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

@test "prifilt star is a catch-all and a prifilt on mail is not" {
  put /etc/rsyslog.conf 'if prifilt("*.*") then {
  action(type="omfwd" target="192.0.2.1" port="514" protocol="tcp")
}
if prifilt("mail.*") then action(type="omfwd" target="192.0.2.2")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [[ "$(key syslog_catchall_lines)" == 'if prifilt("*.*") then action('* ]]
  [[ "$(key syslog_catchall_lines)" != *192.0.2.2* ]]
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp,192.0.2.2:514/udp" ]
  [ "$(key syslog_facilities_used)" = mail ]
}

@test "auth.* forward is not a catch-all" {
  put /etc/rsyslog.conf 'auth,authpriv.* @@192.0.2.1:514'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_catchall_lines)" = none ]
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp" ]
}

@test "a * selector is a catch-all even with .none exclusions" {
  put /etc/rsyslog.conf '*.*;local0,local1,local2,local3,local4,local5,local6,local7.none @@192.0.2.1'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
}

@test "local facilities count unless excluded with .none" {
  put /etc/rsyslog.conf 'local6.* @@192.0.2.1'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  put /etc/rsyslog.conf 'local6.*;local6.none @@192.0.2.1
auth.*;local3.none @@192.0.2.2'
  run_survey
  [ "$(key syslog_catchall)" = no ]
}

@test "forwards in an unused ruleset or a comment are not catch-alls" {
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
  [ "$(key syslog_dropins)" = none ]
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

@test "syslog_plugin_installed needs the binary on 3.x and builtin_syslog on RHEL 7" {
  run_survey
  [ "$(key syslog_plugin_installed)" = no ]
  for f in /usr/sbin/audisp-syslog /sbin/audisp-syslog; do
    use_host rocky8
    put "$f" 'binary'
    run_survey
    [ "$(key syslog_plugin_installed)" = yes ]
  done
  use_host centos7
  put /etc/audisp/plugins.d/syslog.conf 'active = yes
path = builtin_syslog'
  run_survey
  [ "$(key syslog_plugin_installed)" = yes ]
}

@test "a leftover plugin config without the binary does not count" {
  put /etc/audit/plugins.d/syslog.conf 'active = yes
path = /sbin/audisp-syslog'
  run_survey
  [ "$(key syslog_plugin_installed)" = no ]
  put /etc/audisp/plugins.d/syslog.conf 'active = no
path = /sbin/audisp-syslog'
  run_survey
  [ "$(key syslog_plugin_installed)" = no ]
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

# The next tests follow the layout of the distro default files (see tests/fixtures/rsyslog).

# use_rsyslog <fixture>: copy a distro-style rsyslog layout into the root.
use_rsyslog() {
  cp -R "$repo/tests/fixtures/rsyslog/$1/." "$AKIT_ROOT/"
}

@test "distro default rsyslog layouts have no forward and no catch-all" {
  for d in rhel7 rhel9 ubuntu2404; do
    use_host rocky8
    use_rsyslog "$d"
    run_survey
    [ "$(key syslog_forward_targets)" = none ]
    [ "$(key syslog_catchall)" = no ]
  done
}

@test "a forward appended to the main file of each distro layout is found" {
  line_rhel7='*.* @@203.0.113.10:514'
  line_rhel9='action(type="omfwd" Target="198.51.100.20" Port="10514" Protocol="tcp")'
  for pair in rhel7:203.0.113.10:514/tcp rhel9:198.51.100.20:10514/tcp ubuntu2404:203.0.113.10:514/tcp; do
    d=${pair%%:*}
    use_host rocky8
    use_rsyslog "$d"
    if [ "$d" = rhel9 ]; then printf '%s\n' "$line_rhel9" >>"$AKIT_ROOT/etc/rsyslog.conf"; else printf '%s\n' "$line_rhel7" >>"$AKIT_ROOT/etc/rsyslog.conf"; fi
    run_survey
    [ "$(key syslog_forward_targets)" = "${pair#*:}" ]
    [ "$(key syslog_catchall)" = yes ]
  done
}

@test "a forward in a drop-in of each distro layout is found" {
  for d in rhel7 rhel9 ubuntu2404; do
    use_host rocky8
    use_rsyslog "$d"
    put /etc/rsyslog.d/60-remote.conf '*.* @@203.0.113.10:514'
    run_survey
    [ "$(key syslog_forward_targets)" = "203.0.113.10:514/tcp" ]
    [ "$(key syslog_catchall)" = yes ]
  done
  use_host rocky8
  use_rsyslog ubuntu2404
  put /etc/rsyslog.d/60-remote.conf 'auth,authpriv.* @@203.0.113.10:514'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_facilities_used)" = "auth,authpriv,kern,mail" ]
}

@test "a slash-star in a path or an include is not a comment" {
  put /etc/rsyslog.conf '$IncludeConfig /etc/rsyslog.d/*.conf
*.* /var/log/all/*
*.* @@192.0.2.1
/* real comment */
local1.* @@192.0.2.2'
  run_survey
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp,192.0.2.2:514/tcp" ]
  [ "$(key syslog_catchall)" = yes ]
}

@test "forwards behind severity, property, and expression filters are catch-alls" {
  for conf in 'if $syslogseverity <= 6 then action(type="omfwd" target="192.0.2.1")' \
    "if \$syslogfacility-text != 'mail' then @@192.0.2.1" \
    'if not prifilt("mail.*") then action(type="omfwd" target="192.0.2.1")' \
    "if \$syslogfacility-text == 'auth' then action(type=\"omfwd\" target=\"192.0.2.1\")" \
    ':msg, contains, "x" action(type="omfwd" target="192.0.2.1")' \
    ':syslogfacility-text, isequal, "local6" @@192.0.2.1' \
    'if prifilt("auth.*") then stop
else action(type="omfwd" target="192.0.2.1")' \
    'if prifilt("auth.*") then {
  stop
} else {
  action(type="omfwd" target="192.0.2.1")
}'; do
    put /etc/rsyslog.conf "$conf"
    run_survey
    [[ "$(key syslog_forward_targets)" == 192.0.2.1:514/* ]]
    [ "$(key syslog_catchall)" = yes ]
  done
}

@test "a ruleset that is called or bound makes its forward a catch-all" {
  put /etc/rsyslog.conf 'ruleset(name="fwd") {
  action(type="omfwd" target="192.0.2.1")
}
call fwd'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  put /etc/rsyslog.conf 'module(load="imjournal" Ruleset="fw")
ruleset(name="fw") {
 action(type="omfwd" target="192.0.2.1")
}'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  put /etc/rsyslog.conf 'ruleset(name="r"){ action(type="omfwd" target="192.0.2.1") }
input(type="imtcp" port="10514" ruleset="r")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  put /etc/rsyslog.conf '$RuleSet remote
*.* @@192.0.2.1
$RuleSet RSYSLOG_DefaultRuleset
$InputTCPServerBindRuleset remote'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
}

@test "a target is recorded for every kind of forward" {
  put /etc/rsyslog.conf 'if $programname == "a" then @@192.0.2.1
if prifilt("auth.*") then
  @@192.0.2.2
:msg, contains, "x" action(type="omfwd" target="192.0.2.3")
ruleset(name="r"){ action(type="omfwd" target="192.0.2.4") }
if prifilt("mail.*") then {
  stop
} else action(type="omfwd" target="192.0.2.5")
if prifilt("mail.*") then @@192.0.2.6
& @@192.0.2.7
Action(Type="omfwd" Target="192.0.2.8")
action(type="omrelp" target="192.0.2.9" port="2514")
*.info :omrelp:192.0.2.10:20514
local5.* :omfwd:192.0.2.11:10514'
  run_survey
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp,192.0.2.2:514/tcp,192.0.2.3:514/udp,192.0.2.4:514/udp,192.0.2.5:514/udp,192.0.2.6:514/tcp,192.0.2.7:514/tcp,192.0.2.8:514/udp,192.0.2.9:2514/relp,192.0.2.10:20514/relp,192.0.2.11:10514/udp" ]
}

@test "an if-then-action with a facility prifilt on the next line stays not a catch-all" {
  put /etc/rsyslog.conf 'if prifilt("auth.*") then
  @@192.0.2.2
& @@192.0.2.3'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_forward_targets)" = "192.0.2.2:514/tcp,192.0.2.3:514/tcp" ]
}

@test "a filter does not leak out of an else-if chain" {
  put /etc/rsyslog.conf 'if prifilt("auth.*") then {
  stop
} else if prifilt("mail.*") then {
  stop
}
action(type="omfwd" target="192.0.2.9")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  put /etc/rsyslog.conf 'if prifilt("auth.*") then stop
else action(type="omfwd" target="192.0.2.8")
action(type="omfwd" target="192.0.2.9")'
  run_survey
  [ "$(key syslog_catchall)" = yes ]
  [[ "$(key syslog_catchall_lines)" == *192.0.2.9* ]]
}

@test "an unbalanced statement makes syslog_catchall unknown and later lines still count" {
  put /etc/rsyslog.conf 'action(type="omfwd" target="192.0.2.1"
port="514"'
  run_survey
  [ "$(key syslog_catchall)" = unknown ]
  put /etc/rsyslog.conf 'if prifilt("auth.*") then {
  action(type="omfwd" target="192.0.2.1")'
  run_survey
  [ "$(key syslog_catchall)" = unknown ]
  put /etc/rsyslog.conf 'auth.* /var/log/x (
auth.* @@192.0.2.5'
  run_survey
  [ "$(key syslog_catchall)" = no ]
  [ "$(key syslog_forward_targets)" = "192.0.2.5:514/tcp" ]
}

@test "a property filter on the facility adds to syslog_facilities_used" {
  put /etc/rsyslog.d/30-prop.conf ':syslogfacility-text, isequal, "local6" /var/log/l6.log'
  run_survey
  [ "$(key syslog_facilities_used)" = local6 ]
}

@test "a backslash continuation joins the selector without a break" {
  put /etc/rsyslog.conf '*.*;\
mail.none @@192.0.2.1
auth.*;\
	mail.* @@192.0.2.2'
  run_survey
  [ "$(key syslog_forward_targets)" = "192.0.2.1:514/tcp,192.0.2.2:514/tcp" ]
  [ "$(key syslog_catchall_lines)" = "*.*;mail.none @@192.0.2.1" ]
}

# conf_case <expected-targets> <expected-catchall> <conf>: survey a one-file rsyslog config.
conf_case() {
  put /etc/rsyslog.conf "$3"
  run_survey
  [ "$(key syslog_forward_targets)" = "$1" ]
  [ "$(key syslog_catchall)" = "$2" ]
}

@test "selector items apply left to right, so a later item can select local6 again" {
  conf_case 198.51.100.17:514/tcp yes '*.none;local6.* @@198.51.100.17'
  conf_case 192.0.2.14:514/tcp yes 'local6.none;local6.info @@192.0.2.14'
  conf_case 198.51.100.18:514/tcp yes 'auth.*;*.none;local6.info @@198.51.100.18'
  conf_case 192.0.2.1:514/tcp no 'local6.*;local6.none @@192.0.2.1'
  conf_case 192.0.2.1:514/tcp no 'auth.*;*.none;mail.* @@192.0.2.1'
}

@test "set, foreach, and if blocks on one line still reach the action" {
  conf_case 192.0.2.11:514/udp yes 'set $.x = "a"; action(type="omfwd" target="192.0.2.11")'
  conf_case 192.0.2.5:514/udp yes 'foreach ($.i in $!arr) do { action(type="omfwd" target="192.0.2.5") }'
  conf_case 198.51.100.21:514/udp yes 'foreach ($.i in $!a) do {
  set $.y = $.i; action(type="omfwd" target="198.51.100.21")
}'
  conf_case 192.0.2.12:514/udp yes "if \$msg contains 'z' then { set \$!a = \"1\"; action(type=\"omfwd\" target=\"192.0.2.12\") }"
  conf_case 192.0.2.4:514/udp yes 'foreach ($.i in $!a) do
  action(type="omfwd" target="192.0.2.4")'
}

@test "call_indirect makes every ruleset used" {
  conf_case 192.0.2.13:514/udp yes 'ruleset(name="fw13") {
  action(type="omfwd" target="192.0.2.13")
}
set $.rs = "fw13";
call_indirect $.rs;'
}

@test "a legacy omruleset binding makes its ruleset used" {
  conf_case 192.0.2.20:514/tcp yes '$RuleSet fwd18
*.* @@192.0.2.20
$RuleSet RSYSLOG_DefaultRuleset
$ActionOmrulesetRulesetName fwd18
*.* :omruleset:'
}

@test "the word then inside a string does not end the if filter" {
  conf_case 192.0.2.15:514/tcp yes 'if $msg contains " then " then @@192.0.2.15'
}

@test "a then on the next line and a multi-line template parse cleanly" {
  conf_case 192.0.2.18:514/udp yes "if \$programname == 'x'
  then {
  action(type=\"omfwd\" target=\"192.0.2.18\")
}"
  conf_case none no 'template(name="t" type="list") {
  property(name="msg"
    controlcharacters="escape")
  constant(value="\n")
}'
}

@test "a backtick target is recorded as its backtick text" {
  conf_case '`echo x`:514/udp' yes 'action(type="omfwd" target=`echo x` port="514")'
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
