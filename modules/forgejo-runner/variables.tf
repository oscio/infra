variable "namespace" {
  description = "Namespace to install the runner into."
  type        = string
  default     = "platform-forgejo"
}

variable "release_name" {
  description = "Base name for runner resources."
  type        = string
  default     = "forgejo-runner"
}

variable "replicas" {
  description = "Number of runner replicas."
  type        = number
  default     = 1
}

# --- Images ---

variable "runner_image" {
  description = "Forgejo runner container image."
  type        = string
  default     = "code.forgejo.org/forgejo/runner:6.3.0"
}

variable "buildkit_image" {
  description = "BuildKit container image (rootless-compatible)."
  type        = string
  default     = "moby/buildkit:v0.17.2-rootless"
}

# --- Connection to Forgejo ---

variable "forgejo_url" {
  description = "Base URL Forgejo is reachable at from inside the cluster (e.g. http://forgejo-http.platform-forgejo.svc.cluster.local:3000). Used by the runner to poll tasks."
  type        = string
}

variable "forgejo_admin_user" {
  description = "Forgejo admin username. Used to obtain a runner-registration token via the admin API."
  type        = string
}

variable "forgejo_admin_password" {
  description = "Forgejo admin password."
  type        = string
  sensitive   = true
}

variable "public_forgejo_url" {
  description = "Public Forgejo URL (e.g. https://git.dev.example.com). Used for the token-fetch local-exec where TLS validity matters."
  type        = string
  default     = ""
}

# --- Storage ---

variable "storage_class" {
  description = "StorageClass for the runner's cache PVC. Empty = cluster default."
  type        = string
  default     = ""
}

variable "cache_storage_size" {
  description = "PVC size for runner cache (build layers, workflow artifacts)."
  type        = string
  default     = "10Gi"
}

# --- Resources ---

variable "runner_cpu_request" {
  type    = string
  default = "200m"
}
variable "runner_cpu_limit" {
  type    = string
  default = "2"
}
variable "runner_memory_request" {
  type    = string
  default = "512Mi"
}
variable "runner_memory_limit" {
  type    = string
  default = "4Gi"
}

variable "buildkit_cpu_request" {
  type    = string
  default = "200m"
}
variable "buildkit_cpu_limit" {
  type    = string
  default = "4"
}
variable "buildkit_memory_request" {
  type    = string
  default = "512Mi"
}
variable "buildkit_memory_limit" {
  type    = string
  default = "8Gi"
}

# --- Labels workflows can target (runs-on: ...) ---

variable "runner_labels" {
  description = "Labels advertised to Forgejo. Workflows use `runs-on: <label>` to select runners."
  type        = list(string)
  default     = ["docker", "linux", "self-hosted"]
}

# --- Registry auth (for docker buildx push → Harbor) ---

variable "registry_host" {
  description = "Harbor hostname (e.g. registry.dev.example.com). Used to construct ~/.docker/config.json."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Harbor robot account username for pushing from CI."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Harbor robot account password."
  type        = string
  default     = ""
  sensitive   = true
}
