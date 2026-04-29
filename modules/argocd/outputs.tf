output "namespace" {
  description = "Argo CD namespace."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "url" {
  description = "Externally-reachable Argo CD URL."
  value       = "https://${var.hostname}"
}

output "server_service_name" {
  description = "Name of argocd-server Service (for in-cluster callers)."
  value       = "${var.release_name}-server"
}

output "server_service_dns" {
  description = "Fully-qualified DNS for argocd-server, in-cluster."
  value       = "${var.release_name}-server.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}
