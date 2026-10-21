# 0021. Select tests from changed files

Status: Accepted
Date: 2026-10-21

## Context

Every PR runs the full test suite, even when only documentation changes. Workflow path filters
can leave required checks pending, so they cannot replace the existing required jobs.

## Decision

This replaces the every-PR test selection in ADR 0007. Its test layers still apply.

PRs select test groups through `scripts/dev/ci-changes.bash`. It reads the complete Git diff
as NUL-delimited paths, including deleted paths and both sides of renames. Directory rules
select the owning tests. Shell, AWK, rule, configuration, and template extensions outside known
directories select the full suite. Other YAML files select lint. Unknown files select the full suite.

| Changes | Tests |
|---|---|
| Ordinary Markdown | No runtime tests |
| Root README, licence, Ansible Markdown | Collection and release packaging |
| Rules README | Rules content tests and packaging |
| Runtime scripts, rules, configuration | Full suite |
| Ansible files | Lint, Molecule, packaging |
| Bats tests and fixtures | Lint, Bats, portability |
| Kernel or container test scripts | Lint, kernel and container matrices |
| Molecule files | Lint and Molecule |
| Development scripts | Lint, Bats, portability, packaging, Molecule |
| Workflow or routing changes | Full suite |
| Linter settings and tool requirements | Lint |

Semgrep, Gitleaks, and Zizmor still run on every PR and weekly. PR-title validation is unchanged.
Pushes to `main` run the full suite. Packaging tests install Ansible rather than silently skipping.

Workflows always start, and jobs select their work only after change detection succeeds. The
required `lint` check fails if detection fails. Integration jobs also fail on detection errors.
Existing required check names stay the same.

## Consequences

Documentation changes avoid host tests. Mixed changes run the union of their test groups.
New file types run all tests until we add a narrower rule and a regression test for it.
Local validation commands remain unchanged.
