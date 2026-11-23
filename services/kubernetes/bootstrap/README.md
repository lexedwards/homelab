# Independent cluster bootstrap

This OpenTofu root owns the prerequisites that must survive loss of Kubernetes:
two RustFS buckets and exact OpenBao bootstrap/identity/value-enrollment access.
It replaces the separate artifacts and recovery-authorization roots. It has no
Kubernetes provider or dependency on infrastructure state.

## Setup and ownership

Choose a stable friendly `cluster_name`. This root declares
`<cluster-name>-backups` for `snapshots/` and `<cluster-name>-configuration` for
exactly `kubeconfig.yaml`. Both are versioned, encrypted and destruction-guarded.
They are cluster resources on existing external services, not RustFS/OpenBao
service deployments. Native S3 environment variables and `VAULT_TOKEN` provide
administrative authentication; never put values in tfvars or resource arguments.

Copy `terraform.tfvars.example` privately. Supply the verified HTTPS endpoints,
existing AppRole mount and five distinct exact KV-v2 paths. The administrator
needs exact identity-metadata creation/update permission; broad KV value access
is not a substitute. No KV engine, administrator identity or shared key is created.

From canonical `main`, run `make init`, `make validate`, then review an authorized
`make plan`. Apply only that unchanged `PLAN_FILE` with credentials still valid.
New roots must not adopt old records/buckets implicitly. Retain old snapshots and
their matching actual tokens until their separately approved disposition.

## Protected values and exported contracts

| Record | Contents |
| --- | --- |
| `config_path` | Runtime profile: cluster name, stable API/registration origins, backup/publication targets and optional native snapshot settings |
| `identity_path` | Observed cluster UID, CA, qualified RKE2 version and token association; absent only for genuine first creation |
| `server_token_path` | Initial or preserved actual server token |
| `s3_secret_path` | Backup application credential pair |
| `publication_secret_path` | Separate publisher application credential pair |

`storage` exports the cluster name and both target objects. Combine these with
the reviewed API/registration endpoints to enroll the runtime profile.
`publisher` and `backup` export independent exact application policies. Use
`../scripts/bootstrap/issue-storage-credentials.py --help` for protected out-of-band
account issuance; it supports both purposes and verifies actual scope/expiry.
Do not back a durable schedule with temporary qualification credentials.

`configuration_enrollment`, `credential_enrollment` and
`publisher_value_enrollment` export bounded writer/issuer metadata. Mint and revoke
their tokens and enroll actual values using the shared
[protected value helper](../../../modules/openbao-deployment-access/README.md#protected-credential-operations).
No value is read/written through Terraform. Preserve independent token and
retrieval-credential custody; fingerprints are not recovery material.

`enrollment` supplies infrastructure's `bootstrap_access`; `issuer_policy` permits
only response-wrapped SecretID introduction to that exact AppRole. The host reader
uses short-lived tokens. First identity registration uses a separate one-minute
CAS-zero-only writer; it cannot overwrite identity or rotate credentials. Retained
identity history blocks a deleted record from being mistaken for a new cluster.

## Publication and refresh

After native startup, integrated completion verifies actual cluster identity,
enrolls the native backup S3 Secret and invokes the application-scoped publisher.
Workers/joiners do not publish. The source kubeconfig is untouched; the exported
copy uses the stable API origin with certificate verification enabled.

First publication is create-only and identical retries are accepted. A changed
existing object is a collision, not permission to overwrite. For a separately
approved refresh, obtain the old object through administrator content access,
record its SHA-256 privately, and pass `--refresh-from-sha256` to the installed
`publish-kubeconfig.py --execute` with the existing protected target/credential
files. The publisher verifies the old content hash, uses its live ETag as an
If-Match condition, then downloads and verifies the new contents. On conflict,
stop and inspect; do not retry with a guessed fingerprint or delete the object.

## Recovery and lifecycle

Native RKE2 owns scheduling/upload/pruning; defaults are a six-hour cron and
local/remote counts of 5/56. Restore obtains the matching token and backup pair
directly from external OpenBao, without a Kubernetes API or in-cluster Secret.
See [recovery](../RECOVERY.md) and [backups](../BACKUP.md).

This root must persist through compute replacement. Deleting a bucket, all object
versions, identity history or retained token associations requires a separate
reviewed retirement scope. External OpenBao/RustFS/KMS outages safely block
recovery; local-only recovery and application-volume restore are not supplied.
