#!/usr/bin/env bash
# External smoke test for Keycloak in production. Run it from YOUR OWN machine:
#   deploy/smoke-test.sh
# Requires: curl, jq, python3, nc. Settings are read from smoke.env next to the
# script (gitignored): DOMAIN, REALM, CLIENT_ID and CLIENT_SECRET of the
# confidential client "smoke-test" in the realm. That client can only use
# client_credentials and its service account has no roles, so the test needs
# no user account and its secret opens nothing. See PRODUCTION.md, "Run the smoke test".
set -uo pipefail
cd "$(dirname "$0")"
[ -f smoke.env ] && source smoke.env

: "${DOMAIN:?DOMAIN is not set (smoke.env)}"
: "${CLIENT_ID:?}" "${CLIENT_SECRET:?}"
REALM="${REALM:-myapps}"
BASE="https://$DOMAIN"
TOKEN_URL="$BASE/realms/$REALM/protocol/openid-connect/token"

pass=0; fail=0
ok() { echo "✅ $1"; pass=$((pass+1)); }
ko() { echo "❌ $1"; fail=$((fail+1)); }

echo "== Keycloak smoke test: $BASE (realm: $REALM, client: $CLIENT_ID) =="

# 1. HTTP must redirect to HTTPS
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$DOMAIN/")
[[ "$code" =~ ^30[1278]$ ]] && ok "HTTP -> HTTPS redirect ($code)" || ko "no HTTP -> HTTPS redirect (code $code)"

# 2. Valid TLS certificate (curl fails on an invalid one by default)
if curl -sS -o /dev/null --max-time 10 "$BASE/realms/$REALM"; then
  ok "HTTPS and certificate are valid, realm '$REALM' responds"
else
  ko "HTTPS/certificate or realm is unavailable"
fi

# 3. The issuer in discovery must match the public URL — the main indicator of a correct proxy setup
issuer=$(curl -s --max-time 10 "$BASE/realms/$REALM/.well-known/openid-configuration" | jq -r '.issuer // empty')
[ "$issuer" = "$BASE/realms/$REALM" ] && ok "issuer = $issuer" || ko "issuer = '$issuer', expected '$BASE/realms/$REALM'"

# 4. JWKS serves the signing keys (Spring downloads them to verify tokens)
nkeys=$(curl -s --max-time 10 "$BASE/realms/$REALM/protocol/openid-connect/certs" | jq '.keys | length' 2>/dev/null)
[ "${nkeys:-0}" -gt 0 ] 2>/dev/null && ok "JWKS: $nkeys keys" || ko "JWKS is empty or unavailable"

# 5. Obtaining a token with client_credentials
resp=$(curl -s --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET")
at=$(echo "$resp" | jq -r '.access_token // empty' 2>/dev/null)
if [ -n "$at" ]; then
  ok "access_token obtained (client_credentials)"
  # 6. iss inside the token matches the issuer (otherwise Spring will reject the token)
  tok_iss=$(python3 -c "import sys,base64,json;s=sys.argv[1].split('.')[1];s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s))['iss'])" "$at")
  [ "$tok_iss" = "$BASE/realms/$REALM" ] && ok "iss in token = $tok_iss" || ko "iss in token = '$tok_iss'"
else
  ko "token not obtained: $(echo "$resp" | jq -c '{error, error_description}' 2>/dev/null || echo "$resp" | head -c 300)"
fi

# 7. Negative checks.
# Wrong client secret -> 401 invalid_client
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="wrong-secret")
[ "$code" = "401" ] && ok "wrong client_secret rejected (401)" || ko "wrong client_secret: expected 401, got $code"

# The password grant is off for this client: Keycloak rejects it with
# unauthorized_client before it looks at the (made-up) username and password.
# Newer Keycloak versions answer 400, as RFC 6749 requires; accept 401 too and check the body.
resp=$(curl -s -w '\n%{http_code}' --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
  -d username="smoke-test-no-such-user" -d password="not-a-password")
code=$(tail -n1 <<<"$resp")
err=$(head -n1 <<<"$resp" | jq -r '.error // empty' 2>/dev/null)
if [[ "$code" =~ ^40[01]$ && "$err" == "unauthorized_client" ]]; then
  ok "password grant rejected for $CLIENT_ID ($code $err)"
else
  ko "password grant: expected 400/401 unauthorized_client, got $code '$err'"
fi

# 8. Internal ports must not be visible from the internet
if command -v nc >/dev/null; then
  for port in 5432 8080 9000; do
    if nc -z -w 3 "$DOMAIN" "$port" 2>/dev/null; then
      ko "port $port is OPEN from outside — close it"
    else
      ok "port $port is closed from outside"
    fi
  done
else
  echo "⚠️  nc not found — skipping the port check"
fi

echo "== Summary: $pass ok, $fail fail =="
[ "$fail" -eq 0 ]
