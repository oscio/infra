variable "namespace" {
  description = "Namespace for the KEDA control plane."
  type        = string
  default     = "keda"
}

variable "chart_version" {
  description = "kedacore/keda Helm chart version."
  type        = string
  default     = "2.16.1"
}
