#!/usr/bin/env bash
# ============================================================
# camunda-uninstall.sh — tear down the local Camunda platform deployment.
#
# Usage:
#   camunda-uninstall.sh          # uninstall the Helm release + delete namespaces
#   camunda-uninstall.sh --full   # also delete operator CRDs (complete reset)
#
# Environment variables (all optional):
#   CAMUNDA_NAMESPACE    - Camunda namespace              (default: camunda)
#   CAMUNDA_RELEASE_NAME - Camunda Helm release name      (default: camunda)
#   ES_NAMESPACE         - Elasticsearch operator ns      (default: elastic-system)
#   CNPG_NAMESPACE       - CloudNativePG operator ns      (default: cnpg-system)
#
# Notes:
#   Only the Camunda platform chart is a Helm release. The ECK, CloudNativePG,
#   and Keycloak operators are applied from raw manifests and are removed when
#   their namespaces are deleted. Their CRDs are cluster-scoped and survive
#   namespace deletion, so --full is required for a truly clean slate.
# ============================================================
set -euo pipefail

CAMUNDA_NAMESPACE="${CAMUNDA_NAMESPACE:-camunda}"
CAMUNDA_RELEASE_NAME="${CAMUNDA_RELEASE_NAME:-camunda}"
ES_NAMESPACE="${ES_NAMESPACE:-elastic-system}"
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"

FULL=false
usage() {
  cat <<'EOF'
Usage: camunda-uninstall.sh [--full]

  --full         Also delete operator CRDs (complete reset)
  -h, --help     Show this help

Environment variables:
  CAMUNDA_NAMESPACE, CAMUNDA_RELEASE_NAME, ES_NAMESPACE, CNPG_NAMESPACE
EOF
}

for arg in "$@"; do
  case "$arg" in
    --full) FULL=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

echo "=============================================="
echo " Camunda Platform Uninstall"
echo "=============================================="
echo "Namespace:    $CAMUNDA_NAMESPACE"
echo "Release name: $CAMUNDA_RELEASE_NAME"
echo "Full reset:   $FULL"
echo ""

# ---- Step 1: Uninstall Helm releases (before namespace deletion so CRs
#              managed by the release are cleaned up first) ----
echo "=== Uninstalling Helm release '$CAMUNDA_RELEASE_NAME' ==="
if helm status "$CAMUNDA_RELEASE_NAME" -n "$CAMUNDA_NAMESPACE" >/dev/null 2>&1; then
  helm uninstall "$CAMUNDA_RELEASE_NAME" -n "$CAMUNDA_NAMESPACE" || true
else
  echo "Helm release '$CAMUNDA_RELEASE_NAME' not found — skipping."
fi

# Warn about any other releases still present in the managed namespaces so
# nothing is orphaned silently.
for ns in "$CAMUNDA_NAMESPACE" "$ES_NAMESPACE" "$CNPG_NAMESPACE"; do
  releases="$(helm list -n "$ns" -q 2>/dev/null || true)"
  if [ -n "$releases" ]; then
    echo "NOTE: remaining Helm release(s) in '$ns':"
    echo "$releases" | sed 's/^/  - /'
  fi
done

# ---- Step 2: Delete namespaces (ignore missing; bounded timeout) ----
echo ""
echo "=== Deleting namespaces ==="
kubectl delete namespace "$ES_NAMESPACE" "$CNPG_NAMESPACE" "$CAMUNDA_NAMESPACE" \
  --ignore-not-found --timeout=300s || true

# ---- Step 3: Optionally remove cluster-scoped operator CRDs ----
if $FULL; then
  echo ""
  echo "=== Deleting operator CRDs (--full) ==="
  for crd in \
    elasticsearches.elastic.co \
    clusters.postgresql.cnpg.io \
    keycloaks.k8s.keycloak.org \
    keycloakrealmimports.k8s.keycloak.org; do
    echo "  deleting $crd"
    kubectl delete crd "$crd" --ignore-not-found --timeout=120s || true
  done
fi

echo ""
echo "=============================================="
echo " Uninstall complete."
if ! $FULL; then
  echo " Run with --full to also remove operator CRDs."
fi
echo "=============================================="
