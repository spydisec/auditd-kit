#!/bin/sh
# Test the script path on a real kernel, on a GitHub Ubuntu runner.
#
# Usage: sudo AKIT_CI_OK=yes sh tests/ci/real-kernel.sh <minimal|medium|heavy>
#
# This changes the host. It installs auditd with apt, which is test setup and not part of
# auditd-kit, and it mounts a small loop file at /var/log/audit and fills it. Run it only on a
# runner or VM that is thrown away after the run, which is why it needs AKIT_CI_OK=yes.
#
# It checks that the survey changes nothing, that an install loads and verifies, that a second
# install has nothing to change, that a rollback gives back checksum-identical /etc/audit and
# /etc/rsyslog.d, that install undoes the forwarding of auditd-kit 0.2.0, and that a full audit disk
# doesn't halt the host.
set -eu
LC_ALL=C
export LC_ALL

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)
profile=${1:-}

step() {
  printf '\n== %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  # Print what is needed to see why the canary or a load failed.
  echo "== Diagnostics" >&2
  {
    date
    locale
    auditctl -s
    auditctl -l | grep -i canary
    ls -l /etc/auditd-kit
    echo "-- ausearch -k akit_canary:"
    ausearch -k akit_canary 2>&1 | tail -n 8
    echo "-- ausearch -ts recent -k akit_canary:"
    ausearch -ts recent -k akit_canary 2>&1 | tail -n 4
    echo "-- LC_ALL=C ausearch -ts <today 00:00:00>:"
    LC_ALL=C ausearch -k akit_canary -ts "$(LC_ALL=C date '+%m/%d/%y') 00:00:00" 2>&1 | tail -n 4
    echo "-- akit_canary lines in the logs:"
    grep -c akit_canary /var/log/audit/audit.log*
    grep akit_canary /var/log/audit/audit.log | cut -c1-300 | head -n 8
    echo "-- ausearch --input audit.log -k akit_canary:"
    ausearch --input /var/log/audit/audit.log -k akit_canary 2>&1 | head -n 6
    ausearch -v 2>&1 | head -n 1
    grep -E "^(log_file|log_format|name_format|write_logs)" /etc/audit/auditd.conf
    echo "-- newest install log:"
    tail -n 30 "$(find /var/log/auditd-kit -name 'install-*.log' 2>/dev/null | sort | tail -n 1)"
    echo "-- rules.d and auditd:"
    ls -l /etc/audit/rules.d
    systemctl is-active auditd
    journalctl -u auditd -n 15 --no-pager
    df -h /var/log/audit
    echo "-- rate limiting:"
    journalctl -u systemd-journald --no-pager | grep -iE 'suppress|rate' | tail -n 5
    journalctl -u rsyslog --no-pager | grep -iE 'rate-limit|ratelimit|dropp' | tail -n 5
    echo "-- canary SYSCALL in audit.log:"
    grep 'key="akit_canary"' /var/log/audit/audit.log | grep SYSCALL | tail -n 2 | cut -c1-200
    echo "-- tail of audit.log:"
    tail -n 5 /var/log/audit/audit.log
  } >&2 2>&1 || true
  exit 1
}

case "$profile" in
  minimal | medium | heavy) ;;
  *) fail "usage: real-kernel.sh <minimal|medium|heavy>" ;;
esac
[ "${AKIT_CI_OK:-}" = yes ] || fail "this changes the host, so set AKIT_CI_OK=yes on a throwaway runner"
[ "$(id -u)" -eq 0 ] || fail "run as root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# sums: the sorted sha256sum of every file under /etc/audit and /etc/rsyslog.d.
sums() {
  for d in /etc/audit /etc/rsyslog.d; do
    [ -d "$d" ] && find "$d" -type f -exec sha256sum {} +
  done | sort
}

# same_sums <file> <what>: fail when the checksums differ from the file.
same_sums() {
  sums >"$work/now"
  if ! diff -u "$1" "$work/now"; then
    fail "$2"
  fi
}

# run_install <out-file> <flags>...: run install.sh, show its output, and fail on a non-zero exit.
run_install() {
  out=$1
  shift
  rc=0
  sh "$repo/scripts/install.sh" "$@" >"$out" 2>&1 || rc=$?
  cat "$out"
  [ "$rc" -eq 0 ] || fail "install.sh $* exited $rc"
}

step "Test setup: install auditd with apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends auditd audispd-plugins rsyslog
service auditd start || true
service rsyslog start || true
auditctl -s

step "Record checksums of /etc/audit and /etc/rsyslog.d"
sums >"$work/before"
cat "$work/before"

step "The survey changes nothing"
sh "$repo/scripts/survey.sh"
same_sums "$work/before" "survey.sh changed a file"

step "Install the $profile profile"
run_install "$work/install1" --profile "$profile" --existing-rules replace
[ -f /var/lib/auditd-kit/render-report.txt ] || fail "no render report"
echo "Render report:"
cat /var/lib/auditd-kit/render-report.txt
auditctl -s
echo "$(auditctl -l | grep -c '^-[aw] ') rules loaded"

step "A second install has nothing to change"
run_install "$work/install2" --profile "$profile" --existing-rules replace
[ "$(tail -n 1 "$work/install2")" = changes=0 ] || fail "the second install changed something"

step "Rollback gives back the files from before the install"
sh "$repo/scripts/rollback.sh" || fail "rollback.sh exited $?"
same_sums "$work/before" "rollback did not restore /etc/audit and /etc/rsyslog.d"

step "Install undoes the forwarding of auditd-kit 0.2.0"
# The host as 0.2.0 left it with forwarding on: an active syslog plugin, our drop-in, and
# forward=remote in the state file.
mkdir -p /etc/auditd-kit
printf 'version=0.2.0\nforward=remote\n' >/etc/auditd-kit/state
echo "if \$syslogfacility-text == 'local6' then { stop }" >/etc/rsyslog.d/40-auditd-kit.conf
sed -i 's/^active = no/active = yes/' /etc/audit/plugins.d/syslog.conf
service rsyslog restart
service auditd restart
sums >"$work/old-before"
run_install "$work/install-old" --profile "$profile" --existing-rules replace
grep -qx 'active = no' /etc/audit/plugins.d/syslog.conf || fail "the syslog plugin is still active"
[ ! -e /etc/rsyslog.d/40-auditd-kit.conf ] || fail "the old drop-in is still there"
sh "$repo/scripts/rollback.sh" || fail "rollback.sh exited $? after the cleanup"
same_sums "$work/old-before" "rollback did not restore the 0.2.0 forwarding files"
rm -f /etc/rsyslog.d/40-auditd-kit.conf /etc/auditd-kit/state
sed -i 's/^active = yes/active = no/' /etc/audit/plugins.d/syslog.conf
service rsyslog restart
service auditd restart

step "A full audit disk doesn't halt the host"
start=$(date +%s)
img=/var/tmp/auditd-kit-test.img
dd if=/dev/zero of="$img" bs=1M count=128 2>/dev/null
mkfs.ext4 -q -F -m 0 "$img"
mount -o loop "$img" /var/log/audit
chmod 0750 /var/log/audit
df -h /var/log/audit
run_install "$work/install3" --profile "$profile" --existing-rules replace \
  --size small --max-log-file 5 --num-logs 4
dd if=/dev/zero of=/var/log/audit/fill bs=1M 2>/dev/null || true
df -h /var/log/audit
i=0
while [ "$i" -lt 200 ]; do
  echo "$i" >/etc/auditd-kit/canary
  auditctl -m "auditd-kit disk full test $i" 2>/dev/null || true
  i=$((i + 1))
done
sleep 5
uptime || fail "the host doesn't answer"
pgrep -x auditd >/dev/null || fail "auditd is not running"
journalctl --no-pager -t auditd --since "@$start" >"$work/journal" || true
cat "$work/journal"
grep -i 'suspending logging' "$work/journal" >/dev/null || fail "no disk full message from auditd in the journal"
rm -f /var/log/audit/fill

step "All checks passed"
