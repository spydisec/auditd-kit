#!/bin/sh
# Check that the audit rules are loaded and that auditd records events.
#
# Usage: verify.sh
# AKIT_VERIFY_POLL sets the canary poll interval in seconds (default 1). The canary check polls for
# up to 10 seconds, so 0 makes it try 10 times with no wait.
#
# Prints one "check=<name> result=<pass|warn|fail> detail=<text>" line per check. Exits 0 when no
# check fails and 2 when any fails. A warning doesn't change the exit code. The checks:
#   status   auditd is running and the kernel has auditing on
#   rules    each rule in the /etc/audit/rules.d files is loaded, compared key by key. A missing
#            rule of ours fails, and a missing rule of another file is an other_rules warning
#   files, canary, lost   only after an install: the files install wrote are unchanged, a test
#            event is recorded, and no events were dropped
# The only change it makes is writing to the canary file.

set -eu

verify_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$verify_root/lib/common.sh"
# shellcheck source=/dev/null
. "$verify_root/lib/rulesd.sh"

PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

verify_failed=0
verify_state=$(akit_path /etc/auditd-kit/state)
verify_canary=$(akit_path /etc/auditd-kit/canary)

# verify_report <name> <pass|warn|fail> <detail>
verify_report() {
  printf 'check=%s result=%s detail=%s\n' "$1" "$2" "$3"
  [ "$2" != fail ] || verify_failed=1
}

# verify_status_field <name> <status text>: print the number that auditctl -s gives for a field.
# Newer auditctl prints "name N" lines, and older auditctl prints name=N on one line.
verify_status_field() {
  printf '%s\n' "$2" | awk -v want="$1" '{
    gsub(/=/, " ")
    for (i = 1; i < NF; i++) if ($i == want && $(i + 1) ~ /^[0-9]+$/) { print $(i + 1); f = 1; exit }
  } END { exit !f }'
}

verify_status() {
  if ! verify_s=$(auditctl -s 2>/dev/null); then
    verify_report status fail "auditctl -s failed"
    return
  fi
  verify_enabled=$(verify_status_field enabled "$verify_s") || verify_enabled=
  verify_pid=$(verify_status_field pid "$verify_s") || verify_pid=0
  # Older auditctl calls the failure mode "flag".
  verify_mode=$(verify_status_field failure "$verify_s") \
    || verify_mode=$(verify_status_field flag "$verify_s") || verify_mode=
  if [ "$verify_enabled" = 0 ] || [ -z "$verify_enabled" ]; then
    verify_report status fail "auditing is turned off in the kernel (enabled ${verify_enabled:-unknown})"
  elif [ "$verify_pid" -eq 0 ]; then
    verify_report status fail "auditd is not running"
  else
    verify_report status pass "auditd is running, enabled $verify_enabled"
  fi
  [ "$verify_mode" != 2 ] \
    || verify_report failure_mode warn "the failure mode is 2, so the kernel panics the host when auditing fails"
}

# Compare the rules in the rules.d files with the loaded rules, key by key. The kernel prints a
# rule differently from how a file writes it, so the lines can't be compared as text. A key with
# fewer loaded rules than our own files hold fails. A key that is short only when the rules of
# other files are counted is a warning, because those rules may not have loaded before the
# install either. The state file lists the copies that install saw the load skip, which aren't
# expected. Rules that an agent adds at run time have their own keys, so they don't hide a
# missing rule.
verify_rules() {
  if ! verify_listed=$(auditctl -l 2>/dev/null); then
    verify_report rules fail "auditctl -l failed"
    return
  fi
  verify_found=$({
    for verify_f in $(akit_rulesd_files); do
      verify_tag=other
      ! akit_rulesd_is_ours "$verify_f" || verify_tag=kit
      verify_p=$(akit_path "$AKIT_RULES_D/$verify_f")
      [ -r "$verify_p" ] || continue
      akit_rule_keys <"$verify_p" | sed "s/^/$verify_tag /"
    done
    printf '%s\n' "$verify_listed" | akit_rule_keys | sed 's/^/loaded /'
    sed -n 's/^skip=//p' "$verify_state" 2>/dev/null
  } | awk '
    $1 == "kit" { kit[$2]++; keys[$2] }
    $1 == "other" { other[$2]++; keys[$2] }
    $1 == "loaded" { loaded[$2]++; total++ }
    $1 == "copy" { copy[$2]++ }
    END {
      for (k in keys) {
        want = kit[k] + other[k] - copy[k]
        short = want - loaded[k]
        if (short <= 0) continue
        item = (k == "-" ? "rules with no key" : k) " (" loaded[k] + 0 " of " want ")"
        if (loaded[k] < kit[k] - copy[k]) bad = bad (bad ? ", " : "") item
        else warn = warn (warn ? ", " : "") item
      }
      print total + 0
      print bad
      print warn
    }')
  verify_loaded=$(printf '%s\n' "$verify_found" | sed -n 1p)
  verify_bad=$(printf '%s\n' "$verify_found" | sed -n 2p)
  verify_warn=$(printf '%s\n' "$verify_found" | sed -n 3p)
  if [ -n "$verify_bad" ]; then
    verify_report rules fail "auditd-kit rules are not loaded, by key: $verify_bad"
  else
    verify_report rules pass "$verify_loaded rules loaded"
  fi
  [ -z "$verify_warn" ] \
    || verify_report other_rules warn "other rule files hold rules that are not loaded, by key: $verify_warn"
}

verify_files() {
  if [ ! -r "$verify_state" ]; then
    verify_report files fail "cannot read $verify_state"
    return
  fi
  verify_bad=
  while IFS= read -r verify_line; do
    case "$verify_line" in
      file=*) ;;
      *) continue ;;
    esac
    verify_rest=${verify_line#file=}
    verify_sum=${verify_rest%% *}
    verify_file=${verify_rest#* }
    verify_now=$(sha256sum "$(akit_path "$verify_file")" 2>/dev/null | awk '{ print $1 }') || verify_now=
    if [ "$verify_now" != "$verify_sum" ]; then
      verify_bad="${verify_bad:+$verify_bad }$verify_file"
    fi
  done <"$verify_state"
  if [ -z "$verify_bad" ]; then
    verify_report files pass "all recorded checksums match"
  else
    verify_report files fail "changed or missing: $verify_bad"
  fi
}

verify_canary_check() {
  verify_poll=${AKIT_VERIFY_POLL:-1}
  case "$verify_poll" in
    '' | *[!0-9]*) verify_poll=1 ;;
  esac
  # ausearch reads stdin when it isn't a terminal, so --input-logs makes it read the audit logs.
  # ausearch -ts takes the date and the time as two arguments. It parses the date with the C
  # locale's %x, which has a two-digit year. One date call gives both, so they are from the same
  # moment.
  verify_start=$(date '+%m/%d/%y %H:%M:%S')
  verify_date=${verify_start% *}
  verify_time=${verify_start#* }
  # The kernel stamps an event with a clock that runs a few ms behind the one date reads. So an
  # event written right after the start time can carry the second before it, and ausearch -ts
  # would skip it. Waiting one second puts the event after the start time.
  [ "$verify_poll" -eq 0 ] || sleep 1
  if ! printf 'canary %s\n' "$verify_start" >"$verify_canary" 2>/dev/null; then
    verify_report canary fail "cannot write $verify_canary"
    return
  fi
  verify_tries=10
  [ "$verify_poll" -le 1 ] || verify_tries=$((10 / verify_poll))
  verify_i=0
  while [ "$verify_i" -lt "$verify_tries" ]; do
    if ausearch --input-logs -k akit_canary -ts "$verify_date" "$verify_time" >/dev/null 2>&1; then
      verify_report canary pass "event found"
      return
    fi
    verify_i=$((verify_i + 1))
    [ "$verify_poll" -eq 0 ] || sleep "$verify_poll"
  done
  verify_report canary fail "no akit_canary event within 10 seconds"
}

# verify_lost_count: print the kernel's lost event count.
verify_lost_count() {
  verify_ls=$(auditctl -s 2>/dev/null) || return 1
  verify_status_field lost "$verify_ls"
}

# The kernel counts events it dropped because the backlog was full or the rate limit was hit.
# A count that grew during the canary check means the rules log more than the host can keep.
verify_lost() {
  if [ -z "$verify_lost_before" ] || ! verify_lost_after=$(verify_lost_count); then
    verify_report lost fail "auditctl -s shows no lost count"
    return
  fi
  if [ "$verify_lost_after" -gt "$verify_lost_before" ]; then
    verify_report lost fail "the lost count rose by $((verify_lost_after - verify_lost_before)) during the canary check. Use a larger akit_size or a lighter profile."
  else
    verify_report lost pass "no events dropped during the canary check"
  fi
}

verify_status
verify_rules
if [ -f "$verify_state" ]; then
  verify_files
  verify_lost_before=$(verify_lost_count) || verify_lost_before=
  verify_canary_check
  verify_lost
fi

if [ "$verify_failed" -eq 0 ]; then
  exit "$AKIT_EXIT_OK"
fi
exit "$AKIT_EXIT_FAILED"
