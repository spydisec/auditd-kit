#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
init="$repo/rules/base/00-init.rules"
finalize="$repo/rules/base/99-finalize.rules"
minimal="$repo/rules/minimal/30-minimal.rules"

# Lines that are not blank and not comments.
rule_lines() {
  grep -Ev '^[[:space:]]*(#|$)' "$1"
}

# Line number of the first line that equals $2 exactly in file $1.
line_of() {
  grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

@test "base init sets -D, backlog placeholder, -f 1, backlog_wait_time, canary" {
  prev=0
  for line in \
    '-D' \
    '-b @AKIT_BACKLOG@' \
    '-f 1' \
    '--backlog_wait_time 60000' \
    '-w /etc/auditd-kit/canary -p wa -k akit_canary'; do
    n=$(line_of "$init" "$line")
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

@test "every minimal rule has a key" {
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
$(grep -E '^[[:space:]]*-[aw][[:space:]]' "$minimal")
EOF2
  [ "$count" -gt 0 ]
}

@test "every b64 syscall rule in minimal has a b32 twin" {
  # Syscalls that exist on b64 only. A b64 rule that names one of these needs no b32 twin.
  b64_only=''
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    twin=$(printf '%s\n' "$line" | sed 's/arch=b64/arch=b32/')
    if grep -qxF -- "$twin" "$minimal"; then
      continue
    fi
    skip=no
    for sc in $b64_only; do
      case "$line" in
        *"$sc"*) skip=yes ;;
      esac
    done
    if [ "$skip" = no ]; then
      echo "no b32 twin: $line" >&2
      false
    fi
  done <<EOF2
$(grep -E '^-a .*arch=b64' "$minimal")
EOF2
  [ "$count" -gt 0 ]
}

@test "minimal uses only the agreed keys" {
  expected='T1098_Account_Manipulation
T1547_Boot_or_Logon_Autostart_Execution
T1548_Abuse_Elevation_Control_Mechanism
T1556_Modify_Authentication_Process
T1562_Impair_Defenses
time_change'
  actual=$(rule_lines "$minimal" | sed -n 's/.*\(-k \|-F key=\)\([^ ]*\).*/\2/p' | sort -u)
  [ "$actual" = "$expected" ]
}

@test "minimal covers the agreed paths and syscalls" {
  for want in \
    '-w /etc/passwd -p wa' '-w /etc/shadow -p wa' '-w /etc/group -p wa' '-w /etc/gshadow -p wa' \
    '-w /etc/security/opasswd -p wa' '-w /etc/pam.d/ -p wa' '-w /etc/ssh/sshd_config -p wa' \
    '-w /etc/ssh/sshd_config.d/ -p wa' '-w /etc/sudoers -p wa' '-w /etc/sudoers.d/ -p wa' \
    '-w /etc/audit/ -p wa' '-w /etc/audisp/ -p wa' '-w /etc/libaudit.conf -p wa' \
    '-w /etc/localtime -p wa' \
    '-F path=/usr/bin/sudo -F perm=x' '-F path=/usr/bin/su -F perm=x' \
    '-F path=/usr/sbin/auditctl -F perm=x' '-F path=/usr/sbin/augenrules -F perm=x' \
    '-F path=/usr/sbin/auditd -F perm=x' '-F path=/usr/bin/kmod -F perm=x' \
    'adjtimex,settimeofday,clock_settime' '-S stime' \
    'init_module,finit_module,delete_module'; do
    grep -qF -- "$want" "$minimal" || {
      echo "missing: $want" >&2
      false
    }
  done
}

@test "each rule carries the key of its area" {
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    case "$line" in
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
$(rule_lines "$minimal")
EOF2
  [ "$count" -gt 0 ]
}

@test "local README says overlay rules are 50-*.rules with no control lines" {
  grep -q '50-\*\.rules' "$repo/rules/local/README.md"
  grep -qi 'control lines' "$repo/rules/local/README.md"
}
