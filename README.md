# auditd-kit

[![Release](https://img.shields.io/github/v/release/spydisec/auditd-kit?sort=semver)](https://github.com/spydisec/auditd-kit/releases/latest)
[![Integration tests](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/integration.yml)
[![Security scans](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/spydisec/auditd-kit/actions/workflows/security.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/spydisec/auditd-kit)

auditd-kit turns on Linux audit logging (auditd) on your servers. It checks each host before it
changes anything, keeps the logs at a size the disk can hold, and can undo the change.

```text
survey ──> refuse an unsafe host ──> render rules for this host ──> backup ──> install ──> verify
                                                                                 fail ──> rollback
```

- 🔍 Checks the disk, OS, other agents, and existing rules first, and changes nothing if the host isn't safe
- 📐 Keeps one set of rules, and renders them on each host so that every rule loads there
- 📦 Has three profiles, `minimal`, `medium`, and `heavy`, each with a cap on log size
- ✅ Writes a test event after each install, and restores the backup if it isn't recorded
- 🐚 Runs as plain POSIX shell, with no agent and no internet access needed

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
restored. To undo an install, run `sh scripts/rollback.sh`.

To download a release, check its checksum, and install it in one step:

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
| `akit_existing_rules` | unset | `keep` or `replace` other files in `/etc/audit/rules.d/`. |
| `akit_accept` | none | Refusals to accept, as the codes install prints, e.g. `agent_conflict:wazuh`. |
| `akit_immutable` | `false` | `true` locks the rules until reboot (`-e 2`). |

## 📡 Send events to your SIEM

auditd-kit writes events to `/var/log/audit/audit.log`, and your own agent sends that file to your
SIEM. [send-audit-log.md](docs/integrations/send-audit-log.md) shows how for common agents, and
[wazuh.md](docs/integrations/wazuh.md) adds Wazuh alert rules for each auditd-kit key.

## 🐧 Supported systems

RHEL 7 to 10, tested on CentOS 7 and Rocky Linux 8 to 10, and Ubuntu 18.04 to 26.04.

## 📝 Notes

- **Fleets:** with no terminal, `get.sh` only prints the plan, and `--yes` makes it install. Pin
  `AKIT_VERSION`, keep `site.conf` in your own repo, and roll out to a few hosts first. For hosts
  without internet access, set `AKIT_MIRROR`. The header of [scripts/get.sh](scripts/get.sh) has
  the details.
- **Log volume:** `sh scripts/stats.sh` shows how much each rule key writes.
- **Without install.sh:** you can render the rules and load them yourself. See
  [rules/README.md](rules/README.md#load-the-rules-without-installsh).
- **Design decisions:** [docs/adr/](docs/adr/).

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, [SECURITY.md](SECURITY.md) to report a
security problem, and [AI-DECLARATION.md](AI-DECLARATION.md) for how AI tools are used.

## 📄 Licence

[Apache-2.0](LICENSE)
