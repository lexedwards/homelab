---
name: Keep OpenBao authorization administrative and deployment tokens value-write-only
status: accepted
---

# Keep OpenBao Authorization Administrative

## Context

Services own their OpenBao paths, schemas, policies and Kubernetes auth roles.
That ownership does not make ordinary deployment credentials safe policy authors:
permission to change an ACL policy can grant secret reads or administration.

OpenBao parameter restrictions can pin an approved configuration, but required
parameters also apply to reads. Requiring complete security settings blocks the
stock provider's parameterless refresh requests. Removing the requirements lets
callers omit settings when recreating a role. A write-only provider resource
would instead lose automatic configuration drift detection.

## Decision

The operator selected **admin-owned authorization**, not strict write-only role
management. Keep definitions alongside the service, as ADR 002 requires. Apply
and refresh authorization with a trusted administrative identity. Never pass
that identity to application pods or treat it as an untrusted deployment token.

Ordinary service deployment tokens may create/update only exact approved KV-v2
records. They cannot read values, list metadata, delete records, manage policies
or roles, or mint tokens. Runtime identities may read only their required records.

OpenBao's reusable deployment-access module defines a bounded named token role
and a separate issuer policy. An approved administrator can mint a writer directly
through that role or delegate the issuer policy to an operator identity. Issuance
and value enrollment use protected files/stdin, outside OpenTofu. OpenTofu stores
only definitions and uses ephemeral administrative inputs.

## Consequences

- Authorization changes remain privileged actions, even in a service-owned root.
  A root that manages authorization cannot be planned with its value-writer token.
- Native provider configuration refresh and drift repair remain enabled. There
  is no new configuration provider, broker or production state in this slice.
- The Kubernetes runtime root is already a privileged platform root; it owns its
  synthetic service's authorization and enrollment definitions. Future services
  can separate authorization from ordinary deployment in their own local roots.
- Administrative control is trusted: an administrator who can change ACLs can
  grant additional access. This is not a hostile-administrator isolation boundary.
- Someone who can execute in or replace reader pods can still obtain their mounted
  data. OpenBao token separation does not independently constrain Kubernetes admin
  rights, workload mutation, host root or the trusted CSI platform.
- A rotation service needs a separately reviewed writer identity for its exact
  records. Ordinary workload roles do not gain write access as a convenience.

[Ownership decision](002-openbao-service-configuration-ownership.md).
