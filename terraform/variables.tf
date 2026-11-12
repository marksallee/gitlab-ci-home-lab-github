variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API URL, e.g. https://192.168.50.250:8006/"
}

variable "proxmox_insecure" {
  type        = bool
  default     = true
  description = "Skip TLS verification (self-signed certificate)"
}

variable "node_name" {
  type        = string
  default     = "proxmox"
  description = "Proxmox node that hosts the containers"
}

variable "datastore_id" {
  type        = string
  default     = "lab-storage"
  description = "Thin-pool storage for container disks"
}

variable "template_file_id" {
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  description = "LXC template, already downloaded with pveam"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "gateway" {
  type        = string
  description = "Default gateway for the containers"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers handed to the containers"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "Public keys allowed to log in as root on the containers"
}

variable "containers" {
  type = map(object({
    vm_id     = number
    cores     = number
    memory_mb = number
    swap_mb   = number
    disk_gb   = number
    address   = string # CIDR, e.g. 192.168.50.251/24
  }))
  description = "The three lab containers, keyed by hostname"
}
