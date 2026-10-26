# 0019. Add RHEL 10

Status: Superseded by 0022
Date: 2026-10-20

## Context

ADR 0001 limited v1 to RHEL 7, 8, and 9, and Ubuntu 22.04 and 24.04. RHEL 10 is the current RHEL
release. It ships audit 4, which keeps the rule syntax and the `rules.d` layout of audit 3, but it
moves `auditctl` and `augenrules` into a separate `audit-rules` package. A minimal install has no
`tar`, which the backup uses. The `service` command, which install uses to restart auditd, is in
`initscripts-service`, and the audit package doesn't pull it in.

## Decision

v1 supports RHEL 7, 8, 9, and 10, and Ubuntu 22.04 and 24.04. We test RHEL 10 on Rocky Linux 10.
Everything else in ADR 0001 stays: RHEL 5 and 6 are left for a later legacy tier.

The `auditd_missing` refusal names the `audit-rules` package. install refuses with `tar_missing`
when `tar` isn't installed, and with `service_missing` when `service` isn't installed, unless
`--skip-load` is set. auditd-kit still never runs a package manager.

## Consequences

CI runs the container install test on Rocky Linux 10 too. The rule files need no change for RHEL
10, because render drops what a host lacks.
