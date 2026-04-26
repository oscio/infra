variable "namespace" {
  description = "Namespace to install the spawner into."
  type        = string
  default     = "platform-spawner"
}

variable "release_name" {
  description = "Kubernetes resource name for Deployment/Service/SA."
  type        = string
  default     = "agent-spawner"
}

variable "image" {
  description = "Spawner container image. Build with services/agent-spawner/Dockerfile."
  type        = string
  default     = "agent-spawner:dev"
}

variable "image_pull_policy" {
  description = "IfNotPresent lets Docker Desktop k8s use locally-built images."
  type        = string
  default     = "IfNotPresent"
}

# --- Domains --------------------------------------------------------------

variable "hub_hostname" {
  description = "Hub hostname served by the spawner (e.g. hermes.dev.openschema.io)."
  type        = string
}

variable "project_hostname_suffix" {
  description = "Suffix for per-project hostnames (<pid>.<suffix>)."
  type        = string
}

variable "project_namespace_prefix" {
  description = "Prefix for per-project namespaces (hermes-proj-<pid>)."
  type        = string
  default     = "hermes-proj-"
}

# --- Gateway --------------------------------------------------------------

variable "gateway_namespace" { type = string }
variable "gateway_name"      { type = string }

variable "gateway_section_name" {
  description = "Name of the Gateway listener for *.hermes.dev... hostnames."
  type        = string
}

# --- Per-project Hermes -------------------------------------------------

variable "image_profiles" {
  description = <<-EOT
    Catalog of project pod images the dashboard exposes as a dropdown at
    create time. Keys are user-facing profile names (shown in the create
    form); values are the resolved container image tags. The spawner
    stores the profile NAME on each Project row and resolves to the tag
    here at spawn / pod-restart time, so re-tagging an image (e.g. dev
    timestamp bumps) doesn't require touching every Project.

    The profile named in `desktop_image_profile` is treated specially —
    it gets a 5th endpoint (KasmVNC web UI) wired up via an extra Service
    + HTTPRoute. Keep it in this map and the corresponding image actually
    has KasmVNC + XFCE built in (see services/agent-workspace/Dockerfile.desktop).
  EOT
  type    = map(string)
  default = {
    basic   = "agent-workspace:dev"
    desktop = "agent-workspace-desktop:dev"
  }
}

variable "default_image_profile" {
  description = "Profile picked when the user (or a JSON API caller) doesn't choose one. Must be a key in image_profiles."
  type        = string
  default     = "basic"
}

variable "desktop_image_profile" {
  description = "Profile name treated as the KasmVNC desktop variant. Empty string = no profile gets the desktop endpoint."
  type        = string
  default     = "desktop"
}

# --- Forgejo automated git credentials ----------------------------------

variable "forgejo_api_url" {
  description = "Cluster-internal Forgejo URL the spawner calls to mint per-project Personal Access Tokens. Empty = Forgejo automation off (users set up git creds manually)."
  type        = string
  default     = ""
}

variable "forgejo_public_host" {
  description = "Public hostname users push to (e.g. git.dev.openschema.io). Substituted into ~/.git-credentials inside each workspace pod."
  type        = string
  default     = ""
}

variable "forgejo_admin_token" {
  description = "Forgejo admin Personal Access Token. Sensitive. Used by the spawner with the `Sudo` header to mint per-user tokens scoped to a single project."
  type        = string
  default     = ""
  sensitive   = true
}

variable "forgejo_user_default_password" {
  description = "Throwaway password set on freshly-created Forgejo users. Users never type it (auth is OIDC for the UI, minted token for git); Forgejo's API just requires SOMETHING here on user creation."
  type        = string
  default     = ""
  sensitive   = true
}

variable "keel_enabled" {
  description = "Stamp Keel auto-rollout annotations on the spawner Deployment so Keel (deployed cluster-side) auto-restarts the pod when Harbor receives a new image digest. Disable on clusters without Keel installed."
  type        = bool
  default     = true
}

variable "keel_poll_schedule" {
  description = "How often Keel re-checks Harbor for a new digest. Cron-ish syntax."
  type        = string
  default     = "@every 1m"
}

variable "harbor_pull_secret_name" {
  description = "Name of the Secret (kubernetes.io/dockerconfigjson) in THIS module's namespace holding Harbor pull credentials. Used by the spawner Deployment to pull its own image AND copied by the spawner runtime into each project namespace + attached to project ServiceAccounts so workspace pods can pull from Harbor too. Empty = skip (images on public registry / Docker Desktop local daemon)."
  type        = string
  default     = "harbor-pull-secret"
}

variable "workspace_cluster_admin_enabled" {
  description = <<-EOT
    Per-project workspace pods get cluster-admin via ClusterRoleBinding —
    so `kubectl` / `terraform` from inside a workspace can mutate this same
    cluster. DANGEROUS: a misbehaving agent can `terraform destroy` or read
    every other project's secrets. Solo-dev convenience only.
  EOT
  type        = bool
  default     = false
}

variable "storage_class" {
  type    = string
  default = "hostpath"
}

variable "max_projects_per_user" {
  type    = number
  default = 5
}

# --- Database ------------------------------------------------------------

variable "postgres_host" {
  type = string
}

variable "postgres_port" {
  type    = number
  default = 5432
}

variable "postgres_superuser_username" {
  type    = string
  default = "postgres"
}

variable "postgres_superuser_password" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type    = string
  default = "spawner"
}

variable "db_username" {
  type    = string
  default = "spawner"
}

variable "db_password" {
  type      = string
  sensitive = true
}

# --- OpenFGA -------------------------------------------------------------

variable "openfga_api_url" {
  type = string
}

variable "openfga_store_id" {
  type = string
}

variable "openfga_auth_model_id" {
  type = string
}

# --- Per-project secret + CA distribution --------------------------------

variable "llm_api_keys" {
  description = "Shared LLM API keys copied into each project namespace. Sensitive."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "llm_secret_name" {
  type    = string
  default = "hermes-llm-keys"
}

variable "ca_configmap_name" {
  type    = string
  default = "platform-root-ca"
}

variable "ca_configmap_data" {
  description = "PEM data for the self-signed CA ConfigMap propagated to each project namespace."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# --- Dev / misc ---------------------------------------------------------

variable "dev_fallback_user" {
  type    = string
  default = ""
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "extra_env" {
  type    = map(string)
  default = {}
}
