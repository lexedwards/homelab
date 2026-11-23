# Kubernetes tools

| Directory | Purpose | Execution |
| --- | --- | --- |
| `bootstrap/` | Discovery/native restoration, identity/completion, enrollment, publication, custody preparation and shared libraries | Guest systemd/SSH hooks or explicit operator commands |
| `workers/` | Fresh-worker enrollment using a short-lived native token | Explicit operator command after provisioning |
| `charts/` | Checksum-pinned chart download and native chart/Alloy validation | Runtime external-data source or offline operator tools |
| `secrets/` | Offline auth/CSI inspection and exact worker provider-directory preparation | Operator inspection or runtime SSH prerequisite |
| `checks/` | Live readiness/policy probes and isolated bootstrap/enrollment fixtures | Explicit live checks or local Make validation |

Bootstrap CLI tools and their two importable libraries stay together so both
source execution and the fixed guest installation use the same sibling imports.
Installed guest paths remain flat under `/usr/local/libexec/homelab`; source
grouping does not add a Python packaging/deployment framework.

`issue-storage-credentials.py` issues either backup or publisher credentials;
`prepare-provider-directory.py` prepares SELinux filesystem labels, not Kubernetes
Node labels. `download-chart.py` serves both secrets and observability.
`backup-recovery-custody.py` writes an attestation, not a backup of token values.

Manual preparation/issuance/enrollment tools are not implicitly called by
`make validate`. `prepare-recovery.py` creates and verifies a fresh off-node point
before a separately approved replacement; it never schedules backups or destroys
infrastructure. Native RKE2 owns scheduling/upload/retention and membership reset.

Use each CLI's `--help` and the linked service runbooks. Preserve protected inputs
and phase receipts on failure; do not replay issuance/reset operations blindly.
