terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# =====================================================================
# containerd-registry-host — privileged DaemonSet that drops a
# `hosts.toml` under `/etc/containerd/certs.d/<host>/` on every K8s node.
# =====================================================================
#
# Use case: a cluster's containerd is configured to forward image pulls
# through a default mirror (Docker Desktop's `registry-mirror:1273`,
# kubeadm clusters with a registry-mirror plugin, etc.). When the
# cluster also hosts a self-signed registry that the mirror can't
# verify, every `kubectl rollout` against an image from that registry
# fails with `unexpected status from HEAD request to … 500 Internal
# Server Error`. Per-host `hosts.toml` files override the mirror for
# specific hostnames.
#
# Format reference: https://github.com/containerd/containerd/blob/main/docs/hosts.md
#
# The DaemonSet stays running (sleep infinity) so that node restarts
# get the file re-installed automatically. Containerd reads hosts.toml
# fresh on every pull request — no daemon restart needed.

locals {
  labels = {
    "app.kubernetes.io/name"    = var.release_name
    "app.kubernetes.io/part-of" = "agent-platform"
    "agent-platform/component"  = "containerd-registry-host"
  }

  # Render the script that writes one hosts.toml per registry. Each
  # entry becomes `mkdir + cat > hosts.toml` shell block. Heredoc end
  # marker uses TOML_<host>_END to stay unambiguous when multiple
  # registries are managed.
  # Each registry produces (a) a hosts.toml under containerd's certs.d
  # for TLS / mirror behavior, and optionally (b) an /etc/hosts entry
  # pinning the hostname to a routable IP. The /etc/hosts append is
  # idempotent — the marker `# managed-by:containerd-registry-host`
  # makes future runs detect and skip duplicate lines.
  write_script = join("\n", concat(
    [
      for host, spec in var.registries : <<-SH
        mkdir -p '${var.host_certs_d_path}/${host}'
        cat > '${var.host_certs_d_path}/${host}/hosts.toml' <<'TOML_${replace(host, ".", "_")}_END'
        server = "${spec.server != "" ? spec.server : "https://${host}"}"

        [host."${spec.server != "" ? spec.server : "https://${host}"}"]
          capabilities = ["pull", "resolve"]
        ${spec.skip_verify ? "  skip_verify = true" : "  # skip_verify omitted (TLS verified)"}
        TOML_${replace(host, ".", "_")}_END
        echo "[containerd-registry-host] wrote ${var.host_certs_d_path}/${host}/hosts.toml"
      SH
    ],
    [
      <<-SH
        # /etc/hosts is bind-mounted as a single inode (kubelet injects it
        # per-pod), so atomic rename via `sed -i.bak` fails with EBUSY.
        # Instead build the desired content in a tmp file then truncate-
        # and-write back via `cat > /etc/hosts`. Single pass: drop every
        # prior "# managed-by:..." line and append our current entries.
        TMP=$(mktemp)
        grep -v '# managed-by:containerd-registry-host' '${var.host_etc_hosts_path}' > "$TMP" || true
        ${join("\n", [
          for host, spec in var.registries : "        echo '${spec.host_ip} ${host} # managed-by:containerd-registry-host' >> \"$TMP\""
          if spec.host_ip != ""
        ])}
        cat "$TMP" > '${var.host_etc_hosts_path}'
        rm -f "$TMP"
        echo "[containerd-registry-host] /etc/hosts updated"
      SH
    ],
  ))
}

resource "kubernetes_daemon_set_v1" "this" {
  count = length(var.registries) == 0 ? 0 : 1

  metadata {
    name      = var.release_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = { "app.kubernetes.io/name" = var.release_name }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Force the pod to recreate when the rendered script changes
          # (e.g. operator adds a new registry to var.registries).
          "agent-platform/script-hash" = sha1(local.write_script)
        }
      }

      spec {
        host_pid     = true
        host_network = true

        toleration {
          operator = "Exists"
        }

        container {
          name  = "writer"
          image = var.image

          command = ["sh", "-c"]
          args    = [<<-EOT
            set -eu
            ${local.write_script}
            echo "[containerd-registry-host] all ${length(var.registries)} hosts written"
            exec sleep infinity
          EOT
          ]

          security_context {
            privileged = true
          }

          volume_mount {
            name       = "certs-d"
            mount_path = var.host_certs_d_path
          }
          volume_mount {
            name       = "etc-hosts"
            mount_path = var.host_etc_hosts_path
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }

        volume {
          name = "certs-d"
          host_path {
            path = var.host_certs_d_path
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "etc-hosts"
          host_path {
            path = var.host_etc_hosts_path
            type = "File"
          }
        }
      }
    }
  }
}
