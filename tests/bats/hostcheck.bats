#!/usr/bin/env bats
# The stub scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016
# akit_host_stubs in helpers.bash sets calls and stub_state.
# shellcheck disable=SC2154

load helpers
bats_require_minimum_version 1.5.0

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
fx="$BATS_TEST_DIRNAME/../fixtures"

setup() {
  akit_host_fixture
  akit_host_stubs
  rules_d="$AKIT_ROOT/etc/audit/rules.d"
}

hostcheck() {
  run sh "$repo/scripts/lib/hostcheck.sh" "$@"
}

# refuses <code> [flags]: the check exits 1 and prints the refusal.
refuses() {
  want=$1
  shift
  hostcheck "$@"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *"refuse=$want detail="* ]] || { echo "$output"; return 1; }
}

# passes [flags]: the check exits 0 and prints no refusal.
passes() {
  hostcheck "$@"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" != *"refuse="* ]] || { echo "$output"; return 1; }
}

@test "a clean host passes and prints the facts" {
  passes
  [[ "$output" == *"os_id=ubuntu"* ]]
  [[ "$output" == *"os_version=24.04"* ]]
  [[ "$output" == *"auditd_version=3.1.2"* ]]
  [[ "$output" == *"audit_enabled=1"* ]]
  [[ "$output" == *"agents_audit=none"* ]]
  [[ "$output" == *"rules_d_foreign=none"* ]]
  [[ "$output" != *"warn="* ]]
}

@test "the check changes nothing" {
  before=$(akit_sums etc var)
  passes
  [ "$(akit_sums etc var)" = "$before" ]
}

@test "not root refuses, and says nothing about the audit status" {
  echo 1000 >"$stub_state/uid"
  refuses not_root
  [[ "$output" != *"refuse=audit_off"* ]]
}

@test "a host with no augenrules refuses" {
  rm "$AKIT_STUB_BIN/augenrules"
  PATH=$(akit_path_without augenrules) refuses auditd_missing
}

@test "auditd older than 2.8 refuses" {
  akit_stub auditctl 'case "$1" in -v) echo "auditctl version 2.7.1" ;; -s) echo "enabled 1" ;; esac'
  refuses auditd_missing
  [[ "$output" == *"older than 2.8"* ]]
}

@test "auditd 2.8 passes" {
  akit_stub auditctl 'case "$1" in -v) echo "auditctl version 2.8.5" ;; -s) echo "enabled 1" ;; esac'
  passes
}

@test "a kernel with audit off refuses" {
  akit_stub auditctl 'case "$1" in -v) echo "auditctl version 3.1.2" ;; -s) exit 1 ;; esac'
  refuses audit_off
}

@test "low disk refuses" {
  echo 1000 >"$stub_state/free"
  refuses low_disk
}

@test "a kernel with audit off passes when the caller won't load rules" {
  akit_stub auditctl 'case "$1" in -v) echo "auditctl version 3.1.2" ;; -s) exit 1 ;; esac'
  HOSTCHECK_NEED_KERNEL=no passes
  [[ "$output" == *"audit_enabled=unknown"* ]]
}

# The check adds the sbin dirs to PATH, where a real service may be, so only tar is tested.
@test "tar is needed only when the caller says so" {
  path=$(akit_path_without tar)
  PATH=$path passes
  PATH=$path HOSTCHECK_NEED_TAR=yes refuses tar_missing
}

@test "an OS that CI doesn't test warns and passes" {
  cp "$fx/hosts/debian12/etc/os-release" "$AKIT_ROOT/etc/os-release"
  passes
  [[ "$output" == *"warn=untested_os detail="* ]]
  [[ "$output" == *"os_id=debian"* ]]
}

@test "a tested RHEL-family system gives no warning" {
  cp "$fx/hosts/rocky9/etc/os-release" "$AKIT_ROOT/etc/os-release"
  passes
  [[ "$output" != *"warn=untested_os"* ]]
}

@test "Wazuh who-data warns and passes" {
  mkdir -p "$AKIT_ROOT/var/ossec/etc"
  echo '<directories whodata="yes">/etc</directories>' >"$AKIT_ROOT/var/ossec/etc/ossec.conf"
  passes
  [[ "$output" == *"warn=agent_restart:wazuh detail="* ]]
  [[ "$output" == *"agents_audit=wazuh"* ]]
}

@test "Wazuh without who-data gives no warning" {
  mkdir -p "$AKIT_ROOT/var/ossec/etc"
  echo '<directories>/etc</directories>' >"$AKIT_ROOT/var/ossec/etc/ossec.conf"
  passes
  [[ "$output" != *"warn="* ]]
}

@test "osquery with audit on refuses" {
  mkdir -p "$AKIT_ROOT/etc/osquery"
  echo '--disable_audit=false' >"$AKIT_ROOT/etc/osquery/osquery.flags"
  refuses agent_needs_audit:osquery
}

@test "osquery with audit off passes" {
  mkdir -p "$AKIT_ROOT/etc/osquery"
  echo '--disable_audit=true' >"$AKIT_ROOT/etc/osquery/osquery.flags"
  passes
}

@test "Auditbeat with its own rules or a unicast socket refuses" {
  mkdir -p "$AKIT_ROOT/etc/auditbeat"
  printf '%s\n' '- module: auditd' '  audit_rules: |' '    -w /etc/passwd -p wa -k identity' \
    >"$AKIT_ROOT/etc/auditbeat/auditbeat.yml"
  refuses agent_needs_audit:auditbeat
  printf '%s\n' '- module: auditd' '  socket_type: unicast' >"$AKIT_ROOT/etc/auditbeat/auditbeat.yml"
  refuses agent_needs_audit:auditbeat
}

@test "Auditbeat in its default mode passes" {
  mkdir -p "$AKIT_ROOT/etc/auditbeat"
  printf '%s\n' '- module: auditd' >"$AKIT_ROOT/etc/auditbeat/auditbeat.yml"
  passes
}

@test "locked rules pass and are reported" {
  echo 2 >"$stub_state/enabled"
  passes
  [[ "$output" == *"audit_enabled=2"* ]]
}

@test "a foreign rules file needs a choice" {
  echo '-w /etc/hosts -p wa -k hosts' >"$rules_d/50-site.rules"
  refuses existing_rules
  [[ "$output" == *"rules_d_foreign=50-site.rules"* ]]
  passes --existing-rules keep
  passes --existing-rules replace
}

@test "a kept file with control lines refuses" {
  echo '-e 2' >"$rules_d/50-site.rules"
  refuses existing_rules_control --existing-rules keep
  passes --existing-rules replace
}

@test "a bad setting exits 1" {
  hostcheck --size huge
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid setting akit_size"* ]]
}
