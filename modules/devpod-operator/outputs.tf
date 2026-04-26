output "devpods_namespace" {
  value = kubernetes_namespace.devpods.metadata[0].name
}

output "crd_name" {
  value = "devpods.agentplatform.io"
}

output "crd_group" {
  value = "agentplatform.io"
}

output "operator_installed" {
  value = var.install_operator
}
