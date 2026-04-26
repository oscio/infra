output "namespace" {
  description = "Namespace where Postgres is running."
  value       = local.namespace
}

output "service_name" {
  description = "ClusterIP Service name."
  value       = kubernetes_service.this.metadata[0].name
}

output "host" {
  description = "Fully qualified DNS name for in-cluster connections."
  value       = "${kubernetes_service.this.metadata[0].name}.${local.namespace}.svc.cluster.local"
}

output "port" {
  description = "TCP port."
  value       = 5432
}

output "superuser_username" {
  description = "Superuser username."
  value       = var.superuser_username
}

output "superuser_secret_name" {
  description = "Name of the Secret holding POSTGRES_PASSWORD."
  value       = kubernetes_secret.superuser.metadata[0].name
}
