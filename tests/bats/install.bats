#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"

setup() {
  akit_host_fixture
  conf="$AKIT_ROOT/etc/audit/auditd.conf"
  rules_d="$AKIT_ROOT/etc/audit/rules.d"
}

# conf_set <file> <key> <value>
conf_set() {
  run sh -c '. "$1/common.sh"; . "$1/auditdconf.sh"; akit_auditdconf_set "$2" "$3" "$4"' sh "$lib" "$@"
}

# render_to <dir> [render flags]: render the minimal profile into a new dir.
render_to() {
  out=$1
  shift
  sh "$lib/render.sh" --profile minimal --size standard --out-dir "$out" \
    --report "$BATS_TEST_TMPDIR/report.txt" "$@" >/dev/null
}

# plan_lines: the plan's change lines, without the diffs.
plan_lines() {
  printf '%s\n' "$output" | grep -E '^(add|change|move|set) ' || true
}

# deploy_by_hand <rendered-dir>: make the host look like auditd-kit installed it.
deploy_by_hand() {
  rm -f "$rules_d/audit.rules"
  cp "$1"/*.rules "$rules_d/"
  mkdir -p "$AKIT_ROOT/etc/auditd-kit"
  : >"$AKIT_ROOT/etc/auditd-kit/canary"
  sh -c '. "$1/common.sh"; . "$1/settings.sh"; . "$1/auditdconf.sh"; akit_settings_load
    akit_auditdconf_wanted "$1/../.." | while read -r k v; do akit_auditdconf_set "$2" "$k" "$v"; done' \
    sh "$lib" "$conf"
}

@test "auditdconf_set replaces only the key line and keeps comments and unknown keys" {
  printf '%s\n' '# max_log_file = 1 is the old value' '  max_log_file=8' 'unknown_key = x' \
    'max_log_file_action = ROTATE' >"$conf"
  conf_set "$conf" max_log_file 100
  [ "$status" -eq 0 ]
  [ "$(cat "$conf")" = "$(printf '%s\n' '# max_log_file = 1 is the old value' 'max_log_file = 100' \
    'unknown_key = x' 'max_log_file_action = ROTATE')" ]
}

@test "auditdconf_set appends a missing key" {
  printf '%s\n' 'log_file = /var/log/audit/audit.log' >"$conf"
  conf_set "$conf" disk_full_action SUSPEND
  [ "$status" -eq 0 ]
  [ "$(cat "$conf")" = "$(printf '%s\n' 'log_file = /var/log/audit/audit.log' 'disk_full_action = SUSPEND')" ]
}

@test "plan lists move for control-only distro audit.rules" {
  render_to "$BATS_TEST_TMPDIR/out"
  run sh "$lib/plan.sh" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(plan_lines)" = "add /etc/audit/rules.d/00-auditd-kit-base.rules
add /etc/audit/rules.d/10-auditd-kit-minimal.rules
move /etc/audit/rules.d/audit.rules
set /etc/audit/auditd.conf max_log_file
set /etc/audit/auditd.conf num_logs
set /etc/audit/auditd.conf name_format
add /etc/auditd-kit/canary" ]
  [[ "$output" == *"+++ /etc/audit/auditd.conf"* ]]
  [[ "$output" == *"+max_log_file = 100"* ]]
}

@test "plan on an already-installed fixture prints nothing" {
  render_to "$BATS_TEST_TMPDIR/out"
  deploy_by_hand "$BATS_TEST_TMPDIR/out"
  run sh "$lib/plan.sh" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plan moves our files that the profile no longer has" {
  render_to "$BATS_TEST_TMPDIR/heavy" --profile heavy
  deploy_by_hand "$BATS_TEST_TMPDIR/heavy"
  render_to "$BATS_TEST_TMPDIR/out"
  run sh "$lib/plan.sh" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(plan_lines)" = "move /etc/audit/rules.d/20-auditd-kit-medium.rules
move /etc/audit/rules.d/30-auditd-kit-heavy.rules" ]
}
