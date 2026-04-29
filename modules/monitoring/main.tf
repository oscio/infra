terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}

locals {
  use_gateway_api = var.gateway_api_enabled

  ca_enabled             = var.ca_source_secret_name != ""
  ca_configmap_name      = "platform-ca"
  ca_mount_path          = "/etc/ssl/certs/platform-ca.crt"
  grafana_service_name   = "${var.kube_prometheus_stack_release_name}-grafana"
  prometheus_service_url = "http://${var.kube_prometheus_stack_release_name}-prometheus.${var.namespace}.svc.cluster.local:9090"
  loki_gateway_url       = "http://${var.loki_release_name}-gateway.${var.namespace}.svc.cluster.local"

  # --------------------------------------------------------------------------
  # kube-prometheus-stack values.
  #
  # Dev profile: single Prometheus + single Alertmanager, Grafana fronted by
  # a ClusterIP Service (HTTPRoute created separately below).
  #
  # IMPORTANT: the bundled Grafana subchart (v9+) runs an `assertNoLeakedSecrets`
  # helm template check that fails if sensitive keys (admin password, OIDC
  # client secret) appear in-line in `grafana.ini`. Strategy:
  #   - admin password is piped in via `adminPassword` which the chart routes
  #     through a Secret-backed env var (GF_SECURITY_ADMIN_PASSWORD) so it's
  #     already safe.
  #   - OIDC client_secret is OMITTED from `grafana.ini` and injected via
  #     `envRenderSecret` as GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET — Grafana
  #     automatically maps env vars of the form GF_<SECTION>_<KEY> into the
  #     equivalent ini setting at runtime.
  # --------------------------------------------------------------------------
  kps_grafana_auth_yaml = var.oidc_enabled ? yamlencode({
    grafana = {
      # Inject the OIDC client secret via a rendered Secret (env var), not
      # via the grafana.ini values. This is what the upstream chart's
      # assertNoLeakedSecrets check mandates.
      envRenderSecret = {
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = var.oidc_client_secret
      }
      "grafana.ini" = {
        server = {
          root_url            = "https://${var.hostname}/"
          serve_from_sub_path = false
        }
        security = {
          admin_email = var.grafana_admin_email
        }
        auth = {
          disable_login_form = var.oidc_auto_login
          oauth_auto_login   = var.oidc_auto_login
          # Keep the built-in /login path reachable so users can break-glass
          # in with admin when OIDC is down.
          signout_redirect_url = "${var.oidc_issuer_url}/protocol/openid-connect/logout"
        }
        "auth.generic_oauth" = {
          enabled       = true
          name          = "Keycloak"
          allow_sign_up = true
          client_id     = var.oidc_client_id
          # client_secret intentionally omitted — supplied via
          # GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET env var (envRenderSecret).
          scopes                     = "openid email profile groups"
          auth_url                   = "${var.oidc_issuer_url}/protocol/openid-connect/auth"
          token_url                  = "${var.oidc_issuer_url}/protocol/openid-connect/token"
          api_url                    = "${var.oidc_issuer_url}/protocol/openid-connect/userinfo"
          signout_redirect_url       = "${var.oidc_issuer_url}/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2F${var.hostname}%2Flogin"
          role_attribute_path        = local.grafana_role_jmespath
          allow_assign_grafana_admin = true
          use_pkce                   = true
        }
      }
    }
    }) : yamlencode({
    grafana = {
      adminUser     = var.grafana_admin_username
      adminPassword = var.grafana_admin_password
      "grafana.ini" = {
        server = {
          root_url = "https://${var.hostname}/"
        }
        security = {
          admin_email = var.grafana_admin_email
        }
      }
    }
  })

  # JMESPath expression mapping Keycloak `groups` claim -> Grafana role.
  # Evaluated by Grafana per-login. First matching condition wins.
  # Quoting rules (Grafana loads this as a config value, not YAML): wrap in
  # single quotes; inner literals are double-quoted.
  grafana_role_jmespath = join(" || ", concat(
    [for g in var.oidc_admin_groups : "contains(groups[*], '${g}') && 'GrafanaAdmin'"],
    [for g in var.oidc_editor_groups : "contains(groups[*], '${g}') && 'Editor'"],
    ["'Viewer'"],
  ))

  kps_base_values = {
    fullnameOverride = var.kube_prometheus_stack_release_name

    crds = { enabled = true }

    # Disable the chart's own Ingress/Route — we own routing via HTTPRoute.
    alertmanager = {
      alertmanagerSpec = {
        retention = "120h"
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class == "" ? null : var.storage_class
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = { storage = var.alertmanager_storage_size }
              }
            }
          }
        }
      }
    }

    prometheus = {
      prometheusSpec = {
        retention                               = var.prometheus_retention
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        probeSelectorNilUsesHelmValues          = false
        scrapeConfigSelectorNilUsesHelmValues   = false
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class == "" ? null : var.storage_class
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = { storage = var.prometheus_storage_size }
              }
            }
          }
        }
      }
    }

    grafana = {
      adminUser     = var.grafana_admin_username
      adminPassword = var.grafana_admin_password
      # adminEmail isn't a top-level chart value — it lives under
      # grafana.ini → users.default_email. Wired below in `grafana.ini`.

      persistence = {
        enabled          = true
        size             = var.grafana_storage_size
        storageClassName = var.storage_class == "" ? null : var.storage_class
      }

      # Disable the init-chown-data initContainer.
      # With `fsGroup=472` in the Grafana chart's default podSecurityContext,
      # Kubernetes recursively chowns the PVC to GID 472 at mount time, so
      # the chown init container is redundant. On Docker Desktop (and some
      # other setups) that init container crashes with "Permission denied"
      # even when running as root — the host-path provisioner rejects
      # root-inside-container chown. Turning it off works around this and
      # the Grafana process still runs as UID 472 with fsGroup-granted RW.
      initChownData = {
        enabled = false
      }

      service = {
        type = "ClusterIP"
        port = 80
      }

      # Provision Loki datasource in addition to the bundled Prometheus one.
      # kube-prometheus-stack already adds the Prometheus datasource from its
      # `sidecar.datasources.defaultDatasourceEnabled` block, so we only add
      # Loki here. Alertmanager datasource is nice-to-have, skipping for MVP.
      additionalDataSources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          access    = "proxy"
          url       = local.loki_gateway_url
          isDefault = false
          jsonData = {
            maxLines = 1000
          }
        },
      ]

      sidecar = {
        datasources = {
          defaultDatasourceEnabled = true
          # Scrape ConfigMaps labeled grafana_datasource=1 cluster-wide so future
          # app teams can contribute datasources by ConfigMap.
          searchNamespace = "ALL"
        }
        dashboards = {
          enabled         = true
          searchNamespace = "ALL"
          label           = "grafana_dashboard"
        }
      }
    }
  }

  # CA trust block for Grafana: mount the platform CA and point the container's
  # SSL cert bundle at it so the OIDC client validates Keycloak correctly when
  # tls_mode = "selfsigned". Kept as a separate YAML chunk to keep type
  # unification simple (Terraform requires conditional branches to have the
  # same object shape; emitting a string skips that).
  grafana_ca_values_yaml = local.ca_enabled ? yamlencode({
    grafana = {
      extraConfigmapMounts = [{
        name        = local.ca_configmap_name
        mountPath   = local.ca_mount_path
        subPath     = "ca.crt"
        configMap   = local.ca_configmap_name
        readOnly    = true
        defaultMode = 420
      }]
      env = {
        SSL_CERT_FILE = local.ca_mount_path
      }
    }
  }) : ""

  kps_values_yaml = yamlencode(local.kps_base_values)

  # --------------------------------------------------------------------------
  # Loki values (SingleBinary mode — simplest dev profile).
  # --------------------------------------------------------------------------
  loki_values = {
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false

      commonConfig = {
        replication_factor = 1
      }

      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index = {
            prefix = "loki_index_"
            period = "24h"
          }
        }]
      }

      storage = {
        type = "filesystem"
        bucketNames = {
          chunks = "chunks"
          ruler  = "ruler"
          admin  = "admin"
        }
      }

      limits_config = {
        retention_period           = var.loki_retention
        reject_old_samples         = true
        reject_old_samples_max_age = "168h"
        allow_structured_metadata  = true
        volume_enabled             = true
      }

      compactor = {
        retention_enabled    = true
        delete_request_store = "filesystem"
      }

      # SingleBinary mode requires pattern_ingester disabled (default) and
      # ingester settings suitable for a single replica.
      ingester = {
        chunk_idle_period   = "30m"
        chunk_retain_period = "1m"
      }

      # Pattern ingester (a v3 feature) needs wal + kafka; off for dev.
      pattern_ingester = { enabled = false }

      # Disable multi-tenant analytics pings.
      analytics = { reporting_enabled = false }
    }

    # SingleBinary replica count + storage.
    singleBinary = {
      replicas = 1
      persistence = {
        enabled      = true
        size         = var.loki_storage_size
        storageClass = var.storage_class == "" ? null : var.storage_class
      }
    }

    # Disable HA components (read, write, backend, ingester, querier, etc.)
    # that aren't used in SingleBinary mode.
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }

    # Chunk cache / results cache: default to the simple in-memory caches.
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }

    # Test pod / lokiCanary: disabled to keep the dev footprint minimal.
    test       = { enabled = false }
    lokiCanary = { enabled = false }

    # The gateway is an nginx reverse proxy in front of Loki; used as the
    # Grafana datasource URL above. Keep it enabled.
    gateway = {
      enabled  = true
      replicas = 1
    }

    # Disable Minio (we use filesystem storage for dev).
    minio = { enabled = false }

    # Enable metrics scraping by the kube-prometheus-stack Prometheus.
    monitoring = {
      serviceMonitor = { enabled = true }
      selfMonitoring = { enabled = false, grafanaAgent = { installOperator = false } }
      lokiCanary     = { enabled = false }
    }
  }

  loki_values_yaml = yamlencode(local.loki_values)

  # --------------------------------------------------------------------------
  # Alloy values (DaemonSet — tails pod logs and ships to Loki).
  #
  # Alloy uses River config, not YAML, so the config lives as a big string.
  # --------------------------------------------------------------------------
  alloy_config = <<-EOT
    // Scrape every pod log on the node and ship to Loki.
    // Kubernetes SD discovers the pods; relabeling turns the pod metadata into
    // LogQL labels.

    discovery.kubernetes "pods" {
      role = "pod"
    }

    discovery.relabel "pod_logs" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_node_name"]
        target_label  = "node"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        target_label  = "app"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_part_of"]
        target_label  = "part_of"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
        target_label  = "__path__"
        separator     = "/"
        replacement   = "/var/log/pods/*$1/*.log"
      }
    }

    loki.source.kubernetes "pod_logs" {
      targets    = discovery.relabel.pod_logs.output
      forward_to = [loki.process.pod_logs.receiver]
    }

    loki.process "pod_logs" {
      forward_to = [loki.write.default.receiver]

      // Drop high-cardinality labels we accidentally captured during relabeling.
      stage.label_keep {
        values = ["namespace", "pod", "container", "node", "app", "part_of"]
      }
    }

    loki.write "default" {
      endpoint {
        url = "${local.loki_gateway_url}/loki/api/v1/push"
      }
    }
  EOT

  alloy_values = {
    alloy = {
      configMap = {
        content = local.alloy_config
      }

      # Grant the Alloy ServiceAccount `get/list/watch` on pods and nodes.
      clustering = { enabled = false }

      mounts = {
        varlog           = true
        dockercontainers = true
      }
    }

    controller = {
      type = "daemonset"
    }

    crds = { create = false }

    service = { enabled = true }

    serviceMonitor = {
      enabled = true
      # Scraped by kube-prometheus-stack; no extra labels required because the
      # Prometheus object has selectorNilUsesHelmValues=false above.
    }
  }

  alloy_values_yaml = yamlencode(local.alloy_values)

  # --------------------------------------------------------------------------
  # HTTPRoute for Grafana (routes grafana.<domain> → grafana Service).
  # --------------------------------------------------------------------------
  grafana_httproute_manifest = local.use_gateway_api ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${var.kube_prometheus_stack_release_name}-grafana"
      namespace = kubernetes_namespace.this.metadata[0].name
      labels = {
        "app.kubernetes.io/part-of" = "agent-platform"
        "agent-platform/component"  = "monitoring"
      }
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
          name = local.grafana_service_name
          port = 80
        }]
      }]
    }
  }) : ""
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "monitoring"
    }
  }
}

# Mirror the platform CA into this namespace so Grafana can trust Keycloak's
# self-signed cert during OIDC. No-op when tls_mode != "selfsigned".
data "kubernetes_secret_v1" "ca_source" {
  count = local.ca_enabled ? 1 : 0

  metadata {
    name      = var.ca_source_secret_name
    namespace = var.ca_source_secret_namespace
  }
}

resource "kubernetes_config_map" "ca_bundle" {
  count = local.ca_enabled ? 1 : 0

  metadata {
    name      = local.ca_configmap_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "agent-platform"
      "agent-platform/component"  = "monitoring"
    }
  }

  data = {
    "ca.crt" = lookup(data.kubernetes_secret_v1.ca_source[0].data, "ca.crt", "")
  }
}

# -----------------------------------------------------------------------------
# kube-prometheus-stack — Prometheus, Alertmanager, Grafana, node-exporter,
# kube-state-metrics.
# -----------------------------------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  name       = var.kube_prometheus_stack_release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version

  # kube-prometheus-stack installs a LOT of CRDs; give it generous time.
  timeout = 900
  wait    = true

  values = compact([
    local.kps_values_yaml,
    local.kps_grafana_auth_yaml,
    local.grafana_ca_values_yaml,
    var.extra_kube_prometheus_stack_values,
  ])

  depends_on = [kubernetes_config_map.ca_bundle]
}

# -----------------------------------------------------------------------------
# Loki — log store. SingleBinary mode for dev.
# -----------------------------------------------------------------------------
resource "helm_release" "loki" {
  name       = var.loki_release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version

  timeout = 600
  wait    = true

  values = compact([
    local.loki_values_yaml,
    var.extra_loki_values,
  ])

  # Loki's ServiceMonitor references the Prometheus operator CRDs installed by
  # kube-prometheus-stack. Install order matters to avoid a CRD-not-found error.
  depends_on = [helm_release.kube_prometheus_stack]
}

# -----------------------------------------------------------------------------
# Grafana Alloy — collects pod logs and ships them to Loki.
# -----------------------------------------------------------------------------
resource "helm_release" "alloy" {
  name       = var.alloy_release_name
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version

  timeout = 300
  wait    = true

  values = compact([
    local.alloy_values_yaml,
    var.extra_alloy_values,
  ])

  # Needs Loki up to have a push target, and needs the Prometheus operator CRDs
  # for its own ServiceMonitor.
  depends_on = [
    helm_release.loki,
    helm_release.kube_prometheus_stack,
  ]
}

# -----------------------------------------------------------------------------
# Grafana HTTPRoute — attached to the platform Gateway.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "grafana_httproute" {
  count = local.use_gateway_api ? 1 : 0

  yaml_body  = local.grafana_httproute_manifest
  depends_on = [helm_release.kube_prometheus_stack]

  lifecycle {
    precondition {
      condition     = var.gateway_parent_ref != null
      error_message = "gateway_parent_ref is required when gateway_api_enabled = true."
    }
  }
}
