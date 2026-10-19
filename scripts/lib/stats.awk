# Count audit volume in audit log files. POSIX awk only.
#
# Usage: LC_ALL=C awk [-v since=<epoch seconds>] [-v top=<n>] -f stats.awk FILE...
#
# Run it under LC_ALL=C, because length() must count bytes. Pass files oldest first
# (audit.log.N down to audit.log.1, then audit.log).
#
# Input: audit.log lines in RAW or ENRICHED format, with or without a node= prefix. Only lines
# with a msg=audit(<epoch>.<ms>:<serial>) id count, and everything from the first \035 byte
# (the start of the enriched fields) is ignored when reading fields. An event is one unique id.
# It takes its UTC day from the epoch. Records of one event may interleave with other events
# or split across files, so the last 256 ids are remembered; an id that comes back after that
# counts again. Events older than since (default 0) are skipped, and their bytes are not
# counted. top (default 10) is how many lines each top_* list prints.
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
  return n == 0 ? "_" : sprintf("%c", n)
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

# Add an event's key, exe, and auid to the tallies, then forget it.
function flush(id,    n, i, parts) {
  if (ev_key[id] != "") {
    n = split(ev_key[id], parts, "\001")
    for (i = 1; i <= n; i++) {
      if (parts[i] != "") {
        kc[clean(parts[i])]++
      }
    }
  }
  if (ev_exe[id] != "") {
    ec[clean(ev_exe[id])]++
  }
  if (ev_auid[id] != "") {
    ac[ev_auid[id]]++
  }
  delete ev_key[id]
  delete ev_exe[id]
  delete ev_auid[id]
  delete seen[id]
}

# event_fields(<id>, <line>): take key, exe, and auid from the line unless the event has them.
function event_fields(id, line,    v) {
  if (ev_key[id] == "") {
    v = field(line, "key")
    if (!fnone) {
      if (v == "(null)") {
        v = "(none)"
      } else if (fhex) {
        v = unhex(v)
      }
      ev_key[id] = v
    }
  }
  if (ev_exe[id] == "") {
    v = field(line, "exe")
    if (!fnone) {
      ev_exe[id] = fhex ? unhex(v) : v
    }
  }
  if (ev_auid[id] == "") {
    v = field(line, "auid")
    if (!fnone && v != "") {
      ev_auid[id] = (v == "4294967295" || v == "-1") ? "unset" : v
    }
  }
}

# show(<label>, <count array>): print the top entries, most events first, ties by name.
# One pass over the array per printed line, so the cost is O(size * top).
function show(label, cnt,    k, best, p, used) {
  for (p = 1; p <= limit; p++) {
    best = ""
    found = 0
    for (k in cnt) {
      if (k in used) {
        continue
      }
      if (!found || cnt[k] > cnt[best] || (cnt[k] == cnt[best] && ("" k) < ("" best))) {
        best = "" k
        found = 1
      }
    }
    if (!found) {
      return
    }
    used[best] = 1
    print label, best, cnt[best]
  }
}

BEGIN {
  since = since + 0
  limit = (top == "") ? 10 : top + 0
  ringsize = 256
  nev = 0
}

{
  blen = length($0) + 1
  line = $0
  gs = index(line, "\035")
  if (gs > 0) {
    line = substr(line, 1, gs - 1)
  }
  if (match(line, /msg=audit\([0-9]+\.[0-9]+:[0-9]+\)/) == 0) {
    next
  }
  id = substr(line, RSTART + 10, RLENGTH - 11)
  ts = substr(id, 1, index(id, ".") - 1) + 0
  if (ts < since) {
    next
  }
  dn = int(ts / 86400)
  if (!(dn in dname)) {
    dname[dn] = civil_day(dn)
  }
  day = dname[dn]
  if (!(id in seen)) {
    seen[id] = 1
    devents[day]++
    slot = nev % ringsize
    nev++
    if (slot in ring) {
      flush(ring[slot])
    }
    ring[slot] = id
  }
  dbytes[day] += blen
  event_fields(id, line)
}

END {
  for (slot in ring) {
    if (ring[slot] in seen) {
      flush(ring[slot])
    }
  }
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
