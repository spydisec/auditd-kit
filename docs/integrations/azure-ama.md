# Send audit events to Microsoft Sentinel with Azure Monitor Agent

Azure Monitor Agent (AMA) collects syslog from rsyslog and sends it to a Log Analytics workspace,
where it lands in the `Syslog` table. auditd-kit doesn't send audit events (ADR 0026), so you turn
on the auditd syslog plugin by hand, and AMA collects the `local6` facility. This page is for
reference only. Check the steps against Microsoft's docs and your own setup before a rollout:

- [Collect Syslog events with Azure Monitor Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-syslog)
- [Forward Syslog data to Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/forward-syslog-monitor-agent)
- [Troubleshoot syslog with Azure Monitor Agent on Linux](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-linux-vm-rsyslog)

AMA can also collect `audit.log` as a custom text log into a custom table. The steps below use the
`Syslog` table, which Sentinel's Linux content expects.

## Steps

1. Check that the host can reach Azure:

   ```sh
   sh scripts/survey.sh --check azure
   ```

   It reports whether AMA or the legacy Log Analytics agent is installed, the proxy, and the DNS
   and TCP 443 results for the AMA control endpoint. The region and workspace endpoints show as
   `unknown` until AMA is installed and a DCR is associated, so run it again after step 4.

2. Install auditd-kit, e.g. `sh scripts/install.sh --profile medium`.

3. Turn on the auditd syslog plugin with the steps in
   [send-audit-log.md](send-audit-log.md#syslog-with-rsyslog-set-up-by-hand), with one change.
   AMA sends the events, so the rsyslog file only keeps them out of the local log files:

   ```
   if $syslogfacility-text == 'local6' then stop
   ```

   Name it `/etc/rsyslog.d/40-audit-local.conf`, so that it sorts after AMA's own file (see the
   gotchas).

4. Add a Syslog data source to a data collection rule (DCR) that sends to your Sentinel workspace.
   Set `LOG_LOCAL6` to minimum level `LOG_INFO`, which is the level the plugin writes at. Associate
   the DCR with the hosts.

5. Check that events arrive:

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

- The AMA rsyslog file must sort before your `40-audit-local.conf`, which ends with `stop`, so
  rsyslog files that sort after it never see the events. AMA 1.28 and later writes
  `/etc/rsyslog.d/10-azuremonitoragent-omfwd.conf`, which sorts first. Check the name on older AMA
  versions, which used a Unix socket instead of TCP.
- AMA forwards only the default rsyslog ruleset. Inputs bound to another ruleset don't reach
  AMA. With a central collector, bind its port 514 input to the default ruleset.
- Long records can be cut. An `EXECVE` record with many arguments can be longer than the
  rsyslog message size limit, which is 8k by default, so add `global(maxMessageSize="64k")` at
  the top of `/etc/rsyslog.conf` on each host.
- The `Syslog` table is billed on ingestion. Measure each profile first with `stats.sh`, and
  use a DCR transformation to drop records you don't need.
- Check the DCR definition, not the portal form. The portal clears the facility checkboxes when
  you reopen a DCR. The `facilityNames` property in the DCR definition shows what is collected.

## Not covered

Sentinel parsers, analytics rules, and DCR templates aren't part of auditd-kit. The CEF connector
doesn't apply, because audit records aren't in CEF format.
