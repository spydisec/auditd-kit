# 0004. Keep logs local by default and forward through one added file

Status: Superseded by 0026
Date: 2026-10-19

## Context

Hosts often already have an rsyslog configuration that sends logs somewhere, and other agents may
add their own rsyslog files. If we edit or replace that configuration, existing log flows can break
without anyone noticing.

## Decision

By default, audit logs stay in `/var/log/audit`, and the auditd syslog plugin is installed but
inactive. Forwarding is opt-in. When an operator turns it on, auditd-kit adds one file,
`/etc/rsyslog.d/40-auditd-kit.conf`, which matches only the chosen syslog facility.
auditd-kit never edits `/etc/rsyslog.conf`, never changes another rsyslog file, and never installs
or upgrades rsyslog.

Before restarting rsyslog, the installer checks the new configuration with `rsyslogd -N1`. If the
check fails, it removes the file and leaves rsyslog alone. The installer refuses to proceed when
the facility is already in use or when a catch-all forward would also pick up audit events, unless
the operator overrides that condition.

## Consequences

Any SIEM that takes syslog works, and a local agent such as Azure Monitor Agent reads the facility
through its own rsyslog file, which auditd-kit doesn't write. Hosts that use only syslog-ng or
journald don't get automatic forwarding in v1, and the manual guide covers them.
