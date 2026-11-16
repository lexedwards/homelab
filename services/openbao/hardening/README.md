# OpenBao Hardening

This administrative root owns the shared `approle` and `userpass` authentication
mounts and the `openbao-administrator` ACL policy. The [init root] remains independent
of OpenBao API availability. Consumer services own their policies and roles;
[accounts] owns identities without another service owner.

## Prepare

Use OpenTofu 1.11+ and the published init-root HTTPS endpoint, never its private
state. Migrate any former `authorization/` state using the [layout migration]
**before** initializing this directory. Existing AppRole ownership is preserved.

```bash
cp terraform.tfvars.example terraform.tfvars
tofu init -lockfile=readonly
make validate
```

Provider initialization and validation do not configure the server. An API
plan/apply requires a separately authorized, initialized, unsealed server.

## First Administrative Bootstrap

Only this initial stage uses the original root token. In a private terminal,
disable shell tracing and OpenTofu/provider HTTP debug logging. Prefer a second
person observing the root-token session. Do not copy tokens into arguments,
tfvars, plans, cloud-init, logs or issue discussions.

After explicit authorization, authenticate interactively and bridge the cached
CLI token to the provider's native environment channel:

```bash
set +x
unset BAO_TOKEN VAULT_TOKEN
export BAO_ADDR='<published-verified-https-origin>'
bao login -no-print
export VAULT_TOKEN="$(bao print token)"
```

The login prompts for the root token. The token helper caches it;
`bao login` does **not** export `VAULT_TOKEN`. `bao print token` is captured here,
not printed to the terminal. Keep the original root token in its protected
bootstrap custody until explicit revocation. Record its accessor privately for
the later identity check, not in OpenTofu or Git:

```bash
umask 077
bao token lookup -field=accessor > /protected/initial-root.accessor
```

Inspect ownership before creating mounts or policies. If an object already exists
outside the migrated state, stop for an explicit adoption decision and protected
state backup; do not disable a mount or force policy overwrite. An authorized
adoption uses native import into this sole owner, for example:

```bash
tofu import vault_auth_backend.approle approle
```

Do not import an object already present in the migrated state. Then generate and
inspect a fresh saved plan from canonical `main` using this root's own state:

```bash
tofu plan -out=hardening.tfplan
tofu show hardening.tfplan
tofu apply hardening.tfplan
```

Apply only that unchanged, reviewed plan. Keep `VAULT_TOKEN` valid and privileged
through both plan and saved-plan apply; it is not recovered from the saved plan.
`skip_child_token = true` prevents automatic provider child-token issuance.
Remove obsolete `TF_VAR_configuration_token` injection from operator setup.

Publish `approle_mount`, `userpass_mount` and `administrator_policy` outputs to
their consumers explicitly, without granting access to this state. These names
are not credentials. Continue with the [accounts bootstrap][accounts] to establish
and verify non-root administration, then explicitly revoke the original root.

## Ongoing Administration

After bootstrap, authenticate using the named personal userpass account and
export its cached token as described in [accounts]. Do not generate root tokens
for routine hardening plans/applies. The administrator can manage auth methods,
secret-engine mounts, ACL policies, identities and auth/token roles. The policy
does not directly grant secret-value reads, Raft recovery, seal/unseal or
generate-root access. An ACL author can grant more privileges: this is a trusted
administrative identity, not a hostile-administrator security boundary.

Mounts and policy are destruction-guarded while their declarations remain.
Disabling a mount can revoke consumer leases; removing the policy can lock out
administrators. These guards do not protect against direct API writes or deleting
declarations. Preserve independent unseal custody and emergency recovery access.

[init root]: ../init/README.md
[accounts]: ../accounts/README.md
[layout migration]: ../README.md#preserve-existing-local-state
