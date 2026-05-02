# --- Identity / placement ---
variable "namespace" {
  description = "Namespace where the console runs."
  type        = string
  default     = "platform-console"
}

variable "release_name" {
  description = "Prefix for in-namespace resources (deployments, services, configmaps)."
  type        = string
  default     = "console"
}

variable "hostname" {
  description = "Public hostname the console is served at (e.g. console.<domain>)."
  type        = string
}

variable "tls_enabled" {
  description = "Whether the public URL is https. Determines BETTER_AUTH_URL scheme."
  type        = bool
  default     = true
}

# --- Gateway API ---
variable "gateway_parent_ref" {
  description = "Gateway API parentRef the HTTPRoute attaches to (Traefik gateway in this cluster)."
  type = object({
    name        = string
    namespace   = string
    sectionName = optional(string)
  })
}

# --- Images ---
variable "web_image" {
  description = "Fully-qualified Next.js (web) image, e.g. cr.<domain>/agent-platform/console-web:<tag>."
  type        = string
}

variable "api_image" {
  description = "Fully-qualified NestJS (api) image, e.g. cr.<domain>/agent-platform/console-api:<tag>. Reused by the auth-migrate Job."
  type        = string
}

variable "web_replicas" {
  description = "Replicas for the web Deployment."
  type        = number
  default     = 1
}

variable "api_replicas" {
  description = "Replicas for the api Deployment."
  type        = number
  default     = 1
}

# --- Harbor (registry pull) ---
variable "harbor_registry" {
  description = "Harbor host, e.g. cr.dev.openschema.io. Encoded into the dockerconfigjson pull Secret."
  type        = string
}

variable "harbor_username" {
  description = "Harbor username for image pulls. Sensitive."
  type        = string
  sensitive   = true
}

variable "harbor_password" {
  description = "Harbor password (or robot token) for image pulls. Sensitive."
  type        = string
  sensitive   = true
}

# --- Postgres backend (shared platform-infra) ---
variable "postgres_host" {
  description = "Postgres hostname (cluster-internal)."
  type        = string
}

variable "postgres_port" {
  description = "Postgres TCP port."
  type        = number
  default     = 5432
}

variable "postgres_superuser_username" {
  description = "Postgres superuser username (used only by the db-create Job)."
  type        = string
  default     = "postgres"
}

variable "postgres_superuser_password" {
  description = "Postgres superuser password. Sensitive."
  type        = string
  sensitive   = true
}

variable "console_db_name" {
  description = "Database name for the console."
  type        = string
  default     = "console"
}

variable "console_db_username" {
  description = "Postgres role the console authenticates as."
  type        = string
  default     = "console"
}

variable "console_db_password" {
  description = "Password for the console Postgres role. Sensitive."
  type        = string
  sensitive   = true
}

# --- better-auth ---
variable "better_auth_secret" {
  description = "BETTER_AUTH_SECRET (32 bytes base64 recommended). Sensitive."
  type        = string
  sensitive   = true
}

# --- Keycloak (OIDC IdP) ---
variable "keycloak_issuer_url" {
  description = "OIDC issuer URL for the platform realm, e.g. https://auth.<domain>/realms/platform."
  type        = string
}

variable "keycloak_client_id" {
  description = "OIDC client id provisioned for the console (default `console`)."
  type        = string
  default     = "console"
}

variable "keycloak_client_secret" {
  description = "OIDC client secret for the console. Sensitive."
  type        = string
  sensitive   = true
}

# --- Self-signed platform CA (selfsigned TLS mode only) ---
# When set, the module mirrors the CA from
# `<ca_source_secret_namespace>/<ca_source_secret_name>` into a ConfigMap
# in this namespace, mounts it into web/api pods, and points Node.js at
# it via NODE_EXTRA_CA_CERTS so server-side fetches to Keycloak (which
# uses the same self-signed cert) verify correctly.
variable "ca_source_secret_name" {
  description = "Secret holding the platform CA bundle in `data.ca.crt` (typically cert-manager/platform-root-ca). Empty disables CA injection — fine for letsencrypt-* TLS modes."
  type        = string
  default     = ""
}

variable "ca_source_secret_namespace" {
  description = "Namespace of the CA source Secret."
  type        = string
  default     = "cert-manager"
}

# --- OpenFGA (consumed via the bootstrap Secret module.openfga writes) ---
variable "openfga_namespace" {
  description = "Namespace where OpenFGA + the bootstrap Secret live."
  type        = string
  default     = "platform-openfga"
}

variable "openfga_bootstrap_secret_name" {
  description = "Name of the Secret module.openfga writes (store_id, auth_model_id, api_url)."
  type        = string
  default     = "openfga-bootstrap"
}

# --- Forgejo (consumed by the Functions module to provision repos) ---
# When forgejo_admin_secret_name is empty the console-api falls back
# to DB-only function CRUD — useful for environments without Forgejo.
variable "forgejo_internal_url" {
  description = "Cluster-internal Forgejo base URL, e.g. http://forgejo-http.platform-forgejo.svc.cluster.local:3000."
  type        = string
  default     = ""
}

variable "forgejo_public_url" {
  description = "User-facing Forgejo base URL, e.g. https://git.<domain>. Used for 'Open in Forgejo' links."
  type        = string
  default     = ""
}

variable "forgejo_namespace" {
  description = "Namespace where Forgejo + the admin Secret live."
  type        = string
  default     = "platform-forgejo"
}

variable "forgejo_admin_secret_name" {
  description = "Name of the Secret carrying Forgejo admin Basic-auth creds (keys: username, password). Empty disables the Forgejo cascade."
  type        = string
  default     = ""
}

variable "forgejo_function_org" {
  description = "Org under which Phase-2 function repos are created."
  type        = string
  default     = "service"
}

variable "forgejo_template_org" {
  description = "Org tf forks the platform-managed template repos into (function-template-base-python, ...). Console-api forks user functions FROM this org."
  type        = string
  default     = "platform"
}

# --- Image rollout policy ---
variable "image_pull_policy" {
  description = "imagePullPolicy for the console Deployments. `Always` pairs with Keel-driven rollouts on `:latest`."
  type        = string
  default     = "IfNotPresent"
}

variable "keel_managed" {
  description = "Annotate Deployments with `keel.sh/policy=force` so module.keel rolls them on new digests."
  type        = bool
  default     = true
}

variable "vm_image_base" {
  description = "Image ref the api uses when creating a `base` VM (StatefulSet container). E.g. cr.<domain>/agent-platform/agent-sandbox:latest. Empty = base VMs disabled."
  type        = string
  default     = ""
}

variable "vm_image_desktop" {
  description = "Image ref the api uses when creating a `desktop` VM. E.g. cr.<domain>/agent-platform/agent-sandbox-desktop:latest. Empty = desktop VMs disabled."
  type        = string
  default     = ""
}

variable "agent_image" {
  description = "Image ref the api uses for the agent runtime — both standalone Agent pods and VM-attached sidecars. The image's entrypoint reads AGENT_TYPE at boot to pick which adapter to dispatch on. E.g. cr.<domain>/agent-platform/agents:latest. Empty = agent feature disabled."
  type        = string
  default     = ""
}

variable "vm_domain" {
  description = "Hostname suffix used to derive `<vm-slug>.<vm_domain>` for each VM (e.g. vm.dev.example.com). Per-VM HTTPRoutes attach to the cluster Gateway under `<slug>-term.<vm_domain>` and `<slug>-vnc.<vm_domain>`."
  type        = string
  default     = "vm.localhost"
}

variable "function_dev_image" {
  description = "Image ref console-api spawns the per-function dev Knative Service from. ConfigMap-mounted user folder + this image's runner = no-build edit/test loop. E.g. cr.<domain>/agent-platform/function-dev-python:latest."
  type        = string
  default     = ""
}

variable "function_domain" {
  description = "Domain Knative auto-generates Service URLs under (matches knative-serving's config-domain). console-api uses this to build the Host header when proxying Test-tab invocations through Kourier. E.g. fn.dev.example.com."
  type        = string
  default     = ""
}

variable "function_image_prefix" {
  description = "Image prefix the Deploy flow patches Knative Services onto. Each function's built image lives at <prefix>/<slug>:<sha>. E.g. cr.<domain>/agent-platform/functions."
  type        = string
  default     = ""
}

# --- Argo CD-managed Deployments (replaces Keel auto-roll path) -----

variable "argocd_managed_deployments" {
  description = "When true, the module SKIPS creating kubernetes_deployment.{api,web} (ArgoCD applies them from the manifests in services/console/k8s/) and instead emits an Argo CD Application + repo Secret. The argocd-image-updater annotations on the Application replace Keel's role: Harbor push → patch Application → Argo CD syncs."
  type        = bool
  default     = false
}

variable "argocd_namespace" {
  description = "Namespace Argo CD lives in. The Application CR + repo Secret are created here."
  type        = string
  default     = "platform-argocd"
}

variable "argocd_repo_url" {
  description = "Git URL Argo CD pulls manifests from (e.g. https://git.<domain>/platform/console.git). Required when argocd_managed_deployments = true."
  type        = string
  default     = ""
}

variable "argocd_repo_path" {
  description = "Path inside the repo containing the kustomize root."
  type        = string
  default     = "k8s"
}

variable "argocd_repo_revision" {
  description = "Git ref Argo CD tracks (branch / tag / SHA)."
  type        = string
  default     = "main"
}

variable "argocd_repo_username" {
  description = "Username for the Git repo (e.g. forgejo-admin). Empty = anonymous (won't work against private forgejo repos)."
  type        = string
  default     = ""
}

variable "argocd_repo_password" {
  description = "Password / token for the Git repo. Stored in a Secret labelled argocd.argoproj.io/secret-type=repository."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_repo_insecure" {
  description = "Skip TLS verification when Argo CD clones the repo. Set true when the Git server uses a selfsigned cert and you don't want to mount a CA bundle."
  type        = bool
  default     = false
}

variable "harbor_registry_prefix" {
  description = "Hostname prefix the argocd-image-updater registry config matches against, e.g. cr.<domain>. Used in image-list annotations on the Application. Empty = derived from var.harbor_registry."
  type        = string
  default     = ""
}

variable "vm_gateway_name" {
  description = "Gateway API parentRef name for per-VM HTTPRoutes."
  type        = string
  default     = "platform-gateway"
}

variable "vm_gateway_namespace" {
  description = "Namespace of the Gateway named in vm_gateway_name."
  type        = string
  default     = "platform-traefik"
}

variable "vm_auth_forward_url" {
  description = "ForwardAuth target URL the api wires into a per-VM-namespace Traefik Middleware. Typically `http://oauth2-proxy.platform-oauth2-proxy.svc.cluster.local/oauth2/auth`. Empty = no auth gate."
  type        = string
  default     = ""
}

variable "vm_auth_oauth_service_name" {
  description = "oauth2-proxy Service name for the per-VM errors-redirect Traefik Middleware (catches 401 → /oauth2/start)."
  type        = string
  default     = ""
}

variable "vm_auth_oauth_service_namespace" {
  description = "Namespace of vm_auth_oauth_service_name."
  type        = string
  default     = ""
}

variable "vm_auth_oauth_service_port" {
  description = "Port of vm_auth_oauth_service_name (the chart's default ClusterIP Service is 80)."
  type        = number
  default     = 80
}

variable "oauth_proxy_url" {
  description = "Public oauth2-proxy URL (e.g. https://oauth.<domain>). Wraps VM launch links in /oauth2/start?rd=<vm-url> so users get silent SSO before hitting the VM's forwardAuth gate. Empty = launch links go directly to the VM URL (blank 401 if no session)."
  type        = string
  default     = ""
}
