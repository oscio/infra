terraform {
  required_providers {
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
  }
}

# =====================================================================
# Keel — registry-polling Deployment auto-updater
# =====================================================================
#
# Why Keel (vs ArgoCD Image Updater): ACDIU's write-back targets are
# Argo CD Applications (helm / kustomize / git). The agent-spawner
# Deployment is managed directly by terraform, not Argo CD, so ACDIU's
# strategies don't apply. Keel's annotation-driven model patches plain
# Deployments / StatefulSets, which is the minimum we need for
# "Forgejo build → Harbor push → spawner auto-rolls".
#
# How it works for us:
#   1. Spawner Deployment carries `keel.sh/policy: force` + `keel.sh/trigger: poll`
#   2. Keel polls Harbor for the configured image's digest every
#      `poll_schedule` (default 1m)
#   3. New digest → Keel patches the Deployment → kubelet rolls the pod
#
# The dockerconfigjson Secret (same one Forgejo Runner uses to push) is
# attached to Keel's ServiceAccount so registry auth is shared.

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "keel"
    }
  }
}

# Mirror the Harbor pull secret into Keel's namespace so the chart can
# reference it. Keel's Secret needs to live in the same namespace as the
# Keel Pod for it to be mountable.
resource "kubernetes_secret_v1" "registry_creds" {
  count = var.harbor_pull_secret_name != "" && var.harbor_pull_secret_namespace != "" ? 1 : 0

  metadata {
    name      = "harbor-pull-secret"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = data.kubernetes_secret_v1.source[0].data[".dockerconfigjson"]
  }
}

data "kubernetes_secret_v1" "source" {
  count = var.harbor_pull_secret_name != "" && var.harbor_pull_secret_namespace != "" ? 1 : 0

  metadata {
    name      = var.harbor_pull_secret_name
    namespace = var.harbor_pull_secret_namespace
  }
}

resource "helm_release" "keel" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://charts.keel.sh"
  chart      = "keel"
  version    = var.chart_version

  timeout = 300
  wait    = true

  values = [yamlencode({
    helmProvider = { enabled = false }  # we use Deployment-annotation mode, not Helm releases
    polling = {
      enabled         = true
      defaultSchedule = var.poll_schedule
    }
    # Mount the registry creds at /secrets and tell Keel to read them
    # there. Keel auto-detects ~/.docker/config.json by default — we
    # symlink the projected file in via the chart's secrets settings.
    secret = var.harbor_pull_secret_name != "" ? {
      name = "harbor-pull-secret"
    } : {}
    rbac = { enabled = true }
    serviceAccount = { create = true }
    # Cluster-wide so Keel can patch Deployments in any namespace
    # (per-project workspace pods live in `hermes-proj-<id>` namespaces).
    namespaces = []
  })]

  depends_on = [
    kubernetes_namespace.this,
    kubernetes_secret_v1.registry_creds,
  ]
}
