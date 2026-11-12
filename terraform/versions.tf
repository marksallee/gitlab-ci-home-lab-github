terraform {
  required_version = ">= 1.7" # import blocks with for_each

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
