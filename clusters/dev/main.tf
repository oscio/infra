#
# Dev cluster — Agent Platform
#
# Installs Traefik (Gateway API), Keycloak, oauth2-proxy, Forgejo,
# Harbor, Forgejo Runner, Keel, and the monitoring stack. Registry-
# driven rolling is handled by Keel; there is intentionally no GitOps
# controller (terraform apply is the source of truth in dev).
#
# Gateway API routing: Traefik creates a 'traefik' GatewayClass and a
# shared 'platform-gateway' Gateway. All downstream components create
# HTTPRoutes attached to that Gateway.
#

locals {
  keycloak_hostname     = "auth.${var.domain}"
  oauth2_proxy_hostname = "oauth.${var.domain}"
  forgejo_hostname      = "git.${var.domain}"
  harbor_hostname       = "cr.${var.domain}"
  grafana_hostname      = "grafana.${var.domain}"
  argocd_hostname       = "cd.${var.domain}"
  console_hostname      = "console.${var.domain}"

  # Where in-cluster components (kubelet for pulls, CI runner pods for
  # pushes) reach Harbor. Selfsigned dev → in-cluster NodePort Service
  # (anonymous pull, plain HTTP, no DNS hacks). Other modes assume real
  # DNS + valid certs, where the public hostname is fine for both
  # external and in-cluster traffic. Image refs are constructed from
  # this so all consumers stay in sync; tfvars no longer hard-codes
  # Harbor hostnames.
  harbor_image_prefix = var.harbor_enabled && local.tls_is_selfsigned ? (
    length(module.harbor) > 0 ? module.harbor[0].internal_image_prefix : ""
  ) : local.harbor_hostname
  local_bootstrap_port_suffix = var.local_gateway_port == 443 ? "" : ":${var.local_gateway_port}"

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
  # Let's Encrypt modes require: letsencrypt_email + dns_provider =
  # cloudflare + Cloudflare API token. Enforced by preconditions below.
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

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "platform-traefik"
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "traefik"
    }
  }
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
      condition     = !local.tls_is_letsencrypt || var.dns_provider == "cloudflare"
      error_message = "When tls_mode is a letsencrypt-* mode, dns_provider must be 'cloudflare' (DNS-01 is required for wildcard certificates)."
    }
    precondition {
      condition     = !local.tls_is_letsencrypt || var.cloudflare_api_token != ""
      error_message = "cloudflare_api_token is required when tls_mode is letsencrypt-*."
    }
  }
}

module "cert_manager" {
  source = "../../modules/cert-manager"
  count  = local.cert_manager_enabled ? 1 : 0

  letsencrypt_email    = var.letsencrypt_email
  dns_provider         = var.dns_provider
  cloudflare_api_token = var.cloudflare_api_token

  # Which issuer flavour to create is driven by tls_mode.
  selfsigned_enabled = local.cert_manager_selfsigned

  wildcard_certificate_enabled     = local.cert_manager_wildcard_cert
  wildcard_certificate_domain      = var.domain
  wildcard_certificate_namespace   = "platform-traefik"
  wildcard_certificate_secret_name = "wildcard-${replace(var.domain, ".", "-")}-tls"
  wildcard_certificate_issuer      = local.cert_manager_issuer

  depends_on = [kubernetes_namespace.traefik]
}

module "traefik" {
  source = "../../modules/traefik"

  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false

  gateway_api_enabled     = var.gateway_api_enabled
  gateway_hostnames       = local.gateway_hostnames
  gateway_tls_secret_name = local.effective_tls_secret_name
  service_type            = var.traefik_service_type
  tls_enabled             = local.tls_enabled

  # Deep-wildcard HTTPS listeners. Gateway API wildcards only match one DNS
  # label, so '*.dev.openschema.io' does NOT cover 'foo.vm.dev.openschema.io';
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

# Per-node /etc/hosts + /etc/containerd/certs.d entries so kubelet on each
# node can resolve cr.<domain> (no public DNS in dev) and trust the
# Traefik-served self-signed wildcard. CoreDNS handles the in-cluster
# (kaniko push) side; this DaemonSet handles the host-level (kubelet pull)
# side — without it, ImagePullBackOff with `lookup cr.<domain>: no such
# host`. Pointed at var.local_gateway_ip (Tailscale/LAN IP that maps to
# Traefik); falls back to skipping if not set.
module "containerd_registry_host" {
  source = "../../modules/containerd-registry-host"
  count  = local.tls_is_selfsigned && var.harbor_enabled && var.local_gateway_ip != "" ? 1 : 0

  # k3s ships its own containerd that reads from a non-standard certs.d
  # path. kubeadm/Docker Desktop use the upstream default. Switch via
  # var.containerd_certs_d_path in tfvars; empty = upstream default.
  host_certs_d_path = var.containerd_certs_d_path != "" ? var.containerd_certs_d_path : "/etc/containerd/certs.d"

  registries = {
    (local.harbor_hostname) = {
      skip_verify = true
      host_ip     = var.local_gateway_ip
    }
  }
}

# Propagate the self-signed CA bundle to every consumer namespace so OIDC
# clients (oauth2-proxy, argo-cd dex, forgejo, harbor) can validate
# the wildcard cert served by Traefik. Skipped when tls_mode is a public
# (letsencrypt-*) mode — those are trusted by the system roots anyway.
# Note: oauth2-proxy and forgejo modules mirror the CA into their own
# namespaces via their ca_source_secret_name input (so the CA ConfigMap
# is lifecycle-coupled to their Helm release). We still use this module
# for the namespaces that don't own their own copy (argo, harbor).
module "platform_ca" {
  source = "../../modules/platform-ca"
  count  = local.tls_is_selfsigned ? 1 : 0

  source_secret_name      = "platform-root-ca"
  source_secret_namespace = "cert-manager"

  target_namespaces = compact([
    var.harbor_enabled ? "platform-harbor" : "",
  ])

  depends_on = [
    module.cert_manager,
    module.harbor,
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
  admin_username      = var.keycloak_admin_username
  admin_password      = var.keycloak_admin_password
  replicas            = 1
  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref
  tls_enabled         = local.tls_enabled
  local_resolve_ip    = var.local_gateway_ip
  local_resolve_port  = var.local_gateway_port

  db = {
    host     = module.postgres.host
    port     = module.postgres.port
    database = "keycloak"
    username = "keycloak"
    password = var.keycloak_db_password
  }

  # Keycloak's post-deploy readiness probe curls the public hostname, which
  # only resolves after platform_dns + traefik are up — wire that as an
  # explicit dependency so the wait doesn't race against route reconciliation.
  depends_on = [module.postgres, module.platform_dns, module.cert_manager]
}

# oauth2-proxy protecting the platform workspace UIs. Uses Keycloak *platform* realm
# (same realm as Forgejo / Harbor / Grafana — consolidated). The
# oauth2-proxy client is seeded by the keycloak-realm module.
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
  # Per-VM hostnames live under *.vm.<domain>. Tell oauth2-proxy
  # to accept those as legitimate post-login `rd=` redirect targets.
  extra_whitelist_domains = ["*.vm.${var.domain}"]
  # Emit the Traefik ForwardAuth Middleware so VM HTTPRoutes can
  # gate traffic through this oauth2-proxy.
  forward_auth_enabled = true

  # Trust the internal CA so OIDC discovery against Keycloak works. When
  # tls_mode="selfsigned", the module mirrors cert-manager/platform-root-ca
  # into a ConfigMap in its own namespace and mounts it. letsencrypt-* modes
  # use publicly-trusted certs, so no mirror needed.
  ca_source_secret_name      = local.tls_is_selfsigned ? "platform-root-ca" : ""
  ca_source_secret_namespace = "cert-manager"

  depends_on = [module.realm, module.platform_dns, module.cert_manager]
}

# Read the self-signed CA so consumers (Keel, monitoring) can mount it
# for SSL_CERT_FILE-style trust of in-cluster HTTPS endpoints.
data "kubernetes_secret_v1" "platform_root_ca" {
  count = local.tls_is_selfsigned ? 1 : 0

  metadata {
    name      = "platform-root-ca"
    namespace = "cert-manager"
  }

  depends_on = [module.cert_manager]
}

# Seed the Keycloak realm, clients, and groups. Enable this AFTER Keycloak
# is running and reachable (two-phase apply).
module "realm" {
  source = "../../modules/keycloak-realm"
  count  = var.realm_enabled ? 1 : 0

  realm_name         = var.keycloak_realm_name
  realm_display_name = var.keycloak_realm_display_name

  oauth2_proxy_urls = compact([
    "https://${local.oauth2_proxy_hostname}",
  ])
  forgejo_url = var.forgejo_enabled ? "https://${local.forgejo_hostname}" : ""
  harbor_url  = var.harbor_enabled ? "https://${local.harbor_hostname}" : ""
  grafana_url = var.monitoring_enabled ? "https://${local.grafana_hostname}" : ""
  console_url = var.console_enabled ? "https://${local.console_hostname}" : ""
  argocd_url  = var.argocd_enabled ? "https://${local.argocd_hostname}" : ""

  oauth2_proxy_client_id     = var.oauth2_proxy_client_id
  oauth2_proxy_client_secret = var.oauth2_proxy_client_secret
  forgejo_client_id          = var.forgejo_client_id
  forgejo_client_secret      = var.forgejo_oidc_client_secret
  harbor_client_id           = var.harbor_client_id
  harbor_client_secret       = var.harbor_oidc_client_secret
  grafana_client_id          = var.grafana_client_id
  grafana_client_secret      = var.grafana_oidc_client_secret
  console_client_id          = var.console_client_id
  console_client_secret      = var.console_oidc_client_secret
  argocd_client_id           = var.argocd_client_id
  argocd_client_secret       = var.argocd_oidc_client_secret
  hermes_client_id           = var.hermes_client_id
  hermes_client_secret       = var.hermes_client_secret
  devpod_client_id           = var.devpod_client_id

  # Token exchange requires Keycloak's fine-grained admin-authz feature,
  # which is off by default. Leave disabled until we actually need it.
  token_exchange_enabled = false

  # Dev convenience: no password policy so we can seed "admin" as the
  # bootstrap user password. Set to a real policy for staging/prod.
  password_policy = var.keycloak_realm_password_policy

  groups = var.keycloak_realm_groups
  users  = var.keycloak_realm_users

  depends_on = [module.keycloak]
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
  oidc_client_id     = var.forgejo_client_id
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
  hostname_prefix = "cr"

  gateway_parent_ref = module.traefik.gateway_parent_ref

  storage_class         = var.storage_class
  registry_storage_size = var.harbor_registry_storage_size
  database_storage_size = var.harbor_database_storage_size

  admin_username = var.harbor_admin_username
  admin_password = var.harbor_admin_password
  admin_email    = var.harbor_admin_email

  # Disable Trivy on dev (memory-constrained). Re-enable on a bigger cluster.
  trivy_enabled = false

  oidc_enabled       = var.realm_enabled
  oidc_issuer_url    = module.keycloak.issuer_url
  oidc_client_id     = var.harbor_client_id
  oidc_client_secret = var.harbor_oidc_client_secret
  oidc_admin_group   = "platform-admin"
  oidc_verify_cert   = var.harbor_oidc_verify_cert

  # Local-exec curl runs from the Terraform host, which doesn't trust the
  # internal CA. Skip cert verification for that local->gateway hop.
  local_exec_insecure_tls = local.tls_is_selfsigned

  # Side-channel for in-cluster image pulls. With this + harbor_bootstrap
  # `project_public = true`, kubelet can pull anonymously over plain HTTP
  # without ImagePullSecrets, /etc/hosts hacks, or insecure-registry
  # config on every node. Pinned ClusterIP so workspace image refs stay
  # stable across helm upgrades. Selfsigned-TLS dev path only — prod
  # turns this off and relies on real DNS + valid certs.
  internal_service_enabled    = local.tls_is_selfsigned
  internal_service_cluster_ip = "10.43.250.250"

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

  operator_image       = var.devpod_operator_image != "" ? var.devpod_operator_image : "${local.harbor_image_prefix}/library/devpod-operator:latest"
  default_devpod_image = var.devpod_default_image != "" ? var.devpod_default_image : "${local.harbor_image_prefix}/library/devpod-base:latest"
}

# Forgejo Runner — executes Actions workflows.
# Runs BuildKit (rootless) as a sidecar for `docker buildx build --push`.
# Fetches its registration token from Forgejo via admin API at plan time.
# Forgejo pull-mirror bootstrap. On first apply, mirrors the listed
# upstream repos into Forgejo so the in-cluster runner can build them.
# Empty source URLs = skip (e.g. when services are already pushed
# directly to Forgejo and don't need an upstream mirror).

# Harbor bootstrap — creates the `agent-platform` project + a robot
# account with push+pull. Runs on every apply (idempotent: project
# create returns 409 on exists; robot secret rotates). Output flows
# into the forgejo-runner module + forgejo-fork org secrets.
module "harbor_bootstrap" {
  source = "../../modules/harbor-bootstrap"
  count  = var.harbor_enabled ? 1 : 0

  harbor_url            = "https://${local.harbor_hostname}${local.local_bootstrap_port_suffix}"
  resolve_ip            = var.local_gateway_ip
  harbor_admin_password = var.harbor_admin_password
  project_name          = "agent-platform"
  robot_name            = "agent-platform-builder"

  # Public in dev so kubelet can pull anonymously via the in-cluster
  # NodePort Service (no Bearer challenge → external URL detour). Prod
  # leaves this false and relies on real DNS + valid certs so the auth
  # flow works without per-node hacks.
  project_public = local.tls_is_selfsigned

  depends_on = [module.harbor, module.platform_dns]
}

module "forgejo_fork" {
  source = "../../modules/forgejo-fork"
  count  = var.forgejo_enabled && length(var.forgejo_fork_repos) > 0 ? 1 : 0

  namespace              = "platform-forgejo"
  forgejo_internal_url   = "http://${module.forgejo[0].service_dns_http}:3000"
  public_forgejo_url     = "https://${local.forgejo_hostname}"
  forgejo_admin_username = var.forgejo_admin_username
  forgejo_admin_password = var.forgejo_admin_password

  # Park forks under a Forgejo org so repo-level secrets (HARBOR_USER,
  # GITHUB_PAT) can be set once at org level instead of per-repo. The
  # bootstrap Job creates the org idempotently.
  target_owner = var.forgejo_fork_owner

  # Inject GitHub credentials into entries that don't supply their own
  # auth — the typical pattern for cloning private upstreams from a
  # single GitHub PAT. Per-entry overrides still win.
  #
  # `extra_files` overlays a known-good `.forgejo/workflows/build.yml`
  # on top of whatever upstream had (typically out-of-date references
  # to BUILDKIT_HOST etc.) so CI works on the very first push without
  # the operator hand-editing the fork.
  repos = {
    for name, spec in var.forgejo_fork_repos : name => {
      clone_addr    = spec.clone_addr
      description   = spec.description
      private       = spec.private
      auth_username = spec.auth_username != "" ? spec.auth_username : var.github_clone_username
      auth_password = spec.auth_password != "" ? spec.auth_password : var.github_clone_token
      extra_files = fileexists("${path.module}/../../../services/${name}/.forgejo/workflows/build.yml") ? {
        ".forgejo/workflows/build.yml" = base64encode(file("${path.module}/../../../services/${name}/.forgejo/workflows/build.yml"))
      } : {}
    }
  }

  # Org-level secrets so workflows can `${{ secrets.HARBOR_USER }}` etc.
  # Set on the `platform` org once, inherited by every repo under it.
  org_secrets = (var.harbor_enabled && var.forgejo_fork_owner != "") ? {
    HARBOR_USER  = module.harbor_bootstrap[0].robot_name
    HARBOR_TOKEN = module.harbor_bootstrap[0].robot_secret
  } : {}

  # Org-level variables (non-secret) so the build.yml stays portable —
  # different clusters set HARBOR to whatever URL their Harbor is
  # reachable at (in-cluster ClusterIP+NodePort in dev, public hostname
  # in prod) without forking the workflow file.
  org_variables = (var.harbor_enabled && var.forgejo_fork_owner != "") ? {
    HARBOR = local.harbor_image_prefix
  } : {}

  # Run dead last. Pushing a workflow file (which the operator does after
  # this Job completes) immediately triggers a Forgejo Actions build, so
  # the runner, Harbor + robot account, and Keel poller all need to be
  # fully up before the fork repos exist. Otherwise the first build hits
  # a dead-on-arrival pipeline (missing runner / no robot creds / Keel
  # not watching yet) and the operator has to re-trigger by hand.
  depends_on = [
    module.forgejo,
    module.forgejo_runner,
    module.harbor,
    module.harbor_bootstrap,
    module.argocd,
    module.keycloak,
    module.realm,
    module.traefik,
    module.platform_dns,
  ]
}

module "forgejo_runner" {
  source = "../../modules/forgejo-runner"
  count  = var.forgejo_runner_enabled ? 1 : 0

  namespace = "platform-forgejo"
  replicas  = var.forgejo_runner_replicas

  # In-cluster Forgejo URL for polling, public for the token-fetch check.
  forgejo_url        = var.forgejo_enabled ? "http://${module.forgejo[0].service_dns_http}:3000" : ""
  public_forgejo_url = var.forgejo_enabled ? "https://${local.forgejo_hostname}${local.local_bootstrap_port_suffix}" : ""
  public_resolve_ip  = var.local_gateway_ip

  forgejo_admin_username = var.forgejo_admin_username
  forgejo_admin_password = var.forgejo_admin_password

  storage_class      = var.storage_class
  cache_storage_size = var.forgejo_runner_cache_size

  # Harbor robot-account credentials for `docker buildx push`. Sourced
  # from harbor-bootstrap so a fresh cluster doesn't need a manually-
  # created robot in tfvars.
  registry_host     = var.harbor_enabled ? local.harbor_hostname : ""
  registry_username = var.harbor_enabled ? module.harbor_bootstrap[0].robot_name : ""
  registry_password = var.harbor_enabled ? module.harbor_bootstrap[0].robot_secret : ""

  # Self-signed TLS modes don't ship a CA bundle the DinD daemon trusts,
  # so push/pull against Harbor fails with x509 unknown-authority. Skip
  # cert verification for the cluster's own registry in those modes.
  registry_insecure = local.tls_is_selfsigned || local.tls_is_off

  # Match docker0 to the pod-network MTU (k3s/Flannel vxlan: 1450).
  # Without this, base-image pulls inside DinD time out at the TLS
  # handshake when the cluster overlay MTU < 1500.
  dind_mtu = var.forgejo_runner_dind_mtu

  depends_on = [module.forgejo]
}

# OpenFGA — Zanzibar-style authorization engine for the platform.
# Reuses the shared platform-infra Postgres. Bootstraps a store + the
# project-authz model into Secret `openfga-bootstrap` in platform-openfga
# namespace.
# Argo CD — GitOps + Image Updater (replaces Keel).
# UI at cd.<domain>. Built-in `admin` stays as break-glass; Keycloak
# OIDC is wired alongside (members of `platform-admin` get Argo CD's
# admin role via the realm groups → role:admin RBAC mapping).
module "argocd" {
  source = "../../modules/argocd"
  count  = var.argocd_enabled && var.realm_enabled ? 1 : 0

  hostname           = local.argocd_hostname
  gateway_parent_ref = module.traefik.gateway_parent_ref
  tls_enabled        = local.tls_enabled

  admin_password = var.argocd_admin_password

  oidc_enabled       = true
  oidc_issuer_url    = local.keycloak_platform_issuer_url
  oidc_client_id     = var.argocd_client_id
  oidc_client_secret = var.argocd_oidc_client_secret
  oidc_admin_group   = "platform-admin"

  # Mount the platform CA so argocd-server's OIDC discovery and the
  # Image Updater's Harbor probes validate the selfsigned chain.
  ca_configmap_data = local.tls_is_selfsigned ? {
    "ca.crt" = try(
      lookup(data.kubernetes_secret_v1.platform_root_ca[0].data, "ca.crt", ""),
      base64decode(lookup(data.kubernetes_secret_v1.platform_root_ca[0].binary_data, "ca.crt", "")),
      "",
    )
  } : {}

  # Image Updater: registers Harbor as the platform's primary registry.
  # It can authenticate via the harbor-bootstrap robot (re-uses the
  # forgejo-runner pull secret) but anonymous pulls work for our public
  # `agent-platform` project, which is what the dev cluster runs on.
  image_updater_enabled = true
  image_updater_registries = var.harbor_enabled ? {
    harbor = {
      api_url = "https://${local.harbor_hostname}"
      prefix  = local.harbor_hostname
      default = true
      # Selfsigned dev: tell the updater the cert chain is "insecure"
      # to bypass strict verification at the registry-client layer
      # (the SSL_CERT_FILE mount handles HTTPS, but the registry
      # client uses its own dialer).
      insecure = local.tls_is_selfsigned
    }
  } : {}

  depends_on = [module.realm]
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

  store_name = "platform-projects"

  # Authorization model is owned by the console service (it defines the
  # types/relations the console-api Checks against). The bootstrap Job is
  # one-shot — see infra/modules/openfga/main.tf — so changes here only
  # apply on the FIRST `tf apply`. To re-seed on later edits, delete the
  # `openfga-bootstrap` Secret in platform-openfga and re-apply.
  authz_model_json = file("${path.module}/../../../services/console/openfga/model.json")
  authz_model_fga  = file("${path.module}/../../../services/console/openfga/model.fga")

  depends_on = [module.postgres]
}

# Console — in-cluster image build via kaniko, sourced from
# github.com/oscio/console (the canonical mirror of services/console).
# The build runs as Kubernetes Jobs so `tf apply` doesn't depend on the
# host docker daemon trusting the platform CA. Each Job:
#   1. initContainer `clone` — alpine/git clones github.com/oscio/console
#      into a shared emptyDir.
#   2. `build` container — gcr.io/kaniko-project/executor builds the
#      Dockerfile and pushes to harbor-internal (plain HTTP, ClusterIP)
#      using a mounted dockerconfig.json with harbor admin creds.
#
# Re-runs require taint/replace: kubernetes_job_v1 is idempotent in TF
# state. For ongoing iteration, push via the Forgejo workflow + Keel.
locals {
  # All in-cluster kaniko Jobs land here. Harbor admin Secret is also in
  # this namespace, kept close to the registry it talks to.
  image_build_namespace = "platform-harbor"

  # Use the public Harbor hostname for both kaniko push and kubelet pull.
  # Kaniko skips TLS via --skip-tls-verify(-pull); kubelet trusts
  # cr.<domain> via per-node containerd hosts.toml skip_verify in the
  # selfsigned dev mode. The in-cluster ClusterIP path (harbor-internal)
  # does NOT work on Docker Desktop because containerd routes pulls
  # through `registry-mirror:1273` which can't forward to a ClusterIP.
  image_registry = local.harbor_hostname

  console_repo_url      = "https://github.com/oscio/console.git"
  console_repo_ref      = "main"
  console_web_image_ref = "${local.image_registry}/agent-platform/console-web:latest"
  console_api_image_ref = "${local.image_registry}/agent-platform/console-api:latest"

  agent_sandbox_repo_url         = "https://github.com/oscio/agent-sandbox.git"
  agent_sandbox_repo_ref         = "main"
  agent_sandbox_image_ref        = "${local.image_registry}/agent-platform/agent-sandbox:latest"
  agent_sandbox_desktop_image_ref = "${local.image_registry}/agent-platform/agent-sandbox-desktop:latest"
  agents_image_ref               = "${local.image_registry}/agent-platform/agents:latest"
}

# Auth for kaniko push — harbor admin via dockerconfigjson keyed by the
# in-cluster registry URL (ClusterIP:port). Kaniko reads
# `/kaniko/.docker/config.json` automatically.
resource "kubernetes_secret_v1" "console_build_auth" {
  count = var.console_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "console-build-dockerconfig"
    namespace = local.image_build_namespace
  }

  type = "Opaque"
  data = {
    "config.json" = jsonencode({
      auths = {
        (local.image_registry) = {
          username = var.harbor_admin_username
          password = var.harbor_admin_password
          auth     = base64encode("${var.harbor_admin_username}:${var.harbor_admin_password}")
        }
      }
    })
  }

  depends_on = [module.harbor]
}

resource "kubernetes_job_v1" "console_build_web" {
  count = var.console_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "console-build-web"
    namespace = local.image_build_namespace
  }
  spec {
    backoff_limit = 2
    template {
      metadata { labels = { "agent-platform/component" = "console-build" } }
      spec {
        restart_policy = "Never"
        init_container {
          name    = "clone"
          image   = "alpine/git:latest"
          command = ["sh", "-c"]
          args    = ["git clone --depth=1 --branch=${local.console_repo_ref} ${local.console_repo_url} /workspace && ls /workspace"]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
        }
        container {
          name  = "build"
          image = "gcr.io/kaniko-project/executor:v1.23.2"
          args = [
            "--context=/workspace",
            "--dockerfile=Dockerfile.web",
            "--destination=${local.console_web_image_ref}",
            "--insecure",
            "--skip-tls-verify",
            "--single-snapshot",
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-config"
            mount_path = "/kaniko/.docker"
          }
        }
        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "docker-config"
          secret {
            secret_name = kubernetes_secret_v1.console_build_auth[0].metadata[0].name
            items {
              key  = "config.json"
              path = "config.json"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    module.harbor,
    kubernetes_secret_v1.console_build_auth,
  ]
}

# agent-sandbox — workspace-pod base images. `agent-sandbox` (basic) is
# code-server + hermes-agent + webui + ttyd; `agent-sandbox-desktop`
# layers XFCE + KasmVNC on top. The desktop variant `FROM`s the basic
# image, so the basic build must finish first (TF depends_on enforces).
# Source: github.com/oscio/agent-sandbox (mirror of services/agent-sandbox).
# Currently no in-cluster module consumes these — they're staged in
# Harbor for the (not-yet-enabled) devpod operator.
resource "kubernetes_secret_v1" "agent_sandbox_build_auth" {
  count = var.agent_sandbox_build_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "agent-sandbox-build-dockerconfig"
    namespace = local.image_build_namespace
  }

  type = "Opaque"
  data = {
    "config.json" = jsonencode({
      auths = {
        (local.image_registry) = {
          username = var.harbor_admin_username
          password = var.harbor_admin_password
          auth     = base64encode("${var.harbor_admin_username}:${var.harbor_admin_password}")
        }
      }
    })
  }

  depends_on = [module.harbor]
}

resource "kubernetes_job_v1" "agent_sandbox_build_basic" {
  count = var.agent_sandbox_build_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "agent-sandbox-build-basic"
    namespace = local.image_build_namespace
  }
  spec {
    backoff_limit = 2
    template {
      metadata { labels = { "agent-platform/component" = "agent-sandbox-build" } }
      spec {
        restart_policy = "Never"
        init_container {
          name    = "clone"
          image   = "alpine/git:latest"
          command = ["sh", "-c"]
          args    = ["git clone --depth=1 --branch=${local.agent_sandbox_repo_ref} ${local.agent_sandbox_repo_url} /workspace"]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
        }
        container {
          name  = "build"
          image = "gcr.io/kaniko-project/executor:v1.23.2"
          args = [
            "--context=/workspace",
            "--dockerfile=Dockerfile",
            "--destination=${local.agent_sandbox_image_ref}",
            "--skip-tls-verify",
            "--skip-tls-verify-pull",
            "--single-snapshot",
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-config"
            mount_path = "/kaniko/.docker"
          }
        }
        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "docker-config"
          secret {
            secret_name = kubernetes_secret_v1.agent_sandbox_build_auth[0].metadata[0].name
            items {
              key  = "config.json"
              path = "config.json"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    module.harbor,
    kubernetes_secret_v1.agent_sandbox_build_auth,
  ]
}

resource "kubernetes_job_v1" "agent_sandbox_build_desktop" {
  count = var.agent_sandbox_build_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "agent-sandbox-build-desktop"
    namespace = local.image_build_namespace
  }
  spec {
    backoff_limit = 2
    template {
      metadata { labels = { "agent-platform/component" = "agent-sandbox-build" } }
      spec {
        restart_policy = "Never"
        init_container {
          name    = "clone"
          image   = "alpine/git:latest"
          command = ["sh", "-c"]
          args    = ["git clone --depth=1 --branch=${local.agent_sandbox_repo_ref} ${local.agent_sandbox_repo_url} /workspace"]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
        }
        container {
          name  = "build"
          image = "gcr.io/kaniko-project/executor:v1.23.2"
          args = [
            "--context=/workspace",
            "--dockerfile=Dockerfile.desktop",
            "--destination=${local.agent_sandbox_desktop_image_ref}",
            "--build-arg=SANDBOX_BASE=${local.agent_sandbox_image_ref}",
            "--skip-tls-verify",
            "--skip-tls-verify-pull",
            "--single-snapshot",
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-config"
            mount_path = "/kaniko/.docker"
          }
        }
        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "docker-config"
          secret {
            secret_name = kubernetes_secret_v1.agent_sandbox_build_auth[0].metadata[0].name
            items {
              key  = "config.json"
              path = "config.json"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    kubernetes_job_v1.agent_sandbox_build_basic,
  ]
}

resource "kubernetes_job_v1" "console_build_api" {
  count = var.console_enabled && var.harbor_enabled ? 1 : 0

  metadata {
    name      = "console-build-api"
    namespace = local.image_build_namespace
  }
  spec {
    backoff_limit = 2
    template {
      metadata { labels = { "agent-platform/component" = "console-build" } }
      spec {
        restart_policy = "Never"
        init_container {
          name    = "clone"
          image   = "alpine/git:latest"
          command = ["sh", "-c"]
          args    = ["git clone --depth=1 --branch=${local.console_repo_ref} ${local.console_repo_url} /workspace"]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
        }
        container {
          name  = "build"
          image = "gcr.io/kaniko-project/executor:v1.23.2"
          args = [
            "--context=/workspace",
            "--dockerfile=Dockerfile.api",
            "--destination=${local.console_api_image_ref}",
            "--insecure",
            "--skip-tls-verify",
            "--single-snapshot",
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-config"
            mount_path = "/kaniko/.docker"
          }
        }
        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "docker-config"
          secret {
            secret_name = kubernetes_secret_v1.console_build_auth[0].metadata[0].name
            items {
              key  = "config.json"
              path = "config.json"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    module.harbor,
    kubernetes_secret_v1.console_build_auth,
  ]
}

# Console — Next.js + NestJS at console.<domain>. Reuses the platform
# Postgres (separate `console` DB) and consumes the openfga-bootstrap
# Secret from platform-openfga. Images are built+pushed by
# `terraform_data.console_image_build` above on initial apply; later
# updates flow through the Forgejo workflow at
# services/console/.forgejo/workflows/build.yml + Keel.
# Gated by `console_enabled` AND `realm_enabled` (the OIDC client and
# redirect URIs come from module.realm).
module "console" {
  source = "../../modules/console"
  count  = var.console_enabled && var.realm_enabled ? 1 : 0

  namespace    = "platform-console"
  release_name = "console"
  hostname     = local.console_hostname
  tls_enabled  = local.tls_enabled

  gateway_parent_ref = module.traefik.gateway_parent_ref

  # Pull from harbor-internal (ClusterIP:port, plain HTTP) — same ref the
  # kaniko build Jobs push to. Avoids host TLS trust complexity entirely:
  # kubelet talks to the in-cluster Service via kube-proxy, no DNS hacks
  # or selfsigned-CA propagation needed. Override `console_web_image`/
  # `console_api_image` in tfvars to use the public cr.<domain> URL when
  # images are pushed externally.
  web_image = var.console_web_image != "" ? var.console_web_image : local.console_web_image_ref
  api_image = var.console_api_image != "" ? var.console_api_image : local.console_api_image_ref

  # Harbor pull-secret is unused when pulling from harbor-internal (Harbor
  # serves anonymous pulls there). Pass admin creds anyway for parity with
  # the public URL fallback path.
  harbor_registry = local.image_registry
  harbor_username = var.harbor_admin_username
  harbor_password = var.harbor_admin_password

  postgres_host               = module.postgres.host
  postgres_port               = module.postgres.port
  postgres_superuser_username = module.postgres.superuser_username
  postgres_superuser_password = var.platform_postgres_superuser_password

  console_db_name     = "console"
  console_db_username = "console"
  console_db_password = var.console_db_password

  better_auth_secret = var.console_better_auth_secret

  keycloak_issuer_url    = local.keycloak_platform_issuer_url
  keycloak_client_id     = var.console_client_id
  keycloak_client_secret = var.console_oidc_client_secret

  openfga_namespace             = "platform-openfga"
  openfga_bootstrap_secret_name = "openfga-bootstrap"

  # Forgejo cascade for Phase-2 functions: console-api creates a
  # repo under <forgejo_function_org>/function-<slug> on every
  # function create, and deletes it on function delete. Per-user
  # auth is intentionally skipped — we use the platform admin
  # account for all repo operations.
  forgejo_internal_url      = var.forgejo_enabled ? "http://forgejo-http.platform-forgejo.svc.cluster.local:3000" : ""
  forgejo_public_url        = var.forgejo_enabled ? "https://${local.forgejo_hostname}" : ""
  forgejo_namespace         = "platform-forgejo"
  forgejo_admin_secret_name = var.forgejo_enabled ? "forgejo-admin" : ""
  forgejo_function_org      = "service"

  # In selfsigned mode, mirror the platform CA into the namespace and
  # mount it into web/api so Node.js (server-side fetch to Keycloak)
  # trusts the same root cert Traefik serves.
  ca_source_secret_name      = local.tls_is_selfsigned ? "platform-root-ca" : ""
  ca_source_secret_namespace = "cert-manager"

  # VM provisioning — share the agent-sandbox image refs that the
  # cluster's kaniko Jobs already build/push to Harbor.
  vm_image_base    = local.agent_sandbox_image_ref
  vm_image_desktop = local.agent_sandbox_desktop_image_ref
  # Agent runtime — same image for headless agent pods and VM
  # sidecars; entrypoint reads AGENT_TYPE at boot to dispatch.
  agent_image      = local.agents_image_ref
  vm_domain        = "vm.${var.domain}"

  # Gate per-VM URLs through oauth2-proxy ForwardAuth — anyone
  # opening vm-XXX-term.vm.<domain> needs a Keycloak session first.
  # The api clones a tiny Traefik Middleware into each VM namespace
  # pointing at this URL (Traefik resolves Middleware refs only
  # within the HTTPRoute's namespace, so cross-ns refs don't work).
  vm_auth_forward_url = try(
    "${module.oauth2_proxy[0].internal_service_url}/oauth2/auth",
    "",
  )
  # Public oauth2-proxy URL — api wraps VM launch links in
  # `<oauth>/oauth2/start?rd=<vm-url>` so the user gets silent SSO.
  oauth_proxy_url = try("https://${module.oauth2_proxy[0].hostname}", "")

  # Argo CD-managed Deployments. When the cluster has Argo CD
  # enabled, hand the api/web Deployments off to Argo CD so the
  # Image Updater (running in module.argocd) can patch them on
  # every Harbor push without TF tug-of-war. Manifest source =
  # services/console/k8s in the in-cluster Forgejo mirror.
  argocd_managed_deployments = var.argocd_enabled
  argocd_namespace           = "platform-argocd"
  argocd_repo_url            = "https://${local.forgejo_hostname}/${var.forgejo_fork_owner}/console.git"
  argocd_repo_path           = "k8s"
  argocd_repo_revision       = "main"
  argocd_repo_username       = var.forgejo_admin_username
  argocd_repo_password       = var.forgejo_admin_password
  argocd_repo_insecure       = local.tls_is_selfsigned
  harbor_registry_prefix     = local.harbor_hostname

  depends_on = [
    module.postgres,
    module.realm,
    module.openfga,
    module.platform_dns,
    module.cert_manager,
    kubernetes_job_v1.console_build_web,
    kubernetes_job_v1.console_build_api,
  ]
}

# Monitoring — kube-prometheus-stack (Prometheus, Alertmanager, Grafana,
# node-exporter, kube-state-metrics) + Loki + Alloy (pod-log collector).
# Grafana is fronted by Keycloak OIDC via the platform realm.
module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.monitoring_enabled ? 1 : 0

  namespace = "platform-monitoring"
  hostname  = local.grafana_hostname

  grafana_admin_username = var.grafana_admin_username
  grafana_admin_password = var.grafana_admin_password
  grafana_admin_email    = var.grafana_admin_email

  gateway_api_enabled = var.gateway_api_enabled
  gateway_parent_ref  = module.traefik.gateway_parent_ref

  # OIDC is on iff the realm has been seeded (the `grafana` client exists).
  oidc_enabled       = var.realm_enabled
  oidc_issuer_url    = local.keycloak_platform_issuer_url
  oidc_client_id     = var.grafana_client_id
  oidc_client_secret = var.grafana_oidc_client_secret
  oidc_admin_groups  = ["platform-admin"]
  oidc_editor_groups = []
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
