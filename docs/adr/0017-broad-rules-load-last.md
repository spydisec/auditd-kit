# 0017. Broad rules load last

Status: Accepted
Date: 2026-10-20

## Context

The kernel checks exit rules in load order and gives an event the key of the first rule that
matches it. Two broad rules matched events that later, more specific rules were meant to key:

- The `minimal` rule for setuid programs keyed `crontab` and `at` as `T1548`, not `T1053`.
- The `medium` rule for every command by a logged-in user keyed commands run from `/tmp`, the
  `heavy` label and ACL tools, and any overlay rule as `T1059`.

The events were still logged, but a search by key missed them.

## Decision

The broad execve rules move into their own files, which load after the profile files and the
overlay files:

- `rules/90-minimal-last.rules` holds the setuid rule, and every profile loads it.
- `rules/91-medium-last.rules` holds the every-command rule, and `medium` and `heavy` load it.

A test checks that no other rule file holds an execve rule without a path.

## Consequences

A profile now writes up to two more files to `/etc/audit/rules.d/`. A new specific rule can go in
any profile file or overlay file and keeps its own key. A new broad rule goes in a last file.
