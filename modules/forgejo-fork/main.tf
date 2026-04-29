terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# =====================================================================
# Forgejo fork (one-time clone) bootstrap (in-cluster Job)
# =====================================================================
#
# Calls Forgejo's `POST /api/v1/repos/migrate` with `mirror: false` for
# each entry in `var.repos`. Result: independent, writable repos in
# Forgejo — unlike a pull-mirror they don't auto-sync from upstream and
# can be edited in-cluster (push, PR, workflow tweaks).
#
# Use case: iterate on Forgejo Actions workflows in-cluster without
# round-tripping through GitHub. To re-sync from upstream later, the
# operator deletes the repo and re-runs the bootstrap (or imports
# specific changes manually).
#
# Runs as a K8s Job inside `var.namespace`, hitting the in-cluster
# ClusterIP at `var.forgejo_internal_url` — sidesteps the self-signed-
# cert / public-DNS hassle of running curl from the terraform host.
#
# Idempotent: 409 (already exists) is swallowed.
#
# Job/ConfigMap/Secret names embed a sha1 of the inputs, so terraform
# replaces them (and re-runs the migration) whenever repos / creds /
# target URL change. Unchanged inputs → no-op apply.

locals {
  owner = var.target_owner != "" ? var.target_owner : var.forgejo_admin_username

  # `org_secrets` is included so a Harbor robot password rotation (the
  # harbor-bootstrap module rotates on every apply) bumps the hash → Job
  # replaces → org secrets in Forgejo refresh. Without this, the K8s
  # Secret object would update in place but the bootstrap Job wouldn't
  # rerun, leaving Forgejo's org secret stale and `docker push` failing
  # with 401 on the next workflow run.
  input_hash = substr(sha1(jsonencode({
    repos        = var.repos
    owner        = local.owner
    url          = var.forgejo_internal_url
    user         = var.forgejo_admin_username
    org_secrets  = var.org_secrets
    org_variables = var.org_variables
  })), 0, 8)

  job_name = "forgejo-fork-bootstrap-${local.input_hash}"

  labels = {
    "app.kubernetes.io/name"      = "forgejo-fork-bootstrap"
    "app.kubernetes.io/part-of"   = "platform-forgejo"
    "app.kubernetes.io/component" = "bootstrap"
  }

  repos_json = jsonencode([
    for name, spec in var.repos : {
      repo_name     = name
      repo_owner    = local.owner
      clone_addr    = spec.clone_addr
      private       = spec.private
      auth_username = spec.auth_username
      auth_password = spec.auth_password
      description   = spec.description
      extra_files   = spec.extra_files
    }
  ])

  org_secrets_json   = jsonencode(var.org_secrets)
  org_variables_json = jsonencode(var.org_variables)
}

resource "kubernetes_secret_v1" "fork" {
  metadata {
    name      = local.job_name
    namespace = var.namespace
    labels    = local.labels
  }

  type = "Opaque"
  data = {
    "ADMIN_USER"         = var.forgejo_admin_username
    "ADMIN_PASS"         = var.forgejo_admin_password
    "repos.json"         = local.repos_json
    "org_secrets.json"   = local.org_secrets_json
    "org_variables.json" = local.org_variables_json
  }
}

resource "kubernetes_config_map_v1" "fork" {
  metadata {
    name      = local.job_name
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "migrate.sh" = <<-SH
      #!/bin/sh
      set -eu

      URL="${var.forgejo_internal_url}"
      REPOS=/secret/repos.json

      echo "[forgejo-fork] target=$URL"

      for i in $(seq 1 60); do
        if curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" "$URL/api/v1/version" >/dev/null 2>&1; then
          echo "[forgejo-fork] forgejo reachable."
          break
        fi
        echo "  ...($i/60) not ready"
        sleep 3
      done

      # If target_owner is an org distinct from the admin user, create it
      # (idempotent — 409 if it already exists). Lets repo-bootstrap below
      # land at <forgejo>/<org>/<repo> instead of under the admin user.
      OWNER="${local.owner}"
      if [ "$OWNER" != "$ADMIN_USER" ]; then
        status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
          -u "$ADMIN_USER:$ADMIN_PASS" \
          -X POST \
          -H 'Content-Type: application/json' \
          "$URL/api/v1/orgs" \
          -d "$(jq -nc --arg n "$OWNER" '{username:$n, visibility:"private"}')")
        case "$status" in
          200|201) echo "[forgejo-fork] org created: $OWNER" ;;
          422)
            # Forgejo returns 422 with "already exists" — same idea as 409.
            if grep -q "already taken\|already exists" /tmp/out 2>/dev/null; then
              echo "[forgejo-fork] org exists, skipped: $OWNER"
            else
              echo "[forgejo-fork] FAILED creating org $OWNER: HTTP $status" >&2
              cat /tmp/out >&2; echo >&2
              exit 1
            fi
            ;;
          *)
            echo "[forgejo-fork] FAILED creating org $OWNER: HTTP $status" >&2
            cat /tmp/out >&2; echo >&2
            exit 1
            ;;
        esac
      fi

      ENABLE_ACTIONS="${var.enable_actions}"

      # ----------------------------------------------------------------
      # Pass 1: migrate repos + enable actions. No content pushes yet —
      # those happen in pass 3 after org-level secrets/vars are in place,
      # so the push-triggered workflow runs see the *current* secret
      # values (harbor-bootstrap rotates the robot password on every
      # apply, and stale secrets cause `docker push: unauthorized`).
      # ----------------------------------------------------------------
      count=$(jq 'length' "$REPOS")
      i=0
      while [ "$i" -lt "$count" ]; do
        body=$(jq -c ".[$i] | {clone_addr, mirror: false, repo_name, repo_owner, private, description, auth_username, auth_password}" "$REPOS")
        name=$(jq -r ".[$i].repo_name" "$REPOS")
        repo_owner=$(jq -r ".[$i].repo_owner" "$REPOS")

        status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
          -u "$ADMIN_USER:$ADMIN_PASS" \
          -X POST \
          -H 'Content-Type: application/json' \
          "$URL/api/v1/repos/migrate" \
          -d "$body")

        case "$status" in
          200|201) echo "[forgejo-fork] created: $name" ;;
          409)     echo "[forgejo-fork] exists, skipped: $name" ;;
          *)
            echo "[forgejo-fork] FAILED $name: HTTP $status" >&2
            cat /tmp/out >&2; echo >&2
            exit 1
            ;;
        esac

        # Enable Forgejo Actions before any pushes happen anywhere.
        # Forgejo only fires push-event workflow runs when has_actions
        # is true at push time — enabling actions later would leave the
        # build.yml push landing silently.
        if [ "$ENABLE_ACTIONS" = "true" ]; then
          status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
            -u "$ADMIN_USER:$ADMIN_PASS" \
            -X PATCH \
            -H 'Content-Type: application/json' \
            "$URL/api/v1/repos/$repo_owner/$name" \
            -d '{"has_actions":true}')
          case "$status" in
            200) echo "[forgejo-fork] actions enabled: $name" ;;
            *)
              echo "[forgejo-fork] FAILED enable-actions $name: HTTP $status" >&2
              cat /tmp/out >&2; echo >&2
              exit 1
              ;;
          esac
        fi

        i=$((i + 1))
      done

      # ----------------------------------------------------------------
      # Pass 2: org-level Actions secrets + variables.
      # PUT is idempotent — 201 on create, 204 on update. Variables
      # split create (POST) and update (PUT), so try POST then fall
      # back to PUT on 409.
      # ----------------------------------------------------------------
      ORG_SECRETS=/secret/org_secrets.json
      if [ "$OWNER" != "$ADMIN_USER" ] && [ -s "$ORG_SECRETS" ] && [ "$(jq 'length' "$ORG_SECRETS")" -gt 0 ]; then
        jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ORG_SECRETS" \
          | while IFS=$(printf '\t') read -r sname svalue; do
            body=$(jq -nc --arg d "$svalue" '{data: $d}')
            status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
              -u "$ADMIN_USER:$ADMIN_PASS" \
              -X PUT \
              -H 'Content-Type: application/json' \
              "$URL/api/v1/orgs/$OWNER/actions/secrets/$sname" \
              -d "$body")
            case "$status" in
              201|204) echo "[forgejo-fork] org secret set: $OWNER/$sname" ;;
              *)
                echo "[forgejo-fork] FAILED org secret $OWNER/$sname: HTTP $status" >&2
                cat /tmp/out >&2; echo >&2
                exit 1
                ;;
            esac
          done
      fi

      ORG_VARIABLES=/secret/org_variables.json
      if [ "$OWNER" != "$ADMIN_USER" ] && [ -s "$ORG_VARIABLES" ] && [ "$(jq 'length' "$ORG_VARIABLES")" -gt 0 ]; then
        jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ORG_VARIABLES" \
          | while IFS=$(printf '\t') read -r vname vvalue; do
            body=$(jq -nc --arg v "$vvalue" '{value: $v}')
            status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
              -u "$ADMIN_USER:$ADMIN_PASS" \
              -X POST \
              -H 'Content-Type: application/json' \
              "$URL/api/v1/orgs/$OWNER/actions/variables/$vname" \
              -d "$body")
            case "$status" in
              201|204) echo "[forgejo-fork] org variable set: $OWNER/$vname" ;;
              409)
                pstatus=$(curl -sS -o /tmp/out -w '%%{http_code}' \
                  -u "$ADMIN_USER:$ADMIN_PASS" \
                  -X PUT \
                  -H 'Content-Type: application/json' \
                  "$URL/api/v1/orgs/$OWNER/actions/variables/$vname" \
                  -d "$body")
                case "$pstatus" in
                  204) echo "[forgejo-fork] org variable updated: $OWNER/$vname" ;;
                  *)
                    echo "[forgejo-fork] FAILED org variable $OWNER/$vname update: HTTP $pstatus" >&2
                    cat /tmp/out >&2; echo >&2
                    exit 1
                    ;;
                esac
                ;;
              *)
                echo "[forgejo-fork] FAILED org variable $OWNER/$vname: HTTP $status" >&2
                cat /tmp/out >&2; echo >&2
                exit 1
                ;;
            esac
          done
      fi

      # ----------------------------------------------------------------
      # Pass 3: push extra_files. This is the step that triggers
      # workflow runs (push events to default branch), so it has to run
      # AFTER the org secrets are in place — otherwise the runs see
      # stale credentials and `docker push` fails with 401.
      # Each entry is already base64-encoded by terraform. POST creates;
      # 422 means file already exists, in which case GET-sha then PUT.
      # ----------------------------------------------------------------
      i=0
      while [ "$i" -lt "$count" ]; do
        name=$(jq -r ".[$i].repo_name" "$REPOS")
        repo_owner=$(jq -r ".[$i].repo_owner" "$REPOS")
        files_count=$(jq -r ".[$i].extra_files // {} | length" "$REPOS")
        if [ "$files_count" -gt 0 ]; then
          jq -r ".[$i].extra_files | to_entries[] | \"\(.key)\t\(.value)\"" "$REPOS" \
            | while IFS=$(printf '\t') read -r path content_b64; do
              body=$(jq -nc --arg msg "[forgejo-fork] bootstrap" --arg c "$content_b64" \
                '{message:$msg, content:$c}')
              status=$(curl -sS -o /tmp/out -w '%%{http_code}' \
                -u "$ADMIN_USER:$ADMIN_PASS" \
                -X POST \
                -H 'Content-Type: application/json' \
                "$URL/api/v1/repos/$repo_owner/$name/contents/$path" \
                -d "$body")
              case "$status" in
                201) echo "[forgejo-fork] wrote: $name:$path" ;;
                422)
                  sha=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASS" \
                    "$URL/api/v1/repos/$repo_owner/$name/contents/$path" \
                    | jq -r '.sha // empty')
                  if [ -z "$sha" ]; then
                    echo "[forgejo-fork] FAILED $name:$path: no sha to update" >&2
                    cat /tmp/out >&2; echo >&2
                    exit 1
                  fi
                  # Compare existing content to new content; skip the PUT
                  # entirely when they're identical so we don't churn an
                  # empty commit (which would still trigger a workflow run
                  # that just wastes CPU). Forgejo's contents API rejects
                  # PUTs with no diff anyway (422 "no change"), so this
                  # also avoids needing to special-case that response.
                  cur_b64=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASS" \
                    "$URL/api/v1/repos/$repo_owner/$name/contents/$path" \
                    | jq -r '.content // empty' | tr -d '\n ')
                  new_b64=$(echo "$content_b64" | tr -d '\n ')
                  if [ "$cur_b64" = "$new_b64" ]; then
                    echo "[forgejo-fork] unchanged: $name:$path"
                    continue
                  fi
                  body=$(jq -nc --arg msg "[forgejo-fork] bootstrap" --arg c "$content_b64" --arg s "$sha" \
                    '{message:$msg, content:$c, sha:$s}')
                  pstatus=$(curl -sS -o /tmp/out -w '%%{http_code}' \
                    -u "$ADMIN_USER:$ADMIN_PASS" \
                    -X PUT \
                    -H 'Content-Type: application/json' \
                    "$URL/api/v1/repos/$repo_owner/$name/contents/$path" \
                    -d "$body")
                  case "$pstatus" in
                    200) echo "[forgejo-fork] updated: $name:$path" ;;
                    *)
                      echo "[forgejo-fork] FAILED $name:$path: HTTP $pstatus" >&2
                      cat /tmp/out >&2; echo >&2
                      exit 1
                      ;;
                  esac
                  ;;
                *)
                  echo "[forgejo-fork] FAILED $name:$path: HTTP $status" >&2
                  cat /tmp/out >&2; echo >&2
                  exit 1
                  ;;
              esac
            done
        fi
        i=$((i + 1))
      done

      echo "[forgejo-fork] all $count repos processed."
    SH
  }
}

resource "kubernetes_job_v1" "fork" {
  metadata {
    name      = local.job_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    backoff_limit = 6
    # No ttl_seconds_after_finished: a TTL would auto-delete the completed
    # Job, so terraform would see drift on every plan and recreate. Letting
    # it linger keeps state in sync — the resource is replaced only when
    # inputs change (the sha1 in the name forces a new Job).

    template {
      metadata {
        labels = local.labels
      }
      spec {
        restart_policy = "OnFailure"

        container {
          name    = "migrate"
          image   = var.bootstrap_image
          command = ["/bin/sh", "/cfg/migrate.sh"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.fork.metadata[0].name
            }
          }

          volume_mount {
            name       = "cfg"
            mount_path = "/cfg"
          }
          volume_mount {
            name       = "secret"
            mount_path = "/secret"
            read_only  = true
          }
        }

        volume {
          name = "cfg"
          config_map {
            name         = kubernetes_config_map_v1.fork.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "secret"
          secret {
            secret_name = kubernetes_secret_v1.fork.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_secret_v1.fork,
    kubernetes_config_map_v1.fork,
  ]
}
