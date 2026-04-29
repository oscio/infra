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

variable "admin_username" {
  description = "Bootstrap admin username (master realm). Configurable; the Keycloak entrypoint reads it from KEYCLOAK_ADMIN at first boot."
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

variable "tls_enabled" {
  description = "Whether the gateway terminates TLS for the Keycloak hostname. Drives the URL scheme used by the post-deploy readiness probe (so callers don't have to know the scheme)."
  type        = bool
  default     = true
}

variable "wait_for_public_url" {
  description = "After the Helm release is healthy, block until https://<hostname>/realms/master/... responds 200. Lets a single `terraform apply` proceed straight into the keycloak-realm module without the documented `wait 30s and re-run` step. Disable only if the Terraform host can't reach the gateway."
  type        = bool
  default     = true
}

variable "local_resolve_ip" {
  description = "Optional IP for curl --resolve <hostname>:<port>:<ip> in the public-readiness probe. Use when the local Terraform host can't resolve the Keycloak hostname (e.g. dnsmasq stale / no /etc/hosts entry) but can reach the gateway IP directly (LAN or Tailscale)."
  type        = string
  default     = ""
}

variable "local_resolve_port" {
  description = "Port paired with local_resolve_ip. Defaults to 443 (Traefik HTTPS) when tls_enabled, else 80."
  type        = number
  default     = 0
}
