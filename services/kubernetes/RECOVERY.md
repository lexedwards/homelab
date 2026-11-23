# Automatic control-plane bootstrap

Cloud-init is an immutable VM installation asset. Changing it is a guest
replacement, never an in-place configuration mechanism. It installs fixed tools,
units, a stable base RKE2 configuration and an enrollment-gated startup check.
It contains no OpenBao access metadata, discovered role, snapshot selection,
fencing flag or recovery-operation revision.

All live operations, including qualification on retained test guests, run only
from canonical `main` and the owning root's existing state after merge and
explicit approval. No feature-worktree or copied-root deployment is supported.
The new automatic flow remains unqualified until that main-only exercise passes.

## The boot procedure

```text
Initialized local datastore → start it normally.
Otherwise wait for verified SSH/OpenBao enrollment.
Read runtime profile, independent identity and server token from OpenBao.
Verified cluster endpoint available → join.
Endpoint refuses connection + known cluster + newest valid backup → restore.
Endpoint refuses connection + no recorded cluster + empty current/history inventory → create.
Anything uncertain → stop and retry; never fall back to creation.
```

The fast probe uses the published registration endpoint and expected CA. A proxy
error, DNS failure, TLS error, timeout or unexpected response is uncertainty,
not absence. A joining server does not read backup or publication credentials,
restore a snapshot, or publish a kubeconfig. Existing local data takes precedence
over all discovery and needs no OpenBao or S3 access to start.

Native package installation creates an empty `server/db/snapshots` directory.
That scaffolding is not an initialized datastore. Bootstrap inspects contents:
directory-only trees are allowed without depending on package directory names.
Files, symlinks, unsafe directory permissions and TLS material still stop an
uninitialized server for inspection. The same inspection runs after snapshot
download, before native reset. It never deletes or renames these paths.

Automatic recovery assumes the single control-plane VM slot has exclusive
ownership. Before enrolling a replacement, verify the old VM is stopped/destroyed
and cannot return. A failed endpoint probe is not fencing. Never enroll another
server for recovery during a partition of an unfenced cluster. Future HA fencing
and endpoint ownership need separate qualification; a joiner must not repoint
the cluster DNS record to itself.

## Deploy, then introduce access separately

Choose the stable friendly `cluster_name` before deployment. The storage root
declares `<cluster-name>-backups` and `<cluster-name>-configuration`, with separate
application credentials. Snapshot keys use `snapshots/`; kubeconfig uses exactly
`kubeconfig.yaml`. UID and CA still verify the original cluster, but never address
its storage. No wildcard publisher grant or UID-dependent enrollment is needed.

External OpenBao and RustFS are accepted recovery dependencies. If either is
unavailable, an empty server waits safely. This workflow does not provide a
local-only backup restore route; independent token custody remains required.

1. Prepare the independent [OpenBao authorization](recovery/README.md) and populate
   its runtime profile and three credential records outside Terraform state.
   Preserve the existing server token. For a first cluster, provision its initial
   token out of band; do not rotate an existing cluster's token to fit bootstrap.
2. For an existing cluster, independently enroll its namespace UID, actual server
   CA certificate, qualified RKE2 version and normalized native token hash into the
   identity record. Preserve matching token and application-credential copies in
   OpenBao plus independent recovery custody. Absence of that record is permitted
   only for genuine first creation; existing snapshots then prevent creation.
3. Supply the recovery root's non-secret `enrollment` output as `bootstrap_access`
   in the VM root's private inputs. Set `bootstrap_ssh_known_hosts_file` to an
   independently verified guest host-key/CA file. Inject the exact-role wrapped
   issuer only through ephemeral `TF_VAR_bootstrap_issuer_token`; do not write it
   to tfvars, state or a saved plan. Leave `publication_access` null: bootstrap
   completion owns publication through its separate OpenBao record.
4. From canonical `main`, use the owning root's existing state to plan, inspect
   and apply with explicit deployment approval. After creating the VM and API DNS,
   `terraform_data.bootstrap_enrollment` waits for cloud-init and introduces access
   over verified SSH automatically. VM replacement recreates this hook. Changing
   `bootstrap_enrollment_revision` retries enrollment without changing VM assets or
   rotating a matching SecretID. Network, SSH and guest-agent services remain
   available while RKE2 waits. Neither access metadata nor discovery enters cloud-init.

An enrollment/activation error fails the apply and leaves the hook retryable;
empty-datastore RKE2 startup stays gated until its safety checks pass. Successful
enrollment is not cluster readiness or recovery acceptance. With null
`bootstrap_access`, apply does not enroll: an empty VM continues waiting. This
preserves explicit separately approved installation/manual-enrollment use.

For an explicitly approved standalone introduction or diagnostic retry, the same
transport remains available from the canonical Kubernetes service directory:

```text
python3 -B scripts/enroll-bootstrap.py \
  --enrollment <private-enrollment-output> \
  --known-hosts <independently-verified-host-key-or-CA-file> \
  --target <approved-user-at-guest> --issuer-file <private-scoped-issuer>
```

First-contact scanning is not host attestation. Both paths transfer only
non-secret access metadata plus a one-time wrapped SecretID over verified SSH.
The host saves the reusable SecretID root-only before activation. Repeating
introduction for the same role reuses that credential; a different role fails
instead of silently rotating it. No VM resource or first-boot bytes change.

The five-minute timer starts an inactive RKE2 service and completes identity and
publication work. It does not restart an already running server. Endpoint/storage
or enrollment failures leave empty-datastore startup blocked. Runtime profile and
credential updates are OpenBao operations, not VM redeployment inputs.

## Discovery and preservation

Discovery selects the newest maintained `homelab-scheduled` snapshot in the
recorded cluster namespace. It verifies native S3 Node/token metadata and a bounded
size, then downloads conditionally against that object's ETag. It preserves the
download checksum, token association and native ZIP suffix. Invalid or ambiguous
newest snapshots stop recovery rather than silently selecting another point.
Missing backups for a recorded cluster never authorize a new cluster.

Before a planned replacement, use `prepare-recovery.py` to obtain a fresh native
off-node snapshot and verify actual retrieval and independent token custody.
It defaults to plan-only; `--execute` needs explicit snapshot/download approval.
Its private receipts and downloaded copy are preparation evidence, not Terraform
inputs or a manually selected boot mode. Record the recovery-point age and agreed
data-loss window before fencing/destruction. Existing schedules and retention are
unchanged; this helper does not retire old snapshots.

The gate writes one fixed runtime overlay after discovery, never rewriting the
base installation file. Native `with-node-id` separates a replacement Kubernetes
Node name from the preserved VM hostname. Normal restart keeps local identity.
Native restore receives the matching server token only in its child environment;
the native token-file setting alone was insufficient in the earlier proof.

Root-private reset-start/result/completion receipts block replay after failure or
partial restoration. A restored CA must match independent identity before startup
is allowed. Do not remove receipts, rename data directories or clear reset flags
as routine retry; agree a separate disposition after inspection. Raw native
stdout/stderr are never published as diagnostics.

## After startup

Completion authenticates through the stable API and verifies the actual namespace
UID and CA against OpenBao. On genuine first creation it records that identity
with a short-lived, CAS-zero-only writer. It cannot replace existing identity or
write server-token/credential records. Any CAS collision stops for inspection.
Keep independent identity custody protected; deletion of its OpenBao record is
not a supported reset operation.

The host then obtains the separate application publisher pair and renders its
publication metadata locally. Use the dedicated configuration bucket and the
predeclared exact `kubeconfig.yaml` grant, even on first creation. Publication remains create-only;
changed retained contents need the [explicit conditional refresh](artifacts/README.md).
Credentials and operational metadata never enter cloud-init or VM state.

Acceptance still requires original CA/namespace/object identity, healthy
single-member etcd, unchanged workers/Node UIDs/client certificates, fresh workload
and exec, healthy Cilium, and an actual administrator kubeconfig download/login.
Remove only the explicitly fenced old server Node through the approved procedure.
Reinstall/check the separately owned backup runner for the actual replacement
Node using [BACKUP.md](BACKUP.md); its independent custody and retention gates are
not bypassed by successful bootstrap. Application volumes and OpenBao/KMS loss
recovery remain separate concerns.

## Retained-server ownership handoff

This is a separately approved state operation, not a VM replacement or permission
to apply a copied root. Work from canonical `main`. Preserve the existing sole
server owner until the handoff is approved. A second workspace cannot by itself
isolate remote files: set a distinct `snippet_namespace` and review every VM ID,
snippet path and DNS record before using a qualification workspace.

For local state, prepare these exact inputs in a protected operator record:

- Source state path, lineage, serial and hash, and the one server VM resource
  address, provider and native VM ID.
- Destination workspace/state path and its canonical address,
  `proxmox_virtual_environment_vm.control_plane`. Verify the destination is not
  production and owns no server. Include any workspace creation in the approval.
- Backup paths for both states, exclusive access to both owners and a halt point
  if either state changes after review. Keep default state locking enabled.
- The complete list of resources that stay in the source, with their attributes
  fingerprinted for comparison. Keep the worker and all original snippets there,
  including any network-data file shared with the worker.

`tofu state mv` supports a local source/destination state handoff. Its `-dry-run`
must select exactly the approved server address. With the protected input paths
and source address supplied privately, review this command before running it:

```bash
tofu state mv -dry-run \
  -state="$SOURCE_STATE" -state-out="$DESTINATION_STATE" \
  -backup="$SOURCE_BACKUP" -backup-out="$DESTINATION_BACKUP" \
  "$SERVER_SOURCE_ADDRESS" proxmox_virtual_environment_vm.control_plane
```

Removing `-dry-run` performs the separately approved transfer. Verify that the
installed CLI supports these local-state options. Do not use
`state rm` followed by import, copy state into a second active owner, or suppress
locking. Remote-backend migrations require their own backend-specific procedure;
do not apply local-file instructions to them.

After approval, preserve byte-exact copies of each existing state and transfer
only the server VM address. Native command backups may normalize serialization;
they do not replace those pre-operation copies.
Freeze the old root against apply: its old configuration would otherwise attempt
to recreate the removed server. Read back both states immediately. Require the
same native VM ID under exactly one owner, unchanged worker/snippet attributes,
unchanged production state, and the expected lineages/serials. Moving across two
local files is not an atomic transaction; if interrupted, inspect both states and
backups before any retry or apply. State backups are not datastore rollback.

Only then generate a fresh saved plan from the canonical server-owning workspace
with explicit qualification inputs and `workers = {}`. New namespaced snippets
must not take ownership of the old worker's backing files. Review a same-slot
server replacement as destroy-before-create when reusing its VM slot. Proxmox
may allocate a new MAC and DHCP address. The existing managed API DNS record must
follow the discovered replacement address before enrollment, preserving the
API/registration name and its TLS SAN. Verify resolution from the worker and
administrator paths without hosts-file or transport overrides. No preserved MAC
or IP address is required for cluster persistence.

Correct legacy test-fixture endpoint overrides before qualification through a
separately reviewed and approved change. Replace an address-based runtime profile
with the stable DNS name, reconcile any worker hosts-file override and verify
that its registration configuration uses that name. Preserve worker identity,
token and datastore; do not rebuild or re-enroll it to repair the fixture.
Review any required explicit conditional kubeconfig refresh as well. Do not
change maintained infrastructure to preserve a fixture's hard-coded address.

The namespace and deletion-protection inputs do not bypass the independent
SSH trust, stable DNS endpoint, custody, fresh snapshot, fencing or replacement
approval gates. The exact replacement plan needs its own approval before apply.

## Validation

`make validate` checks native configuration, shell/YAML and public CLI loading,
plus isolated filesystem guards. Bubblewrap needs enabled user namespaces; it
cannot access the network or real datastore. Native OpenTofu console rendering
also compares actual installation bytes before/after enrollment-input changes.
Transport fixtures exercise first introduction, matching-credential reuse and
failure propagation with stubbed SSH/OpenBao in a network-isolated namespace.
`make bootstrap-authorization-check BAO_BINARY=<reviewed-local-binary>` additionally
loads the actual rendered policies into disposable OpenBao and exercises the
guest AppRole client over verified local TLS. It proves first registration and
denied unsafe CAS, overwrite, metadata changes and deleted-history replay without
using production credentials. A matching OpenBao 2.7.2 binary and enabled user
namespaces are required. No operation-mode variables exist in the VM root.
Local checks do not establish end-to-end restore, deployed enrollment or actual
RustFS snapshot transport; those remain main-only live qualification gates.
