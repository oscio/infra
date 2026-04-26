variable "namespace" {
  description = "Namespace to deploy Postgres into. Typically 'platform-infra'."
  type        = string
  default     = "platform-infra"
}

variable "create_namespace" {
  description = "If true, this module creates the namespace. Set false if another module owns it."
  type        = bool
  default     = true
}

variable "release_name" {
  description = "Name used for Deployment, Service, PVC, and Secret."
  type        = string
  default     = "postgres"
}

variable "image_repository" {
  description = "Postgres image repository. Defaults to the official Docker Hub image."
  type        = string
  default     = "docker.io/postgres"
}

variable "image_tag" {
  description = "Postgres image tag. Pin deliberately; bump with intent."
  type        = string
  default     = "16.4-alpine"
}

variable "superuser_username" {
  description = "Postgres superuser username (maps to POSTGRES_USER)."
  type        = string
  default     = "postgres"
}

variable "superuser_password" {
  description = "Postgres superuser password. Pass via tfvars or env var."
  type        = string
  sensitive   = true
}

variable "storage_class" {
  description = "StorageClass for the data PVC. Empty string = cluster default."
  type        = string
  default     = ""
}

variable "storage_size" {
  description = "PVC size for the Postgres data directory."
  type        = string
  default     = "8Gi"
}

variable "resources" {
  description = "Pod resource requests/limits."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}

variable "databases" {
  description = <<-EOT
    List of per-application databases to pre-create. Each entry yields a role
    and a database owned by that role. Useful for a shared dev Postgres that
    hosts Keycloak, Forgejo, Harbor, etc. in one instance.

    Example:
      [
        { database = "keycloak", username = "keycloak", password = "..." },
        { database = "forgejo",  username = "forgejo",  password = "..." },
      ]
  EOT
  type = list(object({
    database = string
    username = string
    password = string
  }))
  default   = []
  sensitive = true
}
