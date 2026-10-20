#!/bin/sh
# Decide whether auditd-kit may change this host. Change nothing.
#
# Usage: survey.sh | preflight.sh [setting flags]
# Reads the survey's key=value lines on stdin and the settings from the flags (see settings.sh).
# Prints one line per refusal, "refuse=<code> override=<text>", and exits 1 if there are any.
# To add a refusal, write a pf_check_<name> function that calls pf_refuse, and list it below.
# shellcheck disable=SC2154
set -eu

pf_root=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$pf_root/common.sh"
# shellcheck source=/dev/null
. "$pf_root/settings.sh"

pf_refusals=

# pf_refuse <code> <override-text>
pf_refuse() {
  pf_refusals="${pf_refusals}refuse=$1 override=$2
"
}

# pf_get <key>: print the survey value, or "unknown" when the key is absent.
pf_get() {
  pf_val=$(printf '%s\n' "$pf_survey" | sed -n "s/^$1=//p" | head -n 1)
  printf '%s\n' "${pf_val:-unknown}"
}

pf_check_host() {
  [ "$(pf_get uid)" = 0 ] || pf_refuse not_root none
  [ "$(pf_get support_tier)" != unsupported ] || pf_refuse unsupported_os none
  [ "$(pf_get auditd_installed)" != no ] || pf_refuse auditd_missing "install auditd from your repos"
  [ "$(pf_get audit_enabled)" != 2 ] || pf_refuse immutable "reboot without -e 2"
}

# The audit log filesystem needs 1.5 times the preset total. An unreadable value refuses.
pf_check_disk() {
  pf_free=$(pf_get audit_log_free_mb)
  case "$pf_free" in
    '' | *[!0-9]*) pf_refuse low_disk "free space or set a smaller size" ;;
    *)
      if [ $((pf_free * 2)) -lt $((akit_preset_total_mb * 3)) ]; then
        pf_refuse low_disk "free space or set a smaller size"
      fi
      ;;
  esac
}

pf_check_agents() {
  pf_agents=$(pf_get agents)
  case "$pf_agents" in none | unknown) return 0 ;; esac
  for pf_a in $(printf '%s\n' "$pf_agents" | tr ',' ' '); do
    case ",$akit_accept_agents," in
      *",$pf_a,"*) ;;
      *) pf_refuse "agent_conflict:$pf_a" akit_accept_agents ;;
    esac
  done
}

# rules_d_files lists foreign files. A name ending in :control is a distro file with only control
# lines, which install replaces. Anything else, or an unreadable list, needs an explicit choice.
pf_check_rules() {
  pf_files=$(pf_get rules_d_files)
  if [ "$akit_existing_rules" = unset ]; then
    pf_foreign=no
    case "$pf_files" in none) ;; *)
      for pf_f in $(printf '%s\n' "$pf_files" | tr ',' ' '); do
        case "$pf_f" in *:control) ;; *) pf_foreign=yes ;; esac
      done
      ;;
    esac
    [ "$pf_foreign" = no ] || pf_refuse existing_rules "akit_existing_rules=keep or replace"
  elif [ "$akit_existing_rules" = keep ] && [ "$(pf_get rules_d_control_lines)" != none ]; then
    pf_refuse existing_rules_control "akit_existing_rules=replace"
  fi
}

akit_settings_load "$@"
pf_survey=$(cat)

pf_check_host
pf_check_disk
pf_check_agents
pf_check_rules

if [ -n "$pf_refusals" ]; then
  printf '%s' "$pf_refusals"
  exit "$AKIT_EXIT_REFUSED"
fi
