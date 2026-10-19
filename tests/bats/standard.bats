#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
std="$repo/rules/standard"

upstream_value() {
  sed -n "s/^$1: //p" "$std/UPSTREAM.md" | head -n 1
}

@test "vendored file matches the sha256 in UPSTREAM.md" {
  want=$(upstream_value sha256)
  [ -n "$want" ]
  got=$(sha256sum "$std/upstream/audit.rules" | cut -d' ' -f1)
  [ "$got" = "$want" ]
}

@test "UPSTREAM.md pins a full commit SHA" {
  commit=$(upstream_value commit)
  printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$'
}

@test "UPSTREAM.md names the upstream repo and file" {
  [ "$(upstream_value repo)" = "https://github.com/Neo23x0/auditd" ]
  [ "$(upstream_value file)" = "audit.rules" ]
}

@test "standard LICENSE is the Apache-2.0 text" {
  grep -q 'Apache License' "$std/LICENSE"
  grep -q 'Version 2.0, January 2004' "$std/LICENSE"
}

@test "update-standard.sh refuses a commit that is not 40 hex characters" {
  run sh "$repo/scripts/dev/update-standard.sh" master
  [ "$status" -ne 0 ]
  run sh "$repo/scripts/dev/update-standard.sh" abc123
  [ "$status" -ne 0 ]
  run sh "$repo/scripts/dev/update-standard.sh"
  [ "$status" -ne 0 ]
}

@test "UPSTREAM.md names the licence" {
  [ "$(upstream_value licence)" = "Apache-2.0" ]
}
