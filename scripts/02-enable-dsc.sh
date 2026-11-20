#!/usr/bin/env bash
# Phase 2 — flip DSC to V1.1 target set
set -euo pipefail

echo "Current DSC phase: $(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}')"
echo "Patching default-dsc from manifests/10-rhoai/dsc-patch.yaml..."
oc patch datasciencecluster default-dsc --type=merge --patch-file manifests/10-rhoai/dsc-patch.yaml
echo "Waiting for Ready (can take a few minutes)..."
oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=600s || true
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
echo

echo "Checking webhook NOT SET reset (3.5 EA2 bug)..."
oc get datasciencecluster default-dsc -o json | jq '.spec.components | to_entries[] | select(.value.managementState == null or .value.managementState == "Removed") | "\(.key): \(.value.managementState // "NOT SET")"' | head -n 20
echo "If aipipelines/mlflowoperator show NOT SET but should be Managed, re-run:"
echo "  oc patch datasciencecluster default-dsc --type=merge -p '{\"spec\":{\"components\":{\"aipipelines\":{\"managementState\":\"Managed\"},\"mlflowoperator\":{\"managementState\":\"Managed\"}}}}'"
echo

echo "Gates:"
oc get csv -A --no-headers | grep -v Succeeded || echo "all CSVs Succeeded ✓"
oc get pods -n redhat-ods-operator 2>/dev/null | head -n 20
