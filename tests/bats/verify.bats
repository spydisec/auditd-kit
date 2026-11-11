#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016,SC2030,SC2031

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
verify="$repo/scripts/verify.sh"

setup() {
  akit_fixture_root
  rules_d="$AKIT_ROOT/etc/audit/rules.d"
  mkdir -p "$rules_d" "$AKIT_ROOT/etc/auditd-kit"
  printf '%s\n' '## header' '-D' '-w /etc/passwd -p wa -k id' \
    '-a always,exit -F arch=b64 -S execve -k exec' >"$rules_d/30-auditd-kit-test.rules"
  export AKIT_VERIFY_POLL=0
  stub_auditctl
  loaded '-w /etc/passwd -p wa -k id' '-a always,exit -F arch=b64 -S execve -F key=exec'
  stub_ausearch found
}

# stub_auditctl [<status text>]: auditctl -s prints the status text, and auditctl -l prints the
# lines that loaded saved.
stub_auditctl() {
  printf '%s\n' "${1:-enabled 1
failure 1
pid 321
lost 0}" >"$AKIT_ROOT/status"
  akit_stub auditctl 'if [ "$1" = -s ]; then cat "$AKIT_ROOT/status"; else cat "$AKIT_ROOT/loaded"; fi'
}

# loaded [<rule> ...]: the rules that auditctl -l prints, or "No rules" with no arguments.
loaded() {
  if [ $# -eq 0 ]; then
    echo 'No rules' >"$AKIT_ROOT/loaded"
  else
    printf '%s\n' "$@" >"$AKIT_ROOT/loaded"
  fi
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
  [[ "$output" == *"check=status result=pass"* ]]
  [[ "$output" == *"check=rules result=pass detail=2 rules loaded"* ]]
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

@test "no state file runs only the status and rules checks" {
  run sh "$verify"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"check=rules result=pass detail=2 rules loaded"* ]]
  [ ! -e "$AKIT_ROOT/etc/auditd-kit/canary" ]
}

@test "auditctl failing fails the status and rules checks" {
  akit_stub auditctl 'exit 1'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=status result=fail"* ]]
  [[ "$output" == *"check=rules result=fail"* ]]
}

@test "lost events during the canary check fail the lost check" {
  write_state
  # Each auditctl -s call reports one more lost event.
  akit_stub auditctl 'if [ "$1" = -s ]; then n=$(cat "$AKIT_ROOT/lost" 2>/dev/null || echo 0); echo "enabled 1"; echo "pid 321"; echo "lost $n"; echo $((n + 1)) >"$AKIT_ROOT/lost"; else echo "-w /x -p wa -k k"; echo "-w /y -p wa -k k"; fi'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=lost result=fail detail=the lost count rose by 1 during"* ]]
}

@test "the lost check reads the older AUDIT_STATUS format" {
  write_state
  stub_auditctl 'AUDIT_STATUS: enabled=1 flag=1 pid=1 rate_limit=0 backlog_limit=320 lost=0 backlog=0'
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=lost result=pass"* ]]
}

@test "a missing auditd-kit rule fails and names its key" {
  loaded '-w /etc/passwd -p wa -k id'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=rules result=fail detail=auditd-kit rules are not loaded, by key: exec (0 of 1)"* ]]
}

@test "rules that an agent added don't hide a missing auditd-kit rule" {
  loaded '-w /etc/passwd -p wa -k id' '-w /var/www -p wa -k wazuh_fim' '-w /srv -p wa -k wazuh_fim'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"by key: exec (0 of 1)"* ]]
}

@test "a missing rule of another file is a warning, and verify passes" {
  printf '%s\n' '-w /opt/app -p wa -k org_app' '-w /opt/db -p wa' >"$rules_d/40-org.rules"
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=rules result=pass"* ]]
  [[ "$output" == *"check=other_rules result=warn detail="*"org_app (0 of 1)"* ]]
  [[ "$output" == *"rules with no key (0 of 1)"* ]]
}

@test "a rule of another file under one of our keys is a warning, and a saved copy is not expected" {
  write_state
  echo '-w /etc/passwd -p wa -k id' >"$rules_d/40-org.rules"
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=other_rules result=warn detail="*"id (1 of 2)"* ]]
  echo 'skip=copy id' >>"$AKIT_ROOT/etc/auditd-kit/state"
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" != *"other_rules"* ]]
}

@test "no rules loaded on a host with only other files is a warning" {
  rm "$rules_d/30-auditd-kit-test.rules"
  echo '-w /opt/app -p wa -k org_app' >"$rules_d/40-org.rules"
  loaded
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=rules result=pass detail=0 rules loaded"* ]]
  [[ "$output" == *"check=other_rules result=warn detail="*"org_app (0 of 1)"* ]]
}

@test "auditing turned off, or auditd not running, fails the status check" {
  stub_auditctl 'enabled 0
pid 321
lost 0'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=status result=fail detail=auditing is turned off"* ]]
  stub_auditctl 'enabled 1
pid 0
lost 0'
  run sh "$verify"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=status result=fail detail=auditd is not running"* ]]
}

@test "failure mode 2 is a warning" {
  stub_auditctl 'enabled 1
failure 2
pid 321
lost 0'
  run sh "$verify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check=failure_mode result=warn"* ]]
}

@test "verify waits a second after it takes the start time, before it writes the canary" {
  write_state
  # The kernel's event clock runs a few ms behind date, so an event written right after the
  # start time can carry the second before it, and ausearch -ts would then skip it.
  export AKIT_VERIFY_POLL=1
  akit_stub sleep '{ [ -e "$AKIT_ROOT/etc/auditd-kit/canary" ] && echo after || echo before; } >>"$AKIT_ROOT/sleeps"'
  run sh "$verify"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$AKIT_ROOT/sleeps")" = before ]
}
