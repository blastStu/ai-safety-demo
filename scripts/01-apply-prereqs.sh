#!/usr/bin/env bash
# Phase 1 — cert-manager + kueue-operator (derive live, then pin)
set -euo pipefail

derive() {
  local pkg=$1
  local ch csv
  ch=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  csv=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o json | jq -r --arg c "$ch" '.status.channels[] | select(.name==$c) | .currentCSV')
  echo "DERIVED $pkg: channel=$ch csv=$csv"
  echo "  → update manifests/00-prereqs/$2/subscription.yaml with these values before apply"
}

echo "Deriving live channels (do not hardcode):"
derive openshift-cert-manager-operator cert-manager
derive kueue-operator kueue-operator
echo

approve_pending() {
  local ns=$1
  # Manual InstallPlans block until approved — approve any that are Manual/false, with a short poll for OLM to create the InstallPlan
  for attempt in 1 2 3 4 5; do
    local pending=""
    pending=$(oc get installplan -n "$ns" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{" "}{end}' 2>/dev/null)
    if [ -n "$pending" ]; then
      for ip in $pending; do
        echo "Approving InstallPlan $ip in $ns (Manual)..."
        oc patch installplan "$ip" -n "$ns" --type merge -p '{"spec":{"approved":true}}'
      done
      return 0
    fi
    # No InstallPlan yet — OLM may still be reconciling the Subscription channel switch
    sleep 3
  done
}

echo "Apply cert-manager:"
oc apply -k manifests/00-prereqs/cert-manager
approve_pending openshift-cert-manager
# CSVs signal phase, not condition Available — wait on phase
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n openshift-cert-manager csv --all 2>/dev/null || true
sleep 2
approve_pending openshift-cert-manager
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n openshift-cert-manager csv --all 2>/dev/null || echo "check: oc get csv -n openshift-cert-manager"
echo

echo "Apply kueue-operator:"
oc apply -k manifests/00-prereqs/kueue-operator
approve_pending kueue-system
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n kueue-system csv --all 2>/dev/null || true
sleep 2
approve_pending kueue-system
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n kueue-system csv --all 2>/dev/null || echo "check: oc get csv -n kueue-system"
echo

echo "Gates:"
oc get csv -n openshift-cert-manager
oc get csv -n kueue-system
oc get crd certificates.cert-manager.io 2>/dev/null && echo "cert-manager CRD present ✓" || echo "cert-manager CRD missing"
