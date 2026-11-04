#!/usr/bin/env bash
# Validates everything that does not need a Hetzner account: no token, no cost.
# Needs Docker and jq. The stack test runs the real Ghost, MySQL and Caddy images.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source ./lib.sh
# shellcheck source=stack/owner.sh
source ./stack/owner.sh

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
  # Saved plans read back as JSON are used as they are, for the checks in lib.sh.
  if [ "${1:-}" = show ] && [[ "${3:-}" == *.json ]]; then
    cat "$3"
    return
  fi
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

echo "== Deletion guards: the real checks, on plan files of each shape"
mkdir -p "$work/plans"
cat > "$work/plans/protection-only.json" <<'JSON'
{"resource_changes":[{"address":"hcloud_server.ghost","change":{"actions":["update"],
 "before":{"delete_protection":true,"server_type":"cx23"},
 "after":{"delete_protection":false,"server_type":"cx23"}}}]}
JSON
cat > "$work/plans/server-type.json" <<'JSON'
{"resource_changes":[{"address":"hcloud_server.ghost","change":{"actions":["update"],
 "before":{"delete_protection":true,"server_type":"cx23"},
 "after":{"delete_protection":true,"server_type":"cx33"}}}]}
JSON
cat > "$work/plans/replace-server.json" <<'JSON'
{"resource_changes":[{"address":"hcloud_server.ghost","change":{"actions":["delete","create"],
 "before":{"delete_protection":false,"server_type":"cx23"},
 "after":{"delete_protection":true,"server_type":"cx23"}}}]}
JSON
cat > "$work/plans/delete-volume.json" <<'JSON'
{"resource_changes":[{"address":"hcloud_volume.data","change":{"actions":["delete"],
 "before":{"delete_protection":true},"after":null}}]}
JSON
only_protection_changes "$work/plans/protection-only.json"
echo "PASS  lifting delete protection on the server is allowed"
if only_protection_changes "$work/plans/server-type.json"; then echo "FAIL  a server type change passed"; exit 1; fi
echo "PASS  a change to the server type is refused when protection is lifted"
if only_protection_changes "$work/plans/replace-server.json"; then echo "FAIL  a replacement passed"; exit 1; fi
[ "$(planned_deletes "$work/plans/replace-server.json" '^hcloud_server\.ghost$')" = 1 ]
echo "PASS  a server replacement is detected and not treated as a protection change"
[ "$(planned_deletes "$work/plans/delete-volume.json" '^hcloud_(volume|primary_ip)\.')" = 1 ]
[ "$(planned_deletes "$work/plans/protection-only.json" '^hcloud_(volume|primary_ip)\.')" = 0 ]
echo "PASS  a plan that deletes the volume or the IP is detected"

echo "== Host config: the real sshd and ufw"
docker run --rm --cap-add NET_ADMIN -v "$PWD/stack":/stack:ro \
  -v "$PWD/tests/host-config-check.sh":/check.sh:ro ubuntu:24.04 bash /check.sh

echo "== Bootstrap: real script with system commands stubbed, run twice"
docker run --rm -v "$PWD/stack/bootstrap.sh":/opt/ghost/bootstrap.sh:ro \
  -v "$PWD/stack/owner.sh":/opt/ghost/owner.sh:ro \
  -v "$PWD/tests/bootstrap-check.sh":/check.sh:ro ubuntu:24.04 bash /check.sh

echo "== Stack: real containers with a local certificate"
base=https://ghost.localhost:18443
local_curl=(-k --resolve ghost.localhost:18443:127.0.0.1)
blog_curl() { curl -sS --max-time 20 "${local_curl[@]}" "$@"; }
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
  # The same command the server's owner setup uses, pointed at this stack
  export OWNER_COMPOSE="docker compose --project-name ghost-local-test --project-directory stack -f stack/compose.yml --env-file $work/env"
}
wait_for_blog() {
  for _ in $(seq 1 60); do
    [ "$(blog_curl -o /dev/null -w '%{http_code}' "$base/" 2>/dev/null || true)" = 200 ] && return 0
    sleep 5
  done
  stack logs --tail 30
  return 1
}
running_services() {
  stack ps --status running --format '{{.Service}}' | sort | tr '\n' ' '
}

write_env "$work/data"
stack up -d db ghost
ghost_wait_ready
[ "$(running_services)" = "db ghost " ]
echo "PASS  before the owner exists, only the database and Ghost run (no public web server)"
if blog_curl -o /dev/null "$base/" 2>/dev/null; then
  echo "FAIL  the blog answered before the owner existed"
  exit 1
fi
echo "PASS  the blog is unreachable from the outside before the owner exists"
if ghost_has_owner; then echo "FAIL  a fresh blog should have no owner"; exit 1; fi

OWNER_EMAIL=owner@example.com OWNER_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n')" \
  GHOST_TITLE="Local Test" GHOST_URL="$base" ghost_create_owner_if_missing
ghost_has_owner
echo "PASS  the owner account is created inside the stack"

stack up -d caddy
wait_for_blog
echo "PASS  the blog answers over HTTPS only after the owner exists"
[ "$(blog_curl -o /dev/null -w '%{http_code}' --resolve ghost.localhost:18080:127.0.0.1 http://ghost.localhost:18080/)" = 308 ]
echo "PASS  HTTP redirects to HTTPS"
blog_curl -sI "$base/" | grep -qi '^strict-transport-security: max-age='
echo "PASS  HTTPS responses send Strict-Transport-Security"
[ "$(stack ps --format '{{.Service}} {{.Publishers}}' | grep -c -E '^(db|ghost) .*0\.0\.0\.0')" = 0 ]
echo "PASS  only Caddy publishes ports"
if curl -s --max-time 3 http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
  echo "FAIL  Caddy's admin API is reachable from the host"
  exit 1
fi
echo "PASS  Caddy's admin API is not reachable from the host"
admin_code=$(blog_curl -s -o /dev/null -w '%{http_code}' "$base/ghost/api/admin/users/")
[ "$admin_code" = 401 ] || [ "$admin_code" = 403 ]
echo "PASS  the Ghost admin API refuses anonymous requests (HTTP $admin_code)"

echo "Public routes, anonymous, after setup:"
for path in / /ghost/ /ghost/api/admin/site/ /ghost/api/admin/users/ \
  /ghost/api/admin/authentication/setup/ /rss/ /sitemap.xml /robots.txt; do
  echo "  $(blog_curl -s -o /dev/null -w '%{http_code}' "$base$path")  $path"
done

ghost_create_owner_if_missing | grep -q 'already exists'
echo "PASS  running the owner setup again does not create a second owner"

stack down
stack up -d db ghost
ghost_wait_ready
stack up -d caddy
wait_for_blog
ghost_has_owner
echo "PASS  data survives recreating the containers"

export DATA_DIR="$work/data" GHOST_COMPOSE="docker compose --project-name ghost-local-test --project-directory stack -f stack/compose.yml --env-file $work/env"
archive=$(stack/ghost-backup.sh | tail -n 1)
tar -tzf "$archive" | grep -q db.sql.gz
echo "PASS  backup created: $(du -h "$archive" | cut -f1)"

stack down
cp "$archive" "$work/backup.tar.gz"
write_env "$work/data2"
export DATA_DIR="$work/data2" GHOST_COMPOSE="docker compose --project-name ghost-local-test --project-directory stack -f stack/compose.yml --env-file $work/env"
stack up -d db ghost
ghost_wait_ready
if ghost_has_owner; then echo "FAIL  a fresh data directory should have no owner"; exit 1; fi
stack/ghost-restore.sh "$work/backup.tar.gz"
stack up -d caddy
wait_for_blog
ghost_has_owner
echo "PASS  backup restores onto an empty server, with its owner"

echo "All local checks passed."
