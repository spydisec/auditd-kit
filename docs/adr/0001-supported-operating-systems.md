# 0001. Supported operating systems for v1

Status: Accepted
Date: 2026-10-19

## Context

Fleets that need audit logging often still run RHEL 5 and 6. RHEL 5 ships Python 2.4 and RHEL 6
ships Python 2.6, and current ansible-core can't manage either. Their auditd versions also reject
rule syntax that newer versions accept. Supporting them would need a second code path and a second
test matrix.

## Decision

v1 supports RHEL 7, 8, and 9, and Ubuntu 22.04 and 24.04. We test RHEL 7 on CentOS 7 and RHEL 8
and 9 on Rocky Linux. RHEL 5 and 6 are left for a later legacy tier that uses static rule files and
the Ansible `raw` module.

## Consequences

RHEL 7 uses Python 2.7, so the collection must work with an ansible-core version that still manages
Python 2.7 targets. CI tests that version and a current one. The survey script must still run on
RHEL 5 and 6, so it's written in plain POSIX shell, and it reports those hosts as unsupported.
