# Runtime bootstrap access

This OpenBao-only administrative root owns the host's exact record-reader and
wrapped-introduction authorization. It is independent of Kubernetes and of VM
installation. It has no create/join/restore selector, snapshot key or VM resource.
All values are enrolled through protected API operations, never Terraform.

Copy the commented example privately. Use existing AppRole/KV-v2 mounts and
configuration-operator `VAULT_TOKEN` over verified HTTPS. `make init` and
`make validate` are local preparation. For an approved deployment, run only from
canonical `main` using this root's existing state: `make plan`, inspect the saved
plan privately, then `make apply` on the unchanged plan. Both accept `PLAN_FILE`;
apply refuses a missing plan. Review policy/role ownership before creation.

## Five exact records

| Record reference | Contents |
| --- | --- |
| `config_path` | Runtime profile below; no credentials or lifecycle switches |
| `identity_path` | Existing cluster's `cluster_uid`, `ca_certificate`, `rke2_version`, `token_hash`; absent only before genuine first creation |
| `server_token_path` | `server_token`; retain the existing matching token |
| `s3_secret_path` | Dedicated backup application `access_key_id`, `secret_access_key` |
| `publication_secret_path` | Separate publisher `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

The runtime profile contains `api_server`, `registration_server`, `backup` and
`publication`. Each storage object contains only `endpoint`, `bucket`, `region`.
Use the same published cluster DNS identity for API and registration, and different
snapshot/configuration buckets. Populate published endpoint values privately.
Initial snapshot discovery needs authenticated current-object and version-history
inventory; existing-cluster recovery needs listing and object/metadata retrieval
in its cluster namespace. Keep backup and publisher credentials application-scoped,
not workstation operator credentials. Existing backup retention permissions remain
owned by the backup workflow, not this OpenBao authorization root.

`configuration_enrollment` grants a bounded writer access only to the runtime
profile. Use the shared [protected value helper][writer] and revoke its writer
after enrollment. Server-token and S3 value custody remain with their existing
service-owned enrollment procedures. Preserve independent recovery copies.

The host reads these exact records with short-lived AppRole tokens and attempts
self-revocation. To record first cluster identity, it can mint only a one-minute
writer whose ACL requires KV-v2 CAS zero on the identity record. That separate
token cannot read, rewrite existing identity, or write credential/configuration
records. The administrative setup cannot populate application values through state.
The new nested CAS constraint needs live denial/lifetime qualification on `main`.

Export `enrollment` privately as the VM root's `bootstrap_access` input; it feeds
only the apply-time verified-SSH hook, never cloud-init or VM installation assets.
Provide verified host keys and an ephemeral exact-role issuer as described in
[RECOVERY.md](../RECOVERY.md). The standalone `scripts/enroll-bootstrap.py` remains
available for explicitly approved manual introduction. `issuer_policy` can mint
only a short-lived wrapped SecretID for that AppRole. Introduction, runtime profile
changes, credential rotation and snapshot discovery do not alter any VM asset.

See [RECOVERY.md](../RECOVERY.md) for single-server ownership/fencing, automatic
discovery, safe retries and acceptance. No production deployment, native restore
or reader/writer API success follows from offline validation alone.

[writer]: ../../../modules/openbao-deployment-access/README.md#protected-credential-operations
