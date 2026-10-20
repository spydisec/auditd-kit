#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016,SC2030,SC2031

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
verify="$repo/scripts/verify.sh"

setup() {
  akit_fixture_root
  mkdir -p "$AKIT_ROOT/etc/audit" "$AKIT_ROOT/etc/auditd-kit"
  printf '%s\n' '## header' '-D' '-b 8192' '' '-w /etc/passwd -p wa -k id' \
    '-a always,exit -F arch=b64 -S execve -k exec' >"$AKIT_ROOT/etc/audit/audit.rules"
  export AKIT_VERIFY_POLL=0
  stub_auditctl 2
  stub_ausearch found
}

# stub_auditctl <n> [<status line>]: auditctl -l prints n rule lines, or "No rules" when n is 0.
# auditctl -s prints the status line, "lost 0" by default.
stub_auditctl() {
  akit_stub auditctl "if [ \"\$1\" = -s ]; then echo '${2:-lost 0}'; elif [ $1 -eq 0 ]; then echo 'No rules'; else i=0; while [ \$i -lt $1 ]; do echo '-w /x -p wa -k k'; i=\$((i + 1)); done; fi"
}

# stub_ausearch <found|none>: record the arguments in $AKIT_ROOT/ausearch.args.
stub_ausearch() {
  if [ "$1" = found ]; then
    akit_stub ausearch 'printf "%s\\n" "$@" >"$AKIT_ROOT/ausearch.args"; echo "type=SYSCALL"'
  else
    akit_stub ausearch 'printf "%s\\n" "$@" >"$AKIT_ROOT/ausearch.args"; exit 1'
  fi
}

# write_state [<path> <content>]: write a state file, with a file= line when given a file.
write_state() {
  printf 'version=1\nprofile=medium\n' >"$AKIT_ROOT/etc/auditd-kit/state"
  if [ $# -gt 0 ]; then
    mkdir -p "$(dirname "$AKIT_ROOT$1")"
    printf '%s' "$2" >"$AKIT_ROOT$1"
    printf 'file=%s %s\n' "$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)" "$1" \
      >>"$AKIT_ROOT/etc/auditd-kit/state"
  fi
}

@test "matching counts and canary found pass with exit 0" {
  write_state /etc/audit/auditd.conf "a=1"
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=rule_count result=pass"* ]]
  [[ "$output" == *"check=files result=pass"* ]]
  [[ "$output" == *"check=canary result=pass"* ]]
  [ -s "$AKIT_ROOT/etc/auditd-kit/canary" ]
  # ausearch must read the log files (not stdin), and needs the date and the time as two
  # separate arguments after -ts.
  [ "$(sed -n 1p "$AKIT_ROOT/ausearch.args")" = --input-logs ]
  [ "$(sed -n 4p "$AKIT_ROOT/ausearch.args")" = -ts ]
  sed -n 5p "$AKIT_ROOT/ausearch.args" | grep -Eqx '[0-9]{2}/[0-9]{2}/[0-9]{2}'
  sed -n 6p "$AKIT_ROOT/ausearch.args" | grep -Eqx '[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

@test "canary file is overwritten, not appended" {
  write_state
  run sh "$verify"
  run sh "$verify"
  [ "$(wc -l <"$AKIT_ROOT/etc/auditd-kit/canary")" -eq 1 ]
}

@test "unreadable state file fails the files check with exit 2" {
  write_state
  chmod 000 "$AKIT_ROOT/etc/auditd-kit/state"
  [ -r "$AKIT_ROOT/etc/auditd-kit/state" ] && skip "running as root"
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=files result=fail detail=cannot read"* ]]
}

@test "rule count compares against auditctl output" {
  for n in 1 3; do
    stub_auditctl "$n"
    run sh "$verify"
    [ "$status" -eq 2 ]
    [[ "$output" == *"check=rule_count result=fail"* ]]
  done
  stub_auditctl 0
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=rule_count result=fail detail=loaded 0, expected 2"* ]]
}

@test "canary not found in 10 s fails" {
  write_state
  stub_ausearch none
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=canary result=fail"* ]]
}

@test "changed or missing file fails the files check" {
  write_state /etc/audit/auditd.conf "a=1"
  printf 'a=2' >"$AKIT_ROOT/etc/audit/auditd.conf"
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=files result=fail detail="*"/etc/audit/auditd.conf"* ]]
  rm "$AKIT_ROOT/etc/audit/auditd.conf"
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=files result=fail"* ]]
}

@test "no state file runs only rule_count" {
  run sh "$verify"
  [ "$status" -eq 0 ]
  [ "$output" = "check=rule_count result=pass detail=2 rules loaded" ]
  [ ! -e "$AKIT_ROOT/etc/auditd-kit/canary" ]
}

@test "auditctl failing fails rule_count" {
  akit_stub auditctl 'exit 1'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=rule_count result=fail"* ]]
}

# forward_state <targets>: a state file for an install with forwarding, and an rsyslog.d dir.
forward_state() {
  write_state
  printf 'forward=remote\nsyslog_forward_targets=%s\n' "$1" >>"$AKIT_ROOT/etc/auditd-kit/state"
  mkdir -p "$AKIT_ROOT/etc/rsyslog.d"
  : >"$AKIT_ROOT/etc/rsyslog.d/40-auditd-kit.conf"
  akit_stub service 'exit 0'
}

# check <name> <pass|fail>: run verify and look for the check line.
check() {
  run sh "$verify"
  [[ "$output" == *"check=$1 result=$2"* ]] || { echo "$1 $2: $output"; return 1; }
}

@test "forwarding checks pass when the state shows forwarding and the host matches" {
  forward_state 192.0.2.20:5515/tcp
  printf '%s\n' 'action(type="omfwd" target="192.0.2.20" port="5515" protocol="tcp")' \
    >"$AKIT_ROOT/etc/rsyslog.d/30-existing.conf"
  : >"$AKIT_ROOT/etc/rsyslog.d/10-azuremonitoragent.conf"
  run sh "$verify"
  [ "$status" -eq 0 ]
  for name in rsyslog_active forward_targets_unchanged dropin_order; do
    check $name pass
  done
}

@test "each forwarding check can fail" {
  forward_state none
  akit_stub service 'exit 3'
  check rsyslog_active fail
  akit_stub service 'exit 0'
  printf '%s\n' 'action(type="omfwd" target="192.0.2.30" port="514" protocol="tcp")' \
    >"$AKIT_ROOT/etc/rsyslog.d/30-new.conf"
  check forward_targets_unchanged fail
  : >"$AKIT_ROOT/etc/rsyslog.d/50-azuremonitoragent.conf"
  check dropin_order fail
  [ "$status" -eq 2 ]
}

@test "forwarding checks do not run without forwarding in the state" {
  write_state
  run sh "$verify"
  [[ "$output" != *rsyslog_active* ]]
  printf 'forward=none\n' >>"$AKIT_ROOT/etc/auditd-kit/state"
  run sh "$verify"
  [[ "$output" != *rsyslog_active* ]]
}

@test "lost events during the canary check fail the lost check" {
  write_state
  # Each auditctl -s call reports one more lost event.
  akit_stub auditctl 'if [ "$1" = -s ]; then n=$(cat "$AKIT_ROOT/lost" 2>/dev/null || echo 0); echo "lost $n"; echo $((n + 1)) >"$AKIT_ROOT/lost"; else echo "-w /x -p wa -k k"; echo "-w /y -p wa -k k"; fi'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=lost result=fail detail=the lost count rose by 1 during"* ]]
}

@test "the lost check reads the older AUDIT_STATUS format" {
  write_state
  stub_auditctl 2 'AUDIT_STATUS: enabled=1 flag=1 pid=1 rate_limit=0 backlog_limit=320 lost=0 backlog=0'
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=lost result=pass"* ]]
}
