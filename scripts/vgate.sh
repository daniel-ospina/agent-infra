#!/usr/bin/env bash
# vgate.sh — observable + clearable verification-gate bridge state (#561).
#
# The verification-gate extension bridges verified-file state through
# ~/.pi/agent/verification/latest.json (compound keys: "<worktree-root>::<rel>",
# verifier-authoritative stored hashes). The bridge is inert-by-design
# (recovery merges only current-root entries whose stored hash still matches
# disk) but agents had no first-class way to INSPECT or CLEAR it — indicator 2
# of issue #561 ("no manual ~/.pi/agent/verification surgery").
#
# Usage:
#   vgate.sh status              — print bridge path/mtime, per-entry
#                                  root::file + stored hash + disk match
#                                  preview, and the gate audit tail
#   vgate.sh clear               — drop THIS worktree root's entries from the
#                                  bridge (current git root resolved from cwd)
#   vgate.sh clear --root <R>    — drop entries whose compound root is <R>
#   vgate.sh clear --all         — remove the bridge file entirely
#
# ⛔ Fail-closed semantics: clearing only REMOVES verified state — the next git
# op simply re-blocks and re-verifies. It is never a gate bypass, so #285's
# no-auto-disable invariant is untouched. A RUNNING session's in-memory
# registry is process-local and is NOT affected by this script; a stuck block
# inside a live session is cured by the gate's own in-band diagnostics +
# escalation, not by this CLI (see the block message).
#
# Audit: every clear appends a JSONL line to ~/.pi/agent/audit/gate-events.jsonl
# (same file the extensions append to, schema {ts,event,extension,reason,...}).

set -euo pipefail

BRIDGE_DIR="${VGATE_BRIDGE_DIR:-$HOME/.pi/agent/verification}"
BRIDGE="$BRIDGE_DIR/latest.json"
AUDIT="$HOME/.pi/agent/audit/gate-events.jsonl"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

audit() { # $1=reason $2=root(optional)
  local reason="$1" root="${2:-}"
  mkdir -p "$(dirname "$AUDIT")"
  local extra=""
  [ -n "$root" ] && extra=", \"root\": \"$root\""
  # macOS/BSD date has no %N — second precision is sufficient for an audit stamp.
  printf '{"ts":"%s","event":"bridge_clear","extension":"verification-gate","reason":"%s","session_cwd":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" "$(pwd)" "$extra" >> "$AUDIT" 2>/dev/null || true
}

git_root() { # best-effort; empty when not in a repo
  git rev-parse --show-toplevel 2>/dev/null || true
}

status() {
  if [ ! -f "$BRIDGE" ]; then
    echo "vgate: no bridge at $BRIDGE (no verification state to observe)"
    [ -f "$AUDIT" ] && { echo "audit tail (gate-events.jsonl):"; tail -n 5 "$AUDIT"; }
    exit 0
  fi
  local root; root="$(git_root)"
  local mtime size
  mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$BRIDGE" 2>/dev/null || stat -c "%y" "$BRIDGE" 2>/dev/null || echo "?")
  size=$(stat -f "%z" "$BRIDGE" 2>/dev/null || stat -c "%s" "$BRIDGE" 2>/dev/null || echo "?")
  echo "vgate bridge: $BRIDGE"
  echo "  mtime: $mtime  size: ${size}B  (current git root: ${root:-<not-a-repo>})"
  echo "  entries:"
  python3 - "$BRIDGE" "$root" <<'PYEOF'
import json, os, sys, hashlib
bridge, root = sys.argv[1], (sys.argv[2] or "")
try:
    data = json.load(open(bridge))
except Exception as e:
    print(f"  ⚠️ unreadable/corrupt: {e}")
    sys.exit(0)
files = data.get("verified_files", [])
if not files:
    print("  (none)")
for vf in files:
    path = vf.get("path", "?")
    h = vf.get("hash", "?")
    # compound key "<root>::<rel>" → disk preview of the rel path under root
    disk = "n/a"
    if "::" in path:
        r, rel = path.split("::", 1)
        if os.path.isfile(os.path.join(r, rel)):
            try:
                disk = hashlib.sha256(open(os.path.join(r, rel), "rb").read()).hexdigest()
            except Exception:
                disk = "unreadable"
        else:
            disk = "missing"
    print(f"  - {path}")
    print(f"      stored: {h}")
    print(f"      disk:   {disk}   ({'match' if disk not in ('n/a','missing','unreadable') and disk == h else 'NO MATCH — recovery drops this entry (fail-closed)' if disk != 'n/a' else ''})")
PYEOF
  [ -f "$AUDIT" ] && { echo "audit tail (gate-events.jsonl):"; tail -n 5 "$AUDIT"; }
}

clear() { # $1=ALL or a root scope
  local scope="$1"
  [ -f "$BRIDGE" ] || { echo "vgate: no bridge at $BRIDGE — nothing to clear"; exit 0; }
  if [ "$scope" = "ALL" ]; then
    rm -f "$BRIDGE"
    echo "removed"
    return
  fi
  python3 - "$BRIDGE" "$scope" <<'PYEOF'
import json, sys
bridge, scope = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(bridge))
except Exception:
    print("unreadable"); sys.exit(0)
files = data.get("verified_files", [])
kept = [vf for vf in files if not str(vf.get("path", "")).startswith(scope + "::")]
data["verified_files"] = kept
data["cleared_by_vgate_sh"] = scope
with open(bridge, "w") as f:
    json.dump(data, f, indent=2)
print(len(files) - len(kept))
PYEOF
}


case "${1:-}" in
  status)
    status
    ;;
  clear)
    scope=""
    case "${2:-}" in
      --all) scope="ALL" ;;
      --root)
        [ -n "${3:-}" ] || usage
        scope="$3"
        ;;
      "")
        scope="$(git_root)" || true
        [ -n "$scope" ] || { echo "vgate: cannot resolve current git root — pass --root <R> or --all"; exit 1; }
        ;;
      *) usage ;;
    esac
    # #285-friendly warn: this only removes verified state (re-block, never a bypass).
    if [ "${TASK_HEARTBEAT:-}" = "1" ] && [ "${PI_MODE:-}" = "print" ]; then
      echo "vgate: ⚠️ running inside a task sub-agent — clearing removes parent-recovered bridge"
      echo "  entries for this root; the next commit will re-block and need a fresh [VGATE] dispatch."
    fi
    cleared=$(clear "$scope")
    if [ "$scope" = "ALL" ]; then
      audit "bridge_clear_all"
    else
      audit "bridge_clear_root" "$scope"
    fi
    if [ "$cleared" = "removed" ]; then
      echo "vgate: bridge file removed (scope: ALL) — next git op re-blocks until re-verified (fail-closed)"
    else
      echo "vgate: cleared $cleared entries (scope: $scope) — next git op re-blocks until re-verified (fail-closed)"
    fi
    ;;
  *) usage ;;
esac
