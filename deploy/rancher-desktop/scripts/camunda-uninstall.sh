#!/bin/bash
set -euo pipefail
#helm uninstall camunda -n camunda

kubectl delete namespace elastic-system
kubectl delete namespace cnpg-system
kubectl delete namespace camunda
