# Deployment Update Plan

Consolidate all deployment into shell scripts, eliminate the Makefile, fix existing issues, and produce a single authoritative `DEPLOYMENT.md`.

---

## Current State (As-Is)

Deployment is split across **two mechanisms** with overlapping responsibilities:

| Mechanism | What it does | Location |
|-----------|-------------|----------|
| **Makefile** (3 targets) | `build-web` — runs `npm ci && npm run build` in `web/`<br>`docker-webapp` — builds the Go BFF + Angular SPA Docker image<br>`deploy-webapp` — applies k8s manifests, restarts `pe-webapp` deployment | `/Makefile` (12 lines) |
| **Shell scripts** (6 scripts) | `camunda-deploy-no-domain.sh` — deploys Camunda platform stack (Elasticsearch, PostgreSQL, Keycloak, Helm chart)<br>`configure-c8ctl.sh` — creates OIDC client, c8tl profile, Zeebe authorizations<br>`camunda-port-forwards.sh` — starts 8 port-forward processes<br>`build-deploy.sh` — builds 6 Go service Docker images, applies manifests, rollout restarts per deployment<br>`camunda-uninstall.sh` — deletes namespaces (incomplete cleanup)<br>`set-secrets.sh` — creates PostgreSQL secrets | `deploy/rancher-desktop/scripts/` and `deploy/services/` |

**Inconsistencies:**
- The Makefile handles webapp build/deploy while shell scripts handle everything else. There is no single entry point to deploy the full stack.
- The README.md references `make build-web`, `make docker-webapp`, and `make deploy-webapp` directly — these targets duplicate logic already in shell scripts.
- The root README.md, `deploy/rancher-desktop/README.md`, and `docs/Deployment_Guide.md` each cover different parts of deployment with no single source of truth.
- `docs/Deployment_Guide.md` covers workflow artifact deployment (forms, DMN, BPMN) — a subset of what `build-deploy.sh --resources` already does.

**Critical port-forward behavior:** Port-forwards started by `camunda-port-forwards.sh` are child processes of the script. When the script exits (Ctrl+C or normal termination), all port-forwards are killed. They do **not** survive after the script ends. This is why you run them separately — to keep them alive independently of any deployment or management script.

---

## Target State (To-Be)

All deployment is performed by shell scripts. The Makefile is removed. A single `DEPLOYMENT.md` at the repository root describes every step to get a complete working environment deployed. All existing issues (port collision, incomplete uninstall, dead code) are fixed as part of this consolidation.

---

## Step-by-Step Plan

### Phase 1: Fix existing scripts before consolidation

Before creating the unified script, fix the issues in existing scripts so they are correct when called.

#### 1a. Fix port-forward collision (8086)

**File:** `deploy/rancher-desktop/scripts/camunda-port-forwards.sh` (update)

The simulator service (`pe-simulator`) and the Camunda Connectors component both map to `localhost:8086` when port-forwarded simultaneously. The simulator is a user-deployed service; Connectors is part of the Camunda Helm chart.

**Fix:** Change the simulator port-forward to use `8186` instead of `8086`. The simulator's in-cluster Service already exposes port 8086 internally — the port-forward only maps to localhost. Update:
- The `kubectl port-forward` line for `pe-simulator` from `8086:8086` to `8186:8086`.
- The README.md access URLs table (both root and `deploy/rancher-desktop/README.md`) to show simulator at `localhost:8186`.
- Any documentation or scripts referencing the simulator port.

This is a non-breaking change for in-cluster communication (services talk to `pe-simulator:8086` internally). Only localhost access changes.

#### 1b. Fix incomplete uninstall script

**File:** `deploy/rancher-desktop/scripts/camunda-uninstall.sh` (update)

The current script only deletes namespaces (`elastic-system`, `cnpg-system`, `camunda`). It does not uninstall Helm releases or operator CRDs. On re-deployment, orphaned Helm releases with stale values cause conflicts.

**Fix:** Add proper cleanup steps before namespace deletion:
```bash
# Uninstall Helm releases first (so CRs are cleaned up before namespace deletion)
helm uninstall camunda -n camunda 2>/dev/null || true
helm uninstall keycloak-operator 2>/dev/null || true

# Delete namespaces (this removes remaining CRs and resources)
kubectl delete namespace elastic-system cnpg-system camunda --ignore-not-found

# Optionally remove operator CRDs (aggressive — only if a full reset is desired)
# kubectl delete crd elasticsearches.elastic.co 2>/dev/null || true
# kubectl delete crd postgresclusters.postgresql.crunchydata.com 2>/dev/null || true
# kubectl delete crd keycloaks.org.keycloak.org 2>/dev/null || true
```

The CRD deletion lines are commented by default. Add a `--full` flag to uncomment and execute them for a complete reset.

#### 1c. Remove dead authorization initializer from Helm values

**File:** `deploy/rancher-desktop/helm-values/values-no-domain.yml` (update)

The Helm chart declares an authorization initializer for the `zeebe-cli` client, but this initializer only runs at first startup — before the `zeebe-cli` client exists (it is created by `configure-c8ctl.sh`). The authorization config in the Helm values is therefore dead code; `configure-c8ctl.sh` recreates all authorizations via the REST API on every run.

**Fix:** Remove the authorization initializer block from `values-no-domain.yml`. The authorizations are correctly created by `configure-c8ctl.sh` via the REST API. This eliminates confusion and ensures a clean re-deployment without stale authorization config.

#### 1d. Pin Helm chart and operator versions consistently

**File:** `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` (update)

Helm chart version (`14.6.1`) and operator versions (ECK `3.4.1`, CNPG `1.30.0`) are embedded directly in the script. If another script or documentation references different versions, upgrades become error-prone.

**Fix:** Extract all version constants to the top of `camunda-deploy-no-domain.sh` in a clearly labeled block. Ensure all other scripts that reference these versions (e.g., Helm values files) use the same constants or document their version independently. Add a `--check-versions` flag that prints all versions for verification.

---

### Phase 2: Create the unified deployment script

**File:** `deploy/deploy.sh` (new)

A single entry-point shell script that orchestrates the entire deployment in order. This script calls existing scripts (now fixed) and wraps Makefile logic as shell commands.

**Critical design decision: Port-forwards are NOT started by this script.** Because port-forwards die when the script exits (they are foreground child processes), `deploy/deploy.sh` does NOT start them. Users must start port-forwards separately before running any c8ctl commands (which is the current workflow).

**What it does (in order):**

1. **Prerequisites check** — verifies `kubectl`, `docker`, `helm`, `c8ctl`, `envsubst`, `yq`, `openssl` are available. Exits with a clear error if any are missing.

2. **Deploy Camunda platform** — calls `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` (now with fixed uninstall and version pinning).

3. **Configure c8ctl** — calls `deploy/rancher-desktop/scripts/configure-c8ctl.sh` (now with dead code removed from Helm values).

4. **Deploy worker services** — calls `deploy/services/build-deploy.sh --services` (existing script, no changes needed).

5. **Deploy workflow resources** — calls `deploy/services/build-deploy.sh --resources` (existing script, no changes needed).

6. **Build and deploy webapp** — replaces the 3 Makefile targets (`build-web`, `docker-webapp`, `deploy-webapp`) with inline shell commands:
   ```bash
   cd web && npm ci && npm run build
   docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest -f deploy/services/Dockerfile .
   kubectl apply -f deploy/services/manifests.yaml
   kubectl rollout restart deployment/pe-webapp -n camunda
   kubectl rollout status deployment/pe-webapp -n camunda --timeout=180s
   ```

**Design decisions:**
- The script accepts flags: `--platform` (deploy Camunda only), `--services` (deploy worker services only), `--resources` (deploy workflow resources only), `--webapp` (build and deploy webapp only), `--all` (default, everything). This mirrors the existing `build-deploy.sh` flag pattern.
- The script is idempotent where possible — re-running it after a partial failure resumes from the last completed step.
- The script prints clear status messages and error codes so users know exactly where things stand.
- **Port-forwards are explicitly NOT managed by this script.** The documentation clearly states that users must start `camunda-port-forwards.sh` separately and keep it running.

---

### Phase 3: Create `DEPLOYMENT.md` at repository root

**File:** `/DEPLOYMENT.md` (new)

A comprehensive, single-source-of-truth document describing every step to deploy and operate the complete environment. Structure:

1. **Overview** — What this project deploys (Camunda 8 platform, Go microservices, Angular SPA via Go BFF).
2. **Prerequisites** — All tools required (Rancher Desktop k3s, Docker, kubectl, helm, envsubst, yq, openssl, c8ctl, Node.js 20+, Go).
3. **Quick Start** — Two commands: start port-forwards, then run `./deploy/deploy.sh --all`.
4. **Detailed Deployment Steps** — Each step with explanation:
   - Step 1: Start port-forwards (separate terminal, keep running)
   - Step 2: Deploy Camunda Platform (operators, Elasticsearch, PostgreSQL, Keycloak, Helm chart)
   - Step 3: Configure c8ctl (OIDC client, profile, authorizations)
   - Step 4: Deploy worker services (6 Go microservices)
   - Step 5: Deploy workflow resources (BPMN, DMN, forms)
   - Step 6: Build and deploy webapp (Angular SPA + Go BFF)
5. **Access URLs** — Table of all services with port-forwarded localhost URLs (updated for simulator at 8186).
6. **Admin Credentials** — How to retrieve Camunda admin and Keycloak admin passwords.
7. **Partial Deployment** — How to deploy individual components using flags (`--platform`, `--services`, `--resources`, `--webapp`).
8. **Local Development** — How to run the BFF locally and Angular separately (from root README.md).
9. **Playwright Tests** — How to run tests (from root README.md, condensed).
10. **Cleanup / Uninstall** — How to tear down the deployment (`deploy/rancher-desktop/scripts/camunda-uninstall.sh`), including the `--full` flag for complete reset.
11. **Known Cluster Behavior** — Zeebe customHeaders bug, ghost-activated jobs (from root README.md).

This document replaces the deployment content currently scattered across:
- Root `README.md` (Quick Start, Local Development, Playwright tests, Known cluster behavior)
- `deploy/rancher-desktop/README.md` (Camunda platform deployment, c8ctl config, access URLs, admin credentials)
- `docs/Deployment_Guide.md` (workflow artifact deployment order and verification)

---

### Phase 4: Update the root README.md

**File:** `/README.md` (update)

The root README should be a concise project overview that **references** `DEPLOYMENT.md` for all deployment instructions. Changes:

- Keep the project structure section (it is useful context).
- Replace the "Quick Start" section with a short paragraph pointing to `DEPLOYMENT.md` for full deployment instructions, plus the two commands:
  ```bash
  # Terminal 1: Start port-forwards (keep running)
  ./deploy/rancher-desktop/scripts/camunda-port-forwards.sh

  # Terminal 2: Deploy everything
  ./deploy/deploy.sh --all
  ```
- Keep the "Local development" section but shorten it to reference `DEPLOYMENT.md` for details.
- Keep the "Playwright tests" section but shorten it to reference `DEPLOYMENT.md` for details.
- Keep the "Microservices" table — update simulator port to 8186.
- Keep "Time-emulation mode" and "Known cluster behavior" (useful context).
- Remove all `make` references — replace with shell script equivalents.

The updated README should be ~60-80 lines (down from 169), serving as a landing page that points to `DEPLOYMENT.md` for operational instructions.

---

### Phase 5: Handle existing deployment documentation

The following files contain deployment-relevant content that will be **consolidated into `DEPLOYMENT.md`** and then removed or archived:

| File | Action | Reason |
|------|--------|--------|
| `deploy/rancher-desktop/README.md` | **Update** to a short reference pointing to root `DEPLOYMENT.md`. Keep the directory structure (manifests, Helm values) as-is since it may be copied to other projects. The README should say: "For deployment instructions, see the root `DEPLOYMENT.md`." | Its full content is absorbed into `DEPLOYMENT.md`. The directory itself (manifests + Helm values) remains useful as a standalone Camunda deployment template. |
| `docs/Deployment_Guide.md` | **Remove** | Its content (artifact inventory, deployment order for workflow resources) is absorbed into `DEPLOYMENT.md` under "Step 5: Deploy workflow resources" and the artifact inventory table. |
| `docs/Testing_Guide.md` | **Keep** (no change) | This covers test scenarios, not deployment. It is orthogonal to the deployment consolidation. Reference it from `DEPLOYMENT.md` in a "Testing" section. |

---

### Phase 6: Remove the Makefile

**File:** `/Makefile` (delete)

Once `deploy/deploy.sh` exists and all references to `make build-web`, `make docker-webapp`, and `make deploy-webapp` are removed from documentation, delete the Makefile.

Verify no other scripts or CI/CD configurations reference `make` before deleting:
- Search for `make build-web`, `make docker-webapp`, `make deploy-webapp` across the codebase.
- Check for any CI/CD pipeline files (`.github/workflows/`, `.gitlab-ci.yml`, etc.) that invoke `make`.

---

### Phase 7: Update cross-references in remaining scripts

Ensure all scripts that reference deployment steps or URLs are consistent with the changes:

- `deploy/rancher-desktop/scripts/camunda-port-forwards.sh` — simulator port changed to 8186 (Phase 1a).
- `deploy/rancher-desktop/README.md` — access URLs table updated to show simulator at 8186 (Phase 5).
- Root `README.md` — microservices table updated to show simulator at 8186 (Phase 4).
- Any Playwright test configuration referencing the simulator port — update to 8186.

---

### Phase 8: Verify and test

1. Run `./deploy/deploy.sh --all` end-to-end on a fresh cluster to verify the script works.
2. Verify `DEPLOYMENT.md` instructions match what the script actually does — a reader should be able to follow `DEPLOYMENT.md` without reading the script source.
3. Verify the updated README.md is clear and points to `DEPLOYMENT.md` correctly.
4. Verify no remaining references to `make` exist in documentation or scripts.
5. Verify port-forward collision is resolved (simulator accessible at 8186, connectors at 8086).
6. Verify `camunda-uninstall.sh --full` properly cleans up Helm releases and CRDs.
7. Verify re-deployment after uninstall works without conflicts (no stale Helm releases or authorization config).

---

## Files Summary

| File | Action |
|------|--------|
| `deploy/deploy.sh` (new) | Unified deployment script — single entry point for all deployment steps. Replaces Makefile targets and coordinates existing scripts. Does NOT manage port-forwards (they must be started separately). |
| `DEPLOYMENT.md` (new) | Single source of truth for deployment — comprehensive guide covering all steps, access URLs, admin credentials, local development, testing, and cleanup. |
| `README.md` (update) | Condensed project overview with references to `DEPLOYMENT.md`. Removes all `make` references. Updates simulator port to 8186. |
| `deploy/rancher-desktop/README.md` (update) | Shortened to a reference pointing to root `DEPLOYMENT.md`. Directory structure (manifests, Helm values) preserved. |
| `deploy/rancher-desktop/scripts/camunda-port-forwards.sh` (update) | Simulator port-forward changed from 8086 to 8186 to resolve collision with Connectors. |
| `deploy/rancher-desktop/scripts/camunda-uninstall.sh` (update) | Added Helm release uninstallation and optional `--full` flag for CRD cleanup. |
| `deploy/rancher-desktop/helm-values/values-no-domain.yml` (update) | Removed dead authorization initializer block. |
| `docs/Deployment_Guide.md` (remove) | Content absorbed into `DEPLOYMENT.md`. |
| `Makefile` (delete) | No longer needed — all logic moved to `deploy/deploy.sh`. |
| `docs/Testing_Guide.md` (keep) | Unchanged — covers test scenarios, not deployment. |

---

## Issues Fixed (Beyond Consolidation)

| Issue | Fix | Phase |
|-------|-----|-------|
| **Port-forward collision** (8086: Connectors vs simulator) | Simulator port-forward changed to 8186 in `camunda-port-forwards.sh`. All docs updated. | 1a, 4, 5, 7 |
| **Incomplete uninstall** (Helm releases and CRDs orphaned) | `camunda-uninstall.sh` now uninstalls Helm releases before namespace deletion. Added `--full` flag for CRD cleanup. | 1b, 3, 8 |
| **Dead authorization initializer** (Helm values config never takes effect) | Removed from `values-no-domain.yml`. Authorizations correctly created by `configure-c8ctl.sh` via REST API. | 1c, 8 |
| **Port-forwards die when script exits** (critical design constraint) | `deploy/deploy.sh` explicitly does NOT start port-forwards. Documentation clearly states they must be started separately and kept running. | 2, 3, 4 |
| **No single deployment entry point** | `deploy/deploy.sh` provides a single command (`--all`) for full deployment, with flags for partial deployment. | 2, 3, 4 |
