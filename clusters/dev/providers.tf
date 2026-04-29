terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    keycloak   = { source = "keycloak/keycloak", version = "~> 5.0" }
    # Used by harbor-bootstrap and forgejo-bootstrap modules to call the
    # Harbor / Forgejo REST APIs at plan time.
    external = { source = "hashicorp/external", version = "~> 2.3" }
    null     = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}

# Keycloak provider. Authenticates against the already-running Keycloak
# using the bootstrap admin user. Set via TF_VAR_* env vars in CI.
provider "keycloak" {
  client_id     = "admin-cli"
  username      = var.keycloak_admin_username
  password      = var.keycloak_admin_password
  url           = "https://${local.keycloak_hostname}"
  realm         = "master"
  initial_login = false # don't hit the server during terraform init/plan

  # Accept the self-signed CA when tls_mode = "selfsigned". Let's Encrypt
  # modes serve real trusted certs, so we can skip verification universally
  # here — the provider only talks to our own cluster's Keycloak over the
  # local Gateway, so MITM risk is negligible inside this context.
  tls_insecure_skip_verify = local.tls_is_selfsigned
}
