#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"

@test "text mode prints key=value lines in insertion order" {
  run sh -c '. "$1/output.sh"; akit_kv b 2; akit_kv a 1; akit_kv c x; akit_kv_flush text' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'b=2\na=1\nc=x')" ]
}

@test "text mode replaces newlines in values with spaces" {
  run sh -c '. "$1/output.sh"; akit_kv a "one
two"; akit_kv_flush text' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "a=one two" ]
}

@test "flush empties the collected pairs" {
  run sh -c '. "$1/output.sh"; akit_kv a 1; akit_kv_flush text >/dev/null; akit_kv_flush text' sh "$lib"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "json mode escapes quotes, backslashes, tabs and newlines" {
  run sh -c '. "$1/output.sh"; akit_kv plain ok; akit_kv odd "q\" b\\ t	n
x"; akit_kv_flush json' sh "$lib"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -m json.tool >/dev/null
  run sh -c '. "$1/output.sh"; akit_kv odd "q\" b\\ t	n
x"; akit_kv_flush json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"odd\"].count(chr(9)))"' sh "$lib"
  [ "$output" = "1" ]
}

@test "json mode prints an empty object when nothing was collected" {
  run sh -c '. "$1/output.sh"; akit_kv_flush json' sh "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "json mode keeps an equals sign inside a value" {
  run sh -c '. "$1/output.sh"; akit_kv a "x=y"; akit_kv_flush json' sh "$lib"
  [[ "$output" == *'"a":"x=y"'* ]]
}
