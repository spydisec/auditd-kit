#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016
# akit_host_stubs in helpers.bash sets calls and stub_state.
# shellcheck disable=SC2154

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"
template="$repo/config/rsyslog/40-auditd-kit.conf"
golden="$repo/tests/fixtures/rsyslog/golden"

setup() {
  akit_host_fixture
  akit_host_stubs
  plugin="$AKIT_ROOT/etc/audit/plugins.d/syslog.conf"
  dropin="$AKIT_ROOT/etc/rsyslog.d/40-auditd-kit.conf"
}

# install [flags]: run install.sh.
install() {
  run sh "$repo/scripts/install.sh" "$@" </dev/null
}

# remote_install [flags]
remote_install() {
  install --forward tcp://192.0.2.10 "$@"
}

# fwd <function> [arg]...: load the settings from FLAGS, then run a forward.sh function.
fwd() {
  # FLAGS is split on purpose.
  # shellcheck disable=SC2086
  sh -c '. "$1/common.sh"; . "$1/settings.sh"; . "$1/forward.sh"; f=$2; shift 2
    akit_settings_load $FLAGS; "$f" "$@"' sh "$lib" "$@"
}

@test "render matches the golden files for remote and local" {
  for mode in remote local; do
    case $mode in remote) fl=tcp://192.0.2.10 ;; *) fl=local ;; esac
    FLAGS="--forward $fl" run fwd akit_forward_render "$template" "$BATS_TEST_TMPDIR/$mode.conf"
    [ "$status" -eq 0 ]
    diff "$golden/$mode.conf" "$BATS_TEST_TMPDIR/$mode.conf"
  done
}

@test "udp changes only the protocol" {
  FLAGS="--forward udp://192.0.2.10" fwd akit_forward_render "$template" "$BATS_TEST_TMPDIR/udp.conf"
  [ "$(diff "$golden/remote.conf" "$BATS_TEST_TMPDIR/udp.conf" | grep -c '^[<>]')" -eq 2 ]
  grep -q 'protocol="udp"' "$BATS_TEST_TMPDIR/udp.conf"
}

@test "every template line is a comment" {
  run grep -v '^#' "$template"
  [ "$status" -eq 1 ]
}

@test "forward=none leaves a plugin it didn't turn on, and touches no rsyslog file" {
  sed -i 's/^active = no/active = yes/' "$plugin"
  before=$(akit_sums etc/rsyslog.d etc/rsyslog.conf)
  install
  [ "$status" -eq 0 ]
  grep -qx 'active = yes' "$plugin"
  [ "$(akit_sums etc/rsyslog.d etc/rsyslog.conf)" = "$before" ]
  run ! akit_called "service rsyslog restart"
  run ! akit_called "rsyslogd -N1"
}

@test "forward=none turns off the plugin after auditd-kit turned it on" {
  remote_install
  [ "$status" -eq 0 ]
  grep -qx 'active = yes' "$plugin"
  install
  [ "$status" -eq 0 ]
  grep -qx 'active = no' "$plugin"
}

@test "forwarding without the plugin's config file refuses and changes nothing" {
  rm "$plugin"
  before=$(akit_sums etc)
  remote_install
  [ "$status" -eq 1 ]
  [[ "$output" == *refuse=syslog_plugin_missing* ]]
  [ "$(akit_sums etc)" = "$before" ]
}

@test "forwarding sets the plugin to active with the facility" {
  remote_install --syslog-facility local3
  [ "$status" -eq 0 ]
  grep -qx 'active = yes' "$plugin"
  grep -qx 'args = LOG_INFO LOG_LOCAL3' "$plugin"
  grep -q "'local3'" "$dropin"
  akit_called "service auditd restart"
}

@test "plugin path is /etc/audisp/plugins.d on the centos7 fixture" {
  mkdir -p "$AKIT_ROOT/etc/audisp/plugins.d"
  mv "$plugin" "$AKIT_ROOT/etc/audisp/plugins.d/syslog.conf"
  run fwd akit_forward_plugin_file
  [ "$output" = /etc/audisp/plugins.d/syslog.conf ]
  rm "$AKIT_ROOT/etc/audisp/plugins.d/syslog.conf"
  run fwd akit_forward_plugin_file
  [ "$status" -eq 1 ]
}

@test "rsyslogd -N1 failure removes our file and leaves rsyslog.d unchanged" {
  echo >"$stub_state/rsyslogd_fails"
  before=$(akit_sums etc/rsyslog.d etc/rsyslog.conf etc/audit)
  remote_install
  [ "$status" -eq 2 ]
  [ ! -e "$dropin" ]
  [ "$(akit_sums etc/rsyslog.d etc/rsyslog.conf etc/audit)" = "$before" ]
  run ! akit_called "service rsyslog restart"
}

@test "rsyslog restarts only when our drop-in changed" {
  # Each row: flags, then whether rsyslog restarts. The rows run in order on one host.
  while IFS='|' read -r flags restarts; do
    : >"$calls"
    # shellcheck disable=SC2086
    install $flags
    [ "$status" -eq 0 ] || { echo "$flags: $output"; return 1; }
    if [ "$restarts" = yes ]; then
      akit_called "service rsyslog restart" || { echo "$flags: no restart"; return 1; }
    else
      ! akit_called "service rsyslog restart" || { echo "$flags: restarted"; return 1; }
    fi
  done <<'EOF'
--forward tcp://192.0.2.10|yes
--forward tcp://192.0.2.10|no
--forward tcp://192.0.2.10 --profile medium|no
--forward tcp://192.0.2.10:6514|yes
--forward local|yes
--forward none|yes
--forward none|no
EOF
  [ ! -e "$dropin" ]
}

@test "install records the drop-in and the targets of other files, and a repeat run changes nothing" {
  printf '%s\n' 'auth.* action(type="omfwd" target="192.0.2.20" port="5515" protocol="tcp")' \
    >"$AKIT_ROOT/etc/rsyslog.d/30-existing.conf"
  remote_install
  [ "$status" -eq 0 ]
  state="$AKIT_ROOT/etc/auditd-kit/state"
  grep -qx 'syslog_forward_targets=192.0.2.20:5515/tcp' "$state"
  grep -q '^file=[0-9a-f]* /etc/rsyslog.d/40-auditd-kit.conf$' "$state"
  remote_install
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = changes=0 ]
  grep -qx 'syslog_forward_targets=192.0.2.20:5515/tcp' "$state"
}

@test "rollback removes the drop-in and restores the plugin file" {
  before=$(akit_sums etc/rsyslog.d etc/audit)
  remote_install
  [ -f "$dropin" ]
  run sh "$repo/scripts/rollback.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$dropin" ]
  [ "$(akit_sums etc/rsyslog.d etc/audit)" = "$before" ]
}

@test "catch-all refusal prints the stats estimate" {
  printf '%s\n' '*.* @@192.0.2.20:514' >"$AKIT_ROOT/etc/rsyslog.d/30-all.conf"
  cp "$repo/tests/fixtures/audit-logs/basic/audit.log" "$AKIT_ROOT/var/log/audit/"
  before=$(akit_sums etc)
  remote_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse=catchall_forward override=akit_accept=catchall_forward"* ]]
  [[ "$output" == *"estimate: "*" MB per day"* ]]
  [ "$(akit_sums etc)" = "$before" ]
  remote_install --accept catchall_forward
  [ "$status" -eq 0 ]
}
