#!/bin/sh
# Check that the audit rules are loaded and that auditd records events.
#
# Usage: verify.sh
# AKIT_VERIFY_POLL sets the canary poll interval in seconds (default 1). The canary check polls for
# up to 10 seconds, so 0 makes it try 10 times with no wait.
#
# Prints one "check=<name> result=<pass|fail> detail=<text>" line per check. Exits 0 when every
# check passes and 2 when any fails. The only change it makes is writing to the canary file.

set -eu

verify_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$verify_root/lib/common.sh"

PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

verify_failed=0
verify_rules=$(akit_path /etc/audit/audit.rules)
verify_state=$(akit_path /etc/auditd-kit/state)
verify_canary=$(akit_path /etc/auditd-kit/canary)

# verify_report <name> <pass|fail> <detail>
verify_report() {
  printf 'check=%s result=%s detail=%s\n' "$1" "$2" "$3"
  [ "$2" = pass ] || verify_failed=1
}

verify_rule_count() {
  verify_expected=$(awk '/^-[aw][ \t]/ { n++ } END { print n + 0 }' "$verify_rules" 2>/dev/null) || verify_expected=
  if [ -z "$verify_expected" ] || [ ! -r "$verify_rules" ]; then
    verify_report rule_count fail "cannot read $verify_rules"
    return
  fi
  if ! verify_listed=$(auditctl -l 2>/dev/null); then
    verify_report rule_count fail "auditctl -l failed"
    return
  fi
  verify_loaded=$(printf '%s\n' "$verify_listed" | awk '/^-[aw][ \t]/ { n++ } END { print n + 0 }')
  if [ "$verify_loaded" -eq "$verify_expected" ]; then
    verify_report rule_count pass "$verify_loaded rules loaded"
  else
    verify_report rule_count fail "loaded $verify_loaded, expected $verify_expected"
  fi
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
  # ausearch parses -ts with the C locale's %x, which has a two-digit year. The event time is never before this second, so the search can't miss it.
  verify_start=$(date '+%m/%d/%y %H:%M:%S')
  if ! printf 'canary %s\n' "$verify_start" >"$verify_canary" 2>/dev/null; then
    verify_report canary fail "cannot write $verify_canary"
    return
  fi
  verify_tries=10
  [ "$verify_poll" -le 1 ] || verify_tries=$((10 / verify_poll))
  verify_i=0
  while [ "$verify_i" -lt "$verify_tries" ]; do
    if ausearch -k akit_canary -ts "$verify_start" >/dev/null 2>&1; then
      verify_report canary pass "event found"
      return
    fi
    verify_i=$((verify_i + 1))
    [ "$verify_poll" -eq 0 ] || sleep "$verify_poll"
  done
  verify_report canary fail "no akit_canary event within 10 seconds"
}

verify_rule_count
if [ -f "$verify_state" ]; then
  verify_files
  verify_canary_check
fi

if [ "$verify_failed" -eq 0 ]; then
  exit "$AKIT_EXIT_OK"
fi
exit "$AKIT_EXIT_FAILED"
