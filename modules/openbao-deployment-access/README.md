# Service Deployment Access

Call this module from the owning service's **administrative authorization** root
or stage. Pass its exact name and KV-v2 data paths. The provider must use the
trusted configuration identity; never the deployment token this module defines.
The module does not enable a KV engine, populate values or issue credentials.

It defines `<name>-deploy`, a create/update-only record policy and a non-renewable
token role. The constrained issuer and helper require both `ttl=900s` and
`explicit_max_ttl=900s` on every issuance. No default policy is attached.
`<name>-issuer` can mint only that role with exactly its deployment policy and
fixed issuance parameters. It cannot manage roles/policies, read
records, mint readers or request orphan tokens. Tokens remain children of their
issuer. Both identities may inspect/revoke themselves; neither can renew itself.

OpenBao 2.7.2 can return a token with `explicit_max_ttl=0` even when the role's
`token_explicit_max_ttl` is 900. Do not infer the issued-token cap from that role
field alone. The explicit request parameter is enforced by the issuer ACL and
verified through token self-lookup in the isolated real-server test. Trusted
administrators issuing directly must also supply `explicit_max_ttl=900s`.

`enrollment` returns names and paths, never tokens. Add the service-owned HTTPS
endpoint to this metadata and export it privately for
`scripts/service-credentials.py`. Issue credentials only after the
administrative plan is reviewed/applied. Existing policy-name collisions fail
instead of being silently adopted; inspect token-role ownership too before apply.

When upgrading from the earlier helper, review/apply the issuer-policy update
before using the new request shape. An older policy rejects the additional
parameter, and the updated policy rejects requests that omit it; neither has a
compatibility fallback. Existing issued tokens are not changed or revoked by
this update. No value reads, workload reader-policy changes or pod restarts are
needed. Obtain explicit authorization for each consuming root's saved plan.

Runtime read policies and auth roles remain service-owned but administrative.
See [ADR 008][decision] for the refresh/security trade-off and Kubernetes limits.

## Protected Credential Operations

After an authorized administrative apply, export the consuming root's enrollment
output into a private file. For Kubernetes qualification, from its canonical runtime root:

```bash
umask 077
tofu output -json secrets_qualification_enrollment > /protected/enrollment.json
```

An administrator can mint a writer directly through the named token role, or
delegate the exact `issuer_policy` to a short-lived operator credential with no
other policies or entity/group grants. Do not give issuer credentials to pods.
From the repository root:

```bash
python3 -B modules/openbao-deployment-access/scripts/service-credentials.py \
  --enrollment /protected/enrollment.json \
  --token-file /protected/issuer-token \
  issue --output /protected/deployment-token
```

All commands require `--enrollment PATH` and `--token-file PATH` before the
subcommand. Inputs must be operator-owned private regular files, not symlinks.
The enrollment supplies the service-published HTTPS origin, exact role/policy
names and owned KV-v2 paths. There is no lookup of another service's state.

- `issue --output PATH` creates a new mode-`0600` raw token file; never overwrites.
  Its parent must be operator-owned and not group/world-writable. The helper
  verifies the returned policy/lifetime and attempts revocation if validation or
  saving fails. Reissue explicitly after failure; there is no broad fallback.
- `write --secret-path PATH` uses the writer credential and reads a nonempty JSON
  object from stdin (maximum 1 MiB), without reading existing values. Use a
  protected input file or pipe, never literal values in argv/history. The entire
  declared record is replaced: this is not a schema validator, automatic merge,
  CAS-based writer or rotation manager. Maintain a single-writer/rotation procedure
  and dispose of populated input files through the owning service's runbook.
- `revoke` revokes the supplied credential itself. Revoking an issuer also revokes
  its non-orphan children. Expired/revoked credentials require fresh issuance,
  not renewal or administrative fallback for value enrollment.

The writer cannot read values/metadata, list, patch, delete, manage authorization
or mint tokens. Removing a token role blocks new issuance, not existing tokens;
revoke them or wait for expiry. Removing its ACL removes access. Neither deletes
the records. Rotation requires a separately reviewed identity, not broader reader rights.

The helper prints generic success/failure only. Never enable shell tracing,
`TF_LOG`, HTTP debug output or CLI token caching. Tokens and values must not enter
OpenTofu resources, argv, state, plans or logs. OpenBao ACL separation does not
isolate data from host root, CSI administrators or control of reader pods.

## Validation

Run `make -C modules/openbao-deployment-access validate` from the repository root.
The explicitly enabled real-server suite is:

```bash
make -C modules/openbao-deployment-access deployment-auth-test \
  BAO_TEST_BINARY=/path/to/verified/bao
```

It requires OpenBao 2.7.2 and starts an in-memory loopback-only server with
synthetic credentials. It applies this grant module and the two Vault resource
blocks from the shared `modules/kubernetes-openbao-access` implementation, then
checks denials, native refresh/drift repair and protected enrollment. No service
implementation, state or production inputs are read. Normal unit validation skips
this opt-in suite.

[decision]: ../../docs/adrs/008-openbao-administrative-authorization.md
