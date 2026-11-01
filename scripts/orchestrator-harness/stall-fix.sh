#!/usr/bin/env bash
# stall-fix.sh — LOUD escalation that DISPATCHES a worker on the land problem.
#
# ⛔ WHY (owner decision, 2026-10-27). The controller's deadlock arm used to only
# PRINT: `[dispatch] DRAIN DEADLOCK — no PR merged in Nm … and this pass STARTED NO
# WORKER`. It was printed 8 times on a live box that sat at `lanes=0` for 3.4h, and
# the escalation record existed too — and nothing was ever done about the stall
# itself. Measured 2026-10-27 on this Mac: 18 open PRs, 16 un-owned, the PR path
# spawned nothing for pass after pass, the issue path was closed by merge-priority,
# and the box held capacity it never used. The owner's ruling for that state is:
# the issue path MAY open (the #2832 escape), but the stall must ALSO put a worker
# on the land problem — so the box cannot report a deadlock into a void.
#
# The worker it dispatches is a `prfix` (KIND), which the creation back-pressure
# gate lets through — because this work IS the drain, not new work.
#
# Bounded: one dispatch per DRAIN_STALL_FIX_EVERY stalled passes (default 3), so a
# stall that nobody fixes does not spawn a worker per cycle forever.
#
# Exit: 0 dispatched or deliberately skipped (with a reason), 2 usage error.
set -uo pipefail

O="${O:-$HOME/orchestrator}"
SEEN="${1:-}"                       # the pass's stall counter (_dpass), from the loop
EVERY="${DRAIN_STALL_FIX_EVERY:-3}"
TIMEOUT="${DRAIN_STALL_FIX_TIMEOUT:-1800}"
UNOWNED="${UPN_WORK:-?}"
AGEMIN="${2:-?}"                    # minutes since the last land (or the threshold)

say() { printf '[dispatch] %s\n' "$*"; }

# ⛔ THE TIGHT FORM, NOT A LENIENT FIFTH (selftest.sh "ONE PREDICATE, EVERY SHIPPED COPY"): the
# `''|*[!0-9]*` form ACCEPTS `08`, and `$(( SEEN % EVERY ))` below then reads it as invalid OCTAL and
# errors — so the bound would be neither applied nor refused. Rejecting leading zeros is what makes
# that arithmetic safe, so this copy has to AGREE with orch-loop.sh's, not merely look like it.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ >= 1, NOT merely numeric: `is_num 0` passes, `$(( SEEN % 0 ))` errors and the
# guard then FELL THROUGH to dispatch (verifier, 2026-10-27). A bound of zero is not
# a bound.
is_num "$EVERY" && [ "$EVERY" -ge 1 ] || EVERY=3
is_num "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || TIMEOUT=1800
# ⛔ A PASS COUNTER OF 0 IS NOT "THE ZEROTH STALL": the caller sets it only inside the stall
# arm, so 0 means the caller is on a healthy pass (or passed it through a default). Refusing
# here as well makes the bound hold even if a future call site forgets the gate.
if [ "${SEEN:-0}" = "0" ]; then
  say "DRAIN STALL -> stall fix skipped (pass counter 0 — not a stalled pass)"
  exit 0
fi
if ! is_num "${SEEN:-}"; then
  say "DRAIN STALL -> STALL FIX SKIPPED (no pass counter; not a number: '${SEEN}')"
  exit 0
fi

# Bounded: fire on the EVERY-th stalled pass only, so one stall == one worker.
if [ "$(( SEEN % EVERY ))" -ne 0 ]; then
  say "DRAIN STALL -> stall fix deferred (pass ${SEEN}, one dispatch per ${EVERY})"
  exit 0
fi

DISP="$O/nonblocking-dispatch.sh"
if [ ! -x "$DISP" ]; then
  say "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (no executable $DISP) — the stall line is the only trace"
  exit 0
fi

BRIEF_DIR="$O/state/briefs"
mkdir -p "$BRIEF_DIR" 2>/dev/null || {
  say "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (state/briefs is unwritable)"; exit 0; }
BRIEF="$BRIEF_DIR/stall-fix-$(date -u '+%Y%m%dT%H%M%SZ').md"

# The brief names only MEASURED facts it is handed, plus where to look. It must not
# tell the worker what the cause is: that is the finding it is dispatched to produce.
cat > "$BRIEF" <<'BRIEFEOF'
FIRST ACTION: write `__O__/state/REPORT-stall-fix.md` with a stub. **You are dispatched by a
stall escalation, not by a PR or an issue.** 30 minutes, then report even if unfinished.

⛔ **YOU OWN NO PR — AND THE "COMMIT AS YOU GO" SECTION APPENDED BELOW DOES NOT APPLY TO YOU.** This
brief is dispatched with the `prfix` kind for ONE reason: the creation back-pressure gate exempts a
stall repair as `prfix`. That kind's delivery section contributes the sentence *"Your PR is ALREADY
OPEN — commit and push onto it, and do NOT open a second PR"*, which describes a FIXER working on an
existing PR. It does not describe you. **You are READ-ONLY: do not commit, do not push, do not open,
re-open or touch any PR.** Your only output is `__O__/state/REPORT-stall-fix.md`. If the two
instructions conflict, this one governs.

## Why you exist

The controller reported a DRAIN STALL: **no PR merged in __AGEMIN__ minutes** while
**__UNOWNED__ un-owned PR(s)** remain, and **__SPAWNS__**. The issue path is
held closed by merge-priority (un-owned PRs first), so the box is holding capacity it is not using.
That has now happened for __SEEN__ consecutive stalled passes.

## Your job: find out WHY nothing lands, and say it with evidence

Work read-only against the runtime. Do **not** change dispatch policy, do not edit the controller,
do not merge anything.

1. `tail -40 __O__/logs/orch-loop.log` — quote the last `[pr] PR path` line and the
   `[select]` line. The usual named reasons are: rows "outside this cycle's sweep window"
   (window=K/cycle rotating), "a worker already owns this PR", or a check-surface read failure.
   **Which reason dominates, and is the window the real cause or a symptom?**
2. `__O__/state/prdisp.tsv` and `__O__/state/spawn-refused.tsv` — what did the PR path actually do, per
   row, and what did the spawn gate refuse?
3. Is any worker alive? (`ls __O__/bg/*.pid`, and for each pid `ps -p <pid>`). A "worker already owns
   this PR" reason whose owner pid is dead is a phantom-ownership bug, not a wait.
4. If you find the cause, **do not fix it here** — write it to the report as
   `file:line — what is wrong — the narrowest change that would fix it`, so a fix can be dispatched
   against it.

## RESEARCH FIRST — before you decide anything (agent-infra#2258)

INTERNAL: read what THIS box already holds before concluding anything — `logs/orch-loop.log` (the
`[pr] PR path`, `[select]` and `[dispatch]` lines), `state/prdisp.tsv`, `state/spawn-refused.tsv`,
`state/drain-stall`, and the live pid files in `bg/`. The root cause is almost certainly already
recorded there; re-deriving it from the code without reading these is the defect this pass exists to
prevent.

EXTERNAL: if the reason turns out to be a pattern rather than a specific wait (e.g. queue starvation
under a strict priority rule), look outside for how comparable dispatchers handle it — and say what
you took from it. Use the `research` skill.

RUNG: 3 — `web_fetch` / exa (`mcp_load exa`); the diagnosis is INTERNAL and needs no external search,
so run rung 3 only if a pattern question arises. Name the rung you actually took; if it does not
load, name the error — a silent fallback erases the config gap.

CONTRADICTION TEST: the owner decision of **2026-10-27** (option 1 on the drain-deadlock decision)
covers this work: the issue path MAY open and the stall must ALSO put a worker on the land problem.
The 2026-10-18 ruling — "a stalled drain is a land/capacity problem and opening new work is how it
gets hidden; the escalation must never grow a release valve" — is NOT reversed here: you are
dispatched to DIAGNOSE the land problem, not to open new work or change dispatch policy. If your
finding contradicts either, record it and stop; do not adopt over it.

## Report

`__O__/state/REPORT-stall-fix.md`: the dominant named reason (verbatim), whether it is a real wait or a
phantom owner, the evidence command per claim, and the narrowest fix. If the stall is genuinely
capacity-shaped, say that instead, with the measurement.
BRIEFEOF

# ⛔ AN UNMEASURED COUNT MUST NOT BECOME A MEASURED CLAIM (the loop refuses the same
# thing at orch-loop.sh "an unmeasured count must not carry a positive diagnosis"). If
# PRDISP_SPAWNS is empty we do NOT know whether workers ran, so the brief says so.
if ! is_num "${PRDISP_SPAWNS:-}"; then
  SPAWNS_TXT="the spawn count is UNMEASURED this pass (it could not be read)"
elif [ "${PRDISP_SPAWNS:-0}" -gt 0 ]; then
  SPAWNS_TXT="this pass started ${PRDISP_SPAWNS} worker(s) and still nothing landed"
else
  SPAWNS_TXT="this pass started no worker at all"
fi
# ⛔ THE VALUES ARE SUBSTITUTED, NOT INTERPOLATED: an UNQUOTED heredoc runs the body through the
# shell, so every backticked path in this brief was executed as a command and the text arrived
# mangled (measured 2026-10-27: "logs/orch-loop.log: No such file or directory" three times, and a
# lane dispatched on a corrupted brief). Quote the heredoc, keep placeholders, substitute here.
# ⛔ AND SUBSTITUTED IN BASH, NOT WITH `sed -i ''` (portability trap `sed-in-place-bsd`, the SILENT
# kind: a BSD-only `-i ''` edits NOTHING under GNU sed, so a cell would dispatch a worker on a brief
# full of `__AGEMIN__` placeholders). Parameter expansion is also the SAFER substitution — `&` and `|`
# are literal here and special inside a sed script.
_brief="$(cat "$BRIEF" 2>/dev/null || true)"
_brief="${_brief//__AGEMIN__/$AGEMIN}"
_brief="${_brief//__UNOWNED__/$UNOWNED}"
_brief="${_brief//__SEEN__/$SEEN}"
_brief="${_brief//__O__/$O}"
_brief="${_brief//__SPAWNS__/$SPAWNS_TXT}"
printf '%s\n' "$_brief" > "$BRIEF" 2>/dev/null || true
if [ ! -s "$BRIEF" ]; then
  say "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (brief could not be written)"
  exit 0
fi
# ⛔ AND THE SUBSTITUTION IS CHECKED, NOT ASSUMED: a failed write leaves the ORIGINAL file in place,
# which is NON-EMPTY and passes the size test above — so an unstubbed brief would be dispatched with
# `__SEEN__` still in it. A surviving placeholder is a brief that cannot be read correctly: refuse.
if grep -q '__\(AGEMIN\|UNOWNED\|SEEN\|O\|SPAWNS\)__' "$BRIEF" 2>/dev/null; then
  say "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (brief still carries unresolved placeholders — not dispatching a worker on it)"
  exit 0
fi

# KIND=prfix: the creation gate exempts it because the product of this worker IS the
# drain (spawn-gate.sh §"prfix EXISTS BECAUSE KIND IS NOT A CREATION/REPAIR DISCRIMINATOR").
# ⛔ A WORKER NEEDS A REAL GIT WORKTREE, NOT $O. Measured 2026-10-27: passing the
# runtime dir got `[land-backlog] REFUSED … UNREADABLE repo — this worktree's origin
# is not a GitHub owner/name slug`, and the worker died in 1s with rc=74. So the
# stall fix runs in its own worktree of the harness repo (throwaway, detached).
WT="${STALL_FIX_WORKTREE:-$O/state/wt-stallfix}"
HREPO="${HARNESS_REPO:-$HOME/ai-harness-main}"
if [ ! -e "$WT/.git" ] && [ -e "$HREPO/.git" ]; then
  git -C "$HREPO" worktree add -f --detach "$WT" origin/main >/dev/null 2>&1 || true
fi
if [ ! -e "$WT/.git" ]; then
  say "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (no usable worktree: $WT — set HARNESS_REPO)"
  exit 0
fi
if KIND=prfix "$DISP" "stallfix-$(date -u '+%H%M%S')" "$WT" "$BRIEF" "$TIMEOUT" prfix >>"$O/logs/stall-fix.log" 2>&1; then
  say "DRAIN STALL -> STALL FIX DISPATCHED (pass ${SEEN}; brief ${BRIEF#$O/}; report $O/state/REPORT-stall-fix.md)"
  printf '%s\tstall-fix dispatched\tpass=%s\tunowned=%s\tage_min=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SEEN" "$UNOWNED" "$AGEMIN" >> "$O/state/drain-stall-dispatch.log" 2>/dev/null
  exit 0
fi

# ⛔ A FAILED DISPATCH IS LOUD TOO: a stall escalation that cannot start a worker must
# not read as one that did.
say "DRAIN STALL -> STALL FIX DISPATCH FAILED (nonblocking-dispatch.sh refused; see $O/logs/stall-fix.log) — the box is still stalled"
printf '%s\tstall-fix DISPATCH FAILED\tpass=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SEEN" >> "$O/state/drain-stall-dispatch.log" 2>/dev/null
exit 0
