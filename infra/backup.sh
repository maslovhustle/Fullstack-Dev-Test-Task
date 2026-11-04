#!/usr/bin/env bash
# Creates a backup on the server and copies it here through the tunnel.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need jq "Install jq: brew install jq"
load_env

remote_archive=$(tunnel_ssh ghost-backup | tail -n 1)
mkdir -p backups
scp "${tunnel_ssh_opts[@]}" "root@$(tailnet_ip):$remote_archive" backups/
echo "Saved backups/$(basename "$remote_archive")"
