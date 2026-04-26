variable "namespace" {
  description = "Namespace to install oauth2-proxy into."
  type        = string
  default     = "platform-auth"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "oauth2-proxy"
}

variable "chart_version" {
  description = "oauth2-proxy Helm chart version."
  type        = string
  default     = "10.4.3" # oauth2-proxy app 7.15.2 (official chart, not Bitnami)
}

variable "hostname" {
  description = "Public hostname for oauth2-proxy itself. When protected_hostname is set, oauth2-proxy is ALSO reachable at protected_hostname (Host-based routing) and proxies to the upstream Service."
  type        = string
}

variable "protected_hostname" {
  description = "Optional: a hostname oauth2-proxy should own as a reverse-proxy for an internal Service (e.g. 'hermes.dev.example.com'). HTTPRoute is created at this hostname pointing at oauth2-proxy; oauth2-proxy proxies to upstream_service on success. Empty = oauth2-proxy is standalone."
  type        = string
  default     = ""
}

variable "extra_whitelist_domains" {
  description = <<-EOT
    Additional hostnames (wildcards allowed) that oauth2-proxy should accept
    as valid `rd=` / post-auth redirect targets. Used when a separate
    routing layer (e.g. Traefik ForwardAuth middleware) sends per-request
    authentication checks to oauth2-proxy from hostnames OTHER than
    `protected_hostname` — each one must appear in oauth2-proxy's whitelist
    or the login redirect will be rejected.

    Example: oauth2-proxy primarily protects `hermes.dev.example.com` but
    is also the auth backend for ForwardAuth on `*.hermes.dev.example.com`
    → pass `["*.hermes.dev.example.com"]`.
  EOT
  type        = list(string)
  default     = []
}

variable "upstream_service_name" {
  description = "Name of the Service oauth2-proxy proxies to after successful auth (e.g. 'hermes-webui'). Required when protected_hostname is set."
  type        = string
  default     = ""
}

variable "upstream_service_namespace" {
  description = "Namespace of the upstream Service. Required when protected_hostname is set."
  type        = string
  default     = ""
}

variable "upstream_service_port" {
  description = "Port on the upstream Service (usually 80)."
  type        = number
  default     = 80
}

variable "cookie_domain" {
  description = "Cookie domain for oauth2-proxy session cookies. When protecting one host, set to that host; for wildcard, prefix with dot (e.g. '.dev.example.com')."
  type        = string
  default     = ""
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (typically Keycloak realm URL)."
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID registered in Keycloak."
  type        = string
  default     = "oauth2-proxy"
}

variable "oidc_client_secret" {
  description = "OIDC client secret. Pass via tfvars or env var."
  type        = string
  sensitive   = true
}

variable "cookie_secret" {
  description = "32-byte base64 cookie secret. If empty, a random one is generated."
  type        = string
  default     = ""
  sensitive   = true
}

variable "email_domains" {
  description = "List of allowed email domains. ['*'] to accept any authenticated user."
  type        = list(string)
  default     = ["*"]
}

variable "allowed_groups" {
  description = "Keycloak groups allowed through. Empty = no group check."
  type        = list(string)
  default     = []
}

# --- Routing: Gateway API (preferred) OR classic Ingress ---

variable "gateway_api_enabled" {
  description = "Use Gateway API (HTTPRoute) for ingress. When true, chart-native Ingress is disabled and an HTTPRoute is created referencing gateway_parent_ref."
  type        = bool
  default     = true
}

variable "gateway_parent_ref" {
  description = "Gateway to attach the HTTPRoute to. Required when gateway_api_enabled = true."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
  default = null
}

variable "ingress_class_name" {
  description = "Ingress class when gateway_api_enabled = false."
  type        = string
  default     = "traefik"
}

variable "tls_enabled" {
  description = "Enable TLS on the classic Ingress. Ignored under Gateway API."
  type        = bool
  default     = true
}

variable "cert_manager_issuer" {
  description = "cert-manager ClusterIssuer name. Ignored under Gateway API."
  type        = string
  default     = "letsencrypt-staging"
}

variable "extra_values" {
  description = "Extra Helm values merged on top (YAML string)."
  type        = string
  default     = ""
}

variable "ca_configmap_name" {
  description = "Optional: name of a ConfigMap in this module's namespace containing a 'ca.crt' key. When set, the CA bundle is mounted into the pod and SSL_CERT_FILE points at it, so oauth2-proxy trusts certs signed by that CA (e.g. the internal selfsigned-ca)."
  type        = string
  default     = ""
}

variable "ca_source_secret_name" {
  description = "Optional: name of a Secret in ca_source_secret_namespace holding a 'ca.crt' key. When set, the CA is copied into a ConfigMap in this module's namespace and mounted into the oauth2-proxy pod. Overrides ca_configmap_name."
  type        = string
  default     = ""
}

variable "ca_source_secret_namespace" {
  description = "Namespace of ca_source_secret_name. Defaults to 'cert-manager'."
  type        = string
  default     = "cert-manager"
}
