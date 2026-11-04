#!/usr/bin/env bash
# Validates everything that does not need a Hetzner account: no token, no cost.
# Needs Docker and jq. The stack test runs the real Ghost, MySQL and Caddy images.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source ./lib.sh

tofu_image=ghcr.io/opentofu/opentofu:1.13.2
shellcheck_image=koalaman/shellcheck:v0.11.0
fake_token=$(printf 'x%.0s' $(seq 1 64))

work=$(mktemp -d "$PWD/.tmp.XXXXXX")
stack() {
  docker compose --project-name ghost-local-test --project-directory stack \
    -f stack/compose.yml --env-file "$work/env" "$@"
}
cleanup() {
  [ -f "$work/env" ] && stack down --volumes >/dev/null 2>&1 || true
  docker run --rm -v "$work":/w alpine rm -rf /w/data /w/data2 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

tofu() {
  docker run --rm -i -v "$PWD":/work -w /work -e HCLOUD_TOKEN="$fake_token" \
    -e TF_VAR_acme_email=test@example.com -e TF_VAR_tailscale_auth_key=tskey-test \
    -e TF_VAR_ssh_public_key="ssh-ed25519 AAAATEST test" -e TF_VAR_ghost_domain=blog.example.com \
    "$tofu_image" "$@"
}

echo "== shellcheck"
docker run --rm -v "$PWD":/mnt -w /mnt "$shellcheck_image" -x ./*.sh stack/*.sh tests/*.sh

echo "== OpenTofu: format, validate, and a plan with a fake token (no API writes)"
tofu fmt -check -recursive
tofu init -input=false >/dev/null
tofu validate
tofu plan -input=false -refresh=false -no-color | grep -E '^Plan:'

echo "== cloud-init: the rendered config passes the official schema"
echo 'base64encode(nonsensitive(local.cloud_config))' | tofu console | tr -d '"\r\n' |
  base64 -d > "$work/user-data"
grep -q '^#cloud-config' "$work/user-data"
echo "rendered size: $(wc -c < "$work/user-data") bytes (Hetzner's limit is 32 KiB)"
[ "$(wc -c < "$work/user-data")" -lt 32768 ]
docker run --rm -v "$work":/r:ro ubuntu:24.04 bash -ec '
  apt-get update -qq >/dev/null
  apt-get install -y -qq cloud-init >/dev/null 2>&1
  cloud-init schema --config-file /r/user-data
  apt-get install -s docker.io docker-compose-v2 ufw jq curl ca-certificates >/dev/null
  echo "packages are installable on Ubuntu 24.04"'

echo "== Host config: the real sshd and ufw"
docker run --rm --cap-add NET_ADMIN -v "$PWD/stack":/stack:ro \
  -v "$PWD/tests/host-config-check.sh":/check.sh:ro ubuntu:24.04 bash /check.sh

echo "== Bootstrap: real script with system commands stubbed, run twice"
docker run --rm -v "$PWD/stack/bootstrap.sh":/opt/ghost/bootstrap.sh:ro \
  -v "$PWD/tests/bootstrap-check.sh":/check.sh:ro ubuntu:24.04 bash /check.sh

echo "== Stack: real containers with a local certificate"
base=https://ghost.localhost:18443
write_env() {
  cat > "$work/env" <<ENV
GHOST_DOMAIN=ghost.localhost
GHOST_URL=$base
ACME_EMAIL=test@example.com
CADDY_EXTRA_GLOBAL=local_certs
HTTP_PORT=18080
HTTPS_PORT=18443
DATA_DIR=$1
MYSQL_ROOT_PASSWORD=local-root-password
MYSQL_PASSWORD=local-password
ENV
  mkdir -p "$1"/{mysql,ghost-content,caddy-data,caddy-config,backups}
}
# Extra curl arguments for the local test certificate and host name.
local_curl=(-k --resolve ghost.localhost:18443:127.0.0.1)
blog_curl() { curl -sS --max-time 20 "${local_curl[@]}" "$@"; }
wait_for_blog() {
  for _ in $(seq 1 60); do
    [ "$(blog_curl -o /dev/null -w '%{http_code}' "$base/" 2>/dev/null || true)" = 200 ] && return 0
    sleep 5
  done
  stack logs --tail 30
  return 1
}
owner_exists() { ghost_has_owner "$base" "${local_curl[@]}"; }

write_env "$work/data"
stack up -d
wait_for_blog
echo "PASS  blog answers over HTTPS through Caddy"
[ "$(blog_curl -o /dev/null -w '%{http_code}' --resolve ghost.localhost:18080:127.0.0.1 http://ghost.localhost:18080/)" = 308 ]
echo "PASS  HTTP redirects to HTTPS"
[ "$(stack ps --format '{{.Service}} {{.Publishers}}' | grep -c -E '^(db|ghost) .*0\.0\.0\.0')" = 0 ]
echo "PASS  only Caddy publishes ports"
owner_exists && { echo "FAIL  a new blog should have no owner"; exit 1; }

# The helpers the deploy script uses, so a change to them is tested here
owner_secret=$(openssl rand -base64 24 | tr -d '/+=\n')
ghost_create_owner "$base" owner@example.com "$owner_secret" "Local Test" "${local_curl[@]}"
owner_exists
echo "PASS  owner account created with the deploy script's helper"

stack down
stack up -d
wait_for_blog
owner_exists
echo "PASS  data survives recreating the containers"

export DATA_DIR="$work/data" GHOST_COMPOSE="docker compose --project-name ghost-local-test --project-directory stack -f stack/compose.yml --env-file $work/env"
archive=$(stack/ghost-backup.sh | tail -n 1)
tar -tzf "$archive" | grep -q db.sql.gz
echo "PASS  backup created: $(du -h "$archive" | cut -f1)"

stack down
cp "$archive" "$work/backup.tar.gz"
write_env "$work/data2"
export DATA_DIR="$work/data2"
stack up -d
wait_for_blog
owner_exists && { echo "FAIL  fresh data directory should have no owner"; exit 1; }
stack/ghost-restore.sh "$work/backup.tar.gz"
wait_for_blog
owner_exists
echo "PASS  backup restores onto an empty server"

echo "All local checks passed."
