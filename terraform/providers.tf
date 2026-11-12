# Credentials come from the environment, never from files in this repo:
#   export PROXMOX_VE_API_TOKEN="terraform@pve!<token-id>=<secret>"
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure # self-signed certificate in the lab
}
