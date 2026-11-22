# Guarded control-plane bootstrap

This workflow separates initialized startup, explicit new-cluster creation,
joining, and same-cluster snapshot restoration. It does not authorize fencing,
VM replacement, datastore deletion, upgrades or application-volume recovery.

The earlier synthetic native new-VM proof established the recovery contract.
The maintained bootstrap described here is locally checked but **not yet
live-qualified**. Its first deployment and restore exercise must run from the
canonical checkout on `main`, after merge and explicit operation approval. Never
deploy a feature worktree, copied root or competing state.

## Startup contract

| Local state / selected mode | Behavior before normal RKE2 startup |
| --- | --- |
| Initialized etcd, no unfinished reset | Preserve it; do not read recovery credentials, contact storage or reset membership |
| Partial datastore or incomplete reset receipt | Stop for inspection; no fresh initialization and no reset replay |
| Empty / `existing` (default) | Refuse startup until create, join or restore is explicitly selected |
| Empty / `create` | Fetch only the application's inventory credential; require both current objects and version history to be empty |
| Empty / `join` | Fetch only the existing server token; use the declared registration endpoint, without snapshot access or publication |
| Empty / `restore` | Verify selected snapshot bytes, native token association, compatible version, distinct replacement Node and explicit fencing/custody; run native reset once |

Creation does not treat listing failure, hidden versions, a delete marker or a
failed restore as absence. A nonempty backup bucket requires recovery or a
separately agreed new-cluster/storage decision, not a guessed unused prefix.

The native startup preflight runs first, then the bootstrap gate. The gate checks
the declared configuration fingerprint, native command, Node identity and token
path before empty-datastore work. Additional configuration fragments and unmanaged
environment/command overrides fail closed. Restore supports the qualified pinned
RKE2 version only; arbitrary upgrade-and-restore compatibility is not assumed.

## Before any planned replacement

1. Keep the original server and workers intact. Record original CA and kube-system
   UID, stable API identity, worker VM/Node UIDs and client-certificate fingerprints
   privately. Verify independent access to Proxmox, DNS, object storage and OpenBao.
2. Recover the matching server-token and application backup-credential copies from
   their independent custody, not only from the running VM or cluster controller.
   Preserve the existing token; do not generate an initial OpenBao password or
   rotate it as part of replacement. Keep historical snapshot/token associations.
3. Install the reviewed preparation helper and its dependencies on the original
   server through a separately approved maintenance operation. From the canonical
   service source, `prepare-recovery.py` needs adjacent `etcd-backup.py`,
   `kubernetes_object_store.py` and `kubernetes_recovery.py` in the same private
   executable directory. It uses the existing backup target/custody schemas and
   installed native tools. Do not rerun cloud-init or restart RKE2 to install it.
4. Run plan-only preparation first, then add `--execute` only after snapshot
   creation/download approval:

   ```text
   python3 -B prepare-recovery.py \
     --credentials-file <independently-recovered-application-pair> \
     --server-token-file <independently-recovered-matching-token> \
     --api-server <stable-verified-api-origin> \
     --output-directory <new-root-private-custody-directory> \
     --independent-copies-confirmed
   ```

   `--config` and `--custody-file` default to the installed backup target and
   attestation. `--max-snapshot-bytes` defaults to two GiB and accepts a positive
   bound up to sixteen GiB. No credential is read in plan-only mode.
5. Require `preparation-verified.json` and `recovery-point.json`. Execution checks
   the stable endpoint's cluster UID and native host/version, creates one fresh
   native off-node snapshot, verifies its matching token association and downloads
   the actual object. It records size/checksum and the recovery-point age without
   exposing values or changing schedules/retention. It does not retire snapshots.
   Download verification is not yet successful decryption or a restore rehearsal.
6. Preserve the metadata and protected downloaded snapshot independently of the
   original VM before destruction. The metadata contains the selected cluster,
   source Node, API identity, version, timestamp, exact key, checksum, size and
   token fingerprint, never the token itself. Record the agreed data-loss window
   at cutover; later writes are not included in that recovery point. A native
   token fingerprint is a correlation identifier, not independent custody proof.

If preparation fails after starting a save, inspect the native inventory before
retrying. A timed-out request may have completed. Preserve the phase directory;
do not silently select a different snapshot, token, namespace or cluster.

## Authorization and enrollment

The separate [recovery authorization root](recovery/README.md) manages only the
exact OpenBao reader, wrapped issuer and bounded application-credential writer.
It needs no Kubernetes API, creates no bucket and never owns server-token values.
Its record references must come from the existing approved custody interface.
The snapshot reader is distinct from both the kubeconfig publisher and workstation
operator. Use the native issuer's `--purpose bootstrap` scope, verify the account,
then enroll the application pair through the bounded writer outside state.

Pass its `enrollment` export as `cluster_bootstrap.access`. Supply the published
backup target, exact prepared recovery-point object, a distinct `node_name`, and
the separately confirmed fencing and independent-custody flags for restore.
`cluster_bootstrap.join_server` is used only for join. Never put application values,
SecretIDs or wrapping tokens into tfvars, state, plans, cloud-init or argv.

`bootstrap_ssh_known_hosts_file` must contain an independently verified guest
host key/CA; scanning an unknown replacement is not attestation. Inject only the
exact-role wrapped issuer through ephemeral `TF_VAR_bootstrap_issuer_token`.
The separate introduction resource checks metadata over verified SSH, unwraps
once, and stores the reusable root-only SecretID **before** starting bootstrap.
The Python reader obtains a short-lived exact-policy token for input retrieval,
then attempts self-revocation. It never sends operator credentials to the host.

The installed bootstrap timer retries a failed, credential-gated RKE2 start every
five minutes. It does not restart an already running RKE2. Dependency failures
before reset leave startup blocked; no token regeneration or fresh-cluster
fallback exists. `bootstrap_enrollment_revision` retries introduction, not file
installation, SecretID rotation, datastore cleanup or reset replay.

## Fencing and replacement

Agree the exact original VM, snapshot, replacement configuration, fencing method,
capacity, observation bound and stop decision before disabling VM protection.
Fence the original server before admitting the replacement. An attestation flag
does not fence a machine; the operator must verify the agreed hypervisor/network
action independently. Preserve the stable API/registration identity and unchanged
workers. The VM hostname stays configured independently of its new Kubernetes
Node name. Same-name server Node-password recovery is not qualified.

Only then generate a fresh canonical-`main` infrastructure saved plan using the
existing state. Inspect every deletion/replacement, disk effect and DNS change.
Apply only that unchanged approved plan. Do not import, forget or create competing
state to force replacement; do not disable protection without the agreed scope.

First boot installs the gate before enabling RKE2 and reboots into the installed
kernel as before. A missing enrollment blocks empty-datastore startup. Publication
introduction follows bootstrap introduction; it verifies the recovered API/UID and
retains the separate artifact's create-only/explicit-refresh behavior.

### Existing-server gate installation

Installing first-boot snippets does not update an existing guest. For a separately
approved in-place gate installation, transfer only the reviewed canonical source
and `bootstrap_host_configuration` metadata over verified SSH. Keep the actual
RKE2 configuration and native datastore untouched. Install the source assets from
`local.bootstrap_assets` at their declared paths/modes, plus root-only
`bootstrap.json` from the output's `metadata` field and the declared tmpfiles rule.
Required distribution tools are Python, PyYAML, jq and curl. Restore their native
SELinux labels, create the tmpfiles directory and run `systemctl daemon-reload`.
Do not restart RKE2, enable the retry timer or rewrite an existing AppRole merely
to install the gate. Review any existing file collision rather than overwriting it.

An initialized host's gate can be checked through the explicit
`rke2-bootstrap.py --execute`: it locks its own state and returns without reading
credentials or altering initialized data. This is still an authorized maintenance
check, not a repair command. Stop if incomplete-reset evidence is present.

## Failure, retry and acceptance

Before native reset, the gate verifies the exact downloaded snapshot checksum,
size and matching token association, then installs the protected token for native
startup. The native reset receives that same token in its child environment, not
argv; `token-file` alone was insufficient in the earlier proof. Local restore
explicitly disables native S3 retrieval, so the selected verified file is used.
ZIP suffixes are preserved. Raw native stdout/stderr are not written to logs.

The root-private bootstrap state retains the staged snapshot and
`restore-started.json`, `restore-result.json`, `restore-complete.json`. An absent
or inconsistent completion blocks future startup even if a partial datastore now
exists. A completed restore with missing data also blocks replay/creation. Do not
delete these receipts, rename data directories or clear a native reset flag as
routine retry. Preserve evidence and agree a separate state/data disposition first.
Transfer failures discard only the newly created incomplete download; verified
or mismatching staged files are not silently overwritten.

After native restoration, verify through the unchanged stable endpoint: original
CA and kube-system UID, retained objects, expected version and healthy
single-member etcd. Remove only the explicitly fenced old server Node through
the approved Kubernetes procedure, not workers or their node-password records.
Confirm original workers reconnect with their unchanged VM/Node identities and
client certificates, then verify new workload/exec and Cilium health. Reinstall
the separately owned backup timer/target for the replacement Node and verify an
actual new off-node backup without changing historical retention/token custody.

Download the actual kubeconfig with its intended administrator identity and
authenticate with TLS verification. An artifact collision after certificate
regeneration requires the [reviewed conditional refresh](artifacts/README.md),
not overwrite during recovery. Restore success does not qualify production DNS,
application volumes, OpenBao/KMS loss recovery or future HA behavior.

## Local checks

`make validate` includes native CLI loading, authorization-root validation,
OpenTofu composition checks and `bootstrap-guard-check`. The latter requires
Linux bubblewrap with unprivileged user namespaces; it uses real isolated
filesystem state and the public gate CLI without RKE2 execution or networking.
These checks are not an authenticated restore. Live qualification belongs on
canonical `main` with existing state and an explicitly approved synthetic scope.
