#!/usr/bin/env bash
# Removes the deployment.
#   ./destroy.sh                remove the server and firewall; keep the volume and IP
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
    targets=(hcloud_volume_attachment.data hcloud_server.ghost hcloud_firewall.ghost)
    target_flags=()
    for t in "${targets[@]}"; do target_flags+=("-target=$t"); done
    plan=$(mktemp "${TMPDIR:-/tmp}/ghost-destroy.XXXXXX")
    tofu plan -destroy -input=false -var protect_data=false "${target_flags[@]}" -out="$plan" >/dev/null
    if [ "$(planned_deletes "$plan" '^hcloud_(volume|primary_ip)\.')" != 0 ]; then
      rm -f "$plan"
      die "Refusing: this would delete the volume or the IP. Nothing was changed."
    fi
    echo "This will remove: ${targets[*]}"
    echo "The data volume and the public IP are kept, and keep billing."
    rm -f "$plan"
    read -r -p "Type yes to remove the server: " answer
    [ "$answer" = yes ] || die "Cancelled."

    stop_stack_if_reachable
    set_delete_protection false "${targets[@]}"
    tofu destroy -input=false -auto-approve -var protect_data=false "${target_flags[@]}"
    echo "Server removed. The volume and IP remain, and are still billed."
    echo "Run ./deploy.sh to bring the blog back, or ./destroy.sh --delete-data to remove them."
    ;;
  --delete-data)
    echo "This permanently deletes the blog's data, including backups on the volume."
    read -r -p "Type the server name ($SERVER_NAME) to confirm: " answer
    [ "$answer" = "$SERVER_NAME" ] || die "Cancelled."

    stop_stack_if_reachable
    set_delete_protection false hcloud_server.ghost hcloud_volume.data hcloud_primary_ip.ghost
    tofu destroy -input=false -auto-approve -var protect_data=false
    echo "All Hetzner resources removed. Remove the node from your Tailscale admin console too."
    ;;
  *) die "Usage: $0 [--delete-data]" ;;
esac
