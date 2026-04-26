output "rewrite_target_fqdn" {
  description = "Cluster DNS name that *.<platform_domain> gets synthesized to via CoreDNS template plugin."
  value       = local.target_fqdn
}
