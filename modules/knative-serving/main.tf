terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
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
    # Drop the namespace segment from the auto-generated URL so each
    # Knative Service's external host is `<name>.<domain>` instead of
    # `<name>.<ns>.<domain>`. With every function in the same `resource`
    # namespace the segment was just noise — and the platform-gateway
    # listener is a single-label wildcard (`*.fn.<domain>`), which only
    # matches the shorter form.
    "domain-template" = "{{.Name}}.{{.Domain}}"
  }
  force = true
}

# Allow HTTPRoutes in `resource` (where console-api creates per-function
# routes) to backend-ref the `kourier` Service in `kourier-system`.
# Cross-namespace backend refs require an explicit ReferenceGrant by
# the Gateway API spec.
resource "kubectl_manifest" "kourier_reference_grant" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "function-routes-to-kourier"
      namespace = "kourier-system"
    }
    spec = {
      from = [
        {
          group     = "gateway.networking.k8s.io"
          kind      = "HTTPRoute"
          namespace = var.function_namespace
        },
      ]
      to = [
        {
          group = ""
          kind  = "Service"
          name  = "kourier"
        },
      ]
    }
  })
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

# Knative resolves `image: foo:tag` to a digest before scheduling, by
# making an HTTPS HEAD against the registry. Self-signed Harbor in
# the dev cluster makes that round-trip fail with x509:unknown-authority,
# so registries listed here are exempt from the resolution step. The
# kubelet still pulls (over its own host trust path).
resource "kubernetes_config_map_v1_data" "config_deployment" {
  metadata {
    name      = "config-deployment"
    namespace = var.namespace
  }
  data = {
    "registries-skipping-tag-resolving" = var.registries_skipping_tag_resolving
  }
  force = true
}
