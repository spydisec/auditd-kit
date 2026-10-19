#!/bin/sh
# Report the state of this host and change nothing.
#
# Usage: survey.sh [--json] [--check azure]
# AKIT_AZURE_TIMEOUT sets the Azure probe time limit in seconds (default 5).
#
# The survey always exits 0. A check that fails reports its keys as "unknown" and is named in
# survey_errors. It does not use "set -e" or "set -u", because either one could stop the run.

survey_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$survey_root/lib/common.sh"
# shellcheck source=/dev/null
. "$survey_root/lib/output.sh"
# shellcheck source=/dev/null
. "$survey_root/lib/survey-host.sh"
# shellcheck source=/dev/null
. "$survey_root/lib/survey-logging.sh"
# shellcheck source=/dev/null
. "$survey_root/lib/survey-azure.sh"

# Tools such as auditctl and ss live in sbin, which a normal user may not have on PATH.
PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
export PATH

AKIT_SURVEY_VERSION=1
survey_errors=

survey_add_error() {
  survey_errors="${survey_errors:+$survey_errors,}$1"
}

# survey_check <name> <key>...: run survey_check_<name>. When it fails, drop what it added
# and report every key as unknown.
survey_check() {
  survey_cname=$1
  shift
  survey_saved=$AKIT_KV_BUF
  if "survey_check_$survey_cname"; then
    return 0
  fi
  AKIT_KV_BUF=$survey_saved
  for survey_key in "$@"; do
    akit_kv "$survey_key" unknown
  done
  survey_add_error "$survey_cname"
}

survey_format=text
survey_extra=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) survey_format=json ;;
    --check)
      if [ $# -ge 2 ]; then
        survey_extra="$survey_extra $2"
        shift
      else
        survey_add_error "option:--check"
      fi
      ;;
    *) survey_add_error "option:$1" ;;
  esac
  shift
done

akit_kv survey_version "$AKIT_SURVEY_VERSION"
survey_check uid uid
survey_check os os_id os_version
survey_check arch arch
survey_check kernel kernel
survey_check python python
survey_check support_tier support_tier
survey_check auditd_installed auditd_installed
survey_check auditd_version auditd_version
survey_check audit_rule_count audit_rule_count
survey_check audit_enabled audit_enabled
survey_check audit_failure audit_failure
survey_check boot_audit boot_audit
survey_check boot_audit_backlog_limit boot_audit_backlog_limit
survey_check audit_log_dir audit_log_dir_fs audit_log_dir_mount audit_log_free_mb audit_log_free_inodes
survey_check time_sync time_sync
survey_check mac mac
survey_check listening_ports listening_ports
survey_check interactive_users interactive_users
survey_check container_runtime container_runtime
survey_check akit_state_version akit_state_version
survey_check akit_state_profile akit_state_profile
survey_check agents agents
survey_check hardening hardening_loginuid_immutable hardening_rule_files
survey_check rules_d rules_d_files rules_d_control_lines
survey_check syslog_daemon syslog_daemon syslog_version
survey_check syslog_forwarding syslog_forward_targets syslog_facilities_used syslog_catchall syslog_catchall_lines
survey_check syslog_dropins syslog_dropins
survey_check syslog_plugin_installed syslog_plugin_installed
survey_check audit_volume audit_volume_top_keys

for survey_name in $survey_extra; do
  case "$survey_name" in
    azure) survey_check azure azure_ama azure_oms azure_proxy ;;
    *) survey_add_error "check:$survey_name" ;;
  esac
done

akit_kv survey_errors "$survey_errors"
akit_kv_flush "$survey_format"
exit 0
