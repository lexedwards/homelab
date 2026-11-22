# Kubernetes observability

The opt-in API runtime defines a pinned Grafana Kubernetes Monitoring release.
Its worker-hosted collector scrapes kubelet, resource, cAdvisor, API-server,
kube-state-metrics and Cilium endpoints and exports cumulative OTLP metrics to
warehouse Alloy. The same collector watches Kubernetes events and collects
stdout/stderr from all pods through the API, then exports logs over OTLP. This is
collection configuration, not deployed acceptance.

Node CPU/memory and readiness/pressure coverage does not require Node Exporter,
host mounts or a control-plane collector. Full host-device monitoring and
scheduler/controller-manager/etcd metrics are outside this pass. The
[collection decision][decision] explains the boundaries.

## Pod logs and events

Pod discovery covers all namespaces. The collector has read-only log access,
not host filesystem access or an ability to mutate workloads. All-pod collection
is intentional; it does not grant application pods access to the collector or
warehouse APIs. The event reader remains a singleton. Neither path collects
audit logs, arbitrary host journals or Kata guest-internal logs.

The OTLP destination maps node identity into `k8s.node.name`. Kubernetes namespace,
pod and container metadata use the chart's standard mappings. Controller name and
kind remain `workload` and `workload_kind` attributes; a ReplicaSet controller name
is not silently relabelled as a Deployment. Event object/timestamp details remain
in the JSON event body. A cluster-scoped event need not have namespace/node data.

The destination replaces incoming Loki label hints with a bounded list: service,
environment, host and Kubernetes cluster/namespace/node identities. The existing
warehouse's insert-only hint processor preserves that list, so a warehouse reload
is not required. Native local conversion with the warehouse-matching Alloy version
confirmed those Kubernetes labels, while pod name/UID and workload attributes
remain in the JSON entry. Trace/span IDs remain unindexed fields when emitted.
This local conversion check is not proof of live Kubernetes log delivery.

Example LogQL selectors after verifying the actual ingested fields:

```logql
{k8s_cluster_name="<cluster>",k8s_namespace_name="<namespace>"}
{k8s_cluster_name="<cluster>",k8s_node_name="<node>"} | json
{k8s_cluster_name="<cluster>"} | json workload="attributes.workload" | workload="<controller>"
{k8s_cluster_name="<cluster>"} | json pod=`resources["k8s.pod.name"]` | pod="<pod>"
```

API log streaming is best effort. There is no claimed persistent file checkpoint.
Rotation, reader reconnect, container replacement, API unavailability and collector
restart can lose or replay records. Queues are shared with the configured export
pipeline and are lost on restart. Observe failures and compare synthetic sequence
numbers before/after approved tests; do not infer continuity from a Ready pod.

Applications must not disclose secrets. Optional collection redaction is separate
defence in depth, not a way to hide unsafe logging. Do not emit real credentials
as a smoke test or export the same event through both SDK logs and stdout.

## Inputs and ownership

Use the canonical `services/kubernetes/runtime` root and its existing protected
state for persistent operations. Set `cluster_api.kubeconfig_path` to an absolute
protected kubeconfig path, or retain the existing enabled `secrets_platform`
connection. Neither input enrolls credentials. Keep kubeconfig owner-readable.

Set `observability` in ignored runtime inputs:

- `cluster_name`: one stable identifier for this cluster.
- `warehouse_url`: the privately published ingestion HTTP(S) origin, including
  its explicit listener port, without credentials, path or query.
- `warehouse_ipv4` and `warehouse_port`: the same reviewed destination for the
  export policy. Recheck DNS and update the policy if its address changes.
- `dns_ipv4`: the cluster DNS Service address.
- `node_ipv4_addresses`: all node addresses used for direct metrics discovery.
- `api_ipv4_addresses`: API Service and control-plane endpoint addresses used by
  in-cluster discovery. Cilium policy behavior must be checked on the actual path.
- `allow_plaintext`: defaults to false. Set true only under the accepted temporary
  private collector-to-warehouse exception. This does not bypass kubelet/API TLS.

The runtime owns one native RKE2 HelmChart, its namespace and network policies.
The chart owns the namespace-scoped Alloy Operator, collector, restricted
kube-state-metrics deployment and explicit collector RBAC. The operator cannot
create ClusterRoles. Collectors cannot read Secrets or ConfigMaps and do not use
administrative client certificates. Existing warehouse deployment/state remains
separate; supply its published endpoint rather than reading its state.

Cilium assigns reserved identities to API-server and node endpoints. CIDR-only
egress policies do not cover those identities. The runtime therefore also owns
namespace-scoped CiliumNetworkPolicies: API access for platform pods on the API
ports, and node-identity access for only the cluster collector on kubelet/Cilium
metrics ports. This covers joined cluster nodes, not arbitrary external hosts.
Exact-address policies still bound DNS and warehouse export. Do not enable a
cluster-wide CIDR matching mode or add broad egress to repair these paths.

Node discovery uses verified kubelet CA and IP identity. The pinned chart's
experimental component-replacement interface removes its default TLS bypass.
Chart upgrades require rerendering and revalidation of all three replacements.

The collector is one StatefulSet replica to avoid duplicate singleton scrapes.
Its queues use memory, not a persistent volume. Restart loses queued data; this
is not an HA or lossless pipeline. Scrapes, export requests, retries, batch sizes,
memory and CPU are bounded in the maintained values. Resource limits are initial
budgets, not measured capacity guarantees.

## Local verification

Run parent and runtime `make init`, then `make validate`. These commands do not
plan or deploy infrastructure. Download the archive identified by
`platform/observability/chart.json` separately and use Helm plus the Alloy version
recorded there:

```bash
make observability-chart-validate \
  OBSERVABILITY_CHART='<downloaded-chart-archive>' \
  HELM='<helm-binary>' ALLOY='<chart-matching-alloy-binary>'
```

This checks the package digest, native Helm lint/render and native Alloy
configuration with synthetic inputs. It starts no collectors and contacts no
cluster or warehouse. It needs Python, PyYAML and the two native tools. Invalid
packages, version mismatch, render failure, missing configs or Alloy errors fail
the command. It does not establish collector authorization or network enforcement.

## Review and rollout

1. Obtain separate authorization for canonical runtime planning and deployment.
   Review a fresh saved plan. Reject unrelated secret-platform, VM or recovery
   changes, unexpected ownership adoption, and namespace collisions. Apply only
   the unchanged reviewed plan. Never deploy from a feature-worktree state.
2. Verify the native Helm release, operator, collector and kube-state-metrics
   readiness. A HelmChart object alone is not running-collector evidence. Check
   worker placement, no unexpected host access, actual service-account permissions
   and the default-deny policy. Node/host-network traffic has Cilium-specific
   behavior: test the actual permitted and rejected paths.
3. Enable `cilium_metrics_enabled` in the parent infrastructure inputs under a
   separately reviewed canonical plan/apply. This changes only the generated
   native configuration/output, not first-boot snippets or VM resources. Export
   `cilium_metrics_manifest` privately. Follow [the existing atomic native
   configuration procedure][cilium] to replace the persistent chart configuration,
   preserving the service-pool values. Do not use a second Helm/API writer or
   restart RKE2 to deliver the change.
4. Observe Cilium reconciliation and replacement agent/operator readiness. Verify
   node/API health and ordinary/Kata networking and service exposure before
   accepting the datapath change. Check metrics from every agent and the operator.
5. Query the real warehouse. Confirm all nodes and required sources, stable
   cluster/node/namespace/workload labels, no duplicate series and export health.
   Neither administrative metric reads nor the local validator proves delivery.
6. Under an approved bounded test, observe collector restart and warehouse export
   failure/recovery. Inspect failed sends, queue saturation and dropped data.
   Do not manufacture a warehouse outage by restarting unrelated services.
7. For logs, emit numbered synthetic stdout/stderr records from ordinary and Kata
   pods on each worker. Query their node/namespace/workload identity and event
   object/timestamp fields in Loki. Exercise container restart, bounded rotation
   and collector reconnect; record gaps/replay and recovery rather than claiming
   lossless delivery. Use only owned fixtures and preserve runtime selection.

Use the supplied query API access privately. Expected PromQL starting points are
below; verify translated names and labels against real ingestion before recording
acceptance. The cluster selector uses the maintained chart's cluster identity.

```promql
sum by (node) (rate(node_cpu_usage_seconds_total{cluster="<cluster>"}[5m]))
node_memory_working_set_bytes{cluster="<cluster>"}
kube_node_status_condition{cluster="<cluster>",condition="Ready",status="true"}
kube_node_status_condition{cluster="<cluster>",condition="MemoryPressure",status="true"}
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{cluster="<cluster>"}[15m]))
sum by (code) (rate(apiserver_request_total{cluster="<cluster>"}[5m]))
up{cluster="<cluster>",job="integrations/cilium"}
sum(rate({cluster="<cluster>",__name__=~"otelcol_exporter_send_failed_.*"}[5m]))
time() - timestamp(node_memory_working_set_bytes{cluster="<cluster>"})
```

Missing or stale series are not healthy zeros. Compare source discovery, scrape
success, collector failure metrics and warehouse/query availability. The existing
warehouse converter drops delta-temporality metrics; do not change the producer
to delta to repair missing data.

## Upgrade and rollback

Keep the chart URL, checksum and matching Alloy validation version together in
`platform/observability/chart.json`. Render and review generated permissions,
images, resources, component replacements and policy targets before an upgrade.
Preserve a private copy of the current native Cilium configuration before changes.

Rollback collector configuration through its canonical OpenTofu/chart owner using
a fresh reviewed plan; restore the previously reviewed pin/values, not a second
Helm release. Roll back Cilium through the same persistent native file owner and
wait for datapath health. Do not delete release Secrets or weaken TLS/SELinux.

The telemetry chart uses the native controller's `retry` failure policy, supported
by the reviewed RKE2 CRD. Fix the cause and apply a reviewed configuration change
to retry a failed install/upgrade; it does not request an uninstall/reinstall.
Do not switch to `reinstall` or remove release state to clear a failure.

The namespace/chart have destruction guards. Setting the input to null is not an
automatic safe uninstall; review removal explicitly. Back up runtime state through
the established operator process. Recreating the collector restores configuration,
not lost in-memory telemetry. Deployment and outage evidence belongs in the
owning tracker issues, not a claim inferred from these procedures.

[decision]: ../../docs/adrs/013-kubernetes-telemetry-collection.md
[cilium]: SERVICE-EXPOSURE.md#prepare-and-review
