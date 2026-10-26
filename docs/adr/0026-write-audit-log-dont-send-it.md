# 0026. Write audit.log, and don't send it

Status: Accepted
Date: 2026-10-26

## Context

auditd-kit could forward audit events through rsyslog (ADR 0004). It turned on the auditd syslog
plugin and added one rsyslog drop-in, and preflight had four refusals to keep that safe:
`no_rsyslog`, `syslog_plugin_missing`, `facility_in_use`, and `catchall_forward`. Forwarding
changes how the whole host logs, so it was the riskiest change auditd-kit made.

Most sites already send logs with their own agent, e.g. Wazuh, Splunk UF, Azure Monitor Agent,
Elastic Agent, or Fluent Bit, and each of these can read `/var/log/audit/audit.log` directly. On the
first pilot host, the Wazuh agent read `audit.log`, and forwarding wasn't used. v0.3.0 hasn't been
released, so the `akit_forward` URL setting from ADR 0024 can still go without a deprecation period.

## Decision

auditd-kit writes audit events to `audit.log` and doesn't send them anywhere. The site's own agent
or syslog setup sends them to its SIEM, the same way the SIEM owns detection (ADR 0025).

v0.3.0 removes `akit_forward`, `akit_syslog_facility`, the four forwarding refusals, the
`catchall_forward` accept code, and the survey's rsyslog checks. Nine settings are left. A config
that sets a removed setting fails with a message that points to
`docs/integrations/send-audit-log.md`.

auditd-kit still owns what makes `audit.log` easy to ship: the log file size and count, the
`node=<hostname>` prefix on each record, and the keys. The survey still reports the syslog daemon
and the agents, so an operator can see what could ship the logs.

A host where an earlier version turned forwarding on gets cleaned up. When the state file shows
`forward=local` or `forward=remote` and `/etc/rsyslog.d/40-auditd-kit.conf` is still there, install
sets the syslog plugin to inactive and removes the drop-in, after the backup. The plan lists both
changes, and install logs a warning that names `docs/integrations/send-audit-log.md`. A plugin
that the operator set up again by hand is left as it is.

## Consequences

auditd-kit no longer edits the syslog plugin or rsyslog on a new install, so it can't change where
the host's other logs go. A site that sends logs only by syslog sets up rsyslog or syslog-ng by
hand, and `docs/integrations/send-audit-log.md` gives the steps. The cleanup code stays until no
supported upgrade path starts from 0.2.0 or earlier.

ADR 0004 is superseded, and so is the forwarding part of ADR 0024.
