# =============================================================================
# Monitoring module — kube-prometheus-stack + Loki + Grafana Alloy.
#
# One namespace (platform-monitoring), three Helm releases:
#   - kube-prometheus-stack  (Prometheus + Alertmanager + Grafana + exporters)
#   - grafana/loki           (log store, single-binary dev profile)
#   - grafana/alloy          (DaemonSet; ships pod logs to Loki)
#
# Grafana is exposed at `grafana.<domain>` via an HTTPRoute, with Keycloak OIDC
# integration and Prometheus + Loki auto-provisioned as datasources.
# =============================================================================

# --- Chart / namespace basics --------------------------------------------------

variable "namespace" {
  description = "Namespace for all monitoring components."
  type        = string
  default     = "platform-monitoring"
}

variable "kube_prometheus_stack_release_name" {
  description = "Helm release name for kube-prometheus-stack."
  type        = string
  default     = "kube-prom-stack"
}

variable "kube_prometheus_stack_chart_version" {
  description = "Chart version for prometheus-community/kube-prometheus-stack."
  type        = string
  default     = "84.0.1"
}

variable "loki_release_name" {
  description = "Helm release name for grafana/loki."
  type        = string
  default     = "loki"
}

variable "loki_chart_version" {
  description = "Chart version for grafana/loki (single-binary/SSD deployment)."
  type        = string
  default     = "6.55.0"
}

variable "alloy_release_name" {
  description = "Helm release name for grafana/alloy."
  type        = string
  default     = "alloy"
}

variable "alloy_chart_version" {
  description = "Chart version for grafana/alloy."
  type        = string
  default     = "1.8.0"
}

# --- Grafana exposure ---------------------------------------------------------

variable "hostname" {
  description = "Public hostname for Grafana (e.g. grafana.dev.example.com)."
  type        = string
}

variable "grafana_admin_username" {
  description = "Bootstrap Grafana admin username (chart's `adminUser`). The chart wires it into the admin Secret and grafana.ini."
  type        = string
  default     = "admin"
}

variable "grafana_admin_email" {
  description = "Email for the built-in Grafana admin user. Shown in the UI; not used by the platform."
  type        = string
  default     = "admin@example.com"
}

variable "grafana_admin_password" {
  description = <<-EOT
    Bootstrap Grafana admin password. Used for the built-in `admin` user.
    When OIDC is enabled, prefer signing in as a Keycloak user with an
    oidc group mapped to GrafanaAdmin. The local admin is kept as a break-glass.
  EOT
  type        = string
  sensitive   = true
}

# --- Gateway API / routing ----------------------------------------------------

variable "gateway_api_enabled" {
  description = "Create an HTTPRoute for Grafana (requires a Gateway already installed)."
  type        = bool
  default     = true
}

variable "gateway_parent_ref" {
  description = "Gateway parentRef (name / namespace / sectionName) to attach Grafana's HTTPRoute to."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
  default = null
}

# --- OIDC (Keycloak) ----------------------------------------------------------

variable "oidc_enabled" {
  description = "Configure Grafana with Keycloak OIDC as the default auth. Requires a matching `grafana` client registered in the Keycloak realm."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (Keycloak realm URL, e.g. https://auth.dev.example.com/realms/platform)."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "Grafana OIDC client_id in Keycloak."
  type        = string
  default     = "grafana"
}

variable "oidc_client_secret" {
  description = "Grafana OIDC client secret. Must match the `grafana` client seeded by the realm module."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_admin_groups" {
  description = "Keycloak group names whose members are mapped to Grafana's GrafanaAdmin/Admin role."
  type        = list(string)
  default     = ["platform-admin"]
}

variable "oidc_editor_groups" {
  description = "Keycloak group names whose members are mapped to Grafana's Editor role. Empty = no Editor mapping."
  type        = list(string)
  default     = []
}

variable "oidc_auto_login" {
  description = "Redirect anonymous visitors straight to Keycloak. Set false to keep the Grafana login form visible for break-glass access."
  type        = bool
  default     = false
}

# --- Self-signed CA trust -----------------------------------------------------

variable "ca_source_secret_name" {
  description = "Name of a Secret (in ca_source_secret_namespace) holding a `ca.crt` we should trust. The module mirrors it into a ConfigMap in this namespace and mounts it as SSL_CERT_FILE for Grafana's OIDC client. Leave empty for public TLS (letsencrypt) modes."
  type        = string
  default     = ""
}

variable "ca_source_secret_namespace" {
  description = "Namespace that holds ca_source_secret_name (typically cert-manager)."
  type        = string
  default     = "cert-manager"
}

# --- Storage ------------------------------------------------------------------

variable "storage_class" {
  description = "StorageClass for stateful components (Prometheus TSDB, Loki chunks). Empty = cluster default."
  type        = string
  default     = ""
}

variable "prometheus_storage_size" {
  description = "PVC size for Prometheus' TSDB."
  type        = string
  default     = "20Gi"
}

variable "prometheus_retention" {
  description = "Prometheus data retention window (flag syntax: 15d, 720h, etc.)."
  type        = string
  default     = "15d"
}

variable "alertmanager_storage_size" {
  description = "PVC size for Alertmanager."
  type        = string
  default     = "2Gi"
}

variable "grafana_storage_size" {
  description = "PVC size for Grafana (dashboards DB, plugins)."
  type        = string
  default     = "5Gi"
}

variable "loki_storage_size" {
  description = "PVC size for Loki (SingleBinary mode stores chunks locally)."
  type        = string
  default     = "20Gi"
}

variable "loki_retention" {
  description = "Loki log retention (e.g. 168h = 7d). Applied via the compactor."
  type        = string
  default     = "168h"
}

# --- Helm value overrides (escape hatches) ------------------------------------

variable "extra_kube_prometheus_stack_values" {
  description = "Extra YAML appended to the kube-prometheus-stack Helm release."
  type        = string
  default     = ""
}

variable "extra_loki_values" {
  description = "Extra YAML appended to the Loki Helm release."
  type        = string
  default     = ""
}

variable "extra_alloy_values" {
  description = "Extra YAML appended to the Alloy Helm release."
  type        = string
  default     = ""
}
