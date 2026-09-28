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

| Where (on the server)                 | What it holds                                                            | If it's lost                                                             |
|---------------------------------------|--------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Docker volume `auth_keycloak_pg_data` | users, sessions, realm and client config, signing keys                   | restore the newest dump (see "Restore production from a dump")           |
| `/var/backups/pg/auth/`               | nightly dumps of that database, 14 days                                  | copies on the laptop in `~/backups/finance-nl-server/auth/`              |
| Docker volume `auth_caddy_data`       | TLS certificates, ACME account                                           | re-issued automatically                                                  |
| `/opt/auth/.env`                      | domain, database password, admin allowlist                               | recreate by hand from `deploy/.env.example`                              |
| `/opt/caddy-sites/`                   | other projects' Caddy site files, one per project                        | each project installs its file again with `caddy-site install`           |
| `/opt/auth/vault/`                    | Keycloak vault: the Brevo SMTP key, the Google and GitHub client secrets | create new ones in Brevo, Google and GitHub and write them (see "Vault") |
| `/root/automation-cli.secret`         | secret of the admin client `automation-cli`                              | regenerate it in the admin console (see "Admin CLI")                     |

`.env`, `vault/` and `automation-cli.secret` contain secrets. They exist only
on the server, and `deploy/sync.sh` never copies or overwrites them. The
server's `/opt/auth/.env` is the one that counts; the laptop's gitignored
`deploy/.env` is not kept in sync. The realm configuration lives only in the
database: there is no realm import file, so change settings in the admin
console or with kcadm (see "Admin CLI"), and the nightly dump covers them.

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
- Other projects' sites: the Caddyfile imports every
  `/opt/caddy-sites/*.caddy` (mounted read-only; files get there only
  through `caddy-site install`, which validates them), and Caddy is also on
  the Docker network `edge`, where those projects' containers are. The
  admin allowlist, the header removal and the access log apply to
  `auth.finance-nl.com` only. Caddy reaches Keycloak as `auth-keycloak`, a
  name that exists only on the stack's own network. See "Hosting another
  project behind this Caddy".
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

### DNS

finance-nl.com's DNS is at Squarespace. `auth.finance-nl.com` and
`app.finance-nl.com` are A records for `2.28.108.199`, with no AAAA record
(see IPv6 above). Each of the two names has exactly two CAA records, and
`finance-nl.com` itself has none (checked 2026-09-28 against the laptop's
resolver, 1.1.1.1 and 8.8.8.8):

```text
auth.finance-nl.com.  CAA  0 issue "letsencrypt.org"
auth.finance-nl.com.  CAA  0 issue "sectigo.com"
app.finance-nl.com.   CAA  0 issue "letsencrypt.org"
app.finance-nl.com.   CAA  0 issue "sectigo.com"
```

- A certificate authority must check CAA before it issues: only these two
  may issue certificates for `auth.finance-nl.com` and `app.finance-nl.com`.
- `letsencrypt.org`: Let's Encrypt, Caddy's first issuer. Both current
  certificates come from it.
- `sectigo.com`: ZeroSSL, whose certificates Sectigo issues, is Caddy's
  fallback issuer. In Caddy 2.11.4 the fallback is active only when the
  Caddyfile sets a global `email` option; `deploy/Caddyfile` sets none, so
  today Caddy asks only Let's Encrypt (and keeps retrying it). The record
  lets ZeroSSL issue without a DNS change if `email` is ever added.
- `finance-nl.com` has no CAA record, so a new name under it has no
  restriction until it gets its own. Give every new hostname the same two
  records.

To check, **on the laptop** (every line should show the two records, except
`finance-nl.com`, which shows none):

```bash
for r in "" @1.1.1.1 @8.8.8.8; do for n in auth.finance-nl.com app.finance-nl.com finance-nl.com; do echo "$n ${r:-local}: $(dig $r +short CAA $n | sort | tr '\n' ' ')"; done; done
```

### Containers ([`deploy/docker-compose.yml`](deploy/docker-compose.yml))

- Images pinned to an exact version and digest.
- Healthchecks: Postgres with `pg_isready`, Keycloak with
  `http://localhost:9000/health/ready`. `docker compose up` starts Postgres,
  then Keycloak once Postgres is healthy, then Caddy once Keycloak is healthy.
  After a reboot, Docker's restart policy (`unless-stopped`) starts all three
  at once; the reboot on 2026-09-27 came back healthy with no restarts.
- Keycloak `mem_limit: 1280m`. The JVM heap is 70% of the limit, 896 MiB;
  at `1g` it was about 700 MiB, too tight next to the 540–620 MiB
  measured before. Right after the switch on 2026-09-27 it used 465 MiB.
- Only Caddy is on the shared network `edge`; Keycloak and Postgres are
  only on the stack's own network `auth_default`. There Keycloak also has
  the alias `auth-keycloak`, Caddy's upstream: the prefix `auth-` is
  reserved for this stack, so no container on `edge` can share the name.
- Log rotation for every container: `json-file`, 10 MB × 5 files.
- Compose project name fixed to `auth`, so the volumes stay `auth_*`
  whatever the directory is called.
- Keycloak runs `start` without `--import-realm`, with the file vault
  (`KC_VAULT=file`, `KC_VAULT_DIR=/opt/keycloak/vault`). `/opt/auth/vault` is
  mounted there read-only. It belongs to uid 1000, the container's `keycloak`
  user (no account on the host has that uid), group 0, directory mode 500 and
  file mode 400, so only that user and root can read it.

### Realm `myapps`

A public demo: anyone can register with an email address, has to confirm
the address before the first login, and can reset a forgotten password by
email. Anyone can also sign in with Google or GitHub (see "Identity
providers"). Set with kcadm on 2026-09-27 (stage 4, and stage 5 for the
identity providers, the default role and the admin events expiration):

| Area                  | Setting                                                                                                                                                                                                                                                                                                                                            |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Registration, login   | `registrationAllowed`, `registrationEmailAsUsername`, `verifyEmail`, `resetPasswordAllowed` and `loginWithEmailAllowed` on; `duplicateEmailsAllowed`, `editUsernameAllowed` and `rememberMe` off                                                                                                                                                   |
| Identity providers    | `google` and `github`, shown on the login page, first login flow `first broker login` (the default, unchanged). Details in "Identity providers" below                                                                                                                                                                                              |
| Default roles         | `default-roles-myapps` = `offline_access`, `uma_authorization`, `account` → `manage-account` and `view-profile` (Keycloak's defaults), plus `finance-tracker` → `user` since stage 5, so every user, new or existing, may use Finance Tracker                                                                                                      |
| Password policy       | `length(12) and maxLength(128) and notUsername and notEmail`                                                                                                                                                                                                                                                                                       |
| Brute-force detection | temporary lockout only (`permanentLockout` off): after 10 failed logins the user waits 60 s, and every further 10 failures add 60 s (strategy `MULTIPLE`), up to 15 minutes; the count resets 12 hours after the last failure; two failures within 1 s also cause a 60 s wait                                                                      |
| SMTP                  | `smtp-relay.brevo.com`, port 587, STARTTLS on, SSL off, authentication with the Brevo SMTP login, password `${vault.smtppassword}`; from `noreply@finance-nl.com`, display name `finance-nl.com`. Hetzner blocks outbound ports 25 and 465, so 587 is the only option. finance-nl.com is authenticated in Brevo; SPF, DKIM and DMARC pass at Gmail |
| User events           | stored for 30 days, all event types. The `jboss-logging` listener also writes error events (`LOGIN_ERROR` and the like) to the Keycloak container log                                                                                                                                                                                              |
| Admin events          | stored without representation details, kept 90 days (realm attribute `adminEventsExpiration` = 7776000 s, since stage 5); Keycloak's periodic cleanup deletes older ones                                                                                                                                                                           |
| Tokens                | refresh-token rotation: `revokeRefreshToken` on, `refreshTokenMaxReuse` 0. Other lifetimes are Keycloak's defaults: access token 5 min, SSO session idle 30 min and max 10 h, offline session idle 30 days with no maximum, access code 1 min, login 30 min, user action 5 min, action tokens 5 min (user) and 12 h (admin)                        |
| Client policy         | `pkce-s256-public-clients`: for every public client (condition `client-access-type` = public), the profile `pkce-s256` runs the `pkce-enforcer` executor with `auto-configure` on. An authorization request from a public client without PKCE S256 is rejected with `invalid_request`                                                              |
| `sslRequired`         | `external`. `all` would lock out kcadm, which talks to Keycloak over `http://localhost:8080` inside the container. From outside only Caddy reaches Keycloak, and it forwards the https scheme                                                                                                                                                      |

Clients: the built-in `account`, `account-console`, `admin-cli`, `broker`,
`realm-management` and `security-admin-console`, plus:

- `automation-cli`: confidential, service account only, with the
  `realm-management` role `realm-admin` (every admin right in `myapps`, none
  in `master`). kcadm on the server signs in with it (see "Admin CLI"). No
  redirect URIs and no web origins (the leftover `/*` entries were removed
  in stage 5; its standard flow is off). **Disabled** since 2026-09-28,
  enabled only for maintenance (see "Maintenance access").
- `smoke-test`: confidential, `client_credentials` only (no standard flow,
  no direct access grants); its service account has no roles, not even the
  default ones. Only `deploy/smoke-test.sh` uses it.
- `finance-tracker`: the Finance Tracker app, confidential (see below).

The built-in `admin-cli` is public with direct access grants on, so anyone
can try `myapps` passwords over the token endpoint without a client secret;
brute-force detection covers that. In stage 4 the demo clients `shop-api`,
`blog-api` and `admin-app`, the old confidential `finance-tracker` (from the
realm import, with a dev secret) and the user `testuser` were deleted; stage
5 created `finance-tracker` anew.

### Client `finance-tracker` (Finance Tracker)

Finance Tracker (`https://app.finance-nl.com`, its own repository) signs
users in as a backend-for-frontend: its Spring backend runs the
authorization code flow with PKCE, keeps the tokens in its server-side
session and gives the browser only an `HttpOnly` session cookie. So the
client is confidential; a public client would put tokens in the browser for
nothing. Created with kcadm on 2026-09-27 (stage 5):

| Setting                        | Value                                                                                                                 | Why                                                                                                                                                                                |
|--------------------------------|-----------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Client authentication          | on (`client-secret`)                                                                                                  | the backend can keep a secret, and the code exchange and refreshes then need it                                                                                                    |
| Flows                          | standard flow only; implicit flow, direct access grants and service account off; consent off                          | the app only needs the code flow, nobody types a password into anything but Keycloak's page, and it is a first-party app                                                           |
| PKCE                           | `pkce.code.challenge.method` = `S256` on the client                                                                   | the realm's client policy covers only public clients. Spring Security 6.5 sends `code_challenge_method=S256` because the app sets `requireProofKey(true)`                          |
| Valid redirect URI             | `https://app.finance-nl.com/login/oauth2/code/keycloak`, exact                                                        | Spring's callback `{baseUrl}/login/oauth2/code/keycloak`. An exact URI leaves no room for redirects elsewhere on the site                                                          |
| Valid post logout redirect URI | `https://app.finance-nl.com/`                                                                                         | where the app's logout handler returns to (`{baseUrl}/`)                                                                                                                           |
| Web origins                    | none                                                                                                                  | the browser never calls Keycloak with CORS; every token request comes from the backend                                                                                             |
| Full scope allowed             | off                                                                                                                   | tokens carry only this client's own roles, no realm roles and no other client's roles                                                                                              |
| Front-channel logout           | off; no back-channel logout URL                                                                                       | the app has neither endpoint. A logout elsewhere ends the app's session at its next token refresh, within about 5 minutes                                                          |
| Base URL                       | `https://app.finance-nl.com/`                                                                                         | the app's link in the account console                                                                                                                                              |
| Client role                    | `user`, in `default-roles-myapps`                                                                                     | the backend requires it (see "Audience and role")                                                                                                                                  |
| Mapper                         | `finance-tracker audience`: Audience, Included Client Audience `finance-tracker`, access token and introspection only | see "Audience and role"                                                                                                                                                            |
| Secret                         | generated by Keycloak when the client was created                                                                     | never read on the server or put in this repository; it is copied from the admin console (Clients → `finance-tracker` → Credentials) into the app's `.env` when the app is deployed |

The app's local development uses the dev stack's Keycloak at
`http://localhost:8080`, so production has no localhost redirect URIs.

#### Audience and role

The backend accepts an access token only if its `iss` is
`https://auth.finance-nl.com/realms/myapps`, its `aud` contains
`finance-tracker` and `resource_access.finance-tracker.roles` contains
`user`. It ignores realm roles on purpose. The user id is `sub`; `email`,
`name` and `preferred_username` are only shown.

- **Audience.** Keycloak's built-in "audience resolve" mapper puts into
  `aud` every client whose roles the token carries, except the client that
  asked for the token. Without the `finance-tracker audience` mapper the
  app's own tokens would lack `finance-tracker` in `aud`, and the backend
  would reject them. The mapper names the client itself (Included Client
  Audience) rather than a free-text custom audience: the audience is the
  same client whose roles the backend reads, so `aud` and
  `resource_access` always name the same client.
- **Role.** `finance-tracker` → `user` is a client role, so it means
  nothing to other apps, and it is part of `default-roles-myapps`: every
  new user gets it, whether they register with an email address or arrive
  through Google or GitHub, and existing users have it through their
  default role too. Each user sees only their own ledger, because the app
  keys all data by `sub`.
- **Limit.** Clients with full scope allowed (`admin-cli`,
  `security-admin-console`) also get `finance-tracker` in `aud` and the
  `user` role in their tokens. With the password grant on `admin-cli`, a
  user can get such a token for themselves and call the API directly; that
  opens only their own data, as a normal login would.

To stop giving the role to everyone, remove it from the default role and
assign it per user instead, **on the server** after signing in (see "Admin
CLI"):

```bash
kc remove-roles -r myapps --rname default-roles-myapps --cclientid finance-tracker --rolename user
```

Example access token for the only user, from the evaluate-scopes endpoint
on 2026-09-27 (scope `openid profile email`, personal values redacted):

```json
{
  "iss": "https://auth.finance-nl.com/realms/myapps",
  "aud": "finance-tracker",
  "azp": "finance-tracker",
  "sub": "7df2283a-b1c7-4959-a9ac-e88f71859ba6",
  "typ": "Bearer",
  "acr": "1",
  "resource_access": { "finance-tracker": { "roles": ["user"] } },
  "scope": "openid email profile",
  "email_verified": true,
  "email": "(redacted)",
  "name": "(redacted)",
  "preferred_username": "(redacted)",
  "given_name": "(redacted)",
  "family_name": "(redacted)"
}
```

There is no `realm_access`, because full scope is off.

### Identity providers (Google, GitHub)

Set with kcadm on 2026-09-27 (stage 5). Both use the default first login
flow and import mode, and both show a button on the login page.

| Setting                         | `google`                                                                                                   | `github`                                                                                      |
|---------------------------------|------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| Provider type, display name     | Google, `Google`                                                                                           | GitHub, `GitHub`                                                                              |
| Client ID                       | `891890306139-5250q9075robb0lvl3c8phhjacqdq8qm.apps.googleusercontent.com`                                 | `Ov23liuOFSXjfJwCjwZk`                                                                        |
| Client secret                   | `${vault.googlesecret}`, the file `/opt/auth/vault/myapps_googlesecret`                                    | `${vault.githubsecret}`, the file `/opt/auth/vault/myapps_githubsecret`                       |
| Scopes                          | `openid profile email`                                                                                     | the provider's default (`user:email`: profile and email addresses, read-only)                 |
| Trust email                     | on                                                                                                         | off                                                                                           |
| First login flow                | `first broker login`                                                                                       | `first broker login`                                                                          |
| Sync mode                       | import                                                                                                     | import                                                                                        |
| Store tokens, link only, hidden | off                                                                                                        | off                                                                                           |
| Configured at the provider      | Google Cloud Console → Google Auth Platform → Clients: the web application client with the client ID above | GitHub → Settings → Developer settings → OAuth Apps → `finance-nl.com`                        |
| Redirect URI at the provider    | Authorized redirect URI `https://auth.finance-nl.com/realms/myapps/broker/google/endpoint`                 | Authorization callback URL `https://auth.finance-nl.com/realms/myapps/broker/github/endpoint` |

- **Trust email on for Google:** Google returns only addresses it has
  verified, so a new account from Google starts with its email verified.
- **Trust email off for GitHub:** an address from GitHub is not taken as
  proof. A new account from GitHub gets the required action `VERIFY_EMAIL`,
  and Keycloak sends it the confirmation email before the first login
  completes.
- **Import:** profile data is copied only at the first login; later
  changes at Google or GitHub don't overwrite what the user has here.
- The client IDs are not secret. Only the vault files hold the secrets.
- For anyone outside the Google project to sign in with Google, the Google
  Auth Platform → Audience page must say "In production"; in "Testing"
  only the listed test users can. Not checked in stage 5.

What a first login does (tested on 2026-09-27):

- **New email address:** Keycloak creates a user (`REGISTER` event with
  `register_method` = `broker`) with the default roles. From GitHub the
  user first confirms the address by email; from Google they are signed in
  at once. "Review Profile" appears only when the provider leaves a
  required field empty.
- **Email of an existing user:** Keycloak shows "Account already exists";
  after "Add to existing account" it emails a link to that account's
  address ("Verify existing account by Email"), and the link links the
  accounts and signs the user in. Trust email does not skip this step, so
  a Google account can't take over an account here just by having the same
  address. The flow's other option, signing in again with the account's
  password, is meant for when Keycloak can't send that email (not tested).
- **Linking while signed in:** account console → Account security →
  Linked accounts → Link account. An identity that is already linked to
  another user is refused (`FEDERATED_IDENTITY_LINK_ERROR`,
  `identityProviderAlreadyLinkedMessage`); delete or unlink the other user
  first.

To see who uses which provider, **on the server** after signing in (see
"Admin CLI"):

```bash
kc get users -r myapps -q idpAlias=github --fields id,username
kc get users -r myapps -q idpAlias=google --fields id,username
kc get users/7df2283a-b1c7-4959-a9ac-e88f71859ba6/federated-identity -r myapps
```

The last line lists the providers linked to one user (here the first user).

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
  [`deploy/backup/auth.conf`](deploy/backup/auth.conf)). Finance Tracker's
  database is backed up the same way as the instance `finance`, with its
  settings from the finance repository (see "The finance database").

## Not covered yet

- **Backups beyond the laptop.** The only copy off the server is on the
  laptop, and it is only as recent as the last pull: if the server is lost,
  everything since then is lost too. A laptop that stays off for more than
  14 days also leaves gaps in its history. There is no second off-site copy,
  and Hetzner's server backups are off.
- Monitoring and alerting. Events are stored in `myapps` (see above), but
  nothing reports on them.
- **Spam registrations.** Registration is open with no captcha and no rate
  limit; only the email confirmation stands in the way. Watch the `REGISTER`
  events (see "Watch registrations and events") and add a captcha if bots
  show up.
- **Logout propagation to apps.** No client has back-channel logout:
  Finance Tracker has no endpoint for it, so a logout elsewhere (or a
  disabled user) reaches it only at its next token refresh, within about
  5 minutes.
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
deploy/sync.sh --dry-run   # which files would change, with diffs; checks the compose file against the server's .env and the Caddyfile with the site files
deploy/sync.sh             # the same, asks, copies, runs docker compose up -d, waits until healthy
```

`sync.sh` copies the git-tracked files of `deploy/` to `/opt/auth`, never
`.env` or `vault/`. It warns when `deploy/` has uncommitted changes. Before
copying anything, it stops if `/opt/auth` holds a compose file that Docker
Compose would read next to or instead of `docker-compose.yml`, such as
`docker-compose.override.yml`; checks the new compose file against the
server's `.env`; and validates the new Caddyfile together with the site
files in `/opt/caddy-sites`, with the Caddy image and environment the new
compose file defines (this needs `python3` on the server). If any of these
checks fails, it stops without changing anything; `--dry-run` runs them too.
Then it creates the Docker network `edge` and the directory
`/opt/caddy-sites` (root, mode 755) if they are missing, never touching the
directory's contents, copies the files, installs `deploy/caddy-site.sh` as
`/usr/local/sbin/caddy-site`, and runs `docker compose up -d`. Caddy mounts
the Caddyfile as a single file, and rsync replaces a file by renaming a new
one over it, so a running Caddy keeps the old one, even through a reload,
until it restarts: `sync.sh` restarts caddy when the Caddyfile inside it
differs from `/opt/auth/Caddyfile` (about a second without HTTPS). The
deployed revision is in `/opt/auth/.deployed-revision`, and the files it
replaced are in `/root/auth-sync-backups/`, one directory per deploy named
by UTC time. To undo the most recent deploy, **on the server**:

```bash
last=$(ls -1 /root/auth-sync-backups | tail -1)
cp /root/auth-sync-backups/$last/* /opt/auth/
cd /opt/auth && docker compose up -d && docker compose restart --no-deps caddy
```

The restart makes Caddy load the restored Caddyfile (see above).

The first directory, `/root/auth-sync-backups/20260927T121134Z`, holds the
setup from before stage 2. It also needs the variables that were removed
from `.env` then; they are in `/root/auth-config-2026-09-27/.env`. The
compose files from before stage 4 (up to `20260927T135505Z`) mount
`/opt/auth/realm-export.json`, which no longer exists; to go back to one of
them, first copy `/root/auth-config-2026-09-27/realm-export.json` to
`/opt/auth/` (it holds the old client secrets and the test user's password,
but it is only imported into an empty database).

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

**On the laptop**:

```bash
deploy/smoke-test.sh
```

Expected last line: `== Summary: 11 ok, 0 fail ==`. The script needs
`curl`, `jq`, `python3` and `nc`, and reads the gitignored
`deploy/smoke.env` (`DOMAIN`, `REALM`, `CLIENT_ID=smoke-test`,
`CLIENT_SECRET`). It uses no user account. It checks that:

1. HTTP redirects to HTTPS;
2. the certificate is valid and the realm answers;
3. the discovery document's issuer is `https://auth.finance-nl.com/realms/myapps`;
4. JWKS lists signing keys;
5. `smoke-test` gets a token with `client_credentials`;
6. the token's `iss` matches the issuer;
7. a wrong client secret gets 401 `unauthorized_client`, "Invalid client or
   Invalid client credentials";
8. the password grant with `smoke-test` and its correct secret is refused
   with 400 `unauthorized_client`, "Client not allowed for direct access
   grants";
9. ports 5432, 8080 and 9000 are closed from outside (three checks).

Keycloak 26.7.4 answers checks 7 and 8 with the same error code, so they
compare the HTTP status and the `error_description` too: with a wrong
`CLIENT_SECRET` in `smoke.env`, check 8 gets check 7's answer and fails
(and so does check 5). After a Keycloak upgrade, compare these two answers
with what the new version says, and update the script if they changed.

Each run leaves a `CLIENT_LOGIN`, a `CLIENT_LOGIN_ERROR` and a `LOGIN_ERROR`
event in `myapps`; the two errors also appear as WARN lines in the Keycloak
log. The `smoke-test` secret only yields a token with no roles.

To create `deploy/smoke.env` on another laptop, or after the secret was
regenerated, copy the secret from the admin console (realm `myapps` →
Clients → `smoke-test` → Credentials), then **on the laptop** paste it at
the prompt:

```bash
IFS= read -rs -p 'smoke-test client secret: ' s; echo
(umask 077; printf 'DOMAIN=auth.finance-nl.com\nREALM=myapps\nCLIENT_ID=smoke-test\nCLIENT_SECRET=%s\n' "$s" > deploy/smoke.env)
unset s
```

### Maintenance access

`automation-cli` is the only way kcadm on the server gets into realm
`myapps` (see "Admin CLI" below), and its secret is worth as much as an
admin password. So it is **disabled by default** (since 2026-09-28): while
it is off, Keycloak gives it no token, even with the right secret. Its
secret stays in `/root/automation-cli.secret` on the server the whole time;
disabling and enabling don't change it.

Before a task that needs it (the kcadm commands in this runbook, or a step
of the finance runbook that signs in as `automation-cli`):

1. Open the admin console, from an address in `ADMIN_ALLOWED_IPS` (see
   "Change the admin IP"), and sign in.
2. Go to realm `myapps` → **Clients** → `automation-cli`, and switch
   **Enabled** on.
3. **On the server**, sign in with kcadm and do the task (see "Admin CLI").

Afterwards, disable it again:

4. **On the server**, delete kcadm's session file:

   ```bash
   docker compose -f /opt/auth/docker-compose.yml exec -T keycloak rm -f /tmp/kcadm.config </dev/null
   ```

5. In the admin console, realm `myapps` → **Clients** → `automation-cli`,
   switch **Enabled** off and confirm. (Or, before step 4, let kcadm disable
   its own client: the last command in "Admin CLI".)
6. **On the server**, check that it gets no token. The command prints only
   the HTTP status, never a token: `401` means disabled, `200` means it is
   still enabled.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://auth.finance-nl.com/realms/myapps/protocol/openid-connect/token \
     -d grant_type=client_credentials -d client_id=automation-cli --data-urlencode client_secret@/root/automation-cli.secret
   ```

While it is disabled, kcadm's sign-in fails with `Invalid client or Invalid
client credentials [invalid_client]`: enable it first (steps 1 and 2).

### Admin CLI (kcadm with `automation-cli`)

The confidential client `automation-cli` lets this runbook and scripts
change realm `myapps` from the server without the master admin: kcadm runs
inside the Keycloak container, talks to `http://localhost:8080` and signs in
with the client's secret. Its service account holds the `realm-management`
role `realm-admin`, so the secret is worth as much as an admin password for
`myapps`; it has no rights in `master`. The secret is in
`/root/automation-cli.secret` on the server (owner root, mode 600, no
trailing newline). Never print it; the commands below read it with
`$(cat …)` inside the server's shell. The client is disabled except during
maintenance: enable it first, and disable it afterwards (see "Maintenance
access").

Sign in, **on the server**. The sections below use the `kc` helper; kcadm
keeps its session in `/tmp/kcadm.config` inside the container:

```bash
kc() { docker compose -f /opt/auth/docker-compose.yml exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config </dev/null; }
kc config credentials --server http://localhost:8080 --realm myapps --client automation-cli --secret "$(cat /root/automation-cli.secret)"
kc get realms/myapps --fields registrationAllowed,verifyEmail,passwordPolicy
```

- Always pass `--fields` when reading clients: a full client
  representation includes its secret.
- A repeated `-q` key counts only once (the last one wins), so filter by one
  event type at a time.

When you are done, delete the session file, **on the server** (recreating
the container deletes it too):

```bash
docker compose -f /opt/auth/docker-compose.yml exec -T keycloak rm -f /tmp/kcadm.config </dev/null
```

**Rotate the secret**, **on the server**, after signing in. The old secret
stops working at once; the current kcadm session lasts until its token
expires (5 minutes). Check that `wc -c` does not print 0 before the `mv`:

```bash
id=$(kc get clients -r myapps -q clientId=automation-cli --fields id --format csv --noquotes)
kc create clients/$id/client-secret -r myapps > /dev/null
(umask 077; kc get clients/$id/client-secret -r myapps --fields value --format csv --noquotes | tr -d '\n' > /root/automation-cli.secret.new)
wc -c /root/automation-cli.secret.new
mv /root/automation-cli.secret.new /root/automation-cli.secret
kc config credentials --server http://localhost:8080 --realm myapps --client automation-cli --secret "$(cat /root/automation-cli.secret)"
```

On 2026-09-27 these commands rotated the `smoke-test` secret (with
`smoke-test` in place of `automation-cli`); they have not been run for
`automation-cli` itself. If something goes wrong halfway, regenerate the
secret in the admin console (realm `myapps` → Clients → `automation-cli` →
Credentials → Regenerate), copy it and write it, **on the server**:

```bash
IFS= read -rs -p 'automation-cli secret: ' s; echo
(umask 077; printf '%s' "$s" > /root/automation-cli.secret)
unset s
```

**Disable it** in the admin console (realm `myapps` → Clients →
`automation-cli` → Enabled off). New sign-ins fail at once. kcadm can also
disable its own client, **on the server** after signing in, but then only
the admin console can turn it back on (this is how it was disabled on
2026-09-28):

```bash
id=$(kc get clients -r myapps -q clientId=automation-cli --fields id --format csv --noquotes)
kc update clients/$id -r myapps -s enabled=false
```

### Vault: add or rotate a secret

A realm setting can refer to a file in the vault instead of holding the
secret: `${vault.smtppassword}` in realm `myapps` reads
`/opt/auth/vault/myapps_smtppassword`. The file name is the realm name, an
underscore and the key; an underscore inside the realm name or the key is
doubled (key `github_secret` in realm `myapps` would be the file
`myapps_github__secret`). The file holds only the value, with no trailing
newline. The vault holds:

| File                  | Used by                                             | Where a new value comes from                                                                                        |
|-----------------------|-----------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `myapps_smtppassword` | realm SMTP password, `${vault.smtppassword}`        | Brevo → SMTP & API → SMTP keys                                                                                      |
| `myapps_googlesecret` | identity provider `google`, `${vault.googlesecret}` | Google Cloud Console → Google Auth Platform → Clients → the client `891890306139-5250q9075robb0lvl3c8phhjacqdq8qm…` |
| `myapps_githubsecret` | identity provider `github`, `${vault.githubsecret}` | GitHub → Settings → Developer settings → OAuth Apps → `finance-nl.com`                                              |

On a new server, create the directory before the first `docker compose up`
(otherwise Docker creates it empty and owned by root), **on the server**:

```bash
install -d -m 500 -o 1000 -g 0 /opt/auth/vault
```

To replace a value (or add another secret under its own file name),
**on the server**. Set `f` to the file (the example replaces the SMTP key;
use `myapps_googlesecret` or `myapps_githubsecret` for the others). The
value is pasted at the prompt, so it never reaches the shell history, and
`printf` is a shell builtin, so it never shows up in the process list:

```bash
f=/opt/auth/vault/myapps_smtppassword
IFS= read -rs -p 'Value: ' v; echo
(umask 077; printf '%s' "$v" > "$f.new")
unset v
chown 1000:0 "$f.new"
chmod 400 "$f.new"
mv "$f.new" "$f"
stat -c '%n %u:%g %a %s bytes' /opt/auth/vault/*
```

`stat` must show owner `1000:0`, mode `400` and a size that is not 0 for
every file. These steps were tried with a throwaway key on 2026-09-27; the
container could read the file. The Google and GitHub files were written by
hand in stage 5 and then given the same owner and mode. Keycloak reads a
vault file when it uses the value, so no restart should be needed. Check:
for the SMTP key, send yourself a password-reset email from the login page;
for Google or GitHub, sign in with that button in a private window. Restart
Keycloak (**on the server**: `cd /opt/auth && docker compose restart
keycloak`) if it still fails.

**Rotate the Google or GitHub client secret** without an outage:

1. At the provider (see the table above), create a second secret; both
   providers show a new secret only once. Google: the client's page → Add
   secret. GitHub: the OAuth App → Generate a new client secret. The old
   secret keeps working meanwhile.
2. Write the new secret to `myapps_googlesecret` or `myapps_githubsecret`
   with the commands above, **on the server**.
3. Sign in with that provider in a private window at
   `https://auth.finance-nl.com/realms/myapps/account/`. A failure shows
   up as `IDENTITY_PROVIDER_LOGIN_ERROR` in the events and as a WARN line
   in the Keycloak log.
4. Only then disable and delete the old secret at the provider.

If a secret leaked, delete it at the provider first and accept the outage
for that button until step 3 passes.

### Connecting a new app to this auth server

The checklist follows how `finance-tracker` was set up in stage 5: an app
whose server keeps the tokens (a backend-for-frontend or a server-rendered
web app) gets a confidential client. The commands carry Finance Tracker's
values; for a new app, change the variables at the top.

1. **Read what the app expects**, from its code, not its docs: the exact
   redirect URI and post-logout URI, the scopes it asks for, whether it
   sends PKCE S256, the audience it checks, which claim it reads roles from
   (`resource_access` of which client, or `realm_access`), the role names,
   and the claim it uses as the user id. Its local development must point
   at the dev stack (`http://localhost:8080`), never at production; if it
   points at production, fix the app rather than adding localhost URIs
   here.
2. **Back up**, **on the server**: `systemctl start pg-backup@auth.service`
   (it must exit 0; see "Run a backup now").
3. **Create the client, its role and the audience mapper**, **on the
   server** after signing in (see "Admin CLI"):

   ```bash
   app=finance-tracker
   app_name='Finance Tracker'
   base=https://app.finance-nl.com/
   callback=https://app.finance-nl.com/login/oauth2/code/keycloak
   logout_to=https://app.finance-nl.com/
   cid=$(kc create clients -r myapps -i -s clientId=$app -s "name=$app_name" \
     -s protocol=openid-connect -s publicClient=false -s clientAuthenticatorType=client-secret \
     -s standardFlowEnabled=true -s implicitFlowEnabled=false -s directAccessGrantsEnabled=false \
     -s serviceAccountsEnabled=false -s consentRequired=false -s fullScopeAllowed=false \
     -s frontchannelLogout=false -s baseUrl=$base \
     -s "redirectUris=[\"$callback\"]" -s 'webOrigins=[]' \
     -s 'attributes."pkce.code.challenge.method"=S256' \
     -s "attributes.\"post.logout.redirect.uris\"=$logout_to")
   echo "$cid"
   kc create clients/$cid/roles -r myapps -s name=user
   kc add-roles -r myapps --rname default-roles-myapps --cclientid $app --rolename user
   kc create clients/$cid/protocol-mappers/models -r myapps -s "name=$app audience" \
     -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
     -s "config.\"included.client.audience\"=$app" -s 'config."id.token.claim"=false' \
     -s 'config."access.token.claim"=true' -s 'config."introspection.token.claim"=true' \
     -s 'config."lightweight.claim"=false'
   kc get clients/$cid -r myapps --fields 'clientId,publicClient,standardFlowEnabled,directAccessGrantsEnabled,fullScopeAllowed,redirectUris,webOrigins,attributes(*),protocolMappers(name,config(*))'
   ```

   - One exact redirect URI per callback the app really has; no `/*`.
   - Web origins stay empty unless the browser itself calls Keycloak.
   - Full scope off, so its tokens carry only its own roles.
   - Skip the `add-roles` line if not every user should get the app: then
     assign the role per user (admin console → Users → the user → Role
     mapping → Assign role → Filter by clients).
   - Skip the mapper if the app checks no audience.
   - Keycloak generates the secret. Never read it with kcadm (always pass
     `--fields` when reading a client); copy it from the admin console
     (Clients → the client → Credentials) straight into the app's secret
     store when the app is deployed.
4. **Check a token**, **on the server**, in the same shell as step 3 (it
   set `cid`): an example access token for a test user (here the first
   user). It prints that user's email and name,
   so keep the output private:

   ```bash
   kc get clients/$cid/evaluate-scopes/generate-example-access-token -r myapps -q 'scope=openid profile email' -q userId=7df2283a-b1c7-4959-a9ac-e88f71859ba6
   ```

   `aud` must contain the app's audience, `azp` the client ID,
   `resource_access` the app's role, and the claims the app reads must be
   there.
5. **Check the authorization endpoint**, **on the laptop**. The challenge
   is the S256 example from RFC 7636; the requests leave `LOGIN_ERROR`
   events for the two rejected ones:

   ```bash
   auth=https://auth.finance-nl.com/realms/myapps/protocol/openid-connect/auth
   q='client_id=finance-tracker&response_type=code&scope=openid&state=test&nonce=test'
   ok='redirect_uri=https%3A%2F%2Fapp.finance-nl.com%2Flogin%2Foauth2%2Fcode%2Fkeycloak'
   bad='redirect_uri=https%3A%2F%2Fevil.example%2Flogin%2Foauth2%2Fcode%2Fkeycloak'
   pkce='code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256'
   curl -s -o /dev/null -w '%{http_code}\n' "$auth?$q&$ok&$pkce"    # 200: the login page
   curl -s -o /dev/null -w '%{http_code}\n' "$auth?$q&$bad&$pkce"   # 400: Invalid parameter: redirect_uri
   curl -s -o /dev/null -w '%{redirect_url}\n' "$auth?$q&$ok"       # back to the app with error=invalid_request: no PKCE
   ```

6. **Run the smoke test**, **on the laptop**: `deploy/smoke-test.sh`.
7. **Write it down**: a section for the client in this file (settings and
   why) and an entry in `change_log.mdx`.
8. **Once the app is deployed**, sign in through it end to end; the events
   show `LOGIN` and `CODE_TO_TOKEN` with the app's client ID.

**The public SPA variant**, for a future app that runs only in the browser
and holds the tokens itself:

- `publicClient` on, no secret. The realm's client policy
  `pkce-s256-public-clients` sets and enforces PKCE S256 on its own.
- Redirect URIs: the exact callback page (and silent-renew page, if the
  OIDC library uses one); web origins: the app's own origin, because the
  browser calls the token endpoint with CORS; the post-logout URI.
- The app keeps tokens in memory, not in `localStorage`; refresh-token
  rotation is already on in the realm.
- Its API gets a client of its own with every flow off, which holds the
  roles. The SPA client gets full scope off, a scope mapping to the API
  client's role (Client scopes → the dedicated scope → Scope → Assign
  role), and an audience mapper with Included Client Audience set to the
  API client.

### Hosting another project behind this Caddy

Caddy in this stack owns ports 80 and 443 and the certificates, so other
projects on this server get their HTTPS from it. Finance Tracker at
`https://app.finance-nl.com` is the example throughout: its code is cloned to
`/opt/finance-tracker` on the server, and its stack is the compose project
`finance-tracker-prod` in `/opt/finance-tracker/deploy/app`. A project
brings two things, both from its own repository and runbook:

- a site file, installed with `caddy-site install` as
  `/opt/caddy-sites/finance.caddy`. The Caddyfile imports every
  `/opt/caddy-sites/*.caddy`, mounted read-only at `/etc/caddy/sites`.
  Finance Tracker's is `deploy/finance.caddy` in its repository;
- the containers Caddy proxies to, attached to the Docker network `edge`
  under names that start with the project's name. Finance Tracker's are
  `finance-tracker-api` (its Spring backend) and `finance-tracker-web`
  (nginx with the built frontend).

The finance repository's `deploy/RUNBOOK.md` is the source of truth for how
Finance Tracker runs: its compose file, site file, deploys, updates and
backups. This section holds the rules every project follows here, and the
tools this repository provides (`caddy-site`, the network `edge`).

Rules:

- **No project puts files into `/opt/auth`.** Not a site block in the
  Caddyfile (`deploy/sync.sh` overwrites it on every deploy), not a
  `docker-compose.override.yml` or any other compose file (Docker Compose
  merges it into every command run there, so `sync.sh` refuses to deploy
  while one exists), not a volume for Caddy to mount. Settings of this
  stack, Keycloak's memory limit included, change only in `deploy/` of this
  repository.
- **Site files go live only through `caddy-site install` and leave only
  through `caddy-site remove`.** Never copy, edit or delete a file in
  `/opt/caddy-sites` directly. Caddy imports every `*.caddy` there, and one
  it can't read stops Caddy from starting at its next restart (a deploy,
  the automatic reboot at 04:00 UTC), which takes `auth.finance-nl.com` down
  too. `caddy-site` validates a file before it goes live, and `sync.sh`
  validates the Caddyfile with the site files before every deploy.
  `caddy-site` is `/usr/local/sbin/caddy-site` on the server, installed by
  `sync.sh` from [`deploy/caddy-site.sh`](deploy/caddy-site.sh).
- Caddy reaches other projects only over `edge` and mounts none of their
  files, so a project serves its static files from a container of its own.
- `sync.sh` creates `edge` and `/opt/caddy-sites` when they are missing and
  never writes into the directory. Nothing removes either of them.
- Keycloak and Postgres are not on `edge`. A project's backend reaches
  Keycloak at `https://auth.finance-nl.com`, through the server's public
  address, like any other client.
- **Names on `edge`:** every container on `edge` is named with its project's
  name as a prefix, `finance-` for Finance Tracker (its containers there are
  `finance-tracker-api` and `finance-tracker-web`), and site files proxy
  only to such names. The prefix `auth-` is reserved for this stack.
  Docker's DNS answers a name from every network a container is on, so a
  container on `edge` can take over a name that Caddy uses. Caddy reaches
  Keycloak as `auth-keycloak`, an alias on this stack's own network only, so
  a container on `edge` named `keycloak` gets none of its traffic, whichever
  network Docker checks first (tested 2026-09-27). One named `auth-keycloak`
  on `edge` would get it as soon as Docker checked `edge` first; Docker
  orders the networks by name, and today `auth_default` comes first. The
  reserved prefix prevents that case.
- Every container on `edge` can reach Caddy and every other container on
  it. Attach only the containers Caddy proxies to, never a database, and
  only projects of this server's owner.
- A site file holds only site blocks for the project's own hostnames: no
  global options block, no `auth.finance-nl.com`, no catch-all address such
  as `:443` or `https://`. Point the hostname's DNS record at the server,
  and give it the two CAA records (see "DNS"), before installing the file,
  because Caddy requests the certificate as soon as it loads the site.

#### Put a container on `edge`

In the project's own compose file, give each container Caddy proxies to a
name with the project's prefix, and put it on `edge`. Finance Tracker does
it with a fixed `container_name` (its `deploy/app/docker-compose.yml`,
abridged): the backend joins its stack's network and `edge`, the frontend
only `edge`, and the database `finance-tracker-postgres` stays off `edge`.

```yaml
services:
  api:
    container_name: finance-tracker-api
    networks: [default, edge]
  web:
    container_name: finance-tracker-web
    networks: [edge]

networks:
  edge:
    external: true
```

An alias on `edge` (`networks: {edge: {aliases: [...]}}`) works too, but a
container name is unique on the whole host, an alias is not. Compose also
gives each container its service name (`api`, `web`) on `edge`, which
another project may use too, so a site file uses only the prefixed names.
After `docker compose up -d` in the project's directory, **on the server**:

```bash
docker network inspect edge -f '{{range .Containers}}{{.Name}} {{end}}'
cd /opt/auth && for n in finance-tracker-api finance-tracker-web; do echo "$n: $(docker compose exec -T caddy getent ahostsv4 $n </dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"; done
```

The first command lists `auth-caddy-1`, `finance-tracker-api` and
`finance-tracker-web`, and no database. The second must print exactly one
address per name: two mean another container uses the name; none means the
container is not on `edge` or not running. Finance Tracker's runbook runs
the same checks in step 6, "Build and start the app".

#### Add or change a site

A site file holds complete site blocks for the project's hostnames and
proxies to its prefixed names on `edge`. Its name is the site's name plus
`.caddy`, in lowercase letters, digits and dashes: `finance.caddy` for the
site `finance`. The file lives in the project's repository. Finance
Tracker's is `deploy/finance.caddy` in its repository: it sends `/api`,
`/api/*`, `/oauth2/*`, `/login/oauth2/*` and `/logout` to
`finance-tracker-api:8080` and every other path to
`finance-tracker-web:8080`, and sets the app's own response headers (HSTS,
CSP and others). Its runbook checks the file on the laptop with
`deploy/check-site.sh`, the way `caddy-site` will, before it is committed.
Sites imported this way have no access log unless the file adds a `log`
block like the one in `deploy/Caddyfile`.

**On the server**, copy the file from the project's clone to `/root` under
the site's name, then install it. For Finance Tracker (its runbook does
this in step 7, "Put the site live", and in "Update the app" when the file
changed):

```bash
cp /opt/finance-tracker/deploy/finance.caddy /root/finance.caddy
caddy-site install /root/finance.caddy
```

`caddy-site install`:

1. validates the deployed `/opt/auth/Caddyfile` with the site files in
   `/opt/caddy-sites` and the new file (in place of an older
   `finance.caddy`), in a throwaway container of the running Caddy's image
   with its environment and no network;
2. only if that is valid, puts exactly the validated file in place as
   `/opt/caddy-sites/finance.caddy` (owner root, mode 644) with a rename, so
   Caddy never reads a half-written file, and reloads Caddy;
3. if Caddy rejects it at the reload, puts the previous version back (or
   removes the new file) and reloads again.

`/root/finance.caddy` stays where it is. A version it replaced is kept in
`/root/caddy-sites-removed/`, in a directory named by UTC time such as
`20260927T183443Z`. What it prints, with its exit code:

- `✅ /opt/caddy-sites/finance.caddy installed and live` (or `replaced and
  live. The previous version is kept as …`): exit 0.
- Caddy's error with the file and line, such as `Error: adapting config
  using caddyfile: /etc/caddy/sites/finance.caddy:4: unrecognized
  directive: …`, then `❌ /root/finance.caddy is not valid: nothing was
  changed`: exit 1. Fix `/root/finance.caddy` and run the install again.
- `Reload failed: restoring the previous finance.caddy` and `❌ Caddy
  rejected finance.caddy at reload`: exit 1. The syntax was valid, but Caddy
  can't run it (tested with a site bound to an address the server doesn't
  have). `/opt/caddy-sites` is as before and Caddy keeps its configuration.
- It changes nothing and says why if the caddy container isn't running, or
  if the running Caddy still has an older `/opt/auth/Caddyfile` (then
  restart it first: `cd /opt/auth && docker compose restart caddy`).

To change a site later, change the file in the project's repository, bring
the server's clone up to date, and copy and install it again as above. For
Finance Tracker, its runbook's "Change the site file" and "Update the app"
cover this. Editing `/root/finance.caddy` directly would leave the live site
different from its repository.

Check the result. **On the server**, Caddy's messages since the install
(for a new hostname, a `certificate obtained successfully` line for
`app.finance-nl.com` within a minute, and no `error` lines):

```bash
cd /opt/auth && docker compose logs --since 10m caddy | grep -v '"http.log.access' | grep -E 'error|app.finance-nl.com'
```

**On the laptop**, the site answers and `auth.finance-nl.com` still passes
the smoke test (`== Summary: 11 ok, 0 fail ==`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://app.finance-nl.com/
deploy/smoke-test.sh
```

#### Remove a site

**On the server**:

```bash
caddy-site remove finance
```

It moves `/opt/caddy-sites/finance.caddy` into a new directory under
`/root/caddy-sites-removed/` (named by UTC time) and reloads Caddy; it
prints `✅ Site finance removed. The file is kept as …`. If Caddy rejected
the configuration without the file, it puts the file back and says so.
**On the laptop**,
`curl -s -o /dev/null -w '%{http_code}\n' https://app.finance-nl.com/` now
prints `000`: Caddy no longer has a certificate for the name. Then take the
project's containers off `edge` (in its own compose file, or by stopping the
project the way its runbook says; never `docker compose down -v`, which
deletes its database) and remove the DNS record. The old certificate stays
in `auth_caddy_data` until it expires;
Caddy no longer renews it. Leave `edge` and `/opt/caddy-sites` in place.

To switch a site off for a while instead, run `caddy-site remove finance`
**on the server**, and later put back the newest kept copy, also **on the
server**:

```bash
caddy-site install "$(ls -1 /root/caddy-sites-removed/*/finance.caddy | tail -1)"
```

### Watch registrations and events

User events are kept for 30 days. The quickest view is the admin console
(realm `myapps` → Events → User events, filter by event type). The event
details include the user's email address and IP. Types worth knowing in
Keycloak 26:

| Event type                                                      | Meaning                                                                                                                                                     |
|-----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `REGISTER`, `REGISTER_ERROR`                                    | self-registration                                                                                                                                           |
| `SEND_VERIFY_EMAIL`, `VERIFY_EMAIL`                             | confirmation email sent, address confirmed                                                                                                                  |
| `SEND_RESET_PASSWORD`                                           | "Forgot password" email sent                                                                                                                                |
| `UPDATE_CREDENTIAL`, `UPDATE_PASSWORD`                          | password set or changed (both are logged); `_ERROR` with `password_rejected` when the policy refuses it                                                     |
| `LOGIN`, `LOGIN_ERROR`                                          | sign-ins and failed sign-ins                                                                                                                                |
| `USER_DISABLED_BY_TEMPORARY_LOCKOUT`                            | brute-force lockout                                                                                                                                         |
| `IDENTITY_PROVIDER_FIRST_LOGIN`                                 | first sign-in with a Google or GitHub identity that no user here has yet (detail `identity_provider`)                                                       |
| `REGISTER` with `register_method` = `broker`                    | a new user created by such a first sign-in                                                                                                                  |
| `SEND_IDENTITY_PROVIDER_LINK`, `IDENTITY_PROVIDER_LINK_ACCOUNT` | the first sign-in matched an existing user's email: link email sent, link used                                                                              |
| `FEDERATED_IDENTITY_LINK`, `FEDERATED_IDENTITY_LINK_ERROR`      | an identity linked to a user (first sign-in or account console); the error means it already belongs to another user                                         |
| `IDENTITY_PROVIDER_LOGIN_ERROR`                                 | Google or GitHub refused the sign-in or the code exchange, for example a wrong client secret                                                                |
| `LOGIN` with detail `identity_provider`                         | a sign-in through Google or GitHub by a user who already has that identity linked; Keycloak 26 logs no `IDENTITY_PROVIDER_LOGIN` event for a successful one |

In the test on 2026-09-27 a password reset showed up as
`SEND_RESET_PASSWORD` followed by `UPDATE_PASSWORD` and `UPDATE_CREDENTIAL`;
there was no `RESET_PASSWORD` event. In stage 5, linking Google to an
existing account showed up as `IDENTITY_PROVIDER_FIRST_LOGIN`,
`SEND_IDENTITY_PROVIDER_LINK`, then (after the email link)
`IDENTITY_PROVIDER_LINK_ACCOUNT`, `FEDERATED_IDENTITY_LINK` and `LOGIN` with
the detail `identity_provider` = `google`. A new user from GitHub showed up
as `IDENTITY_PROVIDER_FIRST_LOGIN`, `REGISTER` and `SEND_VERIFY_EMAIL`. Later
sign-ins with Google or GitHub showed up only as `LOGIN` with the details
`identity_provider` and `identity_provider_identity`; the admin console
can't filter by a detail, but `--fields time,details` on `type=LOGIN` in
kcadm (below) shows which sign-ins came through a provider.

With kcadm, **on the server** after signing in (see "Admin CLI"); `time` is
in milliseconds since 1970:

```bash
kc get events -r myapps -q type=REGISTER -q dateFrom=2026-09-27 -q max=1000 --fields time --format csv --noquotes | wc -l
kc get events -r myapps -q type=REGISTER -q max=20 --fields time,ipAddress,details
kc get events -r myapps -q type=LOGIN_ERROR -q max=20 --fields time,error,ipAddress
kc get events -r myapps -q type=LOGIN -q max=20 --fields time,details
kc get events -r myapps -q type=IDENTITY_PROVIDER_FIRST_LOGIN -q max=20 --fields time,ipAddress,details
kc get events -r myapps -q type=IDENTITY_PROVIDER_LOGIN_ERROR -q max=20 --fields time,error,details
kc get admin-events -r myapps -q max=20 --fields time,operationType,resourceType,resourcePath
```

Admin events are kept for 90 days.

The first line counts registrations since 2026-09-27. Error events also go
to the Keycloak log, **on the server**:

```bash
cd /opt/auth && docker compose logs --since 24h keycloak | grep -E 'type="(REGISTER_ERROR|LOGIN_ERROR)"'
```

**Spam registrations:** if `REGISTER` events pile up from a few addresses,
or many new accounts never reach `VERIFY_EMAIL`, add a captcha to the
registration flow (Authentication → `registration` has a disabled
reCAPTCHA step) and delete the junk accounts.

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
| Settings for the `finance` database    | on the server: `/etc/pg-backup/finance.conf` (from the finance repository; see "The finance database")  |
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
deploy/backup/install.sh server   # scripts, units and every deploy/backup/*.conf; enables pg-backup@auth.timer; leaves finance.conf alone
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
  -c 'CREATE DATABASE keycloak OWNER keycloak' </dev/null

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
  -c 'ALTER DATABASE keycloak_before_restore RENAME TO keycloak' </dev/null
docker compose start keycloak
systemctl start pg-backup@auth.timer
```

Once the restored state has worked for a few days, **on the server**:

```bash
cd /opt/auth && docker compose exec -T postgres psql -X -U keycloak -d postgres -c 'DROP DATABASE keycloak_before_restore' </dev/null
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

#### The finance database

Finance Tracker's own Postgres (container `finance-tracker-postgres`, compose
project `finance-tracker-prod`) is backed up by the same `pg-backup` and
`pg-restore-test`, as the instance `finance`: timer
`pg-backup@finance.timer`, dumps in `/var/backups/pg/finance/`, settings in
`/etc/pg-backup/finance.conf`. That settings file belongs to the finance
repository, not this one: it is `deploy/pg-backup/finance.conf` there
(`COMPOSE_DIR=/opt/finance-tracker/deploy/app`, `SERVICE=postgres`,
database and user `finance`, and `CHECK_*` lines that fit its schema).
Its runbook, `deploy/RUNBOOK.md`, installs it and enables the timer in
step 9, "Backups", and covers its restore test and its restore from a
dump. Change it there, never here.

`deploy/backup/install.sh server` installs only this repository's
`deploy/backup/*.conf` (today only `auth.conf`) and enables only their
timers: it never overwrites or removes `/etc/pg-backup/finance.conf` and
leaves `pg-backup@finance.timer` alone. So never add a `finance.conf` to
`deploy/backup/`. The scripts it installs, `/usr/local/sbin/pg-backup` and
`/usr/local/sbin/pg-restore-test`, serve both instances: after changing
them, run the restore test for both, **on the server**:

```bash
pg-restore-test auth
pg-restore-test finance
```

Both end with `PASS`. The laptop's pull already copies
`/var/backups/pg/finance/` and checks its freshness too.

Another project's database follows the same pattern: a `NAME.conf` in the
format of [`deploy/backup/auth.conf`](deploy/backup/auth.conf), kept in that
project's repository and installed by its runbook as
`/etc/pg-backup/NAME.conf` (root, mode 600), with
`systemctl enable --now pg-backup@NAME.timer`. `pg_dump` runs inside the
container over the local socket, which the official `postgres` image allows
without a password.

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
restore test (**on the server**: `pg-restore-test auth` and
`pg-restore-test finance`).

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
