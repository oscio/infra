variable "realm_name" {
  description = "Name of the Keycloak realm to create."
  type        = string
  default     = "platform"
}

variable "realm_display_name" {
  description = "Human-readable realm name shown in the UI."
  type        = string
  default     = "Agent Platform"
}

# --- Hostnames of the clients we're registering ---

variable "oauth2_proxy_urls" {
  description = "Base URLs oauth2-proxy handles (own hostname + every protected hostname). Each gets /oauth2/callback registered as a valid redirect URI. Example: ['https://oauth.dev.example.com', 'https://hermes.dev.example.com']."
  type        = list(string)
}

variable "argocd_url" {
  description = "Base URL of Argo CD (e.g. https://argocd.dev.example.com)."
  type        = string
}

variable "forgejo_url" {
  description = "Base URL of Forgejo (e.g. https://git.dev.example.com). Leave empty to skip creating the Forgejo client."
  type        = string
  default     = ""
}

variable "forgejo_oidc_provider_name" {
  description = "OIDC provider display name configured on Forgejo (module.forgejo.oidc_provider_name). Forgejo builds its callback path as /user/oauth2/<name>/callback using this exact value (case-sensitive). Must match what Forgejo actually sends as redirect_uri, otherwise Keycloak returns 'Invalid parameter: redirect_uri'."
  type        = string
  default     = "Keycloak"
}

variable "harbor_url" {
  description = "Base URL of Harbor (e.g. https://registry.dev.example.com). Leave empty to skip creating the Harbor client."
  type        = string
  default     = ""
}

# --- Client secrets (pre-shared with the consumers' tfvars) ---

variable "oauth2_proxy_client_secret" {
  description = "OIDC client secret for oauth2-proxy. Must match the oauth2-proxy module's oidc_client_secret."
  type        = string
  sensitive   = true
}

variable "argocd_client_secret" {
  description = "OIDC client secret for Argo CD. Must match the argocd module's oidc_client_secret."
  type        = string
  sensitive   = true
}

variable "forgejo_client_secret" {
  description = "OIDC client secret for Forgejo. Required when forgejo_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_client_secret" {
  description = "OIDC client secret for Harbor. Required when harbor_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_url" {
  description = "Base URL of Grafana (e.g. https://grafana.dev.example.com). Leave empty to skip creating the Grafana client."
  type        = string
  default     = ""
}

variable "grafana_client_secret" {
  description = "OIDC client secret for Grafana. Required when grafana_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "hermes_client_secret" {
  description = "OIDC client secret for the single `hermes` confidential client (used for token exchange to devpod). There is ONE Hermes user in the cluster."
  type        = string
  sensitive   = true
}

# --- Token exchange (the key feature for agent impersonation) ---

variable "token_exchange_enabled" {
  description = "Enable Keycloak token-exchange feature for hermes -> devpod. Requires Keycloak server started with --features=token-exchange."
  type        = bool
  default     = true
}

# --- Bootstrap admin user (optional) ---

variable "bootstrap_admin_user" {
  description = "Username of an initial platform admin user to create. Empty = skip."
  type        = string
  default     = ""
}

variable "bootstrap_admin_email" {
  description = "Email for the bootstrap admin user."
  type        = string
  default     = ""
}

variable "bootstrap_admin_password" {
  description = "Initial password for the bootstrap admin user. Temporary iff bootstrap_admin_password_temporary is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bootstrap_admin_password_temporary" {
  description = "If true, the bootstrap admin must change their password on first login. Set false for dev clusters where the password in tfvars is the real password."
  type        = bool
  default     = true
}

variable "bootstrap_admin_first_name" {
  description = "First name for the bootstrap admin user (optional)."
  type        = string
  default     = ""
}

variable "bootstrap_admin_last_name" {
  description = "Last name for the bootstrap admin user (optional)."
  type        = string
  default     = ""
}

variable "password_policy" {
  description = <<-EOT
    Keycloak password policy string. Examples:
      - ""                                                (none — dev/sandbox)
      - "length(8)"                                       (minimum length 8)
      - "length(12) and notUsername and passwordHistory(3)" (strict)
    See https://www.keycloak.org/docs/latest/server_admin/#_password-policies
  EOT
  type        = string
  default     = "length(12) and notUsername and notEmail and passwordHistory(3)"
}
