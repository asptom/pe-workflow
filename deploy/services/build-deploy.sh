#!/usr/bin/env bash
# build-deploy.sh — build the pe-workflow Go services, apply their k8s manifests,
# and optionally deploy the workflow resources (forms, DMN, BPMN) via c8ctl.
# Default action is --services. Run from anywhere; paths are resolved from the
# repo root (three levels up from this file's directory).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SERVICES="eligibility verification scheduling documents notifications simulator"
TAG="latest"
PROFILE="rancher-desktop"
DO_SERVICES=false
DO_RESOURCES=false
HAS_FLAG=false

usage() {
  cat <<'EOF'
Usage: build-deploy.sh [--services] [--resources] [--tag <tag>] [--profile <name>]

  --services          Build images, kubectl apply manifests, rollout status (default if no flags)
  --resources         Deploy workflow resources (forms, DMN, shared, delegates, orchestrator) via c8ctl
  --tag <tag>         Image tag to build (default: latest)
  --profile <name>    c8ctl profile to use (default: rancher-desktop)
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

if $DO_SERVICES; then
  for svc in $SERVICES; do
    docker build --build-arg SERVICE="$svc" -t "pe-workflow/$svc:$TAG" -f "$ROOT/deploy/services/Dockerfile" "$ROOT"
  done

  kubectl apply -f "$ROOT/deploy/services/manifests.yaml"

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
  c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/shared/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/delegates/ --profile="$PROFILE"
  c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile="$PROFILE"
fi
