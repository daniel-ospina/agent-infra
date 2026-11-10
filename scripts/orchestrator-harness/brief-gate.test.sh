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
# ⛔ AND THE LANE'S OWN `WIP_PATH` IS CLEARED FOR §D, WHICH DRIVES A REAL WORKER (measured 2026-11-07,
# running this suite FROM A FIXER LANE — which is where lanes run it). The worker's exit path roots its
# rescue at `"${WIP_PATH:-$PWD}"` (spawn-gate.sh), so a caller's `WIP_PATH` OUTRANKS the dispatcher's
# `cd "$TMP/wt"`: §D's worker rescued THIS lane's worktree, pushed a `refs/wip/*` ref to the REAL
# origin, and the one arm that watches the worker then missed its 10 s window because the rescue had
# real work to do — a red that was neither the brief gate's nor the branch's. §D is about the BRIEF and
# the delivery section, never about the caller's tree, so the envelope is cleared here the same way the
# capability gate is — declared, not silently `unset` in a helper arms cannot see.
export WIP_PATH=
# ⛔ AND THE MEMORY ARM IS NEUTRALISED FOR THE SAME REASON, one gate over (agent-infra#2387). Every arm
# below drives the SHIPPED `run_agent` with `MAX_LOAD=1000 DISK_MIN_FREE_MB=1` so that a load or disk
# refusal cannot decide an arm about the BRIEF. `run_agent` now also consults available memory before
# load, so on a box under the shipped 2048 MB floor the positive control (`rc=0 started=1`) returned 73
# and the suite reported its own subject — the research-first contract — as broken. `1` disables the
# floor's ability to bind; the SHIPPED default and its arithmetic are asserted in spawn-gate.test.sh,
# which owns them.
export MEM_MIN_AVAIL_MB=1
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$HERE/brief-gate.sh"
PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
# ⛔ THE PREVIOUS WORK BLOCK IS INCLUDED HERE FOR THE REASON IT EXISTS (#3484): this fixture's subject is
# MARKDOWN SPELLINGS, so it must satisfy the OTHER contracts completely — otherwise a refusal reported
# here would be about the absent PW block and this arm would prove nothing about style.
{ printf '## RESEARCH FIRST\n### Internal\n- **INTERNAL:** read the tracker first\n### External\n1. EXTERNAL: fetch the RFC\n'
  printf 'RUNG: 3 — web_fetch https://example.com/rfc\nCONTRADICTION TEST: no recorded decision reaches this work\n'
  printf '\n## PREVIOUS WORK\n- **CLAIM:** unclaimed\n- **WIP:** issue-<N> -> none (measured in fixture)\n'
  # ⛔ `printf` NEEDS A FORMAT STRING: a line starting with `-` is parsed as an OPTION and the whole
  # argument is dropped (`printf: - : invalid option`), which silently produced a fixture that was
  # short three labels — a vacuous-arm generator, not a spelling test.
  printf '%s\n' '- **BRANCH:** none' '- **WORKTREE:** none' '- **PRIOR:** no previous attempt'; } > "$TMP/styled.txt"
bash "$GATE" --check "$TMP/styled.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "bold/bullet/numbered/subsection spellings are all admitted (got $rc)"

echo
# ── §A2 THE REVIEW ROUND (#3441) — the mandate PAST ROUND 3, and the round as a real input ──────
# Owner ruling (2026-11-04): from round 4 a REVIEW brief must name what COMPARABLE / COMPETITOR
# implementations do, because rounds 1-3 converge on "is this line correct" (a local read CAN answer)
# and past round 3 the loop has stopped converging. Before this change the brief generator had NO
# round input at all, so round 1 and round 7 were briefed identically and the mandate could not be
# expressed — let alone enforced.
echo "§A2 the review ROUND — the mandate past round 3, and the round as a real input (agent-infra#3441)"
# ⛔ THE REQUIREMENT IS A LABEL (`COMPARABLES:`), NOT A WORD-SEARCH INSIDE `EXTERNAL:` — and that is a
# fix a fresh review of this very change forced. The first draft matched /comparable|competitor/ in the
# EXTERNAL line, and the canonical block THIS GATE EMITS says "how comparable systems solve this", so
# the clause was satisfied by the gate own boilerplate for every generated brief at every round: a gate
# whose PASS was supplied by itself, inert on the one path #3441 exists for. The fixtures below pin
# both directions — a brief with the full research contract but NO `COMPARABLES:` line is admitted at
# rounds 1-3 and refused from 4 — and the strongest arm is (r7-canon3): a brief built by the ROUND-3
# generator is REFUSED when it is used at round 7, which is the missing-round-plumbing defect itself.
# ⛔ EVERY FIXTURE BELOW ALSO CARRIES THE #3442 NON-VACUITY BLOCK, AND THAT IS PART OF THE MERGE, NOT
# DECORATION. `main` added a THIRD reviewer requirement while this branch was open (a `MUTATION
# ATTRIBUTION` section — #3442/#3481), so a reviewer brief that carries only the research contract is
# now refused for a reason that has nothing to do with the round. Without the block these arms redden
# with rc=80 at ROUND 1 as well, i.e. they would measure #3442 instead of the round they name — the
# same "the arm cannot tell which contract failed" defect §A pins for the missing tokens. The block
# is identical across the fixtures ON PURPOSE: the only variable any of these arms may move is the
# `COMPARABLES:` line and the round.
# ⛔ THE SAME MERGE-TIME REASON APPLIES AGAIN TO #3484's `PREVIOUS WORK` BLOCK, which landed while
# this branch was open: the contract is UNIVERSAL (every role, every round), so a round fixture
# without it is refused at round 1 as well and the arm would measure #3484 instead of the round it
# names. `PW_FIXTURE` is appended to every round fixture below, identically, for that reason — the
# arms must move ONE variable.
PW_FIXTURE='## PREVIOUS WORK
CLAIM: unclaimed (fixture)
WIP: issue-9999 -> none (measured in the round fixture)
BRANCH: none
WORKTREE: none
PRIOR: no previous attempt'
printf '## RESEARCH FIRST\nINTERNAL: read the diff at the head.\nEXTERNAL: vendor docs for the review gate only.\nRUNG: 2 — web_search model="sonar"\nCONTRADICTION TEST: no recorded decision reaches this work.\n\n## MUTATION ATTRIBUTION\nNO NEW ASSERTIONS: round fixture — this brief carries no assertion of its own.\n\n%s\n' "$PW_FIXTURE" > "$TMP/rev-vendor.txt"
printf '## RESEARCH FIRST\nINTERNAL: read the diff at the head.\nEXTERNAL: vendor docs for the review gate only.\nCOMPARABLES: comparable harnesses (an agent CI gate) cap review rounds and escalate at the ceiling.\nRUNG: 2 — web_search model="sonar"\nCONTRADICTION TEST: no recorded decision reaches this work.\n\n## MUTATION ATTRIBUTION\nNO NEW ASSERTIONS: round fixture — this brief carries no assertion of its own.\n\n%s\n' "$PW_FIXTURE" > "$TMP/rev-cmp.txt"
for r in 1 2 3; do
  bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer "$r" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "(r$r) a brief with NO comparables line is ADMITTED at round $r — the mandate starts at 4 (got $rc)"
done
for r in 4 7 12; do
  bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer "$r" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 80 ]; ck $? "(r$r) the same brief is REFUSED with 80 at round $r (got $rc)"
done
bash "$GATE" --check "$TMP/rev-cmp.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "a round-7 brief that DOES carry comparables is admitted (got $rc)"
# The refusal is ATTRIBUTABLE: the round clause has its own token, so a message that omitted it could
# not pass as "the author already knows about comparables".
bash "$GATE" --missing "$TMP/rev-vendor.txt" reviewer 7 2>/dev/null | grep -qx 'EXTERNAL-COMPARABLES'; ck $? "the missing token is EXTERNAL-COMPARABLES — one element, not a generic refusal"
OUTR="$(bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer 7 2>&1)"
grep -q 'COMPARABLE / COMPETITOR' <<<"$OUTR"; ck $? "the round-4 refusal TEACHES what is missing (a comparables line)"
grep -q 'round: 7' <<<"$OUTR"; ck $? "…and names the round it was refused at, so the author can see the input took effect"
# THE ROUND REACHES THE GENERATED BLOCK, which is the half a validator alone cannot give: every
# briefing caller splices `--section`, so a mandate that only lived in the validator would be advice.
bash "$GATE" --section reviewer 7 > "$TMP/sec-r7.txt" 2>/dev/null
grep -q '^COMPARABLES:' "$TMP/sec-r7.txt"; ck $? "--section reviewer 7 emits a COMPARABLES: line (the round is an INPUT to the canonical text)"
bash "$GATE" --section reviewer 3 > "$TMP/sec-r3.txt" 2>/dev/null
grep -q '^COMPARABLES:' "$TMP/sec-r3.txt"; rc=$?
[ "$rc" -ne 0 ]; ck $? "--section reviewer 3 does NOT (round 3 was never the problem to solve)"
bash "$GATE" --check "$TMP/sec-r7.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "the round-7 canonical block SATISFIES the round-7 validator (the gate cannot refuse its own advice) (got $rc)"
# ⛔ STATED RESIDUAL, PINNED AS BEHAVIOUR (fresh review of #3441, P2): THIS IS A *DELIVERY* CHECK, NOT A
# DEPTH CHECK. A brief whose `COMPARABLES:` line is nothing but the mandate's OWN wording names no
# comparable at all, and it is ADMITTED — because the gate reads the BRIEF, and the answer to "what do
# comparables do" lives in the reviewer's VERDICT. The alternative was worse: rejecting the placeholder
# would refuse `merge-one.sh`'s own generated brief (it splices exactly this block) at exit 80, i.e. it
# would break every round-≥4 review in order to make a text check look stronger than it is. So the
# clause guarantees the mandate REACHES the reviewer and refuses a hand-authored brief that dropped the
# label; it cannot guarantee the reviewer complied. Pinned here so the stronger reading — the one the
# README used to carry — cannot be re-adopted by a later lane without reddening this arm.
{ printf '## RESEARCH FIRST\nINTERNAL: read the head.\nEXTERNAL: vendor docs only.\nRUNG: 3 — web_fetch https://x\n'
  printf 'COMPARABLES: name at least one COMPARABLE / COMPETITOR implementation and say how it solves it.\n'
  printf 'CONTRADICTION TEST: none recorded.\n'
  printf '\n## MUTATION ATTRIBUTION\nNO NEW ASSERTIONS: round fixture — this brief carries no assertion of its own.\n\n%s\n' "$PW_FIXTURE"; } > "$TMP/cmp-boilerplate.txt"
bash "$GATE" --check "$TMP/cmp-boilerplate.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(residual) the mandate's own wording SATISFIES the clause — a DELIVERY check, not a depth check (got $rc)"
# …and the delivery half is real and non-vacuous: the SAME brief with the label DELETED is refused. Without
# this contrast the arm above would pin the clause as unfalsifiable rather than as a weakened one.
grep -v '^COMPARABLES:' "$TMP/cmp-boilerplate.txt" > "$TMP/cmp-boilerplate-no.txt"
bash "$GATE" --check "$TMP/cmp-boilerplate-no.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(residual) …but the SAME brief with the label DELETED is REFUSED — the clause is non-vacuous on delivery (got $rc)"
# (r7-canon3) ⛔ THE ARM THAT WOULD HAVE CAUGHT THE VACUOUS GATE: a brief generated at the WRONG round
# is refused by the round it is used at. This is the plumbing defect #3441 names, pinned as behaviour.
bash "$GATE" --check "$TMP/sec-r3.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(r7-canon3) a ROUND-3 generated brief is REFUSED when used at round 7 — the round really is an input (got $rc)"
# ⛔ THE LABEL IS SCOPED TO THE RESEARCH SECTION, LIKE ITS SIBLINGS (round 2 review, P2). `cmp` was set
# outside the `ins` guard, so a `COMPARABLES:` line under an unrelated heading satisfied the round>=4
# clause — the same trick §A refuses for `EXTERNAL:` ("scoping is enforced"). Pinned in both directions.
{ printf '## RESEARCH FIRST\nINTERNAL: read the head.\nEXTERNAL: vendor docs only.\nRUNG: 3 — web_fetch https://x\n'
  printf 'CONTRADICTION TEST: none recorded.\n\n## NOTES\nCOMPARABLES: out of the research section\n'
  printf '\n## MUTATION ATTRIBUTION\nNO NEW ASSERTIONS: round fixture — this brief carries no assertion of its own.\n\n%s\n' "$PW_FIXTURE"; } > "$TMP/cmp-outside.txt"
bash "$GATE" --check "$TMP/cmp-outside.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "a COMPARABLES line OUTSIDE the research section does NOT satisfy round 4+ (got $rc)"
bash "$GATE" --check "$TMP/cmp-outside.txt" reviewer 3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and the same brief is still admitted at round 3, where the clause does not apply (got $rc)"
# STATED RESIDUAL, pinned as behaviour so nobody discovers it as a surprise: a caller that passes NO
# round gets the round-3 contract. `merge-one.sh` always supplies one (`REV_ROUND`, else
# `state/reviewround-<PR>`), so our own path cannot reach this — a HAND-authored brief can.
bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(residual) NO round supplied => the round-3 contract applies (a lost round cannot buy the mandate) (got $rc)"
bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer banana >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(residual) a GARBAGE round is treated as unknown, not as a high one (got $rc)"
# ⛔ FAIL-OPEN ARITHMETIC ON THE ROUND (fresh review, P2): `$(( 10#… ))` on a longer-than-nine-digit
# value WRAPS NEGATIVE, and a negative round is neither 0 nor >= the threshold — it would slip past the
# mandate entirely. Pinned so the bound cannot be dropped.
bash "$GATE" --check "$TMP/rev-vendor.txt" reviewer 9223372036854775808 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(round-bound) an absurd-but-numeric round is coerced to UNKNOWN (0), never wrapped negative past the mandate (got $rc)"
bash "$GATE" --check "$TMP/rev-cmp.txt" reviewer 9223372036854775808 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and the wrapped value does not REFUSE a brief either (the coercion is to 0, not to a huge round) (got $rc)"
# ── NON-VACUITY, TWO MUTANTS because the arm makes TWO claims (#3441 acceptance: "mutation-test that
# refusal"). Both are derived FROM THE SHIPPED FILE so they track it, and both assert the file CHANGED
# — a sed whose anchor stopped matching yields an unchanged file and would prove nothing.
MUT2="$TMP/mutant-nocmp.sh"
sed 's/^  if (gr_role == "reviewer".*EXTERNAL-COMPARABLES"$/  # MUTANT: the round-4 refusal is removed/' "$GATE" > "$MUT2"
diff -q "$GATE" "$MUT2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "MUTANT-A really changed the file (the sed anchor still matches the awk refusal)"
bash -n "$MUT2" && bash "$MUT2" --section reviewer 7 >/dev/null 2>&1; ck $? "MUTANT-A still parses and renders (a program, not a syntax error failing for the wrong reason)"
bash "$MUT2" --check "$TMP/rev-vendor.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "MUTATION-A: 'a round-7 brief with no comparables is refused' now FAILS — the mutant admits it (rc=$rc, §A2 would report ❌)"
bash "$MUT2" --check "$TMP/rev-vendor.txt" reviewer 3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "MUTATION-A leaves the round-3 arm UNCHANGED — the refusal is scoped to the round, not blanket (rc=$rc)"
MUT3="$TMP/mutant-nosection.sh"
# MUTANT-B removes the round>=4 EMISSION from the generator — the plumbing half. It must redden
# (r7-canon3)'s sibling: the round-7 canonical block would no longer satisfy the round-7 validator.
# ⛔ MUTATE THE CONDITION, NOT THE STRING: `round_note` is a multi-line assignment, so replacing its
# first line alone yields a file that does not parse — a mutant that fails for the wrong reason.
sed 's/\[ "\$rnd" -ge "\$BRIEF_GATE_COMPARABLE_ROUND" \]/[ "$rnd" -ge 999 ]/' "$GATE" > "$MUT3"
diff -q "$GATE" "$MUT3" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "MUTANT-B really removed the round>=4 emission (the sed anchor still matches)"
bash -n "$MUT3" && bash "$MUT3" --section reviewer 7 > "$TMP/sec-m3.txt" 2>/dev/null; ck $? "MUTANT-B still parses and renders a section"
bash "$MUT3" --check "$TMP/sec-m3.txt" reviewer 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "MUTATION-B: without the emission the round-7 canonical block is REFUSED by the round-7 validator — 'the gate cannot refuse its own advice' would report ❌ (rc=$rc)"

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
# ⛔ THE ANCHOR IS THE DECISION ITSELF, IN ITS CURRENT SHAPE (#3484 moved it from a one-line `||` to an
# `if`/`then` because the PREVIOUS WORK cross-check had to run on the SAME body — a `||` short-circuit
# would have returned before it). The `sed` still targets ONE line and the arm below asserts the file
# really changed, so a future refactor that moves it again reddens here instead of silently weakening §C.
sed 's/^  if \[ -z "\$miss" \]; then$/  if true; then  # MUTANT: always pass/' "$GATE" > "$MUT"
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
# ⛔ THE REFUSE-EVERYTHING MUTANT FLIPS THE CONDITION, IT DOES NOT SEED `miss` (#3484). Seeding `miss`
# before an `if true;` takes the EARLY-RETURN branch and returns 0 — the opposite of what this arm
# intends — so the arm would go green for the wrong reason. `if false;` skips the return and falls
# through to the refusal text with whatever `miss` holds, EMPTY included.
sed 's/^  if \[ -z "\$miss" \]; then$/  if false; then  # MUTANT: always refuse/' "$GATE" > "$TMP/mutant-refuse.sh"
bash "$TMP/mutant-refuse.sh" --check "$CANON" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "MUTATION (other direction): 'a complete brief passes' FAILS when the gate refuses everything (rc=$rc)"

echo
echo "§F the NON-VACUITY contract (#3442) — the reviewer brief must carry a mutation attribution"
# ── WHAT THIS SECTION PINS. A clean REVIEW was the one claim in the system nobody had to prove could
# fail, so five PRs in one night were reviewed clean over assertions that stay GREEN with the bug
# restored (docs/ops/review-non-vacuity-baseline.md). The gate now demands the block from the REVIEWER
# role, and `record-review.sh` calls the SAME parser on a review artifact, so these arms are the shape
# half of that contract. §G is the mutation proof that they can FAIL.
REV_CANON="$TMP/canonical-reviewer.txt"; bash "$GATE" --section reviewer > "$REV_CANON"
# The block is the LAST section of the canonical reviewer brief, so dropping from its heading to EOF
# yields a brief that is complete in every OTHER respect — the fixture that isolates this requirement.
sed '/^## MUTATION ATTRIBUTION/,$d' "$REV_CANON" > "$TMP/reviewer-no-mutation.txt"
grep -q '^CONTRADICTION TEST:' "$TMP/reviewer-no-mutation.txt"; ck $? "fixture: the reviewer brief WITHOUT the block is otherwise complete (research + contradiction test intact)"
bash "$GATE" --check "$TMP/reviewer-no-mutation.txt" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(i) a REVIEWER brief with NO mutation attribution is REFUSED with 80 (got $rc)"
bash "$GATE" --missing "$TMP/reviewer-no-mutation.txt" reviewer 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "…and the missing token NAMES the block (MUTATION-ATTRIBUTION)"
# ⛔ THE OTHER DIRECTION, and it is what keeps this from being a wall on every dispatch: the identical
# brief is a VALID brief for a non-reviewer role, so the requirement is scoped to the role that makes
# the claim — not to the file.
bash "$GATE" --check "$TMP/reviewer-no-mutation.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(ii) the SAME brief is still admitted for role 'lane' — the requirement belongs to the role, not the file (got $rc)"
bash "$GATE" --check "$REV_CANON" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(iii) the canonical reviewer brief PASSES (the gate cannot refuse its own advice) (got $rc)"
# …and the one-line disclosure a reviewer's lane log carries names it too, or an operator grepping the
# log sees the research contract and would not know the verdict half exists.
bash "$GATE" --line reviewer | grep -q '3442'; ck $? "(iv) the reviewer one-line disclosure names the non-vacuity contract"
bash "$GATE" --line lane | grep -q '3442'; rc=$?
[ "$rc" -ne 0 ]; ck $? "(iv-b) …and the LANE line does not (the block is not demanded of a lane brief)"
# ── the parser, on the four shapes the artifact side can actually be in.
printf '## MUTATION ATTRIBUTION\n\nI read the diff and it looks right.\n' > "$TMP/mut-prose.txt"
bash "$GATE" --mutation-missing "$TMP/mut-prose.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(v) a heading with prose and no table is REFUSED (a heading alone is not an attribution)"
printf '## MUTATION ATTRIBUTION\n\n| assertion | note | reddened row |\n|---|---|---|\n| a | b | c |\n' > "$TMP/mut-nocol.txt"
bash "$GATE" --mutation-missing "$TMP/mut-nocol.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(vi) a table whose header never names the MUTANT is REFUSED (the attribution key is the column, not the prose)"
# ⛔ EACH OF THE THREE COLUMN KEYS GETS ITS OWN FIXTURE (review cycle 4, P1 — VACUOUS ARM). This one
# used to omit BOTH `mutant` and `redden`, so deleting EITHER term of the header test was masked by
# the other: §G's §F(vi) mutant could not say which key it had removed. Each fixture below lacks
# EXACTLY ONE key and carries a real data row, so under the mutant that stops requiring that key the
# table is a COMPLETE attribution — and the arm goes RED, which is the only thing that makes it a test.
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant | what I checked |\n|---|---|---|\n| a | b | c |\n' > "$TMP/mut-noredden.txt"
bash "$GATE" --mutation-missing "$TMP/mut-noredden.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(vi-b) …and a table that never names the REDDENED ROW is REFUSED"
printf '## MUTATION ATTRIBUTION\n\n| note | mutant | reddened row |\n|---|---|---|\n| a | b | c |\n' > "$TMP/mut-noassertion.txt"
bash "$GATE" --mutation-missing "$TMP/mut-noassertion.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(vi-c) …and a table that never names the ASSERTION is REFUSED"
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row |\n|---|---|---|\n' > "$TMP/mut-norow.txt"
bash "$GATE" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(vii) a header with EVERY data row deleted is REFUSED (a header is not a kill)"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: docs-only — the diff touches docs/ops/*.md and adds no assertion.\n' > "$TMP/mut-none.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-none.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(viii) the NO NEW ASSERTIONS exemption is REACHABLE — a diff that adds no assertion is not deadlocked (got '$miss')"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS:\n' > "$TMP/mut-none-empty.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-empty.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(viii-b) …but a BARE 'NO NEW ASSERTIONS:' with no reason is REFUSED (an unexplained exemption is how the block becomes a rubber stamp)"
# ⛔ THE CARRIER THE RECORD PATH ACTUALLY USES: a GitHub comment body arrives @tsv-ESCAPED, so its
# newlines are the two characters `\n` and the whole artifact is ONE awk record. A line-oriented
# parser finds no heading there and would refuse EVERY honest review — the `13v1` arm in
# record-review.test.sh proves the same thing end-to-end; this pins the parser half where it lives.
printf '%s' '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: docs-only — the diff adds no assertion.\n' > "$TMP/mut-tsv.txt"
[ "$(grep -c '' "$TMP/mut-tsv.txt")" = "1" ]; ck $? "fixture: the escaped carrier really is ONE line (otherwise this arm proves nothing about @tsv)"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-tsv.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(ix) a ONE-LINE @tsv-escaped body is parsed (the review-artifact carrier; got '$miss')"
bash "$GATE" --mutation-missing "$TMP/does-not-exist-mut.txt" 2>/dev/null | grep -qx 'NO-FILE'; ck $? "(x) an UNREADABLE artifact is refused as NO-FILE, never admitted (fail-closed)"
# ── THE SHAPED-BUT-VACUOUS CARRIERS (fresh-context review of #3442, P1/P2). Each of these carries the
#    SHAPE of an attribution and NONE of its content — which is the exact vacuity the contract exists to
#    refuse, so each is a separate arm rather than a variant of (v)–(vii).
printf '## MUTATION ATTRIBUTION\n\n| assertion (file:line) | mutant | reddened row | observed |\n|---|---|---|---|\n' > "$TMP/mut-hdr-decorated.txt"
bash "$GATE" --mutation-missing "$TMP/mut-hdr-decorated.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(xi) a header whose FIRST CELL is DECORATED ('assertion (file:line)') with no data rows is REFUSED — the header is excluded by POSITION, not by matching its text"
printf '## MUTATION ATTRIBUTION\r\n\r\n| assertion | mutant | reddened row | observed |\r\n|---|---|---|---|\r\n' > "$TMP/mut-crlf.txt"
bash "$GATE" --mutation-missing "$TMP/mut-crlf.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(xii) …and that header-plus-rule table delivered over CRLF is REFUSED too (the trailing \\r made the RULE the data row)"
printf '## Review\n\nQuoting the shape:\n\n```\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| example | example | example | ok |\n```\n' > "$TMP/mut-fenced.txt"
bash "$GATE" --mutation-missing "$TMP/mut-fenced.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xiii) a block inside a TRIPLE-BACKTICK fence is QUOTED, not claimed — the artifact still carries no attribution"
printf '## MUTATION ATTRIBUTION\n\n| assertion (file:line) | mutant | reddened row | observed |\n|---|---|---|---|\n| a:1 | sed s/x/y/ | §A | ❌ rc=1 |\n' > "$TMP/mut-hdr-decorated-full.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xiv) POSITIVE CONTROL: a decorated header WITH a real data row is ADMITTED — the position rule excludes the header, never the table (got '$miss')"
# ── CYCLE 2: THE CARRIER THE RECORDER ACTUALLY FEEDS, AND THE TWO DIRECTIONS OF OVER-BLOCK. The
#    escape reversal runs here because `evidence_fetch` hands this program a `jq @tsv` body; a fix that
#    only handles a REAL CR/LF file fixes the fixture, not the path that mints records.
printf '## MUTATION ATTRIBUTION\\r\\n\\r\\n| assertion | mutant | reddened row | observed |\\r\\n|---|---|---|---|\\r\\n' > "$TMP/mut-tsv-crlf.txt"
[ "$(grep -c '' "$TMP/mut-tsv-crlf.txt")" = "1" ]; ck $? "fixture: the CRLF+@tsv carrier is ONE line of literal \\r\\n escapes (the shape jq @tsv emits)"
bash "$GATE" --mutation-missing "$TMP/mut-tsv-crlf.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(xv) the SAME header-plus-rule table through the @tsv carrier is REFUSED (an escaped \\r left unreversed made the RULE the data row)"
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row |\n|---|---|---|\n| a:1 | sed s/a\\nb// | §A |\n' > "$TMP/mut-literal-escape.txt"
grep -q 's/a\\nb//' "$TMP/mut-literal-escape.txt"; ck $? "fixture: a real multi-line artifact whose CELL contains a literal backslash-n (a newline-editing mutant)"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-literal-escape.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xvi) …is ADMITTED — un-escaping a REAL multi-line body splits that cell and REFUSES an honest row (got '$miss')"
printf '## Review\n\n~~~text\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| example | example | example | ok |\n~~~\n' > "$TMP/mut-tilde.txt"
bash "$GATE" --mutation-missing "$TMP/mut-tilde.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xvii) a QUOTE inside a tilde fence is quoted too — CommonMark has two fence characters, and the paste-back shape is the same"
printf '## MUTATION ATTRIBUTION\n\n    | assertion | mutant | reddened row | observed |\n    |---|---|---|---|\n    | example | example | example | ok |\n' > "$TMP/mut-indented.txt"
bash "$GATE" --mutation-missing "$TMP/mut-indented.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(xviii) …and a 4-SPACE INDENTED table under a real heading is an indented CODE BLOCK, not a data row — REFUSED, and the token names the COLUMN it therefore never supplied (a two-token match could not tell which guard fired)"
printf '  ## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| a | b | c | d |\n' > "$TMP/mut-indented-heading.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-indented-heading.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xix) a heading indented by 1–3 spaces is a HEADING (Markdown) and its table is ADMITTED — requiring column 0 would deadlock an honest verdict until it is reflowed (got '$miss')"
# ── CYCLE 3: THE SUMMARY TABLE ABOVE THE ATTRIBUTION, AND GFM'S OPTIONAL OUTER PIPES.
#    A "what I ran" table is the NORMAL shape of a review comment, and it sits ABOVE the attribution
#    table — so a row seen before the header must not survive into it.
printf '## MUTATION ATTRIBUTION\n\nWhat I ran:\n\n| suite | result | notes |\n|---|---|---|\n| brief-gate.test.sh | 183 pass, 1 known-fail | pre-existing |\n\nNow the attribution:\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n' > "$TMP/mut-table-before-header.txt"
bash "$GATE" --mutation-missing "$TMP/mut-table-before-header.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(xx) a SUMMARY table above the attribution does not donate a row to it — the attribution header with no rows of its own is REFUSED"
printf '## MUTATION ATTRIBUTION\n\nassertion | mutant | reddened row | observed\n---|---|---|---\n| x.sh:1 | sed s/a/b/ | §A | rc=1 |\n' > "$TMP/mut-no-outer-pipes.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-no-outer-pipes.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxi) a GFM table WITHOUT outer pipes is a table — the attribution is complete, and telling the reviewer its header lacks a column it has is a false block (got '$miss')"

# ── CYCLE 4: THE FIVE DEFECTS A FRESH-CONTEXT REVIEW OF THIS HEAD FOUND — four carrier holes and one
#    in the canonical block itself. EVERY one of these was ADMITTED by the cycle-3 parser, so each is
#    its own arm rather than a variant of (v)–(vii), and §G carries a mutant that reverts its fix.
printf '## MUTATION ATTRIBUTION\n\n**NO NEW ASSERTIONS:**\n' > "$TMP/mut-none-bold-empty.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-bold-empty.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(xxii) a DECORATED but EMPTY exemption (\`**NO NEW ASSERTIONS:**\`) is REFUSED — the closing emphasis is NOT a reason (fail-open: it minted a clean record with no attribution and no justification)"
printf '## MUTATION ATTRIBUTION\n\n*NO NEW ASSERTIONS: docs-only — no executable assertion.*\n' > "$TMP/mut-none-decorated.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-none-decorated.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxiii) …and the OTHER direction: an honest DECORATED exemption is ADMITTED — a one-sided strip refused it, which is a false block on the reviewer who decorated a label (got '$miss')"
printf '## MUTATION ATTRIBUTION\n\n> | assertion | mutant | reddened row |\n> |---|---|---|\n' > "$TMP/mut-blockquote.txt"
bash "$GATE" --mutation-missing "$TMP/mut-blockquote.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "(xxiv) a BLOCKQUOTED header-plus-rule table is REFUSED as ROWS — the '>' marker made the RULE non-all-separator, so the rule itself became the DATA row and a table with no attribution at all was admitted"
printf '## Review\n\n```\n~~~\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n```\n' > "$TMP/mut-tilde-in-fence.txt"
bash "$GATE" --mutation-missing "$TMP/mut-tilde-in-fence.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xxv) a \`~~~\` line INSIDE a triple-backtick block does NOT close it — a fence is closed only by its own character, so the paste-back it quotes stays quoted"
printf '## Review\n\n```\n    ```\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n```\n' > "$TMP/mut-indented-fence.txt"
bash "$GATE" --mutation-missing "$TMP/mut-indented-fence.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xxvi) …and a fence line INDENTED BY FOUR inside a fence does not close it either — an indented line is CODE, tested BEFORE the fence (otherwise it re-opened the live region)"
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened |\n|---|---|---|\n| `g.sh:120` the new assertion | `sed s/rc=80/rc=0/` (the mutant) | g.test.sh sec A (reddened) | rc=1 |\n' > "$TMP/mut-honest-wordy.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-honest-wordy.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxvii) a DATA row that happens to spell out all three column words is ADMITTED — ONE header per section, so a row can never reset the row set and refuse the row it was told to write (got '$miss')"
printf '## MUTATION ATTRIBUTION\n\nI read the diff.\n\n## What I ran\n\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n' > "$TMP/mut-section-close.txt"
bash "$GATE" --mutation-missing "$TMP/mut-section-close.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(xxviii) a heading at or above the section CLOSES it — an attribution table filed under a LATER heading is not this block's claim"
# ⛔ THE CANONICAL BLOCK MUST NOT EXEMPT ITSELF (review cycle 4, P1 — FAIL-OPEN, and the worst of the
# four because the HARNESS teaches it). A LIVE `NO NEW ASSERTIONS:` line inside the block made every
# artifact pasted from it admissible, so a reviewer who pasted the block and deleted the table minted a
# clean record on a code diff. It is an INDENTED code block now; this arm is what says so.
grep -v '^|' "$REV_CANON" > "$TMP/canonical-no-table.txt"
grep -q '^    NO NEW ASSERTIONS: docs-only' "$TMP/canonical-no-table.txt"; ck $? "fixture: the canonical exemption example survives the table strip (otherwise this arm proves nothing about the paste-back)"
bash "$GATE" --mutation-missing "$TMP/canonical-no-table.txt" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-INDENTED'; ck $? "(xxix) the CANONICAL block with its table DELETED is REFUSED — and the token NAMES the indented exemption, because that is what the artifact actually holds; telling its reviewer its TABLE HEADER is wrong sends it to look for a table it never wrote"
# ⛔ A CLOSING FENCE CARRIES NO INFO STRING (review cycle 5, P1 — FAIL-OPEN). Deriving the fence
# CHARACTER alone closed the block on an inner fenced command, so a log excerpt ending in one
# re-opened the live region and the paste-back it was quoting was ADMITTED.
printf '## Review\n\n```\nsome log\n```bash\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n```\n' > "$TMP/mut-infostring-fence.txt"
bash "$GATE" --mutation-missing "$TMP/mut-infostring-fence.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xxx) an inner fence line WITH AN INFO STRING (a fenced command inside the block) does not CLOSE it — a closing fence has none, so the quoted table stays quoted"
printf '## Review\n\n~~~\nlog\n~~~sh\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n~~~\n' > "$TMP/mut-infostring-tilde.txt"
bash "$GATE" --mutation-missing "$TMP/mut-infostring-tilde.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xxx-b) …and the same hole in the TILDE fence is closed too — one rule, both characters"
# ⛔ A PLACEHOLDER IS NOT A REASON (review cycle 5, P2). Every carrier that tells a reviewer about the
# exemption spells it `NO NEW ASSERTIONS: <why>`, so the literal slot is the text most likely pasted,
# and it minted a clean record on a code diff.
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: <why>\n' > "$TMP/mut-none-slot.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-slot.txt" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-PLACEHOLDER'; ck $? "(xxxi) an exemption whose only reason is the literal slot the harness itself prints is REFUSED, and the token NAMES the slot — the generic column token would send the reviewer to look for a table it never wrote"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: only docs/<file>.md is touched\n' > "$TMP/mut-none-angle.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-none-angle.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxxi-b) …and a real reason that merely CONTAINS angle brackets is still ADMITTED — only a reason that is nothing but ONE slot is refused (got '$miss')"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: "<why>"\n' > "$TMP/mut-none-quoted.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-quoted.txt" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-PLACEHOLDER'; ck $? "(xxxi-c) …and the QUOTED re-spelling of the slot is refused too — one layer of quotes comes off before the test, because a paste arrives quoted"
# ⛔ A TAB IS FOUR COLUMNS (review cycle 6, P1 — FAIL-OPEN). CommonMark expands a leading tab to the
# next 4-column stop, so a tab-indented exemption IS a code block to every renderer — but it is ONE
# character, so a four-CHARACTER test let the copied exemption go LIVE.
printf '## MUTATION ATTRIBUTION\n\n\tNO NEW ASSERTIONS: docs-only.\n' > "$TMP/mut-tab-exemption.txt"
bash "$GATE" --mutation-missing "$TMP/mut-tab-exemption.txt" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-INDENTED'; ck $? "(xxxii) a TAB-indented exemption is QUOTED like a four-space one — it is refused as an indented paste-back, not read as the claim"
# ⛔ INDENT IS COLUMNS, NOT CHARACTERS (final verification, P2 — FAIL-OPEN). A tab advances to the next
# 4-column stop, so `" \t"` and `"  \t"` are FOUR columns of indent — an indented code block to every
# renderer — while a character test saw two or three characters and let the copied exemption go LIVE.
# The miss set was non-monotonic (more indentation was caught, less was not), which is what a rule
# measuring the wrong thing looks like.
for _sp in ' \t' '  \t' '   \t' '\t\t' '\t   '; do
  printf '## MUTATION ATTRIBUTION\n\n%bNO NEW ASSERTIONS: docs-only.\n' "$_sp" > "$TMP/mut-tabstop.txt"
  bash "$GATE" --mutation-missing "$TMP/mut-tabstop.txt" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-INDENTED'; ck $? "(xxxv) a tab that reaches the 4-column stop is INDENTED CODE — refused as a paste-back (spacing: $(printf '%s' "$_sp" | cat -v))"
done
# ⛔ AND THE EMPTINESS TEST READS THE STRIPPED FORM (final verification, P2 — FAIL-OPEN). `\"\"` is an
# empty reason with a quoted pair around it, so `length(r)` saw two characters and minted a clean record.
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: ""\n' > "$TMP/mut-none-quoted-empty.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-quoted-empty.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(xxxvi) an EMPTY quoted reason is REFUSED — the quotes are decoration, not a reason"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: "   "\n' > "$TMP/mut-none-quoted-space.txt"
bash "$GATE" --mutation-missing "$TMP/mut-none-quoted-space.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "(xxxvi-b) …and a WHITESPACE-ONLY quoted reason is refused too (same defect, one more spelling)"
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: the reviewer wrote "no new assertions" elsewhere\n' > "$TMP/mut-none-quotes.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-none-quotes.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxxvi-c) …but a real reason that CONTAINS quotes is still admitted — the strip is one layer, not a ban (got '$miss')"
# ⛔ THE CLOSER IS MEASURED (review cycle 6, P1/P2). A closing fence carries no info string AND must be
# at least as long as the opener; the character alone expresses neither.
printf '## Review\n\n````markdown\nRun it:\n\n```bash\necho hi\n```\n\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n````\n' > "$TMP/mut-4tick-inner.txt"
bash "$GATE" --mutation-missing "$TMP/mut-4tick-inner.txt" 2>/dev/null | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "(xxxiii) a 4-TICK block quoting fenced markdown is NOT closed by the inner 3-tick run — a shorter run is content, so the whole quote stays quoted"
printf '## Review\n\n````markdown\n```bash\necho hi\n```\n`````\n\n## MUTATION ATTRIBUTION\n| assertion | mutant | reddened |\n|---|---|---|\n| a | b | c |\n' > "$TMP/mut-longer-closer.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/mut-longer-closer.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "(xxxiv) …and a LONGER closer (five ticks closing four) DOES close — CommonMark permits it, and refusing it told the reviewer it had no section that is plainly there (got '$miss')"

# ── §G THE MUTATION PROOF: each §F assertion above must be able to FAIL. Same discipline as §C — the
# mutant is derived FROM THE SHIPPED FILE so it tracks it, and the transformation is itself asserted.
echo
echo "§G NON-VACUITY of §F — removing the requirement makes §F's refusals pass, and the mutant is alive"
# ⛔ NO TRAILING COMMENT IN THE REPLACEMENT: `if false  # MUTANT…` swallows the `; then` that follows
# on the same line and yields a mutant that fails to PARSE — a mutation that fails for the wrong reason.
sed 's/if \[ "$role" = "reviewer" \]/if false/' "$GATE" > "$TMP/mutant-no-role.sh"
cmp -s "$GATE" "$TMP/mutant-no-role.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the role mutation REALLY changed the file (both role tests still match the anchor)"
# ⛔ NO PIPE: `grep -c` writes its count ONCE at EOF, but a `| grep -q` consumer exits on the
# first match — the SIGPIPE/#841 idiom, refused by `scripts/check-no-sigpipe-grep.sh` (this
# line was the `sigpipe-grep` red on PR #3481). Test the count directly instead.
[ "$(grep -c 'if false; then' "$TMP/mutant-no-role.sh" || true)" = "4" ]; ck $? "§G …and it replaced ALL FOUR role tests (two parse branches + the section render + the disclosure), which is the pre-#3442 behaviour: nothing asked"
bash -n "$TMP/mutant-no-role.sh"; ck $? "§G the mutant still parses — a program, not a syntax error"
bash "$TMP/mutant-no-role.sh" --check "$TMP/reviewer-no-mutation.txt" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "§G ⛔ MUTATION: §F(i) 'a reviewer brief with no attribution is REFUSED' now FAILS — the mutant admits it (rc=$rc)"
bash "$TMP/mutant-no-role.sh" --check "$REV_CANON" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "§G …and the control still passes, so the flip is the missing requirement and not a broken fixture (rc=$rc)"
# …and the OTHER direction on the PARSER half: a mutant that stops requiring the mutant COLUMN makes
# §F(vi) — the single most load-bearing arm, since a table with no mutant column is the shape a real
# reviewer writes when it believes prose is enough — pass.
sed 's|^  if (!hdr) {$|  if (0) {|' "$GATE" > "$TMP/mutant-no-column.sh"
cmp -s "$GATE" "$TMP/mutant-no-column.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the column mutation REALLY changed the file (the awk anchor still matches)"
bash -n "$TMP/mutant-no-column.sh"; ck $? "§G …and the column mutant still parses"
miss="$(bash "$TMP/mutant-no-column.sh" --mutation-missing "$TMP/mut-nocol.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(vi) 'a table whose header never names the mutant is REFUSED' now FAILS — the mutant admits it (got '$miss')"

# §F(xi)/(xii) — the header is excluded from `row` BY POSITION. The mutant drops that index, so the
# header counts as its own data row and a header-only table is admitted (measured: the decorated-header
# and CRLF fixtures both return EMPTY under it, which is §F(xi) and §F(xii) failing).
sed 's/i > hl) row = 1/1) row = 1  # MUTANT: a header may count as its own row/' "$GATE" > "$TMP/mutant-hdr-row.sh"
cmp -s "$GATE" "$TMP/mutant-hdr-row.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the header-position mutation REALLY changed the file (the awk anchor still matches)"
bash -n "$TMP/mutant-hdr-row.sh"; ck $? "§G …and the header-position mutant still parses"
for _f in mut-hdr-decorated mut-crlf; do
  miss="$(bash "$TMP/mutant-hdr-row.sh" --mutation-missing "$TMP/$_f.txt" 2>/dev/null)"
  [ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xi)/(xii) on '$_f' now FAILS — the mutant lets the HEADER be the row (got '$miss')"
done

# §F(xii)'s SECOND half — the trailing CR is what made the RULE the data row. The mutant keeps the
# position rule and drops the CR strip, so only the CRLF fixture is admitted: the arm is load-bearing
# for the strip, not merely a restatement of the position rule.
sed 's/; sub(\/\\r\$\/, "", line)//' "$GATE" > "$TMP/mutant-cr.sh"
cmp -s "$GATE" "$TMP/mutant-cr.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the CR-strip mutation REALLY changed the file (the awk anchor still matches)"
bash -n "$TMP/mutant-cr.sh"; ck $? "§G …and the CR-strip mutant still parses"
miss="$(bash "$TMP/mutant-cr.sh" --mutation-missing "$TMP/mut-crlf.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xii) now FAILS — without the strip the all-separator RULE is the data row (got '$miss')"
miss="$(bash "$TMP/mutant-cr.sh" --mutation-missing "$TMP/mut-hdr-decorated.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G …and the \\r-less fixture is STILL refused, so the strip is what the arm tests (got '$miss')"

# §F(xiii) — fenced material is quoted, never claimed. The mutant stops the fence from OPENING, so the
# quoted block is parsed as the artifact's own claim.
# ⛔ NO TRAILING COMMENT: the replacement sits mid-line (`else if (…)` follows it), so a `#` here
# would swallow the rest of the statement and yield a syntax error instead of a mutant.
sed 's|if (!fence) {|if (0) {|' "$GATE" > "$TMP/mutant-fence.sh"
cmp -s "$GATE" "$TMP/mutant-fence.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the fence mutation REALLY changed the file (the awk anchor still matches)"
bash -n "$TMP/mutant-fence.sh"; ck $? "§G …and the fence mutant still parses"
miss="$(bash "$TMP/mutant-fence.sh" --mutation-missing "$TMP/mut-fenced.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xiii) now FAILS — the mutant admits a paste-back of the worked example (got '$miss')"

# §F(xv) — the `\r` half of the escape reversal. Emptying that branch's body makes a `\r` fall
# through unchanged, which is the pre-fix behaviour on the @tsv carrier: the escaped CR survives as a
# cell, `|---|` stops being all-separator, and the RULE becomes the data row.
sed 's/if (nx == "r")  { out = out "\\r"; i++; continue }/if (nx == "r")  { }  # MUTANT: the escaped CR is not reversed/' "$GATE" > "$TMP/mutant-tsvcr.sh"
cmp -s "$GATE" "$TMP/mutant-tsvcr.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the escaped-CR mutation REALLY changed the file (the un-escape anchor still matches)"
bash -n "$TMP/mutant-tsvcr.sh"; ck $? "§G …and the escaped-CR mutant still parses"
miss="$(bash "$TMP/mutant-tsvcr.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the escaped-CR mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-tsvcr.sh" --mutation-missing "$TMP/mut-tsv-crlf.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xv) now FAILS — the @tsv carrier admits the vacuous table again (got '$miss')"

# §F(xvi) — the single-record DETECTION. Dropping it applies the reversal to real multi-line bodies
# too, which un-escapes a literal `\n` inside a cell and splits the row: an honest verdict refused.
sed 's/if (nraw == 1 || (nraw == 2 \&\& RAW\[2\] == "")) buf = _unescape(buf)/buf = _unescape(buf)  # MUTANT: un-escape unconditionally/' "$GATE" > "$TMP/mutant-uncond.sh"
cmp -s "$GATE" "$TMP/mutant-uncond.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the single-record mutation REALLY changed the file (the detection anchor still matches)"
bash -n "$TMP/mutant-uncond.sh"; ck $? "§G …and the single-record mutant still parses"
miss="$(bash "$TMP/mutant-uncond.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the single-record mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-uncond.sh" --mutation-missing "$TMP/mut-literal-escape.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xvi) now FAILS — the honest row is refused over a cell that merely mentions a newline edit (got '$miss')"

# §F(xvii) — the tilde fence. The mutant stops recognising `~~~`, so the quoted block parses as a
# claim. §F(xviii) has its own mutant because the indented block is a different markdown construct.
# ⛔ AND EVERY MUTANT BELOW IS PROVEN TO STILL *ANSWER*: a sed that fails to apply leaves an EMPTY
# program, which `bash -n` accepts and which admits everything — a false green this suite hit once.
sed 's@/^(```|~~~)/@/^(```)/@' "$GATE" > "$TMP/mutant-tilde.sh"
cmp -s "$GATE" "$TMP/mutant-tilde.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the tilde-fence mutation REALLY changed the file (the fence regex anchor still matches)"
bash -n "$TMP/mutant-tilde.sh"; ck $? "§G …and the tilde-fence mutant still parses"
miss="$(bash "$TMP/mutant-tilde.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the tilde-fence mutant still ANSWERS (a control is admitted, so it is a mutation and not a broken program; got '$miss')"
miss="$(bash "$TMP/mutant-tilde.sh" --mutation-missing "$TMP/mut-tilde.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xvii) now FAILS — the mutant admits a quoted block fenced with tildes (got '$miss')"

# §F(xviii) — the 4-space INDENTED block: same paste-back, no fence at all.
sed 's@if (icol >= 4) {@if (0) {@' "$GATE" > "$TMP/mutant-indent.sh"
cmp -s "$GATE" "$TMP/mutant-indent.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the indented-block mutation REALLY changed the file (the indent anchor still matches)"
bash -n "$TMP/mutant-indent.sh"; ck $? "§G …and the indented-block mutant still parses"
miss="$(bash "$TMP/mutant-indent.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the indented-block mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-indent.sh" --mutation-missing "$TMP/mut-indented.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xviii) now FAILS — the mutant reads the indented code block as a data row (got '$miss')"
# …and the SAME guard is what keeps a 4-space INDENTED FENCE from closing an open fence (§F(xxvi)),
# because the indent test runs BEFORE the fence test.
miss="$(bash "$TMP/mutant-indent.sh" --mutation-missing "$TMP/mut-indented-fence.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxvi) now FAILS too — an indented fence line closes the block and the quoted table is admitted (got '$miss')"

# §F(xix) — the heading indent allowance. Narrowing it back to column 0 refuses a Markdown-valid
# indented heading, which is the false block the allowance exists to remove.
sed 's@if (icol >= 4) {@if (icol >= 1) {@' "$GATE" > "$TMP/mutant-hindent.sh"
cmp -s "$GATE" "$TMP/mutant-hindent.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the heading-indent mutation REALLY changed the file (the indent-allowance anchor still matches)"
bash -n "$TMP/mutant-hindent.sh"; ck $? "§G …and the heading-indent mutant still parses"
miss="$(bash "$TMP/mutant-hindent.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the heading-indent mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-hindent.sh" --mutation-missing "$TMP/mut-indented-heading.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xix) now FAILS — a 2-space-indented heading is refused as if there were no block (got '$miss')"

# §F(xx) — the header RESETS the row. Without the reset a row from a summary table ABOVE the header
# survives into it, and a header-only attribution table is admitted.
sed 's/hdr = 1; hl = i; row = 0/hdr = 1; hl = i/' "$GATE" > "$TMP/mutant-noreset.sh"
cmp -s "$GATE" "$TMP/mutant-noreset.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the row-reset mutation REALLY changed the file (the header anchor still matches)"
bash -n "$TMP/mutant-noreset.sh"; ck $? "§G …and the row-reset mutant still parses"
miss="$(bash "$TMP/mutant-noreset.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the row-reset mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-noreset.sh" --mutation-missing "$TMP/mut-table-before-header.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xx) now FAILS — the summary row above the header is inherited, so the vacuous table is admitted (got '$miss')"

# §F(xxi) — outer pipes are OPTIONAL in GFM. Restoring the column-0 requirement refuses an honest
# table, which is the false block the widening removes.
sed 's@if (l ~ /.|/) {@if (l ~ /^\\|/) {@' "$GATE" > "$TMP/mutant-outerpipe.sh"
cmp -s "$GATE" "$TMP/mutant-outerpipe.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the outer-pipe mutation REALLY changed the file (the table-line anchor still matches)"
bash -n "$TMP/mutant-outerpipe.sh"; ck $? "§G …and the outer-pipe mutant still parses"
miss="$(bash "$TMP/mutant-outerpipe.sh" --mutation-missing "$TMP/mut-hdr-decorated-full.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and the outer-pipe mutant still ANSWERS (control admitted; got '$miss')"
miss="$(bash "$TMP/mutant-outerpipe.sh" --mutation-missing "$TMP/mut-no-outer-pipes.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxi) now FAILS — an honest pipe-less table is refused again (got '$miss')"

# ── THE ARMS THAT ONLY FALSIFY THE **OVER-BLOCK** DIRECTION, WHICH HAD NO MUTANT AT ALL (cycle-3
#    review, P2). §F(ii)/(iv-b) are the scoping half: making the reviewer requirement GLOBAL is the
#    plausible well-meaning defect, and it would deadlock every lane dispatch. §F(iii)/(viii)/(ix)/(x)
#    are the reachability half — a parser that refuses EVERYTHING passes every refusal arm in §F.
sed 's/if \[ "$role" = "reviewer" \]/if true/' "$GATE" > "$TMP/mutant-role-true.sh"
cmp -s "$GATE" "$TMP/mutant-role-true.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the over-block role mutation REALLY changed the file (both role tests still match the anchor)"
bash -n "$TMP/mutant-role-true.sh"; ck $? "§G …and the over-block mutant still parses"
bash "$TMP/mutant-role-true.sh" --check "$TMP/reviewer-no-mutation.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "§G ⛔ MUTATION: §F(ii) 'the SAME brief is still admitted for role lane' now FAILS — a global requirement refuses a lane brief (rc=$rc)"
bash "$TMP/mutant-role-true.sh" --line lane 2>/dev/null | grep -q '3442'; ck $? "§G ⛔ MUTATION: §F(iv-b) 'the LANE line does not name the block' now FAILS — the mutant's lane line demands it"

sed 's/if (none) exit/if (0) exit/' "$GATE" > "$TMP/mutant-none.sh"
cmp -s "$GATE" "$TMP/mutant-none.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the exemption mutation REALLY changed the file (the NO NEW ASSERTIONS anchor still matches)"
bash -n "$TMP/mutant-none.sh"; ck $? "§G …and the exemption mutant still parses"
bash "$TMP/mutant-none.sh" --mutation-missing "$TMP/mut-none.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "§G ⛔ MUTATION: §F(viii) 'NO NEW ASSERTIONS is REACHABLE' now FAILS — the mutant refuses the exemption"

sed 's/if (nx == "n")  { out = out ".n"; i++; continue }/if (nx == "n")  { }/' "$GATE" > "$TMP/mutant-nl.sh"
cmp -s "$GATE" "$TMP/mutant-nl.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the escaped-LF mutation REALLY changed the file (the un-escape anchor still matches)"
bash -n "$TMP/mutant-nl.sh"; ck $? "§G …and the escaped-LF mutant still parses"
bash "$TMP/mutant-nl.sh" --mutation-missing "$TMP/mut-tsv.txt" 2>/dev/null | grep -qx 'MUTATION-MUTANT-COLUMN'; ck $? "§G ⛔ MUTATION: §F(ix) 'a ONE-LINE @tsv body is parsed' now FAILS — without the LF reversal the escaped carrier has no heading"

sed 's/printf .NO-FILE.n./:/' "$GATE" > "$TMP/mutant-nofile.sh"
cmp -s "$GATE" "$TMP/mutant-nofile.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the NO-FILE mutation REALLY changed the file (the refusal anchors still match)"
bash -n "$TMP/mutant-nofile.sh"; ck $? "§G …and the NO-FILE mutant still parses"
miss="$(bash "$TMP/mutant-nofile.sh" --mutation-missing "$TMP/does-not-exist-mut.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(x) 'an UNREADABLE artifact is refused as NO-FILE' now FAILS — a missing file reads as clean (got '$miss')"

# ── CYCLE 4 — ONE MUTANT PER CARRIER FIX, each derived from the shipped file. A fix with no mutant is
#    the exact thing this PR exists to refuse: an assertion nobody ever tried to break.

# §F(xxii)/(xxiii) — the DECORATION strip. This mutant restores the PRE-FIX handling exactly (strip a
# leading `**`/`__` only, measure the reason without stripping), which is what made an empty exemption
# admit AND an honest decorated one refuse. Both directions must go red.
# ⛔ THE DELIMITER IS `@`, NOT `|`: the replacement contains a `|` (the awk alternation in
# `sub(/^(\*\*|__)/, …)`), which would terminate an `s|…|…|` command early — measured: sed reported
# `unknown option to 's'`, the mutation silently did NOT apply, and the arm below read the FLIP as a
# missing flip. That is the "a mutation that did not apply is a false green" trap, so the application
# is asserted on BOTH sides (the new call present, the old one gone).
sed -e 's@nn = _undress(l)@sub(/^(\\*\\*|__)/, "", l); nn = l@' \
    -e 's@r = _undress(r)@r = r@' \
    -e 's@_undress(rq)@rq@g' \
    "$GATE" > "$TMP/mutant-undress.sh"
cmp -s "$GATE" "$TMP/mutant-undress.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the decoration-strip mutation REALLY changed the file (both anchors still match)"
# ⛔ ASSERT THE EXECUTABLE FORMS, NOT THE WORD: `_undress` also appears in the function definition and
# in two comments, so a bare `grep -c _undress` can never reach zero and the assertion would be red on
# a perfectly good mutant. These three patterns are the CALL SITES.
[ "$(grep -c 'length(_undress(rq))' "$TMP/mutant-undress.sh" || true)" = "0" ] && [ "$(grep -c 'nn = _undress(l)' "$TMP/mutant-undress.sh" || true)" = "0" ] && [ "$(grep -c 'r = _undress(r)' "$TMP/mutant-undress.sh" || true)" = "0" ]; ck $? "§G …and EVERY strip call site was really replaced (the decoration rule has THREE now, because the emptiness test strips too — a two-site mutant would leave that guard standing and prove nothing)"
bash -n "$TMP/mutant-undress.sh"; ck $? "§G …and the decoration-strip mutant still parses"
bash "$TMP/mutant-undress.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the decoration-strip mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
miss="$(bash "$TMP/mutant-undress.sh" --mutation-missing "$TMP/mut-none-bold-empty.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxii) 'a DECORATED but EMPTY exemption is REFUSED' now FAILS — the mutant admits it (got '$miss')"
miss="$(bash "$TMP/mutant-undress.sh" --mutation-missing "$TMP/mut-none-decorated.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxiii) 'an honest DECORATED exemption is ADMITTED' now FAILS — the mutant refuses it (got '$miss')"

# §F(xxiv) — the BLOCKQUOTE strip. Without it the `>` marker is the first cell, the rule stops being
# all-separator, and the rule itself becomes the data row.
sed 's|while (bq) { bq = sub(/^\[ \\t\]\*>\[ \\t\]?/, "", l) }|while (0) { }|' "$GATE" > "$TMP/mutant-blockquote.sh"
cmp -s "$GATE" "$TMP/mutant-blockquote.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the blockquote-strip mutation REALLY changed the file (the strip anchor still matches)"
bash -n "$TMP/mutant-blockquote.sh"; ck $? "§G …and the blockquote-strip mutant still parses"
bash "$TMP/mutant-blockquote.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the blockquote-strip mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
bash "$TMP/mutant-blockquote.sh" --mutation-missing "$TMP/mut-blockquote.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G ⛔ MUTATION: §F(xxiv) 'a BLOCKQUOTED header-plus-rule table is REFUSED as ROWS' now FAILS — the marker defeats the all-separator check (got '$(bash "$TMP/mutant-blockquote.sh" --mutation-missing "$TMP/mut-blockquote.txt" 2>/dev/null)')"

# §F(xxv) — the FENCE CHARACTER. Back to one boolean, so a \`~~~\` line inside a \`\`\` block re-opens the
# live region and the paste-back it was quoting is ADMITTED.
sed 's|else if (fc == fencec|else if (1|' "$GATE" > "$TMP/mutant-fencechar.sh"
cmp -s "$GATE" "$TMP/mutant-fencechar.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the fence-character mutation REALLY changed the file (the fence-state anchor still matches)"
bash -n "$TMP/mutant-fencechar.sh"; ck $? "§G …and the fence-character mutant still parses"
bash "$TMP/mutant-fencechar.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the fence-character mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
miss="$(bash "$TMP/mutant-fencechar.sh" --mutation-missing "$TMP/mut-tilde-in-fence.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxv) now FAILS — a \`~~~\` inside a \`\`\` block closes it and the quoted table is admitted (got '$miss')"

# §F(xxvii) — the ONE-HEADER-PER-SECTION guard. Without `!hdr` any row whose cells spell out the three
# column words is a new header, so an honest single-row attribution is refused (the false block).
sed 's|if (!hdr && t ~ /mutant/|if (t ~ /mutant/|' "$GATE" > "$TMP/mutant-hdr-any.sh"
cmp -s "$GATE" "$TMP/mutant-hdr-any.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the one-header mutation REALLY changed the file (the header anchor still matches)"
bash -n "$TMP/mutant-hdr-any.sh"; ck $? "§G …and the one-header mutant still parses"
bash "$TMP/mutant-hdr-any.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the one-header mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
miss="$(bash "$TMP/mutant-hdr-any.sh" --mutation-missing "$TMP/mut-honest-wordy.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxvii) now FAILS — a data row that names the column words is read as a new header and the honest attribution is refused (got '$miss')"

# §F(xxviii) — the SECTION CLOSE. Pinned to the shipped rule and mutated in place, because a guard the
# PR itself documents but nothing breaks is exactly the invisibility this contract exists to end.
sed 's|if (ins && nh > 0 && nh <= depth) ins = 0|if (0) ins = 0|' "$GATE" > "$TMP/mutant-secclose.sh"
cmp -s "$GATE" "$TMP/mutant-secclose.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the section-close mutation REALLY changed the file (the close anchor still matches)"
bash -n "$TMP/mutant-secclose.sh"; ck $? "§G …and the section-close mutant still parses"
bash "$TMP/mutant-secclose.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the section-close mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
miss="$(bash "$TMP/mutant-secclose.sh" --mutation-missing "$TMP/mut-section-close.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxviii) now FAILS — the section never closes and a table under a later heading is credited to it (got '$miss')"

# §F(xxix) — the CANONICAL block cannot exempt itself. The mutant de-indents the worked 'NO NEW
# ASSERTIONS' line, making it a LIVE claim again: the paste-back hole this fix closes.
sed 's|^    NO NEW ASSERTIONS: docs-only|NO NEW ASSERTIONS: docs-only|' "$GATE" > "$TMP/mutant-canonlive.sh"
cmp -s "$GATE" "$TMP/mutant-canonlive.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the canonical-exemption mutation REALLY changed the file (the indented example anchor still matches)"
bash -n "$TMP/mutant-canonlive.sh"; ck $? "§G …and the canonical-exemption mutant still parses"
bash "$TMP/mutant-canonlive.sh" --section reviewer > "$TMP/canon-live.txt" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ]; ck $? "§G …and it still RENDERS the reviewer brief (rc=$rc) — a mutation, not a broken program"
grep -v '^|' "$TMP/canon-live.txt" > "$TMP/canon-live-notable.txt"
miss="$(bash "$TMP/mutant-canonlive.sh" --mutation-missing "$TMP/canon-live-notable.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxix) now FAILS — the canonical block's LIVE exemption admits the artifact with its table deleted (got '$miss')"

# §F(vi)/(vi-b)/(vi-c) — EACH column key, mutated on its OWN. Before cycle 4 one fixture omitted two
# keys at once, so deleting any single term of the header test stayed green; these three arms are what
# make a one-key deletion a RED.
# ⛔ EVERY `&&` IN A SED *REPLACEMENT* MUST BE `\&\&`: a bare `&` stands for the WHOLE MATCH, so an
# unescaped one silently splices the matched text into the mutant and yields a program that ERRORS at
# runtime — empty stdout, which reads as "admitted" and turned three of these arms into false greens
# until the refusal control below caught it.
for _spec in \
  'mutant|if (!hdr \&\& t ~ /assertion/ \&\& t ~ /redden/)|mut-nocol|no-MUTANT' \
  'redden|if (!hdr \&\& t ~ /mutant/ \&\& t ~ /assertion/)|mut-noredden|no-REDDENED-ROW' \
  'assertion|if (!hdr \&\& t ~ /mutant/ \&\& t ~ /redden/)|mut-noassertion|no-ASSERTION'; do
  _term="${_spec%%|*}"; _rest="${_spec#*|}"
  _repl="${_rest%%|*}"; _rest="${_rest#*|}"
  _fixt="${_rest%%|*}"; _label="${_rest#*|}"
  sed "s|if (!hdr && t ~ /mutant/ && t ~ /assertion/ && t ~ /redden/)|${_repl}|" \
    "$GATE" > "$TMP/mutant-col-$_term.sh"
  cmp -s "$GATE" "$TMP/mutant-col-$_term.sh"; rc=$?
  [ "$rc" -ne 0 ]; ck $? "§G the '$_label' column mutation REALLY changed the file (the header anchor still matches)"
  bash -n "$TMP/mutant-col-$_term.sh"; ck $? "§G …and the '$_label' mutant still parses"
bash "$TMP/mutant-col-$_term.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the '$_label' mutant still REFUSES a header-only table — a REFUSAL control, because an EMPTY program admits everything and would satisfy an ADMISSION control (the false green this suite already hit once)"
  miss="$(bash "$TMP/mutant-col-$_term.sh" --mutation-missing "$TMP/$_fixt.txt" 2>/dev/null)"
  [ -z "$miss" ]; ck $? "§G ⛔ MUTATION: the §F arm for '$_label' now FAILS — the mutant treats the key $_term as optional and admits the incomplete table (got '$miss')"
done

# §F(xxx) — the CLOSING FENCE has no info string. Dropping that clause closes the block on an inner
# fenced command and admits the paste-back it was quoting.
sed 's|rest ~ /^|rest !~ /^|' "$GATE" > "$TMP/mutant-fenceinfo.sh"
cmp -s "$GATE" "$TMP/mutant-fenceinfo.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the fence-info mutation REALLY changed the file (the close-clause anchor still matches)"
bash -n "$TMP/mutant-fenceinfo.sh"; ck $? "§G …and the fence-info mutant still parses"
bash "$TMP/mutant-fenceinfo.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the fence-info mutant still REFUSES a header-only table (a refusal control, so an empty program cannot pass as a mutation)"
miss="$(bash "$TMP/mutant-fenceinfo.sh" --mutation-missing "$TMP/mut-infostring-fence.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxx) now FAILS — an inner fenced command closes the block and the quoted table is admitted (got '$miss')"
miss="$(bash "$TMP/mutant-fenceinfo.sh" --mutation-missing "$TMP/mut-infostring-tilde.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxx-b) now FAILS too — the same clause protects BOTH fence characters, so one mutant kills both arms and neither is unguarded"

# §F(xxxii) — a TAB is four columns. Dropping the tab alternative from the indent test lets the copied
# exemption go live, which is the fail-open this arm exists for.
# §F(xxxii)/(xxxv) — INDENT IS COLUMNS. Two mutants, because the rule has two halves: counting a tab
# as ONE column lets `" \t"` through, and treating a tab as zero would refuse an honest exemption.
sed 's@for (tw = 4 - (col % 4); tw > 0; tw--)@for (tw = 1; tw > 0; tw--)@' "$GATE" > "$TMP/mutant-tab.sh"
cmp -s "$GATE" "$TMP/mutant-tab.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the tab-stop mutation REALLY changed the file (the expansion-loop anchor still matches)"
bash -n "$TMP/mutant-tab.sh"; ck $? "§G …and the tab-stop mutant still parses"
bash "$TMP/mutant-tab.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the tab-stop mutant still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-tab.sh" --mutation-missing "$TMP/mut-tab-exemption.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxii) now FAILS — a tab counts as ONE column, so the copied exemption goes live (got '$miss')"
sed 's@if (c == "\\t") {@if (c == "\\t" \&\& 0) {@' "$GATE" > "$TMP/mutant-tabzero.sh"
cmp -s "$GATE" "$TMP/mutant-tabzero.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the tab-ignored mutation REALLY changed the file (the tab-branch anchor still matches)"
bash -n "$TMP/mutant-tabzero.sh"; ck $? "§G …and the tab-ignored mutant still parses"
bash "$TMP/mutant-tabzero.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the tab-ignored mutant still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-tabzero.sh" --mutation-missing "$TMP/mut-tab-exemption.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxii)/(xxxv) now FAIL — a tab contributes no columns, so tab-indented code is read as the live claim (got '$miss')"

# §F(xxxiii)/(xxxiv) — the measured closer. Two clauses, two mutants: dropping the LENGTH test lets a
# shorter inner run close the block, and requiring EQUALITY refuses a legal longer closer.
sed 's@fc == fencec && flen >= fencelen && rest@fc == fencec \&\& rest@' "$GATE" > "$TMP/mutant-fenlen.sh"
cmp -s "$GATE" "$TMP/mutant-fenlen.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the fence-length mutation REALLY changed the file (the close-clause anchor still matches)"
bash -n "$TMP/mutant-fenlen.sh"; ck $? "§G …and the fence-length mutant still parses"
bash "$TMP/mutant-fenlen.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the fence-length mutant still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-fenlen.sh" --mutation-missing "$TMP/mut-4tick-inner.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxiii) now FAILS — the inner 3-tick run closes a 4-tick block and the quoted table is admitted (got '$miss')"
sed 's@flen >= fencelen@flen == fencelen@' "$GATE" > "$TMP/mutant-fenlen-eq.sh"
cmp -s "$GATE" "$TMP/mutant-fenlen-eq.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the fence-length-equality mutation REALLY changed the file (the comparison anchor still matches)"
bash -n "$TMP/mutant-fenlen-eq.sh"; ck $? "§G …and the fence-length-equality mutant still parses"
bash "$TMP/mutant-fenlen-eq.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and it still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-fenlen-eq.sh" --mutation-missing "$TMP/mut-longer-closer.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxiv) now FAILS — a legal LONGER closer is refused and the artifact is told it has no section (got '$miss')"

# §F(xxxi-b) — the over-refusal direction. Inverting the slot test to reject ANY angle bracket must red
# the arm that says a real reason with angle brackets is still admitted.
# ⛔ `\&\&` IN THE REPLACEMENT: a bare `&` splices the whole match in, and the resulting program dies
# at runtime — empty stdout, which reads as "admitted". The refusal control on the next line is what
# makes that visible instead of a silent false green.
sed 's@if (length(_undress(rq)) > 0 && rq !~ /^<@if (0 \&\& rq !~ /^<@' "$GATE" > "$TMP/mutant-slotwide.sh"
cmp -s "$GATE" "$TMP/mutant-slotwide.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the wide-slot mutation REALLY changed the file (the slot-test anchor still matches)"
bash -n "$TMP/mutant-slotwide.sh"; ck $? "§G …and the wide-slot mutant still parses"
bash "$TMP/mutant-slotwide.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the wide-slot mutant still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-slotwide.sh" --mutation-missing "$TMP/mut-none-angle.txt" 2>/dev/null)"
[ -n "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxi-b) now FAILS — an over-refusing parser rejects an honest reason that mentions a path (got '$miss')"

# §F(xxxvi) — the reason is measured AFTER the quote strip. Reverting to the pre-strip length mints a
# clean record over `NO NEW ASSERTIONS: ""`, which is an exemption with no reason at all.
sed 's@if (length(_undress(rq)) > 0 && rq !~ /^<@if (length(r) > 0 \&\& rq !~ /^<@' "$GATE" > "$TMP/mutant-emptystrip.sh"
cmp -s "$GATE" "$TMP/mutant-emptystrip.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the pre-strip-emptiness mutation REALLY changed the file (the emptiness anchor still matches)"
bash -n "$TMP/mutant-emptystrip.sh"; ck $? "§G …and the pre-strip-emptiness mutant still parses"
bash "$TMP/mutant-emptystrip.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and it still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-emptystrip.sh" --mutation-missing "$TMP/mut-none-quoted-empty.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxvi) now FAILS — the quote pair makes an EMPTY reason look non-empty (got '$miss')"

# §F(xxxi) — a PLACEHOLDER is not a reason. Dropping the slot test mints a clean record over the
# literal `NO NEW ASSERTIONS: <why>` every carrier tells a reviewer to write.
sed 's|rq !~ /^<|rq !~ /^QQ|' "$GATE" > "$TMP/mutant-slot.sh"
cmp -s "$GATE" "$TMP/mutant-slot.sh"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§G the placeholder mutation REALLY changed the file (the slot-test anchor still matches)"
bash -n "$TMP/mutant-slot.sh"; ck $? "§G …and the placeholder mutant still parses"
bash "$TMP/mutant-slot.sh" --mutation-missing "$TMP/mut-norow.txt" 2>/dev/null | grep -qx 'MUTATION-ROWS'; ck $? "§G …and the placeholder mutant still REFUSES a header-only table (refusal control)"
miss="$(bash "$TMP/mutant-slot.sh" --mutation-missing "$TMP/mut-none-slot.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G ⛔ MUTATION: §F(xxxi) now FAILS — the literal slot is admitted as an exemption (got '$miss')"
miss="$(bash "$TMP/mutant-slot.sh" --mutation-missing "$TMP/mut-none-angle.txt" 2>/dev/null)"
[ -z "$miss" ]; ck $? "§G …and it still ADMITS a real reason with angle brackets, so the arm tests the SLOT rule and not the characters (got '$miss')"

echo
echo "§H the PREVIOUS WORK contract (#3484) — a brief must say what is already there, and a claim of absence is CHECKED"
# ── WHAT THIS SECTION PINS. Two mechanisms that make a reaped claim safe existed and were both
# VOLUNTARY: `lane-wip.py` ("did the lane stop mid-WIP, and WHAT is the WIP?") and `bg-rescue-wip.sh`
# (archives uncommitted work to `refs/wip/*` on origin). Measured 2026-11-05: 222 rescued archives
# existed and NOTHING told the next actor to look — `claims.sh` and `claim-reaper.sh` mentioned WIP
# zero times, and one session produced three branches for a single issue. So the brief must carry the
# measurement, and a `WIP:` line that names NO ref is a claim of absence that this gate CHECKS.
#
# ⛔ THE REMOTE IS A REAL LOCAL BARE REPO, so `refs/wip/*` is read by the shipped `git ls-remote` —
# nothing below mocks the git layer, and no ref ever leaves this machine.
HW="$TMP/pw"; mkdir -p "$HW"
git init -q --bare "$HW/origin.git" 2>/dev/null
git init -q "$HW/work" 2>/dev/null
git -C "$HW/work" remote add origin "$HW/origin.git" 2>/dev/null
PW_EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
mk_wip() { # mk_wip <refname>
  local sha
  sha="$(git -C "$HW/work" -c user.name=pw -c user.email=pw@localhost commit-tree "$PW_EMPTY_TREE" -m "wip: fixture $1" 2>/dev/null)"
  [ -n "$sha" ] || { echo "fixture: cannot build a wip commit"; return 1; }
  git -C "$HW/work" push -q origin "$sha:refs/wip/$1" 2>/dev/null
}
mk_wip "issue-4242-first-attempt" && mk_wip "fix-4243-other-work" && mk_wip "ai-fork-headroom"
ck $? "§H fixture: the fixture remote carries refs/wip/* (3 real refs, one with no issue number at all)"
PW_REFS="$(bash "$GATE" --wip-refs 4242 "$HW/work" 2>/dev/null)"
grep -q 'refs/wip/issue-4242-first-attempt' <<<"$PW_REFS"; ck $? "(H1) --wip-refs FINDS the ref for its issue (the verb claim-reaper.sh and claims.sh consume)"
grep -q 'refs/wip/fix-4243-other-work' <<<"$PW_REFS"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H2) …and does NOT match a ref belonging to another issue (the matcher discriminates, it is not a firehose)"
grep -q 'refs/wip/ai-fork-headroom' <<<"$(bash "$GATE" --wip-refs 4243 "$HW/work" 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H3) …and a ref with no issue token in it matches NO issue — which is why bg-rescue-wip.sh now says so out loud"
[ -z "$(bash "$GATE" --wip-refs 99999 "$HW/work" 2>/dev/null)" ]; ck $? "(H4) an issue with no ref answers EMPTY and exits 0 (empty is an answer; unreadable is 2)"
bash "$GATE" --wip-refs 99999 "$TMP/no-such-repo" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; ck $? "(H5) …and an EXPLICIT repository that is not one is 2 (UNMEASURED) — no silent fallback to another tree (got $rc)"

# ── the shape: five labelled facts, and the absent block is REFUSED.
sed '/^## PREVIOUS WORK/,$d' "$CANON" > "$TMP/no-pw.txt"
grep -q '^CONTRADICTION TEST:' "$TMP/no-pw.txt"; ck $? "§H fixture: the no-PW brief is otherwise COMPLETE (research + contradiction test intact)"
bash "$GATE" --missing "$TMP/no-pw.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-SECTION'; ck $? "(H6) a brief with NO PREVIOUS WORK section names the block as missing"
bash "$GATE" --check "$TMP/no-pw.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H7) …and is REFUSED with 80, not admitted (got $rc)"
sed '/^PRIOR:/d' "$CANON" > "$TMP/pw-no-prior.txt"
bash "$GATE" --missing "$TMP/pw-no-prior.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-PRIOR'; ck $? "(H8) a block missing ONE label names that label (PRIOR), not the whole block"
bash "$GATE" --check "$TMP/pw-no-prior.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H9) …and is refused (got $rc)"
# ⛔ EVERY FIXTURE BELOW IS DERIVED WITH `sed … "$CANON"` — the FILE — not with a pipe from the
# variable. `printf '%s\n' "$CANON" | sed …` prints the PATH, so the fixture becomes a one-line file
# holding a filename, and every arm below would then be asserting "a brief with no research section"
# while claiming to test the WIP line — the vacuous-fixture failure this suite exists to catch.
sed 's/^WIP:.*/WIP:       none, nothing to see/' "$CANON" > "$TMP/pw-unkeyed.txt"
grep -qx 'WIP:       none, nothing to see' "$TMP/pw-unkeyed.txt"; ck $? "§H fixture: the unkeyed brief really carries the unkeyed WIP line"
bash "$GATE" --missing "$TMP/pw-unkeyed.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-WIP'; ck $? "(H10) an UNKEYED WIP value ('none, nothing to see') is refused — it names no issue to check"

# ── the CONTRADICTION: a keyed absence claim against a ref that exists.
sed 's|^WIP:.*|WIP:       issue-4242 -> none (measured: git ls-remote refs/wip/* at 2026-11-06T00:00Z)|' "$CANON" > "$TMP/pw-contradicted.txt"
grep -qF 'refs/wip/*' "$TMP/pw-contradicted.txt"; ck $? "§H fixture: the absence claim carries a MEASUREMENT NOTE naming refs/wip/* — a note must not be mistaken for a named ref"
bash "$GATE" --check "$TMP/pw-contradicted.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H11) a brief claiming 'no WIP for issue 4242' while refs/wip holds one is REFUSED (got $rc)"
PW_OUT="$(bash "$GATE" --check "$TMP/pw-contradicted.txt" lane 0 "$HW/work" 2>&1)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$PW_OUT"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H12) …the refusal does not print the raw token at the author (it is translated)"
grep -q 'refs/wip/issue-4242-first-attempt' <<<"$PW_OUT"; ck $? "(H13) …it NAMES the ref that contradicts the claim (a refusal that names nothing sends the author to grep)"
grep -q 'CONTINUE that work' <<<"$PW_OUT"; ck $? "(H14) …and says what to do about it, which is the whole point of the handover"
# …and the SAME brief passes on stdin: two passes read the brief, so a second `-` reader at EOF would
# silently see no WIP line and the cross-check would be INERT on pane orders (the inline carrier).
bash "$GATE" --check - lane 0 "$HW/work" < "$TMP/pw-contradicted.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H15) the same contradiction is caught through STDIN (both passes read one materialised body) (got $rc)"
# …and naming ANY ref satisfies the shape: the gate checks the CONTRADICTION, not whether the ref is
# the right one — that judgement is the next actor's, and pretending otherwise would manufacture it.
sed 's|^WIP:.*|WIP:       issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-named.txt"
bash "$GATE" --check "$TMP/pw-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H16) a brief that NAMES the rescued ref is ADMITTED — the block is a handover, not a wall (got $rc)"
# ── the STATED RESIDUAL, ASSERTED SO IT CANNOT BE MISTAKEN FOR A PASS: an unmeasurable refs/wip ADMITS
# the brief and says so. The alternative — refusing every dispatch on a network blip — converts a
# memory gap into a fleet-wide outage, and the claim pre-flight already hard-depends on origin.
# ⛔ THE FIXTURE MUST FAIL THE MEASUREMENT. A repo with a reachable `origin` and no `refs/wip/*` is a
# SUCCESSFUL read that answers "none" (rc 0) — the ordinary case, not the residual. Only a repository
# whose `ls-remote` cannot answer (no `origin` at all, or an unreachable one) exercises this arm.
git init -q "$HW/noremote" 2>/dev/null
PW_OUT="$(bash "$GATE" --check "$TMP/pw-contradicted.txt" lane 0 "$HW/noremote" 2>&1)"; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H17) an UNREADABLE refs/wip ADMITS the brief (documented residual) (got $rc)"
grep -q 'UNVERIFIED' <<<"$PW_OUT"; ck $? "(H18) …and says the absence claim is UNVERIFIED on stderr, so the pass is never silent"
# ── QUOTED MATERIAL IS NOT A CLAIM (fresh-context review of #3484, P1) ──────────────────────────
# The first cut's WIP reader took the LAST `WIP:` label anywhere in the section with no fence or indent
# awareness, so pasting the canonical block as a REFERENCE both satisfied the shape and switched the
# cross-check off: `issue-<N> -> refs/wip/<ref>` inside a fence read as the author's own claim. Measured
# before the fix: a brief claiming `issue-4242 -> none` was refused (80) alone, and ADMITTED (0) once a
# fenced copy of the block was pasted after it. Two arms, one per carrier of the paste.
{ sed 's|^PRIOR:.*|PRIOR: no previous attempt|' "$TMP/pw-contradicted.txt"
  printf '\nReference (the shape the harness hands you):\n\n```\nWIP:       issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111\n```\n'; } > "$TMP/pw-fenced-after.txt"
grep -q 'issue-4242 -> none' "$TMP/pw-fenced-after.txt"; ck $? "§H fixture: the LIVE claim is still the absence claim (the fenced copy comes after it)"
bash "$GATE" --check "$TMP/pw-fenced-after.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H19) a FENCED quotation of a ref does not switch the cross-check off — the live absence claim is still REFUSED (got $rc)"
{ printf '# a brief\n\n```\n'
  sed -n '/^## PREVIOUS WORK/,/^PRIOR:/p' "$CANON"
  printf '```\n'; } > "$TMP/pw-only-fenced.txt"
bash "$GATE" --missing "$TMP/pw-only-fenced.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-SECTION'; ck $? "(H20) a PREVIOUS WORK block that exists ONLY inside a fence is QUOTED, not claimed — the section is still missing"
# …and the four-column carrier, which is the same quote in CommonMark's other spelling.
awk '{ print "    " $0 }' "$TMP/pw-contradicted.txt" > "$TMP/pw-indented.txt"
bash "$GATE" --missing "$TMP/pw-indented.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-SECTION'; ck $? "(H21) …and an INDENTED copy (a code block) is quoted too, so the whole brief is refused as having no section"
# ── THE DIAGNOSTIC VERB MUST AGREE WITH THE GATE (fresh-context review of #3484, P2). `--missing` is
# what an author iterates with; reading stdin twice made it report "complete, rc=0" for a brief `--check`
# refuses on the SAME bytes.
miss="$(bash "$GATE" --missing - lane 0 "$HW/work" < "$TMP/pw-contradicted.txt" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; ck $? "(H22) --missing on STDIN sees the SAME body --check does (no second EOF reader)"
bash "$GATE" --check - lane 0 "$HW/work" < "$TMP/pw-contradicted.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H23) …and --check on the same bytes refuses it, so (xiv) is not a green over a broken pipe (got $rc)"
# ── CYCLE-2 P1: EVERY `WIP:` VALUE IS CHECKED, NOT THE LAST ONE (fresh-context review of #3484) ──
# The shape check accepted ANY keyed `WIP:` line while the cross-check measured only the LAST one, so
# each carrier below satisfied the shape and made the checker abstain on a line that was never the
# claim. Measured before the fix, all with a live `issue-4242 -> none` against an EXISTING ref:
#   E a pasted canonical block (a live, unfenced `issue-<N> -> refs/wip/<ref>` line — the text this
#     gate itself hands the author), F a trailing `WIP: none`, G a bare `WIP:`, H a keyed line for a
#     DIFFERENT issue, N `pr-<N>` on a lane. Each was ADMITTED (rc=0); each must now be REFUSED.
cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-canon.txt"; sed -n '/^## PREVIOUS WORK/,$p' "$CANON" >> "$TMP/pwplus-canon.txt"
bash "$GATE" --check "$TMP/pwplus-canon.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H24) a pasted canonical block after a live absence claim does NOT switch the check off (got $rc)"
{ cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-none.txt"; printf '\nWIP:       none\n'; } >> "$TMP/pwplus-none.txt" 2>/dev/null || { cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-none.txt"; printf '\nWIP:       none\n' >> "$TMP/pwplus-none.txt"; }
bash "$GATE" --check "$TMP/pwplus-none.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H25) a trailing UNKEYED 'WIP: none' does not exempt the keyed claim above it (got $rc)"
# ⛔ (H25b) ASSERTS THE TOKEN, NOT JUST rc (review of #3621, P2 — VERIFIED by reproduction). rc alone is
# 80 EITHER WAY: with last-wins restored the contradicting-ref token VANISHES while rc stays 80, because
# the trailing unkeyed `none` is refused on its OWN account. So an rc-only arm DESCRIBED this carrier and
# could not fail — a revert of the every-value reader re-opened the fail-open with (H25) still green.
# Measured both ways: shipped token=1, last-wins token=0, rc=80 in both.
miss="$(bash "$GATE" --missing "$TMP/pwplus-none.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; ck $? "(H25b) …and the CONTRADICTED token is what refuses it — rc alone is 80 under last-wins too"
{ cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-bare.txt"; printf '\nWIP:\n' >> "$TMP/pwplus-bare.txt"; }
bash "$GATE" --check "$TMP/pwplus-bare.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H26) a BARE 'WIP:' label does not exempt it either (got $rc)"
{ cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-other.txt"; printf '\nWIP:       issue-4243 -> refs/wip/fix-4243-other @ 111111111111\n' >> "$TMP/pwplus-other.txt"; }
bash "$GATE" --check "$TMP/pwplus-other.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H27) a keyed ref for a DIFFERENT issue does not exempt the claim about this one (got $rc)"
# ⛔ THE ROLE-SCOPING ARM NEEDS A BRIEF THAT IS OTHERWISE CLEAN, or it measures the absence claim it
# inherited instead of the key rule (measured: built from the contradicted fixture it was 80 for the
# FIXER too, for the unrelated reason).
{ cat "$CANON"; printf '\nWIP:       pr-1 -> none\n'; } > "$TMP/pwplus-pr.txt"
bash "$GATE" --check "$TMP/pwplus-pr.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H28) 'pr-<N>' is NOT a lane/worker key — it is the fixer's and the reviewer's (got $rc)"
bash "$GATE" --check "$TMP/pwplus-pr.txt" fixer 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H29) …and for a FIXER it is the right key, so the rule is role-scoped and not a blanket ban (got $rc)"
# ⛔ THE REVIEWER FIXTURE MUST BE THE REVIEWER SECTION (`--section reviewer`): the same file tested as
# `reviewer` is ALSO refused for the missing MUTATION ATTRIBUTION block, which would make this arm
# measure the wrong contract (it did, at 80, until the fixture was role-shaped).
{ bash "$GATE" --section reviewer; printf '\nWIP:       pr-1 -> none\n'; } > "$TMP/pwplus-pr-rev.txt"
bash "$GATE" --check "$TMP/pwplus-pr-rev.txt" reviewer 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H30) …and for a REVIEWER too (it reviews one PR at a head) (got $rc)"
# ── THE INDENT RULE'S BEHAVIOUR, ON A LIVE BRIEF (review cycle 2, P2; corrected in review of #3621).
# ⛔ THESE TWO ARMS ARE CONTROLS, NOT MUTANT-KILLERS: their fixture inherits a LIVE absence claim that
# refuses on its own, so they stay at 80 with the indent logic deleted (measured). They assert the
# RULE's behaviour (an indented late line does not change the verdict); the arms that actually redden
# under `sed 's/^  line = _qskip($0)/  line = $0/'` are H36/H37 below, whose base is a CLEAN claim.
{ cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-ind.txt"; printf '\n    WIP:       issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111\n' >> "$TMP/pwplus-ind.txt"; }
bash "$GATE" --check "$TMP/pwplus-ind.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H31) a 4-COLUMN INDENTED late WIP line is a code block, so the live absence claim still decides (got $rc)"
{ cp "$TMP/pw-contradicted.txt" "$TMP/pwplus-tab.txt"; printf '\n\tWIP:       issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111\n' >> "$TMP/pwplus-tab.txt"; }
bash "$GATE" --check "$TMP/pwplus-tab.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H32) …and the TAB spelling of the same indent (a 4-column stop) too (got $rc)"

# ── CYCLE-3 P1: ONE RECOGNIZER — the shape check called `WIP-:` the `wip` LABEL (`_label` folds
# `[ \t-]+` into a space) while the reader required `^wip[ \t]*:`, so the reader collected NOTHING, the
# cross-check abstained, and a claim of absence went UNCHECKED (measured: rc 0 against an existing ref).
sed 's|^WIP:.*|WIP-:      issue-4242 -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-dashlabel.txt"
grep -q '^WIP-:' "$TMP/pw-dashlabel.txt"; ck $? "§H fixture: the WIP line really carries the dashed label spelling"
bash "$GATE" --check "$TMP/pw-dashlabel.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H33) a DASHED label ('WIP-:') is still the wip label — its absence claim is CHECKED, not skipped (got $rc)"
sed 's|^WIP:.*|WIP --:    issue-4242 -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-dashlabel2.txt"
bash "$GATE" --check "$TMP/pw-dashlabel2.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H34) …and 'WIP --:' too (one recogniser, every separator the label class folds) (got $rc)"
# …and the mirror: an honest NAMED ref under the same spelling is ADMITTED, so the fix is not a blanket
# refusal keyed on the spelling.
sed 's|^WIP:.*|WIP-:      issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-dashlabel-named.txt"
bash "$GATE" --check "$TMP/pw-dashlabel-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H35) …while a NAMED ref under the same spelling is admitted (no false block) (got $rc)"

# ── CYCLE-3 P2: THE QUOTE-SKIP NEEDS A FIXTURE IT CAN ACTUALLY CHANGE. The earlier arms inherited a
# live absence claim that refuses on its own, so they were green with `_qskip` deleted. This one's live
# claim is for an issue with NO ref (admitted), and the ONLY thing that can refuse it is a QUOTED
# `WIP: none` being read as a claim — which is exactly what the indent rule prevents.
sed 's|^WIP:.*|WIP:       issue-99999 -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-clean.txt"
bash "$GATE" --check "$TMP/pw-clean.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "§H control: a clean absence claim for an issue with no ref is ADMITTED (got $rc)"
{ cat "$TMP/pw-clean.txt"; printf '\n    WIP:       none\n'; } > "$TMP/pw-clean-ind.txt"
bash "$GATE" --check "$TMP/pw-clean-ind.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H36) a 4-COLUMN INDENTED 'WIP: none' is a code block and does NOT become a live unkeyed claim — deleting \`_qskip\` reddens THIS arm (got $rc)"
{ cat "$TMP/pw-clean.txt"; printf '\n\tWIP:       none\n'; } > "$TMP/pw-clean-tab.txt"
bash "$GATE" --check "$TMP/pw-clean-tab.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H37) …and the TAB spelling of the same indent (got $rc)"


# ── A GLOB IS NOT A REF (review of #3621, P2) ─────────────────────────────────────────────────────────
# `refs/wip/* is empty` begins with `refs/wip/`, so it was read as "a ref is named" and the check was
# SWITCHED OFF by the most honest possible statement of having looked. Measured rc 0 with a matching
# ref on origin, on the merged baseline too.
sed 's|^WIP:.*|WIP:       issue-4242 -> refs/wip/* is empty (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-glob.txt"
bash "$GATE" --check "$TMP/pw-glob.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H48) a GLOB claim ('refs/wip/* is empty') is a claim of ABSENCE and is CHECKED (got $rc)"
sed 's|^WIP:.*|WIP:       issue-4242 -> refs/wip/ — nothing there (measured)|' "$CANON" > "$TMP/pw-barewip.txt"
bash "$GATE" --check "$TMP/pw-barewip.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H49) …and so is \`refs/wip/\` with no token after it (got $rc)"
bash "$GATE" --check "$TMP/pw-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H50) …while a CONCRETE ref still satisfies it (no over-block; got $rc)"
# ── `keyless — <why>` HAD NO ARM AT ALL (review of #3621, P2): the branch that decides it is a single
# unasserted point whose deletion false-blocks the honest diagnosis-lane form the canonical block hands
# out. Two rows: the form is ADMITTED, and deleting the branch REFUSES it.
sed 's|^WIP:.*|WIP:       keyless — a diagnosis lane with no issue or PR key|' "$CANON" > "$TMP/pw-keyless.txt"
bash "$GATE" --check "$TMP/pw-keyless.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H51) a keyless diagnosis-lane brief is ADMITTED (the third documented form) (got $rc)"
sed 's|^WIP:.*|WIP:       keyless|' "$CANON" > "$TMP/pw-keyless-bare.txt"
bash "$GATE" --check "$TMP/pw-keyless-bare.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H51b) …but a bare 'keyless' with no reason is not (got $rc)"
# ⛔ THE SEPARATOR IS ANY WHITESPACE, NOT JUST A SPACE (cycle 12 review, P2; the citation corrected in
# cycle 13 — this comment first credited "the shape parser" with a test that no longer exists at this
# head). On `origin/main` the only key test WAS the shape parser `_rest ~ /^keyless[ \t]+[^ \t]/`, which
# is whitespace-general; `1519642ff` deleted that test and made the classifier the sole authority, and the
# arm it introduced required a literal SPACE — so the move narrowed a spelling the base accepted. Measured
# on byte-identical briefs: `origin/main` rc 0, the cycle-11 head rc 80 (UNKEYED, a diagnostic about the
# key, for the documented third form). H51c is the row, and it discriminates on its own — it fails against
# the cycle-11 head.
# ⛔ H51d IS THE PARITY ROW, AND ITS CARRIER MATTERS — two findings, in two cycles, and the row is
# only correct because BOTH were applied: the cycle-13 review found this row VACUOUS (its finding 2: the
# space/tab carrier collapses under the trim and re-asserted H51b, so it discriminated nothing and was
# deleted), and the cycle-14 delta review found the remedy wrong (its finding 1, P2: CR, VT and FF
# SURVIVE that trim and do arrive at the arm as whitespace-only). What the row still has to assert: a
# separator followed by WHITESPACE ONLY is refused, so the "reason" must contain a non-whitespace
# character. The carrier has to be a byte the value reader's trailing trim KEEPS — that trim is `[ \t]+`
# (brief-gate.sh:341), so a space/tab-only value collapses to bare `keyless` and re-asserts H51b (the first
# version of this row did exactly that and was vacuous). CR survives the trim and arrives at the arm as
# whitespace-only, so the mutant `[[:space:]]*[![:space:]]*` → `[[:space:]]*` is killed by THIS row
# (`keyless<CR>` 80 → 0) while the bare-`keyless` row alone cannot kill it (80 → 80, measured).
sed "s|^WIP:.*|WIP:       keyless$(printf '\t')— a diagnosis lane with no issue or PR key|" "$CANON" > "$TMP/pw-keyless-tab.txt"
bash "$GATE" --check "$TMP/pw-keyless-tab.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H51c) …and a TAB is a separator too — the base admitted this spelling (got $rc)"
awk -v r="keyless$(printf '\r')" '{ if ($0 ~ /^WIP:/) printf "WIP:       %s\n", r; else print }' "$CANON" > "$TMP/pw-keyless-cr.txt"
bash "$GATE" --check "$TMP/pw-keyless-cr.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H51d) …while a separator + WHITESPACE ONLY is still refused (CR carrier: the trim keeps it) (got $rc)"
MUT_PW4="$TMP/mutant-pw-nokeyless.sh"
sed 's|^      keyless\*)$|      keyless-NEVER*)|' "$GATE" > "$MUT_PW4"
diff -q "$GATE" "$MUT_PW4" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H52) the KEYLESS-BRANCH mutation really changed the file"
bash "$MUT_PW4" --check "$TMP/pw-keyless.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H52b) MUTATION: H51 now FAILS — with the keyless branch deleted the honest form is refused (rc=$rc)"
# ── the KEY is case-folded like the label (review of #3621, nit): `Issue-4242 -> none` was refused.
# ⛔ THE ARM MUST NAME WHICH 80 IT IS (review of #3621, cycle 2, P2). Asserting rc alone was satisfied by
# the UNFIXED gate for a different reason (the key read as unkeyed), so it could not fail. The TOKEN is
# the discriminator, plus the named-ref direction, which the unfixed gate rejects as unkeyed.
sed 's|^WIP:.*|WIP:       Issue-4242 -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-case.txt"
miss="$(bash "$GATE" --missing "$TMP/pw-case.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; ck $? "(H53) a case-folded key ('Issue-4242') is the SAME key — it is looked up, and its contradiction is what refuses it"
sed 's|^WIP:.*|WIP:       Issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-case-named.txt"
bash "$GATE" --check "$TMP/pw-case-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H53b) …so an honest NAMED ref under the folded key is ADMITTED, not refused as unkeyed (got $rc)"
# ── A NUMBER IN BRACKETS IS STILL A NUMBER (review of #3621, cycle 2, P2): `issue-<4242> -> none` was
# keyed-but-UNCHECKED — the doc's "carries a REAL issue number" fail-open, reachable with two brackets —
# and `pr-<1>` bypassed the role rule the same way.
sed 's|^WIP:.*|WIP:       issue-<4242> -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-slotnum.txt"
bash "$GATE" --check "$TMP/pw-slotnum.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H55) 'issue-<4242> -> none' is CHECKED — a bracketed number is still a number (got $rc)"
sed 's|^WIP:.*|WIP:       issue-<4242> -> refs/wip/* is empty (measured)|' "$CANON" > "$TMP/pw-slotglob.txt"
bash "$GATE" --check "$TMP/pw-slotglob.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H55b) …and the bracketed form cannot smuggle a GLOB claim past H48 either (got $rc)"
{ cat "$CANON"; printf '\nWIP:       pr-<1> -> none\n'; } > "$TMP/pw-slotpr.txt"
bash "$GATE" --check "$TMP/pw-slotpr.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H55c) …and 'pr-<1>' does not bypass the role rule on a lane (got $rc)"
# ⛔ THE REFUSAL DIRECTION IS NOT ENOUGH (review of #3621, cycle 3, P3): a misfix that treated the
# bracketed number as UNKEYED would keep H55/H55b/H55c green while falsely refusing the honest form.
# These are the mirror rows, including the BRACKET NAMED-REF path that the optional arrow protects.
sed 's|^WIP:.*|WIP:       issue-<4242> -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-slot-named.txt"
bash "$GATE" --check "$TMP/pw-slot-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H55d) a bracketed key with a NAMED ref is ADMITTED (got $rc)"
# ⛔ THE FIXTURE MUST BE ROLE-SHAPED: testing the LANE section as `reviewer` is ALSO refused for the
# missing MUTATION ATTRIBUTION block, which would measure the wrong contract (it did, at 80).
for r in fixer reviewer; do
  { bash "$GATE" --section "$r"; printf '\nWIP:       pr-<1> -> none\n'; } > "$TMP/pw-slotpr-$r.txt"
  bash "$GATE" --check "$TMP/pw-slotpr-$r.txt" "$r" 0 "$HW/work" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "(H55e[$r]) …while 'pr-<1>' IS the right key for a $r (the role rule, not a blanket ban) (got $rc)"
done
# ── ANY SPELLING OF A BRACKETED NUMBER IS STILL A NUMBER (review of #3621, cycle 3, P2): requiring a
# digit immediately after `<` left `issue-<#4242>`, `issue-< 4242>`, `issue-<issue-4242>` UNCHECKED — and
# `issue #4242` is the natural way to write it.
for spell in 'issue-<#4242>' 'issue-< 4242>' 'issue-<issue-4242>' 'issue-<+4242>'; do
  sed "s|^WIP:.*|WIP:       $spell -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|" "$CANON" > "$TMP/pw-spell.txt"
  bash "$GATE" --check "$TMP/pw-spell.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 80 ]; ck $? "(H57['$spell']) a bracketed number in ANY spelling is CHECKED (got $rc)"
done
sed 's|^WIP:.*|WIP:       issue-<#4242> -> refs/wip/* is empty (measured)|' "$CANON" > "$TMP/pw-spellglob.txt"
bash "$GATE" --check "$TMP/pw-spellglob.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H57b) …and it cannot smuggle the GLOB claim past H48 either (got $rc)"
# ⛔ A REFUSAL-ONLY ARM IS NOT ENOUGH FOR A WIDENED SPELLING (review of #3621, cycle 4, P3): a misfix that
# marked `<#…>`/`<+…>` UNKEYED keeps every refusal row green while falsely refusing the honest form. One
# admitted-direction row per spelling kills that mutant.
for spell in 'issue-<#4242>' 'issue-< 4242>' 'issue-<issue-4242>' 'issue-<+4242>'; do
  sed "s|^WIP:.*|WIP:       $spell -> refs/wip/issue-4242-first-attempt @ 111111111111|" "$CANON" > "$TMP/pw-spell-named.txt"
  bash "$GATE" --check "$TMP/pw-spell-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "(H57c['$spell']) …and the honest NAMED form under that spelling is ADMITTED (no false block) (got $rc)"
done
# ── THE FIRST DIGIT RUN, NOT EVERY DIGIT (review of #3621, cycle 4, P1). Concatenating the runs measured
# a key that does not exist (`42421234`) and ADMITTED the claim it should refuse.
for v in 'issue-<#4242 (prev attempt #1234)>' 'issue-<4242, 5555>' 'issue-<4242 attempt 2>'; do
  sed "s|^WIP:.*|WIP:       $v -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|" "$CANON" > "$TMP/pw-firstrun.txt"
  miss="$(bash "$GATE" --missing "$TMP/pw-firstrun.txt" lane 0 "$HW/work" 2>/dev/null)"
  grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; rc=$?
  [ "$rc" -eq 0 ]; ck $? "(H59['$v']) the FIRST digit run is the key — a second number in the bracket does not move it (token asserted, not just rc)"
done
# ── AN UNTERMINATED BRACKET IS STILL KEYED AND STILL CHECKED (review of #3621, cycle 4, P2): dropping the
# closing `>` used to fall through to the unfilled-slot arm and go UNCHECKED.
# ⛔ AND THE ARM MUST NAME WHICH 80 IT IS (review of #3621, cycle 5, P3): rc alone cannot tell "checked and
# contradicted" from "never checked" — deleting the whole arm still yields 80 through the unkeyed branch.
# The token is the discriminator.
sed 's|^WIP:.*|WIP:       issue-<4242 - none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-unterm.txt"
miss="$(bash "$GATE" --missing "$TMP/pw-unterm.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; ck $? "(H60) an UNTERMINATED bracket ('issue-<4242 - none') is still KEYED and MEASURED (the token proves the lookup, rc alone would not)"
grep -qx 'PREVIOUS-WORK-WIP' <<<"$miss"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H60b) …and it is not refused as merely UNKEYED — the number was read, not discarded"
# ⛔ THE SLOT SENTINEL IS NOT A PREFIX (review of #3621, cycle 5, P3): `issue-slot*` matched `issue-slot4242`,
# an author-spellable route to the unchecked arm WITH a number in it. Both of these measured rc 0 there.
# ⛔ A BRACKET WITH NO DIGITS IS THE SLOT (documented), so the escapes tested here are the ones that DO
# carry a number in the key part: a prefix collision, and a number glued after the closing bracket.
for v in 'issue-slot4242' 'issue-<4242>4242>' 'issue-<x4242>'; do
  sed "s|^WIP:.*|WIP:       $v -> none (measured: git ls-remote refs/wip/* at 2026-11-06)|" "$CANON" > "$TMP/pw-slotescape.txt"
  bash "$GATE" --check "$TMP/pw-slotescape.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 80 ]; ck $? "(H61['$v']) a slot-LOOKING spelling carrying a number cannot reach the unchecked arm (got $rc)"
done
# ── `WIP_:` IS NOT A `wip` LABEL TO THE SHAPE PARSER (`_label` folds only space/hyphen), and the reader
# no longer collects it either: ONE verdict, fail-closed, from both readers. The READER half is only
# observable in the TOKEN set, so this is an absence fixture and the assertion is on the tokens — `rc`
# alone cannot tell the two worlds apart (the shape parser refuses either way).
sed 's|^WIP:.*|WIP_:      issue-4242 -> none (measured)|' "$CANON" > "$TMP/pw-under-absence.txt"
miss="$(bash "$GATE" --missing "$TMP/pw-under-absence.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -qx 'PREVIOUS-WORK-WIP' <<<"$miss"; ck $? "(H58) 'WIP_:' is not a wip label — the brief is refused for having no WIP line"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H58b) …and the reader did NOT collect it either — no CONTRADICTED token, so the two readers agree (a reader that collected it would add one)"
sed 's|^WIP:.*|WIP_:      issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-under.txt"
bash "$GATE" --check "$TMP/pw-under.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H58c) …so the named form is refused too, and for the same reason (got $rc)"
# ── A TAB SEPARATOR IS NOT A `wip` LABEL TO EITHER READER (review of #3621 cycle 2, P2). `_label`'s
# label class is `[A-Za-z][A-Za-z0-9 _-]`, so `WIP<TAB>:` matches NO label — the SHAPE parser refuses
# the brief for having no `WIP:` line. This gets the same three-way treatment (H58) gives `WIP_:`
# because the guarantee here is the label CLASS: `_label` folds `[ \t-]+` only AFTER it matches, so
# teaching it to span `\t` without extending this reader's `[ -]*` would satisfy the shape and leave the
# reader silent — an ADMITTED absence claim, the #3484 fail-open. The last arm is the CONTROL that makes
# (H63c) mean something: the SAME brief with a colon is admitted, so a TAB refusal is the label class and
# not "it named a ref". `tab` is a literal TAB built by printf, because a `\t` in a sed REPLACEMENT is a
# GNU extension and this suite runs on BSD sed (the cycle-3 portability defect).
tab="$(printf '\t')"
sed "s|^WIP:.*|WIP${tab}:      issue-4242 -> none (measured)|" "$CANON" > "$TMP/pw-tab-absence.txt"
miss="$(bash "$GATE" --missing "$TMP/pw-tab-absence.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -qx 'PREVIOUS-WORK-WIP' <<<"$miss"; ck $? "(H63) 'WIP<TAB>:' is not a wip label — the brief is refused for having no WIP line"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H63b) …and the reader did not collect it either — no CONTRADICTED token, so the two readers agree (a reader that spanned TAB would add one)"
sed "s|^WIP:.*|WIP${tab}:      issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|" "$CANON" > "$TMP/pw-tab-named.txt"
bash "$GATE" --check "$TMP/pw-tab-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H63c) …and the NAMED form is refused for the same reason, not for naming a ref (got $rc)"
sed 's|^WIP:.*|WIP:      issue-4242 -> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-colon-named.txt"
bash "$GATE" --check "$TMP/pw-colon-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H63d) CONTROL: the same brief with a COLON label is ADMITTED — so (H63c) is the label class, not the named ref (got $rc)"

# ── THE TWO COPIES OF THE QUOTING HELPERS MUST STAY BYTE-IDENTICAL (review of #3621, P3). They are
# duplicated because the two awk programs are separate single-quoted strings by design (#3442's reason:
# wrapping two contracts in one END block is how a change to one re-opens the other). That is safe only
# while the bodies are equal — unequal copies is exactly how the cycle-3 recognizer divergence happened.
extract_fn() { # <n> <function-name> — the n-th `function <name>(…){…}` block of the gate
  awk -v want="$1" -v fn="$2" 'BEGIN{n=0;f=0}
    index($0, "function " fn "(") == 1 {n++; f=(n==want); if (f) print; next}
    f && /^\}/{print; f=0; next}
    f {print}' "$GATE"
}
for fn in _qskip _fence; do
  diff <(extract_fn 1 "$fn") <(extract_fn 2 "$fn") >/dev/null 2>&1; ck $? "(H54) the two copies of $fn are IDENTICAL (a divergence is the cycle-3 defect class)"
  [ "$(extract_fn 1 "$fn" | grep -c '')" -gt 2 ]; ck $? "(H54b) …$fn: the extract is not empty (an empty pair would make 'identical' vacuous)"
  [ "$(extract_fn 1 "$fn" | grep -c "function $fn")" = "1" ] && [ "$(extract_fn 2 "$fn" | grep -c "function $fn")" = "1" ]; ck $? "(H54c) …$fn: both copies were really found (a missing second copy cannot pass as equal)"
done
# ── `--missing` MUST NOT ANSWER CANNOT-VERIFY WITH STATUS 0 (review of #3621, cycle 2, P3): with an
# unusable TMPDIR it printed GATE-UNAVAILABLE and returned 0, so a consumer's `if ! --missing` read a
# cannot-verify as SUCCESS. `--check` already answered 78 for the same condition.
out="$(TMPDIR=/nonexistent-brief-gate-$$ bash "$GATE" --missing - lane 0 "$HW/work" < "$TMP/pw-clean.txt" 2>/dev/null)"; rc=$?
grep -q 'GATE-UNAVAILABLE' <<<"$out"; ck $? "(H56) an unusable TMPDIR answers GATE-UNAVAILABLE from --missing"
[ "$rc" -eq 78 ]; ck $? "(H56b) …with status 78 (cannot verify), never 0 (got $rc)"

# ── THE ARROW IS NOT REQUIRED FOR A BRACKET KEY (review of #3621, cycle 8, P2): `issue-<4242>
# refs/wip/issue-4242-first-attempt` (no arrow) was refused with "read the ref you already named",
# because the claim was derived from the text after the ARROW and there was none. The claim now follows
# the BRACKET CLOSE, so both spellings agree.
sed 's|^WIP:.*|WIP:       issue-<4242> refs/wip/issue-4242-first-attempt @ 111111111111|' "$CANON" > "$TMP/pw-noarrow-named.txt"
bash "$GATE" --check "$TMP/pw-noarrow-named.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H62) a bracket key with NO ARROW that NAMES its ref is ADMITTED — the claim follows the bracket, not the arrow (got $rc)"
sed 's|^WIP:.*|WIP:       issue-<4242> none (measured: git ls-remote refs/wip/* at 2026-11-06)|' "$CANON" > "$TMP/pw-noarrow-none.txt"
miss="$(bash "$GATE" --missing "$TMP/pw-noarrow-none.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss"; ck $? "(H62b) …while the same shape claiming ABSENCE is measured and contradicted (the mirror, so H62 is not a free pass)"

# ── NON-VACUITY: remove the check and the arms above go green.
MUT_PW="$TMP/mutant-pw.sh"
# ⛔ THE ANCHOR TRACKS THE CALL SITE (review cycle 2): the reader now takes the ROLE too, and an anchor
# that stops matching makes the "mutant" byte-identical to the real file — the arm that proves the check
# is load-bearing then passes for the wrong reason. The diff assertion below is what catches that.
sed 's|^  pw="\$(brief_gate_previous_work "\$f" "\$repo" "\$role")"$|  pw=""  # MUTANT: no cross-check|' "$GATE" > "$MUT_PW"
diff -q "$GATE" "$MUT_PW" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H38) the cross-check mutation REALLY changed the file (its anchor still matches)"
bash -n "$MUT_PW"; ck $? "(H39) …and the mutant still parses"
bash "$MUT_PW" --check "$TMP/pw-contradicted.txt" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H40) MUTATION: (v) now FAILS — with the cross-check removed the contradicted brief is admitted (rc=$rc)"
bash "$MUT_PW" --check "$TMP/no-pw.txt" lane >/dev/null 2>&1; rc=$?
[ "$rc" -eq 80 ]; ck $? "(H41) …and the SHAPE refusal is untouched by that mutant, so (ii) was not green because of it (rc=$rc)"
# ⛔ THE EVERY-VALUE READER NEEDS ITS OWN MUTANT (review cycle 3, P2). `pw=""` deletes the whole check,
# which proves nothing about WHICH values are read. This revert restores "the last WIP line wins" — the
# exact shape cycle 2 found — and the carriers that must notice are named one by one.
MUT_PW3="$TMP/mutant-pw-lastwins.sh"
# ⛔ TWO ANCHORS, BOTH PROVEN (review of #3621, P2). The second `sed` expression below spells the source
# `\n` as `\n`, which GNU sed reads as a NEWLINE \u2014 the pattern then matched nothing, so the "last-wins"
# mutant left the every-value printer in place, `_n` was never incremented, the reader emitted NOTHING,
# and H42 was green over a mutant that deletes the reader rather than one that restores last-wins. The
# two anchors are now asserted SEPARATELY, by grepping the mutant for the text each one writes.
# ⛔ THE PRINTER ANCHOR IS MATCHED ON ITS STABLE PREFIX, not on the `\t`/`\n` literals: spelling those in
# a sed PATTERN is where the first attempt went inert (a BRE `\n` is a newline, so the pattern matched
# nothing and the mutant silently kept the every-value loop). `.` for the escapes, and the replacement
# writes the two characters back with `\\t`.
sed -e 's|^    _v\[++_n\] = t$|    val = t|' \
    -e 's|^END { for (_i = 1.*$|END { if (length(val) > 0) print "V\\t" val }|' \
    "$GATE" > "$MUT_PW3"
grep -qx '    val = t' "$MUT_PW3"; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H42) the LAST-WINS mutation replaced the COLLECTOR anchor (the file really changed there)"
grep -q 'if (length(val) > 0) print "V' "$MUT_PW3"; rc=$?
[ "$rc" -eq 0 ]; ck $? "(H42a) …and the PRINTER anchor too — an inert expression leaves the every-value loop in place and the mutant then proves nothing"
grep -q '_v\[++_n\] = t' "$MUT_PW3"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H42b) …and the old collector is GONE (a mutant that kept it would not be last-wins either)"
bash -n "$MUT_PW3"; ck $? "(H43) …and it still parses"
# ⛔ NOT EVERY CARRIER FLIPS UNDER THIS MUTANT, and asserting one that cannot would be its own
# vacuous arm — so each carrier is named by what it ACTUALLY does, MEASURED. (Review of #3621, P2: the
# first version of this comment mis-cited both arms it named — (H5) is the `--wip-refs` explicit-repo
# arm and has NO `WIP:` line at all (:868), and (H16) is the named-ref arm, which is ADMITTED with a
# single `WIP:` line and therefore has no trailing line — while (H25), the carrier it described, was not
# named at all.)
# ⛔ FLIP — the mutant ADMITS them, so `rc -eq 0` below is the claim: (H24) a pasted canonical block,
# (H27) a keyed line for another issue, and (H26) a BARE `WIP:`, whose last value is EMPTY, so last-wins
# collects nothing and the key check has nothing to refuse.
# ⛔ DO NOT FLIP ON rc — (H25) a trailing UNKEYED `WIP: none`. Last-wins collects the value `none` off an
# unkeyed line, which is refused on its OWN account, so rc stays 80 while the contradicting-ref token
# DISAPPEARS. Its discriminator is therefore the TOKEN, asserted by (H25b) and by (H44b) below; an
# rc-only assertion cannot fail here and is exactly the non-discriminating shape this suite forbids.
for pair in "pwplus-canon.txt:H24" "pwplus-other.txt:H27" "pwplus-bare.txt:H26"; do
  f="${pair%%:*}"; lab="${pair#*:}"
  bash "$MUT_PW3" --check "$TMP/$f" lane 0 "$HW/work" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "(H44) MUTATION: ${lab} now FAILS — with last-wins restored that brief is ADMITTED (rc=$rc)"
done
# (H44b) THE TOKEN-GONE HALF: for the carrier that does NOT flip rc, the token IS the discriminator —
# under last-wins the contradicted ref is never inspected, so it vanishes. This is what makes (H25b)
# non-vacuous WITHOUT relying on rc, which cannot move here.
miss3="$(bash "$MUT_PW3" --missing "$TMP/pwplus-none.txt" lane 0 "$HW/work" 2>/dev/null)"
grep -q 'PREVIOUS-WORK-WIP-CONTRADICTED' <<<"$miss3"; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H44b) MUTATION: (H25b) now FAILS — with last-wins restored the contradicting-ref token is GONE (rc stays 80, so only the token can catch this)"
MUT_PW2="$TMP/mutant-pw2.sh"
sed 's|^  if (!pwsec) print "PREVIOUS-WORK-SECTION"$|  # MUTANT: no section token|' "$GATE" > "$MUT_PW2"
diff -q "$GATE" "$MUT_PW2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H45) the section-token mutation really changed the file"
# ⛔ THIS MUTANT REMOVES ONE TOKEN, AND THE ARM SAYS EXACTLY THAT. The five LABEL tokens still refuse a
# brief with no block at all, so asserting "the brief is admitted" would be false; asserting the token
# is gone is the claim §H(ii) actually rests on.
bash "$MUT_PW2" --missing "$TMP/no-pw.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-SECTION'; rc=$?
[ "$rc" -ne 0 ]; ck $? "(H46) MUTATION: (ii) now FAILS — with the token line deleted, no-PW is no longer named as PREVIOUS-WORK-SECTION"
bash "$MUT_PW2" --missing "$TMP/no-pw.txt" 2>/dev/null | grep -qx 'PREVIOUS-WORK-CLAIM'; ck $? "(H47) …and the FIVE LABEL tokens still refuse the same brief, so (x-b) removed a token and not the contract"

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
# ⛔ AND $AGENT_INFRA_PATH (measured on a developer box, 2026-10-28: rc=0 started=1 — the arm's whole
# claim is that the search cannot reach a real installed copy, and `brief_gate_lib` consults
# `$AGENT_INFRA_PATH/scripts/orchestrator-harness/brief-gate.sh` as its THIRD home, which an isolated
# HOME does not cover. `env -u` is what clears it here, and it is the same isolation the arm claims.)
# ⛔ AND THE MEMORY FLOOR IS NEUTRALISED (`MEM_MIN_AVAIL_MB=1`), for the reason the disk and load
# confounders are: this arm is about the BRIEF gate's cannot-verify path, and the memory gate sits at
# the SAME spawn point (#2387), so on a box below its 2048 MB floor the spawn is refused 81 before the
# validator is ever sought and the suite reports its own subject as broken. One line, same shape the
# sibling suites carry. (Both isolation idioms merged: main's `env -u AGENT_INFRA_PATH` is the one the
# note above documents — an empty assignment and `env -u` drive the same not-found path.)
res="$( cd "$FIXREPO" && env -u AGENT_INFRA_PATH PATH="$TMP/bin:$PATH" O="$TMP/o2" HOME="$TMP/fakehome" PI_LOG="$PI_LOG" MAX_LOAD=1000 MEM_MIN_AVAIL_MB=1 DISK_MIN_FREE_MB=1 \
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
# ⛔ THE POSITIVE CONTROL USES THE REVIEWER BRIEF, NOT `$CANON` (agent-infra#3442): merge-one.sh's
# `run_agent` gates role `reviewer`, and since #3442 a reviewer brief must carry the mutation block.
# Driving the LANE canonical brief here stopped being a control the moment the contract landed — it
# now proves the gate fires, which the arm ABOVE already covers.
res="$(drive_m1 "$REV_CANON")"
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

# ── safe-send.sh's PANE PROBE must accept the context budget pi actually draws (2026-10-31).
# The owner decision moved the clamp 300K → 800K, so a settled TUI renders `formatTokens(800000)`
# = `%/800k`; until this arm the probe's only literals were `/300k` and the model bullet, and the
# pre-existing `/300k` literal was equally untested. A probe that does not match the live footer
# reads a LIVE, settled lane as a bare login shell and REFUSES the send (rc 3) — the failure that
# motivated the literal. Driven, not grepped: the stub's LAST line carries the budget and NOTHING
# else the probe matches (no `• high` bullet, no model-bullet arm), so these arms flip only on the
# budget literals. `%/500k` is the negative control: a budget pi never draws is refused.
# ⛔ `%/1.0M` IS NOT A NICETY — it is the window this fleet PRESCRIBES for its own rollback
# (`models.json` contextWindow 800000 → 1000000, docs/ops/cost-config-policy.md §7.1 and
# watch-truncation.sh's printed procedure) and the shipped `kimi-k3` window (1,048,576). pi draws
# it as `1.0M`, NOT `1M` (`formatTokens`: `count < 1e6 → round(count/1000)+"k"`, else
# `(count/1e6).toFixed(1)+"M"`), so a tuple written from the `/1M` guess matches no footer at all:
# after the owner executes the rollback procedure every lane would read "NO pi IN THIS PANE" and
# every send would exit 3. `%/262k` is the other shipped non-deepseek window (`qwen3.8-max`,
# 262144 → pi renders `262k`); unlike the heartbeat's probe, safe-send's has NO `(auto)` or
# model-bullet rescue arm, so an unlisted window is an outright refusal. Pin every shipped window
# here, not just the current clamp.
# ⛔ THE LATER GATE MUST BE THE FIXTURE'S, NOT THIS HOST'S. `safe-send.sh` delegates busy/idle to
# `lane-guard.py`, whose `cmux` calls run through `lane-status.py`'s `env=CMUX` with four HARD-CODED
# absolute bin dirs PREPENDED to PATH (`_CMUX_BIN_DIRS` is `:49-54`; the prepend itself is `:58`,
# `CMUX["PATH"] = os.pathsep.join(_present + …)`, guarded by `:57 if _present:`). So the `$TMP/bin/cmux` stub below is
# SHADOWED wherever a real `cmux` sits in one of the four dirs that EXIST on the box — `/usr/local/bin` or
# `~/.local/bin` on a Linux box, `/opt/homebrew/bin` or the macOS app dir on a Mac — and is reached only
# when none of them holds one (CI: ubuntu-latest). This is NOT a Mac-only condition: measured on the
# Linux box this was diagnosed on, `cmux` resolves at `/usr/local/bin/cmux`, `/usr/local/bin` is one of
# the four, and the real gate therefore ran and satisfied the grep. Wherever it runs, its empty read
# produces the SAME message this arm wants, purely by accident. Measured both ways: the green was a
# property of the HOST, not of `safe-send.sh`.
#
# SO WHAT GETS PINNED HERE IS THE **CONSUMER** SIDE, AND ONLY THROUGH A SENTINEL. This arm pins
# `safe-send.sh:182-189`: that it READS `SAFE_SEND_GUARD` (`:182`), runs it (`:183`), and turns a
# non-zero rc (`:185`) into its `REFUSED … Not consumable` message with `exit 3` (`:189`). ⛔ But a fixture that emits the REAL gate's message cannot prove the
# seam was honoured at all — the real `lane-guard.py` emits `REFUSED [3.1s] pane UNREADABLE — busy/idle
# UNKNOWN, not idle`, which satisfies a bare `pane UNREADABLE` grep. Measured: deleting the seam
# (`GUARD="$SCRIPTS/lane-guard.py"`, so `SAFE_SEND_GUARD` is never read) left this suite at an IDENTICAL
# `118 passed, 1 failed` — the arm was grading the host again, one layer down. So the fixture prints a
# `FIXTURE-GUARD:` sentinel that the real gate never emits, and the positive arms assert on THAT. Re-run
# the same mutation after any edit here: it must go RED.
# The real `lane-guard.py` is STUBBED, not pinned: it has no host-independent seam to drive (`lane-status.py`
# hard-codes `_CMUX_BIN_DIRS` with no env override), which is precisely why the stub `cmux` could never
# reach it. ⛔ RESIDUAL, named rather than absorbed: on a host WITH `cmux` this arm used to execute the real
# gate incidentally, and on CI it always did; after this change NO arm in this suite executes
# `lane-guard.py`, so a regression in its busy/idle refusal ships with nothing red here. Tracked at #3524.
printf 'import sys\nprint("REFUSED [0.0s] FIXTURE-GUARD: pane UNREADABLE — busy/idle UNKNOWN, not idle")\nsys.exit(3)\n' > "$TMP/bin/fake-guard.py"
for _budget in '%/800k' '%/300k' '%/1.0M' '%/262k' '%/500k'; do
  printf '#!/bin/sh\necho "CMUX_RAN $*" >> "$CMUX_LOG"\ncase "$1 $2" in "read-screen --workspace") echo "~/Documents/GitHub/agent-infra"; echo "  deepseek-flash %s";; esac\nexit 0\n' "$_budget" > "$TMP/bin/cmux"
  chmod +x "$TMP/bin/cmux"
  : > "$CMUX_LOG"
  PATH="$TMP/bin:$PATH" CMUX_LOG="$CMUX_LOG" AGENT_INFRA_PATH="$ROOT" SAFE_SEND_DISPATCH=/bin/true \
    SAFE_SEND_GUARD="$TMP/bin/fake-guard.py" \
    bash "$ROOT/scripts/safe-send.sh" 00000000-0000-0000-0000-000000000000 pane-probe "$ALERT" --notice >"$TMP/probe.out" 2>&1; rc=$?
  if [ "$_budget" = '%/500k' ]; then
    grep -q 'NO pi IN THIS PANE' "$TMP/probe.out"; ck $? "negative control: a budget pi never draws (%/500k) is still REFUSED as 'no pi' (rc=$rc)"
    grep -q 'pane UNREADABLE' "$TMP/probe.out"; [ $? -ne 0 ]; ck $? "…and it never reaches the later busy/idle gate (the refusal is the pane probe's)"
  else
    # The observable is WHICH gate refused, not the exit code: the pane probe's refusal is the
    # "NO pi IN THIS PANE" message (exit 3), while the busy/idle gate that follows refuses with
    # "pane UNREADABLE" and ALSO exits 3 — so an rc-only assertion cannot tell them apart, and a
    # probe that rejected the live footer would print the message this arm forbids.
    grep -q 'NO pi IN THIS PANE' "$TMP/probe.out"; [ $? -ne 0 ]; ck $? "the pane probe ACCEPTS the live footer budget ${_budget} (it does not report 'NO pi IN THIS PANE')"
    # ⛔ THE SENTINEL IS THE POINT: 'pane UNREADABLE' alone is emitted by the REAL `lane-guard.py` too, so a
    # bare grep passes when `SAFE_SEND_GUARD` is ignored and the host's gate runs instead of the fixture.
    # 'FIXTURE-GUARD:' is a string the real gate never prints, so this assertion can only be satisfied by
    # the fixture the seam installed — re-run the seam-deletion mutation to confirm it goes red.
    grep -q 'FIXTURE-GUARD: pane UNREADABLE' "$TMP/probe.out"; ck $? "…and the refusal it DOES hit is the FIXTURE busy/idle gate, so the probe admitted ${_budget}"
    # ⛔ AND THE REFUSAL MUST REACH THE CALLER AS A REFUSAL. The two greps above are blind to the exit
    # code, so a `safe-send.sh` that prints its busy/idle refusal and then reports SUCCESS is green
    # everywhere — measured: mutating `safe-send.sh:189` `exit 3` → `exit 0` left this suite at an
    # IDENTICAL `118 passed, 1 failed`. That is the regression worth catching, because the rc IS the
    # verdict: `tools/fleet/outcome_canary.py:2944` renders it through `SAFE_SEND_RC`
    # (`0: "DELIVERED (consumed)"`, `3: "REFUSED (lane busy or state unknown)"`), so a refusal that
    # returned 0 would be recorded as delivered. (⛔ NOT `lane.sh`/`fix-one.sh`: they LAUNCH an agent and
    # never send into a pane — `grep -c safe-send` is 0 in both, and `lane-status.py` records that
    # `safe-send.sh` is manual-only now. Citing them here was a round-7 review finding.)
    # `-eq 3` pins the CODE, not the identity of the refuser: the pane probe's own refusals are also 3
    # (`safe-send.sh:130`, `:155`), and so is the real host gate's — which is why WHICH gate refused is
    # settled by the `FIXTURE-GUARD:` sentinel above and only there.
    [ "$rc" -eq 3 ]; ck $? "…and the busy/idle refusal is a REFUSAL to the caller (3), never a success (rc=$rc)"
  fi
done

# ── pr-doctor.py: the fleet's own generated worker brief must carry the contract, or every worker the
# beat spawns is refused. Driven through the module, not grepped from the source.
# ⛔ THE PROBE IS ISOLATED, AND ITS ISOLATION IS ASSERTED BELOW (agent-infra#2708, review). Before
# agent-infra#2708 `brief()`'s success path logged NOTHING, so an unisolated probe neither resolved the
# box's `brief-gate.sh` copies nor wrote anything outside the repo. Both changed: `research_section()`
# now `log()`s a provenance line ("rendered by <copy> and admitted by N validator(s)"), `log()` appends
# to `$STATE_DIR/pr-doctor.log` resolved AT CALL TIME from `HOME`, and `_brief_gate_paths()` widened the
# ladder to `$AGENT_INFRA_PATH` and the farm with a VETO from any rung that refuses. Unisolated, that is
# two defects in one line: this shard appends a fabricated provenance line to the operator's LIVE log
# (indistinguishable from a real pass's, naming a copy no pass used -- the class
# `test_pr_doctor.py::_clean_env` already closed for pytest), and its verdict becomes a statement about
# what this box happens to have installed. `O` an empty dir + a private `HOME` + no `AGENT_INFRA_PATH`
# leaves the TREE's own copy as the only rung, which is what the arm is about.
mkdir -p "$TMP/pd-o" "$TMP/fakehome"
out="$("$ROOT/../venv-brief-probe" 2>/dev/null; env -u AGENT_INFRA_PATH O="$TMP/pd-o" HOME="$TMP/fakehome" \
        python3 - "$ROOT" <<'PY' 2>/dev/null
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
# ⛔ AND THE PROVENANCE LINE LANDS IN THE FIXTURE, NAMING THE TREE'S OWN COPY -- asserted by EFFECT,
# not by the presence of `HOME=`/`O=` above, and not by a prefix match either. Both halves of the
# defect are graded here because both are visible in the one line: WHERE it went (inside the private
# home, so the live operator log was never touched) and WHICH COPY it names (`_brief_gate_paths`,
# `pr-doctor.py:3470-3482`, resolves `$ROOT/scripts/orchestrator-harness/brief-gate.sh` and nothing
# else once `O` is an empty dir, `HOME` is private and `$AGENT_INFRA_PATH` is unset). Measured: a
# PREFIX-ONLY grep is green on a half-revert that keeps `HOME=` and drops `O=`/`env -u`, because the
# line still lands in the fixture -- it just names the BOX's copy and its validator count (the
# box-dependence half of the defect, unasserted). Pinning the whole line reds that half-revert, so the
# `O=` and `env -u` in the invocation above cannot rot silently. `-F`: `$ROOT` is a path, not a regex.
grep -qF "brief: research contract rendered by $ROOT/scripts/orchestrator-harness/brief-gate.sh and admitted by 1 validator(s)" \
  "$TMP/fakehome/.pi/agent/state/pr-doctor.log"; ck $? \
  "…and its provenance line names the TREE's own copy (1 validator) and lands in the FIXTURE, never the live log"
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
# ⛔ AND THE BRANCH MUST BE THE ONE THE FIXTURE IS ON (measured: `fix/x` -> rc=72,
# `REPO_TARGET_REFUSED`, `branch-missing`). lane.sh asserts the checkout's own origin AND attached
# branch (#2724/#2694) BEFORE it looks for a validator, so a lane told a branch the fixture does not
# have is refused for the REPO-IDENTITY reason and never reaches the missing-validator path this arm
# is about — the assertion then reads as "the fail-closed arm is broken" when the arm had not run. The
# fixture is born on `init.defaultBranch=fix/research-first-gate` above; one word, same branch.
# ⛔ AND `env -u AGENT_INFRA_PATH` IS *STILL* NOT ENOUGH ON A BOX WITH A `keys.env` — A SIXTH ROOT IS THE
# BOX'S OWN CREDENTIAL FILE (review cycle 11, MEASURED on a cell). `lane.sh` sources `lane-env.sh`, which
# dots `${ENV_FILE:-$HOME/keys.env}` at top level under `set -a` BY DESIGN (`lane-env.sh:16-61`: the keys
# file is authoritative for credentials, exactly as `cloud-cell-supervisor.sh` treats it) — and a real
# `keys.env` carries `export AGENT_INFRA_PATH=/home/cmux/agent-infra`, which it RE-EXPORTS over the
# `env -u` above. The resolver then found `/home/cmux/agent-infra/scripts/orchestrator-harness/brief-gate.sh`,
# ran the REAL validator, and reported `rc=0` — so the arm read as "the fail-closed path is broken" on
# every cell and dev box while passing on a clean CI runner (which has no keys file), i.e. it reddened
# exactly where the variable is REAL. `ENV_FILE` is the seam `lane-env.sh` already exposes; pointing it
# at a path that does not exist is the isolation this arm claims, and it is the same `env -u` reasoning
# one layer further out: a fixture that inherits ambient state cannot make a claim about isolation.
( cd "$TMP" && env -u AGENT_INFRA_PATH ENV_FILE="$TMP/fakehome/no-keys.env" O="$TMP/lane-o2" PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    HOME="$TMP/fakehome" bash "$HERE/lane.sh" 2258 fix/research-first-gate daniel-ospina/agent-infra ) >/dev/null 2>&1; rc=$?
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
# measured). The `orchestrator-harness` entries without a comment above arrived on `main` after the last
# time this list was edited — `ai-drainer.sh` dispatches through `brief_gate_run`, and the suites drive
# gate-carrying paths — so the arm was ALREADY red on `main` (`found` is a strict superset),
# independently of any branch. Declared here because an equality that is red on its own base stops being
# a signal: every PR inherits the same red and nobody can attribute it.
# ⛔ THE COUNT IS DELIBERATELY NOT NAMED (this list changes; a pinned integer is the drift
# `check-single-source.sh` warns about). What each entry IS still has to be said:
#   * `mandate-preflight.sh` / `mandate-preflight.test.sh` (#3377) are REFERENCERs — the helper names
#     `brief-gate.sh` in its header prose and the suite quotes it — and neither dispatches a `pi`
#     invocation, so they join this equality without joining the dispatch population.
#   * `check-farm-drift.sh` (88c720f54, #3120) and `nonblocking-dispatch.test.sh` (e9b8b7663, #3219 —
#     issue #3162) landed on `main` after the list was last edited and are the same class: a REFERENCER
#     (it names the gate in prose, `:19`) and a SUITE (it stubs the gate). They are TWO of the four names
#     that kept this equality red at this change's base — measured there (29b3af07), `found`=30 vs the 26
#     declared — which is the condition this block's own paragraph calls out: an equality red on its own
#     base attributes nothing, so a NEW dispatch path added tomorrow would inherit the same red and stay
#     invisible. They are declared here so the arm can pass and therefore say something again.
#   * `cloud-cell-supervisor.sh` and `key-gate.sh` (29b3af07, #3331/#3342) are the OTHER two of those
#     four, arriving with that same commit and declared for the same reason: the supervisor NAMES the
#     gate in prose and in its own preflight list (`:2654`, `:2656`), the key gate names it in prose
#     (`:33`). Measured at this change's rebase head (19f1c6fe), `found`=32 vs the 30 declared. Neither
#     dispatches a `pi` invocation, so neither joins the dispatch population.
#   * ⛔ THE `pi`-INVOKER CENSUS COVERS THE HELPER ONLY, NOT ITS SUITE (measured): `spawn-gate.test.sh`'s
#     scan excludes `*.test.*` by name, so `mandate-preflight.test.sh` is invisible to it. That is why the
#     suite's own E5 states its residual in-line instead of pointing at that census for protection.
#   * ⛔ AND #3442 ADDS FIVE MEMBERS OF ITS OWN, declared on the same terms: `record-review.sh` (it calls
#     `brief-gate.sh --mutation-missing` rather than merely naming it), `record-review.test.sh` and
#     `mutation-attribution.test.sh` (both DRIVE that parser), and the two `fixtures/mutation-attribution/`
#     documents (they name the parser where a suite's author copies the shape from). Declared rather than
#     filtered out of the scan: a filter on a directory would silently absorb the next caller that happens
#     to live there, which is the "gate that cannot see the thing it exists for" shape this list exists
#     to prevent.
#   * ⛔ `disk-admission.test.sh` (c2b7f2bf0, #3395/#3409) is a REFERENCER, and it was the ONE name that
#     kept this equality red at this change's base — measured on `2c18ff89a`, `found`=42 vs the 41
#     declared, the same "red on its own base" condition the paragraph above calls out. Its only
#     reference is a comment (`:1260`-`:1261`) recording WHY it declined to grow a `--section fixer`
#     option: the flag belongs to `brief-gate.sh`. It dispatches no `pi` invocation, so it joins this
#     equality without joining the dispatch population.
#   * ⛔ `scripts/test_cmux_dispatch_path.py` (#1957, declared on ITS owner's terms) is a SUITE that
#     drives the REAL `scripts/safe-send.sh` end to end — including its gate call, whose refusal it
#     asserts by the validator's own message (`brief-gate.sh not found` → 78). So it is a REFERENCER
#     of the class this block already carries (`capacity-transfer.test.sh`, `nonblocking-dispatch.test.sh`),
#     not a new dispatch path: it never launches `pi` and never sends anything. It joined the scan
#     when the 78-precedence arm started naming the validator's message (#3836 F4) — an ARM that
#     asserts WHICH refusal it got cannot do so without naming it — and an undeclared member reddens
#     this equality with `ADDED: scripts/test_cmux_dispatch_path.py`, which is the attributable red
#     the census exists for. Declared rather than filtered out: a filter on `scripts/test_*.py` would
#     silently absorb the next suite that becomes a CALLER.
#   * ⛔ `scripts/orchestrator-harness/gh-auth.test.sh` (#2509) is the SAME class as
#     `capacity-transfer.test.sh` and `nonblocking-dispatch.test.sh`, one level higher: its `run_lane`
#     arms drive the REAL `spawn-gate.sh` `run_agent`, and the gate refuses a non-compliant brief with
#     74 BEFORE the code under test is reached — so the suite renders its brief fixture by CALLING
#     `$HERE/brief-gate.sh --section lane` (`:135`) rather than hard-coding a block that would drift
#     from the gate. It dispatches no writer of its own (the `pi` it starts is a stub), so it is a
#     REFERENCER: it joins this equality without joining the dispatch population. Undeclared it
#     reddens the arm with `ADDED: scripts/orchestrator-harness/gh-auth.test.sh`, which is the
#     attributable red this census exists for. Declared rather than hidden behind a filter: a filter on
#     `*gh-auth*` would silently absorb the next suite that starts driving the gate.
EXPECTED="AGENTS.md scripts/check-farm-drift.sh scripts/cloud-cell-supervisor.sh scripts/orch-send.sh scripts/orchestrator-harness/ARCHITECTURE.md scripts/orchestrator-harness/README.md scripts/orchestrator-harness/ai-drainer.sh scripts/orchestrator-harness/ai-drainer.test.sh scripts/orchestrator-harness/brief-gate.sh scripts/orchestrator-harness/capacity-transfer.test.sh scripts/orchestrator-harness/check-single-source.sh scripts/orchestrator-harness/claim-reaper.sh scripts/orchestrator-harness/claim-reaper.test.sh scripts/orchestrator-harness/claims.sh scripts/orchestrator-harness/disk-admission.test.sh scripts/orchestrator-harness/fix-one.sh scripts/orchestrator-harness/fixtures/mutation-attribution/README.md scripts/orchestrator-harness/fixtures/mutation-attribution/verdict-attribution.md scripts/orchestrator-harness/gh-auth.test.sh scripts/orchestrator-harness/install.sh scripts/orchestrator-harness/key-gate.sh scripts/orchestrator-harness/lane-bound.test.sh scripts/orchestrator-harness/lane.sh scripts/orchestrator-harness/mandate-preflight.sh scripts/orchestrator-harness/mandate-preflight.test.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/mutation-attribution.test.sh scripts/orchestrator-harness/nonblocking-dispatch.sh scripts/orchestrator-harness/nonblocking-dispatch.test.sh scripts/orchestrator-harness/reviewer-preflight.test.sh scripts/orchestrator-harness/selftest.sh scripts/orchestrator-harness/spawn-gate.sh scripts/orchestrator-harness/spawn-gate.test.sh scripts/orchestrator-harness/wip-rescue-exit.test.sh scripts/pr-doctor.py scripts/record-review.sh scripts/record-review.test.sh scripts/safe-send.sh scripts/test_cmux_dispatch_path.py scripts/test_cmux_payload.py scripts/test_pr_doctor.py templates/AGENTS.base.md templates/LANE-BRIEF.md"
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
