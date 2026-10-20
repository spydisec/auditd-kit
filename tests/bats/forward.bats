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

# fwd <function> [arg]...: load the settings from FLAGS, then run a forward.sh function.
fwd() {
  # FLAGS is split on purpose.
  # shellcheck disable=SC2086
  sh -c '. "$1/common.sh"; . "$1/settings.sh"; . "$1/forward.sh"; f=$2; shift 2
    akit_settings_load $FLAGS; "$f" "$@"' sh "$lib" "$@"
}

@test "render matches the golden files for remote and local" {
  for mode in remote local; do
    FLAGS="--forward $mode --remote-host 192.0.2.10" run fwd akit_forward_render "$template" "$BATS_TEST_TMPDIR/$mode.conf"
    [ "$status" -eq 0 ]
    diff "$golden/$mode.conf" "$BATS_TEST_TMPDIR/$mode.conf"
  done
}

@test "udp changes only the protocol" {
  FLAGS="--forward remote --remote-host 192.0.2.10 --remote-protocol udp" fwd akit_forward_render "$template" "$BATS_TEST_TMPDIR/udp.conf"
  [ "$(diff "$golden/remote.conf" "$BATS_TEST_TMPDIR/udp.conf" | grep -c '^[<>]')" -eq 2 ]
  grep -q 'protocol="udp"' "$BATS_TEST_TMPDIR/udp.conf"
}

@test "every template line is a comment" {
  run grep -v '^#' "$template"
  [ "$status" -eq 1 ]
}
