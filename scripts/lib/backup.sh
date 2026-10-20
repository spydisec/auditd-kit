# Back up and restore the files that auditd-kit changes. Source this file after common.sh, don't
# run it.
# shellcheck shell=sh
#
# A backup is /var/lib/auditd-kit/backups/<id>.tgz, where the id is the UTC time as
# YYYYmmddTHHMMSSZ, with -1, -2, and so on added when that id exists. It holds /etc/audit, the
# RHEL 7 plugin dir /etc/audisp, our rsyslog drop-in, and the state file, when each exists.
# Paths in the archive are relative to /, so a restore under AKIT_ROOT works the same way.

AKIT_BACKUP_DIR=$(akit_path /var/lib/auditd-kit/backups)
AKIT_BACKUP_KEEP=5

# The paths a backup holds, and the paths a restore looks at for files added after the backup.
AKIT_BACKUP_PATHS='etc/audit etc/audisp etc/rsyslog.d/40-auditd-kit.conf etc/auditd-kit/state'
AKIT_BACKUP_SCAN='etc/audit etc/audisp etc/rsyslog.d/40-auditd-kit.conf etc/auditd-kit'

# akit_backup_existing <paths>: print the paths that exist under AKIT_ROOT.
akit_backup_existing() {
  for backup_p in $1; do
    if [ -e "$(akit_path "/$backup_p")" ]; then
      echo "$backup_p"
    fi
  done
}

# akit_backup_valid_id <id>
akit_backup_valid_id() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-*) ;;
    *) return 1 ;;
  esac
  case "${1#*Z-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# akit_backup_ids: print the backup ids, oldest first.
akit_backup_ids() {
  [ -d "$AKIT_BACKUP_DIR" ] || return 0
  for backup_f in "$AKIT_BACKUP_DIR"/*.tgz; do
    backup_n=${backup_f##*/}
    backup_n=${backup_n%.tgz}
    if [ -f "$backup_f" ] && akit_backup_valid_id "$backup_n"; then
      echo "$backup_n"
    fi
  done | awk '{
    base = $0
    n = 0
    if (match(base, /-[0-9]+$/)) {
      n = substr(base, RSTART + 1)
      base = substr(base, 1, RSTART - 1)
    }
    printf "%s %010d %s\n", base, n, $0
  }' | sort | awk '{ print $3 }'
}

# akit_backup_create: write a new backup, remove all but the newest 5, and print the new id.
akit_backup_create() {
  backup_members=$(akit_backup_existing "$AKIT_BACKUP_PATHS")
  if [ ! -d "$(akit_path /etc/audit)" ]; then
    akit_log error "nothing to back up, $(akit_path /etc/audit) is missing"
    return 1
  fi
  mkdir -p "$AKIT_BACKUP_DIR" && chmod 0700 "$AKIT_BACKUP_DIR" || return 1
  backup_base=$(date -u '+%Y%m%dT%H%M%SZ')
  # A later backup in the same second takes the next suffix after the highest one in use, so the
  # ids keep their order even after old ones are removed.
  backup_id=$(akit_backup_ids | awk -v b="$backup_base" '
    $0 == b { seen = 1 }
    index($0, b "-") == 1 { s = substr($0, length(b) + 2) + 0; if (s > n) n = s; seen = 1 }
    END { print (seen ? b "-" (n + 1) : b) }')
  backup_tmp="$AKIT_BACKUP_DIR/.$backup_id.tmp"
  # The member list has no spaces, so it is split on purpose.
  # shellcheck disable=SC2086
  if ! tar -czf "$backup_tmp" -C "${AKIT_ROOT:-/}" $backup_members \
    || ! mv -f "$backup_tmp" "$AKIT_BACKUP_DIR/$backup_id.tgz"; then
    rm -f "$backup_tmp"
    akit_log error "cannot write backup $AKIT_BACKUP_DIR/$backup_id.tgz"
    return 1
  fi
  backup_all=$(akit_backup_ids)
  backup_count=$(printf '%s\n' "$backup_all" | grep -c .) || true
  if [ "$backup_count" -gt "$AKIT_BACKUP_KEEP" ]; then
    printf '%s\n' "$backup_all" | head -n $((backup_count - AKIT_BACKUP_KEEP)) | while read -r backup_old; do
      rm -f "$AKIT_BACKUP_DIR/$backup_old.tgz"
    done
  fi
  echo "$backup_id"
}

# akit_backup_ours <rel-path>: succeed when auditd-kit wrote the file. That is a path that
# contains auditd-kit, a file the state file lists, or the audit.rules that augenrules writes.
akit_backup_ours() {
  case "$1" in
    *auditd-kit* | etc/audit/audit.rules | etc/audit/audit.rules.prev) return 0 ;;
  esac
  [ -r "$AKIT_BACKUP_STATE" ] || return 1
  sed -n 's/^file=[^ ]* //p' "$AKIT_BACKUP_STATE" | grep -x -F "/$1" >/dev/null 2>&1
}

# akit_backup_restore <id>: put the files back as they were at the backup. It first checks that
# the archive can be read, then removes the files auditd-kit added after the backup, and then
# unpacks the archive. A file added after the backup by something else stays, with a warning.
# The canary stays, unless the backup is from before the first install.
akit_backup_restore() {
  if ! akit_backup_valid_id "$1"; then
    akit_log error "not a backup id: $1"
    return 1
  fi
  restore_archive="$AKIT_BACKUP_DIR/$1.tgz"
  restore_root=${AKIT_ROOT:-/}
  AKIT_BACKUP_STATE=$(akit_path /etc/auditd-kit/state)
  if ! restore_list=$(tar -tzf "$restore_archive" 2>/dev/null) || [ -z "$restore_list" ]; then
    akit_log error "cannot read backup $restore_archive"
    return 1
  fi
  # tar lists the files now on the host, so restore needs no find.
  restore_now=
  restore_have=$(akit_backup_existing "$AKIT_BACKUP_SCAN")
  if [ -n "$restore_have" ]; then
    restore_scan=$(mktemp) || return 1
    # The path list has no spaces, so it is split on purpose.
    # shellcheck disable=SC2086
    if ! tar -cf "$restore_scan" -C "$restore_root" $restore_have \
      || ! restore_now=$(tar -tf "$restore_scan"); then
      rm -f "$restore_scan"
      akit_log error "cannot list the files to restore"
      return 1
    fi
    rm -f "$restore_scan"
  fi
  if ! printf '%s\n' "$restore_now" | while IFS= read -r restore_p; do
    case "$restore_p" in
      '' | */ | etc/auditd-kit/canary) continue ;;
    esac
    printf '%s\n' "$restore_list" | grep -x -F -e "$restore_p" >/dev/null && continue
    if akit_backup_ours "$restore_p"; then
      rm -f "$restore_root/$restore_p" || exit 1
    else
      akit_log warning "kept /$restore_p, which something other than auditd-kit added after the backup"
    fi
  done; then
    akit_log error "cannot remove the files added after the backup"
    return 1
  fi
  if ! tar -xzpf "$restore_archive" -C "$restore_root"; then
    akit_log error "cannot unpack backup $restore_archive"
    return 1
  fi
  if ! printf '%s\n' "$restore_list" | grep -x -F etc/auditd-kit/state >/dev/null; then
    rm -f "$(akit_path /etc/auditd-kit/canary)"
    rmdir "$(akit_path /etc/auditd-kit)" 2>/dev/null || true
  fi
  if [ -z "$AKIT_ROOT" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -R /etc/audit /etc/audisp /etc/rsyslog.d/40-auditd-kit.conf /etc/auditd-kit >/dev/null 2>&1 || true
  fi
}
