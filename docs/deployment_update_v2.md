# Deployment Update Plan v2

Supersedes `docs/deployment_update.md` (v1). Same goal: **normalize all deployment onto shell
scripts, remove the Makefile, eliminate known risks, and make one authoritative `DEPLOYMENT.md`.**

v2 exists because a fact-check of v1 against the actual working tree found several incorrect
premises that would have led to wrong edits. Every claim below was verified by reading the files;
corrections are listed first so reviewers can see exactly what changed.

---

## 0. Corrections to v1 (verified)

| v1 claim | Verified reality | Consequence for v2 |
|-----------|------------------|--------------------|
| Simulator port-forward collides with Connectors at `8086` | **No `pe-simulator` port-forward exists at all.** `camunda-port-forwards.sh` has 8 entries; `camunda-connectors` maps `8086:8080`. The collision is *latent* and only asserted in prose. | Do **not** "change" a mapping. **Add** `svc/pe-simulator … 8186:8086`. (Decision Q1.) |
| `set-secrets.sh` lives under `deploy/services/` | It lives at `deploy/rancher-desktop/manifests/postgresql/set-secrets.sh`. | Fix the inventory; no edit needed. |
| `deploy.sh --all` calls platform, then configure | `camunda-deploy-no-domain.sh` **already invokes `configure-c8ctl.sh`** as its final step (Step 7). | Running both double-configures. Add a skip flag. |
| Versions to pin: Helm `14.6.1`, ECK `3.4.1`, CNPG `1.30.0` | Also pins **Keycloak `26.3.2`**. | Include all four; centralize in one block. |
| Quick Start: "start port-forwards, then `deploy.sh --all`" | On a fresh cluster, `kubectl port-forward` to not-yet-created Services dies immediately; and `--resources` needs `localhost:8080`. Ordering is impossible as written. | Remove port-forward orchestration from the happy path; make `--resources` self-manage a temp forward. (Decision Q2.) |
| "Re-running resumes from the last completed step" | There is no state tracking. | Reword: "every step is individually idempotent." |
| Update "any Playwright config referencing simulator port" | No Playwright file references `8086`/`8186`. `playwright-tests/utils/zeebe.ts:26` references `make deploy-webapp`. | Update that one reference; no port change. |
| All `make` references should be removed | Live refs are in `README.md` (42–47, 115–116) and `playwright-tests/utils/zeebe.ts:26`; historical refs are in `docs/frontend-plan-v3.md` / `v4.md`. | Fix live refs; leave planning docs as historical. (Decision Q3.) |

---

## 1. Verified current state

Deployment is split across **two mechanisms**:

| Mechanism | Targets / scripts | Location |
|-----------|-------------------|----------|
| **Makefile** (3 targets) | `build-web`, `docker-webapp`, `deploy-webapp` | `/Makefile` (12 lines, untracked) |
| **Shell scripts** (6) | `camunda-deploy-no-domain.sh`, `configure-c8ctl.sh`, `camunda-port-forwards.sh`, `camunda-uninstall.sh`, `build-deploy.sh`, `manifests/postgresql/set-secrets.sh` | `deploy/rancher-desktop/scripts/`, `deploy/services/`, `deploy/rancher-desktop/manifests/postgresql/` |

**Verified touchpoints and constraints**

- `Makefile`:
  - `build-web`: `cd web && npm ci && npm run build`
  - `docker-webapp`: depends on `build-web`; `docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest -f deploy/services/Dockerfile .`
  - `deploy-webapp`: depends on `docker-webapp`; `kubectl apply -f deploy/services/manifests.yaml`; `rollout restart`/`status deployment/pe-webapp -n camunda --timeout=180s`
- `deploy/services/Dockerfile` builds `./cmd/${SERVICE}` via `ARG SERVICE`; it does **not** run npm. The webapp BFF embeds `//go:embed static/*` (`services/cmd/webapp/main.go`), so `npm run build` must populate `services/cmd/webapp/static/` **before** the Docker build.
- `camunda-port-forwards.sh`: 8 foreground-batch forwards (`FORWARDS` array, lines 8–17), `wait` at the end, `trap cleanup SIGINT`. Forwards die with the script by design.
- `camunda-deploy-no-domain.sh`: 7 steps; releases `camunda` namespace; constants inline — chart `14.6.1` (line 52), ECK `3.4.1` (86), CNPG `1.30.0` (115), Keycloak `26.3.2` (149). Step 7 calls `configure-c8ctl.sh`.
- `configure-c8ctl.sh`: **already implements the self-managed temp-forward pattern** — starts a temp Keycloak forward (`PF_PID`, line 148) and separate verification forwards for Keycloak and the Zeebe gateway (`start_verify_kc`/`start_verify_gw`, lines 623–624), cleans them up on `EXIT INT TERM` (146, 665). It registers profile `rancher-desktop` at `http://localhost:8080/v2`.
- `build-deploy.sh`: flags `--services` (default), `--resources`, `--tag`, `--profile`. `--resources` runs four `c8ctl deploy` calls against the profile → **requires `localhost:8080`**.
- `camunda-uninstall.sh` (7 lines): only `kubectl delete namespace elastic-system cnpg-system camunda`; `helm uninstall` is commented out.
- `values-no-domain.yml`: dead `orchestration.initialization.authorizations` list for owner `zeebe-cli` at lines 109–129. `security.authorizations.enabled: true` and `initialization.defaultRoles.admin` must stay.
- `pe-simulator` internal port is `8086` (`services/cmd/simulator/main.go:18`; `deploy/services/manifests.yaml:352–360`). It is **not** exposed on localhost today.
- No CI/CD exists anywhere (no `.github/`, `.gitlab-ci.yml`, etc.).

---

## 2. Locked decisions

| # | Decision |
|---|----------|
| Q1 | **Expose the simulator on `localhost:8186`** by adding `svc/pe-simulator -n $CAMUNDA_NAMESPACE 8186:8086` to the port-forward script. Internal `pe-simulator:8086` is unchanged. Update docs that imply localhost `8086`. |
| Q2 | **`--resources` self-manages a temporary Zeebe-gateway port-forward** (start if `localhost:8080` is free, wait for readiness, tear down on exit), mirroring the existing pattern in `configure-c8ctl.sh`. Users are no longer required to coordinate forwards for deployment. |
| Q3 | **Fix live `make` references only** (`README.md`, `playwright-tests/utils/zeebe.ts`); leave `docs/frontend-plan-v3.md` / `v4.md` as historical records. Delete the Makefile. |
| Q4 | Unified entry point is **`deploy/deploy.sh`**, invoked as `./deploy/deploy.sh --all`. |

---

## 3. Target state

- One entry point (`deploy/deploy.sh`) with composable flags; it orchestrates existing scripts and wraps the 3 Makefile targets.
- Long-lived port-forwards remain a separate, explicitly-documented concern; short-lived forwards needed *during* deployment are managed by the scripts that need them.
- The simulator has a stable localhost address (`8186`) that never collides with Connectors (`8086`).
- Uninstall is complete and re-deployable.
- One `DEPLOYMENT.md`; `README.md` is a landing page; no `make`.

---

## 4. Phased plan

### Phase 0 — Pre-flight verification (do before editing)

1. **Confirm Helm release name(s).** v1 assumed `helm uninstall camunda`, but the deploy script's
   `CAMUNDA_RELEASE_NAME=camunda` may not match the `helm upgrade --install <name>` argument.
   Run `helm list -A` and confirm the actual release name(s) for the Camunda chart and the
   Keycloak operator. The uninstall script must use the real names (or discover them).
2. **Confirm the Angular build output path.** Verify `web/`'s build writes into
   `services/cmd/webapp/static/` (matching `//go:embed static/*`). If it doesn't, the webapp
   image will silently ship stale assets. Capture the exact command as today's `make build-web` does.
3. **Confirm Keycloak operator namespace/release** used by `camunda-deploy-no-domain.sh` Step 4
   so uninstall covers it.

If any of these differ from the assumptions below, adjust the corresponding phase before executing.

**Phase 0 findings (resolved during implementation):**

- **Helm release name confirmed:** the only Helm release is the Camunda platform chart,
  installed as `$CAMUNDA_RELEASE_NAME` (default `camunda`) in namespace `camunda`. So
  `helm uninstall camunda` (or the configured name) is correct.
- **Operators are NOT Helm releases:** ECK, CloudNativePG, and the Keycloak operator are
  all applied from raw manifests (`kubectl apply`), not Helm. v1's
  `helm uninstall keycloak-operator` was wrong. They are removed by deleting their
  namespaces; only their cluster-scoped CRDs survive.
- **Correct CRD names for `--full`:** `elasticsearches.elastic.co`,
  `clusters.postgresql.cnpg.io`, `keycloaks.k8s.keycloak.org`,
  `keycloakrealmimports.k8s.keycloak.org`.
- **Angular output confirmed:** `web/angular.json` sets
  `outputPath: ../services/cmd/webapp/static` and `npm run build` runs
  `ng build && node scripts/flatten-output.mjs`, matching the BFF's `//go:embed static/*`.

---

### Phase 1 — Fix existing scripts

#### 1a. Add simulator port-forward at 8186

**File:** `deploy/rancher-desktop/scripts/camunda-port-forwards.sh` (update)

Append to the `FORWARDS` array (after the `pe-webapp` line):

```bash
  "svc/pe-simulator -n $CAMUNDA_NAMESPACE 8186:8086"
```

This is purely additive; in-cluster traffic keeps using `pe-simulator:8086`. While in this file,
harden it (low risk, aligns with the rest of the scripts):
- add `set -euo pipefail`;
- trap `EXIT TERM` in addition to `INT` so forwards are cleaned up on any termination.

Do **not** alter the `pe-webapp 8088:8080` or Connectors `8086:8080` mappings.

#### 1b. Make uninstall complete and idempotent

**File:** `deploy/rancher-desktop/scripts/camunda-uninstall.sh` (rewrite)

Requirements:
- `set -euo pipefail`.
- Accept `--full` (also deletes operator CRDs) and default to safe teardown.
- **Discover and uninstall Helm releases** in the managed namespaces before deleting namespaces,
  rather than hardcoding names (use `helm list -A -o json` filtered to the namespaces, or the
  exact names confirmed in Phase 0). Guard every call with `|| true`.
- Delete namespaces with `--ignore-not-found` and a `--timeout` so the script never hangs or fails
  on a partially-deployed cluster:
  `kubectl delete namespace elastic-system cnpg-system "$CAMUNDA_NAMESPACE" --ignore-not-found --timeout=300s`
- Under `--full`, delete the operator CRDs guarded by `|| true`:
  `elasticsearches.elastic.co`, `clusters.postgresql.cnpg.io`,
  `keycloaks.k8s.keycloak.org`, `keycloakrealmimports.k8s.keycloak.org` (names confirmed
  in Phase 0).
- Print a summary of what was removed.

#### 1c. Remove dead authorization initializer

**File:** `deploy/rancher-desktop/helm-values/values-no-domain.yml` (update)

Remove **only** the `orchestration.security.initialization.authorizations` list (lines 109–129).
Keep `security.authorizations.enabled: true`, `security.authentication.oidc`, and
`security.initialization.defaultRoles.admin`. Authorizations are recreated by
`configure-c8ctl.sh` on every run via the REST API; the Helm block runs before the `zeebe-cli`
client exists and therefore never takes effect.

#### 1d. Centralize version pins and add `--check-versions`

**File:** `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` (update)

Move all tool/chart versions into one clearly-labeled block near the top of the file:

```bash
# ---- Pinned versions (single source of truth) ----
CAMUNDA_HELM_CHART_VERSION="${CAMUNDA_HELM_CHART_VERSION:-14.6.1}"
ECK_VERSION="${ECK_VERSION:-3.4.1}"
CNPG_VERSION="${CNPG_VERSION:-1.30.0}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.3.2}"
```

- Replace the inline literals (lines 52, 86, 115, 149) with references to these variables.
- Add `--check-versions` which prints all four and exits 0 without deploying.
- Add a short comment noting `deploy/rancher-desktop/README.md` documents the chart version
  (`CAMUNDA_HELM_CHART_VERSION`) and must be kept in sync; update that README if it drifts.

---

### Phase 2 — Unified entry point

#### 2a. `deploy/deploy.sh` (new)

Single orchestrator at `deploy/deploy.sh`. **It does not start or manage long-lived
port-forwards.** Steps that need a forward during execution obtain a temporary one themselves
(see 2b).

**Flags**

| Flag | Action |
|------|--------|
| `--platform` | Deploy Camunda platform (calls `camunda-deploy-no-domain.sh`, skipping its internal c8ctl config). |
| `--configure` | Configure c8ctl (calls `configure-c8ctl.sh`). |
| `--services` | Build + apply workers (calls `build-deploy.sh --services`). |
| `--resources` | Deploy workflow artifacts (calls `build-deploy.sh --resources`; self-managed forward). |
| `--webapp` | Build Angular SPA + Go BFF image and roll out (inline, replaces the 3 Makefile targets). |
| `--all` | `platform → configure → services → resources → webapp` (default when no flags). |
| `-h/--help` | Usage. |

**Behavior**
- **Prerequisite check** at startup: `kubectl`, `docker`, `helm`, `c8ctl`, `envsubst`, `yq`,
  `openssl`, `node`/`npm`, `go`. Exit non-zero with a clear message naming the first missing tool.
- **Avoid double configuration.** Add a `--skip-c8ctl-config` flag to
  `camunda-deploy-no-domain.sh` that suppresses its Step 7 call. `deploy.sh --platform` passes it,
  and the `--configure` step owns that work. Running `camunda-deploy-no-domain.sh` directly keeps
  its current (configure-inclusive) behavior for backward compatibility.
- **Idempotent steps.** Do not claim resumability; each sub-step (`helm upgrade --install`,
  `kubectl apply`, `rollout restart`) is safe to re-run. Print a clear per-step banner and fail
  fast with a non-zero exit code on the first error.
- **Webapp step** (verbatim behavior of `make build-web`, then Dockerfile, then rollout):
  ```bash
  (cd "$ROOT/web" && npm ci && npm run build)
  docker build --build-arg SERVICE=webapp -t pe-workflow/webapp:latest -f "$ROOT/deploy/services/Dockerfile" "$ROOT"
  kubectl apply -f "$ROOT/deploy/services/manifests.yaml"
  kubectl rollout restart deployment/pe-webapp -n "$NAMESPACE"
  kubectl rollout status  deployment/pe-webapp -n "$NAMESPACE" --timeout=180s
  ```
  Resolve `$ROOT` from `${BASH_SOURCE[0]}` (like `build-deploy.sh`) so it runs from anywhere.

#### 2b. Self-managed temporary forward for `--resources`

**File:** `deploy/services/build-deploy.sh` (update)

Before the four `c8ctl deploy` calls:
1. If `localhost:8080` already answers, use the existing forward — do not start or kill anything.
2. Otherwise start `kubectl port-forward svc/camunda-zeebe-gateway -n "${NAMESPACE:-camunda}" 8080:8080 &`,
   record the PID, and `trap 'kill "$PF_PID"' EXIT INT TERM`.
3. Poll `http://localhost:8080/v2/topology` (or a TCP connect) up to ~15s before deploying,
   restarting once if the forward exits early — mirror `configure-c8ctl.sh` lines 629–650.
4. Only kill the forward if this script started it.

This removes the external coordination requirement and makes `--resources` work standalone.

---

### Phase 3 — `DEPLOYMENT.md` (new, repo root)

Single source of truth. Sections:

1. **Overview** — what gets deployed (Camunda 8 platform, 6 Go workers, Angular SPA via Go BFF).
2. **Prerequisites** — Rancher Desktop (k3s), Docker, kubectl, helm, envsubst, yq, openssl,
   c8ctl, Node.js 20+, Go.
3. **Quick Start** — the *correct* order:
   ```bash
   # Deploy the full stack (no port-forwards required during deploy)
   ./deploy/deploy.sh --all

   # Then, in a separate terminal, start long-lived port-forwards for interactive use
   ./deploy/rancher-desktop/scripts/camunda-port-forwards.sh
   ```
4. **Deployment steps** — platform, configure c8ctl, workers, workflow resources, webapp.
   Explicitly explain that short-lived forwards are handled internally.
5. **Access URLs** — table incl. simulator at `http://localhost:8186` and Connectors at
   `http://localhost:8086`.
6. **Admin credentials** — Camunda admin and Keycloak admin retrieval commands.
7. **Partial deployment** — the `deploy.sh` flags.
8. **Local development** — BFF locally + Angular dev server (from root README).
9. **Playwright tests** — condensed, links to `docs/Testing_Guide.md`.
10. **Workflow artifact inventory** — the Deployment_Guide content (forms, DMN, shared/delegate
    BPMN, orchestrator) folded into the "resources" step.
11. **Cleanup / uninstall** — `camunda-uninstall.sh` and `--full`.
12. **Known cluster behavior** — Zeebe customHeaders bug, ghost-activated jobs.

---

### Phase 4 — Root `README.md` (update)

- Replace lines 42–47 and 115–116 (`make build-web` / `make docker-webapp` / `make deploy-webapp`)
  with `./deploy/deploy.sh --webapp`.
- Replace the Quick Start deployment body with a pointer to `DEPLOYMENT.md` plus the two commands
  in Phase 3.3.
- Microservices table: keep simulator's service port as `8086`, but note its **localhost URL is
  `http://localhost:8186`** (Connectors owns 8086).
- Keep project structure, time-emulation, known cluster behavior; shorten local-dev and Playwright
  sections to point at `DEPLOYMENT.md` / `docs/Testing_Guide.md`.
- Target ~60–80 lines.

---

### Phase 5 — Other documentation

| File | Action |
|------|--------|
| `docs/Deployment_Guide.md` | **Remove** (`git rm`); content absorbed into `DEPLOYMENT.md` §4/§10. |
| `docs/Testing_Guide.md` | **Keep.** Add a one-line note that the simulator is reachable locally at `http://localhost:8186` (internal `:8086` unchanged). |
| `deploy/rancher-desktop/README.md` | **Shorten** to a pointer to root `DEPLOYMENT.md`; keep the directory-structure/manifests/Helm-values description because this directory is a reusable template. Add the simulator `8186` row to any access-URL table. |
| `docs/frontend-plan-v3.md`, `docs/frontend-plan-v4.md` | **Leave as-is** (historical). |

---

### Phase 6 — Remove the Makefile and live `make` references

1. Update `playwright-tests/utils/zeebe.ts:26`: `make deploy-webapp` → `./deploy/deploy.sh --webapp`.
2. Confirm no remaining references: `rg -n "make (build-web|docker-webapp|deploy-webapp)"`
   should only match the historical frontend-plan docs (accepted).
3. No CI exists, so nothing else to update.
4. `git rm Makefile`.

---

### Phase 7 — Verify (definition of done)

1. From a **fresh** cluster: `./deploy/deploy.sh --all` completes without manual port-forwards.
2. `./deploy/rancher-desktop/scripts/camunda-port-forwards.sh` then exposes: simulator on `8186`,
   Connectors on `8086`, webapp on `8088`; no bind collisions.
3. `./deploy/deploy.sh --resources` succeeds with **no** pre-existing port-forward (proves 2b).
4. `./deploy/deploy.sh --webapp` reproduces the old `make deploy-webapp` result; the served SPA
   reflects the just-built `web/` assets (proves Phase 0.2).
5. `camunda-uninstall.sh` removes releases and namespaces cleanly; a subsequent
   `./deploy/deploy.sh --all` succeeds with no stale Helm/authorization conflicts.
6. `camunda-uninstall.sh --full` additionally removes the operator CRDs.
7. `rg -n "make (build-web|docker-webapp|deploy-webapp)"` matches only the historical planning docs.
8. A reader can follow `DEPLOYMENT.md` end-to-end without reading script source.

---

## 5. Risk register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Wrong Helm release name hardcoded in uninstall | Medium | Phase 0.1: discover via `helm list` / use exact names; uninstall uses discovery. |
| Angular build no longer populates `static/`, shipping stale SPA | Low–Med | Phase 0.2 verifies output path; Phase 7.4 is an explicit check. |
| `deploy.sh` double-runs `configure-c8ctl.sh` | High if unaddressed | Add `--skip-c8ctl-config`; `deploy.sh --platform` passes it. |
| Temp forward races Zeebe readiness in `--resources` | Medium | Poll + one restart, mirroring `configure-c8ctl.sh`; never kill a forward the script didn't start. |
| Port `8080` already occupied during `--resources` | Low | Helper detects an existing listener and reuses it. |
| `set -e` aborts uninstall on an already-deleted namespace | High in current script | `--ignore-not-found` + `|| true` on all destructive calls. |
| Docs drift from scripts | Medium | Central version block + `--check-versions`; DEPLOYMENT.md reviewed against script output (Phase 7.8). |
| Removing Makefile breaks an unknown caller | Low | Repo has no CI; `rg` sweep in Phase 6; historical docs intentionally left. |

**Explicit non-goals:** no change to in-cluster service ports; no long-lived port-forward
supervision/daemon; no rework of `configure-c8ctl.sh` internals; no edits to historical
`frontend-plan-v*.md`.

---

## 6. Files summary

| File | Action |
|------|--------|
| `deploy/deploy.sh` | **New** — unified orchestrator (flags above); owns platform/configure/services/resources/webapp; no long-lived forwards. |
| `deploy/services/build-deploy.sh` | **Update** — `--resources` self-manages a temporary Zeebe forward. |
| `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` | **Update** — centralize versions; add `--check-versions` and `--skip-c8ctl-config`. |
| `deploy/rancher-desktop/scripts/camunda-port-forwards.sh` | **Update** — add simulator `8186:8086`; harden traps/`set -euo pipefail`. |
| `deploy/rancher-desktop/scripts/camunda-uninstall.sh` | **Rewrite** — Helm uninstall + `--ignore-not-found` + `--full`. |
| `deploy/rancher-desktop/helm-values/values-no-domain.yml` | **Update** — remove dead `initialization.authorizations`. |
| `DEPLOYMENT.md` | **New** — single source of truth. |
| `README.md` | **Update** — condense, point to `DEPLOYMENT.md`, fix `make` refs, simulator 8186 note. |
| `deploy/rancher-desktop/README.md` | **Update** — shorten to pointer; add simulator 8186 row. |
| `docs/Deployment_Guide.md` | **Remove** — absorbed into `DEPLOYMENT.md`. |
| `docs/Testing_Guide.md` | **Update** — one-line simulator localhost note. |
| `playwright-tests/utils/zeebe.ts` | **Update** — `make deploy-webapp` → `./deploy/deploy.sh --webapp`. |
| `Makefile` | **Delete**. |
| `docs/deployment_update.md` | **Leave** as the v1 record (superseded by this file). |
