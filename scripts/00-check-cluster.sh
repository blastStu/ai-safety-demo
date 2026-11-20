#!/usr/bin/env bash
# Phase 0 — baseline gates (read-only). Run before any manifest touches the cluster.
set -euo pipefail

echo "=== oc whoami ==="
oc whoami
echo

echo "=== DSC phase (should be Ready) ==="
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" Ready since "}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}'
echo

echo "=== DSC spec.components (Managed vs Removed) ==="
oc get datasciencecluster default-dsc -o json | jq '.spec.components | to_entries[] | "\(.key): \(.value.managementState // "NOT SET")"'
echo

echo "=== CSVs (all should be Succeeded) ==="
oc get csv -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.phase}{"\n"}{end}' | sort
if oc get csv -A -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -qv Succeeded; then echo "FAIL: some CSVs not Succeeded"; exit 1; fi
echo "all CSVs Succeeded ✓"
echo

echo "=== Nodes ==="
oc get nodes -o wide
echo

echo "=== Packagemanifest channels (derive, don't hardcode) ==="
for pkg in openshift-cert-manager-operator kueue-operator rhods-operator; do
  echo "--- $pkg ---"
  oc get packagemanifest "$pkg" -n openshift-marketplace -o json | jq -r --arg p "$pkg" '"  defaultChannel: \(.status.defaultChannel) | \(.status.defaultChannel as $d | .status.channels[] | select(.name==$d) | "  channel=\(.name) CSV=\(.currentCSV)" )"'
done
echo

echo "=== Routes (dashboard) ==="
oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='https://{.spec.host}{"\n"}' 2>/dev/null || echo "dashboard route not found"
echo

echo "=== CRDs present (trustyai/eval) ==="
oc get crd | grep -iE "dspa|mlflow|evalhub|trustyai" || echo "no eval/mlflow CRDs yet (expected before DSC flip)"
echo
echo "Phase 0 gates complete — record values in docs/decisions.md"
