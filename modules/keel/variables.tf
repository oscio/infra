variable "namespace" {
  description = "Kubernetes namespace for the Keel controller."
  type        = string
  default     = "platform-keel"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "keel"
}

variable "chart_version" {
  description = "keel-hq/keel chart version. Pinned to avoid surprise upgrades — bump intentionally when a new app version is wanted."
  type        = string
  default     = "1.0.6" # app v0.20.x
}

variable "poll_schedule" {
  description = "Default poll interval Keel uses when a Deployment doesn't override via `keel.sh/pollSchedule`. Cron-ish syntax (`@every 30s`, `@every 1m`, `0 */5 * * *`)."
  type        = string
  default     = "@every 1m"
}

variable "harbor_pull_secret_namespace" {
  description = "Namespace holding the dockerconfigjson Secret Keel should reuse to talk to Harbor (so it can read tags/digests). Empty = anonymous (only works for public registries)."
  type        = string
  default     = ""
}

variable "harbor_pull_secret_name" {
  description = "Name of the dockerconfigjson Secret Keel reads to authenticate with Harbor."
  type        = string
  default     = ""
}
