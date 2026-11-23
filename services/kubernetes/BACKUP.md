# Native RKE2 etcd backups

RKE2 owns snapshot scheduling, S3 upload, count-based retention and native restore.
Use its [backup and restore documentation][upstream] for those operations. Homelab
provides the external credentials, safe bootstrap and recovery-point verification;
it does not run a second backup timer or implement snapshot pruning.

Etcd snapshots do not back up application volumes. Production rollout and recovery
qualification are separate approved operations; merged configuration is not live
backup evidence.

## Configuration and credentials

The external OpenBao runtime profile described in [recovery/README.md](recovery/README.md)
supplies the dedicated `<cluster-name>-backups` target. Its optional `snapshots`
object accepts these native settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `etcd-snapshot-schedule-cron` | `0 */6 * * *` | Native cron schedule, evaluated in the server's timezone |
| `etcd-snapshot-retention` | `5` | Local snapshots retained per server |
| `etcd-s3-retention` | `56` | Remote snapshots retained across the configured bucket/folder/name prefix |

Configure the guest timezone deliberately; the previous external timer used UTC.
Zero retention disables native pruning. RKE2 parses cron syntax and implements
scheduling and retention. At six-hour intervals, 56 remote snapshots represent
approximately fourteen days, **not a guaranteed age-based recovery window**.
Native remote retention is not scoped to the current server Node, so replacing a
Node does not strand earlier native scheduled snapshots outside its count.

For fresh create/restore, discovery writes the non-secret native snapshot overlay
before starting RKE2. It enables compressed snapshots and native S3 Secret support.
After the stable API authenticates to the original cluster identity, bootstrap
completion reads the separate backup application pair from OpenBao and creates
the native `kube-system/rke2-etcd-snapshot-s3-config` Secret. It refuses a Secret
owned by someone else, reuses matching data and uses resource-version checking for
credential updates. No credential is passed in argv, cloud-init or OpenTofu state.

The native Secret contains the verified HTTPS endpoint, path-style bucket access,
`snapshots/` folder, region, application pair and S3 retention count. No other S3
connection flags are set in the server overlay: those would override native Secret
lookup. Joining bootstrap servers skip this integration, restoration and publication;
HA backup behavior is not qualified here.

RKE2 reads this Secret for snapshot operations. Credential refresh can therefore
take effect without restarting RKE2. Bootstrap completion retries independently
of kubeconfig publication; a publication collision does not prevent Secret
enrollment. Normal backup status/failure visibility comes from RKE2 logs and
`ETCDSnapshotFile` resources, not a separate wrapper report.

## Preserve the server token independently

The snapshot alone is insufficient to restore a new host. Preserve the matching
`/var/lib/rancher/rke2/server/token` in **external OpenBao and independent Proton
Pass custody** before relying on the schedule. Never regenerate it to configure
backups, and never extract the live token merely to claim independent custody.
Our scheduling integration does not write or rotate the server token.

Retain the actual tokens associated with all retained snapshots and version
history. Fingerprints only correlate recovery points; they are not replacement
token material. Preserve independently recoverable application credentials too.
See [the custody decision][custody].

The runtime root's optional recovery-custody grant still owns exact administrative
authorization for fingerprint-addressed token and backup-credential records. It
does not write values or grant a Kubernetes controller recovery access. Preserve
historical records on credential/token rotation.

## Existing-server migration

Do not install the retired custom backup timer. For a host that still has it,
separately approve disabling `homelab-etcd-backup.timer` before enabling native
off-node scheduling. Preserve its private inputs, reports and snapshots until
their scoped disposition is approved; deleting source code does not remove them
from a guest. Existing `homelab-scheduled` snapshots remain discoverable for restore
but are not adopted by native scheduled-prefix pruning.

From canonical `main`, install reviewed static integration assets through an
approved in-place maintenance procedure, not cloud-init replay or a copied root.
Run bootstrap completion only after matching OpenBao enrollment and custody are
verified. It stages `config.yaml.d/80-snapshots.yaml` and enrolls the native Secret.
An existing RKE2 process needs a **separately approved restart** to load changed
cron/S3-enable/local-retention settings. Completion reports this but never restarts
a healthy server. A runtime profile change does not change VM installation bytes.

Verify the next real scheduled upload, metadata and actual retrieval before
claiming scheduled backup success. Do not enable a durable schedule with temporary
qualification credentials. No native pruning migration, version purge, timer
activation or restart follows merely from merging this change.

## Verify an off-node recovery point

After approved enrollment, use native commands on the server:

```bash
sudo rke2 etcd-snapshot ls
kubectl get etcdsnapshotfiles
sudo journalctl -u rke2-server
```

Keep raw output private. Native local snapshots alone do not prove an S3 upload.
Verify HTTPS, the dedicated bucket/folder, native token/Node metadata and actual
download. Before any replacement, use the maintained
[preparation procedure](RECOVERY.md#discovery-and-preservation).

`backup/target.json.example` and `backup/credentials.json.example` describe protected
preparation inputs, not files needed by the scheduler. The target identifies the
cluster UID and current source Node as verification evidence, never storage naming.
Attest independently recovered copies without printing values:

```text
python3 -B scripts/backup-recovery-custody.py \
  --config <private-preparation-target> \
  --credentials-file <independently-recovered-backup-pair> \
  --server-token-file <independently-recovered-server-token> \
  --independent-copies-confirmed --output <new-private-custody-record>
```

Use `--previous <private-custody-record>` on rotation to retain older token
associations. The preparation helper invokes native snapshot save and verifies a
fresh matching off-node point using independently supplied credentials, including
ETag-conditional download. It does not schedule backups or prune snapshots itself.

## Restore and retention boundaries

The native S3 Secret is for normal operation, **not the recovery credential source**:
the API is unavailable during restoration. Guarded bootstrap obtains the original
token and backup pair directly from external OpenBao, verifies/downloads the
matching snapshot, then invokes native `rke2 server --cluster-reset` with local
snapshot input and S3 disabled for that invocation. It never falls back to fresh
creation when recovery material is missing. See [RECOVERY.md](RECOVERY.md).

The buckets remain versioned and encrypted under the approved RustFS/OpenBao KMS
boundary. Native logical deletion does not purge noncurrent versions or reclaim
all storage. Preserve associated tokens until version disposition is reviewed.
External OpenBao/RustFS/KMS outages remain recovery dependencies; local-only
recovery and application-volume recovery are not claimed.

[upstream]: https://docs.rke2.io/datastore/backup_restore
[custody]: ../../docs/adrs/007-kubernetes-recovery-custody.md
