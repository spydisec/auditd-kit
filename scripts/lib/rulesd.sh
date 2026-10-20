# Sort the files in /etc/audit/rules.d by who wrote them. Source this file after common.sh,
# don't run it. The survey and plan.sh both use it, so they always agree.
# shellcheck shell=sh
#
# A file is "ours" when its name contains auditd-kit or a file=<sha256> <path> line in the state
# file lists it. A distro audit.rules that holds only control lines is "control". Every other
# file is "foreign". The functions read files under AKIT_ROOT and work with or without set -eu.

AKIT_RULES_D=/etc/audit/rules.d

# akit_rulesd_state_has <abs-path>: succeed when the state file lists the path.
akit_rulesd_state_has() {
  rulesd_sf=$(akit_path /etc/auditd-kit/state)
  [ -r "$rulesd_sf" ] || return 1
  sed -n 's/^file=[^ ]* //p' "$rulesd_sf" | grep -x -F "$1" >/dev/null 2>&1
}

# akit_rulesd_is_ours <name>
akit_rulesd_is_ours() {
  case "$1" in
    *auditd-kit*) return 0 ;;
  esac
  akit_rulesd_state_has "$AKIT_RULES_D/$1"
}

# akit_rulesd_files: print the names of the *.rules files in rules.d, one per line.
akit_rulesd_files() {
  rulesd_dir=$(akit_path "$AKIT_RULES_D")
  [ -d "$rulesd_dir" ] || return 0
  for rulesd_f in "$rulesd_dir"/*.rules; do
    [ -f "$rulesd_f" ] || continue
    printf '%s\n' "${rulesd_f##*/}"
  done
}

# akit_rulesd_body <name>: print the lines that are not blank or comments.
akit_rulesd_body() {
  sed -e 's/^[[:space:]]*//' -e '/^#/d' -e '/^$/d' "$(akit_path "$AKIT_RULES_D/$1")"
}

# akit_rulesd_control <name>: print "yes" when the file holds only control lines, else "no".
# The second line lists its control lines as <name>:<line>, joined by commas. A control line
# starts with a flag in AKIT_CONTROL_FLAGS, with or without a space before the value.
akit_rulesd_control() {
  rulesd_body=$(akit_rulesd_body "$1") || return 1
  printf '%s\n' "$rulesd_body" | awk -v f="$1" '
    function is_control(word,    n, c, i) {
      n = split(ENVIRON["AKIT_CONTROL_FLAGS"], c, " ")
      for (i = 1; i <= n; i++) {
        if (word == c[i]) return 1
        if (c[i] ~ /^--/) {
          if (index(word, c[i] "=") == 1) return 1
        } else if (index(word, c[i]) == 1) return 1
      }
      return 0
    }
    NF == 0 {next}
    is_control($1) {
      gsub(/[ \t]+/, " ")
      sub(/ $/, "")
      lines = lines (n++ ? "," : "") f ":" $0
      next
    }
    {bad = 1}
    END {print (bad ? "no" : "yes"); print lines}'
}

# akit_rulesd_sort: print "<ours|control|foreign> <name>" for each file. Fails when a file that
# is not ours can't be read.
akit_rulesd_sort() {
  for rulesd_n in $(akit_rulesd_files); do
    if akit_rulesd_is_ours "$rulesd_n"; then
      echo "ours $rulesd_n"
      continue
    fi
    rulesd_only=$(akit_rulesd_control "$rulesd_n") || return 1
    if [ "$rulesd_n" = audit.rules ] && [ "$(printf '%s\n' "$rulesd_only" | sed -n 1p)" = yes ]; then
      echo "control $rulesd_n"
    else
      echo "foreign $rulesd_n"
    fi
  done
}
