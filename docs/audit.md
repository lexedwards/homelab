# Documentation audit

## Review record

ALE-47 first slice, reviewed 2026-11-14. The full overhaul remains open; coverage
and remaining work are recorded below. Repository sources and existing runbooks
were inspected; no infrastructure was contacted. Operator input
confirmed the application roles, hosts, and subnets recorded in the inventory.

| Area | Coverage in this slice | Finding / disposition |
| --- | --- | --- |
| Root overview | Reviewed and updated | Removed retired placeholders, filled application descriptions, updated Kubernetes summary, added navigation. |
| Host READMEs | All three read | Proxmox roots are provider-only; Micro Node seed is first-boot configuration. Inventory now states those ownership limits. Full host recovery guidance remains incomplete. |
| Service READMEs | Ownership/placement/dependencies reviewed for the overview; connection-detail search across Markdown | Added canonical inventory and removed numeric addresses/ports from affected prose, commands, and diagrams. Full command-by-command correctness audit remains open. |
| Kubernetes runbooks | Lifecycle qualification, storage, secrets, exposure, policy, backup and restore boundaries sampled | Preserved failed/unproven restore status and distinction between definitions, qualification, and deployment. Full procedural reconciliation against linked issue evidence remains open. |
| ADRs | Relevant ownership, topology, NFS, runtime-state and recovery-custody decisions consulted | Linked rationale; did not rewrite history. Duplicate `006` numbering and stale links/status need a complete pass. |
| Module documentation | Located; not fully reviewed | OpenBao integration contracts need a full documentation pass alongside their callers. |
| Contributor/agent guidance | Existing service/configuration skills inspected for navigation | Added onboarding, ownership, privacy and documentation-review guidance. Existing skills remain authoritative for their workflows. |
| Architecture | New logical context, container and deployment/network views | Mermaid is the chosen source format. Reviewers keep the views consistent; there is no infrastructure-derived or custom model generator. |
| Unmanaged infrastructure | Repository references and operator input only | Unknown placement, policy, backup and recovery details are labelled unverified; confirmation deferred at operator request. |

## Required remaining work for ALE-47

- Finish the full documentation review: every service, host, module README, ADR,
  operational procedure, and repository-specific agent convention. Record coverage
  and correct contradictions without changing infrastructure.
- Reconcile recorded deployment and qualification claims against linked issues.
  Do not turn missing evidence into a deployed or non-deployed assertion.
- Complete remaining onboarding, operating, and recovery guidance where evidence
  supports it. Record evidence gaps where procedures cannot yet be written.
- Add repeatable link/privacy checks and practical automated Mermaid validation.
  Include checks in the documented review workflow and report their limits.
- Review the rendered views and privacy coverage, including private locators or
  identifiers that pattern searches cannot reliably recognize.

## Agreed deferrals and external work

- The operator agreed to leave unknown unmanaged inventory/placement unverified
  for now. TrueNAS/RustFS/NFS details, UniFi policy, UPS coverage, proxy routes and
  application backup/recovery details need confirmation before stronger claims.
- Kubernetes restore qualification remains ALE-55's
  work. Documenting its limitation does not require rerunning a failed experiment.
- Component/code-level architecture views, live discovery, infrastructure rollout,
  and recovery exercises are outside this documentation change.
