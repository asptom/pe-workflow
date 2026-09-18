# Camunda 8 on Rancher Desktop (k3s) — No-Domain Deployment

Self-contained reference for deploying Camunda 8 Self-Managed to Rancher Desktop's local
k3s cluster using port-forwarding (no ingress, no domain).

> **Deployment instructions live in the root [`DEPLOYMENT.md`](../../DEPLOYMENT.md).**
> This directory is also a reusable template: all manifests and Helm values needed for the
> deployment are included under `manifests/` and `helm-values/`, so you can copy the whole
> `rancher-desktop/` directory to another project and run the scripts standalone.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/camunda-deploy-no-domain.sh` | Full platform deployment (Steps 1–7) |
| `scripts/configure-c8ctl.sh` | c8ctl profile + Zeebe authorizations (Step 7) |
| `scripts/camunda-port-forwards.sh` | Starts all long-lived port-forwards |
| `scripts/camunda-uninstall.sh` | Tear down (`--full` also removes operator CRDs) |

Run the platform script with `--check-versions` to print pinned component versions, or
`--skip-c8ctl-config` to defer c8ctl configuration.

## What Gets Deployed

| Step | Component | Operator |
|------|-----------|----------|
| 1 | Namespace `camunda` | — |
| 2 | Elasticsearch cluster | ECK (Elastic Cloud on Kubernetes) |
| 3 | PostgreSQL clusters (Keycloak, Identity, WebModeler) | CloudNativePG |
| 4 | Keycloak instance | Keycloak Operator |
| 5 | Identity secrets (`camunda-credentials`) | — |
| 6 | Camunda Platform (Zeebe, Operate, Tasklist, Optimize, Console, Web Modeler, Connectors) | Helm chart `camunda-platform` |
| 7 | OIDC client + c8ctl profile + Zeebe authorizations | Keycloak Admin API + c8ctl |

## Directory Structure

```
rancher-desktop/
├── README.md                          # This file
├── helm-values/
│   └── values-no-domain.yml           # Camunda Helm values (no-domain/port-forward mode)
├── manifests/                         # Copied from upstream generic/kubernetes/operator-based/ template
│   ├── elasticsearch/
│   │   ├── elasticsearch-cluster.yml          # ES cluster CR
│   │   └── camunda-elastic-values.yml          # ES Helm values for Camunda
│   ├── postgresql/
│   │   ├── postgresql-clusters.yml            # CNPG cluster CRs
│   │   ├── set-secrets.sh                     # PG secret creation script
│   │   ├── camunda-identity-values.yml        # Identity DB Helm values
│   │   └── camunda-webmodeler-values.yml      # WebModeler DB Helm values
│   └── keycloak/
│       ├── keycloak-instance-no-domain.yml    # Keycloak CR
│       └── camunda-keycloak-no-domain-values.yml  # Keycloak Helm values
└── scripts/
    ├── camunda-deploy-no-domain.sh   # Main deployment script (Steps 1-7)
    ├── configure-c8ctl.sh            # c8ctl profile + Zeebe authorizations (Step 7)
    ├── camunda-port-forwards.sh      # Port-forwarding helper
    └── camunda-uninstall.sh          # Cleanup script
```

## Environment Variables

All variables are optional with sensible defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `CAMUNDA_NAMESPACE` | `camunda` | Kubernetes namespace |
| `CAMUNDA_HELM_CHART_VERSION` | `14.6.1` | Camunda Platform Helm chart version |
| `CAMUNDA_RELEASE_NAME` | `camunda` | Helm release name |
| `ECK_VERSION` | `3.4.1` | ECK operator version |
| `CNPG_VERSION` | `1.30.0` | CloudNativePG operator version |
| `KEYCLOAK_VERSION` | `26.3.2` | Keycloak operator version |

## Access URLs (with port-forwards running)

| Service | URL | Port-forward |
|---------|-----|--------------|
| Keycloak | http://localhost:18080/auth | `svc/keycloak-service 18080:18080` |
| Operate | http://localhost:8080/operate | `svc/camunda-zeebe-gateway 8080:8080` |
| Tasklist | http://localhost:8080/tasklist | (same as Zeebe gateway) |
| Identity | http://localhost:8080/identity | (same as Zeebe gateway) |
| Console | http://localhost:8087 | `svc/camunda-console 8087:80` |
| Optimize | http://localhost:8083 | `svc/camunda-optimize 8083:80` |
| Web Modeler | http://localhost:8070 | `svc/camunda-web-modeler-restapi 8070:80` |
| Connectors | http://localhost:8086 | `svc/camunda-connectors 8086:8080` |
| pe-webapp | http://localhost:8088 | `svc/pe-webapp 8088:8080` |
| pe-simulator | http://localhost:8186 | `svc/pe-simulator 8186:8086` |
| Zeebe gRPC | localhost:26500 | `svc/camunda-zeebe-gateway 26500:26500` |

## Admin Credentials

```bash
# Camunda admin password
kubectl get secret camunda-credentials -n camunda \
  -o jsonpath='{.data.identity-first-user-password}' | base64 -d

# Keycloak admin credentials
kubectl get secret keycloak-initial-admin -n camunda \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get secret keycloak-initial-admin -n camunda \
  -o jsonpath='{.data.password}' | base64 -d
```

## Cleanup

```bash
./scripts/camunda-uninstall.sh          # uninstall Helm release + delete namespaces
./scripts/camunda-uninstall.sh --full   # also delete operator CRDs
```

See the root [`DEPLOYMENT.md`](../../DEPLOYMENT.md) for full details.
