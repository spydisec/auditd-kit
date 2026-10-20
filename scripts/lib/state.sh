# Write the state file, /etc/auditd-kit/state. Source this file after common.sh and settings.sh,
# don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2154
#
# The state file is key=value lines. Each file=<sha256> <path> line names a file that auditd-kit
# wrote, so the survey counts it as ours and verify can check that it is unchanged. The canary is
# never listed, because verify writes to it.

AKIT_STATE_FILE=$(akit_path /etc/auditd-kit/state)

# akit_state_write <rule-count> <forward-targets> <abs-path>...: the forward targets are the
# survey's syslog_forward_targets from before this install. The paths are host paths.
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
