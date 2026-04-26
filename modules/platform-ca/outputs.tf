output "configmap_name" {
  description = "Name of the CA ConfigMap placed in each target namespace."
  value       = var.configmap_name
}

output "ca_key" {
  description = "Key inside the ConfigMap that holds the CA PEM."
  value       = "ca.crt"
}
