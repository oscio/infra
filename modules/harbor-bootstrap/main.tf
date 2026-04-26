terraform {
  required_providers {
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

# =====================================================================
# Harbor bootstrap
# =====================================================================
#
# `data "external"` runs at plan time and:
#   1. Creates the Harbor project (idempotent — 409/already-exists is OK)
#   2. Creates a project-scoped robot account with push+pull
#   3. Returns {name, secret} into terraform state for downstream consumers
#      (forgejo-runner's docker config + the dockerconfigjson Secret used
#      by workspace pods to pull from Harbor).
#
# Idempotency: the robot account creation returns the secret only once
# at create time. On re-runs, we PATCH /api/v2.0/robots/{id} with an
# empty body to regenerate the secret — meaning the secret rotates on
# every `terraform apply`. Acceptable for solo dev (terraform updates the
# downstream K8s Secret in the same apply) and avoids storing the secret
# in tfvars or out-of-band state.

data "external" "robot" {
  program = ["bash", "-c", <<-EOT
    set -eo pipefail
    INPUT=$(cat)
    HARBOR_URL=$(echo "$${INPUT}" | jq -r '.harbor_url')
    ADMIN_PW=$(echo  "$${INPUT}" | jq -r '.admin_password')
    PROJECT=$(echo   "$${INPUT}" | jq -r '.project')
    ROBOT_NAME=$(echo "$${INPUT}" | jq -r '.robot_name')

    AUTH=(-u "admin:$${ADMIN_PW}" -ksS -H 'Content-Type: application/json')

    # Create project (idempotent — 409 = already exists, both fine).
    curl "$${AUTH[@]}" -X POST \
      "$${HARBOR_URL}/api/v2.0/projects" \
      -d "{\"project_name\":\"$${PROJECT}\",\"public\":false}" \
      -o /dev/null -w '' || true

    # Try to create the robot. Returns 201 + {name, secret} on success.
    BODY=$(jq -nc \
      --arg name "$${ROBOT_NAME}" \
      --arg project "$${PROJECT}" \
      '{name: $name, duration: -1,
        description: "forgejo-runner build/push (managed by terraform)",
        level: "project",
        permissions: [{
          kind: "project",
          namespace: $project,
          access: [
            {resource: "repository", action: "push"},
            {resource: "repository", action: "pull"}
          ]
        }]}')

    CREATE=$(curl "$${AUTH[@]}" -X POST \
      "$${HARBOR_URL}/api/v2.0/projects/$${PROJECT}/robots" \
      -d "$${BODY}")

    NAME=$(echo "$${CREATE}" | jq -r '.name // empty')
    SECRET=$(echo "$${CREATE}" | jq -r '.secret // empty')

    if [ -z "$${SECRET}" ]; then
      # Already exists — find the robot ID and rotate its secret. Harbor
      # prefixes project robots: `robot$<project>+<robot_name>`.
      FULL_NAME="robot$${PROJECT}+$${ROBOT_NAME}"
      ROBOT_ID=$(curl "$${AUTH[@]}" \
        "$${HARBOR_URL}/api/v2.0/projects/$${PROJECT}/robots" \
        | jq -r ".[] | select(.name == \"$${FULL_NAME}\") | .id" \
        | head -1)
      [ -n "$${ROBOT_ID}" ] || { echo "robot $${FULL_NAME} not found after create-failure" >&2; exit 1; }

      # PATCH with empty body regenerates the secret.
      ROTATE=$(curl "$${AUTH[@]}" -X PATCH \
        "$${HARBOR_URL}/api/v2.0/projects/$${PROJECT}/robots/$${ROBOT_ID}/sec" \
        -d '{}')
      SECRET=$(echo "$${ROTATE}" | jq -r '.secret // empty')
      NAME="$${FULL_NAME}"
    fi

    [ -n "$${SECRET}" ] || { echo "no secret returned" >&2; echo "$${CREATE}" >&2; exit 1; }

    jq -nc --arg name "$${NAME}" --arg secret "$${SECRET}" \
      '{name: $name, secret: $secret}'
  EOT
  ]

  query = {
    harbor_url     = var.harbor_url
    admin_password = var.harbor_admin_password
    project        = var.project_name
    robot_name     = var.robot_name
  }
}
