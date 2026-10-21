# Load rules, restart services, and roll back to a backup. Source this file after common.sh and
# backup.sh, don't run it. The caller sets AKIT_SCRIPTS_DIR to the dir that holds verify.sh.
# shellcheck shell=sh
#
# auditd is restarted with "service auditd restart", never systemctl, because the RHEL unit
# refuses a manual stop through systemctl. Command output goes to the log.

# akit_load_run <command>...: run a command and keep its exit code. When it succeeds and there is
# a log file, its output goes only to the log, because augenrules prints a note for each watch
# rule. When it fails, or there is no log file, the output is shown too.
akit_load_run() {
  akit_log info "running: $*"
  if load_out=$("$@" 2>&1); then
    load_rc=0
  else
    load_rc=$?
  fi
  [ -n "$load_out" ] || return "$load_rc"
  if [ "$load_rc" -eq 0 ] && [ -n "${AKIT_LOG_FILE:-}" ]; then
    printf '%s\n' "$load_out" | sed "s/^/$(date '+%Y-%m-%dT%H:%M:%S') auditd-kit: info:   /" \
      >>"$AKIT_LOG_FILE" 2>/dev/null || true
    load_n=$(printf '%s\n' "$load_out" | wc -l | tr -d ' ')
    [ "$load_n" -eq 1 ] && load_lines=line || load_lines=lines
    akit_log info "  its output ($load_n $load_lines) is in $AKIT_LOG_FILE"
  else
    printf '%s\n' "$load_out" | while IFS= read -r load_line; do
      akit_log info "  $load_line"
    done
  fi
  return "$load_rc"
}

# akit_load_apply <rules yes|no> <auditd yes|no> <rsyslog yes|no>: load the rules with augenrules
# when they changed, then restart rsyslog when our drop-in changed, then restart auditd when
# auditd.conf or the syslog plugin changed. Loading first means a rule that the kernel rejects
# fails here, with its error, and not later in auditd's start hook. rsyslog restarts before
# auditd so that the drop-in is in effect when the plugin starts to write.
akit_load_apply() {
  if [ "$1" = yes ]; then
    akit_load_run augenrules --load || return 1
  fi
  if [ "${3:-no}" = yes ]; then
    akit_load_run service rsyslog restart || return 1
  fi
  if [ "$2" = yes ]; then
    akit_load_run service auditd restart || return 1
  fi
}

# akit_load_sums <paths>: print a checksum line for each file in the paths, which may be dirs.
akit_load_sums() {
  for load_p in $1; do
    load_abs=$(akit_path "$load_p")
    for load_f in "$load_abs" "$load_abs"/* "$load_abs"/plugins.d/*; do
      [ -f "$load_f" ] && sha256sum "$load_f"
    done
  done
  return 0
}

# akit_rollback <backup-id> <skip-load yes|no>: restore the backup, then restart auditd when its
# config or plugin files changed, load the restored audit.rules, restart rsyslog when our drop-in
# changed, and run verify.sh. Fails when any step fails, which leaves the host for a person.
akit_rollback() {
  rb_auditd='/etc/audit/auditd.conf /etc/audit/plugins.d /etc/audisp'
  rb_rsyslog=/etc/rsyslog.d/40-auditd-kit.conf
  rb_auditd_before=$(akit_load_sums "$rb_auditd")
  rb_rsyslog_before=$(akit_load_sums "$rb_rsyslog")
  akit_log info "restoring backup $1"
  akit_backup_restore "$1" || return 1
  [ "$2" = no ] || return 0
  if [ "$(akit_load_sums "$rb_auditd")" != "$rb_auditd_before" ]; then
    akit_load_run service auditd restart || return 1
    # auditd's start hook runs augenrules, which can rewrite audit.rules and add audit.rules.prev,
    # so the files are restored once more.
    akit_backup_restore "$1" || return 1
  fi
  # The restored audit.rules is loaded as it is. augenrules could rebuild it from rules.d.
  akit_load_run auditctl -D || return 1
  akit_load_run auditctl -R "$(akit_path /etc/audit/audit.rules)" || return 1
  if [ "$(akit_load_sums "$rb_rsyslog")" != "$rb_rsyslog_before" ]; then
    akit_load_run service rsyslog restart || return 1
  fi
  sh "$AKIT_SCRIPTS_DIR/verify.sh" || return 1
}
