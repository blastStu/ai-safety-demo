# AI Safety Demo — Garak + Guardrails on OpenShift AI

This repo is the **GitOps source** for a Red Hat Demo Platform (RHDP) catalog item.
Same manifests, two ways to deploy: shell scripts (learning / step-through) or a Helm chart
(RHDP field delivery and `oc apply` production).

**Current target: bare OpenShift with 2 CPU + 2 GPU worker nodes, no OpenShift AI installed.**
The stack below installs everything from scratch:

> bare OpenShift → **RHOAI 3.6 EA2** (operator `beta`, CSV `rhods-operator.3.6.0-ea.2`) →
> **NFD + NVIDIA GPU Operator** (GPU nodes become `nvidia.com/gpu` schedulable) →
> **DSPA (Kubeflow Pipelines v2)** + **SeaweedFS** (S3) + **PostgreSQL** →
> **MLflow** + **TrustyAIService + EvalHub `garak-kfp`** + **Benchmarks**

Previous V1.1 baseline was CPU-only on `stable-3.5` / `rhods-operator.3.5.3` with external models;
3.6 keeps the same DSPA/MLflow/EvalHub contract (`DSPA Ready True`, `MLflow Available True`,
`EvalHub Ready True`).

## Prerequisites

- An OpenShift cluster you have `cluster-admin` on. The reference cluster is **bare OCP**
  (no RHOAI, no NFD/GPU Operator — the setup below installs them) with at least
  **2 CPU + 2 GPU worker nodes**. The scripts and the Helm chart both assume this
  starting point; a pre-provisioned RHDP RHOAI cluster also works (see "RHDP notes" below).
- `oc` (matching `oc version`), `helm` 3.8+, `jq`.
- Two OpenAI-compatible model endpoints for the final Garak run: a **target/judge** model
  and an **abliterated** prompt-generator (see `Benchmarks` and `Secrets`).

Check access first:

```bash
oc whoami --show-server   # should print the API URL you were given
oc get nodes -o wide      # expect 4 workers (2 CPU + 2 GPU instance types, e.g. g6.xlarge)
```

## Pick a path

| Path | Who it's for | Command |
|------|-------------|---------|
| **Scripts** (learning) | You want to see each phase, pause, and re-run idempotently | `scripts/00-check-cluster.sh` → `…01…` → `…04…` below |
| **Helm** (one-shot / CI) | You want one declarative install you can repeat or hand to RHDP | `helm install … charts/ai-safety-demo --set gpu.enabled=true` |

Both paths produce the same cluster. RHDP's catalog item uses the Helm path (see
[RHDP / GitOps](#rhdp--gitops) and [charts/ai-safety-demo/README.md](charts/ai-safety-demo/README.md)).

---

## Path 1 — Scripts (learning experience)

Run from the repo root, in order. Every script is `set -euo pipefail`, idempotent, and
leaves a `Ready`/`Available` gate so you know when to continue. Re-running a script that
already succeeded is safe — it prints "already Succeeded / skipping".

```bash
# 0. Read-only sanity check: whoami, nodes (CPU vs GPU), RHOAI operator not yet present,
#    packagemanifest channels (nfd + gpu-operator-certified appear here on a GPU cluster),
#    CRDs not yet present on a bare cluster.
./scripts/00-check-cluster.sh

# 1. Platform prerequisites: cert-manager + Kueue (derive channel/CSV live, Manual
#    approval, wait for CSV Succeeded). Skips cleanly when RHDP already installed them.
./scripts/01-apply-prereqs.sh

# 1b. GPU — only if oc get nodes shows GPU instance types (g6/p families).
#     Skips with a clear message on CPU-only clusters. Installs NFD (OwnNamespace OG,
#     labelSources: all + GPU-taint toleration, rollout restart) then NVIDIA GPU Operator
#     (OwnNamespace OG, CSV alm-examples → ClusterPolicy, manager toleration patch).
./scripts/01b-setup-gpu.sh
# Verify after: oc get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
# Driver rollout can take a few minutes.

# 2. RHOAI 3.6 EA2: installs rhods-operator 3.6.0-ea.2 from the beta channel when missing
#    (Manual InstallPlan poll, wait CSV Succeeded), waits for DataScienceCluster +
#    DashboardConfig to be created, patches DSC (aipipelines/kserve/trustyai/mlflowoperator
#    Managed, etc.) and dashboard flags (disableLMEval, externalModels, modelCapabilities),
#    waits for DSC Ready.
./scripts/02-enable-dsc.sh
# After: oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'  →  Ready

# 3. Object storage + pipeline + experiment tracking (must be before EvalHub):
#    - SeaweedFS (S3 on ghcr.io/chrislusf/seaweedfs digest, Deployment/Service/Routes)
#    - evalhub namespace (platform namespace, no tenant label) + Postgres (DeploymentConfig)
#    - DSPA (datasciencepipelinesapplications.opendatahub.io/v1, Ready True)
#    - MLflow (mlflow.opendatahub.io/v1, Available True)
./scripts/03-deploy-dspa-mlflow.sh

# 4. EvalHub: TrustyAIService (Available True) + EvalHub garak-kfp (Ready True).
#    Needs DSC Ready + SeaweedFS Available + Postgres rollout + DSPA Ready + MLflow Available.
./scripts/04-deploy-evalhub.sh
# After: open the RHOAI dashboard URL printed at the end → Evaluations → garak-kfp visible.

# 5. Run the intents benchmark (needs redteam-api-keys secret — see Secrets below).
./scripts/05-run-garak.sh
# or: Dashboard → Develop & train → Evaluations → Start evaluation run → garak-kfp → intents
```

### What to watch for

- **`00-check-cluster.sh`** is the canary: if it says "No DataScienceCluster yet" / "no eval/mlflow CRDs yet"
  on a bare cluster, that's expected — `01`/`01b`/`02` will create them.
- **`01b-setup-gpu.sh`** prints `GPU-capable nodes: N` — if `0` on a 2+2 cluster, your kubeconfig is
  pointed at the wrong API (re-login). GPU allocatable (`nvidia.com/gpu: "1"`) appears only after
  the NVIDIA driver DaemonSet finishes (minutes).
- **`02-enable-dsc.sh`** waits for `default-dsc` / `odh-dashboard-config` to be created by the operator
  before patching — on a cold cluster that can be 30–120 s after CSV Succeeded. Let it poll.
- All `oc wait --for=condition=Ready` steps can take several minutes; the scripts retry with a deadline.

---

## Path 2 — Helm (one-shot + RHDP)

The Helm chart is at [`charts/ai-safety-demo/`](charts/ai-safety-demo/) — see its
[README](charts/ai-safety-demo/README.md) for values reference and RHDP details.
It renders the same resources as `overlays/rhdp` without Kustomize, so Argo CD can use
`source.helm`.

### Local install (matches the 2 CPU + 2 GPU bare cluster)

```bash
# Dry-run first (on a truly bare cluster this shows resource mapping not found for
# DSPA/MLflow/EvalHub/TrustyAI until the RHOAI CRDs exist — that's expected):
helm template ai-safety-demo charts/ai-safety-demo --set gpu.enabled=true \
  | oc apply --dry-run=server -f -

# Real install:
helm upgrade --install ai-safety-demo charts/ai-safety-demo \
  --set gpu.enabled=true

# Argo CRD validation: the chart carries SkipDryRunOnMissingResource on the four CRs
# and a wave-3 wait-for-rhoai-crds gate so Argo doesn't reject the whole app before
# the RHOAI CSVs install. Operator installs are Manual with 15-minute poll + Role/Binding.

# Watch progress:
oc get csv -A | grep -v Succeeded || echo "all CSVs Succeeded"
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'  # → Ready
oc get dspa dspa -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
oc get evalhub evalhub -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get nodes -o json | jq -r '.items[] | "\(.metadata.name): nvidia.com/gpu=\(.status.allocatable["nvidia.com/gpu"] // "none")"'
```

Common knobs (all in [`values.yaml`](charts/ai-safety-demo/values.yaml)):

| Value | When |
|-------|------|
| `operators.rhoai.channel` / `startingCSV` | Bump to `stable-3.6` + GA CSV when 3.6 goes GA (today: `beta` / `rhods-operator.3.6.0-ea.2`) |
| `gpu.enabled` | `true` on the 2+2 cluster; leave `false` on CPU-only clusters (NFD/GPU Operator not installed) |
| `gpu.nfd.*` / `gpu.gpuOperator.*` | Pin a different NFD/GPU Operator CSV if the catalog moved |
| `rhoai.dashboard.*` | `modelCapabilities: true` is on by default for 3.6 EA2 |
| `seaweedfs.*` / `postgres.*` / `mlflow.storage` | Storage sizes, image digests, non-sensitive creds |

### RHDP / GitOps

RHDP provisions the bare cluster, then points its **Existing GitOps Repo** at:

```
repoURL:        https://github.com/blastStu/ai-safety-demo
targetRevision: <your-branch>     # e.g. helm-v1.1
path:           charts/ai-safety-demo
source.helm.values: |
  gpu:
    enabled: true          # when the provisioned cluster has a GPU worker pool
  # bases.rhoai: true       # when RHDP pre-installs RHOAI + cert-manager (chart skips its own)
```

Argo CD sync waves: namespaces/OperatorGroups/Subscriptions + approvers `0`, ConfigMaps/RBAC `1`,
DSC patch + credential Jobs `2`, `wait-for-rhoai-crds` gate + workloads/PVCs `3`, DSPA `4`, MLflow `5`,
EvalHub/TrustyAI `6`. See [chart README → Chart layout](charts/ai-safety-demo/README.md#chart-layout).

The Kustomize overlay at [`overlays/rhdp/`](overlays/rhdp/) is the same stack for `oc apply -k`
debugging; [`manifests/argocd/application.yaml`](manifests/argocd/application.yaml) is a standalone
Argo Application for a Kustomize deployment. Prefer the Helm path for new RHDP leases.

---

## What lives in this repo

```
manifests/              # Kustomize bases, numbered for apply order
  00-prereqs/            # cert-manager, Kueue (channel + CSV pinned)
  10-rhoai/              # RHOAI 3.6 EA2: rhods-operator beta pin + DSC patch + dashboard flags
  20-dspa/               # SeaweedFS (object storage) + DSPA (Kubeflow Pipelines) + Postgres
  30-mlflow/             # MLflow v1 (single instance named mlflow)
  40-garak/              # EvalHub garak-kfp (TrustyAI + EvalHub, tenancy: single)
overlays/               # per-environment Kustomize (dev, rhdp) — sync-wave patches
charts/ai-safety-demo/  # Helm chart — canonical for RHDP, renders the same stack as overlays/rhdp
benchmarks/             # runnable Benchmark parameters JSON for the Dashboard upload
scripts/                # 00-check → 01-prereqs → 01b-gpu → 02-dsc → 03-dspa+mlflow → 04-evalhub → 05-garak
```

## Benchmarks

`benchmarks/intents-garak-kfp.json` is the **Benchmark parameters** upload for
`provider: garak-kfp, benchmark: intents` (SDG → Baseline → SPO → TAP). In the RHOAI
dashboard: **Develop & train → Evaluations → Start evaluation run → `garak-kfp` → `intents`
→ Upload → pick this file**.

It contains:

- `kfp_config`: `https://ds-pipeline-dspa.evalhub.svc.cluster.local:8888` (direct API server, `verify_ssl: false`),
  namespace `evalhub`, S3 `seaweedfs:8333` / bucket `evalhub`
- `intents_models`: `judge` + `sdg` + `attacker` + `evaluator` (all-or-one), `sdg` name with `hosted_vllm/` prefix
- `sdg_max_concurrency: 1`

Replace the `https://YOUR_TARGET_MODEL/v1` / `YOUR_ABLITERATED_MODEL/v1` placeholders with your
OpenAI-compatible endpoints before uploading. The same values can be passed via env to
`scripts/05-run-garak.sh` (`MODEL_URL` / `RED_URL` / `MODEL_NAME` / `RED_NAME`).

## Secrets — never committed

The demo's external model credentials are not in git. After `04-deploy-evalhub.sh`, create the
8-key `redteam-api-keys` secret in `evalhub` (Dashboard's **API key secret name** → `Validate connection`
probes `api-key`, Garak uses the role keys):

```bash
oc create secret generic redteam-api-keys -n evalhub \
  --from-literal=api-key="<TARGET_AND_JUDGE_TOKEN>" \
  --from-literal=TARGET_API_KEY="<TARGET_TOKEN>" \
  --from-literal=JUDGE_API_KEY="<TARGET_TOKEN>" \
  --from-literal=EVALUATOR_API_KEY="<TARGET_TOKEN>" \
  --from-literal=SDG_API_KEY="<ABLITERATED_TOKEN>" \
  --from-literal=ATTACKER_API_KEY="<ABLITERATED_TOKEN>" \
  --from-literal=k8s_url="https://api.<your-cluster>:6443" \
  --from-literal=k8s_sa_token="" \
  --dry-run=client -o yaml | oc apply -f -
```

`secrets` (`seaweedfs-evalhub-credentials`, `evalhub-db-credentials`, `mlflow-s3-credentials`)
are created by the scripts/chart (SeaweedFS placeholder `THEACCESSKEY` / Postgres
`REPLACE_ME_GENERATE_16CHAR` are demo defaults — rotate for anything real).

## Roadmap

| Milestone | Demo scope | Cluster |
|-----------|-----------|---------|
| **V1.1** (baseline) | `garak-kfp → intents` on external target + external abliterated SDG, judge as target, MLflow | CPU-only, no GPU Operator, bare OCP + RHOAI 3.6 EA2 |
| **V1.2** | Same run behind NeMo Guardrails — side-by-side comparison | + Guardrails |
| **V1.3** | Self-contained models (vLLM on GPU) | + GPU pool + serving (next if External not viable) |
| V1.4 | Storyboard + field hand-off | — |

## Troubleshooting

- **Packagemanifest not found (`nfd` / `gpu-operator-certified`)** — catalog snapshot doesn't carry it.
  `01b-setup-gpu.sh` derives live; if it fails, check the marketplace is reachable and re-run after a catalog resync.
- **DSPA / MLflow / EvalHub `resource mapping not found` on `helm template | oc apply --dry-run=server`** — CRDs don't exist until RHOAI CSVs are Succeeded. Expected on a bare cluster; Argo's CRD gate + sync-waves handle it. For scripts, let `02-enable-dsc.sh` finish before `03-`.
- **No `pci-*` labels on GPU nodes** — NFD's `labelSources: ["all"]` + `oc rollout restart ds/nfd-worker` (both wired in the chart/scripts) fix the 4.22 default-off. Check `oc get nodes -o json | jq '.items[].metadata.labels | keys[] | select(test("pci"))'`.
- **`nvidia.com/gpu` never allocatable** — driver DaemonSet still building. `oc get pods -n nvidia-gpu-operator` (driver/toolkit/device-plugin Running, validators Completed), then `oc logs -n nvidia-gpu-operator ds/nvidia-driver-daemonset`.

## References

- RHOAI: [3.6 EA release notes (under 3.5 docs root)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/3.6_early_access_release_notes/index) · [Garak risk assessment](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/evaluating_ai_systems/test-model-safety-with-automated-risk-assessment_evaluate) · [NeMo Guardrails](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/enabling-ai-safety-with-nemo-guardrails_nemo-guardrails)
- NVIDIA GPU Operator: [docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html) (channel/CSV always derived live from `packagemanifest gpu-operator-certified`)
- Platform notes: [charts/ai-safety-demo/README.md](charts/ai-safety-demo/README.md) · [rosa-cluster-skill](https://github.com/blastStu/rosa-cluster-skill) (ROSA HCP + GPU + RHOAI provisioning reference)

