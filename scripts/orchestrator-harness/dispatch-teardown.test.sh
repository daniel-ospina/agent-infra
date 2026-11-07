#!/usr/bin/env bash
# dispatch-teardown.test.sh — a checkout the dispatcher PROVISIONED and no lane ever ran in is taken
# back before the batch moves on (agent-infra#2047).
#
# THE DEFECT. `dispatch-merge.sh` provisions the lane's worktree, and the LANE is a later, separate
# step — the launcher has no surface (no cmux answer AND no tmux), the credential contract refuses,
# the spawn dies. Those paths printed `lane-<N> NOT spawned` and moved on, leaving the worktree and
# the branch `-b` had just created on disk at ZERO commits ahead. The intake pre-flight infers
# "in flight" from exactly those two surfaces, so the free issue became permanently undispatchable
# on EVERY box while its slots were empty — measured on #8090:
#
#   [local branches] refs/heads/feat/8090-tm — matched issue-number (8090) — 0 commit(s) ahead
#
# The ledger's own indicator for this issue is the assertion T1 makes: an aborted lane leaves
# `git worktree list | grep -c "<N>"` = 0 and `git branch --list "*<N>*" | wc -l` = 0.
#
# HOW THESE ARMS ARE WRITTEN. Each one drives the SHIPPED `dispatch-merge.sh` against a REAL git repo
# with a REAL bare origin — never a shimmed `git`, because the gates being tested (0-ahead counts,
# dirty trees, attached branches) ARE git semantics. A stub launcher module supplies only the
# `wt_spawn`/`wt_alive` verdicts, which is the exact seam the defect lives on (a launcher that
# refused).
#
# ⛔ EVERY TEARDOWN ARM IS PAIRED WITH A REFUSAL ARM. The teardown is `wt_reap_if_empty`, which is
# only safe because it REFUSES anything that could be work. So T2 (commits ahead), T3 (a dirty tree)
# and T4 (a lane the launcher reports as alive) all assert the worktree is KEPT, with its reason —
# without them a "fix" that reaped unconditionally would pass T1 and pass nothing else.
#
# Hermetic: throwaway temp dirs, a throwaway HOME, no network, no tmux, no model call. The fixture's
# `origin` is a GitHub-shaped URL (the dispatcher asserts the slug) but a `url.<local>.insteadOf`
# rewrite sends every fetch to the fixture's OWN bare repo, so `dispatch-merge.sh`'s
# `git fetch origin main` stays on the box.
#
# ⛔ `sleep` IS NOT STUBBED, AND THE FIVE ARMS THEREFORE PAY THE SHIPPED 30 s INTER-ISSUE STAGGER
# (~2.5 min total, well inside the runner's 1800 s bound). Stubbing it was tried and is WRONG:
# `wt-lifecycle.sh` builds its bounded-probe watchdog on `sleep`, so a no-op `sleep` made every probe
# return `124`, the live-holder witness read "could not be evaluated (fail-closed)", and EVERY reap
# was PRESERVED — T1 and T5 failed while T2/T3/T4 "passed" for the wrong reason. A fixture that
# disables the safety probe cannot witness a teardown.
#
# Run:  bash scripts/orchestrator-harness/dispatch-teardown.test.sh

set -uo pipefail

# ⛔ THE DISPATCHER IS INVOKED BY A LITERAL RELATIVE PATH FROM THIS SUITE'S OWN DIRECTORY, AND THE
# SELF-PARSE GUARD IS GONE ON PURPOSE. A nested invocation whose script path is runtime-expanded
# (`bash "$0"`, `bash "$DM"`) is refused by the checkout-hygiene gate before bash starts, because
# the gate cannot statically resolve WHICH script it is being asked to read, so it fails closed. Both
# spellings are literal here instead, and the truncation check the other suites do with
# `bash -n "$0"` is done against the literal path (skipped when the suite is run from a copy outside
# the repo, where that path does not exist — the run's own exit status still covers it).
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 2
SELF_REL="scripts/orchestrator-harness/dispatch-teardown.test.sh"
DM_REL="scripts/orchestrator-harness/dispatch-merge.sh"
[ -f "$DM_REL" ] || { echo "FATAL: $DM_REL is missing (run this suite from the repo checkout)" >&2; exit 2; }
if [ -f "$SELF_REL" ]; then
    bash -n scripts/orchestrator-harness/dispatch-teardown.test.sh \
        || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }
fi
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required" >&2; exit 2; }
# The slug the fixture's origin carries. `dispatch-merge.sh` asserts the checkout's own origin
# against the target before it provisions anything (#2724/#2694) and refuses the whole batch when
# they disagree, so the fixture and the argument must be one repo. Nothing here reaches the network:
# the URL is only PARSED for the slug, and pushes go to the fixture's local bare origin.
OR="daniel-ospina/agent-infra"
T="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-teardown.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want '$2')"; fi; }
assert_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_not_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (present: $2)"; else ok "$3"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_branch()   { if git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; then ok "$3"; else bad "$3 (no ref: $2)"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (file exists: $1)"; else ok "$2"; fi; }
assert_releases() { # <logfile> <expected count> <message>
    local n=0
    [ -f "$1" ] && n="$(wc -l <"$1" | tr -d ' ')"
    assert_eq "${n:-0}" "$2" "$3"
}
assert_nobranch() { if git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; then bad "$3 (ref still exists: $2)"; else ok "$3"; fi; }
assert_clean_of() { # <repo> <token> — the LEDGER's indicator: no worktree and no branch named for it
    local wt br
    wt="$(git -C "$1" worktree list 2>/dev/null | grep -c "$2")"
    br="$(git -C "$1" branch --list "*$2*" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${wt:-1}" = 0 ] && [ "${br:-1}" = 0 ]; then ok "$3 (0 worktrees, 0 branches named '$2')"
    else bad "$3 (worktrees matching '$2': ${wt:-?}, branches: ${br:-?})"; fi; }

# ── the fixture box ───────────────────────────────────────────────────────────────────────────────
# mk_box <name> -> sets REPO, O and HOMEFIX: a git checkout whose origin parses as $OR, one commit
# on main, `origin/main` fetched, and a launcher module whose verdicts each arm controls.
mk_box() {
    local n="$1"
    REPO="$T/$n/repo"; O="$T/$n/o"; HOMEFIX="$T/$n/home"
    mkdir -p "$O/logs" "$O/state" "$HOMEFIX"
    git init -q --bare "$T/$n/origin.git"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.email t@t
    git -C "$REPO" config user.name t
    printf 'base\n' >"$REPO/base.txt"
    git -C "$REPO" add -A
    GIT_AUTHOR_DATE="2026-09-01T00:00:00" GIT_COMMITTER_DATE="2026-09-01T00:00:00" \
        git -C "$REPO" commit -qm init
    # The slug the dispatcher asserts, and the transport it never uses (the URL is parsed, not read).
    git -C "$REPO" remote add origin "https://github.com/$OR.git"
    # ⛔ HERMETIC FETCH. `dispatch-merge.sh` runs `git fetch origin main`, and the origin URL has to
    # carry the target SLUG (it is asserted before anything is provisioned). Rewriting that URL to
    # the fixture's own bare repo keeps the slug, keeps the refs the arms assert on, and keeps the
    # run off the network — without the rewrite the fetch lands the REAL main and every "N commits
    # ahead" assertion counts against the wrong history.
    git -C "$REPO" config "url.file://$T/$n/origin.git.insteadOf" "https://github.com/$OR.git"
    git -C "$REPO" push -q "$T/$n/origin.git" main:refs/heads/main
    git -C "$REPO" fetch -q "$T/$n/origin.git" "refs/heads/main:refs/remotes/origin/main"
    # The LAUNCHER seam. Only the verdicts are stubbed; `dispatch-merge.sh` refuses to run at all
    # unless all six verbs exist (its own staleness guard), so the module carries the full set.
    cat >"$O/worker-terminal.sh" <<'SH'
wt_launcher()     { echo "stub"; }
wt_launcher_why() { echo "stub"; }
wt_count()        { echo 0; }
wt_alive()        { return "${WT_STUB_ALIVE:-1}"; }   # 1 = not alive (default)
wt_close()        { return 0; }
wt_spawn() { case "$1" in
    lane-*)  return "${WT_STUB_LANE_RC:-1}" ;;        # 1 = the spawn FAILED (default)
    *)       return "${WT_STUB_CHAIN_RC:-0}" ;; esac; }
SH
    # Present but INCOMPLETE on purpose: the CI-queue gate announces itself INERT and the batch
    # proceeds. An ABSENT file would send the script to its own sibling copy — the REAL one — and a
    # fixture arm would then wait on a live `gh` read.
    : >"$O/ci-queue.sh"
    : >"$O/lane.sh"; : >"$O/chain-merge.sh"; : >"$O/merge-one.sh"
    : >"$O/dispatched.txt"
    # The CLAIM surface, stubbed to RECORD every release. `release_issue_claim_unspawned` is a no-op
    # when `$O/claims.sh` is absent, so without this a future edit that released the claim on the
    # lane-never-started path (letting a peer duplicate work this box is still implementing) would
    # red nothing.
    cat >"$O/claims.sh" <<'SH'
claim_issue_release_record() { printf 'release %s\n' "${3:-?}" >> "$O/claim-releases.log"; return 0; }
claim_issue_record_commit()  { return 0; }
SH
}

# drive <logfile> [WT_STUB_ALIVE] [WT_STUB_LANE_RC] [WT_STUB_CHAIN_RC] — run the SHIPPED dispatcher
# for issue 2047 exactly as the controller does, with the fixture as the whole world.
# ⛔ AND THE DISK ADMISSION IS NEUTRALISED WITH ALL FOUR TERMS, OR THIS FIXTURE IS DECIDED BY THE
# HOST (#3409 review). `dispatch-merge.sh` provisions a real checkout through `wt_provision`, which
# since #3395 calls `wt_disk_admit` BEFORE `git worktree add` — so every arm below inherits whatever
# free space the machine running the suite has. MEASURED on a 68 GB host: 33 passed / 0 failed; the
# same suite under a 1 GB `df` stub: 21 passed / 12 failed. That is a host-decided suite, and a box
# under the 8,144 MB bound would red it for a reason no assertion here names. The four terms are the
# seam's own: a floor of 1 MB, and the three lane-cost terms at 0, so `need` is 0 and admission can
# never depend on this disk. (`DISK_LANE_TREE_MB` defaults to 350 and `DISK_LANE_SELF_MB` to 6,144
# when unstated — a bare shell assignment would not reach the child either, which is why these are
# an ENV PREFIX on the invocation rather than statements.)
drive() {
    local log="$1" alive="${2:-1}" lane_rc="${3:-1}" chain_rc="${4:-0}"
    HOME="$HOMEFIX" TMPDIR="$T" O="$O" HARNESS_TOKEN= \
        DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
        WT_STUB_ALIVE="$alive" WT_STUB_LANE_RC="$lane_rc" WT_STUB_CHAIN_RC="$chain_rc" \
        bash scripts/orchestrator-harness/dispatch-merge.sh "$REPO" "$OR" 2047 >"$log" 2>&1
    return $?
}

echo "── T1: a lane that never started leaves NO worktree and NO branch (#2047)"
mk_box t1
drive "$T/t1/log" 1 1 0
assert_contains "$T/t1/log" "#2047: lane-2047 NOT spawned" "T1 the fixture really refused the lane spawn (the arm is about that path)"
assert_nodir "$REPO/.worktrees/tm-2047" "T1 the provisioned checkout is GONE"
assert_nobranch "$REPO" feat/2047-tm "T1 …and the 0-ahead branch it created"
assert_clean_of "$REPO" 2047 "T1 the issue's own indicator holds: nothing named 2047 is left"
assert_contains "$T/t1/log" "produced no commits" "T1 the take-back is REPORTED, not silent"
assert_nofile "$O/claim-releases.log" "T1 the issue claim was NOT released (the chain is alive and waiting; a peer must not duplicate it)"
if git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $REPO/.worktrees/tm-2047"; then
    bad "T1 the worktree is still REGISTERED in git's own list"
else
    ok "T1 the worktree record is gone (not merely the directory)"
fi

echo "── T2: a branch that carries COMMITS keeps its worktree (the teardown cannot destroy work)"
mk_box t2
git -C "$REPO" branch feat/2047-tm origin/main
mkdir -p "$REPO/.worktrees"
git -C "$REPO" worktree add -q "$REPO/.worktrees/seed-2047" feat/2047-tm
printf 'lane work\n' >"$REPO/.worktrees/seed-2047/w.txt"
git -C "$REPO/.worktrees/seed-2047" add w.txt
GIT_AUTHOR_DATE="2026-09-02T00:00:00" GIT_COMMITTER_DATE="2026-09-02T00:00:00" \
    git -C "$REPO/.worktrees/seed-2047" commit -qm 'lane work'
git -C "$REPO" worktree remove --force "$REPO/.worktrees/seed-2047"
assert_eq "$(git -C "$REPO" rev-list --count "origin/main..feat/2047-tm")" "1" \
    "T2 the fixture branch really is 1 commit ahead of origin/main"
drive "$T/t2/log" 1 1 0
assert_contains "$T/t2/log" "#2047: lane-2047 NOT spawned" "T2 the lane spawn was refused (same path as T1)"
assert_dir "$REPO/.worktrees/tm-2047" "T2 the worktree is KEPT"
assert_branch "$REPO" feat/2047-tm "T2 …and the branch holding the commit"
assert_eq "$(git -C "$REPO" rev-list --count "origin/main..feat/2047-tm")" "1" \
    "T2 the commit is intact"
assert_contains "$T/t2/log" "worktree kept" "T2 the refusal is reported as a KEEP, with its reason"
# ⛔ THE LOG MAY NOT CLAIM A TAKE-BACK IT DID NOT DO (#3577 review). The helper used to announce
# "taking the checkout back" BEFORE it knew the verdict, so this arm — where the reaper's gates fire
# and the commit is preserved — carried a line saying the checkout had been taken back, immediately
# contradicted by the next line. Nothing is deleted here, so nothing may say it was.
assert_not_contains "$T/t2/log" "taking the checkout back" "T2 the log does not announce a take-back that its own next line contradicts"

echo "── T3: an UNCOMMITTED tree keeps its worktree (the dirty class is the reaper's, not the exit path's)"
mk_box t3
mkdir -p "$REPO/.worktrees"
git -C "$REPO" worktree add -q "$REPO/.worktrees/tm-2047" -b feat/2047-tm origin/main
printf 'uncommitted work\n' >"$REPO/.worktrees/tm-2047/wip.txt"
drive "$T/t3/log" 1 1 0
assert_contains "$T/t3/log" "#2047: lane-2047 NOT spawned" "T3 the lane spawn was refused (the reused checkout reaches the same path)"
assert_dir "$REPO/.worktrees/tm-2047" "T3 a DIRTY worktree is KEPT"
if [ -f "$REPO/.worktrees/tm-2047/wip.txt" ]; then ok "T3 the uncommitted file is still there"; else bad "T3 the uncommitted file is GONE (silent destruction of work)"; fi
assert_contains "$T/t3/log" "DIRTY" "T3 the reason names the dirt"
assert_not_contains "$T/t3/log" "taking the checkout back" "T3 uncommitted work is not reported as taken back (it is still on disk)"

echo "── T4: a spawn reported FAILED while the lane is ALIVE keeps its worktree (#2499/#2787)"
mk_box t4
drive "$T/t4/log" 0 1 0
assert_contains "$T/t4/log" "#2047: lane-2047 NOT spawned" "T4 the spawn verdict was 'failed'"
assert_dir "$REPO/.worktrees/tm-2047" "T4 the worktree is KEPT — a live lane's checkout is never taken back"
assert_branch "$REPO" feat/2047-tm "T4 …and its branch"
assert_contains "$T/t4/log" "is alive" "T4 the arm says WHY it kept it"

echo "── T5: the NO-CHAIN path still reaps its empty checkout (regression: one take-back, both paths)"
mk_box t5
# ⛔ THE LANE SPAWN MUST SUCCEED HERE. With a FAILING lane spawn this arm is vacuous for the
# no-chain branch: the lane-never-started path above already takes the checkout back, so the
# no-chain reap finds "nothing to reap" and deleting it reds nothing (measured — a review round
# found exactly that). With `lane_rc=0` the lane is spawned (the stub does not run anything, so the
# checkout stays empty), only the CHAIN fails, and the no-chain take-back is the only one that runs.
drive "$T/t5/log" 1 0 1
assert_contains "$T/t5/log" "lane-2047 (implement+PR" "T5 the fixture really spawned the lane (so this arm measures the NO-CHAIN path, not the spawn-failure path)"
assert_contains "$T/t5/log" "chain-2047 could NOT be started" "T5 the fixture really reached the no-chain path"
assert_nodir "$REPO/.worktrees/tm-2047" "T5 the checkout is GONE"
assert_nobranch "$REPO" feat/2047-tm "T5 …and its 0-ahead branch"
assert_clean_of "$REPO" 2047 "T5 nothing named 2047 is left on this box"
# The no-chain path is the one of the TWO TAKE-BACK paths that releases (the lane is confirmed gone
# and no chain will ever look at this checkout) — asserted so the ordering it was built for is still
# observable. ⚠️ SCOPED (cycle-4 review, P2): unscoped, "the ONE path that releases" was false —
# dispatch-merge.sh releases claims at the batch/no-target/per-issue refusals and elsewhere too.
assert_releases "$O/claim-releases.log" 1 "T5 the no-chain path released the issue claim exactly once (and only after the lane was confirmed gone)"

echo "── T6: the shipped dispatcher is the one under test (a moved script would prove nothing)"
# ⛔ COMMENTS ARE STRIPPED AND THE COUNTS ARE PINNED (#3577 review, P2 — MEASURED). The condition here
# used to be `grep -q 'reap_unused_worktree'` && `grep -q 'wt_reap_if_empty'`, and BOTH were satisfiable
# by prose: `wt_reap_if_empty` appears in the comment above the helper, `reap_unused_worktree` in the
# helper's own DEFINITION and in the SCOPE comment above it. So the stated failure condition —
# "dispatch-merge.sh no longer calls wt_reap_if_empty" — could never fire: replacing the helper's call
# with a raw `git worktree remove --force` + `update-ref -d`, and deleting BOTH call sites, each left
# T6 GREEN. The counts below are over non-comment lines, i.e. executable text only:
#   · `wt_reap_if_empty`      — EXACTLY 1: the single teardown, inside reap_unused_worktree. A second
#                               occurrence means a second teardown has been introduced.
#   · `reap_unused_worktree`  — at least 3: its definition plus BOTH call sites (lane-not-spawned and
#                               no-chain). Dropping either call site falls below 3 and reddens.
_dm_code="$(grep -vE '^[[:space:]]*#' "$DM_REL")"
# ⛔ THE CALL SHAPES ARE COUNTED, NOT THE WORDS. A whole-line count of `wt_reap_if_empty` also counts
# the `command -v wt_reap_if_empty` existence probe and the failure message that names the missing
# verb (T7) — both are non-comment lines, so the exact-1 pin reddened on the very guard it exists to
# protect. Anchoring to a call shape counts teardowns: one at the start of a line, one definition.
_reaps="$(printf '%s\n' "$_dm_code" | grep -cE '^[[:space:]]*wt_reap_if_empty[[:space:]]')"
_calls="$(printf '%s\n' "$_dm_code" | grep -cE '(^|[[:space:]])reap_unused_worktree(\(|[[:space:]])')"
if [ "${_reaps:-0}" -eq 1 ] && [ "${_calls:-0}" -ge 3 ]; then
    ok "T6 both take-backs still route through the reviewed wt_reap_if_empty (1 teardown, ${_calls} call/definition lines)"
else
    bad "T6 dispatch-merge.sh no longer routes both take-backs through wt_reap_if_empty (non-comment wt_reap_if_empty=$_reaps want 1, reap_unused_worktree=$_calls want >=3) — this suite would be testing a second teardown"
fi

echo ""
echo "── T7: a take-back that CANNOT RUN must not bill a stale verdict (the module may predate the verb)"
# ⛔ MEASURED, NOT ASSUMED (#3577 review). `$WTL` is sourced beside this script with no verb guard —
# `$WTL` only has to source cleanly — so a module without `wt_reap_if_empty` reaches the call as
# `command not found` (rc 127) and falls into the `*)` arm. Without the two lines pinned below, that
# arm printed `WT_RESULT` exactly as `wt_provision` had left it:
#   "⚠️ worktree NOT reaped — created .worktrees/tm-2047 on feat/2047-tm from origin/main (…)"
# i.e. the one arm that exists to surface a failed take-back named a wrong cause, and the #8090
# residue it was reporting survived. A behaviour-only arm cannot reach this without shipping a
# broken module into the fixture, so it is pinned on the helper's executable text — and T6 shows
# what a pin over non-comment code is worth here.
# ⛔ HERE-STRINGS, NOT PIPES (#841/#864, `sigpipe-grep`). `printf … | grep -q` is the SIGPIPE
# false-negative idiom: under `pipefail` the quiet grep exits at its FIRST match, the writer takes
# SIGPIPE (141), and the pipeline status becomes non-zero — so a string that IS present reads as
# absent and these three pins would report the defect they exist to catch, on a file that does not
# have it. A here-string has no earlier writer to kill. Measured: the piped form is what this file
# shipped and `scripts/check-no-sigpipe-grep.sh` flagged all three as undeclared.
T7_CODE="$(sed -n '/^reap_unused_worktree() {/,/^}$/p' "$DM_REL" | grep -v '^[[:space:]]*#')"
grep -qF 'WT_RESULT=""' <<<"$T7_CODE" \
    && ok "T7 the helper resets WT_RESULT at entry (belt-and-braces: wt_reap_if_empty resets it too, and the verb guard below returns before the call without reading it)" \
    || bad "T7 the helper no longer resets WT_RESULT before the call — NOT a live defect today (the module resets it, the guard returns unread), but a caller that later reads a verdict it never received would inherit wt_provision's 'created …' — the #2033 shape"
if grep -qF 'command -v wt_reap_if_empty' <<<"$T7_CODE"; then
    ok "T7 …and it proves the verb exists, naming the missing verb instead of a wrong cause"
else
    bad "T7 the helper calls wt_reap_if_empty unguarded — an older module turns the failure arm into a wrong-cause report"
fi

if ! grep -qF 'taking the checkout back' <<<"$T7_CODE"; then
    ok "T7 …and it announces no verdict before the call (the verdict lines are the only claim)"
else
    bad "T7 the helper still announces 'taking the checkout back' before it knows the verdict"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
