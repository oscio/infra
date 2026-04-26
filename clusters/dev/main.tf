#
# Dev cluster — Agent Platform
#
# Installs Traefik (Gateway API), Keycloak, oauth2-proxy, and Argo CD.
# Dev defaults: 1 replica Keycloak (embedded PG), non-HA Argo CD,
# letsencrypt-staging.
#
# Gateway API routing: Traefik creates a 'traefik' GatewayClass and a
# shared 'platform-gateway' Gateway. All downstream components create
# HTTPRoutes attached to that Gateway.
#

locals {
  keycloak_hostname     = "auth.${var.domain}"
  oauth2_proxy_hostname = "oauth.${var.domain}"
  argocd_hostname       = "cd.${var.domain}"
  hermes_hostname       = "hermes.${var.domain}"
  forgejo_hostname      = "git.${var.domain}"
  harbor_hostname       = "registry.${var.domain}"
  grafana_hostname      = "grafana.${var.domain}"

  gateway_hostnames = ["*.${var.domain}"]

  # ---------------------------------------------------------------------------
  # TLS mode resolution.
  #
  # Single user-facing knob (var.tls_mode) drives every TLS-related feature
  # flag. Valid values:
  #   - "off"                  → plain HTTP, no cert-manager
  #   - "selfsigned"           → cert-manager + internal CA, wildcard signed
  #                               by selfsigned-ca (browsers need CA trusted)
  #   - "letsencrypt-staging"  → Let's Encrypt staging (fake CA, untrusted;
  #                               useful to dry-run ACME without rate limits)
  #   - "letsencrypt-prod"     → Let's Encrypt prod (real trusted certs)
  #
  # Let's Encrypt modes require: letsencrypt_email + dns_provider (cloudflare
  # or route53) + that provider's credentials. Enforced by preconditions in
  # the cert-manager module.
  # ---------------------------------------------------------------------------
  tls_is_off                 = var.tls_mode == "off"
  tls_is_selfsigned          = var.tls_mode == "selfsigned"
  tls_is_letsencrypt_staging = var.tls_mode == "letsencrypt-staging"
  tls_is_letsencrypt_prod    = var.tls_mode == "letsencrypt-prod"
  tls_is_letsencrypt         = local.tls_is_letsencrypt_staging || local.tls_is_letsencrypt_prod

  cert_manager_enabled       = !local.tls_is_off
  cert_manager_selfsigned    = local.tls_is_selfsigned
  cert_manager_letsencrypt   = local.tls_is_letsencrypt
  cert_manager_wildcard_cert = !local.tls_is_off
  tls_enabled                = !local.tls_is_off

  cert_manager_issuer = (
    local.tls_is_selfsigned ? "selfsigned-ca" :
    local.tls_is_letsencrypt_staging ? "letsencrypt-staging" :
    local.tls_is_letsencrypt_prod ? "letsencrypt-prod" :
    ""
  )

  # If cert-manager is creating the wildcard cert, use its output secret name.
  # Otherwise, use whatever the user provided (or empty = HTTP-only).
  effective_tls_secret_name = (
    local.cert_manager_enabled && local.cert_manager_wildcard_cert
    ? module.cert_manager[0].wildcard_certificate_secret_name
    : var.gateway_tls_secret_name
  )

  # All OIDC clients live in the platform realm for consistency. Scheme is
  # driven by tls_enabled (oauth2-proxy will try to connect to the issuer on
  # startup, so the URL must match what's actually served).
  keycloak_platform_issuer_url = "${local.tls_enabled ? "https" : "http"}://${local.keycloak_hostname}/realms/platform"
}

# Fail fast when Let's Encrypt is requested without the required inputs. This
# resource is a no-op check that produces a clear error message during plan.
resource "terraform_data" "tls_mode_validation" {
  lifecycle {
    precondition {
      condition = contains(
        ["off", "selfsigned", "letsencrypt-staging", "letsencrypt-prod"],
        var.tls_mode,
      )
      error_message = "tls_mode must be one of: off, selfsigned, letsencrypt-staging, letsencrypt-prod."
    }
    precondition {
      condition     = !local.tls_is_letsencrypt || var.letsencrypt_email != ""
      error_message = "letsencrypt_email is required when tls_mode = letsencrypt-staging or letsencrypt-prod."
    }
    precondition {
      # ACME wildcard requires DNS-01 — http-01 ("none") can't wildcard.
      condition     = !local.tls_is_letsencrypt || contains(["cloudflare", "route53"], var.dns_provider)
      error_message = "When tls_mode is a letsencrypt-* mode, dns_provider must be 'cloudflare' or 'route53' (DNS-01 is required for wildcard certificates)."
    }
    precondition {
      condition     = !local.tls_is_letsencrypt || var.dns_provider != "cloudflare" || var.cloudflare_api_token != ""
      error_message = "cloudflare_api_token is required when tls_mode is letsencrypt-* and dns_provider = 'cloudflare'."
    }
    precondition {
      condition     = !local.tls_is_letsencrypt || var.dns_provider != "route53" || (var.route53_region != "" && var.route53_hosted_zone_id != "")
      error_message = "route53_region and route53_hosted_zone_id are required when tls_mode is letsencrypt-* and dns_provider = 'route53'."
    }
  }
}

module "cert_manager" {
  source = "../../modules/cert-manager"
  count  = local.cert_manager_enabled ? 1 : 0

  letsencrypt_email         = var.letsencrypt_email
  dns_provider              = var.dns_provider
  cloudflare_api_token      = var.cloudflare_api_token
  route53_region            = var.route53_region
  route53_hosted_zone_id    = var.route53_hosted_zone_id
  route53_access_key_id     = var.route53_access_key_id
  route53_secret_access_key = var.route53_secret_access_key

  # Which issuer flavour to create is driven by tls_mode.
  selfsigned_enabled = local.cert_manager_selfsigned

  wildcard_certificate_enabled     = local.cert_manager_wildcard_cert
  wildcard_certificate_domain      = var.domain
  wildcard_certificate_namespace   = "platform-traefik"
  wildcard_certificate_secret_name = "wildcard-${replace(var.domain, ".", "-")}-tls"
  wildcard_certificate_issuer      = local.cert_manager_issuer
}

module "traefik" {
  source = "../../modules/traefik"

  gateway_api_enabled     = var.gateway_api_enabled
  gateway_hostnames       = local.gateway_hostnames
  gateway_tls_secret_name = local.effective_tls_secret_name
  service_type            = var.traefik_service_type
  tls_enabled             = local.tls_enabled

  # Deep-wildcard HTTPS listeners. Gateway API wildcards only match one DNS
  # label, so '*.dev.openschema.io' does NOT cover 'foo.hermes.dev.openschema.io';
  # each deep-wildcard hostname needs its own listener + cert-manager cert.
  # The traefik module creates one Certificate (signed by cert_manager_issuer)
  # + one listener per entry.
  extra_listener_hostnames = var.traefik_extra_listener_hostnames
  cert_manager_issuer      = local.cert_manager_issuer

  # Traefik needs its namespace to exist for the Certificate to land in it;
  # cert-manager's Certificate resource is in platform-traefik.
  depends_on = [module.cert_manager]
}

# CoreDNS rewrite so in-cluster DNS for *.<domain> resolves to Traefik
# (rather than following the host's /etc/hosts 127.0.0.1 mapping). Required
# for oauth2-proxy / argo-cd / harbor / etc. to reach Keycloak by its public
# hostname from inside the cluster.
module "platform_dns" {
  source = "../../modules/platform-dns"

  platform_domain           = var.domain
  gateway_service_name      = "traefik"
  gateway_service_namespace = "platform-traefik"

  depends_on = [module.traefik]
}

# Propagate the self-signed CA bundle to every consumer namespace so OIDC
# clients (oauth2-proxy, argo-cd dex, forgejo, harbor, hermes) can validate
# the wildcard cert served by Traefik. Skipped when tls_mode is a public
# (letsencrypt-*) mode — those are trusted by the system roots anyway.
# Note: oauth2-proxy and forgejo modules mirror the CA into their own
# namespaces via their ca_source_secret_name input (so the CA ConfigMap
# is lifecycle-coupled to their Helm release). We still use this module
# for the namespaces that don't own their own copy (argo, harbor, hermes).
module "platform_ca" {
  source = "../../modules/platform-ca"
  count  = local.tls_is_selfsigned ? 1 : 0

  source_secret_name      = "platform-root-ca"
  source_secret_namespace = "cert-manager"

  target_namespaces = compact([
    "platform-argocd", # argocd is always on in Phase 1
    var.harbor_enabled ? "platform-harbor" : "",
    var.hermes_enabled ? "platform-hermes" : "",
  ])

  depends_on = [
    module.cert_manager,
    module.argocd,
    module.harbor,
    module.hermes,
  ]
}

# Shared Postgres for platform-level services (Keycloak for now; extendable
# to Forgejo/Harbor later). Lives in platform-infra. Dev-only: single pod,
# Recreate strategy, no HA.
module "postgres" {
  source = "../../modules/postgres"

  namespace          = "platform-infra"
  release_name       = "postgres"
  superuser_password = var.platform_postgres_superuser_password
  storage_class      = var.storage_class
  storage_size       = var.platform_postgres_storage_size

  databases = [
    {
      database = "keycloak"
      username = "keycloak"
      password = var.keycloak_db_password
    },
    {
      database = "forgejo"
      username = "forgejo"
      password = var.forgejo_db_password
    },
    {
      database = "harbor"
      username = "harbor"
      password = var.harbor_db_password
    },
  ]
}

module "keycloak" {
  source = "../../modules/keycloak"

  hostname            = local.keycloak_hostname
  admin_password      = var.keycloak_admin_password
  replicas            = 1
  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref

  db = {
    host     = module.postgres.host
    port     = module.postgres.port
    database = "keycloak"
    username = "keycloak"
    password = var.keycloak_db_password
  }

  depends_on = [module.postgres]
}

# oauth2-proxy protecting Hermes WebUI. Uses Keycloak *platform* realm
# (same realm as Argo CD / Forgejo / Harbor — consolidated per Shane's
# decision). The oauth2-proxy client is seeded by the keycloak-realm module.
module "oauth2_proxy" {
  source = "../../modules/oauth2-proxy"
  # oauth2-proxy hard-fails on startup if OIDC discovery can't reach the
  # issuer. Don't deploy it until Keycloak AND the platform realm are up.
  count = var.realm_enabled ? 1 : 0

  hostname            = local.oauth2_proxy_hostname
  oidc_issuer_url     = local.keycloak_platform_issuer_url
  oidc_client_id      = var.oauth2_proxy_client_id
  oidc_client_secret  = var.oauth2_proxy_client_secret
  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref
  tls_enabled         = local.tls_enabled
  cert_manager_issuer = local.cert_manager_issuer
  email_domains       = var.oauth2_proxy_email_domains
  cookie_domain       = ".${var.domain}"

  # Protect the Hermes hub (spawner) at hermes.<domain>. The spawner
  # serves the project dashboard; per-project pods live at
  # <pid>.hermes.<domain> and are fronted by the same oauth2-proxy via the
  # wildcard entry in extra_protected_hostnames below.
  protected_hostname         = var.agent_spawner_enabled ? local.hermes_hostname : ""
  upstream_service_name      = var.agent_spawner_enabled ? module.agent_spawner[0].service_name : ""
  upstream_service_namespace = var.agent_spawner_enabled ? module.agent_spawner[0].service_namespace : ""
  upstream_service_port      = 80

  # Trust the internal CA so OIDC discovery against Keycloak works. When
  # tls_mode="selfsigned", the module mirrors cert-manager/platform-root-ca
  # into a ConfigMap in its own namespace and mounts it. letsencrypt-* modes
  # use publicly-trusted certs, so no mirror needed.
  ca_source_secret_name      = local.tls_is_selfsigned ? "platform-root-ca" : ""
  ca_source_secret_namespace = "cert-manager"

  depends_on = [module.realm, module.platform_dns, module.cert_manager]
}

# Read the self-signed CA so we can inject it into Argo CD's OIDC config.
# (Argo CD doesn't read SSL_CERT_FILE like oauth2-proxy does — it validates
# the OIDC issuer using the rootCA field inside oidc.config.)
data "kubernetes_secret_v1" "platform_root_ca" {
  count = local.tls_is_selfsigned ? 1 : 0

  metadata {
    name      = "platform-root-ca"
    namespace = "cert-manager"
  }

  depends_on = [module.cert_manager]
}

module "argocd" {
  source = "../../modules/argocd"

  hostname            = local.argocd_hostname
  ha_enabled          = false
  oidc_issuer_url     = module.keycloak.issuer_url
  oidc_client_secret  = var.argocd_oidc_client_secret
  source_repos        = var.argocd_source_repos
  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref
  tls_enabled         = local.tls_enabled
  cert_manager_issuer = local.cert_manager_issuer

  # Trust the internal CA so argocd-server can reach Keycloak over https
  # without x509 errors. Only populated under tls_mode = "selfsigned".
  oidc_root_ca_pem = local.tls_is_selfsigned ? lookup(
    data.kubernetes_secret_v1.platform_root_ca[0].data,
    "ca.crt",
    "",
  ) : ""
}

# Seed the Keycloak realm, clients, and groups. Enable this AFTER Keycloak
# is running and reachable (two-phase apply).
module "realm" {
  source = "../../modules/keycloak-realm"
  count  = var.realm_enabled ? 1 : 0

  realm_name         = "platform"
  realm_display_name = "Agent Platform (dev)"

  oauth2_proxy_urls = compact([
    "https://${local.oauth2_proxy_hostname}",
    # Legacy single-shared Hermes (deprecated) OR the new multi-project
    # spawner hub — both use the same hermes.<domain> hostname so they
    # can't both be enabled at once, but either triggers registration.
    (var.hermes_enabled || var.agent_spawner_enabled) ? "https://${local.hermes_hostname}" : "",
  ])
  argocd_url  = "https://${local.argocd_hostname}"
  forgejo_url = var.forgejo_enabled ? "https://${local.forgejo_hostname}" : ""
  harbor_url  = var.harbor_enabled ? "https://${local.harbor_hostname}" : ""
  grafana_url = var.monitoring_enabled ? "https://${local.grafana_hostname}" : ""

  oauth2_proxy_client_secret = var.oauth2_proxy_client_secret
  argocd_client_secret       = var.argocd_oidc_client_secret
  hermes_client_secret       = var.hermes_client_secret
  forgejo_client_secret      = var.forgejo_oidc_client_secret
  harbor_client_secret       = var.harbor_oidc_client_secret
  grafana_client_secret      = var.grafana_oidc_client_secret

  # Token exchange requires Keycloak's fine-grained admin-authz feature,
  # which is off by default. Leave disabled until we actually need it.
  token_exchange_enabled = false

  # Dev convenience: no password policy so we can seed "admin" as the
  # bootstrap user password. Set to a real policy for staging/prod.
  password_policy = ""

  bootstrap_admin_user               = var.bootstrap_admin_user
  bootstrap_admin_email              = var.bootstrap_admin_email
  bootstrap_admin_password           = var.bootstrap_admin_password
  bootstrap_admin_password_temporary = var.bootstrap_admin_password_temporary
  bootstrap_admin_first_name         = var.bootstrap_admin_first_name
  bootstrap_admin_last_name          = var.bootstrap_admin_last_name

  depends_on = [module.keycloak]
}

# Hermes (single pod: agent + webui containers, shared PVC). Dev only.
module "hermes" {
  source = "../../modules/hermes"
  count  = var.hermes_enabled ? 1 : 0

  namespace    = "platform-hermes"
  release_name = "hermes"

  agent_image       = var.hermes_agent_image
  webui_image       = var.hermes_webui_image
  image_pull_secret = var.hermes_image_pull_secret

  storage_class          = var.storage_class
  storage_size           = var.hermes_storage_size
  workspace_storage_size = var.agent_workspace_storage_size

  # NOTE: run_as_uid/gid intentionally NOT passed — the agent and webui
  # images bake in their own User directives and break if overridden.

  default_provider = var.hermes_default_provider
  default_model    = var.hermes_default_model

  llm_api_keys   = var.hermes_llm_api_keys
  webui_password = var.hermes_webui_password

  cluster_access_enabled = var.hermes_cluster_access_enabled
}

# Hermes Spawner — hub UI at hermes.<domain> + per-project pod orchestrator.
# Replaces the single shared Hermes with a multi-tenant, OpenFGA-backed setup.
module "agent_spawner" {
  source = "../../modules/agent-spawner"
  count  = var.agent_spawner_enabled ? 1 : 0

  namespace    = "platform-spawner"
  release_name = "agent-spawner"
  image        = var.agent_spawner_image

  hub_hostname             = local.hermes_hostname
  project_hostname_suffix  = local.hermes_hostname
  project_namespace_prefix = "hermes-proj-"

  gateway_namespace    = "platform-traefik"
  gateway_name         = "platform-gateway"
  gateway_section_name = "https-hermes-dev-openschema-io"

  image_profiles = {
    basic   = var.agent_spawner_workspace_image
    desktop = var.agent_spawner_workspace_desktop_image
  }
  default_image_profile = "basic"
  desktop_image_profile = "desktop"
  storage_class         = var.storage_class

  # Forgejo automated git credential provisioning. Empty admin_token = off;
  # users set up git creds manually. Internal API URL bypasses TLS so the
  # spawner pod doesn't need the platform CA installed.
  forgejo_api_url               = var.forgejo_enabled ? "http://forgejo-http.platform-forgejo.svc.cluster.local:3000" : ""
  forgejo_public_host           = "git.${var.domain}"
  # Forgejo admin PAT — auto-minted by forgejo-bootstrap on every apply.
  # `try()` lets the count=0 branch (forgejo disabled) collapse to "" so
  # the spawner still boots in degraded mode.
  forgejo_admin_token           = try(module.forgejo_bootstrap[0].admin_token, "")
  forgejo_user_default_password = var.platform_postgres_superuser_password

  workspace_cluster_admin_enabled = var.agent_spawner_workspace_cluster_admin_enabled

  max_projects_per_user = var.agent_spawner_max_projects_per_user

  postgres_host               = module.postgres.host
  postgres_superuser_username = "postgres"
  postgres_superuser_password = var.platform_postgres_superuser_password

  db_name     = "spawner"
  db_username = "spawner"
  db_password = var.agent_spawner_db_password

  openfga_api_url       = var.openfga_enabled ? module.openfga[0].http_url : ""
  openfga_store_id      = var.openfga_enabled ? module.openfga[0].store_id : ""
  openfga_auth_model_id = var.openfga_enabled ? module.openfga[0].auth_model_id : ""

  llm_api_keys = var.hermes_llm_api_keys

  # Distribute the self-signed CA bundle to every project namespace so
  # pods can trust internal TLS endpoints.
  ca_configmap_data = local.tls_is_selfsigned ? {
    "ca.crt" = data.kubernetes_secret_v1.platform_root_ca[0].data["ca.crt"]
  } : {}

  log_level = var.agent_spawner_log_level

  depends_on = [module.postgres, module.openfga, module.realm, module.traefik]
}

# Forgejo — in-cluster Git (dev only).
# Depends on the realm module so the `forgejo` OIDC client exists before
# Forgejo boots with OIDC enabled.
module "forgejo" {
  source = "../../modules/forgejo"
  count  = var.forgejo_enabled ? 1 : 0

  namespace       = "platform-forgejo"
  domain          = var.domain
  hostname_prefix = "git"

  gateway_parent_ref = module.traefik.gateway_parent_ref

  storage_class     = var.storage_class
  repo_storage_size = var.forgejo_repo_storage_size

  # Shared platform Postgres (see module.postgres). The 'forgejo' DB + role
  # are pre-created via that module's `databases` list.
  db = {
    host     = module.postgres.host
    port     = module.postgres.port
    database = "forgejo"
    username = "forgejo"
    password = var.forgejo_db_password
  }

  admin_username = var.forgejo_admin_username
  admin_email    = var.forgejo_admin_email
  admin_password = var.forgejo_admin_password

  # OIDC is on iff the realm has been seeded (client exists to auth against).
  oidc_enabled       = var.realm_enabled
  oidc_issuer_url    = module.keycloak.issuer_url
  oidc_client_id     = "forgejo"
  oidc_client_secret = var.forgejo_oidc_client_secret

  # Trust the self-signed CA so Forgejo's init job can discover Keycloak.
  ca_source_secret_name      = local.tls_is_selfsigned ? "platform-root-ca" : ""
  ca_source_secret_namespace = "cert-manager"

  disable_registration = var.forgejo_disable_registration
  require_signin_view  = var.forgejo_require_signin_view
  ssh_service_type     = var.forgejo_ssh_service_type

  depends_on = [module.realm, module.postgres, module.platform_dns, module.cert_manager]
}

# Harbor — container registry (dev only).
# OIDC config is pushed via Harbor API after install (see module).
module "harbor" {
  source = "../../modules/harbor"
  count  = var.harbor_enabled ? 1 : 0

  namespace       = "platform-harbor"
  domain          = var.domain
  hostname_prefix = "registry"

  gateway_parent_ref = module.traefik.gateway_parent_ref

  storage_class         = var.storage_class
  registry_storage_size = var.harbor_registry_storage_size
  database_storage_size = var.harbor_database_storage_size

  admin_password = var.harbor_admin_password

  # Disable Trivy on dev (memory-constrained). Re-enable on a bigger cluster.
  trivy_enabled = false

  oidc_enabled       = var.realm_enabled
  oidc_issuer_url    = module.keycloak.issuer_url
  oidc_client_id     = "harbor"
  oidc_client_secret = var.harbor_oidc_client_secret
  oidc_admin_group   = "platform-admin"
  oidc_verify_cert   = var.harbor_oidc_verify_cert

  # Local-exec curl runs from the Terraform host, which doesn't trust the
  # internal CA. Skip cert verification for that local->gateway hop.
  local_exec_insecure_tls = local.tls_is_selfsigned

  depends_on = [module.realm, module.platform_dns]
}

# DevPod operator + CRD. Dev only.
# When enabled with run_controller = false, only installs the CRD and a
# namespace — useful to register CRs by hand before the operator exists.
module "devpod_operator" {
  source = "../../modules/devpod-operator"
  count  = var.devpod_operator_enabled ? 1 : 0

  namespace         = "platform-devpods"
  devpods_namespace = "platform-devpods"
  install_crd       = true
  install_operator  = var.devpod_operator_run_controller

  operator_image       = var.devpod_operator_image
  default_devpod_image = var.devpod_default_image
}

# Forgejo Runner — executes Actions workflows.
# Runs BuildKit (rootless) as a sidecar for `docker buildx build --push`.
# Fetches its registration token from Forgejo via admin API at plan time.
# Forgejo pull-mirror bootstrap. On first apply, mirrors the listed
# upstream repos into Forgejo so the in-cluster runner can build them.
# Empty source URLs = skip (e.g. when services are already pushed
# directly to Forgejo and don't need an upstream mirror).
# Harbor docker-config Secret used by:
#   1. The agent-spawner Deployment (to pull its own image from Harbor)
#   2. Per-project workspace pods (the spawner copies this Secret into
#      each project namespace + attaches it as an imagePullSecret on the
#      project's `hermes` ServiceAccount).
# Reuses the same robot account that forgejo-runner uses to push, since
# Harbor robot tokens grant push+pull on the same project.
resource "kubernetes_secret_v1" "harbor_pull_secret" {
  count = var.agent_spawner_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "harbor-pull-secret"
    namespace = "platform-spawner"
    labels = {
      "agent-platform/component" = "harbor-pull-secret"
    }
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.harbor_hostname) = {
          username = module.harbor_bootstrap[0].robot_name
          password = module.harbor_bootstrap[0].robot_secret
          auth     = base64encode("${module.harbor_bootstrap[0].robot_name}:${module.harbor_bootstrap[0].robot_secret}")
        }
      }
    })
  }

  depends_on = [module.harbor_bootstrap, module.agent_spawner]
}

# Forgejo bootstrap — mints an admin PAT for the agent-spawner. Runs on
# every apply (idempotent: deletes the named token if it exists, then
# recreates). Output flows into `module.agent_spawner.forgejo_admin_token`
# below.
module "forgejo_bootstrap" {
  source = "../../modules/forgejo-bootstrap"
  count  = var.forgejo_enabled && var.agent_spawner_enabled ? 1 : 0

  forgejo_url    = "https://${local.forgejo_hostname}"
  admin_user     = var.forgejo_admin_username
  admin_password = var.forgejo_admin_password

  depends_on = [module.forgejo, module.platform_dns]
}

# Harbor bootstrap — creates the `agent-platform` project + a robot
# account with push+pull. Runs on every apply (idempotent: project
# create returns 409 on exists; robot secret rotates). Output flows
# into the harbor-pull-secret K8s Secret + the forgejo-runner module.
module "harbor_bootstrap" {
  source = "../../modules/harbor-bootstrap"
  count  = var.harbor_enabled && var.agent_spawner_enabled ? 1 : 0

  harbor_url            = "https://${local.harbor_hostname}"
  harbor_admin_password = var.harbor_admin_password
  project_name          = "agent-platform"
  robot_name            = "agent-platform-builder"

  depends_on = [module.harbor, module.platform_dns]
}

module "forgejo_mirror" {
  source = "../../modules/forgejo-mirror"
  count  = var.forgejo_enabled && (var.agent_spawner_source_repo != "" || var.agent_workspace_source_repo != "") ? 1 : 0

  public_forgejo_url     = "https://${local.forgejo_hostname}"
  forgejo_admin_username = var.forgejo_admin_username
  forgejo_admin_password = var.forgejo_admin_password

  repos = merge(
    var.agent_spawner_source_repo == "" ? {} : {
      "agent-spawner" = {
        clone_addr    = var.agent_spawner_source_repo
        auth_username = var.github_mirror_username
        auth_password = var.github_mirror_token
        description   = "Mirror of upstream agent-spawner — built by forgejo-runner, pushed to Harbor."
      }
    },
    var.agent_workspace_source_repo == "" ? {} : {
      "agent-workspace" = {
        clone_addr    = var.agent_workspace_source_repo
        auth_username = var.github_mirror_username
        auth_password = var.github_mirror_token
        description   = "Mirror of upstream agent-workspace."
      }
    },
  )

  depends_on = [module.forgejo, module.platform_dns]
}

module "forgejo_runner" {
  source = "../../modules/forgejo-runner"
  count  = var.forgejo_runner_enabled ? 1 : 0

  namespace = "platform-forgejo"
  replicas  = var.forgejo_runner_replicas

  # In-cluster Forgejo URL for polling, public for the token-fetch check.
  forgejo_url        = var.forgejo_enabled ? "http://${module.forgejo[0].service_dns_http}:3000" : ""
  public_forgejo_url = var.forgejo_enabled ? module.forgejo[0].url : ""

  forgejo_admin_user     = var.forgejo_admin_username
  forgejo_admin_password = var.forgejo_admin_password

  storage_class      = var.storage_class
  cache_storage_size = var.forgejo_runner_cache_size

  # Harbor robot-account credentials for `docker buildx push`. Sourced
  # from harbor-bootstrap so a fresh cluster doesn't need a manually-
  # created robot in tfvars.
  registry_host     = var.harbor_enabled ? local.harbor_hostname : ""
  registry_username = var.harbor_enabled && var.agent_spawner_enabled ? module.harbor_bootstrap[0].robot_name : ""
  registry_password = var.harbor_enabled && var.agent_spawner_enabled ? module.harbor_bootstrap[0].robot_secret : ""

  depends_on = [module.forgejo]
}

# OpenFGA — Zanzibar-style authorization engine for the per-project
# Hermes spawner. Reuses the shared platform-infra Postgres. Bootstraps
# a store + the project-authz model into Secret `openfga-bootstrap` in
# platform-openfga namespace.
# Keel — registry-polling Deployment auto-updater. Closes the
# Forgejo-Runner-builds → Harbor-pushes → spawner-rolls loop without an
# Argo CD Application restructure. Annotations on the spawner Deployment
# (set by the agent-spawner module) tell Keel which image to watch.
module "keel" {
  source = "../../modules/keel"
  count  = var.keel_enabled ? 1 : 0

  harbor_pull_secret_namespace = "platform-spawner"
  harbor_pull_secret_name      = "harbor-pull-secret"

  depends_on = [
    kubernetes_secret_v1.harbor_pull_secret,
  ]
}

module "openfga" {
  source = "../../modules/openfga"
  count  = var.openfga_enabled ? 1 : 0

  namespace    = "platform-openfga"
  release_name = "openfga"

  postgres_host               = module.postgres.host
  postgres_port               = module.postgres.port
  postgres_superuser_username = module.postgres.superuser_username
  postgres_superuser_password = var.platform_postgres_superuser_password

  openfga_db_name     = "openfga"
  openfga_db_username = "openfga"
  openfga_db_password = var.openfga_db_password

  store_name = "hermes-projects"

  depends_on = [module.postgres]
}

# Monitoring — kube-prometheus-stack (Prometheus, Alertmanager, Grafana,
# node-exporter, kube-state-metrics) + Loki + Alloy (pod-log collector).
# Grafana is fronted by Keycloak OIDC via the platform realm.
module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.monitoring_enabled ? 1 : 0

  namespace = "platform-monitoring"
  hostname  = local.grafana_hostname

  grafana_admin_password = var.grafana_admin_password

  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref

  # OIDC is on iff the realm has been seeded (the `grafana` client exists).
  oidc_enabled       = var.realm_enabled
  oidc_issuer_url    = local.keycloak_platform_issuer_url
  oidc_client_id     = "grafana"
  oidc_client_secret = var.grafana_oidc_client_secret
  oidc_admin_groups  = ["platform-admin"]
  oidc_editor_groups = ["developer"]
  oidc_auto_login    = false

  # Trust the self-signed CA so Grafana can validate Keycloak's TLS cert.
  ca_source_secret_name      = local.tls_is_selfsigned ? "platform-root-ca" : ""
  ca_source_secret_namespace = "cert-manager"

  storage_class             = var.storage_class
  prometheus_storage_size   = var.monitoring_prometheus_storage_size
  prometheus_retention      = var.monitoring_prometheus_retention
  alertmanager_storage_size = var.monitoring_alertmanager_storage_size
  grafana_storage_size      = var.monitoring_grafana_storage_size
  loki_storage_size         = var.monitoring_loki_storage_size
  loki_retention            = var.monitoring_loki_retention

  depends_on = [module.realm, module.platform_dns, module.cert_manager]
}

output "gateway_class" {
  value = module.traefik.gateway_class_name
}

output "gateway_parent_ref" {
  value = module.traefik.gateway_parent_ref
}

output "keycloak_url" {
  value = "https://${local.keycloak_hostname}"
}

output "keycloak_issuer_url" {
  value = module.keycloak.issuer_url
}

output "oauth2_proxy_url" {
  value = "https://${local.oauth2_proxy_hostname}"
}

output "argocd_url" {
  value = module.argocd.server_url
}

output "hermes_url" {
  description = "Public URL of the Hermes WebUI (routed through oauth2-proxy → Keycloak master realm)."
  value       = var.hermes_enabled ? "https://${local.hermes_hostname}" : ""
}

output "forgejo_url" {
  description = "Public URL of Forgejo."
  value       = var.forgejo_enabled ? module.forgejo[0].url : ""
}

output "harbor_url" {
  description = "Public URL of Harbor."
  value       = var.harbor_enabled ? module.harbor[0].url : ""
}

# --- OpenFGA outputs ---

output "openfga_url" {
  description = "Cluster-internal HTTP URL for the OpenFGA API."
  value       = var.openfga_enabled ? module.openfga[0].http_url : ""
}

output "openfga_service_dns" {
  description = "FQDN of the OpenFGA HTTP Service inside the cluster."
  value       = var.openfga_enabled ? module.openfga[0].service_dns : ""
}

output "openfga_namespace" {
  description = "Namespace OpenFGA runs in."
  value       = var.openfga_enabled ? module.openfga[0].namespace : ""
}

output "openfga_bootstrap_secret_name" {
  description = "Name of the Secret (in OpenFGA's namespace) that holds store_id + auth_model_id + api_url for downstream consumers."
  value       = var.openfga_enabled ? module.openfga[0].bootstrap_secret_name : ""
}

output "openfga_store_id_secret_name" {
  description = "Alias for openfga_bootstrap_secret_name — kept for clarity at the cluster level."
  value       = var.openfga_enabled ? module.openfga[0].bootstrap_secret_name : ""
}

output "openfga_store_id" {
  description = "ULID of the OpenFGA store bootstrapped by this cluster."
  value       = var.openfga_enabled ? module.openfga[0].store_id : ""
}

output "openfga_auth_model_id" {
  description = "ULID of the authz model written into the OpenFGA store."
  value       = var.openfga_enabled ? module.openfga[0].auth_model_id : ""
}

# --- Monitoring outputs ---

output "grafana_url" {
  description = "Public Grafana URL (dashboards + log/metrics explorer)."
  value       = var.monitoring_enabled ? module.monitoring[0].grafana_url : ""
}

output "monitoring_namespace" {
  description = "Namespace hosting Prometheus, Grafana, Loki, and Alloy."
  value       = var.monitoring_enabled ? module.monitoring[0].namespace : ""
}

output "prometheus_service_url" {
  description = "In-cluster Prometheus URL."
  value       = var.monitoring_enabled ? module.monitoring[0].prometheus_service_url : ""
}

output "loki_gateway_url" {
  description = "In-cluster Loki gateway URL (datasource + Alloy push target)."
  value       = var.monitoring_enabled ? module.monitoring[0].loki_gateway_url : ""
}
