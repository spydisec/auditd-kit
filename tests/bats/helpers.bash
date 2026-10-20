# Shared helpers for the bats tests. Load with: load helpers

# Make a temp directory under BATS_TEST_TMPDIR and export it as AKIT_ROOT.
akit_fixture_root() {
  AKIT_ROOT=$(mktemp -d "${BATS_TEST_TMPDIR}/root.XXXXXX")
  export AKIT_ROOT
}

# akit_stub <cmd> <script-body>
# Write an executable stub named <cmd> into a temp bin directory and put that
# directory first on PATH.
akit_stub() {
  if [ -z "${AKIT_STUB_BIN:-}" ]; then
    AKIT_STUB_BIN=$(mktemp -d "${BATS_TEST_TMPDIR}/bin.XXXXXX")
    export AKIT_STUB_BIN
    PATH="${AKIT_STUB_BIN}:${PATH}"
    export PATH
  fi
  printf '#!/bin/sh\n%s\n' "$2" >"${AKIT_STUB_BIN}/$1"
  chmod +x "${AKIT_STUB_BIN}/$1"
}

# akit_path_without <cmd>...: print a PATH dir that holds the stubs and the tools the survey and
# its libs call, minus the named commands, so a test can hide one real command. The list is fixed,
# so the dir takes about 30 symlinks, not one for every executable on PATH.
akit_path_without() {
  akit_hide=$(mktemp -d "${BATS_TEST_TMPDIR}/hide.XXXXXX")
  for akit_n in sh bash awk sed grep head tail tr cut sort uniq wc cat date dirname basename \
    id ps uname df find ls rm mktemp readlink timeout python3 python python2; do
    for akit_x in "$@"; do
      [ "$akit_n" = "$akit_x" ] && continue 2
    done
    akit_p=$(command -v "$akit_n" 2>/dev/null) || continue
    case "$akit_p" in /*) ln -s "$akit_p" "$akit_hide/$akit_n" ;; esac
  done
  if [ -n "${AKIT_STUB_BIN:-}" ]; then
    for akit_f in "$AKIT_STUB_BIN"/*; do
      akit_n=${akit_f##*/}
      for akit_x in "$@"; do
        [ "$akit_n" = "$akit_x" ] && continue 2
      done
      ln -sf "$akit_f" "$akit_hide/$akit_n"
    done
  fi
  echo "$akit_hide"
}

# akit_host_fixture: make a new AKIT_ROOT that holds a host with auditd installed but not yet set
# up by auditd-kit, and point render at the Ubuntu 24.04 syscall tables.
akit_host_fixture() {
  akit_fixture_root
  akit_fx="$BATS_TEST_DIRNAME/../fixtures"
  cp -R "$akit_fx/hosts/ubuntu2404/." "$AKIT_ROOT/"
  cp -R "$akit_fx/install/etc" "$AKIT_ROOT/"
  mkdir -p "$AKIT_ROOT/run" "$AKIT_ROOT/var/log/audit"
  AKIT_SYSCALLS_B64="$akit_fx/syscalls/ubuntu2404-b64.txt"
  AKIT_SYSCALLS_B32="$akit_fx/syscalls/ubuntu2404-b32.txt"
  AKIT_ARCH=x86_64
  export AKIT_SYSCALLS_B64 AKIT_SYSCALLS_B32 AKIT_ARCH
}

# akit_sums <dir>...: print the sorted sha256sum of every file under the dirs, relative to AKIT_ROOT.
akit_sums() {
  (cd "$AKIT_ROOT" && find "$@" -type f -exec sha256sum {} + 2>/dev/null | sort)
}
