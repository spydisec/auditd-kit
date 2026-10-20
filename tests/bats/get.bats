#!/usr/bin/env bats
# The fake install.sh expands its own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
get="$repo/scripts/get.sh"

# A mirror dir with a fake 9.9.9 bundle. Its install.sh prints its arguments and changes=3, prints
# refuse=low_disk and exits with FAKE_RC when that is set.
setup() {
  akit_stub id 'echo 0'
  # The test dirs belong to the test user, so stat reports them as root's.
  akit_stub stat 'echo 0'
  mirror="$BATS_TEST_TMPDIR/mirror"
  mkdir -p "$mirror" "$BATS_TEST_TMPDIR/b/auditd-kit-9.9.9/scripts"
  printf '%s\n' 'echo "install ran: $*"' '[ -z "${FAKE_RC:-}" ] || { echo "refuse=low_disk override=x"; exit "$FAKE_RC"; }' \
    'echo changes=3' >"$BATS_TEST_TMPDIR/b/auditd-kit-9.9.9/scripts/install.sh"
  tar -C "$BATS_TEST_TMPDIR/b" -czf "$mirror/auditd-kit-9.9.9.tar.gz" auditd-kit-9.9.9
  (cd "$mirror" && sha256sum auditd-kit-9.9.9.tar.gz >SHA256SUMS)
  export AKIT_MIRROR="file://$mirror" AKIT_DIR="$BATS_TEST_TMPDIR/opt"
}

# get [args]: run get.sh with no controlling terminal, as from ssh or a config tool.
get() {
  run setsid -w sh "$get" "$@"
}

@test "with --yes, get checks the bundle, unpacks it, and runs install.sh with the arguments" {
  get --profile medium --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"install ran: --profile medium"$'\n'* ]]
  [ -f "$AKIT_DIR/auditd-kit-9.9.9/scripts/install.sh" ]
  [ "${lines[${#lines[@]} - 1]}" = "result=installed version=9.9.9 host=$(uname -n)" ]
}

@test "without --yes and with no terminal, get only plans" {
  get --profile medium
  [ "$status" -eq 0 ]
  [[ "$output" == *"install ran: --dry-run --profile medium"* ]]
  [[ "${lines[${#lines[@]} - 1]}" == "result=planned "* ]]
}

@test "an explicit --dry-run with --yes reports planned, and an old copy of the version is replaced" {
  mkdir -p "$AKIT_DIR/auditd-kit-9.9.9/scripts/lib"
  touch "$AKIT_DIR/auditd-kit-9.9.9/scripts/lib/planted.sh"
  get --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "${lines[${#lines[@]} - 1]}" == "result=planned "* ]]
  [ ! -e "$AKIT_DIR/auditd-kit-9.9.9/scripts/lib/planted.sh" ]
}

@test "an AKIT_DIR that root doesn't own is refused" {
  akit_stub stat 'echo 1000'
  get --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be owned by root"* ]]
  [[ "$output" != *"install ran"* ]]
}

@test "a mirror that isn't https or file is refused" {
  AKIT_MIRROR=http://example.com/auditd-kit get
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an https:// or file:// URL"* ]]
}

@test "a refusal ends with result=refused and its codes, and keeps the exit code" {
  FAKE_RC=1 get --yes
  [ "$status" -eq 1 ]
  [[ "${lines[${#lines[@]} - 1]}" == "result=refused version=9.9.9 host="*" codes=low_disk" ]]
}

@test "a bundle that doesn't match SHA256SUMS never runs" {
  echo tampered >>"$mirror/auditd-kit-9.9.9.tar.gz"
  get
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match SHA256SUMS"* ]]
  [[ "$output" != *"install ran"* ]]
  [ ! -e "$AKIT_DIR/auditd-kit-9.9.9" ]
}

@test "a pinned version that the mirror doesn't have exits 1" {
  AKIT_VERSION=1.0.0 get
  [ "$status" -eq 1 ]
  [[ "$output" == *"asked for 1.0.0, but"*"has 9.9.9"* ]]
}

@test "get refuses to run without root" {
  akit_stub id 'echo 1000'
  get
  [ "$status" -eq 1 ]
  [[ "$output" == *"run it as root"* ]]
}
