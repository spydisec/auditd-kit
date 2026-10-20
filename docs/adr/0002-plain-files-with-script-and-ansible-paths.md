# 0002. Plain files with a script path and an Ansible path

Status: Accepted
Date: 2026-10-19

## Context

Some hosts are managed by Ansible and some are not. Some networks have no internet access, and
operators often copy a playbook and edit it locally. A design that works only through Ansible
would leave those hosts out.

## Decision

The source of truth is plain files in `rules/` and `config/`, which an operator can read and copy
by hand. Two front ends deploy them:

- `scripts/install.sh`, a POSIX shell script with no dependencies.
- The `auditd` role in the `spydisec.auditd_kit` Ansible collection.

Both follow the same steps and use the same setting names. One script, `scripts/verify.sh`, is the
acceptance test for both. Rule rendering, which drops rules that can't load on a host, is a single
script (`scripts/render.sh`) that both front ends call, because it's the step most likely to
fail across a mixed fleet.

## Consequences

Some logic, e.g. preflight checks, exists in both shell and Ansible. Running `verify.sh` against
both front ends in CI catches the two drifting apart. Each release ships an offline tarball and a
collection tarball, so neither path needs internet access on the target.
