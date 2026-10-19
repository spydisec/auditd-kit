# Syscall fixtures

Each file lists the syscall names that `ausyscall --dump` knows on one OS, one name per line.
`<os>-b64.txt` stands in for `ausyscall x86_64 --dump` and `<os>-b32.txt` for
`ausyscall i386 --dump`. The names come from `lib/x86_64_table.h` and `lib/i386_table.h` in
linux-audit/audit-userspace, at the tag for the audit version that OS ships.

| Fixture | audit-userspace tag |
|---|---|
| centos7 | v2.8.5 |
| rocky8 | v3.1.2 |
| rocky9 | v3.1.5 |
| ubuntu2204 | v3.0.7 |
| ubuntu2404 | v3.1.2 |

To rebuild the files, run `sh scripts/dev/update-syscall-fixtures.sh` and commit the result.
