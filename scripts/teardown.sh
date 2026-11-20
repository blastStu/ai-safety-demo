#!/usr/bin/env bash
# Teardown in reverse dependency order — never delete the shared oidc-provider.
set -euo pipefail
echo "This script is not auto-runnable — review each step first."
echo "Reverse order: 40-garak → 30-mlflow → 20-dspa → 10-rhoai (patch DSC back to dashboard+workbenches) → 00-prereqs (optional, leave cert-manager/kueue if shared)"
echo "NEVER run: rosa delete oidc-provider — it is shared and kills every cluster in the org."
echo "Cluster teardown (only when done with your dev cluster):"
echo "  rosa delete cluster -c <your-cluster-name> --yes"
echo "  rosa delete operator-roles --prefix <your-operator-roles-prefix> --yes --mode auto"
