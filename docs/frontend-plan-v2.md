# Angular SPA + Go BFF Front‑end Architecture

## 1. Goal
Build a production‑ready single‑page Angular application that communicates with a lightweight Go backend (BFF). The BFF proxies all Zeebe REST v2 calls, handles authentication with Keycloak, serves static files, and ensures secure CORS. The plan covers token lifecycle, CORS strategy, error handling, dynamic form rendering, deployment (Docker, Helm, Rancher Desktop), automated Playwright tests, and additional operational details.

## 2. High‑level Architecture
```
┌───────────────────────────────┐           ┌───────────────────────┐
│  Angular SPA (static assets) │ ────────▶ │  Go BFF (HTTP)        │
└───────┬───────────────────────┘           │  (embed Angular dist) │
        │                                       │
        │                                       │
┌───────▼───────────────────────┐           │
│  Keycloak/OIDC (JWT)            │ ◀─────── │  Zeebe REST v2 API   │
└─────────────────────────────────┘           └───────────────────────┘
```
- SPA consumes the BFF via `HttpClient`. All Zeebe calls are proxied with a fresh bearer token.
- BFF exposes REST endpoints described in the *API Surface* section.
- CORS is restricted to the SPA origin.
- All sensitive secrets (client‑id, client‑secret, Keycloak URL) are injected through Helm values.

## 3. Go BFF Design

### 3.1 Project layout
```
services/
├─ cmd/
│  └─ webapp/
│     ├─ main.go
│     └─ static/  (embedded Angular build)
└─ internal/
   ├─ api/        (handler wrappers)
   ├─ auth/       (token provider)
   └─ proxy/      (Zeebe request builder)
```
### 3.2 Token Flow
1. On startup, the BFF fetches a **client‑credentials** token from Keycloak:
   ```go
   client := oauth2.NewClient(ctx, oauth2.StaticTokenSource(&oauth2.Token{AccessToken: ""}))
   token, _ := client.Token(ctx)
   ```
2. Token is cached in a thread‑safe struct and refreshed every `tokenRefreshInterval` (default 50 s). The refresh routine uses `time.Ticker` and `sync.RWMutex`.
3. All proxied requests acquire the token via `tokenProvider.GetToken(ctx)` and set `Authorization: Bearer <token>`.
4. In case of a 401 from Zeebe, the BFF immediately refreshes the token and retries once.

### 3.3 CORS Policy
- Only allow the SPA origin (`https://frontend.local`).
- Enable credentials for cookie‑based auth if needed.
- Use `github.com/rs/cors` middleware:
  ```go
  handler := cors.New(cors.Options{
      AllowedOrigins: []string{"https://frontend.local"},
      AllowedMethods: []string{"GET", "POST", "PUT", "DELETE"},
      AllowedHeaders: []string{"Authorization", "Content-Type"},
  }).Handler(router)
  ```

### 3.4 Error Handling
- Define an `apiError` type mapping HTTP status to JSON payload.
- Wrap all handler logic in a `defer` recover to catch panics and return 500.
- For Zeebe errors, map 404 to `NotFound`, 400 to `BadRequest`, others to `InternalServerError`.
- Log errors with structured fields (endpoint, method, status, error).

### 3.5 Static Asset Serving
- Use `embed.FS` to embed the `dist/` folder.
- Serve `index.html` on `/` and static assets on `/assets/*`.
- Set `Cache-Control` headers for long‑lived assets.

### 3.6 API Surface
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/process-instances` | POST | Search instances (proxy to `/v2/process-instances/search`). |
| `/api/process-instances/:key` | GET | Get instance details. |
| `/api/process-instances/:key/sequence` | GET | Retrieve sequence of events. |
| `/api/process-definitions/:key/xml` | GET | Fetch BPMN XML. |
| `/api/user-tasks` | POST | Search user tasks. |
| `/api/tasks/:key/form` | GET | Get form schema (proxy to Zeebe `formKey`). |
| `/api/tasks/:key/complete` | POST | Complete task with form variables. |
| `/health` | GET | Health check. |

## 4. Angular SPA Design

### 4.1 Project Setup
```bash
cd web
ng new pe-frontend --routing --style=css --skip-tests
```
- Add core dependencies:
  ```bash
  npm i bpmn-js@18 @bpmn-io/form-js-viewer@latest
  npm i ngx-spinner ng2-charts  # optional for UX
  ```
- Create lazy modules for major features (Process, Tasks, Forms).

### 4.2 Routing
```
/           → Dashboard (Process list)
/tasks      → UserTaskListComponent
/process/:id → ProcessDetailComponent (shows BPMN + Sequence)
```
- Use `HashLocationStrategy` if deploying behind a reverse proxy that does not support SPA routing.

### 4.3 Core Services
- **AuthService**: obtains JWT from BFF `/auth/token` (if needed for UI). Stores in `localStorage` with expiry.
- **ApiService**: wraps `HttpClient`, adds `Authorization` header via `AuthService` and handles errors (mapping to UI toast).
- **ZeebeService**: provides typed wrappers for the API surface.

### 4.4 UI Components
| Component | Responsibility |
|-----------|----------------|
| `ProcessListComponent` | Calls `ZeebeService.searchProcessInstances()`, displays in `MatTable`. |
| `ProcessDetailComponent` | Loads BPMN XML via `ZeebeService.getProcessXml()` and renders with `bpmn-js`. Displays sequence timeline. |
| `TaskFormComponent` | Receives form schema, renders dynamic form using `FormViewer` (Form JS). Submits to `completeTask()`. |
| `TaskListComponent` | Lists user tasks via `searchUserTasks()`. |
| `SpinnerComponent` | Global loading indicator. |
| `ErrorDialogComponent` | Shows error messages. |

### 4.5 Dynamic Form Rendering
- Use `@bpmn-io/form-js-viewer` which consumes Camunda Form JSON.
- The form schema is fetched from `/api/tasks/:key/form` and passed directly.
- On submit, gather form data via `FormViewer.getFormData()` and post to `/api/tasks/:key/complete`.
- Handle validation errors returned from BFF and surface them via form feedback.

### 4.6 Build & Deploy
- In `angular.json`, set output path to `../services/cmd/webapp/static`.
- Build for production:
  ```bash
  cd web
  ng build --configuration production
  ```
- The resulting `dist/pe-frontend` folder is copied into the Go project during Docker build.

## 5. Deployment Pipeline

### 5.1 Dockerfile (multi‑stage)
```
# Builder stage
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum .
RUN go mod download
COPY . .
RUN go build -o webapp ./services/cmd/webapp

# Angular build stage
FROM node:20-alpine AS frontend-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json .
RUN npm ci
COPY web .
RUN npm run build --prod

# Runtime stage
FROM gcr.io/distroless/base
WORKDIR /app
COPY --from=builder /app/webapp /app
COPY --from=frontend-builder /app/web/dist/pe-frontend /app/static
CMD ["/app/webapp"]
```
- Image tagged with Git SHA or `latest` for local dev.

### 5.2 Helm Values
Add a section in `deploy/rancher-desktop/helm-values/values-no-domain.yml`:
```yaml
bff:
  image:
    repository: myregistry/webapp
    tag: "${IMAGE_TAG}"
  service:
    type: ClusterIP
    port: 8080
  ingress:
    enabled: true
    hosts:
      - host: frontend.local
        paths:
          - path: /
            pathType: Prefix
  env:
    - name: KEYCLOAK_URL
      value: "https://keycloak.local"
    - name: KEYCLOAK_CLIENT_ID
      value: "frontend-client"
    - name: KEYCLOAK_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: keycloak-secret
          key: client-secret
```
- Ingress uses `frontend.local` for local DNS (configured in `/etc/hosts`).
- Service exposes port 8080, optionally load‑balanced.

### 5.3 Kubernetes Manifest Updates
- Deploy `services/cmd/webapp` container side by side with Zeebe gateway.
- Use `ReadinessProbe` on `/health`.
- Add `resources:` limits/requests.

## 6. Playwright Testing

### 6.1 Test Structure
```
playwright-tests/
├─ e2e/
│  ├─ start-process.spec.ts
│  ├─ view-diagram.spec.ts
│  ├─ complete-task.spec.ts
├─ playwright.config.ts
└─ utils/
    └─ zeebe.ts   # helper to start/stop local cluster and deploy BPMN
```
### 6.2 Setup
- Playwright CLI installed locally.
- `playwright install` to fetch browsers.
- Use `dotenv` to load environment variables for cluster endpoint, frontend URL, and BFF credentials.

### 6.3 Example Test
```ts
import { test, expect } from '@playwright/test';
import { startCluster, deployBpmn, stopCluster } from '../utils/zeebe';

test.beforeAll(async () => {
  await startCluster();
  await deployBpmn('processes/855-family.bpmn');
});

test.afterAll(async () => {
  await stopCluster();
});

test('start instance, complete task, verify state', async ({ page }) => {
  await page.goto('http://frontend.local');
  await page.click('text=Start 855‑family');
  await expect(page.locator('text=Process ID:')).toBeVisible();
  const pid = await page.locator('data-test=process-id').innerText();
  await page.goto(`http://frontend.local/process/${pid}`);
  await expect(page.locator('text=Active:')).toBeVisible();
  await page.click('text=Review');
  await page.fill('input[name=reviewer]', 'John');
  await page.click('text=Submit');
  await expect(page.locator('text=Completed')).toBeVisible();
});
```
### 6.4 CI Integration
- Add a job to GitHub Actions that runs Playwright tests against a local Docker‑Compose stack (Zeebe, Keycloak, BFF). Use `docker compose up --abort-on-container-exit` to orchestrate.
- Cache Playwright binaries between runs.
- Generate JUnit XML reports for badge display.

## 7. Monitoring & Logging
- BFF logs via `logrus` or `zap` in JSON format to STDOUT.
- Expose Prometheus metrics (`/metrics`) via `github.com/prometheus/client_golang/prometheus/promhttp`.
- Set up Grafana dashboards for: token refresh latency, request latency, error rates, number of active instances.
- Use `k3d` log forwarding or Loki for aggregated logs.

## 8. Security Considerations
- Store Keycloak client secret in a Kubernetes secret (`keycloak-secret`).
- Use `Strict-Transport-Security` header in Go server.
- Rotate JWT secrets via Kubernetes secret rotation.
- Limit CORS to the SPA origin only.
- Enable CSRF protection if you shift to cookie auth.

## 9. Next Steps
1. Generate the Go project structure and implement token provider.
2. Scaffold Angular app and create core modules.
3. Implement API service and token handling.
4. Write unit tests for key components.
5. Build Docker image locally and run with `docker run`.
6. Deploy Helm chart and verify UI.
7. Add Playwright test suite and run CI.
8. Iterate on UX based on feedback.

---

**Deliverables**: `services/cmd/webapp/main.go`, `web/`, Dockerfile, Helm values, Playwright tests, updated Kubernetes manifests.
