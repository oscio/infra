output "namespace" {
  description = "Namespace where the Knative Serving control plane lives."
  value       = var.namespace
}

# In-cluster ingress endpoint. Step 6 will create a Traefik HTTPRoute
# pointing at this ClusterIP for external function URLs.
output "kourier_service" {
  description = "Cluster-internal ingress for routing requests to Knative Services."
  value = {
    namespace = "kourier-system"
    name      = "kourier"
    port      = 80
  }
}

output "domain" {
  description = "Domain Knative auto-generates Service URLs under."
  value       = var.domain
}
