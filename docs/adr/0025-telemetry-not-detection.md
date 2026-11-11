# 0025. Telemetry, not detection

Status: Accepted
Date: 2026-10-26

## Context

auditd-kit records audit events and ships them to a SIEM. Once the events reach a SIEM, the next
requests are about detection: alert levels, what counts as suspicious, allowlists for normal
activity, and alerts that combine several events. Each environment has its own normal activity, so
detection work never ends, and it would pull auditd-kit away from what it does well.

## Decision

auditd-kit owns the telemetry, and the SIEM owns detection.

auditd-kit owns:

- the profiles and rules, which decide what gets recorded on which hosts
- the keys, which name each kind of event and carry a MITRE ATT&CK ID where one fits
- rollout, verify, rollback, and log volume

The SIEM and the people who run it own:

- deciding what is malicious, alert thresholds, and how events are combined
- allowlists for one environment
- detection content such as Sigma rules, and the response to an alert

The keys are auditd-kit's interface to every SIEM. Renaming or removing a key is a breaking change,
and the release notes list it.

SIEM integrations in `config/<siem>/` and `docs/integrations/` only make auditd-kit events visible
and labeled in that SIEM. They map each key to a default alert level, based on the key's risk, and
to its MITRE ID. They hold no behavior logic and no correlation, and the docs say the levels are
defaults to change.

auditd-kit suppresses only noise that it causes itself, e.g. the `auditctl -s` that `verify.sh`
runs. Noise from a site's own software is the site's to tune, in its SIEM rules or with
`akit_skip_keys`. A site can also put an exclusion in its own file in `/etc/audit/rules.d/`. The
kernel uses the first rule that matches, so a file that sorts before `10-` reaches every profile
rule, and a `50-` file only reaches the broad rules in the `90-*-last` and `91-*-last` files.

## Consequences

Requests for new alerts or event correlation go to the SIEM's own rules or to Sigma, not into
auditd-kit. Each new SIEM integration follows the same pattern as the Wazuh one, and a test keeps
it in step with the rule keys. Each integration doc shows how to quiet a site's own noise in that
SIEM.
