output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "staging_issuer_name" {
  description = "Name of the letsencrypt-staging ClusterIssuer. Empty string if issuers weren't created."
  value       = local.create_issuers ? "letsencrypt-staging" : ""
}

output "prod_issuer_name" {
  description = "Name of the letsencrypt-prod ClusterIssuer. Empty string if issuers weren't created."
  value       = local.create_issuers ? "letsencrypt-prod" : ""
}

output "wildcard_certificate_secret_name" {
  description = "Secret name holding the wildcard cert. Feed this into the Traefik module's gateway_tls_secret_name."
  value       = var.wildcard_certificate_enabled ? var.wildcard_certificate_secret_name : ""
}

output "wildcard_certificate_namespace" {
  value = var.wildcard_certificate_enabled ? var.wildcard_certificate_namespace : ""
}

output "selfsigned_ca_issuer_name" {
  description = "Name of the 'selfsigned-ca' ClusterIssuer backed by the internal CA. Empty string if selfsigned_enabled = false."
  value       = local.create_selfsigned ? "selfsigned-ca" : ""
}

output "selfsigned_ca_secret_name" {
  description = "Name of the Secret holding the internal CA key+cert (in the cert-manager namespace). Extract ca.crt from it to install as a trusted root on client machines."
  value       = local.create_selfsigned ? "platform-root-ca" : ""
}
