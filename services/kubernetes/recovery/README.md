# Bootstrap authorization

This OpenBao-only administrative root owns exact host-reader and wrapped-issuer
authorization for a selected RKE2 create, join or restore operation. It does not
need the Kubernetes API. It never owns the backup bucket, server-token values,
application credentials or VM resources.

Use the [guarded bootstrap procedure](../RECOVERY.md) for preparation, enrollment,
fencing and acceptance. Provision this authorization before losing the cluster
API. The existing recovery-custody writer remains separately owned; this root
cannot write or regenerate the existing server token.

## Inputs and workflow

Requires OpenTofu 1.11+, trusted HTTPS OpenBao, its existing AppRole/KV-v2 mounts,
and configuration-operator `VAULT_TOKEN`. Fill the commented example privately.
Use `enrollment_name` as the exact service-owned authorization identity; it is not
an assumed future kube-system UID. Select a lifecycle explicitly:

| Mode | OpenBao reader | Application S3 policy |
| --- | --- | --- |
| `create` | One application credential record; no server token | List current objects and version history in the dedicated backup bucket, to prove absence |
| `join` | Existing secure server-token record only | No S3 credential, bucket or snapshot grant |
| `restore` | Exact snapshot-reader and matching existing token records | GetObject for one approved cluster-scoped snapshot; no listing, writes or deletion |

```bash
make init
make validate
```

These are offline provider/module preparation and validation, not deployments.
For an explicitly approved deployment, use only the canonical checkout on `main`
with this root's existing state. Never create a second owner/state from a feature
worktree or copied root. Save a fresh plan with `make plan`, inspect it privately,
then use `make apply` on that unchanged plan. `PLAN_FILE` overrides the default
`deployment.tfplan`; apply refuses a missing plan.

The `enrollment` output contains non-secret role/record references for
`cluster_bootstrap.access`. `issuer_policy` is only the exact-role wrapped
SecretID issuer. The host uses reusable root-only SecretIDs and one-operation
runtime tokens capped at fifteen minutes, with no default or identity policy;
it attempts self-revocation after fetching inputs. It has no record-write,
authorization-management or arbitrary-secret access.

## Snapshot-reader value enrollment

Export `snapshot_reader` and `snapshot_value_enrollment` privately. From the
Kubernetes service directory, use the maintained native RustFS issuer:

```text
python3 -B scripts/issue-publication-credentials.py --purpose bootstrap \
  --scope <private-snapshot-reader-output> --expires-at <approved-UTC-expiry> \
  --output-directory <new-private-custody-directory>
```

Default behavior is plan-only. After explicit issuance approval, add `--execute`.
The operator credential comes from `homelab-creds` on the workstation; it never
reaches the guest. Require the account's `scope-verified.json` before enrollment.
The output pair uses the existing backup schema, `access_key_id` and
`secret_access_key`, not the configuration publisher's record. Choose expiry to
cover the agreed recovery window and preserve an independently recoverable
application-credential copy. An expired credential blocks recovery, not creation.

Use the shared [bounded value helper][writer] with
`snapshot_value_enrollment` to enroll only that application pair. Revoke its
short-lived writer afterwards. No corresponding module exists in join mode.
Do not enroll operator S3 credentials or copy the server token into this record.
Preserve historical matching token records and independent custody.

There is no automatic migration of the existing runtime custody authorization,
record rewrite, bucket policy, cleanup or production replacement. Verification
of this new path must run from canonical `main` after merge and explicit approval;
local validation does not establish successful snapshot decryption or restoration.

[writer]: ../../../modules/openbao-deployment-access/README.md#protected-credential-operations
