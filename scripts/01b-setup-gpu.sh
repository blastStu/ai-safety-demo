#!/usr/bin/env bash
# Phase 1b — GPU setup: NFD + NVIDIA GPU Operator (only if GPU pool exists).
# Run after 01-apply-prereqs.sh (needs cert-manager/kueue not strictly, but they share the
# same operator-install pattern) and before 02-enable-dsc.sh (RHOAI can install without GPU,
# but KServe will later need the GPU resource).
#
# Prerequisites:
#   - Cluster has at least one GPU-capable node (rosa create machinepool --instance-type g6.2xlarge
#     or the RHDP cluster spec already includes a GPU worker pool).
#   - oc is logged in as cluster-admin.
#   - Follows rosa-cluster-skill Step 6 (NFD channel/CSV derived live, PCI labelSources fix,
#     GPU-taint tolerations, OwnNamespace OperatorGroups, Manual InstallPlan approval).
set -euo pipefail

echo "=== GPU availability gate ==="
GPU_NODES=$(oc get nodes -o json | jq -r '.items[].metadata.labels["node.kubernetes.io/instance-type"]' | grep -Ec '^(g|p)[0-9]' || echo 0)
echo "GPU-capable nodes: $GPU_NODES"
if [ "$GPU_NODES" -eq 0 ]; then
  echo "No GPU-capable nodes found — skipping NFD/GPU Operator install."
  echo "RHOAI will install without GPU. Re-run after adding a GPU machine pool:"
  echo "  rosa create machinepool --cluster <name> --name g6-2xlarge --instance-type g6.2xlarge --replicas 1 --taints nvidia.com/gpu=true:NoSchedule"
  exit 0
fi
oc get nodes -o json | jq -r '.items[] | select(.metadata.labels["node.kubernetes.io/instance-type"] | test("^(g|p)[0-9]")) | "  \(.metadata.name) \(.metadata.labels["node.kubernetes.io/instance-type"])"'
echo

approve_pending() {
  local ns=$1
  for attempt in 1 2 3 4 5 6; do
    local pending
    pending=$(oc get installplan -n "$ns" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
    if [ -n "$pending" ]; then
      for ip in $pending; do
        echo "Approving InstallPlan $ip in $ns..."
        oc patch installplan "$ip" -n "$ns" --type merge -p '{"spec":{"approved":true}}'
      done
      return 0
    fi
    sleep 5
  done
  echo "No InstallPlan appeared in $ns after polling — check: oc get subscription -n $ns -o yaml" >&2
}

# ── NFD ──
echo "=== NFD (Node Feature Discovery) ==="
NFD_CHANNEL=$(oc get packagemanifest nfd -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
NFD_CSV=$(oc get packagemanifest nfd -n openshift-marketplace -o json | jq -r --arg c "$NFD_CHANNEL" '.status.channels[] | select(.name==$c) | .currentCSV')
echo "NFD: channel=$NFD_CHANNEL csv=$NFD_CSV"

oc create namespace openshift-nfd 2>/dev/null || true
oc label namespace openshift-nfd openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operatorgroup
  namespace: openshift-nfd
spec:
  targetNamespaces: [openshift-nfd]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: ${NFD_CHANNEL}
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: ${NFD_CSV}
EOF

approve_pending openshift-nfd
echo "Waiting for NFD CSV Succeeded..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n openshift-nfd csv "$NFD_CSV" 2>/dev/null || true

echo "Creating NodeFeatureDiscovery CR (labelSources: all, GPU taint toleration)..."
cat <<'NFDEOF' | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    workerTolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
  workerConfig:
    configData: |
      core:
        labelSources: ["all"]
NFDEOF

# Config is read at startup — restart worker so it picks up labelSources
sleep 5
oc rollout restart ds/nfd-worker -n openshift-nfd 2>/dev/null || echo "nfd-worker not yet scheduled, will appear shortly"
oc rollout status ds/nfd-worker -n openshift-nfd --timeout=180s 2>/dev/null || true

echo "NFD worker labels (pci*):"
sleep 5
oc get nodes -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.name): \(.metadata.labels | keys | map(select(test("pci"))) | join(", "))"' 2>/dev/null || true
echo

# ── NVIDIA GPU Operator ──
echo "=== NVIDIA GPU Operator ==="
GPU_CHANNEL=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
GPU_CSV=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o json | jq -r --arg c "$GPU_CHANNEL" '.status.channels[] | select(.name==$c) | .currentCSV')
echo "GPU Operator: channel=$GPU_CHANNEL csv=$GPU_CSV"

oc create namespace nvidia-gpu-operator 2>/dev/null || true
oc label namespace nvidia-gpu-operator openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces: [nvidia-gpu-operator]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${GPU_CHANNEL}
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: ${GPU_CSV}
EOF

# InstallPlan appears asynchronously — poll
echo "Waiting for GPU Operator InstallPlan..."
for i in $(seq 1 30); do
  PLAN=$(oc get installplan -n nvidia-gpu-operator -o name 2>/dev/null | head -1 || true)
  if [ -n "$PLAN" ]; then break; fi
  sleep 5
done
if [ -n "${PLAN:-}" ]; then
  echo "Approving $PLAN"
  oc patch "$PLAN" -n nvidia-gpu-operator --type merge -p '{"spec":{"approved":true}}'
else
  echo "No InstallPlan appeared — check subscription: oc get subscription gpu-operator-certified -n nvidia-gpu-operator -o yaml" >&2
fi

echo "Waiting for GPU Operator CSV Succeeded..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n nvidia-gpu-operator csv "$GPU_CSV" 2>/dev/null || true

echo "Creating ClusterPolicy from CSV alm-examples..."
oc get csv -n nvidia-gpu-operator "$GPU_CSV" -o jsonpath='{.metadata.annotations.alm-examples}' 2>/dev/null \
  | jq -r 'map(select(.kind=="ClusterPolicy"))[0]' | oc apply -f - 2>/dev/null \
  || echo "ClusterPolicy creation skipped (CSV annotation not yet available, will reconcile)"

echo "Patching gpu-operator manager to tolerate GPU taint..."
sleep 5
oc patch deployment gpu-operator -n nvidia-gpu-operator --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[]}]' 2>/dev/null || true
oc patch deployment gpu-operator -n nvidia-gpu-operator --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}}]' 2>/dev/null \
  || echo "gpu-operator toleration already present or deployment not yet ready"

echo
echo "=== GPU gates ==="
oc get csv -n openshift-nfd 2>/dev/null | head -5
oc get csv -n nvidia-gpu-operator 2>/dev/null | head -5
oc get clusterpolicy -o jsonpath='{.items[0].status.state}{"\n"}' 2>/dev/null || echo "ClusterPolicy not yet reconciled"
oc get nodes -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.name): nvidia.com/gpu=\(.status.allocatable["nvidia.com/gpu"] // "none")"' 2>/dev/null || true
echo
echo "Driver rollout can take several minutes. If nvidia.com/gpu never becomes allocatable, check:"
echo "  oc get pods -n nvidia-gpu-operator"
echo "  oc logs -n nvidia-gpu-operator ds/nvidia-driver-daemonset  # or nvidia-operator-validator"
