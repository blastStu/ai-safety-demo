# cert-manager (prereq)

Why: cert-manager is a platform dependency for Kueue and for RHOAI's webhook certs. odh-gitops lists it in `dependencies/operators/kustomization.yaml` (11 active operators). The rosa skill installs it first (L799).

Apply: `oc apply -k manifests/00-prereqs/cert-manager`
Gate: `oc get csv -n openshift-cert-manager`, `oc get crd certificates.cert-manager.io` exists.

Provenance: derive channel/CSV live from `packagemanifest openshift-cert-manager-operator`, record in `docs/decisions.md`.
