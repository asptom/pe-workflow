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
| variable name `RANCHER_DIR` | rename to `CAMUNDA_DIR` for clarity (update uses at lines 34, 35, 39, 40, 42, 266) — **confirmed** |
| `ENV_FILE` lookup (lines 39-43) | **fix (confirmed):** `$CAMUNDA_DIR/../../..` points at the repo root so the root-level `env_exports.sh` named in `.gitignore` is actually sourced |
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
| `.env.example` | line 5 | **delete** the `C8CTL_PROFILE=rancher-desktop` line (it is not consumed by any test code — §7) |
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

### 5.8 Documentation updates (ALL docs)

> **Policy (confirmed):** every documentation reference to a moved path or the
> old c8ctl profile name is updated so the repo has zero stale references after
> the change. This explicitly includes the historical planning docs. In those
> files only **path and command references** are substituted; the surrounding
> narrative and any references to tools that no longer exist (e.g. the deleted
> `Makefile` targets) are preserved, and a short banner is added noting the paths
> were updated after the reorg.

Substitution rules applied repo-wide:

| Old | New |
|-----|-----|
| `deploy/deploy.sh`, `./deploy/deploy.sh` | `scripts/deploy.sh`, `./scripts/deploy.sh` |
| `deploy/services/` | `scripts/deploy/services/` |
| `deploy/rancher-desktop/` | `scripts/deploy/camunda/` |
| `playwright-tests/` | `web/tests/` |
| `deploy/rancher-desktop/scripts/camunda-uninstall.sh` | `scripts/uninstall.sh` |
| `--profile=rancher-desktop`, profile `rancher-desktop` | `--profile=kubernetes`, profile `kubernetes` |
| `Rancher Desktop k3s` (prose, host platform) | **unchanged** — still correct |

**Live docs (update paths, commands, and prose):**

- **`README.md`** — line 13 (structure bullet: `deploy/` → `scripts/`, add
  `web/tests/`); 22, 25 (quick-start commands); 39 (`DEPLOYMENT.md#playwright-tests`
  anchor is unaffected); 50, 52 (profile).
- **`DEPLOYMENT.md`** — line 4 ("scripts under `deploy/`" → `scripts/`); 14, 20,
  23, 27, 44, 53, 56, 65, 76, 79, 81, 86, 90, 97, 100, 106, 116, 126, 135, 183,
  197-205, 217-220, 235-237, 247, 294-309, 317-320. Playwright section (294-309):
  `playwright-tests/` → `web/tests/` and the `go run ../services/cmd/webapp` note
  → `../../services/cmd/webapp`. Cleanup (317-320): uninstall → `./scripts/uninstall.sh`.
- **`docs/Testing_Guide.md`** — lines 28, 29 (port-forward script), 40, 43, 75
  (`build-deploy.sh`, `manifests.yaml`); profile at 29, 32, 34, 60, 61, 69-72,
  131, 144, 145, 156, 170, 172, 174, 185, 186, 196, 213, 224, 225, 236, 265,
  276-292.
- **`scripts/deploy/camunda/README.md`** (moved) — line 6 and 111
  (`../../DEPLOYMENT.md` → `../../../DEPLOYMENT.md`); 9, 38 (`rancher-desktop/` →
  `camunda/`, described as `scripts/deploy/camunda/`); 107-108 (uninstall →
  repo-root `./scripts/uninstall.sh`).
- **`docs/services_implementation_plan.md`** — line 13 (port-forward path), 14
  (profile), 53, 341, 359, 379, 381 (Dockerfile/manifests), 403-429, 436 (profile
  in every command).

**Historical planning docs (mechanical path/profile substitution + banner):**

- **`docs/deployment_update.md`** — lines 14, 19, 20, 40, 46, 53, 76, 84, 94, 98,
  104, 106, 108, 110, 115, 116, 122, 137, 150, 155, 170, 173, 191, 201, 213, 214,
  222, 236, 239-242, 244, 256, 257.
- **`docs/deployment_update_v2.md`** — lines 17, 18, 20, 22, 23, 34, 40, 41, 42,
  45, 46, 49, 60, 61, 67, 113, 130, 149, 159, 173, 180, 182, 192, 193, 202, 211,
  212, 216, 220, 244, 247, 254, 267, 284, 291, 301, 302, 304, 305, 308, 321,
  338-343, 346, 349.
- **`docs/frontend-plan.md`** — lines 81, 103, 106.
- **`docs/frontend-plan-v2.md`** — lines 163, 202.
- **`docs/frontend-plan-v3.md`** — lines 15, 244, 253, 256, 261, 263, 312, 322,
  329, 345, 360, 368, 378, 420, 470, 482.
- **`docs/frontend-plan-v4.md`** — lines 24, 26, 28, 300, 318, 321, 330, 332,
  334, 385, 388, 390, 394, 404, 420, 437, 550, 560, 562.

**Intentionally excluded from the sweep:**

- `docs/dir_structure.md` itself — it necessarily quotes the old paths in its
  "current structure" and change tables. Do not rewrite its historical sections.
- `make ...` invocations in the historical frontend-plan docs — they describe a
  deleted Makefile; rewrite to the new scripts only if you want full command
  accuracy, otherwise leave and let the banner cover them.

### 5.9 c8ctl profile rename (`rancher-desktop` → `kubernetes`)

Client-side only; no cluster resources change.

- `configure-c8ctl.sh` creates/activates the `kubernetes` profile on next run.
- The Keycloak OIDC client (`zeebe-cli`), the `c8ctl-credentials` secret, the
  realm, and all authorizations are unaffected.
- Existing machines keep a stale `rancher-desktop` profile in the c8ctl config.
  Migration: `c8ctl remove profile rancher-desktop` (or leave it; harmless).
- **Document this migration** in `scripts/deploy/camunda/README.md` and the
  `DEPLOYMENT.md` cleanup/configure sections (confirmed decision §7 #5); do not
  auto-remove the old profile in `configure-c8ctl.sh`.
- Document the rename in the PR description so anyone with shell history
  updates their `--profile` flag.

---

## 6. Execution order

1. Land the moves from §5.1 (single commit; rename detection keeps diffs small).
2. Patch scripts (§5.2-§5.5) and run `bash -n` on each.
3. Patch `web/tests` config and utils (§5.6).
4. Patch **all** documentation (§5.8): live docs first, then the mechanical
   path/profile pass over the historical planning docs.
5. Update `.gitignore` (§5.5).
6. Run the validation checklist (§8).
7. Final sweep: `rg -n "rancher-desktop|playwright-tests|deploy/"` and confirm
   every remaining hit is either an intentional host-name mention
   ("Rancher Desktop k3s" prose) or a quotation inside `docs/dir_structure.md`
   itself. No live path may remain stale.

---

## 7. Resolved decisions

All previously-open items are confirmed and are now part of the work above.

| # | Item | Decision |
|---|------|----------|
| 1 | `env_exports.sh` lookup in `camunda-deploy-no-domain.sh` | **Fix to repo root** (`$CAMUNDA_DIR/../../..`) so the root-level `env_exports.sh` named in `.gitignore` is actually sourced. |
| 2 | `docs/services_implementation_plan.md` | **Update** to the new layout (it is a live reference linked from `Testing_Guide.md`, and the goal is zero stale references). |
| 3 | Unused `C8CTL_PROFILE` in `web/tests/.env.example` | **Delete the line.** |
| 4 | Rename `RANCHER_DIR` shell variable | **Yes → `CAMUNDA_DIR`** (cosmetic; update all uses: lines 34, 35, 39, 40, 42, 266). |
| 5 | Legacy `rancher-desktop` profile cleanup | **Document the manual command** (`c8ctl remove profile rancher-desktop`) in `scripts/deploy/camunda/README.md` / `DEPLOYMENT.md`; do not auto-remove in `configure-c8ctl.sh`. |
| 6 | `deploy.sh` `$CAMUNDA_NAMESPACE` typo at line ~155 | **Fix** to `$NAMESPACE`. |
| 7 | Historical planning docs | **Update path/profile references too**, so the whole repo is accurate (mechanical substitutions + banner; §5.8). |

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

Reference sweep (goal: **no stale references anywhere**):

- [ ] `rg -n "playwright-tests" .` → only `docs/dir_structure.md` (plan quotations)
- [ ] `rg -n "deploy/rancher-desktop|deploy/services|\./deploy/deploy\.sh" .` → only `docs/dir_structure.md`
- [ ] `rg -n "profile=rancher-desktop|profile \`rancher-desktop\`" .` → only `docs/dir_structure.md`
- [ ] Re-run the three `rg` commands above and confirm no hits outside the plan doc
- [ ] `git status` shows renames, not delete+add, for the moved trees

---

## 9. Reference index (current locations)

Files that reference the moved paths/profiles (line numbers are pre-move and
may shift as edits land):

| File | Lines (pre-move) | What it references |
|------|------------------|--------------------|
| `deploy/deploy.sh` | 3, 10, 13-18, 27, 28, 39, 140 | its own path, `rancher-desktop/scripts`, `deploy/services` |
| `deploy/services/build-deploy.sh` | 14, 26, 54, 117, 120 | profile, `deploy/services/{Dockerfile,manifests.yaml}` |
| `deploy/rancher-desktop/scripts/camunda-deploy-no-domain.sh` | 18, 82, 336-339 | `rancher-desktop/manifests`, README path, profile echoes |
| `deploy/rancher-desktop/scripts/configure-c8ctl.sh` | 43, 69 | profile default + usage |
| `deploy/rancher-desktop/README.md` | 6, 9, 38, 107, 108, 111 | `../../DEPLOYMENT.md`, its own tree, uninstall path |
| `playwright-tests/playwright.config.ts` | 30 | `../services/cmd/webapp` |
| `playwright-tests/utils/zeebe.ts` | 26 | `./deploy/deploy.sh` |
| `playwright-tests/.env.example` | 5 | `C8CTL_PROFILE=rancher-desktop` |
| `.gitignore` | 37 | `playwright-tests/node_modules/` |
| `README.md` | 13, 22, 25, 50, 52 | deploy commands, playwright path, profile |
| `DEPLOYMENT.md` | 4, 14, 20, 23, 27, 44, 53, 56, 65, 76, 79, 81, 86, 90, 97, 100, 106, 116, 126, 135, 183, 197-205, 217-220, 235-237, 247, 294-309, 317-320 | paths, playwright, uninstall, profile |
| `docs/Testing_Guide.md` | 28, 29, 32, 34, 40, 43, 60-72, 75, 131, 144, 145, 156, 170-174, 185, 186, 196, 213, 224, 225, 236, 265, 276-292 | deploy commands, manifests, profile |
| `docs/services_implementation_plan.md` | 13, 14, 53, 341, 359, 379, 381, 403-429, 436 | deploy paths, profile |
| `docs/deployment_update.md` | 14, 19, 20, 40, 46, 53, 76, 84, 94, 98, 104, 106, 108, 110, 115, 116, 122, 137, 150, 155, 170, 173, 191, 201, 213, 214, 222, 236, 239-242, 244, 256, 257 | historical — path/profile substitution |
| `docs/deployment_update_v2.md` | 17, 18, 20, 22, 23, 34, 40-42, 45, 46, 49, 60, 61, 67, 113, 130, 149, 159, 173, 180, 182, 192, 193, 202, 211, 212, 216, 220, 244, 247, 254, 267, 284, 291, 301, 302, 304, 305, 308, 321, 338-343, 346, 349 | historical — path/profile substitution |
| `docs/frontend-plan.md` | 81, 103, 106 | historical — path substitution |
| `docs/frontend-plan-v2.md` | 163, 202 | historical — path substitution |
| `docs/frontend-plan-v3.md` | 15, 244, 253, 256, 261, 263, 312, 322, 329, 345, 360, 368, 378, 420, 470, 482 | historical — path/profile substitution |
| `docs/frontend-plan-v4.md` | 24, 26, 28, 300, 318, 321, 330, 332, 334, 385, 388, 390, 394, 404, 420, 437, 550, 560, 562 | historical — path/profile substitution |
| `docs/dir_structure.md` | (this file) | intentionally quotes old paths; excluded from sweeps |
