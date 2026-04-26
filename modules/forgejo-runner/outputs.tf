output "namespace" {
  value = var.namespace
}

output "runner_name" {
  value = var.release_name
}

output "runner_labels" {
  description = "Labels the runner advertises (for workflows' runs-on)."
  value       = var.runner_labels
}
