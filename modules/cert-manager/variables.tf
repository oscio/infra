variable "namespace" {
  description = "Namespace to install cert-manager into."
  type        = string
  default     = "cert-manager"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "cert-manager"
}

variable "chart_version" {
  description = "jetstack/cert-manager chart version."
  type        = string
  default     = "v1.16.2"
}

variable "install_crds" {
  description = "Install cert-manager CRDs via the chart. Set false if managing CRDs separately (e.g. via Argo CD)."
  type        = bool
  default     = true
}

# --- Let's Encrypt ClusterIssuers ---

variable "letsencrypt_email" {
  description = "Email used for Let's Encrypt registration. Leave empty to skip ClusterIssuer creation."
  type        = string
  default     = ""
}

variable "dns_provider" {
  description = "DNS-01 provider for wildcards. One of: 'cloudflare' (Let's Encrypt + Cloudflare-managed zone) or 'none' (falls back to HTTP-01, no wildcard support — use with selfsigned-ca for in-cluster wildcards)."
  type        = string
  default     = "cloudflare"
  validation {
    condition     = contains(["cloudflare", "none"], var.dns_provider)
    error_message = "dns_provider must be one of: cloudflare, none."
  }
}

# Cloudflare DNS-01
variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission on the relevant zone(s). Required when dns_provider = 'cloudflare'."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Wildcard certificate for the platform domain ---

variable "wildcard_certificate_enabled" {
  description = "Create a wildcard Certificate for *.<domain>. Requires dns_provider != 'none'."
  type        = bool
  default     = false
}

variable "wildcard_certificate_domain" {
  description = "Base domain for the wildcard cert (e.g. 'dev.example.com' yields cert for '*.dev.example.com' and 'dev.example.com')."
  type        = string
  default     = ""
}

variable "wildcard_certificate_namespace" {
  description = "Namespace to create the wildcard Certificate (and its Secret) in. Typically the Gateway's namespace (platform-traefik)."
  type        = string
  default     = "platform-traefik"
}

variable "wildcard_certificate_secret_name" {
  description = "Name of the Secret the Certificate writes to. Pass this to the Traefik module's gateway_tls_secret_name."
  type        = string
  default     = "wildcard-tls"
}

variable "wildcard_certificate_issuer" {
  description = "ClusterIssuer to use for the wildcard cert. 'letsencrypt-staging' or 'letsencrypt-prod'."
  type        = string
  default     = "letsencrypt-staging"
}

variable "selfsigned_enabled" {
  description = "If true, create a self-signed ClusterIssuer + internal CA (ClusterIssuer 'selfsigned-ca'). Useful for dev environments where Let's Encrypt is overkill but you still want real HTTPS with a consistent CA across services."
  type        = bool
  default     = false
}
