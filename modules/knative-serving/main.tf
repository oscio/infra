terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ---------------------------------------------------------------------------
# Knative Serving — Phase 2 Functions runtime.
#
# **Install is out-of-band**, not via tf. The 80+ raw manifests in the
# upstream serving-crds.yaml + serving-core.yaml + kourier.yaml don't
# play well with the kubectl provider (timeouts, server-side-apply
# conflicts, slow per-manifest reconcile). For now Knative + Kourier
# are installed via plain `kubectl apply -f` from the upstream releases:
#
#   KNATIVE_VERSION=v1.18.0
#   kubectl apply -f https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml
#   kubectl apply -f https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml
#   kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-${KNATIVE_VERSION}/kourier.yaml
#
# What this module *does* manage is the small bit of config that has
# to match the rest of the platform: the ingress-class pointer (so
# Knative knows to route through Kourier) and the public domain that
# auto-generated Service URLs get composed under. Both are upserts on
# pre-existing ConfigMaps the install creates, which is why we use
# kubernetes_config_map_v1_data (server-side patch) instead of a full
# kubernetes_config_map resource.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map_v1_data" "config_network" {
  metadata {
    name      = "config-network"
    namespace = var.namespace
  }
  data = {
    "ingress-class" = "kourier.ingress.networking.knative.dev"
  }
  force = true
}

resource "kubernetes_config_map_v1_data" "config_domain" {
  metadata {
    name      = "config-domain"
    namespace = var.namespace
  }
  data = {
    (var.domain) = ""
  }
  force = true
}
