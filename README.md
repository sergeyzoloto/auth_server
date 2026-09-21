# Reusable Keycloak auth server (Docker)

One Keycloak container, backed by Postgres, pre-loaded with a single realm and
three example clients (`shop-api`, `blog-api`, `admin-app`) — the setup from
the realm/client diagram earlier in this conversation. Any Spring Boot
service just points at this realm's issuer URI and trusts its tokens; no
per-project auth code.

## Prerequisites
- Docker and Docker Compose v2 (`docker compose version`)
- `curl` and `jq` for the verification steps below (`jq` is optional but makes step 3 much shorter)

## Layout
```
keycloak-auth-server/
├── docker-compose.yml         # Keycloak + Postgres
├── realm-export.json          # realm, clients, roles, one test user — imported on first boot
└── spring-client-example/
    ├── application.yml        # points a Spring service at this realm
    └── SecurityConfig.java    # maps Keycloak roles into Spring authorities
```

## 1. Start the stack
```bash
docker compose up -d
docker compose logs -f keycloak
```
Wait for `Imported realm myapps from file ...` followed by the server
actually starting. First boot typically takes 20-40s while Postgres
initializes and the realm imports. `--import-realm` only imports into a
*fresh* database — once the `myapps` realm exists, Keycloak treats it as
live data and skips re-importing on later restarts, so editing
`realm-export.json` later won't retroactively change a running realm (see
step 5 for how to apply changes).

## 2. Confirm it came up right
Open `http://localhost:8080`, sign in with `admin` / `admin_dev_password`,
and check: realm **myapps** exists, Clients lists `shop-api`, `blog-api`,
`admin-app`, and Users lists `testuser`.

## 3. Get a real token (proves the whole chain end-to-end)
```bash
curl -s -X POST http://localhost:8080/realms/myapps/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=shop-api \
  -d client_secret=shop-api-secret \
  -d username=testuser \
  -d password=test1234 | jq -r .access_token
```
Copy the token and inspect its payload to see the role claims Spring will read:
```bash
echo "<paste the token here>" | cut -d. -f2 | python3 -c "
import sys, base64, json
s = sys.stdin.read().strip()
s += '=' * (-len(s) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(s)), indent=2))
"
```
You should see `"realm_access": {"roles": ["user", ...]}` and
`"resource_access": {"shop-api": {"roles": ["user"]}}` — exactly the claims
`SecurityConfig.java` reads.

## 4. Wire up a Spring Boot resource server
1. Add the dependency `org.springframework.boot:spring-boot-starter-oauth2-resource-server`.
2. Copy the block from `spring-client-example/application.yml` into that service's config.
3. Copy `spring-client-example/SecurityConfig.java` into the service and set
   `CLIENT_ID` to that service's client id (`shop-api`, `blog-api`, or `admin-app`).
4. Call the API with `Authorization: Bearer <token from step 3>` —
   `@PreAuthorize("hasRole('USER')")` now works.

Services running in the same Docker network as Keycloak should use
`http://keycloak:8080/realms/myapps` as the issuer, not `localhost`.

## 5. Adding a fourth project, or changing a client
Edit `realm-export.json`: copy one of the three client blocks in `clients`
(change `clientId` and `secret`), and add a matching entry under
`roles.client` for its `user`/`admin` roles — client roles live in the
realm-level `roles.client` map, *not* inside the client object, or the
import fails with `Unrecognized field "roles"`. Then force a fresh import:
```bash
docker compose down -v && docker compose up -d
```
`-v` drops the Postgres volume so the realm is "new" again and gets
re-imported — but it also discards any changes made by hand in the admin
console. On a system with real data, add the client through the Admin
Console or the Admin REST API instead of wiping the volume.

## Before this touches real production
This is deliberately a local/dev setup: `start-dev` skips hostname and TLS
checks and isn't meant for the open internet. Before exposing it beyond
your machine:
- Switch `start-dev` to `start`, set `KC_HOSTNAME`, and terminate real TLS
  (either Keycloak's own `KC_HTTPS_CERTIFICATE_FILE` /
  `KC_HTTPS_CERTIFICATE_KEY_FILE`, or a reverse proxy in front of it).
- Replace every password and secret used here (`admin_dev_password`,
  `keycloak_dev_password`, and each client `secret`) with generated values
  kept out of git — Docker secrets or a gitignored env file, not hardcoded
  strings.
- Keep `realm-export.json` in version control for its *structure* (clients,
  roles), but strip the real secrets and drop the `testuser` account once
  this is more than a personal sandbox.
