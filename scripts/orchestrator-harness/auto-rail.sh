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
# ⛔ DIGITS ARE NOT ENOUGH: A VALUE BEYOND bash's LONG_MAX MAKES EVERY COMPARISON AN ERROR, AND AN ERROR
# READS AS FALSE. The `case '':|*[!0-9]*` guards below accept `99999999999999999999`; `[ 0 -ge 999… ]`
# prints "integer expression expected" and returns 2, which every `if` in this file reads as FALSE — so
# REVIEW_PER_PASS stops bounding (one PAID reviewer per candidate per pass), REVIEW_COOLDOWN_S stops
# delaying a second paid reviewer over a head already in flight, REVIEW_MAX_ATTEMPTS exhausts at ZERO
# attempts, and REVIEW_ATTEMPT_WINDOW_S wraps `cut` negative so nothing ever expires. All four were
# demonstrated by driving the shipped functions. A LENGTH bound makes the error path unreachable; nine
# digits is ~31 years in seconds, so no lawful window or count is excluded.
knob_fits() {  # $1 = knob name, $2 = its value; refuses a value whose LENGTH breaks `[ ]`
  [ "${#2}" -le 9 ] && return 0
  echo "$(date -u +%FT%TZ) REFUSED: $1='$2' is longer than 9 digits — bash's numeric comparison errors above LONG_MAX, and an ERROR reads as FALSE to every caller, i.e. no bound at all" >> "$LOG"
  exit 3
}
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
# ⛔ THE LENGTH BOUND RUNS **BEFORE** THE NUMERIC COMPARISONS: `[ 99999999999999999999 -gt 0 ]` is ITSELF
# the error this guard exists to prevent, so a length check placed BELOW it never runs — measured, the
# refusal then came from the `-gt 0` line saying "is not a POSITIVE integer", which is the wrong reason and
# sends the operator looking for a zero they never set.
knob_fits REVIEW_COOLDOWN_S "$REVIEW_COOLDOWN_S"
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
knob_fits REVIEW_ATTEMPT_WINDOW_S "$REVIEW_ATTEMPT_WINDOW_S"
[ "$REVIEW_ATTEMPT_WINDOW_S" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: REVIEW_ATTEMPT_WINDOW_S='${REVIEW_ATTEMPT_WINDOW_S}' is not a POSITIVE integer — 0 makes every attempt expire the instant it is written, i.e. no bound at all, which is the paid loop this counter exists to stop" >> "$LOG"; exit 3; }
REVIEW_MAX_ATTEMPTS=${REVIEW_MAX_ATTEMPTS:-3}
case "${REVIEW_MAX_ATTEMPTS}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: REVIEW_MAX_ATTEMPTS='${REVIEW_MAX_ATTEMPTS}' is not a non-negative integer — a non-number makes the attempt comparison an ERROR, which reads as FALSE, i.e. no bound at all" >> "$LOG"; exit 3;; esac
knob_fits REVIEW_MAX_ATTEMPTS "$REVIEW_MAX_ATTEMPTS"
[ "$REVIEW_MAX_ATTEMPTS" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: REVIEW_MAX_ATTEMPTS='${REVIEW_MAX_ATTEMPTS}' is not a POSITIVE integer — 0 makes every head EXHAUSTED before its first dispatch, which is the review arm silently disabled while the log reads clean; REVIEW_PER_PASS=0 is the lawful way to disable it" >> "$LOG"; exit 3; }
# ⛔ EVERY NUMERIC KNOB THIS STEP READS THAT HAS NO `-gt 0` COMPARISON OF ITS OWN. `LAUNCH_VERIFY_S` and
# `COOLDOWN_TRANSIENT_S` were unvalidated for exactly this reason and are compared in the same `[ ]`
# arithmetic — `COOLDOWN_TRANSIENT_S=abc` makes `[ "$age" -lt "$_cool" ]` an ERROR, which reads as FALSE,
# i.e. no cooldown at all: re-railing/re-reviewing on every pass. `REVIEW_PER_PASS` is length-checked here
# too (it has no `-gt 0`), so this is the only place its magnitude is bounded.
knob_fits LAUNCH_VERIFY_S "$LAUNCH_VERIFY_S"
knob_fits COOLDOWN_TRANSIENT_S "$COOLDOWN_TRANSIENT_S"
knob_fits REVIEW_PER_PASS "$REVIEW_PER_PASS"
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
  RAIL_SCRIPT="$RAIL_SCRIPT" nohup bash "$RAIL_SCRIPT" "$pr" --repo "$repo" $extra < /dev/null > "$out" 2>&1 &
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
# ⛔ THE AGE OF A DISPATCH WITHOUT AN EPOCH (review round 7, P3, measured). `review_dispatched_at` prints
# nothing when the record has no dispatch line (a record written by an older auto-rail, a foreign/truncated
# record), and the loop then used `0` — which is BOTH "no measurement" and a legitimate value — so a
# `retry`/`refused` record with an exit line but no epoch reported "dispatched 0m ago, within its 900s
# window" on every pass and waited FOR EVER: never retried, never exhausted, never published again. The
# file's own mtime is a real, conservative measurement (it is at least as new as the dispatch, so the age
# it yields is never larger than the truth), so it is used as the fallback and named as such in the log.
# rc 0 = epoch, 1 = mtime fallback, 2 = nothing measurable.
review_age() {  # $1 = the review's output file
  local f=$1 ep mt
  ep=$(review_dispatched_at "$f")
  case "${ep:-}" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$ep"; return 0;;
  esac
  [ -f "$f" ] || return 2
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  case "${mt:-}" in
    ''|*[!0-9]*) return 2;;
  esac
  printf '%s\n' "$mt"; return 1
}

# ⛔ AND THE SECONDS THE LOOP ACTS ON COME FROM HERE, NOT FROM AN INLINE EXPRESSION (review round 8, P3,
# measured): the fallback was pinned only by the TEXT of the call and by the log's wording, so a one-line
# insertion after that call (`_rdat=$(date +%s)`) restored the permanent-WAIT defect with the suite green.
# The arithmetic lives in a function the suite can drive, and the loop's one call is pinned for adjacency.
# prints the age in seconds; rc = review_age's rc (0 epoch, 1 mtime, 2 unmeasurable, age then 0).
review_dispatch_age() {  # $1 = the review's output file
  local f=$1 v rc now
  v=$(review_age "$f"); rc=$?
  if [ "${rc:-2}" = 2 ]; then printf '0\n'; return 2; fi
  case "${v:-}" in
    ''|*[!0-9]*) printf '0\n'; return 2;;
  esac
  now=$(date +%s)
  v=$(( now - v )); [ "$v" -ge 0 ] || v=0
  printf '%s\n' "$v"; return "${rc:-0}"
}
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
  # ⛔ `-e`/`-f` FIRST: `wc`/`awk < missing` is BASH failing to open the redirect, not the tool failing, so
  # a `2>/dev/null` on the tool does not silence it — the suite printed "No such file or directory" for a
  # question it asked on purpose.
  # ⛔ `-e` BEFORE `-f` (review cycle 2, P2, measured): `-f` ALONE answers "not a regular file" with 0
  # dispatches, i.e. "nothing has been spent" — the one fail-open direction this block exists to forbid. A
  # DIRECTORY at the ledger path (an interrupted state-dir create, a restored archive, a mistyped path) is
  # therefore reported as a FREE SLOT, while the append in `launch_review` to that same path FAILS — so the
  # count is pinned at 0 FOR EVER and the loop buys one full PAID review per COOLDOWN_TRANSIENT_S at that
  # head, with no EXHAUSTED state and no diagnostic. "The path exists but is not a ledger this file can
  # read" is the SAME fact as an unreadable ledger, never the same fact as "nothing has been spent".
  # ⛔ `-e` DOES NOT SEE AN ENTRY THAT DOES NOT RESOLVE (review cycle 2, P2, measured): `test -e` FOLLOWS the
  # link, so a symlink loop and a dangling symlink whose target directory is gone both answer "absent" —
  # while the append in `launch_review` to that same path FAILS — which is the identical fail-open the
  # `-f` split above removes for a directory, in the two symlink shapes it cannot reach. `-L` is what makes
  # "a directory ENTRY is here" the question, so an entry that exists and does not resolve is classified
  # with the other uncountable ones. Deliberately fail-closed for a dangling link whose target COULD be
  # created: that path cannot be counted either, and "uncountable" is the fact this function reports.
  [ -e "$f" ] || [ -L "$f" ] || { printf '0\n'; return 0; }
  [ -f "$f" ] || {
    log_line "$f REVIEW-LEDGER-UNREADABLE: the attempt ledger path exists but is not a regular file (or is a link that does not resolve), so this head's spend cannot be counted — treating it as EXHAUSTED (fail-closed: an uncountable counter is not a free slot, and the append would fail while every pass read 0)"
    printf '%s\n' "${REVIEW_MAX_ATTEMPTS:-3}"; return 0
  }
  cut=$(( $(date +%s) - REVIEW_ATTEMPT_WINDOW_S ))
  # ⛔ AN UNREADABLE LEDGER IS NOT A FREE SLOT (review round 6, P2, measured). "No file" means nothing has
  # been spent, so 0 is right — but a file that EXISTS and cannot be read (`awk` exits 2: mode 0200, a
  # root-owned leftover after a sudo run, a corrupted path under the state dir) is the opposite fact: the
  # head may have spent its whole budget and the append still succeeds, so `>>` grows the ledger while
  # every pass reads 0 — one full PAID review per review-duration, for ever, with no EXHAUSTED state and
  # no diagnostic (the log prints the same 0). Every neighbouring counter in this file already fails
  # CLOSED on an unreadable source (`rails_for_repo` → COUNTER-FAILED, `rail_already_running` → rc 2,
  # `publish_review_state` → MARKER-UNREADABLE); this is the one that must too.
  # ⛔ THE UNPARSEABLE ARM USED TO BE UNREACHABLE (review round 8, P3, measured): the awk ended in
  # `END {printf "%d", c+0}`, which ALWAYS prints digits and ALWAYS exits 0 — so `n` was numeric by
  # construction, the `*[!0-9]*` case below could never fire, and a ledger full of garbage (`REVIEW-ATTEMPT
  # corrupt`, `not-a-number`) was reported as **0 dispatches spent**: up to REVIEW_MAX_ATTEMPTS paid
  # reviews forgiven by a corrupted counter, with no diagnostic. The scan now ALSO reports whether every
  # non-empty line parsed, which is the fact the arm was written to test.
  # ⛔ READABLE IS NOT COUNTABLE (review round 15, P2, measured): a regular file that opens for reading but
  # refuses `>>` (root-owned 0644/0444 after a sudo run, a read-only mount) passed `-e`/`-L`/`-f`, `awk`
  # succeeded, the count stayed 0 for ever, and the append failure was only LOGGED — so one paid review was
  # bought on every pass past the bound (measured: 5 dispatches at one head in 5 passes, ledger lines=0).
  # The named trigger for this doctrine is "a root-owned leftover after a sudo run"; this is that file's
  # readable sibling, and it belongs in the same fail-closed branch.
  if [ -e "$f" ] && [ ! -w "$f" ]; then
    log_line "$f REVIEW-LEDGER-UNWRITABLE: the per-head attempt ledger exists and reads, but nothing can be appended to it (a read-only file, a root-owned leftover, a read-only mount) — treating this head as EXHAUSTED (fail-closed: a counter that cannot be incremented is not a free slot, and every pass would otherwise buy another paid review)"
    printf '%s\n' "${REVIEW_MAX_ATTEMPTS:-3}"
    return 0
  fi
  if ! n=$(awk -v cut="$cut" '
      $0 ~ /^[[:space:]]*$/ { next }
      $1 !~ /^[0-9]+$/ { bad = 1; next }
      $1 > cut { c++ }
      END { printf "%d %d\n", c + 0, bad + 0 }' "$f" 2>/dev/null); then
    log_line "$f REVIEW-LEDGER-UNREADABLE: the per-head attempt ledger exists but could not be read — treating this head as EXHAUSTED (fail-closed: an unreadable counter is not a free slot, and the append would otherwise grow a ledger nothing can count)"
    # ⛔ THE VALUE RETURNED HERE IS THE CAP, NOT A COUNT — so whoever PUBLISHES it must not present it as a
    # measurement. That cannot be signalled from here: the loop calls this function in `$( … )`, which is a
    # SUBSHELL, so no variable set in this body reaches the caller (measured — a flag here left the
    # published text claiming "3 dispatch(es)" as fact, with the suite green because its arms set the flag
    # by hand). `review_ledger_unreadable` exists for the caller to ask the question DIRECTLY instead.
    printf '%s\n' "${REVIEW_MAX_ATTEMPTS:-3}"
    return 0
  fi
  # An empty file counts as 0 (nothing spent yet); a line that does not parse is the same failure as "could
  # not read", and it fails CLOSED. The count and the parse verdict arrive together, so neither can be
  # inferred from the other.
  case "${n:-}" in
    '') printf '0\n'; return 0;;
  esac
  # ⛔ ONE ARM, NOT TWO (review round 11, P3, measured): the scan above always prints "<digits> <digits>",
  # so a `*[!0-9 ]*` case could never fire — it advertised a failure mode the code cannot produce, and its
  # message named a count that never exists. The pair's second field is the whole test.
  case "${n#* }" in
    1)
      log_line "$f REVIEW-LEDGER-UNPARSEABLE (a line is not an epoch; count would be ${n%% *}): treating this head as EXHAUSTED (fail-closed — a corrupted counter must never forgive a paid dispatch)"
      printf '%s\n' "${REVIEW_MAX_ATTEMPTS:-3}"; return 0;;
  esac
  printf '%s\n' "${n%% *}"
}
# Can this ledger be READ? Asked DIRECTLY by the caller, never through `$( )` — see the note inside
# `review_attempts`: a subshell cannot hand a variable back, so a flag set there is silently inert and the
# published comment keeps asserting the CAP as a measured count. rc 0 = exists and cannot be read.
review_ledger_unreadable() {  # $1 = attempt ledger; rc 0 = exists but its content cannot be counted
  local f=$1 bad
  # ⛔ THE SAME `-e`/`-L`/`-f` SPLIT AS `review_attempts` (review cycle 2, P2): `-e` follows the link, so a
  # non-resolving entry (`-L`) is "exists but its content cannot be counted" — exactly what this contract
  # promises, and exactly what a bare `[ -e ]` said "absent, therefore readable" about. One classifier, two
  # consumers, so the two must agree on EVERY input or the CAP wording is skipped for the one record whose
  # count was never measured.
  [ -e "$f" ] || [ -L "$f" ] || return 1
  [ -f "$f" ] || return 0
  # ⛔ SAME QUESTION AS `review_attempts` (review round 8, P3): this used to test only that awk could RUN,
  # so a readable ledger of garbage answered "readable" here while the count it produces is meaningless —
  # and the CAP wording (which exists so the published comment never asserts an unmeasured count) would then
  # be skipped for exactly the record whose count was never measured. One classifier, two consumers.
  # ⛔ AND THE SAME QUESTION HERE (review round 15, P2): a readable-but-unappendable ledger cannot be
  # COUNTED, so the CAP wording must apply to it — otherwise the published comment asserts a measurement
  # taken from a counter that can never grow.
  [ -e "$f" ] && [ ! -w "$f" ] && return 0
  bad=$(awk '
      $0 ~ /^[[:space:]]*$/ { next }
      $1 !~ /^[0-9]+$/ { bad = 1 }
      END { printf "%d\n", bad + 0 }' "$f" 2>/dev/null) || return 0
  [ "${bad:-1}" = 0 ] || return 0
  return 1
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
# ⛔ IT DROPS ONE LINE — AND ONLY WHEN THAT LINE IS PROVABLY THE REFUSAL'S OWN. An earlier version
# truncated the WHOLE ledger, which forgave paid attempts too (two paid failures + one refusal reset the
# budget and bought three more paid reviews); the one-line form closed that. The caller cannot see the
# ledger's history, though — it acts on the STATE alone, and `launch_review` logs REVIEW-ATTEMPT-UNRECORDED
# when its own append fails, in which case the newest line belongs to a PAID dispatch. So the drop is
# gated on an EPOCH MATCH against the refusal's own dispatch (`$2`), not on "the last dispatch must have
# been the refusal": see the guard in the body.
# A failure here leaves the refusal counted — TIGHTER than intended, i.e. fail-closed, the right
# direction for a bound.
review_forgive_refusal() {  # $1 = attempt ledger, $2 = the refusal's own dispatch epoch; drops that entry
  local f=$1 want=${2:-} n tmp last
  [ -f "$f" ] || return 0
  # ⛔ IT MUST DROP THE REFUSAL'S LINE, NOT WHATEVER IS NEWEST (review round 6, P3, measured): the caller
  # runs this on the STATE alone, and `launch_review` logs REVIEW-ATTEMPT-UNRECORDED when its append
  # fails — in which case the newest line is a PAID dispatch and an unguarded `sed '$d'` forgives MONEY,
  # the exact defect the one-line form exists to keep closed. So the caller passes the refusal's dispatch
  # epoch (the record's `at=`, written from the same variable the ledger line uses) and the drop happens
  # only on an exact match. No match → nothing dropped → the refusal stays counted: fail-closed, which is
  # the right direction for a bound.
  [ -n "$want" ] || { log_line "$f REVIEW-FORGIVE-SKIPPED: no dispatch epoch was supplied, so the refusal stays counted (fail-closed)"; return 0; }
  last=$(tail -1 "$f" 2>/dev/null)
  [ "$last" = "$want" ] || { log_line "$f REVIEW-FORGIVE-SKIPPED: the newest ledger entry ('${last:-none}') is not this refusal's dispatch ('$want') — nothing dropped, fail-closed"; return 0; }
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
# red-with-a-stale-marker. THAT CLASS IS NOT AUTOMATICALLY LANDABLE, AND THIS ARM DOES NOT CLAIM IT IS:
# `record-review.sh --check-carry` re-measured over those 14 the same day returned `carry` for ONE (#3134,
# whose `pipeline-compliance` is green) and `fresh` for the other 13 — the reviewed DIFF moved, so a fresh
# review is genuinely owed. The rest of the fleet cannot supply one: `orch-loop.sh` merges only on `GREEN`,
# the red-fixer fires on a RAIL REFUSAL, and `pr-sickness` repairs but never merges. So the arm's claim is
# narrower and still correct: the base HANDED these candidates to the rail, no other arm supplies that, and
# dropping them was a silent removal of reachability (the one that can carry, plus the refusal signal the
# fixer loop reads). The line's own claim — "the red arm owns this PR" — named the branch it was standing in.
# ⛔ WHAT THIS ARM DELIBERATELY DOES NOT DO IS BUY A REVIEW FOR A RED HEAD. That would be the larger change
# (#3440 records the proposal that an attestation must carry its check-surface verdict, not that a red head
# is never reviewed), and it is NOT made here: the green gate is the author's deliberate choice, and
# reversing it is a reopen, not a review finding. It is stated as the residual it is on the PR.
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
    *:at-head)  printf 'rail\n';;    # a CLEAN attestation at the head that would merge: today's path
    # ⛔ A NON-CLEAN RECORD AT THE HEAD IS NOT `at-head`, AND ROUTING IT TO THE RAIL WAS AN INFINITE
    # RE-RAIL (P1, measured 2026-11-06). `record-review.sh` mints `verdict=not-clean` as a first-class
    # verdict for a review that found blocking issues (agent-infra#3400), and check (c) accepts ONLY
    # `clean|clean-micro|clean-low` — so `at-head` on a not-clean marker launched a rail against a head
    # the gate refuses for ever, re-railed every COOLDOWN_TRANSIENT_S, AND disabled the review arm (the
    # one value that does) at the same time. Live on this repo when this was written: #3333, #3308 and
    # #3231 all carry `verdict=not-clean @ <current head>`. The head HAS been reviewed; the remedy is a
    # fix, so this is a terminal state that publishes itself — never a rail, never a second review of a
    # revision whose verdict is already known.
    *:rejected) printf 'skip\n';;    # head-bound record exists, but NOT a verdict the gate can accept
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
# ⛔ IDEMPOTENCE IS BY KEY, NOT BY HOPE. The hidden tag names the state (and the head, when the caller
# supplies one), so re-running the loop in the same state adds NOTHING, while a real transition —
# in-flight → found-issues — adds exactly one new marker instead of rewriting history. The EXCEPTION is
# the corrective family below, which supersedes BY POSITION: `review-in-flight` ↔
# `review-dispatch-failed`, and `awaiting-review` when a caller passes a head (a dispatch that finished
# WITHOUT a verdict corrects the in-flight claim). For those, "is my tag already present" is the wrong
# question — the stale tag outlives its truth, so the newest of the family wins. `review-retries-exhausted`
# is NOT positional itself (nothing supersedes it, and a repeat exhaustion at one head must stay a no-op),
# but it IS compared against: it is newer truth about this head than any claim posted before it, and the
# dispatch that follows its rolled window has to be able to say so. `awaiting-review` with NO head is the
# cap-deferral publish: it says "no owner yet" about the PR rather than a revision, and it stays plain
# presence.
publish_review_state() {  # $1 repo, $2 pr, $3 state, $4 head (optional); rc 0 = present (or just posted)
  local repo=$1 pr=$2 state=$3 head=${4:-} basis=${5:-} tag seen text _ratt_basis _ratt_tail
  # ⛔ THE BASIS IS PART OF THE KEY (review round 10, P2, measured). This state is presence-keyed, and a
  # tag naming only (state, head) cannot tell the rc=7 text from the corrected not-clean-record text for
  # the SAME head — so whichever published first owned that head for ever. The ordinary flow publishes the
  # rc=7 text first (`review-pr.sh` posts its findings and exits 7; the recorder mints `verdict=not-clean`
  # afterwards), so the correction was a PERMANENT no-op and the PR went on asserting "No attestation was
  # recorded" about a head that demonstrably HAS a record — the false claim claim 3 removed, merely
  # reordered. Including the basis keeps the supersession it exists for (a real transition adds exactly
  # one comment) and makes a repeat publish of the SAME basis a no-op, which is what idempotence must mean.
  tag="<!-- auto-rail-review:${state}${head:+:$head}${basis:+:$basis} -->"
  # ⛔ WHAT MAY BE SAID ABOUT THE COUNT (review round 6, P3): when the attempt ledger could not be READ, the
  # count the loop acted on is the CAP, not a measurement — so the comment says that instead of asserting
  # "3 dispatch(es)" as a fact. The caller passes `cap` for that case (a global flag cannot work: the count
  # is fetched in `$( … )`, and a subshell cannot write back).
  # ⛔ AND THE TAIL IS PART OF THAT CLAIM, NOT BOILERPLATE (review round 7, P2, reproduced). The sentence after
  # the basis used to be shared: "… until that window rolls — which it does BY ITSELF, so an environmental
  # cause needs no action at all". That is TRUE of the counted case (the window is a clock, and a head ages out
  # of it with nobody's help) and FALSE of the CAP case, which is exactly the case this basis exists for:
  # `review_attempts` returns the cap on its unreadable path WITHOUT computing `cut` or consulting the clock,
  # so no window exists to roll — the ledger stays unreadable on every future pass and waiting changes
  # nothing. `review-retries-exhausted` is deliberately NOT in the positional family (nothing supersedes it),
  # so a "no action required" there is a PERMANENT false instruction on the operator's only visible surface.
  # Same class as the round-2 defect this file already carries: a false claim on the PR that nothing corrects.
  if [ "$basis" = cap ]; then
    _ratt_basis="its ATTEMPT LEDGER could not be read, so it is held fail-closed as if ${REVIEW_MAX_ATTEMPTS} dispatches inside ${REVIEW_ATTEMPT_WINDOW_S}s had been spent (that is the CAP, not a count)"
    _ratt_tail="That is NOT a window that rolls by itself: the ledger file is present but UNREADABLE, so every pass reads the same fail-closed value and waiting changes nothing. Repair or remove that file, or push a new head — a new head is a new review."
  else
    _ratt_basis="${REVIEW_MAX_ATTEMPTS} dispatch(es) inside ${REVIEW_ATTEMPT_WINDOW_S}s"
    _ratt_tail="That window rolls BY ITSELF, so an environmental cause (a rate-limit or auth window, a loaded box) needs no action at all. If this head genuinely cannot be reviewed, push a new head: a new head is a new review."
  fi
  case "$state" in
    awaiting-review)
      # ⛔ THE CAP-DEFERRAL PUBLISH IS HEADLESS, SO IT MAY NOT PROMISE A DISPATCH (review round 11, P2,
      # measured). It runs BEFORE the head is read, and `review_candidate_arm` maps a head whose review
      # found blocking issues to `skip` — an rc=7 review records nothing, so the body-visible `rejected`
      # guard cannot see it. The old text ("a reviewer is dispatched as soon as this repo has a free
      # slot") was therefore false for that head, and self-perpetuating: `review-found-issues:<head>` is
      # already on the PR, so nothing newer is ever posted and the promise is the newest auto-rail
      # comment until the head changes. The text now states only what was measured — no head-bound
      # attestation — and names both what happens to a reviewable head and what happens to one that was
      # already reviewed and rejected. The HEAD-KEYED call keeps the direct promise, because that publish
      # follows a proven launch.
      if [ -n "$head" ]; then
        text="🔎 **auto-rail: review needed.** This PR is a merge candidate and carries no head-bound review attestation. auto-rail owns it: a reviewer is dispatched as soon as this repo has a free slot and the environment allows it. **It is not waiting on a lane.**"
      else
        # ⛔ EVERY TERMINAL STATE, NOT JUST ONE (review round 12, P3, measured): `review_action` returns 2 —
        # TERMINAL, no dispatch, no window — for `issues` (rc=7) AND for `clean` (a record whose body marker
        # is missing, i.e. `review-record-unbound`), and 3 for a spent cap (including the fail-closed cap of
        # an unreadable ledger); none of the three shows in the PR body, and all three are reachable at this
        # publish. Naming only the rc=7 class left the other two reading "a reviewer is coming" for a head
        # the loop will never dispatch — and this marker is presence-keyed, so nothing later can supersede
        # it. The text names all of them.
        #
        # ⛔ AND EACH TERMINAL STATE NAMES ITS OWN OUTCOME, NEVER A SHARED ONE (review cycle 2, P2, measured):
        # the three classes were named together and then given ONE consequence ("no reviewer is coming: that
        # verdict is in the reviewer's own comment or in that record"), which is false for two of them. (a)
        # `review_action`'s rc 3 is EXHAUSTED WITHIN THE WINDOW — "terminal until the window rolls, NOT for
        # ever" — and this file's own `review-retries-exhausted` text says so ("That window rolls BY
        # ITSELF"), so for a spent counter a reviewer IS coming and telling the operator to push a NEW head
        # is the opposite of the sibling text. (b) A spent counter has NO verdict: the state is defined as
        # "the reviewer is not producing a verdict", so pointing at "the reviewer's own comment or that
        # record" describes a document that does not exist. (c) The fail-closed cap of an UNREADABLE ledger
        # is the one subclass that does NOT roll by itself (nothing was measured), so lumping it in behind
        # "(including when …)" hid the only remedy that applies to it. Each class now states what is true of
        # it, and the text claims nothing the code did not measure — the whole point of claim 3.
        #
        # ⛔ AND THE ENUMERATION MAY NOT BE THE READER'S ONLY READING (review round 14, P3, measured): this
        # publish runs BEFORE the `REVIEW_AVAILABLE != 1` gate further down, so on a box with no usable
        # reviewer the three enumerated reasons are all false and the first sentence was false too — and
        # while that box stays reviewerless nothing head-keyed is ever published to correct it. The
        # availability fact is named here, with the log line that reports it.
        text="🔎 **auto-rail: review needed.** This PR is a merge candidate and carries no head-bound review attestation. If its current head is reviewable, auto-rail dispatches a reviewer for it as soon as this repo has a free slot AND a usable reviewer exists on this box (a missing or unparseable reviewer is logged by this actuator, and nothing is dispatched until this actuator is RESTARTED with one in place (it checks once, at start, and never again)). It does NOT dispatch when one of these is already true — and each names a DIFFERENT fact, so read the one that applies: **(1)** the review at that head has ALREADY run and found blocking issues — the verdict is in that reviewer's own comment, and a NEW head is what gets a new review; **(2)** a review record exists that the gate cannot bind — re-running \`record-review.sh\` at the same head re-posts its marker, and no second review is bought; **(3)** this head's review attempts are spent — a reviewer that ran and left NO verdict, so there is none to read: that window rolls BY ITSELF and needs no action at all, UNLESS the attempt ledger cannot be read, in which case nothing was measured and that file needs repairing or removing. auto-rail records nothing itself. **It is not waiting on a lane.**"
      fi;;
    review-in-flight)
      text="🔎 **auto-rail: review in flight** at \`${head:0:12}\`. No head-bound attestation existed, so a fresh-context reviewer was dispatched (\`review-pr.sh\`, KIND=reviewer) at $(date -u +%FT%TZ), and its launch was VERIFIED to have started before this comment was posted. auto-rail records nothing itself — any verdict and its attestation come from that reviewer. **It is not waiting on a lane.**";;
    review-found-issues)
      # ⛔ TWO DIFFERENT FACTS, TWO DIFFERENT TEXTS (review round 8, P3): this state is published for rc=7
      # (the reviewer found issues and wrote no record) AND for a head that HAS a record whose verdict the
      # gate will not accept (not-clean). Saying "no attestation was recorded" on the second one contradicts
      # the log line written for the same transition in the same pass, and hides the record the operator
      # needs to read. The caller passes `record` for that case.
      if [ "$basis" = record ]; then
        text="⛔ **auto-rail: the review found blocking issues** at \`${head:0:12}\`. A head-bound review RECORD EXISTS and its verdict is not one the merge gate accepts (\`not-clean\`), so auto-rail will NOT re-review this head and the rail cannot land it — the findings are in the reviewer's own comment and in that record. This head needs a fix; a new head gets a new review."
      else
        text="⛔ **auto-rail: the review found blocking issues** at \`${head:0:12}\`. No attestation was recorded, and auto-rail will NOT re-review this head — the findings are in the reviewer's own comment. This head needs a fix; a new head gets a new review."
      fi;;
    review-retries-exhausted)
      text="⛔ **auto-rail: the reviewer is not producing a verdict** at \`${head:0:12}\` — ${_ratt_basis}. No attestation exists, and auto-rail is not dispatching another review at this revision. ${_ratt_tail}";;
    review-record-unbound)
      text="⚠️ **auto-rail: a review record exists at \`${head:0:12}\` but the PR body carries no marker this loop can bind.** Re-running \`record-review.sh\` for this PR re-posts the signed marker at the same head (that write is idempotent). auto-rail never writes records, so it cannot do this itself — and it is deliberately NOT buying a second review, which would not help. **It is not waiting on a lane.**";;
    review-dispatch-failed)
      text="⚠️ **auto-rail: the reviewer was announced but never started** at \`${head:0:12}\` — the dispatch was rolled back (nothing ran, and no attempt was spent), so no \`review in flight\` marker was posted for it: this state is published only for a launch that failed to start, and in-flight only for one that did. The head is retried on a later pass; if this state persists, the actuator's reviewer path is broken and the log has the \`REVIEW-LAUNCH-FAILED\` line for it. **Nothing is reviewing this PR right now.**";;
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
  # ⛔ IDEMPOTENCE IN THE RIGHT DIRECTION: A STATE POSTS UNLESS IT IS ALREADY THE NEWEST TRUTH.
  # `review-in-flight` and `review-dispatch-failed` each CORRECT the other — in-flight after a failure
  # notice (so the PR stops saying "nothing is reviewing this" while something is), and dispatch-failed
  # when the review that WAS announced has since been retried and the retry's launch never started (so it
  # stops saying a review is running when nothing is; that is the sequence in-flight → failure → in-flight
  # → failure, which positional repair would otherwise suppress with its own older tag). For those two,
  # "does my tag already exist" is the WRONG question: the stale tag outlives its truth, so the correction
  # is suppressed for ever. Measured all three ways (review rounds 4 and 5): presence-only let a failure
  # notice outlive its retry; one-way positional let a retry that ALSO rolled back leave the re-posted
  # in-flight claim as the permanent last word; and both-positional WITH the in-flight publish before the
  # launch alternated two comments per pass on a broken path. The loop now publishes in-flight only for a
  # launch it PROVED started, so exactly one of the pair is published per real transition and positional
  # converges: each transition adds one comment, a repeated no-op adds none. (The family has THREE
  # members once `awaiting-review` carries a head — see below — so "newer than its partner" is computed
  # against the newest of all of them, never against one.) Every other state keeps plain
  # presence — nothing corrects it, so one marker IS the truth.
  # ⛔ AND `awaiting-review` JOINS THAT FAMILY WHEN IT CARRIES A HEAD (review round 6, P2, measured): a
  # dispatch that finished WITHOUT a verdict corrects an in-flight marker by publishing it, and
  # presence-keyed it could only ever do that ONCE — a later `review-in-flight:H` (posted when the record
  # was still `pending` at the verify window, then rc=75 a second later) stayed the newest comment for
  # ever, because `refused` retries on time alone and never posts another state. Position is the only
  # rule that both corrects and converges. The headless call (cap deferral) stays plain presence: it
  # says "no owner yet" about the PR, not about a revision.
  local _pos=0 _o _on _mine_last _other_last
  case "$state" in
    review-in-flight|review-dispatch-failed) _pos=1 ;;
    awaiting-review) [ -n "$head" ] && _pos=1 ;;
  esac
  if [ "$_pos" = 1 ]; then
    # ⛔ THE FAMILY HAS THREE MEMBERS, SO "newer than the ONE other state" IS WRONG (review round 7, P2,
    # measured). `awaiting-review:<head>` joined at the top of this function, and comparing each state
    # against a single partner let a NEWER awaiting-review suppress both halves of the pair for ever: with
    # `refused` fast-finish posting awaiting-review and the record removed on the next rolled-back launch,
    # the state returns to `none` and every later pass publishes `review-dispatch-failed` — which was
    # compared only against in-flight, found newer awaiting-review irrelevant, and posted. Measured
    # sequence (in-flight, awaiting-review:H, in-flight) left ONE in-flight marker where two transitions
    # happened, and (dispatch-failed, awaiting-review:H, dispatch-failed) left ONE dispatch-failed notice
    # while the reviewer path stayed broken — the false claim standing indefinitely, which is the exact
    # reason this family exists. Compare against the NEWEST of the other members instead.
    _other_last=0
    # ⛔ THE SCAN MATCHES THE TAG'S PREFIX, NOT ITS WHOLE FORM (review round 16, P2, measured): a dispatch
    # claim is keyed by the DISPATCH (`_d<epoch>` basis, see the call sites), so an exact-form match would
    # stop counting every such marker the moment one carried a basis — the pair would then never correct
    # each other. The head is a 40-char sha, so a `:$_o:$head` prefix cannot collide with another revision.
    # ⛔ AND `review-retries-exhausted` IS PART OF WHAT A DISPATCH CLAIM MUST BE ABLE TO CORRECT (review round
    # 18, P2, measured). It is deliberately NOT positional itself — nothing supersedes it, and a repeat
    # exhaustion at one head must stay a no-op — but it IS newer truth about this head than a claim posted
    # before it: after its window rolls BY ITSELF the loop dispatches again at the SAME head, and the claim
    # that follows ("review in flight", or "awaiting review" for a dispatch that was refused) has to speak
    # over it. Left out of this comparison, that claim was suppressed by its own pre-exhaustion tag and the
    # PR kept "not dispatching another review at this revision" as its newest comment while the loop bought
    # up to REVIEW_MAX_ATTEMPTS more reviews. Measured on the shipped function: awaiting-review → exhausted →
    # awaiting-review left ONE marker, newest = the exhausted text.
    for _o in review-in-flight review-dispatch-failed awaiting-review review-retries-exhausted; do
      [ "$_o" = "$state" ] && continue
      _on=$(printf '%s\n' "$seen" | awk -v t="<!-- auto-rail-review:$_o:$head" 'index($0,t){n=NR} END{print n+0}')
      [ "${_on:-0}" -gt "$_other_last" ] && _other_last=$_on
    done
    _mine_last=$(printf '%s\n' "$seen" | awk -v t="$tag" 'index($0,t){n=NR} END{print n+0}')
    # ⛔ A CLAIM KEYED TO A DISPATCH THAT HAS NO MARKER YET IS NEW TRUTH AND MUST POST (review round 16, P2,
    # measured): `review-retries-exhausted:<head>` is deliberately NOT in this family, and its own text says
    # the window rolls BY ITSELF — so after it, the loop dispatches again at the SAME head. With the state
    # keyed only by (state, head), that dispatch's claim reused a tag posted BEFORE the exhaustion and was
    # suppressed by the positional rule, leaving "not dispatching another review at this revision" as the
    # newest comment while the loop bought up to REVIEW_MAX_ATTEMPTS more reviews at that revision — and
    # nothing ever corrected it. `_mine_last = 0` means "no marker for THIS dispatch", which is exactly the
    # case that must post.
    [ "${_mine_last:-0}" -gt 0 ] && [ "${_mine_last:-0}" -ge "${_other_last:-0}" ] && return 0
  else
    case "$seen" in *"$tag"*) return 0;; esac
  fi
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
  # ⛔ `< /dev/null` IS LOAD-BEARING: the loop's stdin is the CANDIDATE FILE (`done < "$_cand"`), and
  # `pi` DRAINS PIPED STDIN into the first prompt. A child that inherits fd 0 therefore eats the rest of
  # this repo's candidate list — measured with the shipped loop shape and a stdin-reading child: of four
  # candidates, one was processed and the other three were consumed by the reviewer and prepended to its
  # prompt. The pass line had already reported `candidates=4`, so the loss is silent.
  bash "$1" "$2" --repo "$3" >> "$4" 2>&1 < /dev/null
  # ⛔ THE EXIT LINE MUST START ITS OWN LINE (P2, measured). Appended bare, it GLUES onto a child whose
  # last output has no trailing newline — reachable with the shipped reviewer, which prints `tail -80`
  # of a transcript on the no-parsed-findings path, and `tail` adds none. `review_state` parses the line
  # `^REVIEW-EXIT rc=`-anchored, so a glued line matched NOTHING: a rejected head read `pending`, was
  # re-dispatched as a fresh PAID review after the cooldown, and never published `review-found-issues`.
  printf '\nREVIEW-EXIT rc=%s\n' "$?" >> "$4"
}
export -f run_review
# ── THE DISPATCH, VERIFIED THE SAME WAY `launch_rail` IS ────────────────────────────────────────────
# `( … ) &` returns 0 whether or not anything ran (measured cycle 4 on this very file for the rail), and
# a dispatch that never started must be RETRIED next pass, not remembered as in flight for
# REVIEW_COOLDOWN_S. So the record is removed on proof that nothing started.
launch_review() {  # $1 = repo, $2 = PR, $3 = head, $4 = state file, $5 = attempt ledger; rc 0 = started
  local repo=$1 pr=$2 head=$3 out=$4 led=${5:-} pid
  # ⛔ THE FAILED WRITE MUST ALSO REMOVE THE FILE IT MAY HAVE TRUNCATED (P2, measured). `>` truncates the
  # redirect target BEFORE the write runs, so a write that fails (ENOSPC/EDQUOT on a nearly-full volume —
  # this repo ships `disk-floor.sh` for exactly that) leaves a ZERO-BYTE record and destroys the previous
  # dispatch's state. An empty record has no exit line (-> `pending`) and no dispatch epoch (-> `_rage=0`,
  # the value a real fresh dispatch carries), so `review_action pending 0 …` answers WAIT on every pass
  # for ever: no dispatch, no publication, no exhaustion, and a log line that says a review is running.
  # `rm -f` here is the same rollback the verify-failure path below already performs.
  # ⛔ ONE EPOCH FOR BOTH RECORDS (review round 6, P3): the record's `at=` and the ledger line are the
  # same dispatch, and the forgiver now MATCHES them — two separate `date +%s` calls can straddle a
  # second boundary, so a mismatch would silently disable forgiveness (or, worse, match a previous paid
  # line). Captured once, used twice.
  local _ep; _ep=$(date +%s)
  printf 'REVIEW-DISPATCHED at=%s head=%s repo=%s pr=%s\n' "$_ep" "$head" "$repo" "$pr" > "$out" \
    || { rm -f "$out" 2>/dev/null; log_line "$repo #$pr REVIEW-LAUNCH-FAILED: cannot write the review record at $out — nothing was dispatched, no cooldown was consumed, and the truncated record was removed (a zero-byte record reads as a review in flight for ever)"; return 1; }
  nohup bash -c 'run_review "$@"' _ "$REVIEW_SCRIPT" "$pr" "$repo" "$out" >> "$LOG" 2>&1 < /dev/null &
  pid=$!
  log_line "$repo #$pr no attestation at head $head -> dispatching reviewer (KIND=reviewer, $REVIEW_SCRIPT)"
  sleep "$LAUNCH_VERIFY_S"
  if kill -0 "$pid" 2>/dev/null || [ "$(wc -l < "$out")" -gt 1 ]; then
    # ⛔ THE ATTEMPT IS COUNTED **HERE**, NOT AT THE RECORD WRITE (review, P1). A dispatch that never
    # started is rolled back two lines below and must consume NOTHING — otherwise three transient
    # `nohup` failures would read as three paid reviews and mark the head EXHAUSTED without one ever
    # having run. Only verified dispatches are money, so only verified dispatches are counted.
    if [ -n "$led" ]; then
      printf '%s\n' "$_ep" >> "$led" 2>/dev/null \
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
# ⛔ TWO PATTERNS, BECAUSE THE TWO VERDICT FAMILIES HAVE DIFFERENT TAIL GUARANTEES (review round 5, P2).
# The `$` anchor only means something if the text before it is bounded. For the CLEAN family it is: the gate's
# own shape is exact, so a line that starts with a clean marker and then carries prose (or a trailing space)
# is a QUOTATION, and the strict form below rejects it — that is the guarantee that stops a quotation from
# disabling the review arm for ever.
# ⛔ A NOT-CLEAN MARKER CANNOT HAVE THAT GUARANTEE. Its recorded tail is ` findings=<n>[ note=<free text>]`,
# and `note=` is documented FREE-FORM, single-line plain text — `note=1 open P2` is record-review.sh's OWN
# example (it rejects only quotes/backslashes/control chars, not spaces), and a live body carries
# `findings=9 note=3 open P1 (…)+ 6 P2 sig=…` on agent-infra#3201. There is no delimiter between that text
# and anything appended after it, so no pattern can accept the note and reject prose — a `\S+` rejects BOTH,
# and rejecting the real shape is the worse error: it reads a recorded review as `absent`, which on a green
# head buys a PAID review of a head that already carries a record (`review-pr.sh`'s E_ALREADY short-circuit
# only matches `verdict=clean`, so it does pay). The permissive tail is therefore DELIBERATE and bounded to
# `not-clean`, which check (c) refuses on ANY shape (`clean|clean-micro|clean-low` only) — so nothing about
# whether this PR can LAND turns on it; it only keeps the loop's verdict-blind policy (any record at this
# head is at-head) working for the one family whose tail cannot be anchored.
# Verified against every open PR body on both driven repos: the at-head/stale/absent split is identical to
# the pre-anchoring parse, and the #3201 note form classifies.
# The repo is CAPTURED and compared exactly, not tested as a substring of the line: the gate binds it, and
# `(<owner/repo>)` appearing anywhere on a marker line is not the same claim as the marker naming that repo.
_HEAD_RE = r'^review recorded: reviews/(\d+)\.json verdict=%s @ ([0-9a-f]{40})(?: diff=[0-9a-f]{64})? \(([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)\)'
# The gate's exact clean shape: optional `diff=`, optional `sig=`, NOTHING else before end of line.
CLEAN_MARKER_RE = re.compile(_HEAD_RE % r'(clean|clean-micro|clean-low)' + r'(?: sig=[0-9a-f]{64})?$')
# The not-clean shape: its recorded tail, including the free-form note (see above).
NOTCLEAN_MARKER_RE = re.compile(_HEAD_RE % r'(not-clean)' + r'(?: findings=[0-9]+)?(?: note=.*)?(?: sig=[0-9a-f]{64})?$')

def attestation(body, head, pr, repo):
    "at-head | rejected | stale | absent | nohead — never an inference from a partial match."
    if not head:
        return "nohead"          # no head means nothing can be at it; the reviewer re-reads the head
    seen = []
    clean = []
    # ⛔ `split("\n")`, NEVER `splitlines()` — THE PARSER MUST BE NO MORE PERMISSIVE THAN THE GATE (P1,
    # review round 6, measured). `splitlines()` also breaks on `\r`, `\v`, `\f`, `\x1c`-`\x1e`, `\x85`
    # and `\u2028/\u2029`, so it SPLITS A LINE THE GATE READS WHOLE, and strips the `\r` that makes the
    # gate's `$` fail. Measured by driving both readers on one body: a CRLF-terminated marker line — the
    # shape `gh pr create --body-file` produces from a CRLF file, or any body round-tripped through a CRLF
    # tool — read `at-head` here while check (c)'s `while IFS= read -r line` (which splits on `\n` alone,
    # leaving the `\r` inside `$line`) refused it. `at-head` is the ONE value that disables the review arm,
    # so the only producer of attestations would be switched off for that PR for ever while every
    # COOLDOWN_TRANSIENT_S pass burned a MAX slot railing a head the gate refuses. The gate's own reader is
    # the specification; this reproduces it exactly, including the failure.
    for line in (body or "").split("\n"):
        # `match` + the patterns' own `^`/`$`: the RECORD shape exactly, not a line that starts with one.
        # ⛔ WHICH PATTERN MATCHED IS THE VERDICT — there is no second list of "verdicts that may land" to
        # drift from `CLEAN_MARKER_RE`, and `(clean|clean-micro|clean-low)` is check (c)'s own set. A line
        # matching only `NOTCLEAN_MARKER_RE` is a review that HAPPENED at this head and did NOT pass.
        mc = CLEAN_MARKER_RE.match(line)
        m = mc or NOTCLEAN_MARKER_RE.match(line)
        if not m:
            continue                 # not a record line: indented, prefixed, or carrying prose after it
        if m.group(1) != str(pr):
            continue                 # a record for a DIFFERENT PR is not this PR's attestation
        if m.group(4).lower() != repo.lower():
            continue                 # the gate binds the repo; a marker naming another repo is not ours
        # ⛔ `seen`/`clean` HOLD HEADS — a SHA is what `head in …` is asked about — and the VERDICT only
        # decides which head lands in `clean`.
        h = m.group(3).lower()
        seen.append(h)
        if mc:
            clean.append(h)
    if head in clean:
        return "at-head"
    if head in seen:
        return "rejected"         # reviewed AT this head, and the verdict is not one the gate can land
    return "stale" if seen else "absent"

for p in prs:
    # A DRAFT CAN NEVER MERGE: the rail refuses it in one line ("PR is a DRAFT").
    if p.get("isDraft"):
        continue
    # ⛔ A HEAD THAT CANNOT LAND MUST NOT BUY A REVIEW (review round 5, P2, measured): `mergeable` was
    # fetched here and never read, so a green-but-CONFLICTING head — checks pass, then `main` moves under
    # the PR and the rollup stays green — was dispatched a PAID review whose verdict nothing can use (the
    # rail refuses a conflicted head), and the rebase that fixes it is a NEW head, which buys a second one.
    # Only a DEFINITE `CONFLICTING` is skipped: GitHub computes `mergeable` lazily and reports `UNKNOWN` on
    # a fresh head, and skipping that would stall exactly the heads this loop exists to review.
    if str(p.get("mergeable") or "").upper() == "CONFLICTING":
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
        # ⛔ AND THE PUBLISHED TEXT NO LONGER PROMISES A DISPATCH (review round 11, P2): the headless
        # `awaiting-review` runs before the head is read, and an rc=7 review records nothing — so a head
        # whose review found blocking issues is skipped by `review_candidate_arm` while the body-visible
        # `rejected` guard stays blind to it. The `!= rejected` exclusion below still removes the one class
        # it CAN see; the text carries the rest by stating only what was measured. See the message split in
        # `publish_review_state`.
        # ⛔ AND A `rejected` HEAD IS EXCLUDED, BECAUSE THE CLAIM WOULD BE FALSE (P2, review round 7): the
        # text below promises "a reviewer is dispatched as soon as this repo has a free slot", but
        # `review_candidate_arm` maps `*:rejected` to `skip` \u2014 a head whose record says `not-clean` is
        # TERMINAL and no reviewer ever comes. Publishing it left the PR's newest state claiming a review
        # that would never arrive, on the exact population the previous commit set out to make readable
        # (#3333/#3308/#3231), and under sustained cap saturation \u2014 the NORMAL state, and the only state
        # in which this line runs \u2014 the pass never advances far enough to publish `review-found-issues`, so
        # the false claim could stand indefinitely. That is #3489's invisibility, inverted.
        # ⛔ A REWORDED TEXT NEEDS A NEW KEY EVERY TIME (rounds 15 and 17, both measured): a headless tag is
        # presence-keyed, so re-wording under an EXISTING key is a permanent no-op on every PR that carries
        # the old sentence. `notice-restart`, over `notice`, is per-CORRECTION.
        [ "$_kind" = green ] && [ "$_att" != at-head ] && [ "$_att" != rejected ] && publish_review_state "$repo" "$pr" awaiting-review "" notice-restart
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
          # ⛔ A NON-CLEAN RECORD AT THIS HEAD IS ITS OWN STATE, NOT "THE RED ARM OWNS IT" (P1): the head
          # was reviewed and the review found blocking issues, so nothing in the fleet may re-buy that
          # verdict and the rail can never land it (check (c) accepts clean only). Publishing it is what
          # makes a PR that is blocked ON ITS OWN REVIEW readable instead of looking like a PR nobody has
          # looked at — and it is idempotent by (state, head, basis), so it costs one comment per head.
          if [ "$_att" = rejected ]; then
            publish_review_state "$repo" "$pr" review-found-issues "$head" record
            log_line "$repo #$pr REVIEW-REJECTED at $head — a head-bound record EXISTS and its verdict is not one the gate accepts (not-clean), so the rail cannot land this revision and no second review is bought; the fix is a NEW head, which is a new key"
            continue
          fi
          log_line "$repo #$pr AWAITING-REVIEW ($_att) and its checks are RED — no marker at ANY head to carry and no review is bought for a red head (a red head must not be attested clean, #3440); the red arm owns this PR"
          continue
        fi
        if [ "$_rarm" = rail ]; then
          # ⛔ RED, BUT IT CARRIES A MARKER AT AN OLDER HEAD — SO THE RAIL IS STILL THE RIGHT ARM, AND
          # DROPPING IT HERE WAS THE P1 REVIEW FINDING. There is a carry (`diff=` unchanged) and an
          # exemption engine that can land this revision; nothing else in the fleet can. The line is
          # logged so the pass says which arm took it instead of implying a lane is working on the PR.
          log_line "$repo #$pr RED with a marker at an OLDER head ($_att) — NOT reviewed; handed to the RAIL, where check (c)'s carry (only when the reviewed DIFF is unchanged) and the exemption engine are what can land a red head. When the diff moved this head still needs the fresh review the green gate withholds (#3440), so it is railed, not fixed — said plainly rather than reported as progress"
        fi
      fi
      if [ "$_att" != at-head ] && [ "$_rarm" = review ]; then
        if [ "$REVIEW_AVAILABLE" != 1 ]; then
          # ⛔ THIS EXIT IS THE ONE STATE THAT PUBLISHED NOTHING (review round 16, P2, measured): on a box with
          # no usable reviewer and free capacity, neither deferral path runs (nothing is ever dispatched, so
          # the burst counter never moves), so a mergeable green unattested PR got NO auto-rail comment at
          # all — indistinguishable from "a lane is working on it", the #3489 invisibility. The notice text
          # for exactly this population already exists; it is published here.
          publish_review_state "$repo" "$pr" awaiting-review "" notice-restart
          log_line "$repo #$pr AWAITING-REVIEW ($_att) and this box has no reviewer at $REVIEW_SCRIPT — the PR stays unattested until this actuator is RESTARTED with a usable reviewer in place — the check is taken ONCE, before the loop, and never again (said once at start, named here per candidate)"
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
        # ⛔ ONE CALL, NOTHING BETWEEN IT AND ITS CONSUMER (review round 8, P3): the age and its basis come
        # out of `review_dispatch_age` together, so no line inserted after a pinned call can discard the
        # mtime fallback and silently restore the permanent-WAIT defect. `_rage_rc` is the basis (0 epoch,
        # 1 mtime, 2 unmeasurable) and only chooses wording; the number itself is already seconds.
        _rage=$(review_dispatch_age "$_rout"); _rage_rc=$?
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
          # ⛔ STATE THE BASIS OF THE AGE (review round 7, P3): "dispatched 0m ago" was printed for a record
          # with NO epoch, so the operator's primary instrument asserted a measurement that did not exist.
          case "$_rage_rc" in
            0) _rage_txt="dispatched $(( _rage / 60 ))m ago";;
            1) _rage_txt="the record carries NO dispatch epoch, so the age is ${_rage}s measured from the record file's own mtime";;
            *) _rage_txt="the record carries NO dispatch epoch and its mtime could not be read, so the age is UNKNOWN";;
          esac
          log_line "$repo #$pr review $_rstate at $head — ${_rage_txt}, within its ${_rwin}s window for this state; waiting, not re-dispatching (a slow review is not a stuck one)"
          continue
        fi
        if [ "$_ract" -eq 3 ]; then
          # ⛔ EXHAUSTED IS NOT A WAIT AND NOT A RETRY: this head has spent its paid attempts and still
          # has no verdict, so dispatching again buys the same failure at review prices. Publishing it
          # is what keeps the PR from reading as "a lane is working on it" — the rest of this step only
          # exists to keep that from happening.
          # ⛔ THE COUNT AND THE COMMENT MUST AGREE, AND NEITHER MAY OVERSTATE WHAT WAS MEASURED: when the
          # ledger cannot be read, `_rattn` is the CAP, so the published comment AND the log say that.
          if review_ledger_unreadable "$_ratt"; then _rbasis=cap; else _rbasis=; fi
          publish_review_state "$repo" "$pr" review-retries-exhausted "$head" "$_rbasis"
          if [ "$_rbasis" = cap ]; then
            log_line "$repo #$pr REVIEW-RETRIES-EXHAUSTED at $head — the attempt ledger could not be read, so this head is held fail-closed as if $REVIEW_MAX_ATTEMPTS dispatches inside ${REVIEW_ATTEMPT_WINDOW_S}s had been spent (that is the CAP, not a count; last state $_rstate, record $_rout, ledger $_ratt); that window will NOT roll by itself — an unreadable ledger reads the same value on every pass, so repair or remove that file. A new head is a new key and gets a review immediately"
          else
            log_line "$repo #$pr REVIEW-RETRIES-EXHAUSTED at $head — $_rattn dispatch(es) inside ${REVIEW_ATTEMPT_WINDOW_S}s (cap $REVIEW_MAX_ATTEMPTS, last state $_rstate, record $_rout, ledger $_ratt); not dispatching again until the window rolls. A new head is a new key and gets a review immediately"
          fi
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
          publish_review_state "$repo" "$pr" awaiting-review "" notice-restart
          log_line "$repo #$pr AWAITING-REVIEW ($_att at $head) — $_rdispatched review(s) already dispatched for this repo this pass (cap $REVIEW_PER_PASS); this head is next in the queue"
          continue
        fi
        # ⛔ A REFUSAL SPENT NOTHING, SO ITS OWN LEDGER LINE COMES STRAIGHT BACK (review rounds 2 and 3):
        # the window bounds how long damage lasts but would still let three load refusals exhaust the
        # FIRST real review's retries. `review_forgive_refusal` drops exactly that one line, and only when
        # the last dispatch is the refusal — never a paid entry.
        [ "$_rstate" = refused ] && review_forgive_refusal "$_ratt" "$(review_dispatched_at "$_rout")"
        # ⛔ THE IN-FLIGHT MARKER IS PUBLISHED ONLY ONCE THE LAUNCH IS PROVEN TO HAVE STARTED (review
        # round 5, measured on the real functions). Both orderings were tried and both lie or thrash:
        #  - BEFORE the launch: a rolled-back dispatch has already told the PR "a reviewer was
        #    dispatched", so every later pass must either re-post in-flight (the failure notice outlives
        #    its retry) or re-post the failure (the in-flight claim outlives ITS truth) — and with both
        #    corrected positionally a permanently broken reviewer path posts TWO comments PER PASS, for
        #    ever, which is the duplicate-marker thrash these arms exist to forbid.
        #  - AFTER it: a dispatch that never started says nothing at all, the failure notice is the
        #    last word AND the truth, a successful retry re-posts in-flight exactly once (it is newer than
        #    the failure), and a quiet repeat adds nothing. No alternation, no thrash.
        # The few seconds between launch and this line do not hide a running review: the record that
        # `launch_review` wrote already says DISPATCHED, and the state machine reads the record.
        launch_review "$repo" "$pr" "$head" "$_rout" "$_ratt" \
          || { publish_review_state "$repo" "$pr" review-dispatch-failed "$head"; continue; }
        # ⛔ A SUCCESS MEANS THE LAUNCH STARTED — NOT THAT A REVIEW IS STILL RUNNING (review round 5, P2,
        # measured). `launch_review` also accepts a child that started AND FINISHED inside LAUNCH_VERIFY_S,
        # and `review-pr.sh` exits 4/9/75 in about a second on a loaded box or a missing `pi` — so this
        # point is reached with the record already carrying an outcome. Publishing "review in flight" then
        # is a false claim on the PR that NOTHING ever corrects: the outcome state is `refused`/`retry`, and
        # `refused` retries on time alone and publishes nothing, so the marker would outlive the review for
        # ever. Say what the record says. A verdict (clean/issues) is published by its own path on the next
        # pass, so nothing is published for it here.
        # position, not presence — see `publish_review_state`: a success after a rolled-back dispatch must be
        # able to correct that notice.
        # ⛔ KEYED BY WHAT THE COMMENT ACTUALLY CLAIMS — THE TWO ARMS ARE NOT THE SAME FACT (review round 18,
        # P2, measured), SO THEY DO NOT CARRY THE SAME KEY.
        #  - `review-in-flight` IS a per-dispatch claim: its text carries the dispatch's OWN timestamp
        #    ("dispatched … at $(date -u …)"), so a second dispatch is new truth and must be able to say so.
        #    The exhausted state is not positional and its window rolls BY ITSELF, so without a per-dispatch
        #    key the claim following a rolled window reuses a tag posted BEFORE the exhaustion and is
        #    suppressed for ever (round 16). The epoch of THIS dispatch is that key.
        #  - `awaiting-review` is NOT: its text is byte-identical on every refusal, because nothing in it is
        #    per-event. Keyed by the epoch, EVERY retry cycle posted a new identical "review needed" comment,
        #    and `refused` retries on TIME ALONE and spends nothing — so that is unbounded: measured, one
        #    comment per COOLDOWN_TRANSIENT_S per PR (≈4/hour) for a state that told the operator nothing new,
        #    and `publish_review_state` re-reads the comment list with `--paginate` on every call, so each one
        #    inflated every later marker read on the shared budget this actuator exists to protect. It is keyed
        #    by (state, head) again — and the round-16 outcome is PRESERVED, not traded away: the positional
        #    rule now compares against `review-retries-exhausted` too, so the claim that follows a rolled
        #    exhaustion window is newer truth and posts, while a repeat refusal at the same head is a no-op.
        # Computed BEFORE the case, because a case body cannot hold statements.
        _rdisp="d$(review_dispatched_at "$_rout")"
        case "$_rdisp" in d) _rdisp=;; esac
        case "$(review_state "$_rout")" in
          pending) publish_review_state "$repo" "$pr" review-in-flight "$head" "$_rdisp" ;;
          refused|retry) publish_review_state "$repo" "$pr" awaiting-review "$head" ;;
        esac
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
