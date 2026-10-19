# 0003. Run a read-only survey before any change

Status: Accepted
Date: 2026-10-19

## Context

Turning on auditd can break things that were already on the host. For example, another security
agent may also read audit events, an existing catch-all syslog forward may start sending audit
volume to a SIEM, or `/var/log/audit` may be on a small filesystem. The people planning a rollout
also need to know what each host runs today.

## Decision

`scripts/survey.sh` reports the state of a host and changes nothing. It covers the OS, auditd and
its rules, disk space, other audit consumers, existing syslog forwarding, time sync, and current
audit volume. Cloud agent checks, e.g. `--check azure`, are opt-in. The `survey.yml` playbook
collects the reports from a fleet into one CSV.

The install path runs a subset of the survey as its preflight. It refuses to change a host when it
finds a blocking condition, unless the operator passes the override for that specific condition.

## Consequences

Every refusal needs a test fixture, and the survey must keep working on hosts we don't support, so
it reports them instead of failing.
