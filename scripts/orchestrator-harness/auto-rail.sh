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
COOLDOWN_TRANSIENT_S=${COOLDOWN_TRANSIENT_S:-900}
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
  mtime=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null)
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
log_line "auto-rail started max=$MAX max_total=$MAX_TOTAL interval=${INTERVAL}s red_cap=$RED_CAP rail=$RAIL_SCRIPT"

while :; do
  for repo in $REPOS; do
    _cand=/tmp/auto-rail-cand.$$
    python3 - "$repo" "$RED_CAP" <<'PY' 2>> "$LOG" > "$_cand"
import json,subprocess,sys
repo=sys.argv[1]
try:
    r=subprocess.run(["gh","pr","list","--repo",repo,"--state","open","--limit","100",
        "--json","number,mergeable,isDraft,statusCheckRollup,body"],capture_output=True,text=True)
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
for p in prs:
    # ⛔ A PR WITHOUT A REVIEW RECORD CANNOT MERGE, so railing it is noise that occupies a MAX slot.
    # Measured 2026-10-24: three PRs sat at reds=0 with a record and NOBODY railed them (that is what
    # this script exists for) while many more were red only on `pipeline-compliance (c)` -- no head-bound
    # record -- and a rail on those refuses in seconds. Requiring the marker makes the candidate set
    # equal the set of PRs that can actually land, which is the whole point of an actuator.
    if "review recorded:" not in (p.get("body") or ""):
        continue
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
    (green if redn==0 else red).append((redn, p["number"]))
for _r,n in sorted(green): print(n)
for _r,n in sorted(red)[:int(sys.argv[2])]: print(n)
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
    while read -r pr; do
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
        log_line "$repo #$pr deferred ($_own rails on this repo + $_unk unattributed, $_total live in total, max=$MAX max_total=$MAX_TOTAL)"; continue
      fi
      # ⛔ A FAILED HEAD READ IS NOT AN EMPTY HEAD. `gh` failing here used to write the cooldown key
      # with an EMPTY head, which no later pass's real head can ever match — so the same PR was railed
      # again every interval, each launch taking a MAX slot from the candidates this actuator exists to
      # serve. Skip the candidate instead, and say so.
      head=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null) \
        || { log_line "$repo #$pr HEAD-READ-FAILED: gh rc=$? — skipping this candidate (a cooldown keyed to an empty head would re-rail it every pass)"; continue; }
      [ -n "$head" ] || { log_line "$repo #$pr HEAD-READ-FAILED: gh returned an empty head — skipping this candidate"; continue; }
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
