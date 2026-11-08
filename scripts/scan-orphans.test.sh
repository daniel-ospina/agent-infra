#!/usr/bin/env bash
# shard: off NO CI run site in either lane (pre-existing; tracked in agent-infra#2610) - wiring it is a coverage decision, not a side effect of a refactor
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
#   #1393 destructive gates:
#           | an unmeasurable tree is NEVER read as clean (G1)
#           | dirt is checked whether or not git still registers the worktree (G2)
#           | the branch delete is a compare-and-delete, never `git branch -D` (G3)
#           | a surviving tree keeps its branch (G4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

assert_not_contains() {
    if ! grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (unexpected: $2)"; fi
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
#     must NEVER delete it, and must NEVER delete its branch either (#1393 G2+G4).
#     The old behaviour removed the dir never but the BRANCH always — a tree that
#     survives with its ref force-deleted is one of the two halves #1393 reported.
#     An unregistered tree's state cannot be read at all, so the branch may be the
#     only ref to work that is sitting in it.
mkdir -p "$FIX/important-dir"
echo precious > "$FIX/important-dir/data.txt"
git branch fix/poison-1
$RW add --branch fix/poison-1 --worktree "$FIX/important-dir" --dispatch d-poison --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN --apply 2>&1 || true)"
[ -f "$FIX/important-dir/data.txt" ] && ok "--apply never deletes an unregistered dir" || bad "--apply DELETED an arbitrary dir (P1!)"
assert_contains "$OUT" "ORPHANED BUT DIRTY" "unregistered dir is not classified 'safe to remove'"
assert_contains "$OUT" "state UNMEASURABLE" "unmeasured state is named as such, never as clean"
git branch | grep -q fix/poison-1 && ok "unregistered record keeps its branch (tree survives => ref kept)" || bad "--apply deleted the branch of a surviving tree"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "--apply keeps the record for a human to resolve"
assert_contains "$OUT" "KEPT by --apply: 1 record(s)" "a sweep that kept something says so"
#     --force-dirty does NOT authorize removing a directory git does not vouch for.
$SCAN --apply --force-dirty >/dev/null 2>&1 || true
[ -f "$FIX/important-dir/data.txt" ] && ok "--force-dirty leaves an unregistered dir alone" || bad "--force-dirty DELETED an unregistered dir"
git branch | grep -q fix/poison-1 && ok "--force-dirty keeps its branch" || bad "--force-dirty deleted its branch"
$RW done --dispatch d-poison >/dev/null
git branch -D fix/poison-1 >/dev/null

# 2j. a registered worktree whose removal FAILS → the branch is KEPT too (#1393 G4).
#     `git worktree remove --force` can fail (permissions, a held file); the old code
#     then deleted the branch anyway, and the surviving tree's uncommitted work lost
#     its only ref. Simulated by making the worktree directory non-writable.
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 2j (running as root — chmod cannot deny removal)"
else
    git worktree add -q "$FIX/wt-keep" -b fix/keep-1
    $RW add --branch fix/keep-1 --worktree "$FIX/wt-keep" --dispatch d-keep --ts 2026-08-01T00:00:00Z >/dev/null
    chmod a-w "$FIX/wt-keep"
    OUT="$($SCAN --apply 2>&1 || true)"
    chmod u+w "$FIX/wt-keep"
    if [ -d "$FIX/wt-keep" ]; then
        git branch | grep -q fix/keep-1 && ok "failed worktree removal keeps the branch" || bad "branch deleted although the tree survived"
        assert_contains "$OUT" "KEPT tree+ref+record" "the refusal is named"
        $RW done --dispatch d-keep >/dev/null
        git worktree remove --force "$FIX/wt-keep" >/dev/null 2>&1 || true
        git branch -D fix/keep-1 >/dev/null 2>&1 || true
    else
        # The removal succeeded anyway on this platform/permission model; assert the
        # ordinary contract instead of pretending the scenario ran.
        git branch | grep -q fix/keep-1 && bad "worktree removed but branch survived" || ok "removal path still deletes tree+branch"
    fi
fi

# 2k. the ref delete is a COMPARE-AND-DELETE, never `git branch -D` (#1393 G3):
#     a moved tip must be refused rather than destroyed. Exercises the primitive the
#     script now relies on, on this git.
git branch fix/cas-1
git branch fix/cas-2
CAS_OLD="$(git rev-parse fix/cas-1)"
git checkout -q fix/cas-1 && echo moved >> file.txt && git commit -qam moved && git checkout -q main
if git update-ref -d refs/heads/fix/cas-1 "$CAS_OLD" 2>/dev/null; then
    bad "update-ref -d accepted a MOVED tip (the CAS this script relies on does not hold)"
else
    git show-ref --verify --quiet refs/heads/fix/cas-1 && ok "update-ref -d refuses a moved tip (CAS holds)" || bad "CAS refusal removed the ref anyway"
fi
git branch -D fix/cas-1 fix/cas-2 >/dev/null 2>&1 || true
assert_not_contains "$(grep -vE '^[[:space:]]*#' scripts/scan-orphans.sh)" "git branch -D" "script never calls git branch -D"

# ── #3799 review, Finding 1: `update-ref -d` does NOT inherit `git branch -D`'s
#    CHECKED-OUT refusal, so the swap must re-enumerate the worktrees itself.
# ── 2l. the branch is checked out in a LIVE worktree at a DIFFERENT path than the
#     record names (a lane that recreated its worktree). The record's dir is gone, so
#     the old code deleted the ref under the live lane; the guard must keep it.
git worktree add -q "$FIX/wt-moved" -b fix/moved-1
echo wip > "$FIX/wt-moved/keep.txt"
$RW add --branch fix/moved-1 --worktree "$FIX/gone-forever" --dispatch d-moved --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN --apply 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/moved-1 && ok "a branch checked out in a live worktree is never CAS-deleted" || bad "the ref of a LIVE worktree's branch was deleted"
assert_contains "$OUT" "could not be compare-deleted" "the checked-out refusal is named"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept when the ref is refused"
$RW done --dispatch d-moved >/dev/null
git worktree remove --force "$FIX/wt-moved" >/dev/null 2>&1 || true
git branch -D fix/moved-1 >/dev/null 2>&1 || true

# ── 2m. the CAS is inside reap_record, not only in the fixture (Finding 3 row): a
#     wrapper `git` moves the ref at the moment the swap is attempted, so the classified
#     tip is stale. A script that dropped the old-oid would delete the ref anyway.
mkdir -p "$FIX/shim"
REAL_GIT="$(command -v git)"
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" update-ref -d "*)
      "$GIT_WRAP_REAL" -C "$GIT_WRAP_REPO" branch -f "${3#refs/heads/}" main >/dev/null 2>&1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git branch fix/cas-move
git checkout -q fix/cas-move && echo x >> file.txt && git commit -qam x && git checkout -q main
$RW add --branch fix/cas-move --worktree "$FIX/gone-too" --dispatch d-casmove --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" $SCAN --apply 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/cas-move && ok "a tip that MOVED inside the reap window is refused (CAS is in the script)" || bad "reap_record deleted a ref whose tip moved (unconditional update-ref)"
assert_contains "$OUT" "could not be compare-deleted" "the in-window CAS refusal is named"
$RW done --dispatch d-casmove >/dev/null
git branch -D fix/cas-move >/dev/null 2>&1 || true

# ── 2n. an UNREADABLE classified tip refuses rather than degrading to update-ref's
#     unconditional form (Finding 3, the F15 guard). git 2.43 refuses to point a branch at a
#     non-commit, so the unreadable tip is injected where it is read: a wrapper `git` that
#     fails the ^{commit} peel.
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse --verify --quiet refs/heads/fix/noncommit^{commit} "*) exit 1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git branch fix/noncommit
$RW add --branch fix/noncommit --worktree "$FIX/gone-three" --dispatch d-noncommit --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" $SCAN --apply 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/noncommit && ok "an unreadable tip refuses (no unconditional delete)" || bad "an unreadable tip was deleted unconditionally"
assert_contains "$OUT" "<unread-tip>" "the unread-tip refusal is named"
$RW done --dispatch d-noncommit >/dev/null
git branch -D fix/noncommit >/dev/null 2>&1 || true

# ── 2o. G5: a tree that becomes DIRTY between classification and the removal window is
#     KEPT. A wrapper `git` dirties the tree on the SECOND `status` call (the first is
#     the classification, the second is reap_record's own read).
rm -f "$FIX/status-count"
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "status" ]; then
  n=$(cat "$GIT_WRAP_COUNT" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$GIT_WRAP_COUNT"
  [ "$n" -ge 2 ] && echo injected > "$GIT_WRAP_TREE/injected.txt"
fi
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git worktree add -q "$FIX/wt-window" -b fix/window-1
$RW add --branch fix/window-1 --worktree "$FIX/wt-window" --dispatch d-window --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" GIT_WRAP_COUNT="$FIX/status-count" GIT_WRAP_TREE="$FIX/wt-window" $SCAN --apply 2>&1 || true)"
[ -d "$FIX/wt-window" ] && ok "a tree dirtied inside the removal window is not removed" || bad "a tree dirtied inside the window was force-removed"
git show-ref --verify --quiet refs/heads/fix/window-1 && ok "...and its branch is kept" || bad "...but its branch was deleted"
assert_contains "$OUT" "at the removal window" "the in-window re-measure is named"
$RW done --dispatch d-window >/dev/null
git worktree remove --force "$FIX/wt-window" >/dev/null 2>&1 || true
git branch -D fix/window-1 >/dev/null 2>&1 || true

# ── 2p. Finding 2: a path that cannot be STAT'ed is not `absent`. Parent chmod 000 →
#     `[ -d ]`/`[ -e ]` are false while the tree is still there; `absent` would delete the
#     ref of a tree that exists. It must read `unmeasurable` and be preserved.
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 2p (running as root — chmod cannot make a path unstatable)"
else
    mkdir -p "$FIX/locked"
    git branch fix/locked-1
    $RW add --branch fix/locked-1 --worktree "$FIX/locked/child" --dispatch d-lock --ts 2026-08-01T00:00:00Z >/dev/null
    chmod 000 "$FIX/locked"
    OUT="$($SCAN --apply 2>&1 || true)"
    chmod 755 "$FIX/locked"
    assert_contains "$OUT" "state UNMEASURABLE" "an unreachable path is unmeasurable, never absent"
    git show-ref --verify --quiet refs/heads/fix/locked-1 && ok "an unstatable tree keeps its branch" || bad "an unstatable tree's branch was deleted"
    assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "an unstatable tree keeps its record"
    $RW done --dispatch d-lock >/dev/null
    git branch -D fix/locked-1 >/dev/null 2>&1 || true
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== scan-orphans.test.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
