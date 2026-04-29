variable "namespace" {
  description = "Namespace to install Harbor into."
  type        = string
  default     = "platform-registry"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "harbor"
}

variable "chart_version" {
  description = "harbor/harbor Helm chart version (https://helm.goharbor.io)."
  type        = string
  default     = "1.18.3" # app ~v2.14.x
}

# --- Routing ---

variable "domain" {
  description = "Base domain. Harbor UI exposed at <hostname_prefix>.<domain>."
  type        = string
}

variable "hostname_prefix" {
  description = "Subdomain for Harbor."
  type        = string
  default     = "registry"
}

variable "gateway_parent_ref" {
  description = "Gateway to attach the HTTPRoute to."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
}

# --- Storage ---

variable "storage_class" {
  description = "StorageClass for all Harbor PVCs. Empty = cluster default."
  type        = string
  default     = ""
}

variable "registry_storage_size" {
  description = "PVC size for container image blobs."
  type        = string
  default     = "50Gi"
}

variable "database_storage_size" {
  description = "PVC size for embedded Postgres."
  type        = string
  default     = "8Gi"
}

variable "redis_storage_size" {
  description = "PVC size for embedded Redis."
  type        = string
  default     = "2Gi"
}

variable "trivy_storage_size" {
  description = "PVC size for Trivy vulnerability DB cache."
  type        = string
  default     = "5Gi"
}

variable "jobservice_storage_size" {
  description = "PVC size for jobservice work dir."
  type        = string
  default     = "2Gi"
}

# --- Admin (bootstrap) ---

variable "admin_username" {
  description = "Harbor bootstrap admin username. Harbor enforces `admin` for the built-in admin user (the helm chart and API both reject other values), so this exists mostly for symmetry across the app's admin variables. Override at your own risk."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Harbor bootstrap admin password. Used for both UI login and initial OIDC config API calls."
  type        = string
  sensitive   = true
}

variable "admin_email" {
  description = "Email address attached to Harbor's built-in admin user. Shown in UI; unused by the platform."
  type        = string
  default     = "admin@example.com"
}

# --- OIDC (Keycloak) ---

variable "oidc_enabled" {
  description = "Configure Keycloak as Harbor's OIDC provider after install (via Harbor API)."
  type        = bool
  default     = true
}

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer URL (e.g. https://auth.<domain>/realms/platform)."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client_id registered in Keycloak."
  type        = string
  default     = "harbor"
}

variable "oidc_client_secret" {
  description = "OIDC client secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_groups_claim" {
  description = "JWT claim that carries the user's groups."
  type        = string
  default     = "groups"
}

variable "oidc_admin_group" {
  description = "Keycloak group whose members become Harbor admins."
  type        = string
  default     = "platform-admin"
}

variable "oidc_auto_onboard" {
  description = "Auto-create Harbor users on first OIDC login (no signup page)."
  type        = bool
  default     = true
}

variable "oidc_verify_cert" {
  description = "Verify Keycloak's TLS cert. Set false if using letsencrypt-staging / self-signed."
  type        = bool
  default     = true
}

variable "oidc_scope" {
  description = "OAuth scopes requested."
  type        = string
  default     = "openid,profile,email,groups"
}

# --- Resources ---

variable "core_memory_request" {
  type    = string
  default = "256Mi"
}
variable "core_memory_limit" {
  type    = string
  default = "1Gi"
}

variable "extra_values" {
  description = "Extra Helm values merged on top (YAML string)."
  type        = string
  default     = ""
}

variable "trivy_enabled" {
  description = "Enable the Trivy vulnerability scanner component. Costs ~500MB memory + extra PVC for the vuln DB. Safe to disable on memory-constrained dev clusters."
  type        = bool
  default     = true
}

variable "local_exec_insecure_tls" {
  description = "If true, the Terraform host's curl invocations (used for Harbor OIDC config push) skip TLS verification. Needed when Harbor is served by a self-signed CA that the host doesn't trust."
  type        = bool
  default     = false
}

# --- In-cluster registry side-channel -----------------------------------------

variable "internal_service_enabled" {
  description = "Create an additional NodePort Service (`<release>-internal`) that points at the same harbor-nginx pods. In-cluster image pulls target this URL instead of the public hostname, so kubelet does not need node-side DNS for the external URL nor a hosts.toml mirror bypass. Combine with `project_public = true` on harbor-bootstrap (anonymous pull) to avoid the Bearer-token challenge that still references the external URL."
  type        = bool
  default     = false
}

variable "internal_service_cluster_ip" {
  description = "Pinned ClusterIP for the internal Service. Image references can hard-code this IP and remain stable across helm upgrades (the regular Service rotates IPs on recreate). Empty = let K8s pick. Must lie within the cluster's Service CIDR; default works for kubeadm/Docker Desktop (10.96.0.0/12) but not EKS (10.100.0.0/16)."
  type        = string
  default     = ""
}

variable "internal_service_port" {
  description = "ClusterIP port for the internal Service. Used by in-cluster consumers as the image-ref port."
  type        = number
  default     = 30500
}

variable "internal_service_node_port" {
  description = "NodePort for the internal Service. Same value as `internal_service_port` lets one image ref work via both ClusterIP and NodeIP without a search-domain trick."
  type        = number
  default     = 30500
}
