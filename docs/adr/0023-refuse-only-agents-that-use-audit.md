# 0023. Refuse only agents that use the audit system

Status: Accepted
Date: 2026-10-26

## Context

Install refused every host where survey found Microsoft Defender for Endpoint (MDE), CrowdStrike
Falcon, Wazuh, Auditbeat, Splunk UF, or osquery, even when the agent doesn't touch the audit
system. On fleets with one of these agents on most hosts, operators had to override every host.

Each vendor's docs show that most of these agents conflict with auditd-kit only in one setup:

| Agent | Conflicts when |
|---|---|
| Wazuh | Who-data FIM is on (`whodata="yes"`). Wazuh adds `wazuh_fim` watch rules with auditctl when it starts, and our `-D` deletes them. |
| MDE | An old version still uses auditd. eBPF has been the default since 101.23082.0006, and auditd isn't supported since 101.2408.0000. Old versions write `/etc/audit/rules.d/mdatp.rules`. |
| Auditbeat | Its config defines audit rules or sets `socket_type: unicast`. It then takes the audit socket for itself and deletes every loaded rule. With no rules, it uses multicast and runs next to auditd. |
| osquery | Audit-based process events are on (`disable_audit=false`, default `true`). osquery then needs the audit socket for itself. |
| Splunk UF | Never. It reads `audit.log` as a file. |
| CrowdStrike | No known conflict. The sensor uses eBPF or its own kernel module, and no public CrowdStrike doc says it uses the audit system. |

## Decision

Survey keeps listing every agent it finds in `agents`, and adds `agents_audit`, which lists only
the agents that use the audit system in a way that conflicts with auditd-kit. It checks each
agent's config files and processes. When it can't read a config file it needs, it counts the agent
as a conflict.

Preflight refuses with `agent_conflict:<agent>` only for agents in `agents_audit`. The override is
still `akit_accept_agents`. Splunk UF and CrowdStrike never refuse.

When install loads rules on a host where it accepted Wazuh with who-data on, it says to restart
wazuh-agent, so that Wazuh adds its rules again.

## Consequences

Most hosts with MDE, CrowdStrike, Splunk UF, or osquery now install without an override. If a
vendor changes how its agent uses audit, the survey check for that agent must change too.
Confirm the CrowdStrike row with CrowdStrike support.

Adding auditd-kit's rules next to an agent's rules, without `-D`, is still open (#47).
