> **Note:** filesystem paths in this historical plan were updated after the `scripts/` directory restructuring; see [`dir_structure.md`](dir_structure.md).

# Angular SPA + Go BFF Front-end Plan — v4

Status: **implementation plan (replaces v3)** · Applies to Camunda 8.9 (Chart 14.6.1, Zeebe 8.9.12) on the Rancher Desktop k3s cluster in namespace `camunda`.

Scope: **POC**. An **unauthenticated UI is acceptable**. Everything runs **locally only** — no CI, no GitHub Actions workflows, no ingress, no TLS.

> v4 is a polish pass over `docs/frontend-plan-v3.md`. It keeps v3's architecture but fixes its typos and technical errors:
> - Every BFF route is spelled `/api/...` (the document itself was free of `/ap`, but be alert when copying — the SPA proxy and the BFF mux must both use `/api`). `localhost` is spelled consistently; the Kubernetes namespace is `camunda` (the Keycloak *realm* is `camunda-platform` — don't mix them up); the token audience is exactly `orchestration`.
> - The form IDs pinned here are the real ones checked into the repo: `enrollment-start`, `review-validation`, `site-visit-report`.
> - The contract document lives at `docs/api/bff.openapi.yaml`.
> - The Makefile in §5 is authoritative for the webapp build and rollout; the shared `docker build --build-arg SERVICE=webapp` flow requires `make build-web` to compile static assets first (see §5.1/§5.2).
> - The port-forward entry is placed in the `FORWARDS` array (before the `wait`), not appended after it.
> - Token refresh is described via a forced-refresh mechanism: `ReuseTokenSource` has no public invalidate API, so `tokenManager` mints a single fresh token source from `clientcredentials.Config` and installs it on 401 (§3.2).
> - Security does **not** claim "no CSRF surface". It describes the POC's localhost trust boundary plus optional `Origin`/`Content-Type` hardening (§8).
> - `siteVisitOutcome` and `force` variable contracts are stated accurately against the checked-in forms and the `scheduling`/`simulator` workers (§3.6, §6.5).
> - Playwright locators use only valid forms: `getByTestId` requires a `data-testid` attribute, so we standardize on `data-test` attributes in the UI and CSS `[data-test="..."]` locators in the specs (§6.4).

## 1. Decisions

| # | Fork | Decision | Rationale |
|---|------|----------|-----------|
| 1 | Browser auth | **BFF-only client-credentials. No user login.** | The POC accepts an unauthenticated UI. The BFF is the only actor that talks to Zeebe; the browser receives no token, so we drop `AuthService`, `/auth/token`, and `localStorage` entirely. |
| 2 | Zeebe credential | **Reuse the existing `zeebe-cli` client + `c8ctl-credentials` secret.** Do **not** create a `frontend-client` client or a `keycloak-secret`. | All six worker services already authenticate with `ZEEBE_CLIENT_ID`/`ZEEBE_CLIENT_SECRET` (secret keys `client-id`/`client-secret`) against the `orchestration` audience. No new Keycloak bootstrap, no new secret, no `configure-c8ctl.sh` changes. |
| 3 | Exposure | **Port-forward over localhost, same-origin.** In-cluster BFF at `http://localhost:8088` via the port-forward; when running the BFF on the host it binds `localhost:8088` for direct browser access. | The cluster is deliberately no-ingress (`scripts/deploy/camunda/helm-values/values-no-domain.yml` sets `global.ingress.enabled: false`). Everything is reached via `camunda-port-forwards.sh`. No `/etc/hosts`, no `*.local`, no TLS, no ingress-controller work. Same-origin serving makes CORS unnecessary. |
| 4 | Dashboard scope | **List running instances + "Start new" (Enrollment_Orchestrator via its `enrollment-start` form).** | Required to make the UI usable from a browser and to make Playwright tests drive through the real UI instead of shelling out to `c8ctl`. |
| 5 | Static build into image | **Host builds Angular → embedded via `embed.FS`; one shared Dockerfile.** | The shared `scripts/deploy/services/Dockerfile` (`ARG SERVICE`) builds all six services. Keeping the SPA build out of the Go image keeps the BFF a drop-in 7th service with zero Dockerfile churn. Because the Dockerfile only runs Go, the Angular static must be built **before** the image build — the Makefile enforces this order (§5.1). |
| 6 | Routing strategy | **`PathLocationStrategy` + explicit SPA fallback in the BFF.** | The BFF serves the SPA same-origin; the Go server returns `index.html` for every non-`/api` GET. No hash routing needed. |
| 7 | Delivery process | **Local-only.** Makefile-driven build/deploy/verify; Playwright runs locally against the local cluster. **No CI/GitHub Actions in this iteration.** | POC constraint. Keeps the plan consistent with the repo's existing local-only tooling (`build-deploy.sh`, `camunda-port-forwards.sh`) and removes v3's premature `.github/workflows/playwright.yml`. |

Non-goals for this iteration: per-user identity/OIDC login, multi-tenancy, ingress/TLS, user-task assignment UX, CI pipelines.

## 2. Architecture

```
 Browser (Angular SPA)  ── http://localhost:8088 ──▶  Go BFF (pe-webapp)
   same origin, no CORS, no bearer token in the browser │
                                                        │  • embed.FS static assets
                                                        │  • /api/* routes (see §3.6)
                                                        │  • x/oauth2 client-credentials → Keycloak
                                                        │  • bearer token → Zeebe REST
                                                        ▼
                                            camunda-zeebe-gateway:8080
                                            Orchestration Cluster REST API (v2)
                                                        ▲
                 Keycloak: keycloak-service:18080 ──────┘  (token endpoint, client-credentials)
```

Two equivalent ways to reach the BFF (choose one; do not mix inside a single run):

- **In-cluster BFF:** `pe-webapp` Deployment in namespace `camunda` binds `:8080`; the browser reaches it through `kubectl port-forward svc/pe-webapp 8088:8080`. No localhost bind is involved — the port-forward owns local port `8088`, the pod owns `8080`. This is the default for day-to-day use.
- **Local (dev) BFF:** `go run ./services/cmd/webapp` on the host with `BFF_ADDR=:8088` (or `localhost:8088`); it talks to Zeebe over the existing `localhost:8080` gateway port-forward and Keycloak over `localhost:18080`. This is the Playwright `webServer` mode and the Angular dev-server proxy backend (§6.2).

Data flow:

- SPA → BFF: same origin (`localhost:8088`). No CORS, no `Authorization` header, no cookie.
- BFF → Zeebe: every proxied call carries `Authorization: Bearer <orchestration-audience JWT>`.
- BFF → Keycloak: `POST /auth/realms/camunda-platform/protocol/openid-connect/token` using the `zeebe-cli` client credentials.
- In-cluster, `ZEEBE_REST_ADDRESS` is `http://camunda-zeebe-gateway:8080` and the Keycloak URL is `http://keycloak-service:18080/...`; in local dev they are `http://localhost:8080` and `http://localhost:18080/...` (existing port-forwards).

## 3. BFF (`services/cmd/webapp`)

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
   ├─ auth/                              # NEW: token manager (x/oauth2 client-credentials)
   └─ proxy/                             # NEW: Zeebe REST request builder + 401 retry
```

Go module is the existing `github.com/pe-workflow/services` (Go 1.22). `golang.org/x/oauth2` is already an indirect dependency in `go.mod` (v0.23.0); promote it to a direct require.

### 3.2 Token flow — `x/oauth2`, with a *real* forced-refresh path

Imports: `golang.org/x/oauth2` and `golang.org/x/oauth2/clientcredentials`.

```go
cfg := clientcredentials.Config{
    TokenURL:     os.Getenv("ZEEBE_AUTHORIZATION_SERVER_URL"),
    ClientID:     os.Getenv("ZEEBE_CLIENT_ID"),
    ClientSecret: os.Getenv("ZEEBE_CLIENT_SECRET"),
    EndpointParams: url.Values{"audience": {os.Getenv("ZEEBE_TOKEN_AUDIENCE")}},
}
```

- `cfg.TokenSource(ctx)` returns an `oauth2.ReuseTokenSource`: it caches a token, refreshes only near expiry, and is concurrency-safe. **It has no public "invalidate" API, and calling `source.Token()` does not force a refresh — it returns the cached token.** So v3's "call `source.Token()` to force-refresh on 401" is wrong and is replaced below.
- The `audience` form parameter is exactly how the existing `zeebe-client-go` provider requests `orchestration`, so BFF tokens are interchangeable with the workers'.

Keep the `Config` around and wrap access in a small manager. On a `401` backstop, mint exactly one fresh `oauth2.TokenSource` from `cfg.TokenSource(ctx)` (which initializes an empty cache and executes a fresh client-credentials exchange on `.Token()`), verify it, and install that fresh source as the active source for subsequent requests:

```go
type tokenManager struct {
    mu  sync.Mutex
    cfg clientcredentials.Config
    src oauth2.TokenSource
}

func newTokenManager(cfg clientcredentials.Config) *tokenManager {
    return &tokenManager{cfg: cfg, src: cfg.TokenSource(context.Background())}
}

func (m *tokenManager) token(ctx context.Context) (*oauth2.Token, error) {
    m.mu.Lock()
    defer m.mu.Unlock()
    return m.src.Token()
}

func (m *tokenManager) forceRefresh(ctx context.Context) error {
    m.mu.Lock()
    defer m.mu.Unlock()
    freshSrc := m.cfg.TokenSource(ctx)
    if _, err := freshSrc.Token(); err != nil {
        return err
    }
    m.src = freshSrc
    return nil
}
```

- Every proxied request calls `tokenManager.token(ctx)` and sets `req.Header.Set("Authorization", "Bearer "+tok.AccessToken)`.
- **401 backstop:** if a proxied Zeebe call returns `401` (stale or revoked token), call `forceRefresh(ctx)` once and retry the request exactly once; on a second `401`, surface the upstream error. Log both events.
- For a `bff_token_refresh_total` metric, either bump a counter inside `forceRefresh` or wrap the source with `oauth2.WrapTokenSource` (which returns a caching wrapper you can count through) — see §7. Do **not** build a hand-rolled `time.Ticker` refresh loop.

> The v3 snippet (`oauth2.StaticTokenSource(&oauth2.Token{AccessToken: ""})`) is removed — it produced empty tokens and would fail on the first request.

### 3.3 CORS

**Not needed.** The BFF serves the SPA from the same origin (`localhost:8088`), so browsers never issue cross-origin requests and `rs/cors` is not required. If the SPA is ever served from a separate host, add `github.com/rs/cors` restricted to that single origin — do not blanket-enable.

### 3.4 Error handling

- `apiError{ Status int; Code string; Message string }` marshalled as JSON. Codes: `not_found`, `bad_request`, `unauthorized`, `forbidden`, `timeout`, `upstream_error`, `internal`.
- Every handler is wrapped with `defer recover()` → log + `500 internal`.
- Upstream mapping:
  - Zeebe `404` → `404 not_found`
  - Zeebe `400` (including FEEL/validation errors from completion) → `400 bad_request` **with the upstream `message` field passed through** so the SPA can render field-level feedback
  - Zeebe `401` → handled by the retry logic (§3.2), else `401 unauthorized`
  - Zeebe `403` → `403 forbidden` (authorization-scope problem — see §9)
  - Timeout/conn errors → `504 timeout`
  - anything else → `502 upstream_error` (do **not** leak upstream internals beyond the mapped `message`)
- Logging: `log/slog` (stdlib) JSON handler to STDOUT with fields `endpoint`, `method`, `status`, `error`, `request_id`. Matches the repo's stdout-JSON convention; no `logrus`/`zap` deps.

### 3.5 Static serving, SPA fallback, caching

- `import _ "embed"` + `//go:embed static/*` → `embed.FS`.
- Routes:
  - `GET /` → `index.html`
  - Any other non-`/api`, non-`/metrics`, non-`/healthz` GET → **SPA fallback**: if the path matches an existing asset (`/assets/*`, hashed filenames), serve the asset; otherwise serve `index.html` (this is what makes `PathLocationStrategy` deep links like `/process/:id` work).
  - `GET /assets/<hashed-name>` → `Cache-Control: public, max-age=31536000, immutable`
  - `GET /index.html` and `/` → `Cache-Control: no-cache` (so new builds surface)
- Server header: `X-Content-Type-Options: nosniff`.

### 3.6 API surface (exact)

The BFF proxies 1:1 to the **Orchestration Cluster REST API** (Zeebe 8.9). All proxied requests carry the bearer token; the SPA is tokenless. Path params are explicit; there is no overloaded `:key`. **All routes use the `/api` prefix.**

| BFF endpoint | Method | Proxy target (Zeebe REST) | Purpose |
|---|---|---|---|
| `/api/process-instances` | POST | `POST /v2/process-instances/search` | Search instances (dashboard table) |
| `/api/process-instances/start` | POST | `POST /v2/process-instances` | **Start** a process instance (create) |
| `/api/process-instances/{processInstanceKey}` | GET | `GET /v2/process-instances/{key}` | Instance detail |
| `/api/process-instances/{processInstanceKey}/sequences` | GET | `GET /v2/process-instances/{key}/sequences` | Sequence-flow timeline (note: **plural**; "get sequence flows", added in 8.8) |
| `/api/process-instances/{processInstanceKey}/variables` | POST | `POST /v2/process-instances/{key}/variables/search` | Fetch variables (display provider identity, etc.) |
| `/api/process-definitions` | POST | `POST /v2/process-definitions/search` | List definitions (for the "Start new" picker) |
| `/api/process-definitions/{processDefinitionKey}/xml` | GET | `GET /v2/process-definitions/{key}/xml` | BPMN XML for `bpmn-js` |
| `/api/process-definitions/{processDefinitionKey}/form` | GET | `GET /v2/process-definitions/{key}/form` | **Start-event form schema** |
| `/api/user-tasks` | POST | `POST /v2/user-tasks/search` | Search user tasks |
| `/api/user-tasks/{userTaskKey}/form` | GET | `GET /v2/user-tasks/{key}/form` | User-task form schema (added 8.8) |
| `/api/user-tasks/{userTaskKey}/completion` | POST | `POST /v2/user-tasks/{key}/completion` | Complete task with variables |
| `/healthz` | GET | — | Readiness/liveness probe (matches the existing six services) |
| `/metrics` | GET | — | Prometheus (`promhttp`) |

On successful calls, request and response bodies align directly with Zeebe REST v2 schemas without structural transformation (while upstream errors map to the structured `apiError` envelope per §3.4):

```
POST /api/process-instances/start        → POST /v2/process-instances
req:  { "processDefinitionKey": 456, "variables": { "provider": {...}, "submissionMethod": "PECOS" }, "tenantId": "<default>" }
resp: { "processInstanceKey": 123, "tenantId": "<default>" }

POST /api/process-instances              (search)
req:  { "filter": {}, "sort": [{ "field": "startDate", "order": "desc" }], "page": { "limit": 50 } }
resp: { "items": [ { "processInstanceKey": 123, "processDefinitionKey": 456,
                     "processDefinitionName": "CMS Provider Enrollment Orchestrator",
                     "bpmnProcessId": "Enrollment_Orchestrator",
                     "processDefinitionVersion": 1, "state": "ACTIVE",
                     "startDate": "...", "endDate": null } ], "page": { "totalItems": 12 } }

GET  /api/process-definitions/{key}/xml   → resp: { "xml": "<bpmn:definitions .../>" }
GET  /api/process-definitions/{key}/form  → resp: { "schema": "<form JSON string>" }
GET  /api/user-tasks/{key}/form           → resp: { "schema": "<form JSON string>" }

POST /api/user-tasks                       (search)
req:  { "filter": { "state": "CREATED" },
        "sort": [ { "field": "creationDate", "order": "asc" } ], "page": { "limit": 50 } }
resp: { "items": [ { "userTaskKey": 789, "processInstanceKey": 123,
                     "bpmnProcessId": "Delegate_855A", "elementId": "UserTask_855A_Review",
                     "name": "Review Facility Application", "state": "CREATED",
                     "candidateGroups": ["enrollment-reviewers"], "assignee": null } ], "page": {} }

POST /api/user-tasks/{key}/completion
req:  { "variables": { "approvalDecision": "Approve", "reviewComments": "ok",
                       "tenantId": "<default>" } }
resp: {}
```

**Variable contracts (verified against the repo):**

- **Review task** (`formId=review-validation` → `UserTask_855A_Review`, candidate group `enrollment-reviewers`): bind `approvalDecision` (radio, `Approve`/`Deny`) and `reviewComments` (optional). Completion `{ "approvalDecision": "Approve" }`.
- **Site-visit task** (`formId=site-visit-report` → `UserTask_855A_SiteVisit`, candidate group `site-visitors`): the form binds `siteVerified` (required checkbox), `siteAddress`, `siteVisitDate`, `deficienciesFound`, `correctiveActionPlan`, and `fireSafetyCompliant` (visible only when `provider.enrollmentType == "855A"`). The `process-site-visit` worker (`services/cmd/scheduling`) additionally reads the process variable **`siteVisitOutcome`** (`"Passed"` ⇒ `provider.siteVerified=true`, `followUpRequired=false`; anything else ⇒ follow-up). The UI must therefore submit **both**: `{ "siteVerified": true, "siteVisitOutcome": "Passed", "fireSafetyCompliant": true }` (derive `siteVisitOutcome` from `siteVerified` — `"Passed"` when checked, `"Not Passed"` otherwise). Omitting `siteVisitOutcome`, as v3's example did, silently yields a follow-up.
- **Search filter:** the two 855A tasks belong to *different* candidate groups (`enrollment-reviewers` and `site-visitors`), so the task query must not hard-code one group. Use `{ "state": "CREATED" }` and show `candidateGroups`/`elementId` in the UI instead of filtering on a single group.

> Every request/response above is defined once in the checked-in OpenAPI document — §9. That file is the single source of truth for both the Go handlers and the `ZeebeService` types.

### 3.7 Environment contract (BFF)

Same block the other six services use, plus two BFF-only vars. Credentials come from the secret `c8ctl-credentials`:

| Env var | Value (local dev BFF) | Value (in-cluster BFF) |
|---|---|---|
| `ZEEBE_CLIENT_ID` / `ZEEBE_CLIENT_SECRET` | from `c8ctl-credentials` (or local `.env`) | from `c8ctl-credentials` secret |
| `ZEEBE_AUTHORIZATION_SERVER_URL` | `http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token` | `http://keycloak-service:18080/auth/realms/camunda-platform/protocol/openid-connect/token` |
| `ZEEBE_TOKEN_AUDIENCE` | `orchestration` | `orchestration` |
| `ZEEBE_REST_ADDRESS` | `http://localhost:8080` (existing port-forward) | `http://camunda-zeebe-gateway:8080` |
| `BFF_ADDR` | `:8088` or `localhost:8088` | `:8080` (container port) |
| `LOG_LEVEL` | `info` (optional) | `info` |

Note: when the in-cluster BFF is port-forwarded to `localhost:8088`, the local BFF's `BFF_ADDR` is irrelevant — nothing binds localhost on the host for that path; the port-forward owns `localhost:8088` and forwards to the pod's `:8080` (§2).

## 4. Angular SPA (`web/`)

### 4.1 Setup & pinned versions

```bash
cd web
ng new pe-frontend --routing --style=css --skip-tests
```

- **Angular 18 LTS** (or current LTS — pin it in `package.json`). Node 20 LTS locally; production build with `outputHashing: all` (default).
- Dependencies (pin exact versions in `package.json` for reproducibility):
  - `bpmn-js@^18.0.0`
  - `@bpmn-io/form-js-viewer@<current latest 1.x — pin the exact version you install>`
- **No `@angular/material`, no `ngx-spinner`, no `ng2-charts`.** Render tables with plain HTML plus a small CSS spinner component. (v3 §4.4 referenced `MatTable` without ever installing Material — this removes that contradiction.)
- `web/dist` and `services/cmd/webapp/static` go into `.gitignore` (see §5.6).

### 4.2 Routing

```
/                           → DashboardComponent          (instance table + Start-new)
/process/:processInstanceKey → ProcessDetailComponent     (bpmn-js view + sequence timeline)
/tasks                      → TaskListComponent           (user tasks for candidate groups)
```

- `PathLocationStrategy` (default). Deep links work because the BFF SPA-fallback serves `index.html` for non-`/api` GETs (§3.5). **Do not use `HashLocationStrategy`.**
- Lazy-load each feature module (dashboard, process-detail, tasks).

### 4.3 Core services

- **ApiService** — thin `HttpClient` wrapper for `/api/*`; centralizes error mapping into a typed `ApiError { code, message, status }` and feeds a global `ErrorDialogComponent`. **No auth header, no token, no localStorage** — the BFF authenticates server-side.
- **ZeebeService** — typed methods mirroring §3.6 exactly (generated/derived from the OpenAPI contract): `searchProcessInstances(filter)`, `startProcessInstance(definitionKey, variables)`, `getProcessInstance(key)`, `getSequences(key)`, `searchVariables(key)`, `searchProcessDefinitions()`, `getProcessXml(defKey)`, `getStartForm(defKey)`, `searchUserTasks(filter)`, `getTaskForm(taskKey)`, `completeTask(taskKey, variables)`.

### 4.4 Components

| Component | Responsibility | Notes |
|---|---|---|
| `DashboardComponent` | Instance table (search) + "Start Enrollment_Orchestrator" action | `data-test="process-id"` on instance-key links. Start-new: definition picker (search defs) → load start form → open form modal |
| `ProcessDetailComponent` | Loads BPMN XML → renders with `bpmn-js`; loads sequences → timeline; loads variables → meta panel | Highlight traversed flows from sequence data if feasible in v1; otherwise passive diagram + timeline |
| `TaskListComponent` | Lists CREATED user tasks, click-through to form | Show `candidateGroups`/task `name`; do not filter by a single hard-coded group (§3.6) |
| `TaskFormComponent` | hosts `FormJS` for a task; submits to `completeTask` | Handles the task-specific completion payloads (§3.6, §4.5) |
| `FormModalComponent` | reused by Dashboard (start form) and TaskList (task form) | same `FormJS` host component, two data sources |
| `SpinnerComponent` | CSS-only global loading indicator | no library |
| `ErrorDialogComponent` | shows `ApiError` | |

Add `data-test` attributes on app-owned chrome (required by Playwright, §6.4): instance-key links (`data-test="process-id"`), start button (`data-test="start-process"`), submit buttons (`data-test="submit-form"`), the server-error banner (`data-test="form-error"`), and task rows (`data-test="task-row"`). Form-js renders its own inputs, which keep their `key` as the input `name` — those are addressed with `input[name=...]` CSS in the specs.

### 4.5 Dynamic form rendering (form-js)

- User-task form: `GET /api/user-tasks/{key}/form` → `schema` JSON string → `FormJS.fromSchema(schemaElement, schemaJson)`.
- Start form: `GET /api/process-definitions/{defKey}/form` → same host component.
- On submit, **use the viewer's submit API** (not a misremembered `getFormData()`):
  ```ts
  const result = await formJS.submit();
  // result.data → { variables }; result.errors → client-side validation map (empty if valid)
  ```
- Client-side validation: `formJS.validate()` on field blur/change; block submit when `errors` is non-empty.
- **Server-side feedback strategy** (form-js viewer has no built-in server-error rendering): on `completeTask` → `400`, parse `ApiError.message`; if it is a Zeebe FEEL/validation message, show it in an alert banner above the form (`data-test="form-error"`) and keep the user's entered values; otherwise fall through to the global `ErrorDialogComponent`.
- After a successful completion, emit the completed event so `TaskListComponent`/`DashboardComponent` refresh their queries.
- Task-specific submit mapping: for the site-visit task, include `siteVisitOutcome` derived from `siteVerified` (§3.6) before calling `completeTask`.

### 4.6 Build & local dev

- `angular.json` → `projects.pe-frontend.architect.build.options.outputPath: "../../services/cmd/webapp/static"` — single source of truth for the embedded build; **remove** any separate dist-copy step.
- Dev loop (no Docker):
  1. `scripts/deploy/camunda/scripts/camunda-port-forwards.sh`
  2. run the BFF locally: `ZEEBE_REST_ADDRESS=http://localhost:8080 ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token BFF_ADDR=localhost:8088 go run ./services/cmd/webapp`
  3. `cd web && ng serve --proxy-config proxy.conf.json` where `proxy.conf.json` forwards `/api` → `http://localhost:8088` (the Angular dev server owns the origin, so no CORS).
- Prod-ish: `make docker-webapp` → serve everything from the in-cluster BFF at `http://localhost:8088`.

## 5. Local build/deploy

### 5.1 Makefile (new, repo root) — valid syntax, real dependency ordering

The repo currently has no `Makefile`. It serves as the authoritative orchestrator for the webapp build, container image creation, and deployment. (Angular project files under `web/` are scaffolded once via `ng new` as in §4.1; the Makefile builds existing sources and enforces that the Angular build precedes container packaging):

```make
.PHONY: build-web docker-webapp deploy-webapp

build-web:
	cd web && npm ci && npm run build

docker-webapp: build-web
	docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest -f scripts/deploy/services/Dockerfile .

deploy-webapp: docker-webapp
	kubectl apply -f scripts/deploy/services/manifests.yaml
	kubectl rollout restart deployment/pe-webapp -n camunda
	kubectl rollout status deployment/pe-webapp -n camunda --timeout=180s
```

(Indentation in a `Makefile` **must** be tabs, not spaces. `docker-webapp`/`deploy-webapp` workspace dependencies are what guarantee the static build precedes the image build.)

### 5.2 Shared Dockerfile — and the clean-checkout caveat

`scripts/deploy/services/Dockerfile` (`golang:1.22` build stage → `alpine:3.20`, `COPY services/ .` then `go build ./cmd/${SERVICE}`) is used unchanged. It expects `services/cmd/webapp/static/` to already exist at `COPY` time (the BFF embeds it via `//go:embed static/*`). Because the Dockerfile does not run `npm`, **the shared Dockerfile alone cannot build a working BFF image without prior host asset generation** (`make build-web` / `npm run build`). This is why §10 acceptance criterion 8 is stated via `make docker-webapp`, not `docker build`.

**Alternative (self-contained single image, no host `ng` build):** add `scripts/deploy/services/Dockerfile.webapp` — 3-stage (`node:20-alpine` builds `web/`, `golang:1.22` builds the BFF, minimal runtime). Keep it opt-in and **do not** restructure the shared `ARG SERVICE` Dockerfile, which the other six services depend on.

### 5.3 `scripts/deploy/services/manifests.yaml` — add `pe-webapp`

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
            - name: ZEEBE_ADDRESS
              value: camunda-zeebe-gateway:26500
            - name: ZEEBE_REST_ADDRESS
              value: http://camunda-zeebe-gateway:8080
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

### 5.4 Service build & deploy sequence

`scripts/deploy/services/build-deploy.sh` remains authoritative for the six backend worker services and workflow resources (`--services`, `--resources`). **Do NOT append `webapp` to `build-deploy.sh`'s `SERVICES` list.** The shared script does not perform Node/Angular builds, and mixing the webapp into its loop would create fragile ordering dependencies.

The realistic local sequence is:
1. **Worker services & workflow resources:** run `./scripts/deploy/services/build-deploy.sh --services --resources` to build/deploy the six backend worker images and deploy BPMN, DMN, and form definitions via the c8ctl `kubernetes` profile.
2. **Webapp frontend & BFF:** run `make deploy-webapp` (which triggers `build-web` → `docker-webapp` → manifest apply and rollout) to build and deploy `pe-webapp`.
3. **Port-forwards:** run `scripts/deploy/camunda/scripts/camunda-port-forwards.sh` to expose Zeebe, Keycloak, and the webapp (`localhost:8088`).

### 5.5 Port-forward — entry in the `FORWARDS` array (before the `wait`)

Append one entry to the `FORWARDS` array in `scripts/deploy/camunda/scripts/camunda-port-forwards.sh` — **inside the array, not after the script's trailing `wait`**, so the existing launch loop (and the `PIDS` cleanup trap) pick it up:

```bash
FORWARDS=(
  "svc/keycloak-service -n $CAMUNDA_NAMESPACE 18080:18080"
  "svc/camunda-zeebe-gateway -n $CAMUNDA_NAMESPACE 8080:8080"
  "svc/pe-webapp -n $CAMUNDA_NAMESPACE 8088:8080"
)
```

Local port **8088** — it does not collide with any existing forward (18080 Keycloak, 8080 Zeebe REST/Operate, 8083 Optimize, 8070 Web Modeler, 8085 Modeler websockets, 8087 Console, 8086 Connectors). Browser URL: `http://localhost:8088`. Update `scripts/deploy/camunda/README.md` and the root `README.md` microservice port table with `pe-webapp 8088` / container `8080`.

### 5.6 `.gitignore` + docs

- Add: `web/dist/`, `services/cmd/webapp/static/`, `web/node_modules/` (if not already covered), `.env` (local Playwright env).
- Drop from this plan: all `frontend.local`/`keycloak.local`, `/etc/hosts`, ingress, TLS, `bff:`-under-camunda-helm-values, and `keycloak-secret` content — none applies to this repo's port-forward, no-ingress deployment model.

## 6. Local Playwright verification

### 6.1 What the tests actually exercise

Only the **855A delegate path** has user tasks: `Delegate_855A.bpmn` → `UserTask_855A_Review` (`formId=review-validation`, candidate group `enrollment-reviewers`) and `UserTask_855A_SiteVisit` (`formId=site-visit-report`, candidate group `site-visitors`). There is **no `processes/855-family.bpmn`**; the orchestrator is `workflows/855x-combined/Enrollment_Orchestrator.bpmn` (id `Enrollment_Orchestrator`) with start form `workflows/855x-combined/forms/enrollment-start.form` (`provider.enrollmentType`, `provider.legalName`, `provider.npi`, `provider.tin`, `submissionMethod`, `provider.filingDate`).

### 6.2 Environment assumptions (local-only)

- The Rancher Desktop k3s cluster already exists with Camunda 8.9 + Keycloak. **`c8ctl cluster start` does not exist in this repo** — do not attempt `startCluster()/stopCluster()`.
- Preconditions, run before the suite: `scripts/deploy/camunda/scripts/camunda-port-forwards.sh`; `./scripts/deploy/services/build-deploy.sh --services --resources` (deploys worker services + all BPMN/DMN/forms via the c8ctl `kubernetes` profile).
- **Two BFF topologies** (pick one per run; do not mix):
  - *In-cluster BFF:* `make deploy-webapp`, then `kubectl port-forward svc/pe-webapp 8088:8080` (either via `camunda-port-forwards.sh` §5.5 or ad hoc). Playwright's `baseURL` is `http://localhost:8088`. No local BFF process, so no localhost bind is needed — the port-forward owns `localhost:8088`.
  - *Local BFF (Playwright `webServer`):* run `go run ./services/cmd/webapp` on the host bound to `:8088` with `webServer.reuseExistingServer: true` — then either this local instance OR an already-port-forwarded in-cluster one can answer on `localhost:8088`:
    ```js
    webServer: {
      command: 'ZEEBE_REST_ADDRESS=http://localhost:8080 ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token BFF_ADDR=:8088 go run ./services/cmd/webapp',
      port: 8088,
      reuseExistingServer: true,
      env: { ...process.env, ZEEBE_CLIENT_ID: process.env.ZEEBE_CLIENT_ID, ZEEBE_CLIENT_SECRET: process.env.ZEEBE_CLIENT_SECRET },
    },
    ```
- `.env` (gitignored) exports: `BFF_URL=http://localhost:8088`, `C8CTL_PROFILE=kubernetes`, `ZEEBE_CLIENT_ID`, `ZEEBE_CLIENT_SECRET`.

### 6.3 Structure

```
web/tests/
├─ e2e/
│  ├─ start-process.spec.ts     # login-free: start 855A from the dashboard, assert on the detail page
│  ├─ view-diagram.spec.ts      # render bpmn-js, assert a node/label + timeline loads
│  ├─ complete-task.spec.ts     # take 855A through review + site-visit forms
│  └─ helpers/instance.ts       # start instance via UI (not c8ctl), read the process id
├─ playwright.config.ts
├─ .env.example
└─ utils/zeebe.ts               # NO port-forward start/stop — only asserts cluster reachability
```

### 6.4 Example spec (valid selectors, real forms/flow)

Playwright locator rules: `getByTestId(...)` matches `data-testid` by default, so it will **not** find `data-test` attributes. We standardize on `data-test` attributes in the UI and address them with explicit CSS `[data-test="..."]` in specs; form-js inputs are addressed by their `key`-derived `name` attributes. Text is matched with `getByRole`/`getByText`, not the legacy `text=...` engine.

```ts
import { test, expect } from '@playwright/test';
import { ensureResources } from '../utils/zeebe';

test.beforeAll(async () => {
  await ensureResources();
});

test('start 855A, complete review + site-visit, verify state', async ({ page }) => {
  await page.goto('http://localhost:8088');
  await page.click('[data-test="start-process"]');
  await page.selectOption('select[name="provider.enrollmentType"]', '855A');
  await page.fill('input[name="provider.legalName"]', 'Acme Clinic');
  await page.fill('input[name="provider.npi"]', '1234567890');
  await page.fill('input[name="provider.tin"]', '12-3456789');
  await page.selectOption('select[name="submissionMethod"]', 'PECOS');
  await page.fill('input[name="provider.filingDate"]', '2026-08-27');
  await page.click('[data-test="submit-form"]');

  const pid = await page.locator('[data-test="process-id"]').innerText();
  await page.goto(`http://localhost:8088/process/${pid}`);
  await expect(page.getByText('Review Facility Application')).toBeVisible();

  await page.click('text=Review Facility Application');
  await page.check('input[name="approvalDecision"][value="Approve"]');
  await page.click('[data-test="submit-form"]');
  await expect(page.getByText('Complete Site Visit Report')).toBeVisible();

  await page.click('text=Complete Site Visit Report');
  await page.check('input[name="siteVerified"]');
  await page.check('input[name="fireSafetyCompliant"]');
  await page.fill('input[name="siteAddress"]', '10 Main St, Springfield');
  await page.click('[data-test="submit-form"]');
  await expect(page.locator('[data-test="form-error"]')).toHaveCount(0);
});
```

> Field names come from the actual `enrollment-start.form`, `review-validation.form`, and `site-visit-report.form`. Do not invent inputs (e.g. v2's bogus `reviewer` field). Also note the `site-visit-report` form requires `siteVerified` and derives `siteVisitOutcome` — the completion payload must include both (§3.6). If the selectors above start to drift, verify them against the checked-in forms first.
> Portability: use `page.click('text=...')` only where a unique visible element exists; prefer `[data-test="..."]` for anything ambiguous.

### 6.5 Determinism

- The `simulate-sa-review` and `simulate-cms-decision` workers are 50/50 random by default (`Testing_Guide` §7).
- **`force` contract (verified in `services/cmd/simulator/main.go`):** a single top-level process variable `force` is read by *both* workers, so one variable powers only one worker per run:
  - `"responded"` / `"timeout"` ⇒ the SA/AO review outcome (`saAoResponseReceived`).
  - `"Approved"` / `"Denied"` ⇒ the CMS decision (`cmsDecision`).
  - Any other value (including using `force` for one worker and leaving "random" for the other) means that worker stays random.
- For a deterministic **terminal** state (e.g. `cmsDecision=Approved`), start the instance with `{"force":"Approved"}` merged into the start-form variables. That forces only the CMS leg; the SA review leg is *timing*-nondeterministic but always settles (initial response or the 3-second follow-up path), so the final `Approved` state is stable. **Do not assert timeline labels that only appear on a specific SA-referral sub-path** unless you accept that timing variance.
- The task-completion portion above never reaches the CMS decision, so it is stable **without** any `force` variable — start it without `force` to keep the two user tasks on the happy path.
- Run the suite twice consecutively as a determinism check (§10 item 7).

## 7. Monitoring

- BFF: `log/slog` JSON to STDOUT (§3.4); `promhttp` handler on `/metrics` with default Go process stats.
- Custom counters (cheap, useful): `bff_proxy_requests_total{endpoint,status}`, `bff_proxy_latency_seconds` histogram, `bff_token_refresh_total` (bump inside `forceRefresh`, §3.2 — do not build a hand-rolled refresh loop to measure it).
- Aggregation stays as today (no Loki/Grafana yet in the repo); the BFF exposes `/metrics` and optional `PORT`-scoped pprof behind a build flag. No Grafana dashboards this iteration — note them as a follow-up.

## 8. Security

- Browser never holds a token; no credentials in `localStorage`/`sessionStorage`.
- `ZEEBE_CLIENT_SECRET` only ever lives in the k8s secret `c8ctl-credentials` (server-side) or a local `.env` (dev) — never in the SPA bundle or a `manifest.yaml` literal.
- Response headers: `X-Content-Type-Options: nosniff`. When TLS is eventually added (out of scope for localhost), also add `Strict-Transport-Security`.
- **Localhost trust boundary (POC):** this deployment is a single-user UI on `localhost:8088`, with no login and no cookies. There is no authenticated session an attacker could hijack, so the classic session-cookie CSRF vector does not apply. But we do **not** claim "no CSRF surface": a hostile page in the same browser could still attempt requests *at* `http://localhost:8088` (cross-origin) to a localhost service, so add light defense-in-depth on state-changing `/api` POSTs:
  - If an `Origin` header is present, reject unless it is an allowed origin: `http://localhost:8088` and the Angular dev-server origin `http://localhost:4200`.
  - Require `Content-Type: application/json` (or an equivalent non-form content type) on those POSTs — a cross-origin HTML form cannot set that header without a preflight.
  - These are POC hardening on top of the localhost-only deployment, not a substitute for real authentication, which remains a non-goal in this iteration.
- The BFF must not echo upstream error bodies verbatim beyond the mapped `message` (§3.4).
- CORS remains empty-allow unless the SPA is ever hosted separately (§3.3).

## 9. Contract — OpenAPI as the source of truth

Add **`docs/api/bff.openapi.yaml`** describing every §3.6 endpoint (paths, methods, request/response bodies conforming to Zeebe REST v2 and BFF error envelopes). This is the single most important clarity artifact:

- Go handlers generated/checked against it (`github.com/deepmap/oapi-codegen` or a hand-written router mirroring it — small surface, hand-written is fine).
- TypeScript `ZeebeService` types generated or derived from it (`openapi-typescript`). No hand-maintained DTO drift between the two.

**Authorizations scope (verify before writing handlers):** the `zeebe-cli` client authorizations created by `configure-c8ctl.sh` must cover the REST v2 operations the BFF proxies: `CREATE_PROCESS_INSTANCE`, `READ` on process instances/definitions (+ sequence flow), `READ` on user tasks, `WRITE`/`COMPLETE` on user tasks. Smoke-test each proxied endpoint from a throwaway Go client before wiring the UI. If any is scoped down, extend `configure-c8ctl.sh` first.

## 10. Acceptance criteria

Definition of Done for the feature:

1. `curl http://localhost:8088/healthz` → 200 from a freshly built image.
2. Browser can list instances, open a detail page (bpmn-js renders, timeline loads), start a new 855A enrollment from the `enrollment-start` form.
3. Task list shows CREATED tasks for `enrollment-reviewers` and `site-visitors`; completing `review-validation` makes that task vanish and the `site-visit-report` task appear; completing it with `siteVerified=true` + `siteVisitOutcome="Passed"` removes it.
4. Deep link `/process/<key>` — refresh works (SPA fallback; `index.html` served `no-cache`, assets `immutable`).
5. Auth fail-fast: `ZEEBE_CLIENT_SECRET` absent → BFF fails fast on startup (validate config), logs a clear error.
6. Zeebe down → BFF returns `502 upstream_error` with the mapped body; browser shows `ErrorDialog`, app stays responsive.
7. Playwright suite passes twice consecutively (determinism check, §6.5).
8. **With `web/` sources present, `make docker-webapp` produces a working BFF image** — the Makefile first runs the Angular host build before image compilation (§5.1/§5.2). This is stated via the Makefile target, not a bare `docker build`, because the shared Dockerfile alone embeds whatever static assets exist on disk.
9. Local-only: no CI/GitHub Actions introduced; all verification steps run on the workstation against the Rancher Desktop cluster.

## 11. Build order

1. `docs/api/bff.openapi.yaml` (§9) — freeze the contract.
2. BFF skeleton: `internal/auth` (token manager, §3.2), `internal/proxy` (request forwarding + 401 retry), `internal/api` (handlers, error mapping §3.4, SPA fallback §3.5, `embed.FS`), `/healthz`, `/metrics` (§7). Smoke with curl (§9 authorizations check).
3. Angular SPA in `web/` (§4.1): Dashboard + detail (bpmn-js + timeline) + start-new; TaskList + TaskForm (form-js) with the §4.5 error strategy and §3.6 completion payloads; `data-test` attributes (§6.4).
4. `services/cmd/webapp/static` build output wiring (§4.6) + root `Makefile` (§5.1); `.gitignore` updates (§5.6).
5. `pe-webapp` manifest block in `scripts/deploy/services/manifests.yaml` (§5.3) + port-forward array entry in `camunda-port-forwards.sh` (§5.5) + README port table. Deploy backend worker services and resources via `build-deploy.sh` and webapp via Makefile (`make deploy-webapp`, §5.4).
6. Playwright suite (§6) run locally.
7. Acceptance pass against §10.

## 12. Assumptions

- **POC scope:** an **unauthenticated UI is acceptable** for this iteration; no user login, no OIDC, no per-user identity.
- **Local-only operation:** everything runs against the Rancher Desktop k3s cluster on this workstation; **no CI/GitHub workflows** are added.
- The cluster already exists with Camunda 8.9 + Keycloak; `c8ctl cluster start` is not used anywhere.
- The `zeebe-cli` OIDC client already exists with the `orchestration` audience, its credentials live in the `c8ctl-credentials` secret in namespace `camunda`, and its Zeebe authorizations cover the REST v2 operations the BFF needs (verify in §9).
- The workflow artifacts (forms, DMN, BPMN) are deployed via `build-deploy.sh --resources` / c8ctl profile `kubernetes` before the Playwright suite runs.
- No ingress/TLS; reachability is exclusively via `camunda-port-forwards.sh` (`localhost:8088` for the BFF).
- The shared `scripts/deploy/services/Dockerfile` stays as-is (no node stage); the Angular static is host-built and embedded — enforced by the new Makefile.
- Form field names and form IDs match the checked-in files: `enrollment-start`, `review-validation`, `site-visit-report`; `siteVerified`/`siteVisitOutcome` and `force` follow the contracts in §3.6/§6.5.
