variable "namespace" {
  description = "Namespace to install Traefik into."
  type        = string
  default     = "platform-traefik"
}

variable "create_namespace" {
  description = "Whether this module should create the Traefik namespace. Disable when the root module pre-creates it for cross-module dependencies."
  type        = bool
  default     = true
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "traefik"
}

variable "chart_version" {
  description = "traefik/traefik chart version."
  type        = string
  default     = "39.0.8" # app ~v3.6.x, Gateway API v1 stable
}

variable "gateway_api_enabled" {
  description = "Enable Traefik's Gateway API provider and install Gateway API CRDs."
  type        = bool
  default     = true
}

variable "install_gateway_api_crds" {
  description = "Let the Traefik chart install Gateway API CRDs (standard channel). Disable if CRDs are managed elsewhere (e.g. by a Gateway API Helm chart or Argo CD)."
  type        = bool
  default     = true
}

variable "gateway_name" {
  description = "Name of the shared Gateway resource created by this module."
  type        = string
  default     = "platform-gateway"
}

variable "gateway_class_name" {
  description = "GatewayClass name Traefik registers. The chart creates a 'traefik' GatewayClass by default."
  type        = string
  default     = "traefik"
}

variable "gateway_hostnames" {
  description = "Hostnames the Gateway's HTTPS listener matches (SNI). Use ['*.example.com'] for wildcards."
  type        = list(string)
  default     = []
}

variable "gateway_tls_secret_name" {
  description = "Name of the Secret (in the Gateway's namespace) holding the TLS cert/key for the HTTPS listener. Typically managed by cert-manager."
  type        = string
  default     = ""
}

variable "service_type" {
  description = "Type of the Traefik Service (LoadBalancer for cloud, NodePort for bare metal / local, ClusterIP if fronted by something else)."
  type        = string
  default     = "LoadBalancer"
}

variable "entrypoint_timeout_seconds" {
  description = "EntryPoint read/write/idle timeout. Applied to both `web` and `websecure`. Defaults to 30 minutes — long enough for a multi-GB Harbor docker push to complete on a slow link without hitting Traefik's default 180s idle timeout (manifested as HTTP 499 Client Closed Request on the backend)."
  type        = number
  default     = 1800
}

variable "extra_values" {
  description = "Extra Helm values merged on top (YAML string)."
  type        = string
  default     = ""
}

variable "tls_enabled" {
  description = "If true, the websecure entryPoint enables TLS. Set false when running HTTP-only (dev without cert-manager)."
  type        = bool
  default     = false
}

variable "extra_listener_hostnames" {
  description = <<-EOT
    Additional HTTPS listener hostnames (typically deep wildcards like
    '*.vm.dev.openschema.io') to attach to the shared Gateway. For each
    entry, the module creates:
      - a cert-manager Certificate issued by `cert_manager_issuer`, producing
        a TLS Secret in the Gateway namespace; and
      - a Gateway listener on port 8443 with that hostname + TLS ref.
    Gateway API wildcards match exactly one DNS label, so '*.dev.openschema.io'
    does NOT cover 'foo.bar.dev.openschema.io' — add the deeper wildcard here.
    Leave empty to not create any extra listeners.
  EOT
  type        = list(string)
  default     = []
}

variable "cert_manager_issuer" {
  description = "Name of the cert-manager ClusterIssuer used to sign extra-listener wildcard certs. Required (and only used) when extra_listener_hostnames is non-empty."
  type        = string
  default     = ""
}
