variable "namespace" {
  description = "Namespace to run the Hermes pod in. Created if missing."
  type        = string
  default     = "platform-hermes"
}

variable "release_name" {
  description = "Base name for the StatefulSet, Services, and HTTPRoute."
  type        = string
  default     = "hermes"
}

# --- Images ---

variable "agent_image" {
  description = "Hermes Agent container image (runs the gateway + dashboard)."
  type        = string
  default     = "nousresearch/hermes-agent:latest"
}

variable "webui_image" {
  description = "Hermes WebUI container image."
  type        = string
  default     = "ghcr.io/nesquena/hermes-webui:latest"
}

variable "image_pull_policy" {
  description = "imagePullPolicy for both containers."
  type        = string
  default     = "IfNotPresent"
}

variable "image_pull_secret" {
  description = "Image pull secret. Empty = none."
  type        = string
  default     = ""
}

# --- Storage ---

variable "storage_class" {
  description = "StorageClass for the shared PVC. Empty = cluster default. Docker Desktop: 'hostpath'."
  type        = string
  default     = ""
}

variable "storage_size" {
  description = "PVC size for the shared Hermes home (config, sessions, skills, memory)."
  type        = string
  default     = "10Gi"
}

variable "workspace_storage_size" {
  description = "PVC size for the user workspace (code the agent edits)."
  type        = string
  default     = "10Gi"
}

# --- UID/GID ---

variable "run_as_uid" {
  description = "UID both containers run as. Must match between containers to avoid permission errors on the shared volume."
  type        = number
  default     = 10000
}

variable "run_as_gid" {
  description = "GID both containers run as."
  type        = number
  default     = 10000
}

# --- Gateway / resource tuning ---

variable "agent_cpu_request" {
  type    = string
  default = "500m"
}
variable "agent_cpu_limit" {
  type    = string
  default = "2"
}
variable "agent_memory_request" {
  type    = string
  default = "1Gi"
}
variable "agent_memory_limit" {
  type    = string
  default = "4Gi"
}

variable "webui_cpu_request" {
  type    = string
  default = "200m"
}
variable "webui_cpu_limit" {
  type    = string
  default = "1"
}
variable "webui_memory_request" {
  type    = string
  default = "512Mi"
}
variable "webui_memory_limit" {
  type    = string
  default = "2Gi"
}

# --- LLM provider credentials ---

variable "llm_api_keys" {
  description = "Map of env-var-name -> API key. Mounted into the agent container."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "default_model" {
  description = "Default LLM model."
  type        = string
  default     = "anthropic/claude-sonnet-4.7"
}

variable "default_provider" {
  description = "Default LLM provider."
  type        = string
  default     = "openrouter"
}

# --- WebUI ---

variable "webui_password" {
  description = "Optional password for the WebUI's built-in auth. Leave empty to rely solely on oauth2-proxy in front."
  type        = string
  default     = ""
  sensitive   = true
}

variable "webui_default_workspace" {
  description = "Mount path for the workspace directory inside the webui container."
  type        = string
  default     = "/workspace"
}

# --- Networking (internal services) ---

variable "create_service" {
  description = "Create ClusterIP Services for webui (8787) and agent gateway (8642)."
  type        = bool
  default     = true
}

# --- Kubernetes access for agent (Speckit dispatch, future) ---

variable "cluster_access_enabled" {
  description = "Grant a Role in the devpods namespace (list/get pods + CRUD on DevPod CRs). Used for Hermes to dispatch DevPods."
  type        = bool
  default     = false
}

variable "devpods_namespace" {
  description = "Namespace the Hermes agent may dispatch DevPod CRs to."
  type        = string
  default     = "platform-devpods"
}

# --- Extra env ---

variable "extra_agent_env" {
  description = "Additional environment variables for the agent container."
  type        = map(string)
  default     = {}
}

variable "extra_webui_env" {
  description = "Additional environment variables for the webui container."
  type        = map(string)
  default     = {}
}
