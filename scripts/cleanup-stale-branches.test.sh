#!/usr/bin/env bash
# cleanup-stale-branches.test.sh — self-check for scripts/cleanup-stale-branches.sh
# (issue #1787: the LOCAL scope's three gates, plus the remote-scope regression).
#
# Run: bash scripts/cleanup-stale-branches.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: builds throwaway
# git repos (a bare origin + a work repo) under $(mktemp -d) and NEVER touches a
# real checkout or any remote. The PR-state map is injected through
# --pr-map-file (and CLEANUP_BRANCH_PR_MAP_JSON), so the suite needs no `gh`, no
# network and no real PRs — and NOTHING here is deleted for real (the only
# deletions happen inside the fixture repos).
#
# Why each gate fixture exists:
#   merged           a MERGED PR, based on main, whose headRefOid IS the local
#                    tip — the squash-merge case `--merged` cannot see. It is
#                    also the ONLY class that exercises the force-delete fallback.
#   post-merge       a MERGED PR based on main, but the local branch gained a
#                    commit AFTER the merge, so the tip has MOVED past
#                    headRefOid. Must be KEPT (`merged-tip-moved`): `git branch
#                    -d` refuses (not an ancestor of main) and the only copy of
#                    the post-merge commit is the reflog, so the pre-fix code
#                    force-deleted it via `-D`.
#   stacked          a MERGED PR whose base is `feat/base`, NOT main. Its
#                    content is in that base, not in main. Must be KEPT
#                    (`merged-base-not-main`), never `-D`'d.
#   redundant        a branch with no commits outside origin/main.
#   remotecopy       a branch fully present on its upstream.
#   stale-tracking   pushed, then deleted DIRECTLY IN THE BARE ORIGIN, so the
#                    local refs/remotes/origin/<br> is STALE. Without the
#                    `git fetch --prune` that local scope now runs, rev-parse
#                    succeeds, the ahead-count is 0, it is classed remotecopy and
#                    `-d` deletes the only durable copy. Must be KEPT.
#   negative-refspec the same stale-tracking shape, but with a NEGATIVE refspec
#                    (`^refs/heads/<br>`) in remote.origin.fetch: the fetch
#                    EXITS 0 while `--prune` SKIPS the ref, so the exit status
#                    cannot prove freshness. Must be KEPT (the gate stands down).
#   unpushed         THE CRITICAL NEGATIVE: an upstream exists but the local
#                    branch is AHEAD of it. Those commits are pushed nowhere
#                    else, so the branch must NOT be selected.
#   localonly        local commits, no upstream, no PR.
#   worktree         checked out in a linked worktree, and it WOULD match the
#                    merged gate — proving the worktree guard beats a gate.
#   fresh            matches a gate (MERGED PR) but its tip is newer than the
#                    cutoff — proving staleness is required.
#   open-pr          an OPEN PR, otherwise remotecopy-eligible — proving the
#                    OPEN-PR keep rule beats a matching gate.
#   upstream-gone    pushed, then deleted with `git push --delete` (which also
#                    removes the LOCAL tracking ref) — the rev-parse guard.
#   redundant-stuck  redundant, but its upstream is an UNRELATED history, so
#                    `git branch -d` legitimately refuses. It must be reported
#                    FAILED and must NOT be force-deleted.
#
# Cross-platform: no macOS-only flags (no `date -v`, `shasum`, BSD `sed -i`,
# `stat -f`). Fixture commits are backdated with GIT_*_DATE, so no clock
# injection is needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/cleanup-stale-branches.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required by scripts/cleanup-stale-branches.sh's PR-map parse" >&2
    exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_match() { if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no match: $2)"; fi }
assert_no_match() { if grep -qE -- "$2" <<<"$1"; then bad "$3 (unexpected match: $2)"; else ok "$3"; fi }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-branch-test.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# run_script <cmd...> — captures stdout+stderr in OUT and the exit status in RC
# (the script under test is expected to fail in the fail-closed sections).
OUT=""
RC=0
run_script() {
    set +e
    OUT="$("$@" 2>&1)"
    RC=$?
    set -e
}

old_commit() { # $1 = message; backdates both author and committer dates
    GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
        git commit -q -m "$1"
}

new_repo() { # $1 = repo dir  $2 = bare origin dir
    git init -q --bare "$2"
    git init -q -b main "$1"
    git -C "$1" config user.email test@test.test
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
    git -C "$1" remote add origin "$2"
}

echo "── cleanup-stale-branches.test.sh ────────────────────────────────"
echo ""
echo "== 1. local scope: gate fixtures =="

ORIGIN="$FIX/origin.git"
REPO="$FIX/repo"
new_repo "$REPO" "$ORIGIN"
cd "$REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
LOCAL_SCRIPT="$REPO/scripts/cleanup-stale-branches.sh"

# A SECOND remote, so a branch can track a non-origin upstream. Only `origin`
# is ever pruned by the local scope; this one is never fetched after setup.
OTHER_ORIGIN="$FIX/origin-other.git"
git init -q --bare "$OTHER_ORIGIN"
git remote add other "$OTHER_ORIGIN"

echo base > file.txt
git add file.txt
old_commit "init"          # base is OLD, so branches at main's tip are stale
git push -q origin main

# merged — commits NOT on main, no upstream, MERGED PR, tip IS the merged revision
git checkout -q -b feat/merged-one main
echo one > one.txt; git add one.txt; old_commit "one"
MERGED_ONE_SHA="$(git rev-parse HEAD)"
git checkout -q main

# post-merge — the PR merged revision A, then the branch gained commit B locally.
# A MERGED PR proves A landed; it says nothing about B. The tip has MOVED.
git checkout -q -b post-merge-one main
echo pm > pm.txt; git add pm.txt; old_commit "pm-merged"
POST_MERGE_SHA="$(git rev-parse HEAD)"     # this is what the PR merged
echo pmlate > pmlate.txt; git add pmlate.txt; old_commit "pm-late"   # POST-merge
git checkout -q main

# stacked — a MERGED PR whose base is NOT main
git checkout -q -b stacked-one main
echo st > st.txt; git add st.txt; old_commit "stacked"
STACKED_SHA="$(git rev-parse HEAD)"
git checkout -q main

# redundant — no commits outside origin/main
git branch redundant-one main

# remotecopy — pushed, local == upstream
git checkout -q -b remote-copy-one main
echo two > two.txt; git add two.txt; old_commit "two"
git push -q -u origin remote-copy-one
git checkout -q main

# stale-tracking — pushed, then deleted ONLY in the bare origin, so the local
# remote-tracking ref survives at the old tip and the ahead-count is 0.
git checkout -q -b stale-tracking-one main
echo stg > stg.txt; git add stg.txt; old_commit "stg"
git push -q -u origin stale-tracking-one
git checkout -q main
git -C "$ORIGIN" update-ref -d refs/heads/stale-tracking-one

# non-origin-upstream — pushed to a SECOND remote and deleted THERE. Only
# origin is pruned, so refs/remotes/other/<br> survives STALE: `rev-parse`
# resolves it and the ahead-count is 0. Without the origin-only guard this is
# classed remotecopy and `-d` removes the only durable copy of its commits.
git checkout -q -b other-remote-one main
echo or > or.txt; git add or.txt; old_commit "or"
git push -q -u other other-remote-one
git checkout -q main
git -C "$OTHER_ORIGIN" update-ref -d refs/heads/other-remote-one

# CRITICAL: upstream exists but local is AHEAD → must NOT be selected
git checkout -q -b unpushed-one main
echo three > three.txt; git add three.txt; old_commit "three"
git push -q -u origin unpushed-one
echo more > more.txt; git add more.txt; old_commit "more"
git checkout -q main

# local-only, no upstream, no PR
git checkout -q -b localonly-one main
echo four > four.txt; git add four.txt; old_commit "four"
git checkout -q main

# checked out in a worktree, and it WOULD match the merged gate
git checkout -q -b wt-one main
echo five > five.txt; git add five.txt; old_commit "five"
WT_SHA="$(git rev-parse HEAD)"
git checkout -q main
git worktree add -q "$FIX/wt-one" wt-one

# MERGED PR but newer than the cutoff
git checkout -q -b fresh-one main
echo six > six.txt; git add six.txt
git commit -q -m "six"     # NOW-dated on purpose
FRESH_SHA="$(git rev-parse HEAD)"
git checkout -q main

# OPEN PR, otherwise remotecopy-eligible
git checkout -q -b open-pr-one main
echo seven > seven.txt; git add seven.txt; old_commit "seven"
git push -q -u origin open-pr-one
OPEN_SHA="$(git rev-parse HEAD)"
git checkout -q main

# upstream deleted before classification (`git push --delete` also drops the
# local tracking ref) → the rev-parse guard must keep it
git checkout -q -b upstream-gone-one main
echo eight > eight.txt; git add eight.txt; old_commit "eight"
git push -q -u origin upstream-gone-one
git checkout -q main
git push -q origin --delete upstream-gone-one

# redundant, but `-d` REFUSES: its upstream is an UNRELATED local branch.
# Built with plumbing (mktree + commit-tree + update-ref) so the working tree is
# never touched — a whole-tree `git rm`/checkout dance here is a working-tree
# discard the main-worktree-guard extension refuses to see in a checked-out
# script, and the fixture does not need one.
OTHER_TREE="$(printf '' | git mktree)"
OTHER_COMMIT="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$OTHER_TREE" -m "other-root")"
git update-ref refs/heads/other "$OTHER_COMMIT"
git branch redundant-stuck main
git branch --set-upstream-to=other redundant-stuck >/dev/null

PR_MAP="$FIX/pr-map.json"
cat > "$PR_MAP" <<JSON
[
  {"headRefName":"feat/merged-one","state":"MERGED","headRefOid":"$MERGED_ONE_SHA","baseRefName":"main"},
  {"headRefName":"post-merge-one","state":"MERGED","headRefOid":"$POST_MERGE_SHA","baseRefName":"main"},
  {"headRefName":"stacked-one","state":"MERGED","headRefOid":"$STACKED_SHA","baseRefName":"feat/base"},
  {"headRefName":"wt-one","state":"MERGED","headRefOid":"$WT_SHA","baseRefName":"main"},
  {"headRefName":"fresh-one","state":"MERGED","headRefOid":"$FRESH_SHA","baseRefName":"main"},
  {"headRefName":"open-pr-one","state":"OPEN","headRefOid":"$OPEN_SHA","baseRefName":"main"}
]
JSON

# A map with no PR for any fixture branch — proves a GOOD map is still accepted.
PR_MAP_OTHER="$FIX/pr-map-other.json"
printf '%s\n' '[{"headRefName":"nobody","state":"OPEN","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"main"}]' \
    > "$PR_MAP_OTHER"

branch_exists() { git show-ref --verify --quiet "refs/heads/$1"; }
assert_branch_exists() { if branch_exists "$1"; then ok "$2"; else bad "$2 (branch $1 is GONE)"; fi }
assert_branch_absent() { if branch_exists "$1"; then bad "$2 (branch $1 still present)"; else ok "$2"; fi }

echo ""
echo "== 2. local scope FAILS CLOSED without a PR map (nothing deleted) =="

unset CLEANUP_BRANCH_PR_MAP_JSON || true
run_script bash "$LOCAL_SCRIPT" --scope local --execute
assert_eq "$RC" "1" "no PR map → exit 1"
assert_contains "$OUT" "refusing to classify local branches" "no PR map → loud refusal"
assert_contains "$OUT" "could not read the PR-state map" "no PR map → cause named"
assert_branch_exists feat/merged-one "no PR map → merged branch NOT deleted"
assert_branch_exists redundant-one "no PR map → redundant branch NOT deleted"

echo ""
echo "== 3. the PR map is SHAPE-CHECKED, and every bad shape REFUSES (Defect 5) =="
# An EMPTY payload and a wrong shape must not read as "no PRs": with `{}`, jq
# iterates an empty OBJECT to zero values and exits 0, which silently disables
# the OPEN-PR keep rule. Each case below must exit 1 and classify NOTHING.

: > "$FIX/pr-empty-file.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-empty-file.json"
assert_eq "$RC" "1" "an EMPTY PR-map file is refused (exit 1)"
assert_contains "$OUT" "PR map is EMPTY" "empty file → emptiness named"
assert_not_contains "$OUT" "── SELECTED" "empty file → nothing classified"

# F5: the refusal must cover WHITESPACE-ONLY input, not just a zero-byte file.
# The guard is now a `case` glob (bash 3.2's `${var//[[:space:]]/}` hangs on a
# real ~88 KB gh payload); this pins the SEMANTICS it replaces: a file of only
# spaces/tabs/newlines is refused exactly like an empty one, before any shape
# check runs.
printf '   \n\t \n\n' > "$FIX/pr-whitespace-only.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-whitespace-only.json"
assert_eq "$RC" "1" "a WHITESPACE-ONLY PR-map file is refused (F5)"
assert_contains "$OUT" "PR map is EMPTY" "whitespace-only file → emptiness named (F5)"
assert_not_contains "$OUT" "── SELECTED" "whitespace-only file → nothing classified (F5)"

printf '{}\n' > "$FIX/pr-object.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-object.json"
assert_eq "$RC" "1" "{} is refused (not silently an empty keep-set)"
assert_contains "$OUT" "PR map refused" "{} → refusal names the shape"
assert_contains "$OUT" "not a JSON array" "{} → refusal explains the wrong type"
assert_not_contains "$OUT" "── SELECTED" "{} → nothing classified"

printf '[]\n' > "$FIX/pr-array-empty.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-array-empty.json"
assert_eq "$RC" "1" "[] is refused (an empty array is not an empty PR rule)"
assert_contains "$OUT" "an empty array" "[] → emptiness named"
assert_not_contains "$OUT" "── SELECTED" "[] → nothing classified"

# The same [] injected through the ENV seam is just as unauthoritative.
run_script env CLEANUP_BRANCH_PR_MAP_JSON='[]' bash "$LOCAL_SCRIPT" --scope local
assert_eq "$RC" "1" "an injected [] via CLEANUP_BRANCH_PR_MAP_JSON is refused"
assert_contains "$OUT" "an empty array" "env-injected [] → emptiness named"
assert_not_contains "$OUT" "── SELECTED" "env-injected [] → nothing classified"

printf '[{"headRefName":"x"}]\n' > "$FIX/pr-missing-state.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-missing-state.json"
assert_eq "$RC" "1" "an element missing state is refused"
assert_contains "$OUT" "lack a string headRefName and/or state" "missing state → named"

printf '[{"state":"OPEN"}]\n' > "$FIX/pr-missing-name.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-missing-name.json"
assert_eq "$RC" "1" "an element missing headRefName is refused"

printf '[{"headRefName":"x","state":"MERGED"}]\n' > "$FIX/pr-merged-noid.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-merged-noid.json"
assert_eq "$RC" "1" "a MERGED element without headRefOid/baseRefName is refused"
assert_contains "$OUT" "MERGED element(s) lack a string headRefOid" "missing merged fields → named"

# Defect D2: `state` is case-sensitive, so a case variant matches neither fold
# arm. A lowercase "open" would bypass the OPEN-PR keep rule entirely (the
# branch below is otherwise remotecopy-eligible, so --execute would DELETE it);
# a lowercase "merged" would be silently ignored. Both must be refused instead.
printf '[{"headRefName":"open-pr-one","state":"open","headRefOid":"%s","baseRefName":"main"}]\n' "$OPEN_SHA" > "$FIX/pr-lowercase-open.json"
run_script bash "$LOCAL_SCRIPT" --scope local --execute --pr-map-file "$FIX/pr-lowercase-open.json"
assert_eq "$RC" "1" 'a lowercase state ("open") is refused, not silently bypassing the keep rule'
assert_contains "$OUT" "outside OPEN|CLOSED|MERGED" 'lowercase "open" → refusal names the enum'
assert_not_contains "$OUT" "── SELECTED" 'lowercase "open" → nothing classified'
assert_branch_exists open-pr-one 'lowercase "open" → the OPEN-PR branch is NOT deleted'

printf '[{"headRefName":"x","state":"merged","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"main"}]\n' > "$FIX/pr-lowercase-merged.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-lowercase-merged.json"
assert_eq "$RC" "1" 'a lowercase "merged" is refused (the entry is never silently ignored)'
assert_contains "$OUT" "outside OPEN|CLOSED|MERGED" 'lowercase "merged" → refusal names the enum'

printf 'this is not json\n' > "$FIX/pr-malformed.json"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-malformed.json"
assert_eq "$RC" "1" "malformed JSON is still refused"
assert_contains "$OUT" "PR map refused" "malformed JSON → refusal"

run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$FIX/pr-map-missing-file.json"
assert_eq "$RC" "1" "a missing map FILE is refused"

# F5: a REAL gh payload is parsed, never hung. On macOS's /bin/bash 3.2.57 the
# old guard `[ -z "${src//[[:space:]]/}" ]` is SUPERLINEAR: an ~88 KB
# whitespace-heavy gh payload never returns (>30 s and climbing), so the LOCAL
# scope neither classified nor failed closed. This builds a >=80 KB
# pretty-printed map in the `gh pr list --json ...` shape and requires the run to
# COMPLETE (bounded wall clock — macOS has no `timeout`) and to CLASSIFY with the
# fixture's own PR entries still applied. Mutation proof: restore
# `${src//[[:space:]]/}` and this run exceeds the bound and is killed.
F5BIG_MAP="$FIX/f5-big-map.json"
{
    printf '[\n'
    jq -c '.[]' "$PR_MAP" | while IFS= read -r _f5_obj; do
        printf '  %s,\n' "$_f5_obj"
    done
    _f5_i=0
    while [ "$_f5_i" -lt 900 ]; do
        printf '  {\n    "headRefName": "filler/branch-%04d",\n    "state": "CLOSED",\n    "headRefOid": "%040d",\n    "baseRefName": "main"\n  },\n' "$_f5_i" "$_f5_i"
        _f5_i=$((_f5_i + 1))
    done
    printf '  {"headRefName":"filler/final","state":"CLOSED","headRefOid":"%040d","baseRefName":"main"}\n' 0
    printf ']\n'
} > "$F5BIG_MAP"
F5BIG_BYTES="$(wc -c < "$F5BIG_MAP" | tr -d ' ')"
if [ "$F5BIG_BYTES" -ge 81920 ]; then
    ok "F5 fixture is >=80 KB of whitespace-heavy JSON ($F5BIG_BYTES bytes)"
else
    bad "F5 fixture is too small to reproduce the hang ($F5BIG_BYTES bytes, want >=81920)"
fi
# Background-and-poll: macOS has no `timeout`. The fixed run is near-instant; a
# 60 s bound is generous and still catches the superlinear hang.
F5BIG_BOUND=60
F5BIG_START=$SECONDS
set +e
bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$F5BIG_MAP" >"$FIX/f5-big.out" 2>&1 &
F5BIG_PID=$!
F5BIG_WAITED=0
while kill -0 "$F5BIG_PID" 2>/dev/null; do
    sleep 1
    F5BIG_WAITED=$((F5BIG_WAITED + 1))
    if [ "$F5BIG_WAITED" -ge "$F5BIG_BOUND" ]; then
        kill -9 "$F5BIG_PID" 2>/dev/null || true
        break
    fi
done
wait "$F5BIG_PID" 2>/dev/null
F5BIG_RC=$?
set -e
F5BIG_ELAPSED=$((SECONDS - F5BIG_START))
F5BIG_OUT="$(cat "$FIX/f5-big.out" 2>/dev/null || true)"
assert_eq "$F5BIG_RC" "0" "a >=80 KB whitespace-heavy PR map is PARSED and exits 0 (F5)"
assert_contains "$F5BIG_OUT" "Classified" "the large map reached local classification (F5)"
assert_contains "$F5BIG_OUT" "── Summary ──" "the large map ran the whole local pass to the summary (F5)"
assert_match "$F5BIG_OUT" '^  delete +merged +feat/merged-one$' 'the large map still applies its own MERGED entry (F5)'
assert_match "$F5BIG_OUT" '^  keep +open-pr +open-pr-one$' 'the large map still applies its own OPEN-PR entry (F5)'
if [ "$F5BIG_ELAPSED" -lt "$F5BIG_BOUND" ]; then
    ok "the large map completed in ${F5BIG_ELAPSED}s (< ${F5BIG_BOUND}s bound) (F5)"
else
    bad "the large map did not complete within ${F5BIG_BOUND}s — the guard hangs (F5)"
fi

echo ""
echo "== 4. local scope dry-run: classification =="

run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_eq "$RC" "0" "dry-run exits 0"
assert_contains "$OUT" "Stale Local Branch Cleanup" "local scope header printed"
assert_contains "$OUT" "DRY-RUN" "dry-run is the default mode"
assert_contains "$OUT" "remotecopy gate enabled" "the local scope pruned before classifying"

# selected by each gate
assert_match "$OUT" '^  delete +merged +feat/merged-one$' 'merged gate selects the MERGED-PR branch at the merged tip'
assert_match "$OUT" '^  delete +redundant +redundant-one$' 'redundant gate selects the no-commits-outside-main branch'
assert_match "$OUT" '^  delete +remotecopy +remote-copy-one$' 'remotecopy gate selects the fully-pushed branch'
assert_match "$OUT" '^  delete +redundant +redundant-stuck$' 'redundant gate selects the -d-refusing branch'

# Defect 1: a MERGED PR does NOT authorize -D on a tip that has moved
assert_no_match "$OUT" '^  delete +[a-z-]+ +post-merge-one$' 'a MERGED branch with a POST-merge commit is NOT selected'
assert_match "$OUT" '^  keep +merged-tip-moved +post-merge-one$' 'POST-merge tip kept with reason merged-tip-moved'
assert_no_match "$OUT" '^  delete +[a-z-]+ +stacked-one$' 'a MERGED PR based on a non-main base is NOT selected'
assert_match "$OUT" '^  keep +merged-base-not-main +stacked-one$' 'non-main base kept with reason merged-base-not-main'

# Defect 2: a STALE remote-tracking ref is not a durable copy
assert_no_match "$OUT" '^  delete +[a-z-]+ +stale-tracking-one$' 'a STALE remote-tracking ref is NOT a remotecopy'
assert_match "$OUT" '^  keep +localonly +stale-tracking-one$' 'stale-tracking branch kept as localonly'

# Defect D1: the prune refreshes ONLY origin, so a branch tracking another
# remote is not a copy we can trust. It must be KEPT and named, not deleted.
assert_no_match "$OUT" '^  delete +[a-z-]+ +other-remote-one$' 'a branch tracking a NON-origin remote is NOT a remotecopy'
assert_match "$OUT" '^  keep +non-origin-upstream +other-remote-one$' 'non-origin upstream kept with reason non-origin-upstream'

# the critical negative: an upstream exists, but local is AHEAD
assert_no_match "$OUT" '^  delete +[a-z-]+ +unpushed-one$' 'UNPUSHED commits (ahead of upstream) are NOT selected'
assert_match "$OUT" '^  keep +localonly +unpushed-one$' 'UNPUSHED branch kept as localonly'

# other never-selected classes
assert_no_match "$OUT" '^  delete +[a-z-]+ +localonly-one$' 'local-only branch with no PR NOT selected'
assert_no_match "$OUT" '^  delete +[a-z-]+ +upstream-gone-one$' 'missing upstream ref is NOT a remotecopy'
assert_no_match "$OUT" '^  delete +[a-z-]+ +wt-one$' 'branch checked out in a worktree NOT selected'
assert_no_match "$OUT" '^  delete +[a-z-]+ +fresh-one$' 'branch newer than the cutoff NOT selected'
assert_no_match "$OUT" '^  delete +[a-z-]+ +open-pr-one$' 'branch with an OPEN PR NOT selected'
assert_no_match "$OUT" '^  delete +[a-z-]+ +main$' 'main branch NOT selected'

# kept reasons
assert_match "$OUT" '^  keep +worktree +wt-one$' 'worktree branch kept with reason worktree'
assert_match "$OUT" '^  keep +main +main$' 'main kept with reason main'
assert_match "$OUT" '^  keep +open-pr +open-pr-one$' 'OPEN-PR branch kept with reason open-pr'
assert_match "$OUT" '^  keep +not-stale +fresh-one$' 'fresh branch kept with reason not-stale'
assert_match "$OUT" '^  keep +localonly +localonly-one$' 'local-only branch kept with reason localonly'
assert_match "$OUT" '^  keep +localonly +upstream-gone-one$' 'deleted-upstream branch kept as localonly'
assert_match "$OUT" '^  keep +localonly +other$' 'unrelated-history branch kept as localonly'

# summary counts by class
assert_contains "$OUT" "Selected:  4 (merged: 1, redundant: 2, remotecopy: 1)" "summary counts selections by class"
assert_contains "$OUT" "Deleted:   0 (dry-run)" "summary reports zero deletions in dry-run"
assert_contains "$OUT" "Kept:      12 (worktree: 1, main: 1, open-pr: 1, not-stale: 1, merged-tip-moved: 1, merged-base-not-main: 1, non-origin-upstream: 1, localonly: 5)" "summary counts keep reasons"

# dry-run must delete nothing at all
assert_branch_exists feat/merged-one "dry-run deleted nothing (merged)"
assert_branch_exists redundant-one "dry-run deleted nothing (redundant)"
assert_branch_exists remote-copy-one "dry-run deleted nothing (remotecopy)"
assert_branch_exists redundant-stuck "dry-run deleted nothing (redundant-stuck)"
assert_branch_exists post-merge-one "dry-run deleted nothing (post-merge)"
assert_branch_exists stacked-one "dry-run deleted nothing (stacked)"
assert_branch_exists stale-tracking-one "dry-run deleted nothing (stale-tracking)"

echo ""
echo "== 4b. a TAG sharing a branch name must not defeat the keep rules =="
# `%(refname:short)` DISAMBIGUATES against tags: with tag `wt-one` present, git
# renders branch refs/heads/wt-one as `heads/wt-one`. Every keep-rule and gate
# keys on the PLAIN name, so before the `%(refname:lstrip=2)` fix this branch
# missed the worktree rule (and open-pr-one missed the OPEN-PR rule) and was
# mis-selected by a gate. Mutation proof: revert lstrip=2 to :short and the
# `keep` assertions below go red and `Selected:` gains two phantom entries.
git tag wt-one "$WT_SHA"
git tag open-pr-one "$OPEN_SHA"
run_script bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_eq "$RC" "0" "tag-collision dry-run exits 0"
assert_match "$OUT" '^  keep +worktree +wt-one$' 'a same-named TAG does not defeat the worktree keep rule'
assert_match "$OUT" '^  keep +open-pr +open-pr-one$' 'a same-named TAG does not defeat the OPEN-PR keep rule'
assert_no_match "$OUT" '^  delete +[a-z-]+ +heads/wt-one$' 'a same-named TAG does not make the worktree branch selectable'
assert_no_match "$OUT" '^  delete +[a-z-]+ +heads/open-pr-one$' 'a same-named TAG does not make the OPEN-PR branch selectable'
assert_contains "$OUT" "Selected:  4 (merged: 1, redundant: 2, remotecopy: 1)" "the tag collision leaves the selection set unchanged"
assert_contains "$OUT" "Kept:      12 (worktree: 1, main: 1, open-pr: 1, not-stale: 1, merged-tip-moved: 1, merged-base-not-main: 1, non-origin-upstream: 1, localonly: 5)" "the tag collision leaves the keep reasons unchanged"
assert_branch_exists wt-one "tag collision deleted nothing (worktree branch)"
assert_branch_exists open-pr-one "tag collision deleted nothing (OPEN-PR branch)"
# Remove the tags so they cannot perturb a later section's expectations.
git tag -d wt-one open-pr-one >/dev/null

echo ""
echo "== 4c. a FAILED worktree enumeration aborts the pass (fail-closed) =="
# `git worktree list --porcelain` is the ONLY source of the worktree keep-rule.
# An unguarded failure yields an EMPTY lookup and silently no rule, so a branch
# checked out in a worktree would be classed as if none held it. The guard must
# abort instead of classifying. A git shim makes the enumeration fail while
# every other git command passes through.
REAL_GIT="$(command -v git)"
FAKEBIN="$FIX/gitshim"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<GITSHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "list" ]; then
    echo "fatal: simulated worktree enumeration failure" >&2
    exit 128
fi
exec "$REAL_GIT" "\$@"
GITSHIM
chmod +x "$FAKEBIN/git"
run_script env PATH="$FAKEBIN:$PATH" bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_eq "$RC" "1" "a failed worktree enumeration exits 1 (fail-closed)"
assert_contains "$OUT" "could not enumerate worktrees" "a failed worktree enumeration names the cause"
assert_not_contains "$OUT" "── SELECTED" "a failed worktree enumeration classifies NOTHING"
# ⛔ REGEX, not a fixed string: the pattern is anchored (`^  delete `), and
# `assert_not_contains` is `grep -qF`. A fixed-string search for a literal `^`
# can never match this output, so the assertion was DEAD — it reported ok even
# when the reverted guard selected branches. `assert_no_match` is `grep -qE`.
assert_no_match "$OUT" '^  delete ' "a failed worktree enumeration selects no branch"
rm -rf "$FAKEBIN"

echo ""
echo '== 5. the launcher shape: bash -s (BASH_SOURCE empty) + --repo =='
# This is EXACTLY how templates/launchd/com.tortoise.branch-reaper.plist runs
# the script: the shared launcher streams it to `bash -s`, and under `bash -s`
# BASH_SOURCE is unset, so the script's own checkout inference is unavailable.
# The pass works only because --repo supplies the tree. If that seam regresses
# the scheduled job classifies nothing (or the wrong tree) while the plist looks
# fine — so it is exercised here, not just reasoned about.

set +e
OUT="$(bash -s -- --repo "$REPO" --scope local --pr-map-file "$PR_MAP" < "$SCRIPT" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "0" "bash -s (launcher shape) exits 0"
assert_match "$OUT" '^  delete +merged +feat/merged-one$' 'bash -s with --repo still classifies (BASH_SOURCE empty)'
assert_match "$OUT" '^  keep +worktree +wt-one$' 'bash -s with --repo still honors the worktree guard'

# Proof that --repo is not silently ignored: point it at a directory that is not
# a repo and require the loud refusal rather than a wrong-tree classification.
set +e
OUT="$(bash -s -- --repo "$FIX" --scope local --pr-map-file "$PR_MAP" < "$SCRIPT" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "--repo pointing at a non-repo fails loudly"
assert_contains "$OUT" "is not a git repository" "--repo refusal names the cause"

echo ""
echo "== 6. the env seam (CLEANUP_BRANCH_PR_MAP_JSON) is equivalent =="

run_script env CLEANUP_BRANCH_PR_MAP_JSON="$(cat "$PR_MAP")" \
    bash "$LOCAL_SCRIPT" --scope local
assert_eq "$RC" "0" "env-injected PR map: dry-run exits 0"
assert_match "$OUT" '^  delete +merged +feat/merged-one$' 'env-injected map selects the merged branch too'
assert_match "$OUT" '^  keep +open-pr +open-pr-one$' 'env-injected map honors the OPEN-PR keep rule'

echo ""
echo "== 6b. the opt-in capped report log (Defect 6) =="
# templates/launchd/com.tortoise.branch-reaper.plist sets CLEANUP_BRANCH_LOG, so
# a launchd pass's report is retrievable instead of only reaching the unified
# log. Unset (every other section) = print only, so this changes nothing else.
LOG1="$FIX/report.log"
run_script env CLEANUP_BRANCH_LOG="$LOG1" \
    bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_eq "$RC" "0" "the report log does not change the exit status"
assert_contains "$(cat "$LOG1")" "=== Stale Local Branch Cleanup ===" "the log holds the pass report"
assert_contains "$(cat "$LOG1")" "delete merged" "the log holds the classification"

# an over-cap log is truncated BEFORE the pass, so it cannot grow unbounded
printf 'STALE-MARKER-STALE-MARKER-STALE-MARKER-STALE-MARKER\n' > "$LOG1"
run_script env CLEANUP_BRANCH_LOG="$LOG1" CLEANUP_BRANCH_LOG_MAX_BYTES=32 \
    bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_not_contains "$(cat "$LOG1")" "STALE-MARKER" "an over-cap log is truncated before the pass"
assert_contains "$(cat "$LOG1")" "Stale Local Branch Cleanup" "the newest pass is still logged after truncation"

# a fail-closed refusal keeps its non-zero status THROUGH the tee
run_script env CLEANUP_BRANCH_LOG="$LOG1" bash "$LOCAL_SCRIPT" --scope local
assert_eq "$RC" "1" "a fail-closed refusal keeps its exit status through the log pipe"
assert_contains "$(cat "$LOG1")" "refusing to classify local branches" "the refusal reaches the log too"

# ⛔ A SYMLINKED log must not be truncated THROUGH. `: >"$f"` FOLLOWS the link
# and destroys its TARGET, and CLEANUP_BRANCH_LOG is a fixed, predictable path
# in the shipped plist — the symlink surface scripts/pi-reap-idle.sh guards. The
# cap must replace the link (mktemp + mv) or skip; never write through it.
LOG_LINK="$FIX/report-link.log"
LOG_TARGET="$FIX/report-link-target.log"
printf 'ORIGINAL-TARGET-CONTENT-MUST-SURVIVE\n' > "$LOG_TARGET"
ln -s "$LOG_TARGET" "$LOG_LINK"
run_script env CLEANUP_BRANCH_LOG="$LOG_LINK" CLEANUP_BRANCH_LOG_MAX_BYTES=1 \
    bash "$LOCAL_SCRIPT" --scope local --pr-map-file "$PR_MAP"
assert_eq "$RC" "0" "a symlinked over-cap log does not change the exit status"
assert_contains "$(cat "$LOG_TARGET")" "ORIGINAL-TARGET-CONTENT-MUST-SURVIVE" \
    "an over-cap SYMLINKED log does NOT truncate its target"
assert_contains "$(cat "$LOG_LINK")" "Stale Local Branch Cleanup" \
    "the pass report still reaches the symlinked log path"

echo ""
echo "== 7. the gh seam: rc reporting (Defect 3) and truncation (Defect 4) =="

ORIGIN3="$FIX/origin3.git"
REPO3="$FIX/repo3"
new_repo "$REPO3" "$ORIGIN3"
cd "$REPO3"
mkdir -p scripts
cp "$SCRIPT" scripts/
GH_SCRIPT="$REPO3/scripts/cleanup-stale-branches.sh"
echo base > file.txt
git add file.txt
old_commit "init"
git push -q origin main
git branch old-redundant main          # redundant: selected as soon as a map parses
# The gh path is reached only for a github.com origin; the fetch then FAILS here
# (which is fine — section 8 covers that failure, and redundant needs no remote).
git remote set-url origin https://github.com/example/example.git

FAKEBIN="$FIX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
# fake `gh` for cleanup-stale-branches.test.sh — never touches the network
set -euo pipefail
limit=10000
prev=""
for a in "$@"; do
    if [ "$prev" = "--limit" ]; then limit="$a"; fi
    prev="$a"
done
case "${FAKE_GH_MODE:-ok}" in
    fail)
        echo "FAILED-NETWORK: could not connect to api.github.com" >&2
        exit 3
        ;;
    truncate)
        # exactly --limit rows, which is what gh returns when more exist
        jq -n --argjson n "$limit" \
            '[range($n) | {headRefName:("pr-" + (.|tostring)), state:"CLOSED",
                           headRefOid:"0000000000000000000000000000000000000000",
                           baseRefName:"main"}]'
        ;;
    ok)
        printf '%s' '[{"headRefName":"branch-of-an-open-pr","state":"OPEN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main"}]'
        ;;
    empty)
        # gh's real answer for a repository with ZERO pull requests
        printf '%s' '[]'
        ;;
    repo)
        # Finding 2 (round 1): the map must be pinned to the SWEPT repo. F2
        # (round 2): a 2-segment `--repo` is resolved against an ambient GH_HOST,
        # so the HOST must be pinned too. This fake returns the swept repo's map
        # ONLY for `--repo github.com/example/example`; a bare `example/example`
        # (or any other value) is treated as a redirected lookup and returns [] —
        # which knows nothing of `old-redundant`, so the branch is deleted as
        # redundant instead of kept by its OPEN PR.
        repo=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--repo" ]; then repo="$a"; fi
            prev="$a"
        done
        if [ -n "${FAKE_GH_ARGV_LOG:-}" ]; then printf '%s\n' "$repo" > "$FAKE_GH_ARGV_LOG"; fi
        if [ "$repo" = "github.com/example/example" ]; then
            printf '%s' '[{"headRefName":"old-redundant","state":"OPEN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main"}]'
        else
            printf '%s' '[]'
        fi
        ;;
    *)
        echo "unexpected FAKE_GH_MODE" >&2
        exit 9
        ;;
esac
FAKEGH
chmod +x "$FAKEBIN/gh"

run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=fail bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a gh failure fails closed (exit 1)"
assert_contains "$OUT" "gh pr list failed (rc=3)" "the gh EXIT STATUS is reported (not the status of '!')"
assert_contains "$OUT" "FAILED-NETWORK" "gh's real stderr is surfaced, not discarded"

run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=truncate bash "$GH_SCRIPT" --scope local --pr-limit 3
assert_eq "$RC" "1" "a gh result that REACHES --limit is refused (exit 1)"
assert_contains "$OUT" "PR map TRUNCATED" "truncation is named"
assert_contains "$OUT" "gh returned 3 PR(s)" "truncation names the count and the limit"
assert_not_contains "$OUT" "── SELECTED" "a truncated map classifies nothing"

run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "a complete valid gh map classifies normally"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'the gh path selects the redundant branch'

# Defect D3: gh returning [] IS authoritative — the repository genuinely has no
# PRs, so the OPEN-PR rule is vacuously true and the pass must still RUN. Only
# an [] injected through the seam is unauthoritative (covered in section 3).
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=empty bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "gh returning [] is authoritative: local scope RUNS (exit 0)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'gh [] → keep rule vacuous, classification proceeds'
assert_not_contains "$OUT" "an empty array" 'gh [] is NOT refused as an injected empty map'

echo ""
echo "== 7b. the gh map is PINNED to the swept repo AND host (F2) =="
# Finding 2 (round 1): `gh pr list` honours an exported GH_REPO when no --repo
# is given. F2 (round 2): a 2-segment --repo is resolved against an ambient
# GH_HOST, so an exported host still redirects the whole map to another host.
# The fake `gh` returns the swept repo's map ONLY for the host-pinned 3-segment
# value, and section 7c records the argv it received.
FAKE_GH_ARGV="$FIX/fake-gh-repo-argv"
run_script env PATH="$FAKEBIN:$PATH" GH_REPO="other/other" GH_HOST="gh-host-should-not-be-used.invalid" FAKE_GH_MODE=repo FAKE_GH_ARGV_LOG="$FAKE_GH_ARGV" bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "a foreign GH_REPO/GH_HOST does not fail the pass (F2)"
assert_contains "$(cat "$FAKE_GH_ARGV" 2>/dev/null || true)" "github.com/example/example" "gh is asked for the HOST-PINNED repo (F2)"
assert_match "$OUT" '^  keep +open-pr +old-redundant$' 'the swept repo OPEN PR is still kept when GH_REPO/GH_HOST point elsewhere (F2)'
assert_no_match "$OUT" '^  delete +[a-z-]+ +old-redundant$' 'the OPEN-PR branch is NOT deleted when GH_REPO/GH_HOST point elsewhere (F2)'

echo ""
echo "== 7c. github_slug accepts ONLY an exact github.com host (F3) =="
# A SUBSTRING host test (`*github.com[:/]*`) accepts `https://notgithub.com/...`
# and `git@mygithub.com:...`, strips the embedded `github.com/`, and yields a
# FOREIGN but syntactically valid `owner/repo`. `gh` reads that as
# `github.com/<owner>/<repo>`, so a foreign repository's map silently displaces
# this one's. The script must find NO github.com origin and fail closed.
git -C "$REPO3" remote set-url origin 'https://notgithub.com/example/example.git'
run_script bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a notgithub.com origin fails closed (F3)"
assert_contains "$OUT" "no github.com origin" "a notgithub.com origin is named as such (F3)"
assert_not_contains "$OUT" "── SELECTED" "a notgithub.com origin classifies nothing (F3)"

git -C "$REPO3" remote set-url origin 'git@mygithub.com:example/example.git'
run_script bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a mygithub.com SSH origin fails closed (F3)"
assert_contains "$OUT" "no github.com origin" "a mygithub.com origin is named as such (F3)"
assert_not_contains "$OUT" "── SELECTED" "a mygithub.com origin classifies nothing (F3)"

# Restore the real github.com URL for any later use of REPO3.
git -C "$REPO3" remote set-url origin 'https://github.com/example/example.git'

echo ""
echo "== 7d. github_slug requires EXACTLY owner/repo — a 1-segment path does not pin a host (R3-5) =="
# `https://github.com/onlyowner` used to yield the slug `onlyowner`, so the
# pinned `--repo github.com/$slug` was the 2-segment `github.com/onlyowner`, which
# `gh` resolves as OWNER/REPO against the ambient $GH_HOST — the declared host pin
# did not hold for an input the parser accepted. Requiring two non-empty segments
# makes `github.com/$slug` always 3 segments (host/owner/repo).
git -C "$REPO3" remote set-url origin 'https://github.com/onlyowner'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a 1-segment origin fails closed (R3-5)"
assert_contains "$OUT" "no github.com origin" "a 1-segment origin yields NO slug (R3-5)"
assert_not_contains "$OUT" "── SELECTED" "a 1-segment origin classifies nothing (R3-5)"

git -C "$REPO3" remote set-url origin 'https://github.com/owner/repo/tree/main'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a >2-segment URL path fails closed (R3-5)"
assert_contains "$OUT" "no github.com origin" "a >2-segment URL path yields NO slug (R3-5)"
assert_not_contains "$OUT" "── SELECTED" "a >2-segment URL path classifies nothing (R3-5)"

# A normal owner/repo origin still resolves (the fake gh returns a valid map).
git -C "$REPO3" remote set-url origin 'https://github.com/example/example.git'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "a normal owner/repo origin still resolves the slug (R3-5)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'the normal origin still classifies (R3-5)'

echo ""
echo "== 8. a FAILED fetch disables the remotecopy gate (Defect 2, fail-closed) =="
# A branch whose upstream was deleted server-side, with the refs NOT refreshed
# because the fetch failed. If a failure were silently treated as "the refs are
# fresh", the stale origin/<br> would class the branch remotecopy and `-d` would
# delete the only durable copy of its commit.

ORIGIN4="$FIX/origin4.git"
REPO4="$FIX/repo4"
new_repo "$REPO4" "$ORIGIN4"
cd "$REPO4"
mkdir -p scripts
cp "$SCRIPT" scripts/
FF_SCRIPT="$REPO4/scripts/cleanup-stale-branches.sh"
echo base > file.txt
git add file.txt
old_commit "init"
git push -q origin main
git checkout -q -b copy-before-break main
echo c > c.txt; git add c.txt; old_commit "c"
git push -q -u origin copy-before-break
git checkout -q main
git remote set-url origin "$FIX/does-not-exist.git"

run_script bash "$FF_SCRIPT" --scope local --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "a failed fetch does not abort the pass"
assert_contains "$OUT" "git fetch origin --prune FAILED" "a failed fetch is announced"
assert_contains "$OUT" "the remotecopy gate is DISABLED" "a failed fetch disables the remotecopy gate (fail-closed)"
assert_no_match "$OUT" '^  delete +[a-z-]+ +copy-before-break$' 'no branch is deleted on unfresh refs'
assert_match "$OUT" '^  keep +localonly +copy-before-break$' 'the would-be remotecopy is KEPT when refs are unfresh'

run_script bash "$FF_SCRIPT" --scope local --execute --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "the failed-fetch execute pass exits 0"
assert_branch_exists copy-before-break "the branch SURVIVES a failed-fetch --execute (nothing durable is lost)"

cd "$REPO"

echo ""
echo "== 8b. a NEGATIVE refspec in origin's fetch config disables the remotecopy gate =="
# `git fetch origin --prune` exits 0 while a NEGATIVE refspec (`^refs/heads/foo`)
# makes the prune SKIP that ref, so refs/remotes/origin/foo survives at its old
# tip: `rev-parse --verify` succeeds, the ahead-count is 0, the branch is classed
# `remotecopy`, and `-d` deletes the only durable copy of its commit. The fetch's
# exit status alone cannot see this, so the gate must stand down on the refspec's
# presence — the refspec is the operator's to own, and the gate must not rewrite
# it.

ORIGIN5="$FIX/origin5.git"
REPO5="$FIX/repo5"
new_repo "$REPO5" "$ORIGIN5"
cd "$REPO5"
mkdir -p scripts
cp "$SCRIPT" scripts/
NEG_SCRIPT="$REPO5/scripts/cleanup-stale-branches.sh"
echo base > file.txt
git add file.txt
old_commit "init"
git push -q origin main

# foo — pushed, then deleted SERVER-SIDE, so refs/remotes/origin/foo is STALE.
git checkout -q -b foo main
echo nf > nf.txt; git add nf.txt; old_commit "nf"
git push -q -u origin foo
git checkout -q main
git -C "$ORIGIN5" update-ref -d refs/heads/foo

# The negative refspec makes every subsequent `--prune` SKIP refs/heads/foo
# while the fetch still exits 0. `foo` is otherwise a textbook remotecopy.
git config --add remote.origin.fetch '^refs/heads/foo'
# Prove the premise the fix responds to: after a real prune the stale tracking
# ref is STILL there, which is why the fetch exit status is insufficient.
git fetch origin --prune --quiet
assert_branch_exists foo "negative-refspec fixture: the local branch exists"
if git rev-parse --verify -q origin/foo >/dev/null 2>&1; then
    ok "negative-refspec fixture: the STALE origin/foo survives --prune (fetch exited 0)"
else
    bad "negative-refspec fixture: origin/foo was pruned — the fixture no longer exercises the defect"
fi

run_script bash "$NEG_SCRIPT" --scope local --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "negative refspec: the dry-run pass still runs"
assert_contains "$OUT" "remote.origin.fetch carries a NEGATIVE refspec" "a negative refspec is detected and announced"
assert_contains "$OUT" "the remotecopy gate is DISABLED" "a negative refspec DISABLES the remotecopy gate (fail-closed)"
assert_not_contains "$OUT" "remotecopy gate enabled" "a negative refspec does NOT report the gate enabled"
assert_no_match "$OUT" '^  delete +[a-z-]+ +foo$' 'a would-be remotecopy behind a negative refspec is NOT selected'
assert_no_match "$OUT" '^  delete +remotecopy +foo$' 'it is NOT classed remotecopy'
assert_match "$OUT" '^  keep +localonly +foo$' 'it is KEPT (as localonly: no other gate matches)'

run_script bash "$NEG_SCRIPT" --scope local --execute --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "negative refspec: the --execute pass exits 0"
assert_branch_exists foo "the branch SURVIVES --execute behind a negative refspec (its commits exist nowhere else)"

cd "$REPO"

echo ""
echo "== 9. local scope --execute: deletion mechanics =="

run_script bash "$LOCAL_SCRIPT" --scope local --execute --pr-map-file "$PR_MAP"
# F1: a per-branch failure is REPORTED and must ALSO make the pass non-zero —
# `--help` states the status means "everything selected was reaped", so
# `Failed: 1` with rc=0 was a sweep that reported success while a selected branch
# was left behind. Mutation proof: restore `return 0` at the end of
# run_local_scope and this assertion goes red (`RC` becomes 0).
assert_eq "$RC" "1" "execute exits NON-ZERO when a selected branch was not reaped (F1)"
assert_contains "$OUT" "1 local branch delete(s) FAILED" "the non-zero exit names the failed-delete count (F1)"
assert_match "$OUT" '^  deleted +merged +feat/merged-one' 'merged branch deleted (via the force-delete fallback)'
assert_contains "$OUT" "via update-ref -d: squash-merged PR" 'the force-delete fallback is named in the output'
assert_match "$OUT" '^  deleted +redundant +redundant-one' 'redundant branch deleted'
assert_match "$OUT" '^  deleted +remotecopy +remote-copy-one' 'remotecopy branch deleted'
assert_match "$OUT" '^  failed +redundant +redundant-stuck' 'redundant-stuck reported FAILED (no force-delete for a non-merged class)'
assert_contains "$OUT" "Deleted:   3" "summary reports 3 deletions"
assert_contains "$OUT" "Failed:    1" "summary reports 1 failure"

assert_branch_absent feat/merged-one "merged branch removed by the force-delete fallback"
assert_branch_absent redundant-one "redundant branch removed by -d"
assert_branch_absent remote-copy-one "remotecopy branch removed by -d"
assert_branch_exists redundant-stuck "redundant-stuck SURVIVES (force-delete not allowed for the redundant class)"
assert_branch_exists post-merge-one "POST-merge branch survives --execute (its commit exists nowhere else)"
assert_branch_exists stacked-one "non-main-base MERGED branch survives --execute"
assert_branch_exists stale-tracking-one "STALE-tracking branch survives --execute"
assert_branch_exists other-remote-one "NON-origin-upstream branch survives --execute (its remote was never pruned)"
assert_branch_exists unpushed-one "UNPUSHED branch survives --execute (the critical safety case)"
assert_branch_exists localonly-one "local-only branch survives --execute"
assert_branch_exists wt-one "worktree branch survives --execute"
assert_branch_exists fresh-one "fresh branch survives --execute"
assert_branch_exists open-pr-one "OPEN-PR branch survives --execute"
assert_branch_exists upstream-gone-one "deleted-upstream branch survives --execute"
assert_branch_exists main "main survives --execute"

echo ""
echo "== 9b. --execute with nothing selected must NOT claim DRY-RUN =="
# The header already says `EXECUTE (will delete)`; the nothing-to-delete arm
# printed `DRY-RUN: nothing to delete`, contradicting the mode it just
# announced. A fresh repo with only main selects nothing, so the arm is reached
# with --execute. Mutation proof: restore the unconditional DRY-RUN line and
# the `EXECUTE: nothing to delete` assertion goes red.
ORIGIN6="$FIX/origin6.git"
REPO6="$FIX/repo6"
new_repo "$REPO6" "$ORIGIN6"
cd "$REPO6"
mkdir -p scripts
cp "$SCRIPT" scripts/
echo base > file.txt
git add file.txt
old_commit "init"
git push -q origin main
run_script bash "$REPO6/scripts/cleanup-stale-branches.sh" --scope local --execute --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "--execute with nothing selected exits 0"
assert_contains "$OUT" "Mode:    EXECUTE (will delete)" "--execute announces the EXECUTE mode"
assert_contains "$OUT" "── EXECUTE: nothing to delete ──" "--execute with nothing selected says EXECUTE, not DRY-RUN"
assert_not_contains "$OUT" "DRY-RUN: nothing to delete" "--execute does not print the DRY-RUN nothing-to-delete line"
# The dry-run arm must keep its own label (both directions pinned).
run_script bash "$REPO6/scripts/cleanup-stale-branches.sh" --scope local --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "dry-run with nothing selected exits 0"
assert_contains "$OUT" "── DRY-RUN: nothing to delete ──" "dry-run with nothing selected still says DRY-RUN"

echo ""
echo "== 10. remote scope: default scope + unchanged behaviour =="

ORIGIN2="$FIX/origin2.git"
REPO2="$FIX/repo2"
new_repo "$REPO2" "$ORIGIN2"
cd "$REPO2"
mkdir -p scripts
cp "$SCRIPT" scripts/
REMOTE_SCRIPT="$REPO2/scripts/cleanup-stale-branches.sh"

echo base > file.txt
git add file.txt
old_commit "init"
git push -q origin main
git checkout -q -b remote-old main
echo old > old.txt; git add old.txt; old_commit "old"
git push -q origin remote-old
git checkout -q main
git merge -q --ff-only remote-old
git push -q origin main

run_script bash "$REMOTE_SCRIPT"
assert_eq "$RC" "0" "no --scope defaults to remote and exits 0"
assert_contains "$OUT" "=== Stale Branch Cleanup ===" "default scope runs the REMOTE header"
assert_not_contains "$OUT" "Stale Local Branch Cleanup" "default scope does NOT run local classification"
assert_contains "$OUT" "origin/remote-old" "remote scope still finds the ancestor-merged stale branch"
assert_contains "$OUT" "DRY-RUN: no branches deleted" "remote scope still dry-runs by default"

run_script bash "$REMOTE_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "remote --execute exits 0"
assert_contains "$OUT" "deleted" "remote --execute deletes the stale branch"
if [ -z "$(git ls-remote origin refs/heads/remote-old 2>/dev/null)" ]; then
    ok "remote branch removed on origin"
else
    bad "remote branch still present on origin"
fi

echo ""
echo "== 10b. --scope both dispatches remote then local =="
# Recreate the remote branch the --execute above removed, then give the local
# leg a valid map with no fixture branch in it, so both legs run in one call.
git push -q origin remote-old
run_script bash "$REMOTE_SCRIPT" --scope both --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "both scope exits 0"
assert_contains "$OUT" "=== Stale Branch Cleanup ===" "both runs the remote scope"
assert_contains "$OUT" "Stale Local Branch Cleanup" "both runs the local scope too"
assert_contains "$OUT" "origin/remote-old" "both: the remote leg sees the stale remote branch"
assert_match "$OUT" '^  delete +redundant +remote-old$' 'both: the local leg selects the redundant local branch'

echo ""
echo "== 10c. a remote branch whose name contains '|' is deleted by its FULL name =="
# `|` is a LEGAL git branch-name character. The remote scope used to build each
# record as "<branch>|<date>" and split it with ${entry%%|*}, so a remote branch
# named `release|2020-01-01` yielded `origin/release` and --execute deleted
# `release` — a branch matching neither the staleness nor the merged premise and
# never selected. The delimiter is now TAB, which a git ref name cannot contain.
ORIGIN7="$FIX/origin7.git"
REPO7="$FIX/repo7"
new_repo "$REPO7" "$ORIGIN7"
cd "$REPO7"
mkdir -p scripts
cp "$SCRIPT" scripts/
PIPE_SCRIPT="$REPO7/scripts/cleanup-stale-branches.sh"

echo base > file.txt; git add file.txt; old_commit "init"
git push -q origin main

# the colliding name: OLD and MERGED (its tip is an ancestor of origin/main)
git checkout -q -b 'release|2020-01-01' main
echo pipe > pipe.txt; git add pipe.txt; old_commit "pipe"
git push -q origin 'release|2020-01-01'
git checkout -q main
git merge -q --ff-only 'release|2020-01-01'
git push -q origin main

# the decoy: a FRESH, UNMERGED `release` — matched by no premise, must survive
git checkout -q -b release main
echo rel > rel.txt; git add rel.txt
git commit -q -m "release"          # current date: fresh
git push -q origin release
git checkout -q main

run_script bash "$PIPE_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "remote --execute with a '|' branch exits 0"
assert_contains "$OUT" 'Deleting origin/release|2020-01-01' "the '|' branch is deleted by its FULL name"
if git -C "$ORIGIN7" show-ref --verify --quiet 'refs/heads/release|2020-01-01'; then
    bad "the '|' branch was NOT removed from origin"
else
    ok "the '|' branch was removed from origin"
fi
if git -C "$ORIGIN7" show-ref --verify --quiet refs/heads/release; then
    ok "the fresh 'release' branch SURVIVES (a '|' name must not delete it)"
else
    bad "the fresh 'release' branch was WRONGLY deleted"
fi

echo ""
echo "== 11. usage/help documents the surface =="

run_script bash "$LOCAL_SCRIPT" --help
assert_eq "$RC" "0" "--help exits 0"
assert_contains "$OUT" "--scope" "help documents --scope"
assert_contains "$OUT" "--pr-map-file" "help documents --pr-map-file"
assert_contains "$OUT" "--pr-limit" "help documents --pr-limit"
assert_contains "$OUT" "--repo" "help documents --repo"

run_script bash "$LOCAL_SCRIPT" --scope bogus
assert_eq "$RC" "1" "an invalid --scope exits 1"
assert_contains "$OUT" "--scope must be remote, local or both" "an invalid --scope is named"

run_script bash "$LOCAL_SCRIPT" --pr-limit 0 --scope local
assert_eq "$RC" "1" "an invalid --pr-limit exits 1"
assert_contains "$OUT" "--pr-limit must be a positive integer" "an invalid --pr-limit is named"

echo ""
echo "== 12. an off-base MERGED PR does not pre-empt the redundant gate (Finding 3) =="
# `merged-base-not-main` used to `continue` unconditionally, so a branch whose
# content is provably already in main was kept forever. It must now fall through
# to the redundant/remotecopy gates, while a genuinely off-base branch is still
# kept. `merged-tip-moved` keeps its behaviour.

F3_ORIGIN="$FIX/f3-origin.git"
F3_REPO="$FIX/f3-repo"
new_repo "$F3_REPO" "$F3_ORIGIN"
cd "$F3_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F3_SCRIPT="$F3_REPO/scripts/cleanup-stale-branches.sh"
echo base > f3.txt; git add f3.txt; old_commit "init"; git push -q origin main
F3_MAIN_SHA="$(git rev-parse main)"
# offbase-redundant: tip == origin/main, MERGED into a non-main base → redundant
git branch offbase-redundant main
# offbase-local: a commit not on main, MERGED into a non-main base → kept
git checkout -q -b offbase-local main
echo local > local.txt; git add local.txt; old_commit "local"
F3_OFFBASE_LOCAL_SHA="$(git rev-parse HEAD)"
# Back to main, with a `git` command on the NEXT line: a bare `git checkout main`
# immediately followed by a non-command line is mis-scanned as a path-restore by
# extensions/main-worktree-guard, and the `git` word bounds its argument list.
git checkout -q main
git rev-parse --verify -q refs/heads/offbase-local >/dev/null
F3_MAP="$FIX/f3-map.json"
cat > "$F3_MAP" <<JSON
[
  {"headRefName":"offbase-redundant","state":"MERGED","headRefOid":"$F3_MAIN_SHA","baseRefName":"feat/base"},
  {"headRefName":"offbase-local","state":"MERGED","headRefOid":"$F3_OFFBASE_LOCAL_SHA","baseRefName":"feat/base"}
]
JSON
run_script bash "$F3_SCRIPT" --scope local --pr-map-file "$F3_MAP"
assert_eq "$RC" "0" "off-base fixture: dry-run exits 0"
assert_match "$OUT" '^  delete +redundant +offbase-redundant$' 'an off-base MERGED PR at origin/main tip is selected as redundant (Finding 3)'
assert_match "$OUT" '^  keep +merged-base-not-main +offbase-local$' 'a genuinely off-base MERGED PR is still KEPT (Finding 3)'
assert_no_match "$OUT" '^  delete +[a-z-]+ +offbase-local$' 'the off-base local-commit branch is NOT selected'

echo ""
echo "== 13. a non-numeric CLEANUP_BRANCH_LOG_MAX_BYTES warns and still caps (Finding 4) =="
# `[ "$size" -ge "$max" ]` with a non-numeric $max returns status 2; the `if`
# then reads false and the cap silently NEVER fires — no error, no warning — so
# the log grows without bound exactly as the header promises it cannot.
LOG3="$FIX/report-cap.log"
{ printf 'STALE-MARKER-STALE-MARKER\n'; printf '%*s' 1100000 '' | tr ' ' X; } > "$LOG3"
run_script env CLEANUP_BRANCH_LOG="$LOG3" CLEANUP_BRANCH_LOG_MAX_BYTES=abc \
    bash "$F3_SCRIPT" --scope local --pr-map-file "$F3_MAP"
assert_eq "$RC" "0" "a non-numeric log cap does not abort the pass (Finding 4)"
assert_contains "$OUT" "CLEANUP_BRANCH_LOG_MAX_BYTES must be a positive integer" "a non-numeric log cap is WARNED about (Finding 4)"
assert_not_contains "$(cat "$LOG3")" "STALE-MARKER" "the cap still FIRES after falling back to the default (Finding 4)"
assert_contains "$(cat "$LOG3")" "Stale Local Branch Cleanup" "the newest pass is logged after the fallback truncation (Finding 4)"

echo ""
echo "== 13b. a NUMERIC value that overflows bash's integer range is refused (F4) =="
# `[[ "99999999999999999999" =~ ^[0-9]+$ ]]` is TRUE, so a digit-only check
# passes it; `[ "$v" -lt 1 ]` — and every later `[ "$size" -ge "$max" ]` — then
# returns status 2 (integer overflow), the `if` reads false, and the cap silently
# NEVER fires — exactly the silent no-op Finding 4 exists to close. The digit
# count must be bounded too.
LOG4="$FIX/report-overflow.log"
{ printf 'STALE-MARKER-STALE-MARKER\n'; printf '%*s' 1100000 '' | tr ' ' X; } > "$LOG4"
run_script env CLEANUP_BRANCH_LOG="$LOG4" CLEANUP_BRANCH_LOG_MAX_BYTES=99999999999999999999 \
    bash "$F3_SCRIPT" --scope local --pr-map-file "$F3_MAP"
assert_eq "$RC" "0" "an overflowing log cap does not abort the pass (F4)"
assert_contains "$OUT" "CLEANUP_BRANCH_LOG_MAX_BYTES must be a positive integer" "an overflowing log cap is WARNED about (F4)"
assert_not_contains "$(cat "$LOG4")" "STALE-MARKER" "the cap FIRES after the fallback (F4)"
assert_contains "$(cat "$LOG4")" "Stale Local Branch Cleanup" "the pass is logged after the fallback truncation (F4)"

for _nflag in --cutoff --pr-limit; do
    run_script bash "$SCRIPT" "$_nflag" 99999999999999999999 --repo "$FIX"
    assert_eq "$RC" "1" "$_nflag with an overflowing value exits 1 (F4)"
    assert_contains "$OUT" "$_nflag must be a positive integer" "$_nflag overflow is refused and named (F4)"
done
unset _nflag

echo ""
echo "== 14. a relative --pr-map-file resolves against the CALLER's cwd (Finding 5) =="
# Args are parsed before `cd "$REPO_ROOT"`, but the file is read after, so a
# relative path used to be looked up INSIDE the swept checkout — the supplied map
# silently "not found".
F5_ORIGIN="$FIX/f5-origin.git"
F5_REPO="$FIX/f5-repo"
new_repo "$F5_REPO" "$F5_ORIGIN"
mkdir -p "$F5_REPO/scripts"
cp "$SCRIPT" "$F5_REPO/scripts/"
F5_SCRIPT="$F5_REPO/scripts/cleanup-stale-branches.sh"
F5_CWD="$FIX/f5-cwd"
mkdir -p "$F5_CWD"
cp "$PR_MAP_OTHER" "$F5_CWD/map5.json"
cd "$F5_REPO"
echo base > f5.txt; git add f5.txt; old_commit "init"; git push -q origin main
git branch f5-redundant main
cd "$F5_CWD"
run_script bash "$F5_SCRIPT" --scope local --repo "$F5_REPO" --pr-map-file ./map5.json
assert_eq "$RC" "0" "a relative --pr-map-file is read from the caller's cwd (Finding 5)"
assert_contains "$OUT" "Loading PR state (file:" "the supplied map was opened (Finding 5)"
assert_match "$OUT" '^  delete +redundant +f5-redundant$' 'classification ran with the relative map (Finding 5)'

echo ""
echo "== 15. a two-token flag with no value names the flag (Finding 7) =="
# `shift 2` on a single remaining argument fails under `set -e` and the shell
# exits with only shell noise; the operator never learns which flag was
# malformed. The value is parsed BEFORE any repo validation, so no fixture is
# needed.
for _flag in --cutoff --scope --pr-map-file --pr-limit --repo; do
    run_script bash "$SCRIPT" "$_flag"
    assert_eq "$RC" "1" "$_flag with no value exits 1 (Finding 7)"
    assert_contains "$OUT" "$_flag requires a value" "$_flag with no value names the flag (Finding 7)"
done
unset _flag

echo ""
echo "== 16. a branch whose name begins with '-' can be reaped (Finding 8) =="
# `git branch -d "$br"` passes the name as the first non-option token, so git
# parses `-x` as an OPTION, the delete always fails, and such a ref could never
# be removed. `--` ends option parsing.
F8_ORIGIN="$FIX/f8-origin.git"
F8_REPO="$FIX/f8-repo"
new_repo "$F8_REPO" "$F8_ORIGIN"
cd "$F8_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F8_SCRIPT="$F8_REPO/scripts/cleanup-stale-branches.sh"
echo base > f8.txt; git add f8.txt; old_commit "init"; git push -q origin main
F8_MAIN_SHA="$(git rev-parse main)"
git update-ref refs/heads/-x "$F8_MAIN_SHA"
git update-ref refs/heads/--version "$F8_MAIN_SHA"
run_script bash "$F8_SCRIPT" --scope local --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "dash-named fixture: dry-run exits 0 (Finding 8)"
assert_match "$OUT" '^  delete +redundant +-x$' 'a branch named -x is SELECTED as redundant (Finding 8)'
assert_match "$OUT" '^  delete +redundant +--version$' 'a branch named --version is SELECTED as redundant (Finding 8)'
assert_contains "$OUT" 'git branch -d -- -x   # class=redundant' 'the dry-run echo mirrors the -- guard, annotation outside the argv (Finding 8)'
run_script bash "$F8_SCRIPT" --scope local --execute --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "dash-named fixture: --execute exits 0 (Finding 8)"
assert_match "$OUT" '^  deleted +redundant +-x' 'a branch named -x is actually DELETED (Finding 8)'
assert_match "$OUT" '^  deleted +redundant +--version' 'a branch named --version is actually DELETED (Finding 8)'
assert_branch_absent "-x" "-x was removed (Finding 8)"
assert_branch_absent "--version" "--version was removed (Finding 8)"

echo ""
echo "== 16b. remote scope reaps a branch whose name begins with '-' (F5) =="
# `git push origin --delete "$local_branch"` passes the name as the first
# non-option token, so `-x`/`--version` are parsed as OPTIONS, the delete always
# fails, and such a ref could never be reaped. `--` ends option parsing, and the
# dry-run echo must mirror it.
F10_ORIGIN="$FIX/f10-origin.git"
F10_REPO="$FIX/f10-repo"
new_repo "$F10_REPO" "$F10_ORIGIN"
cd "$F10_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F10_SCRIPT="$F10_REPO/scripts/cleanup-stale-branches.sh"
echo base > f10.txt; git add f10.txt; old_commit "init"; git push -q origin main
F10_MAIN_SHA="$(git rev-parse main)"
git update-ref refs/heads/-x "$F10_MAIN_SHA"
git update-ref refs/heads/--version "$F10_MAIN_SHA"
git push -q origin refs/heads/-x:refs/heads/-x
git push -q origin refs/heads/--version:refs/heads/--version
run_script bash "$F10_SCRIPT" --scope remote
assert_eq "$RC" "0" "dash-named remote fixture: dry-run exits 0 (F5)"
assert_contains "$OUT" "--force-with-lease=refs/heads/-x:$F10_MAIN_SHA -- refs/heads/-x" 'the dry-run echo mirrors the -- guard and the lease for -x (F5/F2)'
assert_contains "$OUT" "--force-with-lease=refs/heads/--version:$F10_MAIN_SHA -- refs/heads/--version" 'the dry-run echo mirrors the -- guard and the lease for --version (F5/F2)'
run_script bash "$F10_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "dash-named remote fixture: --execute exits 0 (F5)"
if [ -z "$(git ls-remote origin 'refs/heads/-x' 2>/dev/null)" ]; then
    ok "remote branch -x was actually reaped (F5)"
else
    bad "remote branch -x was NOT reaped (F5)"
fi
if [ -z "$(git ls-remote origin 'refs/heads/--version' 2>/dev/null)" ]; then
    ok "remote branch --version was actually reaped (F5)"
else
    bad "remote branch --version was NOT reaped (F5)"
fi

echo ""
echo "== 17. remote scope never deletes a NON-origin remote's ref through origin (Finding 1) =="
# `git branch -r --merged` enumerates EVERY remote's tracking refs, but deletion
# is always `git push origin --delete ${branch#origin/}`. For `upstream/foo` the
# prefix-strip removes nothing, so the pass tells ORIGIN to delete
# `refs/heads/upstream/foo` — a branch never shown to be merged. The premise was
# evaluated on ref A and the destructive action landed on ref B.
F1_ORIGIN="$FIX/f1-origin.git"
F1_UPSTREAM="$FIX/f1-upstream.git"
F1_REPO="$FIX/f1-repo"
new_repo "$F1_REPO" "$F1_ORIGIN"
cd "$F1_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F1_SCRIPT="$F1_REPO/scripts/cleanup-stale-branches.sh"
git init -q --bare "$F1_UPSTREAM"
git remote add upstream "$F1_UPSTREAM"
echo base > f1.txt; git add f1.txt; old_commit "init"; git push -q origin main
# `upstream/foo` — merged into main on the SECOND remote.
git checkout -q -b foo main
echo up > up.txt; git add up.txt; old_commit "up"
git push -q -u upstream foo
git checkout -q main
git merge -q --ff-only upstream/foo
git push -q origin main
# origin carries a branch LITERALLY named `upstream/foo`, with an UNMERGED
# commit — this is the ref the pre-fix push would destroy.
git checkout -q -b upstream/foo main
echo danger > danger.txt; git add danger.txt; old_commit "danger"
git push -q origin refs/heads/upstream/foo:refs/heads/upstream/foo
git checkout -q main
# origin's plain `foo`, also unmerged and distinct.
git checkout -q -b origin-foo main
echo of > of.txt; git add of.txt; old_commit "of"
git push -q origin refs/heads/origin-foo:refs/heads/foo
# NOTE: deliberately left on origin-foo — a trailing bare `git checkout main`
# here is mis-scanned as a path-restore (see the section-12 note); the remote
# scope only warns when HEAD is not main, which no assertion depends on.

run_script bash "$F1_SCRIPT" --scope remote
assert_eq "$RC" "0" "non-origin fixture: remote dry-run exits 0 (Finding 1)"
assert_contains "$OUT" "non-origin-remote" "a non-origin merged ref is REPORTED, never silently skipped (Finding 1)"
assert_match "$OUT" '^  keep +non-origin-remote +upstream/foo$' 'the non-origin ref is a KEEP line, not just any mention (Finding 1)'
# ⛔ F6: the previous assertion here (`assert_contains "$OUT" "upstream/foo"`) was
# NOT falsifying — the PRE-fix dry-run also prints `upstream/foo`, inside
# `git push origin --delete "upstream/foo"`. Assert on the deletion PLAN instead:
# origin must never be told to delete a ref whose `--merged` premise was
# evaluated on another remote. RED whenever the origin confinement is reverted.
# F3: the previous assertion here (`assert_no_match "$OUT" '--delete -- "refs/heads/upstream/foo"'`)
# was permanently VACUOUS once the plan started emitting the lease: the literal
# `--delete -- "` can never occur in any line the plan prints. Guard the SAME
# defect with a lease-aware negative that genuinely tracks the fix — RED when the
# `origin/*` confinement is reverted (the plan would then lease
# refs/heads/upstream/foo through origin).
assert_no_match "$OUT" 'force-with-lease=refs/heads/upstream/foo:' 'the deletion plan never leases the non-origin ref through origin (Finding 1)'

run_script bash "$F1_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "non-origin fixture: remote --execute exits 0 (Finding 1)"
if [ -n "$(git ls-remote origin refs/heads/upstream/foo 2>/dev/null)" ]; then
    ok "origin refs/heads/upstream/foo SURVIVES --execute (Finding 1)"
else
    bad "origin refs/heads/upstream/foo was DELETED through origin (Finding 1)"
fi
# ⛔ F6: the pre-F6 `origin refs/heads/foo SURVIVES` check that stood here was
# INERT in both directions — origin's `foo` is unmerged, so it was never a
# candidate and the assertion could not fail either way. It is dropped; the
# deletion-plan assertion above replaces it and IS inversion-sensitive.

echo ""
echo "== 18. remote scope REFUSES to sweep behind a NEGATIVE refspec (F1 round 2) =="
# `git fetch origin --prune` exits 0 while a NEGATIVE refspec (`^refs/heads/foo`)
# makes `--prune` SKIP that ref, so refs/remotes/origin/foo survives at an OLD
# MERGED tip while origin's REAL refs/heads/foo has advanced to an UNMERGED
# commit. The remote scope's classification IS its delete list, so pre-fix the
# sweep would `git push origin --delete foo` and destroy the only copy of the
# unmerged commit. The sweep must fail closed, and must not rewrite the refspec.
NEG_ORIGIN="$FIX/neg-origin.git"
NEG_REPO="$FIX/neg-repo"
NEG_CLONE="$FIX/neg-clone"
new_repo "$NEG_REPO" "$NEG_ORIGIN"
cd "$NEG_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
NEG_SCRIPT="$NEG_REPO/scripts/cleanup-stale-branches.sh"
echo base > neg.txt; git add neg.txt; old_commit "init"; git push -q origin main
# foo — merged into main at an OLD tip, so origin/foo is a `--merged` candidate.
git checkout -q -b foo main
echo old > old.txt; git add old.txt; old_commit "old"
git push -q -u origin foo
git checkout -q main
git merge -q --ff-only foo
git push -q origin main
NEG_STALE_SHA="$(git rev-parse origin/foo)"
# Advance origin's REAL foo to an UNMERGED commit, from a SEPARATE clone so this
# repo's remote-tracking ref stays at the old merged tip.
git clone -q -b main "$NEG_ORIGIN" "$NEG_CLONE"
git -C "$NEG_CLONE" config user.email test@test.test
git -C "$NEG_CLONE" config user.name "Test Runner"
git -C "$NEG_CLONE" config commit.gpgsign false
git -C "$NEG_CLONE" checkout -q -b adv main
echo danger > "$NEG_CLONE/danger.txt"
git -C "$NEG_CLONE" add danger.txt
GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git -C "$NEG_CLONE" commit -q -m danger
git -C "$NEG_CLONE" push -q origin adv:refs/heads/foo
NEG_REAL_SHA="$(git -C "$NEG_ORIGIN" rev-parse refs/heads/foo)"
# The negative refspec makes every subsequent `--prune` SKIP refs/heads/foo while
# the fetch still exits 0.
git config --add remote.origin.fetch '^refs/heads/foo'
git fetch origin --prune --quiet
if [ "$(git rev-parse origin/foo)" = "$NEG_STALE_SHA" ]; then
    ok "negative-refspec fixture: origin/foo is STALE (old merged tip) after a 0-exit prune"
else
    bad "negative-refspec fixture: origin/foo was refreshed — the fixture no longer exercises the defect"
fi
if [ "$NEG_REAL_SHA" != "$NEG_STALE_SHA" ]; then
    ok "negative-refspec fixture: origin's real foo has ADVANCED to an unmerged commit"
else
    bad "negative-refspec fixture: origin's real foo did not advance"
fi
run_script bash "$NEG_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "a negative refspec REFUSES the remote --execute (F1)"
assert_contains "$OUT" "remote.origin.fetch carries a NEGATIVE refspec" "the negative refspec is named (F1)"
assert_contains "$OUT" "Refusing the remote sweep" "the refusal says the sweep is refused (F1)"
assert_not_contains "$OUT" "Deleting origin/" "no branch was even attempted (F1)"
if [ "$(git -C "$NEG_ORIGIN" rev-parse -q --verify refs/heads/foo || echo GONE)" = "$NEG_REAL_SHA" ]; then
    ok "origin's real UNMERGED foo SURVIVES --execute behind a negative refspec (F1)"
else
    bad "origin's real foo was deleted or moved — data loss (F1)"
fi
# The refspec is the operator's to own: the refusal must not have rewritten it.
if grep -q '^\^' <<<"$(git config --get-all remote.origin.fetch 2>/dev/null || true)"; then
    ok "the negative refspec is left in place (the pass does not rewrite config) (F1)"
else
    bad "the pass rewrote remote.origin.fetch (F1)"
fi
run_script bash "$NEG_SCRIPT" --scope remote
assert_eq "$RC" "1" "a negative refspec refuses the remote dry-run too (F1)"
# ⛔ R3-6: the assertion that stood here (`assert_not_contains "$OUT" "Deleting origin/"`)
# was VACUOUS — `Deleting origin/` is emitted only inside the execute block, which
# the dry-run returns before ever reaching, so it could not fail in either
# direction. Assert on the dry-run's DELETE PLAN instead, which the pre-fix
# dry-run DOES print and which is therefore inversion-sensitive.
# F3: the `--delete -- "refs/heads/foo"` form can no longer occur (the plan is
# always leased), so that negative was unfalsifiable. Lease-aware replacement:
# RED if the negative-refspec refusal is removed and the plan leases refs/heads/foo.
assert_no_match "$OUT" 'force-with-lease=refs/heads/foo:' 'the dry-run plans no leased deletion behind the refspec (F1)'

echo ""
echo "== 19. remote scope VERIFIES the target before deleting — a NARROWED POSITIVE refspec (R3-1) =="
# The config guard greps remote.origin.fetch for a NEGATIVE refspec (an entry
# beginning with `^`). A NARROWED POSITIVE refspec —
# `+refs/heads/main:refs/remotes/origin/main`, what `git remote set-branches` and
# `clone --single-branch` leave behind — omits `refs/heads/*`, so the fetch exits
# 0, `--prune` never refreshes and never prunes the ref, and the grep finds
# nothing. The stale refs/remotes/origin/doomed holds an OLD merged tip while
# origin's real refs/heads/doomed has advanced to an UNMERGED commit: the sweep
# classifies the stale tip, and pre-fix `git push origin --delete` destroyed the
# real branch. The DELETE-TIME comparison against `git ls-remote` must refuse it.
R31_ORIGIN="$FIX/r31-origin.git"
R31_REPO="$FIX/r31-repo"
R31_CLONE="$FIX/r31-clone"
new_repo "$R31_REPO" "$R31_ORIGIN"
cd "$R31_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R31_SCRIPT="$R31_REPO/scripts/cleanup-stale-branches.sh"
echo base > r31.txt; git add r31.txt; old_commit "init"; git push -q origin main
# doomed — merged into main at an OLD tip, so origin/doomed is a `--merged` candidate.
git checkout -q -b doomed main
echo old > old.txt; git add old.txt; old_commit "old"
git push -q -u origin doomed
git checkout -q main
git merge -q --ff-only doomed
git push -q origin main
R31_STALE_OID="$(git rev-parse origin/doomed)"
# Advance origin's REAL doomed to an UNMERGED commit, from a SEPARATE clone, so
# this repo's remote-tracking ref stays at the old merged tip.
git clone -q -b main "$R31_ORIGIN" "$R31_CLONE"
git -C "$R31_CLONE" config user.email test@test.test
git -C "$R31_CLONE" config user.name "Test Runner"
git -C "$R31_CLONE" config commit.gpgsign false
git -C "$R31_CLONE" checkout -q -b adv main
echo danger > "$R31_CLONE/danger.txt"
git -C "$R31_CLONE" add danger.txt
GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git -C "$R31_CLONE" commit -q -m danger
git -C "$R31_CLONE" push -q origin adv:refs/heads/doomed
R31_REAL_OID="$(git -C "$R31_ORIGIN" rev-parse refs/heads/doomed)"
# The NARROWED refspec: only main is refreshed, so `--prune` never sees doomed.
git config --replace-all remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git fetch origin --prune --quiet
if [ "$(git rev-parse origin/doomed)" = "$R31_STALE_OID" ]; then
    ok "narrowed-refspec fixture: origin/doomed is STALE (old merged tip) after a 0-exit prune (R3-1)"
else
    bad "narrowed-refspec fixture: origin/doomed was refreshed — the fixture no longer exercises the defect (R3-1)"
fi
if [ "$R31_REAL_OID" != "$R31_STALE_OID" ]; then
    ok "narrowed-refspec fixture: origin's real doomed has ADVANCED to an unmerged commit (R3-1)"
else
    bad "narrowed-refspec fixture: origin's real doomed did not advance (R3-1)"
fi
# The early config guard must NOT fire — this is precisely the class it misses.
if grep -q '^\^' <<<"$(git config --get-all remote.origin.fetch 2>/dev/null || true)"; then
    bad "narrowed-refspec fixture: the config carries a '^' entry, so the WRONG guard fires (R3-1)"
else
    ok "narrowed-refspec fixture: the config has NO negative refspec (the '^' guard cannot catch it) (R3-1)"
fi
run_script bash "$R31_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "a narrowed refspec REFUSES the remote --execute (R3-1)"
assert_contains "$OUT" "REFUSING to delete origin/doomed" "the refused delete is named (R3-1)"
assert_contains "$OUT" "origin's real refs/heads/doomed is $R31_REAL_OID" "the refusal names origin's REAL oid (R3-1)"
assert_contains "$OUT" "classified $R31_STALE_OID" "the refusal names the CLASSIFIED oid (R3-1)"
assert_contains "$OUT" "Refused: 1" "the summary reports the refusal (R3-1)"
# R5-5: a REFUSED delete is a refusal, not a failure. It used to increment BOTH
# counters, so one branch was reported as `Failed: 1` AND `Refused: 1` — the
# summary double-counted a branch that was never attempted.
assert_contains "$OUT" "Failed:  0" "the refused branch is NOT also counted as a failure (R5-5)"
assert_contains "$OUT" "Total:   1" "the one candidate is counted exactly once (R5-5)"
assert_not_contains "$OUT" "✅ deleted" "no branch was actually deleted (R3-1)"
if [ "$(git -C "$R31_ORIGIN" rev-parse -q --verify refs/heads/doomed || echo GONE)" = "$R31_REAL_OID" ]; then
    ok "origin's real UNMERGED doomed SURVIVES --execute (R3-1)"
else
    bad "origin's real doomed was deleted or moved — data loss (R3-1)"
fi

cd "$REPO"
echo ""
echo "== 19b. remote scope REFUSES when origin/main cannot resolve (F8) =="
# `git branch -r --merged "origin/$MAIN_BRANCH"` exits NON-ZERO with NO output
# when that ref does not resolve. The old loop carried `|| true`, so the status
# was swallowed, the candidate list was EMPTY, and the pass printed
# `✅ No stale merged branches found` and exited 0 — a FALSE PASS over an estate
# that still holds a stale merged branch. A `--single-branch --branch foo` clone
# leaves exactly that state: `git fetch origin --prune` exits 0 and
# refs/remotes/origin/main is NEVER created, while origin's `foo` IS merged and
# stale. This is the "an unreadable map is not an empty one" rule the LOCAL
# scope already enforces with `main_ref_ok`; the remote scope must refuse too.
F8_ORIGIN="$FIX/f8-origin.git"
F8_SEED="$FIX/f8-seed"
F8_CLONE="$FIX/f8-clone"
new_repo "$F8_SEED" "$F8_ORIGIN"
cd "$F8_SEED"
mkdir -p scripts
cp "$SCRIPT" scripts/
F8_SCRIPT="$F8_SEED/scripts/cleanup-stale-branches.sh"
echo base > f8.txt; git add f8.txt; old_commit "init"; git push -q origin main
# foo — merged into main and STALE, so it WOULD be a candidate if origin/main resolved.
git checkout -q -b foo main
echo foo > foo.txt; git add foo.txt; old_commit "foo"
git push -q -u origin foo
git checkout -q main
git merge -q --ff-only foo
git push -q origin main
# The single-branch clone: remote.origin.fetch omits refs/heads/main entirely.
git clone -q --single-branch --branch foo "$F8_ORIGIN" "$F8_CLONE"
if git -C "$F8_CLONE" rev-parse --verify -q refs/remotes/origin/main >/dev/null 2>&1; then
    bad "F8 fixture: refs/remotes/origin/main resolved — the fixture no longer exercises the defect (F8)"
else
    ok "F8 fixture: refs/remotes/origin/main does NOT resolve after a 0-exit fetch (F8)"
fi
if git -C "$F8_CLONE" rev-parse --verify -q refs/remotes/origin/foo >/dev/null 2>&1; then
    ok "F8 fixture: refs/remotes/origin/foo resolves (origin's merged+stale foo is present) (F8)"
else
    bad "F8 fixture: refs/remotes/origin/foo is missing (F8)"
fi
run_script bash "$F8_SCRIPT" --repo "$F8_CLONE" --scope remote
assert_eq "$RC" "1" "an unresolvable origin/main REFUSES the remote scope (F8)"
assert_contains "$OUT" "origin/main does not resolve" "the refusal names the unresolved ref (F8)"
assert_not_contains "$OUT" "No stale merged branches found" "the false 'nothing is stale' success line is NOT printed (F8)"
# And the same state must refuse the remote leg under --execute as well.
run_script bash "$F8_SCRIPT" --repo "$F8_CLONE" --scope remote --execute
assert_eq "$RC" "1" "an unresolvable origin/main REFUSES --execute too (F8)"
assert_not_contains "$OUT" "✅ deleted" "nothing is deleted against an unresolvable merge base (F8)"

cd "$REPO"
echo ""
echo "== 20. a FAILED fetch REFUSES the remote sweep even under CLEANUP_BRANCH_LOG (R3-2) =="
# `git fetch origin --prune --quiet` in the remote scope was bare and relied on
# `set -e`. The opt-in report log wraps the whole pass in `set +e` (so PIPESTATUS
# can be read through the tee), which DISABLES that abort: a failed fetch fell
# through, the STALE tracking ref was classified, and `git push origin --delete`
# destroyed origin's real branch. CLEANUP_BRANCH_LOG is set by
# templates/launchd/com.tortoise.branch-reaper.plist — the normal operator
# invocation — so the check must be EXPLICIT, never errexit-dependent.
R32_ORIGIN="$FIX/r32-origin.git"
R32_REPO="$FIX/r32-repo"
new_repo "$R32_REPO" "$R32_ORIGIN"
cd "$R32_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R32_SCRIPT="$R32_REPO/scripts/cleanup-stale-branches.sh"
echo base > r32.txt; git add r32.txt; old_commit "init"; git push -q origin main
git checkout -q -b doomed32 main
echo old > old32.txt; git add old32.txt; old_commit "old32"
git push -q -u origin doomed32
git checkout -q main
git merge -q --ff-only doomed32
git push -q origin main
R32_ORIGIN_OID="$(git rev-parse origin/doomed32)"
# A broken fetch refspec that makes `git fetch` FAIL while `git push --delete`
# still SUCCEEDS: fetching into `refs/heads/*` refuses to update the CHECKED-OUT
# main branch, but push parses no fetch refspec.
git config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
if git fetch origin --prune --quiet >/dev/null 2>&1; then
    bad "fetch-failure fixture: the broken refspec did NOT make fetch fail (R3-2)"
else
    ok "fetch-failure fixture: the broken refspec makes fetch FAIL (R3-2)"
fi
# Prove push still works on this config, so the survival below is attributable to
# the FETCH check and not to a push that simply cannot run.
git push -q origin refs/heads/main:refs/heads/r32-push-probe
if git push -q origin --delete -- r32-push-probe; then
    ok "fetch-failure fixture: 'git push --delete' still SUCCEEDS under the broken fetch config (R3-2)"
else
    bad "fetch-failure fixture: push also fails, so the fixture does not isolate the fetch check (R3-2)"
fi
R32_LOG="$FIX/r32-report.log"
run_script env CLEANUP_BRANCH_LOG="$R32_LOG" bash "$R32_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "with the log set, a FAILED fetch refuses the remote sweep (R3-2)"
assert_contains "$OUT" "git fetch origin --prune --quiet FAILED" "the failed fetch is named (R3-2)"
assert_contains "$OUT" "Refusing the remote sweep because the fetch failed" "the refusal is explicit, not deferred to delete-time verification (R3-2)"
assert_not_contains "$OUT" "REFUSING to delete origin/" "the sweep never reached the delete loop (R3-2)"
assert_contains "$(cat "$R32_LOG")" "Refusing the remote sweep because the fetch failed" "the refusal reaches the log through the tee (R3-2)"
if [ "$(git -C "$R32_ORIGIN" rev-parse -q --verify refs/heads/doomed32 || echo GONE)" = "$R32_ORIGIN_OID" ]; then
    ok "origin's real doomed32 SURVIVES the failed-fetch --execute (R3-2)"
else
    bad "origin's real doomed32 was deleted on a failed fetch — data loss (R3-2)"
fi

cd "$REPO"
echo ""
echo "== 21. --scope both propagates a remote REFUSAL through the log pipe (R3-4) =="
# Under `set +e` (the log path) the `both` case ran `run_remote_scope` bare and
# then `run_local_scope`, whose status 0 became PIPESTATUS[0] — a REFUSED remote
# sweep was reported as success. The refusal must be independent of errexit.
R34_ORIGIN="$FIX/r34-origin.git"
R34_REPO="$FIX/r34-repo"
new_repo "$R34_REPO" "$R34_ORIGIN"
cd "$R34_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R34_SCRIPT="$R34_REPO/scripts/cleanup-stale-branches.sh"
echo base > r34.txt; git add r34.txt; old_commit "init"; git push -q origin main
git checkout -q -b doomed34 main
echo old > old34.txt; git add old34.txt; old_commit "old34"
git push -q -u origin doomed34
git checkout -q main
git merge -q --ff-only doomed34
git push -q origin main
git config --add remote.origin.fetch '^refs/heads/doomed34'
git fetch origin --prune --quiet
R34_LOG="$FIX/r34-report.log"
# --pr-map-file supplies a VALID map, so the LOCAL leg returns 0 — otherwise the
# reverted code would exit non-zero for an unrelated reason and the test would not
# be falsifying.
run_script env CLEANUP_BRANCH_LOG="$R34_LOG" \
    bash "$R34_SCRIPT" --scope both --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "1" "--scope both with the log set exits NON-ZERO when the remote sweep refuses (R3-4)"
assert_contains "$OUT" "Refusing the remote sweep" "the remote refusal is the cause (R3-4)"
# Prove the local leg WOULD have returned 0 — the pre-fix status that masked it.
run_script bash "$R34_SCRIPT" --scope local --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "0" "the local leg alone exits 0 under the same fixture (so only the remote leg is non-zero) (R3-4)"

echo ""
echo "== 21b. --scope both RUNS the local leg even when the remote leg refuses (F4) =="
# `run_remote_scope || return 1` aborted `run_scopes` BEFORE `run_local_scope`,
# so every local deletion was silently skipped whenever the remote sweep
# refused. The two legs are independent, and `--help` promises "remote, then
# local". Both must run, and a refusal in either must reach the exit status.
# R34_REPO already carries the negative refspec that refuses the remote sweep
# AND a local branch (`doomed34`) the redundant gate selects, so one run shows
# both facts. NO --execute: the point is that the local leg RUNS, which the
# dry-run's SELECTED line proves; nothing is deleted outside the fixture anyway.
run_script bash "$R34_SCRIPT" --repo "$R34_REPO" --scope both --pr-map-file "$PR_MAP_OTHER"
assert_eq "$RC" "1" "--scope both is NON-ZERO when the remote leg refuses (F4)"
assert_contains "$OUT" "Refusing the remote sweep" "the remote refusal is the cause (F4)"
assert_contains "$OUT" "Stale Local Branch Cleanup" "the LOCAL leg still RAN despite the remote refusal (F4)"
assert_match "$OUT" '^  delete +redundant +doomed34$' "the local leg still classified and selected (F4)"

cd "$REPO"
echo ""
echo "== 22. remote scope handles a '|' in a ref name without truncating it (R3-3) =="
# `|` is a LEGAL ref-name character (`git check-ref-format 'refs/heads/foo|bar'`
# is OK), and the sweep encoded `"$branch|$DATE"` then decoded with
# `${entry%%|*}` — a LONGEST-suffix strip — so `origin/foo|bar` decoded to
# `origin/foo`: the premise was evaluated on one ref and the delete landed on
# ANOTHER. Same truncation in the non-origin decode. The separator is now TAB,
# which check-ref-format REJECTS in a ref name (so the sentinel cannot collide).
R33_ORIGIN="$FIX/r33-origin.git"
R33_REPO="$FIX/r33-repo"
new_repo "$R33_REPO" "$R33_ORIGIN"
cd "$R33_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R33_SCRIPT="$R33_REPO/scripts/cleanup-stale-branches.sh"
echo base > r33.txt; git add r33.txt; old_commit "init"; git push -q origin main
# `foo|bar` — an old MERGED tip, so it IS a stale `--merged` candidate.
git checkout -q -b 'foo|bar' main
echo fb > fb.txt; git add fb.txt; old_commit "foo-bar"
git push -q origin 'refs/heads/foo|bar:refs/heads/foo|bar'
git checkout -q main
git merge -q --ff-only 'foo|bar'
git push -q origin main
# `foo` — a DIFFERENT origin branch with an UNMERGED commit: the ref the pre-fix
# truncation would have destroyed.
git checkout -q -b foo main
echo f > f.txt; git add f.txt; old_commit "foo-unmerged"
git push -q origin refs/heads/foo:refs/heads/foo
git checkout -q main
git rev-parse --verify -q refs/heads/foo >/dev/null
R33_FOO_OID="$(git -C "$R33_ORIGIN" rev-parse refs/heads/foo)"
run_script bash "$R33_SCRIPT" --scope remote
assert_eq "$RC" "0" "pipe-named fixture: dry-run exits 0 (R3-3)"
assert_match "$OUT" '--delete --force-with-lease=refs/heads/foo\\[|]bar:[0-9a-f]+ -- refs/heads/foo\\[|]bar' 'the dry-run plan targets foo|bar with the lease, not a truncated foo (R3-3/F2)'
# F3: `--delete -- "refs/heads/foo"$` can never occur under the leased form, so it
# was unfalsifiable. The lease-aware negative is RED if the truncation returns
# (the plan would lease plain refs/heads/foo).
assert_no_match "$OUT" 'force-with-lease=refs/heads/foo:' 'the dry-run plan does NOT lease plain foo (R3-3)'
run_script bash "$R33_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "pipe-named fixture: --execute exits 0 (R3-3)"
if [ -z "$(git ls-remote origin 'refs/heads/foo|bar' 2>/dev/null)" ]; then
    ok "origin refs/heads/foo|bar was actually reaped (R3-3)"
else
    bad "origin refs/heads/foo|bar was NOT reaped (R3-3)"
fi
if [ "$(git -C "$R33_ORIGIN" rev-parse -q --verify refs/heads/foo || echo GONE)" = "$R33_FOO_OID" ]; then
    ok "origin's UNMERGED foo SURVIVES (the truncated target was never deleted) (R3-3)"
else
    bad "origin's foo was deleted by the truncated target — data loss (R3-3)"
fi

cd "$REPO"
echo ""
echo "== 23. the remote HAPPY PATH still deletes a stale merged branch when the refs AGREE (R3-1) =="
# The delete-time verification must not become a blanket refusal: a genuinely
# stale, merged remote branch whose tracking ref EQUALS origin's real ref is
# still deletable.
R35_ORIGIN="$FIX/r35-origin.git"
R35_REPO="$FIX/r35-repo"
new_repo "$R35_REPO" "$R35_ORIGIN"
cd "$R35_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R35_SCRIPT="$R35_REPO/scripts/cleanup-stale-branches.sh"
echo base > r35.txt; git add r35.txt; old_commit "init"; git push -q origin main
git checkout -q -b happily-stale main
echo hs > hs.txt; git add hs.txt; old_commit "hs"
git push -q -u origin happily-stale
git checkout -q main
git merge -q --ff-only happily-stale
git push -q origin main
run_script bash "$R35_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "the happy path exits 0 (R3-1)"
assert_contains "$OUT" "Refused: 0" "nothing was refused when the refs agree (R3-1)"
if [ -z "$(git ls-remote origin refs/heads/happily-stale 2>/dev/null)" ]; then
    ok "a genuinely stale merged remote branch IS still deleted (R3-1)"
else
    bad "the happy path no longer deletes a stale merged remote branch (R3-1)"
fi

cd "$REPO"
echo ""
echo "== 24. the verifier proves the PUSH url, not the FETCH url — remote.origin.pushurl (F1) =="
# `git ls-remote origin` reads the FETCH url (remote.origin.url) while
# `git push origin` honours remote.origin.pushurl, which may name a DIFFERENT
# repository. Pre-fix the fetch-side check proved repo A while the delete landed
# on repo B — and reported success. The target must be resolved with
# `git remote get-url --push origin` and used for BOTH the proof and the delete.
P1_A="$FIX/p1-a.git"
P1_B="$FIX/p1-b.git"
P1_REPO="$FIX/p1-repo"
new_repo "$P1_REPO" "$P1_A"
cd "$P1_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
P1_SCRIPT="$P1_REPO/scripts/cleanup-stale-branches.sh"
echo base > p1.txt; git add p1.txt; old_commit "init"; git push -q origin main
# Repo A: `doomed` is merged into main and stale → a genuine candidate.
git checkout -q -b doomed main
echo da > da.txt; git add da.txt; old_commit "doomed-on-A"
git push -q -u origin doomed
git checkout -q main
git merge -q --ff-only doomed
git push -q origin main
P1_A_OID="$(git -C "$P1_A" rev-parse refs/heads/doomed)"
# Repo B: its own `doomed` holds a UNIQUE, UNMERGED commit that exists nowhere else.
git init -q --bare "$P1_B"
git checkout -q -b b-doomed main
echo dangerB > dangerB.txt; git add dangerB.txt; old_commit "doomed-on-B"
P1_B_OID="$(git rev-parse HEAD)"
git push -q "$P1_B" refs/heads/b-doomed:refs/heads/doomed
git checkout -q main
git rev-parse --verify -q refs/heads/b-doomed >/dev/null
if [ "$P1_A_OID" != "$P1_B_OID" ]; then
    ok "pushurl fixture: repo A's and repo B's doomed differ (the divergence is real) (F1)"
else
    bad "pushurl fixture: A and B share one oid — the fixture does not exercise the divergence (F1)"
fi
# The divergence itself: fetch from A, push to B.
git config remote.origin.pushurl "$P1_B"
if [ "$(git remote get-url --push origin)" = "$P1_B" ]; then
    ok "pushurl fixture: git resolves origin's PUSH url to repo B (F1)"
else
    bad "pushurl fixture: git did not resolve the pushurl — the fixture is wrong (F1)"
fi
run_script bash "$P1_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "a pushurl divergence REFUSES the delete (F1)"
assert_contains "$OUT" "REFUSING to delete origin/doomed" "the pushurl divergence is refused (F1)"
assert_contains "$OUT" "Refused: 1" "the pushurl refusal is counted (F1)"
if [ "$(git -C "$P1_B" rev-parse -q --verify refs/heads/doomed || echo GONE)" = "$P1_B_OID" ]; then
    ok "repo B's unique UNMERGED doomed SURVIVES (F1)"
else
    bad "repo B's doomed was DELETED — data loss (F1)"
fi

cd "$REPO"
echo ""
echo "== 25. the verifier proves the PUSH url — pushInsteadOf with no pushurl (F1) =="
# The same divergence with NO pushurl: `url.<base>.pushInsteadOf` rewrites every
# push to origin into a push to a DIFFERENT repository. `git remote get-url
# --push` applies that rewrite, so it must be the URL the verifier and the
# delete both use.
P2_A="$FIX/p2-a.git"
P2_C="$FIX/p2-c.git"
P2_REPO="$FIX/p2-repo"
new_repo "$P2_REPO" "$P2_A"
cd "$P2_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
P2_SCRIPT="$P2_REPO/scripts/cleanup-stale-branches.sh"
echo base > p2.txt; git add p2.txt; old_commit "init"; git push -q origin main
git checkout -q -b doomed main
echo da > da.txt; git add da.txt; old_commit "doomed-on-A2"
git push -q -u origin doomed
git checkout -q main
git merge -q --ff-only doomed
git push -q origin main
P2_A_OID="$(git -C "$P2_A" rev-parse refs/heads/doomed)"
git init -q --bare "$P2_C"
git checkout -q -b c-doomed main
echo dangerC > dangerC.txt; git add dangerC.txt; old_commit "doomed-on-C"
P2_C_OID="$(git rev-parse HEAD)"
git push -q "$P2_C" refs/heads/c-doomed:refs/heads/doomed
git checkout -q main
git rev-parse --verify -q refs/heads/c-doomed >/dev/null
if [ "$P2_A_OID" != "$P2_C_OID" ]; then
    ok "pushInsteadOf fixture: repo A's and repo C's doomed differ (F1)"
else
    bad "pushInsteadOf fixture: A and C share one oid — the fixture does not exercise the divergence (F1)"
fi
# No pushurl: the rewrite alone must redirect the push.
git config "url.$P2_C.pushInsteadOf" "$P2_A"
if [ "$(git remote get-url --push origin)" = "$P2_C" ]; then
    ok "pushInsteadOf fixture: git resolves origin's PUSH url to repo C (F1)"
else
    bad "pushInsteadOf fixture: git did not apply pushInsteadOf — the fixture is wrong (F1)"
fi
run_script bash "$P2_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "a pushInsteadOf divergence REFUSES the delete (F1)"
assert_contains "$OUT" "REFUSING to delete origin/doomed" "the pushInsteadOf divergence is refused (F1)"
if [ "$(git -C "$P2_C" rev-parse -q --verify refs/heads/doomed || echo GONE)" = "$P2_C_OID" ]; then
    ok "repo C's unique UNMERGED doomed SURVIVES (F1)"
else
    bad "repo C's doomed was DELETED — data loss (F1)"
fi

cd "$REPO"
echo ""
echo "== 26. remote scope reaps '@' and a foo vs refs/heads/foo collision (F2) =="
# `@` is a legal ref name but also a revision shorthand: `git push --delete @`
# fails with `fatal: invalid refspec ':@'` and the sweep still exits 0, so the
# branch is never reaped. A bare `foo` is likewise ambiguous beside
# `refs/heads/foo`. Pushing the FULLY-QUALIFIED ref fixes both.
P3_ORIGIN="$FIX/p3-origin.git"
P3_REPO="$FIX/p3-repo"
new_repo "$P3_REPO" "$P3_ORIGIN"
cd "$P3_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
P3_SCRIPT="$P3_REPO/scripts/cleanup-stale-branches.sh"
echo base > p3.txt; git add p3.txt; old_commit "init"; git push -q origin main
git checkout -q -b merged-tip main
echo m > m.txt; git add m.txt; old_commit "merged-tip"
git checkout -q main
git merge -q --ff-only merged-tip
git push -q origin main
P3_SHA="$(git rev-parse main)"
git update-ref refs/heads/@ "$P3_SHA"
git update-ref refs/heads/collide "$P3_SHA"
# push the three remote refs one at a time (a bare `refs/heads/foo` SRC is itself
# ambiguous beside refs/heads/refs/heads/foo)
git push -q origin refs/heads/@:refs/heads/@
git push -q origin refs/heads/collide:refs/heads/foo
git push -q origin refs/heads/collide:refs/heads/refs/heads/foo
for _r in 'refs/heads/@' 'refs/heads/foo' 'refs/heads/refs/heads/foo'; do
    if [ -n "$(git ls-remote origin "$_r" 2>/dev/null)" ]; then
        ok "qualified-ref fixture: origin has $_r (F2)"
    else
        bad "qualified-ref fixture: origin is missing $_r (F2)"
    fi
done
unset _r
run_script bash "$P3_SCRIPT" --scope remote
assert_eq "$RC" "0" "qualified-ref fixture: dry-run exits 0 (F2)"
assert_contains "$OUT" "--force-with-lease=refs/heads/@:$P3_SHA -- refs/heads/@" 'the plan targets the QUALIFIED ref for @ with the lease (F2)'
assert_contains "$OUT" "--force-with-lease=refs/heads/refs/heads/foo:$P3_SHA -- refs/heads/refs/heads/foo" 'the plan targets the QUALIFIED nested ref with the lease (F2)'
run_script bash "$P3_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "qualified-ref fixture: --execute exits 0 (F2)"
for _r in 'refs/heads/@' 'refs/heads/foo' 'refs/heads/refs/heads/foo'; do
    if [ "$(git -C "$P3_ORIGIN" rev-parse -q --verify "$_r" 2>/dev/null || echo GONE)" = "GONE" ]; then
        ok "origin $_r was actually reaped (F2)"
    else
        bad "origin $_r was NOT reaped (F2)"
    fi
done
unset _r

cd "$REPO"
echo ""
echo "== 27. the delete-time verifier checks the returned ref NAME, not just the OID (F3) =="
# `ls-remote <pattern>` matches path-component SUFFIXES: with only
# `refs/heads/refs/heads/foo` present, `ls-remote refs/heads/foo` RETURNS it, so a
# count==1 + OID comparison PASSES for `foo` while the matched ref has a
# different name. The verifier must require an exact ref-name match.
P4_ORIGIN="$FIX/p4-origin.git"
P4_REPO="$FIX/p4-repo"
new_repo "$P4_REPO" "$P4_ORIGIN"
cd "$P4_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
P4_SCRIPT="$P4_REPO/scripts/cleanup-stale-branches.sh"
echo base > p4.txt; git add p4.txt; old_commit "init"; git push -q origin main
P4_SHA="$(git rev-parse main)"
# origin gets ONLY the nested-suffix ref, at the merged OID...
git -C "$P4_ORIGIN" update-ref refs/heads/refs/heads/foo "$P4_SHA"
# ...and the local repo holds a STALE tracking ref `origin/foo` at that OID.
git update-ref refs/remotes/origin/foo "$P4_SHA"
# A narrowed fetch refspec keeps `--prune` from removing origin/foo (it tracks
# only main) — the same staleness mechanism section 19 exercises.
git config --replace-all remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
if [ "$(git rev-parse origin/foo)" = "$P4_SHA" ]; then
    ok "suffix-only fixture: origin/foo is a stale tracking ref at the merged oid (F3)"
else
    bad "suffix-only fixture: origin/foo is not as set up (F3)"
fi
run_script bash "$P4_SCRIPT" --scope remote --execute
assert_eq "$RC" "1" "a suffix-only match is REFUSED, not passed (F3)"
assert_contains "$OUT" "REFUSING to delete origin/foo" "the suffix-only match is refused (F3)"
assert_contains "$OUT" "named exactly refs/heads/foo" "the refusal names the missing EXACT ref (F3)"
if [ "$(git -C "$P4_ORIGIN" rev-parse -q --verify refs/heads/refs/heads/foo || echo GONE)" = "$P4_SHA" ]; then
    ok "the nested ref SURVIVES the refused suffix-only match (F3)"
else
    bad "the nested ref was deleted by a suffix-only match — wrong target (F3)"
fi

cd "$REPO"
echo ""
echo "== 27b. a same-suffix ref does NOT falsely refuse the legitimate branch (F3) =="
P5_ORIGIN="$FIX/p5-origin.git"
P5_REPO="$FIX/p5-repo"
new_repo "$P5_REPO" "$P5_ORIGIN"
cd "$P5_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
P5_SCRIPT="$P5_REPO/scripts/cleanup-stale-branches.sh"
echo base > p5.txt; git add p5.txt; old_commit "init"; git push -q origin main
# `foo` — merged into main, stale → a genuine candidate.
git checkout -q -b foo main
echo f > f.txt; git add f.txt; old_commit "foo-merged"
git push -q -u origin foo
git checkout -q main
git merge -q --ff-only foo
git push -q origin main
# `refs/heads/refs/heads/foo` — a legitimate stale merged ref whose name is a
# SUFFIX match for `foo` (so `ls-remote refs/heads/foo` returns TWO refs).
git push -q origin refs/heads/foo:refs/heads/refs/heads/foo
run_script bash "$P5_SCRIPT" --scope remote --execute
assert_eq "$RC" "0" "a same-suffix ref does NOT cause a false refusal (F3)"
assert_contains "$OUT" "Refused: 0" "nothing was refused when foo is the exact match (F3)"
assert_contains "$OUT" "Deleting origin/foo..." "the legitimate foo is not refused by the verifier (F3)"
if [ "$(git -C "$P5_ORIGIN" rev-parse -q --verify refs/heads/foo || echo GONE)" = "GONE" ]; then
    ok "the legitimate foo IS still deleted beside a suffix-matching ref (F3)"
else
    bad "the legitimate foo was FALSELY REFUSED (F3)"
fi
if [ "$(git -C "$P5_ORIGIN" rev-parse -q --verify refs/heads/refs/heads/foo || echo GONE)" = "GONE" ]; then
    ok "the same-named suffix ref is reaped on its own evidence (F3)"
else
    bad "the suffix ref was left behind (F3)"
fi

cd "$REPO"
echo ""
echo "== 28. github_slug normalises the HOST case (F4) =="
# URL host names are case-insensitive and git accepts `https://GitHub.com/o/r.git`,
# but the exact `[ "$host" != "github.com" ]` comparison refused it — a false
# negative that disables the PR-state seam for a legitimate origin.
git -C "$REPO3" remote set-url origin 'https://GitHub.com/example/example.git'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "a mixed-case GitHub.com origin resolves the slug (F4)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'a mixed-case host still classifies normally (F4)'
# Restore the canonical github.com URL for any later use.
git -C "$REPO3" remote set-url origin 'https://github.com/example/example.git'

cd "$REPO"
echo ""
echo "== 29. a CHAINED pushInsteadOf is applied ONCE by the delete (R5-1) =="
# `git remote get-url --push origin` applies pushInsteadOf ONCE, so with
# `url.B.pushInsteadOf=A` and `url.C.pushInsteadOf=B` it resolves to repo B. The
# pre-fix delete then ran `git push "$push_url"`, i.e. `git push B`, which applies
# the rewrite a SECOND time and lands on repo C — an unverified repository whose
# unique UNMERGED branch is destroyed, reported as `Deleted: 1 / Refused: 0`,
# rc=0. The delete must go through git's own remote resolution
# (`git push origin --delete`), which applies the rewrite exactly once — the same
# single application that produced the verified URL.
R51_A="$FIX/r51-a.git"
R51_B="$FIX/r51-b.git"
R51_C="$FIX/r51-c.git"
R51_REPO="$FIX/r51-repo"
new_repo "$R51_REPO" "$R51_A"
cd "$R51_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R51_SCRIPT="$R51_REPO/scripts/cleanup-stale-branches.sh"
echo base > r51.txt; git add r51.txt; old_commit "init"; git push -q origin main
git checkout -q -b chain-doomed main
echo cd > cd.txt; git add cd.txt; old_commit "chain-doomed-on-A"
git push -q -u origin chain-doomed
git checkout -q main
git merge -q --ff-only chain-doomed
git push -q origin main
R51_A_OID="$(git -C "$R51_A" rev-parse refs/heads/chain-doomed)"
# Repo B is a MIRROR of A's merged branch — the same OID — so a verification
# against B passes. B is what `get-url --push` resolves to.
git init -q --bare "$R51_B"
git push -q "$R51_B" refs/heads/chain-doomed:refs/heads/chain-doomed
# Repo C holds a UNIQUE, UNMERGED chain-doomed that exists nowhere else.
git init -q --bare "$R51_C"
git checkout -q -b c-chain main
echo dangerChain > dangerChain.txt; git add dangerChain.txt; old_commit "chain-doomed-on-C"
R51_C_OID="$(git rev-parse HEAD)"
git push -q "$R51_C" refs/heads/c-chain:refs/heads/chain-doomed
git checkout -q main
git rev-parse --verify -q refs/heads/c-chain >/dev/null
if [ "$R51_A_OID" != "$R51_C_OID" ]; then
    ok "chained-rewrite fixture: A's and C's chain-doomed differ (R5-1)"
else
    bad "chained-rewrite fixture: A and C share one oid — no divergence to exercise (R5-1)"
fi
# Prove the premise: get-url applies ONCE (→B), so the fix's single-target
# resolution holds and the ambiguity refusal does NOT fire.
git config "url.$R51_B.pushInsteadOf" "$R51_A"
git config "url.$R51_C.pushInsteadOf" "$R51_B"
if [ "$(git remote get-url --push origin)" = "$R51_B" ]; then
    ok "chained-rewrite fixture: get-url --push applies the rewrite ONCE (→ repo B) (R5-1)"
else
    bad "chained-rewrite fixture: get-url --push did not resolve to B — the fixture is wrong (R5-1)"
fi
if [ "$(git remote get-url --push --all origin | wc -l | tr -d ' ')" = "1" ]; then
    ok "chained-rewrite fixture: --all resolves ONE push url (the fix does not refuse) (R5-1)"
else
    bad "chained-rewrite fixture: --all did not resolve exactly one push url (R5-1)"
fi
# The DRY-RUN plan must name git's own resolution, never the resolved URL (which
# would be re-rewritten at push time).
run_script bash "$R51_SCRIPT" --repo "$R51_REPO" --scope remote
assert_eq "$RC" "0" "chained-rewrite fixture: dry-run exits 0 (R5-1)"
assert_contains "$OUT" "git push origin --delete --force-with-lease=refs/heads/chain-doomed:$R51_A_OID -- refs/heads/chain-doomed" 'the dry-run plan deletes through origin WITH the lease, not the resolved URL (R5-1/F2)'
assert_not_contains "$OUT" "$R51_B" 'the dry-run plan does NOT echo the resolved URL as the push target (R5-1)'
run_script bash "$R51_SCRIPT" --repo "$R51_REPO" --scope remote --execute
assert_eq "$RC" "0" "chained-rewrite fixture: --execute exits 0 (R5-1)"
assert_contains "$OUT" "Deleted: 1" "exactly one branch is deleted (R5-1)"
if [ "$(git -C "$R51_B" rev-parse -q --verify refs/heads/chain-doomed || echo GONE)" = "GONE" ]; then
    ok "the VERIFIED target (repo B) is the one reaped (R5-1)"
else
    bad "repo B's chain-doomed was NOT deleted (R5-1)"
fi
if [ "$(git -C "$R51_C" rev-parse -q --verify refs/heads/chain-doomed || echo GONE)" = "$R51_C_OID" ]; then
    ok "repo C's unique UNMERGED chain-doomed SURVIVES (the rewrite is NOT applied twice) (R5-1)"
else
    bad "repo C's chain-doomed was DELETED — the delete re-rewrote the resolved URL (R5-1)"
fi

cd "$REPO"
echo ""
echo "== 29b. the dry-run plan and the EXECUTED delete carry the SAME command (F1) =="
# The dry-run's job is to tell the operator what `--execute` WOULD run. If it
# prints the pre-lease `git push origin --delete -- refs/heads/<br>` while the
# execute path runs `--force-with-lease=refs/heads/<br>:<oid>`, then an operator
# who copies the printed line runs exactly the unguarded delete the lease exists
# to prevent (no compare-and-swap: a pushInsteadOf/pushurl divergence would
# delete unconditionally). Capture the dry-run command, then read the executed
# argv from git's OWN trace and require the two to be the same string.
F1C_ORIGIN="$FIX/f1c-origin.git"
F1C_REPO="$FIX/f1c-repo"
new_repo "$F1C_REPO" "$F1C_ORIGIN"
cd "$F1C_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F1C_SCRIPT="$F1C_REPO/scripts/cleanup-stale-branches.sh"
echo base > f1c.txt; git add f1c.txt; old_commit "init"; git push -q origin main
git checkout -q -b plan-match main
echo pm > pm.txt; git add pm.txt; old_commit "plan-match"
git push -q -u origin plan-match
git checkout -q main
git merge -q --ff-only plan-match
git push -q origin main
F1C_OID="$(git -C "$F1C_ORIGIN" rev-parse refs/heads/plan-match)"

run_script bash "$F1C_SCRIPT" --repo "$F1C_REPO" --scope remote
assert_eq "$RC" "0" "command-parity fixture: dry-run exits 0 (F1)"
DRY_CMD="$(grep -F 'git push origin --delete' <<<"$OUT" | head -n1 || true)"
DRY_CMD="${DRY_CMD#  }"
if [ -n "$DRY_CMD" ]; then
    ok "command-parity fixture: the dry-run prints a delete command (F1)"
else
    bad "command-parity fixture: the dry-run printed no delete command (F1)"
fi
assert_contains "$DRY_CMD" "--force-with-lease=refs/heads/plan-match:$F1C_OID" 'the dry-run command carries the classified-oid lease (F1)'

# GIT_TRACE=1 makes git print `trace: built-in: git push <argv...>`. The script
# captures the push's own stderr (2>&1) and re-prints it, so the trace lands in OUT.
run_script env GIT_TRACE=1 bash "$F1C_SCRIPT" --repo "$F1C_REPO" --scope remote --execute
assert_eq "$RC" "0" "command-parity fixture: --execute exits 0 (F1)"
TRACE_CMD="$(grep -F 'git push origin --delete' <<<"$OUT" | grep -F 'built-in' | head -n1 || true)"
if [ -n "$TRACE_CMD" ]; then
    ok "command-parity fixture: GIT_TRACE exposed the executed push argv (F1)"
else
    bad "command-parity fixture: GIT_TRACE did not expose the executed push argv (F1)"
fi
# The plan is now shell-quoted only where the shell needs it, so removing `"`
# is a no-op for the plain `plan-match` name; the command string (every FLAG and
# operand) must be identical to what git executed.
DRY_CMD_PLAIN="${DRY_CMD//\"/}"
TRACE_CMD_PLAIN="${TRACE_CMD#*built-in: }"
if [ -n "$TRACE_CMD_PLAIN" ] && [ "$TRACE_CMD_PLAIN" = "$DRY_CMD_PLAIN" ]; then
    ok "the dry-run plan and the executed command are the SAME string (F1)"
else
    bad "the dry-run plan and the executed command DIFFER (F1): plan='$DRY_CMD_PLAIN' exec='$TRACE_CMD_PLAIN'"
fi

echo ""
echo "== 29c. the dry-run plan is PASTE-SAFE for legal special ref names (F2) =="
# A git ref name may legally contain `$()`, a double quote, a single quote, a
# backtick or `|` (`git check-ref-format` accepts them). The old plan echoed
# `--force-with-lease="refs/heads/$local_branch:$oid"`, so pasting the printed
# line ran `$(id)` as a COMMAND and mangled a `"`-bearing name into a different
# refspec. The plan is now built as ONE array and rendered through `quote_argv`,
# so evaluating the printed line must re-parse to EXACTLY the argv the execute
# path runs. This asserts that round-trip byte-for-byte (NUL-delimited argv), not
# merely that a lease substring appears. Names are chosen with DISTINCT lengths
# so the length-descending delete order is total and the two streams are
# comparable without a sort.
F2_ORIGIN="$FIX/f2-origin.git"
F2_REPO="$FIX/f2-repo"
new_repo "$F2_REPO" "$F2_ORIGIN"
cd "$F2_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F2_SCRIPT="$F2_REPO/scripts/cleanup-stale-branches.sh"
echo base > f2.txt; git add f2.txt; old_commit "init"; git push -q origin main
# Legal special ref names: `$()` (11), backtick (9), single quote (5), double
# quote (4). A SPACE is NOT a legal ref name (check-ref-format rejects it), so it
# cannot enter this path — the quoting primitive's space handling is asserted
# separately below.
F2_NAMES=('pwn$(id)end' 'back`tick' "s'qzz" 'q"xx')
for _n in "${F2_NAMES[@]}"; do
    git checkout -q -b "$_n" main
    git push -q -u origin "$_n"
    git checkout -q main
done
F2_REAL_GIT="$(command -v git)"
F2_WRAP="$FIX/f2-wrap"
mkdir -p "$F2_WRAP"
cat > "$F2_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double: intercept `git push`. In `print` mode it dumps the argv (the
# paste-evaluation side); otherwise it appends the argv to GIT_WRAP_LOG and then
# delegates to the real git, so the execute path really deletes.
REAL_GIT="${F2_REAL_GIT:?F2_REAL_GIT unset}"
if [ "$1" = "push" ]; then
    if [ "${GIT_WRAP_MODE:-delegate}" = "print" ]; then
        printf '%s\000' "$@"
        printf '\000'
        exit 0
    fi
    {
        printf '%s\000' "$@"
        printf '\000'
    } >>"${GIT_WRAP_LOG:?GIT_WRAP_LOG unset}"
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F2_WRAP/git"

run_script bash "$F2_SCRIPT" --repo "$F2_REPO" --scope remote
assert_eq "$RC" "0" "paste-safety fixture: dry-run exits 0 (F2)"
F2_PLAN_COUNT="$(grep -c '^  git push origin --delete' <<<"$OUT" || true)"
assert_eq "$F2_PLAN_COUNT" "4" "the plan prints one paste-safe command per special-named ref (F2)"

# Evaluate each printed plan line with `git` stubbed to an argv dumper, writing
# NUL-delimited records (a ref name cannot contain NUL, so the encoding is exact).
F2_PLAN_ARGV="$FIX/f2-plan.bin"
: > "$F2_PLAN_ARGV"
while IFS= read -r _f2_line; do
    [ -n "$_f2_line" ] || continue
    PATH="$F2_WRAP:$PATH" F2_REAL_GIT="$F2_REAL_GIT" GIT_WRAP_MODE=print \
        bash -c 'eval "$1"' _ "$_f2_line" >>"$F2_PLAN_ARGV"
done <<<"$(grep '^  git push origin --delete' <<<"$OUT" || true)"

# The execute path logs the SAME encoding from its real `git push` invocations.
F2_EXEC_ARGV="$FIX/f2-exec.bin"
: > "$F2_EXEC_ARGV"
run_script env PATH="$F2_WRAP:$PATH" F2_REAL_GIT="$F2_REAL_GIT" GIT_WRAP_LOG="$F2_EXEC_ARGV" \
    bash "$F2_SCRIPT" --repo "$F2_REPO" --scope remote --execute
assert_eq "$RC" "0" "paste-safety fixture: --execute exits 0 (F2)"
if [ -s "$F2_PLAN_ARGV" ] && cmp -s "$F2_PLAN_ARGV" "$F2_EXEC_ARGV"; then
    ok "evaluating the printed plan yields EXACTLY the executed argv (no \$(id) fired) (F2)"
else
    bad "the printed plan does NOT re-parse to the executed argv (F2)"
    echo "    plan argv:"
    od -c "$F2_PLAN_ARGV" | head -n 8
    echo "    exec argv:"
    od -c "$F2_EXEC_ARGV" | head -n 8
fi

# The quoting primitive must also keep a SPACE inside ONE argv element, even
# though no legal ref name can carry one (check-ref-format rejects it), so this
# cannot be exercised end-to-end. Source the SHIPPED function — not a copy — and
# round-trip the argument.
F2_QUOTE_FN="$FIX/f2-quote.sh"
sed -n '/^quote_argv() {/,/^}/p' "$SCRIPT" > "$F2_QUOTE_FN"
if [ -s "$F2_QUOTE_FN" ]; then
    # shellcheck disable=SC1090
    . "$F2_QUOTE_FN"
    F2_SPACE_LINE="$(quote_argv git push --delete '--force-with-lease=refs/heads/a b:deadbeef' -- 'refs/heads/a b')"
    F2_SPACE_ARGS="$(F2_SPACE_LINE="$F2_SPACE_LINE" bash -c 'git() { printf "[%s]" "$@"; }; eval "$F2_SPACE_LINE"')"
    assert_eq "$F2_SPACE_ARGS" "[push][--delete][--force-with-lease=refs/heads/a b:deadbeef][--][refs/heads/a b]" "quote_argv keeps a space inside ONE argv element (F2)"
else
    bad "could not extract quote_argv from the script (F2)"
fi

echo ""
echo "== 29d. the LOCAL dry-run plan is PASTE-SAFE for legal special branch names (F6) =="
# The SAME defect F2 fixed for the remote `git push` plan existed in the LOCAL
# plan: `printf '  git branch -d -- "%s"'` echoes the branch name inside double
# quotes, and a git ref name may LEGALLY contain `$(...)`, `"`, a single quote or
# `|` (`git check-ref-format` accepts them). Pasting
# `git branch -d -- "pwn$(id)end"` runs `$(id)` as a COMMAND and a `"`-bearing
# name re-parses into a different argument. The local plan is now built as ONE
# array and rendered through the SAME `quote_argv`, so evaluating the printed
# line must re-parse to EXACTLY the argv the execute path runs. The
# `# class=<cls>` annotation must stay OUTSIDE that argv.
F6_ORIGIN="$FIX/f6-origin.git"
F6_REPO="$FIX/f6-repo"
new_repo "$F6_REPO" "$F6_ORIGIN"
cd "$F6_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F6_SCRIPT="$F6_REPO/scripts/cleanup-stale-branches.sh"
echo base > f6.txt; git add f6.txt; old_commit "init"; git push -q origin main
F6_MAIN_SHA="$(git rev-parse main)"
# `$(id)` (11), `|` (4), single quote (5), double quote (4): all legal ref-name
# characters, all at main's tip so each is classed `redundant` (`-d` succeeds,
# no `-D`). Created with plumbing (update-ref) so no working-tree operation runs.
F6_NAMES=('pwn$(id)end' 'p|pe' "s'qzz" 'q"xx')
for _f6n in "${F6_NAMES[@]}"; do
    git update-ref "refs/heads/$_f6n" "$F6_MAIN_SHA"
done
# ⛔ AND one `merged`-class name whose tip is NOT an ancestor of main. This is
# one of TWO `merged` shapes: this SQUASH shape reaches the `-D` fallback (`git
# branch -d` refuses a squash-merged tip), while F9's merge-commit shape (below)
# does not. This shape exposed the plan/execute divergence where the plan printed
# just `git branch -d`, while `--execute` silently fell back to `git branch -D`,
# so pasting the plan refused and the branch was never reaped. Built with
# plumbing (commit-tree + update-ref) so no working-tree operation runs. The
# tree is main's, so the commit is distinct and unreachable from main.
F6_TREE="$(git rev-parse "$F6_MAIN_SHA^{tree}")"
F6_MERGED_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F6_TREE" -p "$F6_MAIN_SHA" -m "f6-merged")"
git update-ref refs/heads/f6-merged "$F6_MERGED_SHA"
if git merge-base --is-ancestor "$F6_MERGED_SHA" main 2>/dev/null; then
    bad "F6 fixture: the merged tip IS an ancestor of main — the -D fallback is unreachable (F6/F7)"
else
    ok "F6 fixture: the merged tip is NOT an ancestor of main (the -D fallback is reachable) (F6/F7)"
fi
# ⛔ F9: the OTHER `merged` shape — a branch merged with a MERGE COMMIT. Its tip
# IS an ancestor of main (the merge commit lists it as a parent), so the execute
# path's `git branch -d` SUCCEEDS and `-D` never runs. Pre-F9 the plan printed
# the `-D` fallback UNCONDITIONALLY, making it a strict SUPERSET of execution:
# pasting the plan ran `git branch -D -- f6-manc` → `error: branch 'f6-manc' not
# found`, and under `set -e` that aborted the rest of the paste — an UNDER-reap.
# The plan must print EXACTLY ONE command for this shape. A REAL `git merge
# --no-ff` (not plumbing) is required, because the whole point is the ancestry
# the merge produces.
git checkout -q -b f6-manc main
echo manc > f6-manc.txt
git add f6-manc.txt
old_commit "f6-manc"
F6_MANC_SHA="$(git rev-parse HEAD)"
git checkout -q main
git merge -q --no-ff -m "merge f6-manc" f6-manc
git push -q origin main
if git merge-base --is-ancestor "$F6_MANC_SHA" main 2>/dev/null; then
    ok "F9 fixture: the merge-commit-merged tip IS an ancestor of main (-d succeeds, no -D) (F9)"
else
    bad "F9 fixture: the merge-commit-merged tip is NOT an ancestor of main — the shape is wrong (F9)"
fi
# The PR map backing both: MERGED, base main, headRefOid == the tip. The four
# special names stay absent, so they remain `redundant` and take only `-d`.
F6_PR_MAP="$FIX/f6-pr-map.json"
cat > "$F6_PR_MAP" <<JSON
[
  {"headRefName":"f6-merged","state":"MERGED","headRefOid":"$F6_MERGED_SHA","baseRefName":"main"},
  {"headRefName":"f6-manc","state":"MERGED","headRefOid":"$F6_MANC_SHA","baseRefName":"main"}
]
JSON
F6_REAL_GIT="$(command -v git)"
F6_WRAP="$FIX/f6-wrap"
mkdir -p "$F6_WRAP"
cat > "$F6_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double: intercept `git branch` and `git update-ref`. In `print` mode it
# dumps the argv (the paste-evaluation side); otherwise it appends the argv to
# GIT_WRAP_LOG (branch) or GIT_WRAP_REF_LOG (update-ref) and then delegates to
# the real git, so the execute path really deletes. The two logs are SEPARATE
# (F17): the plan prints only the `-d` line as a COMMAND and describes the
# force-delete fallback as a COMMENT, so plan ⇄ execute parity is over the `-d`
# surface, while GIT_WRAP_REF_LOG still captures the executed atomic swap.
REAL_GIT="${F6_REAL_GIT:?F6_REAL_GIT unset}"
case "$1" in
    branch|update-ref)
        if [ "${GIT_WRAP_MODE:-delegate}" = "print" ]; then
            printf '%s\000' "$@"
            printf '\000'
            exit 0
        fi
        if [ "$1" = "update-ref" ] && [ -n "${GIT_WRAP_REF_LOG:-}" ]; then
            LOG="$GIT_WRAP_REF_LOG"
        else
            LOG="${GIT_WRAP_LOG:?GIT_WRAP_LOG unset}"
        fi
        {
            printf '%s\000' "$@"
            printf '\000'
        } >>"$LOG"
        ;;
esac
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F6_WRAP/git"

run_script bash "$F6_SCRIPT" --repo "$F6_REPO" --scope local --pr-map-file "$F6_PR_MAP"
F6_PLAN_OUT="$OUT"
assert_eq "$RC" "0" "local paste-safety fixture: dry-run exits 0 (F6)"
# One `-d` per selected branch; the force-delete fallback for the SQUASH
# `merged` shape is advertised as a COMMENT only (F17). Counted separately so the
# test also pins that the force-delete stays CONFINED to `merged` and to the
# shape that needs it (F9), and (F12) that its primitive is the atomic
# `git update-ref -d`.
F6_PLAN_D_COUNT="$(grep -c '^  git branch -d --' <<<"$OUT" || true)"
F6_PLAN_EXEC_LINES="$(grep -c '^  git ' <<<"$OUT" || true)"
F6_PLAN_FORCE_COUNT="$(grep -c '^  git update-ref -d ' <<<"$OUT" || true)"
F6_PLAN_FORCE_CMT="$(grep -c '^  #   git update-ref -d refs/heads/f6-merged' <<<"$OUT" || true)"
assert_eq "$F6_PLAN_D_COUNT" "6" "the local plan prints one -d command per selected branch (4 redundant + 2 merged) (F6)"
assert_eq "$F6_PLAN_EXEC_LINES" "6" "the plan has EXACTLY ONE executable line per selected branch; the fallback is not a command (F17)"
assert_eq "$F6_PLAN_FORCE_COUNT" "0" "the plan prints NO executable update-ref line (the squash fallback is not a command) (F17)"
assert_eq "$F6_PLAN_FORCE_CMT" "1" "the plan prints the squash force-delete fallback as a COMMENT (F17)"
assert_contains "$OUT" 'git update-ref -d refs/heads/f6-merged' 'the squash merged class actually advertises its force-delete fallback (F6/F7)'
assert_contains "$OUT" '# class=redundant' 'the class annotation is still printed (F6)'
# ⛔ F9: the MERGE-COMMIT-merged shape takes EXACTLY ONE command (`-d`) — `-d`
# succeeds, so a printed `-D` would be a command execution never runs. Assert
# both shapes, so restoring the unconditional `-D` goes RED here.
F6_PLAN_MANC_D="$(grep -c '^  git branch -d -- f6-manc   # class=merged' <<<"$OUT" || true)"
F6_PLAN_MANC_FORCE="$(grep -c '^  git update-ref -d refs/heads/f6-manc' <<<"$OUT" || true)"
assert_eq "$F6_PLAN_MANC_D" "1" "the merge-commit-merged shape prints exactly one -d command (F9)"
assert_eq "$F6_PLAN_MANC_FORCE" "0" "the merge-commit-merged shape prints NO force-delete fallback (F9)"
assert_contains "$OUT" 'git branch -d -- f6-merged   # class=merged' 'the squash shape still prints its -d command (F9)'
assert_match "$OUT" '^  #   git update-ref -d refs/heads/f6-merged [0-9a-f]+   \[tip must still be [0-9a-f]+; checked-out branches are refused\]$' 'the squash shape advertises the atomic fallback as a COMMENT with the tip pin (F9/F12/F17)'
assert_contains "$OUT" 'if that refuses (squash-merged), --execute runs:' 'the comment names the squash-merged refusal that motivates the fallback (F17)'

# Evaluate each printed EXECUTABLE plan line with `git` stubbed to an argv
# dumper, writing NUL-delimited records (a ref name cannot contain NUL, so the
# encoding is exact). The trailing `# class=...` is a shell COMMENT; eval ignores
# it. The force-delete fallback is a COMMENT line (F17) and so is deliberately
# NOT evaluated here: the plan's executable surface is the `-d` line.
F6_PLAN_ARGV="$FIX/f6-plan.bin"
: > "$F6_PLAN_ARGV"
while IFS= read -r _f6_line; do
    [ -n "$_f6_line" ] || continue
    PATH="$F6_WRAP:$PATH" F6_REAL_GIT="$F6_REAL_GIT" GIT_WRAP_MODE=print \
        bash -c 'eval "$1"' _ "$_f6_line" >>"$F6_PLAN_ARGV" || true
done <<<"$(grep -E '^  git branch -[dD] --' <<<"$OUT" || true)"

# The execute path logs the SAME encoding from its real `git branch` invocations;
# the atomic swap is captured separately (F17).
F6_EXEC_ARGV="$FIX/f6-exec.bin"
F6_EXEC_REF_ARGV="$FIX/f6-exec-ref.bin"
: > "$F6_EXEC_ARGV"
: > "$F6_EXEC_REF_ARGV"
run_script env PATH="$F6_WRAP:$PATH" F6_REAL_GIT="$F6_REAL_GIT" GIT_WRAP_LOG="$F6_EXEC_ARGV" \
    GIT_WRAP_REF_LOG="$F6_EXEC_REF_ARGV" \
    bash "$F6_SCRIPT" --repo "$F6_REPO" --scope local --execute --pr-map-file "$F6_PR_MAP"
assert_eq "$RC" "0" "local paste-safety fixture: --execute exits 0 (F6)"
if [ -s "$F6_PLAN_ARGV" ] && cmp -s "$F6_PLAN_ARGV" "$F6_EXEC_ARGV"; then
    ok "evaluating the LOCAL printed plan's -d lines yields EXACTLY the executed -d argv (no \$(id) fired) (F6/F17)"
else
    bad "the LOCAL printed plan's -d lines do NOT re-parse to the executed -d argv (F6/F17)"
    echo "    plan argv:"
    od -c "$F6_PLAN_ARGV" | head -n 8
    echo "    exec argv:"
    od -c "$F6_EXEC_ARGV" | head -n 8
fi
# The annotation must NOT have entered the argv: every executed argv is exactly
# `branch -d -- <name>`. A stray `# class=...` argument would add a 5th element.
F6_BAD_ELEM="$(tr '\0' '\n' < "$F6_EXEC_ARGV" | grep -c 'class=' || true)"
assert_eq "$F6_BAD_ELEM" "0" "the class annotation stays OUTSIDE the quoted argv (F6)"
# ⛔ F9: the NUL-delimited argv is EXACT for BOTH merged shapes. The global `cmp`
# above pins plan == execute as a whole; these per-shape element counts pin each
# shape's argv, so a plan that emitted a spurious `-D` for the merge-commit shape
# goes RED even if the total happened to line up. A branch name cannot contain
# NUL, so `tr` + an anchored match is an exact element test.
F6_PLAN_MANC_N="$(tr '\0' '\n' < "$F6_PLAN_ARGV" | grep -c '^f6-manc$' || true)"
F6_EXEC_MANC_N="$(tr '\0' '\n' < "$F6_EXEC_ARGV" | grep -c '^f6-manc$' || true)"
assert_eq "$F6_PLAN_MANC_N" "1" "the plan's NUL argv names f6-manc exactly once (-d only, merge-commit shape) (F9)"
assert_eq "$F6_EXEC_MANC_N" "1" "the execute path's NUL argv names f6-manc exactly once (-d only, merge-commit shape) (F9)"
F6_PLAN_MERGED_N="$(tr '\0' '\n' < "$F6_PLAN_ARGV" | grep -c '^f6-merged$' || true)"
F6_EXEC_MERGED_N="$(tr '\0' '\n' < "$F6_EXEC_ARGV" | grep -c '^f6-merged$' || true)"
assert_eq "$F6_PLAN_MERGED_N" "1" "the plan's NUL argv names f6-merged once through -d (squash shape) (F9)"
assert_eq "$F6_EXEC_MERGED_N" "1" "the execute path's NUL argv names f6-merged once through -d (squash shape) (F9)"
# ⛔ F12: the squash shape's force-delete is the ATOMIC `git update-ref -d`, whose
# old-value argument is the classified tip. Since it is advertised as a COMMENT
# (F17), the plan side is pinned on the comment text and the EXECUTED argv is
# pinned on the separate ref log — so an edit back to `git branch -D` goes RED.
F6_PLAN_REF_CMT="$(grep -c '^  #   git update-ref -d refs/heads/f6-merged ' <<<"$F6_PLAN_OUT" || true)"
assert_eq "$F6_PLAN_REF_CMT" "1" "the plan's fallback COMMENT passes the ref to update-ref -d (squash shape) (F12/F17)"
assert_contains "$F6_PLAN_OUT" "[tip must still be $F6_MERGED_SHA; checked-out branches are refused]" 'the fallback COMMENT pins the classified tip (F12)'
F6_EXEC_REF_N="$(tr '\0' '\n' < "$F6_EXEC_REF_ARGV" | grep -c '^refs/heads/f6-merged$' || true)"
F6_EXEC_REF_TIP_N="$(tr '\0' '\n' < "$F6_EXEC_REF_ARGV" | grep -c "^$F6_MERGED_SHA$" || true)"
assert_eq "$F6_EXEC_REF_N" "1" "the execute path passes the ref to update-ref -d exactly once (squash shape) (F12)"
assert_eq "$F6_EXEC_REF_TIP_N" "1" "the execute path's update-ref -d carries the classified tip as the old value (F12)"

# ⛔ F17/F19: a VERBATIM PASTE of the printed local plan under `set -e` DOES NOT
# reap every branch — and the plan must SAY SO. For a SQUASH-merged branch the
# printed `git branch -d` REFUSES (its tip is not an ancestor of HEAD), so a
# paste stops at that line. Once the force-delete fallback stopped being printed
# as a SECOND executable command (F17), a single-branch fixture made "the paste
# attempts every advertised command" TRUE by construction — a tautology, because
# that ONE advertised command was the refusing `-d` (F19). The fixture is now
# MULTI-branch, with the refusing branch FIRST, so the paste attempts a STRICT
# SUBSET (only the `-d` that refuses) while `--execute` reaps all three. The
# plan's framing is asserted too: its header must not imply a paste-safe script;
# it must say `--execute` is the way and that the paste STOPS at the refusing -d.
F17_ORIGIN="$FIX/f17-origin.git"
F17_REPO="$FIX/f17-repo"
new_repo "$F17_REPO" "$F17_ORIGIN"
cd "$F17_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F17_SCRIPT="$F17_REPO/scripts/cleanup-stale-branches.sh"
echo base > f17.txt; git add f17.txt; old_commit "init"; git push -q origin main
F17_MAIN_SHA="$(git rev-parse main)"
F17_TREE="$(git rev-parse "$F17_MAIN_SHA^{tree}")"
F17_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F17_TREE" -p "$F17_MAIN_SHA" -m "f17-squash")"
# `f17-arefuse` sorts FIRST among refs/heads (for-each-ref is refname-ascending),
# so it is the plan's FIRST command and the paste aborts on it immediately.
# The other two are `redundant` (their tip IS main), so their `-d` succeeds.
git update-ref refs/heads/f17-arefuse "$F17_SHA"
git update-ref refs/heads/f17-bredun "$F17_MAIN_SHA"
git update-ref refs/heads/f17-credun "$F17_MAIN_SHA"
if git merge-base --is-ancestor "$F17_SHA" main 2>/dev/null; then
    bad "F17 fixture: the squash tip IS an ancestor of main — -d would succeed and no fallback is printed (F17)"
else
    ok "F17 fixture: the squash tip is NOT an ancestor of main (the -d refusal is reachable) (F17)"
fi
F17_MAP="$FIX/f17-pr-map.json"
cat > "$F17_MAP" <<JSON
[
  {"headRefName":"f17-arefuse","state":"MERGED","headRefOid":"$F17_SHA","baseRefName":"main"}
]
JSON
F17_REAL_GIT="$(command -v git)"
F17_WRAP="$FIX/f17-wrap"
mkdir -p "$F17_WRAP"
cat > "$F17_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F17): dumps/records `git branch` and `git update-ref` argv as
# NUL-delimited records. `print` mode dumps; otherwise the paste's real run is
# recorded BEFORE delegating, so the failing `-d` is still captured.
REAL_GIT="${F17_REAL_GIT:?F17_REAL_GIT unset}"
case "$1" in
    branch|update-ref)
        if [ "${GIT_WRAP_MODE:-delegate}" = "print" ]; then
            printf '%s\000' "$@"
            printf '\000'
            exit 0
        fi
        {
            printf '%s\000' "$@"
            printf '\000'
        } >>"${GIT_WRAP_LOG:?GIT_WRAP_LOG unset}"
        ;;
esac
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F17_WRAP/git"
run_script bash "$F17_SCRIPT" --repo "$F17_REPO" --scope local --pr-map-file "$F17_MAP"
F17_PLAN_OUT="$OUT"
assert_eq "$RC" "0" "F17: the multi-branch dry-run exits 0"
# The plan's executable surface: one `-d` per selected branch (3), NO executable
# update-ref line, and the squash fallback as a COMMENT (F17).
assert_eq "$(grep -c '^  git ' <<<"$F17_PLAN_OUT" || true)" "3" "F17: the plan has exactly ONE executable line per selected branch (3 -d commands)"
assert_eq "$(grep -c '^  git update-ref -d ' <<<"$F17_PLAN_OUT" || true)" "0" "F17: the plan has NO executable update-ref line (the fallback is a comment)"
assert_eq "$(grep -c '^  #   git update-ref -d refs/heads/f17-arefuse ' <<<"$F17_PLAN_OUT" || true)" "1" "F17: the plan carries the squash fallback as a COMMENT"
# ⛔ F19 framing: the header must not claim the block is a paste-safe script.
assert_contains "$F17_PLAN_OUT" "NOT a paste-safe script" "F19: the plan's header says plainly it is NOT a paste-safe script"
assert_contains "$F17_PLAN_OUT" "Run --execute to reap every selected branch" "F19: the plan names --execute as the way to reap every selected branch"
assert_contains "$F17_PLAN_OUT" "STOPS at that" "F19: the plan says a verbatim paste STOPS at the refusing -d"
# The plan's advertised executable argv (print-mode evaluation).
F17_ADVERTISED="$FIX/f17-advertised.bin"; : > "$F17_ADVERTISED"
while IFS= read -r _f17_line; do
    [ -n "$_f17_line" ] || continue
    PATH="$F17_WRAP:$PATH" F17_REAL_GIT="$F17_REAL_GIT" GIT_WRAP_MODE=print \
        bash -c 'eval "$1"' _ "$_f17_line" >>"$F17_ADVERTISED" || true
done <<<"$(grep -E '^  git ' <<<"$F17_PLAN_OUT" || true)"
F17_ADV_N="$(grep -c '^branch$' <<<"$(tr '\0' '\n' < "$F17_ADVERTISED")" || true)"
assert_eq "$F17_ADV_N" "3" "F17: the plan advertises THREE executable commands (one per selected branch)"
# The VERBATIM paste: the lines the plan prints as commands, run under `set -e`.
F17_PASTE_SCRIPT="$FIX/f17-paste.sh"
{
    printf '#!/usr/bin/env bash\nset -e\n'
    awk '/^Deletion commands that would run/ { grab=1; next } grab && /^$/ { exit } grab { print }' <<<"$F17_PLAN_OUT"
} > "$F17_PASTE_SCRIPT"
assert_contains "$(cat "$F17_PASTE_SCRIPT")" '#   git update-ref -d refs/heads/f17-arefuse' "F17: the pasted block carries the fallback as a COMMENT"
F17_PASTED="$FIX/f17-pasted.bin"; : > "$F17_PASTED"
cd "$F17_REPO"
run_script env PATH="$F17_WRAP:$PATH" F17_REAL_GIT="$F17_REAL_GIT" GIT_WRAP_LOG="$F17_PASTED" \
    bash "$F17_PASTE_SCRIPT"
F17_PASTE_RC="$RC"
# ⛔ F19: the paste's surface is a STRICT SUBSET of the plan's, and the refusal
# is the FIRST advertised command — so the paste reaps NOTHING, exactly what the
# header now says. A single-branch fixture could not show this (it made the
# attempted set trivially equal to the advertised set).
F17_PASTED_ARGS="$(tr '\0' '\n' < "$F17_PASTED")"
F17_PASTED_N="$(grep -c '^branch$' <<<"$F17_PASTED_ARGS" || true)"
assert_eq "$F17_PASTE_RC" "1" "F19: the paste's rc is 1 — the -d refusal is the documented outcome, not a silent success"
assert_eq "$F17_PASTED_N" "1" "F19: the paste STOPS at the first (refusing) -d and attempts exactly ONE of the plan's THREE commands"
if [ "$F17_PASTED_N" -lt "$F17_ADV_N" ]; then
    ok "F19: the paste's attempted commands are a STRICT SUBSET of the plan's advertised commands"
else
    bad "F19: the paste attempted every advertised command — the multi-branch fixture no longer shows the part-way stop"
fi
assert_contains "$F17_PASTED_ARGS" 'f17-arefuse' "F19: the one attempted -d is the branch whose -d refuses"
assert_not_contains "$F17_PASTED_ARGS" 'update-ref' "F17: the paste never runs the force-delete fallback (a comment cannot be pasted into doing something execution would refuse)"
for _f17br in f17-arefuse f17-bredun f17-credun; do
    if branch_exists "$_f17br"; then
        ok "F19: the paste left $_f17br in place (it reaped nothing)"
    else
        bad "F19: the paste deleted $_f17br — it reaped part of the plan despite the observed refusal"
    fi
done
unset _f17br
# ⛔ F21: the F19 header's promise is SHELL-CONDITIONAL, so pin BOTH modes. The
# F19 paste above ran under `set -e`; WITHOUT it the paste CONTINUES past the
# refusing `-d` and reaps the LATER `-d` lines too, leaving the refusing branch
# behind — the OPPOSITE of "reaps only the branches printed before it". The
# header now states that explicitly, and this run pins the second clause.
assert_contains "$F17_PLAN_OUT" "Under 'set -e'" "F21: the header names the 'set -e' case"
assert_contains "$F17_PLAN_OUT" "WITHOUT 'set -e'" "F21: the header names the no-'set -e' case"
F17_PASTE_NOE_SCRIPT="$FIX/f17-paste-noe.sh"
{
    printf '#!/usr/bin/env bash\n'
    awk '/^Deletion commands that would run/ { grab=1; next } grab && /^$/ { exit } grab { print }' <<<"$F17_PLAN_OUT"
} > "$F17_PASTE_NOE_SCRIPT"
if grep -q 'set -e' "$F17_PASTE_NOE_SCRIPT"; then
    bad "F21: the second paste script sets -e — it does not exercise the mode the header now describes"
else
    ok "F21: the second paste script does NOT set -e (the mode the header now describes)"
fi
F17_PASTED_NOE="$FIX/f17-pasted-noe.bin"; : > "$F17_PASTED_NOE"
cd "$F17_REPO"
run_script env PATH="$F17_WRAP:$PATH" F17_REAL_GIT="$F17_REAL_GIT" GIT_WRAP_LOG="$F17_PASTED_NOE" \
    bash "$F17_PASTE_NOE_SCRIPT"
assert_eq "$RC" "0" "F21: without set -e the paste CONTINUES past the refusal and exits 0"
F17_PASTED_NOE_ARGS="$(tr '\0' '\n' < "$F17_PASTED_NOE" || true)"
assert_eq "$(grep -c '^branch$' <<<"$F17_PASTED_NOE_ARGS" || true)" "3" "F21: without set -e the paste attempts EVERY advertised -d (the refusal no longer aborts it)"
assert_branch_exists f17-arefuse "F21: the refusing branch SURVIVES the no-'set -e' paste (its -d refused)"
assert_branch_absent f17-bredun "F21: the no-'set -e' paste reaps the LATER -d branch f17-bredun"
assert_branch_absent f17-credun "F21: the no-'set -e' paste reaps the LATER -d branch f17-credun"
# Restore the two later branches so the `--execute` assertions below still see
# the full three-branch fixture.
git update-ref refs/heads/f17-bredun "$F17_MAIN_SHA"
git update-ref refs/heads/f17-credun "$F17_MAIN_SHA"
# ⛔ AND `--execute` is the way: it falls back to the ATOMIC update-ref -d for the
# squash branch and reaps ALL THREE — which the paste could not.
run_script bash "$F17_SCRIPT" --repo "$F17_REPO" --scope local --execute --pr-map-file "$F17_MAP"
assert_eq "$RC" "0" "F19: --execute exits 0"
assert_contains "$OUT" "Deleted:   3" "F19: --execute reaps all three selected branches"
assert_contains "$OUT" "Failed:    0" "F19: --execute reports no failure"
for _f17br2 in f17-arefuse f17-bredun f17-credun; do
    assert_branch_absent "$_f17br2" "F19: --execute reaped $_f17br2 (the paste could not)"
done
unset _f17br2

cd "$REPO"
echo ""
echo "== 30. TWO pushurls REFUSE the sweep — git push origin reaches BOTH (R5-2) =="
# `git remote get-url --push origin` returns only the FIRST pushurl while
# `git push origin` pushes to EVERY one. Pre-fix the sweep verified the first
# mirror, deleted there, and reported `Deleted: 1` — leaving the second mirror's
# copy in place, and that copy is unverified (a delete authorised by the other
# mirror's evidence). With more than one push target there is no single URL the
# proof and the delete can both be pinned to, so the sweep must REFUSE and name
# each URL.
R52_A="$FIX/r52-a.git"
R52_M1="$FIX/r52-m1.git"
R52_M2="$FIX/r52-m2.git"
R52_REPO="$FIX/r52-repo"
new_repo "$R52_REPO" "$R52_A"
cd "$R52_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
R52_SCRIPT="$R52_REPO/scripts/cleanup-stale-branches.sh"
echo base > r52.txt; git add r52.txt; old_commit "init"; git push -q origin main
git checkout -q -b multi-doomed main
echo md > md.txt; git add md.txt; old_commit "multi-doomed"
git push -q -u origin multi-doomed
git checkout -q main
git merge -q --ff-only multi-doomed
git push -q origin main
R52_OID="$(git -C "$R52_A" rev-parse refs/heads/multi-doomed)"
# Two mirrors, BOTH holding the merged branch at the same OID.
git init -q --bare "$R52_M1"
git init -q --bare "$R52_M2"
git push -q "$R52_M1" refs/heads/multi-doomed:refs/heads/multi-doomed
git push -q "$R52_M2" refs/heads/multi-doomed:refs/heads/multi-doomed
git config --add remote.origin.pushurl "$R52_M1"
git config --add remote.origin.pushurl "$R52_M2"
if [ "$(git remote get-url --push --all origin | wc -l | tr -d ' ')" = "2" ]; then
    ok "two-pushurl fixture: origin resolves TWO push urls (R5-2)"
else
    bad "two-pushurl fixture: origin does not resolve two push urls — the fixture is wrong (R5-2)"
fi
if [ "$(git remote get-url --push origin)" = "$R52_M1" ]; then
    ok "two-pushurl fixture: the single-URL resolution returns only the FIRST mirror (R5-2)"
else
    bad "two-pushurl fixture: get-url --push did not return the first mirror (R5-2)"
fi
run_script bash "$R52_SCRIPT" --repo "$R52_REPO" --scope remote --execute
assert_eq "$RC" "1" "more than one push url REFUSES the sweep (R5-2)"
assert_contains "$OUT" "origin has 2 PUSH urls" "the refusal names the count of push urls (R5-2)"
assert_contains "$OUT" "$R52_M1" "the refusal names the first mirror (R5-2)"
assert_contains "$OUT" "$R52_M2" "the refusal names the second mirror (R5-2)"
assert_not_contains "$OUT" "Deleting origin/" "nothing is deleted when the push target is ambiguous (R5-2)"
for _m in "$R52_M1" "$R52_M2"; do
    if [ "$(git -C "$_m" rev-parse -q --verify refs/heads/multi-doomed || echo GONE)" = "$R52_OID" ]; then
        ok "mirror $(basename "$_m")'s multi-doomed SURVIVES the ambiguity refusal (R5-2)"
    else
        bad "mirror $(basename "$_m")'s multi-doomed was deleted — one mirror was never verified (R5-2)"
    fi
done
unset _m

cd "$REPO"
echo ""
echo "== 31. the host fold is LOCALE-PINNED — a Turkish fold cannot forge github.com (R5-3) =="
# `tr '[:upper:]' '[:lower:]'` is LOCALE-DEPENDENT. Under a Turkish locale it
# folds `İ` (U+0130) to `i`, so the foreign host `GİTHUB.COM` folded to exactly
# `github.com` and PASSED the exact-host guard — a foreign repository's PR map
# silently displacing this one's, the very defect the exact comparison exists to
# stop. The fold must be pinned `LC_ALL=C` (ASCII-only), which is all a host name
# needs.
#
# The triggering locale is not guaranteed to be installed on every machine, so
# the suite does not depend on it: a FAKE `tr` on PATH models the
# locale-dependent fold deterministically — it applies the Turkish `İ`→`i`
# mapping UNLESS its LC_ALL is exactly `C`, which is precisely the property the
# fix asserts. Every other locale is treated as hostile.
TRBIN="$FIX/fake-tr-bin"
mkdir -p "$TRBIN"
cat > "$TRBIN/tr" <<'FAKETR'
#!/usr/bin/env bash
# Models the locale-dependent case fold of the REAL tr. `LC_ALL=C` ⇒ ASCII-only
# fold (İ is untouched); ANY other value ⇒ the Turkish fold (İ→i). Every other
# invocation delegates to the real tr.
if [ "${1:-}" = "[:upper:]" ] && [ "${2:-}" = "[:lower:]" ] && [ "$#" -eq 2 ]; then
    if [ "${LC_ALL:-}" = "C" ]; then
        exec /usr/bin/tr '[:upper:]' '[:lower:]'
    fi
    /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/sed 's/İ/i/g'
    exit 0
fi
exec /usr/bin/tr "$@"
FAKETR
chmod +x "$TRBIN/tr"
# Prove the fake models the defect: under a non-C locale it forges github.com...
if [ "$(printf 'GİTHUB.COM' | env LC_ALL=tr_TR.UTF-8 PATH="$TRBIN:$PATH" tr '[:upper:]' '[:lower:]')" = "github.com" ]; then
    ok "fake-tr fixture: a non-C locale folds GİTHUB.COM to github.com (the defect is modelled) (R5-3)"
else
    bad "fake-tr fixture: the fake tr does not model the Turkish fold — the test cannot falsify (R5-3)"
fi
# ...and under LC_ALL=C it folds ASCII only.
if [ "$(printf 'GİTHUB.COM' | env LC_ALL=C PATH="$TRBIN:$PATH" tr '[:upper:]' '[:lower:]')" = "gİthub.com" ]; then
    ok "fake-tr fixture: LC_ALL=C folds ASCII only, leaving İ untouched (R5-3)"
else
    bad "fake-tr fixture: LC_ALL=C did not produce the ASCII-only fold (R5-3)"
fi
# A foreign host that folds to github.com ONLY under a hostile locale must be
# REFUSED: the pass must not read a foreign repository's PR map.
git -C "$REPO3" remote set-url origin 'https://GİTHUB.COM/example/example.git'
run_script env LC_ALL=tr_TR.UTF-8 PATH="$TRBIN:$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "1" "a host that folds to github.com only under a hostile locale is REFUSED (R5-3)"
assert_contains "$OUT" "no github.com origin" "the locale-folded host yields NO slug (R5-3)"
assert_not_contains "$OUT" "── SELECTED" "the locale-folded host classifies nothing (R5-3)"
# The intended ASCII case-insensitivity still works: an ALL-ASCII mixed-case
# host folds to github.com under the pin (and under any locale).
git -C "$REPO3" remote set-url origin 'https://GITHUB.COM/example/example.git'
run_script env LC_ALL=tr_TR.UTF-8 PATH="$TRBIN:$FAKEBIN:$PATH" FAKE_GH_MODE=ok bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "an ALL-ASCII mixed-case host still resolves under a hostile locale (R5-3)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'the ASCII mixed-case host still classifies (R5-3)'
# Restore the canonical github.com URL for §32.
git -C "$REPO3" remote set-url origin 'https://github.com/example/example.git'

cd "$REPO"
echo ""
echo "== 32. an scp-like origin with NO user still resolves github.com (R5-4) =="
# `[user@]host:path` was only recognised WITH a user, so `github.com:o/r.git`
# and `github.com:o/r` — both GENUINE github.com origins, which git hands to ssh —
# fell through to the bare-path branch. `${url%%/*}` then split on the `/` INSIDE
# the path, yielding host `github.com:o` (≠ github.com) and a single-segment
# path, so the origin was REFUSED and the whole local scope stood down.
# GIT_SSH_COMMAND=false keeps the fetch from attempting ssh (no network, fails
# fast); the origin URL string — all the parser reads — is unchanged.
git -C "$REPO3" remote set-url origin 'github.com:example/example.git'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok GIT_SSH_COMMAND=false bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "an scp-like origin with no user resolves the slug (R5-4)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'the no-user scp-like origin classifies normally (R5-4)'
git -C "$REPO3" remote set-url origin 'github.com:example/example'
run_script env PATH="$FAKEBIN:$PATH" FAKE_GH_MODE=ok GIT_SSH_COMMAND=false bash "$GH_SCRIPT" --scope local
assert_eq "$RC" "0" "an scp-like origin with no user and no .git resolves (R5-4)"
assert_match "$OUT" '^  delete +redundant +old-redundant$' 'the no-user, no-.git scp-like origin classifies (R5-4)'
# Restore the canonical github.com URL for any later use.
git -C "$REPO3" remote set-url origin 'https://github.com/example/example.git'

cd "$REPO"
echo ""
echo "== 33. the delete is pinned to the CLASSIFIED oid by git's own LEASE (F1) =="
# fetch=A, `pushInsteadOf A→B`, `insteadOf B→C`. The delete-time verification
# runs `git ls-remote <resolved push url>` — but ls-remote is a FETCH, so it
# applies `url.<base>.insteadOf` to the ALREADY-RESOLVED push url (B→C) and
# proves repo C's foo at the classified oid. `git push origin --delete` applies
# `pushInsteadOf` to origin's FETCH url (A→B) and does NOT then apply
# `insteadOf`, so it lands on repo B — whose foo is a DIFFERENT, UNMERGED commit
# that exists nowhere else. When the fetch and push targets differ git applies
# NO compare-and-swap: pre-fix the sweep reported `Deleted: 1 / Refused: 0`,
# rc=0, and B's commit was destroyed. The delete's `--force-with-lease` sends the
# classified oid as the expected old value through the SAME resolution as the
# delete, so B's receive-pack REFUSES.
F1L_A="$FIX/f1lease-a.git"
F1L_B="$FIX/f1lease-b.git"
F1L_C="$FIX/f1lease-c.git"
F1L_REPO="$FIX/f1lease-repo"
new_repo "$F1L_REPO" "$F1L_A"
cd "$F1L_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F1L_SCRIPT="$F1L_REPO/scripts/cleanup-stale-branches.sh"
echo base > f1l.txt; git add f1l.txt; old_commit "init"; git push -q origin main
# A's foo: merged into A's main, stale → a genuine candidate.
git checkout -q -b foo main
echo afoo > afoo.txt; git add afoo.txt; old_commit "foo-on-A"
git push -q -u origin foo
git checkout -q main
git merge -q --ff-only foo
git push -q origin main
F1L_A_OID="$(git -C "$F1L_A" rev-parse refs/heads/foo)"
# C: a MIRROR of A's foo (same oid) — so the fetch-side verification PASSES.
git init -q --bare "$F1L_C"
git push -q "$F1L_C" refs/heads/foo:refs/heads/foo
# B: foo holds a UNIQUE, UNMERGED commit that exists nowhere else.
git init -q --bare "$F1L_B"
git checkout -q -b b-foo main
echo dangerB > dangerB.txt; git add dangerB.txt; old_commit "foo-on-B"
F1L_B_OID="$(git rev-parse HEAD)"
git push -q "$F1L_B" refs/heads/b-foo:refs/heads/foo
git checkout -q main
if [ "$F1L_A_OID" != "$F1L_B_OID" ]; then
    ok "lease fixture: repo A's and repo B's foo differ (the divergence is real) (F1)"
else
    bad "lease fixture: A and B share one oid — the fixture does not exercise the divergence (F1)"
fi
# The rewrite chain: fetch stays A, push resolves to B, and B itself rewrites to
# C for any FETCH-side read of B.
git config "url.$F1L_B.pushInsteadOf" "$F1L_A"
git config "url.$F1L_C.insteadOf" "$F1L_B"
if [ "$(git remote get-url --push origin)" = "$F1L_B" ]; then
    ok "lease fixture: get-url --push resolves origin's push url to repo B (F1)"
else
    bad "lease fixture: get-url --push did not resolve to B — the fixture is wrong (F1)"
fi
# Prove the fixture models the divergence: the verification target (`ls-remote
# B`) is re-rewritten to C, so it reads C's oid — the classified one — and
# PASSES. This is exactly the false proof the lease must survive.
F1L_LS_B="$(git ls-remote "$F1L_B" refs/heads/foo 2>/dev/null | awk '{print $1}')"
if [ "$F1L_LS_B" = "$F1L_A_OID" ]; then
    ok "lease fixture: the fetch-side verification reads repo C and PASSES (the false proof) (F1)"
else
    bad "lease fixture: ls-remote B did not read C's oid ($F1L_LS_B vs $F1L_A_OID) — the fixture is wrong (F1)"
fi
run_script bash "$F1L_SCRIPT" --repo "$F1L_REPO" --scope remote --execute
assert_eq "$RC" "1" "the A→B→C divergence REFUSES the delete (F1)"
assert_contains "$OUT" "REFUSING to delete origin/foo" "the lease rejection is a REFUSAL, not a failure (F1)"
assert_contains "$OUT" "stale info" "the refusal names the lease rejection (F1)"
assert_contains "$OUT" "Deleted: 0" "nothing was deleted (F1)"
assert_contains "$OUT" "Refused: 1" "the lease refusal is counted once (F1)"
assert_contains "$OUT" "Failed:  0" "a lease refusal is NOT also counted as a failure (F1)"
if [ "$(git -C "$F1L_B" rev-parse -q --verify refs/heads/foo || echo GONE)" = "$F1L_B_OID" ]; then
    ok "repo B's unique UNMERGED foo SURVIVES (the lease pinned the delete) (F1)"
else
    bad "repo B's foo was DELETED — data loss (F1)"
fi

cd "$REPO"
echo ""
echo "== 34. the MERGE premise is re-proved against origin's REAL main (F2) =="
# The classification is `git branch -r --merged origin/main` — the LOCAL tracking
# ref. A NARROWED POSITIVE refspec may omit `refs/heads/main`, so
# `git fetch origin --prune` exits 0 and leaves origin/main STALE; if main has
# since been REWRITTEN, origin/foo still looks merged. The delete-time target
# verification does NOT close this: it proves origin's real foo equals the
# TRACKED oid, never that the oid is in real main. Pre-fix the sweep destroyed
# the only copy of foo's commits.
F2M_ORIGIN="$FIX/f2main-origin.git"
F2M_REPO="$FIX/f2main-repo"
new_repo "$F2M_REPO" "$F2M_ORIGIN"
cd "$F2M_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F2M_SCRIPT="$F2M_REPO/scripts/cleanup-stale-branches.sh"
echo base > f2m.txt; git add f2m.txt; old_commit "init"; git push -q origin main
git checkout -q -b foo main
echo f > f.txt; git add f.txt; old_commit "f"
git push -q -u origin foo
git checkout -q main
git merge -q --ff-only foo
echo m > m.txt; git add m.txt; old_commit "m"
git push -q origin main
F2M_F_OID="$(git rev-parse foo)"
F2M_M_OID="$(git rev-parse main)"
# Narrowed positive refspec: only foo is refreshed, so origin/main stays at M.
git config --replace-all remote.origin.fetch '+refs/heads/foo:refs/remotes/origin/foo'
git fetch origin --prune --quiet
if [ "$(git rev-parse origin/main)" = "$F2M_M_OID" ] && [ "$(git rev-parse origin/foo)" = "$F2M_F_OID" ]; then
    ok "real-main fixture: origin/main is STALE at M and origin/foo is current (F2)"
else
    bad "real-main fixture: refs not as expected — the fixture is wrong (F2)"
fi
# Rewrite the BARE's main to a root that does NOT contain F. It is created in
# the BARE ONLY, so the swept checkout does not have the object: the merge proof
# must fail on an UNKNOWN object too, and an unknown object is a REFUSAL.
F2M_TREE="$(printf '' | git -C "$F2M_ORIGIN" mktree)"
F2M_G="$(GIT_AUTHOR_NAME="Test Runner" GIT_AUTHOR_EMAIL=test@test.test \
    GIT_COMMITTER_NAME="Test Runner" GIT_COMMITTER_EMAIL=test@test.test \
    GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git -C "$F2M_ORIGIN" commit-tree "$F2M_TREE" -m root-rewrite)"
git -C "$F2M_ORIGIN" update-ref refs/heads/main "$F2M_G"
F2M_REAL_MAIN="$(git -C "$F2M_ORIGIN" rev-parse refs/heads/main)"
if [ "$F2M_REAL_MAIN" != "$F2M_M_OID" ]; then
    ok "real-main fixture: origin's REAL main was rewritten (F2)"
else
    bad "real-main fixture: origin's real main did not change (F2)"
fi
if ! git cat-file -e "$F2M_G" 2>/dev/null; then
    ok "real-main fixture: the rewritten main commit is UNKNOWN in the swept checkout (F2)"
else
    bad "real-main fixture: the rewritten commit is locally present — the unknown-object path is not exercised (F2)"
fi
run_script bash "$F2M_SCRIPT" --repo "$F2M_REPO" --scope remote --execute
assert_eq "$RC" "1" "a stale origin/main REFUSES the delete (F2)"
assert_contains "$OUT" "REFUSING to delete origin/foo" "the stale-main refusal is named (F2)"
assert_contains "$OUT" "does NOT provably contain the classified tip" "the refusal names the failed merge proof (F2)"
assert_contains "$OUT" "Refused: 1" "the stale-main refusal is counted (F2)"
assert_contains "$OUT" "Deleted: 0" "nothing was deleted against a stale main (F2)"
if [ "$(git -C "$F2M_ORIGIN" rev-parse -q --verify refs/heads/foo || echo GONE)" = "$F2M_F_OID" ]; then
    ok "origin's foo SURVIVES the stale-main sweep (F2)"
else
    bad "origin's foo was deleted against a stale main — data loss (F2)"
fi
# Happy path: put the REAL main back on the line that CONTAINS the tip. The
# re-proof must NOT become a blanket refusal.
git push -q --force origin "$F2M_M_OID:refs/heads/main"
run_script bash "$F2M_SCRIPT" --repo "$F2M_REPO" --scope remote --execute
assert_eq "$RC" "0" "a real main containing the tip does NOT refuse (F2)"
assert_contains "$OUT" "Deleted: 1" "the ordinary happy path still deletes (F2)"
if [ "$(git -C "$F2M_ORIGIN" rev-parse -q --verify refs/heads/foo || echo GONE)" = "GONE" ]; then
    ok "a branch provably merged into real main IS deleted (F2)"
else
    bad "the happy path no longer deletes (F2)"
fi

cd "$REPO"
echo ""
echo "== 35. a non-'stale info' push failure makes the sweep exit NON-ZERO (F2) =="
# A push can fail for reasons OTHER than the lease — a protected ref, an ambiguous
# target, a transport failure. The sweep counts those as `Failed` and must make the
# EXIT STATUS non-zero: the exit status is the only signal a scheduler reads, and
# `Failed: 1` with rc=0 reports "the sweep succeeded" while a selected branch was
# never reaped. `receive.denyDeletes` makes the bare reject every deletion with
# `deletion prohibited` (no `stale info`), so the push takes the generic-FAILED arm.
F2X_ORIGIN="$FIX/f2x-origin.git"
F2X_REPO="$FIX/f2x-repo"
new_repo "$F2X_REPO" "$F2X_ORIGIN"
git -C "$F2X_ORIGIN" config receive.denyDeletes true
cd "$F2X_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F2X_SCRIPT="$F2X_REPO/scripts/cleanup-stale-branches.sh"
echo base > f2x.txt; git add f2x.txt; old_commit "init"; git push -q origin main
git checkout -q -b protected-doomed main
echo pd > pd.txt; git add pd.txt; old_commit "protected-doomed"
git push -q -u origin protected-doomed
git checkout -q main
git merge -q --ff-only protected-doomed
git push -q origin main
F2X_OID="$(git -C "$F2X_ORIGIN" rev-parse refs/heads/protected-doomed)"
run_script bash "$F2X_SCRIPT" --repo "$F2X_REPO" --scope remote --execute
assert_eq "$RC" "1" "a non-lease push failure exits non-zero (F2)"
assert_contains "$OUT" "Failed:  1" "the failed delete is counted (F2)"
assert_contains "$OUT" "Deleted: 0" "nothing was deleted (F2)"
assert_contains "$OUT" "❌ failed" "the push is reported as failed, not refused (F2)"
assert_not_contains "$OUT" "stale info" "the failure is NOT a lease refusal (F2)"
if [ "$(git -C "$F2X_ORIGIN" rev-parse -q --verify refs/heads/protected-doomed || echo GONE)" = "$F2X_OID" ]; then
    ok "the protected branch SURVIVES (denyDeletes) (F2)"
else
    bad "the protected branch was deleted despite denyDeletes (F2)"
fi

cd "$REPO"
echo ""
echo "== 36. the local force-delete is the ATOMIC update-ref swap — a tip that MOVED is not deleted (F12) =="
# The `merged` gate proves tip == headRefOid at CLASSIFICATION time, and the
# delete must not rest on a check-then-act pre-check: the read and the delete are
# two separate git processes, so a commit landing BETWEEN them is invisible to
# the check. This fixture races exactly that window — a git wrapper answers sq's
# delete-time `rev-parse` with the CLASSIFIED tip B AFTER advancing
# refs/heads/sq to the child R, so the pre-check passes on a STALE value. Only
# `git update-ref -d <ref> <old>` (git compares and deletes in ONE operation)
# can prevent the loss; the remote leg closes the same class with
# --force-with-lease.
F10R_ORIGIN="$FIX/f10r-origin.git"
F10R_REPO="$FIX/f10r-repo"
new_repo "$F10R_REPO" "$F10R_ORIGIN"
cd "$F10R_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F10R_SCRIPT="$F10R_REPO/scripts/cleanup-stale-branches.sh"
echo base > f10r.txt; git add f10r.txt; old_commit "init"; git push -q origin main
# sq: squash-shaped (tip NOT an ancestor of main), no upstream, MERGED PR.
git checkout -q -b sq main
echo sq > sq.txt; git add sq.txt; old_commit "sq-content"
F10R_B="$(git rev-parse HEAD)"
git checkout -q main
# ok-sq: the SAME shape but never raced — the positive control proving the
# atomic swap still reaps a normal squash merge.
git checkout -q -b ok-sq main
echo ok > oksq.txt; git add oksq.txt; old_commit "ok-sq-content"
F10R_OK="$(git rev-parse HEAD)"
git checkout -q main
# R: a child of B reachable ONLY from sq. Without the atomic swap, the delete
# destroys the only ref to R (and drops the reflog with it).
F10R_TREE="$(git rev-parse "$F10R_B^{tree}")"
F10R_R="$(GIT_AUTHOR_DATE="2020-01-02T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-02T00:00:00 +0000" \
    git commit-tree "$F10R_TREE" -p "$F10R_B" -m "post-classification commit")"
F10R_PR_MAP="$FIX/f10r-pr-map.json"
cat > "$F10R_PR_MAP" <<JSON
[
  {"headRefName":"sq","state":"MERGED","headRefOid":"$F10R_B","baseRefName":"main"},
  {"headRefName":"ok-sq","state":"MERGED","headRefOid":"$F10R_OK","baseRefName":"main"}
]
JSON
F10R_REAL_GIT="$(command -v git)"
F10R_WRAP="$FIX/f10r-wrap"
F10R_SENT="$FIX/f10r-advanced.sentinel"
F10R_UR_LOG="$FIX/f10r-update-ref.log"
rm -f "$F10R_SENT" "$F10R_UR_LOG"
mkdir -p "$F10R_WRAP"
cat > "$F10R_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F12): the delete-time pre-check is answered with the CLASSIFIED
# tip B AFTER refs/heads/sq is advanced to the child R, so the check-then-act
# pre-check cannot see the move and only `git update-ref -d <ref> <old>` can.
# Every `update-ref` invocation is logged as one TAB-separated record so the
# test can pin the atomic primitive AND its old-value argument; every other call
# delegates to the real git.
REAL_GIT="${F10R_REAL_GIT:?F10R_REAL_GIT unset}"
if [ "$1" = "rev-parse" ]; then
    for _a in "$@"; do
        if [ "$_a" = "refs/heads/${F10R_BRANCH:?F10R_BRANCH unset}" ]; then
            if [ ! -e "${F10R_SENTINEL:?F10R_SENTINEL unset}" ]; then
                : >"$F10R_SENTINEL"
                _old="$("$REAL_GIT" rev-parse "refs/heads/$F10R_BRANCH")"
                "$REAL_GIT" update-ref "refs/heads/$F10R_BRANCH" "${F10R_R_SHA:?F10R_R_SHA unset}"
                printf '%s\n' "$_old"
                exit 0
            fi
        fi
    done
fi
if [ "$1" = "update-ref" ]; then
    { printf '%s\t' "$@"; printf '\n'; } >>"${GIT_WRAP_LOG:?GIT_WRAP_LOG unset}"
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F10R_WRAP/git"
run_script env PATH="$F10R_WRAP:$PATH" F10R_REAL_GIT="$F10R_REAL_GIT" \
    F10R_BRANCH="sq" F10R_R_SHA="$F10R_R" F10R_SENTINEL="$F10R_SENT" \
    GIT_WRAP_LOG="$F10R_UR_LOG" \
    bash "$F10R_SCRIPT" --repo "$F10R_REPO" --scope local --execute --pr-map-file "$F10R_PR_MAP"
# Non-zero: a moved tip was NOT reaped, so the sweep must not claim success.
assert_eq "$RC" "1" "a tip that moves under the sweep exits non-zero (F12)"
assert_match "$OUT" '^  moved +merged +sq ' "the advanced branch is reported as moved (F12)"
assert_contains "$OUT" "tip advanced $F10R_B -> $F10R_R" "the move names the old and new oids (F12)"
assert_contains "$OUT" "Moved:     1" "the moved branch is counted in the summary (F12)"
assert_no_match "$OUT" '^  deleted +merged +sq ' "the moved branch is NOT reported deleted (F12)"
if [ "$(git -C "$F10R_REPO" rev-parse -q --verify refs/heads/sq || echo GONE)" = "$F10R_R" ]; then
    ok "the ADVANCED branch SURVIVES at the new tip R (no data loss) (F12)"
else
    bad "the advanced branch was deleted or moved — DATA LOSS (F12)"
fi
# ⛔ THE ATOMIC PRIMITIVE IS PINNED: the sq delete must have gone through
# `git update-ref -d refs/heads/sq <B>` — the CLASSIFIED tip as the OLD value —
# and not `git branch -D`. Rework the delete path back to `-D` and this record
# never appears, so this assertion goes RED.
F10R_UR_FLAT="$(cat "$F10R_UR_LOG" 2>/dev/null || true)"
assert_contains "$F10R_UR_FLAT" \
    "$(printf 'update-ref\t-d\trefs/heads/sq\t%s' "$F10R_B")" \
    "the sq delete went through git update-ref -d with the CLASSIFIED tip as its old value (F12)"
# Positive control: the un-raced squash branch is still reaped through the SAME
# atomic swap.
assert_branch_absent ok-sq "the normal squash branch is still reaped via update-ref (F12)"
assert_contains "$OUT" "via update-ref -d: squash-merged PR" "the normal squash force-delete path is unchanged (F12)"
assert_contains "$F10R_UR_FLAT" \
    "$(printf 'update-ref\t-d\trefs/heads/ok-sq\t%s' "$F10R_OK")" \
    "the un-raced squash delete also went through git update-ref -d (F12)"

cd "$REPO"
echo ""
echo "== 36b. the force-delete path REFUSES a branch that becomes CHECKED OUT (update-ref -d has no -D guard) (F12a) =="
# `git branch -D` refuses a checked-out branch; `git update-ref -d` does NOT
# (verified: it removes the checked-out branch and leaves HEAD dangling). The
# classification's `worktree:` keep rule is not a guard across the window, so
# the delete path re-enumerates the worktrees itself. Here the branch is checked
# out in a LINKED WORKTREE after classification and just before the swap; the
# delete must REFUSE and the branch must survive.
F12A_ORIGIN="$FIX/f12a-origin.git"
F12A_REPO="$FIX/f12a-repo"
new_repo "$F12A_REPO" "$F12A_ORIGIN"
cd "$F12A_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F12A_SCRIPT="$F12A_REPO/scripts/cleanup-stale-branches.sh"
echo base > f12a.txt; git add f12a.txt; old_commit "init"; git push -q origin main
F12A_MAIN_SHA="$(git rev-parse main)"
F12A_TREE="$(git rev-parse "$F12A_MAIN_SHA^{tree}")"
F12A_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F12A_TREE" -p "$F12A_MAIN_SHA" -m "wt-race")"
git update-ref refs/heads/wt-race "$F12A_SHA"
F12A_MAP="$FIX/f12a-pr-map.json"
cat > "$F12A_MAP" <<JSON
[
  {"headRefName":"wt-race","state":"MERGED","headRefOid":"$F12A_SHA","baseRefName":"main"}
]
JSON
F12A_REAL_GIT="$(command -v git)"
F12A_WRAP="$FIX/f12a-wrap"
F12A_SENT="$FIX/f12a-checked-out.sentinel"
rm -f "$F12A_SENT"
mkdir -p "$F12A_WRAP"
cat > "$F12A_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F12a): when the delete pre-check reads the target branch, check it
# out in a LINKED WORKTREE first — the window between classification and the
# atomic swap. Every call then delegates to the real git.
REAL_GIT="${F12A_REAL_GIT:?F12A_REAL_GIT unset}"
if [ "$1" = "rev-parse" ]; then
    for _a in "$@"; do
        if [ "$_a" = "refs/heads/${F12A_BRANCH:?F12A_BRANCH unset}" ]; then
            if [ ! -e "${F12A_SENTINEL:?F12A_SENTINEL unset}" ]; then
                : >"$F12A_SENTINEL"
                "$REAL_GIT" worktree add -q "${F12A_WT_DIR:?F12A_WT_DIR unset}" "$F12A_BRANCH" >/dev/null 2>&1 || true
            fi
        fi
    done
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F12A_WRAP/git"
run_script env PATH="$F12A_WRAP:$PATH" F12A_REAL_GIT="$F12A_REAL_GIT" \
    F12A_BRANCH="wt-race" F12A_SENTINEL="$F12A_SENT" F12A_WT_DIR="$FIX/f12a-wt" \
    bash "$F12A_SCRIPT" --repo "$F12A_REPO" --scope local --execute --pr-map-file "$F12A_MAP"
assert_eq "$RC" "1" "a branch that becomes checked out fails the sweep (F12a)"
assert_match "$OUT" '^  failed +merged +wt-race ' "the checked-out branch is reported FAILED, not deleted (F12a)"
assert_no_match "$OUT" '^  deleted +merged +wt-race ' "the checked-out branch is NOT reported deleted (F12a)"
if git -C "$F12A_REPO" rev-parse -q --verify refs/heads/wt-race >/dev/null 2>&1; then
    ok "the checked-out branch SURVIVES (no dangling HEAD / broken worktree) (F12a)"
else
    bad "the checked-out branch was DELETED despite being checked out (F12a)"
fi

cd "$REPO"
echo ""
echo "== 37. the local plan ⇄ execute parity holds for BOTH refs git branch -d tests (F11) =="
# `git branch -d` tests the branch's UPSTREAM when it has one, else HEAD — never
# `origin/main`. The pre-F11 predictor tested `origin/main`, which mispredicted
# BOTH ways: (A) a merge-commit branch with HEAD off main printed only `-d`
# while execute ran `-D` (UNDER-describes); (B) a branch tracking origin printed
# a spurious `-D` while execute ran only `-d` (OVER-describes). Each shape gets
# its own fixture, and each asserts plan ⇄ execute parity under the SAME
# NUL-delimited argv comparison section 29d uses. Restore the origin/main-only
# predicate and the `cmp` below goes RED in the corresponding fixture.
F11_WRAP="$FIX/f11-wrap"
F11_REAL_GIT="$(command -v git)"
mkdir -p "$F11_WRAP"
cat > "$F11_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F11): dumps the `git branch` / `git update-ref` argv as
# NUL-delimited records in `print` mode; otherwise appends them to GIT_WRAP_LOG
# (branch) or GIT_WRAP_REF_LOG (update-ref) and delegates to the real git, so the
# execute path really deletes. The two logs are SEPARATE (F17): the plan prints
# only the `-d` line as a COMMAND and describes the squash force-delete fallback
# as a COMMENT, so plan ⇄ execute parity is over the `-d` surface.
REAL_GIT="${F11_REAL_GIT:?F11_REAL_GIT unset}"
case "$1" in
    branch|update-ref)
        if [ "${GIT_WRAP_MODE:-delegate}" = "print" ]; then
            printf '%s\000' "$@"
            printf '\000'
            exit 0
        fi
        if [ "$1" = "update-ref" ] && [ -n "${GIT_WRAP_REF_LOG:-}" ]; then
            LOG="$GIT_WRAP_REF_LOG"
        else
            LOG="${GIT_WRAP_LOG:?GIT_WRAP_LOG unset}"
        fi
        {
            printf '%s\000' "$@"
            printf '\000'
        } >>"$LOG"
        ;;
esac
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F11_WRAP/git"

# ── (A) HEAD is NOT main: a merge-commit-merged branch needs -D, and the plan
#        must say so (the pre-F11 plan printed only -d here).
F11A_ORIGIN="$FIX/f11a-origin.git"
F11A_REPO="$FIX/f11a-repo"
new_repo "$F11A_REPO" "$F11A_ORIGIN"
cd "$F11A_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F11A_SCRIPT="$F11A_REPO/scripts/cleanup-stale-branches.sh"
echo base > f11a.txt; git add f11a.txt; old_commit "init"; git push -q origin main
F11A_BASE="$(git rev-parse main)"
git checkout -q -b m-anc main
echo ma > ma.txt; git add ma.txt; old_commit "m-anc-content"
F11A_MANC="$(git rev-parse HEAD)"
git checkout -q main
git merge -q --no-ff -m "merge m-anc" m-anc
git push -q origin main
# HEAD to an OLD commit that does NOT contain m-anc. `-d` tests HEAD, so it will
# REFUSE and execute will need `-D`; the plan must predict that.
git checkout -q -b detour "$F11A_BASE"
if git merge-base --is-ancestor "$F11A_MANC" HEAD 2>/dev/null; then
    bad "F11A fixture: HEAD contains m-anc — -d would not refuse (shape wrong) (F11)"
else
    ok "F11A fixture: HEAD does not contain m-anc, so -d refuses and -D is required (F11)"
fi
F11A_MAP="$FIX/f11a-pr-map.json"
cat > "$F11A_MAP" <<JSON
[
  {"headRefName":"m-anc","state":"MERGED","headRefOid":"$F11A_MANC","baseRefName":"main"}
]
JSON
run_script env PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_MODE=print \
    bash "$F11A_SCRIPT" --repo "$F11A_REPO" --scope local --pr-map-file "$F11A_MAP"
F11A_PLAN_OUT="$OUT"
assert_eq "$RC" "0" "F11A: dry-run exits 0"
assert_contains "$F11A_PLAN_OUT" 'git branch -d -- m-anc   # class=merged' "F11A: the plan prints the -d command (F11)"
assert_match "$F11A_PLAN_OUT" '^  #   git update-ref -d refs/heads/m-anc [0-9a-f]+   \[tip must still be [0-9a-f]+; checked-out branches are refused\]$' "F11A: the plan advertises the force-delete fallback as a COMMENT because -d will test HEAD, not origin/main (F11/F17)"
assert_contains "$F11A_PLAN_OUT" 'if that refuses (squash-merged), --execute runs:' "F11A: the fallback COMMENT names the squash-merged refusal (F17)"
assert_eq "$(grep -c '^  git ' <<<"$F11A_PLAN_OUT" || true)" "1" "F11A: the plan has exactly ONE executable line (the fallback is a comment) (F17)"
F11A_PLAN="$FIX/f11a-plan.bin"; : > "$F11A_PLAN"
while IFS= read -r _f11a_line; do
    [ -n "$_f11a_line" ] || continue
    PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_MODE=print \
        bash -c 'eval "$1"' _ "$_f11a_line" >>"$F11A_PLAN" || true
done <<<"$(grep -E '^  git branch -[dD] --' <<<"$F11A_PLAN_OUT" || true)"
F11A_EXEC="$FIX/f11a-exec.bin"; : > "$F11A_EXEC"
F11A_EXEC_REF="$FIX/f11a-exec-ref.bin"; : > "$F11A_EXEC_REF"
run_script env PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_LOG="$F11A_EXEC" \
    GIT_WRAP_REF_LOG="$F11A_EXEC_REF" \
    bash "$F11A_SCRIPT" --repo "$F11A_REPO" --scope local --execute --pr-map-file "$F11A_MAP"
assert_eq "$RC" "0" "F11A: --execute exits 0"
if [ -s "$F11A_PLAN" ] && cmp -s "$F11A_PLAN" "$F11A_EXEC"; then
    ok "F11A: plan ⇄ execute -d argv parity with HEAD off main (merge-commit needs the fallback) (F11/F17)"
else
    bad "F11A: plan ⇄ execute -d argv DIVERGE with HEAD off main (F11/F17)"
    echo "    plan argv:"; od -c "$F11A_PLAN" | head -n 6
    echo "    exec argv:"; od -c "$F11A_EXEC" | head -n 6
fi
assert_contains "$(tr '\0' '\n' < "$F11A_EXEC_REF")" 'refs/heads/m-anc' "F11A: execute ran the atomic update-ref -d fallback for m-anc (F11)"
assert_branch_absent m-anc "F11A: the merge-commit branch is reaped via the force-delete fallback (F11)"

# ── (B) the branch tracks origin: `-d` tests the UPSTREAM, so the plan must NOT
#        print a spurious -D (the pre-F11 plan did).
F11B_ORIGIN="$FIX/f11b-origin.git"
F11B_REPO="$FIX/f11b-repo"
new_repo "$F11B_REPO" "$F11B_ORIGIN"
cd "$F11B_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F11B_SCRIPT="$F11B_REPO/scripts/cleanup-stale-branches.sh"
echo base > f11b.txt; git add f11b.txt; old_commit "init"; git push -q origin main
git checkout -q -b sq main
echo sq > sq.txt; git add sq.txt; old_commit "sq-content"
F11B_SQ="$(git rev-parse HEAD)"
git push -q -u origin sq
git checkout -q main
# origin/main does NOT contain sq's tip; `-d` tests origin/sq (== the tip) and
# SUCCEEDS, so execute never runs -D.
F11B_MAP="$FIX/f11b-pr-map.json"
cat > "$F11B_MAP" <<JSON
[
  {"headRefName":"sq","state":"MERGED","headRefOid":"$F11B_SQ","baseRefName":"main"}
]
JSON
run_script env PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_MODE=print \
    bash "$F11B_SCRIPT" --repo "$F11B_REPO" --scope local --pr-map-file "$F11B_MAP"
F11B_PLAN_OUT="$OUT"
assert_eq "$RC" "0" "F11B: dry-run exits 0"
assert_contains "$F11B_PLAN_OUT" 'git branch -d -- sq   # class=merged' "F11B: the plan prints the -d command (F11)"
assert_not_contains "$F11B_PLAN_OUT" 'git update-ref -d refs/heads/sq' "F11B: the plan prints NO spurious force-delete for an upstream-comparison branch (F11)"
assert_eq "$(grep -c '^  git ' <<<"$F11B_PLAN_OUT" || true)" "1" "F11B: the plan has exactly ONE executable line (F17)"
F11B_PLAN="$FIX/f11b-plan.bin"; : > "$F11B_PLAN"
while IFS= read -r _f11b_line; do
    [ -n "$_f11b_line" ] || continue
    PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_MODE=print \
        bash -c 'eval "$1"' _ "$_f11b_line" >>"$F11B_PLAN" || true
done <<<"$(grep -E '^  git branch -[dD] --' <<<"$F11B_PLAN_OUT" || true)"
F11B_EXEC="$FIX/f11b-exec.bin"; : > "$F11B_EXEC"
F11B_EXEC_REF="$FIX/f11b-exec-ref.bin"; : > "$F11B_EXEC_REF"
run_script env PATH="$F11_WRAP:$PATH" F11_REAL_GIT="$F11_REAL_GIT" GIT_WRAP_LOG="$F11B_EXEC" \
    GIT_WRAP_REF_LOG="$F11B_EXEC_REF" \
    bash "$F11B_SCRIPT" --repo "$F11B_REPO" --scope local --execute --pr-map-file "$F11B_MAP"
assert_eq "$RC" "0" "F11B: --execute exits 0"
if [ -s "$F11B_PLAN" ] && cmp -s "$F11B_PLAN" "$F11B_EXEC"; then
    ok "F11B: plan ⇄ execute -d argv parity with an upstream comparison ref (F11/F17)"
else
    bad "F11B: plan ⇄ execute -d argv DIVERGE with an upstream comparison ref (F11/F17)"
    echo "    plan argv:"; od -c "$F11B_PLAN" | head -n 6
    echo "    exec argv:"; od -c "$F11B_EXEC" | head -n 6
fi
assert_eq "$([ -s "$F11B_EXEC_REF" ] && echo nonempty || echo empty)" "empty" "F11B: execute ran NO atomic fallback for an upstream-comparison branch (F11)"
assert_branch_absent sq "F11B: the upstream-tracking squash branch is reaped via -d (F11)"

cd "$REPO"
echo ""
echo "== 38. the remote scope skips the origin/HEAD SYMREF, not every origin/HEAD* branch (F13) =="
# `git branch -r` renders the symref as `origin/HEAD -> origin/main`, and the
# old skip was the glob `origin/HEAD*`, which ALSO swallowed every real remote
# branch whose name merely BEGINS with `HEAD` (`origin/HEADfoo`) — no selection
# line, no keep line: a SILENT skip, contradicting the remote scope's rule that
# non-candidates are reported. Match the rendered symref instead (a space is
# illegal in a ref name, so `origin/HEAD -> ` can never be a real branch).
F13_ORIGIN="$FIX/f13-origin.git"
F13_REPO="$FIX/f13-repo"
new_repo "$F13_REPO" "$F13_ORIGIN"
cd "$F13_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F13_SCRIPT="$F13_REPO/scripts/cleanup-stale-branches.sh"
echo base > f13.txt; git add f13.txt; old_commit "init"; git push -q origin main
git checkout -q -b doomed main
echo d > d.txt; git add d.txt; old_commit "doomed"
git push -q origin doomed
git checkout -q main
git merge -q --ff-only doomed
git checkout -q -b HEADfoo main
echo h > h.txt; git add h.txt; old_commit "HEADfoo"
git push -q origin HEADfoo
git checkout -q main
git merge -q --ff-only HEADfoo
git push -q origin main
git fetch -q origin
git remote set-head origin main
if git rev-parse --verify -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
    ok "F13 fixture: refs/remotes/origin/HEAD exists (the symref the skip targets)"
else
    bad "F13 fixture: refs/remotes/origin/HEAD was not created — the symref is not exercised"
fi
run_script bash "$F13_SCRIPT" --scope remote
assert_eq "$RC" "0" "F13: remote dry-run exits 0"
assert_contains "$OUT" "origin/doomed" "F13: the ordinary stale merged branch is selected (control)"
assert_contains "$OUT" "origin/HEADfoo" "F13: a branch whose name begins with HEAD is NOT silently skipped (F13)"
assert_no_match "$OUT" 'refs/heads/HEAD:' "F13: the origin/HEAD symref itself is never selected for deletion (F13)"

cd "$REPO"
echo ""
echo "== 39. the local plan's unresolvable-tip arm is CONDITIONAL, not an unconditional fallback (F14) =="
# When a merged branch's tip cannot be resolved at plan time, execution's
# pre-check reads empty, reports `moved`, and does NOT run the fallback. The old
# plan printed the fallback with the SAME unqualified `(fallback if -d refuses)`
# reason it used for a resolvable tip, i.e. it advertised a command execution
# would refuse. The line is kept — never UNDER-advertise a delete execution may
# still perform if the ref reappears at the classified tip — but it is annotated
# as conditional on the tip, with the atomic caveat that update-ref -d refuses
# any other tip.
F14_ORIGIN="$FIX/f14-origin.git"
F14_REPO="$FIX/f14-repo"
new_repo "$F14_REPO" "$F14_ORIGIN"
cd "$F14_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F14_SCRIPT="$F14_REPO/scripts/cleanup-stale-branches.sh"
echo base > f14.txt; git add f14.txt; old_commit "init"; git push -q origin main
F14_MAIN_SHA="$(git rev-parse main)"
F14_TREE="$(git rev-parse "$F14_MAIN_SHA^{tree}")"
F14_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F14_TREE" -p "$F14_MAIN_SHA" -m "f14-unres")"
git update-ref refs/heads/f14-unres "$F14_SHA"
F14_MAP="$FIX/f14-pr-map.json"
cat > "$F14_MAP" <<JSON
[
  {"headRefName":"f14-unres","state":"MERGED","headRefOid":"$F14_SHA","baseRefName":"main"}
]
JSON
F14_REAL_GIT="$(command -v git)"
F14_WRAP="$FIX/f14-wrap"
mkdir -p "$F14_WRAP"
cat > "$F14_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F14): make the plan's tip read unresolvable for the target branch
# (the race where the ref disappears between classification and plan); every
# other call delegates.
REAL_GIT="${F14_REAL_GIT:?F14_REAL_GIT unset}"
if [ "$1" = "rev-parse" ]; then
    for _a in "$@"; do
        if [ "$_a" = "refs/heads/${F14_BRANCH:?F14_BRANCH unset}" ]; then
            exit 1
        fi
    done
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F14_WRAP/git"
run_script env PATH="$F14_WRAP:$PATH" F14_REAL_GIT="$F14_REAL_GIT" F14_BRANCH="f14-unres" \
    bash "$F14_SCRIPT" --repo "$F14_REPO" --scope local --pr-map-file "$F14_MAP"
assert_eq "$RC" "0" "F14: the unresolvable-tip dry-run still exits 0"
assert_contains "$OUT" 'git branch -d -- f14-unres   # class=merged' "F14: the -d command is still printed"
assert_contains "$OUT" 'git update-ref -d refs/heads/f14-unres' "F14: the fallback is still advertised (never under-advertise) (F14)"
assert_contains "$OUT" 'only if the tip is still' "F14: the fallback is annotated as CONDITIONAL on the tip (F14)"
assert_contains "$OUT" 'unresolvable at plan time' "F14: the annotation states the tip was unresolvable at plan time (F14)"
assert_not_contains "$OUT" 'class=merged (fallback if -d refuses)' "F14: the unresolvable arm does NOT print the unqualified fallback reason (F14)"

cd "$REPO"
echo ""
echo "== 40. an EMPTY classified tip refuses the force-delete; update-ref -d never gets an empty old value (F15) =="
# `git update-ref -d <ref> <old>` refuses unless the ref's current value equals
# <old> — but an EMPTY <old> disables that comparison and deletes
# UNCONDITIONALLY. `$sha` comes from the classification's `%(objectname)` field,
# and the delete-time pre-check that would otherwise reject an empty value is —
# by the script's own comment — NOT the safety mechanism. The shipped parsers
# make an empty tip UNREACHABLE through the merged gate: the PR map's
# `merged_ok_lookup` is `br:<oid>`, and `read` with IFS=TAB collapses an empty
# `<oid>` so its `baseRefName` field shifts away — the branch lands off-base and
# is kept. That construction is exactly why the guard must not DEPEND on it. To
# exercise the guard, the condition is FORCED on a COPY of the script (never the
# worktree file): one injected line empties the classified tip for the target
# branch AFTER the gate has classified it, simulating the field-shift the
# classification comment itself warns about. A git wrapper also answers the
# delete-time pre-check with nothing, so the atomic swap is reached. `f15-ok` is
# the positive control: the same shape with a resolvable tip must still be reaped
# by the atomic swap.
F15_ORIGIN="$FIX/f15-origin.git"
F15_REPO="$FIX/f15-repo"
new_repo "$F15_REPO" "$F15_ORIGIN"
cd "$F15_REPO"
echo base > f15.txt; git add f15.txt; old_commit "init"; git push -q origin main
F15_MAIN_SHA="$(git rev-parse main)"
F15_TREE="$(git rev-parse "$F15_MAIN_SHA^{tree}")"
F15_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F15_TREE" -p "$F15_MAIN_SHA" -m "f15-squash")"
git update-ref refs/heads/f15-empty "$F15_SHA"
git update-ref refs/heads/f15-ok "$F15_SHA"
F15_MAP="$FIX/f15-pr-map.json"
cat > "$F15_MAP" <<JSON
[
  {"headRefName":"f15-empty","state":"MERGED","headRefOid":"$F15_SHA","baseRefName":"main"},
  {"headRefName":"f15-ok","state":"MERGED","headRefOid":"$F15_SHA","baseRefName":"main"}
]
JSON
# The forced-condition copy. `index()` is a LITERAL substring match — the anchor
# carries regex metacharacters (`${`, `}`) that a regex would misread.
F15_DOC="$FIX/f15-doc"
mkdir -p "$F15_DOC"
awk -v inj='        if [ "$br" = "$F15_FORCE_EMPTY_TIP" ]; then sha=""; fi' '
    index($0, "delete_list=\"${delete_list}${cls}\"") > 0 { print inj }
    { print }
' "$SCRIPT" > "$F15_DOC/cleanup-stale-branches.sh"
if bash -n "$F15_DOC/cleanup-stale-branches.sh"; then
    ok "F15: the forced-condition copy is syntactically valid"
else
    bad "F15: the forced-condition copy is syntactically invalid"
fi
F15_REAL_GIT="$(command -v git)"
F15_WRAP="$FIX/f15-wrap"
mkdir -p "$F15_WRAP"
cat > "$F15_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F15): answer the plan/delete-time pre-check for the target branch
# with nothing (the ref appears unresolvable), so the atomic swap is reached.
# Every other call delegates to the real git.
REAL_GIT="${F15_REAL_GIT:?F15_REAL_GIT unset}"
BR="${F15_BRANCH:?F15_BRANCH unset}"
if [ "$1" = "rev-parse" ]; then
    for _a in "$@"; do
        if [ "$_a" = "refs/heads/$BR" ]; then
            exit 1
        fi
    done
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F15_WRAP/git"
# Dry run: the plan must NOT advertise a fallback whose old value is empty —
# pasting it would be an unconditional delete, and execution refuses that swap.
run_script env PATH="$F15_WRAP:$PATH" F15_REAL_GIT="$F15_REAL_GIT" F15_BRANCH="f15-empty" \
    F15_FORCE_EMPTY_TIP="f15-empty" \
    bash "$F15_DOC/cleanup-stale-branches.sh" --repo "$F15_REPO" --scope local --pr-map-file "$F15_MAP"
assert_eq "$RC" "0" "F15: the dry-run pass still exits 0"
assert_contains "$OUT" 'git branch -d -- f15-empty   # class=merged' "F15: the -d plan line is still printed"
assert_not_contains "$OUT" 'git update-ref -d refs/heads/f15-empty' \
    "F15: NO fallback is advertised when the CLASSIFIED tip is empty (an empty old value deletes unconditionally) (F15)"
assert_contains "$OUT" 'git update-ref -d refs/heads/f15-ok' \
    "F15: the normal fallback IS still advertised for a RESOLVABLE tip (no under-advertisement) (F15)"
# Execute: the empty-tip swap must be REFUSED and the branch must survive.
run_script env PATH="$F15_WRAP:$PATH" F15_REAL_GIT="$F15_REAL_GIT" F15_BRANCH="f15-empty" \
    F15_FORCE_EMPTY_TIP="f15-empty" \
    bash "$F15_DOC/cleanup-stale-branches.sh" --repo "$F15_REPO" --scope local --execute --pr-map-file "$F15_MAP"
assert_eq "$RC" "1" "F15: an empty classified tip fails the sweep (non-zero) (F15)"
assert_match "$OUT" '^  failed +merged +f15-empty ' "F15: the empty-tip branch is reported FAILED, never deleted (F15)"
assert_no_match "$OUT" '^  deleted +merged +f15-empty ' "F15: the empty-tip branch is NOT reported deleted (F15)"
if git -C "$F15_REPO" rev-parse -q --verify refs/heads/f15-empty >/dev/null 2>&1; then
    ok "F15: the branch SURVIVES (no unconditional update-ref -d with an empty old value) (F15)"
else
    bad "F15: the branch was DELETED via an empty old value — the invariant was not local to the swap (F15)"
fi
assert_branch_absent f15-ok "F15: the positive control (a RESOLVABLE tip) is still reaped through the atomic swap"
assert_contains "$OUT" "via update-ref -d: squash-merged PR" "F15: the normal force-delete path is unchanged"

cd "$REPO"
echo ""
echo "== 41. a successful force-delete ALSO removes branch.<b>.* config, matching git branch -D (F16) =="
# `git branch -D` removes the `branch.<b>.*` section; `git update-ref -d` does
# not, so pre-fix a later branch created under the same name inherited a stale
# upstream that this sweep's own `-d` and its plan prediction then consulted.
# `f16-nocfg` has NO such section: removing a missing section must not fail the
# run (git branch -D is equally silent when there is nothing to remove).
F16_ORIGIN="$FIX/f16-origin.git"
F16_REPO="$FIX/f16-repo"
new_repo "$F16_REPO" "$F16_ORIGIN"
cd "$F16_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F16_SCRIPT="$F16_REPO/scripts/cleanup-stale-branches.sh"
echo base > f16.txt; git add f16.txt; old_commit "init"; git push -q origin main
F16_MAIN_SHA="$(git rev-parse main)"
F16_TREE="$(git rev-parse "$F16_MAIN_SHA^{tree}")"
F16_SHA="$(GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
    GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git commit-tree "$F16_TREE" -p "$F16_MAIN_SHA" -m "f16-squash")"
git update-ref refs/heads/f16-cfg "$F16_SHA"
git update-ref refs/heads/f16-nocfg "$F16_SHA"
# the stale upstream the pre-fix path left behind (update-ref -d does not touch it);
# no `.merge`, so the branch has no complete upstream and `-d` compares against HEAD.
git config branch.f16-cfg.remote origin
F16_MAP="$FIX/f16-pr-map.json"
cat > "$F16_MAP" <<JSON
[
  {"headRefName":"f16-cfg","state":"MERGED","headRefOid":"$F16_SHA","baseRefName":"main"},
  {"headRefName":"f16-nocfg","state":"MERGED","headRefOid":"$F16_SHA","baseRefName":"main"}
]
JSON
assert_eq "$(git config --get branch.f16-cfg.remote || echo ABSENT)" "origin" \
    "F16: the fixture starts with branch.f16-cfg.remote configured"
run_script bash "$F16_SCRIPT" --repo "$F16_REPO" --scope local --execute --pr-map-file "$F16_MAP"
assert_eq "$RC" "0" "F16: the execute pass succeeds (a missing config section is not an error)"
assert_branch_absent f16-cfg "F16: the configured branch is force-deleted"
assert_branch_absent f16-nocfg "F16: the unconfigured branch is force-deleted"
assert_eq "$(git config --get branch.f16-cfg.remote || echo ABSENT)" "ABSENT" \
    "F16: branch.f16-cfg.remote is REMOVED (parity with git branch -D)"
assert_contains "$OUT" "Deleted:   2" "F16: both branches are counted deleted"
assert_contains "$OUT" "Failed:    0" "F16: no branch is reported failed"

cd "$REPO"
echo ""
echo "== 42. F18: a colour config must not make the REMOTE sweep drop candidates SILENTLY =="
# `git branch -r` COLOURISES the ref names it prints when `color.ui=always` (or
# `color.branch=always`) is set, so `$branch` became `\e[31morigin/foo\e[m`.
# `git log -1 --format='%ct' "$branch"` then exits 0 with EMPTY output, the old
# `= "0"` guard missed it, `[ "" -lt "$CUTOFF_EPOCH" ]` returned status 2 (which
# the `if` reads as FALSE), and the ref was dropped with NO diagnostic while the
# sweep printed `✅ No stale merged branches found` and exited 0 — a FALSE PASS on
# the destructive path. `--no-color` on the classification is the load-bearing
# fix, so removing it makes this whole section RED.
F18_ORIGIN="$FIX/f18-origin.git"
F18_REPO="$FIX/f18-repo"
new_repo "$F18_REPO" "$F18_ORIGIN"
cd "$F18_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F18_SCRIPT="$F18_REPO/scripts/cleanup-stale-branches.sh"
echo base > f18.txt; git add f18.txt; old_commit "init"; git push -q origin main
git checkout -q -b f18-stale main
echo hs > hs.txt; git add hs.txt; old_commit "hs"
git push -q -u origin f18-stale
git checkout -q main
git merge -q --ff-only f18-stale
git push -q origin main
if git merge-base --is-ancestor f18-stale main 2>/dev/null; then
    ok "F18 fixture: f18-stale is ancestor-merged into main (a remote candidate)"
else
    bad "F18 fixture: f18-stale is NOT merged into main — the fixture is wrong"
fi

# (a) the colour config the finding names: `color.ui=always`
run_script env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
    bash "$F18_SCRIPT" --repo "$F18_REPO" --scope remote
assert_eq "$RC" "0" "F18: dry-run with color.ui=always exits 0"
assert_contains "$OUT" "origin/f18-stale" "F18: the stale merged branch IS classified with color.ui=always"
assert_not_contains "$OUT" "No stale merged branches found" "F18: the false 'nothing is stale' success line is NOT printed with color.ui=always"
assert_not_contains "$OUT" "integer expression expected" "F18: no silent integer-compare failure with color.ui=always"
run_script env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
    bash "$F18_SCRIPT" --repo "$F18_REPO" --scope remote --execute
assert_eq "$RC" "0" "F18: --execute with color.ui=always exits 0"
if [ -z "$(git ls-remote origin refs/heads/f18-stale 2>/dev/null)" ]; then
    ok "F18: the stale merged remote branch IS deleted with color.ui=always (exactly as with colour off)"
else
    bad "F18: color.ui=always made the sweep DROP the candidate — the branch survives"
fi

# (b) `color.branch=always` — the case `color.ui=false` alone does NOT cover
#     (verified on git 2.50.1: color.branch wins over color.ui). `--no-color`
#     is a command-line flag, so it beats both.
git push -q origin refs/heads/main:refs/heads/f18-stale
run_script env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=color.branch GIT_CONFIG_VALUE_0=always \
    bash "$F18_SCRIPT" --repo "$F18_REPO" --scope remote --execute
assert_eq "$RC" "0" "F18: --execute with color.branch=always exits 0"
assert_not_contains "$OUT" "No stale merged branches found" "F18: color.branch=always does not silence the sweep"
if [ -z "$(git ls-remote origin refs/heads/f18-stale 2>/dev/null)" ]; then
    ok "F18: the branch IS deleted with color.branch=always (--no-color beats color.branch)"
else
    bad "F18: color.branch=always made the sweep DROP the candidate — the branch survives"
fi

# (c) the LOUD arm: an unreadable date for a LISTED ref must REFUSE the sweep,
#     not be read as "not stale". A `git log` that exits 0 with empty output is
#     exactly the shape the colour bug produced.
F18_WRAP="$FIX/f18-wrap"
F18_REAL_GIT="$(command -v git)"
mkdir -p "$F18_WRAP"
cat > "$F18_WRAP/git" <<'WRAP'
#!/usr/bin/env bash
# Test double (F18): for ONE ref, model an UNREADABLE commit date — `git log`
# exits 0 with EMPTY output, exactly what a colour-poisoned ref name produced.
# Every other invocation delegates unchanged.
REAL_GIT="${F18_REAL_GIT:?F18_REAL_GIT unset}"
if [ "${1:-}" = "log" ]; then
    case "$*" in
        *f18-nodate*) exit 0 ;;
    esac
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$F18_WRAP/git"
git push -q origin refs/heads/main:refs/heads/f18-nodate
F18_NODATE_OID="$(git -C "$F18_ORIGIN" rev-parse refs/heads/f18-nodate)"
run_script env PATH="$F18_WRAP:$PATH" F18_REAL_GIT="$F18_REAL_GIT" \
    bash "$F18_SCRIPT" --repo "$F18_REPO" --scope remote --execute
if [ "$RC" -ne 0 ]; then
    ok "F18: an unreadable commit date REFUSES the sweep (rc=$RC, not a silent success)"
else
    bad "F18: an unreadable commit date did NOT fail the sweep (rc=0) — the silent-drop path is back"
fi
assert_contains "$OUT" "could not read the commit date of origin/f18-nodate" "F18: the refusal names the ref whose date was unreadable"
assert_not_contains "$OUT" "No stale merged branches found" "F18: the refusal does NOT print the clean-sweep line"
if [ "$(git -C "$F18_ORIGIN" rev-parse -q --verify refs/heads/f18-nodate || echo GONE)" = "$F18_NODATE_OID" ]; then
    ok "F18: the unreadable-date branch SURVIVES the refused sweep (nothing partial is deleted)"
else
    bad "F18: the unreadable-date branch was deleted despite the refusal"
fi

cd "$REPO"
echo ""
echo "== 43. F20: the REMOTE plan must NOT advertise a delete that --execute REFUSES =="
# The lease pins the OID, but it cannot check the MERGE PREMISE. A branch
# classified `--merged` from a STALE refs/remotes/origin/<main> (narrowed
# positive refspec) whose commits are no longer in REWRITTEN real main passes
# the lease and IS DELETED by a pasted plan line, while `--execute` REFUSES it
# (its verify_merged_into_real_main gate). The plan must run the SAME two gates,
# per entry, and print a refused entry ONLY as a comment.
F20_ORIGIN="$FIX/f20-origin.git"
F20_REPO="$FIX/f20-repo"
F20_RW="$FIX/f20-rewrite"
new_repo "$F20_REPO" "$F20_ORIGIN"
cd "$F20_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F20_SCRIPT="$F20_REPO/scripts/cleanup-stale-branches.sh"
echo base > f20.txt; git add f20.txt; old_commit "init"; git push -q origin main
# doomed — merged into main and stale, so it IS a candidate against the local
# refs/remotes/origin/main.
git checkout -q -b doomed main
echo d > d.txt; git add d.txt; old_commit "doomed"
git push -q -u origin doomed
git checkout -q main
git merge -q --ff-only doomed
git push -q origin main
F20_DOOMED_OID="$(git -C "$F20_ORIGIN" rev-parse refs/heads/doomed)"
# A ref OTHER than main for the narrowed fetch refspec (it must exist on the
# remote or the fetch exits non-zero). Fresh commit -> never a stale candidate.
git checkout -q -b f20-anchor main
echo a > a.txt; git add a.txt; git commit -q -m "f20-anchor"
git push -q -u origin f20-anchor
git checkout -q main
# REWRITE real main from a separate clone so it no longer contains doomed's tip.
git clone -q -b main "$F20_ORIGIN" "$F20_RW"
git -C "$F20_RW" config user.email test@test.test
git -C "$F20_RW" config user.name "Test Runner"
git -C "$F20_RW" config commit.gpgsign false
git -C "$F20_RW" checkout -q --orphan rewritten
git -C "$F20_RW" rm -q -rf . >/dev/null 2>&1 || true
echo rewritten > "$F20_RW/rewritten.txt"
git -C "$F20_RW" add rewritten.txt
GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000" \
GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000" \
    git -C "$F20_RW" commit -q -m rewritten
git -C "$F20_RW" push -q --force origin rewritten:refs/heads/main
F20_REAL_MAIN="$(git -C "$F20_ORIGIN" rev-parse refs/heads/main)"
F20_STALE_MAIN="$(git rev-parse origin/main)"
if [ "$F20_STALE_MAIN" = "$F20_DOOMED_OID" ]; then
    ok "F20 fixture: refs/remotes/origin/main is STALE and contains doomed's tip (F20)"
else
    bad "F20 fixture: refs/remotes/origin/main ($F20_STALE_MAIN) is not the pre-rewrite tip (F20)"
fi
if ! git -C "$F20_ORIGIN" merge-base --is-ancestor "$F20_DOOMED_OID" "$F20_REAL_MAIN" 2>/dev/null; then
    ok "F20 fixture: real main was REWRITTEN and no longer contains doomed's tip (F20)"
else
    bad "F20 fixture: real main still contains doomed's tip — the fixture is wrong (F20)"
fi
# The NARROWED refspec: only f20-anchor is refreshed, so refs/remotes/origin/main
# keeps its stale (pre-rewrite) value through a 0-exit prune.
git config --replace-all remote.origin.fetch '+refs/heads/f20-anchor:refs/remotes/origin/f20-anchor'
git fetch origin --prune --quiet
if [ "$(git rev-parse origin/main)" = "$F20_STALE_MAIN" ]; then
    ok "F20 fixture: refs/remotes/origin/main stayed STALE through the fetch (F20)"
else
    bad "F20 fixture: the fetch refreshed origin/main — the narrowed refspec did not hold (F20)"
fi
# The plan must run the gates and REFUSE the doomed entry as a COMMENT, never as
# an executable command.
run_script bash "$F20_SCRIPT" --repo "$F20_REPO" --scope remote
assert_eq "$RC" "0" "F20: the dry-run exits 0"
F20_PLAN="$OUT"
assert_contains "$F20_PLAN" "origin/doomed" "F20: the doomed branch IS classified as a candidate"
assert_contains "$F20_PLAN" "# REFUSED — --execute will not run this" "F20: the plan marks the entry REFUSED"
assert_contains "$F20_PLAN" "does NOT provably contain the classified tip" "F20: the REFUSED note carries the real reason"
assert_eq "$(grep -c '^  git push origin --delete' <<<"$F20_PLAN" || true)" "0" "F20: the plan prints NO executable delete for the refused entry"
# A VERBATIM PASTE of the plan's command block must NOT delete doomed. Under the
# pre-fix code the entry was printed as an executable push whose lease PASSES
# (origin's real doomed IS at the classified oid), so the paste deleted it while
# `--execute` refused — the data-loss path.
F20_PASTE="$FIX/f20-paste.sh"
{
    printf '#!/usr/bin/env bash\n'
    awk '/^Deletion commands that would run/ { grab=1; next } grab && /^$/ { exit } grab { print }' <<<"$F20_PLAN"
} > "$F20_PASTE"
run_script bash "$F20_PASTE"
assert_eq "$RC" "0" "F20: a paste of the plan exits 0"
if [ "$(git -C "$F20_ORIGIN" rev-parse -q --verify refs/heads/doomed || echo GONE)" = "$F20_DOOMED_OID" ]; then
    ok "F20: a PASTE of the printed plan does NOT delete doomed (F20)"
else
    bad "F20: a paste of the plan DELETED doomed — the data-loss path is back (F20)"
fi
# And `--execute` still refuses, leaving the branch intact.
run_script bash "$F20_SCRIPT" --repo "$F20_REPO" --scope remote --execute
assert_eq "$RC" "1" "F20: --execute still REFUSES the unprovable delete"
assert_contains "$OUT" "REFUSING to delete origin/doomed" "F20: --execute names the refused branch"
assert_contains "$OUT" "Refused: 1" "F20: --execute counts exactly one refusal"
if [ "$(git -C "$F20_ORIGIN" rev-parse -q --verify refs/heads/doomed || echo GONE)" = "$F20_DOOMED_OID" ]; then
    ok "F20: origin's real doomed SURVIVES --execute (F20)"
else
    bad "F20: origin's real doomed was deleted — data loss (F20)"
fi

cd "$REPO"
echo ""
echo "== 44. F22: an over-range LOCAL committer date REFUSES, it never counts as stale =="
# `git for-each-ref` reads `%(committerdate:unix)` from an object `git log`
# cannot format. For an all-digit value ABOVE bash's integer range
# (2^63 = 9223372036854775808) a bare `[ "$cdate" -ge "$CUTOFF_EPOCH" ]` returns
# status 2, the `||` reads FALSE, and the branch is treated as STALE — the
# failure GROWS the candidate set, the OPPOSITE polarity to the remote F18 guard.
# The guard must REFUSE the local sweep, name the ref and leave it intact; a
# genuine epoch-0 commit (cdate = 0, all-digits) must STILL be treated as stale.
F22_ORIGIN="$FIX/f22-origin.git"
F22_REPO="$FIX/f22-repo"
new_repo "$F22_REPO" "$F22_ORIGIN"
cd "$F22_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F22_SCRIPT="$F22_REPO/scripts/cleanup-stale-branches.sh"
echo base > f22.txt; git add f22.txt; old_commit "init"; git push -q origin main
F22_MAIN_SHA="$(git rev-parse main)"
F22_TREE="$(git rev-parse "$F22_MAIN_SHA^{tree}")"
# A synthetic commit with committer timestamp 2^63, written with --literally so
# git does not sanitise the value.
F22_OVER_OID="$(printf 'tree %s\nparent %s\nauthor A <a@b> 9223372036854775808 +0000\ncommitter A <a@b> 9223372036854775808 +0000\n\nf22 over\n' \
    "$F22_TREE" "$F22_MAIN_SHA" | git hash-object -t commit -w --stdin --literally)"
git update-ref refs/heads/f22-over "$F22_OVER_OID"
F22_CDATE="$(git for-each-ref --format='%(committerdate:unix)' refs/heads/f22-over)"
assert_eq "$F22_CDATE" "9223372036854775808" "F22 fixture: for-each-ref renders the over-intmax date as wrapped digits (F22)"
# A GENUINE epoch-0 commit: cdate = 0, which IS stale and must keep being stale.
git checkout -q -b f22-epoch main
echo z > z.txt; git add z.txt
GIT_AUTHOR_DATE="1970-01-01T00:00:00 +0000" \
GIT_COMMITTER_DATE="1970-01-01T00:00:00 +0000" \
    git commit -q -m "f22-epoch"
F22_EPOCH_OID="$(git rev-parse HEAD)"
git checkout -q main
# A PR map carries BOTH branches as `merged`, so each reaches the delete path
# once the staleness gate lets it through — the guard is what refuses f22-over.
F22_MAP="$FIX/f22-pr-map.json"
cat > "$F22_MAP" <<JSON
[
  {"headRefName":"f22-over","state":"MERGED","headRefOid":"$F22_OVER_OID","baseRefName":"main"},
  {"headRefName":"f22-epoch","state":"MERGED","headRefOid":"$F22_EPOCH_OID","baseRefName":"main"}
]
JSON
run_script bash "$F22_SCRIPT" --repo "$F22_REPO" --scope local --pr-map-file "$F22_MAP" --execute
if [ "$RC" -ne 0 ]; then
    ok "F22: an over-intmax committer date REFUSES the local sweep (rc=$RC)"
else
    bad "F22: the over-intmax committer date did NOT fail the sweep (rc=0) — it was read as stale"
fi
assert_contains "$OUT" "commit date of f22-over" "F22: the refusal names the ref whose date is unreadable"
assert_branch_exists f22-over "F22: the over-intmax branch SURVIVES the refused sweep"
assert_eq "$(git rev-parse -q --verify refs/heads/f22-over || echo GONE)" "$F22_OVER_OID" "F22: the over-intmax branch is still at its classified oid"
# With the pathological ref removed, epoch-0 must STILL be stale: the sweep runs
# clean and reaps it, proving the guard did not swallow the genuine stale case.
git update-ref -d refs/heads/f22-over
run_script bash "$F22_SCRIPT" --repo "$F22_REPO" --scope local --pr-map-file "$F22_MAP" --execute
assert_eq "$RC" "0" "F22: with the pathological ref removed, the sweep runs clean"
assert_branch_absent f22-epoch "F22: a genuine epoch-0 commit (cdate 0) IS still treated as stale and reaped"

echo ""
echo "== 45. F24: an OVER-LONG all-digit commit date is REFUSED by BOTH scopes =="
# The remote guard's `''|*[!0-9]*` case ACCEPTED an over-long all-digit value
# (`9223372036854775808`): `[ "$COMMIT_DATE" -lt "$CUTOFF_EPOCH" ]` returned
# status 2, the `if` read FALSE, and the candidate was DROPPED with no
# diagnostic while the sweep printed `✅ No stale merged branches found` and
# exited 0 — the SAME false PASS F18 closes for an EMPTY value, and the exact
# case the F18 comment claimed could no longer happen. The local scope (F22) had
# its own copy of the check WITH the 15-digit bound, so the two scopes had
# drifted. Both now call the single validate_commit_date; this section pins the
# REMOTE call site (F22 pins the local one) and re-pins the local one from this
# same fixture. Removing the helper's `[ "${#value}" -gt 15 ]` bound turns
# BOTH halves RED.
F24_ORIGIN="$FIX/f24-origin.git"
F24_REPO="$FIX/f24-repo"
new_repo "$F24_REPO" "$F24_ORIGIN"
cd "$F24_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F24_SCRIPT="$F24_REPO/scripts/cleanup-stale-branches.sh"
echo base > f24.txt; git add f24.txt; old_commit "init"; git push -q origin main
F24_MAIN_SHA="$(git rev-parse main)"
F24_TREE="$(git rev-parse "$F24_MAIN_SHA^{tree}")"

# CONTROL: a GENUINE all-digit date must still be evaluated normally. `f24-old`
# is the initial (2020) commit, merged into main and older than the cutoff, so a
# sweep that sees only it classifies it as stale and exits 0 — proof the helper
# rules on READABILITY, never on staleness.
git push -q origin refs/heads/main:refs/heads/f24-old
run_script bash "$F24_SCRIPT" --repo "$F24_REPO" --scope remote
assert_eq "$RC" "0" "F24 control: a genuine old all-digit date is still evaluated (rc=0)"
assert_contains "$OUT" "origin/f24-old" "F24 control: the stale merged branch with a readable date IS selected"

# The over-long value: 2^63, written with --literally so git does not sanitise
# it. origin's main AND f24-over point at it, so `--merged origin/main` LISTS
# f24-over (it is main's own commit) and the guard is reached for it.
F24_OVER_OID="$(printf 'tree %s\nparent %s\nauthor A <a@b> 9223372036854775808 +0000\ncommitter A <a@b> 9223372036854775808 +0000\n\nf24 over\n' \
    "$F24_TREE" "$F24_MAIN_SHA" | git hash-object -t commit -w --stdin --literally)"
git update-ref refs/heads/main "$F24_OVER_OID"
git update-ref refs/heads/f24-over "$F24_OVER_OID"
git push -q --force origin main f24-over
F24_CDATE="$(git log --no-color -1 --format='%ct' refs/remotes/origin/f24-over 2>/dev/null || true)"
assert_eq "$F24_CDATE" "9223372036854775808" "F24 fixture: git log prints the over-long date verbatim (the guard's input)"

run_script bash "$F24_SCRIPT" --repo "$F24_REPO" --scope remote --execute
if [ "$RC" -ne 0 ]; then
    ok "F24: an over-long remote commit date REFUSES the sweep (rc=$RC, not a silent clean sweep)"
else
    bad "F24: the over-long remote date did NOT fail the sweep (rc=0) — the candidate was dropped silently"
fi
assert_contains "$OUT" "commit date of origin/f24-over" "F24: the remote refusal NAMES the ref it could not evaluate"
assert_not_contains "$OUT" "No stale merged branches found" "F24: the refusal does NOT print the clean-sweep line"
assert_not_contains "$OUT" "integer expression expected" "F24: the failed comparison does not leak a bare bash diagnostic"
if [ "$(git -C "$F24_ORIGIN" rev-parse -q --verify refs/heads/f24-over || echo GONE)" = "$F24_OVER_OID" ]; then
    ok "F24: the over-long-date branch SURVIVES the refused remote sweep"
else
    bad "F24: the over-long-date branch was deleted despite the refusal"
fi

# The LOCAL call site, from the SAME shared helper. A local branch at the
# synthetic commit must refuse too — naming ITS OWN ref, which proves each call
# site passes its ref through to the one implementation. The MERGED PR makes the
# branch gate-eligible, so if the bound is removed it is selected and deleted
# (`rc=0`) — the mutation this section catches.
git update-ref refs/heads/f24-local-over "$F24_OVER_OID"
F24_MAP="$FIX/f24-pr-map.json"
cat > "$F24_MAP" <<JSON
[
  {"headRefName":"f24-local-over","state":"MERGED","headRefOid":"$F24_OVER_OID","baseRefName":"main"}
]
JSON
run_script bash "$F24_SCRIPT" --repo "$F24_REPO" --scope local --pr-map-file "$F24_MAP" --execute
if [ "$RC" -ne 0 ]; then
    ok "F24: the SAME over-long date REFUSES the local sweep too (rc=$RC)"
else
    bad "F24: the local over-long date did NOT fail the sweep (rc=0) — the two call sites still differ"
fi
assert_contains "$OUT" "commit date of f24-local-over" "F24: the local refusal names its OWN ref (the shared helper is called from both sites)"
if [ "$(git rev-parse -q --verify refs/heads/f24-local-over || echo GONE)" = "$F24_OVER_OID" ]; then
    ok "F24: the over-long-date local branch SURVIVES the refused local sweep"
else
    bad "F24: the over-long-date local branch was deleted despite the refusal — the local guard did not fire"
fi

echo ""
echo "== 46. F25: the commit-date family is bounded by the NORMALISED NUMERIC VALUE, never the raw string =="
# `git log --format='%ct'` (the REMOTE scope's read) prints a timestamp VERBATIM,
# so a commit object can carry `0000000009` or `0000000000000009` — the SAME
# numeric value (9), spelled with a different digit count. Bounding the RAW
# STRING split that one root into two OPPOSITE failures:
#   * `0000000009` (10 characters) PASSED the 15-character bound, and then
#     `date -r 0000000009` FAILED on macOS (it parses the argument as a DATE, not
#     as seconds, and there is no `date -d` fallback here). Under `set -e` that
#     assignment aborted the whole remote sweep with a raw `date` usage message,
#     rc=1, NO plan and NO delete. Under CLEANUP_BRANCH_LOG the pass runs
#     `set +e`, so the same value printed the branch with an EMPTY date instead.
#   * `0000000000000009` (16 characters, numeric 9) was FALSELY refused as
#     "outside bash's integer range", although `[ 0000000000000009 -lt 100 ]` is 0
#     on bash 3.2.57.
# The shared helper now strips leading zeros BEFORE the bound, and the remote
# `date` call re-reads the digits as base 10 (`$((10#$v))`), so a zero-padded
# value can never reach `date` as a date string. This section pins the WHOLE
# family: it calls the SHARED helper directly for the value classes, then drives
# BOTH scopes end-to-end with REAL zero-padded commit objects. `git for-each-ref`
# (the local scope's read) NORMALISES the value, so the LOCAL half pins
# ACCEPTANCE; the REMOTE half pins that `date` is never handed the raw string.
F25_HELPER="$FIX/f25-helper.sh"
sed -n '/^validate_commit_date()/,/^}/p' "$SCRIPT" > "$F25_HELPER"
if grep -qF 'value="${value#' "$F25_HELPER"; then
    ok "F25: the SHARED validate_commit_date was extracted from the script under test"
else
    bad "F25: could not extract validate_commit_date from the script — the unit half cannot run"
fi
f25_helper() { # $1 = the value the shared helper is asked to rule on
    run_script bash -c 'source "$1"; validate_commit_date "f25-helper" "$2"' _ "$F25_HELPER" "$1"
}

# ── REFUSED: empty, whitespace, non-numeric ───────────────────────
f25_helper ""
assert_eq "$RC" "1" "F25: an EMPTY commit date is REFUSED"
assert_contains "$OUT" "could not read the commit date of f25-helper" "F25: the empty-value refusal NAMES the ref"
f25_helper " "
assert_eq "$RC" "1" "F25: a WHITESPACE commit date is REFUSED"
f25_helper "abc"
assert_eq "$RC" "1" "F25: a NON-NUMERIC commit date is REFUSED"
f25_helper "12x"
assert_eq "$RC" "1" "F25: a partially-numeric commit date is REFUSED"

# ── REFUSED: genuinely over the file's 15-digit bound ─────────────
f25_helper "9223372036854775808"
assert_eq "$RC" "1" "F25: 2^63 is REFUSED as over-range"
assert_contains "$OUT" "outside bash's integer range" "F25: the over-range refusal says WHY"
f25_helper "9999999999999999"
assert_eq "$RC" "1" "F25: a 16-digit over-range value is REFUSED"
f25_helper "1000000000000000"
assert_eq "$RC" "1" "F25: 10^15 (16 digits) is REFUSED"

# ── ACCEPTED: zero-padded values, judged by NUMERIC VALUE ─────────
# These are the assertions that go RED if the leading-zero strip is removed:
# without it, every value longer than 15 raw characters is refused here, and
# `0000000009` reaches `date` as a date string in the remote half below.
f25_helper "0000000009"
assert_eq "$RC" "0" "F25: 0000000009 (numeric 9) is ACCEPTED"
f25_helper "0000000000000009"
assert_eq "$RC" "0" "F25: 0000000000000009 (16 characters, numeric 9) is ACCEPTED — the RAW length is not the bound"
f25_helper "0000000000000000000000000009"
assert_eq "$RC" "0" "F25: any number of leading zeros normalises to the same value (26 characters accepted)"
f25_helper "0000000000"
assert_eq "$RC" "0" "F25: an all-zero value normalises to 0 and is ACCEPTED"
f25_helper "0"
assert_eq "$RC" "0" "F25: epoch 0 is ACCEPTED (it is STALE, not unreadable)"
f25_helper "012"
assert_eq "$RC" "0" "F25: the leading-zero short value 012 is ACCEPTED"
f25_helper "999999999999999"
assert_eq "$RC" "0" "F25: the 15-digit maximum is still ACCEPTED"
f25_helper "1577836800"
assert_eq "$RC" "0" "F25: a normal 10-digit date is ACCEPTED"

# ── REMOTE scope end-to-end: real zero-padded %ct objects ─────────
F25_ORIGIN="$FIX/f25-origin.git"
F25_REPO="$FIX/f25-repo"
new_repo "$F25_REPO" "$F25_ORIGIN"
cd "$F25_REPO"
mkdir -p scripts
cp "$SCRIPT" scripts/
F25_SCRIPT="$F25_REPO/scripts/cleanup-stale-branches.sh"
echo base > f25.txt; git add f25.txt; old_commit "init"; git push -q origin main
F25_PARENT="$(git rev-parse main)"
F25_TREE="$(git rev-parse "$F25_PARENT^{tree}")"
# Chain the synthetic commits, so EVERY one of them is an ancestor of main's
# tip and `git branch -r --merged origin/main` lists each as its own ref.
# ⛔ NOT called inside `$( )`: a command substitution runs the function in a
# SUBSHELL, so the `F25_PARENT` chaining update would be discarded and every
# commit would become a sibling of the base — merged into main, but NOT
# ancestors of it, so `--merged` would list none of them.
f25_synth() { # $1 = branch name, $2 = RAW committer timestamp -> sets $F25_OID
    F25_OID="$(printf 'tree %s\nparent %s\nauthor A <a@b> %s +0000\ncommitter A <a@b> %s +0000\n\nf25 %s\n' \
        "$F25_TREE" "$F25_PARENT" "$2" "$2" "$1" \
        | git hash-object -t commit -w --stdin --literally)"
    F25_PARENT="$F25_OID"
}
F25_OID=""
f25_synth f25-zpad10 0000000009;      F25_ZPAD10="$F25_OID"
f25_synth f25-zpad16 0000000000000009; F25_ZPAD16="$F25_OID"
f25_synth f25-zlead 012;               F25_ZLEAD="$F25_OID"
f25_synth f25-epoch 0;                 F25_EPOCH="$F25_OID"
f25_synth f25-fresh 2000000000;        F25_FRESH="$F25_OID"
git update-ref refs/heads/main "$F25_FRESH"
git update-ref refs/heads/f25-zpad10 "$F25_ZPAD10"
git update-ref refs/heads/f25-zpad16 "$F25_ZPAD16"
git update-ref refs/heads/f25-zlead "$F25_ZLEAD"
git update-ref refs/heads/f25-epoch "$F25_EPOCH"
git update-ref refs/heads/f25-fresh "$F25_FRESH"
git push -q --force origin main f25-zpad10 f25-zpad16 f25-zlead f25-epoch f25-fresh
# Fixture proof: `git log` prints the timestamp VERBATIM (the guard's input),
# while `git for-each-ref` normalises it (the local scope's input).
assert_eq "$(git log --no-color -1 --format='%ct' refs/remotes/origin/f25-zpad10)" "0000000009" "F25 fixture: git log prints 0000000009 verbatim (the remote guard's input)"
assert_eq "$(git log --no-color -1 --format='%ct' refs/remotes/origin/f25-zpad16)" "0000000000000009" "F25 fixture: git log prints the 16-character zero-padded value verbatim"
assert_eq "$(git for-each-ref --no-color --format='%(committerdate:unix)' refs/heads/f25-zpad16)" "9" "F25 fixture: git for-each-ref normalises the same value to 9 (the local scope's input)"

run_script bash "$F25_SCRIPT" --repo "$F25_REPO" --scope remote
assert_eq "$RC" "0" "F25 remote: the zero-padded family does NOT abort the sweep (no raw-date abort, no refusal)"
assert_not_contains "$OUT" "illegal option" "F25 remote: no raw 'date' usage message (the abort F25 closes)"
assert_not_contains "$OUT" "usage: date" "F25 remote: no raw 'date' usage message (Linux shape)"
assert_not_contains "$OUT" "could not read the commit date" "F25 remote: a zero-padded date is NOT treated as unreadable"
assert_no_match "$OUT" 'last commit: *$' "F25 remote: no candidate is printed with an EMPTY date"
assert_contains "$OUT" "Found 4 stale merged branch(es)" "F25 remote: all four stale zero-padded/epoch candidates are SELECTED (none silently dropped)"
assert_match "$OUT" 'origin/f25-zpad10 +last commit: [0-9]{4}-[0-9]{2}-[0-9]{2}' "F25 remote: 0000000009 is evaluated and rendered as its NUMERIC date"
assert_match "$OUT" 'origin/f25-zpad16 +last commit: [0-9]{4}-[0-9]{2}-[0-9]{2}' "F25 remote: the 16-character zero-padded value is rendered as a date, not refused"
assert_contains "$OUT" "origin/f25-zlead" "F25 remote: the leading-zero short value 012 is selected"
assert_contains "$OUT" "origin/f25-epoch" "F25 remote: epoch 0 is still stale and selected"
assert_not_contains "$OUT" "origin/f25-fresh" "F25 remote: the large legitimate FRESH date is NOT selected"

run_script bash "$F25_SCRIPT" --repo "$F25_REPO" --scope remote --execute
assert_eq "$RC" "0" "F25 remote --execute: exits 0 over the zero-padded family"
for _f25b in f25-zpad10 f25-zpad16 f25-zlead f25-epoch; do
    if [ "$(git -C "$F25_ORIGIN" rev-parse -q --verify "refs/heads/$_f25b" || echo GONE)" = "GONE" ]; then
        ok "F25 remote: stale $_f25b WAS deleted (accepted, evaluated, reaped)"
    else
        bad "F25 remote: stale $_f25b SURVIVED the execute sweep — it was silently dropped"
    fi
done
unset _f25b
assert_eq "$(git -C "$F25_ORIGIN" rev-parse -q --verify refs/heads/f25-fresh || echo GONE)" "$F25_FRESH" "F25 remote: the FRESH branch SURVIVES --execute"

# ── LOCAL scope end-to-end: the SAME zero-padded commit date ──────
# Nothing on the local path reads `date` (its plan prints no date), but the
# SHARED helper is on it — so this pins that the local sweep ACCEPTS a
# zero-padded committer date instead of falsely refusing the whole run, and
# evaluates it as its numeric value (for-each-ref normalised it to 9).
git update-ref refs/heads/f25-local-zpad "$F25_ZPAD16"
F25_MAP="$FIX/f25-pr-map.json"
cat > "$F25_MAP" <<JSON
[
  {"headRefName":"f25-local-zpad","state":"MERGED","headRefOid":"$F25_ZPAD16","baseRefName":"main"}
]
JSON
run_script bash "$F25_SCRIPT" --repo "$F25_REPO" --scope local --pr-map-file "$F25_MAP" --execute
assert_eq "$RC" "0" "F25 local: a zero-padded committer date does NOT refuse the local sweep (rc=0)"
assert_not_contains "$OUT" "outside bash's integer range" "F25 local: the 16-character zero-padded value is NOT refused as over-range"
assert_branch_absent f25-local-zpad "F25 local: the zero-padded local branch IS treated as stale and reaped"

cd "$REPO"
echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
