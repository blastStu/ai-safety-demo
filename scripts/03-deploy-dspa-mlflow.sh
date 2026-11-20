#!/usr/bin/env bash
# Phase 3 + 4 — MinIO, EvalHub Postgres, DSPA, then MLflow (MLflow must be Ready before EvalHub)
set -euo pipefail

echo "=== Object storage (S3 for pipelines and experiments) ==="
oc apply -k manifests/20-dspa/seaweedfs
oc wait --for=condition=Available deployment/seaweedfs -n seaweedfs --timeout=300s
oc get route seaweedfs-s3 -n seaweedfs -o jsonpath='SeaweedFS S3: https://{.spec.host}{"\n"}'
echo

echo "=== EvalHub namespace (needed for Postgres + DSPA) ==="
# evalhub is the platform namespace (not a tenant) — create without tenant label; EvalHub CR is tenancy: single
oc create namespace evalhub 2>/dev/null || true
# Do NOT label with evalhub.trustyai.opendatahub.io/tenant — that marks a tenant project, not the platform ns
oc label namespace evalhub evalhub.trustyai.opendatahub.io/tenant- 2>/dev/null || true
echo

echo "=== EvalHub Postgres (DeploymentConfig) ==="
# Idempotent: only create if dc/postgresql doesn't already exist
if oc get deploymentconfig postgresql -n evalhub >/dev/null 2>&1; then
  echo "dc/postgresql already exists — skipping oc new-app"
else
  oc new-app --template=openshift/postgresql-persistent -n evalhub \
    -p POSTGRESQL_USER=evalhub -p POSTGRESQL_PASSWORD="$(openssl rand -base64 12)" \
    -p POSTGRESQL_DATABASE=evalhub -p VOLUME_CAPACITY=5Gi 2>&1 | tail -n 5
fi
echo "Waiting for dc/postgresql..."
oc rollout status dc/postgresql -n evalhub --timeout=300s || true

# Create the Secret EvalHub actually mounts (evalhub-db-credentials) from the DB password that oc new-app stored in the postgresql Secret
# This is idempotent — re-applying is safe
DB_PASS=$(oc get secret postgresql -n evalhub -o jsonpath='{.data.database-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -n "$DB_PASS" ]; then
  oc create secret generic evalhub-db-credentials -n evalhub \
    --from-literal=db-url="postgres://evalhub:${DB_PASS}@postgresql.evalhub.svc.cluster.local:5432/evalhub" \
    --from-literal=database-password="${DB_PASS}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
  echo "Created evalhub-db-credentials from postgresql secret"
else
  echo "WARN: could not read postgresql secret yet — EvalHub may show FailedMount until next run"
fi
echo

echo "=== DSPA (update route host first!) ==="
echo "NOTE: edit manifests/20-dspa/dspa/dspa.yaml host to match: $(oc get route seaweedfs-s3 -n seaweedfs -o jsonpath='{.spec.host}')"
# Ensure evalhub ns exists (platform ns, not a tenant — no tenant label)
oc create namespace evalhub 2>/dev/null || true
oc label namespace evalhub evalhub.trustyai.opendatahub.io/tenant- 2>/dev/null || true
# Object storage credentials for the evaluation pipelines
oc create secret generic seaweedfs-evalhub-credentials -n evalhub \
  --from-literal=AWS_ACCESS_KEY_ID=THEACCESSKEY --from-literal=AWS_SECRET_ACCESS_KEY=THESECRETKEY \
  --from-literal=AWS_S3_ENDPOINT=http://seaweedfs.seaweedfs.svc:8333 --from-literal=AWS_S3_BUCKET=evalhub --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
oc apply -k manifests/20-dspa/dspa
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True dspa/dspa -n evalhub --timeout=300s 2>/dev/null || \
  echo "Poll: oc get dspa dspa -n evalhub -o jsonpath='{.status.conditions}'"
echo

echo "=== MLflow ==="
oc apply -k manifests/30-mlflow
# Wait for MLflow to become Ready (v1 uses Available: True DeploymentReady, not Ready: True)
echo "Waiting for MLflow Ready..."
for i in $(seq 1 30); do
  available=$(oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [ "$available" = "True" ]; then echo "MLflow Available: True — Ready"; break; fi
  sleep 10
done
oc get mlflow mlflow -n redhat-ods-applications 2>/dev/null || echo "mlflow CR not yet reconciled"
oc get pods -n redhat-ods-applications | grep -i mlflow
oc get pvc -n redhat-ods-applications | grep mlflow || true
echo "Dashboard proxy: https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')/mlflow"
