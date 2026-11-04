output "public_ip" {
  value = hcloud_primary_ip.ghost.ip_address
}

output "domain" {
  value = local.domain
}

output "firewall_id" {
  value = hcloud_firewall.ghost.id
}

output "server_id" {
  value = hcloud_server.ghost.id
}

output "server_name" {
  value = var.server_name
}
