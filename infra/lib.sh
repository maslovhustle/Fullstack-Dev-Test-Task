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

# Ghost gives the blog to whoever completes setup first, so the deploy does it.
# Extra arguments go to curl.
ghost_has_owner() {
  local base=$1
  shift
  curl -fsS --max-time 20 "$@" "$base/ghost/api/admin/authentication/setup/" |
    grep -q '"status":true'
}

ghost_create_owner() {
  local base=$1 email=$2 password=$3 title=$4
  shift 4
  jq -n --arg email "$email" --arg password "$password" --arg title "$title" \
    '{setup: [{name: "Owner", email: $email, password: $password, blogTitle: $title}]}' |
    curl -fsS --max-time 60 "$@" -o /dev/null -X POST "$base/ghost/api/admin/authentication/setup/" \
      -H 'Content-Type: application/json' -H "Origin: $base" -d @-
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
