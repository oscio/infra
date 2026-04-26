output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "release_name" {
  value = helm_release.argocd.name
}

output "hostname" {
  value = var.hostname
}

output "server_url" {
  value = "https://${var.hostname}"
}
