# Deployment Guide: CMS Provider Enrollment Framework

This document covers uploading and deploying the enrollment workflow artifacts to a Camunda 8 cluster.

---

## Prerequisites

| Requirement | Check |
|---|---|
| `c8ctl` CLI installed | `c8ctl --version` |
| Camunda 8 cluster running | `c8ctl get topology` |
| Correct profile active | `c8ctl which profile` |

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

**Total: 14 deployable artifacts**

---

## Deployment Order

Artifacts have dependencies. Forms and DMN decisions must be deployed before BPMN files that reference them.

### Option A: Single Command (Recommended)

`c8ctl deploy` auto-discovers all deployable files (`.bpmn`, `.dmn`, `.form`) in a directory tree:

```bash
c8ctl deploy .
```

This deploys all 14 artifacts in a single request. Camunda resolves dependencies internally.

### Option B: Step-by-Step Deploy

Deploy in dependency order if you need granular control:

**Step 1 — Forms and DMN (no dependencies)**

```bash
c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/
```

**Step 2 — Shared services (reference forms/DMN)**

```bash
c8ctl deploy workflows/855x-combined/shared/
```

**Step 3 — Delegates (reference shared services)**

```bash
c8ctl deploy workflows/855x-combined/delegates/
```

**Step 4 — Orchestrator (references everything)**

```bash
c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn
```

---

## Verification

After deployment, verify all artifacts are registered:

### Check Process Definitions

```bash
c8ctl list pd
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

### Search for Enrollment Processes

```bash
c8ctl search pd --iname='*enrollment*'
c8ctl search pd --iname='*delegate*'
```

### Visual Verification

```bash
c8ctl open operate    # View process definitions and instances
c8ctl open tasklist   # Verify forms render on user tasks
```

### Test a Process Instance

```bash
c8ctl run Enrollment_Orchestrator.bpmn
```

This deploys (if not already) and starts a new instance. Use Operate to trace execution.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Connection refused` | Start the cluster: `c8ctl cluster start` |
| `Process not found` | Check profile: `c8ctl which profile`. Deploy with `--profile` if needed |
| `Form not found` on user task | Forms must be deployed before BPMN. Redeploy `forms/` first |
| `Decision not found` on business rule task | DMN must be deployed before BPMN. Redeploy `decisions/` first |
| `no-implicit-start` lint error | Missing sequence flow on a task. Run `c8ctl bpmn lint <file>` to identify |
