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
    for k in $AKIT_SETTING_KEYS akit_backlog akit_preset_total_mb; do
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
akit_remote_host=
akit_remote_port=514
akit_remote_protocol=tcp
akit_immutable=false
akit_existing_rules=unset
akit_extra_rules_dir=
akit_accept_agents=
akit_accept_catchall=false
akit_skip_keys=
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
    'akit_remote_port=70000:akit_remote_port' 'akit_immutable=yes:akit_immutable' \
    'akit_accept_agents=a b:akit_accept_agents' 'akit_skip_keys=a;b:akit_skip_keys' \
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

@test "remote forward without remote_host exits 1" {
  run load_settings --forward remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid setting akit_remote_host"* ]]
  run load_settings --forward remote --remote-host logs.example.com
  [ "$status" -eq 0 ]
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
