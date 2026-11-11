#!/bin/sh
# Decide whether auditd-kit can work on this host. Change nothing.
#
# Usage: hostcheck.sh [--config FILE] [setting flags]
#
# Prints one line per finding and exits 1 when any line is a refusal, else 0:
#   <key>=<value>                  a fact about the host, which install shows in guided mode
#   warn=<code> detail=<text>      install goes ahead and logs the text
#   refuse=<code> detail=<text>    install stops, and the text says how to fix it
# A refusal means auditd-kit can't work here. A case that rollback can undo is never one
# (ADR 0029). To add a check, write an hc_check_<name> function and list it at the end.
#
# HOSTCHECK_NEED_TAR and HOSTCHECK_NEED_SERVICE are yes when the caller will use tar or service.
# HOSTCHECK_NEED_KERNEL is no when the caller won't load rules, as in a container, where the
# kernel audit system can't be used.
# shellcheck disable=SC2154
set -eu

hc_lib=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
for hc_l in common settings rulesd; do
  # shellcheck source=/dev/null
  . "$hc_lib/$hc_l.sh"
done

# auditctl and augenrules live in sbin, which a normal user may not have on PATH.
PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

# The systems that CI installs on, as <os-id>:<version>. A RHEL-family version is its major
# number. Keep this list in step with .github/workflows/integration.yml.
HOSTCHECK_TESTED='ubuntu:18.04 ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04
  centos:7 rocky:8 rocky:9 rocky:10'

hc_refused=no

hc_refuse() {
  hc_refused=yes
  echo "refuse=$1 detail=$2"
}

hc_warn() {
  echo "warn=$1 detail=$2"
}

# hc_file_has <regex> <path>...: succeed when a line of a readable file matches the extended
# regex, or when a file exists and can't be read. Missing files are skipped, and lines that start
# with # or <!-- don't count.
hc_file_has() {
  hc_re=$1
  shift
  for hc_f in "$@"; do
    hc_f=$(akit_path "$hc_f")
    [ -e "$hc_f" ] || continue
    [ -r "$hc_f" ] || return 0
    grep -E -v '^[[:space:]]*(#|<!--)' "$hc_f" 2>/dev/null | grep -E -q -e "$hc_re" && return 0
  done
  return 1
}

# hc_glob <dir> <pattern>: print the files in dir that match the pattern, without AKIT_ROOT.
hc_glob() {
  hc_gd=$(akit_path "$1")
  [ -d "$hc_gd" ] || return 0
  for hc_gf in "$hc_gd"/$2; do
    [ -e "$hc_gf" ] && printf '%s\n' "$1/${hc_gf##*/}"
  done
  return 0
}

hc_check_root() {
  hc_uid=$(id -u 2>/dev/null) || hc_uid=unknown
  [ "$hc_uid" = 0 ] || hc_refuse not_root "run as root"
}

# The OS name is read only for the warning. Nothing else depends on it.
hc_check_os() {
  hc_osr=$(akit_path /etc/os-release)
  hc_id=unknown
  hc_ver=unknown
  if [ -r "$hc_osr" ]; then
    hc_id=$(sed -n 's/^ID=//p' "$hc_osr" | head -n 1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
    hc_ver=$(sed -n 's/^VERSION_ID=//p' "$hc_osr" | head -n 1 | tr -d "\"'")
  fi
  echo "os_id=${hc_id:-unknown}"
  echo "os_version=${hc_ver:-unknown}"
  case "$hc_id" in ubuntu) hc_want="$hc_id:$hc_ver" ;; *) hc_want="$hc_id:${hc_ver%%.*}" ;; esac
  case " $(printf '%s' "$HOSTCHECK_TESTED" | tr '\n' ' ' | tr -s ' ') " in
    *" $hc_want "*) ;;
    *) hc_warn untested_os "auditd-kit isn't tested on ${hc_id:-unknown} ${hc_ver:-unknown}, so check the result with verify.sh" ;;
  esac
}

# auditd 2.8 is the oldest version that CI installs on.
hc_check_auditd() {
  hc_fix="install auditd from your repos (audit and audit-rules on RHEL 10)"
  hc_av=unknown
  hc_ae=unknown
  hc_have=yes
  for hc_c in auditctl augenrules; do
    if ! command -v "$hc_c" >/dev/null 2>&1; then
      hc_refuse auditd_missing "$hc_c is not installed, $hc_fix"
      hc_have=no
    fi
  done
  if [ "$hc_have" = yes ]; then
    hc_v=$(auditctl -v 2>/dev/null | head -n 1 | awk '{print $NF}')
    case "$hc_v" in
      [0-9]*.[0-9]*)
        hc_av=$hc_v
        hc_major=${hc_v%%.*}
        hc_minor=${hc_v#*.}
        hc_minor=${hc_minor%%[!0-9]*}
        if [ "$hc_major" -lt 2 ] || { [ "$hc_major" -eq 2 ] && [ "$hc_minor" -lt 8 ]; }; then
          hc_refuse auditd_missing "auditd $hc_v is older than 2.8"
        fi
        ;;
    esac
    # Only root can read the audit status, so a normal user gets not_root and nothing more.
    if [ "$hc_uid" = 0 ]; then
      if hc_s=$(auditctl -s 2>/dev/null); then
        hc_en=$(printf '%s\n' "$hc_s" | awk '{
          gsub(/=/, " ")
          for (i = 1; i < NF; i++) if ($i == "enabled") { print $(i + 1); exit }
        }')
        hc_ae=${hc_en:-unknown}
      elif [ "${HOSTCHECK_NEED_KERNEL:-yes}" = yes ]; then
        hc_refuse audit_off "auditctl -s failed, so boot the kernel with audit on (no audit=0)"
      fi
    fi
  fi
  echo "auditd_version=$hc_av"
  echo "audit_enabled=$hc_ae"
}

# The audit log filesystem needs 1.5 times the size preset. An unreadable value refuses.
hc_check_disk() {
  hc_dir=/var/log/audit
  while [ "$hc_dir" != / ] && [ ! -d "$(akit_path "$hc_dir")" ]; do
    hc_dir=$(dirname "$hc_dir")
  done
  hc_kb=$(df -Pk "$(akit_path "$hc_dir")" 2>/dev/null | awk 'NR == 2 {print $4}')
  case "$hc_kb" in
    '' | *[!0-9]*)
      echo "audit_log_free_mb=unknown"
      hc_refuse low_disk "cannot read the free space for $hc_dir"
      ;;
    *)
      hc_mb=$((hc_kb / 1024))
      echo "audit_log_free_mb=$hc_mb"
      if [ $((hc_mb * 2)) -lt $((akit_preset_total_mb * 3)) ]; then
        hc_refuse low_disk "$hc_mb MB free for $hc_dir, and the logs need $((akit_preset_total_mb * 3 / 2)) MB, so free space or set a smaller size"
      fi
      ;;
  esac
}

hc_check_tools() {
  if [ "${HOSTCHECK_NEED_TAR:-no}" = yes ] && ! command -v tar >/dev/null 2>&1; then
    hc_refuse tar_missing "install tar"
  fi
  if [ "${HOSTCHECK_NEED_SERVICE:-no}" = yes ] && ! command -v service >/dev/null 2>&1; then
    hc_refuse service_missing "install initscripts-service"
  fi
}

# An agent that takes the audit system for itself leaves auditd with no events, so no install can
# work. An agent that adds its own rules at run time only gets a warning.
hc_check_agents() {
  hc_agents=
  hc_args=$(ps -e -o args= 2>/dev/null) || hc_args=
  if hc_file_has 'disable_audit[^a-z_]*[=: ][[:space:]"]*false' \
    /etc/osquery/osquery.flags /etc/osquery/osquery.conf \
    || printf '%s\n' "$hc_args" | grep -E -q 'osqueryd.*disable_audit[= ]+false'; then
    hc_agents=osquery
    hc_refuse agent_needs_audit:osquery "osquery reads the audit events itself (disable_audit=false), so auditd gets none. Turn that off in osquery, or don't install auditd-kit here"
  fi
  # Rules in the config or in audit.rules.d, or unicast, make Auditbeat own the audit socket.
  # shellcheck disable=SC2046
  if hc_file_has '^[[:space:]]*socket_type:[[:space:]]*["'\'']?unicast|^[[:space:]]*-[aw][[:space:]]' \
    /etc/auditbeat/auditbeat.yml $(hc_glob /etc/auditbeat/modules.d '*.yml') \
    $(hc_glob /etc/auditbeat/audit.rules.d '*.conf'); then
    hc_agents="${hc_agents:+$hc_agents,}auditbeat"
    hc_refuse agent_needs_audit:auditbeat "Auditbeat loads its own audit rules or uses a unicast socket, so auditd gets no events. Remove audit_rules and unicast from Auditbeat, or don't install auditd-kit here"
  fi
  # Centralized settings from the Wazuh server land in shared/agent.conf.
  if hc_file_has 'whodata[[:space:]]*=[[:space:]]*.yes' \
    /var/ossec/etc/ossec.conf /var/ossec/etc/shared/agent.conf; then
    hc_agents="${hc_agents:+$hc_agents,}wazuh"
    hc_warn agent_restart:wazuh "Wazuh who-data adds audit rules when the agent starts. If its events stop after the install, restart wazuh-agent. auditd-kit doesn't restart it"
  fi
  echo "agents_audit=${hc_agents:-none}"
}

# Files in rules.d that auditd-kit didn't write are kept. augenrules uses the last -f and -b it
# reads, so a kept -f 2 would replace our -f 1 and panic the host when auditing fails (ADR 0006).
hc_check_rules() {
  hc_foreign=
  if hc_sorted=$(akit_rulesd_sort); then
    hc_foreign=$(printf '%s\n' "$hc_sorted" | sed -n 's/^foreign //p' | tr '\n' ',' | sed 's/,$//')
  else
    hc_foreign=unknown
  fi
  echo "rules_d_foreign=${hc_foreign:-none}"
  [ "$akit_existing_rules" = keep ] || return 0
  for hc_n in $(printf '%s\n' "$hc_foreign" | tr ',' ' '); do
    [ -r "$(akit_path "$AKIT_RULES_D/$hc_n")" ] || continue
    hc_found=$(awk -v want="$akit_backlog" '
      { sub(/^[ \t]+/, "") }
      /^-f[ \t]*2([ \t]|$)/ { print "panic " NR }
      /^-b[ \t]*[0-9]+/ {
        v = $0
        sub(/^-b[ \t]*/, "", v)
        if (v + 0 < want + 0) print "backlog " NR " " v + 0
      }
    ' "$(akit_path "$AKIT_RULES_D/$hc_n")")
    [ -n "$hc_found" ] || continue
    while read -r hc_kind hc_line hc_val; do
      case "$hc_kind" in
        panic) hc_refuse existing_rules_panic "$hc_n:$hc_line sets -f 2, which panics the host when auditing fails. Change it to -f 1, or set akit_existing_rules=replace" ;;
        backlog) hc_warn existing_rules_backlog "$hc_n:$hc_line sets the backlog to $hc_val, and the last -b wins by file name, so it can replace auditd-kit's $akit_backlog" ;;
      esac
    done <<HC_EOF
$hc_found
HC_EOF
  done
}

akit_settings_load "$@"

hc_check_root
hc_check_os
hc_check_auditd
hc_check_disk
hc_check_tools
hc_check_agents
hc_check_rules

[ "$hc_refused" = no ] || exit "$AKIT_EXIT_REFUSED"
