# auditd-kit

[![Release](https://img.shields.io/github/v/release/spydisec/auditd-kit?sort=semver)](https://github.com/spydisec/auditd-kit/releases/latest)
[![Integration tests](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml)
[![Security scans](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/spydisec/auditd-kit)

auditd-kit sets up Linux audit logging (auditd rules and log settings) on your servers. It checks
each host before it changes anything, keeps the logs at a fixed size, and can undo the change.

```text
host check ──> render ──> plan ──> backup ──> install ──> verify
auditd can't work:                                        a check fails:
refuse, change nothing                                    restore the backup
```

- 🔍 Checks auditd, disk space, other agents, and existing rules first, and changes nothing if
  auditd-kit can't work on the host
- 📐 Keeps one set of rules, and on each host leaves out the rules that host can't load, e.g. a
  syscall its kernel doesn't know or a program that isn't installed
- 📦 Has three rule profiles, `minimal`, `medium`, and `heavy`, and three log sizes, from 250 MB
  to 2 GB in total
- ✅ Checks after each install that the rules are loaded and a test event is recorded, and restores
  the backup if a check fails
- 🐚 Runs as plain POSIX shell scripts, with nothing left running in the background

auditd-kit is at `0.x`, so settings can still change between releases.

## 🚀 Quick start

Run these as root on a host that has auditd. RHEL 10 also needs `tar` and `initscripts-service`.

```sh
sh scripts/install.sh --profile minimal --dry-run    # show each change
sh scripts/install.sh --profile minimal
```

If install exits with 1, it refused and changed nothing. A refusal from the host check prints
`refuse=<code> detail=<what to do>`. Exit code 2 means a check failed and the backup was
restored, and 3 means the restore failed too, so the host needs a person. To undo an install, run
`sh scripts/rollback.sh`.

`get.sh` downloads the latest release, checks it against `SHA256SUMS`, and runs its `install.sh`.
On a terminal it asks a few questions and shows the plan before it changes anything:

```sh
curl -fsSL https://github.com/spydisec/auditd-kit/releases/latest/download/get.sh | sudo sh
```

## ⚙️ Settings

Pass a setting as a flag, e.g. `--skip-keys`, or as a `key=value` line in a file that you name
with `--config FILE`.

| Setting | Default | What it does |
|---|---|---|
| `akit_profile` | `minimal` | `minimal`, `medium`, or `heavy`. See [rules/README.md](rules/README.md). |
| `akit_size` | `standard` | `small`, `standard`, or `large`: the backlog and the log file sizes. |
| `akit_max_log_file`, `akit_num_logs` | from `akit_size` | Your own log file size in MB and number of log files. |
| `akit_skip_keys` | none | Rule keys to leave out on this host. |
| `akit_existing_rules` | `keep` | `keep` leaves other files in `/etc/audit/rules.d/` as they are and loads them with ours. `replace` removes them, after the backup. |
| `akit_immutable` | `false` | `true` locks the rules until reboot (`-e 2`), so a later change or rollback needs a reboot. |

## 📡 Send events to your SIEM

auditd-kit writes events to `/var/log/audit/audit.log`, and your own agent sends that file to your
SIEM. [send-audit-log.md](docs/integrations/send-audit-log.md) shows how for common agents, and
[wazuh.md](docs/integrations/wazuh.md) adds Wazuh alert rules for each auditd-kit key.

## 🐧 Systems

auditd-kit runs on any Linux host that has auditd 2.8 or later with `augenrules`. Install prints a
warning on a system that isn't in the tested list, and goes ahead.

Tested on each change:

- Ubuntu 22.04, 24.04, and 26.04, with the rules loaded into a real kernel
- CentOS 7, Rocky Linux 8, 9, and 10, and Ubuntu 18.04 and 20.04, in containers, which check the
  files but can't load rules

## 📝 Notes

- **Fleets:** with no terminal, `get.sh` only prints the plan, and `--yes` makes it install. Pin
  `AKIT_VERSION`, keep `site.conf` in your own repo, and roll out to a few hosts first. For hosts
  without internet access, set `AKIT_MIRROR`. The header of [scripts/get.sh](scripts/get.sh) has
  the details.
- **Log volume:** `sh scripts/stats.sh` shows the bytes and events written each day, and which rule
  keys, programs, and users write the most events.
- **Without install.sh:** you can render the rules and load them yourself. See
  [rules/README.md](rules/README.md#load-the-rules-without-installsh).
- **Existing rules:** install keeps rule files it didn't write, under any name, so your own rules
  go in `/etc/audit/rules.d/` too. The files load in name order, and the kernel gives an event the
  key of the first rule that matches it, so a file that sorts before `10-` wins over our profile
  rules. A rule that is a copy of a loaded rule is skipped. A line of yours that can't load gets
  a warning, and a line of ours that can't load rolls the install back. A file of yours that
  sorts before `00-auditd-kit-base.rules` is the exception. A bad line there stops the whole load,
  and install rolls back. Install refuses a kept file that sets `-f 2`, because that would panic
  the host when auditing fails, and it warns when a kept file sets `-e 2`.
- **Locked rules:** when the rules are locked until reboot (`-e 2`), install and rollback can't
  load anything. They write the files, print `reboot=required`, and the reboot loads them. The
  new rules are not checked until then, so run `sh scripts/verify.sh` after the reboot. If it
  fails, run `sh scripts/rollback.sh` and reboot again.
- **After a reboot or a kernel update:** run `sh scripts/verify.sh`. The rules load with `-i`, so
  a rule that stops loading doesn't stop the others, and verify is what reports it. It fails when
  fewer rules are loaded than auditd-kit loaded at the install.
- **Other agents:** install never restarts or changes another agent. It refuses only when an
  agent has taken the audit system for itself, which is osquery with `disable_audit=false`, or
  Auditbeat with its own audit rules or a unicast socket. Some agents, e.g. Wazuh with who-data,
  add audit rules with `auditctl` when they start. A load deletes those, so install puts them
  back after it. It finds them by a key that no file in `rules.d` uses, and logs each one. It
  can't put them back when the new rules lock the audit system (`-e 2`), and rollback doesn't
  restore them, so restart the agent in those two cases.
- **Rollback:** `sh scripts/rollback.sh` restores the newest backup, `--list` prints the backup ids,
  and `rollback.sh <id>` restores an older one. Install keeps the newest 5 backups. On a host with
  no auditd-kit state file, it also keeps the first one as `original`, so
  `rollback.sh --original` puts the host back as it was before the first install. Rollback exits
  0 when done, 1 when there is no such backup, and 3 when a person must fix the host.
- **Files on the host:** [ADR 0014](docs/adr/0014-files-auditd-kit-writes.md) lists each file that
  auditd-kit writes or removes.
- **Script options:** each script's header lists its flags, e.g. `install.sh --guided`,
  and `stats.sh --format csv --top 20`. `verify.sh` exits 2 when a check fails.
- **Design decisions:** [docs/adr/](docs/adr/).

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, [SECURITY.md](SECURITY.md) to report a
security problem, and [AI-DECLARATION.md](AI-DECLARATION.md) for how AI tools are used.

## 📄 Licence

[Apache-2.0](LICENSE)
