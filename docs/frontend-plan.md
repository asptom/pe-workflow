> **Note:** filesystem paths in this historical plan were updated after the `scripts/` directory restructuring; see [`dir_structure.md`](dir_structure.md).

# Front‑end & BFF Implementation Plan

## Overview
The goal is to provide a single‑page Angular application that lets users:

1. **Discover** the 855‑family processes, filter by stage, and view the current state.
2. **View** the BPMN diagram for the selected instance using *bpmn‑js*.
3. **Complete** pending user tasks (`UserTask_855A_Review`, `UserTask_855I_Review`, etc.) via the corresponding forms.
4. **Observe** the live sequence of events, including notifications for denied decisions.

The front‑end will be served by a lightweight Go back‑end (the *BFF*) that handles authentication, token refresh, and proxying to the Zeebe REST v2 API.

## Architecture
```
┌──────────────────────┐        ┌──────────────────────┐
│  Angular SPA (static)│───────▶│  Go BFF (HTTP)       │
└───────────┬──────────┘        │  (embedded files)   │
            │                    └──────────────┬───────┘
            │                               │      │
        ┌────▼─────┐                ┌──────▼──────┐
        │ Zeebe V2 │◀──────────────►│ Keycloak/OIDC│
        └──────────┘                └──────────────┘
```
*The BFF exposes endpoints that the SPA consumes via the `http` Angular `HttpClient`.*

## 1. Go BFF Skeleton
Create a new module: `services/cmd/webapp/main.go`. The BFF will:

1. **Embed** the Angular build folder using `embed.FS`.
2. **Expose** the following routes:
   * `GET /` – serves `index.html`.
   * `GET /assets/*` – serves static assets.
   * `POST /api/user-tasks/search` – forwards to `POST /v2/user-tasks/search`.
   * `POST /api/process-instances/search` – forwards to `POST /v2/process-instances/search`.
   * `GET /api/process-instances/:key` – forwards to `GET /v2/process-instances/{key}`.
   * `GET /api/process-instances/:key/sequence` – forwards to `GET /v2/process-instances/{key}/sequences`.
   * `GET /api/process-definitions/:key/xml` – forwards to `GET /v2/process-definitions/{key}/xml`.
   * `POST /api/tasks/:key/complete` – complete user task, posting the form variables.
3. **Obtain** a client‑credentials token on startup from Keycloak, using the `client-id`/`client-secret` stored in the `c8ctl-credentials` secret. Store the token and refresh it every minute.
4. **Proxy** Zeebe REST requests while adding the `Authorization: Bearer <token>` header.

**Dependencies** – Use the Zeebe Go SDK (`go get github.com/camunda/zeebe/clients/go/v2`) for helper types, but we will mostly use `net/http` for simple proxying.

## 2. Angular SPA
Create `web/` at the repo root.

### 2.1 Project scaffolding
```bash
cd web
ng new pe-frontend --routing --style=css
```
*Add only Angular core packages – no additional dependencies.*

### 2.2 Core modules
| Feature | Angular Module | Notes |
|---|---|---|
| Routing | `AppRoutingModule` | Simple paths: `/`, `/process/:id`, `/tasks` |
| BPMN Viewer | `BpmnViewerComponent` | Uses `bpmn-js` (`npm i bpmn-js@18`), `@bpmn-io/form-js-viewer@latest` |
| Task Form | `TaskFormComponent` | Dynamic form rendering, uses `FormViewer` from *form-js-viewer* |
| Process List | `ProcessListComponent` | Calls `/api/process-instances/search` |
| User Task List | `UserTaskListComponent` | Calls `/api/user-tasks/search` |
| API Service | `ApiService` | Wraps Angular `HttpClient` and adds Auth header from BFF token.

### 2.3 UI
* Use Angular Material (`ng add @angular/material`) for quick UI components.
* A top‑bar with navigation links.
* `ProcessListComponent` shows a table of running instances – click a row to navigate to `/process/:id`.
* `BpmnViewerComponent` loads the BPMN XML from `/api/process-definitions/:key/xml` and uses `bpmn-js` to render.
* `TaskFormComponent` receives the form schema from the task's `formKey` via `/api/tasks/:key/form` and renders it. The user can submit; the component posts to `/api/tasks/:key/complete`.

### 2.4 Build & Serve
In `angular.json` add:
```json
"outputPath": "../services/cmd/webapp/static",
"assets": ["src/assets", "src/favicon.ico"]
```
After `ng build --prod`, the static files will land in `../services/cmd/webapp/static`, which the Go BFF will embed.

## 3. Deployment
### 3.1 Dockerfile for BFF
In `scripts/deploy/services/Dockerfile`, add a multi‑stage build:
1. **Builder** – build the Go binary.
2. **Static** – copy Angular `dist` folder.
3. **Runtime** – copy binary and static files into a small `distroless` or `alpine` image.

```Dockerfile
# Builder
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o webapp ./services/cmd/webapp

# Serve static assets
RUN mkdir -p /usr/share/webapp/static && cp -R webapp/static/* /usr/share/webapp/static

# Runtime
FROM gcr.io/distroless/base
WORKDIR /app
COPY --from=builder /app/webapp /app
COPY --from=builder /usr/share/webapp/static /usr/share/webapp/static
CMD ["./webapp"]
```
Add the image to `scripts/deploy/services/manifests.yaml` so it deploys alongside the Zeebe gateway.

### 3.2 Helm values
Add a new section in `scripts/deploy/camunda/helm-values/values-no-domain.yml` to expose a service on port `80` (or `8081` if conflict) and a matching Ingress.

## 4. Testing & QA
| Type | Tool | Target |
|---|---|---|
| Unit | Jasmine/Karma | Angular components |
| Integration | Playwright | End‑to‑end flow: start instance → view diagram → complete a task → verify new state |
| API | Postman collection | BFF endpoints |

Create a Playwright script that:
1. Starts a local cluster using `c8ctl start`.
2. Deploys the BPMN.
3. Launches the BFF via `docker run`.
4. Uses the browser to interact with the UI.

## 5. Next Steps
1. Implement the Go BFF skeleton (generate the files, add token logic).
2. Scaffold the Angular project, generate core components.
3. Wire up API services and test locally.
4. Build Docker image and push to local registry.
5. Update Kubernetes manifests and deploy.
6. Run Playwright integration tests.

---

**Deliverables** – `services/cmd/webapp/main.go`, `web/` project, Dockerfile update, updated manifests, and a Playwright test suite.
