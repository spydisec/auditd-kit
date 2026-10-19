#!/bin/sh
# Build this host's audit rules from the kit's rule files.
#
# Usage: render.sh --profile <minimal|standard> --size <small|medium|large>
#          [--extra-dir DIR] [--immutable true|false] --out-dir DIR --report FILE
#
# Writes the rule files to the out dir, writes one report line for each dropped or trimmed
# rule, and prints rule_count=<n>. Exits 0 on success. Exits 1 on bad arguments or any other
# failure, and then leaves the out dir and the report as they were.
#
# The kit's rules/ and config/ dirs must sit two levels above this script's dir (scripts/lib/),
# so any copy of the kit must keep that layout. Host paths are read under AKIT_ROOT.
#
# Test hooks: AKIT_SYSCALLS_B64 and AKIT_SYSCALLS_B32 name files that replace
# "ausyscall <arch> --dump", and AKIT_ARCH replaces "uname -m".
set -eu

lib=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null && pwd)
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

if [ -d "$report" ]; then
  refuse "--report is a directory: $report"
fi

arch=${AKIT_ARCH:-$(uname -m)}

# Everything is built in a temp dir and moved into place only when all steps succeed.
tmp=$(mktemp -d) || refuse "cannot create a temp dir"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
mkdir "$tmp/out"
: >"$tmp/report"

# syscall_table <fixture-file> <ausyscall-arch> <out-file>
syscall_table() {
  if [ -n "$1" ]; then
    [ -r "$1" ] || refuse "cannot read syscall list: $1"
    cat "$1" >"$3" || refuse "cannot read syscall list: $1"
  else
    if ! command -v ausyscall >/dev/null 2>&1; then
      refuse "ausyscall not found, so render can't tell which syscalls this kernel knows. It ships with auditd."
    fi
    ausyscall "$2" --dump >"$3" 2>/dev/null || refuse "ausyscall $2 --dump failed"
  fi
  # Count lines that are a bare name or the "<number> <name>" lines of ausyscall --dump.
  if ! awk 'NF == 1 || (NF == 2 && $1 ~ /^[0-9]+$/) { n++ } END { exit n == 0 }' "$3"; then
    refuse "the $2 syscall table has no names"
  fi
}

# b32 rules use i386 syscall names, so they render only on x86_64.
syscall_table "${AKIT_SYSCALLS_B64:-}" "$arch" "$tmp/b64"
if [ "$arch" = x86_64 ]; then
  syscall_table "${AKIT_SYSCALLS_B32:-}" i386 "$tmp/b32"
  b32_ok=1
else
  : >"$tmp/b32"
  b32_ok=0
fi

# SELinux fields can't match without a loaded policy.
if [ -e "$(akit_path /sys/fs/selinux/enforce)" ]; then
  selinux=1
else
  selinux=0
fi

# The awk program reads paths and labels from the environment, so backslashes stay as they are.
AKIT_RENDER_TMP=$tmp
AKIT_RENDER_ARCH=$arch
export AKIT_RENDER_TMP AKIT_RENDER_ARCH

# rules_file <mode> <file> <label> <output name>: run render.awk on one source file.
rules_file() {
  [ -r "$2" ] || refuse "cannot read rules file: $2"
  if [ "$1" = paths ]; then
    AKIT_RENDER_LABEL=$3 awk -v mode=paths -f "$lib/render.awk" "$2" >>"$tmp/paths" \
      || refuse "cannot process rules file: $2"
  else
    AKIT_RENDER_LABEL=$3 awk -v mode=render -v strip=1 -v b32_ok="$b32_ok" \
      -v selinux="$selinux" -f "$lib/render.awk" "$2" >"$tmp/out/$4" \
      || refuse "cannot process rules file: $2"
  fi
}

# all_sources <mode>: the profile file, then each 50-*.rules file in the extra dir.
all_sources() {
  rules_file "$1" "$kit/$profile_rules" "$profile_rules" "30-auditd-kit-$profile.rules"
  if [ -n "$extra_dir" ]; then
    for f in "$extra_dir"/50-*.rules; do
      [ -f "$f" ] || continue
      rules_file "$1" "$f" "$f" "$(basename "$f")"
    done
  fi
}

# List the host paths that rules depend on, and keep the ones missing under AKIT_ROOT.
: >"$tmp/paths"
all_sources paths
sort -u "$tmp/paths" | while IFS= read -r p; do
  [ -e "$(akit_path "$p")" ] || printf '%s\n' "$p"
done >"$tmp/missing" || refuse "cannot check rule paths"

{
  echo "# Rendered by auditd-kit from rules/base/00-init.rules. Do not edit."
  sed "s/@AKIT_BACKLOG@/$backlog/" "$kit/rules/base/00-init.rules"
} >"$tmp/out/00-auditd-kit-init.rules" || refuse "cannot render rules/base/00-init.rules"

all_sources render

if [ "$immutable" = true ]; then
  {
    echo "# Rendered by auditd-kit from rules/base/99-finalize.rules. Do not edit."
    cat "$kit/rules/base/99-finalize.rules"
  } >"$tmp/out/99-auditd-kit-finalize.rules" || refuse "cannot render rules/base/99-finalize.rules"
fi

count=$(awk '/^[ \t]*-[aAw][ \t]/ { n++ } END { print n + 0 }' "$tmp/out"/*.rules) \
  || refuse "cannot count rendered rules"

# Write the report first, then the rules. If the rules can't be written, remove both.
if ! { mkdir -p "$(dirname "$report")" && cp "$tmp/report" "$report"; }; then
  refuse "cannot write report: $report"
fi
if [ -d "$out_dir" ]; then
  out_existed=1
else
  out_existed=0
fi
if ! { mkdir -p "$out_dir" && cp "$tmp/out"/*.rules "$out_dir"/; }; then
  rm -f "$report"
  # The out dir was empty or missing before, so every file in it is ours.
  if [ "$out_existed" -eq 1 ]; then
    rm -f "$out_dir"/*.rules
  else
    rm -rf "$out_dir"
  fi
  refuse "cannot write rules to: $out_dir"
fi

echo "rule_count=$count"
