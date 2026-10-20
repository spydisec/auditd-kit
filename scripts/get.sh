#!/bin/sh
# Download an auditd-kit release, check it, and run its install.sh.
#
# Usage: curl -fsSL https://github.com/spydisec/auditd-kit/releases/latest/download/get.sh | sudo sh
#        ... | sudo sh -s -- [--yes] [install.sh arguments]
#
# On a terminal, install runs in guided mode and asks before it changes anything. With no
# terminal, as from ssh or a config tool, it only prints the survey and the plan. --yes runs
# install with the given settings and no questions. The last line is a result line for the host:
#   result=<installed|unchanged|planned|cancelled|refused|rolled_back|rollback_failed> version=X.Y.Z host=<name>
#
# AKIT_VERSION=X.Y.Z picks a release instead of the latest one. AKIT_MIRROR is a URL to download
# from instead of GitHub, e.g. a dir on your own web server that holds one release's
# auditd-kit-<version>.tar.gz and SHA256SUMS. AKIT_DIR is where releases are unpacked (default
# /opt/auditd-kit) and must be owned by root. The bundle is checked against SHA256SUMS before
# anything runs. That catches a broken download. Both files come from the same place, so use a
# mirror that you control.
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
  case "$get_base" in
    https://* | file://*) ;;
    *) die "AKIT_MIRROR must be an https:// or file:// URL" ;;
  esac
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
# Root runs what is unpacked here, so the dir must be root's, and an old copy of this version is
# replaced, not added to.
[ "$(stat -c %u "$get_dir")" = 0 ] || die "$get_dir must be owned by root"
rm -rf "${get_dir:?}/auditd-kit-$get_version"
tar -xzf "$get_tmp/$get_name" -C "$get_dir" || die "cannot unpack $get_name into $get_dir"
printf 'auditd-kit get: %s is in %s/auditd-kit-%s\n' "$get_version" "$get_dir" "$get_version" >&2

# Take --yes out of the arguments, then pick the mode. An explicit --dry-run only plans.
get_yes=no
get_dry=no
get_n=$#
while [ "$get_n" -gt 0 ]; do
  get_a=$1
  shift
  get_n=$((get_n - 1))
  if [ "$get_a" = --yes ]; then
    get_yes=yes
  else
    [ "$get_a" != --dry-run ] || get_dry=yes
    set -- "$@" "$get_a"
  fi
done
get_mode=apply
if [ "$get_dry" = yes ]; then
  get_mode=plan
elif [ "$get_yes" = no ]; then
  if (: </dev/tty) 2>/dev/null; then
    get_mode=guided
    set -- --guided "$@"
  else
    get_mode=plan
    set -- --dry-run "$@"
  fi
fi

# Run install, keep its output for the result line, and keep its exit code.
{ sh "$get_dir/auditd-kit-$get_version/scripts/install.sh" "$@" || echo "$?" >"$get_tmp/rc"; } \
  | tee "$get_tmp/out"
get_rc=$(cat "$get_tmp/rc" 2>/dev/null || echo 0)
get_changes=$(sed -n 's/^changes=//p' "$get_tmp/out" | tail -n 1)
case "$get_rc" in
  0)
    if [ "$get_mode" = plan ]; then
      get_result=planned
    elif grep -qx cancelled "$get_tmp/out"; then
      get_result=cancelled
    elif [ "$get_changes" = 0 ]; then
      get_result=unchanged
    else
      get_result=installed
    fi
    ;;
  1) get_result=refused ;;
  2) get_result=rolled_back ;;
  *) get_result=rollback_failed ;;
esac
get_codes=$(sed -n 's/^refuse=\([^ ]*\).*/\1/p' "$get_tmp/out" | paste -sd, -)
printf 'result=%s version=%s host=%s%s\n' "$get_result" "$get_version" "$(uname -n)" "${get_codes:+ codes=$get_codes}"
exit "$get_rc"
