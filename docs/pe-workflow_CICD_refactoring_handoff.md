# pe-workflow CI/CD Refactoring Handoff

> Instructions for an external coding model working on the merged `main` branch.

## Purpose

Use this document as the implementation brief for OpenCode/OpenRouter or another coding model that has a writable clone of the repository.

Repository: https://github.com/asptom/pe-workflow

Branch to modify: `main`. The former `azure` branch has been merged into `main`; do not treat it as an independent source of truth.

The goal is to make and review the repository changes on the external development machine, push them to `main`, and then allow the corporate Azure environment to pull and execute the updated code.

## 1. Current situation

This is a Provider Enrollment workflow POC using Camunda 8, Azure Kubernetes Service (AKS), Azure Container Registry (ACR), Go microservices, and Azure DevOps.

Current proven environment values:

- Azure resource group: `GWS-Engineering_and_Innovation-Sandbox`
- AKS cluster: `aks-pe-workflow`
- ACR: `acrpeworkflowd211`
- ACR login server: `acrpeworkflowd211.azurecr.io`
- Azure DevOps service connection: `pe-workflow-azure`
- Self-hosted Azure DevOps deployment agent: `vm-jumpbox`
- Self-hosted agent pool: `Default`
- AKS is private, so deployment operations should run from the jumpbox/self-hosted agent rather than the Microsoft-hosted build agent.
- Camunda has already been installed into AKS.
- AKS-to-ACR pull access has been explicitly verified with `az aks check-acr`.
- The CI experiment successfully built `eligibility`, pushed an immutable image such as `acrpeworkflowd211.azurecr.io/pe-workflow/eligibility:6`, and AKS successfully pulled and started that image.
- `eligibility` subsequently exited because required runtime OAuth configuration was absent. Treat that as application/runtime configuration work, not a failure of the ACR/AKS delivery path. Do not redesign CI/CD around that single experiment.

## 2. Scope

Refactor the deployment tooling and Azure DevOps pipeline so the six backend services are tested, built, published, and deployed using clear lifecycle boundaries.

The backend services are:

- `eligibility`
- `verification`
- `scheduling`
- `documents`
- `notifications`
- `simulator`

### Explicitly out of scope

The web application is not required for this Azure pipeline change.

Do **not** add:

- Angular build work
- Node.js stages solely for the webapp
- `webapp` Docker image creation
- `webapp` deployment
- webapp static-asset handling

## 3. Source-of-truth boundaries

Avoid duplicating Kubernetes application configuration in `azure-pipelines.yml`.

### Kubernetes manifests and repository deployment tooling own

- Namespace
- Deployment names
- Container names
- Container ports
- Service ports
- Service definitions
- Environment/configuration references
- ConfigMaps and Secret references
- Health/readiness/liveness probes
- Other Kubernetes workload configuration

### Azure DevOps pipeline owns

- Azure service connection
- Azure resource group
- AKS cluster selection
- ACR selection/login
- Pipeline Build ID
- Pipeline stages/jobs
- Hosted vs. self-hosted agent selection
- Calling the repository deployment tooling

The pipeline should **not** define `aksNamespace` merely to duplicate the manifests.

The pipeline should **not** hard-code application ports such as `8080`, `8081`, etc.

If imperative `kubectl` operations require a namespace, `deploy.sh` should resolve it from the deployed workload/manifests, or support an explicit namespace override for local troubleshooting.

## 4. Repository facts to verify before editing

Inspect the complete current `main` branch before making changes. Preserve working behavior unrelated to this refactor.

Known facts from the current work:

- The repository uses a unified `scripts/deploy.sh` entry point and deployment assets under `scripts/deploy/`.
- A shared service Dockerfile exists under `scripts/deploy/services/Dockerfile`.
- The shared Dockerfile needs the **repository root** as Docker build context because it copies from `services/`.
- Do not `cd scripts/deploy/services` and use that directory as the Docker build context unless the current Dockerfile has materially changed and explicitly supports that.
- The Go module is under `services/`.
- The backend binaries are under `services/cmd/<service>`.
- Shared Go code/tests are under `services/internal/`.
- A previous `go test ./...` pulled in `cmd/webapp` and failed because the webapp had a generated-static-content dependency. Since webapp is out of scope, backend validation must not depend on building it.
- `docs/azure-migration-plan-v2.md` is now on `main` after the branch merge. Use it as planning/background context, but prefer proven current environment values and current repository behavior when they differ from older proposal values.

Before editing, search the repository for at least:

```text
deploy.sh
build-deploy.sh
--services
--all
Dockerfile
manifests.yaml
REGISTRY
TAG
webapp
```

Also inspect `README.md`, `DEPLOYMENT.md`, and `docs/azure-migration-plan-v2.md` for behaviors that must remain compatible.

## 5. Required lifecycle model

Refactor the deployment tooling so **BUILD**, **PUSH**, and **DEPLOY** are separate operations.

The intended CI/CD flow is:

```text
commit to main
    |
    v
backend tests / compile
    |
    v
build six images tagged with Build.BuildId
    |
    v
push exactly those images to ACR
    |
    v
deploy exactly those Build.BuildId images to private AKS
    |
    v
wait for rollouts and report deployed state
```

### BUILD

Creates local container images.

It must **not**:

- Authenticate to ACR as part of build behavior
- Push images
- Access Kubernetes
- Deploy anything

### PUSH

Publishes already-built local images.

It must **not**:

- Rebuild images
- Access Kubernetes
- Deploy anything

### DEPLOY

Deploys already-published images to Kubernetes.

It must **not**:

- Run `docker build`
- Run `docker push`
- Recreate an image on the jumpbox

### Architectural principle

**Build once, publish once, deploy the same immutable artifact.**

The image deployed to AKS must be the image produced by CI. There must be no rebuild between ACR and AKS.

## 6. Desired `scripts/deploy.sh` interface

Adapt the existing `scripts/deploy.sh`; do not blindly replace unrelated behavior.

Maintain current local/full-stack functionality where practical, especially documented behavior such as `--all`, while adding explicit CI/CD-safe actions.

Target command interface:

```bash
REGISTRY=acrpeworkflowd211.azurecr.io \
TAG=27 \
./scripts/deploy.sh --build --services
```

```bash
REGISTRY=acrpeworkflowd211.azurecr.io \
TAG=27 \
./scripts/deploy.sh --push --services
```

```bash
REGISTRY=acrpeworkflowd211.azurecr.io \
TAG=27 \
./scripts/deploy.sh --deploy --services
```

Recommended inputs/options:

- `--build`, `--push`, `--deploy`: exactly one lifecycle action for CI/CD usage
- `--services`: backend-service scope
- `REGISTRY` or `--registry`: registry login server
- `TAG` or `--tag`: explicit image version; Azure DevOps will pass `$(Build.BuildId)`
- `IMAGE_PREFIX`: may default to `pe-workflow`
- `NAMESPACE` / `--namespace`: optional troubleshooting/local override, not something Azure DevOps should need to duplicate
- `MANIFEST` / `--manifest`: optional manifest override if it is useful within the current repository design

Requirements:

- Reject contradictory action flags.
- Fail fast for missing required values, files, or tools.
- Use robust Bash settings such as `set -Eeuo pipefail` if compatible with the existing script.
- Preserve existing behaviors that are relied upon by local development unless there is a strong reason to change them.

## 7. Required build behavior

For:

```bash
./scripts/deploy.sh --build --services
```

Process exactly:

```text
eligibility
verification
scheduling
documents
notifications
simulator
```

Use the shared service Dockerfile and repository root as build context.

Conceptually:

```bash
docker build \
  --build-arg SERVICE="$service" \
  --file "$DOCKERFILE" \
  --tag "$REGISTRY/pe-workflow/$service:$TAG" \
  "$ROOT_DIR"
```

The exact implementation should fit the current script structure.

Build mode must not push or deploy.

## 8. Required push behavior

For:

```bash
./scripts/deploy.sh --push --services
```

For each service:

1. Require a non-empty registry and tag.
2. Verify the expected local image exists.
3. Push exactly that image/tag.
4. Fail if an expected local image is missing.
5. Do not rebuild the image.

Conceptually:

```bash
docker image inspect "$REGISTRY/pe-workflow/$service:$TAG"
docker push "$REGISTRY/pe-workflow/$service:$TAG"
```

Do **not** use:

```bash
docker push ... --all-tags
```

That can publish stale or unintended tags present on the worker.

### Immutable tag policy

The required pipeline/deployment tag is:

```text
$(Build.BuildId)
```

`latest` is not needed for deployment.

If existing developer workflows genuinely benefit from `latest`, it may be retained as an **optional convenience**, but:

- it must not replace the immutable tag;
- AKS deployment must use the Build ID;
- it should not cause the push operation to publish arbitrary local tags.

## 9. Required deploy behavior

For:

```bash
./scripts/deploy.sh --deploy --services
```

Requirements:

1. Require `kubectl` and the required `REGISTRY`/`TAG` values.
2. Do not build anything.
3. Do not push anything.
4. Apply/use the repository's canonical Kubernetes manifests according to the existing deployment design.
5. Point each backend Deployment at:

```text
REGISTRY/pe-workflow/<service>:TAG
```

6. Wait for rollout status for each backend service.
7. Return a non-zero result if a rollout fails.
8. Report final Deployment/pod state and configured images so the CI/CD log clearly identifies what was deployed.

### Namespace handling

Keep namespace knowledge in the repository deployment layer rather than `azure-pipelines.yml`.

Important Kubernetes behavior: `kubectl apply -f manifests.yaml` respects `metadata.namespace` on the objects, but a later imperative command such as:

```bash
kubectl set image deployment/eligibility ...
```

does not infer its namespace from the previously applied manifest.

Implement namespace handling within `deploy.sh` using one of these approaches:

1. **Preferred:** After applying/locating the manifests, discover the namespace containing the expected service Deployment. Verify that it resolves unambiguously to one namespace and use that namespace for `set image` and rollout operations.
2. If the repository already has a reliable mechanism for reading the namespace from the manifests, reuse that mechanism.
3. Keep `--namespace` / `NAMESPACE` as an explicit override for local troubleshooting.

Do not simply assume `default` unless inspection of the current repository proves that is intentional.

## 10. Azure DevOps pipeline requirements

Update `azure-pipelines.yml` to call the new lifecycle operations.

Keep the Azure DevOps pipeline backend-only.

### Stage 1: Test

Run on a Microsoft-hosted Ubuntu agent.

Requirements:

- Install Go 1.22.
- From `services/`, run:

```bash
go test ./internal/...
```

- Explicitly compile all six backend services, for example:

```bash
for svc in \
  eligibility \
  verification \
  scheduling \
  documents \
  notifications \
  simulator
do
  go build "./cmd/${svc}"
done
```

- Do not use `go test ./...` if that brings the out-of-scope webapp into this backend pipeline.

### Stage 2: BuildAndPush

Run on a Microsoft-hosted Ubuntu agent.

Use:

```yaml
azureSubscription: pe-workflow-azure
```

Authenticate Docker to ACR:

```bash
az acr login --name acrpeworkflowd211
```

Then invoke the repository abstraction:

```bash
REGISTRY="$(acrLoginServer)" \
TAG="$(Build.BuildId)" \
./scripts/deploy.sh --build --services
```

followed by:

```bash
REGISTRY="$(acrLoginServer)" \
TAG="$(Build.BuildId)" \
./scripts/deploy.sh --push --services
```

Do not deploy `latest`. The Build ID is the immutable release identity.

### Stage 3: Deploy

Run on the self-hosted jumpbox:

```yaml
pool:
  name: Default
  demands:
  - Agent.Name -equals vm-jumpbox
```

Use `AzureCLI@2` with the existing `pe-workflow-azure` service connection.

Retrieve credentials for private AKS:

```bash
az aks get-credentials \
  --resource-group "$(resourceGroup)" \
  --name "$(aksName)" \
  --overwrite-existing
```

Then:

```bash
REGISTRY="$(acrLoginServer)" \
TAG="$(Build.BuildId)" \
./scripts/deploy.sh --deploy --services
```

The Deploy stage must **not** contain:

- Docker builds
- Docker pushes
- webapp handling
- hard-coded service ports
- duplicated `aksNamespace`

## 11. Target Azure pipeline shape

This is an architecture sketch. Produce actual valid YAML when implementing it.

```yaml
trigger:
- main

variables:
  azureServiceConnection: pe-workflow-azure
  resourceGroup: GWS-Engineering_and_Innovation-Sandbox
  aksName: aks-pe-workflow
  acrName: acrpeworkflowd211
  acrLoginServer: acrpeworkflowd211.azurecr.io

stages:

- stage: Test
  # Microsoft-hosted Ubuntu
  # Install Go 1.22
  # Test shared packages
  # Compile the six backend services

- stage: BuildAndPush
  dependsOn: Test
  # Microsoft-hosted Ubuntu
  # az acr login
  # deploy.sh --build --services
  # deploy.sh --push --services
  # REGISTRY and TAG are supplied by the pipeline

- stage: Deploy
  dependsOn: BuildAndPush
  # Self-hosted Default pool / vm-jumpbox
  # az aks get-credentials
  # deploy.sh --deploy --services
  # Same immutable Build.BuildId tag
```

## 12. Backward compatibility

Before modifying `scripts/deploy.sh`, inspect its complete behavior and every documented invocation in the repository.

Particularly inspect:

- `README.md`
- `DEPLOYMENT.md`
- `docs/azure-migration-plan-v2.md`
- callers of `scripts/deploy.sh`
- callers of any legacy `scripts/deploy/services/build-deploy.sh`

Requirements:

- If `--all` currently installs Camunda/resources/services or performs full-stack local deployment, preserve that useful developer behavior or provide a clearly compatible replacement.
- Do not silently change the meaning of existing flags used by documented local-development workflows.
- Avoid maintaining two competing CI/CD implementations.
- If `build-deploy.sh` becomes obsolete, either refactor its callers and deprecate/remove it appropriately, or reduce it to a compatibility wrapper if that makes sense after inspecting current usage.
- Update documentation when the public command contract changes.

## 13. Local validation required before commit

The external coding model has a writable development clone but does not need corporate Azure access for source-level checks.

Before considering the work complete:

1. Run Bash syntax validation on changed scripts:

```bash
bash -n scripts/deploy.sh
```

2. If `shellcheck` is available, run it and review meaningful findings.
3. Validate `azure-pipelines.yml` syntax/structure as far as practical locally.
4. Run the shared Go package tests.
5. Compile all six backend services.
6. Review `git diff` carefully.
7. Confirm no webapp/Angular work was added to this Azure pipeline.
8. Confirm no secret, PAT, client secret, token, kubeconfig, certificate, or private key was added to Git.
9. Confirm the Docker build context remains the repository root.
10. Confirm the same `TAG` flows through build, push, and deploy.
11. Confirm the deploy path contains no `docker build` or `docker push`.
12. Confirm `azure-pipelines.yml` contains no duplicate namespace or service-port configuration.
13. Confirm existing important local deployment behaviors remain functional or are intentionally documented as changed.

## 14. Acceptance criteria

The refactor is complete when all of the following are true:

- `scripts/deploy.sh` has explicit build, push, and deploy modes for backend services.
- Build mode creates six backend images and does not push/deploy.
- Push mode pushes six existing immutable images and does not build/deploy.
- Deploy mode deploys six already-published images and does not build/push.
- `azure-pipelines.yml` contains no webapp job, webapp image build, or webapp deployment.
- Test/build/push run on Microsoft-hosted agents.
- Private-AKS deployment runs on `vm-jumpbox` in pool `Default`.
- The deployed tag is `$(Build.BuildId)`, not `latest`.
- Namespace and port configuration are not duplicated in `azure-pipelines.yml`.
- Repository manifests/deployment code remain the owner of Kubernetes topology/configuration.
- Existing local deployment behavior is preserved where practical.
- Documentation is updated if command semantics change.
- Available local syntax/tests pass.

## 15. Do not do these things

- Do not make the `eligibility` CrashLoopBackOff the focus of this refactor. Missing OAuth runtime configuration is a separate application/configuration issue.
- Do not create a special eligibility-only manifest just for CI/CD if canonical repository manifests already define the services.
- Do not hard-code `8080`, `8081`, or other service ports in `azure-pipelines.yml`.
- Do not build containers on `vm-jumpbox` during CD.
- Do not deploy `latest`.
- Do not use `docker push --all-tags`.
- Do not reintroduce the webapp into this Azure pipeline change.
- Do not restore old sample Azure names such as `rg-pe-workflow-dev`, `aks-pe-workflow-dev`, or `acrpeworkflowXXXX`.
- Do not assume the old `azure` branch remains authoritative. Work from the merged `main` branch.
- Do not replace working deployment behavior without first inspecting how the current repository uses it.

## 16. Output expected from the external coding model

Do not merely propose code. Make the edits in the writable clone and leave the repository ready for the owner to commit/push according to the local workflow.

Report:

1. A concise summary of what changed and why.
2. The complete list of modified files.
3. The resulting `deploy.sh` command contract.
4. The final Azure DevOps stage structure.
5. Any backward-compatibility decisions made and why.
6. Commands/tests executed locally and their results.
7. Anything that cannot be validated without the corporate Azure environment, clearly separated from locally verified results.
8. A final `git diff --stat` and focused discussion of material changes.

## 17. Corporate-side validation after push

After the changes reach GitHub `main`, validation will occur from the corporate/Azure environment through the existing Azure DevOps integration.

Expected checkpoints:

1. `Test` succeeds for all six backend services.
2. `BuildAndPush` produces six ACR images with the same `Build.BuildId` tag.
3. `Deploy` runs on `vm-jumpbox` in the `Default` pool.
4. The jumpbox retrieves credentials for private `aks-pe-workflow`.
5. `deploy.sh --deploy --services` uses the repository's canonical Kubernetes configuration and changes the six workloads to the immutable Build ID images.
6. The deployment reports workload rollout status and configured images.
7. Application-level failures such as missing runtime configuration are reported as application/runtime issues, not worked around by rebuilding a different image.

## 18. Final architectural principle

The governing design is **immutable promotion**:

```text
source
  |
  v
test
  |
  v
build once
  |
  v
push exact artifact
  |
  v
ACR
  |
  v
deploy same artifact
  |
  v
private AKS
```

Azure DevOps orchestrates the lifecycle and knows Azure connection information. The repository deployment tooling owns Kubernetes-specific application knowledge. This keeps the POC pipeline understandable, auditable, and extensible without spreading Kubernetes topology throughout the pipeline YAML.

