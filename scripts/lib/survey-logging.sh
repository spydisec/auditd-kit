# Logging, agent, and existing-rule checks for the survey. Source this file, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2154
#
# These follow the rules in survey-host.sh: one survey_check_<name> function per check, keys
# through akit_kv, a non-zero return when the host cannot be read, files read under AKIT_ROOT.
# survey.sh must set survey_root before it calls the checks, because two of them run the awk
# programs in lib/. A list with no entries is reported as "none".

# survey_join: read lines from stdin and print them joined by $1 (default a comma), or "none".
survey_join() {
  awk -v sep="${1:-,}" 'NF {printf "%s%s", (n++ ? sep : ""), $0} END {if (!n) printf "none"; print ""}'
}

survey_check_agents() {
  survey_ag=
  survey_procs=
  if survey_psout=$(ps -e -o comm= 2>/dev/null) && [ -n "$survey_psout" ]; then
    survey_procs=$survey_psout
  elif survey_psout=$(ps -e 2>/dev/null); then
    survey_procs=$(printf '%s\n' "$survey_psout" | awk 'NR > 1 {print $NF}')
  fi
  # Each line is: agent, a process name, then install paths.
  while read -r survey_name survey_proc survey_paths; do
    survey_hit=no
    for survey_p in $survey_paths; do
      if [ -e "$(akit_path "$survey_p")" ]; then
        survey_hit=yes
      fi
    done
    survey_proc=$(printf '%s\n' "$survey_proc" | tr ',' ' ')
    for survey_pn in $survey_proc; do
      if printf '%s\n' "$survey_procs" | grep -x -F "$survey_pn" >/dev/null 2>&1; then
        survey_hit=yes
      fi
    done
    if [ "$survey_hit" = yes ]; then
      survey_ag="${survey_ag:+$survey_ag,}$survey_name"
    fi
  done <<EOF
mde wdavdaemon /opt/microsoft/mdatp
crowdstrike falcon-sensor /opt/CrowdStrike
wazuh wazuh-agentd,ossec-agentd /var/ossec
auditbeat auditbeat /usr/share/auditbeat /etc/auditbeat
splunkuf splunkd /opt/splunkforwarder
osquery osqueryd /opt/osquery /etc/osquery
EOF
  akit_kv agents "${survey_ag:-none}"
}

survey_check_hardening() {
  survey_li=no
  survey_hf=
  survey_ar=$(akit_path /etc/audit/audit.rules)
  if [ -r "$survey_ar" ] && grep -v '^[[:space:]]*#' "$survey_ar" | grep -e '--loginuid-immutable' >/dev/null 2>&1; then
    survey_li=yes
  fi
  survey_list=$(akit_rulesd_files)
  for survey_n in $survey_list; do
    survey_body=$(akit_rulesd_body "$survey_n") || return 1
    if printf '%s\n' "$survey_body" | grep -e '--loginuid-immutable' >/dev/null 2>&1; then
      survey_li=yes
    fi
    akit_rulesd_is_ours "$survey_n" && continue
    survey_lname=$(printf '%s\n' "$survey_n" | tr '[:upper:]' '[:lower:]')
    survey_hit=no
    case "$survey_lname" in
      *cis* | *stig*) survey_hit=yes ;;
    esac
    if [ "$survey_hit" = no ] && grep -i -E '^[[:space:]]*#(.*[^a-z])?(cis|stig)([^a-z]|$)' "$(akit_path "$AKIT_RULES_D/$survey_n")" >/dev/null 2>&1; then
      survey_hit=yes
    fi
    if [ "$survey_hit" = yes ]; then
      survey_hf="${survey_hf:+$survey_hf,}$survey_n"
    fi
  done
  akit_kv hardening_loginuid_immutable "$survey_li"
  akit_kv hardening_rule_files "${survey_hf:-none}"
}

# akit_rulesd_sort in rulesd.sh sorts the files. A distro audit.rules with only control lines
# gets the :control suffix, and its lines are not reported. Every foreign file is listed with
# each of its control lines, because augenrules keeps the last -f and -b it reads, so a kept file
# can override ours.
survey_check_rules_d() {
  survey_df=
  survey_cl=
  survey_sorted=$(akit_rulesd_sort) || return 1
  while read -r survey_kind survey_n; do
    case "$survey_kind" in
      foreign) ;;
      control)
        survey_df="${survey_df:+$survey_df,}$survey_n:control"
        continue
        ;;
      *) continue ;;
    esac
    survey_df="${survey_df:+$survey_df,}$survey_n"
    survey_cl_new=$(akit_rulesd_control "$survey_n" | sed -n 2p)
    if [ -n "$survey_cl_new" ]; then
      survey_cl="${survey_cl:+$survey_cl,}$survey_cl_new"
    fi
  done <<EOF
$survey_sorted
EOF
  akit_kv rules_d_files "${survey_df:-none}"
  akit_kv rules_d_control_lines "${survey_cl:-none}"
}

survey_check_syslog_daemon() {
  survey_sd=none
  survey_sv=none
  if [ -e "$(akit_path /etc/rsyslog.conf)" ] || [ -e "$(akit_path /usr/sbin/rsyslogd)" ] || [ -e "$(akit_path /sbin/rsyslogd)" ]; then
    survey_sd=rsyslog
    survey_sv=$(rsyslogd -v 2>/dev/null | awk 'NR == 1 {print $2; exit}' | sed 's/,$//')
  elif [ -e "$(akit_path /etc/syslog-ng/syslog-ng.conf)" ] || [ -e "$(akit_path /usr/sbin/syslog-ng)" ] || [ -e "$(akit_path /sbin/syslog-ng)" ]; then
    survey_sd=syslog-ng
    survey_sv=$(syslog-ng --version 2>/dev/null | awk '/^Installer-Version:/ {print $2; found = 1; exit} NR == 1 {first = $2} END {if (!found) print first}')
  elif [ -d "$(akit_path /run/systemd/journal)" ] || [ -e "$(akit_path /usr/lib/systemd/systemd-journald)" ] || [ -e "$(akit_path /lib/systemd/systemd-journald)" ]; then
    survey_sd=journald
    survey_sv=$(journalctl --version 2>/dev/null | awk 'NR == 1 {print $2; exit}')
  fi
  if [ "$survey_sd" != none ] && [ -z "$survey_sv" ]; then
    survey_sv=unknown
  fi
  akit_kv syslog_daemon "$survey_sd"
  akit_kv syslog_version "$survey_sv"
}

survey_check_syslog_forwarding() {
  survey_rsmain=$(akit_path /etc/rsyslog.conf)
  survey_rsd=$(akit_path /etc/rsyslog.d)
  set --
  [ -f "$survey_rsmain" ] && set -- "$survey_rsmain"
  for survey_f in "$survey_rsd"/*.conf; do
    [ -f "$survey_f" ] && set -- "$@" "$survey_f"
  done
  survey_rsout=
  if [ $# -gt 0 ]; then
    survey_rsout=$(awk -f "$survey_root/lib/rsyslog.awk" "$@" 2>/dev/null) || return 1
  fi
  survey_tg=$(printf '%s\n' "$survey_rsout" | sed -n 's/^target //p' | survey_join)
  survey_fu=$(printf '%s\n' "$survey_rsout" | sed -n 's/^facility //p' | survey_join)
  survey_cl=$(printf '%s\n' "$survey_rsout" | sed -n 's/^catchall //p' | survey_join ' | ')
  survey_ca=no
  [ "$survey_cl" != none ] && survey_ca=yes
  # The survey can't see the forwards in a file it doesn't read, so another include fails closed.
  if printf '%s\n' "$survey_rsout" | grep -E '^(parse_error$|include )' >/dev/null 2>&1; then
    survey_ca=unknown
  fi
  akit_kv syslog_forward_targets "$survey_tg"
  akit_kv syslog_facilities_used "$survey_fu"
  akit_kv syslog_catchall "$survey_ca"
  akit_kv syslog_catchall_lines "$survey_cl"
}

survey_check_syslog_dropins() {
  survey_di=
  survey_rsd=$(akit_path /etc/rsyslog.d)
  if [ -d "$survey_rsd" ]; then
    for survey_f in "$survey_rsd"/*; do
      [ -f "$survey_f" ] || continue
      survey_di="${survey_di:+$survey_di,}${survey_f##*/}"
    done
  fi
  akit_kv syslog_dropins "${survey_di:-none}"
}

# On auditd 3.x the plugin needs the audisp-syslog binary, so a leftover config file does not
# count. On RHEL 7 the syslog plugin is built in, and its config names builtin_syslog.
survey_check_syslog_plugin_installed() {
  survey_pi=no
  for survey_p in /sbin/audisp-syslog /usr/sbin/audisp-syslog; do
    if [ -e "$(akit_path "$survey_p")" ]; then
      survey_pi=yes
    fi
  done
  survey_bi=$(akit_path /etc/audisp/plugins.d/syslog.conf)
  if [ -r "$survey_bi" ] && grep -E '^[[:space:]]*path[[:space:]]*=[[:space:]]*builtin_syslog' "$survey_bi" >/dev/null 2>&1; then
    survey_pi=yes
  fi
  akit_kv syslog_plugin_installed "$survey_pi"
}

# AKIT_NOW pins the current time (epoch seconds), so tests need no clock.
survey_check_audit_volume() {
  survey_vdir=$(akit_path /var/log/audit)
  survey_vtop=
  if [ -d "$survey_vdir" ]; then
    survey_now=${AKIT_NOW:-$(date +%s)}
    case "$survey_now" in
      '' | *[!0-9]*) return 1 ;;
    esac
    survey_vout=$(sh "$survey_root/stats.sh" --dir "$survey_vdir" --top 10 --since "$((survey_now - 86400))" 2>/dev/null) || return 1
    survey_vtop=$(printf '%s\n' "$survey_vout" | awk '$1 == "top_key" {printf "%s%s:%s", (n++ ? "," : ""), $2, $3}')
  fi
  akit_kv audit_volume_top_keys "${survey_vtop:-none}"
}
