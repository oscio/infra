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

# --- In-cluster registry side-channel -----------------------------------------

output "internal_service_cluster_ip" {
  description = "ClusterIP assigned to the `<release>-internal` Service. Image refs can use this IP directly so neither cluster DNS nor /etc/hosts hacks are needed (works from pods via kube-proxy, and from kubelet on the same node)."
  value       = var.internal_service_enabled ? kubernetes_service_v1.internal[0].spec[0].cluster_ip : ""
}

output "internal_service_port" {
  description = "ClusterIP port for the `<release>-internal` Service."
  value       = var.internal_service_port
}

output "internal_url" {
  description = "Pre-formatted `<scheme>://<ip>:<port>` for in-cluster consumers (image refs, build CI HARBOR env). Empty when internal_service_enabled = false."
  value       = var.internal_service_enabled ? "http://${kubernetes_service_v1.internal[0].spec[0].cluster_ip}:${var.internal_service_port}" : ""
}

output "internal_image_prefix" {
  description = "Convenience output: `<ip>:<port>` (no scheme) for use as the leading hostname in image tags."
  value       = var.internal_service_enabled ? "${kubernetes_service_v1.internal[0].spec[0].cluster_ip}:${var.internal_service_port}" : ""
}
