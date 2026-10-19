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

@test "detects omfwd and @@ forward targets" {
  put /etc/rsyslog.conf '$IncludeConfig /etc/rsyslog.d/*.conf'
  put /etc/rsyslog.d/50-remote.conf 'action(type="omfwd" target="192.0.2.1"
  port="6514" protocol="tcp")
local3.* @@198.51.100.7:1514
auth.* @(o)203.0.113.9
authpriv.* :omfwd:example.com:10514;RSYSLOG_ForwardFormat
mail.* @[2001:db8::1]:515'
  run_survey
  [ "$status" -eq 0 ]
  [ "$(key syslog_forward_targets)" = "192.0.2.1:6514/tcp,198.51.100.7:1514/tcp,203.0.113.9:514/udp,example.com:10514/udp,[2001:db8::1]:515/udp" ]
}

@test "omfwd parameters accept any quoting and defaults" {
  put /etc/rsyslog.conf "action(Type='omfwd' Target=192.0.2.5)
action(type=\"omfwd\", target=\"192.0.2.6\", port=\"601\", protocol=\"udp\")
action(type=\"omfile\" file=\"/var/log/x\")"
  run_survey
  [ "$(key syslog_forward_targets)" = "192.0.2.5:514/udp,192.0.2.6:601/udp" ]
}

@test "*.* @@203.0.113.10:514 sets syslog_catchall=yes" {
  put /etc/rsyslog.conf '*.* @@203.0.113.10:514'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [ "$(key syslog_catchall_lines)" = "*.* @@203.0.113.10:514" ]
  [ "$(key syslog_forward_targets)" = "203.0.113.10:514/tcp" ]
}

@test "*.info and an unfiltered omfwd action are catch-alls" {
  put /etc/rsyslog.conf '*.info @192.0.2.1'
  put /etc/rsyslog.d/60-all.conf 'action(type="omfwd" target="192.0.2.2" port="514" protocol="tcp")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [[ "$(key syslog_catchall_lines)" == "*.info @192.0.2.1 | action(type=\"omfwd\""* ]]
}

@test "prifilt star is a catch-all and a local6 filter is not" {
  put /etc/rsyslog.conf 'if prifilt("*.*") then {
  action(type="omfwd" target="192.0.2.1" port="514" protocol="tcp")
}
if $syslogfacility-text == '"'"'local4'"'"' then action(type="omfwd" target="192.0.2.2")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [[ "$(key syslog_catchall_lines)" == 'if prifilt("*.*") then action('* ]]
  [[ "$(key syslog_catchall_lines)" != *192.0.2.2* ]]
  [ "$(key syslog_facilities_used)" = local4 ]
}

@test "auth.* forward is not a catch-all" {
  put /etc/rsyslog.conf 'auth,authpriv.* @@192.0.2.1:514'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_catchall_lines)" = none ]
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp" ]
}

@test "a .none exclusion of local0 to local7 is not a catch-all" {
  put /etc/rsyslog.conf '*.*;local0,local1,local2,local3,local4,local5,local6,local7.none @@192.0.2.1'
  put /etc/rsyslog.d/70-part.conf '*.*;local6.none @@192.0.2.2'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [ "$(key syslog_catchall_lines)" = "*.*;local6.none @@192.0.2.2" ]
}

@test "forwards inside a ruleset or a comment are not catch-alls" {
  put /etc/rsyslog.conf '# *.* @@192.0.2.1
/* *.* @@192.0.2.9 */
ruleset(name="fwd") {
  action(type="omfwd" target="192.0.2.3")
}'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_forward_targets)" = "192.0.2.3:514/udp" ]
}

@test "facility local6 used by another drop-in is listed" {
  put /etc/rsyslog.conf 'kern.* /dev/console'
  put /etc/rsyslog.d/30-app.conf 'local6.* /var/log/app.log
& stop'
  put /etc/rsyslog.d/31-prifilt.conf 'if prifilt("local2.info") then /var/log/x.log'
  run_survey
  [ "$(key syslog_facilities_used)" = "kern,local6,local2" ]
}

@test "our own 40-auditd-kit.conf is ignored for facility use" {
  put /etc/rsyslog.d/40-auditd-kit.conf 'local6.* action(type="omfwd" target="192.0.2.1" port="514" protocol="tcp")'
  run_survey
  [ "$(key syslog_facilities_used)" = none ]
  [ "$(key syslog_dropins)" = 40-auditd-kit.conf ]
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp" ]
}

@test "rsyslog.conf is read before the drop-ins and rsyslog.d is listed" {
  put /etc/rsyslog.conf 'cron.* /var/log/cron'
  put /etc/rsyslog.d/20-b.conf 'mail.* /var/log/mail'
  put /etc/rsyslog.d/10-a.conf 'ftp.* /var/log/ftp'
  run_survey
  [ "$(key syslog_facilities_used)" = "cron,ftp,mail" ]
  [ "$(key syslog_dropins)" = "10-a.conf,20-b.conf" ]
}

@test "each agent is detected from its fixture path" {
  for pair in mde:/opt/microsoft/mdatp crowdstrike:/opt/CrowdStrike wazuh:/var/ossec \
    auditbeat:/usr/share/auditbeat auditbeat:/etc/auditbeat splunkuf:/opt/splunkforwarder \
    osquery:/opt/osquery osquery:/etc/osquery; do
    use_host rocky8
    mkdir -p "$AKIT_ROOT${pair#*:}"
    run_survey
    [ "$(key agents)" = "${pair%%:*}" ]
  done
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
  run_survey
  [ "$(key rules_d_control_lines)" = "05-reset.rules:-D,99-finalize.rules:-e 2" ]
  [ "$(key rules_d_files)" = "05-reset.rules:control,99-finalize.rules" ]
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
  [ "$(key syslog_dropins)" = none ]
}

@test "rsyslog host reports its version" {
  put /etc/rsyslog.conf 'kern.* /dev/console'
  akit_stub rsyslogd 'echo "rsyslogd  8.2102.0 (aka 2021.02) compiled with:"'
  run_survey
  [ "$(key syslog_daemon)" = rsyslog ]
  [ "$(key syslog_version)" = 8.2102.0 ]
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

@test "syslog_plugin_installed from a binary or a plugin config" {
  run_survey
  [ "$(key syslog_plugin_installed)" = no ]
  for f in /usr/sbin/audisp-syslog /sbin/audisp-syslog /etc/audit/plugins.d/syslog.conf /etc/audisp/plugins.d/syslog.conf; do
    use_host rocky8
    put "$f" 'active = yes'
    run_survey
    [ "$(key syslog_plugin_installed)" = yes ]
  done
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
  [ -z "$(key audit_volume_top_keys)" ]
  [ "$(key survey_errors)" = "" ]
}

@test "audit_volume_top_keys is empty without logs" {
  run_survey
  grep -q '^audit_volume_top_keys=$' <<<"$output"
}

@test "the new keys follow the existing ones in order, in text and JSON" {
  run_survey
  last=$(printf '%s\n' "$output" | sed -n '$p')
  [[ "$last" == survey_errors=* ]]
  order=$(printf '%s\n' "$output" | sed -n '/^akit_state_profile=/,$p' | cut -d= -f1 | tr '\n' ' ')
  [ "$order" = "akit_state_profile agents hardening_loginuid_immutable hardening_rule_files rules_d_files rules_d_control_lines syslog_daemon syslog_version syslog_forward_targets syslog_facilities_used syslog_catchall syslog_catchall_lines syslog_dropins syslog_plugin_installed audit_volume_top_keys survey_errors " ]
  run_survey --json
  [[ "$output" == *'"akit_state_profile":"","agents":"none",'* ]]
  [[ "$output" == *'"audit_volume_top_keys":"","survey_errors":""}' ]]
}

@test "a failing logging check reports its keys as unknown and exits 0" {
  put /etc/rsyslog.conf 'kern.* /dev/console'
  chmod 000 "$AKIT_ROOT/etc/rsyslog.conf"
  run_survey
  [ "$status" -eq 0 ]
  [ "$(key syslog_catchall)" = unknown ]
  [[ "$(key survey_errors)" == *syslog_forwarding* ]]
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
