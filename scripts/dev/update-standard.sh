#!/bin/sh
# Developer tool: pin rules/standard to a commit of Neo23x0/auditd.
# Usage: sh scripts/dev/update-standard.sh <40-hex-commit>
set -eu
LC_ALL=C
export LC_ALL

repo_url=https://github.com/Neo23x0/auditd
raw_url=https://raw.githubusercontent.com/Neo23x0/auditd

if [ $# -ne 1 ]; then
  echo "usage: $0 <commit>" >&2
  exit 1
fi
commit=$1
if ! printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "error: commit must be 40 lowercase hex characters" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
std="$root/rules/standard"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$raw_url/$commit/audit.rules" -o "$tmp/audit.rules"
curl -fsSL "$raw_url/$commit/LICENSE" -o "$tmp/LICENSE"

if ! grep -q 'Apache License' "$tmp/LICENSE" || ! grep -q 'Version 2.0, January 2004' "$tmp/LICENSE"; then
  echo "error: upstream LICENSE is not Apache-2.0" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum=$(sha256sum "$tmp/audit.rules" | cut -d' ' -f1)
else
  sum=$(shasum -a 256 "$tmp/audit.rules" | cut -d' ' -f1)
fi

mkdir -p "$std/upstream"
cp "$tmp/audit.rules" "$std/upstream/audit.rules"
cp "$tmp/LICENSE" "$std/LICENSE"

cat >"$std/UPSTREAM.md" <<EOT
repo: $repo_url
commit: $commit
file: audit.rules
sha256: $sum
licence: Apache-2.0

upstream/audit.rules is an unmodified copy of audit.rules at that commit, and render strips its control lines.

To update the pin, run \`sh scripts/dev/update-standard.sh <commit>\` and commit the result.
The pull request must add a "Volume impact" note to the changelog, because new upstream
rules can change how many events a host writes.
EOT

echo "pinned rules/standard to $commit"
