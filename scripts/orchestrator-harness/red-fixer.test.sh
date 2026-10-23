#!/bin/bash
# red-fixer.test.sh — the controller's RED-FIXER role (spawn-on-refusal).
#
# WHAT THIS SUITE IS FOR. Measured 2026-10-20: open=17, thirteen rails "running", ONE merge that
# day, and ZERO agent lanes on the cells. A rail refuses a red tree by design; nothing turned that
# refusal into work, so the queue looked busy and nothing moved. The role added here is:
#
#     rail refuses (RED TREE) -> record it (head-bound) -> spawn ONE fixer for that PR
#                             -> when the head moves, drop the refusal and RE-RAIL
#                             -> after the caps, record + park (never loop)
#
# ⛔ EVERY ASSERTION IS BEHAVIOURAL, and driven against a FAKE RAIL. Nothing here greps orch-loop.sh
# for a sentence: the shipped fragment is EXTRACTED and executed, the fake rail really exits with a
# real refusal string, and the assertions are on what actually ran (sessions spawned, state files
# written, the ledger rows produced). A prose test passes on the sentence and on its absence alike —
# the defect class this repo has paid for repeatedly.
#
# ⛔ HERMETIC: no network, no gh, no tmux, no real $HOME. `gh` is never called by the router, `tmux`
# is a function stub, and every state directory is a mktemp.
#
# Run: bash scripts/orchestrator-harness/red-fixer.test.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$HERE/orch-loop.sh"
MERGE="$HERE/merge-one.sh"
MOD="$HERE/rail-refusal.sh"
# A PER-RUN directory: a fixed path would be shared by two concurrent lanes on one box and one run's
# truncation would wipe the other's rows mid-flight (a flaky red that grades the wrong run).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# ⛔ 40-CHAR SHAS, DELIBERATELY (review P2, cycle 7). Every head here used to be 8 hex chars, which
# cannot tell a full-sha comparison from a truncated one: a writer storing `${HEAD:0:12}` or a reader
# comparing `${HEAD_N:0:8}` makes EVERY refusal read as stale at a real 40-char head — the role then
# never spawns a fixer while the log reports a clean re-rail — and the suite stayed green. The (4d)
# cases additionally pin a genuine PREFIX as a DIFFERENT head.
H1=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
H2=cafe1234cafe1234cafe1234cafe1234cafe1234
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

for f in "$ORCH" "$MERGE" "$MOD"; do
  [ -f "$f" ] || { echo "FATAL: $f not found"; exit 1; }
done

# ── extraction: the shipped fragments (markers, so a refactor that drops them fails loudly) ──────
sed -n '/# \[redfix:begin\]/,/# \[redfix:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/redfix.sh"
if [ -s "$TMP/redfix.sh" ] && grep -q 'RED TREE ->' "$TMP/redfix.sh"; then
  ok "the red-fixer router is extracted from the shipped loop ($(awk 'END{print NR}' "$TMP/redfix.sh") lines)"
else
  bad "the [redfix] block is missing or does not parse — the whole role is gone"
fi
sed -n '/# \[railrefusal-doctor:begin\]/,/# \[railrefusal-doctor:end\]/p' "$HERE/cloud-cell-doctor.sh" | sed '1d;$d' > "$TMP/doctor-recorder.sh"
if [ -s "$TMP/doctor-recorder.sh" ] && grep -q 'rail_refusal_record' "$TMP/doctor-recorder.sh"; then
  ok "the cell doctor's RECORDER is extracted too (it executes the same rail, so it is a second writer)"
else
  bad "the doctor's [railrefusal-doctor] block is missing — a refusal its merge role makes is never recorded"
fi
sed -n '/# \[railrefusal:begin\]/,/# \[railrefusal:end\]/p' "$MERGE" | sed '1d;$d' > "$TMP/recorder.sh"
if [ -s "$TMP/recorder.sh" ] && grep -q 'rail_refusal_record' "$TMP/recorder.sh"; then
  ok "the rail-refusal RECORDER is extracted from merge-one.sh (the one place that runs the rail)"
else
  bad "the [railrefusal] block is missing — a refusal would never be recorded"
fi
# The shipped validators the fragments call, taken from the files that ship them (not re-invented).
grep -E '^is_num\(\) \{' "$ORCH" > "$TMP/isnum.sh"
grep -E '^is_limit\(\) \{' "$ORCH" >> "$TMP/isnum.sh"
grep -E '^refund_bailed_fixer\(\) \{' "$ORCH" > "$TMP/refund.sh"
sed -n '/^refund_bailed_fixer() {/,/^}/p' "$ORCH" > "$TMP/refund.sh"
# `head_reds` is the shipped clearance predicate (is ANY check red at this head) — extracted, not
# stubbed, so its allow-list polarity is what the GREEN/UNKNOWN cases actually exercise.
sed -n '/# \[fixgate-refund:begin\]/,/# \[fixgate-refund:end\]/p' "$HERE/fix-one.sh" | sed '1d;$d' > "$TMP/gaterefund.sh"
if [ -s "$TMP/gaterefund.sh" ] && grep -q 'fixgate-' "$TMP/gaterefund.sh"; then
  ok "the fixer's gate-refusal REFUND is extracted from fix-one.sh (the PRODUCER of fixgate-*, driven below)"
else
  bad "the [fixgate-refund] block is missing from fix-one.sh — the per-head refund would have no producer"
fi
sed -n '/^head_reds() {/,/^}/p' "$ORCH" > "$TMP/headreds.sh"
[ -s "$TMP/headreds.sh" ] || { echo "FATAL: head_reds not found in orch-loop.sh"; exit 1; }
# [railrefusal] is a plain statement block inside a function in merge-one.sh; at FILE scope the
# function-local `local`s it does not use are fine, but `tail`/`wc` are external on purpose.
[ -s "$TMP/isnum.sh" ] || { echo "FATAL: is_num/is_limit not found in orch-loop.sh"; exit 1; }
[ -s "$TMP/refund.sh" ] || { echo "FATAL: refund_bailed_fixer not found in orch-loop.sh"; exit 1; }

# ── the FAKE RAIL ───────────────────────────────────────────────────────────────
# A real script with a real exit status and real stderr, because the recorder's whole job is to
# interpret what a rail WROTE. `--mode` selects the refusal shape.
mk_rail() { # mk_rail <path> <mode>
  local p="$1" mode="$2"
  cat > "$p" <<RAIL
#!/usr/bin/env bash
case "$mode" in
  red)
    echo "admin-merge: the lane 'python-ci' is green on both sides"
    echo "admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED." >&2
    echo "   evaluated tree: 2 failing on head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >&2
    echo "   - lint (agent-infra-ci)" >&2
    echo "   AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge attempted." >&2
    exit 1 ;;
  green)
    echo "admin-merge: ✅ merged #777"
    exit 0 ;;
  draft)
    echo "admin-merge: ✗ BLOCK — PR #777 is a DRAFT, and gh refuses to merge a draft" >&2
    exit 1 ;;
  conflict)
    echo "admin-merge: ✗ BLOCK — the PR is CONFLICTING with its base" >&2
    exit 1 ;;
  unreadable)
    echo "admin-merge: ✗ BLOCK — the PR's evaluated-tree surface could NOT be read, so the" >&2
    exit 1 ;;
esac
RAIL
  chmod +x "$p"
}

# ── drive the RECORDER: run the shipped fragment with the fake rail ─────────────
# drive_rec <mode> [<override-in-play:0|1>] [<pre-log-lines>""] [<no-module:0>] [<attempts:1>]
# Writes: $TMP/rO/state/railrefusal-777 (the record)   $TMP/rO/logs/merge-777.log
drive_rec() {
  rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state" "$TMP/rO/logs" "$TMP/repo"
  mk_rail "$TMP/fake-rail.sh" "$1"
  (
    PR=777; HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; O="$TMP/rO"; L="$TMP/rO/logs/merge-777"
    REPO="$TMP/repo"; OR=daniel-ospina/agent-infra; RAIL="$TMP/fake-rail.sh"
    RAIL_TRIES=3; RC_N="${5:-1}"
    if [ "${3:-}" != "" ]; then printf '%b' "$3" > "$L.log"; else : > "$L.log"; fi
    . "$TMP/isnum.sh"
    [ "${4:-0}" = "1" ] || . "$MOD"
    if [ "${2:-0}" = "1" ]; then AGENT_ADMIN_MERGE_OVERRIDE=1; else unset AGENT_ADMIN_MERGE_OVERRIDE; fi
    . "$TMP/recorder.sh"
  ) >/dev/null 2>&1
}
rec_field() { ( . "$MOD"; rail_refusal_field "$TMP/rO" 777 "${1:-}" 2>/dev/null ); }

echo
echo "=== A: the recorder turns the rail's own words into a head-bound record ==="
drive_rec red
[ "$(rec_field class)" = "red-tree" ] \
  && ok "a RED-TREE refusal is recorded as class=red-tree" \
  || bad "class=[$(rec_field class)] — the trigger the whole role hangs on is not recorded"
[ "$(rec_field head)" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && ok "the record is HEAD-BOUND (head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef) — the key that lets a push invalidate it" \
  || bad "head=[$(rec_field head)] — an un-head-bound refusal outlives the tree it describes"
case "$(rec_field reason)" in
  *'THE TREE THIS PR PRODUCES IS RED'*) ok "the refusal is stored VERBATIM: '$(rec_field reason)'" ;;
  *) bad "reason=[$(rec_field reason)] — the operator cannot see the rail's own sentence" ;;
esac
case "$(rec_field detail)" in
  *'2 failing on head'*) ok "the rail's summary line is kept beside the verdict" ;;
  *) bad "detail=[$(rec_field detail)] — the failing-check evidence was lost" ;;
esac
grep -q 'refusal recorded: class=red-tree' "$TMP/rO/logs/merge-777.log" \
  && ok "the worker log names the recorded class (a refusal that is recorded silently is untraceable)" \
  || bad "no 'refusal recorded' line in merge-777.log"

drive_rec green
grep -q 'MERGED via the rail' "$TMP/rO/logs/merge-777.log" \
  && ok "the green case actually drove the fake rail to a MERGE (not a no-op fixture)" \
  || bad "the green fixture never ran the rail — the assertion below would be vacuous"
[ ! -f "$TMP/rO/state/railrefusal-777" ] \
  && ok "a MERGE records nothing (no refusal to act on)" \
  || bad "a merge left a refusal record behind — a stale verdict on a landed PR"
# ...and it CLEARS an older refusal for the same PR.
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf 'head=old\nclass=red-tree\nreason=old\n' > "$TMP/rO/state/railrefusal-777"
mk_rail "$TMP/fake-rail.sh" green
( PR=777; HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; O="$TMP/rO"; L="$TMP/rO/logs/m"; mkdir -p "$TMP/rO/logs"
  REPO="$TMP/repo"; OR=o/r; RAIL="$TMP/fake-rail.sh"; RAIL_TRIES=3; RC_N=1
  . "$TMP/isnum.sh"; . "$MOD"; . "$TMP/recorder.sh" ) >/dev/null 2>&1
[ ! -f "$TMP/rO/state/railrefusal-777" ] \
  && ok "a MERGE clears the old refusal (a landed PR carries no verdict)" \
  || bad "a merged PR kept its old refusal record"

drive_rec red 1
[ "$(rec_field class)" = "override" ] \
  && ok "the AUDITED OVERRIDE path is classed \`override\` — a deliberate red merge is not a defect" \
  || bad "class=[$(rec_field class)] with the override in play — a decision would be 'repaired'"

# ⛔ THE OFFSET IS THE POINT: the log already holds an EARLIER red-tree refusal (a previous attempt,
# or a previous head). Classifying the whole log would resurrect that old verdict and spawn a fixer
# for a refusal that is no longer true. This attempt's rail says DRAFT-only.
drive_rec draft 0 'admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n'
case "$(rec_field class)" in
  other) ok "only THIS attempt's words are classified (the older red-tree line in the log did not win: class=other)" ;;
  red-tree) bad "an OLD red-tree line in the log was re-classified as this attempt's — the whole-log read is back" ;;
  *) bad "expected class=other from a draft-only attempt, got '[$(rec_field class)]' (an absent/garbled record must not pass)" ;;
esac

for mode in conflict unreadable; do
  drive_rec "$mode"
  case "$(rec_field class)" in
    "$mode") ok "class '$mode' is named for a $mode refusal (no fixer: a lane cannot repair it)" ;;
    *) bad "$mode refusal classed '$(rec_field class)' — the classifier is not separating repairable from unrepairable" ;;
  esac
done

drive_rec red 0 "" 1
grep -q 'REFUSAL NOT RECORDED' "$TMP/rO/logs/merge-777.log" \
  && ok "a missing/stale module is SAID LOUDLY (not a silent no-op) and the merge path still runs" \
  || bad "without rail-refusal.sh the refusal path said nothing — a silent no-op"

echo
echo "=== B: the router spawns ONE fixer on a refusal, and re-rails when the head moves ==="
# ── the driver for the ROUTER ───────────────────────────────────────────────────
# drive_route <record-class> <record-head> <HEAD_N> <lanes-in-use:0> <spawn-ok:1> <attempts:0> <head-for-attempts:->
#             <live-fixer:0> <bail:0>
# The shipped block ends in `continue` (a syntax error at file scope), so it runs inside a
# one-iteration `for`; the `break` after it also makes FALL-THROUGH observable — a block that
# `continue`s never reaches the marker after it.
drive_route() {
  [ "${KEEP:-0}" = "1" ] || rm -rf "$TMP/rO"
  mkdir -p "$TMP/rO/state"
  : > "$TMP/spy"; : > "$TMP/d.log"; : > "$TMP/rows"
  : > "$TMP/lanes"; _i=0
  while [ "$_i" -lt "${4:-0}" ]; do echo "fix-$_i" >> "$TMP/lanes"; _i=$((_i+1)); done
  if [ "${1:-none}" != "none" ] && { [ "${SEED_REC:-0}" = "1" ] || [ "${KEEP:-0}" != "1" ]; }; then
    { echo "head=${2:-}"; echo "class=${1}"; echo "attempt=1"; echo "override=0"
      echo "reason=admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED."
      echo "detail=   evaluated tree: 2 failing on head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; } > "$TMP/rO/state/railrefusal-4242"
  fi
  case "${6:-0}" in 0) : ;; *) printf '%s %s\n' "${7:-}" "$6" > "$TMP/rO/state/redfix-4242" ;; esac
  case "${COUNTER_MODE:-normal}" in
    torn)       : > "$TMP/rO/state/redfix-4242"; chmod 000 "$TMP/rO/state/redfix-4242" 2>/dev/null; chmod 644 "$TMP/rO/state/redfix-4242" 2>/dev/null ;;
    unreadable) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1\n' > "$TMP/rO/state/redfix-4242"; chmod 000 "$TMP/rO/state/redfix-4242" ;;
    unwritable) rm -f "$TMP/rO/state/redfix-4242"; mkdir -p "$TMP/rO/state/redfix-4242" ;;
  esac
  [ "${9:-0}" = "1" ] && : > "$TMP/rO/state/fixbail-4242-${3}"
  (
    PR=4242; BR=fix/thing; OR=daniel-ospina/agent-infra; REPO=/nonexistent
    O="$TMP/rO"; LOG="$TMP/d.log"; HEAD_N="${3:-}"
    REDFIX=1; MAX_RED_FIX="${MAX_RED_FIX_OVERRIDE:-4}"; MAX_RED_FIX_TRIES="${MAX_RED_FIX_TRIES_OVERRIDE:-2}"; MAX_LOAD=999; L=1
    . "$TMP/isnum.sh"
    . "$MOD"
    . "$TMP/refund.sh"
    if [ "${HEAD_REDS_EMPTY:-0}" = "1" ]; then head_reds() { :; }; else . "$TMP/headreds.sh"; fi
    session_live="${8:-0}"; SPAWN_OK="${5:-1}"; MERGE_LIVE="${MERGE_LIVE:-0}"
    SURF="${SURF:-RED}"; CLAIM_HELD="${CLAIM_HELD:-0}"
    sess() {
      case "$1" in
        "fix-4242")   [ "$session_live" = "1" ]; return ;;
        # The rail/review worker for the SAME PR — the guard that makes "one worker per PR" true
        # across roles. Unstubbed, its removal was a mutation the suite could not see.
        "merge-4242") [ "$MERGE_LIVE" = "1" ]; return ;;
      esac
      return 1
    }
    # ⛔ ASSERT THE HEAD ARGUMENT (review P2, cycle 7). `claim_lease_live` returns 1 immediately when
    # the sha is empty, so `claim_live "$PR"` without it makes the cross-box arm dead in production
    # while a stub that ignores its arguments keeps the suite green.
    claim_live() { [ "$2" = "$HEAD_N" ] && [ "$CLAIM_HELD" = "1" ]; }
    # `head_reds` asks gh; the stub answers the three shapes it can return. A stub that printed
    # nothing would make the role read UNKNOWN everywhere and silently grade the wrong branch.
    gh() { printf '[{"name":"lint","state":"%s"}]\n' "${GH_STATE:-FAILURE}"; return 0; }
    can_spawn() { return 0; }
    # A ledger row is a TAB-delimited record; the summary counts act vs wait, so the stub records
    # which it was (the router's claim "it acted" must be checkable).
    disp() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$TMP/rows"; }
    park_ctrl() { printf '%s\n' "$3" > "$TMP/rO/state/parkreason-$1"; printf '%s\n' "$2" > "$TMP/rO/state/parked-$1"; }
    tmux() {
      case "$1" in
        ls) cat "$TMP/lanes" 2>/dev/null; return 0 ;;
        # NO trailing `return 0`: a stub that always succeeds would make the "spawn FAILED" case a
        # tautology (pr-dispatch.test.sh documents the same trap).
        new-session) echo "TMUX $*" >> "$TMP/spy"; [ "$SPAWN_OK" = "1" ]; return ;;
      esac
      return 0
    }
    # ⛔ THE SPAWN SURFACE IS THE LAUNCHER, NOT A HAND-WRITTEN COMMAND (agent-infra#2209/#2210). The
    # controller spawns through `worker-terminal.sh`, so a worker gets a daemon-OWNED durable terminal
    # where the cmux daemon answers and tmux WITH the HOME+keys.env contract where it does not — a
    # credential-less worker dies early (the `~21 log lines` death was the environment, agent-infra#2210
    # reopened), and a dead red-fixer is indistinguishable from one that found nothing to fix. The stubs below answer the launcher's own
    # verbs and record into the SAME spy, in the SAME `<session> -- <command>` shape the assertions
    # already read — so every arm keeps testing what it was written to test, and the `wt_count`
    # default (an EMPTY census line) is what a box with no workers really answers.
    # ⚠️ Unstubbed, these verbs made the cap test read an empty string, so EVERY drive fell into the
    # capacity `else` and 24 arms died against a controller that was correct (found in review of the
    # #2232 integration, 2026-10-21).
    wt_count() {
      local pre="$1"; awk -v p="$pre" 'index($0,p)==1' "$TMP/lanes" 2>/dev/null | awk 'END{print NR+0}'
    }
    wt_spawn() {
      local name="$1"; shift 2            # <name> <cwd> <command...>
      echo "TMUX -s $name -- $*" >> "$TMP/spy"
      [ "$SPAWN_OK" = "1" ]
    }
    wt_alive() { sess "$1"; }
    for _once in 1; do
      . "$TMP/redfix.sh"
      echo FALLTHROUGH >> "$TMP/d.log"
      break
    done
  ) >/dev/null 2>&1
}
spawns()   { awk 'END{print NR+0}' "$TMP/spy" 2>/dev/null; }
acts()     { awk -F'\t' '$4=="act"'  "$TMP/rows" 2>/dev/null | wc -l | tr -d ' '; }
waits()    { awk -F'\t' '$4=="wait"' "$TMP/rows" 2>/dev/null | wc -l | tr -d ' '; }
redfix_n() { awk '{print $2}' "$TMP/rO/state/redfix-4242" 2>/dev/null; }

echo
echo "  -- (1) refusal at the current head -> exactly one fixer lane --"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "1" ] && ok "(1) a RED-TREE refusal spawns a fixer lane" \
  || bad "(1) spawns=$(spawns) — the refusal produced no work (the measured stall)"
case "$(cat "$TMP/spy")" in
  *'-s fix-4242 '*) ok "(1)/(2) the session is keyed on the PR number: fix-4242" ;;
  *) bad "(1)/(2) unexpected session name: $(cat "$TMP/spy")" ;;
esac
case "$(cat "$TMP/spy")" in
  *fix-one.sh*--argv*) ok "(1) it runs the existing fixer (fix-one.sh), so the worktree/claim/gate path is not duplicated" ;;
  *) bad "(1) the spawn does not reach fix-one.sh: $(cat "$TMP/spy")" ;;
esac
[ -f "$TMP/rO/state/argv-4242" ] && [ "$(wc -l < "$TMP/rO/state/argv-4242" | tr -d ' ')" = "4" ] \
  && ok "(1) argv travels in a FILE (no PR-derived value reaches \`sh -c\`)" \
  || bad "(1) state/argv-4242 missing or malformed"
[ "$(redfix_n)" = "1" ] && ok "(3) the attempt counter books 1 for this head" \
  || bad "(3) attempt counter=[$(redfix_n)]"
[ "$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)" = "1" ] \
  && ok "(3) the SAME attempt is booked against fixcount too, so fix-one.sh's gate-refusal refund works" \
  || bad "fixcount=[$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)] — a gate refusal would be unaccounted"
[ "$(acts)" = "1" ] && [ "$(waits)" = "0" ] \
  && ok "(7) exactly ONE disposition row, and it is an ACT (no double act on one PR)" \
  || bad "(7) acts=$(acts) waits=$(waits)"
L1="$(cat "$TMP/d.log")"
case "$L1" in
  *'#4242 RED TREE -> fix-4242 spawned'*) ok "(7) the log names the PR, the session, and the attempt" ;;
  *) bad "(7) spawn line missing/unnamed: $L1" ;;
esac
case "$L1" in
  *'REFUSAL: admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.'*) ok "(7) the refusal line is VERBATIM in the log" ;;
  *) bad "(7) the refusal was not logged verbatim" ;;
esac
case "$L1" in
  *'attempt 1/2'*) ok "(7) the attempt counter is in the log line" ;;
  *) bad "(7) the attempt counter is not in the log line" ;;
esac
grep -q FALLTHROUGH "$TMP/d.log" && bad "(1) the router did not \`continue\` — the ordinary arms would also act on this PR" \
  || ok "(1) the router owns the PR for the cycle (no fall-through, so no second spawn from the arm chain)"

echo
echo "  -- (2) idempotence: a second refusal does NOT spawn a second fixer --"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 "" 1
[ "$(spawns)" = "0" ] && ok "(2) a live fix-4242 suppresses the spawn (a second refusal spawns nothing)" \
  || bad "(2) spawns=$(spawns) with a live fixer — two lanes would push to one branch"
[ "$(waits)" = "1" ] && ok "(2) the second refusal is recorded as a WAIT that names the owner" \
  || bad "(2) the suppressed spawn is not in the ledger"
{ [ "$(redfix_n)" = "0" ] || [ ! -f "$TMP/rO/state/redfix-4242" ]; } \
  && ok "(2) the suppressed spawn consumes NO attempt" \
  || bad "(2) the suppressed spawn consumed an attempt ([$(redfix_n)])"
# Two whole cycles back to back: the first spawns, the second (same state, session now live) must not.
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
_first="$(spawns)"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 "" 1
_second="$(spawns)"
[ "$_first" = "1" ] && [ "$_second" = "0" ] \
  && ok "(2) cycle 1 spawns 1, cycle 2 spawns 0 — idempotent across cycles, not just within one" \
  || bad "(2) across cycles: first=$_first second=$_second"

echo
echo "  -- (3) the caps fire, and nothing loops --"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(spawns)" = "0" ] && ok "(3) at 2 attempts for THIS head, no third fixer is spawned" \
  || bad "(3) spawns=$(spawns) — the per-head cap did not bind"
grep -q 'PARKED' "$TMP/d.log" && [ -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3) the cap PARKS the PR (recorded, not silently dropped)" \
  || bad "(3) the cap did not park the PR — the role would re-check it forever"
case "$(cat "$TMP/rO/state/parkreason-4242" 2>/dev/null)" in
  *'THE TREE THIS PR PRODUCES IS RED'*) ok "(3) the park reason carries the VERBATIM refusal for the human" ;;
  *) bad "(3) parkreason=[$(cat "$TMP/rO/state/parkreason-4242" 2>/dev/null)] — no refusal recorded for the operator" ;;
esac
grep -q 'FALLTHROUGH' "$TMP/d.log" && bad "(3) a capped PR fell through to the ordinary arms (they would re-spawn)" \
  || ok "(3) a capped head stops here (no fall-through, so no loop back into the arms)"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 4 1 0 ""
[ "$(spawns)" = "0" ] && ok "(3) the BOX cap (4 live fixers) refuses a fifth" \
  || bad "(3) spawns=$(spawns) with the box already saturated"
[ -f "$TMP/rO/state/redfix-4242" ] && bad "(3) the box-cap refusal consumed an attempt" \
  || ok "(3) the box-cap refusal consumes NO attempt (it retries when a slot frees)"
grep -q 'NO red-fixer slot' "$TMP/d.log" \
  && ok "(3) the capacity refusal is PRINTED with its ceiling and the load gate (#2126 T5)" \
  || bad "(3) the capacity refusal printed no reason"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 0 0 ""
[ "$(spawns)" = "1" ] && ! grep -qE '^deadbeefdeadbeefdeadbeefdeadbeefdeadbeef [1-9]' "$TMP/rO/state/redfix-4242" 2>/dev/null \
  && [ "$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)" = "0" ] \
  && ok "(3) a FAILED spawn rolls BOTH counters back (red-fixer AND fixcount: nothing ran)" \
  || bad "(3) a failed spawn consumed an attempt: redfix=[$(cat "$TMP/rO/state/redfix-4242" 2>/dev/null)] fixcount=[$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)]"
# ...and the rollback RESTORES the previous value rather than zeroing it (two gate refusals must not
# silently clear a budget other arms already spent).
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"; printf '2\n' > "$TMP/rO/state/fixcount-4242"
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 0 0 ""
[ "$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)" = "2" ] \
  && ok "(3) ...restoring the PREVIOUS fixcount (2), not zeroing it" \
  || bad "(3) rollback lost a budget other arms spent: fixcount=[$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)]"
# A cross-box bail is not an attempt.
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1
[ "$(redfix_n)" = "1" ] && grep -q 'attempt refunded to 0' "$TMP/d.log" \
  && ok "(3) a cross-box BAIL refunds the red-fix attempt (1 -> 0, then this spawn books 1)" \
  || bad "(3) bail not refunded: n=[$(redfix_n)]"
[ "$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)" = "1" ] \
  && ok "(3) ...and the BOOKED fixcount is refunded with it (1, not 2 — a bail did no work)" \
  || bad "(3) fixcount=[$(cat "$TMP/rO/state/fixcount-4242" 2>/dev/null)] after a bail — the refund path is not wired"

echo
echo "  -- (4b-pred) the clearance predicate fails CLOSED (a miss is never a green) --"
reds_of() { ( OR=o/r; JSON="$1"; . "$TMP/headreds.sh"; gh() { printf '%s\n' "$JSON"; }; head_reds 1 ); }
[ "$(reds_of '[{"name":"lint","state":"FAILURE"}]')" = "RED" ] \
  && ok "a completed red is RED" || bad "a completed red is not RED"
[ "$(reds_of '[{"name":"lint","state":"SUCCESS"}]')" = "GREEN" ] \
  && ok "an all-non-red surface is GREEN (the only value that may clear a refusal)" || bad "green surface misread"
[ "$(reds_of '[{"name":"lint","state":"PENDING"}]')" = "UNKNOWN" ] \
  && ok "an in-flight check is UNKNOWN, never GREEN (a refusal is not cleared by a pending run)" || bad "pending misread as green/red"
[ "$(reds_of '[{"name":"lint","state":"SOMETHING_NEW"}]')" = "RED" ] \
  && ok "an UNRECOGNISED state is RED (allow-list polarity: it can never clear a refusal)" || bad "an unrecognised state fell through as non-red"
[ "$(reds_of '[]')" = "UNKNOWN" ] \
  && ok "an EMPTY surface is UNKNOWN (absence is not green)" || bad "an empty surface read as GREEN"
[ "$(reds_of 'not json')" = "UNKNOWN" ] \
  && ok "an unreadable surface is UNKNOWN" || bad "an unreadable surface was not UNKNOWN"

echo
echo "  -- (4b) a head can go GREEN without a push (a re-run): re-rail, never park it --"
SURF=GREEN GH_STATE=SUCCESS drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(spawns)" = "0" ] && ok "(4b) a refusal whose head is now non-red (same sha, a re-run) spawns NO fixer" \
  || bad "(4b) spawns=$(spawns) — a lane spent on a tree that is already green"
[ ! -f "$TMP/rO/state/railrefusal-4242" ] && ok "(4b) ...the stale refusal is DROPPED" \
  || bad "(4b) the refusal survived a green head"
grep -q 'FALLTHROUGH' "$TMP/d.log" && ok "(4b) ...and the head is handed back to the sweep, i.e. RE-RAILED (not parked)" \
  || bad "(4b) a green head was not re-railed — the GREEN arm is suppressed and the PR stalls"
[ ! -f "$TMP/rO/state/parked-4242" ] && ok "(4b) a mergeable PR is never parked by this role" \
  || bad "(4b) a mergeable PR was parked"
# ⛔ THE CAP'S OWN PARK, PRE-SEEDED (review P1, cycle 4). The parked guard is the NEXT statement in the
# sweep and lives OUTSIDE this extracted fragment, so a clearance that leaves `parked-<PR>` behind
# would strand the PR while the log said "re-railing". Without a pre-seeded park this case was vacuous.
printf 'head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\nclass=red-tree\nreason=admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n' \
  > "$TMP/rO/state/railrefusal-4242"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$TMP/rO/state/parked-4242"
printf 'rail refused a RED TREE and 2 red-fixer attempt(s) at this head did not clear it\n' > "$TMP/rO/state/parkreason-4242"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 3\n' > "$TMP/rO/state/railcount-4242"
SURF=GREEN GH_STATE=SUCCESS KEEP=1 drive_route none deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ ! -f "$TMP/rO/state/parked-4242" ] \
  && ok "(4b) a green surface LIFTS the park its own cap wrote (else the next guard strands the PR)" \
  || bad "(4b) the park survived a green surface — the PR is never re-railed"
[ ! -f "$TMP/rO/state/railcount-4242" ] \
  && ok "(4b) ...and the head's rail retry budget is reset, so the re-rail gets a real attempt" \
  || bad "(4b) railcount survived at the cap — the re-railed head would park on its first refusal"
# ⛔ ...BUT ONLY THE PARK THIS ROLE (OR THE RAIL) WROTE (review P3, cycle 5). A park records a
# JUDGEMENT; a green check surface does not settle one made by another arm or by a human.
printf 'head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\nclass=red-tree\nreason=admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n' \
  > "$TMP/rO/state/railrefusal-4242"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$TMP/rO/state/parked-4242"
printf 'still CONFLICTING after 3 fixes\n' > "$TMP/rO/state/parkreason-4242"
SURF=GREEN GH_STATE=SUCCESS KEEP=1 drive_route none deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ -f "$TMP/rO/state/parked-4242" ] && grep -q 'NOT lifted' "$TMP/d.log" \
  && ok "(4b) a park written by ANOTHER arm (or a human) is NOT lifted by a green surface" \
  || bad "(4b) the role lifted a park it did not write — a human's decision was overridden"
SURF=UNKNOWN GH_STATE=PENDING drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(spawns)" = "0" ] && [ "$(redfix_n)" = "1" ] \
  && ok "(4b) an UNMEASURABLE surface (in flight / unreadable) spawns nothing and spends no attempt" \
  || bad "(4b) an unmeasurable surface spawned or consumed an attempt (n=$(redfix_n))"
[ -f "$TMP/rO/state/railrefusal-4242" ] && ! grep -q FALLTHROUGH "$TMP/d.log" \
  && ok "(4b) ...the refusal is KEPT and the PR is not re-railed on an unmeasured surface" \
  || bad "(4b) an unmeasured surface cleared the refusal and fell through to a re-rail"
# ...and an EMPTY reading (python3 missing / head_reds printing nothing) is NOT a measurement either.
SURF=EMPTY GH_STATE=SUCCESS HEAD_REDS_EMPTY=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] \
  && ok "(4b) a head_reds that prints NOTHING spawns nothing (an empty read is not a red tree)" \
  || bad "(4b) an empty surface reading spawned a lane — polarity keyed on '= UNKNOWN' instead of '!= RED'"

echo
echo "  -- (3b) a counter that cannot be read or written STOPS the role (it must not disable its own cap) --"
# ⛔ `chmod` DOES NOT BIND FOR uid 0, so on a root container lane these two cases would invert and
# redden CI on CORRECT code. Two other suites in this repo carry the same guard (see
# cloud-cell-bringup.test.sh, cloud-cell-supervisor.test.sh).
if [ "$(id -u)" = "0" ]; then
  echo "  ⏭  skipped: the unreadable-counter case (uid 0 ignores chmod — cannot be staged here)"
else
COUNTER_MODE=unreadable drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(3b) an UNREADABLE attempt counter spawns nothing (resetting it to 0 would be a cap silently disabled)" \
  || bad "(3b) spawns=$(spawns) with an unreadable counter — the per-head cap can never bind"
[ -f "$TMP/rO/state/parked-4242" ] && ok "(3b) ...and the PR is PARKED with the cause, so a human can repair the counter" \
  || bad "(3b) an unreadable counter neither spawned nor parked — the PR is stuck silently"
grep -q 'unreadable or not a count' "$TMP/d.log" \
  && ok "(3b) the log names the cause (not just 'parked')" \
  || bad "(3b) the park reason does not name the counter fault"
fi
# The counter belongs to a HEAD. `fix-one.sh` pushes and immediately re-runs `merge-one.sh`, whose
# rail writes the NEW head's refusal before the sweep sees the record — so a counter left at the cap
# for the previous head must NOT park the fresh head with zero attempts spent.
drive_route red-tree cafe1234cafe1234cafe1234cafe1234cafe1234 cafe1234cafe1234cafe1234cafe1234cafe1234 0 1 2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(spawns)" = "1" ] && ok "(4c) a counter recorded for an OLDER head does not park the new one (the budget resets with the head)" \
  || bad "(4c) spawns=$(spawns) — a stale counter reached the cap and parked a head with 0 attempts"
# ⛔ AN UNREADABLE HEAD IS NOT "A NEW HEAD" (review P3, cycle 6). `HEAD_N=""` (a failed `gh pr view`)
# makes `RF_HEAD != $HEAD_N` true, so a guard without `-n` would take the STALE arm for a VALID refusal:
# clear the record, delete the budget and re-rail on a `gh` blip. The record and counter must survive.
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"; printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1\n' > "$TMP/rO/state/redfix-4242"
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "" 0 1 0 ""
[ -f "$TMP/rO/state/railrefusal-4242" ] && [ -f "$TMP/rO/state/redfix-4242" ] && [ "$(spawns)" = "0" ] \
  && ok "(4c) a FAILED head read does not destroy a valid refusal (it waits, keeping record and budget)" \
  || bad "(4c) an empty head read wiped the refusal/budget and re-railed — one gh blip loses the evidence"
CLAIM_HELD=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(2) a cross-box CLAIM held on this head suppresses the spawn (no second box's lane)" \
  || bad "(2) spawns=$(spawns) while the head is claimed cross-box"
MERGE_LIVE=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(2) a live merge-<PR> (rail/review worker) suppresses the red-fixer — ONE worker per PR across roles" \
  || bad "(2) spawns=$(spawns) while merge-4242 was live — two workers on one branch"
COUNTER_MODE=torn drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && [ ! -e "$TMP/rO/state/redfix-4242" ] \
  && ok "(3b) a TORN (0-byte) counter is reset and NOT spawned on: the failure direction that cannot double-spawn" \
  || bad "(3b) torn counter: spawns=$(spawns), file still present=$([ -e "$TMP/rO/state/redfix-4242" ] && echo yes || echo no)"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "1" ] && ok "(3b) ...and the NEXT cycle (counter gone) spawns normally — the reset self-heals" \
  || bad "(3b) after a torn reset the role never recovered"
COUNTER_MODE=unwritable drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
# Booked BEFORE the session exists (cycle-4 fix): a counter that cannot be written now refuses the
# spawn outright, instead of starting a lane whose attempt can never be recorded.
[ "$(spawns)" = "0" ] && [ -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3b) an unwritable counter REFUSES the spawn and parks (the cap cannot be kept, so no lane starts)" \
  || bad "(3b) unwritable counter: spawns=$(spawns) parked=$([ -f "$TMP/rO/state/parked-4242" ] && echo yes || echo no)"
grep -q 'counters could not be written' "$TMP/d.log" \
  && ok "(3b) the unwritable counter is SAID, with its paths" \
  || bad "(3b) the unwritable counter was silent"
# the cap's log line is novel-only: a second cycle at the cap must not repeat it
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
_cap1="$(grep -c 'PARKED' "$TMP/d.log")"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(grep -c 'PARKED' "$TMP/d.log")" = "$_cap1" ] \
  && ok "(3b) a head already parked at the cap does not re-log the park every cycle" \
  || bad "(3b) the cap's park line repeats every cycle (a repeated line is how a real change is missed)"

echo
echo "  -- (4d) a stored head must be compared as a WHOLE sha (a prefix is a different head) --"
# A 12-char prefix of the current head is NOT this head. This pins that neither writer truncates the
# head and neither reader compares a prefix: such a mutation makes EVERY refusal read as stale at a
# real 40-char head — the role then never spawns a fixer at all, while the log reports a clean re-rail.
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf 'head=%s\nclass=red-tree\nreason=admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n' \
  "$(printf '%s' "$H1" | cut -c1-12)" > "$TMP/rO/state/railrefusal-4242"
printf '%s 1\n' "$(printf '%s' "$H1" | cut -c1-12)" > "$TMP/rO/state/redfix-4242"
KEEP=1 drive_route none - "$H1" 0 1 0 ""
[ "$(spawns)" = "0" ] && grep -q FALLTHROUGH "$TMP/d.log" \
  && ok "(4d) a 12-char prefix of the head is treated as a DIFFERENT (stale) head" \
  || bad "(4d) a prefix was treated as the current head — the stale arm is prefix-sensitive"
# ...and the whole sha is NOT stale: the normal case must still spawn.
printf 'head=%s\nclass=red-tree\nreason=admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n' \
  "$H1" > "$TMP/rO/state/railrefusal-4242"
KEEP=1 drive_route none - "$H1" 0 1 0 ""
[ "$(spawns)" = "1" ] \
  && ok "(4d) the WHOLE 40-char sha matches, so the refusal is live and a fixer is spawned" \
  || bad "(4d) a full-sha record was not recognised as the current head — every refusal would read as stale"

echo
echo "  -- (3f) the caps are read from their TUNABLES, not from literals --"
# MAX_RED_FIX_TRIES=3: two attempts must NOT reach the cap (a literal 2 would park here).
MAX_RED_FIX_TRIES_OVERRIDE=3 drive_route red-tree "$H1" "$H1" 0 1 2 "$H1"
[ "$(spawns)" = "1" ] && [ ! -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3f) MAX_RED_FIX_TRIES=3 allows the third attempt (the cap is not the literal 2)" \
  || bad "(3f) an operator-pinned MAX_RED_FIX_TRIES=3 was ignored (spawns=$(spawns))"
# MAX_RED_FIX=2 with three live fixer lanes: the box cap must bind.
MAX_RED_FIX_OVERRIDE=2 drive_route red-tree "$H1" "$H1" 3 1 0 ""
[ "$(spawns)" = "0" ] \
  && ok "(3f) MAX_RED_FIX=2 binds with three live lanes (the box cap is not the literal 4)" \
  || bad "(3f) an operator-pinned MAX_RED_FIX=2 was ignored (spawns=$(spawns))"

echo
echo "  -- (3c) the caps bind on a REAL sequence of cycles (not just a pre-seeded counter) --"
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"      # (3b) left state behind; this section starts clean
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
_c1_n="$(redfix_n)"; _c1_h="$(awk '{print $1}' "$TMP/rO/state/redfix-4242" 2>/dev/null)"
KEEP=1 drive_route none deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
_c2_n="$(redfix_n)"; _c2_h="$(awk '{print $1}' "$TMP/rO/state/redfix-4242" 2>/dev/null)"
[ "$(spawns)" = "1" ] && ok "(3c) cycle 2 (no live fixer) spawns the SECOND lane" \
  || bad "(3c) cycle 2 spawns=$(spawns) — the budget did not advance"
KEEP=1 drive_route none deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(3c) cycle 3 spawns NOTHING (the per-head cap is reached by real cycles)" \
  || bad "(3c) cycle 3 spawns=$(spawns) — the cap never binds in a real sequence"
[ "$_c1_n" = "1" ] && [ "$_c2_n" = "2" ] && [ "$_c2_h" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && ok "(3c) the counter really advances 1 -> 2 and stays bound to the head (not a constant 1)" \
  || bad "(3c) counter sequence broken: c1=$_c1_n c2=$_c2_n head=$_c2_h"
[ -f "$TMP/rO/state/parked-4242" ] && ok "(3c) cycle 3 parks the head" || bad "(3c) cycle 3 did not park"

echo
echo "  -- (3c2) the refund PRODUCER (fix-one.sh) writes the marker the controller consumes --"
rm -rf "$TMP/gO"; mkdir -p "$TMP/gO/state"
printf '2\n' > "$TMP/gO/state/fixcount-4242"
: > "$TMP/gO/log"
(
  PR=4242; HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; O="$TMP/gO"; L="$TMP/gO/log"; CTRL=1
  . "$TMP/isnum.sh"; . "$TMP/gaterefund.sh"
) >/dev/null 2>&1
[ -f "$TMP/gO/state/fixgate-4242-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && ok "(3c2) a gate refusal writes fixgate-<PR>-<HEAD> (the marker the controller refunds on)" \
  || bad "(3c2) fix-one.sh no longer writes the fixgate marker — the per-head refund has no producer"
[ "$(cat "$TMP/gO/state/fixcount-4242" 2>/dev/null)" = "1" ] \
  && ok "(3c2) ...and refunds fixcount in the same block (2 -> 1)" \
  || bad "(3c2) fixcount=[$(cat "$TMP/gO/state/fixcount-4242" 2>/dev/null)] — the refund block is not wired"
rm -rf "$TMP/gO2"; mkdir -p "$TMP/gO2/state"; printf '2\n' > "$TMP/gO2/state/fixcount-4242"
( PR=4242; HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; O="$TMP/gO2"; L="$TMP/gO2/log"; CTRL=0
  . "$TMP/isnum.sh"; . "$TMP/gaterefund.sh" ) >/dev/null 2>&1
[ ! -f "$TMP/gO2/state/fixgate-4242-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] && [ "$(cat "$TMP/gO2/state/fixcount-4242")" = "2" ] \
  && ok "(3c2) a MANUAL run (CTRL=0) refunds nothing (it never booked an attempt)" \
  || bad "(3c2) a manual run refunded an attempt it never booked"

echo
echo "  -- (3c3) MAX_RED_FIX_TRIES=0 is REPORT-ONLY (it must not park at zero attempts) --"
MAX_RED_FIX_TRIES_OVERRIDE=0 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && [ ! -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3c3) a 0 cap spawns nothing AND parks nothing (it is a report-only switch)" \
  || bad "(3c3) a 0 cap parked a PR at zero attempts (a false reason on a PR nothing was tried on)"
grep -q 'REPORT-ONLY' "$TMP/d.log" && ok "(3c3) ...and says so" || bad "(3c3) the report-only state is silent"
grep -q 'FALLTHROUGH' "$TMP/d.log" \
  && ok "(3c3) ...and FALLS THROUGH, so the ordinary arms still own the PR (report-only is not a stall)" \
  || bad "(3c3) report-only suppressed the ordinary arms — the PR gets no merge, no re-rail and no row"
[ "$(acts)" = "0" ] && [ "$(waits)" = "0" ] \
  && ok "(3c3) ...without writing a ledger row of its own (the arms write the PR's ONE row)" \
  || bad "(3c3) acts=$(acts) waits=$(waits) — report-only wrote a second disposition for the PR"

echo
echo "  -- (3d) the TOTAL fixer budget binds ACROSS heads (a push must not buy an endless budget) --"
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf '3\n' > "$TMP/rO/state/fixcount-4242"
KEEP=1 SEED_REC=1 drive_route red-tree cafe1234cafe1234cafe1234cafe1234cafe1234 cafe1234cafe1234cafe1234cafe1234cafe1234 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(3d) at MAX_FIX_TRIES spent, a RED TREE at a FRESH head spawns nothing" \
  || bad "(3d) spawns=$(spawns) — a new head bought an unbounded budget (push/re-refuse forever)"
[ -f "$TMP/rO/state/parked-4242" ] && grep -q 'MAX_FIX_TRIES' "$TMP/rO/state/parkreason-4242" \
  && ok "(3d) ...and parks with a reason naming MAX_FIX_TRIES" \
  || bad "(3d) the total bound neither spawned nor parked (or the reason lost the cause)"
rm -f "$TMP/rO/state/fixcount-4242" "$TMP/rO/state/parked-4242" "$TMP/rO/state/parkreason-4242"

echo
echo "  -- (3d2) the TOTAL counter fails closed on corruption, and the authority guard is honoured --"
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf '99999999999999999999\n' > "$TMP/rO/state/fixcount-4242"   # > 2**63: `[ -ge ]` would ERROR
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && [ -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3d2) a corrupt TOTAL counter parks instead of silently losing the across-heads bound" \
  || bad "(3d2) a 20-digit fixcount neither bound nor parked (spawns=$(spawns)) — the cap is unenforceable"
grep -q 'total fixer counter' "$TMP/d.log" && ok "(3d2) ...and the cause is named" || bad "(3d2) the cause is unstated"
# The sweep promises "AUTHORITY_UNKNOWN -> nothing spawned"; this role runs BEFORE that guard.
AUTHORITY_UNKNOWN=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && grep -q FALLTHROUGH "$TMP/d.log" \
  && ok "(3d2) an UNREADABLE merge contract spawns nothing and falls through (the sweep's own promise)" \
  || bad "(3d2) the role spawned a paid lane while the merge contract was UNREADABLE"

echo
echo "  -- (3e) a SPAWN-GATE refusal is not an attempt (a disk refusal never clears by waiting) --"
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2\n' > "$TMP/rO/state/redfix-4242"     # AT the cap: only a refund can let a spawn through
: > "$TMP/rO/state/fixgate-4242-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "1" ] && [ ! -f "$TMP/rO/state/parked-4242" ] \
  && ok "(3e) a fixgate marker refunds the per-head attempt: at the cap, the refunded budget spawns and does NOT park" \
  || bad "(3e) a spawn-gate refusal consumed the per-head budget: spawns=$(spawns) n=[$(redfix_n)]"
grep -q 'per-head attempt refunded to 1' "$TMP/d.log" \
  && ok "(3e) ...the refund is logged with the value it restored" \
  || bad "(3e) the refund path is not wired (no 'refunded to 1' line)"
[ -f "$TMP/rO/state/fixgate-4242-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && bad "(3e) the fixgate marker was not consumed (it would refund the same refusal forever)" \
  || ok "(3e) ...and the marker is consumed once"
# ...and a marker for a SUPERSEDED head must NOT credit the new head's budget.
rm -rf "$TMP/rO"; mkdir -p "$TMP/rO/state"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1\n' > "$TMP/rO/state/redfix-4242"
: > "$TMP/rO/state/fixgate-4242-cafe1234cafe1234cafe1234cafe1234cafe1234"
KEEP=1 SEED_REC=1 drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
grep -q 'refunded to 0' "$TMP/d.log" \
  && bad "(3e) a marker from ANOTHER head refunded this head's attempt (fail-open on the per-head cap)" \
  || ok "(3e) a fixgate marker for a superseded head does not refund this head's budget"

echo
echo "  -- (4) a NEW HEAD invalidates the old refusal: re-rail, do not re-spawn --"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef cafe1234cafe1234cafe1234cafe1234cafe1234 0 1 1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(spawns)" = "0" ] && ok "(4) a refusal recorded for an OLD head spawns nothing at the new head" \
  || bad "(4) spawns=$(spawns) — a stale refusal spawned a fixer (a repair could hit the wrong tree)"
[ ! -f "$TMP/rO/state/railrefusal-4242" ] && ok "(4) the stale record is DROPPED (it cannot outlive its head)" \
  || bad "(4) the stale refusal record survived — the 'old refusal still stands' bug"
grep -q 'is STALE' "$TMP/d.log" && ok "(4) the log says why the old verdict was dropped" \
  || bad "(4) the stale drop was silent"
grep -q 'FALLTHROUGH' "$TMP/d.log" \
  && ok "(4) it FALLS THROUGH to the ordinary arms — i.e. the new head is RE-RAILED" \
  || bad "(4) the new head was not handed back to the sweep: it would never be re-railed"
[ ! -f "$TMP/rO/state/redfix-4242" ] && ok "(4) the attempt budget resets with the head" \
  || bad "(4) attempts carried across a head change"

echo
echo "  -- (5) a red tree is fixed or reported, NEVER overridden --"
. "$MOD"
if grep -qE '^[[:space:]]*[^#[:space:]].*AGENT_ADMIN_MERGE_OVERRIDE=' "$TMP/redfix.sh" "$TMP/recorder.sh" "$MOD"; then
  bad "(5) the role ASSIGNS AGENT_ADMIN_MERGE_OVERRIDE — a red tree must never be overridden"
else
  ok "(5) nothing in the role assigns AGENT_ADMIN_MERGE_OVERRIDE (the rail is never bypassed)"
fi
drive_route override deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && ok "(5) an \`override\`-class refusal spawns no fixer (a human decided)" \
  || bad "(5) the audited override path spawned a 'repair'"
drive_route none - deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
[ "$(spawns)" = "0" ] && grep -q FALLTHROUGH "$TMP/d.log" \
  && ok "(5) no refusal record -> the router is inert and the cycle is unchanged" \
  || bad "(5) the router acted without a refusal"

echo
echo "  -- (5b) a record that was not written must not be reported as written --"
# ⛔ PERMISSION-INDEPENDENT: `state` is a REGULAR FILE, so `mkdir -p`/the write fail for ANY uid
# (a `chmod 500` case inverts under uid 0, which ignores permissions — reddening CI on correct code).
_rr_o="$TMP/rrO"; rm -rf "$_rr_o"; mkdir -p "$_rr_o"; : > "$_rr_o/state"
printf 'admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED.\n' > "$TMP/rr-txt.txt"
_rr_out="$( . "$MOD"; rail_refusal_record "$_rr_o" 9 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1 "$TMP/rr-txt.txt" 0 2>/dev/null )"; _rr_rc=$?
{ [ "$_rr_rc" != "0" ] && [ -z "${_rr_out:-}" ]; } \
  && ok "(5b) an unwritable state dir makes the writer return NON-ZERO and print NO class (a caller cannot log a false 'recorded')" \
  || bad "(5b) unwritable state dir: rc=$_rr_rc out='${_rr_out:-}' — the writer claimed a record it did not make"
grep -qE '_rf_txt=/dev/null|: > /dev/null' "$TMP/recorder.sh" \
  && bad "(5b) the recorder still has a /dev/null fallback (an unconditional rm -f can delete the device on a root worker)" \
  || ok "(5b) the recorder has no /dev/null fallback"

echo
echo "  -- (6) the fixer's model/provider is explicit, and not ambient --"
drive_route red-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 0 1 0 ""
case "$(cat "$TMP/spy")" in
  *'unset OPENAI_API_KEY OPENAI_BASE_URL;'*) ok "(6) the spawn UNSETS the image's OPENAI credentials (they shadow provider selection, #2208)" ;;
  *) bad "(6) OPENAI_API_KEY is not unset at the spawn — an ambient credential outranks the pin" ;;
esac
# The ONE gated `pi` invocation. Structural pin, on purpose: launching a real agent to prove a flag
# would make this suite non-hermetic, and the flag is a literal in one place.
if grep -q 'pi -p --provider deepseek --model deepseek-v4-flash' "$HERE/spawn-gate.sh"; then
  ok "(6) the gated invocation NAMES provider+model explicitly (spawn-gate.sh) — nothing is env-derived"
else
  bad "(6) spawn-gate.sh no longer pins --provider/--model explicitly"
fi

echo
echo "  -- the second writer: the cell doctor's merge role (driven, not grepped) --"
# drive_doctor <state-dir-mode:ok|unwritable>
drive_doctor() {
  rm -rf "$TMP/dO"; mkdir -p "$TMP/dO/state" "$TMP/dO/state/roles"
  mk_rail "$TMP/fake-rail.sh" red
  bash "$TMP/fake-rail.sh" > "$TMP/dout.txt" 2>&1
  : > "$TMP/dlist.txt"
  # same trick: a state dir that is a regular FILE fails for any uid
  [ "${1:-ok}" = "unwritable" ] && { rmdir "$TMP/dO/state/roles" 2>/dev/null; rm -rf "$TMP/dO/state"; : > "$TMP/dO/state"; }
  (
    pr=909; head=cafe1234cafe1234cafe1234cafe1234cafe1234; rc=1; why="tree is red"; result=""; out="$TMP/dout.txt"
    O="$TMP/dO"; ROLES_DIR="$TMP/dO/state/roles"
    . "$TMP/isnum.sh"; . "$MOD"
    attempt_record() { printf '%s %s %s %s\n' "$1" "$2" "$(date +%s)" "${3:-}" >> "$TMP/dO/state/roles/merge.attempts"; }
    log() { printf '%s\n' "$*" >> "$TMP/dlog.txt"; }
    . "$TMP/doctor-recorder.sh"
    printf '%s\n' "$result" > "$TMP/dresult.txt"
  ) >/dev/null 2>&1
}
: > "$TMP/dlog.txt"
drive_doctor ok
( . "$MOD"; rail_refusal_field "$TMP/dO" 909 head ) | grep -qx 'cafe1234cafe1234cafe1234cafe1234cafe1234' \
  && ok "the doctor records under the PR's OWN HEAD (an un-head-bound record would never be invalidated by a push)" \
  || bad "the doctor's record is un-head-bound or absent (head=[$( . "$MOD"; rail_refusal_field "$TMP/dO" 909 head )])"
( . "$MOD"; rail_refusal_field "$TMP/dO" 909 class ) | grep -qx 'red-tree' \
  && ok "the doctor's refusal is classed red-tree (same classifier as the controller)" \
  || bad "the doctor recorded class=[$( . "$MOD"; rail_refusal_field "$TMP/dO" 909 class )]"
grep -q 'class=red-tree' "$TMP/dlog.txt" \
  && ok "the doctor's log names the recorded class" \
  || bad "the doctor's log does not name the class"
: > "$TMP/dlog.txt"
drive_doctor unwritable
grep -q 'NOT RECORDED' "$TMP/dlog.txt" \
  && ok "an UNWRITABLE state dir makes the doctor say NOT RECORDED (never 'recorded' for a failed write)" \
  || bad "the doctor logged a successful record for a write that failed: $(cat "$TMP/dlog.txt")"
grep -q 'recorded (class=' "$TMP/dlog.txt" \
  && bad "the doctor claims a record it did not make" \
  || ok "the doctor never claims a record it did not make"
DOCTOR="$HERE/cloud-cell-doctor.sh"
_landed_arm="$(sed -n '/landed=\$((landed + 1))/,/log "\[merge\] #\$pr LANDED/p' "$DOCTOR")"
case "$_landed_arm" in *rail_refusal_clear*) rc=0 ;; *) rc=1 ;; esac
[ "$rc" = "0" ] && ok "the doctor's LANDED arm clears the refusal record (a merged head carries no refusal)" \
  || bad "the doctor leaves a refusal record on a LANDED PR"
case "$_landed_arm" in *'redfix-$pr'*) rc=0 ;; *) rc=1 ;; esac
[ "$rc" = "0" ] && ok "the doctor's LANDED arm clears the red-fixer budget too" \
  || bad "the doctor clears only half the pair on a LANDED PR"
case "$_landed_arm" in *'fixgate-$pr-'*) rc=0 ;; *) rc=1 ;; esac
[ "$rc" = "0" ] && ok "the doctor's LANDED arm reclaims the fixgate markers as well (none outlives the PR)" \
  || bad "the doctor leaves fixgate markers behind on a LANDED PR"

echo
echo "  -- wiring: the role's own shard is registered in the ONE shard list --"
grep -q 'red-fixer.test.sh' "$HERE/../../scripts/run-bash-shards.sh" \
  && ok "red-fixer.test.sh is a shard (a suite nobody runs is not a gate)" \
  || bad "red-fixer.test.sh is NOT in scripts/run-bash-shards.sh — it would never run in CI"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" = "0" ]
