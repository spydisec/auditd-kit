# Render the rsyslog drop-in and set the auditd syslog plugin. Source this file after common.sh,
# settings.sh, and auditdconf.sh, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2154
#
# The drop-in /etc/rsyslog.d/40-auditd-kit.conf is the only rsyslog file auditd-kit writes.

AKIT_RSYSLOG_DROPIN=/etc/rsyslog.d/40-auditd-kit.conf

# akit_forward_render <template> <out>: write the drop-in for akit_forward (local or remote). Lines
# that start with #both: and with the mode are uncommented, lines for the other mode are dropped,
# and the placeholders take the settings.
akit_forward_render() {
  case "$akit_forward" in
    local) fwd_other=remote ;;
    remote) fwd_other=local ;;
    *) return 1 ;;
  esac
  sed -e "/^#$fwd_other: /d" -e 's/^#both: //' -e "s/^#$akit_forward: //" \
    -e "s|@AKIT_SYSLOG_FACILITY@|$akit_syslog_facility|g" \
    -e "s|@AKIT_REMOTE_HOST@|$akit_remote_host|g" \
    -e "s|@AKIT_REMOTE_PORT@|$akit_remote_port|g" \
    -e "s|@AKIT_REMOTE_PROTOCOL@|$akit_remote_protocol|g" "$1" >"$2"
}
