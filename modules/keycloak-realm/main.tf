terraform {
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.0"
    }
  }
}

# =====================================================================
# Realm
# =====================================================================

resource "keycloak_realm" "platform" {
  realm                    = var.realm_name
  display_name             = var.realm_display_name
  enabled                  = true
  registration_allowed     = false
  reset_password_allowed   = true
  remember_me              = true
  login_with_email_allowed = true

  # Short access-token lifetime; long-lived work uses refresh tokens.
  access_token_lifespan    = "15m"
  sso_session_idle_timeout = "8h"
  sso_session_max_lifespan = "24h"

  # Password policy is configurable. Default is strong; pass "" to disable
  # entirely (dev convenience — lets us create a user with password "admin").
  password_policy = var.password_policy

  internationalization {
    supported_locales = ["en"]
    default_locale    = "en"
  }
}

# =====================================================================
# Groups (map to app-specific roles via group claims)
# =====================================================================
# Data-driven: caller passes the full list via `var.groups`. Default
# is just `platform-admin` — the only group wired into Forgejo / Harbor /
# Grafana out of the box.

resource "keycloak_group" "this" {
  for_each = toset(var.groups)

  realm_id = keycloak_realm.platform.id
  name     = each.value
}

# =====================================================================
# Client scope: groups claim (shared across all clients)
# =====================================================================

resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.platform.id
  name                   = "groups"
  description            = "Adds the user's groups as a claim in the ID token."
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id            = keycloak_realm.platform.id
  client_scope_id     = keycloak_openid_client_scope.groups.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = false
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# =====================================================================
# Client: oauth2-proxy (front-door for any UI that delegates auth to it)
# =====================================================================

resource "keycloak_openid_client" "oauth2_proxy" {
  realm_id  = keycloak_realm.platform.id
  client_id = var.oauth2_proxy_client_id
  name      = "oauth2-proxy"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.oauth2_proxy_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  # First URL as display root/base; accept /oauth2/callback on every URL.
  root_url            = var.oauth2_proxy_urls[0]
  base_url            = var.oauth2_proxy_urls[0]
  valid_redirect_uris = [for url in var.oauth2_proxy_urls : "${url}/oauth2/callback"]
  web_origins         = var.oauth2_proxy_urls
}

resource "keycloak_openid_client_default_scopes" "oauth2_proxy" {
  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.oauth2_proxy.id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: forgejo (optional — only if forgejo_url is set)
# =====================================================================

resource "keycloak_openid_client" "forgejo" {
  count = var.forgejo_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = var.forgejo_client_id
  name      = "Forgejo"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.forgejo_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  root_url = var.forgejo_url
  base_url = var.forgejo_url
  valid_redirect_uris = [
    "${var.forgejo_url}/user/oauth2/${var.forgejo_oidc_provider_name}/callback",
  ]
  web_origins = [var.forgejo_url]
}

resource "keycloak_openid_client_default_scopes" "forgejo" {
  count = var.forgejo_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.forgejo[0].id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: harbor (optional — only if harbor_url is set)
# Harbor's OIDC callback path is /c/oidc/callback. Confidential client.
# =====================================================================

resource "keycloak_openid_client" "harbor" {
  count = var.harbor_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = var.harbor_client_id
  name      = "Harbor"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.harbor_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  root_url = var.harbor_url
  base_url = var.harbor_url
  valid_redirect_uris = [
    "${var.harbor_url}/c/oidc/callback",
  ]
  web_origins = [var.harbor_url]
}

resource "keycloak_openid_client_default_scopes" "harbor" {
  count = var.harbor_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.harbor[0].id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: grafana (optional — only if grafana_url is set)
# Grafana's OIDC callback path is /login/generic_oauth.
# =====================================================================

resource "keycloak_openid_client" "grafana" {
  count = var.grafana_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = var.grafana_client_id
  name      = "Grafana"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.grafana_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  root_url = var.grafana_url
  base_url = var.grafana_url
  valid_redirect_uris = [
    "${var.grafana_url}/login/generic_oauth",
  ]
  web_origins = [var.grafana_url]
}

resource "keycloak_openid_client_default_scopes" "grafana" {
  count = var.grafana_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.grafana[0].id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: argocd (optional — only if argocd_url is set)
# Argo CD's OIDC callback path is /auth/callback (and the CLI listens
# on http://localhost:8085/auth/callback for `argocd login --sso`).
# =====================================================================

resource "keycloak_openid_client" "argocd" {
  count = var.argocd_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = var.argocd_client_id
  name      = "Argo CD"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.argocd_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  root_url = var.argocd_url
  base_url = var.argocd_url
  valid_redirect_uris = [
    "${var.argocd_url}/auth/callback",
    "http://localhost:8085/auth/callback",
  ]
  web_origins = [var.argocd_url]
}

resource "keycloak_openid_client_default_scopes" "argocd" {
  count = var.argocd_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.argocd[0].id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: console (better-auth, optional — only if console_url is set)
# better-auth's genericOAuth plugin builds the redirect as
# <baseURL>/api/auth/oauth2/callback/<providerId>; our providerId is
# `keycloak`. The web app is served from console_url, so the URL below
# is what arrives at Keycloak as redirect_uri.
# =====================================================================

resource "keycloak_openid_client" "console" {
  count = var.console_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = var.console_client_id
  name      = "Console"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.console_client_secret

  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  root_url = var.console_url
  base_url = var.console_url
  valid_redirect_uris = [
    "${var.console_url}/api/auth/oauth2/callback/keycloak",
    # Local dev convenience — better-auth resolves callbacks against
    # BETTER_AUTH_URL, which on a developer machine is localhost:3000.
    "http://localhost:3000/api/auth/oauth2/callback/keycloak",
  ]
  web_origins = [var.console_url, "http://localhost:3000"]
}

resource "keycloak_openid_client_default_scopes" "console" {
  count = var.console_url == "" ? 0 : 1

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.console[0].id

  default_scopes = [
    "profile",
    "email",
    keycloak_openid_client_scope.groups.name,
  ]
}

# =====================================================================
# Client: hermes (service identity for the hermes-agent binary running
# inside each VM / agent-sandbox pod). Exchanges user tokens for
# devpod-worker tokens — linchpin of the on-behalf-of flow. UI auth
# (e.g. the upcoming console) goes through oauth2-proxy; the `hermes`
# client here is purely a service identity.
# =====================================================================

resource "keycloak_openid_client" "hermes" {
  realm_id  = keycloak_realm.platform.id
  client_id = var.hermes_client_id
  name      = "Hermes"
  enabled   = true

  access_type   = "CONFIDENTIAL"
  client_secret = var.hermes_client_secret

  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
}

# =====================================================================
# Client: devpod (confidential; target audience for tokens minted for
# ephemeral dev pods that hermes-agent dispatches). Replaces the previous
# speckit-worker naming — DevPod is a generic dev environment; speckit is
# one of many things that can run inside it.
# =====================================================================

resource "keycloak_openid_client" "devpod" {
  realm_id  = keycloak_realm.platform.id
  client_id = var.devpod_client_id
  name      = "DevPod"
  enabled   = true

  access_type = "CONFIDENTIAL"
  # Secret not used directly — clients auth via exchanged tokens.
  # Still required to exist for the audience mapping.
  client_secret = var.hermes_client_secret # reused — not sensitive in this direction

  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  # Token exchange permissions (granted below) make this client a valid audience.
}

# Token-exchange permission: makes devpod a valid exchange target.
# This resource enables Keycloak's fine-grained client permissions. Actual
# permission grants (which client may exchange for this one) are managed
# via keycloak_openid_client_scope_policy + token_exchange permission — for
# now we just flip the feature on; grant wiring is Phase 2.
resource "keycloak_openid_client_permissions" "devpod_permissions" {
  count = var.token_exchange_enabled ? 1 : 0

  realm_id  = keycloak_realm.platform.id
  client_id = keycloak_openid_client.devpod.id
}

# =====================================================================
# Realm users (data-driven)
# =====================================================================
# Caller passes the full set via `var.users`. Group memberships are
# resolved by name against `var.groups`.

resource "keycloak_user" "this" {
  # for_each can't take a sensitive value (passwords would leak into the
  # resource address). Username keys aren't secret; nonsensitive()
  # strips the sensitivity flag so they can be used as keys, while
  # password lookups inside the body keep their sensitivity.
  for_each = nonsensitive(var.users)

  realm_id       = keycloak_realm.platform.id
  username       = each.key
  enabled        = each.value.enabled
  email          = each.value.email
  email_verified = each.value.email_verified
  first_name     = each.value.first_name
  last_name      = each.value.last_name

  initial_password {
    value     = each.value.password
    temporary = each.value.password_temporary
  }
}

resource "keycloak_user_groups" "this" {
  for_each = nonsensitive({
    for username, spec in var.users : username => spec
    if length(spec.groups) > 0
  })

  realm_id = keycloak_realm.platform.id
  user_id  = keycloak_user.this[each.key].id

  # Resolve group names to IDs from the for_each set above. Names not
  # present in `var.groups` cause a clean apply-time error rather than
  # silently dropping the membership.
  group_ids = [for g in each.value.groups : keycloak_group.this[g].id]
}
