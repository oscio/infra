output "namespace" {
  description = "Namespace OpenFGA runs in."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "service_name" {
  description = "OpenFGA HTTP Service name (inside cluster)."
  value       = local.http_service_name
}

output "service_dns" {
  description = "Fully qualified in-cluster DNS name of the OpenFGA HTTP Service."
  value       = local.http_service_dns
}

output "http_url" {
  description = "Base URL for the OpenFGA HTTP API (cluster-internal)."
  value       = local.http_api_url
}

output "grpc_service_dns" {
  description = "In-cluster DNS name of the OpenFGA gRPC Service."
  value       = "${var.release_name}-grpc.${var.namespace}.svc.cluster.local"
}

output "bootstrap_secret_name" {
  description = "Secret holding store_id + auth_model_id + api_url written by the bootstrap Job."
  value       = var.bootstrap_secret_name
}

output "bootstrap_secret_namespace" {
  description = "Namespace of the bootstrap Secret."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "store_id" {
  description = "OpenFGA store ID (read from bootstrap Secret). Consumed by the spawner."
  # The ULID is not a secret — de-sensitise so cluster-level outputs
  # can expose it without `sensitive = true` on every consumer.
  value = nonsensitive(try(data.kubernetes_secret_v1.bootstrap.data["store_id"], ""))
}

output "auth_model_id" {
  description = "OpenFGA authorization model ID (read from bootstrap Secret)."
  value       = nonsensitive(try(data.kubernetes_secret_v1.bootstrap.data["auth_model_id"], ""))
}

output "store_name" {
  description = "Store name passed to `fga store create`."
  value       = var.store_name
}
