# Contributing

Thank you for helping with auditd-kit. This page explains how changes are made and what a pull request needs.

## Branches and pull requests

Work on a short-lived branch whose name starts with `feat/`, `fix/`, `docs/`, `ci/`, or `chore/`, and open a
pull request into `main`. Never push to `main` directly. Give the pull request a Conventional Commits title,
e.g. `feat: add survey script`, because the title becomes the commit message when the pull request is squash
merged. The `main` branch takes squash merges only, after the required checks pass. The ruleset that enforces
this is stored in `.github/rulesets/main.json`, and it is active on `main`.

## Checks to run before you push

Run `sh tests/lint.sh` for the linters, and run `bats tests/bats` for the tests. The
lint script needs shellcheck, shfmt, and yamllint on your path, and `tests/requirements.txt` lists the Python
tools.

PRs run test groups selected by changed paths and file extensions. Security scans run on every
PR, and pushes to `main` run the full suite. See [ADR 0021](docs/adr/0021-select-tests-from-changed-files.md)
for the groups. Changes to the routing rules must include tests in `tests/bats/ci-changes.bats`.

## Public repository rules

This repository is public, so a change must not contain any of the following.

- Client names, hostnames, IP addresses, workspace IDs, or any other site details. Examples use `example.com`
  and the RFC 5737 addresses `192.0.2.0/24`, `198.51.100.0/24`, and `203.0.113.0/24`.
- Design specs, plans, or notes from conversations. Local notes belong in `docs/design/`, which git ignores.
- Secrets or credentials.

## Decisions

When a decision matters to other people, record it as an architecture decision record in `docs/adr/`. Each
record is one numbered file with a context, a decision, and consequences. The format is in `docs/adr/README.md`.
To change an earlier decision, write a new record and mark the old one as superseded.

## Writing style

Write prose in plain words and complete sentences. Don't use em dashes, en dashes, or curly quotes, write
headings in sentence case, and keep code comments sparse. The rules are in
`.claude/skills/plain-writing/SKILL.md`.

## Licence

By contributing, you agree that your work is released under the Apache-2.0 licence in `LICENSE`.
