#!/usr/bin/env bash
# build-deploy.sh — DEPRECATED thin wrapper around scripts/deploy.sh.
#
# The service/resource lifecycle now lives in scripts/deploy.sh:
#
#   build-deploy.sh                    ->  deploy.sh --services
#   build-deploy.sh --services         ->  deploy.sh --services
#   build-deploy.sh --resources        ->  deploy.sh --resources
#   build-deploy.sh --tag <tag>        ->  deploy.sh --tag <tag>
#   build-deploy.sh --profile <name>   ->  deploy.sh --profile <name>
#
# New callers should use scripts/deploy.sh directly (it also exposes the
# CI/CD lifecycle actions --build/--push/--deploy --services).

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

{
  echo "WARNING: scripts/deploy/services/build-deploy.sh is deprecated; use scripts/deploy.sh."
  echo "         --services -> deploy.sh --services, --resources -> deploy.sh --resources,"
  echo "         --tag <tag> -> deploy.sh --tag <tag>, --profile <name> -> deploy.sh --profile <name>"
} >&2

# Preserve the old default: no flags meant --services.
if [[ $# -eq 0 ]]; then
  set -- --services
fi

exec "$ROOT/scripts/deploy.sh" "$@"
