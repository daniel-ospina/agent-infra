#!/bin/bash
# pr-review-order.test.sh — agent-infra#2971: the answer to NEEDS-REVIEW is a REVIEW ORDER.
#
# ⛔ WHAT THIS SUITE IS FOR, in the log it reproduces (2026-10-28, tortoise PR #10213, the Mac
# controller):
#
#   10213 FAILED:ai-review-gate
#   10213 NEEDS-REVIEW (no findings marker at head=4c50922…) — the remedy is another review, NOT a fixer
#   10213 re-record
#   [spawn] SPAWNED 5 worker(s) in this pass's PR sweep: merge-10021,…,merge-10213,merge-10214
#   [pr] PR path: 5 acted (#10213,…) … spawned=5 this pass
#
# The loop named the right remedy and then spawned `merge-10213` — the same tag a LANDING worker
# carries — so nothing in the pass told a review order apart from a re-run of the thing that had just
# been refused, and the next pass logged the same diagnosis. Two artifacts fix that, and both are
# DRIVEN here rather than grepped:
#
#   D1 the review arm dispatches `review-<PR>` for that (PR, head), and NEVER `merge-<PR>`.
#   D2 ONE (PR, head) review budget: `state/reviewdisp-<PR>` is spent by the controller's dispatch AND
#      by merge-one.sh's verdict-less run, counted ONCE (``REV_PAID=1`` is the seam), and a review
#      attempt that ends without a CLEAN/ISSUES marker is a COUNTED failed attempt with its reason.
#
# Mutation (the one this section must survive): put the spawn tag back to `merge-$PR` and D1 reddens
# naming `merge-10213`; drop the shared-budget spend and D2 reddens naming `reviewdisp`.
#
# Hermetic: no network, no tmux, no gh. Run: bash pr-review-order.test.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$HERE/orch-loop.sh"
MERGE="$HERE/merge-one.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

for f in "$ORCH" "$MERGE"; do [ -f "$f" ] || { echo "FATAL: $f not found"; exit 1; }; done

# ⛔ THE HOST'S OWN WORKERS MUST NOT LEAK INTO THIS SUITE'S CENSUS. `wt_table` counts worker-named
# tmux sessions with no record of their own, so on a box where the controller is RUNNING the lane
# counts would be `9 fixture + the box's live review-*/merge-*` and the ceiling assertions would
# depend on what the machine happened to be doing. `wt_bounded` `exec`s, so only a FILE can answer.
mkdir -p "$TMP/bin-tmuxnone"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "no server running on /tmp/fixture"\nexit 1\n' > "$TMP/bin-tmuxnone/tmux"
chmod +x "$TMP/bin-tmuxnone/tmux"

# ── the shipped fragments, EXTRACTED (never re-typed) ────────────────────────────────────────────
grep -E '^shq\(\) \{' "$ORCH"                                    > "$TMP/shq.sh"
grep -E '^is_num\(\) \{' "$ORCH"                                 > "$TMP/isnum.sh"
grep -E '^is_limit\(\) \{' "$ORCH"                               > "$TMP/islimit.sh"
sed -n '/^spawn_gate_tok() {/,/^}/p' "$ORCH"                     > "$TMP/spawntok.sh"
sed -n '/^spawns_since() {/,/^}/p' "$ORCH"                       > "$TMP/spawns.sh"
sed -n '/^review_gate_state() {/,/^}/p' "$ORCH"                  > "$TMP/rgs.sh"
sed -n '/^park_ctrl() {/,/^}/p' "$ORCH"                          > "$TMP/parkctrl.sh"
sed -n '/# \[reviewdisp:begin\]/,/# \[reviewdisp:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/reviewdisp.sh"
sed -n '/# \[prdisp:begin\]/,/# \[prdisp:end\]/p' "$ORCH" | sed '1d;$d'         > "$TMP/disp.sh"
sed -n '/# \[acting-case:begin\]/,/# \[acting-case:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/arm.sh"
for _x in shq isnum islimit spawntok spawns rgs parkctrl reviewdisp disp arm; do
  [ -s "$TMP/$_x.sh" ] || { echo "FATAL: the shipped block '$TMP/$_x.sh' did not extract from orch-loop.sh"; exit 1; }
done
grep -q 'review_disp_decide' "$TMP/reviewdisp.sh" || { echo "FATAL: [reviewdisp] block missing review_disp_decide"; exit 1; }
grep -q 'no acting arm for class' "$TMP/arm.sh"    || { echo "FATAL: [acting-case] block did not extract"; exit 1; }

# ⛔ THE MERGE-ONE HALF: the shared budget and the abandoned-attempt recorder are extracted from the
# PRODUCER (merge-one.sh), not copied, so a drift between the writer and the reader reddens here.
awk '/^verdict_class\(\) \{/{f=1} f{print} f&&/^\}/{exit}'              "$MERGE" > "$TMP/verdict.sh"
sed -n '/# \[revbudget:begin\]/,/# \[revbudget:end\]/p'          "$MERGE" | sed '1d;$d' > "$TMP/revbudget.sh"
awk '/^review_abandoned_record\(\) \{/{f=1} f{print} f&&/^\}/{exit}'     "$MERGE" > "$TMP/abandoned.sh"
awk '/^review_state_record\(\) \{/{f=1} f{print} f&&/^\}/{exit}'        "$MERGE" > "$TMP/revstate.sh"
grep -m1 '^is_limit() {' "$MERGE" >> "$TMP/revbudget.sh"
grep -m1 '^is_num() {'   "$MERGE" >> "$TMP/revbudget.sh"
for _x in verdict revbudget abandoned revstate; do
  [ -s "$TMP/$_x.sh" ] || { echo "FATAL: merge-one.sh's $_x block did not extract"; exit 1; }
done
grep -q 'reviewdisp-' "$TMP/revbudget.sh" || { echo "FATAL: merge-one.sh no longer keeps a (PR,head) budget keyed on reviewdisp-<PR>"; exit 1; }
grep -q 'REV_PAID' "$TMP/revbudget.sh"    || { echo "FATAL: the REV_PAID no-double-count seam is gone from merge-one.sh"; exit 1; }

# ── D1: the review arm's dispatch, driven ───────────────────────────────────────────────────────
# drive <V> [<lanes:0>] [<spawn-ok:1>] [<head:4c50922…>]
# Writes: $TMP/spy  (one line per spawn: the launcher argv + its stdin document)
#         $TMP/d.log(the controller's log)   $TMP/O/state (the state the arm writes)
PR_SICK=10213
PR_SICK_HEAD=4c50922cceaadae2a7016196fc0e80e43ba8d5bf
drive() {
  : > "$TMP/spy"; : > "$TMP/d.log"; mkdir -p "$TMP/O/state"; : > "$TMP/ledger"
  : > "$TMP/lanes"; _i=0
  while [ "$_i" -lt "${2:-0}" ]; do echo "review-$_i" >> "$TMP/lanes"; echo "merge-$_i" >> "$TMP/lanes"; _i=$((_i+1)); done
  (
    PR=$PR_SICK; BR=fix/thing; HEAD_N="${4-$PR_SICK_HEAD}"; OR=daniel-ospina/agent-infra; REPO=/nonexistent
    SPAWN_CWD="$TMP/O"; O="$TMP/O"; LOG="$TMP/d.log"
    V="$1"; MERGE_AUTHORITY=rail; AUTHORITY_UNKNOWN=0; MSTAT=CLEAN; DRAFT=false
    MF=9; MR=9; MAX_FIX_TRIES=3; MAX_REVIEW_TRIES=3
    REQ='ai-review-gate python-ci-gate pipeline-compliance'; REVIEW_GATE='ai-review-gate'
    PRDISP="$TMP/ledger"; HARNESS_TOKEN=
    HOME="$TMP/home"; mkdir -p "$HOME/.pi/agent/reviews"
    WT_DIR="$O/state"; WT_TABLE_TTL=0
    SPAWN_OK="${3:-1}"
    file_mtime_epoch() { echo $(( $(date +%s) - 7200 )); }
    . "$TMP/shq.sh"; . "$TMP/isnum.sh"; . "$TMP/islimit.sh"
    . "$TMP/disp.sh"; . "$TMP/rgs.sh"; . "$TMP/spawntok.sh"; . "$TMP/spawns.sh"
    . "$TMP/reviewdisp.sh"
    . "$TMP/parkctrl.sh"
    . "$HERE/worker-terminal.sh"
    cmux() {
      case "$1" in
        tree) python3 - "$TMP/lanes" <<'PY'
import json,sys
names=[l.strip() for l in open(sys.argv[1]) if l.strip()]
ws=[];sc=[];tb=[];tm=[]
for i,n in enumerate(names):
    ws.append({"id":"ws_%d"%i,"name":"wt-"+n})
    sc.append({"id":"s_%d"%i,"workspace_id":"ws_%d"%i,"layout":{"root":{"tab_ids":["t_%d"%i]}}})
    tb.append({"id":"t_%d"%i,"content_id":"term_%d"%i})
    tm.append({"id":"term_%d"%i,"running":True})
print(json.dumps({"workspaces":ws,"screens":sc,"tabs":tb,"terminals":tm}))
PY
              return 0 ;;
        server) return 0 ;;
        surface) return 1 ;;
        layout) { printf 'CMUX %s ' "$*"; tr -d '\n' <&0; echo; } >> "$TMP/spy"
                [ "$SPAWN_OK" = "1" ] || return 1
                printf '{"workspace_id": "ws_x", "panes": [{"surfaces": [{"terminal_id": "term_x"}]}]}\n'
                return 0 ;;
      esac
      return 0
    }
    gh() { case "$1 $2" in "pr view") case "$*" in *mergeable*) echo "$MSTAT" ;; *headRefOid*) echo "$HEAD_N" ;; *) echo "" ;; esac ;; *) : ;; esac; return 0; }
    PATH="$TMP/bin-tmuxnone:$PATH"
    # The arm asks "is a worker already on this PR?" — this suite is about the ORDER, so ownership is
    # answered by the shipped census with no records (free). pr-owner-liveness.test.sh grades the guard.
    sess() { wt_alive "${1:-}"; }
    claim_live() { return 1; }
    pr_owner_live() { return 1; }
    can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }
    ciq_push_ok() { return 0; }
    ciq_defer_note_here() { :; }
    L=0; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=9000; MEM_UNKNOWN=0
    wt_count() {  # the fixture's lanes, by prefix (the shipped module reads a live surface)
      local re="" p; for p in "$@"; do re="$re${re:+|} $p"; done
      awk 'BEGIN{n=0} {n++} END{print n+0}' "$TMP/lanes"
    }
    . "$TMP/arm.sh"
  ) >/dev/null 2>&1
}
spawn_names() { tr ' ' '\n' < "$TMP/spy" | sed -En 's/^wt-(review-[0-9]+|merge-[0-9]+)$/\1/p' | sort -u; }
spawn_count() { awk 'END{print NR+0}' "$TMP/spy" 2>/dev/null; }

echo "=== D1: a NEEDS-REVIEW head gets a REVIEW ORDER, never another merge worker (#2971) ==="
drive 'FAILED:ai-review-gate'
_names="$(spawn_names)"
if [ "$(spawn_count)" = "1" ]; then
  ok "D1(a) one NEEDS-REVIEW head with capacity => exactly ONE dispatch this pass"
else
  bad "D1(a) expected exactly 1 dispatch, got $(spawn_count) — [$_names]"
fi
if [ "$_names" = "review-$PR_SICK" ]; then
  ok "D1(b) …and it is the review ORDER: review-$PR_SICK"
else
  bad "D1(b) the dispatch was not a review order — spawned=[${_names:-none}]. The remedy NEEDS-REVIEW names is a review for (PR, head); a pass that spawns merge-$PR_SICK again is the 2026-10-28 livelock"
fi
if grep -qx "merge-$PR_SICK" <<< "$_names"; then
  bad "D1(c) a MERGE worker (merge-$PR_SICK) was spawned at a head nobody has reviewed — the refusal was acted on as if it were an order to merge"
else
  ok "D1(c) …and NO merge worker: merge-$PR_SICK is not in this pass's spawns"
fi
grep -q "#$PR_SICK review ORDER review-$PR_SICK dispatched for (PR=$PR_SICK, head=$PR_SICK_HEAD)" "$TMP/d.log" \
  && ok "D1(d) the log NAMES the review order with the (PR, head) it was ordered for" \
  || bad "D1(d) the pass did not name the review order it dispatched — log=$(tr '\n' ';' < "$TMP/d.log")"
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK" 2>/dev/null)" = "$PR_SICK_HEAD 1" ] \
  && ok "D1(e) the dispatch is RECORDED on the (PR, head) key the merge arm reads: \"<head> 1\"" \
  || bad "D1(e) the shared (PR,head) record was not written: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK" 2>/dev/null)]"
# ⛔ THE SPAWN CARRIES THE BUDGET-SHARING SEAM. Without it merge-one.sh would spend the attempt a second
# time (halving a budget already measured as tight), so this is asserted on the worker's OWN RUN FILE —
# the file the launcher actually executes — and not on a comment or on the tmux/cmux argv.
grep -q 'REV_PAID=1' "$TMP/O/state/run-review-$PR_SICK.sh" 2>/dev/null \
  && ok "D1(f) the spawn carries REV_PAID=1 — the attempt is counted ONCE across the two arms" \
  || bad "D1(f) the review order does not tell merge-one.sh that this attempt is already spent — the shared budget would double-count (run file: [$(tail -1 "$TMP/O/state/run-review-$PR_SICK.sh" 2>/dev/null | cut -c1-120)])"
# The second pass at the SAME head must not buy an unbounded run of paid reviews: it spends attempt 2.
drive 'FAILED:ai-review-gate'
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK" 2>/dev/null)" = "$PR_SICK_HEAD 2" ] \
  && ok "D1(g) a second dispatch at the SAME head spends attempt 2 — the order is bounded per (PR, head)" \
  || bad "D1(g) the second dispatch did not spend the second attempt: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK" 2>/dev/null)]"

echo
echo "=== D2: ONE (PR, head) budget, and a silent reviewer exit is a COUNTED failure (#2971) ==="
# _merge <spend-args…> — drive merge-one.sh's own record/recorder against the SAME state dir the
# controller wrote, exactly as the two scripts share it in production.
_rv() {  # <fn> [args…]  — with HEAD/PR/O/MAX_REVIEW_TRIES as the controller left them
  local fn="$1"; shift
  ( O="$TMP/O"; PR="$PR_SICK"; HEAD="${HEAD_OVERRIDE:-$PR_SICK_HEAD}"; L="$TMP/O/logs/merge-$PR_SICK"
    MAX_REVIEW_TRIES=3; REV_PAID="${REV_PAID:-0}"; REV_STARTED="${REV_STARTED:-0}"; REV_RECORDED="${REV_RECORDED:-0}"
    LAST="${LAST_OVERRIDE:-}"
    mkdir -p "$TMP/O/logs"
    park() { printf '%s\n' "$*" > "$TMP/O/state/parkreason-$PR_SICK"; printf '%s\n' "$HEAD" > "$TMP/O/state/parked-$PR_SICK"; }
    . "$TMP/verdict.sh"; . "$TMP/revbudget.sh"; . "$TMP/abandoned.sh"; . "$TMP/revstate.sh"
    "$fn" "$@" )
}
# Start from the state D1 left: reviewdisp = "<head> 2" after two controller dispatches.
printf '%s 2\n' "$PR_SICK_HEAD" > "$TMP/O/state/reviewdisp-$PR_SICK"
rm -f "$TMP/O/state/parked-$PR_SICK" "$TMP/O/state/parkreason-$PR_SICK" "$TMP/O/state/needsreview-$PR_SICK-"*
# D2(a) NO DOUBLE COUNT: a controller-dispatched run (REV_PAID=1) does not spend the attempt twice.
REV_PAID=1 _rv review_state_record NO-VERDICT
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK")" = "$PR_SICK_HEAD 2" ] \
  && ok "D2(a) a dispatcher-paid verdict-less run does NOT spend the attempt again (still \"<head> 2\")" \
  || bad "D2(a) the shared budget double-counted one dispatch: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK")] — a budget already measured as tight would be halved"
[ -f "$TMP/O/state/needsreview-$PR_SICK-$PR_SICK_HEAD" ] \
  && ok "D2(b) …and it still leaves the NEEDS-REVIEW marker the controller reads (the diagnosis is not lost)" \
  || bad "D2(b) a verdict-less run left no needsreview marker — the controller would read the head as unreviewed by ABSENCE"
# D2(c) the CHAIN/fix path has nobody counting above it, so it spends the shared budget itself.
rm -f "$TMP/O/state/needsreview-$PR_SICK-"* "$TMP/O/state/parked-$PR_SICK"
REV_PAID=0 _rv review_state_record NO-VERDICT
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK")" = "$PR_SICK_HEAD 3" ] \
  && ok "D2(c) an UNDISPATCHED verdict-less run (chain-/fix-one) spends the shared budget itself: \"<head> 3\"" \
  || bad "D2(c) an undispatched run spent nothing: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK")] — that arm would buy paid reviews with no bound"
[ "$(cat "$TMP/O/state/parked-$PR_SICK" 2>/dev/null)" = "$PR_SICK_HEAD" ] \
  && ok "D2(d) at the cap it PARKS the head, naming the exhausted limit (never a silent stop)" \
  || bad "D2(d) the cap did not park the head (parked=[$(cat "$TMP/O/state/parked-$PR_SICK" 2>/dev/null)])"
grep -q 'NO usable verdict' "$TMP/O/state/parkreason-$PR_SICK" 2>/dev/null \
  && ok "D2(e) …and the park reason says WHAT was missing (the reviewer produced no usable verdict)" \
  || bad "D2(e) the park reason does not name the cause: [$(cat "$TMP/O/state/parkreason-$PR_SICK" 2>/dev/null)]"
# D2(f) ⛔ THE SILENCE (requirement 3). A reviewer that exits WITHOUT a CLEAN/ISSUES marker used to
# leave nothing at all — merge-10213's log simply stopped at 23:30. The EXIT recorder must count it.
printf '%s 1\n' "$PR_SICK_HEAD" > "$TMP/O/state/reviewdisp-$PR_SICK"
rm -f "$TMP/O/state/parked-$PR_SICK" "$TMP/O/state/parkreason-$PR_SICK" "$TMP/O/state/needsreview-$PR_SICK-"*
REV_STARTED=1 REV_RECORDED=0 LAST_OVERRIDE= _rv review_abandoned_record
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK")" = "$PR_SICK_HEAD 2" ] \
  && ok "D2(f) a reviewer run that ends with NO marker is a COUNTED failed attempt (the budget moved 1 => 2)" \
  || bad "D2(f) a markerless reviewer exit counted NOTHING: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK")] — the 2026-10-28 silence"
grep -q 'ENDED WITHOUT a CLEAN/ISSUES marker' "$TMP/O/logs/merge-$PR_SICK.log" \
  && ok "D2(g) …and its REASON is in the log (exit rc + the last line), not an unexplained stop" \
  || bad "D2(g) the abandoned attempt left no reason: log=[$(tail -2 "$TMP/O/logs/merge-$PR_SICK.log" 2>/dev/null | tr '\n' ';')]"
# D2(h) the recorder is INERT when the run did produce a verdict: a CLEAN that failed to RECORD is a
# different failure, and writing "no verdict" over it would put a falsehood in the reason a human reads.
printf '%s 1\n' "$PR_SICK_HEAD" > "$TMP/O/state/reviewdisp-$PR_SICK"
rm -f "$TMP/O/state/needsreview-$PR_SICK-"*
REV_STARTED=1 REV_RECORDED=0 LAST_OVERRIDE='CLEAN https://github.com/o/r/pull/10213#issuecomment-7' _rv review_abandoned_record
if [ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK")" = "$PR_SICK_HEAD 1" ] && [ ! -f "$TMP/O/state/needsreview-$PR_SICK-$PR_SICK_HEAD" ]; then
  ok "D2(h) a run that DID emit CLEAN is not recorded as verdict-less (the recorder is not a blanket)"
else
  bad "D2(h) the recorder treated a CLEAN run as verdict-less: budget=[$(cat "$TMP/O/state/reviewdisp-$PR_SICK")] marker=$( [ -f "$TMP/O/state/needsreview-$PR_SICK-$PR_SICK_HEAD" ] && echo yes || echo no)"
fi
# D2(i) a TERMINAL record (REV_RECORDED=1) makes the recorder inert — the verdict arm already spoke.
printf '%s 1\n' "$PR_SICK_HEAD" > "$TMP/O/state/reviewdisp-$PR_SICK"
REV_STARTED=1 REV_RECORDED=1 _rv review_abandoned_record
[ "$(cat "$TMP/O/state/reviewdisp-$PR_SICK")" = "$PR_SICK_HEAD 1" ] \
  && ok "D2(i) a run whose terminal record was already written is not counted twice at exit" \
  || bad "D2(i) the EXIT recorder double-counted an already-recorded run: [$(cat "$TMP/O/state/reviewdisp-$PR_SICK")]"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ==============="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
