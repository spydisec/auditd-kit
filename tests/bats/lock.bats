#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

setup() {
  akit_fixture_root
  mkdir -p "$AKIT_ROOT/run"
  lock="$AKIT_ROOT/run/auditd-kit.lock"
}

# with_lock <commands>: run the commands in sh after sourcing the lock library.
with_lock() {
  run sh -c '. "$1/scripts/lib/common.sh"; '"$1" sh "$repo"
}

@test "lock is taken with the PID and released" {
  with_lock 'akit_lock_take; [ "$(cat "$AKIT_ROOT/run/auditd-kit.lock")" = "$$" ] || exit 9; akit_lock_release'
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
}

@test "a lock held by a live PID exits 1 and stays" {
  echo "$$" >"$lock"
  with_lock 'akit_lock_take; echo taken'
  [ "$status" -eq 1 ]
  [[ "$output" == *"another auditd-kit run holds the lock (pid $$)"* ]]
  [[ "$output" != *taken* ]]
  [ "$(cat "$lock")" = "$$" ]
}

@test "a lock left by a dead PID or with no PID is replaced" {
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  for old in "$dead" "" "garbage"; do
    echo "$old" >"$lock"
    with_lock 'akit_lock_take && cat "$AKIT_ROOT/run/auditd-kit.lock"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"replacing a stale lock"* ]]
  done
}

@test "release leaves a lock that another PID took" {
  with_lock 'akit_lock_take; echo 1 >"$AKIT_ROOT/run/auditd-kit.lock"; akit_lock_release'
  [ "$status" -eq 0 ]
  [ "$(cat "$lock")" = 1 ]
}
