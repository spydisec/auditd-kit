#!/bin/sh
# Report how much audit data a host writes each day, and what writes it.
#
# Usage: stats.sh [--dir DIR] [--top N] [--since EPOCH] [--format text|csv]
#
# Reads audit.log and the rotated audit.log.N files in DIR (default /var/log/audit). Text
# output has one "day=YYYY-MM-DD bytes=<n> events=<n>" line per UTC day, then top_key, top_exe,
# and top_auid lines. CSV output has one host,day,bytes,events row per day and no header. The
# host is AKIT_HOSTNAME when set, else the host name. --since skips events older than the epoch
# seconds (default 0).
#
# A missing or empty DIR prints nothing and exits 0. A bad argument or an unreadable DIR or
# log file exits 1.
set -eu

lib=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)/lib
# shellcheck source=/dev/null
. "$lib/common.sh"

dir=
top=10
since=0
format=text
while [ $# -gt 0 ]; do
  case $1 in
    --dir | --top | --since | --format) ;;
    *) akit_die "$AKIT_EXIT_REFUSED" "stats: unknown argument: $1" ;;
  esac
  [ $# -ge 2 ] || akit_die "$AKIT_EXIT_REFUSED" "stats: $1 needs a value"
  case $1 in
    --dir) dir=$2 ;;
    --top) top=$2 ;;
    --since) since=$2 ;;
    --format) format=$2 ;;
  esac
  shift 2
done

case $top in
  '' | *[!0-9]*) akit_die "$AKIT_EXIT_REFUSED" "stats: --top must be a whole number" ;;
esac
case $since in
  '' | *[!0-9]*) akit_die "$AKIT_EXIT_REFUSED" "stats: --since must be a whole number" ;;
esac
case $format in
  text | csv) ;;
  *) akit_die "$AKIT_EXIT_REFUSED" "stats: --format must be text or csv" ;;
esac

if [ -z "$dir" ]; then
  dir=$(akit_path /var/log/audit)
fi
# A leading ./ keeps awk from reading a file name as an option or as var=value.
case $dir in
  /*) ;;
  *) dir=./$dir ;;
esac

if [ ! -e "$dir" ]; then
  exit 0
fi
if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
  akit_die "$AKIT_EXIT_REFUSED" "stats: cannot read dir: $dir"
fi

tmp=$(mktemp -d) || akit_die "$AKIT_EXIT_REFUSED" "stats: cannot create a temp dir"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

# Rotated logs are audit.log.<digits>; list them highest number (oldest) first.
for f in "$dir"/audit.log.[0-9]*; do
  [ -f "$f" ] || continue
  n=${f##*/audit.log.}
  case $n in
    *[!0-9]*) continue ;;
  esac
  printf '%s %s\n' "$n" "$f"
done | sort -rn -k1,1 >"$tmp/rotated"

set --
while read -r n f; do
  set -- "$@" "$f"
done <"$tmp/rotated"
if [ -f "$dir/audit.log" ]; then
  set -- "$@" "$dir/audit.log"
fi
if [ $# -eq 0 ]; then
  exit 0
fi
for f in "$@"; do
  [ -r "$f" ] || akit_die "$AKIT_EXIT_REFUSED" "stats: cannot read file: $f"
done

awk -v top="$top" -v since="$since" -f "$lib/stats.awk" "$@" >"$tmp/out" \
  || akit_die "$AKIT_EXIT_REFUSED" "stats: awk failed"

if [ "$format" = text ]; then
  cat "$tmp/out"
else
  host=${AKIT_HOSTNAME:-$(hostname 2>/dev/null || uname -n)}
  AKIT_STATS_HOST=$host awk '
    /^day=/ {
      split($1, d, "=")
      split($2, b, "=")
      split($3, e, "=")
      print ENVIRON["AKIT_STATS_HOST"] "," d[2] "," b[2] "," e[2]
    }' "$tmp/out"
fi
