terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# ---------------------------------------------------------------------------
# Console — Next.js (web) + NestJS (api) at console.<domain>.
#
# Deployment shape (mirrors infra/modules/openfga for the boilerplate):
#   1. Namespace platform-console
#   2. dockerconfigjson Secret for Harbor pulls
#   3. db-create Job (psql) — ensures the `console` DATABASE + ROLE exist
#      in the shared platform-infra Postgres. Idempotent.
#   4. Mirror of the openfga-bootstrap Secret (api_url + store_id +
#      auth_model_id) into platform-console — module.openfga's README
#      explicitly leaves cross-namespace mounting to consumers.
#   5. ConfigMap (non-secret runtime env) + Secret (DATABASE_URL,
#      BETTER_AUTH_SECRET, KEYCLOAK_CLIENT_SECRET).
#   6. auth-migrate Job — runs `pnpm --filter @workspace/auth auth:migrate`
#      against the console DB once before the web/api roll out. Idempotent;
#      migrate is the only safe way to bring up better-auth's tables.
#   7. api Deployment (port 3001) + ClusterIP Service.
#   8. web Deployment (port 3000) + ClusterIP Service.
#   9. Gateway API HTTPRoute on `<hostname>` → web Service. The api is
#      cluster-internal only — `apps/web/lib/api.ts` proxies through the
#      web origin via API_URL_INTERNAL, so the browser never talks to the
#      api directly.
# ---------------------------------------------------------------------------

locals {
  labels = {
    "app.kubernetes.io/part-of"  = "agent-platform"
    "app.kubernetes.io/name"     = var.release_name
    "app.kubernetes.io/instance" = var.release_name
    "agent-platform/component"   = "console"
  }

  scheme          = var.tls_enabled ? "https" : "http"
  better_auth_url = "${local.scheme}://${var.hostname}"

  # In-cluster DNS for the api Service (used by the web pod for its
  # server-side fetches).
  api_service_name = "${var.release_name}-api"
  web_service_name = "${var.release_name}-web"
  api_internal_url = "http://${local.api_service_name}.${var.namespace}.svc.cluster.local:3001"

  # Postgres URI for both apps + the auth-migrate Job.
  pg_uri = "postgres://${var.console_db_username}:${var.console_db_password}@${var.postgres_host}:${var.postgres_port}/${var.console_db_name}?sslmode=disable"

  pull_secret_name          = "${var.release_name}-harbor-pull"
  app_env_cm                = "${var.release_name}-env"
  app_secret_name           = "${var.release_name}-secret"
  openfga_secret_local_name = var.openfga_bootstrap_secret_name # mirror keeps the same name
  forgejo_secret_local_name = "${var.release_name}-forgejo-admin"
  forgejo_enabled           = var.forgejo_admin_secret_name != "" && var.forgejo_internal_url != ""

  # The dockerconfigjson body — base64-encoded by the API server when we
  # set `data` as a raw string (Kubernetes provider handles the encode).
  docker_config_json = jsonencode({
    auths = {
      (var.harbor_registry) = {
        username = var.harbor_username
        password = var.harbor_password
        auth     = base64encode("${var.harbor_username}:${var.harbor_password}")
      }
    }
  })

  keel_annotations = var.keel_managed ? {
    "keel.sh/policy"  = "force"
    "keel.sh/trigger" = "poll"
  } : {}

  ca_enabled    = var.ca_source_secret_name != ""
  ca_mount_path = "/etc/ssl/platform"
  ca_file_path  = "${local.ca_mount_path}/ca.crt"
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# ---------------------------------------------------------------------------
# Harbor pull Secret. Provisioned in-namespace (vs. mirroring from another
# ns) because no cluster-wide source of truth for these creds exists today.
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "harbor_pull" {
  metadata {
    name      = local.pull_secret_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = local.docker_config_json
  }
}

# ---------------------------------------------------------------------------
# Postgres bootstrap (CREATE ROLE + DATABASE).
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "pg_super" {
  metadata {
    name      = "${var.release_name}-pg-superuser"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    PGHOST     = var.postgres_host
    PGPORT     = tostring(var.postgres_port)
    PGUSER     = var.postgres_superuser_username
    PGPASSWORD = var.postgres_superuser_password
    PGDATABASE = "postgres"
  }
}

locals {
  db_create_sql = <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${var.console_db_username}') THEN
        CREATE ROLE ${var.console_db_username} LOGIN PASSWORD '${var.console_db_password}';
      ELSE
        ALTER ROLE ${var.console_db_username} WITH LOGIN PASSWORD '${var.console_db_password}';
      END IF;
    END
    $$;
  SQL
}

resource "kubernetes_config_map" "db_create" {
  metadata {
    name      = "${var.release_name}-db-create"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  data = {
    "create-role.sql" = local.db_create_sql
    "entrypoint.sh"   = <<-SH
      #!/bin/sh
      set -eu
      echo "[db-create] ensuring role '${var.console_db_username}' exists..."
      psql -v ON_ERROR_STOP=1 -f /sql/create-role.sql
      echo "[db-create] ensuring database '${var.console_db_name}' exists..."
      if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${var.console_db_name}'" | grep -q 1; then
        psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${var.console_db_name} OWNER ${var.console_db_username};"
      else
        echo "[db-create] database already exists, skipping CREATE."
      fi
      psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${var.console_db_name} TO ${var.console_db_username};"
      echo "[db-create] done."
    SH
  }
}

resource "kubernetes_job" "db_create" {
  metadata {
    name      = "${var.release_name}-db-create"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    backoff_limit = 6
    template {
      metadata {
        labels = local.labels
      }
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["/bin/sh", "/scripts/entrypoint.sh"]
          env_from {
            secret_ref {
              name = kubernetes_secret.pg_super.metadata[0].name
            }
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.db_create.metadata[0].name
            default_mode = "0755"
            items {
              key  = "entrypoint.sh"
              path = "entrypoint.sh"
            }
          }
        }
        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.db_create.metadata[0].name
            items {
              key  = "create-role.sql"
              path = "create-role.sql"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_secret.pg_super, kubernetes_config_map.db_create]
}

# ---------------------------------------------------------------------------
# Platform CA mirror (selfsigned TLS mode).
# Node.js reads NODE_EXTRA_CA_CERTS at startup; pod mounts this ConfigMap
# at /etc/ssl/platform/ca.crt and the env var points there.
# ---------------------------------------------------------------------------
data "kubernetes_secret_v1" "ca_source" {
  count = var.ca_source_secret_name == "" ? 0 : 1

  metadata {
    name      = var.ca_source_secret_name
    namespace = var.ca_source_secret_namespace
  }
}

resource "kubernetes_config_map" "ca_bundle" {
  count = var.ca_source_secret_name == "" ? 0 : 1

  metadata {
    name      = "${var.release_name}-platform-ca"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  data = {
    "ca.crt" = lookup(data.kubernetes_secret_v1.ca_source[0].data, "ca.crt", "")
  }
}

# ---------------------------------------------------------------------------
# OpenFGA bootstrap Secret mirror.
# ---------------------------------------------------------------------------
data "kubernetes_secret_v1" "openfga_bootstrap" {
  metadata {
    name      = var.openfga_bootstrap_secret_name
    namespace = var.openfga_namespace
  }
}

resource "kubernetes_secret" "openfga_bootstrap_mirror" {
  metadata {
    name      = local.openfga_secret_local_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  # Pass through the keys the OpenFgaService reads at boot.
  # `api_url` from the source Secret is `http://openfga-http.platform-openfga...`;
  # we override it with the cluster DNS we want consumers to use.
  data = {
    OPENFGA_API_URL       = lookup(data.kubernetes_secret_v1.openfga_bootstrap.data, "api_url", "")
    OPENFGA_STORE_ID      = lookup(data.kubernetes_secret_v1.openfga_bootstrap.data, "store_id", "")
    OPENFGA_AUTH_MODEL_ID = lookup(data.kubernetes_secret_v1.openfga_bootstrap.data, "auth_model_id", "")
    OPENFGA_STORE_NAME    = lookup(data.kubernetes_secret_v1.openfga_bootstrap.data, "store_name", "")
  }
}

# ---------------------------------------------------------------------------
# Forgejo admin Secret mirror.
# Same trick as openfga: source Secret lives in platform-forgejo, but
# k8s envFrom can't cross namespaces, so we read it via data and write
# a copy with the env-var keys the FunctionsService expects.
# ---------------------------------------------------------------------------
data "kubernetes_secret_v1" "forgejo_admin" {
  count = local.forgejo_enabled ? 1 : 0

  metadata {
    name      = var.forgejo_admin_secret_name
    namespace = var.forgejo_namespace
  }
}

resource "kubernetes_secret" "forgejo_admin_mirror" {
  count = local.forgejo_enabled ? 1 : 0

  metadata {
    name      = local.forgejo_secret_local_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    FORGEJO_INTERNAL_URL   = var.forgejo_internal_url
    FORGEJO_PUBLIC_URL     = var.forgejo_public_url
    FORGEJO_FUNCTION_ORG   = var.forgejo_function_org
    FORGEJO_ADMIN_USER     = lookup(data.kubernetes_secret_v1.forgejo_admin[0].data, "username", "")
    FORGEJO_ADMIN_PASSWORD = lookup(data.kubernetes_secret_v1.forgejo_admin[0].data, "password", "")
  }
}

# ---------------------------------------------------------------------------
# Runtime env — non-secret ConfigMap + secret Secret.
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "app_env" {
  metadata {
    name      = local.app_env_cm
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  data = {
    BETTER_AUTH_URL     = local.better_auth_url
    KEYCLOAK_ISSUER_URL = var.keycloak_issuer_url
    KEYCLOAK_CLIENT_ID  = var.keycloak_client_id
    WEB_URL             = local.better_auth_url
    API_URL_INTERNAL    = local.api_internal_url
    NEXT_PUBLIC_API_URL = local.better_auth_url # browser never hits api directly; harmless fallback
    # VM / Agent provisioning — the api creates StatefulSets in the
    # unified `resource` namespace using these refs. Empty values
    # disable the corresponding feature.
    VM_IMAGE_BASE        = var.vm_image_base
    VM_IMAGE_DESKTOP     = var.vm_image_desktop
    AGENT_IMAGE          = var.agent_image
    VM_DOMAIN            = var.vm_domain
    # Phase-2 Functions runtime — both vars are used by the
    # FunctionsService dev path (per-function Knative Service +
    # ConfigMap mount + invoke proxy through Kourier).
    FUNCTION_DEV_IMAGE    = var.function_dev_image
    FUNCTION_DOMAIN       = var.function_domain
    FUNCTION_IMAGE_PREFIX = var.function_image_prefix
    VM_GATEWAY_NAME      = var.vm_gateway_name
    VM_GATEWAY_NAMESPACE = var.vm_gateway_namespace
    # ForwardAuth chain for the per-VM Middlewares the api clones
    # into each VM namespace. First gate = oauth2-proxy session;
    # second gate = console-api ownership check (FGA). Empty oauth
    # URL = no auth gate at all. The errors middleware needs the
    # raw Service identity (not just URL) because Traefik's errors
    # spec takes a Service ref, not an HTTP URL.
    VM_AUTH_FORWARD_URL       = var.vm_auth_forward_url
    VM_AUTH_OWNERSHIP_URL     = "http://${local.api_service_name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local:3001/vms/auth"
    # Public oauth2-proxy URL; api wraps VM launch links in
    # `<oauth>/oauth2/start?rd=<vm-url>` so the user gets silent SSO
    # before landing on the VM hostname's forwardAuth gate.
    OAUTH_PROXY_URL = var.oauth_proxy_url
    # Carries every VM's launch URLs as console.<domain>/vms/<slug>/...
    CONSOLE_HOSTNAME = var.hostname
  }
}

# ServiceAccount + ClusterRole the api pod uses to talk to the K8s API
# when provisioning workloads. All VMs/Volumes/LBs/Agents share a
# single `resource` namespace; ownership is enforced at the application
# layer via OpenFGA tuples, not via namespace isolation. Cluster-scoped
# is kept (instead of namespaced Role) because the api creates the
# `resource` namespace itself on first use.
resource "kubernetes_service_account_v1" "api" {
  metadata {
    name      = "${local.api_service_name}-vms"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_v1" "api_vms" {
  metadata {
    name   = "${var.release_name}-vms"
    labels = local.labels
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "create"]
  }
  rule {
    api_groups = [""]
    resources  = ["services", "persistentvolumeclaims"]
    # patch + update needed for the volume bind-to-VM label flip
    # (vms.service.bindToVm / unbindFromVm).
    verbs      = ["get", "list", "create", "delete", "deletecollection", "patch", "update"]
  }
  # Per-VM SSH key Secret. Created by VmsService.create when an
  # agent is attached (id_ed25519 + authorized_keys); deleted on
  # VM teardown.
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  # Read EndpointSlices to compute LB readiness (any endpoint with
  # `conditions.ready != false` flips status from Pending to Ready).
  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list"]
  }
  # Per-resource HTTPRoute under the unified `resource` namespace —
  # one per VM service (term/code/vnc), one per LB, one per agent.
  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["httproutes"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  # Auth Middlewares (vm-auth-oauth/fga, agent-auth-oauth/fga) live
  # once in the `resource` namespace so HTTPRoute extensionRefs can
  # resolve them locally.
  rule {
    api_groups = ["traefik.io"]
    resources  = ["middlewares"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  # ConfigMaps + Knative Services are how Phase-2 Functions surface a
  # dev runtime: per-function ConfigMap holds the user folder, the
  # Knative Service mounts it. console-api creates+rolls these on
  # save in the editor.
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["serving.knative.dev"]
    resources  = ["services"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  # Per-VM ServiceAccount + (Cluster)RoleBinding so kubectl in the
  # workspace pod authenticates with its own identity. Default grant
  # is namespace-admin (RoleBinding in `resource` ns); cluster-admin
  # is opt-in via the VM create form.
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["rolebindings", "clusterrolebindings"]
    verbs      = ["get", "list", "create", "delete", "patch", "update"]
  }
  # `bind` on the specific ClusterRoles we hand out. Without this,
  # k8s rejects the RoleBinding/ClusterRoleBinding create with
  # "user cannot bind clusterroles.rbac.authorization.k8s.io/<name>"
  # — bind is enforced separately from create on (cluster)rolebindings.
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["clusterroles"]
    resource_names = ["admin", "cluster-admin"]
    verbs          = ["bind"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "api_vms" {
  metadata {
    name   = "${var.release_name}-vms"
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.api_vms.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.api.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_secret" "app_secret" {
  metadata {
    name      = local.app_secret_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    DATABASE_URL           = local.pg_uri
    BETTER_AUTH_SECRET     = var.better_auth_secret
    KEYCLOAK_CLIENT_SECRET = var.keycloak_client_secret
    # Phase-2 Functions Deploy flow needs Harbor creds so console-api
    # can mirror them as Forgejo org secrets on the `service` org —
    # without that, function repos can't `docker login` to Harbor and
    # the build workflow fails. Reusing the same admin creds the
    # harbor_pull dockerconfig is built from.
    HARBOR_USER  = var.harbor_username
    HARBOR_TOKEN = var.harbor_password
  }
}

# ---------------------------------------------------------------------------
# auth-migrate Job — runs better-auth's CLI migrate against the console DB.
# Reuses the api image (which ships pnpm + the built @workspace/auth pkg).
# Idempotent: running the migrate against an already-migrated schema is a
# no-op modulo a network round-trip.
# ---------------------------------------------------------------------------
resource "kubernetes_job" "auth_migrate" {
  metadata {
    name      = "${var.release_name}-auth-migrate"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    backoff_limit = 4
    template {
      metadata {
        labels = local.labels
      }
      spec {
        restart_policy = "OnFailure"
        image_pull_secrets {
          name = kubernetes_secret.harbor_pull.metadata[0].name
        }
        container {
          name              = "migrate"
          image             = var.api_image
          image_pull_policy = var.image_pull_policy
          working_dir       = "/repo"
          command           = ["pnpm"]
          args = [
            "--filter", "@workspace/auth",
            "auth:migrate",
          ]
          env_from {
            secret_ref {
              name = kubernetes_secret.app_secret.metadata[0].name
            }
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map.app_env.metadata[0].name
            }
          }
          dynamic "env" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name  = "NODE_EXTRA_CA_CERTS"
              value = local.ca_file_path
            }
          }
          dynamic "volume_mount" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name       = "platform-ca"
              mount_path = local.ca_mount_path
              read_only  = true
            }
          }
        }
        dynamic "volume" {
          for_each = local.ca_enabled ? [1] : []
          content {
            name = "platform-ca"
            config_map {
              name = kubernetes_config_map.ca_bundle[0].metadata[0].name
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_job.db_create,
    kubernetes_secret.app_secret,
    kubernetes_secret.harbor_pull,
  ]
}

# ---------------------------------------------------------------------------
# api Deployment + Service. Cluster-internal only.
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "api" {
  count = var.argocd_managed_deployments ? 0 : 1

  metadata {
    name        = local.api_service_name
    namespace   = kubernetes_namespace.this.metadata[0].name
    labels      = merge(local.labels, { "agent-platform/role" = "api" })
    annotations = local.keel_annotations
  }
  spec {
    replicas = var.api_replicas
    selector {
      match_labels = { "app.kubernetes.io/instance" = var.release_name, "agent-platform/role" = "api" }
    }
    template {
      metadata {
        labels = merge(local.labels, { "agent-platform/role" = "api" })
      }
      spec {
        service_account_name = kubernetes_service_account_v1.api.metadata[0].name
        image_pull_secrets {
          name = kubernetes_secret.harbor_pull.metadata[0].name
        }
        container {
          name              = "api"
          image             = var.api_image
          image_pull_policy = var.image_pull_policy
          port {
            name           = "http"
            container_port = 3001
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.app_secret.metadata[0].name
            }
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map.app_env.metadata[0].name
            }
          }
          # OpenFGA bootstrap values arrive via mirrored Secret as
          # OPENFGA_{API_URL,STORE_ID,AUTH_MODEL_ID,STORE_NAME}.
          env_from {
            secret_ref {
              name = kubernetes_secret.openfga_bootstrap_mirror.metadata[0].name
            }
          }
          dynamic "env" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name  = "NODE_EXTRA_CA_CERTS"
              value = local.ca_file_path
            }
          }
          dynamic "volume_mount" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name       = "platform-ca"
              mount_path = local.ca_mount_path
              read_only  = true
            }
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }
        }
        dynamic "volume" {
          for_each = local.ca_enabled ? [1] : []
          content {
            name = "platform-ca"
            config_map {
              name = kubernetes_config_map.ca_bundle[0].metadata[0].name
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_job.auth_migrate]
}

resource "kubernetes_service" "api" {
  metadata {
    name      = local.api_service_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/instance" = var.release_name
      "agent-platform/role"        = "api"
    }
    port {
      name        = "http"
      port        = 3001
      target_port = "http"
    }
  }
}

# ---------------------------------------------------------------------------
# web Deployment + Service. Public ingress lands here.
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "web" {
  count = var.argocd_managed_deployments ? 0 : 1

  metadata {
    name        = local.web_service_name
    namespace   = kubernetes_namespace.this.metadata[0].name
    labels      = merge(local.labels, { "agent-platform/role" = "web" })
    annotations = local.keel_annotations
  }
  spec {
    replicas = var.web_replicas
    selector {
      match_labels = { "app.kubernetes.io/instance" = var.release_name, "agent-platform/role" = "web" }
    }
    template {
      metadata {
        labels = merge(local.labels, { "agent-platform/role" = "web" })
      }
      spec {
        image_pull_secrets {
          name = kubernetes_secret.harbor_pull.metadata[0].name
        }
        container {
          name              = "web"
          image             = var.web_image
          image_pull_policy = var.image_pull_policy
          port {
            name           = "http"
            container_port = 3000
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.app_secret.metadata[0].name
            }
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map.app_env.metadata[0].name
            }
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.openfga_bootstrap_mirror.metadata[0].name
            }
          }
          dynamic "env" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name  = "NODE_EXTRA_CA_CERTS"
              value = local.ca_file_path
            }
          }
          dynamic "volume_mount" {
            for_each = local.ca_enabled ? [1] : []
            content {
              name       = "platform-ca"
              mount_path = local.ca_mount_path
              read_only  = true
            }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
        dynamic "volume" {
          for_each = local.ca_enabled ? [1] : []
          content {
            name = "platform-ca"
            config_map {
              name = kubernetes_config_map.ca_bundle[0].metadata[0].name
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_deployment.api]
}

resource "kubernetes_service" "web" {
  metadata {
    name      = local.web_service_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/instance" = var.release_name
      "agent-platform/role"        = "web"
    }
    port {
      name        = "http"
      port        = 3000
      target_port = "http"
    }
  }
}

# ---------------------------------------------------------------------------
# HTTPRoute → web Service. The api isn't exposed publicly; web→api stays
# within the cluster on the api Service DNS.
# ---------------------------------------------------------------------------
locals {
  httproute_manifest = yamlencode({
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
      hostnames = [var.hostname]
      rules = [{
        matches = [{ path = { type = "PathPrefix", value = "/" } }]
        backendRefs = [{
          name = local.web_service_name
          port = 3000
        }]
      }]
    }
  })
}

resource "kubectl_manifest" "httproute" {
  yaml_body  = local.httproute_manifest
  depends_on = [kubernetes_service.web]
}

# =====================================================================
# Argo CD-managed mode (Phase 2 of the Keel → Argo CD migration)
#
# When `argocd_managed_deployments = true`, the module's TF Deployments
# are skipped and Argo CD takes over from a kustomize tree at
# `<argocd_repo_url>/<argocd_repo_path>`. argocd-image-updater
# annotations on the Application replace Keel's auto-roll role:
#   Forgejo Actions push → Harbor :latest digest changes →
#   Image Updater patches Application → Argo CD syncs → kubelet rolls.
# =====================================================================

locals {
  argocd_enabled        = var.argocd_managed_deployments
  argocd_repo_secret_id = sha1(var.argocd_repo_url)
  harbor_prefix = (
    var.harbor_registry_prefix != "" ? var.harbor_registry_prefix
    : split("/", var.harbor_registry)[0]
  )

  # `newest-build` picks the SHA tag with the highest push time —
  # matches our "Forgejo Actions pushes <git-sha> + :latest" CI. The
  # allow-tags regex filters out moving tags (latest, etc.) so the
  # Application always pins to an immutable SHA (kubelet's
  # IfNotPresent cache stays safe across rolls).
  argocd_app_annotations = {
    "argocd-image-updater.argoproj.io/image-list" = join(",", [
      "console-api=${local.harbor_prefix}/agent-platform/console-api",
      "console-web=${local.harbor_prefix}/agent-platform/console-web",
    ])
    "argocd-image-updater.argoproj.io/console-api.update-strategy" = "newest-build"
    "argocd-image-updater.argoproj.io/console-web.update-strategy" = "newest-build"
    "argocd-image-updater.argoproj.io/console-api.allow-tags"      = "regexp:^[0-9a-f]{40}$"
    "argocd-image-updater.argoproj.io/console-web.allow-tags"      = "regexp:^[0-9a-f]{40}$"
    # Patch the Application's `spec.source.kustomize.images` (NOT the
    # YAML in git) so the source tree stays clean across rolls.
    "argocd-image-updater.argoproj.io/write-back-method" = "argocd"
  }
}

# Repo Secret — Argo CD's repo-server uses this to clone manifests
# from the Git source.
resource "kubernetes_secret_v1" "argocd_repo" {
  count = local.argocd_enabled ? 1 : 0

  metadata {
    name      = "console-${local.argocd_repo_secret_id}"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type"   = "repository"
      "agent-platform/component"         = "console"
      "app.kubernetes.io/instance"       = var.release_name
    }
  }

  type = "Opaque"

  data = {
    type     = "git"
    url      = var.argocd_repo_url
    username = var.argocd_repo_username
    password = var.argocd_repo_password
    insecure = var.argocd_repo_insecure ? "true" : "false"
  }
}

resource "kubectl_manifest" "argocd_application" {
  count = local.argocd_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name        = var.release_name
      namespace   = var.argocd_namespace
      labels      = local.labels
      annotations = local.argocd_app_annotations
      finalizers  = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_repo_url
        targetRevision = var.argocd_repo_revision
        path           = var.argocd_repo_path
        kustomize = {
          # Initial image tags. Image Updater overwrites these on
          # every Harbor push.
          images = [
            "${local.harbor_prefix}/agent-platform/console-api:latest",
            "${local.harbor_prefix}/agent-platform/console-web:latest",
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.this.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=false", # we create it ourselves
          "ApplyOutOfSyncOnly=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  depends_on = [
    kubernetes_secret_v1.argocd_repo,
    kubernetes_namespace.this,
    kubernetes_secret.app_secret,
    kubernetes_config_map.app_env,
    kubernetes_secret.harbor_pull,
    kubernetes_service_account_v1.api,
  ]
}
