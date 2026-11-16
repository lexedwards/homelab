# OpenBao Accounts

This root owns identity metadata and policy assignments for people, systems and
machine accounts without another service's IaC owner. It currently manages only
the named personal administrator. Service-specific roles and policies remain in
their service roots. No future CI/CD identity is provisioned; machine automation
must use a separate identity, never the operator's password.

## Credential Boundary

Use OpenTofu 1.11+ and Vault provider **5.13.0**. Its dedicated
`vault_userpass_auth_backend_user` resource has write-only password attributes,
but its schema requires exactly one password/password-hash input. It is not a
password-free metadata resource. We intentionally do not send either through
OpenTofu, even as an ephemeral value.

Instead, `vault_generic_endpoint.operator` manages only token metadata on
`auth/<userpass-mount>/users/<operator>`. OpenBao 2.7.2 accepts metadata-only updates
for an **existing** user and never returns its password/hash from that endpoint.
The password must be enrolled out of band before import. Native refresh stays
enabled; `ignore_absent_fields` ignores API fields this resource does not own,
not drift in configured fields. The resource neither reads secret values nor
handles password rotation. `prevent_destroy` and `disable_delete` prevent routine
account deletion; removing state does not revoke existing sessions.

See the [pinned resource implementation][user-resource] and
[generic endpoint implementation][generic-resource]. Password changes remain
operator operations; changing metadata must not reset the password.

## Bootstrap The Named Administrator

This is a separately authorized credential-enrollment operation, not part of
validation or a deployment dependency. First complete [hardening] with the
original root token. Keep independent unseal shares in their separate custody.
Generate a strong, unique password in **Proton Pass** and save it there before
enrollment. Do not store it in OpenBao itself as the only recovery copy.

While still authenticated with the original root token, create the personal
user once in a private Bash terminal. Supply the published mount/policy names
and personal username as non-secret selectors. Verify that this username does
not already exist; if it does, stop for adoption rather than overwrite a password.

```bash
set +x
operator='<operator>'
userpass_mount='<published-userpass-mount>'
administrator_policy='<published-administrator-policy>'
IFS= read -r -s -p 'Password from Proton Pass: ' password
printf '\n'
printf '%s' "$password" | bao write "auth/$userpass_mount/users/$operator" \
  password=- token_policies="$administrator_policy" \
  token_no_default_policy=true token_ttl=3600 token_max_ttl=28800 token_type=service
unset password
```

The CLI reads the password from stdin, not argv or an exported variable. Do not
run this in an agent transcript or recorded/debug terminal. On uncertain failure,
inspect account existence privately before retrying; do not blindly overwrite it.

Now clear token environment overrides and perform a fresh non-root login:

```bash
unset VAULT_TOKEN BAO_TOKEN
bao login -method=userpass -path="$userpass_mount" -no-print username="$operator"
export VAULT_TOKEN="$(bao print token)"
bao token lookup -format=json | jq -e \
  '.data.policies | (index("root") == null)' > /dev/null
```

Login prompts for the password and replaces the cached session token. It does not
export `VAULT_TOKEN`; the explicit captured export is for OpenTofu. Use the same
verified HTTPS origin for `BAO_ADDR` and the roots' `openbao_address` input. Disable
shell tracing, `TF_LOG` and provider HTTP debug logs. Do not leave a stale
`BAO_TOKEN` override selected while testing another identity.

## Adopt And Verify With Non-Root Administration

Populate ignored `terraform.tfvars` from the example, using the published
hardening outputs. This root does not read either sibling's state.

```bash
cp terraform.tfvars.example terraform.tfvars
tofu init -lockfile=readonly
make validate
tofu import vault_generic_endpoint.operator "auth/$userpass_mount/users/$operator"
tofu plan -out=accounts.tfplan
tofu show accounts.tfplan
tofu apply accounts.tfplan
```

Run persisted operations only from canonical `main`. Review existing metadata
before adoption and inspect the exact plan; reject password fields or unrelated
changes. Import reads only metadata. If no metadata changes are proposed, a no-op
apply proves no write: separately authorize a reversible metadata update and
revert to demonstrate administrative writes before retiring root access.

With that fresh non-root session, also verify hardening refresh/plan and the
required warehouse/Kubernetes authorization operations under their own acceptance
authorization. Do not substitute `token capabilities` output or local fixtures
for actual required read/write acceptance. Application-secret reads, enrollment,
S3 readiness and worker readiness remain separate operations.

Sessions have a one-hour initial TTL and an eight-hour configured maximum, subject
to mount limits. Renew before expiry or log in again. A valid, sufficiently
privileged `VAULT_TOKEN` is required for both plan and saved-plan apply. Remove old
`TF_VAR_configuration_token` and `TF_VAR_openbao_admin_token` injection from
operator setup; service-specific enrollment-issuer inputs remain unchanged.

## Explicitly Revoke The Original Root Token

Only after fresh non-root administrative acceptance and a separate revocation
authorization, switch back to the **original** token from protected bootstrap
custody. Prefer multiple people observing this short root session.

```bash
unset VAULT_TOKEN BAO_TOKEN
bao login -no-print
export VAULT_TOKEN="$(bao print token)"
test "$(bao token lookup -field=accessor)" = "$(cat /protected/initial-root.accessor)"
```

Stop on a failed identity check. With the checked original root token still
selected, explicitly run:

```bash
bao token revoke -self
unset VAULT_TOKEN BAO_TOKEN
bao login -method=userpass -path="$userpass_mount" -no-print username="$operator"
export VAULT_TOKEN="$(bao print token)"
```

`revoke -self` revokes the currently authenticated token. Running it with the new
administrator token would **not** revoke the original root token. Verify the old
accessor no longer resolves using the new administrator, without printing token
material, and retire cached/custody copies under the operator's retention policy.
Deleting a token copy alone is not revocation. Never revoke unseal shares or
collapse their independent custody. Emergency root generation remains a separate
quorum-operated recovery procedure, not an ongoing OpenTofu credential source.

[hardening]: ../hardening/README.md
[user-resource]: https://github.com/hashicorp/terraform-provider-vault/blob/v5.13.0/internal/vault/auth/userpass/user_resource.go
[generic-resource]: https://github.com/hashicorp/terraform-provider-vault/blob/v5.13.0/vault/resource_generic_endpoint.go
