#!/usr/bin/env bats
# shellcheck disable=SC2154

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

setup() {
  akit_fixture_root
  akit_host_stubs
  mkdir -p "$AKIT_ROOT/etc/audit/rules.d" "$AKIT_ROOT/run"
  echo '-w /opt/app -p wa -k org_app' >"$AKIT_ROOT/etc/audit/rules.d/40-org.rules"
}

@test "backup.sh backs up a host that never ran install, and rollback restores it" {
  run sh "$repo/scripts/backup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == backup=* ]]
  id=${output#backup=}
  [ -f "$AKIT_ROOT/var/lib/auditd-kit/backups/$id.tgz" ]
  [ -f "$AKIT_ROOT/var/lib/auditd-kit/backups/original.tgz" ]
  echo '-w /broken' >"$AKIT_ROOT/etc/audit/rules.d/40-org.rules"
  run sh "$repo/scripts/rollback.sh" "$id"
  [ "$status" -eq 0 ]
  [ "$(cat "$AKIT_ROOT/etc/audit/rules.d/40-org.rules")" = '-w /opt/app -p wa -k org_app' ]
}

@test "backup.sh refuses when not root or given an argument" {
  run sh "$repo/scripts/backup.sh" --what
  [ "$status" -eq 1 ]
  echo 1000 >"$stub_state/uid"
  run sh "$repo/scripts/backup.sh"
  [ "$status" -eq 1 ]
  [ ! -d "$AKIT_ROOT/var/lib/auditd-kit/backups" ]
}
