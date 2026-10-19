#!/bin/sh
# Check the syntax of every *.rules file in a dir without loading it.
#
# Usage: validate.sh <rules-dir>
#
# A line passes when it is blank, a comment, an -a/-A rule, a -w watch, or a control line.
# Each bad line is printed as "<file>:<line>: <text>". Exits 0 when all lines pass, else 1.
set -eu

lib=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck source=/dev/null
. "$lib/common.sh"

[ $# -eq 1 ] || akit_die "$AKIT_EXIT_REFUSED" "usage: validate.sh <rules-dir>"
dir=$1
[ -d "$dir" ] || akit_die "$AKIT_EXIT_REFUSED" "validate: rules dir not found: $dir"

found=0
for f in "$dir"/*.rules; do
  [ -f "$f" ] && found=1
done
[ "$found" -eq 1 ] || akit_die "$AKIT_EXIT_REFUSED" "validate: no .rules files in $dir"

awk '
function rule_ok(n, t, i, flag, val) {
  if (t[2] !~ /^(always|never),(exit|task|user|exclude|filesystem|io_uring)$/ &&
    t[2] !~ /^(exit|task|user|exclude|filesystem|io_uring),(always|never)$/)
    return 0
  for (i = 3; i <= n; i += 2) {
    flag = t[i]
    if (i == n)
      return 0
    val = t[i + 1]
    if (flag == "-F") {
      if (val !~ /^[A-Za-z0-9_]+(!=|<=|>=|&=|=|<|>|&)[^ \t]+$/)
        return 0
    } else if (flag == "-C") {
      if (val !~ /^[A-Za-z0-9_]+(!=|=)[A-Za-z0-9_]+$/)
        return 0
    } else if (flag == "-S") {
      if (val !~ /^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$/)
        return 0
    } else if (flag != "-k")
      return 0
  }
  return 1
}

# Some valid auditctl forms are rejected on purpose because the kit does not use them:
# "-w PATH -F key=X", "-c", and a control flag with its value attached, such as "-f2".
function watch_ok(n, t, i) {
  if (n < 2 || t[2] !~ /^\//)
    return 0
  for (i = 3; i <= n; i += 2) {
    if (i == n)
      return 0
    if (t[i] == "-p") {
      if (t[i + 1] !~ /^[rwxa]+$/)
        return 0
    } else if (t[i] != "-k")
      return 0
  }
  return 1
}

# The control flags come from AKIT_CONTROL_FLAGS in common.sh.
function control_ok(n, t,    nf, f, i, known) {
  nf = split(ENVIRON["AKIT_CONTROL_FLAGS"], f, " ")
  known = 0
  for (i = 1; i <= nf; i++)
    if (t[1] == f[i])
      known = 1
  if (!known)
    return 0
  if (t[1] == "-D")
    return n == 1 || (n == 3 && t[2] == "-k")
  if (t[1] == "-i" || t[1] == "--loginuid-immutable")
    return n == 1
  if (t[1] == "-b" || t[1] == "-r" || t[1] == "--backlog_wait_time")
    return n == 2 && t[2] ~ /^[0-9]+$/
  if (t[1] == "-f" || t[1] == "-e")
    return n == 2 && t[2] ~ /^[012]$/
  return 0
}

/^[ \t]*(#|$)/ { next }

{
  n = split($0, t)
  if (t[1] == "-a" || t[1] == "-A")
    ok = rule_ok(n, t)
  else if (t[1] == "-w")
    ok = watch_ok(n, t)
  else
    ok = control_ok(n, t)
  if (!ok) {
    print FILENAME ":" FNR ": " $0
    bad = 1
  }
}

END { exit bad }
' "$dir"/*.rules
