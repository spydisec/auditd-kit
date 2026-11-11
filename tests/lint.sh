#!/bin/sh
# Run every linter that has files to check. Exits non-zero if any tool fails.
set -eu
LC_ALL=C
export LC_ALL

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

find_files() {
  find . \( -name .git -o -name .venv -o -name .superpowers -o -name design \) -prune -o \
    -type f "$@" -print | sort
}

# Shell files: *.sh, plus extensionless files under scripts/ and tests/ with an sh shebang.
find_files -name '*.sh' >"$tmp/sh"
for dir in scripts tests; do
  [ -d "$dir" ] || continue
  find "$dir" -type f ! -name '*.*' | while read -r f; do
    if head -n 1 "$f" | grep -Eq '^#![[:space:]]*/[^ ]*(/|[[:space:]])sh([[:space:]]|$)'; then
      echo "./$f"
    fi
  done >>"$tmp/sh"
done
sort -u "$tmp/sh" -o "$tmp/sh"
find_files -name '*.bats' >"$tmp/bats"
find_files -name '*.bash' >"$tmp/bash"

status=0
run() {
  echo "+ $*"
  "$@" || status=1
}

if [ -s "$tmp/sh" ]; then
  xargs shellcheck -s sh <"$tmp/sh" || status=1
  xargs shfmt -d <"$tmp/sh" || status=1
else
  echo "no sh files, skipping shellcheck and shfmt"
fi
if [ -s "$tmp/bats" ]; then
  xargs shellcheck -s bats <"$tmp/bats" || status=1
fi
if [ -s "$tmp/bash" ]; then
  xargs shellcheck -s bash <"$tmp/bash" || status=1
fi

# The yamllint settings are given here, so the repo needs no .yamllint.yml file.
run yamllint -s -d '{
  extends: default,
  ignore: [.venv/, .superpowers/, docs/design/],
  rules: {line-length: {max: 120}, truthy: {check-keys: false}}
}' .

exit "$status"
