# Undo the forwarding that auditd-kit 0.2.0 and earlier could turn on (ADR 0026). Source this
# file after common.sh and auditdconf.sh, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2034
#
# Those versions wrote the drop-in below and set the auditd syslog plugin to active, and recorded
# forward=local or forward=remote in the state file. plan.sh moves the drop-in and lists the
# plugin change, and install.sh makes both changes after the backup.

AKIT_RSYSLOG_DROPIN=/etc/rsyslog.d/40-auditd-kit.conf

# akit_forward_plugin_file: print the host path of the syslog plugin file, which is under
# /etc/audit on auditd 3.x and under /etc/audisp on RHEL 7. Fail when neither exists.
akit_forward_plugin_file() {
  for fwd_p in /etc/audit/plugins.d/syslog.conf /etc/audisp/plugins.d/syslog.conf; do
    if [ -f "$(akit_path "$fwd_p")" ]; then
      echo "$fwd_p"
      return 0
    fi
  done
  return 1
}

# akit_forward_was_on: succeed when the state file shows that auditd-kit turned forwarding on. A
# plugin that a person or another agent turned on is left as it is.
akit_forward_was_on() {
  grep -Eq '^forward=(local|remote)$' "$(akit_path /etc/auditd-kit/state)" 2>/dev/null
}
