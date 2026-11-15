# Onboarding and contributor guidance

## Start safely

1. Read the [inventory](inventory.md), [architecture](architecture.md), and the
   target service's README. Identify the deployment root and state owner before
   selecting commands. Read the relevant [ADRs](adrs/).
2. Prepare local tools listed by that service. Versions and requirements vary;
   do not assume every root has identical OpenTofu or provider requirements.
3. Develop on a dedicated branch/worktree. Never copy production state, private
   variables, plans, credentials, rendered cloud-init, or recovery artifacts into
   a feature worktree or documentation.
4. Run the target's documented offline checks. `make init` downloads dependencies;
   inspect the target's Makefile before assuming what `make validate` does.
   Mocked tests are not evidence of deployment, restart safety, or recovery.
5. Request separate authorization before any online plan, apply, import, probe,
   restart, or recovery exercise. Persistent operations use the canonical checkout
   and established state. Keep feature worktrees out of production deployment.

For service changes, follow the repository's [service skill](../.agents/skills/create-a-service/SKILL.md)
and [configuration-value rules](../.agents/skills/principle-configuration-values/SKILL.md).
Use repository-level modules for shared implementation. Integrations consume
published interfaces. Keep another service's private state and files outside the
integration.

## Documentation ownership and review

The change author updates affected documentation in the same change as the
infrastructure. The reviewer checks the following before approval:

- Inventory names, ownership, placement, and status match the evidence.
- Context, container, and deployment views remain consistent. Keep C4
  applications/datastores separate from deployment nodes and guest types.
- Runtime, provisioning, renewal, and recovery dependencies are distinguished.
- Procedures identify prerequisites, state ownership, limitations, and validation.
  Untested procedures stay labelled; do not promote local tests into live evidence.
- New decisions link to an ADR when durable rationale is needed. Do not duplicate
  service runbooks or copy issue execution logs into the overview.
- Unknowns and proposed deferrals remain visible in the [audit](audit.md).

## Documentation privacy

Do not include IP addresses, address ranges, numeric ports, private DNS names,
numeric network identifiers, MAC addresses, credentials, private artifact
locations, or raw operational output in Markdown or diagrams. This includes
synthetic examples. Public project/documentation links and logical labels such
as `compute`, `store`, IoT, Service, and Trusted are allowed.

Use private-input variables or descriptive placeholders for required connection
values. Resolve exact values from protected operator configuration at execution
time. Do not guess them or make a placeholder silently default to another path.
Keep operational security warnings when removing connection details.

## Documentation checks

GitHub renders the Mermaid fences directly. For a reproducible local render,
from the repository root with Node.js/npm and the Mermaid CLI's supported browser
dependencies available:

```bash
mkdir -p /tmp/opencode/ale-47-diagrams
npm exec --yes --package=@mermaid-js/mermaid-cli@12.2.0 -- \
  mmdc -i docs/architecture.md -o /tmp/opencode/ale-47-diagrams/architecture.md
```

The first run needs network access to download tooling and its browser.
Rendering runs locally, does not contact infrastructure, and writes temporary
Markdown and diagram files outside Git. Do not use a public renderer for topology.
The pinned renderer validates syntax. Deployment status and architecture accuracy
need separate checks.

Check changed relative links and headings, inspect every rendered view for
readability, and review Markdown/diagrams for connection details. The first slice
does not yet provide automated repository-wide link/privacy checks or CI rendering;
those remain explicit work in the [audit](audit.md). Semantic accuracy will still
need review after those checks are added.
