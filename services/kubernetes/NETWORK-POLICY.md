# Workload Network Policy

The reusable baseline denies ingress and egress in one explicitly selected
namespace. A separate policy allows only TCP/UDP port 53 to CoreDNS pods in
`kube-system`. It does not change Cilium, node networking, VLAN routing, system
namespaces, existing applications or admission policy. No Layer 7 rule is added.

## Onboard A Namespace

Before deployment, identify the application's owner, callers, dependencies,
protocols, ports, DNS and persistent-data requirements. Review all existing
NetworkPolicies and Cilium policies: Kubernetes allow policies are additive, so a
broad existing allowance can defeat the intended baseline. A namespace label or
VLAN-facing Service address does not replace pod policy.

Under separate rollout approval, apply the baseline and DNS policy to the
intended namespace, then apply only its reviewed dependency rules:

```bash
kubectl -n '<workload-namespace>' apply -f platform/network-policy/
```

Neither baseline manifest supplies a namespace; always select it explicitly. Do
not apply the baseline to every namespace or to `kube-system`. The DNS peer uses
namespace and pod selectors in **one** list item: both must match. Confirm the
deployed DNS pods use `k8s-app=kube-dns` in `kube-system`. NodeLocal DNS or a
host-network resolver needs a separately reviewed path, not unrestricted egress.

Application policies must name both sides of an approved path. In an isolated
namespace, a source egress allowance does not grant destination ingress. A peer
`podSelector` without a `namespaceSelector` selects only pods in the policy's own
namespace. For approved cross-namespace dependencies, put both selectors in the
same peer item; two items mean OR, not AND. Treat selector labels and policy
editing as trusted owner/operator permissions, not as tenant self-authorization.

## Bounded Synthetic Verification

The fixtures are not applications A through E and do not invent their dependency
matrix. They create two ordinary and two isolated client/server Deployments,
each spread across both workers, one unapproved client and an unprotected
outside-namespace HTTP witness. Each server listens on 8080 **and** 9090; a closed
port cannot manufacture a denied-port pass. No token mount, host networking,
privileged container, persistent volume or LoadBalancer is requested.

### Prerequisites And Ownership

Require explicit test deployment approval, a healthy verified-HTTPS API, both
workers Ready with verified Kata eligibility, healthy Cilium/CoreDNS and enough
capacity for ten synthetic pods including four Kata sandboxes. Check that the
`policy-check` and `policy-outside` namespaces do not already exist. Stop rather
than adopt unrelated namespace content or remove another owner's policies.

Denied probes use the existing Cilium agents' `cilium-dbg monitor --type drop
--json`, bounded by the container's native `timeout` command. Hubble need not be
enabled. Confirm those commands and the existing node-monitor socket are usable.
The checker does not install tooling, change agent configuration, restart Cilium
or change RBAC. If observation is unavailable, denial is unproven: stop and review
the evidence boundary before changing the cluster.

With the approved administrative context, deploy only the fixtures first:

```bash
kubectl apply -f examples/network-policy/workloads.yaml
kubectl -n policy-check wait deployment --all --for=condition=available --timeout=300s
kubectl -n policy-outside wait deployment --all --for=condition=available --timeout=300s
kubectl -n policy-check get pods -o wide
kubectl -n policy-outside get pods -o wide
```

Retain pod UIDs, addresses, placement, runtime classes and node/capability health
privately. Confirm ordinary and isolated client/server replicas cover both
workers. Select exact source/destination pods; repeat the matrix for both client
runtimes against both server runtimes, including cross-worker pairs in both
directions. Never substitute a Service that might route back to the source pod.

### Probe Command

```bash
python3 scripts/check-policy-probe.py \
  --source 'policy-check/<client-pod>' \
  --destination 'policy-check/<server-pod>' \
  --port 8080 --expect allow \
  --api-server 'https://<stable-api-name>:6443' \
  --evidence '<protected-new-receipt.json>'
```

- `--source`, `--destination`: distinct `namespace/pod` identities. Both must be
  Ready, non-host-network pods labeled `homelab.io/policy-check=true`.
- `--port`: required TCP destination port, 1–65535.
- `--expect`: required `allow` or `deny`.
- `--api-server`: required verified HTTPS API identity on port 6443.
- `--kubectl`: executable, default `kubectl`.
- `--kubeconfig`: defaults to `/etc/rancher/rke2/rke2.yaml` for in-guest use.
- `--evidence`: required new file in an existing protected directory. Created
  exclusively with mode 0600; receipts contain private addresses and flow data.
- `--timeout`: total observation bound, default 60 seconds; accepts 5–300.

The checker resolves the destination Pod IP directly, creates a fresh bounded
HTTP connection and rechecks endpoint identity/readiness afterwards. An allowed
probe requires successful connectivity. A denied probe starts bounded monitors
on both endpoint nodes before the request, excludes pre-probe output and requires
a matching `drop` / `Policy denied` event for that source IP, destination IP and
TCP port. Run probes serially on otherwise idle synthetic endpoints; concurrent
requests using the same tuple would make correlation ambiguous. Each remote
monitor self-terminates after ten seconds, including if the local command fails.
The checker does not equate API errors, unavailable listeners, stale/unrelated
events or timeouts with enforcement. Exit 0 means that single probe passed; exit
1 means failure/incomplete evidence, not a policy pass. Normal output excludes raw
command errors and private flow details.

### Staged Matrix

First prove **all** listed HTTP paths and both listening ports work with no test
policies. Prove DNS from ordinary, isolated and unapproved clients using
`nslookup kubernetes.default.svc.cluster.local`. Record each stage with fresh
receipts on the same pod identities. Do not proceed if a prerequisite path fails.

Apply only the indicated policy at each stage, in order:

```bash
kubectl -n policy-check apply -f platform/network-policy/default-deny.yaml
kubectl -n policy-check apply -f platform/network-policy/allow-cluster-dns.yaml
kubectl -n policy-check apply -f examples/network-policy/allow-peer.yaml
```

Do **not** run all three commands before testing their individual stages. Wait
for the relevant Cilium endpoints to realize each policy revision, retain that
state and confirm the pods/listeners remain healthy. Observe rather than repair
a failed assertion by adding broad allow rules.

| Probe | No policy | Default deny | Add DNS | Add peer rules |
| --- | --- | --- | --- | --- |
| Approved client → server TCP 8080 | Allow | Deny | Deny | Allow |
| Approved client → server TCP 9090 | Allow | Deny | Deny | Deny |
| Unapproved client → server TCP 8080 | Allow | Deny | Deny | Deny |
| Outside witness → server TCP 8080 | Allow | Deny | Deny | Deny |
| Approved client → outside witness TCP 8080 | Allow | Deny | Deny | Deny |
| Unapproved client → outside witness TCP 8080 | Allow | Deny | Deny | Deny |
| Protected clients → cluster DNS | Allow | Deny | Allow | Allow |

The outside witness intentionally carries both the approved-source and server
labels. Cross-namespace rejection therefore tests namespace scope, not a missing
label. Its own namespace stays unprotected so outside→server demonstrates target
ingress enforcement, while client→outside demonstrates source egress enforcement.

The HTTP checker is TCP-only. For the DNS-deny stage, also retain fresh native
monitor UDP/53 policy-drop evidence matching the client and actual DNS endpoint;
an `nslookup` timeout alone is not enforcement proof. DNS restoration must not
restore unrelated HTTP egress. For TCP DNS fallback, retain a real TCP/53 query
when qualifying the deployed resolver path; the manifest's port list alone is
configuration evidence, not that runtime check.

ALE-31 supplies actual VLAN-facing Services. After that exposure is available,
repeat direct-peer policy probes between the selected service backends while
retaining their Service/pool placement. Do not claim VLAN placement isolation
from this ClusterIP/Pod-IP phase or relax pod policy for advertisements.

### Cleanup

Verify both namespaces still contain only owned fixtures, no PVCs/useful data and
no unrelated objects. Delete those namespaces with normal bounded deletion and
wait for their pods and Kata sandbox processes to exit. Do not force-delete or
change runtime labels to hide stuck cleanup. Check API/Cilium/node health and
retain sanitized results in ALE-30; keep raw evidence private.

## Troubleshooting And Emergency Changes

Check API/etcd availability, pod readiness and listeners before policy. Inspect
namespace/pod labels, endpoint addresses and all additive policies, then Cilium
endpoint policy state and correlated flows on the intended source/target nodes.
Check DNS selectors and TCP/UDP 53 separately from the application path. Only
after internal paths pass, investigate Service endpoints, VLAN address allocation,
L2 announcements and upstream routing/firewall state.

During API loss, existing forwarding is not proof that new policies or scheduling
work. Preserve the default-deny baseline; use ALE-32's recovery procedure. An
emergency exception needs an owner, a specific caller/destination/protocol/port,
approval, an expiry/removal plan and verification. Do not delete default-deny,
disable SELinux or introduce cluster-wide unrestricted egress as a diagnostic.
