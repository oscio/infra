terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "harbor"
  }

  hostname   = "${var.hostname_prefix}.${var.domain}"
  public_url = "https://${local.hostname}"

  storage_class_setting = var.storage_class == "" ? {} : { storageClass = var.storage_class }

  # Helm chart values. Harbor exposes a big tree of optional settings; we
  # tune the bare minimum for a dev deployment (embedded PG, Redis, Trivy).
  # OIDC is NOT set here — it has to be pushed via Harbor API after install
  # because Harbor persists auth-mode config in its DB, not env vars.
  base_values = {
    # External URL Harbor advertises in `docker pull`, manifests, etc.
    externalURL = local.public_url

    expose = {
      type = "clusterIP" # Chart creates a Service; our HTTPRoute fronts it.
      tls = {
        enabled = false # TLS terminates at the Gateway.
      }
      ingress = {
        enabled = false
      }
    }

    internalTLS = {
      enabled = false # inter-pod in-cluster; skip for simplicity
    }

    harborAdminPassword = var.admin_password

    # Embedded DB + cache (dev only; prod would use external managed svcs)
    database = {
      type = "internal"
      internal = {
        password     = "changeit" # embedded Postgres user
        shmSizeLimit = "512Mi"
      }
    }

    redis = {
      type = "internal"
    }

    # Persistence — one entry per PVC-backed component.
    persistence = {
      enabled        = true
      resourcePolicy = "keep"
      persistentVolumeClaim = merge(
        {
          registry = merge(
            { size = var.registry_storage_size, accessMode = "ReadWriteOnce" },
            local.storage_class_setting,
          )
          jobservice = {
            jobLog = merge(
              { size = var.jobservice_storage_size, accessMode = "ReadWriteOnce" },
              local.storage_class_setting,
            )
          }
          database = merge(
            { size = var.database_storage_size, accessMode = "ReadWriteOnce" },
            local.storage_class_setting,
          )
          redis = merge(
            { size = var.redis_storage_size, accessMode = "ReadWriteOnce" },
            local.storage_class_setting,
          )
        },
        var.trivy_enabled ? {
          trivy = merge(
            { size = var.trivy_storage_size, accessMode = "ReadWriteOnce" },
            local.storage_class_setting,
          )
        } : {},
      )
    }

    trivy = {
      enabled = var.trivy_enabled # vuln scanning — disable on memory-constrained dev clusters
    }

    # Resource tuning for the core container (the one that matters most on
    # Docker Desktop — the rest use chart defaults).
    core = {
      resources = {
        requests = { memory = var.core_memory_request }
        limits   = { memory = var.core_memory_limit }
      }
    }
  }

  base_values_yaml = yamlencode(local.base_values)
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

resource "helm_release" "harbor" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://helm.goharbor.io"
  chart      = "harbor"
  version    = var.chart_version

  # Harbor first-boot is slow: DB init + migrations + Trivy DB seed.
  timeout = 1200
  wait    = true

  values = compact([
    local.base_values_yaml,
    var.extra_values,
  ])
}

# =====================================================================
# HTTPRoute at registry.<domain>
# Harbor chart creates a Service named `<release>-core` (HTTP). All
# /v2/, /api/, /service/, /c/ paths go to core; core proxies to registry
# internally.
# =====================================================================

resource "kubectl_manifest" "httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = var.release_name
      namespace = kubernetes_namespace.this.metadata[0].name
      labels    = local.labels
    }
    spec = {
      parentRefs = [merge(
        {
          name      = var.gateway_parent_ref.name
          namespace = var.gateway_parent_ref.namespace
        },
        var.gateway_parent_ref.sectionName == null ? {} : { sectionName = var.gateway_parent_ref.sectionName },
      )]
      hostnames = [local.hostname]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # Harbor ships an internal nginx that reverse-proxies UI (portal)
          # and API (core) under one hostname. Its Service is just
          # "<release>" (no suffix). Routing directly at harbor-core would
          # only expose the API and hit 404 on '/'.
          name = var.release_name
          port = 80
        }]
      }]
    }
  })

  depends_on = [helm_release.harbor]
}

# =====================================================================
# In-cluster registry endpoint (NodePort, plain HTTP)
# =====================================================================
#
# Reasons we can't reuse Harbor's external URL for in-cluster pulls:
#   1. The chart pins the registry's external URL to `https://<host>`,
#      which the Bearer-token challenge embeds in WWW-Authenticate. To
#      reach that URL kubelet needs node-side DNS for the public hostname
#      → /etc/hosts hacks per node.
#   2. Self-signed dev certs need skip_verify in containerd hosts.toml.
#   3. The chart's own Service has no NodePort, so even bypassing DNS
#      we couldn't reach Harbor without going through Traefik.
#
# This Service:
#   - Adds a side-channel that points at the same harbor-nginx pods.
#   - Pinned ClusterIP so image refs (e.g.
#     `<cluster_ip>:<node_port>/agent-platform/foo:latest`) are stable
#     across helm upgrades without a data source lookup.
#   - NodePort makes it trivially reachable from any node.
#
# Pair with `project_public = true` on the harbor-bootstrap module so
# anonymous pull works — otherwise Harbor still issues a Bearer
# challenge pointing back at the *external* URL and we're back to
# square one.

resource "kubernetes_service_v1" "internal" {
  count = var.internal_service_enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}-internal"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type       = "NodePort"
    cluster_ip = var.internal_service_cluster_ip == "" ? null : var.internal_service_cluster_ip

    selector = {
      "app.kubernetes.io/name"      = "harbor"
      "app.kubernetes.io/component" = "nginx"
      "release"                     = var.release_name
    }

    port {
      name        = "http-registry"
      port        = var.internal_service_port
      target_port = 8080
      node_port   = var.internal_service_node_port
      protocol    = "TCP"
    }
  }

  depends_on = [helm_release.harbor]
}

# =====================================================================
# OIDC configuration (post-install, via Harbor API)
#
# Why this pattern: Harbor stores auth-mode + OIDC config in its Postgres
# DB, not in env vars. The Helm chart has no knob to pre-seed it. We call
# the Harbor REST API once Harbor is up to flip auth_mode=oidc_auth and
# register the Keycloak provider. Idempotent — PUT upserts the config.
#
# Dependencies: curl + jq on the Terraform runner. Runs via local-exec.
# =====================================================================

resource "null_resource" "oidc_config" {
  count = var.oidc_enabled ? 1 : 0

  triggers = {
    issuer_url    = var.oidc_issuer_url
    client_id     = var.oidc_client_id
    client_secret = var.oidc_client_secret
    admin_group   = var.oidc_admin_group
    groups_claim  = var.oidc_groups_claim
    scope         = var.oidc_scope
    auto_onboard  = tostring(var.oidc_auto_onboard)
    verify_cert   = tostring(var.oidc_verify_cert)
    harbor_url    = local.public_url
    # Force re-run when the admin password changes (breaks the curl otherwise)
    admin_password_hash = sha256(var.admin_password)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      HARBOR_URL     = local.public_url
      ADMIN_PASSWORD = var.admin_password
      ISSUER_URL     = var.oidc_issuer_url
      CLIENT_ID      = var.oidc_client_id
      CLIENT_SECRET  = var.oidc_client_secret
      GROUPS_CLAIM   = var.oidc_groups_claim
      ADMIN_GROUP    = var.oidc_admin_group
      OIDC_SCOPE     = var.oidc_scope
      AUTO_ONBOARD   = tostring(var.oidc_auto_onboard)
      VERIFY_CERT    = tostring(var.oidc_verify_cert)
      INSECURE_TLS   = tostring(var.local_exec_insecure_tls)
    }
    command = <<-EOT
      set -euo pipefail

      # Local-exec runs on the Terraform host, which typically doesn't
      # trust the internal self-signed CA. -k skips verification — safe
      # because the traffic is localhost → gateway → Harbor, no MITM
      # surface. If a real CA bundle is preferred, swap in --cacert.
      CURL_INSECURE=""
      if [ "$${INSECURE_TLS}" = "true" ]; then
        CURL_INSECURE="-k"
      fi

      # Wait up to 3 minutes for Harbor core to accept admin credentials.
      for i in {1..60}; do
        if curl $${CURL_INSECURE} -fsS -u "admin:$${ADMIN_PASSWORD}" "$${HARBOR_URL}/api/v2.0/health" >/dev/null 2>&1; then
          echo "Harbor is ready."
          break
        fi
        echo "Waiting for Harbor API... ($${i}/60)"
        sleep 3
      done

      BODY=$(cat <<JSON
      {
        "auth_mode":              "oidc_auth",
        "oidc_name":              "Keycloak",
        "oidc_endpoint":          "$${ISSUER_URL}",
        "oidc_client_id":         "$${CLIENT_ID}",
        "oidc_client_secret":     "$${CLIENT_SECRET}",
        "oidc_scope":             "$${OIDC_SCOPE}",
        "oidc_groups_claim":      "$${GROUPS_CLAIM}",
        "oidc_admin_group":       "$${ADMIN_GROUP}",
        "oidc_auto_onboard":      $${AUTO_ONBOARD},
        "oidc_verify_cert":       $${VERIFY_CERT},
        "oidc_user_claim":        "preferred_username"
      }
      JSON
      )

      curl $${CURL_INSECURE} -fsS -u "admin:$${ADMIN_PASSWORD}" \
        -X PUT "$${HARBOR_URL}/api/v2.0/configurations" \
        -H "Content-Type: application/json" \
        -d "$${BODY}"

      echo "Harbor OIDC configured."
    EOT
  }

  depends_on = [kubectl_manifest.httproute]
}
