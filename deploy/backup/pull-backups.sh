#!/usr/bin/env bash
# Pulls the Postgres dumps from the production server to this laptop. Runs on
# the laptop: daily from the systemd user timer finance-nl-backup-pull.timer
# (installed as ~/.local/bin/finance-nl-backup-pull by
# deploy/backup/install.sh laptop), or by hand.
# Copies /var/backups/pg/ on the server (one subfolder per database) to
# ~/backups/finance-nl-server/ with the dedicated key ~/.ssh/finance-nl-backup.
# The server lets that key run only "rrsync -ro /var/backups/pg/", so it can
# read the backups and nothing else; the server holds no credentials for the
# laptop, so a compromised server cannot touch these copies.
# Keeps KEEP_DAYS days of dumps here (never fewer than the newest KEEP_MIN per
# database), then checks freshness: if the newest dump of any database is
# older than MAX_AGE_HOURS, or the pull failed, it prints a warning, sends a
# desktop notification and exits non-zero.
set -euo pipefail
shopt -s inherit_errexit
umask 077

SERVER="${SERVER:-root@2.28.108.199}"
KEY="$HOME/.ssh/finance-nl-backup"
DEST="$HOME/backups/finance-nl-server"
KEEP_DAYS=60
KEEP_MIN=3
MAX_AGE_HOURS=36
ATTEMPTS=5          # the laptop may have just woken up without a network
RETRY_DELAY=60

problems=()

mkdir -p "$DEST"
chmod 700 "$HOME/backups" "$DEST"
[ -r "$KEY" ] || { echo "ERROR: key $KEY not found (see PRODUCTION.md, Backups)" >&2; exit 1; }

# Only the dedicated key, never the agent's keys; the host key must already be known.
ssh_cmd="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20"
echo "Pulling $SERVER:/var/backups/pg/ to $DEST/"
for ((attempt = 1; ; attempt++)); do
  # Server-side temporary files start with "."; -p with --chmod forces 700/600 here.
  if rsync -rtp --chmod=D700,F600 --exclude='.*' --out-format='  updated: %n (%l bytes)' \
      -e "$ssh_cmd" "$SERVER:./" "$DEST/"; then
    break
  else
    rc=$?
  fi
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    problems+=("pull from the server failed (rsync exit code $rc, $ATTEMPTS attempts)")
    break
  fi
  echo "rsync failed (exit code $rc), attempt $attempt of $ATTEMPTS; retrying in ${RETRY_DELAY}s"
  sleep "$RETRY_DELAY"
done

cutoff=$(date -d "-$KEEP_DAYS days" +%s)
now=$(date +%s)
databases=0
for dir in "$DEST"/*/; do
  [ -d "$dir" ] || continue
  db=$(basename "$dir")
  databases=$((databases + 1))

  # Newest first; keep KEEP_MIN whatever their age, delete the rest past KEEP_DAYS.
  mapfile -t dumps < <(find "$dir" -maxdepth 1 -type f -name '*.dump' -printf '%T@\t%p\n' | sort -rn)
  for i in "${!dumps[@]}"; do
    mtime=${dumps[$i]%%.*}; path=${dumps[$i]#*$'\t'}
    if [ "$i" -ge "$KEEP_MIN" ] && [ "$mtime" -lt "$cutoff" ]; then
      rm -f -- "$path"
      echo "  deleted $path (older than $KEEP_DAYS days)"
    fi
  done

  if [ "${#dumps[@]}" -eq 0 ]; then
    problems+=("$db: no dumps")
    continue
  fi
  newest=${dumps[0]#*$'\t'}
  age=$((now - ${dumps[0]%%.*}))
  count=$(find "$dir" -maxdepth 1 -type f -name '*.dump' | wc -l)
  printf '%s: newest %s (%s bytes, %dh%02dm old), %d dumps, %s\n' "$db" "$(basename "$newest")" \
    "$(stat -c %s "$newest")" $((age / 3600)) $((age % 3600 / 60)) "$count" "$(du -sh "$dir" | cut -f1)"
  if [ "$age" -gt $((MAX_AGE_HOURS * 3600)) ]; then
    problems+=("$db: newest dump is $((age / 3600))h old (limit ${MAX_AGE_HOURS}h)")
  fi
done
[ "$databases" -gt 0 ] || problems+=("no database folders in $DEST")

if [ "${#problems[@]}" -gt 0 ]; then
  for p in "${problems[@]}"; do echo "WARNING: $p" >&2; done
  if command -v notify-send >/dev/null; then
    notify-send -u critical -a "finance-nl backups" "finance-nl backup pull: problem" \
      "$(printf '%s\n' "${problems[@]}")" || true
  fi
  exit 1
fi
echo "OK: all backups are fresh"
