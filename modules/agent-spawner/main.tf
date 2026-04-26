terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# ---------------------------------------------------------------------------
# Hermes Spawner — hub dashboard at `hermes.dev.openschema.io` that
# spawns per-project Hermes pods at `<pid>.hermes.dev.openschema.io`.
#
# Depends on:
#   * module.postgres — for the spawner's own DB
#   * module.openfga  — for project ReBAC
#   * module.traefik  — for the Gateway + wildcard listener (must already
#                       have `*.hermes.dev.openschema.io`)
#   * oauth2-proxy    — to front the hub URL with Keycloak SSO
# ---------------------------------------------------------------------------

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "agent-spawner"
  }

  database_url = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${var.postgres_host}:${var.postgres_port}/${var.db_name}"
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# =====================================================================
# DB bootstrap Job — creates the `spawner` Postgres role + database.
# Runs once at install; idempotent (ignores "already exists" errors).
# =====================================================================

resource "kubernetes_secret" "pg_super" {
  metadata {
    name      = "${var.release_name}-pg-superuser"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    PGPASSWORD = var.postgres_superuser_password
  }
}

resource "kubernetes_config_map" "db_create" {
  metadata {
    name      = "${var.release_name}-db-create"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  data = {
    "create.sql" = <<-SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${var.db_username}') THEN
          CREATE ROLE ${var.db_username} LOGIN PASSWORD '${var.db_password}';
        END IF;
      END $$;
    SQL
    "create-db.sh" = <<-SH
      #!/bin/sh
      set -eu
      export PGHOST=${var.postgres_host} PGPORT=${var.postgres_port} PGUSER=${var.postgres_superuser_username}

      echo "[db-create] ensuring role '${var.db_username}'..."
      psql -d postgres -v ON_ERROR_STOP=1 -f /sql/create.sql

      if psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${var.db_name}'" | grep -q 1; then
        echo "[db-create] database '${var.db_name}' already exists."
      else
        echo "[db-create] creating database '${var.db_name}'..."
        psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${var.db_name} OWNER ${var.db_username};"
      fi

      psql -d postgres -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${var.db_name} TO ${var.db_username};"
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
    backoff_limit = 5
    template {
      metadata {
        labels = local.labels
      }
      spec {
        restart_policy = "OnFailure"

        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["/bin/sh", "/scripts/create-db.sh"]

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
          }
        }
        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.db_create.metadata[0].name
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

  depends_on = [
    kubernetes_secret.pg_super,
    kubernetes_config_map.db_create,
  ]
}

# =====================================================================
# CA ConfigMap + LLM Secret source copies
# These live in the spawner's namespace and the spawner propagates them
# to each new per-project namespace at spawn time.
# =====================================================================

resource "kubectl_manifest" "ca_configmap" {
  count = length(var.ca_configmap_data) == 0 ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = var.ca_configmap_name
      namespace = kubernetes_namespace.this.metadata[0].name
      labels    = local.labels
    }
    data = var.ca_configmap_data
  })
}

resource "kubernetes_secret" "llm_keys" {
  count = length(var.llm_api_keys) == 0 ? 0 : 1

  metadata {
    name      = var.llm_secret_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = var.llm_api_keys
}

# =====================================================================
# ServiceAccount + ClusterRole + Binding (broad perms)
# =====================================================================

resource "kubernetes_service_account" "spawner" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "spawner" {
  metadata {
    name   = "${var.release_name}-manager"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources = [
      "serviceaccounts", "services", "configmaps", "secrets",
      "persistentvolumeclaims", "pods", "pods/log",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets", "statefulsets/scale"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["httproutes", "referencegrants"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # ClusterRoleBinding management for the per-project cluster-admin
  # binding (only created when workspace_cluster_admin_enabled). The
  # spawner needs to be able to create AND delete these to keep the
  # cluster's cluster-scoped state in sync with the project lifecycle.
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterrolebindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "spawner" {
  metadata {
    name   = "${var.release_name}-manager"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.spawner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.spawner.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

# =====================================================================
# Deployment
# =====================================================================

resource "kubernetes_secret" "runtime" {
  metadata {
    name      = "${var.release_name}-runtime"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    SPAWNER_DATABASE_URL = local.database_url
  }
}

resource "kubernetes_deployment" "spawner" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
    # Keel auto-rollout config. With `force` policy + `poll` trigger,
    # Keel polls Harbor for a new digest of `var.image` every minute
    # and patches this Deployment when one appears — closes the loop
    # of "Forgejo Actions builds → Harbor push → spawner restarts on
    # the new image" without anyone running `kubectl rollout restart`.
    annotations = var.keel_enabled ? {
      "keel.sh/policy"       = "force"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = var.keel_poll_schedule
      "keel.sh/match-tag"    = "true"
    } : {}
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"  # single DB writer; avoid two spawners in parallel
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = var.release_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name = kubernetes_service_account.spawner.metadata[0].name

        # Pulling the spawner image from in-cluster Harbor needs creds.
        # The Secret is created at the cluster level (kubernetes_secret_v1
        # "harbor_pull_secret") in this same namespace; we reference it
        # by name. dynamic{} so the block disappears when the Secret was
        # opted out of (`var.harbor_pull_secret_name == ""`).
        dynamic "image_pull_secrets" {
          for_each = var.harbor_pull_secret_name == "" ? [] : [1]
          content {
            name = var.harbor_pull_secret_name
          }
        }

        container {
          name              = "spawner"
          image             = var.image
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "SPAWNER_HUB_HOSTNAME"
            value = var.hub_hostname
          }
          env {
            name  = "SPAWNER_PROJECT_HOSTNAME_SUFFIX"
            value = var.project_hostname_suffix
          }
          env {
            name  = "SPAWNER_NAMESPACE_PREFIX"
            value = var.project_namespace_prefix
          }
          env {
            name  = "SPAWNER_GATEWAY_NAMESPACE"
            value = var.gateway_namespace
          }
          env {
            name  = "SPAWNER_GATEWAY_NAME"
            value = var.gateway_name
          }
          env {
            name  = "SPAWNER_GATEWAY_SECTION_NAME"
            value = var.gateway_section_name
          }
          env {
            name  = "SPAWNER_STORAGE_CLASS"
            value = var.storage_class
          }
          env {
            name = "SPAWNER_IMAGE_PROFILES"
            # pydantic-settings parses dict[str, str] from a JSON string.
            value = jsonencode(var.image_profiles)
          }
          env {
            name  = "SPAWNER_DEFAULT_IMAGE_PROFILE"
            value = var.default_image_profile
          }
          env {
            name  = "SPAWNER_DESKTOP_IMAGE_PROFILE"
            value = var.desktop_image_profile
          }
          env {
            name  = "SPAWNER_FORGEJO_API_URL"
            value = var.forgejo_api_url
          }
          env {
            name  = "SPAWNER_FORGEJO_PUBLIC_HOST"
            value = var.forgejo_public_host
          }
          env {
            name  = "SPAWNER_FORGEJO_ADMIN_TOKEN"
            value = var.forgejo_admin_token
          }
          env {
            name  = "SPAWNER_FORGEJO_USER_DEFAULT_PASSWORD"
            value = var.forgejo_user_default_password
          }
          env {
            name  = "SPAWNER_WORKSPACE_CLUSTER_ADMIN_ENABLED"
            value = var.workspace_cluster_admin_enabled ? "true" : "false"
          }
          env {
            name  = "SPAWNER_HARBOR_PULL_SECRET_NAME"
            value = var.harbor_pull_secret_name
          }
          env {
            name  = "SPAWNER_HARBOR_PULL_SECRET_SOURCE_NAMESPACE"
            value = var.namespace
          }
          env {
            name  = "SPAWNER_LLM_SECRET_SOURCE_NAMESPACE"
            value = kubernetes_namespace.this.metadata[0].name
          }
          env {
            name  = "SPAWNER_LLM_SECRET_NAME"
            value = var.llm_secret_name
          }
          env {
            name  = "SPAWNER_CA_CONFIGMAP_SOURCE_NAMESPACE"
            value = kubernetes_namespace.this.metadata[0].name
          }
          env {
            name  = "SPAWNER_CA_CONFIGMAP_NAME"
            value = var.ca_configmap_name
          }
          env {
            name  = "SPAWNER_MAX_PROJECTS_PER_USER"
            value = tostring(var.max_projects_per_user)
          }
          env {
            name  = "SPAWNER_OPENFGA_API_URL"
            value = var.openfga_api_url
          }
          env {
            name  = "SPAWNER_OPENFGA_STORE_ID"
            value = var.openfga_store_id
          }
          env {
            name  = "SPAWNER_OPENFGA_AUTH_MODEL_ID"
            value = var.openfga_auth_model_id
          }
          env {
            name  = "SPAWNER_DEV_FALLBACK_USER"
            value = var.dev_fallback_user
          }
          env {
            name  = "LOG_LEVEL"
            value = var.log_level
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.runtime.metadata[0].name
            }
          }

          dynamic "env" {
            for_each = var.extra_env
            content {
              name  = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8080
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 30
            failure_threshold = 3
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding.spawner,
    kubernetes_job.db_create,
  ]
}

# =====================================================================
# Service (oauth2-proxy upstream) + HTTPRoute for the hub URL
# =====================================================================

resource "kubernetes_service" "spawner" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = var.release_name
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}
