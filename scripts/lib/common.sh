# Shared helpers for every auditd-kit script. Source this file, don't run it.
# shellcheck shell=sh

LC_ALL=C
export LC_ALL

AKIT_ROOT=${AKIT_ROOT:-}

# The kit version that install writes to the state file. The repo stays at 0.0.0, and
# scripts/dev/build-release.sh writes the release version into the bundle.
# shellcheck disable=SC2034
AKIT_VERSION=0.0.0

AKIT_EXIT_OK=0
AKIT_EXIT_REFUSED=1
AKIT_EXIT_FAILED=2
AKIT_EXIT_ROLLBACK_FAILED=3
export AKIT_EXIT_OK AKIT_EXIT_REFUSED AKIT_EXIT_FAILED AKIT_EXIT_ROLLBACK_FAILED

# The auditctl options that set the audit system itself instead of adding a rule. A line that
# starts with one of them is a control line. Only rules/00-base.rules sets them. Exported so
# that awk programs can read the list from ENVIRON.
AKIT_CONTROL_FLAGS='-D -b -f -e -r -i --backlog_wait_time --loginuid-immutable'
export AKIT_CONTROL_FLAGS

# akit_path <abs-path>: print the path under AKIT_ROOT.
akit_path() {
  printf '%s%s\n' "$AKIT_ROOT" "$1"
}

# akit_same_file <a> <b>: succeed when both files exist and have the same content.
akit_same_file() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  [ "$(sha256sum <"$1")" = "$(sha256sum <"$2")" ]
}

# akit_log <level> <message>: write to stderr, and to AKIT_LOG_FILE when it is set.
akit_log() {
  akit_log_line="auditd-kit: $1: $2"
  # Logging must never fail, because an exit trap that logs must go on to restore the backup.
  printf '%s\n' "$akit_log_line" >&2 || true
  if [ -n "${AKIT_LOG_FILE:-}" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$akit_log_line" >>"$AKIT_LOG_FILE" 2>/dev/null || true
  fi
}

# akit_die <code> <message>: log the message as an error and exit with the code.
akit_die() {
  akit_log error "$2"
  exit "$1"
}

# Output: collect key=value pairs and print them as text or JSON.

# Pairs are kept as "key=value" records ended by the ASCII record separator (octal 036),
# so a value can hold newlines until the flush.
AKIT_KV_BUF=
AKIT_KV_RS=$(printf '\036')

# akit_kv <key> <value>: add a pair.
akit_kv() {
  akit_kv_val=$2
  while :; do
    case "$akit_kv_val" in
      *"$AKIT_KV_RS"*) akit_kv_val="${akit_kv_val%%"$AKIT_KV_RS"*}${akit_kv_val#*"$AKIT_KV_RS"}" ;;
      *) break ;;
    esac
  done
  AKIT_KV_BUF="${AKIT_KV_BUF}$1=${akit_kv_val}${AKIT_KV_RS}"
}

# akit_kv_flush <text|json>: print the collected pairs, then forget them.
akit_kv_flush() {
  printf '%s' "$AKIT_KV_BUF" | LC_ALL=C awk -v mode="$1" '
    BEGIN {
      RS = "\036"
      for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      for (i = 128; i < 256; i++) ctl[sprintf("%c", i)] = "?"
      ctl["\t"] = "\\t"
      ctl["\n"] = "\\n"
      ctl["\r"] = "\\r"
      ctl["\b"] = "\\b"
      ctl["\f"] = "\\f"
      n = 0
    }
    {
      eq = index($0, "=")
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      if (mode == "json") {
        out = ""
        len = length(val)
        for (i = 1; i <= len; i++) {
          c = substr(val, i, 1)
          if (c == "\\") c = "\\\\"
          else if (c == "\"") c = "\\\""
          else if (c in ctl) c = ctl[c]
          out = out c
        }
        items[++n] = "\"" key "\":\"" out "\""
      } else {
        gsub(/\n/, " ", val)
        print key "=" val
      }
    }
    END {
      if (mode == "json") {
        s = "{"
        for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") items[i]
        print s "}"
      }
    }'
  AKIT_KV_BUF=
}

# Run lock: two auditd-kit runs never change a host at the same time. The lock file holds the
# PID of the run that took it. It is created with "set -C", so only one run can create it. A lock
# whose PID is no longer running was left by a killed run, and is replaced. A lock held by a live
# PID makes the run exit 1.

AKIT_LOCK_FILE=$(akit_path /run/auditd-kit.lock)

# akit_lock_alive <pid>: succeed when the PID is a running process. kill -0 fails for a process
# of another user, so /proc is checked too.
akit_lock_alive() {
  case "$1" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null || [ -d "/proc/$1" ]
}

# akit_lock_create: create the lock file with this PID, and fail if it already exists.
akit_lock_create() {
  (
    set -C
    printf '%s\n' "$$" >"$AKIT_LOCK_FILE"
  ) 2>/dev/null
}

akit_lock_take() {
  akit_lock_create && return 0
  [ -f "$AKIT_LOCK_FILE" ] || akit_die "$AKIT_EXIT_REFUSED" "cannot create the lock $AKIT_LOCK_FILE"
  lock_pid=$(head -n 1 "$AKIT_LOCK_FILE" 2>/dev/null) || lock_pid=
  if akit_lock_alive "$lock_pid"; then
    akit_die "$AKIT_EXIT_REFUSED" "another auditd-kit run holds the lock (pid $lock_pid)"
  fi
  akit_log warning "replacing a stale lock left by pid ${lock_pid:-unknown}"
  rm -f "$AKIT_LOCK_FILE"
  akit_lock_create || akit_die "$AKIT_EXIT_REFUSED" "another auditd-kit run took the lock"
}

# akit_lock_release: remove the lock, but only when this run holds it.
akit_lock_release() {
  if [ "$(head -n 1 "$AKIT_LOCK_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$AKIT_LOCK_FILE"
  fi
}

# State file: /etc/auditd-kit/state, as key=value lines. akit_state_write needs settings.sh.
# Each file=<sha256> <path> line names a file that auditd-kit wrote, so the survey counts it as
# ours and verify can check that it is unchanged. The canary is never listed, because verify
# writes to it.

AKIT_STATE_FILE=$(akit_path /etc/auditd-kit/state)

# akit_state_write <rule-count> <forward-targets> <abs-path>...: the forward targets are the
# survey's syslog_forward_targets from before this install. The paths are host paths.
# shellcheck disable=SC2154
akit_state_write() {
  state_tmp="$AKIT_STATE_FILE.tmp"
  state_count=$1
  state_targets=$2
  shift 2
  (
    echo "version=$AKIT_VERSION"
    echo "profile=$akit_profile"
    echo "size=$akit_size"
    echo "forward=$akit_forward"
    echo "installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "rule_count=$state_count"
    echo "syslog_forward_targets=$state_targets"
    for state_p in "$@"; do
      state_sum=$(sha256sum <"$(akit_path "$state_p")") || exit 1
      echo "file=${state_sum%% *} $state_p"
    done
  ) >"$state_tmp" && chmod 0644 "$state_tmp" && mv -f "$state_tmp" "$AKIT_STATE_FILE" && return 0
  rm -f "$state_tmp"
  return 1
}
