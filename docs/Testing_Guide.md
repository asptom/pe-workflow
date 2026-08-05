# Testing Guide — 855x Enrollment Workflows on the Local Cluster

## Overview

This guide walks through validating the 855x enrollment orchestration on the local
Camunda 8 cluster (Rancher Desktop k3s, namespace `camunda`). The workflow has been
tuned for demo speed:

- All real-world timers are replaced with short ones and the external-party outcomes
  (SA/AO response, CMS decision) are produced by the new **simulator** service instead
  of real-world wait times:
  - `Timer_45DayReview` (Shared_SA_Referral): `PT5S`
  - `Timer_14DayFollowUp` (Shared_SA_Referral): `PT3S`
  - `Timer_AdditionalInfo` (Enrollment_Orchestrator): `PT5S`
  - `Timer_CMSDecision` (Enrollment_Orchestrator): `PT5S`
- The Go microservices (`eligibility`, `verification`, `scheduling`, `documents`,
  `notifications`, and now `simulator`) each run an embedded job worker registered
  against the cluster's Zeebe gateway.

A complete run of the simplest scenario (855I) takes roughly 20–30 seconds end to end,
including the simulated review/decision pauses.

## Prerequisites

1. Cluster reachable. Start the port-forwards and confirm the topology:

   ```bash
   ./deploy/rancher-desktop/scripts/camunda-port-forwards.sh
   c8ctl get topology --profile=rancher-desktop
   ```

2. c8ctl profile `rancher-desktop` is configured and authorized (see
   `docs/services_implementation_plan.md` §9 for the auth setup). Always pass
   `--profile=rancher-desktop`.

3. Services deployed. Build the six images, apply the manifests, wait for rollout,
   and deploy the workflow resources in the verified order:

   ```bash
   ./deploy/services/build-deploy.sh --services --resources
   ```

   This runs `docker build` per service, `kubectl apply -f deploy/services/manifests.yaml`,
   `kubectl rollout status deployment/pe-<svc> -n camunda --timeout=120s`, then the four
   `c8ctl deploy` resource steps below.

4. Confirm the workers are up:

   ```bash
   kubectl get deploy -n camunda
   kubectl logs -n camunda deployment/pe-simulator      # expect both workers open
   kubectl logs -n camunda deployment/pe-notifications   # expect worker open
   ```

## 1. Deploy resources

After editing any BPMN/DMN/form, lint the edited diagrams first:

```bash
c8ctl bpmn lint workflows/855x-combined/shared/Shared_SA_Referral.bpmn --profile=rancher-desktop
c8ctl bpmn lint workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile=rancher-desktop
```

Both must report **No issues found.** Then deploy in this order (forms + DMN first,
shared processes before the orchestrator that calls them, delegates next, orchestrator
last so the top-level process resolves to the newest child versions):

```bash
c8ctl deploy workflows/855x-combined/forms/ workflows/855x-combined/decisions/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/shared/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/delegates/ --profile=rancher-desktop
c8ctl deploy workflows/855x-combined/Enrollment_Orchestrator.bpmn --profile=rancher-desktop
```

Or just `./deploy/services/build-deploy.sh --resources`.

## 2. The simulator

`pe-simulator` (`:8086`) runs two job workers that replace external-party wait times
with short random outcomes:

| Job type | Completes with | Default behavior |
|---|---|---|
| `simulate-sa-review` | `saAoResponseReceived` (bool), `saAoOutcome` (`Responded`/`No response`) | Sleeps 2–4 s, then 50/50 responded vs no response |
| `simulate-cms-decision` | `cmsDecision` (`Approved`/`Denied`) | Sleeps 2–4 s, then 50/50 Approved vs Denied |

Both workers read an optional **`force`** job variable (populated by ioMapping inputs,
with the old `force` task header as fallback) that overrides the randomness:

| Worker | `force` values |
|---|---|
| `simulate-sa-review` | `responded` → always responded; `timeout` → always no response |
| `simulate-cms-decision` | `Approved` / `Denied` → always that decision |

There is also an informational `phase` job variable on the SA tasks (`initial` /
`followup`, an ioMapping input with the header as fallback) that does not change
behavior — it exists so the two `simulate-sa-review` jobs in `Shared_SA_Referral` are
distinguishable in the logs.

The BPMN wiring:

- `Shared_SA_Referral`: `Task_SimulateSAReview` (`phase=initial`) runs after the 5 s
  review timer and writes `referral.saAoResponseReceived` / `referral.saAoOutcome`;
  `Task_SimulateFollowUp` (`phase=followup`) does the same after the 3 s follow-up
  timer. Both use ioMapping outputs into the `referral` object, which the two XOR
  gateways then read.
- `Enrollment_Orchestrator`: `Task_SimulateCMSDecision` runs after the 5 s CMS timer
  and writes the top-level `cmsDecision` variable that `Gateway_CMSDecision` reads.
  No ioMapping — the variable lands directly in the process scope.

To make a run deterministic, start the process instance with a `force` **process
variable** instead of a task header — see Scenario 6. Otherwise re-run and you will see
different branches.

## 3. Scenario matrix

All scenarios use `c8ctl create pi` against the already-deployed process definition.
The `--variables` payload is the process start form data (`provider`, plus the flat
`submissionMethod`). You can replace `create pi` with `c8ctl run <path-to-bpmn>`
which deploys and starts in one step, but the steps below use `create pi` so you start
the exact deployed definition.

### Scenario 1 — 855I (no user tasks)

Individual practitioner, no human interaction required.

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855I","legalName":"Jane Doe MD","npi":"1234567893","tin":"123456789","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
```

- NPI `1234567893` ends in an odd digit and no `state` is supplied, so the OIG screen
  scores `30 + 25 + 20 = 75` → **CONDITIONAL** (site visit required).
- Expected execution path: doc determination → generate-doc → 855I delegate
  (verify-license, verify-board-cert) → eligibility → **CONDITIONAL** →
  additional-info notification → 5 s timer → timeline → forward-to-CMS notification →
  5 s timer → simulated CMS decision → approval **or** denial letter → **COMPLETED**.
- Expected key variables afterwards — see §6.
- Verification:

  ```bash
  c8ctl list pi --profile=rancher-desktop
  c8ctl search vars --processInstanceKey=<key> --profile=rancher-desktop --fullValue
  ```

### Scenario 2 — 855A (two user tasks)

Organization/Facility. The delegate pauses at **two** user tasks that you complete
from the CLI (or Tasklist).

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855A","legalName":"Main Street Clinic","npi":"1111111116","tin":"123456789","entityType":"Facility","licenseNumber":"LIC-1001","fireSafetyCertification":"FSC-2026","state":"NY","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
```

- NPI `1111111116` ends in an even digit and `state` is supplied, so the risk score
  stays `30` → **ELIGIBLE** (no additional-info detour).
- Expected execution path: doc determination → generate-doc → 855A delegate → OIG
  screening → **Review Facility Application** user task → verify-license →
  verify-fire-safety → SA referral (simulated in seconds) → **Complete Site Visit
  Report** user task → process-site-visit → eligibility → timeline → forward to CMS →
  simulated CMS decision → letter → **COMPLETED**.

Complete the two user tasks:

```bash
c8ctl list ut --profile=rancher-desktop
# 1. Review Facility Application
c8ctl complete ut <key> --variables '{"approvalDecision":"Approve"}' --profile=rancher-desktop
# 2. Complete Site Visit Report
c8ctl complete ut <key> --variables '{"siteVerified":true,"siteVisitOutcome":"Passed","fireSafetyCompliant":true}' --profile=rancher-desktop
```

- The review form (`review-validation.form`) binds `approvalDecision` (`Approve`/`Deny`).
- The site visit form (`site-visit-report.form`) binds `siteVerified`,
  `fireSafetyCompliant`, etc.; the `process-site-visit` worker additionally reads
  `siteVisitOutcome` (`Passed`/anything else) and sets `provider.siteVerified` and
  `followUpRequired`.
- Verification:

  ```bash
  c8ctl list ut --profile=rancher-desktop   # should be empty once both are done
  c8ctl search vars --processInstanceKey=<key> --profile=rancher-desktop --fullValue
  ```

### Scenario 3 — 855B (no user tasks)

DMEPOS supplier, no human interaction.

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855B","legalName":"Acme DME Supply","npi":"1999999996","tin":"123456789","entityType":"DME Supplier","stateLicenseNumber":"SL-77","suretyBondAmount":100000,"equipmentLicenseNumber":"EQ-01","state":"FL","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
```

- Even-last-digit NPI + `state` supplied → risk score `30` → **ELIGIBLE**.
- Expected path: doc determination → generate-doc → 855B delegate (verify-license on
  the state license, verify-bond ≥ 50000, verify-equipment) → eligibility → timeline →
  forward to CMS → simulated CMS decision → letter → **COMPLETED**.
- No user tasks appear. Verify with `c8ctl search vars --processInstanceKey=<key> --fullValue`
  and check `bondValid`, `equipmentLicensureValid`, `tinValid`, `cmsDecision`.

### Scenario 4 — EXCLUDED provider

OIG screening fails for any legal name containing `EXCLUDED`.

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855I","legalName":"EXCLUDED PROVIDER","npi":"1234567893","tin":"123456789"}}' \
  --profile=rancher-desktop
```

- Expected path: OIG screening returns `oigCleared=false` → eligibility →
  **INELIGIBLE** → ineligibility notification → **EndEvent_Ineligible**. No timers
  and no simulator jobs are involved.
- Expected variables: `oigCleared=false`, `eligibilityResult.eligibilityStatus="INELIGIBLE"`,
  `ineligibilityNoticeStatus` set, no `cmsDecision`, no letter statuses.
- Verify the end state:

  ```bash
  c8ctl list pi --id Enrollment_Orchestrator --profile=rancher-desktop
  c8ctl search vars --processInstanceKey=<key> --profile=rancher-desktop --fullValue
  ```

### Scenario 5 — CONDITIONAL + additional info

High-risk provider (odd NPI + empty state → score 75, ≥ 75 → CONDITIONAL with a site
visit flag) exercises the additional-information branch and the 5 s response window.

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855B","legalName":"Coastal DME Services","npi":"1234567893","tin":"123456789","entityType":"DME Supplier","stateLicenseNumber":"SL-99","suretyBondAmount":100000,"equipmentLicenseNumber":"EQ-02"}}' \
  --profile=rancher-desktop
```

- No `state` and an odd-last-digit NPI → risk score `75` → **CONDITIONAL**,
  `siteVisitRequired=true`.
- Expected path: … delegate → eligibility → **CONDITIONAL** → additional-info
  notification → 5 s timer → timeline → forward-to-CMS notification → 5 s timer →
  simulated CMS decision → letter → **COMPLETED**.
- Expected variables: `providerRiskScore=75`, `additionalInfoRequestStatus` set,
  `eligibilityResult.siteVisitRequired=true`, then the normal timeline/CMS/letter
  variables. Watch the 5 s window elapse with `c8ctl watch`.

### Scenario 6 — Forcing a branch deterministically

Runs are 50/50 random. To pin a specific outcome for a repeatable demo, start the
process instance with the `force` **process variable** — no redeploy or BPMN edit is
needed. The simulator reads `force` from the job variables on this cluster (see §8):

- **Always respond** (SA/AO review): start the instance with the variable
  `{"force":"responded"}`. `{"force":"timeout"}` pins no-response → follow-up →
  escalation path instead.
- **Always approve** (CMS decision): start with `{"force":"Approved"}`.
  `{"force":"Denied"}` pins the denial branch.

Add `force` to the start variables of any scenario payload, e.g.:

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"force":"responded","provider":{"enrollmentType":"855I","legalName":"Jane Doe MD","npi":"1234567893","tin":"123456789","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=rancher-desktop
```

The outcome is now deterministic. Omit `force` from the variables to go back to random.
Note `force` is read per activated job — instances already running keep the value they
started with.

## 4. Verification commands

| Purpose | Command |
|---|---|
| Live tail of process activity | `c8ctl watch --profile=rancher-desktop` |
| Find the instance key | `c8ctl list pi --id Enrollment_Orchestrator --profile=rancher-desktop` |
| Jobs activated / pending workers | `c8ctl list jobs --processInstanceKey=<key> --profile=rancher-desktop` |
| Full variable dump | `c8ctl search vars --processInstanceKey=<key> --profile=rancher-desktop --fullValue` |
| Open user tasks | `c8ctl list ut --profile=rancher-desktop` |
| Complete a user task | `c8ctl complete ut <key> --variables '<json>' --profile=rancher-desktop` |
| Active incidents (expect none) | `c8ctl search inc --profile=rancher-desktop` |
| Simulator decisions in the logs | `kubectl logs -n camunda deployment/pe-simulator` |
| Notification sends in the logs | `kubectl logs -n camunda deployment/pe-notifications` |
| Cancel a stuck instance | `c8ctl cancel pi <key> --profile=rancher-desktop` |

End-of-run checks:

```bash
c8ctl search inc --profile=rancher-desktop          # expect: no active incidents
c8ctl list pi --state COMPLETED --profile=rancher-desktop
c8ctl search vars --processInstanceKey=<key> --profile=rancher-desktop --fullValue
```

## 5. Eligibility and timeline branching rules

### `Eligibility_Rules.dmn` (hit policy FIRST)

Inputs: `enrollmentType` (unused by the rules), `providerRiskScore` (number),
`npiIsActive` (boolean), `oigCleared` (boolean). Outputs: `eligibilityStatus`,
`siteVisitRequired`. First matching rule wins:

| Rule | When | `eligibilityStatus` | `siteVisitRequired` |
|---|---|---|---|
| 1 | `npiIsActive = false` | INELIGIBLE | false |
| 2 | `oigCleared = false` | INELIGIBLE | false |
| 3 | `providerRiskScore >= 75` | CONDITIONAL | true |
| 4 | `providerRiskScore >= 50` | CONDITIONAL | false |
| 5 | default (anything else) | ELIGIBLE | false |

How the inputs are produced:

- `oigCleared` / `samCleared` / `providerRiskScore` come from the `screen-oig` /
  `screen-sam` workers. The OIG screen returns `cleared=false` whenever
  `legalName` contains `EXCLUDED` (SAM clears unless the name contains `DEBARRED`).
- `providerRiskScore` is `30` base, `+25` when the NPI's last digit is odd, `+20`
  when `state` is empty — so `30` (even NPI + state) is ELIGIBLE, `55` (odd NPI +
  state) is CONDITIONAL, `75` (odd NPI + no state) is CONDITIONAL + site visit.
- `npiIsActive` comes from `verify-npi` (real Luhn check digit on the NPI);
  `tinValid` from `verify-tin`.

Consequences in the orchestrator:

- INELIGIBLE → `Task_SendIneligibility` → `EndEvent_Ineligible` (no timers).
- CONDITIONAL → `Task_RequestAdditionalInfo` → 5 s `Timer_AdditionalInfo` →
  merge → timeline.
- ELIGIBLE → straight to the timeline.

### `Processing_Timeline.dmn` (hit policy UNIQUE)

Inputs: `submissionMethod` (`PECOS`/`Paper`), `siteVisitRequired`. Outputs:
`intakeDays`, `validationDays`, `saAoReviewDays`, `siteVisitDays`, `cmsDecisionDays`,
`totalEstimateDays`.

| submissionMethod | siteVisitRequired | totals (intake/validation/SA-AO/site visit/CMS) |
|---|---|---|
| PECOS | true | 5 / 10 / 45 / 45 / 30 → **135** |
| PECOS | false | 5 / 10 / 45 / 0 / 30 → **90** |
| Paper | true | 15 / 15 / 45 / 45 / 30 → **150** |
| Paper | false | 15 / 15 / 45 / 0 / 30 → **105** |

## 6. Expected variables for the 855I run

After Scenario 1 completes, `c8ctl search vars --processInstanceKey=<key> --fullValue`
should show roughly:

```json
{
  "provider": {
    "enrollmentType": "855I",
    "legalName": "Jane Doe MD",
    "npi": "1234567893",
    "tin": "123456789",
    "filingDate": "2026-07-01"
  },
  "submissionMethod": "PECOS",
  "documentation": { "documentId": "DOC-1234567893-<unix>", "format": "PDF", "pages": 2, "generatedAt": "<timestamp>" },
  "providerRiskScore": 75,
  "oigCleared": true,
  "samCleared": true,
  "npiIsActive": true,
  "tinValid": true,
  "eligibilityResult": { "eligibilityStatus": "CONDITIONAL", "siteVisitRequired": true },
  "additionalInfoRequestStatus": "Sent: additional-info to Jane Doe MD",
  "timelineResult": { "intakeDays": 5, "validationDays": 10, "saAoReviewDays": 45, "siteVisitDays": 45, "cmsDecisionDays": 30, "totalEstimateDays": 135 },
  "cmsForwardStatus": "Sent: cms-forward to CMS Provider Enrollment",
  "cmsDecision": "Approved",
  "approvalLetterStatus": "Sent: approval to Jane Doe MD"
}
```

Exactly one of `approvalLetterStatus` (`cmsDecision=Approved`) or `denialLetterStatus`
(`cmsDecision=Denied`) is present; the other letter status is absent. The 855A/855B
ELIGIBLE runs produce the same shape minus `additionalInfoRequestStatus`, with
`eligibilityResult.eligibilityStatus="ELIGIBLE"` and `totalEstimateDays=90`, and the
855A run additionally carries `approvalDecision`, `provider.siteVerified=true`,
`siteVisitOutcome="Passed"`, and `followUpRequired=false`.

## 7. Random vs deterministic

- By default the SA/AO review and the CMS decision are **50/50 random** (plus a
  random 2–4 s pause each). Re-run the same `create pi` command to see different
  branches — e.g. an approval letter on one run and a denial letter on the next, or a
  same-day response vs the follow-up/escalation path.
- To make a run deterministic, start the instance with a `force` process variable
  (Scenario 6) — `{"force":"responded"}` (or `"timeout"`) for the SA/AO review and
  `{"force":"Approved"}` / `{"force":"Denied"}` for the CMS decision. No redeploy needed.
- The `phase` variable is informational only and never affects the outcome.

## 8. Troubleshooting / known cluster behavior

This local cluster runs Zeebe 8.9.12, which does **not** deliver BPMN custom task
headers on job activation (`customHeaders` is always `{}`). Therefore the services read
`kind` / `force` / `phase` from the **job variables** populated by the ioMapping inputs
in the BPMN, with the task headers as a fallback on correctly-behaving clusters. If an
outcome or notification seems wrong on this cluster, check the process variables
(`c8ctl search vars --fullValue`) rather than the task headers in the diagram.

Rarely, a job gets "ghost activated": it stays `CREATED` with full retries but no worker
can activate it (observed once for `verify-tin`), and even `c8ctl update job --retries 3`
does not unstick it. There is no incident. Fix: cancel the process instance and re-create
it — a fresh instance passes fine.
