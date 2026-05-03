variable "namespace" {
  description = "Namespace to install the runner into."
  type        = string
  default     = "platform-forgejo"
}

variable "release_name" {
  description = "Base name for runner resources."
  type        = string
  default     = "forgejo-runner"
}

variable "replicas" {
  description = "Number of runner replicas."
  type        = number
  default     = 1
}

# --- Images ---

variable "runner_image" {
  description = "Forgejo runner container image."
  type        = string
  default     = "code.forgejo.org/forgejo/runner:6.3.0"
}

variable "dind_image" {
  description = "Docker-in-Docker container image. Spawns job containers (e.g. node:20-bookworm for actions/checkout) since forgejo-runner needs a Docker daemon for container-mode execution."
  type        = string
  default     = "docker:24-dind"
}

# --- Connection to Forgejo ---

variable "forgejo_url" {
  description = "Base URL Forgejo is reachable at from inside the cluster (e.g. http://forgejo-http.platform-forgejo.svc.cluster.local:3000). Used by the runner to poll tasks."
  type        = string
}

variable "forgejo_admin_username" {
  description = "Forgejo admin username. Used to obtain a runner-registration token via the admin API."
  type        = string
}

variable "forgejo_admin_password" {
  description = "Forgejo admin password."
  type        = string
  sensitive   = true
}

variable "public_forgejo_url" {
  description = "Public Forgejo URL (e.g. https://git.dev.example.com). Used for the token-fetch local-exec where TLS validity matters."
  type        = string
  default     = ""
}

variable "public_resolve_ip" {
  description = "Optional IP for curl --resolve <forgejo-host>:443:<ip> when the local Terraform host cannot resolve the public Forgejo hostname."
  type        = string
  default     = ""
}

# --- Storage ---

variable "storage_class" {
  description = "StorageClass for the runner's cache PVC. Empty = cluster default."
  type        = string
  default     = ""
}

variable "cache_storage_size" {
  description = "PVC size for runner cache (build layers, workflow artifacts)."
  type        = string
  default     = "10Gi"
}

# --- Cache pruning sidecar ---
# Without periodic pruning, DinD's /var/lib/docker grows unboundedly
# (every workflow leaves layers behind). The local-path provisioner
# does NOT enforce the requested PVC size, so the cache silently
# eats the host disk and eventually trips DiskPressure on the node,
# blocking ALL pod scheduling. The sidecar runs `docker system
# prune` against the DinD daemon on a fixed cadence + a free-space
# watermark to keep the cache bounded.

variable "cache_prune_image" {
  description = "Image used by the cache-pruner sidecar. Needs the docker CLI."
  type        = string
  default     = "docker:24-cli"
}

variable "cache_prune_interval_seconds" {
  description = "Seconds between routine prune passes. Each pass removes images / build cache older than `cache_prune_until_age` so caches still help across back-to-back builds."
  type        = number
  default     = 21600 # 6 hours
}

variable "cache_prune_until_age" {
  description = "Docker `until=` filter argument for routine prunes (e.g. `24h`, `7d`). Sets the minimum age of items to evict; recent layers stay so warm builds remain fast."
  type        = string
  default     = "24h"
}

variable "cache_prune_emergency_pct" {
  description = "Filesystem-use percentage at which the sidecar performs an UNFILTERED `docker system prune -af --volumes` regardless of `until_age`. Set to 0 to disable the emergency path."
  type        = number
  default     = 75
}

# --- Resources ---

variable "runner_cpu_request" {
  type    = string
  default = "500m"
}
variable "runner_cpu_limit" {
  type    = string
  default = "4"
}
variable "runner_memory_request" {
  type    = string
  default = "1Gi"
}
variable "runner_memory_limit" {
  type    = string
  default = "4Gi"
}

variable "dind_cpu_request" {
  type    = string
  default = "500m"
}
variable "dind_cpu_limit" {
  type    = string
  default = "4"
}
variable "dind_memory_request" {
  type    = string
  default = "1Gi"
}
variable "dind_memory_limit" {
  type    = string
  default = "8Gi"
}

variable "dind_mtu" {
  description = "MTU for the docker0 bridge inside DinD. Set to the pod network's eth0 MTU when smaller than 1500 (k3s/Flannel vxlan: 1450, Wireguard: 1380). 0 = leave docker default. Mismatch silently black-holes large packets → 'TLS handshake timeout' pulling base images."
  type        = number
  default     = 0
}

# --- Labels workflows can target (runs-on: ...) ---

variable "runner_labels" {
  description = <<-EOT
    Labels advertised to Forgejo. Use the `<label>:docker://<image>` form
    so jobs run inside a container (needed for Node-based actions like
    actions/checkout). Bare labels (no scheme) fall back to host mode,
    where the runner image has no `node` and most actions break.
    Workflows reference these via `runs-on: <label>`.
  EOT
  type        = list(string)
  default = [
    "docker:docker://node:20-bookworm",
    "ubuntu-latest:docker://catthehacker/ubuntu:act-latest",
    "ubuntu-22.04:docker://catthehacker/ubuntu:act-22.04",
    "ubuntu-20.04:docker://catthehacker/ubuntu:act-20.04",
  ]
}

# --- Registry auth (for docker buildx push → Harbor) ---

variable "registry_host" {
  description = "Harbor hostname (e.g. registry.dev.example.com). Used to construct ~/.docker/config.json AND, when `registry_insecure = true`, added to DinD's --insecure-registry list so buildx push works against a self-signed registry without bundling the cluster CA."
  type        = string
  default     = ""
}

variable "registry_insecure" {
  description = "Skip TLS verification for `registry_host` from inside the runner pod (DinD daemon + buildkit). Use for dev clusters with self-signed certs. Production should leave this false and ship a trusted CA bundle instead."
  type        = bool
  default     = false
}

variable "registry_username" {
  description = "Harbor robot account username for pushing from CI."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Harbor robot account password."
  type        = string
  default     = ""
  sensitive   = true
}
