# AI Safety Demo — how to run it (for the agent in this repo)

You are probably here to **run the demo**, not to extend this repo. This file is the
agent's runbook — keep it short, keep it accurate, and point at the canonical docs.

## What this is

A Red Hat Demo Platform (RHDP) catalog item — also a standalone AI Quickstart — that
gives field folks a live **AI safety** demo: red-team a model with Garak via EvalHub,
put NeMo Guardrails in front, red-team again, compare. Audience: security teams (or
similar) who own model safety. Session: one time-boxed run, "unprotected vs protected",
two MLflow reports side by side.

The demo is intentionally narrow in 2026-11: bare OpenShift with **2 CPU + 2 GPU**
worker nodes → **RHOAI 3.6 EA2** (`beta` / `rhods-operator.3.6.0-ea.2`) → NFD + NVIDIA
GPU Operator (GPU becomes `nvidia.com/gpu` schedulable) → DSPA + SeaweedFS (S3) + Postgres
→ MLflow + TrustyAIService + **EvalHub `garak-kfp`** (`intents` benchmark: SDG →
Baseline → SPO → TAP, with the current JSON it's `intents_models` all-or-one and
`sdg_max_concurrency: 1`). Guardrails is next, self-contained vLLM after that.

## Before you touch anything

1. **Read [README.md](README.md) once.** It is the runbook for both deployment paths
   (scripts vs Helm) and matches the current commit. Do not repeat its install
   commands here — link to it.
2. Check your environment variables before assuming defaults. The user's actual
   credentials may differ from placeholders.

## Starting point / cluster shape

- You will be handed **bare OpenShift** (no RHOAI, no NFD/GPU Operator) with 2 CPU + 2 GPU nodes
  — or a ROSA HCP / RHDP lease that looks the same. Confirm once:
  ```bash
  oc whoami --show-server
  oc get nodes -o wide   # expect 4 workers; GPU ones are g6.xlarge (or similar)
  ```
- The repo's scripts and Helm chart both install from that starting point. Don't try to
  pre-install RHOAI, cert-manager, NFD, or the GPU Operator by hand — the setup below does it.
  RHOAI 3.6 EA docs live under the **3.5 documentation root** (upstream quirk); if you go read
  docs, use the 3.6 EA release notes there. Don't chase a floating `main` of upstream odh-gitops.

## How to stand it up

Pick **one** path. Don't mix them on the same cluster.

**A — Scripts (learning / step-through, recommended when you're driving live):**
Follow [README → Path 1](README.md#path-1--scripts-learning-experience) in order:
`00-check` (sanity check, GPU count, packagemanifest) → `01-prereqs` →
`01b-gpu` (auto-skips on CPU-only) → `02-dsc` (installs RHOAI 3.6 EA2, patches DSC +
dashboard) → `03-dspa+mlflow` → `04-evalhub`. Every step has a `Ready`/`Available` gate;
let it finish before the next one. `00-check` saying "No DataScienceCluster yet" on a
bare cluster is expected.

**B — Helm (one-shot / RHDP / CI):**
Follow [README → Path 2](README.md#path-2--helm-one-shot--rhdp) — `helm upgrade --install
ai-safety-demo charts/ai-safety-demo --set gpu.enabled=true` on the 2+2 cluster. RHDP
wires `gpu.enabled: true` via `source.helm.values`; the chart's wave-3 CRD gate +
`SkipDryRunOnMissingResource` handles the bare-cluster Argo validation case. See
[charts/ai-safety-demo/README.md](charts/ai-safety-demo/README.md) for all `values.yaml` knobs.

Either path, the cluster is ready when:
```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'          # Ready
oc get dspa dspa -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
oc get evalhub evalhub -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get nodes -o json | jq -r '.items[] | "\(.metadata.name): nvidia.com/gpu=\(.status.allocatable["nvidia.com/gpu"] // "none")"'
```

## Running the demo itself

1. **Put the secret in.** `redteam-api-keys` in `evalhub` (8 keys: `api-key` plus
   `TARGET/JUDGE/EVALUATOR` + `SDG/ATTACKER` + `k8s_url`/`k8s_sa_token`) is never in git —
   create it imperatively after `04-evalhub.sh` per [README → Secrets](README.md#secrets--never-committed).
   The dashboard's **Validate connection** against `api-key` is what proves it.
2. **Upload the benchmark.** In the RHOAI dashboard: Develop & train → Evaluations →
   Start evaluation run → `garak-kfp` → `intents` → Upload → [`benchmarks/intents-garak-kfp.json`](benchmarks/intents-garak-kfp.json).
   Replace the `YOUR_*` endpoint placeholders first (see the file's `kfp_config` / `intents_models`
   / `sdg_max_concurrency`).
3. **Tell the room the comparison contract:** hold target model, Garak config, judge, and prompt
   seed constant. Call the workflow **Garak + SDG** (not TAP in deck material); the abliterated
   model is the SDG generator, never the assessment target. If SDG regenerates prompts per run,
   say so when reading the delta.
4. **Read it back in MLflow** — `https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')/mlflow`.

`scripts/05-run-garak.sh` is the same flow via `curl` against `https://<evalhub-route>/api/v1/evaluations/jobs`.

## Things that bite

- NFD's `labelSources: [all]` PCI fix + `oc rollout restart ds/nfd-worker` and the GPU
  toleration / ClusterPolicy extraction are already wired (scripts + chart) — don't re-add them
  by hand. Check `pci-*` labels and `nvidia.com/gpu` allocatable instead.
- `oc apply --dry-run=server` on a bare cluster will complain about DSC/EvalHub CRDs until RHOAI
  CSVs are Succeeded — expected. The chart's Argo gate handles this; for scripts, finish `02` first.
- The Dashboard Evaluations page is hidden unless `disableLMEval: false` + `externalModels: true` +
  `modelCapabilities: true` are set — they are in the patched dashboard config; a browser refresh
  is enough.
- 3.6 GA will move RHOAI from `beta` to `stable-3.6` with a new CSV — bump both
  `charts/ai-safety-demo/values.yaml` and `manifests/10-rhoai/rhods-operator/subscription.yaml` then.

## For the rare maintainer pass

If you're actually changing this repo, not just running it: keep Helm and Kustomize pins in sync
(channel/CSV + dashboard flags), derive `packagemanifest` channels live (don't hardcode), don't
template `redteam-api-keys`, and run `helm lint --strict` (also ` --set gpu.enabled=true`) plus
`bash -n scripts/*.sh` before pushing.
