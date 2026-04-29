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
    PROJECT_PUBLIC=$(echo "$${INPUT}" | jq -r '.project_public // "false"')
    ROBOT_NAME=$(echo "$${INPUT}" | jq -r '.robot_name')
    RESOLVE_IP=$(echo "$${INPUT}" | jq -r '.resolve_ip // empty')
    HARBOR_HOST=$(echo "$${HARBOR_URL}" | sed -E 's#^https?://([^/:]+).*#\1#')
    HARBOR_PORT=$(echo "$${HARBOR_URL}" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')
    HARBOR_PORT="$${HARBOR_PORT:-443}"

    AUTH=(-u "admin:$${ADMIN_PW}" -ksS --connect-timeout 3 --max-time 20 -H 'Content-Type: application/json')
    if [ -n "$${RESOLVE_IP}" ]; then
      AUTH+=(--resolve "$${HARBOR_HOST}:$${HARBOR_PORT}:$${RESOLVE_IP}")
    fi

    # Create project (idempotent — 409 = already exists, both fine).
    # On 409 the existing project's metadata.public stays whatever it was,
    # so we explicitly PUT it afterwards to keep state in sync with the
    # `project_public` variable (Harbor stores it as a string under
    # metadata.public, "true"|"false").
    curl "$${AUTH[@]}" -X POST \
      "$${HARBOR_URL}/api/v2.0/projects" \
      -d "{\"project_name\":\"$${PROJECT}\",\"public\":$${PROJECT_PUBLIC}}" \
      -o /dev/null -w '' || true

    curl "$${AUTH[@]}" -X PUT \
      "$${HARBOR_URL}/api/v2.0/projects/$${PROJECT}" \
      -d "{\"metadata\":{\"public\":\"$${PROJECT_PUBLIC}\"}}" \
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

    # Harbor 2.x consolidated robot CRUD under /api/v2.0/robots regardless
    # of scope (level + permissions[].namespace carry the project info).
    # The legacy /api/v2.0/projects/<p>/robots path returns 404 on current
    # builds.
    CREATE=$(curl "$${AUTH[@]}" -X POST \
      "$${HARBOR_URL}/api/v2.0/robots" \
      -d "$${BODY}")

    NAME=$(echo "$${CREATE}" | jq -r 'if type == "object" then (.name // empty) else empty end')
    SECRET=$(echo "$${CREATE}" | jq -r 'if type == "object" then (.secret // empty) else empty end')

    if [ -z "$${SECRET}" ]; then
      # Already exists — find the robot ID and rotate its secret. Harbor
      # prefixes project robots: `robot$<project>+<robot_name>`.
      #
      # Listing project-scoped robots requires the project's numeric ID
      # in the q= filter (Harbor 2.14 rejects Level=project alone with
      # "must with project ID when to query project robots").
      # printf to keep the literal `$` in the robot name (Harbor lists
      # project robots as `robot$<project>+<name>`). A double-quoted
      # bash assignment would expand $PROJECT and drop the `$` separator.
      FULL_NAME=$(printf 'robot$%s+%s' "$${PROJECT}" "$${ROBOT_NAME}")
      PROJECT_ID=$(curl "$${AUTH[@]}" \
        "$${HARBOR_URL}/api/v2.0/projects?name=$${PROJECT}" \
        | jq -r 'if type == "array" then (.[0].project_id // empty) else empty end')
      [ -n "$${PROJECT_ID}" ] || { echo "project $${PROJECT} not found" >&2; exit 1; }

      ROBOT_ID=$(curl "$${AUTH[@]}" \
        "$${HARBOR_URL}/api/v2.0/robots?q=ProjectID=$${PROJECT_ID},Level=project&page_size=100" \
        | jq -r "if type == \"array\" then (.[] | select(.name == \"$${FULL_NAME}\") | .id) else empty end" \
        | head -1)
      [ -n "$${ROBOT_ID}" ] || { echo "robot $${FULL_NAME} not found after create-failure" >&2; echo "create-response: $${CREATE}" >&2; exit 1; }

      # Harbor 2.14: PATCH /robots/{id} with {secret: ""} regenerates and
      # returns {secret: "<new>"}. The legacy /sec sub-path is gone.
      ROTATE=$(curl "$${AUTH[@]}" -X PATCH \
        "$${HARBOR_URL}/api/v2.0/robots/$${ROBOT_ID}" \
        -d '{"secret":""}')
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
    project_public = tostring(var.project_public)
    robot_name     = var.robot_name
    resolve_ip     = var.resolve_ip
  }
}
