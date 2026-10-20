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
# /etc/rsyslog.d, that forwarding to a TCP sink reaches the sink and leaves the other rsyslog files
# alone, and that a full audit disk doesn't halt the host.
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
    echo "-- forwarding:"
    pgrep -a audisp || echo "no audisp process"
    grep -vE '^\s*(#|$)' /etc/audit/plugins.d/syslog.conf
    cat /etc/rsyslog.d/40-auditd-kit.conf
    grep -h akit_canary /var/log/syslog /var/log/messages 2>/dev/null | tail -n 3
    ss -ltn | grep -E ':551[45]'
    journalctl -u rsyslog -n 15 --no-pager
    ls -l "${work:-/nonexistent}"/sink-* && tail -c 400 "$work"/sink-*
    echo "-- sink-ours: akit_canary lines, SYSCALL lines, first lines:"
    grep -c akit_canary "$work/sink-ours"
    grep -c 'type=SYSCALL' "$work/sink-ours"
    head -c 600 "$work/sink-ours"
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
cleanup() {
  pkill -x socat 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

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
apt-get install -y -q --no-install-recommends auditd audispd-plugins rsyslog socat
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

# wait_for <file> <text>: wait up to 30 seconds for the text to appear in the file.
wait_for() {
  w=0
  while [ "$w" -lt 30 ]; do
    grep -F -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 1
    w=$((w + 1))
  done
  return 1
}

step "Forwarding reaches the sink and leaves the other rsyslog files alone"
: >"$work/sink-ours"
: >"$work/sink-existing"
socat -u TCP-LISTEN:5514,bind=127.0.0.1,reuseaddr,fork "OPEN:$work/sink-ours,append" &
socat -u TCP-LISTEN:5515,bind=127.0.0.1,reuseaddr,fork "OPEN:$work/sink-existing,append" &
# A forward that was there before auditd-kit. It must keep working and must not change.
printf '%s\n' 'auth.* action(type="omfwd" target="127.0.0.1" port="5515" protocol="tcp")' \
  >/etc/rsyslog.d/30-existing.conf
service rsyslog restart
sums >"$work/fwd-before"
ls /etc/rsyslog.d >"$work/fwd-ls-before"
sha256sum /etc/rsyslog.conf /etc/rsyslog.d/30-existing.conf >"$work/fwd-main-before"
run_install "$work/install-fwd" --profile "$profile" --existing-rules replace \
  --forward remote --remote-host 127.0.0.1 --remote-port 5514
ls /etc/rsyslog.d >"$work/fwd-ls-after"
{
  cat "$work/fwd-ls-before"
  echo 40-auditd-kit.conf
} | sort >"$work/fwd-ls-want"
sort "$work/fwd-ls-after" | diff -u "$work/fwd-ls-want" - || fail "the install added or removed an rsyslog.d file other than ours"
sha256sum /etc/rsyslog.conf /etc/rsyslog.d/30-existing.conf | diff -u "$work/fwd-main-before" - \
  || fail "the install changed rsyslog.conf or 30-existing.conf"
grep -qx 'active = yes' /etc/audit/plugins.d/syslog.conf || fail "the syslog plugin is not active"
# Empty the sink first, so that only a new event passes the check.
: >"$work/sink-ours"
# This shell started before auditd enabled auditing and may have no syscall audit context.
# Open and write the canary in a new process so that the kernel audits the write.
sh -c 'echo "canary $(date)" >/etc/auditd-kit/canary'
wait_for "$work/sink-ours" akit_canary || fail "the canary event did not reach the sink on port 5514"
logger -p auth.info "auditd-kit-marker-$$"
wait_for "$work/sink-existing" "auditd-kit-marker-$$" || fail "the existing auth forward stopped working"
grep -F -q "auditd-kit-marker-$$" "$work/sink-ours" && fail "our sink got an auth message"

# A 20 KB execve argument. The drop-in sets maxMessageSize, which some rsyslog versions ignore in
# a drop-in. That is only a warning, because auditd-kit never edits rsyslog.conf to fix it.
auditctl -a always,exit -F arch=b64 -S execve -k akit_longtest || fail "cannot add the long event test rule"
long=$(head -c 20000 /dev/zero | tr '\0' a)
/bin/true "AKITLONG${long}AKITEND"
auditctl -d always,exit -F arch=b64 -S execve -k akit_longtest
if wait_for "$work/sink-ours" AKITEND; then
  echo "The long execve event reached the sink. Longest line: $(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$work/sink-ours") bytes"
else
  echo "WARNING: the long execve event did not reach the sink whole, so maxMessageSize may not take effect from a drop-in"
fi

sh "$repo/scripts/rollback.sh" || fail "rollback.sh exited $? after the forwarding install"
same_sums "$work/fwd-before" "rollback did not restore /etc/audit and /etc/rsyslog.d after forwarding"
pkill -x socat || true
rm -f /etc/rsyslog.d/30-existing.conf
service rsyslog restart

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
