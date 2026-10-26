# 0024. Fewer settings

Status: Accepted
Date: 2026-10-26

## Context

auditd-kit has 15 settings (`scripts/lib/settings.sh`, and the same names in the Ansible role).
Several of them describe one thing in pieces, and each new refusal so far added its own override
setting. Every setting is one more thing to document, validate, test, and explain to an operator.
v1 hasn't shipped, so settings can still be renamed without a deprecation period.

## Decision

v0.3.0 removes 5 settings and adds 1, which leaves 11.

Forwarding becomes one setting. `akit_forward` takes `none`, `local`, or a URL, and
`akit_remote_host`, `akit_remote_port`, and `akit_remote_protocol` are removed:

```
akit_forward=tcp://siem.example.com:514
akit_forward=udp://192.0.2.10        # the port defaults to 514
akit_forward=tcp://[2001:db8::1]:514 # an IPv6 address goes in brackets
```

`akit_syslog_facility` stays, with its default of `local6`.

Overrides become one setting. `akit_accept` is a comma list of refusal codes, and
`akit_accept_agents` and `akit_accept_catchall` are removed. A refusal prints the exact value to
add, e.g. `refuse=agent_conflict:wazuh override=akit_accept=agent_conflict:wazuh`. Only refusals
that the operator can't fix on the host take part, which today are `agent_conflict:<agent>` and
`catchall_forward`. The others, e.g. `low_disk` or `not_root`, still print an action to take.

Log sizes stay as they are. `akit_size=small|standard|large` sets the log file size and count, and
that covers most hosts. An operator who needs other values sets `akit_max_log_file` and
`akit_num_logs`, which override the preset. The `low_disk` check already uses the values in effect,
so custom sizes are checked the same way as the presets.

`akit_existing_rules` stays. It's a choice between `keep` and `replace`, not an override.

A removed setting, given as a flag or in a config file, fails with a message that names the
replacement, the same way the renamed profile and size values do today. For example,
`akit_remote_host` fails with "removed, use akit_forward=tcp://host:port".

The 11 settings after the change are `akit_profile`, `akit_size`, `akit_max_log_file`,
`akit_num_logs`, `akit_immutable`, `akit_skip_keys`, `akit_extra_rules_dir`,
`akit_existing_rules`, `akit_forward`, `akit_syslog_facility`, and `akit_accept`.

## Consequences

Operators learn one rule for overrides, and a new refusal never adds a setting. Existing
`site.conf` files and Ansible inventories that set forwarding or overrides must change before they
run v0.3.0, so the release notes list each old setting with its replacement. The state
file and the survey keep their current keys.

The forwarding URL needs its own parser and tests, including IPv6 brackets and a missing port.
Guided mode still asks for the server, port, and protocol, and builds the URL from the answers.

