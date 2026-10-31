#!/usr/bin/env bash
# brief-gate.test.sh — the research-first dispatch gate, DRIVEN, plus a mutation that proves the
# assertions can fail (agent-infra#2258).
#
# WHY THIS SUITE EXISTS IN THIS SHAPE. The gate's whole claim is "a brief with no research contract
# never reaches an agent". Two ways to ship that claim broken: the validator never refuses, or the
# dispatch path never calls it. So the suite has three halves and NONE of them is a grep of the
# validator's own text:
#
#   §A  the validator's decisions, on real brief files (refuse / admit / fail-closed on the edges)
#   §B  the REFUSAL MUST TEACH — the message names every missing element and prints a pasteable block
#   §C  NON-VACUITY — a mutant whose refusal is removed makes §A's two central asserts FAIL. Without
#       this arm, "refused" could be green on a tree where the gate refuses everything (or on a tree
#       where `ck` itself is broken), and nobody would know which.
#   §D  the WIRING, executed: `run_agent` (which covers lane.sh + fix-one.sh + every future caller),
#       `merge-one.sh`'s own run_agent, `nonblocking-dispatch.sh` (foreground), `orch-send.sh`,
#       `safe-send.sh`, and `pr-doctor.py`'s generated brief — each driven with a stub `pi`/`cmux`, so
#       the assertion is "the agent DID NOT RUN", not "the source contains a word".
#   §E  the census: the files that touch the gate are an EQUALITY, so a dispatch path added tomorrow
#       without one reddens this suite instead of drifting in unvalidated (the shape
#       spawn-gate.test.sh already uses for `pi -p` invokers).
#
# Run: bash scripts/orchestrator-harness/brief-gate.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ THE CAPABILITY GATE IS DISABLED FOR THE ARMS IN THIS FILE, BY NAME AND ON PURPOSE (agent-infra#2935).
# `run_agent` measures the box — one bounded `pi` call — immediately before every launch, and these
# arms drive `run_agent` with a STUB `pi` that never emits the probe's answer token. With the gate live
# here, each arm would spend up to 2 x LANE_PREFLIGHT_BOUND on a stub and then be REFUSED by a gate
# this file is not testing, so an arm about the LOAD or DISK gate would report a capability refusal.
# The capability gate has its own arms (`cell-lane-preflight.test.sh`, and the capability block in
# `spawn-gate.test.sh`, which re-enables it with LANE_PREFLIGHT=1). This is the documented operator
# escape, declared where it applies — not a silent bypass: unsetting it here turns the gate back on and
# these arms go red, which is the assertion that the line is load-bearing rather than decorative.
export LANE_PREFLIGHT=0
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$HERE/brief-gate.sh"
PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap "echo KEEPTMP=$TMP" EXIT
[ -s "$GATE" ] && bash -n "$GATE"; ck $? "the validator exists and parses"
[ -x "$GATE" ]; ck $? "the validator is executable (every caller invokes it as a program)"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# One brief per shape. `canonical` is rendered FROM the shipped helper, so the "complete brief" is the
# gate's own advice rather than a hand-typed copy that could drift from it.
CANON="$TMP/canonical.txt"; bash "$GATE" --section lane > "$CANON"
printf 'Just fix the thing. Do not overthink it.\n' > "$TMP/no-research.txt"
sed '/^CONTRADICTION TEST:/d' "$CANON" > "$TMP/no-contradiction.txt"
sed '/^RUNG:/d'              "$CANON" > "$TMP/no-rung.txt"
sed 's/^RUNG:.*/RUNG: 2/'    "$CANON" > "$TMP/rung-no-tool.txt"
sed 's/^RUNG:.*/RUNG: web_search model="sonar"/' "$CANON" > "$TMP/rung-no-digit.txt"
: > "$TMP/empty.txt"

echo
echo "§A the validator's decisions on real brief files"
bash "$GATE" --check "$TMP/no-research.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(i) a brief with NO research section is REFUSED with 80 (got $rc)"
bash "$GATE" --check "$TMP/no-contradiction.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(ii) research present but NO contradiction test is REFUSED with 80 (got $rc)"
bash "$GATE" --check "$TMP/no-rung.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(ii-b) research + contradiction but NO RUNG/tool line is REFUSED with 80 (got $rc)"
bash "$GATE" --check "$TMP/rung-no-tool.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(ii-c) a RUNG with no tool named is REFUSED (a digit alone is not a decision) (got $rc)"
bash "$GATE" --check "$TMP/rung-no-digit.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(ii-d) a tool with no rung number is REFUSED (the rung is the cost decision) (got $rc)"
bash "$GATE" --check "$CANON" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(iii) a COMPLETE brief PASSES with 0 (got $rc)"
for role in lane fixer reviewer worker; do
  bash "$GATE" --section "$role" > "$TMP/section-$role.txt" 2>/dev/null
  bash "$GATE" --check "$TMP/section-$role.txt" "$role" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "the canonical section for role '$role' satisfies the validator (the gate cannot refuse its own advice) (got $rc)"
done
# Fail-closed edges. Each one is a state a caller really reaches: a caller that forgot the file, a
# pipeline that produced nothing, and a role typo in a wrapper.
bash "$GATE" --check "$TMP/empty.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "an EMPTY brief is refused, not read as 'nothing to check' (got $rc)"
bash "$GATE" --check "$TMP/does-not-exist.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "a MISSING brief file is refused (got $rc)"
bash "$GATE" --check "$CANON" banana >/dev/null 2>&1; rc=$?
[ "$rc" -eq 78 ]; ck $? "an UNKNOWN role is 78 (cannot verify), never a pass (got $rc)"
bash "$GATE" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 78 ]; ck $? "bad usage is 78, not 0 (got $rc)"
bash "$GATE" --check - lane < "$CANON" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "a brief on STDIN is admitted (pane orders are passed inline, not as files) (got $rc)"
# Scope: a label AFTER the section's closing heading is outside the contract. A validator that just
# grepped the whole file for `EXTERNAL:` would admit a brief whose section is an empty stub with the
# real content pasted somewhere else — the shape a hurried author produces.
{ printf '## RESEARCH FIRST\nINTERNAL: only this line is inside the section\n\n## Notes\n'
  printf 'EXTERNAL: pasted below the section\nRUNG: 2 — web_search model="sonar"\nCONTRADICTION TEST: none\n'; } > "$TMP/scoped.txt"
bash "$GATE" --missing "$TMP/scoped.txt" 2>/dev/null | grep -qx 'EXTERNAL'; ck $? "a label OUTSIDE the research section does not count (scoping is enforced)"
# Bold / bullet / numbered / subsection spellings must all be accepted: the contract is about the
# content, not about markdown style, and refusing a well-formed brief teaches authors to fight the gate.
{ printf '## RESEARCH FIRST\n### Internal\n- **INTERNAL:** read the tracker first\n### External\n1. EXTERNAL: fetch the RFC\n'
  printf 'RUNG: 3 — web_fetch https://example.com/rfc\nCONTRADICTION TEST: no recorded decision reaches this work\n'; } > "$TMP/styled.txt"
bash "$GATE" --check "$TMP/styled.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "bold/bullet/numbered/subsection spellings are all admitted (got $rc)"

echo
echo "§B the refusal TEACHES — it names what is missing and prints a pasteable block"
OUT="$(bash "$GATE" --check "$TMP/no-research.txt" lane 2>&1)"
grep -q 'RESEARCH FIRST' <<<"$OUT"; ck $? "the refusal names the missing RESEARCH FIRST section"
grep -q 'CONTRADICTION TEST' <<<"$OUT"; ck $? "…and the missing CONTRADICTION TEST line"
grep -q 'INTERNAL:' <<<"$OUT"; ck $? "…and the INTERNAL field it wants"
grep -q 'RUNG:' <<<"$OUT"; ck $? "…and the RUNG field it wants"
grep -qF 'brief-gate.sh --section lane' <<<"$OUT"; ck $? "…and names the command that prints the canonical block (the remedy, not just the fault)"
grep -q '^\[brief-gate\]   ## RESEARCH FIRST' <<<"$OUT"; ck $? "…and PRINTS the canonical block, indented, ready to paste"
grep -q '2258' <<<"$OUT"; ck $? "…and cites the record (agent-infra#2258) so the author can read why"
grep -qi 'NOTHING WAS STARTED' <<<"$OUT"; ck $? "…and states that nothing was consumed (the author is not debugging a phantom dispatch)"
# The refusal for ONE missing element must not claim the others are missing too: a message that
# always lists everything is a message nobody reads past.
OUT1="$(bash "$GATE" --check "$TMP/no-contradiction.txt" lane 2>&1)"
{ grep -q 'CONTRADICTION TEST' <<<"$OUT1" && ! grep -q '`INTERNAL:`' <<<"$OUT1"; }; ck $? "a brief missing ONLY the contradiction test is told only that (the message is not a fixed blob)"

echo
echo "§C NON-VACUITY — the mutation makes §A's two central asserts FAIL"
# ⛔ MUTATE THE VALIDATOR, NOT THE TEST. The mutant is derived FROM THE SHIPPED FILE (so it tracks it)
# by deleting the refusal: `brief_gate_missing` is redefined to print nothing, which is exactly the
# "always pass" defect. If §A would stay green under that mutation, §A is testing nothing.
MUT="$TMP/mutant.sh"
# The mutation is on the DECISION line, not the function header: replacing the header alone leaves the
# body behind and yields a syntax error, i.e. a mutant that fails for the wrong reason.
sed 's/^  \[ -n "\$miss" \] || return 0$/  return 0  # MUTANT: always pass/' "$GATE" > "$MUT"
# The transformation is ASSERTED, not assumed: if the anchor stops matching, sed yields an UNCHANGED
# file and the arms below would "pass" for the wrong reason.
diff -q "$GATE" "$MUT" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "the mutation REALLY changed the file (the sed anchor still matches)"
bash -n "$MUT"; ck $? "the mutant still parses — it is a program, not a syntax error that fails for the wrong reason"
bash "$MUT" --section lane >/dev/null 2>&1; ck $? "the mutant is ALIVE (it still renders the section) — the mutation removed the refusal only"
bash "$MUT" --check "$TMP/no-research.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "MUTATION: (i) 'no research section is refused' now FAILS — the mutant admits it (rc=$rc, §A would report rc=$rc as ❌)"
bash "$MUT" --check "$TMP/no-contradiction.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "MUTATION: (ii) 'no contradiction test is refused' now FAILS — the mutant admits it (rc=$rc, §A would report rc=$rc as ❌)"
# …and the OTHER direction: a validator that refuses everything is equally useless, so pin that a
# complete brief is ADMITTED by the shipped gate (already §A.iii) and that the mutation is not the
# only way to be wrong.
sed 's/^  \[ -n "\$miss" \] || return 0$/  miss="${miss:-RESEARCH-SECTION}"  # MUTANT: always refuse/' "$GATE" > "$TMP/mutant-refuse.sh"
bash "$TMP/mutant-refuse.sh" --check "$CANON" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "MUTATION (other direction): 'a complete brief passes' FAILS when the gate refuses everything (rc=$rc)"

echo
echo "§D the WIRING — driven, with a stub pi/cmux: the assertion is that NO AGENT RAN"
# ── the stub `pi` records every invocation, so "refused" is proven by ABSENCE, and the admitted
#    control proves the machinery under it actually works (a negative assert alone passes on a tree
#    where nothing exists — the #1884 review's finding, applied here).
mkdir -p "$TMP/bin" "$TMP/o/state" "$TMP/fakehome"
printf '#!/bin/sh\necho "PI_RAN" >> "$PI_LOG"\nexit 0\n' > "$TMP/bin/pi"; chmod +x "$TMP/bin/pi"
export PI_LOG="$TMP/pi.log"
# ⛔ THE CREATION BACK-PRESSURE GATE NEEDS A READING AND A REPO — NOT AN OFF SWITCH (#2409). `run_agent`
# measures the repo's landing ratio through `gh` immediately before any spawn, and this suite drives the
# SHIPPED helper from whatever checkout the runner started in: on a repo over its ceiling every positive
# control below is refused by the LAND-BACKLOG gate instead of running (MEASURED on this box: 66 open /
# 2.3 landings, so `good-brief: rc=74 started=0` and `!! positive control did NOT run pi`). Supplying the
# reading is the fix `spawn-gate.test.sh` established (#2333 review: an env var that opens a gate is not
# a gate), and the repo is supplied for the same reason — a driver run from a directory with no GitHub
# origin makes `land_backlog_repo` unreadable and refuses there too.
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
FIXREPO="$TMP/repofix"; mkdir -p "$FIXREPO"
git init -q "$FIXREPO" && git -C "$FIXREPO" remote add origin https://github.com/owner/repo.git
# drive_run_agent <brief> — the SHIPPED run_agent, with the load probe pinned and a stub pi.
drive_run_agent() { # drive_run_agent <brief-file>
  : > "$PI_LOG"
  ( cd "$FIXREPO" && PATH="$TMP/bin:$PATH" O="$TMP/o" HOME="$TMP/fakehome" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
    bash -c '. "$1"; load1() { printf "1"; }; run_agent 1 "$2" "$3" "brief-gate test" >/dev/null 2>&1
             printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$HERE/spawn-gate.sh" "$TMP/ra.log" "$1" )
}
res="$(drive_run_agent "$TMP/no-research.txt")"
[ "$res" = "rc=80 started=0" ]; ck $? "run_agent REFUSES an invalid brief: 80, AGENT_STARTED=0 ($res)"
[ -s "$PI_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and the model was NOT invoked (the stub pi wrote nothing)"
grep -q 'brief-gate' "$TMP/ra.log"; ck $? "…and the refusal is in the agent log, where an operator greps for the item"
grep -q 'NOT a capacity refusal' "$TMP/ra.log"; ck $? "…and says it is NOT a capacity refusal (the remedy is the brief, not the box)"
ROWS=0; [ -s "$TMP/o/state/walltime.tsv" ] && ROWS="$(wc -l < "$TMP/o/state/walltime.tsv" | tr -d ' ')"
[ "$ROWS" = "0" ]; ck $? "…and NO walltime row is written (a refused brief must not fabricate a zero-duration sample)"
res="$(drive_run_agent "$CANON")"
[ "$res" = "rc=0 started=1" ]; ck $? "POSITIVE CONTROL: run_agent ADMITS a valid brief and the agent RUNS ($res)"
grep -q 'PI_RAN' "$PI_LOG"; ck $? "…the stub pi really ran (the refusal above is evidence, not a vacuous green)"
# Fail-closed on a MISSING validator: copy the helper alone into a directory with no brief-gate.sh and
# an isolated HOME, so the search cannot reach a real installed copy. 78 = cannot verify, and the log
# must say so — a gate that silently passes when it cannot find its rules is the failure mode this
# whole layer exists to prevent.
# ⛔ AND AN ISOLATED `$HOME` IS NOT ENOUGH — `$AGENT_INFRA_PATH` IS A FIFTH SEARCH ROOT (#1881 LANE,
# measured on a cell). `spawn-gate.sh`/`lane.sh` also resolve the validator under
# `\$AGENT_INFRA_PATH/scripts/orchestrator-harness`, and `AGENTS.md` makes exporting that variable a
# PREREQUISITE of this repo — so on every dev box and every cell these arms found the REAL checkout's
# validator, ran it, and reported `rc=0 started=1`, i.e. they reddened exactly where the variable is
# set and passed on a clean runner. Same class as the suite-side defect this lane fixed in
# `scripts/test_cmux_payload.py`: a fixture that inherits ambient env cannot make a claim about
# isolation. `env -u` is the isolation the arm already claimed.
mkdir -p "$TMP/nolib"
cp "$HERE/spawn-gate.sh" "$TMP/nolib/"
: > "$PI_LOG"
res="$( cd "$FIXREPO" && env -u AGENT_INFRA_PATH PATH="$TMP/bin:$PATH" O="$TMP/o2" HOME="$TMP/fakehome" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
  bash -c '. "$1"; load1() { printf "1"; }; run_agent 1 "$2" "$3" "no validator" >/dev/null 2>&1
           printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$TMP/nolib/spawn-gate.sh" "$TMP/nolib.log" "$CANON" )"
[ "$res" = "rc=78 started=0" ]; ck $? "a MISSING validator is 78/cannot-verify, not a pass ($res)"
[ -s "$PI_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and no agent ran on cannot-verify either"
grep -q 'CANNOT VERIFY' "$TMP/nolib.log"; ck $? "…and the log says the gate could not find its own rules (not 'the brief is bad')"

# ── merge-one.sh's OWN run_agent (the FIRST-REVIEW path for every own-lane PR). Extracted from the
# shipped file exactly as selftest.sh extracts it, so the function under test is the shipped one.
sed -n '/^run_agent() {/,/^}/p' "$HERE/merge-one.sh" > "$TMP/m1-runagent.sh"
[ -s "$TMP/m1-runagent.sh" ]; ck $? "merge-one.sh's run_agent() was extracted from the shipped file"
drive_m1() { # drive_m1 <brief-file>
  : > "$PI_LOG"
  ( cd "$FIXREPO" && PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" brief_gate_sh="$GATE" log="$TMP/m1.log" L="$TMP/m1" O="$TMP/o" \
    bash -c '. "$1"; run_agent 1 "$2" "$3" >/dev/null 2>&1; printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' \
      _ "$TMP/m1-runagent.sh" "$TMP/m1.log" "$1" )
}
res="$(drive_m1 "$TMP/no-contradiction.txt")"
[ "$res" = "rc=80 started=0" ]; ck $? "merge-one.sh's run_agent REFUSES an invalid reviewer brief: 80, started=0 ($res)"
[ -s "$PI_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and the reviewer model was NOT invoked"
res="$(drive_m1 "$CANON")"
[ "$res" = "rc=0 started=1" ]; ck $? "POSITIVE CONTROL: merge-one.sh's run_agent runs the reviewer for a valid brief ($res)"
grep -q 'PI_RAN' "$PI_LOG"; ck $? "…and the stub pi really ran there too"

# ── nonblocking-dispatch.sh: the AUTHORED-brief path (pr-doctor + a human). The refusal must be in
# the FOREGROUND — the worker is backgrounded with `exec >/dev/null 2>&1`, so a refusal raised inside
# it would leave no trace and the caller would report a launch that never happened.
mkdir -p "$TMP/wt" "$TMP/bg-o/state" "$TMP/bg-o/gh-rest"
# ⛔ THE DISPATCHER'S WORKTREE NEEDS A GITHUB ORIGIN TOO (review cycle 2, P1). `nonblocking-dispatch.sh`
# `cd`s into it before `run_agent`, and `land_backlog_repo` derives owner/name from `$PWD`'s origin with
# NO env fallback (`repo-slug.sh`), so a plain `mkdir` directory makes the LAND-BACKLOG gate refuse with
# "UNREADABLE repo" and the worker exits 74 instead of launching (MEASURED: dispatcher rc=0, worker
# rc=74, stub pi never ran, and only the last assertion below noticed).
git init -q "$TMP/wt" && git -C "$TMP/wt" remote add origin https://github.com/owner/repo.git
NB="$HERE/nonblocking-dispatch.sh"
# ⛔ THE STUB `pi` GOES IN `$O/gh-rest`, AND THAT IS THE SCRIPT'S OWN SEAM, NOT A TRICK. The dispatcher
# exports `/opt/homebrew/bin:/usr/local/bin` AT THE FRONT of PATH (for the reason its comment gives:
# `spawn-gate.sh` derives the CPU count at SOURCE time), and then re-asserts `$O/gh-rest` ahead of that
# — so a stub in `$TMP/bin` is outranked by a real `pi` on this box. `$O/gh-rest` is the first
# directory on the resulting PATH, which makes it the only honest place to put one. (The visible
# symptom of getting this wrong: the "positive control" ran the REAL pi and wrote a real session.)
cp "$TMP/bin/pi" "$TMP/bg-o/gh-rest/pi"; chmod +x "$TMP/bg-o/gh-rest/pi"
: > "$PI_LOG"
out="$( cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
       bash "$NB" bgtest "$TMP/wt" "$TMP/no-research.txt" 5 2>&1 )"; rc=$?
[ "$rc" -eq 80 ]; ck $? "nonblocking-dispatch.sh REFUSES an invalid brief in the FOREGROUND with 80 (rc=$rc)"
grep -q 'RESEARCH FIRST' <<<"$out"; ck $? "…and the teaching message reached the CALLER (not a detached log)"
[ ! -f "$TMP/bg-o/bg/bgtest.pid" ]; ck $? "…and NO worker was started (no pid file, so no launch to report)"
[ -s "$PI_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and no agent ran"
# ⛔ ITS OWN COPY OF THE FIXTURE, not `$CANON`. The dispatch below APPENDS the COMMIT-AS-YOU-GO
# section (#2981) to whatever brief it is handed — so handing it the shared `$CANON` mutated the
# suite's own canonical fixture mid-run, which is the kind of hidden coupling that makes a later
# arm's precondition true for a reason nobody chose. One brief, one test.
OKNB="$TMP/nonblocking-ok.txt"; cp "$CANON" "$OKNB"
out="$( cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
       bash "$NB" bgok "$TMP/wt" "$OKNB" 20 2>&1 )"; rc=$?
[ "$rc" -eq 0 ]; ck $? "POSITIVE CONTROL: nonblocking-dispatch.sh LAUNCHES for a valid brief ($(printf '%s' "$out" | tail -1))"
# The worker is backgrounded; wait for its durable verdict rather than sleeping a guess.
for _i in $(seq 1 100); do [ -s "$TMP/bg-o/bg/bgok.rc" ] && break; sleep 0.1; done
[ "$(cat "$TMP/bg-o/bg/bgok.rc" 2>/dev/null)" = "0" ]; ck $? "…and the worker reached a SUCCESSFUL durable exit status (a 74 refusal also produces a file, so existence alone proves nothing)"
grep -q 'PI_RAN' "$PI_LOG"; ck $? "…with the stub pi actually invoked"

# ── §D.2 #2981 — the AUTHORED brief gets COMMIT AS YOU GO APPENDED, idempotently.
# The measured batch behind #2981 was five `prfix` workers dispatched through THIS path, and every one
# held its single commit for the end and was killed at its cap with 0 commits. The research contract
# above is REFUSED when absent (80) because a worker that never looked first is that gate's defect;
# this one is APPENDED, because an otherwise complete authored brief must not become a dead dispatch
# over one missing sentence — so the assertion is on the FILE the worker receives, not the source.
DELIVERY_HEAD="$(bash "$HERE/reviewer-preflight.sh" --delivery-brief bg | head -1)"
[ -n "$DELIVERY_HEAD" ]; ck $? "the delivery section renders a heading ($(printf '%.40s' "$DELIVERY_HEAD"))"
AUTH="$TMP/authored.txt"; cp "$CANON" "$AUTH"
grep -qF -- "$DELIVERY_HEAD" "$AUTH"; rc=$?
[ "$rc" -ne 0 ]; ck $? "fixture: the authored brief does NOT already carry the section (so the append is what puts it there)"
cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
  bash "$NB" bgdelivery "$TMP/wt" "$AUTH" 20 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and a dispatch through nonblocking-dispatch.sh still LAUNCHES (rc=$rc)"
for _i in $(seq 1 100); do [ -s "$TMP/bg-o/bg/bgdelivery.rc" ] && break; sleep 0.1; done
grep -qF -- "$DELIVERY_HEAD" "$AUTH"; ck $? "…and the brief the worker received CARRIES it (appended, never refused)"
[ "$(grep -cF -- "$DELIVERY_HEAD" "$AUTH")" -eq 1 ]; ck $? "…exactly once"
# ⛔ IDEMPOTENCE IS THE POINT: a re-dispatch on the same brief file must not grow it. Without this arm
# an append that concatenated the section on every attempt would pass every assertion above.
cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
  bash "$NB" bgdelivery2 "$TMP/wt" "$AUTH" 20 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -cF -- "$DELIVERY_HEAD" "$AUTH")" -eq 1 ]; ck $? "…and a SECOND dispatch does NOT append a second copy (idempotent, rc=$rc)"
# ⛔ THE ROLE IS THE KIND'S, NOT A HARDCODED ONE (this PR's review, cycle 1 — P2). This dispatch passes
# FOUR arguments, so `$WK` is the documented `bg` default and the role must be `bg`. It used to render
# `prfix` unconditionally, which told an `ai-drainer.sh` hygiene lane "Your PR is ALREADY OPEN" — a
# false statement about a worker that owns no PR. Asserted BOTH ways so neither sentence can be
# silently swapped back: the `bg` claim is absent, and the conditional one is present.
case "$(cat "$AUTH")" in *"Your PR is ALREADY OPEN"*) rc=0;; *) rc=1;; esac
[ "$rc" -ne 0 ]; ck $? "…and a 4-arg (bg) dispatch does NOT get the prfix claim 'Your PR is ALREADY OPEN'"
grep -qF 'already has an open PR, commit and push onto it' "$AUTH"; ck $? "…it gets the bg role's CONDITIONAL PR sentence instead"
# …and the other side of the same arm: a declared `prfix` dispatch DOES get the prfix sentence. Without
# this, a regression that rendered `bg` for everything would pass every assertion above.
AUTH_PRFIX="$TMP/authored-prfix.txt"; cp "$CANON" "$AUTH_PRFIX"
cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
  bash "$NB" bgdelivery3 "$TMP/wt" "$AUTH_PRFIX" 20 prfix >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and a DECLARED prfix dispatch still LAUNCHES (rc=$rc)"
for _i in $(seq 1 100); do [ -s "$TMP/bg-o/bg/bgdelivery3.rc" ] && break; sleep 0.1; done
grep -qF 'Your PR is ALREADY OPEN' "$AUTH_PRFIX"; ck $? "…and IT gets the prfix role (the role follows \$WK, both directions)"
case "$(cat "$AUTH_PRFIX")" in *"already has an open PR, commit and push onto it"*) rc=0;; *) rc=1;; esac
[ "$rc" -ne 0 ]; ck $? "…never the bg sentence (so the two arms cannot both pass on one hardcoded role)"
# ⛔ THE COLLISION THE ROLE-INVARIANT HEADING COULD NOT SEE (this PR's review, cycle 2 — P2). The
# heading is IDENTICAL in all three roles, so a heading-only idempotency test declares a brief complete
# when it carries ANOTHER role's copy. This is the reachable instance, not a hypothetical: the controller
# template is pinned to the `lane` render, a controller authors its brief by copying it, and
# `pr-doctor.py` dispatches that same file as `prfix` — so before the fix the heading matched, nothing
# was appended, and the worker was ordered to open a PR it ALREADY HAS (#2148/#2325's exact class).
# Build the fixture FROM the real template so the arm cannot drift away from the artifact it describes.
AUTH_TMPL="$TMP/authored-from-template.txt"; cp "$ROOT/templates/LANE-BRIEF.md" "$AUTH_TMPL"
grep -qF 'Open the PR as soon as the first commit is pushed' "$AUTH_TMPL"; ck $? "template fixture: the controller template carries the LANE PR sentence (that is what makes the collision reachable)"
case "$(cat "$AUTH_TMPL")" in *"Your PR is ALREADY OPEN"*) rc=0;; *) rc=1;; esac
[ "$rc" -ne 0 ]; ck $? "template fixture: …and NOT the prfix one"
cd "$FIXREPO" && O="$TMP/bg-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
  bash "$NB" bgdelivery4 "$TMP/wt" "$AUTH_TMPL" 20 prfix >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and a prfix dispatch over a template-derived (lane) brief still LAUNCHES (rc=$rc)"
for _i in $(seq 1 100); do [ -s "$TMP/bg-o/bg/bgdelivery4.rc" ] && break; sleep 0.1; done
grep -qF 'Your PR is ALREADY OPEN' "$AUTH_TMPL"; ck $? "⛔ …and the brief the worker received NOW carries the prfix sentence (a role-invariant heading would have skipped the append)"
# ⛔ AND THE STALE ORDER IS MARKED SUPERSEDED, IN THAT ORDER (this PR's review, cycle 3 — P2). The arm
# above proves the CORRECT sentence ARRIVED; it cannot see the FALSE one still sitting above it
# ("Open the PR as soon as the first commit is pushed"). Asserting only arrival is half an assertion:
# append-only left the worker holding both, relying on a reading-order assumption nothing enforced.
# The append policy is NOT reversed — the author's bullet stays where its author put it — so what must
# now be true is that the worker meets the notice and THEN the true order, last.
grep -qF 'SUPERSEDES ANY COPY ABOVE THIS LINE' "$AUTH_TMPL"; ck $? "⛔ …and the stale lane order is MARKED SUPERSEDED (arrival alone cannot see the false order still above it)"
awk '/SUPERSEDES ANY COPY ABOVE THIS LINE/{m=NR} /Your PR is ALREADY OPEN/{if(!p)p=NR} END{exit !(m && p && p>m)}' "$AUTH_TMPL"
ck $? "…and the notice lands BEFORE the true sentence, so the last word the worker reads is the true one"
# The already-correct case must NOT gain a notice — its brief has no stale copy, so a notice there
# would be a false claim of its own (and it would break the byte-for-byte promise above).
case "$(cat "$AUTH_PRFIX")" in *"SUPERSEDES ANY COPY ABOVE THIS LINE"*) rc=0;; *) rc=1;; esac
[ "$rc" -ne 0 ]; ck $? "…and a brief that was ALREADY role-correct gets NO supersession notice (idempotent, no false claim)"
# ── §D.3 #2981 — THE HELPER IS RESOLVED LIKE EVERYTHING ELSE IN THIS FILE, NOT FROM `$SELF` ALONE.
# ⛔ THIS IS THE BOX-WIDE-STANDSTILL CLASS THE DISPATCHER ITSELF DOCUMENTS, ONE SCREEN ABOVE THE CODE
# UNDER TEST: "`$O` is seeded file by file, so a NEW dispatcher can run against an OLD
# `$O/spawn-gate.sh`" — and its brief-gate resolver searches FOUR homes for exactly that reason. A
# `$SELF`-only pin on `reviewer-preflight.sh` turns a half-seeded `$O` into "every dispatch on this
# box exits 78": the fleet stops dispatching, which is the outcome #2981 exists to prevent, caused by
# the rule that prevents it (`install.sh` names the same failure for `brief-gate.sh`). The fixture is
# the skew faithfully — every harness script seeded into one directory EXCEPT the helper, which is
# reachable only through `$AGENT_INFRA_PATH` — so a pin that only looks beside itself goes red here.
SKEW="$TMP/skew"; mkdir -p "$SKEW"
cp "$HERE"/*.sh "$SKEW"/ 2>/dev/null; cp "$HERE"/*.py "$SKEW"/ 2>/dev/null
rm -f "$SKEW/reviewer-preflight.sh"
[ -f "$SKEW/nonblocking-dispatch.sh" ] && [ ! -f "$SKEW/reviewer-preflight.sh" ]; ck $? "fixture: a seeded harness dir WITHOUT reviewer-preflight.sh (the half-synced \$O shape)"
SKEWBRIEF="$TMP/skew-brief.txt"; cp "$CANON" "$SKEWBRIEF"
out="$( cd "$FIXREPO" && O="$TMP/bg-o" AGENT_INFRA_PATH="$ROOT" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" MAX_LOAD=1000 DISK_MIN_FREE_MB=1 \
       bash "$SKEW/nonblocking-dispatch.sh" bgskew "$TMP/wt" "$SKEWBRIEF" 20 prfix 2>&1 )"; rc=$?
[ "$rc" -eq 0 ]; ck $? "⛔ …and the skew copy still LAUNCHES: the helper is found through the fallback homes, not \$SELF alone (rc=$rc: $(printf '%s' "$out" | tail -1))"
for _i in $(seq 1 100); do [ -s "$TMP/bg-o/bg/bgskew.rc" ] && break; sleep 0.1; done
grep -qF -- "$DELIVERY_HEAD" "$SKEWBRIEF"; ck $? "…and the worker's brief CARRIES the section, rendered by the helper it resolved (the fallback is not an empty pass)"

# ── orch-send.sh + safe-send.sh: the pane-order paths. Stub `cmux` records every call, so "refused"
# is again proven by absence.
printf '#!/bin/sh\necho "CMUX_RAN $*" >> "$CMUX_LOG"\ncase "$1 $2" in "read-screen --workspace") echo "~/Documents/GitHub/agent-infra";; esac\nexit 0\n' > "$TMP/bin/cmux"
chmod +x "$TMP/bin/cmux"
export CMUX_LOG="$TMP/cmux.log"
: > "$CMUX_LOG"
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" \
  bash "$ROOT/scripts/orch-send.sh" 00000000-0000-0000-0000-000000000000 test "just fix it, no research" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "orch-send.sh REFUSES an order with no research contract (rc=$rc)"
[ -s "$CMUX_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and cmux was never called (the refusal precedes target resolution — the defect is the brief, not the pane)"
: > "$CMUX_LOG"
# ⛔ THE STUB NEVER SUBMITS, SO WITHOUT A WINDOW THIS ARM WAITS ONE OUT (#1881 review P2). The stub
# `cmux` records calls and never names a session, so nothing can ever verify: `orch-send.sh` polls
# `read-screen` to its deadline (90 s default + the helper's two 2 s sleeps ≈ 95 s of a CI shard) and
# the assertion below — satisfied by the footer probe — uses none of it. `ORCH_SEND_VERIFY_TIMEOUT=0`
# is what the Python suite sets for the same reason: it changes WHAT the arm costs, not what it proves.
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" ORCH_SEND_VERIFY_TIMEOUT=0 \
  bash "$ROOT/scripts/orch-send.sh" 00000000-0000-0000-0000-000000000000 test "@$CANON" >/dev/null 2>&1
[ -s "$CMUX_LOG" ]; ck $? "POSITIVE CONTROL: a compliant @file order passes the gate and reaches cmux"
: > "$CMUX_LOG"
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" \
  bash "$ROOT/scripts/safe-send.sh" 00000000-0000-0000-0000-000000000000 test "$TMP/no-research.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "safe-send.sh REFUSES a non-compliant brief file (rc=$rc)"
[ -s "$CMUX_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and cmux was never called there either"
# The ONE documented exemption: `--force` is the STOP route (see safe-send.sh's header). Pinned here
# so the exemption is a DECISION with a test, not an accident a later reader rediscovers.
: > "$CMUX_LOG"
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" SAFE_SEND_DISPATCH=/bin/true \
  bash "$ROOT/scripts/safe-send.sh" 00000000-0000-0000-0000-000000000000 test "$TMP/no-research.txt" --force >/dev/null 2>&1
[ -s "$CMUX_LOG" ]; ck $? "…but --force (the documented STOP route) bypasses the brief gate — the exemption is pinned, not implied"

# ── safe-send.sh `--notice`: the ALERT route (review cycle 5, P1). The fleet's only controller alert
# (tools/fleet/outcome_canary.py) sends a MACHINE-COMPOSED message through safe-send.sh, and that
# message has no brief and no research question. With the gate unconditional every alert was refused
# 80 and then classified AMBIGUOUS by the canary — which SUPPRESSES — so the controller was never
# told. Two assertions, both driven, and they must move in opposite directions: the alert refuses
# WITHOUT the mode (so the exemption is a real mode and not a hole in the gate) and is admitted WITH
# it; and the no-pi guard still fires under --notice, because typing an alert into a bare shell
# EXECUTES. (A `--notice` that also skipped that guard would be the bug this file exists to prevent.)
ALERT="$TMP/alert.txt"; printf 'STALE PR: 999 has not moved in 3h\n' > "$ALERT"
: > "$CMUX_LOG"
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" \
  bash "$ROOT/scripts/safe-send.sh" 00000000-0000-0000-0000-000000000000 outcome-canary "$ALERT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "an ALERT with no research contract is still REFUSED without --notice (rc=$rc)"
[ -s "$CMUX_LOG" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and the pane was not even read (no exemption by accident)"
: > "$CMUX_LOG"
PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" SAFE_SEND_DISPATCH=/bin/true \
  bash "$ROOT/scripts/safe-send.sh" 00000000-0000-0000-0000-000000000000 outcome-canary "$ALERT" --notice >"$TMP/notice.out" 2>&1; rc=$?
{ [ "$rc" -ne 80 ] && [ "$rc" -ne 78 ]; }; ck $? "POSITIVE CONTROL: --notice passes the BRIEF gate for a machine-composed alert (rc=$rc)"
grep -q 'NO pi IN THIS PANE' "$TMP/notice.out"; ck $? "…and the no-pi guard is STILL in force under --notice (an alert typed into a bare shell would be EXECUTED)"
# ⛔ A BYPASS NOBODY CAN TYPO. An unknown mode must be a usage error, not a silent exemption: the next
# person who reaches for "--no-gate" would otherwise get a gate-free send and never learn it.
bash "$ROOT/scripts/safe-send.sh" ws label "$ALERT" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; ck $? "an UNKNOWN mode is a usage error (2), never a silent exemption (rc=$rc)"

# ── pr-doctor.py: the fleet's own generated worker brief must carry the contract, or every worker the
# beat spawns is refused. Driven through the module, not grepped from the source.
out="$("$ROOT/../venv-brief-probe" 2>/dev/null; python3 - "$ROOT" <<'PY' 2>/dev/null
import importlib.util, sys, os
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("pd", os.path.join(root, "scripts", "pr-doctor.py"))
m = importlib.util.module_from_spec(spec); sys.modules["pd"] = m
spec.loader.exec_module(m)
pr = {"number": 7, "headRefOid": "a" * 40, "title": "t", "headRefName": "fix/x",
      "isCrossRepository": False}
b = m.brief(pr, "fix-ci", "check x")
assert b.strip(), "brief() returned nothing"
assert "## RESEARCH FIRST" in b, "pr-doctor's brief carries no research contract"
assert "CONTRADICTION TEST" in b, "pr-doctor's brief carries no contradiction test"
assert m.brief(pr, "no-such-action") == "", "an EMPTY order must stay empty (no phantom dispatch)"
open(os.path.join(sys.argv[1], ".pd-brief.txt"), "w").write(b)
print("ok")
PY
)"
# ⛔ THE SENTINEL IS THE LAST LINE, NOT THE WHOLE STREAM. `brief()` logs to STDOUT (`log()` in
# pr-doctor.py -- the operator log an agent-infra pass is read from), and agent-infra#2708 gave it one
# more line on that path: "brief: research contract rendered by <copy> and admitted by N validator(s)",
# which is what turns the measured 6h32m stale-copy stall into a one-line read. Comparing the ENTIRE
# capture to "ok" made that legitimate log line a red in this shard -- a test that fails because the
# capability got MORE observable. The probe still has to reach its final `print("ok")`, which is after
# every assert, so nothing is weakened: a failed assert or a crash leaves the last line short of "ok".
# Parameter expansion, not a pipe: `${out##*$'\n'}` has no subprocess to SIGPIPE. (This file sets only
# `set -u`; `run-bash-shards.sh` sets `pipefail` for ITSELF but spawns each shard as `bash "$1"`, a child
# that does not inherit it. `sigpipe-grep-guard` is repo-wide regardless, so the expansion stands on its
# own merits and not on a `pipefail` claim this file cannot make.)
[ "${out##*$'\n'}" = "ok" ]; ck $? "pr-doctor.py's generated brief carries the research contract (driven through brief())"
bash "$GATE" --check "$ROOT/.pd-brief.txt" worker >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and that generated brief PASSES the validator (worker role) (rc=$rc)"
rm -f "$ROOT/.pd-brief.txt"

# ── lane.sh: the GENERATED lane brief must pass the gate, and a missing validator must STOP the lane.
# LANE_DRY_RUN=1 is the shipped seam that renders the real brief without starting an agent (#2148).
mkdir -p "$TMP/lane-o"
# ⛔ THE LANE'S CWD MUST BE A CHECKOUT OF THE REPO AND BRANCH IT IS TOLD (agent-infra#2724/#2694):
# lane.sh asserts the worktree's own origin and its attached branch before writing a brief, so driving
# it from a bare `mktemp -d` refuses 72 and drops the three brief assertions below. Same fixture shape
# the sibling suites carry (reviewer-preflight, capacity-transfer, spawn-gate).
# ⛔ `init.defaultBranch` NAMES THE BRANCH, so the fixture is born ON the branch it is told
# (no worktree switch: this suite is run where a branch-state command is not available).
( cd "$TMP" && git -c init.defaultBranch=fix/research-first-gate init -q . \
    && git remote add origin https://github.com/daniel-ospina/agent-infra.git \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
( cd "$TMP" && O="$TMP/lane-o" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$HERE/lane.sh" 2258 fix/research-first-gate daniel-ospina/agent-infra ) >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "lane.sh --dry-run renders its brief and exits 0 (rc=$rc)"
bash "$GATE" --check "$TMP/lane-o/logs/prompt-2258.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "the GENERATED lane brief PASSES the research gate (the lane is actually told) (rc=$rc)"
grep -q '## RESEARCH FIRST' "$TMP/lane-o/logs/prompt-2258.txt"; ck $? "…and carries the section, not just the pre-flight line"
grep -q '#2258 research-first' "$TMP/lane-o/logs/lane-2258.log"; ck $? "…and the one-line pre-flight is in the lane LOG (what an operator greps)"
mv "$GATE" "$GATE.moved"
# ⛔ `env -u AGENT_INFRA_PATH`: see the note at the §"MISSING validator" arm — the variable is a
# documented fifth search root and is exported on every cell, so without this the "missing validator"
# fixture finds the REAL one and the arm refuses 72 (the worktree precondition) instead of 78.
( cd "$TMP" && env -u AGENT_INFRA_PATH O="$TMP/lane-o2" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    HOME="$TMP/fakehome" bash "$HERE/lane.sh" 2258 fix/x daniel-ospina/agent-infra ) >/dev/null 2>&1; rc=$?
mv "$GATE.moved" "$GATE"
[ "$rc" -eq 78 ]; ck $? "a MISSING validator refuses the LANE with 78 (fail-closed: never a lane nobody asked to look first) (rc=$rc)"

# ── the authored template must be a COMPLIANT brief, or every controller that copies it authoring a
#    refused dispatch (the #2148 suite makes the same assertion for the reviewer section).
TEMPLATE="$ROOT/templates/LANE-BRIEF.md"
[ -f "$TEMPLATE" ]; ck $? "templates/LANE-BRIEF.md exists"
bash "$GATE" --check "$TEMPLATE" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "the controller brief template IS a compliant brief (the template cannot teach a refused shape) (rc=$rc)"
grep -q '^CONTRADICTION TEST:' "$TEMPLATE"; ck $? "…and carries the contradiction test as its own labelled line"

echo
echo "§E the census — every file that touches the gate is declared, and the population is not empty"
# ⛔ AN EQUALITY, NOT A FLOOR (the shape spawn-gate.test.sh uses for `pi -p` invokers): a dispatch path
# added tomorrow that never gates must REDDEN this, and so must a caller that silently drops its gate.
# The allowlist is by name and by ROLE, and each entry says what it is — a name list with no reasons
# is the thing this census exists to prevent.
# STATED LIMIT (the shape the `pi`-census above uses): the population is `scripts/`, `templates/` and
# the root `AGENTS.md` — a reference from anywhere else (a skill, a docs/ page) is outside this scan,
# by design, because a doc mention must never be able to redden a gate census.
found="$(cd "$ROOT" && { grep -rlE 'brief-gate\.sh|brief_gate_(lib|run|verify|section|line|missing)' \
          --include='*.sh' --include='*.py' --include='*.md' scripts templates 2>/dev/null
          grep -lE 'brief-gate\.sh' AGENTS.md 2>/dev/null; } \
          | grep -v 'brief-gate\.test\.sh$' | sort | tr '\n' ' ' | sed 's/ $//')"
# The CALLERS are the eight below; the rest NAME the gate on purpose and are declared rather than
# filtered out by a pattern — a filter would silently absorb the next caller that happens to be a
# `.md` file, which is the "gate that cannot see the thing it exists for" shape.
#
# ⛔ AND A SUITE THAT DRIVES `run_agent` IS A MEMBER TOO (review cycle 3, P1). `capacity-transfer.test.sh`
# renders its brief fixture FROM this validator, so it references the gate; but the class it belongs to
# is broader than "references": ANY suite that drives a dispatch path needs a COMPLIANT fixture, and
# this census cannot see one that merely *drives* the path. That gap let two registered shards go red
# in one commit (capacity-transfer and tests/pi-shim — the latter with a brief that was never created
# at all). Declared here so the reference is accounted for; the broader class is named in the STATED
# LIMIT below rather than silently believed to be covered.
# the at all). Declared here so the reference is accounted for; the broader class is named in the STATED
# LIMIT below rather than silently believed to be covered.
#
# ⛔ AND A SUITE THAT BUILDS ITS OWN FIXTURES FROM THIS VALIDATOR IS A MEMBER TOO (#1881 review P2).
# `scripts/test_cmux_payload.py` asks `brief-gate.sh --section lane` for the RESEARCH contract its
# dispatch fixtures must carry (the same construction `capacity-transfer.test.sh` uses, and for the
# same reason: a hard-coded block would drift from the gate and the suite would pin a brief no
# dispatcher accepts). It reaches the gate through `orch-send.sh`, which this census already counts,
# so it is a deliberate NAMER of the gate rather than a new dispatch path — but it is a REFERENCER,
# and an undeclared one reddens this equality. Measured: unregistered, this arm fails with
# `ADDED: scripts/test_cmux_payload.py`, which is exactly the attributable red the census exists for.
# ⛔ AND THE LIST IS AN EQUALITY, SO IT MUST BE KEPT CURRENT BY WHOEVER MOVES THE SCAN (#1881 LANE,
# measured). The five `orchestrator-harness` entries without a comment above arrived on `main` after
# the last time this list was edited — `ai-drainer.sh` dispatches through `brief_gate_run`, and the
# four suites drive gate-carrying paths — so the arm was ALREADY red on `main` (`found` is a strict
# superset), independently of any branch. Declared here because an equality that is red on its own
# base stops being a signal: every PR inherits the same red and nobody can attribute it.
EXPECTED="AGENTS.md scripts/orch-send.sh scripts/orchestrator-harness/ARCHITECTURE.md scripts/orchestrator-harness/README.md scripts/orchestrator-harness/ai-drainer.sh scripts/orchestrator-harness/ai-drainer.test.sh scripts/orchestrator-harness/brief-gate.sh scripts/orchestrator-harness/capacity-transfer.test.sh scripts/orchestrator-harness/check-single-source.sh scripts/orchestrator-harness/fix-one.sh scripts/orchestrator-harness/install.sh scripts/orchestrator-harness/lane-bound.test.sh scripts/orchestrator-harness/lane.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/nonblocking-dispatch.sh scripts/orchestrator-harness/reviewer-preflight.test.sh scripts/orchestrator-harness/selftest.sh scripts/orchestrator-harness/spawn-gate.sh scripts/orchestrator-harness/spawn-gate.test.sh scripts/orchestrator-harness/wip-rescue-exit.test.sh scripts/pr-doctor.py scripts/safe-send.sh scripts/test_cmux_payload.py scripts/test_pr_doctor.py templates/AGENTS.base.md templates/LANE-BRIEF.md"
[ "$found" = "$EXPECTED" ]; crc=$?
[ "$crc" -eq 0 ] || echo "      found: [$found]"
ck "$crc" "the files touching the gate are EXACTLY the declared set (a new dispatch path must declare itself)"
# STATED LIMIT, so the next lane does not read this census as covering a class it cannot see: it counts
# REFERENCERS under scripts/ + templates/ + AGENTS.md. A suite that drives `run_agent` (or a dispatcher)
# through a fixture WITHOUT naming the gate is invisible here — `tests/pi-shim/run.sh` was exactly that,
# and it was red for a missing brief fixture no census could have caught.
[ -n "$found" ]; ck $? "…and the census found something (an empty scan is never a clean scan)"
# …and each DISPATCH path is listed with a call, not merely a mention. This is the half that catches a
# caller whose gate line was deleted while its comment stayed.
for pair in "scripts/orchestrator-harness/lane.sh:--section lane" \
            "scripts/orchestrator-harness/fix-one.sh:--section fixer" \
            "scripts/orchestrator-harness/merge-one.sh:--section reviewer" \
            "scripts/orchestrator-harness/nonblocking-dispatch.sh:--check" \
            "scripts/orchestrator-harness/spawn-gate.sh:brief_gate_run" \
            "scripts/orch-send.sh:--check -" \
            "scripts/safe-send.sh:--check" \
            "scripts/pr-doctor.py:brief-gate.sh"; do
  f="${pair%%:*}"; needle="${pair#*:}"
  grep -qF -e "$needle" "$ROOT/$f"; ck $? "$(basename "$f") still carries its gate call ('$needle')"
done

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
