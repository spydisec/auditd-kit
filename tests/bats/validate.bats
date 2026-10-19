#!/usr/bin/env bats

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"
fixtures="$repo/tests/fixtures/syscalls"

# render_profile <profile> [os]: render a profile with the os syscall tables (default rocky9)
# into $out.
render_profile() {
  akit_fixture_root
  out="$BATS_TEST_TMPDIR/out-$1-${2:-rocky9}"
  AKIT_SYSCALLS_B64="$fixtures/${2:-rocky9}-b64.txt" AKIT_SYSCALLS_B32="$fixtures/${2:-rocky9}-b32.txt" \
    AKIT_ARCH=x86_64 sh "$lib/render.sh" --profile "$1" --size standard --immutable true \
    --out-dir "$out" --report "$BATS_TEST_TMPDIR/report-$1.txt" >/dev/null
}

# rules_file <line>...: write the lines to $dir/50-test.rules.
rules_file() {
  dir="$BATS_TEST_TMPDIR/rules"
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/50-test.rules"
}

@test "every rendered profile passes on every OS fixture" {
  for profile in minimal medium heavy; do
    for os in centos7 rocky8 rocky9 ubuntu2204 ubuntu2404; do
      render_profile "$profile" "$os"
      run sh "$lib/validate.sh" "$out"
      [ "$status" -eq 0 ]
      [ -z "$output" ]
    done
  done
}

@test "the profile sources pass with a backlog value filled in" {
  src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  for f in "$repo"/rules/*.rules; do
    sed 's/@AKIT_BACKLOG@/8192/' "$f" >"$src/$(basename "$f")"
  done
  run sh "$lib/validate.sh" "$src"
  [ "$status" -eq 0 ]
}

@test "a -S with no value fails and names the line" {
  rules_file '# comment' '' '-a always,exit -F arch=b64 -S'
  run sh "$lib/validate.sh" "$dir"
  [ "$status" -eq 1 ]
  [ "$output" = "$dir/50-test.rules:3: -a always,exit -F arch=b64 -S" ]
}

@test "a line starting with -x fails" {
  rules_file '-w /etc/passwd -p wa -k test' '-x /etc/passwd'
  run sh "$lib/validate.sh" "$dir"
  [ "$status" -eq 1 ]
  [ "$output" = "$dir/50-test.rules:2: -x /etc/passwd" ]
}

@test "every bad line is listed" {
  rules_file \
    '-a always,bogus -S adjtimex' \
    '-w etc/passwd -p wa' \
    '-w /etc/passwd -p wz' \
    '-a always,exit -F arch' \
    '-a always,exit -S adjtimex -k' \
    '-f 3' \
    '-b many' \
    '-i extra' \
    '-w /etc/passwd -p wa # trailing comment'
  run sh "$lib/validate.sh" "$dir"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 9 ]
}

@test "known rule and control forms pass" {
  rules_file \
    '-D' \
    '-b 8192' \
    '-f 1' \
    '-e 2' \
    '-i' \
    '-r 100' \
    '--backlog_wait_time 60000' \
    '--loginuid-immutable' \
    '-a always,exclude -F msgtype=CRYPTO_KEY_USER' \
    '-a never,user -F subj_type=crond_t' \
    '-a exit,never -F arch=b64 -S all -F exe=/usr/bin/vmtoolsd' \
    '-A always,exit -F arch=b32 -S open,openat -S creat -F auid>=1000 -F auid!=unset -k test' \
    '-a always,exit -F dir=/home -F uid=0 -C auid!=obj_uid -k test' \
    '-a always,exit -F arch=b64 -S socket -F a0=2  -k test' \
    '-w /var/log/audit/ -p wra -k test' \
    '-w /etc/passwd'
  run sh "$lib/validate.sh" "$dir"
  [ "$status" -eq 0 ]
}

@test "a missing dir or a dir with no rules files fails" {
  run sh "$lib/validate.sh" "$BATS_TEST_TMPDIR/nothere"
  [ "$status" -eq 1 ]
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run sh "$lib/validate.sh" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 1 ]
  run sh "$lib/validate.sh"
  [ "$status" -eq 1 ]
}
