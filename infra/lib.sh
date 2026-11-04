# shellcheck shell=bash
# Shared helpers, sourced by the scripts in this directory. Works on macOS bash 3.2.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

api=https://api.hetzner.cloud/v1

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing '$1'. $2"; }

load_env() {
  [ -f .env ] || die "No .env file. Run: cp .env.example .env"
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
  : "${HCLOUD_TOKEN:?Set HCLOUD_TOKEN in .env}"
  SERVER_NAME=${SERVER_NAME:-ghost}
  SERVER_TYPE=${SERVER_TYPE:-cx23}
  LOCATION=${LOCATION:-fsn1}
  VOLUME_SIZE_GB=${VOLUME_SIZE_GB:-20}
  SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}
  SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE/#\~/$HOME}
  [ -f "$SSH_PUBLIC_KEY_FILE" ] || die "SSH public key not found: $SSH_PUBLIC_KEY_FILE"

  export TF_VAR_server_name=$SERVER_NAME TF_VAR_server_type=$SERVER_TYPE
  export TF_VAR_location=$LOCATION TF_VAR_volume_size_gb=$VOLUME_SIZE_GB
  export TF_VAR_ghost_domain=${GHOST_DOMAIN:-} TF_VAR_acme_email=${ACME_EMAIL:-}
  export TF_VAR_ghost_owner_email=${GHOST_OWNER_EMAIL:-} TF_VAR_ghost_title=${GHOST_TITLE:-My Blog}
  export TF_VAR_tailscale_auth_key=${TAILSCALE_AUTH_KEY:-}
  TF_VAR_ssh_public_key=$(cat "$SSH_PUBLIC_KEY_FILE")
  export TF_VAR_ssh_public_key
}

# Hetzner rejects duplicate SSH keys, so reuse this one if the project already has it.
use_existing_ssh_key() {
  local fingerprint key_id
  fingerprint=$(ssh-keygen -E md5 -lf "$SSH_PUBLIC_KEY_FILE" | awk '{print $2}' | sed 's/^MD5://')
  key_id=$(hcloud_get "ssh_keys?fingerprint=$fingerprint" | jq -r '.ssh_keys[0].id // empty')
  if [ -n "$key_id" ] && ! tofu state list 2>/dev/null | grep -q '^hcloud_ssh_key.admin'; then
    export TF_VAR_existing_ssh_key_id=$key_id
  fi
}

hcloud_get() {
  curl -fsS --max-time 30 -H "Authorization: Bearer $HCLOUD_TOKEN" "$api/$1"
}

tailscale_cli() {
  if command -v tailscale >/dev/null; then
    tailscale "$@"
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"
  else
    die "Tailscale is not installed on this machine."
  fi
}

tailnet_ip() {
  tailscale_cli status --json | jq -r --arg name "$SERVER_NAME" \
    '[.Peer[]? | select(.HostName == $name and .Online)][0].TailscaleIPs[0] // empty'
}

# A rebuilt server has new host keys. Skipping the check is safe here because
# this traffic only runs inside the tailnet, which authenticates each node.
tunnel_ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

tunnel_ssh() {
  local ip
  ip=$(tailnet_ip)
  [ -n "$ip" ] || die "'$SERVER_NAME' is not online in your tailnet."
  # shellcheck disable=SC2029  # the commands are meant to run on the server
  ssh "${tunnel_ssh_opts[@]}" "root@$ip" "$@"
}

# --- Protecting the server and its data -------------------------------------
# Server, volume and IP carry Hetzner delete protection (see main.tf), so a plain
# apply cannot delete them. The scripts below only lift that protection for a
# named set of resources, and only after checking that nothing else changes.

# How many changes in the saved plan $1 delete a resource whose address matches $2.
planned_deletes() {
  tofu show -json "$1" | jq --arg re "$2" \
    '[.resource_changes[] | select(.address | test($re)) | select(.change.actions | index("delete"))] | length'
}

# Succeeds only if every planned change in plan $1 is an update of delete_protection.
only_protection_changes() {
  tofu show -json "$1" | jq -e '
    def changed_keys:
      (.change.before // {}) as $b | (.change.after // {}) as $a
      | [($b + $a | keys_unsorted[]) | select(($b[.] // null) != ($a[.] // null))];
    [.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])]
    | all(.[]; .change.actions == ["update"] and ((changed_keys - ["delete_protection"]) == []))
  ' >/dev/null
}

# Sets delete protection to $1 (true or false) for the resources named after it.
set_delete_protection() {
  local value=$1 targets=() plan
  shift
  for t in "$@"; do targets+=("-target=$t"); done
  plan=$(mktemp "${TMPDIR:-/tmp}/ghost-protection.XXXXXX")
  tofu plan -input=false -out="$plan" -var "protect_data=$value" "${targets[@]}" >/dev/null
  if ! only_protection_changes "$plan"; then
    rm -f "$plan"
    die "Refusing: changing delete protection would also change something else. Run ./deploy.sh and review the plan."
  fi
  tofu apply -input=false -auto-approve "$plan" >/dev/null
  rm -f "$plan"
}

# Stops Ghost cleanly before the server goes away, so the database is not cut
# off mid-write. If the tunnel is down, the caller decides whether to go on.
stop_stack_if_reachable() {
  if [ -n "$(tailnet_ip)" ]; then
    tunnel_ssh "ghost-compose stop && sync" || echo "WARNING: could not stop the stack cleanly."
  else
    echo "WARNING: the server is not reachable through Tailscale, so the stack was not stopped cleanly."
  fi
}

# Without state, OpenTofu would create second copies of resources that already
# exist in the project, and the old copies would keep billing.
hetzner_has_named() { # $1 = API path, $2 = JSON key, $3 = name
  hcloud_get "$1?name=$3" | jq -e --arg n "$3" ".${2}[] | select(.name == \$n)" >/dev/null 2>&1
}

refuse_orphaned_resources() {
  [ -z "$(tofu state list 2>/dev/null)" ] || return 0
  local found=""
  hetzner_has_named servers servers "$SERVER_NAME" && found="$found server $SERVER_NAME"
  hetzner_has_named volumes volumes "$SERVER_NAME-data" && found="$found volume $SERVER_NAME-data"
  hetzner_has_named primary_ips primary_ips "$SERVER_NAME-ipv4" && found="$found IP $SERVER_NAME-ipv4"
  [ -z "$found" ] || die "These already exist in your Hetzner project but not in this machine's state:$found.
Restore the state file, or remove them in the Hetzner console. Creating new ones would double the cost."
}
