# Per-cluster backup and configuration storage

This administrative root owns two buckets for a stable `cluster_name`:
`<cluster-name>-backups` for native snapshots under `snapshots/`, and
`<cluster-name>-configuration` for the single `kubeconfig.yaml` object. It also owns
the standalone publisher's OpenBao authorization. It does not create snapshots,
store application credential values, manage DNS or own the VM. It needs no live
Kubernetes API to provision storage or exact application scopes before first boot.

Publication is the first ALE-63 slice. Guarded snapshot restoration is separate;
these definitions alone do not make VM replacement safe.

## Access and custody

| Identity | Purpose |
| --- | --- |
| Workstation S3 operator | Provision both buckets and issue separate RustFS application accounts through `homelab-creds` |
| Trusted OpenBao configuration operator | Manage reader, issuer and bounded-writer authorization |
| Bounded value writer | Enroll the application credential into one exact OpenBao record; cannot read it |
| Wrapped-SecretID issuer | Introduce the host to its AppRole; cannot read the application credential |
| Host AppRole | Read only its application credential record, using short-lived runtime tokens |
| Application S3 publisher | GetObject/PutObject for exactly `kubeconfig.yaml` in this cluster's configuration bucket |
| Application backup account | Inventory its dedicated backup bucket and read/write/logically retire only `snapshots/*`; no version purge |

The publisher account has no backup-bucket, bucket-management, listing or
deletion grant. Credential issuance and value enrollment happen outside OpenTofu.
Neither credential values nor the kubeconfig belong in state, plans or cloud-init.
The host receives no operator credential.

Both buckets use versioning and default AES256 server-side encryption. Neither has an
anonymous access grant. Verify anonymous denial and an actual administrator
content download during qualification; listing or metadata access is not enough.
Both are protected against managed destruction. Versioning is not a backup
of the RKE2 server token; retain that token separately in its existing recovery
custody. Treat every kubeconfig version as an administrator credential.

## Prepare and provision

Requires OpenTofu 1.11+, the existing AppRole mount and KV-v2 engine, and trusted
HTTPS endpoints. The AWS provider is used only for its S3-compatible resources,
with path-style requests and no IAM/STS discovery. RustFS IAM uses its native API,
not AWS IAM resources.

Copy `terraform.tfvars.example` to an ignored private `terraform.tfvars`. Fill
the required stable `cluster_name` and certificate-covered API identity. Use two
to forty lowercase name characters, starting with a letter and ending in a letter
or digit. If a suffix is needed for uniqueness, choose it once and retain it.
Do not generate a new name during VM replacement. `cluster_uid` is optional
observed identity evidence for standalone existing-server publication; automatic
bootstrap obtains it from Kubernetes in the guest. It never affects storage names
or credential scope. Use provider-native workstation authentication from
`homelab-creds`; clear unrelated AWS session/profile/endpoint overrides.

```bash
make init
make validate
```

These commands install providers and validate locally. They do not deploy or
prove authorization. After separate approval, use the canonical checkout and
this root's protected state to create a fresh saved plan, inspect it privately,
and apply only that unchanged plan. Do not import or adopt a policy/bucket owned
elsewhere without a separately reviewed ownership change.

`make plan` saves `deployment.tfplan`; inspect it privately with `tofu show`
before running `make apply`. Both targets accept `PLAN_FILE` overrides. The apply
target requires an existing saved plan and never creates one implicitly.

Export the sensitive `publisher`, `backup`, `storage`, `publisher_value_enrollment` and `enrollment`
outputs into private files with `umask 077`. They contain scope and enrollment
metadata, not credentials. Keep exact deployment locators out of shared logs.

## Issue and enroll an application credential

From the Kubernetes service directory:

```text
python3 -B scripts/issue-publication-credentials.py \
  --scope <private-publisher-output> --expires-at <approved-UTC-expiry> \
  --output-directory <new-private-custody-directory>
```

- All three arguments are required. The expiry is an explicit ISO-8601 UTC time.
- Default behavior is plan-only: no operator lookup, API calls or custody writes.
- `--execute` issues the credential through native RustFS service-account APIs.
- `--credential-helper` selects the executable; default: `homelab-creds`.
- `--purpose backup` consumes the `backup` scope instead and writes the lower-case
  backup credential schema. The default `publication` purpose consumes `publisher`.
  Always issue two different accounts; the helper rejects cross-bucket scopes.
- The custody directory must be new, under an owned private directory. The helper
  saves the generated pair before issuance, then records the HTTP result and
  verifies the account's exact explicit policy. It never overwrites custody.

Exit zero after execution means the issuer confirmed the pair and its policy.
Before enrollment, require `scope-verified.json`. If issuance or inspection fails,
preserve the directory: the account may already exist. Inspect its exact access
key using the native API before deciding to revoke it or issue another account.
Do not blindly rerun with another directory. A denied creation needs the native
`add-service-accounts` operation; a denied verification needs
`info-service-account` for the issued account, not broad administrator access.

Use the shared [bounded writer helper][writer] with the exported
`publisher_value_enrollment` metadata to issue a short-lived writer and write
`credentials.json` into `publisher_secret_path`. The record must contain exactly
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Revoke the writer after enrollment.
Do not enroll the operator pair. Keep the custody pair protected until enrollment
and host access are verified, then handle it under the operator's secret-retention
policy. Deleting a local file does not revoke its RustFS account.

For backup values, use the recovery root's `credential_enrollment.backup` bounded
writer and its `s3_secret_path`. Enroll the separately protected existing server
token with `credential_enrollment.token`. Neither needs the Kubernetes API.
Enroll the `storage` fields with the stable API/registration endpoints in the
recovery runtime profile. The same cluster name must be used in both roots.

### Existing storage is not migrated automatically

Changing `cluster_name`, moving from UID-prefixed storage or adopting a bucket
owned elsewhere is an explicit migration. Existing bucket addresses retain their
destruction guards; a plan that would replace an enrolled bucket must stop.
Do not import, rename, copy or delete old buckets/objects as part of ordinary
bootstrap. Retain their state, contents and token associations. Before adopting
the new target, separately approve and verify either fresh native backups or a
reviewed object transfer into `snapshots/`, including actual retrieval, version
history and token association. A known cluster with no usable backup still stops.

Expiry requires an explicit rotation before that time: issue and verify a new
account, enroll its pair, verify host refresh and publication, then revoke the
old account. This helper does not perform rotation or automatic revocation.

## Host introduction and publication

For standalone publication on an existing initialized server, supply its observed
`cluster_uid` and pass the exact artifacts `enrollment` output as infrastructure
`publication_access`. First creation instead uses [automatic bootstrap](../RECOVERY.md),
which discovers UID in the guest without changing storage scope. Supply an independently verified guest host-key/CA file as
`publication_ssh_known_hosts_file`. The optional
`TF_VAR_publication_issuer_token` is an ephemeral wrapped-SecretID issuer, not an
OpenBao administrator or S3 credential. Enrollment follows [trusted SSH
introduction][ssh-introduction]; first-contact key scanning is not attestation.

The VM always installs fixed tools/units. Enabling publication does not add
metadata to first-boot data: the verified-SSH hook installs non-secret enrollment
metadata separately, then introduces the wrapped SecretID. For the unified
automatic path use [runtime bootstrap enrollment](../RECOVERY.md); its OpenBao
profile and distinct publisher record are fetched after startup. Do not rerun
cloud-init or replace an initialized VM to change operational information.
Absent tools still require separately approved installation. Changing
`publication_enrollment_revision` retries introduction; it does not install files,
rotate an existing SecretID or repair configuration.

### Existing-server installation

First review the canonical infrastructure plan with `publication_access` enabled.
Do not apply a plan that replaces or restarts an initialized VM for publication.
The enrollment hook cannot succeed before the files exist. It may fail during
the first authorized apply without replacing the VM; complete this installation
and retry only the separate enrollment resource through a fresh reviewed plan.

Export `publication_host_configuration` privately after its metadata is present
in canonical state. If that operation cannot safely establish the output, use
`tofu console` to export that same output expression privately, not a second
state or a guessed configuration. Check the published cluster UID and stable API
identity against the existing cluster before installing anything.

Transfer the reviewed Kubernetes service source and that non-secret metadata
over independently verified SSH. On the guest, enter the service source directory
and assign `HOST_CONFIGURATION` to the protected metadata file. After explicit
maintenance approval, reject existing metadata files or symlinks and preserve any
existing installation for a separately reviewed update. As root, stop on any
failure:

```bash
set -euo pipefail
umask 077
test ! -e /etc/rancher/rke2/publication-openbao.json
test ! -L /etc/rancher/rke2/publication-openbao.json
test ! -e /etc/rancher/rke2/publication.json
test ! -L /etc/rancher/rke2/publication.json
dnf install -y jq python3 curl
install -D -o root -g root -m 0644 scripts/kubernetes_object_store.py \
  /usr/local/libexec/homelab/kubernetes_object_store.py
install -D -o root -g root -m 0644 scripts/kubernetes_recovery.py \
  /usr/local/libexec/homelab/kubernetes_recovery.py
install -D -o root -g root -m 0700 scripts/install-enrollment.py \
  /usr/local/libexec/homelab/install-enrollment.py
install -D -o root -g root -m 0700 scripts/publish-kubeconfig.py \
  /usr/local/libexec/homelab/publish-kubeconfig.py
install -D -o root -g root -m 0700 scripts/kubeconfig-credentials.sh \
  /usr/local/sbin/kubeconfig-credentials
install -o root -g root -m 0644 config/kubernetes-publication-credentials.service \
  config/kubernetes-publication-credentials.timer \
  config/kubernetes-kubeconfig-publication.service /etc/systemd/system/
jq -e .openbao "$HOST_CONFIGURATION" > /etc/rancher/rke2/publication-openbao.json
jq -e .publication "$HOST_CONFIGURATION" > /etc/rancher/rke2/publication.json
chmod 0600 /etc/rancher/rke2/publication-openbao.json /etc/rancher/rke2/publication.json
printf '%s\n' 'd /run/kubernetes-publication-credentials 0700 root root - -' \
  > /etc/tmpfiles.d/kubernetes-publication.conf
restorecon -RF /usr/local/libexec/homelab /usr/local/sbin/kubeconfig-credentials \
  /etc/rancher/rke2/publication-openbao.json /etc/rancher/rke2/publication.json \
  /etc/systemd/system/kubernetes-publication-credentials.service \
  /etc/systemd/system/kubernetes-publication-credentials.timer \
  /etc/systemd/system/kubernetes-kubeconfig-publication.service \
  /etc/tmpfiles.d/kubernetes-publication.conf
systemd-tmpfiles --create /etc/tmpfiles.d/kubernetes-publication.conf
systemctl daemon-reload
```

These are installation commands, not unattended repair. Do not overwrite an AppRole,
application credential, RKE2 configuration, token or kubeconfig. Verify that the
source revision matches the exported implementation fingerprint and that the
existing RKE2 configuration matches its declared fingerprint. Run
`kubeconfig-credentials check` with the exported `config_sha256`; exit ten means
the configuration is accepted and introduction is still required, not a broken
cluster. Other failures require inspection before enrollment. No RKE2 restart
is required. Resume the separately reviewed enrollment plan only after these
checks; the timer, reader login and actual object retrieval still need acceptance.

The separate hook waits for cloud-init, checks both metadata fingerprints over
verified SSH, and introduces a short-lived response-wrapped SecretID on stdin.
The host checks its exact creation path, unwraps once and stores a reusable
root-only AppRole SecretID. Runtime tokens are short-lived and renewed or replaced.
The credential timer fetches the application pair and starts publication every
five minutes. Failures remain failures and retry on the timer; no administrative
credential fallback exists.

The publisher requires SELinux enforcing, the declared initializer configuration,
a running non-joining RKE2 server, a ready local API and a matching kube-system UID.
Non-initializers skip before kubeconfig or credential reads. The fixed runtime
overlay is accepted only when its hash matches the recorded bootstrap decision;
other RKE2 fragments or an unmanaged configuration path fail closed.
The exported native certificate-based kubeconfig uses the stable API identity.

Normal writes use `If-None-Match: *`. An identical existing object is downloaded
and accepted without overwrite. Different contents fail; nothing silently
refreshes an existing administrator credential. Successful writes are downloaded
again and compared. After an approved certificate/configuration refresh, run the
publisher manually with `--execute --refresh-from-sha256 <approved-old-content-hash>`.
It downloads the existing object, checks that hash and updates only its matching
ETag. Concurrent changes fail rather than being overwritten.

### Command and health reference

`scripts/publish-kubeconfig.py` defaults to plan-only. `--config`,
`--credentials-file`, `--kubectl` and `--kubeconfig` override the installed guest
paths; use `--help` for their exact defaults. `--wait-seconds` bounds server/API
readiness from one to nine hundred seconds, default one hundred eighty.
`--execute` requires root. Exit zero means skip, plan, verified unchanged contents
or verified publication, distinguished by its short output; nonzero means failure.
No credential or child-command diagnostics are printed.

Inspect `kubernetes-publication-credentials.timer`,
`kubernetes-publication-credentials.service` and
`kubernetes-kubeconfig-publication.service` on the guest. A successful refresh
alone is not proof of administrator access: download the actual object with the
intended administrator identity and use its retained TLS verification to verify
the expected cluster UID through the stable endpoint.

Enrollment and publication do not modify etcd, retrieve snapshots, rotate the
server token or restart RKE2. Existing workers and the API endpoint remain owned
by their current lifecycle. Production rollout and replacement need separate
authorization and qualification; local validation is not deployed acceptance.

[writer]: ../../../modules/openbao-deployment-access/README.md#protected-credential-operations
[ssh-introduction]: ../../../docs/adrs/011-ssh-approle-enrollment.md
