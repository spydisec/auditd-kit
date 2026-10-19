# Host checks for the survey. Source this file, don't run it.
# shellcheck shell=sh
#
# Each survey_check_<name> function reads the host, calls akit_kv for its keys, and returns 0.
# It returns non-zero when it cannot read the host. survey_check in survey.sh then reports the
# keys as unknown and adds the check name to survey_errors. Files are read under AKIT_ROOT.
# Commands are called by name, so tests can stub them.

survey_os_id=
survey_os_version=
survey_have_auditctl=no

# survey_osr_value <file> <key>: print the value of KEY= in an os-release file, without quotes.
survey_osr_value() {
  sed -n "s/^$2=//p" "$1" | head -n 1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]'
}

survey_check_uid() {
  survey_uid=$(id -u 2>/dev/null) || return 1
  [ -n "$survey_uid" ] || return 1
  akit_kv uid "$survey_uid"
}

survey_check_os() {
  survey_os_file=$(akit_path /etc/os-release)
  survey_rr_file=$(akit_path /etc/redhat-release)
  if [ -r "$survey_os_file" ]; then
    survey_os_id=$(survey_osr_value "$survey_os_file" ID)
    survey_os_version=$(survey_osr_value "$survey_os_file" VERSION_ID)
  elif [ -r "$survey_rr_file" ]; then
    survey_rr_line=$(head -n 1 "$survey_rr_file")
    case "$survey_rr_line" in
      *"Red Hat"*) survey_os_id=rhel ;;
      CentOS*) survey_os_id=centos ;;
      Rocky*) survey_os_id=rocky ;;
      AlmaLinux*) survey_os_id=almalinux ;;
      Oracle*) survey_os_id=ol ;;
      Fedora*) survey_os_id=fedora ;;
      *) survey_os_id=unknown ;;
    esac
    survey_os_version=$(printf '%s\n' "$survey_rr_line" | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p')
  else
    return 1
  fi
  akit_kv os_id "${survey_os_id:-unknown}"
  akit_kv os_version "${survey_os_version:-unknown}"
}

survey_check_arch() {
  survey_arch=$(uname -m 2>/dev/null) || return 1
  akit_kv arch "$survey_arch"
}

survey_check_kernel() {
  survey_kfile=$(akit_path /proc/sys/kernel/osrelease)
  if [ -r "$survey_kfile" ]; then
    survey_kernel=$(head -n 1 "$survey_kfile")
  else
    survey_kernel=$(uname -r 2>/dev/null) || return 1
  fi
  akit_kv kernel "$survey_kernel"
}

survey_check_python() {
  for survey_py in python3 python python2; do
    if command -v "$survey_py" >/dev/null 2>&1; then
      survey_pyver=$("$survey_py" --version 2>&1 | head -n 1 | sed 's/^Python //')
      akit_kv python "${survey_pyver:-unknown}"
      return 0
    fi
  done
  akit_kv python none
}

survey_check_support_tier() {
  survey_tier=unsupported
  survey_major=${survey_os_version%%.*}
  case "$survey_os_id" in
    rhel | centos | rocky | almalinux | ol)
      case "$survey_major" in
        7 | 8 | 9) survey_tier=supported ;;
      esac
      ;;
    ubuntu)
      case "$survey_os_version" in
        22.04 | 24.04) survey_tier=supported ;;
      esac
      ;;
  esac
  akit_kv support_tier "$survey_tier"
}

survey_check_auditd_installed() {
  if command -v auditctl >/dev/null 2>&1; then
    survey_have_auditctl=yes
  else
    survey_have_auditctl=no
  fi
  akit_kv auditd_installed "$survey_have_auditctl"
}

survey_check_auditd_version() {
  if [ "$survey_have_auditctl" != yes ]; then
    akit_kv auditd_version unknown
    return 0
  fi
  survey_out=$(auditctl -v 2>/dev/null) || return 1
  survey_ver=$(printf '%s\n' "$survey_out" | head -n 1 | awk '{print $NF}')
  [ -n "$survey_ver" ] || return 1
  akit_kv auditd_version "$survey_ver"
}

survey_check_audit_rule_count() {
  if [ "$survey_have_auditctl" != yes ]; then
    akit_kv audit_rule_count unknown
    return 0
  fi
  survey_out=$(auditctl -l 2>/dev/null) || return 1
  survey_count=$(printf '%s\n' "$survey_out" | awk '/^No rules/ {next} NF {n++} END {print n + 0}')
  akit_kv audit_rule_count "$survey_count"
}

survey_check_audit_enabled() {
  if [ "$survey_have_auditctl" != yes ]; then
    akit_kv audit_enabled unknown
    return 0
  fi
  survey_out=$(auditctl -s 2>/dev/null) || return 1
  survey_en=$(printf '%s\n' "$survey_out" | awk '{
    gsub(/=/, " ")
    for (i = 1; i < NF; i++) if ($i == "enabled") { print $(i + 1); exit }
  }')
  case "$survey_en" in
    0 | 1 | 2) akit_kv audit_enabled "$survey_en" ;;
    *) return 1 ;;
  esac
}

# survey_cmdline_value <name>: print the value of a kernel parameter, or "unset".
survey_cmdline_value() {
  survey_cmdline=$(akit_path /proc/cmdline)
  [ -r "$survey_cmdline" ] || return 1
  awk -v name="$1=" '{
    for (i = 1; i <= NF; i++) if (index($i, name) == 1) v = substr($i, length(name) + 1)
  } END { print (v == "" ? "unset" : v) }' "$survey_cmdline"
}

survey_check_boot_audit() {
  survey_val=$(survey_cmdline_value audit) || return 1
  akit_kv boot_audit "$survey_val"
}

survey_check_boot_audit_backlog_limit() {
  survey_val=$(survey_cmdline_value audit_backlog_limit) || return 1
  akit_kv boot_audit_backlog_limit "$survey_val"
}

# Report the filesystem of /var/log/audit, or of the nearest parent that exists.
survey_check_audit_log_dir() {
  survey_dir=/var/log/audit
  while [ "$survey_dir" != / ] && [ ! -d "$(akit_path "$survey_dir")" ]; do
    survey_dir=$(dirname "$survey_dir")
  done
  survey_target=$(akit_path "$survey_dir")
  survey_out=$(df -Pk "$survey_target" 2>/dev/null) || return 1
  survey_line=$(printf '%s\n' "$survey_out" | awk 'NR == 2')
  survey_fs=$(printf '%s\n' "$survey_line" | awk '{print $1}')
  survey_mount=$(printf '%s\n' "$survey_line" | awk '{m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print m}')
  survey_kb=$(printf '%s\n' "$survey_line" | awk '{print $4}')
  case "$survey_kb" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -n "$survey_fs" ] || return 1
  survey_iout=$(df -Pi "$survey_target" 2>/dev/null) || return 1
  survey_inodes=$(printf '%s\n' "$survey_iout" | awk 'NR == 2 {print $4}')
  case "$survey_inodes" in
    '' | *[!0-9]*) survey_inodes=unknown ;;
  esac
  akit_kv audit_log_dir_fs "$survey_fs"
  akit_kv audit_log_dir_mount "$survey_mount"
  akit_kv audit_log_free_mb "$((survey_kb / 1024))"
  akit_kv audit_log_free_inodes "$survey_inodes"
}

survey_check_time_sync() {
  survey_sync=none
  if command -v systemctl >/dev/null 2>&1; then
    for survey_unit in chronyd chrony ntpd ntp systemd-timesyncd; do
      if systemctl is-active "$survey_unit" >/dev/null 2>&1; then
        case "$survey_unit" in
          chronyd | chrony) survey_sync=chronyd ;;
          ntpd | ntp) survey_sync=ntpd ;;
          *) survey_sync=timesyncd ;;
        esac
        break
      fi
    done
  else
    survey_procs=$(ps -e -o comm= 2>/dev/null) || return 1
    for survey_unit in chronyd ntpd; do
      if printf '%s\n' "$survey_procs" | grep -x "$survey_unit" >/dev/null 2>&1; then
        survey_sync=$survey_unit
        break
      fi
    done
  fi
  akit_kv time_sync "$survey_sync"
}

survey_check_mac() {
  survey_mac=none
  survey_aa=$(akit_path /sys/module/apparmor/parameters/enabled)
  survey_se=$(akit_path /sys/fs/selinux/enforce)
  if command -v getenforce >/dev/null 2>&1; then
    survey_mode=$(getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
    [ -n "$survey_mode" ] || return 1
    survey_mac="selinux:$survey_mode"
  elif [ -r "$survey_se" ]; then
    case "$(head -n 1 "$survey_se")" in
      1) survey_mac=selinux:enforcing ;;
      *) survey_mac=selinux:permissive ;;
    esac
  elif [ -r "$survey_aa" ]; then
    case "$(head -n 1 "$survey_aa")" in
      Y*) survey_mac=apparmor:enabled ;;
      *) survey_mac=apparmor:disabled ;;
    esac
  fi
  akit_kv mac "$survey_mac"
}

survey_check_listening_ports() {
  if command -v ss >/dev/null 2>&1; then
    survey_raw=$(ss -ltn 2>/dev/null) || return 1
    survey_raw=$(printf '%s\n' "$survey_raw" | awk 'NR > 1 {print $4}')
  elif command -v netstat >/dev/null 2>&1; then
    survey_raw=$(netstat -ltn 2>/dev/null) || return 1
    survey_raw=$(printf '%s\n' "$survey_raw" | awk '$1 ~ /^tcp/ {print $4}')
  else
    return 1
  fi
  survey_ports=$(printf '%s\n' "$survey_raw" \
    | awk '{p = $0; sub(/.*:/, "", p); if (p ~ /^[0-9]+$/) print p}' \
    | sort -n -u \
    | awk 'NR > 1 {printf ","} {printf "%s", $0} END {print ""}')
  akit_kv listening_ports "${survey_ports:-none}"
}

survey_check_interactive_users() {
  survey_passwd=$(akit_path /etc/passwd)
  [ -r "$survey_passwd" ] || return 1
  survey_users=$(awk -F: '
    ($3 == 0 || ($3 >= 500 && $3 < 65534)) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {
      printf "%s%s", (n++ ? "," : ""), $1
    }
    END { print "" }' "$survey_passwd")
  akit_kv interactive_users "${survey_users:-none}"
}

survey_check_container_runtime() {
  survey_rt=none
  survey_cg=$(akit_path /proc/1/cgroup)
  survey_ct=$(akit_path /run/systemd/container)
  if [ -e "$(akit_path /.dockerenv)" ]; then
    survey_rt=docker
  elif [ -e "$(akit_path /run/.containerenv)" ]; then
    survey_rt=podman
  elif [ -r "$survey_ct" ]; then
    survey_rt=$(head -n 1 "$survey_ct")
  elif [ -r "$survey_cg" ]; then
    for survey_name in docker lxc kubepods containerd; do
      if grep "$survey_name" "$survey_cg" >/dev/null 2>&1; then
        survey_rt=$survey_name
        break
      fi
    done
  fi
  akit_kv container_runtime "$survey_rt"
}

# survey_state_value <key>: print the value from the deployed state file, or nothing.
survey_state_value() {
  survey_sfile=$(akit_path /etc/auditd-kit/state)
  [ -r "$survey_sfile" ] || return 0
  sed -n "s/^$1=//p" "$survey_sfile" | head -n 1
}

survey_check_akit_state_version() {
  akit_kv akit_state_version "$(survey_state_value version)"
}

survey_check_akit_state_profile() {
  akit_kv akit_state_profile "$(survey_state_value profile)"
}
