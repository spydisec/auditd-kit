#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
rules="$repo/rules"
base="$rules/00-base.rules"
minimal="$rules/10-minimal.rules"
medium="$rules/20-medium.rules"
heavy="$rules/30-heavy.rules"
finalize="$rules/99-finalize.rules"

# Lines that are not blank and not comments.
rule_lines() {
  grep -Ev '^[[:space:]]*(#|$)' "$@"
}

# Line number of the first line that equals $2 exactly in file $1.
line_of() {
  grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# keys_of <file>...: the sorted set of rule keys in the files.
keys_of() {
  rule_lines "$@" | sed -n 's/.*\(-k \|-F key=\)\([^ ]*\).*/\2/p' | LC_ALL=C sort -u
}

@test "the old rule dirs are gone" {
  for d in base minimal standard local; do
    [ ! -e "$rules/$d" ]
  done
}

@test "base sets -D, backlog placeholder, -f 1, backlog_wait_time, canary" {
  prev=0
  for line in \
    '-D' \
    '-b @AKIT_BACKLOG@' \
    '-f 1' \
    '--backlog_wait_time 60000' \
    '-w /etc/auditd-kit/canary -p wa -k akit_canary'; do
    n=$(line_of "$base" "$line")
    [ -n "$n" ]
    [ "$n" -gt "$prev" ]
    prev=$n
  done
}

@test "finalize holds only -e 2" {
  run rule_lines "$finalize"
  [ "$status" -eq 0 ]
  [ "$output" = "-e 2" ]
}

@test "only base sets control lines" {
  run grep -El -- '^[[:space:]]*(-D|-b|-f|-e|-r|-i|--backlog_wait_time|--loginuid-immutable)([[:space:]=]|$)' \
    "$base" "$minimal" "$medium" "$heavy"
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

@test "no rule file sets -f 2" {
  run grep -E '^[[:space:]]*-f[[:space:]]+2([[:space:]]|$)' "$rules"/*.rules
  [ "$status" -eq 1 ]
}

@test "every profile rule has a key" {
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    case "$line" in
      *' -k '* | *'-F key='*) ;;
      *)
        echo "no key: $line" >&2
        false
        ;;
    esac
  done <<EOF2
$(grep -hE '^[[:space:]]*-[aw][[:space:]]' "$base" "$minimal" "$medium" "$heavy")
EOF2
  [ "$count" -gt 0 ]
}

@test "every b64 syscall rule has a b32 twin in the same file" {
  # Syscalls that exist on b64 only. A b64 rule that names one of these needs no b32 twin.
  b64_only=''
  count=0
  for f in "$base" "$minimal" "$medium" "$heavy"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      count=$((count + 1))
      twin=$(printf '%s\n' "$line" | sed 's/arch=b64/arch=b32/')
      if grep -qxF -- "$twin" "$f"; then
        continue
      fi
      skip=no
      for sc in $b64_only; do
        case "$line" in
          *"$sc"*) skip=yes ;;
        esac
      done
      if [ "$skip" = no ]; then
        echo "no b32 twin in $f: $line" >&2
        false
      fi
    done <<EOF2
$(grep -E '^-a .*arch=b64' "$f")
EOF2
  done
  [ "$count" -gt 0 ]
}

@test "base and minimal use only the agreed keys" {
  [ "$(keys_of "$base")" = 'T1562_Impair_Defenses
akit_canary' ]
  [ "$(keys_of "$minimal")" = 'T1098_Account_Manipulation
T1547_Boot_or_Logon_Autostart_Execution
T1548_Abuse_Elevation_Control_Mechanism
T1556_Modify_Authentication_Process
time_change' ]
}

@test "base covers audit tampering" {
  for want in \
    '-w /etc/audit/ -p wa' '-w /etc/audisp/ -p wa' '-w /etc/libaudit.conf -p wa' \
    '-F path=/usr/sbin/auditctl -F perm=x' '-F path=/usr/sbin/augenrules -F perm=x' \
    '-F path=/usr/sbin/auditd -F perm=x'; do
    grep -qF -- "$want" "$base" || {
      echo "missing: $want" >&2
      false
    }
  done
}

@test "minimal covers the agreed paths and syscalls" {
  for want in \
    '-w /etc/passwd -p wa' '-w /etc/shadow -p wa' '-w /etc/group -p wa' '-w /etc/gshadow -p wa' \
    '-w /etc/security/opasswd -p wa' '-w /etc/pam.d/ -p wa' '-w /etc/ssh/sshd_config -p wa' \
    '-w /etc/ssh/sshd_config.d/ -p wa' '-w /etc/sudoers -p wa' '-w /etc/sudoers.d/ -p wa' \
    '-w /etc/localtime -p wa' \
    '-F path=/usr/bin/sudo -F perm=x' '-F path=/usr/bin/su -F perm=x' \
    '-F path=/usr/bin/kmod -F perm=x' \
    'adjtimex,settimeofday,clock_settime' '-S stime' \
    'init_module,finit_module,delete_module'; do
    grep -qF -- "$want" "$minimal" || {
      echo "missing: $want" >&2
      false
    }
  done
}

@test "each rule in base and minimal carries the key of its area" {
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    case "$line" in
      -D | -b* | -f* | --backlog_wait_time*) continue ;;
      *' /etc/auditd-kit/canary '*)
        want=akit_canary ;;
      *' /etc/passwd '* | *' /etc/shadow '* | *' /etc/group '* | *' /etc/gshadow '* | *' /etc/security/opasswd '*)
        want=T1098_Account_Manipulation ;;
      *' /etc/pam.d/ '* | *' /etc/ssh/sshd_config '* | *' /etc/ssh/sshd_config.d/ '*)
        want=T1556_Modify_Authentication_Process ;;
      *' /etc/sudoers '* | *' /etc/sudoers.d/ '* | *path=/usr/bin/sudo' '* | *path=/usr/bin/su' '*)
        want=T1548_Abuse_Elevation_Control_Mechanism ;;
      *' /etc/audit/ '* | *' /etc/audisp/ '* | *' /etc/libaudit.conf '* | *path=/usr/sbin/audit* | *path=/usr/sbin/augenrules' '*)
        want=T1562_Impair_Defenses ;;
      *adjtimex* | *stime* | *' /etc/localtime '*)
        want=time_change ;;
      *init_module* | *path=/usr/bin/kmod' '*)
        want=T1547_Boot_or_Logon_Autostart_Execution ;;
      *)
        echo "no area for: $line" >&2
        false
        ;;
    esac
    case "$line" in
      *" -k $want") ;;
      *)
        echo "wrong key (want $want): $line" >&2
        false
        ;;
    esac
  done <<EOF2
$(rule_lines "$base" "$minimal" | sed 's/^[^:]*://')
EOF2
  [ "$count" -gt 0 ]
}

@test "medium uses only the agreed keys" {
  [ "$(keys_of "$medium")" = 'T1053_Scheduled_Task_Job
T1055_Process_Injection
T1059_Command_and_Scripting_Interpreter
T1098_Account_Manipulation
T1543_Create_or_Modify_System_Process
T1546_Event_Triggered_Execution
T1574_Hijack_Execution_Flow
mounts
network_config' ]
}

@test "medium exec rules filter on logged-in users and note the UID_MIN floor" {
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      *' -F auid>=1000 -F auid!=unset '*) ;;
      *)
        echo "no auid filter: $line" >&2
        false
        ;;
    esac
  done <<EOF2
$(rule_lines "$medium" | grep -F -- '-S execve')
EOF2
  [ "$n" -eq 2 ]
  grep -q 'UID_MIN' "$medium"
}

@test "heavy uses only the agreed keys, the setuid recipe, and the commented execve rule" {
  [ "$(keys_of "$heavy")" = 'T1070_Indicator_Removal
T1222_File_and_Directory_Permissions_Modification
T1562_Impair_Defenses
access
logins' ]
  grep -qF -- 'find /' "$heavy"
  grep -qF -- '# -a always,exit -F arch=b64 -S execve,execveat -k' "$heavy"
}

@test "heavy syscall rules filter on logged-in users" {
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      *' -F auid>=1000 -F auid!=unset '*) ;;
      *)
        echo "no auid filter: $line" >&2
        false
        ;;
    esac
  done <<EOF2
$(rule_lines "$heavy" | grep -F -- ' -S ')
EOF2
  [ "$n" -gt 0 ]
}

@test "32-bit-only syscalls appear only on b32 rules" {
  for call in chown32 fchown32 lchown32 truncate64 ftruncate64; do
    pat="[ ,]${call}[ ,]"
    [ "$(rule_lines "$heavy" | grep -c -- "$pat")" -gt 0 ]
    [ "$(rule_lines "$heavy" | grep -- "$pat" | grep -vc -- 'arch=b32')" -eq 0 ]
  done
}

@test "medium and heavy headers say they add log volume" {
  for f in "$medium" "$heavy"; do
    head -n 5 "$f" | grep -qi 'volume' || {
      echo "no volume note: $f" >&2
      false
    }
  done
}

@test "heavy and finalize say immutable mode needs a reboot for rule changes" {
  for f in "$heavy" "$finalize"; do
    grep -q -- '-e 2' "$f"
    grep -qi 'compliance' "$f"
    grep -qi 'reboot' "$f"
  done
}

@test "README names the profiles, the overlay rules, and the credits" {
  readme="$rules/README.md"
  # The backticks are Markdown, not command substitution.
  # shellcheck disable=SC2016
  for want in '`minimal` (default)' '`medium`' '`heavy`' 'akit_extra_rules_dir' '50-*.rules' \
    'control lines' 'https://github.com/Neo23x0/auditd' \
    'https://github.com/certeu/ansible-auditd-laurel' 'https://attack.mitre.org' 'Laurel'; do
    grep -qF -- "$want" "$readme" || {
      echo "missing: $want" >&2
      false
    }
  done
}
