#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"

@test "akit_path prefixes AKIT_ROOT" {
  run sh -c '. "$1/common.sh" && akit_path /etc/audit' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/audit" ]

  AKIT_ROOT=/tmp/root run sh -c '. "$1/common.sh" && akit_path /etc/audit' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/root/etc/audit" ]
}

@test "akit_die exits with the given code and logs the message" {
  run sh -c '. "$1/common.sh" && akit_die 3 msg' sh "$lib"
  [ "$status" -eq 3 ]
  [[ "$output" == *msg* ]]
}

@test "akit_log also writes to AKIT_LOG_FILE when it is set" {
  log="$BATS_TEST_TMPDIR/akit.log"
  AKIT_LOG_FILE=$log run sh -c '. "$1/common.sh" && akit_log info hello' sh "$lib"
  [ "$status" -eq 0 ]
  [[ "$output" == *hello* ]]
  grep -q 'info.*hello' "$log"
}

@test "LC_ALL is C after sourcing and exit codes are defined" {
  run env LC_ALL=de_DE.UTF-8 sh -c '. "$1/common.sh" && echo "$LC_ALL $AKIT_EXIT_OK $AKIT_EXIT_REFUSED $AKIT_EXIT_FAILED $AKIT_EXIT_ROLLBACK_FAILED"' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "C 0 1 2 3" ]
}
