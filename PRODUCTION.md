# Production

One Hetzner Cloud VPS runs the whole stack from [`deploy/`](deploy/):
Keycloak, Postgres and Caddy under Docker Compose, in `/opt/auth`.

- Public URL: `https://auth.finance-nl.com`, realm `myapps`
- Server: `2.28.108.199` (Ubuntu 26.04, 2 vCPU, 3.7 GiB RAM + 2 GB swap),
  SSH as `root` with a key only
- Versions: Keycloak 26.7.4, Postgres 16.15, Caddy 2.11.4

The dev stack in the repository root (`docker-compose.yml`,
`realm-export.json`) is for local work only. It has a test user and fixed
secrets, so never deploy it.

| Where (on the server)                 | What it holds                                          | If it's lost                                    |
|---------------------------------------|--------------------------------------------------------|-------------------------------------------------|
| Docker volume `auth_keycloak_pg_data` | users, sessions, realm and client config, signing keys | everything; see "Not covered yet" about backups |
| Docker volume `auth_caddy_data`       | TLS certificates, ACME account                         | re-issued automatically                         |
| `/opt/auth/.env`                      | domain, database password, admin allowlist             | recreate by hand from `deploy/.env.example`     |
| `/opt/auth/realm-export.json`         | realm file imported once, at the very first start      | not needed while the database exists            |

`.env` and `realm-export.json` contain secrets. They exist only on the server
(and in gitignored copies on the laptop), and `deploy/sync.sh` never copies
or overwrites them. The server's `/opt/auth/.env` is the one that counts.

## What is in place

### Edge (Caddy)

- Only Caddy publishes ports: 80/tcp, 443/tcp and 443/udp (HTTP/3). Postgres
  publishes nothing. Keycloak's management port 9000 (health) is bound to
  `127.0.0.1` on the server. Health and metrics are not reachable through 443.
- Let's Encrypt certificate, obtained and renewed by Caddy; HTTP redirects to
  HTTPS with 308.
- `/admin*` and `/realms/master*` (admin console, admin REST API, master
  realm) are proxied only for addresses in `ADMIN_ALLOWED_IPS`; everyone else
  gets 403. Caddy checks the TCP peer address, not `X-Forwarded-For`.
- The `Server` and `Via` response headers are removed. Keycloak sets HSTS,
  `X-Frame-Options`, CSP `frame-ancestors`, `X-Content-Type-Options` and
  `Referrer-Policy`.
- JSON access log on Caddy's stdout (`docker compose logs caddy`). Caddy
  redacts cookies and `Authorization`; the Caddyfile also redacts
  `id_token_hint` in logout URLs and the authorization `code` in redirects.
  Only HTTPS requests are logged, not the port-80 redirects.
- **IPv6:** the compose network is IPv4-only, so every client that connects
  over IPv6 reaches Caddy through docker-proxy as the Docker gateway
  `172.18.0.1`. Such clients never pass the admin allowlist (reach the admin
  console over IPv4), and Keycloak sees `172.18.0.1` as their address. There
  is no AAAA record, so normal clients use IPv4. Never put a private range in
  `ADMIN_ALLOWED_IPS`: it would admit every IPv6 client.

### Containers ([`deploy/docker-compose.yml`](deploy/docker-compose.yml))

- Images pinned to an exact version and digest.
- Healthchecks: Postgres with `pg_isready`, Keycloak with
  `http://localhost:9000/health/ready`. `docker compose up` starts Postgres,
  then Keycloak once Postgres is healthy, then Caddy once Keycloak is healthy.
  After a reboot, Docker's restart policy (`unless-stopped`) starts all three
  at once; the reboot on 2026-09-27 came back healthy with no restarts.
- Keycloak `mem_limit: 1g` (it used about 620 MiB without a limit; the JVM
  heap is 70% of the limit).
- Log rotation for every container: `json-file`, 10 MB × 5 files.
- Compose project name fixed to `auth`, so the volumes stay `auth_*`
  whatever the directory is called.

### Host

- SSH: public key only, `PermitRootLogin prohibit-password`, no X11
  forwarding (`/etc/ssh/sshd_config.d/00-hardening.conf`).
- fail2ban `sshd` jail (`/etc/fail2ban/jail.d/sshd.local`, package defaults
  otherwise): 5 failures within 10 minutes → 10-minute ban (nftables). The
  admin laptop's address is in `ignoreip`.
- ufw: incoming denied except 22/tcp, 80/tcp, 443/tcp and 443/udp; outgoing
  allowed. **Docker-published ports bypass ufw**: Docker's own iptables rules
  forward them to containers before ufw's rules are consulted. That is
  acceptable here because only Caddy publishes ports (80/443). Any port
  published later with `ports:` is public regardless of ufw, unless it is
  bound to `127.0.0.1` like port 9000.
- Hetzner Cloud Firewall in front of the server: inbound TCP 22, 80, 443 and
  UDP 443.
- Swap: 2 GB `/swapfile` (in `/etc/fstab`), `vm.swappiness=10`
  (`/etc/sysctl.d/99-swappiness.conf`).
- unattended-upgrades installs Ubuntu security updates daily and reboots at
  04:00 UTC when an update needs it
  (`/etc/apt/apt.conf.d/52unattended-upgrades-local`). It does not cover the
  Docker packages from `download.docker.com`; see the monthly routine below.

## Not covered yet

- **Backups.** The database exists only in the `auth_keycloak_pg_data` volume
  on this one server. The one-off dump from 2026-09-27 (below) sits on the
  same server.
- Stored login and admin events, monitoring and alerting.
- High availability: one Keycloak instance. If the server is down, logins and
  token refreshes stop; already issued access tokens keep working until they
  expire (5 minutes).
- Dual-stack networking (see IPv6 above).

## First admin on an empty database

The compose file sets no bootstrap admin. On an empty database (a new
server), create a temporary admin once, sign in, create a permanent admin
with OTP, then delete the temporary one. On the server (not tested on this
server yet; see Keycloak's guide "Bootstrapping and recovering an admin
account"):

```bash
cd /opt/auth
docker compose stop keycloak
docker compose run --rm keycloak bootstrap-admin user   # asks for a username and password
docker compose up -d
```

## Runbook

Commands marked **on the laptop** run in `~/dev/auth_server`. Commands marked
**on the server** run after `ssh root@2.28.108.199`.

### Deploy a change

Edit files in `deploy/`, commit, then **on the laptop**:

```bash
deploy/sync.sh --dry-run   # which files would change, with diffs; checks the compose file against the server's .env
deploy/sync.sh             # the same, asks, copies, runs docker compose up -d, waits until healthy
```

`sync.sh` copies the git-tracked files of `deploy/` to `/opt/auth`, never
`.env` or `realm-export.json`. It warns when `deploy/` has uncommitted
changes. The deployed revision is in `/opt/auth/.deployed-revision`, and the
files it replaced are in `/root/auth-sync-backups/`, one directory per deploy
named by UTC time. To undo the most recent deploy, **on the server**:

```bash
last=$(ls -1 /root/auth-sync-backups | tail -1)
cp /root/auth-sync-backups/$last/* /opt/auth/
cd /opt/auth && docker compose up -d
```

The first directory, `/root/auth-sync-backups/20260927T121134Z`, holds the
setup from before stage 2. It also needs the variables that were removed
from `.env` then; they are in `/root/auth-config-2026-09-27/.env`.

### Change the admin IP

The admin console only works from addresses in `ADMIN_ALLOWED_IPS`. Find the
laptop's public IPv4 address **on the laptop**:

```bash
curl -4 -s https://checkip.amazonaws.com
```

**On the server**, edit `ADMIN_ALLOWED_IPS` in `/opt/auth/.env` (one or more
IPv4 addresses or CIDRs separated by spaces, e.g.
`ADMIN_ALLOWED_IPS=198.51.100.20/32`), then recreate Caddy and check the
value it sees:

```bash
nano /opt/auth/.env
cd /opt/auth && docker compose up -d --force-recreate --no-deps caddy
cd /opt/auth && docker compose exec caddy printenv ADMIN_ALLOWED_IPS
```

Also update the address in `ignoreip` in `/etc/fail2ban/jail.d/sshd.local`,
then `systemctl reload fail2ban`. A wrong address only locks out the admin
console, never SSH.

### View logs

**On the server**:

```bash
cd /opt/auth
docker compose ps                          # state and health
docker compose logs --tail 200 keycloak
docker compose logs --since 1h postgres
docker compose logs -f caddy               # JSON access log plus Caddy's own messages
fail2ban-client status sshd                # failed SSH logins and current bans
journalctl -u ssh --since today
```

The server has no `jq`. To read the access log **on the laptop**:

```bash
ssh root@2.28.108.199 'cd /opt/auth && docker compose logs --no-log-prefix caddy' \
  | grep '"http.log.access' | jq -c '{ip: .request.remote_ip, method: .request.method, uri: .request.uri, status}'
```

### Run the smoke test

**On the laptop** (reads the gitignored `deploy/smoke.env`):

```bash
deploy/smoke-test.sh
```

Expected last line: `== Summary: 11 ok, 0 fail ==`.

### Restart the stack

**On the server**:

```bash
cd /opt/auth
docker compose restart keycloak   # one service
docker compose restart            # the whole stack
docker compose up -d              # after editing .env: recreates what changed
```

Never run `docker compose down -v`, `docker volume rm` or
`docker system prune --volumes`: they delete the database and the
certificates.

### Monthly update routine (Docker packages)

unattended-upgrades skips `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-compose-plugin` and `docker-buildx-plugin`. Once a month, **on the
server**:

```bash
DEBIAN_FRONTEND=noninteractive apt-get update
apt list --upgradable
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold upgrade
cd /opt/auth && docker compose ps
test -e /var/run/reboot-required && echo "reboot needed"
```

An upgrade of `docker-ce` restarts the Docker daemon and with it the
containers (about a minute without logins). If a reboot is needed, run
`reboot` or leave it to the 04:00 automatic reboot. Afterwards, **on the
laptop**: `deploy/smoke-test.sh`.

Keycloak, Postgres and Caddy versions change only when the image lines in
`deploy/docker-compose.yml` are edited. For an upgrade, take a dump first
(Keycloak migrates the schema on start and can't migrate back), get the new
digest **on the laptop** with `docker pull` of the new tag (for example
`docker pull quay.io/keycloak/keycloak:26.7.5`; it prints `Digest:
sha256:…`), change the image line, and deploy with `deploy/sync.sh`.

### Safety copies from 2026-09-27

**On the server**, taken before the stage 2 changes:

- `/root/auth-config-2026-09-27/`: copy of `/opt/auth` as it was (including
  the old `.env`; mode 700). It restores the old setup only together with the
  old variables it contains.
- `/root/keycloak-2026-09-27.sql`: plain `pg_dump` of the `keycloak`
  database (mode 600, 348 KiB).
- `/root/iptables-before-ufw-2026-09-27.rules` and
  `/root/ip6tables-before-ufw-2026-09-27.rules`: firewall rules before ufw
  was enabled.

To take a new dump **on the server**:

```bash
cd /opt/auth && (umask 077; docker compose exec -T postgres pg_dump -U keycloak -d keycloak > /root/keycloak-$(date -u +%F).sql)
```
