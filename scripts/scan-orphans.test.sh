#!/usr/bin/env bash
# scan-orphans.test.sh — self-check for scripts/record-worktree.sh +
# scripts/scan-orphans.sh (issue #195 teardown fix).
#
# Run: bash scripts/scan-orphans.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds a
# throwaway git repo + bare origin in a temp dir, never touches the real
# ~/.pi/agent/worktrees.jsonl (WORKTREES_RECORD isolates every invocation).
#
# Coverage:
#   writer: add appends JSONL with all fields | done removes by dispatch
#           | status repo-filters | add warns (exit 0) on unwritable record
#   scanner: no records → clean | stale orphan flagged in dry-run
#           | recent record listed as RECENT, not orphan | branch on origin LIVE
#           | dirty worktree listed separately + refused by --apply
#           | --apply removes worktree+branch+record | ghost record pruned
#           | unrecorded worktrees/branches listed (informational)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

assert_not_contains() {
    if ! printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (unexpected: $2)"; fi
}

assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

# ── Fixture: temp dir + bare origin + work repo ──────────────────────────
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
ORIGIN="$FIX/origin.git"
REPO="$FIX/repo"
export WORKTREES_RECORD="$FIX/records.jsonl"
export WORKTREES_REPO=local

git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email test@test.test
git config user.name "Test Runner"
git remote add origin "$ORIGIN"
mkdir -p scripts
cp "$SCRIPT_DIR/record-worktree.sh" "$SCRIPT_DIR/scan-orphans.sh" scripts/
echo base > file.txt
git add . && git commit -qm init
git push -q origin main

RW="bash scripts/record-worktree.sh"
SCAN="bash scripts/scan-orphans.sh"

echo "=== 1. record-worktree.sh: add/done/status ==="

# 1a. add appends a JSONL record with all fields
$RW add --branch fix/orphan-801 --worktree /tmp/wt-801 --dispatch d-801 --ts 2026-08-01T00:00:00Z >/dev/null
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "add appends one record"
LINE="$(cat "$WORKTREES_RECORD")"
assert_contains "$LINE" '"ts":"2026-08-01T00:00:00Z"' "record has ts"
assert_contains "$LINE" '"branch":"fix/orphan-801"' "record has branch"
assert_contains "$LINE" '"worktree":"/tmp/wt-801"' "record has worktree"
assert_contains "$LINE" '"dispatch":"d-801"' "record has dispatch"
assert_contains "$LINE" '"repo":"local"' "record has repo"

# 1b. done removes records for the dispatch
$RW done --dispatch d-801 >/dev/null
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "0" "done removes the record"

# 1c. status reports counts and repo-filtering
$RW add --branch fix/a --worktree /tmp/wt-a --dispatch d-a --repo local >/dev/null
$RW add --branch fix/b --worktree /tmp/wt-b --dispatch d-b --repo other/repo >/dev/null
OUT="$($RW status --repo local)"
assert_contains "$OUT" "1/2 record(s) shown" "status filters by repo"
$RW done --dispatch d-a >/dev/null
$RW done --dispatch d-b >/dev/null

# 1d. unwritable record path → warning, exit 0 (dispatch never blocked)
touch "$FIX/afile"
set +e
OUT="$(WORKTREES_RECORD="$FIX/afile/x.jsonl" $RW add --branch fix/c --worktree /tmp/wt-c --dispatch d-c 2>&1)"
RC=$?
set -e
assert_eq "$RC" "0" "add exits 0 when record unwritable"
assert_contains "$OUT" "WARNING" "add warns when record unwritable"

echo "=== 2. scan-orphans.sh: classification ==="

# 2a. no records → clean
OUT="$($SCAN)"
assert_contains "$OUT" "No orphaned worktrees/branches found" "clean run with no records"

# 2b. stale orphan flagged in dry-run, nothing removed
git checkout -qb fix/orphan-801
echo wip > file.txt && git commit -qam wip
git checkout -q main
git worktree add -q "$FIX/wt-801" fix/orphan-801
$RW add --branch fix/orphan-801 --worktree "$FIX/wt-801" --dispatch d-801 --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN)"
assert_contains "$OUT" "ORPHANED (safe to remove)" "dry-run flags stale orphan"
assert_contains "$OUT" "fix/orphan-801" "dry-run names the branch"
assert_contains "$OUT" "DRY-RUN: nothing removed" "dry-run deletes nothing"
[ -d "$FIX/wt-801" ] && ok "worktree untouched by dry-run" || bad "worktree removed by dry-run"

# 2c. recent record → listed as RECENT, NOT as orphan
git worktree add -q "$FIX/wt-recent" -b fix/recent-1
$RW add --branch fix/recent-1 --worktree "$FIX/wt-recent" --dispatch d-recent >/dev/null
OUT="$($SCAN)"
ORPHAN_BLOCK="$(printf '%s' "$OUT" | sed -n '/ORPHANED (safe to remove)/,/── Summary ──/p')"
assert_contains "$OUT" "── RECENT (recorded, not yet stale" "RECENT section present"
assert_contains "$OUT" "fix/recent-1" "RECENT section names the branch"
assert_not_contains "$ORPHAN_BLOCK" "fix/recent-1" "recent branch not in orphan block"
$RW done --dispatch d-recent >/dev/null
git worktree remove --force "$FIX/wt-recent" >/dev/null
git branch -D fix/recent-1 >/dev/null

# 2d. branch pushed to origin → LIVE, not flagged
git branch fix/pushed-1
git push -q origin fix/pushed-1
git fetch -q origin
$RW add --branch fix/pushed-1 --worktree /tmp/nowhere --dispatch d-pushed --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN)"
ORPHAN_BLOCK="$(printf '%s' "$OUT" | sed -n '/ORPHANED (safe to remove)/,/── Summary ──/p')"
assert_not_contains "$ORPHAN_BLOCK" "fix/pushed-1" "pushed branch not flagged"
assert_contains "$OUT" "Live: 1" "summary counts live branch"
$RW done --dispatch d-pushed >/dev/null

# 2e. dirty worktree → DIRTY section; --apply refuses without --force-dirty
git worktree add -q "$FIX/wt-dirty" -b fix/dirty-1
echo uncommitted > "$FIX/wt-dirty/extra.txt"
$RW add --branch fix/dirty-1 --worktree "$FIX/wt-dirty" --dispatch d-dirty --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN)"
assert_contains "$OUT" "ORPHANED BUT DIRTY" "dirty worktree listed separately"
$SCAN --apply >/dev/null 2>&1 || true
[ -d "$FIX/wt-dirty" ] && ok "--apply refuses dirty worktree" || bad "--apply removed dirty worktree"
$SCAN --apply --force-dirty >/dev/null 2>&1 || true
[ ! -d "$FIX/wt-dirty" ] && ok "--force-dirty removes worktree" || bad "--force-dirty did not remove worktree"
git branch | grep -q fix/dirty-1 && bad "dirty branch survives --force-dirty" || ok "--force-dirty deletes branch"

# 2f. --apply removes orphan worktree + branch + record (fresh orphan)
git checkout -qb fix/orphan-802
echo wip2 > file.txt && git commit -qam wip2
git checkout -q main
git worktree add -q "$FIX/wt-802" fix/orphan-802
$RW add --branch fix/orphan-802 --worktree "$FIX/wt-802" --dispatch d-802 --ts 2026-08-01T00:00:00Z >/dev/null
$SCAN --apply >/dev/null 2>&1 || true
[ ! -d "$FIX/wt-802" ] && ok "--apply removes worktree" || bad "--apply left worktree"
git branch | grep -q fix/orphan-802 && bad "branch survives --apply" || ok "--apply deletes branch"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "0" "--apply prunes the record"
OUT="$($SCAN)"
assert_contains "$OUT" "No orphaned worktrees/branches found" "sweep clean after apply"

# 2g. ghost record (branch + dir never existed) → GHOST; --apply prunes
$RW add --branch fix/ghost-1 --worktree /tmp/wt-ghost-never --dispatch d-ghost --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN)"
assert_contains "$OUT" "GHOST RECORDS" "ghost record flagged"
$SCAN --apply >/dev/null 2>&1 || true
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "0" "--apply prunes ghost record"

# 2h. unrecorded worktree/branch listed as informational, never applied
git worktree add -q "$FIX/wt-unrecorded" -b fix/unrecorded-1
OUT="$($SCAN)"
assert_contains "$OUT" "UNRECORDED" "unrecorded section present"
assert_contains "$OUT" "wt-unrecorded" "unrecorded worktree listed"
assert_contains "$OUT" "fix/unrecorded-1" "unrecorded branch listed"
$SCAN --apply >/dev/null 2>&1 || true
[ -d "$FIX/wt-unrecorded" ] && ok "--apply never touches unrecorded" || bad "--apply removed unrecorded worktree"
git branch | grep -q fix/unrecorded-1 && ok "unrecorded branch survives" || bad "unrecorded branch deleted"

# 2i. poisoned record (arbitrary dir, not a registered worktree) → --apply
#     must NEVER delete it (P1 safety gate, review #216)
mkdir -p "$FIX/important-dir"
echo precious > "$FIX/important-dir/data.txt"
git branch fix/poison-1
$RW add --branch fix/poison-1 --worktree "$FIX/important-dir" --dispatch d-poison --ts 2026-08-01T00:00:00Z >/dev/null
$SCAN --apply >/dev/null 2>&1 || true
[ -f "$FIX/important-dir/data.txt" ] && ok "--apply never deletes an unregistered dir" || bad "--apply DELETED an arbitrary dir (P1!)"
git branch | grep -q fix/poison-1 && bad "poison branch survives --apply" || ok "--apply still deletes the local-only branch"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "0" "--apply prunes the poison record"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== scan-orphans.test.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
