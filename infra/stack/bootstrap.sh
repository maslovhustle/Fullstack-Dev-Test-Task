#!/usr/bin/env bash
# First-boot setup, run by cloud-init. Safe to run again.
set -euo pipefail
exec > >(tee -a /var/log/ghost-bootstrap.log) 2>&1

set -a
# shellcheck source=/dev/null
source /etc/ghost-deploy.env
set +a
auth_key_file=/etc/ghost-tailscale-auth-key

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
if [ ! -f "$secrets_file" ]; then
  umask 077
  {
    echo "MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)"
    echo "MYSQL_PASSWORD=$(openssl rand -hex 32)"
  } > "$secrets_file"
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

echo "== Starting Ghost"
cat > /usr/local/bin/ghost-compose <<SCRIPT
#!/bin/sh
exec docker compose --project-directory /opt/ghost -f /opt/ghost/compose.yml \
  --env-file /etc/ghost-deploy.env --env-file "$secrets_file" "\$@"
SCRIPT
chmod 700 /usr/local/bin/ghost-compose
systemctl enable --now docker
# Pulling images can fail briefly, for example when Docker Hub limits shared IPs.
for attempt in 1 2 3 4 5; do
  ghost-compose up -d && break
  [ "$attempt" -lt 5 ] || { echo "Could not start the stack"; exit 1; }
  echo "Start failed (attempt $attempt); retrying"
  sleep $((attempt * ${START_RETRY_DELAY:-20}))
done

systemctl enable --now ghost-backup.timer
echo "== Bootstrap finished"
