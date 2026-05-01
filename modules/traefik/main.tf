terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

locals {
  namespace_name = var.namespace

  base_values = {
    providers = {
      kubernetesGateway = {
        enabled = var.gateway_api_enabled
      }
      kubernetesCRD = {
        enabled             = true
        allowCrossNamespace = true
      }
    }
    gateway = {
      # The chart's built-in Gateway is too opinionated for our needs; we
      # create our own Gateway resource below. Disable the chart's Gateway.
      enabled = false
    }
    gatewayClass = {
      enabled = var.gateway_api_enabled
      name    = var.gateway_class_name
    }
    experimental = {
      kubernetesGateway = {
        enabled = var.gateway_api_enabled
      }
    }
    service = {
      type = var.service_type
    }
    ports = {
      web = merge(
        {
          port        = 8000
          exposedPort = 80
          expose      = { default = true }
          protocol    = "TCP"
          transport = {
            respondingTimeouts = {
              readTimeout       = "${var.entrypoint_timeout_seconds}s"
              writeTimeout      = "${var.entrypoint_timeout_seconds}s"
              idleTimeout       = "${var.entrypoint_timeout_seconds}s"
              readHeaderTimeout = "60s"
            }
          }
        },
        # Permanent 301 to websecure when TLS is on. Skipped without TLS to
        # avoid an infinite 301 loop on plain-HTTP dev clusters. Catches
        # everything at the entryPoint layer, so HTTPRoutes don't have to
        # opt-in per route. Chart schema requires the redirection block to
        # nest under `http`.
        var.tls_enabled ? {
          http = {
            redirections = {
              entryPoint = {
                to        = "websecure"
                scheme    = "https"
                permanent = true
              }
            }
          }
        } : {},
      )
      websecure = {
        port        = 8443
        exposedPort = 443
        expose      = { default = true }
        protocol    = "TCP"
        http = {
          tls = { enabled = var.tls_enabled }
        }
        # Long-running streamed uploads (Harbor docker push, esp. multi-GB
        # workspace images) need the entryPoint to keep the connection
        # open beyond Traefik's 3-minute default. Without this, the
        # backend logs `499 Client Closed Request` mid-push.
        transport = {
          respondingTimeouts = {
            readTimeout       = "${var.entrypoint_timeout_seconds}s"
            writeTimeout      = "${var.entrypoint_timeout_seconds}s"
            idleTimeout       = "${var.entrypoint_timeout_seconds}s"
            readHeaderTimeout = "60s"
          }
        }
      }
    }
    ingressClass = {
      enabled        = true
      isDefaultClass = true
      name           = "traefik"
    }
    logs = {
      general = { level = "INFO" }
      access  = { enabled = true }
    }
    metrics = {
      prometheus = { enabled = true }
    }
  }

  # Traefik Gateway API provider matches listener.port to Traefik entryPoint
  # port (the container-side listen port), NOT the exposed Service port.
  # Our entryPoints are web:8000 and websecure:8443 (see base_values.ports).
  https_listener = length(var.gateway_hostnames) == 0 ? [] : [{
    name     = "https"
    port     = 8443
    protocol = "HTTPS"
    hostname = length(var.gateway_hostnames) == 1 ? var.gateway_hostnames[0] : null
    allowedRoutes = {
      namespaces = { from = "All" }
    }
    tls = var.gateway_tls_secret_name == "" ? null : {
      mode = "Terminate"
      certificateRefs = [{
        kind      = "Secret"
        name      = var.gateway_tls_secret_name
        namespace = local.namespace_name
      }]
    }
  }]

  # Extra HTTPS wildcard listeners (typically deep wildcards the primary
  # '*.dev.openschema.io' listener can't cover, since Gateway API wildcards
  # only match one DNS label). Each entry yields:
  #   - a cert-manager Certificate (see kubectl_manifest.extra_certificate)
  #   - a Gateway listener with its own TLS secretRef
  #
  # `slug` strips the leading wildcard and replaces dots with dashes so we
  # can build a k8s-safe name (Secret + Certificate + listener name). The
  # hostname like "*.vm.dev.openschema.io" becomes:
  #   slug        = "vm-dev-openschema-io"
  #   secret name = "wildcard-vm-dev-openschema-io-tls"
  #   listener    = "https-vm-dev-openschema-io"
  # Extra listeners are keyed by slug so apply/destroy is stable across
  # list reorderings.
  extra_listeners_raw = [
    for h in var.extra_listener_hostnames : {
      hostname    = h
      slug        = replace(replace(h, "*.", ""), ".", "-")
      bare_domain = replace(h, "*.", "")
    }
  ]
  extra_listeners = {
    for l in local.extra_listeners_raw : l.slug => merge(l, {
      secret_name   = "wildcard-${l.slug}-tls"
      listener_name = "https-${l.slug}"
    })
  }

  extra_listener_entries = [
    for slug, l in local.extra_listeners : {
      name     = l.listener_name
      port     = 8443
      protocol = "HTTPS"
      hostname = l.hostname
      allowedRoutes = {
        namespaces = { from = "All" }
      }
      tls = {
        mode = "Terminate"
        certificateRefs = [{
          kind      = "Secret"
          name      = l.secret_name
          namespace = local.namespace_name
        }]
      }
    }
  ]

  gateway_manifest = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = local.namespace_name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "gateway"
      }
    }
    spec = {
      gatewayClassName = var.gateway_class_name
      listeners = concat(
        [{
          name     = "http"
          port     = 8000
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        }],
        local.https_listener,
        local.extra_listener_entries,
      )
    }
  })
}

resource "kubernetes_namespace" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = local.namespace_name
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "traefik"
    }
  }
}

resource "helm_release" "traefik" {
  name       = var.release_name
  namespace  = local.namespace_name
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.chart_version

  timeout = 600
  wait    = true

  values = compact([
    yamlencode(local.base_values),
    var.extra_values,
  ])

  depends_on = [kubernetes_namespace.this]
}

# Per-hostname wildcard Certificates (cert-manager) for extra listeners.
# Signed by the user-provided ClusterIssuer (same as the primary wildcard's).
# The resulting Secret matches `extra_listeners[*].secret_name` and is
# referenced by the corresponding Gateway listener's tls.certificateRefs.
resource "kubectl_manifest" "extra_certificate" {
  for_each = local.extra_listeners

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = each.value.secret_name
      namespace = local.namespace_name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "gateway"
      }
    }
    spec = {
      secretName = each.value.secret_name
      issuerRef = {
        name = var.cert_manager_issuer
        kind = "ClusterIssuer"
      }
      commonName = each.value.bare_domain
      dnsNames = [
        each.value.bare_domain,
        each.value.hostname, # e.g. "*.vm.dev.openschema.io"
      ]
    }
  })

  depends_on = [helm_release.traefik]

  lifecycle {
    precondition {
      condition     = var.cert_manager_issuer != ""
      error_message = "cert_manager_issuer must be set when extra_listener_hostnames is non-empty."
    }
  }
}

# Shared Gateway resource all HTTPRoutes attach to via parentRefs.
resource "kubectl_manifest" "gateway" {
  count = var.gateway_api_enabled ? 1 : 0

  yaml_body = local.gateway_manifest
  depends_on = [
    helm_release.traefik,
    kubectl_manifest.extra_certificate,
  ]
}
