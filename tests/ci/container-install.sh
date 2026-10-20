#!/bin/sh
# Test the script path in a Docker container of one supported OS image.
#
# Usage: sh tests/ci/container-install.sh <image>
#
# Starts a container of the image with the repo mounted read-only at /kit, and runs this script
# again inside it with --inside. Inside, it installs auditd with the image's package manager,
# which is test setup and not part of auditd-kit. Then it runs install.sh --skip-load twice and
# expects changes=0 the second time, and runs rollback.sh --skip-load and expects
# checksum-identical /etc/audit and /etc/rsyslog.d. A container can't use the kernel audit
# system, so nothing is loaded or verified.
set -eu
LC_ALL=C
export LC_ALL

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

# setup: install auditd and the tools the test itself uses.
setup() {
  if [ -f /etc/centos-release ] && grep -q 'release 7' /etc/centos-release; then
    # CentOS 7 is end of life, and its packages are only on vault.centos.org.
    sed -i -e 's/^mirrorlist=/#mirrorlist=/' \
      -e 's|^#* *baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' \
      /etc/yum.repos.d/CentOS-*.repo
  fi
  if command -v apt-get >/dev/null 2>&1; then
    # Keep the package scripts from starting auditd, which can't run in a container.
    printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends auditd procps
  elif command -v dnf >/dev/null 2>&1; then
    # RHEL 10 ships auditctl and augenrules in audit-rules.
    extra=
    major=$(sed -n 's/^VERSION_ID="\{0,1\}\([0-9]*\).*/\1/p' /etc/os-release)
    [ "$major" -lt 10 ] || extra=audit-rules
    dnf install -y -q audit $extra tar gzip procps-ng findutils diffutils
  else
    yum install -y -q audit tar gzip procps-ng findutils diffutils
  fi
}

sums() {
  for d in /etc/audit /etc/rsyslog.d; do
    [ -d "$d" ] && find "$d" -type f -exec sha256sum {} +
  done | sort
}

# run_kit <out-file> <script> <flags>...: run a kit script, show its output, and fail on a
# non-zero exit.
run_kit() {
  out=$1
  script=$2
  shift 2
  rc=0
  sh "/kit/scripts/$script" "$@" >"$out" 2>&1 || rc=$?
  cat "$out"
  [ "$rc" -eq 0 ] || fail "$script $* exited $rc"
}

inside() {
  step "Test setup: install auditd"
  setup
  work=$(mktemp -d)
  sums >"$work/before"

  step "First install"
  run_kit "$work/install1" install.sh --skip-load --existing-rules replace
  grep -q 'disk_full_action = SUSPEND' /etc/audit/auditd.conf || fail "auditd.conf was not set"
  grep -q '^profile=minimal$' /etc/auditd-kit/state || fail "no state file"
  [ -f /etc/audit/rules.d/10-auditd-kit-minimal.rules ] || fail "no rules file"

  step "A second install has nothing to change"
  run_kit "$work/install2" install.sh --skip-load --existing-rules replace
  [ "$(tail -n 1 "$work/install2")" = changes=0 ] || fail "the second install changed something"

  step "Rollback gives back the files from before the install"
  run_kit "$work/rollback" rollback.sh --skip-load
  sums >"$work/after"
  if ! diff -u "$work/before" "$work/after"; then
    fail "rollback did not restore /etc/audit and /etc/rsyslog.d"
  fi

  step "All checks passed"
}

if [ "${1:-}" = --inside ]; then
  inside
  exit 0
fi
image=${1:-}
[ -n "$image" ] || fail "usage: container-install.sh <image>"
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)
docker run --rm -v "$repo:/kit:ro" "$image" sh /kit/tests/ci/container-install.sh --inside
