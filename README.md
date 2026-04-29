# infra/

Terraform code for the **Agent Platform** dev cluster — running Traefik
(Gateway API), Keycloak, cert-manager, Argo CD, oauth2-proxy, Forgejo,
Harbor, and a Forgejo Actions runner. The console.<domain> module
(VM / agent-sandbox orchestrator) is the next thing to land here.

See `../agent-platform/DESIGN.md` for the full architecture and
`../agent-platform/PHASE-A-VERIFICATION.md` for end-to-end testing.

> **Prod cluster is not implemented yet.** Focus is on getting the dev
> loop (git push → build → Harbor → Argo CD → deploy) working on Docker
> Desktop. Prod will come later by copying `clusters/dev/` and hardening
> (external Postgres, HA replicas, prod LE issuer, separate Argo CD
> source repos, etc.).

## Layout

```
infra/
├── README.md
├── versions.tf
├── .gitignore
├── modules/
│   ├── traefik/               # Traefik + GatewayClass + shared Gateway
│   ├── cert-manager/          # Let's Encrypt DNS-01 (Cloudflare/Route53)
│   ├── keycloak/              # codecentric/keycloakx (quay.io/keycloak/keycloak)
│   ├── keycloak-realm/        # platform realm + OIDC clients
│   ├── oauth2-proxy/          # OIDC proxy (front-door for platform UIs)
│   ├── argocd/                # Argo CD (GitOps)
│   ├── forgejo/               # Forgejo (self-hosted git)
│   ├── forgejo-runner/        # Forgejo Actions runner + BuildKit
│   ├── harbor/                # Harbor (container registry)
│   ├── monitoring/            # kube-prometheus-stack + Loki + Alloy (Grafana stack)
│   └── devpod-operator/       # DevPod CRD + operator
└── clusters/
    └── dev/                   # single-cluster setup (Docker Desktop)
```

## Routing: Gateway API

Traefik installs with the Gateway API provider enabled and creates a
`traefik` GatewayClass + shared `platform-gateway` Gateway (HTTP :80 +
HTTPS :443). Every component module attaches its own `HTTPRoute` to
that gateway via `parentRefs`.

Hostname convention (all under `<domain>`):

| Service      | Hostname            |
| ------------ | ------------------- |
| Keycloak     | `auth.<domain>`     |
| oauth2-proxy | `oauth.<domain>`    |
| Argo CD      | `cd.<domain>`       |
| Console      | `console.<domain>`  |
| VMs          | `vm.<domain>`       |
| Forgejo      | `git.<domain>`      |
| Harbor       | `registry.<domain>` |
| Grafana      | `grafana.<domain>`  |

## Identity

**One realm (`platform`) for everything**, seeded by `keycloak-realm`.
Clients: `oauth2-proxy`, `argocd`, `forgejo`, `harbor`, `hermes`,
`devpod`.

## Phased apply

Because Terraform's Keycloak provider needs Keycloak reachable at plan
time, bring-up is split into phases via `*_enabled` flags:

| Phase | Flag flip                        | What comes up                                   |
| ----- | -------------------------------- | ----------------------------------------------- |
| 1     | (defaults)                       | Traefik, cert-manager, Keycloak, Argo CD        |
| 2     | `realm_enabled = true`           | Platform realm + all OIDC clients               |
| 3     | `forgejo_enabled = true`         | Forgejo + OIDC                                  |
| 4     | `harbor_enabled = true`          | Harbor + OIDC (configured via API post-install) |
| 4.5   | (manual)                         | Create Harbor robot account for CI              |
| 5     | `forgejo_runner_enabled = true`  | Runner + BuildKit sidecar                       |
| 6     | `devpod_operator_enabled = true` | DevPod CRD (+ operator when image ready)        |
| 7     | `monitoring_enabled = true`      | Prometheus + Grafana + Loki + Alloy             |

See `agent-platform/PHASE-A-VERIFICATION.md` for step-by-step testing
after each phase.

## Usage

```bash
cd clusters/dev
cp terraform.tfvars.example terraform.tfvars
# edit: kube_context, domain, fill in CHANGE-ME secrets
terraform init
terraform apply
# then flip *_enabled flags and re-apply for each phase
```

## Assumptions

- Cluster **already exists**. This code configures workloads, not the
  cluster itself. Dev target: Docker Desktop Kubernetes.
- **Gateway API CRDs** installed (Traefik chart installs them via
  `install_gateway_api_crds = true` by default).
- DNS wildcard `*.<domain>` resolves to Traefik's Service (Docker
  Desktop: `127.0.0.1`).
- On Docker Desktop: `storage_class = "hostpath"`, at least 8GB RAM
  allocated.

## TLS

Three supported strategies, all togglable in tfvars:

1. **HTTP-only** — `cert_manager_enabled = false`, `gateway_tls_secret_name = ""`. Fastest bring-up.
2. **cert-manager wildcard** — `cert_manager_enabled = true`, `cert_manager_wildcard_cert = true`, pick DNS-01 provider (Cloudflare/Route53).
3. **Pre-provisioned Secret** — set `gateway_tls_secret_name` to an existing k8s Secret name.

## State

Local state by default (`terraform.tfstate` in `clusters/dev/`). For
real use, configure the S3/GCS backend stub in `backend.tf`.
