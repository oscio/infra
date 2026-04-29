output "fork_urls" {
  description = "Map of fork name → resulting Forgejo URL. Useful for downstream consumers pointing image tags at Harbor builds of these repos."
  value = {
    for name, _ in var.repos :
    name => "${var.public_forgejo_url}/${var.target_owner != "" ? var.target_owner : var.forgejo_admin_username}/${name}"
  }
}
