terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

locals {
  use_gateway_api = var.gateway_api_enabled

  # Argo CD's OIDC config goes into the argocd-cm ConfigMap via Helm values.
  # When oidc_root_ca_pem is provided, Argo CD uses it to validate the OIDC
  # provider's TLS cert (required when the issuer is served by a self-signed
  # CA like our dev cluster).
  oidc_config_yaml = var.oidc_root_ca_pem == "" ? yamlencode({
    name            = "Keycloak"
    issuer          = var.oidc_issuer_url
    clientID        = var.oidc_client_id
    clientSecret    = var.oidc_client_secret
    requestedScopes = ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims = {
      groups = { essential = true }
    }
    }) : yamlencode({
    name            = "Keycloak"
    issuer          = var.oidc_issuer_url
    clientID        = var.oidc_client_id
    clientSecret    = var.oidc_client_secret
    requestedScopes = ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims = {
      groups = { essential = true }
    }
    rootCA = var.oidc_root_ca_pem
  })

  # RBAC ConfigMap content. Binds Keycloak groups to built-in Argo CD roles.
  rbac_policy_csv = join("\n", concat(
    [for g in var.rbac_admin_groups : "g, ${g}, role:admin"],
    [for g in var.rbac_readonly_groups : "g, ${g}, role:readonly"],
  ))

  # HA tuning. Both branches have identical keys so the conditional's types match.
  ha_values = var.ha_enabled ? {
    controller     = { replicas = 1 } # application-controller is sharded, not HA-replicated
    server         = { replicas = 2 }
    repoServer     = { replicas = 2 }
    applicationSet = { replicas = 2 }
    redis-ha       = { enabled = true }
    redis          = { enabled = false }
    } : {
    controller     = {}
    server         = {}
    repoServer     = {}
    applicationSet = {}
    redis-ha       = { enabled = false }
    redis          = { enabled = true }
  }

  # Server routing values as a separate YAML string (avoids conditional type
  # mismatch when embedded in base_values).
  server_routing_yaml = local.use_gateway_api ? yamlencode({
    server = {
      ingress = { enabled = false }
    }
    }) : yamlencode({
    server = {
      ingress = {
        enabled          = true
        ingressClassName = var.ingress_class_name
        hostname         = var.hostname
        tls              = var.tls_enabled
        annotations = merge(
          var.tls_enabled ? { "cert-manager.io/cluster-issuer" = var.cert_manager_issuer } : {},
          { "traefik.ingress.kubernetes.io/router.tls" = "true" },
        )
      }
    }
  })

  params_values = {
    "server.insecure" = local.use_gateway_api ? true : false
  }

  base_values = {
    global = {
      domain = var.hostname
    }
    configs = {
      cm = {
        "admin.enabled" = "false" # force OIDC-only after bootstrap
        "url"           = "https://${var.hostname}"
        "oidc.config"   = local.oidc_config_yaml
      }
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv"     = local.rbac_policy_csv
        "scopes"         = "[groups, email]"
      }
      params = local.params_values
      repositories = length(var.source_repos) == 0 ? {} : {
        for idx, url in var.source_repos : "repo-${idx}" => {
          url  = url
          type = "git"
        }
      }
    }
    dex = { enabled = false } # using Argo CD's native OIDC, not Dex
  }

  base_values_yaml = yamlencode(merge(local.base_values, local.ha_values))

  httproute_manifest = local.use_gateway_api ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${var.release_name}-server"
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "argocd"
      }
    }
    spec = {
      parentRefs = [merge(
        {
          name      = var.gateway_parent_ref.name
          namespace = var.gateway_parent_ref.namespace
        },
        var.gateway_parent_ref.sectionName == null ? {} : { sectionName = var.gateway_parent_ref.sectionName },
      )]
      hostnames = [var.hostname]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          name = "${var.release_name}-server"
          port = 80
        }]
      }]
    }
  }) : ""
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "argocd"
    }
  }
}

resource "helm_release" "argocd" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  timeout = 600
  wait    = true

  values = compact([
    local.base_values_yaml,
    local.server_routing_yaml,
    var.extra_values,
  ])
}

resource "kubectl_manifest" "httproute" {
  count = local.use_gateway_api ? 1 : 0

  yaml_body  = local.httproute_manifest
  depends_on = [helm_release.argocd]

  lifecycle {
    precondition {
      condition     = var.gateway_parent_ref != null
      error_message = "gateway_parent_ref is required when gateway_api_enabled = true."
    }
  }
}
