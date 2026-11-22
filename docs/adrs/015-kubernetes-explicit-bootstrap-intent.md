---
name: Require explicit intent before empty-datastore bootstrap
status: superseded by 016-kubernetes-runtime-bootstrap-discovery
---

# Require Explicit Intent Before Empty-Datastore Bootstrap

## Context

An empty replacement server can look like an initial installation. Automatically
initializing it would create a different cluster instead of recovering the
existing identity, even while old workers and usable backups remain.

## Decision

Keep initialized startup separate from explicit creation, joining and recovery.
Default to existing-data startup only; creation requires confirmed absence of
current and historical backups, while recovery requires an approved downloaded
recovery point, its independently protected matching token, compatible inputs and
verified fencing of the old member.

Never overwrite initialized data or fall back from failed recovery to creation.
Retain incomplete recovery evidence and require operator inspection before replay;
use a distinct replacement Kubernetes Node name while preserving VM hostname,
cluster identity, workers and stable endpoints. Apply deployments only from the
canonical `main` checkout and its existing state, keeping development isolation
separate from infrastructure ownership.

## Consequences

- A new empty VM remains blocked until its lifecycle and credential introduction
  are explicit; missing dependencies cannot accidentally create a new cluster.
- Independent [token custody][custody] and a selected recovery point are required
  before destructive replacement, not reconstructed from a snapshot alone.
- Retained versions prevent interpreting logical object deletion as absence.
  Deliberate new clusters alongside old backups need a separate storage decision.
- Recovery failures can need manual investigation rather than unattended replay;
  a published kubeconfig or successful local check is not restore qualification.

[custody]: 007-kubernetes-recovery-custody.md
