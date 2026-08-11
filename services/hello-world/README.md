# Hello World

Hello World is an integration test for deploying services to Incus on the
[Micro Node]. It creates a small Debian instance, obtains an IPv4 address over
DHCP, installs Nginx, and verifies the local HTTP endpoint.

## Dependencies

- A prepared [Micro Node] with its `default` directory pool and unmanaged `br0`
  bridge
- A trusted Incus remote on the management workstation
- DHCP and network access on a VLAN
- OpenTofu 1.6 or newer, `make`, and `yamllint`

## Quick Start

1. Create the local configuration.

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Initialize and validate the root.

   ```bash
   make init
   make validate
   ```

3. Create and review a saved plan.

   ```bash
   make plan
   tofu show deployment.tfplan
   ```

4. Apply the reviewed plan and test the service from the management network.

   ```bash
   make apply
   curl "http://$(tofu output -raw ipv4_address)/hello-world"
   ```

The response is `hello world`. A successful apply confirms that OpenTofu can
reach the Incus remote, the expected storage pool and bridge exist, cloud-init
can use IPv4 DHCP, and the instance can install and serve Nginx.

OpenTofu uses local state in this directory. State and local variable files are
ignored by Git.

## Troubleshooting

Inspect the instance, DHCP address, cloud-init status, and HTTP endpoint:

```bash
incus list <remote-name>: hello-world
incus config show <remote-name>:hello-world
incus exec <remote-name>:hello-world -- cloud-init status --long
incus exec <remote-name>:hello-world -- curl --fail http://127.0.0.1/hello-world
```

[Micro Node]: ../../hosts/micro-node/README.md
