# OpenBao Platform Authorization

This separate administrative root owns the shared `approle` authentication mount.
The hosting root remains independent of OpenBao API availability. Consumer services
own their policies and AppRoles; this root creates no identities or secret values.

Use OpenTofu 1.11+ and the published hosting-root HTTPS endpoint, never its private
state. Supply `TF_VAR_configuration_token` through protected process injection using
the trusted administrative identity. It is ephemeral and must be supplied for both
an authorized plan and its apply. Never put it in tfvars or enable tracing/debug logs.

```bash
cp terraform.tfvars.example terraform.tfvars
make init
make validate
```

Initialization/validation are local. An API plan/apply requires a separately
authorized, unsealed server. If `approle` already exists, inspect its owner and
settings first; do not create another owner or disable it to make creation pass.
An approved adoption uses a protected state backup and native import:

```bash
tofu import vault_auth_backend.approle approle
tofu plan -out=authorization.tfplan
tofu show authorization.tfplan
tofu apply authorization.tfplan
```

Apply only the reviewed, unchanged saved plan from canonical `main` and this root's
own state. Reject unrelated authorization changes. `prevent_destroy` guards the
mount while its declaration remains; it is not protection against removing the
declaration or direct API writes. Disabling this mount breaks every consumer and
revokes its authentication leases.

Publish `tofu output -raw approle_mount` privately to consumers alongside the
hosting root's endpoint export. Neither output grants access or contains tokens.
This root does not initialize, unseal, populate a KV engine, issue SecretIDs or
authorize live enrollment.
