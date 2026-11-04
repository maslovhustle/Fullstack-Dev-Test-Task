# Ghost on Hetzner, with no public SSH

One command provisions a Hetzner VPS and deploys a [Ghost](https://ghost.org) blog with HTTPS.
Port 22 is closed to the internet. You administer the server through a Tailscale tunnel.

```bash
cd infra
cp .env.example .env    # add your Hetzner token, Tailscale key and email; Git ignores this file
./deploy.sh --plan      # shows live prices and the plan, and creates nothing
./deploy.sh             # asks, then deploys, creates the owner account and verifies
```

| | |
|---|---|
| Provisioning | [OpenTofu](infra/main.tf): server, firewall, fixed IP and data volume. Reruns only change what differs. |
| Setup | [cloud-init](infra/stack/bootstrap.sh), so no SSH is needed during the deploy |
| Application | Ghost, MySQL and Caddy (automatic HTTPS) in [Docker Compose](infra/stack/compose.yml), with pinned versions |
| Public access | Ports 80 and 443 only. The Hetzner firewall and the host firewall both block 22. |
| Admin access | SSH through Tailscale only, with keys and no passwords |
| Data | One Hetzner volume holds the database, uploads, certificates, secrets and the Tailscale identity |

Everything you need to run it is in **[infra/README.md](infra/README.md)**: prerequisites,
credentials, domain and DNS setup, deployment, tunnel access, backups, cleanup and troubleshooting.

**This creates billable resources** (a server, a volume and a fixed IPv4 address). `./deploy.sh`
prints the monthly prices it reads from the Hetzner API before it asks, and `./destroy.sh` removes
the server (the volume and IP are kept, and keep billing, until `--delete-data`).

**Ghost is not public until its owner exists.** The server creates the owner account from inside the
stack before Caddy starts, so no visitor can claim the blog first. Details, and every way the server
can be deleted, are in [infra/README.md](infra/README.md).

## What has been verified

Everything that needs no cloud account runs in CI, and locally with `infra/tests/test-local.sh`
(Docker and jq only):

- ShellCheck, OpenTofu format, validation and a full plan, and the cloud-init schema.
- The real `sshd` and `ufw` with this project's settings: SSH accepts keys only, and the firewall
  allows 80, 443 and SSH on the tunnel interface alone. Breaking either setting makes the test fail.
- The deletion guards, run on plan files of each shape: a server replacement or a volume deletion
  is refused unless it is confirmed, and destroy never touches the volume or the IP.
- The first-boot script run twice against stubbed system commands, including a failed start, and a
  check that Caddy starts only after the owner exists.
- Real Ghost, MySQL and Caddy containers: the blog is unreachable before the owner exists, then
  HTTPS, redirect and security headers work; only Caddy publishes ports; the admin API refuses
  anonymous requests; surviving a restart; and backup and restore onto an empty server.

**Not yet verified against a real Hetzner account.** The live checks in `infra/verify.sh` (the blog
answers over trusted HTTPS, ports 22, 2368 and 3306 are closed from the internet, and SSH works
through the tunnel) run at the end of every real deploy. They have not been run yet. Neither has the
Hetzner behaviour that the deletion guards depend on, such as name filters on the API.

## How it was built

It was written with Claude Code. The real conversation, with secrets redacted, is in
[docs/ai-conversation.md](docs/ai-conversation.md).
