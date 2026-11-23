# Kubernetes API runtime

This OpenTofu root owns post-boot platform configuration, independently of
[infrastructure](../infrastructure/README.md). Its API providers must never be a
dependency of VM recovery planning.

## Shared connection

Supply `cluster_api` with a protected administrator `kubeconfig_path` and the
reviewed stable `api_host`. For worker prerequisites, also supply `ssh_user` and
the full `workers` cohort. The latter fields come from infrastructure's privately
exported `runtime_connection`; inspect that export before use. There is no
remote-state read and no authentication fallback tied to workload-secret enablement.

Each feature is independently optional:

| Input | Owned configuration |
| --- | --- |
| `observability` | Pinned monitoring chart, namespace and bounded Kubernetes/Cilium policies; metrics/logs/events export to the warehouse |
| `secrets_platform` | CSI/provider charts, verified worker SELinux preparation/readiness labels, TokenReview role and OpenBao Kubernetes auth |
| `private_dns_forwarding` | Native CoreDNS conditional forwarding for one exact private suffix |

Telemetry and private DNS need only the common API connection, not CSI/OpenBao
workload integration. The secret platform accepts a nonempty reviewed worker
cohort, not a fixed two-worker topology. Its additional `openbao_endpoint_file`
is the published JSON endpoint, never another service's state; administration
uses native `VAULT_TOKEN`. Worker preparation requires approved SSH trust and
checks node UIDs before/after changing only the provider directory.

## Deployment and ownership

Run `make init` and `make validate` locally. For separately authorized canonical
operations, inspect a fresh `make plan` and apply only the unchanged `PLAN_FILE`.
Feature worktrees never own live state. Confirm real chart/CRD readiness after
apply; a HelmChart object alone is not a running release.

OpenTofu owns native RKE2 HelmChart objects; RKE2 owns the releases. Do not apply
inspection exports or direct Helm writes alongside these owners. Private DNS
owns only `rke2-coredns` HelmChartConfig, not its rendered ConfigMap or release.
Keep the private forwarding resolver internal; mixed public/private resolvers
can return intermittent negative answers. Follow [DNS checks](../SECRETS.md).

Normal runtime has no synthetic applications or recovery-custody writer grants.
[Secret-delivery fixtures](../examples/secret-delivery/README.md) use an explicitly
invoked separate example root, only after CSI CRDs and Kata prerequisites exist.
Consuming services own their own exact secret access through shared repository
modules. [Bootstrap](../bootstrap/README.md) owns independent recovery access;
actual values and independent custody stay outside state.

## Removal and limits

Remove fixture consumers before CSI CRDs, then drain native releases before
deleting their namespaces. Destroy runtime before the API/VMs. Namespaces, shared
charts/auth mount and DNS config have destruction guards: explicitly review
removal rather than bypassing state ownership. External OpenBao/warehouse services
and stored values are not destroyed by this root.

Enabled plans download pinned charts over verified HTTPS and check their bytes.
Offline mocked tests establish configuration behavior, not API/SSH authorization,
network enforcement, chart readiness or warehouse ingestion. Native chart/Alloy
inspection is separately available through the service Makefile.

See [secrets](../SECRETS.md), [observability](../OBSERVABILITY.md) and
[ADR 017](../../../docs/adrs/017-kubernetes-deployment-roots.md).
