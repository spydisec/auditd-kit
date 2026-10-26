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
  cp -R "$akit_fx/install/etc" "$akit_fx/install/usr" "$AKIT_ROOT/"
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

# akit_host_stubs: stub the host tools that install, rollback, and verify call. Each stub logs its
# arguments to $calls. Files in $stub_state change what they do:
#   uid, enabled, free   the value for id -u, the auditctl -s enabled field, and df free KB
#   lost                 the auditctl -s lost field, which grows by one on each call
#   augenrules_fails     augenrules runs this file as a script and exits 1
#   ausearch_fails       ausearch finds no event
# augenrules joins the rules.d files into audit.rules, and auditctl -l lists that file's rules.
akit_host_stubs() {
  calls="$BATS_TEST_TMPDIR/calls"
  stub_state="$BATS_TEST_TMPDIR/stub-state"
  mkdir -p "$stub_state"
  : >"$calls"
  export AKIT_VERIFY_POLL=0
  akit_s=$stub_state
  akit_c=$calls
  akit_stub id "[ \"\$1\" = -u ] || exec $(command -v id) \"\$@\"; cat $akit_s/uid 2>/dev/null || echo 0"
  akit_stub df "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo \"/dev/sda1 99000000 1 \$(cat $akit_s/free 2>/dev/null || echo 90000000) 1% /\""
  akit_stub auditctl "echo \"auditctl \$*\" >>$akit_c
case \"\$1\" in
  -v) echo 'auditctl version 3.1.2' ;;
  -s)
    echo \"enabled \$(cat $akit_s/enabled 2>/dev/null || echo 1)\"
    l=\$(cat $akit_s/lost 2>/dev/null || echo 0)
    echo \"lost \$l\"
    [ ! -e $akit_s/lost ] || echo \$((l + 1)) >$akit_s/lost
    ;;
  -l) grep -E '^-[aw] ' \"\$AKIT_ROOT/etc/audit/audit.rules\" || echo 'No rules' ;;
esac"
  akit_stub augenrules "echo \"augenrules \$*\" >>$akit_c
if [ -e $akit_s/augenrules_fails ]; then sh $akit_s/augenrules_fails; exit 1; fi
cp \"\$AKIT_ROOT/etc/audit/audit.rules\" \"\$AKIT_ROOT/etc/audit/audit.rules.prev\"
cat \"\$AKIT_ROOT\"/etc/audit/rules.d/*.rules >\"\$AKIT_ROOT/etc/audit/audit.rules\""
  akit_stub service "echo \"service \$*\" >>$akit_c"
  akit_stub systemctl "echo \"systemctl \$*\" >>$akit_c"
  akit_stub ausearch "echo \"ausearch \$*\" >>$akit_c; [ ! -e $akit_s/ausearch_fails ]"
}

# akit_called <text>: succeed when a stub from akit_host_stubs logged a call that holds the text.
akit_called() {
  grep -F -e "$1" "$calls" >/dev/null 2>&1
}
