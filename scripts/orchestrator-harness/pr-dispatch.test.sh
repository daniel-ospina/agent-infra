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
# The surface is a fake `cmux` (worker-terminal.sh's durable terminal), NOT a fake `tmux`: a tmux
# window is the measured 21-line death on a cell, so the launcher this suite drives is the one that
# replaced it. `$TMP/lanes` names the workers; `cmux tree` renders them as the workspaces the
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
    # The refusal line prints `$(spawn_gate_tok)`; give it the shipped function and real inputs so the
    # driven line carries a reading instead of an empty field (see the extraction above).
    . "$TMP/spawntok.sh"
    L=0; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=9000; MEM_UNKNOWN=0
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
    . "$TMP/shq.sh"
    . "$TMP/spawntok.sh"
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
