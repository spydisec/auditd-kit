#!/bin/sh
# Build the files of one release: the offline bundle, the collection tarball, and SHA256SUMS.
#
# Usage: build-release.sh <version> <out-dir>
#
# The version is X.Y.Z. It is written into both tarballs, so the repo itself stays at 0.0.0. The
# out dir must be missing or empty.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)

die() {
  printf 'build-release: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 2 ] || die "usage: build-release.sh <version> <out-dir>"
version=$1
out=$2
printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || die "version must be X.Y.Z: $version"
if [ -d "$out" ] && [ -n "$(ls -A "$out")" ]; then
  die "out dir is not empty: $out"
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# stamp <file> <sed expression>: rewrite one version line in place.
stamp() {
  sed "$2" "$1" >"$1.new" && mv "$1.new" "$1"
}

# The offline bundle: what a host needs to run the scripts, without tests or dev tools.
name=auditd-kit-$version
mkdir "$tmp/$name"
cp -R "$repo/rules" "$repo/config" "$repo/scripts" "$repo/README.md" "$repo/LICENSE" "$tmp/$name/"
rm -rf "$tmp/$name/scripts/dev"
stamp "$tmp/$name/scripts/lib/common.sh" "s/^AKIT_VERSION=.*/AKIT_VERSION=$version/"
tar -C "$tmp" -czf "$out/$name.tar.gz" "$name"

# The collection, with the same stamped scripts in its role.
sh "$repo/scripts/dev/sync-collection.sh"
cp -R "$repo/ansible" "$tmp/ansible"
stamp "$tmp/ansible/galaxy.yml" "s/^version: .*/version: $version/"
stamp "$tmp/ansible/roles/auditd/files/scripts/lib/common.sh" "s/^AKIT_VERSION=.*/AKIT_VERSION=$version/"
ansible-galaxy collection build "$tmp/ansible" --output-path "$out" >/dev/null

(cd "$out" && sha256sum ./*.tar.gz | sed 's| \./| |' >SHA256SUMS)
ls "$out"
