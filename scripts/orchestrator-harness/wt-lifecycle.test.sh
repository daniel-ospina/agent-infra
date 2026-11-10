#!/usr/bin/env bash
# wt-lifecycle.test.sh — the regression contract for the lane worktree/branch lifecycle
# (agent-infra#2033).
#
# THE DEFECT. A failed or aborted lane left a worktree and/or a branch behind, and the collision
# pre-flight infers "in flight" from exactly those two surfaces — so a FREE issue became permanently
# undispatchable on every box, with no owner and no expiry:
#
#   #8090 -> VERDICT: COLLISION
#     [local branches]  refs/heads/feat/8090-tm — matched issue-number (8090) — 0 commit(s) ahead
#     [local worktrees] …/.worktrees/tm-8090 [refs/heads/feat/8090-tm] (age=2.4h)
#
# ZERO commits ahead. The creation site (`dispatch-merge.sh`) was
#   git worktree add .worktrees/tm-N -b feat/N-tm origin/main || { release claim; skip }
# so a failed add left the branch it had already created (plus, when killed mid-checkout, a LOCKED,
# half-materialised, `D`-for-every-missing-file directory), and a leftover 0-ahead branch made every
# later attempt fail with "branch exists?" — the issue was skipped for ever on every box.
#
# HOW THESE CHECKS ARE WRITTEN. Every check drives the SHIPPED `wt-lifecycle.sh` (and, for the last
# group, the SHIPPED `lane.sh`) against REAL git repositories in a throwaway temp dir: the gates ARE
# git semantics, so shimming git would let the suite pass while the production behaviour was wrong.
# Fixtures are tiny (one commit, one file) — the whole suite is a handful of MB.
#
# ⛔ THE FAILED-ADD FIXTURE IS THE MEASURED SHAPE, NOT AN INVENTED ONE. Three `git worktree add`
# invocations were SIGKILLed mid-checkout on 2026-10-18 and every one left: the branch (created
# first), a registered admin record, a `locked` file containing `initializing`, a partial directory,
# and `D` entries for every file git had not written yet. `mk_failing_git` reproduces that state
# deterministically (a real checkout, then the lock + missing files + exit 1) instead of racing a
# kill, because a test that is 1-in-20 flaky pins nothing.
#
# Run:  bash scripts/orchestrator-harness/wt-lifecycle.test.sh

set -uo pipefail

# Guard the one failure this suite cannot report itself: a truncated file (bash executes
# incrementally, so an unbalanced quote late in the file runs every earlier fixture and then dies
# without a summary).
bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WTL="$HERE/wt-lifecycle.sh"
LANE="$HERE/lane.sh"
# The GitHub slug `mk_lane_box` points the fixture's origin at, and — because lane.sh asserts the
# checkout's own origin against its target (#2724/#2694) — the ONLY target L6/L7 may pass it.
LANE_OR="daniel-ospina/agent-infra"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (found: $2)"; else ok "$3"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_branch()   { if [ -n "$("$REAL_GIT" -C "$1" rev-parse --verify -q "refs/heads/$2" 2>/dev/null)" ]; then ok "$3"; else bad "$3 (no ref: $2)"; fi; }
assert_nobranch() { if [ -n "$("$REAL_GIT" -C "$1" rev-parse --verify -q "refs/heads/$2" 2>/dev/null)" ]; then bad "$3 (ref still exists: $2)"; else ok "$3"; fi; }
assert_registered()   { if "$REAL_GIT" -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; then ok "$3"; else bad "$3 (not registered: $2)"; fi; }
assert_unregistered() { if "$REAL_GIT" -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; then bad "$3 (still registered: $2)"; else ok "$3"; fi; }

# ⛔ THE DISK ADMISSION IS NEUTRALISED FOR THIS SUITE (agent-infra#3395), AND THAT IS TEST HYGIENE,
# NOT A CONVENIENCE. `wt_provision` now asks the ONE disk predicate before it creates anything, so
# every arm below would otherwise depend on THIS HOST's free space: measured, on a cell with 8.4 GB
# free the 6 GiB + reserve bound admits, and the same suite on a tighter box (or after its own
# fixtures eat 2 GB) would refuse and report failures about worktrees that were never created.
# That is the exact host-measuring defect `spawn-gate.test.sh` documents for its own `df` stub. The
# gate's own behaviour is pinned in `disk-admission.test.sh`, which STUBS `df` and measures nothing
# about this host; here all THREE terms are zeroed through the documented seams, so these arms test
# the lifecycle and only the lifecycle.
# ⛔ ALL THREE, NOT TWO (review P2, #3409). `disk_worktree_terms` defaults the TREE term to its
# python default (350 MB) whenever `DISK_LANE_TREE_MB` is unstated, so zeroing only self+reserve left
# `need = 350` and this suite still measured the host below a 350 MB floor — measured: a `df` stub
# reporting 100 MB free printed 46 passed / 62 failed, every red on a provision that was merely
# refused. `spawn-gate.test.sh` had always zeroed all three; these exports copied two.
export DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0

REAL_GIT="$(command -v git)" || { echo "FATAL: git is required" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/wt-lifecycle-test.XXXXXX")" || { echo "FATAL: no temp dir" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

OLD_DATE="2026-09-01T00:00:00"
RECENT_DATE="2026-10-17T20:00:00"

# mk_repo <name> — a repo with a bare origin, one commit on main, and `origin/main` fetched.
# Prints the repo path. Claims live in the TARGET repo's origin, and three of the classes below
# consult them, so the origin is not decoration.
mk_repo() {
    local n="$1" d="$T/$1/repo"
    mkdir -p "$d" "$T/$1/home" "$T/$1/state" "$T/$1/bin"
    "$REAL_GIT" init -q --bare "$T/$1/origin.git"
    "$REAL_GIT" init -q -b main "$d"
    "$REAL_GIT" -C "$d" config user.email t@t
    "$REAL_GIT" -C "$d" config user.name t
    printf 'base\n' >"$d/base.txt"
    printf 'keep\n' >"$d/keep.txt"
    "$REAL_GIT" -C "$d" add -A
    GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
        "$REAL_GIT" -C "$d" commit -qm init
    "$REAL_GIT" -C "$d" remote add origin "$T/$1/origin.git"
    "$REAL_GIT" -C "$d" push -q origin main
    "$REAL_GIT" -C "$d" fetch -q origin
    printf '%s\n' "$d"
}

# in_wt <repo> <script> — source the library in a subshell rooted at <repo> and run <script>.
# Every git call inside the library is then relative to that repo, exactly as in production.
in_wt() {
    ( cd "$2" && WT_GIT="$REAL_GIT" bash -c ". '$WTL' || exit 99; $1" )
}

# ── the LANE ARMS MUST SUPPLY MAIN'S CREATION-GATE READING (#2409) ────────────────────────────────
# L6/L7 execute the SHIPPED `lane.sh`, and `run_agent` now measures the repo's landing ratio before
# it starts a CREATION worker (`KIND=lane`): it DERIVES `owner/name` from the worktree's `origin` and
# REFUSES when it cannot (spawn-gate.sh `land_backlog_repo` → rc 74). Both of those are deliberate
# main-side decisions (repo-slug.sh refuses a local-path remote ON PURPOSE, and UNREADABLE must HOLD,
# never read as OK), so the FIXTURE is what has to look like a box — not the gate.
#
# ⛔ WITHOUT THIS THE ARMS PASS FOR THE WRONG REASON, WHICH IS HOW THIS WAS FOUND. `mk_repo` builds a
# LOCAL bare origin, so the gate refused at `land-backlog` BEFORE any agent ran: the stub `pi` never
# committed, and L7's three assertions then failed on a lane that never spawned (the trap had
# correctly reaped a genuinely 0-commit worktree). L6 passed — but only because its assertion is
# "the trap removed it", which a refusal satisfies too.
#
# The reading is SUPPLIED THE WAY A BOX SUPPLIES IT, following capacity-transfer.test.sh §LB: install
# the REST adapter at `$O/gh-rest/gh`, which `lane.sh` prepends to PATH (install.sh ships it, and it
# is in the drift list). There is deliberately NO env seam that switches the gate off — review cycle 1
# reproduced one opening the gate on a repo with 82 open PRs — so a stub ADAPTOR is the only shape
# that both answers the read and leaves the gate itself under test.
#
# The two reads: the OPEN pull count (floored at `--jq length`) and the recent MERGED close-count.
# 0 open / 0 landings is UNDER the ceiling (floored at 5), so creation is ALLOWED — the state these
# arms need in order to reach the agent at all.
mk_lane_box() { # <env-dir> <repo> -> repo with a GitHub-shaped origin and an answering gh adapter
    local e="$1" repo="$2"
    mkdir -p "$e/gh-rest"
    cat >"$e/gh-rest/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'pulls?state=open'*)   printf '0\n' ;;   # under the ceiling (floored at 5) -> creation allowed
  *'pulls?state=closed'*) : ;;             # no merged closes read -> landings 0
  *) : ;;
esac
exit 0
SH
    chmod +x "$e/gh-rest/gh"
    # The SLUG is what the gate parses, and it reads `remote.origin.url` only — nothing in L6/L7
    # touches the network (wt_reap_if_empty reads the LOCAL `refs/remotes/origin/<br>`, never
    # ls-remote), so repointing origin here cannot make the arms reach out. Every other arm keeps
    # mk_repo's local bare origin, because THOSE do push and fetch.
    #
    # ⛔ AND THE LANE MUST BE TOLD THE **SAME** SLUG. `lane.sh` now asserts the checkout's own origin
    # against the target before it starts anything (#2724/#2694), so invoking it with a made-up
    # `owner/repo` while this box's origin is `$LANE_OR` makes it refuse with `repo-target REFUSED`
    # (exit 72) — and the trap then reaps the empty checkout, which L6's assertions would read as "the
    # trap worked" and L7's as "the lane produced nothing". Measured 2026-10-28: 4 arms red for a
    # reason none of them tests. One constant, used by both.
    "$REAL_GIT" -C "$repo" remote set-url origin "https://github.com/$LANE_OR.git"
}

# mk_failing_git <dir> <repo> <branch> — a `git` that performs the real `worktree add`, then makes
# the result the MEASURED residue (lock = initializing, files missing) and exits 1. Everything else
# is passed straight through, so `wt_rollback` runs against real git.
mk_failing_git() {
    local dir="$1" repo="$2" br="$3"
    cat >"$dir/git-fail-add" <<SH
#!/bin/bash
real='$REAL_GIT'
"\$real" "\$@"; rc=\$?
# The library invokes git as `git -C <repo> worktree add …`, so the verb is NOT \$1/\$2 — a wrapper
# that tested those positions would never fire and the fixture would pass while proving nothing.
prev=""; is_add=0
for a in "\$@"; do
  [ "\$prev" = worktree ] && [ "\$a" = add ] && is_add=1
  prev="\$a"
done
if [ "\$is_add" = 1 ]; then
  # ⛔ THE DEAD `gd=` LINE IS GONE ON PURPOSE. It was a dead assignment whose glob+quoting
  # (`-C '$repo/.worktrees/'*' rev-parse …`) made the GENERATED script a syntax error: bash runs
  # lines 1..N before it parses the broken one, so the real `worktree add` DID run, then the wrapper
  # died with rc 2 — and every `wt_git` call after it failed. The fixture both manufactured the
  # residue and reported a failure the library had not caused, which is the opposite of a fixture.
  # Verified with `bash -n` on the generated file (asserted below).
  # The record git leaves while the checkout is in flight, and a partially materialised tree.
  for d in '$repo'/.git/worktrees/*; do
    [ -d "\$d" ] || continue
    echo initializing >"\$d/locked" 2>/dev/null || true
  done
  rm -f '$repo'/.worktrees/*/keep.txt 2>/dev/null || true
  exit 1
fi
exit \$rc
SH
    chmod +x "$dir/git-fail-add"
    printf '%s\n' "$dir/git-fail-add"
}

echo "── wt-lifecycle.test.sh ────────────────────────────────────────────"

# ── W1: a clean provision creates a usable worktree on a new branch ────
ENV=W1; REPO="$(mk_repo $ENV)"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-1 feat/1-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "W1 a fresh provision succeeds"
assert_contains "$OUT" "WT_RESULT=created" "W1 the result names what it did"
assert_dir "$REPO/.worktrees/tm-1" "W1 the worktree directory exists"
assert_branch "$REPO" feat/1-tm "W1 the branch exists"
assert_registered "$REPO" "$REPO/.worktrees/tm-1" "W1 the record is registered"
assert_eq "$("$REAL_GIT" -C "$REPO/.worktrees/tm-1" symbolic-ref --short HEAD)" "feat/1-tm" \
    "W1 the checkout is ON the lane branch"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse feat/1-tm)" "$("$REAL_GIT" -C "$REPO" rev-parse origin/main)" \
    "W1 the branch starts at origin/main"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-1 feat/1-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "W1 a second call is idempotent"
assert_contains "$OUT" "WT_RESULT=reused" "W1 the second call REUSES (it does not re-create)"

# ── W2: a FAILED `worktree add` leaves NOTHING (the measured residue) ───
# Before: the branch survives with 0 commits ahead, the directory is half-materialised, the record
# is registered and locked. After: no branch, no directory, no record — verified by the function.
ENV=W2; REPO="$(mk_repo $ENV)"
FAILGIT="$(mk_failing_git "$T/$ENV/bin" "$REPO" feat/2-tm)"
OUT="$( cd "$REPO" && WT_GIT="$FAILGIT" bash -c ". '$WTL' || exit 99; wt_provision '$REPO' .worktrees/tm-2 feat/2-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" )"
assert_contains "$OUT" "rc=1" "W2 a failed add reports failure (not success)"
assert_contains "$OUT" "worktree add failed" "W2 the result names the failed add"
assert_contains "$OUT" "rolled back" "W2 the rollback verified the empty end state"
assert_nodir "$REPO/.worktrees/tm-2" "W2 no half-materialised directory survives"
assert_nobranch "$REPO" feat/2-tm "W2 no 0-commit branch survives (the pre-flight surface)"
assert_unregistered "$REPO" "$REPO/.worktrees/tm-2" "W2 no admin record survives"
# ⛔ PIN THE FIXTURE'S OWN VALIDITY. This arm's first draft emitted a fake `git` with an unbalanced
# quote: it was a syntax error, so the wrapper died on EVERY call (after running the real verb), the
# library was blamed for the resulting state, and the arm "failed" for a reason unrelated to the code
# under test. A one-line parse check makes a broken fixture name itself.
bash -n "$FAILGIT" && ok "W2 the failing-git fixture itself parses" || bad "W2 the failing-git fixture does not parse"
# the FALSIFIER: the same wrapper run directly DOES leave the residue, so the assertions above are
# about the rollback and not about a fixture that never made any.
grep -q . "$FAILGIT" && ok "W2 falsifier: the failing-git fixture exists"
"$FAILGIT" -C "$REPO" worktree add "$REPO/.worktrees/tm-2b" -b feat/2b-tm origin/main >/dev/null 2>&1
assert_branch "$REPO" feat/2b-tm "W2 falsifier: an unrolled-back failed add DOES leave the branch"
assert_registered "$REPO" "$REPO/.worktrees/tm-2b" "W2 falsifier: …and the locked, partial record"
"$REAL_GIT" -C "$REPO" worktree unlock "$REPO/.worktrees/tm-2b" >/dev/null 2>&1
"$REAL_GIT" -C "$REPO" worktree remove --force "$REPO/.worktrees/tm-2b" >/dev/null 2>&1
"$REAL_GIT" -C "$REPO" branch -d feat/2b-tm >/dev/null 2>&1 || true

# ── W3: a pre-existing 0-ahead GHOST branch is cleared, not "branch exists?" ──
# This is the freeze: a leftover branch made `add -b` fail for ever, and the caller skipped the issue.
ENV=W3; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" branch feat/3-tm origin/main
assert_branch "$REPO" feat/3-tm "W3 precondition: the ghost branch exists with 0 commits ahead"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-list --count "origin/main..feat/3-tm")" "0" \
    "W3 precondition: it really is 0 commits ahead"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-3 feat/3-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "W3 the issue is provisionable again (was: skipped for ever)"
assert_contains "$OUT" "ghost" "W3 the ghost branch is NAMED as such in the log"
assert_dir "$REPO/.worktrees/tm-3" "W3 a usable worktree now exists"
assert_branch "$REPO" feat/3-tm "W3 the branch exists again (re-created from origin/main)"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse feat/3-tm)" "$("$REAL_GIT" -C "$REPO" rev-parse origin/main)" \
    "W3 it was re-created at origin/main (nothing was carried over)"

# ── W4: an existing branch WITH commits is ATTACHED, never deleted ────
ENV=W4; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" branch feat/4-tm origin/main
"$REAL_GIT" -C "$REPO" worktree add -q "$T/$ENV/scratch" feat/4-tm
printf 'real work\n' >"$T/$ENV/scratch/w.txt"
"$REAL_GIT" -C "$T/$ENV/scratch" add w.txt
"$REAL_GIT" -C "$T/$ENV/scratch" commit -qm "wip 4"
"$REAL_GIT" -C "$REPO" worktree remove "$T/$ENV/scratch"
W4_TIP="$("$REAL_GIT" -C "$REPO" rev-parse feat/4-tm)"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-4 feat/4-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "W4 an existing branch with commits is usable"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse feat/4-tm)" "$W4_TIP" \
    "W4 the branch tip is UNCHANGED (its commits were not thrown away)"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-list --count "origin/main..feat/4-tm")" "1" \
    "W4 the lane's commit is still there (1 ahead)"
assert_contains "$OUT" "WT_RESULT=created" "W4 it was materialised as a worktree"

# ── W5: an INTERRUPTED add is repaired instead of trusted ──────────────
# The measured record: registered, locked `initializing`, partial tree. The old caller's
# directory-name probe read it as "already provisioned" and spawned the lane into it.
ENV=W5; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" worktree add -q "$REPO/.worktrees/tm-5" -b feat/5-tm origin/main
GD="$("$REAL_GIT" -C "$REPO/.worktrees/tm-5" rev-parse --path-format=absolute --git-dir)"
printf 'initializing\n' >"$GD/locked"
touch -t 202609011200 "$GD/locked"
rm -f "$REPO/.worktrees/tm-5/keep.txt"
assert_registered "$REPO" "$REPO/.worktrees/tm-5" "W5 precondition: the half-made record is registered"
OUT="$( cd "$REPO" && WT_GIT="$REAL_GIT" WT_INIT_LOCK_MIN_AGE=60 bash -c ". '$WTL' || exit 99; wt_provision '$REPO' .worktrees/tm-5 feat/5-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" )"
assert_contains "$OUT" "rc=0" "W5 the interrupted add is repaired"
assert_contains "$OUT" "INTERRUPTED" "W5 the repair is announced (not a silent reuse)"
assert_file "$REPO/.worktrees/tm-5/keep.txt" "W5 the checkout is COMPLETE again"
assert_dir "$REPO/.worktrees/tm-5" "W5 the worktree exists"
assert_eq "$("$REAL_GIT" -C "$REPO/.worktrees/tm-5" status --porcelain | wc -l | tr -d ' ')" "0" \
    "W5 and it is clean (no phantom deletions)"

# ── W6: an ACTIVE lock (`initializing` but young) is REFUSED, not reused ───────
ENV=W6; REPO="$(mk_repo $ENV)"
"$REAL_GIT" -C "$REPO" worktree add -q "$REPO/.worktrees/tm-6" -b feat/6-tm origin/main
GD="$("$REAL_GIT" -C "$REPO/.worktrees/tm-6" rev-parse --path-format=absolute --git-dir)"
printf 'initializing\n' >"$GD/locked"
# ⛔ THIS ARM'S EXPECTATION WAS INVERTED (#2102 review P1, MEASURED). It used to assert `rc=0` +
# `reused` for a young `initializing` lock — "an add may still be running, leave it alone". But rc=0 is
# the callers' "a USABLE worktree exists at <path>", and a HALF-MATERIALISED checkout answers it,
# because git writes the ref and HEAD BEFORE it populates the tree (the ordering quoted in
# wt-lifecycle.sh's header). Measured on the PRODUCTION default floor (300 s): a record locked
# `initializing` whose tree has every file missing answered `rc=0  WT_RESULT=reused existing
# worktree …`, and dispatch-merge.sh spawned a lane into it — consequence #2 of that header, in
# exactly the window the floor does not cover. The lock is still NOT touched (that is what the floor
# is for), but "not touched" is rc=2, not a claim of usability: the caller releases the claim and
# retries next cycle.
rm -f "$REPO/.worktrees/tm-6/keep.txt"     # the REAL measured residue: a partial tree reads as DELETED
W6_FILES="$(cd "$REPO/.worktrees/tm-6" && ls)"
OUT="$( cd "$REPO" && WT_GIT="$REAL_GIT" WT_INIT_LOCK_MIN_AGE=3600 bash -c ". '$WTL' || exit 99; wt_provision '$REPO' .worktrees/tm-6 feat/6-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" )"
assert_contains "$OUT" "rc=2" "W6 a young 'initializing' lock is REFUSED, never reported usable"
assert_contains "$OUT" "initializing" "W6 the refusal names the lock as the reason"
case "$OUT" in *"WT_RESULT=reused"*) bad "W6 a half-materialised checkout was reported as a REUSABLE worktree" ;;
                 *) ok "W6 …and it is never spelled 'reused' (rc=0 means usable; this is not)" ;; esac
assert_eq "$(cd "$REPO/.worktrees/tm-6" && ls)" "$W6_FILES" \
    "W6 nothing was created, repaired or deleted while an add may still be running"
assert_dir "$REPO/.worktrees/tm-6" "W6 the record survives (the floor is not a licence to reap it)"
assert_branch "$REPO" feat/6-tm "W6 the branch survives too"

# ── W7: a path occupied by an unregistered directory is REFUSED ────────
ENV=W7; REPO="$(mk_repo $ENV)"
mkdir -p "$REPO/.worktrees/tm-7"
printf 'operator data\n' >"$REPO/.worktrees/tm-7/precious.txt"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-7 feat/7-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=2" "W7 an unregistered directory is refused (nothing created)"
assert_contains "$OUT" "refusing to touch it" "W7 the refusal is explicit"
if [ -f "$REPO/.worktrees/tm-7/precious.txt" ]; then ok "W7 the operator's directory is intact"; else bad "W7 the operator's directory was DESTROYED"; fi

# ── W8: the branch is checked out ELSEWHERE => rc=2, never "reused" ────
# #2102 review §3. `wt_provision` resolves a worktree BY BRANCH, anywhere, so a branch already
# checked out at `.worktrees/fix-9` (fix-one.sh's path, keyed on the same PR head branch) made a
# request for `.worktrees/tm-9` return rc=0 + "reused existing worktree …/fix-9". `dispatch-merge.sh`
# trusts rc=0 and hard-codes its OWN path, so `cd .worktrees/tm-9` failed and the tmux session exited
# instantly — `tmux new-session -d` still returned 0, the dispatcher printed "lane-N (implement+PR)",
# deliberately did not release the claim, and chain-N waited 90 minutes for a PR nothing was working
# on. Pre-PR the same input failed closed ("branch exists" → release + continue), so rc=0 at a path
# that does not exist is the regression this arm pins.
ENV=W8; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/fix-9 feat/9-tm origin/main" "$REPO" >/dev/null
assert_dir "$REPO/.worktrees/fix-9" "W8 the branch is first provisioned at a DIFFERENT path"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-9 feat/9-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=2" "W8 a request for a path it did not materialise is REFUSED (rc=2)"
assert_contains "$OUT" "already checked out at" "W8 the refusal names where the branch actually is"
assert_nodir "$REPO/.worktrees/tm-9" "W8 no worktree was created at the requested path"
assert_dir "$REPO/.worktrees/fix-9" "W8 the existing checkout is untouched"
assert_eq "$("$REAL_GIT" -C "$REPO" worktree list --porcelain | grep -c '^worktree ')" "2" \
    "W8 no second record was registered (main + fix-9 only)"
# …and the SAME path still reuses (rc=0), so the refusal above is about the PATH, not the branch.
OUT="$(in_wt "wt_provision '$REPO' .worktrees/fix-9 feat/9-tm origin/main; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "W8 asking for the path the branch IS at still succeeds"
assert_contains "$OUT" "WT_RESULT=reused" "W8 …and reports a reuse"

# ── L-series: the lane's own exit path (wt_reap_if_empty) ──────────────
echo "the lane exit path (a lane that produced nothing takes its checkout back)"

# ── L1: nothing produced => worktree AND branch gone ───────────────────
ENV=L1; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-10 feat/10-tm origin/main" "$REPO" >/dev/null
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-10' feat/10-tm 'lane 10'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L1 an empty lane reclaims its own checkout"
assert_contains "$OUT" "produced no commits" "L1 the result says why"
assert_nodir "$REPO/.worktrees/tm-10" "L1 the worktree is gone"
assert_nobranch "$REPO" feat/10-tm "L1 the 0-ahead branch is gone (the pre-flight surface)"
assert_unregistered "$REPO" "$REPO/.worktrees/tm-10" "L1 the record is gone"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-10' feat/10-tm 'lane 10'; echo rc=\$?" "$REPO")"
assert_contains "$OUT" "rc=0" "L1 a second call is a no-op success (idempotent)"

# ── L2: commits ahead => PRESERVED ─────────────────────────────────────
ENV=L2; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-11 feat/11-tm origin/main" "$REPO" >/dev/null
printf 'wip\n' >"$REPO/.worktrees/tm-11/w.txt"
"$REAL_GIT" -C "$REPO/.worktrees/tm-11" add w.txt
"$REAL_GIT" -C "$REPO/.worktrees/tm-11" commit -qm "wip 11"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-11' feat/11-tm 'lane 11'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L2 a lane with a commit is preserved"
assert_contains "$OUT" "ahead" "L2 the reason names the commits"
assert_dir "$REPO/.worktrees/tm-11" "L2 the worktree (and therefore the work) survives"
assert_branch "$REPO" feat/11-tm "L2 the branch survives"

# ── L3: a DIRTY tree (no commit ever made) => PRESERVED ────────────────
# This is the 24-row class measured on the laptop: the only copy of that work is the working tree.
# The dying lane must NOT delete it (backup-then-remove is the reaper's policy, not the lane's).
ENV=L3; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-12 feat/12-tm origin/main" "$REPO" >/dev/null
printf 'uncommitted\n' >"$REPO/.worktrees/tm-12/wip.txt"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-12' feat/12-tm 'lane 12'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L3 a dirty tree is preserved"
assert_contains "$OUT" "DIRTY" "L3 the reason is the dirt (the work is the uncommitted file)"
assert_eq "$(cat "$REPO/.worktrees/tm-12/wip.txt" 2>/dev/null)" "uncommitted" "L3 the uncommitted work is still there"
assert_branch "$REPO" feat/12-tm "L3 the branch is kept with it"

# ── L3b: gitignored DATA also preserves (git would delete it silently) ─
ENV=L3b; REPO="$(mk_repo $ENV)"
printf '*.env\n' >"$REPO/.gitignore"
"$REAL_GIT" -C "$REPO" add .gitignore
"$REAL_GIT" -C "$REPO" commit -qm "ignore env"
"$REAL_GIT" -C "$REPO" push -q origin main
in_wt "wt_provision '$REPO' .worktrees/tm-12b feat/12b-tm origin/main" "$REPO" >/dev/null
printf 'SECRET=1\n' >"$REPO/.worktrees/tm-12b/prod.env"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-12b' feat/12b-tm 'lane 12b'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L3b an ignored non-regenerable file preserves the checkout"
assert_contains "$OUT" "ignored" "L3b the reason names the ignored data"
assert_eq "$(cat "$REPO/.worktrees/tm-12b/prod.env" 2>/dev/null)" "SECRET=1" "L3b the ignored data is intact"

# ── L3c: a declared-ephemeral `.venv` is disposable, not dirt ──────────
ENV=L3c; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-12c feat/12c-tm origin/main" "$REPO" >/dev/null
mkdir -p "$REPO/.worktrees/tm-12c/.venv/bin"
printf 'x\n' >"$REPO/.worktrees/tm-12c/.venv/bin/python"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-12c' feat/12c-tm 'lane 12c'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L3c a root-level .venv does not block the reap"
assert_nodir "$REPO/.worktrees/tm-12c" "L3c the checkout (with its venv) is gone"

# ── L4: a PUSHED branch => PRESERVED (it may back an open PR) ──────────
ENV=L4; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-13 feat/13-tm origin/main" "$REPO" >/dev/null
"$REAL_GIT" -C "$REPO" push -q origin feat/13-tm
"$REAL_GIT" -C "$REPO" fetch -q origin
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-13' feat/13-tm 'lane 13'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L4 a pushed branch preserves the checkout"
assert_contains "$OUT" "origin/feat/13-tm exists" "L4 the reason names the upstream"
assert_dir "$REPO/.worktrees/tm-13" "L4 the worktree survives"

# ── L5: a LIVE HOLDER => PRESERVED (never touch a path in use) ─────────
ENV=L5; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-14 feat/14-tm origin/main" "$REPO" >/dev/null
( cd "$REPO/.worktrees/tm-14" && exec sleep 60 ) &
HOLDER=$!
sleep 0.4
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-14' feat/14-tm 'lane 14'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5 a live process holding the path preserves it"
assert_contains "$OUT" "live process" "L5 the reason names the holder"
assert_contains "$OUT" "pid $HOLDER" "L5 and names the pid"
assert_dir "$REPO/.worktrees/tm-14" "L5 the live checkout survives"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-14' feat/14-tm 'lane 14'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L5 once the holder is gone, the same call reaps"

# ── L5b: a DETACHED-HEAD commit is PRESERVED, never orphaned ──────────────
# ⛔ #2102 review P1, MEASURED. Every gate below used to ask only about `refs/heads/$br`; not one asked
# what the checkout was checked out ON. So a lane that left HEAD detached and committed its work there
# passed them all — clean tree, `$br` still at the base (0 ahead), never pushed — and the checkout was
# removed and the branch CAS-deleted, leaving the lane's commit reachable from NOTHING while the log
# said "produced no commits". The reviewed reaper already treats this class as PRESERVE
# (`detached-unreachable`); this arm pins the same rule at the lane's own exit seam.
ENV=L5b; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-15 feat/15-tm origin/main" "$REPO" >/dev/null
"$REAL_GIT" -C "$REPO/.worktrees/tm-15" checkout -q --detach origin/main
printf 'lane work\n' >"$REPO/.worktrees/tm-15/w.txt"
"$REAL_GIT" -C "$REPO/.worktrees/tm-15" add w.txt
"$REAL_GIT" -C "$REPO/.worktrees/tm-15" commit -qm "lane 15 detached work"
L5B_SHA="$("$REAL_GIT" -C "$REPO/.worktrees/tm-15" rev-parse HEAD)"
L5B_AHEAD="$("$REAL_GIT" -C "$REPO" rev-list --count "origin/main..refs/heads/feat/15-tm")"
assert_eq "$L5B_AHEAD" "0" "L5b precondition: the NAMED branch is 0 ahead (so every other gate would pass)"
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-15' feat/15-tm 'lane 15'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5b a DETACHED-HEAD commit preserves the checkout"
assert_contains "$OUT" "DETACHED" "L5b the reason says the HEAD is detached (not that the lane was empty)"
assert_dir "$REPO/.worktrees/tm-15" "L5b the checkout survives (the commit inside it is the only copy)"
assert_branch "$REPO" feat/15-tm "L5b the branch survives too"
if "$REAL_GIT" -C "$REPO" cat-file -e "$L5B_SHA" 2>/dev/null; then ok "L5b the lane's commit still exists"; else bad "L5b the lane's commit was DESTROYED"; fi
if [ -n "$("$REAL_GIT" -C "$REPO/.worktrees/tm-15" rev-parse --verify -q HEAD)" ]; then
  ok "L5b …and it is still checked out somewhere (not merely an object)"; else bad "L5b the lane's work was left dangling"; fi

# ── L5c: the same checkout, EMPTY, still reaps when nothing can be lost ──
# The guard must not be a blanket "detached ⇒ keep": a lane that detached and committed NOTHING sits
# on a commit a surviving ref already holds (the base tip), so removing it cannot orphan anything —
# and keeping it would leave exactly the residue #2033 exists to remove.
ENV=L5c; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-16 feat/16-tm origin/main" "$REPO" >/dev/null
"$REAL_GIT" -C "$REPO/.worktrees/tm-16" checkout -q --detach origin/main
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-16' feat/16-tm 'lane 16'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L5c a detached HEAD at a commit a survivor holds is still reapable"
assert_nodir "$REPO/.worktrees/tm-16" "L5c the empty checkout is gone (no residue left behind)"
assert_nobranch "$REPO" feat/16-tm "L5c and its 0-ahead branch with it"

# ── L5d: a checkout on ANOTHER branch is PRESERVED ─────────────────────────
# The other half of the same blind spot: the directory is a worktree of somebody else's branch. Removing
# it loses that checkout (and any stash/scratch state) while the log would call the lane empty.
ENV=L5d; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-17 feat/17-tm origin/main" "$REPO" >/dev/null
"$REAL_GIT" -C "$REPO" branch feat/other-17 origin/main
"$REAL_GIT" -C "$REPO/.worktrees/tm-17" checkout -q feat/other-17
OUT="$(in_wt "wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-17' feat/17-tm 'lane 17'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5d a checkout on ANOTHER branch is preserved"
assert_contains "$OUT" "feat/other-17" "L5d the reason names the branch it is actually on"
assert_dir "$REPO/.worktrees/tm-17" "L5d the checkout survives"

# ── L5e: a cwd-ONLY holder keeps the checkout where `lsof` is absent (#2744) ─────────────────
# ⛔ THE DEFECT. The cwd witness used to be `lsof`-only, and an absent `lsof` returned "no holder" — so
# on a slim Linux image the one process shape #2744 is about (`pi` sitting in the checkout with a cwd
# inside it and a command line that never names the path) was INVISIBLE, and the dispatcher's take-back
# deleted the live lane's tree with no error. The reaper on the same box, in the same minute, classified
# the same path `preserve reason=live-cwd`, because IT reads `/proc/<pid>/cwd`. The predicate already
# existed; the dispatch path did not apply it.
# ⛔ THE TABLE IS A FIXTURE, NOT THIS HOST. `WT_PROC_ROOT` points the arm at a directory of
# `<pid>/cwd` symlinks and `WT_LSOF` at a binary that does not exist, so the arm states the same thing
# on macOS (no /proc) as on Linux and measures no real process on the runner.
ENV=L5e; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"
in_wt "wt_provision '$REPO' .worktrees/tm-18 feat/18-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "$REPO/.worktrees/tm-18" "$FAKE/4242/cwd"   # pid 4242's cwd IS the checkout
ln -sfn "$FAKE" "$FAKE/self/cwd"                     # the arm is only taken where `self/cwd` is a link
OUT="$(in_wt "WT_PROC_ROOT='$FAKE'; WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-18' feat/18-tm 'lane 18'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5e with no lsof, a /proc cwd-only holder still preserves the checkout"
assert_contains "$OUT" "pid 4242" "L5e and names the pid that holds it"
assert_contains "$OUT" "cwd-inside-the-worktree" "L5e …by the cwd witness, not by argv"
assert_dir "$REPO/.worktrees/tm-18" "L5e the live checkout survives (#2744)"
assert_branch "$REPO" feat/18-tm "L5e and so does its branch"

# ── L5e2: the same fixture, row names a DIFFERENT path → still reaps (non-vacuity) ──────────────
# Without this the arm above would pass for a "any row at all blocks the reap" bug, which would make
# every checkout on the box unreapable the moment one process existed.
ENV=L5e2; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"
in_wt "wt_provision '$REPO' .worktrees/tm-19 feat/19-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "/some/other/tree" "$FAKE/4242/cwd"
ln -sfn "$FAKE" "$FAKE/self/cwd"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE'; WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-19' feat/19-tm 'lane 19'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L5e2 a cwd row OUTSIDE the checkout does not block the reap"
assert_nodir "$REPO/.worktrees/tm-19" "L5e2 the empty checkout is reaped"

# ── L5f: with NEITHER witness available the verdict must SAY so ───────────────────────────────
# The degraded tolerance is deliberate (refusing for ever would keep every worktree), but a reap that
# proceeded without the witness that catches #2744 must not read as a clean bill of health: the line is
# the only record, and `dispatch-merge.sh` prints `WT_RESULT` straight into the dispatch log.
ENV=L5f; REPO="$(mk_repo $ENV)"
in_wt "wt_provision '$REPO' .worktrees/tm-20 feat/20-tm origin/main" "$REPO" >/dev/null
OUT="$(in_wt "WT_PROC_ROOT='$T/$ENV/no-such-proc'; WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$REPO/.worktrees/tm-20' feat/20-tm 'lane 20'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=0" "L5f with no /proc and no lsof the empty checkout is still reaped"
assert_contains "$OUT" "cwd witness is UNAVAILABLE" "L5f …and the verdict discloses that one witness never ran"
assert_contains "$OUT" "#2744" "L5f …naming what that gap would have missed"

# ── L5g: the ambient `QUOTING_STYLE` cannot disarm the census (#2744 review, P1 MEASURED) ──────
# ⛔ THE DEFECT (reproduced before this arm existed, on this fixture shape). `ls` quotes names
# according to the AMBIENT `QUOTING_STYLE` environment variable, and both useful styles defeated the
# parse in opposite directions — which is why one arm cannot pin it:
#   `c`      wraps the link name AND the target, so NO row is produced → the census reads as "no
#            witness" → the caller reaps. Measured: rc=0, `WT_RESULT=reaped …`, directory GONE,
#            holder pid still alive.
#   `escape` produces a row whose target reads `…/re\ po\ wt` — PRESENT, but it can never equal the
#            checkout path, so it silently matches nothing and the reap carries NO disclosure at all.
# The checkout path therefore carries a SPACE: that is the input which makes quoting visible, and
# without it both styles would produce the same bytes as the literal style. An ambient env var must
# not be able to disarm a gate (the `bypass by ambient env` class), so the census forces the style.
ENV=L5g; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/re po wt"
in_wt "wt_provision '$REPO' '.worktrees/re po wt' feat/18-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "$WTP" "$FAKE/4242/cwd"
ln -sfn "$FAKE" "$FAKE/self/cwd"
OUT="$(in_wt "export QUOTING_STYLE=c WT_PROC_ROOT='$FAKE' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/18-tm 'lane 18'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5g QUOTING_STYLE=c cannot make the census unreadable"
assert_contains "$OUT" "pid 4242" "L5g …the cwd holder is still named, by pid"
assert_dir "$WTP" "L5g the live checkout survives an ambient QUOTING_STYLE (#2744)"
OUT="$(in_wt "export QUOTING_STYLE=escape WT_PROC_ROOT='$FAKE' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/18-tm 'lane 18'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5g2 QUOTING_STYLE=escape cannot turn the row into a path that never matches"
assert_contains "$OUT" "pid 4242" "L5g2 …the cwd holder is still named, by pid"
assert_dir "$WTP" "L5g2 the live checkout survives an escaped target (#2744)"

# ── L5h: a census that RUNS but yields nothing usable is FAIL-CLOSED, not "unavailable" ──
# ⛔ THE DEFECT (P1 MEASURED). "No witness on this host" (tolerated, disclosed, reap proceeds) and
# "this witness ran and its output cannot be trusted" were collapsed into one return code, so any
# unparsable census licensed a deletion. The two facts are now different codes, and this arm pins the
# one that deletes work if it is wrong: the probe produced bytes and NOT ONE usable row.
ENV=L5h; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/tm-21"
GARBAGE="$T/$ENV/garbage-ls"
in_wt "wt_provision '$REPO' .worktrees/tm-21 feat/21-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "$WTP" "$FAKE/4242/cwd"
ln -sfn "$FAKE" "$FAKE/self/cwd"
printf '#!/bin/sh\necho "total 0"\necho "not a table at all"\n' >"$GARBAGE"; chmod +x "$GARBAGE"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE' WT_LS='$GARBAGE' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/21-tm 'lane 21'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5h an unparsable census PRESERVES the checkout (fail-closed, not 'unavailable')"
assert_contains "$OUT" "cwd census produced nothing usable" "L5h …and the verdict names the census, not a generic phrase"
assert_dir "$WTP" "L5h the live checkout survives an unparsable census (#2744 review)"
assert_branch "$REPO" feat/21-tm "L5h …and so does its branch"

# ── L5i: a census the WATCHDOG killed is fail-closed too ────────────────────────────────────────
# ⛔ THE DEFECT (P2 MEASURED). `wt_run_bounded` DELETES the partial table on timeout, so an unchecked
# rc read exactly like a successful scan that found nobody: measured rc 3 ("unavailable") and the
# checkout was deleted while its holder was alive. A probe that never finished decided a deletion.
ENV=L5i; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/tm-22"
SLOWLS="$T/$ENV/slow-ls"
in_wt "wt_provision '$REPO' .worktrees/tm-22 feat/22-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "$WTP" "$FAKE/4242/cwd"
ln -sfn "$FAKE" "$FAKE/self/cwd"
printf '#!/bin/sh\nsleep 5\nexec /bin/ls "$@"\n' >"$SLOWLS"; chmod +x "$SLOWLS"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE' WT_LS='$SLOWLS' WT_LSOF=/nonexistent-lsof WT_PROBE_SECONDS=1; wt_reap_if_empty '$REPO' '$WTP' feat/22-tm 'lane 22'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5i a census the watchdog killed PRESERVES the checkout"
assert_contains "$OUT" "could not be evaluated" "L5i …and says the probe could not be evaluated"
assert_dir "$WTP" "L5i the live checkout survives a timed-out census (#2744 review)"

# ── L5j: the lsof arm's `-Fpn` pairing, and the `(deleted)` strip, are covered at all ──────
# Neither was exercised by any arm before this one (#2744 review, finding 6): the lsof fallback is
# what runs on macOS and in a container with no /proc, and the ` (deleted)` suffix is what a process
# whose checkout was already removed still reports — the shape that must stay BLOCKING.
ENV=L5j; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/tm-23"
FAKELSOF="$T/$ENV/fake-lsof"
in_wt "wt_provision '$REPO' .worktrees/tm-23 feat/23-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/self"
ln -sfn "$FAKE" "$FAKE/self/cwd"
printf '#!/bin/sh\nprintf "p4242\\nn%s\\np9999\\nn/somewhere/else\\n"\n' "$WTP" >"$FAKELSOF"; chmod +x "$FAKELSOF"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE' WT_LS=/nonexistent-ls WT_LSOF='$FAKELSOF'; wt_reap_if_empty '$REPO' '$WTP' feat/23-tm 'lane 23'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5j the lsof -Fpn fallback sees a holder inside the checkout"
assert_contains "$OUT" "pid 4242" "L5j …and names it (p/n rows paired correctly)"
assert_contains "$OUT" "cwd-inside-the-worktree" "L5j …by the cwd witness"
assert_dir "$WTP" "L5j the live checkout survives the lsof arm"

# ── L5k: ` (deleted)` is STRIPPED, so an already-removed-then-recreated path still blocks ──────
ENV=L5k; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/tm-24"
in_wt "wt_provision '$REPO' .worktrees/tm-24 feat/24-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/4242" "$FAKE/self"
ln -sfn "$WTP (deleted)" "$FAKE/4242/cwd"
ln -sfn "$FAKE" "$FAKE/self/cwd"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/24-tm 'lane 24'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5k a ' (deleted)' target still names the checkout and blocks the reap"
assert_contains "$OUT" "pid 4242" "L5k …naming the pid"
assert_dir "$WTP" "L5k the checkout survives"

# ── L5l: an UNREADABLE row (another uid) must not throw the readable rows away ────────────────
# `ls -l /proc/[0-9]*/cwd` exits 2 on any shared box while listing every link it could read, and an
# unreadable link prints no ` -> ` at all. The holder must still be found in the same table.
ENV=L5l; REPO="$(mk_repo $ENV)"; FAKE="$T/$ENV/fakeproc"; WTP="$REPO/.worktrees/tm-25"
MIXEDLS="$T/$ENV/mixed-ls"
in_wt "wt_provision '$REPO' .worktrees/tm-25 feat/25-tm origin/main" "$REPO" >/dev/null
mkdir -p "$FAKE/self"
ln -sfn "$FAKE" "$FAKE/self/cwd"
printf '#!/bin/sh\nprintf "lrwxrwxrwx 1 root root 0 Nov 10 20:00 %s/1111/cwd\\nlrwxrwxrwx 1 root root 0 Nov 10 20:00 %s/4242/cwd -> %s\\n"\nexit 2\n' "$FAKE" "$FAKE" "$WTP" >"$MIXEDLS"; chmod +x "$MIXEDLS"
OUT="$(in_wt "WT_PROC_ROOT='$FAKE' WT_LS='$MIXEDLS' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/25-tm 'lane 25'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5l a partial census (rc=2 from ls) still finds the holder it could read"
assert_contains "$OUT" "pid 4242" "L5l …and names it"
assert_dir "$WTP" "L5l the live checkout survives"

# ── L5m: a HALF-RUN probe that PRESERVES must disclose it too ─────────────────────────────────
# The disclosure used to ride only the REAP verdict, so exactly the paths an operator reads when a
# checkout will not go away were the ones that said nothing about the missing witness (#2744 review P3).
ENV=L5m; REPO="$(mk_repo $ENV)"; WTP="$REPO/.worktrees/tm-26"
in_wt "wt_provision '$REPO' .worktrees/tm-26 feat/26-tm origin/main" "$REPO" >/dev/null
printf 'uncommitted\n' >"$WTP/scratch.txt"
OUT="$(in_wt "WT_PROC_ROOT='$T/$ENV/no-such-proc' WT_LSOF=/nonexistent-lsof; wt_reap_if_empty '$REPO' '$WTP' feat/26-tm 'lane 26'; echo rc=\$?; echo \"WT_RESULT=\$WT_RESULT\"" "$REPO")"
assert_contains "$OUT" "rc=1" "L5m a dirty tree with no cwd witness is preserved"
assert_contains "$OUT" "DIRTY" "L5m …for its own reason"
assert_contains "$OUT" "cwd witness is UNAVAILABLE" "L5m …AND the preserve verdict discloses the missing witness"
assert_contains "$OUT" "#2744" "L5m …naming what that gap would have missed"

# ⛔ L6/L7 ALSO PIN `MAX_LOAD`, AND THAT IS THE SAME CLASS OF FIXTURE DEFECT (measured 2026-11-03 while
# reviewing #3331). Both arms read "the lane REACHED its agent" from the ABSENCE of a land-backlog line,
# so a LOAD refusal (75) — which the ambient load on a busy box produces, with no other symptom — reaps
# the 0-commit worktree and reddens L7's three assertions. The arm is about the EXIT TRAP, not the load
# gate; a fixture whose verdict depends on the runner's 1-minute load average is a false red on a busy
# runner and a false green on an idle one (the rule `capacity-transfer.test.sh` states for the same
# gate). This pins the box to "not loaded" explicitly.
#
# ⛔ L6/L7 DECLARE THE MODEL-CREDENTIAL GATE OFF, BY NAME AND ON PURPOSE (agent-infra#3331). Both arms
# replace `pi` with a STUB, so the credential is not what they measure — and `lane.sh` now asserts the
# credential immediately before it spawns the agent. Without this, the arm's verdict would depend on
# whether the RUNNER has a key (a false red on a fresh box, a false green on a provisioned one) instead
# of on the trap it exists to test. The escape is loud: the lane log carries
# `[key-gate] … check=skipped reason=--key-gate-off`, and `lane-outcome.test.sh` proves the gate refuses
# by default (82) — so this line cannot hide a broken gate, only omit an unrelated assertion.
#
# ⛔ L6/L7 ALSO PIN `ENV_FILE` TO A FIXTURE-OWNED (ABSENT) FILE, FOR THE SAME REASON ONE VARIABLE UP.
# `lane.sh` dots `lane-env.sh`, which sources `${ENV_FILE:-$HOME/keys.env}`, and the CONTROLLER exports
# `ENV_FILE` — so a run on a real box inherits that box's `keys.env`, which carries `PATH` and `HOME`.
# Sourcing it lands AFTER `lane.sh:65` prepended `$O/gh-rest`, so it DISPLACES the fixture's `gh`
# adapter (`mk_lane_box`) and hands the real repository's state to the #2409 creation gate: MEASURED
# 2026-11-04 while rebasing #3342 onto main, both arms refused with `land-backlog] REFUSED` because the
# gate read `41 open / 0.9 landings per hour` from the live repo instead of the fixture's `0`. Pinning
# the seam keeps the arm a statement about the TRAP, not about how busy the fleet is that morning.
#
# ── L6: the SHIPPED lane.sh trap does the same, end to end ─────────────
# The lane is executed for real: a stub `pi` returns immediately (so no model is called), the lane
# produces no commit and no push, and its EXIT trap must take the worktree and branch back.
#
# ⛔ THE STUB MUST BE A FUNCTION, NOT ONLY A FILE, AND THAT IS MEASURED (this arm's first draft ran a
# REAL AGENT for 77 s and spent model tokens). `lane.sh` line 8 is
# `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, so a file stub under a prepended PATH dir is
# SHADOWED by a system `pi` — and on this box there is one. A shell FUNCTION is resolved before any
# PATH lookup, so it cannot be shadowed. `spawn-gate.test.sh` has pinned exactly this for the same
# reason (and pins the mechanism with `env | grep '^BASH_FUNC_pi'`).
ENV=L6; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/o/logs" "$T/$ENV/o/state" "$T/$ENV/o/bin"
printf '#!/bin/bash\nexit 0\n' >"$T/$ENV/o/bin/pi"; chmod +x "$T/$ENV/o/bin/pi"
mk_lane_box "$T/$ENV/o" "$REPO"
in_wt "wt_provision '$REPO' .worktrees/tm-15 feat/15-tm origin/main" "$REPO" >/dev/null
OUT="$( cd "$REPO/.worktrees/tm-15" && \
        O="$T/$ENV/o" PATH="$T/$ENV/o/bin:$PATH" ENV_FILE="$T/$ENV/keys.env" \
        REAP_LANE_VENV_DISABLE=1 AGENT_INFRA_PATH="$T/.." MAX_LOAD=999999 \
        bash -c 'pi() { exit 0; }; export -f pi; exec bash "$0" --key-gate-off "$@"' "$LANE" 15 feat/15-tm "$LANE_OR" 2>&1 )"
assert_contains "$(cat "$T/$ENV/o/logs/lane-15.log" 2>/dev/null)" "exited" "L6 the shipped lane.sh ran to its exit path"
# The repo-identity gate must not be what refused: with the target naming this box's origin it must
# PASS, otherwise "the trap reaped an empty checkout" is a statement about a lane that never started.
assert_not_contains "$(cat "$T/$ENV/o/logs/lane-15.log" 2>/dev/null)" "repo-target REFUSED" \
    "L6 the repo-identity gate PASSED (the fixture's origin and the target are one repo)"
# ⛔ THE AGENT MUST HAVE ACTUALLY RUN. Without this the arm cannot tell "the trap reaped a 0-commit
# lane" from "the lane refused to start and the trap reaped what provisioning left" — and the second
# is exactly what the #2409 creation gate produced once main merged in.
assert_not_contains "$(cat "$T/$ENV/o/logs/lane-15.log" 2>/dev/null)" "land-backlog] REFUSED" \
    "L6 the lane REACHED its agent (the creation gate did not refuse the fixture)"
assert_nodir "$REPO/.worktrees/tm-15" "L6 the lane's own EXIT trap removed the worktree"
assert_nobranch "$REPO" feat/15-tm "L6 …and its 0-ahead branch"
assert_contains "$(cat "$T/$ENV/o/logs/lane-15.log" 2>/dev/null)" "worktree:" \
    "L6 the outcome is LOGGED in the lane log (not silent)"

# ── L7: the lane trap leaves a lane that DID work alone ────────────────
ENV=L7; REPO="$(mk_repo $ENV)"
mkdir -p "$T/$ENV/o/logs" "$T/$ENV/o/state" "$T/$ENV/o/bin"
# A stub `pi` that behaves like a lane which commits: it runs a commit in its cwd. Same function
# (not just file) stub as L6, for the same measured reason — a PATH stub is shadowed by lane.sh's own
# `export PATH=/opt/homebrew/bin:…` and the real agent runs instead.
cat >"$T/$ENV/o/stub-pi.sh" <<SH
pi() {
  printf 'lane work\n' > w.txt
  '$REAL_GIT' add w.txt
  GIT_AUTHOR_DATE='$RECENT_DATE' GIT_COMMITTER_DATE='$RECENT_DATE' \
    '$REAL_GIT' -c user.email=t@t -c user.name=t commit -qm 'lane work'
  return 0
}
export -f pi
SH
mk_lane_box "$T/$ENV/o" "$REPO"
in_wt "wt_provision '$REPO' .worktrees/tm-16 feat/16-tm origin/main" "$REPO" >/dev/null
( cd "$REPO/.worktrees/tm-16" && O="$T/$ENV/o" PATH="$T/$ENV/o/bin:$PATH" ENV_FILE="$T/$ENV/keys.env" \
  REAP_LANE_VENV_DISABLE=1 MAX_LOAD=999999 \
  bash -c '. "$1"; exec bash "$2" --key-gate-off 16 feat/16-tm "$3"' _ "$T/$ENV/o/stub-pi.sh" "$LANE" "$LANE_OR" \
  >/dev/null 2>&1 )
assert_not_contains "$(cat "$T/$ENV/o/logs/lane-16.log" 2>/dev/null)" "land-backlog] REFUSED" \
    "L7 the lane REACHED its agent (the creation gate did not refuse the fixture)"
# ⛔ AND THE IDENTITY GATE PASSED TOO — otherwise "the lane produced nothing" is a statement about a
# lane that never started. ($LANE_OR is passed as `$3`, not spliced into the `bash -c` body: inside
# that body it is an UNSET variable and the target arrived EMPTY — measured, and it made this arm read
# as "the trap reaped a committing lane" when the lane had been refused at the identity gate.)
assert_not_contains "$(cat "$T/$ENV/o/logs/lane-16.log" 2>/dev/null)" "repo-target REFUSED" \
    "L7 the repo-identity gate PASSED (the fixture's origin and the target are one repo)"
assert_dir "$REPO/.worktrees/tm-16" "L7 a lane that committed keeps its worktree"
assert_branch "$REPO" feat/16-tm "L7 and its branch"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-list --count "origin/main..feat/16-tm")" "1" \
    "L7 the lane's commit is intact"

# ── L8: the library refuses an unsafe branch name ──────────────────────
ENV=L8; REPO="$(mk_repo $ENV)"
OUT="$(in_wt "wt_provision '$REPO' .worktrees/tm-17 'feat/17 t m' origin/main; echo rc=\$?" "$REPO")"
assert_contains "$OUT" "rc=1" "L8 a branch name with whitespace is refused"
assert_nodir "$REPO/.worktrees/tm-17" "L8 nothing was created"

# ── L9: the `wt_` NAMESPACE IS SHARED WITH worker-terminal.sh, AND MUST NOT COLLIDE ────────────
# Both modules are SOURCED into the same shell by `dispatch-merge.sh`, so a verb defined in both
# resolves to whichever file was sourced LAST — silently, with no error and no log line. That is not
# hypothetical for this file: the launcher already owns `wt_spawn`/`wt_alive`/`wt_close`/`wt_dir`/
# `wt_count`, and `wt_dir` in particular is a name a worktree helper would reach for first. No name
# collides TODAY; this arm is what keeps it true the next time a verb is added to either module
# (the same "one fact, two definitions" class the harness spends so much of its suite budget on).
WT_VERBS_SELF="$(grep -oE '^(function )?wt_[a-z0-9_]+' "$HERE/wt-lifecycle.sh" 2>/dev/null | sed 's/^function //' | sort -u)"
WT_VERBS_OTHER="$(grep -oE '^(function )?wt_[a-z0-9_]+' "$HERE/worker-terminal.sh" 2>/dev/null | sed 's/^function //' | sort -u)"
if [ -n "$WT_VERBS_SELF" ]; then ok "L9 the extraction found this module's wt_ verbs ($(printf '%s\n' "$WT_VERBS_SELF" | wc -l | tr -d ' '))"; else bad "L9 extracted NO wt_ verbs from wt-lifecycle.sh - the collision arm would pass vacuously"; fi
if [ -n "$WT_VERBS_SELF" ] && [ -n "$WT_VERBS_OTHER" ]; then
  WT_SHARED_NAMES="$(comm -12 <(printf '%s\n' "$WT_VERBS_SELF") <(printf '%s\n' "$WT_VERBS_OTHER") | tr '\n' ' ')"
  if [ -z "${WT_SHARED_NAMES// /}" ]; then
    ok "L9 no wt_ verb is defined in BOTH wt-lifecycle.sh and worker-terminal.sh (no silent shadowing)"
  else
    bad "L9 these wt_ verbs are defined in BOTH modules and one silently shadows the other: $WT_SHARED_NAMES"
  fi
else
  bad "L9 could not extract both verb sets (self=$(printf '%s' "$WT_VERBS_SELF" | wc -l | tr -d ' ') other=$(printf '%s' "$WT_VERBS_OTHER" | wc -l | tr -d ' '))"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
