#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
stats="$repo/scripts/stats.sh"
awk_prog="$repo/scripts/lib/stats.awk"
logs="$repo/tests/fixtures/audit-logs"

@test "events count unique serials, not lines" {
  [ "$(wc -l <"$logs/basic/audit.log")" -eq 7 ]
  run sh "$stats" --dir "$logs/basic"
  [ "$status" -eq 0 ]
  [[ "$output" == *"day=2023-11-14 bytes=783 events=3"* ]]
}

@test "bytes per day split at UTC midnight" {
  run sh "$stats" --dir "$logs/midnight"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "day=2023-11-14 bytes=246 events=1" ]
  [ "${lines[1]}" = "day=2023-11-15 bytes=310 events=2" ]
}

@test "top keys rank by event count" {
  run sh "$stats" --dir "$logs/basic"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ntop_key exec 2\ntop_key net 1'* ]]
  run sh "$stats" --dir "$logs/basic" --top 1
  [[ "$output" == *"top_key exec 2"* ]]
  [[ "$output" != *"top_key net"* ]]
}

@test "top exe and auid are counted" {
  run sh "$stats" --dir "$logs/basic"
  [[ "$output" == *$'\ntop_exe /usr/bin/cat 1\ntop_exe /usr/bin/curl 1\ntop_exe /usr/bin/ls 1'* ]]
  [[ "$output" == *$'\ntop_auid 1000 2\ntop_auid 0 1'* ]]
}

@test "hex-encoded multi-key is split into its keys" {
  run sh "$stats" --dir "$logs/keys"
  [ "$status" -eq 0 ]
  [[ "$output" == *"top_key key1 1"* ]]
  [[ "$output" == *"top_key a 3"* ]]
}

@test "key=(null) counts as (none)" {
  run sh "$stats" --dir "$logs/keys"
  [[ "$output" == *"top_key (none) 1"* ]]
}

@test "a hex-encoded exe is decoded, and auid 4294967295 counts as unset" {
  run sh "$stats" --dir "$logs/keys"
  [[ "$output" == *"top_exe /opt/my_app/run 1"* ]]
  [[ "$output" == *"top_exe /usr/bin/sudo 1"* ]]
  [[ "$output" == *"top_auid unset 2"* ]]
  [[ "$output" == *"top_auid 1000 5"* ]]
}

@test "rotated logs are included" {
  run sh "$stats" --dir "$logs/keys"
  [[ "$output" == *"day=2023-11-13 bytes=155 events=1"* ]]
  [[ "$output" == *"day=2023-11-14 bytes=1022 events=6"* ]]
  [[ "$output" == *"top_key exec 2"* ]]
}

@test "csv format prints host,day,bytes,events" {
  AKIT_HOSTNAME=web1.example.com run sh "$stats" --dir "$logs/midnight" --format csv
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "web1.example.com,2023-11-14,246,1" ]
  [ "${lines[1]}" = "web1.example.com,2023-11-15,310,2" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "csv host defaults to the host name" {
  run sh "$stats" --dir "$logs/midnight" --format csv
  [[ "$output" == "$(hostname 2>/dev/null || uname -n),2023-11-14,"* ]]
}

@test "the default dir is /var/log/audit under AKIT_ROOT" {
  akit_fixture_root
  mkdir -p "$AKIT_ROOT/var/log/audit"
  cp "$logs/midnight/audit.log" "$AKIT_ROOT/var/log/audit/"
  run sh "$stats"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "day=2023-11-14 bytes=246 events=1" ]
}

@test "a missing or empty dir prints nothing and exits 0" {
  run sh "$stats" --dir "$BATS_TEST_TMPDIR/nothere"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$stats" --dir "$logs/empty"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$stats" --dir "$logs/empty" --format csv
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unreadable dir exits 1" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can read any dir"
  fi
  mkdir "$BATS_TEST_TMPDIR/locked"
  chmod 000 "$BATS_TEST_TMPDIR/locked"
  run sh "$stats" --dir "$BATS_TEST_TMPDIR/locked"
  chmod 755 "$BATS_TEST_TMPDIR/locked"
  [ "$status" -eq 1 ]
}

@test "a dir that is a file exits 1" {
  run sh "$stats" --dir "$logs/basic/audit.log"
  [ "$status" -eq 1 ]
}

@test "bad arguments exit 1" {
  run sh "$stats" --bogus
  [ "$status" -eq 1 ]
  run sh "$stats" --format xml
  [ "$status" -eq 1 ]
  run sh "$stats" --top many
  [ "$status" -eq 1 ]
  run sh "$stats" --top -1
  [ "$status" -eq 1 ]
  run sh "$stats" --dir
  [ "$status" -eq 1 ]
}

@test "stats.awk skips events older than since" {
  run awk -v since=1700006400 -f "$awk_prog" "$logs/midnight/audit.log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "day=2023-11-15 bytes=310 events=2" ]
  [[ "$output" != *"2023-11-14"* ]]
  run awk -v since=1700006401 -f "$awk_prog" "$logs/midnight/audit.log"
  [ "${lines[0]}" = "day=2023-11-15 bytes=155 events=1" ]
  run awk -v since=1800000000 -f "$awk_prog" "$logs/midnight/audit.log"
  [ -z "$output" ]
}

@test "stats.awk since also limits the top lists" {
  run awk -v since=1700000003 -f "$awk_prog" "$logs/keys/audit.log" "$logs/keys/audit.log.1"
  [[ "$output" != *"top_key key1"* ]]
  [[ "$output" == *"top_key a 1"* ]]
  [[ "$output" == *"top_key exec 1"* ]]
}

@test "stats.awk gives the same output under every awk on this machine" {
  want=$(awk -f "$awk_prog" "$logs"/keys/audit.log* "$logs/midnight/audit.log" "$logs/basic/audit.log" "$logs/enriched/audit.log" "$logs/interleaved/audit.log")
  [ -n "$want" ]
  tried=0
  for a in gawk mawk "busybox awk"; do
    # shellcheck disable=SC2086
    command -v ${a%% *} >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    got=$($a -f "$awk_prog" "$logs"/keys/audit.log* "$logs/midnight/audit.log" "$logs/basic/audit.log" "$logs/enriched/audit.log" "$logs/interleaved/audit.log")
    [ "$got" = "$want" ]
    tried=$((tried + 1))
  done
  [ "$tried" -ge 1 ]
}

@test "enriched logs give the same top lists as raw logs" {
  run sh "$stats" --dir "$logs/enriched"
  [ "$status" -eq 0 ]
  enriched_top=$(printf '%s\n' "$output" | grep '^top_')
  run sh "$stats" --dir "$logs/raw-twin"
  raw_top=$(printf '%s\n' "$output" | grep '^top_')
  [ "$enriched_top" = "$raw_top" ]
  [[ "$enriched_top" == *"top_key (none) 1"* ]]
  [[ "$enriched_top" == *"top_key key1 1"* ]]
  [[ "$enriched_top" == *"top_key a 2"* ]]
  [[ "$enriched_top" == *"top_auid unset 1"* ]]
  [[ "$enriched_top" != *ARCH* ]]
}

@test "records of one event that interleave with another count once" {
  run sh "$stats" --dir "$logs/interleaved"
  [[ "$output" == *"events=2"* ]]
  [ "$(wc -l <"$logs/interleaved/audit.log")" -eq 3 ]
}

@test "an event split across audit.log.1 and audit.log counts once" {
  run sh "$stats" --dir "$logs/split"
  [[ "$output" == *"events=2"* ]]
  [[ "$output" == *"top_key exec 1"* ]]
}

@test "node= prefixed lines are counted" {
  run sh "$stats" --dir "$logs/node"
  [[ "$output" == *"events=2"* ]]
  [[ "$output" == *"top_key exec 2"* ]]
  [[ "$output" == *"top_exe /usr/bin/ls 2"* ]]
}

@test "rotated names that do not end in digits are skipped" {
  run sh "$stats" --dir "$logs/extra-files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"events=3"* ]]
  [[ "$output" != *junk* ]]
}

@test "rotated logs are read in numeric order" {
  dir="$BATS_TEST_TMPDIR/many"
  mkdir "$dir"
  for n in 2 10 1; do
    : >"$dir/audit.log.$n"
  done
  : >"$dir/audit.log"
  # Stand in for awk and print the file order it was given.
  akit_stub awk 'for f in "$@"; do case $f in *audit.log*) echo "${f##*/}" ;; esac; done'
  run sh "$stats" --dir "$dir"
  [ "$output" = $'audit.log.10\naudit.log.2\naudit.log.1\naudit.log' ]
}

@test "30000 distinct names finish in a few seconds" {
  awk 'BEGIN { for (i = 1; i <= 30000; i++)
    printf "type=SYSCALL msg=audit(1700000000.001:%d): auid=%d exe=\"/opt/app%d\" key=\"k%d\"\n", i, i, i, i }' >"$BATS_TEST_TMPDIR/audit.log"
  start=$(date +%s)
  run sh "$stats" --dir "$BATS_TEST_TMPDIR"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ $((end - start)) -le 10 ]
  [[ "$output" == *"events=30000"* ]]
}

@test "stats.sh --since skips older events and rejects a bad value" {
  run sh "$stats" --dir "$logs/midnight" --since 1700006401
  [ "$status" -eq 0 ]
  [[ "$output" != *"day=2023-11-14"* ]]
  [[ "$output" == *"day=2023-11-15"* ]]
  run sh "$stats" --dir "$logs/midnight" --since 1800000000
  [ "$status" -eq 0 ]
  [[ "$output" != *"day="* ]]
  run sh "$stats" --dir "$logs/midnight" --since soon
  [ "$status" -eq 1 ]
}
