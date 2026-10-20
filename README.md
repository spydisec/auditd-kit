# auditd-kit

auditd-kit turns on Linux audit logging (auditd) across a fleet with safe defaults. It ships plain rule and
configuration files, POSIX shell scripts, and an Ansible collection, so you can use the files by hand, run the
scripts on a single host, or roll the change out with Ansible.

Its defaults are meant not to harm the host. For example, no setting makes the machine halt or drop to single-user
mode when audit logging has a problem.

## Status

auditd-kit is at version `0.x` and is not ready for production use. Interfaces and defaults may change between
releases. The Ansible collection can survey hosts and collect stats, but it can't install yet.

## Quickstart

Run these as root on the host, from a copy of this repo. auditd must already be installed. On RHEL
10 that's the `audit` and `audit-rules` packages, and install also needs `tar` and `service`
(`initscripts-service`).

```sh
sh scripts/survey.sh                          # report the host, change nothing
sh scripts/install.sh --profile minimal --dry-run   # show what install would change
sh scripts/install.sh --profile minimal
```

install refuses with exit code 1, and changes nothing, when the host isn't safe to change. Each
refusal is printed as `refuse=<code> override=<what to do>`. After a change it runs `verify.sh`,
and if a check fails it restores the backup and exits 2. Exit code 3 means the restore failed too,
and a person must fix the host. Every run logs to `/var/log/auditd-kit/`.

To undo an install, run `sh scripts/rollback.sh`. To check a host later, run `sh scripts/verify.sh`.
To see how much audit data a host writes and which rules write it, run `sh scripts/stats.sh`.

### Settings

Pass settings as flags, or as `key=value` lines in a file named with `--config FILE`. A flag drops
the `akit_` prefix and uses dashes, so `akit_skip_keys` is `--skip-keys`.

| Setting | Default | What it does |
|---|---|---|
| `akit_profile` | `minimal` | `minimal`, `medium`, or `heavy`. See [rules/README.md](rules/README.md). |
| `akit_size` | `standard` | `small`, `standard`, or `large`: the backlog and the log file sizes. |
| `akit_skip_keys` | none | Rule keys to leave out on this host. |
| `akit_extra_rules_dir` | none | A dir of your own `50-*.rules` files to load with the profile. |
| `akit_existing_rules` | unset | `keep` or `replace` other files in `/etc/audit/rules.d/`. Install refuses while it's unset and other rule files exist. |
| `akit_forward` | `none` | Forward audit events through rsyslog. `remote` sends them to `akit_remote_host`. `local` sends them to the syslog facility only, for a local agent such as Azure Monitor Agent to read. |
| `akit_immutable` | `false` | `true` locks the rules until reboot (`-e 2`). |

### Without install.sh

To load the rules by hand, render them on the host first. Render writes rule files that load on
that host, and changes nothing. See [rules/README.md](rules/README.md#load-the-rules-without-installsh).

## Supported systems

- Red Hat Enterprise Linux 7, 8, 9, and 10, tested on CentOS 7 and Rocky Linux 8, 9, and 10
- Ubuntu 22.04 and 24.04

## More information

The decisions behind the design are recorded in [docs/adr/](docs/adr/). See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to propose a change and [SECURITY.md](SECURITY.md) for how to report a security problem.

## Licence

Apache-2.0. See [LICENSE](LICENSE). Files copied from other projects keep their own licence file
next to them.

[AI-DECLARATION.md](AI-DECLARATION.md) says how AI tools are used to build auditd-kit.
