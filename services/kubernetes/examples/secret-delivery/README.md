# Optional secret-delivery qualification

This root owns only the synthetic ordinary/Kata secret-delivery consumers and
their exact-record access. Normal cluster deployment does not invoke it.

First deploy the shared secret platform through `../../runtime`, wait for the
actual CSI CRDs/releases and verify Kata. Planning a SecretProviderClass requires
its real CRD schema; `depends_on` cannot install it during that earlier plan.

Provide the published cluster/platform connection contract privately. Use a
protected kubeconfig and native `VAULT_TOKEN`, never credential values in tfvars.
Start with zero replicas. After an authorized canonical plan/apply, export
`value_enrollment` privately and populate only the declared synthetic record with
the shared protected value helper. Then approve two replicas and use
[the qualification checks](../../SECRETS.md#owned-ordinarykata-qualification).

This root has its own state. Destroy it while Kubernetes and the CSI CRDs are
available, before removing the shared platform or VMs. Its destroy does not
delete stored OpenBao values. Record all temporary artefacts and their disposal
in ALE-67's protected lifecycle ledger. Never reuse real application secrets.
