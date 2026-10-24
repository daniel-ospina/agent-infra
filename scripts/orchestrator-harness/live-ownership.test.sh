#!/usr/bin/env bash
# live-ownership.test.sh — the owner's dispatch rule, driven against REAL processes.
#
# ⛔ WHY THIS SUITE IS DIFFERENT FROM THE OTHERS: every other harness suite stubs `gh` or extracts a
# single function. This one asserts a fact about the MACHINE — "is a live process holding this PR's
# branch" — so it creates REAL worktrees and REAL processes and lets the SHIPPED scan find them. A
# stub here would test the stub: the whole defect being fixed is that a registry said a lane was
# running while nothing held the branch, so a test that supplies the answer itself reproduces the bug.
#
# The four cases the owner named:
#   (a) 3 un-owned PRs                       -> the selection takes PRs, issues are SKIPPED
#   (b) 0 un-owned + capacity                -> the selection dispatches issues
#   (c) 0 un-owned + no capacity             -> the selection dispatches nothing
#   (d) a registry claiming owned, DEAD process -> UN-OWNED (the measured bug shape)
#
# Hermetic: a throwaway git repo, worktrees and sleeps under $TMPDIR; nothing touches a real box.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/live-ownership.sh"
ORCH="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
eqv() { # eqv <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2], got [$3]"; fi
}

[ -f "$LIB" ]  || { echo "❌ $LIB is missing — the selection module moved"; exit 1; }
[ -f "$ORCH" ] || { echo "❌ $ORCH is missing — the controller moved"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

# The OWNERSHIP PREDICATE is extracted from the SHIPPED controller (not re-implemented): a rename or
# a reordering that changes what counts as ownership must fail HERE, not in production.
ex() { sed -n "/^$1()/,/^}/p" "$ORCH"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/lo-suite.XXXXXX")" || { echo "❌ mktemp failed"; exit 1; }
OWN_FNS="$T/own.sh"
{ ex pr_owned; ex claim_foreign_live; ex claim_selection_verdict; ex claim_live; ex claim_lease_live; grep -E '^_this_host\(\) \{' "$ORCH"; } > "$OWN_FNS"
SPIDS=""
cleanup() {
  local p
  for p in $SPIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT INT TERM
for _f in pr_owned claim_foreign_live claim_selection_verdict claim_live claim_lease_live; do
  grep -q "^$_f() {" "$OWN_FNS" || { echo "❌ could not extract $_f() from $ORCH — the rule moved or was reformatted"; exit 1; }
done
bash -n "$OWN_FNS" 2>/dev/null || { echo "❌ the extracted ownership functions do not parse"; exit 1; }

# ── fixture: a repo with worktrees ───────────────────────────────────────────────────────────────
R="$T/repo"
git init -q "$R" && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  || { echo "❌ could not create the fixture repo"; exit 1; }
WT="$R/.worktrees/fix-9007"
WT2="$T/aig-wt-9100"
git -C "$R" worktree add -q "$WT"  -b fix/9007-thing   >/dev/null 2>&1 || { echo "❌ worktree add failed"; exit 1; }
git -C "$R" worktree add -q "$WT2" -b chore/no-pr-name >/dev/null 2>&1 || { echo "❌ worktree add 2 failed"; exit 1; }
# A path INSIDE a cell clone that is NOT a worktree — cell ownership is territory, not branches.
mkdir -p "$T/cellclone/scratch"
# A DATE-shaped directory: the one false positive the "path carries the PR number" rule must not have.
mkdir -p "$R/.worktrees/docs-2026-10-17"

# ⛔ NO `$( … )` AROUND THIS: a background job started inside a command substitution is dead by the
# time the substitution returns (measured), which makes every assertion below vacuously TRUE.
start_in() { ( cd "$1" && exec sleep 300 ) & SPIDS="$SPIDS $!"; }

echo
echo "=== 1) the probe finds a LIVE process holding a branch, by BRANCH ==="
start_in "$WT"; P1="$!"
sleep 0.4
LO_LIVE="$T/live.tsv"
lo_scan "$LO_LIVE" "$R"
[ -s "$LO_LIVE" ] && ok "lo_scan produced rows from real processes" || bad "lo_scan produced nothing with a live process in a worktree"
lo_scan_ok "$LO_LIVE" && ok "lo_scan_ok: the scan is KNOWABLE (rows present)" || bad "lo_scan_ok said UNKNOWN with rows present"
[ "$(awk -F'\t' '$1=="fix/9007-thing"' "$LO_LIVE" | wc -l | tr -d ' ')" -ge 1 ] \
  && ok "the row for fix/9007-thing is present" || bad "no row for fix/9007-thing: $(cat "$LO_LIVE")"
lo_pr_owned "$LO_LIVE" 9007 fix/9007-thing && ok "PR #9007 OWNED: a live cwd is its head ref's checkout" \
  || bad "PR #9007 read UNOWNED with a live process in its worktree"
lo_pr_owned "$LO_LIVE" 9999 feat/not-anybodys && bad "PR #9999 read OWNED with nothing working it" \
  || ok "PR #9999 UNOWNED: no live process holds that branch"

echo
echo "=== 1b) the BRANCH arm alone: a path with no PR number, a branch that names one ==="
# ⛔ THIS CASE EXISTS BECAUSE THE SUITE WAS BLIND TO IT (mutation-tested 2026-10-18): disabling the
# branch arm entirely left every assertion above GREEN, because the fixture's worktree PATH
# (`fix-9007`) answered through the path rule. Real branches look like this one — the PR number is in
# the REF, not in the directory — so the branch arm is the primary signal and must be pinned alone.
WTB="$R/.worktrees/beat-guard"
git -C "$R" worktree add -q "$WTB" -b fix/1991-beat-guard-exhaustive >/dev/null 2>&1 || { echo "❌ worktree add 3 failed"; exit 1; }
start_in "$WTB"
sleep 0.4
lo_scan "$LO_LIVE" "$R"
lo_owns_path_pr "$LO_LIVE" 1991 && bad "the PATH rule matched a path with no PR number in it — the fixture is wrong" \
  || ok "(isolated) the path rule does NOT match this worktree — so only the branch arm can answer"
lo_pr_owned "$LO_LIVE" 1991 fix/1991-beat-guard-exhaustive \
  && ok "PR #1991 OWNED by its BRANCH alone (the path carries no PR number)" \
  || bad "PR #1991 UNOWNED — the branch arm did not fire, which is the primary signal"

echo
echo "=== 2) the fallback: a worktree PATH carrying the PR number (no PR-shaped branch) ==="
start_in "$WT2"
start_in "$R/.worktrees/docs-2026-10-17"
sleep 0.4
lo_scan "$LO_LIVE" "$R"
lo_pr_owned "$LO_LIVE" 9100 chore/no-pr-name \
  && ok "PR #9100 OWNED via the worktree path (aig-wt-9100) despite an unrelated branch name" \
  || bad "PR #9100 UNOWNED — the path-carries-the-number rule did not fire"
lo_pr_owned "$LO_LIVE" 2026 docs/whatever \
  && bad "PR #2026 read OWNED from a DATE directory (2026-10-17) — the path rule is too loose" \
  || ok "a date component (2026-10-17) is NOT read as PR #2026"

echo
echo "=== 3) (d) THE MEASURED BUG SHAPE: the registry says owned, the process is DEAD ==="
LO_LIVE="$T/live2.tsv"
lo_scan "$LO_LIVE" "$R"
lo_pr_owned "$LO_LIVE" 9007 fix/9007-thing && ok "(precondition) #9007 is owned while its process lives" \
  || bad "(precondition) #9007 not owned even while its process lives — the rest of this section is meaningless"
kill "$P1" 2>/dev/null || true
wait "$P1" 2>/dev/null || true
sleep 0.3
lo_scan "$LO_LIVE" "$R"
lo_pr_owned "$LO_LIVE" 9007 fix/9007-thing \
  && bad "#9007 STILL reads owned after its process died — a dead process must not own a PR" \
  || ok "#9007 becomes UNOWNED when the process dies (the measured bug shape, closed)"
# …and the same question through the SHIPPED pr_owned(): a session name and a marker are records of
# intent, not of work. This is the exact defect (21 "running" lanes, none holding a PR branch).
O="$T/o"; mkdir -p "$O/state"
: > "$O/state/claims-snapshot"
WSESS="fix-9007 merge-9007"
LO_SCAN=1; LO_LIVE="$T/live2.tsv"
is_num() { lo_num "$1"; }
# shellcheck source=/dev/null
. "$OWN_FNS"
# ⛔ THE VERDICT ITSELF IS SOURCED FROM claims.sh (agent-infra#2466), for the same reason test-gates.sh
# does: `claim_selection_verdict` is a thin policy wrapper over ONE reader, and extracting the wrapper
# without the reader left every "unowned" fixture reading owned (a missing reader exits 127, which is
# fail-closed). Sourcing the shipped file keeps this suite grading the shipped polarity.
# shellcheck source=/dev/null
. "$HERE/claims.sh"
touch "$O/state/needsfix-9007-sha"             # a findings marker agrees with the sessions
if pr_owned 9007 sha fix/9007-thing; then
  bad "pr_owned() counted a DEAD PR as owned from a session name + a marker — the exact defect measured"
else
  ok "pr_owned(): a session name + a findings marker are NOT ownership (dead process => un-owned)"
fi

echo
echo "=== 4) a LIVE process makes pr_owned() true; a FOREIGN claim too; per HEAD, not per PR ==="
start_in "$WT"
sleep 0.4
lo_scan "$LO_LIVE" "$R"
pr_owned 9007 sha fix/9007-thing && ok "pr_owned(): a LIVE process in the branch's checkout owns the PR" \
  || bad "pr_owned() missed a live process holding the branch"
# A claim held by ANOTHER box is the only evidence a remote holder can leave (claims.sh: a lease is
# data, not liveness) — it must count, or two boxes race the same PR.
# (PR #9500 / branch feat/claim-check: NOTHING holds it, so only the claim arm can answer.)
printf 'refs/claims/9500-abc000000000\totherbox:123\t9999999999\n' > "$O/state/claims-snapshot"
claim_ref() { printf 'refs/claims/%s-%s' "$1" "$(printf '%s' "$2" | cut -c1-12)"; }
pr_owned 9500 abc000000000 feat/claim-check \
  && ok "pr_owned(): a live claim held by ANOTHER box owns the PR (unobservable locally)" \
  || bad "pr_owned() ignored a foreign live claim — two boxes would race the same PR"
pr_owned 9500 zzz000000000 feat/claim-check \
  && bad "pr_owned() owned PR #9500 at a DIFFERENT head — a claim is per head, not per PR" \
  || ok "pr_owned(): a claim on another head does not own this one"
# A claim held by THIS box is not foreign: its liveness must be proven by a live process.
printf 'refs/claims/9500-abc000000000\t%s:123\t9999999999\n' "$(_this_host)" > "$O/state/claims-snapshot"
pr_owned 9500 abc000000000 feat/claim-check \
  && bad "pr_owned() counted THIS box's claim as ownership — a local claim outlives its process by design" \
  || ok "pr_owned(): THIS box's claim alone does not own the PR (only a live process does)"

echo
echo "=== 5) an unreadable probe is UNKNOWN, not 'nothing is owned' ==="
lo_scan "$T/none.tsv" "$T/does-not-exist" \
  && bad "lo_scan returned success for a repo that does not exist" \
  || ok "lo_scan FAILS on a missing repo (an empty scan cannot pass as a healthy fleet)"
lo_scan_ok "$T/none.tsv" && bad "lo_scan_ok said KNOWABLE for an empty scan" || ok "lo_scan_ok: an empty scan is UNKNOWN"
: > "$T/empty.tsv"
lo_pr_owned "$T/empty.tsv" 9007 fix/9007-thing \
  && bad "an EMPTY live table owned a PR" || ok "an empty live table owns nothing (no invented liveness)"

echo
echo "=== 6) cells: a live process under the box's clone ==="
start_in "$T/cellclone/scratch"
sleep 0.4
lo_scan "$LO_LIVE" "$R" "$T/cellclone"
lo_cell_owned "$LO_LIVE" "$T/cellclone" && ok "the cell is OWNED: a live process is inside its clone" \
  || bad "cell ownership missed a live process inside the clone"
lo_cell_owned "$LO_LIVE" "$T/some-other-cell" && bad "a cell with no process in it read OWNED" \
  || ok "an idle cell reads UNOWNED"

echo
echo "=== 7) the ORDER: conflicted → red → pending → green; oldest first within a class ==="
META="$T/meta.tsv"; CLS="$T/class.tsv"
cat > "$META" <<'EOF'
1	2026-10-01T00:00:00Z
2	2026-10-02T00:00:00Z
3	2026-10-03T00:00:00Z
4	2026-10-04T00:00:00Z
5	2026-10-05T00:00:00Z
EOF
cat > "$CLS" <<'EOF'
1	sha1	GREEN
2	sha2	PENDING
3	sha3	CONFLICTED
4	sha4	CONFLICTED
5	sha5	RED
EOF
printf '1\tb1\tfalse\n2\tb2\tfalse\n3\tb3\tfalse\n4\tb4\tfalse\n5\tb5\tfalse\n' > "$T/rows.tsv"
eqv "conflicted (#3,#4 oldest first) then red (#5) then pending (#2) then green (#1)" \
  "3 4 5 2 1 " "$(lo_order "$META" "$CLS" < "$T/rows.tsv" | cut -f1 | tr '\n' ' ')"
# A PR the sweep has never observed carries no class: it must not jump the queue, and must not vanish.
printf '1\tb1\tfalse\n6\tb6\tfalse\n' > "$T/rows2.tsv"
eqv "an UNOBSERVED PR is not dropped and sorts with pending" \
  "6 1 " "$(lo_order "$META" "$CLS" < "$T/rows2.tsv" | cut -f1 | tr '\n' ' ')"
# The class file is append-only between compactions, so the LAST observation must win.
printf '7\tb7\tfalse\n' > "$T/rows3.tsv"
printf '7\tb7\tGREEN\n7\tb7\tCONFLICTED\n' > "$T/cls3.tsv"
eqv "the LAST observation wins over an earlier one (conflicted now)" \
  "7 " "$(lo_order /dev/null "$T/cls3.tsv" < "$T/rows3.tsv" | cut -f1 | tr '\n' ' ')"
printf '7\tb7\tGREEN\n7\tb7\tCONFLICTED\n' > "$T/cls3.tsv"
lo_class_compact "$T/cls3.tsv"
eqv "lo_class_compact keeps ONE row per PR (bounded growth)" "1" "$(wc -l < "$T/cls3.tsv" | tr -d ' ')"
grep -q CONFLICTED "$T/cls3.tsv" && ok "…and the row it keeps is the LAST observation" \
  || bad "lo_class_compact kept an earlier observation"

echo
echo "=== 8) (a)(b)(c) the selection cases, and what the funnel SAYS ==="
# (a) 3 un-owned PRs, capacity abundant: PRs first, issues SKIPPED.
sel3() { lo_select "$@" > "$T/selline"; LO_CHOICE_V="$LO_CHOICE"; line="$(cat "$T/selline")"; }
sel3 3 0 3 0 42 '' 9; choice="$LO_CHOICE_V"
eqv "(a) 3 un-owned -> the choice is PR takeover" "pr" "$choice"
case "$line" in *"issues: SKIPPED (un-owned PRs exist)"*) ok "(a) the funnel SAYS the issue path is shut" ;;
  *) bad "(a) the funnel did not name the blocked issue path: $line" ;; esac
case "$line" in *"#42"*) ok "(a) the funnel names the PR it will take first" ;;
  *) bad "(a) the funnel did not name a target: $line" ;; esac
case "$line" in *"3 un-owned"*) ok "(a) the funnel carries the count it decided on" ;;
  *) bad "(a) the funnel lost the count: $line" ;; esac
# (b) 0 un-owned + capacity: issues.
sel3 0 0 0 0 - '' 7; choice="$LO_CHOICE_V"
eqv "(b) 0 un-owned + capacity -> dispatch issues" "issue" "$choice"
case "$line" in *"issues: DISPATCH"*) ok "(b) the funnel says the issue path is OPEN" ;;
  *) bad "(b) the funnel did not open the issue path: $line" ;; esac
# (c) 0 un-owned + NO capacity: nothing, and the reason is named.
sel3 0 0 0 0 - 'mem_avail=100M<=min_mem_free_mb=512M' 7; choice="$LO_CHOICE_V"
eqv "(c) 0 un-owned + no capacity -> dispatch NOTHING" "none" "$choice"
case "$line" in *"no capacity: mem_avail="*) ok "(c) the funnel names the binding capacity gate" ;;
  *) bad "(c) the funnel did not name the capacity gate: $line" ;; esac
# ⛔ #2126 THE HONESTY FIELDS. 8 and 9 are <acted> <named-waits>, appended AFTER <backlog> so every
# older positional caller (and the `#42` / `no capacity:` pins above) keeps its meaning.
# (d) un-owned PRs exist but the sweep spawned NOTHING: the funnel must not say "dispatching".
sel3 3 0 3 0 42 '' 9 0 3; choice="$LO_CHOICE_V"
eqv "(d) un-owned + nothing acted -> still the PR choice" "pr" "$choice"
case "$line" in *"dispatching"*) bad "(d) the funnel claimed 'dispatching' on a cycle that spawned nothing: $line" ;;
  *) ok "(d) the funnel does NOT claim a dispatch when no unit was spawned" ;; esac
case "$line" in *"NO UNIT SPAWNED"*"named wait"*) ok "(d) …it names the waits instead of the work" ;;
  *) bad "(d) the funnel did not name the waits: $line" ;; esac
# (e) …and with at least one act it keeps its claim, and names the first target.
sel3 3 0 3 0 42 '' 9 2 1; choice="$LO_CHOICE_V"
case "$line" in *"dispatching PR-takeover (first #42"*) ok "(e) a cycle that DID spawn says dispatching, and names it" ;;
  *) bad "(e) the funnel lost its claim with acts>0: $line" ;; esac
# A MEASURED ZERO IS NOT AN UNRECORDED CYCLE (review cycle 2, P1). The caller passes 0/0 when the
# ledger is unwritable OR holds no rows -- including "truncate succeeded, every write failed". Asserting
# "NO UNIT SPAWNED" there is the same defect sign-reversed, on the headline line.
sel3 3 0 3 0 42 '' 9 0 0 unknown; choice="$LO_CHOICE_V"
eqv "(g) un-owned + nothing recorded -> still the PR choice" "pr" "$choice"
case "$line" in *"NO UNIT SPAWNED"*) bad "(g) the funnel asserted a measured zero from an unrecorded cycle: $line" ;;
  *) ok "(g) an UNRECORDED cycle does not claim 'NO UNIT SPAWNED'" ;; esac
case "$line" in *"UNKNOWN, not zero"*) ok "(g) ...it says the actions are UNKNOWN, not zero" ;;
  *) bad "(g) the funnel did not say UNKNOWN: $line" ;; esac
# (h) ...and the row count is never labelled a count of un-owned PRs.
sel3 3 0 3 0 42 '' 9 0 4 ok; choice="$LO_CHOICE_V"
case "$line" in *"4 un-owned PR(s)"*) bad "(h) a ledger ROW count was printed as un-owned PRs: $line" ;;
  *) ok "(h) the wait count is labelled rows, not un-owned PRs" ;; esac
case "$line" in *"4 recorded row(s)"*) ok "(h) ...and it says exactly that" ;;
  *) bad "(h) the rows label is missing: $line" ;; esac
# (f) an OLDER caller (no acted field) keeps the pre-#2126 wording -- a stale harness and a stale module agree.
sel3 3 0 3 0 42 '' 9; choice="$LO_CHOICE_V"
case "$line" in *"dispatching PR-takeover"*) ok "(f) an absent acted count keeps the old wording (compatible)" ;;
  *) bad "(f) the absent-acted path changed wording: $line" ;; esac
# ⛔ #2590: ACT IS NOT SPAWN. A measured ZERO SPAWNS must take the word "dispatch" out of the line even
# though the ledger reported actions — the live defect was `2 acted (#9812,#9528)` where #9528's row was
# `auto-armed`, i.e. a button press counted as a dispatch.
sel3 3 0 3 0 42 '' 9 2 4 ok 0; choice="$LO_CHOICE_V"
eqv "(i) acts but 0 spawns -> still the PR choice" "pr" "$choice"
case "$line" in *"dispatching"*) bad "(i) the funnel claimed 'dispatching' on a pass that started NO worker: $line" ;;
  *) ok "(i) 2 actions and 0 spawns does NOT claim a dispatch" ;; esac
case "$line" in *"NO WORKER SPAWNED"*"0 worker records"*) ok "(i) ...it names the measured zero, and says an arm/rerun starts nothing" ;;
  *) bad "(i) the zero-spawn wording is missing: $line" ;; esac
# ...and one real spawn restores the claim, WITH the count, so the line is backed by an artifact.
sel3 3 0 3 0 42 '' 9 2 4 ok 1; choice="$LO_CHOICE_V"
case "$line" in *"dispatching PR-takeover (first #42"*"1 worker(s) spawned"*) ok "(j) a measured spawn restores the claim and prints the count behind it" ;;
  *) bad "(j) the funnel dropped its claim (or its evidence) with 1 spawn: $line" ;; esac
# 0 spawns AND nothing recorded is BOTH readings, not one: the spawn count WAS measured.
sel3 3 0 3 0 42 '' 9 0 0 unknown 0; choice="$LO_CHOICE_V"
case "$line" in *"measured: 0 worker records"*"UNKNOWN, not zero"*) ok "(k) a measured zero spawn beside an unwritable ledger says BOTH" ;;
  *) bad "(k) the two readings were collapsed: $line" ;; esac
# An UNREADABLE spawn count is not a zero: an old module/caller must not be rendered as "nothing spawned".
sel3 3 0 3 0 42 '' 9 2 4 ok ''; choice="$LO_CHOICE_V"
case "$line" in *"dispatching PR-takeover"*) ok "(l) an UNREPORTED spawn count leaves the acted-based wording alone (compatible)" ;;
  *) bad "(l) an unreported spawn count changed the wording: $line" ;; esac
# An unreadable count must not open the issue path (assuming 0 would be the fail-open direction).
sel3 5 0 '' 0 - '' 9; choice="$LO_CHOICE_V"
eqv "an UNREADABLE un-owned count -> PRs (drain), never issues" "pr" "$choice"
case "$line" in *"UNREADABLE"*) ok "…and the funnel says the count was unreadable" ;;
  *) bad "…the funnel hid that the count was unreadable: $line" ;; esac
# Parked PRs are subtracted by the CALLER (upstream of this function), so pin that the exclusion is
# PRINTED: otherwise "3 un-owned" and "3 un-owned, 3 of them unworkable" read identically.
sel3 4 0 0 3 - '' 2
case "$line" in *"3 parked/needs-human excluded"*) ok "the funnel SHOWS how many un-owned PRs are parked (unworkable)" ;;
  *) bad "the funnel hid the parked exclusion: $line" ;; esac

echo
echo "=== 9) REVIEW R1: a ref that cannot identify a PR cannot prove ownership ==="
# A fork PR's headRefName is only a branch name. Before this guard, ANY PR whose head ref equalled a
# branch some process was merely SITTING on read OWNED — including this repo's own `main` checkout.
ROOT_BR="$(git -C "$R" rev-parse --abbrev-ref HEAD)"
printf 'main\t%s\t12345\t%s\n' "$R" "$R" > "$T/live-main.tsv"
lo_owns_branch "$T/live-main.tsv" main \
  && bad "a live process on 'main' owned a PR whose head ref is 'main' — a shared ref is not PR identity" \
  || ok "a live process on 'main' does NOT own a PR whose head ref is 'main' (shared refs are refused)"
lo_owns_branch "$T/live-main.tsv" master \
  && bad "'master' was accepted as PR identity" || ok "'master' is refused as PR identity"
lo_owns_branch "$LO_LIVE" main \
  && bad "a stale LIVE TABLE owned a PR on 'main'" || ok "…and the refusal holds over the real live table"
# The branch arm still works for a ref that CAN identify work (the guard must not break case 1b).
git -C "$R" worktree list --porcelain | grep -q "fix/9007-thing" || bad "fixture lost its worktree"
lo_owns_branch "$LO_LIVE" fix/9007-thing \
  && ok "…while a PR-shaped branch (fix/9007-thing) still owns" \
  || bad "the refusal broke the branch arm for a real PR branch"

echo
echo "=== 10) REVIEW R1: an UNREGISTERED cwd under .worktrees/ does not inherit the root branch ==="
# A deleted worktree's directory can still be a process cwd; the longest-prefix match then falls back
# to the ROOT checkout and reported its branch — so a PR on the root's branch read OWNED with nobody
# working it. Measured on this box: two `main` rows, one from a deleted .worktrees path.
mkdir -p "$R/.worktrees/gone-9999"
( cd "$R/.worktrees/gone-9999" && exec sleep 300 ) & SPIDS="$SPIDS $!"
sleep 0.4
lo_scan "$T/live-stale.tsv" "$R"
rootrows="$(awk -F'\t' -v b="$ROOT_BR" -v w="$R" '$1 == b && $2 == w' "$T/live-stale.tsv" | wc -l | tr -d ' ')"
stalerows="$(awk -F'\t' '$1 == "(stale)"' "$T/live-stale.tsv" | wc -l | tr -d ' ')"
[ "$stalerows" -ge 1 ] && ok "the unregistered .worktrees/ cwd is marked (stale), not given a branch" \
  || bad "the unregistered .worktrees/ cwd was not marked (stale) — it inherited a real branch"
lo_pr_owned "$T/live-stale.tsv" 9999 "$ROOT_BR" 2>/dev/null \
  && bad "a stale .worktrees/ cwd owned a PR on the root checkout's branch" \
  || ok "…so a PR on the root branch is NOT read owned from a stale worktree"
# ⛔ AND THE PATH ARM MUST REFUSE IT TOO (review R2, P1): marking the branch fixed only half the
# predicate. One leftover process in a deleted `.worktrees/fix/1712-x` still owned PR #1712 through the
# path rule — the exact row the branch guard was added for.
mkdir -p "$R/.worktrees/fix-1712-abc"
( cd "$R/.worktrees/fix-1712-abc" && exec sleep 300 ) & SPIDS="$SPIDS $!"
sleep 0.4
lo_scan "$T/live-stale2.tsv" "$R"
lo_pr_owned "$T/live-stale2.tsv" 1712 feat/1712-thing \
  && bad "PR #1712 was owned by a sleep in a DELETED .worktrees/fix-1712-abc (the path arm)" \
  || ok "a (stale) row matches no PR by PATH either (1712 is not owned by a leftover sleep)"
# …and a REGISTERED worktree whose path carries the number still owns by path (no over-refusal).
lo_pr_owned "$LO_LIVE" 9100 chore/no-pr-name \
  && ok "…while a REGISTERED worktree path still owns by its number (9100)" \
  || bad "the (stale) refusal also broke the legitimate path arm"
# A process legitimately AT the root still names the root's branch (the guard must not over-refuse).
( cd "$R" && exec sleep 300 ) & SPIDS="$SPIDS $!"
sleep 0.4
lo_scan "$T/live-root.tsv" "$R"
[ "$(awk -F'\t' -v b="$ROOT_BR" '$1 == b' "$T/live-root.tsv" | wc -l | tr -d ' ')" -ge 1 ] \
  && ok "a process actually AT the root checkout still reports the root branch" \
  || bad "the stale marker swallowed a genuine root-checkout row"

echo
echo "=== 11) REVIEW R1: a QUIET box is an ANSWER; a FAILED census is UNKNOWN ==="
QREPO="$T/quiet-repo"
git init -q "$QREPO" && git -C "$QREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  || bad "could not create the quiet fixture repo"
lo_scan "$T/quiet.tsv" "$QREPO"; rc=$?
eqv "a repo NO process is working scans rc=0 (a real answer: everything un-owned)" "0" "$rc"
[ -s "$T/quiet.tsv" ] && bad "the quiet scan wrote rows it could not have" || ok "…and writes no rows"
lo_scan "$T/none2.tsv" "$T/does-not-exist"; rc=$?
[ "$rc" -ne 0 ] && ok "a scan of a MISSING repo is still non-zero (UNKNOWN, never 'nobody works')" \
  || bad "a missing repo scanned as success"
# A census that read nothing at all is UNKNOWN even when the repo exists: drive it by hiding the
# process probe, which is what an absent/broken lsof looks like.
( LO_CWD_PROBE=/nonexistent/lsof lo_scan "$T/nocensus.tsv" "$QREPO" ) 2>/dev/null; rc=$?
eqv "a census that read NOTHING is rc=2 (UNKNOWN) even for a valid repo" "2" "$rc"

echo
echo "=== 12) REVIEW R2: a failed WRITE must not leave yesterday's table reading as ownership ==="
# The write status was discarded: an unwritable state/ left the previous cycle's rows in place,
# lo_scan returned 0, the controller printed scan=ok, and pr_owned then read processes that had died.
WREPO="$T/wrepo"
git init -q "$WREPO" && git -C "$WREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  || bad "could not create the write-failure fixture"
git -C "$WREPO" worktree add -q "$T/wrepo-wt" -b fix/7001-thing >/dev/null 2>&1 || bad "worktree add failed"
( cd "$T/wrepo-wt" && exec sleep 300 ) & SPIDS="$SPIDS $!"
sleep 0.4
WOUT="$T/wtable.tsv"
lo_scan "$WOUT" "$WREPO"; rc=$?
eqv "a writable scan succeeds" "0" "$rc"
lo_pr_owned "$WOUT" 7001 fix/7001-thing && ok "…and the row owns its PR while the process is alive" \
  || bad "the row did not own its PR"
: > "$T/prev-rows.tsv"
cp "$WOUT" "$T/wtable.keep"
chmod 500 "$T" 2>/dev/null || true          # the DIRECTORY is not writable → the temp write fails
lo_scan "$WOUT" "$WREPO"; rc=$?
chmod 700 "$T" 2>/dev/null || true
[ "$rc" -ne 0 ] && ok "a scan whose write fails returns NON-ZERO (UNKNOWN, not 'ok')" \
  || bad "a failed write still reported a successful scan (rc=$rc)"
# A read-only directory cannot be written to AND cannot be cleaned — so the module's own contract is
# the STATUS (rc≠0 = UNKNOWN); the CALLER must stop reading the table on a non-zero scan, which
# orch-loop does by blanking LO_LIVE (pinned in test-gates.sh). Both halves are asserted, in the layer
# that owns each: a module that claimed to have cleaned up when it could not would be the false
# reassurance, not the guarantee.
ok "the failed write is reported as UNKNOWN (rc≠0) — the caller, not the module, decides what to read"
cp "$T/wtable.keep" "$WOUT" 2>/dev/null || true

echo
echo "=== 13) REVIEW R2: the funnel's marks refuse the same shared refs as the gate ==="
printf 'main\t%s\t4242\t%s\n' "$R" "$R" > "$T/sr.tsv"
printf '7\tmain\tfalse\n' | lo_select_rows "$T/sr.tsv" > "$T/sr.out" 2>/dev/null
case "$(cat "$T/sr.out")" in
  *UNOWNED*) ok "lo_select_rows marks a PR whose head ref is 'main' UNOWNED (same predicate as pr_owned)" ;;
  *) bad "lo_select_rows marked a 'main' PR OWNED while pr_owned refuses it: $(cat "$T/sr.out")" ;;
esac
printf 'fix/7-thing\t%s\t4243\t%s\n' "$R" "$R" > "$T/sr2.tsv"
printf '7\tfix/7-thing\tfalse\n' | lo_select_rows "$T/sr2.tsv" > "$T/sr2.out" 2>/dev/null
case "$(cat "$T/sr2.out")" in
  *OWN*) ok "…while a PR-shaped branch is still marked OWN" ;;
  *) bad "the shared-ref refusal broke the legitimate mark: $(cat "$T/sr2.out")" ;;
esac

echo
echo "──────────────────────────────────────────────"
echo "live-ownership: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
