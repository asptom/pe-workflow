# Detailed Implementation Plan for Go Micro‑services

## 1. Project Setup

| Step | Command / Action | Purpose |
|------|------------------|---------|
| 1 | `mkdir -p services && cd services` | Create a dedicated services root.
| 2 | `go mod init github.com/yourorg/provider-enroll-demo` | Initialize a Go module for reproducible builds.
| 3 | `go get github.com/go-chi/chi/v5` | Pull a minimal HTTP router.
| 4 | `go get github.com/rs/zerolog` | Add structured logging.
| 5 | `mkdir k8s` | Prepare Kubernetes manifests folder.
| 6 | `mkdir .dockerignore` | Ensure only necessary files are sent to the container.

## 2. Service Skeleton (for each micro‑service)

1. **Folder** – `services/<service-name>` (e.g., `npi-verification`).
2. **Main package** – `cmd/<service-name>/main.go`.
3. **Handler** – A single HTTP `POST /process` endpoint.
4. **Request/Response structs** – Match the data Camunda sends/receives.
5. **Stub logic** – Return deterministic JSON for now.
6. **Dockerfile** – Build a slim image.
7. **K8s manifests** – Deployment & Service (ClusterIP).

### File layout for a single service
```
services
├─ npi-verification
│   ├─ cmd
│   │   └─ npi-verification
│   │       └─ main.go
│   ├─ internal
│   │   ├─ handler.go
│   │   └─ npi.go
│   ├─ Dockerfile
│   └─ k8s
│       ├─ deployment.yaml
│       └─ service.yaml
``` 

### main.go (template)
```go
package main

import (
    "context"
    "log"
    "net/http"
    "github.com/go-chi/chi/v5"
    "github.com/rs/zerolog"
    "github.com/rs/zerolog/hlog"
)

func main() {
    // Simple logger
    logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stdout}).With().Timestamp().Logger()
    // Router
    r := chi.NewRouter()
    r.Use(hlog.NewHandler(logger))
    r.Post("/process", processHandler)
    // Listen
    log.Fatal(http.ListenAndServe(":8080", r))
}
```

### handler.go (template)
```go
package internal

import (
    "encoding/json"
    "net/http"
)

func processHandler(w http.ResponseWriter, r *http.Request) {
    var req YourRequestType
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    // Stub: compute response
    resp := YourResponseType{ /* fill fields */ }
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(resp)
}
```

### Dockerfile (template)
```
# Build
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod download
RUN go build -o /bin/<service-name> ./cmd/<service-name>
# Run
FROM alpine
WORKDIR /app
COPY --from=builder /bin/<service-name> ./
EXPOSE 8080
ENTRYPOINT ["./<service-name>"]
```

## 3. Kubernetes Manifests

### deployment.yaml (template)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: provider-enroll-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
      - name: <service-name>
        image: <image-registry>/provider-enroll-demo/<service-name>:latest
        ports:
        - containerPort: 8080
```

### service.yaml (template)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: provider-enroll-demo
spec:
  selector:
    app: <service-name>
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: ClusterIP
```

## 4. External‑Task Topics (snake_case convention)

| Service | External Task Topic |
|---------|----------------------|
| NPI/TIN Verification | `verify_npi_tin` |
| Eligibility Check | `check_eligibility` |
| Document Generation | `generate_doc` |
| Site‑Visit Scheduler | `schedule_visit` |
| Notification | `send_notification` |

## 5. BPMN Integration

1. Identify each BPMN file that must call an external task:
   * `shared/Shared_OIG_Screening.bpmn` → `verify_npi_tin`
   * `Enrollment_Orchestrator.bpmn` → `check_eligibility`
   * Delegate BPMNs (`Delegate_855I.bpmn`, `Delegate_855A.bpmn`, `Delegate_855B.bpmn`) → `generate_doc` and `schedule_visit` as appropriate.
   * Any tasks requiring stakeholder emails → `send_notification`.
2. For each target, add an **External Task** element:
   * Set the **Topic** to the snake_case name.
   * Configure **Retries**: `3`.
   * Configure **Timeout**: `600000` ms (10 minutes).
3. Validate the updated BPMN:
   ```bash
   c8ctl bpmn lint <file>.bpmn
   ```
   Ensure no validation errors and that the external‑task elements are correctly referenced.
4. Deploy updated BPMNs:
   ```bash
   c8ctl deploy shared/ delegated/ Enrollment_Orchestrator.bpmn
   ```
5. Start a test instance:
   ```bash
   c8ctl run Enrollment_Orchestrator.bpmn
   ```
   Observe in `c8ctl tasklist` that the external tasks are visible and workers can pick them up.

## 6. External Task Workers

1. Use Camunda’s **Zeebe Go Client** (`github.com/camunda/zeebe/clients/go/v8`) to implement each worker:
   * The worker should subscribe to the same topic as the BPMN external task.
   * On reception, the worker calls the corresponding HTTP endpoint locally (e.g., `http://npi-verification:80/process`).
   * Pass the external task payload JSON as the request body.
   * On success, complete the task and return the response JSON as the external task variables.
   * On failure, report a failure and let Camunda retry according to the retries config.
2. Package the worker as a separate Go binary (or embed it in the service binary if preferred).
3. Deploy the worker as a Kubernetes Deployment in the same namespace, exposing the Zeebe gateway address via `ZEBE_GATEWAY` env var.

## 7. Deployment Flow

1. **Namespace creation**:
   ```bash
   kubectl create namespace provider-enroll-demo
   ```
2. **Build & push images** (replace `<registry>` with your container registry):
   ```bash
   docker build -t <registry>/provider-enroll-demo/npi-verification:latest services/npi-verification
   docker push <registry>/provider-enroll-demo/npi-verification:latest
   ```
   Repeat for all services and workers.
3. **Apply Kubernetes manifests** (in any order, services first, then workers):
   ```bash
   kubectl apply -f services/npi-verification/k8s -n provider-enroll-demo
   kubectl apply -f services/npi-verification/worker/k8s -n provider-enroll-demo
   ```
4. **Verify Pods**:
   ```bash
   kubectl get pods -n provider-enroll-demo
   ```
   All should be `Running`.

## 8. Testing & Validation

1. Deploy the BPMN artifacts as described in the Deployment Guide.
2. Trigger an instance via `c8ctl run`.
3. Use `c8ctl tasklist` to confirm external tasks are pending.
4. Watch the worker logs (`kubectl logs -f <pod>`) to see the HTTP calls and responses.
5. Once all external tasks complete, the process should finish.
6. Inspect the finished instance in Camunda Operate to ensure variables contain the expected values from each stub.

## 9. Future Enhancements

* Replace stub logic with real API calls (CMS NPI API, scheduling API, etc.).
* Add persistence (e.g., PostgreSQL) if state tracking is required.
* Add health‑check endpoints (`/healthz`) for readiness and liveness probes.
* Introduce Prometheus metrics in each service for observability.
* Create CI pipelines to build, test, and push images automatically.

---

**Notes**

* All services expose only a `ClusterIP` service; no NodePort or LoadBalancer is configured.
* Docker tags are set to `latest` for simplicity during prototyping.
* The namespace `provider-enroll-demo` isolates these prototypes from any existing workloads.
* When ready to add persistence, each service can add a `state` package that talks to a shared PostgreSQL instance.

---

End of plan.
