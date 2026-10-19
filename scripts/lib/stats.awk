# Count audit volume in raw audit log files. POSIX awk only.
#
# Usage: awk [-v since=<epoch seconds>] [-v top=<n>] -f stats.awk FILE...
#
# Input: raw audit.log lines. Only lines with a msg=audit(<epoch>.<ms>:<serial>) id count.
# An event is one run of consecutive lines with the same id, and it takes its UTC day from
# the epoch. Events older than since (default 0) are skipped, bytes included. top (default
# 10) is how many lines each top_* list prints.
#
# Output, in this order:
#   day=YYYY-MM-DD bytes=<n> events=<n>   one line per UTC day, oldest first; bytes is the sum
#                                         of line lengths plus one per line
#   top_key <name> <count>                events per key, most first, ties by name
#   top_exe <name> <count>                events per executable path
#   top_auid <name> <count>               events per audit uid; 4294967295 counts as unset
#
# A key list from a hex-encoded key is split at the \001 byte, and each key counts once for
# the event. key=(null) counts as (none). An event with no key, exe, or auid field adds
# nothing to that list. Spaces and control bytes in names print as "_".

function chr(n) {
  return n == 0 ? "?" : sprintf("%c", n)
}

function hexval(c) {
  return index("0123456789ABCDEF", toupper(c)) - 1
}

# unhex(<even-length hex string>): the decoded bytes.
function unhex(s,    i, out) {
  out = ""
  for (i = 1; i < length(s); i += 2) {
    out = out chr(hexval(substr(s, i, 1)) * 16 + hexval(substr(s, i + 1, 1)))
  }
  return out
}

# field(<line>, <name>): the value of " name=" in the line, without quotes. Sets fhex when the
# value is a bare even-length hex string. Returns fnone when the field is missing.
function field(line, name,    p, v, q) {
  fnone = 0
  fhex = 0
  p = index(line, " " name "=")
  if (p == 0) {
    fnone = 1
    return ""
  }
  v = substr(line, p + length(name) + 2)
  if (substr(v, 1, 1) == "\"") {
    v = substr(v, 2)
    q = index(v, "\"")
    return q == 0 ? v : substr(v, 1, q - 1)
  }
  q = index(v, " ")
  if (q > 0) {
    v = substr(v, 1, q - 1)
  }
  if (length(v) >= 2 && length(v) % 2 == 0 && v ~ /^[0-9A-Fa-f]+$/) {
    fhex = 1
  }
  return v
}

function clean(s) {
  gsub(/[^!-~]/, "_", s)
  return s
}

# civil_day(<days since 1970-01-01>): YYYY-MM-DD, proleptic Gregorian, UTC.
function civil_day(days,    z, era, doe, yoe, y, doy, mp, d, m) {
  z = days + 719468
  era = int(z / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp < 10 ? mp + 3 : mp - 9
  if (m <= 2) {
    y++
  }
  return sprintf("%04d-%02d-%02d", y, m, d)
}

# Add the finished event's key, exe, and auid to the tallies.
function flush(    n, i, parts) {
  if (!active) {
    return
  }
  if (ev_key != "") {
    n = split(ev_key, parts, "\001")
    for (i = 1; i <= n; i++) {
      if (parts[i] != "") {
        kc[clean(parts[i])]++
      }
    }
  }
  if (ev_exe != "") {
    ec[clean(ev_exe)]++
  }
  if (ev_auid != "") {
    ac[ev_auid]++
  }
  active = 0
}

# event_fields(<line>): take key, exe, and auid from the line unless the event already has them.
function event_fields(line,    v) {
  if (ev_key == "") {
    v = field(line, "key")
    if (!fnone) {
      if (v == "(null)") {
        v = "(none)"
      } else if (fhex) {
        v = unhex(v)
      }
      ev_key = v
    }
  }
  if (ev_exe == "") {
    v = field(line, "exe")
    if (!fnone) {
      ev_exe = fhex ? unhex(v) : v
    }
  }
  if (ev_auid == "") {
    v = field(line, "auid")
    if (!fnone && v != "") {
      ev_auid = (v == "4294967295" || v == "-1") ? "unset" : v
    }
  }
}

# sorted(<count array>, <name array>): fill the name array, most events first. Returns the size.
function sorted(cnt, names,    k, n, i, j, t) {
  n = 0
  for (k in cnt) {
    names[++n] = "" k
  }
  for (i = 2; i <= n; i++) {
    t = names[i]
    for (j = i - 1; j >= 1 && before(t, names[j], cnt); j--) {
      names[j + 1] = names[j]
    }
    names[j + 1] = t
  }
  return n
}

function before(a, b, cnt) {
  if (cnt[a] != cnt[b]) {
    return cnt[a] > cnt[b]
  }
  return a < b
}

function show(label, cnt,    names, n, i) {
  n = sorted(cnt, names)
  for (i = 1; i <= n && i <= limit; i++) {
    print label, names[i], cnt[names[i]]
  }
}

BEGIN {
  since = since + 0
  limit = (top == "") ? 10 : top + 0
  cur = ""
  active = 0
}

{
  if (match($0, /msg=audit\([0-9]+\.[0-9]+:[0-9]+\)/) == 0) {
    next
  }
  id = substr($0, RSTART + 10, RLENGTH - 11)
  if (id != cur) {
    flush()
    cur = id
    ts = substr(id, 1, index(id, ".") - 1) + 0
    keep = (ts >= since)
    if (keep) {
      day = civil_day(int(ts / 86400))
      devents[day]++
      ev_key = ""
      ev_exe = ""
      ev_auid = ""
      active = 1
    }
  }
  if (keep) {
    dbytes[day] += length($0) + 1
    event_fields($0)
  }
}

END {
  flush()
  n = 0
  for (d in devents) {
    days[++n] = d
  }
  for (i = 2; i <= n; i++) {
    t = days[i]
    for (j = i - 1; j >= 1 && days[j] > t; j--) {
      days[j + 1] = days[j]
    }
    days[j + 1] = t
  }
  for (i = 1; i <= n; i++) {
    printf "day=%s bytes=%.0f events=%.0f\n", days[i], dbytes[days[i]], devents[days[i]]
  }
  show("top_key", kc)
  show("top_exe", ec)
  show("top_auid", ac)
}
