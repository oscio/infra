terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# ---------------------------------------------------------------------------
# Hermes = one StatefulSet with two containers sharing a PVC:
#   * agent  — nousresearch/hermes-agent    (root user, HERMES_HOME=/opt/data)
#   * webui  — ghcr.io/nesquena/hermes-webui (hermeswebuitoo user, /apptoo/.hermes)
#
# Each image ships its own entrypoint + userspace conventions; this module
# does NOT override the entrypoint or runAsUser. We only:
#   1. Mount a shared PVC at BOTH images' HERMES_HOME paths so they see the
#      same config/sessions/skills.
#   2. Inject env for ports, default model/provider, LLM API keys, webui pw.
#   3. Expose Services for in-cluster access; the oauth2-proxy module
#      (configured in the cluster composition layer) fronts the webui
#      publicly with Keycloak SSO.
#
# Neither image's upstream has a strong k8s-native deployment story yet,
# so treat this as a best-effort dev harness — be prepared to iterate when
# entrypoint/path conventions change in a future image release.
# ---------------------------------------------------------------------------

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "hermes"
  }

  # Where each image expects HERMES_HOME. Mounting the same PVC at both
  # paths lets the two containers share sessions/skills/memory.
  agent_home_path = "/opt/data"              # per nousresearch/hermes-agent Dockerfile
  webui_home_path = "/apptoo/.hermes"        # per ghcr.io/nesquena/hermes-webui Dockerfile
  webui_workspace = "/apptoo/workspace"

  # The webui imports Hermes agent modules via sys.path — it expects the
  # agent source tree at /home/hermeswebui/.hermes/hermes-agent (standard
  # two-container compose layout). We stage it with an initContainer that
  # copies /opt/hermes from the agent image into an emptyDir volume shared
  # with the webui. Without this the webui logs:
  #   "AIAgent not available -- check that hermes-agent is on sys.path"
  # and falls back to reduced functionality (no chat).
  agent_src_path_in_webui = "/home/hermeswebui/.hermes/hermes-agent"
}

resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# =====================================================================
# Secrets
# =====================================================================

resource "kubernetes_secret" "llm_keys" {
  count = length(var.llm_api_keys) == 0 ? 0 : 1

  metadata {
    name      = "${var.release_name}-llm-keys"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  type = "Opaque"
  data = var.llm_api_keys
}

resource "kubernetes_secret" "webui_password" {
  count = var.webui_password == "" ? 0 : 1

  metadata {
    name      = "${var.release_name}-webui-password"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  type = "Opaque"
  data = {
    "password" = var.webui_password
  }
}

# =====================================================================
# ServiceAccount + optional RBAC (for dispatching DevPod CRs)
# =====================================================================

resource "kubernetes_service_account" "hermes" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_role" "devpod_dispatch" {
  count = var.cluster_access_enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}-devpod-dispatch"
    namespace = var.devpods_namespace
    labels    = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "configmaps"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["agentplatform.io"]
    resources  = ["devpods"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "devpod_dispatch" {
  count = var.cluster_access_enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}-devpod-dispatch"
    namespace = var.devpods_namespace
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.devpod_dispatch[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.hermes.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

# =====================================================================
# StatefulSet (agent + webui containers, shared PVC)
# =====================================================================

resource "kubernetes_stateful_set_v1" "hermes" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    service_name = var.release_name
    replicas     = 1

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
        service_account_name = kubernetes_service_account.hermes.metadata[0].name

        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secret == "" ? [] : [1]
          content {
            name = var.image_pull_secret
          }
        }

        # No pod-level securityContext — both images ship their own User
        # directive. Overriding UID breaks webui's whoami-based init and
        # the agent's root-only setup paths.

        # --- initContainer: stage agent source for webui ---
        # The agent image has its source at /opt/hermes (layer content).
        # We copy it into a shared emptyDir so the webui can pip-install
        # it from /home/hermeswebui/.hermes/hermes-agent at startup.
        # Use a plain `cp -a` to preserve permissions/timestamps; the
        # webui init runs uv pip install against this path.
        init_container {
          name              = "copy-agent-src"
          image             = var.agent_image
          image_pull_policy = var.image_pull_policy
          command           = ["sh", "-c"]
          args = [
            "set -eu; if [ -f /dst/pyproject.toml ]; then echo 'agent source already staged, skipping'; else echo 'copying /opt/hermes -> /dst'; cp -a /opt/hermes/. /dst/; fi; ls /dst | head",
          ]
          volume_mount {
            name       = "agent-src"
            mount_path = "/dst"
          }
        }

        # --- Agent container (nousresearch/hermes-agent) ---
        container {
          name              = "agent"
          image             = var.agent_image
          image_pull_policy = var.image_pull_policy

          # Don't override command (entrypoint = tini -> entrypoint.sh).
          # args are passed to `hermes <args>` by the entrypoint script.
          # `gateway run` starts the long-running gateway process so the pod
          # stays up (otherwise the default interactive REPL exits with no
          # TTY attached).
          args = ["gateway", "run"]

          port {
            name           = "agent"
            container_port = 8642
          }

          env {
            name  = "HERMES_HOME"
            value = local.agent_home_path
          }
          env {
            name  = "HERMES_DEFAULT_MODEL"
            value = var.default_model
          }
          env {
            name  = "HERMES_DEFAULT_PROVIDER"
            value = var.default_provider
          }

          dynamic "env" {
            for_each = var.extra_agent_env
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env_from" {
            for_each = length(var.llm_api_keys) == 0 ? [] : [1]
            content {
              secret_ref {
                name = kubernetes_secret.llm_keys[0].metadata[0].name
              }
            }
          }

          resources {
            requests = {
              cpu    = var.agent_cpu_request
              memory = var.agent_memory_request
            }
            limits = {
              cpu    = var.agent_cpu_limit
              memory = var.agent_memory_limit
            }
          }

          volume_mount {
            name       = "hermes-home"
            mount_path = local.agent_home_path
          }
        }

        # --- WebUI container (ghcr.io/nesquena/hermes-webui) ---
        container {
          name              = "webui"
          image             = var.webui_image
          image_pull_policy = var.image_pull_policy

          # Default CMD = /hermeswebui_init.bash — don't override.

          port {
            name           = "webui"
            container_port = 8787
          }

          env {
            name  = "HERMES_WEBUI_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "HERMES_WEBUI_PORT"
            value = "8787"
          }
          env {
            name  = "HERMES_WEBUI_STATE_DIR"
            value = "${local.webui_home_path}/webui"
          }
          env {
            name  = "HERMES_WEBUI_DEFAULT_WORKSPACE"
            value = local.webui_workspace
          }
          env {
            name  = "HERMES_HOME"
            value = local.webui_home_path
          }
          # Point the webui's config.py agent discovery at the staged source.
          # Redundant (config.py also probes the same path) but explicit is safer.
          env {
            name  = "HERMES_WEBUI_AGENT_DIR"
            value = local.agent_src_path_in_webui
          }

          dynamic "env" {
            for_each = var.extra_webui_env
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = var.webui_password == "" ? [] : [1]
            content {
              name = "HERMES_WEBUI_PASSWORD"
              value_from {
                secret_key_ref {
                  name = kubernetes_secret.webui_password[0].metadata[0].name
                  key  = "password"
                }
              }
            }
          }

          resources {
            requests = {
              cpu    = var.webui_cpu_request
              memory = var.webui_memory_request
            }
            limits = {
              cpu    = var.webui_cpu_limit
              memory = var.webui_memory_limit
            }
          }

          # Mount the shared PVC at the webui's HERMES_HOME. The webui's
          # init script chowns files to its built-in user, so the PVC
          # contents end up owned by hermeswebuitoo. The agent container
          # runs as root so it can read/write regardless.
          volume_mount {
            name       = "hermes-home"
            mount_path = local.webui_home_path
          }

          volume_mount {
            name       = "workspace"
            mount_path = local.webui_workspace
          }

          volume_mount {
            name       = "agent-src"
            mount_path = local.agent_src_path_in_webui
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8787
            }
            period_seconds    = 5
            failure_threshold = 60
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8787
            }
            period_seconds = 10
          }
          liveness_probe {
            tcp_socket {
              port = 8787
            }
            period_seconds    = 30
            failure_threshold = 3
          }
        }

        # Pod-level emptyDir that the initContainer populates with the
        # agent source tree; the webui container mounts the same volume at
        # /home/hermeswebui/.hermes/hermes-agent.
        volume {
          name = "agent-src"
          empty_dir {}
        }
      }
    }

    # Shared home PVC — both containers mount this at the path each image
    # expects for HERMES_HOME. Same underlying volume, two mountpoints.
    volume_claim_template {
      metadata {
        name = "hermes-home"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class == "" ? null : var.storage_class
        resources {
          requests = {
            storage = var.storage_size
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "workspace"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class == "" ? null : var.storage_class
        resources {
          requests = {
            storage = var.workspace_storage_size
          }
        }
      }
    }
  }
}

# =====================================================================
# Services (cluster-internal; oauth2-proxy fronts the webui publicly)
# =====================================================================

resource "kubernetes_service" "webui" {
  count = var.create_service ? 1 : 0

  metadata {
    name      = "${var.release_name}-webui"
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
      target_port = 8787
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_service" "agent" {
  count = var.create_service ? 1 : 0

  metadata {
    name      = "${var.release_name}-agent"
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
      target_port = 8642
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}
