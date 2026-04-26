output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "service_account" {
  value = kubernetes_service_account.spawner.metadata[0].name
}

output "service_name" {
  description = "ClusterIP Service (oauth2-proxy upstream target)."
  value       = kubernetes_service.spawner.metadata[0].name
}

output "service_port" {
  value = 80
}

output "service_dns" {
  description = "In-cluster DNS for the spawner Service."
  value       = "${kubernetes_service.spawner.metadata[0].name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}

output "service_namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}
