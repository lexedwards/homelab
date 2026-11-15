---
name: Introduce machine credentials through trusted SSH orchestration
status: accepted
---

# Introduce Machine Credentials Through Trusted SSH Orchestration

## Context

Proxmox and Incus guests have no established platform identity for OpenBao.
Single-use AppRole credentials would require another enrollment controller to
recover autonomously after a prolonged outage, adding disproportionate homelab
maintenance for one operator.

## Decision

Use the trusted deployment orchestrator and verified SSH to deliver a
response-wrapped, reusable, non-expiring SecretID for a service-scoped AppRole.
Keep authorization declarative, cloud-init non-secret, credentials root-only on
the consumer, and runtime tokens short-lived; activate services only after their
required secrets have been obtained.

## Consequences

- This deliberately trades single-use SecretIDs for autonomous reauthentication
  without another controller. SecretIDs require explicit rotation and revocation.
- Wrapping tokens remain short-lived and single-use. Neither they nor SecretIDs
  enter OpenTofu state, plans, cloud-init, command arguments or logs.
- Enrollment failure must not taint a VM for replacement. Enrollment is not an
  alternative package/configuration owner or a recurring deployment repair loop.
- No guest-agent credential transport is introduced. Existing address discovery
  remains separate. OpenBao still requires manual unseal after its restart.
