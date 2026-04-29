terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

# ---------------------------------------------------------------------------
# Keycloak via codecentric/keycloakx (uses the official quay.io/keycloak/keycloak
# image). No Bitnami dependency.
#
# This chart does NOT bundle a Postgres subchart — you must supply an external
# DB. In this project we use the shared module.postgres in `platform-infra`.
# ---------------------------------------------------------------------------

locals {
  use_gateway_api = var.gateway_api_enabled
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "keycloak"
    }
  }
}

# DB password stored as a Secret so it's not hardcoded into chart values.
resource "kubernetes_secret" "db" {
  metadata {
    name      = "${var.release_name}-db"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of"  = "agent-platform"
      "app.kubernetes.io/name"     = var.release_name
      "app.kubernetes.io/instance" = var.release_name
    }
  }
  type = "Opaque"
  data = {
    "username" = var.db.username
    "password" = var.db.password
  }
}

# Admin bootstrap credentials.
resource "kubernetes_secret" "admin" {
  metadata {
    name      = "${var.release_name}-admin"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of"  = "agent-platform"
      "app.kubernetes.io/name"     = var.release_name
      "app.kubernetes.io/instance" = var.release_name
    }
  }
  type = "Opaque"
  data = {
    "username" = var.admin_username
    "password" = var.admin_password
  }
}

locals {
  # codecentric/keycloakx passes config via `extraEnv` as a YAML-serialized list.
  # Keycloak uses KC_* env vars (see https://www.keycloak.org/server/all-config).
  extra_env_yaml = <<-YAML
    - name: KEYCLOAK_ADMIN
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.admin.metadata[0].name}
          key: username
    - name: KEYCLOAK_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.admin.metadata[0].name}
          key: password
    # Legacy env names used by Keycloak 26+ bootstrap
    - name: KC_BOOTSTRAP_ADMIN_USERNAME
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.admin.metadata[0].name}
          key: username
    - name: KC_BOOTSTRAP_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.admin.metadata[0].name}
          key: password
    - name: KC_DB
      value: postgres
    - name: KC_DB_URL
      value: "jdbc:postgresql://${var.db.host}:${var.db.port}/${var.db.database}"
    - name: KC_DB_USERNAME
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.db.metadata[0].name}
          key: username
    - name: KC_DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: ${kubernetes_secret.db.metadata[0].name}
          key: password
    - name: KC_HOSTNAME
      value: ${var.hostname}
    - name: KC_HOSTNAME_STRICT
      value: "false"
    - name: KC_PROXY_HEADERS
      value: xforwarded
    - name: KC_HTTP_ENABLED
      value: "true"
    - name: KC_HEALTH_ENABLED
      value: "true"
    - name: KC_METRICS_ENABLED
      value: "true"
  YAML

  base_values = {
    image = {
      repository = var.image_repository
      tag        = var.image_tag
      # pullPolicy: IfNotPresent (chart default)
    }

    # `start` runs Keycloak in its built-in optimized mode; we set HTTP-only
    # and rely on the gateway to terminate TLS.
    command = [
      "/opt/keycloak/bin/kc.sh",
      "start",
      "--http-enabled=true",
      "--hostname-strict=false",
      "--proxy-headers=xforwarded",
    ]

    replicas = var.replicas

    http = {
      relativePath = "/"
    }

    # The chart ships liveness/readiness probes hitting /health/live and
    # /health/ready; these require KC_HEALTH_ENABLED=true (set via extraEnv).
    resources = var.resources

    serviceAccount = { create = true }

    # Disable the chart's built-in Postgres dependency — we inject our own.
    database = {
      vendor         = "postgres"
      existingSecret = ""
    }

    # Ingress disabled; we use Gateway API (HTTPRoute created below).
    ingress = { enabled = false }

    # Service stays ClusterIP; the Gateway handles external routing.
    service = {
      type     = "ClusterIP"
      httpPort = 8080
    }
  }

  base_values_yaml = yamlencode(local.base_values)

  httproute_manifest = local.use_gateway_api ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = var.release_name
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "keycloak"
      }
    }
    spec = {
      parentRefs = [merge(
        {
          name      = var.gateway_parent_ref.name
          namespace = var.gateway_parent_ref.namespace
        },
        var.gateway_parent_ref.sectionName == null ? {} : { sectionName = var.gateway_parent_ref.sectionName },
      )]
      hostnames = [var.hostname]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # codecentric/keycloakx creates a Service named
          # "<release>-keycloakx-http" (suffix is hardcoded in the chart).
          name = "${var.release_name}-keycloakx-http"
          port = 8080
        }]
      }]
    }
  }) : ""
}

resource "helm_release" "keycloak" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.chart_version

  timeout = 900
  wait    = true

  values = compact([
    local.base_values_yaml,
    local.extra_env_wrapper,
    var.extra_values,
  ])
}

# Keycloakx expects `extraEnv` to be a YAML *string*, not a list — it templates
# it verbatim. We wrap the env list in that top-level key.
locals {
  extra_env_wrapper = yamlencode({
    extraEnv = local.extra_env_yaml
  })
}

resource "kubectl_manifest" "httproute" {
  count = local.use_gateway_api ? 1 : 0

  yaml_body  = local.httproute_manifest
  depends_on = [helm_release.keycloak]

  lifecycle {
    precondition {
      condition     = var.gateway_parent_ref != null
      error_message = "gateway_parent_ref is required when gateway_api_enabled = true."
    }
  }
}

# Helm `wait = true` only confirms pod readiness — it doesn't confirm that
# Traefik has reconciled the HTTPRoute or that Keycloak's master realm is
# actually serving OIDC discovery. The keycloak/keycloak provider used by
# module.keycloak-realm hits the public URL at apply time, so without this
# gate the first apply fails with `404 Not Found` from Traefik until the
# route lands. The previous workaround was "wait 30s and re-run" — this
# folds that into a single apply.
resource "null_resource" "wait_public" {
  count = var.wait_for_public_url ? 1 : 0

  triggers = {
    helm_revision = helm_release.keycloak.metadata[0].revision
    httproute_id  = join("", kubectl_manifest.httproute[*].id)
    hostname      = var.hostname
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eo pipefail
      SCHEME="${var.tls_enabled ? "https" : "http"}"
      PORT="${var.local_resolve_port > 0 ? var.local_resolve_port : (var.tls_enabled ? 443 : 80)}"
      URL="$${SCHEME}://${var.hostname}/realms/master/.well-known/openid-configuration"
      RESOLVE_ARGS=()
      if [ -n "${var.local_resolve_ip}" ]; then
        RESOLVE_ARGS=(--resolve "${var.hostname}:$${PORT}:${var.local_resolve_ip}")
        echo "Waiting for Keycloak at $${URL} (resolve ${var.hostname} -> ${var.local_resolve_ip})..."
      else
        echo "Waiting for Keycloak at $${URL}..."
      fi
      for i in $(seq 1 90); do
        STATUS=$(curl -ksS "$${RESOLVE_ARGS[@]}" -o /dev/null -w '%%{http_code}' --connect-timeout 3 --max-time 10 "$${URL}" || true)
        if [ "$${STATUS}" = "200" ]; then
          echo "Keycloak ready (HTTP $${STATUS}) after $${i} attempt(s)."
          exit 0
        fi
        sleep 2
      done
      echo "Keycloak did not become ready at $${URL} within ~3min" >&2
      exit 1
    EOT
  }

  depends_on = [helm_release.keycloak, kubectl_manifest.httproute]
}
