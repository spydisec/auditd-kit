# 0010. Render trims unknown syscalls and strips control lines

Status: Accepted
Date: 2026-10-19

## Context

A rule that names a syscall the kernel doesn't know fails to load. The Neo23x0 rules list several
syscalls in one rule, and the syscall tables differ between the audit versions we support, so
dropping each rule that names one unknown syscall would lose coverage on older hosts.

Control lines such as `-D`, `-b`, `-f`, and `-e` in the standard profile or in extra rules would
override the settings in `rules/base/`, and a `-e 2` would lock the rules. The standard profile
also has `-i`, which tells auditctl to ignore errors. Without `-i`, one rule that fails stops the
whole load, so render must drop every rule that can't load on the host.

The b32 rules use i386 syscall names. On aarch64 the kernel accepts `arch=b32` as 32-bit ARM,
where those names don't match.

## Decision

`scripts/lib/render.sh` removes each unknown syscall from a rule and drops the rule only when no
syscalls are left. It checks names against `ausyscall <arch> --dump` for b64 rules and
`ausyscall i386 --dump` for b32 rules.

Render strips the control lines `-D`, `-b`, `-f`, `-e`, `-i`, `--backlog_wait_time`, and
`--loginuid-immutable` from every file outside `rules/base/`.

Render keeps b32 rules on x86_64 only. On other architectures it drops them with the reason
`no_b32`.

Render also drops these rules, each with its reason in the report:

- A `-w` watch whose parent directory is missing (`missing_path`). The kernel accepts a watch on a
  missing file when its parent exists.
- A `-F dir=` rule whose directory is missing (`missing_path`).
- A `-F path=` or `-F exe=` rule whose file is missing (`missing_binary`).
- A rule with an SELinux field, such as `-F subj_type=`, when `/sys/fs/selinux/enforce` doesn't
  exist (`no_selinux`). Without a loaded policy these rules can't load.

`rules/standard/upstream/audit.rules` stays an unmodified copy, because its SHA-256 is pinned in
`rules/standard/UPSTREAM.md`. Its comments that refer to `-i` no longer describe the rendered
rules.

## Consequences

The render report lists each trimmed syscall and each dropped rule with its reason, so an operator
can see what a host doesn't cover. Hosts that aren't x86_64 have no b32 coverage in v1. Render
needs `ausyscall` on the host, and it refuses to run without it.
