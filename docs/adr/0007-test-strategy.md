# 0007. Test strategy

Status: Superseded by 0021
Date: 2026-10-19

## Context

Containers share the host kernel's audit subsystem, so they can't load audit rules. Real RHEL
family kernels need virtual machines, and the main development machine runs Ubuntu.

## Decision

Tests run in layers:

1. Static checks run on every PR, using shellcheck in POSIX mode, shfmt, ansible-lint, and
   yamllint.
2. Unit tests run with bats-core on every PR. Scripts accept an `AKIT_ROOT` prefix, so tests can run
   them against fixture filesystems without root.
3. Molecule runs the role in Docker on CentOS 7, Rocky 8 and 9, and Ubuntu 22.04 and 24.04 on every
   PR. It checks convergence, a second run with no changes, and check mode, and it skips the rule
   load.
4. GitHub's Ubuntu runners are virtual machines, so they run a full install and `verify.sh` with a
   real rule load on every PR.
5. `tests/vm/run.sh` runs both front ends on Incus virtual machines (CentOS 7, Rocky 8 and 9) on a
   developer machine before each release.
6. Semgrep, gitleaks, and zizmor run on every PR and weekly. Actions are pinned to commit SHAs, and
   Dependabot keeps them updated.

## Consequences

The RHEL family rule load is tested only before a release, unless GitHub's runners turn out to
support KVM, in which case it can run nightly. A release PR must include the output of the virtual
machine tests.
