#!/usr/bin/env bash
# build-deploy.sh — build the pe-workflow Go services, apply their k8s manifests,
# and optionally deploy the workflow resources (forms, DMN, BPMN) via c8ctl.
# Default action is --services. Run from anywhere; paths are resolved from the
# repo root (three levels up from this file's directory).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

SERVICES="eligibility verification scheduling documents notifications simulator"
TAG="latest"
PROFILE="kubernetes"
DO_SERVICES=false
DO_RESOURCES=false
HAS_FLAG=false

usage() {
  cat <<'EOF'
Usage: build-deploy.sh [--services] [--resources] [--tag <tag>] [--profile <name>]

  --services          Build images, kubectl apply manifests, rollout status (default if no flags)
  --resources         Deploy workflow resources (forms, DMN, shared, delegates, orchestrator) via c8ctl
  --tag <tag>         Image tag to build (default: latest)
  --profile <name>    c8ctl profile to use (default: kubernetes)
  -h, --help          Show this help

Examples:
  build-deploy.sh                 build + deploy services only
  build-deploy.sh --resources     deploy workflow resources only
  build-deploy.sh --services --resources   build + deploy services AND resources
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --services) DO_SERVICES=true; HAS_FLAG=true ;;
    --resources) DO_RESOURCES=true; HAS_FLAG=true ;;
    --tag) TAG="$2"; shift ;;
    --profile) PROFILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if ! $HAS_FLAG; then
  DO_SERVICES=true
fi

# ---------------------------------------------------------------------------
# Temporary port-forwards for c8ctl resource deployment.
# The kubernetes profile fetches an OAuth token from Keycloak on
# localhost:18080 and calls the REST API on the Zeebe gateway at
# localhost:8080, so both must be reachable. If a forward is already running
# we reuse it; otherwise we start one and tear it down on exit.
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-camunda}"
RELEASE_NAME="${RELEASE_NAME:-camunda}"
ZEEBE_PORT="${ZEEBE_PORT:-8080}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18080}"
PF_PIDS=()
PF_STARTED=false

# ensure_forward <resource> <local:remote> <readiness-url> <label>
ensure_forward() {
  local resource="$1" mapping="$2" url="$3" label="$4"
  local port="${mapping%%:*}"
  if curl -s -o /dev/null --max-time 2 "$url" 2>/dev/null; then
    echo "Using existing $label port-forward on localhost:${port}."
    return 0
  fi
  echo "Starting temporary $label port-forward on localhost:${port}..."
  kubectl port-forward "$resource" -n "$NAMESPACE" "$mapping" >/dev/null 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")
  PF_STARTED=true
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: temporary $label port-forward exited unexpectedly." >&2
      return 1
    fi
    if curl -s -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      echo "Temporary $label port-forward is ready."
      return 0
    fi
    sleep 1
  done
  echo "ERROR: temporary $label port-forward did not become ready." >&2
  return 1
}

cleanup_forwards() {
  if $PF_STARTED; then
    for pid in "${PF_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    PF_STARTED=false
  fi
}

# On a fresh deployment Zeebe crash-loops until Management Identity has created
# the Keycloak realm, so give it a chance to become Ready before forwarding.
wait_for_zeebe() {
  echo "Waiting for Zeebe gateway (statefulset/${RELEASE_NAME}-zeebe) to be Ready..."
  if kubectl rollout status "statefulset/${RELEASE_NAME}-zeebe" -n "$NAMESPACE" --timeout=300s >/dev/null 2>&1; then
    echo "Zeebe gateway is Ready."
  else
    echo "WARNING: Zeebe gateway not Ready yet; attempting port-forward anyway."
  fi
}

if $DO_SERVICES; then
  for svc in $SERVICES; do
    docker build --build-arg SERVICE="$svc" -t "pe-workflow/$svc:$TAG" -f "$ROOT/scripts/deploy/services/Dockerfile" "$ROOT"
  done

  kubectl apply -f "$ROOT/scripts/deploy/services/manifests.yaml"

  # Images are tagged :latest and manifests are unchanged across rebuilds, so a
  # plain apply does not restart existing pods. Force a rollout so the freshly
  # built image is picked up, skipping deployments scaled to 0 replicas.
  for svc in $SERVICES; do
    replicas=$(kubectl get deployment pe-$svc -n camunda -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    if [[ "$replicas" -gt 0 ]]; then
      kubectl rollout restart deployment/pe-$svc -n camunda
    fi
    kubectl rollout status deployment/pe-$svc -n camunda --timeout=180s
  done
fi

if $DO_RESOURCES; then
  trap cleanup_forwards EXIT INT TERM
  wait_for_zeebe
  ensure_forward "svc/${RELEASE_NAME}-zeebe-gateway" "${ZEEBE_PORT}:8080" \
    "http://localhost:${ZEEBE_PORT}/v2/topology" "Zeebe gateway"
  ensure_forward "svc/keycloak-service" "${KEYCLOAK_PORT}:18080" \
    "http://localhost:${KEYCLOAK_PORT}/auth/realms/master" "Keycloak"
  c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/shared/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/delegates/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile="$PROFILE"
  cleanup_forwards
  trap - EXIT INT TERM
fi
