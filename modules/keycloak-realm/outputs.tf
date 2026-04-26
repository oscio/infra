output "realm_name" {
  value = keycloak_realm.platform.realm
}

output "realm_id" {
  value = keycloak_realm.platform.id
}

output "client_ids" {
  description = "Map of client_id -> internal Keycloak UUID. Useful when other Terraform code needs to reference these clients."
  value = merge(
    {
      "oauth2-proxy" = keycloak_openid_client.oauth2_proxy.id
      "argocd"       = keycloak_openid_client.argocd.id
      "hermes"       = keycloak_openid_client.hermes.id
      "devpod"       = keycloak_openid_client.devpod.id
    },
    var.forgejo_url == "" ? {} : {
      "forgejo" = keycloak_openid_client.forgejo[0].id
    },
    var.harbor_url == "" ? {} : {
      "harbor" = keycloak_openid_client.harbor[0].id
    },
  )
}

output "group_ids" {
  description = "Map of group name -> Keycloak UUID."
  value = {
    "platform-admin" = keycloak_group.platform_admin.id
    "developer"      = keycloak_group.developer.id
    "viewer"         = keycloak_group.viewer.id
  }
}
