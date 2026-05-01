variable "domain" {
  description = "Base domain Knative auto-generates Service URLs under (e.g. fn.dev.openschema.io). Each Service gets <name>-<ns>.<domain>."
  type        = string
}

variable "registries_skipping_tag_resolving" {
  description = "Comma-separated registry hostnames Knative skips tag→digest resolution for. Avoids x509 errors against self-signed Harbor in dev."
  type        = string
  default     = "cr.dev.openschema.io"
}

variable "function_namespace" {
  description = "Namespace where console-api creates per-function HTTPRoutes. ReferenceGrant in kourier-system allows them to backend-ref the kourier Service."
  type        = string
  default     = "resource"
}

variable "namespace" {
  description = "Namespace for the Knative Serving control plane."
  type        = string
  default     = "knative-serving"
}

