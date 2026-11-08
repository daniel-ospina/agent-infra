#!/usr/bin/env bash
# record-worktree.sh — teardown manifest for dispatch-created worktrees/branches
# (issue #195). Every worktree/branch a dispatch will create is RECORDED BEFORE
# the sub-agent starts; clean completion removes the records; an abort leaves
# them as the teardown trail consumed by scripts/scan-orphans.sh.
#
# Never fails the caller: an unwritable record path emits a WARNING and exits 0
# (a dispatch must never be blocked by bookkeeping).
#
# Usage:
#   bash scripts/record-worktree.sh add --branch <b> --worktree <dir> [--dispatch <id>] [--ts <ISO>] [--repo <label>]
#   bash scripts/record-worktree.sh done --dispatch <id> [--branch <b>] [--worktree <dir>]
#     --branch/--worktree narrow the prune to ONE record of that dispatch (a dispatch records
#     several worktrees; without them `done` clears every record under the dispatch).
#   bash scripts/record-worktree.sh status [--repo <label>]
#
# Env overrides (tests / unusual homes):
#   WORKTREES_RECORD   record file path (default ~/.pi/agent/worktrees.jsonl)
#   WORKTREES_REPO     default repo label (default: local)

set -euo pipefail

RECORD_FILE="${WORKTREES_RECORD:-$HOME/.pi/agent/worktrees.jsonl}"
DEFAULT_REPO="${WORKTREES_REPO:-local}"

MODE="${1:?usage: record-worktree.sh <add|done|status> ...}"
shift || true

case "$MODE" in
  add)
    BRANCH=""; DIR=""; DISPATCH="unknown"; TS=""; REPO="$DEFAULT_REPO"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        --worktree) DIR="$2"; shift 2 ;;
        --dispatch) DISPATCH="$2"; shift 2 ;;
        --ts) TS="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$BRANCH" ] || { echo "missing --branch" >&2; exit 1; }
    [ -n "$DIR" ] || { echo "missing --worktree" >&2; exit 1; }
    [ -n "$TS" ] || TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! mkdir -p "$(dirname "$RECORD_FILE")" 2>/dev/null || \
       ! printf '{"ts":"%s","branch":"%s","worktree":"%s","dispatch":"%s","repo":"%s"}\n' \
         "$TS" "$BRANCH" "$DIR" "$DISPATCH" "$REPO" >> "$RECORD_FILE" 2>/dev/null; then
      echo "WARNING: could not write teardown record ($RECORD_FILE) — continuing (dispatch must not be blocked)" >&2
      exit 0
    fi
    ;;
  done)
    DISPATCH=""; ONLY_BRANCH=""; ONLY_WORKTREE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dispatch) DISPATCH="$2"; shift 2 ;;
        --branch) ONLY_BRANCH="$2"; shift 2 ;;
        --worktree) ONLY_WORKTREE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$DISPATCH" ] || { echo "missing --dispatch" >&2; exit 1; }
    if [ -f "$RECORD_FILE" ]; then
      # ⛔ PRUNE BY THE RECORD'S OWN IDENTITY, NOT BY ITS DISPATCH ALONE (#1393 R12-F1).
      # `--dispatch` is not an identity: one dispatch records SEVERAL worktrees, so a reaper that
      # cleared one record erased every sibling record under the same dispatch — including a
      # record the same sweep had just KEPT. The surviving dirty tree then lost the teardown trail
      # whose whole purpose is to make the next sweep re-report it.
      # `--branch`/`--worktree` narrow the prune to the ONE record the caller actually examined.
      # Both are OPTIONAL, so without them this keeps its documented whole-dispatch meaning and
      # every existing caller is unchanged.
      # Keys are matched with their closing quote (`"branch":"x"` never matches `"branch":"xy"`),
      # the same pinning the sibling scanners use.
      # ⛔ FAIL-SAFE REWRITE: a filter that dies mid-write must LEAVE the file alone. Replacing it
      # with a partial temp file would destroy the entire teardown trail — the one failure mode
      # this file must never have.
      if awk -v want_d="$DISPATCH" -v want_b="$ONLY_BRANCH" -v want_w="$ONLY_WORKTREE" '
             {
               hit = index($0, "\"dispatch\":\"" want_d "\"") > 0
               if (hit && want_b != "") hit = index($0, "\"branch\":\"" want_b "\"") > 0
               if (hit && want_w != "") hit = index($0, "\"worktree\":\"" want_w "\"") > 0
               if (!hit) print
             }' "$RECORD_FILE" > "$RECORD_FILE.tmp" 2>/dev/null; then
        mv "$RECORD_FILE.tmp" "$RECORD_FILE" 2>/dev/null || true
      else
        rm -f "$RECORD_FILE.tmp" 2>/dev/null || true
      fi
    fi
    ;;
  status)
    REPO=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$REPO" ] || REPO="$DEFAULT_REPO"
    TOTAL=0; SHOWN=0
    if [ -f "$RECORD_FILE" ]; then
      TOTAL="$(wc -l < "$RECORD_FILE" | tr -d ' ')"
      SHOWN="$(grep -c "\"repo\":\"$REPO\"" "$RECORD_FILE" 2>/dev/null || echo 0)"
    fi
    echo "$SHOWN/$TOTAL record(s) shown for repo '$REPO'"
    ;;
  *)
    echo "usage: record-worktree.sh <add|done|status> ..." >&2
    exit 1
    ;;
esac
