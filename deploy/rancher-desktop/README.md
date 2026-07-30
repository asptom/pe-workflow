# Camunda 8 on Rancher Desktop (k3s) — No-Domain Deployment

Self-contained reference for deploying Camunda 8 Self-Managed to Rancher Desktop's
local k3s Kubernetes cluster using port-forwarding (no ingress, no domain).

This folder is **fully self-contained** — all manifests and Helm values needed for
deployment are included under `manifests/` and `helm-values/`. You can copy this
entire `rancher-desktop/` directory to any project and it will work standalone.

## Prerequisites

- **Rancher Desktop** with k3s running and `kubectl` configured
- **helm** (v3+)
- **envsubst** (from `gettext`)
- **yq** (for filtered PostgreSQL cluster deployment)
- **openssl** (for secret generation)
- **c8ctl** (`npm install -g @camunda8/cli`) — optional, for Step 7

## Quick Start

```bash
# 1. Deploy everything (operators + Camunda + c8ctl config)
./procedure/camunda-deploy-no-domain.sh

# 2. Start port-forwards in a separate terminal
./procedure/camunda-port-forwards.sh

# 3. Use c8ctl (with port-forwards running)
c8ctl get topology --profile=rancher-desktop
c8ctl list pd --profile=rancher-desktop
```

## What Gets Deployed

| Step | Component | Operator |
|------|-----------|----------|
| 1 | Namespace `camunda` | — |
| 2 | Elasticsearch cluster | ECK (Elastic Cloud on Kubernetes) |
| 3 | PostgreSQL clusters (Keycloak, Identity, WebModeler) | CloudNativePG |
| 4 | Keycloak instance | Keycloak Operator |
| 5 | Identity secrets (`camunda-credentials`) | — |
| 6 | Camunda Platform (Zeebe, Operate, Tasklist, Optimize, Console, Web Modeler, Connectors) | Helm chart `camunda-platform` |
| 7 | OIDC client + c8ctl profile | Keycloak Admin API + c8ctl |

## Directory Structure

```
rancher-desktop/
├── README.md                          # This file
├── helm-values/
│   └── values-no-domain.yml           # Camunda Helm values (no-domain/port-forward mode)
├── manifests/                         # Copied from generic/kubernetes/operator-based/
│   ├── elasticsearch/
│   │   ├── elasticsearch-cluster.yml         # ES cluster CR
│   │   └── camunda-elastic-values.yml         # ES Helm values for Camunda
│   ├── postgresql/
│   │   ├── postgresql-clusters.yml           # CNPG cluster CRs
│   │   ├── set-secrets.sh                    # PG secret creation script
│   │   ├── camunda-identity-values.yml       # Identity DB Helm values
│   │   └── camunda-webmodeler-values.yml     # WebModeler DB Helm values
│   └── keycloak/
│       ├── keycloak-instance-no-domain.yml   # Keycloak CR
│       └── camunda-keycloak-no-domain-values.yml  # Keycloak Helm values
└── procedure/
    ├── camunda-deploy-no-domain.sh   # Main deployment script (Steps 1-7)
    ├── configure-c8ctl.sh            # c8ctl profile setup (Step 7)
    ├── camunda-port-forwards.sh      # Port-forwarding helper
    └── camunda-uninstall.sh          # Full cleanup script
```

## Environment Variables

All variables are optional with sensible defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `CAMUNDA_NAMESPACE` | `camunda` | Kubernetes namespace |
| `CAMUNDA_HELM_CHART_VERSION` | `14.6.1` | Camunda Platform Helm chart version |
| `CAMUNDA_RELEASE_NAME` | `camunda` | Helm release name |

## c8ctl Configuration

Step 7 of the deployment script automatically configures c8ctl:

1. **Creates an OIDC client** (`zeebe-cli`) in the Keycloak realm `camunda-platform`
   with service accounts enabled, `fullScopeAllowed`, and an `orchestration`
   audience mapper for Zeebe gateway authentication.
2. **Sets the client secret** via the Keycloak Admin API (Keycloak 26.x generates
   a random secret — the script reads it from the API response).
3. **Stores credentials** in a Kubernetes secret `c8ctl-credentials` in the `camunda` namespace.
4. **Creates a c8ctl profile** named `rancher-desktop` pointing at `http://localhost:8080/v2`
   with the Keycloak OAuth token endpoint and `orchestration` audience.

### Using c8ctl

After deployment, start the port-forwards and use c8ctl:

```bash
# Required port-forwards (run in separate terminals or via the helper script)
kubectl port-forward svc/keycloak-service -n camunda 18080:18080
kubectl port-forward svc/camunda-zeebe-gateway -n camunda 8080:8080

# c8ctl commands
c8ctl get topology --profile=rancher-desktop
c8ctl list pd --profile=rancher-desktop
c8ctl list pi --profile=rancher-desktop
c8ctl deploy ./my-process.bpmn --profile=rancher-desktop
c8ctl run ./order.bpmn --profile=rancher-desktop --variables='{"orderId":"42"}'
c8ctl watch --profile=rancher-desktop
```

### Manual c8ctl Reconfiguration

If you need to reconfigure c8ctl outside the deployment script:

```bash
./procedure/configure-c8ctl.sh --namespace camunda --release-name camunda
```

### Retrieving c8ctl Credentials

```bash
# Get the client ID
kubectl get secret c8ctl-credentials -n camunda -o jsonpath='{.data.client-id}' | base64 -d

# Get the client secret
kubectl get secret c8ctl-credentials -n camunda -o jsonpath='{.data.client-secret}' | base64 -d
```

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
./procedure/camunda-uninstall.sh
```

This removes the `camunda`, `elastic-system`, and `cnpg-system` namespaces.
