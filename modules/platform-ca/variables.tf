variable "source_secret_name" {
  description = "Name of the Secret holding the CA bundle (expects a 'ca.crt' key)."
  type        = string
  default     = "platform-root-ca"
}

variable "source_secret_namespace" {
  description = "Namespace holding the source CA Secret (typically where cert-manager lives)."
  type        = string
  default     = "cert-manager"
}

variable "configmap_name" {
  description = "Name of the ConfigMap to create in each target namespace."
  type        = string
  default     = "platform-ca"
}

variable "target_namespaces" {
  description = "List of namespaces that should receive a copy of the CA ConfigMap."
  type        = list(string)
  default     = []
}
