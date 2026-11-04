#!/usr/bin/env bash
# One command: provision the server, deploy Ghost, and verify it. Safe to rerun.
#   ./deploy.sh          show the cost and plan, ask, then deploy
#   ./deploy.sh --yes    deploy without asking
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
need openssl "Install openssl."
load_env
[ -n "${ACME_EMAIL:-}" ] || die "Set ACME_EMAIL in .env"
[ -n "${TAILSCALE_AUTH_KEY:-}" ] || die "Set TAILSCALE_AUTH_KEY in .env"

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
tofu plan -input=false -out=tfplan
if [ "$mode" = plan ]; then
  rm -f tfplan
  echo "Plan only: nothing was changed."
  exit 0
fi
if [ "$mode" = ask ]; then
  read -r -p "Apply this plan? It can create billable resources. Type yes: " answer
  [ "$answer" = yes ] || { rm -f tfplan; die "Cancelled."; }
fi

# The owner password stays on this machine. Re-running reuses it.
ensure_owner() {
  local base=$1 email=${GHOST_OWNER_EMAIL:-$ACME_EMAIL}
  if ghost_has_owner "$base"; then
    echo "The owner account already exists."
    return
  fi
  if [ ! -s .owner-password ]; then
    (umask 077 && openssl rand -base64 24 | tr -d '/+=\n' > .owner-password)
  fi
  ghost_create_owner "$base" "$email" "$(cat .owner-password)" "${GHOST_TITLE:-My Blog}"
  echo "Created the owner account for $email."
  echo "Change the password after logging in."
}

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

echo "== Waiting for https://$domain (first boot takes a few minutes)"
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null --max-time 10 "https://$domain/" && break
  sleep 10
done

if curl -fsS -o /dev/null --max-time 10 "https://$domain/"; then
  echo "== Creating the Ghost owner account"
  ensure_owner "https://$domain"
else
  echo "WARNING: the blog is not answering yet, so the owner account was not created."
  echo "Run ./deploy.sh again once it is up."
fi

./verify.sh

echo
echo "Blog:  https://$domain"
echo "Admin: https://$domain/ghost"
echo "Log in with the owner email and the password in $PWD/.owner-password"
