# Read rsyslog configuration files for the survey. POSIX awk only.
#
# Usage: LC_ALL=C awk -f rsyslog.awk FILE...
#
# Pass /etc/rsyslog.conf first and then the files in /etc/rsyslog.d. The program understands
# legacy selector lines (including @host, @@host:port, @(o)host and :omfwd:), RainerScript
# action() statements over several lines, and if ... then filters with $syslogfacility-text and
# prifilt(). It ignores $IncludeConfig and include(), comments, and everything else.
#
# Output, one record per line, each value listed once in the order it was first seen:
#   target <host:port/proto>   a forward from an omfwd action or an @ or @@ line
#   facility <name>            a facility that a file other than 40-auditd-kit.conf selects by
#                              name
#   catchall <line>            a forward whose selector names * as a facility, without a .none
#                              exclusion for all of local0 to local7

BEGIN {
  nfac = split("kern user mail daemon auth syslog lpr news uucp cron authpriv ftp ntp security console local0 local1 local2 local3 local4 local5 local6 local7", fl, " ")
  for (i = 1; i <= nfac; i++) known[fl[i]] = 1
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# clean(s): drop \r, # comments, and C comments, outside quotes.
function clean(s,    out, i, n, c, d) {
  gsub(/\r/, "", s)
  out = ""
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
    } else if (d == "/*") {
      cblock = 1
      i++
    } else if (c == "#") {
      break
    } else {
      out = out c
    }
  }
  q = ""
  return out
}

# depth(s): parentheses opened and not closed, outside quotes.
function depth(s,    i, n, c, d, qq) {
  d = 0
  qq = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (qq != "") {
      if (c == "\\") i++
      else if (c == qq) qq = ""
    } else if (c == "\"" || c == "'") qq = c
    else if (c == "(") d++
    else if (c == ")") d--
  }
  return d
}

function push(v) { stk[++sp] = v }
function pop() { if (sp > 0) sp-- }

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

# sel_walk(sel, mode): mode "use" records facilities; mode "catch" returns 1 for a catch-all.
function sel_walk(sel, mode,    items, ni, k, it, p, j, facs, lev, fa, nfa, m, haspos, allx, excl, ex) {
  gsub(/[ \t]/, "", sel)
  ni = split(sel, items, ";")
  haspos = 0
  for (k = 1; k <= ni; k++) {
    it = items[k]
    p = 0
    for (j = length(it); j >= 1; j--) {
      if (substr(it, j, 1) == ".") {
        p = j
        break
      }
    }
    if (p == 0) continue
    facs = substr(it, 1, p - 1)
    lev = tolower(substr(it, p + 1))
    sub(/^[!=]+/, "", lev)
    nfa = split(facs, fa, ",")
    for (m = 1; m <= nfa; m++) {
      if (lev == "none") {
        if (fa[m] == "*") ex["*"] = 1
        else ex[tolower(fa[m])] = 1
      } else if (fa[m] == "*") {
        haspos = 1
      } else if (mode == "use") {
        add_fac(fa[m])
      }
    }
  }
  if (mode == "use") return 0
  if (!haspos) return 0
  if ("*" in ex) return 0
  allx = 1
  for (j = 0; j < 8; j++) if (!(("local" j) in ex)) allx = 0
  return allx ? 0 : 1
}

# prifilt_walk(expr, mode): apply sel_walk to each prifilt("...") string in expr.
function prifilt_walk(expr,    rest, r, s) {
  r = 0
  rest = expr
  while (match(tolower(rest), /prifilt[ \t]*\([ \t]*["'][^"']*["']/)) {
    s = substr(rest, RSTART, RLENGTH)
    sub(/^[^"']*["']/, "", s)
    sub(/["']$/, "", s)
    rest = substr(rest, RSTART + RLENGTH)
    if (sel_walk(s, "catch")) r = 1
    sel_walk(s, "use")
  }
  return r
}

# if_walk(expr): record facilities named by an if filter, and return 1 when it is a catch-all.
function if_walk(expr, mode,    rest, s, low, r) {
  low = tolower(expr)
  r = 0
  if (low ~ /prifilt[ \t]*\(/) {
    r = prifilt_walk(expr)
  }
  if (low ~ /syslogfacility/) {
    rest = low
    while (match(rest, /["'][a-z0-9]+["']/)) {
      s = substr(rest, RSTART + 1, RLENGTH - 2)
      add_fac(s)
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  return r
}

function top_filter(    t) {
  if (sp == 0) return ""
  return stk[sp]
}

# forward(target, filt, text): record a forward and decide whether it is a catch-all.
function forward(t, filt, text,    c, kind) {
  add_target(t)
  c = 0
  kind = (substr(filt, 1, 3) == "if:") ? "if:" : substr(filt, 1, 4)
  if (filt == "") c = 1
  else if (kind == "sel:") c = sel_walk(substr(filt, 5), "catch")
  else if (kind == "if:") c = (tolower(filt) ~ /prifilt[ \t]*\(/) ? prifilt_walk(substr(filt, 4)) : 0
  if (c) {
    if (kind == "if:") text = "if " substr(filt, 4) " then " text
    add_catch(text)
  }
}

# do_action(stmt, filt): read the parameters of an action(...) statement.
function do_action(stmt, filt,    s, i, n, c, key, val, qc, par, tgt, port, proto, text) {
  s = substr(stmt, index(stmt, "(") + 1)
  n = length(s)
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == ")") break
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
      while (i <= n && substr(s, i, 1) !~ /[ \t,)]/) {
        val = val substr(s, i, 1)
        i++
      }
    }
    par[tolower(key)] = val
  }
  if (tolower(par["type"]) != "omfwd") return
  tgt = par["target"]
  if (tgt == "") return
  port = par["port"]
  if (port == "") port = 514
  proto = tolower(par["protocol"])
  if (proto == "") proto = "udp"
  if (index(tgt, ":") > 0 && substr(tgt, 1, 1) != "[") tgt = "[" tgt "]"
  text = stmt
  gsub(/[ \t]+/, " ", text)
  forward(tgt ":" port "/" proto, filt, text)
}

# legacy_forward(act, filt, text): read an @host, @@host:port, or :omfwd: action.
function legacy_forward(act, filt, text,    s, proto, cl, rest, host, port, hp, n) {
  proto = "udp"
  s = act
  if (s ~ /^:omfwd:/) s = substr(s, 8)
  if (s ~ /^@@/) {
    proto = "tcp"
    s = substr(s, 3)
  } else if (s ~ /^@/) {
    s = substr(s, 2)
  }
  sub(/^\([^)]*\)/, "", s)
  sub(/;.*/, "", s)
  s = trim(s)
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
  forward(host ":" port "/" proto, filt, text)
}

function handle_legacy(stmt,    i, sel, act, w, n, filt, text) {
  text = stmt
  gsub(/[ \t]+/, " ", text)
  if (stmt ~ /^:/) {
    n = split(stmt, w, /[ \t]+/)
    act = w[n]
    if (act ~ /^@/ || act ~ /^:omfwd:/) legacy_forward(act, "prop", text)
    return
  }
  i = match(stmt, /[ \t]/)
  if (!i) return
  sel = substr(stmt, 1, i - 1)
  act = trim(substr(stmt, i))
  if (sel == "&") sel = prev_sel
  else prev_sel = sel
  if (sel !~ /^[A-Za-z0-9_*,.;!=-]+$/) return
  sel_walk(sel, "use")
  filt = "sel:" sel
  if (act ~ /^@/ || act ~ /^:omfwd:/) legacy_forward(act, filt, text)
  else if (act ~ /^action[ \t]*\(/) do_action(act, filt)
}

function count_ch(s, ch,    t) {
  t = s
  return gsub(ch, "", t)
}

function handle(stmt,    low, p, expr, rest, nclose, opened) {
  stmt = trim(stmt)
  if (stmt == "") return
  low = tolower(stmt)
  if (substr(stmt, 1, 1) == "{") {
    push(pend != "" ? pend : "block")
    pend = ""
    handle(substr(stmt, 2))
    return
  }
  if (substr(stmt, 1, 1) == "}") {
    pop()
    rest = trim(substr(stmt, 2))
    if (tolower(rest) ~ /^else/) {
      rest = trim(substr(rest, 5))
      push("else")
      if (substr(rest, 1, 1) == "{") rest = substr(rest, 2)
    }
    handle(rest)
    return
  }
  if (substr(stmt, 1, 1) == "$") return
  if (low ~ /^if[ \t(]/) {
    p = match(low, /[ \t)]then([ \t{]|$)/)
    if (!p) return
    expr = trim(substr(stmt, 3, p - 2))
    rest = trim(substr(stmt, p + 5))
    if_walk(expr)
    pend = ""
    if (substr(rest, 1, 1) == "{") {
      push("if:" expr)
      handle(substr(rest, 2))
    } else if (rest == "") {
      pend = "if:" expr
    } else {
      push("if:" expr)
      handle(rest)
      pop()
    }
    return
  }
  if (low ~ /^(stop|call|set|unset|continue)([ \t]|$)/) return
  if (low ~ /^action[ \t]*\(/) {
    p = top_filter()
    do_action(stmt, p)
  } else if (low ~ /^(module|input|template|global|main_queue|parser|lookup_table|timezone|include|reload_lookup_table|ruleset|property|constant|ratelimit)[ \t]*\(/) {
    if (low ~ /^ruleset/ && stmt ~ /\{[ \t]*$/) push("ruleset")
    else if (stmt ~ /\{[ \t]*$/) push("block")
    return
  } else {
    handle_legacy(stmt)
  }
  if (stmt ~ /\}[ \t]*$/ && count_ch(stmt, "\\}") > count_ch(stmt, "\\{")) pop()
}

FNR == 1 {
  buf = ""
  sp = 0
  pend = ""
  cblock = 0
  prev_sel = ""
  n = split(FILENAME, parts, "/")
  own = (parts[n] == "40-auditd-kit.conf")
}

{
  line = clean($0)
  if (buf != "") buf = buf " " trim(line)
  else buf = trim(line)
  if (buf == "") next
  if (buf ~ /\\$/) {
    sub(/\\$/, "", buf)
    next
  }
  if (depth(buf) > 0) next
  stmt = buf
  buf = ""
  handle(stmt)
}

END {
  for (i = 1; i <= nt; i++) print "target " tlist[i]
  for (i = 1; i <= nf; i++) print "facility " flist[i]
  for (i = 1; i <= nc; i++) print "catchall " clist[i]
}
