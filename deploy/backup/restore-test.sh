#!/usr/bin/env bash
# Restore test for pg-backup dumps. Runs on the server; installed as
# /usr/local/sbin/pg-restore-test:
#   pg-restore-test auth                  newest dump in BACKUP_DIR of /etc/pg-backup/auth.conf
#   pg-restore-test auth /path/x.dump     a specific dump
# Restores the dump into a throwaway container of the image production runs
# (--rm, --network none, no published ports, no named volumes, data on tmpfs),
# then compares it with production: the number of tables plus every CHECK_*
# query from the config. Production is only read, in read-only transactions.
# Removes the container and prints PASS or FAIL (exit code 0 or 1).
set -euo pipefail
shopt -s inherit_errexit
umask 077

CONF_DIR=/etc/pg-backup
READY_TIMEOUT=120

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 INSTANCE [DUMP]" >&2; exit 2; }
INSTANCE=$1
[[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid instance name '$INSTANCE'"
CONF="$CONF_DIR/$INSTANCE.conf"

# Same format as for pg-backup; CHECK_NAME=SQL lines define the checks.
check_names=(); check_sql=()
load_config() {
  local line key
  [ -r "$CONF" ] || die "config $CONF not found"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "$CONF: cannot parse: $line"
    key=${BASH_REMATCH[1]}
    case "$key" in
      COMPOSE_DIR|SERVICE|DB_NAME|DB_USER|BACKUP_DIR) printf -v "$key" '%s' "${BASH_REMATCH[2]}" ;;
      RETENTION_DAYS) ;;
      CHECK_*) check_names+=("${key#CHECK_}"); check_sql+=("${BASH_REMATCH[2]}") ;;
      *) die "$CONF: unknown key $key" ;;
    esac
  done <"$CONF"
  for key in COMPOSE_DIR SERVICE DB_NAME DB_USER BACKUP_DIR; do
    [ -n "${!key:-}" ] || die "$CONF: $key is not set"
  done
  for key in SERVICE DB_NAME DB_USER; do
    [[ "${!key}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$CONF: invalid $key"
  done
}
load_config

exec 9>"/run/lock/pg-restore-test-$INSTANCE.lock"
flock -n 9 || die "another restore test of '$INSTANCE' is running"

# From here on every exit removes the test container and prints the verdict.
name="pg-restore-test-$INSTANCE"
result=FAIL
on_exit() {
  local rc=$?
  docker rm -fv "$name" >/dev/null 2>&1 || true
  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "ERROR: container $name is still there; remove it with: docker rm -fv $name" >&2
    result=FAIL
  else
    echo "No test container left ($name)."
  fi
  [ "$rc" -eq 0 ] || result=FAIL
  echo "$result"
  [ "$result" = PASS ] || exit 1
}
trap on_exit EXIT

if [ $# -eq 2 ]; then
  dump=$2
else
  dump=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$INSTANCE-*.dump" -printf '%T@\t%p\n' \
    | sort -rn | awk -F'\t' 'NR == 1 { print $2 }')
fi
[ -n "$dump" ] && [ -r "$dump" ] || die "no dump found in $BACKUP_DIR"

cd "$COMPOSE_DIR"
prod_id=$(docker compose ps -q "$SERVICE")
[ -n "$prod_id" ] || die "production service $SERVICE is not running"
image=$(docker inspect -f '{{.Image}}' "$prod_id")
image_ref=$(docker inspect -f '{{.Config.Image}}' "$prod_id")
pgdata=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | sed -n 's/^PGDATA=//p')
[ -n "$pgdata" ] || die "image $image_ref has no PGDATA"

# Read-only against production: every statement runs in a read-only transaction.
q_prod() {
  docker compose exec -T -e PGOPTIONS='-c default_transaction_read_only=on' "$SERVICE" \
    psql -X -q -v ON_ERROR_STOP=1 -At -U "$DB_USER" -d "$DB_NAME" -c "$1"
}
q_copy() { docker exec "$name" psql -X -q -v ON_ERROR_STOP=1 -At -U "$DB_USER" -d "$DB_NAME" -c "$1"; }

echo "Restore test for '$INSTANCE'"
echo "Dump:      $dump ($(stat -c %s "$dump") bytes, $(date -u -d "@$(stat -c %Y "$dump")" '+%F %T UTC'))"
echo "Image:     $image_ref (the image production runs)"

docker rm -fv "$name" >/dev/null 2>&1 || true   # left over from a killed run
docker run -d --rm --name "$name" --network none --tmpfs "$pgdata" \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_USER="$DB_USER" -e POSTGRES_DB="$DB_NAME" \
  "$image" >/dev/null
echo "Container: $name (--network none, no published ports, data on tmpfs)"

# TCP on 127.0.0.1 answers only once the entrypoint has finished initdb and
# started the final server (its temporary init server listens on the socket only).
waited=0
until docker exec "$name" pg_isready -q -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" 2>/dev/null; do
  docker container inspect "$name" >/dev/null 2>&1 || die "the test container exited"
  [ "$waited" -lt "$READY_TIMEOUT" ] || die "test container not ready after ${READY_TIMEOUT}s"
  sleep 2; waited=$((waited + 2))
done

started=$SECONDS
docker exec -i "$name" pg_restore -U "$DB_USER" -d "$DB_NAME" --exit-on-error --single-transaction <"$dump"
echo "Restored in $((SECONDS - started))s"
echo

names=(tables "${check_names[@]}")
sqls=("SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')" "${check_sql[@]}")
ok=1
printf '%-24s %12s %12s\n' check production restored
for i in "${!names[@]}"; do
  prod=$(q_prod "${sqls[$i]}")
  copy=$(q_copy "${sqls[$i]}")
  if [ "$prod" = "$copy" ]; then mark=ok; else mark=MISMATCH; ok=0; fi
  printf '%-24s %12s %12s  %s\n' "${names[$i],,}" "$prod" "$copy" "$mark"
  [ "$i" -eq 0 ] && [ "$copy" -eq 0 ] && { echo "The restored database has no tables."; ok=0; }
done
[ "$ok" -eq 1 ] || echo "A mismatch can also mean production changed after the dump was taken: take a new backup and run the test again."
echo
[ "$ok" -eq 1 ] && result=PASS
exit 0
