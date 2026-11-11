# auditd-kit

[![Release](https://img.shields.io/github/v/release/spydisec/auditd-kit?sort=semver)](https://github.com/spydisec/auditd-kit/releases/latest)
[![Integration tests](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml)
[![Security scans](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/spydisec/auditd-kit)

auditd-kit puts a tested set of Linux audit rules (auditd) on a server with one command. It keeps
the rules and agents that are already there, checks that the new rules record events, and can
undo the change.

```text
host check ──> render ──> plan ──> backup ──> install ──> verify
auditd can't work:                                        a check fails:
refuse, change nothing                                    restore the backup
```

- **Three rule profiles**, `minimal`, `medium`, and `heavy`, with rule keys named after MITRE
  ATT&CK techniques. See [rules/README.md](rules/README.md).
- **Rules that fit the host.** Install leaves out a rule that the host can't load, e.g. a syscall
  its kernel doesn't know or a program that isn't installed.
- **A fixed log size**, from 250 MB to 2 GB in total, and auditd never halts the host when the
  disk fills.
- **A backup before every change**, and a rollback when the load or a check fails.
- **Plain POSIX shell.** Install adds no packages and leaves nothing running. It writes the rule
  files, a few `auditd.conf` keys, and its own state and backups.

auditd-kit is at `0.x`, so settings can still change between releases.

## Quick start

Run as root on a host that has auditd. RHEL 10 also needs `tar` and `initscripts-service`.

```sh
curl -fsSL https://github.com/spydisec/auditd-kit/releases/latest/download/get.sh | sudo sh
```

`get.sh` downloads the latest release, checks it against `SHA256SUMS`, and runs its `install.sh`.
On a terminal it asks for the profile and shows the plan before it changes anything.

From a copy of the repo or a release bundle, run the scripts yourself:

```sh
sh scripts/install.sh --profile minimal --dry-run    # show each change
sh scripts/install.sh --profile minimal
sh scripts/rollback.sh                               # undo the last install
```

| Exit code | Meaning |
|---|---|
| 0 | Done. |
| 1 | Refused, and nothing changed. Each reason prints as `refuse=<code> detail=<what to do>`. |
| 2 | A check failed, and the backup was restored. |
| 3 | The restore failed too, so a person must fix the host. |

## What install does on a host that is already set up

- **Existing rules stay.** Install keeps every file in `/etc/audit/rules.d/` that it didn't
  write, and loads its own files next to them. A rule that is a copy of a loaded rule is skipped.
  `--existing-rules replace` removes the other files instead, after the backup.
- **Your own rules go in the same place.** Put a file with any name that ends in `.rules` in
  `/etc/audit/rules.d/`. The files load in name order, and the kernel gives an event the key of
  the first rule that matches it. So a file that sorts before `10-` wins over the profile rules,
  and that is where a rule that excludes a noisy program goes. A line of yours that the kernel
  rejects gets a warning, and the rest still load.
- **Other agents are left alone.** Install never restarts or changes another agent. Some agents,
  e.g. Wazuh with who-data, add audit rules when they start, and a load deletes those. Install
  puts them back after the load, when they have a key that no rule file uses.
- **Locked rules need a reboot.** When the rules are locked until reboot (`-e 2`), install writes
  the files and prints `reboot=required`. Run `sh scripts/verify.sh` after the reboot.

Install refuses only when auditd-kit can't work on the host:

| Code | Reason |
|---|---|
| `not_root` | Install isn't running as root. |
| `auditd_missing` | `auditctl` or `augenrules` isn't installed, or auditd is older than 2.8. |
| `audit_off` | The kernel has audit turned off. |
| `low_disk` | The audit log filesystem has less than 1.5 times the chosen log size free. |
| `tar_missing`, `service_missing` | The `tar` or `service` command isn't installed. |
| `agent_needs_audit:<agent>` | An agent reads the audit events itself, so auditd gets none: osquery with `disable_audit=false`, or Auditbeat with its own audit rules or a unicast socket. |
| `existing_rules_panic` | A kept rule file sets `-f 2`, which would panic the host when auditing fails. |

## Settings

Pass a setting as a flag, e.g. `--skip-keys`, or as a `key=value` line in a file that you name
with `--config FILE`.

| Setting | Default | What it does |
|---|---|---|
| `akit_profile` | `minimal` | `minimal`, `medium`, or `heavy`. |
| `akit_size` | `standard` | `small`, `standard`, or `large`: the backlog and the log file sizes. |
| `akit_max_log_file`, `akit_num_logs` | from `akit_size` | Your own log file size in MB and number of log files. |
| `akit_skip_keys` | none | Rule keys to leave out on this host. |
| `akit_existing_rules` | `keep` | `keep` leaves other files in `/etc/audit/rules.d/` as they are. `replace` removes them. |
| `akit_immutable` | `false` | `true` locks the rules until reboot (`-e 2`), so a later change or rollback needs a reboot. |

## Rollback

`sh scripts/rollback.sh` restores the newest backup, `--list` prints the backup ids, and
`rollback.sh <id>` restores an older one. Install keeps the newest 5 backups. It also keeps the
backup from before the first install, so `rollback.sh --original` puts the host back as it was.

A backup holds all of `/etc/audit`, so it covers the rules of other tools too.
`sh scripts/backup.sh` makes one without installing anything. You can run it before you edit
your own rules, and `rollback.sh` then undoes the edit, even on a host that has no auditd-kit
rules.

Rollback exits 0 when done, 1 when there is no such backup, and 3 when a person must fix the
host. It doesn't restore rules that an agent added at run time, so restart that agent if its
events stop.

## Send events to your SIEM

auditd-kit writes events to `/var/log/audit/audit.log`, and your own agent sends that file to your
SIEM. [send-audit-log.md](docs/integrations/send-audit-log.md) shows how for common agents, and
[wazuh.md](docs/integrations/wazuh.md) adds Wazuh alert rules for each auditd-kit key.

## Systems

auditd-kit runs on any Linux host that has auditd 2.8 or later with `augenrules`. On a system that
isn't in the tested list, install prints a warning and goes ahead.

Tested on each change:

- Ubuntu 22.04, 24.04, and 26.04, with the rules loaded into a real kernel
- CentOS 7, Rocky Linux 8, 9, and 10, and Ubuntu 18.04 and 20.04, in containers, which check the
  files but can't load rules
- Debian 12 in a container, as an example of a system that isn't in the list

## Fleets

auditd-kit has no fleet tool of its own. Your own tool, e.g. Ansible or an SSH loop, runs the same
command on each host and copies your own rule files to `/etc/audit/rules.d/`.

- With no terminal, `get.sh` only prints the plan, and `--yes` makes it install.
- The last line of `get.sh` is one result line for the host, e.g.
  `result=installed version=0.4.0 host=web1`. A refusal adds `codes=`, and locked rules add
  `reboot=required`.
- Pin `AKIT_VERSION`, keep your settings file in your own repo, and roll out to a few hosts first.
- For hosts without internet access, set `AKIT_MIRROR`. The header of
  [scripts/get.sh](scripts/get.sh) has the details.

## Notes

- **After a reboot or a kernel update:** run `sh scripts/verify.sh`. The rules load with `-i`, so
  a rule that stops loading doesn't stop the others, and verify is what reports it. It checks
  that auditd is running, compares the rules in `/etc/audit/rules.d/` with the loaded rules by
  key, and records a test event. It exits 2 when an auditd-kit rule isn't loaded or the test
  event isn't recorded. A rule of another file that isn't loaded prints as `result=warn` and
  doesn't change the exit code.
- **Log volume:** `sh scripts/stats.sh` shows the bytes and events written each day, and which rule
  keys, programs, and users write the most events.
- **A rule file that sorts before ours:** a bad line in a file that sorts before
  `00-auditd-kit-base.rules` stops the whole load, and install rolls back. The host check warns
  about such a file before the install.
- **Without install.sh:** you can render the rules and load them yourself. See
  [rules/README.md](rules/README.md#load-the-rules-without-installsh).
- **Files on the host:** [ADR 0014](docs/adr/0014-files-auditd-kit-writes.md) lists each file that
  auditd-kit writes or removes.
- **Script options:** each script's header lists its flags, e.g. `install.sh --guided` and
  `stats.sh --format csv --top 20`.
- **Design decisions:** [docs/adr/](docs/adr/).
  [ADR 0029](docs/adr/0029-keep-what-is-on-the-host.md) explains why install keeps what is on the
  host.

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, [SECURITY.md](SECURITY.md) to report a
security problem, and [AI-DECLARATION.md](AI-DECLARATION.md) for how AI tools are used.

## Licence

[Apache-2.0](LICENSE)
