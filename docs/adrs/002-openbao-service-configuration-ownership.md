---
name: Keep service-specific OpenBao configuration with its service
status: accepted
---

# Keep Service-Specific OpenBao Configuration With Its Service

## Context

OpenBao provides shared secret engines and authentication backends, while each
service has its own secret paths and access needs. Centralizing every service's
configuration would separate its lifecycle from the service, unlike the existing
service-owned DNS model.

## Decision

Keep service-specific secret paths, supported metadata, policies, and authentication
roles in their owning service roots. Keep shared engines and authentication
backends platform-owned, with exactly one owner for each object. Treat populating
secret values as a separate enrollment operation unless their persistence in
OpenTofu state and saved plans is explicitly accepted.

## Consequences

- Service changes can include their own access configuration without competing
  central writers.
- Service deployment identities need narrowly scoped configuration permissions;
  runtime identities must not be able to alter their own policies.
- OpenBao configuration requires an available, initialized, unsealed server.
  Its hosting and recovery credentials must remain independently accessible.
