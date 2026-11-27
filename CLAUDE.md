# AI Safety Demo — notes for the coding agent

You are working on the **GitOps source for an RHDP catalog item** (and matching AI
Quickstart) that puts a live AI-safety demo on OpenShift AI: red-team a model with
Garak, put NeMo Guardrails in front, red-team again, compare. Audience: security teams.

## Current state (what the cluster is right now)

- **Reference cluster:** bare OpenShift (no RHOAI, no NFD/GPU Operator) with **2 CPU + 2 GPU
  worker nodes**. The stack provisions everything from that starting point. The previous
  V1.1 baseline was CPU-only on `stable-3.5` / `rhods-operator.3.5.3`; the current target
  is below.
- **Target operator set:** RHOAI **3.6 EA2** — `beta` channel, CSV `rhods-operator.3.6.0-ea.2`
  (GA will move to `stable-3.6`; bump both `charts/ai-safety-demo/values.yaml` and
  `manifests/10-rhoai/rhods-operator/subscription.yaml` when you do). Dashboard flag
  `modelCapabilities: true` (3.6+) is already wired.
- **GPU:** NFD + NVIDIA GPU Operator, controlled by `gpu.enabled` in the Helm chart and
  `scripts/01b-setup-gpu.sh` for the script path. Both follow `rosa-cluster-skill` Step 6:
  OwnNamespace OperatorGroups, `labelSources: [all]` PCI fix, `nvidia.com/gpu=true:NoSchedule`
  tolerations, ClusterPolicy from CSV `alm-examples`, manager toleration patch.
- **Rest of stack:** DSPA (Kubeflow Pipelines v2) + SeaweedFS (S3 on ghcr.io digest) + Postgres
  → MLflow v1 → TrustyAIService + EvalHub `garak-kfp` + benchmark JSON.

## How to run it

There are **two deployment paths that must stay in sync** — never break one while fixing the other.

**Scripts (learning / step-through):** ordered under `scripts/`, each `set -euo pipefail` and
idempotent with a `Ready`/`Available` gate. See [README.md](README.md#path-1--scripts-learning-experience)
for the exact sequence: `00-check` → `01-prereqs` (cert-manager+Kueue) → `01b-gpu` (NFD+GPU, skips on
CPU-only) → `02-dsc` (install RHOAI 3.6 EA2 from `beta`, patch DSC+dashboard) → `03-dspa+mlflow` →
`04-evalhub` → `05-garak`. `local/` files are gitignored scratch — never commit them.

**Helm (one-shot + RHDP):** [`charts/ai-safety-demo/`](charts/ai-safety-demo/) — `helm upgrade --install … --set gpu.enabled=true`
on the 2+2 cluster; RHDP points `targetRevision`/`path` at this chart with
`source.helm.values.gpu.enabled: true` (and `bases.rhoai` when it pre-installs RHOAI). See
[charts/ai-safety-demo/README.md](charts/ai-safety-demo/README.md) for values and Argo sync-wave details.
Wave-3 `wait-for-rhoai-crds` + `SkipDryRunOnMissingResource` on the four CRs handle bare-cluster validation.

**Overlays:** `overlays/rhdp` + `overlays/dev` are thin Kustomize wrappers for `oc apply -k`
debugging; `manifests/argocd/application.yaml` is a standalone Argo Application. They are
kept but the Helm chart is the canonical RHDP path.

## What to do when touching this repo

1. Read [README.md](README.md) first — it is the runbook for both paths. Keep it current when
   you change scripts, chart values, or the target cluster shape.
2. Keep `values.yaml` and `manifests/10-rhoai/rhods-operator/subscription.yaml` + `manifests/10-rhoai/patch-dsc-job.yaml`
   in sync (channel/CSV + dashboard flags) — drift between Helm and Kustomize already bit us once
   (`modelCapabilities` missing from the Kustomize ConfigMap, caught in review B1).
3. Never hardcode a `packagemanifest` channel/CSV — derive live with
   `oc get packagemanifest <pkg> -n openshift-marketplace` and record pins + date in
   `local/decisions.md` (audit trail, gitignored but shareable on request).
4. NFD/GPU Operator changes must follow `rosa-cluster-skill` Step 6 (OwnNamespace OGs, PCI
   labelSources, taint tolerations, ClusterPolicy extraction). The skill is not vendored —
   reference https://github.com/blastStu/rosa-cluster-skill.
5. Secrets (`redteam-api-keys`, S3 creds) are never in git — scripts create them imperatively,
   the chart creates the S3-derived copies via Jobs. Don't template `redteam-api-keys`.
6. Before pushing: `helm lint --strict charts/ai-safety-demo` (also with `--set gpu.enabled=true`)
   and `bash -n scripts/*.sh`. The chart must render 57 kinds without GPU, 71 with.
7. Commits are on `helm-v1.1` (current workstream); end messages with `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

## Local docs (gitignored, not authoritative after the README)

- `local/HANDOFF.md` — older orientation (2026-11-20, describes the 3.5.3 `sbatters-gitops` cluster).
  Still useful for demo narrative and RHDP catalog context, but operator versions/worker shape are stale.
- `local/decisions.md` — operator pin journal (now 3.6 EA2; update when you re-derive).
- `local/v1.1-walkthrough.md` — narrative script for the before-half demo. Update if the
  benchmark endpoints change for 3.6 (they haven't).
- `local/NEXT-STEP-RESULT-2026-11-27.md` — what the 3.6+GPU commit (95e1623) did and what still
  needs a live cluster run.

