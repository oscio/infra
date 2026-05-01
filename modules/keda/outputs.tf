output "namespace" {
  description = "Namespace where KEDA is installed."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}
