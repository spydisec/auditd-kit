#!/bin/sh
# Developer tool: rebuild tests/fixtures/syscalls from the audit-userspace syscall tables.
# Usage: sh scripts/dev/update-syscall-fixtures.sh
set -eu
LC_ALL=C
export LC_ALL

raw_url=https://raw.githubusercontent.com/linux-audit/audit-userspace

root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/tests/fixtures/syscalls"
mkdir -p "$out"

# Each line is a fixture name and the audit-userspace tag for the audit version that OS ships.
pins='centos7 v2.8.5
rocky8 v3.1.2
rocky9 v3.1.5
ubuntu2204 v3.0.7
ubuntu2404 v3.1.2'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Print the syscall names from a table header, one per line, in table order.
names() {
  sed -n 's/^_S([0-9]*, *"\([a-z0-9_]*\)").*/\1/p' "$1"
}

printf '%s\n' "$pins" | while read -r os tag; do
  curl -fsSL "$raw_url/$tag/lib/x86_64_table.h" -o "$tmp/b64.h"
  curl -fsSL "$raw_url/$tag/lib/i386_table.h" -o "$tmp/b32.h"
  names "$tmp/b64.h" >"$out/$os-b64.txt"
  names "$tmp/b32.h" >"$out/$os-b32.txt"
  if [ ! -s "$out/$os-b64.txt" ] || [ ! -s "$out/$os-b32.txt" ]; then
    echo "error: no syscall names found for $os at $tag" >&2
    exit 1
  fi
done

{
  cat <<'EOT'
# Syscall fixtures

Each file lists the syscall names that `ausyscall --dump` knows on one OS, one name per line.
`<os>-b64.txt` stands in for `ausyscall x86_64 --dump` and `<os>-b32.txt` for
`ausyscall i386 --dump`. The names come from `lib/x86_64_table.h` and `lib/i386_table.h` in
linux-audit/audit-userspace, at the tag for the audit version that OS ships.

| Fixture | audit-userspace tag |
|---|---|
EOT
  printf '%s\n' "$pins" | while read -r os tag; do
    echo "| $os | $tag |"
  done
  cat <<'EOT'

To rebuild the files, run `sh scripts/dev/update-syscall-fixtures.sh` and commit the result.
EOT
} >"$out/README.md"

echo "wrote syscall fixtures to $out"
