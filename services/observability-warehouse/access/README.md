# Warehouse OpenBao Access

This administrative root declares one service AppRole, an exact KV-v2 reader
policy and a wrapped-SecretID issuer policy. It does not create the shared AppRole
mount or KV engine, read/write application values, or issue credentials.

## Prepare And Apply

Use OpenTofu 1.11+. Supply the published OpenBao HTTPS endpoint and platform-owned
AppRole mount, plus the exact existing KV-v2 data path. The dedicated record must
contain string fields `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Keep value
enrollment separate and protected; do not add a secret value resource/data source.

Inject the trusted administrative credential through ephemeral
`TF_VAR_configuration_token`, not tfvars. Supply it for authorized planning and
applying. Do not give that credential to the guest or ordinary deployment process.

```bash
cp terraform.tfvars.example terraform.tfvars
make init
make validate
tofu plan -out=access.tfplan
tofu show access.tfplan
tofu apply access.tfplan
```

The last three commands require separate API authorization. Use canonical `main`
and this root's authoritative state. Inspect existing policy/role names before
creation; existing objects require an explicit ownership/adoption decision, not
silent overwrite. Policy-name collisions fail closed. Keep native provider refresh
enabled and review all proposed changes.

Export the non-secret enrollment object privately into the infrastructure root's
`warehouse_openbao_access` input. No cross-root state access is required. A scoped
deployment identity receives only `tofu output -raw issuer_policy`, without other
token/entity/group grants. The issuer can issue SecretIDs only for this role and
only with a wrapping TTL between one and five minutes; it cannot read the record,
read RoleID, change authorization or mint ordinary reader tokens.

## Credential Lifecycle

Per the [SSH enrollment decision], SecretIDs are reusable and non-expiring,
deliberately trading single-use bootstrap credentials for autonomous recovery.
Each enrolled guest retains its own root-only SecretID/accessor. Reader tokens
have a fifteen-minute TTL and a one-hour configured renewal maximum. They have no
default policy, only the record read and token self-renew/revoke permissions.

Rotate/revoke SecretIDs explicitly with administrative authorization. Use the
accessor stored in the guest's protected `approle.json` with OpenBao's native
SecretID-accessor destruction API; do not expose the SecretID itself. Revoking a
SecretID blocks new logins, not tokens already issued from it. Revoke those tokens
separately or allow expiry. Removing a role/policy is not a one-guest rotation.

Coordinate credential retirement before destroying a guest or restoring/cloning
its disk. Backups containing the SecretID are credential copies. The deployment
hook intentionally does not overwrite an existing credential or revoke identities
as a destroy-time side effect. Rotation/adoption requires a separately reviewed
procedure, not deletion of working files to force first-boot provisioning.

[SSH enrollment decision]: ../../../docs/adrs/011-ssh-approle-enrollment.md
