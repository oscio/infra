output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "release_name" {
  value = helm_release.oauth2_proxy.name
}

output "hostname" {
  value = var.hostname
}

output "internal_service_url" {
  description = "Cluster-internal oauth2-proxy URL. Use in ingress auth-url annotations."
  value       = "http://${helm_release.oauth2_proxy.name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}

output "forward_auth_middleware" {
  description = "Identity of the Traefik ForwardAuth Middleware (when forward_auth_enabled). HTTPRoutes attach this via an ExtensionRef filter to gate traffic on a Keycloak login."
  value = var.forward_auth_enabled ? {
    name      = "${var.release_name}-forward-auth"
    namespace = kubernetes_namespace.this.metadata[0].name
  } : null
}
