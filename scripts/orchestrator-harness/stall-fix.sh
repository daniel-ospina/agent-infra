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
# Exit: 0 whatever happened to the dispatch (it is reported, never raised).
# ⛔ NO USAGE PATH (review P3, 2026-11-02): this file used to advertise "2 usage error" while having no
# argument parser at all — a claim nothing could produce. Every input degrades to a skip or a default;
# `2` is never returned, and the dispatcher's OWN `2` is reported, never raised (see the verdict arm).
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
# ⛔ BOTH SINKS THIS SCRIPT OPENS ARE BOUNDED (review P3, 2026-11-02). Nothing else in the tree prunes
# them: `state/briefs/` had no production writer before this script, and no reaper names either file.
# Measured from the knobs: `CYC=240`s ⇒ a stalled pass every ~4 min ⇒ one dispatch per
# `DRAIN_STALL_FIX_EVERY=3` ⇒ ~120 brief files/day, unbounded, on exactly the population this
# escalation exists for (a box stalled for hours or days), in the directory the controller `find`s
# over. "A device that fills silently is the defect #1765 exists for" — the same rule `pi_gate_ledger`
# enforces with its own cap, and the same one-generation rotation (the series an operator reads after
# an incident is the last two). The cap is a module constant, not an env knob: the size of a ledger
# is not a policy a caller should be able to lift. The brief bound is a knob because retention is.
STALL_FIX_LEDGER_MAX_BYTES=5242880
STALL_FIX_BRIEF_MAX_AGE_MIN="${STALL_FIX_BRIEF_MAX_AGE_MIN:-1440}"
# ⛔ `-mmin +N`, NOT `-mmin -N` (fresh-context review, 2026-11-02). The mechanism this clamp protects
# is NOT the one a selection window uses: `+N` means "older than N minutes" — an eviction bound. `-N`
# means "newer than N", and `-mmin -0` matches NOTHING. So the trap here is the opposite polarity:
# an UNCLAMPED `0` collapses retention to "older than a full minute" and evicts every previous
# brief, and a NON-NUMERIC bound makes `find` fail, which (under the `|| true`) prunes nothing at all
# — the unbounded sink silently returns. Both are refused by the clamps below.
is_num "$STALL_FIX_BRIEF_MAX_AGE_MIN" && [ "$STALL_FIX_BRIEF_MAX_AGE_MIN" -ge 1 ] || STALL_FIX_BRIEF_MAX_AGE_MIN=1440
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
# Prune BEFORE minting the new brief, and only this script's own files (`stall-fix-*.md`, not the whole
# directory — another writer may legitimately share it). `-mmin +N` is "older than N minutes"; it is
# the correct polarity for eviction and cannot be confused with the `-mmin -N` selection window. The
# bound is enforced on every dispatch the script actually makes, which is the only cadence that can
# create the files — no dependency on an hourly reaper existing on the box.
find "$BRIEF_DIR" -maxdepth 1 -type f -name 'stall-fix-*.md' \
  -mmin "+$STALL_FIX_BRIEF_MAX_AGE_MIN" -exec rm -f {} + 2>/dev/null || true
BRIEF="$BRIEF_DIR/stall-fix-$(date -u '+%Y%m%dT%H%M%SZ').md"
# ⛔ THE WORKER'S NAME — AND ITS OWN REPORT PATH — ARE MINTED HERE, BEFORE THE BRIEF (review P1,
# 2026-11-01). The dispatch is bounded by DRAIN_STALL_FIX_EVERY stalled PASSES (default 3, i.e. one
# every ~12 min), while each worker is given 1800 s — so an unfixed stall normally has TWO OR THREE
# workers alive at once, and a single hard-coded `state/REPORT-stall-fix.md` meant the newest worker's
# mandated FIRST ACTION (write a stub there) TRUNCATED the report the previous worker exists to
# produce. Silent destruction of the only artifact the escalation buys. One report path per dispatch
# makes concurrent workers independent instead of destructive; the log line names the file.
NAME="stallfix-$(date -u '+%Y%m%dT%H%M%SZ')"
REPORTF="$O/state/REPORT-stall-fix-$NAME.md"
BGD="$O/bg"; BLOG="$BGD/$NAME.log"; BRC="$BGD/$NAME.rc"; BPID="$BGD/$NAME.pid"

# The brief names only MEASURED facts it is handed, plus where to look. It must not
# tell the worker what the cause is: that is the finding it is dispatched to produce.
cat > "$BRIEF" <<'BRIEFEOF'
FIRST ACTION: write `__REPORT__` with a stub. **You are dispatched by a
stall escalation, not by a PR or an issue.** 30 minutes, then report even if unfinished.

⛔ **YOU OWN NO PR — AND THE "COMMIT AS YOU GO" SECTION APPENDED BELOW DOES NOT APPLY TO YOU.** This
brief is dispatched with the `prfix` kind because a stall repair is drain work, not new work. ⛔ That
kind is MEASURED, not exempted (see the `KIND=prfix` note in the dispatcher): the creation
back-pressure gate reads the landing ratio and can HOLD this dispatch on exactly the box that is
stalled. That decision is not yours and not the brief's — it happened before you were started, so if
you are reading this you were admitted. The kind's delivery section contributes the sentence *"Your PR
is ALREADY OPEN — commit and push onto it, and do NOT open a second PR"*, which describes a FIXER
working on an existing PR. It does not describe you. **You are READ-ONLY: do not commit, do not push,
do not open, re-open or touch any PR.** Your only output is `__REPORT__`. If the
two instructions conflict, this one governs.

## Why you exist

The controller reported a DRAIN STALL: **no PR merged in __AGEMIN__ minutes** while
**__UNOWNED__ un-owned PR(s)** remain, and **__SPAWNS__**. The issue path is
held closed by merge-priority (un-owned PRs first), so the box is holding capacity it is not using.
That has now happened for __SEEN__ consecutive stalled passes.

⛔ **CITE THE COMMIT YOU READ.** The tree you are in was checked out at **`__WTSHA__`**. Put that
commit in your report beside every `file:line` claim (or quote it once at the top and say all
citations are at it). Another dispatch may refresh this tree while you run, so a line number quoted
without its commit cannot be checked later — and a report nobody can check is not evidence.

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

`__REPORT__`: the dominant named reason (verbatim), whether it is a real wait or a
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
_brief="${_brief//__REPORT__/$REPORTF}"
_brief="${_brief//__WTSHA__/${_wtsha:-UNKNOWN}}"
_brief="${_brief//__SPAWNS__/$SPAWNS_TXT}"
printf '%s\n' "$_brief" > "$BRIEF" 2>/dev/null || true
if [ ! -s "$BRIEF" ]; then
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (brief could not be written)"
  exit 0
fi
# ⛔ AND THE SUBSTITUTION IS CHECKED, NOT ASSUMED: a failed write leaves the ORIGINAL file in place,
# which is NON-EMPTY and passes the size test above — so an unstubbed brief would be dispatched with
# `__SEEN__` still in it. A surviving placeholder is a brief that cannot be read correctly: refuse.
if grep -q '__\(AGEMIN\|UNOWNED\|SEEN\|O\|SPAWNS\|REPORT\|WTSHA\)__' "$BRIEF" 2>/dev/null; then
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
# ⛔ NEVER RE-POINT THE TREE UNDER A LIVE WORKER (fresh-context review, 2026-11-02, P2). The refresh
# below fixed a FROZEN base; a single shared `$WT` refreshed on EVERY dispatch is the same defect
# inverted. This file's own note (see the report-path comment) records that an unfixed stall normally
# has TWO OR THREE workers alive at once — one dispatch per ~12 min, worker timeout 1800 s — so the
# second dispatch `git checkout`ed the tree the first worker was still reading. That worker's brief
# orders it to report `file:line — what is wrong`, and those citations are what a repair lane acts on:
# a report mixing two commits is unattributable, and nothing in it named the commit it read.
#
# ⛔ THE LIVENESS READ IS BENIGN IN BOTH DIRECTIONS, WHICH IS WHY IT IS SAFE HERE. A wrong "in use"
# only DEFERS the refresh — the worker gets the tree from the previous dispatch (at most ~12 min old)
# instead of one frozen for days, and the dispatch still HAPPENS. A wrong "free" is the only way to
# re-point a live tree, and it needs a worker that is running with no `.pid` AND no `.rc`, which the
# dispatcher always writes. Compare this with the alternative — skipping the DISPATCH while a worker
# runs — whose inference error would silence the escalation entirely, the inert-enforcer class.
wt_in_use() {
  local p live
  for p in "$O/bg"/stallfix-*.pid; do
    [ -f "$p" ] || continue
    [ -f "${p%.pid}.rc" ] && continue      # a terminal record means THAT worker is done
    live="$(cat "$p" 2>/dev/null || true)"
    is_num "${live:-}" && kill -0 "$live" 2>/dev/null && return 0
  done
  return 1
}
# ⛔ A THROWAWAY WORKTREE IS NOT A ONE-TIME WORKTREE (fresh-context review, 2026-11-02). It was
# created ONCE and then reused by every later dispatch, pinned to `$HREPO`'s LOCAL `origin/main` as of
# the FIRST stall — while this escalation keeps firing every `DRAIN_STALL_FIX_EVERY` stalled passes.
# The brief orders the worker to report `file:line — what is wrong`, so a box stalled for days would
# get line numbers resolved against a frozen tree, and those reports are what a repair lane acts on.
# This is the "stale flag that records a past state and is never revalidated" class. Refresh the base
# on EVERY dispatch, and name the commit so a report's provenance is checkable.
if [ -e "$HREPO/.git" ]; then
  if [ ! -e "$WT/.git" ]; then
    git -C "$HREPO" worktree add -f --detach "$WT" origin/main >/dev/null 2>&1 || true
  elif wt_in_use; then
    # A worker is still reading this tree — leave it exactly where it is and report that commit.
    :
  else
    # The BASE is $HREPO's own `origin/main`, not the worktree's copy of it: after a failed fetch (an
    # offline box, a moved remote) the local tracking ref is still newer than a checkout pinned days
    # ago, and it is the same ref the `worktree add` arm above resolves. Refresh from it either way.
    git -C "$HREPO" fetch -q origin main >/dev/null 2>&1 || true
    _base="$(git -C "$HREPO" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)"
    [ -n "$_base" ] && git -C "$WT" checkout -q --detach "$_base" >/dev/null 2>&1 || true
  fi
fi
if [ ! -e "$WT/.git" ]; then
  log_line "DRAIN STALL -> STALL FIX COULD NOT DISPATCH (no usable worktree: $WT — set HARNESS_REPO)"
  exit 0
fi
# The tree the worker actually reads. Printed in every dispatch line below, and substituted into the
# brief as `__WTSHA__`: a report resolved against an unnamed commit cannot be checked, so the commit
# has to travel WITH the report rather than only in a log line an operator may never read. An empty
# value is reported as UNKNOWN rather than guessed.
_wtsha="$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || true)"
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
# ⛔ THE NAME IS DATE-STAMPED, AND ITS RECORDS ARE CLEARED BEFORE THE LAUNCH (review P2, 2026-11-01).
# `%H%M%S` repeats every 24 h, so a previous day's `stallfix-<HHMMSS>.rc` could answer for THIS worker —
# and the verdict loop tests `-s "$BRC"` BEFORE it probes the pid, so a stale .rc produced
# "RAN AND ALREADY ENDED … it DID start" with no evidence about this launch (a fail-open), while a stale
# .log holding `REFUSED` produced a false "NOT DISPATCHED". Both directions are closed by the two lines
# below: a name that cannot repeat within a box's lifetime (minted with the brief, above), and records
# that cannot outlive their own dispatch.
rm -f "$BLOG" "$BRC" "$BPID"
# The ledger is APPEND-ONLY and shared by every spawn on the box, so the byte offset taken BEFORE the
# launch is what stops a row from an earlier worker (or an earlier run of the same name) answering for
# THIS one. `tr -cd 0-9` because `wc -c` pads its number on some platforms, and an unreadable offset
# must degrade to 0 (whole file) rather than to an arithmetic error under `set -u`.
LG="${HOME:-}/.pi/agent/state/spawn-gate.tsv"
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
# ⛔ ANCHORED TO THE GATE SHAPE, NOT TO THE WORD (review P2, 2026-11-01). `$BLOG` is a SHARED channel:
# `nonblocking-dispatch.sh` hands it to `run_agent`, so it holds the gates' refusals AND everything the
# worker itself prints — and the brief sends this worker to read the drain's own ledger, whose rows say
# things like "landing claim REFUSED: held by another box". A bare `/REFUSED/` therefore matched the
# WORKER'S OWN OUTPUT: a live, running diagnostician was reported as "NOT DISPATCHED (a spawn gate
# REFUSED this worker)" and the durable escalation row said the same — a false claim on the one surface
# whose whole job is to say what actually happened, and it points the operator at a refusal no gate
# made. Every refusal this path can write begins `[<name>] REFUSED` at column 0 (`[brief-gate]`,
# `[fork-gate]`, `[disk-gate]`, `[load-gate]`, `[land-backlog]`, `[capability-gate]`, `[pi-gate]`,
# `[worker-terminal]`), so the pattern requires that prefix.
gate_refusal() {
  [ -f "$BLOG" ] || return 0
  awk '/^\[[^]]*\] REFUSED/ { print; exit }' "$BLOG" 2>/dev/null
}

_launch=0
KIND=prfix "$DISP" "$NAME" "$WT" "$BRIEF" "$TIMEOUT" prfix >>"$O/logs/stall-fix.log" 2>&1 || _launch=$?

_verdict="unproven"; _vmax="${STALL_FIX_VERIFY_SECS:-10}"; _vwaited=0; _bpid=""
is_num "${_vmax:-}" && [ "$_vmax" -ge 1 ] || _vmax=10
[ "$_vmax" -gt 120 ] && _vmax=120
# ⛔ A NON-ZERO EXIT IS NOT ALWAYS A PRE-LAUNCH REFUSAL (fresh-context review, 2026-11-02). The
# dispatcher ALSO exits 75 AFTER the launch — `NOT STARTED` (it exited rc=0 without writing a byte)
# and `FAILED EARLY` (it started and died) at `nonblocking-dispatch.sh:405-443` — and that is
# precisely the `[land-backlog] REFUSED … rc=74` case this file's own note above records. Treating
# every non-zero exit as "refused before launching" bypassed the evidence reader and threw that
# gate's own line away, so the operator was told the wrong thing about a worker that DID run. The
# reader therefore runs on BOTH paths, and the foreground-refusal wording is reserved for the codes
# the dispatcher refuses BEFORE it forks (usage 2, missing helper/gate-policy 78, brief-gate 80).
if [ "$_launch" -ne 0 ]; then
  if spawn_row refused; then _verdict=refused
  elif [ -n "$(gate_refusal)" ]; then _verdict=refused
  elif [ -s "$BRC" ]; then _verdict=ended
  elif spawn_row allowed; then _verdict=started
  else _verdict=failed; fi
else
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
# ⛔ ROTATED, NOT APPENDED FOREVER (review P3, 2026-11-02). One `.1` generation, checked before the
# write, keeps the total bounded at ~2x the cap with no timer, no reaper dependency and no
# cross-process state — the identical mechanism `pi_gate_ledger` uses for the highest-volume sink in
# the tree. Rotation costs nothing a reader needs: the row being written survives, and the previous
# generation holds the series an operator reads after an incident.
_record() {
  local _f="$O/state/drain-stall-dispatch.log"
  if [ -f "$_f" ] && [ "$(wc -c < "$_f" 2>/dev/null || printf '0')" -ge "$STALL_FIX_LEDGER_MAX_BYTES" ]; then
    mv -f "$_f" "$_f.1" 2>/dev/null || :
  fi
  printf '%s\t%s\tpass=%s\tunowned=%s\tage_min=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$SEEN" "$UNOWNED" "$AGEMIN" >> "$_f" 2>/dev/null
}

case "$_verdict" in
  started)
    log_line "DRAIN STALL -> STALL FIX DISPATCHED (pass ${SEEN}; spawn-gate ledger: allowed TAG=$NAME; brief ${BRIEF#$O/}; report $REPORTF; worktree ${_wtsha:-UNKNOWN})"
    _record "stall-fix dispatched"
    exit 0 ;;
  running)
    # The pid is alive and nothing refused, but this box published no spawn-gate row either (the pi
    # shim is a per-box install). Say exactly that: a live process is not proof an AGENT started, and
    # claiming one would be the same fail-open in a narrower window.
    log_line "DRAIN STALL -> STALL FIX LAUNCH ACCEPTED, AGENT START UNPROVEN (pass ${SEEN}; worker pid ${_bpid:-?} is alive but no spawn-gate ledger row for TAG=$NAME and no refusal within ${_vmax}s — the pi spawn-point ledger may not be installed on this box; brief ${BRIEF#$O/}; worktree ${_wtsha:-UNKNOWN}; worker log $BLOG)"
    _record "stall-fix launch-accepted (agent start unproven)"
    exit 0 ;;
  refused)
    _g="$(gate_refusal)"
    log_line "DRAIN STALL -> STALL FIX NOT DISPATCHED (a spawn gate REFUSED this worker, so the box is STILL STALLED): ${_g:-<refusal recorded in the spawn-gate ledger for TAG=$NAME; run: bash $DISP --status $NAME>} — worker log $BLOG"
    _record "stall-fix NOT DISPATCHED (spawn refused)"
    exit 0 ;;
  ended)
    _rc="$(cat "$BRC" 2>/dev/null || true)"
    log_line "DRAIN STALL -> STALL FIX RAN AND ALREADY ENDED (pass ${SEEN}; rc=${_rc:-?}) — it DID start, so its report may exist: $REPORTF; worker log $BLOG"
    _record "stall-fix ran-and-ended rc=${_rc:-?}"
    exit 0 ;;
  failed)
    # `nonblocking-dispatch.sh`'s own refusal text went to this script's stderr (`$O/logs/stall-fix.log`
    # when the controller runs it), and any worker-side refusal to `$BLOG`. Name BOTH: the old message
    # pointed only at the first, which is where a gate refusal is NOT written.
    # ⛔ AND NAME ONLY WHAT THE CODE MEANS (fresh-context review, 2026-11-02). "Refused before
    # launching" is TRUE for the foreground codes (usage 2, missing helper/gate-policy 78, brief-gate
    # 80) and FALSE for the post-launch 75s — but those are classified above, so an exit that reaches
    # here with a code outside the foreground set is a LAUNCH WHOSE FATE IS UNREAD: no row, no refusal
    # line, no worker record. Say that, instead of asserting a refusal the evidence does not show.
    case "$_launch" in
      2|78|80) _failwhy="nonblocking-dispatch.sh refused before launching, exit ${_launch}" ;;
      *)      _failwhy="the dispatcher exited ${_launch} and left NO spawn-gate row, NO refusal line and NO worker record — its fate is UNREAD, not a proven refusal" ;;
    esac
    log_line "DRAIN STALL -> STALL FIX DISPATCH FAILED (${_failwhy}; see $O/logs/stall-fix.log and $BLOG) — the box is still stalled"
    _record "stall-fix DISPATCH FAILED (exit ${_launch})"
    exit 0 ;;
  *)
    log_line "DRAIN STALL -> STALL FIX DISPATCH UNPROVEN (pass ${SEEN}; no pid, no exit status, no refusal and no spawn-gate ledger row appeared within ${_vmax}s, so nothing here proves a worker started; brief ${BRIEF#$O/}; worker log $BLOG) — the box is still stalled"
    _record "stall-fix dispatch unproven"
    exit 0 ;;
esac
