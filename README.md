# pe-workflow

Enrollment workflow modeling and local deployment for Camunda 8.

## Structure

- `workflows/` — BPMN, DMN, and Camunda Form artifacts
  - `855x-combined/` — the combined enrollment framework (orchestrator, delegates, shared services, decisions, forms)
  - `855i-single/` — a standalone single-delegate 855I reference process
- `services/` — Go microservices, one binary per service, each running Camunda 8 job workers for the combined workflows
  - `cmd/` — eligibility, verification, scheduling, documents, notifications, simulator, webapp
  - `internal/zeebeworker/` — shared Zeebe client bootstrap and job-handling helpers
- `scripts/` — deployment scripts, Helm values, Kubernetes manifests, and the unified `deploy.sh`
- `web/tests/` — Playwright end-to-end tests for the Angular SPA and Go BFF
- `docs/` — testing guide and implementation plans

## Quick Start

**All deployment instructions live in [`DEPLOYMENT.md`](DEPLOYMENT.md).** In short:

```bash
# Deploy the full stack (no port-forwards needed during deploy)
./scripts/deploy.sh --all

# In a separate terminal, start port-forwards for interactive use
./scripts/deploy/camunda/scripts/camunda-port-forwards.sh
```

Open the application at <http://localhost:8088>. See `DEPLOYMENT.md` for prerequisites,
step-by-step deployment, partial deployment, credentials, and cleanup.

## Local development

Run the Go BFF and the Angular dev server on the host instead of in-cluster. See
[DEPLOYMENT.md § Local development](DEPLOYMENT.md#local-development) for the port-forwards,
environment variables, and commands.

## Playwright tests

See [DEPLOYMENT.md § Playwright tests](DEPLOYMENT.md#playwright-tests) and
[`docs/Testing_Guide.md`](docs/Testing_Guide.md) for setup and the scenario matrix.

## Running a process scenario

With the services, resources, and webapp deployed and port-forwards up, start a scenario
from [`docs/Testing_Guide.md`](docs/Testing_Guide.md):

```bash
c8ctl create pi --id Enrollment_Orchestrator \
  --variables '{"provider":{"enrollmentType":"855I","legalName":"Jane Doe MD","npi":"1234567893","tin":"123456789","filingDate":"2026-07-01"},"submissionMethod":"PECOS"}' \
  --profile=kubernetes

c8ctl watch --profile=kubernetes
```

`docs/Testing_Guide.md` covers all scenarios (855I, 855A, 855B, EXCLUDED, CONDITIONAL),
forcing outcomes deterministically with the `force` variable, and the expected end-state
variables.

## Microservices

All services connect to the Zeebe gateway with OAuth client credentials from the standard
`ZEEBE_*` environment variables and expose their own REST API (`/healthz` on every service).

| Service | Port | Job types |
| --- | --- | --- |
| eligibility | 8081 | `screen-oig`, `screen-sam` |
| verification | 8082 | `verify-npi`, `verify-tin`, `verify-license`, `verify-bond`, `verify-equipment`, `verify-fire-safety`, `verify-board-cert` |
| scheduling | 8083 | `process-site-visit` |
| documents | 8084 | `generate-doc` |
| notifications | 8085 | `send-notification` (kind selected via job variable: `ineligibility`, `additional-info`, `cms-forward`, `approval`, `denial`) |
| simulator | 8086 (container) / 8186 (localhost) | `simulate-sa-review`, `simulate-cms-decision` |
| pe-webapp | 8088 (local) / 8080 (container) | Go BFF and Angular SPA |

The simulator listens on `8086` inside the cluster and is exposed on `8186` locally so it
does not collide with Connectors (`8086`).

## Time-emulation mode

The combined workflows use the simulator to collapse long review waits into seconds:

- 45-day SA/AO review → `Timer_45DayReview` `PT5S`
- 14-day follow-up → `Timer_14DayFollowUp` `PT3S`
- 30-day additional-info and 30-day CMS decision → `PT5S` each

Outcomes are 50/50 random. Start a process instance with a `force` variable to make a run
deterministic: `force=responded|timeout` (SA review) or `force=Approved|Denied` (CMS
decision). See `docs/Testing_Guide.md` (Scenario 6).

## Known cluster behavior

- Zeebe 8.9.12 in this cluster does not deliver BPMN custom task headers on job activation
  (`customHeaders` is always `{}`); the services read `kind`/`force`/`phase` from job
  variables populated by ioMapping inputs instead, with headers as a fallback on
  correctly-behaving clusters.
- Rarely a job is ghost-activated (stuck `CREATED`, no incident, cannot be activated);
  cancel and re-create the process instance to recover.

Details in `docs/Testing_Guide.md` §8.
