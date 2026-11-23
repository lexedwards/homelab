---
name: Separate Kubernetes bootstrap, infrastructure and runtime ownership
status: accepted
---

# Separate Kubernetes Bootstrap, Infrastructure And Runtime Ownership

## Context

The original cluster was explicitly declared disposable and retired before a
clean rebuild. Keeping VM provisioning at the service entry point obscured
ownership, while recovery authorization and publication had overlapping paths.
API runtime configuration also inherited an unnecessary workload-secret and
fixed-worker dependency.

## Decision

Use a documentation/orchestration-only service directory with separate bootstrap,
infrastructure and runtime states. Bootstrap owns external recovery prerequisites;
infrastructure owns replaceable compute and enrollment; runtime owns post-boot
platform configuration through an explicit exported connection contract.

Use the integrated bootstrap publication path, keep synthetic consumers in an
explicit optional qualification root, and remove duplicate runtime recovery-value
authorization. Independent actual-token/credential custody and native RKE2
snapshot ownership remain required.

## Consequences

- VM recovery planning does not require Kubernetes or runtime providers.
- Compute removal does not delete external recovery material.
- Runtime consumes reviewed output metadata, not another root's whole state.
- The retired cluster's state and inputs are evidence, not a migration source.
  Recreating nodes for an established cluster still requires guarded restoration;
  a fresh identity never silently bypasses retained identity or backup history.
- Existing manually managed platform integrations need an explicit ownership
  handoff before any later declarative adoption; moving files is not deployment.
