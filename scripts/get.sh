#!/bin/sh
# Download an auditd-kit release, check it, and run its install.sh.
#
# Usage: curl -fsSL https://github.com/spydisec/auditd-kit/releases/latest/download/get.sh | sudo sh
#        ... | sudo sh -s -- <install.sh arguments>
#
# AKIT_VERSION=X.Y.Z picks a release instead of the latest one. AKIT_MIRROR is a URL to download
# from instead of GitHub, e.g. a dir on your own web server that holds one release's
# auditd-kit-<version>.tar.gz and SHA256SUMS. AKIT_DIR is where releases are unpacked (default
# /opt/auditd-kit). The bundle is checked against SHA256SUMS before anything runs.
#
# Exits 1 when it can't download or check the release, and otherwise with install.sh's exit code.
set -eu

die() {
  printf 'auditd-kit get: %s\n' "$1" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run it as root, e.g. with sudo"
for get_tool in tar sha256sum; do
  command -v "$get_tool" >/dev/null 2>&1 || die "$get_tool not found. Install it and try again."
done

if [ -n "${AKIT_MIRROR:-}" ]; then
  get_base=${AKIT_MIRROR%/}
elif [ -n "${AKIT_VERSION:-}" ]; then
  get_base="https://github.com/spydisec/auditd-kit/releases/download/v$AKIT_VERSION"
else
  get_base="https://github.com/spydisec/auditd-kit/releases/latest/download"
fi

# fetch <url> <file>
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --proto '=https,file' -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  die "curl or wget not found. Install one, or copy a release bundle to the host by hand."
fi

get_tmp=$(mktemp -d) || die "cannot create a temp dir"
trap 'rm -rf "$get_tmp"' EXIT

fetch "$get_base/SHA256SUMS" "$get_tmp/SHA256SUMS" || die "cannot download $get_base/SHA256SUMS"
get_line=$(grep -E '^[0-9a-f]{64}  auditd-kit-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' "$get_tmp/SHA256SUMS" | head -n 1) \
  || die "SHA256SUMS at $get_base lists no auditd-kit bundle"
get_name=${get_line##* }
get_version=${get_name#auditd-kit-}
get_version=${get_version%.tar.gz}
if [ -n "${AKIT_VERSION:-}" ] && [ "$get_version" != "$AKIT_VERSION" ]; then
  die "asked for $AKIT_VERSION, but $get_base has $get_version"
fi

fetch "$get_base/$get_name" "$get_tmp/$get_name" || die "cannot download $get_base/$get_name"
printf '%s\n' "$get_line" >"$get_tmp/sum"
(cd "$get_tmp" && sha256sum -c sum >/dev/null 2>&1) || die "$get_name doesn't match SHA256SUMS, so nothing ran"

get_dir=${AKIT_DIR:-/opt/auditd-kit}
mkdir -p "$get_dir" || die "cannot create $get_dir"
tar -xzf "$get_tmp/$get_name" -C "$get_dir" || die "cannot unpack $get_name into $get_dir"
printf 'auditd-kit get: %s is in %s/auditd-kit-%s\n' "$get_version" "$get_dir" "$get_version" >&2

rm -rf "$get_tmp"
trap - EXIT
exec sh "$get_dir/auditd-kit-$get_version/scripts/install.sh" "$@"
