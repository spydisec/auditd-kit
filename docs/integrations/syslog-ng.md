# Forward audit events with syslog-ng

auditd-kit doesn't send audit events (ADR 0026). On a host that runs syslog-ng, set up sending by
hand once, with these steps. They were tested on Rocky Linux 10 with syslog-ng 4.8.

The setup needs two things that a single drop-in can't do:

- syslog-ng reads `conf.d/` at the end of its main config, after its own log paths, so a drop-in
  can't keep audit events out of `/var/log/messages` or `/var/log/syslog`. You need one edit in
  the main config.
- On RHEL, SELinux doesn't let syslog-ng read `/var/log/audit/audit.log`, so the events must come
  from the auditd syslog plugin.

## Steps

The auditd syslog plugin must be installed: `audispd-plugins` on RHEL and Ubuntu. Turn the plugin
on last, so that no audit event reaches the system log files before the filters are in place.

1. Install auditd-kit:

   ```sh
   sh scripts/install.sh --profile minimal
   ```

   If auditd-kit 0.2.0 or earlier turned on forwarding on this host, this run turns the plugin off.
   Do it before the next steps, and later runs leave the plugin as it is.

2. Keep `local6` out of the system log files. In `/etc/syslog-ng/syslog-ng.conf`, add
   `not facility(local6) and` at the start of the expression in each catch-all filter:

   | System | Filters |
   |---|---|
   | RHEL (EPEL syslog-ng) | `f_default` |
   | Ubuntu | `f_syslog3` and `f_messages` |

   For example, the stock RHEL filter becomes:

   ```
   filter f_default    { level(info..emerg) and not facility(local6) and
                           not (facility(mail)
                           or facility(authpriv)
                           or facility(cron)); };
   ```

3. Add `/etc/syslog-ng/conf.d/40-auditd-kit.conf`. Use the system source name from the main
   config: `s_sys` on RHEL, `s_src` on Ubuntu. Change the host, port, and transport to your
   collector's:

   ```
   # Audit events from the auditd syslog plugin, on facility local6.
   filter f_auditd_kit { facility(local6); };
   destination d_auditd_kit { network("siem.example.com" port(514) transport("tcp")); };
   log { source(s_sys); filter(f_auditd_kit); destination(d_auditd_kit); flags(final); };
   ```

4. Check the config and restart syslog-ng:

   ```sh
   syslog-ng --syntax-only && systemctl restart syslog-ng
   ```

5. Turn on the plugin. Its file is `/etc/audit/plugins.d/syslog.conf`, or
   `/etc/audisp/plugins.d/syslog.conf` on RHEL 7. Set these two lines, then run
   `service auditd restart`:

   ```
   active = yes
   args = LOG_INFO LOG_LOCAL6
   ```

6. Check the result. `sh scripts/verify.sh` should pass, your collector should get `type=` audit
   records, and `/var/log/messages` (or `/var/log/syslog`) should get none.

## Undo

1. Set `active = no` in the plugin file, and run `service auditd restart`.
2. Remove the drop-in and the `not facility(local6) and` edits, and restart syslog-ng.
