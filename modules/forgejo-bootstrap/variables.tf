variable "forgejo_url" {
  description = "Public Forgejo URL the local terraform host can reach (e.g. https://git.dev.openschema.io)."
  type        = string
}

variable "admin_user" {
  description = "Forgejo admin username (typically `forgejo-admin`)."
  type        = string
}

variable "admin_password" {
  description = "Forgejo admin password. Sensitive — only used for the initial token mint over HTTP basic auth."
  type        = string
  sensitive   = true
}

variable "token_name" {
  description = "Name of the admin Personal Access Token to mint. Must be unique per user; the bootstrap deletes any existing token with this name before recreating, so re-runs always yield a usable token in state."
  type        = string
  default     = "platform-bootstrap"
}

variable "token_scopes" {
  description = "PAT scopes. Default grants `write:user` (mint per-project tokens via Sudo) + `write:admin` (create users on first project)."
  type        = list(string)
  default     = ["write:admin", "write:user"]
}
