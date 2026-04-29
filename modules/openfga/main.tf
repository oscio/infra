terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# ---------------------------------------------------------------------------
# OpenFGA — Zanzibar-style authorization engine for the platform.
#
# Deployment shape (dev):
#   1. Namespace platform-openfga
#   2. db-create Job (psql) — ensures DATABASE + ROLE exist in the shared
#      platform-infra Postgres. Idempotent (IF NOT EXISTS).
#   3. db-migrate Job — runs `openfga migrate` before the server rollout.
#   4. Helm release openfga/openfga with Postgres backend.
#   5. bootstrap Job (openfga/cli) — waits for HTTP API, creates the store
#      with the authz model, writes {store_id, auth_model_id, api_url}
#      into a Kubernetes Secret so downstream consumers (e.g. console) can
#      pick them up.
#
# The bootstrap Job is a one-shot: it skips if the target Secret already
# exists. To re-bootstrap (e.g. after model changes), delete the Secret
# and the Job, then re-apply.
# ---------------------------------------------------------------------------

locals {
  labels = {
    "app.kubernetes.io/part-of"  = "agent-platform"
    "app.kubernetes.io/name"     = var.release_name
    "app.kubernetes.io/instance" = var.release_name
    "agent-platform/component"   = "openfga"
  }

  # Postgres URI for OpenFGA itself (reads/writes tuples + models).
  # OpenFGA supports postgres://user:pass@host:port/db?sslmode=disable
  pg_uri = "postgres://${var.openfga_db_username}:${var.openfga_db_password}@${var.postgres_host}:${var.postgres_port}/${var.openfga_db_name}?sslmode=disable"

  # OpenFGA helm chart 0.3.x creates a single Service named `<release>` (no
  # `-http` suffix) exposing HTTP 8080 alongside gRPC 8081 and playground 3000.
  http_service_name = var.release_name
  http_service_dns  = "${local.http_service_name}.${var.namespace}.svc.cluster.local"
  http_api_url      = "http://${local.http_service_dns}:8080"
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# ---------------------------------------------------------------------------
# Secret — OpenFGA's Postgres DSN. Mounted by the OpenFGA pod via
# datastore.uriSecret. Also used by the db-create Job.
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "datastore" {
  metadata {
    name      = "${var.release_name}-datastore"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    # Chart key that datastore.uriSecret reads.
    uri = local.pg_uri
    # Convenience fields for the bootstrap Job / humans.
    POSTGRES_HOST     = var.postgres_host
    POSTGRES_PORT     = tostring(var.postgres_port)
    POSTGRES_DB       = var.openfga_db_name
    POSTGRES_USER     = var.openfga_db_username
    POSTGRES_PASSWORD = var.openfga_db_password
  }
}

# Superuser secret used ONLY by the db-create Job. Not mounted into the
# OpenFGA pod.
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

# ---------------------------------------------------------------------------
# db-create Job: idempotently create the openfga DB + role in the shared
# Postgres. Runs once per apply (name is stable; kubectl_manifest replaces
# it on changes).
# ---------------------------------------------------------------------------
locals {
  db_create_sql = <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${var.openfga_db_username}') THEN
        CREATE ROLE ${var.openfga_db_username} LOGIN PASSWORD '${var.openfga_db_password}';
      ELSE
        ALTER ROLE ${var.openfga_db_username} WITH LOGIN PASSWORD '${var.openfga_db_password}';
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
      echo "[db-create] ensuring role '${var.openfga_db_username}' exists..."
      psql -v ON_ERROR_STOP=1 -f /sql/create-role.sql
      echo "[db-create] ensuring database '${var.openfga_db_name}' exists..."
      if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${var.openfga_db_name}'" | grep -q 1; then
        psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${var.openfga_db_name} OWNER ${var.openfga_db_username};"
      else
        echo "[db-create] database already exists, skipping CREATE."
      fi
      psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${var.openfga_db_name} TO ${var.openfga_db_username};"
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
          image   = var.psql_image
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

  depends_on = [
    kubernetes_secret.pg_super,
    kubernetes_config_map.db_create,
  ]
}

# ---------------------------------------------------------------------------
# db-migrate Job: OpenFGA won't report ready until its datastore schema is at
# the binary's expected revision. Run this explicitly before Helm waits on the
# Deployment so a fresh database doesn't deadlock the release rollout.
# ---------------------------------------------------------------------------
resource "kubernetes_job" "db_migrate" {
  metadata {
    name      = "${var.release_name}-db-migrate"
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
          name    = "migrate"
          image   = "${var.image_repository}:${var.image_tag}"
          command = ["/openfga", "migrate"]

          env {
            name  = "OPENFGA_DATASTORE_ENGINE"
            value = "postgres"
          }

          env {
            name = "OPENFGA_DATASTORE_URI"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.datastore.metadata[0].name
                key  = "uri"
              }
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

  depends_on = [
    kubernetes_job.db_create,
    kubernetes_secret.datastore,
  ]
}

# ---------------------------------------------------------------------------
# Helm release: openfga/openfga with Postgres backend.
# Migrations are handled by kubernetes_job.db_migrate above. Keeping them out
# of the chart avoids a fresh-database rollout where the pod waits for
# migrations while Helm waits for the pod.
# ---------------------------------------------------------------------------
locals {
  openfga_values = yamlencode({
    replicaCount = var.replicas

    image = {
      repository = var.image_repository
      tag        = var.image_tag
      pullPolicy = "IfNotPresent"
    }

    datastore = {
      engine            = "postgres"
      uriSecret         = kubernetes_secret.datastore.metadata[0].name
      applyMigrations   = false
      # waitForMigrations=true adds an init container `wait-for-migration`
      # that calls `kubectl wait job/openfga-migrate` — but the migrate
      # job is a pre-install Helm hook that gets garbage-collected after
      # completion, so the init container loops forever looking for it.
      # Turn it off: the pre-install hook is synchronous relative to Helm
      # install, so by the time the Deployment rolls out the DB is already
      # migrated.
      waitForMigrations = false
      migrationType     = "job"
    }

    # Disable the deprecated bundled subcharts — we use the shared platform PG.
    postgresql = { enabled = false }
    mysql      = { enabled = false }

    playground = {
      enabled = var.playground_enabled
      port    = 3000
    }

    service = {
      type = "ClusterIP"
      port = 8080
    }

    http = {
      enabled = true
      addr    = "0.0.0.0:8080"
    }

    grpc = {
      addr = "0.0.0.0:8081"
    }

    log = {
      level  = "info"
      format = "json"
    }

    resources = var.resources

    # No ingress — consumers reach OpenFGA via cluster DNS.
    ingress = { enabled = false }

    # Telemetry — leave metrics on (scraped only if Prometheus is present).
    telemetry = {
      metrics = {
        enabled        = true
        serviceMonitor = { enabled = false }
      }
    }
  })
}

resource "helm_release" "openfga" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://openfga.github.io/helm-charts"
  chart      = "openfga"
  version    = var.chart_version

  timeout = 600
  wait    = true

  values = [local.openfga_values]

  depends_on = [
    kubernetes_job.db_migrate,
    kubernetes_secret.datastore,
  ]
}

# ---------------------------------------------------------------------------
# Bootstrap Job: create the store with the authz model via the openfga/cli
# container, then write store_id + auth_model_id into a Kubernetes Secret
# so downstream consumers can pick them up.
#
# Requires a ServiceAccount with permission to get/create Secrets in its
# own namespace (to check-and-create the target bootstrap Secret).
# ---------------------------------------------------------------------------

resource "kubernetes_service_account" "bootstrap" {
  metadata {
    name      = "${var.release_name}-bootstrap"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_role" "bootstrap" {
  metadata {
    name      = "${var.release_name}-bootstrap"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "bootstrap" {
  metadata {
    name      = "${var.release_name}-bootstrap"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.bootstrap.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.bootstrap.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_config_map" "bootstrap" {
  metadata {
    name      = "${var.release_name}-bootstrap"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  data = {
    "model.fga"     = var.authz_model_fga
    "model.json"    = var.authz_model_json
    "store-name"    = var.store_name
    "bootstrap.sh"  = <<-SH
      #!/bin/sh
      set -eu

      API_URL="${local.http_api_url}"
      SECRET_NAME="${var.bootstrap_secret_name}"
      NS="${var.namespace}"
      STORE_NAME="$(cat /cfg/store-name)"
      MODEL_FILE=/cfg/model.json

      echo "[bootstrap] API_URL=$API_URL  SECRET=***  NS=$NS"

      # Short-circuit: if the secret already has a non-empty store_id,
      # assume we've already bootstrapped — skip.
      if kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
        existing=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.store_id}' 2>/dev/null || true)
        if [ -n "$existing" ]; then
          echo "[bootstrap] Secret $SECRET_NAME already present with store_id — skipping."
          exit 0
        fi
      fi

      echo "[bootstrap] waiting for OpenFGA API to be reachable..."
      for i in $(seq 1 60); do
        if curl -fsS "$API_URL/healthz" >/dev/null 2>&1 || curl -fsS "$API_URL/stores" >/dev/null 2>&1; then
          echo "[bootstrap] API responding."
          break
        fi
        echo "  ...($i/60) not ready yet"
        sleep 2
      done

      echo "[bootstrap] creating store '$STORE_NAME'..."
      store_out=$(curl -fsS -X POST "$API_URL/stores" -H 'Content-Type: application/json' -d "{\"name\":\"$STORE_NAME\"}")
      echo "[bootstrap] store response: $store_out"
      store_id=$(echo "$store_out" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
      if [ -z "$store_id" ]; then
        echo "[bootstrap] ERROR: failed to parse store_id" >&2
        exit 1
      fi
      echo "[bootstrap] store_id=$store_id"

      echo "[bootstrap] writing authorization model..."
      model_out=$(curl -fsS -X POST "$API_URL/stores/$store_id/authorization-models" -H 'Content-Type: application/json' -d @"$MODEL_FILE")
      echo "[bootstrap] model response: $model_out"
      model_id=$(echo "$model_out" | sed -n 's/.*"authorization_model_id":"\([^"]*\)".*/\1/p')
      if [ -z "$model_id" ]; then
        echo "[bootstrap] ERROR: failed to parse model_id" >&2
        exit 1
      fi

      echo "[bootstrap] store_id=$store_id  model_id=$model_id"

      kubectl -n "$NS" create secret generic "$SECRET_NAME" \
        --from-literal=store_id="$store_id" \
        --from-literal=auth_model_id="$model_id" \
        --from-literal=api_url="$API_URL" \
        --from-literal=store_name="$STORE_NAME" \
        --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

      echo "[bootstrap] done — Secret $SECRET_NAME populated."
    SH
  }
}

resource "kubernetes_job" "bootstrap" {
  metadata {
    name      = "${var.release_name}-bootstrap"
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
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.bootstrap.metadata[0].name

        # Single container: alpine/k8s bundles kubectl + sh + curl in one
        # non-Bitnami image, so no initContainer / shared volume required.
        # The bootstrap script talks directly to the OpenFGA HTTP API with
        # curl and writes the result Secret with kubectl.
        container {
          name    = "bootstrap"
          image   = var.bootstrap_image
          command = ["/bin/sh", "-c", "sh /cfg/bootstrap.sh"]

          volume_mount {
            name       = "cfg"
            mount_path = "/cfg"
          }
        }

        volume {
          name = "cfg"
          config_map {
            name         = kubernetes_config_map.bootstrap.metadata[0].name
            default_mode = "0755"
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
    helm_release.openfga,
    kubernetes_role_binding.bootstrap,
  ]
}

# Read back the Secret the bootstrap Job wrote, for outputs.
data "kubernetes_secret_v1" "bootstrap" {
  metadata {
    name      = var.bootstrap_secret_name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  depends_on = [kubernetes_job.bootstrap]
}
