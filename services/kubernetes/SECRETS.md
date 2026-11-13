# OpenBao Mounted-Secret Authentication

`scripts/prepare-secret-auth.py` prepares the platform authentication contract and
one service's exact enrollment. It runs offline, does not read secret values or
credentials, and does not contact Kubernetes or OpenBao.
`scripts/prepare-secrets-csi.py` verifies the pinned CSI/provider charts and
prepares their native RKE2 installer separately. Neither tool deploys anything
or changes a running service. ALE-49 owns authorized production qualification.

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

Follow [ADR 002][ownership]:

| Owner | Prepared artifact | Responsibility |
| --- | --- | --- |
| Kubernetes platform | `platform-auth-config.json` | One Kubernetes auth mount, stable API identity, CA and reviewer model |
| Kubernetes platform | `platform-tokenreview-role.yaml` | One shared exact TokenReview ClusterRole |
| Owning service | `service-policy.hcl` | Read-only exact KV-v2 data paths |
| Owning service | `service-role.json` | Exact namespace/account binding, audience, policy and TTL |
| Owning service | `service-enrollment.yaml` | Its reviewer binding and SecretProviderClass |
| Operator | No generated value artifact | Secret population and independent OpenBao recovery custody |

No service account or namespace is created or adopted by this tool. Their owner
must create them first. Review existing role, policy, binding and provider-class
names before applying anything. Stop on an ownership conflict. Each object must
have one writer; do not make every service reconcile the platform files.

Authorization is at the whole KV-v2 record path, **not an individual field**.
`secret_key` selects the mounted field; it does not restrict what an issued token
can read from that record. Put independently authorized values in separate records.
No wildcard paths, list/write permissions or implicit parent-path access are
generated. File mode is `0444` for non-root ordinary/Kata readers; that is readable
by every process that can access the volume, not UID-exclusive access. Mount the
volume read-only only into the intended container. Kubernetes Secret synchronization
is absent; provider-internal HMAC metadata is a separate concern.

## Prepare a private enrollment

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
I/O failure can leave a partial new directory; do not apply partial artifacts.
Inspect privately and use a new destination for another attempt. Do not copy
prepared files into Git, OpenTofu inputs/state/plans, tickets or shared logs.

## Authorized enrollment and acceptance

Rendering grants no live-change authority. Before deployment:

1. Verify OpenBao HTTPS trust, API HTTPS/CA trust from the external OpenBao host,
   supported Kubernetes auth plugin/provider behavior, and the actual API audience.
   Preserve the initialized cluster and manual-unseal/recovery boundary.
2. Inspect live ownership. The platform owner enables a new dedicated Kubernetes
   auth mount if absent, reviews its exact configuration and the shared ClusterRole,
   and applies them once. Do not overwrite a mount whose consumers are unknown.
3. The service owner creates its namespace/account, writes its exact policy and
   role, and applies only its service enrollment. Send JSON/HCL via protected files
   or stdin through the approved CLI/API. Keep operator tokens out of argv/history,
   disable tracing and avoid printing token-bearing API responses. Define secret
   paths, schemas, access rules and lifecycle procedures alongside the owning
   service. Populate actual values through a protected enrollment workflow that
   does not persist them in Git, OpenTofu state, saved plans or logs.
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

Download the two public chart archives from the blueprint's source annotations
into an operator-owned location. The preparer checks their exact SHA-256 values
before Helm sees them, renders copies of those verified bytes locally for RKE2
1.36.6, and checks the resulting resource, image and security contract. It embeds
the same verified bytes in `chartContent`; installation does not fetch an archive
from a release URL. Publisher-index checksums and registry manifest digests bind
the reviewed inputs, but are not independent publisher-signature attestations.

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

After explicit host-change approval, copy `scripts/label-secrets-provider.py` to
each selected worker through the existing pinned SSH trust path. Run it as root
without flags to **check only**, or with `--apply` to add the approved mapping:

```bash
sudo python3 -B /protected/location/label-secrets-provider.py --apply
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
pass before an administrator sets the capability label on the exact worker.

This is the accepted shared-container-data exception, not provider-exclusive
socket isolation. Do not broaden it to kubelet directories, add allow rules or
use privileged provider mode. Keep workload hostPath/privilege restrictions.
The local mapping and labels persist across normal reboot; after any replacement,
repeat preparation before restoring the capability label. No immutable VM
bootstrap or control-plane identity changes are needed.

After ownership/trust review and explicit deployment approval, install only the
prepared `secrets-csi.yaml` as root-owned mode `0600` in the existing RKE2 server
manifest directory. Wait for both worker DaemonSets and both node registrations,
the two CRDs and expected Helm releases before service enrollment or test pods.
Do not persist qualification workloads in that auto-reconciled directory.

## Owned ordinary/Kata qualification

Use only a new, approved `secrets-check` namespace, `reader` service account and
`qualification-files` class mapping one synthetic field to filename `value`.
The service-owned OpenBao role must bind that exact account and namespace. Stop
if these names already belong to something else. The example namespace is
restricted; its NetworkPolicy denies application ingress/egress, and no Service
or VLAN address is allocated. Use authorized pod exec with loopback requests;
check node readiness probes under the actual Cilium policy.

After separate synthetic-value/enrollment approval, create the owned namespace
and account first, enroll its exact role/class, and create `reload-app` from
`examples/secret-reload.py` using `--from-file=reload.py=examples/secret-reload.py`.
Only this non-secret application source belongs in that ConfigMap. Then apply
`examples/secrets-workloads.yaml`: it creates two ordinary and two explicit Kata
consumers, one of each per verified worker, without service-account token mounts,
writable secret mounts, hostPath or writable root filesystems.

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
