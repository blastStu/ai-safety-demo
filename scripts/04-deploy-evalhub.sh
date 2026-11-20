#!/usr/bin/env bash
# Phase 5 — deploy EvalHub garak-kfp (the service the Evaluations UI asks for)
# Must run after: DSC Ready (trustyai: Managed + kserve: Managed), SeaweedFS Available, Postgres RolledOut, DSPA Ready, MLflow Available
set -euo pipefail

echo "=== EvalHub (garak-kfp) — TrustyAIService + EvalHub CR ==="
# evalhub is the platform ns (not a tenant) — ensure it exists without tenant label; EvalHub CR is tenancy: single
oc create namespace evalhub 2>/dev/null || true
oc label namespace evalhub evalhub.trustyai.opendatahub.io/tenant- >/dev/null 2>&1 || true

# The SeaweedFS → evalhub credentials copy — 5 AWS_* keys required by garak-kfp pipeline steps (idempotent — already created in 03, but keep it here for fresh-cluster runs)
oc create secret generic seaweedfs-evalhub-credentials -n evalhub \
  --from-literal=AWS_ACCESS_KEY_ID=THEACCESSKEY --from-literal=AWS_SECRET_ACCESS_KEY=THESECRETKEY \
  --from-literal=AWS_S3_ENDPOINT=http://seaweedfs.seaweedfs.svc:8333 --from-literal=AWS_S3_BUCKET=evalhub --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true

oc apply -k manifests/40-garak

# Ensure evalhub-db-credentials exists (created in 03, but re-create for fresh runs where 03 was skipped)
DB_PASS=$(oc get secret postgresql -n evalhub -o jsonpath='{.data.database-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -n "$DB_PASS" ]; then
  oc create secret generic evalhub-db-credentials -n evalhub \
    --from-literal=db-url="postgres://evalhub:${DB_PASS}@postgresql.evalhub.svc.cluster.local:5432/evalhub" \
    --from-literal=database-password="${DB_PASS}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
fi

echo "Waiting for TrustyAIService Available..."
for i in $(seq 1 30); do
  st=$(oc get trustyaiservice trustyai-service -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  [ "$st" = "True" ] && { echo "TrustyAIService Available: True"; break; }
  sleep 10
done

echo "Waiting for EvalHub Ready..."
for i in $(seq 1 30); do
  # v1 uses Ready: True when deployment is Available; fall back to Available
  st=$(oc get evalhub evalhub -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  av=$(oc get evalhub evalhub -n evalhub -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [ "$st" = "True" ] || [ "$av" = "True" ]; then echo "EvalHub Ready: True ($st/$av)"; break; fi
  sleep 10
done

# External endpoint secrets are NOT in git — create them imperatively with your supplied values before triggering:
#   oc create secret generic target-model-credentials -n evalhub --from-literal=baseUrl="$TARGET_BASE_URL" --from-literal=apiKey="$TARGET_API_KEY"
#   oc create secret generic abliterated-model-credentials -n evalhub --from-literal=baseUrl="$ABLITERATED_BASE_URL" --from-literal=apiKey="$ABLITERATED_API_KEY"
# Then: ./scripts/05-run-garak.sh  or  Dashboard → Develop & train → Evaluations → Start evaluation → garak-kfp

oc get pods -n evalhub -o wide || true
oc get evalhub evalhub -n evalhub -o jsonpath='EvalHub: {.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}' 2>/dev/null || true
oc get trustyaiservice trustyai-service -n evalhub -o jsonpath='TrustyAIService: {.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null || true
echo "Dashboard: https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null)/evaluation/evalhub"
