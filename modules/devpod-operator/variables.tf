variable "namespace" {
  description = "Namespace to install the operator into. DevPod CRs will live in `devpods_namespace` (usually the same)."
  type        = string
  default     = "platform-devpods"
}

variable "devpods_namespace" {
  description = "Namespace where DevPod CRs and their backing pods are created."
  type        = string
  default     = "platform-devpods"
}

variable "install_crd" {
  description = "Install the DevPod CRD. Set false if managing the CRD via Argo CD/another controller."
  type        = bool
  default     = true
}

variable "install_operator" {
  description = "Deploy the operator. Set false to install the CRD only (useful for a first pass where you kubectl-apply CRs by hand before the operator exists)."
  type        = bool
  default     = false
}

variable "operator_image" {
  description = "Operator container image. Caller-supplied (no default) so the module stays domain-agnostic — clusters compute the value from their own var.domain."
  type        = string
}

variable "operator_replicas" {
  description = "Operator replica count."
  type        = number
  default     = 1
}

variable "default_devpod_image" {
  description = "Default DevPod base image used when a DevPod CR doesn't specify one. Caller-supplied (no default)."
  type        = string
}

variable "default_ttl" {
  description = "Default TTL for DevPod pods (how long they stay alive with no activity)."
  type        = string
  default     = "8h"
}

variable "labels" {
  description = "Extra labels added to operator resources."
  type        = map(string)
  default     = {}
}
