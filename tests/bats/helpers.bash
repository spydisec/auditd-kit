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
