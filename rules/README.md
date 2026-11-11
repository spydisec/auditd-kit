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

## Your own rules

Put your own rule files in `/etc/audit/rules.d/`, under any name that ends in `.rules`. Install
keeps every file there that it didn't write, and loads it with the kit's files. Don't edit the
kit's files, because the next install overwrites them.

The files load in name order, and the first rule that matches an event sets its key:

- A file that sorts before `10-auditd-kit-minimal.rules`, e.g. `05-site.rules`, wins over the
  profile rules. Put a rule that excludes a noisy program there.
- A file that sorts between the profile files and `90-`, e.g. `50-site.rules`, adds rules, and
  still loads before the broad command rules in the `-last` files.

Install doesn't check your files before the load. The kit loads with `-i`, so a line of yours that
the kernel rejects is skipped, and install logs a warning that names the file and the rule. A rule
that is a copy of a loaded rule is skipped too.

## Skip rules on a host

To leave kit rules out on a host, list their keys in `akit_skip_keys` (flag `--skip-keys`), e.g.
`akit_skip_keys=exec_from_tmp,network_connect`. Render drops every rule with those keys from the
profile files and lists each one in the render report as `skipped`. It never skips the rules in
`00-base.rules`, which verify needs, or rules in your own files.

Render refuses a key that no profile rule uses, so a typo can't pass for a skipped rule. A key from
a bigger profile is accepted, so one setting can serve hosts on different profiles.

## Load the rules without install.sh

Don't copy these files into `/etc/audit/rules.d/` as they are. `00-base.rules` holds a placeholder
for the backlog size, and some rules name syscalls, programs, or paths that a host may not have.
`auditctl` stops at the first rule it can't load, so every rule after that one is lost.

Render the rules on the target host instead. Render changes nothing on the host. It writes files
that load there, and a report that lists each rule it dropped or trimmed, with the reason:

```sh
sh scripts/render.sh --profile minimal --size standard \
  --out-dir /tmp/akit-rules --report /tmp/akit-report.txt
```

Then copy the rendered files into `/etc/audit/rules.d/` and run `augenrules --load`. `install.sh`
does all of this for you. It also backs up the files it changes, checks the result, and rolls
back if a check fails.

Write each rule on one line. Rule files have no line continuation, so a rule split with `\` fails
to load.

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
