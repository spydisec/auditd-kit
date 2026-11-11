#!/bin/sh
# Set up auditd on this host with the kit's rules and auditd.conf keys.
#
# Usage: install.sh [--config FILE] [setting flags] [--dry-run] [--skip-load] [--guided]
#
# --guided shows a summary of the host, asks for the main settings on the terminal, and asks again
# before it changes anything. Settings given as flags or in the config file are the defaults.
#
# The stages run in this order. Nothing on the host changes before the backup.
#   1. host check hostcheck.sh, which refuses a host where auditd-kit can't work
#   2. render     render.sh builds this host's rules in a temp dir
#   3. validate   validate.sh checks the rule syntax in that dir
#   4. plan       plan.sh lists each change. --dry-run prints the plan and stops here
#   5. backup     saves the files that the next stages change
#   6. deploy     writes the rules, the auditd.conf keys, the canary, the report, and the state
#   7. load       augenrules --load when the rules changed, service auditd restart when
#                 auditd.conf changed
#   8. verify     verify.sh
# When the rules are locked until reboot (-e 2), stages 7 and 8 are skipped, the last line is
# reboot=required, and a reboot loads the new files.
# A failure after the backup restores it. --skip-load skips load and verify, and is only for
# tests in containers, where the kernel audit system can't be used.
#
# Prints the plan's change lines and ends with changes=<n>. A run with nothing to change prints
# changes=0 and makes no backup. Exits 0 when done, 1 when refused with nothing changed, 2 when it
# failed and the backup was restored, and 3 when the restore failed too and a person must fix the
# host. Each run logs to /var/log/auditd-kit/install-<time>.log.
# shellcheck disable=SC2034,SC2154
set -eu

install_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
install_lib=$install_root/lib
for install_l in common settings backup auditdconf rulesd load; do
  # shellcheck source=/dev/null
  . "$install_lib/$install_l.sh"
done
AKIT_SCRIPTS_DIR=$install_root
umask 022

# augenrules, auditctl, and service live in sbin, which may not be on PATH.
PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

AKIT_EXTRA_FLAGS="--dry-run --skip-load --guided"
akit_settings_load "$@"
install_dry_run=no
install_skip_load=no
install_guided=no
for install_a in $AKIT_ARGS; do
  case "$install_a" in
    --dry-run) install_dry_run=yes ;;
    --skip-load) install_skip_load=yes ;;
    --guided) install_guided=yes ;;
    *) akit_die "$AKIT_EXIT_REFUSED" "unknown argument: $install_a" ;;
  esac
done

# The stage is "check" until the backup exists, then "change", then "finished". The exit trap
# turns any failure in "change" into a restore of the backup.
install_stage=check
install_backup=
install_work=

install_on_exit() {
  install_rc=$?
  # A failing command here must not stop the restore.
  set +e
  trap - EXIT
  # A signal must not stop the restore halfway.
  trap '' INT TERM HUP
  if [ "$install_stage" = change ]; then
    akit_log error "install failed, restoring backup $install_backup"
    if akit_rollback "$install_backup" "$install_skip_load"; then
      akit_log error "install failed, and backup $install_backup was restored"
      [ "$akit_reboot_needed" = no ] || akit_log error "the rules are locked until reboot, so reboot to load the restored files"
      install_rc=$AKIT_EXIT_FAILED
    else
      akit_log error "rollback failed. Restore backup $install_backup by hand with rollback.sh, or fix the host."
      install_rc=$AKIT_EXIT_ROLLBACK_FAILED
    fi
  elif [ "$install_stage" = check ] && [ "$install_rc" -ne 0 ]; then
    # Nothing changed before the backup, so every failure there is a refusal.
    install_rc=$AKIT_EXIT_REFUSED
  fi
  [ -z "$install_work" ] || rm -rf "$install_work"
  akit_lock_release
  exit "$install_rc"
}

# install_fail <message>: log the message and exit through the trap.
install_fail() {
  akit_log error "$1"
  exit "$AKIT_EXIT_FAILED"
}

akit_lock_take
trap install_on_exit EXIT
trap 'exit 1' INT TERM HUP

install_log_dir=$(akit_path /var/log/auditd-kit)
if mkdir -p "$install_log_dir" 2>/dev/null; then
  AKIT_LOG_FILE="$install_log_dir/install-$(date -u '+%Y%m%dT%H%M%SZ').log"
else
  akit_log warning "cannot create $install_log_dir, so this run is not logged"
fi
akit_log info "install $AKIT_VERSION started: $*"

install_work=$(mktemp -d) || akit_die "$AKIT_EXIT_REFUSED" "cannot create a temp dir"

# install_write_settings: write the current settings to the config file that hostcheck.sh and
# plan.sh read, so that they get the same settings.
install_write_settings() {
  for install_k in $AKIT_SETTING_KEYS; do
    eval "install_v=\$$install_k"
    [ -z "$install_v" ] || printf '%s=%s\n' "$install_k" "$install_v"
  done >"$install_work/settings.conf"
}

# install_ask <question> <default>: ask on the terminal, and set install_ans to the answer or
# to the default when the answer is empty.
install_ask() {
  printf '%s ' "$1" >/dev/tty
  IFS= read -r install_ans </dev/tty || install_ans=
  [ -n "$install_ans" ] || install_ans=$2
}

# install_hostcheck: run the host check with the current settings, and keep its output.
install_hostcheck() {
  install_write_settings
  install_need_tar=yes
  install_need_service=yes
  [ "$install_dry_run" = no ] || install_need_tar=no
  { [ "$install_dry_run" = no ] && [ "$install_skip_load" = no ]; } || install_need_service=no
  install_need_kernel=yes
  [ "$install_skip_load" = no ] || install_need_kernel=no
  HOSTCHECK_NEED_TAR=$install_need_tar HOSTCHECK_NEED_SERVICE=$install_need_service \
    HOSTCHECK_NEED_KERNEL=$install_need_kernel \
    sh "$install_lib/hostcheck.sh" --config "$install_work/settings.conf" >"$install_work/hostcheck" 2>&1
}

# install_host_get <key>: print a fact from the host check.
install_host_get() {
  sed -n "s/^$1=//p" "$install_work/hostcheck" | head -n 1
}

# install_refused <pattern>: print the refusals that don't match the grep pattern, and stop when
# there are any.
install_refused() {
  install_hard=$(grep '^refuse=' "$install_work/hostcheck" | { grep -v -e "$1" || true; })
  [ -n "$install_hard" ] || return 0
  printf '%s\n' "$install_hard"
  akit_die "$AKIT_EXIT_REFUSED" "the host check refused this host, and nothing changed"
}

# install_warnings: log the warnings of the host check.
install_warnings() {
  sed -n 's/^warn=[^ ]* detail=//p' "$install_work/hostcheck" | while IFS= read -r install_w; do
    akit_log warning "$install_w"
  done
}

# Guided mode: show the host, then ask only what applies to it.
if [ "$install_guided" = yes ]; then
  (: </dev/tty) 2>/dev/null || akit_die "$AKIT_EXIT_REFUSED" "--guided needs a terminal"
  install_hostcheck || true
  {
    echo "auditd-kit $AKIT_VERSION on $(install_host_get os_id) $(install_host_get os_version)"
    echo "  auditd $(install_host_get auditd_version), $(install_host_get audit_log_free_mb) MB free for logs"
  } >/dev/tty
  # Stop on a refusal before asking anything.
  install_refused '^$'
  case "$akit_profile" in minimal) install_d=1 ;; medium) install_d=2 ;; *) install_d=3 ;; esac
  install_ask "Profile? 1) minimal, for every server  2) medium, for critical servers  3) heavy, for CIS or STIG [$install_d]:" "$install_d"
  case "$install_ans" in
    1) akit_settings_set akit_profile minimal ;;
    2) akit_settings_set akit_profile medium ;;
    3) akit_settings_set akit_profile heavy ;;
    *) akit_settings_set akit_profile "$install_ans" ;;
  esac
  if [ "$akit_profile" = heavy ] && [ "$akit_immutable" = false ]; then
    install_ask "Lock the rules until reboot (-e 2), as CIS and STIG expect? Every later rule change, rollback too, then needs a reboot. [y/N]:" n
    case "$install_ans" in
      [yY]*) akit_settings_set akit_immutable true ;;
    esac
  fi
fi

# 1. Host check
if ! install_hostcheck; then
  install_warnings
  install_refused '^$'
  cat "$install_work/hostcheck"
  akit_die "$AKIT_EXIT_REFUSED" "the host check failed, and nothing changed"
fi
install_warnings
# With locked rules (-e 2) nothing can be loaded until a reboot. Install then writes the files,
# and the reboot loads them.
install_locked=no
[ "$(install_host_get audit_enabled)" != 2 ] || install_locked=yes

# 2. Render, into a temp dir with its report next to it.
set -- --profile "$akit_profile" --size "$akit_size" --immutable "$akit_immutable" \
  --out-dir "$install_work/rendered" --report "$install_work/render-report.txt"
[ -z "$akit_skip_keys" ] || set -- "$@" --skip-keys "$akit_skip_keys"
install_out=$(sh "$install_root/render.sh" "$@") || akit_die "$AKIT_EXIT_REFUSED" "render failed, and nothing changed"
install_rule_count=$(printf '%s\n' "$install_out" | sed -n 's/^rule_count=//p')
install_dropped=$(grep -c . "$install_work/render-report.txt" || true)
if [ "$install_dropped" -gt 0 ]; then
  akit_log info "render left out or trimmed $install_dropped rules that this host can't load. An install lists them in /var/lib/auditd-kit/render-report.txt"
fi

# 3. Validate
if ! install_out=$(sh "$install_lib/validate.sh" "$install_work/rendered" 2>&1); then
  printf '%s\n' "$install_out"
  akit_die "$AKIT_EXIT_REFUSED" "the rendered rules failed the syntax check, and nothing changed"
fi

# 4. Plan
sh "$install_lib/plan.sh" "$install_work/rendered" --config "$install_work/settings.conf" \
  >"$install_work/plan"
grep -E '^(add|change|move|set) ' "$install_work/plan" >"$install_work/changes" || true
install_changes=$(wc -l <"$install_work/changes" | tr -d ' ')
if [ -n "${AKIT_LOG_FILE:-}" ]; then
  cat "$install_work/plan" >>"$AKIT_LOG_FILE"
fi
if [ "$install_dry_run" = yes ]; then
  cat "$install_work/plan"
  echo "changes=$install_changes"
  install_stage=finished
  exit "$AKIT_EXIT_OK"
fi
if [ "$install_guided" = yes ] && [ "$install_changes" -gt 0 ]; then
  cat "$install_work/changes"
  echo "To see each change in full first, run install.sh with --dry-run."
  install_ask "Apply these $install_changes changes? [y/N]:" n
  case "$install_ans" in
    [yY]*) ;;
    *)
      akit_log info "cancelled, and nothing changed"
      echo cancelled
      echo "changes=0"
      install_stage=finished
      exit "$AKIT_EXIT_OK"
      ;;
  esac
else
  cat "$install_work/changes"
fi
if [ "$install_changes" -eq 0 ]; then
  akit_log info "nothing to change"
  echo "changes=0"
  install_stage=finished
  exit "$AKIT_EXIT_OK"
fi

# The rules that are loaded now, some of which an agent may have added at run time.
if [ "$install_skip_load" = no ] && [ "$install_locked" = no ]; then
  akit_load_runtime_save "$install_work"
fi

# 5. Backup
install_backup=$(akit_backup_create) || akit_die "$AKIT_EXIT_REFUSED" "backup failed, and nothing changed"
akit_log info "backup $install_backup written"
install_stage=change

# 6. Deploy
install_rules=no
install_auditd=no
set --
for install_f in "$install_work/rendered"/*.rules; do
  set -- "$@" "$AKIT_RULES_D/${install_f##*/}"
done
AKIT_BACKUP_ADDED=$*
for install_d in /etc/auditd-kit "$AKIT_RULES_D"; do
  mkdir -p "$(akit_path "$install_d")" || install_fail "cannot create $(akit_path "$install_d")"
done
install_canary=$(akit_path /etc/auditd-kit/canary)
if [ ! -e "$install_canary" ]; then
  { : >"$install_canary" && chmod 0600 "$install_canary"; } || install_fail "cannot create $install_canary"
fi
while read -r install_verb install_path install_key; do
  case "$install_verb:$install_path" in
    add:/etc/audit/rules.d/* | change:/etc/audit/rules.d/*)
      install_dst=$(akit_path "$install_path")
      { cat "$install_work/rendered/${install_path##*/}" >"$install_dst" && chmod 0640 "$install_dst"; } \
        || install_fail "cannot write $install_dst"
      install_rules=yes
      ;;
    move:/etc/audit/rules.d/*)
      rm -f "$(akit_path "$install_path")" || install_fail "cannot remove $(akit_path "$install_path")"
      install_rules=yes
      ;;
    set:*) install_auditd=yes ;;
  esac
  akit_log info "$install_verb $install_path${install_key:+ $install_key}"
done <"$install_work/changes"
install_conf=$(akit_path "$AKIT_AUDITD_CONF")
akit_auditdconf_wanted "$install_root/.." >"$install_work/wanted" || install_fail "cannot read the auditd.conf preset"
while read -r install_k install_v; do
  akit_auditdconf_set "$install_conf" "$install_k" "$install_v" || install_fail "cannot set $install_k in $install_conf"
done <"$install_work/wanted"
if ! { mkdir -p "$(akit_path /var/lib/auditd-kit)" \
  && cp "$install_work/render-report.txt" "$(akit_path /var/lib/auditd-kit/render-report.txt)"; }; then
  install_fail "cannot write the render report"
fi
akit_state_write "$install_rule_count" "$@" "$AKIT_AUDITD_CONF" \
  || install_fail "cannot write $AKIT_STATE_FILE"

if [ "$install_skip_load" = yes ]; then
  akit_log info "skipping load and verify"
elif [ "$install_locked" = yes ]; then
  # The reboot will skip each rule of ours that a kept file also holds, so those don't count.
  install_copies=0
  for install_f in "$install_work/rendered"/*.rules; do
    while IFS= read -r install_rule; do
      case "$install_rule" in -a* | -w*) ;; *) continue ;; esac
      for install_o in $(install_host_get rules_d_foreign | tr ',' ' '); do
        if grep -q -x -F -e "$install_rule" "$(akit_path "$AKIT_RULES_D/$install_o")" 2>/dev/null; then
          install_copies=$((install_copies + 1))
          break
        fi
      done
    done <"$install_f"
  done
  akit_state_set_loaded "$((install_rule_count - install_copies))" || install_fail "cannot write $AKIT_STATE_FILE"
  akit_log warning "the audit rules are locked until reboot (-e 2), so the new files are written but not loaded or checked. Reboot, then run verify.sh. If the new rules fail after the reboot, run rollback.sh and reboot again"
else
  # 7. Load
  akit_load_apply "$install_rules" "$install_auditd" || install_fail "loading the rules or restarting auditd failed"
  # The base file holds -i, so the load went on past each line that failed. A copy of a loaded
  # rule is fine, and so is a bad line in a file that auditd-kit didn't write, which failed
  # before the install too. Any other error is ours.
  install_bad=no
  install_copies=0
  if [ "$install_rules" = yes ]; then
    printf '%s\n' "$akit_load_output" | akit_load_errors >"$install_work/load-errors"
    while read -r install_class install_src install_rule; do
      case "$install_class" in
        copy)
          akit_log info "already loaded, skipped: $install_rule"
          install_copies=$((install_copies + 1))
          ;;
        kept) akit_log warning "$install_src has a rule that didn't load: $install_rule" ;;
        *)
          akit_log error "$install_src has a rule that didn't load: $install_rule"
          install_bad=yes
          ;;
      esac
    done <"$install_work/load-errors"
  fi
  [ "$install_bad" = no ] || install_fail "an auditd-kit rule failed to load"
  # verify.sh later passes on at least our own rule count, less the copies that were skipped. The
  # rules of other files don't count, so that removing one of them later doesn't fail verify.
  install_floor=$((install_rule_count - install_copies))
  install_loaded=$(auditctl -l 2>/dev/null | awk '/^-[aw][ \t]/ { n++ } END { print n + 0 }')
  [ "$install_loaded" -ge "$install_floor" ] && [ "$install_loaded" -gt 0 ] \
    || install_fail "$install_loaded rules are loaded, and at least $install_floor were expected"
  akit_state_set_loaded "$install_floor" || install_fail "cannot write $AKIT_STATE_FILE"
  # The rules are counted before the put-back, so a rule that is put back never makes up for a
  # rule of ours that didn't load.
  [ "$install_rules" = no ] || akit_load_runtime_restore "$install_work"
  # 8. Verify
  sh "$install_root/verify.sh" || install_fail "verify failed"
fi

install_stage=finished
akit_log info "install done with $install_changes changes, backup $install_backup"
echo "backup=$install_backup"
echo "changes=$install_changes"
[ "$install_locked" = no ] || echo "reboot=required"
