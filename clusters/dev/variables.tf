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

variable "local_gateway_ip" {
  description = "Optional host-reachable Gateway IP used by Terraform local bootstrap scripts via curl --resolve when platform hostnames are not in DNS or /etc/hosts."
  type        = string
  default     = ""
}

variable "local_gateway_port" {
  description = "HTTPS port paired with local_gateway_ip for Terraform local bootstrap scripts. Use 9443 when forwarding localhost:9443 to Traefik 443."
  type        = number
  default     = 443
}

variable "containerd_certs_d_path" {
  description = "Path on each node where containerd reads per-registry hosts.toml overrides. Empty defaults to the upstream `/etc/containerd/certs.d` (kubeadm, Docker Desktop). k3s reads from `/var/lib/rancher/k3s/agent/etc/containerd/certs.d` instead — set that here when running on k3s."
  type        = string
  default     = ""
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
    Example: ["*.vm.dev.openschema.io"].
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

    Let's Encrypt modes require letsencrypt_email + dns_provider =
    "cloudflare" + cloudflare_api_token.
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
  description = "DNS-01 provider for wildcard certs: 'cloudflare' or 'none' (HTTP-01, no wildcards). Local dev (selfsigned) uses 'none'; ACME wildcards require 'cloudflare'."
  type        = string
  default     = "cloudflare"
  validation {
    condition     = contains(["cloudflare", "none"], var.dns_provider)
    error_message = "dns_provider must be one of: cloudflare, none."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission. Required when dns_provider = 'cloudflare'."
  type        = string
  default     = ""
  sensitive   = true
}

# Removed: tls_enabled, cert_manager_enabled, cert_manager_wildcard_cert,
# cert_manager_selfsigned_enabled, cert_manager_issuer, gateway_tls_secret_name (duplicated above)
# All derived from var.tls_mode now. See main.tf `locals { tls_* }` block.

# --- Keycloak ---
variable "keycloak_admin_username" {
  description = "Bootstrap admin username for Keycloak master realm (also used by the Terraform keycloak provider for realm/user/group resources)."
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

variable "keycloak_realm_name" {
  description = "Name of the Keycloak realm the keycloak-realm module creates (also the realm slug in URLs, e.g. /realms/<name>)."
  type        = string
  default     = "platform"
}

variable "keycloak_realm_display_name" {
  description = "Human-readable realm name shown in Keycloak's UI."
  type        = string
  default     = "Agent Platform"
}

variable "keycloak_realm_password_policy" {
  description = "Keycloak password policy string applied to the realm. Empty disables. Examples: `length(8)`, `length(12) and digits(1) and upperCase(1)`. Dev defaults to empty so weak tfvars passwords work."
  type        = string
  default     = ""
}

variable "keycloak_realm_groups" {
  description = "Groups to create in the platform realm. The default is just `platform-admin` (wired into Forgejo/Harbor/Grafana as the admin group). Add more for downstream RBAC."
  type        = list(string)
  default     = ["platform-admin"]
}

variable "keycloak_realm_users" {
  description = <<-EOT
    Realm users keyed by username. Each entry:

      email              = string
      first_name         = string (optional)
      last_name          = string (optional)
      password           = string (sensitive)
      password_temporary = bool (default true). Force password change
                           on first login. Set false in dev where the
                           tfvars password is the actual login password.
      groups             = list(string). Group names must exist in
                           `keycloak_realm_groups`. Members of
                           `platform-admin` auto-promote to admin in
                           Forgejo / Harbor / Grafana on every OIDC
                           login.

    The first/primary admin goes here too — there is no separate
    "bootstrap admin" block. Empty map = no realm users (Keycloak
    master admin is still usable for setup).
  EOT
  type = map(object({
    enabled            = optional(bool, true)
    email              = string
    email_verified     = optional(bool, true)
    first_name         = optional(string, "")
    last_name          = optional(string, "")
    password           = string
    password_temporary = optional(bool, true)
    groups             = optional(list(string), [])
  }))
  default   = {}
  sensitive = true
}

variable "hermes_client_secret" {
  description = "OIDC client secret for the `hermes` client in the platform realm (service identity for the hermes-agent binary running inside each VM / agent-sandbox pod)."
  type        = string
  default     = ""
  sensitive   = true
}

# Bootstrap admin is now just an entry in `keycloak_realm_users` —
# no need for a separate variable block.

# --- Forgejo mirror sources -----------------------------------------------

variable "forgejo_fork_owner" {
  description = "Forgejo org or user that owns the forked repos (URL path: <forgejo>/<owner>/<repo>). Empty = admin user. Setting an org name lets the bootstrap Job create the org and centralize repo-level secrets there."
  type        = string
  default     = ""
}

variable "forgejo_fork_repos" {
  description = <<-EOT
    Repos to fork into Forgejo on cluster bootstrap (one-time clone via
    `POST /api/v1/repos/migrate` with `mirror: false` — independent and
    writable, no upstream sync). Use for repos whose Forgejo Actions
    workflows you iterate on in-cluster without round-tripping through
    GitHub. Empty = no forks.

    Map key is the LOCAL repo name in Forgejo (URL path: <forgejo>/<owner>/<key>).
    Per-entry `auth_username` / `auth_password` override the cluster-wide
    `github_clone_username` / `github_clone_token` defaults.
  EOT
  type = map(object({
    clone_addr    = string
    description   = optional(string, "")
    private       = optional(bool, false)
    auth_username = optional(string, "")
    auth_password = optional(string, "")
  }))
  default = {}
}

variable "github_clone_username" {
  description = "GitHub username used by Forgejo to authenticate against private upstream repos when forking. Per-entry `auth_username` in `forgejo_fork_repos` overrides this. Empty = anonymous (works for public repos)."
  type        = string
  default     = ""
}

variable "github_clone_token" {
  description = "GitHub Personal Access Token (read-only `repo` scope is enough). Sensitive. Per-entry `auth_password` overrides this."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Forgejo (in-cluster git, dev only) ---

variable "forgejo_enabled" {
  description = "Deploy Forgejo. Dev-cluster only per DESIGN.md."
  type        = bool
  default     = false
}

variable "forgejo_admin_username" {
  description = "Forgejo admin username (seeded on first boot). Cannot be 'admin' — Forgejo 15+ reserves it and the configure-gitea init container CrashLoops with `CreateUser: name is reserved`."
  type        = string
  default     = "forgejo-admin"

  validation {
    condition     = lower(var.forgejo_admin_username) != "admin"
    error_message = "forgejo_admin_username cannot be 'admin' — Forgejo 15+ reserves that name. Use e.g. 'forgejo-admin'."
  }
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

variable "harbor_admin_username" {
  description = "Harbor bootstrap admin username. Harbor itself enforces `admin`; this exists for symmetry with other apps."
  type        = string
  default     = "admin"
}

variable "harbor_admin_password" {
  description = "Harbor bootstrap admin password. Used to login at /harbor/sign-in and by the OIDC-config local-exec."
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_admin_email" {
  description = "Email shown for Harbor's built-in admin user. Cosmetic — Harbor exposes it in the UI."
  type        = string
  default     = "admin@example.com"
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
  description = "DevPod operator image. Empty (default) → derived from var.domain at module-call time. Override for locally-built tags."
  type        = string
  default     = ""
}

variable "devpod_default_image" {
  description = "Default DevPod base image (used when a DevPod CR leaves .spec.image blank). Empty (default) → derived from var.domain."
  type        = string
  default     = ""
}

# --- Forgejo Runner (CI) ---

variable "forgejo_runner_enabled" {
  description = "Deploy a Forgejo Actions runner with a BuildKit sidecar. Requires Forgejo up and reachable."
  type        = bool
  default     = true
}

variable "forgejo_runner_replicas" {
  description = "Number of runner replicas."
  type        = number
  default     = 1
}

variable "forgejo_runner_dind_mtu" {
  description = "MTU for the docker0 bridge inside the runner's DinD container. Set to the pod network's eth0 MTU when smaller than 1500 (k3s/Flannel vxlan: 1450, Wireguard: 1380). 0 = leave docker default; mismatch silently breaks `docker pull` of base images."
  type        = number
  default     = 0
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

# --- oauth2-proxy (front-door for platform UIs, fronted by Keycloak platform realm) ---

variable "oauth2_proxy_client_id" {
  description = "Keycloak OIDC client_id for oauth2-proxy. The realm module registers a client with this id; the oauth2-proxy module authenticates against it. Both sides read from this variable."
  type        = string
  default     = "oauth2-proxy"
}

variable "forgejo_client_id" {
  description = "Keycloak OIDC client_id for Forgejo."
  type        = string
  default     = "forgejo"
}

variable "harbor_client_id" {
  description = "Keycloak OIDC client_id for Harbor."
  type        = string
  default     = "harbor"
}

variable "grafana_client_id" {
  description = "Keycloak OIDC client_id for Grafana."
  type        = string
  default     = "grafana"
}

# --- agent-sandbox (workspace-pod base images) ---

variable "agent_sandbox_build_enabled" {
  description = "Build the agent-sandbox basic + desktop images in-cluster (kaniko Jobs cloning from github.com/oscio/agent-sandbox) and push them to Harbor on every fresh apply. The images themselves have no in-cluster consumer until the devpod operator is enabled — disable to skip ~25min of build time when iterating on unrelated infra."
  type        = bool
  default     = true
}

# --- Console (better-auth in services/console) ---

variable "console_enabled" {
  description = "Register the `console` OIDC client in Keycloak. Required for the better-auth integration in services/console to work."
  type        = bool
  default     = false
}

variable "console_client_id" {
  description = "Keycloak OIDC client_id for the console (better-auth)."
  type        = string
  default     = "console"
}

variable "console_oidc_client_secret" {
  description = "OIDC client secret for the console. Plumbed into BETTER_AUTH's KEYCLOAK_CLIENT_SECRET. Sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "console_db_password" {
  description = "Password for the `console` Postgres role used by the console module's better-auth tables. Sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "console_better_auth_secret" {
  description = "BETTER_AUTH_SECRET for the console (≥32 bytes base64). Generate with `openssl rand -base64 32`. Sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "console_web_image" {
  description = "Fully-qualified console-web image (Harbor). The Forgejo workflow at services/console/.forgejo/workflows/build.yml pushes :<sha> and :latest."
  type        = string
  default     = "cr.dev.openschema.io/agent-platform/console-web:latest"
}

variable "console_api_image" {
  description = "Fully-qualified console-api image. Reused by the auth-migrate Job."
  type        = string
  default     = "cr.dev.openschema.io/agent-platform/console-api:latest"
}

variable "hermes_client_id" {
  description = "Keycloak OIDC client_id for the hermes-agent confidential client (token-exchange source). hermes-agent is the binary running inside each VM / agent-sandbox pod."
  type        = string
  default     = "hermes"
}

variable "devpod_client_id" {
  description = "Keycloak OIDC client_id for the DevPod token-exchange target."
  type        = string
  default     = "devpod"
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

# --- OpenFGA (Zanzibar-style authorization engine) ---

variable "openfga_enabled" {
  description = "Deploy OpenFGA on the cluster (module.openfga). Bootstraps a store + authz model for downstream consumers (e.g. the upcoming console.<domain>)."
  type        = bool
  default     = true
}

variable "openfga_db_password" {
  description = "Password for the 'openfga' Postgres role. Used by module.openfga to authenticate to the shared platform-infra Postgres."
  type        = string
  default     = "0penSk22ma!"
  sensitive   = true
}

# --- Argo CD (replaces Keel as the GitOps + image-update layer) ---

variable "argocd_enabled" {
  description = "Deploy Argo CD + Image Updater cluster-side. UI at cd.<domain>. Image Updater watches Harbor and patches Argo CD Applications when new tags appear."
  type        = bool
  default     = true
}

# --- Knative Serving (Phase-2 Functions runtime) ---

variable "knative_enabled" {
  description = "Install Knative Serving + Kourier for the Functions runtime. Adds ~30 CRDs and ~8 Deployments."
  type        = bool
  default     = true
}

variable "keda_enabled" {
  description = "Install KEDA for event-driven autoscaling (cron / queue / custom triggers)."
  type        = bool
  default     = true
}


variable "argocd_admin_password" {
  description = "Plaintext password for the built-in `admin` user. Bcrypt-hashed at apply time. Break-glass; OIDC is the human path."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_client_id" {
  description = "OIDC client_id Argo CD presents to Keycloak."
  type        = string
  default     = "argocd"
}

variable "argocd_oidc_client_secret" {
  description = "OIDC client secret for Argo CD. Required when argocd_enabled = true."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Monitoring (Prometheus + Grafana + Loki + Alloy) ---

variable "monitoring_enabled" {
  description = "Deploy the monitoring stack (kube-prometheus-stack + Loki + Alloy). Grafana is fronted by Keycloak OIDC via the platform realm."
  type        = bool
  default     = false
}

variable "grafana_admin_username" {
  description = "Bootstrap Grafana admin username. Wired into the chart's `adminUser`."
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Bootstrap Grafana admin password (local `admin` user). OIDC users take over once realm is seeded; keep this as break-glass."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_admin_email" {
  description = "Email for the built-in Grafana admin user. Wired into `grafana.ini → security.admin_email`."
  type        = string
  default     = "admin@example.com"
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
