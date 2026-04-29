terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

# =====================================================================
# Keel — registry-polling Deployment auto-updater
# =====================================================================
#
# Why Keel (vs ArgoCD Image Updater): ACDIU's write-back targets are
# Argo CD Applications (helm / kustomize / git). The platform's app
# Deployments are managed directly by terraform, not Argo CD, so
# ACDIU's strategies don't apply. Keel's annotation-driven model
# patches plain Deployments / StatefulSets, which is the minimum we
# need for "Forgejo build → Harbor push → Deployment auto-rolls".
#
# How it works for us:
#   1. The Deployment carries `keel.sh/policy: force` + `keel.sh/trigger: poll`
#   2. Keel polls Harbor for the configured image's digest every
#      `poll_schedule` (default 1m)
#   3. New digest → Keel patches the Deployment → kubelet rolls the pod
#
# The dockerconfigjson Secret (same one Forgejo Runner uses to push) is
# attached to Keel's ServiceAccount so registry auth is shared.

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "keel"
    }
  }
}

# =====================================================================
# Harbor auth — mirror dockerconfigjson into Keel's namespace
# =====================================================================
# The Secret name is intentionally NOT `harbor-pull-secret` (which the
# chart, with its default values, would also try to render): Helm SDK
# v3 refuses to install if a Secret with a name it might render exists
# without `app.kubernetes.io/managed-by=Helm` labels.
#
# The chart's `dockerRegistry.*` block wires this Secret into the
# `DOCKER_REGISTRY_CFG` env var via `valueFrom.secretKeyRef`. Keel reads
# that env var as the JSON *content* of a docker config (not a file
# path — `extraVolumes` + `SSL_CERT_FILE`-style mounting crashed with
# "failed to decode secret provided in DOCKER_REGISTRY_CFG").

data "kubernetes_secret_v1" "source" {
  count = var.harbor_pull_secret_name != "" && var.harbor_pull_secret_namespace != "" ? 1 : 0

  metadata {
    name      = var.harbor_pull_secret_name
    namespace = var.harbor_pull_secret_namespace
  }
}

resource "kubernetes_secret_v1" "docker_config" {
  count = var.harbor_pull_secret_name != "" && var.harbor_pull_secret_namespace != "" ? 1 : 0

  metadata {
    name      = "keel-docker-config"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = data.kubernetes_secret_v1.source[0].data[".dockerconfigjson"]
  }
}

# =====================================================================
# Self-signed CA — mount the platform CA + point Go TLS at it via
# `SSL_CERT_FILE` so the Harbor poll's HTTPS check passes.
#
# Without this Keel logs `x509: certificate signed by unknown authority`
# and never advances past the digest fetch on a tls_mode=selfsigned
# cluster.
# =====================================================================

resource "kubernetes_config_map_v1" "platform_ca" {
  count = length(var.ca_configmap_data) == 0 ? 0 : 1

  metadata {
    name      = "keel-platform-ca"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = var.ca_configmap_data
}

locals {
  registry_auth_enabled = length(kubernetes_secret_v1.docker_config) > 0
  ca_enabled            = length(kubernetes_config_map_v1.platform_ca) > 0
  ingress_enabled       = var.hostname != "" && var.gateway_parent_ref != null

  ca_mount_dir  = "/etc/keel-ca"
  ca_mount_file = "${local.ca_mount_dir}/ca.crt"

  registry_auth_values = local.registry_auth_enabled ? {
    dockerRegistry = {
      enabled = true
      name    = kubernetes_secret_v1.docker_config[0].metadata[0].name
      key     = ".dockerconfigjson"
    }
  } : {}

  service_values = local.ingress_enabled ? {
    service = {
      enabled      = true
      type         = "ClusterIP"
      externalPort = 9300
    }
  } : {}

  # The admin dashboard ships only in the upstream `latest` image. Override
  # the chart's pinned tag when the operator opts in via `image_tag`.
  image_values = var.image_tag == "" ? {} : {
    image = {
      tag = var.image_tag
    }
  }

  # Dashboard requires basic auth — without credentials the UI returns 401.
  basicauth_enabled = var.basicauth_user != "" && var.basicauth_password != ""
  basicauth_values = local.basicauth_enabled ? {
    basicauth = {
      enabled  = true
      user     = var.basicauth_user
      password = var.basicauth_password
    }
  } : {}

  ca_values = {
    extraVolumes = local.ca_enabled ? [{
      name = "platform-ca"
      configMap = {
        name = kubernetes_config_map_v1.platform_ca[0].metadata[0].name
        items = [{
          key  = "ca.crt"
          path = "ca.crt"
        }]
      }
    }] : []
    extraVolumeMounts = local.ca_enabled ? [{
      name      = "platform-ca"
      mountPath = local.ca_mount_dir
      readOnly  = true
    }] : []
    extraEnv = local.ca_enabled ? [{
      name  = "SSL_CERT_FILE"
      value = local.ca_mount_file
    }] : []
  }
}

resource "helm_release" "keel" {
  name       = var.release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://charts.keel.sh"
  chart      = "keel"
  version    = var.chart_version

  timeout = 300
  wait    = true

  values = [yamlencode(merge({
    helmProvider = { enabled = false } # we use Deployment-annotation mode, not Helm releases
    polling = {
      enabled         = true
      defaultSchedule = var.poll_schedule
    }
    rbac           = { enabled = true }
    serviceAccount = { create = true }
    # Cluster-wide so Keel can patch Deployments in any namespace.
    namespaces = []
  }, local.registry_auth_values, local.ca_values, local.service_values, local.image_values, local.basicauth_values))]

  depends_on = [
    kubernetes_namespace.this,
    kubernetes_secret_v1.docker_config,
    kubernetes_config_map_v1.platform_ca,
  ]
}

# =====================================================================
# HTTPRoute — expose Keel's web UI through the platform Gateway.
# =====================================================================
# Useful as a lightweight inspection surface (which Deployments Keel is
# tracking, what tags it's seen) without standing up Argo CD just for
# the dashboard. The chart's Service stays disabled by default; we flip
# it on via `service_values` above only when a hostname is provided.

resource "kubectl_manifest" "httproute" {
  count = local.ingress_enabled ? 1 : 0

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
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          name = var.release_name
          port = 9300
        }]
      }]
    }
  })

  depends_on = [helm_release.keel]
}
