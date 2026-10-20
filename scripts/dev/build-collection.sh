#!/bin/sh
# Build the spydisec.auditd_kit collection tarball.
#
# Usage: build-collection.sh [OUT_DIR]   (default: dist/ at the repo root)
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)
out=${1:-$repo/dist}

sh "$repo/scripts/dev/sync-collection.sh"
mkdir -p "$out"
ansible-galaxy collection build "$repo/ansible" --output-path "$out" --force
