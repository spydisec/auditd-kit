# Raise Wazuh alerts for auditd-kit events

A Wazuh agent that reads `audit.log` sends every audit event to the manager, and the manager
decodes it. But Wazuh's own rules only raise alerts for its `audit-wazuh-*` keys. Every other audit
event matches rule 80700 at level 0, so it raises no alert and doesn't show in the dashboard unless
the archives are on. `config/wazuh/auditd-kit-rules.xml` adds one rule for each auditd-kit key, with
an alert level and, where one applies, a MITRE ATT&CK ID. Tested with Wazuh 4.12.

## Steps

1. On each host, check that the Wazuh agent reads `audit.log`. `/var/ossec/etc/ossec.conf` needs
   this block, and the agent needs a restart after you add it:

   ```xml
   <localfile>
     <log_format>audit</log_format>
     <location>/var/log/audit/audit.log</location>
   </localfile>
   ```

2. On the Wazuh manager, copy the rules file and restart the manager. In a cluster, do this on the
   master node, which syncs the rules to the workers.

   ```sh
   cp config/wazuh/auditd-kit-rules.xml /var/ossec/etc/rules/
   chown wazuh:wazuh /var/ossec/etc/rules/auditd-kit-rules.xml
   systemctl restart wazuh-manager
   ```

   The rules use IDs 100800 to 100899. If your manager already uses them, change the IDs in the
   file.

3. Check the result. Run `sh scripts/verify.sh` on a host. Its canary write raises rule 100800,
   "auditd-kit canary written by verify.sh", for that agent. If the alert shows up, events travel
   from the host to the dashboard.

To test one event on the manager without a host, paste an audit line into
`/var/ossec/bin/wazuh-logtest`.

## Alert levels

| Level | Keys |
|---|---|
| 12 | `T1055` injection, `T1611` container escape, `T1620` and `exec_from_shm` code run from memory, `kexec` |
| 10 | `T1562` impair defenses, `T1556` authentication, `T1574` library hijack, `T1070` indicator removal, `T1505` service started a program, `exec_from_tmp` |
| 8 | Accounts, scheduled jobs, services, kernel modules, shell startup files, boot scripts, sniffing, `power_abuse` |
| 5 | `T1548` privilege elevation, time, sysctl, mounts, `fstab`, swap, network settings, containers, bpf |
| 3 | `T1059` commands by logged-in users, package tools, network connections, and the canary, plus the low-risk `heavy` keys, e.g. permission changes and login records |

Change a level in the file to suit your SOC. Keep in mind that the rules don't change how much the
agent ships. The agent sends every line of `audit.log`, so the profile you install sets the volume.

## Notes

- `node=<hostname>` at the start of each line is fine, because Wazuh's audit decoder accepts it.
- Wazuh who-data adds its own audit rules, and install deletes them. See ADR 0023.
- `tests/bats/rules.bats` fails when a rule key has no Wazuh rule, so the file stays in step with
  the profiles.
