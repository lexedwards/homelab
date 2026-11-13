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

[decision]: ../../../docs/adrs/006-kubernetes-runtime-state-boundary.md
[secrets]: ../SECRETS.md
