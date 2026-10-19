---
version: "0.1.2"
level: copilot
components:
  rules/standard: none
---

This format is based on [AI-DECLARATION.md](https://ai-declaration.md/en/0.1.2).

## Notes

- Claude Code writes most of the code, tests, CI, and docs from a design the maintainer has
  agreed to, and it asks the maintainer about decisions the design leaves open.
- Each change goes through a PR with CI and an AI review. The maintainer merges each PR, or tells
  Claude Code to merge a set of PRs once their CI and review pass.
- The rules in `rules/standard/` are an unmodified copy of
  [Neo23x0/auditd](https://github.com/Neo23x0/auditd). Claude Code copied them without changes.
