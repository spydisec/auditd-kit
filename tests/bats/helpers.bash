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
