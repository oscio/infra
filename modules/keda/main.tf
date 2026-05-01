terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ---------------------------------------------------------------------------
# KEDA — event-driven autoscaling. Pairs with Knative Serving for
# scale-to-zero on non-HTTP triggers (cron, queues, custom metrics).
# Knative Serving alone covers HTTP autoscaling; KEDA is what fills in
# Lambda's EventSourceMapping equivalent.
#
# Single chart, ~3 controller pods. CRDs are bundled (the chart sets
# them via crds.install=true by default).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "agent-platform/component" = "keda"
      "app.kubernetes.io/part-of" = "agent-platform"
    }
  }
}

resource "helm_release" "keda" {
  name       = "keda"
  namespace  = kubernetes_namespace_v1.this.metadata[0].name
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.chart_version

  values = [
    yamlencode({
      # Default install: operator + metrics-apiserver + admission-webhooks.
      # Resources are deliberately small for our dev cluster.
      resources = {
        operator = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "1",   memory = "256Mi" }
        }
        metricServer = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "1",   memory = "256Mi" }
        }
      }
    })
  ]
}
