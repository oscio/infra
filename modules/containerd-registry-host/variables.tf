variable "namespace" {
  description = "Namespace for the DaemonSet."
  type        = string
  default     = "kube-system"
}

variable "release_name" {
  description = "Base name for the DaemonSet (also used as label and resource name suffix)."
  type        = string
  default     = "containerd-registry-host"
}

variable "registries" {
  description = <<-EOT
    Map of <hostname> => { skip_verify, host_url, server }. One
    `/etc/containerd/certs.d/<hostname>/hosts.toml` is dropped per
    entry.

    - `skip_verify=true` makes containerd ignore the registry's TLS
      cert (typical for self-signed dev registries) — equivalent to
      Docker Desktop's `insecure-registries`.
    - `host_ip` writes a `<host_ip> <hostname>` line to `/etc/hosts`
      on every node so containerd resolves the registry to that IP
      *while still sending the original hostname as Host header*. Use
      when host-side dnsmasq returns an unreachable IP (e.g. 127.0.0.1
      for browser convenience but kubelet needs the gateway LB IP).
      Empty = leave node DNS alone.
    - `server` is the canonical registry URL the image refs are tagged
      against — usually unset (defaults to `https://<hostname>`).

    Example:
      registries = {
        "cr.dev.example.com" = {
          skip_verify = true
          host_url    = "https://10.96.0.42"   # Traefik LB IP
        }
      }
  EOT
  type = map(object({
    skip_verify = optional(bool, true)
    host_ip     = optional(string, "")
    server      = optional(string, "")
  }))
  default = {}
}

variable "host_etc_hosts_path" {
  description = "Path to the node's /etc/hosts. Default `/etc/hosts` matches Docker Desktop and kubeadm clusters. The DaemonSet appends `<host_ip> <hostname>` lines, idempotent (skipped if already present)."
  type        = string
  default     = "/etc/hosts"
}

variable "image" {
  description = "Image used for the writer container. Needs `sh` and basic coreutils."
  type        = string
  default     = "busybox:1.36"
}

variable "host_certs_d_path" {
  description = "Path to containerd's per-registry config directory on the host. Default `/etc/containerd/certs.d` matches both kubeadm clusters and Docker Desktop's containerd."
  type        = string
  default     = "/etc/containerd/certs.d"
}
