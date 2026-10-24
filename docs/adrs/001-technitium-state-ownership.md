---
name: Keep Technitium infrastructure and shared configuration in one state
status: accepted
---

# Keep Technitium Infrastructure And Shared Configuration In One State

## Context

The existing Technitium service root owns the Incus instance. Adopting its DNS
configuration could introduce a separate state, but server-wide settings and
shared zones have a different ownership boundary from service-specific records.

## Decision

Keep the Incus instance, supported server settings, and shared zone lifecycle in
the existing Technitium root and state, with logically separated declarations.
Prefer service roots for their own records, with central ownership only for
identified legacy records and exactly one owner per recordset.

## Consequences

- No infrastructure state migration or second central configuration state is
  needed. Full-root plans expose infrastructure and configuration changes together.
- The central root requires administrator access; that does not imply consumers
  need administrator access or share its credentials.
- State ownership does not replace application backups, and record ownership is
  not an API-enforced per-record permission boundary.
