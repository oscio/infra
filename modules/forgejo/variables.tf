variable "namespace" {
  description = "Namespace to install Forgejo into. Created if missing."
  type        = string
  default     = "platform-forgejo"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "forgejo"
}

variable "chart_version" {
  description = "Forgejo Helm chart version (https://code.forgejo.org/forgejo-helm/charts)."
  type        = string
  default     = "17.0.0" # app ~v15.x
}

variable "chart_repository" {
  description = "Chart repository. Default is the official OCI registry."
  type        = string
  default     = "oci://code.forgejo.org/forgejo-helm"
}

# --- Routing ---

variable "domain" {
  description = "Base domain. Forgejo is exposed at <hostname_prefix>.<domain>."
  type        = string
}

variable "hostname_prefix" {
  description = "Subdomain for Forgejo."
  type        = string
  default     = "git"
}

variable "gateway_parent_ref" {
  description = "Gateway to attach the HTTPRoute to."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
}

# --- Storage ---

variable "storage_class" {
  description = "StorageClass for Forgejo's PVCs (repo storage + embedded Postgres). Empty = cluster default."
  type        = string
  default     = ""
}

variable "repo_storage_size" {
  description = "PVC size for Forgejo's git repositories + LFS data."
  type        = string
  default     = "20Gi"
}

# --- Postgres (external only; chart 17+ does not bundle a PG subchart) ---

variable "db" {
  description = <<-EOT
    External Postgres connection details for Forgejo. Typically points at
    the shared module.postgres in platform-infra. The database + user must
    already exist — use module.postgres.databases to pre-create them.
  EOT
  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
  })
  sensitive = true
}

# --- Image (official forgejo/forgejo, not Bitnami) ---

variable "image_repository" {
  description = "Forgejo container image repository. The chart prepends code.forgejo.org/ automatically, so use just 'forgejo/forgejo' not the full URL."
  type        = string
  default     = "forgejo/forgejo"
}

variable "image_tag" {
  description = "Forgejo image tag. Empty = chart default (matches appVersion)."
  type        = string
  default     = ""
}

# --- CA trust (for self-signed OIDC issuer) ---

variable "ca_source_secret_name" {
  description = "Optional: name of a Secret in ca_source_secret_namespace holding a 'ca.crt' key. When set, the CA is copied into a ConfigMap here and mounted into the Forgejo pod so OIDC discovery against a self-signed Keycloak works."
  type        = string
  default     = ""
}

variable "ca_source_secret_namespace" {
  description = "Namespace of ca_source_secret_name. Defaults to 'cert-manager'."
  type        = string
  default     = "cert-manager"
}

# --- Admin user ---

variable "admin_username" {
  description = "Forgejo admin username. Seeded on first boot."
  type        = string
  default     = "forgejo-admin"
}

variable "admin_email" {
  description = "Admin email."
  type        = string
  default     = "admin@example.com"
}

variable "admin_password" {
  description = "Admin password (first-boot only; change via UI after)."
  type        = string
  sensitive   = true
}

# --- OIDC (Keycloak) ---

variable "oidc_enabled" {
  description = "Pre-configure Keycloak as a login source via init-container. When false, Forgejo boots with local-only auth."
  type        = bool
  default     = true
}

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer URL, e.g. https://auth.<domain>/realms/platform."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "Keycloak client_id. Should match the realm module's forgejo client."
  type        = string
  default     = "forgejo"
}

variable "oidc_client_secret" {
  description = "OIDC client secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_provider_name" {
  description = "Display name on the Forgejo sign-in button."
  type        = string
  default     = "Keycloak"
}

variable "oidc_admin_group" {
  description = "Keycloak group whose members are auto-granted Forgejo admin (IsAdmin=true) on every OIDC login. Must match the actual group name in Keycloak; the Keycloak realm needs a `groups` claim mapper that emits group memberships in the ID token."
  type        = string
  default     = "platform-admin"
}

# --- App tuning ---

variable "disable_registration" {
  description = "Disable local signup (rely on OIDC + admin-created accounts)."
  type        = bool
  default     = true
}

variable "require_signin_view" {
  description = "Require sign-in to see anything (no public browsing)."
  type        = bool
  default     = true
}

variable "ssh_service_type" {
  description = "Service type for SSH access. 'ClusterIP' = cluster-internal only (recommended dev default). 'LoadBalancer' = expose externally (requires LB support)."
  type        = string
  default     = "ClusterIP"
}

variable "ssh_port" {
  description = "External SSH port (only matters when ssh_service_type = LoadBalancer)."
  type        = number
  default     = 22
}

# --- Resources ---

variable "cpu_request" {
  type    = string
  default = "200m"
}

variable "cpu_limit" {
  type    = string
  default = "2"
}

variable "memory_request" {
  type    = string
  default = "512Mi"
}

variable "memory_limit" {
  type    = string
  default = "2Gi"
}

variable "extra_values" {
  description = "Extra Helm values merged on top (YAML string)."
  type        = string
  default     = ""
}
