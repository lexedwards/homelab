---
name: Separate Kubernetes API runtime state from VM provisioning
status: accepted
---

# Separate Kubernetes API Runtime State From VM Provisioning

## Context

CSI delivery and OpenBao workload-auth definitions need declarative ownership,
not prepared artifacts followed by one-off API writes. Putting API providers in
the VM state, however, makes infrastructure refresh depend on a functioning
Kubernetes API and unsealed OpenBao. That obstructs recovery of the infrastructure
whose APIs are unavailable. The operator selected an adjacent runtime state.

## Decision

Keep the existing VM/provisioning root and state at `services/kubernetes`. Put
API-managed platform resources in `services/kubernetes/runtime`, with its own
protected state and pinned Kubernetes/API-compatible Vault providers. Both remain
part of the Kubernetes service and deploy only from canonical `main`.

Read only non-secret connection metadata from the existing Kubernetes and OpenBao
hosting states. Their state files remain authoritative and are not migrated or
replaced. State readers still need access to the whole hosting state; protect it.
Never export actual credentials or secret values as connection metadata.

OpenTofu owns native RKE2 HelmChart objects; RKE2 owns their releases. Service roots
own their access definitions through the shared module. Actual value enrollment
remains protected and outside state/plans; setup credentials are ephemeral.

## Consequences

- VM recovery planning does not require either runtime API. API resources still
  require functioning endpoints for their own refresh/apply.
- Initial runtime deployment follows infrastructure enrollment and metadata output
  applies. Service-class planning follows real CRD installation; `depends_on`
  cannot resolve a missing schema during an earlier plan.
- Runtime state has independent custody and restore obligations. Do not promote
  feature-worktree states or introduce competing file/Helm/API writers.
- No state split is needed for this adoption: the old manual API rollout was
  paused before creating runtime objects. Previously created objects elsewhere
  require explicit ownership/import review, not forceful adoption.
