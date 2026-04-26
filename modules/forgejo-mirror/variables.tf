variable "public_forgejo_url" {
  description = "Public Forgejo URL the local terraform host can reach (e.g. https://git.dev.openschema.io). The mirror creation runs as a `local-exec` from terraform's host because Forgejo's `/api/v1/repos/migrate` endpoint is the cleanest way to create a pull-mirror — there's no first-class terraform-provider-forgejo resource for it that handles all of {private repos, auth, idempotent re-run}."
  type        = string
}

variable "forgejo_admin_username" {
  description = "Forgejo admin user used to create mirror repos via API."
  type        = string
}

variable "forgejo_admin_password" {
  description = "Forgejo admin password / token. Sensitive."
  type        = string
  sensitive   = true
}

variable "target_owner" {
  description = "Forgejo user or org that owns the mirror repos. Empty defaults to the admin user — fine for solo dev; production should give each team its own org and pass that here."
  type        = string
  default     = ""
}

variable "repos" {
  description = <<-EOT
    Map of mirror specs. Key is the LOCAL repo name in Forgejo (becomes
    the URL path: <forgejo>/<owner>/<key>). Each value:

      clone_addr   = upstream URL to mirror from (e.g. https://github.com/owner/agent-spawner)
      private      = optional bool, default false. Set true if upstream is private.
      auth_username= optional GitHub username for private upstream
      auth_password= optional GitHub PAT for private upstream
      description  = optional human-readable description

    Mirrors are configured as periodic-sync (Forgejo's default 8h pull
    cadence). To force a sync, the user can hit Forgejo's UI → Settings
    → Mirror → Sync Now, or call POST /api/v1/repos/<owner>/<repo>/mirror-sync.
  EOT
  type = map(object({
    clone_addr    = string
    private       = optional(bool, false)
    auth_username = optional(string, "")
    auth_password = optional(string, "")
    description   = optional(string, "")
  }))
  default = {}
}
