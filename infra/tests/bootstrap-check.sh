#!/usr/bin/env bash
# Runs inside a throwaway container. Stubs record what bootstrap.sh would do.
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq jq openssl >/dev/null 2>&1

log=/tmp/calls.log
mkdir -p /stubs /dev/disk/by-id
touch /dev/disk/by-id/scsi-0HC_Volume_123 "$log"
stub() {
  printf '#!/bin/sh\necho "%s $*" >> %s\n%s\n' "$1" "$log" "${2:-exit 0}" > "/stubs/$1"
  chmod +x "/stubs/$1"
}
for name in ufw systemctl mount; do stub "$name"; done
stub mountpoint 'exit 1'
# shellcheck disable=SC2016  # expanded when the stub runs
stub tailscale '[ "$1" = status ] && echo "{\"BackendState\":\"$(cat /tmp/ts-state)\"}"; exit 0'
# Docker behaves like the real one where it matters for bootstrap.sh:
# - the first "up" fails, as when an image pull is refused, and must be retried;
# - the Ghost setup endpoint reports "not set up" until an owner is posted.
# shellcheck disable=SC2016
stub docker 'case "$*" in
  *" up -d"*) n=$(cat /tmp/up-count 2>/dev/null || echo 0); echo $((n + 1)) > /tmp/up-count; [ "$n" -ge 1 ] || exit 1 ;;
esac
case "$*" in
  *--post-data*) touch /tmp/owner-created ;;
  *authentication/setup*)
    if [ -f /tmp/owner-created ]; then echo "{\"setup\":[{\"status\":true}]}"; else echo "{\"setup\":[{\"status\":false}]}"; fi ;;
esac
exit 0'
export PATH=/stubs:$PATH START_RETRY_DELAY=0

cat > /etc/ghost-deploy.env <<ENV
GHOST_DOMAIN=blog.example.com
ACME_EMAIL=test@example.com
NODE_NAME=ghost
DATA_DIR=/mnt/ghost
ENV
cat > /etc/ghost-owner.env <<ENV
OWNER_EMAIL=owner@example.com
GHOST_TITLE=Test Blog
ENV

echo tskey-test > /etc/ghost-tailscale-auth-key
echo NeedsLogin > /tmp/ts-state
bash /opt/ghost/bootstrap.sh >/dev/null
first_secrets=$(cat /mnt/ghost/secrets/stack.env)
first_owner=$(cat /mnt/ghost/secrets/owner.env)

grep -q 'tailscale up --auth-key=file:' "$log"
[ ! -e /etc/ghost-tailscale-auth-key ]
echo "PASS  first boot joins the tailnet and deletes the auth key"
[ "$(grep -n '^ufw --force enable' "$log" | cut -d: -f1)" -lt "$(grep -n '^tailscale up' "$log" | head -n 1 | cut -d: -f1)" ]
[ "$(grep -n '^ufw --force enable' "$log" | cut -d: -f1)" -lt "$(grep -n 'up -d db ghost' "$log" | head -n 1 | cut -d: -f1)" ]
echo "PASS  the host firewall is enabled before anything else starts"
grep -q 'ufw allow in on tailscale0 to any port 22 proto tcp' "$log"
if grep -E '^ufw allow 22' "$log"; then exit 1; fi
echo "PASS  port 22 is only allowed on tailscale0"
grep -q 'RequiresMountsFor=/mnt/ghost' /etc/systemd/system/docker.service.d/ghost-data.conf
echo "PASS  Docker waits for the data volume"
grep -q 'docker compose --project-directory /opt/ghost .* up -d db ghost' "$log"
echo "PASS  the database and Ghost are started"
[ "$(grep -c ' up -d' "$log")" -ge 3 ]
echo "PASS  a failed start is retried"

post_line=$(grep -n -- '--post-data' "$log" | head -n 1 | cut -d: -f1)
caddy_line=$(grep -n 'up -d caddy' "$log" | head -n 1 | cut -d: -f1)
[ "$(grep -c -- '--post-data' "$log")" = 1 ]
[ -n "$post_line" ] && [ -n "$caddy_line" ] && [ "$post_line" -lt "$caddy_line" ]
echo "PASS  the owner account is created once, before Caddy starts"
grep -q 'OWNER_PASSWORD=' /mnt/ghost/secrets/owner.env
[ "$(stat -c %a /mnt/ghost/secrets/owner.env 2>/dev/null || echo 600)" = 600 ]
echo "PASS  the owner password is generated once and stored with mode 600"
[ "$(grep -c ' /mnt/ghost ' /etc/fstab)" = 1 ]

# A rebuilt server: same volume, saved identity, a spent auth key, and an owner that exists.
: > "$log"
echo tskey-spent > /etc/ghost-tailscale-auth-key
echo Running > /tmp/ts-state
bash /opt/ghost/bootstrap.sh >/dev/null
if grep -q '^tailscale up' "$log"; then exit 1; fi
if grep -q -- '--post-data' "$log"; then exit 1; fi
grep -q 'up -d caddy' "$log"
[ "$first_secrets" = "$(cat /mnt/ghost/secrets/stack.env)" ]
[ "$first_owner" = "$(cat /mnt/ghost/secrets/owner.env)" ]
echo "PASS  a rerun keeps the secrets, the identity and the owner, and creates no second owner"
