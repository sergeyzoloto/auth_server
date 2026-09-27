#!/usr/bin/env bash
# Installs the backup scripts and timers. Runs on the laptop, from the repository:
#   deploy/backup/install.sh server   on the server: /usr/local/sbin/pg-backup,
#                                     /usr/local/sbin/pg-restore-test, the pg-backup@
#                                     units, and every deploy/backup/*.conf as
#                                     /etc/pg-backup/*.conf; enables pg-backup@INSTANCE.timer
#   deploy/backup/install.sh laptop   on this laptop: ~/.local/bin/finance-nl-backup-pull
#                                     and its systemd user timer
# Safe to run again after a change. It never runs a backup and never touches
# existing dumps. The SSH key for the pull is a one-time manual step
# (PRODUCTION.md, "Backups").
set -euo pipefail
cd "$(dirname "$0")"

SERVER="${SERVER:-root@2.28.108.199}"
SSH_OPTS=(-o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%C" -o ControlPersist=60)
remote() { ssh "${SSH_OPTS[@]}" "$SERVER" "$@"; }
# put LOCAL_FILE MODE REMOTE_PATH: copy one file, owned by root, with that mode.
put() { remote "install -D -o root -g root -m $2 /dev/stdin '$3'" <"$1"; echo "  $3 (mode $2)"; }

case "${1:-}" in
  server)
    confs=(*.conf)
    [ -e "${confs[0]}" ] || { echo "no *.conf in deploy/backup" >&2; exit 1; }
    echo "== Installing on $SERVER"
    remote "install -d -o root -g root -m 700 /etc/pg-backup /var/backups/pg"
    put pg-backup.sh 755 /usr/local/sbin/pg-backup
    put restore-test.sh 755 /usr/local/sbin/pg-restore-test
    put pg-backup@.service 644 /etc/systemd/system/pg-backup@.service
    put pg-backup@.timer 644 /etc/systemd/system/pg-backup@.timer
    for conf in "${confs[@]}"; do put "$conf" 600 "/etc/pg-backup/$conf"; done
    remote systemctl daemon-reload
    for conf in "${confs[@]}"; do
      remote systemctl enable --now "pg-backup@${conf%.conf}.timer"
    done
    remote systemctl list-timers --no-pager 'pg-backup@*'
    ;;
  laptop)
    echo "== Installing on this laptop"
    install -D -m 700 pull-backups.sh "$HOME/.local/bin/finance-nl-backup-pull"
    install -D -m 644 -t "$HOME/.config/systemd/user" \
      finance-nl-backup-pull.service finance-nl-backup-pull.timer
    echo "  ~/.local/bin/finance-nl-backup-pull, ~/.config/systemd/user/finance-nl-backup-pull.{service,timer}"
    [ -r "$HOME/.ssh/finance-nl-backup" ] || echo "⚠️  ~/.ssh/finance-nl-backup is missing; create and authorize it first (PRODUCTION.md, Backups)."
    systemctl --user daemon-reload
    systemctl --user enable --now finance-nl-backup-pull.timer
    systemctl --user list-timers --no-pager finance-nl-backup-pull.timer
    ;;
  *)
    echo "usage: $0 server|laptop" >&2; exit 2 ;;
esac
