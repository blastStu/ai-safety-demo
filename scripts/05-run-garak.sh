#!/usr/bin/env bash
# Run the Garak intents benchmark via EvalHub (SDG → Baseline → SPO → TAP) and upload results to MLflow.
# Prereqs: 00-04 green, and redteam-api-keys in evalhub (see README.md "Secrets" and benchmarks/intents-garak-kfp.json).

set -euo pipefail

# --- 1. Resolve endpoints (override via env for your cluster) ---
# EVALHUB is the EvalHub route; MODEL_URL/RED_URL are your external OpenAI-compatible model endpoints.
if [ -z "${EVALHUB:-}" ]; then
  EVALHUB_HOST=$(oc get route evalhub -n evalhub -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$EVALHUB_HOST" ]; then
    EVALHUB="https://${EVALHUB_HOST}"
  else
    echo "Set EVALHUB to your EvalHub route, e.g. EVALHUB=https://evalhub-evalhub.apps.<your-cluster>/ (oc get route evalhub -n evalhub)"
    exit 1
  fi
fi

# Default to placeholder model URLs — override with YOUR_MODEL_URL / YOUR_ABLITERATED_MODEL_URL for a real run.
MODEL_URL="${MODEL_URL:-${YOUR_MODEL_URL:-https://YOUR_TARGET_MODEL/v1}}"
MODEL_NAME="${MODEL_NAME:-YOUR_TARGET_MODEL_NAME}"
RED_URL="${RED_URL:-${YOUR_ABLITERATED_MODEL_URL:-https://YOUR_ABLITERATED_MODEL/v1}}"
RED_NAME="${RED_NAME:-YOUR_ABLITERATED_MODEL_NAME}"
SDG_NAME="${SDG_NAME:-hosted_vllm/$RED_NAME}"
TOK=$(oc whoami -t)
H=(-H "Authorization: Bearer $TOK" -H "X-Tenant: evalhub")

# --- 2. Ensure the pipeline can reach its storage ---
# NetworkPolicy allowing the evaluation job pods to talk to the pipeline server on port 8888.
oc apply -f - <<'EOF' >/dev/null 2>&1 || true
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-evalhub-jobs-to-dspa-apiserver, namespace: evalhub}
spec:
  podSelector: {matchLabels: {app: ds-pipeline-dspa, component: data-science-pipelines}}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {matchLabels: {app: evalhub, component: evaluation-job}}}], ports: [{protocol: TCP, port: 8888}]}]
EOF

# Allow the job pod to fetch results from object storage via the in-cluster API.
K8S_API=$(oc whoami --show-server 2>/dev/null || echo "https://kubernetes.default.svc")
oc patch secret redteam-api-keys -n evalhub --type merge -p "{\"stringData\":{\"k8s_url\":\"$K8S_API\",\"k8s_sa_token\":\"\"}}" >/dev/null 2>&1 || echo "  (redteam-api-keys not yet present — create it per README.md Secrets)"

oc apply -f - <<'EOF' >/dev/null 2>&1 || true
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: evalhub-job-read-s3-credentials, namespace: evalhub}
rules: [{apiGroups: [""], resources: ["secrets"], resourceNames: ["seaweedfs-evalhub-credentials"], verbs: ["get"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: evalhub-job-read-s3-credentials, namespace: evalhub}
subjects: [{kind: ServiceAccount, name: evalhub-evalhub-job, namespace: evalhub}]
roleRef: {kind: Role, name: evalhub-job-read-s3-credentials, apiGroup: rbac.authorization.k8s.io}
EOF

# --- 3. Verify external models reachable ---
echo "=== Verify external models ==="
if oc get secret redteam-api-keys -n evalhub >/dev/null 2>&1; then
  KEY=$(oc get secret redteam-api-keys -n evalhub -o jsonpath='{.data.TARGET_API_KEY}' | base64 -d)
  curl -sk -o /dev/null -w '  target/judge: %{http_code}' -H "Authorization: Bearer $KEY" "$MODEL_URL/models" 2>&1 | xargs echo; echo
  KEY=$(oc get secret redteam-api-keys -n evalhub -o jsonpath='{.data.SDG_API_KEY}' | base64 -d)
  curl -sk -o /dev/null -w '  sdg/attacker: %{http_code}' -H "Authorization: Bearer $KEY" "$RED_URL/models" 2>&1 | xargs echo; echo
  unset KEY
else
  echo "  redteam-api-keys not found — create it first per README.md Secrets. Example:"
  echo "    oc create secret generic redteam-api-keys -n evalhub --from-literal=api-key=\"\$TOKEN\" --from-literal=TARGET_API_KEY=\"\$TOKEN\" --from-literal=SDG_API_KEY=\"\$ABL_TOKEN\" ..."
fi

# --- 4. Submit the assessment ---
echo "=== Submit garak-kfp intents ==="
RESP=$(curl -sk "${H[@]}" -H 'Content-Type: application/json' -X POST "$EVALHUB/api/v1/evaluations/jobs" -d @- <<EOF
{
  "name": "ai-safety-baseline-$(date +%m%d)",
  "model": { "url": "$MODEL_URL", "name": "$MODEL_NAME", "auth": { "secret_ref": "redteam-api-keys" } },
  "benchmarks": [{
    "id": "intents", "provider_id": "garak-kfp",
    "parameters": {
      "kfp_config": {
        "endpoint": "https://ds-pipeline-dspa.evalhub.svc.cluster.local:8888",
        "namespace": "evalhub",
        "s3_secret_name": "seaweedfs-evalhub-credentials",
        "s3_endpoint": "http://seaweedfs.seaweedfs.svc:8333",
        "s3_bucket": "evalhub",
        "verify_ssl": false
      },
      "intents_models": {
        "judge":     { "url": "$MODEL_URL", "name": "$MODEL_NAME" },
        "sdg":       { "url": "$RED_URL",   "name": "$SDG_NAME" },
        "attacker":  { "url": "$RED_URL",   "name": "$RED_NAME" },
        "evaluator": { "url": "$MODEL_URL", "name": "$MODEL_NAME" }
      },
      "sdg_max_concurrency": 1
    }
  }],
  "experiment": { "name": "EvalHub" }
}
EOF
)
echo "$RESP" | jq .
JOB=$(echo "$RESP" | jq -r '.resource.id')
if [ -z "$JOB" ] || [ "$JOB" = "null" ]; then
  echo "Submission failed — check response above"
  exit 1
fi
echo "job id: $JOB"
echo "Watch: curl -sk \"\${H[@]}\" \"$EVALHUB/api/v1/evaluations/jobs/$JOB\" | jq -c '{state: .status.state, msg: .status.message.message}'"
echo "       oc get workflows -n evalhub -w"
echo "Logs:  POD=\$(oc get pods -n evalhub --sort-by=.metadata.creationTimestamp -o name | grep evalhub-garak-scan | tail -1 | cut -d/ -f2); oc logs -n evalhub \"\$POD\" -c main -f"
