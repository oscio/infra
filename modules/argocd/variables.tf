variable "namespace" {
  description = "Namespace Argo CD installs into."
  type        = string
  default     = "platform-argocd"
}

variable "release_name" {
  description = "Helm release name. Becomes the prefix on every Argo CD resource."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argo-helm `argo-cd` chart version. Empty = latest from the configured repo."
  type        = string
  default     = "8.5.7"
}

variable "hostname" {
  description = "Public hostname for the Argo CD server (e.g. cd.dev.example.com)."
  type        = string
}

variable "tls_enabled" {
  description = "Whether the Gateway terminates TLS for `hostname`. Drives the externally-served URL scheme."
  type        = bool
  default     = true
}

variable "gateway_parent_ref" {
  description = "Gateway API parentRef for the HTTPRoute (name + namespace + optional sectionName)."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
}

# --- Admin user (built-in, always available — break-glass) -----------

variable "admin_password" {
  description = "Plaintext admin password. Bcrypt-hashed at apply time and stored in `argocd-secret`. Required."
  type        = string
  sensitive   = true
}

# --- OIDC (Keycloak) -------------------------------------------------

variable "oidc_enabled" {
  description = "Wire Keycloak OIDC into argocd-cm. Built-in admin still works alongside."
  type        = bool
  default     = true
}

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer URL, e.g. https://auth.<domain>/realms/platform."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client_id Argo CD presents to Keycloak."
  type        = string
  default     = "argocd"
}

variable "oidc_client_secret" {
  description = "OIDC client_secret. Stored in argocd-secret under `oidc.keycloak.clientSecret`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_admin_group" {
  description = "Keycloak realm group whose members get Argo CD's `admin` role via RBAC. Empty disables the auto-mapping."
  type        = string
  default     = "platform-admin"
}

# --- TLS trust ------------------------------------------------------

variable "ca_configmap_data" {
  description = "Optional `{ \"ca.crt\" = <pem> }`. When set, mounted at /etc/ssl/argocd-ca and exported via SSL_CERT_FILE so Argo CD's HTTPS calls (Keycloak OIDC discovery, Harbor) validate selfsigned platform certs. Empty = use system roots."
  type        = map(string)
  default     = {}
}

# --- Image Updater (replaces Keel) ----------------------------------

variable "image_updater_enabled" {
  description = "Install argocd-image-updater alongside Argo CD. Watches container registries and patches Argo CD Applications when new tags appear."
  type        = bool
  default     = true
}

variable "image_updater_chart_version" {
  description = "argo-helm `argocd-image-updater` chart version."
  type        = string
  default     = "0.12.3"
}

variable "image_updater_registries" {
  description = "Registries the updater should authenticate against. Each entry adds an item to the updater's registries.conf. Empty = use anonymous pulls."
  type = map(object({
    api_url        = string
    prefix         = string
    insecure       = optional(bool, false)
    credentials    = optional(string, "") # `pullsecret:<ns>/<name>`, `secret:<ns>/<name>#<key>`, or `ext:<binary>`
    default        = optional(bool, false)
    ping           = optional(bool, true)
  }))
  default = {}
}
