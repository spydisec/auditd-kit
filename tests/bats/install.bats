#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016
# akit_host_stubs in helpers.bash sets calls and stub_state.
# shellcheck disable=SC2154

load helpers
bats_require_minimum_version 1.5.0

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"

setup() {
  fresh_host
  akit_host_stubs
}

# fresh_host: a new host fixture, with $conf and $rules_d pointing into it.
fresh_host() {
  akit_host_fixture
  conf="$AKIT_ROOT/etc/audit/auditd.conf"
  rules_d="$AKIT_ROOT/etc/audit/rules.d"
}

# install [flags]: run install.sh.
install() {
  run sh "$repo/scripts/install.sh" "$@" </dev/null
}

# config_sums: checksums of everything an install may change.
config_sums() {
  akit_sums etc var/lib
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
add /etc/audit/rules.d/90-auditd-kit-minimal-last.rules
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
move /etc/audit/rules.d/30-auditd-kit-heavy.rules
move /etc/audit/rules.d/91-auditd-kit-medium-last.rules" ]
}

@test "dry-run changes nothing and prints the plan" {
  before=$(config_sums)
  install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"move /etc/audit/rules.d/audit.rules"* ]]
  [[ "$output" == *"+max_log_file = 100"* ]]
  [[ "$output" == *"changes=8"* ]]
  [ "$(config_sums)" = "$before" ]
  [ ! -e "$AKIT_ROOT/run/auditd-kit.lock" ]
}

@test "fresh install writes the rule files, sets auditd.conf keys, creates the canary, writes state" {
  install
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = changes=8 ]
  [ -f "$rules_d/00-auditd-kit-base.rules" ] && [ -f "$rules_d/10-auditd-kit-minimal.rules" ]
  [ ! -e "$rules_d/audit.rules" ]
  grep -qx 'max_log_file = 100' "$conf" && grep -qx 'name_format = hostname' "$conf"
  grep -qx 'log_group = adm' "$conf"
  [ -f "$AKIT_ROOT/etc/auditd-kit/canary" ]
  state="$AKIT_ROOT/etc/auditd-kit/state"
  grep -qx profile=minimal "$state" && grep -q '^rule_count=[1-9]' "$state"
  [ "$(grep -c '^file=' "$state")" -eq 4 ]
  grep -q '^file=[0-9a-f]* /etc/audit/auditd.conf$' "$state"
  run ! grep -q canary "$state"
  [ -f "$AKIT_ROOT/var/lib/auditd-kit/render-report.txt" ]
  ls "$AKIT_ROOT"/var/log/auditd-kit/install-*.log >/dev/null
  [ ! -e "$AKIT_ROOT/run/auditd-kit.lock" ]
}

@test "second run prints changes=0 and makes no backup" {
  install
  [ "$status" -eq 0 ]
  install
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = changes=0 ]
  set -- "$AKIT_ROOT"/var/lib/auditd-kit/backups/*.tgz
  [ $# -eq 1 ]
}

@test "each preflight refusal exits 1 and changes nothing" {
  # The table rows use fx.
  # shellcheck disable=SC2034
  fx="$BATS_TEST_DIRNAME/../fixtures"
  while IFS='|' read -r want flags change; do
    fresh_host
    eval "$change"
    before=$(config_sums)
    # shellcheck disable=SC2086
    install $flags
    [ "$status" -eq 1 ] || { echo "$want: status $status: $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "$want: $output"; return 1; }
    [ "$(config_sums)" = "$before" ] || { echo "$want: files changed"; return 1; }
    rm -f "$stub_state"/*
  done <<'EOF'
refuse=not_root||echo 1000 >"$stub_state/uid"
refuse=unsupported_os||cp "$fx/hosts/debian12/etc/os-release" "$AKIT_ROOT/etc/os-release"
refuse=immutable||echo 2 >"$stub_state/enabled"
refuse=low_disk||echo 1000 >"$stub_state/free"
refuse=agent_conflict:mde||mkdir -p "$AKIT_ROOT/opt/microsoft/mdatp"
refuse=existing_rules||echo '-w /etc/hosts -p wa -k hosts' >"$rules_d/50-site.rules"
refuse=existing_rules_control|--existing-rules keep|echo '-e 2' >"$rules_d/50-site.rules"
invalid setting akit_size|--size huge|:
another auditd-kit run holds the lock|--dry-run|echo $$ >"$AKIT_ROOT/run/auditd-kit.lock"
unknown argument: extra|extra|:
EOF
  if [ ! -e /sbin/auditctl ] && [ ! -e /usr/sbin/auditctl ]; then
    rm "$AKIT_STUB_BIN/auditctl"
    install
    [ "$status" -eq 1 ] && [[ "$output" == *refuse=auditd_missing* ]]
  fi
}

@test "augenrules failure rolls back and exits 2" {
  before=$(akit_sums etc/audit etc/rsyslog.d)
  echo : >"$stub_state/augenrules_fails"
  install
  [ "$status" -eq 2 ]
  [ "$(akit_sums etc/audit etc/rsyslog.d)" = "$before" ]
  [ ! -e "$AKIT_ROOT/etc/auditd-kit" ]
  akit_called "auditctl -R $AKIT_ROOT/etc/audit/audit.rules"
}

@test "verify failure rolls back and exits 2" {
  before=$(akit_sums etc/audit etc/rsyslog.d)
  : >"$stub_state/ausearch_fails"
  install
  [ "$status" -eq 2 ]
  [[ "$output" == *"check=canary result=fail"* ]]
  [ "$(akit_sums etc/audit etc/rsyslog.d)" = "$before" ]
}

@test "rollback failure exits 3" {
  echo 'chmod 000 "$AKIT_ROOT"/var/lib/auditd-kit/backups/*.tgz' >"$stub_state/augenrules_fails"
  install
  archive=$(echo "$AKIT_ROOT"/var/lib/auditd-kit/backups/*.tgz)
  [ -r "$archive" ] && skip "running as root"
  [ "$status" -eq 3 ]
  [[ "$output" == *"rollback failed"* ]]
}

@test "auditd.conf change restarts with service, not systemctl" {
  install
  [ "$status" -eq 0 ]
  akit_called "service auditd restart"
  run ! grep -E '^systemctl (restart|stop|start|reload)' "$calls"
}

@test "rules-only change runs augenrules --load and no restart" {
  install
  [ "$status" -eq 0 ]
  : >"$calls"
  install --profile medium
  [ "$status" -eq 0 ]
  akit_called "augenrules --load"
  run ! akit_called service
  [ -f "$rules_d/20-auditd-kit-medium.rules" ]
}

@test "replace removes foreign rules files, keep leaves them" {
  for mode in replace keep; do
    fresh_host
    echo '-w /etc/hosts -p wa -k hosts' >"$rules_d/50-site.rules"
    install --existing-rules "$mode"
    [ "$status" -eq 0 ]
    if [ "$mode" = replace ]; then
      [ ! -e "$rules_d/50-site.rules" ]
    else
      [ -f "$rules_d/50-site.rules" ]
    fi
  done
}

@test "a deploy failure removes the overlay files it wrote" {
  mkdir "$BATS_TEST_TMPDIR/extra"
  echo '-w /etc/hosts -p wa -k hosts' >"$BATS_TEST_TMPDIR/extra/50-site.rules"
  before=$(akit_sums etc/audit etc/rsyslog.d)
  # The state file can't be written, so deploy fails after it wrote the rules.
  mkdir -p "$AKIT_ROOT/etc/auditd-kit/state.tmp"
  install --extra-rules-dir "$BATS_TEST_TMPDIR/extra"
  [ "$status" -eq 2 ]
  [ "$(akit_sums etc/audit etc/rsyslog.d)" = "$before" ]
}
