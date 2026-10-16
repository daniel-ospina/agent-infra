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
#   4. Manifest parity: manifest.json files.extensions.entries (the consumer
#      ship-list materialized by bin/agent-infra.js into ~/.pi/agent/extensions/)
#      and the extensions/ tree must name the SAME set (dirs normalized — the
#      manifest records "dir/", the tree "dir" — and *.test.ts excluded from
#      both sides). A new extension with no manifest row ships on NO consumer
#      (#498 staleness class); a stale manifest row for a deleted extension
#      breaks every consumer bootstrap.
#   5. LIVE-FARM LIVENESS (machine-local — checks 1-4 gate the repo, this one
#      gates the materialized farm at ~/.pi/agent/extensions/). Every
#      manifest-listed entry that IS a symlink there must RESOLVE to a path
#      that exists. A dangling link is silent: pi does not load the extension,
#      so a guard the link was carrying is simply ABSENT with nothing anywhere
#      reporting it (#1214b parked the clamp-output-floor link on a worktree
#      while its PR was open; that link dies the moment the worktree is
#      removed). Scope is the manifest ship-list on purpose — machine-local
#      links this repo does not ship are not this gate's business, so it cannot
#      false-block on someone else's half-installed farm. An absent farm prints
#      an explicit STOP line and passes, and an absent link for a row is simply
#      not inspected; PI_EXTENSIONS_DIR overrides the farm root for
#      tests/pi-config-extensions/run.sh.
#
# Because each entry IS the extensions/ file/dir (via symlink), content can
# never drift between the two trees; checks 1-3 close every farm drift mode:
#   - copy materialized over a link            -> fails check 1
#   - link retargeted elsewhere / broken       -> fails check 2
#   - entry deleted, or new ext not added      -> fails check 3
# Check 4 closes the manifest drift mode:
#   - tree and manifest rows diverge           -> fails check 4
# Check 5 closes the machine-local half of that same row set:
#   - a shipped link's target was removed      -> fails check 5
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

# --- check 4: manifest ↔ tree set parity (issue #502) ------------------------
# manifest.json files.extensions.entries is the consumer ship-list that
# bin/agent-infra.js materializes into ~/.pi/agent/extensions/ on every
# bootstrap. Checks 1-3 gate the farm ↔ tree pair; the manifest is a THIRD
# surface that can silently lose/gain rows (#498 fixed one such stale row —
# session-checks.ts existed in the tree but had no manifest entry, so
# consumers farmed via bin/agent-infra.js never got it).
#
# JSON is parsed with python3 stdlib (the sibling gate check-cost-config.sh
# sets the convention: "bash + POSIX coreutils + python3 (stdlib only)").
MANIFEST="$ROOT/manifest.json"
parse_ok=1
if [ ! -f "$MANIFEST" ]; then
  echo "❌ manifest.json missing at $MANIFEST — consumer ship-list is ungated"
  FAILURES=$((FAILURES + 1))
  parse_ok=0
elif ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 required (stdlib json) to read $MANIFEST entries — present on ubuntu-latest + macOS"
  FAILURES=$((FAILURES + 1))
  parse_ok=0
else
  # Normalized manifest rows (trailing slash stripped — manifest records dirs
  # as "dir/"; the tree lists bare basenames). One row per line; empty when
  # the entries array is missing/empty (fail-closed on the tree→manifest loop
  # below).
  manifest_rows="$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except (OSError, ValueError):
    sys.exit(1)

for e in (m.get("files") or {}).get("extensions/", {}).get("entries") or []:
    print(str(e).rstrip("/"))
PYEOF
)" || {
    echo "❌ cannot parse $MANIFEST — malformed JSON or missing files.extensions.entries"
    FAILURES=$((FAILURES + 1))
    parse_ok=0
  }
fi

# 4a/4b run whenever the manifest parsed cleanly, INDEPENDENT of farm checks
# 1-3 — masking manifest drift behind farm drift would let a merged PR ship
# both at once. (Guard on parse_ok, not FAILURES: prior failures must not
# suppress the manifest report.)
if [ "$parse_ok" -eq 1 ]; then
  # 4a — every real extension (except *.test.ts) must have a manifest row.
  for e in "$DST"/*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in
      *.test.ts) continue ;;   # test files are not shipped; never in manifest
    esac
    if ! grep -Fqx "$base" <<<"$manifest_rows"; then
      echo "❌ extension $base exists in extensions/ but has no manifest.json files.extensions.entries row (bin/agent-infra.js consumers won't get it)"
      FAILURES=$((FAILURES + 1))
    fi
  done

  # 4b — every manifest row must resolve to a real extensions/ entry.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ ! -e "$DST/$row" ]; then
      echo "❌ manifest.json row \"$row\" has no matching extensions/ entry (stale — every consumer bootstrap will fail)"
      FAILURES=$((FAILURES + 1))
    fi
  done <<< "$manifest_rows"
fi

# --- check 5: live-farm liveness (machine-local; CI has no ~/.pi) ------------
# See the header. Only manifest-listed entries are inspected, and only when they
# are present as symlinks: an absent live link is not this gate's business (the
# machine may simply not be bootstrapped for that row), and a link this repo
# does not ship is somebody else's state. Guarded by parse_ok because
# manifest_rows only exists once the manifest parsed.
if [ "$parse_ok" -eq 1 ]; then
  LIVE_FARM="${PI_EXTENSIONS_DIR:-${HOME:-}/.pi/agent/extensions}"
  if [ ! -d "$LIVE_FARM" ]; then
    echo "⏭️  live extension farm not found at $LIVE_FARM — check 5 (dangling shipped links) skipped; set PI_EXTENSIONS_DIR to aim it at a farm"
  else
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      live="$LIVE_FARM/$row"
      [ -L "$live" ] || continue   # not farmed as a link here — not this gate's row
      if [ ! -e "$live" ]; then
        echo "❌ live farm link $row -> $(readlink "$live") is DANGLING (target does not exist) — pi loads NOTHING for it, so that extension is silently absent; repoint it at an existing checkout (bin/agent-infra.js, or \`ln -sf\`)"
        FAILURES=$((FAILURES + 1))
      fi
    done <<< "$manifest_rows"
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "❌ $FAILURES pi-config/extensions drift issue(s) — fix or the bootstrap ships stale/partial extensions"
  exit 1
fi

echo "✅ pi-config/extensions = symlink farm into extensions/ (single source of truth, $(( $(ls -1 "$SRC" | wc -l | tr -d ' ') )) entries)"
echo "✅ manifest.json files.extensions.entries ↔ extensions/ tree parity holds (check 4)"
