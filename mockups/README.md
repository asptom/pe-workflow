# Enrollment Workbench — Design Prototype (v0.1)

High-fidelity, clickable HTML mockups of the **provider enrollment specialist's workbench** — the
companion experience to the Camunda 8 provider-enrollment workflows in this repo. This is the design
phase deliverable: it defines *what the specialist sees and does* before any Angular is written.

**Concept:** *the case file, operationalized.* Not a Camunda visualizer and not a generic task list —
a desk where every assignment arrives with its reason, deadline, evidence, and live workflow position.

## Open it

No build step, no server required:

```
open mockups/index.html        # narrative hub + links (best starting point for a demo)
open mockups/dashboard.html    # straight into the specialist's day
```

Fonts load from Google Fonts (Libre Franklin · Public Sans · IBM Plex Mono); offline it falls back
to system faces and everything still works.

## Screens

| # | File | What it demonstrates |
|---|------|----------------------|
| 0 | `index.html` | Narrative hub: concept, design principles, screen guide, and the mapping to the repo's real BPMN/DMN/forms |
| 1 | `dashboard.html` | "My Work": KPIs, enrollment pipeline band (8 stages), **prioritized attention queue**, full assignment register, outcomes feed, in-place intake modal, ineligibility-determination modal |
| 2 | `case-review.html` | Case file + live journey through `Delegate_855A` + the `review-validation.form` action panel (automated validation readouts, comments, Approve/Deny) |
| 3 | `case-site-visit.html` | The second human task: `site-visit-report.form` as a field report — site verification, findings, fire-safety pass |
| 4 | `case-response.html` | The conditional path: SA/AO "Favorable" response received, provider answered inside the 30-day window — verify the response and release to CMS |

## The demo loop (2 minutes, fully clickable)

1. `dashboard.html` → attention queue shows **Main Street Clinic — Review Facility Application**.
2. Open the case → record **Approve** → you land back on the dashboard with the case advanced
   (stage dots move, pill flips to *In flight*, attention count drops, a confirmation toast explains
   what the workflow did next).
3. Repeat with **Lakeview Surgical Center** (check *Site verified* → submit) and **Coastal DME Services**
   (check all three verification items → *Release to CMS review*).
4. Extras: **Fairfield Home Medical** opens the ineligibility-determination modal (LEIE match,
   `Eligibility_Rules → INELIGIBLE`); **＋ Start application** opens the `enrollment-start` intake form
   and drops a new case into the register.

A `?resolved=review|sitevisit|response` query param drives the loop so the demo is repeatable.

## Grounded in the real project — nothing invented

| Mockup element | Source artifact in this repo |
|---|---|
| Review Facility Application | `workflows/855x-combined/forms/review-validation.form` · user task in `delegates/Delegate_855A.bpmn` |
| Complete Site Visit Report | `workflows/855x-combined/forms/site-visit-report.form` · user task in `Delegate_855A.bpmn` |
| Intake modal fields | `workflows/855x-combined/forms/enrollment-start.form` |
| Required-documentation checklists | `decisions/Enrollment_Documentation.dmn` |
| Eligibility states & risk 75 → conditional | `decisions/Eligibility_Rules.dmn` + risk-score logic in `docs/Testing_Guide.md` |
| "Est. 135-day timeline" | `decisions/Processing_Timeline.dmn` (PECOS + site visit) |
| Journey stages, SA/AO windows, CMS decision, letter kinds | `Enrollment_Orchestrator.bpmn`, `shared/Shared_Intake.bpmn`, `Shared_OIG_Screening.bpmn`, `Shared_SA_Referral.bpmn` |
| Provider names, NPIs, outcomes | `docs/Testing_Guide.md` scenarios 1–5 + `workflows/855i-single/cms855i-start-form.form` defaults |

## Phase 2 — porting to the real app

The existing Angular 18 app (`web/`) already has form-js, bpmn-js, and a Go BFF proxying Zeebe REST v2.
Each mockup panel maps directly onto existing endpoints (`docs/api/bff.openapi.yaml`):

- Attention queue ← `GET /v2/user-tasks/search` (by candidate group) enriched with process variables
- Register / pipeline ← `GET /v2/process-instances/search` + variables (stage = derived from active element / variables)
- Journey timeline ← instance variables + executed sequence flows (already fetched by `ProcessDetailComponent`)
- Action panels ← `GET /v2/user-tasks/{key}/form` rendered with form-js; complete via `POST /v2/user-tasks/{key}/completion`
- KPIs / timers ← DMN timeline outputs + task ages; long-lived timers surface as dashboard chips

Suggested next steps: (1) review/adjust the visual direction with stakeholders, (2) rename the product
("Enrollment Workbench" is a placeholder), (3) port the dashboard first, then case pages, keeping the
existing BFF.