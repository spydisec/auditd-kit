# 0009. Verify with a canary watch rule

Status: Accepted
Date: 2026-10-19

## Context

After a change, `verify.sh` needs to prove that auditd is recording events. It needs an event that
it can create on demand, on every host, in every profile. Immutable mode (`-e 2`) blocks later rule
changes, so verify can't add a rule when it runs.

## Decision

The canary rule is part of `rules/base/00-init.rules`, so every profile loads it, and it is in place
before any immutable lock:

```
-w /etc/auditd-kit/canary -p wa -k akit_canary
```

Install creates `/etc/auditd-kit/canary`. Verify writes to that file and looks for an event with the
`akit_canary` key.

## Consequences

Every host carries one extra watch rule. The canary file must exist before render runs, because
some auditd versions refuse to load a watch on a path that is missing. Verify works the same in the minimal and
standard profiles and in immutable mode, and it never changes rules.
