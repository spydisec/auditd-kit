#!/usr/bin/env bats

load helpers

@test "akit_fixture_root makes a directory under the test temp dir and exports it" {
  akit_fixture_root
  [ -d "$AKIT_ROOT" ]
  case "$AKIT_ROOT" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *) false ;;
  esac
  run sh -c 'echo "${AKIT_ROOT:-unset}"'
  [ "$output" = "$AKIT_ROOT" ]
}

@test "akit_fixture_root gives a new directory on each call" {
  akit_fixture_root
  first=$AKIT_ROOT
  akit_fixture_root
  [ "$first" != "$AKIT_ROOT" ]
  [ -d "$first" ]
}

@test "akit_stub puts an executable stub first on PATH" {
  # shellcheck disable=SC2016
  akit_stub auditkit-demo 'echo "stub says $1"'
  run auditkit-demo hi
  [ "$status" -eq 0 ]
  [ "$output" = "stub says hi" ]
  [ "$(command -v auditkit-demo)" = "${AKIT_STUB_BIN}/auditkit-demo" ]
}

@test "akit_stub overrides a real command" {
  akit_stub uname 'echo stubbed'
  run uname
  [ "$output" = "stubbed" ]
}

@test "akit_stub keeps the exit status of the stub" {
  akit_stub auditkit-fail 'exit 7'
  run auditkit-fail
  [ "$status" -eq 7 ]
}

@test "akit_stub can add several stubs to the same directory" {
  akit_stub auditkit-one 'echo one'
  akit_stub auditkit-two 'echo two'
  run sh -c 'auditkit-one; auditkit-two'
  [ "$output" = "$(printf 'one\ntwo')" ]
}
