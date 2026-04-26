# infra/modules/monitoring

Installs the Grafana observability stack on a Kubernetes cluster:

| Component                 | Chart                                        | Purpose                                       |
| ------------------------- | -------------------------------------------- | --------------------------------------------- |
| **Prometheus**            | `prometheus-community/kube-prometheus-stack` | Metrics (scrapes ServiceMonitors / PodMonitors) |
| **Alertmanager**          | (bundled in kube-prometheus-stack)           | Alert routing                                 |
| **node-exporter**         | (bundled)                                    | Node hardware/OS metrics                      |
| **kube-state-metrics**    | (bundled)                                    | Kubernetes API metrics                        |
| **Grafana**               | (bundled)                                    | Dashboards + query UI                         |
| **Loki**                  | `grafana/loki` (SingleBinary mode)           | Log store                                     |
| **Grafana Alloy**         | `grafana/alloy` (DaemonSet)                  | Tails pod logs → ships to Loki                |

Everything lives in `platform-monitoring`. Grafana is exposed at
`var.hostname` (typically `grafana.<domain>`) via an HTTPRoute on the shared
platform Gateway.

## Auth

When `oidc_enabled = true`, Grafana is wired to the Keycloak `platform` realm:

- `auth.generic_oauth` is configured to use Keycloak.
- `role_attribute_path` (a JMESPath) maps Keycloak groups → Grafana roles:
  - any group in `oidc_admin_groups` → `GrafanaAdmin`
  - any group in `oidc_editor_groups` → `Editor`
  - everyone else → `Viewer`
- The OIDC client is named `grafana` and is seeded by the `keycloak-realm`
  module (requires `realm_enabled = true` on the cluster).
- A local `admin` user is still provisioned as break-glass; set
  `oidc_auto_login = true` to hide it from the login page.

When `tls_mode = "selfsigned"`, set `ca_source_secret_name` to the internal
CA Secret (`platform-root-ca` in `cert-manager`). The module mirrors it into
this namespace and mounts it at `SSL_CERT_FILE` so Grafana validates
Keycloak's cert during OIDC discovery.

## Datasources

Two datasources are provisioned automatically:

- `Prometheus` — the in-cluster Prometheus (set as default).
- `Loki` — the in-cluster Loki gateway.

Extra datasources and dashboards can be contributed by any namespace via
ConfigMaps labelled `grafana_datasource=1` or `grafana_dashboard=1` — the
Grafana sidecar picks them up cluster-wide.

## Storage profiles

Dev defaults are modest (PVs sized for Docker Desktop). For a real cluster:

| Variable                      | Dev default | Production suggestion |
| ----------------------------- | ----------- | --------------------- |
| `prometheus_storage_size`     | `20Gi`      | `100–500Gi`           |
| `prometheus_retention`        | `15d`       | `30d`                 |
| `loki_storage_size`           | `20Gi`      | `200Gi+` (or S3)      |
| `loki_retention`              | `168h` (7d) | `720h+` (30d)         |
| `grafana_storage_size`        | `5Gi`       | `10Gi`                |
| `alertmanager_storage_size`   | `2Gi`       | `5Gi`                 |

For prod Loki, switch `deploymentMode` to `SimpleScalable` + S3 object storage
via `extra_loki_values`.

## Phased bring-up

This module has a hard dependency on the `kube-prometheus-stack` CRDs (its own
`ServiceMonitor`s for Loki and Alloy reference them). The module installs the
stack first, then Loki, then Alloy to respect that ordering.

If you see errors like *"no matches for kind ServiceMonitor"* on first apply,
re-run `terraform apply` once the CRDs are installed.
