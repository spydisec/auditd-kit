#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

check_preset() {
  file="$repo/config/auditd/$1.conf"
  grep -qx "max_log_file = $2" "$file"
  grep -qx "num_logs = $3" "$file"
  grep -qx "# akit_backlog = $4" "$file"
}

@test "small preset is 50 MB x 5 with backlog 8192" {
  check_preset small 50 5 8192
}

@test "standard preset is 100 MB x 8 with backlog 16384" {
  check_preset standard 100 8 16384
}

@test "the old medium preset name is gone" {
  [ ! -e "$repo/config/auditd/medium.conf" ]
}

@test "large preset is 200 MB x 10 with backlog 32768" {
  check_preset large 200 10 32768
}

@test "every preset sets the never-halt actions" {
  for size in small standard large; do
    file="$repo/config/auditd/$size.conf"
    grep -qx 'max_log_file_action = ROTATE' "$file"
    grep -qx 'space_left_action = SYSLOG' "$file"
    grep -qx 'admin_space_left_action = SUSPEND' "$file"
    grep -qx 'disk_full_action = SUSPEND' "$file"
    grep -qx 'disk_error_action = SUSPEND' "$file"
    grep -qx 'name_format = hostname' "$file"
  done
}

@test "no auditd.conf action can halt the host or drop it to single-user mode" {
  run grep -rEi '^[[:space:]]*[a-z_]*_action[[:space:]]*=[[:space:]]*(HALT|SINGLE)' "$repo/config"
  [ "$status" -eq 1 ]
}
