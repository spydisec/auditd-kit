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
  # A log file that can't be written must not make akit_log fail under set -e.
  AKIT_LOG_FILE=$BATS_TEST_TMPDIR/no-such-dir/akit.log run sh -c 'set -e; . "$1/common.sh"; akit_log info hello; echo after' sh "$lib"
  [ "$status" -eq 0 ]
  [[ "$output" == *after* ]]
}

@test "LC_ALL is C after sourcing and exit codes are defined" {
  run env LC_ALL=de_DE.UTF-8 sh -c '. "$1/common.sh" && echo "$LC_ALL $AKIT_EXIT_OK $AKIT_EXIT_REFUSED $AKIT_EXIT_FAILED $AKIT_EXIT_ROLLBACK_FAILED"' sh "$lib"
  [ "$status" -eq 0 ]
  # Some shells warn on stderr that they can't set the locale, so check only the last line.
  [ "${lines[${#lines[@]} - 1]}" = "C 0 1 2 3" ]
}

# Render tests use a fixture root, the Rocky 9 syscall tables, and x86_64 unless a test says
# otherwise.
fixtures="$repo/tests/fixtures/syscalls"
tab=$(printf '\t')

# not <cmd>...: succeed only when the command fails. Bats ignores a bare "! cmd" mid-test.
not() {
  if "$@"; then
    return 1
  fi
}

render_setup() {
  akit_fixture_root
  AKIT_SYSCALLS_B64="$fixtures/rocky9-b64.txt"
  AKIT_SYSCALLS_B32="$fixtures/rocky9-b32.txt"
  AKIT_ARCH=x86_64
  export AKIT_SYSCALLS_B64 AKIT_SYSCALLS_B32 AKIT_ARCH
  out="$BATS_TEST_TMPDIR/out"
  report="$BATS_TEST_TMPDIR/report.txt"
  extra="$BATS_TEST_TMPDIR/extra"
  mkdir -p "$extra"
}

# render [args...]: run render.sh with the minimal profile and standard size unless args override.
render() {
  run sh "$lib/render.sh" --profile minimal --size standard --out-dir "$out" --report "$report" "$@"
}

# extra_rules <line>...: write the lines to $extra/50-test.rules.
extra_rules() {
  printf '%s\n' "$@" >"$extra/50-test.rules"
}

# out_files: the names in the out dir on one line.
out_files() {
  (cd "$out" && echo *)
}

@test "standard size puts -b 16384 in the base file" {
  render_setup
  render
  [ "$status" -eq 0 ]
  grep -qx -- '-b 16384' "$out/00-auditd-kit-base.rules"
  not grep -q '@AKIT_BACKLOG@' "$out/00-auditd-kit-base.rules"
}

@test "each profile writes its own file list" {
  render_setup
  render
  [ "$status" -eq 0 ]
  [ "$(out_files)" = "00-auditd-kit-base.rules 10-auditd-kit-minimal.rules 90-auditd-kit-minimal-last.rules" ]
  rm -rf "$out"
  render --profile medium
  [ "$status" -eq 0 ]
  [ "$(out_files)" = "00-auditd-kit-base.rules 10-auditd-kit-minimal.rules 20-auditd-kit-medium.rules 90-auditd-kit-minimal-last.rules 91-auditd-kit-medium-last.rules" ]
  rm -rf "$out"
  extra_rules '-w /etc/x -p wa -k test_x'
  render --profile heavy --immutable true --extra-dir "$extra"
  [ "$status" -eq 0 ]
  [ "$(out_files)" = "00-auditd-kit-base.rules 10-auditd-kit-minimal.rules 20-auditd-kit-medium.rules 30-auditd-kit-heavy.rules 50-test.rules 90-auditd-kit-minimal-last.rules 91-auditd-kit-medium-last.rules 99-auditd-kit-finalize.rules" ]
}

@test "the old profile and size names exit 1 and name the new value" {
  render_setup
  render --profile standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile standard is now heavy"* ]]
  render --size medium
  [ "$status" -eq 1 ]
  [[ "$output" == *"size medium is now standard"* ]]
  [ ! -e "$out" ]
}

@test "small and large sizes use their preset backlog" {
  render_setup
  render --size small
  [ "$status" -eq 0 ]
  grep -qx -- '-b 8192' "$out/00-auditd-kit-base.rules"
  rm -rf "$out"
  render --size large
  [ "$status" -eq 0 ]
  grep -qx -- '-b 32768' "$out/00-auditd-kit-base.rules"
}

@test "watch whose parent dir is missing is dropped with missing_path" {
  render_setup
  extra_rules '-w /opt/nothere/app.conf -p wa -k test_watch'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q test_watch "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}missing_path${tab}/opt/nothere/app.conf\$" "$report"
}

@test "watch on a missing path with an existing parent is kept" {
  render_setup
  mkdir -p "$AKIT_ROOT/etc"
  extra_rules '-w /etc/nothere.conf -p wa -k test_file' '-w /etc/nothere.d/ -p wa -k test_dir'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -qx -- '-w /etc/nothere.conf -p wa -k test_file' "$out/50-test.rules"
  grep -qx -- '-w /etc/nothere.d/ -p wa -k test_dir' "$out/50-test.rules"
  not grep -q nothere "$report"
}

@test "exe or path filter on a missing binary is dropped with missing_binary" {
  render_setup
  mkdir -p "$AKIT_ROOT/usr/bin"
  touch "$AKIT_ROOT/usr/bin/present"
  extra_rules \
    '-a always,exit -F path=/usr/bin/nothere -F perm=x -k test_path' \
    '-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/gone -k test_exe' \
    '-a always,exit -F path=/usr/bin/present -F perm=x -k test_present'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q test_path "$out/50-test.rules"
  not grep -q test_exe "$out/50-test.rules"
  grep -q test_present "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}missing_binary${tab}/usr/bin/nothere\$" "$report"
  grep -q "50-test.rules:2${tab}dropped${tab}missing_binary${tab}/usr/bin/gone\$" "$report"
}

@test "path filter on a symlink is dropped with symlink" {
  render_setup
  mkdir -p "$AKIT_ROOT/usr/bin"
  touch "$AKIT_ROOT/usr/bin/real"
  ln -s real "$AKIT_ROOT/usr/bin/link"
  extra_rules \
    '-a always,exit -F path=/usr/bin/link -F perm=x -k test_link' \
    '-a always,exit -F path=/usr/bin/real -F perm=x -k test_real'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q test_link "$out/50-test.rules"
  grep -q test_real "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}symlink${tab}/usr/bin/link\$" "$report"
}

@test "dir filter on a missing directory is dropped with missing_path" {
  render_setup
  mkdir -p "$AKIT_ROOT/etc"
  extra_rules \
    '-a always,exit -F arch=b64 -F dir=/etc/nothere/ -F perm=wa -k test_gone' \
    '-a always,exit -F arch=b64 -F dir=/etc/ -F perm=wa -k test_here'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q test_gone "$out/50-test.rules"
  grep -q test_here "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}missing_path${tab}/etc/nothere/\$" "$report"
}

@test "unknown syscall is trimmed and the rule is kept" {
  render_setup
  extra_rules \
    '-a always,exit -F arch=b64 -S adjtimex,fakecall -k test_comma' \
    '-a always,exit -F arch=b64 -S adjtimex -S fakecall -S settimeofday -k test_repeat'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -qx -- '-a always,exit -F arch=b64 -S adjtimex -k test_comma' "$out/50-test.rules"
  grep -qx -- '-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k test_repeat' "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}trimmed${tab}unknown_syscall${tab}fakecall\$" "$report"
  grep -q "50-test.rules:2${tab}trimmed${tab}unknown_syscall${tab}fakecall\$" "$report"
}

@test "rule with only unknown syscalls is dropped" {
  render_setup
  extra_rules '-a always,exit -F arch=b64 -S fakecall,othercall -k test_empty'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q test_empty "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}unknown_syscall${tab}fakecall,othercall\$" "$report"
}

@test "b32 syscalls are checked against the b32 table and -S all is kept" {
  render_setup
  extra_rules \
    '-a always,exit -F arch=b32 -S stime -k test_b32' \
    '-a always,exit -F arch=b64 -S stime -k test_b64' \
    '-a never,exit -F arch=b64 -S all -F auid=0 -k test_all'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -q test_b32 "$out/50-test.rules"
  not grep -q test_b64 "$out/50-test.rules"
  grep -qx -- '-a never,exit -F arch=b64 -S all -F auid=0 -k test_all' "$out/50-test.rules"
}

@test "b32 rules are dropped on aarch64 with no_b32" {
  render_setup
  AKIT_ARCH=aarch64
  unset AKIT_SYSCALLS_B32
  render
  [ "$status" -eq 0 ]
  not grep -q 'arch=b32' "$out/10-auditd-kit-minimal.rules"
  grep -q 'arch=b64' "$out/10-auditd-kit-minimal.rules"
  grep -q "rules/10-minimal.rules:[0-9]*${tab}dropped${tab}no_b32${tab}aarch64\$" "$report"
}

@test "control lines in overlay rules are stripped and base keeps its own" {
  render_setup
  extra_rules '-D' '-b 8192' '-e 2' '-f 2' '-a always,exit -F arch=b64 -S adjtimex -k test_keep'
  render --profile heavy --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -q test_keep "$out/50-test.rules"
  not grep -Eq -- '^(-D|-b|-e|-f|-i|--backlog_wait_time|--loginuid-immutable)( |$)' "$out/50-test.rules"
  for n in 1 2 3 4; do
    grep -q "50-test.rules:$n${tab}dropped${tab}control_line${tab}" "$report"
  done
  for line in '-D' '-b 16384' '-f 1' '--backlog_wait_time 60000'; do
    grep -qx -- "$line" "$out/00-auditd-kit-base.rules"
  done
  [ ! -e "$out/99-auditd-kit-finalize.rules" ]
}

@test "control lines in the kit's profile files are kept" {
  render_setup
  # A copy of the kit, with a control line added to the medium profile file.
  kit="$BATS_TEST_TMPDIR/kit"
  mkdir -p "$kit/scripts"
  cp -R "$repo/rules" "$repo/config" "$kit/"
  cp -R "$lib" "$kit/scripts/lib"
  echo '--loginuid-immutable' >>"$kit/rules/20-medium.rules"
  run sh "$kit/scripts/lib/render.sh" --profile medium --size standard --out-dir "$out" \
    --report "$report"
  [ "$status" -eq 0 ]
  grep -qx -- '--loginuid-immutable' "$out/20-auditd-kit-medium.rules"
  not grep -q control_line "$report"
}

@test "an overlay -r line and a control flag with its value attached are stripped" {
  render_setup
  extra_rules '-r 100' '-f2' '--backlog_wait_time=0' '-a always,exit -F arch=b64 -S adjtimex -k test_keep'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -q test_keep "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}control_line${tab}-r 100\$" "$report"
  grep -q "50-test.rules:2${tab}dropped${tab}control_line${tab}-f2\$" "$report"
  grep -q "50-test.rules:3${tab}dropped${tab}control_line${tab}--backlog_wait_time=0\$" "$report"
  not grep -Eq -- '^(-r|-f2|--backlog_wait_time)' "$out/50-test.rules"
}

@test "only 50-*.rules files are taken from the extra dir" {
  render_setup
  extra_rules '-a always,exit -F arch=b64 -S adjtimex -k test_keep'
  printf '%s\n' '-a always,exit -F arch=b64 -S adjtimex -k test_other' >"$extra/10-other.rules"
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  [ -f "$out/50-test.rules" ]
  [ ! -e "$out/10-other.rules" ]
  [ "$(head -n 1 "$out/50-test.rules")" = "# Rendered by auditd-kit from 50-test.rules. Do not edit." ]
}

@test "finalize file only when immutable is true" {
  render_setup
  render
  [ "$status" -eq 0 ]
  [ ! -e "$out/99-auditd-kit-finalize.rules" ]
  rm -rf "$out"
  render --immutable false
  [ "$status" -eq 0 ]
  [ ! -e "$out/99-auditd-kit-finalize.rules" ]
  rm -rf "$out"
  render --immutable true
  [ "$status" -eq 0 ]
  grep -qx -- '-e 2' "$out/99-auditd-kit-finalize.rules"
}

@test "rule_count matches the -a and -w lines written" {
  render_setup
  mkdir -p "$AKIT_ROOT/etc"
  extra_rules '-a always,exit -F arch=b64 -S adjtimex -k test_keep' \
    '  -w /etc/indented -p wa -k test_indent' \
    "-a${tab}always,exit -F arch=b64 -S adjtimex -k test_tab"
  render --profile heavy --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -q test_indent "$out/50-test.rules"
  grep -q test_tab "$out/50-test.rules"
  n=$(cat "$out"/*.rules | grep -Ec -- '^[[:space:]]*-[aAw][[:space:]]')
  [ "$n" -gt 0 ]
  [ "$output" = "rule_count=$n" ]
}

@test "SELinux rules are dropped with no_selinux when no policy is loaded" {
  render_setup
  extra_rules \
    '-a never,user -F subj_type=crond_t' \
    '-a always,exit -F arch=b64 -S adjtimex -F obj_uid=0 -k test_objuid'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  not grep -q crond_t "$out/50-test.rules"
  grep -q test_objuid "$out/50-test.rules"
  grep -q "50-test.rules:1${tab}dropped${tab}no_selinux${tab}subj_type=crond_t\$" "$report"
}

@test "SELinux rules are kept when a policy is loaded" {
  render_setup
  mkdir -p "$AKIT_ROOT/sys/fs/selinux"
  touch "$AKIT_ROOT/sys/fs/selinux/enforce"
  extra_rules '-a never,user -F subj_type=crond_t'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -qx -- '-a never,user -F subj_type=crond_t' "$out/50-test.rules"
  not grep -q no_selinux "$report"
}

@test "an unreadable extra file gives exit 1 and leaves no out dir and no report" {
  render_setup
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can read any file"
  fi
  extra_rules '-a always,exit -F arch=b64 -S adjtimex -k test_keep'
  chmod 000 "$extra/50-test.rules"
  render --extra-dir "$extra"
  [ "$status" -eq 1 ]
  [[ "$output" == *50-test.rules* ]]
  [ ! -e "$out" ]
  [ ! -e "$report" ]
}

@test "a report path that can't be written gives exit 1 and leaves no out dir" {
  render_setup
  touch "$BATS_TEST_TMPDIR/plainfile"
  run sh "$lib/render.sh" --profile minimal --size standard --out-dir "$out" \
    --report "$BATS_TEST_TMPDIR/plainfile/report.txt"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "a failed rules copy leaves an earlier report as it was" {
  render_setup
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can write to any dir"
  fi
  mkdir -p "$out"
  chmod 555 "$out"
  echo old >"$report"
  render
  chmod 755 "$out"
  [ "$status" -eq 1 ]
  [ "$(cat "$report")" = old ]
  [ ! -e "$report.tmp" ]
  [ -z "$(ls -A "$out")" ]
}

@test "an empty syscall table is refused" {
  render_setup
  : >"$BATS_TEST_TMPDIR/empty.txt"
  AKIT_SYSCALLS_B64="$BATS_TEST_TMPDIR/empty.txt" render
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
  AKIT_SYSCALLS_B32="$BATS_TEST_TMPDIR/empty.txt" render
  [ "$status" -eq 1 ]
  AKIT_ARCH=aarch64 AKIT_SYSCALLS_B32="$BATS_TEST_TMPDIR/empty.txt" render
  [ "$status" -eq 0 ]
}

@test "a backslash in the extra dir path is reported as it is" {
  render_setup
  bs_extra="$BATS_TEST_TMPDIR/ex\\tra"
  mkdir -p "$bs_extra"
  echo '-a always,exit -F arch=b64 -S adjtimex,fakecall -k test_comma' >"$bs_extra/50-test.rules"
  render --extra-dir "$bs_extra"
  [ "$status" -eq 0 ]
  grep -qF "$bs_extra/50-test.rules:1${tab}trimmed" "$report"
}

@test "render works from any directory" {
  render_setup
  cd /
  render
  [ "$status" -eq 0 ]
  [ -f "$out/10-auditd-kit-minimal.rules" ]
}

@test "render reads ausyscall --dump output when no fixture is set" {
  render_setup
  unset AKIT_SYSCALLS_B64 AKIT_SYSCALLS_B32
  akit_stub ausyscall "case \"\$1\" in
  x86_64) echo 'Using x86_64 syscall table:'; awk '{print NR \"\\t\" \$1}' '$fixtures/rocky9-b64.txt' ;;
  i386) echo 'Using i386 syscall table:'; awk '{print NR \"\\t\" \$1}' '$fixtures/rocky9-b32.txt' ;;
  *) exit 1 ;;
esac"
  extra_rules '-a always,exit -F arch=b64 -S adjtimex,fakecall -k test_comma'
  render --extra-dir "$extra"
  [ "$status" -eq 0 ]
  grep -qx -- '-a always,exit -F arch=b64 -S adjtimex -k test_comma' "$out/50-test.rules"
  not grep -q "${tab}unknown_syscall${tab}adjtimex" "$report"
}

@test "render exits 1 when ausyscall is missing and no fixture is set" {
  render_setup
  unset AKIT_SYSCALLS_B64 AKIT_SYSCALLS_B32
  PATH="$(dirname "$(command -v awk)"):/usr/bin:/bin"
  if command -v ausyscall >/dev/null 2>&1; then
    skip "ausyscall is installed on this machine"
  fi
  render
  [ "$status" -eq 1 ]
  [[ "$output" == *ausyscall* ]]
}

@test "bad arguments exit 1" {
  render_setup
  render --profile huge
  [ "$status" -eq 1 ]
  render --size huge
  [ "$status" -eq 1 ]
  render --immutable yes
  [ "$status" -eq 1 ]
  render --extra-dir "$BATS_TEST_TMPDIR/nothere"
  [ "$status" -eq 1 ]
  render --bogus
  [ "$status" -eq 1 ]
  run sh "$lib/render.sh" --profile minimal --size standard --report "$report"
  [ "$status" -eq 1 ]
}

@test "a non-empty out dir is refused" {
  render_setup
  mkdir -p "$out"
  touch "$out/old.rules"
  render
  [ "$status" -eq 1 ]
}

@test "every profile renders on every OS fixture with no dropped unknown_syscall and passes validate" {
  render_setup
  for profile in minimal medium heavy; do
    for os in centos7 rocky8 rocky9 ubuntu2204 ubuntu2404; do
      rm -rf "$out" "$report"
      AKIT_SYSCALLS_B64="$fixtures/$os-b64.txt" AKIT_SYSCALLS_B32="$fixtures/$os-b32.txt" \
        render --profile "$profile" --immutable true
      [ "$status" -eq 0 ] || { echo "$profile/$os: $output"; false; }
      [[ "$output" == rule_count=* ]]
      not grep -q "${tab}dropped${tab}unknown_syscall${tab}" "$report" || { echo "$profile/$os: dropped unknown_syscall"; false; }
      run sh "$lib/validate.sh" "$out"
      [ "$status" -eq 0 ] || { echo "$profile/$os: validate: $output"; false; }
      [ -z "$output" ]
    done
  done
}

@test "a missing binary drops only its own rule and keeps the others" {
  render_setup
  mkdir -p "$AKIT_ROOT/usr/bin" "$AKIT_ROOT/usr/sbin" "$AKIT_ROOT/etc"
  for b in bin/sudo bin/su bin/kmod sbin/auditctl sbin/augenrules sbin/auditd; do
    touch "$AKIT_ROOT/usr/$b"
  done
  render --profile medium
  [ "$status" -eq 0 ]
  grep -qx -- '-a always,exit -F path=/usr/bin/sudo -F perm=x -k T1548_Abuse_Elevation_Control_Mechanism' "$out/10-auditd-kit-minimal.rules"
  not grep -q "path=/usr/bin/crontab" "$out/10-auditd-kit-minimal.rules"
  grep -q "10-minimal.rules:[0-9]*${tab}dropped${tab}missing_binary${tab}/usr/bin/crontab\$" "$report"
}

@test "heavy never renders the commented all-process execve rule" {
  render_setup
  render --profile heavy
  [ "$status" -eq 0 ]
  grep -q -- '-S execve,execveat -F auid>=1000' "$out/91-auditd-kit-medium-last.rules"
  [ "$(awk '!/^[[:space:]]*#/ && /-S execve/ && !/auid>=1000/' "$out"/*.rules | wc -l)" -eq 0 ]
}
