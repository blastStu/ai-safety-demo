# RHOAI — DSC enablement for V1.1

This layer extends the existing `default-dsc` (dashboard + workbenches) to the V1.1 set: `aipipelines` + `trustyai` + `mlflowoperator` (Managed), `kueue` starts Removed.

- `rhods-operator/` is already installed (3.6.0-ea.2, beta channel, Manual) — the Subscription here is the pin, not a new install. For GA switch to `stable-3.6` and bump the CSV.
- `dsc-patch.yaml` is the minimal merge patch. Apply via `oc patch … --patch-file` or via the Kustomize wrapper.
- Watch for the 3.5 EA2 webhook bug: after Ready, re-check `oc get dsc default-dsc -o json | jq .spec.components` — if aipipelines/mlflowoperator flipped to NOT SET, re-patch.
- `kueue-config/` is optional — only promote DSC kueue to Unmanaged + apply these if Garak/Training jobs complain about missing queues.
