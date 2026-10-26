# Send audit.log to your SIEM

auditd-kit writes audit events to `/var/log/audit/audit.log` and doesn't send them anywhere (ADR
0026). Use the agent or syslog setup you already have. Each record starts with `node=<hostname>`
and then `type=`, because install sets `name_format = hostname`, so a parser should allow for the
`node=` prefix.

This page is for reference only. Check each step against your agent's docs before a rollout.

## Agents that read audit.log

| Agent | What to set |
|---|---|
| Wazuh | A `localfile` block with `log_format` `audit`. See [wazuh.md](wazuh.md). |
| Splunk Universal Forwarder | A `[monitor:///var/log/audit/audit.log]` input with `sourcetype = linux:audit`, which the Splunk Add-on for Unix and Linux parses. |
| Elastic Agent or Filebeat | The Auditd Logs integration, or the Filebeat `auditd` module. Both read `audit.log`. |
| Fluent Bit | A `tail` input on `/var/log/audit/audit.log`. |
| Azure Monitor Agent | See [azure-ama.md](azure-ama.md). |

`audit.log` is readable by root only. An agent that runs as another user, e.g. Splunk UF 9.1 and
later as `splunkfwd`, needs read access, so follow the agent's own docs for that.

The agent sends every line of `audit.log`, so the profile you install sets the volume. Run
`sh scripts/stats.sh` to measure it before a rollout.

## Syslog with rsyslog, set up by hand

Use these steps when no agent on the host reads files and your SIEM takes syslog. The auditd syslog
plugin sends each audit record to rsyslog on the `local6` facility, and one rsyslog file sends that
facility on and keeps it out of the local log files.

1. Check that nothing else on the host uses `local6`, and that no other rsyslog file sends every
   facility (`*.*`) to a server, because that file would send the audit events as well.

2. Install the auditd syslog plugin. It's in the `audispd-plugins` package on most systems, and
   RHEL 7 has it built in.

3. Add `/etc/rsyslog.d/40-audit-forward.conf`, with your collector's name, port, and protocol. The
   queue keeps events on disk while the collector is down:

   ```
   if $syslogfacility-text == 'local6' then {
     action(type="omfwd" target="siem.example.com" port="514" protocol="tcp"
            queue.type="LinkedList" queue.filename="audit-forward" queue.maxDiskSpace="1g"
            queue.saveOnShutdown="on" action.resumeRetryCount="-1")
     stop
   }
   ```

   The file must sort before the files that write `/var/log/syslog` or `/var/log/messages`, e.g.
   Ubuntu's `50-default.conf`, so that `stop` keeps the events out of them. A long `EXECVE` record
   can be longer than rsyslog's 8k limit, so add `global(maxMessageSize="64k")` at the top of
   `/etc/rsyslog.conf`, and set the same limit on the collector.

4. Check the config and restart rsyslog:

   ```sh
   rsyslogd -N1 && service rsyslog restart
   ```

5. Turn on the plugin last, so that no audit event reaches the local log files before the filter
   is in place. In `/etc/audit/plugins.d/syslog.conf`, or `/etc/audisp/plugins.d/syslog.conf` on
   RHEL 7 and Ubuntu 18.04 and 20.04, set these two lines, then run `service auditd restart`:

   ```
   active = yes
   args = LOG_INFO LOG_LOCAL6
   ```

6. Run `sh scripts/verify.sh`, which checks that auditd records events on the host but not that
   they reach the collector. Then look for the `akit_canary` event at your collector, and check
   that `/var/log/syslog` or `/var/log/messages` gets no `type=` records.

`install.sh` leaves the plugin and your rsyslog file as they are on later runs. `rollback.sh`
puts `/etc/audit` back as it was before the install it undoes, so after a rollback, set the plugin
again.

To undo, set `active = no` in the plugin file and run `service auditd restart`, then remove the
rsyslog file and restart rsyslog.

## Syslog with syslog-ng

See [syslog-ng.md](syslog-ng.md).
