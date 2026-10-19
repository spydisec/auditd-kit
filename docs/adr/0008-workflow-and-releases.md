# 0008. Trunk-based workflow and verifiable release bundles

Status: Accepted
Date: 2026-10-19

## Context

The project is small and public. A long-lived `dev` branch would add merges without adding safety.
Operators on networks without internet access need to check the files they download.

## Decision

All work goes through short-lived branches and PRs into a protected `main`. `main` requires the CI
checks to pass and allows only squash merges and linear history. PR titles follow Conventional
Commits, and CI checks them.

release-please keeps a release PR with the changelog and the version. Merging it tags `vX.Y.Z`, and
the release workflow publishes the offline tarball, the collection tarball, `SHA256SUMS`, and
GitHub build provenance attestations. Versions follow SemVer, and we stay on `0.x` until the v1
definition of done is met.

## Consequences

Operators can check downloads with `sha256sum -c` or `gh attestation verify`, so we don't need to
manage GPG keys. Every change, including documentation, needs a PR.
