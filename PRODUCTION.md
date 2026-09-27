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

| Where (on the server)                 | What it holds                                          | If it's lost                                                   |
|---------------------------------------|--------------------------------------------------------|----------------------------------------------------------------|
| Docker volume `auth_keycloak_pg_data` | users, sessions, realm and client config, signing keys | restore the newest dump (see "Restore production from a dump") |
| `/var/backups/pg/auth/`               | nightly dumps of that database, 14 days                | copies on the laptop in `~/backups/finance-nl-server/auth/`    |
| Docker volume `auth_caddy_data`       | TLS certificates, ACME account                         | re-issued automatically                                        |
| `/opt/auth/.env`                      | domain, database password, admin allowlist             | recreate by hand from `deploy/.env.example`                    |
| `/opt/auth/realm-export.json`         | realm file imported once, at the very first start      | not needed while the database exists                           |

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

### Backups ([`deploy/backup/`](deploy/backup/))

- Every night at 02:30 UTC (plus up to 10 minutes of random delay, before
  the 04:00 reboot window) the timer `pg-backup@auth.timer` runs
  `/usr/local/sbin/pg-backup auth`. It takes a `pg_dump -Fc` of the
  `keycloak` database inside the Postgres container, over the local socket
  without a password, and checks the archive with `pg_restore` (the table
  of contents must list objects, and every data block must read back).
  Only then is it renamed to `/var/backups/pg/auth/auth-2026-09-27T1258Z.dump`
  (UTC time in the name). A failed run leaves no file and shows up as a
  failed unit and as errors in the journal.
- The server keeps 14 days of dumps, and always the 3 newest whatever their
  age. `/var/backups/pg/auth/last-success` holds the time and size of the
  last good dump.
- The laptop pulls `/var/backups/pg/` every day at 18:00 local time (or at
  the next login if it was off) into `~/backups/finance-nl-server/`, keeps
  60 days there, and raises a desktop notification if the newest dump of
  any database is older than 36 hours or the pull failed. The pull uses a
  dedicated key that the server allows only to read `/var/backups/pg/`; the
  server holds no credentials for the laptop, so a compromised server can't
  delete the laptop's copies.
- Dumps contain password hashes, client secrets and the realm signing keys:
  directories are mode 700 and files mode 600, on the server and on the
  laptop.
- `pg-restore-test auth` restores the newest dump into a throwaway,
  network-less container and compares it with production. First run on
  2026-09-27: PASS.
- Settings per database are in `/etc/pg-backup/auth.conf` (from
  [`deploy/backup/auth.conf`](deploy/backup/auth.conf)); another database
  needs only another config file (see "Add the finance database").

## Not covered yet

- **Backups beyond the laptop.** The only copy off the server is on the
  laptop, and it is only as recent as the last pull: if the server is lost,
  everything since then is lost too. A laptop that stays off for more than
  14 days also leaves gaps in its history. There is no second off-site copy,
  and Hetzner's server backups are off.
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

### Backups and restore

| What                                   | Where                                                                                                   |
|----------------------------------------|---------------------------------------------------------------------------------------------------------|
| Dumps, 14 days (`pg_dump -Fc`)         | on the server: `/var/backups/pg/auth/`, e.g. `auth-2026-09-27T1258Z.dump` (UTC time)                    |
| Time, file and size of the last dump   | on the server: `/var/backups/pg/auth/last-success`                                                      |
| Settings for the `auth` database       | on the server: `/etc/pg-backup/auth.conf` (from `deploy/backup/auth.conf`)                              |
| Backup and restore-test scripts        | on the server: `/usr/local/sbin/pg-backup`, `/usr/local/sbin/pg-restore-test`                           |
| Units                                  | on the server: `/etc/systemd/system/pg-backup@.service`, `/etc/systemd/system/pg-backup@.timer`         |
| Copies, 60 days                        | on the laptop: `~/backups/finance-nl-server/auth/`                                                      |
| Pull script and timer                  | on the laptop: `~/.local/bin/finance-nl-backup-pull`, `~/.config/systemd/user/finance-nl-backup-pull.*` |
| Pull key                               | on the laptop: `~/.ssh/finance-nl-backup`; on the server: its line in `/root/.ssh/authorized_keys`      |
| One-off plain SQL dump from 2026-09-27 | on the server: `/root/keycloak-2026-09-27.sql`                                                          |

#### Install or update the backup scripts

`deploy/sync.sh` does not copy `deploy/backup/`. After changing anything
there, **on the laptop**:

```bash
deploy/backup/install.sh server   # scripts, units and every deploy/backup/*.conf; enables pg-backup@auth.timer
deploy/backup/install.sh laptop   # pull script and its user timer on this laptop
```

#### Run a backup now

Before any risky change (a Keycloak upgrade, bulk realm edits), **on the
server**:

```bash
systemctl start pg-backup@auth.service    # returns when the dump is done
journalctl -u pg-backup@auth.service -n 10 --no-pager
```

A good run ends with `Wrote /var/backups/pg/auth/auth-….dump: … bytes, …
archive entries` and `OK: … dumps in /var/backups/pg/auth`. A failed run
exits non-zero, `systemctl start` reports it, and no new file is left behind.

#### Check the timers and the last backup

**On the server**:

```bash
systemctl list-timers 'pg-backup@*'                  # NEXT and LAST run
systemctl status pg-backup@auth.service --no-pager   # result of the last run
journalctl -u pg-backup@auth.service --since -3d --no-pager
journalctl -u pg-backup@auth.service -p err --since -30d --no-pager   # errors only
cat /var/backups/pg/auth/last-success
ls -la /var/backups/pg/auth/
```

**On the laptop**:

```bash
systemctl --user list-timers finance-nl-backup-pull.timer
journalctl --user -u finance-nl-backup-pull.service -n 20 --no-pager
ls -la ~/backups/finance-nl-server/auth/
```

#### Run the restore test

Once a month, after changing the backup scripts and after a Postgres
upgrade, **on the server**:

```bash
pg-restore-test auth                                                   # the newest dump
pg-restore-test auth /var/backups/pg/auth/auth-2026-09-27T1258Z.dump   # a specific one
```

It starts a throwaway container from the image production runs (`--rm`,
`--network none`, no published ports, no volumes, data on tmpfs), restores
the dump with `pg_restore --single-transaction`, compares the number of
tables, realms, users in `myapps` and clients in `myapps` with production
(read-only queries), removes the container and prints `PASS` or `FAIL`.
Someone registering between the dump and the test also causes a mismatch:
take a new backup and run the test again. First run, 2026-09-27:

```text
check                      production     restored
tables                            100          100  ok
realms                              2            2  ok
myapps_users                        1            1  ok
myapps_clients                     10           10  ok
```

#### Restore production from a dump

Documented only; never run on production so far. The SQL of steps 5 and 6
and of the rollback below was tried on 2026-09-27 in a throwaway container
like the restore test's. Logins fail from step 4 until Keycloak is healthy
again in step 7. **On the server**, in one shell session:

```bash
# 1. The dump to restore: the newest one. For an older one set, for example,
#    dump=/var/backups/pg/auth/auth-2026-09-27T1258Z.dump
dump=$(ls -1 /var/backups/pg/auth/auth-*.dump | tail -1); echo "$dump"

# 2. Check that it restores, without touching production
pg-restore-test auth "$dump"

# 3. Dump the current state too (may fail if the database is broken), then
#    pause the nightly backup until step 8
systemctl start pg-backup@auth.service
systemctl stop pg-backup@auth.timer

# 4. Stop Keycloak (Caddy answers 502 meanwhile)
cd /opt/auth && docker compose stop keycloak

# 5. Keep the current database under another name and create an empty one
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U keycloak -d postgres \
  -c 'ALTER DATABASE keycloak RENAME TO keycloak_before_restore' \
  -c 'CREATE DATABASE keycloak OWNER keycloak'

# 6. Restore in one transaction, stopping at the first error
docker compose exec -T postgres pg_restore -U keycloak -d keycloak --exit-on-error --single-transaction < "$dump"

# 7. Start Keycloak; repeat the ps until it shows (healthy), about a minute
docker compose start keycloak
docker compose ps keycloak

# 8. Resume the nightly backup
systemctl start pg-backup@auth.timer
```

Then **on the laptop** run `deploy/smoke-test.sh` (expected `11 ok, 0 fail`)
and look at users and clients in the admin console.

Step 5 fails if `keycloak_before_restore` is still there from an earlier
restore; drop that one first (below). If step 6 or 7 fails, go back to the
previous database, **on the server**:

```bash
cd /opt/auth && docker compose stop keycloak
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U keycloak -d postgres \
  -c 'DROP DATABASE IF EXISTS keycloak' \
  -c 'ALTER DATABASE keycloak_before_restore RENAME TO keycloak'
docker compose start keycloak
systemctl start pg-backup@auth.timer
```

Once the restored state has worked for a few days, **on the server**:

```bash
cd /opt/auth && docker compose exec -T postgres psql -X -U keycloak -d postgres -c 'DROP DATABASE keycloak_before_restore'
```

If the server or the volume is lost, the dump comes from the laptop. Build
the stack as usual (`deploy/sync.sh`, `/opt/auth/.env` from
`deploy/.env.example`; a new `POSTGRES_PASSWORD` is fine, since the dump
holds the database but not the roles), run `deploy/backup/install.sh
server`, then copy the newest laptop copy up, **on the laptop**:

```bash
ls -1 ~/backups/finance-nl-server/auth/
scp ~/backups/finance-nl-server/auth/auth-2026-09-27T1258Z.dump root@2.28.108.199:/root/
```

and follow the steps above with `dump=/root/auth-2026-09-27T1258Z.dump`. In
step 2 the comparison then fails, because "production" is the new, empty
realm; there only the restore itself (`Restored in …`) counts.

#### Add the finance database

For the finance app's own Postgres, running under Docker Compose on this
server:

1. **On the laptop**, copy `deploy/backup/auth.conf` to
   `deploy/backup/finance.conf` and set `COMPOSE_DIR` (the finance compose
   directory, for example `/opt/finance`), `SERVICE` (its Postgres service),
   `DB_NAME` and `DB_USER` (`POSTGRES_DB` and `POSTGRES_USER` in its compose
   file) and `BACKUP_DIR=/var/backups/pg/finance`. Replace the `CHECK_*`
   lines with read-only counts that fit the finance schema, or delete them
   (then only the number of tables is compared). Commit it.
2. **On the laptop**: `deploy/backup/install.sh server`. It installs
   `/etc/pg-backup/finance.conf` and enables `pg-backup@finance.timer`.
3. **On the server**:

   ```bash
   systemctl start pg-backup@finance.service
   journalctl -u pg-backup@finance.service -n 10 --no-pager
   pg-restore-test finance
   ```

4. Nothing changes on the laptop: the next pull copies
   `/var/backups/pg/finance/` and checks its freshness too. To pull at once,
   **on the laptop**: `systemctl --user start finance-nl-backup-pull.service`.

`pg_dump` runs inside the container over the local socket, which the
official `postgres` image allows without a password. Restoring the finance
database works like the steps above, with its compose directory, service,
database and user.

#### The laptop pull

- The user timer `finance-nl-backup-pull.timer` runs
  `~/.local/bin/finance-nl-backup-pull` (a copy of
  `deploy/backup/pull-backups.sh`) every day at 18:00. User timers run only
  while the user is logged in; `Persistent=true` makes up a missed run at
  the next login.
- It connects as `root` with `~/.ssh/finance-nl-backup` and no other key.
  The server accepts that key only with
  `restrict,command="/usr/bin/rrsync -ro /var/backups/pg/"`: no shell, no
  other commands, no port forwarding, no writes, nothing outside
  `/var/backups/pg/`.
- rsync copies new dumps and the `last-success` files into
  `~/backups/finance-nl-server/`, one folder per database, and deletes
  nothing on either side. The script then deletes local dumps older than
  60 days, always keeping the newest 3 per database.
- It fails, with a desktop notification, if the pull failed (5 attempts a
  minute apart) or the newest dump of any database is older than 36 hours.

**On the laptop**:

```bash
systemctl --user status finance-nl-backup-pull.service --no-pager   # result of the last pull
systemctl --user start finance-nl-backup-pull.service               # pull now
cat ~/backups/finance-nl-server/auth/last-success
```

To confirm the key is still read-only, **on the laptop** (expected:
`/usr/bin/rrsync error: SSH_ORIGINAL_COMMAND does not run rsync`):

```bash
ssh -i ~/.ssh/finance-nl-backup -o IdentitiesOnly=yes root@2.28.108.199 id
```

To revoke the key, **on the server** (the line ends with the key's comment;
check with a new SSH connection afterwards that your own key still works):

```bash
grep -n 'finance-nl-backup-pull$' /root/.ssh/authorized_keys
sed -i '/ finance-nl-backup-pull$/d' /root/.ssh/authorized_keys
```

To set it up again (for example on a new laptop), **on the laptop**:

```bash
ssh-keygen -t ed25519 -N '' -C finance-nl-backup-pull -f ~/.ssh/finance-nl-backup
printf 'restrict,command="/usr/bin/rrsync -ro /var/backups/pg/" %s\n' "$(cat ~/.ssh/finance-nl-backup.pub)" \
  | ssh root@2.28.108.199 'cat >> /root/.ssh/authorized_keys'
deploy/backup/install.sh laptop
```

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
laptop**: `deploy/smoke-test.sh`. In the same monthly session, run the
restore test (**on the server**: `pg-restore-test auth`).

Keycloak, Postgres and Caddy versions change only when the image lines in
`deploy/docker-compose.yml` are edited. For an upgrade, run a backup first
(**on the server**: `systemctl start pg-backup@auth.service`; Keycloak
migrates the schema on start and can't migrate back), get the new
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

The plain SQL dump restores with `psql`, not `pg_restore`. For a new dump,
see "Run a backup now".
