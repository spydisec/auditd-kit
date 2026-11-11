# Load rules, restart services, and roll back to a backup. Source this file after common.sh and
# backup.sh, don't run it. The caller sets AKIT_SCRIPTS_DIR to the dir that holds verify.sh.
# shellcheck shell=sh
#
# auditd is restarted with "service auditd restart", never systemctl, because the RHEL unit
# refuses a manual stop through systemctl. Command output goes to the log.

# akit_load_restart_auditd: restart auditd. An install and a rollback a few seconds apart can hit
# systemd's start limit, which refuses the start, so the failed state is cleared first (#58).
#
# With audit 4, auditd.service pulls in audit-rules.service, which runs augenrules --load after
# auditd starts. The restart doesn't wait for it, so the next auditctl call would race it. Starting
# audit-rules.service joins the queued start and waits until it ends. Its result isn't checked here,
# because verify.sh checks the loaded rules.
akit_load_restart_auditd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reset-failed auditd >/dev/null 2>&1 || true
  fi
  akit_load_run service auditd restart || return 1
  if command -v systemctl >/dev/null 2>&1 \
    && systemctl cat audit-rules.service >/dev/null 2>&1; then
    akit_load_run systemctl start audit-rules.service || true
  fi
  return 0
}

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
  if [ "$load_rc" -eq 0 ] && [ -n "${AKIT_LOG_FILE:-}" ] \
    && printf '%s\n' "$load_out" | sed "s/^/$(date '+%Y-%m-%dT%H:%M:%S') auditd-kit: info:   /" \
      >>"$AKIT_LOG_FILE" 2>/dev/null; then
    load_n=$(printf '%s\n' "$load_out" | wc -l | tr -d ' ')
    [ "$load_n" -eq 1 ] && load_lines=line || load_lines=lines
    akit_log info "  its output ($load_n $load_lines) is in $AKIT_LOG_FILE"
    # An error or a warning shows even when the command succeeds.
    printf '%s\n' "$load_out" | grep -iE 'error|warning|failed' | while IFS= read -r load_line; do
      akit_log info "  $load_line"
    done
  else
    printf '%s\n' "$load_out" | while IFS= read -r load_line; do
      akit_log info "  $load_line"
    done
  fi
  return "$load_rc"
}

# akit_load_apply <rules yes|no> <auditd yes|no>: load the rules with augenrules when they
# changed, then restart auditd when auditd.conf changed. Loading first means a rule that the
# kernel rejects fails here, with its error, and not later in auditd's start hook. The output of
# augenrules is left in akit_load_output.
akit_load_apply() {
  akit_load_output=
  if [ "$1" = yes ]; then
    akit_load_run augenrules --load || return 1
    # shellcheck disable=SC2034
    akit_load_output=$load_out
  fi
  if [ "$2" = yes ]; then
    akit_load_restart_auditd || return 1
  fi
}

# akit_load_errors: read the output of a load on stdin, and print one line for each rule that
# auditctl skipped, as "<copy|kit|kept> <rules.d file> <rule text>". A copy is a rule that was
# already loaded. Any other error is sorted by the file its rule came from. A rule that a kit file
# holds, or that no file holds, counts as the kit's. Source rulesd.sh before calling it.
akit_load_errors() {
  le_rules=$(akit_path /etc/audit/audit.rules)
  awk '/^There was an error in line [0-9]+/ { print $7 " " prev } { prev = $0 }' \
    | while read -r le_n le_msg; do
      le_text=$(sed -n "${le_n}p" "$le_rules")
      le_src=
      for le_f in $(akit_rulesd_files); do
        if grep -q -x -F -e "$le_text" "$(akit_path "$AKIT_RULES_D/$le_f")" 2>/dev/null; then
          le_src=$le_f
          ! akit_rulesd_is_ours "$le_f" || break
        fi
      done
      case "$le_msg" in
        *"Rule exists"*) printf '%s %s %s\n' copy "${le_src:-unknown}" "$le_text" ;;
        *)
          if [ -n "$le_src" ] && ! akit_rulesd_is_ours "$le_src"; then
            printf '%s %s %s\n' kept "$le_src" "$le_text"
          else
            printf '%s %s %s\n' kit "${le_src:-unknown}" "$le_text"
          fi
          ;;
      esac
    done
}

# akit_load_rule_keys: print the key names of the audit rules on stdin, one per line. A key is
# written as "-k name" or as "-F key=name".
akit_load_rule_keys() {
  awk '/^[ \t]*-[aAw]/ {
    for (i = 1; i <= NF; i++) {
      if ($i == "-k" && i < NF) print $(i + 1)
      else if ($i ~ /^key=/) print substr($i, 5)
    }
  }'
}

# akit_load_runtime_save <dir>: before a load, save the loaded rules and the keys that the
# rules.d files use. An agent such as Wazuh adds rules with auditctl when it starts, and the -D
# in our base file deletes them, so akit_load_runtime_restore puts them back. Call it before
# any rules.d file is written or removed. Source rulesd.sh first.
akit_load_runtime_save() {
  auditctl -l >"$1/loaded-before" 2>/dev/null || : >"$1/loaded-before"
  for rt_f in $(akit_rulesd_files); do
    akit_load_rule_keys <"$(akit_path "$AKIT_RULES_D/$rt_f")" 2>/dev/null || true
  done | sort -u >"$1/file-keys"
}

# akit_load_runtime_restore <dir>: after a load, add each rule that was loaded before, is gone
# now, and has a key that no rules.d file used. A rule with no key isn't put back, because it
# can't be told from a rule of a file that install changed or removed. A rule that doesn't split
# into flag and value pairs, e.g. a path with a space, and a rule that auditctl rejects get a
# warning. When the load locked the rules (-e 2), nothing can be added, so the rules are only
# named. Always succeeds.
akit_load_runtime_restore() {
  rt_dir=$1
  auditctl -l >"$rt_dir/loaded-after" 2>/dev/null || return 0
  grep -v -x -F -f "$rt_dir/loaded-after" "$rt_dir/loaded-before" >"$rt_dir/missing" 2>/dev/null || true
  rt_locked=no
  ! akit_load_locked || rt_locked=yes
  while IFS= read -r rt_line; do
    rt_keys=$(printf '%s\n' "$rt_line" | akit_load_rule_keys)
    [ -n "$rt_keys" ] || continue
    # An empty pattern file matches every line in some greps, so it is skipped.
    if [ -s "$rt_dir/file-keys" ] \
      && printf '%s\n' "$rt_keys" | grep -q -x -F -f "$rt_dir/file-keys" 2>/dev/null; then
      continue
    fi
    if [ "$rt_locked" = yes ]; then
      akit_log warning "the rules are locked until reboot (-e 2), so this rule that was loaded before the install is gone: $rt_line"
      continue
    fi
    if ! printf '%s\n' "$rt_line" \
      | awk '{ if (NF % 2) exit 1; for (i = 1; i <= NF; i += 2) if ($i !~ /^-/) exit 1 }'; then
      akit_log warning "could not put back: $rt_line"
      continue
    fi
    set -f
    # shellcheck disable=SC2086
    set -- $rt_line
    set +f
    if auditctl "$@" >/dev/null 2>&1; then
      akit_log info "put back: $rt_line"
    else
      akit_log warning "could not put back: $rt_line"
    fi
  done <"$rt_dir/missing"
  return 0
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

# akit_load_locked: succeed when the loaded rules are locked until reboot (auditctl -s shows
# enabled 2). Then auditctl can't delete or add rules, and only a reboot loads new ones.
akit_load_locked() {
  load_en=$(auditctl -s 2>/dev/null | awk '{
    gsub(/=/, " ")
    for (i = 1; i < NF; i++) if ($i == "enabled") { print $(i + 1); exit }
  }')
  [ "$load_en" = 2 ]
}

# akit_rollback <backup-id> <skip-load yes|no>: restore the backup, then restart auditd when its
# config or plugin files changed, load the restored audit.rules, and run verify.sh. Fails when any
# step fails, which leaves the host for a person.
# When the rules are locked, it restores only the files, sets akit_reboot_needed=yes, and logs that
# a reboot loads them, because restarting auditd or loading rules would fail.
akit_rollback() {
  # shellcheck disable=SC2034
  akit_reboot_needed=no
  rb_auditd='/etc/audit/auditd.conf /etc/audit/plugins.d /etc/audisp'
  rb_auditd_before=$(akit_load_sums "$rb_auditd")
  akit_log info "restoring backup $1"
  akit_backup_restore "$1" || return 1
  [ "$2" = no ] || return 0
  if akit_load_locked; then
    # shellcheck disable=SC2034
    akit_reboot_needed=yes
    akit_log warning "the audit rules are locked until reboot (-e 2), so backup $1 is restored on disk and takes effect after a reboot"
    return 0
  fi
  if [ "$(akit_load_sums "$rb_auditd")" != "$rb_auditd_before" ]; then
    akit_load_restart_auditd || return 1
    # auditd's start hook runs augenrules, which can rewrite audit.rules and add audit.rules.prev,
    # so the files are restored once more.
    akit_backup_restore "$1" || return 1
  fi
  # The restored audit.rules is loaded as it is. augenrules could rebuild it from rules.d.
  akit_load_run auditctl -D || return 1
  akit_load_run auditctl -R "$(akit_path /etc/audit/audit.rules)" || return 1
  sh "$AKIT_SCRIPTS_DIR/verify.sh" || return 1
}
