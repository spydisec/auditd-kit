# 0014. Files auditd-kit writes

Status: Accepted
Date: 2026-10-20

## Context

An install changes files that auditd and the distro also own, so an operator needs to know which
files auditd-kit writes, which it removes, and what a rollback puts back. auditd 2.8 on RHEL 7
rejects some `auditd.conf` keys that auditd 3.x accepts, so auditd-kit can't ship one whole
`auditd.conf` for every host. Most distros also ship a `rules.d/audit.rules` that holds only control
lines such as `-D`, `-b`, and `-f`, and those lines would override ours.

## Decision

auditd-kit writes these files, and no others:

| File | What auditd-kit does |
|---|---|
| `/etc/audit/rules.d/00-auditd-kit-base.rules` and the profile files `10-`, `20-`, `30-auditd-kit-*.rules` | Writes the rendered rules |
| `/etc/audit/rules.d/99-auditd-kit-finalize.rules` | Writes it only when `akit_immutable` is true |
| `/etc/audit/rules.d/50-*.rules` | Copies the overlay files from `akit_extra_rules_dir` |
| `/etc/audit/auditd.conf` | Sets the keys in `config/auditd/<size>.conf` and leaves every other line alone |
| `/etc/auditd-kit/canary` | Creates it once, for `verify.sh` |
| `/etc/auditd-kit/state` | Records the settings, the rule count, and a checksum line for each file above, except the canary |
| `/var/lib/auditd-kit/render-report.txt` | Lists each rule that render dropped and why |
| `/var/lib/auditd-kit/backups/<id>.tgz` | Keeps the newest 5 backups |
| `/var/log/auditd-kit/install-<time>.log` and `rollback-<time>.log` | Logs each run, including dry runs and refusals |
| `/run/auditd-kit.lock` | Holds the PID of the running script |

A file in `rules.d` belongs to auditd-kit when its name contains `auditd-kit` or the state file lists
it. auditd-kit always removes a distro `audit.rules` that holds only control lines. Every other
file in `rules.d` needs a choice in `akit_existing_rules`:

- `keep` leaves the files in place, and preflight refuses when any of them has a control line.
- `replace` removes them.

auditd-kit removes a file only after the backup has saved it. When a profile no longer has one of
our files, e.g. after a change from `heavy` to `minimal`, install removes that file too.

A backup holds `/etc/audit`, `/etc/audisp` on RHEL 7, our rsyslog drop-in, and the state file. A
restore puts those files back. It removes the files that auditd-kit added after the backup, and
also the `audit.rules` and `audit.rules.prev` that augenrules writes. It keeps any other file that
was added after the backup, and logs a warning for it. A restore to a backup from before the first
install also removes the canary and `/etc/auditd-kit/`.

## Consequences

A rollback gives back checksum-identical `/etc/audit` and `/etc/rsyslog.d`, and the state file lets
the survey and `verify.sh` tell our files from the ones that other tools wrote. A run that exits 1
changes no file in `/etc` or `/var/lib`, but it still writes its log and briefly holds the lock.
The render report stays after a rollback, so an operator can see why the rules failed to load.
A new file that auditd-kit writes must be added to this list, to the backup, and to the restore.
