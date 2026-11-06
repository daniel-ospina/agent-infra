#!/bin/bash
# auto-rail — the actuator: any PR whose check surface is fully terminal AND has no red,
# gets a rail launched, without an agent in the loop. The rail itself remains the gate
# (it re-reads everything: lane terminal, base comparison, evaluated tree, evidence),
# so this only removes the WAITING, never a check.
#
#   * grouped by (name), newest attempt per group — a superseded failure must not outvote
#     a green re-run (the rail's §2C rule, applied here so we queue the right PRs)
#   * in-flight => not a candidate (a queued check is a WAIT, never a green)
#   * at most MAX rails per repo, and MAX_TOTAL overall; a PR that already has a rail is skipped
#   * one lock: two copies of this script would double-rail
set -u
# The log sink is bound FIRST, because every startup refusal below writes to it and a refusal that can
# only reach a hardcoded path cannot be driven by a test (review round 5). Same default as before.
LOG=${LOG:-/tmp/auto-rail.log}
# ⛔ THE SHIPPED DEFAULT IS 8. Review round 5 measured `MAX=${MAX:-2}` here and it is the recorded
# SYMPTOM value, not a considered bound: it derived `MAX_TOTAL=4` where the body of the change promised
# 16, and it re-shipped the exact incident this repo already has on record twice —
#   tests/inert-capability-effects/run.sh:17-19  "a second 'auto-rail' instance was not a duplicate
#     actuator but a DIFFERENT POLICY, silently owning the log with 'MAX=2' while the plist said 8"
#   scripts/pr-doctor-trigger.py:39-40           "a `max=2` in the plist that the log never showed"
# The tracked copy becomes the source of truth the moment it lands (self-healing-contract C5), so it
# must ship the documented policy, and the comment below ("MAX=8 was justified against this machine's
# CPU ceiling") is only true at 8. Pinned by an arm in the accounting suite, which evaluates the SHIPPED
# `MAX=` and `MAX_TOTAL=` lines with nothing supplied and requires 8 and 16.
MAX=${MAX:-8}
case "${MAX}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: MAX='${MAX}' is not a positive integer — this actuator would not know its own bound" >> "$LOG"; exit 3;; esac
# ⛔ ZERO IS NOT A BOUND, IT IS A STALL — and the message above always said "positive integer".
# `case` above accepts `0` (it is a digit), and `MAX=0` derives `MAX_TOTAL=0`, whose clause
# `[ total -ge 0 ]` is true for EVERY population: the actuator would defer every candidate for ever
# while logging a normal-looking `deferred (…)`. Fail-closed, but a silent total stall is exactly the
# state this guard exists to make diagnosable, so refuse it here rather than discover it in the log.
[ "$MAX" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: MAX='${MAX}' is not a POSITIVE integer — 0 would defer every candidate for ever" >> "$LOG"; exit 3; }
# The repos this actuator drives. `rails_for_repo` takes the FULL slug for the repo being asked about
# plus this same list for the population, and derives every short name itself — one call shape, so the
# two cannot drift apart (the bug that made `unattributed` read 1 for a rail that WAS attributed).
REPOS="daniel-ospina/tortoise daniel-ospina/agent-infra"
# The aggregate's derivation is a FUNCTION, for the same reason `rails_should_defer` is: a test must be
# able to pin the SHIPPED arithmetic instead of a copy of it. Every review round on this branch rewrote
# the MAX_TOTAL line (three of five rounds), which is exactly the line that cannot be left unpinned — a
# literal `MAX * 2` in the test would keep passing after the derivation was broken or disarmed.
max_total_for() {  # $1 = MAX; $2.. = the repos this actuator drives
  local max=$1 n=0 _r
  shift
  for _r in "$@"; do n=$(( n + 1 )); done
  printf '%s\n' "$(( max * n ))"
}
# ── ⛔ THE MERGE-SLOT ACCOUNTING IS PER REPO (2026-11-01). IT WAS GLOBAL, AND THAT STARVED A QUEUE. ──
# `rails_live` used to be ONE count across every repo this actuator drives, and it gated EVERY repo's
# candidates. So rails working on repo A consumed repo B's merge capacity. Measured on this box: a
# per-pass population of `rails_live=8..15 max=8` in which the overwhelming majority were agent-infra
# rails waiting out their FIRST-CHECKS bound, and tortoise's ONLY candidate deferred on every pass —
#
#   2026-11-01T16:48:57Z daniel-ospina/tortoise pass: candidates=1 rails_live=11 max=8
#   2026-11-01T16:48:57Z daniel-ospina/tortoise #10010 deferred (11 rails already live, max=8)
#
# — while `ps` at 17:12Z showed 6 rails on agent-infra, 1 on tortoise. A per-repo queue gated by a
# global counter is not a concurrency bound, it is one repo's backlog holding another's queue shut.
#
# MAX is the budget for ONE repo. Mergify, the closest analogue (independent queues feeding one shared
# CI resource), scopes concurrency exactly this way: `max_parallel_checks` is a GLOBAL cap and per-scope
# `capacities` cap an individual queue (docs.mergify.com/merge-queue/queue-modes). GitHub's merge-queue
# build concurrency and Trunk's are likewise per queue, not per machine. Nobody scopes a queue's limit to
# "everything else the box happens to be running".
#
# ⛔ PER-REPO MUST NOT SILENTLY MULTIPLY THE LOAD BOUND. MAX=8 was justified against this machine's CPU
# ceiling (see the launchd plist), so making it per-repo would turn an 8-rail bound into 8×N with nothing
# saying so. MAX_TOTAL is that aggregate, NAMED AND TUNABLE instead of an arithmetic accident: MAX × the
# number of repos this actuator drives, DERIVED from REPOS so that adding a third repo cannot leave the
# aggregate below the sum of the per-repo budgets. It is a ceiling on what THIS ACTUATOR LAUNCHES, never a
# bound on the box — measured 2026-11-01 the box carried 15 rails against max=8, because pr-doctor and the
# repair lanes start rails without consulting this counter at all. The real governor is measured load at
# dispatch time.
# ⛔ AND THE AGGREGATE IS A REAL CEILING, NOT A DECORATION — say so rather than claiming the class is
# dead: at `total >= max_total` an otherwise-idle repo's candidate IS still deferred by other repos'
# rails. That population is reachable (the log holds rails_live=15 and =16 today), so max_total is a
# bound on how much THIS actuator will pile into the shared REST budget, not a promise that the symptom
# can never recur at a larger population. It is printed on every pass for exactly that reason.
MAX_TOTAL=${MAX_TOTAL:-$(max_total_for "$MAX" $REPOS)}
case "${MAX_TOTAL}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: MAX_TOTAL='${MAX_TOTAL}' is not a positive integer — an unparseable ceiling reads as FALSE and would disarm the aggregate bound" >> "$LOG"; exit 3;; esac
# ⛔ NO BACKTICKS INSIDE A DOUBLE-QUOTED MESSAGE: `` `[ total -ge 0 ]` `` in this string was COMMAND
# SUBSTITUTION (measured cycle 4) — bash ran `[ total -ge 0 ]`, printed `[: total: integer expression
# expected` to stderr, and deleted the entire explanatory clause from the log line, i.e. it truncated
# the message at the exact point that explains why the value is refused. The suite now matches the
# explanation FRAGMENT, not just `REFUSED: MAX_TOTAL=`, so this cannot come back silently.
[ "$MAX_TOTAL" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: MAX_TOTAL='${MAX_TOTAL}' is not a POSITIVE integer — 0 makes the aggregate clause '[ total -ge 0 ]' true for every population, i.e. every candidate deferred for ever" >> "$LOG"; exit 3; }
# ⛔ EVERY OTHER KNOB THIS LOOP OBEYS GETS THE SAME GUARD MAX AND MAX_TOTAL ALREADY HAVE (review
# round 5, measured). Two were unvalidated, and each is a failure this file already documents elsewhere:
#   * `INTERVAL=abc` makes `sleep` fail INSTANTLY, so the `while :;` loop below spins at `gh` speed
#     against the fleet's ONE shared 5000/h REST bucket — the very budget the per-repo argument is built
#     on. A busy-loop is not a policy, it is an outage with a running process behind it.
#   * `RED_CAP=abc` reached `int(sys.argv[2])` in the candidate heredoc and killed it mid-stream, so the
#     red list was silently truncated; the same class as the SEARCH-FAILED defect, one line further in.
INTERVAL=${INTERVAL:-180}
case "${INTERVAL}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: INTERVAL='${INTERVAL}' is not a positive integer — a fractional or non-numeric interval makes 'sleep' fail instantly and this loop spins against the shared REST bucket" >> "$LOG"; exit 3;; esac
[ "$INTERVAL" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: INTERVAL='${INTERVAL}' is not a POSITIVE integer — 0 spins the pass loop against the shared 5000/h bucket with no pause at all" >> "$LOG"; exit 3; }
# RED_CAP is the number of RED-handed-over candidates per repo per pass; 0 is legal and means "green
# only" (it disables the red arm rather than the bound), so it is validated as NON-NEGATIVE.
RED_CAP=${RED_CAP:-2}
case "${RED_CAP}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: RED_CAP='${RED_CAP}' is not a non-negative integer — an unparseable cap kills the candidate heredoc mid-stream and silently truncates the red list" >> "$LOG"; exit 3;; esac
# How long a launch is given to prove it started (see `launch_rail`). Kept a named seam so the accounting
# suite can drive both outcomes in a second instead of waiting out the shipped window.
LAUNCH_VERIFY_S=${LAUNCH_VERIFY_S:-3}
case "${LAUNCH_VERIFY_S}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: LAUNCH_VERIFY_S='${LAUNCH_VERIFY_S}' is not a non-negative integer" >> "$LOG"; exit 3;; esac
COOLDOWN_TRANSIENT_S=${COOLDOWN_TRANSIENT_S:-900}
case "${COOLDOWN_TRANSIENT_S}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: COOLDOWN_TRANSIENT_S='${COOLDOWN_TRANSIENT_S}' is not a positive integer" >> "$LOG"; exit 3;; esac
# ⛔ A DISPATCHED REVIEW IS NOT A RAILED VERDICT, so it does not take the 15-minute transient retry.
# `review-pr.sh` is a PAID, multi-minute reviewer process that caps ITSELF at 1800 s and then
# SIGTERMs (SIGKILL after `REVIEW_PR_KILL_GRACE`, default 15 s). A dispatch that has shown no exit
# line for 2700 s is therefore certainly not running any more — re-dispatching before that would pay
# for a SECOND review of the same head while the first is still working. 2700 = 1800 + 900 of margin.
# This is the SAME head-keyed cooldown the rail path uses (the key is the head, in the state file's
# name and in its dispatch line); it is a separate window only because a review is a different unit
# of work from a rail.
REVIEW_COOLDOWN_S=${REVIEW_COOLDOWN_S:-2700}
case "${REVIEW_COOLDOWN_S}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: REVIEW_COOLDOWN_S='${REVIEW_COOLDOWN_S}' is not a positive integer — a non-numeric window makes every review-dispatch comparison a syntax error, i.e. no cooldown at all" >> "$LOG"; exit 3;; esac
[ "$REVIEW_COOLDOWN_S" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: REVIEW_COOLDOWN_S='${REVIEW_COOLDOWN_S}' is not a POSITIVE integer — 0 re-dispatches a paid reviewer every pass over a head that is already being reviewed" >> "$LOG"; exit 3; }
# ⛔ AND A REVIEW IS NOT A RAIL: DO NOT EMPTY THE QUEUE IN ONE PASS. Measured on this box while
# implementing this: agent-infra had 8 mergeable PRs with NO record and 16 with a STALE one, tortoise 4
# and 12 — 40 mergeable PRs this step is now the owner of. The per-repo cap below is a LIVE-RAIL count,
# so it cannot bound a review burst (reviews are not `admin-merge` processes), and the first pass would
# otherwise start ~10 concurrent paid reviewers on a 10-core box. `review-pr.sh` honours `spawn-gate.sh`
# (rc 75 when the box is loaded) and that refusal is retried, but relying on the load gate to be the only
# bound makes the burst a policy-by-accident. One review per repo per pass, counted and published: the
# rest are marked `awaiting-review` ON THE PR, so a PR waiting its turn is still not invisible.
REVIEW_PER_PASS=${REVIEW_PER_PASS:-1}
case "${REVIEW_PER_PASS}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: REVIEW_PER_PASS='${REVIEW_PER_PASS}' is not a non-negative integer — 0 is legal and means 'publish awaiting-review and dispatch nothing' (it disables the review arm rather than the bound), a non-number makes the comparison an ERROR, which reads as FALSE, i.e. no bound at all" >> "$LOG"; exit 3;; esac
# ⛔ PER-PASS IS NOT A LIFETIME BOUND, AND `retry` WAS THE HOLE IN IT (measured by review, 2026-11-05).
# `REVIEW_PER_PASS` bounds one pass; it says nothing about the SAME head being re-bought on the next one.
# A reviewer that runs the full review and then fails AFTER it was paid for — `review-pr.sh` rc=6 (no
# verdict line), rc=9 (the record/artifact arm), rc=10 (the P0/P1/P2 scanner did not run) — leaves state
# `retry`, and the retry window is measured from the DISPATCH epoch, which by then is already older than
# COOLDOWN_TRANSIENT_S because the review itself outlasts it. So every pass re-dispatched immediately:
# one full paid review per review-duration, at one head, for ever, with the record truncated on each
# replay so an operator could not even count the attempts. `review-pr.sh`'s own header names this
# remedy defect from the other side ("re-running the recorder is the remedy, not re-reviewing").
# The bound is a durable per-head ATTEMPT LEDGER, counted only after a dispatch is VERIFIED to have
# started (a rollback must consume nothing), and EXHAUSTED is a terminal answer that publishes itself
# on the PR instead of dispatching again. A new head is a new key, so a fix still gets its review.
# ⛔ AND THE BUDGET MUST EXPIRE, OR A TRANSIENT FAILURE IS A PERMANENT LOCK (review round 3, P1).
# The attempt ledger was a LIFETIME count, and not every failure that spends it is a paid review — far
# from it: `review-pr.sh` exits 3 on 17 pre-review paths (no `gh`, no auth, cannot read the PR, the diff,
# the issue list, no writable tmp) that run BEFORE it spawns a reviewer at all, and exits 9 pre-review on
# two more ("refusing to pay for a review whose record step cannot run"). Three of those, ~900 s apart —
# one rate-limit or auth window on the same shared bucket the INTERVAL guard exists to protect — used to
# mark EVERY unattested head on the box EXHAUSTED, for ever, with a comment on each PR asserting money had
# been spent. That is the #3489 symptom (a mergeable PR nobody can unblock) rebuilt as the fix.
# So the count is WINDOWED: only dispatches inside `REVIEW_ATTEMPT_WINDOW_S` count. A head can therefore
# spend at most REVIEW_MAX_ATTEMPTS paid reviews per window — the cost bound, stated as a RATE because a
# rate is what can be honoured — and an environmental fault heals BY ITSELF when the window rolls, with
# no new head and no operator action. A head that genuinely cannot be reviewed costs one window's worth.
REVIEW_ATTEMPT_WINDOW_S=${REVIEW_ATTEMPT_WINDOW_S:-21600}
case "${REVIEW_ATTEMPT_WINDOW_S}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: REVIEW_ATTEMPT_WINDOW_S='${REVIEW_ATTEMPT_WINDOW_S}' is not a non-negative integer — a non-number makes the window comparison an ERROR, which reads as FALSE, i.e. every attempt ever counted and the bound permanent" >> "$LOG"; exit 3;; esac
[ "$REVIEW_ATTEMPT_WINDOW_S" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: REVIEW_ATTEMPT_WINDOW_S='${REVIEW_ATTEMPT_WINDOW_S}' is not a POSITIVE integer — 0 makes every attempt expire the instant it is written, i.e. no bound at all, which is the paid loop this counter exists to stop" >> "$LOG"; exit 3; }
REVIEW_MAX_ATTEMPTS=${REVIEW_MAX_ATTEMPTS:-3}
case "${REVIEW_MAX_ATTEMPTS}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: REVIEW_MAX_ATTEMPTS='${REVIEW_MAX_ATTEMPTS}' is not a non-negative integer — a non-number makes the attempt comparison an ERROR, which reads as FALSE, i.e. no bound at all" >> "$LOG"; exit 3;; esac
[ "$REVIEW_MAX_ATTEMPTS" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: REVIEW_MAX_ATTEMPTS='${REVIEW_MAX_ATTEMPTS}' is not a POSITIVE integer — 0 makes every head EXHAUSTED before its first dispatch, which is the review arm silently disabled while the log reads clean; REVIEW_PER_PASS=0 is the lawful way to disable it" >> "$LOG"; exit 3; }
# ⛔ THE RAIL MUST LIVE SOMEWHERE THAT SURVIVES. Measured 2026-10-30 08:20Z, on this very actuator:
#    RAIL_SCRIPT defaulted to `/tmp/wt-regsync2/scripts/admin-merge.sh`  -> MISSING
#    PARALLEL    defaulted to `/tmp/jobs2/rail-parallel.sh`              -> MISSING
#    the redirect target `/tmp/rails/`                                   -> MISSING
# and `/tmp/auto-rail.log` contained **zero** `launching rail` lines — not "none needed": the launch path
# could not have worked if a candidate HAD appeared. It polled every 180 s, logged `candidates=0`, and was
# incapable. `candidates=0` is exactly what a healthy idle pass looks like, which is why this survived.
# A helper that lives in /tmp is a helper macOS deletes; a rail that lives in a checkout survives.
# ⛔ THE RAIL MUST BE EXECUTABLE FROM THE ENVIRONMENT THIS JOB RUNS IN — a path is not enough
# (measured 2026-10-30): with the hub path, all 9 launches of the first working pass died
# `Operation not permitted` — macOS TCC forbids a launchd agent from exec-ing a script under
# ~/Documents. `~/rail-hub` is a real git clone, fast-forwarded at the top of every pass, so it is what
# main carries at a path TCC permits — not a hand-copied mirror, which would be the stale-code trap.
RAIL_SCRIPT=${RAIL_SCRIPT:-$HOME/rail-hub/scripts/admin-merge.sh}
RAIL_HUB=$(dirname "$(dirname "$RAIL_SCRIPT")")
# ── THE REVIEWER STEP'S SEAM (#3489) ───────────────────────────────────────────────────────────────
# `scripts/review-pr.sh` is the step that PRODUCES an attestation: it spawns a fresh-context reviewer
# (`KIND=reviewer`), posts the reviewer's findings as a COMMENT, and — only when the reviewer came back
# clean — records the verdict with `record-review.sh --evidence comment:<id>` bound to the reviewed
# head. It is taken from the SAME refreshed clone as the rail, for the same measured reason: a path
# under `~/Documents` is TCC-denied for a launchd job (`Operation not permitted`), and `$RAIL_HUB` is
# fast-forwarded to origin/main at the top of every pass, so it is what main carries at a permissible
# path rather than a hand-copied mirror.
REVIEW_SCRIPT=${REVIEW_SCRIPT:-$RAIL_HUB/scripts/review-pr.sh}
# ⛔ THE `gh` THIS JOB FINDS MUST BE THE SHIM **AND** EXECUTABLE HERE. `~/.pi/agent/shims/gh` is a symlink into
# ~/Documents (TCC-denied for launchd), and using the real gh directly would DROP the argv-level admin-merge
# guard (#984) from the one actor that merges automatically. The rail-hub clone carries scripts/gh-shim/gh at a
# TCC-free path and is refreshed to origin/main every pass, so this is the current guard, not a copy of it.
if [ -x "$RAIL_HUB/scripts/gh-shim/gh" ]; then
  export PATH="$RAIL_HUB/scripts/gh-shim:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/share/pi-node/node-v22.23.2-darwin-arm64/bin:/opt/homebrew/bin:/usr/local/bin"
else
  echo "$(date -u +%FT%TZ) REFUSED: no executable gh shim at $RAIL_HUB/scripts/gh-shim/gh — refusing to fall back to an unguarded gh" >> "$LOG"
  exit 3
fi
# ⛔ NO ACTUATOR MAY PASS SILENTLY WITH A MISSING DEPENDENCY. Fail loudly, once, at start: a launchd job
# that exits non-zero with a reason is diagnosable; one that logs a placid `candidates=0` for weeks is not.
# ⛔ THESE THREE PATHS ARE ENV-OVERRIDABLE SEAMS, NOT CONSTANTS (review round 5). They were hardcoded,
# so the accounting suite could not drive a single line that touches them — the cooldown ledger, the
# launch, the startup refusals — and had to `sed`-patch a COPY of this script to test a refusal. A copy
# is a test of the copy. With the seam, the suite runs the SHIPPED file with `TRIED`/`RAIL_DIR`/`LOG`
# pointed at a `mktemp` directory, which is also what makes the launch-verification and rollback arms
# measurable at all. The defaults are unchanged.
RAIL_DIR=${RAIL_DIR:-$HOME/.pi/agent/state/rails}
# ⛔ (pr, head) ALREADY ANSWERED => DO NOT ASK AGAIN. Measured 2026-10-30: identical refusals were re-railed
# every pass, because the only thing that can change a refusal is a new head (push/rebase/conflict resolved)
# or a PR-state change — and neither happens by waiting 5 minutes.
TRIED=${TRIED:-$RAIL_DIR/tried.tsv}
COOLDOWN_S=${COOLDOWN_S:-21600}
# ⛔ A COOLDOWN MUST BE KEYED TO WHAT CAN CHANGE THE ANSWER, NOT TO THE HEAD.
# Measured 2026-10-30 18:13Z: the head-keyed cooldown below skipped tortoise #9876 with the sentence
# "a refusal can only change with a new head" — which is FALSE. #9876 was refused for "no run of the
# lane actually TESTED head" while CI was still running; 20 minutes later it was GREEN and attested at
# the SAME head, and this actuator would not look at it for six hours. The same holds for a stale
# attestation being re-recorded and for main going green. So: a verdict that can only be changed by a
# NEW HEAD (CONFLICTED, DRAFT) keeps the long cooldown; every other verdict gets the short one.
# ⛔ THE RAIL DIRECTORIES ARE PRECONDITIONS, NOT DECORATION. Every launch writes its verdict into
# `$RAIL_DIR`, and the cooldown logic READS it; a `mkdir` whose status nobody checks, and a redirect that
# cannot be opened, both leave the ledger recording "railed" for a rail that never ran — measured cycle 4
# on this file: `nohup … > <unopenable> 2>&1 &` returns 0 to the caller, the log says `launching rail`,
# and every later pass reports "this head was already railed … only a NEW HEAD can change" for six hours
# over a rail that never started. Refuse at start instead of failing silently per launch, exactly as the
# `$TRIED` and `$RAIL_SCRIPT` checks below do.
if ! mkdir -p "$RAIL_DIR" 2>/dev/null || [ ! -d "$RAIL_DIR" ] || [ ! -w "$RAIL_DIR" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: cannot create a writable rail-verdict directory at $RAIL_DIR — a launch that cannot write its verdict is a failed launch this log would record as a launch" >> "$LOG"
  exit 3
fi
# ⛔ THE COOLDOWN LEDGER IS THE ONLY THING STOPPING AN UNLIMITED RE-RAIL LOOP, so its absence is a
# refusal, not a shrug: unreadable/unwritable, every candidate reads as "never tried" and is launched
# again every INTERVAL, each launch consuming a MAX slot. Refuse once, diagnosably, at start.
if ! touch "$TRIED" 2>/dev/null || [ ! -w "$TRIED" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: cannot create the cooldown ledger at $TRIED — without it every candidate would be re-railed every pass" >> "$LOG"
  exit 3
fi
if [ ! -f "$RAIL_SCRIPT" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: rail not found at $RAIL_SCRIPT — this actuator cannot land anything" >> "$LOG"
  exit 3
fi
# ⛔ PRs the consolidation pass (aiconsol2, 2026-10-24) flagged as one of a DUPLICATE PAIR whose
# survivor is not yet decided. Green checks do not make a duplicate safe to merge: the pair exists
# because two lanes implemented the same issue, and merging both lands one change twice.
# ⛔ A DENY entry is a claim about the PRESENT, and this list was a claim about 20:30Z.
# Revalidated 2026-10-24T22:10Z (measured, not assumed): of the original eleven, SIX named a
# partner that is no longer open — `#2317 CLOSED`, `#2247 CLOSED`, `#2336 MERGED` — so the
# refusal they justified no longer exists. A DENY that outlives its partner is a FALSE REFUSAL:
# it blocks a green, recorded PR for ever, and it is invisible because the only symptom is
# `candidates=0` on every pass (measured on both repos, 21:52Z and 21:57Z).
# ⛔ AND THE KEY IS THE REPO **AND** THE PR, NOT THE PR NUMBER (review round 5, measured). The match used
# to be `case "$DENY" in *" $pr "*)` over bare numbers, so `tortoise#2597` DENIED `agent-infra#2597`:
# a refusal decided by a number that names a DIFFERENT repository's pull request. The key is now
# `<owner>/<name>#<pr>`, which is also what makes an entry auditable — a bare `2597` does not say whose.
# Re-derived 2026-11-01 (not assumed), which is why the list is now EMPTY: every surviving number is
# MERGED or CLOSED in EVERY repo it resolves in — agent-infra#2597 MERGED, #2608 CLOSED, #2172 MERGED,
# #2551 MERGED; tortoise#2608 MERGED, #2551 MERGED (2597/2172 do not exist there). A candidate is an
# OPEN PR, so an entry for a closed one can never fire: the list was four dead keys and one wrong repo.
# Re-derive this list with the repo in the key, never append to it:
#   for k in $DENY; do gh pr view "${k#*#}" --repo "${k%#*}" --json number,state,title; done
DENY="${DENY:-}"
# rc 0 = this repo's PR is REFUSED as a duplicate-pair member. A function so the suite drives the KEY
# instead of reading a `case` at the loop — the repo-blindness was a one-line `case` that no test saw.
denied() {  # $1 = repo, $2 = PR number
  case " $DENY " in *" $1#$2 "*) return 0;; esac
  return 1
}
log_line() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
LOCK=${LOCK:-/tmp/auto-rail.lock}
# A lock younger than this cannot be judged stale: it is inside the window between `mkdir` and the
# winner's pid write. macOS has no `flock`; a directory is an atomic lock.
LOCK_AGE_GRACE=${LOCK_AGE_GRACE:-120}
case "${LOCK_AGE_GRACE}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: LOCK_AGE_GRACE='${LOCK_AGE_GRACE}' is not a non-negative integer" >> "$LOG"; exit 3;; esac
# ⛔ THE STALE-LOCK RECLAIM WAS UNSOUND IN BOTH DIRECTIONS (review round 5, measured). It read the pid
# file, and `ps -p` was the whole test:
#   * STEAL A LIVE LOCK: between `mkdir "$LOCK.d"` and `echo $$ > "$LOCK.d/pid"` the pid file does not
#     exist, so `holder="?"`, `ps -p "?"` fails, and the second instance `rm -rf`'d the first's lock and
#     ran anyway — the double-rail this whole lock exists to prevent, in a window of a few microseconds
#     that a pass started from a timer hits more often than it sounds.
#   * STOP FOR EVER AT PID REUSE: a RECYCLED pid satisfies `ps -p` (some unrelated process now owns that
#     number), so every later instance took the "another auto-rail holds the lock" branch, exited 0 with
#     one benign log line, and the actuator was permanently dead with a clean log — the exact ambiguity
#     the ALIVE/REFUSING/IDLE comments in this file are built to prevent.
# The three answers are now: the holder's ARGS must name `auto-rail.sh` (a pid is not an identity); an
# ALIVE non-matching or unreadable pid is only reclaimable once the lock is OLDER than LOCK_AGE_GRACE (so
# the mkdir->pid window reads as HELD, fail-closed); and when the lock cannot be dated it is HELD.
lock_holder_is_live() {  # $1 = lock dir; rc 0 = a LIVE auto-rail holds it (do not touch it)
  local d=$1 pid age mtime now
  [ -d "$d" ] || return 1          # no lock dir at all: nobody holds it
  pid=$(cat "$d/pid" 2>/dev/null | tr -cd '0-9')
  # ⛔ THE HOLDER'S ARGS MUST NAME **THIS** SCRIPT, not any string containing "auto-rail": the first
  # version grepped `auto-rail`, which matches `auto-rail.accounting.test.sh` — i.e. the SUITE ITSELF read
  # as the holder (measured), and would also match any tool named after the actuator. The actuator runs as
  # `.../auto-rail.sh`, so that is what the argv must contain.
  if [ -n "$pid" ] && ps -p "$pid" -o args= 2>/dev/null | grep -q 'auto-rail[.]sh'; then
    return 0   # a real holder: right pid AND the process is this script
  fi
  # ⛔ THE DATE MUST BE READ WITH THE FORM THAT WORKS ON THIS PLATFORM, AND THE FALLBACK WAS IN THE
  # WRONG ORDER (measured 2026-11-05 on a Linux cell, on the base commit — this suite's two "recycled
  # pid" arms were red there and green on macOS). GNU `stat -f %m` is *"filesystem info, format %m"*: it
  # prints a whole multi-line filesystem block to STDOUT and exits 1, so the BSD form came FIRST and
  # SUCCEEDED-ENOUGH to poison the `||` fallback — `mtime` held a block of text plus the real epoch.
  # The numeric guard below then returned 0 ("cannot date it → assume held") on EVERY Linux box, i.e. the
  # stale-lock reclaim this function was rewritten for could never fire on a cell: a lock left behind by
  # a killed pass makes the actuator exit 0 with "another auto-rail holds the lock" for ever — the exact
  # permanently-dead-with-a-clean-log state the three answers above exist to rule out.
  # GNU (`-c %Y`) first, BSD (`-f %m`) second: on macOS `stat -c` fails outright, on Linux `stat -c %Y`
  # is the only form that prints just the epoch. The numeric guard stays as the fail-closed backstop.
  mtime=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null)
  case "${mtime:-}" in ''|*[!0-9]*) return 0;; esac   # cannot date the lock -> assume held
  now=$(date +%s); age=$(( now - mtime ))
  [ "$age" -lt "$LOCK_AGE_GRACE" ]
}
# rc 0 = this process holds the lock; 1 = another instance does (the caller exits 0).
acquire_lock() {
  if ! mkdir "$LOCK.d" 2>/dev/null; then
    if lock_holder_is_live "$LOCK.d"; then
      log_line "another auto-rail holds the lock ($(cat "$LOCK.d/pid" 2>/dev/null || echo 'pid not yet written')) — exiting"
      return 1
    fi
    log_line "stale lock ($(cat "$LOCK.d/pid" 2>/dev/null || echo 'no pid') older than ${LOCK_AGE_GRACE}s) — taking it"
    rm -rf "$LOCK.d"; mkdir "$LOCK.d" 2>/dev/null || return 1
  fi
  # ATOMIC pid write: temp + rename, so a reader can never see a half-written pid file (the old
  # `echo $$ > pid` could be observed empty by the other instance, which then treated it as stale).
  printf '%s\n' "$$" > "$LOCK.d/pid.tmp" && mv "$LOCK.d/pid.tmp" "$LOCK.d/pid"
  return 0
}
acquire_lock || exit 0
trap 'rm -rf "$LOCK.d"' EXIT INT TERM
# ── merge-slot accounting, PER REPO ─────────────────────────────────────────────────────────────────
# ⛔ THE IDENTITY IS THE FULL `owner/name`, NEVER THE BASENAME (review round 5, measured P0). Both
# attribution sites used to collapse a slug with `.split("/")[-1]` — the `--repo <owner/name>` argument
# AND the path rule — so 8 rails launched on `premise-labs/agent-infra` read as `8 8 0`
# (own/total/unknown) for `daniel-ospina/agent-infra`, and `/opt/forks/agent-infra/scripts/admin-merge.sh`
# read as `own` here. Two measured consequences, one per direction:
#   * the OTHER driven repo counted those 8 live rails as neither own nor unknown (`0 8 0`), so its
#     counter said "nothing is running" while the box was saturated — a FAIL-OPEN launch;
#   * the log line `rails_on_repo=8` asserted 8 rails on THIS repo when none of them was on this repo —
#     a statement about another org's queue, printed as a fact about ours.
# Attribution has PRECEDENCE, and it is ONE pass over the process table (`rail_rows`) that BOTH the
# counter and the duplicate-rail guard read — three greps is how a rail gets counted twice by one and
# never by another:
#   1. an explicit `--repo <owner/name>` from the launcher decides. It must carry BOTH parts: a bare
#      `--repo agent-infra` cannot name an owner, so it is UNKNOWN rather than assumed to be ours;
#   2. else the CLONE the rail runs from decides — walk up from the script to the repo root and read
#      `git -C <root> remote get-url origin`. Only the tree's own origin can tell a fork from upstream,
#      or another org's same-named repo from ours;
#   3. else a path segment that literally names one of the driven `<owner>/<name>` slugs decides;
#   4. else UNKNOWN.
# A rail attributable to NEITHER is UNKNOWN, and so is one whose `--repo` names a repo this actuator does
# not drive. Unknown load must never read as free load (fail-closed), so it counts against EVERY repo and
# is printed: that is the difference between "no rails here" and "rails I cannot see".
rail_rows() {  # one pass over the process table; prints "<owner/name|UNKNOWN><TAB><pr|->" per rail
  local tbl
  # ⛔ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE — the rule the candidate search states at
  # SEARCH-FAILED, and the counter path did not have. This script has no `pipefail`, so a `ps` that
  # cannot run (rc≠0, no process table) left python reading EOF and printing a perfectly parseable
  # `0 0 0`: the guard in `rails_should_defer` never fired, BOTH bounds disarmed, and the log read
  # byte-identically to a healthy idle box. Capture the table and its STATUS first, and print NOTHING
  # on failure — empty output is exactly what makes that guard defer (fail-closed).
  tbl="$(ps -eo args= 2>/dev/null)" || { log_line "COUNTER-FAILED: ps rc=$? — cannot read the process table (fail-closed)"; return 1; }
  printf '%s\n' "$tbl" | python3 -c '
import os, re, subprocess, sys

# "<owner>/<name>" out of a slug or a remote URL; None when the string cannot name an owner.
def slug_of(s):
    s = (s or "").strip().rstrip("/")
    if not s:
        return None
    if s.startswith("git@"):                 # git@github.com:owner/name.git
        s = s.split("@", 1)[1].replace(":", "/", 1)
    s = re.sub(r"\.git$", "", s)
    parts = [p for p in s.split("/") if p]
    if len(parts) < 2:                        # a bare name cannot name an OWNER
        return None
    return ("%s/%s" % (parts[-2], parts[-1])).lower()

_resolved = {}
def slug_from_clone(path):
    """The clone a rail runs from decides its owner — its origin, never its directory name."""
    d = os.path.dirname(os.path.abspath(path))
    key = d
    if key in _resolved:
        return _resolved[key]
    _resolved[key] = None
    for _ in range(8):
        if os.path.exists(os.path.join(d, ".git")):
            try:
                url = subprocess.run(["git", "-C", d, "remote", "get-url", "origin"],
                                     capture_output=True, text=True, timeout=10)
                if url.returncode == 0:
                    _resolved[key] = slug_of(url.stdout)
            except Exception:
                pass
            return _resolved[key]
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None

known = [k for k in (slug_of(a) for a in sys.argv[1:]) if k]
for raw in sys.stdin.buffer:
    # a single non-UTF-8 byte in any argv would otherwise kill this whole read (UnicodeDecodeError),
    # the function would print nothing, and the caller would see an unreadable population.
    line = raw.decode("utf-8", "replace")
    # `[a]dmin-merge.sh` is the grep artifact of OTHER processes scanning this table, not a rail; and
    # the form with no trailing argument (`admin-merge.sh 3212`) is a rail, so the match is the TOKEN.
    if not re.search(r"(?:^|\s)\S*admin-merge\.sh(?:\s|$)", line) or "[a]dmin-merge.sh" in line:
        continue
    toks = line.split()
    path = None
    for i, t in enumerate(toks):
        if t.endswith("admin-merge.sh"):
            path = t
            break
    args = toks[i + 1:] if path is not None else []
    # ⛔ EVERY NUMERIC ARGV TOKEN IS A PR CANDIDATE, AND THE GUARD IS ASKED ABOUT ALL OF THEM (measured,
    # review rounds 5-6). Picking ONE token is unsound in both directions: `--main-runs 10 3136` read the
    # option VALUE as the PR and missed the live rail for #3136 (a duplicate launch — the defect the guard
    # exists to prevent), while the shape `--main-runs 10 --any-workflow 3136` still defeats the "not after
    # a flag" heuristic because a BOOLEAN flag sits between them. So the row carries every numeric token,
    # and matching ANY of them counts as a live rail. That is deliberately the FAIL-CLOSED direction: an
    # option value that happens to equal an open PR number makes one candidate skip for one pass, which
    # costs a wait; a missed rail costs a duplicate merge attempt and a slot.
    pr = ",".join(t for t in args if t.isdigit()) or "-"
    slug = None
    for j, t in enumerate(args):
        if t == "--repo" and j + 1 < len(args):
            slug = slug_of(args[j + 1])
            break
    if slug is None and path is not None:
        slug = slug_from_clone(path)
    if slug is None:
        for k in known:
            if "/%s/" % k in line:
                slug = k
                break
    print("%s\t%s" % (slug or "UNKNOWN", pr))
' "$@"
}
# $1 = the repo asked about; $2.. = every repo driven. Prints "<own> <total> <unknown>".
rails_for_repo() {
  local rows me=$1
  shift
  rows=$(rail_rows "$me" "$@") || return 1
  # ⛔ AN EMPTY POPULATION IS `0 0 0`, NOT ONE UNKNOWN RAIL (measured, review round 6). `printf '%s\n'
  # "$rows"` on an empty string emits ONE EMPTY LINE, which awk counts as a record: total=1, no slug,
  # so unk=1. Every idle pass logged `rails_live=1 unattributed=1` — a per-repo pass line that was false
  # on every idle box, the exact class this whole change exists to remove — and at a legal `MAX=1` the
  # phantom rail made `own+unk >= MAX` true for ever, i.e. a silent total stall. The rc check ABOVE stays
  # first and separate: a FAILED `rail_rows` must still print NOTHING (that is what defers), while a
  # successful empty read prints `0 0 0`.
  [ -n "$rows" ] || { printf '0 0 0\n'; return 0; }
  printf '%s\n' "$rows" | awk -v me="$me" -v known="$*" '
    BEGIN { n = split(known, k, " ") }
    { total++;
      if ($1 == me) { own++; next }
      driven = 0
      for (i = 1; i <= n; i++) if ($1 == k[i]) driven = 1
      if (!driven) unk++ }
    END { printf "%d %d %d\n", own, total, unk }
  '
}
# The defer decision, in ONE place, so a test can pin the SHIPPED predicate instead of a copy of it.
rails_should_defer() {  # $1 = this repo (owner/name), $2.. = every repo driven
  local own total unk
  read -r own total unk <<< "$(rails_for_repo "$@")"
  # ⛔ AN UNPARSEABLE COUNTER IS NOT A FREE SLOT. `read` succeeds on empty output, and then `[ "" -ge n ]`
  # errors — and an errored `[` reads as FALSE, i.e. LAUNCH. So say it and defer: a population I cannot
  # read is load I cannot rule out, which is the same fail-closed rule as the unknown bucket.
  case ":${own}:${total}:${unk}:" in
    *[!0-9:]*|::*|*::|*:::*) log_line "COUNTER-FAILED: rails_for_repo produced no usable counts — deferring $1 (fail-closed)"; return 0;;
  esac
  [ $(( own + unk )) -ge "$MAX" ] || [ "$total" -ge "$MAX_TOTAL" ]
}
# ── THE CALL SITE'S SHAPE, as a function ───────────────────────────────────────────────────────
# `rails_should_defer` is only PER-REPO because its caller passes the whole population ($REPOS)
# alongside the repo being asked about. Drop that argument — or put the old global `total >= MAX`
# back at the call site — and every other repo's rails read as unknown load: the fix is fully undone
# while the predicate itself is untouched, and a suite that drives the predicate alone cannot see it.
# So the call site's shape is a function the suite DRIVES — and the loop's own invocation of it is
# pinned SEPARATELY, by a declared text assertion in the suite, because the loop cannot be executed
# without stub-driving the whole supervisor. Neither pin alone is enough: driving this wrapper cannot
# see `"$repo"` losing its `$REPOS` at the loop, and a grep at the loop cannot see this wrapper
# mangling its arguments. The suite states which is which (see its "call site" section).
candidate_deferred() {  # $1 = this repo, $2.. = every repo driven  (rc 0 = defer this candidate)
  rails_should_defer "$@"
}
# ── THE DUPLICATE-RAIL GUARD, as a function ────────────────────────────────────────────────────
# rc 0 = a rail for THIS PR is live (skip it), 1 = no rail for it, 2 = CANNOT TELL — and 2 is not 1.
# The guard used to read `ps … | grep -c`, which has no `pipefail` here: a failing `ps` left `grep -c`
# reading EOF, printing `0`, so "I cannot see the process table" became "no rail is running" and the
# actuator launched a SECOND rail for a PR that already had one — burning the shared REST budget,
# doubling the merge attempt, and inflating this repo's own count so other candidates of the repo this
# change exists to unstarve get deferred. A FUNCTION so the suite drives all three answers.
# ⛔ AND THE KEY IS THE REPO **TOO** (review round 5, measured): it matched the PR NUMBER alone, so a live
# rail on `agent-infra#2710` made `tortoise#2710` skip for that pass. PR numbers are per repo, so a
# number is not an identity any more than a basename is. It now reads the SAME one-pass attribution as
# the counter, and a rail that names this repo OR that cannot be attributed at all (UNKNOWN — it might
# be this repo's) counts; a rail attributed to a DIFFERENT driven repo does not.
rail_already_running() {  # $1 = repo, $2 = PR number
  local repo=$1 pr=$2 rows
  rows=$(rail_rows "$repo") || { log_line "COUNTER-FAILED: ps rc=$? — cannot rule out an existing rail for $repo#$pr (fail-closed)"; return 2; }
  [ -n "$rows" ] || return 1
  # A row's second field is EVERY numeric token of that rail's argv, comma-separated (see `rail_rows`):
  # an option VALUE can be numeric, so "which one is the PR" is not decidable from the row alone and the
  # fail-closed answer is "any of them may be". Matching ONE token was a duplicate-rail fail-open for
  # `--main-runs 10 3136` (measured, review round 6).
  printf '%s\n' "$rows" | awk -v me="$repo" -v pr="$pr" '
    $1 == me || $1 == "UNKNOWN" {
      n = split($2, num, ",")
      for (i = 1; i <= n; i++) if (num[i] == pr) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}
# ── THE DUPLICATE-RAIL ANSWER, MAPPED TO AN ACTION ──────────────────────────────────────────────
# `rail_already_running` has three answers and the pass has two actions; collapsing the third into
# "no rail" is the fail-open. That mapping lives here, as a DRIVEN function, because a bare
# `if [ "$rc" -ne 1 ]` at the loop is one line a reviewer found could be deleted with the suite green.
rail_says_skip() {  # $1 = rc from rail_already_running  (rc 0 = skip this candidate)
  case "$1" in
    0) return 0;;   # a rail for this PR is live
    1) return 1;;   # no rail: proceed
    *) return 0;;   # CANNOT TELL -> skip (fail-closed) — never a launch
  esac
}
# ── THE COOLDOWN, AS A FUNCTION ────────────────────────────────────────────────────────────────────
# ⛔ WHICH COOLDOWN APPLIES, IN ONE DRIVEN PLACE (review round 5, measured P2). Only CONFLICTED / DRAFT /
# DENIED are answers that require a NEW HEAD to change. Everything else — INCLUDING an attempt whose rail
# left NO verdict at all — gets the short retry. That last case is the fix: a launch that never produced a
# verdict used to fall through to COOLDOWN_S (6 h) and the pass then printed "railed 6h ago on a verdict
# that only a NEW HEAD can change" about a verdict that never existed — the false-premise sentence the
# block above was written to kill, surviving in the branch that runs when there is no verdict at all.
cooldown_for() {  # $1 = the rail's verdict file; prints the seconds to wait
  if [ -f "$1" ] && grep -qiE 'CONFLICTED|is a DRAFT|DENIED' "$1" 2>/dev/null; then
    printf '%s\n' "$COOLDOWN_S"
  else
    printf '%s\n' "$COOLDOWN_TRANSIENT_S"
  fi
}
# Drop ONE ledger row. Used when a launch is proven not to have started, so the head is retried on the
# next pass instead of being reported as "already railed" for hours over a rail that never ran.
forget_tried() {  # $1 = the exact ledger row (tab-separated); rc 0 = the row is gone
  local row=$1 tmp rc
  [ -f "$TRIED" ] || return 1
  tmp="$TRIED.$$.tmp"
  # ⛔ `grep -v` EXITS 1 WHEN IT SELECTS NOTHING — i.e. exactly when the row being dropped is the ledger's
  # ONLY line — and the old `|| { rm -f; return 1; }` therefore left that row in place while `launch_rail`
  # logged "cooldown row rolled back so this head is retried next pass" (measured, review round 6). A claim
  # of an effect that did not happen is the class this file exists to remove. rc 0 and rc 1 are both fine
  # here (lines kept / nothing kept); any OTHER rc is a real error and stays a failure.
  grep -vxF -- "$row" "$TRIED" > "$tmp" 2>/dev/null; rc=$?
  [ "$rc" -le 1 ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$TRIED"
}
# ── THE LAUNCH, AS A FUNCTION ──────────────────────────────────────────────────────────────────────
# ⛔ THE LEDGER RECORDS AN ATTEMPT, AND THE ATTEMPT IS NOW VERIFIED — both halves matter (review round 5).
# Recording only AFTER a verified start was proposed in review and rejected: a rail may refuse in two
# seconds, and "the process is gone" is exactly the case the cooldown exists for, so writing after it
# would re-rail every fast refusal every pass. But a launch that never STARTED must not stay recorded, and
# `nohup … &` returns 0 whether or not anything ran (measured cycle 4: an unopenable redirect, a missing
# wrapper) — the log then said `launching rail` and every later pass said "already railed … only a NEW
# HEAD can change" for six hours. So the row is written first and ROLLED BACK on proof that nothing ran:
# after the verify window the child is either still ALIVE, or it exited having put SOMETHING in its
# verdict file. Neither => forget the row and say LAUNCH-FAILED.
# What this does NOT prove, stated rather than implied: a child that exec'd bash and failed on a MISSING
# script writes bash's own error into the verdict file, so it reads as "ran and refused". That residue is
# why the script's presence is a startup precondition (checked above) rather than something this
# verification could discover.
launch_rail() {  # $1 = repo, $2 = PR, $3 = head, $4 = verdict file; rc 0 = an attempt started
  local repo=$1 pr=$2 head=$3 out=$4 row extra="" pid
  # ⛔ agent-infra SPLITS ITS LANES BY TRIGGER (agent-infra #1257): `ci.yml` is pull_request-only and
  # `ci-main.yml` is push:[main]-only, so no single `--workflow` spans both sides and the rail's own
  # BLOCK line tells the operator to add `--any-workflow`. Without it every agent-infra launch from here
  # would burn a MAX slot and refuse — an actuator that fires and cannot land. This does NOT bypass a
  # check: `--any-workflow` widens the MAIN baseline (compare against every lane on main), it does not
  # skip the comparison.
  [ "$repo" = "daniel-ospina/agent-infra" ] && extra="--any-workflow"
  row="$pr	$head	$(date +%s)"
  printf '%s\n' "$row" >> "$TRIED"
  log_line "$repo #$pr GREEN+terminal -> launching rail (head $head)"
  RAIL_SCRIPT="$RAIL_SCRIPT" nohup bash "$RAIL_SCRIPT" "$pr" --repo "$repo" $extra > "$out" 2>&1 &
  pid=$!
  sleep "$LAUNCH_VERIFY_S"
  if kill -0 "$pid" 2>/dev/null || [ -s "$out" ]; then return 0; fi
  log_line "$repo #$pr LAUNCH-FAILED — nothing started within ${LAUNCH_VERIFY_S}s (no live child, empty verdict file $out); cooldown row rolled back so this head is retried next pass instead of being reported as already railed"
  forget_tried "$row"
  return 1
}
# ── THE REVIEW STEP: THE PRODUCER OF ATTESTATIONS (#3489) ─────────────────────────────────────────
# ⛔ MEASURED 2026-11-05 on PR #3486 while it sat in exactly this state:
#     auto-rail.sh  admin-merge refs   = 4
#     auto-rail.sh  record-review refs = 0
#     chain-merge for #3486 running    = none
#     ~/.pi/agent/reviews/3486         = absent
# — a MERGEABLE PR reading `mergeable=MERGEABLE state=BLOCKED reviewDecision=empty`. `admin-merge` reads
# a head-bound attestation out of the PR BODY and NOTHING in the unattended loop ever wrote one: the
# candidate search DROPPED every PR without the marker (`if "review recorded:" not in body: continue`),
# so "mergeable, no owner" was not merely invisible — it was not a candidate at all. That filter is the
# root; these are the pieces that replace it.
#
# ⛔ THIS ACTUATOR NEVER WRITES A VERDICT. It dispatches `review-pr.sh`, which spawns a fresh-context
# reviewer and — only on a clean verdict — calls `record-review.sh --evidence comment:<id>` itself. A
# review record is minted only from a fresh-context reviewer's verified evidence; an actuator that
# composed verdict text (or that called the recorder on its own reading) would BE the attestation
# author, which reverses that recorded decision. The reviewer is dispatched by KIND (review-pr.sh sets
# KIND=reviewer), never by a self-declared exemption flag.
# ⛔ AND NOT VIA `chain-merge.sh`: its interface is lane-scoped (`<repo-path> <owner/repo> <issue>
# <branch>`) and it "waits for the lane to open its PR". An orphaned PR has no lane to wait on, which is
# the entire case here, so the step lives in this loop, keyed to the PR and its head like everything
# else in this file.
#
# ── WHAT A DISPATCHED REVIEW IS DOING, AS ONE DRIVEN FUNCTION ─────────────────────────────────────
# One file per (repo, pr, HEAD) carries the review's whole life, so a later pass needs no memory:
#     line 1   REVIEW-DISPATCHED at=<epoch> head=<head> …   written by the PARENT, before the launch
#     …        the reviewer's own output (review-pr.sh: findings, evidence, refusals)
#     last     REVIEW-EXIT rc=<n>                          written by the wrapper, ALWAYS
# The exit line is what makes the outcome durable — an earlier pass cannot learn a background child's
# status, and `review-pr.sh`'s rc IS the outcome:
#     0  clean: record written and verified at the reviewed head
#     5  a clean record already exists at this head (a lost race in the good direction: nothing owed)
#     7  the reviewer FOUND ISSUES — not recorded, findings posted as the comment
#     8  the head moved during the review        9  the record/artifact arm failed
#     4  no `pi`                                 75 a spawn-point load refusal
#     → 0/5 clean, 7 issues, 4/75 REFUSED (nothing was consumed: see `refused` in review_action),
#       everything else retry (the review may have been paid for, so the attempt budget applies).
# ⛔ A STALE RECORD IS TREATED AS "NO ATTESTATION FOR THE HEAD THAT WOULD MERGE", WHICH IS A DELIBERATE
# COST, STATED RATHER THAN HIDDEN. `record-review.sh --check-carry` would sometimes answer that the
# reviewed DIFF is unchanged and the record carries (#3315) — and in that case this actuator buys a
# review the recorder says nobody needs. It is bought anyway, for two reasons: (a) deciding that a record
# covers what would merge is the GATE's predicate, not this actuator's, and re-deriving it here would be
# a second definition of "unchanged" for the same contract — the one thing `--check-carry` exists to
# prevent; (b) the two errors are not symmetric: a fresh review of an unchanged diff costs one review and
# one pass, while a wrong carry records a verdict over a diff nobody read. `review-pr.sh` also exits 5
# ("a clean record already exists at this head") when the record is in fact current, so the repeat case
# costs nothing at all.
# ⛔ 7 IS TERMINAL AT THIS HEAD, AND THAT IS THE POINT: re-dispatching a head the reviewer already
# rejected pays for the SAME verdict again for ever. The fix is a new head, and a new head is a
# different key (the file is named for the head), so a new head gets a review by construction.
review_state() {  # $1 = the review's output file; prints none|pending|clean|issues|retry|refused
  [ -f "$1" ] || { printf 'none\n'; return 0; }
  local rc
  # `tail` FIRST: the exit line is the LAST line, and a reviewer transcript is tens of KB that every pass
  # would otherwise re-read in full while the review is pending.
  rc=$(tail -20 "$1" 2>/dev/null | sed -n 's/^REVIEW-EXIT rc=\([0-9][0-9]*\)$/\1/p' | tail -1)
  # ⛔ NO EXIT LINE IS *PENDING*, NOT *FAILED*: the child may be mid-review, or may not have reached the
  # line yet. Reading it as failed is exactly how a live 20-minute review gets a duplicate next pass.
  [ -n "$rc" ] || { printf 'pending\n'; return 0; }
  case "$rc" in
    0|5) printf 'clean\n';;
    7)   printf 'issues\n';;
    # ⛔ A REFUSAL IS NOT A REVIEW (review round 2, P2). rc=4 (no `pi`) and rc=75 (the load gate) are
    # documented as consuming NOTHING, so they must not spend the PAID attempt budget: three load
    # refusals would otherwise mark a head nobody ever read as EXHAUSTED, permanently, and the comment
    # published for it would claim the review had been paid for. Their own state retries on TIME alone.
    # rc=3 is deliberately NOT here: `review-pr.sh` exits 3 on several paths AFTER the reviewer ran.
    4|75) printf 'refused\n';;
    *)   printf 'retry\n';;
  esac
}
# The dispatch epoch, from the record the PARENT wrote — never the file's mtime, which a reviewer that
# keeps writing output would keep refreshing and which would therefore never age out.
review_dispatched_at() {  # $1 = the review's output file; prints the epoch, or nothing
  head -1 "$1" 2>/dev/null | sed -n 's/^REVIEW-DISPATCHED at=\([0-9][0-9]*\).*/\1/p'
}
# How many dispatches this head has already spent INSIDE THE WINDOW. The ledger is APPEND-ONLY and lives
# beside the record (same (repo, PR, head) key), because the record itself is truncated on every replay —
# a count kept inside it would be destroyed by exactly the replay it is supposed to bound. Entries older
# than REVIEW_ATTEMPT_WINDOW_S stop counting: the bound is a rate, so a transient fault cannot lock a head
# for ever (review round 3 — see the knob's comment).
review_attempts() {  # $1 = the head-keyed attempt ledger; prints the in-window dispatch count
  local f=$1 n cut
  # ⛔ `-f` FIRST: `wc`/`awk < missing` is BASH failing to open the redirect, not the tool failing, so a
  # `2>/dev/null` on the tool does not silence it — the suite printed "No such file or directory" for a
  # question it asked on purpose.
  [ -f "$f" ] || { printf '0\n'; return 0; }
  cut=$(( $(date +%s) - REVIEW_ATTEMPT_WINDOW_S ))
  n=$(awk -v cut="$cut" '$1 ~ /^[0-9]+$/ && $1 > cut {c++} END {printf "%d", c+0}' "$f" 2>/dev/null)
  case "${n:-}" in ''|*[!0-9]*) printf '0\n'; return 0;; esac
  printf '%s\n' "$n"
}
# ── FORGIVING A REFUSAL, PRECISELY ───────────────────────────────────────────────────────────────
# ⛔ THE WINDOW DOES NOT MAKE THIS UNNECESSARY, AND DELETING IT WAS WRONG (review round 3, verifier).
# The window bounds how long damage LASTS; it does not stop a refusal consuming the budget. On a loaded
# box: three rc=75 refusals fill the window's allowance, the box quiets, the first REAL review then fails
# rc=6 — and the head is EXHAUSTED on its FIRST paid failure, having spent one review, until the window
# rolls. That is the round-2 defect intact, merely time-boxed. The two mechanisms answer different halves
# and both are needed: this one keeps a free dispatch out of the budget at all, and the window covers the
# classes auto-rail cannot see (rc=3/9 have pre-review paths too, so their state is `retry` and they DO
# consume — there is no state that could tell those apart from a paid failure).
# ⛔ IT DROPS ONE LINE — THE REFUSAL'S OWN. `launch_review` appends exactly one line per verified
# dispatch and this runs only when the LAST dispatch is the refusal, so `sed '$d'` is exact. An earlier
# version truncated the WHOLE ledger, which forgave paid attempts too (two paid failures + one refusal
# reset the budget and bought three more paid reviews); the one-line form is what keeps that closed.
# A failure here leaves the refusal counted — TIGHTER than intended, i.e. fail-closed, the right
# direction for a bound.
review_forgive_refusal() {  # $1 = attempt ledger; drops the newest entry if there is one
  local f=$1 n tmp
  [ -f "$f" ] || return 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  case "${n:-}" in ''|*[!0-9]*) return 0;; esac
  [ "$n" -gt 0 ] || return 0
  tmp="$f.tmp.$$"
  sed '$d' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" && return 0
  rm -f "$tmp" 2>/dev/null
  log_line "$f REVIEW-FORGIVE-FAILED: could not drop the refusal's attempt line — this head is one attempt tighter than intended (fail-closed)"
  return 0
}
# ── THE ACTION, IN ONE PLACE ───────────────────────────────────────────────────────────────────────
# rc 0 = WAIT (a review is already owed at this head), 1 = DISPATCH now, 2 = TERMINAL at this head (a
# fix or the recorder is owed — never another review), 3 = EXHAUSTED WITHIN THE WINDOW (this head has
# spent its dispatch budget for REVIEW_ATTEMPT_WINDOW_S — terminal until the window rolls, NOT for ever,
# because most of what can spend the budget is environmental and must heal without an operator).
# A function, so a test pins the SHIPPED predicate instead of a copy of it: the whole anti-thrash arm IS
# these lines.
review_action() {  # $1 = state, $2 = seconds since dispatch, $3 = attempts already spent at this head
  local age=${2:-0} att=${3:-0}
  case "${1:-}" in
    issues|clean) return 2;;
    # A dispatched review is a WAIT, and it is longer than a rail's: only the reviewer's own exit (or
    # its own 1800 s cap) can end it, and neither is observable from here while it runs.
    pending) [ "$age" -lt "$REVIEW_COOLDOWN_S" ] && return 0
             [ "$att" -lt "$REVIEW_MAX_ATTEMPTS" ] && return 1
             return 3;;
    # It RAN AND LEFT NO VERDICT. ⛔ THIS IS THE ARM THAT MUST BE BOUNDED (review, P1): rc=6/9/10 arrive
    # AFTER the review was paid for, so their age is already past the short window and an unbounded
    # retry is one paid review per review-duration, for ever, at one head.
    retry)   [ "$age" -lt "$COOLDOWN_TRANSIENT_S" ] && return 0
             [ "$att" -lt "$REVIEW_MAX_ATTEMPTS" ] && return 1
             return 3;;
    # ⛔ NOTHING WAS CONSUMED, SO NOTHING IS EXHAUSTED. A refusal waits out the short window and is
    # retried whatever the attempt count says: an environment fault (a loaded box, no `pi`) must recover
    # BY ITSELF, not block a head with a message about money that was never spent. The loop ALSO hands
    # the refusal's own ledger entry back (`review_forgive_refusal`), because this arm only protects the
    # refusal's own pass — without it, three load refusals would still exhaust the FIRST real review's
    # retries, which is a defect merely time-boxed by the window, not fixed.
    refused) [ "$age" -lt "$COOLDOWN_TRANSIENT_S" ] && return 0; return 1;;
    *)       return 1;;
  esac
}
# rc 0 = defer this dispatch (this repo's per-pass burst is spent), 1 = dispatch now.
# A DRIVEN function, not `[ "$n" -ge "$REVIEW_PER_PASS" ]` inline at the loop: the loop cannot be executed
# by the suite, so an inline bound is a line nothing pins — and a bound that silently stops bounding
# (a `-gt` flipped, the counter reset in the wrong place) turns the burst back on with the suite green.
review_should_defer() {  # $1 = reviews already dispatched for THIS repo in THIS pass
  [ "${1:-0}" -ge "$REVIEW_PER_PASS" ]
}
# ── WHICH ARM OWNS A CANDIDATE: review | rail | skip ───────────────────────────────────────────────
# ⛔ ONE PREDICATE, DRIVEN BY THE SUITE, BECAUSE GETTING IT WRONG IS A SILENT MERGE STALL (#3489, P1).
# The first cut of this branch gated the review arm on `[ "$_kind" = green ]` and `continue`d for every
# other candidate — so a RED candidate carrying a marker at an OLDER head was dropped by BOTH arms: the
# review arm refused it (red) and the `continue` prevented the rail path below. Measured 2026-11-06 on
# this box: `gh pr list` on daniel-ospina/agent-infra classified **33 candidates, green=0, red=33** (main
# is red on `bash-suites (1)-(8)` and `verify`, so every PR inherits a red it does not own) — 14 of them
# red-with-a-stale-marker. That class is LANDABLE and was landable on the base: check (c) accepts a
# STALE marker whose `diff=` equals the live diff (`record-review.sh --check-carry`, #3315) and the rail's
# exemption engine merges when the residual reds are not PR-unique. So the `continue` removed reachability
# that existed before this change and no other arm supplies it: `orch-loop.sh` merges only on `GREEN`, the
# red-fixer fires on a RAIL REFUSAL (which no longer happens for a candidate that is never railed), and
# the line's own claim — "the red arm owns this PR" — names the branch it is standing in.
# ⛔ AND THE ASYMMETRY IS THE POINT: an unattested head cannot merge, so a review it does not get is work
# left undone; a markerless red head has NOTHING for the rail to carry (check (c) is red on the missing
# marker alone), so railing it is the noise-and-slot-burn the base's substring filter existed to avoid.
# Hence:
#   green + anything but at-head        -> review  (the defect this change exists for)
#   red   + absent                      -> skip    (no marker anywhere: the red arm owns it, and a review
#                                                  is not bought for a red head — a red head must not be
#                                                  attested clean, #3440)
#   red   + stale|nohead (a marker)      -> rail    (the carry arm + the exemption engine: the only path
#                                                  that can land it, and exactly what the base did)
#   at-head (any kind)                  -> rail    (today's path, untouched)
# ⛔ THE DEFAULT IS `rail`, NEVER `review`: an unclassifiable candidate must fall back to the arm that
# spends nothing. Defaulting to `review` would turn a parse surprise into a paid dispatch.
review_candidate_arm() {  # $1 = candidate kind (green|red), $2 = attestation; prints review|rail|skip
  case "$1:${2:-}" in
    *:at-head)  printf 'rail\n';;    # an attestation at the head that would merge: today's path
    green:*)    printf 'review\n';;  # no attestation for the head that would merge, and it could land
    red:absent) printf 'skip\n';;    # red, and nothing to carry: the red arm owns it
    *)          printf 'rail\n';;    # red WITH a marker (stale/nohead): hand it to the rail, as the base did
  esac
}
# ── PUBLISHING THE STATE ON THE PR, IDEMPOTENTLY ───────────────────────────────────────────────────
# ⛔ THIS IS THE PART THAT ACTUALLY KILLS THE DEFECT: `mergeable=MERGEABLE state=BLOCKED
# reviewDecision=empty` with nothing written on the PR is indistinguishable from "a lane is working on
# this". The state has to be ON THE PR. Mergify expresses a required review as a queue CONDITION it
# reports, and the label-based queues keep their state on the PR and resume from it after a crash; the
# convergent answer is a first-class visible state reconciled by a loop — which this already is.
# ⛔ A COMMENT, NEVER A BODY EDIT: the body is where the attestation marker lives, and an edit after a
# record wipes the proof the gate reads (agent-infra#1224). `review-pr.sh` refuses to PATCH a body for
# the same reason.
# ⛔ IDEMPOTENCE IS BY KEY, NOT BY HOPE. The hidden tag names the state AND the head, so re-running the
# loop in the same state adds NOTHING (a second `review-in-flight` marker for one head is a duplicate
# this cannot emit), while a real transition — in-flight → found-issues — adds exactly one new marker
# instead of rewriting history. `awaiting-review` carries NO head: it is published where the head is
# not yet read (a cap deferral), and it says "no owner yet" about the PR, not about a revision.
publish_review_state() {  # $1 repo, $2 pr, $3 state, $4 head (optional); rc 0 = present (or just posted)
  local repo=$1 pr=$2 state=$3 head=${4:-} tag seen text
  tag="<!-- auto-rail-review:${state}${head:+:$head} -->"
  case "$state" in
    awaiting-review)
      text="🔎 **auto-rail: review needed.** This PR is mergeable and carries no head-bound review attestation. auto-rail owns it: a reviewer is dispatched as soon as this repo has a free slot. **It is not waiting on a lane.**";;
    review-in-flight)
      text="🔎 **auto-rail: review in flight** at \`${head:0:12}\`. No head-bound attestation existed, so a fresh-context reviewer was dispatched (\`review-pr.sh\`, KIND=reviewer) at $(date -u +%FT%TZ). auto-rail records nothing itself — any verdict and its attestation come from that reviewer. **It is not waiting on a lane.**";;
    review-found-issues)
      text="⛔ **auto-rail: the review found blocking issues** at \`${head:0:12}\`. No attestation was recorded, and auto-rail will NOT re-review this head — the findings are in the reviewer's own comment. This head needs a fix; a new head gets a new review.";;
    review-retries-exhausted)
      text="⛔ **auto-rail: the reviewer is not producing a verdict** at \`${head:0:12}\` — ${REVIEW_MAX_ATTEMPTS} dispatch(es) inside ${REVIEW_ATTEMPT_WINDOW_S}s. No attestation exists, and auto-rail is not dispatching another review at this revision until that window rolls — which it does BY ITSELF, so an environmental cause (a rate-limit or auth window, a loaded box) needs no action at all. If this head genuinely cannot be reviewed, push a new head: a new head is a new review.";;
    review-record-unbound)
      text="⚠️ **auto-rail: a review record exists at \`${head:0:12}\` but the PR body carries no marker this loop can bind.** Re-running \`record-review.sh\` for this PR re-posts the signed marker at the same head (that write is idempotent). auto-rail never writes records, so it cannot do this itself — and it is deliberately NOT buying a second review, which would not help. **It is not waiting on a lane.**";;
    review-dispatch-failed)
      text="⚠️ **auto-rail: the reviewer was announced but never started** at \`${head:0:12}\` — the dispatch was rolled back (nothing ran, and no attempt was spent). This corrects the in-flight marker posted before the launch. The head is retried on a later pass; if this state persists, the actuator's reviewer path is broken and the log has the \`REVIEW-LAUNCH-FAILED\` line for it. **Nothing is reviewing this PR right now.**";;
    *) text="auto-rail: review state \`${state}\`.";;
  esac
  # ⛔ A FAILED READ IS NOT "NO MARKER": this script has no `pipefail`, so a `gh` that cannot run would
  # leave the read empty, which reads as ABSENT and posts a DUPLICATE marker on every pass — the exact
  # thrash the idempotence requirement forbids, produced by the check that implements it. Read first,
  # decide second, and refuse to post on an unreadable list.
  # ⛔ THE PAGINATED ENDPOINT, NOT `pr view --json comments`: a PR body's comment list is truncated by
  # the single-page query, so on exactly the busiest PRs — the ones with dozens of review findings — the
  # marker can fall off the page that was read, and the duplicate this check exists to prevent gets
  # posted. `--paginate` reads every page.
  seen=$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate --jq '.[].body' 2>/dev/null) \
    || { log_line "$repo #$pr MARKER-UNREADABLE: could not read the PR's comments to check for an existing review marker — NOT posting (a blind post is a duplicate on every pass)"; return 1; }
  case "$seen" in *"$tag"*) return 0;; esac
  gh pr comment "$pr" --repo "$repo" --body "$(printf '%s\n\n%s' "$text" "$tag")" >/dev/null 2>>"$LOG" \
    || { log_line "$repo #$pr MARKER-FAILED: could not post the review-state marker ($state) — this loop knows the state and GitHub does not"; return 1; }
  log_line "$repo #$pr review state published on the PR: $state"
  return 0
}
# ── THE WRAPPER THAT MAKES THE OUTCOME DURABLE ────────────────────────────────────────────────────
# Runs in a background subshell and writes the exit line UNCONDITIONALLY, so a reviewer that dies at
# once still leaves an outcome rather than a permanent `pending`. Exported (rather than inlined into
# `nohup bash -c`) so the suite can drive it against a stub reviewer without spawning the loop.
run_review() {  # $1 = reviewer script, $2 = PR, $3 = repo, $4 = output file
  bash "$1" "$2" --repo "$3" >> "$4" 2>&1
  printf 'REVIEW-EXIT rc=%s\n' "$?" >> "$4"
}
export -f run_review
# ── THE DISPATCH, VERIFIED THE SAME WAY `launch_rail` IS ────────────────────────────────────────────
# `( … ) &` returns 0 whether or not anything ran (measured cycle 4 on this very file for the rail), and
# a dispatch that never started must be RETRIED next pass, not remembered as in flight for
# REVIEW_COOLDOWN_S. So the record is removed on proof that nothing started.
launch_review() {  # $1 = repo, $2 = PR, $3 = head, $4 = state file, $5 = attempt ledger; rc 0 = started
  local repo=$1 pr=$2 head=$3 out=$4 led=${5:-} pid
  printf 'REVIEW-DISPATCHED at=%s head=%s repo=%s pr=%s\n' "$(date +%s)" "$head" "$repo" "$pr" > "$out" \
    || { log_line "$repo #$pr REVIEW-LAUNCH-FAILED: cannot write the review record at $out — nothing was dispatched and no cooldown was consumed"; return 1; }
  nohup bash -c 'run_review "$@"' _ "$REVIEW_SCRIPT" "$pr" "$repo" "$out" >> "$LOG" 2>&1 &
  pid=$!
  log_line "$repo #$pr no attestation at head $head -> dispatching reviewer (KIND=reviewer, $REVIEW_SCRIPT)"
  sleep "$LAUNCH_VERIFY_S"
  if kill -0 "$pid" 2>/dev/null || [ "$(wc -l < "$out")" -gt 1 ]; then
    # ⛔ THE ATTEMPT IS COUNTED **HERE**, NOT AT THE RECORD WRITE (review, P1). A dispatch that never
    # started is rolled back two lines below and must consume NOTHING — otherwise three transient
    # `nohup` failures would read as three paid reviews and mark the head EXHAUSTED without one ever
    # having run. Only verified dispatches are money, so only verified dispatches are counted.
    if [ -n "$led" ]; then
      printf '%s\n' "$(date +%s)" >> "$led" 2>/dev/null \
        || log_line "$repo #$pr REVIEW-ATTEMPT-UNRECORDED: could not append to $led — this dispatch is running but is NOT counted against REVIEW_MAX_ATTEMPTS, so the per-head bound is weaker than it says"
    fi
    return 0
  fi
  log_line "$repo #$pr REVIEW-LAUNCH-FAILED — nothing started within ${LAUNCH_VERIFY_S}s (no live child, nothing beyond the dispatch line in $out); the record is removed so this head is retried next pass instead of being reported as in flight for ${REVIEW_COOLDOWN_S}s"
  rm -f "$out"
  return 1
}
# ⛔ THE FAIL-VISIBLE PATH, AS A FUNCTION (review round 5, measured P1). The candidate search's stdout IS
# the candidate file, so its diagnostics go to stderr — and unredirected stderr is launchd's
# StandardErrorPath, the channel this file's own header records as the grave of the original defect
# ("1.5 MB of tracebacks accumulated in StandardErrorPath where nobody looks"). So a `gh` failure still
# logged `candidates=0`, byte-identical to a healthy idle pass: the ALIVE/REFUSING/IDLE fix was INERT on
# the exact failure it was written for. The search now (a) sends its stderr to $LOG at the call site,
# (b) EXITS NON-ZERO when it could not read the queue — it used to `sys.exit(0)` after printing
# SEARCH-FAILED, which no caller could see — and (c) this function turns that rc into a line in the log
# an operator reads the pass line in, plus a refusal to act on a HALF-READ queue (a search that died
# mid-stream has a truncated candidate list, which is not the same thing as a short queue).
report_search() {  # $1 = repo, $2 = the search's rc; rc 0 = this pass must not act
  [ "$2" -eq 0 ] && return 1
  log_line "$1 CANDIDATE-PASS-FAILED rc=$2 — the candidate search did not complete, so this pass has NO QUEUE (which is not an empty queue) and launches nothing"
  return 0
}
# Keep the TCC-free rail clone current BEFORE using it. A failed refresh is LOUD but not fatal: the
# previous HEAD then runs, which is strictly better than not merging, and the log says which happened.
if [ -d "$RAIL_HUB/.git" ]; then
  if git -C "$RAIL_HUB" fetch -q --depth 1 origin main 2>>"$LOG" \
     && git -C "$RAIL_HUB" -c advice.detachedHead=false checkout -q -B main origin/main 2>>"$LOG"; then
    log_line "rail-hub refreshed -> $(git -C "$RAIL_HUB" rev-parse --short HEAD)"
  else
    log_line "rail-hub REFRESH FAILED — running $(git -C "$RAIL_HUB" rev-parse --short HEAD) (possibly stale)"
  fi
else
  log_line "REFUSED: no rail clone at $RAIL_HUB — the rail cannot be executed from ~/Documents (TCC)"
  exit 3
fi
# ⛔ THE REVIEW SEAM'S ABSENCE IS LOUD BUT NOT FATAL, AND THE DIFFERENCE IS DELIBERATE. A missing RAIL
# is fatal because nothing can land; a missing REVIEWER is not, because the rail still lands every
# PR that already carries an attestation. Exiting here would turn a missing capability into a total
# merge stall — the larger failure. So it is said ONCE at start, in the log an operator reads the pass
# line in, and the pass then names each PR it could not serve.
# ⛔ AND IT IS COMPUTED **AFTER** THE REFRESH ABOVE, WHICH IS THE WHOLE POINT OF THE SEAM (review, P2).
# `REVIEW_SCRIPT` defaults to `$RAIL_HUB/scripts/review-pr.sh` — the file the refresh is what fetches —
# so an existence test taken BEFORE it answers a question about the PREVIOUS clone. Latched there, a job
# that starts while `~/rail-hub` is behind `origin/main` (the tolerated "running … (possibly stale)"
# case) would read REVIEW_AVAILABLE=0 and log "no reviewer at $REVIEW_SCRIPT" — naming a path that the
# refresh two lines earlier has just created — for the entire lifetime of the process, dispatching
# nothing. An inert review arm with a clean log is this file's characteristic failure, not a new one.
# ⛔ EXISTENCE IS NOT CAPABILITY, and the bar is this repo's own (`gate-policy.sh`): a file that merely
# has the right NAME proves nothing about being callable. A zero-byte `review-pr.sh` is valid bash: it
# exits 0, `run_review` writes `REVIEW-EXIT rc=0`, the head reads `clean` and — because clean is
# TERMINAL — a head nobody reviewed is reported "REVIEW-RECORDED cleanly" and never looked at again.
REVIEW_AVAILABLE=0
if [ -f "$REVIEW_SCRIPT" ] && [ -x "$REVIEW_SCRIPT" ] && [ -s "$REVIEW_SCRIPT" ] \
   && bash -n "$REVIEW_SCRIPT" 2>/dev/null; then
  REVIEW_AVAILABLE=1
else
  echo "$(date -u +%FT%TZ) REVIEW-UNAVAILABLE: no usable reviewer at $REVIEW_SCRIPT (needs to exist, be executable, non-empty and parseable) — unattested green PRs will stay unattested (the rail path is unaffected)" >> "$LOG"
fi
log_line "auto-rail started max=$MAX max_total=$MAX_TOTAL interval=${INTERVAL}s red_cap=$RED_CAP rail=$RAIL_SCRIPT"

while :; do
  for repo in $REPOS; do
    _cand=/tmp/auto-rail-cand.$$
    python3 - "$repo" "$RED_CAP" <<'PY' 2>> "$LOG" > "$_cand"
import json,re,subprocess,sys
repo=sys.argv[1]
try:
    r=subprocess.run(["gh","pr","list","--repo",repo,"--state","open","--limit","100",
        "--json","number,mergeable,isDraft,statusCheckRollup,body,headRefOid"],capture_output=True,text=True)
except Exception as e:
    # ⛔ THIS IS HOW THE ACTUATOR WAS DEAD FOR DAYS WITHOUT A SYMPTOM (measured 2026-10-30): `gh` exists
    # ONLY at ~/.pi/agent/shims/gh, that directory was missing from this job's PATH, so subprocess raised
    # FileNotFoundError here, the whole heredoc died, and the pass logged `candidates=0` — byte-identical
    # to a healthy idle pass. 1.5 MB of tracebacks accumulated in StandardErrorPath where nobody looks.
    print("SEARCH-FAILED %s: %s" % (type(e).__name__, e), file=sys.stderr); sys.exit(2)
o=r.stdout
try: prs=json.loads(o)
except Exception:
    # ⛔ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE (2026-10-30). This block used to `sys.exit(0)` on any
    # parse failure, so a `gh` that could not run at all (PATH, auth, rate limit) printed ZERO candidates
    # and the pass logged `candidates=0` — the exact ALIVE/REFUSING/IDLE ambiguity this script's own
    # comments call out. Say it instead.
    print("SEARCH-FAILED rc=%s stderr=%s" % (r.returncode, (r.stderr or "").strip().splitlines()[:1]), file=sys.stderr)
    sys.exit(2)
green=[]; red=[]

# ⛔ THE ONE DEFINITION OF "IS THIS ATTESTED AT THE HEAD THAT WOULD MERGE" (#3489). The old rule was a
# SUBSTRING (`"review recorded:" in body`), and it was wrong in both directions:
#   * it dropped a PR with NO marker entirely, which is the defect this change exists for — such a PR
#     was not "waiting on a lane", it was not a candidate at all, so nothing ever moved; and
#   * it PASSED a PR whose body merely QUOTES the marker shape (our own PR bodies do), or carries one
#     for a DIFFERENT PR number, or for an OLDER head — the rail then refuses for "no head-bound
#     record" and the actuator never learns why.
# So the marker is parsed the way the GATE names it: `review recorded: reviews/<PR>.json verdict=<v> @
# <40-hex>` with the repo suffix on the same line. ⛔ WHICH VERDICTS MAY LAND IS THE GATE'S DECISION, NOT
# THIS ACTUATOR'S: any recorded verdict at this head is `at-head`, because the question asked here is
# only "does an attestation exist for the head that would merge?" (a non-clean record still names a
# review that happened, and re-buying a review of the same head is not the remedy for it).
# ⛔ ANCHORED AT THE START OF THE LINE, EXACTLY AS THE GATE IT FEEDS IS. The gate's own regex
# (`check-pipeline-compliance.sh`: `^review recorded: reviews/<PR>.json verdict=(clean|clean-micro|clean-low)
# @ <sha>...`) is line-anchored on purpose: an INDENTED or mid-sentence marker is a QUOTATION, not a
# record — record-review.sh emits the marker as a line of its own. The first cut of this parse had no
# `^`, so a body that merely quoted the shape on a line carrying the repo slug read `at-head`: the rail is
# then launched for something check (c) will refuse for ever, and — worse — `at-head` is the ONLY value
# that disables the review arm, so the PR could never be reviewed either. That is the #3489 failure
# (invisible, unattributable, permanent) reproduced by the change that exists to remove it. `^` here is
# per-LINE because the loop below feeds this one line at a time; it is not MULTILINE and must not be.
MARKER_RE = re.compile(r"^review recorded: reviews/(\d+)\.json verdict=[a-z][a-z-]* @ ([0-9a-f]{40})")

def attestation(body, head, pr, repo):
    "at-head | stale | absent | nohead — never an inference from a partial match."
    if not head:
        return "nohead"          # no head means nothing can be at it; the reviewer re-reads the head
    seen = []
    for line in (body or "").splitlines():
        if ("(%s)" % repo) not in line:
            continue                 # the gate binds the repo; a marker naming another repo is not ours
        for m in MARKER_RE.finditer(line):
            if m.group(1) == str(pr):
                seen.append(m.group(2).lower())
    if head in seen:
        return "at-head"
    return "stale" if seen else "absent"

for p in prs:
    # A DRAFT CAN NEVER MERGE: the rail refuses it in one line ("PR is a DRAFT").
    if p.get("isDraft"):
        continue
    g={}
    for c in p.get("statusCheckRollup") or []:
        k=c.get("name") or c.get("context")
        if k not in g or (c.get("databaseId") or 0) > (g[k].get("databaseId") or 0): g[k]=c
    redn=inflight=0
    for k,c in g.items():
        st,co=c.get("status"),c.get("conclusion")
        if st and st!="COMPLETED": inflight+=1; continue
        if co in ("SUCCESS","NEUTRAL","SKIPPED","CANCELLED","STALE"): continue
        redn+=1
    if not g or inflight: continue
    # ⛔ AND A RED PR IS STILL A CANDIDATE -- OTHERWISE THIS ACTUATOR CAN NEVER CLEAR THE ACTUAL QUEUE.
    # Measured 2026-10-30: the open queue was 12 PRs with red>0 and 0 with red==0, because `main` is red
    # on pre-existing broken suites, so EVERY PR inherits a red that is not its own. The rail has an
    # exemption engine for exactly that (scripts/ci_exemption.py: an id is EXEMPT only when it was
    # measured on main over several runs), and this filter never let the rail reach it -- the actuator
    # was strictly stricter than the gate it feeds, which is why 32 PRs sat. Green goes first and
    # red-handed-over rails are CAPPED (RED_CAP) so a burst cannot burn the API budget; the rail still
    # refuses anything whose red is unique to the PR.
    att = attestation(p.get("body") or "", (p.get("headRefOid") or "").lower(), p["number"], repo)
    (green if redn==0 else red).append((redn, p["number"], att))
# ⛔ THE CANDIDATE LINE CARRIES THREE FIELDS — <green|red>\t<PR>\t<att> — and each one has a consumer:
#   * the KIND is what tells the loop whether a review may be bought at all (a RED head has to change
#     before an attestation can land it, so buying a review for it is money spent on a dying revision);
#   * the ATTESTATION is the classification #3489 is about, computed HERE because this is where the
#     body is already fetched — no second read, and one definition of the predicate (the suite drives
#     this heredoc directly, so the rule is pinned where it is written).
for _r,n,a in sorted(green): print("green\t%d\t%s" % (n,a))
# Attested reds are emitted FIRST so RED_CAP cannot be spent on a red that a review could not help.
for _r,n,a in sorted(red, key=lambda t: (t[2] != "at-head", t[0], t[1]))[:int(sys.argv[2])]:
    print("red\t%d\t%s" % (n,a))
PY
    # ⛔ A FAILED SEARCH IS NOT AN EMPTY QUEUE, AND IT IS SAID OUT LOUD (review round 5, measured P1).
    # `2>> "$LOG"` above is what makes SEARCH-FAILED visible at all — unredirected it went to launchd's
    # StandardErrorPath. `report_search` is what makes it a VERDICT: a non-zero search means the pass
    # must not act, because a search that died mid-stream leaves a TRUNCATED candidate list, and acting
    # on a truncated list is exactly the half-read-queue launch this pass must never make.
    report_search "$repo" "$?" && { rm -f "$_cand"; continue; }
    # ⛔ A SILENT PASS IS NOT EVIDENCE OF A HEALTHY PASS (measured 2026-10-24). This actuator logged
    # NOTHING between 14:47 and 15:20 — alive, polling, and either finding zero candidates or
    # refusing silently — and those two readings are indistinguishable from the log. That is the
    # exact ALIVE / REFUSING / IDLE ambiguity the fleet keeps paying for (agent-infra #2700): a
    # capability that cannot say "I looked and found nothing" gets diagnosed as dead on the next
    # bad day. One line per repo per pass makes the answer readable.
    # The counts are PER REPO (that is the fix) and `unattributed` is printed rather than dropped: a
    # rail nobody can attribute is unknown load, and a report that omits it reads as "none".
    read -r _own _total _unk <<< "$(rails_for_repo "$repo" $REPOS)"
    log_line "$repo pass: candidates=$(wc -l < "$_cand") cand_bytes=$(wc -c < "$_cand" 2>/dev/null || echo MISSING) rails_on_repo=$_own rails_live=$_total unattributed=$_unk max=$MAX max_total=$MAX_TOTAL"
    # The per-pass review budget is PER REPO (the same scope as MAX): another repo's reviews must not
    # starve this one's, and this one's must not leak into the next repo's pass.
    _rdispatched=0
    while IFS=$'\t' read -r _kind pr _att; do
      [ -z "${pr:-}" ] && continue
      if denied "$repo" "$pr"; then log_line "$repo #$pr DENIED — duplicate-pair member or contradictory PR pending a decision"; continue; fi
      # ⛔ THE SAME FAIL-OPEN THIS FILE FORBIDS AT THE COUNTER, one line below it. No `pipefail` here,
      # so a `ps` that cannot run left `grep -c` reading EOF and printing `0`: "I cannot see the process
      # table" became "no rail is running for #pr", and the actuator would launch a SECOND rail for a PR
      # that already has one — burning the shared REST budget, doubling the merge attempt, and inflating
      # this repo's own count so other candidates of the repo this change exists to unstarve are deferred.
      # Unreadable is not zero: skip the candidate loudly (a pass that cannot rule a rail out must not add one).
      # The question is asked about THIS REPO's #pr, not about the number alone (round 5: a live rail on
      # agent-infra#2710 made tortoise#2710 skip, because a PR number is per repo).
      rail_already_running "$repo" "$pr"; _rail_rc=$?
      if rail_says_skip "$_rail_rc"; then
        if [ "$_rail_rc" -eq 0 ]; then log_line "$repo #$pr skipped (rail already running)"
        else log_line "$repo #$pr skipped — cannot rule out an existing rail (fail-closed)"; fi
        continue
      fi
      # ⛔ THIS REPO'S BUDGET, NOT THE BOX'S. `rails_should_defer` adds the unattributable population to
      # this repo's own count (fail-closed) and keeps the aggregate as a second, independent clause:
      # another repo's rails can only decide this repo's candidates once the AGGREGATE is reached.
      if candidate_deferred "$repo" $REPOS; then
        read -r _own _total _unk <<< "$(rails_for_repo "$repo" $REPOS)"
        log_line "$repo #$pr deferred ($_own rails on this repo + $_unk unattributed, $_total live in total, max=$MAX max_total=$MAX_TOTAL)"
        # ⛔ A CAP DEFERRAL IS EXACTLY WHERE AN UNATTESTED PR GOES INVISIBLE AGAIN, so the state is
        # published HERE as well: a PR that is mergeable, has no review owner and is waiting on a slot
        # must not look like a PR waiting on a lane. Keyed on the STATE (no head — the head is read
        # further down), so this is a no-op on every pass after the first. A RED head is left out: it
        # cannot be landed by an attestation, its owner is the red arm, and its state is already
        # visible as a red check.
        [ "$_kind" = green ] && [ "$_att" != at-head ] && publish_review_state "$repo" "$pr" awaiting-review
        continue
      fi
      # ⛔ A FAILED HEAD READ IS NOT AN EMPTY HEAD. `gh` failing here used to write the cooldown key
      # with an EMPTY head, which no later pass's real head can ever match — so the same PR was railed
      # again every interval, each launch taking a MAX slot from the candidates this actuator exists to
      # serve. Skip the candidate instead, and say so.
      head=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null) \
        || { log_line "$repo #$pr HEAD-READ-FAILED: gh rc=$? — skipping this candidate (a cooldown keyed to an empty head would re-rail it every pass)"; continue; }
      [ -n "$head" ] || { log_line "$repo #$pr HEAD-READ-FAILED: gh returned an empty head — skipping this candidate"; continue; }
      # ⛔ THE ONE DECISION THIS CHANGE ADDS, AND IT IS MADE FROM THE ATTESTATION AT THE HEAD THAT WOULD
      # MERGE (#3489). `at-head` is today's behaviour, untouched, below. Anything else is decided by
      # `review_candidate_arm` — which is NOT simply "review it": a RED head with a marker is handed to
      # the rail below (the carry + exemption path, unchanged from the base), because the review arm
      # cannot land a red head and dropping it was a silent merge stall (P1, review round 3).
      # The classification was computed by the candidate search from ITS `gh pr list` read (body +
      # headRefOid) while the head used for the state key below is this candidate's own read, a second
      # apart. ⛔ THAT RACE IS NAMED RATHER THAN CLOSED, because closing it costs a second `gh` call per
      # candidate per pass and it cannot produce a wrong ACTION: a push in between means the reviewer
      # re-reads the head itself and reviews what is really there (`review-pr.sh` binds its record to the
      # head it reviewed), and a record that landed in between means `review-pr.sh` exits 5 — "a clean
      # record already exists at this head" — having spent nothing.
      # ⛔ WHICH ARM OWNS THIS CANDIDATE IS DECIDED ONCE, BY A DRIVEN PREDICATE (P1, review round 3).
      # Default `rail` — the arm that spends nothing — so an at-head candidate (which never consults the
      # predicate) and any unclassifiable one still take today's path, and a parse surprise can never
      # become a paid dispatch.
      _rarm=rail
      if [ "$_att" != at-head ]; then
        _rarm=$(review_candidate_arm "$_kind" "$_att")
        if [ "$_rarm" = skip ]; then
          log_line "$repo #$pr AWAITING-REVIEW ($_att) and its checks are RED — no marker at ANY head to carry and no review is bought for a red head (a red head must not be attested clean, #3440); the red arm owns this PR"
          continue
        fi
        if [ "$_rarm" = rail ]; then
          # ⛔ RED, BUT IT CARRIES A MARKER AT AN OLDER HEAD — SO THE RAIL IS STILL THE RIGHT ARM, AND
          # DROPPING IT HERE WAS THE P1 REVIEW FINDING. There is a carry (`diff=` unchanged) and an
          # exemption engine that can land this revision; nothing else in the fleet can. The line is
          # logged so the pass says which arm took it instead of implying a lane is working on the PR.
          log_line "$repo #$pr RED with a marker at an OLDER head ($_att) — NOT reviewed; handed to the RAIL, where a diff-matched carry plus the exemption engine is the only path that can land a red head (dropping it here would remove reachability the base had)"
        fi
      fi
      if [ "$_att" != at-head ] && [ "$_rarm" = review ]; then
        if [ "$REVIEW_AVAILABLE" != 1 ]; then
          log_line "$repo #$pr AWAITING-REVIEW ($_att) and this box has no reviewer at $REVIEW_SCRIPT — the PR stays unattested until one is reachable (said once at start, named here per candidate)"
          continue
        fi
        # One state file per (repo, PR, HEAD): that file IS the head-keyed cooldown for this step, for
        # the same reason `$TRIED` is for the rail — a verdict that only a new head can change must not
        # be re-bought every 180 s, and a new head is a different key by construction.
        _rout="$RAIL_DIR/review-$(printf '%s' "$repo" | tr '/' '-')-$pr-$head.out"
        # The attempt ledger is a SEPARATE append-only file with the SAME (repo, PR, head) key: the
        # record is truncated on every replay, so a count kept in it would be destroyed by the very
        # replay it bounds. A new head is a new key, so a fix always starts from a clean count.
        _ratt="$RAIL_DIR/review-$(printf '%s' "$repo" | tr '/' '-')-$pr-$head.attempts"
        _rstate=$(review_state "$_rout")
        _rattn=$(review_attempts "$_ratt")
        _rdat=$(review_dispatched_at "$_rout")
        case "${_rdat:-}" in ''|*[!0-9]*) _rage=0;; *) _rage=$(( $(date +%s) - _rdat )); [ "$_rage" -ge 0 ] || _rage=0;; esac
        review_action "$_rstate" "$_rage" "$_rattn"; _ract=$?
        if [ "$_ract" -eq 0 ]; then
          # ⛔ THE WINDOW IN THE LOG MUST BE THE ONE THE PREDICATE USED (review round 3, P3): `_ract` is 0
          # for `retry`/`refused` on COOLDOWN_TRANSIENT_S, NOT on REVIEW_COOLDOWN_S, so a single hardcoded
          # number told the operator "within its 2700s window" about a 900 s comparison — on the file's own
          # primary instrument.
          case "$_rstate" in
            pending) _rwin=$REVIEW_COOLDOWN_S;;
            *)       _rwin=$COOLDOWN_TRANSIENT_S;;
          esac
          log_line "$repo #$pr review $_rstate at $head — dispatched $(( _rage / 60 ))m ago, within its ${_rwin}s window for this state; waiting, not re-dispatching (a slow review is not a stuck one)"
          continue
        fi
        if [ "$_ract" -eq 3 ]; then
          # ⛔ EXHAUSTED IS NOT A WAIT AND NOT A RETRY: this head has spent its paid attempts and still
          # has no verdict, so dispatching again buys the same failure at review prices. Publishing it
          # is what keeps the PR from reading as "a lane is working on it" — the rest of this step only
          # exists to keep that from happening.
          publish_review_state "$repo" "$pr" review-retries-exhausted "$head"
          log_line "$repo #$pr REVIEW-RETRIES-EXHAUSTED at $head — $_rattn dispatch(es) inside ${REVIEW_ATTEMPT_WINDOW_S}s (cap $REVIEW_MAX_ATTEMPTS, last state $_rstate, record $_rout, ledger $_ratt); not dispatching again until the window rolls. A new head is a new key and gets a review immediately"
          continue
        fi
        if [ "$_ract" -eq 2 ]; then
          if [ "$_rstate" = issues ]; then
            publish_review_state "$repo" "$pr" review-found-issues "$head"
            log_line "$repo #$pr REVIEW-FOUND-ISSUES at $head ($_rout) — no attestation was recorded and this head is NOT re-reviewed; it needs a fix, and a new head gets a new review"
          else
            # ⛔ rc=0/5 MEANS A RECORD EXISTS AT THIS HEAD AND THE **BODY** DOES NOT CARRY ITS MARKER —
            # a state `review-pr.sh` documents as expected (its evidence post is best-effort, and a body
            # edit wipes the marker: agent-infra#1224). Logging "re-running the recorder is the remedy"
            # while nothing performs it left the PR exactly as invisible as #3489's `reviewDecision=empty`
            # — for ever, because the key never changes without a new head (review, P2). This actuator
            # must NOT call the recorder (a record is minted only from a fresh reviewer's evidence), so
            # the remedy is PUBLISHED where a human/operator will read it instead.
            publish_review_state "$repo" "$pr" review-record-unbound "$head"
            log_line "$repo #$pr REVIEW-RECORDED cleanly at $head but the PR body carries no marker this actuator can bind ($_rout) — the recorder remedy is published on the PR; this actuator never writes records and is NOT re-reviewing (a second review would not help)"
          fi
          continue
        fi
        # ⛔ THE BURST BOUND, AND IT PUBLISHES WHILE IT WAITS: a PR queued behind this repo's own
        # reviews must still not look like a PR waiting on a lane.
        if review_should_defer "$_rdispatched"; then
          publish_review_state "$repo" "$pr" awaiting-review
          log_line "$repo #$pr AWAITING-REVIEW ($_att at $head) — $_rdispatched review(s) already dispatched for this repo this pass (cap $REVIEW_PER_PASS); this head is next in the queue"
          continue
        fi
        # ⛔ A REFUSAL SPENT NOTHING, SO ITS OWN LEDGER LINE COMES STRAIGHT BACK (review rounds 2 and 3):
        # the window bounds how long damage lasts but would still let three load refusals exhaust the
        # FIRST real review's retries. `review_forgive_refusal` drops exactly that one line, and only when
        # the last dispatch is the refusal — never a paid entry.
        [ "$_rstate" = refused ] && review_forgive_refusal "$_ratt"
        publish_review_state "$repo" "$pr" review-in-flight "$head"
        # ⛔ A ROLLED-BACK DISPATCH MUST CORRECT THE MARKER IT JUST POSTED (review round 3, P2). The
        # in-flight publish is deliberately BEFORE the launch (a dispatched review must never be
        # invisible), so when the launch is proven not to have started the comment is already on the PR
        # claiming "a fresh-context reviewer was dispatched". The record is removed, so every later pass
        # reads `none` and re-publishes the SAME tag — a no-op — leaving a PR that reads `review in flight`
        # with nothing running and no attestation coming: the "indistinguishable from a lane" disguise this
        # PR exists to remove, and the log line even claims the opposite.
        launch_review "$repo" "$pr" "$head" "$_rout" "$_ratt" \
          || { publish_review_state "$repo" "$pr" review-dispatch-failed "$head"; continue; }
        _rdispatched=$(( _rdispatched + 1 ))
        continue
      fi
      # The rail writes its verdict into rails/auto-<owner>-<repo>-<pr>.out. Computed ONCE, before the
      # cooldown read AND before the launch, so the file the cooldown judges and the file the launch
      # writes are the same file by construction (they were two separate expressions).
      _out="$RAIL_DIR/auto-$(printf '%s' "$repo" | tr '/' '-')-$pr.out"
      now=$(date +%s)
      if grep -q "^$pr[[:space:]]$head[[:space:]]" "$TRIED" 2>/dev/null; then
        ts=$(grep "^$pr[[:space:]]$head[[:space:]]" "$TRIED" | tail -1 | awk '{print $3}')
        age=$(( now - ${ts:-0} ))
        # Which cooldown applies is a DRIVEN function (`cooldown_for`), not three hand-typed branches:
        # only CONFLICTED / DRAFT / DENIED are answers a new head is required to change, and an attempt
        # that left NO verdict is not one of them (it is retried on the short cooldown, not held 6 h).
        _cool=$(cooldown_for "$_out")
        if [ "$age" -lt "$_cool" ]; then
          if [ ! -f "$_out" ]; then
            log_line "$repo #$pr skipped — railed $(( age / 60 ))m ago and NO verdict was ever recorded at $_out; retry in $(( (_cool - age) / 60 ))m"
          elif [ "$_cool" = "$COOLDOWN_TRANSIENT_S" ]; then
            log_line "$repo #$pr skipped — railed $(( age / 60 ))m ago on a verdict that CAN change without a new head; retry in $(( (_cool - age) / 60 ))m"
          else
            log_line "$repo #$pr skipped — this head ($head) was already railed $(( age / 60 ))m ago on a verdict that only a NEW HEAD can change"
          fi
          continue
        fi
      fi
      # ⛔ THE LAUNCH IS A DRIVEN FUNCTION because the ledger and the launch must agree: the row is
      # written first (a rail may refuse in two seconds, and that case must cool down), and it is ROLLED
      # BACK when the launch is proven not to have started (round 5: `nohup … &` returns 0 whether or not
      # anything ran). See `launch_rail` for what the verification does and does not prove.
      launch_rail "$repo" "$pr" "$head" "$_out" || continue
    done < "$_cand"
    rm -f "$_cand"
  done
  sleep "$INTERVAL"
done
