# Store

This OpenTofu root is the starting point for managing the `store` Proxmox VE
host. It currently configures the provider only and manages no resources.

## Quick Start

1. Create the local endpoint configuration.

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Initialize and validate the root.

   ```bash
   make init
   make validate
   ```

These commands download the provider and validate the configuration. They do
not contact the Proxmox API or deploy anything.

Store-hosted service roots include the
[Observability Warehouse](../../services/observability-warehouse/README.md),
whose OpenTofu root also manages its compute-hosted telemetry collector and
Grafana VMs.

Before a future online operation, provide a least-privilege API token outside
the OpenTofu files:

```bash
export PROXMOX_VE_API_TOKEN='user@realm!token-id=token-secret'
```

OpenTofu uses local state in this directory. State, saved plans, and local
variable files are ignored by Git.
