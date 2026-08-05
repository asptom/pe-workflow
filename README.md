# pe-workflow

Enrollment workflow modeling and local deployment for Camunda 8.

## Structure

- `workflows/` — BPMN, DMN, and Camunda Form artifacts
  - `855x-combined/` — the combined enrollment framework (orchestrator, delegates, shared services, decisions, forms)
  - `855i-single/` — a standalone single-delegate 855I reference process
- `services/` — Go microservices, one binary per service, each running Camunda 8 job workers for the combined workflows
  - `cmd/` — eligibility, verification, scheduling, documents, notifications, simulator
  - `internal/zeebeworker/` — shared Zeebe client bootstrap and job-handling helpers
- `deploy/rancher-desktop/` — scripts, Helm values, and manifests for a local Camunda 8 instance on Rancher Desktop k3s
- `deploy/services/` — Dockerfile, Kubernetes manifests, and the build/deploy script for the microservices
- `docs/` — deployment guide, testing guide, and implementation plan

## Quick Start

1. Deploy the local cluster: see `deploy/rancher-desktop/README.md`
2. Deploy the workflow artifacts (BPMN, DMN, forms): see `docs/Deployment_Guide.md`
3. Build and deploy the services and artifacts:
   `./deploy/services/build-deploy.sh --services --resources`
4. Run the scenarios: see `docs/Testing_Guide.md`

## Microservices

All services connect to the Zeebe gateway with OAuth client credentials from the
standard `ZEEBE_*` environment variables and expose their own REST API (`/healthz`
on every service).

| Service | Port | Job types |
| --- | --- | --- |
| eligibility | 8081 | `screen-oig`, `screen-sam` |
| verification | 8082 | `verify-npi`, `verify-tin`, `verify-license`, `verify-bond`, `verify-equipment`, `verify-fire-safety`, `verify-board-cert` |
| scheduling | 8083 | `process-site-visit` |
| documents | 8084 | `generate-doc` |
| notifications | 8085 | `send-notification` (kind selected via job variable: `ineligibility`, `additional-info`, `cms-forward`, `approval`, `denial`) |
| simulator | 8086 | `simulate-sa-review`, `simulate-cms-decision` |

## Time-emulation mode

The combined workflows use the simulator to collapse long review waits into seconds:

- 45-day SA/AO review → `Timer_45DayReview` `PT5S`
- 14-day follow-up → `Timer_14DayFollowUp` `PT3S`
- 30-day additional-info and 30-day CMS decision → `PT5S` each

Outcomes are 50/50 random. Start a process instance with a `force` variable to make
a run deterministic: `force=responded|timeout` (SA review) or `force=Approved|Denied`
(CMS decision). See `docs/Testing_Guide.md` (Scenario 6).

## Known cluster behavior

- Zeebe 8.9.12 in this cluster does not deliver BPMN custom task headers on job
  activation (`customHeaders` is always `{}`); the services read `kind`/`force`/`phase`
  from job variables populated by ioMapping inputs instead, with headers as a fallback
  on correctly-behaving clusters.
- Rarely a job is ghost-activated (stuck `CREATED`, no incident, cannot be activated);
  cancel and re-create the process instance to recover.

Details in `docs/Testing_Guide.md` §8.
