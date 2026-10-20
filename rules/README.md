# Audit rules

Pick a profile with `akit_profile` (flag `--profile`). Each profile loads the files of the
profiles before it, so log volume grows from `minimal` to `heavy`.

| Profile | Files | Use it for |
|---|---|---|
| `minimal` (default) | `00-base.rules`, `10-minimal.rules`, `90-minimal-last.rules` | Every server. |
| `medium` | adds `20-medium.rules`, `91-medium-last.rules` | Critical servers. It logs the commands that logged-in people run. |
| `heavy` | adds `30-heavy.rules` | Hosts that must meet CIS or STIG audit checks. |

`00-base.rules` sets the audit system itself and holds the canary rule that verify uses.
The kernel gives an event the key of the first rule that matches it. So the broad command rules
sit in the two `-last` files, which load after every rule that names a program (ADR 0017).
`99-finalize.rules` turns on immutable mode, and render adds it only when `akit_immutable` is true.

## Overlay rules

You can add your own rules without editing these files. Put them in a directory of your own, and
set `akit_extra_rules_dir` (flag `--extra-rules-dir`) to it. Name each file `50-*.rules`, e.g.
`50-site.rules`, so it loads after the profile files and before the `-last` files. A broad rule in
an overlay file, such as one for every command, takes the key of the events that the `-last` files
would have keyed.

Overlay files must not hold control lines, which are `-D`, `-b`, `-f`, `-e`, `-r`, `-i`,
`--backlog_wait_time`, and `--loginuid-immutable`. Render removes them from overlay files and lists
each one in the render report.

## Credits

The rules are our own, and no text or rules are copied from these sources. We took ideas from:

- [Neo23x0/auditd](https://github.com/Neo23x0/auditd)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks) for RHEL and Ubuntu
- [DISA STIGs](https://public.cyber.mil/stigs/)
- [audit-userspace sample rules](https://github.com/linux-audit/audit-userspace/tree/master/rules)
- [Graylog Illuminate Linux auditd content pack](https://go2docs.graylog.org/illuminate-current/content_packs/linux_auditd_content_pack.htm)
- [MITRE ATT&CK](https://attack.mitre.org/), for the rule key names
- [certeu/ansible-auditd-laurel](https://github.com/certeu/ansible-auditd-laurel)
- [ndaal_public_auditd](https://gitlab.com/ndaal_open_source/ndaal_public_auditd), for its notes on rule order

If you want audit logs as JSON, use [Laurel](https://github.com/threathunters-io/laurel). It runs as
an auditd plugin and writes each event as one JSON line to its own log file.
