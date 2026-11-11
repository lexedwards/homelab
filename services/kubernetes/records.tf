module "worker_dns" {
  source = "./modules/worker-dns"

  zone             = var.api_dns.zone
  ttl              = var.api_dns.ttl
  reverse_zone     = var.worker_reverse_dns_zone
  cluster_networks = var.cluster_networks
  workers = {
    for host, vm in proxmox_virtual_environment_vm.worker : host => {
      fqdn           = var.workers[host].fqdn
      primary_mac    = vm.network_device[0].mac_address
      mac_addresses  = vm.mac_addresses
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}
