#!/bin/sh
# Restore a backup that install.sh made.
#
# Usage: rollback.sh [--list] [--skip-load] [backup-id]
#
# Restores the newest backup when no id is given. It restarts auditd when auditd.conf or a plugin
# file changed, loads the restored audit.rules, restarts rsyslog when our drop-in changed, and runs
# verify.sh. --list prints the backup ids, newest first, and changes nothing. --skip-load restores
# only the files, and is only for tests in containers.
#
# Exits 0 when done, 1 when there is no such backup and nothing changed, and 3 when the restore
# or verify failed and a person must fix the host. Each run logs to
# /var/log/auditd-kit/rollback-<time>.log.
# shellcheck disable=SC2034
set -eu

rollback_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
for rollback_l in common backup load; do
  # shellcheck source=/dev/null
  . "$rollback_root/lib/$rollback_l.sh"
done
AKIT_SCRIPTS_DIR=$rollback_root
umask 022

PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

rollback_list=no
rollback_skip_load=no
rollback_id=
for rollback_a in "$@"; do
  case "$rollback_a" in
    --list) rollback_list=yes ;;
    --skip-load) rollback_skip_load=yes ;;
    -*) akit_die "$AKIT_EXIT_REFUSED" "unknown argument: $rollback_a" ;;
    *)
      [ -z "$rollback_id" ] || akit_die "$AKIT_EXIT_REFUSED" "give at most one backup id"
      rollback_id=$rollback_a
      ;;
  esac
done

if [ "$rollback_list" = yes ]; then
  akit_backup_ids | awk '{ id[NR] = $0 } END { for (i = NR; i > 0; i--) print id[i] }'
  exit "$AKIT_EXIT_OK"
fi

akit_lock_take
trap akit_lock_release EXIT
trap 'exit 1' INT TERM HUP

if [ -z "$rollback_id" ]; then
  rollback_id=$(akit_backup_ids | tail -n 1)
  [ -n "$rollback_id" ] || akit_die "$AKIT_EXIT_REFUSED" "no backups in $AKIT_BACKUP_DIR"
fi
if ! akit_backup_valid_id "$rollback_id" || [ ! -f "$AKIT_BACKUP_DIR/$rollback_id.tgz" ]; then
  akit_die "$AKIT_EXIT_REFUSED" "no backup $rollback_id in $AKIT_BACKUP_DIR"
fi

rollback_log_dir=$(akit_path /var/log/auditd-kit)
if mkdir -p "$rollback_log_dir" 2>/dev/null; then
  AKIT_LOG_FILE="$rollback_log_dir/rollback-$(date -u '+%Y%m%dT%H%M%SZ').log"
else
  akit_log warning "cannot create $rollback_log_dir, so this run is not logged"
fi

if akit_rollback "$rollback_id" "$rollback_skip_load"; then
  akit_log info "backup $rollback_id restored"
  echo "restored=$rollback_id"
  exit "$AKIT_EXIT_OK"
fi
akit_log error "rollback to backup $rollback_id failed, and the host needs a person to fix it"
exit "$AKIT_EXIT_ROLLBACK_FAILED"
