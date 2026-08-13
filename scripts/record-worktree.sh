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
#   bash scripts/record-worktree.sh done --dispatch <id>
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
    DISPATCH=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dispatch) DISPATCH="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$DISPATCH" ] || { echo "missing --dispatch" >&2; exit 1; }
    if [ -f "$RECORD_FILE" ]; then
      grep -v "\"dispatch\":\"$DISPATCH\"" "$RECORD_FILE" > "$RECORD_FILE.tmp" 2>/dev/null || true
      mv "$RECORD_FILE.tmp" "$RECORD_FILE" 2>/dev/null || true
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
