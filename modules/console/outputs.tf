output "namespace" {
  description = "Namespace the console runs in."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "web_service_name" {
  description = "ClusterIP Service name for the Next.js web pod."
  value       = kubernetes_service.web.metadata[0].name
}

output "api_service_name" {
  description = "ClusterIP Service name for the NestJS api pod."
  value       = kubernetes_service.api.metadata[0].name
}

output "public_url" {
  description = "Public URL the Gateway routes to web."
  value       = "${var.tls_enabled ? "https" : "http"}://${var.hostname}"
}
