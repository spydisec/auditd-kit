#!/usr/bin/env bats
# The stub bodies expand their own variables, so single quotes are intended.
# shellcheck disable=SC2016

load helpers

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
survey="$repo/scripts/survey.sh"
ama_dir=/opt/microsoft/azuremonitoragent
ama_conf=/etc/opt/microsoft/azuremonitoragent/config-cache
ws=00000000-0000-0000-0000-000000000000

put() {
  mkdir -p "$(dirname "$AKIT_ROOT$1")"
  printf '%s\n' "$2" >"$AKIT_ROOT$1"
}

key() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

run_survey() {
  run sh "$survey" "$@"
}

# resolve_as <global> <ingest> <ods>: stub getent to answer for the three names.
resolve_as() {
  akit_stub getent "a=
case \"\$2\" in
global.handler.*) a=$1 ;;
*.ingest.*) a=$2 ;;
*.ods.*) a=$3 ;;
esac
[ -z \"\$a\" ] || echo \"\$a  \$2\""
}

setup() {
  akit_stub id 'echo 1000'
  akit_stub ps 'printf "systemd\nbash\n"'
  akit_stub timeout 'shift; exec "$@"'
  akit_stub bash 'exit "${TEST_TCP_EXIT:-0}"'
  unset LC_ALL AKIT_NOW https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
  akit_fixture_root
  put /etc/os-release 'ID=rocky
VERSION_ID="8.10"'
}

with_ama() {
  mkdir -p "$AKIT_ROOT$ama_dir"
  put "$ama_conf/mcs.json" '{"location": "westeurope", "workspaceId": "'"$ws"'"}'
}

@test "no azure keys without --check azure" {
  with_ama
  run_survey
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^azure_')" -eq 0 ]
}

@test "an unknown check is reported and the survey exits 0" {
  run_survey --check bogus
  [ "$status" -eq 0 ]
  case ",$(key survey_errors)," in *,check:bogus,*) ;; *) false ;; esac
  [ "$(printf '%s\n' "$output" | grep -c '^azure_')" -eq 0 ]
}

@test "reports agent presence" {
  mkdir -p "$AKIT_ROOT$ama_dir"
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  run_survey --check azure
  [ "$(key azure_ama)" = yes ]
  [ "$(key azure_oms)" = no ]
  mkdir -p "$AKIT_ROOT/opt/microsoft/omsagent"
  run_survey --check azure
  [ "$(key azure_oms)" = yes ]
}

@test "classifies DNS answers and names each endpoint" {
  with_ama
  resolve_as 10.1.2.3 198.51.100.7 ""
  run_survey --check azure
  [ "$status" -eq 0 ]
  [ "$(key azure_endpoint_1)" = global.handler.control.monitor.azure.com ]
  [ "$(key azure_endpoint_2)" = westeurope.ingest.monitor.azure.com ]
  [ "$(key azure_endpoint_3)" = "$ws.ods.opinsights.azure.com" ]
  [ "$(key azure_dns_1)" = private ]
  [ "$(key azure_dns_2)" = public ]
  [ "$(key azure_dns_3)" = failed ]
}

@test "treats 100.64.0.0/10 and 172.16.0.0/12 as private and 172.32 as public" {
  with_ama
  resolve_as 100.100.1.1 172.31.0.1 172.32.0.1
  run_survey --check azure
  [ "$(key azure_dns_1)" = private ]
  [ "$(key azure_dns_2)" = private ]
  [ "$(key azure_dns_3)" = public ]
}

@test "reports region and workspace names as unknown without a config" {
  mkdir -p "$AKIT_ROOT$ama_dir"
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  run_survey --check azure
  [ "$(key azure_endpoint_2)" = unknown ]
  [ "$(key azure_dns_2)" = unknown ]
  [ "$(key azure_tcp443_2)" = unknown ]
  [ "$(key azure_endpoint_3)" = unknown ]
  [ "$(key azure_dns_3)" = unknown ]
  [ "$(key azure_dns_1)" = private ]
}

@test "reports TCP open and closed through bash" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  TEST_TCP_EXIT=0 run_survey --check azure
  [ "$(key azure_tcp443_1)" = open ]
  TEST_TCP_EXIT=1 run_survey --check azure
  [ "$(key azure_tcp443_1)" = closed ]
}

@test "does not probe TCP for a name that did not resolve" {
  with_ama
  resolve_as "" "" ""
  run_survey --check azure
  [ "$(key azure_dns_1)" = failed ]
  [ "$(key azure_tcp443_1)" = unknown ]
}

# minimal_path <tool>...: a PATH holding only the named tools, so bash and nc are absent.
minimal_path() {
  mp=$(mktemp -d "${BATS_TEST_TMPDIR}/min.XXXXXX")
  for t in "$@"; do
    ln -s "$(command -v "$t")" "$mp/$t"
  done
  cp "$AKIT_STUB_BIN"/getent "$AKIT_STUB_BIN"/id "$AKIT_STUB_BIN"/ps "$AKIT_STUB_BIN"/timeout "$mp/"
  echo "$mp"
}

@test "falls back to nc when bash is absent" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  akit_stub nc 'exit "${TEST_TCP_EXIT:-0}"'
  mp=$(minimal_path awk sed grep cat dirname uname date nc)
  PATH="$mp" TEST_TCP_EXIT=0 run /bin/sh "$survey" --check azure
  [ "$(key azure_tcp443_1)" = open ]
  PATH="$mp" TEST_TCP_EXIT=1 run /bin/sh "$survey" --check azure
  [ "$(key azure_tcp443_1)" = closed ]
}

@test "reports TCP unknown without bash and nc, and still exits 0" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  mp=$(minimal_path awk sed grep cat dirname uname date)
  PATH="$mp" run /bin/sh "$survey" --check azure
  [ "$status" -eq 0 ]
  [ "$(key azure_dns_1)" = private ]
  [ "$(key azure_tcp443_1)" = unknown ]
  [ "$(key azure_tcp443_3)" = unknown ]
}

@test "boundaries and mixed addresses classify correctly" {
  with_ama
  resolve_as 172.15.0.1 100.63.0.1 100.128.0.1
  run_survey --check azure
  [ "$(key azure_dns_1)" = public ]
  [ "$(key azure_dns_2)" = public ]
  [ "$(key azure_dns_3)" = public ]
  akit_stub getent 'printf "10.1.2.3  %s\n198.51.100.7  %s\n" "$2" "$2"'
  run_survey --check azure
  [ "$(key azure_dns_1)" = public ]
  akit_stub getent 'printf "10.1.2.3  %s\n192.168.1.1  %s\n" "$2" "$2"'
  run_survey --check azure
  [ "$(key azure_dns_1)" = private ]
  akit_stub getent 'echo "::FFFF:10.1.2.3  $2"'
  run_survey --check azure
  [ "$(key azure_dns_1)" = private ]
}

@test "a hostile region or workspace is reported as unknown and runs nothing" {
  mkdir -p "$AKIT_ROOT$ama_dir"
  put "$ama_conf/mcs.json" '{"location": "x;touch '"$BATS_TEST_TMPDIR"'/PWNED", "workspaceId": "a b$(touch '"$BATS_TEST_TMPDIR"'/PWNED2)"}'
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  run_survey --check azure
  [ "$status" -eq 0 ]
  [ "$(key azure_endpoint_2)" = unknown ]
  [ "$(key azure_endpoint_3)" = unknown ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED2" ]
}

@test "a getent that hangs is cut off by timeout" {
  mkdir -p "$AKIT_ROOT$ama_dir"
  rm "$AKIT_STUB_BIN/timeout"
  akit_stub getent 'exec sleep 30'
  start=$(date +%s)
  run_survey --check azure
  end=$(date +%s)
  [ $((end - start)) -lt 15 ]
  [ "$(key azure_dns_1)" = failed ]
}

@test "without timeout there are no network calls and the errors name it" {
  with_ama
  akit_stub getent 'touch '"$BATS_TEST_TMPDIR"'/CALLED'
  mp=$(minimal_path awk sed grep cat dirname uname date)
  rm "$mp/timeout"
  PATH="$mp" run /bin/sh "$survey" --check azure
  [ "$status" -eq 0 ]
  [ "$(key azure_dns_1)" = unknown ]
  [ "$(key azure_tcp443_1)" = unknown ]
  [ "$(key azure_dns_3)" = unknown ]
  case ",$(key survey_errors)," in *,azure_no_timeout,*) ;; *) false ;; esac
  [ ! -e "$BATS_TEST_TMPDIR/CALLED" ]
}

@test "proxy credentials are removed even when the password holds a slash" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  https_proxy='http://u:p/x@h:3128' run_survey --check azure
  [ "$(key azure_proxy)" = "http://h:3128" ]
  https_proxy='u:p/x@h' run_survey --check azure
  [ "$(key azure_proxy)" = "h" ]
}

@test "reports the proxy with credentials removed" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  run_survey --check azure
  [ "$(key azure_proxy)" = none ]
  https_proxy='http://user:p@ss@proxy.example.com:3128/' run_survey --check azure
  [ "$(key azure_proxy)" = "http://proxy.example.com:3128/" ]
  HTTP_PROXY='user:pw@proxy.example.com:3128' run_survey --check azure
  [ "$(key azure_proxy)" = "proxy.example.com:3128" ]
  [ "$(printf '%s' "$output" | grep -c 'pw')" -eq 0 ]
}

@test "the first proxy variable that is set wins" {
  with_ama
  resolve_as 10.1.2.3 10.1.2.3 10.1.2.3
  https_proxy=http://a.example.com:1 HTTP_PROXY=http://b.example.com:2 run_survey --check azure
  [ "$(key azure_proxy)" = "http://a.example.com:1" ]
}
