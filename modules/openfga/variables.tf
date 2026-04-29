variable "namespace" {
  description = "Namespace where OpenFGA runs."
  type        = string
  default     = "platform-openfga"
}

variable "release_name" {
  description = "Helm release / kubernetes resource name."
  type        = string
  default     = "openfga"
}

variable "chart_version" {
  description = "openfga/openfga Helm chart version."
  type        = string
  default     = "0.3.2"
}

variable "image_repository" {
  description = "OpenFGA container image repository."
  type        = string
  default     = "openfga/openfga"
}

variable "image_tag" {
  description = "OpenFGA image tag. Leave empty to use the chart default."
  type        = string
  default     = "v1.14.2"
}

variable "replicas" {
  description = "Number of OpenFGA replicas."
  type        = number
  default     = 1
}

variable "playground_enabled" {
  description = "Enable the OpenFGA Playground (useful in dev)."
  type        = bool
  default     = true
}

# --- Postgres backend ---
# OpenFGA stores tuples + models in Postgres. We reuse the shared
# platform-infra Postgres.
variable "postgres_host" {
  description = "Postgres hostname (e.g. postgres.platform-infra.svc.cluster.local)."
  type        = string
}

variable "postgres_port" {
  description = "Postgres TCP port."
  type        = number
  default     = 5432
}

variable "postgres_superuser_username" {
  description = "Postgres superuser username (used only by the db-create Job to CREATE DATABASE + CREATE ROLE)."
  type        = string
  default     = "postgres"
}

variable "postgres_superuser_password" {
  description = "Postgres superuser password (used only by the db-create Job)."
  type        = string
  sensitive   = true
}

variable "openfga_db_name" {
  description = "Postgres database name OpenFGA will use."
  type        = string
  default     = "openfga"
}

variable "openfga_db_username" {
  description = "Postgres role OpenFGA will authenticate as."
  type        = string
  default     = "openfga"
}

variable "openfga_db_password" {
  description = "Password for the OpenFGA Postgres role."
  type        = string
  sensitive   = true
}

# --- Bootstrap store / authz model ---
variable "store_name" {
  description = "OpenFGA store name to create on bootstrap."
  type        = string
  default     = "platform-projects"
}

variable "authz_model_fga" {
  description = <<-EOT
    Authorization model in FGA DSL (schema 1.1). Written into the store
    on first bootstrap. If you change this after initial apply, rerun the
    bootstrap Job manually (delete Job + Secret) — the module only writes
    the model when the bootstrap Secret is missing.

    The default is a generic placeholder (user + project only). Real
    deployments should override per-cluster — clusters/dev passes the
    console-owned model from services/console/openfga/model.fga.
  EOT
  type        = string
  default     = <<-FGA
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
  FGA
}

variable "authz_model_json" {
  description = <<-EOT
    Authorization model in OpenFGA JSON format (what the HTTP API expects).
    This is functionally equivalent to `authz_model_fga` — we ship both so
    that the bootstrap Job (which uses plain curl, not the fga CLI) can POST
    the model directly.

    Like `authz_model_fga`, the default is a generic placeholder. Override
    per-cluster — clusters/dev passes services/console/openfga/model.json.
  EOT
  type        = string
  default     = <<-JSON
    {
      "schema_version": "1.1",
      "type_definitions": [
        { "type": "user" },
        {
          "type": "project",
          "relations": {
            "owner":      { "this": {} },
            "editor":     { "union": { "child": [ { "this": {} }, { "computedUserset": { "relation": "owner" } } ] } },
            "viewer":     { "union": { "child": [ { "this": {} }, { "computedUserset": { "relation": "editor" } } ] } },
            "can_view":   { "computedUserset": { "relation": "viewer" } },
            "can_edit":   { "computedUserset": { "relation": "editor" } },
            "can_admin":  { "computedUserset": { "relation": "owner" } },
            "can_delete": { "computedUserset": { "relation": "owner" } }
          },
          "metadata": {
            "relations": {
              "owner":  { "directly_related_user_types": [ { "type": "user" } ] },
              "editor": { "directly_related_user_types": [ { "type": "user" } ] },
              "viewer": { "directly_related_user_types": [ { "type": "user" } ] }
            }
          }
        }
      ]
    }
  JSON
}

variable "bootstrap_image" {
  description = <<-EOT
    Container image used by the one-shot bootstrap Job that talks to the
    OpenFGA HTTP API and writes the result Secret. Needs ``sh``, ``curl``,
    and ``kubectl`` in one image. Default: alpine/k8s (non-Bitnami, bundles
    kubectl + curl + sh).
  EOT
  type        = string
  default     = "alpine/k8s:1.31.3"
}

# Kept for backwards-compat with the older bootstrap flow that shelled out
# to the `fga` CLI. The current flow hits the HTTP API directly with curl,
# so this variable is no longer referenced — left here only to avoid
# breaking any existing tfvars that set it.
variable "cli_image" {
  description = "Deprecated — no longer used."
  type        = string
  default     = "openfga/cli:latest"
}

variable "psql_image" {
  description = "postgres client image used by the db-create Job (for psql)."
  type        = string
  default     = "postgres:16-alpine"
}

variable "bootstrap_secret_name" {
  description = "Name of the Secret the bootstrap Job writes store_id + auth_model_id into."
  type        = string
  default     = "openfga-bootstrap"
}

variable "resources" {
  description = "Resource requests/limits for OpenFGA pods."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { cpu = "1000m", memory = "512Mi" }
  }
}
