#!/bin/bash
# ============================================================
# check-pi-config-extensions.sh — pi-config extensions drift gate (issue #95)
#
# Enforces the single-source-of-truth invariant:
#   pi-bootstrap/pi-config/extensions/* MUST be symlinks resolving into
#   extensions/ — never materialized copies, which is what went stale before.
#
# Checks:
#   1. Every pi-config/extensions entry is a symlink (a real copy = drift risk).
#   2. Every entry resolves (realpath) to extensions/<name> — clone-path agnostic.
#   3. Set parity: every extensions/ top-level entry except *.test.ts is wired
#      into pi-config (a new extension that isn't wired ships on NO machine).
#
# Because each entry IS the extensions/ file/dir (via symlink), content can
# never drift between the two trees; checks 1-3 close every drift mode:
#   - copy materialized over a link            -> fails check 1
#   - link retargeted elsewhere / broken       -> fails check 2
#   - entry deleted, or new ext not added      -> fails check 3
#
# Usage:  bash scripts/check-pi-config-extensions.sh
# Exit:   0 = invariant holds, 1 = drift found (details printed to stdout).
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/pi-bootstrap/pi-config/extensions"
DST="$ROOT/extensions"
FAILURES=0

# Resolve to an absolute, symlink-free path ("" when unresolvable).
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

if [ ! -d "$SRC" ]; then
  echo "❌ pi-config/extensions missing at $SRC — nothing to gate"
  exit 1
fi
if [ ! -d "$DST" ]; then
  echo "❌ extensions/ missing at $DST — nothing to compare against"
  exit 1
fi

# --- checks 1 + 2: every pi-config entry is a symlink into extensions/ -------
for e in "$SRC"/*; do
  [ -e "$e" ] || [ -L "$e" ] || continue   # skip empty glob only, NOT broken links (P2 #95-review)
  base="$(basename "$e")"

  if [ ! -L "$e" ]; then
    echo "❌ pi-config/extensions/$base is NOT a symlink (materialized copy — will drift)"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  src_res="$(resolve_path "$e")"
  dst_res="$(resolve_path "$DST/$base")"
  if [ -z "$src_res" ] || [ -z "$dst_res" ] || [ "$src_res" != "$dst_res" ]; then
    echo "❌ pi-config/extensions/$base -> $(readlink "$e") does not resolve to extensions/$base"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- check 3: set parity — every real extension is wired into pi-config ------
for e in "$DST"/*; do
  [ -e "$e" ] || continue
  base="$(basename "$e")"
  case "$base" in
    *.test.ts) continue ;;   # test files are not extensions; not shipped
  esac
  if [ ! -L "$SRC/$base" ]; then
    echo "❌ extension $base exists in extensions/ but is not wired into pi-config/extensions (fresh machines won't get it)"
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "❌ $FAILURES pi-config/extensions drift issue(s) — fix or the bootstrap ships stale/partial extensions"
  exit 1
fi

echo "✅ pi-config/extensions = symlink farm into extensions/ (single source of truth, $(( $(ls -1 "$SRC" | wc -l | tr -d ' ') )) entries)"
