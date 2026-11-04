locals {
  # A stable IP lets DNS be set once and survive server rebuilds.
  domain = var.ghost_domain != "" ? var.ghost_domain : "${replace(hcloud_primary_ip.ghost.ip_address, ".", "-")}.sslip.io"

  stack_files = {
    "/opt/ghost/compose.yml"                   = { source = "stack/compose.yml", mode = "0644" }
    "/opt/ghost/Caddyfile"                     = { source = "stack/Caddyfile", mode = "0644" }
    "/opt/ghost/bootstrap.sh"                  = { source = "stack/bootstrap.sh", mode = "0700" }
    "/opt/ghost/owner.sh"                      = { source = "stack/owner.sh", mode = "0644" }
    "/usr/local/bin/ghost-backup"              = { source = "stack/ghost-backup.sh", mode = "0700" }
    "/usr/local/bin/ghost-restore"             = { source = "stack/ghost-restore.sh", mode = "0700" }
    "/etc/ssh/sshd_config.d/10-ghost.conf"     = { source = "stack/sshd.conf", mode = "0644" }
    "/etc/systemd/system/ghost-backup.service" = { source = "stack/ghost-backup.service", mode = "0644" }
    "/etc/systemd/system/ghost-backup.timer"   = { source = "stack/ghost-backup.timer", mode = "0644" }
  }

  deploy_env = join("\n", [
    "GHOST_DOMAIN=${local.domain}",
    "ACME_EMAIL=${var.acme_email}",
    "NODE_NAME=${var.server_name}",
    "DATA_DIR=/mnt/ghost",
    "",
  ])

  # Kept out of stack_revision on purpose: changing the owner's name or title
  # must not rebuild the server. It only matters on the first boot.
  owner_env = join("\n", [
    "OWNER_EMAIL=${local.owner_email}",
    "GHOST_TITLE=${var.ghost_title}",
    "",
  ])
  owner_email = var.ghost_owner_email != "" ? var.ghost_owner_email : var.acme_email

  cloud_config = "#cloud-config\n${yamlencode({
    package_update = true
    packages       = ["ca-certificates", "curl", "docker-compose-v2", "docker.io", "jq", "ufw"]
    write_files = concat(
      [for target, f in local.stack_files : {
        path        = target
        encoding    = "b64"
        content     = base64encode(file("${path.module}/${f.source}"))
        permissions = f.mode
      }],
      [
        {
          path        = "/etc/ghost-deploy.env"
          encoding    = "b64"
          content     = base64encode(local.deploy_env)
          permissions = "0600"
        },
        {
          path        = "/etc/ghost-owner.env"
          encoding    = "b64"
          content     = base64encode(local.owner_env)
          permissions = "0600"
        },
        {
          path        = "/etc/ghost-tailscale-auth-key"
          encoding    = "b64"
          content     = base64encode(var.tailscale_auth_key)
          permissions = "0600"
        },
      ],
    )
    runcmd = [["/opt/ghost/bootstrap.sh"]]
  })}"
}

resource "hcloud_ssh_key" "admin" {
  count      = var.existing_ssh_key_id == "" ? 1 : 0
  name       = "${var.server_name}-admin"
  public_key = var.ssh_public_key
}

# Inbound is web traffic only. There is deliberately no rule for port 22.
resource "hcloud_firewall" "ghost" {
  name = "${var.server_name}-web-only"

  rule {
    description = "HTTP (ACME challenge and redirect to HTTPS)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTPS"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_primary_ip" "ghost" {
  name              = "${var.server_name}-ipv4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protect_data
}

resource "hcloud_volume" "data" {
  name              = "${var.server_name}-data"
  size              = var.volume_size_gb
  location          = var.location
  format            = "ext4"
  delete_protection = var.protect_data
}

# Changing the stack rebuilds the server; a new Tailscale key alone does not.
# All data stays on the volume, so a rebuild only costs a few minutes of downtime.
resource "terraform_data" "stack_revision" {
  input = sha256(join("", concat(
    [for f in local.stack_files : filesha256("${path.module}/${f.source}")],
    [local.deploy_env, var.image],
  )))
}

resource "hcloud_server" "ghost" {
  name         = var.server_name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  firewall_ids = [hcloud_firewall.ghost.id]
  ssh_keys     = [var.existing_ssh_key_id != "" ? var.existing_ssh_key_id : hcloud_ssh_key.admin[0].id]
  user_data    = local.cloud_config

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ghost.id
    ipv6_enabled = false
  }

  lifecycle {
    ignore_changes       = [user_data, ssh_keys]
    replace_triggered_by = [terraform_data.stack_revision]
  }
}

resource "hcloud_volume_attachment" "data" {
  server_id = hcloud_server.ghost.id
  volume_id = hcloud_volume.data.id
  automount = false
}
