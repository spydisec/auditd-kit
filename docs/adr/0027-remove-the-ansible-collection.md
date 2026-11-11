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
0012, 0015, 0016, 0020, 0021, and 0022.

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:207c4892ac6a3e29686916bf1f66acabe142ac165c593c3f83f31f8c0933205b -->

The remaining decisions in the superseded ADRs still apply, subject to changes in later ADRs:

- 0012: settings in `site.conf`, flags, validation, precedence, and exit codes.
- 0020: the branch and release workflow, versioning, checksums, and attestations.
- 0021: test selection from changed files, the remaining test groups, and security checks.
- 0022: supported operating systems and container and kernel tests. Test Ubuntu 18.04 and 20.04
  on a VM before releases that change rule syntax.

The Molecule test layer from ADR 0007 no longer applies.

<!-- /coderabbit-ai-generated:v1 -->

## Consequences

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:c76a7dfc5d9b883143e6152ef8425dcc55446838bab91193dd4f630c46397ea1 -->

A release ships the offline bundle, `get.sh`, and `SHA256SUMS`. An operator who uses Ansible must
copy and extract the bundle on each host, then run `install.sh`, `survey.sh`, or `stats.sh` from
its `scripts/` directory with `ansible.builtin.command`. The scripts need the libraries in the
extracted bundle and print `key=value` lines that a playbook can collect.

<!-- /coderabbit-ai-generated:v1 -->

If a role comes back, it needs a new ADR and install tasks before it ships.
