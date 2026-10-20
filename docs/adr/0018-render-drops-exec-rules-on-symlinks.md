# 0018. Render drops exec rules on symlinks

Status: Accepted
Date: 2026-10-20

## Context

The kernel matches a `-F path=` or `-F exe=` rule on the inode of the path itself, and doesn't
follow a symlink. Exec reaches the link's target, so an exec rule on a symlink never fires. Many
tools are links on some distros: `iptables` on every supported distro, `yum` on RHEL 8 and later,
and `snap` on Ubuntu 24.04.

## Decision

Render drops a `-F exe=` rule, or a `-F path=` rule with `-F perm=x`, when its file is a symlink on
the host. It lists each one in the render report with the reason `symlink`. A path rule with
another `perm` stays, because it can match changes to the link itself.

The rule files name the targets as well as the links, e.g. `xtables-nft-multi` next to the
`iptables` tools.

## Consequences

A tool that is a link on one distro shows up in the render report instead of loading a rule that
never fires. A new exec rule must name the real file on each distro.
