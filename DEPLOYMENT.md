# Deployment Guide

Single source of truth for deploying and operating the pe-workflow stack on a local
Rancher Desktop k3s cluster. Everything is driven by shell scripts under `deploy/`;
there is no Makefile.

For test scenarios, see [`docs/Testing_Guide.md`](docs/Testing_Guide.md). For the
project overview, see [`README.md`](README.md).

---

## Overview

`./deploy/deploy.sh` deploys, in order:

1. **Camunda 8 Self-Managed platform** — ECK (Elasticsearch), CloudNativePG (PostgreSQL),
   Keycloak operator, and the `camunda-platform` Helm chart (Zeebe, Operate, Tasklist,
   Identity, Optimize, Console, Web Modeler, Connectors). No ingress/domain — local
   access is via port-forward.
2. **c8ctl profile** — OIDC client, c8ctl profile `rancher-desktop`, and Zeebe
   authorizations, created by `configure-c8ctl.sh`.
3. **Worker services** — six Go microservices (eligibility, verification, scheduling,
   documents, notifications, simulator) built and applied from `deploy/services/`.
4. **Workflow resources** — forms, DMN, and BPMN artifacts deployed via `c8ctl`.
5. **Webapp** — Angular SPA compiled into the Go BFF (`services/cmd/webapp`) and rolled out.

Long-lived port-forwards are **not** managed by `deploy.sh`. Steps that need a forward
during deployment (c8ctl configuration, resource deployment) start a temporary one and
tear it down automatically. Start the long-lived helper separately for interactive use.

---

## Prerequisites

- **Rancher Desktop** with its local k3s cluster running and `kubectl` configured
- **Docker** (worker service and webapp images)
- **helm**, **envsubst** (gettext), **yq**, **openssl** (platform deployment)
- **c8ctl** (`npm install -g @camunda8/cli`)
- **Node.js 20+** and **Go** (webapp build)

Verify pinned platform versions at any time:

```bash
./deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh --check-versions
```

---

## Quick Start

```bash
# 1. Deploy the full stack. No port-forwards are required during deployment.
./deploy/deploy.sh --all

# 2. In a separate terminal, start the long-lived port-forwards for interactive use.
./deploy/rancher-desktop/scripts/camunda-port-forwards.sh
```

Then open the application at <http://localhost:8088> and check the BFF:

```bash
curl http://localhost:8088/healthz
```

> Start the port-forward helper **after** `deploy.sh` finishes. A few forwarded Services
> (for example `pe-webapp`, `pe-simulator`) only exist once their workloads are deployed;
> forwarding them earlier fails silently until they appear.

---

## Detailed Deployment Steps

### Step 1 — Deploy the Camunda platform

```bash
./deploy/deploy.sh --platform
```

Runs `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh`, which installs the
operators and the `camunda-platform` Helm chart. This step does **not** configure c8ctl
(`deploy.sh` passes `--skip-c8ctl-config`); run `--configure` next.

### Step 2 — Configure c8ctl

```bash
./deploy/deploy.sh --configure
```

Runs `configure-c8ctl.sh`: creates the `zeebe-cli` OIDC client, stores the
`c8ctl-credentials` secret, registers the `rancher-desktop` profile at
`http://localhost:8080/v2`, and creates the Zeebe authorizations. The script starts its
own temporary Keycloak and Zeebe gateway port-forwards and cleans them up when done.

### Step 3 — Deploy worker services

```bash
./deploy/deploy.sh --services
```

Builds the six Go service images and applies `deploy/services/manifests.yaml`, then rolls
out each deployment.

### Step 4 — Deploy workflow resources

```bash
./deploy/deploy.sh --resources
```

Deploys forms, DMN, shared processes, delegates, and the orchestrator via `c8ctl`. If no
forward is running on `localhost:8080`, this step starts a temporary one for the duration
of the deploy (see [Workflow artifact inventory](#workflow-artifact-inventory)).

### Step 5 — Build and deploy the webapp

```bash
./deploy/deploy.sh --webapp
```

Runs `npm ci && npm run build` in `web/` (output goes to `services/cmd/webapp/static`),
builds the `pe-workflow/webapp:latest` image, applies the manifests, and rolls out
`pe-webapp`.

### All steps at once

```bash
./deploy/deploy.sh --all
```

Equivalent to `--platform --configure --services --resources --webapp`.

---

## Access URLs

Start `./deploy/rancher-desktop/scripts/camunda-port-forwards.sh` first. All URLs are
`localhost` because the deployment uses port-forwarding, not ingress.

| Service | URL | Port-forward |
|---------|-----|--------------|
| Keycloak | http://localhost:18080/auth | `svc/keycloak-service 18080:18080` |
| Operate | http://localhost:8080/operate | `svc/camunda-zeebe-gateway 8080:8080` |
| Tasklist | http://localhost:8080/tasklist | (same as Zeebe gateway) |
| Identity | http://localhost:8080/identity | (same as Zeebe gateway) |
| Console | http://localhost:8087 | `svc/camunda-console 8087:80` |
| Optimize | http://localhost:8083 | `svc/camunda-optimize 8083:80` |
| Web Modeler | http://localhost:8070 | `svc/camunda-web-modeler-restapi 8070:80` |
| Connectors | http://localhost:8086 | `svc/camunda-connectors 8086:8080` |
| pe-webapp | http://localhost:8088 | `svc/pe-webapp 8088:8080` |
| pe-simulator | http://localhost:8186 | `svc/pe-simulator 8186:8086` |
| Zeebe gRPC | localhost:26500 | `svc/camunda-zeebe-gateway 26500:26500` |

The simulator listens on `8086` **inside** the cluster (`pe-simulator:8086`); it is exposed
on `8186` locally to avoid colliding with Connectors on `8086`.

---

## Admin Credentials

```bash
# Camunda admin password
kubectl get secret camunda-credentials -n camunda \
  -o jsonpath='{.data.identity-first-user-password}' | base64 -d

# Keycloak admin credentials
kubectl get secret keycloak-initial-admin -n camunda \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get secret keycloak-initial-admin -n camunda \
  -o jsonpath='{.data.password}' | base64 -d

# c8ctl client credentials
kubectl get secret c8ctl-credentials -n camunda \
  -o jsonpath='{.data.client-id}' | base64 -d
kubectl get secret c8ctl-credentials -n camunda \
  -o jsonpath='{.data.client-secret}' | base64 -d
```

The default Camunda user is `admin` (email `admin@camunda.local`).

---

## Partial Deployment

`deploy.sh` flags may be combined; each step is independently idempotent and safe to re-run.

| Flag | Action |
|------|--------|
| `--platform` | Camunda platform only |
| `--configure` | c8ctl profile/authorizations only |
| `--services` | Build + deploy Go workers only |
| `--resources` | Deploy workflow artifacts only |
| `--webapp` | Build + deploy Angular SPA/BFF only |
| `--all` | Everything (default) |

Examples:

```bash
./deploy/deploy.sh --resources          # re-deploy artifacts after a BPMN/DMN/form change
./deploy/deploy.sh --webapp             # rebuild and roll out the SPA after a UI change
./deploy/deploy.sh --platform --services
```

You can also call the underlying scripts directly:
`deploy/services/build-deploy.sh --services --resources` and
`deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` (which, unlike `deploy.sh`,
configures c8ctl in its final step unless `--skip-c8ctl-config` is passed).

---

## Workflow artifact inventory

`--resources` deploys the combined enrollment framework (14 artifacts) plus the
standalone 855I reference (3 artifacts) — **17 deployable artifacts** total.

The script deploys them in dependency order:

```bash
c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/shared/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/delegates/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile=rancher-desktop
```

| Group | Files |
|-------|-------|
| Forms (3) | `enrollment-start.form`, `review-validation.form`, `site-visit-report.form` |
| DMN decisions (3) | `Enrollment_Documentation.dmn`, `Eligibility_Rules.dmn`, `Processing_Timeline.dmn` |
| Shared BPMN (4) | `Shared_Intake.bpmn`, `Shared_OIG_Screening.bpmn`, `Shared_SA_Referral.bpmn`, `Error_Handling.bpmn` |
| Delegates (3) | `Delegate_855I.bpmn`, `Delegate_855A.bpmn`, `Delegate_855B.bpmn` |
| Orchestrator (1) | `Enrollment_Orchestrator.bpmn` |
| Standalone 855I (3) | `workflows/855i-single/cms855i-enrollment.bpmn`, `cms855i-enrollment.dmn`, `cms855i-start-form.form` |

Verify after deployment (port-forwards running):

```bash
c8ctl list pd --profile=rancher-desktop
c8ctl search pd --iname='*enrollment*' --profile=rancher-desktop
c8ctl open operate --profile=rancher-desktop
```

Expected process definitions: `Enrollment_Orchestrator`, `Delegate_855I`, `Delegate_855A`,
`Delegate_855B`, `Shared_Intake`, `Shared_OIG_Screening`, `Shared_SA_Referral`,
`Error_Handling` (and `cms855i-mac-enrollment` if the standalone 855I files are deployed).

To deploy **all** deployable files in one request instead (including 855i-single):

```bash
c8ctl deploy . --profile=rancher-desktop
```

---

## Local development

Run the BFF on the host (not in-cluster) and the Angular dev server separately. Forward
only Keycloak and the Zeebe REST API so port `8088` stays free for the local BFF:

```bash
kubectl port-forward svc/keycloak-service -n camunda 18080:18080
kubectl port-forward svc/camunda-zeebe-gateway -n camunda 8080:8080
```

Each `kubectl port-forward` is a blocking foreground command — run them in separate
terminals. Do **not** use `camunda-port-forwards.sh` here: it also forwards
`svc/pe-webapp` on `8088`, which would collide with the local BFF.

Export the c8ctl client credentials (see [Admin Credentials](#admin-credentials)), then:

```bash
ZEEBE_REST_ADDRESS=http://localhost:8080 \
ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token \
BFF_ADDR=:8088 \
go run ./services/cmd/webapp
```

In another terminal:

```bash
cd web && npm ci && npm start
```

The Angular dev server runs at <http://localhost:4200> and proxies `/api` to
<http://localhost:8088>. The in-cluster BFF and the local BFF are alternatives; do not
bind both to `8088` at once.

---

## Playwright tests

Full test documentation is in [`docs/Testing_Guide.md`](docs/Testing_Guide.md). Tests need
the worker services and workflow resources deployed, plus the Zeebe and Keycloak
port-forwards.

```bash
cp playwright-tests/.env.example playwright-tests/.env   # set ZEEBE_CLIENT_ID / ZEEBE_CLIENT_SECRET
cd playwright-tests
npm install
npm run install:browsers
npm test
```

The test configuration uses `BFF_URL=http://localhost:8088` and a Playwright `webServer`
on that port (`reuseExistingServer: true`). Two BFF modes, one per run:

- **Automatic local BFF** — with nothing bound to `8088`, Playwright starts
  `go run ../services/cmd/webapp`. That binary embeds the compiled Angular assets from
  `services/cmd/webapp/static`, so run `./deploy/deploy.sh --webapp` first (or at least
  `cd web && npm ci && npm run build`) or the BFF serves stale assets.
- **Deployed in-cluster BFF** — run `./deploy/deploy.sh --webapp` and let
  `camunda-port-forwards.sh` provide `localhost:8088`; Playwright reuses that server.

---

## Cleanup / Uninstall

```bash
# Uninstall the Helm release and delete the namespaces
./deploy/rancher-desktop/scripts/camunda-uninstall.sh

# Complete reset — also delete the operator CRDs
./deploy/rancher-desktop/scripts/camunda-uninstall.sh --full
```

The default uninstall removes the `camunda-platform` Helm release and deletes the
`camunda`, `elastic-system`, and `cnpg-system` namespaces (missing namespaces are ignored).
The ECK, CloudNativePG, and Keycloak operators are applied from raw manifests, so they are
removed with their namespaces; their cluster-scoped CRDs remain until `--full`.

---

## Known cluster behavior

- Zeebe 8.9.12 in this cluster does not deliver BPMN custom task headers on job activation
  (`customHeaders` is always `{}`); the services read `kind`/`force`/`phase` from job
  variables populated by ioMapping inputs instead, with headers as a fallback on
  correctly-behaving clusters.
- Rarely a job is ghost-activated (stuck `CREATED`, no incident, cannot be activated);
  cancel and re-create the process instance to recover.

Details in [`docs/Testing_Guide.md`](docs/Testing_Guide.md) §8.
