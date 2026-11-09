#!/bin/bash
# pr-dispatch.test.sh — agent-infra#2126: the PR path must be HONEST and COMPLETE.
#
# ⛔ WHAT THIS SUITE IS FOR. The defect: an un-owned PR held the issue path shut while the sweep
# spawned nothing and said nothing, and the funnel printed "dispatching PR-takeover" anyway. A test
# that greps the log for a sentence cannot see that — it passes on the sentence and on its absence
# alike. So every assertion here is BEHAVIOURAL: the shipped fragments are EXTRACTED and DRIVEN
# against stub `gh`/`tmux`, and the assertions are on (a) what actually ran, and (b) whether the
# printed claim matches it. Nothing here greps orch-loop.sh for prose.
#
# The five classes (declared at scoping, agent-infra#2126):
#   T1 a printed claim of work with no spawn behind it (and a spawn that failed unremarked)
#   T2 a PR counted into UPN (so the issue path stays shut) that appears in no disposition
#   T4 a buildable class that falls through the acting case with no arm and no line
#   T5 a capacity refusal that prints nothing (lanes=0 with no reason)
#   T6 the ledger being wired into the GATE (it is a record, never an input)
# T3 (double act: a fixer AND a `gh run rerun` in one cycle) is a PRECEDENCE decision, not a
# honesty repair — it is DISCLOSED here as a residual rather than silently "fixed" (see the last
# section: the double act is asserted to be NAMED, not removed).
#
# Hermetic: no network, no tmux, no gh. Run: bash pr-dispatch.test.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$HERE/orch-loop.sh"
# ⛔ THE CAP'S RANGE IS DECLARED AND ENFORCED HERE, BEFORE ANY ARM PRINTS (fresh review of #3441, P2).
# The ceiling arms seed `$CAP - 1` and `$CAP - 2` to stand one and two rounds BELOW the ceiling, so a
# cap under 2 makes those seeds 0 / negative — `review_round_read` coerces a negative to 0 and the arms
# then assert a state they never created. Measured before this guard: `DRIVE_MAX_REVIEW=1` reds 1 arm
# and `=0` reds 15, which reads as a product REGRESSION when it is the SUITE being driven outside the
# range its arms are written for — exactly how a real red gets ignored later. Both values are accepted
# by `install.sh`, so the refusal names each one instead of letting them red silently.
# ⚠️ `0` is REPORT-ONLY: nothing is dispatched at all, and `(c4e)` drives that mode deliberately on its
# own. It cannot be the mode the whole suite runs in, because every other dispatch arm would
# (correctly) see zero reviews and red — the product behaving as documented, not a defect.
DRIVE_MAX_REVIEW="${DRIVE_MAX_REVIEW:-10}"
case "$DRIVE_MAX_REVIEW" in ''|*[!0-9]*)
  echo "❌ DRIVE_MAX_REVIEW='$DRIVE_MAX_REVIEW' is not a number — this suite drives a per-PR round ceiling" >&2; exit 2 ;;
  0[0-9]*)
  # ⛔ A LEADING ZERO IS AN OCTAL-LOOKING VALUE, AND `[ "08" -lt 2 ]` ERRORS (round 8 review, P3). The
  # error makes the range test read FALSE, so the guard passes and `$(( CAP - 1 ))` then aborts — the
  # very "misleading red" this guard exists to prevent. `is_num`/`is_limit` doctrine: reject the shape.
  echo "❌ DRIVE_MAX_REVIEW='$DRIVE_MAX_REVIEW' has a leading zero — write it in base 10 (e.g. ${DRIVE_MAX_REVIEW#0}), not as an octal-looking value" >&2; exit 2 ;;
esac
if [ "$DRIVE_MAX_REVIEW" -lt 2 ]; then
  echo "❌ DRIVE_MAX_REVIEW=$DRIVE_MAX_REVIEW is OUTSIDE this suite's declared range (>= 2)." >&2
  echo "   The ceiling arms seed CAP-1 and CAP-2 to stand one and two rounds below the ceiling; below 2" >&2
  echo "   those seeds are 0/negative, are coerced to 0, and the arms assert rounds they never created." >&2
  echo "   ⚠️ MAX_REVIEW=0 is REPORT-ONLY and IS covered — by (c4e), which drives it explicitly on its own." >&2
  exit 2
fi
export DRIVE_MAX_REVIEW
CAP="$DRIVE_MAX_REVIEW"
# ⛔ A PER-RUN directory: a fixed path is shared by two concurrent lanes on one box, and one run's
# truncation would wipe the other's rows mid-flight (a flaky red, and — worse — `acts()` could read the
# OTHER run's act row and PASS the exact assertion this suite exists for).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
# ⛔ THE ONE COMMENT-STRIP THE TEXT ARMS SHARE (round-16 review, P3). `!/^[ \t]*#/` drops whole-line
# comments only, so an INLINE `#` survived and two measured decoys passed GREEN at 191/0:
#   `: # review_round_clear "$PR"` (a call defanged behind a colon), and
#   `rm -f … || true   # was: "$O/state/reviewround-$PR"` (the path alive only in a trailing comment).
# A text arm a comment can satisfy is worse than no arm: it reports coverage it does not have.
c4mc() { sed 's/[[:space:]]#.*$//' ; }   # drop anything from an inline `#` to EOL
clear_workers() {
  local f
  for f in "$TMP/O/state"/worker-* "$TMP/O/state/.wt-census"; do
    [ -e "$f" ] && mv "$f" "$TMP/worker.spent.$RANDOM" 2>/dev/null
  done
  return 0
}


[ -f "$ORCH" ] || { echo "FATAL: $ORCH not found"; exit 1; }
# ⛔ THE HOST'S OWN TMUX MUST NOT LEAK INTO THIS SUITE'S CENSUS (agent-infra#2653 review round 12).
# `wt_table` counts worker-named tmux sessions with no record of their own; on a box where the
# controller is RUNNING those are real, so the lane-count assertions read `10/9` or `12/9` depending on
# what the machine was doing. ⛔ A SHELL FUNCTION IS NOT ENOUGH — the census invokes tmux through
# `wt_bounded` (`perl -e 'alarm shift; exec @ARGV'`), i.e. `exec`, which can only find a FILE. So this
# is a file stub answering the EMPTY polarity (`no server running` => no tmux session can exist).
mkdir -p "$TMP/bin-tmuxnone"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "no server running on /tmp/fixture"\nexit 1\n' > "$TMP/bin-tmuxnone/tmux"
chmod +x "$TMP/bin-tmuxnone/tmux"

# ── the shipped quoter (the spawn lines call `shq`) ───────────────────────────────────────────────
grep -E '^shq\(\) \{' "$ORCH" > "$TMP/shq.sh"
# `is_num` is the shipped digit validator (it refuses a leading zero, which `[ -gt ]` reads as decimal):
# the summariser's tallies pass through it, so the fixture must use the SHIPPED one, not a stub.
grep -E '^is_num\(\) \{' "$ORCH" > "$TMP/isnum.sh"
# ⛔ THE REFUSAL LINES' EVIDENCE TOKEN IS EXTRACTED TOO (agent-infra#1732 review). Four of the five
# held-back-spawn lines print `$(spawn_gate_tok)`, which is DEFINED OUTSIDE both extracted blocks, so
# without this a drive renders `… NO merge slot (merge lanes=9/9, )` — an empty field where the gate's
# reading belongs — and, because the drives discard stderr, it does so SILENTLY while the T5 assertion
# ("a capacity refusal NAMES itself") stays green on the prefix alone. Same defect the red-fixer drive
# had, in the suite that drives the other four lines.
sed -n '/^spawn_gate_tok() {/,/^}/p' "$ORCH" > "$TMP/spawntok.sh"
# ⛔ THE SPAWN-EVIDENCE READER IS EXTRACTED TOO (agent-infra#2590). The `[spawn]` line inside the
# [prsum] block calls `spawns_since`, which is DEFINED OUTSIDE it — an undefined command there yields
# an empty count, which reads as UNMEASURED and would leave every assertion below green while the
# shipped reader was broken. Same class as the `spawn_gate_tok` extraction above.
sed -n '/^spawns_since() {/,/^}/p' "$ORCH" > "$TMP/spawns.sh"
[ -s "$TMP/shq.sh" ] || { echo "FATAL: shq() not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/isnum.sh" ] || { echo "FATAL: is_num() not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/spawns.sh" ] || { echo "FATAL: spawns_since() not found in orch-loop.sh"; exit 1; }
# ⛔ THE REVIEW-GATE ARM'S OWN CLASSIFIER, EXTRACTED AND NOT STUBBED (#2333 review, P2). Since
# agent-infra#2132 the arm decides NEEDS-FIX vs NEEDS-REVIEW through `review_gate_state()`, which
# reads the findings marker. A driver that stubbed it would grade its own copy and could never reach
# the arm's DEFER branch (the deferral is only for a head WITH findings); an UNDEFINED command here
# would return empty -> NEEDS-REVIEW -> the re-record path, i.e. the drive would silently prove
# nothing about the defer arm it exists for. So the shipped polarity is sourced.
sed -n '/^review_gate_state() {/,/^}/p' "$ORCH" > "$TMP/rgs.sh"
[ -s "$TMP/rgs.sh" ] && grep -q 'NEEDS-FIX' "$TMP/rgs.sh" \
  || { echo "FATAL: review_gate_state() not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/spawntok.sh" ] || { echo "FATAL: spawn_gate_tok() not found in orch-loop.sh"; exit 1; }
# ⛔ THE REVIEW-DISPATCH KEY, EXTRACTED AND NOT STUBBED (agent-infra#2653). The review arm now decides
# through `review_disp_decide`/`review_disp_record`/`review_lane_holders` before it looks at capacity,
# and those live OUTSIDE the [acting-case] block — so an undefinected command here would make `_rvd`
# EMPTY, no branch match, and every drive would silently fall through to the capacity arm while the
# assertions below stayed green on the wrong path. That is the same `! 127` polarity trap this suite
# documents for `ciq_push_ok` and `is_num`. A block that does not extract aborts the section.
sed -n '/# \[reviewdisp:begin\]/,/# \[reviewdisp:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/reviewdisp.sh"
[ -s "$TMP/reviewdisp.sh" ] && grep -q 'review_disp_decide' "$TMP/reviewdisp.sh" \
  || { echo "FATAL: the [reviewdisp] block is missing from orch-loop.sh — the review key is untested"; exit 1; }
# ── extraction 1d: the PER-PR REVIEW-ROUND budget (agent-infra#3441) ────────────────────────────
# Its own block because it answers a DIFFERENT question from [reviewdisp]: rounds spent on the PR
# (cumulative, a push does NOT re-arm it) vs attempts at ONE head (a push does). A suite that graded
# only one of them would leave the other free to be inert.
sed -n '/# \[reviewround:begin\]/,/# \[reviewround:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/reviewround.sh"
[ -s "$TMP/reviewround.sh" ] && grep -q 'review_round_exhausted' "$TMP/reviewround.sh" \
  && grep -q 'review_ceiling_line' "$TMP/reviewround.sh" \
  || { echo "FATAL: the [reviewround] block is missing from orch-loop.sh — the per-PR round ceiling is untested"; exit 1; }
# ⛔ `is_limit` IS THE KEY'S VALIDATOR AND IS DEFINED OUTSIDE THE BLOCK. Undefined it is
# `command not found` (127), so `is_limit "$n" || n=0` coerces EVERY count to 0 and the cap can never
# bind — the drive would prove an unbounded budget while its own assertions expected one. Extracted,
# not stubbed, for the same reason as `review_gate_state` above.
# ⛔ `is_limit` IS A ONE-LINER — extract that LINE, not a `/^}/`-terminated block: the block form runs
# from the definition to the next `}` in the file, which is ~150 lines of the controller's top-level
# startup code. Sourced into the drive subshell that code aborted every drive (measured: the whole
# suite went 22 red with empty logs), and it would have LOOKED like a code defect in the arm.
grep -E '^is_limit\(\) \{' "$ORCH" > "$TMP/islimit.sh"
[ -s "$TMP/islimit.sh" ] && grep -q 'is_num' "$TMP/islimit.sh" \
  || { echo "FATAL: is_limit() not found in orch-loop.sh"; exit 1; }
# The drain rule the review budget feeds: `mp_reason <unowned> <lanes> <workers> [<open>]` prints the
# hold-down reason, or NOTHING when no PR is un-owned (the only state that opens the issue path).
sed -n '/^mp_reason() {/,/^}/p' "$ORCH" > "$TMP/mpreason.sh"
# ⛔ THE SHIPPED `park_ctrl`, NOT A STUB (review of #2664, P2). A `park_ctrl() { return 0; }` stub made
# every "…PARKED" claim in T7 unverified: the log line is emitted BEFORE the park, so dropping the park
# from either branch left the arm green while the PR re-entered it every cycle for ever — the exact
# endless-wait shape the reviewathead bound exists to end, and the one thing that stops re-entry is the
# `parked-<PR>` file this function writes.
sed -n '/^park_ctrl() {/,/^}/p' "$ORCH" > "$TMP/parkctrl.sh"
[ -s "$TMP/parkctrl.sh" ] && grep -q 'parkreason-' "$TMP/parkctrl.sh" \
  || { echo "FATAL: park_ctrl() not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/mpreason.sh" ] && grep -q 'merge-priority' "$TMP/mpreason.sh" \
  || { echo "FATAL: mp_reason() not found in orch-loop.sh"; exit 1; }

# ⛔ NO SYNTAX CHECK OF A TEMP FILE HERE, AND NO REMOVAL OF ONE (#709). Both forms are read by the
# main-worktree-guard as an unverifiable script operand or discard target, and it then refuses to run
# this whole file — in-tree, from a copy, executable or not — for every unhatched session. A syntax
# check whose own object is a temp file is not worth a suite no lane can run. A non-empty block plus a
# shipped ANCHOR proves it was extracted, and a block that does not source cleanly still aborts the
# drive below, where the assertions fail loudly instead.

# ── extraction 1: the disposition helper ─────────────────────────────────────────────────────────
sed -n '/# \[prdisp:begin\]/,/# \[prdisp:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/disp.sh"
[ -s "$TMP/disp.sh" ] && grep -q 'dispreplace()' "$TMP/disp.sh" \
  && ok "the disposition helper is extracted from the shipped loop" \
  || { bad "the [prdisp] block is missing or does not parse — the whole ledger is gone"; }

# ── extraction 1b: the CONFLICTING router (its own `case`, BEFORE the acting one) ────────────────
sed -n '/# \[conflict-case:begin\]/,/# \[conflict-case:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/conflict.sh"
[ -s "$TMP/conflict.sh" ] && grep -q 'CONFLICTING' "$TMP/conflict.sh" \
  && ok "the CONFLICTING router is extracted from the shipped loop" \
  || bad "the [conflict-case] block is missing or does not parse — the conflicted-first path is untested"

# ── extraction 2: the acting case ────────────────────────────────────────────────────────────────
sed -n '/# \[acting-case:begin\]/,/# \[acting-case:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/arm.sh"
if [ -s "$TMP/arm.sh" ] && grep -q "no acting arm for class" "$TMP/arm.sh"; then
  ok "the acting case is extracted and parses (237 shipped lines)"
else
  bad "the [acting-case] block is missing or does not parse — the drive below would grade nothing"
fi

# ── the driver: run the shipped case for ONE PR under stubs ──────────────────────────────────────
# drive <V> <merge-authority> [<lanes-in-use:0>] [<spawn-ok:1>] [<authority-unknown:0>] [<mergeable:CLEAN>]
#       [<max-review-tries:3>] [<head:abc1234> — pass "" for an UNREADABLE head]
# `lanes-in-use` is how many fake WORKERS the surface reports, so the arm's own
# `wt_count fix-` / `wt_count merge-` ceiling test is exercised for real. `MF`/`MR` stay at 9.
# The surface is a fake `cmux` (worker-terminal.sh's durable terminal): this suite drives the launcher's
# durable-terminal arm, the surface that answers first wherever a daemon is reachable. (The `~21 log
# lines` death agent-infra#2210 blamed on tmux was the missing HOME+keys.env environment, not tmux —
# the tmux arm is exercised by worker-terminal.test.sh §C/§D.) `$TMP/lanes` names the workers; `cmux tree` renders them as the workspaces the
# shipped census reads.
# Writes:  $TMP/d.tsv (the ledger the shipped disp() produced)   $TMP/spy (spawn argv)
#          $TMP/gspy (gh argv)                                    $TMP/d.log (the log lines)
drive() {
  : > "$TMP/spy"; : > "$TMP/gspy"; : > "$TMP/d.log"; mkdir -p "$TMP/O/state"; : > "$LEDGER"  # `lanes-in-use` fake rows: half fix-, half merge-, so BOTH ceilings are reachable from one knob.
  : > "$TMP/lanes"; _i=0
  while [ "$_i" -lt "${3:-0}" ]; do echo "fix-$_i" >> "$TMP/lanes"; echo "merge-$_i" >> "$TMP/lanes"; _i=$((_i+1)); done
  (
    PR=4242; BR=fix/thing; HEAD_N=abc1234; OR=daniel-ospina/agent-infra; REPO=/nonexistent
    SPAWN_CWD="$TMP/O"   # the loop sets it at startup; the driver supplies what the loop supplies
    O="$TMP/O"; mkdir -p "$O/state"
    LOG="$TMP/d.log"
    V="$1"; MERGE_AUTHORITY="$2"; AUTHORITY_UNKNOWN="${5:-0}"; MSTAT="${6:-CLEAN}"
    # INSIDE the subshell: `$O` is set here, so a marker written in the function body would land in
    # `/state/…` and the review-gate fixer arm would silently take the re-record path instead.
    [ "${NEEDSFIX:-0}" = "1" ] && : > "$O/state/needsfix-$PR-abc1234"
    MF=9; MR=9; MAX_FIX_TRIES=3; MAX_REVIEW_TRIES=3; REQ='ai-review-gate python-ci-gate pipeline-compliance'
    # ⛔ MAX_REVIEW IS PINNED HERE, NOT INHERITED (#3441, fresh review P2). `install.sh` renders it into the
    # launchd plist, so every child of a live controller inherits it — the live box is configured for 12,
    # and a box pinned at 4 makes the ceiling arms below read 10 against a 4 budget. A suite that grades a
    # limit must set it. `[9]`-style driving is unnecessary: the arms seed the COUNTER, not the cap.
    MAX_REVIEW="${DRIVE_MAX_REVIEW:-10}"
    REVIEW_GATE='ai-review-gate'; DRAFT=false
    # shellcheck disable=SC1090
    . "$TMP/shq.sh"
    # shellcheck disable=SC1090
    . "$TMP/disp.sh"
    # shellcheck disable=SC1090
    . "$TMP/rgs.sh"
    # The worker census the arm compares against `$MF`/`$MR` comes from the LAUNCHER now, so the
    # stub is the SURFACE: `cmux tree --json` renders `$TMP/lanes` (written per drive, so the same
    # stub serves an idle box and a saturated one) as `wt-<worker>` workspaces with a live terminal.
    SPAWN_OK="${4:-1}"
    # ⛔ THE ARM'S OWN INPUTS ARE POSITIONAL ON PURPOSE, so a drive can move them (review of #2653):
    # `[6]` is `MAX_REVIEW_TRIES` (default 3) — the CAP drive must be able to LOWER it, because with
    # `n == max` the `CAP <n> <max>` parse bug is invisible and the number the "never a silent stop"
    # line prints is untested. `[7]` is the head (`HEAD_N`), empty means an unreadable head.
    MAX_REVIEW_TRIES="${7:-3}"; HEAD_N="${8-abc1234}"
    WT_DIR="$O/state"; WT_TABLE_TTL=0
    # ⛔ THE RECORD STORE IS READ BY THE SHIPPED KEY (agent-infra#2653/#2517), so the fixture needs a
    # HOME the arm can find it in. It is the SAME path `record-review.sh` writes; a drive that left it
    # at the real `$HOME` would read the developer's own review history and grade nothing.
    HOME="$TMP/home"; mkdir -p "$HOME/.pi/agent/reviews"
    # The holders line computes a log age; give the portable probe a deterministic answer (2h).
    file_mtime_epoch() { echo $(( $(date +%s) - 7200 )); }
    # shellcheck disable=SC1090
    . "$TMP/islimit.sh"
    # shellcheck disable=SC1090
    . "$TMP/reviewdisp.sh"
    # shellcheck disable=SC1090
    . "$TMP/reviewround.sh"
    # shellcheck disable=SC1090
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
        # ⛔ NO trailing `return 0`: that made every spawn SUCCEED and turned this suite's
        # "a failed spawn must be recorded as a wait" case into a tautology.
        # The guest CLI has NO `surface` scope (measured: `cmux: unknown resource scope "surface"`),
        # so the stub refuses it exactly as the cell does and the layout grammar is the one driven.
        surface) return 1 ;;
        layout) { printf 'CMUX %s ' "$*"; tr -d '\n' <&0; echo; } >> "$TMP/spy"   # argv + STDIN (the document)
                [ "$SPAWN_OK" = "1" ] || return 1
                printf '{"workspace_id": "ws_x", "panes": [{"surfaces": [{"terminal_id": "term_x"}]}]}\n'
                return 0 ;;
      esac
      return 0
    }
    gh() {
      echo "GH $*" >> "$TMP/gspy"
      case "$1 $2" in
        "pr view")
          case "$*" in
            *mergeable*) echo "$MSTAT" ;;
            *headRefOid*) echo abc1234 ;;
            *state*) echo OPEN ;;
            *) echo "" ;;
          esac ;;
        "pr checks")
          # ⛔ THE RERUN BLOCK'S OWN INPUT. A stub answering `*) return 0` here prints nothing, so the
          # rerun never fires and the double-act path cannot be driven at all — which is exactly how
          # a second ledger row for one PR shipped unremarked.
          if [ "${PYCI:-0}" = "1" ]; then
            printf '[{"name":"python-ci-gate","link":"https://github.com/o/r/actions/runs/98765/job/1"}]\n'
          else
            printf '[]\n'
          fi
          return 0 ;;
        "pr ready") return 0 ;;
        "pr merge") return 0 ;;
        "run rerun") return 0 ;;
        *) return 0 ;;
      esac
    }
    # ⛔ NEUTRALISE THE HOST'S OWN TMUX (measured, agent-infra#2653 round 11): `wt_table` counts
    # worker-named tmux sessions that have no record of their own, so on a box where the controller is
    # RUNNING this suite's census was `9 fixture lanes + the box's live merge-*/fix-* sessions` — the
    # lane-count assertions then read 12/9 and depended on what the machine happened to be doing. A
    # stub that answers nothing makes the tmux arm UNKNOWN, which invents no rows.
    PATH="$TMP/bin-tmuxnone:$PATH"
    # ⛔ `OWN_LIVE=1` IS THE SEAM THE ARM-LEVEL OWNERSHIP PAIR DRIVES (#2831 (c)). It answers the one
    # question the fixture owns — "does the census see a worker for this PR?" — through `sess`, which is
    # inert everywhere else (`return 1`) so no other drive changes meaning.
    sess() { [ "${OWN_LIVE:-0}" = "1" ] && return 0; return 1; }
    claim_live() { return 1; }
    # The SHIPPED `pr_owner_live` (extracted above), not a re-implementation — see the note at the
    # extraction. `PL_MOD=0` keeps it on the documented pre-module path, so this drive never reaps a
    # lock; the module's own verdict is graded by pr-owner-liveness.test.sh against real lock files.
    PL_MOD=0
    # shellcheck source=/dev/null
    . "$TMP/owner-live.sh"
    can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }
    # ⛔ THE SHIPPED park_ctrl (review of #2664, P2) — a stub makes every "PARKED" assertion a claim
    # about a log line that is written BEFORE the park.
    # shellcheck disable=SC1090
    . "$TMP/parkctrl.sh"
    # ⛔ THE CI-QUEUE PREDICATE IS STUBBED LIKE EVERY OTHER NEIGHBOUR (#2333 review cycle 2, P1).
    # It is not decoration: `orch-loop.sh` now calls `ciq_push_ok` in both fixer arms, and an
    # UNDEFINED command returns 127 — `! 127` is TRUE, so every arm here would take the DEFERRAL path
    # and the driver could never reach a spawn it is supposed to prove. That is the same `! 127`
    # polarity trap the loop's own top-level definition carries a ⛔ comment about, reproduced one
    # layer down. ⛔ AND IT RECORDS THAT IT RAN (#2927): the three FIXER arms must no longer consult
    # it at all, and a stub that refuses silently would make "not called" and "called and ignored"
    # indistinguishable. `CIQ_PUSH_RC=1` is how an arm asks for the refused world.
    ciq_push_ok() { printf 'CALLED\n' >> "$TMP/ciqspy"; return "${CIQ_PUSH_RC:-0}"; }
    ciq_defer_note_here() { printf '[ci-queue] DEFERRED %s\n' "${1:-work}"; }
    # The refusal line prints `$(spawn_gate_tok)`; give it the shipped function and real inputs so the
    # driven line carries a reading instead of an empty field (see the extraction above).
    . "$TMP/spawntok.sh"
    L=0; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=9000; MEM_UNKNOWN=0
    # ⛔ AND `is_num`, WHICH THE BLOCKS CALL TOO (review of #1732; pre-existing, latent, same class).
    # `arm.sh`'s cap guards do `is_num "$NF" || NF=0`: with the predicate UNDEFINED that is
    # `command not found` (discarded with stderr), so a drive that seeds `fixcount-<PR>` reads 0 and
    # silently grades the UNCAPPED path — the cap assertions would pass against a cap that never
    # bound. No drive seeds one today, which is why this was invisible rather than red.
    . "$TMP/isnum.sh"
    # shellcheck disable=SC1090
    . "$TMP/arm.sh"
  ) >/dev/null 2>&1
}
# ⛔ ONE NUMBER OUT. `grep -c` prints 0 AND returns 1 on no-match, so `|| echo 0` produced "0\n0"
# and every numeric comparison below died on an "integer expression expected" that bash reports as a
# FAILING test — a fixture bug that would have read as a code defect.
spawns() { awk 'END{print NR+0}' "$TMP/spy" 2>/dev/null; }
# drive_conflict <lanes-in-use:0> [<spawn-ok:1>] — the CONFLICTING arm runs inside a one-iteration
# `for`, because the shipped block ends in `continue` (which is a syntax error at file scope, and a
# `break` after it makes "took the conflict path" vs "fell through" observable: the fall-through
# spawns nothing at all).
drive_conflict() {
  : > "$TMP/spy"; : > "$TMP/gspy"; : > "$TMP/d.log"; mkdir -p "$TMP/O/state"
  : > "$TMP/lanes"; _i=0
  while [ "$_i" -lt "${1:-0}" ]; do echo "fix-$_i" >> "$TMP/lanes"; echo "merge-$_i" >> "$TMP/lanes"; _i=$((_i+1)); done
  (
    PR=4242; BR=fix/thing; HEAD_N=abc1234; OR=daniel-ospina/agent-infra; REPO=/nonexistent
    SPAWN_CWD="$TMP/O"   # the loop sets it at startup; the driver supplies what the loop supplies
    O="$TMP/O"; LOG="$TMP/d.log"; V=PENDING:docs; MERGE_AUTHORITY=rail; AUTHORITY_UNKNOWN=0
    MF=9; MR=9; MAX_FIX_TRIES=3; REQ='ai-review-gate'; REVIEW_GATE='ai-review-gate'; DRAFT=false
    MSTAT=CONFLICTING; SPAWN_OK="${2:-1}"
    WT_DIR="$O/state"; WT_TABLE_TTL=0
    # shellcheck disable=SC1090
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
        # ⛔ NO trailing `return 0`: that made every spawn SUCCEED and turned this suite's
        # "a failed spawn must be recorded as a wait" case into a tautology.
        # The guest CLI has NO `surface` scope (measured: `cmux: unknown resource scope "surface"`),
        # so the stub refuses it exactly as the cell does and the layout grammar is the one driven.
        surface) return 1 ;;
        layout) { printf 'CMUX %s ' "$*"; tr -d '\n' <&0; echo; } >> "$TMP/spy"   # argv + STDIN (the document)
                [ "$SPAWN_OK" = "1" ] || return 1
                printf '{"workspace_id": "ws_x", "panes": [{"surfaces": [{"terminal_id": "term_x"}]}]}\n'
                return 0 ;;
      esac
      return 0
    }
    # the mergeability probe IS the routing decision, so the stub must answer it (a stub that prints
    # nothing makes the arm read MSTAT="" and fall through — silently grading the wrong path).
    gh() { echo "GH $*" >> "$TMP/gspy"; case "$*" in *mergeable*) echo CONFLICTING ;; esac; return 0; }
    PATH="$TMP/bin-tmuxnone:$PATH"   # see the file stub at the top: the host's live sessions must not leak
    sess() { return 1; }; claim_live() { return 1; }; can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }; park_ctrl() { return 0; }
    # …and the CI-queue predicate for the same reason as `drive()` above: the CONFLICTING arm now
    # calls `ciq_push_ok`, and an undefined command is `! 127` = TRUE = DEFER, which would make this
    # rig unable to prove the conflict path ever dispatches. It records its calls for the same reason
    # as `drive()` above (#2927): the conflict arm must not consult it any more.
    ciq_push_ok() { printf 'CALLED\n' >> "$TMP/ciqspy"; return "${CIQ_PUSH_RC:-0}"; }
    ciq_defer_note_here() { printf '[ci-queue] DEFERRED %s\n' "${1:-work}"; }
    . "$TMP/shq.sh"
    . "$TMP/spawntok.sh"
    . "$TMP/isnum.sh"        # the blocks' `is_num "$NFC" || NFC=0` guards (see drive() for why)
    L=0; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=9000; MEM_UNKNOWN=0
    . "$TMP/disp.sh"
    for _once in 1; do
      . "$TMP/conflict.sh"
      break
    done
  ) >/dev/null 2>&1
}
# drive_rows <rows> <merge-authority> [<spawn-ok>] — the ACTING case, driven over a POPULATION.
# `rows` is TAB-delimited `PR<tab>HEAD` (empty string = no un-owned PR at all). This is the shape the
# controller actually runs (`printf … | while read`), so "0 un-owned PRs dispatches nothing" is
# observed on the shipped code rather than asserted about a population that is never read.
# ⛔ ONE LEVEL OF NESTING, NOT TWO: the arm block is sourced inside the `while`, so its `continue`
# statements mean "next PR" exactly as in the controller.
drive_rows() {
  : > "$TMP/spy"; : > "$TMP/gspy"; : > "$TMP/d.log"; mkdir -p "$TMP/O/state"
  : > "$TMP/lanes"
  : > "$TMP/O/state/prdisp.tsv"
  (
    BR=fix/thing; OR=daniel-ospina/agent-infra; REPO=/nonexistent
    SPAWN_CWD="$TMP/O"; O="$TMP/O"; LOG="$TMP/d.log"
    MERGE_AUTHORITY="${2:-rail}"; AUTHORITY_UNKNOWN=0
    MF=9; MR=9; MAX_FIX_TRIES=3; REQ='ai-review-gate'; REVIEW_GATE='ai-review-gate'; DRAFT=false
    SPAWN_OK="${3:-1}"; WT_DIR="$O/state"; WT_TABLE_TTL=0
    # shellcheck disable=SC1090
    . "$HERE/worker-terminal.sh"
    cmux() {
      case "$1" in
        tree) printf '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}\n'; return 0 ;;
        surface) return 1 ;;
        layout) { printf 'CMUX %s ' "$*"; tr -d '\n' <&0; echo; } >> "$TMP/spy"
                [ "$SPAWN_OK" = "1" ] || return 1
                printf '{"workspace_id": "ws_x", "panes": [{"surfaces": [{"terminal_id": "term_x"}]}]}\n'
                return 0 ;;
      esac
      return 0
    }
    gh() { echo "GH $*" >> "$TMP/gspy"; case "$*" in *mergeable*) echo "$MSTAT" ;; esac; return 0; }
    sess() { return 1; }; claim_live() { return 1; }; can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }; park_ctrl() { return 0; }
    . "$TMP/shq.sh"
    . "$TMP/disp.sh"
    while IFS="$(printf '\t')" read -r _p _h; do
      [ -z "${_p:-}" ] && continue
      PR="$_p"; HEAD_N="$_h"; V=GREEN; MSTAT=MERGEABLE
      . "$TMP/arm.sh"
    done <<ROWS
${1:-}
ROWS
  ) >/dev/null 2>&1
}
# The shipped disp() block sets `PRDISP="$O/state/prdisp.tsv"` ITSELF (it must — it ships next to
# the truncation), so the fixture cannot redirect it: the ledger is read from where the code puts it.
LEDGER="$TMP/O/state/prdisp.tsv"
acts()   { [ -f "$LEDGER" ] && awk -F'\t' '$4=="act"'  "$LEDGER" | wc -l | tr -d ' ' || echo 0; }
waits()  { [ -f "$LEDGER" ] && awk -F'\t' '$4=="wait"' "$LEDGER" | wc -l | tr -d ' ' || echo 0; }
rows()   { [ -f "$LEDGER" ] && awk 'END{print NR+0}' "$LEDGER" || echo 0; }
reason() { [ -f "$LEDGER" ] && awk -F'\t' '{print $5}' "$LEDGER" | head -1 || true; }

if [ -s "$TMP/arm.sh" ]; then

echo
echo "=== T4: no buildable class falls through the acting case ==="
# NOCHECKS is the measured hole: an empty check surface (or a failed `gh pr checks`, whose stderr the
# pipeline discards) printed nothing and spawned nothing, forever.
drive NOCHECKS rail 0
[ "$(spawns)" = "0" ] && [ "$(waits)" -ge 1 ] && [ "$(acts)" = "0" ] \
  && ok "NOCHECKS: a wait row is recorded and NOTHING is spawned (it is never treated as healthy)" \
  || bad "NOCHECKS: spawns=$(spawns) acts=$(acts) waits=$(waits) — the class fell through silently again"
grep -qi 'no acting arm for class' "$TMP/d.log" \
  && ok "NOCHECKS: the refusal is also a printed log line (not ledger-only)" \
  || bad "NOCHECKS: nothing was logged — a reader of the log still sees an idle PR with no reason"
# An EMPTY V is the same hole by another route (gh pr checks itself failed).
drive "" rail 0
[ "$(waits)" -ge 1 ] && [ "$(spawns)" = "0" ] \
  && ok "an EMPTY class (unreadable check read) also gets a named wait" \
  || bad "an empty class still falls through (waits=$(waits) spawns=$(spawns))"

# ⛔ THE NAMED VERDICTS (agent-infra#2719). Before the arm, all four causes arrived as the ONE token
# above and the only thing the cycle could print was "re-read next cycle". Each cause has its own
# remedy, so each must reach its own row — and NOT ONE of them may spawn: an empty check surface is
# never a green and never a reason to act on the code.
for _nm in \
  "NOCHECKS:READ-FAILED:transport: error connecting to api.github.com" \
  "NOCHECKS:BUDGET:this box's share of the ACCOUNT's core budget is exhausted (fleet=4)" \
  "NOCHECKS:WAIT:a run is executing and has produced no check-run yet (Python CI run 77 in_progress)" \
  "NOCHECKS:DEFERRED-REPAIR:ci-check-repair (scheduled workflow) owns the re-trigger" \
  "NOCHECKS:RUN-STARTED:a token the resolver never emits (a NEW token must still not spawn)"; do
  drive "$_nm" rail 0
  _k="${_nm%%:*}"; _r="$(reason)"
  [ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] && [ "$(waits)" = "1" ] \
    && ok "${_nm%%:*}…: one wait row, NOTHING spawned (the cause is named, not acted on)" \
    || bad "${_nm}: spawns=$(spawns) acts=$(acts) waits=$(waits)"
  case "$_r" in *"${_nm#NOCHECKS:}"*) ok "…and the ledger row CARRIES the named cause" ;;
    *) bad "the ledger row does not carry the cause: '$_r'" ;; esac
  # ⛔ AND IT MUST HAVE REACHED THE NAMED ARM, NOT THE RESIDUAL `*)` CATCH-ALL (review P3,
  # agent-infra#2719). Both arms write one `wait` row carrying `$V`, so every other assertion here
  # passed with the `NOCHECKS:*` arm DELETED — measured. The residual arm's reason text is the
  # distinguishing fact: it says "unreadable or empty", which is exactly the collapse this change
  # removes.
  case "$_r" in *"unreadable or empty"*) bad "'${_nm%%:*}' fell through to the residual catch-all: '$_r'" ;;
    *) ok "…and it was the NAMED arm that handled it (not the residual catch-all)" ;; esac
  [ ! -f "$TMP/O/state/parked-4242" ] \
    && ok "…and a non-terminal cause never parks the head" \
    || bad "'${_nm%%:*}' PARKED a head that a later cycle can still resolve"
done
drive "NOCHECKS:UNRESOLVABLE:no workflow run exists at this head (head abc1234)" rail 0
[ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] && [ "$(waits)" = "1" ] \
  && ok "NOCHECKS:UNRESOLVABLE: one wait row and NOTHING spawned (a dead end is never a fix or a merge)" \
  || bad "NOCHECKS:UNRESOLVABLE: spawns=$(spawns) acts=$(acts) waits=$(waits)"
[ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ] \
  && ok "…and it PARKS the head (no further cycle is spent on a named dead end)" \
  || bad "the unresolvable verdict did not park the head ($(cat "$TMP/O/state/parked-4242" 2>/dev/null))"
grep -q 'NOCHECKS-UNRESOLVABLE' "$TMP/O/state/parkreason-4242" 2>/dev/null \
  && ok "…with the verdict as the park REASON (so the next cycle reports why, not 'parked')" \
  || bad "the park carries no reason ($(cat "$TMP/O/state/parkreason-4242" 2>/dev/null))"
grep -q 'PARKED — NOCHECKS-UNRESOLVABLE' "$TMP/d.log" \
  && ok "…and the log line says PARKED with the verdict" \
  || bad "the log does not report the park"
# ⛔ A VERDICT THAT NEVER REACHED THE PR MUST NOT PARK (agent-infra#2719 review P2): the arm never
# re-enters a parked head, so a failed post would be retried never and the PR would be dead-ended with
# no explanation anywhere a human looks.
# the earlier drive PARKED this head, and `drive()` does not clear the park files (they are the very
# state this assertion is about) — so clear them first or the assertion reads the previous drive's park.
rm -f "$TMP/O/state/parked-4242" "$TMP/O/state/parkreason-4242"
drive "NOCHECKS:UNRESOLVABLE:no workflow run exists at this head (head abc1234) [post=failed]" rail 0
[ ! -f "$TMP/O/state/parked-4242" ] \
  && ok "[post=failed]: the head is NOT parked (the verdict is retried instead of lost)" \
  || bad "a verdict that could not be posted still parked the head"
[ "$(waits)" = "1" ] && [ "$(spawns)" = "0" ] \
  && ok "[post=failed]: still one wait row and nothing spawned" \
  || bad "[post=failed]: waits=$(waits) spawns=$(spawns)"
grep -q 'verdict could NOT be posted' "$TMP/d.log" \
  && ok "…and the log NAMES the failed post" \
  || bad "the log does not report the failed post"
# …but a post that has now failed its bounded number of times IS parked, with the failure as the reason.
rm -f "$TMP/O/state/parked-4242" "$TMP/O/state/parkreason-4242"
drive "NOCHECKS:UNRESOLVABLE:no workflow run exists at this head (head abc1234) [post=failed-parked]" rail 0
[ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ] \
  && ok "[post=failed-parked]: the bounded-retry case DOES park (the token is not terminal for ever)" \
  || bad "a post that exhausted its attempts was not parked — the retry would loop for ever"
grep -q 'could not be posted' "$TMP/O/state/parkreason-4242" 2>/dev/null \
  && ok "…and the park reason records the post failure (a human can see why nothing was published)" \
  || bad "the park reason does not record the post failure"
# …and when the post bound itself cannot be COUNTED (state/ unwritable), it is named and parked.
rm -f "$TMP/O/state/parked-4242" "$TMP/O/state/parkreason-4242"
drive "NOCHECKS:UNRESOLVABLE:no workflow run exists at this head [post=failed-inert]" rail 0
[ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ] \
  && ok "[post=failed-inert]: an UNCOUNTABLE post bound parks too (a named dead end beats a comment loop)" \
  || bad "an uncountable post bound was left retrying for ever"
grep -q 'could not be counted' "$TMP/O/state/parkreason-4242" 2>/dev/null \
  && ok "…and the park reason says the bound was INERT" \
  || bad "the park reason does not name the inert bound"

echo
echo "=== T1: a claim has a spawn behind it, and a failed spawn is never silent ==="
clear_workers; drive GREEN rail 0 1
_g=$(spawns); _a="$(acts)"
[ "$_g" -ge 1 ] && [ "$_a" = "1" ] && [ "$_g" = "$_a" ] \
  && ok "GREEN+rail: 1 spawn and exactly 1 \`act\` row (the ledger's act count IS the spawn count)" \
  || bad "GREEN+rail: spawns=$_g act-rows=$_a — the record and the spawn disagree"
drive GREEN rail 0 0        # the tmux spawn FAILS
[ "$(acts)" = "0" ] && [ "$(waits)" -ge 1 ] \
  && ok "GREEN+rail: a FAILED spawn records a WAIT, never an act (no phantom dispatch)" \
  || bad "GREEN+rail: a failed spawn recorded acts=$(acts) waits=$(waits)"
grep -qi 'spawn FAILED' "$TMP/d.log" \
  && ok "…and the failed spawn is a printed line (the \`&& echo\` shape that swallowed it is gone)" \
  || bad "…a failed rail spawn is still unremarked in the log"
# A re-record spawn that fails: this was `tmux … && echo`, i.e. silent on failure.
# ⛔ NO `rm` ON A `$TMP/…` PATH AND NO GLOB (#709): the main-worktree-guard reads a discard whose target
# starts with a variable as an unresolvable effect and refuses to run this whole file. `mv` out of the
# way is not a discard, and the assertion only needs the marker ABSENT — the destination is junk.
mv "$TMP/O/state/needsfix-4242-abc1234" "$TMP/marker.spent" 2>/dev/null || true
drive 'FAILED:ai-review-gate' rail 0 0
[ "$(acts)" = "0" ] && grep -qi 're-record spawn FAILED' "$TMP/d.log" \
  && ok "a FAILED re-record spawn is named (no unremarked non-spawn)" \
  || bad "a failed re-record spawn is still silent (acts=$(acts))"

echo
echo "=== T5: a capacity refusal NAMES itself (lanes=0 must never be unexplained) ==="
# The CONFLICTING router has its OWN case block (it runs before the class arms), so it is driven
# separately — and it must (a) spawn the fixer when a slot exists, (b) refuse AND name the refusal
# at the ceiling. Both halves matter: a routing fix that silently stops spawning is not a fix.
drive_conflict 0
[ "$(spawns)" -ge 1 ] && [ "$(acts)" = "1" ] \
  && ok "CONFLICTING with a free slot: the conflict fixer is spawned and recorded as ONE act" \
  || bad "CONFLICTING with a free slot: spawns=$(spawns) acts=$(acts) — the conflicted-first path did not dispatch"
drive_conflict 9
[ "$(acts)" = "0" ] && [ "$(waits)" -ge 1 ] && grep -qi 'NO fixer slot' "$TMP/d.log" \
  && grep -q 'mem-gate=9000M/512' "$TMP/d.log" \
  && ok "CONFLICTING at the fix-lane ceiling: refused, named in the log WITH its gate evidence, recorded as a wait" \
  || bad "CONFLICTING at the ceiling: acts=$(acts) waits=$(waits) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
drive_conflict 0 0
[ "$(acts)" = "0" ] && grep -qi 'fixer spawn FAILED' "$TMP/d.log" \
  && ok "CONFLICTING: a FAILED conflict-fixer spawn is a wait + a printed line (never a phantom act)" \
  || bad "CONFLICTING: a failed spawn recorded acts=$(acts) — the record claims work that did not happen"
drive GREEN rail 9 1
[ "$(acts)" = "0" ] && grep -qi 'NO merge slot' "$TMP/d.log" \
  && ok "GREEN+rail at the merge-lane ceiling: refused and named" \
  || bad "GREEN+rail at the ceiling: acts=$(acts) — the refusal is still silent"
# ⛔ THE NEEDS-FIX MARKER FROM THE DEFER DRIVE ABOVE MUST GO (agent-infra#2653 review round 5): with
# findings on disk this arm now names the FIXER ceiling (correctly — a fixer is the remedy for a head
# that has findings), so leaving the marker here would grade the wrong branch while still passing on
# "refused". `mv`, not `rm` (#709).
mv "$TMP/O/state/needsfix-4242-abc1234" "$TMP/needsfix.t5.spent.$RANDOM" 2>/dev/null || true
drive 'FAILED:ai-review-gate' rail 9 1
[ "$(acts)" = "0" ] && grep -qi 'NO re-record slot' "$TMP/d.log" \
  && ok "review-gate red at the review-lane ceiling: refused and named" \
  || bad "review-gate red at the ceiling: acts=$(acts) — silent refusal"
drive 'FAILED:pipeline-compliance' rail 9 1
[ "$(acts)" = "0" ] && grep -qi 'NO fixer slot' "$TMP/d.log" \
  && ok "CI-red at the fix-lane ceiling: refused and named" \
  || bad "CI-red at the ceiling: acts=$(acts) — silent refusal"
# ⛔ THE FOURTH HOLE (found by this drive): RED, but no red name is a REQUIRED check for the repo, so
# neither the review-gate arm nor the CI-red arm fires. Not acting is correct; being silent is not.
drive 'FAILED:docs-lint' rail 0 1
[ "$(acts)" = "0" ] && [ "$(waits)" -ge 1 ] && grep -qi 'no arm: no red check' "$TMP/d.log" \
  && ok "a red that is not a required check: nothing spawned, but the PR is NAMED (no silent red)" \
  || bad "a non-required red is still unattributed (acts=$(acts) waits=$(waits) log=$(head -2 "$TMP/d.log" | tr '\n' ';'))"

# ⛔ THE THREE DRIVES ABOVE SPAWN, SO THEY CONSUME THE SHARED `fixcount-4242` AND LEAVE A `fixspend`
# RECORD BEHIND (the defer arms they replaced changed no state at all). Each one therefore starts from
# a cleared counter: without it the third drive reads an exhausted attempt cap and parks instead of
# spawning, which would make it assert the wrong branch. `mv`, never `rm` on a `$TMP/…` path (#709).
t5_clear() {
  for _f in fixcount-4242 fixspend-4242-abc1234 parked-4242 parkreason-4242 argv-4242; do
    [ -e "$TMP/O/state/$_f" ] && mv "$TMP/O/state/$_f" "$TMP/state.spent.$_f.$RANDOM" 2>/dev/null
  done
  return 0
}

# ⛔ THE CI-QUEUE GATE IS GONE FROM ALL THREE FIXER ARMS, AND THESE DRIVE THAT (#2927). Until this
# change each of them deferred on `ciq_push_ok`, so a deep queue stopped PR-REPAIR work: measured
# 2026-10-27 on cell 4, 41 consecutive repair dispatches were skipped while 8 self-hosted runners and
# ~11 lane slots sat idle. The predicate is stubbed to REFUSE (`CIQ_PUSH_RC=1`) *and* to record being
# asked — so "the arm no longer consults the queue" is measured, not inferred from a missing log line.
t5_clear; : > "$TMP/ciqspy"
CIQ_PUSH_RC=1; drive_conflict 0; unset CIQ_PUSH_RC
[ "$(spawns)" -ge 1 ] && [ "$(acts)" = "1" ] && [ ! -s "$TMP/ciqspy" ] && ! grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "CONFLICTING with a REFUSING queue predicate: the fixer is spawned AND the predicate is never consulted" \
  || bad "CONFLICTING still consults the queue: spawns=$(spawns) acts=$(acts) called=$([ -s "$TMP/ciqspy" ] && echo yes || echo no) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
: > "$TMP/ciqspy"
CIQ_PUSH_RC=1; drive 'FAILED:pipeline-compliance' rail 0 1; unset CIQ_PUSH_RC
[ "$(spawns)" -ge 1 ] && [ "$(acts)" = "1" ] && [ ! -s "$TMP/ciqspy" ] && ! grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "CI-red fixer with a REFUSING queue predicate: spawned, and the predicate is never consulted" \
  || bad "CI-red fixer still consults the queue: spawns=$(spawns) acts=$(acts) called=$([ -s "$TMP/ciqspy" ] && echo yes || echo no)"
# The review-gate arm only reaches ITS fixer branch for a PR with FINDINGS at this head (a head with
# none is a re-record, which spends no CI), so the needsfix marker is supplied.
t5_clear; : > "$TMP/ciqspy"
NEEDSFIX=1; CIQ_PUSH_RC=1; drive 'FAILED:ai-review-gate' rail 0 1; unset NEEDSFIX CIQ_PUSH_RC
[ "$(spawns)" -ge 1 ] && [ "$(acts)" = "1" ] && [ ! -s "$TMP/ciqspy" ] && ! grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "review-gate fixer with a REFUSING queue predicate: spawned, and the predicate is never consulted" \
  || bad "review-gate fixer still consults the queue: spawns=$(spawns) acts=$(acts) called=$([ -s "$TMP/ciqspy" ] && echo yes || echo no)"


echo
echo "=== T7: the review remedy is DISPATCHABLE, keyed on (PR, head), and BOUNDED (agent-infra#2653) ==="
# ⛔ WHAT THIS SECTION IS FOR. The controller printed the correct remedy (`NEEDS-REVIEW — the remedy is
# another review`) and then took no action on it for 26 hours, while the box reported 5-18 idle
# workers. The measured reason was capacity (`review lanes=11/6`, eleven of them dead records), but the
# second half of the defect is that a review had no (PR, head) identity at all: nothing could say "this
# head is already reviewed" or "this head has spent its budget", so the only two possible behaviours
# were "dispatch again" and "dispatch forever". These drives pin the four states as BEHAVIOUR.
REV_DISP="$TMP/O/state/reviewdisp-4242"
STORE="$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-4242.json"
# ⛔ `mv`, NOT `rm`, AND NO GLOB (#709): the main-worktree-guard refuses a discard whose target is a
# `$TMP/…` path, and it then refuses to run this whole file for every unhatched session.
clear_revdisp() { mv "$REV_DISP" "$TMP/revdisp.spent.$RANDOM" 2>/dev/null || true; }
clear_store()   { mv "$STORE" "$TMP/store.spent.$RANDOM" 2>/dev/null || true; }
seed_revdisp()  { printf '%s %s\n' "$1" "$2" > "$REV_DISP"; }
# ⛔ THE REVIEW-GATE ARM IS ONLY REACHED FOR A HEAD WITH NO FINDINGS (#2132). The T5 drives above may
# leave a `needsfix-4242-abc1234` marker behind (the review-gate arm there supplies one; since #2927 it
# CONSUMES it by spawning rather than deferring, but the clearing must not depend on which branch T5
# took), and every drive here shares ONE `$O/state`. Leaving it in place routes these drives into the
# FIXER arm and the whole section would then grade a path it never reached — measured: (a) reported
# "spawns=1" for a fixer.
clear_needsfix() { mv "$TMP/O/state/needsfix-4242-abc1234" "$TMP/needsfix.spent.$RANDOM" 2>/dev/null || true; }
# ── the PER-PR REVIEW-ROUND budget (agent-infra#3441) ────────────────────────────────────────────
# Same `mv`-not-`rm` rule (#709): the guard treats a `rm` of a `$TMP/…` path as an unverifiable discard.
ROUND_F="$TMP/O/state/reviewround-4242"
clear_round() { mv "$ROUND_F" "$TMP/round.spent.$RANDOM" 2>/dev/null || true; }
seed_round()  { printf '%s\n' "$1" > "$ROUND_F"; }
# ⛔ THE CAP IS A KNOB THE ARMS MUST DERIVE FROM, NOT REPEAT (round 2 review, P2). `install.sh` renders
# `MAX_REVIEW` into the launchd plist, so a box pinned to 4 or 12 is an ordinary box; the first version
# of these arms seeded 9/10 and asserted `rounds=10/10`, which encoded the SHIPPED DEFAULT — the same
# class this PR fixed in `test_pr_doctor.py`'s saturated-fleet fixture. Every ceiling arm is built from
# `$CAP`, so the suite tracks the cap it is driving. The range it is driven over is declared and
# enforced at the TOP of this file (see `DRIVE_MAX_REVIEW` there): CAP >= 2.
# ⛔ A DRIVE THAT SPAWNS LEAVES A WORKER RECORD, WHICH INFLATES THE NEXT DRIVE'S CENSUS (measured):
# the `lanes-in-use` fixture says 9, and a leftover `worker-merge-4242` made the same assertion read
# `review lanes=10/9`. Records are files, so move the ones this fixture's PR could own out of the way —
# `mv`, never `rm` on a `$TMP/…` path (#709).
clear_workers
# The shipped park_ctrl WRITES parked/parkreason into the shared `$TMP/O/state`, so each park assertion
# starts from a clean slate: a leftover `parked-4242` from an earlier drive would make the next
# assertion pass for the wrong reason (and the negative one — a failed spawn parks nothing — impossible).
clear_parked() { mv "$TMP/O/state/parked-4242" "$TMP/parked.spent.$RANDOM" 2>/dev/null || true
                 mv "$TMP/O/state/parkreason-4242" "$TMP/parkreason.spent.$RANDOM" 2>/dev/null || true; }
clear_needsfix; clear_parked
# The holders line reads a worker's log age: give it a real log file so the age is an age, not `?m`.
mkdir -p "$TMP/O/logs"; : > "$TMP/O/logs/merge-0.log"

# (a) a NEEDS-REVIEW head with capacity dispatches EXACTLY ONE review lane, keyed on (PR, head)
clear_store; clear_revdisp
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && [ "$(acts)" = "1" ] && grep -q '^#4242 re-record$' "$TMP/d.log" \
   && grep -q 'fresh review, attempt 1/3' "$LEDGER" 2>/dev/null; then
  ok "(a) one NEEDS-REVIEW head + capacity = exactly ONE review lane, and it is recorded as an act"
else
  bad "(a) spawns=$(spawns) acts=$(acts) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
fi
[ "$(cat "$REV_DISP" 2>/dev/null)" = "abc1234 1" ] \
  && ok "(a) …and the dispatch is RECORDED against (PR=4242, head=abc1234) as \"abc1234 1\"" \
  || bad "(a) the (PR,head) key was not written: [$(cat "$REV_DISP" 2>/dev/null)]"

# (b1) ONE review per (PR, head): a head the store already records CLEAN is NOT re-reviewed
clear_revdisp
printf '%s\n' '{"pr":4242,"head_sha":"abc1234","verdict":"clean","repo":"daniel-ospina/agent-infra"}' > "$STORE"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] && grep -q 'REVIEW-AT-HEAD' "$TMP/d.log"; then
  ok "(b1) same head, review ALREADY recorded => NOTHING dispatched, and the refusal is named REVIEW-AT-HEAD"
else
  bad "(b1) spawns=$(spawns) acts=$(acts) — a reviewed head still bought a fresh review"
fi
grep -q 'holding:' "$TMP/d.log" && bad "(b1) the AT-HEAD refusal was reported as a capacity problem" \
  || ok "(b1) …and it is not misreported as a capacity refusal (the reason is the head, not the box)"
clear_store

# (b2) the BOUND holds at the cap, and it says REVIEW-CAP with the count — never a silent stop
clear_parked; clear_store; seed_revdisp abc1234 3
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] && grep -q 'REVIEW-CAP 3/3' "$TMP/d.log" \
   && [ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ]; then
  ok "(b2) MAX_REVIEW_TRIES spent at this head => no dispatch, REVIEW-CAP with the count, and the head is PARKED"
else
  bad "(b2) spawns=$(spawns) acts=$(acts) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log") — the review budget is unbounded at a fixed head"
fi

# (c) a PUSH re-arms it: the same PR at a NEW head is dispatchable again, and the budget restarts
seed_revdisp def5678 3
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && [ "$(acts)" = "1" ] && [ "$(cat "$REV_DISP" 2>/dev/null)" = "abc1234 1" ]; then
  ok "(c) the head moved => dispatchable again, and the count RESTARTS at this head (1), not 4"
else
  bad "(c) spawns=$(spawns) key=[$(cat "$REV_DISP" 2>/dev/null)] — a push did not re-arm the review budget"
fi

# (c2) the count INCREMENTS from what this head already spent (review of #2653, P2). Without this
# drive `_rvn=0` hard-coded passes (a) and (c), because both only ever assert the value `1`.
clear_store; seed_revdisp abc1234 1
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && [ "$(cat "$REV_DISP" 2>/dev/null)" = "abc1234 2" ] \
   && grep -q 'fresh review, attempt 2/3' "$LEDGER" 2>/dev/null; then
  ok "(c2) a second dispatch at the same head spends the SECOND attempt (2/3), not a reset to 1"
else
  bad "(c2) spawns=$(spawns) key=[$(cat "$REV_DISP" 2>/dev/null)] — the attempt number is not derived from the record"
fi

# (c4) THE PER-PR REVIEW-ROUND CEILING (agent-infra#3441). ⛔ THE QUESTION IS NOT `reviewdisp`'s:
# that one is per HEAD and a push re-arms it, so before this the review loop had no bound at all that
# spanned heads — a PR could buy reviews for ever, one head at a time (measured on #3355: four recorded
# rounds across four heads, each within its own budget, nothing counting the PR). `MAX_REVIEW` now
# bounds the rounds a PR may spend and the round AFTER the ceiling is REFUSED and PARKED.
clear_parked; clear_store; clear_revdisp; clear_round
# (c4a) BELOW the ceiling it dispatches and the round is SPENT — the counter is not decoration.
seed_round $(( CAP - 1 ))
drive 'FAILED:ai-review-gate' rail 0 1
# ⛔ THE DISPATCH DOES NOT SPEND THE ROUND (round-3 review, P1) — the REVIEWER does, and `merge-one.sh`
# is the only writer. The controller spent it here until round 3, right after `wt_spawn`, i.e. before the
# worker existed: a worker that then took the rail-only path, lost a claim race or was refused by its own
# brief gate still cost a round, and the ceiling could later refuse a genuine review with a false
# "budget exhausted". So this arm asserts the OPPOSITE of what it used to: the counter is UNCHANGED by a
# successful dispatch (merge-one writes it when `AGENT_STARTED=1`; (c4g)/(c4g2) pin that structure).
if [ "$(spawns)" = "1" ] && [ "$(cat "$ROUND_F" 2>/dev/null)" = "$(( CAP - 1 ))" ]; then
  ok "(c4a) a review at round $(( CAP - 1 ))/$CAP IS dispatched, and the DISPATCH spends nothing (the counter stays $(( CAP - 1 )) — the reviewer pays it, not the controller)"
else
  bad "(c4a) spawns=$(spawns) round=[$(cat "$ROUND_F" 2>/dev/null)] (expected $(( CAP - 1 )) unchanged) — the dispatch either did not happen or spent a round it never ran"
fi
# (c4b) AT the ceiling the next round is REFUSED, the head is PARKED, and the terminal line names the
# PR, the rounds spent and the findings — in the log, in the ledger AND in the park reason, which is
# what makes the diagnosis survive log-quiet (#943).
clear_parked; clear_store; clear_revdisp; clear_round
seed_round "$CAP"
: > "$TMP/O/state/needsfix-4242-dead999"   # findings left by an EARLIER head, still unresolved
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] \
   && grep -q "REVIEW-CEILING 4242 rounds=$CAP/$CAP head=abc1234 stale_findings=1 heads=dead999" "$TMP/d.log" \
   && grep -qF "REVIEW-CEILING 4242 rounds=$CAP/$CAP" "$LEDGER" 2>/dev/null \
   && [ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ] \
   && grep -qF "REVIEW-CEILING 4242 rounds=$CAP/$CAP" "$TMP/O/state/parkreason-4242" 2>/dev/null; then
  ok "(c4b) the round ceiling REFUSES the next review, parks the head, and the line names PR+rounds+findings in the log, the ledger AND the park reason"
else
  bad "(c4b) spawns=$(spawns) acts=$(acts) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log") reason=[$(cat "$TMP/O/state/parkreason-4242" 2>/dev/null | head -1)]"
fi
mv "$TMP/O/state/needsfix-4242-dead999" "$TMP/deadfix.spent.$RANDOM" 2>/dev/null || true
# (c4c) THE CEILING IS AN ESCALATION, NOT A VERDICT: the park reason must say so in words an operator
# can act on, and it must NOT claim the PR was reviewed or passed. A bounded stop that reads as a
# quality verdict is the one reading this arm must never print.
if grep -qi 'ESCALATION, not a pass' "$TMP/O/state/parkreason-4242" 2>/dev/null \
   && grep -qF 'stale_findings names the findings markers' "$TMP/O/state/parkreason-4242" 2>/dev/null; then
  # ⛔ THE FIELD NAME MUST SURVIVE THE QUOTING (round 2 review, P2): the reason is built inside a
  # DOUBLE-QUOTED string, so a backticked field name was COMMAND-SUBSTITUTED — the text lost the name
  # (two spaces where it belonged) and the shell printed "stale_findings: command not found". No arm
  # covered it, so it stayed green. This one reads the field name it tells the operator to look at.
  ok "(c4c) the park reason states the ceiling is an ESCALATION, never a pass — and the stale_findings field name survives the quoting"
else
  bad "(c4c) the park reason does not say the ceiling is an escalation: [$(head -c 200 "$TMP/O/state/parkreason-4242" 2>/dev/null)]"
fi
# (c4d) THE ROUND IS PASSED INTO THE REVIEW ORDER, so the brief the reviewer receives knows which
# round it is. Acceptance #4 of #3441 is exactly this plumbing (`REV_ROUND`), and a spawn that dropped
# it would briefing round 7 as round 1 — the mandate would exist and never apply.
clear_parked; clear_store; clear_revdisp; clear_round
seed_round $(( CAP - 2 ))
drive 'FAILED:ai-review-gate' rail 0 1
# ⛔ THE RUN FILE, NOT THE SPY: `wt_spawn` runs a worker through a per-worker script
# (`$O/state/run-<name>.sh`) and the layout argv carries only its PATH, so the env the reviewer actually
# receives is in that file. Measured: grepping `$TMP/spy` found the script name and no env at all.
if grep -qF "REV_ROUND=$(( CAP - 1 ))" "$TMP/O/state/run-review-4242.sh" 2>/dev/null; then
  ok "(c4d) the review ORDER carries REV_ROUND=$(( CAP - 1 )) — the round this review spends, derived from the counter"
else
  bad "(c4d) the spawn did not carry REV_ROUND: [$(grep -o 'REV_PAID=[^ ]*' "$TMP/O/state/run-review-4242.sh" 2>/dev/null | head -1)] file=$(ls "$TMP/O/state" 2>/dev/null | grep run- | head -3 | tr '\n' ' ')"
fi
clear_parked; clear_store; clear_revdisp; clear_round

# (c4e) MAX_REVIEW=0 IS REPORT-ONLY, NOT "EVERYTHING IS EXHAUSTED" (fresh review of #3441, P1).
# `is_limit 0` is TRUE and `install.sh` accepts `MAX_REVIEW=0`, so a bare `[ 0 -ge 0 ]` parked EVERY
# PR in the queue with a reason claiming an exhausted budget it had never spent — a false diagnosis
# manufactured by the knob whose sibling (`MAX_REVIEW_TRIES=0`) means the opposite. Measured before the
# fix: 13 red arms under `MAX_REVIEW=0`, including "parked=abc1234 … rounds=0/0".
clear_parked; clear_store; clear_revdisp; clear_round
DRIVE_MAX_REVIEW=0 drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && ! grep -q 'REVIEW-CEILING' "$TMP/d.log" \
   && [ ! -e "$TMP/O/state/parked-4242" ] && grep -q 'MAX_REVIEW=0 on this box (REPORT-ONLY' "$TMP/d.log"; then
  ok "(c4e) MAX_REVIEW=0 is REPORT-ONLY: nothing dispatched, NOTHING parked, and the line says so"
else
  bad "(c4e) MAX_REVIEW=0 spawns=$(spawns) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi
clear_parked; clear_store; clear_revdisp; clear_round

# (c4f) A FAILED SPAWN SPENDS NO ROUND — the `fixcount` rule, and a fresh review showed this arm was
# MISSING: booking the round before `wt_spawn` (the exact regression the arm's comment forbids) kept
# this suite fully green, because (c3) checks `reviewdisp` and `parked-` but never the round counter.
# The seeded value matters: a counter that starts EMPTY cannot distinguish "not spent" from "written 0".
clear_parked; clear_store; clear_revdisp; clear_round; seed_round $(( CAP - 1 ))
drive 'FAILED:ai-review-gate' rail 0 0
if [ "$(cat "$ROUND_F" 2>/dev/null)" = "$(( CAP - 1 ))" ] && [ "$(acts)" = "0" ]; then
  ok "(c4f) a FAILED review spawn leaves the round counter at $(( CAP - 1 )) — nothing is spent when nothing starts"
else
  bad "(c4f) round=[$(cat "$ROUND_F" 2>/dev/null)] acts=$(acts) — a failed spawn consumed a review round"
fi
clear_parked; clear_store; clear_revdisp; clear_round

# (c4g) THE OTHER WRITER — WHICH IS NOW THE ONLY WRITER (round-3 review, P1). The controller's arm is
# driven above; `merge-one.sh` cannot be driven here (it needs gh, claims and the rail), so what is
# pinned is the INVARIANT that took two review rounds to get right:
#   * the round must not be written at the top of the file (a rail merge, a claim race, a duplicate
#     invocation all exit before any review — that was round 2);
#   * it must not be written just above `run_agent` either, because `run_agent` REFUSES the reviewer in
#     its own arms (brief gate 80, pi load gate 76) and both say no reviewer ran — that was round 3;
#   * and the CONTROLLER must not write it at all: its write fired before `merge-one.sh` started.
# So: ONE writer, and its write sits BELOW `run_agent`, gated on `AGENT_STARTED`. ⛔ THE ANCHOR IS THE
# `printf` ITSELF, not the diagnostic echo below it — the first version of this arm anchored on the
# `|| echo` line, which made the window one line wide and let a DELETED write pass (round-3 review, P2).
# The hazard scan is widened past `exit` to `exec`/`return`/`die`, any of which leaves the function —
# and it SKIPS COMMENT LINES, because the block above the write legitimately names those words.
MW="$(dirname "$ORCH")/merge-one.sh"
# ⛔ COUNT THE WRITERS, DO NOT JUST FIND THE FIRST (round 4 review, P2). This arm's own claim is
# "merge-one.sh is the ONLY round writer", and the first version located the write with `head -1` and
# checked only THAT match's placement — so a SECOND writer appended lower in the file was invisible
# and the arm stayed green. Measured on a copy of the tree: appending a duplicate write gave
# 158 passed / 0 failed under a claimed "ONLY round writer". A double-spent round reaches
# `REVIEW-CEILING … rounds=10/10` after ~5 real reviews and parks with a reason asserting a diagnosis
# that does not exist — the exact false-diagnosis class this PR exists to close. Exclusivity is a
# COUNT over every write into the counter — and the pattern must tolerate RESPELLINGS (round 5
# review, P2; widened again by round 7, P2): the first version counted only `> "$_rr_f"`, so a
# duplicate written as `>"$_rr_f"` (no space), unquoted, with `>>`, or via `| tee "$_rr_f"` left
# W_COUNT=1 and the arm green; the second still missed `| tee -a "$_rr_f"` (the flag broke the match)
# and any write to the LITERAL path (`> "$O/state/reviewround-$PR"`). Both were measured green. The
# scan now allows tee flags, the `>|` noclobber override, and the atomic/file-copy idioms a future
# lane would reach for (`dd of=`, `cp`, `mv`, `install`) — the ones round 8 measured as green under the
# round-7 pattern (`>|`, `> tmp && mv tmp counter`, `| dd of=`, `cp`).
# ⛔ THIS IS A HEURISTIC SCAN, NOT A PROOF, AND SAY SO PLAINLY (round 8 review, P2). No text pattern
# can enumerate every way a shell writes a file, so the arm must not claim it "cannot be defeated" —
# the earlier wording did, and each round found another spelling. What it DOES pin is the shape a real
# second writer takes when a lane edits this file, and the behavioural half (placement below all three
# refusal arms, the `= "1"` guard ending in `]; then`) is what makes it safe. ⚠️ STATED RESIDUAL: a
# writer that reaches the counter by a form this pattern does not know is caught by nothing here.
# Prefer strengthening the behavioural pins to growing this regex.
W_COUNT="$(grep -cE '(>>?\||>>?|tee)[[:space:]]*(-[A-Za-z]+[[:space:]]+)*"?[^"[:space:]]*(_rr_f|reviewround-)|(dd[[:space:]]+of=|cp[[:space:]]+[^ ]+[[:space:]]+|mv[[:space:]]+[^ ]+[[:space:]]+|install[[:space:]]+[^ ]+[[:space:]]+)"?[^"[:space:]]*(_rr_f|reviewround-)' "$MW" || true)"
# ⛔ THE PLACEMENT INVARIANT IS ABOUT WHEN THE WRITE **EXECUTES**, NOT WHERE IT IS DEFINED
# (round 10 review, P1). Round 9 moved the write into `review_round_spend()` so the EXIT trap could
# reach a reaped reviewer's round — but the helper was then defined BELOW `run_agent`, so the trap
# fired while only the stub existed and the spend was DEAD CODE. The helper must be defined before the
# thing it guards; therefore the line the pin checks is the CALL SITE, not the printf:
#   * the printf (W_LINE) is the ONE write, wherever the helper is defined;
#   * the ingress call must sit BELOW every refusal arm and be guarded by the exact `= "1"` test;
#   * the exit hook must be DEFINED before `run_agent` and REGISTERED on the trap BEFORE
#     `review_abandoned_record` (whose real definition is far below, so the stub otherwise wins).
# ⛔ THE ANCHOR ACCEPTS BOTH SPELLINGS OF THE WRITE (fresh review of #3441, P2). The write is now
# ATOMIC — `printf > "$_rr_new" && mv "$_rr_new" "$_rr_f"` — because `printf > "$_rr_f"` truncates
# before it writes and both readers coerce a TORN (empty) book to 999999999, which parks a healthy PR
# with a false `REVIEW-CEILING … rounds=999999999/10`. The temp name deliberately does NOT spell the
# counter path, so `W_COUNT` still counts exactly ONE write into the destination (the `mv`); an anchor
# that only knew the `> "$_rr_f"` spelling would have found no writer at all and failed the arm for
# the safer code. Either spelling is accepted here, and the behavioural halves below (inside the
# helper, below every refusal arm) are unchanged.
W_LINE="$(grep -nE '^  (\{ )?printf .%s.n. *"\$REVIEW_ROUND" > "\$_rr_(f|new)"' "$MW" | cut -d: -f1 | head -1)"
[ -n "$W_LINE" ] || W_LINE="$(grep -n '> "\$_rr_f" 2>/dev/null' "$MW" | cut -d: -f1 | head -1)"
R_LINE="$(grep -n '^run_agent "${REVIEW_TIMEOUT' "$MW" | cut -d: -f1 | head -1)"
# the guarded ingress CALL — the exact line, so an appended `&& false` / `|| true` cannot satisfy it
CALL_LINE="$(grep -nxF 'if [ "${AGENT_STARTED:-0}" = "1" ]; then review_round_spend; fi' "$MW" | cut -d: -f1 | head -1)"
# the exit hook: defined before `run_agent`, and registered FIRST on the trap
HOOK_LINE="$(grep -n '^review_round_spend_at_exit() {' "$MW" | cut -d: -f1 | head -1)"
HELPER_LINE="$(grep -n '^review_round_spend() {' "$MW" | cut -d: -f1 | head -1)"
TRAP_LINE="$(grep -n "^trap 'review_round_spend_at_exit; review_abandoned_record" "$MW" | cut -d: -f1 | head -1)"
# ⛔ NO TOTAL ORDER BETWEEN ARMS, AND THE ANCHOR'S OWN BODY MUST TERMINATE (round 10 review, P2):
# a `if [ … ]; then : ; fi` DECOY satisfied both the header text and `arm_close()` while refusing
# nothing, so the real arm could be moved below the write and the suite stayed green. Each anchor now
# has to be a refusal that actually EXITS.
arm_close() { # <anchor-line> -> the line of its closing `fi` (bare, column 0)
  [ -n "$1" ] || return 0
  awk -v a="$1" 'NR>a && /^fi$/ {print NR; exit}' "$MW" 2>/dev/null
}
# ⛔ THE ARM MUST END BY LEAVING, NOT MERELY CONTAIN AN `exit` SOMEWHERE (round 11 review, P2). The
# round-10 version accepted any `^\s*exit N` in the block, so `if false; then exit 75; fi` — an
# UNREACHABLE exit — satisfied it while the arm refused nothing; the real arm could then be moved
# below the ingress call and the suite stayed GREEN (measured). What the invariant needs is that the
# LAST thing the arm does is exit, so control cannot fall past it on the refusal path.
arm_refuses() { # <anchor-line> <close-line> -> 0 when the block's LAST code line is a real `exit`
  [ -n "$1" ] && [ -n "$2" ] || return 1
  # ⛔ TWO ACCEPTED SPELLINGS, because the arms themselves use two and only one was ever matched
  # (measured on the merged tree, #3645): the LITERAL `exit 75` for a code this file publishes
  # itself, and the PROPAGATED `exit "${NAME:-<digits>}"` for a code DECLARED in `spawn-gate.sh`
  # and never exported (`AGENT_BRIEF_REFUSED` 80, `AGENT_HARNESS_SKEW_REFUSED` 83). The literal-only
  # pattern made this pin report `arms-exit=0` — "the arms stopped refusing" — for every arm #3645
  # converted, while the arms were correct. Both requirements that made it a CHECK survive: the LAST
  # code line must be an `exit` (control cannot fall past the arm on the refusal path), and the
  # tolerant form must carry a NUMERIC default (`exit "${X:-}"` is a bash usage error, not a refusal
  # code, and is still rejected).
  awk -v a="$1" -v b="$2" 'NR>a && NR<b && !/^[[:space:]]*#/ && NF {last=$0}
       END{
         if (last ~ /^[[:space:]]*exit[[:space:]]+[0-9]+[[:space:]]*$/) exit 0
         if (last ~ /^[[:space:]]*exit[[:space:]]+"[$][{][A-Za-z_][A-Za-z0-9_]*:-[0-9]+[}]"[[:space:]]*$/) exit 0
         exit 1
       }' "$MW" 2>/dev/null
}
A76="$(grep -nE '^if \[ "\$AGENT_RC" = "\$\{PI_GATE_REFUSED:-76\}" \]; then' "$MW" | cut -d: -f1 | head -1)"
A78="$(grep -nE '^if \[ "\$\{AGENT_STARTED:-0\}" = "1" \] && \{' "$MW" | cut -d: -f1 | head -1)"
A80="$(grep -nE '^if \[ "\$AGENT_RC" = "\$\{AGENT_BRIEF_REFUSED:-80\}" \]; then' "$MW" | cut -d: -f1 | head -1)"
# ⛔ THE SYNC/SKEW ARM (83) IS THE FOURTH REFUSAL ARM, AND THIS PIN NEVER LEARNED IT (measured on the
# merged tree, #3645). #3645 added it to `merge-one.sh`, and it is a refusal of exactly this class: no
# reviewer ran, both round flags are cleared, so nothing may be spent. Because the three original
# anchors did not know it, the window scan below read its `exit "${…:-83}"` as an UNEXPLAINED exit
# between the last known arm and the ingress call, and reported `place-ok=0` on correct code — a
# FALSE BLOCK whose only two readings are "delete this pin" and "move the arm". Naming the arm makes
# the invariant stronger instead: four arms are now each required to exist, to END by exiting, and to
# clear the flags.
A83="$(grep -nE '^if \[ "\$AGENT_RC" = "\$\{AGENT_HARNESS_SKEW_REFUSED:-83\}" \]; then' "$MW" | cut -d: -f1 | head -1)"
A78_OK=0
if [ -n "$A78" ] && sed -n "${A78}p" "$MW" 2>/dev/null | grep -q 'PI_FORK_REFUSED:-78'; then A78_OK=1; fi
C76="$(arm_close "${A76:-}")"; C78="$(arm_close "${A78:-}")"; C80="$(arm_close "${A80:-}")"
C83="$(arm_close "${A83:-}")"
LAST_CLOSE=0
for _c in "${C76:-0}" "${C78:-0}" "${C80:-0}" "${C83:-0}"; do if [ "${_c:-0}" -gt "$LAST_CLOSE" ]; then LAST_CLOSE="${_c:-0}"; fi; done
ARMS_EXIT=0
arm_refuses "${A76:-}" "${C76:-}" && arm_refuses "${A78:-}" "${C78:-}" && arm_refuses "${A80:-}" "${C80:-}" \
  && arm_refuses "${A83:-}" "${C83:-}" && ARMS_EXIT=1
# ⛔ EVERY REFUSAL ARM MUST CLEAR THE ROUND FLAGS, AND *THAT* WAS PINNED BY NOTHING (round-16 review,
# P3). The `(c4g)` scan above pins that the spend CALL is below these arms, but not what they DO:
# measured, deleting BOTH `REV_STARTED=0` and `AGENT_STARTED=0` from the load arm, and both from the
# fork/127 arm, EACH left the suite GREEN at 191/0. With both flags left at 1 the EXIT hook
# (`review_round_spend_at_exit`, which requires `REV_STARTED=1` AND `AGENT_STARTED=1`) spends a round
# for a reviewer that never ran — ten load refusals burn MAX_REVIEW=10 with ZERO reviews and park the PR
# with `REVIEW-CEILING … rounds=10/10`, the false diagnosis this whole change exists to close.
# ⛔ THE ARMS THAT FIRE **AFTER** `pi` WAS LAUNCHED (76, 78/127) NEED BOTH FLAGS, because `run_agent`
# sets `AGENT_STARTED=1` before the spawn; the brief arm (80) returns before that, so `REV_STARTED=0`
# alone is the documented one-rule invariant there (`merge-one.sh` says so at the arm).
flags_cleared() { # <start> <close> <needs-agent-flag> <label>
  local body rc=1 need="the"
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { bad "$4: the arm could not be located, so its flags are unverified"; return 0; }
  # ⛔ WHOLE-LINE COMMENTS ARE FILTERED BEFORE THE STRIP, EXACTLY LIKE THE `(c4m)` SCANS (round-17
  # review, P3). `c4mc` only removes an INLINE `#` (it requires whitespace before it), so a column-0
  # comment survived it — measured: deleting BOTH real clears from the load arm and leaving the text in
  # a `# REV_STARTED=0` / `# AGENT_STARTED=0` comment left this suite GREEN at 195/0 while the arm
  # genuinely spent a round per refusal. That is the same decoy class round 17 closed next door, left
  # open here; the two scans must share BOTH halves of the strip or they can drift in the load-bearing
  # direction.
  body="$(sed -n "${1},${2}p" "$MW" | awk '!/^[ \t]*#/' | c4mc)"
  [ "${3:-0}" = "1" ] && need="both the"
  case "$body" in *'REV_STARTED=0'*) : ;; *) rc=0 ;; esac
  if [ "${3:-0}" = "1" ]; then case "$body" in *'AGENT_STARTED=0'*) : ;; *) rc=0 ;; esac; fi
  [ "$rc" -eq 1 ] && ok "$4 clears the round flag(s) it must, so a refusal cannot spend a round through the EXIT hook" \
    || bad "$4 does NOT clear $need round flag(s) — a refusal at this arm leaves REV_STARTED/AGENT_STARTED at 1, the EXIT hook then SPENDS a round for a reviewer that never ran, and MAX_REVIEW load/fork refusals burn the whole budget and park the PR with a false REVIEW-CEILING diagnosis"
}
flags_cleared "${A76:-}" "${C76:-}" 1 "(c4n) the LOAD refusal arm (rc 76 -> exit 75)"
flags_cleared "${A78:-}" "${C78:-}" 1 "(c4n) the FORK/127 refusal arm (rc 78/127)"
flags_cleared "${A80:-}" "${C80:-}" 0 "(c4n) the BRIEF refusal arm (rc 80)"
# ⛔ THE 83 ARM CLEARS BOTH, AND IS PINNED TO THE STRICTER FORM. The sync floor is decided by the
# SPAWN POINT before any agent runs, and the arm clears `REV_STARTED` AND `AGENT_STARTED` for it; an
# arm that cleared only `REV_STARTED` here would spend a round on a helper-deploy fault — the #3441
# defect, one code over.
flags_cleared "${A83:-}" "${C83:-}" 1 "(c4n) the HELPER/SYNC refusal arm (rc 83)"
# ── (c4o) A REPORT-ONLY BOX MUST NOT BANK A ROUND (fresh review of #3441, P2) ───────────────────────
# `MAX_REVIEW=0` means "this box buys no reviewer rounds". The controller's dispatch arm honours that by
# dispatching nothing and spending nothing; THIS ingress cannot dispatch-nothing (a direct caller —
# `chain-<N>`, `fix-one.sh`, `lane-merge.sh`, an operator — asked for the review, and inventing a refusal
# code for a policy knob would break readers that classify 3/75/80/127), but it MUST NOT SPEND either.
# Measured before the guard: book 10, MAX_REVIEW=0 → exit 0 and the book became 11. Restoring the knob
# then parks every such PR at `rounds=11/10` with a REVIEW-CEILING reason asserting a spent budget that
# nobody configured — the false-diagnosis class this whole change exists to close, manufactured by the
# knob that was supposed to be inert.
RRSPEND="$TMP/rrspend.sh"
# ⛔ `$MW` (set near the top of this file), NOT `$MERGED_ONE_SH` — that one is assigned 100+ lines BELOW
# this block, and using it here left `$RRSPEND` empty: every `(c4o)` arm then reddened for the wrong
# reason and `(c4o) MAX_REVIEW=0 banks NO round` passed VACUOUSLY (an absent function writes nothing).
# Measured by the verifier before this line was corrected: 198/4 at every cap, with `sed: can't read :`
# in the log. An arm that cannot tell "the guard held" from "there is no writer" is not an arm.
sed -n '/^review_round_spend() {/,/^}$/p' "$MW" > "$RRSPEND"
# ⛔ AND ITS CALLEE, EXTRACTED HERE TOO (same ordering class, second variable). `$RRCEIL` — the suite's
# shared extract of the `[rrceiling]` block — is assigned 100+ lines BELOW this section, so sourcing it
# here left `_rr_report_only` UNDEFINED: `command not found`, the `if` went false, the guard was skipped
# and the writer banked a round. The NOHELPER sentinel cannot catch that one, because the WRITER is
# present — the arm looked like a genuine `book=11`. Measured by the verifier: 201/2 with this block
# reddening on its own. `$MW` and `$TMP` are both valid here; nothing else is assumed.
RRCEIL_O="$TMP/rrceiling.o.sh"
sed -n '/# \[rrceiling:begin\]/,/# \[rrceiling:end\]/p' "$MW" | sed '1d;$d' > "$RRCEIL_O"
# ⛔ AND THE WRITER'S OWN READER, FOR THE SAME ORDERING REASON AND ONE MORE (fresh review of #3441, P3).
# `review_round_spend` RE-READS the book before it writes (the refund fix below), so the shipped helper
# depends on `_rr_read_book` — which sits above it in merge-one.sh, unconditionally, so production always
# has it. A fixture that sourced only the writer therefore made every spend arm noisy with
# `_rr_read_book: command not found` (and the following `-ge` errored, leaving the write at the
# top-of-file value); `(c4t)` caught it as a stderr leak, which is exactly what that arm is for. Extracted
# HERE rather than at `(c4k)`, 400 lines below, so every arm that drives the writer can source it.
RRBOOK_O="$TMP/rrbook.o.sh"
sed -n '/^_rr_read_book() {/,/^}$/p' "$MW" > "$RRBOOK_O"
if [ -s "$RRSPEND" ]; then
  ok "(c4o) merge-one.sh::review_round_spend was extracted (declared)"
else
  bad "(c4o) review_round_spend could NOT be extracted from merge-one.sh — the report-only spend guard is unverified, and every arm below it would pass VACUOUSLY (an absent writer writes nothing, which looks exactly like a guard that held)"
fi
if [ -s "$RRSPEND" ] && ! grep -q '_rr_report_only' "$RRSPEND"; then
  bad "(c4o) review_round_spend does not consult _rr_report_only — a MAX_REVIEW=0 box banks a round for every direct-ingress review it buys, and a later restore of the knob parks those PRs with a false REVIEW-CEILING diagnosis"
elif [ -s "$RRSPEND" ]; then
  ok "(c4o) merge-one.sh::review_round_spend consults the report-only predicate before it writes"
fi
# ⛔ THE PREDICATE MUST ACTUALLY RESOLVE (not merely be named). A text grep inside the helper is not
# enough: the helper names it either way. This is the arm that would have caught the empty `$RRCEIL`.
if ( . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; command -v _rr_report_only >/dev/null 2>&1 ); then
  ok "(c4o) _rr_report_only RESOLVES from the [rrceiling] block — the spend helper's predicate is defined, not merely referenced"
else
  bad "(c4o) _rr_report_only does not resolve after sourcing the [rrceiling] block — the spend guard is INERT (the \`if\` fails and the writer banks a round) while looking pinned, so every MAX_REVIEW=0 box still fills the counter"
fi
rrspend() { # <max> <round> <book-seed> -> the book AS FOUND after the spend, or NOHELPER
  local d; d="$(mktemp -d)"; mkdir -p "$d/state"
  printf '%s\n' "$3" > "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  ( PR=777; L="$d/log"; _rr_f="$d/state/reviewround-777"; REVIEW_ROUND="$2"; MAX_REVIEW="$1"
    . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; . "$RRBOOK_O"; . "$RRSPEND"
    # ⛔ A MISSING WRITER MUST NOT LOOK LIKE A HELD GUARD (the vacuous pass the verifier measured): if the
    # extraction produced nothing, `review_round_spend` is undefined, the book is untouched, and the
    # "banks NO round" arm would be GREEN for the wrong reason. Say NOHELPER instead.
    if command -v review_round_spend >/dev/null 2>&1; then review_round_spend; else : > "$d/nohelper"; fi )
  if [ -f "$d/nohelper" ]; then printf 'NOHELPER\n'; else cat "$d/state/reviewround-777"; fi
  mv "$d" "$TMP/rrspend.spent.$RANDOM" 2>/dev/null || true
}
_got="$(rrspend 0 11 10)"
[ "$_got" = "10" ] && ok "(c4o) MAX_REVIEW=0 (REPORT-ONLY) banks NO round — the book is left at 10 for a round-11 spend" \
  || bad "(c4o) MAX_REVIEW=0 BANKED a round (book=$(printf '%s' "$_got"), expected 10) — a box configured to buy no reviewer rounds fills the counter it is then restored against"
_got="$(rrspend "$CAP" "$CAP" $(( CAP - 1 )))"
[ "$_got" = "$CAP" ] && ok "(c4o) a NORMAL box still banks the round (book $(( CAP - 1 )) -> $CAP) — the report-only guard does not disarm the spend" \
  || bad "(c4o) a normal MAX_REVIEW=$CAP box did NOT bank the round (book=$(printf '%s' "$_got")) — the report-only guard is too wide and the ceiling is now inert everywhere"
_got="$(rrspend garbage 11 10)"
[ "$_got" = "11" ] && ok "(c4o) a GARBAGE MAX_REVIEW still banks (book 10 -> 11) — an unreadable knob fail-closes toward the ceiling, never toward a free budget" \
  || bad "(c4o) a GARBAGE MAX_REVIEW did not bank (book=$(printf '%s' "$_got")) — an unreadable knob must coerce to the documented default 10, never to report-only"
# ⛔ THE WRITE RE-DERIVES THE FLOOR FROM A FRESH READ (fresh review of #3441, P3, MEASURED REFUND).
# `$REVIEW_ROUND` is computed at the TOP of merge-one.sh, while the ceiling check that runs before the
# spend reads the book FRESH "because a concurrent reviewer on this box may have written the book
# since". Both were shipped at once, so the write could put the LOWER top-of-file value back over a
# HIGHER one another reviewer had just written — refunding a round, the mirror of the `max()` floor.
# The arm drives exactly that interleaving: round CAP-1 in hand, another writer already at CAP+3. The
# shipped write must land CAP+4. MUTANT (measured): delete the re-derive block from the extracted
# helper and this arm reds with the book back at CAP-1.
_got="$(rrspend "$CAP" $(( CAP - 1 )) $(( CAP + 3 )))"
[ "$_got" = "$(( CAP + 4 ))" ] && ok "(c4o) a book a CONCURRENT writer moved ahead is never overwritten: round $(( CAP - 1 )) against a book of $(( CAP + 3 )) lands $(( CAP + 4 )), not a REFUND back to $(( CAP - 1 ))" \
  || bad "(c4o) the spend wrote the TOP-OF-FILE round over a higher book (book=$(( CAP + 3 )) -> $(printf '%s' "$_got"), expected $(( CAP + 4 ))) — the counter moves BACKWARDS, so each such interleaving refunds a round and the per-PR ceiling is loose by exactly as many as happen"
# ⛔ AND THE WRITER'S CLAMPS, WHICH WERE PINNED BY NOTHING (fresh review of #3441, P3). Both READERS
# coerce a 10-digit book (the `(c4j)`/`(c4k)` arms BELOW drive both readers), so a writer that EMITS one is invisible until a
# reader launders it. The reachable one is the SPEND'S OWN clamp, not the top-of-file one: the ceiling
# check reads the book once, near the top, and the spend re-reads it afterwards, so a book that reached
# 999999999 during an already-allowed review hands `+ 1` a 10-digit candidate. MUTANT (measured): delete
# the `[ "${#REVIEW_ROUND}" -gt 9 ] && REVIEW_ROUND=999999999` line INSIDE the re-derivation block and
# this arm reds with `1000000000`. ⛔ THE TOP-OF-FILE `if` IS NOT THIS ARM'S MUTANT, and the reason is
# mechanical rather than semantic (fresh review of #3441, P3): that line executes BEFORE the helper and
# is not inside the extracted function, so deleting it leaves the driven helper BYTE-IDENTICAL — the arm
# cannot observe it at all. (An earlier version of this comment gave a different reason — that the
# in-spend clamp clamps first — which is measurably wrong: the in-spend clamp sits inside its own `if`
# and cannot touch a value arriving from the top-of-file assignment.)
_got="$(rrspend "$CAP" 5 999999999)"
[ "$_got" = "999999999" ] && ok "(c4o) the WRITER clamps a spend on a book already at the 9-digit ceiling back to 999999999, never emitting a 10-digit value for a reader to launder" \
  || bad "(c4o) the spend wrote a 10-digit book ($(printf '%s' "$_got"), expected 999999999) — the reachable clamp (the one inside the re-derivation) is gone, so the writer emits a numeral its own readers must coerce and its 9-digit invariant is false"
sed 's/if _rr_report_only "${MAX_REVIEW:-}"; then/if false; then/' "$RRSPEND" > "$TMP/rrspend.rev.sh"
diff -q "$RRSPEND" "$TMP/rrspend.rev.sh" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  M6="$( . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; . "$RRBOOK_O"; . "$TMP/rrspend.rev.sh"
         d="$(mktemp -d)"; mkdir -p "$d/state"; printf '10\n' > "$d/state/reviewround-777"
         ( PR=777; L="$d/log"; _rr_f="$d/state/reviewround-777"; REVIEW_ROUND=11; MAX_REVIEW=0; review_round_spend )
         cat "$d/state/reviewround-777"; mv "$d" "$TMP/rrspend.rev.spent.$RANDOM" 2>/dev/null || true )"
  [ "${M6:-}" = "11" ] && ok "MUTANT-M6: reverting the report-only guard makes MAX_REVIEW=0 bank a round again (book 10 -> 11) — (c4o)'s first arm would report ❌" \
    || bad "MUTANT-M6 did not behave as a mutant (book=${M6:-<empty>}) — the arm above proves nothing"
else
  bad "MUTANT-M6 changed nothing — the report-only anchor no longer matches review_round_spend, so the arm above proves nothing"
fi
# PLACEMENT: the guarded ingress CALL sits below every refusal arm's closing `fi` (any arm order), and
# nothing but comments leaves the script between the last arm and that call.
# ⛔ THE WRITE MUST LIVE **INSIDE** THE HELPER (round 12 review, P2). Round 11 compared only the
# CALL site against the refusal arms and merely required `W_LINE > HELPER_LINE`. So the printf could be
# lifted OUT of the helper and dropped directly above the load arm — W_COUNT stays 1, CALL_LINE still
# sits below every arm, every other component still satisfied — and a load refusal spends a round
# again (the exact round-11 defect), suite GREEN. Measured. The write, not merely the call, has to be
# the helper's own body.
HELPER_END="$(awk -v a="${HELPER_LINE:-0}" 'NR>a && /^}$/ {print NR; exit}' "$MW" 2>/dev/null)"
# ⛔ COUNT THE CALL SITES TOO (round 13 review, P2). Pinning the WRITE and ONE anchored call left the
# CALLERS unobserved: inserting a second spend above the load arm — `review_round_spend` bare, or
# `[ "${AGENT_STARTED:-0}" = "1" ] && review_round_spend` — kept W_COUNT=1, the write inside the helper
# and CALL_LINE below every arm, so the suite stayed GREEN while a load refusal spent a round (the
# round-11 P1 again). There are exactly THREE non-comment mentions by design: the DEFINITION, the EXIT
# HOOK's call, and the guarded INGRESS call. Anything else is a new spender.
SPEND_COUNT="$(awk '!/^[[:space:]]*#/ && /review_round_spend([^_]|$)/ {n++} END{print n+0}' "$MW" 2>/dev/null)"
PLACE_OK=0
if [ -n "$CALL_LINE" ] && [ -n "$LAST_CLOSE" ] && [ "$LAST_CLOSE" -gt 0 ] \
   && [ "$CALL_LINE" -gt "$LAST_CLOSE" ] && [ "$ARMS_EXIT" = "1" ] && [ "$A78_OK" = "1" ] \
   && [ "${SPEND_COUNT:-0}" = "3" ] \
   && [ -n "$W_LINE" ] && [ -n "$HELPER_LINE" ] && [ -n "$HELPER_END" ] \
   && [ "$W_LINE" -gt "$HELPER_LINE" ] && [ "$W_LINE" -lt "$HELPER_END" ] \
   && ! awk -v a="$LAST_CLOSE" -v b="$CALL_LINE" 'NR>a && NR<b && !/^[[:space:]]*#/ && /(^|[^[:alnum:]_])(exit|exec|return|die)[[:space:](]/ {print; found=1} END{exit !found}' "$MW" >/dev/null; then
  PLACE_OK=1
fi
# THE TRAP PATH: the hook is defined BEFORE `run_agent` (a helper defined after the call it must guard
# is unreachable from the trap — the round-9 defect) and registered FIRST on the trap, ahead of the
# recorder whose real definition sits far below.
# ⛔ AND NO LATER `trap … EXIT` MAY SUPERSEDE IT (round 12 review, P2). `merge-one.sh` re-registers
# its EXIT trap twice (`rm -f "$CLAIM"`, then the claim-release pair), so moving the hook trap UP — a
# legal-looking position, still before `run_agent` — silently replaces it and a TERM'd reviewer never
# pays. Measured: 159/0 with the hook trap at the top of the file. The hook's registration must be the
# LAST EXIT registration before the review starts.
# ⛔ ANY LINE THAT MENTIONS BOTH `trap` AND `EXIT`, not only a line BEGINNING with `trap` (round 13
# review, P3): the first version missed a one-line helper that registers the trap (`_rearm() { trap
# 'rm -f "$CLAIM"' EXIT; }`) and is CALLED in the window, which measurably replaced the hook while the
# suite stayed green. ⚠️ STATED RESIDUAL: a function DEFINED above the window and merely CALLED inside
# it still escapes any text scan — the natural form (a third inline re-registration, as at the two
# sites in `merge-one.sh`) is caught, which is what this pin is for.
SUPERSEDING_TRAPS="$(awk -v a="${TRAP_LINE:-0}" -v b="${R_LINE:-0}" 'NR>a && NR<b && !/^[[:space:]]*#/ && /trap/ && /EXIT/ {n++} END{print n+0}' "$MW" 2>/dev/null)"
GUARD_OK=0
# ⛔ THE TRAP MUST BE REGISTERED **BEFORE** `run_agent`, NOT MERELY EXIST (round 11 review, P2).
# Moving the `trap … EXIT` line below the review left the earlier bare `trap 'rm -f "$CLAIM"' EXIT` in
# force during the review, so a TERM mid-review never reached the hook — the round-9 dead-code defect
# again, with the suite green. Ordering is the whole property.
if [ -n "$HOOK_LINE" ] && [ -n "$HELPER_LINE" ] && [ -n "$R_LINE" ] && [ -n "$TRAP_LINE" ] \
   && [ "$HELPER_LINE" -lt "$HOOK_LINE" ] && [ "$HOOK_LINE" -lt "$R_LINE" ] \
   && [ "$TRAP_LINE" -lt "$R_LINE" ] && [ "${SUPERSEDING_TRAPS:-1}" = "0" ]; then
  GUARD_OK=1
fi
if [ "$PLACE_OK" = "1" ] && [ "$GUARD_OK" = "1" ] && [ "${W_COUNT:-0}" = "1" ]; then
  ok "(c4g) merge-one.sh is the ONLY round writer; the guarded ingress call sits BELOW all four refusal arms (each of which really exits); the round-spend helper is defined ABOVE run_agent so the EXIT trap can reach it; and the trap hook is registered BEFORE the recorder whose real definition is far below"
else
  bad "(c4g) round-writes=$W_COUNT write=${W_LINE:-<none>} helper=${HELPER_LINE:-<none>} hook=${HOOK_LINE:-<none>} trap=${TRAP_LINE:-<none>} ingress-call=${CALL_LINE:-<none>} reviewer-start=${R_LINE:-<none>} load-arm=${A76:-<none>} fork-arm=${A78:-<none>} fork-arm-ok=$A78_OK brief-arm=${A80:-<none>} last-arm-close=${LAST_CLOSE:-<none>} arms-exit=$ARMS_EXIT spend-sites=$SPEND_COUNT superseding-traps=${SUPERSEDING_TRAPS:-?} guard-ok=$GUARD_OK place-ok=$PLACE_OK — the round writer is duplicated (expected exactly 1), the guarded ingress call is missing or sits ABOVE a refusal arm (a refusal would then spend a round for a reviewer that never ran), the helper/hook is defined after run_agent (the EXIT trap cannot reach it), or the trap hook is not registered first: $(awk -v a="${LAST_CLOSE:-0}" -v b="${CALL_LINE:-0}" 'NR>a && NR<b && !/^[[:space:]]*#/ && /(^|[^[:alnum:]_])(exit|exec|return|die)[[:space:](]/ {printf "%s:%s ", NR, $0}' "$MW")"
fi
# …and the CONTROLLER must not write it at ALL, and must not carry a dormant second writer either
# (round-3 review P1 for the call site; fresh review of #3441 P2 for the dead function). A call site in
# the arm means the dispatch pays before the worker exists; a DEFINITION with no failure handling is a
# fail-open waiting for the next lane to wire it back in. Both are defects, so the scan asserts the
# name is ABSENT — not merely uncalled.
# ⛔ NO PIPE INTO A QUIET GREP (#841/#864 — `scripts/check-no-sigpipe-grep.sh` caught the first version of
# this arm): capture the non-quiet producer, then test in the shell.
_rrc_calls="$(awk '!/^[[:space:]]*#/ && /review_round_record/ {print FILENAME":"FNR": "$0}' "$ORCH")"
case "$_rrc_calls" in
  *[![:space:]]*) bad "(c4g2) orch-loop.sh still CARRIES review_round_record (a call site, or a dead second writer with no write-failure handling): $(printf '%s' "$_rrc_calls" | head -2 | tr '\n' ';')" ;;
  *) ok "(c4g2) orch-loop.sh neither CALLS nor DEFINES review_round_record — the dispatch cannot spend a round before the reviewer runs, and no dormant second writer exists to be re-wired" ;;
esac

# ── (c4h–c4j) THE TWO READERS OF THE ROUND BOOK MUST FAIL CLOSED, ON BOTH INGRESSES ──────────────────
# ⛔ TWO OPEN FINDINGS FROM THE FRESH REVIEW OF #3441, both fail-open in the same direction: a review the
# ceiling exists to refuse was still bought.
#   * merge-one.sh never consulted `MAX_REVIEW` at all. `orch-loop.sh` refuses on its DISPATCH arm, but
#     `chain-<N>` / `fix-one.sh` / `lane-merge.sh` / a hand-run operator reach merge-one DIRECTLY, so the
#     documented bound ("exact for controller-dispatched reviews, delayed by at most one direct review")
#     was one nobody enforced. (c4h)/(c4i) pin the decision and its call site.
#   * `review_round_read` coerced a CORRUPT or OVERSIZED book to `0` — i.e. garbage read as "nothing spent
#     yet", resetting the budget. (c4j) pins the coercion, and `merge-one.sh::_rr_read_book` coerces the
#     same way because two readers of one file must not disagree.
MERGED_ONE_SH="$(dirname "$ORCH")/merge-one.sh"
RRCEIL="$TMP/rrceiling.sh"
sed -n '/# \[rrceiling:begin\]/,/# \[rrceiling:end\]/p' "$MERGED_ONE_SH" | sed '1d;$d' > "$RRCEIL"
if [ -s "$RRCEIL" ] && grep -q '_rr_ceiling_hit' "$RRCEIL"; then
  ok "(c4h) merge-one.sh carries the [rrceiling] block — the DIRECT ingress consults the round ceiling"
else
  bad "(c4h) the [rrceiling] block is MISSING from merge-one.sh, so only the controller's dispatch arm bounds the round budget and a direct/chain/fix-one review buys round n+1 past it"
fi
# Drive the decision itself. ⛔ THE ARMS ARE DERIVED FROM `CAP`, NOT HARDCODED (#3441 round-2 P2): a box
# pinned to 4 or 12 is an ordinary box.
rr_drive() { # <book> <max> -> prints REFUSE|allow
  # shellcheck disable=SC1090
  ( . "$RRCEIL"; if _rr_ceiling_hit "$1" "$2"; then echo REFUSE; else echo allow; fi )
}
for pair in "$(( CAP - 1 )):$CAP:allow" "$CAP:$CAP:REFUSE" "$(( CAP + 1 )):$CAP:REFUSE" \
            "0:0:allow" "0:$CAP:allow" "garbage:$CAP:REFUSE" \
            "999999999:$CAP:REFUSE" "1000000000:$CAP:REFUSE"; do
  b="${pair%%:*}"; rest="${pair#*:}"; m="${rest%%:*}"; want="${rest#*:}"
  got="$(rr_drive "$b" "$m")"
  [ "$got" = "$want" ] && ok "(c4h) book=$b max=$m -> $want" \
    || bad "(c4h) book=$b max=$m -> $got, expected $want — got the opposite decision, so the round ceiling FAILS OPEN on this ingress"
done
# ⛔ A BAD `max` FALLS BACK TO THE DOCUMENTED DEFAULT — NOT TO 0 AND NOT TO `garbage`. Asserting the
# decision on `$CAP:garbage` would encode the SHIPPED DEFAULT 10 (it reads `allow` on a box with
# `MAX_REVIEW=4`, i.e. a false red), so this arm compares the two answers instead of stating one.
if [ "$(rr_drive "$CAP" garbage)" = "$(rr_drive "$CAP" 10)" ] && [ "$(rr_drive 10 garbage)" = "REFUSE" ]; then
  ok "(c4h) a GARBAGE max is coerced to the documented default 10 (same decision as max=10, not to 0/allow)"
else
  bad "(c4h) a GARBAGE max is not coerced to 10: garbage=$(rr_drive "$CAP" garbage) max10=$(rr_drive "$CAP" 10) book10/garbage=$(rr_drive 10 garbage) — an unresolvable knob must fall back to the documented default, never to 'allow everything'"
fi
# ⛔ AND THE BOUNDARY FROM BELOW, WHICH IS THE HALF THE ARM ABOVE CANNOT SEE (round-16 review, P3).
# The comparison above holds for ANY fallback >= 10 and for any fallback that is `allow` at $CAP, so a
# coercion default of 3 stayed GREEN at `DRIVE_MAX_REVIEW=10` and `=12` — i.e. unpinned exactly where
# the suite ships. `book=9` against a garbage max separates 10 from 3: at 10 it is `allow` (9 < 10), at 3
# it is REFUSE. Measured: shipped → allow; `max=3` mutant → REFUSE.
if [ "$(rr_drive 9 garbage)" = "allow" ]; then
  ok "(c4h) a GARBAGE max is a fallback ABOVE 9 (so a 9-round book is still allowed) — the default is not a small number that would park a PR early"
else
  bad "(c4h) a GARBAGE max refuses a book of 9 — the coercion fell back to a SMALL ceiling (3?), so on a box whose MAX_REVIEW is unreadable a PR parks after a few rounds instead of 10, with a REVIEW-CEILING reason asserting a budget that was never the configured one"
fi
# ── (c4p) THE TERMINAL LINE'S `rounds=<n>/<max>` FIELD MUST CARRY THE COERCED MAX (fresh review of
# #3441, P2). The DECISION coerces a garbage / oversized `MAX_REVIEW` through `_rr_coerce_max`, but the
# park reason and the log echo printed the RAW knob — so the one machine-read line read
# `REVIEW-CEILING 4242 rounds=10/garbage` while the decision it reported used 10: a line that
# DISAGREES with the refusal it describes, and a non-numeric field in the format README §4 documents.
# `orch-loop.sh` cannot reach this (it normalises `MAX_REVIEW` at startup); `merge-one.sh` has no such
# early normalisation, so it must coerce at the one place it reads.
# ⛔ TWO HALVES, AND ONLY THE FIRST IS BEHAVIOURAL (stated, not implied): the coercion table below
# drives the SHIPPED block, and the shape pin after it requires the assignment site to go THROUGH that
# coercion. A residual remains — a future edit that coerced correctly and then re-read the raw knob
# somewhere else in the message is caught by nothing here.
rr_coerce_drive() { # <knob> -> the coerced max, from the SHIPPED block
  # shellcheck disable=SC1090
  ( . "$RRCEIL"; _rr_coerce_max "$1" )
}
COERCE_BAD=0
for pair in "garbage:10" "09:10" "00:10" "0:0" "$CAP:$CAP" "1000000000:10" ":10"; do
  k="${pair%%:*}"; want="${pair#*:}"
  got="$(rr_coerce_drive "$k")"
  [ "$got" = "$want" ] || { COERCE_BAD=1; bad "(c4p) MAX_REVIEW='$k' coerces to '$got', expected '$want'"; }
done
[ "$COERCE_BAD" = "0" ] && ok "(c4p) _rr_coerce_max maps garbage / leading-zero / oversized / empty to the documented default 10 and keeps only the exact '0' as REPORT-ONLY — the same rule is_limit/is_num applies, so both ingresses coerce one knob one way"
RC_MAX_ASSIGN="$(grep -nE '^_rr_max=' "$MERGED_ONE_SH" | head -1)"
RC_MAX_RHS="${RC_MAX_ASSIGN#*_rr_max=}"
case "$RC_MAX_RHS" in
  '"$(_rr_coerce_max'*) ok "(c4p) the ceiling's max is assigned THROUGH _rr_coerce_max (:${RC_MAX_ASSIGN%%:*}), so the line cannot print the raw knob again" ;;
  *) bad "(c4p) _rr_max is assigned from the RAW knob (${RC_MAX_ASSIGN:-<none>}) — the REVIEW-CEILING field can then disagree with the decision that produced it (rounds=10/garbage)" ;;
esac
# ── (c4q) THE BOOK WRITE MUST BE ATOMIC — SIBLING, THEN RENAME (fresh review of #3441, P2) ────────
# A `printf` redirected STRAIGHT ONTO the counter TRUNCATES before it writes, and BOTH readers coerce
# an EMPTY book to 999999999 on purpose (an unreadable book is corruption, never round 0), so a
# controller reading inside that window PARKS A HEALTHY PR with `REVIEW-CEILING … rounds=999999999/10`
# and a reason asserting a budget nobody spent. A rename is atomic, so no reader can see a partial
# book. ⛔ THIS IS A SHAPE PIN, AND IT IS THE RIGHT KIND HERE: the property ("the bytes never become
# visible under the counter's name until they are complete") is a property of HOW the file is written,
# not of what a caller can observe in a test — there is no deterministic way to lose a race on demand
# in this suite. What it removes is the regression that reintroduces the window, and MUTANT-Q below
# in this suite. What it removes is the regression that reintroduces the window, and MUTANT-Q below
# proves it can fail. ⛔ AND IT READS COMMENT-STRIPPED SOURCE, NOT THE EXTRACTED TEXT AS-IS (fresh review
# of #3441, P3 — MEASURED DECOY): the badge above used to claim extraction made comment text
# unusable, but extraction drops the block ABOVE the function, not the comments INSIDE it, and the
# helper is full of them. Restoring the truncating write AND adding one `#` comment inside the helper
# carrying both literals left this arm GREEN (207/2, the second red being MUTANT-Q's moved anchor). The
# strip is the SAME `c4mc`-style one `(c4m)`/`(c4n)` use, so the scans cannot drift.
RRSPEND_CODE="$(awk '!/^[[:space:]]*#/' "$RRSPEND" 2>/dev/null | c4mc)"
RR_ATOMIC=0
if [ -n "$RRSPEND_CODE" ] \
   && grep -qF 'printf '\''%s\n'\'' "$REVIEW_ROUND" > "$_rr_new"' <<<"$RRSPEND_CODE" \
   && grep -qF 'mv "$_rr_new" "$_rr_f"' <<<"$RRSPEND_CODE"; then
  RR_ATOMIC=1
  ok "(c4q) the round book is written to a SIBLING and RENAMED onto the counter — a reader can never observe a torn (empty) book, which both readers would read as 999999999 and park a healthy PR"
else
  bad "(c4q) review_round_spend does NOT write the book atomically — a `printf` straight onto the counter truncates before it writes, a concurrent reader coerces the empty book to 999999999, and a healthy PR parks with a false REVIEW-CEILING rounds=999999999/10 diagnosis"
fi
# ⛔ (c4r) THE FAILURE BRANCH MUST STILL BE REACHABLE, AND A DIRECTORY IS HOW IT BECOMES UNREACHABLE
# (fresh review of #3441, P2 — a REGRESSION THE ATOMIC WRITE INTRODUCED). `mv` onto an existing
# DIRECTORY moves the temp INSIDE it and exits 0, so the `|| { rm -f …; echo … CANNOT BE WRITTEN … }`
# group never fires: the temp is left behind, the log says nothing, and `_rr_read_book` coerces the
# directory to 999999999 — the false `REVIEW-CEILING … rounds=999999999/10` park this atomicity exists
# to prevent, reached by a non-torn route, with `_rr_written=1` suppressing the EXIT-hook retry.
# Driven BEHAVIOURALLY against the SHIPPED helper (so it needs no mutant: dropping the `[ ! -d ]`
# guard reddens it — that is the defect this arm was written from, measured at 209/0 -> ❌ here).
rrspend_bookdir() { # -> "named=<0|1> temps=<n>" for a DIRECTORY planted at the counter path
  local d; d="$(mktemp -d)"; mkdir -p "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  ( PR=777; L="$d/log"; _rr_f="$d/state/reviewround-777"; REVIEW_ROUND=7; MAX_REVIEW=10
    . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; . "$RRBOOK_O"; . "$RRSPEND"
    review_round_spend 2>/dev/null || true
    n=0; grep -qF 'CANNOT BE WRITTEN' "$d/log.log" 2>/dev/null && n=1
    printf 'named=%s ' "$n"
    # ⛔ COUNTED ANYWHERE UNDER state/, not just as a sibling: `mv` onto a DIRECTORY moves the temp
    # INSIDE it, so a sibling-only count reads 0 on the very failure this arm exists for (measured).
    t="$(find "$d/state" -name 'reviewround-777.new.*' 2>/dev/null | wc -l | tr -d ' ')"
    printf 'temps=%s\n' "$t" )
  mv "$d" "$TMP/rrspend.dir.spent.$RANDOM" 2>/dev/null || true
}
RR_DIR="$(rrspend_bookdir)"
case "$RR_DIR" in
  'named=1 temps=0') ok "(c4r) an UNWRITABLE counter (a directory at the path) is NAMED in the log and leaves NO temp file behind — the failure branch is reachable, so the operator is not left with a silent false REVIEW-CEILING" ;;
  *) bad "(c4r) an unwritable counter is NOT reported cleanly ($RR_DIR, expected named=1 temps=0) — a directory at state/reviewround-<PR> makes the rename move the temp INSIDE it and exit 0, so the failure group never fires: the log says nothing, a temp file is left under state/, and the next reader coerces the book to 999999999 and parks a healthy PR with a false REVIEW-CEILING rounds=999999999/10" ;;
esac
# ⛔ (c4r2) A FAILED WRITE MUST NOT REPORT A SPEND (verifier of THIS fix round, P1-class). The fix for the
# EXIT recorder's unconditional "round N spent" echo added an `_rr_banked` flag — and the FIRST version of
# that fix set it AFTER the `||` chain, so the FAILURE branch (which had no `return`) fell THROUGH to it:
# a write that provably did not land still marked the round banked, and the recorder printed
# "review round N spent by the EXIT recorder" directly beside "CANNOT BE WRITTEN — book UNCHANGED". That
# is the exact defect the flag was added to close, reintroduced by its own plumbing — so it gets an arm,
# driven through the SHIPPED recorder on BOTH no-bank shapes. Measured before the `return 0` in the
# failure branch: `dir: named=1 spent=1` and `ro: spent=1` on the report-only box, both GREEN over a book
# that never moved; `spent=` was named nowhere in this suite.
RRSPEND_EXIT="$TMP/rrspend.exit.sh"
awk '/^review_round_spend_at_exit\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MW" > "$RRSPEND_EXIT"
rrspend_exit_shape() { # <dir|ro> -> "named=<0|1> spent=<0|1>" for a spend that does NOT bank
  local d; d="$(mktemp -d)"; mkdir -p "$d/state"
  [ "$1" = "dir" ] && mkdir -p "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  ( PR=777; L="$d/log"; _rr_f="$d/state/reviewround-777"; REVIEW_ROUND=7; REV_STARTED=1; AGENT_STARTED=1
    if [ "$1" = "ro" ]; then MAX_REVIEW=0; else MAX_REVIEW=10; fi
    . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; . "$RRBOOK_O"; . "$RRSPEND"; . "$RRSPEND_EXIT"
    command -v review_round_spend_at_exit >/dev/null 2>&1 || { printf 'NOHELPER\n'; exit 0; }
    review_round_spend_at_exit 2>/dev/null || true
    n=0; grep -qF 'CANNOT BE WRITTEN' "$d/log.log" 2>/dev/null && n=1
    s=0; grep -qF 'spent by the EXIT recorder' "$d/log.log" 2>/dev/null && s=1
    printf 'named=%s spent=%s\n' "$n" "$s" )
  mv "$d" "$TMP/rrspend.exit.spent.$RANDOM" 2>/dev/null || true
}
[ -s "$RRSPEND_EXIT" ] || bad "(c4r2) review_round_spend_at_exit could NOT be extracted from merge-one.sh — the recorder's spend echo is unverified, so both arms below are vacuous"
RR_EX_DIR="$(rrspend_exit_shape dir)"
RR_EX_RO="$(rrspend_exit_shape ro)"
[ "$RR_EX_DIR" = 'named=1 spent=0' ] && ok "(c4r2) a FAILED write (directory at the counter) is NAMED and the EXIT recorder claims NO spend — a grep for 'spent' finds nothing, because the book never moved" \
  || bad "(c4r2) a FAILED write reported ($RR_EX_DIR, expected named=1 spent=0) — a spend the book never recorded is greppable in the log beside its own CANNOT BE WRITTEN line: the false-report class this change removes, manufactured by the flag added to remove it"
[ "$RR_EX_RO" = 'named=0 spent=0' ] && ok "(c4r2) a REPORT-ONLY box (MAX_REVIEW=0) banks nothing and the EXIT recorder claims NO spend — the two log lines no longer contradict each other" \
  || bad "(c4r2) the REPORT-ONLY shape reported ($RR_EX_RO, expected named=0 spent=0) — the recorder still prints 'round N spent' on a box whose book it deliberately leaves untouched"
# ⛔ (c4s) THE MESSAGE MUST STATE THE REAL CONSEQUENCE AND A REPAIR THAT WORKS (fresh review of #3441,
# P2). The first version of that line said "the per-PR round ceiling cannot be counted on this path (the
# per-head budget still binds)" — which reads as an INERT bound. What actually happens is the OPPOSITE
# and worse: both readers coerce the unreadable book to 999999999, so the next cycle PARKS the PR with
# `REVIEW-CEILING rounds=999999999/10` and a reason claiming a spent budget nobody spent. And the state
# had NO exit: every clear site and both printed remedies said `rm -f`, which cannot remove a DIRECTORY.
# Three claims, each pinned: the message names the false-park consequence, it names a repair, and the
# repair is `rm -rf`.
RR_MSG_LINE="$(awk '/review round counter .*CANNOT BE WRITTEN/ && !/^[[:space:]]*#/' "$MERGED_ONE_SH" | head -1)"
case "$RR_MSG_LINE" in
  *999999999*) ok "(c4s) the write-failure message names the REAL consequence (a false REVIEW-CEILING park at rounds=999999999) instead of claiming an inert bound" ;;
  *) bad "(c4s) the write-failure message does not name the false-park consequence — an operator reads 'the ceiling cannot be counted here' as 'the bound is inert', while both readers actually coerce the unreadable book to 999999999 and park the PR on the NEXT cycle" ;;
esac
case "$RR_MSG_LINE" in
  *'rm -rf'*) ok "(c4s) …and the repair it names is rm -rf (rm -f cannot remove the DIRECTORY that is the corruption most likely to cause it)" ;;
  *) bad "(c4s) the write-failure message names no working repair (no rm -rf) — the state it describes has no exit that the operator is told about, so a directory at the counter outlives every documented remedy" ;;
esac
# ⛔ (c4t) THE FAILURE PATH MUST NOT LEAK TO STDERR (fresh review of #3441, P3 — MEASURED). Redirections
# apply LEFT TO RIGHT, so `printf … > "$_rr_new" … 2>/dev/null` CANNOT retract the shell's own
# `Permission denied` / `No such file or directory` for that redirect: it was already printed with the
# ORIGINAL stderr. Driven against the SHIPPED helper on both unwritable shapes.
rrspend_stderr() { # <shape: readonly|missing> -> the bytes the helper wrote to stderr
  local d; d="$(mktemp -d)"; mkdir -p "$d/state"
  case "$1" in
    readonly) chmod 500 "$d/state" ;;   # the redirect into it must fail
    missing)  rmdir "$d/state" ;;       # no parent at all
  esac
  # shellcheck disable=SC1090
  ( PR=777; L="$d/log"; _rr_f="$d/state/reviewround-777"; REVIEW_ROUND=7; MAX_REVIEW=10
    . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$RRCEIL_O"; . "$RRBOOK_O"; . "$RRSPEND"
    review_round_spend ) 2>&1 >/dev/null
  chmod 700 "$d/state" 2>/dev/null || true
  mv "$d" "$TMP/rrspend.err.spent.$RANDOM" 2>/dev/null || true
}
RR_STDERR="$(rrspend_stderr readonly)$(rrspend_stderr missing)"
if [ -z "$RR_STDERR" ]; then
  ok "(c4t) a failed book write leaks NOTHING to stderr on either unwritable shape (read-only state/, missing state/) — the operator gets the log line, not a bare shell error beside it"
else
  bad "(c4t) a failed book write LEAKS to stderr: [$(printf '%s' "$RR_STDERR" | tr '\n' ';' | cut -c1-160)] — the redirect is not grouped, so the shell prints the redirect's own error before the trailing 2>/dev/null can apply"
fi
# MUTANT-Q: reintroduce the truncating spelling in a COPY and require the pin above to red. Mutation
# tested rather than asserted, because "the write is atomic" is exactly the kind of claim a later tidy
# silently reverts while every behavioural arm stays green.
MWQ="$TMP/mutant-nonatomic.sh"
# ⛔ THE ANCHOR IS THE printf LINE ONLY (the write moved into a group, so the old
# `> "$_rr_new" 2>/dev/null` spelling no longer exists). An unaddressed sed would ALSO rewrite the
# `mv` line's SOURCE and the mutant would fail its own "still renames onto the counter" precondition.
sed '/printf .%s.n. "\$REVIEW_ROUND"/s|> "\$_rr_new"|> "\$_rr_f"|' "$MERGED_ONE_SH" > "$MWQ"
diff -q "$MERGED_ONE_SH" "$MWQ" >/dev/null 2>&1; q_rc=$?
if [ "$q_rc" -ne 0 ]; then
  sed -n '/^review_round_spend() {/,/^}$/p' "$MWQ" > "$TMP/q-helper.sh"
  if grep -qF 'mv "$_rr_new" "$_rr_f"' "$TMP/q-helper.sh" \
     && ! grep -qF 'printf '\''%s\n'\'' "$REVIEW_ROUND" > "$_rr_new"' "$TMP/q-helper.sh"; then
    ok "MUTANT-Q: with the SIBLING redirect reverted to the counter itself, (c4q)'s pin reports ❌ — the atomicity assertion is live"
  else
    bad "MUTANT-Q did not remove the sibling redirect (the sed anchor stopped matching), so (c4q) proves nothing"
  fi
else
  bad "MUTANT-Q produced an UNCHANGED file (the sed anchor stopped matching) — (c4q) is unverified"
fi
# MUTANT-P: the raw knob back on the ceiling line must red (c4p)'s shape pin.
MWP="$TMP/mutant-rawmax.sh"
sed 's|^_rr_max="$(_rr_coerce_max "${MAX_REVIEW:-}")"$|_rr_max="${MAX_REVIEW:-10}"|' "$MERGED_ONE_SH" > "$MWP"
RP_ASSIGN="$(grep -nE '^_rr_max=' "$MWP" | head -1)"
RP_RHS="${RP_ASSIGN#*_rr_max=}"
case "$RP_RHS" in
  '"$(_rr_coerce_max'*) bad "MUTANT-P did not revert the assignment (the sed anchor stopped matching) — (c4p) is unverified" ;;
  *) ok "MUTANT-P: with the ceiling's max read from the RAW knob, (c4p)'s shape pin reports ❌ — the message field is pinned to the coerced value" ;;
esac
# ⛔ AND THE CALL SITE, NOT JUST THE FUNCTION — a correct predicate that nothing calls is the round-3
# defect in a new place. The check must sit ABOVE the reviewer start (`REV_STARTED=1`), because below it
# the round is already being paid for, and its refusal must NOT be `exit 75` (whose readers report a
# CAPACITY refusal and would send an operator to wait for a quieter box, which cannot clear a spent budget).
RC_CALL="$(awk '!/^[[:space:]]*#/ && /_rr_ceiling_hit "/ {print FNR}' "$MERGED_ONE_SH" | head -1)"
RC_START="$(awk '!/^[[:space:]]*#/ && /^REV_STARTED=1$/ {print FNR}' "$MERGED_ONE_SH" | head -1)"
RC_EXIT="$(awk -v a="${RC_CALL:-0}" '/^[[:space:]]*#/ {next} NR>a && /^[[:space:]]*exit 3$/ {print NR; exit}' "$MERGED_ONE_SH")"
if [ -n "$RC_CALL" ] && [ -n "$RC_START" ] && [ "$RC_CALL" -lt "$RC_START" ] && [ -n "$RC_EXIT" ] \
   && awk -v a="$RC_CALL" -v b="$RC_EXIT" 'NR>a && NR<b && !/^[[:space:]]*#/' "$MERGED_ONE_SH" | grep -q 'park "REVIEW-CEILING'; then
  ok "(c4i) the ceiling is consulted at merge-one.sh:$RC_CALL — ABOVE the reviewer start (:${RC_START}) so no round is paid for — and the refusal parks a REVIEW-CEILING reason and exits 3, not 75"
else
  bad "(c4i) merge-one.sh ceiling call=${RC_CALL:-<none>} reviewer-start=${RC_START:-<none>} exit3=${RC_EXIT:-<none>} — the DIRECT ingress does not refuse at the ceiling, refuses AFTER the round is paid for, or refuses with a code whose readers report a capacity refusal"
fi
# Mutants for the decision — the same rule M1/M2 follow: derived FROM the shipped block, and each is
# asserted to have really changed the file.
sed 's/\[ "\$book" -ge "\$max" \]/[ "$book" -gt "$max" ]/' "$RRCEIL" > "$TMP/rrceiling.m3.sh"
diff -q "$RRCEIL" "$TMP/rrceiling.m3.sh" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  M3="$( . "$TMP/rrceiling.m3.sh"; if _rr_ceiling_hit "$CAP" "$CAP"; then echo REFUSE; else echo allow; fi )"
  [ "$M3" = "allow" ] && ok "MUTANT-M3: '>=' widened to '>' lets a book AT the ceiling buy the next round (allow) — (c4h)'s book=$CAP/$CAP arm would report ❌" \
    || bad "MUTANT-M3 did not behave as a mutant (got $M3) — the arm above proves nothing"
else
  bad "MUTANT-M3 changed nothing — the -ge anchor no longer matches the shipped block, so the arm above proves nothing"
fi
sed 's/\[ "\$max" -ge 1 \] || return 1/:/' "$RRCEIL" > "$TMP/rrceiling.m4.sh"
diff -q "$RRCEIL" "$TMP/rrceiling.m4.sh" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  M4="$( . "$TMP/rrceiling.m4.sh"; if _rr_ceiling_hit 0 0; then echo REFUSE; else echo allow; fi )"
  [ "$M4" = "REFUSE" ] && ok "MUTANT-M4: dropping the report-only guard makes MAX_REVIEW=0 refuse EVERY round — (c4h)'s 0/0 arm would report ❌ (the knob would mean the opposite of REPORT-ONLY)" \
    || bad "MUTANT-M4 did not behave as a mutant (got $M4)"
else
  bad "MUTANT-M4 changed nothing — the report-only guard anchor no longer matches, so the arm above proves nothing"
fi
# (c4j) THE READER MUST FAIL CLOSED ON A CORRUPT BOOK. Garbage read as round 0 = a FULL budget, i.e. the
# ceiling RESETS on exactly the input that should stop it.
rrread() { # <file-content|__ABSENT__> -> n
  local d; d="$(mktemp -d)"; mkdir -p "$d/state"
  [ "$1" = "__ABSENT__" ] || printf '%s' "$1" > "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  ( O="$d"; . "$TMP/reviewround.sh"; review_round_read 777 )
  # ⛔ `mv`, NOT `rm` (#709): the guard refuses a discard whose target is a temp path.
  mv "$d" "$TMP/rrread.spent.$RANDOM" 2>/dev/null || true
}
rr_case() { # <label> <content> <want>
  local got; got="$(rrread "$2")"
  [ "$got" = "$3" ] && ok "(c4j) $1 -> $3" \
    || bad "(c4j) $1 -> $got, expected $3 — an unreadable book must coerce to the 9-digit ceiling (fail-closed), never to 0 (which RESETS the budget)"
}
rr_case "an ABSENT book is round 0 (nothing spent yet)" '__ABSENT__' 0
rr_case "a NON-NUMERIC book is the 9-digit ceiling, not 0" 'garbage' 999999999
rr_case "an OVERLONG book is the 9-digit ceiling, not 0" '1000000000' 999999999
rr_case "an EMPTY book is the 9-digit ceiling, not 0" '' 999999999
rr_case "a NEGATIVE book is the 9-digit ceiling, not 0" '-3' 999999999
rr_case "a plain book is still read as itself" "$(( CAP - 1 ))" "$(( CAP - 1 ))"
# …and it must be EXHAUSTED at the coerced value, which is the whole point of not resetting it.
printf 'garbage\n' > "$ROUND_F"
# ⛔ `islimit.sh` MUST BE SOURCED HERE TOO: `review_round_exhausted` coerces its `<max>` argument with
# `is_limit`, so an UNRESOLVABLE `is_limit` would silently fall back to 10 and this arm would grade the
# SHIPPED DEFAULT instead of the cap the suite is driven at (green at 10, a false red at 4 or 12).
# ⛔ AND `isnum.sh` WITH IT — `is_limit` is `is_num … && [ len -le 9 ]`, so sourcing `islimit.sh` ALONE
# leaves `is_num` undefined: `is_limit` fails on `command not found`, `|| max=10` masks it, and this arm
# graded 10 on EVERY cap while printing `is_num: command not found` to the log (measured by the round-17
# verifier: one line per run, at all four caps). A dependency sourced two-thirds of the way is a guard
# grading something other than what it claims.
if ( O="$TMP/O"; . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$TMP/reviewround.sh"; review_round_exhausted 4242 "$CAP" ); then
  ok "(c4j) a CORRUPT book is EXHAUSTED at MAX_REVIEW=$CAP — the controller refuses the next review instead of buying a free one"
else  bad "(c4j) a CORRUPT book does NOT read as exhausted at MAX_REVIEW=$CAP — the ceiling RESET, which is the fail-open the coercion removes"
fi
clear_round
# ⛔ THE CONTROLLER'S HALF OF THE FROM-BELOW BOUNDARY (round-17 review, P3). The `book=9` arm above drives
# `merge-one.sh::_rr_ceiling_hit` ONLY — the controller has its OWN `max` coercion
# (`orch-loop.sh::review_round_exhausted`: `is_limit "${max:-}" || max=10`) and it was unpinned from
# below: changing that fallback to 3 left the suite GREEN at `DRIVE_MAX_REVIEW` 4, 10 AND 12 (measured).
# A 3 there parks a controller-dispatched PR after three rounds with a REVIEW-CEILING reason asserting a
# budget nobody configured — the false diagnosis #3441 exists to close, on the higher-volume ingress.
rr_exh() { # <max-arg> <book> -> REFUSE|allow, through the SHIPPED controller predicate
  local got
  seed_round "$2"
  if ( O="$TMP/O"; . "$TMP/isnum.sh"; . "$TMP/islimit.sh"; . "$TMP/reviewround.sh"; review_round_exhausted 4242 "$1" ); then got=REFUSE; else got=allow; fi
  clear_round
  printf '%s\n' "$got"
}
# Absolute book values, deliberately NOT derived from $CAP: the question is what a GARBAGE knob falls back
# TO, and the answer (10) is the shipped default rather than the cap the suite is driven at.
for _pair in "9:allow" "10:REFUSE"; do
  _b="${_pair%%:*}"; _want="${_pair#*:}"; _got="$(rr_exh garbage "$_b")"
  [ "$_got" = "$_want" ] && ok "(c4j) controller: a GARBAGE max is coerced to the documented default 10 (book=$_b -> $_want)" \
    || bad "(c4j) controller: a GARBAGE max on a book of $_b -> $_got, expected $_want — the controller's fallback is not 10, so a box whose MAX_REVIEW is unreadable refuses rounds early (a small fallback) with a REVIEW-CEILING reason asserting a budget that was never configured, or buys past it (a large one)"
done
# (c4k) THE SECOND READER MUST FAIL CLOSED TOO — AND IT IS THE ONE NOBODY ELSE EXERCISES (round-14
# review, P2). `(c4j)` drives `orch-loop.sh::review_round_read`; `(c4h)` passes the book IN as an
# argument, so neither touches `merge-one.sh::_rr_read_book`, the function that reads the file on the
# DIRECT ingress. Measured before this arm: reverting that function to the old
# `is_limit "${v:-}" || v=0` — the exact defect this commit claims to fix — left the suite GREEN at
# 179/0. Two readers of ONE file that disagree is the failure the README row and the function's own
# comment both assert cannot happen, so the shared coercion has to be pinned on BOTH sides.
RRBOOK="$TMP/rrbook.sh"
sed -n '/^_rr_read_book() {/,/^}/p' "$MERGED_ONE_SH" > "$RRBOOK"
if [ -s "$RRBOOK" ] && grep -q '999999999' "$RRBOOK"; then
  ok "(c4k) merge-one.sh::_rr_read_book was extracted (declared)"
else
  bad "(c4k) _rr_read_book is MISSING from merge-one.sh — the direct ingress cannot read the round book, so it can neither spend nor refuse on it"
fi
rrbook() { # <file-content|__ABSENT__> -> n
  local d got; d="$(mktemp -d)"; mkdir -p "$d/state"
  [ "$1" = "__ABSENT__" ] || printf '%s' "$1" > "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  got="$( _rr_f="$d/state/reviewround-777"; . "$RRBOOK"; _rr_read_book )"
  printf '%s\n' "$got"
  mv "$d" "$TMP/rrbook.spent.$RANDOM" 2>/dev/null || true
}
rrb_case() { # <label> <content> <want>
  local got; got="$(rrbook "$2")"
  [ "$got" = "$3" ] && ok "(c4k) $1 -> $3" \
    || bad "(c4k) $1 -> $got, expected $3 — merge-one.sh's reader DISAGREES with orch-loop.sh's about the same file, so a corrupt book resets the budget on the direct ingress while the controller parks it"
}
rrb_case "merge-one: an ABSENT book is round 0" '__ABSENT__' 0
rrb_case "merge-one: a NON-NUMERIC book is the 9-digit ceiling" 'garbage' 999999999
rrb_case "merge-one: an OVERLONG book is the 9-digit ceiling" '1000000000' 999999999
rrb_case "merge-one: an EMPTY book is the 9-digit ceiling" '' 999999999
rrb_case "merge-one: a NEGATIVE book is the 9-digit ceiling" '-3' 999999999
rrb_case "merge-one: a plain book is still read as itself" "$(( CAP - 1 ))" "$(( CAP - 1 ))"
# ⛔ A NON-REGULAR BOOK IS A CORRUPTION, NOT AN ABSENT BOOK (round-15 review, P3). Both readers gated
# "absent ⇒ 0" on `[ -f ]`, so a stray DIRECTORY at `state/reviewround-<PR>` — the failure mode this
# tree's own remedies name, `rm -rf a stray directory named parked-$PR` — read as ABSENT: round 0, a FULL
# budget, while the README row says a corrupt book "reads as EXHAUSTED and parks, instead of RESETTING
# the budget". Measured before the fix: BOTH readers returned 0 and BOTH ingresses bought the round.
rrb_dir() { # <which: orch|merge> -> n, with a DIRECTORY standing in for the book
  local d got; d="$(mktemp -d)"; mkdir -p "$d/state/reviewround-777"
  case "$1" in
    orch) got="$( O="$d"; . "$TMP/islimit.sh"; . "$TMP/reviewround.sh"; review_round_read 777 )" ;;
    merge) got="$( _rr_f="$d/state/reviewround-777"; . "$RRBOOK"; _rr_read_book )" ;;
  esac
  printf '%s\n' "$got"
  mv "$d" "$TMP/rrdir.spent.$RANDOM" 2>/dev/null || true
}
for _r in orch merge; do
  _got="$(rrb_dir "$_r")"
  [ "$_got" = 999999999 ] && ok "(c4l) a NON-REGULAR book (a stray DIRECTORY) reads as the 9-digit ceiling in the $_r reader, not as round 0" \
    || bad "(c4l) the $_r reader read a DIRECTORY standing in for the book as $_got, expected 999999999 — a non-regular book is CORRUPTION, and treating it as ABSENT hands the PR a FULL budget (the reset the coercion above exists to prevent)"
done
# ⛔ THE OTHER NON-REGULAR BOOK DOES NOT FAIL CLOSED — IT HANGS (fresh review of #3441, P2, MEASURED).
# A DIRECTORY is caught only incidentally (the `read` fails, `v` stays empty, 999999999); a FIFO is
# `-e`-true and `read -r v < fifo` BLOCKS ON OPEN until a writer appears, so the coercion below is never
# reached. Measured on the pre-fix code: `rc=124` under a 5 s bound in BOTH readers — and in
# `orch-loop.sh` that reader is the CONTROLLER'S main loop, so the failure mode is the whole fleet loop
# wedging with no log line (the #943/#3331 false-silence class at fleet scale), not the fail-closed park
# the README promises. Both readers now gate on `-f`: absent ⇒ 0, non-regular ⇒ 999999999, never opened.
# ⛔ THE ARM IS BOUNDED ITSELF, because the failure it detects IS a hang: without a bound the suite would
# block instead of reporting ❌. A `kill -9` on the reader subshell is the only exit from a blocked FIFO
# open on every platform (`timeout`/`gtimeout` are not guaranteed where this suite runs).
rrb_fifo() { # <which: orch|merge> -> the reader's answer, or HANG
  local d out p i
  d="$(mktemp -d)"; mkdir -p "$d/state"; mkfifo "$d/state/reviewround-777"
  out="$TMP/rrfifo.out"
  rm -f "$out" 2>/dev/null || true
  case "$1" in
    orch)  ( O="$d"; . "$TMP/islimit.sh"; . "$TMP/reviewround.sh"; review_round_read 777 ) > "$out" 2>/dev/null & ;;
    merge) ( _rr_f="$d/state/reviewround-777"; . "$RRBOOK"; _rr_read_book ) > "$out" 2>/dev/null & ;;
  esac
  p=$!
  i=0
  while [ "$i" -lt 5 ] && [ ! -s "$out" ]; do sleep 1; i=$(( i + 1 )); done
  if [ -s "$out" ]; then wait "$p" 2>/dev/null; cat "$out";
  else kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; printf 'HANG\n'; fi
  mv "$d" "$TMP/rrfifo.spent.$RANDOM" 2>/dev/null || true
}
for _r in orch merge; do
  _got="$(rrb_fifo "$_r")"
  [ "$_got" = 999999999 ] && ok "(c4l) a FIFO standing in for the book reads as the 9-digit ceiling in the $_r reader — it is neither OPENED (which would block for ever) nor read as round 0" \
    || bad "(c4l) the $_r reader answered '$_got' for a FIFO at the book path, expected 999999999 — 'HANG' means the reader still OPENS a non-regular book (a fleet-wide wedge in the controller, worse than the park the docs promise), and any other value means it read corruption as a live budget"
done

# ── (c4m) THE BOOK'S LIFECYCLE IS PART OF THE BOUND, AND IT WAS PINNED BY NOTHING ────────────────────
# Round-15 review, P3. README and ARCHITECTURE both state the budget is "cleared on MERGED/CLOSED, by
# prune_orphan_markers, and by merge-one.sh::review_state_clear on a CLEAN verdict". Measured before
# these arms: deleting `reviewround-$PR` from `review_state_clear`'s `rm -f` and deleting
# `review_round_clear "$PR"` from the MERGED|CLOSED arm EACH left the suite at 186/0 GREEN. The
# CLEAN-verdict clear is the one that matters: without it a converged PR carries its spent rounds into
# its NEXT, unrelated round of work and parks with `REVIEW-CEILING … rounds=10/10`, asserting a budget
# it never spent — the false-diagnosis class #3441 exists to close, in the opposite direction.
#
# ⛔ EACH ARM IS A TEXT SCAN BECAUSE THE CODE PATHS ARE NOT DRIVABLE HERE (they need gh, the rail and a
# real signed marker). A text scan is weak on its own, so each one names the exact identifier whose loss
# is the defect, and each was mutant-verified: the mutant that deletes the line reddens its arm.
# ⛔ COMMENTS ARE STRIPPED FROM EVERY BODY SCANNED BELOW — WHOLE-LINE **AND** TRAILING — AND THAT IS THE
# WHOLE POINT OF THE STRIP. Two measured decoys, both of which the first version of these arms passed:
#   `: # review_round_clear "$PR"` (a call defanged behind a colon), and
#   `rm -f … 2>/dev/null || true   # was: "$O/state/reviewround-$PR"` (the path surviving only in a
#   trailing comment). `!/^[ \t]*#/` strips whole-line comments ONLY, so both left the suite GREEN at
#   191/0 while the CLEAN-verdict clear — the one that matters — cleared nothing. A text arm a comment
#   can satisfy is worse than no arm, because it reports coverage it does not have.
# `c4mc()` (defined at the top of this file) is the one strip, so all three scans below cannot drift
# from each other and from the refusal-arm scans in `(c4n)`.
_clear_body="$(awk '/^review_state_clear\(\) \{/{f=1} f&&!/^[ \t]*#/{print} f&&/^}/{exit}' "$MERGED_ONE_SH" | c4mc)"
case "$_clear_body" in
  *'"$O/state/reviewround-$PR"'*) ok "(c4m) merge-one.sh::review_state_clear clears state/reviewround-<PR> on a CLEAN verdict (the loop this bounds CONVERGED, so its spent rounds must not bound the next loop)" ;;
  *) bad "(c4m) review_state_clear does NOT clear state/reviewround-<PR> — a converged PR carries its spent rounds into its next round of work and parks with a REVIEW-CEILING reason asserting a budget it never spent" ;;
esac
_life="$(awk '/case "\$\{PR_ST:-\}" in MERGED\|CLOSED\)/{f=1} f&&!/^[ \t]*#/{print} f&&/^ *esac/{exit}' "$ORCH" | c4mc)"
case "$_life" in
  *'review_round_clear "$PR"'*) ok "(c4m) orch-loop.sh's MERGED|CLOSED arm clears the round book through its own helper (one lifecycle, one place — a hand-rolled rm beside it would be a second spelling)" ;;
  *) bad "(c4m) the MERGED|CLOSED arm does not call review_round_clear — a PR that left the queue keeps its round book for ever (one record per abandoned PR) and the stated lifecycle is false" ;;
esac
_prune="$(awk '/^prune_orphan_markers\(\) \{/{f=1} f&&!/^[ \t]*#/{print} f&&/^}/{exit}' "$ORCH" | c4mc)"
case "$_prune" in
  *'reviewround-*'*) ok "(c4m) prune_orphan_markers sweeps state/reviewround-* like every sibling marker family" ;;
  *) bad "(c4m) prune_orphan_markers does NOT sweep state/reviewround-* — the book accumulates one file per dead PR and the documented sweep is false" ;;
esac
# ⛔ AND IT MUST REMOVE THAT FAMILY THROUGH ITS OWNER, NOT WITH `rm -f` (fresh review of #3441, P2 —
# MEASURED). The family was added to the GLOB but the sweep still removed with a bare `rm -f` (and with
# no redirection at all). For a book that is a DIRECTORY — the corruption both readers park on — that
# fails (`Is a directory`, rc=1) and the `-ot` gate stays true for a dead PR, so the same error printed
# on EVERY cycle for ever while `README.md`'s "cleared … by prune_orphan_markers" stayed false. The arm
# above pins the FAMILY, not the verb; this one pins the verb. It reddens if the routing is reverted to
# `rm -f "$mf"` for the book (measured), and the behavioural `(c4u)` arm below proves the helper it
# routes through really does clear a directory.
case "$_prune" in
  *'review_round_clear "$mp"'*) ok "(c4u) prune_orphan_markers removes the round book through review_round_clear (the rm -rf owner), so a DIRECTORY book is swept instead of erroring every cycle" ;;
  *) bad "(c4u) prune_orphan_markers removes state/reviewround-* with a bare rm -f — a DIRECTORY book is never swept (the failure repeats every cycle for a dead PR) and the documented prune remedy is inert" ;;
esac
# ── (c4u) THE CORRUPTION BOTH READERS DETECT MUST HAVE AN EXIT (fresh review of #3441, P2) ────────
# Both readers treat a NON-REGULAR book as corruption and coerce it to 999999999, which PARKS the PR.
# A stray DIRECTORY at the path is exactly the corruption this tree's remedies name, and it is the one
# shape `rm -f` cannot remove (`Is a directory`, rc=1) — so with `rm -f` at every clear site, the state
# had NO exit at all: not the CLEAN-verdict clear, not MERGED/CLOSED, and not the repair the park text
# prints. The PR stayed parked at `rounds=999999999/10` for ever. Measured before the fix: the
# directory SURVIVED each of those clears.
# ⛔ THE CLEAR IS DRIVEN, NOT SCANNED: `review_round_clear` is extracted from the shipped controller.
rrclear_dir() { # -> "present|gone" for a DIRECTORY planted at the book path
  local d; d="$(mktemp -d)"; mkdir -p "$d/state/reviewround-777"
  # shellcheck disable=SC1090
  ( O="$d"; . "$TMP/islimit.sh"; . "$TMP/reviewround.sh"; review_round_clear 777 )
  if [ -e "$d/state/reviewround-777" ]; then printf 'present\n'; else printf 'gone\n'; fi
  mv "$d" "$TMP/rrclear.spent.$RANDOM" 2>/dev/null || true
}
RR_CLEARED="$(rrclear_dir)"
[ "$RR_CLEARED" = "gone" ] && ok "(c4u) a DIRECTORY standing at state/reviewround-<PR> is actually CLEARED by review_round_clear — the MERGED/CLOSED exit reaches the corruption the readers park on" \
  || bad "(c4u) review_round_clear LEFT the directory in place — \`rm -f\` cannot remove a directory and \`|| true\` hides the failure, so a PR parked at rounds=999999999/10 never clears: not on MERGED/CLOSED, and not through the remedy the park text prints"
# …and the CLEAN-verdict clear in merge-one.sh must use the same verb. A text pin, because that function
# needs the rail, gh and a signed marker to run; it names the exact spelling, like (c4m) does.
_rsc_body="$(awk '/^review_state_clear\(\) \{/{f=1} f&&!/^[ \t]*#/{print} f&&/^}/{exit}' "$MERGED_ONE_SH" | c4mc)"
case "$_rsc_body" in
  *'rm -rf'*'reviewround-'*) ok "(c4u) merge-one.sh::review_state_clear removes the book with rm -rf, so a converged PR whose counter became a DIRECTORY is not left permanently parked" ;;
  *) bad "(c4u) review_state_clear does not remove the book with rm -rf — the CLEAN-verdict clear (the one exit that matters) cannot remove a corrupt non-regular book, and the PR parks for ever with a REVIEW-CEILING reason asserting a budget nobody spent" ;;
esac
# …and BOTH printed remedies must name a verb that works. The park texts are strings, so this is the
# only pin available; it is worth having because the text is what an operator pastes.
# ⛔ THE SCAN IS RESTRICTED TO THE PARK LINES, AND THAT IS A FIX THIS ARM NEEDED (fresh review of #3441,
# P2 — MEASURED VACUOUS). Scanning the WHOLE file for `rm -rf … reviewround-` and taking `head -1`
# matched, in merge-one.sh, the WRITE-FAILURE message above the remedy (added by the same commit) rather
# than the `REVIEW-CEILING` park text in the ceiling arm — so reverting merge-one.sh's park remedy to
# `rm -f` left this suite GREEN (measured 217/0). That is baseline row 4 of
# `docs/ops/review-non-vacuity-baseline.md` in one file over: a phrase that another site prints
# unconditionally. The grep is now anchored on the `park`/`park_ctrl` call sites, so only a remedy that
# is actually printed to an operator can satisfy it; the mutant reverts EACH file in turn and both red.
for _f in "$MERGED_ONE_SH" "$ORCH"; do
  _park_txt="$(grep -E 'park(_ctrl)? ' "$_f" | grep -o 'rm -rf[^\"]*reviewround-[^\"]*' | head -1)"
  [ -n "$_park_txt" ] && ok "(c4u) $(basename "$_f")'s REVIEW-CEILING remedy prints rm -rf for the book (the verb that can remove a DIRECTORY)" \
    || bad "(c4u) $(basename "$_f")'s REVIEW-CEILING remedy (the text an operator PASTES) does not print a working rm -rf for the book — a corrupt (directory) book cannot be cleared with the remedy printed for it, so the documented repair is inert"
done
# MUTANT-U: revert EACH file's park remedy in turn and require this arm to red — PER FILE, because the
# vacuity above was exactly one file satisfying the other's row. The rewrite is applied ONLY to the park
# lines (awk, not a whole-file sed), so the write-failure message that caused the hole is untouched and
# the mutant reproduces the real regression rather than a blanket text change.
for _pair in "$MERGED_ONE_SH:merge-one" "$ORCH:orch-loop"; do
  _mfu="${_pair%%:*}"; _lbl="${_pair#*:}"
  awk '/park(_ctrl)? /{gsub(/rm -rf/,"rm -f")} {print}' "$_mfu" > "$TMP/parktxt.$_lbl.sh"
  _got="$(grep -E 'park(_ctrl)? ' "$TMP/parktxt.$_lbl.sh" | grep -o 'rm -rf[^\"]*reviewround-[^\"]*' | head -1)"
  if [ -z "$_got" ]; then
    ok "MUTANT-U: reverting $_lbl's park remedy to rm -f makes (c4u)'s row for it report ❌ — the per-file remedy pin is live"
  else
    bad "MUTANT-U could not strip $_lbl's park remedy (the park-line rewrite changed nothing), so (c4u)'s row for that file proves nothing"
  fi
done

# ── (c5) NON-VACUITY FOR THE CEILING — two mutants, because the arm makes TWO claims ──────────────
# The issue's acceptance is explicit: a mutant that SUPPRESSES the line must redden the suite. A suite
# that only asserted "something was parked" would stay green over a line that was never emitted, and
# the line IS the deliverable (the operator's diagnosis). Both mutants are derived FROM THE SHIPPED
# FILES so they track them, and both are asserted to have changed the file — a `sed` whose anchor
# stopped matching yields an unchanged file and would "prove" nothing.
cp "$TMP/reviewround.sh" "$TMP/reviewround.orig.sh"
cp "$TMP/arm.sh" "$TMP/arm.orig.sh"
# M1 — THE BOUND GOES INERT: the predicate never says "exhausted". This is the dangerous direction
# (a review is then bought past the ceiling for ever) and it must be visible as a SPAWN, not a park.
sed 's/-ge "\$max" ]$/-ge 999999999 ]/' "$TMP/reviewround.orig.sh" > "$TMP/reviewround.mut.sh"
diff -q "$TMP/reviewround.orig.sh" "$TMP/reviewround.mut.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ok_bad=$?
[ "$ok_bad" -eq 0 ] && ok "MUTANT-M1 really changed review_round_exhausted (the sed anchor still matches the shipped file)" \
  || bad "MUTANT-M1 did not change the file — the mutation anchor no longer matches, so the arm below proves nothing"
bash -n "$TMP/reviewround.mut.sh"; ck_m1=$?
[ "$ck_m1" -eq 0 ] && ok "MUTANT-M1 still parses (a program, not a syntax error that fails for the wrong reason)" \
  || bad "MUTANT-M1 does not parse — it fails for the wrong reason"
cp "$TMP/reviewround.mut.sh" "$TMP/reviewround.sh"
clear_parked; clear_store; clear_revdisp; clear_round; seed_round "$CAP"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && ! grep -q 'REVIEW-CEILING' "$TMP/d.log"; then
  ok "MUTATION-M1: with the ceiling INERT the PR buys the review anyway (spawns=1, no REVIEW-CEILING) — (c4b)'s 'refuses and parks' would report ❌"
else
  bad "MUTATION-M1 did not behave as a mutant: spawns=$(spawns) log=$(tr '\n' ';' < "$TMP/d.log")"
fi
cp "$TMP/reviewround.orig.sh" "$TMP/reviewround.sh"
# M2 — THE LINE GOES, THE PARK STAYS. This is the shape the issue names: a stop that is still a stop
# but no longer says WHY, i.e. "this PR exhausted its review budget" reading as "the queue stopped".
grep -v 'review-round budget EXHAUSTED, PARKED' "$TMP/arm.orig.sh" > "$TMP/arm.mut.sh"
diff -q "$TMP/arm.orig.sh" "$TMP/arm.mut.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "MUTANT-M2 really deleted the terminal line from the shipped arm" \
  || bad "MUTANT-M2 deleted nothing — the line it targets is gone or renamed, so the arm below proves nothing"
bash -n "$TMP/arm.mut.sh"; rc=$?
[ "$rc" -eq 0 ] && ok "MUTANT-M2 still parses" || bad "MUTANT-M2 does not parse"
cp "$TMP/arm.mut.sh" "$TMP/arm.sh"
clear_parked; clear_store; clear_revdisp; clear_round; seed_round "$CAP"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && ! grep -q 'REVIEW-CEILING' "$TMP/d.log"; then
  ok "MUTATION-M2: with the terminal line suppressed the review is still refused but the LOG SAYS NOTHING — (c4b)'s line assertion would report ❌ (the parked head would be a silent stop)"
else
  bad "MUTATION-M2 did not behave as a mutant: spawns=$(spawns) log=$(tr '\n' ';' < "$TMP/d.log")"
fi
cp "$TMP/arm.orig.sh" "$TMP/arm.sh"
clear_parked; clear_store; clear_revdisp; clear_round

# (c3) a FAILED spawn spends NOTHING — the `fixcount` rule, applied to the review budget
clear_parked; clear_store; clear_revdisp
drive 'FAILED:ai-review-gate' rail 0 0
# ⛔ `acts`/`waits`, NOT `spawns`: the stub records the ATTEMPT in `$TMP/spy` before it refuses, so a
# failed spawn still has a spy line (the suite's own existing rule: a failed spawn is a WAIT, never an
# act). The artifact under test here is the (PR, head) KEY, which must not exist at all.
if [ "$(acts)" = "0" ] && [ ! -e "$REV_DISP" ] && [ ! -e "$TMP/O/state/parked-4242" ] \
   && grep -q 're-record spawn FAILED' "$TMP/d.log"; then
  ok "(c3) a FAILED review spawn records NO attempt and parks NOTHING (bookkeep only on success)"
else
  bad "(c3) acts=$(acts) key-exists=$([ -e "$REV_DISP" ] && echo yes || echo no) log=$(tr '\n' ';' < "$TMP/d.log")"
fi

# (b3) the CAP line reports the SPEND, not the budget, when an operator LOWERS the limit
# (review of #2653, P2 — `CAP <n> <max>`: reading the LAST field reports max and is invisible while
# n == max, i.e. always at the default).
clear_store; seed_revdisp abc1234 3
drive 'FAILED:ai-review-gate' rail 0 1 0 CLEAN 2
if [ "$(spawns)" = "0" ] && grep -q 'REVIEW-CAP 3/2' "$TMP/d.log"; then
  ok "(b3) REVIEW-CAP prints 3/2 for a head that spent 3 with the limit lowered to 2"
else
  bad "(b3) log=$(tr '\n' ';' < "$TMP/d.log") — the cap line reports the budget as the spend"
fi

# (b4) a LEGACY record (`<pr>.json`, written when `--repo` was absent) is evidence too
# (review of #2653, P2 — merge-one.sh::record_at_head checks BOTH names for this reason).
clear_revdisp
printf '%s\n' '{"pr":4242,"head_sha":"abc1234","verdict":"clean","repo":"daniel-ospina/agent-infra"}' > "$TMP/home/.pi/agent/reviews/4242.json"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && grep -q 'REVIEW-AT-HEAD' "$TMP/d.log"; then
  ok "(b4) a LEGACY store record at this head also reads AT-HEAD (both names are consulted)"
else
  bad "(b4) spawns=$(spawns) log=$(head -2 "$TMP/d.log" | tr '\n' ';') — a legacy record bought a fresh review"
fi
mv "$TMP/home/.pi/agent/reviews/4242.json" "$TMP/legacy.spent.$RANDOM" 2>/dev/null || true

# (b5) AT-HEAD is bounded: the one state that neither dispatches nor parks must ESCALATE
# (review of #2653, P2 — otherwise it logs a wait row every cycle for ever).
clear_parked
printf '%s\n' '{"pr":4242,"head_sha":"abc1234","verdict":"clean","repo":"daniel-ospina/agent-infra"}' > "$STORE"
printf 'abc1234 3\n' > "$TMP/O/state/reviewathead-4242"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && grep -q 'REVIEW-AT-HEAD-STUCK 4/3' "$TMP/d.log" \
   && [ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ] \
   && grep -q 'record-review.sh 4242 abc1234 clean daniel-ospina/agent-infra' "$TMP/d.log" \
   && grep -q -- '--expect-head abc1234' "$TMP/d.log" \
   && grep -q 'LIFT THIS PARK' "$TMP/d.log"; then
  ok "(b5) AT-HEAD at the bound PARKS with REVIEW-AT-HEAD-STUCK, the exact re-record command AND its --expect-head pin, AND the park-lift (a re-record alone is provably inert)"
else
  bad "(b5) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log") — the recorded-review/red-gate state never escalates, its command was eaten by a backtick substitution, or the printed remedy mints UNPINNED"
fi
clear_store; mv "$TMP/O/state/reviewathead-4242" "$TMP/athead.spent.$RANDOM" 2>/dev/null || true

# (f) an UNREADABLE head spends nothing: a review is head-scoped evidence
# (review of #2653, P3 — an empty HEAD_N recorded a count under a key nobody can compare, then
# parked the PR claiming the budget when the cause was an API read).
clear_store; clear_revdisp
drive 'FAILED:ai-review-gate' rail 0 1 0 CLEAN 3 ""
if [ "$(spawns)" = "0" ] && [ ! -f "$REV_DISP" ] && grep -q 'HEAD is UNREADABLE' "$TMP/d.log"; then
  ok "(f) an unreadable head dispatches NOTHING and records NO attempt — the refusal names the head"
else
  bad "(f) spawns=$(spawns) key=[$(cat "$REV_DISP" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi

# (g) `MAX_REVIEW_TRIES=0` is REPORT-ONLY — no dispatch, and NOTHING parked (review round 3, P2:
# parking every NEEDS-REVIEW head on its first cycle would remove PRs from the sweep with a reason
# claiming a reviewer failure that never happened, and disagree with merge-one.sh's `0`).
clear_store; clear_revdisp; clear_parked
drive 'FAILED:ai-review-gate' rail 0 1 0 CLEAN 0
if [ "$(spawns)" = "0" ] && [ ! -e "$TMP/O/state/parked-4242" ] && grep -q 'MAX_REVIEW_TRIES=0 on this box (REPORT-ONLY' "$TMP/d.log"; then
  ok "(g) MAX_REVIEW_TRIES=0 is REPORT-ONLY: nothing dispatched, NOTHING parked, and the line says so"
else
  bad "(g) spawns=$(spawns) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi

# (h) an UNWRITABLE review budget is named and STOPS the loop (review round 3, P2). A swallowed write
# made the bound itself best-effort: the count read back as 0 for ever and the arm re-bought a paid
# review EVERY cycle with no REVIEW-CAP ever reached.
clear_store; clear_revdisp; clear_parked
mkdir -p "$TMP/O/state/reviewdisp-4242"      # a DIRECTORY of that name: the write cannot land
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && grep -q 'CANNOT BE WRITTEN' "$TMP/d.log" \
   && [ "$(cat "$TMP/O/state/parked-4242" 2>/dev/null)" = "abc1234" ]; then
  ok "(h) an unwritable budget record is NAMED and the head parks — the cap cannot be outrun silently"
else
  bad "(h) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi
mv "$TMP/O/state/reviewdisp-4242" "$TMP/revdisp.dir.$RANDOM" 2>/dev/null || true
clear_parked

# (i) an UNWRITABLE escalation counter must be NAMED, not silently coerced (review round 3, P2). A
# swallowed write restarts the count at 1 every cycle, so AT-HEAD could never escalate — the endless
# wait it exists to end, wearing a bounded-looking face.
clear_store; clear_parked
printf '%s\n' '{"pr":4242,"head_sha":"abc1234","verdict":"clean","repo":"daniel-ospina/agent-infra"}' > "$STORE"
mkdir -p "$TMP/O/state/reviewathead-4242"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && grep -q 'REVIEW-AT-HEAD-UNBOUNDED' "$TMP/d.log"; then
  ok "(i) an unwritable escalation counter says REVIEW-AT-HEAD-UNBOUNDED (an inert bound is never silent)"
else
  bad "(i) log=$(tr '\n' ';' < "$TMP/d.log") — the escalation silently restarted instead of naming itself"
fi
mv "$TMP/O/state/reviewathead-4242" "$TMP/athead.dir.$RANDOM" 2>/dev/null || true
clear_store; clear_parked

# (j) REPORT-ONLY OUTRANKS AT-HEAD (review round 4, P2). REPORT-ONLY sat AFTER the store check, so on a
# report-only box a head that already carried a CLEAN record took the AT-HEAD path — where `1 >= 0` is
# true — and PARKED on the first refusal as `REVIEW-AT-HEAD-STUCK 1/0`: a PR removed from the sweep with
# a reason naming a budget the box never had, contradicting "REPORT-ONLY: nothing dispatched, NOTHING
# parked". The sibling red-fixer role's rule is "REPORT-ONLY IS DECIDED BEFORE THE COUNTER IS READ".
clear_parked; clear_revdisp
printf '%s\n' '{"pr":4242,"head_sha":"abc1234","verdict":"clean","repo":"daniel-ospina/agent-infra"}' > "$STORE"
drive 'FAILED:ai-review-gate' rail 0 1 0 CLEAN 0
if [ "$(spawns)" = "0" ] && [ ! -e "$TMP/O/state/parked-4242" ] && grep -q 'REPORT-ONLY' "$TMP/d.log" \
   && ! grep -q 'REVIEW-AT-HEAD-STUCK' "$TMP/d.log"; then
  ok "(j) MAX_REVIEW_TRIES=0 outranks AT-HEAD: a recorded review is NOT parked on a report-only box"
else
  bad "(j) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi
clear_store; clear_parked

# (k) a PARK THAT DID NOT LAND is reported as what it is (review round 4, P2). The park IS the
# terminator: an unwritable `parked-<PR>` means the PR re-enters the arm every cycle while the log says
# PARKED. Same hazard class as (h)/(i), one level up — the one place rounds 2-3 did not look.
clear_store; seed_revdisp abc1234 3; clear_parked
mkdir -p "$TMP/O/state/parked-4242"          # a DIRECTORY of that name: the park cannot land
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "0" ] && grep -q 'PARK DID NOT LAND' "$TMP/d.log" && ! grep -q 'PARKED (an unfixable head' "$TMP/d.log"; then
  ok "(k) an unwritable PARK is named (PARK DID NOT LAND), never reported as PARKED"
else
  bad "(k) log=$(tr '\n' ';' < "$TMP/d.log")"
fi
mv "$TMP/O/state/parked-4242" "$TMP/parked.dir.$RANDOM" 2>/dev/null || true
clear_revdisp

# (l) A HEAD WITH FINDINGS NEVER REACHES THE REVIEW KEY (review round 5, P1). `_fix_eligible` is 0 when
# the FIXER ceiling is full, and the chain used to fall through into the review key — which would CAP
# and park that head with a reason claiming "the reviewer produced no usable verdict … a fixer has no
# findings", when `state/needsfix-<PR>-<head>` exists ON DISK. That parks a PR a fixer could still
# repair and points the operator at the wrong subsystem.
clear_store; clear_revdisp; clear_parked; seed_revdisp abc1234 3
NEEDSFIX=1; drive 'FAILED:ai-review-gate' rail 9 1; unset NEEDSFIX
if [ "$(spawns)" = "0" ] && [ ! -e "$TMP/O/state/parked-4242" ] && grep -q 'NO fixer slot' "$TMP/d.log" \
   && ! grep -q 'REVIEW-CAP' "$TMP/d.log"; then
  ok "(l) findings + a full fixer ceiling names the FIXER slot — the review budget never bounds a NEEDS-FIX head"
else
  bad "(l) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log")"
fi
mv "$TMP/O/state/needsfix-4242-abc1234" "$TMP/needsfix.l.spent.$RANDOM" 2>/dev/null || true
clear_revdisp; clear_parked

# (m) an unwritable budget AND an unwritable PARK: the branch must not claim PARKED (review round 5,
# P2) — that would be the inert bound wearing a green face, while the head buys another review.
clear_store; clear_revdisp; clear_parked
mkdir -p "$TMP/O/state/reviewdisp-4242" "$TMP/O/state/parked-4242"
drive 'FAILED:ai-review-gate' rail 0 1
if [ "$(spawns)" = "1" ] && grep -q 'PARK DID NOT LAND' "$TMP/d.log" && ! grep -q '(PARKED)' "$TMP/d.log"; then
  ok "(m) budget unwritable AND park unwritable: PARK DID NOT LAND, and the line does not claim PARKED"
else
  bad "(m) log=$(tr '\n' ';' < "$TMP/d.log")"
fi
mv "$TMP/O/state/reviewdisp-4242" "$TMP/revdisp.m.dir.$RANDOM" 2>/dev/null || true
mv "$TMP/O/state/parked-4242" "$TMP/parked.m.dir.$RANDOM" 2>/dev/null || true

# (d) the review-LANE cap still binds, and the refusal NAMES its holders and their age
clear_store; clear_revdisp
clear_workers; drive 'FAILED:ai-review-gate' rail 9 1
# ⛔ THE NUMERATOR IS PINNED AT 9 (review round 12 of #2653): `wt_table` also counts worker-named TMUX
# sessions that have no record of their own, and on a box where the controller is RUNNING those are
# real — which is why this assertion was briefly widened to `[0-9]+`. The cause is fixed in the fixture
# now (the host's tmux is stubbed out in `drive`, and `clear_workers` removes the records a previous
# drive's spawn left), so the count IS the 9 merge lanes the `lanes-in-use` knob writes, and pinning it
# also keeps the census's OVER-count regression class (a worker counted more than once — this file's own
# `w:`/`t:`/name triple) from passing as "the ceiling was reached anyway".
if [ "$(spawns)" = "0" ] && grep -Eq 'NO re-record slot \(review lanes=9/9' "$TMP/d.log" \
   && grep -q 'holding: merge-0(120m)' "$TMP/d.log"; then
  ok "(d) review-lane ceiling reached => refused, and the line names the lanes holding it WITH their age"
else
  bad "(d) spawns=$(spawns) state=[$(ls "$TMP/O/state" | grep -c '^worker-' )] files=[$(ls "$TMP/O/state" | grep '^worker-' | tr '\n' ',')] log=$(tr '\n' ';' < "$TMP/d.log") — a count with no owner is the state that hid the stall"
fi

# (e) once the review is recorded the MERGE path is reached, and the issue path's own rule opens
#     with it: the review queue is what held it, so an empty un-owned count is the only open state.
drive GREEN rail 0 1
if [ "$(spawns)" -ge 1 ] && [ "$(acts)" -ge 1 ] && ! grep -q 'REVIEW-AT-HEAD\|NO re-record slot' "$TMP/d.log"; then
  ok "(e) the head now merges (rail spawn) — the review arm is no longer the PR's state at all"
else
  bad "(e) spawns=$(spawns) log=$(head -2 "$TMP/d.log" | tr '\n' ';') — the PR never left the review queue"
fi
# shellcheck disable=SC1090
. "$TMP/mpreason.sh"
# ⛔ `is_num` IS A DEPENDENCY OF `mp_reason`, NOT DECORATION: undefined it is `command not found`, so
# EVERY count reads UNREADABLE and the rule always holds the issue path shut — the assertion below
# would then "pass" for the wrong reason on the `1` case and fail on the `0` case.
# shellcheck disable=SC1090
. "$TMP/isnum.sh"
[ -z "$(mp_reason 0 0 0)" ] \
  && ok "(e) …and with NO un-owned PR the drain rule has no reason: the ISSUE PATH IS OPEN" \
  || bad "(e) mp_reason 0 still holds the issue path shut: [$(mp_reason 0 0 0)]"
[ -n "$(mp_reason 1 0 0)" ] \
  && ok "(e) …while one un-owned PR still holds it (the rule is threshold-free, unchanged)" \
  || bad "(e) mp_reason 1 named no reason — the gate that closes the issue path is inert"

echo
echo "=== T1b: a cycle that acted on nothing must SAY so (never 'dispatching') ==="
# The funnel is a separate artifact (live-ownership.sh::lo_select) — it is driven by its own suite,
# live-ownership.test.sh §8(d)-(f). Here we assert the orchestrator half: the ledger exists for the
# PR, and the parent summariser turns it into words.
sed -n '/# \[prdisp-apply:begin\]/,/# \[prdisp-apply:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/apply.sh"
# ⛔ THE SHIPPED OWNERSHIP PREDICATE IS DRIVEN, NOT STUBBED (#2831, review P2). An earlier version of
# T9 re-implemented the PRE-change guard in a stub, so the five arms were exercised against a
# predicate that no longer ships: a shipped `pr_owner_live` that always returned 1 (the #2831 defect
# itself) would have passed. This extraction is the real function from the loop, driven with the
# fixture's own `sess`/`claim_live` answers.
sed -n '/^pr_owner_live() {/,/^}/p' "$ORCH" > "$TMP/owner-live.sh"
grep -q 'pl_verdict' "$TMP/owner-live.sh" || bad "the shipped pr_owner_live() could not be extracted — T9 would grade a stub"
if [ -s "$TMP/apply.sh" ] && grep -q 'no per-PR read this cycle' "$TMP/apply.sh"; then
  # One counted PR the sweep never saw (a 304 / scope-filtered row) must still be NAMED.
  apply() { # apply <OPEN_ROWS> <SWEEP_LIST> [<row the SWEEP already wrote>]
    mkdir -p "$TMP/O/state"; : > "$LEDGER"
    (
      O="$TMP/O"; LOG="$TMP/d.log"; SCOPE_MODE=BROAD
      OPEN_ROWS="$1"; SWEEP_LIST="$2"
      # `pr_owned` is the count's own ownership predicate: 9999 is OWNED in this fixture, so it must
      # never appear as a wait (an owned PR is not work this box owes).
      pr_owned() { [ "$1" = "9999" ] && return 0; return 1; }
      # shellcheck disable=SC1090
      . "$TMP/disp.sh"          # truncates the ledger, exactly as the shipped parent does
      # the sweep's own row, as the subshell would have written it
      [ -n "${3:-}" ] && printf '%s\n' "$3" >> "$TMP/O/state/prdisp.tsv"
      # shellcheck disable=SC1090
      . "$TMP/apply.sh"
    ) >/dev/null 2>&1
  }
  apply "7777:abc:fix/x 8888:def:feat/y" ""
  [ "$(waits)" = "2" ] && [ "$(acts)" = "0" ] \
    && ok "T2: on a 304 (no swept rows) BOTH counted un-owned PRs are recorded — none is invisible" \
    || bad "T2: 304 cycle left counted PRs unnamed (waits=$(waits) acts=$(acts))"
  awk -F'\t' '$1==8888 && $4=="wait" && $5 ~ /no per-PR read/' "$LEDGER" | grep -q . \
    && ok "…and the reason is the honest one (no per-PR read this cycle), not a guessed class" \
    || bad "…the 304 wait reason is wrong: $(reason)"
  apply "7777:abc:fix/x 8888:def:feat/y" "7777	abc	false" "$(printf '7777\tabc\tGREEN\tact\tmerged (gate authority)')"
  [ "$(waits)" = "1" ] && awk -F'\t' '$1==7777 && $4=="act"' "$LEDGER" | grep -q . \
    && ok "T2: a SWEPT row is not double-recorded (the parent only fills the gaps)" \
    || bad "T2: the parent overwrote or duplicated a swept row (waits=$(waits))"
  awk -F'\t' '$1==8888 && $5 ~ /not in this cycle.s swept set/' "$LEDGER" | grep -q . \
    && ok "…and the un-swept row is named as scope-filtered (the real mechanism, not 'unknown')" \
    || bad "…the un-swept reason is wrong: $(reason)"
  # …and an OWNED PR is never recorded: the invariant is about the COUNTED (un-owned) set, and a row
  # for an owned PR would inflate the waits into a number that means nothing.
  apply "9999:aaa:feat/mine 7777:abc:fix/x" ""
  [ "$(waits)" = "1" ] && ! awk -F'\t' '$1==9999' "$LEDGER" | grep -q . \
    && ok "an OWNED open PR is not in the ledger (the waits count un-owned PRs only)" \
    || bad "an owned PR was recorded as a wait (waits=$(waits)) — the number would not mean what it says"
else
  bad "the [prdisp-apply] block is missing — counted-but-unswept PRs have no path to a reason"
fi

echo
echo "=== T3: one PR gets ONE ledger row, and a second act is DISCLOSED ==="
# `FAILED:ai-review-gate,python-ci-gate` spawns a fixer AND reruns CI in one cycle. Removing one is a
# PRECEDENCE decision (#2126, residual), so the change is (a) say it, and (b) keep ONE row per PR —
# an appended second row made the summary report two PRs for one and turned a zero-spawn cycle into
# "1 acted" (review P1). This drives the SHIPPED arm chain with a real needsfix marker and a real
# python-ci-gate row, so both paths actually fire.
NEEDSFIX=1 PYCI=1 drive 'FAILED:ai-review-gate,python-ci-gate' rail 0 1
[ "$(spawns)" = "1" ] && [ "$(rows)" = "1" ] && [ "$(acts)" = "1" ] && [ "$(waits)" = "0" ] \
  && ok "a fixer + a CI rerun in one cycle: 1 spawn, 1 ROW, 1 act (no double row, no phantom second PR)" \
  || bad "double-act cycle: spawns=$(spawns) rows=$(rows) acts=$(acts) waits=$(waits) — the record and the spawns disagree"
grep -q 'DOUBLE ACT this cycle' "$TMP/d.log" \
  && ok "…and the double act is DISCLOSED in the log (residual stated, not hidden)" \
  || bad "…the double act is still undisclosed"

echo
echo "=== The summariser: what the cycle SAYS about the PR path ==="
# The `[pr]` line is the artifact an operator reads, and it was untested (review P2). Driven on a
# fixture ledger, so each of its four states is exercised for real.
sed -n '/# \[prsum:begin\]/,/# \[prsum:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/sum.sh"
if [ -s "$TMP/sum.sh" ] && grep -q 'PR path:' "$TMP/sum.sh"; then
  summarise() { # summarise <ledger-bytes> <PRDISP_OK> <POP> <UPN_WORK> [<refusal-rows>|0] [<refusal-file>]
    : > "$TMP/s.log"; printf '%s' "$1" > "$TMP/s.tsv"
    # The refusal record the launcher writes (worker-terminal.sh → wt_refusal_record). The controller
    # truncates it before the sweep; the fixture writes exactly the rows a refused cycle produced —
    # unless a 6th argument hands over a REAL record (the writer's own output), which is the only way
    # an end-to-end assertion can be about the writer rather than about this fixture.
    mkdir -p "$TMP/O/state"
    if [ -n "${6:-}" ]; then
      cp "$6" "$TMP/O/state/spawn-refused.tsv" 2>/dev/null || : > "$TMP/O/state/spawn-refused.tsv"
    else
      : > "$TMP/O/state/spawn-refused.tsv"
      _ri=0
      while [ "$_ri" -lt "${5:-0}" ]; do
        printf 'fix-90%s\tcmux layout apply failed: database or disk is full\n' "$_ri" >> "$TMP/O/state/spawn-refused.tsv"
        _ri=$(( _ri + 1 ))
      done
    fi
    (
      O="$TMP/O"; LOG="$TMP/s.log"; PRDISP="$TMP/s.tsv"; PRDISP_OK="$2"; POP="$3"; UPN_WORK="$4"
      SPAWNREF="$TMP/O/state/spawn-refused.tsv"
      SCOPE_MODE=BROAD; FLOOR_NOTE=""; PR_FIRST_TOK=""
      # CYCLE_T0 is the SPAWN BASELINE the shipped block reads. Unset, the reader must say UNMEASURED
      # rather than "NONE" — driven by the `summarise_u` case below.
      if [ "${5+x}" = x ]; then CYCLE_T0="$5"; fi
      WT_DIR="$TMP/O/state"; WT_TABLE_TTL=0
      # shellcheck disable=SC1090
      . "$HERE/worker-terminal.sh"
      cmux() { printf '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}\n'; return 0; }
      . "$TMP/isnum.sh"
      . "$TMP/spawns.sh"
      . "$TMP/sum.sh"
      printf 'FIRSTTOK=%s\nSPAWNS=%s\n' "$PR_FIRST_TOK" "${PRDISP_SPAWNS:-}"
    ) > "$TMP/s.tok" 2>&1
  }
  summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3
  grep -q '1 acted (#11)' "$TMP/s.log" \
    && ok "an acting cycle: '1 acted (#11)' and the PR it acted on" \
    || bad "the acting summary lost its act: $(cat "$TMP/s.log")"
  summarise "$(printf '11\tabc\tGREEN\twait\tparked at this head — needs a human\n')" 1 open-rows 3
  grep -q 'NO UNIT SPAWNED this cycle — 1 row(s) with a named reason' "$TMP/s.log" \
    && ok "an idle cycle: NO UNIT SPAWNED, with the wait count and the dominant reason" \
    || bad "the idle summary does not name the state: $(cat "$TMP/s.log")"
  # ⛔ THE DEFERRED MAJORITY MUST NOT ANSWER FOR THE SAMPLE (agent-infra#2933). MEASURED 2026-10-27 on
  # the tortoise target: 26 PRs open, K=8 examined per cycle, and the line printed `most common: 15
  # outside this cycle's sweep window`. That "reason" is computed across ALL rows, so it names a fact
  # about the rows the sweep did NOT read — the deferred rows always outnumber the window, so the modal
  # reason was always the deferral and the examined rows' own reasons were NEVER printed. An operator
  # could not tell "everything examined is legitimately waiting" from "the rows the sweep read are being
  # refused by something broken". Below, every examined row waits for a DIFFERENT reason: each of them
  # must be printed, the deferred reason must appear nowhere as a reason, and the two counts must be
  # separate clauses. The window is the shipped `SWEEP_WINDOW_PR`/`SWEEP_WIN_NOTE` shape, so this drives
  # the SAME predicate the sweep uses to decide what it read (never a second, drifting definition).
  _wdef="outside this cycle's sweep window (window=11-16 of 24 (K=6/cycle, rotating)); it is read within 4 cycles"
  _wled="$(printf '11\tabc\tGREEN\twait\tcapacity: fix-lane ceiling 2 reached or the spawn gate refused\n12\tabc\tGREEN\twait\tcapacity: fix-lane ceiling 4 reached or the spawn gate refused\n13\tabc\tGREEN\twait\ta worker already owns this PR\n14\tabc\tGREEN\twait\tcheck surface in flight — nothing spawned\n15\tabc\tGREEN\twait\tcheck surface READ-FAILED:NOCHECKS — nothing spawned\n16\tabc\tGREEN\twait\tparked at this head — needs a human')"$'\n'
  # ⛔ `$(printf …)` STRIPS THE TRAILING NEWLINE, so appending substitutions row by row would FUSE the
  # deferred rows into a narrower ledger (measured while writing this: 24 rows became 6) and the test
  # would then "prove" the sample/deferral split on a population that has no deferred rows at all.
  for _i in 1 2 3 4 5 6 7 8 9 10 17 18 19 20 21 22 23 24; do
    _wled="$_wled$(printf '%s\tabc\t-\twait\t%s' "$_i" "$_wdef")"$'\n'
  done
  # A SUBSHELL, so the window cannot leak into the cases above or below (they must keep driving the
  # no-window and unwritable paths).
  ( SWEEP_WINDOW_PR=" 11  12  13  14  15  16 "; SWEEP_WIN_NOTE="window=11-16 of 24 (K=6/cycle, rotating)"; \
    SEL_N=24; SWEEP_ROWS_PER_CYCLE=6; summarise "$_wled" 1 open-rows 12 )
  _wl="$(grep '^\[pr\] PR path' "$TMP/s.log" 2>/dev/null)"
  case "$_wl" in
    *"examined 6 (window 11-16 of 24 (K=6/cycle, rotating))"*"18 deferred or scope-excluded this cycle"*)
      ok "a bounded sweep: the EXAMINED count and the deferred count are separate clauses (#2933)" ;;
    *) bad "the summary did not separate the examined sample from the deferred rows: $_wl" ;;
  esac
  _wmiss=""
  for _wlbl in "2 capacity: fix-lane ceiling N reached or the spawn gate refused" \
               "1 a worker already owns this PR" "1 check surface in flight" \
               "1 check surface READ-FAILED:NOCHECKS" "1 parked at this head"; do
    case "$_wl" in *"$_wlbl"*) ;; *) _wmiss="$_wmiss [$_wlbl]" ;; esac
  done
  [ -z "$_wmiss" ] && ok "…EVERY examined row's own reason is printed, not the modal deferred one" \
                   || bad "the summary hid examined reason(s):$_wmiss"
  case "$_wl" in
    *"most common"*|*"outside this cycle's sweep window"*)
      bad "…the deferred rows' reason is still being reported as THE reason (#2933)" ;;
    *) ok "…and no deferred row's reason is printed as a reason" ;;
  esac
  # ⛔ ONE LINE, AND `spawned=N` STILL NAMED — the contract the old line had, kept.
  if [ "$(grep -c '^\[pr\] PR path' "$TMP/s.log" 2>/dev/null)" = "1" ]; then
    case "$_wl" in *"spawned="*) ok "…still exactly ONE \[pr\] line per cycle, still naming spawned=N" ;;
      *) bad "the [pr] line lost its spawned= clause: $_wl" ;; esac
  else
    bad "an idle cycle printed $(grep -c '^\[pr\] PR path' "$TMP/s.log" 2>/dev/null) [pr] lines, not one"
  fi
  # ⛔ AND A CYCLE WITH NO WINDOW AT ALL IS NOT "EXAMINED 0". When nothing was selected to read (a
  # deferral, a failed listing, a cache-less 304) the only honest population IS every row — reporting
  # "examined 0" there would hide the very reasons the line exists to print, and going silent is the
  # defect this line already fixed once.
  summarise "$(printf '11\tabc\t-\twait\tno per-PR read this cycle (the open-PR listing was unchanged — 304 — or unreadable)\n12\tabc\t-\twait\tno per-PR read this cycle (the open-PR listing was unchanged — 304 — or unreadable)\n')" 1 open-rows 23
  grep -q 'NO SWEEP WINDOW this cycle' "$TMP/s.log" \
    && grep -q '2 no per-PR read this cycle' "$TMP/s.log" \
    && ok "no window at all: the reasons are for every row, never 'examined 0' and never silent" \
    || bad "a window-less cycle did not report its rows' reasons: $(cat "$TMP/s.log")"
  # ⛔ THE FORWARD CLAIM (review P2): the old wording asserted "issues stay CLOSED" from a block that
  # cannot know — all-counted-parked legitimately opens the gate. It must not come back.
  grep -qi 'issues stay CLOSED' "$TMP/s.log" \
    && bad "the summary claims what the gate will do — a claim with no artifact behind it" \
    || ok "…and it makes no claim about the issue path (the gate is decided further down)"
  summarise "" 0 open-rows 3
  grep -q 'record UNWRITABLE' "$TMP/s.log" && grep -q 'FIRSTTOK=unknown' "$TMP/s.tok" \
    && ok "an unwritable state/: UNKNOWN, never 'nothing happened' (0 rows cannot read as NF-0)" \
    || bad "an unwritable ledger was reported as a zero: $(cat "$TMP/s.log")"
  summarise "" 1 fallback 26
  grep -q 'NO ROWS' "$TMP/s.log" && grep -q 'FIRSTTOK=none enumerable' "$TMP/s.tok" \
    && ok "no per-PR rows at all: the cycle says so instead of printing an empty tally" \
    || bad "a cycle with no rows printed $(cat "$TMP/s.log")"
  # …and on a NON-enumerable population the caveat must appear: the ledger covers the swept set while
  # the gate reads the listing count, and the difference cannot be named per-PR (review P1).
  summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 swept 26
  grep -q 'NOT enumerable this cycle' "$TMP/s.log" \
    && ok "a swept-only population carries the caveat (the two numbers have different denominators)" \
    || bad "a swept-only population was presented as the whole one"
else
  bad "the [prsum] block is missing — the cycle's own summary is untested"
fi

fi  # /acting-case extractable

echo
echo "=== T7: ACT IS NOT SPAWN — the pass must say what it STARTED (agent-infra#2590) ==="
# ⛔ THE MEASURED DEFECT. A disposition row is `act` for an auto-merge ARM, a draft-ready and a rerun —
# none of which starts a worker — so `N acted` was printed beside `lanes=0` on a box that had started
# nothing at all (live log: `[pr] PR path: 2 acted (#9812,#9528)` where #9528's row was `auto-armed`).
# The spawn count therefore comes from the worker records `wt_spawn` writes, never from the ledger.
if [ -s "$TMP/sum.sh" ] && [ -s "$TMP/spawns.sh" ]; then
  # ── the reader, on its own ──────────────────────────────────────────────────────────────────────
  SP="$TMP/spawnO"; mkdir -p "$SP/state"; BASE=1700000000
  rm -f "$SP"/state/worker-*
  printf 'kind=tmux\ncreated=%s\n' "$((BASE + 5))"  > "$SP/state/worker-merge-11"
  printf 'kind=tmux\ncreated=%s\n' "$((BASE + 9))"  > "$SP/state/worker-fix-12"
  printf 'kind=tmux\ncreated=%s\n' "$((BASE - 600))" > "$SP/state/worker-merge-8"   # LAST cycle's
  printf 'kind=tmux\n'                              > "$SP/state/worker-merge-7"    # no created= field
  printf 'kind=tmux\ncreated=%s\n' "$((BASE + 5))"  > "$SP/state/worker-bad name"   # not a wt tag
  _rs() { ( O="$SP"; . "$TMP/spawns.sh"; . "$TMP/isnum.sh"; WT_DIR="$SP/state" spawns_since "$@" ); }
  _got="$(_rs "$BASE")"
  case "$_got" in
    "2"*"fix-12,merge-11") ok "the reader counts ONLY records created at/after the cycle start, by tag" ;;
    *) bad "the spawn reader returned '$_got' (want 2 + fix-12,merge-11: a stale/foreign record proves nothing)" ;;
  esac
  _got="$(_rs "")"
  [ -z "$_got" ] && ok "an UNREADABLE baseline yields NO answer (never a zero — a zero is a measurement)" \
                 || bad "an empty baseline produced '$_got' instead of no answer"
  _got="$(_rs "$((BASE + 100))")"
  case "$_got" in "0"*) ok "a baseline after every record measures a real ZERO" ;;
                 *) bad "a baseline past every record returned '$_got', not a measured 0" ;; esac
  # ── the shipped terminal line ──────────────────────────────────────────────────────────────────
  _sp() { # _sp <cycle-t0>  -> the [spawn] line the shipped block printed
    : > "$TMP/s.log"
    ( O="$TMP/O"; LOG="$TMP/s.log"; PRDISP="$TMP/s.tsv"; PRDISP_OK=1; POP=open-rows; UPN_WORK=3
      SCOPE_MODE=BROAD; FLOOR_NOTE=""; PR_FIRST_TOK=""; WT_DIR="$SP/state"; WT_TABLE_TTL=0
      CYCLE_T0="$1"
      . "$HERE/worker-terminal.sh"
      cmux() { printf '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}\n'; return 0; }
      . "$TMP/isnum.sh"; . "$TMP/spawns.sh"; . "$TMP/sum.sh" >/dev/null 2>&1
      printf '%s' "${PRDISP_SPAWNS:-<unset>}" > "$TMP/sp.out" ) >/dev/null 2>&1
    grep -h '^\[spawn\]' "$TMP/s.log" 2>/dev/null
  }
  _got="$(_sp "$BASE")"; _c="$(cat "$TMP/sp.out" 2>/dev/null)"
  case "$_got" in
    "[spawn] SPAWNED 2 worker(s) in this pass's PR sweep: fix-12,merge-11"*) ok "a pass that started workers SAYS so, and names them" ;;
    *) bad "the [spawn] line did not name the workers this pass started: '$_got'" ;;
  esac
  if [ "$_c" = "2" ]; then ok "…and the count the funnel and the drain guard read is set to it"
  else bad "PRDISP_SPAWNS was '$_c' after a 2-spawn pass"; fi
  _got="$(_sp "$((BASE + 100))")"; _c="$(cat "$TMP/sp.out" 2>/dev/null)"
  case "$_got" in
    "[spawn] NONE"*"the PR sweep started no worker this pass"*) ok "a pass that started NOTHING says NONE — and says acts may still exist" ;;
    *) bad "a zero-spawn pass did not say NONE: '$_got'" ;;
  esac
  if [ "$_c" = "0" ]; then ok "…and the count is a MEASURED 0, so the funnel cannot borrow the word 'dispatch'"
  else bad "PRDISP_SPAWNS was '$_c' after a zero-spawn pass"; fi
  _got="$(_sp "")"; _c="$(cat "$TMP/sp.out" 2>/dev/null)"
  case "$_got" in
    "[spawn] UNMEASURED"*) ok "an UNREADABLE spawn answer says UNMEASURED — never 'NONE' (a claim from no measurement)" ;;
    *) bad "an unreadable spawn answer printed '$_got' instead of UNMEASURED" ;;
  esac
  if [ "$_c" = "<unset>" ]; then ok "…and no count is published, so a reader cannot mistake it for zero"
  else bad "an UNMEASURED pass published a count of '$_c'"; fi
else
  bad "the [prsum] or the spawns_since reader is missing — the terminal spawn line is untested"
fi

echo
echo "=== T6: the ledger is a RECORD, never a gate input ==="
_disp_ln="$(grep -nE 'prdisp|PRDISP' "$ORCH" | head -1 | cut -d: -f1)"
_count_ln="$(grep -nF 'UPN="$(unowned_pr_count' "$ORCH" | head -1 | cut -d: -f1)"
if [ -n "$_disp_ln" ] && [ -n "$_count_ln" ] && [ "$_disp_ln" -gt "$_count_ln" ]; then
  ok "the ledger is first used at line $_disp_ln, AFTER the count at $_count_ln (it cannot feed it)"
else
  bad "the ledger is used at/before the count (disp@${_disp_ln:-none} count@${_count_ln:-none}) — the gate would decide on a narrower population"
fi
grep -qE '(UPN|UPN_WORK|SEL_PARKED)=.*(prdisp|PRDISP)|mp_reason.*(prdisp|PRDISP)' "$ORCH" \
  && bad "the gate arithmetic reads the ledger" \
  || ok "no count/gate assignment reads the ledger (absence)"
# The parent must TRUNCATE it before the sweep, or cycle N reads cycle N-1's claims as its own.
grep -qF ': > "$PRDISP"' "$ORCH" \
  && ok "the ledger is truncated per cycle (bounded by construction: one row per PR, no prune job)" \
  || bad "the ledger is appended across cycles — cycle N would print cycle N-1's claims"

echo
echo "=== T7: a REFUSED spawn is MEASURED, and the cycle's own line names it ==="
# ⛔ THE MEASURED DEFECT (2026-10-22, cloud cell). The launcher's own volume reached 100%, so EVERY
# `wt_spawn` in EVERY cycle was refused (`cmux layout apply failed: … database or disk is full`) —
# 1,562 refusals in one controller log, six hours, not one PR landed — while the cycle's own line
# read `N acted, M named wait(s)` and `lanes=0`. An `act` can be a draft-ready or an auto-arm, i.e.
# something that starts NO worker, so the act tally alone can never tell "the fleet advanced" from
# "the actuator refused everything". These assertions drive the SHIPPED summary block; nothing here
# greps orch-loop.sh for prose.
summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3 2
grep -q '1 acted (#11)' "$TMP/s.log" && grep -q '2 spawn(s) REFUSED by the launcher' "$TMP/s.log" \
  && ok "an acting cycle that ALSO refused 2 spawns says both ('1 acted' AND '2 spawn(s) REFUSED')" \
  || bad "a refused spawn is still invisible beside the act tally: $(cat "$TMP/s.log")"
grep -q 'database or disk is full' "$TMP/s.log" \
  && ok "…and the launcher's OWN reason is on the line, never a guessed cause" \
  || bad "the refusal reason did not reach the cycle line: $(cat "$TMP/s.log")"
summarise "$(printf '11\tabc\tGREEN\twait\tparked at this head — needs a human\n')" 1 open-rows 3 3
grep -q 'NO UNIT SPAWNED' "$TMP/s.log" && grep -q '3 spawn(s) REFUSED' "$TMP/s.log" \
  && ok "a cycle whose every spawn was refused NAMES it (it is not an idle cycle)" \
  || bad "a fully-refused cycle reads as merely idle: $(cat "$TMP/s.log")"
summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3 0
grep -q 'REFUSED' "$TMP/s.log" \
  && bad "a cycle with NO refusal record invented one" \
  || ok "…and no refusal row means no refusal claim (absence is not a zero stated as a fact)"
# ⛔ WRITER → READER. The fixture rows above are hand-written; this drives a REAL refused spawn through
# the shipped launcher and reads back what the shipped summary would print. A reader tested only
# against a hand-made file proves the formatter, not the measurement.
: > "$TMP/O/state/spawn-refused.tsv"
drive GREEN rail 0 0
grep -q 'merge-4242' "$TMP/O/state/spawn-refused.tsv" \
  && grep -qi 'layout apply failed' "$TMP/O/state/spawn-refused.tsv" \
  && ok "the WRITER: a refused spawn records its worker name AND the launcher's own reason" \
  || bad "a refused spawn wrote no refusal row: $(cat "$TMP/O/state/spawn-refused.tsv" 2>/dev/null)"
# …and the line it produces is fed by THAT record, not by a copy of one: `summarise` receives the
# writer's file verbatim. Requiring the launcher's actual reason (and NOT the `reason not recorded`
# marker) is what makes this assertion able to fail in the direction it is named for.
cp "$TMP/O/state/spawn-refused.tsv" "$TMP/written.tsv"
summarise "$(printf '11\tabc\tGREEN\twait\tspawn FAILED\n')" 1 open-rows 3 0 "$TMP/written.tsv"
grep -q 'merge-4242' "$TMP/written.tsv" && grep -qi 'layout apply failed' "$TMP/s.log" \
  && ok "…and the cycle line carries THAT record's reason (writer → reader, end to end)" \
  || bad "the cycle line did not carry the writer's reason: $(cat "$TMP/s.log")"
# The cap is printed honestly: 200 rows is the writer's bound, so a storm of 200+ reads `≥200`, never
# an exact 200 that understates the storm while looking precise.
summarise "$(printf '11\tabc\tGREEN\twait\tspawn FAILED\n')" 1 open-rows 3 200
grep -q '≥200 spawn(s) REFUSED' "$TMP/s.log" \
  && ok "at the 200-row cap the count reads ≥200 (a bound is not an exact count)" \
  || bad "a capped storm read as an exact count: $(cat "$TMP/s.log")"
# …and the tmux (launchd) refusal is recorded too — its message did not start with `REFUSED ` and was
# therefore the one refusal shape the hook could not see (review, cycle 1). ⛔ DRIVEN THROUGH `wt_spawn`
# WITH THE tmux SURFACE FORCED, never hand-written: a hand-written `wt_warn` line stays green when the
# shipped message form is reverted, which is exactly the regression this assertion exists for.
mkdir -p "$TMP/O/state" "$TMP/tmxfail" "$TMP/whome"; : > "$TMP/O/state/spawn-refused.tsv"
printf '#!/bin/sh\nexit 1\n' > "$TMP/tmxfail/tmux"; chmod +x "$TMP/tmxfail/tmux"
# ⛔ THE CREDENTIAL IS FIXTURED TOO, or this case pins the WRONG refusal: `wt_spawn` refuses for a
# missing gh credential BEFORE it ever reaches the tmux call (`wt_launcher_env`), and that refusal is
# ALSO `REFUSED `-prefixed — so on a runner with no gh store, no keys.env and no exported token (CI
# sets none) the row this case greps for came from the arm above it, and reverting the tmux line's
# `REFUSED ` prefix would have stayed GREEN. A fixture HOME whose keys.env carries a token VALUE is
# what makes the pre-check pass deterministically, so the refusal measured below can only be the
# launcher's own.
printf 'GH_TOKEN=ghp_fixture_for_this_case\n' > "$TMP/whome/keys.env"
(
  O="$TMP/O"; WT_DIR="$TMP/O/state"; WT_WORKER_HOME="$TMP/whome"
  . "$HERE/worker-terminal.sh"
  cmux() { return 1; }                       # no durable-terminal surface …
  uname() { printf 'Darwin\n'; }             # … so macOS's launcher is chosen …
  # ⛔ A PATH SHIM, NOT A FUNCTION STUB (rebase onto the credential contract, #2396/#2508): the
  # shipped arm runs the launch through `wt_bounded`, which is `perl -e 'alarm …; exec @ARGV'` —
  # `exec` takes a PATH BINARY, so a `tmux()` FUNCTION is never consulted and the assertion below
  # stayed green while the REAL tmux started a live session. The intent is unchanged: tmux cannot
  # start the worker.
  PATH="$TMP/tmxfail:$PATH"
  wt_spawn fix-77 "$TMP/O" 'true' >/dev/null 2>&1
) >/dev/null 2>&1
grep -q 'fix-77' "$TMP/O/state/spawn-refused.tsv" \
  && grep -qi 'tmux could not start' "$TMP/O/state/spawn-refused.tsv" \
  && ok "a tmux (launchd) refusal is recorded like any other (driven through wt_spawn, surface forced)" \
  || bad "the launchd surface's refusal wrote no row: $(cat "$TMP/O/state/spawn-refused.tsv" 2>/dev/null)"

# ── the UNMEASURED branch: a record that cannot be written must not read as zero refusals
# (the incident's own cause is ENOSPC, where `: > file` SUCCEEDS and every append fails).
SPAWNREF_OK=0 SPAWNREF_WHY_BAD='state/ is not writable (the probe row could not be written)' \
  summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3 0
grep -q 'refusal measurement UNAVAILABLE' "$TMP/s.log" && grep -q 'UNMEASURED' "$TMP/s.log" \
  && ok "an unmeasurable refusal record says UNMEASURED (it never reads as 'no refusals')" \
  || bad "an unmeasurable record printed a silent zero: $(cat "$TMP/s.log")"

echo
echo "=== T7a: EVERY line that must carry the refusal cause actually does ==="
# ⛔ THE INSERTION POINTS ARE THE CHANGE (review, cycle 3): the suffix existed and was tested on one of
# seven sites, so five could be deleted with CI green — including `_prtail`, the fold into the line that
# printed `lanes=0 … 1 acted, 29 named wait(s)` for six hours. Each one is driven here.
# (a) the two `[pr]` states that no other case reaches: an unwritable ledger, and an empty one.
summarise "" 0 open-rows 3 2
grep -q 'record UNWRITABLE' "$TMP/s.log" && grep -q '2 spawn(s) REFUSED' "$TMP/s.log" \
  && ok "an UNWRITABLE ledger still names the refusals (one line, both facts)" \
  || bad "the unwritable-ledger line lost the refusal cause: $(cat "$TMP/s.log")"
summarise "" 1 open-rows 3 2
grep -q 'NO ROWS' "$TMP/s.log" && grep -q '2 spawn(s) REFUSED' "$TMP/s.log" \
  && ok "a NO-ROWS ledger still names the refusals" \
  || bad "the no-rows line lost the refusal cause: $(cat "$TMP/s.log")"
# (b) the `[dispatch]` PR-path tail — the incident's own line.
sed -n '/# \[prtail:begin\]/,/# \[prtail:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/pt.sh"
if [ -s "$TMP/pt.sh" ]; then
  prtail() { ( _prtail="$1"; _refsuf="$2"; . "$TMP/pt.sh"; printf '%s\n' "$_prtail" ); }
  _o="$(prtail '1 acted, 9 named wait(s)' ' ⛔ 3 spawn(s) REFUSED by the launcher (cmux layout apply failed: database or disk is full)')"
  grep -q '3 spawn(s) REFUSED' <<<"$_o" && grep -q 'cmux layout apply failed' <<<"$_o" \
    && ok "the [dispatch] PR-path tail carries the count AND the launcher's reason" \
    || bad "the dispatch tail lost the cause: $_o"
  _o="$(prtail 'NO UNIT SPAWNED, 9 named wait(s)' '')"
  [ "$_o" = 'NO UNIT SPAWNED, 9 named wait(s)' ] \
    && ok "…and with no refusals the tail is byte-identical to before (additive only)" \
    || bad "the tail changed shape when there was nothing to add: $_o"
else
  bad "the [prtail] block is missing — the incident's own line is unpinned"
fi
# (c) the DRAIN STALLED line.
# ⛔ `O_WORK` IS PREPENDED, NOT ASSUMED (agent-infra#2095, found by this suite). The drain-health block
# dispatches `"$O_WORK/stall-fix.sh"`, and `O_WORK` is declared far ABOVE the extracted range — so
# without this binding the fragment ran `"/stall-fix.sh"` and every leg that pins WHAT the fixer is told
# read "not-called" while the stub it was testing never ran. Binding it to the sandbox `O` is what the
# drivers already intend, and it keeps the loop's real two-home rule (below) out of the fixture's way.
{ echo 'O_WORK="${O_WORK:-$O}"'
  sed -n '/# \[drain-health:begin\]/,/# \[drain-health:end\]/p' "$ORCH" | sed '1d;$d'; } > "$TMP/dh.sh"
if [ -s "$TMP/dh.sh" ]; then
  drain() {
    : > "$TMP/dh.log"; mkdir -p "$TMP/D/state"; : > "$TMP/D/state/merged-1.done"
    (
      O="$TMP/D"; LOG="$TMP/dh.log"; UPN_WORK=5; LO_CHOICE=pr; MERGE_STALL_MIN=360
      _refsuf="$1"
      mp_recent_land() { date -d '400 minutes ago' +%s 2>/dev/null || echo $(( $(date +%s) - 24000 )); }
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    cat "$TMP/dh.log"
  }
  _o="$(drain ' ⛔ 2 spawn(s) REFUSED by the launcher (cmux layout apply failed: database or disk is full)')"
  grep -q 'DRAIN STALLED' <<<"$_o" && grep -q '2 spawn(s) REFUSED' <<<"$_o" \
    && ok "DRAIN STALLED (a land inside the window, aged past the stall bound) carries the refusal cause" \
    || bad "the stall line lost the cause: $_o"
  # ⛔ THE EMPTY ANSWER IS THE ONE THAT PRINTS FOR A REAL STALL (review cycle 4, then #2929).
  # `mp_recent_land` only ever returns a stamp inside 2x the gate's window, so arm 1 covers the
  # 180–360m band — while the measured incident ran SIX HOURS. Once nothing landed inside that bound
  # the function returns empty; before #2929 that landed in a separate arm that PRINTED but recorded
  # nothing and dispatched nothing. It now takes the SAME escalation arm via the synthesised stamp
  # (#2929 ask 1), so this leg drives the six-hour stall line itself — and it is the leg that reddens
  # if that synthesis is ever removed.
  drain_far() {
    : > "$TMP/dh2.log"; mkdir -p "$TMP/D2/state"; : > "$TMP/D2/state/merged-1.done"
    (
      O="$TMP/D2"; LOG="$TMP/dh2.log"; UPN_WORK=23; LO_CHOICE=pr; MERGE_STALL_MIN=360
      _refsuf="$1"
      mp_recent_land() { printf ''; }   # nothing landed inside the bound -> the fallback arm
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    cat "$TMP/dh2.log"
  }
  _o="$(drain_far ' ⛔ 15 spawn(s) REFUSED by the launcher (cmux layout apply failed: database or disk is full)')"
  grep -q 'DRAIN STALLED' <<<"$_o" && grep -q '15 spawn(s) REFUSED' <<<"$_o" \
    && ok "DRAIN STALLED (nothing landed inside the bound — the >=6h arm) carries the refusal cause" \
    || bad "the long-stall line lost the cause: $_o"
  # ⛔ THE DISPATCH IS GATED ON "DID THIS PASS STALL", NOT ON THE COUNTER (verifier, 2026-10-27).
  # The first cut read `_dpass` on EVERY path, where it defaults to 0, and `0 % 3 == 0` spawned a
  # stall-repair worker on every HEALTHY pass; the second cut initialised the flag INSIDE the stall
  # arm, which reset it immediately and dispatched on NO pass at all. Neither state is visible to any
  # existing leg, so both are driven here: a stalled pass MUST invoke the fixer, a landed pass MUST NOT.
  # ⛔ THE STUB RECORDS ITS ARGUMENTS (review P3, #2929). It used to be `echo called`, so the leg proved
  # only THAT a worker was started, never WHAT it was told: mutating `orch-loop.sh` to pass a constant
  # `"0"` instead of `"${_dpass:-0}"` made `stall-fix.sh` refuse every call in production (`SEEN=0` is
  # not a stalled pass — the escalation dispatches NOBODY, the exact inertness this PR removes) while
  # the whole suite stayed green. Asserting the counter is what makes the leg discriminating.
  # ⛔ THE STUB RECORDS THE AGE'S PROVENANCE BESIDE THE COUNTER, NOT JUST THE COUNTER (fresh-context
  # review of #3380, 2026-11-05, P2). `orch-loop.sh` forwards `_AGESRC` on the SAME line it forwards
  # the counter, and that forwarding was pinned by NOTHING: delete `_AGESRC="${_agesrc:-measured}"`
  # from the call and `stall-fix.sh` falls back to its `:-measured` default, so an UNMEASURED or
  # SYNTHESISED age is reported as a measurement on both sinks — the exact defect #3380 fixes — while
  # every suite stayed green (measured: `pr-dispatch.test.sh` 144/0 and `stall-fix.test.sh` 84/0
  # unchanged). §F in `stall-fix.test.sh` pins the CONSUMER of the value; these legs pin the PRODUCER,
  # because an interface is only pinned when both ends are.
  # ⛔ THE SANDBOX MUST BE A COMPLETE WORKER ROOT (agent-infra#2095, found by this PR's own suite).
  # `orch-loop.sh` resolves its worker root as `$O` when `$O` carries the worker scripts, and otherwise
  # as the directory beside the LOOP. A fixture that seeds only `stall-fix.sh` therefore makes the
  # SHIPPED loop drive the REAL harness instead of these stubs: every leg below then reads "not-called"
  # while the stub it is testing never runs, and the leg proves nothing about the producer it pins.
  # Seeding the three names the loop only `-f`-checks keeps the sandbox authoritative.
  seed_worker_root() { # <dir>
    local d="$1" w
    for w in fix-one.sh merge-one.sh dispatch-merge.sh; do : > "$d/$w"; done
  }
  stallfix_dispatch() {   # <land-age-minutes> -> <pass counter>|<age provenance> | "not-called"
    rm -f "$TMP/called.txt"; mkdir -p "$TMP/D3/state"; : > "$TMP/D3/state/merged-1.done"
    seed_worker_root "$TMP/D3"
    cat > "$TMP/D3/stall-fix.sh" <<'STUBFIX'
#!/bin/bash
printf '%s|%s' "${1:-}" "${_AGESRC:-<unset>}" >> "$STUBMARK"
STUBFIX
    chmod +x "$TMP/D3/stall-fix.sh"
    (
      O="$TMP/D3"; LOG="$TMP/dh3.log"; UPN_WORK=9; LO_CHOICE=pr; MERGE_STALL_MIN=360
      STUBMARK="$TMP/called.txt"; export STUBMARK
      # ⛔ THE AGE ARRIVES VIA THE ENVIRONMENT, not `$1`: the block calls `mp_recent_land`
      # with NO arguments, so a stub reading `$1` prints an empty stamp and the whole block is
      # skipped — which is how this leg first "passed" while dispatching nothing.
      LAND_AGE_MIN="$1"; export LAND_AGE_MIN
      mp_recent_land() { echo $(( $(date +%s) - LAND_AGE_MIN * 60 )); }
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    [ -s "$TMP/called.txt" ] && cat "$TMP/called.txt" || echo not-called
  }
  # A real stamp inside the window is a READING (`_lmsyn=0`) — the one case that may say `measured`.
  _o="$(stallfix_dispatch 400)"
  [ "$_o" = "1|measured" ] && ok "a STALLED pass invokes the stall fixer WITH the pass counter it measured (1) — the escalation dispatches — and hands it the age's TRUE provenance (measured)" \
    || bad "a stalled pass did not hand the stall fixer 'pass counter 1 + agesrc=measured' — the escalation is inert, hands it a counter stall-fix.sh refuses, or forwards no provenance at all (the fixer then defaults to 'measured'): got '$_o'"
  # ⛔ AND THE SAME EMPTY ANSWER MUST DISPATCH (verifier, cycle 3 + #2929): an empty `mp_recent_land`
  # is NOTHING landed inside the window — the ≥6h class this box actually reaches, and the state #2929
  # measured at 178 markers / 0 inside 360m. It printed a line and set no flag, so the escalation was
  # inert exactly where the stall is worst. The fixture keeps a marker on disk with an empty answer, so
  # it is the EMPTY-ANSWER path (and not a missing marker) that has to reach the dispatcher.
  stallfix_dispatch_noland() {
    rm -f "$TMP/called.txt"; mkdir -p "$TMP/D4/state"; : > "$TMP/D4/state/merged-1.done"
    seed_worker_root "$TMP/D4"
    cat > "$TMP/D4/stall-fix.sh" <<'STUBFIX'
#!/bin/bash
printf '%s|%s' "${1:-}" "${_AGESRC:-<unset>}" >> "$STUBMARK"
STUBFIX
    chmod +x "$TMP/D4/stall-fix.sh"
    (
      O="$TMP/D4"; LOG="$TMP/dh4.log"; UPN_WORK=9; LO_CHOICE=pr; MERGE_STALL_MIN=360
      STUBMARK="$TMP/called.txt"; export STUBMARK
      mp_recent_land() { printf ''; }   # nothing landed inside the bound -> the empty answer
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    [ -s "$TMP/called.txt" ] && cat "$TMP/called.txt" || echo not-called
  }
  # An EMPTY answer with a READABLE `state/` is a SYNTHESISED bound, never a measurement.
  _o="$(stallfix_dispatch_noland)"
  [ "$_o" = "1|synth" ] && ok "…and the EMPTY answer (nothing landed inside the window — the >=6h stall) dispatches too, with the measured counter — and says the age is a BOUND (synth), not a reading" \
    || bad "the empty-answer path printed the line but never invoked the fixer correctly, or forwarded the wrong provenance ('measured' here is the #3380 defect — an invented reading): got '$_o'"
  # ⛔ THE THIRD PROVENANCE, PINNED AT THE PRODUCER (#3380). `_lmread=0` — a `state/` that exists but
  # cannot be READ — makes `_agesrc=unmeasured`, and the fixer must be TOLD so its brief says the age
  # was not taken. This leg is `chmod`, not a directory trick, because the shape being built IS the
  # permission state (`[ -r "$O/state" ]`), and it therefore cannot be built for root: on a root host
  # `-r` is always true, so the leg is reported UNPROVEN rather than counted — a leg that silently
  # passes for the wrong reason is the thing this suite exists to prevent.
  stallfix_dispatch_unreadable_state() {
    rm -f "$TMP/called.txt"; mkdir -p "$TMP/D7/state"; : > "$TMP/D7/state/merged-1.done"
    seed_worker_root "$TMP/D7"
    chmod 0333 "$TMP/D7/state"
    cat > "$TMP/D7/stall-fix.sh" <<'STUBFIX'
#!/bin/bash
printf '%s|%s' "${1:-}" "${_AGESRC:-<unset>}" >> "$STUBMARK"
STUBFIX
    chmod +x "$TMP/D7/stall-fix.sh"
    (
      O="$TMP/D7"; LOG="$TMP/dh7.log"; UPN_WORK=9; LO_CHOICE=pr; MERGE_STALL_MIN=360
      STUBMARK="$TMP/called.txt"; export STUBMARK
      mp_recent_land() { printf ''; }
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    chmod 0755 "$TMP/D7/state" 2>/dev/null || true
    [ -s "$TMP/called.txt" ] && cat "$TMP/called.txt" || echo not-called
  }
  if [ "$(id -u)" = "0" ]; then
    # ⛔ THE BACKTICKS ARE ESCAPED, AND THAT IS NOT COSMETIC (review cycle 4 of #3380, 2026-11-05, P3):
    # inside a DOUBLE-quoted string an unescaped `state/` is COMMAND SUBSTITUTION, so on the one host
    # class this branch exists for the disclosure printed "/tmp/…: state/: No such file or directory"
    # and "-r: command not found" and then garbled its own sentence, while `bash -n` stayed clean and
    # no gate looked. Measured by running this exact line with an uid-0 stub
    # (`bash /tmp/probe-root-line.sh`) — the escape is what makes it a sentence instead of a script.
    echo "  ⏭  UNPROVEN-ON(root): the unsearchable-\`state/\` leg cannot be built for a privileged user (\`-r\` is always true), so the producer side of 'unmeasured' is UNMEASURED here — the consumer side is pinned by §F in stall-fix.test.sh"
  else
    _o="$(stallfix_dispatch_unreadable_state)"
    [ "$_o" = "1|unmeasured" ] && ok "…and an UNSEARCHABLE state/ dispatches with agesrc=unmeasured — the third provenance reaches BOTH sinks, not a synthesised measurement" \
      || bad "the unsearchable-state path handed the fixer the wrong provenance — 'measured' or 'synth' here asserts a reading this box never took (the #3181 P1): got '$_o'"
  fi
  _o="$(stallfix_dispatch 5)"
  [ "$_o" = "not-called" ] && ok "…and a LANDED pass does not (no worker on a healthy box)" \
    || bad "a healthy pass invoked the stall fixer — the gate reads the counter, not the stall: got '$_o'"
  # ⛔ THE `_dpok` GATE AND THE `STALL FIX MISSING` ARM HAD NO ASSERTION (fresh-context review of #3181,
  # 2026-11-02, P2). Neither is reachable from the legs above: this fixture's `state/` is always
  # writable (so `_dpok=1` on every run) and a stub is always present. Deleting the
  # `[ "${{_dpok:-0}}" != "1" ]` condition left every suite green, while in production an UNPERSISTABLE
  # `state/drain-stall` would then dispatch on EVERY stalled pass — a record frozen at a multiple of the
  # cadence reads the same pass number forever (~7 overlapping 1800 s workers, the storm the gate's own
  # comment says it prevents) — and an absent `$O/stall-fix.sh` would be silent instead of loud.
  stallfix_fixture() { # <o-dir> <make-unwritable:0|1> <plant-fixer:0|1> -> the counter | "not-called"
    rm -f "$TMP/called.txt"; mkdir -p "$1/state"; : > "$1/state/merged-1.done"
    # A DIRECTORY on the record path, not `chmod`: the write fails for every user including root, so the
    # arm measures the FAILED WRITE rather than the permissions of whoever runs the suite.
    if [ "$2" = "1" ]; then mkdir -p "$1/state/drain-stall"; fi
    if [ "$3" = "1" ]; then
      printf '%s\n' '#!/bin/bash' 'printf "%s" "$1" >> "$STUBMARK"' > "$1/stall-fix.sh"
      chmod +x "$1/stall-fix.sh"
    fi
    (
      O="$1"; LOG="$1/dh.log"; UPN_WORK=9; LO_CHOICE=pr; MERGE_STALL_MIN=360
      STUBMARK="$TMP/called.txt"; export STUBMARK
      mp_recent_land() { echo $(( $(date +%s) - 400 * 60 )); }
      is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0?*) return 1 ;; *) return 0 ;; esac; }
      . "$TMP/dh.sh"
    ) >/dev/null 2>&1
    [ -s "$TMP/called.txt" ] && cat "$TMP/called.txt" || echo not-called
  }
  _o="$(stallfix_fixture "$TMP/D5" 1 1)"
  [ "$_o" = "not-called" ] && ok "…and an UNPERSISTABLE pass counter dispatches NOBODY (a cadence that cannot be saved is not a cadence)" \
    || bad "an unwritable state/drain-stall still dispatched — the one-per-N bound is unenforced in production: got '$_o'"
  grep -q 'STALL FIX SKIPPED' "$TMP/D5/dh.log" 2>/dev/null \
    && ok "…and the pass SAYS the fix was skipped (an escalation that silently does nothing is the defect this closes)" \
    || bad "an unpersistable counter was SILENT — no STALL FIX SKIPPED line: $(cat "$TMP/D5/dh.log" 2>/dev/null)"
  _o="$(stallfix_fixture "$TMP/D6" 0 0)"
  [ "$_o" = "not-called" ] && ok "…and a box with NO \$O/stall-fix.sh dispatches nobody rather than pretending" \
    || bad "an absent stall fixer was still invoked: got '$_o'"
  grep -q 'STALL FIX MISSING' "$TMP/D6/dh.log" 2>/dev/null \
    && ok "…and it names why (the box is half-deployed, and the operator is told in the log he reads)" \
    || bad "a half-deployed box was SILENT — no STALL FIX MISSING line: $(cat "$TMP/D6/dh.log" 2>/dev/null)"
else
  bad "the [drain-health] block is missing — the stall line is unpinned"
fi

echo
echo "=== T7d: the PROBE row is never read as a worker or a reason ==="
# The record's line 1 is the controller's write probe, so the reader must subtract it AND skip it when
# choosing the reason. A 13-byte probe could not detect a nearly-full volume either (review, cycle 3).
# ⛔ THE MARKER IS LOAD-BEARING (review, cycle 4): the assertion below greps the operator line for
# `cycle probe`, so a fixture padded with x's alone made that assertion VACUOUS — it could not fail
# whatever the shipped filter did. The filler carries the marker, at a real row's width.
printf '#\tcycle probe %s\n' "$(printf '%*s' 240 '' | tr ' ' x)" > "$TMP/probe.tsv"
printf 'merge-4242\tcmux layout apply failed: database or disk is full\n' >> "$TMP/probe.tsv"
SPAWNREF_BASE=1 summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3 0 "$TMP/probe.tsv"
grep -q '1 spawn(s) REFUSED' "$TMP/s.log" && grep -q 'layout apply failed' "$TMP/s.log" \
  && ok "the probe row is subtracted and never chosen as the reason (probe + 1 refusal reads 1)" \
  || bad "the probe row leaked into the measurement: $(cat "$TMP/s.log")"
grep -q 'cycle probe' "$TMP/s.log" \
  && bad "the probe row's text reached the operator line" \
  || ok "…and its text never reaches the operator line"

echo
echo "=== T7e: the WRITER's cap is the bound the reader's ≥200 depends on ==="
# Two untested bounds that must agree: the writer stops at 201 LINES (200 refusals + the probe) and the
# reader says `≥200` at 200 refusals. A mutant cap of 200 tops out at 199 refusals, which would print an
# EXACT 199 for a 1,562-refusal storm — the precise-looking understatement the cap wording exists for.
: > "$TMP/O/state/spawn-refused.tsv"
printf '#\t%s\n' "$(printf '%*s' 240 '' | tr ' ' x)" >> "$TMP/O/state/spawn-refused.tsv"
( O="$TMP/O"; WT_DIR="$TMP/O/state"; . "$HERE/worker-terminal.sh"
  _i=0; while [ "$_i" -lt 205 ]; do wt_refusal_record "fix-$_i" "cmux layout apply failed: database or disk is full"; _i=$(( _i + 1 )); done ) 2>/dev/null
_cap_rows="$(awk 'END{print NR+0}' "$TMP/O/state/spawn-refused.tsv")"
[ "$_cap_rows" = "201" ] \
  && ok "the writer stops at 201 lines (200 refusals + the probe) — a storm cannot grow the file" \
  || bad "the writer's bound is $_cap_rows lines for 205 refusals (expected 201)"
# ⛔ COPY FIRST: `summarise` copies its 6th argument INTO the fixture path, so passing that same path
# makes `cp` fail and the fixture truncates the very record under test (measured: 201 rows → 0).
cp "$TMP/O/state/spawn-refused.tsv" "$TMP/capped.tsv"
SPAWNREF_BASE=1 summarise "$(printf '11\tabc\tGREEN\tact\tmerged (gate authority)\n')" 1 open-rows 3 0 "$TMP/capped.tsv"
grep -q '≥200 spawn(s) REFUSED' "$TMP/s.log" \
  && ok "…and a capped record reads ≥200 end to end (writer bound → reader wording)" \
  || bad "the capped record did not read ≥200: $(cat "$TMP/s.log")"

echo
echo "=== T7b: the record's PATH is resolved by the launcher's own resolver ==="
# ⛔ THE SINGLE-SOURCE PIN (review, cycle 2): with two independent spellings of the path, a `WT_DIR`
# seam made the writer fill one file while the controller read another — a measurement of 0 forever.
sed -n '/# \[spawnref:begin\]/,/# \[spawnref:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/ref.sh"
if [ -s "$TMP/ref.sh" ] && grep -q 'wt_refused_file' "$TMP/ref.sh"; then
  resolve() { # resolve <sources-worker-terminal:1|0>
    (
      O="$TMP/R"; WT_DIR="$TMP/R/alt-state"; SPAWNREF=""; SPAWNREF_OK=1; SPAWNREF_WHY_BAD=""
      mkdir -p "$TMP/R/alt-state" "$TMP/R/state"
      [ "${1:-1}" = "1" ] && . "$HERE/worker-terminal.sh"
      . "$TMP/isnum.sh"
      . "$TMP/ref.sh"
      printf 'PATH=%s\nOK=%s\nBASE=%s\nWHY=%s\n' "$SPAWNREF" "$SPAWNREF_OK" "$SPAWNREF_BASE" "$SPAWNREF_WHY_BAD"
    ) 2>/dev/null
  }
  _r="$(resolve 1)"
  case "$_r" in
    *"PATH=$TMP/R/alt-state/spawn-refused.tsv"*"OK=1"*"BASE=1"*)
      ok "with the launcher module: the record resolves through WT_DIR and the probe row was written" ;;
    *) bad "the resolver ignored the launcher's own wt_dir: $(printf '%s' "$_r" | tr '\n' ' ')" ;;
  esac
  # ⛔ THE PROBE'S WIDTH, NOT JUST ITS PRESENCE (review, cycle 4). The shipped probe is padded to the
  # row bound because a SHORT probe passes on a volume with a few free bytes and then every refusal
  # row (up to ~250 B) is dropped: OK=1, N=0, no suffix — a MEASURED zero, the exact false PASS the
  # probe exists to prevent. The case above proves a probe is WRITTEN; only a measurement of the row
  # the SHIPPED code wrote pins its size, so shortening that `printf` could not go green.
  _pw="$(awk -F"$(printf '\t')" 'NR==1{print length($2); exit}' "$TMP/R/alt-state/spawn-refused.tsv" 2>/dev/null)"
  case "${_pw:-}" in ''|*[!0-9]*) _pw=0 ;; esac
  [ "$_pw" -ge 240 ] \
    && ok "the shipped probe row is a real row's width (${_pw} B) — a short probe cannot detect a full volume" \
    || bad "the shipped probe row is only ${_pw} B: a nearly-full volume passes the probe and every refusal is then dropped silently"
  _r="$(resolve 0)"   # no worker-terminal.sh at all = a stale deploy
  case "$_r" in
    *"OK=0"*"predates wt_refused_file"*)
      ok "a stale launcher module reports UNMEASURED, never a silent zero" ;;
    *) bad "a missing writer still claimed a measurement: $(printf '%s' "$_r" | tr '\n' ' ')" ;;
  esac
else
  bad "the [spawnref] resolver block is missing — the measurement's path is untested"
fi

echo
echo "=== T7c: the ISSUE path's refusals are counted as a DELTA, never re-reported ==="
# ⛔ THE `[pr]` LINE ALREADY REPORTED THE PR PHASE (review, cycle 2). Printing the cumulative count on
# the issue-path line over-reports it by exactly the PR-phase count and hands it that phase's reason.
sed -n '/# \[issueref:begin\]/,/# \[issueref:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/issue.sh"
if [ -s "$TMP/issue.sh" ]; then
  issueref() { # issueref <base-lines> <pr-phase-refusals> <issue-path-refusals>
    : > "$TMP/i.tsv"
    printf '#\tcycle probe\n' >> "$TMP/i.tsv"
    _j=0
    while [ "$_j" -lt "${2:-0}" ]; do printf 'fix-1%s\tPR phase: cmux layout apply failed\n' "$_j" >> "$TMP/i.tsv"; _j=$(( _j + 1 )); done
    _j=0
    while [ "$_j" -lt "${3:-0}" ]; do printf 'fix-2%s\tISSUE phase: cmux layout apply failed: database or disk is full\n' "$_j" >> "$TMP/i.tsv"; _j=$(( _j + 1 )); done
    : > "$TMP/i.log"
    (
      SPAWNREF="$TMP/i.tsv"; SPAWNREF_OK=1; SPAWNREF_BASE="$1"; SPAWNREF_N="$2"; LOG="$TMP/i.log"
      . "$TMP/isnum.sh"
      . "$TMP/issue.sh"
    ) >/dev/null 2>&1
    cat "$TMP/i.log"
  }
  _o="$(issueref 1 1 3)"
  grep -q '⛔ 3 spawn(s) REFUSED' <<<"$_o" \
    && ok "1 PR-phase + 3 issue-path refusals: the issue line reports 3, not the cumulative 4" \
    || bad "the issue line over-reported: $(printf '%s' "$_o" | tr '\n' ' ')"
  # ⛔ THE REASON'S IDENTITY IS THE CLAIM (review, cycle 4): a count alone stays green while the line
  # attributes the PR phase's reason to issue-path refusals. The fixture writes two distinct reasons.
  grep -q 'ISSUE phase' <<<"$_o" && ! grep -q 'PR phase' <<<"$_o" \
    && ok "…and the reason is the first NEW row's (issue phase), never the PR phase's" \
    || bad "the issue line attributes the wrong phase's reason: $(printf '%s' "$_o" | tr '\n' ' ')"
  _o="$(issueref 1 4 0)"
  [ -z "$_o" ] \
    && ok "…and with no issue-path refusal it prints NOTHING (no duplicate of the [pr] line)" \
    || bad "an issue-path line was printed with no issue-path refusal: $(printf '%s' "$_o" | tr '\n' ' ')"
  # ⛔ THE CAP IS NOT SILENCE (review, cycle 4): a storm that the PR phase already saturated leaves the
  # issue path with nothing to add — and the writer refuses further rows, so "no delta" would read as
  # "nothing was refused" when in fact nothing could be RECORDED.
  _o="$(issueref 1 200 0)"
  grep -q 'at its 200-row cap' <<<"$_o" && grep -q 'UNMEASURED' <<<"$_o" \
    && ok "a record the PR phase saturated says the ISSUE path is UNMEASURED (never a silent zero)" \
    || bad "a saturated record left the issue path silent: $(printf '%s' "$_o" | tr '\n' ' ')"
else
  bad "the [issueref] block is missing — the issue path's measurement is untested"
fi

echo
echo "=== T8: merge-priority active + ONE un-owned PR + free workers -> exactly ONE lander ==="
# The owner's ruling (2026-10-18): while ONE un-owned PR remains, the PR queue is the work. That
# closes the ISSUE path — it must never silence the PR path, because the PR path IS the work. This
# binds the shipped gate to the shipped spawn so a future edit cannot satisfy the ruling by
# dispatching nothing at all (the six-hour shape: "the queue is the work" printed, zero lanes).
sed -n '/^mp_reason() {/,/^}/p' "$ORCH" > "$TMP/mp.sh"
[ -s "$TMP/mp.sh" ] && grep -q 'PRs before issues' "$TMP/mp.sh" \
  && ok "the shipped merge-priority rule is extracted (the ruling itself, not a copy)" \
  || bad "mp_reason() was not found in orch-loop.sh"
_gate() { ( . "$TMP/isnum.sh"; . "$TMP/mp.sh"; mp_reason "$@" ); }
_GATE_ON="$(_gate 1 0 0 3)"; _GATE_OFF="$(_gate 0 0 0 3)"
[ -n "$_GATE_ON" ] && [ -z "$_GATE_OFF" ] \
  && ok "1 un-owned closes the issue path; 0 un-owned opens it — the guard is unchanged" \
  || bad "the gate reads un-owned=1 as '${_GATE_ON:-<empty>}' and 0 as '${_GATE_OFF:-<empty>}'"
# ⛔ THE POPULATION IS THE INPUT, NOT A COMMENT (review, cycle 2): `drive` used to run one fixed PR
# whatever the gate said, so "with merge-priority ACTIVE" was a claim the code never consumed. Both
# halves below drive the SHIPPED acting case over a population, so the count follows the rows.
if [ -n "$_GATE_ON" ]; then
  drive_rows "$(printf '4242\tabc1234')" rail 1
  grep -q 'wt-merge-4242' "$TMP/spy" && [ "$(spawns)" = "1" ] && [ "$(acts)" = "1" ] \
    && ok "with merge-priority ACTIVE + 1 un-owned PR + free workers: exactly ONE spawn, the lander merge-4242" \
    || bad "merge-priority active: spawns=$(spawns) acts=$(acts) — the PR path is not the work here"
  # ⛔ THE CONTRAST HALF (review, cycle 3): on its own this cannot fail — a row loop over nothing runs
  # nothing. It is the second half of a PAIR: the 1-row case above goes red if the population plumbing
  # breaks (a driver that ignores its rows), and this one goes red if it ever fabricates a row (a
  # driver that reads a blank line as a PR). Neither is a claim about `mp_reason` itself — the gate is
  # graded separately, immediately above, and the two are deliberately not conflated.
  drive_rows "" rail 1
  [ "$(spawns)" = "0" ] && [ "$(acts)" = "0" ] && [ "$(rows)" = "0" ] \
    && ok "ZERO un-owned PRs: the same shipped arm over an empty population dispatches NOTHING (contrast half)" \
    || bad "an empty population still dispatched (spawns=$(spawns) acts=$(acts) rows=$(rows))"
else
  bad "the merge-priority gate did not fire on 1 un-owned PR — T8 cannot bind"
fi

echo
echo "=== T9 (#2831): a PR a LIVE worker owns is never stolen, and the same arm still spawns when it is not ==="
# ⛔ THE PAIR IS THE TEST. A one-sided assertion ("owned -> no spawn") passes on an arm that NEVER
# spawns, and the real defect (#2831) was exactly that: 5 PRs reported "a worker already owns this PR"
# with no workers alive, so nothing was ever taken. The contrast half — same arm, same fixture, owner
# NOT live — must spawn, or the ownership guard is indistinguishable from an inert arm.
OWN_LIVE=1 drive 'FAILED:pipeline-compliance' rail 0 1
_owns_n="$(spawns)"; _owns_rows="$(rows)"; _owns_why="$(cat "$LEDGER" 2>/dev/null | awk -F'\t' '$4=="wait"{print $5}' | head -1)"
[ "$_owns_n" = "0" ] && [ "$_owns_rows" -ge 1 ] \
  && ok "a LIVE owner: 0 spawns, and the PR still carries a named wait ($_owns_rows row(s))" \
  || bad "a live owner was not respected: spawns=$_owns_n rows=$_owns_rows"
case "$_owns_why" in
  *"already owns this PR"*) ok "…and the wait names OWNERSHIP, not capacity (so the reason a reader sees is the truth)" ;;
  *) bad "…the wait reason is not ownership: '$_owns_why'" ;;
esac
OWN_LIVE=0 drive 'FAILED:pipeline-compliance' rail 0 1
[ "$(spawns)" = "1" ] \
  && ok "CONTRAST: with the owner NOT live the same arm spawns the fixer (so the guard above is not an inert arm)" \
  || bad "CONTRAST half failed: the arm spawned nothing even with no owner (spawns=$(spawns)) — the ownership assertion above would be vacuous"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]

# zzprobe 144417
