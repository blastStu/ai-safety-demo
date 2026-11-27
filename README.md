# AI Safety Demo — Garak + Guardrails on OpenShift AI

> **Work in progress — V1.1 baseline.** This repo currently proves the "unguarded" half: an external target model is tested with Garak's `intents` benchmark via EvalHub, driven by Kubeflow Pipelines on SeaweedFS-backed object storage, with results in MLflow. Guardrails (V1.2) and self-contained GPU models (V1.3) are not yet on `main`. Expect breaking changes until the RHDP catalog item is cut.

This repo is the GitOps source for a Red Hat Demo Platform catalog item and a matching AI Quickstart. Same manifests, two entry points:

- **RHDP:** the catalog provisions a GPU-ready cluster and Argo CD points at this repo.
- **Quickstart:** you already have an OpenShift cluster, you apply the same layers with `kustomize` or `helm`.

No RHDP-specific glue lives in here — the repo is cluster-agnostic.

## Roadmap

| Version | Demo scope | Cluster |
|---|---|---|
| **V1.1** *(now)* | `garak-kfp` → `intents` (SDG → Baseline → SPO → TAP) on an **external** target + **external** abliterated SDG generator, judge as target, results in MLflow | CPU-only. No GPU operator, no in-cluster model. |
| V1.2 | Same `garak-kfp` run against the **same target behind NeMo Guardrails** — compare | + Guardrails |
| V1.3 | Bring the models self-contained (vLLM + GPU) | + GPU pool + serving |
| V1.4 | Storyboard + field hand-off | — |

## Prerequisites

- OpenShift 4.14+ (ROSA HCP or otherwise) with `cluster-admin`.
- Red Hat OpenShift AI **3.5.x** (operator `stable-3.5`, `DataScienceCluster` API `v2`). `v1alpha1` is not served on 3.5.3 — this repo tracks `v1`.
- `oc`, `kustomize` (5.4+), `jq`.
- Two OpenAI-compatible endpoints: a **target/judge** model and an **abliterated** prompt-generator (see `Benchmarks`).

## What lives in this repo

```
manifests/              # Kustomize bases, numbered for apply order
  00-prereqs/            # cert-manager, Kueue (channel + CSV pinned)
  10-rhoai/              # rhods-operator pin + DataScienceCluster patch + dashboard flags
  20-dspa/               # object storage (SeaweedFS) + pipeline server (DSPA) + Postgres for EvalHub
  30-mlflow/             # MLflow instance (v1, single instance named mlflow)
  40-garak/              # EvalHub garak-kfp (trustyai + evalhub, tenancy: single) + probe ConfigMap
overlays/dev, overlays/rhdp   # per-environment patches (minimal for V1.1)
charts/ai-safety-demo/    # Helm port of overlays/rhdp for RHDP Argo CD source.helm
benchmarks/              # runnable Benchmark parameters JSON for the Dashboard upload
scripts/                # 00-check, 01-prereqs, 02-enable-dsc, 03-dspa-mlflow, 04-evalhub, 05-run-garak
```

Apply in order:

```bash
./scripts/00-check-cluster.sh      # read-only gates: whoami, DSC phase, CSVs, nodes, routes
./scripts/01-apply-prereqs.sh      # cert-manager + Kueue
./scripts/02-enable-dsc.sh         # flip the DataScienceCluster to the V1.1 set
./scripts/03-deploy-dspa-mlflow.sh # object storage + pipelines + MLflow
./scripts/04-deploy-evalhub.sh     # TrustyAIService + EvalHub garak-kfp
# then trigger the evaluation — see Benchmarks
```

Each script waits for its `Ready` / `Available` gate; re-running is idempotent.

### Helm / RHDP GitOps path

`charts/ai-safety-demo/` renders the same stack as `overlays/rhdp` without Kustomize,
for RHDP catalog items that deploy from a Helm chart (Argo CD `source.helm`):

```bash
helm template ai-safety-demo charts/ai-safety-demo | oc apply --dry-run=server -f -
```

Point the RHDP **GitOps Path** at `charts/ai-safety-demo`. `overlays/rhdp` stays
Kustomize for `oc apply -k`. See [charts/ai-safety-demo/README.md](charts/ai-safety-demo/README.md).

## Benchmarks

`benchmarks/intents-garak-kfp.json` is the **Benchmark parameters** payload for `provider: garak-kfp, benchmark: intents`. Drag it into the Dashboard's **Benchmark parameters → Upload** area on **Develop & train → Evaluations → Start evaluation run → garak-kfp → intents**. It contains:

- `kfp_config`: `https://ds-pipeline-dspa.evalhub.svc:8888` (direct api-server, `verify_ssl: false`), namespace `evalhub`, S3 `seaweedfs:8333`
- `intents_models`: `judge` + `sdg` + `attacker` + `evaluator` (all-or-one — see RHOAI docs), `sdg` name with `hosted_vllm/` prefix
- `sdg_max_concurrency: 1`

Replace the placeholder `https://YOUR_TARGET_MODEL/v1` / `YOUR_ABLITERATED_MODEL/v1` URLs in that JSON with your endpoints before uploading.

## Secrets — never committed

V1.1's external models are never in git. Create them imperatively:

```bash
oc create secret generic redteam-api-keys -n evalhub \
  --from-literal=api-key="<TARGET_AND_JUDGE_TOKEN>" \
  --from-literal=TARGET_API_KEY="<TARGET_TOKEN>" --from-literal=JUDGE_API_KEY="<TARGET_TOKEN>" --from-literal=EVALUATOR_API_KEY="<TARGET_TOKEN>" \
  --from-literal=SDG_API_KEY="<ABLITERATED_TOKEN>" --from-literal=ATTACKER_API_KEY="<ABLITERATED_TOKEN>"
```

The Dashboard's **API key secret name: redteam-api-keys** then `Validate connection` probes via `api-key`.

## References

- RHOAI 3.5: [NeMo Guardrails](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/enabling-ai-safety-with-nemo-guardrails_nemo-guardrails) · [Garak automated risk assessment](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/evaluating_ai_systems/test-model-safety-with-automated-risk-assessment_evaluate)
- ODH `odh-gitops` `rhoai-3.5` branch is the platform's chart anchor; `main` tracks 3.6.
