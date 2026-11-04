#!/usr/bin/env bash
# Runs inside a throwaway container with NET_ADMIN. Uses the real sshd and ufw,
# not stubs, to check the settings that keep SSH off the public internet.
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq openssh-server ufw iptables >/dev/null 2>&1

mkdir -p /etc/ssh/sshd_config.d /run/sshd
cp /stack/sshd.conf /etc/ssh/sshd_config.d/10-ghost.conf
ssh-keygen -A >/dev/null
sshd -t
effective=$(sshd -T)
grep -qx 'passwordauthentication no' <<<"$effective"
grep -qx 'kbdinteractiveauthentication no' <<<"$effective"
grep -qE '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective"
echo "PASS  sshd accepts keys only"

# The exact commands from bootstrap.sh, so this test cannot drift from them.
grep -E '^ufw (default|allow)' /stack/bootstrap.sh > /tmp/rules.sh
bash /tmp/rules.sh >/dev/null
ufw --force enable >/dev/null
status=$(ufw status)

# The same patterns verify.sh uses on the live server.
grep -qE '^22/tcp on tailscale0 +ALLOW' <<<"$status"
if grep -qE '^22(/tcp)?( \(v6\))? +ALLOW' <<<"$status"; then
  echo "FAIL  port 22 is open on every interface"
  exit 1
fi
echo "PASS  ufw allows SSH on tailscale0 only"

unexpected=$(grep ALLOW <<<"$status" |
  grep -vE '^(80|443)/tcp( \(v6\))? +ALLOW|^22/tcp( \(v6\))? on tailscale0 +ALLOW' || true)
if [ -n "$unexpected" ]; then
  echo "FAIL  unexpected firewall rules:"
  echo "$unexpected"
  exit 1
fi
ufw status verbose | grep -q '^Default: deny (incoming)'
echo "PASS  ufw allows only 80, 443 and SSH on tailscale0, and denies the rest"
