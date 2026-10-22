#!/usr/bin/env bash
# ============================================================
# scripts/deploy.sh — single entry point for deploying the pe-workflow
# stack onto a local Rancher Desktop k3s cluster, plus the CI/CD
# build/push/deploy lifecycle actions used by azure-pipelines.yml.
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
#   ./scripts/deploy.sh --services     # build + deploy Go workers locally
#   ./scripts/deploy.sh --resources    # deploy workflow artifacts only
#   ./scripts/deploy.sh --webapp       # build + deploy Angular SPA/BFF only
#
# CI/CD lifecycle actions (require --services; mutually exclusive):
#   ./scripts/deploy.sh --build --services    # docker build the six images
#   ./scripts/deploy.sh --push --services     # docker push the built images
#   ./scripts/deploy.sh --deploy --services   # kubectl apply + rollouts (no docker)
#
# Value flags (each also settable as an environment variable):
#   --registry <url>   REGISTRY     image registry login server (e.g. foo.azurecr.io)
#   --tag <tag>        TAG          image tag (CI passes the immutable Build ID)
#   --namespace <ns>   NAMESPACE    namespace override (default: camunda)
#   --manifest <path>  MANIFEST     services manifest
#                                   (default: scripts/deploy/services/manifests.yaml)
#   --profile <name>   PROFILE      c8ctl profile for --resources (default: kubernetes)
#
# Other environment variables:
#   IMAGE_PREFIX                  image repository prefix (default: pe-workflow)
#   RELEASE_NAME                  Camunda Helm release name (default: camunda)
#   ROLLOUT_TIMEOUT               rollout status timeout (default: 180s)
#   ZEEBE_PORT / KEYCLOAK_PORT    local ends of the temporary port-forwards used
#                                 by --resources (default: 8080 / 18080)
#
# Notes:
#   - Flags may be combined, e.g. --platform --services.
#   - Plain --services (no lifecycle flag) is the local flow: it builds
#     $IMAGE_PREFIX/<svc>:latest images (REGISTRY is ignored), applies the full
#     canonical manifest (including pe-webapp), and rollout-restarts.
#   - --build defaults TAG to latest; --push/--deploy require REGISTRY and TAG.
#     --deploy never runs docker; --build/--push never touch kubectl.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT/scripts/deploy/camunda/scripts"
SERVICES_DIR="$ROOT/scripts/deploy/services"

SERVICES="eligibility verification scheduling documents notifications simulator"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---- Defaults (flag/environment overridable) ----
NAMESPACE_EXPLICIT=false
if [[ -n "${NAMESPACE:-}" ]]; then NAMESPACE_EXPLICIT=true; fi
NAMESPACE="${NAMESPACE:-camunda}"
RELEASE_NAME="${RELEASE_NAME:-camunda}"
IMAGE_PREFIX="${IMAGE_PREFIX:-pe-workflow}"
PROFILE="${PROFILE:-kubernetes}"
REGISTRY="${REGISTRY:-}"
TAG="${TAG:-}"
MANIFEST="${MANIFEST:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy.sh [scope flags] [lifecycle flags] [value flags]

Scope flags (local development):
  --all          Deploy everything (default when no flags are given)
  --platform     Deploy the Camunda platform
  --configure    Configure the c8ctl profile and authorizations
  --services     Build + deploy the Go worker services locally
  --resources    Deploy workflow artifacts (forms, DMN, BPMN)
  --webapp       Build and deploy the Angular SPA + Go BFF

CI/CD lifecycle flags (require --services; mutually exclusive):
  --build        Build the six backend images (no push, no kubectl)
  --push         Push previously built images to REGISTRY (no build, no kubectl)
  --deploy       Apply manifests pointing at $REGISTRY/$IMAGE_PREFIX/<svc>:$TAG
                 and wait for rollouts (no docker)

Value flags (each also available as an environment variable):
  --registry <url>   REGISTRY     image registry login server
  --tag <tag>        TAG          image tag (CI passes the immutable Build ID)
  --namespace <ns>   NAMESPACE    namespace override (default: camunda)
  --manifest <path>  MANIFEST     services manifest
                                  (default: scripts/deploy/services/manifests.yaml)
  --profile <name>   PROFILE      c8ctl profile for --resources (default: kubernetes)

Other environment variables:
  IMAGE_PREFIX       image repository prefix (default: pe-workflow)
  ROLLOUT_TIMEOUT    kubectl rollout status timeout (default: 180s)

Notes:
  - Flags may be combined, e.g. --platform --services.
  - Plain --services (no lifecycle flag) builds $IMAGE_PREFIX/<svc>:latest
    locally (REGISTRY is ignored), applies the full canonical manifest
    (including pe-webapp), and rollout-restarts each deployment.
  - --build defaults TAG to latest; --push/--deploy require REGISTRY and TAG.
  - --deploy never runs docker; --build/--push never touch kubectl.

Examples:
  ./scripts/deploy.sh --all
  ./scripts/deploy.sh --resources
  ./scripts/deploy.sh --build --services
  REGISTRY=acrpeworkflowd211.azurecr.io TAG=27 ./scripts/deploy.sh --push --services
  REGISTRY=acrpeworkflowd211.azurecr.io TAG=27 ./scripts/deploy.sh --deploy --services
EOF
}

# ---- Argument parsing ----
LIFECYCLE=""
RAW_ALL=false
RAW_PLATFORM=false
RAW_CONFIGURE=false
RAW_SERVICES=false
RAW_RESOURCES=false
RAW_WEBAPP=false
HAS_FLAG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) RAW_ALL=true; HAS_FLAG=true ;;
    --platform) RAW_PLATFORM=true; HAS_FLAG=true ;;
    --configure) RAW_CONFIGURE=true; HAS_FLAG=true ;;
    --services) RAW_SERVICES=true; HAS_FLAG=true ;;
    --resources) RAW_RESOURCES=true; HAS_FLAG=true ;;
    --webapp) RAW_WEBAPP=true; HAS_FLAG=true ;;
    --build|--push|--deploy)
      if [[ -n "$LIFECYCLE" ]]; then
        echo "ERROR: only one of --build, --push, --deploy may be given (got '--$LIFECYCLE' and '$1')." >&2
        usage >&2
        exit 1
      fi
      LIFECYCLE="${1#--}"
      HAS_FLAG=true ;;
    --registry|--tag|--namespace|--manifest|--profile)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 1
      fi
      case "$1" in
        --registry)  REGISTRY="$2" ;;
        --tag)       TAG="$2" ;;
        --namespace) NAMESPACE="$2"; NAMESPACE_EXPLICIT=true ;;
        --manifest)  MANIFEST="$2" ;;
        --profile)   PROFILE="$2" ;;
      esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# ---- Validate the flag combination ----
if [[ -n "$LIFECYCLE" ]]; then
  if $RAW_ALL || $RAW_PLATFORM || $RAW_CONFIGURE || $RAW_RESOURCES || $RAW_WEBAPP; then
    echo "ERROR: --$LIFECYCLE applies only to the backend services scope." >&2
    echo "       Combine it with --services, not with --all/--platform/--configure/--resources/--webapp." >&2
    exit 1
  fi
  if ! $RAW_SERVICES; then
    echo "ERROR: --$LIFECYCLE requires --services (e.g. ./scripts/deploy.sh --$LIFECYCLE --services)." >&2
    exit 1
  fi
  if [[ "$LIFECYCLE" != "build" ]]; then
    [[ -n "$REGISTRY" ]] || { echo "ERROR: --$LIFECYCLE requires REGISTRY (env or --registry <url>)." >&2; exit 1; }
    [[ -n "$TAG" ]] || { echo "ERROR: --$LIFECYCLE requires TAG (env or --tag <tag>)." >&2; exit 1; }
  fi
fi

# Normalize REGISTRY: strip a leading scheme and any trailing slash.
if [[ -n "$REGISTRY" ]]; then
  normalized="$REGISTRY"
  normalized="${normalized#http://}"
  normalized="${normalized#https://}"
  normalized="${normalized%/}"
  [[ -n "$normalized" ]] || die "REGISTRY '$REGISTRY' normalizes to an empty registry (scheme/slash only)."
  REGISTRY="$normalized"
fi

DO_PLATFORM=$RAW_PLATFORM
DO_CONFIGURE=$RAW_CONFIGURE
DO_SERVICES=$RAW_SERVICES
DO_RESOURCES=$RAW_RESOURCES
DO_WEBAPP=$RAW_WEBAPP
if ! $HAS_FLAG; then
  DO_PLATFORM=true; DO_CONFIGURE=true; DO_SERVICES=true
  DO_RESOURCES=true; DO_WEBAPP=true
fi

# A relative MANIFEST from the caller's cwd is made absolute before we cd.
if [[ -n "$MANIFEST" && "$MANIFEST" != /* ]]; then
  MANIFEST="$PWD/$MANIFEST"
fi
cd "$ROOT"
MANIFEST="${MANIFEST:-$SERVICES_DIR/manifests.yaml}"

# ---- Prerequisite checks (only for the selected steps) ----
require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: required tool '$1' not found in PATH." >&2
    exit 1
  fi
}

if [[ "$LIFECYCLE" == "build" || "$LIFECYCLE" == "push" ]]; then require docker; fi
if [[ "$LIFECYCLE" == "deploy" ]]; then require kubectl; fi
if [[ -z "$LIFECYCLE" ]] && $DO_SERVICES; then for t in docker kubectl; do require "$t"; done; fi
if $DO_PLATFORM; then for t in kubectl helm envsubst yq openssl; do require "$t"; done; fi
if $DO_CONFIGURE; then for t in kubectl c8ctl curl jq; do require "$t"; done; fi
if $DO_RESOURCES; then for t in c8ctl curl kubectl; do require "$t"; done; fi
if $DO_WEBAPP; then for t in docker kubectl node npm go; do require "$t"; done; fi

banner() {
  echo ""
  echo "=============================================="
  echo " $1"
  echo "=============================================="
}

# ---------------------------------------------------------------------------
# Manifest transform for --deploy --services. Pure functions (no cluster and
# no docker access) between the >>>/<<< markers so they can be exercised
# standalone without a cluster.
# ---------------------------------------------------------------------------
# >>> manifest-transform

backend_service_regex() {
  # Build "pe-(eligibility|verification|...)" from the SERVICES list so the
  # roster is defined exactly once in this script.
  local alt="" svc
  for svc in $SERVICES; do
    alt="${alt:+$alt|}${svc}"
  done
  printf 'pe-(%s)\n' "$alt"
}

filter_service_docs() {
  # $1 = source manifest, $2 = destination. Emit only the multi-doc YAML
  # documents whose text matches the backend service regex; documents are
  # preserved verbatim, each emitted document prefixed with "---".
  awk -v svc_re="$(backend_service_regex)" '
    function flush_doc() {
      if (buf != "" && hit) { print "---"; printf "%s", buf }
      buf = ""; hit = 0
    }
    /^---[[:space:]]*$/ { flush_doc(); next }
    { buf = buf $0 "\n"; if ($0 ~ svc_re) hit = 1 }
    END { flush_doc() }
  ' "$1" > "$2"
}

rewrite_namespaces() {
  # $1 = input, $2 = destination. Rewrite the (already verified unique)
  # metadata.namespace value to $NAMESPACE. Leading indentation is preserved.
  awk -v ns="$NAMESPACE" '
    { if ($0 ~ /^[[:space:]]*namespace:/) sub(/namespace:[[:space:]]*[^[:space:]]+/, "namespace: " ns); print }
  ' "$1" > "$2"
}

rewrite_images() {
  # $1 = input, $2 = destination. Rewrite each backend image reference
  # <IMAGE_PREFIX>/<svc>:<anything> to $REGISTRY/$IMAGE_PREFIX/$svc:$TAG.
  # BSD/GNU-safe: writes to a new file, never edits in place.
  local sed_args=() svc
  for svc in $SERVICES; do
    sed_args+=(-e "s|image:[[:space:]]*${IMAGE_PREFIX}/${svc}:[^[:space:]]*|image: ${REGISTRY}/${IMAGE_PREFIX}/${svc}:${TAG}|")
  done
  sed "${sed_args[@]}" "$1" > "$2"
}

verify_transformed_manifest() {
  # $1 = transformed manifest. Structural assertions before kubectl apply.
  local f="$1" svc want count
  if [[ ! -s "$f" ]]; then
    echo "ERROR: transformed manifest is empty; refusing to apply." >&2
    return 1
  fi
  for svc in $SERVICES; do
    want="image: ${REGISTRY}/${IMAGE_PREFIX}/${svc}:${TAG}"
    count="$(grep -cF "$want" "$f" || true)"
    if [[ "$count" -ne 1 ]]; then
      echo "ERROR: expected exactly one '$want' line in the transformed manifest, found $count." >&2
      echo "The manifest has drifted from the expected backend structure; refusing to apply." >&2
      return 1
    fi
  done
  if grep -qF "pe-webapp" "$f"; then
    echo "ERROR: transformed manifest unexpectedly references pe-webapp; refusing to apply." >&2
    return 1
  fi
}
# <<< manifest-transform

# ---------------------------------------------------------------------------
# Temporary port-forwards for c8ctl resource deployment (--resources).
# The kubernetes profile fetches an OAuth token from Keycloak on
# localhost:18080 and calls the REST API on the Zeebe gateway at
# localhost:8080, so both must be reachable. If a forward is already running
# we reuse it; otherwise we start one and tear it down on exit.
# ---------------------------------------------------------------------------
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

# ---- Steps ----

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

image_ref() {
  # Full image reference for a backend service, honoring optional REGISTRY.
  printf '%s\n' "${REGISTRY:+$REGISTRY/}${IMAGE_PREFIX}/$1:${TAG}"
}

step_build_services() {
  TAG="${TAG:-latest}"
  banner "Building backend service images (tag: $TAG${REGISTRY:+, registry: $REGISTRY})"
  for svc in $SERVICES; do
    ref="$(image_ref "$svc")"
    echo "Building $ref"
    docker build --build-arg SERVICE="$svc" -f "$SERVICES_DIR/Dockerfile" -t "$ref" "$ROOT"
  done
}

step_push_services() {
  banner "Pushing backend service images to $REGISTRY (tag: $TAG)"
  for svc in $SERVICES; do
    ref="$REGISTRY/$IMAGE_PREFIX/$svc:$TAG"
    if ! docker image inspect "$ref" >/dev/null 2>&1; then
      echo "ERROR: local image '$ref' not found; run the build step first:" >&2
      echo "       REGISTRY=$REGISTRY TAG=$TAG ./scripts/deploy.sh --build --services" >&2
      exit 1
    fi
    echo "Pushing $ref"
    docker push "$ref"
  done
}

DEPLOY_TMP1=""
DEPLOY_TMP2=""
cleanup_deploy_tmp() {
  if [[ -n "$DEPLOY_TMP1" ]]; then rm -f "$DEPLOY_TMP1"; fi
  if [[ -n "$DEPLOY_TMP2" ]]; then rm -f "$DEPLOY_TMP2"; fi
}

step_deploy_services() {
  banner "Deploying backend services (registry: $REGISTRY, tag: $TAG)"
  [[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

  local svc ns ns_list ns_count ns_values old_ns svc_img
  local DEPLOYED_SUMMARY=""
  DEPLOY_TMP1="$(mktemp "${TMPDIR:-/tmp}/pe-deploy-manifest.XXXXXX")"
  DEPLOY_TMP2="$(mktemp "${TMPDIR:-/tmp}/pe-deploy-manifest.XXXXXX")"
  trap cleanup_deploy_tmp EXIT INT TERM

  echo "Filtering $MANIFEST to the backend service documents..."
  filter_service_docs "$MANIFEST" "$DEPLOY_TMP1"
  echo "  $(grep -c '^---$' "$DEPLOY_TMP1" || true) backend documents selected"

  if $NAMESPACE_EXPLICIT; then
    ns_values="$(grep -E '^[[:space:]]*namespace:[[:space:]]*[^[:space:]]+' "$DEPLOY_TMP1" | awk '{print $2}' | sort -u)" || true
    ns_count="$(printf '%s\n' "$ns_values" | awk 'NF { c++ } END { print c + 0 }')"
    if [[ "$ns_count" -ne 1 ]]; then
      {
        echo "ERROR: --namespace rewrite expects exactly one distinct 'namespace:' value in the"
        echo "       filtered manifest, found $ns_count:"
        printf '%s\n' "$ns_values" | sed 's/^/         /'
        echo "       Refusing to apply; check $MANIFEST."
      } >&2
      exit 1
    fi
    old_ns="$(printf '%s\n' "$ns_values" | head -n 1)"
    echo "Rewriting manifest namespace '$old_ns' -> '$NAMESPACE' (NAMESPACE override)."
    rewrite_namespaces "$DEPLOY_TMP1" "$DEPLOY_TMP2"
    mv "$DEPLOY_TMP2" "$DEPLOY_TMP1"
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
      echo "Creating namespace '$NAMESPACE'..."
      kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    fi
  else
    echo "Keeping manifest namespaces as-is (no NAMESPACE override)."
  fi

  echo "Rewriting backend images to $REGISTRY/$IMAGE_PREFIX/<svc>:$TAG..."
  rewrite_images "$DEPLOY_TMP1" "$DEPLOY_TMP2"
  verify_transformed_manifest "$DEPLOY_TMP2"

  echo
  kubectl apply -f "$DEPLOY_TMP2"

  echo
  for svc in $SERVICES; do
    # Resolve the namespace for rollout/reporting. kubectl set image-style
    # imperative commands do not inherit metadata.namespace from the applied
    # manifest, so resolve it explicitly.
    if $NAMESPACE_EXPLICIT; then
      ns="$NAMESPACE"
      if ! kubectl get deployment "pe-$svc" -n "$ns" >/dev/null 2>&1; then
        {
          echo "ERROR: deployment pe-$svc not found in namespace '$ns'."
          echo "       The --namespace override may be wrong; drop it to auto-discover"
          echo "       the namespace from the cluster."
        } >&2
        exit 1
      fi
    else
      if ! ns_list="$(
        kubectl get deployments \
          --all-namespaces \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\n"}{end}' |
          awk -v deployment="pe-$svc" '$1 == deployment { print $2 }'
      )"; then
        echo "ERROR: kubectl failed while listing deployments across namespaces." >&2
        exit 1
      fi
      ns_list="$(printf '%s\n' "$ns_list" | sort -u)"
      ns_count="$(printf '%s\n' "$ns_list" | awk 'NF { c++ } END { print c + 0 }')"
      if [[ "$ns_count" -eq 0 ]]; then
        echo "ERROR: deployment pe-$svc not found in any namespace — was the backend manifest applied?" >&2
        exit 1
      fi
      if [[ "$ns_count" -gt 1 ]]; then
        {
          echo "ERROR: deployment pe-$svc exists in multiple namespaces; refusing to guess. Found in:"
          printf '%s\n' "$ns_list" | sed 's/^/  /'
          echo "Pass --namespace <ns> (or NAMESPACE) to disambiguate."
        } >&2
        exit 1
      fi
      ns="$(printf '%s\n' "$ns_list" | head -n 1)"
    fi

    echo "Waiting for rollout: deployment/pe-$svc (namespace: $ns, timeout: $ROLLOUT_TIMEOUT)..."
    kubectl -n "$ns" rollout status "deployment/pe-$svc" --timeout="$ROLLOUT_TIMEOUT"

    svc_img="$(kubectl -n "$ns" get deployment "pe-$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    echo
    echo "pe-$svc (namespace: $ns):"
    kubectl -n "$ns" get deployment "pe-$svc" -o wide
    echo "Configured image: $svc_img"
    kubectl -n "$ns" get pods -l "app=pe-$svc" -o wide
    echo

    DEPLOYED_SUMMARY="${DEPLOYED_SUMMARY}  ${svc}  (${ns})  ${REGISTRY}/${IMAGE_PREFIX}/${svc}:${TAG}"$'\n'
  done

  banner "Deployed backend services"
  printf '%s' "$DEPLOYED_SUMMARY"

  trap - EXIT INT TERM
  cleanup_deploy_tmp
}

step_services() {
  banner "Building and deploying worker services (local images)"
  if [[ -n "${REGISTRY:-}" ]]; then
    echo "NOTE: plain --services ignores REGISTRY; it builds local ${IMAGE_PREFIX}/<svc>:${TAG:-latest}"
    echo "      images. Use --build/--push/--deploy --services for registry workflows."
  fi
  [[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

  for svc in $SERVICES; do
    echo "Building ${IMAGE_PREFIX}/${svc}:${TAG:-latest}"
    docker build --build-arg SERVICE="$svc" -t "${IMAGE_PREFIX}/${svc}:${TAG:-latest}" -f "$SERVICES_DIR/Dockerfile" "$ROOT"
  done

  kubectl apply -f "$MANIFEST"

  # Images are tagged :latest and manifests are unchanged across rebuilds, so a
  # plain apply does not restart existing pods. Force a rollout so the freshly
  # built image is picked up, skipping deployments scaled to 0 replicas.
  for svc in $SERVICES; do
    replicas="$(kubectl get deployment "pe-$svc" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    if [[ "$replicas" -gt 0 ]]; then
      kubectl rollout restart "deployment/pe-$svc" -n "$NAMESPACE"
    fi
    kubectl rollout status "deployment/pe-$svc" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
  done
}

step_resources() {
  banner "Deploying workflow resources (c8ctl profile: $PROFILE)"
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
if [[ -n "$LIFECYCLE" ]]; then
  echo "Lifecycle: $LIFECYCLE --services"
  echo "Registry:  ${REGISTRY:-<none>}"
  echo "Tag:       ${TAG:-<none>}"
  echo "Prefix:    $IMAGE_PREFIX"
  if $NAMESPACE_EXPLICIT; then
    echo "Namespace: $NAMESPACE (explicit override)"
  else
    echo "Namespace: auto-discovered from the cluster (--namespace to override)"
  fi
else
  echo "Steps:     platform=$DO_PLATFORM configure=$DO_CONFIGURE services=$DO_SERVICES resources=$DO_RESOURCES webapp=$DO_WEBAPP"
fi

if $DO_PLATFORM; then step_platform; fi
if $DO_CONFIGURE; then step_configure; fi
if [[ "$LIFECYCLE" == "build" ]]; then step_build_services; fi
if [[ "$LIFECYCLE" == "push" ]]; then step_push_services; fi
if [[ "$LIFECYCLE" == "deploy" ]]; then step_deploy_services; fi
if [[ -z "$LIFECYCLE" ]] && $DO_SERVICES; then step_services; fi
if $DO_RESOURCES; then step_resources; fi
if $DO_WEBAPP; then step_webapp; fi

if [[ -n "$LIFECYCLE" ]]; then
  banner "Lifecycle '$LIFECYCLE' complete"
else
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
fi
