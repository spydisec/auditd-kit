# auditd-kit

auditd-kit turns on Linux audit logging (auditd) across a fleet with safe defaults. It ships plain
rule and config files, POSIX shell scripts, and an Ansible collection.

## Public repository rules

The repository is public. Never commit any of the following:

- Client names, hostnames, IP addresses, workspace IDs, or any other site details. Examples use
  `example.com` and RFC 5737 addresses.
- Design specs, plans, or notes from conversations. Keep them in `docs/design/`, which git ignores.
- Secrets or credentials.

Record a decision that other people need to know as an ADR in `docs/adr/`. See
`docs/adr/README.md` for the format.

## Writing style

Use the `plain-writing` skill (`.claude/skills/plain-writing/SKILL.md`) for all prose, including
docs, ADRs, comments, commit messages, and PR descriptions.

## Workflow

- Work on a short-lived branch named `feat/`, `fix/`, `docs/`, `ci/`, or `chore/`.
- Open a PR into `main`, and give it a Conventional Commits title, e.g. `feat: add survey script`.
- `main` takes squash merges only, after the required checks pass.
- Never push to `main` directly.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `spydisec/auditd-kit` (via the `gh` CLI); external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily). See `docs/agents/domain.md`.
