#!/bin/bash
set -euo pipefail

# ============================================================
# configure-c8ctl.sh — Configure c8ctl to work with the local
# Rancher Desktop k3s Camunda 8 no-domain deployment.
#
# This script:
#   1. Creates a dedicated OIDC client ("zeebe-cli") in Keycloak
#      with service accounts enabled and the orchestration audience
#   2. Sets the client secret and reads it from the Keycloak response
#   3. Stores the client credentials in a Kubernetes secret
#   4. Registers a c8ctl profile pointing at the local deployment
#
# Prerequisites:
#   - The no-domain deployment must be running (Keycloak + Zeebe)
#   - c8ctl installed (npm install -g @camunda8/cli)
#   - kubectl connected to the cluster
#   - curl and jq installed
#
# The script starts a temporary Keycloak port-forward in the
# background, performs the configuration, then cleans up.
#
# Usage:
#   ./configure-c8ctl.sh --namespace camunda --release-name camunda
#
# Or called automatically as Step 7 of camunda-deploy-no-domain.sh
# ============================================================

# ---- Defaults ----
NAMESPACE="camunda"
RELEASE_NAME="camunda"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18080}"
ZEEBE_PORT="${ZEEBE_PORT:-8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-camunda-platform}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-temp-admin}"
OIDC_CLIENT_ID="zeebe-cli"
OIDC_CLIENT_NAME="c8ctl CLI Client"
C8CTL_PROFILE_NAME="${C8CTL_PROFILE_NAME:-rancher-desktop}"

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --release-name)
      RELEASE_NAME="$2"
      shift 2
      ;;
    --keycloak-port)
      KEYCLOAK_PORT="$2"
      shift 2
      ;;
    --zeebe-port)
      ZEEBE_PORT="$2"
      shift 2
      ;;
    --profile-name)
      C8CTL_PROFILE_NAME="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--namespace camunda] [--release-name camunda] [--keycloak-port 18080] [--zeebe-port 8080] [--profile-name rancher-desktop]"
      echo ""
      echo "This script starts a temporary Keycloak port-forward, creates an OIDC"
      echo "client for c8ctl, stores credentials in a Kubernetes secret, and"
      echo "registers a c8ctl profile. The port-forward is cleaned up on exit."
      echo ""
      echo "Prerequisites:"
      echo "  - Keycloak and Zeebe must be deployed and running in the cluster"
      echo "  - c8ctl must be installed (npm install -g @camunda8/cli)"
      echo "  - kubectl connected to the k3s cluster"
      echo "  - curl and jq installed"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      exit 1
      ;;
  esac
done

echo "=== c8ctl Configuration ==="
echo "Namespace:    $NAMESPACE"
echo "Release name: $RELEASE_NAME"
echo "Keycloak:     http://localhost:$KEYCLOAK_PORT"
echo "Zeebe REST:   http://localhost:$ZEEBE_PORT"
echo "Realm:        $KEYCLOAK_REALM"
echo "Profile name: $C8CTL_PROFILE_NAME"
echo ""

# ---- Pre-flight checks ----
if ! command -v c8ctl &>/dev/null; then
  echo "ERROR: c8ctl is not installed. Install it with: npm install -g @camunda8/cli"
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl is not installed."
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is not installed."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed."
  exit 1
fi

# ---- Start temporary Keycloak port-forward ----
echo "Starting temporary Keycloak port-forward..."
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then
    echo "Stopping Keycloak port-forward (PID $PF_PID)..."
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

kubectl port-forward "svc/keycloak-service" -n "$NAMESPACE" "${KEYCLOAK_PORT}:18080" >/dev/null 2>&1 &
PF_PID=$!

# Wait for the port-forward to be ready
echo "Waiting for Keycloak port-forward to be ready..."
KEYCLOAK_BASE="http://localhost:${KEYCLOAK_PORT}/auth"
KEYCLOAK_ADMIN_URL="${KEYCLOAK_BASE}/admin/realms/${KEYCLOAK_REALM}"

PF_READY=false
for _ in $(seq 1 15); do
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "ERROR: Keycloak port-forward exited unexpectedly."
    exit 1
  fi
  if curl -s -o /dev/null --max-time 3 "${KEYCLOAK_BASE}/realms/master" 2>/dev/null; then
    PF_READY=true
    break
  fi
  sleep 1
done

if [ "$PF_READY" != "true" ]; then
  echo "ERROR: Keycloak port-forward did not become ready."
  exit 1
fi
echo "Keycloak port-forward is ready."

# ---- Get Keycloak admin credentials ----
echo ""
echo "Retrieving Keycloak admin credentials..."
KEYCLOAK_ADMIN_PASSWORD="$(kubectl get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
  echo "ERROR: Could not retrieve keycloak-initial-admin secret."
  echo "       Ensure the Keycloak operator has deployed and the secret exists."
  exit 1
fi

# ---- Helper: get a fresh admin token ----
# Keycloak tokens expire in 60 seconds, but the realm wait can take minutes.
get_admin_token() {
  curl -s -X POST \
    "${KEYCLOAK_BASE}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${KEYCLOAK_ADMIN_USER}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true
}

# ---- Get admin access token from Keycloak ----
echo "Obtaining admin access token..."
KEYCLOAK_TOKEN="$(get_admin_token)"

if [ -z "$KEYCLOAK_TOKEN" ]; then
  echo "ERROR: Could not obtain Keycloak admin token."
  echo "       The Keycloak admin credentials may have changed since deployment."
  exit 1
fi
echo "Admin token obtained."

# ---- Wait for the camunda-platform realm to exist ----
# The camunda-platform realm is created asynchronously by Camunda Identity
# after the Helm chart is installed. We must wait for it before creating
# an OIDC client in that realm.
echo ""
echo "Waiting for '${KEYCLOAK_REALM}' realm to be created by Camunda Identity..."
REALM_READY=false
for _ in $(seq 1 60); do
  REALM_CHECK="$(curl -s -o /dev/null -w "%{http_code}" \
    "${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}" 2>/dev/null || true)"
  if [ "$REALM_CHECK" = "200" ]; then
    REALM_READY=true
    break
  fi
  # Check if port-forward is still alive
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "ERROR: Keycloak port-forward exited unexpectedly while waiting for realm."
    exit 1
  fi
  # Refresh token if needed (expires in 60s)
  KEYCLOAK_TOKEN="$(get_admin_token)"
  echo "  Realm '${KEYCLOAK_REALM}' not yet available (HTTP ${REALM_CHECK:-000}), retrying in 5s..."
  sleep 5
done

if [ "$REALM_READY" != "true" ]; then
  echo "ERROR: Realm '${KEYCLOAK_REALM}' was not created within 5 minutes."
  echo "       Camunda Identity may not have started yet."
  echo "       Check pod status: kubectl get pods -n $NAMESPACE"
  exit 1
fi
echo "Realm '${KEYCLOAK_REALM}' is available."

# Refresh token after potential realm wait
KEYCLOAK_TOKEN="$(get_admin_token)"

# ---- Create OIDC client in Keycloak for c8ctl ----
echo ""
echo "Creating OIDC client '${OIDC_CLIENT_ID}' in Keycloak..."

# Build the client creation payload.
# fullScopeAllowed=true ensures the service account gets all realm-level roles.
# The orchestration audience mapper adds the "orchestration" audience to tokens,
# which is required for Zeebe gateway authentication in Camunda 8.10+.
CLIENT_PAYLOAD=$(cat <<EOF
{
  "clientId": "${OIDC_CLIENT_ID}",
  "name": "${OIDC_CLIENT_NAME}",
  "enabled": true,
  "publicClient": false,
  "serviceAccountsEnabled": true,
  "directAccessGrantsEnabled": false,
  "authorizationServicesEnabled": false,
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "fullScopeAllowed": true
}
EOF
)

# Check if client already exists (search by clientId, not UUID)
EXISTING_CLIENT_UUID="$(curl -s \
  "${KEYCLOAK_ADMIN_URL}/clients?clientId=${OIDC_CLIENT_ID}" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)"

if [ -n "$EXISTING_CLIENT_UUID" ]; then
  echo "Client '${OIDC_CLIENT_ID}' already exists (UUID: ${EXISTING_CLIENT_UUID}) — updating..."
  # Update client to ensure fullScopeAllowed is set
  curl -s -o /dev/null \
    -X PUT \
    "${KEYCLOAK_ADMIN_URL}/clients/${EXISTING_CLIENT_UUID}" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$CLIENT_PAYLOAD" 2>/dev/null || true
else
  echo "Creating new client '${OIDC_CLIENT_ID}'..."
  CREATE_RESPONSE="$(curl -s -w "\n%{http_code}" \
    -X POST \
    "${KEYCLOAK_ADMIN_URL}/clients" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$CLIENT_PAYLOAD" 2>/dev/null)"

  HTTP_CODE="$(echo "$CREATE_RESPONSE" | tail -1)"
  if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "204" ]; then
    echo "ERROR: Failed to create client via Admin API (HTTP $HTTP_CODE)."
    echo "       Response: $(echo "$CREATE_RESPONSE" | head -n -1)"
    echo ""
    echo "  You may need to create the client manually in the Keycloak UI."
    exit 1
  fi

  # Retrieve the client UUID
  EXISTING_CLIENT_UUID="$(curl -s \
    "${KEYCLOAK_ADMIN_URL}/clients?clientId=${OIDC_CLIENT_ID}" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)"

  if [ -z "$EXISTING_CLIENT_UUID" ]; then
    echo "ERROR: Client created but could not retrieve its UUID."
    exit 1
  fi
  echo "Client '${OIDC_CLIENT_ID}' created (UUID: ${EXISTING_CLIENT_UUID})."
fi

# ---- Add orchestration audience mapper to the client ----
# In Camunda 8.10+, the Zeebe gateway (now "orchestration") requires
# the "orchestration" audience in the token. This mapper adds it.
echo "Adding orchestration audience mapper..."

# Check if mapper already exists
EXISTING_MAPPERS="$(curl -s \
  "${KEYCLOAK_ADMIN_URL}/clients/${EXISTING_CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" 2>/dev/null || true)"

MAPPER_EXISTS="$(echo "$EXISTING_MAPPERS" | jq -r '.[] | select(.name == "orchestration Audience Mapper") | .id // empty' 2>/dev/null || true)"

if [ -n "$MAPPER_EXISTS" ]; then
  echo "Orchestration audience mapper already exists — updating..."
  curl -s -o /dev/null \
    -X PUT \
    "${KEYCLOAK_ADMIN_URL}/clients/${EXISTING_CLIENT_UUID}/protocol-mappers/models/${MAPPER_EXISTS}" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "orchestration Audience Mapper",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.client.audience": "orchestration",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "userinfo.token.claim": "false"
      }
    }' 2>/dev/null || true
else
  MAPPER_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    "${KEYCLOAK_ADMIN_URL}/clients/${EXISTING_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "orchestration Audience Mapper",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.client.audience": "orchestration",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "userinfo.token.claim": "false"
      }
    }' 2>/dev/null || true)"
  if [ "$MAPPER_CODE" != "200" ] && [ "$MAPPER_CODE" != "201" ]; then
    echo "WARNING: Failed to add orchestration audience mapper (HTTP $MAPPER_CODE)."
    echo "         c8ctl may not authenticate against the Zeebe gateway."
  else
    echo "Orchestration audience mapper added (HTTP $MAPPER_CODE)."
  fi
fi

# ---- Set the client secret using the dedicated endpoint ----
# In Keycloak 26.x, POST to /clients/{id}/client-secret generates a new
# random secret. The response body contains the generated secret,
# which we must use (not a pre-generated value).
echo "Setting client secret..."
SECRET_RESPONSE="$(curl -s \
  -X POST \
  "${KEYCLOAK_ADMIN_URL}/clients/${EXISTING_CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' 2>/dev/null || true)"

SECRET_CODE="$(echo "$SECRET_RESPONSE" | jq -r '.value // empty' 2>/dev/null || true)"

if [ -z "$SECRET_CODE" ]; then
  echo "WARNING: Failed to set client secret."
  echo "         Raw response: ${SECRET_RESPONSE}"
  echo "         c8ctl may fail to authenticate."
  CLIENT_SECRET=""
else
  CLIENT_SECRET="$SECRET_CODE"
  echo "Client secret set successfully."
  echo "  Secret: ${CLIENT_SECRET}"
fi

# ---- Store client credentials in a Kubernetes secret ----
echo ""
echo "Storing client credentials in Kubernetes secret 'c8ctl-credentials'..."
if [ -n "$CLIENT_SECRET" ]; then
  kubectl create secret generic "c8ctl-credentials" \
    --namespace "$NAMESPACE" \
    --from-literal=client-id="${OIDC_CLIENT_ID}" \
    --from-literal=client-secret="${CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret 'c8ctl-credentials' created/updated in namespace '$NAMESPACE'."
else
  echo "WARNING: Skipping Kubernetes secret creation — no client secret available."
fi

# ---- Configure c8ctl profile ----
echo ""
echo "Configuring c8ctl profile '${C8CTL_PROFILE_NAME}'..."

# Remove existing profile if it exists (idempotent)
c8ctl remove profile "$C8CTL_PROFILE_NAME" 2>/dev/null || true

# Create the profile
# In Camunda 8.10+, the Zeebe gateway is called "orchestration".
# The audience must be "orchestration" for the token to be accepted.
c8ctl add profile "$C8CTL_PROFILE_NAME" \
  --baseUrl="http://localhost:${ZEEBE_PORT}" \
  --clientId="${OIDC_CLIENT_ID}" \
  --clientSecret="${CLIENT_SECRET}" \
  --audience="orchestration" \
  --oAuthUrl="${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"

# Set as active profile
c8ctl use profile "$C8CTL_PROFILE_NAME" 2>/dev/null || true

# ---- Create authorization for zeebe-cli client via Admin API ----
echo ""
echo "Creating authorization for '${OIDC_CLIENT_ID}' client via Admin API..."

# Start temporary port-forward for Zeebe gateway REST API (admin API)
ADMIN_PF_PID=""
cleanup_admin_pf() {
  if [ -n "$ADMIN_PF_PID" ]; then
    kill "$ADMIN_PF_PID" 2>/dev/null || true
    wait "$ADMIN_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup_admin_pf RETURN

kubectl port-forward "svc/${RELEASE_NAME}-zeebe-gateway" -n "$NAMESPACE" "${ZEEBE_PORT}:8080" >/dev/null 2>&1 &
ADMIN_PF_PID=$!

# Wait for port-forward to be ready
sleep 3
for _ in $(seq 1 10); do
  if curl -s -o /dev/null --max-time 3 "http://localhost:${ZEEBE_PORT}/ready" 2>/dev/null; then
    break
  fi
  sleep 1
done

# Get an access token for the admin API (using the zeebe-cli client credentials)
ADMIN_TOKEN=$(curl -s -X POST \
  "${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${OIDC_CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "audience=orchestration" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)

if [ -n "$ADMIN_TOKEN" ]; then
  # Create authorization for zeebe-cli client to deploy resources
  AUTH_PAYLOAD=$(cat <<EOF
{
  "ownerType": "CLIENT",
  "ownerId": "${OIDC_CLIENT_ID}",
  "resourceType": "RESOURCE",
  "resourceId": "*",
  "permissionTypes": ["CREATE", "READ"]
}
EOF
)

  AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    "http://localhost:${ZEEBE_PORT}/api/admin/authorizations" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" 2>/dev/null || true)

  HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -1)
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "Authorization created successfully for '${OIDC_CLIENT_ID}' client."
  elif [ "$HTTP_CODE" = "409" ]; then
    echo "Authorization already exists for '${OIDC_CLIENT_ID}' client."
  else
    echo "WARNING: Failed to create authorization (HTTP $HTTP_CODE)."
    echo "         Response: $(echo "$AUTH_RESPONSE" | head -n -1)"
    echo "         You may need to create it manually via Admin UI."
    echo "         Owner type: CLIENT, Owner ID: ${OIDC_CLIENT_ID}, Resource: RESOURCE/*, Permissions: CREATE, READ"
  fi
else
  echo "WARNING: Could not obtain admin token. Skipping authorization creation."
  echo "         You may need to create the authorization manually via Admin UI."
fi

cleanup_admin_pf
trap - RETURN

# ---- Verify the profile works ----
echo ""
echo "Verifying c8ctl profile..."

# Start both port-forwards temporarily for verification
VERIFY_PIDS=()
cleanup_verify() {
  for pid in "${VERIFY_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_verify' RETURN

kubectl port-forward "svc/keycloak-service" -n "$NAMESPACE" "${KEYCLOAK_PORT}:18080" >/dev/null 2>&1 &
VERIFY_PIDS+=($!)
kubectl port-forward "svc/${RELEASE_NAME}-zeebe-gateway" -n "$NAMESPACE" "${ZEEBE_PORT}:8080" >/dev/null 2>&1 &
VERIFY_PIDS+=($!)

# Wait for port-forwards to be ready
sleep 3
for _ in $(seq 1 10); do
  if curl -s -o /dev/null --max-time 3 "http://localhost:${KEYCLOAK_PORT}/auth/realms/master" 2>/dev/null; then
    break
  fi
  sleep 1
done

if c8ctl get topology --profile="$C8CTL_PROFILE_NAME" 2>/dev/null; then
  echo "c8ctl profile verified — topology retrieved successfully."
else
  echo "WARNING: c8ctl profile was created but could not retrieve topology."
  echo "         Ensure both port-forwards are running:"
  echo "         kubectl port-forward svc/keycloak-service -n $NAMESPACE ${KEYCLOAK_PORT}:18080"
  echo "         kubectl port-forward svc/${RELEASE_NAME}-zeebe-gateway -n $NAMESPACE ${ZEEBE_PORT}:8080"
  echo ""
  echo "         If the issue persists, check:"
  echo "         - The client secret matches: kubectl get secret c8ctl-credentials -n $NAMESPACE -o jsonpath='{.data.client-secret}' | base64 -d"
  echo "         - The zeebe-cli client has the orchestration audience mapper"
  echo "         - The zeebe-cli client has serviceAccountsEnabled and fullScopeAllowed"
fi
cleanup_verify

echo ""
echo "=============================================="
echo " c8ctl configuration complete!"
echo "=============================================="
echo ""
echo "Profile:      $C8CTL_PROFILE_NAME"
echo "Base URL:     http://localhost:${ZEEBE_PORT}/v2"
echo "OAuth URL:    ${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}"
echo ""
echo "Test the connection (with port-forwards running):"
echo "  c8ctl get topology --profile=${C8CTL_PROFILE_NAME}"
echo "  c8ctl list pd --profile=${C8CTL_PROFILE_NAME}"
echo "  c8ctl list pi --profile=${C8CTL_PROFILE_NAME}"
echo "  c8ctl deploy ./my-process.bpmn --profile=${C8CTL_PROFILE_NAME}"
echo ""
echo "Required port-forwards for ongoing use (run in separate terminals):"
echo "  kubectl port-forward svc/keycloak-service -n $NAMESPACE ${KEYCLOAK_PORT}:18080"
echo "  kubectl port-forward svc/${RELEASE_NAME}-zeebe-gateway -n $NAMESPACE ${ZEEBE_PORT}:8080"
echo ""
echo "To retrieve credentials later:"
echo "  kubectl get secret c8ctl-credentials -n $NAMESPACE -o jsonpath='{.data.client-id}' | base64 -d"
echo "  kubectl get secret c8ctl-credentials -n $NAMESPACE -o jsonpath='{.data.client-secret}' | base64 -d"
