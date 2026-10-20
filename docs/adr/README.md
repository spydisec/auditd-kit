# Architecture decision records

Each file records one decision, why we made it, and what follows from it. Files are numbered in
order and never renumbered. To change a decision, write a new ADR and set the old one's status to
`Superseded by NNNN`.

Use this template:

```markdown
# NNNN. Title in sentence case

Status: Proposed | Accepted | Superseded by NNNN
Date: YYYY-MM-DD

## Context

The problem and the facts that shaped the decision.

## Decision

What we decided.

## Consequences

What becomes easier, what becomes harder, and what we have to do next.
```

| ADR | Title | Status |
|---|---|---|
| [0001](0001-supported-operating-systems.md) | Supported operating systems for v1 | Accepted |
| [0002](0002-plain-files-with-script-and-ansible-paths.md) | Plain files with a script path and an Ansible path | Accepted |
| [0003](0003-survey-before-change.md) | Run a read-only survey before any change | Accepted |
| [0004](0004-local-logs-by-default.md) | Keep logs local by default and forward through one added file | Accepted |
| [0005](0005-rule-profiles.md) | Rule profiles and upstream rule sources | Superseded by 0011 |
| [0006](0006-never-halt-the-host.md) | Never halt the host when the audit disk fills | Accepted |
| [0007](0007-test-strategy.md) | Test strategy | Accepted |
| [0008](0008-workflow-and-releases.md) | Trunk-based workflow and verifiable release bundles | Accepted |
| [0009](0009-verify-with-a-canary-watch-rule.md) | Verify with a canary watch rule | Accepted |
| [0010](0010-render-trims-unknown-syscalls.md) | Render trims unknown syscalls and strips control lines | Accepted |
| [0011](0011-our-own-layered-rule-profiles.md) | Our own layered rule profiles | Accepted |
| [0012](0012-settings-flags-and-exit-codes.md) | Settings, flags, and exit codes | Accepted |
| [0013](0013-no-package-installs.md) | auditd-kit doesn't install packages | Accepted |
| [0014](0014-files-auditd-kit-writes.md) | Files auditd-kit writes | Accepted |
| [0015](0015-role-runs-shared-scripts.md) | The role runs the shared scripts on targets | Accepted |
| [0016](0016-ansible-core-versions.md) | Supported ansible-core versions | Accepted |
| [0017](0017-broad-rules-load-last.md) | Broad rules load last | Accepted |
| [0018](0018-render-drops-exec-rules-on-symlinks.md) | Render drops exec rules on symlinks | Accepted |
