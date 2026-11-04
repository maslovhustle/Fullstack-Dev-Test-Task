#!/usr/bin/env bash
# Proves the blog is public and SSH is reachable only through the tunnel.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
load_env

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
check() {
  local label=$1
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

ip=$(tofu output -raw public_ip) || die "No deployment found. Run ./deploy.sh first."
domain=$(tofu output -raw domain)
firewall_id=$(tofu output -raw firewall_id)
server_id=$(tofu output -raw server_id)

port_is_open() {
  curl -sv --connect-timeout 5 --max-time 6 "telnet://$ip:$1" </dev/null 2>&1 | grep -q 'Connected to'
}
port_is_closed() { ! port_is_open "$1"; }
blog_is_up() { curl -fsS -o /dev/null --max-time 20 "https://$domain/"; }
http_redirects() {
  [ "$(curl -s -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' "http://$domain/")" = "308 https://$domain/" ]
}
firewall_is_web_only() {
  local rules
  rules=$(hcloud_get "firewalls/$firewall_id") || return 1
  [ "$(jq -c '[.firewall.rules[] | select(.direction == "in") | .port] | sort' <<<"$rules")" = '["443","80"]' ] &&
    jq -e --argjson id "$server_id" '.firewall.applied_to[] | select(.server.id == $id)' <<<"$rules" >/dev/null
}

echo "== Public side ($domain, $ip)"
check "blog answers over HTTPS with a trusted certificate" blog_is_up
check "HTTP redirects to HTTPS" http_redirects
check "Hetzner firewall allows only 80 and 443, and is applied" firewall_is_web_only
for port in 22 2368 3306; do
  check "port $port is closed from the internet" port_is_closed "$port"
done

echo "== Tunnel side"
if [ -z "$(tailnet_ip 2>/dev/null)" ]; then
  fail "server is online in your tailnet (is Tailscale running on this machine?)"
else
  check "SSH works through Tailscale" tunnel_ssh true
  check "host firewall limits SSH to tailscale0" tunnel_ssh \
    "ufw status | grep -qE '^22/tcp on tailscale0 +ALLOW' && ! ufw status | grep -qE '^22(/tcp)?( \(v6\))? +ALLOW'"
  check "password login is off" tunnel_ssh "sshd -T | grep -qx 'passwordauthentication no'"
  check "data volume is mounted" tunnel_ssh "mountpoint -q /mnt/ghost"
  check "all containers are running" tunnel_ssh \
    "[ \"\$(ghost-compose ps --status running -q | wc -l)\" -eq 3 ]"
  check "nightly backup timer is active" tunnel_ssh "systemctl is-active -q ghost-backup.timer"
fi

echo
if curl -fsS --max-time 20 "https://$domain/ghost/api/admin/authentication/setup/" |
  jq -e '.setup[0].status == false' >/dev/null 2>&1; then
  echo "WARNING: no owner account yet. Create it now at https://$domain/ghost"
fi
[ "$failures" -eq 0 ] || die "$failures check(s) failed."
echo "All checks passed."
