variable "harbor_url" {
  description = "Harbor base URL the local terraform host can reach (e.g. https://registry.dev.openschema.io). The bootstrap calls `/api/v2.0/projects` and `/api/v2.0/robots` from there."
  type        = string
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

variable "robot_name" {
  description = "Robot account name (without the `robot$<project>+` prefix Harbor adds)."
  type        = string
  default     = "agent-platform-builder"
}
