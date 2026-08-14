data "http" "amazon_linux_2023" {
  url = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm/SHA256SUMS"
}

data "http" "fedora_releases" {
  url = "https://fedoraproject.org/releases.json"
}

data "http" "rocky_linux_10" {
  url = "https://download.rockylinux.org/pub/rocky/10/images/x86_64/CHECKSUM"
}

data "http" "ubuntu_26_04_build" {
  url = "https://cloud-images.ubuntu.com/releases/resolute/release/unpacked/build-info.txt"
}

data "http" "ubuntu_26_04_checksums" {
  url = "https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS"
}

locals {
  amazon_linux_2023_match = regex(
    "^([0-9a-f]{64})  (al2023-kvm-([0-9][0-9.]+)-kernel-6\\.1-x86_64\\.xfs\\.gpt\\.qcow2)$",
    trimspace(data.http.amazon_linux_2023.response_body),
  )

  fedora_44_matches = [
    for image in jsondecode(data.http.fedora_releases.response_body) : image
    if image.version == "44" &&
    image.arch == "x86_64" &&
    image.variant == "Cloud" &&
    image.subvariant == "Cloud_Base" &&
    strcontains(image.link, "/Fedora-Cloud-Base-Generic-") &&
    endswith(image.link, ".x86_64.qcow2")
  ]
  fedora_44 = one(local.fedora_44_matches)

  rocky_linux_10_match = regex(
    "SHA256 \\((Rocky-10-GenericCloud-Base-([0-9]+\\.[0-9]+-[0-9]+\\.[0-9]+)\\.x86_64\\.qcow2)\\) = ([0-9a-f]{64})",
    data.http.rocky_linux_10.response_body,
  )

  ubuntu_26_04_serial = one(regex(
    "(?m)^serial=([0-9]{8})$",
    data.http.ubuntu_26_04_build.response_body,
  ))
  ubuntu_26_04_checksum = one(regex(
    "(?m)^([0-9a-f]{64}) \\*ubuntu-26\\.04-server-cloudimg-amd64\\.img$",
    data.http.ubuntu_26_04_checksums.response_body,
  ))

  release_channels = {
    "amazon-linux-2023" = {
      url             = "https://cdn.amazonlinux.com/al2023/os-images/${local.amazon_linux_2023_match[2]}/kvm/${local.amazon_linux_2023_match[1]}"
      sha256_checksum = local.amazon_linux_2023_match[0]
    }
    "fedora-44" = {
      url             = local.fedora_44.link
      sha256_checksum = local.fedora_44.sha256
    }
    "rocky-linux-10" = {
      url             = "https://download.rockylinux.org/pub/rocky/10/images/x86_64/${local.rocky_linux_10_match[0]}"
      sha256_checksum = local.rocky_linux_10_match[2]
    }
    "ubuntu-26.04" = {
      url             = "https://cloud-images.ubuntu.com/releases/resolute/release-${local.ubuntu_26_04_serial}/ubuntu-26.04-server-cloudimg-amd64.img"
      sha256_checksum = local.ubuntu_26_04_checksum
    }
  }

  cloud_images = {
    for name, image in var.cloud_images : name => merge(
      image,
      local.release_channels[image.release_channel],
    )
  }
}
