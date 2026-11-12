# Cilium Service Exposure

`service_exposure` renders native Cilium IPAM pools, per-interface L2 policies and
the existing RKE2-owned HelmChartConfig. It defaults to `null`: no pools are
rendered and existing bootstrap networking is unchanged. Rendering or merging
these files does not deploy them. ALE-31 records deployment and qualification.

## Inputs And Ownership

Supply private ranges and exact Linux interface names in ignored tfvars, using
the structure in `terraform.tfvars.example`. `primary` and `secondary` are logical
pool names, not VLAN numbers. A deployment can start with one pool and add another
later without renaming the first pool or reallocating its Services. That is an
additive design, not a zero-risk guarantee for a later Cilium/device change.

- `devices` lists the external interfaces used by Cilium on all nodes. Include
  the primary API/node NIC and each worker service NIC; confirm actual names on
  both workers. Do not substitute Proxmox bridge names. The server has only its
  primary NIC; it is excluded from L2 election by the worker selector.
- Each pool supplies a canonical IPv4 `subnet`, inclusive `start` and `stop`, and
  one exact `interface` from `devices`. Regex/wildcard interfaces are rejected.
- Pool names are 2–40 lowercase DNS-label characters, starting with a letter.
  Names become stable resource identities and Service selector values.
- Validation rejects reversed/overlapping ranges, network/broadcast endpoints,
  endpoints outside the subnet and overlap with internal Pod/Service networks.
  It cannot discover leases, static assignments, other live pools or wrong VLAN
  placement. Operator approval and live inventory supply those checks.

Both pool and announcement policies select `homelab.io/service-pool: <name>`.
Unlabelled Services do not match these pools. Each L2 policy selects only worker
nodes and its exact interface. External-IP announcements are disabled. Namespace
owners who can set these labels can request pool addresses; these selectors are
not a tenant authorization boundary. Inspect **all** existing IPAM and L2 policies
for overlapping selectors before deployment.

Use `loadBalancerClass: io.cilium/l2-announcer` and
`externalTrafficPolicy: Cluster`. Cilium L2 announcements do not support `Local`
for this path. The examples disable NodePort allocation and share the existing
ordinary/Kata backends from `examples/network-policy/workloads.yaml`. Four
Services exercise both runtime paths on each selected pool; no application A–E
identities, Multus, pod VLAN NICs, ingress or public exposure are introduced.

RKE2 remains the only Cilium chart owner. Its bundled chart/version is determined
by the existing pinned RKE2 installation; do not install a second Cilium release
or substitute an unreviewed upstream chart. Preserve verified API identity,
host-namespace-only socket LB, tunnel mode and the other existing chart values.
Exposure sets `rollOutCiliumPods = true` and `operator.rollOutPods = true` so
native chart configuration changes roll both agents and operator. L2 enablement
and managed Service classes are startup settings; an updated ConfigMap and healthy
old pods do not prove allocation or announcement works. Require replacement pod
UIDs, readiness, actual L2 leases and client-side evidence before declaring success.
Enabling L2 and changing `devices` affects the shared datapath, including service
routing/masquerading, and can roll agents. It is not merely an IPAM-object update.

API client limits become 50 QPS / 100 burst for the approved two 32-address pools.
At a two-second lease retry interval, 64 independently elected Services can need
about 32 requests/second on one agent before other API traffic. These limits are
headroom, not an API capacity guarantee. Recheck deployed lease timing, throttling
and service count before growth or IP sharing; one address is not always one lease.

## Prepare And Review

1. Confirm pool exclusions and current lease/reservation/static conflicts with
   the upstream owner. Confirm worker MAC reservations, one primary default route,
   secondary DHCP route/DNS suppression and VLAN interface reachability.
2. Run `make validate` and inspect generated manifests against the deployed
   Cilium CRDs and bundled RKE2 chart. Use server-side dry-run before rollout.
3. Use **canonical main and its existing state** for an authorized saved OpenTofu
   plan. Reject unexpected VM replacement/restart, DNS, worker NIC or storage
   changes. Do not use a worktree state or target resources to bypass review.
4. After the separately approved saved-plan apply, export the sensitive output
   to a new protected directory. JSON output is unredacted; do not print it or
   upload it to Git/Linear:

```bash
umask 077
mkdir '<new-protected-directory>'
tofu output -json service_exposure_manifests > '<new-protected-directory>/files.json'
python3 - '<new-protected-directory>' <<'PY'
import json
from pathlib import Path
import sys
directory = Path(sys.argv[1])
for name, text in json.loads((directory / 'files.json').read_text()).items():
    assert Path(name).name == name and name.endswith('.yaml')
    with (directory / name).open('x') as output:
        output.write(text)
PY
```

The output map is empty without opt-in. Exposure inputs change only the sensitive
runtime outputs: the first-boot snippet always uses the unchanged bootstrap
configuration. Enabling exposure must not replace a snippet or VM. Applying
OpenTofu does not update the initialized server's on-disk manifest. Do not rerun
cloud-init, recreate the server or restart RKE2 to deliver this configuration.
Under separate live rollout approval, atomically replace only
`/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml` with the reviewed
export, preserving its root-only ownership/mode. Save its previous content
privately first. Native RKE2/Helm reconciliation owns the update; do not combine
this with an independent Helm install or ephemeral live-only chart edit.

Observe HelmChart/job/release status, Cilium agents and operator, node/API health
and internal ordinary/Kata traffic before applying the exported pool/L2 objects.
Pause on failure and preserve evidence. A Helm guard is not a rollback of already
changed datapaths. Recovery must restore the prior persistent HelmChartConfig
through the same native owner and wait for health; do not delete release Secrets.

## Authorized Runtime Checks

Prepare approved **non-cluster clients on each tested Layer-2 segment**, with
`ip`, `arping` and `curl`. A worker-local or routed-only HTTP request does not
prove that an L2 announcement works. Confirm each client route is directly
connected through the selected NIC, not a gateway or another VLAN interface.
Keep addresses, MACs, client inventory and raw command output private.

Deploy the owned network-policy fixtures and selected Services only after explicit
approval. Do not adopt an existing `policy-check` or `policy-outside` namespace.
If only one pool is selected, deploy only its two Service documents, not the
whole four-Service example. Check each Service's allocated address belongs to
its labelled pool and correlate ready EndpointSlice addresses, pod UIDs/runtime
classes and real Kata execution on the serving nodes.

On each external client, use its intended interface and the allocated address:

```bash
ip route get "$service_ip"
arping -I "$interface" -c 3 "$service_ip"
curl --noproxy '*' --interface "$interface" --connect-timeout 3 --max-time 5 \
  --fail --silent --show-error "http://$service_ip:8080/"
ip neigh show to "$service_ip" dev "$interface"
```

The expected synthetic body is `policy-check`. Record the ARP responder MAC and
correlate it to the active worker/interface and the Service's `cilium-l2announce-*`
Lease in `kube-system`. An IP in Service status alone proves allocation, not
advertisement. Check both runtimes and both pools from their intended L2 clients.
Cross-VLAN access follows upstream routing/firewall policy; the pool selector is
not a firewall and does not guarantee client-VLAN isolation.

With the API healthy, test backend relocation separately from announcer election:

1. On owned server Deployments only, save original pod templates, use one replica
   and remove the two-worker spread requirement. Pin the ordinary/isolated
   backends to one verified worker using a reviewed hostname selector.
2. Verify endpoint and runtime proof, ARP/HTTP and unchanged Service addresses.
   Move those **synthetic** backends to the other worker without draining a node;
   record ready replacement UIDs, HTTP interruption bounds and address stability.
3. Separately constrain an owned test L2 policy's worker selector to the other
   verified worker. Observe lease holder transition, both NIC MACs, ARP convergence
   and HTTP bounds. Keep policy/service/interface selectors unchanged. Restore
   the original worker selector after verification. Do not stop agents or nodes
   to manufacture a failover test.

Before normal workloads, also qualify exhausted and unselected pools. Use a
reviewed **temporary one-address subset of an approved pool** for its first
deployment, while the other pool has spare addresses. The first owned Service
must allocate there; a second with the same label must remain unallocated with
visible pool/Service evidence, not consume another pool. An unlabelled Service
must also remain unallocated. Remove those claims before expanding to the full
reviewed range. Do not shrink, overlap or exhaust a pool serving useful workloads.

Repeat ALE-30's staged positive/negative direct-peer matrix on the actual
VLAN-facing Service backends; Service exposure must not bypass pod policy. Keep
fresh tuple-matched native policy-drop evidence, DNS restoration and the expected
external client rule separate. Do not use unrestricted ingress or delete
default-deny just to make the external HTTP test pass.

## Failures, Cleanup And Recovery

Troubleshoot in order: verified API/etcd availability; chart reconciliation and
agent health; IPAM pool conditions/conflicts and Service labels/class; ready
endpoints and pod policy; L2 leases/holder and actual Cilium-selected devices;
ARP responder and stale neighbors; then bridge/VLAN/LAG membership, upstream
DHCP/static collisions, routing and firewall rules. The native operator owns
IPAM, agents own L2 leases/announcements, and the upstream operator owns switches,
reservations and inter-VLAN access. Do not add static service addresses to nodes.

Lease acquisition/renewal depends on the API on the single control-plane VM.
Moving backends to store before compute maintenance does **not** guarantee service
reachability or failover during API loss. The stable API address must never
depend on these workload pools/announcements. Outage qualification belongs to
ALE-32; retain the default-deny boundary during recovery.

Remove only owned test Services, policies and stateless namespaces after checking
for unrelated content. Verify EndpointSlices, leases and Kata processes are gone,
both workers remain Ready, and node/agent/control-plane identities are accounted
for. Leave reviewed platform pools in place only if that deployment was approved.
Before removing a platform pool or L2 policy, inventory all consumers and plan
their withdrawal. Setting `service_exposure = null` does not delete live objects
or automatically restore the initialized server's persistent chart configuration.
