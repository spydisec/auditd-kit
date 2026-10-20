#!/usr/bin/env bats
# The stub bodies and sh -c scripts expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
survey="$repo/scripts/survey.sh"
hosts="$repo/tests/fixtures/hosts"

# Copy a host fixture into a fresh AKIT_ROOT.
use_host() {
  akit_fixture_root
  cp -R "$hosts/$1/." "$AKIT_ROOT/"
}

# Stub every command the survey calls, so no test depends on the machine it runs on.
stub_defaults() {
  akit_stub id 'echo 1000'
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 2.8.5" ;;
  -l) printf -- "-w /etc/passwd -p wa -k identity\n-a always,exit -F arch=b64 -S execve -k exec\n" ;;
  -s) printf "enabled 1\nfailure 1\npid 812\nrate_limit 0\nbacklog_limit 8192\n" ;;
  esac'
  akit_stub df 'inodes=no
for a in "$@"; do
  case "$a" in -*i*) inodes=yes ;; esac
  path=$a
done
if [ "${LC_ALL:-}" = C ]; then
  if [ $inodes = yes ]; then echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
  else echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; fi
else
  echo "Dateisystem Blöcke Benutzt Verfügbar Verwendet% Eingehängt auf"
fi
case "$path" in
*/var/log/audit) fs=/dev/vg-audit mnt=/var/log/audit ;;
*) fs=/dev/vg-var mnt=/var ;;
esac
if [ "${LC_ALL:-}" != C ]; then echo "$fs 4,0G 2,0G 2,0G 50% $mnt"
elif [ $inodes = yes ]; then echo "$fs 1000000 500000 500000 50% $mnt"
else echo "$fs 4194304 2097152 2097152 50% $mnt"; fi'
  akit_stub ss 'printf "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 128 [::]:443 [::]:*\nLISTEN 0 128 127.0.0.1:22 0.0.0.0:*\n"'
  akit_stub getenforce 'echo Enforcing'
  akit_stub systemctl 'case "$2" in chronyd) echo active ;; *) echo inactive; exit 3 ;; esac'
  akit_stub python3 'echo "Python 3.9.18"'
}

setup() {
  stub_defaults
  unset LC_ALL
}

run_survey() {
  run sh "$survey" "$@"
}

@test "survey changes nothing" {
  use_host rocky8
  mkdir -p "$AKIT_ROOT/var/log/audit"
  before=$(cd "$AKIT_ROOT" && find . | sort && find . -type f -exec cksum {} + | sort)
  run_survey
  [ "$status" -eq 0 ]
  after=$(cd "$AKIT_ROOT" && find . | sort && find . -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
}

@test "survey exits 0 with key=value output on each supported fixture" {
  for pair in centos7:centos rocky8:rocky rocky9:rocky ubuntu2204:ubuntu ubuntu2404:ubuntu; do
    use_host "${pair%%:*}"
    run_survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"os_id=${pair##*:}"* ]]
    [[ "$output" == *"support_tier=supported"* ]]
    [[ "$output" == *"uid=1000"* ]]
    [[ "$output" == *"survey_errors="* ]]
  done
}

@test "survey reports the OS version and kernel" {
  use_host rocky9
  run_survey
  [[ "$output" == *"os_version=9.4"* ]]
  [[ "$output" == *"kernel=5.14.0-427.el9.x86_64"* ]]
}

@test "RHEL 5 and 6 and Debian report support_tier=unsupported and exit 0" {
  for pair in rhel5:rhel:5.11 rhel6:centos:6.10 debian12:debian:12; do
    use_host "${pair%%:*}"
    run_survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"os_id=$(echo "$pair" | cut -d: -f2)"* ]]
    [[ "$output" == *"os_version=$(echo "$pair" | cut -d: -f3)"* ]]
    [[ "$output" == *"support_tier=unsupported"* ]]
  done
}

@test "auditd_installed=no when auditctl is not on PATH" {
  empty=$(mktemp -d "$BATS_TEST_TMPDIR/empty.XXXXXX")
  PATH=$empty run /bin/sh -c '. "$1/common.sh"; . "$1/survey-host.sh"
    survey_check_auditd_installed; printf "%s|%s\n" "$survey_have_auditctl" "$AKIT_KV_BUF"' sh "$repo/scripts/lib"
  [ "$status" -eq 0 ]
  [[ "$output" == "no|auditd_installed=no"* ]]
}

@test "survey exits 0 and reports unknown auditd keys when auditctl is missing" {
  use_host rocky8
  rm "$AKIT_STUB_BIN/auditctl"
  if [ -x /sbin/auditctl ] || [ -x /usr/sbin/auditctl ]; then
    skip "the survey adds sbin to PATH and would find the real auditctl"
  fi
  PATH=$(akit_path_without auditctl) run sh "$survey"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auditd_installed=no"* ]]
  [[ "$output" == *"audit_rule_count=unknown"* ]]
  [[ "$output" == *"os_id=rocky"* ]]
  [[ "$output" == *"uid=1000"* ]]
}

@test "audit_enabled=2 when auditctl -s reports enabled 2" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 3.1.2" ;;
  -l) echo "No rules" ;;
  -s) printf "enabled 2\nfailure 1\n" ;;
  esac'
  run_survey
  [[ "$output" == *"audit_enabled=2"* ]]
  [[ "$output" == *"auditd_installed=yes"* ]]
  [[ "$output" == *"auditd_version=3.1.2"* ]]
  [[ "$output" == *"audit_rule_count=0"* ]]
}

@test "audit_failure comes from the failure line of auditctl -s" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 3.1.2" ;;
  -l) echo "No rules" ;;
  -s) printf "enabled 1\nfailure 2\npid 812\n" ;;
  esac'
  run_survey
  [[ "$output" == *"audit_enabled=1"$'\n'"audit_failure=2"$'\n'* ]]
  run_survey --json
  [[ "$output" == *'"audit_enabled":"1","audit_failure":"2",'* ]]
}

@test "audit_failure reads the old AUDIT_STATUS format" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 2.8.5" ;;
  -l) echo "No rules" ;;
  -s) echo "AUDIT_STATUS: enabled=1 flag=1 pid=1 rate_limit=0 backlog_limit=320" ;;
  esac'
  run_survey
  [[ "$output" == *"audit_failure=1"$'\n'* ]]
}

@test "audit_failure is unknown when it can't be read" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 3.1.2" ;;
  -l) echo "No rules" ;;
  -s) printf "enabled 1\npid 812\n" ;;
  esac'
  run_survey
  [[ "$output" == *"audit_failure=unknown"$'\n'* ]]
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 3.1.2" ;;
  *) exit 4 ;;
  esac'
  run_survey
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_failure=unknown"$'\n'* ]]
}

@test "survey counts loaded rules and reads the old auditctl -s format" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 2.8.5" ;;
  -l) printf "a\nb\nc\n" ;;
  -s) echo "AUDIT_STATUS: enabled=1 flag=1 pid=1 rate_limit=0 backlog_limit=320" ;;
  esac'
  run_survey
  [[ "$output" == *"audit_rule_count=3"* ]]
  [[ "$output" == *"audit_enabled=1"* ]]
}

@test "survey reports unknown and an error when auditctl -l fails" {
  use_host rocky8
  akit_stub auditctl 'case "$1" in
  -v) echo "auditctl version 2.8.5" ;;
  *) echo "You must be root to run this program." >&2; exit 4 ;;
  esac'
  run_survey
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_rule_count=unknown"* ]]
  [[ "$output" == *"audit_enabled=unknown"* ]]
  [[ "$output" == *"survey_errors=audit_rule_count,audit_enabled,audit_failure"* ]]
}

@test "survey parses df under LANG=de_DE.UTF-8" {
  use_host rocky8
  mkdir -p "$AKIT_ROOT/var/log/audit"
  LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 LANGUAGE=de run_survey
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_log_dir_fs=/dev/vg-audit"* ]]
  [[ "$output" == *"audit_log_dir_mount=/var/log/audit"* ]]
  [[ "$output" == *"audit_log_free_mb=2048"* ]]
  [[ "$output" == *"audit_log_free_inodes=500000"* ]]
}

@test "missing /var/log/audit reports the nearest existing parent" {
  use_host rocky8
  mkdir -p "$AKIT_ROOT/var/log"
  run_survey
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_log_dir_fs=/dev/vg-var"* ]]
  [[ "$output" == *"audit_log_dir_mount=/var"* ]]
}

@test "boot parameters are read from proc/cmdline" {
  use_host rocky8
  printf 'ro quiet audit=1 audit_backlog_limit=8192\n' >"$AKIT_ROOT/proc/cmdline"
  run_survey
  [[ "$output" == *"boot_audit=1"* ]]
  [[ "$output" == *"boot_audit_backlog_limit=8192"* ]]
}

@test "boot parameters are unset when proc/cmdline has none" {
  use_host rocky8
  run_survey
  [[ "$output" == *"boot_audit=unset"* ]]
  [[ "$output" == *"boot_audit_backlog_limit=unset"* ]]
}

@test "listening ports fall back from ss to netstat" {
  use_host rocky8
  rm "$AKIT_STUB_BIN/ss"
  akit_stub netstat 'printf "Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address Foreign Address State\ntcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN\ntcp 0 0 :::8080 :::* LISTEN\n"'
  PATH=$(akit_path_without ss) run sh "$survey"
  [[ "$output" == *"listening_ports=22,8080"* ]]
}

@test "listening ports come from ss, sorted and without duplicates" {
  use_host rocky8
  run_survey
  [[ "$output" == *"listening_ports=22,443"* ]]
}

@test "mac, time sync, python and interactive users" {
  use_host rocky8
  run_survey
  [[ "$output" == *"mac=selinux:enforcing"* ]]
  [[ "$output" == *"time_sync=chronyd"* ]]
  [[ "$output" == *"python=3.9.18"* ]]
  [[ "$output" == *"interactive_users=root,alice"* ]]
  [[ "$output" == *"container_runtime=none"* ]]
}

@test "apparmor is reported when selinux is absent" {
  use_host ubuntu2204
  rm "$AKIT_STUB_BIN/getenforce"
  mkdir -p "$AKIT_ROOT/sys/module/apparmor/parameters"
  echo Y >"$AKIT_ROOT/sys/module/apparmor/parameters/enabled"
  PATH=$(akit_path_without getenforce) run sh "$survey"
  [[ "$output" == *"mac=apparmor:enabled"* ]]
}

@test "container runtime is detected from marker files" {
  use_host rocky8
  : >"$AKIT_ROOT/.dockerenv"
  run_survey
  [[ "$output" == *"container_runtime=docker"* ]]
}

@test "state keys come from etc/auditd-kit/state" {
  use_host rocky8
  mkdir -p "$AKIT_ROOT/etc/auditd-kit"
  printf 'version=0.1.0\nprofile=standard\n' >"$AKIT_ROOT/etc/auditd-kit/state"
  run_survey
  [[ "$output" == *"akit_state_version=0.1.0"* ]]
  [[ "$output" == *"akit_state_profile=standard"* ]]
}

@test "state keys are empty when there is no state file" {
  use_host rocky8
  run_survey
  [[ "$output" == *"akit_state_version="$'\n'* ]]
  [[ "$output" == *"akit_state_profile="$'\n'* ]]
}

@test "--json prints one JSON object" {
  use_host rocky8
  run_survey --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -m json.tool >/dev/null
  [[ "$output" == '{"survey_version"'* ]]
}

@test "survey keeps going and exits 0 when a command fails" {
  use_host rocky8
  akit_stub df 'exit 1'
  run_survey
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_log_free_mb=unknown"* ]]
  [[ "$output" == *"os_id=rocky"* ]]
  [[ "$output" == *"survey_errors=audit_log_dir"* ]]
}

@test "survey exits 0 on an unknown option" {
  use_host rocky8
  run_survey --bogus
  [ "$status" -eq 0 ]
  [[ "$output" == *"os_id=rocky"* ]]
}

@test "listening ports parse ss output that has no State column" {
  use_host rocky8
  akit_stub ss 'printf "Recv-Q Send-Q Local Address:Port Peer Address:Port\n0 128 *:22 *:*\n0 128 :::8080 :::*\n"'
  run_survey
  [[ "$output" == *"listening_ports=22,8080"* ]]
}

@test "selinux disabled falls through to apparmor" {
  use_host ubuntu2204
  akit_stub getenforce 'echo Disabled'
  mkdir -p "$AKIT_ROOT/sys/module/apparmor/parameters"
  echo Y >"$AKIT_ROOT/sys/module/apparmor/parameters/enabled"
  run_survey
  [[ "$output" == *"mac=apparmor:enabled"* ]]
}

@test "selinux disabled is reported when there is no apparmor" {
  use_host rocky8
  akit_stub getenforce 'echo Disabled'
  run_survey
  [[ "$output" == *"mac=selinux:disabled"* ]]
}

@test "platform-python is used when no other python exists" {
  use_host rocky8
  rm "$AKIT_STUB_BIN/python3"
  mkdir -p "$AKIT_ROOT/usr/libexec"
  printf '#!/bin/sh\necho "Python 3.6.8"\n' >"$AKIT_ROOT/usr/libexec/platform-python"
  chmod +x "$AKIT_ROOT/usr/libexec/platform-python"
  PATH=$(akit_path_without python3 python python2) run sh "$survey"
  [[ "$output" == *"python=3.6.8"* ]]
}

@test "a failing df -Pi reports only the inode count as unknown" {
  use_host rocky8
  akit_stub df 'for a in "$@"; do case "$a" in -*i*) exit 1 ;; esac; done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vg-var 4194304 2097152 2097152 50% /var"'
  run_survey
  [[ "$output" == *"audit_log_dir_fs=/dev/vg-var"* ]]
  [[ "$output" == *"audit_log_free_mb=2048"* ]]
  [[ "$output" == *"audit_log_free_inodes=unknown"* ]]
  [[ "$output" == *"survey_errors=" ]]
}

@test "time_sync falls back to ps when systemctl is missing" {
  use_host rocky8
  rm "$AKIT_STUB_BIN/systemctl"
  akit_stub ps 'printf "init\nntpd\nbash\n"'
  PATH=$(akit_path_without systemctl) run sh "$survey"
  [[ "$output" == *"time_sync=ntpd"* ]]
}

@test "support_tier follows the OS and version" {
  check_tier() {
    use_host rocky9
    printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" >"$AKIT_ROOT/etc/os-release"
    run_survey
    [[ "$output" == *"support_tier=$3"* ]]
  }
  check_tier almalinux 9.4 supported
  check_tier ol 8.10 supported
  check_tier rhel 10.0 supported
  check_tier rocky 11.0 unsupported
  check_tier ubuntu 20.04 unsupported
  check_tier ubuntu 24.04 supported
}

@test "survey works with CDPATH exported" {
  use_host rocky8
  mkdir "$BATS_TEST_TMPDIR/scripts"
  cd "$repo"
  CDPATH=$BATS_TEST_TMPDIR run sh scripts/survey.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"os_id=rocky"* ]]
}
