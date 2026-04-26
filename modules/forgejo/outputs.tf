output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "hostname" {
  value = local.hostname
}

output "url" {
  value = local.public_url
}

output "service_name_http" {
  description = "ClusterIP Service serving HTTP on :3000."
  value       = "${var.release_name}-http"
}

output "service_dns_http" {
  description = "In-cluster DNS for the HTTP Service."
  value       = "${var.release_name}-http.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}

output "service_name_ssh" {
  description = "Service name for SSH."
  value       = "${var.release_name}-ssh"
}
