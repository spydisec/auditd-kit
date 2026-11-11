# 0028. Install a release with get.sh

Status: Accepted
Date: 2026-11-11

## Context

An operator who tries auditd-kit on one host had to download the bundle, check it, unpack it, and
run `install.sh` by hand. Fleets run the same steps from ssh or a config tool, where nobody can
answer a question, so one script has to work both ways and must never change a host that nobody
approved.

## Decision

Each release ships `scripts/get.sh` next to the bundle. It downloads the bundle and `SHA256SUMS`,
checks the bundle, unpacks it into `/opt/auditd-kit` (or `AKIT_DIR`), and runs that release's
`install.sh`. It runs in one of these modes:

- On a terminal it runs install in guided mode, which asks for the main settings and asks again
  before it changes anything.
- With no terminal it runs only the survey and the plan, and changes nothing.
- With `--yes` it installs with the given settings and asks no questions.

The last line is `result=<outcome> version=X.Y.Z host=<name>`, so a fleet tool can collect one line
per host. `AKIT_VERSION` pins a release, and `AKIT_MIRROR` downloads from a server that the
operator runs, for hosts without internet access.

## Consequences

The checksum comes from the same place as the bundle, so it catches a broken download but not a
changed release. Operators who need more check the bundle with `gh attestation verify` (ADR 0020)
or use a mirror that they control. A change to the install flags must keep `get.sh` working, and
a new outcome must be added to the `result=` line.
