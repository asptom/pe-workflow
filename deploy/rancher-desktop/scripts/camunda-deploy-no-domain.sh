#!/bin/bash
set -euo pipefail

# ============================================================
# One-script Camunda Platform deployment on Rancher Desktop k3s
# No-domain / port-forward mode
#
# Deploys the full stack from scratch:
#   1. Creates namespace
#   2. Elasticsearch  (ECK operator + cluster)
#   3. PostgreSQL     (CloudNativePG operator + clusters + secrets)
#   4. Keycloak       (Keycloak operator CRDs + operator + instance)
#   5. Identity secrets (camunda-credentials)
#   6. Camunda Platform (via Helm)
#   7. c8ctl profile configuration (Keycloak OIDC client + c8ctl profile)
#
# This script is self-contained: all referenced manifests and values
# files live under rancher-desktop/manifests/ and rancher-desktop/helm-values/.
#
# Prerequisites:
#   - kubectl connected to your k3s cluster
#   - helm installed
#   - envsubst installed (from gettext)
#   - yq installed (for filtered PG cluster deployment)
#   - c8ctl installed (npm install -g @camunda8/cli) — for Step 7
#
# Environment variables (all optional):
#   CAMUNDA_NAMESPACE          - Namespace (default: camunda)
#   CAMUNDA_HELM_CHART_VERSION - Chart version (default: 14.6.1)
#   CAMUNDA_RELEASE_NAME       - Helm release name (default: camunda)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$RANCHER_DIR/manifests"

# ---- Source environment (if available) ----
ENV_FILE=""
if [ -f "$RANCHER_DIR/../env_exports.sh" ]; then
  ENV_FILE="$RANCHER_DIR/../env_exports.sh"
elif [ -f "$SCRIPT_DIR/env_exports.sh" ]; then
  ENV_FILE="$SCRIPT_DIR/env_exports.sh"
fi
if [ -n "$ENV_FILE" ]; then
  echo "Sourcing $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# ---- Defaults ----
CAMUNDA_NAMESPACE="${CAMUNDA_NAMESPACE:-camunda}"
CAMUNDA_HELM_CHART_VERSION="${CAMUNDA_HELM_CHART_VERSION:-14.6.1}"
CAMUNDA_RELEASE_NAME="${CAMUNDA_RELEASE_NAME:-camunda}"

echo "=============================================="
echo " Camunda Platform Full Deployment (No-Domain)"
echo "=============================================="
echo "Namespace:     $CAMUNDA_NAMESPACE"
echo "Chart version: $CAMUNDA_HELM_CHART_VERSION"
echo "Release name:  $CAMUNDA_RELEASE_NAME"
echo ""

# ---- Pre-flight checks ----
for cmd in kubectl helm envsubst yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Please install it first."
    exit 1
  fi
done

# ============================================================
# Step 1: Create namespace
# ============================================================
echo ""
echo "=== Step 1/7: Creating namespace '$CAMUNDA_NAMESPACE' ==="
kubectl create namespace "$CAMUNDA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ============================================================
# Step 2: Elasticsearch via ECK operator
# ============================================================
echo ""
echo "=== Step 2/7: Elasticsearch (ECK operator) ==="
ES_NAMESPACE="${ES_NAMESPACE:-elastic-system}"
ES_CLUSTER_FILE="${ES_CLUSTER_FILE:-$MANIFESTS_DIR/elasticsearch/elasticsearch-cluster.yml}"

ECK_VERSION="3.4.1"

# Install ECK operator CRDs
kubectl apply --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/crds.yaml"

# Create operator namespace
kubectl create namespace "$ES_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install ECK operator
kubectl apply -n "$ES_NAMESPACE" --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/operator.yaml"
echo "Waiting for ECK operator..."
kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s \
  statefulset/elastic-operator -n "$ES_NAMESPACE"

# Deploy Elasticsearch cluster
kubectl apply -f "$ES_CLUSTER_FILE" -n "$CAMUNDA_NAMESPACE"
echo "Waiting for Elasticsearch cluster..."
kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=600s \
  elasticsearch --all -n "$CAMUNDA_NAMESPACE"
echo "Elasticsearch is ready"

# ============================================================
# Step 3: PostgreSQL via CloudNativePG operator
# ============================================================
echo ""
echo "=== Step 3/7: PostgreSQL (CloudNativePG operator) ==="
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
CNPG_VERSION="1.30.0"

CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"

# Install operator
kubectl apply -n "$CNPG_NAMESPACE" --server-side -f "$CNPG_MANIFEST_URL"
echo "Waiting for CloudNativePG operator..."
kubectl rollout status deployment -n "$CNPG_NAMESPACE" cnpg-controller-manager --timeout=300s

# Create PG secrets (only the clusters we need for ES mode)
echo "Creating PostgreSQL secrets..."
CLUSTER_FILTER="pg-keycloak,pg-identity,pg-webmodeler" \
  CAMUNDA_NAMESPACE="$CAMUNDA_NAMESPACE" \
  "$MANIFESTS_DIR/postgresql/set-secrets.sh"

# Deploy PG clusters (filtered to ES-required ones)
echo "Deploying PostgreSQL clusters..."
CLUSTER_FILTER="pg-keycloak,pg-identity,pg-webmodeler"
IFS=',' read -ra CLUSTERS <<< "$CLUSTER_FILTER"
for cluster in "${CLUSTERS[@]}"; do
  yq "select(.metadata.name == \"$cluster\")" "$MANIFESTS_DIR/postgresql/postgresql-clusters.yml" | \
    kubectl apply -n "$CAMUNDA_NAMESPACE" --server-side -f -
done
for cluster in "${CLUSTERS[@]}"; do
  echo "Waiting for PG cluster $cluster..."
  kubectl wait --for=condition=Ready --timeout=600s cluster "$cluster" -n "$CAMUNDA_NAMESPACE"
done
echo "PostgreSQL clusters are ready"

# ============================================================
# Step 4: Keycloak via Keycloak operator
# ============================================================
echo ""
echo "=== Step 4/7: Keycloak (Keycloak operator) ==="
KEYCLOAK_VERSION="26.3.2"

# Install Keycloak operator CRDs
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml"
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml"

# Install Keycloak operator (in camunda namespace since it manages resources there)
kubectl apply -n "$CAMUNDA_NAMESPACE" --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/kubernetes.yml"
echo "Waiting for Keycloak operator..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/keycloak-operator -n "$CAMUNDA_NAMESPACE"

# Deploy Keycloak instance (no-domain mode)
echo "Deploying Keycloak instance (no-domain)..."
KEYCLOAK_CONFIG="$MANIFESTS_DIR/keycloak/keycloak-instance-no-domain.yml"
if [ -f "$KEYCLOAK_CONFIG" ]; then
  # No envsubst needed for no-domain config (hostname is hardcoded to keycloak-service)
  kubectl apply -f "$KEYCLOAK_CONFIG" -n "$CAMUNDA_NAMESPACE"
else
  echo "ERROR: $KEYCLOAK_CONFIG not found"
  exit 1
fi

echo "Waiting for Keycloak instance to be ready..."
kubectl wait --for=condition=Ready --timeout=600s \
  keycloak/keycloak -n "$CAMUNDA_NAMESPACE"
echo "Keycloak is ready"

# ============================================================
# Step 5: Create identity secrets
# ============================================================
echo ""
echo "=== Step 5/7: Creating identity secrets ==="
if kubectl get secret camunda-credentials -n "$CAMUNDA_NAMESPACE" &>/dev/null; then
  echo "Secret camunda-credentials already exists — reusing"
else
  echo "Generating camunda-credentials..."
  CONNECTORS_SECRET="$(openssl rand -hex 16)"
  CONSOLE_SECRET="$(openssl rand -hex 16)"
  WEB_MODELER_SECRET="$(openssl rand -hex 16)"
  ORCHESTRATION_SECRET="$(openssl rand -hex 16)"
  OPTIMIZE_SECRET="$(openssl rand -hex 16)"
  ADMIN_SECRET="$(openssl rand -hex 16)"
  FIRST_USER_PASSWORD="$(openssl rand -hex 16)"
  PUSHER_APP_SECRET="$(openssl rand -hex 16)"
  PUSHER_APP_KEY="$(openssl rand -hex 16)"

  kubectl create secret generic camunda-credentials \
    --namespace "$CAMUNDA_NAMESPACE" \
    --from-literal=identity-connectors-client-token="$CONNECTORS_SECRET" \
    --from-literal=identity-console-client-token="$CONSOLE_SECRET" \
    --from-literal=identity-webmodeler-client-token="$WEB_MODELER_SECRET" \
    --from-literal=identity-orchestration-client-token="$ORCHESTRATION_SECRET" \
    --from-literal=identity-optimize-client-token="$OPTIMIZE_SECRET" \
    --from-literal=identity-admin-client-token="$ADMIN_SECRET" \
    --from-literal=identity-first-user-password="$FIRST_USER_PASSWORD" \
    --from-literal=webmodeler-pusher-app-secret="$PUSHER_APP_SECRET" \
    --from-literal=webmodeler-pusher-app-key="$PUSHER_APP_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "camunda-credentials secret created"
fi

# ============================================================
# Step 6: Deploy Camunda via Helm
# ============================================================
echo ""
echo "=== Step 6/7: Installing Camunda Platform (Helm) ==="

helm upgrade --install "$CAMUNDA_RELEASE_NAME" camunda-platform \
  --repo https://helm.camunda.io \
  --version "$CAMUNDA_HELM_CHART_VERSION" \
  --namespace "$CAMUNDA_NAMESPACE" \
  --values "$MANIFESTS_DIR/elasticsearch/camunda-elastic-values.yml" \
  --values "$MANIFESTS_DIR/keycloak/camunda-keycloak-no-domain-values.yml" \
  --values "$MANIFESTS_DIR/postgresql/camunda-identity-values.yml" \
  --values "$MANIFESTS_DIR/postgresql/camunda-webmodeler-values.yml" \
  --values "$RANCHER_DIR/helm-values/values-no-domain.yml"

echo "Camunda Platform Helm release installed."

# ============================================================
# Step 7: Configure c8ctl for this deployment
# ============================================================
echo ""
echo "=== Step 7/7: Configuring c8ctl ==="

# Check if c8ctl is installed
if ! command -v c8ctl &>/dev/null; then
  echo "WARNING: c8ctl is not installed. Skipping c8ctl configuration."
  echo "         Install it with: npm install -g @camunda8/cli"
  echo "         Then run: $SCRIPT_DIR/configure-c8ctl.sh"
  echo ""
else
  # Run the c8ctl configuration script
  "$SCRIPT_DIR/configure-c8ctl.sh" \
    --namespace "$CAMUNDA_NAMESPACE" \
    --release-name "$CAMUNDA_RELEASE_NAME"
fi

echo ""
echo "=============================================="
echo " Deployment complete!"
echo "=============================================="
echo ""
echo "Monitor pods: kubectl get pods -n $CAMUNDA_NAMESPACE -w"
echo ""
echo "=== Port-forwarding (run in separate terminals) ==="
echo ""
echo "  Keycloak: (required for other services to work)"
echo "    kubectl port-forward svc/keycloak-service -n $CAMUNDA_NAMESPACE 18080:18080"
echo "  Operate/Tasklist/Identity/ZeebeREST:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-zeebe-gateway -n $CAMUNDA_NAMESPACE 8080:8080"
echo "  Optimize:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-optimize -n $CAMUNDA_NAMESPACE 8083:80"
echo "  Web Modeler REST API:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-web-modeler-restapi -n $CAMUNDA_NAMESPACE 8070:80"
echo "  Web Modeler WebSockets:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-web-modeler-websockets -n $CAMUNDA_NAMESPACE 8085:80"
echo "  Console:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-console -n $CAMUNDA_NAMESPACE 8087:80"
echo "  Connectors:"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-connectors -n $CAMUNDA_NAMESPACE 8086:8080"

echo "  Zeebe gRPC (e.g. zbctl):"
echo "    kubectl port-forward svc/$CAMUNDA_RELEASE_NAME-zeebe-gateway -n $CAMUNDA_NAMESPACE 26500:26500"
echo ""
echo "=== Access URLs (with all port-forwards running) ==="
echo "  Identity:   http://localhost:8080/identity"
echo "  Operate:    http://localhost:8080/operate"
echo "  Tasklist:   http://localhost:8080/tasklist"
echo "  Optimize:   http://localhost:8083"
echo "  Console:    http://localhost:8087"
echo "  Web Modeler: http://localhost:8070"
echo "  Connectors: http://localhost:8086"
echo "  Keycloak:   http://localhost:18080/auth"
echo "  Zeebe gRPC: localhost:26500"
echo ""
echo "To get credentials for admin, run: "
echo "  kubectl get secret camunda-credentials -n camunda \\"
echo "    -o jsonpath='{.data.identity-first-user-password}' | base64 -d"
echo ""
echo "=== c8ctl usage ==="
echo "  c8ctl get topology --profile=rancher-desktop"
echo "  c8ctl list pd --profile=rancher-desktop"
echo "  c8ctl list pi --profile=rancher-desktop"
echo "  c8ctl deploy ./my-process.bpmn --profile=rancher-desktop"
echo ""
echo "  (Requires port-forwards for Keycloak:18080 and Zeebe gateway:8080 to be running)"
