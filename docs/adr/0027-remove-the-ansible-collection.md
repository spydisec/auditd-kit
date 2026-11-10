# 0027. Remove the Ansible collection

Status: Accepted
Date: 2026-11-10

## Context

ADR 0002 planned two ways to deploy the files, `scripts/install.sh` and an `auditd` role in the
`spydisec.auditd_kit` collection. The role never got install tasks. Through v0.3.1 a plain role
call stopped with an error, and the collection only ran the survey and stats scripts on each
host and gathered their output into CSV files.

Keeping the collection cost a Molecule job with two ansible-core versions, ansible-lint, a build
step in each release, and four ADRs (0002, 0015, 0016, and parts of 0007) that described a role
that didn't exist. The docs audit in November 2026 found that the ADRs and the collection README
read as if the role could install.

## Decision

Remove the collection. `scripts/install.sh` is the only front end, and the plain files in
`rules/` and `config/` stay the source of truth, as ADR 0002 says. This ADR supersedes 0002,
0015, and 0016.

These parts of other ADRs no longer apply:

- 0007: the Molecule test layer.
- 0012: the Ansible variable names. The settings keep the same names in `site.conf`.
- 0020 and 0008: the collection tarball in a release.
- 0021: the Ansible and Molecule rows of the routing table.
- 0022: the Molecule bullet.

## Consequences

A release ships the offline bundle, `get.sh`, and `SHA256SUMS`. An operator who uses Ansible can
copy the bundle to each host and run `install.sh`, `survey.sh`, or `stats.sh` with
`ansible.builtin.script` or `ansible.builtin.command`. The scripts print `key=value` lines, so a
playbook can still collect the results.

If a role comes back, it needs a new ADR and install tasks before it ships.
