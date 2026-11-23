# Kubernetes

This directory is the service entry point, not an OpenTofu deployment root.
Deploy from the owning subdirectory; the top-level Makefile only coordinates
local preparation and checks.

| Root | Owns | Requires a running Kubernetes API? |
| --- | --- | --- |
| [bootstrap](bootstrap/README.md) | External backup/configuration buckets and OpenBao bootstrap/value-enrollment authorization | No |
| [infrastructure](infrastructure/README.md) | Proxmox VMs, DNS, immutable installation and verified-SSH enrollment | No for VM recovery planning |
| [runtime](runtime/README.md) | API-managed telemetry, mounted workload secrets and private DNS forwarding | Yes |

Each root has its own state. Keep bootstrap resources through VM replacement:
destroying compute must not destroy snapshots or the independent token source.
Native RKE2 owns snapshot scheduling, upload, count retention and membership reset.

## Clean deployment

1. Choose a new stable friendly cluster name and disjoint OpenBao record paths.
   Confirm the previous owners are empty before reusing any VM/DNS identity.
   Never copy obsolete tfvars, kubeconfigs or old state into a new owner.
2. Apply bootstrap prerequisites from canonical `main` using an inspected plan.
   Issue separate scoped backup/publisher credentials and enroll them, the initial
   server token and runtime profile through protected out-of-band operations.
   Preserve independent actual-token/credential custody; no values enter state.
3. Provision infrastructure, establish the approved scoped SSH pin and introduce
   bootstrap access. A fresh host waits without enrollment. The host discovers
   create/join/restore; there is no manual mode switch or bypass of old history.
4. Enroll any workers using [the worker procedure](WORKERS.md). Export non-secret
   `runtime_connection` metadata and obtain the protected published kubeconfig.
5. Configure/apply runtime features with that reviewed connection. Verify actual
   releases, secret delivery, private DNS and warehouse ingestion as enabled.
6. Verify a real native scheduled off-node snapshot and an actual download.
   Qualify same-cluster restore separately before application adoption.

An intentionally fresh cluster is not an existing-cluster restore. Existing
identity or retained snapshot history blocks accidental creation. External
OpenBao, RustFS, TrueNAS and the telemetry warehouse remain independently owned.

## Local checks and optional tools

Run `make init`, then `make validate` and `make test`. Init fetches providers but
does not deploy. Tests use mocked providers or isolated local fixtures; passing
checks do not establish live readiness. There is no service-root plan/apply target.

[Script groups](scripts/README.md) distinguish guest runtime from operator tools
and offline inspection. [Secret-delivery qualification](examples/secret-delivery/README.md)
has a separate optional example root; it is never deployed by the three roots.

Some platform integrations retain explicitly reviewed native-manifest workflows:
[Kata/workers](WORKERS.md), [NFS](NFS.md), [service exposure](SERVICE-EXPOSURE.md)
and [network policy](NETWORK-POLICY.md). They are not silently adopted into runtime.
Consolidating their live ownership is a separate rollout, not a consequence of
moving files.

Operating guides: [recovery](RECOVERY.md), [backups](BACKUP.md),
[lifecycle](LIFECYCLE.md), [secrets](SECRETS.md), [observability](OBSERVABILITY.md).
See [ADR 017](../../docs/adrs/017-kubernetes-deployment-roots.md) for the boundary.
