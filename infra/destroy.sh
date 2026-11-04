#!/usr/bin/env bash
# Removes the deployment.
#   ./destroy.sh                remove the server; keep the data volume and IP
#   ./destroy.sh --delete-data  remove everything, including all blog data
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need tofu "Install OpenTofu: brew install opentofu"
need jq "Install jq: brew install jq"
load_env
use_existing_ssh_key

case "${1:-}" in
  "")
    tofu destroy -target=hcloud_server.ghost -target=hcloud_firewall.ghost
    echo "Server removed. The volume and IP remain, and are still billed."
    echo "Run ./deploy.sh to bring the blog back, or ./destroy.sh --delete-data to remove them."
    ;;
  --delete-data)
    echo "This permanently deletes the blog's data, including backups on the volume."
    read -r -p "Type the server name ($SERVER_NAME) to confirm: " answer
    [ "$answer" = "$SERVER_NAME" ] || die "Cancelled."
    tofu apply -auto-approve -var protect_data=false
    tofu destroy -auto-approve -var protect_data=false
    echo "All Hetzner resources removed. Remove the node from your Tailscale admin console too."
    ;;
  *) die "Usage: $0 [--delete-data]" ;;
esac
