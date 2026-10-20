# spydisec.auditd_kit

Ansible collection for auditd-kit. The `auditd` role copies the kit's shell scripts to each host
and runs them, so the Ansible path and the script path give the same results.

Playbooks:

- `spydisec.auditd_kit.survey` runs `survey.sh` on each host and writes one CSV for the fleet
  (`akit_survey_csv`, default `survey.csv`).
- `spydisec.auditd_kit.stats` runs `stats.sh` on each host and writes the audit volume per day
  (`akit_stats_csv`, default `stats.csv`).

The settings are the `akit_*` variables in `roles/auditd/defaults/main.yml`. They match the script
path's settings. See the main README at https://github.com/spydisec/auditd-kit for the details.

ansible-core 2.16 manages CentOS 7 and Rocky 8 hosts that only have their platform Python. Newer
releases manage the rest.
