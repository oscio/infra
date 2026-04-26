output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "service_account" {
  value = kubernetes_service_account.hermes.metadata[0].name
}

output "webui_service_name" {
  description = "ClusterIP Service name for the WebUI (used by oauth2-proxy upstream)."
  value       = var.create_service ? kubernetes_service.webui[0].metadata[0].name : ""
}

output "webui_service_port" {
  description = "Port on the WebUI Service (80 maps to container port 8787)."
  value       = 80
}

output "webui_service_dns" {
  description = "In-cluster DNS for the WebUI Service."
  value       = var.create_service ? "${kubernetes_service.webui[0].metadata[0].name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local" : ""
}

output "agent_service_dns" {
  description = "In-cluster DNS for the Hermes Agent gateway (port 8642 behind Service port 80)."
  value       = var.create_service ? "${kubernetes_service.agent[0].metadata[0].name}.${kubernetes_namespace.this.metadata[0].name}.svc.cluster.local" : ""
}
