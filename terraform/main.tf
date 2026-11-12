resource "proxmox_virtual_environment_container" "lxc" {
  for_each = var.containers

  node_name     = var.node_name
  vm_id         = each.value.vm_id
  description   = "Managed by Terraform: GitLab CI home lab (${each.key})"
  unprivileged  = true
  start_on_boot = true
  started       = true

  # nesting + keyctl let Docker run inside an unprivileged container
  features {
    nesting = true
    keyctl  = true
  }

  # Proxmox defaults, declared so the imported containers show no drift
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory_mb
    swap      = each.value.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = each.value.disk_gb
  }

  network_interface {
    name   = "eth0"
    bridge = var.bridge
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "ubuntu"
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  lifecycle {
    # The template is only used at creation; changing it must not rebuild a running node.
    ignore_changes = [operating_system, initialization[0].user_account]
  }
}
