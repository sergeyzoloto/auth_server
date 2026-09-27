#!/usr/bin/env bash
# Puts another project's Caddy site file live, or takes it offline, so that
# /opt/caddy-sites only ever holds files the running Caddy accepts: a file Caddy
# can't read would stop it from starting at the next restart (a deploy, the
# 04:00 reboot), and auth.finance-nl.com with it. deploy/sync.sh installs this
# script on the server as /usr/local/sbin/caddy-site. On the server, as root:
#   caddy-site install /root/finance.caddy   validate, put it live as /opt/caddy-sites/finance.caddy, reload
#   caddy-site remove finance                move /opt/caddy-sites/finance.caddy to /root/caddy-sites-removed/, reload
# The source file of an install is left where it is. Replaced and removed files
# are kept in /root/caddy-sites-removed/<UTC timestamp>/. See PRODUCTION.md,
# "Hosting another project behind this Caddy".
set -euo pipefail

# Overridable for tests only.
AUTH_DIR=${AUTH_DIR:-/opt/auth}
SITES_DIR=${SITES_DIR:-/opt/caddy-sites}
REMOVED_DIR=${REMOVED_DIR:-/root/caddy-sites-removed}
NAME_RE='^[a-z0-9][a-z0-9-]*$'   # the site name; its file is <name>.caddy

die() { echo "❌ $*" >&2; exit 1; }
usage() { echo "usage: caddy-site install /root/finance.caddy | caddy-site remove finance" >&2; exit 2; }

[ $# -eq 2 ] || usage
[ "$(id -u)" -eq 0 ] || die "run it as root"
[ -d "$SITES_DIR" ] || die "$SITES_DIR does not exist (deploy/sync.sh creates it)"

exec 9>/run/lock/caddy-site.lock
flock -n 9 || die "another caddy-site is running"

work=$(mktemp -d)   # mode 700: the copy of Caddy's environment holds the admin allowlist
trap 'rm -rf "$work"' EXIT
ts=$(date -u +%Y%m%dT%H%M%SZ)

compose() { (cd "$AUTH_DIR" && docker compose "$@") </dev/null; }

# Prints the id of the running caddy container, after checking that it runs
# the Caddyfile that is on disk (a single-file mount keeps an old one until a
# restart), so that what is validated is what a reload and a restart load.
running_caddy() {
  local id
  id=$(compose ps -q caddy)
  [ -n "$id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$id")" = true ] \
    || die "the caddy container of $AUTH_DIR is not running; nothing was changed"
  docker exec "$id" cat /etc/caddy/Caddyfile | cmp -s - "$AUTH_DIR/Caddyfile" \
    || die "the running Caddy has an older $AUTH_DIR/Caddyfile; restart it first (cd $AUTH_DIR && docker compose restart caddy). Nothing was changed"
  echo "$id"
}

# Validates $AUTH_DIR/Caddyfile with the site files in directory $2, in a
# throwaway container of the running Caddy's image ($1) with its environment,
# without network or volumes.
validate() {
  local out
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | grep . > "$work/caddy.env" || return 1
  if out=$(docker run --rm --network none --env-file "$work/caddy.env" \
      -v "$AUTH_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$2:/etc/caddy/sites:ro" \
      "$(docker inspect -f '{{.Image}}' "$1")" \
      caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
    return 0
  fi
  grep -v '"level":"info"' <<<"$out" >&2 || true
  return 1
}

# Caddy reads its site files again. On failure it keeps the previous configuration.
reload() {
  local out
  if out=$(compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
    return 0
  fi
  grep -v '"level":"info"' <<<"$out" >&2 || true
  return 1
}

# Puts file $1 in place as $SITES_DIR/$2 with a rename inside the directory,
# so Caddy never sees a half-written file (the temporary name doesn't match *.caddy).
put() {
  install -o root -g root -m 644 "$1" "$SITES_DIR/.$2.new"
  mv -f "$SITES_DIR/.$2.new" "$SITES_DIR/$2"
}

keep_dir() { install -d -m 700 "$REMOVED_DIR" "$REMOVED_DIR/$ts"; echo "$REMOVED_DIR/$ts"; }

cmd_install() {
  local src=$1 file name id count prev=""
  [ -f "$src" ] || die "$src is not a file"
  file=$(basename "$src"); name=${file%.caddy}
  [ "$file" = "$name.caddy" ] && [[ $name =~ $NAME_RE ]] \
    || die "$file: the file name must be the site name plus .caddy, in lowercase letters, digits and dashes (finance.caddy)"
  id=$(running_caddy)

  # A copy of the live site files, with the candidate in place of its old version.
  mkdir "$work/sites"
  find "$SITES_DIR" -maxdepth 1 ! -type d -name '*.caddy' ! -name "$file" -exec cp {} "$work/sites/" \;
  cp "$src" "$work/sites/$file"
  count=$(find "$work/sites" -type f | wc -l)
  echo "== Validating $AUTH_DIR/Caddyfile with $file from $src and $((count - 1)) other site file(s)"
  validate "$id" "$work/sites" || die "$src is not valid: nothing was changed"
  echo "Valid."

  if [ -e "$SITES_DIR/$file" ]; then
    prev=$(keep_dir)/$file
    cp -p "$SITES_DIR/$file" "$prev"
  fi
  put "$work/sites/$file" "$file"   # exactly the bytes that were validated
  echo "== Reloading Caddy"
  if reload; then
    if [ -n "$prev" ]; then
      echo "✅ $SITES_DIR/$file replaced and live. The previous version is kept as $prev"
    else
      echo "✅ $SITES_DIR/$file installed and live"
    fi
    return 0
  fi
  if [ -n "$prev" ]; then
    echo "Reload failed: restoring the previous $file" >&2
    put "$prev" "$file"
  else
    echo "Reload failed: removing $file again" >&2
    rm -f "$SITES_DIR/$file"
  fi
  if reload; then
    die "Caddy rejected $file at reload. $SITES_DIR is as before and Caddy runs its previous configuration"
  fi
  die "Caddy rejected $file at reload, and the reload after restoring $SITES_DIR failed too. Check: cd $AUTH_DIR && docker compose logs --tail 50 caddy"
}

cmd_remove() {
  local name=${1%.caddy} file dest
  [[ $name =~ $NAME_RE ]] || die "$1: give the site name, such as finance"
  file=$name.caddy
  [ -f "$SITES_DIR/$file" ] || die "$SITES_DIR/$file does not exist"
  running_caddy >/dev/null

  dest=$(keep_dir)
  mv "$SITES_DIR/$file" "$dest/$file"
  echo "== Moved $SITES_DIR/$file to $dest/, reloading Caddy"
  if reload; then
    echo "✅ Site $name removed. The file is kept as $dest/$file"
    return 0
  fi
  echo "Reload failed: putting $file back" >&2
  put "$dest/$file" "$file"
  if reload; then
    die "Caddy rejected the configuration without $file, so it is back in place and Caddy runs as before"
  fi
  die "Caddy rejected the configuration without $file, and the reload after putting it back failed too. Check: cd $AUTH_DIR && docker compose logs --tail 50 caddy"
}

case "$1" in
  install) cmd_install "$2" ;;
  remove) cmd_remove "$2" ;;
  *) usage ;;
esac
