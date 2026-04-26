terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ---------------------------------------------------------------------------
# platform-dns — patches CoreDNS so in-cluster DNS resolves the platform
# domain to the in-cluster gateway.
#
# Why: with Docker Desktop (and most single-node clusters), the platform's
# public hostnames (e.g. auth.dev.openschema.io) resolve via the *host's*
# /etc/hosts to 127.0.0.1. That mapping is fine for the user's browser, but
# inside the cluster `127.0.0.1` is the pod itself → connection refused.
#
# This module adds a CoreDNS rewrite rule so *.<platform_domain> answers with
# <gateway_service>.<gateway_namespace>.svc.cluster.local, i.e. traffic from
# pods goes directly to the gateway Service (Traefik in our setup).
#
# Scheme:
#   rewrite name regex (.+\.dev\.openschema\.io) traefik.platform-traefik.svc.cluster.local answer auto
#
# The `answer auto` piece rewrites the answer back to the original question
# name so callers still see 'auth.dev.openschema.io' in DNS responses (TLS
# certs validate correctly).
#
# Resources:
#   * kubernetes_config_map_v1_data patches the CoreDNS Corefile in place.
#   * The rollout restart of the CoreDNS Deployment picks up the change.
# ---------------------------------------------------------------------------

locals {
  # Start from the stock Corefile shape that Docker Desktop / kubeadm /
  # kind / k3d ship. We splice a `template` block in *before* 'kubernetes'
  # so CoreDNS answers platform hostnames with CNAMEs pointing at the
  # in-cluster gateway Service, and falls through to 'kubernetes' / upstream
  # forward for everything else.
  #
  # We use the `template` plugin (ships with CoreDNS) rather than
  # `rewrite` because rewrite's behaviour with `forward` downstream is
  # surprisingly unreliable under Docker Desktop — upstream often answers
  # before the rewrite applies. `template` synthesizes the answer locally,
  # so there's no race.
  target_fqdn = "${var.gateway_service_name}.${var.gateway_service_namespace}.svc.cluster.local."
  domain_re   = "^(.+)\\.${replace(var.platform_domain, ".", "\\.")}\\.$"

  corefile = <<-EOT
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        template IN A ${var.platform_domain} {
          match ${local.domain_re}
          answer "{{ .Name }} 5 IN CNAME ${local.target_fqdn}"
          fallthrough
        }
        template IN AAAA ${var.platform_domain} {
          match ${local.domain_re}
          answer "{{ .Name }} 5 IN CNAME ${local.target_fqdn}"
          fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
  EOT
}

# Overwrite the Corefile in the CoreDNS ConfigMap. We use the dedicated
# config_map_v1_data resource so Terraform only manages the 'Corefile' key
# and leaves the rest of the ConfigMap (annotations, other keys) untouched.
resource "kubernetes_config_map_v1_data" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  data = {
    Corefile = local.corefile
  }

  force = true
}

# Rolling-restart CoreDNS to pick up the new Corefile. The 'reload' plugin in
# CoreDNS usually handles this, but a forced restart guarantees the change
# lands within a few seconds (and surfaces syntax errors immediately).
resource "kubernetes_annotations" "coredns_restart" {
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  annotations = {
    "agent-platform/coredns-corefile-revision" = sha1(local.corefile)
  }

  template_annotations = {
    "agent-platform/coredns-corefile-revision" = sha1(local.corefile)
  }

  force = true

  depends_on = [kubernetes_config_map_v1_data.coredns]
}
