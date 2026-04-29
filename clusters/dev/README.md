# clusters/dev

Single-cluster Terraform deploy of the agent platform.
Targets Docker Desktop / kind / k3s / kubeadm / EKS — only the K8s
context + storage class change between targets.

## Quick start

```sh
# 1. Copy the example tfvars and edit
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Two-phase first apply (Keycloak realm seed depends on Keycloak
#    being up first):
#
#    Phase 1 — bring up Keycloak with realm_enabled = false (the example
#    tfvars defaults to this).
terraform init
terraform apply

#    Phase 2 — flip realm_enabled = true and apply again.
sed -i '' 's/^realm_enabled = false/realm_enabled = true/' terraform.tfvars
terraform apply
```

## What you must edit in `terraform.tfvars`

Section 1 — required:

- `domain` — every hostname (`auth.<domain>`, `cr.<domain>`, etc.) is
  derived from this. For local dev with no DNS, `127.0.0.1.nip.io`
  works. Add `traefik_extra_listener_hostnames` to match (replace the
  literal `dev.example.com` with your domain).
- All admin passwords + OIDC client secrets in Section 1. The example
  has `CHANGE-ME` placeholders; pick anything that meets Harbor's
  password policy (≥8 chars, upper + lower + digit).
- `keycloak_realm_users` — your primary SSO identity (and any
  additional users) in the platform realm. Members of `platform-admin`
  auto-promote to admin in Forgejo/Harbor/Grafana. Username
  intentionally NOT `admin` (Forgejo reserves that name and Harbor
  has its own internal `admin` user).

Section 2 — TLS:

- `tls_mode = "selfsigned"` for dev (browsers will warn once until
  the platform CA is trusted).
- `tls_mode = "letsencrypt-prod"` for real domains, plus the
  letsencrypt + DNS-01 fields.

## What gets deployed

- **Keycloak** at `auth.<domain>` — OIDC IdP for everything below.
- **Forgejo** at `git.<domain>` — in-cluster git, fronted by Keycloak
  OIDC. Forks listed in `forgejo_fork_repos` are cloned from upstream
  (e.g. GitHub) on first apply.
- **Harbor** at `cr.<domain>` — container registry. In `selfsigned`
  mode, also exposed via a pinned-IP NodePort Service so kubelet can
  pull anonymously (project = public) without the auth-challenge →
  external-DNS round trip.
- **Forgejo Runner** — DinD-backed Actions runner. Picks up workflow
  files in the forked repos and pushes to Harbor.
- **Keel** at `cd.<domain>` — registry-driven Deployment auto-rolling.
- **Grafana / Prometheus / Loki** at `grafana.<domain>` — metrics +
  logs.

The next module to land here is the **console** at `console.<domain>` —
an aws-console-style UI that orchestrates VMs (a.k.a. agent-sandbox
pods, with code-server + hermes-agent + webui) at `vm.<domain>`.

## Admin URLs (after both phases apply)

| URL | Login |
|-----|-------|
| `https://auth.<domain>` | `keycloak_admin_username` / `keycloak_admin_password` (master realm), or any `keycloak_realm_users` entry (platform realm) |
| `https://git.<domain>` | OIDC → Keycloak (use bootstrap admin) |
| `https://cr.<domain>` | "LOGIN VIA OIDC PROVIDER" or `admin` / `harbor_admin_password` for break-glass |
| `https://cd.<domain>` | `keel_admin_username` / `keel_admin_password` (basic auth) |
| `https://grafana.<domain>` | OIDC → Keycloak |

## Granting admin to other users

Members of the Keycloak group `platform-admin` are auto-promoted to
admin on every login (Forgejo, Harbor, Grafana). Add users to the
group via the Keycloak admin UI:

`Realms → platform → Groups → platform-admin → Members`.

## Common gotchas

- **`auth.dev.openschema.io: 404 Not Found`** during phase 2 →
  Keycloak isn't up yet. The keycloak module now blocks until the public
  URL responds 200 (`null_resource.wait_public`); if it still fails, your
  Terraform host can't reach the gateway — check `/etc/hosts` /
  `local_gateway_ip` or set `wait_for_public_url = false` on the module
  and fall back to the two-phase apply.
- **Workspace pod ImagePullBackOff** on `selfsigned` mode → check
  that `harbor_enabled = true`; the Harbor internal Service only
  exists when Harbor is on.
- **`Provider produced inconsistent final plan`** during apply → a
  cosmetic kubernetes-provider quirk; just re-run `terraform apply`.
