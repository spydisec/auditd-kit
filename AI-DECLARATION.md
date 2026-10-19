---
version: "0.1.2"
level: copilot
components:
  rules/standard: none
---

This format is based on [AI-DECLARATION.md](https://ai-declaration.md/en/0.1.2).

## Notes

- Claude Code writes most of the code, tests, CI, and docs from a design that the maintainer
  agreed with it, and it asks the maintainer about decisions the design leaves open.
- Each change goes through a PR with CI and an AI review. The maintainer reviews and merges, or
  lets Claude Code merge a PR after CI and the review pass.
- The rules in `rules/standard/` are an unmodified copy of
  [Neo23x0/auditd](https://github.com/Neo23x0/auditd), and auditd-kit didn't write them.
