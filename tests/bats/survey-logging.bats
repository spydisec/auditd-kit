#!/usr/bin/env bats
# The stub bodies expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
survey="$repo/scripts/survey.sh"
hosts="$repo/tests/fixtures/hosts"
logs="$repo/tests/fixtures/audit-logs"

use_host() {
  akit_fixture_root
  cp -R "$hosts/$1/." "$AKIT_ROOT/"
}

# put <abs-path> <text>: write a file under AKIT_ROOT.
put() {
  mkdir -p "$(dirname "$AKIT_ROOT$1")"
  printf '%s\n' "$2" >"$AKIT_ROOT$1"
}

# key <name>: print the value of a key from the survey output.
key() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

run_survey() {
  run sh "$survey" "$@"
}

setup() {
  akit_stub id 'echo 1000'
  akit_stub ps 'printf "systemd\nbash\n"'
  unset LC_ALL AKIT_NOW
  use_host rocky8
}

@test "each agent is detected from its fixture path" {
  for pair in mde:/opt/microsoft/mdatp crowdstrike:/opt/CrowdStrike wazuh:/var/ossec \
    auditbeat:/usr/share/auditbeat auditbeat:/etc/auditbeat splunkuf:/opt/splunkforwarder \
    osquery:/opt/osquery osquery:/etc/osquery; do
    use_host rocky8
    mkdir -p "$AKIT_ROOT${pair#*:}"
    run_survey
    [ "$(key agents)" = "${pair%%:*}" ]
    [ "$(key agents_audit)" = none ]
  done
}

@test "Wazuh uses audit only with who-data on" {
  put /var/ossec/etc/ossec.conf '<directories realtime="yes">/etc</directories>'
  run_survey
  [ "$(key agents)" = wazuh ]
  [ "$(key agents_audit)" = none ]
  put /var/ossec/etc/ossec.conf '<!-- <directories whodata="yes">/etc</directories> -->'
  run_survey
  [ "$(key agents_audit)" = none ]
  put /var/ossec/etc/ossec.conf '<directories check_all="yes" whodata = "yes">/etc</directories>'
  run_survey
  [ "$(key agents_audit)" = wazuh ]
  put /var/ossec/etc/ossec.conf '<directories realtime="yes">/etc</directories>'
  put /var/ossec/etc/shared/agent.conf '<directories whodata="yes">/etc</directories>'
  run_survey
  [ "$(key agents_audit)" = wazuh ]
}

@test "MDE uses audit only with mdatp.rules or the auditd event provider" {
  mkdir -p "$AKIT_ROOT/opt/microsoft/mdatp"
  akit_stub mdatp 'echo "\"ebpf\""'
  run_survey
  [ "$(key agents)" = mde ]
  [ "$(key agents_audit)" = none ]
  akit_stub mdatp 'echo "\"auditd\""'
  run_survey
  [ "$(key agents_audit)" = mde ]
  akit_stub mdatp 'exit 1'
  put /etc/audit/rules.d/mdatp.rules '-w /etc/passwd -p wa -k mdatp'
  run_survey
  [ "$(key agents_audit)" = mde ]
}

@test "Auditbeat uses audit only with rules or unicast" {
  put /etc/auditbeat/auditbeat.yml '- module: auditd
  audit_rules: |
    ## Define audit rules here.
    #-w /etc/passwd -p wa -k identity'
  run_survey
  [ "$(key agents)" = auditbeat ]
  [ "$(key agents_audit)" = none ]
  put /etc/auditbeat/audit.rules.d/sample.conf '-a always,exit -F arch=b64 -S execve -k exec'
  run_survey
  [ "$(key agents_audit)" = auditbeat ]
  rm "$AKIT_ROOT/etc/auditbeat/audit.rules.d/sample.conf"
  put /etc/auditbeat/auditbeat.yml '- module: auditd
  socket_type: "unicast"'
  run_survey
  [ "$(key agents_audit)" = auditbeat ]
}

@test "osquery uses audit only with disable_audit=false" {
  put /etc/osquery/osquery.flags '--disable_audit=true'
  run_survey
  [ "$(key agents)" = osquery ]
  [ "$(key agents_audit)" = none ]
  put /etc/osquery/osquery.flags '# --disable_audit=false'
  run_survey
  [ "$(key agents_audit)" = none ]
  put /etc/osquery/osquery.flags '--disable_audit false'
  run_survey
  [ "$(key agents_audit)" = osquery ]
  rm "$AKIT_ROOT/etc/osquery/osquery.flags"
  put /etc/osquery/osquery.conf '{"options": {"disable_audit": "false"}}'
  run_survey
  [ "$(key agents_audit)" = osquery ]
  rm "$AKIT_ROOT/etc/osquery/osquery.conf"
  akit_stub ps 'case "$*" in
*args=*) echo "/opt/osquery/bin/osqueryd --disable_audit=false" ;;
*) echo osqueryd ;;
esac'
  run_survey
  [ "$(key agents_audit)" = osquery ]
}

@test "CrowdStrike and Splunk UF never use audit" {
  mkdir -p "$AKIT_ROOT/opt/CrowdStrike" "$AKIT_ROOT/opt/splunkforwarder"
  run_survey
  [ "$(key agents)" = crowdstrike,splunkuf ]
  [ "$(key agents_audit)" = none ]
}

@test "agents are detected from running process names and listed in a fixed order" {
  mkdir -p "$AKIT_ROOT/opt/CrowdStrike"
  akit_stub ps 'printf "bash\nauditbeat\nosqueryd\nwazuh-agentd\nauditbeat-x\n"'
  run_survey
  [ "$(key agents)" = "crowdstrike,wazuh,auditbeat,osquery" ]
}

@test "agents fall back to ps -e and report none when nothing is found" {
  akit_stub ps 'case "$*" in
*comm=*) exit 1 ;;
esac
printf "  PID TTY          TIME CMD\n    1 ?        00:00:01 systemd\n  812 ?        00:00:00 splunkd\n"'
  run_survey
  [ "$(key agents)" = splunkuf ]
  akit_stub ps 'exit 1'
  run_survey
  [ "$(key agents)" = none ]
}

@test "distro default audit.rules is listed with :control" {
  put /etc/audit/rules.d/audit.rules '## First rule - delete all
-D

## Increase the buffers
-b 8192
-f 1'
  put /etc/audit/rules.d/10-custom.rules '-w /etc/hosts -p wa -k hosts'
  run_survey
  [ "$(key rules_d_files)" = "10-custom.rules,audit.rules:control" ]
  [ "$(key rules_d_control_lines)" = none ]
}

@test "files written by auditd-kit are not listed" {
  put /etc/audit/rules.d/10-auditd-kit-base.rules '-D'
  put /etc/audit/rules.d/20-tracked.rules '-w /etc/hosts -p wa -k hosts'
  put /etc/audit/rules.d/30-other.rules '-w /etc/hosts -p wa -k hosts'
  put /etc/auditd-kit/state 'version=1
file=0000000000000000000000000000000000000000000000000000000000000000 /etc/audit/rules.d/20-tracked.rules'
  run_survey
  [ "$(key rules_d_files)" = "30-other.rules" ]
  [ "$(key rules_d_control_lines)" = none ]
}

@test "-e 2 in a foreign rules file is listed in rules_d_control_lines" {
  put /etc/audit/rules.d/99-finalize.rules '# lock it
-w /etc/hosts -p wa -k hosts
-e   2'
  put /etc/audit/rules.d/05-reset.rules '-D'
  put /etc/audit/rules.d/98-nospace.rules '-e2'
  run_survey
  [ "$(key rules_d_control_lines)" = "05-reset.rules:-D,98-nospace.rules:-e2,99-finalize.rules:-e 2" ]
  [ "$(key rules_d_files)" = "05-reset.rules,98-nospace.rules,99-finalize.rules" ]
}

@test "every control line in a foreign rules file is listed, with or without a space" {
  put /etc/audit/rules.d/10-site.rules '-w /etc/hosts -p wa -k hosts
-f 2
-b8192
-r 100
-i
--backlog_wait_time 0
--loginuid-immutable
-f0'
  run_survey
  [ "$(key rules_d_control_lines)" = "10-site.rules:-f 2,10-site.rules:-b8192,10-site.rules:-r 100,10-site.rules:-i,10-site.rules:--backlog_wait_time 0,10-site.rules:--loginuid-immutable,10-site.rules:-f0" ]
}

@test "a control-only audit.rules with -r keeps :control and lists no control lines" {
  put /etc/audit/rules.d/audit.rules '-D
-b 8192
-f 1
-r 0
--backlog_wait_time 60000'
  run_survey
  [ "$(key rules_d_files)" = "audit.rules:control" ]
  [ "$(key rules_d_control_lines)" = none ]
}

@test "a control-only file with another name is listed plainly and reported" {
  put /etc/audit/rules.d/99-finalize.rules '-e 2'
  run_survey
  [ "$(key rules_d_files)" = "99-finalize.rules" ]
  [ "$(key rules_d_control_lines)" = "99-finalize.rules:-e 2" ]
}

@test "audit.rules with a rule line is listed plainly and its control lines are reported" {
  put /etc/audit/rules.d/audit.rules '-D
-w /etc/hosts -p wa -k hosts'
  run_survey
  [ "$(key rules_d_files)" = "audit.rules" ]
  [ "$(key rules_d_control_lines)" = "audit.rules:-D" ]
}

@test "loginuid-immutable and CIS or STIG rule files are reported" {
  put /etc/audit/rules.d/50-cis-level2.rules '-w /etc/hosts -p wa -k hosts'
  put /etc/audit/rules.d/60-site.rules '## STIG V-230400
-w /etc/shadow -p wa -k shadow'
  put /etc/audit/rules.d/70-plain.rules '-w /etc/hosts -p wa -k hosts
--loginuid-immutable'
  run_survey
  [ "$(key hardening_loginuid_immutable)" = yes ]
  [ "$(key hardening_rule_files)" = "50-cis-level2.rules,60-site.rules" ]
}

@test "hardening keys are no and none on a plain host" {
  run_survey
  [ "$(key hardening_loginuid_immutable)" = no ]
  [ "$(key hardening_rule_files)" = none ]
  [ "$(key rules_d_files)" = none ]
}

@test "syslog-ng only host reports syslog_daemon=syslog-ng" {
  put /etc/syslog-ng/syslog-ng.conf '@version: 3.35'
  akit_stub syslog-ng 'printf "syslog-ng 3 (3.35.1)\nConfig version: 3.35\nInstaller-Version: 3.35.1\n"'
  run_survey
  [ "$(key syslog_daemon)" = syslog-ng ]
  [ "$(key syslog_version)" = 3.35.1 ]
}

@test "rsyslog host reports its version" {
  put /etc/rsyslog.conf 'kern.* /dev/console'
  akit_stub rsyslogd 'echo "rsyslogd  8.2102.0 (aka 2021.02) compiled with:"'
  run_survey
  [ "$(key syslog_daemon)" = rsyslog ]
  [ "$(key syslog_version)" = 8.2102.0 ]
  akit_stub rsyslogd 'echo "rsyslogd  8.24.0-57.el7_9.3, compiled with:"'
  run_survey
  [ "$(key syslog_version)" = 8.24.0-57.el7_9.3 ]
}

@test "journald only and bare hosts" {
  mkdir -p "$AKIT_ROOT/run/systemd/journal"
  akit_stub journalctl 'echo "systemd 252 (252.22-1.el9)"'
  run_survey
  [ "$(key syslog_daemon)" = journald ]
  [ "$(key syslog_version)" = 252 ]
  use_host rocky8
  run_survey
  [ "$(key syslog_daemon)" = none ]
  [ "$(key syslog_version)" = none ]
}

@test "audit_volume_top_keys counts the last 24 hours" {
  mkdir -p "$AKIT_ROOT/var/log/audit"
  cp "$logs"/keys/audit.log* "$AKIT_ROOT/var/log/audit/"
  AKIT_NOW=1700000100 run_survey
  [[ "$(key audit_volume_top_keys)" == *exec:1* ]]
  AKIT_NOW=1699950000 run_survey
  all=$(key audit_volume_top_keys)
  [ -n "$all" ]
  expected=$(sh "$repo/scripts/stats.sh" --dir "$logs/keys" --top 10 | awk '$1 == "top_key" {printf "%s%s:%s", (n++ ? "," : ""), $2, $3}')
  [ "$all" = "$expected" ]
  AKIT_NOW=1800000000 run_survey
  [ "$(key audit_volume_top_keys)" = none ]
  [ "$(key survey_errors)" = "" ]
}

@test "audit_volume_top_keys is none without logs" {
  run_survey
  grep -q '^audit_volume_top_keys=none$' <<<"$output"
}

@test "survey_errors comes last, and text and JSON list the keys in the same order" {
  run_survey
  [[ "$(printf '%s\n' "$output" | sed -n '$p')" == survey_errors=* ]]
  text=$(printf '%s\n' "$output" | cut -d= -f1 | tr '\n' ' ')
  run_survey --json
  json=$(printf '%s\n' "$output" | grep -o '"[a-z0-9_]*":' | tr -d '":' | tr '\n' ' ')
  [ "$text" = "$json" ]
}

@test "survey still changes nothing" {
  put /etc/rsyslog.conf '*.* @@192.0.2.1'
  put /etc/audit/rules.d/99.rules '-e 2'
  mkdir -p "$AKIT_ROOT/var/log/audit" "$AKIT_ROOT/opt/CrowdStrike"
  cp "$logs"/keys/audit.log* "$AKIT_ROOT/var/log/audit/"
  before=$(cd "$AKIT_ROOT" && find . | sort && find . -type f -exec cksum {} + | sort)
  run_survey
  [ "$status" -eq 0 ]
  after=$(cd "$AKIT_ROOT" && find . | sort && find . -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
}
