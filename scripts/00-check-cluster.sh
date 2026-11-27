#!/usr/bin/env bash
# Phase 0 — baseline gates (read-only). Run before any manifest touches the cluster.
# Validates on a bare OpenShift cluster (RHDP-provisioned: no RHOAI yet).
set -euo pipefail

echo "=== oc whoami ==="
oc whoami
echo

echo "=== Cluster info ==="
oc get nodes -o wide
echo
oc version --short 2>/dev/null || oc version 2>/dev/null | head -5
echo

echo "=== RHOAI operator (expect NOT found on bare cluster) ==="
oc get csv -n redhat-ods-operator 2>/dev/null | head -5 || echo "No CSVs in redhat-ods-operator yet (expected on bare cluster)"
oc get datasciencecluster default-dsc 2>/dev/null -o jsonpath='{.status.phase}{"\n"}' || echo "No DataScienceCluster yet (expected before RHOAI install)"
echo

echo "=== Packagemanifest channels (derive, don't hardcode) ==="
for pkg in openshift-cert-manager-operator kueue-operator rhods-operator nfd gpu-operator-certified; do
  echo "--- $pkg ---"
  oc get packagemanifest "$pkg" -n openshift-marketplace -o json 2>/dev/null | jq -r --arg p "$pkg" '"  defaultChannel: \(.status.defaultChannel) | \(.status.defaultChannel as $d | .status.channels[] | select(.name==$d) | "  channel=\(.name) CSV=\(.currentCSV)" )"' 2>/dev/null || echo "  not found (optional: nfd/gpu-operator-certified only on GPU clusters)"
done
echo

echo "=== GPU nodes ==="
oc get nodes -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.name) \(.metadata.labels["node.kubernetes.io/instance-type"] // "unknown") \(.metadata.labels["nvidia.com/gpu.present"] // "-")"' 2>/dev/null || true
GPU_NODES=$(oc get nodes -o json 2>/dev/null | jq -r '.items[].metadata.labels["node.kubernetes.io/instance-type"]' 2>/dev/null | grep -Ec '^(g|p)[0-9]' || echo 0)
echo "GPU-capable nodes: $GPU_NODES"
if [ "$GPU_NODES" -gt 0 ]; then
  echo "GPU nodes allocatable:"
  oc get nodes -o json 2>/dev/null | jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | "\(.metadata.name): nvidia.com/gpu=\(.status.allocatable["nvidia.com/gpu"])"' 2>/dev/null || true
fi
echo

echo "=== CRDs present (trustyai/eval) ==="
oc get crd 2>/dev/null | grep -iE "dspa|mlflow|evalhub|trustyai" || echo "no eval/mlflow CRDs yet (expected before RHOAI install)"
echo
echo "Phase 0 gates complete"
