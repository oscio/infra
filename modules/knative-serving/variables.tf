variable "domain" {
  description = "Base domain Knative auto-generates Service URLs under (e.g. fn.dev.openschema.io). Each Service gets <name>-<ns>.<domain>."
  type        = string
}

variable "namespace" {
  description = "Namespace for the Knative Serving control plane."
  type        = string
  default     = "knative-serving"
}

