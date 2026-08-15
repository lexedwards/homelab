# Image Catalogue

Image Catalogue downloads curated cloud images and exposes them as uniform
Proxmox VM templates on the [`store` host]. Each catalogue entry manages one
downloaded image and one cloud-init-ready template.

The catalogue is intentionally empty. Add images only after selecting current
releases and verifying their publisher-provided checksums.

## Dependencies

- The prepared `store` Proxmox VE host
- Datastores that support `import` content and VM disks
- A Proxmox bridge available to cloned VMs
- OpenTofu 1.6 or newer and `make`
- A least-privilege Proxmox API token and PAM user with SSH access
- The PAM user's private key stored outside this repository

## Quick Start

1. Create the local configuration.

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   Set the endpoint, API token, SSH username and private-key path, VM datastore,
   cloud-init user, and real SSH public keys. The ignored variable file contains
   credentials in plaintext and must remain readable only by its owner.

2. Initialize and validate the root.

   ```bash
   make init
   make validate
   ```

3. After catalogue entries have been curated, create and review a saved plan.

   ```bash
   make plan
   tofu show deployment.tfplan
   ```

4. Apply only the reviewed plan.

   ```bash
   make apply
   ```

OpenTofu uses local state in this directory. State, saved plans, and local
variable files are ignored by Git.

## Catalogue Entries

`cloud_images` is a map keyed by the Proxmox template name. Each entry requires
an explicit VM ID, supported release channel, downloaded file name, and template
disk size. QEMU guest agent support defaults to enabled and can be disabled per
image.

The supported channels are `amazon-linux-2023`, `debian-13`, `fedora-44`,
`rocky-linux-10`, and `ubuntu-26.04`. OpenTofu reads official publisher metadata
during each refreshed plan and resolves the selected channel to an immutable
image URL, its published checksum, and the checksum algorithm. Channel names
deliberately pin major releases; upgrading to a new Debian, Fedora, or Ubuntu
release remains a reviewed code change.

| Channel | Publisher metadata | Immutable selection |
| --- | --- | --- |
| `amazon-linux-2023` | [`latest/kvm/SHA256SUMS`][amazon-checksums] | The manifest filename contains the release ID used in the versioned URL. |
| `debian-13` | [Genericcloud amd64 metadata][debian-metadata] and [`SHA512SUMS`][debian-checksums] | The metadata build version selects the versioned release directory and matching qcow2 checksum. |
| `fedora-44` | [`releases.json`][fedora-releases] | The Cloud Base Generic x86_64 entry supplies the exact URL and checksum. |
| `rocky-linux-10` | [Rocky 10 `CHECKSUM`][rocky-checksums] | The versioned GenericCloud Base entry is selected instead of its mutable `latest` alias. |
| `ubuntu-26.04` | [Resolute `SHA256SUMS`][ubuntu-checksums] and [`build-info.txt`][ubuntu-build] | The build serial selects the dated release directory and the manifest supplies its checksum. |

Explicit VM IDs keep existing templates stable when another image is added or
removed. A new build within a selected channel changes the download checksum
and replaces its template. Always review the saved plan before applying it.

The catalogue owns its configured datastore filenames. If a same-named file
already exists outside this OpenTofu state, the download resource deletes and
replaces that file before validating the new content against the publisher's
checksum. This permits migration from older catalogue roots without accepting
stale image bytes.

The metadata and image are retrieved over HTTPS from the same publisher. This
validates downloaded bytes against the publisher's advertised checksum but does
not verify detached release signatures. Metadata endpoint failure stops the
plan rather than retaining stale release information.

Review `cloud_image_sources` in the saved plan to see the exact immutable URLs,
checksums, and checksum algorithms selected by the current publisher metadata.

Changing an entry's downloaded image replaces its template so the source disk
is imported again. Review plans for this replacement before applying updates.

The generated templates use UEFI Secure Boot, a Q35 machine, VirtIO SCSI and
network devices, DHCP, and a serial console. Confirm that each selected image
supports these defaults before adding it to the catalogue.

[`store` host]: ../../hosts/store/README.md
[amazon-checksums]: https://cdn.amazonlinux.com/al2023/os-images/latest/kvm/SHA256SUMS
[debian-checksums]: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS
[debian-metadata]: https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.json
[fedora-releases]: https://fedoraproject.org/releases.json
[rocky-checksums]: https://download.rockylinux.org/pub/rocky/10/images/x86_64/CHECKSUM
[ubuntu-build]: https://cloud-images.ubuntu.com/releases/resolute/release/unpacked/build-info.txt
[ubuntu-checksums]: https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS
