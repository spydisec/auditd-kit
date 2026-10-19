# 0009. Verify with a canary watch rule

Status: Accepted
Date: 2026-10-19

## Context

After a change, `verify.sh` needs to prove that auditd is recording events. It needs an event that
it can create on demand, on every host, in every profile. Immutable mode (`-e 2`) blocks later rule
changes, so verify can't add a rule when it runs.

## Decision

The canary rule is part of `rules/00-base.rules`, so every profile loads it, and it is in place
before any immutable lock:

```
-w /etc/auditd-kit/canary -p wa -k akit_canary
```

Install creates `/etc/auditd-kit/canary`. Verify writes to that file and looks for an event with the
`akit_canary` key.

## Consequences

Every host carries one extra watch rule. The directory `/etc/auditd-kit/` must exist before the
rules load, and install creates it along with the canary file. Verify works the same in every
profile and in immutable mode, and it never changes rules.
