#!/bin/sh
# List what an install would change on this host. Change nothing.
#
# Usage: plan.sh <rendered-dir> [--config FILE] [setting flags]
#
# Compares the rules that render.sh wrote to the dir, and the auditd.conf keys from the settings,
# with the host. Prints one line per change, then a unified diff of each change when diff is
# installed. Prints nothing when the host already matches. Exits 0, or 1 on a bad argument.
#   add <path>         a new file
#   change <path>      a file whose content changes
#   move <path>        a rules.d file that install removes, after the backup has saved it
#   set <file> <key>   an auditd.conf key or a syslog plugin key whose value changes
# On a host where auditd-kit 0.2.0 or earlier turned forwarding on, the rsyslog drop-in is moved
# and the syslog plugin is set to inactive (ADR 0026).
# Only our own files and a distro audit.rules with only control lines are moved, plus every other
# rules.d file when akit_existing_rules is replace.
# shellcheck disable=SC2154
set -eu

lib=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$lib/common.sh"
# shellcheck source=/dev/null
. "$lib/settings.sh"
# shellcheck source=/dev/null
. "$lib/auditdconf.sh"
# shellcheck source=/dev/null
. "$lib/rulesd.sh"
# shellcheck source=/dev/null
. "$lib/forward.sh"
kit=$(cd "$lib/../.." && pwd)

akit_settings_load "$@"
rendered=$AKIT_ARGS
case "$rendered" in
  '' | *' '*) akit_die "$AKIT_EXIT_REFUSED" "usage: plan.sh <rendered-dir> [--config FILE] [setting flags]" ;;
esac
[ -d "$rendered" ] || akit_die "$AKIT_EXIT_REFUSED" "plan: rendered dir not found: $rendered"

tmp=$(mktemp -d) || akit_die "$AKIT_EXIT_REFUSED" "plan: cannot create a temp dir"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
: >"$tmp/lines"
: >"$tmp/diffs"

# plan_diff <host-path> <old-file> <new-file>: add a diff whose headers name the host path.
plan_diff() {
  command -v diff >/dev/null 2>&1 || return 0
  diff -u "$2" "$3" | awk -v p="$1" 'NR <= 2 && /^(---|\+\+\+) / { print substr($0, 1, 4) p; next } { print }' \
    >>"$tmp/diffs"
}

# plan_file <add|change|move> <host-path> <old-file> <new-file>
plan_file() {
  echo "$1 $2" >>"$tmp/lines"
  plan_diff "$2" "$3" "$4"
}

for plan_new in "$rendered"/*.rules; do
  [ -f "$plan_new" ] || continue
  plan_host="$AKIT_RULES_D/${plan_new##*/}"
  plan_cur=$(akit_path "$plan_host")
  if [ ! -e "$plan_cur" ]; then
    plan_file add "$plan_host" /dev/null "$plan_new"
  elif ! akit_same_file "$plan_cur" "$plan_new"; then
    plan_file change "$plan_host" "$plan_cur" "$plan_new"
  fi
done

plan_sorted=$(akit_rulesd_sort) || akit_die "$AKIT_EXIT_REFUSED" "plan: cannot read $(akit_path "$AKIT_RULES_D")"
while read -r plan_kind plan_name; do
  [ -n "$plan_kind" ] || continue
  [ ! -e "$rendered/$plan_name" ] || continue
  if [ "$plan_kind" = foreign ] && [ "$akit_existing_rules" != replace ]; then
    continue
  fi
  plan_file move "$AKIT_RULES_D/$plan_name" "$(akit_path "$AKIT_RULES_D/$plan_name")" /dev/null
done <<EOF
$plan_sorted
EOF

plan_conf=$(akit_path "$AKIT_AUDITD_CONF")
plan_old=/dev/null
if [ -f "$plan_conf" ]; then
  plan_old=$plan_conf
fi
cp "$plan_old" "$tmp/auditd.conf"
plan_wanted=$(akit_auditdconf_wanted "$kit") || akit_die "$AKIT_EXIT_REFUSED" "plan: cannot read the auditd.conf preset"
while read -r plan_key plan_value; do
  [ -n "$plan_key" ] || continue
  [ "$(akit_auditdconf_get "$plan_conf" "$plan_key")" != "$plan_value" ] || continue
  echo "set $AKIT_AUDITD_CONF $plan_key" >>"$tmp/lines"
  akit_auditdconf_set "$tmp/auditd.conf" "$plan_key" "$plan_value"
done <<EOF
$plan_wanted
EOF
if grep '^set ' "$tmp/lines" >/dev/null; then
  plan_diff "$AKIT_AUDITD_CONF" "$plan_old" "$tmp/auditd.conf"
fi

# The forwarding of an earlier version. Without the plugin file, only the drop-in is moved.
if akit_forward_was_on; then
  if plan_plug=$(akit_forward_plugin_file); then
    plan_cur=$(akit_path "$plan_plug")
    if [ "$(akit_auditdconf_get "$plan_cur" active)" != no ]; then
      cp "$plan_cur" "$tmp/plugin"
      akit_auditdconf_set "$tmp/plugin" active no
      echo "set $plan_plug active" >>"$tmp/lines"
      plan_diff "$plan_plug" "$plan_cur" "$tmp/plugin"
    fi
  fi
  plan_file move "$AKIT_RSYSLOG_DROPIN" "$(akit_path "$AKIT_RSYSLOG_DROPIN")" /dev/null
fi

if [ ! -e "$(akit_path /etc/auditd-kit/canary)" ]; then
  echo "add /etc/auditd-kit/canary" >>"$tmp/lines"
fi

cat "$tmp/lines" "$tmp/diffs"
