# Settings for every auditd-kit script. Source this file, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2034
#
# akit_settings_load [--config FILE] [--<setting> VALUE]... [ARG]...
# Precedence: defaults, then the config file, then flags. A flag drops the akit_ prefix and uses
# dashes, so akit_existing_rules is --existing-rules. A flag takes its value as the next
# argument or after an equals sign. The config file holds key=value lines, # comments and blank
# lines, and is parsed, never sourced. Arguments that are not flags are left in AKIT_ARGS.
# Any bad key, flag, or value exits 1 through akit_die. A caller can list its own value-less flags
# in AKIT_EXTRA_FLAGS (space separated). Those go to AKIT_ARGS as they are, and no value is read.

AKIT_SETTING_KEYS='akit_profile akit_size akit_max_log_file akit_num_logs akit_immutable
  akit_existing_rules akit_extra_rules_dir akit_accept akit_skip_keys'

akit_settings_defaults() {
  akit_profile=minimal
  akit_size=standard
  akit_max_log_file=
  akit_num_logs=
  akit_immutable=false
  akit_existing_rules="unset"
  akit_extra_rules_dir=
  akit_accept=
  akit_skip_keys=
}

# akit_settings_bad <key> <reason>
akit_settings_bad() {
  akit_die "$AKIT_EXIT_REFUSED" "invalid setting $1: $2"
}

# akit_settings_set <key> <value>: check the value, then assign it.
akit_settings_set() {
  set_key=$1
  set_val=$2
  # Settings that ADR 0024 and ADR 0026 removed fail with what replaced them.
  case "$set_key" in
    akit_forward | akit_syslog_facility | akit_remote_host | akit_remote_port | akit_remote_protocol | akit_accept_catchall)
      akit_settings_bad "$set_key" "removed, auditd-kit no longer sends audit events. Send audit.log with your own agent, see docs/integrations/send-audit-log.md"
      ;;
    akit_accept_agents) akit_settings_bad "$set_key" "removed, use akit_accept=agent_conflict:<agent>" ;;
  esac
  case " $(printf '%s' "$AKIT_SETTING_KEYS" | tr '\n' ' ' | tr -s ' ') " in
    *" $set_key "*) ;;
    *) akit_settings_bad "$set_key" "unknown setting" ;;
  esac
  case "$set_key" in
    akit_profile)
      case "$set_val" in
        minimal | medium | heavy) ;;
        standard) akit_settings_bad "$set_key" "'standard' was renamed, use heavy" ;;
        *) akit_settings_bad "$set_key" "'$set_val' is not minimal, medium, or heavy" ;;
      esac
      ;;
    akit_size)
      case "$set_val" in
        small | standard | large) ;;
        medium) akit_settings_bad "$set_key" "'medium' was renamed, use standard" ;;
        *) akit_settings_bad "$set_key" "'$set_val' is not small, standard, or large" ;;
      esac
      ;;
    akit_max_log_file | akit_num_logs)
      case "$set_val" in
        '' | 0* | *[!0-9]*) akit_settings_bad "$set_key" "'$set_val' is not a positive whole number" ;;
      esac
      ;;
    akit_immutable)
      case "$set_val" in
        true | false) ;;
        *) akit_settings_bad "$set_key" "'$set_val' is not true or false" ;;
      esac
      ;;
    akit_existing_rules)
      case "$set_val" in
        unset | keep | replace) ;;
        *) akit_settings_bad "$set_key" "'$set_val' is not unset, keep, or replace" ;;
      esac
      ;;
    akit_extra_rules_dir)
      case "$set_val" in
        *[!A-Za-z0-9/._@+-]*) akit_settings_bad "$set_key" "path has characters other than A-Z a-z 0-9 / . _ @ + -" ;;
      esac
      ;;
    akit_accept)
      # Only refusals that can't be fixed on the host can be accepted. preflight matches the list
      # as it is, so spaces and empty entries are refused.
      case "$set_val" in
        *[!a-z0-9_,:-]* | ,* | *, | *,,*) akit_settings_bad "$set_key" "'$set_val' is not a comma list of codes without spaces" ;;
      esac
      for set_code in $(printf '%s\n' "$set_val" | tr ',' ' '); do
        case "$set_code" in
          catchall_forward)
            akit_settings_bad "$set_key" "catchall_forward was removed, because auditd-kit no longer sends audit events. See docs/integrations/send-audit-log.md"
            ;;
          agent_conflict:*)
            case "${set_code#agent_conflict:}" in
              '' | *[!a-z0-9_-]*) akit_settings_bad "$set_key" "'$set_code' has no valid agent id" ;;
            esac
            ;;
          *) akit_settings_bad "$set_key" "'$set_code' is not agent_conflict:<agent>" ;;
        esac
      done
      ;;
    akit_skip_keys)
      case "$set_val" in
        *[!A-Za-z0-9_,]*) akit_settings_bad "$set_key" "'$set_val' is not a comma list of rule keys" ;;
      esac
      ;;
  esac
  eval "$set_key=\$set_val"
}

# akit_settings_read_config <file>
akit_settings_read_config() {
  [ -r "$1" ] || akit_die "$AKIT_EXIT_REFUSED" "cannot read config file $1"
  while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
    cfg_line=$(printf '%s\n' "$cfg_line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$cfg_line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) akit_settings_bad "$cfg_line" "expected key=value" ;;
    esac
    cfg_key=$(printf '%s\n' "${cfg_line%%=*}" | sed 's/[[:space:]]*$//')
    cfg_val=$(printf '%s\n' "${cfg_line#*=}" | sed 's/^[[:space:]]*//')
    akit_settings_set "$cfg_key" "$cfg_val"
  done <"$1"
}

akit_settings_load() {
  akit_settings_defaults
  # The config file goes first so that flags override it wherever they appear.
  load_cfg=
  for load_a in "$@"; do
    if [ "${load_prev:-}" = --config ]; then
      load_cfg=$load_a
    fi
    case "$load_a" in
      --config=*) load_cfg=${load_a#--config=} ;;
    esac
    load_prev=$load_a
  done
  unset load_prev
  [ -z "$load_cfg" ] || akit_settings_read_config "$load_cfg"

  AKIT_ARGS=
  while [ $# -gt 0 ]; do
    for load_x in ${AKIT_EXTRA_FLAGS:-}; do
      if [ "$1" = "$load_x" ]; then
        AKIT_ARGS="${AKIT_ARGS:+$AKIT_ARGS }$1"
        shift
        continue 2
      fi
    done
    case "$1" in
      --config)
        [ $# -ge 2 ] || akit_settings_bad --config "missing value"
        shift
        ;;
      --config=*) ;;
      --*=*) akit_settings_set "akit_$(printf '%s' "${1%%=*}" | sed 's/^--//' | tr - _)" "${1#*=}" ;;
      --*)
        load_key="akit_$(printf '%s' "${1#--}" | tr - _)"
        [ $# -ge 2 ] || akit_settings_bad "$1" "missing value"
        akit_settings_set "$load_key" "$2"
        shift
        ;;
      *) AKIT_ARGS="${AKIT_ARGS:+$AKIT_ARGS }$1" ;;
    esac
    shift
  done

  case "$akit_size" in
    small) load_max=50 load_num=5 akit_backlog=8192 ;;
    standard) load_max=100 load_num=8 akit_backlog=16384 ;;
    large) load_max=200 load_num=10 akit_backlog=32768 ;;
  esac
  [ -n "$akit_max_log_file" ] || akit_max_log_file=$load_max
  [ -n "$akit_num_logs" ] || akit_num_logs=$load_num
  akit_preset_total_mb=$((akit_max_log_file * akit_num_logs))
}
