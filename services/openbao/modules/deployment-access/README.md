# Service Deployment Access

Call this module from the owning service's **administrative authorization** root
or stage. Pass its exact name and KV-v2 data paths. The provider must use the
trusted configuration identity; never the deployment token this module defines.
The module does not enable a KV engine, populate values or issue credentials.

It defines `<name>-deploy`, a create/update-only record policy and a non-renewable
token role with a 900-second explicit maximum lifetime. No default policy is
attached. `<name>-issuer` can mint only that role with exactly its deployment
policy and fixed issuance parameters. It cannot manage roles/policies, read
records, mint readers or request orphan tokens. Tokens remain children of their
issuer. Both identities may inspect/revoke themselves; neither can renew itself.

`enrollment` returns names and paths, never tokens. Add the service-owned HTTPS
endpoint to this metadata and export it privately for
[`service-credentials.py`][credentials]. Issue credentials only after the
administrative plan is reviewed/applied. Existing policy-name collisions fail
instead of being silently adopted; inspect token-role ownership too before apply.

Runtime read policies and auth roles remain service-owned but administrative.
See [ADR 008][decision] for the refresh/security trade-off and Kubernetes limits.

[credentials]: ../../README.md#service-deployment-credentials
[decision]: ../../../../docs/adrs/008-openbao-administrative-authorization.md
