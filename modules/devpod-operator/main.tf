terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

locals {
  base_labels = {
    "app.kubernetes.io/name"    = "devpod-operator"
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "devpod-operator"
  }
  labels = merge(local.base_labels, var.labels)
}

resource "kubernetes_namespace" "devpods" {
  metadata {
    name   = var.devpods_namespace
    labels = local.labels
  }
}

# =====================================================================
# DevPod CRD
#
# A DevPod is an ephemeral or long-lived development environment pod
# that Hermes (or a human) can dispatch. Interactive by default —
# leave `command` empty and the pod stays alive until TTL. Set `command`
# to run a batch task; when it completes, the operator marks the CR
# Succeeded (and optionally deletes the pod).
# =====================================================================

resource "kubectl_manifest" "crd" {
  count = var.install_crd ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apiextensions.k8s.io/v1"
    kind       = "CustomResourceDefinition"
    metadata = {
      name   = "devpods.agentplatform.io"
      labels = local.labels
    }
    spec = {
      group = "agentplatform.io"
      names = {
        kind       = "DevPod"
        listKind   = "DevPodList"
        plural     = "devpods"
        singular   = "devpod"
        shortNames = ["dp"]
      }
      scope = "Namespaced"
      versions = [{
        name    = "v1alpha1"
        served  = true
        storage = true
        schema = {
          openAPIV3Schema = {
            type        = "object"
            description = "A DevPod is a generic ephemeral dev environment pod."
            required    = ["spec"]
            properties = {
              spec = {
                type     = "object"
                required = ["repo"]
                properties = {
                  repo = {
                    type        = "object"
                    description = "Git repo to clone into the DevPod."
                    required    = ["url"]
                    properties = {
                      url        = { type = "string", description = "Git URL (HTTPS; Forgejo or GitHub)." }
                      branch     = { type = "string", default = "main" }
                      workBranch = { type = "string", description = "Branch the DevPod commits to. Auto-generated if blank." }
                    }
                  }
                  command = {
                    type        = "string"
                    description = "Optional. Empty = interactive (pod stays up). Non-empty = batch (runs command, auto-PR, exits)."
                    default     = ""
                  }
                  user = {
                    type        = "string"
                    description = "Username this DevPod is for (audit trail)."
                  }
                  gitCredentialsSecret = {
                    type        = "string"
                    description = "Name of a Secret in the DevPod namespace holding git push credentials (key: 'token')."
                  }
                  image = {
                    type        = "string"
                    description = "Container image. Defaults to the operator's configured base image."
                  }
                  resources = {
                    type = "object"
                    properties = {
                      cpu    = { type = "string", default = "2" }
                      memory = { type = "string", default = "4Gi" }
                    }
                  }
                  workspaceSize = {
                    type        = "string"
                    description = "PVC size for the workspace volume."
                    default     = "20Gi"
                  }
                  storageClass = {
                    type        = "string"
                    description = "StorageClass for the workspace PVC. Empty = cluster default."
                    default     = ""
                  }
                  ttl = {
                    type        = "string"
                    description = "Idle TTL (Go duration: 1h, 30m, 8h). Pod deleted after this period of no activity."
                    default     = "8h"
                  }
                  exposeCodeServer = {
                    type        = "boolean"
                    description = "Run code-server sidecar and expose via HTTPRoute at devpod-<name>.<domain>."
                    default     = false
                  }
                  tools = {
                    type        = "array"
                    description = "Informational: which tools are expected in the image (claude-code, specify, hermes, git, ...). Image is source of truth."
                    items       = { type = "string" }
                  }
                }
              }
              status = {
                type = "object"
                properties = {
                  phase = {
                    type        = "string"
                    description = "Lifecycle phase."
                    enum        = ["Pending", "Running", "Succeeded", "Failed", "TimedOut"]
                  }
                  pod           = { type = "string", description = "Backing Pod name." }
                  codeServerUrl = { type = "string", description = "Public URL of code-server if exposed." }
                  forgejoPR     = { type = "integer", description = "Forgejo PR number (batch mode, post-run)." }
                  message       = { type = "string", description = "Human-readable status." }
                  startedAt     = { type = "string", format = "date-time" }
                  finishedAt    = { type = "string", format = "date-time" }
                }
              }
            }
          }
        }
        additionalPrinterColumns = [
          { name = "Phase", type = "string", jsonPath = ".status.phase" },
          { name = "User", type = "string", jsonPath = ".spec.user" },
          { name = "Repo", type = "string", jsonPath = ".spec.repo.url" },
          { name = "Pod", type = "string", jsonPath = ".status.pod" },
          { name = "Age", type = "date", jsonPath = ".metadata.creationTimestamp" },
        ]
        subresources = {
          status = {}
        }
      }]
    }
  })
}

# =====================================================================
# Operator ServiceAccount + ClusterRole
# The operator needs to read/write DevPod CRs cluster-wide and manage
# Pods/PVCs/Services/HTTPRoutes in the DevPod namespace.
# =====================================================================

resource "kubernetes_service_account" "operator" {
  count = var.install_operator ? 1 : 0

  metadata {
    name      = "devpod-operator"
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "operator" {
  count = var.install_operator ? 1 : 0

  metadata {
    name   = "devpod-operator"
    labels = local.labels
  }

  rule {
    api_groups = ["agentplatform.io"]
    resources  = ["devpods", "devpods/status"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "persistentvolumeclaims", "secrets", "configmaps", "events"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["httproutes"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "operator" {
  count = var.install_operator ? 1 : 0

  metadata {
    name   = "devpod-operator"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.operator[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.operator[0].metadata[0].name
    namespace = var.namespace
  }
}

# =====================================================================
# Operator Deployment (built separately; image pushed to Harbor).
# CURRENTLY INSTALL-GATED — enable once the operator image is built.
# =====================================================================

resource "kubernetes_deployment" "operator" {
  count = var.install_operator ? 1 : 0

  metadata {
    name      = "devpod-operator"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.operator_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "devpod-operator"
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name = kubernetes_service_account.operator[0].metadata[0].name

        container {
          name              = "operator"
          image             = var.operator_image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "DEVPODS_NAMESPACE"
            value = var.devpods_namespace
          }
          env {
            name  = "DEFAULT_DEVPOD_IMAGE"
            value = var.default_devpod_image
          }
          env {
            name  = "DEFAULT_TTL"
            value = var.default_ttl
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.crd]
}
