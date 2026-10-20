#!/usr/bin/env bats
# The sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
lib="$repo/scripts/lib"

setup() {
  akit_host_fixture
  backups="$AKIT_ROOT/var/lib/auditd-kit/backups"
}

# backup <function> [args]: run a backup.sh function.
backup() {
  run sh -c '. "$1/common.sh"; . "$1/backup.sh"; shift; "$@"' sh "$lib" "$@"
}

# install_by_hand: change the host the way an install does.
install_by_hand() {
  rm "$AKIT_ROOT/etc/audit/rules.d/audit.rules"
  echo '-w /etc/passwd -p wa -k id' >"$AKIT_ROOT/etc/audit/rules.d/10-auditd-kit-minimal.rules"
  echo 'num_logs = 8' >>"$AKIT_ROOT/etc/audit/auditd.conf"
  echo 'new' >"$AKIT_ROOT/etc/audit/audit.rules"
  echo 'old' >"$AKIT_ROOT/etc/audit/audit.rules.prev"
  mkdir -p "$AKIT_ROOT/etc/auditd-kit"
  : >"$AKIT_ROOT/etc/auditd-kit/canary"
  echo 'version=0.0.0' >"$AKIT_ROOT/etc/auditd-kit/state"
}

@test "backup keeps the newest 5" {
  mkdir -p "$backups"
  : >"$backups/20261019T000000Z.tgz"
  akit_stub date 'echo 20261020T120000Z'
  for _ in 1 2 3 4 5 6 7; do
    backup akit_backup_create
    [ "$status" -eq 0 ]
  done
  [ "$output" = 20261020T120000Z-6 ]
  [ "$(cd "$backups" && echo *)" = "20261020T120000Z-2.tgz 20261020T120000Z-3.tgz 20261020T120000Z-4.tgz 20261020T120000Z-5.tgz 20261020T120000Z-6.tgz" ]
}

@test "two backups in the same second get distinct ids" {
  akit_stub date 'echo 20261020T120000Z'
  backup akit_backup_create
  [ "$output" = 20261020T120000Z ]
  backup akit_backup_create
  [ "$output" = 20261020T120000Z-1 ]
  tar -tzf "$backups/20261020T120000Z-1.tgz" | grep -qx etc/audit/auditd.conf
}

@test "restore gives checksum-identical /etc/audit and rsyslog.d" {
  before=$(akit_sums etc/audit etc/rsyslog.d)
  backup akit_backup_create
  id=$output
  install_by_hand
  [ "$(akit_sums etc/audit etc/rsyslog.d)" != "$before" ]
  backup akit_backup_restore "$id"
  [ "$status" -eq 0 ]
  [ "$(akit_sums etc/audit etc/rsyslog.d)" = "$before" ]
  [ ! -e "$AKIT_ROOT/etc/auditd-kit" ]
}

@test "restore keeps a file that auditd-kit did not add" {
  backup akit_backup_create
  id=$output
  echo '-w /tmp -p wa' >"$AKIT_ROOT/etc/audit/rules.d/60-later.rules"
  backup akit_backup_restore "$id"
  [ "$status" -eq 0 ]
  [ -f "$AKIT_ROOT/etc/audit/rules.d/60-later.rules" ]
  [[ "$output" == *"kept /etc/audit/rules.d/60-later.rules"* ]]
}

@test "restore of an unreadable or unknown backup fails and changes nothing" {
  backup akit_backup_create
  id=$output
  install_by_hand
  before=$(akit_sums etc)
  chmod 000 "$backups/$id.tgz"
  [ -r "$backups/$id.tgz" ] && skip "running as root"
  for bad in "$id" 20261020T000000Z ../x; do
    backup akit_backup_restore "$bad"
    [ "$status" -ne 0 ]
  done
  [ "$(akit_sums etc)" = "$before" ]
}
