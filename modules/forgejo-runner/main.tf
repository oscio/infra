terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
    external   = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "forgejo-runner"
  }

  has_registry_creds = var.registry_host != "" && var.registry_username != "" && var.registry_password != ""

  # Docker config.json for pushing to Harbor. Mounted at ~/.docker/config.json.
  docker_config_json = local.has_registry_creds ? jsonencode({
    auths = {
      "${var.registry_host}" = {
        auth = base64encode("${var.registry_username}:${var.registry_password}")
      }
    }
  }) : "{}"
}

# =====================================================================
# Fetch a runner registration token from Forgejo admin API
# Runs via `external` data source so the token is available at plan time.
# =====================================================================

data "external" "registration_token" {
  program = ["bash", "-c", <<-EOT
    # The `external` provider hands query keys to the script as a JSON
    # object on stdin (NOT as env vars). Parse with jq up front so the
    # rest of the script reads as if the values were just shell vars.
    set -eo pipefail
    INPUT=$(cat)
    PUBLIC_URL=$(echo "$${INPUT}" | jq -r '.PUBLIC_FORGEJO_URL // empty')
    INTERNAL_URL=$(echo "$${INPUT}" | jq -r '.FORGEJO_URL // empty')
    USER=$(echo "$${INPUT}" | jq -r '.ADMIN_USER')
    PASS=$(echo "$${INPUT}" | jq -r '.ADMIN_PASSWORD')
    URL="$${PUBLIC_URL:-$${INTERNAL_URL}}"
    # Retry until Forgejo is up (relevant on fresh cluster). 3 min budget.
    for i in {1..60}; do
      if OUTPUT=$(curl -fsS -u "$${USER}:$${PASS}" \
        "$${URL}/api/v1/admin/runners/registration-token" 2>/dev/null); then
        # Forgejo returns: {"token": "..."}
        TOKEN=$(echo "$${OUTPUT}" | jq -r '.token')
        jq -nc --arg t "$${TOKEN}" '{"token":$t}'
        exit 0
      fi
      sleep 3
    done
    echo "Failed to fetch Forgejo runner registration token." >&2
    exit 1
  EOT
  ]

  query = {
    FORGEJO_URL        = var.forgejo_url
    PUBLIC_FORGEJO_URL = var.public_forgejo_url
    ADMIN_USER         = var.forgejo_admin_user
    ADMIN_PASSWORD     = var.forgejo_admin_password
  }
}

# =====================================================================
# Secrets
# =====================================================================

resource "kubernetes_secret" "token" {
  metadata {
    name      = "${var.release_name}-token"
    namespace = var.namespace
    labels    = local.labels
  }

  type = "Opaque"
  data = {
    token = data.external.registration_token.result.token
  }
}

resource "kubernetes_secret" "dockerconfig" {
  count = local.has_registry_creds ? 1 : 0

  metadata {
    name      = "${var.release_name}-dockerconfig"
    namespace = var.namespace
    labels    = local.labels
  }

  type = "Opaque"
  data = {
    "config.json" = local.docker_config_json
  }
}

# =====================================================================
# ConfigMap: runner config.yaml
# =====================================================================

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "${var.release_name}-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "config.yaml" = yamlencode({
      log = { level = "info" }
      runner = {
        file           = ".runner"
        capacity       = 2
        envs           = {}
        labels         = var.runner_labels
        fetch_timeout  = "5s"
        fetch_interval = "2s"
      }
      cache = {
        enabled = true
        dir     = "/data/cache"
        host    = ""
        port    = 0
      }
      container = {
        # Docker socket: we point to BuildKit via env in the StatefulSet.
        # Chart handles volume mounts; nothing to set here.
        privileged    = false
        force_rebuild = false
      }
      host = {
        workdir_parent = ""
      }
    })
  }
}

# =====================================================================
# StatefulSet: runner + BuildKit sidecar
# =====================================================================

resource "kubernetes_stateful_set_v1" "runner" {
  metadata {
    name      = var.release_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    service_name = var.release_name
    replicas     = var.replicas

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
        # BuildKit rootless needs a seccomp profile relaxation.
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          fs_group        = 1000
        }

        # --- BuildKit sidecar (rootless) ---
        container {
          name  = "buildkit"
          image = var.buildkit_image
          args = [
            "--addr", "unix:///run/user/1000/buildkit/buildkitd.sock",
            "--addr", "tcp://0.0.0.0:1234",
            "--oci-worker-no-process-sandbox",
          ]
          security_context {
            # Rootless BuildKit still needs a few capabilities.
            run_as_user  = 1000
            run_as_group = 1000
            seccomp_profile {
              type = "Unconfined"
            }
          }
          port {
            name           = "buildkit"
            container_port = 1234
          }
          resources {
            requests = { cpu = var.buildkit_cpu_request, memory = var.buildkit_memory_request }
            limits   = { cpu = var.buildkit_cpu_limit, memory = var.buildkit_memory_limit }
          }
          volume_mount {
            name       = "cache"
            mount_path = "/home/user/.local/share/buildkit"
            sub_path   = "buildkit"
          }
          liveness_probe {
            exec {
              command = ["buildctl", "--addr", "tcp://127.0.0.1:1234", "debug", "workers"]
            }
            period_seconds        = 30
            failure_threshold     = 3
            initial_delay_seconds = 30
          }
        }

        # --- Runner container ---
        container {
          name  = "runner"
          image = var.runner_image

          # Upstream image's default entrypoint is `forgejo-runner` with no
          # args — which just prints help and exits. Wrap with a small sh
          # script that registers (idempotent: skipped if `.runner` already
          # exists) then runs `daemon`. Needs to live in /data because that's
          # where forgejo-runner expects its state.
          command = ["sh", "-c"]
          args = [
            <<-EOT
              set -e
              cd /data
              if [ ! -f .runner ]; then
                forgejo-runner register \
                  --no-interactive \
                  --instance "$FORGEJO_INSTANCE_URL" \
                  --token "$FORGEJO_RUNNER_REGISTRATION_TOKEN" \
                  --name "$FORGEJO_RUNNER_NAME" \
                  --labels docker:docker://node:20-bookworm
              fi
              exec forgejo-runner daemon --config "$CONFIG_FILE"
            EOT
          ]

          env {
            name  = "CONFIG_FILE"
            value = "/etc/forgejo-runner/config.yaml"
          }
          env {
            name  = "FORGEJO_INSTANCE_URL"
            value = var.forgejo_url
          }
          env {
            name = "FORGEJO_RUNNER_REGISTRATION_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.token.metadata[0].name
                key  = "token"
              }
            }
          }
          env {
            name  = "FORGEJO_RUNNER_NAME"
            value = var.release_name
          }
          # Point `docker buildx` / `buildctl` at the sidecar.
          env {
            name  = "BUILDKIT_HOST"
            value = "tcp://127.0.0.1:1234"
          }

          resources {
            requests = { cpu = var.runner_cpu_request, memory = var.runner_memory_request }
            limits   = { cpu = var.runner_cpu_limit, memory = var.runner_memory_limit }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/forgejo-runner"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/data"
            sub_path   = "runner"
          }
          dynamic "volume_mount" {
            for_each = local.has_registry_creds ? [1] : []
            content {
              name       = "dockerconfig"
              mount_path = "/root/.docker"
              read_only  = true
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.config.metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = local.has_registry_creds ? [1] : []
          content {
            name = "dockerconfig"
            secret {
              secret_name = kubernetes_secret.dockerconfig[0].metadata[0].name
              items {
                key  = "config.json"
                path = "config.json"
              }
            }
          }
        }
      }
    }

    # Shared cache PVC (buildkit layer cache + runner workspace)
    volume_claim_template {
      metadata {
        name = "cache"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class == "" ? null : var.storage_class
        resources {
          requests = {
            storage = var.cache_storage_size
          }
        }
      }
    }
  }
}
