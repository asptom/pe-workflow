# pe-workflow

Enrollment workflow modeling and local deployment for Camunda 8.

## Structure

- `workflows/` — BPMN, DMN, and Camunda Form artifacts
  - `855x-combined/` — the combined enrollment framework (orchestrator, delegates, shared services, decisions, forms)
  - `855i-single/` — a standalone single-delegate 855I reference process
- `deploy/rancher-desktop/` — scripts, Helm values, and manifests for a local Camunda 8 instance on Rancher Desktop k3s
- `docs/` — deployment guide and implementation plan

## Quick Start

- Deploy the local cluster: see `deploy/rancher-desktop/README.md`
- Deploy workflow artifacts: see `docs/Deployment_Guide.md`
