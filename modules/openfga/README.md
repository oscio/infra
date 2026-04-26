# OpenFGA module (`infra/modules/openfga/`)

Deploys OpenFGA on a Kubernetes cluster with a Postgres backend and
bootstraps:

1. A Postgres database (`openfga`) + role (`openfga`) in the shared
   platform-infra Postgres.
2. The OpenFGA server itself via the official `openfga/openfga` Helm
   chart. The chart runs `openfga migrate` as a post-install hook
   (`applyMigrations=true`).
3. A one-shot **bootstrap Job** that creates an OpenFGA **store** and
   writes the project-authz **authorization model** (FGA DSL). The Job
   captures the generated `store_id` + `auth_model_id` and writes them
   into a Kubernetes **Secret** that downstream services (the Hermes
   spawner) read at runtime.

## Bootstrap flow

```
┌─────────────────┐  1. CREATE ROLE + DATABASE    ┌──────────────────────┐
│  db-create Job  │ ─────────────────────────────►│  Shared Postgres     │
└─────────────────┘    (psql, idempotent)         │  platform-infra      │
        │                                         └──────────────────────┘
        ▼
┌─────────────────┐  2. openfga migrate (helm     ┌──────────────────────┐
│  helm_release   │     post-install hook Job)    │  OpenFGA pods        │
│  openfga        │ ─────────────────────────────►│  platform-openfga    │
└─────────────────┘     + waitForMigrations       └──────────────────────┘
        │
        ▼
┌─────────────────┐  3. fga store create --model  ┌──────────────────────┐
│  bootstrap Job  │ ─────────────────────────────►│  Secret              │
│ (openfga/cli)   │     write {store_id,          │  openfga-bootstrap   │
└─────────────────┘      auth_model_id, api_url}  │  (same namespace)    │
                                                  └──────────────────────┘
```

The bootstrap Job is **idempotent**: it short-circuits if the target
Secret already has a non-empty `store_id`. To force a re-bootstrap
(e.g. after editing `authz_model_fga`):

```sh
kubectl -n platform-openfga delete secret openfga-bootstrap
kubectl -n platform-openfga delete job openfga-bootstrap
terraform apply    # re-creates both
```

> Creating a *new* store wastes any existing tuples — but for model
> evolution you usually want `fga model write` against the existing
> store, not a brand-new store. The module bootstraps; runtime model
> updates are the spawner's (or a human's) responsibility.

## Outputs

| Output | Purpose |
|--------|---------|
| `namespace`              | Namespace OpenFGA runs in (default `platform-openfga`). |
| `service_name`           | `Service` name for the HTTP API. |
| `service_dns`            | FQDN of the HTTP Service — what the spawner connects to. |
| `http_url`               | Full `http://<svc>:8080` URL. |
| `grpc_service_dns`       | FQDN of the gRPC Service (`:8081`). |
| `bootstrap_secret_name`  | `openfga-bootstrap` by default. |
| `store_id`               | ULID of the bootstrapped store (from the Secret). |
| `auth_model_id`          | ULID of the bootstrapped authorization model. |

## Consuming the Secret

The Hermes spawner should mount / read the Secret directly rather than
relying on Terraform outputs at runtime:

```yaml
env:
  - name: OPENFGA_API_URL
    valueFrom: { secretKeyRef: { name: openfga-bootstrap, key: api_url } }
  - name: OPENFGA_STORE_ID
    valueFrom: { secretKeyRef: { name: openfga-bootstrap, key: store_id } }
  - name: OPENFGA_AUTH_MODEL_ID
    valueFrom: { secretKeyRef: { name: openfga-bootstrap, key: auth_model_id } }
```

(Cross-namespace mount requires mirroring the Secret — the spawner
module will do that.)

## Authorization model (default)

```fga
model
  schema 1.1

type user

type project
  relations
    define owner: [user]
    define editor: [user] or owner
    define viewer: [user] or editor
    define can_view: viewer
    define can_edit: editor
    define can_admin: owner
    define can_delete: owner
```

Override with `var.authz_model_fga` if needed.

## Manual verification

Once applied:

```sh
# 1. Pods up?
kubectl get pods -n platform-openfga

# 2. HTTP API reachable from inside the cluster?
kubectl -n platform-openfga run curl --rm -it --image=curlimages/curl:latest \
    --restart=Never -- curl -s http://openfga-http.platform-openfga.svc.cluster.local:8080/healthz

# 3. Store listed via the fga CLI, from inside a throwaway pod:
kubectl -n platform-openfga run fga --rm -it --image=openfga/cli:latest \
    --restart=Never -- \
    --api-url http://openfga-http.platform-openfga.svc.cluster.local:8080 store list

# 4. Read back the bootstrap Secret:
kubectl -n platform-openfga get secret openfga-bootstrap \
    -o jsonpath='{.data}' | base64-decode-or-jq ...
```

Or simply:

```sh
kubectl -n platform-openfga get secret openfga-bootstrap -o json \
  | jq '.data | map_values(@base64d)'
```

## End-to-end smoke test with `fga` CLI

Exec into the OpenFGA pod (which doesn't have fga itself — use a
throwaway `openfga/cli` pod instead):

```sh
STORE_ID=$(kubectl -n platform-openfga get secret openfga-bootstrap \
           -o jsonpath='{.data.store_id}' | base64 -d)
MODEL_ID=$(kubectl -n platform-openfga get secret openfga-bootstrap \
           -o jsonpath='{.data.auth_model_id}' | base64 -d)
API=http://openfga-http.platform-openfga.svc.cluster.local:8080

# Write a tuple: shane owns project:agentic-chatbot
kubectl -n platform-openfga run fga-smoke --rm -i --image=openfga/cli:latest \
    --restart=Never --command -- \
    fga --api-url "$API" --store-id "$STORE_ID" \
        tuple write user:shane owner project:agentic-chatbot

# Check: can shane view?
kubectl -n platform-openfga run fga-check --rm -i --image=openfga/cli:latest \
    --restart=Never --command -- \
    fga --api-url "$API" --store-id "$STORE_ID" \
        query check user:shane can_view project:agentic-chatbot
# expected: {"allowed": true, ...}
```

## Troubleshooting

### db-create Job fails with `role already exists`
Expected — the SQL uses `IF NOT EXISTS` checks, but if you changed
`openfga_db_password`, the `ALTER ROLE` branch will run. Rerun terraform.

### Helm migration Job stuck (`openfga-migrate-...`)
Check its logs:
```sh
kubectl -n platform-openfga logs job/openfga-migrate
```
Most commonly: DB DSN wrong, DB unreachable, or role can't
`CREATE SCHEMA`. The db-create Job grants `ALL PRIVILEGES ON DATABASE`
which covers this.

### Bootstrap Job fails with `connection refused`
The chart's `wait: true` + `waitForMigrations: true` usually guarantees
the pods are Ready before the bootstrap Job runs, but the Job also
polls `/healthz` for 2 minutes. If it times out, check:
```sh
kubectl -n platform-openfga get pods
kubectl -n platform-openfga logs deploy/openfga
```

### Re-run the bootstrap Job
```sh
kubectl -n platform-openfga delete job openfga-bootstrap
kubectl -n platform-openfga delete secret openfga-bootstrap   # if you want a new store
terraform apply
```

### Changing the authz model after initial bootstrap
The module *only* writes the model on first bootstrap. For subsequent
model changes, use `fga model write` against the existing store — this
preserves tuples:

```sh
kubectl -n platform-openfga run fga-edit --rm -i --image=openfga/cli:latest \
    --restart=Never --command -- \
    fga --api-url "$API" --store-id "$STORE_ID" \
        model write --file /path/to/updated-model.fga
```

Then update `var.authz_model_fga` in the module so future cluster
rebuilds reflect the new baseline.
