# Guide

## Hosts that already have rules or agents

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

## Backup and rollback

Install makes a backup before every change. A backup holds all of `/etc/audit`, so it covers the
rules of other tools too. Install keeps the newest 5 backups, and it never removes the backup
from before the first install.

`sh scripts/backup.sh` makes a backup without installing anything. You can run it before you edit
your own rules, and `rollback.sh` then undoes the edit, even on a host that has no auditd-kit
rules.

A rollback puts back each file that the backup holds. It doesn't remove a file that you added
after the backup, and it names that file in a warning. It also doesn't restore rules that an
agent added at run time, so restart that agent if its events stop.

Rollback exits 0 when done, 1 when there is no such backup, and 3 when a person must fix the
host.

## Verify

Run `sh scripts/verify.sh` after a reboot or a kernel update. The rules load with `-i`, so a rule
that stops loading doesn't stop the others, and verify is what reports it.

| Check | What it tests |
|---|---|
| `status` | auditd is running, and the kernel has auditing on. |
| `rules` | Each rule in `/etc/audit/rules.d/` is loaded. Verify compares the files with the loaded rules by key. |
| `files` | The files that install wrote are unchanged. |
| `canary`, `lost` | A test event is recorded, and no events were dropped. |

Verify exits 2 when a check fails. A rule of another file that isn't loaded, e.g. a bad line or
a copy of a loaded rule, prints as `result=warn` and doesn't change the exit code.

## Many hosts

auditd-kit has no fleet tool of its own. Your own tool, e.g. Ansible or an SSH loop, runs the same
command on each host and copies your own rule files to `/etc/audit/rules.d/`.

- From a script, pipe `get.sh` into the shell and pass `--yes` with your settings, e.g.
  `curl -fsSL <url>/get.sh | sudo sh -s -- --yes --profile medium`. With no terminal and no
  `--yes`, `get.sh` only prints the plan.
- The last line of `get.sh` is one result line for the host, e.g.
  `result=installed version=0.4.0 host=web1`. A refusal adds `codes=`, and locked rules add
  `reboot=required`.
- Pin `AKIT_VERSION`, keep your settings file in your own repo, and roll out to a few hosts first.
- For hosts without internet access, set `AKIT_MIRROR`. The header of
  [scripts/get.sh](../scripts/get.sh) has the details.

## Other notes

- A bad line in a rule file that sorts before `00-auditd-kit-base.rules` stops the whole load,
  and install rolls back. The host check warns about such a file before the install.
- You can render the rules and load them without `install.sh`. See
  [rules/README.md](../rules/README.md#load-the-rules-without-installsh).
- [ADR 0014](adr/0014-files-auditd-kit-writes.md) lists each file that auditd-kit writes or
  removes, and [ADR 0029](adr/0029-keep-what-is-on-the-host.md) explains why install keeps what
  is on the host.
