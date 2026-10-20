# The run lock, so that two auditd-kit runs never change a host at the same time.
# Source this file after common.sh, don't run it.
# shellcheck shell=sh
#
# The lock file holds the PID of the run that took it. It is created with "set -C", so only one
# run can create it. A lock whose PID is no longer running was left by a killed run, and is
# replaced. A lock held by a live PID makes the run exit 1.

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
