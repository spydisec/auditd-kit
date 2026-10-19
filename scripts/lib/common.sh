# Shared helpers for every auditd-kit script. Source this file, don't run it.
# shellcheck shell=sh

LC_ALL=C
export LC_ALL

AKIT_ROOT=${AKIT_ROOT:-}

AKIT_EXIT_OK=0
AKIT_EXIT_REFUSED=1
AKIT_EXIT_FAILED=2
AKIT_EXIT_ROLLBACK_FAILED=3
export AKIT_EXIT_OK AKIT_EXIT_REFUSED AKIT_EXIT_FAILED AKIT_EXIT_ROLLBACK_FAILED

# akit_path <abs-path>: print the path under AKIT_ROOT.
akit_path() {
  printf '%s%s\n' "$AKIT_ROOT" "$1"
}

# akit_log <level> <message>: write to stderr, and to AKIT_LOG_FILE when it is set.
akit_log() {
  akit_log_line="auditd-kit: $1: $2"
  printf '%s\n' "$akit_log_line" >&2
  if [ -n "${AKIT_LOG_FILE:-}" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$akit_log_line" >>"$AKIT_LOG_FILE"
  fi
}

# akit_die <code> <message>: log the message as an error and exit with the code.
akit_die() {
  akit_log error "$2"
  exit "$1"
}
