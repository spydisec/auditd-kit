#!/bin/sh
# Copy rules/, config/, and scripts/ (without scripts/dev/) into the role's files/ dir, so the
# collection ships the same files as the script path. Run it before ansible-lint, Molecule, or a
# build. The copy is git-ignored.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)
files=$repo/ansible/roles/auditd/files

rm -rf "$files"
mkdir -p "$files"
cp -R "$repo/rules" "$repo/config" "$repo/scripts" "$files/"
rm -rf "$files/scripts/dev"
