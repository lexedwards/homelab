# OpenBao Mounted-Secret Authentication

`scripts/prepare-secret-auth.py` prepares the platform authentication contract and
one service's exact enrollment. It runs offline, does not read secret values or
credentials, and does not contact Kubernetes or OpenBao. It does not install the
Secrets Store CSI driver/provider or change a running service. ALE-49 owns that
later integration and its production qualification.

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
   labeling and chart installation are not implemented by this preparation tool.
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

[ownership]: ../../docs/adrs/002-openbao-service-configuration-ownership.md
