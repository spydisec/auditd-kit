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
  akit_host_fixture
  akit_host_stubs
  plugin="$AKIT_ROOT/etc/audit/plugins.d/syslog.conf"
  dropin="$AKIT_ROOT/etc/rsyslog.d/40-auditd-kit.conf"
  state="$AKIT_ROOT/etc/auditd-kit/state"
}

# install [flags]: run install.sh.
# shellcheck disable=SC2120
install() {
  run sh "$repo/scripts/install.sh" "$@" </dev/null
}

# old_forwarding: the host as auditd-kit 0.2.0 left it with forwarding on.
old_forwarding() {
  mkdir -p "$AKIT_ROOT/etc/auditd-kit" "$AKIT_ROOT/etc/rsyslog.d"
  printf 'version=0.2.0\nforward=remote\n' >"$state"
  echo "if \$syslogfacility-text == 'local6' then { stop }" >"$dropin"
  sed -i 's/^active = no/active = yes/' "$plugin"
}

@test "install leaves a plugin it didn't turn on, and touches no rsyslog file" {
  sed -i 's/^active = no/active = yes/' "$plugin"
  before=$(akit_sums etc/rsyslog.d etc/rsyslog.conf)
  install
  [ "$status" -eq 0 ]
  grep -qx 'active = yes' "$plugin"
  [ "$(akit_sums etc/rsyslog.d etc/rsyslog.conf)" = "$before" ]
  run ! akit_called "service rsyslog restart"
  run ! grep -q '^forward=' "$state"
}

@test "install undoes the forwarding of an earlier version, and a repeat run changes nothing" {
  old_forwarding
  install
  [ "$status" -eq 0 ]
  [[ "$output" == *"set /etc/audit/plugins.d/syslog.conf active"* ]]
  [[ "$output" == *"move /etc/rsyslog.d/40-auditd-kit.conf"* ]]
  grep -qx 'active = no' "$plugin"
  [ ! -e "$dropin" ]
  akit_called "service rsyslog restart"
  akit_called "service auditd restart"
  run ! grep -q '^forward=' "$state"
  install
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = changes=0 ]
}

@test "a forward= line without the old drop-in leaves the plugin as it is" {
  old_forwarding
  rm "$dropin"
  install
  [ "$status" -eq 0 ]
  grep -qx 'active = yes' "$plugin"
  run ! akit_called "service rsyslog restart"
}

@test "the cleanup warns that forwarding is off, and restarts auditd before rsyslog" {
  old_forwarding
  install
  [ "$status" -eq 0 ]
  [[ "$output" == *"no longer sends audit events"*"send-audit-log.md"* ]]
  order=$(grep -E '^service (auditd|rsyslog) restart' "$calls" | tr '\n' ' ')
  [ "$order" = "service auditd restart service rsyslog restart " ]
}

@test "rollback after the cleanup brings back the drop-in and the plugin setting" {
  old_forwarding
  before=$(akit_sums etc/rsyslog.d etc/audit)
  install
  [ "$status" -eq 0 ]
  run sh "$repo/scripts/rollback.sh"
  [ "$status" -eq 0 ]
  [ "$(akit_sums etc/rsyslog.d etc/audit)" = "$before" ]
}

@test "plugin path is /etc/audisp/plugins.d on the centos7 fixture" {
  mkdir -p "$AKIT_ROOT/etc/audisp/plugins.d"
  mv "$plugin" "$AKIT_ROOT/etc/audisp/plugins.d/syslog.conf"
  run sh -c '. "$1/common.sh"; . "$1/forward.sh"; akit_forward_plugin_file' sh "$lib"
  [ "$output" = /etc/audisp/plugins.d/syslog.conf ]
  rm "$AKIT_ROOT/etc/audisp/plugins.d/syslog.conf"
  run sh -c '. "$1/common.sh"; . "$1/forward.sh"; akit_forward_plugin_file' sh "$lib"
  [ "$status" -eq 1 ]
}
