# console module (`infra/modules/console/`)

Deploys the platform console (Next.js + NestJS at `services/console`) onto
the cluster:

1. Namespace `platform-console`.
2. Harbor `dockerconfigjson` pull Secret.
3. **db-create** Job — idempotent `CREATE ROLE`/`CREATE DATABASE` on the
   shared platform Postgres for `console`.
4. **openfga-bootstrap mirror** — copies `module.openfga`'s Secret
   (`store_id`, `auth_model_id`, `api_url`) into `platform-console`. The
   openfga module deliberately leaves cross-namespace mounting to the
   consumer; this module is that consumer.
5. **auth-migrate** Job — runs `pnpm --filter @workspace/auth auth:migrate`
   against the `console` DB once before pods start. Idempotent.
6. **api Deployment + Service** (port `3001`, ClusterIP only).
7. **web Deployment + Service** (port `3000`, ClusterIP).
8. **Gateway API HTTPRoute** on `<hostname>` → web. The api isn't
   exposed publicly; the web pod proxies to it via cluster DNS.

## Image build

The images are built and pushed by the Forgejo Actions workflow in
`services/console/.forgejo/workflows/build.yml`:

- `cr.<domain>/agent-platform/console-web:<sha|latest>`
- `cr.<domain>/agent-platform/console-api:<sha|latest>`

Pin `var.web_image` / `var.api_image` to a commit SHA in production
(or to `:latest` + Keel-managed for ad-hoc redeploys).

## Browser flow

```
browser ─► console.<domain>            (HTTPRoute)
            └► console-web (Next.js)   (Deployment, :3000)
                  ├─ /api/auth/*        better-auth handlers
                  └─ RSC + server actions
                        └► http://console-api:3001       (cluster DNS)
                              ├─ /accounts/{me,/}
                              ├─ /role-bindings/...
                              └─ /healthz
```

Browser-side code never directly hits the api; `apps/web/lib/api.ts` is
called only from server components / server actions.

## OpenFGA wiring

The api boots, reads `OPENFGA_API_URL` / `OPENFGA_STORE_ID` /
`OPENFGA_AUTH_MODEL_ID` (sourced from the mirrored Secret), and uses
them via `apps/api/src/openfga/openfga.service.ts`. Platform-admin is
Keycloak-only (the `platform-admin` group claim); console-admin is the
single FGA-managed role (`platform#console_admin` tuple).

## Manual verification after first apply

```sh
kubectl get pods -n platform-console
kubectl -n platform-console logs deploy/console-api
kubectl -n platform-console logs deploy/console-web

# Force a fresh better-auth migration if you bumped the schema:
kubectl -n platform-console delete job console-auth-migrate
terraform apply

# Read back the openfga mirror to confirm bootstrap values landed:
kubectl -n platform-console get secret openfga-bootstrap -o json \
  | jq '.data | map_values(@base64d)'
```
