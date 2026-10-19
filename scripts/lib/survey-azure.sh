# Opt-in Azure Monitor check for the survey. Source this file, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2154
#
# survey.sh runs survey_check_azure only for "--check azure". It reads the AMA config under
# AKIT_ROOT and probes the network. Every probe runs under timeout(1) and stops after
# AKIT_AZURE_TIMEOUT seconds (default 5). When timeout is missing,
# the check makes no network call, reports every dns and tcp key as unknown, and names
# azure_no_timeout in survey_errors. It always returns 0.

AKIT_AZURE_TIMEOUT=${AKIT_AZURE_TIMEOUT:-5}
survey_ama_conf=/etc/opt/microsoft/azuremonitoragent

# survey_azure_field <name>: print the first value of a "name": "value" field in the AMA JSON files.
survey_azure_field() {
  survey_af_dir=$(akit_path "$survey_ama_conf")
  [ -d "$survey_af_dir" ] || return 0
  find "$survey_af_dir" -type f -name '*.json' -exec cat {} + 2>/dev/null \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

# survey_azure_name <value>: print the value when it is a safe host label part, else nothing.
survey_azure_name() {
  case "$1" in
    *[!A-Za-z0-9.-]*) ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# survey_azure_private <address>: succeed for RFC 1918, 100.64.0.0/10, and IPv6 unique-local.
survey_azure_private() {
  survey_ap=$1
  case "$survey_ap" in
    ::[fF][fF][fF][fF]:*) survey_ap=${survey_ap#::????:} ;;
  esac
  case "$survey_ap" in
    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
    [fF][cCdD]*:*) return 0 ;;
  esac
  return 1
}

# survey_azure_dns <host>: print private, public, or failed. Public wins when any address is public.
survey_azure_dns() {
  survey_ad_all=$(timeout "$AKIT_AZURE_TIMEOUT" getent hosts "$1" 2>/dev/null | awk 'NF {print $1}')
  if [ -z "$survey_ad_all" ]; then
    echo failed
    return 0
  fi
  survey_ad_res=private
  for survey_ad_addr in $survey_ad_all; do
    survey_azure_private "$survey_ad_addr" || survey_ad_res=public
  done
  echo "$survey_ad_res"
}

# survey_azure_tcp <host>: print open, closed, or unknown. A bash built without /dev/tcp
# support fails the probe, so it reports closed.
survey_azure_tcp() {
  if command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    if timeout "$AKIT_AZURE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/$1/443' _ "$1" >/dev/null 2>&1; then
      echo open
    else
      echo closed
    fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z -w "$AKIT_AZURE_TIMEOUT" "$1" 443 >/dev/null 2>&1; then
      echo open
    else
      echo closed
    fi
  else
    echo unknown
  fi
}

# survey_azure_proxy: print the first proxy variable that is set, without user:password@.
survey_azure_proxy() {
  for survey_pv in "${https_proxy:-}" "${HTTPS_PROXY:-}" "${http_proxy:-}" "${HTTP_PROXY:-}"; do
    if [ -n "$survey_pv" ]; then
      printf '%s\n' "$survey_pv" \
        | sed -e 's,^\([A-Za-z][A-Za-z0-9+.-]*://\).*@\(.*\)$,\1\2,' -e 's,^.*@,,'
      return 0
    fi
  done
  echo none
}

survey_check_azure() {
  survey_az_region=$(survey_azure_field location)
  [ -n "$survey_az_region" ] || survey_az_region=$(survey_azure_field region)
  survey_az_ws=$(survey_azure_field workspaceId)
  survey_az_region=$(survey_azure_name "$survey_az_region")
  survey_az_ws=$(survey_azure_name "$survey_az_ws")
  survey_az_probe=yes
  if ! command -v timeout >/dev/null 2>&1; then
    survey_az_probe=no
    survey_add_error azure_no_timeout
  fi

  if [ -d "$(akit_path /opt/microsoft/azuremonitoragent)" ]; then
    akit_kv azure_ama yes
  else
    akit_kv azure_ama no
  fi
  if [ -d "$(akit_path /opt/microsoft/omsagent)" ]; then
    akit_kv azure_oms yes
  else
    akit_kv azure_oms no
  fi
  akit_kv azure_proxy "$(survey_azure_proxy)"

  survey_az_n=0
  for survey_az_host in global.handler.control.monitor.azure.com \
    "${survey_az_region:+$survey_az_region.ingest.monitor.azure.com}" \
    "${survey_az_ws:+$survey_az_ws.ods.opinsights.azure.com}"; do
    survey_az_n=$((survey_az_n + 1))
    if [ -z "$survey_az_host" ]; then
      akit_kv "azure_endpoint_$survey_az_n" unknown
      akit_kv "azure_dns_$survey_az_n" unknown
      akit_kv "azure_tcp443_$survey_az_n" unknown
      continue
    fi
    akit_kv "azure_endpoint_$survey_az_n" "$survey_az_host"
    if [ "$survey_az_probe" = no ]; then
      akit_kv "azure_dns_$survey_az_n" unknown
      akit_kv "azure_tcp443_$survey_az_n" unknown
      continue
    fi
    survey_az_dns=$(survey_azure_dns "$survey_az_host")
    akit_kv "azure_dns_$survey_az_n" "$survey_az_dns"
    if [ "$survey_az_dns" = failed ]; then
      akit_kv "azure_tcp443_$survey_az_n" unknown
    else
      akit_kv "azure_tcp443_$survey_az_n" "$(survey_azure_tcp "$survey_az_host")"
    fi
  done
  return 0
}
