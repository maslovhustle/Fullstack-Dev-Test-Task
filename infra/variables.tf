variable "server_name" {
  description = "Name of the server, its Hetzner resources and its Tailscale node."
  type        = string
  default     = "ghost"
}

variable "server_type" {
  description = "Hetzner server type."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location."
  type        = string
  default     = "fsn1"
}

variable "image" {
  description = "Server image. bootstrap.sh targets Ubuntu 24.04."
  type        = string
  default     = "ubuntu-24.04"
}

variable "volume_size_gb" {
  description = "Size of the persistent data volume."
  type        = number
  default     = 20
}

variable "ghost_domain" {
  description = "Blog domain. Empty means <ip>.sslip.io."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email for Let's Encrypt notices."
  type        = string
}

variable "tailscale_auth_key" {
  description = "Used once, on first boot. Later boots reuse the node state on the volume."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public key installed for root."
  type        = string
}

variable "existing_ssh_key_id" {
  description = "ID of this key if it is already in the Hetzner project (keys must be unique)."
  type        = string
  default     = ""
}

variable "protect_data" {
  description = "Delete protection for the data volume and the public IP."
  type        = bool
  default     = true
}
