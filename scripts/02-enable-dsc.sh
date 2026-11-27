#!/usr/bin/env bash
# Phase 2 — install RHOAI 3.6 EA2 (beta channel) + flip DSC to demo target set
# On a bare RHDP cluster there is no RHOAI yet; this installs it from the beta channel
# then patches the DSC/dashboard. On a cluster with RHOAI already, it just patches.
set -euo pipefail

echo "=== RHOAI operator install (beta / 3.6.0-ea.2) ==="
if oc get csv -n redhat-ods-operator rhods-operator.3.6.0-ea.2 2>/dev/null | grep -q Succeeded; then
  echo "rhods-operator.3.6.0-ea.2 already Succeeded — skipping install"
else
  echo "Installing rhods-operator from beta channel..."
  oc apply -k manifests/10-rhoai/rhods-operator
  # Approve Manual InstallPlan (OLM creates it asynchronously)
  for attempt in 1 2 3 4 5 6; do
    pending=$(oc get installplan -n redhat-ods-operator -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
    if [ -n "$pending" ]; then
      for ip in $pending; do
        echo "Approving InstallPlan $ip in redhat-ods-operator..."
        oc patch installplan "$ip" -n redhat-ods-operator --type merge -p '{"spec":{"approved":true}}'
      done
      break
    fi
    echo "No InstallPlan yet (attempt $attempt/6) — waiting for OLM..."
    sleep 5
  done
  echo "Waiting for rhods-operator CSV Succeeded (up to 5 min)..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s -n redhat-ods-operator csv rhods-operator.3.6.0-ea.2 2>/dev/null \
    || echo "Check: oc get csv -n redhat-ods-operator"
fi
echo

echo "Waiting for DataScienceCluster and DashboardConfig to be created by the operator..."
for i in $(seq 1 60); do
  oc get datasciencecluster default-dsc >/dev/null 2>&1 && break
  echo "Waiting for default-dsc to be created (attempt $i/60)..."
  sleep 5
done
for i in $(seq 1 60); do
  oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1 && break
  echo "Waiting for odh-dashboard-config to be created (attempt $i/60)..."
  sleep 5
done

echo "Current DSC phase: $(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo 'not found')"
echo "Patching default-dsc from manifests/10-rhoai/dsc-patch.yaml..."
oc patch datasciencecluster default-dsc --type=merge --patch-file manifests/10-rhoai/dsc-patch.yaml
echo "Patching OdhDashboardConfig (modelCapabilities + externalModels)..."
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge --patch-file manifests/10-rhoai/odhdashboardconfig-patch.yaml
echo "Waiting for DSC Ready (can take a few minutes)..."
oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=600s || true
oc get datasciencecluster default-dsc -o jsonpath='DSC phase: {.status.phase}{"\n"}'
echo

echo "Checking DSC components (Managed vs Removed vs NOT SET)..."
oc get datasciencecluster default-dsc -o json | jq '.spec.components | to_entries[] | "\(.key): \(.value.managementState // "NOT SET")"'
echo "If aipipelines/mlflowoperator show NOT SET but should be Managed, re-run:"
echo "  oc patch datasciencecluster default-dsc --type=merge -p '{\"spec\":{\"components\":{\"aipipelines\":{\"managementState\":\"Managed\"},\"mlflowoperator\":{\"managementState\":\"Managed\"}}}}'"
echo

echo "Gates:"
oc get csv -A --no-headers 2>/dev/null | grep -v Succeeded || echo "all CSVs Succeeded ✓"
oc get pods -n redhat-ods-operator 2>/dev/null | head -n 20
echo
echo "Module operators (3.6+ Platform Orchestrator — appear automatically, do NOT install by hand):"
oc get pods -n redhat-ods-applications 2>/dev/null | grep -Ei 'kserve|ray|trustyai|observab|ogx' || echo "  (none yet — appear after DSC reconciles)"
