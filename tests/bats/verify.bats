#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

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

# stub_auditctl <n>: auditctl -l prints n rule lines, or "No rules" when n is 0.
stub_auditctl() {
  akit_stub auditctl "if [ $1 -eq 0 ]; then echo 'No rules'; else i=0; while [ \$i -lt $1 ]; do echo '-w /x -p wa -k k'; i=\$((i + 1)); done; fi"
}

# stub_ausearch <found|none>: record the arguments in $AKIT_ROOT/ausearch.args.
stub_ausearch() {
  if [ "$1" = found ]; then
    akit_stub ausearch 'echo "$*" >"$AKIT_ROOT/ausearch.args"; echo "type=SYSCALL"'
  else
    akit_stub ausearch 'echo "$*" >"$AKIT_ROOT/ausearch.args"; exit 1'
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
  grep -Eq -- '^-k akit_canary -ts [0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$AKIT_ROOT/ausearch.args"
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
