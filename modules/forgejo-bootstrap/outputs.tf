output "admin_token" {
  description = "Freshly-minted admin PAT. Sensitive."
  value       = data.external.admin_token.result.token
  sensitive   = true
}
