variable "harbor_url" {
  description = "Harbor base URL the local terraform host can reach (e.g. https://registry.dev.openschema.io). The bootstrap calls `/api/v2.0/projects` and `/api/v2.0/robots` from there."
  type        = string
}

variable "resolve_ip" {
  description = "Optional IP for curl --resolve <harbor-host>:443:<ip> when the local Terraform host cannot resolve the Harbor hostname."
  type        = string
  default     = ""
}

variable "harbor_admin_password" {
  description = "Harbor admin password. Sensitive."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Harbor project to create (e.g. agent-platform). Hosts the per-service repositories the in-cluster Forgejo Runner pushes to."
  type        = string
  default     = "agent-platform"
}

variable "project_public" {
  description = <<-EOT
    Make the project public — anonymous pull is allowed (push still
    needs the robot account). Use in dev so kubelet can pull workspace
    images without ImagePullSecrets sync, the auth-challenge → external
    DNS round-trip, or insecure-registry hosts.toml on every node.
    Production should leave this false and rely on real DNS + valid
    certs so the auth flow works without per-node hacks.
  EOT
  type        = bool
  default     = false
}

variable "robot_name" {
  description = "Robot account name (without the `robot$<project>+` prefix Harbor adds)."
  type        = string
  default     = "agent-platform-builder"
}
