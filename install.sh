#!/bin/bash
# claude-sound-effects installer.
# Copies the sfx/ folder to ~/.claude/sfx and merges the hooks into
# ~/.claude/settings.json without clobbering hooks you already have.
#
#   curl -fsSL https://raw.githubusercontent.com/spencerlepine/claude-sound-effects/main/install.sh | bash
#
# Uses only what ships with macOS: bash, awk, git, plutil.

set -euo pipefail

REPO="https://github.com/spencerlepine/claude-sound-effects"
DEST="$HOME/.claude"
SETTINGS="$DEST/settings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- locate the source: a local clone if we're in one, otherwise fetch it ----
SELF_DIR=""
case "${BASH_SOURCE[0]:-}" in
  */*) SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
  ?*)  [ -f "$PWD/${BASH_SOURCE[0]}" ] && SELF_DIR="$PWD" ;;   # `bash install.sh`
esac

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/.claude/settings.json" ]; then
  SRC="$SELF_DIR"
else
  echo "==> fetching $REPO"
  git clone --depth 1 --quiet "$REPO" "$TMP/repo"
  SRC="$TMP/repo"
fi

[ -f "$SRC/.claude/settings.json" ] || { echo "error: $SRC/.claude/settings.json not found" >&2; exit 1; }

# --- 1. sound files ---------------------------------------------------------
if [ -L "$DEST/sfx" ]; then
  echo "==> ~/.claude/sfx is a symlink; leaving it alone"
else
  mkdir -p "$DEST/sfx"
  cp -R "$SRC/.claude/sfx/." "$DEST/sfx/"
  echo "==> installed $(ls -1 "$DEST/sfx" | wc -l | tr -d ' ') sound files to ~/.claude/sfx"
fi

# --- 2. merge hooks ---------------------------------------------------------
if [ -s "$SETTINGS" ]; then
  cp "$SETTINGS" "$TMP/current.json"
  cp "$SETTINGS" "$SETTINGS.bak"
else
  mkdir -p "$DEST"
  printf '{\n}\n' > "$TMP/current.json"
fi

cat > "$TMP/merge.awk" <<'AWK'
# Walks JSON as text so the destination file keeps its own formatting and any
# keys we do not touch. Quote- and escape-aware throughout.

function skipstr(s, i,   c) {            # i is at '"'; return index just past it
  i++
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "\"") return i + 1
    i++
  }
  return i
}
function matchbr(s, i,   op, cl, d, c) { # i is at '{' or '['; return its partner
  op = substr(s, i, 1); cl = (op == "{") ? "}" : "]"; d = 0
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\"") { i = skipstr(s, i); continue }
    if (c == op) d++
    else if (c == cl) { d--; if (d == 0) return i }
    i++
  }
  return 0
}
function nextch(s, i, ch,   c) {         # next literal ch at/after i, outside strings
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\"") { i = skipstr(s, i); continue }
    if (c == ch) return i
    i++
  }
  return 0
}
function findkey(s, from, to, key,   i, c, d, p, q, j) {  # key at depth 1 of from..to
  d = 0; i = from
  while (i <= to) {
    c = substr(s, i, 1)
    if (c == "\"") {
      p = i; q = skipstr(s, i)
      if (d == 1 && substr(s, p, q - p) == "\"" key "\"") {
        j = q
        while (j <= to && substr(s, j, 1) ~ /[ \t\r\n]/) j++
        if (substr(s, j, 1) == ":") return p    # a key, not a value that looks like one
      }
      i = q; continue
    }
    if (c == "{" || c == "[") { d++; i++; continue }
    if (c == "}" || c == "]") { d--; i++; continue }
    i++
  }
  return 0
}
function compact(s,   i, c, out, p, q) { # strip whitespace outside strings
  out = ""; i = 1
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\"") { p = i; q = skipstr(s, i); out = out substr(s, p, q - p); i = q; continue }
    if (c !~ /[ \t\r\n]/) out = out c
    i++
  }
  return out
}
function ins(s, b, text,   j, c) {       # insert text just inside bracket at b
  j = b + 1
  while (substr(s, j, 1) ~ /[ \t\r\n]/) j++
  c = substr(s, j, 1)
  if (c == "}" || c == "]") return substr(s, 1, b) "\n" text "\n" substr(s, j)
  return substr(s, 1, b) "\n" text ",\n" substr(s, j)
}

FNR == NR { src = src $0 "\n"; next }
           { dst = dst $0 "\n" }

END {
  # collect (event, entry) pairs from the repo's settings.json
  sb = nextch(src, 1, "{")
  hk = findkey(src, sb, matchbr(src, sb), "hooks")
  if (hk == 0) { print dst; exit 0 }
  ho = nextch(src, hk, "{"); he = matchbr(src, ho)

  i = ho + 1; d = 1
  while (i < he) {
    c = substr(src, i, 1)
    if (c == "\"") {
      p = i; q = skipstr(src, i)
      if (d == 1) {
        name = substr(src, p + 1, q - p - 2)
        a = nextch(src, q, "["); e = matchbr(src, a)
        k = a + 1
        while (k < e) {
          if (substr(src, k, 1) == "{") {
            m = matchbr(src, k)
            n++; evs[n] = name; ents[n] = substr(src, k, m - k + 1)
            k = m + 1
          } else k++
        }
        i = e + 1; continue
      }
      i = q; continue
    }
    if (c == "{" || c == "[") { d++; i++; continue }
    if (c == "}" || c == "]") { d--; i++; continue }
    i++
  }

  for (t = 1; t <= n; t++) {
    if (index(compact(dst), compact(ents[t])) > 0) continue   # already there

    db = nextch(dst, 1, "{")
    dh = findkey(dst, db, matchbr(dst, db), "hooks")
    if (dh == 0) {
      dst = ins(dst, db, "  \"hooks\": {}")
      db = nextch(dst, 1, "{")
      dh = findkey(dst, db, matchbr(dst, db), "hooks")
    }
    dho = nextch(dst, dh, "{")
    ek = findkey(dst, dho, matchbr(dst, dho), evs[t])
    if (ek == 0) {
      dst = ins(dst, dho, "    \"" evs[t] "\": []")
      dho = nextch(dst, dh, "{")
      ek = findkey(dst, dho, matchbr(dst, dho), evs[t])
    }
    dst = ins(dst, nextch(dst, ek, "["), "      " ents[t])
    added++
  }

  printf "%s", dst
  printf "%d", added+0 > COUNT
}
AWK

awk -v COUNT="$TMP/added" -f "$TMP/merge.awk" \
    "$SRC/.claude/settings.json" "$TMP/current.json" > "$TMP/merged.json"

if ! plutil -convert xml1 -o /dev/null "$TMP/merged.json" 2>/dev/null; then
  echo "error: merge produced invalid JSON; ~/.claude/settings.json left untouched" >&2
  exit 1
fi

cp "$TMP/merged.json" "$SETTINGS"
echo "==> added $(cat "$TMP/added") hook(s) to ~/.claude/settings.json"
if [ -f "$SETTINGS.bak" ]; then
  echo "    (previous version saved as ~/.claude/settings.json.bak)"
fi
echo "==> done — restart Claude Code to hear it"
