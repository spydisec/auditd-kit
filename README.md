# auditd-kit

[![Release](https://img.shields.io/github/v/release/spydisec/auditd-kit?sort=semver)](https://github.com/spydisec/auditd-kit/releases/latest)
[![Integration tests](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml)
[![Security scans](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/spydisec/auditd-kit)

auditd-kit sets up Linux audit logging (auditd rules and log settings) on your servers. It checks
each host before it changes anything, keeps the logs at a fixed size, and can undo the change.

```text
survey ──> preflight ──> render ──> plan ──> backup ──> install ──> verify
           unsafe host:                                            a check fails:
           refuse, change nothing                                  restore the backup
```

- 🔍 Checks the OS, disk space, other agents, and existing rules first, and changes nothing if the
  host isn't safe
- 📐 Keeps one set of rules, and on each host leaves out the rules that host can't load, e.g. a
  syscall its kernel doesn't know or a program that isn't installed
- 📦 Has three rule profiles, `minimal`, `medium`, and `heavy`, and three log sizes, from 250 MB
  to 2 GB in total
- ✅ Checks after each install that the rules are loaded and a test event is recorded, and restores
  the backup if a check fails
- 🐚 Runs as plain POSIX shell scripts, with nothing left running in the background

auditd-kit is at `0.x`, so settings can still change between releases. The Ansible collection can
survey hosts and collect stats, but it can't install yet.

## 🚀 Quick start

Run these as root on a host that has auditd. RHEL 10 also needs `tar` and `initscripts-service`.

```sh
sh scripts/survey.sh                                 # report the host, change nothing
sh scripts/install.sh --profile minimal --dry-run    # show each change
sh scripts/install.sh --profile minimal
```

If install exits with 1, it refused and changed nothing. Each refusal prints
`refuse=<code> override=<what to do>`. Exit code 2 means a check failed and the backup was
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
| `akit_extra_rules_dir` | none | A dir of your own `50-*.rules` files to load with the profile. |
| `akit_existing_rules` | unset | `keep` or `replace` other files in `/etc/audit/rules.d/`. Install refuses while it's unset and other rule files exist. |
| `akit_accept` | none | Refusals to accept, as the codes install prints, e.g. `agent_conflict:wazuh`. |
| `akit_immutable` | `false` | `true` locks the rules until reboot (`-e 2`), so a later change or rollback needs a reboot. |

## 📡 Send events to your SIEM

auditd-kit writes events to `/var/log/audit/audit.log`, and your own agent sends that file to your
SIEM. [send-audit-log.md](docs/integrations/send-audit-log.md) shows how for common agents, and
[wazuh.md](docs/integrations/wazuh.md) adds Wazuh alert rules for each auditd-kit key.

## 🐧 Supported systems

- RHEL 7, 8, 9, and 10, tested on CentOS 7 and Rocky Linux 8, 9, and 10
- Ubuntu 18.04, 20.04, 22.04, 24.04, and 26.04 LTS

## 📝 Notes

- **Fleets:** with no terminal, `get.sh` only prints the plan, and `--yes` makes it install. Pin
  `AKIT_VERSION`, keep `site.conf` in your own repo, and roll out to a few hosts first. For hosts
  without internet access, set `AKIT_MIRROR`. The header of [scripts/get.sh](scripts/get.sh) has
  the details.
- **Log volume:** `sh scripts/stats.sh` shows the bytes and events written each day, and which rule
  keys, programs, and users write the most events.
- **Without install.sh:** you can render the rules and load them yourself. See
  [rules/README.md](rules/README.md#load-the-rules-without-installsh).
- **Design decisions:** [docs/adr/](docs/adr/).

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, [SECURITY.md](SECURITY.md) to report a
security problem, and [AI-DECLARATION.md](AI-DECLARATION.md) for how AI tools are used.

## 📄 Licence

[Apache-2.0](LICENSE)
