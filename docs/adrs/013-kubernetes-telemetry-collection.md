# Kubernetes telemetry collection

Status: accepted collection design; deployment qualification is separate.

## Context

Kubernetes needs infrastructure metrics, all-pod logs/events and an application
OTLP path to the existing Alloy/Mimir/Loki/Tempo warehouse. Maintaining unrelated
collectors would duplicate discovery, permissions, metadata and lifecycle work.
RKE2 owns Cilium, and the API runtime must remain separate from VM recovery.

## Decision

Use the pinned Grafana Kubernetes Monitoring chart through one API-runtime-owned
native RKE2 HelmChart. Namespace-scope its Alloy Operator, predeclare collector
RBAC, and retain verified kubelet/API TLS rather than copying chart bypasses.
Keep warehouse configuration in the warehouse service and integrate through
explicit published endpoints.

Use a worker-hosted singleton for cluster collection. Kubelet resource/cAdvisor
metrics and kube-state-metrics cover initial node/pod CPU/memory and readiness,
pressure and workload state without host mounts or Node Exporter. Collect pod
stdout/stderr through the Kubernetes API and use a singleton event reader.
Applications use a separate worker-hosted OTLP HTTP receiver with a stable private
Service and explicit sender access. No blanket instrumentation is selected.

Use OTLP HTTP/protobuf for warehouse export. It fits the existing receiver and a
future HTTPS reverse proxy without requiring gRPC support. The operator accepted
temporary private plaintext/unauthenticated warehouse ingestion with source
restrictions; it is not permission to bypass Kubernetes TLS or expose ingestion
publicly. Applications remain responsible for never logging secrets. Optional
redaction does not make unsafe application logging acceptable.

Keep Cilium metrics enablement in its existing complete generated native
configuration, preserving exposure settings and the persistent file owner. Do not
introduce another chart/configuration writer.

## Consequences

The chart replaces bespoke collector wiring, not integration verification. Pinning
and native validation are required, including the experimental chart interface
used to remove kubelet TLS bypasses. Least-privilege permissions, Cilium policy,
metadata conversion, ordinary/Kata behavior and backend queries need separately
authorized runtime acceptance.

Full host-device monitoring, scheduler/controller-manager/etcd metrics and a
dedicated host-network collector are outside the initial pass. The queues are
bounded and in memory; restart/outage losses are accepted and must be documented.
No HA, lossless delivery, audit trail or complete log-secret detection is claimed.

Upstream OpenTelemetry Collector remains viable, but requires separately wiring
the exporters, scrape discovery, ownership and duplication controls already
provided by the selected chart. No custom collector implementation is justified.
