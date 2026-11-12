output "container_addresses" {
  description = "Hostname to IPv4 address"
  value       = { for k, v in var.containers : k => v.address }
}
