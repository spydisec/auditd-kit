# 0029. Keep what is on the host, and refuse only when auditd can't work

Status: Accepted
Date: 2026-11-11

## Context

Install refused a host in three common cases: an agent that uses the audit system was present,
`/etc/audit/rules.d` already held rules, or the OS was not on the supported list. Each refusal
needed an override setting (`akit_accept`, `akit_existing_rules`), and the agent override then
replaced every loaded rule, including rules the agent had added. Install already takes a backup
and rolls back when the load or verify fails, so most of those hosts were safe to change.

Every org also changes audit rules to fit its SIEM and to quiet noisy servers. The kit had a
setting for an extra rules directory, and it refused the simpler way, a file the org puts in
`rules.d`.

One line that fails stops `auditctl` from loading every rule after it. A test on audit 3.1.2
showed that a copy of a loaded rule, or a watch on a path that doesn't exist, is enough.

The survey had grown to about 775 lines and reported many values that nothing reads, e.g. the
listening ports and the Azure endpoint checks. Nobody ran it as a command.

## Decision

Install goes ahead whenever rollback can undo the change, and refuses only when auditd-kit can't
work on the host.

- **Refusals.** Install refuses when it isn't root, when `auditctl` or `augenrules` is missing or
  auditd is older than 2.8, when the kernel has audit turned off, when the log disk is too small,
  when an agent has taken the audit system for itself (osquery with audit on, or Auditbeat with
  its own rules or a unicast socket), and when a kept file sets panic mode. No refusal has an
  override setting.
- **Operating systems.** There is no OS allowlist. Install checks what the host has, and warns
  when the OS is not one that CI tests.
- **Existing rules.** Install keeps rule files it didn't write, under any name, and adds its own.
  `akit_existing_rules` is `keep` by default, and `replace` is still available. The kit's base
  file holds `-i`, so `auditctl` skips a line that fails and loads the rest. The kernel rejects a
  rule that is a copy of a loaded rule, and install logs it. Any other load error fails the
  install when it's on a kit line, and is a warning when it's on a line from a kept file.
- **Panic mode.** A kept file that sets `-f 2` refuses the install, because it would override the
  kit's `-f 1` and ADR 0006 says the kit never halts a host. The owner changes the line or uses
  `replace`.
- **Agents.** Install never restarts or reconfigures an agent. After the load it puts back the
  rules that were loaded at run time and came from no rule file, e.g. the Wazuh who-data rules.
  It finds them by key, and it doesn't put back a rule that has no key.
- **An org's own rules.** An org puts its own rule files in `/etc/audit/rules.d`, and install
  keeps them like any other file there. The file name sets the load order. There is no separate
  setting or directory for them.
- **Locked rules.** When the rules are locked until reboot (`-e 2`), install writes the files,
  skips the load, and prints `reboot=required`.
- **Survey.** `survey.sh` is removed. A small host check inside install replaces the survey and
  the preflight step.

This ADR supersedes 0003, 0022, and 0023. It removes `akit_accept` and `akit_extra_rules_dir`
from ADRs 0012 and 0024.

## Consequences

The curl install finishes on most hosts with no settings. An org's fleet tool calls `install.sh`
with flags and copies its own rule files to `rules.d`, and the kit needs no Ansible role.

auditd-kit no longer claims a list of supported systems. The README has a "Tested on" list that
matches CI, and RHEL-family systems are tested in containers only.

When a kept rule and a kit rule match the same event, the kernel uses only the key of the rule
that loaded first, so some events carry an org's key and not the kit's. A rule that differs from
a loaded rule only in its key loads too, and never fires.

With `-i`, a load at boot succeeds even when a line fails, so a rule that stops loading after a
kernel change is silent until someone runs `verify.sh`. Without `-i` the same line would drop
every rule after it.

`verify.sh` passes when at least as many rules are loaded as after the install, because copies
are skipped and agents add rules at run time.

On a host with locked rules, a problem in the new rule set shows only after the reboot, when
install can't roll back by itself. The install summary says so.

