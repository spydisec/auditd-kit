#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

@test "a release build stamps the version and checks out with SHA256SUMS" {
  command -v ansible-galaxy >/dev/null 2>&1 || skip "ansible-galaxy is not installed"
  out="$BATS_TEST_TMPDIR/dist"
  run sh "$repo/scripts/dev/build-release.sh" 1.2.3 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/auditd-kit-1.2.3.tar.gz" ] && [ -f "$out/spydisec-auditd_kit-1.2.3.tar.gz" ]
  (cd "$out" && sha256sum -c SHA256SUMS)
  list=$(tar -tzf "$out/auditd-kit-1.2.3.tar.gz")
  printf '%s\n' "$list" | grep -qx 'auditd-kit-1.2.3/scripts/install.sh'
  [ "$(printf '%s\n' "$list" | grep -cE '/(tests|docs|dev)/')" -eq 0 ]
  tar -xzOf "$out/auditd-kit-1.2.3.tar.gz" auditd-kit-1.2.3/scripts/lib/common.sh | grep -qx 'AKIT_VERSION=1.2.3'
  tar -xzOf "$out/spydisec-auditd_kit-1.2.3.tar.gz" roles/auditd/files/scripts/lib/common.sh \
    | grep -qx 'AKIT_VERSION=1.2.3'
}

@test "a release build refuses a bad version" {
  for v in v1.2 1.2 "1.2.3
x"; do
    run sh "$repo/scripts/dev/build-release.sh" "$v" "$BATS_TEST_TMPDIR/dist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"version must be X.Y.Z"* ]]
  done
}
