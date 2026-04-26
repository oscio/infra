variable "namespace" {
  description = "Namespace to install Keycloak into. Created if missing."
  type        = string
  default     = "platform-keycloak"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "keycloak"
}

variable "chart_version" {
  description = "codecentric/keycloakx chart version."
  type        = string
  default     = "7.1.11" # Keycloak app 26.5.x
}

variable "image_repository" {
  description = "Keycloak container image repository. Defaults to the official image on quay.io."
  type        = string
  default     = "quay.io/keycloak/keycloak"
}

variable "image_tag" {
  description = "Keycloak container image tag. Must match an existing tag at quay.io/keycloak/keycloak."
  type        = string
  default     = "26.5.6"
}

variable "hostname" {
  description = "Public hostname for Keycloak (e.g. auth.dev.openschema.io)."
  type        = string
}

variable "replicas" {
  description = "Number of Keycloak replicas."
  type        = number
  default     = 1
}

variable "admin_user" {
  description = "Bootstrap admin username."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Bootstrap admin password. Pass via tfvars or env var — do not commit."
  type        = string
  sensitive   = true
}

# --- Routing: Gateway API only. Classic Ingress path was dropped when we moved
#     off Bitnami — re-add if someone needs it. ---

variable "gateway_api_enabled" {
  description = "Use Gateway API (HTTPRoute). Must be true for this module version."
  type        = bool
  default     = true
}

variable "gateway_parent_ref" {
  description = "Gateway to attach the HTTPRoute to."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
  default = null
}

# --- Database (external only) ---

variable "db" {
  description = <<-EOT
    External Postgres connection details. Keycloakx does NOT embed Postgres —
    pass credentials for a PG reachable from the Keycloak pod (typically the
    shared module.postgres in platform-infra).
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

variable "resources" {
  description = "Pod resource requests/limits for the Keycloak container."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "500m", memory = "1Gi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
}

variable "extra_values" {
  description = "Extra Helm values merged on top of module defaults (YAML string)."
  type        = string
  default     = ""
}
