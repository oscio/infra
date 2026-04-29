terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# =====================================================================
# Argo CD — GitOps + Image Updater (replaces Keel)
# =====================================================================
# Built-in `admin` stays as break-glass; Keycloak OIDC is the human path.
# Image Updater watches Harbor and patches Argo CD Applications when
# new tags appear, taking over the "auto-roll on push" role Keel had.
# =====================================================================

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "argocd"
    }
  }
}

# Self-signed CA — argocd-server / Image Updater hit Keycloak (and
# Harbor) over HTTPS. Without this they get x509 errors. Mounted via
# extraVolumes and exported as SSL_CERT_FILE.
resource "kubernetes_config_map_v1" "platform_ca" {
  count = length(var.ca_configmap_data) == 0 ? 0 : 1

  metadata {
    name      = "${var.release_name}-platform-ca"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = var.ca_configmap_data
}

locals {
  ca_enabled    = length(kubernetes_config_map_v1.platform_ca) > 0
  ca_mount_dir  = "/etc/argocd-ca"
  ca_mount_file = "${local.ca_mount_dir}/ca.crt"

  oidc_wired = var.oidc_enabled && var.oidc_issuer_url != "" && var.oidc_client_secret != ""

  # argocd-cm key oidc.config — multi-line string the chart's `configs.cm`
  # block embeds. Requested scopes include `groups` so the RBAC mapping
  # below can match Keycloak realm groups.
  oidc_config_yaml = local.oidc_wired ? yamlencode({
    name            = "Keycloak"
    issuer          = var.oidc_issuer_url
    clientID        = var.oidc_client_id
    clientSecret    = "$oidc.keycloak.clientSecret"
    requestedScopes = ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims = {
      groups = { essential = true }
    }
  }) : ""

  # Map the Keycloak realm admin group → Argo CD admin role. RBAC
  # CSV: `g, <group>, role:admin`. Default Argo CD policy stays in
  # place for everything else (read-only).
  rbac_policy_csv = var.oidc_admin_group == "" ? "" : "g, ${var.oidc_admin_group}, role:admin\n"

  ca_extra_volumes = local.ca_enabled ? [{
    name = "platform-ca"
    configMap = {
      name = kubernetes_config_map_v1.platform_ca[0].metadata[0].name
      items = [{ key = "ca.crt", path = "ca.crt" }]
    }
  }] : []

  ca_extra_volume_mounts = local.ca_enabled ? [{
    name      = "platform-ca"
    mountPath = local.ca_mount_dir
    readOnly  = true
  }] : []

  ca_extra_env = local.ca_enabled ? [{
    name  = "SSL_CERT_FILE"
    value = local.ca_mount_file
  }] : []
}

# =====================================================================
# Argo CD Helm release
# =====================================================================

resource "helm_release" "argocd" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  timeout = 600
  wait    = true

  values = [yamlencode({
    global = {
      domain = var.hostname
    }

    configs = {
      # Admin password (bcrypt-hashed by the chart's secret render).
      # The chart accepts `secret.argocdServerAdminPassword` as plaintext
      # and bcrypts it at apply time.
      secret = {
        createSecret               = true
        argocdServerAdminPassword  = bcrypt(var.admin_password)
        # Stable mtime so `argocd login` doesn't invalidate sessions on
        # every reconcile. Bumped only when admin_password actually changes.
        argocdServerAdminPasswordMtime = "2026-01-01T00:00:00Z"
        extra = local.oidc_wired ? {
          "oidc.keycloak.clientSecret" = var.oidc_client_secret
        } : {}
      }

      # argocd-cm — OIDC + URL.
      cm = merge(
        {
          "url" = "https://${var.hostname}"
        },
        local.oidc_wired ? {
          "oidc.config" = local.oidc_config_yaml
        } : {},
      )

      # argocd-rbac-cm — group → role mapping.
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv"     = local.rbac_policy_csv
        "scopes"         = "[groups]"
      }

      # argocd-cmd-params-cm — let Traefik terminate TLS, run argocd-server
      # in plaintext mode behind it. Without --insecure the server enforces
      # HTTP→HTTPS and the HTTPRoute backend port speaks HTTP only.
      params = {
        "server.insecure" = true
      }
    }

    server = {
      extraVolumes      = local.ca_extra_volumes
      extraVolumeMounts = local.ca_extra_volume_mounts
      env               = local.ca_extra_env
    }

    repoServer = {
      extraVolumes      = local.ca_extra_volumes
      extraVolumeMounts = local.ca_extra_volume_mounts
      env               = local.ca_extra_env
    }
  })]

  depends_on = [
    kubernetes_namespace.this,
    kubernetes_config_map_v1.platform_ca,
  ]
}

# =====================================================================
# HTTPRoute on cd.<domain> — argocd-server :80 (insecure mode).
# =====================================================================

resource "kubectl_manifest" "httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = var.release_name
      namespace = kubernetes_namespace.this.metadata[0].name
    }
    spec = {
      parentRefs = [merge(
        {
          name      = var.gateway_parent_ref.name
          namespace = var.gateway_parent_ref.namespace
        },
        var.gateway_parent_ref.sectionName == null ? {} : { sectionName = var.gateway_parent_ref.sectionName },
      )]
      hostnames = [var.hostname]
      rules = [{
        matches = [{ path = { type = "PathPrefix", value = "/" } }]
        backendRefs = [{
          # Chart names the server Service `<release>-server`.
          name = "${var.release_name}-server"
          port = 80
        }]
      }]
    }
  })

  depends_on = [helm_release.argocd]
}

# =====================================================================
# Argo CD Image Updater — Keel's replacement for "Harbor push → roll".
# Watches registries listed in var.image_updater_registries and patches
# Argo CD Application manifests when new tags appear. Updates flow:
#   Harbor push → Image Updater detects → patches Application →
#   Argo CD reconciles → kubelet rolls pod.
# =====================================================================

resource "helm_release" "image_updater" {
  count = var.image_updater_enabled ? 1 : 0

  name       = "${var.release_name}-image-updater"
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = var.image_updater_chart_version

  timeout = 300
  wait    = true

  values = [yamlencode({
    config = {
      # When set, the updater talks to Argo CD's gRPC API directly.
      # Default reads CR objects in-cluster, which is enough for
      # write-back targets that live in the same cluster.
      argocd = {
        grpcWeb     = true
        serverAddress = "${var.release_name}-server.${var.namespace}.svc.cluster.local"
        insecure    = true
        plaintext   = true
      }
      registries = [
        for k, v in var.image_updater_registries : merge(
          {
            name        = k
            api_url     = v.api_url
            prefix      = v.prefix
            ping        = v.ping
            insecure    = v.insecure
            default     = v.default
          },
          v.credentials == "" ? {} : { credentials = v.credentials },
        )
      ]
    }

    extraVolumes      = local.ca_extra_volumes
    extraVolumeMounts = local.ca_extra_volume_mounts
    extraEnv          = local.ca_extra_env
  })]

  depends_on = [helm_release.argocd]
}
