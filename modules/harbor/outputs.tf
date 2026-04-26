output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "hostname" {
  value = local.hostname
}

output "url" {
  value = local.public_url
}

output "core_service_name" {
  description = "Name of the Harbor core Service. In-cluster image pulls target this."
  value       = "${var.release_name}-core"
}

output "core_service_dns" {
  description = "Cluster-internal DNS for the core Service."
  value       = "${var.release_name}-core.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}
