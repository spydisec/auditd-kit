# Logging, agent, and existing-rule checks for the survey. Source this file, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2154
#
# These follow the rules in survey-host.sh: one survey_check_<name> function per check, keys
# through akit_kv, a non-zero return when the host cannot be read, files read under AKIT_ROOT.
# survey.sh must set survey_root before it calls the checks, because audit_volume runs stats.sh.
# A list with no entries is reported as "none".

# survey_file_has <regex> <path>...: succeed when a line of a readable file matches the extended
# regex, or when a file exists and can't be read. Missing files are skipped, and lines that start
# with # or <!-- don't count.
survey_file_has() {
  survey_fh_re=$1
  shift
  for survey_fh in "$@"; do
    survey_fh=$(akit_path "$survey_fh")
    [ -e "$survey_fh" ] || continue
    [ -r "$survey_fh" ] || return 0
    grep -E -v '^[[:space:]]*(#|<!--)' "$survey_fh" 2>/dev/null | grep -E -q -e "$survey_fh_re" && return 0
  done
  return 1
}

# survey_agent_audit <agent>: succeed when the agent uses the audit system in a way that conflicts
# with auditd-kit (ADR 0023). Splunk UF and CrowdStrike don't.
survey_agent_audit() {
  case "$1" in
    wazuh)
      # Centralized settings from the Wazuh server land in shared/agent.conf.
      survey_file_has 'whodata[[:space:]]*=[[:space:]]*.yes' \
        /var/ossec/etc/ossec.conf /var/ossec/etc/shared/agent.conf
      ;;
    mde)
      [ -e "$(akit_path /etc/audit/rules.d/mdatp.rules)" ] && return 0
      command -v mdatp >/dev/null 2>&1 || return 1
      if command -v timeout >/dev/null 2>&1; then
        survey_mde=$(timeout 10 mdatp health --field supplementary_events_subsystem 2>/dev/null) || return 1
      else
        survey_mde=$(mdatp health --field supplementary_events_subsystem 2>/dev/null) || return 1
      fi
      case "$survey_mde" in *auditd*) return 0 ;; esac
      return 1
      ;;
    auditbeat)
      # Rules in the config or in audit.rules.d, or unicast, make Auditbeat own the audit socket.
      # shellcheck disable=SC2046
      survey_file_has '^[[:space:]]*socket_type:[[:space:]]*["'\'']?unicast|^[[:space:]]*-[aw][[:space:]]' \
        /etc/auditbeat/auditbeat.yml $(survey_glob /etc/auditbeat/modules.d '*.yml') \
        $(survey_glob /etc/auditbeat/audit.rules.d '*.conf')
      ;;
    osquery)
      survey_file_has 'disable_audit[^a-z_]*[=: ][[:space:]"]*false' \
        /etc/osquery/osquery.flags /etc/osquery/osquery.conf && return 0
      printf '%s\n' "$survey_args" | grep -E -q 'osqueryd.*disable_audit[= ]+false'
      ;;
    *) return 1 ;;
  esac
}

# survey_glob <dir> <pattern>: print the files in dir that match the pattern, without AKIT_ROOT.
survey_glob() {
  survey_gd=$(akit_path "$1")
  [ -d "$survey_gd" ] || return 0
  for survey_gf in "$survey_gd"/$2; do
    [ -e "$survey_gf" ] && printf '%s\n' "$1/${survey_gf##*/}"
  done
  return 0
}

survey_check_agents() {
  survey_ag=
  survey_aa=
  survey_args=$(ps -e -o args= 2>/dev/null) || survey_args=
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
      if survey_agent_audit "$survey_name"; then
        survey_aa="${survey_aa:+$survey_aa,}$survey_name"
      fi
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
  akit_kv agents_audit "${survey_aa:-none}"
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
