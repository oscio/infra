output "namespace" {
  description = "Namespace monitoring components run in."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "grafana_url" {
  description = "Public Grafana URL."
  value       = "https://${var.hostname}"
}

output "grafana_service_name" {
  description = "In-cluster Grafana Service name (for HTTPRoute backendRefs etc)."
  value       = local.grafana_service_name
}

output "grafana_service_dns" {
  description = "FQDN of the Grafana Service inside the cluster."
  value       = "${local.grafana_service_name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local"
}

output "prometheus_service_url" {
  description = "In-cluster Prometheus URL (used as the Grafana default datasource)."
  value       = local.prometheus_service_url
}

output "loki_gateway_url" {
  description = "In-cluster Loki gateway URL (used as the Grafana Loki datasource and Alloy push target)."
  value       = local.loki_gateway_url
}
