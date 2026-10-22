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
  : > "$TMP/spy"; : > "$TMP/gspy"; : > "$TMP/d.log"; mkdir -p "$TMP/O/state"; : > "$LEDGER"
  # `lanes-in-use` fake rows: half fix-, half merge-, so BOTH ceilings are reachable from one knob.
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
    MF=9; MR=9; MAX_FIX_TRIES=3; REQ='ai-review-gate python-ci-gate pipeline-compliance'
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
    sess() { return 1; }
    claim_live() { return 1; }
    can_spawn() { return 0; }
    refund_bailed_fixer() { return 0; }
    park_ctrl() { return 0; }
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

echo
echo "=== T1: a claim has a spawn behind it, and a failed spawn is never silent ==="
drive GREEN rail 0 1
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
sed -n '/# \[drain-health:begin\]/,/# \[drain-health:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/dh.sh"
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
  # ⛔ THE SECOND ARM IS THE ONE THAT PRINTS FOR A REAL STALL (review, cycle 4): `mp_recent_land` only
  # ever returns a stamp inside 2x the gate's window, so arm 1 covers the 180–360m band — while the
  # measured incident ran SIX HOURS. Once nothing landed inside that bound the function returns empty
  # and arm 2 prints; leaving it unpinned left the six-hour stall line itself untested.
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
else
  bad "the [drain-health] block is missing — the stall line is unpinned"
fi

echo
echo "=== T7d: the PROBE row is never read as a worker or a reason ==="
# The record's line 1 is the controller's write probe, so the reader must subtract it AND skip it when
# choosing the reason. A 13-byte probe could not detect a nearly-full volume either (review, cycle 3).
printf '#\t%s\n' "$(printf '%*s' 240 '' | tr ' ' x)" > "$TMP/probe.tsv"
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
  printf '%s' "$_o" | grep -q '⛔ 3 spawn(s) REFUSED' \
    && ok "1 PR-phase + 3 issue-path refusals: the issue line reports 3, not the cumulative 4" \
    || bad "the issue line over-reported: $(printf '%s' "$_o" | tr '\n' ' ')"
  # ⛔ THE REASON'S IDENTITY IS THE CLAIM (review, cycle 4): a count alone stays green while the line
  # attributes the PR phase's reason to issue-path refusals. The fixture writes two distinct reasons.
  printf '%s' "$_o" | grep -q 'ISSUE phase' && ! printf '%s' "$_o" | grep -q 'PR phase' \
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
  printf '%s' "$_o" | grep -q 'at its 200-row cap' && printf '%s' "$_o" | grep -q 'UNMEASURED' \
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
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]

# zzprobe 144417
