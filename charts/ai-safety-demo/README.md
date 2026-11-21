# ai-safety-demo Helm chart

Helm port of [`overlays/rhdp`](../../overlays/rhdp) for the RHDP **Existing GitOps Repo
→ Path** field. Rendering this chart produces the same resources that
`oc apply -k overlays/rhdp` does at `gitops-v1.1` (040d1af), but without requiring
Kustomize at sync time, so Argo CD can use `source.helm` directly.

Verified RHOAI 3.5.3 baseline: DSPA `Ready True`, MLflow `Available True`,
EvalHub `Ready True`, `Develop & train → Evaluations → Start → garak-kfp`.

## Live verification (2026-11-21)

Deployed to `api.ocp.5td5k.sandbox5240.opentlc.com` (OCP 4.22.22, 5 nodes,
`gp3-csi`) with RHOAI 3.5.3 already installed but every target component `Removed`:

```bash
helm template ai-safety-demo charts/ai-safety-demo \
  --set operators.certManager.enabled=false \
  --set operators.kueue.enabled=false \
  --set operators.rhoai.enabled=false > /tmp/ai-safety-demo.yaml
oc apply -f /tmp/ai-safety-demo.yaml          # pass 1: DSC patch Job runs
# wait for the operator to install the DSPA/MLflow/EvalHub/TrustyAI CRDs
oc apply -f /tmp/ai-safety-demo.yaml          # pass 2: CRs apply
```

Result: `DataScienceCluster` `Ready`, `DSPA` `Ready True`, `MLflow` `Available True`,
`EvalHub` `Ready True`, `TrustyAIService` `Available True`; all four bootstrap Jobs
`Complete`; `seaweedfs-evalhub-credentials` (5 keys), `evalhub-db-credentials` (2 keys)
and `mlflow-s3-credentials` (4 keys) created. EvalHub reaches MLflow at
`https://mlflow.redhat-ods-applications.svc:8443/mlflow` (`/version` → 200).

The operator-install path (cert-manager/kueue/rhods Subscriptions + approvers) was not
exercised on this cluster because it ships those operators already; use a cluster
without them to test `operators.*.enabled=true`.

## Chart layout

| Template | Resources |
|---|---|
| `00-namespaces.yaml` | `evalhub` namespace (`opendatahub.io/dashboard: "true"`) |
| `00-cert-manager.yaml` | cert-manager Namespace/OperatorGroup/Subscription + approver RBAC + blocking InstallPlan approver |
| `00-kueue-operator.yaml` | kueue Namespace/OperatorGroup/Subscription + approver RBAC + blocking InstallPlan approver |
| `10-rhods-operator.yaml` | rhods-operator Namespace/Subscription (no OperatorGroup) + approver RBAC + blocking approver |
| `20-rhoai-config.yaml` | `patch-datasciencecluster` ClusterRole/Binding + ConfigMap + patch hook Job |
| `20-storage-seaweedfs.yaml` | SeaweedFS Namespace/PVC/Secret/ConfigMap/Deployment/Service/Routes + credential-copy hook Job |
| `20-storage-postgres.yaml` | Postgres Role/Secret/PVC/Service/Deployment + DB credential hook Job |
| `20-wait-for-crds.yaml` | wave-3 hook that waits for the DSPA/MLflow/EvalHub/TrustyAI CRDs |
| `30-dspa.yaml` | DSPA v1 |
| `40-mlflow.yaml` | MLflow v1 + S3 read/create RBAC + `mlflow-s3-credentials` hook Job |
| `50-evalhub.yaml` | TrustyAIService v1, EvalHub v1, NetworkPolicy, S3-read Role/Binding |

Sync waves match `overlays/rhdp`: namespaces/OperatorGroups/Subscriptions and their
InstallPlan approvers `0`, ConfigMaps/RBAC `1`, DSC patch + credential Jobs `2`,
the `wait-for-rhoai-crds` gate and workloads/PVCs `3`, DSPA `4`, MLflow `5`,
EvalHub/TrustyAI `6`.

### Argo CD validation on a fresh cluster

Argo validates the whole application before applying anything. On a fresh cluster the
DSPA/MLflow/EvalHub/TrustyAI CRDs do not exist yet, and Argo rejects the entire sync
with `failed to discover server resources for group version ...` — even the operator
install never runs. The chart handles this without needing app-level sync options:

- the four CRs carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`,
- `wait-for-rhoai-crds` (Sync hook, wave 3) blocks the CR waves until the DSC patch has
  caused the operator to register all four CRDs, failing non-zero after
  `crds.waitTimeoutSeconds` (default 900).

### RHDP bases

RHDP catalog items pass `bases.rhoai: true` in `source.helm.values` and install
cert-manager + RHOAI before the Application. The chart detects that and skips its own
cert-manager/kueue/rhods Subscriptions automatically. When no `bases` block is present,
`operators.*.enabled` controls them explicitly.

> The approvers sit in wave `0` (not `1` as in the Kustomize overlay) on purpose:
> Argo CD's `Subscription` health check reports `Progressing` while a `Manual`
> InstallPlan is unapproved, so an approver in a later wave would never run. Each
> approver also carries its own Role/Binding (`installplans` patch, `subscriptions`
> read) and polls for up to `operators.approvalTimeoutSeconds` (default 900), failing
> non-zero on timeout — the old 5×5 s loop exited 0 even when it found nothing, which
> left wave 0 permanently Progressing.

## Use from RHDP / Argo CD

Set the catalog item's GitOps path to `charts/ai-safety-demo` (revision = the branch
carrying this chart). Argo CD will render with `source.helm` and the chart defaults.
An example Application is in [`examples/argocd-application.yaml`](examples/argocd-application.yaml).

```bash
# Render and server-side dry-run before pointing RHDP at it:
helm template ai-safety-demo charts/ai-safety-demo \
  | oc apply --dry-run=server -f -
```

## Values

Defaults are the proven V1.1 values; override only what you need, e.g.:

```bash
helm template ai-safety-demo charts/ai-safety-demo \
  --set seaweedfs.storage=50Gi \
  --set seaweedfs.bucket=evalhub-prod \
  --set postgres.password="$(openssl rand -base64 16)"
```

Common knobs:

- `operators.*` — namespaces, channels and pinned CSVs (`stable-3.5`, `rhods-operator.3.5.3`).
- `operators.rhoai.enabled` — set `false` when RHOAI is already installed; skips the
  Namespace/Subscription/approver, the DSC patch Job still runs.
- `crds.waitTimeoutSeconds` — how long the CRD wait gate polls before failing (default 900).
- `operators.approvalTimeoutSeconds` — how long each InstallPlan approver polls (default 900).
- `rhoai.dsc.components.*` — component management states merged into `DataScienceCluster`.
- `rhoai.dashboard.*` — `disableLMEval` / `externalModels` flags.
- `seaweedfs.image|storage|bucket|region|credentials.*` — object storage.
- `postgres.image|storage|database|user|password` — EvalHub database.
- `mlflow.storage` — MLflow PVC size.
- `evalhub.providers|collections|tenancy|replicas|trustyaiservice.storageSize`.
- `syncWaves.*` — Argo CD ordering.

## Secrets deliberately not templated

`redteam-api-keys` (8 keys: `api-key`, `TARGET_API_KEY`, `JUDGE_API_KEY`,
`EVALUATOR_API_KEY`, `SDG_API_KEY`, `ATTACKER_API_KEY`, `k8s_url`, `k8s_sa_token`)
must be created out-of-band in the `evalhub` namespace — never commit it:

```bash
oc create secret generic redteam-api-keys -n evalhub \
  --from-literal=api-key="<TARGET_TOKEN>" \
  --from-literal=TARGET_API_KEY="<TARGET_TOKEN>" \
  --from-literal=JUDGE_API_KEY="<TARGET_TOKEN>" \
  --from-literal=EVALUATOR_API_KEY="<TARGET_TOKEN>" \
  --from-literal=SDG_API_KEY="<ABLITERATED_TOKEN>" \
  --from-literal=ATTACKER_API_KEY="<ABLITERATED_TOKEN>" \
  --from-literal=k8s_url="https://api.<cluster>:6443" \
  --from-literal=k8s_sa_token="" \
  --dry-run=client -o yaml | oc apply -f -
```

## Differences from the Kustomize overlay

- **InstallPlan approval is fixed for Argo.** The approvers poll for the Subscription /
  InstallPlan for up to 15 minutes, exit non-zero on timeout, and have the RBAC
  (`installplans` patch) the Kustomize manifests never granted. Without this, wave 0
  never becomes healthy on a fresh cluster and no RHOAI resource is ever applied.
- **MLflow credential copy has RBAC** (`read-seaweedfs-credentials` in `seaweedfs`,
  `create-mlflow-s3-credentials` in `redhat-ods-applications`); the Kustomize manifest
  relied on permissions that were never declared.
- **All command-running Jobs are `Sync` hooks with `hook-delete-policy: HookSucceeded`**
  (not plain Jobs / `PreSync` hooks). Hooks are deleted on success and re-run on the
  next sync, so changed values propagate and `Job.spec.template` immutability never
  fails an upgrade; `PreSync` would run before the Secrets they read exist.
- **Credential copies read the source Secret with `oc get -o jsonpath` + `base64 -d`**
  instead of pasting values into shell arguments (`ose-cli` does not ship `jq`); no
  quoting/injection hazard and all 5 AWS keys stay in sync.
- `AWS_DEFAULT_REGION` in `mlflow-s3-credentials` is properly base64-encoded
  (`dXMtZWFzdC0x`); the Kustomize manifest wrote the literal `us-east-1` into `.data`.
- `overlays/rhdp` stays Kustomize, unchanged, for `oc apply -k` parity.

> `helm template ... | oc apply --dry-run=server -f -` only works once the RHOAI CRDs
> exist. On a truly fresh cluster it reports `resource mapping not found` for
> DSPA/MLflow/EvalHub/TrustyAI; use it as an upgrade check, or expect those errors on
> the first `oc apply` pass.
