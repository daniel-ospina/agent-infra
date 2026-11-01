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
# The worker it dispatches declares KIND=`prfix`, because this work IS the drain, not new work.
# ⛔ THAT KIND IS MEASURED, NOT EXEMPTED (review P2, 2026-11-01): only a worktree that provably IS an
# open PR at its HEAD earns the `prfix` exemption, and this one is detached at `origin/main` — so the
# ordinary landing-ratio gate decides, and a drain stall is precisely when that ratio is over the
# ceiling. The dispatch can therefore be HELD, and this script says which happened instead of
# assuming it (see "WHY ITS EXIT STATUS IS NOT THE VERDICT" at the dispatch).
#
# Bounded: one dispatch per DRAIN_STALL_FIX_EVERY stalled passes (default 3), so a
# stall that nobody fixes does not spawn a worker per cycle forever.
#
# Exit: 0 whatever happened to the dispatch (it is reported, never raised), 2 usage error.
set -uo pipefail

O="${O:-$HOME/orchestrator}"
SEEN="${1:-}"                       # the pass's stall counter (_dpass), from the loop
EVERY="${DRAIN_STALL_FIX_EVERY:-3}"
TIMEOUT="${DRAIN_STALL_FIX_TIMEOUT:-1800}"
UNOWNED="${UPN_WORK:-?}"
AGEMIN="${2:-?}"                    # minutes since the last land (or the threshold)

# ⛔ NOT `say` (agent-infra#2910). On macOS `say` is /usr/bin/say — text-to-speech — so a shipped
# script that defines a helper by that name SPEAKS through the owner's speakers whenever a fragment
# runner executes its body in a shell where the definition did not survive. The repo-wide rename
# chose `log_line`; `tests/no-tts/run.sh` re-reads the tree on every run and reddens this file if the
# old name ever comes back.
log_line() { printf '[dispatch] %s\n' "$*"; }

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
  log_line "DRAIN STALL -> stall fix skipped (pass counter 0 — not a stalled pass)"
  exit 0
fi
if ! is_num "${SEEN:-}"; then
  log_line "DRAIN STALL -> STALL FIX SKIPPED (no pass counter; not a number: '${SEEN}')"
  exit 0
fi

# Bounded: fire on the EVERY-th stalled pass only, so one stall == one worker.
if [ "$(( SEEN % EVERY ))" -ne 0 ]; then
  log_line "DRAIN STALL -> stall fix deferred (pass ${SEEN}, one dispatch per ${EVERY})"
  exit 0
fi

DISP="$O/nonblocking-dispatch.sh"
if [ ! -x "$DISP" ]; then
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (no executable $DISP) — the stall line is the only trace"
  exit 0
fi

BRIEF_DIR="$O/state/briefs"
mkdir -p "$BRIEF_DIR" 2>/dev/null || {
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (state/briefs is unwritable)"; exit 0; }
BRIEF="$BRIEF_DIR/stall-fix-$(date -u '+%Y%m%dT%H%M%SZ').md"

# The brief names only MEASURED facts it is handed, plus where to look. It must not
# tell the worker what the cause is: that is the finding it is dispatched to produce.
cat > "$BRIEF" <<'BRIEFEOF'
FIRST ACTION: write `__O__/state/REPORT-stall-fix.md` with a stub. **You are dispatched by a
stall escalation, not by a PR or an issue.** 30 minutes, then report even if unfinished.

⛔ **YOU OWN NO PR — AND THE "COMMIT AS YOU GO" SECTION APPENDED BELOW DOES NOT APPLY TO YOU.** This
brief is dispatched with the `prfix` kind because a stall repair is drain work, not new work. ⛔ That
kind is MEASURED, not exempted (see the `KIND=prfix` note in the dispatcher): the creation
back-pressure gate reads the landing ratio and can HOLD this dispatch on exactly the box that is
stalled. That decision is not yours and not the brief's — it happened before you were started, so if
you are reading this you were admitted. The kind's delivery section contributes the sentence *"Your PR
is ALREADY OPEN — commit and push onto it, and do NOT open a second PR"*, which describes a FIXER
working on an existing PR. It does not describe you. **You are READ-ONLY: do not commit, do not push,
do not open, re-open or touch any PR.** Your only output is `__O__/state/REPORT-stall-fix.md`. If the
two instructions conflict, this one governs.

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
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (brief could not be written)"
  exit 0
fi
# ⛔ AND THE SUBSTITUTION IS CHECKED, NOT ASSUMED: a failed write leaves the ORIGINAL file in place,
# which is NON-EMPTY and passes the size test above — so an unstubbed brief would be dispatched with
# `__SEEN__` still in it. A surviving placeholder is a brief that cannot be read correctly: refuse.
if grep -q '__\(AGEMIN\|UNOWNED\|SEEN\|O\|SPAWNS\)__' "$BRIEF" 2>/dev/null; then
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (brief still carries unresolved placeholders — not dispatching a worker on it)"
  exit 0
fi

# KIND=prfix — A MEASUREMENT, NOT AN EXEMPTION (review P2, 2026-11-01: this comment used to say the
# creation gate "exempts" a stall repair, which spawn-gate.sh denies). `prfix` is exempt ONLY on proof
# that this worktree IS an open PR at this HEAD (`spawn-gate.sh:1989-1993`, via
# `land_backlog_open_pr_evidence`), and a DETACHED worktree at `origin/main` can never produce that
# proof (`:1970-1978`: the branch rule is skipped because `rev-parse --abbrev-ref HEAD` is `HEAD`, and
# no open PR's head is main's tip). So this KIND falls through to the ordinary landing-ratio
# measurement (`:1994-2005`) — and a drain stall IS the state where that ratio is over the ceiling.
# ⇒ The creation back-pressure gate CAN legitimately HOLD this dispatch, and it is most likely to fire
# on exactly the box this escalation exists for. That is stated rather than denied, and it is not
# hidden from the operator: the hold writes `[land-backlog] REFUSED …` to the worker's own log, which
# the verdict reader below prints as `STALL FIX NOT DISPATCHED` WITH the gate's own line quoted.
# An exempt `stallfix` KIND would make the escalation unconditional, but that is a change to the #2409
# gate's own deny-list — not something this file may grant itself, and not something this fix assumes.
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
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (no usable worktree: $WT — set HARNESS_REPO)"
  exit 0
fi
# ── THE DISPATCH — AND WHY ITS EXIT STATUS IS NOT THE VERDICT ─────────────────────────────────────
# ⛔ A REFUSED SPAWN MUST NOT READ AS A DISPATCHED ONE (review P1, 2026-11-01).
# `nonblocking-dispatch.sh` runs `run_agent` — and with it EVERY spawn gate — inside a backgrounded
# subshell with `exec >/dev/null 2>&1` (`nonblocking-dispatch.sh:328-331`), and its own header says
# what that means verbatim: a refusal raised in there "would leave no trace in this caller's output
# and the dispatcher would report a launch that never happened" (`:124-128`). The script then ends on
# plain `echo`s (`:375-381`) with no `exit`, so it RETURNS 0 once it reaches the launch — whether an
# agent started or the load / disk / fork / land-backlog / capability gate refused it. Reading that 0
# as "a worker started" is the exact false-success this file's own contract forbids, and it is not
# hypothetical: the `[land-backlog]` gate is the one MOST likely to fire here, because a drain stall
# is the state it measures (see the KIND=prfix note above).
#
# So the verdict is READ FROM EVIDENCE the dispatcher already publishes, never inferred from its rc:
#   * `$O/bg/<name>.log`      — `run_agent` writes `[<gate>] REFUSED …` there for every gate refusal;
#   * `$O/bg/<name>.rc`       — written by the worker subshell when `run_agent` RETURNS: an agent ran;
#   * `$O/bg/<name>.pid`      — the launch pid, live while the worker runs;
#   * `~/.pi/agent/state/spawn-gate.tsv` — the spawn point's own append-only ledger, one row per `pi`
#     invocation carrying `verdict` (`allowed`|`refused`), `KIND` and `TAG` (= this worker's name).
#     An `allowed` row for THIS TAG is the one POSITIVE PROOF an agent started, so it is preferred
#     where the pi shim is installed; a box without the shim falls back to the record above.
# The read is BOUNDED (`STALL_FIX_VERIFY_SECS`): the gates run a beat AFTER the launch returns, so the
# record APPEARS rather than being there at the instant of return.
NAME="stallfix-$(date -u '+%H%M%S')"
BGD="$O/bg"; BLOG="$BGD/$NAME.log"; BRC="$BGD/$NAME.rc"; BPID="$BGD/$NAME.pid"
LG="${HOME:-}/.pi/agent/state/spawn-gate.tsv"
# The ledger is APPEND-ONLY and shared by every spawn on the box, so the byte offset taken BEFORE the
# launch is what stops a row from an earlier worker (or an earlier run of the same name) answering for
# THIS one. `tr -cd 0-9` because `wc -c` pads its number on some platforms, and an unreadable offset
# must degrade to 0 (whole file) rather than to an arithmetic error under `set -u`.
_lgoff=0
[ -f "$LG" ] && _lgoff="$(wc -c < "$LG" 2>/dev/null | tr -cd '0-9')"
is_num "${_lgoff:-}" || _lgoff=0

# spawn_row <allowed|refused> — did THIS launch write such a row? The awk reads to EOF (no early
# `exit` in the rule) so a slow writer cannot SIGPIPE the reader.
spawn_row() {
  [ -f "$LG" ] || return 1
  tail -c "+$(( _lgoff + 1 ))" "$LG" 2>/dev/null \
    | awk -F'\t' -v want="$1" -v tag="$NAME" '$2 == want && $8 == tag { found = 1 } END { exit(found ? 0 : 1) }'
}
# gate_refusal — the FIRST gate refusal `run_agent` wrote for this worker, verbatim (empty if none).
gate_refusal() {
  [ -f "$BLOG" ] || return 0
  awk '/REFUSED/ { print; exit }' "$BLOG" 2>/dev/null
}

_launch=0
KIND=prfix "$DISP" "$NAME" "$WT" "$BRIEF" "$TIMEOUT" prfix >>"$O/logs/stall-fix.log" 2>&1 || _launch=$?

_verdict="unproven"; _vmax="${STALL_FIX_VERIFY_SECS:-10}"; _vwaited=0; _bpid=""
if [ "$_launch" -ne 0 ]; then
  # A NON-ZERO EXIT IS A FOREGROUND REFUSAL (usage 2, brief-gate 80, missing helper/gate-policy 78, a
  # `cd` failure): the dispatcher refused BEFORE it forked, so nothing was launched and no worker
  # record exists. Its remedy text is on this script's own stderr, not the worker log.
  _verdict="failed"
else
  is_num "${_vmax:-}" && [ "$_vmax" -ge 1 ] || _vmax=10
  [ "$_vmax" -gt 120 ] && _vmax=120
  while :; do
    if spawn_row refused; then _verdict=refused; break; fi
    if spawn_row allowed; then _verdict=started; break; fi
    if [ -n "$(gate_refusal)" ]; then _verdict=refused; break; fi
    if [ -s "$BRC" ]; then _verdict=ended; break; fi
    if [ "$_vwaited" -ge "$_vmax" ]; then
      _bpid="$(cat "$BPID" 2>/dev/null || true)"
      is_num "${_bpid:-}" && kill -0 "$_bpid" 2>/dev/null && _verdict=running
      break
    fi
    sleep 1; _vwaited=$(( _vwaited + 1 ))
  done
fi
# One writer for the durable row, so no verdict can be recorded without the sentence that produced it.
_record() {
  printf '%s\t%s\tpass=%s\tunowned=%s\tage_min=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$SEEN" "$UNOWNED" "$AGEMIN" >> "$O/state/drain-stall-dispatch.log" 2>/dev/null
}

case "$_verdict" in
  started)
    log_line "DRAIN STALL -> STALL FIX DISPATCHED (pass ${SEEN}; spawn-gate ledger: allowed TAG=$NAME; brief ${BRIEF#$O/}; report $O/state/REPORT-stall-fix.md)"
    _record "stall-fix dispatched"
    exit 0 ;;
  running)
    # The pid is alive and nothing refused, but this box published no spawn-gate row either (the pi
    # shim is a per-box install). Say exactly that: a live process is not proof an AGENT started, and
    # claiming one would be the same fail-open in a narrower window.
    log_line "DRAIN STALL -> STALL FIX LAUNCH ACCEPTED, AGENT START UNPROVEN (pass ${SEEN}; worker pid ${_bpid:-?} is alive but no spawn-gate ledger row for TAG=$NAME and no refusal within ${_vmax}s — the pi spawn-point ledger may not be installed on this box; brief ${BRIEF#$O/}; worker log $BLOG)"
    _record "stall-fix launch-accepted (agent start unproven)"
    exit 0 ;;
  refused)
    _g="$(gate_refusal)"
    log_line "DRAIN STALL -> STALL FIX NOT DISPATCHED (a spawn gate REFUSED this worker, so the box is STILL STALLED): ${_g:-<refusal recorded in the spawn-gate ledger for TAG=$NAME; run: bash $DISP --status $NAME>} — worker log $BLOG"
    _record "stall-fix NOT DISPATCHED (spawn refused)"
    exit 0 ;;
  ended)
    _rc="$(cat "$BRC" 2>/dev/null || true)"
    log_line "DRAIN STALL -> STALL FIX RAN AND ALREADY ENDED (pass ${SEEN}; rc=${_rc:-?}) — it DID start, so its report may exist: $O/state/REPORT-stall-fix.md; worker log $BLOG"
    _record "stall-fix ran-and-ended rc=${_rc:-?}"
    exit 0 ;;
  failed)
    # `nonblocking-dispatch.sh`'s own refusal text went to this script's stderr (`$O/logs/stall-fix.log`
    # when the controller runs it), and any worker-side refusal to `$BLOG`. Name BOTH: the old message
    # pointed only at the first, which is where a gate refusal is NOT written.
    log_line "DRAIN STALL -> STALL FIX DISPATCH FAILED (nonblocking-dispatch.sh refused before launching, exit ${_launch}; see $O/logs/stall-fix.log and $BLOG) — the box is still stalled"
    _record "stall-fix DISPATCH FAILED (exit ${_launch})"
    exit 0 ;;
  *)
    log_line "DRAIN STALL -> STALL FIX DISPATCH UNPROVEN (pass ${SEEN}; no pid, no exit status, no refusal and no spawn-gate ledger row appeared within ${_vmax}s, so nothing here proves a worker started; brief ${BRIEF#$O/}; worker log $BLOG) — the box is still stalled"
    _record "stall-fix dispatch unproven"
    exit 0 ;;
esac
