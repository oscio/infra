terraform {
  required_providers {
    null = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

# =====================================================================
# Forgejo pull-mirror bootstrap
# =====================================================================
#
# Calls Forgejo's `POST /api/v1/repos/migrate` API for each entry in
# `var.repos`. With `mirror=true`, Forgejo:
#   - Clones from the upstream URL once now
#   - Schedules periodic syncs (default 8h)
#   - Disables push to the local copy (it's read-only, tracks upstream)
#
# Idempotent: re-runs return 409 from the API, which we swallow. Changes
# to clone_addr or repo_name trigger a re-create via the `triggers` map.
#
# Why local-exec (not a K8s Job): keeping the bootstrap on the terraform
# host means apply-time errors surface in `terraform apply` output instead
# of a separate `kubectl logs job/...` step, and the failure is fail-fast
# rather than retry-pinned-by-Job-backoff. The cost is needing the host
# to reach the public Forgejo URL — already required for cert-manager
# DNS-01, so no new constraint.

locals {
  owner = var.target_owner != "" ? var.target_owner : var.forgejo_admin_username
}

resource "null_resource" "mirror" {
  for_each = var.repos

  triggers = {
    clone_addr = each.value.clone_addr
    repo_name  = each.key
    owner      = local.owner
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eo", "pipefail", "-c"]
    environment = {
      ADMIN_USER = var.forgejo_admin_username
      ADMIN_PASS = var.forgejo_admin_password
    }
    command = <<-EOT
      BODY=$(jq -nc \
        --arg clone_addr "${each.value.clone_addr}" \
        --arg repo_name "${each.key}" \
        --arg repo_owner "${local.owner}" \
        --arg auth_user "${each.value.auth_username}" \
        --arg auth_pass "${each.value.auth_password}" \
        --arg description "${each.value.description}" \
        --argjson private ${each.value.private} \
        '{clone_addr: $clone_addr, mirror: true, repo_name: $repo_name,
          repo_owner: $repo_owner, private: $private,
          description: $description, auth_username: $auth_user,
          auth_password: $auth_pass}')

      # `-k` because dev clusters serve self-signed certs the terraform
      # host may not trust by default. Production should drop -k once a
      # proper CA chain is configured.
      STATUS=$(curl -ksS -o /tmp/forgejo-migrate.out -w '%%{http_code}' \
        -u "$ADMIN_USER:$ADMIN_PASS" \
        -X POST \
        -H 'Content-Type: application/json' \
        "${var.public_forgejo_url}/api/v1/repos/migrate" \
        -d "$BODY")

      case "$STATUS" in
        201|200) echo "[forgejo-mirror] created: ${each.key}" ;;
        409)     echo "[forgejo-mirror] exists, skipped: ${each.key}" ;;
        *)       echo "[forgejo-mirror] FAILED ${each.key}: HTTP $STATUS" >&2
                 cat /tmp/forgejo-migrate.out >&2; echo >&2
                 exit 1 ;;
      esac
    EOT
  }
}
