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
#  14  the escape VALVE: a level holding the room still QUEUES, and cannot record what it cannot spend
#                                                                              → mutant: M19
#  12b what LEVEL 1 does when it holds: no actor keyed on its name or its variable, its hold is
#      unbounded while the PR path produces, and the main-red exemption now RECOGNISES the title the
#      repo's own filer produces (fixed) — the levels remaining COUNT-bounded is an OPEN OWNER DECISION
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
for _f in is_num is_limit pr_in_set _wedge_min measure_ownership_sets measure_ci_inflight \
          worker_log_name pr_owned \
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
: > "$W/logs/merge-9001.log"; : > "$W/logs/fix-9002.log"; : > "$W/logs/merge-9003.log"
printf '9001:shaA:fix/9001-a 9002:shaB:fix/9002-b 9003:shaC:fix/9003-c 9004:shaD:fix/9004-d\n' > "$W/state/last-open-prs"
measure_ownership_sets
ck "the census's live review lane is in WORKING_PR_SET"  "$(case "$WORKING_PR_SET" in *' 9001 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…its live fix lane too"                              "$(case "$WORKING_PR_SET" in *' 9002 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…and its live merge lane"                            "$(case "$WORKING_PR_SET" in *' 9003 '*) echo yes;; *) echo no;; esac)" "yes"
ck "a DEAD record is NOT ownership (the census proves the death)" "$(case "$WORKING_PR_SET" in *' 9004 '*) echo yes;; *) echo no;; esac)" "no"
ck "a live lane-<N> is in INFLIGHT_ISSUE_SET (the pass's dedup input)" "$(case "$INFLIGHT_ISSUE_SET" in *' 77 '*) echo yes;; *) echo no;; esac)" "yes"
ck "…and an \`unknown\` worker counts ALIVE (a probe failure must not free a slot)" "$(case "$INFLIGHT_ISSUE_SET" in *' 78 '*) echo yes;; *) echo no;; esac)" "yes"
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
drive_cascade() { # <unowned> <lanes> <max_lanes> <backlog> <can> [<listing present|absent>] -> "slots pr_waiting wait"
  local d="$TMP/dc$$"; rm -rf "$d"; mkdir -p "$d/state"
  # ⛔ THE LISTING'S PRESENCE IS AN INPUT (review cycle 5). `open_pr_count` `rm -f`s
  # `state/last-open-prs` when the read fails and writes it only on success, so ABSENT is the one datum
  # that says "nobody read this" — and the room guard keys on it. Default `present`, because every other
  # case here is about the arithmetic, not about a failed listing.
  # ⛔ AND THAT DEFAULT IS ALSO WHAT KILLED A FALSE PASS IN THIS RIG (review P1, 2026-11-06): with NO
  # listing written, `cascade_level` hit `[ -n "${list// /}" ] || return 0` and returned `?`, so no level
  # could hold and the headline assertion "the cascade opens" graded an UNMEASURED level — while
  # `drive_block`, which does supply a listing, asserted the OPPOSITE for the same inputs. Two
  # contradictory assertions were green in one run.
  case "${6:-}" in
    absent) : ;;
    present) printf '9001:shaA:fix/a 9002:shaB:fix/b\n' > "$d/state/last-open-prs" ;;
    # ⛔ A ZERO UN-OWNED COUNT MUST NOT SHIP A LISTING OF TWO UN-OWNED PRs (integration fix,
    # 2026-11-06). The default used to be `present` unconditionally, so `drive_cascade 0 …` told the
    # level walk "UPN_WORK=0" and then handed it TWO un-owned PRs — the fixture contradicted itself,
    # the level measured 4, and the assertion labelled "NO un-owned PRs + free room" could not be
    # reached by its own rig. Absent here means "nobody read it" and is asserted explicitly via
    # `absent`; with zero un-owned PRs a real listing IS empty, which is a different state from
    # absent, so write an EMPTY file — that is what `open_pr_count` writes on a successful read of
    # an empty queue.
    *) if is_num "${1:-}" && [ "${1:-0}" -gt 0 ] 2>/dev/null; then
         printf '9001:shaA:fix/a 9002:shaB:fix/b\n' > "$d/state/last-open-prs"
       else
         : > "$d/state/last-open-prs"
       fi ;;
  esac
  ( O="$d"; LOG=/dev/null; UPN_WORK="$1"; UPN="$1"; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
    LANES="$2"; LANES_DISPLAY="$2"; MAX_LANES="$3"; SEL_PARKED=0
    TEST_CAN_SPAWN="$5"
    : > "$d/candidates.txt"
    _i=0; while [ "$_i" -lt "$4" ]; do printf '100%s\n' "$_i" >> "$d/candidates.txt"; _i=$((_i+1)); done
    . "$FNS"; . "$STUB"
    # ⛔ THE LISTED PRs ARE UN-OWNED, WHICH IS WHAT `UPN_WORK` SAYS THEY ARE. `drive_block` stubs
    # `pr_owned` for exactly this reason and this rig did not, so once the listing was supplied the
    # SHIPPED `pr_owned` ran against a fabricated `9001:shaA:fix/a` and answered whatever a box with no
    # such claim answers — which made the level unmeasurable for a SECOND reason and would have let a
    # "the cascade opens" reading survive on the wrong evidence. Stubbed to `return 1` (not owned), so
    # the fixture's only un-owned count is `UPN_WORK`.
    pr_owned() { return 1; }
    # shellcheck source=/dev/null
    . "$TMP/cascade-block.sh"
    printf '%s %s %s\n' "$CASCADE_ISSUE_SLOTS" "$CASCADE_PR_WAITING" "$CASCADE_WAIT" ) 2>/dev/null
}
# ⛔ THE HEADLINE ASSERTION WAS WRONG AND IS CORRECTED HERE RATHER THAN DEFENDED. With the listing
# present (i.e. measured, as production is) a single un-owned PR resolves to a level and the level
# HOLDS the room: `issue_slots=0`. The old `10 0 0` was the UNMEASURED path's answer, so it graded the
# absent file, not the cascade. This is the honest behaviour: **level 5 is reached only when there is
# NO un-owned PR at all** — see the pole assertion in §11 below, which pins that consequence so it
# cannot be forgotten.
ck "un-owned PR work + FREE room -> a LEVEL holds the room (issue_slots=0, pr_waiting=1)" \
   "$(drive_cascade 5 2 25 10 1)" "0 1 0"
ck "un-owned PR work + NO room    -> PR priority holds (slots=0, pr_waiting=1, waits)" "$(drive_cascade 5 25 25 10 1)" "0 1 1"
ck "NO un-owned PRs + free room  -> the leftover room reaches the issue batch" "$(drive_cascade 0 0 25 10 1)" "10 0 0"
# ⛔ DECLARED LIMIT, and it is the SAME class as the pole: an EMPTY listing makes `cascade_level`
# answer `?`, not `5` — its own rule is "no rows is not no work" (a listing that could not be read
# cannot say a mergeable PR is absent). So the assertion above grades the OUTCOME (the room reaches the
# issue batch), NOT the level number; the level-5 arm itself is driven by `drive_block` in §11, where
# an OWNED PR gives a non-empty listing and resolves to 5. Both readings are pinned so neither is
# inferred, and an empty-but-read listing being indistinguishable from an unread one stays disclosed
# rather than silently corrected here (the FAIL-CLOSED guard above keys on the file's ABSENCE, which is
# the one datum that separates them).
ck "no un-owned PRs + empty backlog -> nothing to wait for" "$(drive_cascade 0 0 25 0 1)" "0 0 0"
# ⛔ POLARITY ON THE ROOM ITSELF. `merge-priority` used to carry a fail-closed arm (any unreadable
# count closed the issue path). Removing the barrier must not remove the polarity, or the one listing
# failure that should drain hardest becomes the one that DISPATCHES new work. These three are a set:
# the first two must withhold, the third proves the branch is not simply always closed.
ck "an UNREADABLE un-owned count gives the issue path NO room (fails closed)" \
   "$(drive_cascade abc 2 25 10 1)" "0 1 0"
ck "…and an OUT-OF-RANGE all-digit count does too (is_num passes it, \`[\` would error OPEN)" \
   "$(drive_cascade 99999999999999999999 2 25 10 1)" "0 1 0"
ck "…while the SAME room with a readable count still opens (contrast half)" \
   "$(drive_cascade 0 2 25 10 1)" "10 0 0"
# ⛔ THE PRODUCTION FAILURE PATH (review cycle 5, P1). When `gh` fails, `open_pr_count` ASSUMES A NUMBER
# and `rm -f`s the row file — so the count is always numeric and a guard keyed on the count can never
# fire. The ABSENT row file is the signal, and this is the assertion that would have caught it.
ck "an ABSENT listing (a failed gh read that still yielded a number) grants NO room" \
   "$(drive_cascade 26 2 25 10 1 absent)" "0 1 0"
# ⛔ THE CONTRAST HALF, CORRECTED (review P1, 2026-11-06 — "26 with the listing PRESENT still opens"
# was grading the OWNERSHIP fallback, not the cascade). With the listing present the level IS measured,
# and the two listed PRs resolve to level 4 (`REVIEW_PR`) because `state/prclass.tsv` is empty in this
# fixture — so the level HOLDS the room and `issue_slots=0`. It holds for the same reason level 5 needs
# ZERO un-owned PRs: levels 2-4 partition every un-owned PR. Claiming it "still opens" without a
# `pr_owned` stub was the same unmeasured-level false PASS, one layer down.
ck "…and the contrast: the listing PRESENT means the level is MEASURED, and it HOLDS the room" \
   "$(drive_cascade 26 2 25 10 1 present)" "0 1 0"

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
# ⛔ A DIGIT STRING IS NOT A COUNT (review 2026-11-04, P1). `lo_num` accepts any run of digits, and
# `[ 99999999999999999999 -gt 0 ]` ERRORS — an errored test in an `elif` chain is FALSE, so control
# fell past EVERY arm into the final `else` and printed `DISPATCH` + `CHOICE=issue`, which the batch
# loop then refused. Measured on the shipped function before the fix: `no un-owned PR left ; issues:
# DISPATCH (10 in backlog)`. The cascade's own polarity test (section 4) never reached this because
# it stops at the block, not at the funnel.
ck "an OUT-OF-RANGE un-owned count DRAINS in the funnel (no false DISPATCH)" \
   "$(printf '%s' "$(sel 99999999999999999999 0 '')" | cut -f1)" "pr"
ckni "…and the line does not claim a dispatch it cannot make" \
   "$(printf '%s' "$(sel 99999999999999999999 0 '')" | cut -f2)" "DISPATCH"
ck "an UNREADABLE un-owned count still drains (never opens on a number nobody read)" \
   "$(printf '%s' "$( { . "$FNS"; lo_select 15 0 abc 0 3 '' 10 '' 0 unknown '' '' >/dev/null 2>&1; printf '%s' "$LO_CHOICE"; } )" | tail -1)" "pr"

# ── 6. THE BATCH CAP IS CAPACITY, NOT ONE BATCH ────────────────────────────────────────────────
echo
echo "=== 6. one pass fills capacity (owner: \"do not stop at one batch\") ==="
ckin "the batch breaks on CASCADE_ISSUE_SLOTS" "$SRC" '[ "$K" -ge "${CASCADE_ISSUE_SLOTS:-${BATCH:-2}}" ] && break'
ckni "…and NOT on BATCH alone" "$SRC" '[ "$K" -ge "$BATCH" ] && break'
# ⛔ THE GUARD'S SPELLING IS PART OF THE INVARIANT (review cycle 2, P0): `:-0` reads an UNSET count
# as "no room" and breaks the batch for every standalone-driving suite, so the pin follows the
# terse-minus form and section 14 pins the absence of the other one.
ckin "the loop refuses to queue anything when the cascade granted 0" "$SRC" '[ "${CASCADE_ISSUE_SLOTS-1}" -ge 1 ] 2>/dev/null || break'

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
# ⛔ THE FIXTURE MUST USE THE NAME THE WRITER PRODUCES (review P1, 2026-11-06 — measured). These were
# `logs/review-<PR>.log`, a filename NO WRITER CREATES: a reviewer is spawned as `review-<PR>` but
# `merge-one.sh` sets `L="$O/logs/merge-$PR"` itself, and `lane-reap.sh`'s `is_lane_log_name` REJECTS
# `review-*`. So the arm could never fire in production while these assertions stayed green over the
# invented name — the vacuous-green shape. The fixture now supplies `merge-<PR>.log`, which is what
# `worker_log_name` resolves `review-<PR>` to; reverting either side reddens these assertions.
: > "$W8/logs/merge-9201.log"
touch -t 202001010000 "$W8/logs/merge-9201.log"      # long past the wedge bound
: > "$W8/logs/merge-9202.log"                        # fresh: working
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
ckin "…and the poll re-cycles the moment a slot FREES" "$SRC" '[cascade] a slot FREED after'
# Driven: with room appearing on the second sample, the wait returns 0 (re-cycle NOW) quickly.
_w="$TMP/w9"; mkdir -p "$_w"
( O="$_w"; LOG="$_w/log"; CYC=240; CASCADE_POLL=1; MAX_LANES=4; TEST_LANES=4
  . "$FNS"; . "$STUB"
  _n=0
  measure_lanes() { _n=$((_n+1)); LANES=$([ "$_n" -ge 2 ] && echo 2 || echo 4); LANES_DISPLAY="$LANES"; LANES_TOTAL="$LANES"; LANES_UNKNOWN=0; }
  measure_lanes
  cascade_wait 30 4; printf 'rc=%s\n' "$?" ) > "$TMP/w9.out" 2>/dev/null
ck "cascade_wait returns 0 (re-cycle NOW) as soon as a slot FREES" "$(cat "$TMP/w9.out")" "rc=0"
ckin "…and it says so, with the measurement" "$(cat "$_w/log" 2>/dev/null || true)" "RE-CYCLING NOW"
# ⛔ AND IT MUST NOT FIRE WHEN NOTHING FREED (review 2026-11-04, P1). The first version re-asked the
# ALLOCATOR instead of the census, so on any pass where a pine level HELD the room it logged
# `a slot freed after 20s` with nothing changed and re-swept every ~20s instead of ~240s — a false
# log claim AND the pacing change the owner's ask forbids. These two are the pair: a constant census
# must time out silently, and an unreadable census must not count as "freed".
_w2="$TMP/w9b"; rm -rf "$_w2"; mkdir -p "$_w2"
( O="$_w2"; LOG="$_w2/log"; CYC=240; CASCADE_POLL=1; MAX_LANES=4; TEST_LANES=4
  . "$FNS"; . "$STUB"
  measure_lanes() { LANES=4; LANES_DISPLAY=4; LANES_TOTAL=4; LANES_UNKNOWN=0; }
  cascade_wait 3 4; printf 'rc=%s\n' "$?" ) > "$TMP/w9b.out" 2>/dev/null
ck "a census that never moves returns 1 (the interval runs; nothing is claimed)" "$(cat "$TMP/w9b.out")" "rc=1"
_freedn=0; [ -f "$_w2/log" ] && _freedn="$(grep -c 'slot FREED' "$_w2/log" 2>/dev/null)"
ck "…and NOTHING was logged as freed (the false 'slot freed' line is gone)" \
   "${_freedn:-0}" "0"
_w3="$TMP/w9c"; rm -rf "$_w3"; mkdir -p "$_w3"
( O="$_w3"; LOG="$_w3/log"; CYC=240; CASCADE_POLL=1; MAX_LANES=4; TEST_LANES=4
  . "$FNS"; . "$STUB"
  measure_lanes() { LANES=""; LANES_DISPLAY="?"; LANES_TOTAL="?"; LANES_UNKNOWN=1; }
  cascade_wait 2 4; printf 'rc=%s\n' "$?" ) > "$TMP/w9c.out" 2>/dev/null
ck "an UNREADABLE census never reads as a freed slot" "$(cat "$TMP/w9c.out")" "rc=1"
# ⛔ A PASS WHOSE ROOM A LEVEL HOLDS IS NOT A FULL BOX, so it must NOT arm the poll.
ckin "the poll is armed by the ROOM, not by 'this pass granted none'" "$SRC" 'if [ "${CASCADE_ROOM:-0}" -le 0 ] && [ "${CASCADE_UPN_UNREADABLE:-0}" = "0" ] && [ "${CASCADE_WAITING:-0}" = "1" ]; then'
# ⛔ THE ABSENCE FORM WAS AMBIGUOUS BY CONSTRUCTION and cycle 2 retired it: ``CASCADE_LEVEL_HOLDS:-0}" =
# "1" ]; then`` now legitimately appears in the reason-selection chain (it names the cause), so an
# absence pin on that spelling would red a CORRECT tree. The discriminate is the positive pin above
# (the wait arm keys on ROOM + WAITING) plus the driven pair in section 11 (level-holds with room ⇒
# wait=0; a genuinely full box ⇒ wait=1).
# ⛔ (the "full box still polls" contrast that used to sit here was a DUPLICATE of the pin above —
# same needle, so nothing satisfying one could red the other. Cycle 2 removed it: the contrast is the
# `CASCADE_ROOM <= 0` term itself, which the pin above names in full.)


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
# ⛔ LAST ROW WINS, LIKE THE CLASS FILE SAYS (review 2026-11-04, P2). The set deduped, so when one
# head carried BOTH a GREEN and a RED observation the GREEN survived and level 2 (MERGE) beat level 3
# (FIX_PR) — a healthy answer preferred over a failing one. The class file is append-only and
# `lo_class_compact` keeps the LAST row, so the reducer must too. Both orders are asserted: the rule
# is "last", not "red wins" (a RED superseded by a GREEN must read GREEN, which the L2 case covers).
ck "…and a RED recorded AFTER a GREEN for the SAME head wins (last-row-wins, not first)" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	GREEN
9001	shaA	RED
' - -)" "3 FIX_PR"
ck "…while a GREEN recorded AFTER a RED wins too (the rule is ORDER, not severity)" \
   "$(drive_level '9001:shaA:fix/a' '9001	shaA	RED
9001	shaA	GREEN
' - -)" "2 MERGE"
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
drive_block() { # <unowned> <lanes> <max> <backlog> <can> <listing> <prclass> <owned-prs> [<main-verdict>] [<UPN_WORK>] -> "slots prw wait level"
  # ⛔ `<UPN_WORK>` EXISTS SEPARATELY FROM `<unowned>` BECAUSE THE TWO ARE DIFFERENT POPULATIONS (review
  # P1, 2026-11-06). `<unowned>` is what the LISTING shows; `UPN_WORK` is the pass's own un-owned count
  # with `SEL_PARKED` already subtracted. A parked-at-this-head PR makes them disagree — listing has it,
  # count says 0 — and that disagreement is the defect this rig now drives. Default: they agree.
  local w="$TMP/blk$$"
  rm -rf "$w"; mkdir -p "$w/state"
  printf '%s\n' "$6" > "$w/state/last-open-prs"
  : > "$w/state/prclass.tsv"
  [ -n "${7:-}" ] && [ "${7}" != "-" ] && printf '%s' "$7" > "$w/state/prclass.tsv"
  # <main-verdict> models MAIN's own recorded verdict, which `cascade_level` reads to reach level 1.
  [ -n "${9:-}" ] && printf '%s\n' "$9" > "$w/state/main-verdict"
  ( O="$w"; LOG=/dev/null; UPN_WORK="${10:-$1}"; UPN="$1"; SEL_TOTAL=15; OPEN_N=15; WORKERS=0
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
' -)" "0 1 0 2"
ck "a PR needing a FIX holds the room too (level 3)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' -)" "0 1 0 3"
ck "a REVIEW-only PR holds the room too (level 4)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	NOCHECKS
' -)" "0 1 0 4"
# ⛔ THE POLE, AND ITS DECLARED LIMIT (review P1, 2026-11-06). Every un-owned PR is classified into
# level 2 (GREEN), 3 (RED) or 4 (anything else), so `n_m + n_f + n_r == n_u` and the issue batch gets
# room only when NO un-owned PR exists. That is the recorded ORDER doing its job — and it is also why
# this change must not claim to have removed the 2026-10-18 barrier outright: what it removed is the
# barrier's ABSOLUTE form (a bare `mp_reason` string closing `GATE_WHY`); a level with work still
# withholds the room, by design.
# ⛔ THE DECLARED LIMIT, DRIVEN RATHER THAN HIDDEN: a GREEN PR lands on level 2 (`MERGE`) whether or
# not it is REVIEW-SATISFIED, because `state/prclass.tsv` carries check state only — it does not carry
# review state or mergeability. So "mergeable + review-satisfied" (the level's documented meaning) is
# narrower than what this classifier can measure, and a GREEN-but-unreviewed PR is counted as merge
# work. Pinned HERE so the gap is stated in one place instead of being inferred from the code; making
# the levels genuinely actionability-bounded is an OWNER DECISION (§6 of the contract doc), not a
# thing to be smuggled in under a fixture.
ck "…and a GREEN PR lands on level 2 whether or not it is review-satisfied (the class file carries no review state)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' -)" "0 1 0 2"
ck "…so level 5 is reachable ONLY at zero un-owned PRs (the pole, stated as a consequence)" \
   "$(drive_block 1 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	NOCHECKS
' - | cut -d' ' -f4)" "4"
# ⛔ THE PARKED-POPULATION MISMATCH, DRIVEN (review P1, 2026-11-06). `UPN_WORK` is the pass's own
# UN-OWNED count with `SEL_PARKED` already subtracted, so `UPN_WORK=0` beside a non-empty listing is
# exactly the state a parked-at-this-head PR produces: the count and the funnel both say "no un-owned
# PR work", and the walk must NOT then invent a level out of the parked PR. Before this, that single
# parked PR resolved a level, zeroed `issue_slots`, and broke the batch on its first guard — ZERO
# issues queued every pass while the printed decision said `DISPATCH`, with no release (the drain
# escape only runs on the `LO_CHOICE != pr` arm, and this state reaches it as `issue`, which resets the
# inert streak). The expected level is `-` (never measured): a parked PR is not work for any level.
ck "a PR the count has EXCLUDED (UPN_WORK=0 — parked at this head) must NOT hold the room" \
   "$(drive_block 1 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' - - 0)" "10 0 0 5"
# ⛔ LEVEL 1 DOES NOT DEPEND ON THE UN-OWNED COUNT, AND THE ARM ORDER IS THE ASSERTION (review P2,
# 2026-11-06). The zero-un-owned short-circuit sits AFTER the main-red verdict for exactly this state:
# a RED main with NO un-owned PRs must still resolve level 1 and hold the room. When the two guards
# were the other way round, this state read "no level", the issue path opened, and §6's statement that
# "a red main closes the issue path" was false in the state where it reads worst. Nothing pinned it.
ck "a RED MAIN still holds when there are ZERO un-owned PRs (the short-circuit must not bypass level 1)" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' - 'RED:verify' 0)" "0 1 0 1"
ck "levels 1-4 empty -> the issue batch gets the leftover room (10 slots, pr_waiting=0)" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' 9001 - 1)" "10 0 0 5"
# ⛔ `<UPN_WORK>` IS GIVEN EXPLICITLY HERE (review P1, 2026-11-06). The pass's own un-owned count
# short-circuits the level walk at 0 — that is the parked-PR fix, and it is DRIVEN as its own assertion
# above. A fixture whose POINT is which level an OWNED PR resolves to must therefore keep the count
# non-zero, or it grades the short-circuit instead of the level and reports `-`.
# ⛔ THE CONTRAST THAT KEEPS THE PAIR MEANINGFUL: a level holding the room on a box with NO free lane
# is a FULL box — that is the one state where polling for a freed slot is right. Same inputs as the
# level-2 case above except `lanes == max_lanes`.
# ⛔ A FULL BOX IS NOT MEASURED FOR A LEVEL AT ALL — the block measures it "only when there is room to
# give" (a full box's question is why it has no room, not which level owns it), so the polling contrast
# cannot be observed here. It is pinned at the SOURCE instead (`[ "${CASCADE_ROOM:-0}" -le 0 ]`), and
# the already-shipped full-box case above (`drive_cascade 5 25 25 10 1` => `0 1 1`) is the driven half.
ck "a BUSY PR (owned) is not a level — it does not hold the room" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' 9001 - 1)" "10 0 0 5"
ck "…while the SAME work UN-owned holds it (the pair is the discriminator)" \
   "$(drive_block 0 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	RED
' - - 1)" "0 1 0 3"

# ⛔ THE STATE THAT DECIDES THE WHOLE FLEET TODAY, PINNED (review P1, fix round): a RED MAIN on a box
# with FREE ROOM. Level 1 holds the room, so the issue path is closed — and it must be the LEVEL holding
# it, not a full box: `lanes=2` of `max=25` here, so an implementation that keyed on the room alone would
# dispatch issue work into a red main. The reviewer's OTHER half — "level 1 has no actor" — is NOT
# decided by this assertion and must not be: what level 1 DOES when it holds (dispatch a main-fix, or
# narrow its input to what the rail itself measures) is an owner decision, and nothing here pre-empts it.
# What IS pinned is that this state is not a DEADLOCK: 14e drives the SAME `room > 0 / slots == 0` shape
# and shows the drain escape really GRANTS a slot, so a main that stays red while the PR path produces
# nothing re-opens the issue path instead of closing it for ever.
ck "a RED MAIN on a box with FREE ROOM is level 1 and CLOSES the issue path (an issue must NOT be dispatched)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' - 'RED:verify')" "0 1 0 1"
ck "…and it is the LEVEL holding it, not a FULL box (23 lanes are free, so the poll is not armed)" \
   "$(drive_block 5 2 25 10 1 '9001:shaA:fix/a' '9001	shaA	GREEN
' - 'RED:verify' | cut -d' ' -f3)" "0"

# ── 12. LEVEL 1 IS FED BY MAIN'S OWN CHECK-RUNS ─────────────────────────────────────────────────
# ⛔ AN UNFED LEVEL IS DECORATION. These arms drive `cascade_main_probe` against a stub `gh` and pin
# the polarity the brief states: a check that RAN on main and concluded non-green is a red; a check
# that does not run on main at all (most of this repo's are `pull_request`-only) leaves no run and is
# therefore NOT a red — the false re-report of `verify` after #3503 merged.
echo
echo "=== 12. level 1: measured from MAIN's runs, and absence is not a red ==="
mkdir -p "$TMP/mpbin"
# ⛔ THE STUB EMITS THE SHAPE THE PROBE NOW ASKS `gh --jq` FOR: one TSV row per ATTEMPT, because
# `--paginate` emits one JSON object PER PAGE and a `json.load` would read only the first page. The
# fixture pays that shape, so a future change back to whole-JSON would fail here instead of silently
# grading page one. `GH_FAIL=1` models a transport failure (the case that must not read as GREEN).
cat > "$TMP/mpbin/gh" <<'GHEOF'
#!/bin/bash
[ "${GH_FAIL:-0}" = "1" ] && exit 1
printf '%s\n' "${GH_ROWS:-}"
GHEOF
chmod +x "$TMP/mpbin/gh"
# ⛔ THE SHIPPED PROBE READS THROUGH `gh_bounded`, NOT `gh` (agent-infra#2028), SO THE RIG MUST CARRY
# THAT NAME. Measured on CI at 40e736e4: every arm below read `UNMEASURED … (gh rc=127)` because the
# extracted `cascade_main_probe` called a function the extraction never brings in, and the two mutation
# arms then reported "the assertion does NOT discriminate" — a rig that fails for a reason it does not
# test, which is the fail-open shape this suite exists to prevent. It is an EXECUTABLE on the fixture
# PATH (not a shell function) because the probes run the block in a CHILD (`bash "$probe"`), so an
# in-process stub would be invisible to exactly the arms that need it. A TRANSPARENT PASS-THROUGH on
# purpose: the bound itself is graded by `gh-bound.test.sh` against the real shipped block, and
# re-implementing it here would make this suite depend on `scripts/lib/bounded.sh` on the runner. The
# name stays pinned — a rename in the shipped block leaves this shim unused and every arm RED again.
cat > "$TMP/mpbin/gh_bounded" <<'GHBEOF'
#!/bin/bash
exec gh "$@"
GHBEOF
chmod +x "$TMP/mpbin/gh_bounded"
probe_main() { # <tsv rows…> -> the recorded verdict line ('' when none was written)
  local w="$TMP/mp$$"
  rm -rf "$w"; mkdir -p "$w/state"
  # ⛔ `export GH_ROWS` — the stub `gh` is a CHILD process, so an unexported assignment is invisible
  # to it: the stub printed nothing, every row read as an EMPTY surface, and section 12 went green on
  # `GREEN` for a FAILING run (measured: 5 assertions red on the first attempt).
  ( O="$w"; LOG=/dev/null; PATH="$TMP/mpbin:$PATH"; GH_ROWS="$1"; export GH_ROWS
    . "$FNS"
    cascade_main_probe acme/widget >/dev/null 2>&1
    head -1 "$w/state/main-verdict" 2>/dev/null ) 2>/dev/null
}
# row = <id>\t<app.slug>\t<name>\t<status>\t<conclusion>
row() { printf '%s\t%s\t%s\t%s\t%s' "$1" "${2:-github-actions}" "$3" "$4" "${5:-}"; }
ck "an all-green main is GREEN" \
   "$(probe_main "$(row 11 s verify completed success)")" "GREEN"
ck "a run that FAILED on main is RED, and it is NAMED" \
   "$(probe_main "$(row 11 s verify completed failure)")" "RED:verify"
ck "cancelled is NOT red (the rail's own polarity)" \
   "$(probe_main "$(row 11 s docs completed cancelled)")" "GREEN"
ck "a check still RUNNING is not red" \
   "$(probe_main "$(row 11 s test in_progress '')")" "GREEN"
ck "an EMPTY surface (every check is pull_request-only) is NOT red" "$(probe_main '')" "GREEN"
ck "an unreadable listing records UNMEASURED, not a verdict" \
   "$( ( export GH_FAIL=1; probe_main "$(row 11 s verify completed failure)" ) | cut -d' ' -f1 )" "UNMEASURED"
# ⛔ THE RE-RUN RULE (review 2026-11-04, P1). `filter=all` returns EVERY ATTEMPT, so a job that failed
# once and PASSED on the re-run is green — the defect AGENTS.md names verbatim ("a re-run ADDS a red —
# it does not clear one"). The first version read RED here and would have pinned level 1 (FIX_MAIN)
# for ever, re-creating the barrier this change removes. Three rows, one job, three attempts:
ck "a job that failed then PASSED on a re-run is GREEN (the newest attempt decides)" \
   "$(probe_main "$(printf '%s\n%s' "$(row 11 s verify completed failure)" "$(row 12 s verify completed success)")")" "GREEN"
ck "…and the answer does not depend on the ROW ORDER (newest is by id, not by line)" \
   "$(probe_main "$(printf '%s\n%s' "$(row 12 s verify completed success)" "$(row 11 s verify completed failure)")")" "GREEN"
ck "…while a NEWEST red still reds (the control half: the rule is not 'any success wins')" \
   "$(probe_main "$(printf '%s\n%s' "$(row 11 s verify completed success)" "$(row 12 s verify completed failure)")")" "RED:verify"
ck "…and an in-flight NEWEST attempt is not a red even over an older failure" \
   "$(probe_main "$(printf '%s\n%s' "$(row 11 s verify completed failure)" "$(row 12 s verify in_progress '')")")" "GREEN"
ck "…and a DIFFERENT app publishing the same job name is a separate check (the rail's key)" \
   "$(probe_main "$(printf '%s\n%s' "$(row 11 other verify completed success)" "$(row 12 'github-actions' verify completed failure)")")" "RED:verify"
ck "…and an UNMEASURED / ABSENT record is read as NOT red by the level" \
   "$( ( . "$FNS"; cascade_main_red "/nonexistent/state" ) 2>/dev/null )" "0"

# ── 12b. WHAT LEVEL 1 ACTUALLY DOES WHEN IT HOLDS (review P1, 2026-11-06) ────────────────────────
# ⛔ THE FINDING: level 1's hold has NO ACTOR, so a red main closes the issue path and does nothing
# toward fixing main. On a repo whose main carries `push`-only reds the hold is not a corner case but
# the steady state, so the reviewer asked for "red main + free room ⇒ what happens" to be DRIVEN
# rather than asserted as a level number.
# ⛔ WHAT THIS SECTION DECIDES, AND WHAT IT DELIBERATELY DOES NOT. Whether level 1 SHOULD dispatch a
# main repair or narrow its input to what the merge rail measures is a behavioural policy choice and
# an OWNER DECISION — this change implements neither (`docs/ops/self-healing-contract.md` §6, "LEVEL 1
# CAN HOLD WITHOUT AN ACTOR"). What IS gradeable without that decision is the STATE: (a) the hold is
# unbounded while the PR path is producing, because the only release that exists keys on an INERT PR
# path; (b) nothing in the controller acts on level 1; (c) the repair channel the level depends on is
# unreachable from the issue batch. Each is pinned so the decision is made against evidence, and so a
# future implementation of the action has to come past these assertions.
echo
echo "=== 12b. level 1: the hold has no actor, and its repair channel is unreachable ==="
# ⛔ THE PREDICATE IS THE SHIPPED ONE. `pl_escape_open` and friends are EXTRACTED from
# pr-owner-liveness.sh into the rig (a mirror here would grade itself), then driven below.
L1H="$TMP/l1help.sh"
: > "$L1H"
for _f in pl_num pl_idle_file pl_idle_streak pl_streak_reset pl_note_pass pl_escape_bound pl_escape_open; do
  _body="$(ex "$_f" "$HERE/pr-owner-liveness.sh")"
  if [ -z "$_body" ]; then bad "could not extract $_f() from pr-owner-liveness.sh — it moved or was reformatted"; fi
  printf '%s\n' "$_body" >> "$L1H"
done
. "$L1H"
# (a) THE STEADY STATE. `pl_note_pass` resets the inert streak on a POSITIVE spawn count by design, so
# `pl_escape_open` keeps answering NO however many passes level 1 holds for — the reviewer's measured
# point, driven rather than restated.
l1_escape_over_passes() { # <passes> <spawns-per-pass> <unowned> -> "<streak> <escape-open?>"
  local d="$TMP/l1-$1-$2" n=0 i=0 sp=no
  rm -rf "$d"; mkdir -p "$d"
  while [ "$i" -lt "$1" ]; do
    n="$( pl_note_pass "$d" "$2" "$3" 2>/dev/null )"
    i=$(( i + 1 ))
  done
  pl_escape_open "$d" "$3" 3 >/dev/null 2>&1 && sp=yes
  printf '%s %s\n' "${n:-?}" "$sp"
}
ck "a level-1 hold with the PR path PRODUCING never trips the drain escape (streak stays 0 over 6 passes)" \
   "$(l1_escape_over_passes 6 1 2)" "0 no"
ck "…while the SAME hold on an INERT PR path DOES trip it at the bound (the contrast that keeps this meaningful)" \
   "$(l1_escape_over_passes 3 0 2)" "3 yes"

# ⛔ …AND THE PIN THE ABOVE IS *NOT* (review P2, 2026-11-06). Counting the display NAME cannot see an
# actor written against the VARIABLE — `if [ "$CASCADE_MAIN_RED" = 1 ]; then spawn_main_repair; fi`
# contains no `FIX_MAIN` and would leave the name pin green. So the real absence being claimed is
# pinned too: `CASCADE_MAIN_RED` is CONSUMED exactly once, and that one site is the level walk that
# decides 1-vs-the-rest. A second consumer is where an actor would appear. (This is still a tripwire
# on the likely shapes, not a termination proof — but it is now a tripwire on BOTH of them.)
# ⛔ AND THE TRIPWIRE MUST SEE THE UNBRACED SPELLING TOO (review round 8, P2): the first version grepped
# `\${CASCADE_MAIN_RED` only, so the very shape its comment above QUOTES — `[ "$CASCADE_MAIN_RED" = 1 ]`
# — did not match, and an actor written that way left both pins green (measured: appending that line
# kept the count at 1). Both spellings are counted now, and the actor line takes it to 2.
# ⛔ ONE DEFINITION, BECAUSE A MUTANT CANNOT MUTATE THIS SUITE (review round 10, P2). `mut`/`mutfile`
# only ever mutate `$ORCH`/`spawn-gate.sh` — never a test file — so a probe that RE-IMPLEMENTS the
# pattern inline grades its own private copy: reverting the shipped pin to `grep -c`, or to the
# braced-only pattern, left every assertion green while M23 still reported `shipped=yes, mutant=no`
# (measured: three weakened forms, suite 165/0 every time). The pattern AND the pipeline now live in one
# exported function used by BOTH the assertion and the probe — so weakening either weakens precisely the
# thing the mutant measures, the mutant then reports `mutant=yes`, and the suite goes RED. This is the
# suite's own contract ("every function under test is EXTRACTED FROM THE SHIPPED SCRIPT, never
# re-implemented here: a mirror would grade itself") applied to a pin rather than to a function.
MRPAT='\$\{CASCADE_MAIN_RED|\$CASCADE_MAIN_RED([^A-Z_]|$)'
export MRPAT
mainred_consumers() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -oE "$MRPAT" | wc -l | tr -d ' '; }
# bash 3.2 (the model CI runs) supports `export -f`; guard so a hostile shell cannot abort the suite.
export -f mainred_consumers 2>/dev/null || true
ck "…and CASCADE_MAIN_RED is CONSUMED exactly once (a second consumer is where an actor would live)" \
   "$(mainred_consumers "$ORCH")" "1"
# ⛔ DECLARED LIMIT OF THIS PIN, so it is not read as a proof it does not give: it is NAME-based. It
# fires when an actor is added KEYED ON THE LEVEL'S NAME (`FIX_MAIN`), which is how a level branch is
# written in this file (`cascade_level_name` is the one map every other consumer uses) — it cannot
# prove that no actor exists under some other spelling. It is a tripwire on the likely shape, not a
# termination proof. Counted as OCCURRENCES, not lines: an actor appended to the existing mapping line
# is still an actor, and a line-count would have called that mutant indistinguishable (measured — M20
# failed exactly that way on the first form of this probe).
ck "level 1 has NO ACTOR keyed on the level's NAME: FIX_MAIN occurs on non-comment lines exactly ONCE" \
   "$(grep -vE '^[[:space:]]*#' "$ORCH" | grep -o 'FIX_MAIN' | wc -l | tr -d ' ')" "1"
ck "…and that one line is cascade_level_name's mapping, not a dispatch" \
   "$(grep -vE '^[[:space:]]*#' "$ORCH" | grep 'FIX_MAIN' | sed 's/^[[:space:]]*//')" '1) echo FIX_MAIN ;;'

# (c) THE REPAIR CHANNEL: the exemption must recognise the title the repo ACTUALLY files.
# ⛔ THIS HALF WAS A REAL BUG AND IS FIXED, NOT PINNED AS INTENDED STATE (review P2, 2026-11-06).
# `land_backlog_exempt`'s header records the POLICY — "a `base-red` / `main-red` repair … landing one is
# the single highest-leverage way to REDUCE the backlog, and holding it would be exactly backwards" —
# but its six title patterns (`base-red|main-red|base red|main is red|main goes red|red main`) match
# NONE of them the title the repo's only main-red filer produces: `ci-main.yml`'s
# `auto-file-on-failure` titles its issue `main broken by merge: <failing jobs>`. So the decided policy
# had never fired for a single auto-filed repair. The pattern now includes the filer's own prefix —
# which implements a decision already recorded, and introduces no policy — and what these assertions
# pin is that the CHANNEL IS RECOGNISED, so a future edit that removes the arm goes RED instead of
# quietly re-inerting the exemption.
GATE="$HERE/spawn-gate.sh"
CIW="$HERE/../../.github/workflows/ci-main.yml"
ck "the issue ci-main.yml auto-files is TITLED 'main broken by merge…' (the fixture is the shipped template)" \
   "$(grep -c 'main broken by merge: \${failed.join' "$CIW" 2>/dev/null | tr -d ' ')" "1"
repair_arms() { # every SHIPPED title arm, joined into ONE case-pattern list
  sed -n '/case "\$title" in/,/^  esac/p' "$GATE" 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | sed -n 's/^[[:space:]]*\(.*\))[[:space:]]*$/\1/p' \
    | awk 'NF' | tr '\n' '|' | sed 's/|[[:space:]]*$//'
}
ck "the shipped main-red repair arms were FOUND in spawn-gate.sh (a rename must not skip this)" \
   "$([ -n "$(repair_arms)" ] && echo found || echo missing)" "found"
repair_match() { # <title> -> "matches" when the SHIPPED arm list accepts it
  local arms; arms="$(repair_arms)"
  [ -n "$arms" ] || { echo NO-ARMS; return 0; }
  ( eval "case \"\$1\" in $arms) echo matches ;; *) echo no ;; esac" )
}
ck "⛔ the auto-filed 'main broken by merge: …' IS recognised as a repair (the exemption is no longer inert)" \
   "$(repair_match 'main broken by merge: script-validate')" "matches"
ck "…and the bare variant the filer emits when it cannot name a job is recognised too" \
   "$(repair_match 'main broken by merge')" "matches"
ck "…the shapes it was originally written for still match (control half)" \
   "$(repair_match 'main-red: script-validate broken')" "matches"
ck "…and an UNRELATED title is not exempted (control: the arms are not 'everything')" \
   "$(repair_match 'feat(harness): something unrelated')" "no"

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

# ── 14. REVIEW CYCLE 2: the two blocking findings, pinned so they cannot come back ─────────────
echo
echo "=== 14. an UNSET cascade input means 'older caller', never 'no room' ==="
# ⛔ CI RED (review cycle 2, P0). The batch guard used `:-0`, so an UNSET `CASCADE_ISSUE_SLOTS` read as
# "no room" and the batch broke immediately. Several SHIPPED suites drive that batch body standalone
# (`refresh-scout.test.sh:2232`), so nothing was queued at all: measured 446/9 against 455/0 on main.
# The rule is the terse-minus one the escape block already uses one place over.
ckin "the batch guard treats an UNSET slot count as 'pre-change', not as 0" \
   "$SRC" '[ "${CASCADE_ISSUE_SLOTS-1}" -ge 1 ] 2>/dev/null || break'
ckni "…and the \`:-0\` form is GONE from that guard (it is the CI red)" \
   "$SRC" '[ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 ] 2>/dev/null || break'

 echo "=== 14b. the interval is still spent when the census gives no baseline ==="
# ⛔ P1 (review cycle 2): the shipped call site did not pass `<lanes_at_pass_end>`, and a missing
# baseline returned 1 BEFORE SLEEPING — and this branch REPLACES the nap, so a full box re-ran the
# whole pass with no delay at all.
ckin "the shipped call SITE passes the lane census as the baseline" "$SRC" 'cascade_wait $(( 10#${CYC} - JIT + RANDOM % (2 * JIT + 1) )) "${LANES:-}"'
_s0=$SECONDS
( O="$TMP"; LOG=/dev/null; CASCADE_POLL=1; MAX_LANES=4
  . "$FNS"; . "$STUB"
  measure_lanes() { LANES=4; LANES_DISPLAY=4; LANES_UNKNOWN=0; }
  cascade_wait 2 "" >/dev/null 2>&1 ) 2>/dev/null
_el=$(( SECONDS - _s0 ))
ck "no baseline -> it still SPENDS the interval (returning 1 without sleeping is a hot loop)" \
   "$([ "$_el" -ge 2 ] && echo yes || echo no)" "yes"

 echo "=== 14c. the drain escape is withheld on NO ROOM, not on 'no slots' ==="
# ⛔ P1 (review cycle 2): slots are 0 in TWO states — a full box, and a level HOLDING the room with
# lanes idle. Withholding on the slots disabled the valve exactly where it exists (a merge ceiling
# that keeps refusing), and printed a cause ("NO ROOM … under MAX_LANES/mem/load") that is false.
ckin "…withheld only when the ROOM is exhausted" "$SRC" 'if [ "${CASCADE_ROOM:-1}" -le 0 ] 2>/dev/null; then'

 echo "=== 14e. the PAIR: a level HOLDS the room while the escape is open — the escape must QUEUE ==="
# ⛔ P1 (fix round). 14c proved the escape is withheld only on NO ROOM; section 11 proved that a
# higher level HOLDS the room. The two were never DRIVEN TOGETHER, so nothing graded the state the
# valve actually exists for: `CASCADE_ROOM > 0` (there is a slot to give) with `CASCADE_ISSUE_SLOTS = 0`
# (a level is holding it). Driving the shipped block in that state found the escape recording
# `issue=OPENED-BY-ESCAPE`, printing "issue path OPEN this cycle" and resetting the inert-path streak
# over a batch whose FIRST statement (`[ "${CASCADE_ISSUE_SLOTS-1}" -ge 1 ] || break`) is guaranteed
# to break — zero issues queued, and the measured evidence of the stall destroyed by a pass that did
# nothing. Pre-change the same escape really DID dispatch (it was capped by `BATCH`), so that is a
# REGRESSION in precisely the state a refusing merge ceiling leaves behind (level 4's review loop).
# So the escape GRANTS the slots it spends. These arms drive the grant, its ROOM bound, and both
# stand-downs; M19 removes the grant and must redden them.
PLMOD="$HERE/pr-owner-liveness.sh"
[ -f "$PLMOD" ] || { echo "❌ $PLMOD not found"; exit 1; }
. "$PLMOD"
ESCBLK="$TMP/escape-blk.sh"
awk '/^  # \[drain-escape:begin\]/{f=1} f{print} /^  # \[drain-escape:end\]/{if(f) exit}' "$ORCH" > "$ESCBLK"
ck "the [drain-escape] block was FOUND in orch-loop.sh (a marker rename would otherwise skip 14e)" \
   "$([ -s "$ESCBLK" ] && grep -q 'pl_escape_open' "$ESCBLK" && echo yes || echo no)" "yes"
# ⛔ COMMAND SUBSTITUTION IS LIVE IN **ANY** DOUBLE-QUOTED WORD, NOT ONLY AFTER `echo` (review round 7,
# P2). A first version of this pin grepped `echo "` only — so re-introducing the defect through the
# block's own `printf` log writer (which is how the OTHER line in this block writes) stayed GREEN over an
# executable backtick. The comment lines are stripped first: the block's comments QUOTE the historical
# defect, so a naive `"[^"]*`' grep false-reds on them.
ck "…and it does NOT execute its own words: no CODE line carries a backtick inside a double-quoted word" \
   "$(sed 's/^[[:space:]]*#.*$//' "$ESCBLK" 2>/dev/null | grep -q '"[^"]*`' && echo yes || echo no)" "no"
ck "…and it carries the SLOT GRANT (the fix; without it the escape records what it cannot spend)" \
   "$(grep -q 'DRAIN ESCAPE GRANTS' "$ESCBLK" && echo yes || echo no)" "yes"
# The block is shipped shell, so it must PARSE before it is driven: a stray `fi` would abort the
# source midway, the assertions would read the fixture's own pre-set values, and a broken block would
# grade GREEN — the same false PASS `pr-owner-liveness.test.sh` records for its own drive.
bash -n "$ESCBLK" 2>/dev/null || bad "the extracted [drain-escape] block is not valid shell — the drive would abort midway"

esc_pair() { # <id> <room> <slots> <unread> [<backlog>] [<batch>] [<can>] -> "<slots> <record|none>"
  # ⛔ THE FIXTURE DIRECTORY IS DERIVED FROM `$TMP`, NOT FROM A POSITIONAL ARG. The main-worktree-guard
  # refuses any `rm -rf` whose target it cannot resolve statically (a `$1`-derived path reads as a
  # possible WHOLE-TREE discard and fails closed, #709), and that refusal lands on the SUITE, not on the
  # fixture — the whole file becomes unrunnable. `$TMP/ep-<id>` is resolvable, so the discard is
  # statically visible and the suite stays executable.
  local d="$TMP/ep-$1" room="$2" slots="$3" unread="$4" blg="${5-}" btch="${6:-2}" can="${7-}"
  rm -rf "$d"; mkdir -p "$d/state"
  # Prime the inert-path streak at the bound, so `pl_escape_open` answers YES on the shipped predicate
  # rather than on a fixture that never got there.
  pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
  pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
  ( set +e
    # `O` is the PARENT of the state dir: the shipped block addresses `$O/state/...`, and a fixture
    # that pointed the two at different directories would drive a block reading an EMPTY state dir.
    O="$d"; LOG="$d/state/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=0
    DRAIN_ESCAPE_PASSES=2; GATE_WHY="GW_SENTINEL"; LANES_DISPLAY=2; MAX_LANES=7
    CASCADE_ROOM="$room"; CASCADE_ISSUE_SLOTS="$slots"; CASCADE_UPN_UNREADABLE="$unread"
    # ⛔ `BATCH` IS A REAL KNOB AGAIN (review round 5, P2). A first version hardcoded `BATCH=2`, so the
    # arm that claims "a large BATCH does not widen it past room/2" ran with BATCH=2 against room=5 —
    # where `room/2` and `min(BATCH,ROOM)` BOTH yield 2. The arm passed on the very implementation it
    # exists to reject. `CASCADE_CAN` is likewise explicit: UNSET means the driver-rig contract, and 0
    # means the allocator refused on load/mem even though the box had room.
    CASCADE_QUEUE_DEPTH="$blg"; BATCH="$btch"
    if [ -n "$can" ]; then CASCADE_CAN="$can"; fi
    . "$ESCBLK"
    printf '%s %s\n' "${CASCADE_ISSUE_SLOTS:-unset}" \
      "$( [ -s "$d/state/drain-escape" ] && echo record || echo none )" ) 2>/dev/null
}
ck "level HOLDS the room (room=5, slots=0, backlog loose) -> the escape GRANTS room/2 and RECORDS" \
   "$(esc_pair 1 5 0 0 10)" "2 record"
ck "…and the grant is LOGGED, naming the slots it spends" \
   "$(grep -q 'DRAIN ESCAPE GRANTS 2 issue slot' "$TMP/ep-1/state/log" 2>/dev/null && echo yes || echo no)" "yes"
ck "…HALVED, not min(room,BATCH): room=9 grants 4, because one issue costs two worker records" \
   "$(esc_pair 2 9 0 0 99)" "4 record"
ck "…with a FLOOR of 1 when the box has room (a lane that parks early never attaches its chain)" \
   "$(esc_pair 3 1 0 0 99)" "1 record"
ck "…an UNSET/empty backlog is COERCED to 0 like the allocator, so the grant produces nothing" \
   "$(esc_pair 4 5 0 0)" "0 none"
ck "…and a NON-NUMERIC backlog is coerced too (the allocator answers 0 there, so the grant must)" \
   "$(esc_pair 12 5 0 0 abc)" "0 none"
ck "a cascade that ALREADY granted 3 is not re-granted upward" \
   "$(esc_pair 5 5 3 0 10)" "3 record"
ck "NO ROOM still withholds the escape (cycle 2's ruling is KEPT, not reverted)" \
   "$(esc_pair 6 0 0 0 10)" "0 none"
ck "an UNREADABLE un-owned count withholds instead of spending a slot (fail-closed kept)" \
   "$(esc_pair 7 5 0 1 10)" "0 none"
# ⛔ THE EMPTY BACKLOG: nothing can be queued whatever the slots say, so the escape must NOT record —
# and it must not name a level as the cause either, because with a 0-length backlog the cascade block
# never runs (`slots > 0` gate) and NO level is measured. Same false-PASS shape as the defect above.
ck "an EMPTY BACKLOG withholds: recording an escape over an empty queue is a false PASS" \
   "$(esc_pair 8 5 0 0 0)" "0 none"
ck "…and BATCH is never the grant: BATCH=9 with room=5 still grants 2, not min(BATCH,ROOM)=5" \
   "$(esc_pair 9 5 0 0 10 9)" "2 record"
# ⛔ THE CAPACITY-REFUSED STATE (review round 5, P1): `CASCADE_ROOM` is `MAX_LANES - LANES` and knows
# nothing about the load/mem probe, so room>0 coexists with a REFUSED `can_spawn`. `cascade_issue_slots`
# returns 0 for it, the issue batch has NO guard on `CASCADE_CAN` (`dispatch-merge.sh`'s `wt_spawn` never
# consults the load gate), so a grant here would spawn two worker records on a box the allocator refused
# and consume the room it was given. This arm is the one that would have caught that.
ck "a REFUSED capacity probe withholds even with room — the allocator refused, so there is no slot" \
   "$(esc_pair 10 5 0 0 10 2 0)" "0 none"
ck "…and a GRANTED probe (can=1) still escapes, so the arm above is not passing on a dead path" \
   "$(esc_pair 11 5 0 0 10 2 1)" "2 record"

 echo "=== 14d. the funnel names WHICH of the three states deferred it ==="
# ⛔ P2 (review cycle 2): one boolean, three causes, one sentence. `holds` and `unreadable` must not
# claim "no room left"; the default caller keeps the original wording byte for byte.
sel13() { ( . "$FNS"; lo_select 15 0 5 0 3 "" 10 1 2 ok 1 1 "$1" > "$TMP/s13.$$" 2>/dev/null
           cat "$TMP/s13.$$" ) }
ckin "a LEVEL-HOLD deferral says a higher level holds the room" "$(sel13 holds)" "a higher level is holding the room"
ckni "…and does not claim there is no room" "$(sel13 holds)" "no room left"
ckin "an UNREADABLE count says the count could not be read" "$(sel13 unreadable)" "the count could not be read"
ckin "the default (no cause given) keeps the original sentence" "$(sel13 '')" "no room left after it"
# ⛔ THE ZERO-UN-OWNED HOLD, ASSERTED — NOT ONLY MUTATED (review 2026-11-07, P2). The probe added for
# `M24` discarded stdout, so it pinned the CHOICE but not the LINE the arm exists to print: gutting the
# arm's `issues_why` to name the wrong cause (`DISPATCH (… in backlog)`, or the "no room left after it"
# misattribution repaired once already) left all 168 assertions green. So the state is asserted here as
# a `ck`, and the mutant probes below share the same state. `unowned=0`, `prw=1`, no cap ⇒ the funnel
# must DEFER **and** name the hold, because `CASCADE_ISSUE_SLOTS` is 0 and the batch's first guard
# would break — a printed DISPATCH over a batch that queues nothing.
selz() { ( . "$FNS"; lo_select 0 0 0 0 3 "" 10 1 2 ok 1 1 2>/dev/null ) }
ckin "a LEVEL-HOLD with ZERO un-owned PRs DEFERS and NAMES the hold (level 1 owns the room)" \
   "$(selz)" "a higher level is holding the room"
ck "…and its choice is none, never a DISPATCH over a batch that queues nothing" \
   "$( ( . "$FNS"; lo_select 0 0 0 0 3 "" 10 1 2 ok 1 1 >/dev/null 2>&1; printf '%s' "$LO_CHOICE" ) )" "none"

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
  for _f in is_num is_limit pr_in_set _wedge_min measure_ownership_sets measure_ci_inflight \
          worker_log_name pr_owned \
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
: > "$W/logs/merge-9001.log"; : > "$W/logs/fix-9002.log"; : > "$W/logs/merge-9003.log"
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

# ⛔ THE ZERO-UN-OWNED HOLD ARM, WHICH NOTHING PINNED (review 2026-11-07, P1 — measured). The
# `elif [ "${prw:-}" = "1" ]` arm is the ONLY place a pass with ZERO un-owned PRs can report that a
# higher level holds the room, and every OTHER probe here reaches the other arms first: M5 and `sel13`
# both drive `unowned=5`, and `live-ownership.test.sh`'s (a2)/(b) never pass `prw=1` at `unowned=0`.
# So deleting the whole arm left test-cascade at 167/0 and live-ownership at 74/0 — the exact
# silent-coverage hole a mutant exists to close. Driven at the state the arm is FOR: `unowned=0`,
# `prw=1`, no cap, room to give ⇒ `DEFERRED`, because `CASCADE_ISSUE_SLOTS` is 0 and the batch's own
# first guard would break (a printed DISPATCH over a batch that queues nothing).
cat > "$TMP/p-selz.sh" <<'PEOF'
# Grades the SHIPPED arm: the CHOICE and the LINE it prints. (A probe that discarded stdout pinned only
# the branch, and let the arm be gutted to a string naming the wrong cause with the suite green.)
# ⛔ `LO_CHOICE` MUST BE READ INSIDE THE SAME SUBSHELL (measured): `lo_select` sets it in the shell that
# runs it, so a `$( … )` that only calls it leaves the PARENT's copy unset — the first form of this probe
# tested `[ "$LO_CHOICE" = "none" ]` on the outside and printed `no` for the shipped module too, which
# made M24 and M25 inert assertions that could never go green (`shipped=[no] mutant=[no]`). Both facts
# therefore travel OUT of the subshell in one string.
out="$( . "$ORCH_FNS"; lo_select 0 0 0 0 3 "" 10 1 2 ok 1 1 2>/dev/null; printf '|CHOICE=%s' "$LO_CHOICE" )"
case "$out" in
  *"a higher level is holding the room"*"|CHOICE=none") echo yes ;;
  *) echo no ;;
esac
PEOF
mutlo "M24 the funnel drops the ZERO-un-owned hold arm -> it prints DISPATCH over a batch that queues nothing" \
    's/^  elif \[ "${prw:-}" = "1" \]; then$/  elif false; then/' "$TMP/p-selz.sh"
# ⛔ AND THE ARM'S OWN SENTENCE MUST BE PINNED SEPARATELY: `M24` kills the whole arm, so it would still
# "discriminate" if the arm survived while its message were replaced with a cause it never measured.
mutlo "M25 the ZERO-un-owned hold prints the WRONG CAUSE (a DISPATCH string over a deferring branch)" \
    's/^    issues_why="DEFERRED (a higher level is holding the room this pass: ${unowned} un-owned PR(s))"$/    issues_why="DISPATCH ($backlog in backlog)"/' "$TMP/p-selz.sh"

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
: > "$W/logs/merge-9201.log"; touch -t 202001010000 "$W/logs/merge-9201.log"
printf '9201:sA:b1\n' > "$W/state/last-open-prs"
measure_ownership_sets
# yes == the wedged record does NOT own its PR
pr_in_set "$WORKING_PR_SET" 9201 && echo no || echo yes
PEOF
mut "M8 a wedged record owns its PR again (a corpse holding the gate and a slot)" \
    's/^        pr_in_set "\$wed" "\$(worker_log_name "\$n")" && { WEDGED_SET="\$WEDGED_SET\$n "; continue; }$/        : # wedge filter removed/' \
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
# ⛔ THE ROW MUST BE THE SHAPE THE PROBE PARSES (tsv via --jq, one per attempt). An earlier version of
# this probe fed `{"check_runs":[…]}` JSON, which the tsv reader cannot parse — it produced no rows,
# read GREEN, and the mutant "discriminated" for a reason that had nothing to do with `cancelled`.
. "$ORCH_FNS"
W="$FIX/m-cancel"; rm -rf "$W"; mkdir -p "$W/state"; O="$W"
# ⛔ ONE STUB, THE ONE SECTION 12 ALREADY DROVE. Writing a second stub inside this probe reintroduced
# the same quoting variance that made an earlier version of this assertion "discriminate" for a
# reason unrelated to the code under test (`printf` mangles `\\n` differently in a nested heredoc).
PATH="$FIX/mpbin:$PATH" GH_ROWS="$(printf '11\tgithub-actions\tdocs\tcompleted\tcancelled')" \
  cascade_main_probe acme/widget >/dev/null 2>&1
[ "$(head -1 "$W/state/main-verdict" 2>/dev/null)" = "GREEN" ] && echo yes || echo no
PEOF
mut "M14 a CANCELLED run on main counts as red (the polarities the rail allows are re-narrowed)" \
    's/("success", "neutral", "skipped", "cancelled", "stale")/("success", "neutral", "skipped", "stale")/' "$TMP/p-cancel.sh"

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

cat > "$TMP/p-group.sh" <<'PEOF'
# THE RE-RUN RULE: one job, failed then passed. Newest (by id) must win.
. "$ORCH_FNS"
w="$FIX/m-group"; rm -rf "$w"; mkdir -p "$w/state"
PATH="$FIX/mpbin:$PATH"
GH_ROWS="$(printf '11\tgithub-actions\tverify\tcompleted\tfailure\n12\tgithub-actions\tverify\tcompleted\tsuccess')"
export GH_ROWS
O="$w"; LOG=/dev/null
cascade_main_probe acme/widget >/dev/null 2>&1
[ "$(head -1 "$w/state/main-verdict" 2>/dev/null)" = "GREEN" ] && echo yes || echo no
PEOF
mut "M16 the NEWEST attempt no longer wins (a superseded red pins level 1 for ever)" \
    's/if prev is None or cid > prev\[0\]:/if prev is None:/' "$TMP/p-group.sh"

cat > "$TMP/p-unset.sh" <<'PEOF'
# THE CI RED: the guard must read an UNSET slot count as "pre-change", and must not carry the `:-0`
# form that reads it as "no room".
# ⛔ A SOURCE PIN, NOT A DRIVEN ONE, ON PURPOSE: driving the grepped line means either writing a `.sh`
# and sourcing it (the #1484 script-backdoor shape, which the guard refused while this suite did it)
# or `eval`-ing text read at runtime (which the same guard also refuses, and which is a real backdoor
# idiom regardless). The BEHAVIOUR is graded by `refresh-scout.test.sh`, which drives this exact batch
# body standalone through CI — that is where the 446/9 regression was measured — so this pin only has
# to keep the two SPELLINGS honest.
grep -q '\[ "${CASCADE_ISSUE_SLOTS-1}" -ge 1 \]' "$TGT" \
  && ! grep -q '\[ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 \]' "$TGT" && echo yes || echo no
PEOF
mut "M17 the batch guard reads an UNSET count as 0 again (the refresh-scout CI red)" \
    's/\[ "\${CASCADE_ISSUE_SLOTS-1}" -ge 1 \]/[ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 ]/' "$TMP/p-unset.sh"

cat > "$TMP/p-call.sh" <<'PEOF'
# THE HOT LOOP: the shipped call must hand `cascade_wait` the lane census.
grep -q 'cascade_wait $(( 10#${CYC} - JIT + RANDOM % (2 \* JIT + 1) )) "${LANES:-}"' "$TGT" && echo yes || echo no
PEOF
mut "M18 the call site drops the baseline again (the interval is never spent)" \
    's/ "${LANES:-}" || true/ || true/' "$TMP/p-call.sh"

cat > "$TMP/p-pair.sh" <<'PEOF'
# THE PAIR, DRIVEN (fix round, P1): room to give + a level HOLDING the slots + the escape open.
# The shipped block must GRANT a slot and QUEUE; the pre-fix shape opened the path, recorded
# `issue=OPENED-BY-ESCAPE` and queued nothing. The block is extracted from `$TGT`, so the mutant is
# graded on its OWN text rather than on a mirror.
. "$ORCH_FNS"; . "$STUB"; . "$MODP"
d="$FIX/e-pair"; rm -rf "$d"; mkdir -p "$d/state"
pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
awk '/^  # \[drain-escape:begin\]/{f=1} f{print} /^  # \[drain-escape:end\]/{if(f) exit}' "$TGT" > "$FIX/pair-blk.sh"
( set +e
  O="$d"; LOG="$d/state/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=0
  DRAIN_ESCAPE_PASSES=2; GATE_WHY="GW_SENTINEL"; LANES_DISPLAY=2; MAX_LANES=7
  CASCADE_ROOM=5; CASCADE_ISSUE_SLOTS=0; CASCADE_UPN_UNREADABLE=0; CASCADE_CAN=1; BATCH=2
  # ⛔ THE BACKLOG MUST BE NUMERIC HERE (review round 6): the grant now COERCES a non-numeric backlog to
  # 0 exactly as the allocator does, so leaving it unset makes this probe's own scenario unreachable —
  # "a level HOLDS the room" is only a stall when there ARE candidates to queue.
  CASCADE_QUEUE_DEPTH=10
  . "$FIX/pair-blk.sh"
  [ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 ] && [ -s "$d/state/drain-escape" ] && echo yes || echo no ) 2>/dev/null
PEOF
# `mut` passes a fixed environment, so the module path travels as an EXPORTED var (the mutant copy
# lives in $TMP and has no sibling module beside it).
export MODP="$HERE/pr-owner-liveness.sh"
mut "M19 the escape opens the issue path WITHOUT granting the slots it spends (the level-holds no-op restored)" \
    's/^    if \[ "${CASCADE_ROOM:-1}" -ge 1 \] 2>\/dev\/null && \[ "${CASCADE_UPN_UNREADABLE:-0}" = "0" \] && \[ "${CASCADE_CAN:-1}" = "1" \] && \[ "${CASCADE_ISSUE_SLOTS-1}" -le 0 \] 2>\/dev\/null; then$/    if false; then/' "$TMP/p-pair.sh"

# ⛔ THE COERCED BACKLOG, DRIVEN (review round 6, P2): `cascade_issue_slots` does
# `is_num "${bl:-}" || bl=0`, so an UNSET/empty/non-numeric backlog answers **0** there. A grant that
# caps only when the value IS numeric records an escape over a queue it never measured — the same
# false-PASS direction the backlog=0 arm closes. Driven on the extracted block, so the mutant is graded
# on its own text.
cat > "$TMP/p-blgcoerce.sh" <<'PEOF'
. "$ORCH_FNS"; . "$STUB"; . "$MODP"
d="$FIX/e-blgc"; rm -rf "$d"; mkdir -p "$d/state"
pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
pl_note_pass "$d/state" 0 2 >/dev/null 2>&1
awk '/^  # \[drain-escape:begin\]/{f=1} f{print} /^  # \[drain-escape:end\]/{if(f) exit}' "$TGT" > "$FIX/blgc-blk.sh"
( set +e
  O="$d"; LOG="$d/state/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=0
  DRAIN_ESCAPE_PASSES=2; GATE_WHY="GW_SENTINEL"; LANES_DISPLAY=2; MAX_LANES=7
  CASCADE_ROOM=5; CASCADE_ISSUE_SLOTS=0; CASCADE_UPN_UNREADABLE=0; CASCADE_CAN=1; BATCH=2
  unset CASCADE_QUEUE_DEPTH
  . "$FIX/blgc-blk.sh"
  [ "${CASCADE_ISSUE_SLOTS:-0}" -ge 1 ] && echo no || { [ -s "$d/state/drain-escape" ] && echo no || echo yes; } ) 2>/dev/null
PEOF
mut "M22 the grant caps the backlog ONLY when it is numeric (unset/empty/non-numeric grants anyway, the allocator answers 0)" \
    's/^      is_num "${CASCADE_QUEUE_DEPTH:-}" || CASCADE_QUEUE_DEPTH=0$/      is_num "${CASCADE_QUEUE_DEPTH:-}" || CASCADE_QUEUE_DEPTH=999/' "$TMP/p-blgcoerce.sh"

# ── 12b-M. MUTANTS FOR THE LEVEL-1 STATE PINS ────────────────────────────────
# ⛔ `mut`/`mutlo` only ever mutate `$ORCH`/`$LO` and grade FUNCTIONS. The 12b pins are SOURCE facts
# across three files (`orch-loop.sh`, `spawn-gate.sh`, `ci-main.yml`), so they need their own runner
# — reusing `mut` with a grep probe would mutate the controller and grade a file the probe does not
# read, which is the vacuous-mutant shape this suite exists to refuse.
mutfile() { # <label> <file> <sed-expr> <probe-file>  (probe reads $TGT, prints `yes` when it holds)
  local label="$1" file="$2" expr="$3" probe="$4" m got mutgot
  m="$TMP/mf-$(basename "$file")"
  sed "$expr" "$file" > "$m" 2>/dev/null
  if [ ! -s "$m" ] || cmp -s "$m" "$file"; then
    bad "$label — the mutation changed NOTHING (a vacuous mutant)"; rm -f "$m"; return
  fi
  got="$(    TGT="$file" bash "$probe" 2>/dev/null )"
  mutgot="$( TGT="$m"    bash "$probe" 2>/dev/null )"
  rm -f "$m"
  if [ "$got" = "yes" ] && [ "$mutgot" != "yes" ]; then
    ok "$label  (shipped=yes, mutant=no)"
  else
    bad "$label — shipped=[${got:-<empty>}] mutant=[${mutgot:-<empty>}]: the assertion does NOT discriminate"
  fi
}

# (b) an ACTOR on level 1 — the pin's whole job is to be RED the day one is added.
cat > "$TMP/p-l1actor.sh" <<'PEOF'
# OCCURRENCES, not lines — an actor appended to the mapping line is still an actor.
n="$(grep -vE '^[[:space:]]*#' "$TGT" 2>/dev/null | grep -o 'FIX_MAIN' | wc -l | tr -d ' ')"
[ "$n" = "1" ] && echo yes || echo no
PEOF
mutfile "M20 an ACTOR is added for level 1 (a spawn keyed on FIX_MAIN) -> the 'no actor' pin goes RED" \
    "$ORCH" 's/^    1) echo FIX_MAIN ;;$/    1) echo FIX_MAIN ;; spawn_main_repair "FIX_MAIN"/' "$TMP/p-l1actor.sh"

# ⛔ M23 GRADES THE **WIDENED** `CASCADE_MAIN_RED` PIN (review round 9, P2). The suite's own contract
# (`:34-36`) says a mutation is what turns "the assertion can fail" from a claim into a measurement, and
# the widened pin had none: reverting it to the braced-only pattern left every assertion green. The
# mutant is the shape the pin exists for — an actor written against the UNBRACED variable, APPENDED TO
# THE CONSUMER'S OWN LINE (a second consumer on one line, which is what `grep -c` could not see).
cat > "$TMP/p-mainred-consumer.sh" <<'PEOF'
# Grades the SHIPPED definition (`mainred_consumers`, exported above) — never a copy of it.
n="$(mainred_consumers "$TGT")"
[ "$n" = "1" ] && echo yes || echo no
PEOF
mutfile "M23 an actor consumes the UNBRACED \$CASCADE_MAIN_RED on the consumer's own line -> the pin goes RED" \
    "$ORCH" 's|^  if \[ "${CASCADE_MAIN_RED:-0}" = "1" \]; then$|  if [ "${CASCADE_MAIN_RED:-0}" = "1" ]; then spawn_main_repair "$CASCADE_MAIN_RED"; fi|' "$TMP/p-mainred-consumer.sh"
# (c) the repair pattern widened to accept the auto-filed title — the pin must catch that too, in the
# OTHER direction from the control half above (widening makes the gap vanish and the pin go RED).
cat > "$TMP/p-l1pattern.sh" <<'PEOF'
# yes when the SHIPPED arm list recognises the title the repo's own filer produces.
arms="$(sed -n '/case "\$title" in/,/^  esac/p' "$TGT" 2>/dev/null \
  | grep -vE '^[[:space:]]*#' \
  | sed -n 's/^[[:space:]]*\(.*\))[[:space:]]*$/\1/p' \
  | awk 'NF' | tr '\n' '|' | sed 's/|[[:space:]]*$//')"
[ -n "$arms" ] || { echo no; exit 0; }
r="$( ( eval "case \"main broken by merge: script-validate\" in $arms) echo matches ;; *) echo no ;; esac" ) )"
[ "$r" = "matches" ] && echo yes || echo no
PEOF
# ⛔ THE MUTANT RUNS IN THE FIX DIRECTION: it DELETES the filer's arm, which must make the assertion go
# RED. (The first form of this mutant ADDED a pattern and graded the old "unreachable" pin — i.e. it
# proved that FIXING the exemption tripped the suite, which is the pin-a-defect-as-intended-state shape
# the review called out.)
mutfile "M21 the filer's title arm is REMOVED from land_backlog_exempt -> the repair-channel pin goes RED" \
    "$HERE/spawn-gate.sh" '/^    main\\ broken\\ by\\ merge\*)$/d' "$TMP/p-l1pattern.sh"

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
