#!/bin/sh
# Build the docs site from the Markdown files in the repo.
#
# Usage: build.sh <out-dir> [get.sh]
#
# The pages are the README, docs/guide.md, docs/integrations/, and rules/README.md. The links
# between them are rewritten for the site, and links to other repo files point to GitHub. With a
# second argument, that file is served as /get.sh.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." >/dev/null && pwd)
blob=https://github.com/spydisec/auditd-kit/blob/main
tree=https://github.com/spydisec/auditd-kit/tree/main

[ $# -ge 1 ] && [ $# -le 2 ] || {
  echo "usage: build.sh <out-dir> [get.sh]" >&2
  exit 1
}
mkdir -p "$1"
out=$(cd "$1" && pwd)

src=$repo/site/.build
rm -rf "$src"
mkdir -p "$src/integrations"

sed -e 's|](docs/adr/)|]('"$tree"'/docs/adr)|g' \
  -e 's|](docs/|](|g' \
  -e 's|](rules/README\.md|](rules.md|g' \
  -e 's|](\([A-Z][A-Z-]*\.md\))|]('"$blob"'/\1)|g' \
  -e 's|](LICENSE)|]('"$blob"'/LICENSE)|g' \
  "$repo/README.md" >"$src/index.md"

sed -e 's|](\.\./rules/README\.md|](rules.md|g' \
  -e 's|](\.\./scripts/|]('"$blob"'/scripts/|g' \
  -e 's|](adr/|]('"$blob"'/docs/adr/|g' \
  "$repo/docs/guide.md" >"$src/guide.md"

cp "$repo/rules/README.md" "$src/rules.md"
cp "$repo"/docs/integrations/*.md "$src/integrations/"

if [ $# -eq 2 ]; then
  cp "$2" "$src/get.sh"
fi

mkdocs build --strict -f "$repo/site/mkdocs.yml" -d "$out"
