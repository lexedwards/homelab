# Kubernetes API Runtime

This OpenTofu root owns API-managed cluster configuration separately from the
parent VM/provisioning state. Kubernetes or OpenBao API outages therefore do not
prevent planning VM recovery in the parent root. See [the decision][decision] and
[mounted-secret operations][secrets] for ownership, inputs and apply phases.

All persisted operations run from canonical
`/home/alex/sourcecode/homelab/services/kubernetes/runtime` on `main`. This root has
its own protected `terraform.tfstate`; preserve the existing parent Kubernetes
and sibling OpenBao states. Nothing is migrated or split out of those states:
the earlier API rollout was paused before creating any managed runtime objects.
Never copy a feature-worktree state into production or apply the parent VM plan
from this directory.

Run `make init` then `make validate` locally. These initialize providers and run
mocked/API-fixture checks, not deployments. Parent `make init`/`make validate`
include this root. Live plans require the previously applied non-secret metadata
outputs from the two infrastructure roots, protected Kubernetes credentials,
explicit ephemeral OpenBao administration and reviewed worker trust. Review a
saved runtime plan before applying it. A native chart object is not Ready proof;
wait for real CRDs/releases before enabling service definitions.

This is a privileged platform/authorization root, not an ordinary app deployment
identity. Its qualification definition also enrolls a separate exact-record
writer token role and bounded issuer policy. `secrets_qualification_enrollment`
exports only non-secret issuance metadata. Mint tokens and populate values through
the protected OpenBao helper, never through OpenTofu. That writer cannot manage
or refresh this root's auth resources; authorization remains administrative.

Enabled runtime plans fetch pinned charts over HTTPS and fail on checksum or
network errors. No charts are vendored and there is no offline fallback. Saved
plans contain the verified chart bytes; cluster image pulls still require
reachable registries. Reliable internet access is an operating prerequisite.

[decision]: ../../../docs/adrs/006-kubernetes-runtime-state-boundary.md
[secrets]: ../SECRETS.md
