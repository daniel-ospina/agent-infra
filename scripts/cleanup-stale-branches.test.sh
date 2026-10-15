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
#                    also the ONLY class that exercises the `-D` fallback.
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
assert_not_contains "$OUT" '^  delete ' "a failed worktree enumeration selects no branch"
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
assert_eq "$RC" "0" "execute exits 0 (a per-branch failure is reported, not fatal)"
assert_match "$OUT" '^  deleted +merged +feat/merged-one' 'merged branch deleted (via the -D fallback)'
assert_contains "$OUT" "via -D: squash-merged PR" 'the -D fallback is named in the output'
assert_match "$OUT" '^  deleted +redundant +redundant-one' 'redundant branch deleted'
assert_match "$OUT" '^  deleted +remotecopy +remote-copy-one' 'remotecopy branch deleted'
assert_match "$OUT" '^  failed +redundant +redundant-stuck' 'redundant-stuck reported FAILED (no -D for a non-merged class)'
assert_contains "$OUT" "Deleted:   3" "summary reports 3 deletions"
assert_contains "$OUT" "Failed:    1" "summary reports 1 failure"

assert_branch_absent feat/merged-one "merged branch removed by -D fallback"
assert_branch_absent redundant-one "redundant branch removed by -d"
assert_branch_absent remote-copy-one "remotecopy branch removed by -d"
assert_branch_exists redundant-stuck "redundant-stuck SURVIVES (-D not allowed for the redundant class)"
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
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
