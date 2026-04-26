output "namespace" {
  description = "Namespace Keycloak was installed into."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "release_name" {
  description = "Helm release name."
  value       = helm_release.keycloak.name
}

output "hostname" {
  description = "Public Keycloak hostname."
  value       = var.hostname
}

output "issuer_url" {
  description = "OIDC issuer URL for the 'platform' realm. Use this in oauth2-proxy and Argo CD."
  value       = "https://${var.hostname}/realms/platform"
}

output "internal_service_url" {
  description = "Cluster-internal service URL (no TLS, no hostname). Useful for in-cluster clients."
  value       = "http://${helm_release.keycloak.name}-keycloakx-http.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local:8080"
}
