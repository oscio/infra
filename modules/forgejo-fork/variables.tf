variable "namespace" {
  description = "Namespace to run the bootstrap Job in. Should be the same namespace as Forgejo (so the in-cluster URL resolves and the Job can be co-located with logs/secrets the operator already greps)."
  type        = string
}

variable "forgejo_internal_url" {
  description = "In-cluster Forgejo URL the Job container hits (e.g. http://forgejo-http.platform-forgejo.svc.cluster.local:3000). Plain HTTP — avoids the self-signed-cert noise of going through the public Gateway."
  type        = string
}

variable "public_forgejo_url" {
  description = "Public Forgejo URL — used only to compose the `fork_urls` output for human-facing display. Not hit at apply time."
  type        = string
}

variable "forgejo_admin_username" {
  description = "Forgejo admin user used to create fork repos via API."
  type        = string
}

variable "forgejo_admin_password" {
  description = "Forgejo admin password / token. Sensitive."
  type        = string
  sensitive   = true
}

variable "target_owner" {
  description = "Forgejo user or org that owns the forked repos. Empty defaults to the admin user — fine for solo dev; production should give each team its own org and pass that here."
  type        = string
  default     = ""
}

variable "bootstrap_image" {
  description = "Image for the migration Job. Needs `sh`, `curl`, and `jq`. Default `alpine/k8s` bundles all three (plus kubectl, harmless extra)."
  type        = string
  default     = "alpine/k8s:1.31.3"
}

variable "repos" {
  description = <<-EOT
    Map of fork specs. Key is the LOCAL repo name in Forgejo (becomes
    the URL path: <forgejo>/<owner>/<key>). Each value:

      clone_addr   = upstream URL to clone from (e.g. https://github.com/owner/agent-sandbox)
      private      = optional bool, default false. Set true if upstream is private.
      auth_username= optional GitHub username for private upstream
      auth_password= optional GitHub PAT for private upstream
      description  = optional human-readable description
      extra_files  = optional map(<path-in-repo> => <base64-encoded content>).
                     Overlays files on the freshly-forked repo (typical use:
                     replace upstream's `.forgejo/workflows/build.yml` with
                     a known-good in-cluster version so CI works on first
                     push). Pre-encode with `base64encode(file(...))`.

    Forks are independent copies — no automatic sync from upstream. To
    pull upstream changes later, delete the repo and re-run the
    bootstrap, or import specific changes manually.
  EOT
  type = map(object({
    clone_addr    = string
    private       = optional(bool, false)
    auth_username = optional(string, "")
    auth_password = optional(string, "")
    description   = optional(string, "")
    extra_files   = optional(map(string), {})
  }))
  default = {}
}

variable "enable_actions" {
  description = "After migrate, PATCH `has_actions=true` on each forked repo. Forgejo's default is off even when the cluster-wide `[actions] ENABLED=true` setting is on, so without this the Actions tab never shows up."
  type        = bool
  default     = true
}

variable "org_secrets" {
  description = "Org-level Forgejo Actions secrets to set (e.g. HARBOR_USER, HARBOR_TOKEN). Set once on the org and inherited by every repo under it. Only applied when `target_owner` is non-empty (org must exist)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "org_variables" {
  description = "Org-level Forgejo Actions variables (non-secret, readable in workflows via `vars.<NAME>`). Use for cluster-specific values that differ between dev/prod (e.g. `HARBOR` pointing at the in-cluster ClusterIP in dev, the public hostname in prod) so the workflow YAML stays portable across clusters."
  type        = map(string)
  default     = {}
}
