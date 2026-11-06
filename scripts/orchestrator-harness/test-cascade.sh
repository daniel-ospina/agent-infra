#!/usr/bin/env bash
# test-cascade.sh — merge-priority is a PRIORITY, not a BARRIER (owner ruling 2026-11-04).
#
# ⛔ THE MEASURED DEFECT THIS SUITE PINS. On the live box, over 1,219 recorded cycles:
#     [select] 15 PRs: 13 un-owned (2 owned, 0 parked/needs-human excluded) -> dispatching
#              PR-takeover … 6 worker(s) spawned
#     nothing=gate:merge-priority_(13_un-owned_of_15_open_PR(s) — PRs before issues)
#   `dispatched>0` in 8 cycles (0.66%), each exactly `dispatched=2` — 16 issues in 12.45 days =
#   0.054/h against an 8.1/h pacing bound (0.7%) — while the PR path ran 8.59 workers/h. Two causes:
#   (a) the COUNT called a PR un-owned while a review/fix/CI lane was live against it, so it never
#   reached zero; (b) the count was wired to `GATE_WHY`, which is a BARRIER, so no idle capacity could
#   ever reach the issue path.
#
# WHAT THIS SUITE GRADES, AND WHY EACH ASSERTION CAN GO RED
#   1  the allocator honours the ORDER (PR work first) without a new pacing  → mutant: ignore `lanes`
#   2  a live review/fix/merge lane is OWNED                                 → mutant: drop the census arm
#   3  a check in progress is OWNED only for the head it was seen on         → mutant: drop the head bind
#   4  the gate is gone and the priority remains                             → mutant: restore GATE_WHY=
#   5  the funnel can say "issue" with un-owned PRs open                     → mutant: ignore arg 12
#   6  the batch cap is capacity, not one BATCH                              → mutant: restore `-ge "$BATCH"`
#   7  an issue already in flight is not queued again                        → mutant: drop the dedup arm
#   8  a wedged lane holds neither a PR nor a slot                           → mutant: drop the wedge filter
#   9  a full box with work waiting polls for a slot instead of napping       → mutant: drop CASCADE_WAIT
#  10  the departure from the recorded ruling is NAMED where a reader meets it  → (source pins)
#  11  THE PYRAMID: levels 1-5, filled top-down, and 1-4 hold the room           → mutants: M11-M13
#  12  level 1 is fed by MAIN's own check-runs, and UNMEASURED is NOT red       → mutants: M13, M14
#  13  level 4 is a LOOP: a fix moves the head, and the next pass reviews again → (drives review_disp_decide)
#
# ⛔ EVERY FUNCTION UNDER TEST IS EXTRACTED FROM THE SHIPPED SCRIPT, never re-implemented here: a
# mirror would grade itself. Every mutation is applied to a COPY of the shipped file and the SAME
# assertion is re-run against the copy, so "the assertion can fail" is measured rather than claimed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${ORCH:-$HERE/orch-loop.sh}"
LO="${LO:-$HERE/live-ownership.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cascade-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
ck()   { # ck <label> <got> <want>
  if [ "${2:-}" = "${3:-}" ]; then ok "$1  (=$3)"; else bad "$1 — want [$3] got [$2]"; fi; }
ckin() { # ckin <label> <haystack> <needle>
  case "${2:-}" in *"${3:-}"*) ok "$1" ;; *) bad "$1 — [$2] does not contain [$3]" ;; esac; }
ckni() { # ckni <label> <haystack> <needle>
  case "${2:-}" in *"${3:-}"*) bad "$1 — [$2] STILL contains [$3]" ;; *) ok "$1" ;; esac; }

# ── extraction ───────────────────────────────────────────────────────────────────────────────────
[ -f "$ORCH" ] || { echo "❌ $ORCH not found"; exit 1; }
[ -f "$LO" ]   || { echo "❌ $LO not found"; exit 1; }
# ⛔ A ONE-LINER MUST NOT DRAG THE REST OF THE FILE. `is_num() { … }` is spelled on ONE line in
# orch-loop.sh, so a `/^name()/,/^}/` RANGE never terminates inside it and swallows everything down to
# the next standalone `}` — hundreds of lines of the controller get `eval`'d into the rig, including a
# top-level `if [ -f "$O/…" ]` that dies on `set -u` before a single assertion runs. That is how this
# suite could pass while grading nothing; it was measured here (fns.sh was 764 lines). Take the
# single line when the declaration IS the whole function, and the range only when it is not.
ex() { # <fn> <file>
  local ln
  ln="$(grep -nE "^$1\(\) \{" "$2" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || return 0
  if sed -n "${ln}p" "$2" | grep -qE '\}[[:space:]]*$'; then
    sed -n "${ln}p" "$2"
  else
    sed -n "/^$1()/,/^}/p" "$2"
  fi
}
FNS="$TMP/fns.sh"
: > "$FNS"
for _f in is_num is_limit pr_in_set _wedge_min measure_ownership_sets measure_ci_inflight pr_owned \
          unowned_scan mp_reason cascade_issue_slots cascade_wait \
          cascade_level_name cascade_main_red cascade_level cascade_main_probe; do
  _body="$(ex "$_f" "$ORCH")"
  if [ -z "$_body" ]; then echo "❌ could not extract $_f() from $ORCH — it moved or was reformatted"; exit 1; fi
  printf '%s\n' "$_body" >> "$FNS"
done
# `unowned_scan` needs the fail-closed reader it calls; extract it rather than stub it, or the suite
# would grade a counting path production never runs.
printf '%s\n' "$(ex unowned_pr_count "$ORCH")" >> "$FNS"
# `lo_select`/`lo_num` come from the OWNERSHIP module (the funnel is the module's, not the loop's).
printf '%s\n' "$(ex lo_num "$LO")" "$(ex lo_select "$LO")" >> "$FNS"
STUB="$TMP/stub.sh"
cat > "$STUB" <<'STUBEOF'
# The harness seams production also provides. `claim_foreign_live` reaching 127 would read as "not
# owned", which is the answer these fixtures want, but it would do so by a command that does not run —
# so it is stubbed to the same ANSWER with a reason.
claim_foreign_live() { return 1; }
fork_free_sleep() { sleep "$1" 2>/dev/null; return 0; }
load1() { printf '0.10\n'; }
can_spawn() { [ "${TEST_CAN_SPAWN:-1}" = "1" ]; }
measure_lanes() { LANES="${TEST_LANES:-0}"; LANES_DISPLAY="$LANES"; LANES_TOTAL="$LANES"; LANES_UNKNOWN=0; }
STUBEOF
LOG="$TMP/log"; : > "$LOG"
CYC=240

# ── 1. THE ORDER: the allocator gives issues only the room PR work left ─────────────────────────
echo
echo "=== 1. THE CASCADE'S ORDER (owner: \"we should launch that first priority\") ==="
# ⛔ THE ORDER IS MEASURED, NOT PROMISED: the PR sweep runs earlier in the pass and its workers are
# already counted in `LANES` when the issue batch asks for room, so "PR work took 2 of 4 lanes" is the
# input `cascade_issue_slots` receives on a cycle where PR work got there first.
. "$FNS"; . "$STUB"
ck "PR path took 2 of 4 lanes, backlog 10 -> 1 issue (the leftover room, halved)" "$(cascade_issue_slots 4 2 10 1)" "1"
ck "PR path took 0 of 4 lanes, backlog 10 -> 2 issues (all the room)"             "$(cascade_issue_slots 4 0 10 1)" "2"
ck "box FULL (4 of 4) -> 0 issues, whatever the backlog"                          "$(cascade_issue_slots 4 4 10 1)" "0"
ck "room 1 -> 1 issue (a lane that parks early never attaches its chain)"          "$(cascade_issue_slots 5 4 10 1)" "1"
ck "backlog smaller than the room -> the backlog is the limit"                      "$(cascade_issue_slots 10 0 1 1)" "1"
ck "capacity REFUSED (load/mem) -> 0 issues even with room"                        "$(cascade_issue_slots 4 0 10 0)" "0"
ck "an UNREADABLE lane census -> 0 issues (an unread census must not ADD work)"     "$(cascade_issue_slots 4 '?' 10 1)" "0"
# ⛔ AND THE OTHER HALF OF THE ORDER: the reserve must not become a new pacing knob. `BATCH` is not an
# input at all — a pass fills what the box allows (owner: \"do not stop at one batch\").
ck "a big box is not capped back to BATCH=2"                                        "$(cascade_issue_slots 25 0 40 1)" "12"

# ── 2. OWNERSHIP: a live review/fix/merge lane is OWNED ─────────────────────────────────────────
echo
echo "=== 2. WHAT 'OWNED' MEANS NOW: under review, being fixed, in CI (owner ruling 2026-11-04) ==="
W="$TMP/w2"; mkdir -p "$W/state" "$W/logs"
export O="$W" CYCLE_T0=1000 STALE_MIN=40
# The census the spawner itself uses. `review-9001` is the case that was BROKEN: a reviewer reads the
# PR through `gh` and holds no branch, so the cwd probe cannot see it and the count called it un-owned
# while the spawn arms refused to double-work it.
wt_table() { printf 'review-9001\talive\nfix-9002\talive\nmerge-9003\talive\nreview-9004\tdead\nlane-77\talive\nchain-78\tunknown\n'; }
: > "$W/logs/review-9001.log"; : > "$W/logs/fix-9002.log"; : > "$W/logs/merge-9003.log"
printf '9001:shaA:fix/9001-a 9002:shaB:fix/9002-b 9003:shaC:fix/9003-c 9004:shaD:fix/9004-d\n' > "$W/state/last-open-prs"
measure_ownership_sets
ck "the census's live review lane is in WORKING_PR_SET"  "$(case "$WORKING_PR_SET" in *' 9001 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…its live fix lane too"                              "$(case "$WORKING_PR_SET" in *' 9002 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…and its live merge lane"                            "$(case "$WORKING_PR_SET" in *' 9003 '*) echo yes;; *) echo no;; esac)" "yes"
ck "a DEAD record is NOT ownership (the census proves the death)" "$(case "$WORKING_PR_SET" in *' 9004 '*) echo yes;; *) echo no;; esac)" "no"
ck "a live lane-<N> is in INFLIGHT_ISSUE_SET (the pass's dedup input)" "$(case "$INFLIGHT_ISSUE_SET" in *' 77 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…and an `unknown` worker counts ALIVE (a probe failure must not free a slot)" "$(case "$INFLIGHT_ISSUE_SET" in *' 78 '*) echo yes;; *) echo no;; esac)" "yes"
ck "THE MEASURED CASE: 3 of the 4 open PRs are owned, so unowned=1, not 4" "$(unowned_pr_count 4)" "1"
ck "…and pr_owned() answers the SAME question the spawn arms ask" "$(pr_owned 9001 shaA fix/9001-a && echo owned || echo unowned)" "owned"
# The count and the spawn guard must not disagree about the same PR (the #3096 shape, one level up).
ck "the un-owned one is the one with no live worker" "$(pr_owned 9004 shaD fix/9004-d && echo owned || echo unowned)" "unowned"

# ── 3. CI IN PROGRESS IS OWNED, AND IT IS BOUND TO THE HEAD ─────────────────────────────────────
echo
echo "=== 3. A CHECK IN PROGRESS IS OWNED — for THAT head only ==="
W3="$TMP/w3"; mkdir -p "$W3/state" "$W3/logs"
export O="$W3"
printf '9101:shaA:b1 9102:shaB:b2 9103:shaC:b3\n' > "$W3/state/last-open-prs"
# 9101: PENDING on the head the listing still shows  -> owned
# 9102: PENDING on a head that has since MOVED       -> NOT owned (a different tree)
# 9103: GREEN                                         -> not owned
printf '9101\tshaA\tPENDING\n9102\toldsha\tPENDING\n9103\tshaC\tGREEN\n' > "$W3/state/prclass.tsv"
measure_ci_inflight
ck "a PENDING observation of the CURRENT head is owned (\"going through CI\")" "$(case "$CI_INFLIGHT_SET" in *' 9101 '*) echo yes;; *) echo no;; esac)" "yes"
ck "a PENDING observation of a SUPERSEDED head is NOT ownership"              "$(case "$CI_INFLIGHT_SET" in *' 9102 '*) echo yes;; *) echo no;; esac)" "no"
ck "a GREEN head is not 'in CI'"                                             "$(case "$CI_INFLIGHT_SET" in *' 9103 '*) echo yes;; *) echo no;; esac)" "no"
ck "…so unowned for that listing is 2 (9102, 9103)" "$(unowned_pr_count 3)" "2"

# ── 4. THE GATE IS GONE; THE PRIORITY AND ITS EVIDENCE REMAIN ───────────────────────────────────
echo
echo "=== 4. merge-priority ORDERS the cycle and no longer CLOSES the issue path ==="
SRC="$(cat "$ORCH")"                  # whole file (comments included)
SRC_CODE="$(grep -vE '^[[:space:]]*#' "$ORCH")"   # CODE only: a comment must never grade a gate
ckni "the issue-path gate is NOT fed by mp_reason" "$SRC_CODE" 'GATE_WHY="$(mp_reason'
ckin "the priority IS still fed by mp_reason (the rule survived the rewiring)" "$SRC" 'MP_PRIORITY="$(mp_reason'
ckin "the vector names the priority and the slots it left, so ordering is legible" "$SRC" 'merge-priority(priority:'
# ── the cascade block itself, extracted and DRIVEN ──────────────────────────────────────────────
awk '/^  # \[cascade:begin\]/{f=1} f{print} /^  # \[cascade:end\]/{if(f) exit}' "$ORCH" > "$TMP/cascade-block.sh"
ck "the [cascade:begin]/[cascade:end] block was found (a marker rename would skip the drive)" \
   "$( [ -s "$TMP/cascade-block.sh" ] && echo found || echo missing )" "found"
drive_cascade() { # <unowned> <lanes> <max_lanes> <backlog> <can> -> "slots pr_waiting wait"
  local d="$TMP/dc$$"; rm -rf "$d"; mkdir -p "$d"
  ( O="$d"; LOG=/dev/null; UPN_WORK="$1"; UPN="$1"; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
    LANES="$2"; LANES_DISPLAY="$2"; MAX_LANES="$3"; SEL_PARKED=0
    TEST_CAN_SPAWN="$5"
    : > "$d/candidates.txt"
    _i=0; while [ "$_i" -lt "$4" ]; do printf '100%s\n' "$_i" >> "$d/candidates.txt"; _i=$((_i+1)); done
    . "$FNS"; . "$STUB"
    # shellcheck source=/dev/null
    . "$TMP/cascade-block.sh"
    printf '%s %s %s\n' "$CASCADE_ISSUE_SLOTS" "$CASCADE_PR_WAITING" "$CASCADE_WAIT" ) 2>/dev/null
}
ck "un-owned PR work + FREE room -> the cascade opens (slots>0, pr_waiting=0)" "$(drive_cascade 5 2 25 10 1)" "10 0 0"
ck "un-owned PR work + NO room    -> PR priority holds (slots=0, pr_waiting=1, waits)" "$(drive_cascade 5 25 25 10 1)" "0 1 1"
ck "no un-owned PRs + free room  -> the cascade opens exactly as before" "$(drive_cascade 0 0 25 10 1)" "10 0 0"
ck "no un-owned PRs + empty backlog -> nothing to wait for" "$(drive_cascade 0 0 25 0 1)" "0 0 0"
# ⛔ POLARITY ON THE ROOM ITSELF. `merge-priority` used to carry a fail-closed arm (any unreadable
# count closed the issue path). Removing the barrier must not remove the polarity, or the one listing
# failure that should drain hardest becomes the one that DISPATCHES new work. These three are a set:
# the first two must withhold, the third proves the branch is not simply always closed.
ck "an UNREADABLE un-owned count gives the issue path NO room (fails closed)" \
   "$(drive_cascade abc 2 25 10 1)" "0 1 1"
ck "…and an OUT-OF-RANGE all-digit count does too (is_num passes it, \`[\` would error OPEN)" \
   "$(drive_cascade 99999999999999999999 2 25 10 1)" "0 1 1"
ck "…while the SAME room with a readable count still opens (contrast half)" \
   "$(drive_cascade 5 2 25 10 1)" "10 0 0"

# ── 5. THE FUNNEL FOLLOWS (lo_select) ──────────────────────────────────────────────────────────
echo
echo "=== 5. THE FUNNEL says what the loop DOES (a printed decision the gate ignores is the old bug) ==="
sel() { # <unowned> <pr_waiting|-> <cap>  -> "CHOICE<TAB>line"
  ( . "$FNS"; lo_select 15 0 "$1" 0 3 "${3:-}" 10 1 2 ok 1 "$2" > "$TMP/sel.$$" 2>/dev/null
    printf '%s\t%s\n' "$LO_CHOICE" "$(cat "$TMP/sel.$$")" ) }
_t="$(sel 5 0 '')"
ck "un-owned PRs + cascade open -> LO_CHOICE=issue" "$(printf '%s' "$_t" | cut -f1)" "issue"
ckin "…and the line names the CASCADE (not 'SKIPPED: un-owned PRs exist')" "$_t" "CASCADE"
_2="$(sel 5 1 '')"
ck "un-owned PRs + no room -> LO_CHOICE=pr (PR work holds the priority)" "$(printf '%s' "$_2" | cut -f1)" "pr"
ckin "…and it says DEFERRED with the reason, not 'CLOSED'" "$_2" "DEFERRED"
ck "an OLDER caller (no arg 12) keeps the pre-change answer" "$(printf '%s' "$(sel 5 - '')" | cut -f1)" "pr"
ck "un-owned PRs + cascade open + ANOTHER gate fired -> none (the capacity arm still wins)" \
   "$(printf '%s' "$(sel 5 0 'lanes=25>=max_lanes=25')" | cut -f1)" "none"
ck "an UNREADABLE un-owned count still drains (never opens on a number nobody read)" \
   "$(printf '%s' "$( { . "$FNS"; lo_select 15 0 abc 0 3 '' 10 '' 0 unknown '' '' >/dev/null 2>&1; printf '%s' "$LO_CHOICE"; } )" | tail -1)" "pr"

# ── 6. THE BATCH CAP IS CAPACITY, NOT ONE BATCH ────────────────────────────────────────────────
echo
echo "=== 6. one pass fills capacity (owner: \"do not stop at one batch\") ==="
ckin "the batch breaks on CASCADE_ISSUE_SLOTS" "$SRC" '[ "$K" -ge "${CASCADE_ISSUE_SLOTS:-${BATCH:-2}}" ] && break'
ckni "…and NOT on BATCH alone" "$SRC" '[ "$K" -ge "$BATCH" ] && break'
ckin "the loop refuses to queue anything when the cascade granted 0" "$SRC" '[ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 ] 2>/dev/null || break'

# ── 7. DEDUP: an issue already in flight is not queued twice ───────────────────────────────────
echo
echo "=== 7. each pass dedups (owner ask 4a) ==="
ckin "the batch consults the in-flight set before queueing" "$SRC" 'pr_in_set "${INFLIGHT_ISSUE_SET:- }" "$ISS"'
ck "the dedup is EXACT, not a substring match (issue 7 in flight must not skip 17)" \
   "$( { . "$FNS"; pr_in_set " 7 " 17 && echo hit || echo miss; } )" "miss"
ck "…and it does match when the value IS in the set" "$( { . "$FNS"; pr_in_set " 7 17 " 17 && echo hit || echo miss; } )" "hit"

# ── 8. WEDGE: alive but no progress holds neither a PR nor a slot ─────────────────────────────
echo
echo "=== 8. a WEDGED lane is not ownership (owner ask 4b) ==="
W8="$TMP/w8"; mkdir -p "$W8/state" "$W8/logs"
export O="$W8"
wt_table() { printf 'review-9201\talive\nreview-9202\talive\n'; }
: > "$W8/logs/review-9201.log"
touch -t 202001010000 "$W8/logs/review-9201.log"      # long past the wedge bound
: > "$W8/logs/review-9202.log"                        # fresh: working
printf '9201:sA:b1 9202:sB:b2\n' > "$W8/state/last-open-prs"
measure_ownership_sets
ck "a record whose log stopped advancing is WEDGED, and named" "$(case "$WEDGED_SET" in *' review-9201 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…it does NOT own its PR (the PR is dispatchable again)"   "$(case "$WORKING_PR_SET" in *' 9201 '*) echo yes;; *) echo no;; esac)" "no"
ck "…so that PR counts UN-OWNED rather than held for ever"    "$(pr_owned 9201 sA b1 && echo owned || echo unowned)" "unowned"
ck "a WORKING lane still owns its PR"                         "$(pr_owned 9202 sB b2 && echo owned || echo unowned)" "owned"
ckin "a hung REVIEWER is reaped (it was the omission: the reaper walked merge/lane/fix only)" \
     "$SRC" 'case "$s" in merge-*|lane-*|fix-*|review-*) : ;; *) continue ;; esac'
ckin "the wedge count is printed even when it is zero (no silent instrument)" "$SRC" '[reap-worker] wedged='

# ── 9. THE WAIT: a full box polls for a slot instead of napping through it ─────────────────────
echo
echo "=== 9. fill the capacity, do not sleep through it (owner ask 3) ==="
ckin "the interval is handed to the cascade when work is waiting and the box is full" "$SRC" 'elif [ "${CASCADE_WAIT:-0}" = "1" ]; then'
ckin "…and the poll re-cycles the moment a slot frees" "$SRC" '[cascade] a slot freed after'
# Driven: with room appearing on the second sample, the wait returns 0 (re-cycle NOW) quickly.
_w="$TMP/w9"; mkdir -p "$_w"
( O="$_w"; LOG="$_w/log"; CYC=240; CASCADE_POLL=1; MAX_LANES=4; TEST_LANES=4
  . "$FNS"; . "$STUB"
  _n=0
  measure_lanes() { _n=$((_n+1)); LANES=$([ "$_n" -ge 2 ] && echo 2 || echo 4); LANES_DISPLAY="$LANES"; LANES_TOTAL="$LANES"; LANES_UNKNOWN=0; }
  measure_lanes
  cascade_wait 30; printf 'rc=%s\n' "$?" ) > "$TMP/w9.out" 2>/dev/null
ck "cascade_wait returns 0 (re-cycle NOW) as soon as a slot frees" "$(cat "$TMP/w9.out")" "rc=0"
ckin "…and it says so, with the measurement" "$(cat "$_w/log" 2>/dev/null || true)" "RE-CYCLING NOW"

# ── 11. THE PYRAMID: five levels, filled top-down ───────────────────────────────────────────────
# ⛔ THE ROOM IS NOT THE ORDER. `cascade_issue_slots` answers "how much room did PR work leave";
# these arms pin WHICH LEVEL owns that room. A pass that resolves to 1-4 must grant the issue batch
# NOTHING, because "an issue is never dispatched while a mergeable PR is waiting" is the recorded
# order — and on the allocator alone that rule is FALSE: leftover lanes went to issues while a merge
# waited on its own ceiling.
echo
echo "=== 11. THE PYRAMID — 1 fixes main, 2 merges, 3 fixes, 4 reviews, 5 issues ==="
# The class file is `<pr>\t<head>\t<class>`; the listing is `<pr>:<head>:<branch>`.
drive_level() { # <listing> <prclass-rows|-> <main-verdict|-> <owned-prs|-> -> "<level> <name>"
  local w="$TMP/lv$$"
  rm -rf "$w"; mkdir -p "$w/state"
  printf '%s\n' "$1" > "$w/state/last-open-prs"
  : > "$w/state/prclass.tsv"
  [ -n "${2:-}" ] && [ "${2}" != "-" ] && printf '%s' "$2" > "$w/state/prclass.tsv"
  [ -n "${3:-}" ] && [ "${3}" != "-" ] && printf '%s\n' "$3" > "$w/state/main-verdict"
  ( O="$w"; LOG=/dev/null
    . "$FNS"; . "$STUB"
    # Ownership reduces to the census facts here: a live lane / a check in flight. No locks, no
    # claims, no probes — the PREDICATE under test is the level, not `pr_owned` (section 2 owns it).
    OWN_SET="${4:-}"
    pr_owned() { [ -n "${OWN_SET:-}" ] && pr_in_set " $OWN_SET " "$1" && return 0; return 1; }
    cascade_level "$w/state"
    printf '%s %s\n' "$CASCADE_LEVEL" "$CASCADE_LEVEL_NAME" ) 2>/dev/null
}
ck "L2: a GREEN un-owned PR on its current head is a MERGE waiting" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
' - -)" "2 MERGE"
ck "L3: a RED un-owned PR needs its fix" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	RED
' - -)" "3 FIX_PR"
ck "L4: an un-classified un-owned PR is REVIEW work" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	NOCHECKS
' - -)" "4 REVIEW_PR"
ck "L5: no un-owned PR work left -> ISSUES" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
' - 9001)" "5 ISSUES"
# ⛔ THE ORDER ITSELF, WHICH IS THE WHOLE POINT: a mergeable PR outranks a red one, and a red one
# outranks a reviewable one — the FIRST level with work wins and nothing below it is consulted.
ck "ORDER: mergeable beats red (level 2, not 3)" \
   "$(drive_level '9001:shaA:fix/a 9002:shaB:fix/b' '9001	shaA	RED
9002	shaB	GREEN
' - -)" "2 MERGE"
ck "ORDER: red beats review (level 3, not 4)" \
   "$(drive_level '9001:shaA:fix/a 9002:shaB:fix/b' '9001	shaA	NOCHECKS
9002	shaB	RED
' - -)" "3 FIX_PR"
# ⛔ HEAD-BOUND: a class observed on a head the listing no longer shows says NOTHING about this tree.
ck "a GREEN row for a SUPERSEDED head does not make a mergeable PR" \
   "$(drive_level '9001:newsha:fix/a' '9001	oldsha	GREEN
' - -)" "4 REVIEW_PR"
# ⛔ AN UNREADABLE POPULATION DECIDES NOTHING. It is not level 5 (which would claim the pyramid is
# empty on a listing nobody read) and it is not level 2 either.
ck "an UNREADABLE listing -> '?' (the level decides nothing)" "$(drive_level '' '' - -)" "? UNMEASURED"
ck "level 1 outranks every population below it (a RED main is level 1 even with a green PR)" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
' 'RED:verify')" "1 FIX_MAIN"
ck "an UNMEASURED main is NOT a red (the merged-#3503 re-reporting defect)" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
' 'UNMEASURED the listing failed')" "2 MERGE"
ck "…and a GREEN main is not a red either" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
' 'GREEN')" "2 MERGE"

# ⛔ THE HEADLINE ASSERTION, DRIVEN THROUGH THE SHIPPED BLOCK: a mergeable PR waiting takes the room
# back from the issue batch. This is "an issue is NEVER dispatched while a mergeable PR is waiting".
drive_block() { # <unowned> <lanes> <max> <backlog> <can> <listing> <prclass> <owned-prs> -> "slots prw wait level"
  local w="$TMP/blk$$"
  rm -rf "$w"; mkdir -p "$w/state"
  printf '%s\n' "$6" > "$w/state/last-open-prs"
  : > "$w/state/prclass.tsv"
  [ -n "${7:-}" ] && [ "${7}" != "-" ] && printf '%s' "$7" > "$w/state/prclass.tsv"
  ( O="$w"; LOG=/dev/null; UPN_WORK="$1"; UPN="$1"; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
    LANES="$2"; LANES_DISPLAY="$2"; MAX_LANES="$3"; SEL_PARKED=0; TEST_CAN_SPAWN="$5"
    : > "$w/candidates.txt"; _i=0
    while [ "$_i" -lt "$4" ]; do printf '100%s\n' "$_i" >> "$w/candidates.txt"; _i=$((_i+1)); done
    . "$FNS"; . "$STUB"
    OWN_SET="${8:-}"
    pr_owned() { [ -n "${OWN_SET:-}" ] && pr_in_set " $OWN_SET " "$1" && return 0; return 1; }
    . "$TMP/cascade-block.sh"
    printf '%s %s %s %s\n' "$CASCADE_ISSUE_SLOTS" "$CASCADE_PR_WAITING" "$CASCADE_WAIT" "${CASCADE_LEVEL:--}" ) 2>/dev/null
}
ck "a MERGEABLE PR waiting takes the room: 11 slots -> 0 (an issue must NOT be dispatched)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' -)" "0 1 1 2"
ck "a PR needing a FIX holds the room too (level 3)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' -)" "0 1 1 3"
ck "a REVIEW-only PR holds the room too (level 4)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	NOCHECKS
' -)" "0 1 1 4"
ck "levels 1-4 empty -> the issue batch gets the leftover room (10 slots, pr_waiting=0)" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' 9001)" "10 0 0 5"
ck "a BUSY PR (owned) is not a level — it does not hold the room" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' 9001)" "10 0 0 5"
ck "…while the SAME work UN-owned holds it (the pair is the discriminator)" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' -)" "0 1 1 3"

# ── 12. LEVEL 1 IS FED BY MAIN'S OWN CHECK-RUNS ─────────────────────────────────────────────────
# ⛔ AN UNFED LEVEL IS DECORATION. These arms drive `cascade_main_probe` against a stub `gh` and pin
# the polarity the brief states: a check that RAN on main and concluded non-green is a red; a check
# that does not run on main at all (most of this repo's are `pull_request`-only) leaves no run and is
# therefore NOT a red — the false re-report of `verify` after #3503 merged.
echo
echo "=== 12. level 1: measured from MAIN's runs, and absence is not a red ==="
mkdir -p "$TMP/mpbin"
printf '#!/bin/bash\nprintf "%%s" "$GH_JSON"\n' > "$TMP/mpbin/gh"; chmod +x "$TMP/mpbin/gh"
probe_main() { # <check-runs json> -> the recorded verdict line ('' when none was written)
  local w="$TMP/mp$$"
  rm -rf "$w"; mkdir -p "$w/state"
  ( O="$w"; LOG=/dev/null; PATH="$TMP/mpbin:$PATH"; GH_JSON="$1"; export GH_JSON
    . "$FNS"
    cascade_main_probe acme/widget >/dev/null 2>&1
    head -1 "$w/state/main-verdict" 2>/dev/null ) 2>/dev/null
}
_j() { printf '{"check_runs":[%s]}' "$1"; }
ck "an all-green main is GREEN" \
   "$(probe_main "$(_j '{"name":"verify","status":"completed","conclusion":"success"}')")" "GREEN"
ck "a run that FAILED on main is RED, and it is NAMED" \
   "$(probe_main "$(_j '{"name":"verify","status":"completed","conclusion":"failure"}')")" "RED:verify"
ck "cancelled is NOT red (the rail's own polarity)" \
   "$(probe_main "$(_j '{"name":"docs","status":"completed","conclusion":"cancelled"}')")" "GREEN"
ck "a check still RUNNING is not red" \
   "$(probe_main "$(_j '{"name":"test","status":"in_progress","conclusion":null}')")" "GREEN"
ck "an EMPTY surface (every check is pull_request-only) is NOT red" "$(probe_main '{"check_runs":[]}')" "GREEN"
ck "an unreadable listing records UNMEASURED, not a verdict" \
   "$(probe_main 'not json at all' | cut -d' ' -f1)" "UNMEASURED"
ck "…and an UNMEASURED / ABSENT record is read as NOT red by the level" \
   "$( ( . "$FNS"; cascade_main_red "/nonexistent/state" ) 2>/dev/null )" "0"

# ── 13. LEVEL 4 IS A LOOP, NOT A SINGLE PASS ────────────────────────────────────────────────────
# ⛔ "review once and drop it" is the defect. The shipped loop's terminator is the (PR, HEAD) key: a
# CLEAN review recorded at this head refuses a second reviewer, and a FIX moves the head — so the next
# pass reviews again. review -> findings -> fix -> REVIEW AGAIN -> green, or a bounded park.
echo
echo "=== 13. level 4 loops: a fix moves the head, and the next pass reviews again ==="
for _f in review_store_candidates review_disp_read review_disp_decide; do
  _b="$(ex "$_f" "$ORCH")"
  if [ -z "$_b" ]; then bad "could not extract $_f() — the L4 loop's terminator moved"; fi
  printf '%s\n' "$_b" >> "$FNS"
done
# A record at a head is a CLEAN verdict for it — the shape merge-one.sh's CLEAN path writes.
mk_review() { # <home> <pr> <head-sha> — the store path is $HOME/.pi/agent/reviews/<owner>-<repo>-<pr>.json
  local f="$1/.pi/agent/reviews/acme-widget-$2.json"
  mkdir -p "$(dirname "$f")"
  printf '{"head_sha":"%s","verdict":"clean"}\n' "$3" > "$f"
}
rdd() { # <home> <pr> <head> [<spent-n-at-head>] -> the shipped verdict word
  local h="$1" n="${4:-0}"
  ( HOME="$h"; O="$TMP/rdstate$$"; mkdir -p "$O/state"; OR="acme/widget"; MAX_REVIEW_TRIES="${MAXRD:-3}"
    . "$FNS"; . "$STUB"
    [ "$n" -gt 0 ] && printf '%s %s\n' "$3" "$n" > "$O/state/reviewdisp-$2"
    review_disp_decide "$2" "$3" ) 2>/dev/null
}
H1="$TMP/rdhome1"; rm -rf "$H1"; mkdir -p "$H1"
ck "no review at this head -> a reviewer is dispatched (the loop ENTERS)" \
   "$(rdd "$H1" 9001 shaH1 | cut -d' ' -f1)" "ALLOW"
mk_review "$H1" 9001 shaH1
ck "a CLEAN review AT THIS HEAD -> no second reviewer (the loop does not spin)" \
   "$(rdd "$H1" 9001 shaH1 | cut -d' ' -f1)" "AT-HEAD"
ck "THE LOOP: the fix moves the head -> the next pass reviews AGAIN" \
   "$(rdd "$H1" 9001 shaH2 | cut -d' ' -f1)" "ALLOW"
ck "…spending the per-head budget (2 of 3) still allows the re-review" \
   "$(rdd "$H1" 9001 shaH2 2 | cut -d' ' -f1)" "ALLOW"
ck "the loop is BOUNDED: at MAX_REVIEW_TRIES it parks instead of reviewing for ever" \
   "$(rdd "$H1" 9001 shaH3 3 | cut -d' ' -f1)" "CAP"

# ── MUTANTS: every assertion above must be able to FAIL ────────────────────────────────────────
echo
echo "=== M. MUTANTS — each shipped assertion is re-run against a mutated copy of the SAME file ==="
# mut <label> <sed-expr> <probe-file>
#   Runs the probe twice: against the SHIPPED functions (must print `yes`) and against the mutated
#   copy (must NOT). A probe that prints yes for both is an assertion that cannot go RED, and it is
#   reported as a failure here rather than trusted above.
mut() {
  local label="$1" expr="$2" probe="$3" m="$TMP/mut.sh" mutfns="$TMP/mutfns.sh" got mutgot
  sed "$expr" "$ORCH" > "$m"
  if cmp -s "$m" "$ORCH"; then bad "$label — the mutation changed NOTHING (a vacuous mutant)"; return; fi
  : > "$mutfns"
  for _f in is_num is_limit pr_in_set _wedge_min measure_ownership_sets measure_ci_inflight pr_owned \
            unowned_scan mp_reason cascade_issue_slots cascade_wait \
            cascade_level_name cascade_main_red cascade_level cascade_main_probe; do
    ex "$_f" "$m" >> "$mutfns"
  done
  ex unowned_pr_count "$m" >> "$mutfns"
  ex lo_num "$LO" >> "$mutfns"; ex lo_select "$LO" >> "$mutfns"
  got="$(    ORCH_FNS="$FNS"    TGT="$ORCH" MUT="$m" FIX="$TMP" STUB="$STUB" bash "$probe" 2>/dev/null )"
  mutgot="$( ORCH_FNS="$mutfns" TGT="$m"    MUT="$m" FIX="$TMP" STUB="$STUB" bash "$probe" 2>/dev/null )"
  if [ "$got" = "yes" ] && [ "$mutgot" != "yes" ]; then
    ok "$label  (shipped=yes, mutant=no)"
  else
    bad "$label — shipped=[${got:-<empty>}] mutant=[${mutgot:-<empty>}]: the assertion does NOT discriminate"
  fi
}

# mutlo <label> <sed-expr> <probe-file>
# ⛔ THE FUNNEL LIVES IN THE MODULE, NOT THE LOOP (live-ownership.sh). Mutating the CONTROLLER for a
# module assertion changed nothing and was reported as a vacuous mutant — which is the right verdict,
# and it is what stopped this suite from claiming a funnel pin it did not have.
mutlo() {
  local label="$1" expr="$2" probe="$3" m="$TMP/mutLO.sh" mutfns="$TMP/mutfnsLO.sh" got mutgot
  sed "$expr" "$LO" > "$m"
  if cmp -s "$m" "$LO"; then bad "$label — the mutation changed NOTHING (a vacuous mutant)"; return; fi
  : > "$mutfns"
  ex lo_num "$m" >> "$mutfns"; ex lo_select "$m" >> "$mutfns"
  got="$(    ORCH_FNS="$FNS"    TGT="$LO" MUT="$m" FIX="$TMP" STUB="$STUB" bash "$probe" 2>/dev/null )"
  mutgot="$( ORCH_FNS="$mutfns" TGT="$m"  MUT="$m" FIX="$TMP" STUB="$STUB" bash "$probe" 2>/dev/null )"
  if [ "$got" = "yes" ] && [ "$mutgot" != "yes" ]; then
    ok "$label  (shipped=yes, mutant=no)"
  else
    bad "$label — shipped=[${got:-<empty>}] mutant=[${mutgot:-<empty>}]: the assertion does NOT discriminate"
  fi
}

cat > "$TMP/p-alloc.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"; r="$(cascade_issue_slots 4 2 10 1)"; [ "$r" = "1" ] && echo yes || echo no
PEOF
mut "M1 the allocator ignores the lanes PR work already holds (the barrier back in disguise)" \
    's/room=$(( maxl - lanes ))/room=$(( maxl ))/' "$TMP/p-alloc.sh"

cat > "$TMP/p-own.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"
W="$FIX/m-own"; rm -rf "$W"; mkdir -p "$W/state" "$W/logs"; O="$W"; CYCLE_T0=1; STALE_MIN=40
wt_table() { printf 'review-9001\talive\nfix-9002\talive\nmerge-9003\talive\n'; }
: > "$W/logs/review-9001.log"; : > "$W/logs/fix-9002.log"; : > "$W/logs/merge-9003.log"
printf '9001:shaA:a 9002:shaB:b 9003:shaC:c\n' > "$W/state/last-open-prs"
measure_ownership_sets
[ "$(unowned_pr_count 3)" = "0" ] && echo yes || echo no
PEOF
mut "M2 a live review/fix/merge lane stops counting as ownership (the measured 13-of-15)" \
    's/^  pr_in_set "\${WORKING_PR_SET:- }" "\$pr" && return 0$/  : # arm removed/' "$TMP/p-own.sh"

cat > "$TMP/p-ci.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"
W="$FIX/m-ci"; rm -rf "$W"; mkdir -p "$W/state"; O="$W"
printf '9101:shaA:b1 9102:shaB:b2\n' > "$W/state/last-open-prs"
printf '9101\tshaA\tPENDING\n9102\toldsha\tPENDING\n' > "$W/state/prclass.tsv"
measure_ci_inflight
n=0
pr_in_set "$CI_INFLIGHT_SET" 9101 && n=$((n+1))
pr_in_set "$CI_INFLIGHT_SET" 9102 && n=$((n+10))
[ "$n" = "1" ] && echo yes || echo no
PEOF
mut "M3 a PENDING row owns the PR even when the head it was seen on has been SUPERSEDED" \
    's/cls\[p\] == "PENDING" && hd\[p\] != "" && heads\[p\] == hd\[p\]/cls[p] == "PENDING"/' "$TMP/p-ci.sh"

cat > "$TMP/p-gate.sh" <<'PEOF'
# THE BARRIER IS BACK if the shipped file wires mp_reason into GATE_WHY again.
grep -qE '^[[:space:]]*GATE_WHY="\$\(mp_reason' "$TGT" && echo no || echo yes
PEOF
mut "M4 merge-priority is wired back into GATE_WHY (the barrier restored)" \
    's/^  MP_PRIORITY="\$(mp_reason /  GATE_WHY="$(mp_reason /' "$TMP/p-gate.sh"

cat > "$TMP/p-sel.sh" <<'PEOF'
. "$ORCH_FNS"; lo_select 15 0 5 0 3 "" 10 1 2 ok 1 0 >/dev/null 2>&1; [ "$LO_CHOICE" = "issue" ] && echo yes || echo no
PEOF
mutlo "M5 the funnel ignores arg 12 and re-closes the issue path" \
    's/^  pr_waiting="\${prw:-1}"$/  pr_waiting=1/' "$TMP/p-sel.sh"

cat > "$TMP/p-cap.sh" <<'PEOF'
grep -qF '[ "$K" -ge "${CASCADE_ISSUE_SLOTS:-${BATCH:-2}}" ] && break' "$TGT" && echo yes || echo no
PEOF
mut "M6 the batch stops at BATCH again (a pass that sleeps through idle capacity)" \
    's/\[ "\$K" -ge "\${CASCADE_ISSUE_SLOTS:-\${BATCH:-2}}" \] && break/[ "$K" -ge "$BATCH" ] \&\& break/' \
    "$TMP/p-cap.sh"

cat > "$TMP/p-dedup.sh" <<'PEOF'
. "$ORCH_FNS"; pr_in_set " 77 " 77 && echo yes || echo no
PEOF
mut "M7 the in-flight dedup predicate is neutered" \
    's/^  case "\${1:- }" in \*" \${2} "\*) return 0 ;; esac$/  : # set membership removed/' "$TMP/p-dedup.sh"

cat > "$TMP/p-wedge.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"
W="$FIX/m-wedge"; rm -rf "$W"; mkdir -p "$W/state" "$W/logs"; O="$W"; CYCLE_T0=1; STALE_MIN=40
wt_table() { printf 'review-9201\talive\n'; }
: > "$W/logs/review-9201.log"; touch -t 202001010000 "$W/logs/review-9201.log"
printf '9201:sA:b1\n' > "$W/state/last-open-prs"
measure_ownership_sets
# yes == the wedged record does NOT own its PR
pr_in_set "$WORKING_PR_SET" 9201 && echo no || echo yes
PEOF
mut "M8 a wedged record owns its PR again (a corpse holding the gate and a slot)" \
    's/^        pr_in_set "\$wed" "\$n.log" && { WEDGED_SET="\$WEDGED_SET\$n "; continue; }$/        : # wedge filter removed/' \
    "$TMP/p-wedge.sh"

cat > "$TMP/p-wait.sh" <<'PEOF'
grep -qF 'elif [ "${CASCADE_WAIT:-0}" = "1" ]; then' "$TGT" && echo yes || echo no
PEOF
mut "M9 the interval ignores CASCADE_WAIT (sleeps through a slot that just freed)" \
    's/^  elif \[ "\${CASCADE_WAIT:-0}" = "1" \]; then$/  elif false; then/' "$TMP/p-wait.sh"

cat > "$TMP/p-dedupwire.sh" <<'PEOF'
grep -qF 'pr_in_set "${INFLIGHT_ISSUE_SET:- }" "$ISS"' "$TGT" && echo yes || echo no
PEOF
mut "M10 the dedup arm is removed from the batch (an in-flight issue is queued twice)" \
    's/^      if pr_in_set "\${INFLIGHT_ISSUE_SET:- }" "\$ISS"; then$/      if false; then/' "$TMP/p-dedupwire.sh"

# ⛔ M11-M14 GRADE THE PYRAMID ITSELF. Without them the level arms above would be prose: each
# mutation removes one link of the fill order, and the SAME assertion is re-run to prove it reddens.
cat > "$TMP/p-l2.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"
W="$FIX/m-l2"; rm -rf "$W"; mkdir -p "$W/state"; O="$W"
printf '9001:shaA:fix/a\n' > "$W/state/last-open-prs"
printf '9001\tshaA\tGREEN\n' > "$W/state/prclass.tsv"
pr_owned() { return 1; }
cascade_level "$W/state"
[ "$CASCADE_LEVEL" = 2 ] && echo yes || echo no
PEOF
mut "M11 a mergeable PR no longer wins level 2 (the merge level skipped)" \
    's/^  if   \[ "\$n_m" -gt 0 \]; then CASCADE_LEVEL=2$/  if false; then CASCADE_LEVEL=2/' "$TMP/p-l2.sh"

cat > "$TMP/p-hold.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"
W="$FIX/m-hold"; rm -rf "$W"; mkdir -p "$W/state"; : > "$W/candidates.txt"
printf '9001:shaA:fix/a\n' > "$W/state/last-open-prs"
printf '9001\tshaA\tGREEN\n' > "$W/state/prclass.tsv"
O="$W"; LOG=/dev/null; UPN_WORK=5; UPN=5; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
LANES=2; LANES_DISPLAY=2; MAX_LANES=25; SEL_PARKED=0; TEST_CAN_SPAWN=1
for i in 0 1 2 3 4 5 6 7 8 9; do printf '100%s\n' "$i" >> "$W/candidates.txt"; done
pr_owned() { return 1; }
awk '/^  # \[cascade:begin\]/{f=1} f{print} /^  # \[cascade:end\]/{if(f) exit}' "$TGT" > "$FIX/hold-blk.sh"
. "$FIX/hold-blk.sh"
[ "$CASCADE_ISSUE_SLOTS" = 0 ] && echo yes || echo no
PEOF
mut "M12 a higher level no longer HOLDS the room (an issue is dispatched while a merge waits)" \
    's/^               CASCADE_ISSUE_SLOTS=0; CASCADE_LEVEL_HOLDS=1 ;;$/               CASCADE_LEVEL_HOLDS=1 ;;/' "$TMP/p-hold.sh"

cat > "$TMP/p-unmeas.sh" <<'PEOF'
. "$ORCH_FNS"
[ "$(cascade_main_red /nonexistent/state)" = "0" ] && echo yes || echo no
PEOF
mut "M13 an UNMEASURED main reads as RED (levels 2-5 stall behind a measurement nobody took)" \
    's/^  case "\${t:-}" in RED|RED:\*) printf .1\\n. ;; \*) printf .0\\n. ;; esac$/  case "${t:-}" in RED|RED:*) printf '\''1\\n'\'' ;; *) printf '\''1\\n'\'' ;; esac/' "$TMP/p-unmeas.sh"

cat > "$TMP/p-cancel.sh" <<'PEOF'
. "$ORCH_FNS"
W="$FIX/m-cancel"; rm -rf "$W"; mkdir -p "$W/state"; O="$W"
mkdir -p "$FIX/mpbin"
printf '#!/bin/bash\nprintf "%%s" "$GH_JSON"\n' > "$FIX/mpbin/gh"; chmod +x "$FIX/mpbin/gh"
PATH="$FIX/mpbin:$PATH" GH_JSON='{"check_runs":[{"name":"docs","status":"completed","conclusion":"cancelled"}]}' \
  cascade_main_probe acme/widget >/dev/null 2>&1
[ "$(head -1 "$W/state/main-verdict" 2>/dev/null)" = "GREEN" ] && echo yes || echo no
PEOF
mut "M14 a CANCELLED run on main counts as red (the polarities the rail allows are re-narrowed)" \
    's/("success","neutral","skipped","cancelled","stale")/("success","neutral","skipped","stale")/' "$TMP/p-cancel.sh"

cat > "$TMP/p-pol.sh" <<'PEOF'
# ⛔ THE FAIL-CLOSED ARM, DRIVEN THROUGH THE SHIPPED BLOCK with the one input it exists for. 10
# candidates and 23 free lanes, so nothing but the guard itself can withhold the room.
d="$FIX/m-pol"; rm -rf "$d"; mkdir -p "$d/state"
( O="$d"; LOG=/dev/null; UPN_WORK="abc"; UPN="abc"; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
  LANES=2; LANES_DISPLAY=2; MAX_LANES=25; SEL_PARKED=0; TEST_CAN_SPAWN=1
  for i in 0 1 2 3 4 5 6 7 8 9; do printf '100%s\n' "$i" >> "$d/candidates.txt"; done
  . "$ORCH_FNS"; . "$STUB"
  awk '/^  # \[cascade:begin\]/{f=1} f{print} /^  # \[cascade:end\]/{if(f) exit}' "$TGT" > "$FIX/pol-blk.sh"
  . "$FIX/pol-blk.sh"
  [ "$CASCADE_ISSUE_SLOTS" = 0 ] && [ "$CASCADE_PR_WAITING" = 1 ] && echo yes || echo no ) 2>/dev/null
PEOF
mut "M15 an UNREADABLE un-owned count hands the room to issues (the fail-closed arm removed)" \
    's/^    CASCADE_UPN_UNREADABLE=1; CASCADE_ISSUE_SLOTS=0$/    CASCADE_UPN_UNREADABLE=1/' "$TMP/p-pol.sh"

# ── 10. THE OVERRIDE IS RECORDED, NOT SILENT ───────────────────────────────────────────────────
echo
echo "=== 10. the departure from the recorded ruling is NAMED where a reader meets it ==="
ckin "the cascade names what it overrides (a future reader must not read this as accidental)" "$SRC" 'OVERRIDES: the 2026-10-18 owner ruling "while ANY un-owned PR remains'
ckin "the WIP-floor ruling is explicitly NOT reversed" "$SRC" 'is NOT reversed and NOT touched'
ckin "…and it is the LANDING_FLOOR arm that still gates" "$SRC" 'GATE_WHY="${GATE_WHY:-landing-floor('

printf '\n%s\n' "──────────────────────────────────────────────"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ cascade: all assertions passed"
