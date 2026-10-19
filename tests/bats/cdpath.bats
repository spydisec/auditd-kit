#!/usr/bin/env bats

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
fixtures="$repo/tests/fixtures/syscalls"

# With CDPATH set, "cd scripts/lib" prints the dir it found, which breaks a script that keeps
# the output of cd as its own location. Each script is run by a relative path for that reason.
@test "every entry script runs with CDPATH exported" {
  akit_fixture_root
  akit_stub id 'echo 1000'
  CDPATH=$repo
  export CDPATH
  cd "$repo"

  run sh scripts/survey.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"survey_version=1"* ]]

  run sh scripts/stats.sh --dir "$BATS_TEST_TMPDIR/nothere"
  [ "$status" -eq 0 ]

  AKIT_SYSCALLS_B64="$fixtures/rocky9-b64.txt"
  AKIT_SYSCALLS_B32="$fixtures/rocky9-b32.txt"
  AKIT_ARCH=x86_64
  export AKIT_SYSCALLS_B64 AKIT_SYSCALLS_B32 AKIT_ARCH
  run sh scripts/lib/render.sh --profile minimal --size standard \
    --out-dir "$BATS_TEST_TMPDIR/out" --report "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == rule_count=* ]]

  run sh scripts/lib/validate.sh "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
}
