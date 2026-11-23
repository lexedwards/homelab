# Automatic cluster bootstrap and recovery

Cloud-init is an immutable installation asset, not a create/join/restore selector.
[Bootstrap](bootstrap/README.md) owns external prerequisites;
[infrastructure](infrastructure/README.md) owns VMs, DNS and access introduction.
All persistent operations run from canonical `main` and the actual owning state,
after review of a fresh saved plan. Never deploy a copied root or worktree state.

## Discovery

| Observed condition | Behavior |
| --- | --- |
| Initialized local datastore and consistent restore receipts | Preserve local data and start normally, without external credential reads |
| Empty host, no verified enrollment | Wait safely |
| Verified available registration endpoint and independent identity | Join without restoration or publication |
| Connection refused, known identity and newest valid matching backup | Download conditionally and invoke native restoration |
| Connection refused, no identity/history and empty current/retained backup inventory | Create a genuinely new cluster |
| DNS/TLS/timeout/network error, missing known-cluster backup, wrong token or ambiguous snapshot | Stop and retry; never fall back to creation |

For a deliberately fresh identity, choose new external record/bucket addressing
or separately retire the old history first. Removing identity data alone does
not authorize creation over retained identity metadata or snapshots. Do not add
a force-create switch to work around a failed safety check.

Native RPMs create empty database/snapshot directory scaffolding. Root-controlled
directory-only trees are accepted; files, symlinks, unsafe permissions and TLS
material stop an uninitialized host for inspection. No useful data is deleted or
renamed. The check runs again before reset.

## External prerequisites and custody

1. Apply bootstrap resources and prepare its runtime profile plus three credential
   records through the bounded protected value-enrollment interfaces. A new cluster
   needs an initial token provisioned out of band; an existing cluster must retain
   its actual matching token. Never mint a new token merely to configure backups.
2. Preserve actual token and retrieval-credential copies in external OpenBao and
   independent Proton Pass custody. Fingerprints correlate material but cannot
   decrypt snapshots. Preserve tokens associated with all retained versions.
3. Existing-cluster identity contains the actual namespace UID, CA, qualified RKE2
   version and normalized token association. For genuine creation it is absent;
   completion registers the observed identity through a CAS-zero-only writer.
4. Keep the namespace-friendly `cluster_name` consistent across the profile,
   enrollment and dedicated backup/configuration buckets. Identity is evidence,
   not storage naming. See [the five-record contract](bootstrap/README.md).

External OpenBao, RustFS and KMS remain accepted recovery dependencies. Their
outages block recovery until restored. No local-only recovery route is supplied.
The in-cluster native S3 Secret serves normal backups, not pre-API restoration.

## Verified-SSH introduction

Supply bootstrap's non-secret `enrollment` output as infrastructure's
`bootstrap_access`. Introduce the exact-role issuer only through ephemeral
`TF_VAR_bootstrap_issuer_token`; it must not enter tfvars, plans or state.

The accepted first-contact policy trusts authenticated Proxmox VM identity/address
metadata and the provisioning network. For a new/replacement generation, first
provision with enrollment absent, verify that exact identity/address, capture the
first key and persist a deployment-scoped pin. This is a platform/network trust
assumption, not cryptographic attestation from an IP address alone. Retries reject
unexpected changes; never weaken global SSH checking or guest-agent policy.

Then inspect/apply the enrollment-only plan with `bootstrap_ssh_known_hosts_file`.
The hook runs after VM/DNS provisioning, waits for cloud-init, installs validated
non-secret metadata and introduces a wrapped SecretID. Matching credentials are
reused on retry. VM replacement recreates the hook; changing only
`bootstrap_enrollment_revision` retries it without changing installation assets.
Null access leaves the empty host waiting, not initialized.

For a separately approved standalone introduction, run from the service directory:

```text
python3 -B scripts/bootstrap/enroll-bootstrap.py \
  --enrollment <private-enrollment-output> \
  --known-hosts <scoped-host-key-file> \
  --target <approved-user-at-guest> --issuer-file <private-scoped-issuer>
```

The reusable SecretID is saved root-only before activation. A different role
fails rather than silently rotating credentials. The bounded retry timer starts
inactive RKE2 and completes identity/backup/publication work; it never restarts
a healthy server. Enrollment success is not readiness evidence.

## Restoration and failure boundaries

Fence the old control plane before replacement. A failed endpoint probe is not
fencing; never enroll a second recovery server during a partition of an unfenced
cluster. Future HA membership/fencing requires separate qualification.

Before approved destruction, use `scripts/bootstrap/prepare-recovery.py` to save
and independently download a fresh native snapshot using recovered token and
credential copies. Record the selected timestamp and agreed data-loss window.
The helper defaults to plan-only and authorizes no VM destruction.

Discovery accepts native `etcd-snapshot` and historical `homelab-scheduled` names.
It verifies native Node/token metadata, bounds size and downloads with an ETag
condition. Native reset receives the actual matching token independently and uses
the local downloaded snapshot with `--etcd-s3=false`. The restored CA must match.

Root-private started/result/completed receipts block replay after failed or
partial reset. Preserve receipts and staged downloads on failure; do not clear
reset flags, rename data or replay cloud-init as a routine retry. Publication or
dependency failure after successful startup does not restart healthy RKE2.

## Completion and acceptance

Completion authenticates through stable API DNS and verifies observed UID/CA/token
identity. It enrolls native snapshot settings and the S3 Secret, then publishes a
private kubeconfig copy through separate application credentials. Workers/joiners
do not publish. Existing differing contents need an explicitly approved
[conditional refresh](bootstrap/README.md#publication-and-refresh).

Verify original identity/objects on restoration, retained worker identity and
current credentials, healthy etcd/Cilium, fresh workload/exec/DNS/HTTP, and actual
administrator object download/login. DNS follows the replacement's discovered
address; MAC/IP continuity is not required. Record downtime/write loss rather than
claiming zero loss or an unmeasured SLA. Fresh creation records a new identity;
it does not prove recovery of an old cluster.

Verify a real native scheduled off-node upload and actual retrieval using
[BACKUP.md](BACKUP.md). Existing-process schedule changes need an explicitly
approved RKE2 restart to load; completion only stages them. Application-volume,
HA/quorum-failure and external-dependency-loss recovery remain separate.

## Local verification

Service `make validate` runs native mocked-root checks, shell/YAML/CLI loading,
isolated startup guards and enrollment transport fixtures. Linux bubblewrap/user
namespaces are required. Tests preserve initialized/partial data, failed-reset
receipts, role exclusions and immutable installation across enrollment changes.

`make -C infrastructure bootstrap-authorization-check BAO_BINARY=<reviewed-local-binary>`
also exercises rendered policy and the real guest client against disposable
OpenBao with verified local TLS. It checks first registration, denied overwrite,
unsafe CAS and deleted-history refusal. These local checks establish no live
cluster, shared-service access, native reset or S3 transport success.
