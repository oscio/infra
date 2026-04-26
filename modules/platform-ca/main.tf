terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ---------------------------------------------------------------------------
# platform-ca — distribute the internal CA bundle across namespaces.
#
# Why:
#   All platform services that talk to Keycloak over https:// (oauth2-proxy,
#   argo-cd dex, forgejo oauth client, harbor, hermes, etc.) need to trust
#   the selfsigned-ca that signed the wildcard cert. The CA cert lives in a
#   Secret in the cert-manager namespace; this module copies it as a
#   ConfigMap into every consumer namespace so deployments there can mount
#   it at /etc/ssl/certs/platform-ca.crt and set SSL_CERT_FILE.
#
# Inputs:
#   source_secret_name / source_secret_namespace — the Secret that
#     cert-manager writes the CA into (module.cert_manager has output
#     `selfsigned_ca_secret_name`). Key inside: `ca.crt`.
#   target_namespaces — list of namespaces that should get a ConfigMap copy.
#
# Output:
#   configmap_name — ConfigMap name created in each target namespace. The
#     ConfigMap has one key (`ca.crt`) holding the CA bundle.
# ---------------------------------------------------------------------------

data "kubernetes_secret_v1" "source" {
  metadata {
    name      = var.source_secret_name
    namespace = var.source_secret_namespace
  }
}

# Create the CA ConfigMap in each target namespace. Target namespaces must
# already exist (owned by their respective module). This module only
# creates ConfigMaps — use depends_on in the cluster composition layer to
# order it AFTER the modules that create the namespaces.
resource "kubernetes_config_map" "ca_bundle" {
  for_each = toset(var.target_namespaces)

  metadata {
    name      = var.configmap_name
    namespace = each.value
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "platform-ca"
    }
  }

  data = {
    "ca.crt" = lookup(data.kubernetes_secret_v1.source.data, "ca.crt", "")
  }
}
