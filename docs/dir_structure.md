# Directory Restructuring Plan

Status: **proposal — no changes have been made**
Owner: TBD
Related: [`DEPLOYMENT.md`](../DEPLOYMENT.md), [`README.md`](../README.md), [`docs/Testing_Guide.md`](Testing_Guide.md)

This document specifies a reorganization of the repository's operational assets.
It is a plan only: it lists every move and every reference that must change so
the work can be executed mechanically and reviewed.

---

## 1. Goals

1. Stop burying all operational scripts under `deploy/`. Split *entry points*
   (`deploy.sh`, `uninstall.sh`) from *per-target deploy assets*.
2. Rename `deploy/rancher-desktop/` — which is really "the Camunda platform
   deployment" — to `camunda/`. "Rancher Desktop" is the host platform, not the
   thing being deployed.
3. Promote the uninstall script out of the deeply nested
   `deploy/rancher-desktop/scripts/` folder to a single, symmetric teardown
   entry point.
4. Co-locate the Playwright suite with the web app it tests (`web/tests/`)
   instead of a sibling of unrelated Go services.
5. Rename the c8ctl profile from `rancher-desktop` to `kubernetes` to match the
   intent (it points at the k8s cluster, not at the desktop app).

Out of scope for this plan: the Go service source tree, the workflow artifact
tree, and the Angular application source. They already have sensible locations.

---

## 2. Current structure

```
pe-workflow/
├── deploy/
│   ├── deploy.sh                              # single deploy entry point
│   ├── rancher-desktop/                       # Camunda platform assets
│   │   ├── README.md
│   │   ├── helm-values/values-no-domain.yml
│   │   ├── manifests/{elasticsearch,keycloak,postgresql}/...
│   │   └── scripts/
│   │       ├── camunda-deploy-no-domain.sh
│   │       ├── configure-c8ctl.sh
│   │       ├── camunda-port-forwards.sh
│   │       └── camunda-uninstall.sh           # teardown buried here
│   └── services/                              # Dockerfile + k8s manifests + build script
│       ├── build-deploy.sh
│       ├── Dockerfile
│       └── manifests.yaml
├── playwright-tests/                          # tests the web app, but sits beside Go services
│   ├── e2e/
│   ├── utils/
│   ├── package.json
│   ├── playwright.config.ts
│   └── ...
├── services/                                  # Go source (unchanged)
├── web/                                       # Angular app (unchanged)
├── workflows/                                 # BPMN/DMN/forms (unchanged)
├── docs/
├── README.md
├── DEPLOYMENT.md
└── AGENTS.md
```

### Problems

- `deploy/rancher-desktop/` names the *host*, not the payload.
- The teardown script is four levels deep under `deploy/` and easy to miss.
- All scripts share one `deploy/` prefix, so there is no separation between the
  orchestration entry point and the per-target asset trees.
- `playwright-tests/` is unrelated to its siblings and is never discovered by
  anyone browsing the web app.
- The c8ctl profile name leaks the local runtime brand into every command in
  every doc.

---

## 3. Proposed structure

```
pe-workflow/
├── scripts/                                   # NEW: all operational entry points + assets
│   ├── deploy.sh                              # moved from deploy/deploy.sh
│   ├── uninstall.sh                           # moved from deploy/rancher-desktop/scripts/camunda-uninstall.sh
│   └── deploy/
│       ├── camunda/                           # moved from deploy/rancher-desktop/
│       │   ├── README.md
│       │   ├── helm-values/values-no-domain.yml
│       │   ├── manifests/
│       │   │   ├── elasticsearch/
│       │   │   ├── keycloak/
│       │   │   └── postgresql/
│       │   └── scripts/
│       │       ├── camunda-deploy-no-domain.sh
│       │       ├── configure-c8ctl.sh
│       │       └── camunda-port-forwards.sh
│       └── services/                          # moved from deploy/services/
│           ├── build-deploy.sh
│           ├── Dockerfile
│           └── manifests.yaml
├── services/                                  # unchanged — Go source
├── web/
│   ├── src/ ...                               # unchanged
│   └── tests/                                 # moved from playwright-tests/
│       ├── .env.example
│       ├── package.json
│       ├── package-lock.json
│       ├── playwright.config.ts
│       ├── tsconfig.json
│       ├── e2e/
│       └── utils/
├── workflows/                                 # unchanged
├── docs/
├── README.md
├── DEPLOYMENT.md
└── AGENTS.md
```

Notes on the chosen shape:

- `scripts/` is the umbrella; `scripts/deploy/` is a *payload* grouping, not a
  verb. `scripts/deploy.sh` and `scripts/deploy/` coexist deliberately (file and
  directory names in the same parent is valid on all target filesystems).
- `scripts/deploy/services/` keeps the name `services` because the
  `scripts/deploy/` prefix already disambiguates it from the Go source at
  `services/`. (Alternative rejected: `workers` or inlining the Dockerfile into
  the Go tree — both add churn for little gain.)
- `scripts/uninstall.sh` is the symmetric counterpart to `scripts/deploy.sh`
  (tear the whole stack down; `--full` also drops operator CRDs). The
  cluster-scoped operator CRDs and the namespace-wide delete already cover the
  `pe-*` services, so a single entry point is accurate.
- The `camunda/` tree keeps its internal `helm-values/`, `manifests/`, and
  `scripts/` layout unchanged so it remains copy-pasteable as a standalone
  template.

---

## 4. Decisions (confirmed)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Umbrella layout | `scripts/deploy.sh` + `scripts/uninstall.sh` + `scripts/deploy/{camunda,services}/` |
| 2 | Playwright location | `web/tests/` (internal `e2e/` + `utils/` preserved) |
| 3 | Deploy-config dir name | `scripts/deploy/services/` |
| 4 | Uninstall placement | `scripts/uninstall.sh`, whole-stack teardown |
| 5 | c8ctl profile name | rename `rancher-desktop` → `kubernetes` |

---

## 5. Detailed change plan

### 5.1 File and directory moves

Use `git mv` to preserve history. Execute in this order:

```bash
mkdir -p scripts/deploy
git mv deploy/deploy.sh                                   scripts/deploy.sh
git mv deploy/rancher-desktop                             scripts/deploy/camunda
git mv deploy/services                                    scripts/deploy/services
git mv scripts/deploy/camunda/scripts/camunda-uninstall.sh scripts/uninstall.sh
git mv playwright-tests                                   web/tests

# remove now-empty deploy/ (and stray .DS_Store files)
rm -rf deploy
```

`.DS_Store` files exist under `deploy/rancher-desktop/` (and subdirs) and are
already gitignored; deleting `deploy/` handles them.

### 5.2 `scripts/deploy.sh`

| Location | Current | Change |
|----------|---------|--------|
| header comment | `deploy/deploy.sh — single entry point...` | `scripts/deploy.sh — ...` |
| header + echo | `./deploy/rancher-desktop/scripts/camunda-port-forwards.sh` | `./scripts/deploy/camunda/scripts/camunda-port-forwards.sh` |
| usage comments/string (`lines ~13-18, 39`) | `./deploy/deploy.sh` | `./scripts/deploy.sh` |
| `ROOT=...` (line 24) | `.../..` | **unchanged** — `dirname` is now `scripts/`, `..` is still repo root |
| `SCRIPTS_DIR` (line 27) | `$ROOT/deploy/rancher-desktop/scripts` | `$ROOT/scripts/deploy/camunda/scripts` |
| `SERVICES_DIR` (line 28) | `$ROOT/deploy/services` | `$ROOT/scripts/deploy/services` |
| webapp step (`~119-121`) | uses `$SERVICES_DIR/...` | **unchanged once `SERVICES_DIR` is updated** |
| final echo (line 140) | `./deploy/rancher-desktop/scripts/...` | `./scripts/deploy/camunda/scripts/...` |

Pre-existing latent bug (fix opportunistically, note in PR): line ~155 uses
`$CAMUNDA_NAMESPACE` while the variable defined is `$NAMESPACE`.

### 5.3 `scripts/deploy/services/build-deploy.sh`

| Location | Current | Change |
|----------|---------|--------|
| header comment | "three levels up" | "three levels up" is actually correct for the **new** path (`scripts/deploy/services` → root); update wording to match |
| `ROOT=...(line 9)` | `.../../..` | `.../../../..` |
| `PROFILE` (line 14) | `rancher-desktop` | `kubernetes` |
| usage text (line 26) | `default: rancher-desktop` | `default: kubernetes` |
| comment (line 54) | "rancher-desktop profile" | "kubernetes profile" |
| Dockerfile (line 117) | `$ROOT/deploy/services/Dockerfile` | `$ROOT/scripts/deploy/services/Dockerfile` |
| manifest (line 120) | `$ROOT/deploy/services/manifests.yaml` | `$ROOT/scripts/deploy/services/manifests.yaml` |
| resource deploy (`workflows/...`) | relative to `ROOT` | **unchanged** |

### 5.4 `scripts/deploy/camunda/scripts/` scripts

`camunda-deploy-no-domain.sh`

| Location | Change |
|----------|--------|
| comment (line 18) | `rancher-desktop/manifests/` → `camunda/manifests/` (or `scripts/deploy/camunda/manifests/`) |
| `SCRIPT_DIR`/`RANCHER_DIR`/`MANIFESTS_DIR` (lines 33-35) | relative layout preserved by moving the whole tree; **no path math change required** |
| variable name `RANCHER_DIR` (optional) | rename to `CAMUNDA_DIR` for clarity (used at lines 34, 35, 39, 40, 42, 266) |
| `ENV_FILE` lookup (lines 39-43) | **behaviour fix needed**: `$RANCHER_DIR/..` no longer (and never did) reach the repo-root `env_exports.sh`; point at repo root via `$RANCHER_DIR/../../..` if root-level `env_exports.sh` is intended (see §7) |
| comment (line 82) | `deploy/rancher-desktop/README.md` → `scripts/deploy/camunda/README.md` |
| echo (lines 336-339) | `--profile=rancher-desktop` → `--profile=kubernetes` |

`configure-c8ctl.sh`

| Location | Change |
|----------|--------|
| default (line 43) | `C8CTL_PROFILE_NAME="${C8CTL_PROFILE_NAME:-rancher-desktop}"` → `:-kubernetes` |
| usage (line 69) | `[--profile-name rancher-desktop]` → `kubernetes` |
| "Rancher Desktop k3s" prose | **keep** — it correctly describes the host cluster |
| optional | on re-run, also `c8ctl remove profile rancher-desktop` to clean up the legacy profile (or document it in the migration notes, §6) |

`camunda-port-forwards.sh`

- No path or profile references. **Move only.**

`scripts/uninstall.sh` (moved)

- No path references; no profile references. **Move only.**
- Optional cosmetic: update the header to state it tears down the whole stack
  (platform namespaces include the `pe-*` service deployments).

### 5.5 `.gitignore`

| Line | Change |
|------|--------|
| 37 | `playwright-tests/node_modules/` → `web/tests/node_modules/` |
| `.env`, `playwright-report/`, `test-results/` (lines 38-40) | **unchanged** — unanchored patterns still match under `web/tests/` |
| `web/node_modules/`, `services/cmd/webapp/static/*` | **unchanged** |

### 5.6 `web/tests/` (moved Playwright suite)

| File | Location | Change |
|------|----------|--------|
| `playwright.config.ts` | `webServer.command` (line 30) | `go run ../services/cmd/webapp` → `go run ../../services/cmd/webapp` |
| `playwright.config.ts` | `testDir: './e2e'` | **unchanged** (internal layout preserved) |
| `utils/zeebe.ts` | error message (line 26) | `./deploy/deploy.sh --webapp` → `./scripts/deploy.sh --webapp` |
| `.env.example` | line 5 | `C8CTL_PROFILE=rancher-desktop` → `kubernetes` (note: this variable is not consumed anywhere — §7) |
| `package.json` | name/description | optional rename (`pe-workflow-playwright` still accurate); no path changes |
| `tsconfig.json`, `e2e/*.spec.ts`, `e2e/helpers/instance.ts` | — | no path references found; verify after move |

### 5.7 Application/build files (no change expected)

- `web/angular.json` — `outputPath: ../services/cmd/webapp/static` is relative to
  `web/`, which does not move.
- `web/scripts/flatten-output.mjs` — computes paths relative to itself under
  `web/`, does not move.
- `web/proxy.conf.json` — target `http://localhost:8088`, no paths.
- `deploy/services/Dockerfile` — build context is repo root and `COPY services/ .`
  is relative to that context; moving the Dockerfile changes only the `-f` path.
- `services/**`, `workflows/**` — no references to the moved paths.
- `docs/api/bff.openapi.yaml` — no references.

### 5.8 Documentation updates (live docs)

All of these must be updated. Run a final
`grep -rn "deploy/\|rancher-desktop\|playwright-tests"` to catch stragglers.

**`README.md`**

- Structure list: replace the `deploy/` bullet with `scripts/` (entry points,
  `scripts/deploy/camunda`, `scripts/deploy/services`) and add `web/tests/`.
- Quick Start (lines ~22, 25): `./deploy/deploy.sh` → `./scripts/deploy.sh`;
  `./deploy/rancher-desktop/scripts/camunda-port-forwards.sh` →
  `./scripts/deploy/camunda/scripts/camunda-port-forwards.sh`.
- Playwright section (lines ~37-40): `playwright-tests/` → `web/tests/`.
- Profile references (lines ~50, 52): `--profile=rancher-desktop` → `kubernetes`.

**`DEPLOYMENT.md`** (heaviest)

- Line 4: "scripts under `deploy/`" → "scripts under `scripts/`".
- Line 14, 23, 44, 53, 56, 76, 79, 81, 86, 90, 97, 100, 106, 116, 126, 197-205,
  217-220, 235-237, 247, 294-309, 317-320: update all `./deploy/...`,
  `deploy/services/...`, `deploy/rancher-desktop/...` paths.
- Playwright section (lines ~294-309): `playwright-tests/` → `web/tests/`;
  the `go run ../services/cmd/webapp` note → `../../services/cmd/webapp`.
- Cleanup section (lines ~317-320): `./deploy/rancher-desktop/scripts/camunda-uninstall.sh`
  → `./scripts/uninstall.sh` (and `--full`).
- Every `--profile=rancher-desktop` → `--profile=kubernetes`.

**`docs/Testing_Guide.md`**

- Lines 28, 40, 43, 75: `./deploy/...` → `./scripts/...`; `deploy/services/manifests.yaml`
  → `scripts/deploy/services/manifests.yaml`.
- All `--profile=rancher-desktop` occurrences (~30) → `kubernetes`.
- Lines 79-80, 131, 144-145 and the rest of the command blocks: profile rename.

**`scripts/deploy/camunda/README.md`** (moved)

- Line 6: `../../DEPLOYMENT.md` → `../../../DEPLOYMENT.md`.
- Lines 9, 38: `rancher-desktop/` → `camunda/` (and describe it as
  `scripts/deploy/camunda/`).
- Lines 107-108: `./scripts/camunda-uninstall.sh` → repo-root `./scripts/uninstall.sh`.
- Line 111: `../../DEPLOYMENT.md` → `../../../DEPLOYMENT.md`.

**`docs/services_implementation_plan.md`** — decision required (§7). It contains
live path references (lines 13, 53, 341, 359, 379-381, 403-429, 436) and is the
target of a Testing_Guide link ("see §9 for the auth setup"). Either update it or
demote it to historical.

**Historical documents (leave unchanged):**

- `docs/deployment_update.md`, `docs/deployment_update_v2.md`,
  `docs/frontend-plan.md`, `docs/frontend-plan-v2.md`, `docs/frontend-plan-v3.md`,
  `docs/frontend-plan-v4.md`.

These record past plans and intentionally reference the old layout. Add a
one-line note at the top of each only if desired; do not rewrite paths.

### 5.9 c8ctl profile rename (`rancher-desktop` → `kubernetes`)

Client-side only; no cluster resources change.

- `configure-c8ctl.sh` creates/activates the `kubernetes` profile on next run.
- The Keycloak OIDC client (`zeebe-cli`), the `c8ctl-credentials` secret, the
  realm, and all authorizations are unaffected.
- Existing machines keep a stale `rancher-desktop` profile in the c8ctl config.
  Migration: `c8ctl remove profile rancher-desktop` (or leave it; harmless).
- Document the rename in the PR description so anyone with shell history
  updates their `--profile` flag.

---

## 6. Execution order

1. Land the moves from §5.1 (single commit; rename detection keeps diffs small).
2. Patch scripts ($5.2-$5.5) and run `bash -n` on each.
3. Patch `web/tests` config and utils ($5.6).
4. Patch live docs ($5.8).
5. Update `.gitignore` ($5.5).
6. Run the validation checklist (§8).
7. `grep -rn "rancher-desktop\|playwright-tests\|deploy/deploy"` and resolve
   every remaining hit that is not a historical doc or an intentional host-name
   mention ("Rancher Desktop k3s" in prose is fine).

---

## 7. Open items / decisions needed before or during execution

1. **`env_exports.sh` lookup** — `camunda-deploy-no-domain.sh` tries
   `$RANCHER_DIR/../env_exports.sh`, which resolves to `deploy/` today and will
   resolve to `scripts/deploy/` after the move; neither is the repo root that
   `.gitignore` implies. Fix to the repo root (`$RANCHER_DIR/../../..`), or drop
   the lookup? **Recommend fixing to repo root.**
2. **`docs/services_implementation_plan.md`** — update to the new layout or mark
   as historical? **Recommend marking historical** and pointing the
   Testing_Guide auth note at `configure-c8ctl.sh` directly.
3. **`C8CTL_PROFILE` in `web/tests/.env.example`** — defined but unused. Drop it,
   or wire it up? **Recommend dropping** to avoid implying it does something.
4. **Rename `RANCHER_DIR` shell variable** to `CAMUNDA_DIR` (cosmetic).
   Recommend yes.
5. **Legacy profile cleanup** — should `configure-c8ctl.sh` auto-remove the old
   `rancher-desktop` profile, or should the README document the manual command?
   **Recommend documenting** (less magic in the deployment path).
6. **`deploy.sh` `$CAMUNDA_NAMESPACE` typo** — fix opportunistically.

---

## 8. Validation checklist

Scripts:

- [ ] `bash -n scripts/deploy.sh scripts/uninstall.sh`
- [ ] `bash -n scripts/deploy/camunda/scripts/*.sh`
- [ ] `bash -n scripts/deploy/services/build-deploy.sh`
- [ ] `shellcheck` (if installed) on all of the above
- [ ] `./scripts/deploy.sh --help` prints the new paths
- [ ] `./scripts/deploy/camunda/scripts/camunda-deploy-no-domain.sh --check-versions`
- [ ] `./scripts/deploy/services/build-deploy.sh --help` shows `kubernetes`
- [ ] `./scripts/uninstall.sh --help`

Web tests:

- [ ] `cd web/tests && npm install`
- [ ] `cd web/tests && npm run typecheck`
- [ ] `cd web/tests && npx playwright test --list` resolves all specs
- [ ] Confirm `webServer` starts `../../services/cmd/webapp` correctly

End-to-end (cluster running):

- [ ] `./scripts/deploy.sh --all`
- [ ] `./scripts/deploy.sh --configure` creates the `kubernetes` profile
- [ ] `c8ctl get topology --profile=kubernetes`
- [ ] `./scripts/deploy.sh --resources`
- [ ] `./scripts/deploy.sh --webapp`
- [ ] `cd web/tests && npm test`
- [ ] `./scripts/uninstall.sh` then `./scripts/uninstall.sh --full`

Reference sweep:

- [ ] `grep -rn "playwright-tests" .` → only historical docs
- [ ] `grep -rn "deploy/rancher-desktop\|deploy/services\|\./deploy/deploy.sh" .` → only historical docs
- [ ] `grep -rn "profile=rancher-desktop" .` → only historical docs
- [ ] `git status` shows renames, not delete+add, for the moved trees

---

## 9. Reference index (current locations)

Files that reference the moved paths/profiles (line numbers are pre-move and
may shift as edits land):

| File | What it references |
|------|--------------------|
| `deploy/deploy.sh` | `rancher-desktop/scripts`, `deploy/services`, its own path |
| `deploy/services/build-deploy.sh` | `deploy/services/{Dockerfile,manifests.yaml}`, profile |
| `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` | `rancher-desktop/manifests`, profile in echoes, README path |
| `deploy/rancher-desktop/scripts/configure-c8ctl.sh` | profile default + usage |
| `deploy/rancher-desktop/README.md` | `../../DEPLOYMENT.md`, its own tree, uninstall path |
| `playwright-tests/playwright.config.ts` | `../services/cmd/webapp` |
| `playwright-tests/utils/zeebe.ts` | `./deploy/deploy.sh` |
| `playwright-tests/.env.example` | `C8CTL_PROFILE=rancher-desktop` |
| `.gitignore` | `playwright-tests/node_modules/` |
| `README.md` | deploy commands, playwright path, profile |
| `DEPLOYMENT.md` | all of the above |
| `docs/Testing_Guide.md` | deploy commands, profile |
| `docs/services_implementation_plan.md` | deploy paths, profile (historicity TBD) |
| `docs/deployment_update*.md`, `docs/frontend-plan*.md` | historical only — do not edit |
