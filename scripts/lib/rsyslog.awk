# Read rsyslog configuration files for the survey. POSIX awk only.
#
# Usage: LC_ALL=C awk -f rsyslog.awk FILE...
#
# Pass /etc/rsyslog.conf first and then the files in /etc/rsyslog.d. The program understands
# legacy selector lines (@host, @@host:port, @(o)host, :omfwd:, :omrelp:), property filters,
# RainerScript action() statements over several lines, if ... then / else filters, ruleset()
# blocks, call, and comments. It ignores $IncludeConfig and include(), because the caller
# decides which files to read.
#
# A forward is an omfwd or omrelp output. Output, one record per line, each value listed once
# in the order it was first seen:
#   target <host:port/proto>   a forward
#   facility <name>            a facility that a file other than 40-auditd-kit.conf selects by
#                              name
#   catchall <line>            a forward that is not provably limited to specific facilities
#   parse_error                the files ended inside a statement, a block, or a comment
#
# The catch-all test fails closed. A forward is not a catch-all only when it is inside a
# facility selector, or a prifilt("...") filter, that names specific facilities with no * and
# no local0 to local7 (unless that one is excluded with .none). Everything else is a catch-all:
# unfiltered forwards, severity, property, and expression filters, else branches, and forwards
# in a ruleset that a call, a module, or an input uses. A forward in the 40-auditd-kit.conf
# file is never reported as a catch-all, and a forward in a ruleset nothing uses is not either.

BEGIN {
  nfac = split("kern user mail daemon auth syslog lpr news uucp cron authpriv ftp ntp security console local0 local1 local2 local3 local4 local5 local6 local7", fl, " ")
  for (i = 1; i <= nfac; i++) known[fl[i]] = 1
  nkw = split("action if ruleset module input template include main_queue global call set foreach parser lookup_table timezone unset reload_lookup_table ratelimit", kl, " ")
  for (i = 1; i <= nkw; i++) kw[kl[i]] = 1
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# clean(s): drop # comments and C comments outside quotes. A C comment starts only at the
# beginning of a token, so /var/log/x/* and /etc/rsyslog.d/*.conf are not comments.
function clean(s,    out, i, n, c, d, q) {
  out = ""
  q = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    d = substr(s, i, 2)
    if (cblock) {
      if (d == "*/") {
        cblock = 0
        i++
      }
      continue
    }
    if (q != "") {
      out = out c
      if (c == "\\" && i < n) {
        i++
        out = out substr(s, i, 1)
      } else if (c == q) {
        q = ""
      }
      continue
    }
    if (c == "\"" || c == "'") {
      q = c
      out = out c
    } else if (d == "/*" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) {
      cblock = 1
      i++
    } else if (c == "#") {
      break
    } else {
      out = out c
    }
  }
  return out
}

# match_paren(s, i): index of the ) that closes the ( at index i, or 0.
function match_paren(s, i,    n, c, d, q) {
  n = length(s)
  d = 0
  q = ""
  for (; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      if (c == "\\") i++
      else if (c == q) q = ""
    } else if (c == "\"" || c == "'") q = c
    else if (c == "(") d++
    else if (c == ")") {
      d--
      if (d == 0) return i
    }
  }
  return 0
}

function depth(s,    i, n, c, d, q) {
  d = 0
  q = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      if (c == "\\") i++
      else if (c == q) q = ""
    } else if (c == "\"" || c == "'") q = c
    else if (c == "(") d++
    else if (c == ")") d--
  }
  return d
}

# needs_buffer(s): a RainerScript statement can run over several lines.
function needs_buffer(s,    low, w) {
  low = tolower(s)
  if (low ~ /action[ \t]*\(/) return 1
  if (match(low, /^[a-z_]+/)) {
    w = substr(low, 1, RLENGTH)
    if (w in kw) return 1
  }
  return 0
}

function push(v) { stk[++sp] = v }
function pop() {
  if (sp > 0) sp--
  else perr = 1
}

function add_target(t) {
  if (!(t in tseen)) {
    tseen[t] = 1
    tlist[++nt] = t
  }
}

function add_fac(f) {
  f = tolower(f)
  if ((f in known) && !(f in fseen) && !own) {
    fseen[f] = 1
    flist[++nf] = f
  }
}

function add_catch(l) {
  if (!(l in cseen)) {
    cseen[l] = 1
    clist[++nc] = l
  }
}

function last_dot(it,    j) {
  for (j = length(it); j >= 1; j--) if (substr(it, j, 1) == ".") return j
  return 0
}

# use_sel(sel): record the facilities a selector names.
function use_sel(sel,    items, ni, k, it, p, lev, fa, nfa, m) {
  gsub(/[ \t]/, "", sel)
  ni = split(sel, items, ";")
  for (k = 1; k <= ni; k++) {
    it = items[k]
    p = last_dot(it)
    if (p == 0) continue
    lev = tolower(substr(it, p + 1))
    sub(/^[!=]+/, "", lev)
    if (lev == "none") continue
    nfa = split(substr(it, 1, p - 1), fa, ",")
    for (m = 1; m <= nfa; m++) if (fa[m] != "*") add_fac(fa[m])
  }
}

# safe_sel(sel): 1 when the selector names only specific facilities, none of them local0 to
# local7 unless excluded with .none, and no *.
function safe_sel(sel,    items, ni, k, it, p, lev, fa, nfa, m, npos, pos, ex, exall, f) {
  gsub(/[ \t]/, "", sel)
  if (sel == "") return 0
  split("", ex)
  split("", pos)
  exall = 0
  npos = 0
  ni = split(sel, items, ";")
  for (k = 1; k <= ni; k++) {
    it = items[k]
    p = last_dot(it)
    if (p == 0) return 0
    lev = tolower(substr(it, p + 1))
    sub(/^[!=]+/, "", lev)
    if (lev == "") return 0
    nfa = split(tolower(substr(it, 1, p - 1)), fa, ",")
    if (lev == "none") {
      for (m = 1; m <= nfa; m++) {
        if (fa[m] == "*") exall = 1
        else ex[fa[m]] = 1
      }
    } else {
      pos[++npos] = tolower(substr(it, 1, p - 1))
    }
  }
  if (npos == 0) return 0
  for (k = 1; k <= npos; k++) {
    nfa = split(pos[k], fa, ",")
    for (m = 1; m <= nfa; m++) {
      f = fa[m]
      if (f == "*" || !(f in known)) return 0
      if (f ~ /^local[0-7]$/ && !exall && !(f in ex)) return 0
    }
  }
  return 1
}

# prifilt_str(expr): the string of an expression that is exactly one prifilt("..."), else "".
function prifilt_str(expr,    e, s) {
  e = trim(expr)
  while (substr(e, 1, 1) == "(" && match_paren(e, 1) == length(e)) e = trim(substr(e, 2, length(e) - 2))
  if (tolower(e) !~ /^prifilt[ \t]*\([ \t]*("[^"]*"|'[^']*')[ \t]*\)$/) return ""
  s = e
  sub(/^[^"']*["']/, "", s)
  sub(/["'][ \t]*\)$/, "", s)
  return s
}

function safe_if(expr,    s) {
  s = prifilt_str(expr)
  if (s == "") return 0
  return safe_sel(s)
}

# if_walk(expr): record the facilities an if filter names.
function if_walk(expr,    rest, s, low) {
  low = tolower(expr)
  rest = expr
  while (match(tolower(rest), /prifilt[ \t]*\([ \t]*["'][^"']*["']/)) {
    s = substr(rest, RSTART, RLENGTH)
    sub(/^[^"']*["']/, "", s)
    sub(/["']$/, "", s)
    rest = substr(rest, RSTART + RLENGTH)
    use_sel(s)
  }
  if (low ~ /syslogfacility/) {
    rest = low
    while (match(rest, /["'][a-z0-9]+["']/)) {
      add_fac(substr(rest, RSTART + 1, RLENGTH - 2))
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
}

# note_ctx(extra_safe): work out the filter context of an action statement from the block
# stack, and remember it for a following "&" line.
function note_ctx(extra_safe,    i, e) {
  if (use_prev) {
    cur_safe = prev_safe
    cur_rs = prev_rs
    cur_prefix = prev_prefix
    return
  }
  cur_safe = extra_safe
  cur_rs = ""
  cur_prefix = ""
  for (i = 1; i <= sp; i++) {
    e = stk[i]
    if (substr(e, 1, 3) == "if:") {
      cur_prefix = cur_prefix "if " substr(e, 4) " then "
      if (safe_if(substr(e, 4))) cur_safe = 1
    } else if (e == "else") {
      cur_prefix = cur_prefix "else "
    } else if (substr(e, 1, 8) == "ruleset:") {
      cur_rs = substr(e, 9)
      cur_prefix = cur_prefix "ruleset " cur_rs ": "
    }
  }
  if (cur_rs == "") cur_rs = lrs
  prev_safe = cur_safe
  prev_rs = cur_rs
  prev_prefix = cur_prefix
}

function forward(t, text) {
  add_target(t)
  nfw++
  fsafe[nfw] = cur_safe
  frs[nfw] = cur_rs
  ftext[nfw] = cur_prefix text
  fown[nfw] = own
}

# parse_params(body): fill P with the lower-cased key=value pairs of an object body.
function parse_params(body,    s, i, n, c, key, val, qc) {
  split("", P)
  s = body
  n = length(s)
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c ~ /[ \t,]/) {
      i++
      continue
    }
    key = ""
    while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_.]/) {
      key = key substr(s, i, 1)
      i++
    }
    if (key == "") {
      i++
      continue
    }
    while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
    if (substr(s, i, 1) != "=") continue
    i++
    while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
    val = ""
    qc = substr(s, i, 1)
    if (qc == "\"" || qc == "'") {
      i++
      while (i <= n && substr(s, i, 1) != qc) {
        if (substr(s, i, 1) == "\\") i++
        val = val substr(s, i, 1)
        i++
      }
      i++
    } else {
      while (i <= n && substr(s, i, 1) !~ /[ \t,]/) {
        val = val substr(s, i, 1)
        i++
      }
    }
    P[tolower(key)] = val
  }
}

# action_stmt(s, extra_safe, seltext): handle an action(...) statement. Return what follows.
function action_stmt(s, extra_safe, seltext,    i, j, type, tgt, port, proto, text) {
  i = index(s, "(")
  j = match_paren(s, i)
  if (j == 0) {
    perr = 1
    return ""
  }
  parse_params(substr(s, i + 1, j - i - 1))
  note_ctx(extra_safe)
  type = tolower(P["type"])
  if ((type == "omfwd" || type == "omrelp") && P["target"] != "") {
    tgt = P["target"]
    port = P["port"]
    if (port == "") port = 514
    proto = (type == "omrelp") ? "relp" : tolower(P["protocol"])
    if (proto == "") proto = "udp"
    if (index(tgt, ":") > 0 && substr(tgt, 1, 1) != "[") tgt = "[" tgt "]"
    text = substr(s, 1, j)
    gsub(/[ \t]+/, " ", text)
    forward(tgt ":" port "/" proto, seltext text)
  }
  return substr(s, j + 1)
}

# legacy_forward(act, text): read an @host, @@host:port, :omfwd:, or :omrelp: action.
function legacy_forward(act, text,    s, proto, cl, rest, host, port, hp, n) {
  s = act
  sub(/[ \t].*$/, "", s)
  proto = "udp"
  if (tolower(s) ~ /^:omrelp:/) {
    proto = "relp"
    s = substr(s, 9)
  } else if (tolower(s) ~ /^:omfwd:/) {
    s = substr(s, 8)
  }
  if (s ~ /^@@/) {
    proto = "tcp"
    s = substr(s, 3)
  } else if (s ~ /^@/) {
    s = substr(s, 2)
  }
  sub(/^\([^)]*\)/, "", s)
  sub(/;.*/, "", s)
  if (s == "") return
  port = 514
  if (substr(s, 1, 1) == "[") {
    cl = index(s, "]")
    if (cl == 0) return
    host = substr(s, 1, cl)
    rest = substr(s, cl + 1)
    if (rest ~ /^:[0-9A-Za-z]+/) port = substr(rest, 2)
  } else {
    n = split(s, hp, ":")
    if (n == 2) {
      host = hp[1]
      port = hp[2]
    } else if (n == 1) {
      host = s
    } else {
      host = "[" s "]"
    }
  }
  forward(host ":" port "/" proto, text)
}

# legacy_action(act, extra_safe, seltext): handle the action part of a legacy line.
function legacy_action(act, extra_safe, seltext,    text) {
  text = seltext act
  gsub(/[ \t]+/, " ", text)
  if (tolower(act) ~ /^action[ \t]*\(/) {
    action_stmt(act, extra_safe, seltext)
    return
  }
  note_ctx(extra_safe)
  if (act ~ /^@/ || tolower(act) ~ /^:om(fwd|relp):/) legacy_forward(act, text)
}

function bind(v) {
  if (v != "") bound[v] = 1
}

function directive(d,    low, n, w) {
  sub(/[ \t]+#.*$/, "", d)
  low = tolower(d)
  n = split(d, w, /[ \t]+/)
  if (low ~ /^\$ruleset[ \t]/) {
    lrs = (w[2] == "RSYSLOG_DefaultRuleset") ? "" : w[2]
  } else if (low ~ /^\$[a-z]*bindruleset[ \t]/ || low ~ /^\$defaultruleset[ \t]/) {
    bind(w[2])
  }
}

function handle_else(r,    rest, t) {
  rest = trim(substr(r, 5))
  if (tolower(rest) ~ /^if[ \t(]/) return handle_if(rest, 1)
  if (substr(rest, 1, 1) == "{") {
    push("else")
    return substr(rest, 2)
  }
  if (rest == "") {
    pend = "else"
    return ""
  }
  push("else")
  t = stmt1(rest)
  pop()
  return t
}

function handle_if(s, iselse,    low, p, expr, rest, entry, t) {
  low = tolower(s)
  p = match(low, /[ \t)]then([ \t{]|$)/)
  if (!p) {
    perr = 1
    return ""
  }
  expr = trim(substr(s, 3, p - 2))
  rest = trim(substr(s, p + 5))
  if_walk(expr)
  entry = iselse ? "else" : "if:" expr
  if (substr(rest, 1, 1) == "{") {
    push(entry)
    return substr(rest, 2)
  }
  if (rest == "") {
    pend = entry
    return ""
  }
  push(entry)
  t = trim(stmt1(rest))
  pop()
  if (tolower(t) ~ /^else([ \t{]|$)/) return handle_else(t)
  return t
}

function legacy(s,    i, sel, act, pname, val, rest, text, safe) {
  if (s ~ /^&/) {
    use_prev = 1
    legacy_action(trim(substr(s, 2)), 0, "& ")
    use_prev = 0
    return ""
  }
  if (s ~ /^@/ || tolower(s) ~ /^:om(fwd|relp):/) {
    legacy_action(s, 0, "")
    return ""
  }
  if (tolower(s) ~ /^:om[a-z]+:/) return ""
  if (s ~ /^:/) {
    if (!match(s, /^:[^,]+,[^,]+,[ \t]*("[^"]*"|'[^']*')/)) {
      perr = 1
      return ""
    }
    rest = trim(substr(s, RLENGTH + 1))
    text = substr(s, 1, RLENGTH)
    pname = tolower(trim(substr(text, 2, index(text, ",") - 2)))
    val = text
    sub(/^.*,[ \t]*["']/, "", val)
    sub(/["']$/, "", val)
    if (pname ~ /syslogfacility/) add_fac(val)
    legacy_action(rest, 0, text " ")
    return ""
  }
  i = match(s, /[ \t]/)
  if (!i) return ""
  sel = substr(s, 1, i - 1)
  act = trim(substr(s, i))
  if (sel !~ /^[A-Za-z0-9_*,.;!=-]+$/) {
    legacy_action(act, 0, sel " ")
    return ""
  }
  use_sel(sel)
  legacy_action(act, safe_sel(sel), sel " ")
  return ""
}

# stmt1(s): handle the first statement of s and return the rest.
function stmt1(s,    low, c, w, p, name, r, p2) {
  s = trim(s)
  if (s == "") return ""
  c = substr(s, 1, 1)
  if (pend != "" && c != "{") {
    if (pend == "else" || substr(pend, 1, 3) == "if:") {
      p = pend
      pend = ""
      push(p)
      r = stmt1(s)
      pop()
      return r
    }
    pend = ""
  }
  low = tolower(s)
  if (c == "{") {
    push(pend != "" ? pend : "block")
    pend = ""
    return substr(s, 2)
  }
  if (c == "}") {
    pop()
    r = trim(substr(s, 2))
    if (tolower(r) ~ /^else([ \t{]|$)/) return handle_else(r)
    return r
  }
  if (low ~ /^if[ \t(]/) return handle_if(s, 0)
  if (low ~ /^else([ \t{]|$)/) return handle_else(s)
  if (low ~ /^action[ \t]*\(/) return action_stmt(s, 0, "")
  if (low ~ /^call[ \t]/) {
    r = trim(substr(s, 5))
    name = r
    sub(/[ \t}].*$/, "", name)
    bind(name)
    return trim(substr(r, length(name) + 1))
  }
  if (low ~ /^(stop|continue)([ \t}]|$)/) {
    return trim(substr(s, (substr(low, 1, 4) == "stop" ? 5 : 9)))
  }
  if (low ~ /^(set|unset|reload_lookup_table|foreach)([ \t(]|$)/) {
    if (s ~ /\{[ \t]*$/) push("block")
    return ""
  }
  if (low ~ /^(module|input|template|global|main_queue|parser|lookup_table|timezone|include|ratelimit|ruleset|property|constant)[ \t]*\(/) {
    p = index(s, "(")
    p2 = match_paren(s, p)
    if (p2 == 0) {
      perr = 1
      return ""
    }
    parse_params(substr(s, p + 1, p2 - p - 1))
    bind(P["ruleset"])
    bind(P["defaultruleset"])
    if (low ~ /^ruleset/) pend = "ruleset:" P["name"]
    else if (low ~ /^template/) pend = "block"
    return substr(s, p2 + 1)
  }
  return legacy(s)
}

function handle(s,    t) {
  s = trim(s)
  while (s != "") {
    t = trim(stmt1(s))
    if (length(t) >= length(s)) break
    s = t
  }
}

function finish_file() {
  if (!seen) return
  if (cont && buf != "") handle(buf)
  else if (buf != "") perr = 1
  if (cblock || sp > 0) perr = 1
}

FNR == 1 {
  finish_file()
  seen = 1
  buf = ""
  cont = 0
  sp = 0
  pend = ""
  cblock = 0
  lrs = ""
  prev_safe = 0
  prev_rs = ""
  prev_prefix = ""
  n = split(FILENAME, parts, "/")
  own = (parts[n] == "40-auditd-kit.conf")
}

{
  raw = $0
  gsub(/\r/, "", raw)
  if (buf == "" && !cblock && trim(raw) ~ /^\$/) {
    directive(trim(raw))
    next
  }
  line = trim(clean(raw))
  if (buf == "") buf = line
  else if (cont) buf = buf line
  else buf = buf " " line
  cont = 0
  if (buf == "") next
  if (buf ~ /\\$/) {
    sub(/\\$/, "", buf)
    cont = 1
    next
  }
  if (needs_buffer(buf) && depth(buf) > 0) next
  stmt = buf
  buf = ""
  handle(stmt)
}

END {
  finish_file()
  for (i = 1; i <= nfw; i++) {
    if (!fsafe[i] && !fown[i] && (frs[i] == "" || (frs[i] in bound))) add_catch(ftext[i])
  }
  for (i = 1; i <= nt; i++) print "target " tlist[i]
  for (i = 1; i <= nf; i++) print "facility " flist[i]
  for (i = 1; i <= nc; i++) print "catchall " clist[i]
  if (perr) print "parse_error"
}
