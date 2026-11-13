# Off-node etcd Backups

This workflow creates native RKE2 snapshots on the existing control-plane host
and uploads them to the operator-owned RustFS bucket over verified HTTPS. It
does not back up application volumes, create a bucket, administer TrueNAS, restore
a datastore or upgrade a node. Local validation is not live backup evidence.

## Ownership and prerequisites

- Kubernetes owns these scripts, units, snapshot prefix and private host files.
  RustFS publishes an explicit endpoint/trust interface. Do not import another
  service's implementation, credentials, tfvars or state.
- Use the enrolled Rocky 10 control-plane host and its signed, pinned RKE2
  `v1.36.6+rke2r1`. The helper rejects workers, an untrusted or different kubelet
  certificate identity and other versions. Kubernetes node names need not match
  OS hostnames. Identity uses the local client CA and the public kubelet client
  certificate; no token read is needed for this check. Review the native CLI and
  metadata contract before an upgrade.
- The producer endpoint must pass system-trusted HTTPS from the control plane.
  Private-CA distribution needs separate review; neither plaintext nor TLS
  verification bypass is supported. Use a dedicated bucket-scoped credential.
- Preserve the RKE2 server token corresponding to every retained recovery point.
  Enroll it and the backup credential in external OpenBao through an independently
  reviewed, service-owned enrollment boundary, plus protected Proton Pass copies.
  This runner does not read/write OpenBao or depend on a mounted-secret controller.
- Recover the independent copies without Kubernetes or available OpenBao before
  attesting custody. A fingerprint/checkbox does not prove independent custody
  or a successful restore. Isolated restore qualification is a separate gate.
- Approve the snapshot-data at-rest protection boundary before uploading real
  datastore contents. Native bootstrap encryption does not encrypt every etcd
  value, and ZIP compression is not encryption. This workflow does not enable
  bucket encryption, manage storage keys or add client-side encryption. Existing
  producer-side encryption must be verified or a separate encryption integration
  reviewed; private bucket access and HTTPS alone are not at-rest encryption.

No installer runs automatically. Installation, actual snapshot creation, timer
enablement, retirement and custody access/copy need explicit authorization. All
maintained files must come from canonical `main`, not a feature worktree. Do not
change VM/bootstrap configuration or restart RKE2 to deploy this workflow.

## Protected host inputs

### Service-owned OpenBao records

The adjacent runtime root's optional `recovery_custody` declaration manages only
administrative authorization through the shared deployment-access module. It
checks the actual `kube-system` UID, then grants a separate bounded writer access
to exactly these two records in an explicitly approved existing KV-v2 engine:

| Record suffix under `kubernetes/recovery/<cluster_uid>/` | Fields |
| --- | --- |
| `server-token/<native_token_hash>` | `server_token` |
| `s3-credentials/<credential_sha256>` | `access_key_id`, `secret_access_key` |

The fingerprints are protected metadata, not values. The native token hash is a
correlation identifier, not an authentication or collision-resistant custody
proof. Authorization planning needs the available API/OpenBao services; ordinary
backup/restore credentials do not depend on that planning path being available.
No root-host or workload read policy is granted, no KV engine is created, and
OpenTofu neither mints a token nor writes/reads the values. The ordinary writer
cannot read records or manage authorization; its separate issuer can mint only
the non-renewable, non-orphan, maximum-900-second writer role without default policy.

Review/apply this opt-in definition separately from host installation, using a
fresh scoped administrative identity and the runtime state on canonical `main`.
The setup policy must explicitly cover the named recovery policies/token role;
do not broaden the qualification writer or grant direct administrative value
access. Privately export `recovery_custody_enrollment` and use the shared protected
credential helper to issue the bounded writer. Populate only the declared
schemas through protected stdin, initially with KV-v2 CAS=0. A collision stops
enrollment; do not overwrite or read an existing record to repair it.

Fingerprint-addressed paths and CAS=0 prevent accidental first-write overwrite,
not hostile-writer isolation: this writer still has update capability on its
exact records, and trusted administrators control the policies. Rotation needs
reviewed authorization updates for the new fingerprints and independent copies.
Preserve historical records and actual token copies while their snapshots or
versions are retained. Do not use the read-only workload role for recovery custody.

### Native host files

Prepare inputs outside Git, owned by the operator with mode `0600`. Install the
reviewed copies root-owned with mode `0600` under `/etc/rancher/rke2/`:

| File | Schema |
| --- | --- |
| `backup-target.json` | `endpoint`, `bucket`, `region`, `node_name`, `cluster_uid`; see `backup/target.json.example` |
| `backup-credentials.json` | `access_key_id`, `secret_access_key`; see `backup/credentials.json.example` |
| `backup-recovery-custody.json` | Stable cluster UID, current credential fingerprint and retained server-token fingerprints from the attestation helper |

Generate the endpoint/bucket fields from the producer's published export, not a
second independently maintained endpoint declaration. Obtain `node_name` from the
owning cluster and use the `cluster_uid` in its verified recovery enrollment
export. Verify those identities against the initialized cluster before installing
inputs. The UID namespaces objects under `rke2/<cluster_uid>`; it is not a
credential. Republish and review the host inputs after a producer-interface change.

For custody attestation, use independently recovered private files, never the
live server-token file. The helper rejects the live default path, but the operator
must verify the copies' actual origin and availability:

```bash
python3 -B scripts/backup-recovery-custody.py \
  --config /protected/backup-target.json \
  --credentials-file /protected/recovered-backup-credentials.json \
  --server-token-file /protected/recovered-server-token \
  --independent-copies-confirmed \
  --output /protected/new-backup-recovery-custody.json
```

Use `--previous /protected/previous-custody.json` during rotation to retain older
token associations. Keep the actual older token copies, not only their hashes,
until their retained snapshots and version history have a reviewed disposition.
The helper correlates the normalized server-password hash with native snapshot
annotations; it never writes the token into its output. Credential rotation
changes the credential fingerprint and requires renewed independent custody.

Never put values in CLI arguments, environment debug logs, OpenTofu inputs/state,
cloud-init or tickets. Native credentials are supplied only to the child CLI's
explicit environment, without AWS profile/session/metadata-service fallbacks.
Native RKE2 reads its existing server authentication token internally; this
wrapper neither prints nor exports it. Keep CLI/server debug logging disabled.

## Review and installation

1. Review an approved deployment's host/cluster identity, bucket scope, existing
   object namespace, custody and TLS evidence. Stop on an ownership conflict.
2. Copy `scripts/etcd-backup.py` to
   `/usr/local/libexec/homelab/etcd-backup.py`, root-owned mode `0755`. Copy the two
   reviewed units from `backup/` to `/etc/systemd/system/`. Do not enable the timer
   yet. Install only the three reviewed private inputs; never copy credential
   values through a terminal or put them in a unit.
3. Run the non-mutating default plan. It reads only target metadata, not the
   credential/token files, and runs no native commands:

   ```bash
   sudo python3 -B /usr/local/libexec/homelab/etcd-backup.py backup
   ```

4. After explicit first-snapshot/retirement approval, reload systemd and start
   `homelab-etcd-backup.service`. Inspect its exit status and the root-private
   `backup.json` report under `/var/lib/rancher/rke2/homelab-backup-reports/`.
   Verify the actual uploaded snapshot and its association, then qualify recovery
   before claiming a usable off-node backup.
5. Only after the reviewed first run succeeds and schedule deployment is approved,
   enable/start `homelab-etcd-backup.timer`. It runs at 00/06/12/18 UTC, catches up
   a missed activation and does not start a stopped RKE2 server. Existing native
   local-only scheduling remains unchanged; this separate prefix has one owner.

The wrapper does not edit the native server configuration or restart RKE2. Its
CLI uses `/dev/null` instead of loading unrelated server configuration and passes
the target explicitly. The supported native CLI uses AWS credential environment
variables and excludes credential fields from snapshot metadata. The helper
captures and suppresses raw child output; only selected numeric status is reported.
These contracts were traced against [the pinned native command][native-command],
its [K3s snapshot CLI][native-cli] and [metadata masking][native-metadata].

## Retention and failure behavior

The pinned native `save` command disables automatic local pruning, and this
wrapper explicitly sets remote automatic retention to zero as well. After a
new, ready off-node snapshot with matching recovery-token custody is observed,
only this cluster/node's `homelab-scheduled` snapshots older than fourteen days
are logically retired through native RKE2 deletion. Manual extra runs therefore
do not shorten the recovery window as a fixed-count policy could.

At most eight old snapshots are selected per run. Deletion failure or a remaining
backlog makes the service fail; it does not trigger an unbounded purge. A failed
upload, missing off-node inventory entry, changed target or unknown token
association never authorizes retirement. Keep a distinct prefix for pre-upgrade
or other operator recovery points; they are not adopted or deleted here.
The newly verified point is never selected for retirement. Timestamp-based age
and freshness still require a trustworthy host clock; this tool does not set it.

The bucket is versioned. Logical retirement can leave noncurrent versions and
delete markers; no version purge, bucket lifecycle change, hard permanent-erasure
deadline or reclaimed-storage guarantee follows. Review that lifecycle and its
grace period separately, preserving associated token copies. See [the retention
decision][versioning].

Only one wrapper operation runs at a time. Each native call is bounded at 450
seconds; the pinned CLI's S3 timeout is its normal five minutes. A timed-out
operation may have completed remotely: inspect status before retrying. The unit
has a 45-minute upper bound and never silently relaxes TLS, permissions or custody.

The failure path writes a private failure report and exits nonzero, without raw
child errors. Backup and inventory reports are separate, so a later status read
does not erase a failed backup result. Notification destinations/escalation remain
undecided; failed systemd units and reports are not an alerting deployment.

For an explicitly authorized live inventory/freshness check:

```bash
sudo python3 -B /usr/local/libexec/homelab/etcd-backup.py status --execute
```

The report exposes ready-point count and age, not names, locations, metadata or
recovery values. Add `--max-age-seconds` only with an operator-selected bound;
there is no implicit alert threshold. Status also rejects snapshots whose token
association is not in custody. Both commands need the local RKE2 server; they
are not the independent outage/restore access path. Off-node recovery still
requires independently held credentials and the corresponding server token.

[versioning]: ../../docs/adrs/009-versioned-backup-recovery-window.md
[native-command]: https://github.com/rancher/rke2/blob/v1.36.6%2Brke2r1/pkg/cli/cmds/etcd_snapshot.go
[native-cli]: https://github.com/k3s-io/k3s/blob/c2fdd7c56c2c/pkg/cli/cmds/etcd_snapshot.go
[native-metadata]: https://github.com/k3s-io/k3s/blob/c2fdd7c56c2c/pkg/etcd/snapshot/types.go
