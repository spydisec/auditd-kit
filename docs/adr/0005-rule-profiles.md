# 0005. Rule profiles and upstream rule sources

Status: Accepted
Date: 2026-10-19

## Context

Audit rules decide both what we detect and how much log volume each host produces. Broad rules,
e.g. logging every `execve`, can cost a lot of SIEM ingestion and CPU on busy hosts. Maintained rule
sets already exist, so we don't need to write a full set from scratch.

## Decision

v1 has two profiles:

- `minimal` is the default. It covers identity and authentication changes, sudo, audit tampering,
  time changes, and kernel modules, for both 32-bit and 64-bit syscalls.
- `standard` is the [Neo23x0/auditd](https://github.com/Neo23x0/auditd) rule set (Apache-2.0),
  copied at a pinned commit and recorded in `rules/standard/UPSTREAM.md`.

Site rules go in a separate directory that the operator controls. Rule keys use MITRE ATT&CK
technique names where they map cleanly, e.g. `T1059_Command_and_Scripting_Interpreter`, following
[steveandreassend/linux_auditd](https://github.com/steveandreassend/linux_auditd) (MIT).

## Consequences

Updating `standard` means moving the pinned commit in a PR, and any change that adds log volume
needs a "Volume impact" note in the changelog. A CIS and STIG profile, adapted from
steveandreassend/linux_auditd with 32-bit rules added, is planned after v1. We don't copy code from
GPL-3.0 projects, e.g. certeu/ansible-auditd-laurel, so that our Apache-2.0 licence stays clean.
