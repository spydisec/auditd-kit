#!/bin/sh
# Back up the audit config, without installing or changing anything else.
#
# Usage: backup.sh
#
# Makes the same backup that install.sh makes before it changes a host: a copy of /etc/audit and
# /etc/audisp in /var/lib/auditd-kit/backups. It works on a host that never ran install.sh, so
# you can back up, edit your own rules, and run rollback.sh to undo the edit. The newest 5
# backups are kept, and the first one on a host that has no install is also kept as "original".
#
# Prints backup=<id>. Exits 0 when done and 1 when it can't make the backup.
# shellcheck disable=SC2034
set -eu

backup_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
for backup_l in common backup; do
  # shellcheck source=/dev/null
  . "$backup_root/lib/$backup_l.sh"
done
umask 022

[ $# -eq 0 ] || akit_die "$AKIT_EXIT_REFUSED" "backup.sh takes no arguments"
[ "$(id -u)" -eq 0 ] || akit_die "$AKIT_EXIT_REFUSED" "run it as root, e.g. with sudo"
command -v tar >/dev/null 2>&1 || akit_die "$AKIT_EXIT_REFUSED" "tar not found. Install it and try again."

akit_lock_take
trap akit_lock_release EXIT
trap 'exit 1' INT TERM HUP

backup_new=$(akit_backup_create) || akit_die "$AKIT_EXIT_REFUSED" "the backup was not made"
echo "backup=$backup_new"
