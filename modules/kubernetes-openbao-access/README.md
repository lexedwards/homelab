# Kubernetes OpenBao Access

Instantiate this shared module from the owning service's administrative
authorization root. The caller supplies its namespace/account, exact KV-v2
record/field mappings, published OpenBao endpoint and shared cluster auth contract.
The caller owns the resulting read policy, account-bound role, reviewer binding
and SecretProviderClass. Namespace/account and workload resources remain caller-owned.

Provider authentication is inherited from the caller. It must be the trusted
configuration identity for authorization, never the record-writer token. Actual
credentials and values are not module inputs or outputs. The shared implementation
imports no service code, state or deployment configuration.

The Kubernetes provider needs the installed CSI CRD schema during planning.
Install and qualify the platform before planning service instances. The separate
shared [deployment-access module](../openbao-deployment-access/README.md) provides
bounded value enrollment; it does not broaden runtime read permissions.
