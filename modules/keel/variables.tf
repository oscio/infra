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
  default     = "1.2.0" # app v0.21.1 (mainline keel-hq; 1.0.5 is a third-party fork, 1.0.6 was never published)
}

variable "image_tag" {
  description = "Override Keel image tag. The admin dashboard (web UI) is only built into `latest` per upstream — pinned tags like 0.21.1 ship controller-only. Set to `latest` if you want the dashboard exposed."
  type        = string
  default     = ""
}

variable "basicauth_user" {
  description = "Basic auth username for the Keel admin dashboard. Required by the dashboard — without it the UI returns 401. Empty = basic auth disabled (dashboard inaccessible)."
  type        = string
  default     = ""
}

variable "basicauth_password" {
  description = "Basic auth password for the Keel admin dashboard."
  type        = string
  default     = ""
  sensitive   = true
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

variable "ca_configmap_data" {
  description = "Map of {filename = pem-content} to mount as the trust store for Keel's HTTP client. Required when Harbor is served by a self-signed cert; otherwise the digest poll fails with x509 errors. Empty disables CA mounting (Let's Encrypt mode)."
  type        = map(string)
  default     = {}
  sensitive   = false
}

variable "hostname" {
  description = "Public hostname for the Keel web UI (e.g. cr.dev.example.com). Empty = no HTTPRoute and the chart's Service stays disabled. Useful as a lightweight alternative to Argo CD for inspecting which Deployments Keel is tracking."
  type        = string
  default     = ""
}

variable "gateway_parent_ref" {
  description = "Gateway API parentRef for the HTTPRoute that exposes Keel's UI. Required when `hostname` is set."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
  default = null
}
