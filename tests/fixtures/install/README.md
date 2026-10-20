# Install fixture

A host with auditd installed but not yet set up by auditd-kit. The tests copy it over the
`hosts/ubuntu2404` fixture. The files mirror the structure of the Ubuntu 24.04 defaults, not their
exact text. It has rsyslog and the auditd syslog plugin (inactive), so forwarding tests can run.
