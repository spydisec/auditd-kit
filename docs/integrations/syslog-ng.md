# Forward audit events with syslog-ng

`install.sh` forwards audit events only through rsyslog (ADR 0004). On a host that runs syslog-ng,
set it up by hand once, with these steps. They were tested on Rocky Linux 10 with syslog-ng 4.8.

auditd-kit can't do this for you, for two reasons:

- syslog-ng reads `conf.d/` at the end of its main config, after its own log paths, so a drop-in
  can't keep audit events out of `/var/log/messages` or `/var/log/syslog`. You need one edit in
  the main config.
- On RHEL, SELinux doesn't let syslog-ng read `/var/log/audit/audit.log`, so the events must come
  from the auditd syslog plugin.

## Steps

1. Install with forwarding off, which is the default:

   ```sh
   sh scripts/install.sh --profile minimal
   ```

2. Turn on the auditd syslog plugin. Its file is `/etc/audit/plugins.d/syslog.conf`, or
   `/etc/audisp/plugins.d/syslog.conf` on RHEL 7. Set these two lines, then run
   `service auditd restart`:

   ```
   active = yes
   args = LOG_INFO LOG_LOCAL6
   ```

   A later `install.sh` run with forwarding off leaves the plugin as it is.

3. Keep `local6` out of the system log files. In `/etc/syslog-ng/syslog-ng.conf`, add
   `and not facility(local6)` to the catch-all filters:

   | System | Filters |
   |---|---|
   | RHEL (EPEL syslog-ng) | `f_default` |
   | Ubuntu | `f_syslog3` and `f_messages` |

   For example, on RHEL:

   ```
   filter f_default    { level(info..emerg) and not facility(local6) and
   ```

4. Add `/etc/syslog-ng/conf.d/40-auditd-kit.conf`. Use the system source name from the main
   config: `s_sys` on RHEL, `s_src` on Ubuntu. Change the host, port, and transport to your
   collector's:

   ```
   # Audit events from the auditd syslog plugin, on facility local6.
   filter f_auditd_kit { facility(local6); };
   destination d_auditd_kit { network("siem.example.com" port(514) transport("tcp")); };
   log { source(s_sys); filter(f_auditd_kit); destination(d_auditd_kit); flags(final); };
   ```

5. Check the config and restart syslog-ng:

   ```sh
   syslog-ng --syntax-only && systemctl restart syslog-ng
   ```

6. Check the result. `sh scripts/verify.sh` should pass, your collector should get `type=` audit
   records, and `/var/log/messages` (or `/var/log/syslog`) should get none.

To undo it, remove the drop-in, take `and not facility(local6)` out of the filters, set
`active = no` in the plugin file, and restart syslog-ng and auditd.
