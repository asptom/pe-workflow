#!/usr/bin/env bash
# ============================================================
# scripts/deploy.sh — single entry point for deploying the full pe-workflow
# stack onto a local Rancher Desktop k3s cluster.
#
# Long-lived port-forwards are NOT managed here. Steps that need a forward
# during deployment (c8ctl configuration, resource deployment) obtain a
# temporary one themselves and tear it down on exit. Start long-lived
# forwards separately with:
#   ./scripts/deploy/camunda/scripts/camunda-port-forwards.sh
#
# Usage:
#   ./scripts/deploy.sh --all          # everything (default)
#   ./scripts/deploy.sh --platform     # Camunda platform only
#   ./scripts/deploy.sh --configure    # c8ctl profile/authorizations only
#   ./scripts/deploy.sh --services     # build + deploy Go workers only
#   ./scripts/deploy.sh --resources    # deploy workflow artifacts only
#   ./scripts/deploy.sh --webapp       # build + deploy Angular SPA/BFF only
#
# Flags may be combined, e.g. --platform --services.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-camunda}"
RELEASE_NAME="${RELEASE_NAME:-camunda}"
SCRIPTS_DIR="$ROOT/scripts/deploy/camunda/scripts"
SERVICES_DIR="$ROOT/scripts/deploy/services"

DO_PLATFORM=false
DO_CONFIGURE=false
DO_SERVICES=false
DO_RESOURCES=false
DO_WEBAPP=false
HAS_FLAG=false

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy.sh [--all] [--platform] [--configure] [--services] [--resources] [--webapp]

  --all          Deploy everything (default when no flags are given)
  --platform     Deploy the Camunda platform
  --configure    Configure the c8ctl profile and authorizations
  --services     Build and deploy the Go worker services
  --resources    Deploy workflow artifacts (forms, DMN, BPMN)
  --webapp       Build and deploy the Angular SPA + Go BFF
  -h, --help     Show this help

Flags may be combined, e.g. --platform --services.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --platform) DO_PLATFORM=true; HAS_FLAG=true ;;
    --configure) DO_CONFIGURE=true; HAS_FLAG=true ;;
    --services) DO_SERVICES=true; HAS_FLAG=true ;;
    --resources) DO_RESOURCES=true; HAS_FLAG=true ;;
    --webapp) DO_WEBAPP=true; HAS_FLAG=true ;;
    --all)
      DO_PLATFORM=true; DO_CONFIGURE=true; DO_SERVICES=true
      DO_RESOURCES=true; DO_WEBAPP=true; HAS_FLAG=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

if ! $HAS_FLAG; then
  DO_PLATFORM=true; DO_CONFIGURE=true; DO_SERVICES=true
  DO_RESOURCES=true; DO_WEBAPP=true
fi

# ---- Prerequisite checks (only for the selected steps) ----
require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: required tool '$1' not found in PATH." >&2
    exit 1
  fi
}

if $DO_PLATFORM; then for t in kubectl helm envsubst yq openssl; do require "$t"; done; fi
if $DO_CONFIGURE; then for t in kubectl c8ctl curl jq; do require "$t"; done; fi
if $DO_SERVICES; then for t in docker kubectl; do require "$t"; done; fi
if $DO_RESOURCES; then for t in c8ctl curl kubectl; do require "$t"; done; fi
if $DO_WEBAPP; then for t in docker kubectl node npm go; do require "$t"; done; fi

banner() {
  echo ""
  echo "=============================================="
  echo " $1"
  echo "=============================================="
}

step_platform() {
  banner "Deploying Camunda platform (namespace: $NAMESPACE)"
  CAMUNDA_NAMESPACE="$NAMESPACE" CAMUNDA_RELEASE_NAME="$RELEASE_NAME" \
    "$SCRIPTS_DIR/camunda-deploy-no-domain.sh" --skip-c8ctl-config
}

step_configure() {
  banner "Configuring c8ctl"
  "$SCRIPTS_DIR/configure-c8ctl.sh" \
    --namespace "$NAMESPACE" \
    --release-name "$RELEASE_NAME"
}

step_services() {
  banner "Building and deploying worker services"
  "$SERVICES_DIR/build-deploy.sh" --services
}

step_resources() {
  banner "Deploying workflow resources"
  "$SERVICES_DIR/build-deploy.sh" --resources
}

step_webapp() {
  banner "Building and deploying webapp (Angular SPA + Go BFF)"
  (cd "$ROOT/web" && npm ci && npm run build)
  docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest \
    -f "$SERVICES_DIR/Dockerfile" "$ROOT"
  kubectl apply -f "$SERVICES_DIR/manifests.yaml"
  kubectl rollout restart deployment/pe-webapp -n "$NAMESPACE"
  kubectl rollout status deployment/pe-webapp -n "$NAMESPACE" --timeout=180s
}

banner "pe-workflow deployment"
echo "Namespace: $NAMESPACE"
echo "Release:   $RELEASE_NAME"
echo "Steps:     platform=$DO_PLATFORM configure=$DO_CONFIGURE services=$DO_SERVICES resources=$DO_RESOURCES webapp=$DO_WEBAPP"

if $DO_PLATFORM; then step_platform; fi
if $DO_CONFIGURE; then step_configure; fi
if $DO_SERVICES; then step_services; fi
if $DO_RESOURCES; then step_resources; fi
if $DO_WEBAPP; then step_webapp; fi

banner "Deployment complete"
echo "Start long-lived port-forwards for interactive use:"
echo "  ./scripts/deploy/camunda/scripts/camunda-port-forwards.sh"

banner "Access URLs"
echo "  Identity:   http://localhost:8080/identity"
echo "  Operate:    http://localhost:8080/operate"
echo "  Tasklist:   http://localhost:8080/tasklist"
echo "  Optimize:   http://localhost:8083"
echo "  Console:    http://localhost:8087"
echo "  Web Modeler: http://localhost:8070"
echo "  Connectors: http://localhost:8086"
echo "  Keycloak:   http://localhost:18080/auth"
echo "  Zeebe gRPC: localhost:26500"
echo "  PE WebApp: localhost:8088"
echo ""
echo "To get credentials for admin, run: "
echo "  kubectl get secret camunda-credentials -n $NAMESPACE \\"
echo "    -o jsonpath='{.data.identity-first-user-password}' | base64 -d"
echo ""
