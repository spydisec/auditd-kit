#!/usr/bin/env bats

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
preflight="$repo/scripts/lib/preflight.sh"

# survey <key=value>...: write a clean survey to $input, with the given keys replaced.
survey() {
  input="$BATS_TEST_TMPDIR/survey"
  printf '%s\n' 'uid=0' 'support_tier=supported' 'auditd_installed=yes' 'audit_enabled=1' \
    'audit_log_free_mb=5000' 'agents=none' 'rules_d_files=audit.rules:control' \
    'rules_d_control_lines=none' >"$input"
  for kv in "$@"; do
    sed -i "s/^${kv%%=*}=.*/$kv/" "$input"
  done
}

# refuses <expected output> <flags> <key=value>...: preflight must exit 1 with exactly that output.
refuses() {
  want=$1
  flags=$2
  shift 2
  survey "$@"
  # shellcheck disable=SC2086
  run sh "$preflight" $flags <"$input"
  [ "$status" -eq 1 ] || { echo "$want: status $status"; return 1; }
  [ "$output" = "$want" ] || { echo "$want: got $output"; return 1; }
}

passes() {
  flags=$1
  shift
  survey "$@"
  # shellcheck disable=SC2086
  run sh "$preflight" $flags <"$input"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "clean fixture passes" {
  passes ""
}

@test "each refusal prints its code and override" {
  refuses "refuse=not_root override=none" "" uid=1000
  refuses "refuse=unsupported_os override=none" "" support_tier=unsupported
  refuses "refuse=auditd_missing override=install auditd from your repos" "" auditd_installed=no
  refuses "refuse=immutable override=reboot without -e 2" "" audit_enabled=2
  refuses "refuse=low_disk override=free space or set a smaller size" "" audit_log_free_mb=unknown
  refuses "refuse=existing_rules override=akit_existing_rules=keep or replace" "" rules_d_files=50-cis.rules
  refuses "refuse=existing_rules_control override=akit_existing_rules=replace" "--existing-rules keep" \
    rules_d_files=50-cis.rules "rules_d_control_lines=50-cis.rules:-e 2"
  refuses "refuse=agent_conflict:mde override=akit_accept_agents
refuse=agent_conflict:wazuh override=akit_accept_agents" "" agents=mde,wazuh
}

@test "accepted agent does not refuse" {
  passes "--accept-agents mde" agents=mde
}

@test "control-only distro file does not count as existing rules" {
  passes "" rules_d_files=audit.rules:control
}

@test "foreign rules are fine once existing_rules is chosen" {
  passes "--existing-rules replace" rules_d_files=50-cis.rules "rules_d_control_lines=50-cis.rules:-e 2"
  passes "--existing-rules keep" rules_d_files=50-cis.rules
}

@test "low_disk uses 1.5x: 1199 MB refuses standard, 1200 MB passes" {
  refuses "refuse=low_disk override=free space or set a smaller size" "" audit_log_free_mb=1199
  passes "" audit_log_free_mb=1200
  passes "--size small" audit_log_free_mb=375
}

@test "a bad setting exits 1 before any check" {
  survey
  run sh "$preflight" --size huge <"$input"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid setting akit_size"* ]]
}
