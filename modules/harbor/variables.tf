variable "namespace" {
  description = "Namespace to install Harbor into."
  type        = string
  default     = "platform-registry"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "harbor"
}

variable "chart_version" {
  description = "harbor/harbor Helm chart version (https://helm.goharbor.io)."
  type        = string
  default     = "1.18.3" # app ~v2.14.x
}

# --- Routing ---

variable "domain" {
  description = "Base domain. Harbor UI exposed at <hostname_prefix>.<domain>."
  type        = string
}

variable "hostname_prefix" {
  description = "Subdomain for Harbor."
  type        = string
  default     = "registry"
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
  description = "StorageClass for all Harbor PVCs. Empty = cluster default."
  type        = string
  default     = ""
}

variable "registry_storage_size" {
  description = "PVC size for container image blobs."
  type        = string
  default     = "50Gi"
}

variable "database_storage_size" {
  description = "PVC size for embedded Postgres."
  type        = string
  default     = "8Gi"
}

variable "redis_storage_size" {
  description = "PVC size for embedded Redis."
  type        = string
  default     = "2Gi"
}

variable "trivy_storage_size" {
  description = "PVC size for Trivy vulnerability DB cache."
  type        = string
  default     = "5Gi"
}

variable "jobservice_storage_size" {
  description = "PVC size for jobservice work dir."
  type        = string
  default     = "2Gi"
}

# --- Admin (bootstrap) ---

variable "admin_password" {
  description = "Harbor bootstrap admin password. Used for both UI login and initial OIDC config API calls."
  type        = string
  sensitive   = true
}

# --- OIDC (Keycloak) ---

variable "oidc_enabled" {
  description = "Configure Keycloak as Harbor's OIDC provider after install (via Harbor API)."
  type        = bool
  default     = true
}

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer URL (e.g. https://auth.<domain>/realms/platform)."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client_id registered in Keycloak."
  type        = string
  default     = "harbor"
}

variable "oidc_client_secret" {
  description = "OIDC client secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_groups_claim" {
  description = "JWT claim that carries the user's groups."
  type        = string
  default     = "groups"
}

variable "oidc_admin_group" {
  description = "Keycloak group whose members become Harbor admins."
  type        = string
  default     = "platform-admin"
}

variable "oidc_auto_onboard" {
  description = "Auto-create Harbor users on first OIDC login (no signup page)."
  type        = bool
  default     = true
}

variable "oidc_verify_cert" {
  description = "Verify Keycloak's TLS cert. Set false if using letsencrypt-staging / self-signed."
  type        = bool
  default     = true
}

variable "oidc_scope" {
  description = "OAuth scopes requested."
  type        = string
  default     = "openid,profile,email,groups"
}

# --- Resources ---

variable "core_memory_request" {
  type    = string
  default = "256Mi"
}
variable "core_memory_limit" {
  type    = string
  default = "1Gi"
}

variable "extra_values" {
  description = "Extra Helm values merged on top (YAML string)."
  type        = string
  default     = ""
}

variable "trivy_enabled" {
  description = "Enable the Trivy vulnerability scanner component. Costs ~500MB memory + extra PVC for the vuln DB. Safe to disable on memory-constrained dev clusters."
  type        = bool
  default     = true
}

variable "local_exec_insecure_tls" {
  description = "If true, the Terraform host's curl invocations (used for Harbor OIDC config push) skip TLS verification. Needed when Harbor is served by a self-signed CA that the host doesn't trust."
  type        = bool
  default     = false
}
