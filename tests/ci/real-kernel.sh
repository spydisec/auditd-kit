#!/bin/sh
# Test the script path on a real kernel, on a GitHub Ubuntu runner or in a RHEL-family VM.
#
# Usage: sudo AKIT_CI_OK=yes sh tests/ci/real-kernel.sh <minimal|medium|heavy>
#
# This changes the host. It installs auditd with apt or dnf, which is test setup and not part of
# auditd-kit, and it mounts a small loop file at /var/log/audit and fills it. Run it only on a
# runner or VM that is thrown away after the run, which is why it needs AKIT_CI_OK=yes.
#
# It checks that the host check changes nothing, that an install loads and verifies, that a second
# install has nothing to change, that a rollback gives back checksum-identical /etc/audit and
# /etc/rsyslog.d, and that a full audit disk doesn't halt the host.
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

step "Test setup: install auditd"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends auditd audispd-plugins rsyslog
  service rsyslog start || true
else
  # The RHEL family. The service command is in initscripts-service on RHEL 10 and in initscripts
  # before that. CentOS 7 has no package repos left, so a failed install is fine when its image
  # already holds the tools, which the loop below checks.
  pkg=dnf
  command -v dnf >/dev/null 2>&1 || pkg=yum
  "$pkg" install -y -q audit tar diffutils e2fsprogs || true
  "$pkg" install -y -q initscripts-service || "$pkg" install -y -q initscripts || true
  for tool in auditctl augenrules tar diff mkfs.ext4 service; do
    command -v "$tool" >/dev/null 2>&1 || fail "test setup: $tool is not installed"
  done
fi
service auditd start || true
auditctl -s

step "Record checksums of /etc/audit and /etc/rsyslog.d"
sums >"$work/before"
cat "$work/before"

step "The host check changes nothing"
sh "$repo/scripts/lib/hostcheck.sh" --existing-rules replace
same_sums "$work/before" "hostcheck.sh changed a file"

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

step "Install keeps another tool's rules and loads next to them"
# The file holds a copy of a kit rule written another way, a watch on a path that doesn't exist,
# and a rule of its own. Without -i in the base file, the first two would stop the load.
cat >/etc/audit/rules.d/40-ci-other.rules <<'RULES'
-a exit,always -F path=/usr/sbin/auditctl -F perm=x -F key=T1562_Impair_Defenses
-w /no/such/dir/ci -p wa -k ci_gone
-w /srv -p wa -k ci_other
RULES
other_sum=$(sha256sum </etc/audit/rules.d/40-ci-other.rules)
# A rule that an agent added with auditctl, which is in no file. Install must put it back.
auditctl -w /opt -p wa -k ci_agent
run_install "$work/install-keep" --profile "$profile"
auditctl -l | grep -q 'ci_agent' || fail "the rule that was added at run time is gone"
grep -q 'put back: -w /opt -p wa -k ci_agent' "$work/install-keep" || fail "install didn't log the put-back"
[ "$(sha256sum </etc/audit/rules.d/40-ci-other.rules)" = "$other_sum" ] || fail "install changed the other file"
auditctl -l | grep -q 'ci_other' || fail "the other tool's rule is not loaded"
auditctl -l | grep -q 'akit_canary' || fail "the kit's rules are not loaded"
grep -q "40-ci-other.rules has a rule that didn't load" "$work/install-keep" \
  || fail "install didn't warn about the rule that can't load"
sh "$repo/scripts/verify.sh" >"$work/verify-keep" || fail "verify.sh exited $? next to the other file"
cat "$work/verify-keep"
grep -q 'check=other_rules result=warn detail=.*ci_gone (0 of 1)' "$work/verify-keep" \
  || fail "verify didn't warn about the other file's rule that isn't loaded"
# Delete one kit rule from the kernel. Verify must fail and name its key.
auditctl -W /etc/auditd-kit/canary -p wa -k akit_canary
if sh "$repo/scripts/verify.sh" >"$work/verify-missing"; then
  fail "verify passed with a kit rule missing"
fi
grep -q 'check=rules result=fail detail=.*akit_canary (0 of 1)' "$work/verify-missing" \
  || fail "verify didn't name the missing rule's key"
rm -f /etc/audit/rules.d/40-ci-other.rules
sh "$repo/scripts/rollback.sh" --original || fail "rollback.sh --original exited $?"
same_sums "$work/before" "the keep step left a changed file"

step "backup.sh and rollback.sh undo an edit on a host with no install"
backup_out=$(sh "$repo/scripts/backup.sh") || fail "backup.sh exited $?"
# A restore puts back the files that the backup holds, so the edit is to a file that exists.
set -- /etc/audit/rules.d/*.rules
[ -f "$1" ] || fail "no rules file to edit"
echo '-w /srv -p wa -k ci_edit' >>"$1"
sh "$repo/scripts/rollback.sh" "${backup_out#backup=}" || fail "rollback.sh exited $? after backup.sh"
same_sums "$work/before" "rollback did not undo the edit"

step "A full audit disk doesn't halt the host"
start=$(date +%s)
img=/var/tmp/auditd-kit-test.img
dd if=/dev/zero of="$img" bs=1M count=128 2>/dev/null
mkfs.ext4 -q -F -m 0 "$img"
# With SELinux on, auditd can only write to a filesystem that has the audit log label.
mount_opts=loop
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  mount_opts="loop,context=system_u:object_r:auditd_log_t:s0"
fi
mount -o "$mount_opts" "$img" /var/log/audit
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
