repo: https://github.com/Neo23x0/auditd
commit: 6111069472c26c4120002933b67cef9855dfbad5
file: audit.rules
sha256: 922b43e7b7c4ce386749a0e63c3a228a13854277de2ef092eddb536a8fa4142e
licence: Apache-2.0

upstream/audit.rules is an unmodified copy of audit.rules at that commit, and render strips its control lines.

To update the pin, run `sh scripts/dev/update-standard.sh <commit>` and commit the result.
The pull request must add a "Volume impact" note to the changelog, because new upstream
rules can change how many events a host writes.
