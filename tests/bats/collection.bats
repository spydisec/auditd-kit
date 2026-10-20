#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

setup() {
  command -v ansible-galaxy >/dev/null 2>&1 || skip "ansible-galaxy is not installed"
}

@test "the collection tarball holds the shared files and nothing private" {
  out="$BATS_TEST_TMPDIR/dist"
  run sh "$repo/scripts/dev/build-collection.sh" "$out"
  [ "$status" -eq 0 ]
  # The version comes from galaxy.yml, which release-please updates.
  set -- "$out"/spydisec-auditd_kit-*.tar.gz
  tarball=$1
  [ -f "$tarball" ]
  list=$(tar -tzf "$tarball")
  for want in roles/auditd/files/rules/10-minimal.rules roles/auditd/files/config/auditd/standard.conf \
    roles/auditd/files/scripts/survey.sh roles/auditd/files/scripts/lib/common.sh \
    playbooks/survey.yml playbooks/stats.yml; do
    printf '%s\n' "$list" | grep -qx -- "$want" || {
      echo "missing: $want" >&2
      false
    }
  done
  # Nothing private or development-only may ship.
  [ "$(printf '%s\n' "$list" | grep -cE '(^|/)(tests|docs|\.claude|dev)/')" -eq 0 ]
}
