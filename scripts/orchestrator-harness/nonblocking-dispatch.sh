#!/usr/bin/env bash
# nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [backstop-seconds] [kind]
# nonblocking-dispatch.sh --status <name>
#
# ⛔ `backstop-seconds` IS A BACKSTOP, NOT THE LANE'S PRIMARY BOUND (agent-infra#2888). It is the
# ABSOLUTE ceiling handed to `run_agent` -> `lane-bound.sh --wall`; the bound that decides wedged-vs-slow
# is the PROGRESS allowance (45 min, the fleet's own declared no-progress window), which a caller does
# not pass here because it must be the same number on every lane. Omitted, it defaults to
# `LANE_BACKSTOP_S` from spawn-gate.sh — one default, not a fourth literal in this file.
#
# `kind` declares WHAT is being spawned, because `KIND` is not a creation/repair discriminator: the
# creation back-pressure gate (spawn-gate.sh, agent-infra#2409) holds every KIND except the ones whose
# product IS the drain, and pr-doctor dispatches its PR-REPAIR workers through this script. A
# hardcoded `KIND=bg` therefore put those repairs under the gate in exactly the state that triggers
# it (review cycle 2, P1). The caller now says `prfix` for an already-open PR's repair; the DEFAULT
# stays `bg`, i.e. the refusing direction, so an undeclared caller is measured rather than trusted.
#
# Launches a headless worker in the BACKGROUND and RETURNS IMMEDIATELY, so an orchestrator can keep
# working instead of blocking on it. (The built-in `task`/`subagent` tools block the caller — that is
# agent-infra#1662, "non-blocking dispatch is the one remaining structural gap"; this is the harness's
# own version of the shape #206 sanctions, with the status seam #1662 names as the missing piece.)
#
# ⛔ IT CARRIES NO AGENT INVOCATION OF ITS OWN. It backgrounds `run_agent()` from spawn-gate.sh, so a
# background worker gets the SAME load gate (agent-infra#1720), the same wall-clock watchdog and the
# same #1709 walltime row as `lane.sh` and `fix-one.sh`. The local copy this is ported from spawned
# `pi` itself with NO load gate — i.e. it was a fourth, ungated launch path, exactly what
# spawn-gate.test.sh's two-scope census exists to refuse (it asserts the invoker SET as an equality).
# Routing through the helper is the whole point of the port; do not "simplify" it back to a direct
# spawn, or the census goes red and a background worker starts landing on a saturated box.
set -u
NAME="${1:-}"
if [ "$NAME" = "--status" ]; then
  NAME="${2:-}"
  [ -n "$NAME" ] || { echo "usage: nonblocking-dispatch.sh --status <name>" >&2; exit 2; }
  O="${O:-$HOME/orchestrator}"; D="$O/bg"
  RC="$(cat "$D/$NAME.rc" 2>/dev/null || true)"
  PID="$(cat "$D/$NAME.pid" 2>/dev/null || true)"
  # ⛔ A CAP KILL IS ITS OWN FACT (#2045). A lane killed at its wall-clock cap used to be
  # indistinguishable from one that finished with nothing to do: the launcher recorded a bare exit
  # status, `pi -p`'s buffered output is lost on SIGTERM, and the work it had already done sat
  # uncommitted in a temp worktree while the only signal was an absence. The worker now publishes a
  # `.cap` marker (cap seconds + the verified snapshot run_agent wrote), so this line NAMES the cap
  # and the preserved work instead of reporting a bare `rc=143` — or, worse, `commits=0`.
  CAPNOTE=""
  if [ -f "$D/$NAME.cap" ]; then
    # awk, not `sed | head`: this runs on an operator's status call, and a pipeline whose reader exits
    # early is the SIGPIPE shape `scripts/check-no-sigpipe-grep.sh` exists to keep out of the tree.
    CAPNOTE="$(awk -F= '/^note=/{sub(/^note=/, ""); print; exit}' "$D/$NAME.cap" 2>/dev/null)"
  fi
  # ⛔ THE TERMINAL RECORD (#2834) — WHAT HAPPENED TO THE WORK, NOT ONLY WHAT THE EXIT CODE WAS.
  # `bg/dispatch.log` records the START and this call used to report `rc` alone, so "the lane
  # finished with nothing to do" and "the lane finished and left its only copy of the work in a
  # worktree a reaper will delete" printed the SAME `done rc=0`. run_agent now measures the tree on
  # every terminal transition and this file publishes its verdict, so the answer to "did anything
  # need saving, and where is it" is one status call away instead of an archaeology exercise.
  ENDNOTE=""
  if [ -f "$D/$NAME.end" ]; then
    ENDNOTE="$(awk -F= '
      /^tree=/{t=$2} /^rescue=/{r=$2} /^ref=/{f=$2} /^unpushed=/{u=$2}
      END{ if (t=="" && r=="") exit
           s = " end: tree=" t " rescue=" r
           if (f != "") s = s " (" f ")"
           if (u != "" && u != "0") s = s " unpushed=" u
           print s }' "$D/$NAME.end" 2>/dev/null)"
  fi
  # ⛔ LIVENESS IS NOT %CPU. `%CPU == 0` means WAITING, not finished — a lane blocked in a long tool
  # call sits at 0 % CPU (docs/ops/fleet-liveness.md). The authoritative signal is the worker's own
  # exit-status file, written by the subshell below; the pid probe only distinguishes
  # running from vanished.
  if [ -n "$RC" ]; then
    if [ "$RC" = "0" ]; then
      printf '%s done rc=0%s%s\n' "$NAME" "${CAPNOTE:+ (${CAPNOTE})}" "$ENDNOTE"
    else
      printf '%s failed rc=%s%s%s\n' "$NAME" "$RC" "${CAPNOTE:+ (${CAPNOTE})}" "$ENDNOTE"
    fi
  elif [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "$NAME running pid=$PID"
  else
    # No status file and no live pid: the worker is gone and its verdict was never recorded. Say so
    # rather than reporting a success that nothing produced.
    printf '%s lost (no exit status recorded and pid %s is gone) log=%s%s%s\n' "$NAME" "${PID:-<unknown>}" "$D/$NAME.log" "${CAPNOTE:+ (${CAPNOTE})}" "$ENDNOTE"
  fi
  exit 0
fi
WT="${2:-}"; PROMPT="${3:-}"; T="${4:-}"; WK="${5:-bg}"
if [ -z "$NAME" ] || [ -z "$WT" ] || [ -z "$PROMPT" ]; then
  echo "usage: nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [backstop-seconds] [bg|prfix]" >&2
  echo "       nonblocking-dispatch.sh --status <name>" >&2
  exit 2
fi
# ⛔ A CLOSED VOCABULARY, NOT FREE TEXT. `KIND` is what spawn-gate.sh switches on, so an unvalidated
# argument would let a caller invent `KIND=whatever-i-like` and the gate's deny-list would hold it by
# accident, not by design (`prfix` and `bg` are the only two this dispatcher may start; the exempt
# `fixer`/`reviewer` kinds belong to fix-one.sh/merge-one.sh, which have their own entry points).
case "$WK" in
  bg|prfix) ;;
  *) echo "nonblocking-dispatch.sh: kind '$WK' is not bg or prfix" >&2; exit 2 ;;
esac

O="${O:-$HOME/orchestrator}"; D="$O/bg"; mkdir -p "$D" "$O/state"
# ⛔ PATH FIRST, then source — this part IS lane.sh/fix-one.sh's rule. spawn-gate.sh derives `_NCPU`
# at SOURCE time (sysctl/nproc/getconf), so sourcing it under a cell's pre-export PATH pins
# `_NCPU=4` / `MAX_LOAD=40` for every cell (agent-infra#1702). The two siblings carry the same ⛔.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ AND RE-ASSERT THE gh LIMIT LAYER AFTER IT (#1988) — the same rule lane.sh / fix-one.sh /
# merge-one.sh / chain-merge.sh carry. This script does not call `gh` itself, but it SPAWNS a whole
# worker session IN-PROCESS (`run_agent` inherits this environment), so without these two lines every
# `gh` that worker runs resolves to `/opt/homebrew/bin/gh` — the layer would be deployed and inert,
# which is exactly the state the issue exists to remove. Grouped so the population check in
# `gh-limit.test.sh` sees them.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The RESOLUTION, though, mirrors merge-one.sh's repo-authority.sh — NOT lane.sh/fix-one.sh, which
# source only `$SELF/spawn-gate.sh` and never consult `$O`. Prefer the daemon's copy at `$O`, fall
# back to the copy beside THIS script; an unresolved helper must never degrade into "the worker ran".
if [ -f "$O/spawn-gate.sh" ]; then . "$O/spawn-gate.sh"; HARNESS="$O"
else
  HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  . "$HARNESS/spawn-gate.sh" 2>/dev/null \
    || { echo "nonblocking-dispatch.sh: spawn-gate.sh not found (looked in $O and ${HARNESS:-<unresolved>}) — refusing to start an ungated worker" >&2; exit 78; }
fi
command -v run_agent >/dev/null 2>&1 \
  || { echo "nonblocking-dispatch.sh: spawn-gate.sh is stale (no run_agent) — refusing to start an ungated worker" >&2; exit 78; }

# ⛔ THE BACKSTOP DEFAULT IS RESOLVED HERE BECAUSE IT LIVES IN spawn-gate.sh, WHICH IS SOURCED ABOVE
# (agent-infra#2888). An OMITTED timeout takes the one default; an EXPLICIT non-numeric one is still a
# caller bug and refuses; and on a box whose `$O/spawn-gate.sh` predates the seam the value cannot be
# resolved at all — that is a broken install (78), never a silent fall back to a literal, because a
# guessed backstop is the flat cap this issue removes, back again under a new name.
if [ -z "$T" ]; then
  T="${LANE_BACKSTOP_S:-}"
  [ -n "$T" ] || { echo "nonblocking-dispatch.sh: no timeout was given and this box's spawn-gate.sh has no LANE_BACKSTOP_S (stale \$O) — refusing to guess the backstop; pass it explicitly or sync the harness" >&2; exit 78; }
fi
case "$T" in ''|*[!0-9]*) echo "nonblocking-dispatch.sh: backstop '$T' is not a positive integer" >&2; exit 2 ;; esac

[ -d "$WT" ]     || { echo "nonblocking-dispatch.sh: no worktree $WT" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "nonblocking-dispatch.sh: no prompt file $PROMPT" >&2; exit 2; }

# ── THE BRIEF GATE, IN THE FOREGROUND (agent-infra#2258) ────────────────────────────────────────
# This is the ONE dispatch path whose brief is AUTHORED BY THE CALLER rather than generated by the
# harness (`pr-doctor.py` composes one, and so does a human), which makes it the path the two measured
# defects came through. It is checked HERE, before the fork, and that placement is the whole point:
# the worker is backgrounded with `exec >/dev/null 2>&1` (see below), so a refusal raised INSIDE it
# would leave no trace in this caller's output and the dispatcher would report a launch that never
# happened. In the foreground the author gets the teaching message and a non-zero exit instead.
#
# ⛔ 80 IS NOT 78 AND NEITHER IS 2. 2 = usage/worktree (a caller bug), 78 = the validator itself is
# missing (a broken install — every dispatch on the box is affected), 80 = THIS BRIEF is deficient
# (the author re-authors and re-sends). `pr-doctor.py` propagates the code and the stderr verbatim.
# ⛔ THE RESOLVER IS THE HELPER'S WHEN IT HAS ONE, AND THIS SCRIPT'S OWN WHEN IT DOES NOT, because of
# the $O-SKEW THIS FILE ALREADY DOCUMENTS: the daemon executes `$O/<script>` and `$O` is seeded file
# by file, so a NEW dispatcher can run against an OLD `$O/spawn-gate.sh` that predates #2258 and has
# no `brief_gate_lib`. Calling it unconditionally made every worker on such a box exit 78 with
# `brief_gate_lib: command not found` — loud, but it names the wrong fault (the validator is right
# there). The fallback searches the same four homes, so the gate depends on the VALIDATOR's presence
# and not on the helper's revision.
bg_lib=""
command -v brief_gate_lib >/dev/null 2>&1 && bg_lib="$(brief_gate_lib)"
if [ -z "$bg_lib" ]; then
  for _c in "$O/brief-gate.sh" "$HARNESS/brief-gate.sh" \
            "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh" \
            "${HOME:-}/.pi/agent/scripts/brief-gate.sh"; do
    [ -n "$_c" ] && [ -f "$_c" ] && { bg_lib="$_c"; break; }
  done
fi
if [ -z "$bg_lib" ]; then
  echo "nonblocking-dispatch.sh: brief-gate.sh not found (looked in $O, $HARNESS, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — refusing to start an unvalidated worker" >&2
  exit 78
fi
# ⛔ THE NAMING LINE GOES FIRST, ON THE OUTSIDE OF THE GATE'S OWN OUTPUT (#2708 review, P2 —
# reproduced). The gate prints a ~3.5 KB teaching block on refusal, and `pr-doctor` logs only SLICES
# of the captured stderr: `detail[:200]` on its FAIL line (`scripts/pr-doctor.py:3768`) and
# `detail[:160]` on its NOT-DISPATCHED line (`:5093`; `:5090` is the REFUSED-and-RECORDED line, which
# rc=80 never reaches). With the path APPENDED after that block it lands at byte ~3290 of ~3655 —
# measured on the fixture in `test_pr_doctor.py`, `'brief-gate.sh' in detail[:160]` was False and
# `in detail[:200]` was False — so the operator who reads the doctor's log still could not tell which
# copy refused, i.e. case 3's 6 h 32 m "which copy?" hunt was narrowed but not closed.
# The gate's output is therefore CAPTURED and re-emitted AFTER the naming line, and the path is placed
# at char 53 of `detail` (`rc=80: ` + `brief-gate=`) rather than after a 90-char preamble, so it sits
# at ~char 46 of this line — the whole path fits the 160-char slice whenever the resolved path is
# ≤ 107 chars, which every production `$O` is (the path a real box RESOLVES is `$O/brief-gate.sh`,
# `$O` defaulting to `$HOME/orchestrator` — 27 + `len($HOME)` chars, 41 in this fleet; the
# `$HOME/.pi/agent/scripts` candidate is only the FOURTH fallback, 32 + `len($HOME)`, and both are
# nowhere near 107). ⚠️ The
# bound is the ORDERING plus that length; a box whose resolved path is longer than ~107 chars shows a
# truncated tail, not a missing name (#2986 review, P1: the first form of the arm asserted the pytest
# fixture's 141-char macOS temp path against 160, so it graded the box's `$TMPDIR` and was red on
# every macOS box while green on ubuntu-latest).
# The canonical section still reaches the reader verbatim. On success the gate prints nothing, so the
# capture is invisible on the normal path.
if ! brief_out="$(bash "$bg_lib" --check "$PROMPT" worker 2>&1)"; then
  echo "nonblocking-dispatch.sh: REFUSED — brief-gate=$bg_lib judged the brief at $PROMPT and refused it (agent-infra#2258). NOTHING WAS STARTED: no worker, no session, no model call. The [brief-gate] block BELOW names every missing element and prints the canonical section." >&2
  printf '%s\n' "$brief_out" >&2
  exit 80
fi
[ -n "$brief_out" ] && printf '%s\n' "$brief_out" >&2

LOG="$D/$NAME.log"; RC="$D/$NAME.rc"; PIDF="$D/$NAME.pid"; STAMP="$D/$NAME.started"
CAPF="$D/$NAME.cap"   # written by the worker below when the wall-clock cap fired (#2045)
ENDF="$D/$NAME.end"   # the TERMINAL RECORD (#2834): rc + what the exit path did with the worktree
# ⛔ BOTH CLEARED BEFORE LAUNCH. A `.end` left by a PREVIOUS run of the same name would be read as
# THIS run's terminal record — the same staleness that made `--status` report a finished worker for a
# live one, one file over.
rm -f "$CAPF" "$ENDF"
# The worker is a fleet lane in every respect except that nobody waits for it. ⛔ THE GATE DECISION
# IS MEASURED (agent-infra#2319) — this used to bypass review + VGATE unconditionally; see lane.sh.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/gate-policy.sh" 2>/dev/null || { echo "nonblocking-dispatch.sh: FATAL: $SELF/gate-policy.sh missing — refusing to start a worker that cannot say whether its gates are on" >&2; exit 78; }
apply_gate_policy nonblocking-dispatch
# ── COMMIT AS YOU GO on an AUTHORED brief (#2981) — APPENDED, never refused ──────────────────────────
# This is the one dispatch path whose brief the CALLER wrote (`pr-doctor.py`, or a human), and it is
# the path the measured 5-of-5 zero-commit batch came through. The research contract above is a GATE
# (absent = refuse with 80) because a worker that never looked first is the defect it exists for. This
# one is APPENDED instead: an authored brief that is otherwise complete must not become a dead
# dispatch over one missing sentence, and the append is idempotent — a brief that already carries the
# section (or that came from a generated composer) is left byte-for-byte alone.
# ⛔ THE SECTION HAS ONE HOME. It is rendered by `reviewer-preflight.sh`, never copied here; the
# needle is that render's own first line, so a reworded heading cannot silently stop matching.
# ⛔ THE ROLE COMES FROM `$WK`, NEVER FROM A GUESS. `$WK` is the SAME declared kind that selects the
# spawn-gate policy (#2409), and this dispatcher's callers sit on both sides of it: `pr-doctor.py`
# passes `prfix` (one ALREADY-OPEN PR it repairs), while `ai-drainer.sh` passes FOUR arguments — so
# `$WK` is the documented `bg` default and its brief is a multi-PR hygiene order that opens no PR.
# Rendering `prfix` unconditionally handed that drainer lane "Your PR is ALREADY OPEN", which is
# false about its situation — the untrue-order class #2148/#2325 exist to remove (caught in this
# PR's review, cycle 1).
# ⛔ NO SECOND COPY OF THE VOCABULARY. `$WK` was already narrowed to exactly `bg|prfix` by the closed
# vocabulary ~90 lines above (the `kind '$WK' is not bg or prfix` arm), so a `case` here could never
# reach a third branch — it would be an INERT enforcer that reads as protection. The role is the kind,
# and the ONE place that decides a role is valid is the helper's own `*)` arm below: it returns 2 for
# an unknown role, and the `|| exit 78` refuses the dispatch. Fail-closed in one home, not two.
NB_DELIVERY_ROLE="$WK"
# ⛔ THE HELPER IS RESOLVED THE WAY THIS FILE ALREADY RESOLVES `brief-gate.sh` ABOVE — NEVER FROM `$SELF`
# ALONE (review of #2981, P2). The `$O`-SKEW paragraph on the gate resolver is 30 lines up: "`$O` is
# seeded file by file, so a NEW dispatcher can run against an OLD `$O/spawn-gate.sh`", and that is why
# that resolver searches FOUR homes instead of pinning one. A `$SELF`-only pin here re-creates the
# class one screen below the comment that documents it: on a half-seeded `$O` (new
# `nonblocking-dispatch.sh`, helper not seeded beside it) EVERY dispatch on the box would exit 78 — a
# fleet that cannot dispatch, caused by the rule whose whole purpose is that a lane delivers
# something. Corpus precedent, same failure: `install.sh` on `brief-gate.sh` — "a $O copy that
# predates it makes every one of those refuse (78 = cannot verify) — a whole fleet that cannot
# dispatch". Nearest copy wins, so the executing script's own directory is still first, and STILL
# fail-closed if no home has it.
NB_DELIVERY_SH=""
for _rp in "$SELF/reviewer-preflight.sh" "${HARNESS:-}/reviewer-preflight.sh" "$O/reviewer-preflight.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/reviewer-preflight.sh" \
           "${HOME:-}/.pi/agent/scripts/orchestrator-harness/reviewer-preflight.sh"; do
  [ -n "$_rp" ] && [ -f "$_rp" ] && { NB_DELIVERY_SH="$_rp"; break; }
done
[ -n "$NB_DELIVERY_SH" ] || {
  echo "nonblocking-dispatch.sh: reviewer-preflight.sh not found (looked in $SELF, $O, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts/orchestrator-harness) — refusing to start a worker whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
NB_DELIVERY="$(bash "$NB_DELIVERY_SH" --delivery-brief "$NB_DELIVERY_ROLE")" || {
  echo "nonblocking-dispatch.sh: reviewer-preflight.sh --delivery-brief $NB_DELIVERY_ROLE failed — refusing to start a worker whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
NB_DELIVERY_HEADING="$(printf '%s\n' "$NB_DELIVERY" | head -1)"
[ -n "$NB_DELIVERY_HEADING" ] || {
  echo "nonblocking-dispatch.sh: reviewer-preflight.sh --delivery-brief rendered NOTHING — refusing to start a worker that would hold its work to the cap (#2981)" >&2; exit 78; }
# ⛔ THE HEADING ALONE IS NOT THE KEY (this PR's review, cycle 2 — P2). The heading is ROLE-INVARIANT:
# all three roles render it byte-identically, so a heading-only test calls a brief complete when it
# carries ANOTHER role's copy and leaves it alone. That collision is REACHABLE, not theoretical —
# `templates/LANE-BRIEF.md` is pinned to the `lane` render (it orders "Open the PR as soon as the first
# commit is pushed"), a controller authors its brief by copying that template, and `pr-doctor.py` then
# dispatches it as `prfix`: the heading matches, nothing is appended, and the worker is ordered to open
# a PR it ALREADY HAS — exactly the false-order class #2148/#2325 exist to remove, reached through the
# append path instead of the render path. So the key is the role's OWN PR sentence.
# ⛔ The sentence is taken from the render, never restated here (the ONE home rule): it is the first
# `- **` bullet of the section, and `reviewer-preflight.test.sh` §G.2b pins that order so a reordered
# bullet cannot silently make this read the wrong line. Here-string, not a pipe: no SIGPIPE (#841).
NB_DELIVERY_PR_LINE="$(awk '/^- \*\*/{print; exit}' <<<"$NB_DELIVERY")"
[ -n "$NB_DELIVERY_PR_LINE" ] || {
  echo "nonblocking-dispatch.sh: reviewer-preflight.sh --delivery-brief $NB_DELIVERY_ROLE rendered no PR sentence — refusing to start a worker whose PR duty cannot be verified (#2981)" >&2; exit 78; }
# A brief is already complete only when it carries the heading AND this role's own sentence. A brief
# that carries the heading but a FOREIGN role's sentence is appended to rather than refused, which is
# this path's stated policy (an otherwise complete authored brief must not become a dead dispatch).
# The already-correct case stays byte-for-byte untouched.
# ⛔ APPENDING IS NOT ENOUGH — THE STALE ORDER MUST BE MARKED SUPERSEDED (this PR's review, cycle 3,
# P2). Append-only left the worker holding BOTH orders: `pr-doctor.py` dispatching a template-derived
# brief as `prfix` yields "Open the PR as soon as the first commit is pushed" AND "Your PR is ALREADY
# OPEN". "The last word wins" was an ASSUMPTION about reading order that nothing enforced, and the
# surviving sentence is the false order #2148/#2325 exist to remove — the very sentence this file's
# own comment above calls out. So when the heading was ALREADY present (i.e. a foreign role's copy is
# above), a one-line supersession notice precedes the appended section. The stale bullet is NOT
# deleted: the append policy stands, and a brief is never rewritten under its author. The notice lands
# BEFORE the correct sentence, so the reader meets "this is superseded" and then the true order.
NB_DELIVERY_SUPERSEDE="⛔ THE COMMIT-AS-YOU-GO SECTION BELOW SUPERSEDES ANY COPY ABOVE THIS LINE — the copy above carries a DIFFERENT role's PR instruction, which does not describe your situation. Your PR duty is the one stated in the section below."
NB_DELIVERY_HAD_HEADING=0
# …and whether the notice was actually WRITTEN, which is a DIFFERENT question: the heading pre-exists
# on an already-correct brief too, so keying the post-condition on HAD_HEADING alone demanded a notice
# on a brief that needs none — the first cut of this fix refused every re-dispatch of a correct brief
# (caught by the suite's own idempotence arm, which is why that arm exists).
NB_DELIVERY_SUPERSEDE_DUE=0
grep -qF -- "$NB_DELIVERY_HEADING" "$PROMPT" 2>/dev/null && NB_DELIVERY_HAD_HEADING=1
if [ "$NB_DELIVERY_HAD_HEADING" -eq 0 ] \
   || ! grep -qF -- "$NB_DELIVERY_PR_LINE" "$PROMPT" 2>/dev/null; then
  if [ "$NB_DELIVERY_HAD_HEADING" -eq 1 ]; then
    NB_DELIVERY_SUPERSEDE_DUE=1
    printf '\n%s\n' "$NB_DELIVERY_SUPERSEDE" >> "$PROMPT" || {
      echo "nonblocking-dispatch.sh: could not mark the foreign-role COMMIT-AS-YOU-GO section superseded in $PROMPT — refusing to start a worker that would read a false PR order (#2981)" >&2; exit 78; }
  fi
  printf '\n%s\n' "$NB_DELIVERY" >> "$PROMPT" || {
    echo "nonblocking-dispatch.sh: could not append the COMMIT-AS-YOU-GO section to $PROMPT — refusing to start a worker that would hold its work to the cap (#2981)" >&2; exit 78; }
fi
# ⛔ AND THEN VERIFY IT LANDED. An append that reported success and wrote nothing is the exact shape
# this section exists to refuse, so the post-condition is asserted rather than assumed — and it is
# asserted on BOTH halves, because the heading check alone is the vacuous one this block just fixed.
grep -qF -- "$NB_DELIVERY_HEADING" "$PROMPT" \
  && grep -qF -- "$NB_DELIVERY_PR_LINE" "$PROMPT" || {
  echo "nonblocking-dispatch.sh: the brief at $PROMPT STILL lacks its COMMIT-AS-YOU-GO section (heading or the $NB_DELIVERY_ROLE PR sentence) after the append — refusing to start a worker that would hold its work to the cap (#2981)" >&2; exit 78; }
# …and a brief that HAD a foreign copy must now say so, or the post-condition above is satisfied while
# the false order is the first thing the worker reads. Keyed on SUPERSEDE_DUE, not HAD_HEADING: an
# already-correct brief carries the heading and owes NO notice. A marker that was never written must not
# read as written, and a marker that was never OWED must not be demanded.
if [ "$NB_DELIVERY_SUPERSEDE_DUE" -eq 1 ]; then
  grep -qF -- "$NB_DELIVERY_SUPERSEDE" "$PROMPT" || {
    echo "nonblocking-dispatch.sh: the brief at $PROMPT carried a FOREIGN-role COMMIT-AS-YOU-GO section and its supersession notice did not land — refusing to start a worker that would read a false PR order (#2981)" >&2; exit 78; }
fi
# ⛔ A DIFFERENT HATCH, DELIBERATELY UNTOUCHED: main-edits is a declared escape for writing to a main
# checkout, not a review bypass, and #2319 does not rule on it.
export AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 \
       SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
KIND="$WK"; TAG="$NAME"; export KIND TAG
# The kind is part of the durable stamp: a later reader asking "was this worker held by the creation
# gate?" is answering a question about the KIND, and reconstructing it from a prompt file is prose.

rm -f "$RC"
: > "$LOG"
printf 'name=%s\nworktree=%s\nbranch=%s\nkind=%s\nprompt=%s\nstarted=%s\ncap=%ss\n' \
  "$NAME" "$WT" "$(git -C "$WT" branch --show-current 2>/dev/null)" "$WK" "$PROMPT" \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$T" > "$STAMP"

cd "$WT" || exit 2
# The worker itself — backgrounded, NOT waited on. `trap '' HUP` + `disown` let it outlive the
# orchestrator that dispatched it; `<&-` closes stdin so it cannot steal the parent's tty input.
# ⛔ `exec >/dev/null 2>&1` IS LOAD-BEARING, NOT TIDINESS. Without it the worker INHERITS this
# script's stdout/stderr, so a caller that runs this script with its output CAPTURED (a pipe)
# blocks on EOF for the worker's ENTIRE LIFE, not for this script's exit: `subprocess.run(...
# capture_output=True)` measured 5.02 s for a 5 s worker vs 0.03 s non-captured. A "non-blocking"
# dispatcher that holds its caller for the length of the job is worse than a blocking one, because
# the caller believes it returned. run_agent writes everything it has to say to "$LOG", so
# nothing is lost by closing these.
( trap '' HUP
  # ⛔ RESOLVED BY UNION (#2045 rebase): main's `exec` redirection (see the block above) is kept
  # here, inside the PR's cap-marker block. Every write below is explicitly redirected to a
  # file, so closing these fds loses nothing.
  exec >/dev/null 2>&1
  run_agent "$T" "$LOG" "$PROMPT" "bg $NAME"
  rc=$?
  # ⛔ `.cap` BEFORE `.rc` (VGATE cycle 4, nit 1): `--status` reads `.rc` FIRST, so writing the exit
  # status before the note leaves a window in which a cap kill reads as a bare `failed rc=143` with
  # no explanation, and a test asserting the note could flake on it. In this order a status read sees
  # either "running" (no .rc yet) or a verdict WITH its note — never a verdict stripped of it.
  if [ "${AGENT_CAP_HIT:-0}" = "1" ]; then
    # ⛔ THE NOTE NAMES THE BOUND THAT ENDED THE WORKER (#2888 review, P2-5). `AGENT_CAP_HIT` now fires
    # on a PROGRESS kill too (verdict=stalled at ~the allowance), so restating this launcher's own
    # `$T` published `cap 7200s hit` over a worker the 2700 s progress rule killed — a false statement
    # about WHICH bound ended it, the defect class the same change fixed in `[timeout]`/`walltime.tsv`.
    # `AGENT_CAP_BOUND` is run_agent's measurement of the bound that actually fired; `$T` stays the
    # fallback for an `$O/spawn-gate.sh` older than this change (tolerant, like every other field here).
    _cap_s="${AGENT_CAP_BOUND:-$T}"
    case "${AGENT_BOUND_VERDICT:-}" in
      stalled)           _cap_why="PROGRESS bound (verdict=stalled) at ${_cap_s}s" ;;
      exceeded-wallclock) _cap_why="WALL backstop (verdict=exceeded-wallclock) at ${_cap_s}s" ;;
      '')                _cap_why="bound ${_cap_s}s" ;;
      *)                 _cap_why="bound ${_cap_s}s (verdict=${AGENT_BOUND_VERDICT})" ;;
    esac
    case "${WIP_SNAPSHOT_RESULT:-}" in
      COMPLETE)
        note="${_cap_why} — COMPLETE WIP snapshot: ${WIP_SNAPSHOT_DIR:-<unrecorded>}" ;;
      PARTIAL)
        # A PARTIAL snapshot is a rescue aid, NOT a licence to reap: say so here, where an operator
        # reads it, rather than only in the log (VGATE cycle 8, P2).
        note="${_cap_why} — PARTIAL WIP snapshot (INCOMPLETE: the worktree is still the only full copy, do NOT reap it): ${WIP_SNAPSHOT_DIR:-<unrecorded>}" ;;
      NOTHING-LOST)
        note="${_cap_why} — the worktree was CLEAN, nothing was lost" ;;
      *)
        note="${_cap_why} — WORK NOT PRESERVED (${WIP_SNAPSHOT_RESULT:-unknown}): it is still only in the worktree, so do NOT reap it. See $LOG" ;;
    esac
    printf 'cap_s=%s\nresult=%s\nsnapshot=%s\nnote=%s\n' "$_cap_s" "${WIP_SNAPSHOT_RESULT:-none}" "${WIP_SNAPSHOT_DIR:-}" "$note" > "$CAPF"
  fi
  # ⛔ `.end` BEFORE `.rc`, for the reason `.cap` is: `--status` reads `.rc` FIRST, so writing the
  # exit status first leaves a window in which a terminal report exists without the fate of the work.
  # ⛔ THE FIELDS COME FROM run_agent'S OWN MEASUREMENT (`terminal_wip_rescue`, #2834) — never from a
  # second reading here, which could disagree with the `[wip] end` line already in the lane's log.
  # TOLERANT ON PURPOSE: an `$O/spawn-gate.sh` older than #2834 sets none of these, and a missing
  # field must degrade to an absent field, never to a crash in a worker's exit path.
  printf 'rc=%s\ncap=%s\ntree=%s\nrescue=%s\nref=%s\nunpushed=%s\n' \
    "$rc" "${AGENT_CAP_HIT:-0}" "${LANE_END_TREE:-}" "${LANE_END_RESCUE:-}" \
    "${LANE_END_REF:-}" "${LANE_END_UNPUSHED:-0}" > "$ENDF"
  echo "$rc" > "$RC"
) <&- &
PID=$!
echo "$PID" > "$PIDF"
disown "$PID" 2>/dev/null || true

# Durable record, so a later session can see what was dispatched and when (and can find the exit
# status later via `--status`, rather than inferring it from a log tail).
mkdir -p "$O/state" "$D"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$NAME" "$(git branch --show-current 2>/dev/null)" "$PID" "$(date '+%H:%M:%S')" >> "$D/dispatch-log.tsv"

echo "launched $NAME  pid=$PID  branch=$(git branch --show-current 2>/dev/null)  cap=${T}s"
echo "  log:     $LOG"
echo "  status:  bash $0 --status $NAME"
echo "  worktree: $WT"
echo "NOTE: the review gate for this worker's PR is the PARENT's — gates=$GP_MODE ($([ "$GP_MODE" = enforced ] && echo 'enforced by the lane itself' || echo 'bypassed and audited under #2319')). Hand the PR to the chain when it appears:"
echo "  chain:   bash $HARNESS/chain-merge.sh <repo-path> <owner/repo> <issue> <branch>"
