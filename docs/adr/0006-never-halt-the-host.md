# 0006. Never halt the host when the audit disk fills

Status: Accepted
Date: 2026-10-19

## Context

auditd can halt the host or drop it to single-user mode when its disk fills. Some compliance
standards ask for that, but for most fleets an outage costs more than a gap in local audit logs.
Rule changes also need care, because immutable mode (`-e 2`) means every later rule change needs a
reboot.

## Decision

The default `auditd.conf` presets set `admin_space_left_action` and `disk_full_action` to `SUSPEND`.
auditd then stops writing local logs, and the host keeps running. Failures go to syslog (`-f 1`),
not to a kernel panic. Immutable mode is off by default and is turned on with `akit_immutable`.
auditd-kit doesn't change kernel boot parameters.

## Consequences

When the disk fills, events are lost until space is freed. `docs/risks.md` explains the trade-off,
and operators who must meet a stricter standard can override the actions. The sizing guide helps
operators size `/var/log/audit` so that the disk rarely fills.
