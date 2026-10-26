#!/usr/bin/env bats

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

# load_settings <arg>...: load the settings and print every setting as key=value.
load_settings() {
  sh -c '
    . "$1/scripts/lib/common.sh"
    . "$1/scripts/lib/settings.sh"
    shift
    akit_settings_load "$@"
    for k in $AKIT_SETTING_KEYS akit_fwd_mode akit_fwd_proto akit_fwd_host akit_fwd_port akit_backlog akit_preset_total_mb; do
      eval "printf \"%s=%s\\n\" $k \"\$$k\""
    done
    echo "args=$AKIT_ARGS"
  ' sh "$repo" "$@"
}

# config <line>...: write a config file and set cfg to its path.
config() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/akit.conf"
  cfg="$BATS_TEST_TMPDIR/akit.conf"
}

@test "defaults match the spec" {
  run load_settings
  [ "$status" -eq 0 ]
  expected="akit_profile=minimal
akit_size=standard
akit_max_log_file=100
akit_num_logs=8
akit_forward=none
akit_syslog_facility=local6
akit_immutable=false
akit_existing_rules=unset
akit_extra_rules_dir=
akit_accept=
akit_skip_keys=
akit_fwd_mode=none
akit_fwd_proto=
akit_fwd_host=
akit_fwd_port=
akit_backlog=16384
akit_preset_total_mb=800
args="
  [ "$output" = "$expected" ]
}

@test "each size sets its backlog and total" {
  for row in small:8192:250 standard:16384:800 large:32768:2000; do
    size=${row%%:*}
    rest=${row#*:}
    run load_settings --size "$size"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "akit_backlog=${rest%%:*}"
    echo "$output" | grep -qx "akit_preset_total_mb=${rest#*:}"
  done
}

@test "flag overrides config file, config overrides default" {
  config '# comment' '' 'akit_profile=medium' 'akit_size=small' '  akit_syslog_facility = local3'
  sed -i 's/$/\r/' "$cfg"
  run load_settings --config "$cfg" --size=large extra
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'akit_profile=medium'
  echo "$output" | grep -qx 'akit_size=large'
  echo "$output" | grep -qx 'akit_syslog_facility=local3'
  echo "$output" | grep -qx 'args=extra'
}

@test "a bad key, flag, or value exits 1 and names the setting" {
  for row in 'akit_profle=minimal:akit_profle' 'akit_size=huge:akit_size' \
    'akit_forward=tcp://h:70000:akit_forward' 'akit_immutable=yes:akit_immutable' \
    'akit_accept=low_disk:akit_accept' 'akit_skip_keys=a;b:akit_skip_keys' \
    'not a pair:not a pair'; do
    config "${row%:*}"
    run load_settings --config "$cfg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid setting ${row##*:}:"* ]]
  done
  run load_settings --bogus x
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid setting akit_bogus"* ]]
}

@test "config file is not sourced" {
  rm -f "$BATS_TEST_TMPDIR/x"
  config "akit_profile=\$(touch $BATS_TEST_TMPDIR/x)"
  run load_settings --config "$cfg"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
}

@test "max_log_file override changes preset total" {
  config 'akit_max_log_file=50'
  run load_settings --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'akit_preset_total_mb=400'
}

@test "a forward URL sets the mode, protocol, host, and port" {
  while IFS='|' read -r url want; do
    run load_settings --forward "$url"
    [ "$status" -eq 0 ] || { echo "$url: $output"; false; }
    got=$(printf '%s\n' "$output" | sed -n 's/^akit_fwd_[a-z]*=//p' | tr '\n' ' ')
    [ "$got" = "$want" ] || { echo "$url: got '$got'"; false; }
  done <<'EOT'
local|local    |
tcp://siem.example.com:6514|remote tcp siem.example.com 6514 |
udp://192.0.2.10|remote udp 192.0.2.10 514 |
tcp://[2001:db8::1]:514|remote tcp 2001:db8::1 514 |
tcp://[2001:db8::1]|remote tcp 2001:db8::1 514 |
EOT
}

@test "a bad forward URL exits 1 and says why" {
  while IFS='|' read -r url want; do
    run load_settings --forward "$url"
    [ "$status" -eq 1 ] && [[ "$output" == *"$want"* ]] || { echo "$url: $output"; false; }
  done <<'EOT'
remote|use akit_forward=tcp://host:port
ftp://h|is not none, local, or a tcp:// or udp:// URL
tcp://2001:db8::1|put an IPv6 address in brackets
tcp://|has no valid host name or address
tcp://h:0|has no port from 1 to 65535
tcp://h:514/|has no port from 1 to 65535
EOT
}

@test "akit_accept takes agent_conflict codes and catchall_forward only" {
  run load_settings --accept agent_conflict:wazuh,catchall_forward
  [ "$status" -eq 0 ]
  for bad in low_disk agent_conflict: 'agent_conflict:a b'; do
    run load_settings --accept "$bad"
    [ "$status" -eq 1 ] || { echo "$bad: $output"; false; }
  done
}

@test "the settings ADR 0024 removed exit 1 and name the replacement" {
  while IFS='|' read -r flag want; do
    run load_settings "$flag" x
    [ "$status" -eq 1 ] && [[ "$output" == *"$want"* ]] || { echo "$flag: $output"; false; }
  done <<'EOT'
--remote-host|use akit_forward=tcp://host:port
--remote-port|use akit_forward=tcp://host:port
--remote-protocol|use akit_forward=tcp://host:port
--accept-agents|use akit_accept=agent_conflict:<agent>
--accept-catchall|use akit_accept=catchall_forward
EOT
}

@test "old names exit 1 and name the new value" {
  run load_settings --profile standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"akit_profile"*"heavy"* ]]
  run load_settings --size medium
  [ "$status" -eq 1 ]
  [[ "$output" == *"akit_size"*"standard"* ]]
}

@test "listed extra flags pass through and others are rejected" {
  AKIT_EXTRA_FLAGS="--dry-run --skip-load" run load_settings --dry-run --size small --skip-load file
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'akit_size=small'
  echo "$output" | grep -qx 'args=--dry-run --skip-load file'
  AKIT_EXTRA_FLAGS="--dry-run" run load_settings --skip-load
  [ "$status" -eq 1 ]
}
