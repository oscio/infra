terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

locals {
  create_issuers    = var.letsencrypt_email != ""
  create_selfsigned = var.selfsigned_enabled
  use_cloudflare    = var.dns_provider == "cloudflare"
  use_http01        = var.dns_provider == "none"

  cloudflare_solver_yaml = yamlencode({
    dns01 = {
      cloudflare = {
        apiTokenSecretRef = {
          name = "cert-manager-cloudflare-token"
          key  = "api-token"
        }
      }
    }
  })

  http01_solver_yaml = yamlencode({
    http01 = {
      ingress = {
        class = "traefik"
      }
    }
  })

  solver_yaml = local.use_cloudflare ? local.cloudflare_solver_yaml : local.http01_solver_yaml

  solver_parsed = yamldecode(local.solver_yaml)

  issuer_staging_manifest = local.create_issuers ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [local.solver_parsed]
      }
    }
  }) : ""

  issuer_prod_manifest = local.create_issuers ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [local.solver_parsed]
      }
    }
  }) : ""

  wildcard_certificate_manifest = var.wildcard_certificate_enabled ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.wildcard_certificate_secret_name
      namespace = var.wildcard_certificate_namespace
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      secretName = var.wildcard_certificate_secret_name
      issuerRef = {
        name = var.wildcard_certificate_issuer
        kind = "ClusterIssuer"
      }
      commonName = var.wildcard_certificate_domain
      dnsNames = [
        var.wildcard_certificate_domain,
        "*.${var.wildcard_certificate_domain}",
      ]
    }
  }) : ""
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "cert-manager"
    }
  }
}

resource "helm_release" "cert_manager" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.chart_version

  timeout = 600
  wait    = true

  values = [
    yamlencode({
      installCRDs = var.install_crds
      global = {
        leaderElection = {
          namespace = var.namespace
        }
      }
      prometheus = {
        enabled = true
      }
    }),
  ]
}

# --- Provider credential Secrets ---

resource "kubernetes_secret" "cloudflare_token" {
  count = local.create_issuers && local.use_cloudflare ? 1 : 0

  metadata {
    name      = "cert-manager-cloudflare-token"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
    }
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type       = "Opaque"
  depends_on = [helm_release.cert_manager]

  lifecycle {
    precondition {
      condition     = var.cloudflare_api_token != ""
      error_message = "cloudflare_api_token is required when dns_provider = 'cloudflare'."
    }
  }
}

# --- ClusterIssuers (staging + prod) ---

resource "kubectl_manifest" "issuer_staging" {
  count = local.create_issuers ? 1 : 0

  yaml_body = local.issuer_staging_manifest

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.cloudflare_token,
  ]
}

resource "kubectl_manifest" "issuer_prod" {
  count = local.create_issuers ? 1 : 0

  yaml_body = local.issuer_prod_manifest

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.cloudflare_token,
  ]
}

# --- Self-signed ClusterIssuer + internal CA ---
#
# Strategy: we bootstrap a self-signed CA once, then use that CA to sign all
# downstream service certificates (wildcard included). Browsers only need to
# trust the CA root once to accept every *.dev.openschema.io cert.
#
# Resources created (in order):
#   1. ClusterIssuer "selfsigned-bootstrap" — SelfSigned type, used only to
#      sign the CA cert below.
#   2. Certificate "platform-root-ca" in cert-manager namespace, isCA=true,
#      signed by the bootstrap issuer. Creates secret "platform-root-ca".
#   3. ClusterIssuer "selfsigned-ca" — CA type, backed by the secret from (2).
#      This is the issuer to use for all platform service certs.

resource "kubectl_manifest" "selfsigned_bootstrap_issuer" {
  count = local.create_selfsigned ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-bootstrap"
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      selfSigned = {}
    }
  })

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "selfsigned_ca_cert" {
  count = local.create_selfsigned ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "platform-root-ca"
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      isCA        = true
      commonName  = "Agent Platform Root CA"
      secretName  = "platform-root-ca"
      duration    = "87600h" # 10 years
      renewBefore = "720h"   # 30 days
      privateKey = {
        algorithm = "RSA"
        size      = 4096
      }
      issuerRef = {
        name  = "selfsigned-bootstrap"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })

  depends_on = [kubectl_manifest.selfsigned_bootstrap_issuer]
}

resource "kubectl_manifest" "selfsigned_ca_issuer" {
  count = local.create_selfsigned ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-ca"
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
      }
    }
    spec = {
      ca = {
        secretName = "platform-root-ca"
      }
    }
  })

  depends_on = [kubectl_manifest.selfsigned_ca_cert]
}

# --- Wildcard certificate ---

resource "kubectl_manifest" "wildcard_certificate" {
  count = var.wildcard_certificate_enabled ? 1 : 0

  yaml_body = local.wildcard_certificate_manifest

  depends_on = [
    kubectl_manifest.issuer_staging,
    kubectl_manifest.issuer_prod,
    kubectl_manifest.selfsigned_ca_issuer,
  ]

  lifecycle {
    precondition {
      condition     = var.wildcard_certificate_domain != ""
      error_message = "wildcard_certificate_domain is required when wildcard_certificate_enabled = true."
    }
    precondition {
      # DNS-01 is required for ACME wildcard, but the selfsigned-ca issuer
      # can sign wildcards without any DNS challenge.
      condition     = !local.use_http01 || var.wildcard_certificate_issuer == "selfsigned-ca"
      error_message = "Wildcard certificates from an ACME issuer require DNS-01. Set dns_provider to 'cloudflare', or use wildcard_certificate_issuer = 'selfsigned-ca'."
    }
  }
}
