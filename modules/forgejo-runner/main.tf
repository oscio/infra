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

  # Toggle is keyed off `registry_host` only — username/password may
  # come from a module output (e.g. harbor-bootstrap) that's unknown at
  # plan time, and `count` can't depend on apply-time values. The Secret
  # body still uses the un-resolved values; if those end up empty the
  # docker config.json just has empty creds (harmless, just no auth).
  has_registry_creds = var.registry_host != ""

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
    RESOLVE_IP=$(echo "$${INPUT}" | jq -r '.PUBLIC_RESOLVE_IP // empty')
    URL="$${PUBLIC_URL:-$${INTERNAL_URL}}"
    CURL_ARGS=(-kfsS --connect-timeout 3 --max-time 10)
    if [ -n "$${RESOLVE_IP}" ] && [ -n "$${PUBLIC_URL}" ]; then
      PUBLIC_HOST=$(echo "$${PUBLIC_URL}" | sed -E 's#^https?://([^/:]+).*#\1#')
      PUBLIC_PORT=$(echo "$${PUBLIC_URL}" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')
      PUBLIC_PORT="$${PUBLIC_PORT:-443}"
      CURL_ARGS+=(--resolve "$${PUBLIC_HOST}:$${PUBLIC_PORT}:$${RESOLVE_IP}")
    fi
    # Retry until Forgejo is up (relevant on fresh cluster). 3 min budget.
    for i in {1..60}; do
      if OUTPUT=$(curl "$${CURL_ARGS[@]}" -u "$${USER}:$${PASS}" \
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
    PUBLIC_RESOLVE_IP  = var.public_resolve_ip
    ADMIN_USER         = var.forgejo_admin_username
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
        file     = ".runner"
        capacity = 2
        # `envs` is propagated into every job container. The runner itself
        # talks to DinD via tcp://127.0.0.1:2375 (set as a container env on
        # the StatefulSet); job containers run in DinD's per-workflow
        # network where 127.0.0.1 is their own loopback. They reach DinD
        # via host.docker.internal — wired up by --add-host below.
        envs = {
          DOCKER_HOST = "tcp://host.docker.internal:2375"
        }
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
        privileged    = false
        force_rebuild = false
        # Add /etc/hosts entry so DOCKER_HOST=tcp://host.docker.internal
        # (set via runner.envs above) resolves to the DinD container from
        # inside any job container, regardless of which per-workflow
        # network DinD parks it in.
        options = "--add-host=host.docker.internal:host-gateway"
      }
      host = {
        workdir_parent = ""
      }
    })
  }
}

# =====================================================================
# StatefulSet: runner + DinD sidecar
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
        # --- Docker-in-Docker sidecar ---
        # forgejo-runner needs a Docker daemon to spawn job containers
        # (e.g. node:20-bookworm for actions/checkout). DinD listens on
        # tcp://127.0.0.1:2375 (pod-local only — never exposed via Service).
        # Privileged is required: rootless DinD has too many edge cases
        # with overlay2 + nested cgroups under k8s. Build-cache caching
        # is handled by `cache-to: type=registry` in workflows, so no
        # dedicated BuildKit sidecar — DinD's built-in buildx is enough.
        container {
          name  = "dind"
          image = var.dind_image
          # Default entrypoint already binds 2375 (TLS controlled by
          # DOCKER_TLS_CERTDIR). Don't pass extra --host args — they're
          # additive and double-bind the same port. --insecure-registry
          # is additive though, and only takes effect when set on dockerd
          # startup (cannot be reconfigured per-image at push time).
          args = concat(
            var.registry_insecure && var.registry_host != "" ? ["--insecure-registry=${var.registry_host}"] : [],
            # docker0 defaults to MTU 1500. On clusters whose pod network
            # has a smaller MTU (k3s/Flannel vxlan: 1450), large packets
            # from build containers get black-holed → "TLS handshake
            # timeout" pulling base images. Match docker0 MTU to the pod
            # eth0 MTU when var.dind_mtu is set.
            var.dind_mtu > 0 ? ["--mtu=${var.dind_mtu}"] : [],
          )
          security_context {
            privileged      = true
            run_as_non_root = false
            run_as_user     = 0
          }
          # Empty cert dir → daemon listens plaintext on tcp://0.0.0.0:2375.
          # Pod network namespace isolates this; 127.0.0.1:2375 from runner.
          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }
          resources {
            requests = { cpu = var.dind_cpu_request, memory = var.dind_memory_request }
            limits   = { cpu = var.dind_cpu_limit, memory = var.dind_memory_limit }
          }
          volume_mount {
            name       = "cache"
            mount_path = "/var/lib/docker"
            sub_path   = "dind"
          }
          liveness_probe {
            exec {
              command = ["docker", "-H", "tcp://127.0.0.1:2375", "info"]
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
              # Wait for DinD sidecar to be ready — forgejo-runner pings
              # docker on startup and bails immediately if it's not up.
              for i in $(seq 1 60); do
                if forgejo-runner --version >/dev/null 2>&1 && \
                   wget -qO- "http://127.0.0.1:2375/_ping" >/dev/null 2>&1; then
                  break
                fi
                sleep 2
              done
              if [ ! -f .runner ]; then
                forgejo-runner register \
                  --no-interactive \
                  --instance "$FORGEJO_INSTANCE_URL" \
                  --token "$FORGEJO_RUNNER_REGISTRATION_TOKEN" \
                  --name "$FORGEJO_RUNNER_NAME"
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
          # forgejo-runner uses Docker to spawn job containers. Point at
          # the DinD sidecar; without this, runner falls back to host mode
          # and Node-based actions (e.g. actions/checkout) fail because
          # the runner image has no `node` binary.
          env {
            name  = "DOCKER_HOST"
            value = "tcp://127.0.0.1:2375"
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

    # Shared cache PVC (DinD image store + runner workspace)
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

