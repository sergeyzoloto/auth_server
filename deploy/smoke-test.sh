#!/usr/bin/env bash
# External smoke test for Keycloak in production. Run it from YOUR OWN machine:
#   ./smoke-test.sh
# Requires: curl, jq, python3, nc. Settings are read from smoke.env next to the script.
set -uo pipefail
cd "$(dirname "$0")"
[ -f smoke.env ] && source smoke.env

: "${DOMAIN:?DOMAIN is not set (smoke.env)}"
: "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${TEST_USER:?}" "${TEST_PASSWORD:?}"
REALM="${REALM:-myapps}"
BASE="https://$DOMAIN"
TOKEN_URL="$BASE/realms/$REALM/protocol/openid-connect/token"

pass=0; fail=0
ok() { echo "✅ $1"; pass=$((pass+1)); }
ko() { echo "❌ $1"; fail=$((fail+1)); }

echo "== Keycloak smoke test: $BASE (realm: $REALM) =="

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

# 5. Obtaining a token
resp=$(curl -s --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
  -d username="$TEST_USER" -d password="$TEST_PASSWORD")
at=$(echo "$resp" | jq -r '.access_token // empty' 2>/dev/null)
if [ -n "$at" ]; then
  ok "access_token obtained"
  # 6. iss inside the token matches the issuer (otherwise Spring will reject the token)
  tok_iss=$(python3 -c "import sys,base64,json;s=sys.argv[1].split('.')[1];s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s))['iss'])" "$at")
  [ "$tok_iss" = "$BASE/realms/$REALM" ] && ok "iss in token = $tok_iss" || ko "iss in token = '$tok_iss'"
else
  ko "token not obtained: $(echo "$resp" | head -c 300)"
fi

# 7. Negative checks.
# Wrong password -> invalid_grant error. Newer Keycloak versions return it with status 400
# (as RFC 6749 requires), older ones with 401, so we accept both and check the response body.
resp=$(curl -s -w '\n%{http_code}' --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
  -d username="$TEST_USER" -d password="definitely-wrong-password")
code=$(tail -n1 <<<"$resp")
err=$(head -n1 <<<"$resp" | jq -r '.error // empty' 2>/dev/null)
if [[ "$code" =~ ^40[01]$ && "$err" == "invalid_grant" ]]; then
  ok "wrong password rejected ($code invalid_grant)"
else
  ko "wrong password: expected 400/401 invalid_grant, got $code '$err'"
fi

# Wrong client secret -> 401 invalid_client

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id="$CLIENT_ID" -d client_secret="wrong-secret" \
  -d username="$TEST_USER" -d password="$TEST_PASSWORD")
[ "$code" = "401" ] && ok "wrong client_secret rejected (401)" || ko "wrong secret: expected 401, got $code"

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
