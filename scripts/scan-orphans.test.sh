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

# 1b2. round-13 F3: the prune rewrite is FAIL-SAFE. An unreadable record file means the filter
#      cannot run; the truncating form would replace the file with a PARTIAL temp file and lose the
#      whole teardown trail. A failed filter must leave the file exactly as it was.
$RW add --branch fix/fs-1 --worktree /tmp/wt-fs --dispatch d-fs --ts 2026-08-01T00:00:00Z >/dev/null
$RW add --branch fix/fs-2 --worktree /tmp/wt-fs2 --dispatch d-fs --ts 2026-08-01T00:00:00Z >/dev/null
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "2" "precondition: two records under one dispatch"
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 1b2 (running as root — chmod 000 does not deny root's read)"
else
    chmod 000 "$WORKTREES_RECORD"
    set +e
    $RW done --dispatch d-fs --branch fix/fs-1 --worktree /tmp/wt-fs >/dev/null 2>&1
    RC=$?
    set -e
    chmod 644 "$WORKTREES_RECORD"
    assert_eq "$RC" "0" "done never fails the caller on an unreadable record file"
    assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "2" "a failed filter leaves the record file INTACT (no partial rewrite)"
fi
$RW done --dispatch d-fs >/dev/null
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "0" "1b2 cruft cleared"

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

# 2k. the ref delete is a COMPARE-AND-DELETE, never `git branch -D` (#1393 G3).
#     (The behavioural row is 2m: it drives the SCRIPT's own swap. A primitive-only
#     check here would be invariant under every mutation of the script — #3442 rule 3 —
#     so it is deliberately not asserted.)
assert_not_contains "$(grep -vE '^[[:space:]]*#' scripts/scan-orphans.sh)" "git branch -D" "script never calls git branch -D"

# ── #3799 review, Finding 1: `update-ref -d` does NOT inherit `git branch -D`'s
#    CHECKED-OUT refusal, so the swap must re-enumerate the worktrees itself.
# ── 2l. the branch is checked out in a LIVE worktree at a DIFFERENT path than the
#     record names (a lane that recreated its worktree). The record's dir is gone, so
#     the old code deleted the ref under the live lane; the guard must keep it.
git worktree add -q "$FIX/wt-moved" -b fix/moved-1
echo wip > "$FIX/wt-moved/keep.txt"
$RW add --branch fix/moved-1 --worktree "$FIX/gone-forever" --dispatch d-moved --ts 2026-08-01T00:00:00Z >/dev/null
# --force-dirty so the run reaches the CAS itself: the record's dir is gone but a registration
# still claims the branch, so the classifier now routes this record to the DIRTY path (round-7 F2)
# and a plain --apply refuses it before `delete_branch_cas` is ever consulted.
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/moved-1 && ok "a branch checked out in a live worktree is never CAS-deleted" || bad "the ref of a LIVE worktree's branch was deleted"
assert_contains "$OUT" "CHECKED OUT in a live worktree" "the checked-out refusal is named AS the checked-out refusal"
assert_contains "$OUT" "$(cd "$FIX/wt-moved" && pwd -P)" "the refusal names the live worktree holding the branch"
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
assert_contains "$OUT" "compare-and-delete at" "the in-window CAS refusal is named as the CAS refusal"
# round-9 F1: pin the KEPT counter on the ORPHAN arm (the other counter that had no reddening row).
assert_contains "$OUT" "KEPT by --apply: 1 record(s)" "the orphan-arm refusal is counted as a keep"
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


# ── 2q. Finding 1 of round 2: an ancestor that is LISTABLE but not SEARCHABLE (`444`, i.e. `r`
#     without `x`) — `ls -A` succeeds while its children are unstatable, so "listable" is NOT
#     evidence of non-existence. The tree is on disk and its ref must survive.
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 2q (running as root — chmod cannot deny search)"
else
    mkdir -p "$FIX/readonly-parent/child"
    echo precious > "$FIX/readonly-parent/child/data.txt"
    git branch fix/ro-1
    $RW add --branch fix/ro-1 --worktree "$FIX/readonly-parent/child" --dispatch d-ro --ts 2026-08-01T00:00:00Z >/dev/null
    chmod 444 "$FIX/readonly-parent"
    OUT="$($SCAN --apply 2>&1 || true)"
    chmod 755 "$FIX/readonly-parent"
    assert_contains "$OUT" "state UNMEASURABLE" "a listable-but-unsearchable ancestor is unmeasurable, never absent"
    git show-ref --verify --quiet refs/heads/fix/ro-1 && ok "an r-without-x ancestor keeps the branch of the tree inside it" || bad "the ref was deleted under a tree that was still on disk"
    assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "an r-without-x ancestor keeps the record"
    $RW done --dispatch d-ro >/dev/null
    git branch -D fix/ro-1 >/dev/null 2>&1 || true
    rm -rf "$FIX/readonly-parent"
fi

# ── 2r. a GHOST is pruned only when the tree is PROVABLY absent (round-2 Finding 1, second
#     site): an existing dir under an r-without-x ancestor must not lose its record.
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 2r (running as root — chmod cannot deny search)"
else
    mkdir -p "$FIX/ghost-parent/child"
    echo precious > "$FIX/ghost-parent/child/data.txt"
    $RW add --branch fix/ghost-unreachable --worktree "$FIX/ghost-parent/child" --dispatch d-gh --ts 2026-08-01T00:00:00Z >/dev/null
    chmod 444 "$FIX/ghost-parent"
    OUT="$($SCAN --apply 2>&1 || true)"
    chmod 755 "$FIX/ghost-parent"
    assert_not_contains "$OUT" "never existed" "an unreachable tree is not called a ghost"
    assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record of an unreachable tree is not pruned"
    $RW done --dispatch d-gh >/dev/null
    rm -rf "$FIX/ghost-parent"
fi


# ── 2s. an EXISTING dir git does not vouch for must be refused by --apply AND must not be
#     advertised as "safe to remove" by the default run (round-3 F2 + F3). A clean directory
#     inside the checkout measures `clean`, so only the is_wt arm stands between it and a
#     forced removal — the poisoned-record shape of review #216, in its measurable form.
#     (A subdirectory of THIS checkout would be `dirty` — its files are untracked here — and
#     would be caught by the dirt arm instead. To reach the is_wt arm the state must measure
#     `clean`, so the recorded dir is a CLEAN checkout of a DIFFERENT repo.)
git init -q -b main "$FIX/other-repo"
git -C "$FIX/other-repo" config user.email test@test.test
git -C "$FIX/other-repo" config user.name "Test Runner"
echo theirs > "$FIX/other-repo/theirs.txt"
git -C "$FIX/other-repo" add -A && git -C "$FIX/other-repo" commit -qm theirs
git branch fix/subdir-1
$RW add --branch fix/subdir-1 --worktree "$FIX/other-repo" --dispatch d-subdir --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN)"
assert_contains "$OUT" "does not vouch" "a clean unregistered dir is not advertised as safe to remove"
assert_contains "$OUT" "ORPHANED BUT DIRTY" "a clean unregistered dir is classified DIRTY, not ORPHANED"
$SCAN --apply >/dev/null 2>&1 || true
[ -f "$FIX/other-repo/theirs.txt" ] && ok "a clean unregistered dir is never removed" || bad "--apply REMOVED a clean unregistered dir"
git show-ref --verify --quiet refs/heads/fix/subdir-1 && ok "its branch is kept" || bad "its branch was deleted"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "its record is kept"
# --force-dirty is what REACHES the is_wt arm (without it the dirty arm never calls reap_record),
# and it must refuse there too — this is the row that pins that guard (round-3 F2).
OUT2="$($SCAN --apply --force-dirty 2>&1 || true)"
assert_contains "$OUT2" "exists but git does not vouch" "--force-dirty reports the is_wt refusal"
[ -f "$FIX/other-repo/theirs.txt" ] && ok "--force-dirty does not authorize an unregistered dir" || bad "--force-dirty removed an unregistered dir"
$RW done --dispatch d-subdir >/dev/null
git branch -D fix/subdir-1 >/dev/null 2>&1 || true
rm -rf "$FIX/other-repo"

# ── 2t. an UNREADABLE worktree list REFUSES the ref delete (round-3 F2, second guard):
#     "not checked out anywhere" cannot be established, so nothing is deleted.
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" worktree list --porcelain "*) exit 1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git branch fix/tlist-1
# A LIVE worktree elsewhere holds the branch: that is what makes the CAS guard's removal a real
# fail-open (an unborn branch for a live lane), not a cosmetic difference.
git worktree add -q "$FIX/wt-live" fix/tlist-1
$RW add --branch fix/tlist-1 --worktree "$FIX/gone-four" --dispatch d-tlist --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" $SCAN --apply 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/tlist-1 && ok "an unreadable worktree list refuses the ref delete" || bad "the ref was deleted without establishing it was not checked out"
assert_contains "$OUT" "worktree list could not be read" "the unreadable-list refusal is named"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept when the list is unreadable"
# ⛔ AND THE GUARD ITSELF NEEDS ITS OWN ROW (round-10 finding). Since round-7 F2 an absent dir + an
# unreadable list classifies DIRTY, so a PLAIN --apply never reaches `delete_branch_cas` — the three
# assertions above are then satisfied by the CLASSIFIER's sentence, and deleting the CAS guard left
# the suite fully green while `--apply --force-dirty` deleted a live lane's ref. The --force-dirty
# leg reaches the CAS and asserts ITS OWN sentence.
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" $SCAN --apply --force-dirty 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/tlist-1 && ok "the CAS itself refuses when the worktree list is unreadable" || bad "the CAS deleted a ref it could not prove was not checked out (live lane left unborn)"
assert_contains "$OUT" "not checked out anywhere" "the CAS names ITS OWN reason, not the classifier's"
# ⛔ `git status` SUCCEEDS in a worktree whose branch ref was deleted (measured: rc=0, "No commits
# yet on <b>"), so the old body could not redden under the very mutation this block exists for
# (round-11 F3). `rev-parse --verify HEAD` is the resolvability test: rc=1 exactly when unborn.
( cd "$FIX/wt-live" && git rev-parse --verify --quiet HEAD >/dev/null ) && ok "the live lane holding that branch is not left unborn" || bad "the live lane was left on an unborn branch"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record survives the CAS refusal"
$RW done --dispatch d-tlist >/dev/null
git worktree remove --force "$FIX/wt-live" >/dev/null 2>&1 || true
git branch -D fix/tlist-1 >/dev/null 2>&1 || true


# ── 2u. round-3 F1: after a FAILED removal the post-failure test must not be a bare stat.
#     The wrapper `git` makes `worktree remove` fail AND makes the directory unstatable
#     (chmod 444 on its parent) in the same instant — exactly the TOCTOU the fix is about.
#     A bare `path_there` then reads "gone" and deletes the only ref to the tree.
if [ "$(id -u)" = 0 ]; then
    echo "  ⏭️  skipped 2u (running as root — chmod cannot make a path unstatable)"
else
    mkdir -p "$FIX/vparent"
    git worktree add -q "$FIX/vparent/wt" -b fix/vanish-1
    $RW add --branch fix/vanish-1 --worktree "$FIX/vparent/wt" --dispatch d-vanish --ts 2026-08-01T00:00:00Z >/dev/null
    cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) chmod 444 "$GIT_WRAP_PARENT"; exit 1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
    chmod +x "$FIX/shim/git"
    OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" GIT_WRAP_REPO="$REPO" GIT_WRAP_PARENT="$FIX/vparent" $SCAN --apply 2>&1 || true)"
    chmod 755 "$FIX/vparent"
    assert_contains "$OUT" "not provably gone" "a removal that fails onto an unstatable dir is KEPT, not read as gone"
    git show-ref --verify --quiet refs/heads/fix/vanish-1 && ok "the ref survives a failed removal onto an unstatable dir" || bad "the ref was deleted for a tree that could not be proved gone"
    assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept too"
    $RW done --dispatch d-vanish >/dev/null
    git worktree remove --force "$FIX/vparent/wt" >/dev/null 2>&1 || true
    git branch -D fix/vanish-1 >/dev/null 2>&1 || true
    rm -rf "$FIX/vparent"
fi


# ── 2v. round-6 F1 / round-7 F2: `prunable` is AMBIGUOUS, and the destructive reading must lose.
#     A worktree whose DIRECTORY was `rm -rf`'d and one MOVED with a raw `mv` leave the SAME
#     `prunable` registration at the OLD path; git cannot tell them apart. Reclaiming on that guess
#     severs a live lane (2x pins that), so the ref, the record and the tree state are all KEPT.
#     The DRY run must say so too — it is what an operator and `auto-sync.ts` actually read — and
#     the refusal must NOT name a bare `git worktree prune` (forbidden here, #1141: no path filter,
#     it deregisters unrelated worktrees, and on the moved case it destroys the recovery).
git worktree add -q "$FIX/wt-prunable" -b fix/prunable-1
$RW add --branch fix/prunable-1 --worktree "$FIX/wt-prunable" --dispatch d-prunable --ts 2026-08-01T00:00:00Z >/dev/null
rm -rf "$FIX/wt-prunable"
git worktree list --porcelain | grep -q 'prunable' && ok "fixture: deleting the dir leaves a PRUNABLE registration" || bad "fixture lost the prunable registration (row cannot reach the state it claims to test)"
OUT="$($SCAN 2>&1 || true)"                                  # DRY: the mode operators read
assert_not_contains "$OUT" "ORPHANED (safe to remove)" "the DRY run does not advertise an ambiguous record as safe to remove"
assert_contains "$OUT" "a worktree registration still claims this branch" "the DRY run names the reason it is not safe"
OUT="$($SCAN --apply 2>&1 || true)"                          # apply, no --force-dirty
git show-ref --verify --quiet refs/heads/fix/prunable-1 && ok "an ambiguous (prunable) registration keeps its ref" || bad "the ref was deleted on the prunable guess"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the ambiguous record is kept"
# round-9 F2: the PLAIN --apply must name the remedies too — gating them behind --force-dirty (whose
# documented meaning is "destroy uncommitted work") withheld exactly the two that stop an operator
# clearing a MOVED lane's registration.
assert_contains "$OUT" "worktree repair" "the PLAIN --apply names the moved case's remedy"
assert_contains "$OUT" "worktree remove --force" "the PLAIN --apply names the path-scoped cleanup"
# round-9 F1: pin the KEPT counter on the DIRTY/--force-dirty arm, which had no reddening row.
assert_contains "$OUT" "KEPT by --apply: 1 record(s)" "the plain --apply counts the keep"
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"            # --force-dirty reaches the CAS itself
git show-ref --verify --quiet refs/heads/fix/prunable-1 && ok "--force-dirty does not override the ambiguity either" || bad "the ref was deleted on the prunable guess"
assert_contains "$OUT" "STALE registration" "the refusal names the STALE half of the ambiguity"
assert_contains "$OUT" "MOVED with" "the refusal names the MOVED half of the ambiguity"
assert_contains "$OUT" "worktree repair" "the refusal names the moved case's remedy"
assert_contains "$OUT" "worktree remove --force" "the refusal names a PATH-SCOPED registration cleanup"
assert_not_contains "$OUT" "worktree prune" "the refusal never names the banned bare prune (#1141)"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the ambiguous record stays kept after --force-dirty"
assert_contains "$OUT" "KEPT by --apply: 1 record(s)" "the --force-dirty run counts the keep too"
git worktree remove --force "$FIX/wt-prunable" >/dev/null 2>&1 || true
git branch -D fix/prunable-1 >/dev/null 2>&1 || true

# ── 2x. round-6 F1, the case that makes the whole ambiguity matter: a worktree MOVED with a raw
#     `mv` is LIVE at its new path while its OLD path reads `prunable`. Treating that as a phantom
#     severs it — `git worktree remove --force <old>` returns 0 and the lane's `status` then fails
#     rc=128 — and its unpushed commit goes unreachable. The lane must survive with its git context
#     intact, even under --force-dirty. This is the fixture whose absence let the round-4 fix through.
git worktree add -q "$FIX/wt-moved-away" -b fix/mv-1
echo wip > "$FIX/wt-moved-away/lane-work.txt"
( cd "$FIX/wt-moved-away" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "unpushed lane commit" )
$RW add --branch fix/mv-1 --worktree "$FIX/wt-moved-away" --dispatch d-mv --ts 2026-08-01T00:00:00Z >/dev/null
mv "$FIX/wt-moved-away" "$FIX/wt-moved-here"
( cd "$FIX/wt-moved-here" && git status --porcelain >/dev/null 2>&1 ) && ok "fixture: the moved lane is LIVE at its new path" || bad "fixture did not produce a live moved lane"
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"
( cd "$FIX/wt-moved-here" && git status --porcelain >/dev/null 2>&1 ) && ok "a moved worktree keeps its git context (the lane is not severed)" || bad "the live lane was SEVERED (status failed after --apply)"
git show-ref --verify --quiet refs/heads/fix/mv-1 && ok "a moved worktree's branch survives" || bad "the ref of a live moved lane was deleted"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "a moved worktree's record is kept"
git worktree remove --force --force "$FIX/wt-moved-away" >/dev/null 2>&1 || true
rm -rf "$FIX/wt-moved-here"
git branch -D fix/mv-1 >/dev/null 2>&1 || true

# ── 2y. round-6 F2: a `locked` worktree is live even when its directory is GONE. The listing shows
#     `locked` and NO `prunable` line, so a prunable-only test missed it; `git branch -D` refuses it
#     and this repo preserves it (`pi-reap-worktrees.sh` emits `preserve worktree-locked`).
git worktree add -q "$FIX/wt-locked" -b fix/lock-1
git worktree lock "$FIX/wt-locked"
$RW add --branch fix/lock-1 --worktree "$FIX/wt-locked" --dispatch d-lock1 --ts 2026-08-01T00:00:00Z >/dev/null
rm -rf "$FIX/wt-locked"
git worktree list --porcelain | grep -q '^locked' && ok "fixture: the locked worktree lists as locked" || bad "fixture lost the locked registration"
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/lock-1 && ok "a LOCKED worktree's branch is kept" || bad "the ref of a locked worktree was deleted (broader than 'git branch -D')"
assert_contains "$OUT" "LOCKED" "the refusal names the lock as the cause"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "a locked worktree's record is kept"
git worktree unlock "$FIX/wt-locked" >/dev/null 2>&1 || true
git worktree remove --force --force "$FIX/wt-locked" >/dev/null 2>&1 || true
git branch -D fix/lock-1 >/dev/null 2>&1 || true

# ── 2z. round-6 F3: EVERY registration claiming the branch is examined, not just the first.
#     `git worktree add --force <path> <branch>` really does register TWO worktrees on one branch,
#     so an `exit` on the first match let a LIVE second entry hide behind a prunable first one.
git worktree add -q "$FIX/wt-dup-a" -b fix/dup-1
git worktree add -q --force "$FIX/wt-dup-b" fix/dup-1
$RW add --branch fix/dup-1 --worktree "$FIX/wt-dup-a" --dispatch d-dup --ts 2026-08-01T00:00:00Z >/dev/null
rm -rf "$FIX/wt-dup-a"
assert_eq "$(git worktree list --porcelain | grep -c 'branch refs/heads/fix/dup-1')" "2" "fixture: two registrations claim the same branch"
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/dup-1 && ok "a LIVE second registration protects the ref of a prunable first one" || bad "the ref was freed on the FIRST match with a live second registration present"
assert_contains "$OUT" "CHECKED OUT in a live worktree" "the refusal names the live registration"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept when a live registration remains"
git worktree remove --force --force "$FIX/wt-dup-a" >/dev/null 2>&1 || true
git worktree remove --force --force "$FIX/wt-dup-b" >/dev/null 2>&1 || true
git branch -D fix/dup-1 >/dev/null 2>&1 || true

# ── 2aa. round-8 F1: `prunable` can fire while the DIRECTORY IS PRESENT (remove only the worktree's
#     `.git` file and the registration breaks, the tree and its files stay). The evidence must be
#     `path_absent`, not the flag: the stale arm would otherwise announce "that directory is gone"
#     about a directory that is right there, and prescribe a `worktree remove --force` that fails
#     rc=128 in exactly that state.
git worktree add -q "$FIX/wt-wip" -b fix/wip-1
echo precious > "$FIX/wt-wip/wip.txt"
$RW add --branch fix/wip-1 --worktree "$FIX/gone-wip" --dispatch d-wip --ts 2026-08-01T00:00:00Z >/dev/null
rm -f "$FIX/wt-wip/.git"
assert_eq "$(git worktree list --porcelain | grep -c 'prunable')" "1" "fixture: a PRESENT dir carries a prunable registration"
assert_eq "$(cat "$FIX/wt-wip/wip.txt")" "precious" "fixture: the tree still holds its work"
OUT="$($SCAN --apply --force-dirty 2>&1 || true)"
git show-ref --verify --quiet refs/heads/fix/wip-1 && ok "a PRESENT tree behind a broken registration keeps its ref" || bad "the ref was deleted under a present tree"
assert_contains "$OUT" "CHECKED OUT in a live worktree" "a present tree is diagnosed as PRESENT"
assert_not_contains "$OUT" "while that directory is gone" "the diagnosis never calls a present directory gone"
assert_eq "$(cat "$FIX/wt-wip/wip.txt")" "precious" "the tree's work is untouched"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept"
# restore the linkage so the fixture can be removed cleanly, then deregister path-scoped
printf 'gitdir: %s\n' "$REPO/.git/worktrees/wt-wip" > "$FIX/wt-wip/.git"
git worktree remove --force --force "$FIX/wt-wip" >/dev/null 2>&1 || true
git branch -D fix/wip-1 >/dev/null 2>&1 || true

# ── 2ab. round-8 F2: a FAILED `git worktree list` read must not be reported as "nothing claims this
#     branch". `--apply` already refuses that state (the CAS re-reads and returns 3); the DRY run —
#     what an operator and `extensions/auto-sync.ts` read — advertised it as safe to remove.
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" worktree list "*) exit 1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git worktree add -q "$FIX/wt-unread" -b fix/unread-1
$RW add --branch fix/unread-1 --worktree "$FIX/wt-unread" --dispatch d-unread --ts 2026-08-01T00:00:00Z >/dev/null
rm -rf "$FIX/wt-unread"
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" $SCAN 2>&1 || true)"   # DRY RUN
assert_not_contains "$OUT" "ORPHANED (safe to remove)" "an UNREADABLE worktree list is not advertised as safe to remove"
assert_contains "$OUT" "worktree list could not be read" "the DRY run names the failed read as the reason"
git worktree remove --force "$FIX/wt-unread" >/dev/null 2>&1 || true
git branch -D fix/unread-1 >/dev/null 2>&1 || true

# ── 2ac. round-11 F1: a FAILED `git worktree list` READ must not be reported as "git does not vouch
#     for it". The tree here is registered and clean — only the listing failed. Naming the wrong cause
#     tells the operator to retire the trail of a tree git DOES vouch for, and hides the real fault.
cat > "$FIX/shim/git" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" worktree list "*) exit 1 ;;
esac
exec "$GIT_WRAP_REAL" "$@"
EOS
chmod +x "$FIX/shim/git"
git worktree add -q "$FIX/wt-reg" -b fix/reg-1
$RW add --branch fix/reg-1 --worktree "$FIX/wt-reg" --dispatch d-reg --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" $SCAN 2>&1 || true)"
assert_not_contains "$OUT" "does not vouch for it" "a failed list read is not reported as a non-registration"
assert_contains "$OUT" "worktree list could not be read" "the DRY run names the READ failure as the cause"
OUT="$(PATH="$FIX/shim:$PATH" GIT_WRAP_REAL="$REAL_GIT" $SCAN --apply --force-dirty 2>&1 || true)"
assert_not_contains "$OUT" "clear the record by hand" "the wrong remedy (retire the trail) is withheld for a read failure"
assert_contains "$OUT" "fix 'git worktree list'" "the refusal names the actual fault and the action"
git show-ref --verify --quiet refs/heads/fix/reg-1 && ok "a registered clean worktree keeps its ref when the list read fails" || bad "the ref was deleted"
( cd "$FIX/wt-reg" && git rev-parse --verify --quiet HEAD >/dev/null ) && ok "the lane stays resolvable" || bad "the lane was left unborn"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "the record is kept"
$RW done --dispatch d-reg >/dev/null
git worktree remove --force "$FIX/wt-reg" >/dev/null 2>&1 || true
git branch -D fix/reg-1 >/dev/null 2>&1 || true

# ── 2ad. round-12 F1: ONE DISPATCH IS NOT ONE RECORD. `record-worktree.sh done --dispatch`
#     pruned EVERY line carrying that dispatch, so clearing one reaped record erased a sibling
#     record the same sweep had just KEPT — the surviving dirty tree lost the teardown trail that
#     makes the next sweep re-report it, while `--apply` still printed "KEPT by --apply: 1".
#     Record A is reapable (dir never existed, branch local-only); record B is a registered DIRTY
#     worktree, so the sweep keeps it. Both share ONE dispatch: A's prune must not take B's record.
git branch fix/sib-a
git worktree add -q "$FIX/wt-sib-b" -b fix/sib-b
 echo uncommitted > "$FIX/wt-sib-b/untracked.txt"
$RW add --branch fix/sib-a --worktree "$FIX/never-a" --dispatch d-shared --ts 2026-08-01T00:00:00Z >/dev/null
$RW add --branch fix/sib-b --worktree "$FIX/wt-sib-b" --dispatch d-shared --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN --apply 2>&1 || true)"
assert_contains "$OUT" "KEPT by --apply: 1 record(s)" "the shared-dispatch sweep reports the record it kept"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "a kept sibling record survives the prune of its dispatch-mate"
grep -qF '"branch":"fix/sib-b"' "$WORKTREES_RECORD" \
  && ok "the SURVIVING record is the kept one (fix/sib-b), not the reaped one" \
  || bad "the surviving record is not fix/sib-b — the prune removed the wrong line"
[ -f "$FIX/wt-sib-b/untracked.txt" ] && ok "the dirty sibling tree is still on disk" || bad "the dirty sibling tree was removed"
git show-ref --verify --quiet refs/heads/fix/sib-b && ok "the dirty sibling keeps its branch" || bad "the dirty sibling's branch was deleted"
$RW done --dispatch d-shared --branch fix/sib-b --worktree "$FIX/wt-sib-b" >/dev/null
git worktree remove --force "$FIX/wt-sib-b" >/dev/null 2>&1 || true
git branch -D fix/sib-b >/dev/null 2>&1 || true
git branch -D fix/sib-a >/dev/null 2>&1 || true

# ── 2ae. round-12 F2: the registration test was a SUBSTRING (`*"worktree $PATH"*`), so a record
#     naming a directory that is a strict PREFIX of a registered worktree read as REGISTERED —
#     and IS_WT is what makes the default run print "ORPHANED (safe to remove)", the exact false
#     PASS the is_wt paragraph forbids. The recorded dir must measure `clean` to reach that arm
#     (an unmeasurable dir is already DIRTY), so it is a CLEAN checkout of a DIFFERENT repo whose
#     path is a strict prefix of the live worktree's path.
git worktree add -q "$FIX/pfx-slug" -b fix/pfx-live
git init -q -b main "$FIX/pfx"
git -C "$FIX/pfx" config user.email test@test.test
git -C "$FIX/pfx" config user.name "Test Runner"
echo pfx > "$FIX/pfx/pfx.txt"
git -C "$FIX/pfx" add -A && git -C "$FIX/pfx" commit -qm pfx
git branch fix/pfx-stale
$RW add --branch fix/pfx-stale --worktree "$FIX/pfx" --dispatch d-prefix --ts 2026-08-01T00:00:00Z >/dev/null
# The precondition: this dir is NOT registered, and only a substring test can say otherwise.
# ⛔ CANONICALIZE the fixture path (#1393 R13-F4): porcelain prints REALPATHS, so grepping for the
# mktemp form reports 0 on macOS (/var/folders/… vs /private/var/…) whether or not the fixture is
# right — a precondition that can never fail is not a precondition.
PFX="$(cd "$FIX/pfx" && pwd -P)"
assert_eq "$(git worktree list --porcelain | grep -cxF "worktree $PFX")" "0" \
  "precondition: the prefix dir is genuinely unregistered (0 exact matches)"
OUT="$($SCAN 2>&1 || true)"
assert_not_contains "$OUT" "ORPHANED (safe to remove)" "a strict-prefix dir is never advertised as safe to remove"
assert_contains "$OUT" "ORPHANED BUT DIRTY" "a strict-prefix dir is classified DIRTY (git does not vouch for it)"
$SCAN --apply >/dev/null 2>&1 || true
[ -f "$FIX/pfx/pfx.txt" ] && ok "a strict-prefix dir is never removed" || bad "--apply REMOVED a dir git does not vouch for"
git show-ref --verify --quiet refs/heads/fix/pfx-stale && ok "its branch is kept" || bad "its branch was deleted"
$RW done --dispatch d-prefix --branch fix/pfx-stale --worktree "$FIX/pfx" >/dev/null
git worktree remove --force "$FIX/pfx-slug" >/dev/null 2>&1 || true
git branch -D fix/pfx-live >/dev/null 2>&1 || true
git branch -D fix/pfx-stale >/dev/null 2>&1 || true

# ── 2af. round-13 F2: the GHOST arm's prune is narrowed too. A ghost record (branch nowhere, dir
#     provably absent) shares a dispatch with a registered DIRTY worktree; pruning the ghost by
#     dispatch alone would erase the KEPT sibling's record. The `reap_record` site is pinned by 2ad;
#     this is the OTHER site, and without it reverting `:456` left the suite fully green.
git worktree add -q "$FIX/wt-ghost-sib" -b fix/ghost-sib
 echo uncommitted > "$FIX/wt-ghost-sib/untracked.txt"
$RW add --branch fix/ghost-shared --worktree "$FIX/never-ghost" --dispatch d-ghost-sib --ts 2026-08-01T00:00:00Z >/dev/null
$RW add --branch fix/ghost-sib --worktree "$FIX/wt-ghost-sib" --dispatch d-ghost-sib --ts 2026-08-01T00:00:00Z >/dev/null
OUT="$($SCAN --apply 2>&1 || true)"
assert_contains "$OUT" "never existed" "the ghost record is still identified as a ghost"
assert_eq "$(wc -l < "$WORKTREES_RECORD" | tr -d ' ')" "1" "a kept sibling survives the GHOST arm's prune"
grep -qF '"branch":"fix/ghost-sib"' "$WORKTREES_RECORD" \
  && ok "the GHOST arm's surviving record is the kept sibling" \
  || bad "the GHOST arm pruned the kept sibling's record"
[ -f "$FIX/wt-ghost-sib/untracked.txt" ] && ok "the dirty sibling tree survives the GHOST arm" || bad "the dirty sibling tree was removed"
git show-ref --verify --quiet refs/heads/fix/ghost-sib && ok "the dirty sibling keeps its branch" || bad "the dirty sibling's branch was deleted"
$RW done --dispatch d-ghost-sib --branch fix/ghost-sib --worktree "$FIX/wt-ghost-sib" >/dev/null
git worktree remove --force "$FIX/wt-ghost-sib" >/dev/null 2>&1 || true
git branch -D fix/ghost-sib >/dev/null 2>&1 || true

# ── 2ag. round-13 F1: the registration pin must be able to match the LAST-listed worktree.
#     `$(printf '%s\n' "$WT_LIST")` RE-STRIPS the newline it adds, so the pin missed any line that
#     is last in the listing — and `branch` IS last for the final block. REG_CLAIMS then read false
#     for the branch a LIVE worktree holds, and an absent dir was printed as `ORPHANED (safe to
#     remove)` while the same sweep printed `KEPT by --apply` (a self-contradicting report).
#     The live worktree is added LAST on purpose: that is what puts it in the final block.
git branch fix/last-1
$RW add --branch fix/last-1 --worktree "$FIX/never-last" --dispatch d-last --ts 2026-08-01T00:00:00Z >/dev/null
# Sorted by PATH, so the fixture is named to land after every other registered worktree.
git worktree add -q "$FIX/wt-zzz-last" fix/last-1
assert_eq "$(git worktree list --porcelain | awk 'BEGIN{RS=""} END{print}' | tail -1)" "branch refs/heads/fix/last-1" \
  "precondition: the branch is held by the LAST-listed worktree"
OUT="$($SCAN 2>&1 || true)"
assert_not_contains "$OUT" "ORPHANED (safe to remove)" "a branch held only by the LAST worktree is never 'safe to remove'"
assert_contains "$OUT" "still claims this branch" "the classifier agrees with the CAS: a registration still claims it"
$RW done --dispatch d-last --branch fix/last-1 --worktree "$FIX/never-last" >/dev/null
git worktree remove --force "$FIX/wt-zzz-last" >/dev/null 2>&1 || true
git branch -D fix/last-1 >/dev/null 2>&1 || true

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== scan-orphans.test.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
