#!/usr/bin/env bash
# Nightly pg_dump of one Postgres database that runs in a Docker Compose stack.
# Installed on the server as /usr/local/sbin/pg-backup and run by
# pg-backup@INSTANCE.service (timer: pg-backup@INSTANCE.timer):
#   pg-backup auth        reads /etc/pg-backup/auth.conf
# Each instance has its own config file (format: deploy/backup/auth.conf).
# Steps: pg_dump -Fc into a temporary file in BACKUP_DIR, check the archive
# with pg_restore, rename it to INSTANCE-YYYY-MM-DDTHHMMZ.dump, delete dumps
# older than RETENTION_DAYS (always keeping the newest KEEP_MIN), and write
# BACKUP_DIR/last-success. pg_dump runs inside the database container over the
# local socket, so no password is involved. On any failure the temporary file
# is deleted and the exit code is non-zero.
set -euo pipefail
shopt -s inherit_errexit
umask 077

CONF_DIR=/etc/pg-backup
KEEP_MIN=3          # never delete the newest dumps, whatever their age
READY_TIMEOUT=300   # seconds to wait for the database (e.g. right after boot)

# Under systemd, "<3>" marks a line as an error in the journal (journalctl -p err).
err_prefix=""; [ -n "${JOURNAL_STREAM:-}" ] && err_prefix="<3>"
log() { echo "$*"; }
die() { echo "${err_prefix}ERROR: $*" >&2; exit 1; }

[ $# -eq 1 ] || { echo "usage: $0 INSTANCE   (reads $CONF_DIR/INSTANCE.conf)" >&2; exit 2; }
INSTANCE=$1
[[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid instance name '$INSTANCE'"
CONF="$CONF_DIR/$INSTANCE.conf"

# KEY=value lines; the value is everything after the first "=", taken literally
# (no quotes, no variables). The config is parsed, never executed.
load_config() {
  local line key
  [ -r "$CONF" ] || die "config $CONF not found"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "$CONF: cannot parse: $line"
    key=${BASH_REMATCH[1]}
    case "$key" in
      COMPOSE_DIR|SERVICE|DB_NAME|DB_USER|BACKUP_DIR|RETENTION_DAYS)
        printf -v "$key" '%s' "${BASH_REMATCH[2]}" ;;
      CHECK_*) ;;   # read by pg-restore-test
      *) die "$CONF: unknown key $key" ;;
    esac
  done <"$CONF"
  for key in COMPOSE_DIR SERVICE DB_NAME DB_USER BACKUP_DIR RETENTION_DAYS; do
    [ -n "${!key:-}" ] || die "$CONF: $key is not set"
  done
  [[ "$COMPOSE_DIR" == /* && -d "$COMPOSE_DIR" ]] || die "$CONF: COMPOSE_DIR $COMPOSE_DIR is not a directory"
  [[ "$BACKUP_DIR" == /* ]] || die "$CONF: BACKUP_DIR must be an absolute path"
  [[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die "$CONF: RETENTION_DAYS must be a positive integer"
  for key in SERVICE DB_NAME DB_USER; do
    [[ "${!key}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$CONF: invalid $key"
  done
}
load_config

# One run per instance at a time (the timer and a manual run could overlap).
exec 9>"/run/lock/pg-backup-$INSTANCE.lock"
flock -n 9 || die "another backup of '$INSTANCE' is running"

cd "$COMPOSE_DIR"
# docker compose exec -T passes its stdin on to the container: a call without a
# file as input gets </dev/null, so it can't read the rest of a script fed to bash.
dexec() { docker compose exec -T "$SERVICE" "$@"; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
# Leftovers of a run that was killed before its cleanup could run.
find "$BACKUP_DIR" -maxdepth 1 -type f -name ".$INSTANCE-*.tmp" -delete

log "Backup of '$INSTANCE': database $DB_NAME, service $SERVICE in $COMPOSE_DIR"

waited=0
until dexec pg_isready -q -U "$DB_USER" -d "$DB_NAME" </dev/null 2>/dev/null; do
  [ "$waited" -ge "$READY_TIMEOUT" ] && die "database not ready after ${READY_TIMEOUT}s"
  sleep 10; waited=$((waited + 10))
done
[ "$waited" -gt 0 ] && log "Database ready after ${waited}s"

tmp=""; status_tmp=""
on_exit() {
  local rc=$?
  rm -f "$tmp" "$status_tmp"
  [ "$rc" -eq 0 ] || echo "${err_prefix}ERROR: backup of '$INSTANCE' failed (exit code $rc)" >&2
}
trap on_exit EXIT
tmp=$(mktemp -p "$BACKUP_DIR" --suffix=.tmp ".$INSTANCE-XXXXXX")

started=$SECONDS
dexec pg_dump -Fc -U "$DB_USER" -d "$DB_NAME" </dev/null >"$tmp"
size=$(stat -c %s "$tmp")
[ "$size" -gt 0 ] || die "pg_dump wrote an empty file"

# The table of contents must list at least one object...
list=$(dexec pg_restore --list <"$tmp")
entries=$(grep -c '^[0-9]' <<<"$list" || true)
[ "$entries" -gt 0 ] || die "pg_restore --list shows no entries"
# ...and every data block must decompress (renders the whole restore script).
dexec pg_restore -f /dev/null <"$tmp"

final="$BACKUP_DIR/$INSTANCE-$(date -u +%Y-%m-%dT%H%MZ).dump"
mv -f "$tmp" "$final"
log "Wrote $final: $size bytes, $entries archive entries, $((SECONDS - started))s"

# Retention: delete dumps older than RETENTION_DAYS, except the newest KEEP_MIN.
cutoff=$(date -d "-$RETENTION_DAYS days" +%s)
n=0
while IFS=$'\t' read -r mtime path; do
  n=$((n + 1))
  [ "$n" -le "$KEEP_MIN" ] && continue
  if [ "${mtime%.*}" -lt "$cutoff" ]; then
    rm -f -- "$path"
    log "Deleted $path (older than $RETENTION_DAYS days)"
  fi
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$INSTANCE-*.dump" -printf '%T@\t%p\n' | sort -rn)

status_tmp=$(mktemp -p "$BACKUP_DIR" --suffix=.tmp ".$INSTANCE-XXXXXX")
cat >"$status_tmp" <<EOF
last_success=$(date -u +%Y-%m-%dT%H:%M:%SZ)
last_success_epoch=$(date +%s)
file=$(basename "$final")
size_bytes=$size
EOF
mv -f "$status_tmp" "$BACKUP_DIR/last-success"

kept=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$INSTANCE-*.dump" | wc -l)
log "OK: $kept dumps in $BACKUP_DIR ($(du -sh "$BACKUP_DIR" | cut -f1))"
