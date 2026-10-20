# 0016. Supported ansible-core versions

Status: Accepted
Date: 2026-10-20

## Context

CentOS 7 hosts have Python 2.7, and Rocky 8 hosts often have only the platform Python 3.6.
ansible-core 2.17 and later can't manage either.

## Decision

The collection supports ansible-core 2.16 and later. CI runs the role with 2.16 against CentOS 7,
Rocky 8 and 9, and Ubuntu 22.04 and 24.04, and with the latest release against Rocky 9 and both
Ubuntu versions.

## Consequences

ansible-core 2.16 is past its end of life, and it is kept only for CentOS 7 and Rocky 8 hosts with
platform Python. An operator who installs a newer Python on Rocky 8 can use a current release. When
the last CentOS 7 and Rocky 8 hosts are gone, a later ADR can drop 2.16.
