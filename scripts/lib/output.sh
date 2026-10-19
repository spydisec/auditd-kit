# Collect key=value pairs and print them as text or JSON. Source this file, don't run it.
# shellcheck shell=sh

# Pairs are kept as "key=value" records ended by the ASCII record separator (octal 036),
# so a value can hold newlines until the flush.
AKIT_KV_BUF=
AKIT_KV_RS=$(printf '\036')

# akit_kv <key> <value>: add a pair.
akit_kv() {
  AKIT_KV_BUF="${AKIT_KV_BUF}$1=$2${AKIT_KV_RS}"
}

# akit_kv_flush <text|json>: print the collected pairs, then forget them.
akit_kv_flush() {
  printf '%s' "$AKIT_KV_BUF" | awk -v mode="$1" '
    BEGIN {
      RS = "\036"
      for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      ctl["\t"] = "\\t"
      ctl["\n"] = "\\n"
      ctl["\r"] = "\\r"
      ctl["\b"] = "\\b"
      ctl["\f"] = "\\f"
      n = 0
    }
    {
      eq = index($0, "=")
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      if (mode == "json") {
        out = ""
        len = length(val)
        for (i = 1; i <= len; i++) {
          c = substr(val, i, 1)
          if (c == "\\") c = "\\\\"
          else if (c == "\"") c = "\\\""
          else if (c in ctl) c = ctl[c]
          out = out c
        }
        items[++n] = "\"" key "\":\"" out "\""
      } else {
        gsub(/\n/, " ", val)
        print key "=" val
      }
    }
    END {
      if (mode == "json") {
        s = "{"
        for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") items[i]
        print s "}"
      }
    }'
  AKIT_KV_BUF=
}
