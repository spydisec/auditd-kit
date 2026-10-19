#!/bin/sh
# Build this host's audit rules from the kit's rule files.
#
# Usage: render.sh --profile <minimal|standard> --size <small|medium|large>
#          [--extra-dir DIR] [--immutable true|false] --out-dir DIR --report FILE
#
# Writes the rule files to the out dir, writes one report line for each dropped or trimmed
# rule, and prints rule_count=<n>. Exits 0 on success and 1 on bad arguments.
#
# Test hooks: AKIT_SYSCALLS_B64 and AKIT_SYSCALLS_B32 name files that replace
# "ausyscall <arch> --dump", and AKIT_ARCH replaces "uname -m".
set -eu

lib=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$lib/common.sh"
kit=$(cd "$lib/../.." && pwd)

refuse() {
  akit_die "$AKIT_EXIT_REFUSED" "render: $1"
}

profile=
size=
extra_dir=
immutable=false
out_dir=
report=
while [ $# -gt 0 ]; do
  case $1 in
    --profile | --size | --extra-dir | --immutable | --out-dir | --report) ;;
    *) refuse "unknown argument: $1" ;;
  esac
  [ $# -ge 2 ] || refuse "$1 needs a value"
  case $1 in
    --profile) profile=$2 ;;
    --size) size=$2 ;;
    --extra-dir) extra_dir=$2 ;;
    --immutable) immutable=$2 ;;
    --out-dir) out_dir=$2 ;;
    --report) report=$2 ;;
  esac
  shift 2
done

case $profile in
  minimal) profile_rules="rules/minimal/30-minimal.rules" ;;
  standard) profile_rules="rules/standard/upstream/audit.rules" ;;
  *) refuse "--profile must be minimal or standard" ;;
esac
case $size in
  small | medium | large) ;;
  *) refuse "--size must be small, medium, or large" ;;
esac
case $immutable in
  true | false) ;;
  *) refuse "--immutable must be true or false" ;;
esac
[ -n "$out_dir" ] || refuse "--out-dir is required"
[ -n "$report" ] || refuse "--report is required"
if [ -n "$extra_dir" ] && [ ! -d "$extra_dir" ]; then
  refuse "extra rules dir not found: $extra_dir"
fi
if [ -d "$out_dir" ] && [ -n "$(ls -A "$out_dir")" ]; then
  refuse "out dir is not empty: $out_dir"
fi

for f in rules/base/00-init.rules rules/base/99-finalize.rules "$profile_rules" \
  "config/auditd/$size.conf"; do
  [ -f "$kit/$f" ] || refuse "kit file not found: $kit/$f"
done

backlog=$(sed -n 's/^# akit_backlog = \([0-9][0-9]*\)$/\1/p' "$kit/config/auditd/$size.conf")
[ -n "$backlog" ] || refuse "no akit_backlog line in config/auditd/$size.conf"

arch=${AKIT_ARCH:-$(uname -m)}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

# syscall_table <fixture-file> <ausyscall-arch> <out-file>
syscall_table() {
  if [ -n "$1" ]; then
    [ -r "$1" ] || refuse "cannot read syscall list: $1"
    cat "$1" >"$3"
    return
  fi
  if ! command -v ausyscall >/dev/null 2>&1; then
    refuse "ausyscall not found, so render can't tell which syscalls this kernel knows. It ships with auditd."
  fi
  ausyscall "$2" --dump >"$3" 2>/dev/null || refuse "ausyscall $2 --dump failed"
}

# b32 rules load only on x86_64, where the kernel also runs i386 code.
syscall_table "${AKIT_SYSCALLS_B64:-}" "$arch" "$tmp/b64"
if [ "$arch" = x86_64 ]; then
  syscall_table "${AKIT_SYSCALLS_B32:-}" i386 "$tmp/b32"
  b32_ok=1
else
  : >"$tmp/b32"
  b32_ok=0
fi

# Each source is "<file>|<label>|<output name>". The label names the file in the report.
printf '%s|%s|%s\n' "$kit/$profile_rules" "$profile_rules" "30-auditd-kit-$profile.rules" \
  >"$tmp/sources"
if [ -n "$extra_dir" ]; then
  for f in "$extra_dir"/50-*.rules; do
    [ -f "$f" ] || continue
    printf '%s|%s|%s\n' "$f" "$f" "$(basename "$f")" >>"$tmp/sources"
  done
fi

# List the host paths that rules depend on, and keep the ones missing under AKIT_ROOT.
while IFS='|' read -r src label name; do
  awk -v mode=paths -f "$lib/render.awk" "$src"
done <"$tmp/sources" | sort -u | while IFS= read -r p; do
  [ -e "$(akit_path "$p")" ] || printf '%s\n' "$p"
done >"$tmp/missing"

mkdir -p "$out_dir" "$(dirname "$report")"
: >"$report"

{
  echo "# Rendered by auditd-kit from rules/base/00-init.rules. Do not edit."
  sed "s/@AKIT_BACKLOG@/$backlog/" "$kit/rules/base/00-init.rules"
} >"$out_dir/00-auditd-kit-init.rules"

while IFS='|' read -r src label name; do
  awk -v mode=render -v label="$label" -v strip=1 -v b32_ok="$b32_ok" -v arch="$arch" \
    -v b64_file="$tmp/b64" -v b32_file="$tmp/b32" -v missing_file="$tmp/missing" \
    -v report="$report" -f "$lib/render.awk" "$src" >"$out_dir/$name"
done <"$tmp/sources"

if [ "$immutable" = true ]; then
  {
    echo "# Rendered by auditd-kit from rules/base/99-finalize.rules. Do not edit."
    cat "$kit/rules/base/99-finalize.rules"
  } >"$out_dir/99-auditd-kit-finalize.rules"
fi

count=$(awk '/^-[aAw] / { n++ } END { print n + 0 }' "$out_dir"/*.rules)
echo "rule_count=$count"
