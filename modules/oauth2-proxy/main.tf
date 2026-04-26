terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

resource "random_password" "cookie" {
  count   = var.cookie_secret == "" ? 1 : 0
  length  = 32
  special = false
}

locals {
  use_gateway_api = var.gateway_api_enabled
  cookie_secret   = var.cookie_secret != "" ? var.cookie_secret : base64encode(random_password.cookie[0].result)

  # Routing values. We use yamlencode on each branch rather than returning
  # heterogeneous objects (Terraform requires conditional branches to share
  # type signatures; merging YAML strings sidesteps that).
  ingress_values_yaml = local.use_gateway_api ? yamlencode({
    ingress = { enabled = false }
    }) : yamlencode({
    ingress = {
      enabled   = true
      className = var.ingress_class_name
      hostname  = var.hostname
      path      = "/oauth2"
      pathType  = "Prefix"
      tls = var.tls_enabled ? [{
        secretName = "${var.release_name}-tls"
        hosts      = [var.hostname]
      }] : []
      annotations = var.tls_enabled ? {
        "cert-manager.io/cluster-issuer" = var.cert_manager_issuer
      } : {}
    }
  })

  has_upstream = var.protected_hostname != ""
  upstream_url = local.has_upstream ? "http://${var.upstream_service_name}.${var.upstream_service_namespace}.svc.cluster.local:${var.upstream_service_port}/" : ""

  ca_enabled = var.ca_configmap_name != "" || var.ca_source_secret_name != ""
  # The ConfigMap to mount — either an external one provided by the caller,
  # or the one we just synthesized from the CA Secret.
  ca_configmap_effective = var.ca_source_secret_name != "" ? "platform-ca" : var.ca_configmap_name

  base_values = {
    config = {
      clientID     = var.oidc_client_id
      clientSecret = var.oidc_client_secret
      cookieSecret = local.cookie_secret
    }
    extraArgs = concat(
      compact([
      "--provider=keycloak-oidc",
      "--oidc-issuer-url=${var.oidc_issuer_url}",
      "--email-domain=${join(",", var.email_domains)}",
      "--pass-access-token=true",
      "--pass-authorization-header=true",
      # Inject X-Forwarded-User / X-Forwarded-Email into upstream requests.
      # Default flipped to false in oauth2-proxy 7.x — re-enable explicitly
      # so upstream services (e.g. the spawner) can read the user identity.
      "--pass-user-headers=true",
      "--set-authorization-header=true",
      # Also set X-Auth-Request-User / -Email / -Groups on upstream requests
      # (not just on the /oauth2/auth subrequest). This is what the spawner
      # reads (auth_header_user="X-Auth-Request-User" in its config).
      "--set-xauthrequest=true",
      "--skip-provider-button=true",
      "--cookie-secure=true",
      "--cookie-samesite=lax",
      "--scope=openid email profile groups",
      length(var.allowed_groups) > 0 ? "--allowed-group=${join(",", var.allowed_groups)}" : "",
      # When protecting an upstream, oauth2-proxy acts as a reverse proxy.
      local.has_upstream ? "--upstream=${local.upstream_url}" : "",
      local.has_upstream ? "--reverse-proxy=true" : "",
      # Bind listener across all paths rather than just /oauth2 when protecting.
      local.has_upstream ? "--http-address=0.0.0.0:4180" : "",
      # Cookie domain sharing
      var.cookie_domain == "" ? "" : "--cookie-domain=${var.cookie_domain}",
      # Accept requests for the primary protected hostname + any extras
      # (e.g. a spawner hub + wildcard for per-project subdomains).
      local.has_upstream ? "--whitelist-domain=${var.protected_hostname}" : "",
      local.has_upstream ? "--redirect-url=https://${var.protected_hostname}/oauth2/callback" : "",
      ]),
      # Add an extra --whitelist-domain for each entry so ForwardAuth from
      # other hostnames (or wildcard subdomains) can redirect back through
      # oauth2-proxy without being rejected as untrusted.
      [for h in var.extra_whitelist_domains : "--whitelist-domain=${h}"],
    )
    metrics = { enabled = true }
  }

  # CA trust values are rendered as a separate YAML chunk when enabled, to
  # keep terraform's type unification rules happy (we can't have conditional
  # object attributes — we can have conditional YAML strings).
  ca_values_yaml = local.ca_enabled ? yamlencode({
    extraVolumes = [{
      name = "platform-ca"
      configMap = {
        name = local.ca_configmap_effective
        items = [{
          key  = "ca.crt"
          path = "ca.crt"
        }]
      }
    }]
    extraVolumeMounts = [{
      name      = "platform-ca"
      mountPath = "/etc/ssl/certs/platform-ca.crt"
      subPath   = "ca.crt"
      readOnly  = true
    }]
    extraEnv = [{
      name  = "SSL_CERT_FILE"
      value = "/etc/ssl/certs/platform-ca.crt"
    }]
  }) : ""

  base_values_yaml = yamlencode(local.base_values)

  httproute_manifest = local.use_gateway_api ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = var.release_name
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "oauth2-proxy"
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
          path = { type = "PathPrefix", value = "/oauth2" }
        }]
        backendRefs = [{
          name = var.release_name
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
      "agent-platform/component"  = "oauth2-proxy"
    }
  }
}

# Self-hosted CA bundle mirror. When ca_source_secret_name is set, we read
# the CA from its source Secret (typically cert-manager/platform-root-ca)
# and copy it into a ConfigMap in this namespace so the pod can mount it.
# Keeps the dependency graph acyclic — no external ConfigMap required.
data "kubernetes_secret_v1" "ca_source" {
  count = var.ca_source_secret_name == "" ? 0 : 1

  metadata {
    name      = var.ca_source_secret_name
    namespace = var.ca_source_secret_namespace
  }
}

resource "kubernetes_config_map" "ca_bundle" {
  count = var.ca_source_secret_name == "" ? 0 : 1

  metadata {
    name      = "platform-ca"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "oauth2-proxy"
    }
  }

  data = {
    "ca.crt" = lookup(data.kubernetes_secret_v1.ca_source[0].data, "ca.crt", "")
  }
}

resource "helm_release" "oauth2_proxy" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://oauth2-proxy.github.io/manifests"
  chart      = "oauth2-proxy"
  version    = var.chart_version

  timeout = 300
  wait    = true

  values = compact([
    local.base_values_yaml,
    local.ingress_values_yaml,
    local.ca_values_yaml,
    var.extra_values,
  ])

  depends_on = [kubernetes_config_map.ca_bundle]
}

resource "kubectl_manifest" "httproute" {
  count = local.use_gateway_api ? 1 : 0

  yaml_body  = local.httproute_manifest
  depends_on = [helm_release.oauth2_proxy]

  lifecycle {
    precondition {
      condition     = var.gateway_parent_ref != null
      error_message = "gateway_parent_ref is required when gateway_api_enabled = true."
    }
  }
}

# When protecting an upstream, create an additional HTTPRoute that captures
# the protected hostname and routes it entirely to oauth2-proxy. oauth2-proxy
# then forwards authenticated requests to the upstream Service.
resource "kubectl_manifest" "httproute_protected" {
  count = local.use_gateway_api && local.has_upstream ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${var.release_name}-protected"
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "oauth2-proxy"
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
      hostnames = [var.protected_hostname]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          name = var.release_name
          port = 80
        }]
      }]
    }
  })

  depends_on = [helm_release.oauth2_proxy]
}
