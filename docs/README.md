# Documentation guide

Use these documents to understand the homelab without needing its private
connection details. They describe intended configuration and recorded evidence,
not a live inventory or permission to operate infrastructure.

| Question | Start here |
| --- | --- |
| What exists, who manages it, and what is confirmed? | [Service and infrastructure inventory](inventory.md) |
| How do applications, hosts, and networks fit together? | [Architecture views](architecture.md) |
| What fails together, and what must recover first? | [Operations and recovery](operations.md) |
| How do I prepare a safe change? | [Onboarding and contributor guidance](contributing.md) |
| Why were important choices made? | [Architecture decision records](adrs/) |
| What has the documentation review covered? | [Audit and remaining work](audit.md) |

## Authoritative homes

- The [root README](../README.md) introduces the lab and its services.
- The inventory owns logical names, management ownership, placement, and evidence
  status. Diagrams are selected views of those facts, not separate inventories.
- `hosts/` documents host preparation. `services/` documents each service's
  prerequisites, configuration, state, and operating procedures. A host directory
  does not imply that OpenTofu manages that host.
- `modules/` documents shared implementation contracts, not service deployment.
- ADRs preserve decisions and rationale; current operating instructions belong
  with the service. Linear issues retain deployment evidence and outstanding work.

Connection values, credentials, raw logs, state, plans, rendered configuration,
and recovery artifacts stay in protected operator custody. Use logical names and
private-input placeholders even in synthetic documentation examples.
