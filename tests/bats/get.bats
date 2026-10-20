#!/usr/bin/env bats

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
get="$repo/scripts/get.sh"

# A mirror dir with a fake 9.9.9 bundle, whose install.sh prints its arguments.
setup() {
  akit_stub id 'echo 0'
  mirror="$BATS_TEST_TMPDIR/mirror"
  mkdir -p "$mirror" "$BATS_TEST_TMPDIR/b/auditd-kit-9.9.9/scripts"
  printf '%s\n' 'echo "install ran: $*"' >"$BATS_TEST_TMPDIR/b/auditd-kit-9.9.9/scripts/install.sh"
  tar -C "$BATS_TEST_TMPDIR/b" -czf "$mirror/auditd-kit-9.9.9.tar.gz" auditd-kit-9.9.9
  (cd "$mirror" && sha256sum auditd-kit-9.9.9.tar.gz >SHA256SUMS)
  export AKIT_MIRROR="file://$mirror" AKIT_DIR="$BATS_TEST_TMPDIR/opt"
}

@test "get checks the bundle, unpacks it, and runs install.sh with the arguments" {
  run sh "$get" --profile medium --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"install ran: --profile medium --dry-run"* ]]
  [ -f "$AKIT_DIR/auditd-kit-9.9.9/scripts/install.sh" ]
}

@test "a bundle that doesn't match SHA256SUMS never runs" {
  echo tampered >>"$mirror/auditd-kit-9.9.9.tar.gz"
  run sh "$get"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match SHA256SUMS"* ]]
  [[ "$output" != *"install ran"* ]]
  [ ! -e "$AKIT_DIR/auditd-kit-9.9.9" ]
}

@test "a pinned version that the mirror doesn't have exits 1" {
  AKIT_VERSION=1.0.0 run sh "$get"
  [ "$status" -eq 1 ]
  [[ "$output" == *"asked for 1.0.0, but"*"has 9.9.9"* ]]
}

@test "get refuses to run without root" {
  akit_stub id 'echo 1000'
  run sh "$get"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run it as root"* ]]
}
