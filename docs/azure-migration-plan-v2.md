# Azure Migration Plan v2 — MVP (pe-workflow)

This document supersedes `docs/azure-migration-plan.md` (v1). It is a **minimum viable
product** plan: the smallest set of Azure services that gets the exact current stack
(Camunda 8.9.x on Helm chart 14.6.1, ECK Elasticsearch, Keycloak operator, CloudNativePG,
7 Go services + BFF webapp, c8ctl-deployed workflow resources) running on AKS, with
today's developer workflow preserved (kubectl, helm, c8ctl, localhost port-forward URLs).

**Scope decisions** (confirmed with the project owner):

| Decision | Choice |
|----------|--------|
| Cluster access | **Private AKS + Azure Bastion + jumpbox VM** (no VPN Gateway) |
| PostgreSQL | **Keep CloudNativePG in-cluster** (no Azure Flexible Server) |
| CI/CD | **Azure DevOps Pipelines from day one** (hosted build + self-hosted deploy agent) |
| Data | **Fresh start** — no PostgreSQL/Elasticsearch/process-data migration from the Mac Studio |
| Observability | **Container Insights only** (one AKS add-on flag) |
| Data services | Elasticsearch stays in-cluster via ECK (unchanged from v1) |

## 1. Critical review of v1

v1's core architecture (self-managed Camunda on AKS, ECK in-cluster, same Helm chart, no
application code changes) is right. The following findings drove the v2 scope.

| # | v1 issue | v2 resolution |
|---|----------|---------------|
| F1 | **Access-path overlap**: v1 provisions *both* a VPN Gateway (service #10) *and* Bastion + jumpbox (service #11). They solve the same problem (reaching a private cluster); ~$140+/mo duplicated. | Bastion + jumpbox only, per owner decision. VPN Gateway is dropped entirely. |
| F2 | **Bastion SKU not addressed**: v1 doesn't say which SKU, but the choice is load-bearing. Developer SKU is free but supports **browser-based SSH only** — `az network bastion tunnel` (native client) requires **Standard**. Without native tunneling, laptop browsers cannot reach Keycloak/Operate/webapp. | Standard SKU + SSH local-forward chain; preserves today's `localhost:*` URLs exactly (all OIDC redirect URLs in `values-no-domain.yml` are `localhost`-based and stay valid). |
| F3 | **ACR Premium (~$200/mo)**: Premium is only required for a *private endpoint*. A private-cluster node can pull from ACR's public endpoint over TLS with managed-identity auth. | ACR **Standard** (~$5/mo). Private endpoint is a phase-2 policy item, not an MVP requirement. |
| F4 | **Azure Database for PostgreSQL Flexible Server**: replaces a CNPG setup that is already cloud-agnostic — the three `Cluster` CRs (`postgresql-clusters.yml`) specify no storageClass, no hostnames, nothing Azure-specific. Switching would rewrite five Helm values files, fork the deploy script, and add privatelink DNS, while removing nothing the MVP needs. | Keep CNPG 1.30 as-is. Managed PG deferred to phase 2 (its real benefit — patching/backup offload — matters for prod, not for proving the stack runs). |
| F5 | **Key Vault + Secrets Store CSI**: replaces `set-secrets.sh`, which already creates idempotent Kubernetes secrets locally at zero cost. CSI adds a driver install, `SecretProviderClass` plumbing, and rotation semantics for no MVP benefit. | Keep `set-secrets.sh` and `camunda-credentials` secret generation unchanged. Key Vault deferred. |
| F6 | **Sizing overshoot**: v1 proposes a 3–6× Standard_D8s_v5 user pool *plus* a 2× D2s_v5 system pool (32+ vCPU, 112+ GiB). The actual stack is ~24 pods with explicitly requested resources of only ~2 vCPU / 4.2 Gi (plus chart defaults for Operate/Tasklist/gateway) — it currently fits on one Mac Studio. | One node pool: 2× **Standard_D4s_v5** (4 vCPU / 16 Gi each), autoscale 2–3. No separate system pool. |
| F7 | **Zone redundancy** proposed at cluster creation. | Deferred — dev environment; adds cost and constraints for zero MVP value. |
| F8 | **Managed Prometheus + Grafana**, justified by "the BFF and workers already expose Prometheus `/metrics`". Inaccurate: only the BFF exposes `/metrics` (`api.go:61`); the six workers expose only `/healthz`. | Container Insights only (owner decision; one flag at cluster create). |
| F9 | **Ordering flaw**: the access layer is step 9 of 12, but kubeconfig access is required from step 2 onward. | Jumpbox + Bastion are built in phase 2, before anything is deployed. |
| F10 | **CI/CD on a private cluster**: v1 correctly notes hosted agents can't reach the API server but treats the self-hosted agent as "optional". With CI/CD wanted from day one, it is the *primary* deploy path. | Hosted agent does build/test/push (public endpoints only); **self-hosted agent on the jumpbox** runs kubectl/helm/c8ctl deploy stages. |
| F11 | **No data-migration stance**, and no cost/teardown guardrails. | Fresh start (owner decision). Budget alert at creation, `az aks stop`, jumpbox auto-shutdown documented in §12. |
| F12 | **Cost**: ~$1.2–1.8k/mo estimate reflects the extras above. | ≈ **$520–720/mo** all-in (§10), with the same parity outcome. |
| F13 | **Repo changes**: v1 plans a fork of `camunda-deploy-no-domain.sh`, an edited `values-no-domain.yml`, and a new c8ctl profile. None of that is needed once CNPG stays and access preserves `localhost` URLs. | Two changes only: `build-deploy.sh` gains an optional `REGISTRY` env var; new `azure-pipelines.yml` (§9). |
| F14 | v1's "Not needed" list (App Gateway/Front Door/Service Bus/Entra External ID; no code changes for the Go services) is correct. | Kept verbatim. |
| F15 | **Entra ID** (v1 service #14) bundles three uses; the MVP needs none of them explicitly. ACR auth is the auto-created kubelet identity; cluster access uses the local admin kubeconfig; the ADO connection is a wizard-created federated app registration. | No explicit Entra ID configuration in MVP. |

## 2. Target architecture

```
Laptop (az CLI, docker, browser)
   │  az network bastion tunnel  (TLS on 443, no public IP anywhere)
   ▼
Azure Bastion (Standard) ──► Jumpbox VM (Linux, B2s, no public IP)
                               az CLI · kubectl · helm · c8ctl · git
                               ADO self-hosted agent (deploy stages)
                               camunda-port-forwards.sh (localhost binds)
                                    │  same VNet → private FQDN
                                    ▼
                     Private AKS cluster (free tier, autoscale 2–3 × D4s_v5)
                     namespace camunda:
                       ├─ Camunda chart 14.6.1: Zeebe 8.9.12, gateway, Operate,
                       │  Tasklist, Optimize, Identity, Console, WebModeler, Connectors
                       ├─ Keycloak operator 26.3.2 → Keycloak 26.6.4
                       ├─ ECK 3.4.1 → Elasticsearch 8.19.17 (1 node, 10Gi PVC)
                       ├─ CNPG 1.30 → pg-identity / pg-keycloak / pg-webmodeler (15Gi each)
                       └─ 7× pe-* images from ACR Standard
                     Container Insights → Log Analytics

Azure DevOps:  hosted agent (go test, docker build ×7, push to ACR)
               ─────────────────────────────────────────────►  ACR (Standard)
```

Provisioned Azure services — the entire MVP footprint:

| Service | Purpose |
|---------|---------|
| Resource Group `rg-pe-workflow-dev` | One-command teardown and cost boundary |
| VNet + 3 subnets | Private IP space for AKS nodes, jumpbox, Bastion |
| AKS (private, free tier, Container Insights) | Runs the entire stack |
| Azure Container Registry (Standard) | Stores the 7 `pe-*` images |
| Jumpbox VM (B2s, Linux) | All kubectl/helm/c8ctl operations + ADO deploy agent |
| Azure Bastion (Standard) | Private-path access to the jumpbox |

Created implicitly (no action needed): kubelet managed identity (ACR pull), AKS private
DNS zone (VNet-linked), outbound public IP on the cluster LB, Log Analytics workspace.

## 3. Explicitly deferred (phase 2)

Each item is **not** built in the MVP, with the condition that would trigger adding it:

| Item | Add when |
|------|----------|
| VPN Gateway | Multiple developers need access without per-person Bastion tunnels |
| ACR Premium + private endpoint | An egress-lockdown policy forbids public-registry pulls |
| Azure Flexible Server for PostgreSQL | Moving toward production-grade DB ops (patching/backup offload) |
| Key Vault + Secrets Store CSI | Secrets must be shared/rotated across environments |
| Custom private DNS zones | Only useful with the private endpoints above |
| OIDC workload identity on AKS | First workload wants Key-Vault-CSI or Azure-resource identity (one `az aks update`, no redeploy) |
| Entra ID-integrated cluster RBAC | Second operator joins the environment |
| Zone redundancy / uptime SLA / standard tier | Environment becomes pre-prod |
| Managed Prometheus + Grafana | Dashboards over the BFF `/metrics` are actually needed (workers would need instrumentation first) |
| Image tag discipline (Build-ID tags, digests, no `:latest`) | After parity is proven |
| TLS + real hostnames on ingress | Let's Encrypt HTTP-01 is impossible on a private cluster; would need a private CA or DNS-01 |

## 4. Prerequisites

1. **Azure subscription** with an account that can create resources in the chosen region.
2. **az CLI** on the laptop (everything in phases 1–2 runs from the laptop).
3. **Region + quota check** — the plan needs ~10 vCPU of the Dv5 family (2 nodes × 4 +
   jumpbox 2) and Bastion Standard availability:

   ```bash
   az vm list-usage -l eastus2 -o table \
     --query "[?name.value=='Standard_Dv5FamilyCore']"
   ```

4. **A git remote for the repo.** Azure Pipelines need the source in Azure Repos or
   GitHub. If the repo has no remote yet, push it to Azure Repos (simplest for ADO) or
   GitHub (connect via the Pipelines GitHub app). Everything else in this plan is
   identical either way.
5. **Tooling installed on the jumpbox** (phase 2): az CLI, kubectl, helm, git, c8ctl
   (install per its standard instructions), plus the ADO agent.
6. **Nothing changes on the Mac Studio** until parity is validated in phase 7; it remains
   the fallback environment and the reference for expected behavior.

## 5. Naming and variables

```bash
export REGION=eastus2                                # pick your nearest region
export RG=rg-pe-workflow-dev
export ACR=acrpeworkflow$(openssl rand -hex 2)       # globally unique, lowercase alnum
export AKS=aks-pe-workflow-dev
export BASTION=bas-pe-workflow
export JUMPBOX=vm-jumpbox
```

## 6. Step-by-step plan

### Phase 0 — Cost guardrail (before spending anything)

**Step 0.1 — Budget alert.**
Why: the biggest MVP risk is silent cost creep (autoscaler, forgotten VMs). An alert at
~$750/mo catches it early.
How:

```bash
az consumption budget create \
  --budget-name pe-workflow-dev-budget --category Cost \
  --amount 750 --time-grain Monthly --time-period start-date="$(date +%F)" end-date="$(date -v+1y +%F)" \
  --resource-group $RG --notifications '{ "budgetalert": { "enabled": true, "threshold": 90, "contactEmails": ["you@example.com"] } }'
```

(Or create it in the Portal: Cost Management → Budgets.) Verify: alert appears in Cost
Management.

### Phase 1 — Foundation (RG, VNet, ACR)

**Step 1.1 — Resource group.**
Why: every resource below lives in it; deleting it is the full teardown.
How:

```bash
az group create -n $RG -l $REGION
```

Verify: `az group show -n $RG`.

**Step 1.2 — VNet + subnets.**
Why: a private cluster requires node IPs inside a VNet you control, the jumpbox needs a
subnet to reach it, and Bastion requires a subnet named exactly `AzureBastionSubnet`.
This is the *only* networking the MVP needs — no VPN gateway subnet, no PG subnet, no
private DNS zones.

```bash
az network vnet create -g $RG -n vnet-pe-workflow \
  --address-prefix 10.240.0.0/16 \
  --subnet-name snet-aks --subnet-prefix 10.240.0.0/23

az network vnet subnet add -g $RG --vnet-name vnet-pe-workflow \
  --name snet-jumpbox --address-prefixes 10.240.2.0/24

az network vnet subnet add -g $RG --vnet-name vnet-pe-workflow \
  --name AzureBastionSubnet --address-prefixes 10.240.3.0/26
```

`/23` for AKS covers 3 nodes plus the API-server private endpoint (AKS places it in the
first node-pool subnet). `/26` is the Bastion minimum.

**Step 1.3 — ACR (Standard).**
Why: k3s ran `pe-workflow/*:latest` images straight from the local Docker daemon; AKS
nodes cannot see those, so the images need a registry the cluster can pull from. Standard
is sufficient (see F3); Premium's private endpoint is a phase-2 item.

```bash
az acr create -g $RG -n $ACR --sku Standard
```

Verify: `az acr show -n $ACR --query provisioningState` → `Succeeded`.

### Phase 2 — AKS, jumpbox, Bastion (the access layer comes first)

**Step 2.1 — Private AKS cluster.**
Why each flag:

| Flag | Reason |
|------|--------|
| `--enable-private-cluster` | Owner decision; the API server gets a private FQDN only reachable from the VNet |
| `--vnet-subnet-id` | Places nodes in `snet-aks` |
| `--node-vm-size Standard_D4s_v5`, `--node-count 2`, autoscale 2–3 | Right-sized per F6; two nodes cover the ~24-pod stack with headroom; the third absorbs bursts |
| `--enable-addons monitoring` | Container Insights (owner decision) — pod logs and node metrics in the Portal, one flag |
| `--attach-acr $ACR` | Grants the auto-created kubelet managed identity `AcrPull`; no pull secrets, ever |
| `--tier free` | No uptime SLA needed for a dev environment; `az aks stop/start` still works |
| *(omitted)* workload identity, zones, separate system pool | Deferred items (§3) |

How:

```bash
AKS_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name vnet-pe-workflow \
  -n snet-aks --query id -o tsv)

az aks create \
  -g $RG -n $AKS -l $REGION \
  --tier free \
  --enable-private-cluster \
  --vnet-subnet-id $AKS_SUBNET_ID \
  --node-vm-size Standard_D4s_v5 \
  --node-count 2 --min-count 2 --max-count 3 --enable-cluster-autoscaler \
  --enable-addons monitoring \
  --attach-acr $ACR \
  --generate-ssh-keys
```

Verify: `az aks show -g $RG -n $AKS --query "{private:apiServerAccessProfile.enablePrivateCluster, power:powerState.code}"`.
Note: since no Entra RBAC is configured, `az aks get-credentials` returns a working admin
kubeconfig — that is what the MVP uses.

**Step 2.2 — Jumpbox VM.**
Why: the single place where kubectl/helm/c8ctl can reach the private API server. It
replaces every operation currently done on the Mac Studio (and hosts the ADO deploy
agent). No public IP — access comes only through Bastion.

```bash
az network nsg create -g $RG -n nsg-jumpbox
az network nsg rule create -g $RG --nsg-name nsg-jumpbox -n allow-ssh-from-bastion \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --destination-port-ranges 22 --source-address-prefixes 10.240.3.0/26

az vm create \
  -g $RG -n $JUMPBOX \
  --image Ubuntu2404 --size Standard_B2s \
  --vnet-name vnet-pe-workflow --subnet snet-jumpbox \
  --public-ip-address "" \
  --nsg nsg-jumpbox \
  --admin-username azureuser --generate-ssh-keys

JUMPBOX_IP=$(az vm show -g $RG -n $JUMPBOX -d --query privateIps -o tsv)

az vm auto-shutdown -g $RG -n $JUMPBOX --time 03:00
```

Auto-shutdown saves ~$30/mo and is safe because CI deploys happen during work hours —
but it takes the ADO deploy agent offline too; skip it or adjust the time if you want
nightly CI deploys. The NSG permits SSH only from the Bastion subnet.

**Step 2.3 — Azure Bastion (Standard).**
Why: the managed, public-IP-free path to the jumpbox. **Standard is required** (F2):
native client tunneling — the mechanism that brings the cluster UIs to your laptop — is
a Standard/Premium feature. Developer is free but browser-SSH only, which would strand
Keycloak/Operate/webapp behind the jumpbox.

```bash
az network bastion create -g $RG -n $BASTION \
  --vnet-name vnet-pe-workflow --sku Standard
```

Verify: `az network bastion list -g $RG --query "[].{name:name, sku:sku.name}"`.

**Step 2.4 — Jumpbox bootstrap.**
Why: everything after this step (platform deploy, CI agent, c8ctl) runs on the jumpbox.
How — tunnel in, then install tooling:

```bash
# from laptop, in a background terminal:
az network bastion tunnel --name $BASTION -g $RG \
  --target-ip-address $JUMPBOX_IP --resource-port 22 --port 50022

ssh -p 50022 azureuser@127.0.0.1

# on the jumpbox:
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login --use-device-code
az aks install-cli                                   # kubectl + kubelogin
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
az aks get-credentials -g $RG -n $AKS                # kubeconfig → private FQDN
git clone <repo-url> ~/pe-workflow                   # PAT or SSH creds required
# install c8ctl per its standard installation instructions
kubectl get nodes                                    # sanity: 2 nodes Ready
```

Verify: `kubectl get nodes` succeeds **on the jumpbox** — that single command proves
private DNS, the kubeconfig, and network path all work.

**Step 2.5 — Daily-driver access pattern (runbook, use forever).**
Why: this reproduces today's Mac Studio UX — all UIs on the same `localhost` ports — so
every documented URL and OIDC redirect keeps working unchanged.
How:

```bash
# On the jumpbox (inside tmux, stays running):
~/pe-workflow/scripts/deploy/camunda/scripts/camunda-port-forwards.sh

# From laptop: bastion tunnel (as above), then forward all nine ports through SSH:
ssh -p 50022 -N \
  -L 8080:127.0.0.1:8080  -L 18080:127.0.0.1:18080 -L 8083:127.0.0.1:8083 \
  -L 8070:127.0.0.1:8070  -L 8085:127.0.0.1:8085   -L 8086:127.0.0.1:8086 \
  -L 8087:127.0.0.1:8087  -L 8088:127.0.0.1:8088   -L 8186:127.0.0.1:8186 \
  azureuser@127.0.0.1
```

These are exactly the nine forwards from `camunda-port-forwards.sh` (Keycloak 18080,
gateway/Operate/Tasklist/Identity 8080, Optimize 8083, WebModeler 8070/8085, Connectors
8086, Console 8087, webapp 8088, simulator 8186). Zeebe gRPC 26500 is intentionally not
forwarded — nothing on the laptop uses it (c8ctl is REST; workers run in-cluster).
Verify: `http://localhost:8080` (Operate), `http://localhost:18080` (Keycloak),
`http://localhost:8088` (webapp) respond from the laptop.

### Phase 3 — Camunda platform (existing scripts, zero modifications)

**Step 3.1 — Deploy the platform on the jumpbox.**
Why: with CNPG, ECK, and Keycloak kept (F4), nothing in the platform path is
Azure-specific. The script downloads operator manifests to the jumpbox (which has normal
internet egress), then applies them through the private API server; the cluster pulls
Camunda/Postgres/Elasticsearch images from docker.io/ghcr.io/docker.elastic.co over its
default outbound LB. Storage needs no change either: no manifest sets a `storageClass`,
so AKS's built-in managed-CSI `default` class (Premium SSD) provisions the same PVC
sizes (Zeebe 10Gi, ES 10Gi, 3× PG 15Gi) that k3s's local-path provided.

```bash
cd ~/pe-workflow
scripts/deploy/camunda/scripts/camunda-deploy-no-domain.sh --skip-c8ctl-config
```

This performs the identical sequence as today: namespace → ECK operator + Elasticsearch
CR → CNPG operator + secrets + three clusters → Keycloak operator + CR →
`camunda-credentials` → `helm upgrade --install camunda camunda-platform --version
14.6.1` with the same five values files.

Verify:

```bash
kubectl -n camunda get pods -w        # ~22 pods reach Running/Ready
kubectl -n camunda get pvc            # 5 PVCs, all Bound
```

Startup takes noticeably longer than k3s (Premium disks attach/detach, AKS image pulls);
expect several minutes. If anything sticks, it will be ES or Keycloak waiting on its DB —
check with `kubectl describe pod`.

### Phase 4 — CI/CD (Azure DevOps)

**Step 4.1 — DevOps organization, project, and repo connection.**
Why: pipelines need a home and a source. How: create an ADO org + project `pe-workflow`
(free tier includes 1 hosted parallel job + unlimited self-hosted agents). If the repo is
already on GitHub, connect it; otherwise **import it into Azure Repos** (Repos → Import).

**Step 4.2 — Service connection to Azure (workload identity federation).**
Why: hosted build agents push to ACR without stored secrets. How: Project Settings →
Service connections → Azure Resource Manager → *Workload identity federation
(automatic)* — the wizard creates the Entra app registration and federated credentials.
Scope it to the subscription (or `$RG`) with **Contributor** on the RG (covers ACR push
and `az aks command invoke` break-glass). Verify: *Verify* button on the connection
passes.

**Step 4.3 — Self-hosted agent on the jumpbox.**
Why: hosted agents cannot reach a private API server (F10), so deploy stages must run
where the kubeconfig works — the jumpbox. Agents poll ADO outbound on 443, so the private
network is not a problem for the agent itself.

```bash
# on the jumpbox: ADO → Project Settings → Agent pools → Default → New agent (Linux x64)
mkdir ~/ado-agent && cd ~/ado-agent
tar xzf ~/vsts-agent-linux-x64-*.tar.gz
./config.sh --url https://dev.azure.com/<org> --pool Default --token <PAT> --accept-teeeula
sudo ./svc.sh install && sudo ./svc.sh start        # run as a systemd service
```

Verify: the agent shows **Online** in the ADO pool.

**Step 4.4 — Pipeline.**
Why: automates the one thing that must change for Azure (images in ACR) plus repeatable
deploys. Single build job (not a matrix) because the free tier has 1 hosted parallel job.
How — add `azure-pipelines.yml` at the repo root (contents to be committed in the
implementation step; sketch):

```yaml
trigger: [main]
variables:
  rg: rg-pe-workflow-dev
  aksName: aks-pe-workflow-dev
  acrName: acrpeworkflowXXXX          # set from your ACR name
  azureServiceConnection: pe-workflow-azure

stages:
- stage: buildAndPush                  # Microsoft-hosted: public endpoints only
  jobs:
  - job: test
    steps:
    - task: GoTool@0
      inputs: { version: '1.22.0' }
    - script: cd services && go test ./...
  - job: images
    dependsOn: test
    steps:
    - task: AzureCLI@2
      inputs:
        azureSubscription: $(azureServiceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          az acr login --name $(acrName)
          cd scripts/deploy/services
          for svc in eligibility verification scheduling documents notifications simulator; do
            docker build --build-arg SERVICE=$svc -t $(acrName).azurecr.io/pe-workflow/$svc:$(Build.BuildId) \
              -t $(acrName).azurecr.io/pe-workflow/$svc:latest -f Dockerfile . && \
            docker push $(acrName).azurecr.io/pe-workflow/$svc --all-tags
          done
    - script: |                        # webapp: npm build embeds the Angular SPA
        cd web && npm ci && npm run build
        cd ../scripts/deploy/services
        docker build --build-arg SERVICE=webapp \
          -t $(acrName).azurecr.io/pe-workflow/webapp:$(Build.BuildId) \
          -t $(acrName).azurecr.io/pe-workflow/webapp:latest -f Dockerfile .
        docker push $(acrName).azurecr.io/pe-workflow/webapp --all-tags

- stage: deployServices                # self-hosted agent = the jumpbox
  jobs:
  - job: deploy
    pool: Default                      # the jumpbox agent pool
    steps:
    - script: |
        cd scripts/deploy/services
        REGISTRY=$(acrName).azurecr.io ./build-deploy.sh --services   # see §9
        REGISTRY=$(acrName).azurecr.io ./build-deploy.sh --webapp
```

(A `deployPlatform` stage — running `camunda-deploy-no-domain.sh` from the jumpbox agent
— can be added behind a manual approval gate for chart/version upgrades; platform changes
are rare, so it is optional in the MVP.)

Verify: pipeline run goes green; `az acr repository list -n $ACR` shows all 7 image
names with `latest` + Build-ID tags.

### Phase 5 — Workers + BFF on the cluster

**Step 5.1 — Deploy the services.**
Why: the 7 Go Deployments need no changes except image refs (`manifests.yaml` still
references `pe-workflow/*:latest` and every env var points at in-cluster service DNS —
`camunda-zeebe-gateway:26500`, `keycloak-service:18080` — which resolve identically on
AKS). The `REGISTRY` env var added to `build-deploy.sh` (§9) rewrites the refs at apply
time.
How — run the `deployServices` stage of the pipeline (preferred), or manually on the
jumpbox:

```bash
cd ~/pe-workflow/scripts/deploy/services
REGISTRY=$ACR.azurecr.io ./build-deploy.sh --services
REGISTRY=$ACR.azurecr.io ./build-deploy.sh --webapp
```

Verify:

```bash
kubectl -n camunda get pods -o wide | grep pe-          # 7 pods Running
kubectl -n camunda get deploy pe-eligibility \
  -o jsonpath='{.spec.template.spec.containers[0].image}'  # → $ACR.azurecr.io/pe-workflow/...
```

No `ImagePullBackOff` anywhere confirms the `--attach-acr` identity works. Check one
worker's log for a successful Zeebe connection
(`kubectl -n camunda logs deploy/pe-eligibility`).

**Ad-hoc rebuilds without CI:** from the laptop (Rancher Desktop has Docker, ACR is
public): `az acr login -n $ACR`, `docker build/tag/push`, then restart the deployment
from the jumpbox — the same loop as today, one step longer.

### Phase 6 — c8ctl configuration + workflow resources

**Step 6.1 — Configure c8ctl.**
Why: unchanged — `configure-c8ctl.sh` drives Keycloak and the gateway through the
**localhost port-forwards**, which now run on the jumpbox (Step 2.5), so the script works
verbatim and registers the same `kubernetes` profile (`http://localhost:8080/v2` +
`localhost:18080` OAuth). No new profile needed — v1's planned `azure` profile is
unnecessary.

```bash
cd ~/pe-workflow
scripts/deploy/camunda/scripts/configure-c8ctl.sh
```

Verify: `c8ctl` profile `kubernetes` active; a trivial `c8ctl` query succeeds.

**Step 6.2 — Deploy the 17 workflow artifacts.**
Why/How: unchanged — the dependency-ordered `c8ctl deploy` sequence (forms/decisions →
shared → delegates → orchestrator), run from the jumpbox with port-forwards up:

```bash
scripts/deploy/services/build-deploy.sh --resources
```

Verify: the orchestrator and shared BPMN appear in Operate (`localhost:8080`); forms and
DMN listed as deployed.

### Phase 7 — Parity validation

Why: the exit criterion is "the Azure environment behaves like the Mac Studio one".
How/Verify:

1. Run the six scenarios from `docs/Testing_Guide.md` §3 (855I / 855A / 855B / EXCLUDED /
   CONDITIONAL+additional-info / deterministic `force`) end-to-end through the webapp
   (`localhost:8088`), checking the expected end-state variables (§6).
2. Confirm both known quirks behave **identically** (they are Zeebe 8.9.12 behavior, not
   infra-caused, so they should carry over unchanged):
   - BPMN custom task headers not delivered on activation (§8) — services still receive
     `kind`/`force`/`phase` via ioMapping job variables;
   - rare "ghost jobs" (stuck CREATED) — same cancel-and-recreate workaround.
3. Container Insights: AKS → Monitoring in the Portal shows the ~29 pods, and logs from
   `pe-*` and Zeebe are queryable.
4. Cost check: Cost Management shows the actual burn against the budget from Step 0.1.
5. Record any behavioral deltas in a short addendum to `Testing_Guide.md`.

### Phase 8 — Cutover decision

After phase 7 passes, the Mac Studio environment can be left as-is (fallback/reference)
or stopped. The Azure environment is now the system of record for development. Going
forward: code → pipeline (build+push+deploy), platform/version upgrades → jumpbox script,
workflow edits → `build-deploy.sh --resources` from the jumpbox.

## 7. What changes in the repo (later, during execution — nothing now)

| File | Change | Why |
|------|--------|-----|
| `scripts/deploy/services/build-deploy.sh` | Optional `REGISTRY` env var: when set, rewrite `image: pe-workflow/…` → `$REGISTRY/pe-workflow/…` in `manifests.yaml` (temp copy) before `kubectl apply`. Optionally accept an `--acr` flag for login/push when run where Docker+az exist. | Lets the same script serve local parity (unset), CI deploy, and manual jumpbox deploys. |
| `azure-pipelines.yml` (new) | Pipeline from Step 4.4. | CI/CD. |
| `scripts/azure/provision.sh` (optional) | Capture the phase 1–2 az commands in the repo's shell-script style. | Repeatability; the commands above already work bare. |

**Explicitly unchanged** (the payoff of the CNPG/Bastion choices): all Helm values
(including `values-no-domain.yml`), `elasticsearch-cluster.yml`, Keycloak CR, CNPG
clusters, `camunda-deploy-no-domain.sh`, `camunda-port-forwards.sh`,
`configure-c8ctl.sh`, all Go services (no code changes), `web/` (built in CI), and the
c8ctl profile contract (`kubernetes`, localhost URLs).

## 8. Cost estimate (pay-as-you-go, ≈ monthly, region-dependent)

| Item | ≈ $/mo |
|------|-------:|
| AKS free-tier control plane | 0 |
| 2× Standard_D4s_v5 nodes (autoscale to 3) | 280–420 |
| Node OS disks (2–3 × 128 Gi Premium) | 40–60 |
| PVC data disks (5 × smallest fitting Premium tier) | 15–30 |
| Jumpbox Standard_B2s + disk | ~40 |
| Azure Bastion Standard | ~106 |
| ACR Standard | ~6 |
| Container Insights / Log Analytics (~10–20 GB ingest) | 25–50 |
| Outbound LB public IP | ~4 |
| **Total** | **≈ 520–720** |

Cost levers: `az aks stop/start` (keeps all PVC/cluster state; only disks and IPs bill
while stopped — wait 15–30 minutes between stop and start, and re-run `az aks
get-credentials` on the jumpbox after a start since the API-server IP can change),
jumpbox auto-shutdown, and confirming the autoscaler's max of 3 is rarely hit. Bastion
Developer would save ~$106/mo but removes laptop UI access (F2) — not recommended.

## 9. Risks, wrinkles, and mitigations

- **Jumpbox is a single point of ops + CI deploy.** Break-glass from the laptop: `az aks
  command invoke -g $RG -n $AKS --command "kubectl get pods -n camunda"` — ARM is a
  public endpoint, so this works even with the cluster private (needs Contributor).
  Rebuilding the jumpbox is cheap; its state is only tooling + kubeconfig + agent.
- **Bastion Standard required for native tunnels** (F2). If Standard is ever replaced by
  Developer, UI access from the laptop is lost.
- **Image pulls traverse the public internet**: ACR (Standard, public endpoint) for
  `pe-*` images, and docker.io/ghcr.io/docker.elastic.co for platform images. TLS +
  managed identity; acceptable for MVP, revisited if an egress policy lands (then: ACR
  Premium + private endpoint, and an explicit egress allowlist for the platform image
  sources).
- **Cluster egress dependency list** (default outbound LB allows all; matters only under
  lockdown): `helm.camunda.io`, `download.elastic.co`, `raw.githubusercontent.com`,
  `docker.io`, `ghcr.io`, `docker.elastic.co`, `<acr>.azurecr.io`.
- **TLS**: everything is HTTP over localhost tunnels, exactly as today. TLS/hostnames
  require a private CA or DNS-01 issuer on a private cluster — deferred (§3).
- **Slow first startup** on AKS vs k3s (Premium disk attach, registry pulls); not an
  error, just patience in phase 3.
- **Quota**: if `Standard_Dv5FamilyCore` is exhausted in the region, use D4s_v4/D4as_v5
  equivalents or request quota before phase 2.
- **ADO free tier**: 1 hosted parallel job → the build stage is a single sequential job
  (no matrix); self-hosted agents are unlimited.
- **No data migration was performed by design** — if historical process data ever needs
  to move, it is a separate pg_dump/ES-snapshot exercise, not part of this plan.

## 10. Lifecycle and teardown

- **Stop (nights/vacations):** `az aks stop -g $RG -n $AKS` — stops nodes + control
  plane, preserves all state (works on free-tier, VMSS-backed clusters). `az aks start`
  to resume; re-run `az aks get-credentials` on the jumpbox afterwards.
- **Jumpbox:** auto-shutdown (Step 2.2); `az vm start/stop -g $RG -n $JUMPBOX` as needed.
- **Full teardown:** `az group delete -n $RG --yes --no-wait` — removes cluster, VMs,
  disks, Bastion, ACR content, log data. The ADO org/project and repo host are separate
  and cleaned up manually if desired.
- **Mac Studio:** untouched throughout; decommission (or keep as reference) after phase 7.
