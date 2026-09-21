# Azure Migration Plan: pe-workflow

This document describes what it takes to move the pe-workflow project from its current
local setup (self-managed Camunda 8 on a Mac Studio running Rancher Desktop / k3s) to
Microsoft Azure.

## Decision record

| Decision | Choice |
|----------|--------|
| Camunda deployment model | Self-managed Camunda 8 on AKS (current Helm-based architecture ported over) |
| Data services | Managed PostgreSQL (Azure Database for PostgreSQL Flexible Server); Elasticsearch stays in-cluster via ECK |
| Network exposure | Private AKS cluster — no public ingress; access via VPN Gateway / Azure Bastion |
| Infrastructure-as-Code | az CLI scripts (matching the existing `scripts/deploy.sh` shell-script style) |
| CI/CD | Azure DevOps Pipelines (native Azure CI/CD) |

## Target architecture

One private AKS cluster in a VNet runs the exact same stack as today (Camunda Helm chart
14.6.1, ECK-managed Elasticsearch, Keycloak operator, 7 Go services + BFF webapp), with
Azure-managed PostgreSQL replacing CloudNativePG, Azure Container Registry for images,
and VPN/Bastion replacing kubectl port-forwarding as the access path.

## Azure services needed

| # | Service | Why it's needed |
|---|---------|-----------------|
| 1 | **Resource Group** | Groups every resource below for one-command teardown and cost tracking. |
| 2 | **Virtual Network + subnets** | Private isolation for AKS nodes, PostgreSQL delegated subnet, VPN Gateway subnet, Bastion subnet. Required because the cluster is private — nothing gets a public IP. |
| 3 | **AKS (private cluster)** | Replaces k3s/Rancher Desktop. Runs Camunda Helm chart, ECK, Keycloak operator, and the Go services. Enables OIDC workload identity + Secrets Store CSI at creation. |
| 4 | **AKS user node pool (e.g., 3× Standard_D8s_v5, autoscale 3–6)** | Camunda + Elasticsearch + Optimize + Keycloak are memory-hungry; today's Mac Studio capacity doesn't map to one node. System pool: 2× D2s_v5. |
| 5 | **Azure Disk Storage (Premium SSD via built-in CSI)** | Backs the existing 10Gi PVCs (Zeebe, Elasticsearch) — direct replacement for k3s local storage; no manifest change needed. |
| 6 | **Azure Database for PostgreSQL Flexible Server** | Replaces the three CNPG clusters (`pg-identity`, `pg-keycloak`, `pg-webmodeler`) with one managed server hosting 3 databases. Removes the CNPG operator and gets patching/backups for free. VNet-integrated private access. |
| 7 | **ECK operator on AKS (Elasticsearch 8.19, in-cluster)** | Zeebe secondary storage + Optimize index. Stays in-cluster because Azure has no first-party managed Elasticsearch (the Elastic Cloud ISV service was ruled out in favor of parity). |
| 8 | **Azure Container Registry (Premium)** | Hosts the 7 Go worker/BFF images (replaces local `docker build` in `build-deploy.sh`). Premium SKU is needed for a private endpoint so private-cluster nodes don't traverse the public internet to pull. |
| 9 | **Key Vault + Secrets Store CSI driver** | Replaces `set-secrets.sh` for pre-seeded secrets (PG credentials, Keycloak admin, TLS certs); synced into Kubernetes secrets. Camunda's deploy-time-generated OIDC secrets stay in-cluster exactly as today. |
| 10 | **VPN Gateway (point-to-site)** | Lets developer laptops resolve cluster-internal DNS and reach Keycloak/Operate/webapp — this is what replaces `camunda-port-forwards.sh`. |
| 11 | **Azure Bastion + jumpbox VM** | Browser-based ops access without VPN: run kubectl/helm/c8ctl from the jumpbox. |
| 12 | **Azure Private DNS zones** | `privatelink.postgres.database.azure.com` for the Flexible Server; a custom zone (e.g., `pe.internal`) for ingress hostnames. |
| 13 | **Log Analytics + Container Insights + Managed Prometheus/Grafana** | The BFF and workers already expose Prometheus `/metrics` — Managed Prometheus scrapes them with near-zero code change; Container Insights captures pod logs. (Recommended, optional.) |
| 14 | **Microsoft Entra ID** | AKS admin group for cluster RBAC, Azure DevOps service connection via workload identity federation, ACR attach auth. Does **not** replace Keycloak — Camunda auth stays on Keycloak. |
| 15 | **Azure DevOps Pipelines** | Native Azure CI/CD: builds and tests the Go services, pushes images to ACR over a workload-identity-federated service connection, and deploys the platform, workers, and workflow resources. Optionally pair with Azure Repos if source hosting moves to Azure as well. |

**Not needed:** Application Gateway/Front Door/Traefik (private cluster), Entra External ID,
Service Bus, any Azure PaaS for workers — the Go services need no code changes; they talk
to in-cluster `camunda-zeebe-gateway:26500` and Keycloak via service DNS.

## What changes in the repo

- `scripts/deploy/camunda/helm-values/values-no-domain.yml` — DB hosts → Flexible Server
  FQDN + credentials from CSI-synced secret; keep `identity.keycloak.internal: false` and
  ECK Elasticsearch values; redirect URLs stay `localhost:*` if port-forwarding is kept,
  or move to `https://*.pe.internal` if internal ingress is added.
- New `scripts/deploy/camunda/scripts/camunda-deploy-azure.sh` (fork of
  `camunda-deploy-no-domain.sh`): drops the CNPG-operator step, adds Secrets Store CSI
  install.
- `scripts/deploy/services/build-deploy.sh` — `docker build` → ACR build/push;
  `manifests.yaml` gets ACR image refs (no pull secret needed with
  `az aks update --attach-acr`).
- `scripts/deploy/camunda/scripts/configure-c8ctl.sh` — register c8ctl profile `azure`
  (URL unchanged through port-forward/VPN).
- New `scripts/azure/` with the az CLI provisioning scripts (the IaC equivalent of
  today's `deploy.sh` pattern).
- New `azure-pipelines.yml` (plus optional `pipelines/` template files) — the CI/CD
  pipeline for build, test, push, and deploy.

## Migration steps

1. **Foundation** — `az group create`; VNet with 4 subnets (aks, gateway, bastion,
   postgres); private DNS zones; NSGs.
2. **AKS** — `az aks create` with `--enable-private-cluster`, OIDC workload identity,
   system + user pools, zone-redundant; kubeconfig via VPN or `az aks command invoke`.
3. **ACR + images** — create Premium ACR with private endpoint, `--attach-acr` to AKS,
   adapt and run `build-deploy.sh` to push the 7 images.
4. **PostgreSQL** — one Flexible Server (VNet-integrated), 3 databases; store admin
   credentials in Key Vault; create the schemas/users that the CNPG `Cluster` CRs would
   have created.
5. **Key Vault + CSI** — install Secrets Store CSI driver + Azure provider;
   `SecretProviderClass` syncing PG/Keycloak/TLS secrets into the `camunda` namespace.
6. **Camunda platform** — install ECK + Keycloak operators (skip CNPG); deploy the
   Elasticsearch CR unchanged; run the adapted Helm deploy with the Azure values file;
   then run `configure-c8ctl.sh` against the new endpoint.
7. **Workers/BFF** — `kubectl apply -f manifests.yaml` (env vars are already in-cluster
   service DNS; only image refs change); verify Zeebe worker connections.
8. **Workflow resources** — `c8ctl deploy` the 17 BPMN/DMN/form artifacts; deploy the
   webapp.
9. **Access layer** — VPN Gateway point-to-site with a client cert per developer;
   private DNS A-records for Keycloak/gateway/webapp pointing at the internal LB (or
   keep the existing port-forward script over the VPN — lowest-change option for a dev
   environment); Bastion + jumpbox for no-VPN ops.
10. **Observability** — enable Container Insights, Managed Prometheus scrape config for
    the `/metrics` endpoints, Managed Grafana dashboard, and one alert (pod restarts /
    incidents).
11. **CI/CD (Azure Pipelines)** — create an Azure DevOps project and a service
    connection to the Azure subscription using workload identity federation (no stored
    secrets). Pipeline: build + test Go, build images, push to ACR, then deploy. Because
    Microsoft-hosted agents cannot reach a private API server, deploy steps run via
    `az aks command invoke`, or a self-hosted agent on the jumpbox — which can also run
    `c8ctl deploy` for the workflow resources.
12. **Parity validation** — run the `Testing_Guide.md` scenario matrix; confirm the two
    known quirks (Zeebe 8.9.12 task headers not delivered, occasional ghost jobs) behave
    identically on AKS.

## Wrinkles to be aware of

- **Private cluster + hosted CI**: Azure DevOps Microsoft-hosted agents can't reach the
  private API server — `az aks command invoke` or a self-hosted agent (jumpbox) is
  mandatory for deploy steps. Self-hosted agents are free; the hosted free tier includes
  1 parallel job.
- **TLS**: Let's Encrypt HTTP-01 doesn't work on a private cluster — use Key Vault-stored
  certs (private CA) or a cert-manager CA issuer. If you keep port-forwarding over the
  VPN, plain HTTP like today works as-is.
- **Cost**: rough order ~$1.2–1.8k/month (nodes ~$850, PG ~$100, Bastion + VPN GW ~$300,
  ACR Premium ~$200, disks/logs extra). Autoscale and stopping the environment when idle
  can trim it; keep Zeebe on regular nodes (replicationFactor 1 dislikes spot
  interruptions).
- **What gets simpler**: the CNPG operator and 3 PG clusters disappear; no port-forward
  choreography if you adopt VPN + DNS names.
