#!/bin/bash

# Array of target resources and port mappings
# Format: "resource local_port:remote_port"
FORWARDS=(
  "svc/keycloak-service -n camunda 18080:18080"
  "svc/camunda-zeebe-gateway -n camunda 8080:8080"
  "svc/camunda-optimize -n camunda 8083:80"
  "svc/camunda-web-modeler-restapi -n camunda 8070:80"
  "svc/camunda-web-modeler-websockets -n camunda 8085:80"
  "svc/camunda-console -n camunda 8087:80"
  "svc/camunda-connectors -n camunda 8086:8080"
)

# Array to store background process IDs
PIDS=()

# Function to kill all background port-forwards on exit
cleanup() {
  echo -e "\nStopping all port forwards..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done
  exit 0
}

# Trap Ctrl+C (SIGINT) and call cleanup
trap cleanup SIGINT

# Loop and launch each forward in the background
for item in "${FORWARDS[@]}"; do
  # shellcheck disable=SC2086
  kubectl port-forward $item > /dev/null 2>&1 &
  PIDS+=($!)
  echo "Forwarding $item..."
done
echo "All port forwards started."
echo "Use Ctrl+C to stop all port forwards."

# Keep script alive to wait for Ctrl+C
wait
