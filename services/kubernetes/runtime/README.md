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
output from the parent infrastructure root, a privately published OpenBao endpoint
export (`openbao_endpoint_file`), protected Kubernetes credentials,
explicit ephemeral OpenBao administration and reviewed worker trust. Review a
saved runtime plan before applying it. A native chart object is not Ready proof;
wait for real CRDs/releases before enabling service definitions.

This is a privileged platform/authorization root, not an ordinary app deployment
identity. Its qualification definition also enrolls a separate exact-record
writer token role and bounded issuer policy. `secrets_qualification_enrollment`
exports only non-secret issuance metadata. Mint tokens and populate values through
the protected OpenBao helper, never through OpenTofu. That writer cannot manage
or refresh this root's auth resources; authorization remains administrative.

Reusable implementations live in repository-level `modules/`; this root imports
no module, script or state from another service. OpenBao publishes its endpoint
as a JSON output export, not access to its hosting state. Republish after endpoint
changes. The parent Kubernetes state remains a same-service metadata interface.

Enabled runtime plans fetch pinned charts over HTTPS and fail on checksum or
network errors. No charts are vendored and there is no offline fallback. Saved
plans contain the verified chart bytes; cluster image pulls still require
reachable registries. Reliable internet access is an operating prerequisite.

## Private DNS routing

Set optional `private_dns_forwarding` in protected runtime inputs to an exact
private suffix (`zone`) and its existing internal IPv4 `resolver`. The enabled
`secrets_platform` currently supplies this root's API authentication and trust.
Do not mix public resolvers with internal resolvers for private-zone forwarding:
public negative answers can produce intermittent resolution failures.

This root owns only the native `rke2-coredns` HelmChartConfig. RKE2 still owns
the HelmChart and release; do not edit its rendered ConfigMap or install a second
DNS server. The chart imports one mounted server-block file through `extraConfig`
and `zoneFiles`, leaving its `servers` defaults, cluster discovery, public
forwarding, image and availability settings unchanged. An existing chart config
requires ownership review before adoption; do not force field ownership.

The interface was rendered against the RKE2-provided `rke2-coredns` chart
`1.49.002`. Recheck that interface on RKE2 upgrades. After the approved canonical
apply, wait for the native Helm rollout, verify every DNS backend returns the
private address from both workers, and check cluster/public resolution. Then
check failed consumer mounts retry successfully and the next plan converges.
This changes cluster DNS configuration, not upstream DNS records, firewall rules,
guest resolvers or OpenBao ownership. Disabling the input is destruction-guarded;
review rollback explicitly rather than deleting the config out of band.

[decision]: ../../../docs/adrs/006-kubernetes-runtime-state-boundary.md
[secrets]: ../SECRETS.md
