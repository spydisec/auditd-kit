#!/bin/sh
# Set up auditd on this host with the kit's rules and auditd.conf keys.
#
# Usage: install.sh [--config FILE] [setting flags] [--dry-run] [--skip-load]
#
# The stages run in this order. Nothing on the host changes before the backup.
#   1. preflight  survey.sh | preflight.sh, which refuses an unsafe host
#   2. render     render.sh builds this host's rules in a temp dir
#   3. validate   validate.sh checks the rule syntax in that dir
#   4. plan       plan.sh lists each change. --dry-run prints the plan and stops here
#   5. backup     saves the files that the next stages change
#   6. deploy     writes the rules, the auditd.conf keys, the syslog plugin setting, the rsyslog
#                 drop-in (checked with rsyslogd -N1), the canary, the report, and the state
#   7. load       augenrules --load when the rules changed, service rsyslog restart when the
#                 drop-in changed, service auditd restart when auditd.conf or the plugin changed
#   8. verify     verify.sh
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
for install_l in common settings lock backup state auditdconf rulesd load forward; do
  # shellcheck source=/dev/null
  . "$install_lib/$install_l.sh"
done
AKIT_SCRIPTS_DIR=$install_root
umask 022

# augenrules, auditctl, and service live in sbin, which may not be on PATH.
PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

AKIT_EXTRA_FLAGS="--dry-run --skip-load"
akit_settings_load "$@"
install_dry_run=no
install_skip_load=no
for install_a in $AKIT_ARGS; do
  case "$install_a" in
    --dry-run) install_dry_run=yes ;;
    --skip-load) install_skip_load=yes ;;
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

# preflight.sh and plan.sh get the same settings through a config file.
for install_k in $AKIT_SETTING_KEYS; do
  eval "install_v=\$$install_k"
  [ -z "$install_v" ] || printf '%s=%s\n' "$install_k" "$install_v"
done >"$install_work/settings.conf"

# 1. Preflight
sh "$install_root/survey.sh" >"$install_work/survey"
if ! install_out=$(sh "$install_lib/preflight.sh" --config "$install_work/settings.conf" \
  <"$install_work/survey" 2>&1); then
  printf '%s\n' "$install_out"
  case "$install_out" in
    *refuse=catchall_forward*) akit_forward_estimate "$install_root/stats.sh" ;;
  esac
  akit_die "$AKIT_EXIT_REFUSED" "preflight refused this host, and nothing changed"
fi
# The backup needs tar, and the load step restarts auditd with service. A minimal RHEL 10 host
# has neither, and RHEL 9 and later ship service in initscripts-service.
install_missing=
if [ "$install_dry_run" = no ] && ! command -v tar >/dev/null 2>&1; then
  install_missing="refuse=tar_missing override=install tar"
fi
if [ "$install_dry_run" = no ] && [ "$install_skip_load" = no ] && ! command -v service >/dev/null 2>&1; then
  install_missing="${install_missing:+$install_missing
}refuse=service_missing override=install initscripts-service"
fi
# Forwarding needs the plugin's config file. Refusing here also means that forward=local or
# remote in the state file always records a plugin that this install turned on.
if [ "$akit_forward" != none ] && ! akit_forward_plugin_file >/dev/null; then
  install_missing="${install_missing:+$install_missing
}refuse=syslog_plugin_missing override=install the audit syslog plugin (audispd-plugins)"
fi
if [ -n "$install_missing" ]; then
  printf '%s\n' "$install_missing"
  akit_die "$AKIT_EXIT_REFUSED" "preflight refused this host, and nothing changed"
fi

# 2. Render, into a temp dir with its report next to it.
set -- --profile "$akit_profile" --size "$akit_size" --immutable "$akit_immutable" \
  --out-dir "$install_work/rendered" --report "$install_work/render-report.txt"
[ -z "$akit_extra_rules_dir" ] || set -- "$@" --extra-dir "$akit_extra_rules_dir"
install_out=$(sh "$install_lib/render.sh" "$@") || akit_die "$AKIT_EXIT_REFUSED" "render failed, and nothing changed"
install_rule_count=$(printf '%s\n' "$install_out" | sed -n 's/^rule_count=//p')

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
cat "$install_work/changes"
if [ "$install_changes" -eq 0 ]; then
  akit_log info "nothing to change"
  echo "changes=0"
  install_stage=finished
  exit "$AKIT_EXIT_OK"
fi

# 5. Backup
install_backup=$(akit_backup_create) || akit_die "$AKIT_EXIT_REFUSED" "backup failed, and nothing changed"
akit_log info "backup $install_backup written"
install_stage=change

# 6. Deploy
install_rules=no
install_auditd=no
install_rsyslog=no
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
    add:"$AKIT_RSYSLOG_DROPIN" | change:"$AKIT_RSYSLOG_DROPIN") install_rsyslog=yes ;;
    move:"$AKIT_RSYSLOG_DROPIN")
      rm -f "$(akit_path "$install_path")" || install_fail "cannot remove $(akit_path "$install_path")"
      install_rsyslog=yes
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
install_want=$(akit_forward_plugin_want)
if [ "$install_want" != keep ] && install_plug=$(akit_forward_plugin_file); then
  akit_forward_plugin "$(akit_path "$install_plug")" "$install_want" || install_fail "cannot set $install_plug"
fi
if [ "$akit_forward" != none ]; then
  install_drop=$(akit_path "$AKIT_RSYSLOG_DROPIN")
  mkdir -p "$(dirname "$install_drop")" || install_fail "cannot create $(dirname "$install_drop")"
  akit_forward_render "$install_root/../config/rsyslog/40-auditd-kit.conf" "$install_work/dropin" \
    || install_fail "cannot read the rsyslog template"
  { cat "$install_work/dropin" >"$install_drop" && chmod 0644 "$install_drop"; } \
    || install_fail "cannot write $install_drop"
  akit_forward_check "$install_drop" || install_fail "rsyslogd -N1 rejected the drop-in"
  set -- "$@" "$AKIT_RSYSLOG_DROPIN"
fi
if ! { mkdir -p "$(akit_path /var/lib/auditd-kit)" \
  && cp "$install_work/render-report.txt" "$(akit_path /var/lib/auditd-kit/render-report.txt)"; }; then
  install_fail "cannot write the render report"
fi
install_targets=$(akit_forward_targets "$install_lib")
akit_state_write "$install_rule_count" "$install_targets" "$@" "$AKIT_AUDITD_CONF" \
  || install_fail "cannot write $AKIT_STATE_FILE"

if [ "$install_skip_load" = yes ]; then
  akit_log info "skipping load and verify"
else
  # 7. Load
  akit_load_apply "$install_rules" "$install_auditd" "$install_rsyslog" || install_fail "loading the rules or restarting auditd failed"
  # 8. Verify
  sh "$install_root/verify.sh" || install_fail "verify failed"
fi

install_stage=finished
akit_log info "install done with $install_changes changes, backup $install_backup"
echo "backup=$install_backup"
echo "changes=$install_changes"
