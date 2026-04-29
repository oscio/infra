terraform {
  required_providers {
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

# =====================================================================
# Forgejo bootstrap — mint a Forgejo admin PAT for downstream consumers
# =====================================================================
#
# `data "external"` runs on every plan/apply and:
#   1. Looks up an existing token with the configured name; deletes it
#      if found (Forgejo enforces unique token names per user, and the
#      sha1 secret can't be re-fetched after creation).
#   2. Creates a fresh token with the requested scopes.
#   3. Returns {token: <sha1>} into terraform state.
#
# Side-effect of this design: the admin token rotates on every apply.
# Acceptable for solo dev (terraform updates dependent Deployment envs
# in the same apply, so cached values aren't a concern). Production
# should use a longer-lived token stored in a real secret manager.
#
# Why HTTP basic auth (admin password) for the initial mint: Forgejo
# accepts it for `/api/v1/users/<self>/tokens`, which avoids the
# chicken-and-egg of needing a token to create a token.

data "external" "admin_token" {
  program = ["bash", "-c", <<-EOT
    set -eo pipefail
    INPUT=$(cat)
    URL=$(echo  "$${INPUT}" | jq -r '.forgejo_url')
    USER=$(echo "$${INPUT}" | jq -r '.admin_user')
    PASS=$(echo "$${INPUT}" | jq -r '.admin_password')
    NAME=$(echo "$${INPUT}" | jq -r '.token_name')
    SCOPES=$(echo "$${INPUT}" | jq -r '.token_scopes')

    AUTH=(-u "$${USER}:$${PASS}" -ksS -H 'Content-Type: application/json')

    # Wait for Forgejo to be reachable (fresh-cluster race). 3min budget.
    for _ in $(seq 60); do
      curl "$${AUTH[@]}" "$${URL}/api/v1/version" -o /dev/null -w '' && break
      sleep 3
    done

    # Delete any pre-existing token with this name (idempotent re-run).
    EXISTING=$(curl "$${AUTH[@]}" "$${URL}/api/v1/users/$${USER}/tokens" \
      | jq -r ".[] | select(.name == \"$${NAME}\") | .id" \
      | head -1)
    if [ -n "$${EXISTING}" ]; then
      curl "$${AUTH[@]}" -X DELETE \
        "$${URL}/api/v1/users/$${USER}/tokens/$${EXISTING}" -o /dev/null -w ''
    fi

    BODY=$(jq -nc --arg name "$${NAME}" --argjson scopes "$${SCOPES}" \
      '{name: $name, scopes: $scopes}')

    RESP=$(curl "$${AUTH[@]}" -X POST \
      "$${URL}/api/v1/users/$${USER}/tokens" -d "$${BODY}")

    SHA1=$(echo "$${RESP}" | jq -r '.sha1 // empty')
    if [ -z "$${SHA1}" ]; then
      echo "Forgejo token mint failed:" >&2
      echo "$${RESP}" >&2
      exit 1
    fi

    jq -nc --arg t "$${SHA1}" '{token: $t}'
  EOT
  ]

  query = {
    forgejo_url    = var.forgejo_url
    admin_user     = var.admin_user
    admin_password = var.admin_password
    token_name     = var.token_name
    token_scopes   = jsonencode(var.token_scopes)
  }
}
