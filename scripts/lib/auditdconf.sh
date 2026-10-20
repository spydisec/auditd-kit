# Read and set keys in auditd.conf. Source this file after common.sh, don't run it.
# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154
#
# auditd-kit sets only the keys it manages and leaves every other line alone, because auditd 2.8
# on RHEL 7 rejects keys that auditd 3.x accepts. A key line is "key = value", with any spacing.

AKIT_AUDITD_CONF=/etc/audit/auditd.conf

# akit_auditdconf_get <file> <key>: print the value of the last line that sets the key.
akit_auditdconf_get() {
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, k) == 1 && substr(line, length(k) + 1) ~ /^[ \t]*=/ {
      v = substr(line, index(line, "=") + 1)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t]+$/, "", v)
    }
    END { print v }' "$1"
}

# akit_auditdconf_set <file> <key> <value>: replace each line that sets the key with
# "key = value", or append that line when no line sets it. The file is written only when its
# content changes, and in place, so its owner, mode, and SELinux label stay.
akit_auditdconf_set() {
  conf_tmp=$(mktemp) || return 1
  if [ -f "$1" ]; then
    conf_in=$1
  else
    conf_in=/dev/null
  fi
  if ! awk -v k="$2" -v v="$3" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, k) == 1 && substr(line, length(k) + 1) ~ /^[ \t]*=/ {
      print k " = " v
      done = 1
      next
    }
    { print }
    END { if (!done) print k " = " v }' "$conf_in" >"$conf_tmp"; then
    rm -f "$conf_tmp"
    return 1
  fi
  if ! akit_same_file "$conf_tmp" "$1"; then
    if ! cat "$conf_tmp" >"$1"; then
      rm -f "$conf_tmp"
      return 1
    fi
  fi
  rm -f "$conf_tmp"
}

# akit_auditdconf_wanted <kit-dir>: print "key value" for each key that auditd-kit manages, from
# config/auditd/<akit_size>.conf, with akit_max_log_file and akit_num_logs in place of the preset
# values. Needs the settings from settings.sh.
akit_auditdconf_wanted() {
  [ -r "$1/config/auditd/$akit_size.conf" ] || return 1
  awk -v max="$akit_max_log_file" -v num="$akit_num_logs" '
    /^[ \t]*#/ || !/=/ { next }
    {
      k = substr($0, 1, index($0, "=") - 1)
      v = substr($0, index($0, "=") + 1)
      gsub(/[ \t]/, "", k)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == "max_log_file") v = max
      if (k == "num_logs") v = num
      print k, v
    }' "$1/config/auditd/$akit_size.conf"
}
