# Go Microservices for the 855x Enrollment Workflow — Implementation Plan

## 1. Goal & scope

Implement **5 Go microservices**, each exposing an HTTP API (business logic) **and** an embedded Camunda 8 job worker that calls that HTTP API. The workers replace the current FEEL `scriptTask` stubs in the 855x-combined workflows with real `bpmn:serviceTask`s.

**In scope:** every script task in `Enrollment_Orchestrator.bpmn`, `Delegate_855A/855B/855I.bpmn`, and `Shared_OIG_Screening.bpmn` becomes a service task; a new `generate-doc` service task is inserted in the orchestrator.

**Out of scope:** `Shared_Intake`, `Shared_SA_Referral`, and the orphaned `Shared_Error_Handling` keep their script stubs (none of the 5 topics map to them); the 3 DMN decisions, forms, and user tasks are untouched.

## 2. Verified environment & constraints

- **Cluster:** Camunda Platform helm chart `14.6.1`, release `camunda`, namespace `camunda`, Rancher Desktop k3s. **No ingress** — local access only via `deploy/rancher-desktop/scripts/camunda-port-forwards.sh`.
- **c8ctl profile:** `rancher-desktop`; always pass `--profile=rancher-desktop`. Auth OIDC client `zeebe-cli`, realm `camunda-platform`, audience `orchestration`.
- **Zeebe gateway:** service `camunda-zeebe-gateway` in namespace `camunda`. gRPC `26500` (in-cluster: `camunda-zeebe-gateway:26500`; local: `kubectl port-forward svc/camunda-zeebe-gateway -n camunda 26500:26500`). REST `8080` (local port-forward).
- **Worker auth:** reuse the existing `zeebe-cli` credentials (already in secret `c8ctl-credentials`). `configure-c8ctl.sh` grants `zeebe-cli` `UPDATE_PROCESS_INSTANCE` on `PROCESS_DEFINITION` plus full user-task perms — exactly what job workers need. **No new client or authorizations required.**
- **Go client:** the official `github.com/camunda/zeebe/clients/go/v8` was **deprecated at Camunda 8.6**. Use **`github.com/camunda-community-hub/zeebe-client-go/v8@v8.6.0`** (verified on pkg.go.dev).
- **Multi-tenancy:** disabled — no `tenantIds` needed.

## 3. Architecture

```
Camunda 8 (namespace camunda)
   │  gRPC 26500 (auth: zeebe-cli OIDC)
   ▼
┌────────────────────────────────────────────────────────────┐
│ Each service = 1 binary = HTTP API (logic) + embedded worker│
│                                                              │
│ eligibility     : screen-oig, screen-sam                     │
│ verification    : verify-npi, verify-tin, verify-license,    │
│                   verify-bond, verify-equipment,             │
│                   verify-fire-safety, verify-board-cert      │
│ scheduling      : process-site-visit                         │
│ documents       : generate-doc (NEW BPMN task)               │
│ notifications   : send-notification (5 tasks, header "kind") │
└────────────────────────────────────────────────────────────┘
        │ worker calls own HTTP API on localhost:<port>
        ▼
   business logic (NPI Luhn, OIG/SAM screening sim, doc packet, …)
```

**Module layout** (single Go module, one binary per service):

```
services/
  go.mod                       module github.com/pe-workflow/services
  internal/zeebeworker/        shared client bootstrap + worker helpers
  cmd/eligibility/main.go
  cmd/verification/main.go
  cmd/scheduling/main.go
  cmd/documents/main.go
  cmd/notifications/main.go
deploy/services/
  Dockerfile                   multi-stage, --build-arg SERVICE=<name>
  manifests.yaml               Deployments + optional Services (namespace camunda)
```

## 4. Go module & shared code

```go
// services/go.mod
module github.com/pe-workflow/services

go 1.22

require github.com/camunda-community-hub/zeebe-client-go/v8 v8.6.0
```

```go
// services/internal/zeebeworker/zeebeworker.go
package zeebeworker

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "os"
    "time"

    "github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
    "github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
    "github.com/camunda-community-hub/zeebe-client-go/v8/pkg/zbc"
)

// NewClient builds the Zeebe client from the standard env vars. In-cluster the
// Deployment sets ZEEBE_ADDRESS=camunda-zeebe-gateway:26500 and the Keycloak
// token URL; locally it points at the port-forwards.
func NewClient() (zbc.Client, error) {
    creds, err := zbc.NewOAuthCredentialsProvider(&zbc.OAuthProviderConfig{})
    if err != nil {
        return nil, fmt.Errorf("oauth provider: %w", err)
    }
    return zbc.NewClient(&zbc.ClientConfig{
        GatewayAddress:         envOr("ZEEBE_ADDRESS", "camunda-zeebe-gateway:26500"),
        UsePlaintextConnection: true,
        CredentialsProvider:    creds,
    })
}

// HandlerFunc adapts an HTTP-calling handler to the client's JobHandler. fn
// returns the completion variables (nil => fail with retries 0).
type HandlerFunc func(vars string, headers map[string]string) (map[string]any, error)

func Handle(client worker.JobClient, job entities.Job, fn HandlerFunc) {
    result, err := fn(job.GetVariables(), job.GetCustomHeaders())
    if err != nil {
        fmt.Printf("job %d failed: %v\n", job.GetKey(), err)
        _, _ = client.NewFailJobCommand().
            JobKey(job.GetKey()).
            Retries(0).
            ErrorMessage(err.Error()).
            Send(context.Background())
        return
    }
    if _, err := client.NewCompleteJobCommand().
        JobKey(job.GetKey()).
        VariablesFromObject(result).
        Send(context.Background()); err != nil {
        fmt.Printf("job %d complete failed: %v\n", job.GetKey(), err)
    }
}

// CallPOST posts body to the service's own HTTP API and decodes resp.
func CallPOST(baseURL, path string, body any, out any) error {
    data, err := json.Marshal(body)
    if err != nil {
        return err
    }
    ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()
    req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+path, bytes.NewReader(data))
    if err != nil {
        return err
    }
    req.Header.Set("Content-Type", "application/json")
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("POST %s returned %s", path, resp.Status)
    }
    return json.NewDecoder(resp.Body).Decode(out)
}

func envOr(key, def string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return def
}
```

## 5. Service specifications

Each `cmd/<service>/main.go`: start HTTP server on `localhost:<port>`, create client, register one `worker.JobWorker` per type via `client.NewJobWorker().JobType(t).Handler(...)`, block on signal. Ports: eligibility `8081`, verification `8082`, scheduling `8083`, documents `8084`, notifications `8085`.

### 5.1 eligibility-service (types `screen-oig`, `screen-sam`)

HTTP API:
- `POST /screen/oig` — body `{npi, legalName, state}` → `{cleared bool, riskScore int, source string, screenedAt string}`
- `POST /screen/sam` — body `{npi, legalName, tin}` → `{cleared bool, riskScore int, source string, screenedAt string}`

Deterministic demo rules: `cleared=false` if `legalName` contains `"EXCLUDED"` (OIG) or `"DEBARRED"` (SAM); else `true`. `riskScore = 30` base, `+25` if NPI ends in an odd digit, `+20` if `state` empty — so `providerRiskScore` can hit the DMN's `CONDITIONAL` thresholds (≥50, ≥75).

Handlers:
- `screen-oig` — `FetchVariables("provider")`; POST `/screen/oig`; completes `{oigCleared, providerRiskScore, oigScreening:{...}}`.
- `screen-sam` — POST `/screen/sam`; completes `{samCleared, samScreening:{...}}`.

> **Deliberate naming change:** the old stubs wrote nested `verification.oigCleared`. These tasks now write **flat** `oigCleared`, `samCleared`, `npiIsActive`, `tinValid`, `licenseValid` because `Eligibility_Rules.dmn` declares flat inputs (`oigCleared`, `npiIsActive`, `providerRiskScore`, `enrollmentType`) — see §6.5. Verified: nothing else references `verification.*`, so flattening is safe.

### 5.2 verification-service (7 types)

HTTP API (all body `{provider}` or flat fields; all return `{valid bool, ...}`):
- `POST /verify/npi` — real NPI check digit: 10 digits; take first 9, prepend `80840`, run Luhn; result must equal the 10th digit. Also `{active: true}`. → completes `{npiIsActive, npiValidation:{...}}`
- `POST /verify/tin` — 9 digits, not all zeros. → `{tinValid, tinValidation:{...}}`
- `POST /verify/license` — dispatch on `provider.entityType` (consolidates the 4 old license stubs):
  - `Facility` → `valid = licenseNumber != ""`
  - `DME Supplier` → `valid = stateLicenseNumber != ""`
  - `Physician` | `NPP` → `valid = licenseNumber != ""`
  → completes `{licenseValid, licenseValidation:{...}}`
- `POST /verify/bond` — `valid = suretyBondAmount >= 50000`. → `{bondValid,...}`
- `POST /verify/equipment` — `valid = equipmentLicenseNumber != ""`. → `{equipmentLicensureValid,...}`
- `POST /verify/fire-safety` — `valid = fireSafetyCertification != ""`. → `{fireSafetyCompliant,...}`
- `POST /verify/board-cert` — input `{entityType, licenseValid}`; `certified = entityType == "Physician" && licenseValid`. → `{boardCertified,...}`

### 5.3 scheduling-service (type `process-site-visit`)

- `POST /site-visit/process` — body `{siteVisitOutcome, provider}` → `{siteVerified: siteVisitOutcome=="Passed", followUpDate, followUpRequired: siteVisitOutcome!="Passed"}`.
- `FetchVariables("provider","siteVisitOutcome")`; completes `{provider:{siteVerified,...}, followUpDate, followUpRequired}`.

### 5.4 documents-service (type `generate-doc`, NEW task)

- `POST /documents/generate` — body `{documentationResult, provider}` → `{documentId, format:"PDF", sections, pages, generatedAt}`. Business logic: build an enrollment packet manifest from `documentationResult.requiredDocuments` / `requiredSections`; `pages` = number of sections; `documentId = "DOC-" + provider.npi + "-" + <unix>`, `sections` = split of `requiredSections`.
- `FetchVariables("documentationResult","provider")`; completes `{documentation:{...}}`.

### 5.5 notifications-service (type `send-notification`, 5 tasks via header)

- `POST /notifications/send` — body `{kind, to, subject, body}` → `{messageId, status:"SENT"}`.
- Worker `FetchVariables("provider","eligibilityResult","cmsCertificationNumber","ptanNumber","effectiveDate","denialReason")`. Reads task header `kind`, builds subject/body from those variables, calls the API, completes with **`{notificationStatus: "..."}`** (single generic variable; the per-task variable names are set via BPMN `ioMapping` — §6.2). Kinds: `ineligibility`, `additional-info`, `approval`, `denial`, `cms-forward`.

## 6. BPMN changes

**Transformation rule (applies to every script task):** replace `<bpmn:scriptTask id="…">` … `</bpmn:scriptTask>` with `<bpmn:serviceTask>` keeping the same `id`, `name`, `incoming`, `outgoing`, and replace the `<zeebe:script …/>` element with `<zeebe:taskDefinition type="…"/>` (plus task headers/ioMapping where noted below). Then run `c8ctl bpmn lint <file>`.

### 6.1 `shared/Shared_OIG_Screening.bpmn`

| Element id | type | completes with |
|---|---|---|
| `Task_ScreenOIG` | `screen-oig` | `oigCleared`, `providerRiskScore`, `oigScreening` |
| `Task_ScreenSAM` | `screen-sam` | `samCleared`, `samScreening` |
| `Task_VerifyNPI` | `verify-npi` | `npiIsActive`, `npiValidation` |
| `Task_VerifyTIN` | `verify-tin` | `tinValid`, `tinValidation` |
| `Task_VerifyLicense` | `verify-license` | `licenseValid`, `licenseValidation` |

Example (apply the same shape to the other four):

```xml
    <bpmn:serviceTask id="Task_ScreenOIG" name="Screen OIG">
      <bpmn:extensionElements>
        <zeebe:taskDefinition type="screen-oig" />
      </bpmn:extensionElements>
      <bpmn:incoming>…</bpmn:incoming>
      <bpmn:outgoing>…</bpmn:outgoing>
    </bpmn:serviceTask>
```

### 6.2 `Enrollment_Orchestrator.bpmn`

**a) Notifications → `send-notification`** (add `<zeebe:taskHeaders>` + ioMapping output):

```xml
    <bpmn:serviceTask id="Task_SendIneligibility" name="Send ineligibility notice to provider">
      <bpmn:extensionElements>
        <zeebe:taskDefinition type="send-notification">
          <zeebe:taskHeaders>
            <zeebe:taskHeader key="kind" value="ineligibility" />
          </zeebe:taskHeaders>
        </zeebe:taskDefinition>
        <zeebe:ioMapping>
          <zeebe:output source="=notificationStatus" target="ineligibilityNoticeStatus" />
        </zeebe:ioMapping>
      </bpmn:extensionElements>
      <bpmn:incoming>Flow_Eligibility_Ineligible</bpmn:incoming>
      <bpmn:outgoing>Flow_Ineligibility_End</bpmn:outgoing>
    </bpmn:serviceTask>
```

| Element id | header `kind` | ioMapping output target |
|---|---|---|
| `Task_SendIneligibility` | `ineligibility` | `ineligibilityNoticeStatus` |
| `Task_RequestAdditionalInfo` | `additional-info` | `additionalInfoRequestStatus` |
| `Task_ForwardToCMS` | `cms-forward` | `cmsForwardStatus` |
| `Task_SendApproval` | `approval` | `approvalLetterStatus` |
| `Task_SendDenial` | `denial` | `denialLetterStatus` |

**b) New `generate-doc` task** inserted between `Task_DocDetermination` and `Gateway_EnrollmentType`:

```xml
    <bpmn:serviceTask id="Task_GenerateDocumentation" name="Generate required documentation">
      <bpmn:extensionElements>
        <zeebe:taskDefinition type="generate-doc" />
      </bpmn:extensionElements>
      <bpmn:incoming>Flow_DocDetermination_GenerateDoc</bpmn:incoming>
      <bpmn:outgoing>Flow_GenerateDoc_TypeGateway</bpmn:outgoing>
    </bpmn:serviceTask>
```

Rewire: set `Task_DocDetermination`'s outgoing to `Flow_DocDetermination_GenerateDoc` (sourceRef `Task_DocDetermination`, targetRef `Task_GenerateDocumentation`), add `Flow_GenerateDoc_TypeGateway` (sourceRef `Task_GenerateDocumentation`, targetRef `Gateway_EnrollmentType`), and delete the old `Flow_DocDetermination_TypeGateway`.

**c) Fix DMN flat-input bindings** on the two business rule tasks (the form submits nested `provider.enrollmentType` but the DMNs read flat `enrollmentType`):

```xml
    <bpmn:businessRuleTask id="Task_DocDetermination" name="Determine required documentation">
      <bpmn:extensionElements>
        <zeebe:calledDecision decisionId="Enrollment_Documentation" resultVariable="documentationResult" />
        <zeebe:ioMapping>
          <zeebe:input source="=provider.enrollmentType" target="enrollmentType" />
        </zeebe:ioMapping>
      </bpmn:extensionElements>
      …incoming/outgoing unchanged…
    </bpmn:businessRuleTask>
```

```xml
    <bpmn:businessRuleTask id="Task_EligibilityCheck" name="Evaluate enrollment eligibility">
      <bpmn:extensionElements>
        <zeebe:calledDecision decisionId="Eligibility_Rules" resultVariable="eligibilityResult" />
        <zeebe:ioMapping>
          <zeebe:input source="=provider.enrollmentType" target="enrollmentType" />
        </zeebe:ioMapping>
      </bpmn:extensionElements>
      …incoming/outgoing unchanged…
    </bpmn:businessRuleTask>
```

(`Processing_Timeline` needs no fix: `submissionMethod` is already flat from the form and `siteVisitRequired` comes from `eligibilityResult`.)

### 6.3 Delegates

**`Delegate_855A.bpmn`**

| Element id | type |
|---|---|
| `Script_855A_License` | `verify-license` |
| `Script_855A_Fire` | `verify-fire-safety` |
| `Script_855A_SiteResults` | `process-site-visit` |

**`Delegate_855B.bpmn`**

| Element id | type |
|---|---|
| `Script_855B_StateLicense` | `verify-license` |
| `Script_855B_Bond` | `verify-bond` |
| `Script_855B_Equipment` | `verify-equipment` |

**`Delegate_855I.bpmn`**

| Element id | type |
|---|---|
| `Script_855I_License` | `verify-license` |
| `Script_855I_Board` | `verify-board-cert` |

### 6.4 Variable propagation (critical)

Results produced inside `Shared_OIG_Screening` and the delegates never reach `Task_EligibilityCheck` today because **every** call activity sets `propagateAllChildVariables="false"`. Flip to `"true"` on:
- `Call_855A_OIG`, `Call_855B_OIG`, `Call_855I_OIG` (in each delegate), and
- `Call_Delegate_855A`, `Call_Delegate_855B`, `Call_Delegate_855I` (in the orchestrator).

Leave `Call_*_Intake` and `Call_*_SA` at `false` (their `intakeRecord`/`referralStatus` variables stay contained).

### 6.5 Pre-flight consistency fixes (rationale recap)

Without §6.4 + §6.1 flattening + §6.2c, `Eligibility_Rules` evaluated `ELIGIBLE` for every application (its flat inputs `oigCleared`/`npiIsActive`/`enrollmentType` were never set in the orchestrator scope). These edits make the demo actually branch.

## 7. Container images & Kubernetes deployment

`deploy/services/Dockerfile` (multi-stage):

```dockerfile
FROM golang:1.22 AS build
WORKDIR /src
COPY services/go.mod services/go.sum ./
RUN go mod download
COPY services/ .
ARG SERVICE
RUN CGO_ENABLED=0 go build -o /out/app ./cmd/${SERVICE}

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
```

`deploy/services/manifests.yaml` — per service: a `Deployment` in namespace `camunda` (image `pe-workflow/<service>:latest`, 1 replica, liveness/readiness probe on the HTTP port) and an optional `Service` for manual curl. Env (identical for all five, values from the existing `c8ctl-credentials` secret):

```yaml
env:
  - name: ZEEBE_ADDRESS
    value: camunda-zeebe-gateway:26500
  - name: ZEEBE_AUTHORIZATION_SERVER_URL
    value: http://keycloak-service:18080/auth/realms/camunda-platform/protocol/openid-connect/token
  - name: ZEEBE_TOKEN_AUDIENCE
    value: orchestration
  - name: ZEEBE_CLIENT_ID
    valueFrom: { secretKeyRef: { name: c8ctl-credentials, key: client-id } }
  - name: ZEEBE_CLIENT_SECRET
    valueFrom: { secretKeyRef: { name: c8ctl-credentials, key: client-secret } }
```

Build & install:

```bash
for svc in eligibility verification scheduling documents notifications; do
  docker build --build-arg SERVICE=$svc -t pe-workflow/$svc:latest deploy/services
done
kubectl apply -f deploy/services/manifests.yaml
kubectl rollout status deployment -n camunda eligibility verification scheduling documents notifications
kubectl logs -n camunda deployment/eligibility    # expect: worker open + "connected"
```

## 8. Local development (run workers on the host)

```bash
kubectl port-forward svc/camunda-zeebe-gateway -n camunda 26500:26500   # gRPC
# plus camunda-port-forwards.sh for Keycloak (18080)
export ZEEBE_ADDRESS=localhost:26500
export ZEEBE_CLIENT_ID=zeebe-cli
export ZEEBE_CLIENT_SECRET=$(kubectl get secret c8ctl-credentials -n camunda -o jsonpath='{.data.client-secret}' | base64 -d)
export ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token
export ZEEBE_TOKEN_AUDIENCE=orchestration
go run ./cmd/verification
```

## 9. Validation sequence

```bash
# 1. Cluster reachable
./deploy/rancher-desktop/scripts/camunda-port-forwards.sh
c8ctl get topology --profile=rancher-desktop

# 2. Lint the edited BPMN
for f in workflows/855x-combined/Enrollment_Orchestrator.bpmn \
         workflows/855x-combined/delegates/*.bpmn \
         workflows/855x-combined/shared/Shared_OIG_Screening.bpmn; do
  c8ctl bpmn lint "$f" --profile=rancher-desktop
done

# 3. Redeploy resources (forms → DMN → shared → delegates → orchestrator)
c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/shared/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/delegates/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile=rancher-desktop

# 4. Run an 855I instance (no user tasks, completes end-to-end)
c8ctl run Enrollment_Orchestrator.bpmn \
  --variables='{"provider":{"enrollmentType":"855I","legalName":"Jane Doe MD","npi":"1234567893","tin":"123456789","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
c8ctl watch --profile=rancher-desktop

# 5. Run an 855A instance and complete the user tasks in Tasklist
c8ctl run Enrollment_Orchestrator.bpmn \
  --variables='{"provider":{"enrollmentType":"855A","legalName":"Main Street Clinic","npi":"1234567893","tin":"123456789","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
c8ctl open tasklist --profile=rancher-desktop   # Review Facility Application, Complete Site Visit Report

# 6. Exercise the eligibility branches
c8ctl run Enrollment_Orchestrator.bpmn --variables='{"provider":{"enrollmentType":"855I","legalName":"EXCLUDED PROVIDER","npi":"1234567893","tin":"123456789"}}' --profile=rancher-desktop  # → INELIGIBLE
# riskScore ≥ 50 (NPI ends in odd digit + empty state) → CONDITIONAL path
```

Check Operate for completed `approvalLetterStatus`/`denialLetterStatus`/`cmsForwardStatus` and `documentation.documentId`; `c8ctl search inc --profile=rancher-desktop` should be empty.

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Jobs never activate; worker idles | Port-forwards down, or `ZEEBE_TOKEN_AUDIENCE` ≠ `orchestration`, or wrong `ZEEBE_ADDRESS`. Verify with `kubectl logs`. |
| `UNAUTHENTICATED` | `zeebe-cli` secret changed — re-run `configure-c8ctl.sh` and re-read `c8ctl-credentials`. |
| Incident `FEEL_RESOLUTION_ERROR` on eligibility | Propagation not flipped (§6.4) or `enrollmentType` mapping missing (§6.2c). |
| Incident: could not be activated / no worker | Service type in BPMN doesn't match a registered `JobType`; grep types. |
| Instance stuck at `Task_GenerateDocumentation` | documents-service not deployed / `documentationResult` missing because `Task_DocDetermination` was skipped. |
| gRPC connection refused on host | Run the `26500` port-forward (not covered by `camunda-port-forwards.sh`). |

## 11. Out of scope / future

Convert `Shared_Intake` (log/tracking number) and `Shared_SA_Referral` (referral/follow-up/escalate) to service tasks; wire the orphaned `Shared_Error_Handling` process to real error-boundary events; add BPMN errors thrown via `NewThrowErrorCommand().ErrorCode(...)` from workers; add HTTP health/metrics.

---

End of plan.
