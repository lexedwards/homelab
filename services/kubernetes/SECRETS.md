# OpenBao Mounted-Secret Authentication

`runtime/secrets.tf` manages the cluster's CSI/provider platform, worker prerequisites,
native OpenBao Kubernetes auth and optional owned qualification service in the
adjacent API runtime root/state. The existing VM state and bootstrap are unchanged.
This [state boundary][runtime-state] keeps VM recovery planning independent of
an unavailable Kubernetes API or sealed OpenBao. Native RKE2
Helm still owns the releases; OpenTofu owns their HelmChart API objects, not a
competing Helm release or an auto-reconciled server manifest file.

Secret paths, schemas, access rules and lifecycle procedures belong alongside
the owning service. Populate actual values through a protected enrollment
workflow that does not persist them in Git, OpenTofu state, saved plans or logs.
The offline `prepare-secret-auth.py` and `prepare-secrets-csi.py` tools remain
useful for inspection/render checks, **not as a second live configuration owner**.
Production qualification remains in ALE-49.

## Declarative deployment

Everything defaults off. First establish the cluster and enrolled workers using
the existing infrastructure lifecycle. After separate review/authorization,
enable `secrets_platform` in the canonical `services/kubernetes/runtime` root's
private inputs. Its new protected state owns only API runtime configuration;
the two existing infrastructure states are preserved, not copied or split.
No persisted apply runs from a feature worktree.

- OpenBao's service root exports `api_endpoint`, derived from its service-owned
  DNS name and native HTTPS port. Make that output available through an inspected
  output-only apply in canonical `services/openbao` first. Do not duplicate its
  hostname/port in an ad hoc enrollment file or expose authentication material.
- The runtime root reads that existing OpenBao state and the parent Kubernetes
  state's `runtime_connection` output. Make the latter available through a
  reviewed output-only parent apply first. It supplies the stable API origin,
  SSH user and complete worker cohort, not credentials.
  Remote-state access grants access to the entire protected hosting state, not
  only the output. Keep access/backups protected and keep actual secret values
  out of them. Both infrastructure states remain authoritative. The parent root
  has no Kubernetes or OpenBao API provider dependency.
- Supply an explicit protected `kubeconfig_path`. The provider is pinned to the
  cluster's existing API DNS name and verified TLS, and obtains the public API CA
  from the cluster's `kube-root-ca.crt` ConfigMap. The API audience remains a
  declared, verified cluster identity input, not a guessed hostname default.
- Supply both workers' verified Node UIDs and pinned public SSH host keys. These
  are deployment metadata, not private keys. Worker addresses come from the
  authenticated Node API, not static IP/MAC overrides. Load the approved guest
  and Proxmox SSH identities into the operator's agent; no private-key/password
  argument is stored in OpenTofu.
- Inject a short-lived scoped setup token through
  `TF_VAR_openbao_admin_token`, never tfvars or a literal command argument.
  This variable is **ephemeral**, requiring OpenTofu 1.11+. Its actual value is
  excluded from state and saved plans. Inject it again for apply; it is not
  recovered from the plan or a saved CLI login. Do not enable `TF_LOG`, shell
  tracing or HTTP debug logging. Kubernetes credentials remain inside the
  protected kubeconfig/approved authentication helper, outside state/plan data.

The API-compatible `hashicorp/vault` provider manages OpenBao's native Kubernetes
auth method, not a different authentication protocol. The pinned provider schema
was checked; real OpenBao compatibility and authorization still need runtime
qualification. Child-token creation and TLS bypass are disabled. Give the setup
identity only the required auth-method/role/policy configuration permissions;
it does not need application-value read/write access for these resources.

An enabled platform apply manages the guarded host prerequisite, capability
labels, privileged driver namespace, two native HelmChart objects, shared exact
TokenReview ClusterRole, and protected Kubernetes auth backend/config. Shared
namespace/charts/auth backend have destruction guards; do not casually disable
the opt-in to remove them. Review ownership/imports before adoption and stop on
any unexpected existing object or field-manager conflict. Do not use forced field
ownership to hide a second writer.

### Apply phases and qualification

1. **Platform:** keep `secrets_qualification = null`. Review/apply the saved
   platform plan from canonical `main` in `services/kubernetes/runtime`, using
   that root's runtime state, never the parent VM plan/state. Wait for both
   worker DaemonSets, node registrations, native releases and both driver CRDs.
   Creating HelmChart objects alone does not prove the releases are Ready.
2. **Service definition:** set `secrets_qualification` to an approved exact
   KV-v2 record path, initially with `replicas = 0`. Plan/apply separately after
   the CRDs exist: `kubernetes_manifest` needs their schema during planning;
   `depends_on` cannot make a missing CRD available to an earlier plan. This
   creates the owned namespace/account, default-deny policy, read policy/auth
   role, TokenReview binding, SecretProviderClass, source ConfigMap and parked
   Deployments. It also defines the exact value-writer token role and separate
   issuer policy. It neither creates a KV engine nor mints credentials or
   populates/reads the record.
3. **Value enrollment and consumers:** export `secrets_qualification_enrollment`
   privately. Use OpenBao's [protected credential helper][deployment-credentials]
   to mint a bounded value-writer and populate only its declared synthetic record
   through stdin. Issuer/admin credentials must never reach the pods.
   Set `replicas = 2`, inspect a fresh plan and apply it from canonical `main`.
   Perform the ordinary/Kata file-delivery, reload and identity checks below.
4. **Park/dispose:** return replicas to zero through a reviewed OpenTofu apply,
   not an out-of-band scale that the next apply would undo. Removing the optional
   qualification declaration plans removal of only its owned definition/workloads,
   not the shared platform or stored OpenBao values. Value deletion needs its own
   approved disposition. Preserve the retained NFS claim and initialized cluster.

Future consuming services declare `modules/openbao-access` in **their own roots**
(the path is relative to this Kubernetes root). Pass the shared auth mount,
reviewer-role name, audience and service endpoint, plus their own namespace,
account and exact record/field mappings. The module owns its policy, OpenBao role,
reviewer binding and SecretProviderClass and returns the class reference. The
caller owns its namespace/account and workload. Do not centralize application
values or every service's access policy in the cluster root. Its
`allow_overwrite = false` policy guard is intentionally retained despite the
pinned provider's deprecation warning; dropping it would allow adoption of an
unrelated policy. Review this behavior when upgrading the provider.

Per [ADR 008][administrative-auth], these authorization modules use the trusted
administrative configuration identity, not an ordinary deployment token. Native
provider configuration reads and drift repair remain enabled. A service root
that declares auth roles/policies is a privileged authorization stage; its
value-writer token cannot plan or apply those resources. Service ownership does
not mean the ordinary deployer can author or broaden its own permissions.

Declare OpenBao's `modules/deployment-access` alongside the consuming service's
authorization, using the same exact record paths. It defines only record-write
permissions, a bounded token role and an optional delegated issuer policy; no
credential or value is created by OpenTofu. The Kubernetes runtime root does this
for its own qualification service and exports private enrollment metadata.
Writers can create/update those records but cannot read values/metadata, list,
patch, delete, mint tokens, or edit auth roles/policies. Reader workloads retain
only their exact record-read policy. Kubernetes workload/host administration can
still expose mounted data and is a separate trust boundary.

Non-secret endpoint/path/role metadata and downloaded chart bytes necessarily enter
protected state/plans; `sensitive` redacts normal display, not persistence. Actual
tokens, API keys, database passwords and mounted values do not belong there.

## Authentication model

External OpenBao uses the requesting workload's short-lived JWT as its
TokenReview credential. Each enrolled service account receives only
`create` on `authentication.k8s.io/tokenreviews`. It does **not** receive the
broader `system:auth-delegator` role, Secret access, token issuance or RBAC writes.
TokenReview permission is cluster-scoped and cannot be restricted to a particular
reviewed token or namespace. A holder can submit other tokens for review. This
is an explicit trade-off, not an application requirement hidden in the provider.

This avoids a separate stored reviewer token, renewal daemon and recovery
dependency. The workload token must have an audience accepted by the Kubernetes
API **and** the exact OpenBao role. OpenBao verifies it with the API over the
supplied CA. The API performs issuer, expiry and revocation checks; duplicate
OpenBao issuer validation is disabled. There is no JWT-only/offline fallback.

The configuration explicitly clears `token_reviewer_jwt` and disables use of a
local mounted reviewer token. Do not apply it to an unrelated or shared existing
mount: it changes the reviewer model for every role at that mount.

The provider must obtain fresh short-lived tokens rather than store a static
workload token. OpenBao tokens issued to workloads have a 300-second TTL and a
600-second maximum TTL, without the default policy. Kubernetes revocation blocks
new logins; it does not instantly revoke an already issued OpenBao token. Provider
caching and the existing token's remaining lifetime must be included in live
denial/expiry evidence. Changing role TTLs does not revoke older issued tokens.

## Ownership

Follow [ADR 002][ownership]. Each deployed object has one OpenTofu owner:

| Owner | Managed declaration | Responsibility |
| --- | --- | --- |
| Kubernetes platform | `runtime/secrets.tf` shared resources | Native charts, verified worker prerequisites, auth mount/config and exact TokenReview ClusterRole |
| Owning service | Its `modules/openbao-access` instance | Exact record-read policy, account-bound auth role, reviewer binding and SecretProviderClass |
| Owning service | Its namespace/account and workload resources | Workload identity and read-only class consumption |
| Operator | Protected value-enrollment workflow | Secret population and independent OpenBao recovery custody |

The service caller declares its namespace and account in its own OpenTofu root;
the access module does not create them. For the built-in qualification service,
the runtime root declares `secrets-check` and `reader` and orders their creation
before the access module. No manual namespace/account creation is required.
Review existing object names before applying and stop on an ownership conflict.
Do not let each service reconcile the shared platform resources.

Authorization is at the whole KV-v2 record path, **not an individual field**.
`secret_key` selects the mounted field; it does not restrict what an issued token
can read from that record. Put independently authorized values in separate records.
No wildcard paths, list/write permissions or implicit parent-path access are
generated. File mode is `0444` for non-root ordinary/Kata readers; that is readable
by every process that can access the volume, not UID-exclusive access. Mount the
volume read-only only into the intended container. Kubernetes Secret synchronization
is absent; provider-internal HMAC metadata is a separate concern.

## Optional offline contract inspection

Normal deployment does not require these JSON/YAML exports or a duplicate
endpoint input file. The preparation helpers only support offline comparison and
render checks. **Do not apply their exports**, even when complete: use the
managed declarations and reviewed plan above.

Use Python 3 and PyYAML, already required by `make validate`. Create a private JSON
file outside Git, owned by the current operator with mode `0600` or `0400`.
Symlink inputs are rejected. Do not include credentials, JWTs, private keys or
secret values. Unknown and duplicate JSON fields are rejected.

The input schema below is illustrative, not a deployable configuration. All
names and locators are synthetic. Supply the actual Kubernetes CA certificates
and verified API audience privately; do not infer the audience from API DNS,
issuer text or this example. Changing API audiences is not part of enrollment.

```json
{
  "openbao_address": "https://bao.example.invalid:8200",
  "kubernetes_host": "https://api.example.invalid:6443",
  "kubernetes_ca_cert": "REPLACE WITH THE ACTUAL PEM CERTIFICATE BUNDLE",
  "api_audience": "REPLACE WITH AN EXISTING API-ACCEPTED AUDIENCE",
  "auth_mount": "kubernetes-platform",
  "service": {
    "namespace": "demo",
    "service_account": "reader",
    "role": "demo-reader",
    "policy": "demo-reader",
    "provider_class": "demo-files",
    "objects": [
      {
        "file_name": "password",
        "secret_path": "apps/data/demo",
        "secret_key": "password"
      }
    ]
  }
}
```

Names use lowercase DNS labels, at most 63 characters. HTTPS origins cannot
contain credentials, URL paths, queries or fragments. The CA field accepts only
PEM certificates. Successful offline parsing does not establish that the CA,
certificate validity, API audience or OpenBao hostname matches a live endpoint.
The provider uses normal HTTPS certificate verification and system trust for
OpenBao; private OpenBao CA distribution needs a separately reviewed integration.
There are one to 32 unique simple filenames, each with a simple field name and
an exact `<mount>/data/<record>` KV-v2 path. No KV-v1, dynamic-secret, version-query
or nested-field syntax is supported by this initial interface.

From this service directory:

```bash
python3 -B scripts/prepare-secret-auth.py \
  --input /protected/location/auth.json \
  --output-dir /protected/location/prepared-auth
```

- `--input PATH`: required protected JSON configuration, at most 1 MiB.
- `--output-dir PATH`: required new directory outside this repository. Its parent
  must already exist. The tool creates mode `0700` with mode `0600` files.
- `--help`: show the command contract without reading configuration.

Exit `0` means the files were prepared, not that authentication works. Exit `1`
means validation or file creation failed; argument errors use exit `2`. Values and
endpoints are not printed. The tool never overwrites an existing directory. An
I/O failure can leave a partial new directory. Inspect privately and use a new
destination for another attempt. Complete and partial exports alike are only
inspection material, not deployment inputs. Keep them out of Git, tickets and
shared logs; managed metadata enters protected state through its owning resources.

## Authorized enrollment and acceptance

Rendering grants no live-change authority. Before deployment:

1. Verify OpenBao HTTPS trust, API HTTPS/CA trust from the external OpenBao host,
   supported Kubernetes auth plugin/provider behavior, and the actual API audience.
   Preserve the initialized cluster and manual-unseal/recovery boundary.
2. Inspect live ownership. The platform owner declares/imports the dedicated
   Kubernetes auth mount and shared ClusterRole in the owning OpenTofu state,
   reviews their exact configuration and applies the inspected plan. Do not
   overwrite a mount whose consumers are unknown.
3. The service owner declares its namespace/account and access module, then
   reviews/applies only that owned definition through OpenTofu. Populate actual
   values separately via protected files/stdin through the approved API/CLI.
   Keep operator tokens out of argv/history, disable tracing and avoid printing
   token-bearing API responses. Never apply inspection exports as a second writer.
4. With an approved pinned CSI/provider installation, mount the generated class
   from the exact account using a read-only inline `secrets-store.csi.k8s.io` volume.
   Keep Secret synchronization disabled. Confirm `0444` non-root reads and actual
   runc/Kata execution on both workers under SELinux enforcing. Provider socket
   labeling and chart installation use the separate procedures below.
5. Test allowed and forbidden namespace/account/path requests, wrong audience,
   token expiry and service-account revocation with owned synthetic data. Do not
   publish JWTs, issued OpenBao tokens, mounted values or API responses. Confirm a
   fresh token can authenticate again without replacing reviewer credentials.
6. Verify file rotation separately from actual application reload, distinct
   existing/new-consumer behavior during an approved OpenBao failure, and fresh
   mounts after approved provider/worker maintenance. These remain runtime gates,
   not claims established by rendering.

On an outage, existing files may remain readable while refresh or new mounts fail.
Do not promise immediate erasure or revocation of mounted content. Preserve useful
values and the existing auth configuration during diagnosis; do not seal OpenBao,
delete an auth mount or reset the cluster as automatic rollback. To remove one
service's access, review its provider class, reviewer binding, role, policy and
issued-token lifecycle without removing the shared mount or ClusterRole.

## Pinned CSI and provider stack

`platform/secrets-csi.yaml.tftpl` is a blueprint, **not an installable manifest**.
It selects Secrets Store CSI Driver **1.6.2**, OpenBao chart **0.30.7** with only
provider **2.0.3**, and digest-pinned driver, registrar, liveness and provider
images. The qualification application image is pinned too. Versions retain the
earlier synthetic compatibility baseline; this is not production acceptance or
a claim that every selected version is the latest release.

Chart archives are not stored in Git. With the platform enabled, normal runtime
planning downloads both pinned HTTPS release URLs from the blueprint annotations
through `download-secret-chart.py`. A changed checksum, unavailable source or
download failure stops planning. No cached or vendored fallback is used.
OpenTofu embeds the verified bytes in native `chartContent`; a saved-plan apply
uses those reviewed bytes rather than downloading a potentially different chart.
Fresh planning requires a reliable internet connection. Apply and subsequent
pod scheduling also depend on reachable image registries for uncached images.
This is not an offline deployment or recovery mechanism: chart checksums and
image digests bind inputs, but provide neither availability nor independent
publisher-signature attestations.

For optional offline rendering, download the same pinned archives outside Git
and pass their paths explicitly to the preparer. It checks SHA-256 before Helm
sees them, renders verified bytes for RKE2 1.36.6 and checks the resource, image
and security contract. These inspection exports remain non-deployable second
writers; the owning OpenTofu root performs the live download and reconciliation.

With Helm available and `service-enrollment.yaml` prepared above:

```bash
make secrets-csi-prepare \
  CSI_DRIVER_CHART=/protected/location/secrets-store-csi-driver-1.6.2.tgz \
  CSI_PROVIDER_CHART=/protected/location/openbao-0.30.7.tgz \
  SECRET_ENROLLMENT=/protected/location/prepared-auth/service-enrollment.yaml \
  SECRETS_OUTPUT=/protected/location/prepared-csi
```

The script's required flags are `--driver-chart PATH`, `--provider-chart PATH`
and `--enrollment PATH`. `--helm EXECUTABLE` defaults to `helm`.
`--output-dir PATH` is optional: omit it, or use `make secrets-csi-validate`,
for validation only. The enrollment must be a protected regular file with one
OpenBao class, no Secret synchronization and the expected verified-HTTPS
parameters. The script copies its audience and OpenBao origin into the installer;
it does not infer or change API audiences. All classes using this initial driver
must use that same API-accepted audience. Multiple audience support needs review.

The optional new output directory is mode `0700` with two mode-`0600` files:

- `secrets-csi.yaml`: namespace and two native RKE2 HelmChart objects.
- `rendered.yaml`: the exact local Helm render for private inspection/schema checks.

Existing output directories are never overwritten. Exit `0` means validation
passed, exit `1` means preparation failed, and argument errors use exit `2`.
Values and endpoint-bearing render failures are not printed. A file-write failure
can leave partial output; do not apply partial artifacts. Keep both files outside
Git/state/plans/logs. `make validate` covers local code/template contracts and the
reload application, without downloading charts or contacting infrastructure.
The separate chart targets exercise actual Helm rendering with supplied archives.

### Runtime security and ownership

Both DaemonSets select only workers with the administrator-controlled
`homelab.node-restriction.kubernetes.io/secrets-ready=true` capability label.
An unlabeled replacement cannot silently start the stack before host checks.
The privileged namespace is only for trusted CSI components, not applications.
Native Helm installer jobs are RKE2 controller operations; the worker selector
applies to the installed CSI/provider DaemonSets.

The Linux CSI driver keeps its required privileged, bidirectional kubelet mounts.
The OpenBao provider is UID 0/GID 1000 but **not privileged**, drops all
capabilities, denies privilege escalation, uses a read-only root filesystem and
RuntimeDefault seccomp. The chart's container security context is specified in
full because setting a partial context replaces its defaults. Server, injector,
agent, Windows components and workload-Secret synchronization are disabled.
Provider debug logging and its in-memory token cache are disabled; fresh rotation
requests must authenticate again. No OpenBao server or cache sidecar is installed.

The CSIDriver requests a pod-bound token for the configured API audience with
600-second requested lifetime. Verify the actual lifetime and renewal at runtime.
Kubelet's `serviceAccountTokenInSecrets: true` puts the JWT in the CSI RPC's
sensitive `secrets` map; it **does not create a Kubernetes Secret object**.
The provider consumes the audience-matching forwarded token. Its stock chart
also retains cluster-wide `serviceaccounts/token` creation permission for its
token-request fallback: this trusted provider is not a workload least-privilege
boundary. Qualification must confirm the normal forwarded pod-bound path rather
than infer it from the configuration.

The provider retains namespaced access to its HMAC-key Secret: `get` of the named
key and `create` in `secrets-system` (Kubernetes cannot resource-name-restrict
creation). That internal version-HMAC key is not synchronized workload content.
Do not store application values there or grant this provider account to workloads.
The CSI driver has no Secret-read/write synchronization RBAC.

The chart includes the two upstream CRDs on initial installation. Its
CRD upgrade-hook Job is disabled. Helm does not automatically upgrade CRDs in
`crds/`; future version changes require a separately reviewed CRD migration and
ownership check, not blind chart replacement. Check existing CRDs, CSIDriver,
release names, RBAC and namespace ownership before installation. Do not adopt a
second driver/provider owner.

### Worker provider-directory preparation

`terraform_data.secrets_provider_directory` runs the source-controlled
`label-secrets-provider.py --apply` over agent-authenticated SSH with the pinned
public host key. It checks the approved Node UID before execution and the
capability-label resource rechecks the Node after preparation. Script/Node UID
changes retrigger preparation. It is a bounded apply-time enrollment operation,
not a general remote configuration provider or continuous OS-drift detector.
Do not replace/delete/re-enroll nodes between plan review and apply. A registered
worker replacement must remove its old Node and require new UID/host-key review.

For a separately approved read-only drift/preflight check, run the same script
as root without flags. Do not rerun host changes or set capability labels outside
the owned lifecycle just to hide a failed plan:

```bash
sudo python3 -B /protected/location/label-secrets-provider.py
```

It requires an enrolled Rocky 10 amd64 worker with active RKE2 agent, enforcing
SELinux and no control-plane datastore/server. It does not install packages,
change cloud-init, restart services, set cluster labels or weaken SELinux.
The existing worker package baseline supplies the SELinux tools.
The only mapping is `/etc/kubernetes/secrets-store-csi-providers(/.*)?` to
`container_file_t:s0`. Conflicting exact mappings, symlinks and unrelated provider
contents cause a stop; they are not overwritten. `--apply` restores labels only
inside that directory and never changes existing directory/socket permissions.
Failure may leave an added mapping or created directory; inspect rather than
blindly retry or delete it. Both the persistent mapping and current labels must
pass before OpenTofu grants the capability label on the exact verified worker.

This is the accepted shared-container-data exception, not provider-exclusive
socket isolation. Do not broaden it to kubelet directories, add allow rules or
use privileged provider mode. Keep workload hostPath/privilege restrictions.
The local mapping and labels persist across normal reboot; after any replacement,
repeat preparation before restoring the capability label. No immutable VM
bootstrap or control-plane identity changes are needed.

After ownership/trust review and explicit deployment approval, apply the managed
HelmChart API resources through the inspected OpenTofu plan. **Do not install the
inspection manifest in the RKE2 server manifest directory**: that creates another
writer. Wait for both worker DaemonSets and node registrations, the two CRDs and
expected releases before the service-definition phase. Qualification resources
are also OpenTofu-owned, not server-directory AddOns.

## Owned ordinary/Kata qualification

Use only a new, approved `secrets-check` namespace, `reader` service account and
`qualification-files` class mapping one synthetic field to filename `value`.
The service-owned OpenBao role must bind that exact account and namespace. Stop
if these names already belong to something else. The example namespace is
restricted; its NetworkPolicy denies application ingress/egress, and no Service
or VLAN address is allocated. Use authorized pod exec with loopback requests;
check node readiness probes under the actual Cilium policy.

Use the phased OpenTofu qualification declaration above, not a separate
`kubectl apply` of the sample. `examples/secrets-workloads.yaml` remains the
source blueprint for the managed policy and Deployments; `secret-reload.py`
supplies only non-secret source for the managed `reload-app` ConfigMap. With
replicas enabled, two ordinary and two explicit Kata consumers run one of each
per verified worker, without service-account token mounts, writable secret
mounts, hostPath or writable root filesystems.

The sample application polls `/secrets/value` and keeps its active value **only
in memory**. It reopens the path rather than watching an old inode or using a
subPath mount, so CSI atomic replacement can be observed. It accepts at most
64 KiB. No mounted values, digests or request bodies are logged or returned:

- `GET /ready` reports only whether any value was loaded. It does not establish
  refresh health and remains ready with an old loaded value during an outage.
- `POST /verify` takes expected raw bytes in the body and returns only `matches`
  and an application reload counter. This is a **synthetic test oracle**, not a
  production endpoint: keep it inaccessible to peers/public clients and use
  high-entropy owned test values. Do not pass expected values in URLs or argv.

Use a protected client input/stdin and suppress request/response tracing. Prove
the first value matches, rotate the owned OpenBao record, observe mounted-file
delivery separately, and then prove the second value matches, the first no longer
matches and the in-memory reload counter increased on all four consumers.
The driver polls every two minutes and the application every second; record actual
elapsed times without promising a hard refresh SLA. Offline tests prove the
application reacts to local atomic file replacement, not production CSI rotation.

Record actual Kata/KVM execution, non-root identity, `0444` read-only files,
host tmpfs-backed CSI targets and enforcing SELinux on both workers. Exercise
wrong account/path/audience and expired/revoked identities without emitting
values or tokens. Review any OpenBao unavailability or provider/worker restart
test separately so unrelated users and the initialized cluster are preserved.
Scale down and remove only owned test resources/roles/values after approved
disposition. Preserve the existing NFS witness claim and shared platform objects.

[ownership]: ../../docs/adrs/002-openbao-service-configuration-ownership.md
[administrative-auth]: ../../docs/adrs/008-openbao-administrative-authorization.md
[deployment-credentials]: ../openbao/README.md#service-deployment-credentials
[runtime-state]: ../../docs/adrs/006-kubernetes-runtime-state-boundary.md
