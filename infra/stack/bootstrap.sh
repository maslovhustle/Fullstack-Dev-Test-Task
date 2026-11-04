#!/usr/bin/env bash
# First-boot setup, run by cloud-init. Safe to run again.
set -euo pipefail
exec > >(tee -a /var/log/ghost-bootstrap.log) 2>&1

set -a
# shellcheck source=/dev/null
source /etc/ghost-deploy.env
set +a
auth_key_file=/etc/ghost-tailscale-auth-key
# Read as plain text, not sourced: a blog title may contain spaces.
OWNER_EMAIL=$(sed -n 's/^OWNER_EMAIL=//p' /etc/ghost-owner.env)
GHOST_TITLE=$(sed -n 's/^GHOST_TITLE=//p' /etc/ghost-owner.env)
GHOST_URL=${GHOST_URL:-https://$GHOST_DOMAIN}
export GHOST_URL OWNER_EMAIL GHOST_TITLE

echo "== Host firewall first, so nothing else is ever exposed"
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow in on tailscale0 to any port 22 proto tcp
ufw --force enable
systemctl reload ssh || systemctl restart ssh || true

echo "== Waiting for the data volume"
device=""
for _ in $(seq 1 120); do
  device=$(find /dev/disk/by-id -name 'scsi-0HC_Volume_*' | head -n 1)
  [ -n "$device" ] && break
  sleep 5
done
[ -n "$device" ] || { echo "Data volume never appeared"; exit 1; }

mkdir -p "$DATA_DIR"
grep -q " $DATA_DIR " /etc/fstab || echo "$device $DATA_DIR ext4 discard,nofail,defaults 0 0" >> /etc/fstab
mountpoint -q "$DATA_DIR" || mount "$DATA_DIR"
mkdir -p "$DATA_DIR"/{mysql,ghost-content,caddy-data,caddy-config,secrets,tailscale,backups}
chown 1000:1000 "$DATA_DIR/ghost-content"
chmod 700 "$DATA_DIR/secrets" "$DATA_DIR/tailscale" "$DATA_DIR/backups"

# Never let these start before the volume is mounted: MySQL would initialise an
# empty database on the root disk.
for unit in docker tailscaled; do
  mkdir -p "/etc/systemd/system/$unit.service.d"
  printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA_DIR" > "/etc/systemd/system/$unit.service.d/ghost-data.conf"
done
systemctl daemon-reload

echo "== Generating secrets once; they live only on the volume"
secrets_file="$DATA_DIR/secrets/stack.env"
owner_file="$DATA_DIR/secrets/owner.env"
if [ ! -f "$secrets_file" ]; then
  umask 077
  {
    echo "MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)"
    echo "MYSQL_PASSWORD=$(openssl rand -hex 32)"
  } > "$secrets_file"
fi
if [ ! -f "$owner_file" ]; then
  umask 077
  echo "OWNER_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n')" > "$owner_file"
fi

echo "== Joining the tailnet"
# The node identity lives on the volume, so a rebuilt server keeps its name and IP.
ln -sfn "$DATA_DIR/tailscale" /var/lib/tailscale
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get install -y tailscale
fi
systemctl enable --now tailscaled
state=""
for _ in $(seq 1 30); do
  state=$(tailscale status --json | jq -r .BackendState)
  case "$state" in Running | NeedsLogin | Stopped) break ;; esac
  sleep 1
done
# After a rebuild the saved identity is used; the key may be spent or expired by then.
# A tunnel failure must not take the blog down, and verify.sh reports it.
if [ "$state" = NeedsLogin ]; then
  tailscale up --auth-key="file:$auth_key_file" --hostname="$NODE_NAME" ||
    echo "WARNING: could not join the tailnet"
elif [ "$state" != Running ]; then
  tailscale up --hostname="$NODE_NAME" || echo "WARNING: could not join the tailnet"
fi
rm -f "$auth_key_file"

echo "== Writing the stack command"
cat > /usr/local/bin/ghost-compose <<SCRIPT
#!/bin/sh
exec docker compose --project-directory /opt/ghost -f /opt/ghost/compose.yml \
  --env-file /etc/ghost-deploy.env --env-file "$secrets_file" "\$@"
SCRIPT
chmod 700 /usr/local/bin/ghost-compose
systemctl enable --now docker

# Pulling images can fail briefly, for example when Docker Hub limits shared IPs.
compose_up() {
  for attempt in 1 2 3 4 5; do
    ghost-compose up -d "$@" && return 0
    echo "Start failed (attempt $attempt); retrying"
    sleep $((attempt * ${START_RETRY_DELAY:-20}))
  done
  echo "Could not start: $*"
  return 1
}

echo "== Starting the database and Ghost, but not the public web server yet"
compose_up db ghost

echo "== Creating the owner account before the blog is reachable"
# shellcheck source=/dev/null
source /opt/ghost/owner.sh
set -a
# shellcheck source=/dev/null
source "$owner_file"
set +a
export OWNER_COMPOSE=ghost-compose
ghost_wait_ready
ghost_create_owner_if_missing

echo "== Starting Caddy: the blog becomes public only now"
compose_up caddy

systemctl enable --now ghost-backup.timer
echo "== Bootstrap finished"
