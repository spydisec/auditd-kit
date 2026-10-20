# 0013. auditd-kit doesn't install packages

Status: Accepted
Date: 2026-10-20

## Context

Clients control their own repositories and their change windows. Many hosts have no route to a
repository, and a package install can pull in other updates or restart services that the client
did not plan to touch.

## Decision

auditd-kit never calls a package manager. Preflight refuses when auditd is missing, and when
forwarding is on and the syslog plugin is missing (`audispd-plugins` on Ubuntu). The refusal tells
the operator to install the package from their own repositories and run again.

## Consequences

A host that lacks a package needs one manual step before the first run. In return, auditd-kit
works on air-gapped hosts, and it never changes the package set or versions on a client host.
