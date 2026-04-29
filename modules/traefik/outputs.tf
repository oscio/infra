output "namespace" {
  value = var.namespace
}

output "gateway_class_name" {
  value = var.gateway_class_name
}

output "gateway_parent_ref" {
  description = "Object to pass to downstream modules as gateway_parent_ref."
  value = var.gateway_api_enabled ? {
    name      = var.gateway_name
    namespace = var.namespace
  } : null
}

output "gateway_name" {
  value = var.gateway_name
}
