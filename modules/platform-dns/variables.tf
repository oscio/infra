variable "platform_domain" {
  description = "Base domain (e.g. 'dev.openschema.io'). All hostnames under *.<platform_domain> get rewritten to the gateway Service in CoreDNS."
  type        = string
}

variable "gateway_service_name" {
  description = "Name of the in-cluster gateway Service (typically Traefik)."
  type        = string
  default     = "traefik"
}

variable "gateway_service_namespace" {
  description = "Namespace of the gateway Service."
  type        = string
  default     = "platform-traefik"
}
