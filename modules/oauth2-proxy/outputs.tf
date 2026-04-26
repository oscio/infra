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
