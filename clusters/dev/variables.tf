variable "kubeconfig_path" {
  description = "Path to kubeconfig."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context for the dev cluster."
  type        = string
}

variable "domain" {
  description = "Base DNS domain for dev (e.g. dev.example.com, or 127.0.0.1.nip.io for local). Used to derive component hostnames."
  type        = string
}

# --- Storage ---
variable "storage_class" {
  description = "StorageClass for in-cluster stateful workloads (Postgres, Redis, etc.). Empty = cluster default. Docker Desktop: 'hostpath'. kind: 'standard'. k3d: 'local-path'. EKS: '' (uses gp3)."
  type        = string
  default     = ""
}

variable "platform_postgres_storage_size" {
  description = "PVC size for the shared platform-infra Postgres (hosts Keycloak DB, extendable to other services)."
  type        = string
  default     = "8Gi"
}

variable "platform_postgres_superuser_password" {
  description = "Superuser password for the shared platform-infra Postgres."
  type        = string
  sensitive   = true
}

variable "keycloak_db_password" {
  description = "Password for the 'keycloak' Postgres role. Used by the shared PG to pre-create the role, and by the Keycloak pod to connect."
  type        = string
  sensitive   = true
}

# --- Routing ---
variable "gateway_api_enabled" {
  description = "Use Gateway API via Traefik. Default on."
  type        = bool
  default     = true
}

variable "traefik_service_type" {
  description = "Service type for Traefik's entrypoint."
  type        = string
  default     = "LoadBalancer"
}

variable "traefik_extra_listener_hostnames" {
  description = <<-EOT
    Additional HTTPS wildcard hostnames to publish as separate Gateway
    listeners. Use for deep wildcards the primary '*.<domain>' listener
    can't cover (Gateway API wildcards only match one DNS label). For
    each entry the traefik module creates a cert-manager Certificate
    (signed by the active ClusterIssuer) and a Gateway listener.
    Example: ["*.hermes.dev.openschema.io"].
  EOT
  type        = list(string)
  default     = []
}

variable "gateway_tls_secret_name" {
  description = "Secret name (in Traefik's namespace) holding the wildcard TLS cert for *.<domain>. Leave empty to skip HTTPS listener (dev only). When cert_manager_enabled + cert_manager_wildcard_cert are true, this is derived from cert-manager's output and this variable is ignored."
  type        = string
  default     = ""
}

# --- TLS mode ---
# Single knob that drives cert-manager installation, issuer choice, and
# whether HTTPS is served at all. See main.tf `locals { tls_* }` block.
variable "tls_mode" {
  description = <<-EOT
    TLS strategy for this cluster. One of:
      - "off"                  : plain HTTP, no cert-manager
      - "selfsigned"           : internal CA + wildcard signed by it
                                  (browsers need the CA trusted once)
      - "letsencrypt-staging"  : Let's Encrypt staging issuer (fake certs;
                                  no rate limits, useful for ACME dry-runs)
      - "letsencrypt-prod"     : Let's Encrypt prod (real trusted certs)

    Let's Encrypt modes require letsencrypt_email + dns_provider
    (cloudflare/route53) + matching provider credentials.
  EOT
  type        = string
  default     = "selfsigned"

  validation {
    condition = contains(
      ["off", "selfsigned", "letsencrypt-staging", "letsencrypt-prod"],
      var.tls_mode,
    )
    error_message = "tls_mode must be one of: off, selfsigned, letsencrypt-staging, letsencrypt-prod."
  }
}

variable "letsencrypt_email" {
  description = "Email used for Let's Encrypt registration. Required when cert_manager_enabled = true."
  type        = string
  default     = ""
}

variable "dns_provider" {
  description = "DNS-01 provider for wildcard certs: 'cloudflare', 'route53', or 'none' (HTTP-01, no wildcards)."
  type        = string
  default     = "cloudflare"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Required when dns_provider = 'cloudflare'."
  type        = string
  default     = ""
  sensitive   = true
}

variable "route53_region" {
  description = "AWS region for Route53 DNS-01. Required when dns_provider = 'route53'."
  type        = string
  default     = ""
}

variable "route53_hosted_zone_id" {
  description = "Route53 hosted zone ID."
  type        = string
  default     = ""
}

variable "route53_access_key_id" {
  description = "AWS access key ID. Prefer IRSA in real deployments."
  type        = string
  default     = ""
  sensitive   = true
}

variable "route53_secret_access_key" {
  description = "AWS secret access key."
  type        = string
  default     = ""
  sensitive   = true
}

# Removed: tls_enabled, cert_manager_enabled, cert_manager_wildcard_cert,
# cert_manager_selfsigned_enabled, cert_manager_issuer, gateway_tls_secret_name (duplicated above)
# All derived from var.tls_mode now. See main.tf `locals { tls_* }` block.

# --- Keycloak ---
variable "keycloak_admin_user" {
  description = "Bootstrap admin username for Keycloak (also used by the Terraform keycloak provider)."
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Keycloak bootstrap admin password."
  type        = string
  sensitive   = true
}

# --- Realm config (keycloak-realm module) ---

variable "realm_enabled" {
  description = "Run the keycloak-realm module to seed the platform realm, clients, and groups. Set false on first apply (bootstrap phase); flip to true once Keycloak is reachable."
  type        = bool
  default     = false
}

variable "hermes_client_secret" {
  description = "OIDC client secret for the single `hermes` client in the platform realm (service account + token exchange target). One Hermes user per cluster."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bootstrap_admin_user" {
  description = "Optional: create this user in the platform realm as a platform-admin. Empty = skip."
  type        = string
  default     = ""
}

variable "bootstrap_admin_email" {
  description = "Email for the bootstrap realm admin."
  type        = string
  default     = ""
}

variable "bootstrap_admin_password" {
  description = "Password for the bootstrap realm admin."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bootstrap_admin_password_temporary" {
  description = "If true, the bootstrap admin must change password on first login. Set false for dev when tfvars holds the real password."
  type        = bool
  default     = true
}

variable "bootstrap_admin_first_name" {
  description = "First name for the bootstrap realm admin (optional)."
  type        = string
  default     = ""
}

variable "bootstrap_admin_last_name" {
  description = "Last name for the bootstrap realm admin (optional)."
  type        = string
  default     = ""
}

# --- Hermes (single pod, agent + webui containers) ---

variable "hermes_enabled" {
  description = "Deploy the legacy single-shared Hermes pod. DEPRECATED — prefer agent_spawner_enabled for the multi-project hub."
  type        = bool
  default     = false
}

variable "agent_spawner_enabled" {
  description = "Deploy the Hermes Spawner hub at hermes.<domain>. Requires openfga, realm, oauth2-proxy."
  type        = bool
  default     = false
}

variable "agent_spawner_image" {
  description = "Spawner container image. Built by Forgejo Actions from services/agent-spawner/Dockerfile and pushed to Harbor at agent-platform/agent-spawner."
  type        = string
  default     = "harbor.dev.openschema.io/agent-platform/agent-spawner:latest"
}

variable "agent_spawner_db_password" {
  description = "Password for the spawner's Postgres role."
  type        = string
  sensitive   = true
  default     = ""
}

variable "agent_spawner_max_projects_per_user" {
  description = "Per-user project cap. Admin users bypass it."
  type        = number
  default     = 5
}

variable "agent_spawner_log_level" {
  description = "Python logging level."
  type        = string
  default     = "INFO"
}

variable "hermes_agent_image" {
  description = "Legacy single-pod Hermes Agent image (used only by module \"hermes\", the pre-spawner deployment)."
  type        = string
  default     = "nousresearch/hermes-agent:latest"
}

variable "hermes_webui_image" {
  description = "Legacy single-pod Hermes WebUI image (used only by module \"hermes\", the pre-spawner deployment)."
  type        = string
  default     = "ghcr.io/nesquena/hermes-webui:latest"
}

variable "agent_spawner_workspace_image" {
  description = "Basic per-project pod image (code-server + agent + webui + ttyd). Built by Forgejo Actions from services/agent-workspace/Dockerfile and pushed to Harbor at agent-platform/agent-workspace."
  type        = string
  default     = "harbor.dev.openschema.io/agent-platform/agent-workspace:latest"
}

# --- Forgejo mirror sources -----------------------------------------------

variable "agent_spawner_source_repo" {
  description = "Upstream repo (e.g. https://github.com/<owner>/agent-spawner) for Forgejo to mirror. Empty = skip mirror creation; the user pushes directly to Forgejo instead."
  type        = string
  default     = ""
}

variable "agent_workspace_source_repo" {
  description = "Upstream repo for agent-workspace. Same semantics as agent_spawner_source_repo."
  type        = string
  default     = ""
}

variable "github_mirror_username" {
  description = "GitHub username used by Forgejo to authenticate against private upstream repos. Empty = anonymous (works for public repos)."
  type        = string
  default     = ""
}

variable "github_mirror_token" {
  description = "GitHub Personal Access Token (read-only repo scope is enough). Sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "agent_spawner_workspace_desktop_image" {
  description = "Desktop variant of the per-project pod image. Built by Forgejo Actions from services/agent-workspace/Dockerfile.desktop and pushed to Harbor at agent-platform/agent-workspace-desktop."
  type        = string
  default     = "harbor.dev.openschema.io/agent-platform/agent-workspace-desktop:latest"
}

variable "agent_spawner_forgejo_admin_token" {
  description = "Forgejo admin Personal Access Token. Empty = Forgejo automation off (users set up git creds manually inside the pod). Generate via Forgejo UI under the forgejo-admin user → Settings → Applications. Sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "agent_spawner_workspace_cluster_admin_enabled" {
  description = "Per-project workspace pods get cluster-admin (so the agent or user can `terraform apply` the cluster from inside a workspace). DANGEROUS — solo-dev convenience only. See spawner/config.py docstring for the full risk list."
  type        = bool
  default     = false
}


variable "hermes_image_pull_secret" {
  description = "Image pull secret name. Empty = none."
  type        = string
  default     = ""
}

variable "hermes_storage_size" {
  description = "PVC size for the shared Hermes home (config, sessions, skills, memory)."
  type        = string
  default     = "10Gi"
}

variable "agent_workspace_storage_size" {
  description = "PVC size for the workspace volume mounted into hermes-webui at /workspace."
  type        = string
  default     = "10Gi"
}

variable "hermes_run_as_uid" {
  description = "UID both Hermes containers run as. Set to a fixed value (default 10000) so they can share the PVC without permission errors."
  type        = number
  default     = 10000
}

variable "hermes_run_as_gid" {
  description = "GID both Hermes containers run as."
  type        = number
  default     = 10000
}

variable "hermes_default_provider" {
  description = "Default LLM provider."
  type        = string
  default     = "openrouter"
}

variable "hermes_default_model" {
  description = "Default LLM model."
  type        = string
  default     = "anthropic/claude-sonnet-4.7"
}

variable "hermes_llm_api_keys" {
  description = "Map of env-var-name -> LLM provider API key. Mounted into the agent container."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "hermes_webui_password" {
  description = "Optional password for Hermes WebUI's built-in auth. Usually left empty because oauth2-proxy in front handles auth."
  type        = string
  default     = ""
  sensitive   = true
}

variable "hermes_cluster_access_enabled" {
  description = "Grant Hermes RBAC to create DevPod CRs in the platform-devpods namespace. Enable once the devpod-operator CRD exists."
  type        = bool
  default     = false
}

# --- Forgejo (in-cluster git, dev only) ---

variable "forgejo_enabled" {
  description = "Deploy Forgejo. Dev-cluster only per DESIGN.md."
  type        = bool
  default     = false
}

variable "forgejo_admin_username" {
  description = "Forgejo admin username (seeded on first boot)."
  type        = string
  default     = "forgejo-admin"
}

variable "forgejo_admin_email" {
  description = "Forgejo admin email."
  type        = string
  default     = "admin@example.com"
}

variable "forgejo_admin_password" {
  description = "Forgejo admin password. Change via UI after first login."
  type        = string
  default     = ""
  sensitive   = true
}

variable "forgejo_oidc_client_secret" {
  description = "OIDC client secret used by Forgejo to authenticate against Keycloak's platform realm. Must match the `forgejo` client seeded by the realm module."
  type        = string
  default     = ""
  sensitive   = true
}

variable "forgejo_repo_storage_size" {
  description = "PVC size for Forgejo's git repositories."
  type        = string
  default     = "20Gi"
}

variable "forgejo_postgres_storage_size" {
  description = "PVC size for Forgejo's embedded Postgres."
  type        = string
  default     = "8Gi"
}

variable "forgejo_disable_registration" {
  description = "Disable local signup in Forgejo (rely on OIDC)."
  type        = bool
  default     = true
}

variable "forgejo_require_signin_view" {
  description = "Require Forgejo login to see any content."
  type        = bool
  default     = true
}

variable "forgejo_ssh_service_type" {
  description = "ClusterIP or LoadBalancer for SSH. Default ClusterIP (cluster-internal SSH only)."
  type        = string
  default     = "ClusterIP"
}

# --- Harbor (container registry, dev only) ---

variable "harbor_enabled" {
  description = "Deploy Harbor. Dev-cluster only per DESIGN.md."
  type        = bool
  default     = false
}

variable "harbor_admin_password" {
  description = "Harbor bootstrap admin password. Used to login at /harbor/sign-in and by the OIDC-config local-exec."
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_oidc_client_secret" {
  description = "OIDC client secret for Harbor. Must match the `harbor` client seeded by the realm module."
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_registry_storage_size" {
  description = "PVC size for image blobs."
  type        = string
  default     = "50Gi"
}

variable "harbor_database_storage_size" {
  description = "PVC size for embedded Postgres."
  type        = string
  default     = "8Gi"
}

variable "harbor_oidc_verify_cert" {
  description = "Whether Harbor should verify Keycloak's TLS cert. Set false with letsencrypt-staging / self-signed dev."
  type        = bool
  default     = false
}

# --- DevPod operator + CRD (dev only) ---

variable "devpod_operator_enabled" {
  description = "Install the DevPod CRD. When devpod_operator_run_controller = true, also deploys the operator Deployment."
  type        = bool
  default     = false
}

variable "devpod_operator_run_controller" {
  description = "Deploy the DevPod operator Deployment. Keep false until the operator image is built and pushed to Harbor."
  type        = bool
  default     = false
}

variable "devpod_operator_image" {
  description = "DevPod operator image. Built separately."
  type        = string
  default     = "registry.dev.openschema.io/library/devpod-operator:latest"
}

variable "devpod_default_image" {
  description = "Default DevPod base image (used when a DevPod CR leaves .spec.image blank)."
  type        = string
  default     = "registry.dev.openschema.io/library/devpod-base:latest"
}

# --- Forgejo Runner (CI) ---

variable "forgejo_runner_enabled" {
  description = "Deploy a Forgejo Actions runner with a BuildKit sidecar. Requires Forgejo up and reachable."
  type        = bool
  default     = false
}

variable "forgejo_runner_replicas" {
  description = "Number of runner replicas."
  type        = number
  default     = 1
}

variable "forgejo_runner_cache_size" {
  description = "PVC size for the runner + BuildKit cache."
  type        = string
  default     = "10Gi"
}

variable "forgejo_runner_registry_username" {
  description = "Harbor robot account username used by `docker buildx push` in CI. Create the robot account via Harbor UI or API first."
  type        = string
  default     = ""
}

variable "forgejo_runner_registry_password" {
  description = "Harbor robot account secret."
  type        = string
  default     = ""
  sensitive   = true
}

# --- oauth2-proxy (protects Hermes WebUI via Keycloak master realm) ---

variable "oauth2_proxy_client_id" {
  description = "Keycloak OIDC client_id for oauth2-proxy. Registered in the Keycloak master realm (manually or via a separate realm seed)."
  type        = string
  default     = "oauth2-proxy"
}

variable "oauth2_proxy_client_secret" {
  description = "OIDC client secret for oauth2-proxy. Must match the client registered in the Keycloak master realm."
  type        = string
  sensitive   = true
}

variable "oauth2_proxy_email_domains" {
  description = "Email domains allowed through oauth2-proxy. ['*'] to accept any authenticated user."
  type        = list(string)
  default     = ["*"]
}

# --- Argo CD ---
variable "argocd_oidc_client_secret" {
  description = "OIDC client secret for Argo CD (registered in Keycloak)."
  type        = string
  sensitive   = true
}

variable "argocd_source_repos" {
  description = "Repositories Argo CD is allowed to sync from. Dev uses in-cluster Forgejo."
  type        = list(string)
  default     = ["https://forgejo.dev.example.com/*"]
}

variable "forgejo_db_password" {
  description = "Password for the 'forgejo' Postgres role."
  type        = string
  sensitive   = true
}

variable "harbor_db_password" {
  description = "Password for the 'harbor' Postgres role."
  type        = string
  sensitive   = true
}

# --- OpenFGA (authorization engine for the Hermes project spawner) ---

variable "openfga_enabled" {
  description = "Deploy OpenFGA on the cluster (module.openfga). Bootstraps a store + authz model. Required by the Hermes project spawner."
  type        = bool
  default     = true
}

variable "openfga_db_password" {
  description = "Password for the 'openfga' Postgres role. Used by module.openfga to authenticate to the shared platform-infra Postgres."
  type        = string
  default     = "0penSk22ma!"
  sensitive   = true
}

# --- Keel (registry-polling Deployment auto-updater) ---

variable "keel_enabled" {
  description = "Deploy Keel cluster-side. With Keel running and the spawner Deployment carrying `keel.sh/policy=force` annotations, Harbor pushes auto-roll the spawner without manual `kubectl rollout restart`."
  type        = bool
  default     = true
}

# --- Monitoring (Prometheus + Grafana + Loki + Alloy) ---

variable "monitoring_enabled" {
  description = "Deploy the monitoring stack (kube-prometheus-stack + Loki + Alloy). Grafana is fronted by Keycloak OIDC via the platform realm."
  type        = bool
  default     = false
}

variable "grafana_admin_password" {
  description = "Bootstrap Grafana admin password (local `admin` user). OIDC users take over once realm is seeded; keep this as break-glass."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_oidc_client_secret" {
  description = "OIDC client secret for Grafana. Must match the `grafana` client seeded by the realm module."
  type        = string
  default     = ""
  sensitive   = true
}

variable "monitoring_prometheus_storage_size" {
  description = "PVC size for Prometheus' TSDB."
  type        = string
  default     = "20Gi"
}

variable "monitoring_prometheus_retention" {
  description = "Prometheus data retention window."
  type        = string
  default     = "15d"
}

variable "monitoring_alertmanager_storage_size" {
  description = "PVC size for Alertmanager."
  type        = string
  default     = "2Gi"
}

variable "monitoring_grafana_storage_size" {
  description = "PVC size for Grafana."
  type        = string
  default     = "5Gi"
}

variable "monitoring_loki_storage_size" {
  description = "PVC size for Loki (SingleBinary mode)."
  type        = string
  default     = "20Gi"
}

variable "monitoring_loki_retention" {
  description = "Loki retention window (e.g. 168h = 7d)."
  type        = string
  default     = "168h"
}
