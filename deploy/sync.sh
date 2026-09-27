#!/usr/bin/env bash
# Deploy deploy/ to the production server. Runs on the laptop:
#   deploy/sync.sh             show what would change, ask, copy, start, wait until healthy
#   deploy/sync.sh --dry-run   only show what would change
#   deploy/sync.sh --yes       same as the default, without asking
# Copies the git-tracked files of deploy/ (working tree) to /opt/auth. It never
# copies or overwrites the secrets there (.env and the Keycloak vault/ directory);
# edit those on the server. Files it replaces are kept on the server in
# /root/auth-sync-backups/<UTC timestamp>/. deploy/backup/ is not copied; it is
# installed with deploy/backup/install.sh.
# It also creates the Docker network edge and the directory /opt/caddy-sites
# when they are missing (both shared with other projects; it never writes into
# the directory), and it stops if another compose file in /opt/auth would be
# merged into this stack, such as docker-compose.override.yml. Before copying,
# it validates the new Caddyfile together with the site files in
# /opt/caddy-sites. It installs deploy/caddy-site.sh as /usr/local/sbin/caddy-site.
# Requires: git, rsync, ssh with key access to root on the server (with python3).
set -euo pipefail
cd "$(dirname "$0")"

SERVER="${SERVER:-root@2.28.108.199}"
DEST=/opt/auth
PROTECTED=(.env vault)
HEALTH_TIMEOUT=300
EDGE_NETWORK=edge          # shared with other projects; only caddy joins it
SITES_DIR=/opt/caddy-sites # other projects' Caddy site files, mounted into caddy
# docker compose reads any of these next to docker-compose.yml without being
# asked: an override is merged into every command, a compose.y*ml replaces it.
FOREIGN_COMPOSE=(docker-compose.override.yml docker-compose.override.yaml
  compose.override.yml compose.override.yaml compose.yml compose.yaml docker-compose.yaml)

dry_run=0; assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes|-y) assume_yes=1 ;;
    *) echo "usage: $0 [--dry-run] [--yes]" >&2; exit 2 ;;
  esac
done

# One SSH connection for the whole run.
SSH_OPTS=(-o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%C" -o ControlPersist=60)
remote() { ssh "${SSH_OPTS[@]}" "$SERVER" "$@"; }
RSYNC=(rsync -rlpt --checksum --chmod=Fgo-w,Dgo-w -e "ssh ${SSH_OPTS[*]}")

# Tracked files only, minus anything that must stay server-side and backup/.
files=$(git ls-files . | grep -v '^backup/' | grep -vxF -f <(printf '%s\n' "${PROTECTED[@]}"))
excludes=(); for p in "${PROTECTED[@]}"; do excludes+=(--exclude="$p"); done

# Other projects never put files into /opt/auth (PRODUCTION.md, "Hosting another
# project behind this Caddy"); what this stack runs comes from deploy/ only.
foreign=$(remote "cd $DEST && for f in ${FOREIGN_COMPOSE[*]}; do [ ! -e \$f ] || echo \$f; done" </dev/null)
if [ -n "$foreign" ]; then
  echo "❌ $SERVER:$DEST contains ${foreign//$'\n'/ }, which docker compose would use" >&2
  echo "   in every command there, next to or instead of docker-compose.yml. Settings for" >&2
  echo "   this stack belong in deploy/docker-compose.yml; another project's sites go in" >&2
  echo "   $SITES_DIR. Move the file out of $DEST, then run sync.sh again. Nothing was changed." >&2
  exit 1
fi

rev=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- .)" ]; then
  rev="$rev-dirty"
  echo "⚠️  deploy/ has uncommitted changes; they will be deployed too."
fi

echo "== Dry run: $SERVER:$DEST (revision $rev)"
changes=$("${RSYNC[@]}" --dry-run --itemize-changes "${excludes[@]}" --files-from=<(echo "$files") ./ "$SERVER:$DEST/")
if [ -z "$changes" ]; then
  echo "No file changes."
else
  echo "$changes"
  while read -r flags path; do
    [[ "$flags" == "<f"* ]] || continue   # "<" = would be sent to the server
    echo "--- diff $path (server → local)"
    diff -u --label "server:$DEST/$path" --label "local:deploy/$path" \
      <(remote "cat '$DEST/$path' 2>/dev/null" </dev/null || true) "$path" || true
  done <<<"$changes"
fi

# The new docker-compose.yml and Caddyfile are checked in a temporary directory
# on the server before anything is copied.
check_dir=$(remote "mktemp -d /tmp/auth-sync-check.XXXXXX" </dev/null)
trap 'remote "rm -rf $check_dir" </dev/null || true' EXIT
tar -cf - docker-compose.yml Caddyfile | remote "tar -xf - -C $check_dir"

echo "== Checking docker-compose.yml against the server's .env"
remote "docker compose --project-directory $DEST -f $check_dir/docker-compose.yml config --quiet" </dev/null
echo "OK"

# Caddy imports every site file in $SITES_DIR, and one it can't read stops it
# from starting. Validated with the image and environment that the new compose
# file gives the caddy service, in a throwaway container without network.
echo "== Validating the Caddyfile with the site files in $SITES_DIR"
if ! remote "bash -s -- $DEST $check_dir $SITES_DIR" <<'EOF'
set -euo pipefail
dest=$1 dir=$2 sites=$3
docker compose --project-directory "$dest" -f "$dir/docker-compose.yml" config --format json \
  | python3 -c '
import json, sys
caddy = json.load(sys.stdin)["services"]["caddy"]
with open(sys.argv[1], "w") as env:
    for key, value in (caddy.get("environment") or {}).items():
        env.write((key if value is None else f"{key}={value}") + "\n")
print(caddy["image"])' "$dir/caddy.env" > "$dir/image"
[ -d "$sites" ] || { sites=$dir/no-sites; mkdir "$sites"; }   # before the first deploy
if out=$(docker run --rm --network none --env-file "$dir/caddy.env" \
    -v "$dir/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$sites:/etc/caddy/sites:ro" \
    "$(cat "$dir/image")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
  rc=0
else
  rc=$?
fi
grep -v '"level":"info"' <<<"$out" || true
exit $rc
EOF
then
  echo "❌ Caddy would not start with this Caddyfile and the site files in $SITES_DIR. Nothing was changed." >&2
  exit 1
fi

[ "$dry_run" -eq 1 ] && exit 0
if [ "$assume_yes" -eq 0 ]; then
  read -r -p "Deploy to $SERVER:$DEST and run docker compose up -d? [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]] || { echo "Aborted."; exit 1; }
fi

# Both outlive this stack and are shared with other projects, so they are only
# ever created here, never changed or removed.
echo "== Network $EDGE_NETWORK and directory $SITES_DIR (created when missing)"
remote "set -e
  if docker network inspect $EDGE_NETWORK >/dev/null 2>&1; then echo 'network $EDGE_NETWORK exists'
  else docker network create $EDGE_NETWORK >/dev/null; echo 'network $EDGE_NETWORK created'; fi
  if [ -d $SITES_DIR ]; then echo '$SITES_DIR exists'
  else install -d -o root -g root -m 755 $SITES_DIR; echo '$SITES_DIR created'; fi" </dev/null

ts=$(date -u +%Y%m%dT%H%M%SZ)
echo "== Copying (replaced files go to /root/auth-sync-backups/$ts/)"
"${RSYNC[@]}" --itemize-changes --backup --backup-dir="/root/auth-sync-backups/$ts" \
  "${excludes[@]}" --files-from=<(echo "$files") ./ "$SERVER:$DEST/"
remote "echo '$rev $ts' > $DEST/.deployed-revision"
remote "install -o root -g root -m 755 $DEST/caddy-site.sh /usr/local/sbin/caddy-site" </dev/null
echo "Installed /usr/local/sbin/caddy-site"

echo "== docker compose up -d"
remote "cd $DEST && docker compose up -d"

# caddy mounts the Caddyfile as a single file, and rsync replaces a file by
# renaming a new one over it, so a running caddy keeps the old one (a reload
# too) until it restarts. The new one passed the validation above.
remote "cd $DEST && if docker compose exec -T caddy cat /etc/caddy/Caddyfile | cmp -s - Caddyfile; then
    echo 'caddy runs the current Caddyfile'
  else
    echo '== caddy has an older Caddyfile: restarting it'; docker compose restart --no-deps caddy
  fi" </dev/null

echo "== Waiting until every container is running and healthy (up to ${HEALTH_TIMEOUT}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT))
while :; do
  expected=$(remote "cd $DEST && docker compose config --services" | wc -l)
  status=$(remote "cd $DEST && docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}'")
  # A service without a healthcheck (caddy) only has to be running.
  ready=$(awk '$2 == "running" && ($3 == "" || $3 == "healthy")' <<<"$status" | wc -l)
  if [ "$ready" -eq "$expected" ] && [ "$(wc -l <<<"$status")" -eq "$expected" ]; then
    echo "$status"
    echo "✅ All $expected services are up. Deployed revision $rev."
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "$status"
    echo "❌ Not healthy after ${HEALTH_TIMEOUT}s. Check: ssh $SERVER 'cd $DEST && docker compose logs --tail 100'" >&2
    exit 1
  fi
  sleep 5
done
