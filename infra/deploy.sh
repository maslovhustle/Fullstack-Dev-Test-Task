#!/usr/bin/env bash
# One command: provision the server, deploy Ghost, and verify it. Safe to rerun.
#   ./deploy.sh          show the cost and plan, ask, then deploy
#   ./deploy.sh --yes    deploy without asking (never replaces the server)
#   ./deploy.sh --plan   show the cost and plan, change nothing
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

mode=ask
case "${1:-}" in
  --yes) mode=yes ;;
  --plan) mode=plan ;;
  "") ;;
  *) die "Usage: $0 [--yes|--plan]" ;;
esac

need tofu "Install OpenTofu: brew install opentofu"
need jq "Install jq: brew install jq"
need curl "Install curl."
need dig "Install DNS tools (dnsutils on Debian/Ubuntu)."
load_env
[ -n "${ACME_EMAIL:-}" ] || die "Set ACME_EMAIL in .env"
[ -n "${TAILSCALE_AUTH_KEY:-}" ] || die "Set TAILSCALE_AUTH_KEY in .env"

# Without Tailscale on this machine, the server could be created but never
# administered or verified. Check before anything is billed.
tailscale_cli status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null ||
  die "Tailscale is not running on this machine. Open the Tailscale app and log in, then run again."

echo "== Checking the Hetzner project"
hcloud_get locations >/dev/null || die "Hetzner rejected the token, or the API is unreachable."
server_type=$(hcloud_get "server_types?name=$SERVER_TYPE" | jq '.server_types[0]')
[ "$server_type" != null ] || die "Unknown server type: $SERVER_TYPE"
server_price=$(jq -r --arg l "$LOCATION" \
  '[.prices[] | select(.location == $l)][0].price_monthly.gross // empty' <<<"$server_type")
[ -n "$server_price" ] || die "$SERVER_TYPE is not sold in $LOCATION. Change SERVER_TYPE or LOCATION."
pricing=$(hcloud_get pricing | jq .pricing)
ip_price=$(jq -r --arg l "$LOCATION" \
  '[.primary_ips[] | select(.type == "ipv4") | .prices[] | select(.location == $l)][0].price_monthly.gross // "unknown"' <<<"$pricing")
gb_price=$(jq -r '.volume.price_per_gb_month.gross' <<<"$pricing")
currency=$(jq -r .currency <<<"$pricing")

echo "Monthly cost from the Hetzner API, in $currency, including any VAT on your account:"
echo "  server $SERVER_TYPE in $LOCATION: $server_price"
echo "  primary IPv4: $ip_price"
echo "  volume, ${VOLUME_SIZE_GB} GB at $gb_price per GB"

echo "== Preparing OpenTofu"
tofu init -input=false >/dev/null
use_existing_ssh_key
refuse_orphaned_resources

tofu plan -input=false -out=tfplan
if [ "$(planned_deletes tfplan '^hcloud_(volume|primary_ip)\.')" != 0 ]; then
  rm -f tfplan
  die "The plan would delete the data volume or the public IP, so nothing was changed. Check your .env against the last deploy, then run again."
fi
replaces_server=no
[ "$(planned_deletes tfplan '^hcloud_server\.ghost$')" = 0 ] || replaces_server=yes

if [ "$mode" = plan ]; then
  rm -f tfplan
  echo "Plan only: nothing was changed."
  [ "$replaces_server" = no ] || echo "This plan REPLACES the server: a few minutes of downtime, data stays on the volume."
  exit 0
fi

if [ "$replaces_server" = yes ]; then
  [ "$mode" = ask ] || { rm -f tfplan; die "This plan replaces the server, so it needs confirmation. Run ./deploy.sh without --yes."; }
  echo "This plan REPLACES the server. Data stays on the volume, but the blog is down for a few minutes."
  read -r -p "Type 'replace server' to continue: " answer
  [ "$answer" = "replace server" ] || { rm -f tfplan; die "Cancelled."; }
  rm -f tfplan
  echo "== Stopping the stack cleanly, then lifting delete protection on the server only"
  stop_stack_if_reachable
  set_delete_protection false hcloud_server.ghost
  tofu plan -input=false -out=tfplan
  if [ "$(planned_deletes tfplan '^hcloud_(volume|primary_ip)\.')" != 0 ]; then
    rm -f tfplan
    die "The plan changed and would now delete the volume or IP. Nothing was applied."
  fi
fi

if [ "$mode" = ask ]; then
  read -r -p "Apply this plan? It can create billable resources. Type yes: " answer
  [ "$answer" = yes ] || { rm -f tfplan; die "Cancelled."; }
fi

echo "== Applying"
tofu apply -input=false tfplan
rm -f tfplan

ip=$(tofu output -raw public_ip)
domain=$(tofu output -raw domain)

if [ -n "${GHOST_DOMAIN:-}" ]; then
  echo "== Waiting for DNS. Create this record now if it does not exist yet:"
  echo "   $domain  A  $ip"
  for _ in $(seq 1 90); do
    [ "$(dig +short A "$domain" @1.1.1.1 | tail -n 1)" = "$ip" ] && break
    sleep 10
  done
  [ "$(dig +short A "$domain" @1.1.1.1 | tail -n 1)" = "$ip" ] ||
    die "DNS does not point to $ip yet. Fix it, then run ./deploy.sh again."
fi

# The blog only answers once the owner account exists (see stack/bootstrap.sh),
# so waiting for it also means the owner is in place.
echo "== Waiting for https://$domain (first boot takes a few minutes)"
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null --max-time 10 "https://$domain/" && break
  sleep 10
done
curl -fsS -o /dev/null --max-time 10 "https://$domain/" ||
  die "The blog is not answering yet. Check the first-boot log through the tunnel, then run ./deploy.sh again."

echo "== Fetching the owner password through the tunnel"
if [ -n "$(tailnet_ip)" ] &&
  (umask 077 && tunnel_ssh "sed -n 's/^OWNER_PASSWORD=//p' /mnt/ghost/secrets/owner.env" > .owner-password.tmp) &&
  [ -s .owner-password.tmp ]; then
  mv -f .owner-password.tmp .owner-password
  echo "Saved the owner password to infra/.owner-password (ignored by Git)."
else
  rm -f .owner-password.tmp
  echo "WARNING: could not fetch the owner password. Run ./deploy.sh again once the tunnel is up."
fi

./verify.sh

echo
echo "Blog:  https://$domain"
echo "Admin: https://$domain/ghost"
echo "Owner: ${GHOST_OWNER_EMAIL:-$ACME_EMAIL}, password in infra/.owner-password"
