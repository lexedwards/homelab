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

Automatic recovery assumes the single control-plane VM slot has exclusive
ownership. Before enrolling a replacement, verify the old VM is stopped/destroyed
and cannot return. A failed endpoint probe is not fencing. Never enroll another
server for recovery during a partition of an unfenced cluster. Future HA fencing
and endpoint ownership need separate qualification; a joiner must not repoint
the cluster DNS record to itself.

## Deploy, then introduce access separately

1. Deploy only the fixed installation assets from canonical `main`. The published
   DNS identity must be known and resolve correctly before enrollment/startup.
   Network, SSH and guest-agent services remain available while RKE2 is gated.
2. Prepare the independent [OpenBao authorization](recovery/README.md) and populate
   its runtime profile and three credential records outside Terraform state.
   Preserve the existing server token. For a first cluster, provision its initial
   token out of band; do not rotate an existing cluster's token to fit bootstrap.
3. For an existing cluster, independently enroll its namespace UID, actual server
   CA certificate, qualified RKE2 version and normalized native token hash into the
   identity record. Preserve matching token and application-credential copies in
   OpenBao plus independent recovery custody. Absence of that record is permitted
   only for genuine first creation; existing snapshots then prevent creation.
4. Export the recovery root's `enrollment` output into a private file. Obtain an
   exact-role wrapped-SecretID issuer, not an administrator or S3 operator token.
   From the canonical Kubernetes service directory:

   ```text
   python3 -B scripts/enroll-bootstrap.py \
     --enrollment <private-enrollment-output> \
     --known-hosts <independently-verified-host-key-or-CA-file> \
     --target <approved-user-at-guest> --issuer-file <private-scoped-issuer>
   ```

   First-contact scanning is not host attestation. The command transfers only
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
publication metadata locally. For the first namespace, use a dedicated
configuration bucket and the publisher's filename-scoped initial grant; once the
UID is known it can be tightened to the exact key. Publication remains create-only;
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

## Validation

`make validate` checks native configuration, shell/YAML and public CLI loading,
plus isolated filesystem guards. Bubblewrap needs enabled user namespaces; it
cannot access the network or real datastore. Native OpenTofu console rendering
also compares actual installation bytes before/after enrollment-input changes.
No operation-mode variables exist in the VM root. Local checks do not establish
the new end-to-end restore, enrollment, identity-writer ACL or snapshot transport
behavior; those remain main-only live qualification gates.
