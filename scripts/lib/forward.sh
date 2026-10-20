# Render the rsyslog drop-in, set the auditd syslog plugin, and read the forwards of the other
# rsyslog files. Source this file after common.sh, settings.sh, and auditdconf.sh, don't run it.
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

# akit_forward_plugin <plugin-file> <yes|no>: set active in the plugin file. With yes, also set
# args to the priority and the facility. The file is written only when it changes.
# akit_forward_plugin_want: print what the syslog plugin's active value should become: yes when
# forwarding is on, no when it's off and the state file shows that auditd-kit turned it on, and
# keep otherwise. keep leaves a plugin that a person or another agent set up as it is.
akit_forward_plugin_want() {
  if [ "$akit_forward" != none ]; then
    echo yes
  elif grep -Eq '^forward=(local|remote)$' "$(akit_path /etc/auditd-kit/state)" 2>/dev/null; then
    echo no
  else
    echo keep
  fi
}

akit_forward_plugin() {
  akit_auditdconf_set "$1" active "$2" || return 1
  [ "$2" = yes ] || return 0
  fwd_fac=$(printf '%s' "$akit_syslog_facility" | tr '[:lower:]' '[:upper:]')
  akit_auditdconf_set "$1" args "LOG_INFO LOG_$fwd_fac"
}

# akit_forward_check <file>: check the rsyslog configuration with rsyslogd -N1. When the check
# fails, log its output, remove the file (our drop-in), and fail.
akit_forward_check() {
  if fwd_out=$(rsyslogd -N1 -f "$(akit_path /etc/rsyslog.conf)" 2>&1); then
    return 0
  fi
  akit_log error "rsyslogd -N1 rejected the configuration, so $1 was removed"
  printf '%s\n' "$fwd_out" | while IFS= read -r fwd_line; do
    akit_log error "  $fwd_line"
  done
  rm -f "$1"
  return 1
}

# akit_forward_targets <lib-dir>: print the forward targets of rsyslog.conf and the drop-ins other
# than ours, as the survey does, joined by commas, or "none". The lib dir holds rsyslog.awk.
akit_forward_targets() {
  fwd_dir=$1
  set --
  [ ! -f "$(akit_path /etc/rsyslog.conf)" ] || set -- "$(akit_path /etc/rsyslog.conf)"
  for fwd_f in "$(akit_path /etc/rsyslog.d)"/*.conf; do
    [ -f "$fwd_f" ] || continue
    [ "$fwd_f" != "$(akit_path "$AKIT_RSYSLOG_DROPIN")" ] || continue
    set -- "$@" "$fwd_f"
  done
  [ $# -gt 0 ] || {
    echo none
    return 0
  }
  awk -f "$fwd_dir/rsyslog.awk" "$@" | sed -n 's/^target //p' | awk '
    NF { printf "%s%s", (n++ ? "," : ""), $0 }
    END { if (!n) printf "none"; print "" }'
}

# akit_forward_estimate <stats.sh>: print how much audit data the host writes on its busiest day.
akit_forward_estimate() {
  fwd_stats=$(sh "$1" --dir "$(akit_path /var/log/audit)" 2>/dev/null) || fwd_stats=
  printf '%s\n' "$fwd_stats" | awk '
    /^day=/ {
      split($2, b, "=")
      if (b[2] + 0 > m) m = b[2] + 0
      n++
    }
    END {
      if (n) printf "estimate: %.1f MB per day on the busiest of %d days in /var/log/audit\n", m / 1048576, n
      else print "estimate: no audit logs to measure yet"
    }'
}
