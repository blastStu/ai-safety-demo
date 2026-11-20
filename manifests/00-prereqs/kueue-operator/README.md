# kueue-operator (prereq, external from DSC's point of view)

Why: RHOAI's `kueue: Unmanaged` means "an external Kueue operator owns the ClusterQueue". Installing the operator here satisfies that. Embedded Kueue is deprecated since 2.24 — the external RHBOK operator is the supported path (3.5).

Gate: `oc get csv -n kueue-system`, `oc get crd clusterqueues.kueue.x-k8s.io`.

DSC note: V1.1 defaults `kueue: Removed` in `10-rhoai/dsc-patch.yaml` and only promotes to `Unmanaged` + ClusterQueue if EvalHub actually complains "Configure queue".
