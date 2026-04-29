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

# --- Groups + users (data-driven) ---

variable "groups" {
  description = <<-EOT
    Realm groups to create. Order doesn't matter; name uniqueness is
    enforced by Keycloak. Membership is resolved by name in `var.users`.
    The default is just `platform-admin` (wired into Forgejo/Harbor/
    Grafana as the admin group). Add more for downstream RBAC.
  EOT
  type        = list(string)
  default     = ["platform-admin"]
}

variable "users" {
  description = <<-EOT
    Realm users keyed by username. Each user object:

      enabled            = bool, default true
      email              = string
      email_verified     = bool, default true
      first_name         = string
      last_name          = string
      password           = string (sensitive)
      password_temporary = bool. Force password change on first login.
      groups             = list(string). Group names must exist in `var.groups`.

    Pass an empty map to create no users.
  EOT
  type = map(object({
    enabled            = optional(bool, true)
    email              = string
    email_verified     = optional(bool, true)
    first_name         = optional(string, "")
    last_name          = optional(string, "")
    password           = string
    password_temporary = optional(bool, true)
    groups             = optional(list(string), [])
  }))
  default   = {}
  sensitive = true
}

# --- Hostnames of the clients we're registering ---

variable "oauth2_proxy_urls" {
  description = "Base URLs oauth2-proxy handles (own hostname + every protected hostname). Each gets /oauth2/callback registered as a valid redirect URI. Example: ['https://oauth.dev.example.com', 'https://console.dev.example.com']."
  type        = list(string)
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

variable "oauth2_proxy_client_id" {
  description = "OIDC client_id for oauth2-proxy. Must match the oauth2-proxy module's oidc_client_id."
  type        = string
  default     = "oauth2-proxy"
}

variable "oauth2_proxy_client_secret" {
  description = "OIDC client secret for oauth2-proxy. Must match the oauth2-proxy module's oidc_client_secret."
  type        = string
  sensitive   = true
}

variable "forgejo_client_id" {
  description = "OIDC client_id for Forgejo. Must match what the forgejo module passes as oidc_client_id."
  type        = string
  default     = "forgejo"
}

variable "forgejo_client_secret" {
  description = "OIDC client secret for Forgejo. Required when forgejo_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_client_id" {
  description = "OIDC client_id for Harbor."
  type        = string
  default     = "harbor"
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

variable "console_url" {
  description = "Base URL of the console app (e.g. https://console.dev.example.com). Leave empty to skip creating the console client. better-auth's genericOAuth plugin uses /api/auth/oauth2/callback/<providerId> as the redirect path."
  type        = string
  default     = ""
}

variable "console_client_id" {
  description = "OIDC client_id for the console (better-auth)."
  type        = string
  default     = "console"
}

variable "console_client_secret" {
  description = "OIDC client secret for the console. Required when console_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_url" {
  description = "Base URL of Argo CD (e.g. https://cd.dev.example.com). Empty = skip the argocd OIDC client. Argo CD's redirect path is /auth/callback."
  type        = string
  default     = ""
}

variable "argocd_client_id" {
  description = "OIDC client_id for Argo CD."
  type        = string
  default     = "argocd"
}

variable "argocd_client_secret" {
  description = "OIDC client secret for Argo CD. Required when argocd_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_client_id" {
  description = "OIDC client_id for Grafana."
  type        = string
  default     = "grafana"
}

variable "grafana_client_secret" {
  description = "OIDC client secret for Grafana. Required when grafana_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "hermes_client_id" {
  description = "OIDC client_id for the hermes-agent confidential client (token-exchange source). hermes-agent is the binary running inside each VM / agent-sandbox pod."
  type        = string
  default     = "hermes"
}

variable "hermes_client_secret" {
  description = "OIDC client secret for the `hermes` confidential client (used by hermes-agent for token exchange to devpod)."
  type        = string
  sensitive   = true
}

variable "devpod_client_id" {
  description = "OIDC client_id for the DevPod token-exchange target."
  type        = string
  default     = "devpod"
}

# --- Token exchange (the key feature for agent impersonation) ---

variable "token_exchange_enabled" {
  description = "Enable Keycloak token-exchange feature for hermes -> devpod. Requires Keycloak server started with --features=token-exchange."
  type        = bool
  default     = true
}

# All realm users go through `var.users`. No separate "bootstrap admin"
# concept at the module level.

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
