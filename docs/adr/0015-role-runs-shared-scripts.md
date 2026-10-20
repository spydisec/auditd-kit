# 0015. The role runs the shared scripts on targets

Status: Accepted
Date: 2026-10-20

## Context

The survey, preflight, render, plan, backup, and verify steps must give the same results whether
an operator uses the script path or the Ansible role. Writing them again as Ansible tasks or
Python modules would give two versions of each to keep in step.

## Decision

The role copies the kit's `rules/`, `config/`, and `scripts/` to a temp dir on each host and runs
the scripts there. It uses Ansible's own modules only to write files, run handlers, and collect
results. The collection build copies those three dirs into the role, so the collection tarball
holds the same files as the script path.

## Consequences

There is no Python logic to keep in step with the shell, and a bug fixed in a script is fixed for
both paths. Each host needs a writable temp dir, and every run copies the files there and removes
them at the end.
