terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# ---------------------------------------------------------------------------
# Forgejo (self-hosted Git service).
#
# This module:
# - Deploys the official forgejo/forgejo image via the Codeberg-hosted chart
#   (no Bitnami dependency).
# - Uses an EXTERNAL Postgres only (chart 17.x no longer bundles a PG
#   subchart); callers pass db = { host, port, ... } pointing at the shared
#   module.postgres.
# - Registers an OIDC auth source (Keycloak) via the chart's built-in
#   oauth init job.
# - Optionally mounts a CA bundle so Forgejo trusts the self-signed CA when
#   talking to Keycloak over https.
# ---------------------------------------------------------------------------

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "forgejo"
  }

  hostname   = "${var.hostname_prefix}.${var.domain}"
  public_url = "https://${local.hostname}"

  # --- OIDC auth source (wired by the chart's init job) ---
  oauth_sources = var.oidc_enabled && var.oidc_issuer_url != "" ? [
    {
      name               = var.oidc_provider_name
      provider           = "openidConnect"
      key                = var.oidc_client_id
      secret             = var.oidc_client_secret
      autoDiscoverUrl    = "${var.oidc_issuer_url}/.well-known/openid-configuration"
      existingSecret     = ""
      groupClaimName     = "groups"
      adminGroup         = "platform-admin"
      restrictedGroup    = ""
      requiredClaimName  = ""
      requiredClaimValue = ""
    },
  ] : []

  # --- Base Helm values ---
  base_values = {
    image = {
      repository = var.image_repository
      tag        = var.image_tag
    }

    strategy = { type = "Recreate" }

    # Disable chart ingress; we use Gateway API.
    ingress = { enabled = false }

    service = {
      http = {
        type = "ClusterIP"
        port = 3000
      }
      ssh = {
        type = var.ssh_service_type
        port = var.ssh_port
      }
    }

    persistence = merge(
      {
        enabled = true
        size    = var.repo_storage_size
      },
      var.storage_class == "" ? {} : { storageClass = var.storage_class },
    )

    resources = {
      requests = { cpu = var.cpu_request, memory = var.memory_request }
      limits   = { cpu = var.cpu_limit, memory = var.memory_limit }
    }

    gitea = {
      admin = {
        username = var.admin_username
        password = var.admin_password
        email    = var.admin_email
      }

      # Chart field that auto-wires an OAuth2 login source via init-job.
      oauth = local.oauth_sources

      config = {
        server = {
          DOMAIN           = local.hostname
          ROOT_URL         = "${local.public_url}/"
          SSH_DOMAIN       = local.hostname
          START_SSH_SERVER = true
          SSH_PORT         = var.ssh_port
          SSH_LISTEN_PORT  = 2222 # internal container port
        }
        database = {
          DB_TYPE = "postgres"
          HOST    = "${var.db.host}:${var.db.port}"
          NAME    = var.db.database
          USER    = var.db.username
          PASSWD  = var.db.password
        }
        service = {
          DISABLE_REGISTRATION             = var.disable_registration
          REQUIRE_SIGNIN_VIEW              = var.require_signin_view
          ALLOW_ONLY_EXTERNAL_REGISTRATION = var.disable_registration && var.oidc_enabled
        }
        openid = var.oidc_enabled ? {
          ENABLE_OPENID_SIGNIN = true
          ENABLE_OPENID_SIGNUP = true
        } : {}
        oauth2_client = var.oidc_enabled ? {
          # Auto-register is disabled because Forgejo rejects reserved
          # usernames (e.g. "admin") during the auto-create path and 500s
          # before account-linking can kick in. With this off, first-time
          # OIDC users hit the link-to-existing-account UI instead.
          ENABLE_AUTO_REGISTRATION = false
          USERNAME                 = "preferred_username"
          UPDATE_AVATAR            = true
          ACCOUNT_LINKING          = "login"
          # Promote Keycloak group → Forgejo admin / restricted on every
          # OIDC login. GROUP_CLAIM_NAME must match a claim in the ID token
          # (Keycloak's group mapper emits `groups` by default). Membership
          # is re-evaluated on each login, so removing a user from the
          # group in Keycloak demotes them on next login.
          GROUP_CLAIM_NAME = "groups"
          ADMIN_GROUP      = var.oidc_admin_group
        } : {}
        webhook = {
          ALLOWED_HOST_LIST = "*" # Forgejo -> Hermes/DevPod in-cluster
        }
        # Cluster-wide Forgejo Actions. New repos (incl. mirrors) get
        # Actions enabled by default — workflow files at
        # `.forgejo/workflows/*.yml` trigger on push events. The
        # forgejo-runner module is what actually executes the jobs.
        actions = {
          ENABLED          = true
          DEFAULT_ACTIONS_URL = "github" # `uses: actions/checkout@v4` etc. resolve to upstream GitHub
        }
      }
    }
  }

  base_values_yaml = yamlencode(local.base_values)

  # --- Optional CA bundle mount ---
  # Mirror cert-manager's internal CA secret into this namespace and mount
  # it so Forgejo's Go HTTP client trusts the self-signed Keycloak cert
  # during OIDC autoDiscover. SSL_CERT_DIR makes Go merge the file into the
  # system trust pool rather than replacing it (important — we still need
  # public CAs for fetching external images / webhooks).
  ca_enabled = var.ca_source_secret_name != ""

  ca_values_yaml = local.ca_enabled ? yamlencode({
    extraVolumes = [{
      name = "platform-ca"
      configMap = {
        name = "platform-ca"
        items = [{
          key  = "ca.crt"
          path = "platform-ca.crt"
        }]
      }
    }]
    extraContainerVolumeMounts = [{
      name      = "platform-ca"
      mountPath = "/etc/ssl/certs/platform-ca.crt"
      subPath   = "platform-ca.crt"
      readOnly  = true
    }]
    extraInitVolumeMounts = [{
      name      = "platform-ca"
      mountPath = "/etc/ssl/certs/platform-ca.crt"
      subPath   = "platform-ca.crt"
      readOnly  = true
    }]
    # Forgejo's entrypoint uses BusyBox-alpine; /etc/ssl/certs/*.crt are
    # read automatically. But Go applications prefer SSL_CERT_FILE; set both.
    deployment = {
      env = [
        { name = "SSL_CERT_DIR", value = "/etc/ssl/certs" },
      ]
    }
  }) : ""
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# Mirror the CA Secret into this namespace as a ConfigMap (same pattern as
# oauth2-proxy module). Keeps dependency graph acyclic.
data "kubernetes_secret_v1" "ca_source" {
  count = local.ca_enabled ? 1 : 0

  metadata {
    name      = var.ca_source_secret_name
    namespace = var.ca_source_secret_namespace
  }
}

resource "kubernetes_config_map" "ca_bundle" {
  count = local.ca_enabled ? 1 : 0

  metadata {
    name      = "platform-ca"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  data = {
    "ca.crt" = lookup(data.kubernetes_secret_v1.ca_source[0].data, "ca.crt", "")
  }
}

resource "helm_release" "forgejo" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = var.chart_repository
  chart      = "forgejo"
  version    = var.chart_version

  # Forgejo first-boot (DB init + admin + repo layout) is slow.
  timeout = 900
  wait    = true

  values = compact([
    local.base_values_yaml,
    local.ca_values_yaml,
    var.extra_values,
  ])

  depends_on = [kubernetes_config_map.ca_bundle]
}

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
          name = "${var.release_name}-http"
          port = 3000
        }]
      }]
    }
  })

  depends_on = [helm_release.forgejo]
}
