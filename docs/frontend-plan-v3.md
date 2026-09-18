# Angular SPA + Go BFF Front-end Architecture — v3

Status: **implementation plan (replace v2)** · Applies to Camunda 8.9 (Chart 14.6.1, Zeebe 8.9.12) on the Rancher Desktop k3s cluster in namespace `camunda`.

> v3 is a rewrite of `docs/frontend-plan-v2.md` that (a) resolves the ambiguity around browser auth, (b) aligns every deployment/networking step with this repository's concrete conventions (port-forward, no ingress), and (c) pins down the exact API surface, token mechanism, and Playwright flows against the *real* workflow artifacts. Every path referenced here was verified against the repo as of this writing.

## 1. Decisions (resolved in this plan)

| # | Fork | Decision | Rationale |
|---|------|----------|-----------|
| 1 | Browser auth | **BFF-only client-credentials. No user login.** | The BFF is the only actor that talks to Zeebe. The browser receives no token, so we drop `AuthService`, `/auth/token`, and `localStorage` entirely. This is the security-correct and simplest design for an operational UI feeding an internal demo cluster. |
| 2 | Zeebe credential | **Reuse existing `zeebe-cli` client + `c8ctl-credentials` secret.** Do **not** create a `frontend-client` client or `keycloak-secret`. | All six worker services already authenticate with `ZEEBE_CLIENT_ID`/`ZEEBE_CLIENT_SECRET` (secret keys `client-id`/`client-secret`) and audience `orchestration`. No new Keycloak bootstrap, no new secret, no `configure-c8ctl.sh` changes. |
| 3 | Exposure | **Port-forward over localhost, same-origin.** BFF on `localhost:8088`. | The cluster is deliberately no-ingress (see `values-no-domain.yml` line 22: `global.ingress.enabled: false`). Everything is reached via `camunda-port-forwards.sh`. No `/etc/hosts`, no `*.local`, no TLS, no ingress controller work. Same-origin serving makes CORS unnecessary. |
| 4 | Dashboard scope | **List running instances + "Start new" (Enrollment_Orchestrator via its start form).** | Required to make the UI usable from a browser and to make Playwright tests drive through the real UI instead of shelling out to `c8ctl`. Adds the two endpoints v2 was missing. |
| 5 | Static build into image | **Host builds Angular → embedded via `embed.FS` (v1-style); one shared Dockerfile.** | The shared `deploy/services/Dockerfile` (`ARG SERVICE`) builds all six services. Keeping the SPA build out of the Go image means the BFF is a drop-in 7th service with zero Dockerfile churn. A self-contained 3-stage alt is documented (§6.1b). |
| 6 | Routing strategy | **`PathLocationStrategy` + explicit SPA fallback in the BFF.** | BFF serves the SPA same-origin; the Go server returns `index.html` for every non-`/api` GET. No hash routing needed. |

Non-goals for this iteration: per-user identity/OIDC, multi-tenancy, ingress/TLS, user task assignment UX.

## 2. High-level Architecture

```
┌─────────────────────────────────────────┐        ┌──────────────────────────────┐
│  Browser  ── http://localhost:8088 ──▶  │        │  Go BFF (pe-webapp)          │
│  Angular SPA (embedded in BFF)          │        │  • embed.FS static assets    │
└─────────────────────────────────────────┘        │  • /api/* reverse proxy      │
        ▲  same origin, no CORS, no token           │  • x/oauth2 client-cred.     │
        │                                          │  • token → Zeebe REST        │
┌───────┴────────────────────────────┐    ┌─────────▼─────────────────────────────┐
│  kubectl port-forward svc/pe-webapp│    │  camunda-zeebe-gateway:8080           │
│  (local 8088)                      │    │  Orchestration Cluster REST API (v2) │
└────────────────────────────────────┘    └───────────────────────────────────────┘
        ...
        keycloak-service:18080  ── token endpoint (client-credentials)
```

- SPA → BFF: same origin (`localhost:8088`). No CORS, no Authorization header from the browser.
- BFF → Zeebe: every proxied call carries `Authorization: Bearer <orchestration-audience JWT>`.
- BFF → Keycloak: `POST /auth/realms/camunda-platform/protocol/openid-connect/token` using `zeebe-cli` credentials.
- In-cluster, `ZEEBE_REST_ADDRESS` defaults to `camunda-zeebe-gateway:8080`; in local dev it is `localhost:8080` (existing port-forward). Keycloak URL likewise swaps between `keycloak-service:18080` and `localhost:18080`.

## 3. Go BFF Design (`services/cmd/webapp`)

### 3.1 Project layout

```
services/
├─ cmd/
│  ├─ eligibility/ ... simulator/        # existing worker services (untouched)
│  └─ webapp/                            # NEW
│     ├─ main.go                         # wiring: router, token source, static, metrics
│     └─ static/                         # embedded Angular build (gitignored, host-built)
└─ internal/
   ├─ zeebeworker/                       # existing shared package (untouched)
   ├─ api/                               # NEW: handler wrappers + error mapping
   ├─ auth/                              # NEW: token source (x/oauth2 client-credentials)
   └─ proxy/                             # NEW: Zeebe REST request builder + 401 retry
```

Go module is the existing `github.com/pe-workflow/services` (Go 1.22). New dependency: `golang.org/x/oauth2` (already an indirect dependency in `go.mod`).

### 3.2 Token flow — use `x/oauth2`, not a hand-rolled ticker

Imports: `golang.org/x/oauth2` and `golang.org/x/oauth2/clientcredentials`.

```go
cfg := clientcredentials.Config{
    TokenURL:     os.Getenv("ZEEBE_AUTHORIZATION_SERVER_URL"),
    ClientID:     os.Getenv("ZEEBE_CLIENT_ID"),
    ClientSecret: os.Getenv("ZEEBE_CLIENT_SECRET"),
    EndpointParams: url.Values{"audience": {os.Getenv("ZEEBE_TOKEN_AUDIENCE")}},
}
source := cfg.TokenSource(context.Background()) // oauth2.ReuseTokenSource, concurrency-safe, expiry-aware
```

- `ReuseTokenSource` blocks by default, refreshes only near expiry, and is safe for concurrent `client.Get` calls — replaces the `RWMutex` + `time.Ticker` design in v2. **No ticker.**
- The `audience` form param is exactly how the existing `zeebe-client-go` provider requests `orchestration` (verified in the library source), so tokens are interchangeable with the workers'.
- Attach a token middleware: `client := source`; on request, `client.Get(ctx)` returns a `*oauth2.Token`; set `req.Header.Set("Authorization", "Bearer "+tok.AccessToken)`.
- **401 backstop:** if a proxied Zeebe call returns 401 (stale/revoked token), call `source.Token()` to force-refresh once and retry the request exactly once. On a second 401, surface the upstream error. Log both events.
- Wrap with `oauth2.WrapTokenSource` if you later want a `token_refresh` metric (§8).

> The v2 snippet (`oauth2.StaticTokenSource(&oauth2.Token{AccessToken: ""})`) is removed — it produced empty tokens and would fail on the first request.

### 3.3 CORS

**Not needed.** The BFF serves the SPA from the same origin (`localhost:8088`), so browsers never issue cross-origin requests and `rs/cors` is not required. If the SPA is ever served from a separate host, add `github.com/rs/cors` restricted to that single origin — do not blanket-enable.

### 3.4 Error handling

- `apiError{ Status int; Code string; Message string }` marshalled as JSON. Codes: `not_found`, `bad_request`, `unauthorized`, `forbidden`, `timeout`, `upstream_error`, `internal`.
- Every handler is wrapped with `defer recover()` → log + `500 internal`.
- Upstream mapping:
  - Zeebe `404` → `404 not_found`
  - Zeebe `400` (including FEEL/validation errors from completion) → `400 bad_request` **with the upstream `message` field passed through** so the SPA can render field-level feedback
  - Zeebe `401` → handled by retry logic (§3.2), else `401 unauthorized`
  - Zeebe `403` → `403 forbidden` (authorization scope problem — see §10)
  - Timeout/conn errors → `504 timeout`
  - anything else → `502 upstream_error` (do **not** leak upstream internals)
- Logging: `log/slog` (stdlib) JSON handler to STDOUT with fields `endpoint`, `method`, `status`, `error`, `request_id`. Match the stdout-JSON convention; no need for `logrus`/`zap` deps.

### 3.5 Static serving, SPA fallback, caching

- `import _ "embed"` + `//go:embed static/*` → `embed.FS`.
- Routes:
  - `GET /` → `index.html`
  - `GET /` + any non-`/api`, non-`/metrics`, non-`/healthz` GET → **SPA fallback**: serve `index.html` (this is what makes `PathLocationStrategy` deep links like `/process/:id` work). If the requested path matches an existing asset (`/assets/*`, hashed filenames), serve the asset; otherwise `index.html`.
  - `GET /assets/<hashed-name>` → long-lived: `Cache-Control: public, max-age=31536000, immutable`
  - `GET /index.html` and `/` → `Cache-Control: no-cache` (so new builds surface)
  - `GET /` fallback `index.html` → `no-cache`
- Server header: add `X-Content-Type-Options: nosniff`.

### 3.6 API surface (exact)

The BFF proxies 1:1 to the **Orchestration Cluster REST API** (Zeebe 8.9). All proxied requests carry the bearer token; the SPA is tokenses. Path params are explicit; there is no overloaded `:key`.

| BFF endpoint | Method | Proxy target (Zeebe REST) | Purpose |
|---|---|---|---|
| `/api/process-instances` | POST | `POST /v2/process-instances/search` | Search instances (dashboard table) |
| `/api/process-instances/start` | POST | `POST /v2/process-instances` | **Start** a process instance (create) |
| `/api/process-instances/{processInstanceKey}` | GET | `GET /v2/process-instances/{key}` | Instance detail |
| `/api/process-instances/{processInstanceKey}/sequences` | GET | `GET /v2/process-instances/{key}/sequences` | Sequence-flow timeline (note: **plural**; "Get sequence flows", added 8.8) |
| `/api/process-instances/{processInstanceKey}/variables` | POST | `POST /v2/process-instances/{key}/variables/search` | Fetch variables (display provider identity, etc.) |
| `/api/process-definitions` | POST | `POST /v2/process-definitions/search` | List definitions (for "Start new" picker) |
| `/api/process-definitions/{processDefinitionKey}/xml` | GET | `GET /v2/process-definitions/{key}/xml` | BPMN XML for `bpmn-js` |
| `/api/process-definitions/{processDefinitionKey}/form` | GET | `GET /v2/process-definitions/{key}/form` | **Start-event form schema** |
| `/api/user-tasks` | POST | `POST /v2/user-tasks/search` | Search user tasks |
| `/api/user-tasks/{userTaskKey}/form` | GET | `GET /v2/user-tasks/{key}/form` | User-task form schema (added 8.8) |
| `/api/user-tasks/{userTaskKey}/completion` | POST | `POST /v2/user-tasks/{key}/completion` | Complete task with variables |
| `/healthz` | GET | — | Readiness/liveness probe (matches all 6 existing services) |
| `/health` | GET | — | Alias (optional, keeps v2 wording working) |
| `/metrics` | GET | — | Prometheus (promhttp) |

Request/response bodies are passed through **unchanged**. Representative shapes (follow the spec at `docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/` for authoritative field lists):

```
POST /api/process-instances/start
→ POST /v2/process-instances
req:  { "processDefinitionKey": 456, "variables": { "provider": {...}, "submissionMethod": "PECOS" }, "tenantId": "<default>" }
resp: { "processInstanceKey": 123, "tenantId": "<default>" }

POST /api/process-instances            (search)
req:  { "filter": {}, "sort": [{ "field": "startDate", "order": "desc" }], "page": { "limit": 50 } }
resp: { "items": [ { "processInstanceKey": 123, "processDefinitionKey": 456,
                     "processDefinitionName": "CMS Provider Enrollment Orchestrator",
                     "bpmnProcessId": "Enrollment_Orchestrator",
                     "processDefinitionVersion": 1, "state": "ACTIVE",
                     "startDate": "...", "endDate": null } ], "page": { "totalItems": 12 } }

GET /api/process-definitions/{key}/xml → resp: { "xml": "<bpmn:definitions .../>" }
GET /api/process-definitions/{key}/form → resp: { "schema": "<form JSON string>" }
GET /api/user-tasks/{key}/form          → resp: { "schema": "<form JSON string>" }

POST /api/user-tasks                    (search)
req:  { "filter": { "state": "CREATED", "candidateGroup": "enrollment-reviewers" },
        "sort": [ { "field": "creationDate", "order": "asc" } ], "page": { "limit": 50 } }
resp: { "items": [ { "userTaskKey": 789, "processInstanceKey": 123,
                     "bpmnProcessId": "Delegate_855A", "elementId": "UserTask_855A_Review",
                     "name": "Review Facility Application", "state": "CREATED",
                     "candidateGroups": ["enrollment-reviewers"], "assignee": null } ], "page": {} }

POST /api/user-tasks/{key}/completion
req:  { "variables": { "approvalDecision": "Approve", "reviewComments": "ok" }, "tenantId": "<default>" }
resp: {}   // 204/200 empty
```

> Every request/response above is defined once in a checked-in OpenAPI document — see §10. That OpenAPI file is the single source of truth for both the Go handlers and the `ZeebeService` types.

### 3.7 Environment contract (BFF)

Same block the other six services use, plus two BFF-only vars. From secret `c8ctl-credentials`:

| Env var | Value (local dev) | Value (in-cluster) |
|---|---|---|
| `ZEEBE_CLIENT_ID` / `ZEEBE_CLIENT_SECRET` | from `c8ctl-credentials` | same |
| `ZEEBE_AUTHORIZATION_SERVER_URL` | `http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token` | `http://keycloak-service:18080/auth/realms/camunda-platform/protocol/openid-connect/token` |
| `ZEEBE_TOKEN_AUDIENCE` | `orchestration` | `orchestration` |
| `ZEEBE_REST_ADDRESS` | `localhost:8080` (existing port-forward) | `camunda-zeebe-gateway:8080` |
| `BFF_ADDR` | `localhost:8088` | `:8080` (container port) |
| `LOG_LEVEL` | `info` (optional) | `info` |

## 4. Angular SPA Design (`web/`)

### 4.1 Setup & pinned versions

```bash
cd web
ng new pe-frontend --routing --style=css --skip-tests
```

- **Angular 18 LTS** (or the current LTS — pin it in `package.json`). Node 20 LTS locally; the Angular CLI `ng build --configuration production` with `outputHashing: all` (default in production).
- Dependencies (pin exact versions in `package.json` for reproducibility):
  - `bpmn-js@^18.0.0`
  - `@bpmn-io/form-js-viewer@<current latest 1.x — pin the exact version you install>`
- **No `@angular/material`, no `ngx-spinner`, no `ng2-charts`.** Render tables with plain HTML + a small CSS spinner component. This removes the v2 contradiction (§4.4 referenced `MatTable` but §4.1 never installed Material) and keeps the dependency surface minimal.
- `services/cmd/webapp/static` and `web/dist` go into `.gitignore` (see §6.5).

### 4.2 Routing

```
/                    → DashboardComponent          (instance table + Start-new)
/process/:processInstanceKey → ProcessDetailComponent  (bpmn-js view + sequence timeline)
/tasks               → TaskListComponent           (user tasks for candidate groups)
```

- `PathLocationStrategy` (default). Deep links work because the BFF SPA-fallback serves `index.html` for non-`/api` GETs (§3.5). **Do not use `HashLocationStrategy`.**
- Lazy-load each feature module (dashboard, process-detail, tasks).

### 4.3 Core services

- **ApiService** — thin `HttpClient` wrapper for `/api/*`; centralizes error mapping into a typed `ApiError { code, message, status }` and feeds a global `ErrorDialogComponent`. **No auth header, no token, no localStorage** — the BFF authenticates server-side.
- **ZeebeService** — typed methods mirroring §3.6 exactly (generated/derived from the OpenAPI contract): `searchProcessInstances(filter)`, `startProcessInstance(definitionKey, variables)`, `getProcessInstance(key)`, `getSequences(key)`, `searchVariables(key, name)`, `searchProcessDefinitions()`, `getProcessXml(defKey)`, `getStartForm(defKey)`, `searchUserTasks(filter)`, `getTaskForm(taskKey)`, `completeTask(taskKey, variables)`.

### 4.4 Components

| Component | Responsibility | Notes |
|---|---|---|
| `DashboardComponent` | Instance table (search) + "Start Enrollment_Orchestrator" action | `data-test=process-id` on instance key cells. Start-new: definition picker (search defs) → load start form → open form drawer |
| `ProcessDetailComponent` | Loads BPMN XML → renders with `bpmn-js`; loads sequences → timeline; loads variables → meta panel | Highlight traversed flows from sequence data if feasible in v1; otherwise passive diagram + timeline |
| `TaskListComponent` | Lists user tasks (`state=CREATED`), click-through to form | Filter by candidate group if surfaced |
| `TaskFormComponent` | hosts `FormJS` for a task; submits to `completeTask` | See §4.5 |
| `FormModalComponent` | reused by Dashboard (start form) and TaskList (task form) | same `FormJS` host component, two data sources |
| `SpinnerComponent` | CSS-only global loading indicator | no library |
| `ErrorDialogComponent` | shows `ApiError` | |

Add `data-test` attributes on: instance key links (`data-test=process-id`), start button (`data-test=start-process`), submit buttons (`data-test=submit-form`), task rows — required by Playwright (§7).

### 4.5 Dynamic form rendering (form-js) — corrected API

- User-task form: `GET /api/user-tasks/{key}/form` → `schema` JSON string → `FormJS.fromSchema(schemaElement, schemaJson)`.
- Start form: `GET /api/process-definitions/{defKey}/form` → same host component.
- On submit, **use the viewer's submit API**, not a misremembered `getFormData()`:
  ```ts
  const result = await formJS.submit();
  // result.data → { variables }; result.errors → client-side validation map (empty if valid)
  ```
- Client-side validation: `formJS.validate()` on field blur/change; block submit when `errors` non-empty.
- **Server-side feedback strategy** (form-js viewer has no built-in server-error rendering): on `completeTask` → 400, parse `ApiError.message`; if it is a Zeebe FEEL/validation message, show it in an alert banner above the form (`data-test=form-error`) and keep the user's entered values; otherwise fall through to the global `ErrorDialogComponent`.
- After a successful completion, emit the completed event so `TaskListComponent`/`DashboardComponent` refresh their queries.

### 4.6 Build & local dev

- `angular.json` → `projects.pe-frontend.architect.build.options.outputPath: "../../services/cmd/webapp/static"` (single source of truth for the embedded build; **remove** any separate dist-copy step — fixes the v2 §4.6-vs-§5.1 contradiction).
- Dev loop (no Docker):
  1. `deploy/rancher-desktop/scripts/camunda-port-forwards.sh`
  2. run BFF locally: `ZEEBE_REST_ADDRESS=localhost:8080 ... go run ./services/cmd/webapp` on `:8088`
  3. `cd web && ng serve --proxy-config proxy.conf.json` where `proxy.conf.json` forwards `/api` → `http://localhost:8088` (Angular dev server owns the origin, so no CORS)
- Prod-ish: `ng build` → `docker build --build-arg SERVICE=webapp` (§6.1a) → serve everything from the BFF at `localhost:8088`.

## 5. Deployment

### 5.1 Docker image — one shared Dockerfile (primary)

The existing `deploy/services/Dockerfile` (`ARG SERVICE`) is used unchanged:

1. Host: `cd web && npm ci && npm run build` → emits `services/cmd/webapp/static` (gitignored).
2. `docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest -f deploy/services/Dockerfile .`
3. `COPY services/ .` already includes `static/`; `//go:embed static/*` bundles it at compile time.

Rename the generic multi-arg file note: this exact command is what §6.3's build loop runs. Add a root `Makefile` (repo currently has none) with `make build-web`, `make docker-webapp`, `make deploy-webapp` so the node→go→docker ordering cannot be forgotten.

**5.1b Alternative (self-contained single image, no host ng build):** add `deploy/services/Dockerfile.webapp` (3-stage: `node:20-alpine` builds `web/`, `golang:1.22` builds the BFF, distroless/alpine runtime). Keep it as an opt-in `.webapp` Dockerfile and **do not** restructure the shared `ARG SERVICE` Dockerfile, which the other six services depend on.

### 5.2 `deploy/services/manifests.yaml` — add `pe-webapp`

Append the standard block (namespace `camunda`, mirrors the other services):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pe-webapp
  namespace: camunda
spec:
  replicas: 1
  selector: { matchLabels: { app: pe-webapp } }
  template:
    metadata: { labels: { app: pe-webapp } }
    spec:
      containers:
        - name: webapp
          image: pe-workflow/webapp:latest
          imagePullPolicy: IfNotPresent
          ports: [{ containerPort: 8080 }]
          env:
            - name: ZEEBE_ADDRESS            # not used by webapp; kept for uniformity
              value: camunda-zeebe-gateway:26500
            - name: ZEEBE_REST_ADDRESS
              value: camunda-zeebe-gateway:8080
            - name: ZEEBE_AUTHORIZATION_SERVER_URL
              value: http://keycloak-service:18080/auth/realms/camunda-platform/protocol/openid-connect/token
            - name: ZEEBE_TOKEN_AUDIENCE
              value: orchestration
            - name: ZEEBE_CLIENT_ID
              valueFrom: { secretKeyRef: { name: c8ctl-credentials, key: client-id } }
            - name: ZEEBE_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: c8ctl-credentials, key: client-secret } }
          livenessProbe:  { httpGet: { path: /healthz, port: 8080 } }
          readinessProbe: { httpGet: { path: /healthz, port: 8080 } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata: { name: pe-webapp, namespace: camunda }
spec:
  type: ClusterIP
  selector: { app: pe-webapp }
  ports: [{ port: 8080, targetPort: 8080 }]
```

### 5.3 `deploy/services/build-deploy.sh`

Append `webapp` to `SERVICES="eligibility verification scheduling documents notifications simulator"` (line 12). The existing build/rollout loop then handles it with no other changes:

- `docker build --build-arg SERVICE=webapp ...`
- `kubectl apply -f manifests.yaml`
- `kubectl rollout restart deployment/pe-webapp -n camunda` (new deployments are taken from the manifest apply; the restart only matters for image-tag reuse, consistent with the other services).

### 5.4 Port-forward (browser reachability)

Append to `deploy/rancher-desktop/scripts/camunda-port-forwards.sh`:

```bash
# BFF / frontend (pe-webapp)
kubectl -n camunda port-forward svc/pe-webapp 8088:8080 &
```

Local port **8088** (8080 is already the Zeebe REST forward). Update the `deploy/rancher-desktop/README.md` and root `README.md` "microservice ports" table with `pe-webapp 8088` / container `8080`.

### 5.5 `.gitignore` + docs

- Add: `web/dist/`, `services/cmd/webapp/static/`, `web/node_modules/` (if not already covered), `.env` (Playwright secrets).
- Delete from this plan: all `frontend.local`, `keycloak.local`, `/etc/hosts`, ingress, TLS, `bff:`-under-camunda-helm-values, and `keycloak-secret` content — none of it applies to this repo's deployment model.

## 6. Playwright Testing

### 6.1 What the tests actually exercise

Only the **855A delegate path** has user tasks (`Delegate_855A` → `UserTask_855A_Review` with `review-validation`, `UserTask_855A_SiteVisit` with `site-visit-report`). There is **no `processes/855-family.bpmn`**; the orchestrator is `workflows/855x-combined/Enrollment_Orchestrator.bpmn` (id `Enrollment_Orchestrator`). The start form is `workflows/855x-combined/forms/enrollment-start.form` (`provider.enrollmentType`, `provider.legalName`, `provider.npi`, `provider.tin`, `submissionMethod`, `provider.filingDate`).

### 6.2 Environment assumptions (fixed vs v2)

- The Rancher Desktop k3s cluster already exists with Camunda 8.9 + Keycloak. **`c8ctl cluster start` does not exist in this repo** — do not attempt `startCluster()/stopCluster()`.
- Preconditions, run before the suite: `camunda-port-forwards.sh`; `./deploy/services/build-deploy.sh --services --resources` (deploys worker services + all BPMN/DMN/forms via c8ctl profile `rancher-desktop`).
- The BFF runs either locally (`go run`, see §4.6) or as the in-cluster `pe-webapp` behind the port-forward. Playwright's `webServer` starts the BFF locally with `reuseExistingServer: true`:
  ```js
  webServer: {
    command: 'ZEEBE_REST_ADDRESS=localhost:8080 ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token BFF_ADDR=localhost:8088 go run ./services/cmd/webapp',
    port: 8088,
    reuseExistingServer: true,
    env: { ...process.env, ZEEBE_CLIENT_ID, ZEEBE_CLIENT_SECRET /* from .env */ },
  }
  ```
- `.env` (gitignored) exports: `BFF_URL=http://localhost:8088`, `C8CTL_PROFILE=rancher-desktop`, `ZEEBE_CLIENT_ID`, `ZEEBE_CLIENT_SECRET`.

### 6.3 Structure

```
playwright-tests/
├─ e2e/
│  ├─ start-process.spec.ts     # login-free: start 855A from dashboard, assert on detail page
│  ├─ view-diagram.spec.ts      # render bpmn-js, assert a node/label + timeline loads
│  ├─ complete-task.spec.ts     # take 855A through review + site-visit forms
│  └─ helpers/instance.ts       # start instance via UI (not c8ctl), read process-id
├─ playwright.config.ts
├─ .env.example
└─ utils/zeebe.ts               # starts port-forwards? NO — only asserts cluster reachability + deploys resources via build-deploy.sh
```

### 6.4 Example spec (rewritten against real forms/flow)

```ts
import { test, expect } from '@playwright/test';
import { ensureResources } from '../utils/zeebe';

test.beforeAll(async () => {
  await ensureResources(); // runs build-deploy.sh --services --resources; throws if port-forwards down
});

test('start 855A, complete review + site-visit, verify state', async ({ page }) => {
  await page.goto('http://localhost:8088');
  await page.click('data-test=start-process');
  await page.selectOption('select[name="provider.enrollmentType"]', '855A');
  await page.fill('input[name="provider.legalName"]', 'Acme Clinic');
  await page.fill('input[name="provider.npi"]', '1234567890');   // pattern ^[0-9]{10}$
  await page.fill('input[name="provider.tin"]', '12-3456789');
  await page.selectOption('select[name="submissionMethod"]', 'PECOS');
  await page.fill('input[name="provider.filingDate"]', '2026-08-27');
  await page.click('data-test=submit-form');

  const pid = await page.locator('data-test=process-id').innerText();
  await page.goto(`http://localhost:8088/process/${pid}`);
  await expect(page.locator('text=Review Facility Application')).toBeVisible();

  // complete the review validation form
  await page.click('text=Review Facility Application');
  await page.check('input[name="approvalDecision"][value="Approve"]');
  await page.click('data-test=submit-form');
  await expect(page.locator('text=Complete Site Visit Report')).toBeVisible();

  // complete the site visit form
  await page.click('text=Complete Site Visit Report');
  await page.check('input[name="siteVerified"]');
  await page.check('input[name="fireSafetyCompliant"]');
  await page.fill('input[name="siteAddress"]', '10 Main St, Springfield');
  await page.click('data-test=submit-form');
  await expect(page.locator('data-test=form-error')).toHaveCount(0);
});
```

> Field names above come from the actual `enrollment-start.form`, `review-validation.form`, `site-visit-report.form` files. Do not invent a `reviewer` input (v2's example had one) — verify names from the checked-in forms if they drift.

### 6.5 Determinism

The `simulate-sa-review` and `simulate-cms-decision` workers are 50/50 random by default (Testing_Guide §Scenario 6). A test asserting **terminal** state (e.g. "Approved") must pass `force` as a **process variable** at start: `{"force":{"cmsDecision":"Approved"}}` merged into the start-form variables. The task-completion portion above does **not** depend on the random end-state, so it is stable as written. Do not assert on timeline labels that only appear after the SA referral timers unless you set `force`.

### 6.6 CI integration

- GitHub Actions job (`.github/workflows/playwright.yml`, new) that: checks out → sets up Node 20 + Go 1.22 → runs `build-deploy.sh --services --resources` (requires the k3s cluster; if CI can't host Rancher Desktop, run the BFF against a `docker compose` camunda stack as a parallel path — but note this repo has no compose file today, so that path is work-in-progress).
- `playwright install --with-deps`; cache the Playwright browser cache.
- `--reporter=junit` → upload XML artifact for badge display.
- Run on `pull_request` and `main`.

## 7. Monitoring & Logging

- BFF: `log/slog` JSON to STDOUT (§3.4); `promhttp` handler on `/metrics` with default Go process stats.
- Custom counters (cheap, useful): `bff_proxy_requests_total{endpoint,status}`, `bff_proxy_latency_seconds` histogram, `bff_token_refresh_total`. Wire the refresh counter via `oauth2.WrapTokenSource` around the client-credentials source (§3.2). If you skip the wrapper, drop the refresh metric — don't build it into a hand-rolled refresh loop.
- Aggregation stays as today (no Loki/Grafana yet in repo); BFF exposes `/metrics` and optional `PORT`-scoped pprof behind a build flag. Do not add Grafana dashboards to this iteration; note them as a follow-up.

## 8. Security Considerations

- Browser never holds a token; nothing is stored in `localStorage`/`sessionStorage` (except tooling state, no credentials).
- `ZEEBE_CLIENT_SECRET` only ever lives in the k8s secret `c8ctl-credentials` (server-side) or a local `.env` (dev) — never in the SPA bundle or `manifest.yaml` literal.
- Response headers: `X-Content-Type-Options: nosniff`; when TLS is eventually added, add `Strict-Transport-Security` (out of scope for localhost). No CSRF surface exists (same-origin, tokenless, JSON APIs, no cookies) — the v2 CSRF note is dropped.
- Python/Go server must not echo upstream error bodies verbatim beyond the mapped `message` (§3.4).
- CORS remains empty-allow unless the SPA is hosted separately (§3.3).

## 9. Contract-first: OpenAPI as the source of truth

Add `docs/api/bff.openapi.yaml` describing every §3.6 endpoint (paths, method, request/response body **as passthrough to Zeebe**). This is the single most important clarity artifact:

- Go handlers generated/checked against it (`github.com/deepmap/oapi-codegen` or a hand-written router mirroring it — small surface, hand-written is fine).
- TypeScript `ZeebeService` types generated or derived from it (`openapi-typescript`). No hand-maintained DTO drift between the two.

Acceptance criteria (Definition of Done for the feature):
1. `curl localhost:8088/healthz` → 200 from a freshly built image.
2. Browser can list instances, open a detail page (bpmn-js renders, timeline loads), start a new 855A enrollment from the start form.
3. Task list shows CREATED tasks for `enrollment-reviewers`; completing `review-validation` → the task vanishes and the site-visit form appears.
4. Deep link `/process/<key>` refresh works (SPA fallback; `index.html` served with `no-cache`, assets `immutable`).
5. Auth flow: `ZEEBE_CLIENT_SECRET` absent → BFF fails fast on startup (validate config), logs clear error.
6. Zeebe down → BFF returns `502 upstream_error` with the mapped body; browser shows ErrorDialog, app stays responsive.
7. Playwright suite passes twice consecutively (determinism check).
8. Image builds from a clean checkout with only `make docker-webapp` (no manual host steps hidden in prose).

## 10. Build-time verifications (do these before writing handlers)

1. **Authorizations scope:** confirm the `zeebe-cli` client's Zeebe authorizations (created by `configure-c8ctl.sh`) cover the REST v2 operations the BFF will proxy: `CREATE_PROCESS_INSTANCE`, `READ` on process instances/definitions (+ sequence flow), `READ` on user tasks, `WRITE`/`COMPLETE` on user tasks. Smoke test each proxied endpoint from a throwaway Go client before wiring the UI. If any is scoped down, extend `configure-c8ctl.sh` first.
2. **Form schema shapes:** confirm (via `curl` through the BFF) the byte-level shape of `GET /v2/process-definitions/{key}/form` and `GET /v2/user-tasks/{key}/form` on 8.9 — both return `schema` as a JSON-encoded string; verify whether `formKey`-only tasks need the form deployed (they are, in this repo) and whether `isEmbedded` or related flags appear.
3. **`GET /v2/process-instances/{key}/sequences`** response field names on 8.9 (field `sequences` vs `items`) — encode from the live response, not from memory.
4. **Completion 4xx semantics:** confirm a bad-permission completion returns 401 vs 403, and that FEEL/validation failures arrive as 400 with a structured `message` (drives §4.5 error strategy).
5. **Mic pin:** Angular 18 + `bpmn-js@18` + `form-js-viewer` under the BFF-served same-origin path once, then freeze versions in `package.json`.

## 11. Build order (task breakdown)

1. `docs/api/bff.openapi.yaml` (§9) — freeze the contract.
2. BFF skeleton: `internal/auth` (token source), `internal/proxy` (passthrough + 401 retry), `internal/api` (handlers, error mapping, SPA fallback, `embed.FS`), `/healthz`, `/metrics`. Smoke with curl (§10.1).
3. Dashboard + detail (bpmn-js + timeline) + start-new; TaskList + TaskForm (form-js) with the §4.5 error strategy; `data-test` attributes.
4. `services/cmd/webapp/static` build wiring + `Makefile`; `.gitignore` updates.
5. `pe-webapp` manifest block + `build-deploy.sh` + port-forward + README port table.
6. Playwright suite (§6) + `.github/workflows/playwright.yml`.
7. Acceptance pass against §9 checklist.

## 12. Delivered changes (delta vs v2)

- §1 decisions table: auth, credential reuse, exposure, dashboard scope, single shared Dockerfile, routing strategy.
- §3.2 token: `x/oauth2` client-credentials + 401 retry; reuses `zeebe-cli`/`c8ctl-credentials`.
- §3.3 CORS removed (same-origin).
- §3.6 API surface: +`start`, +`process-definitions` search, +`variables`, +`/healthz`; named path params; plural `/sequences`; exact Zeebe targets; passthrough JSON.
- §3.7 env contract (dev vs in-cluster).
- §4: no Material/ngx-spinner; corrected form-js submit API + server-error strategy; SPA-fallback routing; pinned versions; dev proxy path.
- §5: real deployment (manifests.yaml + build-deploy.sh + port-forward 8088), embedded static as single source of truth, `Makefile`.
- §6: Playwright against the real 855A flow with deterministic `force` vars; no fake `startCluster`.
- §9–§11: OpenAPI contract, acceptance criteria, build-time verifications, task breakdown.