# Production deployment

The production stack is two containers on one host — Keycloak and Caddy —
with the database outside it, in managed Postgres (Supabase below, but any
Postgres works). The dev stack (`docker-compose.yml`, `realm-export.json`) stays
for local work; never deploy it: it has a test user and fixed client secrets.

| Where            | What it holds                                      | If it's lost                          |
|------------------|----------------------------------------------------|---------------------------------------|
| Host: `keycloak` | nothing                                            | recreate the container                |
| Host: `caddy`    | TLS certificates                                   | re-issued automatically               |
| Managed Postgres | users, sessions, clients, signing keys, events     | everything — this is what you back up |

## Prerequisites
- A Linux host with Docker 27+ and Compose v2, ports 80 and 443 open to the
  internet, at least 2 vCPU / 4 GB RAM (Keycloak is capped at 2 GB). IPv6 on
  the host is recommended: it allows the direct database connection below.
- A DNS record for the auth hostname (e.g. `auth.example.com`) pointing at
  the host.
- A Supabase project on a paid plan, in a region close to the host. Every
  login makes several database round-trips, and the Free plan has no
  automatic backups — not acceptable for the database behind every login.

## 1. Prepare the database
1. Supabase SQL Editor:
   ```sql
   create schema keycloak;
   ```
   Keycloak creates its tables but not the schema. Don't use `public`: on
   Supabase it's exposed through the Data API. Don't add `keycloak` to
   *API settings → Exposed schemas* either.
2. Open *Connect* and pick the connection:
   - **Direct connection** (preferred): host `db.<project-ref>.supabase.co`,
     user `postgres`. Nothing sits between Keycloak and the database, but the
     address is IPv6-only, so the host needs working IPv6. Check on the host:
     ```bash
     timeout 5 bash -c 'exec 3<>/dev/tcp/db.<project-ref>.supabase.co/5432' && echo ok
     ```
     The compose network is dual-stack, so containers use the host's IPv6.
   - **Session pooler**, if that check fails: host
     `aws-<n>-<region>.pooler.supabase.com`, port 5432, user
     `postgres.<project-ref>`. It is reachable over IPv4.

   Never the Transaction pooler (port 6543): Keycloak keeps its own
   connection pool and relies on prepared statements.

## 2. Configure
```bash
cp .env.example .env && chmod 600 .env
```
Fill in every value; `.env.example` explains each one. Generate passwords with
`openssl rand -base64 24`.

Then edit `realm-prod.json`: rename the three example clients to your
projects and replace the `example.com` URLs in `redirectUris` and
`post.logout.redirect.uris` with your apps' real ones. This must print
nothing:
```bash
grep -n example.com realm-prod.json
```
The realm file is read once, on the very first start. From then on the
database is the source of truth: change clients, roles and settings in the
admin console or through the Admin REST API. Editing the file and
restarting does nothing.

## 3. Start
```bash
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml logs -f keycloak
```
The first start creates about 100 tables over the network, so give it a few
minutes. Wait for `Realm 'myapps' imported` and `started in`. Caddy starts
once Keycloak is healthy and fetches the Let's Encrypt certificate.

## 4. Replace the temporary admin
From an address in `ADMIN_ALLOWED_IPS`, open `https://<AUTH_HOSTNAME>/admin/`
and sign in with the temporary admin from `.env`. Then:
1. In the **master** realm, create a permanent admin user, give it the
   `admin` realm role, and add the *Configure OTP* required action.
2. Sign in as that user (enrolling OTP), then delete the temporary admin.

From now on the `KC_BOOTSTRAP_ADMIN_*` values are ignored, but leave them in
`.env`: Keycloak refuses to start when they're present but empty, and compose
refuses to start when they're missing.

## 5. Connect the projects
Client secrets aren't in any file — Keycloak generated them during import.
Each project needs:
- **Issuer URL**: `https://<AUTH_HOSTNAME>/realms/myapps`
- **Client ID**: its client from `realm-prod.json`
- **Client secret**: *Clients → <client> → Credentials*

Services validate tokens against the public issuer URL, including services on
the same host: the `iss` claim is always the public hostname.

How apps get tokens:
- **Users log in** with the authorization code flow (redirect to the login
  page). The password grant used in the README's curl example is disabled here.
- **Services call each other** with client credentials:
  ```bash
  curl -s -X POST https://<AUTH_HOSTNAME>/realms/myapps/protocol/openid-connect/token \
    -d grant_type=client_credentials -d client_id=shop-api -d client_secret=<secret>
  ```

## 6. Verify
```bash
H=https://<AUTH_HOSTNAME>
curl -s $H/realms/myapps/.well-known/openid-configuration | jq -r .issuer   # https://<AUTH_HOSTNAME>/realms/myapps
curl -s -o /dev/null -w '%{http_code}\n' $H/admin/                          # 404 from outside ADMIN_ALLOWED_IPS
```
Plus the client-credentials call above, which should return an `access_token`.

### Check that data reaches the database
Run these read-only queries in the Supabase SQL Editor before and after the
test below.

```sql
-- 1. Per realm: people (service accounts excluded), active sessions, stored events
select r.name as realm,
  (select count(*) from keycloak.user_entity u
    where u.realm_id = r.id and u.service_account_client_link is null) as users,
  (select count(*) from keycloak.offline_user_session s
    where s.realm_id = r.id and s.offline_flag = '0') as active_sessions,
  (select count(*) from keycloak.event_entity e where e.realm_id = r.id) as events
from keycloak.realm r
order by r.name;
```

```sql
-- 2. Users in myapps and their active sessions
select u.username, u.email,
       to_timestamp(u.created_timestamp / 1000.0) as created,
       count(s.user_session_id) as active_sessions,
       to_timestamp(max(s.last_session_refresh)) as last_seen
from keycloak.user_entity u
join keycloak.realm r on r.id = u.realm_id
left join keycloak.offline_user_session s
       on s.user_id = u.id and s.offline_flag = '0'
where r.name = 'myapps' and u.service_account_client_link is null
group by u.id
order by u.created_timestamp desc;
```

```sql
-- 3. Latest login events in myapps
select to_timestamp(e.event_time / 1000.0) as at, e.type, e.client_id,
       u.username, e.ip_address, e.error
from keycloak.event_entity e
join keycloak.realm r on r.id = e.realm_id
left join keycloak.user_entity u on u.id = e.user_id
where r.name = 'myapps'
order by e.event_time desc
limit 20;
```

1. In the admin console, open realm `myapps` → *Users → Add user*. Fill in
   email, first and last name, or the first login asks the user to complete
   the profile. Under *Credentials*, set a password of 12+ characters with
   *Temporary* off. **Query 2** now lists the user.
2. In a private browser window, sign in as that user at
   `https://<AUTH_HOSTNAME>/realms/myapps/account`. **Query 1** shows one
   more session and event; **query 3** shows `LOGIN` from `account-console`.
3. In another private window, try a wrong password. **Query 3** shows
   `LOGIN_ERROR` with `invalid_user_credentials`.
4. Recreate Keycloak:
   `docker compose -f docker-compose.prod.yml up -d --force-recreate keycloak`.
   The user and the session from step 2 survive. The new container holds
   nothing locally, so both came from the database.
5. Delete the user. **Query 2** is empty and the session is gone. Its events
   stay, with an empty username, until they expire after 30 days.

Reading the results:
- `user_entity` also holds `service-account-<client>` rows. These are the
  clients' own identities for client credentials, not people; the queries
  leave them out.
- Sessions in `master` are admin console sign-ins. `master` stores no
  events; only `myapps` has them enabled.
- `ip_address` is the client address Caddy saw. Requests from the host
  itself (e.g. through `localhost`) show the Docker gateway.
- Supabase shows the times in UTC.
- Read these tables freely, but never edit them: Keycloak caches realms,
  clients and users in memory and won't notice direct changes. Make changes
  in the admin console or through the Admin REST API.

## What the setup enforces
- **Exposed paths**: `/realms/*`, `/resources/*`, `/.well-known/*` and
  `/robots.txt`. The admin console (`/admin`) and the `master` realm are
  reachable only from `ADMIN_ALLOWED_IPS`. Everything else, including health
  and metrics, returns 404.
- **Keycloak isn't published directly**: only Caddy listens on the host, so
  the `X-Forwarded-*` headers Keycloak trusts always come from Caddy.
- **Real client addresses**: the compose network is dual-stack. On an
  IPv4-only Docker network, every client connecting over IPv6 reaches Caddy
  as the Docker gateway (`172.x.0.1`). That silently breaks
  `ADMIN_ALLOWED_IPS`, and the addresses in Keycloak's login events.
- **Realm**: brute-force lockout after 10 failed logins (waits growing up to
  15 min), passwords of at least 12 characters that differ from the username
  and email, self-registration off, login events kept for 30 days.
- **Clients**: authorization code and client credentials only; redirects are
  accepted only to the listed URLs.
- **Operations**: container logs are rotated (5 × 10 MB); a healthcheck
  gates Caddy on Keycloak being ready.

## Operations
- **Upgrade Keycloak**: bump `KEYCLOAK_VERSION` in the `Dockerfile`, then
  `docker compose -f docker-compose.prod.yml up -d --build`. Take a database
  backup first: Keycloak migrates the schema on start and can't migrate back.
- **Rotate a client secret**: *Clients → <client> → Credentials →
  Regenerate*, then update that project.
- **Backups**: Supabase Pro keeps daily backups for 7 days; point-in-time
  recovery is an add-on (needs at least the Small compute size). Test a
  restore before you depend on it.
- **Move to another host**: copy the repository and `.env`, run
  `up -d --build`, repoint DNS. There's nothing else to migrate.

## Troubleshooting
- `read and write permissions for the 'keycloak.databasechangelog' table`:
  the `keycloak` schema doesn't exist (step 1).
- `password authentication failed`: the username is `postgres` for the
  direct connection but `postgres.<project-ref>` for the Session pooler. If
  the password contains `$`, wrap it in single quotes in `.env`.
- **Timeouts or `Network is unreachable` to `db.<project-ref>.supabase.co`**:
  the host has no working IPv6. Use the Session pooler.
- **Admin console returns 404 from an allowed address**: the browser connects
  over the other IP version. Most often only the IPv4 address is listed
  while the browser uses IPv6. Check `curl -4 ifconfig.me` and
  `curl -6 ifconfig.me`, and list both.
- **No certificate**: Let's Encrypt validates over ports 80/443, so the DNS
  record must already point at this host and both ports must be open.

## Not covered yet
- **Email (SMTP)**: *Realm settings → Email*. Without it, password reset and
  email verification can't work, so password reset is disabled for now.
- **High availability**: this is one Keycloak instance. If the host goes
  down, new logins and token refreshes stop for every project. Access tokens
  already issued keep working until they expire (5 minutes), because services
  validate them locally with cached keys. Two or more instances need to reach
  each other on the JGroups port (7800) — a separate setup.
- **Verifying the database certificate**: `sslmode=require` encrypts the
  connection but doesn't check the server's identity. To check it, download
  the CA certificate from Supabase (*Database settings → SSL Configuration*),
  mount it into the Keycloak service
  (`- ./db-ca.crt:/opt/keycloak/conf/db-ca.crt:ro`), and set
  `DB_JDBC_PARAMS=sslmode=verify-full&sslrootcert=/opt/keycloak/conf/db-ca.crt`.
- **Monitoring**: metrics are enabled on the management port (9000) inside
  the compose network, but nothing collects them yet.
