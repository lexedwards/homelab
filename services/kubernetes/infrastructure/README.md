# Kubernetes infrastructure

This OpenTofu root owns the Rocky Linux RKE2 control-plane VM on `compute`,
optional worker VMs on `compute`/`store`, their snippets and service-owned DNS.
It has no Kubernetes, OpenBao or S3 provider dependency. Keep its state separate
from [bootstrap prerequisites](../bootstrap/README.md) and
[API-managed runtime](../runtime/README.md).

## Inputs and installation

Copy `terraform.tfvars.example` privately and supply the reviewed Proxmox nodes,
catalogue template, guest IDs, primary/service VLANs, DNS identity, cloud user,
SSH public keys and internal cluster networks. Provider authentication uses native
`PROXMOX_VE_API_TOKEN` and `TECHNITIUM_API_TOKEN`. Snippet operations need the
approved Proxmox node identity in the operator's SSH agent. HTTPS verification
remains enabled; never persist provider credentials in inputs or cloud-init.

Cloud-init owns only immutable installation: Rocky packages, signed RKE2
repositories and pinned RPMs, SELinux/module prerequisites, networking, users,
base native configuration and fixed bootstrap tools. It contains no token,
AppRole SecretID, operation mode, runtime profile or recovery-point selection.
Changing these installation bytes may replace a VM; it is not maintenance.

The reviewed Rancher key is retained in `config/rancher-signing-key.asc`.
Installation checks enforce its pinned package/signing contract. DHCP supplies
primary addresses; the managed API DNS record follows the observed primary NIC.
Cluster continuity does not depend on retaining a MAC/address. Workers use a
separate native secondary NetworkManager profile with no default-route/DNS role.

## Enrollment and deployment

1. Prepare bootstrap resources and protected values first. Supply the unchanged
   non-secret bootstrap `enrollment` output as `bootstrap_access`.
2. Plan/apply from canonical `main` with the existing owning state. Review the
   exact saved plan before apply. Keep protection enabled outside an approved
   replacement. Use distinct `snippet_namespace`, VM IDs and DNS records for any
   separately approved qualification deployment.
3. Establish a deployment-scoped SSH pin under the accepted Proxmox metadata and
   provisioning-network first-contact policy. For a new VM, provision with
   enrollment absent, verify its generation/address and capture its scoped key;
   then inspect/apply the enrollment-only plan. Retries reject unexpected keys.
4. Supply `bootstrap_ssh_known_hosts_file` and the exact-role issuer through
   ephemeral `TF_VAR_bootstrap_issuer_token`. The isolated enrollment hook runs
   after VM/DNS creation and reuses a matching existing SecretID on retries.
5. Verify native startup and publication, then use [worker enrollment](../WORKERS.md).
   Successful credential introduction is not readiness proof.

Null `bootstrap_access` installs a host that waits safely. It is not an
unenrolled automatic-create mode. Bootstrap completion owns publication; there
is no standalone publication enrollment hook. Native RKE2 remains the owner of
snapshot operations. See [recovery](../RECOVERY.md) and [backups](../BACKUP.md).

Run `make init`, `make validate`, then, only for an authorized operation,
`make plan` and `make apply`. Both use `PLAN_FILE`; apply requires the previously
inspected unchanged plan. No persisted deployment runs from a feature worktree.

## Outputs and optional native configuration

`runtime_connection` publishes non-secret API/SSH-user/worker-cohort metadata.
Export it privately, inspect it and merge with the protected kubeconfig path in
runtime's `cluster_api` input. Runtime does not read this root's whole state.

NFS, service exposure and Cilium metrics outputs remain inspection/export
interfaces for separately approved native workflows; generating them deploys
nothing. Do not introduce simultaneous file/API owners for native Helm config.
See the service's [NFS](../NFS.md), [exposure](../SERVICE-EXPOSURE.md) and
[observability](../OBSERVABILITY.md) guides.

## Lifecycle and verification

Both VM roles are protected by default. Disable protection only through a
reviewed scoped transition before a separately approved destroy/replacement.
VM deletion removes owned OS/EFI/cloud-init volumes; external NFS/object-store
data has a separate disposition. Destroy runtime while its API still exists,
then infrastructure. Retain bootstrap recovery material unless its deletion is
explicitly approved. See [lifecycle](../LIFECYCLE.md).

Local checks cover mocked DNS transformations/snippet isolation, installed-asset
composition, YAML/shell syntax, CLI loading, isolated startup guards and enrollment
transport. They do not prove RPM boot behavior, native reset, live DNS, S3 upload
or actual cluster readiness. `make bootstrap-authorization-check` additionally
uses an explicitly supplied local OpenBao binary, never a shared service.

The previous cluster was retired through its original owners before this layout.
Keep the terminal old state as evidence; do not copy its inputs or create competing
owners. These roots support a clean identity, not an implicit state migration.
