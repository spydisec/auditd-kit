# 0010. Render trims unknown syscalls and strips control lines

Status: Accepted
Date: 2026-10-19

## Context

A rule that names a syscall the kernel doesn't know fails to load. The Neo23x0 rules list several
syscalls in one rule, and the syscall tables differ between the audit versions we support, so
dropping each rule that names one unknown syscall would lose coverage on older hosts. Control lines
such as `-D`, `-b`, `-f`, `-e`, and `-i` in the standard profile or in extra rules would override
the settings in `rules/base/`, and a `-e 2` would lock the rules. The kernel accepts b32 rules only
on architectures that run 32-bit code, and among our targets that is x86_64.

## Decision

`scripts/lib/render.sh` removes each unknown syscall from a rule and drops the rule only when no
syscalls are left. It checks names against `ausyscall <arch> --dump` for b64 rules and
`ausyscall i386 --dump` for b32 rules.

Render strips the control lines `-D`, `-b`, `-f`, `-e`, `-i`, `--backlog_wait_time`, and
`--loginuid-immutable` from every file outside `rules/base/`.

Render keeps b32 rules on x86_64 only. On other architectures it drops them with the reason
`no_b32`.

Render also drops rules that can't load because a path is missing. A `-w` watch is dropped when the
watched path's parent directory is missing, because the kernel accepts a watch on a missing file
when its parent exists. A `-F dir=` rule is dropped when the directory is missing, and a `-F path=`
or `-F exe=` rule is dropped when the file is missing.

## Consequences

The render report lists each trimmed syscall and each dropped rule with its reason, so an operator
can see what a host doesn't cover. Hosts that aren't x86_64 have no b32 coverage in v1. Render
needs `ausyscall` on the host, and it refuses to run without it.
