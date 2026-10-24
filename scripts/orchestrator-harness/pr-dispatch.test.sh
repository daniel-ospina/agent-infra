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
# ⛔ A PER-RUN directory: a fixed path is shared by two concurrent lanes on one box, and one run's
# truncation would wipe the other's rows mid-flight (a flaky red, and — worse — `acts()` could read the
# OTHER run's act row and PASS the exact assertion this suite exists for).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

[ -f "$ORCH" ] || { echo "FATAL: $ORCH not found"; exit 1; }

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
[ -s "$TMP/shq.sh" ] || { echo "FATAL: shq() not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/isnum.sh" ] || { echo "FATAL: is_num() not found in orch-loop.sh"; exit 1; }
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
    tmux() { return 1; }
    sess() { return 1; }
    claim_live() { return 1; }
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
    # layer down. `CIQ_PUSH_RC=1` is how an arm asks for the deferred world.
    ciq_push_ok() { return "${CIQ_PUSH_RC:-0}"; }
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
    tmux() { return 1; }   # see drive(): the host's live worker sessions must not leak into the census
    sess() { return 1; }; claim_live() { return 1; }; can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }; park_ctrl() { return 0; }
    # …and the CI-queue predicate for the same reason as `drive()` above: the CONFLICTING arm now
    # calls `ciq_push_ok`, and an undefined command is `! 127` = TRUE = DEFER, which would make this
    # rig unable to prove the conflict path ever dispatches.
    ciq_push_ok() { return "${CIQ_PUSH_RC:-0}"; }
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
# ⛔ THE DEFERRAL ITSELF IS DRIVEN, NOT MERELY STUBBED (#2333 review cycle 2, P1). Without this arm
# the new gate is exercised only by its own module suite, and the wiring's failure mode — a deferral
# that spawns anyway, or one that is recorded as an ACT — would be invisible here.
CIQ_PUSH_RC=1; drive_conflict 0; unset CIQ_PUSH_RC
[ "$(spawns)" -eq 0 ] && [ "$(acts)" = "0" ] && [ "$(waits)" = "1" ] && grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "CONFLICTING on a deep/unknown CI queue: NO spawn, ONE wait row, and the deferral is NAMED" \
  || bad "CONFLICTING on a CI-queue deferral: spawns=$(spawns) acts=$(acts) waits=$(waits) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
# ⛔ THE OTHER TWO PUSHERS' DEFER ARMS ARE DRIVEN TOO, NOT MERELY GREPPED (#2333 review, P2). The
# review-gate fixer and the CI-red fixer each carry a defer arm of their own, and before these arms
# they were pinned ONLY by text greps on the call site (`ci-queue.test.sh` e4b/e4c/e6) — so a defer
# branch that ALSO SPAWNED (moving the `printf … > argv-$PR` / `wt_spawn` into the defer body) kept
# every arm green while the gate silently stopped deferring on two of the four CI-spending surfaces.
# That is exactly the class the CONFLICTED drive above was added for, one arm short.
CIQ_PUSH_RC=1; drive 'FAILED:pipeline-compliance' rail 0 1; unset CIQ_PUSH_RC
[ "$(spawns)" -eq 0 ] && [ "$(acts)" = "0" ] && [ "$(waits)" -ge 1 ] && grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "CI-red fixer on a deep/unknown CI queue: NO spawn, a wait row, and the deferral is NAMED" \
  || bad "CI-red fixer on a CI-queue deferral: spawns=$(spawns) acts=$(acts) waits=$(waits) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
# The review-gate arm only reaches ITS defer branch for a PR with FINDINGS at this head (a head with
# none is a re-record, which spends no CI), so the needsfix marker is supplied — otherwise this drive
# would exercise the re-record path and prove nothing about the defer arm.
NEEDSFIX=1; CIQ_PUSH_RC=1; drive 'FAILED:ai-review-gate' rail 0 1; unset NEEDSFIX CIQ_PUSH_RC
[ "$(spawns)" -eq 0 ] && [ "$(acts)" = "0" ] && [ "$(waits)" -ge 1 ] && grep -q 'ci-queue\] DEFERRED' "$TMP/d.log" \
  && ok "review-gate fixer on a deep/unknown CI queue: NO spawn, a wait row, and the deferral is NAMED" \
  || bad "review-gate fixer on a CI-queue deferral: spawns=$(spawns) acts=$(acts) waits=$(waits) log=$(head -2 "$TMP/d.log" | tr '\n' ';')"
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
# ⛔ THE REVIEW-GATE ARM IS ONLY REACHED FOR A HEAD WITH NO FINDINGS (#2132). The T5 drives above leave
# a `needsfix-4242-abc1234` marker behind (they need it to exercise the DEFER arm), and every drive
# here shares ONE `$O/state`. Leaving it in place routes these drives into the FIXER arm and the whole
# section would then grade a path it never reached — measured: (a) reported "spawns=1" for a fixer.
clear_needsfix() { mv "$TMP/O/state/needsfix-4242-abc1234" "$TMP/needsfix.spent.$RANDOM" 2>/dev/null || true; }
# ⛔ A DRIVE THAT SPAWNS LEAVES A WORKER RECORD, WHICH INFLATES THE NEXT DRIVE'S CENSUS (measured):
# the `lanes-in-use` fixture says 9, and a leftover `worker-merge-4242` made the same assertion read
# `review lanes=10/9`. Records are files, so move the ones this fixture's PR could own out of the way —
# `mv`, never `rm` on a `$TMP/…` path (#709).
clear_workers() {
  local f
  for f in "$TMP/O/state"/worker-* "$TMP/O/state/.wt-census"; do
    [ -e "$f" ] && mv "$f" "$TMP/worker.spent.$RANDOM" 2>/dev/null
  done
  return 0
}
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
   && grep -q 'LIFT THIS PARK' "$TMP/d.log"; then
  ok "(b5) AT-HEAD at the bound PARKS with REVIEW-AT-HEAD-STUCK, the exact re-record command, AND the park-lift (a re-record alone is provably inert)"
else
  bad "(b5) parked=[$(cat "$TMP/O/state/parked-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log") — the recorded-review/red-gate state never escalates, or its command was eaten by a backtick substitution"
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
# ⛔ THE NUMERATOR IS NOT PINNED HERE (measured): `wt_table` also counts worker-named TMUX sessions that
# have no record of their own, and on a box where the controller is RUNNING those are real — the count
# then reads `12/9` instead of `9/9` and the assertion depended on what the machine was doing. What the
# arm must prove is the REFUSAL plus the NAME: the ceiling is reached (`=N/9`) and the holders are listed
# with their age. The fixture's own contribution is still the 9 merge lanes the `lanes-in-use` knob writes.
if [ "$(spawns)" = "0" ] && grep -Eq 'NO re-record slot \(review lanes=[0-9]+/9' "$TMP/d.log" \
   && grep -q 'holding: merge-0(120m)' "$TMP/d.log"; then
  ok "(d) review-lane ceiling reached => refused, and the line names the lanes holding it WITH their age"
else
  bad "(d) spawns=$(spawns) key=[$(cat "$REV_DISP" 2>/dev/null)] athead=[$(cat "$TMP/O/state/reviewathead-4242" 2>/dev/null)] log=$(tr '\n' ';' < "$TMP/d.log") — a count with no owner is the state that hid the stall"
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
  summarise() { # summarise <ledger-bytes> <PRDISP_OK> <POP> <UPN_WORK>
    : > "$TMP/s.log"; printf '%s' "$1" > "$TMP/s.tsv"
    (
      O="$TMP/O"; LOG="$TMP/s.log"; PRDISP="$TMP/s.tsv"; PRDISP_OK="$2"; POP="$3"; UPN_WORK="$4"
      SCOPE_MODE=BROAD; FLOOR_NOTE=""; PR_FIRST_TOK=""
      WT_DIR="$TMP/O/state"; WT_TABLE_TTL=0
      # shellcheck disable=SC1090
      . "$HERE/worker-terminal.sh"
      cmux() { printf '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}\n'; return 0; }
      . "$TMP/isnum.sh"
      . "$TMP/sum.sh"
      printf 'FIRSTTOK=%s\n' "$PR_FIRST_TOK"
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
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]

# zzprobe 144417
