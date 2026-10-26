# Send audit events to Microsoft Sentinel with Azure Monitor Agent

auditd-kit sends audit events to rsyslog on a syslog facility, `local6` by default. Azure Monitor
Agent (AMA) reads them from rsyslog and sends them to a Log Analytics workspace, where they land in
the `Syslog` table. This page is for reference only. Check the steps against Microsoft's docs and
your own setup before a rollout:

- [Collect Syslog events with Azure Monitor Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-syslog)
- [Forward Syslog data to Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/forward-syslog-monitor-agent)
- [Troubleshoot syslog with Azure Monitor Agent on Linux](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-linux-vm-rsyslog)

## Layouts

Use one of these layouts:

| Layout | auditd-kit settings | Where AMA runs |
|---|---|---|
| AMA on each host | `akit_forward=local` | On every host |
| Central collector | `akit_forward=remote` and `akit_remote_host=<collector>` | Only on the collector, which runs rsyslog and listens on port 514 |

With `local`, the auditd-kit rsyslog file keeps the events out of `/var/log/messages` and
`/var/log/syslog`, and AMA forwards them. With `remote`, the collector must keep the facility, and
it must accept messages as long as the ones the hosts send (see the message size gotcha below).

## Steps

1. Check that the host can reach Azure:

   ```sh
   sh scripts/survey.sh --check azure
   ```

   It reports whether AMA or the legacy Log Analytics agent is installed, the proxy, and the DNS
   and TCP 443 results for the AMA control endpoint. The region and workspace endpoints show as
   `unknown` until AMA is installed and a DCR is associated, so run it again after step 3.

2. Install with forwarding on. Forwarding needs the auditd syslog plugin (`audispd-plugins`), and
   install refuses with `syslog_plugin_missing` without it. For example, for AMA on each host:

   ```sh
   sh scripts/install.sh --profile medium --forward local
   ```

3. Add a Syslog data source to a data collection rule (DCR) that sends to your Sentinel workspace.
   Set `LOG_LOCAL6`, or the facility in `akit_syslog_facility`, to minimum level `LOG_INFO`. The
   auditd syslog plugin writes at `LOG_INFO`. Associate the DCR with the hosts, or with the
   collector in the central layout.

4. Check that events arrive:

   ```kusto
   Syslog
   | where Facility == "local6"
   | where TimeGenerated > ago(15m)
   | project TimeGenerated, Computer, SyslogMessage
   | take 20
   ```

   Each `SyslogMessage` starts with `node=<hostname>` and then `type=`, because install sets
   `name_format = hostname`. A parser should allow for the `node=` prefix.

## Gotchas

- The AMA rsyslog file must sort before `40-auditd-kit.conf`. The auditd-kit file ends with
  `stop`, so rsyslog files that sort after it never see the events. AMA 1.28 and later writes
  `/etc/rsyslog.d/10-azuremonitoragent-omfwd.conf`, which sorts first. Check the name on older AMA
  versions, which used a Unix socket instead of TCP.
- AMA forwards only the default rsyslog ruleset. Inputs bound to another ruleset don't reach
  AMA. On a collector, bind the port 514 input to the default ruleset.
- Long records can be cut. An `EXECVE` record with many arguments can be longer than the
  rsyslog message size limit, which is 8k by default. With `remote`, auditd-kit sets
  `maxMessageSize` to 64k on the hosts, so set the same value on the collector. With `local`,
  auditd-kit doesn't change the limit, so add `global(maxMessageSize="64k")` at the top of
  `/etc/rsyslog.conf` on each host.
- The `Syslog` table is billed on ingestion. Measure each profile first with `stats.sh`, and
  use a DCR transformation to drop records you don't need.
- Check the DCR definition, not the portal form. The portal clears the facility checkboxes when
  you reopen a DCR. The `facilityNames` property in the DCR definition shows what is collected.

## Not covered

Sentinel parsers, analytics rules, and DCR templates aren't part of auditd-kit. The CEF connector
doesn't apply, because audit records aren't in CEF format.
