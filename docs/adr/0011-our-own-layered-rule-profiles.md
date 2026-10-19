# 0011. Our own layered rule profiles

Status: Accepted
Date: 2026-10-19

## Context

ADR 0005 gave v1 a `minimal` profile of our own and a `standard` profile that was a vendored copy
of the Neo23x0/auditd rules. The vendored file is long, it logs a lot, and its keys and comments
aren't ours, so an operator had to read someone else's file to know what a host logs. Operators
usually edit the rules for their own needs anyway, so the kit's job is to make the first choice
easy and safe.

## Decision

We ship our own rules in four files that build on each other, and we drop the vendored copy:

- `minimal` loads `rules/00-base.rules` and `rules/10-minimal.rules`. It's the default and is
  meant for every server.
- `medium` adds `rules/20-medium.rules` and is meant for critical servers.
- `heavy` adds `rules/30-heavy.rules` and is meant for hosts that must meet CIS or STIG audit
  checks.

`00-base.rules` holds the control lines, the canary rule, and the audit tampering rules, so every
profile has them. Render writes each file to `/etc/audit/rules.d/` with `auditd-kit` in its name,
e.g. `10-auditd-kit-minimal.rules`. Overlay files keep their `50-*.rules` names and load after the
profile files. Immutable mode stays a separate setting (ADR 0006), in `rules/99-finalize.rules`.

Every rule has a short comment of our own that says what it catches. Rule keys use MITRE ATT&CK
technique names where they map cleanly, and plain names elsewhere. We take ideas from other rule
sets, which `rules/README.md` credits, but we don't copy their text or rules.

The size presets are renamed `small`, `standard`, and `large`, so no setting value is also a
profile name. Their values don't change. Render refuses the old names, profile `standard` and size
`medium`, and names the new value.

For JSON output, the docs recommend Laurel instead of building it into the kit.

## Consequences

We maintain the rules ourselves, and a change that adds log volume needs a "Volume impact" note in
the changelog. Operators who used profile `standard` or size `medium` must change their settings
to `heavy` and `standard`. `heavy` is a starting point for compliance and isn't a certified
profile, so a site may still need to add its own rules, e.g. one rule for each setuid binary.
