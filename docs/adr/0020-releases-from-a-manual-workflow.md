# 0020. Releases from a manual workflow

Status: Accepted
Date: 2026-10-20

## Context

ADR 0008 chose release-please to keep a release PR. A PR that a workflow opens with the built-in
`GITHUB_TOKEN` doesn't start other workflows, so the required checks never run on it and it can't
be merged. Fixing that needs a personal access token or a GitHub App, which is one more secret to
manage.

## Decision

The trunk-based workflow from ADR 0008 stays: short-lived branches, PRs into a protected `main`,
squash merges, and Conventional Commits PR titles.

A maintainer releases by running the `release` workflow by hand on `main`, with the version as
`X.Y.Z`. The workflow:

1. builds the offline bundle, the collection tarball, and `SHA256SUMS` with
   `scripts/dev/build-release.sh`, which writes the version into both tarballs
2. attests the tarballs with GitHub build provenance
3. creates the `vX.Y.Z` tag and the release, with notes generated from the merged PR titles

The repo itself keeps version `0.0.0`. Versions follow SemVer, and we stay on `0.x` until the v1
definition of done is met.

## Consequences

No extra token is needed, because one workflow run builds, tags, and publishes. Operators check
downloads with `sha256sum -c SHA256SUMS` or `gh attestation verify`. There is no CHANGELOG file in
the repo. The release notes are the changelog.
