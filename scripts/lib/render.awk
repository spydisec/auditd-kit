# Rule processing for render.sh. POSIX awk only.
#
# mode=paths prints each host path a rule depends on, one per line, so render.sh can test them.
# mode=render prints the rendered file on stdout and appends actions to the report file.
#
# Variables: mode, label (source name for the report), strip (1 to drop control lines),
# b32_ok (1 when b32 rules can load), arch, b64_file, b32_file, missing_file, report.

function load_syscalls(file, set, line, n, f) {
  # Accept one name per line, or the "<number> <name>" lines of ausyscall --dump.
  while ((getline line <file) > 0) {
    n = split(line, f)
    if (n == 1)
      set[f[1]] = 1
    else if (n == 2 && f[1] ~ /^[0-9]+$/)
      set[f[2]] = 1
  }
  close(file)
}

function load_lines(file, set, line) {
  while ((getline line <file) > 0)
    set[line] = 1
  close(file)
}

# The directory that holds a path. A trailing slash is not a path component.
function parent(p) {
  while (length(p) > 1 && substr(p, length(p)) == "/")
    p = substr(p, 1, length(p) - 1)
  sub(/\/[^\/]*$/, "", p)
  if (p == "")
    p = "/"
  return p
}

function is_control(word) {
  return word == "-D" || word == "-b" || word == "-f" || word == "-e" || word == "-i" ||
    word == "--backlog_wait_time" || word == "--loginuid-immutable"
}

function act(action, reason, detail) {
  printf "%s:%d\t%s\t%s\t%s\n", label, FNR, action, reason, detail >>report
}

function known_syscall(name, b32) {
  if (name == "all" || name ~ /^[0-9]+$/)
    return 1
  if (b32)
    return name in b32_calls
  return name in b64_calls
}

BEGIN {
  if (mode == "render") {
    load_syscalls(b64_file, b64_calls)
    load_syscalls(b32_file, b32_calls)
    load_lines(missing_file, missing)
    print "# Rendered by auditd-kit from " label ". Do not edit."
  }
}

# Blank lines and comments pass through unchanged.
/^[ \t]*(#|$)/ {
  if (mode == "render")
    print
  next
}

{
  n = split($0, t)

  if (is_control(t[1])) {
    if (mode != "render")
      next
    if (strip)
      act("dropped", "control_line", $0)
    else
      print
    next
  }

  rule_arch = ""
  watch = ""
  dir = ""
  binary = ""
  for (i = 1; i < n; i++) {
    if (t[i] == "-w")
      watch = t[i + 1]
    else if (t[i] == "-F") {
      field = t[i + 1]
      value = substr(field, index(field, "=") + 1)
      if (field ~ /^arch=/)
        rule_arch = value
      else if (field ~ /^dir=/)
        dir = value
      else if (field ~ /^(path|exe)=/)
        binary = value
    }
  }

  if (mode == "paths") {
    if (watch ~ /^\//)
      print parent(watch)
    if (dir ~ /^\//)
      print dir
    if (binary ~ /^\//)
      print binary
    next
  }

  if (rule_arch == "b32" && !b32_ok) {
    act("dropped", "no_b32", arch)
    next
  }
  if (watch != "" && (parent(watch) in missing)) {
    act("dropped", "missing_path", watch)
    next
  }
  if (dir != "" && (dir in missing)) {
    act("dropped", "missing_path", dir)
    next
  }
  if (binary != "" && (binary in missing)) {
    act("dropped", "missing_binary", binary)
    next
  }

  # Rebuild the rule without unknown syscalls. -S takes a comma list and may repeat.
  rule = ""
  has_syscalls = 0
  kept = 0
  unknown = ""
  for (i = 1; i <= n; i++) {
    if (t[i] == "-S" && i < n) {
      has_syscalls = 1
      m = split(t[i + 1], s, ",")
      keep = ""
      for (j = 1; j <= m; j++) {
        if (known_syscall(s[j], rule_arch == "b32"))
          keep = keep (keep == "" ? "" : ",") s[j]
        else
          unknown = unknown (unknown == "" ? "" : ",") s[j]
      }
      if (keep != "") {
        rule = rule " -S " keep
        kept++
      }
      i++
      continue
    }
    rule = rule " " t[i]
  }

  if (unknown == "") {
    print
    next
  }
  if (has_syscalls && kept == 0) {
    act("dropped", "unknown_syscall", unknown)
    next
  }
  m = split(unknown, s, ",")
  for (j = 1; j <= m; j++)
    act("trimmed", "unknown_syscall", s[j])
  print substr(rule, 2)
}
