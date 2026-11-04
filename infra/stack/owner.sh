# shellcheck shell=bash
# Creates the Ghost owner account from inside the stack, before Caddy makes the
# blog public. Whoever completes Ghost's setup first owns the blog, so nothing
# may be reachable from the internet until this has run.
#
# Callers set: OWNER_COMPOSE (the command that runs docker compose for this stack),
# GHOST_URL, OWNER_EMAIL, OWNER_PASSWORD and GHOST_TITLE.

setup_status() {
  # shellcheck disable=SC2086  # OWNER_COMPOSE is a command with arguments
  ${OWNER_COMPOSE:-ghost-compose} exec -T ghost \
    wget -q -O - http://127.0.0.1:2368/ghost/api/admin/authentication/setup/ 2>/dev/null
}

ghost_has_owner() {
  setup_status | grep -q '"status":true'
}

ghost_wait_ready() {
  for _ in $(seq 1 120); do
    setup_status | grep -q '"setup"' && return 0
    sleep 5
  done
  echo "Ghost did not start in time" >&2
  return 1
}

ghost_create_owner_if_missing() {
  if ghost_has_owner; then
    echo "The owner account already exists."
    return 0
  fi
  local body
  body=$(jq -n --arg email "$OWNER_EMAIL" --arg password "$OWNER_PASSWORD" --arg title "$GHOST_TITLE" \
    '{setup: [{name: "Owner", email: $email, password: $password, blogTitle: $title}]}')
  # shellcheck disable=SC2086
  ${OWNER_COMPOSE:-ghost-compose} exec -T ghost \
    wget -q -O /dev/null \
    --header='Content-Type: application/json' \
    --header="Origin: $GHOST_URL" \
    --post-data="$body" \
    http://127.0.0.1:2368/ghost/api/admin/authentication/setup/ || true
  ghost_has_owner || { echo "The owner account was not created" >&2; return 1; }
  echo "Created the owner account for $OWNER_EMAIL."
}
