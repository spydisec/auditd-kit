# 0012. Settings, flags, and exit codes

Status: Accepted
Date: 2026-10-20

## Context

The scripts and the Ansible role take the same settings. An operator on the script path needs a
way to give them without editing the scripts. A typo in a setting name must not pass silently, and
a config file must not be able to run code.

## Decision

Each setting has one name, e.g. `akit_profile`. The config file uses that exact name, one
`key=value` per line, with `#` comments and blank lines. The scripts parse the file and never
source it. A flag drops the `akit_` prefix and uses dashes, so `akit_profile` is `--profile` and
`akit_syslog_facility` is `--syslog-facility`. The order of precedence is defaults, then the
config file, then flags.

An unknown key, an unknown flag, or a bad value stops the script before it changes anything. The
message names the setting. The old names `akit_profile=standard` and `akit_size=medium` are
refused with the new value in the message.

Every script uses the same exit codes:

| Code | Meaning |
|---|---|
| 0 | Done, or nothing to do |
| 1 | Refused, and nothing changed |
| 2 | Failed, and the change was rolled back |
| 3 | Rollback failed, and a person must fix the host |

## Consequences

The Ansible role and the script path read the same names, so one inventory variable works for
both. Adding a setting means adding it to `scripts/lib/settings.sh`, which checks its value.
Anything that wraps the scripts can rely on code 1 meaning that the host is untouched.
