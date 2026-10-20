# 0010. Render trims unknown syscalls and strips control lines

Status: Accepted
Date: 2026-10-19

## Context

A rule that names a syscall the kernel doesn't know fails to load. A rule can list several
syscalls, and the syscall tables differ between the audit versions we support, so dropping each
rule that names one unknown syscall would lose coverage on older hosts.

Control lines such as `-D`, `-b`, `-f`, and `-e` in overlay rules would override the settings in
`rules/00-base.rules`, and a `-e 2` would lock the rules. The rules load without `-i`, which tells
auditctl to ignore errors, so one rule that fails stops the whole load. For that reason render must
drop every rule that can't load on the host.

The b32 rules use i386 syscall names. On aarch64 the kernel accepts `arch=b32` as 32-bit ARM,
where those names don't match.

## Decision

`scripts/render.sh` removes each unknown syscall from a rule and drops the rule only when no
syscalls are left. It checks names against `ausyscall <arch> --dump` for b64 rules and
`ausyscall i386 --dump` for b32 rules.

Render strips the control lines `-D`, `-b`, `-f`, `-e`, `-r`, `-i`, `--backlog_wait_time`, and
`--loginuid-immutable` from overlay files. It doesn't strip them from the kit's own rule files.

Render keeps b32 rules on x86_64 only. On other architectures it drops them with the reason
`no_b32`.

Render also drops these rules, each with its reason in the report:

- A `-w` watch whose parent directory is missing (`missing_path`). The kernel accepts a watch on a
  missing file when its parent exists.
- A `-F dir=` rule whose directory is missing (`missing_path`).
- A `-F path=` or `-F exe=` rule whose file is missing (`missing_binary`).
- A `-F path=` or `-F exe=` rule whose file is a symlink (`symlink`). The kernel matches the
  file's inode, and exec and writes reach the link's target, so such a rule never fires. Many
  tools are links on some distros, e.g. `yum` on RHEL 8 and 9, so the rules list the targets too.
- A rule with an SELinux field, such as `-F subj_type=`, when `/sys/fs/selinux/enforce` doesn't
  exist (`no_selinux`). Without a loaded policy these rules can't load.

## Consequences

The render report lists each trimmed syscall and each dropped rule with its reason, so an operator
can see what a host doesn't cover. Hosts that aren't x86_64 have no b32 coverage in v1. Render
needs `ausyscall` on the host, and it refuses to run without it.
