# auditd-kit

auditd-kit turns on Linux audit logging (auditd) across a fleet with safe defaults. It ships plain rule and
configuration files, POSIX shell scripts, and an Ansible collection, so you can use the files by hand, run the
scripts on a single host, or roll the change out with Ansible.

Its defaults are meant not to harm the host. For example, no setting makes the machine halt or drop to single-user
mode when audit logging has a problem.

## Status

auditd-kit is at version `0.x` and is not ready for production use. Interfaces and defaults may change between
releases. A quickstart will be added to this file once the scripts and the Ansible collection are in place.

## Supported systems

- Red Hat Enterprise Linux 7, 8, and 9, tested on CentOS 7, Rocky Linux 8, and Rocky Linux 9
- Ubuntu 22.04 and 24.04

## More information

The decisions behind the design are recorded in [docs/adr/](docs/adr/). See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to propose a change and [SECURITY.md](SECURITY.md) for how to report a security problem.

## Licence

Apache-2.0. See [LICENSE](LICENSE). Files copied from other projects keep their own licence file next to them. [AI-DECLARATION.md](AI-DECLARATION.md) says how AI tools are used to build auditd-kit.
