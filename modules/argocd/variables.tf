variable "namespace" {
  description = "Namespace to install Argo CD into."
  type        = string
  default     = "platform-argocd"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argo/argo-cd Helm chart version."
  type        = string
  default     = "9.5.4" # app v3.3.x
}

variable "hostname" {
  description = "Public hostname for Argo CD UI."
  type        = string
}

variable "ha_enabled" {
  description = "Run Argo CD in HA mode (multiple replicas of repo/application/controller)."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "Keycloak OIDC issuer URL (realm URL)."
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID registered in Keycloak for Argo CD."
  type        = string
  default     = "argocd"
}

variable "oidc_client_secret" {
  description = "OIDC client secret. Pass via tfvars or env var."
  type        = string
  sensitive   = true
}

variable "rbac_admin_groups" {
  description = "Keycloak groups mapped to Argo CD admin role."
  type        = list(string)
  default     = ["platform-admin"]
}

variable "rbac_readonly_groups" {
  description = "Keycloak groups mapped to Argo CD readonly role."
  type        = list(string)
  default     = ["developer", "viewer"]
}

variable "source_repos" {
  description = "Git repositories Argo CD is allowed to sync from."
  type        = list(string)
  default     = []
}

# --- Routing: Gateway API (preferred) OR classic Ingress ---

variable "gateway_api_enabled" {
  description = "Use Gateway API (HTTPRoute). Also flips argocd-server to insecure mode so the Gateway terminates TLS (avoids BackendTLSPolicy)."
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

variable "oidc_root_ca_pem" {
  description = "Optional: PEM-encoded CA certificate to trust when validating the OIDC issuer's TLS cert. Required when the issuer is served by a self-signed CA."
  type        = string
  default     = ""
  sensitive   = false
}
