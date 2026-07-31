# Deployment Guide: CMS Provider Enrollment Framework

This document covers uploading and deploying the enrollment workflow artifacts to a Camunda 8 cluster.

---

## Prerequisites

| Requirement | Check |
|---|---|
| `c8ctl` CLI installed | `c8ctl --version` |
| Camunda 8 cluster running | `c8ctl get topology --profile=rancher-desktop` |
| Correct profile active | `c8ctl which profile` (should be `rancher-desktop`) |

This guide targets the local Rancher Desktop k3s deployment in this repo. Before
running c8ctl commands, start the port-forwards (`./scripts/camunda-port-forwards.sh`
from `deploy/rancher-desktop/`) and use the `rancher-desktop` profile. See
`deploy/rancher-desktop/README.md` for details.

---

## Artifact Inventory

### Forms (3)

| File | Purpose | Linked By |
|---|---|---|
| `workflows/855x-combined/forms/enrollment-start.form` | Master intake form for all enrollment types | `Enrollment_Orchestrator.bpmn` (start event) |
| `workflows/855x-combined/forms/review-validation.form` | Expert review of automated validation results | `Shared_Intake.bpmn` (user task) |
| `workflows/855x-combined/forms/site-visit-report.form` | Facility site visit report (855A/B) | `Delegate_855A.bpmn`, `Delegate_855B.bpmn` (user tasks) |

### DMN Decisions (3)

| File | Purpose | Called By |
|---|---|---|
| `workflows/855x-combined/decisions/Enrollment_Documentation.dmn` | Determines required documentation by enrollment type | `Enrollment_Orchestrator.bpmn` |
| `workflows/855x-combined/decisions/Eligibility_Rules.dmn` | Evaluates enrollment eligibility | `Enrollment_Orchestrator.bpmn` |
| `workflows/855x-combined/decisions/Processing_Timeline.dmn` | Calculates processing timeline estimates | `Enrollment_Orchestrator.bpmn` |

### Shared BPMN Processes (4)

| File | Purpose | Called By |
|---|---|---|
| `workflows/855x-combined/shared/Shared_Intake.bpmn` | Application logging, tracking, and validation review | All delegates |
| `workflows/855x-combined/shared/Shared_OIG_Screening.bpmn` | OIG/SAM exclusion and NPI/TIN verification | All delegates |
| `workflows/855x-combined/shared/Shared_SA_Referral.bpmn` | 45-day SA referral loop and escalation | All delegates |
| `workflows/855x-combined/shared/Error_Handling.bpmn` | Centralized error handling for service failures | All delegates |

### Delegate BPMN Processes (3)

| File | Purpose | Called By |
|---|---|---|
| `workflows/855x-combined/delegates/Delegate_855I.bpmn` | Individual practitioner enrollment logic | `Enrollment_Orchestrator.bpmn` |
| `workflows/855x-combined/delegates/Delegate_855A.bpmn` | Organization/facility enrollment logic | `Enrollment_Orchestrator.bpmn` |
| `workflows/855x-combined/delegates/Delegate_855B.bpmn` | DMEPOS supplier enrollment logic | `Enrollment_Orchestrator.bpmn` |

### Orchestrator (1)

| File | Purpose |
|---|---|
| `workflows/855x-combined/Enrollment_Orchestrator.bpmn` | Top-level process managing the full enrollment lifecycle |

### Standalone 855I Reference (3)

| File | Purpose |
|---|---|
| `workflows/855i-single/cms855i-enrollment.bpmn` | Standalone single-delegate 855I process (id `cms855i-mac-enrollment`) |
| `workflows/855i-single/cms855i-enrollment.dmn` | Three decisions: `required-documentation`, `site-visit-determination`, `processing-timeline` |
| `workflows/855i-single/cms855i-start-form.form` | Start form for the standalone 855I process |

**Total: 17 deployable artifacts**

---

## Deployment Order

Artifacts have dependencies. Forms and DMN decisions must be deployed before BPMN files that reference them.

### Option A: Single Command (Recommended)

`c8ctl deploy` auto-discovers all deployable files (`.bpmn`, `.dmn`, `.form`) in a directory tree:

```bash
c8ctl deploy . --profile=rancher-desktop
```

This deploys all 17 artifacts (the 14 `855x-combined` artifacts plus the three standalone
`855i-single` files) in a single request. Camunda resolves dependencies internally.

### Option B: Step-by-Step Deploy

Deploy in dependency order if you need granular control:

**Step 1 — Forms and DMN (no dependencies)**

```bash
c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile=rancher-desktop
```

**Step 2 — Shared services (reference forms/DMN)**

```bash
c8ctl deploy workflows/855x-combined/shared/ --profile=rancher-desktop
```

**Step 3 — Delegates (reference shared services)**

```bash
c8ctl deploy workflows/855x-combined/delegates/ --profile=rancher-desktop
```

**Step 4 — Orchestrator (references everything)**

```bash
c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile=rancher-desktop
```

---

## Verification

After deployment, verify all artifacts are registered:

### Check Process Definitions

```bash
c8ctl list pd --profile=rancher-desktop
```

Expected process definitions:
- `Enrollment_Orchestrator`
- `Delegate_855I`
- `Delegate_855A`
- `Delegate_855B`
- `Shared_Intake`
- `Shared_OIG_Screening`
- `Shared_SA_Referral`
- `Error_Handling`
- `cms855i-mac-enrollment` (only if the standalone `855i-single` files are deployed)

### Search for Enrollment Processes

```bash
c8ctl search pd --iname='*enrollment*' --profile=rancher-desktop
c8ctl search pd --iname='*delegate*' --profile=rancher-desktop
```

### Visual Verification

```bash
c8ctl open operate --profile=rancher-desktop    # View process definitions and instances
c8ctl open tasklist --profile=rancher-desktop   # Verify forms render on user tasks
```

### Test a Process Instance

```bash
c8ctl run Enrollment_Orchestrator.bpmn --profile=rancher-desktop
```

This deploys (if not already) and starts a new instance. Use Operate to trace execution.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Connection refused` | Start the port-forwards: `./scripts/camunda-port-forwards.sh` (Rancher Desktop k3s must be running). This deployment does not use `c8ctl cluster start` |
| `Process not found` | Check profile: `c8ctl which profile` — it must be `rancher-desktop`. Add `--profile=rancher-desktop` if needed |
| `Form not found` on user task | Forms must be deployed before BPMN. Redeploy `workflows/855x-combined/forms/` first |
| `Decision not found` on business rule task | DMN must be deployed before BPMN. Redeploy `workflows/855x-combined/decisions/` first |
| `no-implicit-start` lint error | Missing sequence flow on a task. Run `c8ctl bpmn lint <file>` to identify |
