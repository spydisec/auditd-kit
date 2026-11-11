# 0021. Select tests from changed files

Status: Accepted
Date: 2026-10-21

## Context

Every PR runs the full test suite, even when only documentation changes. Workflow path filters
can leave required checks pending, so they cannot replace the existing required jobs.

## Decision

This replaces the every-PR test selection in ADR 0007. Its static, Bats, real kernel, and security
layers still apply. ADR 0027 removed the Molecule layer, and the VM layer (`tests/vm`) was never
built, so no RHEL host loads the rules on a real kernel in CI.

Note, 2026-11-11: the test layers are lint, Bats with stubbed host tools, a real kernel job on
Ubuntu 22.04, 24.04, and 26.04, and a container job for each image in the README's tested list
plus Debian 12, which checks that an untested system installs with a warning (ADR 0029). The
RHEL family is tested in containers only. Before a release that changes how rules load, run the
install, verify, and rollback by hand on a RHEL-family VM.

PRs select test groups through `scripts/dev/ci-changes.bash`. It reads the complete Git diff
as NUL-delimited paths, including deleted paths and both sides of renames. Directory rules
select the owning tests. Shell, AWK, rule, configuration, and template extensions outside known
directories select the full suite. Other YAML files select lint. Unknown files select the full suite.

| Changes | Tests |
|---|---|
| Ordinary Markdown | No runtime tests |
| Root README, licence | Release packaging |
| Rules README | Rules content tests and packaging |
| Runtime scripts, rules, configuration | Full suite |
| Bats tests and fixtures | Lint, Bats, portability |
| Kernel or container test scripts | Lint, kernel and container matrices |
| Development scripts | Lint, Bats, portability, packaging |
| Workflow or routing changes | Full suite |
| Linter settings and tool requirements | Lint |

Semgrep, Gitleaks, and Zizmor still run on every PR and weekly. PR-title validation is unchanged.
Pushes to `main` run the full suite.

Workflows always start, and jobs select their work only after change detection succeeds. The
required `lint` check fails if detection fails. Integration jobs also fail on detection errors.
Existing required check names stay the same.

## Consequences

Documentation changes avoid host tests. Mixed changes run the union of their test groups.
New file types run all tests until we add a narrower rule and a regression test for it.
Local validation commands remain unchanged.
