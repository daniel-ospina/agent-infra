#!/bin/bash
# orch-loop.sh — self-sustaining orchestrator loop (bash 3.2).
# Fast, non-blocking cycle: heartbeat -> merge sweep -> capacity-gated dispatch -> background refresh.
set -u
# ⛔ OR IS DERIVED FROM THE CHECKOUT BELOW, NEVER FROM A LITERAL (see "the ONE repo" block).
# ⛔ REPO HAS NO DEFAULT, AND THAT IS THE FIX. It used to default to ONE DEVELOPER'S HOME
# (`/Users/<user>/Documents/GitHub/tortoise`), so on any other machine it resolved to a path with
# nothing behind it: the guard just below killed the controller at startup, and under KeepAlive that
# is a crash loop whose only trace is launchd.err — it reads exactly like a box with nothing to do.
# (The other shape, "the controller keeps beating while the refresh aborts every cycle", is a REPO
# that EXISTS but is the wrong repo — refresh-candidates.sh still carries its own default of that
# kind, #1935/#1977.) A path is not a thing this repo can guess — the daemon gets it from install.sh
# (`__REPO__` in the plist), a cell from its keys.env/supervisor, and an operator from §4 step 2.
# Unset is a CONFIGURATION ERROR and it is refused HERE, before any command can run against it.
REPO="${REPO:-}"
if [ -z "$REPO" ]; then echo "orch-loop: FATAL REPO is not set — export REPO=<the target repo's checkout> (see README §4 step 2)" >&2; exit 78; fi
if [ ! -d "$REPO" ]; then echo "orch-loop: FATAL REPO=$REPO does not exist" >&2; exit 78; fi
# ── the ONE repo: $OR is the dispatched checkout's origin, never an independent literal ──────────
# ⛔ THE GUARD WAS COUNTING A SURFACE IT HAD NO REASON TO BELIEVE IN. $OR defaulted to a HARDCODED
# `daniel-ospina/tortoise`, while the backlog is read from $REPO and the lanes work on $REPO. A cell
# whose $REPO is a DIFFERENT checkout therefore graded its merge backlog — and the whole merge
# sweep — against another repo's open PRs. Measured 2026-10-18: three cells logged
# `merge-priority (52 unowned of 54 open PRs — draining before opening more)` while the repo they
# were actually dispatching from had ~10 open PRs and agent-infra had ~55: the count came from the
# WRONG SURFACE, and nothing in the line said which repo it had counted, so the number looked real
# for hours. Deriving $OR from $REPO's origin makes the wrong-repo read impossible by construction;
# an explicit `OR=` still wins (a cell that must grade another repo's queue says so out loud), and
# an origin that cannot be parsed falls back to the old literal LOUDLY rather than silently.
# ⛔ THE PARSE LIVES IN repo-slug.sh, SHARED WITH refresh-candidates.sh. That script reads the
# candidate POOL from $OR, so two independent derivations could grade one repo while queueing
# another's issues — a worse defect than the one being fixed. One function, one answer.
# ⛔ O IS DEFAULTED BEFORE ITS FIRST USE. It used to be assigned ~30 lines below this block, so a
# manual/tmux invocation without an exported O never preferred `$O/repo-slug.sh` and — worse — the
# wrong-repo WARN went to stderr only, because the guard below saw an EMPTY `$O` and skipped the log
# append. stderr on a launchd box is launchd.err: that is the invisible failure the append exists to
# prevent (review round 3).
O="${O:-$HOME/orchestrator}"
_HERE_RS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "${O:-}" ] && [ -f "$O/repo-slug.sh" ]; then . "$O/repo-slug.sh"
elif [ -f "$_HERE_RS/repo-slug.sh" ]; then . "$_HERE_RS/repo-slug.sh"
else
  _fatal_rs="FATAL repo-slug.sh not found (looked in $O and ${_HERE_RS:-<unresolved>}) — refusing to guess which repo to grade"
  echo "orch-loop: $_fatal_rs" >&2
  [ -d "${O:-}" ] && { mkdir -p "${O:-}/logs" 2>/dev/null; echo "$(date) [startup] $_fatal_rs" >> "${O:-}/logs/orch-loop.log" 2>/dev/null; }
  exit 78
fi
# ⛔ THE FILE IS NOT THE FUNCTION. A present-but-STALE copy (an $O seeded from an older harness)
# sources cleanly and defines nothing, and the caller would then fall through to the literal — the
# exact wrong-surface defect this refuses. Same check repo-authority.sh gets, for the same reason.
command -v derive_or >/dev/null 2>&1 \
  || {
    _fatal_rs="FATAL repo-slug.sh in $O is stale/partial (no derive_or) — re-seed it: cp scripts/orchestrator-harness/*.sh $O/"
    echo "orch-loop: $_fatal_rs" >&2
    [ -d "$O" ] && { mkdir -p "$O/logs" 2>/dev/null; echo "$(date) [startup] $_fatal_rs" >> "$O/logs/orch-loop.log" 2>/dev/null; }
    exit 78
  }
OR_EXPLICIT="${OR:-}"
OR_RC=0
OR="$(derive_or "$REPO" "$OR_EXPLICIT")" || OR_RC=$?
if [ "$OR_RC" = "2" ]; then
  # The operator pinned something that is not owner/name. Refused, not silently replaced: grading the
  # hardcoded literal is the wrong-surface defect this change exists to end (review round 7).
  _fatal_or="FATAL OR='$OR_EXPLICIT' is not owner/name — refusing to guess which repo to grade (unset OR to derive it from REPO's origin)"
  echo "orch-loop: $_fatal_or" >&2
  # ⛔ ALSO TO $O/logs/orch-loop.log (review round 8): stderr on a launchd box lands in launchd.err,
  # not the log an operator reads, so a typo'd pin becomes a KeepAlive crash loop with no trace.
  [ -d "$O" ] && { mkdir -p "$O/logs" 2>/dev/null; echo "$(date) [startup] $_fatal_or" >> "$O/logs/orch-loop.log" 2>/dev/null; }
  exit 78
fi
if [ "$OR_RC" != "0" ]; then
  OR="daniel-ospina/tortoise"
  # ⛔ THE WARNING GOES IN TWO PLACES ON PURPOSE. stderr on a launchd box lands in launchd.err, NOT
  # in $O/logs/orch-loop.log — the one file an operator reads — so a wrong-repo WARN that only
  # reached stderr was invisible for the hours this defect lasted. Not fatal: a local mirror or a
  # `file://` origin is a legitimate checkout, and refusing to start would turn a grading mismatch
  # into a dead cell. The line stays, loudly, in both streams.
  _or_warn="WARN cannot derive owner/name from REPO=$REPO origin remote ('$(git -C "$REPO" remote get-url origin 2>/dev/null || echo none)') — grading $OR; set OR=<owner/name> to name the repo explicitly"
  echo "orch-loop: $_or_warn" >&2
  [ -d "$O" ] && echo "$(date) [startup] $_or_warn" >> "$O/logs/orch-loop.log" 2>/dev/null
fi
# ⛔ EXPORTED, AND THAT IS LOAD-BEARING (#2040 review). `refresh-candidates.sh` reads its LISTINGS
# from $OR, and it runs as a CHILD (`bash "$O/refresh-candidates.sh" 6`). A DERIVED value never
# reached this script through the environment, so without this export the child re-derives its own
# default — the pool would come from one repo while the controller graded another. (Before this
# change the same held true, consistently: both sides used the same literal.)
export OR
# ⛔ NO `export REPO` HERE, DELIBERATELY. It would be a no-op for every supported invocation: a
# value that reached this script through the environment is ALREADY exported to the refresh and
# every child, and a value set without `export` in the operator's shell never reaches the script at
# all -- the guard above exits 78 first. (Sourcing this file instead of executing it is not a
# supported entry point, and would be the one case where `export` was load-bearing.)
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1

MAX_FIX="${MAX_FIX:-3}"
MAX_FIX_TRIES="${MAX_FIX_TRIES:-3}"
# ── THE RED-FIXER ROLE'S TWO CAPS (agent-infra — the week the fleet sat on red PRs) ────────────────
# A rail refusal is head-scoped work, so the budget is too: `MAX_RED_FIX` bounds how much of THIS
# BOX the role may take (4 fixer lanes), and `MAX_RED_FIX_TRIES` bounds how many times ONE HEAD may
# be fixed (2). After that the refusal is REPORTED and the PR parks — the role must never become a
# loop, which is the other way an auto-repair can fail (a fixer that cannot fix re-spawned forever
# is worse than the stall it replaced: it burns the box that could have merged something else).
MAX_RED_FIX="${MAX_RED_FIX:-4}"
MAX_RED_FIX_TRIES="${MAX_RED_FIX_TRIES:-2}"
# ⛔ MAX_LOAD IS A SANITY CEILING, NOT A THROUGHPUT TARGET -- and 16 was too tight for this box.
# Measured 2026-10-13 over 3940 log lines of the live harness: 103 were
# `[dispatch] skipped (load=N>=max_load=16)` and 96 were merge-priority. The gate DID open when
# load dipped below 16 (13 `[dispatch] load=` lines exist in that window), so the accurate claim is
# that it is too tight for a 17-workspace fleet on 10 cores -- NOT that it never opened. The box
# merged 25 PRs in a day at load 17-52 and has been observed functioning at ~100; a ceiling at 16
# leaves the dispatcher off for most of the day.
# The REAL capacity constraint is the machine (available RAM / swap) -- see the gate chain below.
# Derive the ceiling from the core count so it scales, and keep the env override.
# sysctl -n hw.ncpu is macOS-only: on a Linux cell sysctl may be absent entirely (Debian's procps
# does not ship it any more — verified in debian:stable-slim) and hw.ncpu is a macOS key regardless,
# so the fallback silently pinned _NCPU=4 for EVERY cell and MAX_LOAD=40 with it (#1702).
# ⛔ LEADING ZEROS ARE NOT NUMBERS HERE (P2, second review round, 2026-10-14). `''|*[!0-9]*`
# ACCEPTED `08`, and `$(( ))` parses base 0 (a leading 0 means OCTAL; `08`/`09` are not octal).
# On /bin/bash 3.2.57 — what the launchd plist invokes — the failed arithmetic ASSIGNMENT aborts
# the rest of the enclosing block and resumes after it with status 0, silently. Inside `while true`
# it is worse: the whole loop is discarded and the script exits 0 after one cycle. Two shipped
# consequences: `CYC=08` reached `JIT=$(( CYC / 5 ))` and turned the controller into a
# relaunch-per-cycle loop under KeepAlive, and a leading-zero timeout reached the lease arithmetic in
# the merge/fix workers. Accept only `0` or `[1-9][0-9]*`.
# NOTE this also tightens `is_limit` below (it delegates here), which is how CYC=08 is coerced to
# 240 before any arithmetic sees it. `is_num` must stay otherwise generous: it also validates a
# 10-digit epoch mtime, and a tighter DIGIT bound silently rejected every file as un-stat-able.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# A digit string is not enough for a TUNABLE: `[` errors at or above 2**63, and an errored test is
# FALSE, which OPENS the very gate the value configures (MAX_LANES=99999999999999999999 passed the
# class test, then `[ "$LANES" -ge "$MAX_LANES" ]` errored and the lane cap was gone). So the limits
# carry a bound too -- but ONLY the limits: `is_num` must stay generous because it also validates an
# epoch mtime, which is already 10 digits, and a tighter bound silently rejected every file as
# un-stat-able (the reaper stopped reaping).
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# Coerce HERE — immediately before the ONLY reads of _NCPU and MAX_LOAD, not in the input-validation
# block 30 lines below. A guard placed THERE guarded nothing (#1702 review): MAX_LOAD is derived on
# the next line, a non-numeric _NCPU already made `$(( _NCPU * 10 ))` fail, and under `set -u` the
# loop then aborted at the first `[ "$L" -ge "$MAX_LOAD" ]` — the same failure class this PR fixes.
# MAX_LOAD gets the same coercion for the same reason every other threshold below does: it is
# supplied by the launchd plist, and a typo there would open the load gate rather than close it
# (`[ -ge ]` on a non-number is FALSE, and a false test in the gate chain ALLOWS dispatch).
#
# It is `is_limit`, not `is_num`, because a non-number is only the FIRST way the gate opens: `[`
# ERRORS at or above 2**63 ("integer expression expected"), so an absurd-but-numeric MAX_LOAD
# slips past is_num and then aborts the gate chain — the same fail-open this block exists to close.
# ⛔ `_NCPU` GETS THE SAME BOUND (P3, fourth review round, 2026-10-14), and the failure it prevents
# is NOT the plist's: `_NCPU` is an OS probe (`sysctl`/`nproc`), so an absurd-but-numeric value
# reaches `$(( 10#$_NCPU * 10 ))` and the magnitude WRAPS instead of erroring — and each wrapped
# outcome is individually a VALID number, so no downstream guard can see it. Measured on
# /bin/bash 3.2.57: 99999999999999999999 * 10 wraps to 3875820019684212726, and -- CORRECTED, fifth
# review round 2026-10-14: that is 19 digits but still BELOW 2**63-1, so `[ -ge ]` does NOT error.
# It just NEVER BINDS and the load gate OPENS SILENTLY (the same mechanism as the 9-digit product
# two sentences below; the earlier comment wrongly said `[ -ge ]` ERRORS here). And
# 9223372036854775808 (2**63) * 10 wraps to exactly **0**, which
# `is_limit` ACCEPTS — and `[ "$L" -ge 0 ]` is always true, so the load gate CLOSES and the box
# dispatches nothing, indefinitely. Bound the PROBE so neither wrap can be produced.
# ⛔ AND MAX_LOAD NEEDS A TRUE DEFAULT, not a re-derivation (same round): the first fallback
# recomputed from the SAME `_NCPU`, so it could not repair an out-of-range product — a 9-digit
# _NCPU yields a 10-digit product (999999999 -> 9999999990), which is under 2**63 so `[ -ge ]` does
# not error, it just never binds and the gate silently OPENS. The second guard falls back to the
# documented default instead. (`MAX_LOAD` may still be set to 0 deliberately — install.sh allows 0
# for every limit but CYC — so this bounds the DERIVATION, never a plist value that passes is_limit.)
is_limit "${_NCPU:-}"    || _NCPU=4
# A 0-valued probe is a FAILED probe, not "no cores": `10 * 0` is 0, `is_limit 0` is true, and
# `[ "$L" -ge 0 ]` is always true, so the load gate CLOSES and the box dispatches nothing, forever.
# install.sh carries the identical line (P3, fifth review round, 2026-10-14).
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 )); is_limit "${MAX_LOAD:-}" || MAX_LOAD=40
# ⛔ CAPACITY, NOT A LANE COUNT (owner ruling, 2026-10-17): "dispatch should be gated on capacity,
# not on number of lanes. max lanes 8 is too low. that needs to be configured to 2.5x the number of
# CPUs". Both numbers in play were LANE COUNTS that no hardware decided: the shipped default was a
# FLAT 4, and the box this was measured on had its plist PINNED at 8 —
# `[cap] load=79/100 lanes=9/8 … [dispatch] skipped (lanes=9>=max_lanes=8)` — 21 points of load
# headroom and comfortable swap/memory, so the NEXT dispatch was refused for a lane count while
# capacity was available. `MAX_LOAD` above already derives from cores; same rule here.
# Integer division, so it FLOORS (4 cores -> 10, 3 -> 7). An explicit MAX_LANES still WINS and is not
# recomputed — with ONE exception, spelled out at the coercion block below: a present-but-INVALID
# value (`4x`, `09`, ten digits) is repaired there to this same derived default.
MAX_LANES="${MAX_LANES:-$(( 10#$_NCPU * 5 / 2 ))}"
MAX_REVIEW="${MAX_REVIEW:-4}"   # keep in sync with install.sh's default and README §4
# Above this many UNOWNED open PRs (open PRs nothing is currently working — pr_owned() below),
# merging takes priority and new lanes stop being dispatched. The pre-fix gate counted the TOTAL
# open count, so a PR mid-review, mid-fix, mid-merge — or held by a claim on another box — read as
# congestion. Measured 2026-10-16: two live cells logged `merge-priority (20 open PRs — draining)`
# at `lanes=1` of a configured 32 with 59-86% CPU idle and 13.9 GB RAM free, while 17 of those 20
# PRs carried a merge state of BEHIND/DIRTY. ⛔ Merge state is NOT an ownership signal (pr_owned
# reads worker sessions, claims and markers only), so that measurement does not by itself show those
# 17 were being worked — and the cells' own `workers=0` shows no LOCAL worker held them (only a
# cross-box claim could have). What it does show is that the gate was counting the wrong thing:
# raising the number alone would still cap a cell whose whole queue is owned.
# Raised to 25 (owner ruling: "we should have something more like 10 PRs who are not being
# processed"). MERGE_PRIORITY_AT also raises the reviewer AND fixer budgets in drain mode.
MERGE_PRIORITY_AT="${MERGE_PRIORITY_AT:-25}"
# ⛔ THE GATE IS NOT BOUNDED IN TIME OR IN EVIDENCE — #2099 REMOVED THAT (owner ruling, 2026-10-18).
# This comment used to describe an AGE/EVIDENCE arm: the gate "also requires POSITIVE evidence that a
# drain is happening" (work in flight + a land inside the window + a young enough unowned PR), and that
# a missing record would let dispatch through. NONE OF THAT SHIPPED. The shipped rule is the opposite
# and it is one line: for as long as ANY workable un-owned PR remains, issues are not opened — no
# threshold, no age, no evidence arm, no exception for a stalled drain (`mp_reason`).
#
# What a stall gets instead is a NAME, in `[dispatch] DRAIN STALLED …` beside the gate it explains, and
# `MERGE_PRIORITY_MAX_AGE_MIN` is the WINDOW that line measures — it is a diagnostic period, never an
# input to the decision. Measured 2026-10-18 for the record: all three cloud cells sat at
# `merge-priority (52 unowned of 54 open PRs — draining before opening more)` at `lanes=0` for HOURS
# with a 219-issue pool behind it. The answer to that was to make the drain WORK (agent-infra#2126:
# every counted un-owned PR is now either acted on or carries a printed reason), not to let new work
# start while the old work sits. A gate whose opening condition the automation cannot meet is still not
# a licence to open it — it is a drain defect, and it is reported as one.
#
# `MERGE_PRIORITY_AT` is retained ONLY as the unreadable-count fallback (a malformed/invalid count
# fails CLOSED to `MERGE_PRIORITY_AT + 1`, i.e. "treat the count as over the line"), and `MR`/`MF`
# (review_slots/fix_slots) still scale the worker budgets with the backlog. Neither can open the gate.
MERGE_PRIORITY_MAX_AGE_MIN="${MERGE_PRIORITY_MAX_AGE_MIN:-180}"
# How old a `state/refresh-funnel` record may be before the funnel line says STALE instead of
# printing it as this cycle's decomposition. Two refresh cycles (the refresh only runs while the
# backlog is below 6, so a quiet box can legitimately go a few cycles between records); past that,
# an old pass's numbers beside a newer `queue=` are a contradiction, not a measurement.
FUNNEL_MAX_AGE_MIN="${FUNNEL_MAX_AGE_MIN:-30}"
MIN_SWAP_FREE="${MIN_SWAP_FREE:-600}"
# Available memory = free + inactive. macOS shows memory pressure as COMPRESSION with swap flat,
# so a swap-only gate does not see it. See the gate chain below.
MIN_MEM_FREE_MB="${MIN_MEM_FREE_MB:-512}"
BATCH="${BATCH:-2}"
CYC="${CYC:-240}"
# ── the per-repo merge contract (agent-infra#1764) ─────────────────────────────
# The required-check list and the review authority are REPO-DEPENDENT inputs. This line used to
# BE tortoise's branch-protection list, so a controller pointed at agent-infra named eight checks
# that can never appear there, every PR read `FAILED:ai-review-gate`, and the merge queue could
# not drain. They now live in repo-authority.sh, SOURCED here and by merge-one.sh so the two
# cannot drift.
# ⛔ REQ in the environment is an operator override and WINS. Capture it ONCE: the cycle below
# overwrites REQ with the resolved value, so reading REQ as "the override" on the next cycle
# would freeze the first cycle's answer (see REQ_OVERRIDE's note in repo-authority.sh).
_HERE_RA="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -f "$O/repo-authority.sh" ]; then . "$O/repo-authority.sh"
elif [ -f "$_HERE_RA/repo-authority.sh" ]; then . "$_HERE_RA/repo-authority.sh"
else echo "orch-loop: FATAL repo-authority.sh not found (looked in $O and ${_HERE_RA:-<unresolved>}) — refusing to run without the per-repo merge contract" >&2; exit 78; fi
# ⚠️ review round 3: a PRESENT but stale/partial repo-authority.sh sources cleanly and silently
# yields REQ="" — which used to read as `rail`. The resolver must actually exist.
command -v resolve_required_checks >/dev/null 2>&1 && command -v merge_authority >/dev/null 2>&1 \
  || { echo "orch-loop: FATAL repo-authority.sh at $O is stale (no resolve_required_checks/merge_authority) — refusing to run without the per-repo merge contract" >&2; exit 78; }
REQ_OVERRIDE="${REQ:-}"
REQ=""

mkdir -p "$O/logs" "$O/state"
LOG="$O/logs/orch-loop.log"
# ── THE WORKER LAUNCHER (worker-terminal.sh) ────────────────────────────────────
# Every worker this loop starts — fixers, reviewers, rail workers — is started, counted and killed
# through ONE module. That is not tidiness: a tmux window on a cloud cell dies at ~21 log lines
# (measured on all three cells, 2026-10-20) while the same lane in a DURABLE TERMINAL survives, so
# the launcher, the census the caps read, and the reaper must all move together or the caps stop
# binding (a census that still counts `tmux ls` reports 0 workers for durable terminals and the
# ceiling never trips). See that file's header for the measurement and for the refusal stance.
for _wt_cand in "$O/worker-terminal.sh" "$(dirname "${BASH_SOURCE[0]:-$0}")/worker-terminal.sh"; do
  [ -f "$_wt_cand" ] && { WT_MOD="$_wt_cand"; break; }
done
[ -n "${WT_MOD:-}" ] && . "$WT_MOD"
# ⛔ A PRESENT-BUT-STALE COPY IS THE SAME DEFECT AS AN ABSENT ONE: if the module does not define the
# verbs this controller actually calls, a spawn silently becomes "no session", the census reports an
# empty box and the loop prints a healthy idle controller. So the guard covers EVERY verb used below —
# not just the three that look load-bearing (`wt_launcher` feeds the startup line and `wt_table` feeds
# the reap, and a module missing either would leave the controller logging `launcher=` and 0 workers).
for _wt_v in wt_spawn wt_alive wt_count wt_close wt_launcher wt_table; do
  command -v "$_wt_v" >/dev/null 2>&1 || { echo "orch-loop: FATAL worker-terminal.sh is missing or stale at ${WT_MOD:-$O} (no $_wt_v; needs wt_spawn/wt_alive/wt_count/wt_close/wt_launcher/wt_table) — refusing to run a controller that cannot start, count or reap its workers; fix: cp scripts/orchestrator-harness/*.sh $O/" >&2; exit 78; }
done
# Where a worker is started from. A tmux session inherited the controller's cwd implicitly; a durable
# terminal's login shell starts in the DAEMON's idea of a cwd, so it is passed explicitly now. The
# workers cd to their own repo/worktree themselves, so this only has to be a sane, existing place.
SPAWN_CWD="$(pwd)"
# Say which launcher this surface got, ONCE, at startup. A cell that quietly landed on `none` would
# otherwise look like a controller with nothing to do — the exact false green this change removes.
echo "[startup] worker launcher=$(wt_launcher) (cmux=$(command -v cmux >/dev/null 2>&1 && echo yes || echo no), uname=$(uname -s 2>/dev/null))" >> "$LOG"
touch "$O/dispatched.txt" "$O/candidates.txt" "$O/checked.txt"
chmod +x "$O"/*.sh 2>/dev/null

# ── input validation ───────────────────────────────────────────────────────────
# These values come from the GitHub API and are then embedded in shell strings that tmux runs via
# `sh -c`, so they are attacker-controlled. git permits ' ; $ ` & | ( ) { } " < > # in a ref name
# (only spaces are forbidden, and ${IFS} supplies those), so a fork PR on branch
# `fix/x';curl${IFS}evil;#` achieved arbitrary command execution on the merge host. Validate.
safe_ref() {
  case "${1:-}" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  git -C "$REPO" check-ref-format --branch "$1" >/dev/null 2>&1
}

# shq <value> -> a POSIX-sh-safe single-quoted word.
# ⛔ NOT `printf %q`. bash's %q emits `$'…'` for any byte outside [[:print:]], and `$'…'` is NOT a
# quoting form in POSIX sh: on a Debian/Ubuntu cell `/bin/sh` is dash, so the quoting is LOST and
# the remainder is re-parsed as COMMANDS. Measured 2026-10-15 (round-8 adversarial review, class
# B6): the spawn line below carried a required-check name containing ESC and executed an injected
# command on the merge host — `REQ=$'a\'\E;touch${IFS}/tmp/PWNED;#'`. `%q` is only safe where the
# reader is bash (the macOS operator box), which is exactly why it went unnoticed.
# Single-quoting with `'\''` escaping is POSIX and correct for EVERY byte (a newline included), so
# it needs no character screen and cannot be defeated by a byte the screen forgot.
shq() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }
# A non-numeric threshold makes `[ -le ]` ERROR -- which returns false, and a false test in the gate
# chain OPENS the gate. So a typo in the plist env (MIN_MEM_FREE_MB=abc) would silently remove the very
# back-pressure these gates exist to apply. Coerce to the documented default instead of failing open.
is_limit "${MIN_SWAP_FREE:-600}"   || MIN_SWAP_FREE=600
is_limit "${MIN_MEM_FREE_MB:-512}" || MIN_MEM_FREE_MB=512
# The same rule applies to EVERY other plist-supplied limit, and these are the ones that fail in the
# OPEN direction: MAX_LANES drops the lane cap (`[ "$LANES" -ge "$MAX_LANES" ]` errors to false, and
# a false test ALLOWS dispatch), MERGE_PRIORITY_AT makes mp_reason() print nothing so the
# drain-before-dispatch gate disappears entirely, BATCH never breaks the candidate loop
# (`[ "$K" -ge "$BATCH" ]` errors to false) so ONE cycle dispatches and writes off the whole backlog,
# and CYC makes `sleep` error so the controller spins with no delay. MAX_FIX_TRIES and MAX_REVIEW
# fail OPEN too, which is worth spelling out because both LOOK like caps: `[ "$NFC" -ge "$MAX_FIX_TRIES" ]`
# errors to false and control falls straight through to the SPAWN `elif`, so a cap of 3 let fixer
# attempt 10 run; and `$((MAX_REVIEW + 2))` reads a leading-zero value as OCTAL (030 -> 26, not 30),
# which is the same trap the scope decision already normalises with `10#` below. MAX_FIX is coerced
# for the same reason. Each is first read below this point, so coercing here is still guard-before-use.
# ⛔ MAX_LANES IS REPAIRED TO ITS OWN DERIVED DEFAULT, not to a flat 4 (owner ruling, 2026-10-17):
# a garbage plist value must leave the box with the ceiling its CORES imply (see the derivation at
# the top), or a typo would silently pin one machine to a lane count its hardware never chose. The
# repair is BOUNDED exactly as MAX_LOAD's is: `_NCPU` passes `is_limit` at nine digits, so
# `* 5 / 2` can produce a ten-digit lane count that `is_limit` rejects — and only a TRUE default can
# repair that, since re-deriving from the same probe returns the same value. 10 = a 4-core box's
# 2.5x. `MAX_LANES=0` still passes `is_limit` and dispatches nothing — unchanged, deliberate.
is_limit "${MAX_LANES:-}"         || { MAX_LANES=$(( 10#$_NCPU * 5 / 2 )); is_limit "${MAX_LANES:-}" || MAX_LANES=10; }
is_limit "${MAX_REVIEW:-}"        || MAX_REVIEW=4
is_limit "${MERGE_PRIORITY_AT:-}" || MERGE_PRIORITY_AT=25
# ⛔ A 0 WINDOW MAKES THE GATE INERT, SILENTLY: `is_limit 0` is TRUE (0 is a valid count), and with
# a 0-minute window `[ "$age" -lt 0 ]` and `now - land <= 0` are both false, so mp_reason can never
# return a reason — the guard disappears with no trace in any log. Coerce on the `is_limit` line
# itself (the same shape as every other limit, and the one the suite's coercion extraction can
# count), rather than on a bare `[ … -ge 1 ]` test a mutation could delete unseen.
is_limit "${MERGE_PRIORITY_MAX_AGE_MIN:-}" || MERGE_PRIORITY_MAX_AGE_MIN=180; [ "${MERGE_PRIORITY_MAX_AGE_MIN:-0}" -ge 1 ] || MERGE_PRIORITY_MAX_AGE_MIN=180
is_limit "${FUNNEL_MAX_AGE_MIN:-}" || FUNNEL_MAX_AGE_MIN=30; [ "${FUNNEL_MAX_AGE_MIN:-0}" -ge 1 ] || FUNNEL_MAX_AGE_MIN=30
is_limit "${MAX_FIX:-}"           || MAX_FIX=3
is_limit "${MAX_FIX_TRIES:-}"     || MAX_FIX_TRIES=3
# Both red-fixer caps fail OPEN in the same shape MAX_FIX_TRIES documents above (`[ "$n" -ge "$cap" ]`
# errors FALSE and control falls through to the SPAWN), so they are coerced here like every other
# plist-supplied limit. `0` stays a valid value: it means "this box never spawns a red-fixer", which
# is a deliberate way to run the role REPORT-ONLY.
is_limit "${MAX_RED_FIX:-}"       || MAX_RED_FIX=4
is_limit "${MAX_RED_FIX_TRIES:-}" || MAX_RED_FIX_TRIES=2
is_limit "${BATCH:-}"             || BATCH=2
is_limit "${CYC:-}"               || CYC=240
# ⛔ CYC ALSO NEEDS A FLOOR, NOT JUST A TYPE CHECK (P3, third review round, 2026-10-14). `is_limit 0`
# is TRUE and install.sh's range loop explicitly allowed `0`, so `CYC=0` survived all the way to
# `sleep $(( 10#0 - 0 + RANDOM % 1 ))` = `sleep 0` — the controller revisited every cycle with no
# delay, hammering the GitHub API. The floor is a small 5s (not 240, which would silently replace a
# deliberate small value); install.sh refuses < 5 at render time, so the two ends agree.
[ "$CYC" -ge 5 ] || CYC=240
# agent-infra#1762. SWEEP_MAX_AGE bounds how long a 304 may serve a cached "unchanged" listing (see
# the sweep listing block for the measured reason the bound is required). SWEEP_MIN_REMAIN is the
# x-ratelimit-remaining floor below which the NEXT sweep is deferred to the reset.
SWEEP_MAX_AGE="${SWEEP_MAX_AGE:-600}"
is_limit "${SWEEP_MAX_AGE:-}"      || SWEEP_MAX_AGE=600
SWEEP_MIN_REMAIN="${SWEEP_MIN_REMAIN:-20}"
is_limit "${SWEEP_MIN_REMAIN:-}"   || SWEEP_MIN_REMAIN=20

# ── portable OS primitives ─────────────────────────────────────────────────────
# This harness runs on macOS (the operator's box, launchd) AND on a Linux cell
# (cloud-cell-supervisor.sh), so every probe below carries both a Linux and a macOS path.
# Found the hard way (#1702): `stat -f '%m'`, `sysctl -n vm.loadavg` and `sysctl -n vm.swapusage`
# are BSD/macOS-only. On GNU coreutils `stat -f '%m' F` prints the FILESYSTEM LISTING on STDOUT and
# exits 1 — so `$(stat -f '%m' F 2>/dev/null || echo $(date +%s))` captured the listing PLUS the
# fallback, the arithmetic failed, `age` was left unset, and under `set -u` the next
# `[ "$age" -gt ... ]` aborted the whole controller. Reachable ~1 cycle after the first dispatch on
# every cell (each lane/merge/fix writes the log the reaper stats). Reproduced on GNU coreutils 9.7
# (debian:stable-slim): `age: unbound variable`, rc=1, no cycle completes.
# GNU first, BSD second — deliberately NOT the other way round, and this is why the obvious
# `stat -f '%m' F || stat -c '%Y' F` ladder is wrong: on GNU the FIRST form does not fail quietly,
# it writes the listing to stdout before exiting 1, and `||` cannot discard stdout. In this order
# `stat -c '%Y'` is a clean failure on BSD (empty stdout, rc 1), so exactly one numeric line results.
file_mtime_epoch() { # <file> -> mtime as epoch seconds; NON-ZERO rc when unreadable (never a guess)
  local m
  m="$(stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null)" || return 1
  is_num "$m" || return 1
  printf '%s\n' "$m"
}
# 1-min load average. THE FIELD DIFFERS: /proc field 1 IS the 1-min load, while macOS
# `sysctl vm.loadavg` prints `{ 1.70 1.90 2.00 }`, so field 2 is. One shared awk would therefore
# read the wrong field on one of the two platforms — the bug this function's test pins.
# The argument is a TEST SEAM (the call site passes nothing), the same idiom as mp_reason() /
# review_slots(): without it the Linux branch could only be exercised on a Linux host.
load1() { # [<loadavg-file>]
  local p="${1:-/proc/loadavg}"
  if [ -r "$p" ]; then
    awk '{printf "%d\n", $1}' "$p" 2>/dev/null
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'
  fi
}
# Swap as MB. Linux reports kB in /proc/meminfo; macOS prints `total = 2048.00M ... free = ...`.
# Echoes "<free_mb> <total_mb>"; NON-ZERO rc when unmeasurable, so the caller can tell "no swap
# configured" (total 0 — the documented allow) from "we could not read it". An unreadable probe is
# NOT treated as pressure: that decision is argued at the gate chain, where the value is consumed.
# The argument is a TEST SEAM (the call site passes nothing).
swap_usage_mb() { # [<meminfo-file>]
  local p="${1:-/proc/meminfo}"
  if [ -r "$p" ]; then
    awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
         END {if (t=="" || f=="") exit 1; printf "%d %d\n", f/1024, t/1024}' "$p" 2>/dev/null
  else
    sysctl -n vm.swapusage 2>/dev/null | awk '
      {for(i=1;i<=NF;i++){if($i=="total")t=$(i+2); if($i=="free")f=$(i+2)}}
      END {if (t=="" || f=="") exit 1; printf "%d %d\n", f, t}'
  fi
}
# Available memory as MB. Linux: /proc/meminfo MemAvailable, falling back to MemFree+Cached on a
# kernel too old to expose it; macOS: `free` + `inactive` vm_stat pages (top's "unused" PhysMem is a
# different figure, and macOS shows pressure as COMPRESSION with swap flat). NON-ZERO rc when
# unmeasurable, and the CALLER MUST keep treating that as UNKNOWN -> do not add work: unlike load and
# swap this probe is deliberately FAIL-CLOSED ("UNKNOWN, not ample"), and that ruling is not this
# function's to change. Before #1702 there was no Linux path at all, so on a cell the probe yielded
# empty, MEM_UNKNOWN was set every cycle, and the capacity gate named `mem_probe_failed` forever —
# the controller completed cycles and dispatched nothing, which is the false green #1702 exists to
# remove. The macOS page size is derived from vm_stat's own header (16 KiB is Apple silicon; Intel
# Macs are supported and a hardcoded 16384 over-reports memory 4x -- the unsafe direction).
# The argument is a TEST SEAM (the call site passes nothing).
mem_avail_mb() { # [<meminfo-file>]
  local p="${1:-/proc/meminfo}" mb
  if [ -r "$p" ]; then
    mb="$(awk '
      /^MemAvailable:/ {a=$2}
      /^MemFree:/ {f=$2}
      /^Cached:/ {c=$2}
      END {if (a!="") v=a; else if (f!="" && c!="") v=f+c; else exit 1
           printf "%d", v/1024}' "$p" 2>/dev/null)" || return 1
  else
    mb="$(vm_stat 2>/dev/null | awk '
      /page size of/ {ps=$8}
      /Pages free/ {gsub(/[.]/,"",$3); f=$3}
      /Pages inactive/ {gsub(/[.]/,"",$3); i=$3}
      END {if (ps=="") ps=16384; if (f=="" || i=="") exit 1
           printf "%d", (f+i)*ps/1048576}')" || return 1
  fi
  is_num "$mb" || return 1
  printf '%s\n' "$mb"
}
# $O is operator config, not attacker input, but a quote or metacharacter here would break every
# spawn (the tmux command string is executed via sh -c). Fail loudly instead of failing mysteriously.
case "$O" in
  *"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) echo "[fatal] \$O must not contain a quote or shell metacharacter: $O" >&2; exit 1 ;;
esac

# ── the selection module: live ownership + the PR-first order (owner rule) ─────
# ⛔ THE OWNER'S DISPATCH RULE IS CODE, NOT OPERATOR HABIT (2026-10-18): take on UN-OWNED PRs
# first — "owned" meaning a LIVE PROCESS is working the PR — and only pick issues for NEW work once
# no un-owned PR remains. It lives in its own file for one reason: it is the one part of the cycle
# whose correctness is a fact about the MACHINE (which processes are in which checkout), so it is
# driven directly by live-ownership.test.sh against real processes rather than extracted from this
# 1,700-line loop.
# `$O` is the runtime copy the daemon executes (install.sh seeds it); the repo copy is the fallback
# for a box whose $O predates this change. NEITHER present is a degrade, not a crash: LO_SCAN=0
# falls back to the registry predicate below and says so in the log every cycle, because a silent
# fallback would read exactly like a working live scan.
LO_SCAN=0
LO_LIVE="$O/state/live-owners.tsv"
_lo_mod=""
if [ -f "$O/live-ownership.sh" ]; then _lo_mod="$O/live-ownership.sh"
elif [ -f "$(dirname "$0")/live-ownership.sh" ]; then _lo_mod="$(dirname "$0")/live-ownership.sh"
fi
if [ -n "$_lo_mod" ]; then
  # shellcheck source=/dev/null
  . "$_lo_mod"
fi
# ⛔ THE INTERFACE, NOT THE FILE (review R2, P2). `LO_SCAN=1` used to be set by the module FILE
# sourcing, so a `$O` copy that provides `lo_scan` but not `lo_order`/`lo_select_rows`/
# `lo_class_compact` produced an EMPTY `SEL_ROWS` — and the sweep then acted on ZERO PRs, silently,
# while `scan=ok` and the log claimed the opposite. Gate on every function the loop actually calls:
# one missing name means the registry-only degrade, which WORKS and says so.
if declare -f lo_scan lo_order lo_select_rows lo_select lo_class_compact >/dev/null 2>&1; then
  LO_SCAN=1
elif [ -n "$_lo_mod" ]; then
  printf '[select] live-ownership.sh is present but INCOMPLETE (needs lo_scan/lo_order/lo_select_rows/lo_select/lo_class_compact) — ownership stays registry-only this cycle\n' >> "$LOG" 2>/dev/null || true
fi

# ── the record a RAIL REFUSAL leaves behind (the red-fixer role reads it) ────────
# `merge-one.sh` writes it (`rail-refusal.sh` classifies and stores the refusal, head-bound), and
# the PR sweep below turns it into a fixer lane. Sourced from the SAME two homes as every module
# here: `$O` is what the daemon executes, the directory is the fallback. The role is gated on the
# INTERFACE (`declare -f`), not on the file, for the reason live-ownership.sh documents above — a
# present-but-stale copy sources cleanly and defines nothing.
_rf_mod=""
if [ -f "$O/rail-refusal.sh" ]; then _rf_mod="$O/rail-refusal.sh"
elif [ -f "$(dirname "$0")/rail-refusal.sh" ]; then _rf_mod="$(dirname "$0")/rail-refusal.sh"
fi
REDFIX=0
if [ -n "$_rf_mod" ]; then
  # shellcheck source=/dev/null
  . "$_rf_mod"
fi
if declare -f rail_refusal_field rail_refusal_get rail_refusal_record rail_refusal_class rail_refusal_clear >/dev/null 2>&1; then
  REDFIX=1
elif [ -n "$_rf_mod" ]; then
  # ⛔ THE INTERFACE, NOT THE FILE, applied here too. A PARTIAL module (say it defines
  # `rail_refusal_record` but not `rail_refusal_get`) satisfies merge-one.sh's gate, so refusals keep
  # being WRITTEN and logged as "recorded" while this loop reads none of them — a stored refusal with
  # no reader is the stall this role exists to end, with a log that says the opposite. Name it.
  printf '[redfix] rail-refusal.sh is present but INCOMPLETE (needs rail_refusal_field/get/record/class/clear) — every stored rail refusal is IGNORED this cycle; a rail refusal therefore spawns no fixer. Re-seed: cp scripts/orchestrator-harness/*.sh "\$O/"\n' >> "$LOG" 2>/dev/null || true
fi
# ⛔ AND WHEN THE MODULE IS ABSENT ALTOGETHER: no reader exists, so a record already on disk would be
# a refusal nobody acts on and nothing would say so. One line, only while such records exist.
if [ "${REDFIX:-0}" != "1" ]; then
  _rf_orphan=""
  for _f in "$O"/state/railrefusal-*; do [ -f "$_f" ] && { _rf_orphan="$_f"; break; }; done
  [ -n "$_rf_orphan" ] && printf '[redfix] rail-refusal.sh is MISSING (looked in \$O and the script directory) but %s exists — that refusal is IGNORED, so no red-fixer can be spawned for it. Re-seed: cp scripts/orchestrator-harness/*.sh "\$O/"\n' "$_rf_orphan" >> "$LOG" 2>/dev/null || true
fi

# A stale claim must not mean "in flight" forever: merge-one.sh removes its claim only on clean
# exit, so a SIGKILLed worker or a reboot mid-merge would otherwise stall that PR permanently.
claim_live() { # claim_live <pr> [<head-sha>] — SPAWN GUARD: a local lock OR a cross-box lease
  local f="$O/state/mergeclaim-$1.lock" p
  if [ -f "$f" ]; then
    p="$(cat "$f" 2>/dev/null || echo 0)"
    # ⛔ ANY LIVE PID HOLDS HERE, DELIBERATELY — the conservative direction for a SPAWN guard: a
    # recycled pid means "do not spawn" (one lost merge, recovered next cycle), and nothing is
    # deleted. pr_owned() is where a live-but-unrelated pid is a real defect, and it is bound to the
    # command line there; do NOT copy that binding here — failing it would `rm -f` a live worker's
    # lock and double-spawn.
    if [ "${p:-0}" -gt 0 ] && kill -0 "$p" 2>/dev/null; then return 0; fi
    rm -f "$f"
  fi
  claim_lease_live "$1" "${2:-}"
}

claim_lease_live() { # <pr> [<head-sha>] — the CROSS-BOX lease, and nothing local.
# ⛔ SPLIT OUT OF claim_live (review R2, P1). claim_live is the SPAWN GUARD and its first arm is a
# deliberately-loose "any live pid" test; ownership (pr_owned -> claim_foreign_live) must NOT
# inherit that looseness, or a stale lock with a recycled pid lends liveness to an EXPIRED lease.
# One lease reader, two callers, no lock arm here.
  # Cross-box (agent-infra#1709 recs 1-3): a reviewer on ANOTHER box holds the claim as a git
  # ref keyed on <PR>-<head-sha>. The pid check above CANNOT see it — a remote pid is not
  # inspectable — so the claim's LEASE is the liveness signal. Read from the snapshot refreshed
  # once at the top of this cycle, not from the network per PR.
  local sha="${2:-}" ref until owner now
  [ -n "$sha" ] || return 1
  [ -f "$O/state/claims-snapshot" ] || return 1
  if command -v claim_ref >/dev/null 2>&1; then ref="$(claim_ref "$1" "$sha")"; else ref="refs/claims/$1-${sha:0:12}"; fi
  until="$(awk -F'\t' -v r="$ref" '$1==r{print $3; exit}' "$O/state/claims-snapshot" 2>/dev/null)"
  owner="$(awk -F'\t' -v r="$ref" '$1==r{print $2; exit}' "$O/state/claims-snapshot" 2>/dev/null)"
  # ⛔ AN OVERSIZED LEASE IS UNPARSEABLE, AND UNPARSEABLE MEANS LIVE (P2, fourth review round,
  # 2026-10-14). This reader now agrees with claim_acquire()'s, which applies the SAME 18-digit
  # bound before its comparison (claims.sh; the bound is 18, not 9, because a lease is an EPOCH
  # SECOND — 10 digits today). Without it the two readers DISAGREED about the same datum: the bare
  # `[ "$now" -le "$until" ]` below ERRORS at or above 2**63 (rc=2, and an errored test is FALSE),
  # so claim_live() reported a foreign full-width claim as DEAD while claim_acquire() correctly
  # refused that head as live. The controller therefore reached the spawn branch EVERY cycle, the
  # refused fixer wrote fixbail-<pr>-<head>, and refund_bailed_fixer deleted that marker and
  # `parked-<pr>` on the next cycle — so the cap never tripped and the PR was never parked: one
  # refused spawn plus 1 GitHub call and 3 remote round trips per cycle, indefinitely, on a PR no
  # box could work. The conservative direction is the same one claims.sh takes: treat it as LIVE.
  #
  # ⛔ AND ABSENT IS STILL NOT THE SAME AS UNPARSEABLE (P2, fifth review round, 2026-10-14). An entry
  # MISSING from the snapshot means "no visible claim" -> NOT live. An entry whose lease reads `0`
  # means "a claim EXISTS whose lease is unreadable", and claims.sh treats exactly that as LIVE
  # (claim_acquire's `[ -z "$held_until" ] || [ "$held_until" = "0" ]`; claim_prune keeps it via
  # `[ "$until" != "0" ]`). A negative lease collapses to the same `0` — `_lease_of`'s `[0-9]*`
  # cannot match a minus sign — and so does any other non-digit. Collapsing the sentinel into the
  # absent case made these two readers DISAGREE on the one input class claims.sh documents as a
  # sentinel, with the very same consequence described above (the controller re-spawns a fixer
  # claim_acquire refuses; refund_bailed_fixer un-parks the PR every cycle, so the cap never trips).
  # `-n` is checked FIRST because absent (not live) and unreadable (live) must never be merged; the
  # non-digit test then covers the literal negative, which claim_prune also reads as "keep".
  [ -n "${until:-}" ] || return 1
  [ "${#until}" -gt 18 ] || [ "$until" = "0" ] && return 0
  [ -z "${until//[0-9]/}" ] || return 0
  # ⛔ AN ORPHANED HOLDER IS NOT IN FLIGHT, AND THIS READER MUST AGREE WITH THE REGISTRY
  # (agent-infra#2094). `claim_acquire`/`claim_issue_preflight`/`claim_prune` all consult
  # `claim_orphan_reason`; this PR-keyed snapshot reader did not, so after a rename a PR claim stamped
  # by the dead host kept the PR OUT of the sweep for its whole term and merge-one's new reclaim arm
  # was never reached — the issue path self-healed and the PR path did not. Guarded with `declare -f`
  # ⛔ AND NO `declare -f` GATE IS NEEDED (cycle-15 review): selftest.sh EXTRACTS this function
  # standalone and drives it without claims.sh, where `claim_orphan_reason` is UNDEFINED — the call
  # below then exits 127, which is non-zero, so the `if` falls through to the pre-existing polarity
  # exactly as intended. The gate that used to sit here was inert: removing it changed no behaviour in
  # any harness (measured — a mutation of it left every suite green), so the honest code is the branch
  # alone. The extraction-only path is pinned by O16, which asserts the polarity still decides there.
  if [ -n "${owner:-}" ] && claim_orphan_reason "$owner" "$ref" >/dev/null 2>&1; then return 1; fi
  # ⛔ THE CLOCK PROBE ABSTAINS TOWARD LIVE, LIKE EVERY OTHER PROBE IN THIS LADDER (P2, cycle-23
  # review). `[ "$(date +%s)" -le "$until" ]` folded an UNREADABLE clock into "not in flight": bash
  # printed `[: …: integer expression expected` on every call and the test read FALSE, so for the
  # duration of a clock failure this reader reported every worker-held PR as free — the sweep then
  # attempted a spawn per PR, `claim_acquire` refused each on its OWN clock guard, `fixbail-<pr>-<head>`
  # was written and `refund_bailed_fixer` un-parked it, so the cap never tripped (the same per-cycle
  # churn the oversized-lease case above produced, plus a stderr line per call). The three readers in
  # claims.sh all treat the same unreadable clock as LIVE (`_lease_is_live` returns LIVE for a
  # non-numeric `now`; `claim_acquire` says "local clock unreadable" and holds; `claim_issue_preflight`
  # is INCOMPLETE, never CLEAN) — and this function is the one this file calls "ONE implementation of
  # the lease polarity", so it abstains the same way instead of being the one reader that fails open.
  now="$(date +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$now" -le "$until" ] && return 0
  return 1
}

# refund_bailed_fixer <pr> <head-sha> <restore-findings: 0|1>
# fix-one.sh writes $O/state/fixbail-<pr>-<head> when the cross-box CAS REFUSES it (another box
# already owns this head). The controller books the attempt at SPAWN (fixcount+1) and, on the
# reviewer-findings arm, DELETES the findings marker there — so a refusal, which does no work at all,
# used to consume one of MAX_FIX_TRIES and destroy the record that a reviewer reported issues. Three
# refusals PARK the PR as needs-a-human although no fixer ever ran (P2, second review round,
# 2026-10-14). This refunds the attempt and restores the marker. `restore-findings` is 1 only on the
# ai-review-gate arm, because that is the only arm that deletes the marker at spawn — the CI-red and
# CONFLICTING arms never touch it, so restoring there would invent a findings record.
refund_bailed_fixer() {
  local pr="$1" head="$2" restore="${3:-0}" b f n
  [ -n "${head:-}" ] || return 0
  b="$O/state/fixbail-$pr-$head"
  [ -f "$b" ] || return 0
  rm -f "$b"
  f="$O/state/fixcount-$pr"; n="$(cat "$f" 2>/dev/null || echo 0)"
  is_num "$n" || n=0
  [ "$n" -gt 0 ] && n=$(( n - 1 ))
  echo "$n" > "$f"
  if [ "$restore" = "1" ]; then
    touch "$O/state/needsfix-$pr-$head"
    echo "#$pr fixer bailed (cross-box refusal) — attempt refunded to $n, findings marker restored" >>"$LOG"
  else
    echo "#$pr fixer bailed (cross-box refusal) — attempt refunded to $n" >>"$LOG"
  fi
  # A bail is proof the cap was not really reached; drop any park so the next cycle retries.
  rm -f "$O/state/parked-$pr"
  return 0
}

# ── SELF-REFRESH: the box re-pins itself, once per cycle (agent-infra#2215) ─────────────────────
# MEASURED 2026-10-20: three cells sat on a checkout 27 commits behind origin/main with an EMPTY
# harness pin, so fixes that had landed hours earlier were running nowhere. Nothing fetched, nothing
# compared, and an empty pin could not be told apart from a current one because no reader refused it.
#
# This block is the SCHEDULE and the DISCLOSURE; `harness-refresh.sh` is the logic (one
# implementation, driving both this loop and the operator's own `./harness-refresh.sh`). Three rules
# it encodes:
#   1. ONCE PER CYCLE. `_HR_DONE` is released at the call site at the top of each iteration and set on
#      entry here, so exactly one refresh runs per cycle and a second call within the same cycle is a
#      no-op — a future call site cannot turn the re-pin into a per-spawn storm, and the refusal speaks
#      exactly once (a warning that prints on every tool call is how #1140's noise hid a real signal).
#      ⛔ The reset is NOT here: a latch that is only set at load refreshes once per PROCESS, not once
#      per cycle, which is the failure mode this whole block exists to end.
#   2. A REFUSAL IS NEVER SWALLOWED. The script's own line goes to $LOG (the file an operator reads)
#      AND to stderr: on launchd a stderr-only WARN lands in launchd.err and has been invisible for
#      hours more than once in this repo.
#   3. A LANE MUST NOT BE SPAWNED FROM A BEHIND CHECKOUT WITHOUT THAT FACT ON THE SPAWN LINE.
#      HARNESS_TOKEN is non-empty for every relation except `current`, and is appended to EVERY
#      dispatch row (`disp`) and to the issue spawn line in dispatch-merge.sh. `current` stays quiet
#      on purpose: a token that is always present is a token nobody reads.
# ⛔ NOT A SECOND SEEDER. Advancing the pin is delegated to `cloud-cell-supervisor.sh apply --pin-only`
# (the only writer of the pinned worktree and of the provenance stamp); this loop never copies a script,
# never checks a tree out and never writes the stamp. $O is deliberately NOT re-seeded here — the next
# `start` does that from the new pin, so a running loop never calls helpers from a different commit.
# See harness-refresh.sh's header for why.
# ⛔ THE KILL SWITCH IS FOR A PINNED BUILD, NOT FOR AVOIDING A RED LINE: with HARNESS_REFRESH=off the
# box stops re-pinning AND says, once per cycle, that a stale checkout will now go unnamed.
# BEGIN harness-refresh (harness-refresh.test.sh extracts this block verbatim — keep it self-contained)
HARNESS_TOKEN=""
_HR_DONE=0
export HARNESS_TOKEN
harness_refresh_cycle() {
  [ "${_HR_DONE:-0}" = "1" ] && return 0
  _HR_DONE=1
  HARNESS_TOKEN=""
  local rr out rc rel run ref pin act rec line
  case "${HARNESS_REFRESH:-on}" in
    off|0|no)
      HARNESS_TOKEN="refresh-off"
      echo "[harness] REFRESH DISABLED (HARNESS_REFRESH=${HARNESS_REFRESH}) — this box will not re-pin, and a stale checkout will be named on no line. Nothing else is affected." >> "$LOG"
      export HARNESS_TOKEN
      return 0 ;;
  esac
  # $O first: it is what the provenance record describes and what every worker executes. Beside the
  # loop is the fallback for a box whose seed is older than this file.
  rr="$O/harness-refresh.sh"
  [ -f "$rr" ] || rr="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/orchestrator-harness/harness-refresh.sh"
  if [ ! -f "$rr" ]; then
    # ABSENT IS UNKNOWN, NEVER CURRENT (#1745): an instrument that is not on disk cannot say the box
    # is up to date, and reading its absence as "fine" is the false-PASS shape this job exists for.
    HARNESS_TOKEN="unknown"
    export HARNESS_TOKEN
    line="[harness] CANNOT-VERIFY: no harness-refresh.sh in $O or beside the loop — whether this box is behind ${HARNESS_REF:-origin/main} is UNKNOWN, and unknown is not current (re-seed: cp scripts/orchestrator-harness/*.sh $O/)"
    echo "$line" >> "$LOG"; echo "$line" >&2
    return 0
  fi
  out="$(bash "$rr" 2>&1)"; rc=$?
  # One machine line FIRST (harness-refresh.sh's contract), then one line of prose. Parse the record;
  # never the prose — an operator's wording change must not silently blank the spawn-line token.
  # ⛔ awk-with-exit / tail, never `… | head -1` in a pipeline whose writer can still be producing:
  # under this file's `set -u` a SIGPIPE tail on the writer is invisible, and `check-no-sigpipe-grep.sh`
  # gates the shape repo-wide.
  rec="$(printf '%s\n' "$out" | awk '/^harness relation=/{print; exit}')"
  rel=""; run=""; ref=""; pin=""; act=""; fst=""
  for kv in $rec; do
    case "$kv" in
      relation=*) rel="${kv#relation=}" ;; running=*) run="${kv#running=}" ;;
      ref=*) ref="${kv#ref=}" ;; pin=*) pin="${kv#pin=}" ;; action=*) act="${kv#action=}" ;;
      fetch=*) fst="${kv#fetch=}" ;;
    esac
  done
  # A refusal prints its record too, so `action=refused` still carries the relation. A missing record
  # (killed by a signal, a truncated script) is UNKNOWN — never an empty relation read as current.
  [ -n "$rel" ] || { rel=unknown; act=no-record; }
  # `current` is the ONLY relation that leaves the token empty: the code this box runs IS the ref tip,
  # so there is nothing to disclose per spawn. A mended pin is also `current` — the record was fixed,
  # the code never moved, and that fact is already on this cycle's line.
  # ⛔ EXCEPT WHEN THE COMPARISON ITSELF WAS NOT FRESH (`fetch=stale|local` in the record). `current`
  # against a ref this cycle could not fetch is cannot-verify, and measured review found the box went
  # completely SILENT in exactly that state: the warning was prose (this block keeps only the last
  # non-record line) and the token was empty. A stale comparison is named on every spawn line instead.
  if [ "$rel" = current ] && [ -n "$fst" ] && [ "$fst" != ok ]; then rel="$fst"; fi
  if [ "$rel" = current ]; then HARNESS_TOKEN=""; else HARNESS_TOKEN="$rel${run:+:$run}"; fi
  export HARNESS_TOKEN
  # The record other surfaces read (status, the next cycle's diagnosis). Staged then renamed, like
  # every other record this loop writes: a truncated state file must never replace a good one.
  { printf 'relation=%s running=%s ref=%s pin=%s action=%s fetch=%s rc=%s at=%s\n' \
      "$rel" "${run:-unknown}" "${ref:-unknown}" "${pin:-none}" "${act:-none}" "${fst:-ok}" "$rc" "$(date +%s)" \
      > "$O/state/.harness-refresh.tmp" && mv -f "$O/state/.harness-refresh.tmp" "$O/state/harness-refresh"; } 2>/dev/null \
    || echo "[harness] WARNING: could not record state/harness-refresh — the verdict below is this cycle's only copy" >> "$LOG"
  # ONE line per cycle, in the script's own words (it already names what it did). A refusal goes to
  # stderr as well: $LOG is right, but a tmux/launchd-console reader must see it too.
  line="$(printf '%s\n' "$out" | awk '!/^harness relation=/ && NF' | tail -1)"
  # ⛔ A WARNING IS NOT A DISCLOSURE UNLESS SOMETHING KEEPS IT. Only the LAST line survives above, so a
  # stale-comparison warning printed BEFORE the verdict line was being dropped from $LOG. The token now
  # carries it (see `fetch=` above), and the warning is kept verbatim for the human who reads the log.
  _warn="$(printf '%s\n' "$out" | awk '/^harness-refresh: WARNING/ || /^harness-refresh: REFUSE/ {print; exit}')"
  [ -n "$_warn" ] && echo "$_warn" >> "$LOG"
  [ -n "$line" ] || line="[harness] $rel: no message from harness-refresh.sh (exit $rc) — the verdict is recorded but unexplained"
  echo "$line" >> "$LOG"
  case "$rc" in 0|10|11) : ;; *) echo "$line" >&2 ;; esac
  return 0
}
# END harness-refresh

# single-instance lock (atomic: noclobber create fails if the file exists)
LOCKF="$O/.orch.lock"
acq() { ( set -o noclobber; echo $$ > "$LOCKF" ) 2>/dev/null; }
if ! acq; then
  OPID="$(cat "$LOCKF" 2>/dev/null || echo 0)"
  if [ "${OPID:-0}" -gt 0 ] && kill -0 "$OPID" 2>/dev/null; then echo "[orch-loop] already running (pid $OPID)"; exit 0; fi
  rm -f "$LOCKF"
  acq || { echo "[orch-loop] lock race — exiting"; exit 0; }
fi
# ⛔ THE SIGNAL HANDLERS ONLY TERMINATE — THE LOCK IS RELEASED BY THE `EXIT` TRAP ALONE.
# Was `trap 'rm -f "$LOCKF"' EXIT INT TERM`, and for INT/TERM a handler that RETURNS does NOT
# terminate: bash RESUMES the interrupted command loop, so the documented stop path
# (`pkill -f orch-loop.sh`, README §6) deleted the lock while the controller kept sweeping,
# reviewing and merging — the next start then passed acq() and two autonomous controllers ran one
# PR queue, which §5.2/§5.3 promise cannot happen (agent-infra#1715).
# Measured on /bin/bash 3.2.57 — the interpreter the rendered launchd plist invokes — with a stub
# loop: the returning trap printed and left the loop alive with the lock already gone; `exit 143`
# from a TERM handler terminated the shell (rc=143) AND still ran the EXIT trap; an UNTRAPPED TERM
# also stopped the loop, but an untrapped INT is IGNORED outright (still alive after 3s), so INT is
# trapped rather than dropped. Releasing from EXIT only makes "the lock is gone" and "the process
# is gone" the same event; a signal arriving after the handler fired leaves the lock in place
# (measured), which is fail-closed — `acq()` reclaims a dead pid.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'rm -f "$LOCKF"' EXIT

# A worker whose log has not grown in this many minutes is hung. `pi -p` has no internal
# timeout and a runaway child it spawns (a reviewer's `find /` ran for 8 hours on 2026-10-12)
# keeps the pane alive, so the concurrency caps — which count SESSIONS — silently halve.
STALE_MIN="${STALE_MIN:-40}"
# §4 documents STALE_MIN and README tells a cell to set it through $ENV_FILE, so it is env-supplied
# like the rest -- but its only read is the arithmetic just below and it had NO coercion, so
# `STALE_MIN=abc` aborted the controller mid-cycle under `set -u` ("abc: unbound variable") instead
# of degrading. Guard-before-use, same rule as every other limit.
is_limit "${STALE_MIN:-}" || STALE_MIN=40

# ── stale-worker reaper ───────────────────────────────────────────────────────
# Kill a worker that has gone silent. It only ever touches WORKERS — the census it walks is worker
# names only (`lane-`/`merge-`/`fix-`, from the launcher's own table), so it can never reach the
# operator's own shell, the controller, or any process outside the harness. The PR is re-dispatched
# by the normal sweep on the next cycle (the claim_live() check then sees a dead owner and frees it).
#
# ⛔ IT REAPS THE DURABLE TERMINAL, NOT A TMUX SESSION NAME (measured 2026-10-20). The old body walked
# `tmux ls`, so on a cell — where workers are durable terminals (worker-terminal.sh) — it matched
# NOTHING and every hung worker held its slot until a human noticed. The census and wt_close() are the
# same module the spawner uses, so "what the controller counts", "what it reaps" and "what it starts"
# cannot disagree. The tmux sessions it used to kill are still covered: they are in the same census.
reap_stale_workers() {
  local s f age m
  while IFS="$(printf '\t')" read -r s _st; do
    case "$s" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    case "$s" in merge-*|lane-*|fix-*) : ;; *) continue ;; esac
    f="$O/logs/$s.log"
    [ -f "$f" ] || continue
    # An unreadable mtime means the age is UNKNOWN, and unknown is not evidence of a hang: skip the
    # worker rather than reap it. Never let the probe's failure escape as an arithmetic error — on
    # a Linux cell that is exactly what aborted the controller one cycle after the first dispatch
    # (#1702): set -u turned the unassigned `age` into `File: unbound variable`.
    m="$(file_mtime_epoch "$f")" || continue
    age=$(( $(date +%s) - m ))
    [ "$age" -gt $(( 10#${STALE_MIN} * 60 )) ] || continue
    echo "[reap-worker] $s silent ${age}s -> closing its worker surface" >> "$LOG"
    # ⛔ A KILL THAT CANNOT BE PROVEN IS NOT A KILL. wt_close() re-reads the surface after closing and
    # returns non-zero if the worker is still there (or UNREADABLE); the record is then KEPT so the
    # next cycle retries. Reporting "reaped" on the strength of the close call alone would free a slot
    # that is still occupied — the exact arithmetic that let hung workers halve the caps.
    if ! wt_close "$s"; then
      echo "[reap-worker] $s could NOT be proven gone — record kept, retried next cycle" >> "$LOG"
    fi
  done <<EOF
$(wt_table)
EOF
}

heartbeat() { date +%s > "$O/heartbeat"; }

# ── THE POOL'S READ STATE, BESIDE THE BACKLOG (agent-infra#1931) ───────────────────────────────
# ⛔ `backlog=0` ALONE IS THE READING THAT LET A CELL IDLE ALL EVENING WHILE HEALTHY. A refresh whose
# pool listing FAILED leaves candidates.txt empty, and an empty file is byte-identical to a fleet
# with nothing to do — measured 2026-10-17: 131 consecutive passes refused for an unreadable pool and
# dispatched nothing, and every cycle line said `backlog=0`. refresh-candidates.sh records what its
# last pool READ saw, and this prints it beside the backlog in the SAME vocabulary the refresh uses
# (EMPTY / READ(n) / PARTIAL(<labels>) / UNREADABLE — one vocabulary, not a second one):
#   EMPTY      the pool was read and is genuinely empty — the only answer that may mean "no work".
#   READ(n)    the pool was read and listed n candidate(s).
#   PARTIAL(x) some priority tiers could not be read (x) — a subset, never a complete pool.
#   UNREADABLE the pool could not be read at all: the fleet is BLIND, which is not "nothing to do".
# The age of the reading is part of the token, so a value frozen by a dead refresh cannot pass as a
# fresh one (this is a STATE RECORD, and a state record with no age is a stale flag waiting to be
# read as current). UNKNOWN means no pass has EVER recorded a read — never EMPTY, because the absence
# of a measurement is not a measurement of emptiness. A torn or hand-edited file prints the state it
# does carry, with no invented age.
queue_state_token() {  # -> EMPTY(12s) / READ(7)(3m) / PARTIAL(P0-blocker)(2m) / UNREADABLE(9m) / UNKNOWN
  local tok="" at="" now age
  { read -r tok at < "$O/state/queue-state"; } 2>/dev/null || true
  case "${tok:-}" in
    EMPTY|UNREADABLE|READ\(*\)|PARTIAL\(*\)) ;;
    *) printf 'UNKNOWN'; return 0 ;;
  esac
  is_num "${at:-}" || { printf '%s' "$tok"; return 0; }
  now="$(date +%s)"; age=$(( now - at )); [ "$age" -lt 0 ] && age=0
  if   [ "$age" -lt 90 ];   then printf '%s(%ss)' "$tok" "$age"
  elif [ "$age" -lt 5400 ]; then printf '%s(%sm)' "$tok" "$(( age / 60 ))"
  else                            printf '%s(%sh)' "$tok" "$(( age / 3600 ))"; fi
}
# ── THE DISPATCH FUNNEL (agent-infra#2040) ──────────────────────────────────────────────────────
# `[dispatch] backlog empty queue=READ(223)` is a CONTRADICTION: 223 candidates were READ and zero
# were dispatchable, and the line said "empty". Measured 2026-10-18 on all three cloud cells, for
# hours: every cell read the pool perfectly and dispatched nothing, and no line anywhere said which
# step removed the 223. This prints the decomposition INSTEAD of the claim, from the refresh's own
# per-reason counts (state/refresh-funnel, written by refresh-candidates.sh) plus the counts this
# loop measures itself. It never invents a number: a missing record prints `UNRECORDED`, and the
# funnel is only printed as a decomposition when the parts are actually known.
# ⛔ AND A YIELDED BACKLOG IS A THIRD READING THAT MUST NOT READ AS STILLNESS (agent-infra#1909).
# The capacity transfer added a SECOND way for `.batch` to end up empty while the backlog is full:
# every remaining candidate was YIELDED to a peer (a saturated box stands down and leaves the item
# unconsumed). The pre-#2040 line printed `backlog empty queue=READ(3)` for that — self-contradictory
# on the one line an operator reads to answer "is there work?" — and it stayed that way for as long
# as the yield (up to the 24h clamp). #2040 removed the false CLAIM; this keeps the FACT #1909 needs
# visible by carrying the yield count through the funnel: `yields=<n>` plus, in words, that this is
# NOT "the fleet has nothing to do". The count is ADDITIVE — it is measured by this loop and is not
# one of the refresh's reconciled buckets — so it can never make an unreconciled funnel look summed.
dispatch_funnel() { # <dispatched_count> <queue_token> [<held_reason>] [<now_epoch>] [<yields>]
  local k="${1:-0}" qtok="${2:-?}" held="${3:-}" now="${4:-}" f key val kv backlog=0
  # The #1909 yield note. `<yields>` is the count THIS cycle yielded, and it is normalised first:
  # a non-numeric value must not reach a `[ ... -gt ... ]`, which would be FALSE and silently
  # UNDER-report the yields — the same fail-open shape the reader-side cases refuse.
  local yld="${5:-0}" ynote=""
  case "$yld" in ''|*[!0-9]*) yld=0 ;; esac
  if [ "$yld" -gt 0 ]; then
    ynote=" | yields=$yld (yielded to peers for capacity — this is NOT \"the fleet has nothing to do\"; they stay free for other boxes until their yield expires)"
  fi
  # ⛔ EVERY ONE OF THESE IS INITIALISED. They are assigned only when their key is present in the
  # record, and under `set -u` a declared-but-unassigned local is UNBOUND: a record missing one key
  # (a rename, a hand-edited or half-synced $O) exited the whole controller — a KeepAlive crash loop
  # on a record that persists. Measured in review round 2: `unj: unbound variable`, exit 1.
  local listed="" judged="" queued="" col="" land="" unj="" sk_ck="" sk_dp="" sk_ld="" sk_co="" notr="" at="" reconciled=""
  local age=""
  is_num "$now" || now="$(date +%s)"
  [ -f "$O/state/refresh-funnel" ] && f="$(cat "$O/state/refresh-funnel" 2>/dev/null || true)"
  for kv in ${f:-}; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      listed) listed="$val" ;; judged) judged="$val" ;; queued) queued="$val" ;;
      collision) col="$val" ;; landed) land="$val" ;; unjudged) unj="$val" ;;
      skipped_checked) sk_ck="$val" ;; skipped_dispatched) sk_dp="$val" ;;
      # ⛔ `skipped_landed` IS A KEY THE WRITER EMITS AND THIS READER DID NOT KNOW (review P2, cycle 3).
      # `refresh-candidates.sh` subtracts it from `not_reached` and records `reconciled=1` on the
      # strength of that subtraction, so the parts printed here summed to LESS than `listed` while the
      # line asserted reconciliation — measured: listed=20, parts summed 17, no UNRECONCILED marker
      # because the writer's own flag said 1. A record whose two halves disagree about its vocabulary
      # is the "the parts are unverified" case announced as verified.
      skipped_landed) sk_ld="$val" ;;
      # `skipped_collided` is the same lesson from main's side (#2124 / #2040 follow-up): a bucket the
      # writer subtracts from `not_reached` and emits. Both keys are INDEPENDENT and both are read —
      # a record predating either omits that part (no invented zero).
      skipped_collided) sk_co="$val" ;;
      not_reached) notr="$val" ;; at) at="$val" ;; reconciled) reconciled="$val" ;;
    esac
  done
  # The queue depth is measured HERE, not taken from the refresh's record: it is this cycle's file.
  [ -f "$O/candidates.txt" ] && backlog="$(wc -l < "$O/candidates.txt" | tr -d ' ')"
  is_num "${backlog:-}" || backlog=0
  if [ -z "${listed:-}" ]; then
    # No usable record. Say so — do NOT print a decomposition that does not exist, and do NOT fall
    # back to "backlog empty", which is the claim this function exists to stop. ⛔ The two causes are
    # distinguished (review round 5): asserting "no pass has recorded one yet" when the file EXISTS
    # but is empty/truncated is a false statement about our own state.
    if [ -f "$O/state/refresh-funnel" ]; then
      printf '[dispatch] %s queued of an UNRECORDED pool (state/refresh-funnel exists but is unreadable/empty) -> %s dispatched%s (queue=%s%s)\n' \
        "$backlog" "$k" "${held:+ | held: $held}" "$qtok" "$ynote"
    else
      printf '[dispatch] %s queued of an UNRECORDED pool (no state/refresh-funnel — no refresh pass has recorded its funnel yet) -> %s dispatched%s (queue=%s%s)\n' \
        "$backlog" "$k" "${held:+ | held: $held}" "$qtok" "$ynote"
    fi
    return 0
  fi
  # ⛔ AGE-BOUNDED, like every other record this loop reads (queue_state_token, gh_limit_token): a
  # record is not a state. The refresh exits BEFORE writing its funnel on the pool-read and
  # provisioning paths, so an old pass's decomposition can sit beside a NEWER `queue=READ(n)` in the
  # same line — internally inconsistent, and indistinguishable from a fresh one. Past the bound the
  # funnel is REPLACED by its age, never presented as this cycle's.
  # ⛔ AN UNPARSEABLE (or absent) `at` IS NOT "FRESH" (review round 3, finding 6). Skipping the age
  # test when the bound cannot be read made an arbitrarily old record print as THIS cycle's
  # decomposition — the same "a record is not a state" defect the age bound exists to end, reachable
  # by one missing field. Unknown age is bounded the only safe way: unverifiable is STALE.
  # ⛔ A FUTURE `at=` IS NOT A FRESH RECORD (review round 5). `age=$(( now - at )); [ age -lt 0 ] &&
  # age=0` turned a clock step-back into "funnel 0m old" with full counts — the very skew that
  # a stamp that cannot be verified refuses to serve. Unverifiable is STALE, so it takes the
  # unknown-age arm below.
  if is_num "${at:-}" && [ $(( 10#$at )) -le $(( 10#$now )) ]; then
    age=$(( (now - (10#$at)) / 60 )); [ "$age" -lt 0 ] && age=0
    if [ "$age" -gt "${FUNNEL_MAX_AGE_MIN:-30}" ]; then
      printf '[dispatch] funnel STALE(%sm > %sm) — the last recorded pass listed %s candidates; %s dispatched THIS cycle%s (backlog=%s, queue=%s%s)\n' \
        "$age" "${FUNNEL_MAX_AGE_MIN:-30}" "${listed:-?}" "$k" "${held:+ | held: $held}" "$backlog" "$qtok" "$ynote"
      return 0
    fi
  else
    printf '[dispatch] funnel STALE(age unknown — no usable `at=` in state/refresh-funnel) — the recorded pass listed %s candidates; %s dispatched THIS cycle%s (backlog=%s, queue=%s%s)\n' \
      "${listed:-?}" "$k" "${held:+ | held: $held}" "$backlog" "$qtok" "$ynote"
    return 0
  fi
  local -a parts
  parts=()
  is_num "$queued"   && parts+=("$queued queued")
  is_num "$col"      && parts+=("$col peer-owned (claim)")
  is_num "$land"     && parts+=("$land already landed")
  is_num "$unj"      && parts+=("$unj unjudged (pre-flight)")
  is_num "$sk_ck"    && parts+=("$sk_ck blacklisted (checked)")
  is_num "$sk_dp"    && parts+=("$sk_dp already dispatched")
  is_num "$sk_ld"    && parts+=("$sk_ld already landed (skipped)")
  # ⛔ PEER-HELD IS NOT "NOT REACHED" (review finding P2-1 for #2124). The refresh walks PAST a
  # candidate a recent pass recorded as peer-held, at no network cost. Until this bucket existed the
  # row was counted nowhere, so it landed in the DERIVED `not_reached` bucket and this function
  # printed it as `N not reached (limit)` — the one part that tells an operator to raise `LIMIT`,
  # asserted about a pass whose `limit=` is printed right beside it at its real value. A record that
  # predates this key simply omits the part (no invented zero), and an older reader ignores it.
  is_num "$sk_co"    && parts+=("$sk_co peer-held (ledger skip)")
  is_num "$notr"     && parts+=("$notr not reached (limit)")
  local joined="" p
  for p in ${parts[@]+"${parts[@]}"}; do joined="${joined:+$joined, }$p"; done
  # A record that does not add up is NOT printed as a clean decomposition: the parts names what
  # could go wrong, and an operator reading "the parts are fine" is exactly the failure this line
  # exists to prevent.
  # ⛔ ABSENT IS NOT "RECONCILED" (review round 3, finding 6). Only a writer that records
  # `reconciled=1` has shown the parts sum; a record with the field missing — an older pass, a
  # hand-edited file — proves nothing, and treating it as clean is a false PASS on the one line an
  # operator uses to decide whether the funnel is lying.
  case "${reconciled:-}" in
    1) : ;;
    0) joined="${joined:+$joined, }UNRECONCILED (the parts do not sum to the pool)" ;;
    *) joined="${joined:+$joined, }UNRECONCILED (no reconciliation recorded — the parts are unverified)" ;;
  esac
  printf '[dispatch] %s candidates -> %s -> %s dispatched%s (backlog=%s, queue=%s%s%s)\n' \
    "${listed:-?}" "${joined:-no reason recorded}" "$k" \
    "${held:+ | held: $held}" "$backlog" "$qtok" "${age:+, funnel ${age}m old}" "$ynote"
}

# ── the box's last gh RATE-LIMIT observation (#1988) ─────────────────────────────────────
# `queue_state_token` above says WHETHER this box could see the pool. This says WHY, when the answer
# is the shared GitHub bucket — the reason a `queue=UNREADABLE` cycle used to have none.
# Every harness gh call passes through `gh-limit.py` (the layer under the REST adapter and under the
# cell-side wrapper), which records the bucket the call was REFUSED on and the reset it observed.
# Those two facts are the ones gh's error text does not carry and `gh api rate_limit` actively
# misreports: measured, it read 4999/5000 on the REST counter while EVERY GraphQL call was refused,
# because the two pools are separate (#1762).
# ⛔ AGE-BOUNDED ON READ, because a record is not a state: a limit observed before the last 15
# minutes — or one stamped by a clock that has since stepped backwards — is not evidence about THIS
# cycle and is not printed. That is the "stale flag that records a past state and is never
# revalidated" failure, applied to the fix that reports it.
GH_LIMIT_STALE_S=900
gh_limit_token() {  # -> "gh=rate_limited(…)" | "gh=recovered(…)" | EMPTY
  local f rec kv at="" bucket="" reset="" rec_at="" now age
  f="${GH_LIMIT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gh-limit}/last-limit"
  [ -f "$f" ] || return 0
  rec="$(cat "$f" 2>/dev/null)" || return 0
  # The record is ONE line of `key=value` pairs with no spaces in any value, so word splitting is
  # the parse — no sed/jq spawn on a line printed every cycle.
  for kv in $rec; do
    case "$kv" in
      at=*)        at="${kv#at=}" ;;
      bucket=*)    bucket="${kv#bucket=}" ;;
      reset=*)     reset="${kv#reset=}" ;;
      recovered=*) rec_at="${kv#recovered=}" ;;
    esac
  done
  is_num "${at:-}" || return 0
  is_num "${reset:-}" || reset=""
  [ "${reset:-0}" = 0 ] && reset="?"
  now="$(date +%s)"; age=$(( now - at ))
  { [ "$age" -ge 0 ] && [ "$age" -le "$GH_LIMIT_STALE_S" ]; } || return 0
  # ⛔ A RECOVERED LIMIT IS NOT A CURRENT ONE. The record outlives the process that wrote it, so
  # without this a one-off limit kept the box asserting `gh=rate_limited(...)` for 15 minutes while
  # the same line showed a healthy queue — a token an operator learns to ignore. The layer marks the
  # record `recovered=<epoch>` on the first success after it (gh-limit.py record_recovery).
  if is_num "${rec_at:-}" && [ "$rec_at" -ge "$at" ]; then
    printf 'gh=recovered(bucket=%s %ss)' "${bucket:-?}" "$age"
    return 0
  fi
  printf 'gh=rate_limited(bucket=%s reset=%s %ss)' "${bucket:-?}" "$reset" "$age"
}
# "Is a worker with this name live?" — delegated to the ONE launcher (worker-terminal.sh), because the
# answer now has to cover a DURABLE TERMINAL as well as a tmux session, and two implementations of
# that question is how the caps and the guards drift apart.
# ⛔ THE EXACT-NAME RULE IS STILL THE POINT (`tmux has-session -t <name>` prefix-matches, so a guard
# for PR #82 reported "in flight" because `fix-820` existed and #82 starved); worker-terminal.sh
# matches workspace/session names exactly, and treats a worker it cannot MEASURE as alive (never the
# other way round — see its header on polarity).
sess() { wt_alive "${1:-}"; }
# ⛔ THE WORKER-SESSION SNAPSHOT IS GONE, WITH THE PREDICATE THAT NEEDED IT (2026-10-18). It existed
# so the per-PR ownership scan would not spawn a `tmux ls` per PR — and ownership no longer consults
# session names at all: a session name is a DECLARATION (a reviewer holds no branch, and a session
# outlives its work), which is exactly what made "21 running lanes" readable while none of them held
# a PR branch. The spawn guards still use `sess`/`claim_live`, unchanged; they answer "may I start
# another worker on this?", which is the question a session list is actually good for.
# (Removing it also removes one `tmux ls` per cycle.)
# Spawning an agent during a load spike makes the spike worse. A Mac reboot lands in an indexing
# storm (Spotlight, PerfPowerServices, duetexpertd) that the LANE dispatch gate already respects
# while the merge sweep did not — so a fresh boot got six reviewers piled onto it. The cheap actions
# (gh pr merge / ready / run rerun) stay ungated, so merges keep flowing while the spike passes.
# Nothing is starved: a held-back spawn retries next cycle, because the marker that authorises it
# (needsfix-<PR>-<head>, fixcount-<PR>) is only written on a SUCCESSFUL spawn.
can_spawn() { [ "${L:-0}" -lt "$MAX_LOAD" ]; }
# head_reds <pr> -> GREEN | RED | UNKNOWN
#
# ⛔ THE RAIL'S QUESTION, NOT THE REPO'S REQUIRED SET. `admin-merge.sh` refuses on a red tree measured
# over EVERY workflow and app, so a check outside this repo's required set can block a merge that the
# `FAILED:` arms below never see. This asks the rail's question — "is anything red here?" — and is
# used ONLY by the red-fixer role, to decide whether a stored refusal still describes the head.
#   GREEN   read, non-empty, every check non-red, and nothing in flight
#   RED     at least one completed check is red
#   UNKNOWN unreadable, empty, or something in flight — a miss is never a green
# The polarity is the same ALLOW-LIST the sweep's classifier and fix-one.sh use (#1714): a state this
# code has never seen is RED, never "not in the red set".
head_reds() {
  gh pr checks "$1" --repo "$OR" --json name,state 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNKNOWN"); raise SystemExit
if not isinstance(d, list) or not d:
    print("UNKNOWN"); raise SystemExit
INFLIGHT = ("queued", "in_progress", "waiting", "requested", "pending")
NONRED = ("success", "neutral", "skipped", "cancelled", "stale")
red = False; inflight = False
for c in d:
    if not isinstance(c, dict):
        continue
    st = str(c.get("state") or "").lower()
    if st in INFLIGHT:
        inflight = True
    elif st not in NONRED:
        red = True
print("RED" if red else ("UNKNOWN" if inflight else "GREEN"))
' 2>/dev/null
}

# ⛔ THE CONTROLLER'S PARK MUST CARRY ITS OWN REASON, IN THE SAME WRITE AS THE MARKER (#1717).
# `parkreason-<PR>` is what merge-one.sh's exit-5 refusal prints, and that log line is the ONLY
# in-band remedy on the chain-<N>/fix-one.sh paths (which never consult the controller). Before this,
# the controller wrote `parked-<PR>` at three sites and never touched the reason, so a park that
# replaced an earlier head's park -- a push moved the head, the controller later parked at the NEW
# head -- left the OLD head's reason beside it: the operator was told to "re-provision the recorder /
# re-record by hand" for a PR actually parked for an unrelated cause. Write the pair together,
# always, so a reason can never outlive the head it describes.
park_ctrl() { # park_ctrl <pr> <head> <reason…>
  printf '%s\n' "$3" > "$O/state/parkreason-$1"
  printf '%s\n' "$2" > "$O/state/parked-$1"
}

# Merge priority: while any UN-OWNED PR remains, the box's work is the PR queue, not new PRs.
# These functions hold the rule so it is directly testable (and so a regression cannot hide behind a
# comment):
#   mp_reason    -> the gate reason when draining should outrank dispatching (empty otherwise)
#   review_slots -> reviewer concurrency, with headroom once a backlog exists
#   fix_slots    -> fixer concurrency, the SAME headroom (see the note on fix_slots)
# ⛔ THE THRESHOLD IS GONE AND THAT IS THE FIX (owner ruling, 2026-10-18). This used to gate on
# `unowned > MERGE_PRIORITY_AT` (25 by default), i.e. FIFTY-SIX un-owned PRs blocked new work and
# twenty-five did not — and the measured box sat at exactly 25 with nothing working any of them while
# it opened more PRs from issues. The owner's rule has no threshold: while ONE un-owned PR remains,
# it is the work. MERGE_PRIORITY_AT keeps its other job (the reviewer/fixer headroom below), where it
# IS a backlog size rather than a licence to ignore the queue.
mp_reason() { # <unowned_prs> <lanes> <workers> [<open_prs>]
  # An UNREADABLE count is not permission to open work: it fails into the drain direction. The
  # caller already substitutes a fail-closed value before calling, and this guard keeps the rule
  # true for any other caller.
  if ! is_num "${1:-}"; then
    echo "merge-priority (un-owned PR count UNREADABLE — draining the PR queue before opening work)"
    return 0
  fi
  if [ "${1:-0}" -gt 0 ]; then
    echo "merge-priority (${1} un-owned of ${4:-${1}} open PR(s) — PRs before issues)"
  fi
}
mp_recent_land() { # [<state-dir>]
  # ⛔ THE WALK IS BOUNDED. `state/merged-<PR>.done` is never pruned — merge-one.sh only ever WRITES
  # them — so a long-lived box accumulates one per merged PR, forever, and the first form stat-ed
  # every one of them twice (GNU `file_mtime_epoch` tries `stat -c` then `stat -f`) on EVERY cycle.
  # Only a land inside 2x the gate's window can matter, so `find -mmin` shortlists and the loop stats
  # only those. A land older than that reads as "no recent land" — which is exactly the gate's own
  # question (a land outside the window releases anyway), and `[cap]`'s `last_land=` prints `?`.
  local d="${1:-$O/state}" f m newest="" bound list
  bound=$(( 10#${MERGE_PRIORITY_MAX_AGE_MIN:-180} * 2 ))
  list="$(find "$d" -maxdepth 1 -name 'merged-*.done' -mmin -"$bound" 2>/dev/null || true)"
  # A here-string, not `find … | while`: under `pipefail` the reader can exit first and make the
  # pipeline read FAILED (#841's class), and the process substitution would lose `newest` to a
  # subshell. `$list` is newline-delimited paths; IFS= read keeps spaces in a path intact.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(file_mtime_epoch "$f")" || continue
    if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then newest="$m"; fi
  done <<MPEOF
$list
MPEOF
  printf '%s\n' "$newest"
}
res_line() {
  local idle pmem f i w cmp avail swapfree swaptotal dline duse procs runnable svcs rate _sw
  # CPU
  local cpu; cpu="$(top -l 2 -n 0 2>/dev/null | awk '/CPU usage/{c=$0} END{sub(/^CPU usage: /,"",c); print c}')"
  # RAM (16 KiB pages on Apple silicon; compute from the header rather than hardcoding)
  pmem="$(vm_stat 2>/dev/null | awk '
    /page size of/ {ps=$8}
    /Pages free/ {gsub(/[.]/,"",$3); f=$3}
    /Pages inactive/ {gsub(/[.]/,"",$3); i=$3}
    /Pages wired/ {gsub(/[.]/,"",$4); w=$4}
    /occupied by compressor/ {gsub(/[.]/,"",$5); c=$5}
    END {if (ps=="") ps=16384; printf "%.2fG free/%.2fG inactive/%.2fG wired/%.2fG comp/%.2fG avail", f*ps/1e9, i*ps/1e9, w*ps/1e9, c*ps/1e9, (f+i)*ps/1e9}')"
  # swap + disk + processes (swap via the portable helper: a macOS-only probe logged '?' on a cell,
  # which is how the gate's absence stayed invisible in the logs — #1702)
  swapfree=""; swaptotal=""
  if _sw="$(swap_usage_mb)"; then swapfree="${_sw%% *}M"; swaptotal="${_sw##* }M"; fi
  # Disk: PORTABLE, and it must name the volume that ACTUALLY FILLS (#1765). The probe this replaces
  # hardcoded BOTH halves to macOS — the path `/System/Volumes/Data` and the `-g` (GiB) flag — so on a
  # Linux cell it printed nothing and every cycle logged `disk(?)`, which is how a filesystem reached
  # 100% with the resource line reading healthy. MEASURED on pi-lane-1, twice: `/dev/root 32G, 30G
  # used, 0 avail` with `disk(?)` in the log right up to it (2026-10-15), and again 2026-10-16 05:13Z
  # when the controller died writing its own log (`echo: write error: No space left on device`).
  # `df -Pk` is POSIX and its 4th column is 1KiB blocks on BOTH platforms, so the figure printed is
  # MEBIBYTES. The path is $REPO — the filesystem the checkout lives on is the one being filled, and
  # on macOS that resolves to the same data volume the old literal named, so this is equivalent there
  # and correct on a cell. An unreadable probe still prints `?` rather than a fabricated number: this
  # line is ADVISORY (the enforcing gate is spawn-gate.sh's disk gate), so unknown must read unknown.
  dline="$(df -Pk "${REPO:-/}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%dM free/%s used", int($4/1024), $5}')"
  procs="$(ps -Ao pid= 2>/dev/null | wc -l | tr -d ' ')"
  runnable="$(ps -Ao stat= 2>/dev/null | grep -c '^R')"
  # the macOS service sinks that have burned this box before, and kernel_task (thermal/I-O)
  svcs="$(ps -Ao pcpu=,comm= 2>/dev/null | awk '
    /opendirectoryd/ {o+=$1}
    /automountd/ {a+=$1}
    /kernel_task/ {k+=$1}
    /fseventsd/ {f+=$1}
    /mds_stores|mds$/ {m+=$1}
    END {printf "opendirectoryd=%.0f%% automountd=%.0f%% kernel_task=%.0f%% fseventsd=%.0f%% mds=%.0f%%", o,a,k,f,m}')"
  # GitHub API ceiling — a capacity limit that is NOT on this machine
  rate="$(gh api rate_limit --jq '.resources.graphql | "\(.remaining)/\(.limit)"' 2>/dev/null)"
  echo "[res] cpu(${cpu:-?}) | mem(${pmem:-?}) | swap(${swapfree:-?}/${swaptotal:-?}) | disk(${dline:-?}) | procs=$procs runnable=$runnable | svc(${svcs:-?}) | gh_gql=${rate:-?}" >> "$LOG"
}
review_slots() { # <unowned_prs>
  # ⛔ THE HEADROOM FOLLOWS THE GATE'S PREDICATE, NOT THE OLD SIZE THRESHOLD (review R2, P3). The gate
  # now blocks the issue path on ONE un-owned PR, so keeping this at `> MERGE_PRIORITY_AT (25)` meant a
  # 25-PR drain ran at the pre-change WIP — the shape the owner's rule 5 ("never cap lanes to a
  # trickle") is about. `is_num` first: a non-numeric count makes `[ … -gt … ]` ERROR (rc 2, FALSE) and
  # silently return the SMALLER budget — the "errored test is FALSE ⇒ permissive arm" pattern this file
  # guards everywhere else, here landing on the restrictive side.
  if is_num "${1:-}" && [ "${1:-0}" -gt 0 ]; then echo $(( 10#${MAX_REVIEW:-4} + 2 )); else echo "${MAX_REVIEW:-4}"; fi
}
# ⛔ DRAIN MODE MUST RAISE THE FIXER BUDGET TOO (measured 2026-10-16). Only review_slots had
# headroom, so a backlog of DIRTY/BEHIND PRs — 17 of 20 open on the live cells — sent the extra
# capacity at REVIEWERS while every spawn site below still compared against the unraised MAX_FIX.
# That is backwards: a DIRTY PR needs a fixer, and a review that is never done also lands on the
# fixer path. Same shape as review_slots, same threshold, same base-10 normalisation (a leading
# zero would otherwise be read as OCTAL by `$(( ))`).
fix_slots() { # <unowned_prs>
  # Same predicate as review_slots and as the gate (see the note there).
  if is_num "${1:-}" && [ "${1:-0}" -gt 0 ]; then echo $(( 10#${MAX_FIX:-3} + 2 )); else echo "${MAX_FIX:-3}"; fi
}

# ── CAPACITY TRANSFER (agent-infra#1909, R8) ────────────────────────────────
# `lane.sh` writes `state/capacity-refused-<N>` when the spawn gate refuses an issue for capacity.
# Format: `<refused_epoch>\t<yield_until>\t<gate>` — the writer in lane.sh is the ONE definition.
#
# WHY THIS BOX MUST STAND DOWN, NOT JUST RELEASE. `chain-merge.sh` releasing the cross-box claim is
# what makes the issue ELIGIBLE on a peer; it is not what makes the peer WIN it. The claim is an
# atomic CAS, and this box is the one that just took it — so on the very next cycle a saturated
# box can re-win the CAS against a healthy peer and be refused again, indefinitely, and the peer
# never gets the issue. The yield is the missing half: while it is live, this box skips the issue
# and leaves it UNCONSUMED (no `dispatched.txt` row, no claim), so it stays a candidate here AND a
# free issue for every peer. When the yield expires — or the box quietens and this box is again the
# fastest to claim it — the ordinary path resumes.
#
# ⛔ FAIL-OPEN, AND IT MUST BE. A missing, empty, garbled, or wrong-shaped record is NOT a yield:
# treating an unreadable file as one would suppress dispatch — the fleet-side idleness R8 exists to
# remove, reintroduced by a corrupt byte. Absent evidence means "dispatch normally".
# Sets CAPACITY_YIELD_WHY for the caller's log line (empty when it returns 1).
CAPACITY_YIELD_WHY=""
capacity_yield_live() { # <issue> -> 0 = this box yielded it (skip, do not consume), 1 = dispatch
  local n="${1:-}" f ep until gate now
  CAPACITY_YIELD_WHY=""
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  f="$O/state/capacity-refused-$n"
  [ -r "$f" ] || return 1
  read -r ep until gate < "$f" 2>/dev/null || return 1
  case "${ep:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${until:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#until}" -le 18 ] || return 1
  now="$(date +%s)"
  [ "$now" -lt "$until" ] || return 1
  # ⛔ THE EPOCH IS BOUNDED TOO, for the same reason the await side bounds it: a record whose
  # `until` is far in the future but whose `refused_epoch` is nonsense is not evidence of a live
  # yield, and `until - ep` is the window the writer used. Accept only a coherent pair.
  [ "$until" -gt "$ep" ] || return 1
  CAPACITY_YIELD_WHY="gate=${gate:-?} until=$until ($(( until - now ))s left)"
  return 0
}

# ── rate-limit-aware conditional listing (agent-infra#1762) ─────────────────────
# The sweep re-listed every open PR every cycle and then read each one twice more, all over
# GraphQL. That budget is 5,000 POINTS/hr per USER and is shared by every cell, lane and box acting
# as the account, so two cells cross it; when it goes, EVERY `gh pr` call fails while
# `gh api rate_limit` still reports `graphql 4933/5000`, and the sweep logs one
# `nothing swept this cycle` line next to a healthy `[scope] open=N`. A cell that cannot list PRs
# cannot merge, and it read as idle-but-fine.
#
# Two mechanisms from GitHub's own REST best-practice page replace that:
#   * a CONDITIONAL listing — `If-None-Match: <etag>`; a 304 means the list is unchanged and GitHub
#     does not charge a 304 to the primary rate limit, so the sweep's listing is free;
#   * the RESPONSE HEADERS as the health signal — `x-ratelimit-remaining` / `-reset` / `Retry-After`
#     — instead of polling `/rate_limit`, which the docs explicitly say not to trust and which was
#     measured reporting 4933 remaining while every call failed (#1762). This governs the DEFERRAL
#     DECISION only. The `[res]` line still prints a `/rate_limit` counter (`res_line`, advisory and
#     deliberately not read for this decision) — do not read a healthy `gh_gql=` there as "the sweep
#     can list PRs".
# The listing moves to REST (`gh api`) because conditional requests are a REST feature — GraphQL has
# no ETag — and `resources.core` is a SEPARATE 5,000/hr bucket from the GraphQL one the per-PR reads
# below still spend. Those per-PR reads stay on GraphQL — moving them to REST is the issue's own
# direction 1 / research item 4 and is NOT this PR — but a 304 SKIPS them for that cycle (an
# identical list means an identical PR set). "Unchanged" therefore means "not moved to REST", never
# "run every cycle": the skip is bounded by SWEEP_MAX_AGE, which drops `If-None-Match` once the
# cached listing ages out.
#
# BEGIN sweep-quota (sweep-quota.test.sh extracts this block verbatim — keep it self-contained)
# rl_header <name>: the value of one HTTP header in a raw `gh api --include` response, or empty.
# Header NAMES are case-insensitive (HTTP/1.1) and the CRLF terminator is stripped. `--paginate -i`
# repeats the header block once per page; the FIRST match (page 1) is returned, which is the page the
# conditional header was sent on and therefore the one the deferral decision is about.
rl_header() {
  local want; want="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
  tr -d '\r' | awk -v want="$want" '
    {
      c = index($0, ":")
      if (c == 0) next
      if (tolower(substr($0, 1, c - 1)) != want) next
      v = substr($0, c + 1)
      # Trim HTTP optional whitespace by character test, not a regex class: one-true-awk (the macOS
      # default) does not reliably honour `\t` inside a bracket expression.
      while (substr(v,1,1) == " " || substr(v,1,1) == "\t") v = substr(v, 2)
      print v; exit
    }'
}
# rl_status: the HTTP status of a raw `gh api --include` response ("HTTP/2.0 200 OK" on line 1).
rl_status() {
  awk 'NR == 1 { if (match($0, / [0-9][0-9][0-9]/)) { print substr($0, RSTART + 1, 3); exit } }'
}
# sweep_fail_kind <raw-response> <stderr> -> rate-limit | network | other.
# A rate-limit failure and a network failure are NOT the same event: the first means the shared
# budget is spent (wait for the reset, then retry), the second means the link (retry at once).
# Reading them as one is what made a cell that cannot merge indistinguishable from an idle one.
# A `304` never reaches here — the caller tests the status first.
sweep_fail_kind() {
  local raw="${1:-}" err="${2:-}"
  # ⛔ NOT `HTTP 4(29|03)`. A bare 403 is how a PERMISSION/SCOPE failure arrives — an expired or
  # under-scoped token, SSO, admin rights ("gh: Resource not accessible by integration (HTTP 403)")
  # — and it carries no rate-limit header, because there was no rate limit. Matching 403 here
  # classified such a failure as `rate-limit`, deferred the sweep for up to an hour, and logged
  # `RATE-LIMITED ... CANNOT MERGE` over a stderr line that says otherwise: the same "instrument
  # reports the opposite of the truth" defect this block exists to remove. A 429 is unambiguous; a 403
  # must CORROBORATE the limit via a header or one of the named phrases, and otherwise falls through
  # to `other`, where the real stderr reaches the operator.
  if [ "$(printf '%s\n' "$raw" | rl_header 'x-ratelimit-remaining')" = "0" ] \
     || [ -n "$(printf '%s\n' "$raw" | rl_header 'retry-after')" ] \
     || grep -qiE 'rate limit|abuse detection|secondary rate|HTTP 429' <<<"$err" ; then
    echo rate-limit
  elif grep -qiE 'timeout|timed out|TLS|tls:|dial|connection|no such host|network|EOF|reset by peer|refused' <<<"$err" ; then
    echo network
  else
    echo other
  fi
}
# sweep_defer_until <raw-response> -> epoch seconds to defer the sweep until.
# Honours `Retry-After` (seconds) and `x-ratelimit-reset` (epoch), takes the LATER, and floors/ceils
# it to [now+60, now+3600]: a missing or absurd reset must not become either a hot retry loop or a
# multi-day stall.
sweep_defer_until() {
  local raw="${1:-}" now ra reset cand=0
  now="$(date +%s)"
  ra="$(printf '%s\n' "$raw" | rl_header 'retry-after')"
  is_num "${ra:-}" || ra=""
  reset="$(printf '%s\n' "$raw" | rl_header 'x-ratelimit-reset')"
  is_num "${reset:-}" || reset=""
  [ -n "$ra" ] && cand=$(( now + ra ))
  if [ -n "$reset" ] && [ "$reset" -gt "$cand" ]; then cand="$reset"; fi
  [ "$cand" -lt $(( now + 60 )) ]   && cand=$(( now + 60 ))
  [ "$cand" -gt $(( now + 3600 )) ] && cand=$(( now + 3600 ))
  printf '%s\n' "$cand"
}
# END sweep-quota

# Count of open PRs. This number drives the SCOPE decision (BROAD drain vs OWN) and the sticky
# fallback, and its `number:headOid` rows feed the ownership scan (unowned_pr_count -> pr_owned)
# whose result is what the reviewer budget (review_slots), the fixer budget (fix_slots) and the
# merge-priority gate (mp_reason) actually consume. So a FAILED count must
# never be readable as "the queue is empty". The pre-fix line was
#   OPEN_N="$(gh pr list … 2>/dev/null)"; : "${OPEN_N:=0}"
# which discarded rc AND stderr, then coerced the empty result to 0: on 2026-10-12 a single
# `Post "https://api.github.com/graphql": net/http: TLS handshake timeout` logged
# `[scope] open=25 -> BROAD` then `[scope] open=0 -> OWN` in one cycle while 22 PRs were open —
# silently dropping the drain, the reviewer headroom and the merge-priority gate. A failure is now
# a DISTINCT, LOGGED 'unknown': rc is captured on its own line, gh's stderr is kept, and the count
# falls back to the sticky last-known value in state/last-open-n (26 on a first-ever failure ->
# BROAD, because resuming a drain is idempotent while opening more lanes is not). It never
# assigns 0. The listing's `number:headOid` rows go to state/last-open-prs for the ownership scan.
open_pr_count() { # -> echoes the open-PR count; never 0 on failure; writes state/last-open-prs
  local raw rc err sticky fc n prs
  # `if …; then` rather than `raw=$(…); rc=$?` so this stays correct if errexit is ever enabled —
  # under `set -e` the bare assignment would exit the loop BEFORE rc was read, on a transient blip.
  # ONE listing, TWO facts: the count (drives scope + the sticky fallback) and the
  # `number:headOid:BranchRef` rows (drive unowned_pr_count below). `--jq` emits a SINGLE line —
  # `<count> <pr:sha:branch> <pr:sha:branch>` — so the split is positional and a variable-length
  # list cannot confuse it; an empty list is `0 ` (jq still prints the count), which the parse below
  # reads as count=0, rows=none.
  # ⛔ THE BRANCH TRAVELS WITH THE ROW BECAUSE OWNERSHIP IS A LIVE FACT PER PR (2026-10-18). The
  # predicate is "a running process's cwd is a checkout of this PR's head ref", so the head ref has
  # to be in the row. A git ref cannot contain ':', so ':' stays an unambiguous separator.
  if raw="$(gh pr list --repo "$OR" --state open --limit 300 \
             --json number,headRefOid,headRefName \
             --jq '"\(length) \(map("\(.number):\(.headRefOid):\(.headRefName)") | join(" "))"' \
             2>"$O/state/.open-err.$$")"; then
    rc=0
  else
    rc=$?
  fi
  err="$(tr '\n' ' ' < "$O/state/.open-err.$$" 2>/dev/null || true)"
  rm -f "$O/state/.open-err.$$"
  # Split on the FIRST run of whitespace: the count is the first field, every row follows it. When
  # the listing carried no row at all (a stub, or a genuinely empty queue) there is no space and
  # the whole value IS the count — so the rows become empty rather than a copy of the count.
  n="${raw%%[[:space:]]*}"; prs="${raw#*[[:space:]]}"
  [ "$n" = "$raw" ] && prs=""
  if [ "$rc" -ne 0 ] || ! is_num "$n"; then
    sticky="$(cat "$O/state/last-open-n" 2>/dev/null || true)"
    # ⛔ A sticky 0 is NOT reused. A drained queue (last success = 0) is exactly when new PRs are
    # most likely to have arrived before this failure, and returning 0 drives the UNSAFE direction:
    # OWN scope, no reviewer headroom, no merge-priority gate. Reuse only a POSITIVE last-known;
    # absent / 0 / non-numeric assumes a count ABOVE the fallback threshold, because resuming a
    # drain is idempotent while opening more lanes is not. THIS is what "never 0 on failure" means.
    # The fallback must exceed BOTH the merge-priority tunable AND the scope gate's threshold (a
    # literal 10 below), so it is max(MERGE_PRIORITY_AT, 10) + 1 — keying it to the tunable alone
    # left a below-default tunable landing in OWN, the unsafe direction, on a failed count.
    # ⛔ The DEFAULT literal here is the shipped MERGE_PRIORITY_AT default (25), NOT the scope
    # literal: with an unset/non-numeric tunable the assumption must still land ABOVE whatever the
    # loop would have coerced the tunable to, or a failed count would OPEN the gate (the unsafe
    # direction this comment forbids). The `-ge 10` floor stays keyed to the SCOPE threshold, which
    # is the other bound the fallback has to clear.
    # ⛔ Normalize to base 10 BEFORE the arithmetic: `[ … -ge … ]` parses base 10 but `$(( … ))`
    # parses base 0, where a leading 0 is OCTAL — so a tunable of `010` passed the guard as "ten"
    # and then evaluated as 8, returning 9 and landing in OWN again. Reject non-digits, then force
    # base 10 with `10#`.
    fc="${MERGE_PRIORITY_AT:-25}"
    case "$fc" in ''|*[!0-9]*) fc=25 ;; esac
    [ "$fc" -ge 10 ] || fc=10
    fc=$(( 10#$fc + 1 ))
    # ⛔ The row file must NOT survive the failure path. It is the OTHER half of one listing, so a
    # previous cycle's rows paired with this cycle's fallback count would silently UNDER-count the
    # unowned set (the rows are a different moment than the count). Absent rows make
    # unowned_pr_count assume NOTHING is owned — the conservative direction.
    rm -f "$O/state/last-open-prs"
    if is_num "$sticky" && [ "$sticky" -gt 0 ]; then
      echo "[scope] open=UNKNOWN rc=$rc (${err:-no stderr}) -> sticky last-known=$sticky" >> "$LOG"
      echo "$sticky"
    else
      echo "[scope] open=UNKNOWN rc=$rc (${err:-no stderr}) -> no positive last-known (sticky='${sticky:-none}'), assuming $fc (BROAD)" >> "$LOG"
      echo "$fc"
    fi
    return 0
  fi
  printf '%s\n' "$n" > "$O/state/last-open-n"
  printf '%s\n' "$prs" > "$O/state/last-open-prs"
  echo "$n"
}

# ── ownership: what the merge-priority gate actually counts ─────────────────────
# ⛔ OWNERSHIP IS A LIVE FACT (owner ruling, 2026-10-18). A PR is owned when SOME RUNNING PROCESS is
# working it — its cwd is a checkout of the PR's head ref, or a worktree whose PATH carries the PR
# number — or when another BOX holds a live claim on it (the one thing a local probe cannot see).
# Everything else that used to count here is a DECLARATION ABOUT THE PAST:
#   • a `fix-<PR>` / `merge-<PR>` tmux SESSION NAME — a reviewer reads the PR through `gh` and holds
#     no branch, and a session can outlive (or postdate) the work;
#   • a `needsfix-<PR>-<head>` marker — that marker AUTHORISES a spawn, it does not prove one ran;
#   • a LOCAL claim ref whose holder died — the lease outlives the process by design.
# MEASURED, and the reason for the rewrite: pr-doctor reported 21 "running" lanes while a live-cwd
# scan found NONE of them holding a PR branch; 25 open PRs, 0 owned, and the box kept opening NEW PRs
# from issues because the gate keyed on an open-PR COUNT (MERGE_PRIORITY_AT) instead of on ownership.
# A stale declaration counting as ownership is exactly that bug in the other direction.
#
# ⚠️ Two residuals, stated rather than hidden:
#   1. A REVIEWER in flight holds no branch, so its PR reads UN-OWNED. That over-counts the work
#      queue — the safe direction for this rule (take on MORE PR work, never less) — and the spawn
#      arms below still refuse to double-work a PR (`sess`/`claim_live` guards, unchanged).
#   2. A cross-box claim is a DECLARED WINDOW, NOT LIVENESS — claims.sh is explicit ("LEASE = DATA,
#      NOT LIVENESS"): git refs have no TTL and a remote pid cannot be probed, so a foreign claim is
#      the strongest evidence that can exist for a remote holder. A LOCAL claim with no live process
#      is NOT counted (that is the defect this rewrite removes).
#      ⛔ AND THE LEASE IS THE BOUND ONLY FOR A CLAIM THIS BOX CANNOT CLASSIFY (agent-infra#2094).
#      `claim_foreign_live` below also asks `claim_orphan_reason`, so an orphaned PR claim (this
#      box's own FORMER host name, a host on CLAIM_DEAD_HOSTS, a host absent from a current
#      CLAIM_KNOWN_HOSTS roster, or a local pid that is gone) does NOT read as owned. What still reads
#      as owned until its lease expires is a claim from a host none of those rules can judge: an
#      unknown name with no roster. That is an UNDER-count of orphanhood on purpose; the over-count
#      direction steals a live peer's work.
pr_owned() { # <pr> <head-sha> [<head-ref>] -> 0 when something is currently working this PR
  local pr="$1" sha="${2:-}" br="${3:-}"
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  # 1. THE LIVE FACT. `lo_pr_owned` reads the once-per-cycle snapshot of every visible process's
  #    cwd; an unavailable module (LO_SCAN=0) or a row with no branch falls through to the arms below.
  if [ "${LO_SCAN:-0}" = "1" ] && [ -n "${br:-}" ] && lo_pr_owned "$LO_LIVE" "$pr" "$br"; then return 0; fi
  # 2. A LIVE LOCAL LOCK (the merge worker's own pid file) — a live fact, BOUND TO THE WORKER.
  local f="$O/state/mergeclaim-$pr.lock" p _pcl
  if [ -f "$f" ]; then
    p="$(cat "$f" 2>/dev/null || echo 0)"
    if [ "${p:-0}" -gt 0 ] && kill -0 "$p" 2>/dev/null; then
      # ⛔ A LIVE PID IS NOT A PROCESS WORKING THIS PR (review R1, P1). merge-one.sh writes nothing but
      # `$$`, so once pids recycle the lock reads LIVE for ever — and the PR is then excluded from the
      # un-owned queue permanently: this change's failure mode, in the dangerous direction, and
      # self-reinforcing (the controller never spawns the worker that would delete the lock).
      # Bind the pid to its COMMAND LINE (one fork, and only when a lock file exists): it must BE the
      # merge worker, and it must name THIS PR.
      # ⛔ TWO SPAWN FORMS, BOTH LOAD-BEARING (review R2, P2). The controller's own rail path spawns
      # `bash merge-one.sh --argv state/argv-<PR>` — the number appears only inside a FILENAME — while
      # `chain-merge.sh`/`fix-one.sh` pass it positionally. Matching only the positional form made a
      # genuinely live merge worker read UN-OWNED for its whole run (safe direction, but it inflated
      # the un-owned count the owner audits, and the arm was dead on the primary path).
      _pcl="$(ps -o command= -p "$p" 2>/dev/null)"
      case "$_pcl" in
        *merge-one*|*dispatch-merge*)
          case " $_pcl " in
            *" $pr "*) return 0 ;;
            *"/argv-$pr "*) return 0 ;;
          esac ;;
      esac
    fi
  fi
  # 3. A LIVE CLAIM HELD BY ANOTHER BOX. Unobservable locally; the lease is all there is.
  if [ -n "$sha" ] && claim_foreign_live "$pr" "$sha"; then return 0; fi
  return 1
}

# claim_foreign_live <pr> <head-sha> -> 0 when a LIVE claim on that head is held by ANOTHER BOX.
# ⛔ A claim held by THIS box is NOT covered here: its liveness must be proven by a live process
# (arms 1-2 above), never by the lease it wrote. `claim_live` remains the SPAWN guard — it answers
# "may I work this?", which is the conservative question; this answers "is someone already working
# it?", which is the selection question. Two questions, two predicates, deliberately.
claim_foreign_live() {
  local pr="$1" sha="${2:-}" ref owner host f p
  [ -n "$sha" ] || return 1
  [ -f "$O/state/claims-snapshot" ] || return 1
  if command -v claim_ref >/dev/null 2>&1; then ref="$(claim_ref "$pr" "$sha")"; else ref="refs/claims/$pr-${sha:0:12}"; fi
  [ -n "$ref" ] || return 1
  owner="$(awk -F'\t' -v r="$ref" '$1==r{print $2; exit}' "$O/state/claims-snapshot" 2>/dev/null)"
  [ -n "${owner:-}" ] || return 1
  host="${owner%%:*}"
  [ "$host" != "$(_this_host)" ] || return 1
  # ⛔ AN ORPHANED HOLDER IS NOT OWNERSHIP (agent-infra#2094) — AND THAT RULE IS INHERITED, NOT
  # DUPLICATED (cycle-17 review). `pr_owned` reads ownership through THIS function, which ends in the
  # ONE lease reader, `claim_lease_live`; #2094 put the `claim_orphan_reason` consult there, so a renamed
  # box's own PR claim stops reading as owned and the PR re-enters the un-owned queue (measured in the
  # incident: `backlog empty queue=READ(192)` — the ISSUE path self-healed because it asked, the PR
  # path did not). A second consult HERE would be dead code: removing it changed no assertion in any
  # suite, which is exactly how a duplicate guard is supposed to fail its own mutation test. Keep the
  # rule in the reader every path shares.
  # ⛔ THE LEASE ALONE DECIDES — NEVER `claim_live` (review R2, P1). `claim_live` is the SPAWN GUARD and
  # its first arm is a deliberately-loose local-lock pid test; delegating ownership to it let a STALE
  # `mergeclaim-<pr>.lock` whose pid had been recycled make even an EXPIRED foreign lease read live, so
  # a PR left the un-owned queue for ever — the dangerous direction, reached through the cross-box arm
  # after arm 2 was already fixed. One lease reader, no lock arm.
  claim_lease_live "$pr" "$sha"
}
# ⛔ THE FLEET-WIDE `box` SENTINEL IS NOT AN IDENTITY HERE EITHER (cycle-21 review). Falling back to
# the literal `box` made a probe-blind box read EVERY peer's `box:<pid>` claim as its OWN — the
# comparison is `[ "$host" != "$(_this_host)" ]` — so `claim_foreign_live` returned "not foreign" and
# `pr_owned()` dropped that PR out of the owned set: the sweep then spawned for it every cycle and
# `claim_acquire` refused (where `box` IS correctly not an identity). Not a steal (nothing is deleted),
# but the churn the live-ownership rewrite exists to remove. An unanswerable name now prints NOTHING,
# so `[ "$host" != "$(_this_host)" ]` STAYS TRUE (a non-empty `$host` is unequal to the empty string),
# the guard does NOT fire, and the claim falls through to `claim_lease_live` — the same "the lease
# decides" answer every genuinely foreign holder gets. (Cycle-22 correction: the first version of this
# comment said "the `!=` test then fails and the guard abstains", which is the opposite polarity among
# `!=` + `|| return 1` and would have read as correct to anyone not tracing the operator.)
_this_host() { local h; h="$(hostname -s 2>/dev/null)"; case "$h" in ''|box) return 1 ;; esac; printf '%s' "$h"; }

# How many OPEN PRs nothing is currently working. <open_prs>
unowned_pr_count() {
  local n="${1:-}" out
  # ⛔ A malformed count must FAIL CLOSED, and failing closed here means EMIT NOTHING — never a
  # number. The first draft coerced it to 0, which is the most permissive value the gate can be
  # handed AND a perfectly valid one, so the caller's guard could not see it and the gate OPENED on
  # a count that was never read (measured). An empty result falls through to the caller's total-open
  # fallback, the conservative direction.
  # ⛔ `is_num`, NOT a `case … [0-9]` digit test: the case pattern ACCEPTS a leading zero, which
  # `$(( ))` then parses in BASE 0 — `08` made the arithmetic below ERROR, `u` came out empty, the
  # caller substituted its own `08`, and `[ 08 -gt 25 ]` read 8 and OPENED the gate. is_num rejects
  # leading zeros (and everything non-numeric) on purpose.
  is_num "$n" || return 1
  out="$(unowned_scan "$n")" || return 1
  printf '%s\n' "${out%% *}"
}

# ── ONE scan, ONE parser, ONE fact: the unowned COUNT (a youngest-PR age lived here once, #2040; see
# below) ────────────────────────────────────────────────────────────────────────────────────────
# `unowned_pr_count` and the merge-priority age probe read the SAME rows, so they must read them the
# SAME way. The first draft of the age probe re-parsed the token and the two disagreed about the
# head — a bug that presented as one PR being counted unowned while its age was read from another
# (measured in review: a 3-field token `number:sha:epoch` left `sha="<sha>:<epoch>"` in the count,
# so every `needsfix-<pr>-<head>` marker stopped matching and EVERY PR read as unowned — inflating
# the very number the gate blocks on). One function, one answer.
#
# Row format: `number:headOid:headRefName`. (An earlier version of this comment said the third field
# was a `createdEpoch` — it never was. The writer is `open_pr_count`'s jq triple
# `number,headRefOid,headRefName` and BOTH readers treat field 3 as a BRANCH; the epoch an age probe
# would want is not in this row at all.) TWO fields is the older on-disk format and is still accepted
# (an aged `state/last-open-prs` must not be misread); the third is absent there.
#
# Echoes `<unowned>`. ⛔ IT DOES NOT RETURN A YOUNGEST-AGE ANY MORE, AND NO AGE MAY DECIDE ANYTHING.
# This comment used to describe an age probe whose unreadable answer let the gate through — that arm
# was removed with the rest of the release valve (#2099, owner ruling 2026-10-18). `mp_reason` holds on
# any un-owned PR, full stop; a missing row file cannot lower it (see the POLARITY note below).
# ⚠️ POLARITY, ONCE (review, #2040). No rows => NOTHING is known to be owned, so the whole count reads
# as unowned: more unowned CLOSES the gate, which is the conservative direction for `unowned`,
# `review_slots` and `fix_slots`. The fallback above remains because it is what the LOG and the budgets
# report — and since the gate is NOT evidence-bounded, an unreadable listing keeps dispatch SHUT. That
# is the fail-closed direction, and it is why a cell whose listing is broken idles instead of minting
# PRs: the fix for that is to restore the listing, or to name the PRs with no rows (agent-infra#2126).
unowned_scan() { # <open_prs>
  local n="${1:-}" list tok pr rest sha br owned=0 u
  is_num "$n" || return 1
  list="$(cat "$O/state/last-open-prs" 2>/dev/null || true)"
  # No rows => assume NOTHING is owned, i.e. the whole count is unowned. That is the CONSERVATIVE
  # direction here: an un-owned PR means "work the queue", and assuming they were owned would OPEN
  # the issue path on a listing we could not read — the fail-open this file's is_limit discipline
  # exists to prevent, and it is what the `rm -f` on open_pr_count's failure path guarantees here.
  [ -n "${list// /}" ] || { echo "$n"; return 0; }
  for tok in $list; do
    pr="${tok%%:*}"; rest="${tok#*:}"; sha="${rest%%:*}"; br="${rest#*:}"
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    [ "$br" = "$sha" ] && br=""   # a legacy two-field row: no branch, so only the local arms apply
    if pr_owned "$pr" "$sha" "$br"; then owned=$(( owned + 1 )); fi
  done
  # An owned count ABOVE the listing's (a race between the two reads) collapses to 0, never to a
  # negative that `[ -gt ]` would read as "not over the threshold".
  # `10#` is belt-and-braces, NOT independently test-covered: `is_num` above already rejects the
  # leading zero this would normalise (mutation-tested — removing it leaves the suite green). It
  # stays for consistency with every other arithmetic read of a tunable in this file, so the
  # function is correct even if the guard is ever loosened.
  u=$(( 10#$n - owned ))
  [ "$u" -lt 0 ] && u=0
  printf '%s\n' "$u"
}

while true; do
  heartbeat
  res_line   # MEASURE every resource; decide nothing from it
  reap_stale_workers
  # ⛔ THE LATCH IS RELEASED HERE, ONCE PER ITERATION — NOT AT LOAD. `_HR_DONE` starts at 0 and the
  # function sets it on entry, so a per-PROCESS latch would refresh once in the controller's whole
  # lifetime and then return early forever: every later cycle keeps the first cycle's token (empty on a
  # box that started current), a box that falls behind afterwards is spawned silently, and
  # `state/harness-refresh` stops being rewritten. That is the exact failure this block exists to end,
  # so the reset belongs at the call site — the guard still catches a SECOND call in the same cycle.
  _HR_DONE=0
  harness_refresh_cycle   # re-pin / refuse / name a stale checkout; sets HARNESS_TOKEN
  L="$(load1)"
  # Read the gh-limit record ONCE per cycle; the token is age-bounded inside (see gh_limit_token).
  GHL="$(gh_limit_token)"
  echo "=== $(date) load=$L lanes=$(wt_count lane-) backlog=$(wc -l < "$O/candidates.txt" | tr -d ' ') queue=$(queue_state_token)${GHL:+ $GHL}${HARNESS_TOKEN:+ harness=$HARNESS_TOKEN} ===" >> "$LOG"

  # ---- 1) merge sweep (this box's open PRs) -------------------------------
  # scope: when the repo has >10 open PRs, help drain EVERYONE's (broad); otherwise just this box's.
  # FAILED counts are 'unknown', never 0 — see open_pr_count() above.
  OPEN_N="$(open_pr_count)"
  # NOTE: the merge-priority gate's own inputs — the unowned count and the reviewer/fixer budgets —
  # are derived BELOW, right after the cross-box claim snapshot is refreshed. pr_owned() reads that
  # snapshot (via claim_live), so running the scan HERE read the PREVIOUS cycle's file: the same
  # predicate gave the gate and the sweep different answers for the same PR within one cycle.
  # Scope: >10 open PRs -> BROAD (help drain everyone's). Our OWN patterns are always included
  # even while drafts, because a draft is invisible to the checks below and nothing else would
  # ever ready it — our lanes' own drafts used to stall red forever (#8219, #8085).
  #
  # BEGIN scope-select (selftest.sh extracts this block verbatim — keep it self-contained)
  # SCOPE pins this box's drain scope: `auto` (DEFAULT — the >10 count rule above, unchanged),
  # `own` (own-only regardless of the count), or `broad` (broad regardless of the count). Any
  # other value — including set-but-EMPTY — is FATAL operator config: a typo (or a blank plist /
  # keys.env entry) must not silently pick a scope, because the wrong scope either drains someone
  # else's queue or strands this box's own drafts. Exactly one machine in a fleet takes BROAD;
  # every other machine pins `SCOPE=own`.
  # ⛔ This is a PARTITION, not a fix for the root. Pinning a second machine to OWN stops it
  # taking BROAD and draining the SHARED queue (measured 2026-10-13: a freshly started cloud cell
  # logged `[scope] open=14 -> BROAD` and was re-recording and auto-arming merges — #8425, #8420 —
  # within ~25s, on the same queue the local orchestrator was working). It does NOT make ownership
  # knowable: the collision pre-flight infers ownership from LOCAL branches/worktrees, which are
  # invisible across machines (#4256), so two OWN-pinned boxes can still race the same PR. The
  # root fix is #5052 (an authoritative expiring claim registry) — do not mistake this pin for it.
  if [ -z "${SCOPE+x}" ]; then SCOPE=auto; fi
  case "$SCOPE" in
    auto)
      if [ "$OPEN_N" -gt 10 ]; then SCOPE_MODE=BROAD; else SCOPE_MODE=OWN; fi
      SCOPE_WHY=auto ;;
    own)   SCOPE_MODE=OWN;   SCOPE_WHY="pinned SCOPE=own" ;;
    broad) SCOPE_MODE=BROAD; SCOPE_WHY="pinned SCOPE=broad" ;;
    *)     echo "[fatal] SCOPE must be auto|own|broad (got '$SCOPE')" >&2; exit 1 ;;
  esac
  if [ "$SCOPE_MODE" = BROAD ]; then
    SEL='select(.headRefName|test("^design/|^scope/|^dependabot/")|not)'
  else
    SEL='select(.headRefName|test("-tm$|-cap$|^fix/"))'
  fi
  echo "[scope] open=$OPEN_N -> $SCOPE_MODE ($SCOPE_WHY)" >> "$LOG"
  # END scope-select
  # ── repo authority for THIS cycle (agent-infra#1764) ────────────────────────
  # Resolved per cycle: branch protection can change while the controller runs. With REQ already set
  # in the environment the RESOLVER costs no gh call (it short-circuits on REQ_OVERRIDE), but the
  # authority-flip DETECTOR below does re-read branch protection on the cycles where an override is
  # active (review round 7 — the earlier comment claimed zero gh calls and was wrong). The required
  # set is the repo's declaration of what must gate a merge; the merge authority follows from it,
  # so both are read from ONE home.
  # ⛔ resolve_required_checks, NEVER `REQ="$(resolve_required_checks …)"`: the command substitution
  # subshells the resolver, REQ_SOURCE cannot survive the assignment, and the ⚠️ fallback warning
  # in the case below would never fire.
  resolve_required_checks "$OR"
  MERGE_AUTHORITY="$(merge_authority "$REQ")"
  # ⚠️ review round 3: an EMPTY contract (a stale/partial repo-authority.sh yields REQ="") used
  # to read as `rail` and silently reroute a gate repo — unknown refuses, exactly like fallback.
  # ⛔ ALLOW-LIST POLARITY (round-11 review, P2). This was a DENY list — an empty REQ, `fallback`,
  # or the literal `unknown` — so any OTHER value was treated as a KNOWN authority and the sweep
  # acted on it. An authority the controller does not recognise is exactly as unknown as an
  # unreadable one, so the test now names the two values it TRUSTS and treats everything else as
  # unknown. (`merge_authority` prints only gate|rail|unknown today, so this is latent — but it was
  # one new value away from the raw merge this whole change exists to prevent.)
  if [ -z "${REQ:-}" ] \
     || { [ "${MERGE_AUTHORITY:-}" != "gate" ] && [ "${MERGE_AUTHORITY:-}" != "rail" ]; } \
     || [ "${REQ_SOURCE:-}" = "fallback" ]; then
    AUTHORITY_UNKNOWN=1
  else
    AUTHORITY_UNKNOWN=0
  fi
  case "${REQ_SOURCE:-}" in
    protection) echo "[req] $OR: required checks from branch protection: $REQ" >>"$LOG" ;;
    env)        echo "[req] $OR: required checks from the REQ environment override: $REQ" >>"$LOG" ;;
    fallback)
      # ⚠️ review P2, round 1: the fallback set deliberately carries the review gate, which on a
      # foreign repo reads FAILED — NOT PENDING — and the FAILED arm would then spawn a
      # fresh-context reviewer per PR per cycle for as long as protection is unreadable. While
      # the repo's own contract cannot be read, the SWEEP merges, auto-arms, and spawns nothing
      # this cycle (AUTHORITY_UNKNOWN, honoured in the sweep below). Dispatch lanes are
      # unaffected; and any merge worker invoked by another ingress (chain-merge, fix-one)
      # refuses on ITS OWN unreadable read — see merge-one.sh's authority-unknown refusal.
      echo "[req] ⚠️ $OR: branch protection UNREADABLE — the merge contract is UNKNOWN; the sweep merges, auto-arms, and spawns nothing this cycle (fail-closed, no burn loop; workers refuse on their own read)" >>"$LOG"
      AUTHORITY_UNKNOWN=1 ;;
    *)          echo "[req] $OR: resolver returned no source (REQ='${REQ:-}')" >>"$LOG" ;;
  esac
  # ⛔ round-11 review, P3: for an authority of `unknown` this line asserted the gate "is NOT
  # required" — a determination the controller cannot make (unknown means it does not know). A
  # three-way suffix, so the log never states a conclusion it did not reach.
  case "$MERGE_AUTHORITY" in
    gate) _gate_rel="IS required" ;;
    rail) _gate_rel="is NOT required" ;;
    *)    _gate_rel="is UNKNOWN (the contract could not be read — the sweep merges nothing this cycle)" ;;
  esac
  echo "[authority] $OR: merge authority=$MERGE_AUTHORITY (review gate '$REVIEW_GATE' $_gate_rel)" >>"$LOG"
  # ⚠️ review rounds 4-6: REQ_OVERRIDE is a documented operator pin (README: "`REQ=…` in the cell
  # env / keys.env overrides the read"), and REQ/REVIEW_GATE are read from the environment — which
  # a cloud cell sources with `set -a`, so a stray export reaches here. An override that CHANGES
  # the authority away from the repo's own declaration would silently re-enable the raw merge this
  # whole change exists to prevent on a rail repo; a REVIEW_GATE override does the same AND moves
  # the classifier's gate_ok onto a different name. The override still wins (it is how a contract
  # is pinned during an outage), but the flip is never silent.
  # ⛔ THE BASELINE IS THE DEFAULT GATE NAME, NOT `$REVIEW_GATE` (review round 6, P1). Computing
  # `_own_auth` from the overridden name made the comparison `X vs X` — provably inert — while a
  # `REVIEW_GATE` export flipped agent-infra to `gate` and issued a RAW `gh pr merge` with no log
  # line at all. With REVIEW_GATE_DEFAULT the question actually asked is "what would this repo's
  # own declaration say with no gate-name override?", which is the thing an override changes.
  if [ "${REQ_SOURCE:-}" = "env" ] || [ "${REVIEW_GATE_SOURCE:-default}" = "env" ]; then
    _own_auth="$(REVIEW_GATE="$REVIEW_GATE_DEFAULT" merge_authority "$(required_checks "$OR" 2>/dev/null || true)")"
    if [ "$_own_auth" != "unknown" ] && [ "$_own_auth" != "$MERGE_AUTHORITY" ]; then
      echo "[authority] ⚠️ $OR: an operator override CHANGES the merge authority away from this repo's own declaration ('$_own_auth' -> '$MERGE_AUTHORITY'; REQ='$REQ' REQ_SOURCE=${REQ_SOURCE:-?} REVIEW_GATE='$REVIEW_GATE' REVIEW_GATE_SOURCE=${REVIEW_GATE_SOURCE:-default}) — the override wins, but verify it is intended$([ "$MERGE_AUTHORITY" = gate ] && printf ' — GATE authority issues a RAW gh pr merge, which on a rail repo lands the PR on the required checks alone with no head-bound evidence')" >>"$LOG"
    fi
  fi
  # Same rule for the sweep listing: as a pipeline into `while read` with 2>/dev/null, a FAILED
  # listing yields ZERO iterations and prints NOTHING — the sweep silently does nothing for the
  # whole cycle. Capture it, check rc, log the failure, and feed the loop from the captured text.
  # `gh pr list` cannot be made conditional — GraphQL has no ETag — so it is a REST `gh api` call
  # whose `--jq` reshapes each REST row into the SAME `.number/.headRefName/.isDraft` triple the
  # pre-fix jq consumed, leaving $SEL and every decision below it untouched. `--paginate` follows the
  # `Link` header, so a repo with more than 100 open PRs is listed in full (the old `--limit 300`
  # silently dropped anything past 300). See the sweep-quota block above for why the listing moved,
  # and for the header helpers used here.
  # BEGIN sweep-listing (sweep-quota.test.sh extracts this block verbatim — keep it self-contained)
  NOW="$(date +%s)"
  SWEEP_LIST=""
  # Bound the DIGITS before any `[ … -gt … ]`. `[` ERRORS at or above 2**63 (the is_limit hazard this
  # file documents at the top), and an ERRORING `[` short-circuits a `&&` clamp into NOT firing — so a
  # 19-digit value would sail past the clamp. `is_num` is deliberately unbounded (it must accept a
  # 10-digit epoch), so the length test is what supplies the bound. Doing this FIRST means every
  # comparison below is on a value that cannot error.
  DEFER_UNTIL="$(cat "$O/state/sweep-defer-until" 2>/dev/null || true)"; is_num "${DEFER_UNTIL:-}" || DEFER_UNTIL=0
  [ "${#DEFER_UNTIL}" -le 10 ] || DEFER_UNTIL=0
  LAST_FULL="$(cat "$O/state/sweep-stamp" 2>/dev/null || true)";       is_num "${LAST_FULL:-}"  || LAST_FULL=0
  [ "${#LAST_FULL}" -le 10 ] || LAST_FULL=0
  # Clamp on READ, not only on write. Both writers below go through sweep_defer_until (<= now+3600),
  # so an implausible value can only arrive from a corrupt/truncated/hand-edited state file — but it
  # is the one piece of new state whose corruption stops the fleet merging and is never left, so it
  # degrades to a FULL sweep rather than a permanent stall.
  [ "$DEFER_UNTIL" -gt $(( NOW + 3600 )) ] && DEFER_UNTIL=0
  # A FUTURE stamp is worse than a stale one. The floor below reads `NOW - LAST_FULL`, so a stamp
  # ahead of NOW yields a NEGATIVE age, which is always `< SWEEP_MAX_AGE`: `If-None-Match` is then
  # sent forever, every cycle is a 304, the per-PR reads are skipped forever, and a green PR sits
  # unmerged behind a cached "unchanged" PERMANENTLY — the exact failure this floor exists to
  # prevent, and silent, because the log reports a future full sweep. Reachable from a corrupt or
  # hand-edited state file, or a BACKWARD clock step (NTP correction, VM snapshot restore). A stamp
  # is written as `$NOW`, so any value ahead of NOW is invalid by construction: degrade to a sweep.
  [ "$LAST_FULL" -gt "$NOW" ] && LAST_FULL=0
  ETAG="$(cat "$O/state/sweep-etag" 2>/dev/null || true)"
  # `If-None-Match` is sent only while the cached listing is younger than SWEEP_MAX_AGE. The floor is
  # REQUIRED, not belt-and-braces: a completed check run does NOT reliably change the listing's ETag
  # (measured 2026-10-15 — PR #1335's checks completed 00:23:32 while its listing `updated_at` stayed
  # 00:17:07), so a 304 means "no PUSH", never "nothing to merge". Without the floor a green PR
  # could sit unmerged behind a cached "unchanged" forever — the same cell-cannot-merge-reads-as-idle
  # failure this fix removes. Once the stamp ages out the header is dropped, forcing a 200 and a full
  # sweep.
  COND=()
  if [ -n "$ETAG" ] && [ $(( NOW - LAST_FULL )) -lt "$SWEEP_MAX_AGE" ]; then
    COND=(-H "If-None-Match: $ETAG")
  fi
  if [ "$DEFER_UNTIL" -gt "$NOW" ]; then
    # A previous listing was refused for rate limiting. Calling again before the reset is exactly the
    # hammering the docs warn about — and every call would fail until then. The reset (or
    # Retry-After) is already recorded, so the sweep waits it out rather than burning attempts.
    echo "[sweep] ⛔ RATE-LIMITED — sweep DEFERRED for another $(( (DEFER_UNTIL - NOW + 59) / 60 ))m (until $(date -d "@$DEFER_UNTIL" '+%H:%M:%S' 2>/dev/null || date -r "$DEFER_UNTIL" '+%H:%M:%S' 2>/dev/null || echo "epoch $DEFER_UNTIL")). THIS CELL CANNOT MERGE, NOT IDLE." >> "$LOG"
  else
    if SWEEP_RAW="$(gh api --paginate -i ${COND[@]+"${COND[@]}"} --jq \
        ".[]|{number,headRefName:.head.ref,isDraft:.draft,created:.created_at,sha:.head.sha}|select((.isDraft|not) or (.headRefName|test(\"-tm$|-cap$|^fix/\")))|$SEL|\"\(.number)\t\(.headRefName)\t\(.isDraft)\t\(.created)\t\(.sha)\"" \
        "repos/$OR/pulls?state=open&per_page=100" 2>"$O/state/.sweep-err.$$")"; then
      SWEEP_RC=0
    else
      SWEEP_RC=$?
    fi
    SWEEP_ERR="$(tr '\n' ' ' < "$O/state/.sweep-err.$$" 2>/dev/null || true)"; rm -f "$O/state/.sweep-err.$$"
    SWEEP_STATUS="$(printf '%s\n' "${SWEEP_RAW:-}" | rl_status)"
    RL_REMAIN="$(printf '%s\n' "${SWEEP_RAW:-}" | rl_header 'x-ratelimit-remaining')"
    RL_RESET="$(printf '%s\n' "${SWEEP_RAW:-}" | rl_header 'x-ratelimit-reset')"
    RL_AFTER="$(printf '%s\n' "${SWEEP_RAW:-}" | rl_header 'retry-after')"
    if [ "$SWEEP_STATUS" = "304" ]; then
      # Unchanged: GitHub does not charge a 304 to the primary rate limit, and the per-PR reads are
      # skipped this cycle — an identical listing means an identical PR set. Bounded by SWEEP_MAX_AGE.
      echo "[sweep] listing unchanged (304, etag sent) — no per-PR reads this cycle; next full sweep in <=$(( SWEEP_MAX_AGE - (NOW - LAST_FULL) ))s" >> "$LOG"
    elif [ "$SWEEP_RC" -ne 0 ]; then
      SWEEP_KIND="$(sweep_fail_kind "${SWEEP_RAW:-}" "$SWEEP_ERR")"
      if [ "$SWEEP_KIND" = "rate-limit" ]; then
        DEFER_UNTIL="$(sweep_defer_until "${SWEEP_RAW:-}")"
        printf '%s\n' "$DEFER_UNTIL" > "$O/state/sweep-defer-until"
        echo "[sweep] ⛔ RATE-LIMITED (HTTP ${SWEEP_STATUS:-?} rc=$SWEEP_RC; remaining=${RL_REMAIN:-?} reset=${RL_RESET:-?} retry-after=${RL_AFTER:-?}) — sweep DEFERRED $(( (DEFER_UNTIL - NOW + 59) / 60 ))m. THIS CELL CANNOT MERGE, NOT IDLE. (${SWEEP_ERR:-no stderr})" >> "$LOG"
      else
        echo "[sweep] PR listing FAILED ($SWEEP_KIND, HTTP ${SWEEP_STATUS:-?} rc=$SWEEP_RC) (${SWEEP_ERR:-no stderr}) — nothing swept this cycle" >> "$LOG"
      fi
    else
      # 200: refresh the validator and the age stamp, and surface a nearly-spent bucket. The low
      # deferral is set HERE, before the NEXT call — gating after the listing would only stop
      # requests the listing has already paid for.
      SWEEP_ETAG_NEW="$(printf '%s\n' "${SWEEP_RAW:-}" | rl_header 'etag')"
      [ -n "$SWEEP_ETAG_NEW" ] && printf '%s\n' "$SWEEP_ETAG_NEW" > "$O/state/sweep-etag"
      printf '%s\n' "$NOW" > "$O/state/sweep-stamp"
      rm -f "$O/state/sweep-defer-until"
      # ⛔ THREE COLUMNS STAY THE CONTRACT (every reader below, and the sweep-quota suite, splits on
      # SWEEP_LIST's `pr \t branch \t draft`). The listing now also carries each PR's `created_at`
      # and head sha — the SAME request, no extra point — and those two are projected into their own
      # state file for the selection ORDER (oldest-first). Writing them into SWEEP_LIST would break
      # every `read -r PR BR DRAFT` consumer, so the projection, not the request, is what splits.
      SWEEP_LIST="$(printf '%s\n' "${SWEEP_RAW:-}" | awk -F"$(printf '\t')" 'NF>=3 && $1 ~ /^[0-9]+$/ {print $1"\t"$2"\t"$3}')"
      printf '%s\n' "${SWEEP_RAW:-}" | awk -F"$(printf '\t')" 'NF>=5 && $1 ~ /^[0-9]+$/ {print $1"\t"$4}' > "$O/state/pr-meta.tsv" 2>/dev/null \
        || : > "$O/state/pr-meta.tsv"
      if is_num "${RL_REMAIN:-}" && [ "$RL_REMAIN" -le "$SWEEP_MIN_REMAIN" ]; then
        DEFER_UNTIL="$(sweep_defer_until "${SWEEP_RAW:-}")"
        printf '%s\n' "$DEFER_UNTIL" > "$O/state/sweep-defer-until"
        echo "[sweep] ⚠️ rate limit low: x-ratelimit-remaining=$RL_REMAIN (<= $SWEEP_MIN_REMAIN) reset=${RL_RESET:-?} — next sweep deferred $(( (DEFER_UNTIL - NOW + 59) / 60 ))m" >> "$LOG"
      fi
    fi
  fi
  # END sweep-listing
  # ── cross-box claim snapshot (agent-infra#1709 recs 1-3) ─────────────────────
  # ONE fetch refreshes every claim ref, so claim_live() answers "is another box on this?"
  # from a local file. Per-PR network calls would be 2 x N round trips per cycle.
  if [ -f "$O/claims.sh" ]; then
    # shellcheck source=/dev/null
    . "$O/claims.sh"
    # REQUIRED: this loop runs from launchd with cwd=$HOME. Without CLAIM_REPO every git call
    # inside claims.sh targets a non-repo, the fetch fails silently and the snapshot is empty
    # even with live claims — measured: 3 claims on origin, 0 snapshot lines.
    CLAIM_REPO="$REPO"
    claim_snapshot "$O/state/claims-snapshot"
    # Expired refs are unbounded otherwise. Hourly, in the background, never blocking the sweep.
    if [ -z "$(find "$O/state/.claims-pruned" -mmin -60 2>/dev/null)" ]; then
      touch "$O/state/.claims-pruned"
      ( claim_prune >> "$LOG" 2>&1 ) &
    fi
  fi

  # ── machine-global package caches (agent-infra#1987) ───────────────────────
  # The measured defect: on pi-cell-3 `~/.cache/uv` reached 7.1GB and the box refused EVERY
  # dispatch at 258MB free while this controller kept beating and the queue read fine. The refusal
  # itself was loud (spawn-gate names the disk and the remedy) — the REMEDY was the gap: `prune`
  # reclaimed per-worktree `.venv`/`node_modules` only, so the largest consumer was untouched and
  # kept growing.
  # This loop is a CLOCK for the reaper, not the owner of its policy. Both triggers ship DRY-RUN:
  # arming a scheduled deletion is an owner-level decision (agent-infra#1678, owner ruling
  # 2026-10-11: "the reaper may run unattended; arming it may not"). The armed arm is reached the
  # way the cell already reclaims under pressure — `cloud-cell-supervisor.sh`, unattended below
  # 2x MIN_FREE_MB with no live worker, calling `prune --caches`.
  # The hourly stamp is the same idiom as claim_prune above (this loop's clock is mtime-based).
  if [ -z "$(find "$O/state/.cache-reaped" -mmin -60 2>/dev/null)" ]; then
    touch "$O/state/.cache-reaped"
    # The same chain as the supervisor and bring-up: ${CACHE_REAPER:-} -> the FARMED copy ->
    # the copy beside the bundle (scripts/pi-cache-reap.sh, one directory up from this harness).
    # The SAME chain, in the SAME order, as cloud-cell-supervisor.sh and cloud-cell-bringup.sh:
    # ${CACHE_REAPER:-} -> the FARMED copy -> the copy beside the bundle. A loop, not an if/else:
    # with an if/else a NON-EMPTY but mistyped override selected nothing and the clock went
    # permanently silent (a log line only — `.cache-reap-blocked` was never written, so `status` said
    # nothing) while the armed prune path on the same box ran the farmed copy.
    _cache_reaper=""
    for _cand in "${CACHE_REAPER:-}" \
                 "${HOME:-}/.pi/agent/scripts/pi-cache-reap.sh" \
                 "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/pi-cache-reap.sh"; do
      [ -n "$_cand" ] && [ -f "$_cand" ] && { _cache_reaper="$_cand"; break; }
    done
    [ -n "$_cache_reaper" ] || _cache_reaper="${CACHE_REAPER:-${HOME:-}/.pi/agent/scripts/pi-cache-reap.sh}"
    if [ -f "$_cache_reaper" ]; then
      # ⛔ `&` discards the exit status, and that status is the reaper's ONLY signal (the class the
      # ⛔ further down this file records for the refresh:
      # "a refresh that aborts EVERY cycle reads as a healthy cell"). Record a non-zero pass where
      # `status` prints it, and clear it on the next clean one.
      (
        bash "$_cache_reaper" --dry-run >>"$LOG" 2>&1
        _rc=$?
        case "$_rc" in
          0) rm -f "$O/state/.cache-reap-blocked" ;;   # checked: every cache is under its bound
          4) : ;;                                      # did not run (lock held) — touch nothing
          5) { printf 'a package cache is OVER its bound and the reaper is not armed (dry-run):\n';
               tail -3 "$LOG" 2>/dev/null; } >"$O/state/.cache-reap-blocked" 2>/dev/null || true ;;
          *) { printf 'cache reaper exit %s at %s\n' "$_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)";
               tail -2 "$LOG" 2>/dev/null; } >"$O/state/.cache-reap-blocked" 2>/dev/null || true ;;
        esac
      ) &
    else
      echo "[cache-reap] NOT RUN — $_cache_reaper is absent, so the machine-global uv/npm/pip caches are unbounded (farm it: pi-bootstrap/setup.sh)" >> "$LOG"
    fi
  fi

  # ── OWNERSHIP + SELECTION ORDER (owner ruling, 2026-10-18) ───────────────────────────────────
  # ⛔ ONE LIVE SCAN PER CYCLE, then everything below reads its output. `lo_scan` asks the MACHINE
  # (every visible process's cwd, joined against this repo's worktrees) who is actually holding a
  # PR branch — that is the predicate pr_owned() uses, and it cannot be answered by reading state
  # files, which is why it is a process probe rather than a registry lookup. Cost: ~2s per cycle at
  # ~180 processes; the sweep's per-PR reads are an order of magnitude more than that.
  # A failed scan is UNKNOWN and prints as such: it degrades to the registry arms of pr_owned (so
  # a box whose `$O` predates this file still runs) and the funnel says scan=UNREADABLE.
  LO_STATUS="unavailable"
  if [ "${LO_SCAN:-0}" = "1" ]; then
    if lo_scan "$LO_LIVE" "$REPO"; then
      LO_STATUS=ok
    else
      # ⛔ A FAILED SCAN MUST NOT LEAVE THE PREDICATE READING THE TABLE IT COULD NOT REFRESH (review
      # R2, P2). The module cannot always delete its own output (an unwritable `state/` cannot be
      # written to AND cannot be cleaned), and `pr_owned` never consulted the status — so a stale
      # table of processes that have since died kept answering OWNED. Blanking the path makes arm 1
      # inert for the cycle, which is the documented registry-only degrade: fail-closed, and it does
      # not depend on being allowed to delete anything.
      LO_STATUS=UNREADABLE
      rm -f "$LO_LIVE" 2>/dev/null || true
      LO_LIVE=""
    fi
  fi
  # ⛔ ORDER IS LOAD-BEARING: this runs AFTER the claim snapshot refresh above (pr_owned reads it)
  # and BEFORE every use of UPN/MR/MF (section 2's spawn sites and the dispatch gate).
  UPN="$(unowned_pr_count "$OPEN_N")"
  # ⛔ A malformed count must not OPEN the gate. `[ … -gt … ]` on a non-number ERRORS (rc 2) and an
  # errored test is FALSE — the gate chain then allows dispatch. Fall back to the TOTAL open count
  # (the conservative direction: more unowned => drain), and if even that is unusable, to one above
  # the threshold. Both arms fail CLOSED — and they are the ONLY fallback there is, now that
  # unowned_pr_count emits nothing rather than a number on a malformed argument.
  # ⛔ `is_num`, NOT a `case … [0-9]` digit test: the case pattern accepts a leading zero, which
  # `[ … -gt … ]` reads as DECIMAL (`08` = 8), so `08` slipped through the guard and the gate
  # OPENED on a count that was never valid.
  is_num "${UPN:-}" || UPN="${OPEN_N:-}"
  is_num "${UPN:-}" || UPN=$(( 10#${MERGE_PRIORITY_AT:-25} + 1 ))
  # Give reviewers AND fixers extra headroom above the backlog threshold (and section 2 stops
  # dispatching new lanes). Below it, run a mix. Tune with MERGE_PRIORITY_AT.
  MR="$(review_slots "$UPN")"
  MF="$(fix_slots "$UPN")"
  # ── THE SELECTION ORDER: un-owned PRs → new issues → nothing ─────────────────
  # The sweep below ACTS in this order, so a scarce fixer/reviewer slot goes to the PR that unblocks
  # the queue (conflicted first, then red, then merely-pending, then green) and, within a class, to
  # the OLDEST — not to whichever PR GitHub happened to list last. Classes come from the last
  # observation this loop made (state/prclass.tsv, appended in the sweep); the age comes from the
  # listing. A class observed one cycle ago is the honest input: the sweep re-observes every PR
  # every cycle, and neither datum decides anything on its own.
  # OWNED / UNOWNED is marked in the same order in ONE awk pass (a per-PR fork here would cost more
  # than the rest of the cycle).
  if [ "${LO_SCAN:-0}" = "1" ] && [ -n "${SWEEP_LIST:-}" ]; then
    SWEEP_ORDER="$(printf '%s\n' "$SWEEP_LIST" | lo_order "$O/state/pr-meta.tsv" "$O/state/prclass.tsv")"
    SEL_ROWS="$(printf '%s\n' "${SWEEP_ORDER:-$SWEEP_LIST}" | lo_select_rows "$LO_LIVE")"
    lo_class_compact "$O/state/prclass.tsv"
  else
    # No live scan (module absent) → the registry arms still answer pr_owned, but there is no order
    # to derive, so the listing order stands and every row is marked UNKNOWN.
    SEL_ROWS="$(printf '%s\n' "${SWEEP_LIST:-}" | awk -F"$(printf '\t')" -v OFS="$(printf '\t')" 'NF>=3 {print $1,$2,$3,"UNKNOWN"}')"
  fi
  # ── the funnel's inputs: ONE POPULATION PER CYCLE, from the RICHEST source that actually read ──
  # ⛔ THE PARTS AND THE TOTAL MUST COME FROM THE SAME READ (measured in the first live cycle of this
  # change: the line read `56 un-owned (5 owned)` beside `61 PRs` from one listing and `26 open` from
  # another — an operator learns to ignore a funnel whose arithmetic does not close). Three sources
  # exist, tried in order of how much they answer:
  #   1. state/last-open-prs — one row per OPEN PR carrying its head ref, written by the SAME listing
  #      that produced OPEN_N. The richest: total, owned and un-owned all come from it.
  #   2. the SWEPT rows — the REST listing below, which is the one that still works when GraphQL is
  #      rate-limited (`gh pr list` is GraphQL and fails first; that is why OPEN_N can be a fallback).
  #   3. OPEN_N alone — a count with no rows: everything reads un-owned, which is the drain direction.
  # ⛔ NOT the swept set when (1) is available, and never the swept set as the GATE's population on its
  # own: SWEEP_LIST is SCOPE-FILTERED (`SCOPE=own` keeps only `-tm$|-cap$|^fix/`), so gating on it would
  # read 0 un-owned while the repo held fifty — and open the issue path, the exact defect this removes.
  OPEN_ROWS="$(cat "$O/state/last-open-prs" 2>/dev/null || true)"
  # [parked-count:begin] (extracted and DRIVEN by test-gates.sh — keep the marker)
  SEL_PARKED=0
  _nrows=0
  for _tok in $OPEN_ROWS; do
    _nrows=$(( _nrows + 1 ))
    _op="${_tok%%:*}"; _rest="${_tok#*:}"; _osha="${_rest%%:*}"; _obr="${_rest#*:}"
    [ "$_obr" = "$_osha" ] && _obr=""
    case "$_op" in ''|*[!0-9]*) continue ;; esac
    # ⛔ THE PARK IS HEAD-KEYED HERE TOO (review cycle 3, P1). This arm counted the marker's
    # EXISTENCE while the acting path compares the head stored inside it (`parked-<PR>` = "the fixer
    # cap was reached at THIS head; a later push re-arms the PR"). A park left behind by a PR that has
    # since been pushed is therefore NOT parked — but it was subtracted from the minuend anyway, so
    # `UPN_WORK` could reach 0 with a workable un-owned PR still on the queue and the issue path
    # OPENED on it. That is the "stale flag that records a past state and is never revalidated" class,
    # and the module's own contract says the workable count is PRs parked AT THIS HEAD.
    # An empty/legacy head on either side reads NOT parked — fail-closed in the direction that blocks.
    [ "$(cat "$O/state/parked-$_op" 2>/dev/null)" = "${_osha:-}" ] || continue
    # ⛔ ONLY AN UN-OWNED PARKED PR MAY BE SUBTRACTED (review P3). UPN already EXCLUDES owned PRs, so
    # subtracting a PR that is both parked and owned removes a unit that was never in the minuend —
    # and with exactly one un-owned PR left, that floored the count to 0 and opened the issue path
    # while an un-owned PR was still on the queue. One `pr_owned` per PARKED PR (rare) is the price.
    if ! pr_owned "$_op" "$_osha" "$_obr"; then SEL_PARKED=$(( SEL_PARKED + 1 )); fi
  done
  # [parked-count:end]
  FIRST_PR="-"; SEL_OWN=0; SEL_UNOWNED=0
  while IFS="$(printf '\t')" read -r _p _b _d _o; do
    [ -z "${_p:-}" ] && continue
    if [ "$_o" = "OWN" ]; then SEL_OWN=$(( SEL_OWN + 1 )); continue; fi
    SEL_UNOWNED=$(( SEL_UNOWNED + 1 ))
    [ "$FIRST_PR" = "-" ] && FIRST_PR="$_p"
  done <<<"${SEL_ROWS:-}"
  # …and the parked exclusion over the SWEPT set, for source (2) (source (1) already counted its own).
  if [ "$_nrows" -eq 0 ]; then
    SEL_PARKED=0
    while IFS="$(printf '\t')" read -r _p _b _d _o; do
      [ -z "${_p:-}" ] && continue
      [ "$_o" = "OWN" ] && continue
      [ -f "$O/state/parked-$_p" ] && SEL_PARKED=$(( SEL_PARKED + 1 ))
    done <<<"${SEL_ROWS:-}"
  fi
  POP=fallback
  FLOOR_NOTE=""
  OWN_N=0
  UPN_WORK="$UPN"
  SEL_TOTAL="${OPEN_N:-?}"
  if [ "$_nrows" -gt 0 ] && is_num "${UPN:-}"; then
    POP=open-rows
    SEL_TOTAL="$_nrows"
    OWN_N=$(( SEL_TOTAL - UPN )); [ "$OWN_N" -lt 0 ] && OWN_N=0
    UPN_WORK=$(( UPN - SEL_PARKED )); [ "$UPN_WORK" -lt 0 ] && UPN_WORK=0
  elif [ "${SEL_UNOWNED:-0}" -gt 0 ] || [ "${SEL_OWN:-0}" -gt 0 ]; then
    POP=swept
    SEL_TOTAL=$(( SEL_OWN + SEL_UNOWNED ))
    OWN_N="$SEL_OWN"
    UPN_WORK=$(( SEL_UNOWNED - SEL_PARKED )); [ "$UPN_WORK" -lt 0 ] && UPN_WORK=0
    # ⛔ THE SWEPT SET MAY NEVER LOWER THE GATE BELOW THE FAIL-CLOSED COUNT (review P1). With no
    # open-PR rows, `unowned_pr_count` answers the WHOLE listing count — "assume nothing is owned" —
    # because `open_pr_count` deletes the rows on a failed read; and SWEEP_LIST is SCOPE-FILTERED and
    # is EMPTY on any cycle whose listing was not a 200 (it is reset before the request and only filled
    # on success — an earlier version of this comment claimed it "survives a non-200 sweep"; that was
    # false, see #2126), so a swept set that reads fully owned — or empty — IS a normal state in
    # exactly the cycle this fallback exists for. Taking its smaller number would open the issue path
    # on the very defect this change removes — the one direction that must never happen. Floor it, and
    # say so on its own line (the funnel's arithmetic stays closed per-source; this line states which
    # number the GATE actually used).
    if is_num "${UPN:-}" && [ "$UPN" -gt "$UPN_WORK" ]; then
      UPN_WORK="$UPN"
      # …AND THE HEADLINE MUST NOT CONTRADICT IT (review R2, P3). Taking the listing's count while
      # printing the swept set's parts produced `5 PRs: 26 un-owned (5 owned …)` — arithmetic that does
      # not close is exactly what this block exists to stop, and an operator reads the headline, not
      # the note. With the floor applied the population IS the listing: total = the listing's count,
      # owned = 0 (a missing row set means nothing is known to be owned). The swept sizes stay on the
      # `population=` line, where they belong.
      SEL_TOTAL="${OPEN_N:-$UPN}"
      OWN_N=0
      # ⛔ AND THE PARKED PART DIES WITH THE POPULATION (review cycle 3, P2). The park count above was
      # computed over the SWEPT set; `UPN` already excludes any parked PR. Keeping the swept count
      # printed `26 PRs: 26 un-owned (0 owned, 5 parked/needs-human excluded)` — 26 + 0 + 5 ≠ 26, the
      # exact arithmetic-does-not-close shape this block exists to prevent. The floor line already
      # states that the per-PR detail (including the parked exclusion) was lost this cycle.
      SEL_PARKED=0
      FLOOR_NOTE="[select] ⚠️ fail-closed floor: the listing answers ${UPN} un-owned (no per-PR rows this cycle) while the swept set saw ${SEL_OWN} owned — gating on ${UPN} (the drain direction)"
    fi
  fi
  echo "[select] population=$POP scan=$LO_STATUS (open-rows=${_nrows:-0} swept=$(( SEL_OWN + SEL_UNOWNED )) fallback_open=${OPEN_N:-?})" >> "$LOG"

  # ── PER-PR DISPOSITIONS (agent-infra#2126) ───────────────────────────────────────────────────
  # ⛔ THE INVARIANT THIS FILE EXISTS TO ENFORCE: every COUNTED un-owned PR must, each cycle, either
  # be acted on by exactly one unit or carry a PRINTED terminal reason. Before this, a PR could hold
  # the issue path shut while appearing in no line at all — the sweep either skipped it silently (a
  # draft/scope/parked/authority `continue`), fell through the acting `case` with no arm (NOCHECKS),
  # or never saw it (the listing filtered it out, or returned 304 with no rows).
  # ⛔ A FILE, NOT A VARIABLE: the sweep below is a pipeline (`printf | while read`), so every
  # variable it sets dies at `done` and there is no `lastpipe` in this file. `prclass.tsv` already
  # travels this way. The parent TRUNCATES it here, BEFORE the pipeline, so cycle N can never read
  # cycle N-1's rows as its own claims (the stale-marker class), and it is bounded by construction:
  # at most one row per PR, rewritten — never appended across cycles (so it needs no prune job).
  # ⛔ WRITTEN ONLY. Nothing between the count and the gate may READ this file (pinned by
  # test-gates.sh): a disposition is a record of what the drain did, and the moment it becomes an
  # input to `UPN_WORK`/`mp_reason` we are back to a narrower population deciding the gate — the
  # reopen #2099 forbids.
  # [prdisp:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
  PRDISP="$O/state/prdisp.tsv"; PRDISP_OK=1
  : > "$PRDISP" 2>/dev/null || { PRDISP=/dev/null; PRDISP_OK=0; }
  DISP_SEP="$(printf '\t')"
  # ⛔ SANITISE EVERY FIELD. Field 3 is the classifier token (`FAILED:<name>,<name>`) and field 5 is a
  # reason, and check names come from the GitHub API. The record is TAB-delimited and every consumer
  # splits on it, so a name containing a tab or a newline could forge a whole row (`9999<TAB>…<TAB>act`)
  # or flip a real row's decision field. Check names are attacker-influenced only with repo write
  # access, which is why this is hardening and not a gate — but a record other code trusts must not
  # carry the delimiter.
  disp() { # disp <pr> <head> <token> <act|wait> <reason>
    local _a _b _c _d _e
    _a="$(printf '%s' "${1:-?}"   | tr -d '\t\n')"
    _b="$(printf '%s' "${2:--}"   | tr -d '\t\n')"
    _c="$(printf '%s' "${3:--}"   | tr -d '\t\n')"
    _d="$(printf '%s' "${4:-wait}" | tr -d '\t\n')"
    _e="$(printf '%s' "${5:-unspecified}" | tr -d '\t\n')"
    # ⛔ THE HARNESS RIDES ON EVERY DISPATCH ROW (agent-infra#2215). A lane spawned from a checkout that
    # is behind origin/main must carry that fact on the line that reports the spawn — and the ONLY
    # place every spawn (current and future) passes through is here. Empty when the box is current, so
    # a healthy log is not made chattier; never invented when the refresh could not answer (that token
    # is `unknown`, which reads as "cannot-verify" and not as "fine").
    if [ -n "${HARNESS_TOKEN:-}" ]; then _e="$_e [harness=$HARNESS_TOKEN]"; fi
    # ⛔ THE REDIRECT FAILURE IS SUPPRESSED BY THE BRACE, NOT BY THE TRAILING `2>/dev/null`: bash opens
    # `>> "$PRDISP"` BEFORE applying the command's stderr redirect, so on a full/unwritable file the
    # error escaped to launchd.err and nothing in $LOG said the ledger was failing (review cycle 2, P3).
    { printf '%s\t%s\t%s\t%s\t%s\n' "$_a" "$_b" "$_c" "$_d" "$_e" >> "$PRDISP"; } 2>/dev/null || true
  }
  # ⛔ ONE ROW PER PR PER CYCLE, BY CONSTRUCTION. A PR can be touched by two code paths in one iteration
  # (the rerun block runs after the arm chain), and a second row made the summary report TWO PRs for one
  # and let a cycle with zero spawns read `1 acted`. Where a later fact supersedes an earlier one, the
  # ROW IS REPLACED — never appended.
  dispreplace() { # dispreplace <pr> <head> <token> <act|wait> <reason>
    local _dp _dtmp
    if [ "${PRDISP_OK:-0}" = "1" ] && grep -q "^$(printf '%s' "${1:-?}" | tr -d '\t\n')"$'\t' "$PRDISP" 2>/dev/null; then
      _dp="${1:-?}"; _dtmp="$PRDISP.new"
      awk -F'\t' -v p="$_dp" '$1!=p' "$PRDISP" > "$_dtmp" 2>/dev/null && mv "$_dtmp" "$PRDISP" 2>/dev/null \
        || { rm -f "$_dtmp" 2>/dev/null; }
    fi
    disp "$@"
  }
  # [prdisp:end]

  printf '%s\n' "$SEL_ROWS" |
  while IFS="$(printf '\t')" read -r PR BR DRAFT OWN; do
    [ -z "${PR:-}" ] && continue
    # Skip anything that is not a plain integer PR / simple ref — never let API data reach a shell.
    is_num "$PR" || { echo "#${PR:-?} SKIPPED (non-numeric PR id)" >>"$LOG"; disp "${PR:-?}" - - wait "non-numeric PR id (not acted on)"; continue; }
    safe_ref "$BR" || { echo "#$PR SKIPPED (unsafe branch name: $BR)" >>"$LOG"; disp "$PR" - - wait "unsafe branch name (not acted on)"; continue; }
    if [ "${DRAFT:-}" = "true" ]; then
      # ⛔ A SWEPT DRAFT IS AN ACT, NOT A WAIT (review cycle 2, P0). The listing's draft exemption is
      # `(not draft) or (branch matches the OWN pattern)`, so a draft that reaches this loop IS
      # selected for action and `gh pr ready` is that action. Recording it as a wait would write a
      # false wait onto an acted PR — the inverse of the defect this change removes.
      if gh pr ready "$PR" --repo "$OR" >/dev/null 2>&1; then
        echo "#$PR readied (was a draft)" >>"$LOG"; disp "$PR" - - act "draft readied"
      else
        echo "#$PR draft: 'gh pr ready' FAILED — it will be retried next cycle" >>"$LOG"
        disp "$PR" - - wait "draft ready FAILED (retried next cycle)"
      fi
      continue
    fi
    PR_ST="$(gh pr view "$PR" --repo "$OR" --json state --jq .state 2>/dev/null)"
    # CLOSED too: a PR listed open can close between `gh pr list` and here. The retired sweep.sh
    # guarded both; the live rewrite kept only MERGED, so a closed PR fell through to
    # `gh pr ready` + `gh pr merge` every cycle and logged `#<PR> merge fail` forever.
    case "${PR_ST:-}" in MERGED|CLOSED)
      # A PR that leaves the queue carries no refusal and no budget: these are head-bound records, and
      # nothing else prunes them (review P3, cycle 4 — small, but one pair per abandoned PR, forever).
      [ "${REDFIX:-0}" = "1" ] && rail_refusal_clear "$O" "$PR" 2>/dev/null
      rm -f "$O/state/redfix-$PR" 2>/dev/null || true
      rm -f "$O/state/fixgate-$PR-"* 2>/dev/null || true
      disp "$PR" - - wait "${PR_ST:-closed} since the count was read (nothing to do)"; continue ;; esac
    HEAD_N="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
    # [redfix:begin] (extracted and DRIVEN by red-fixer.test.sh — keep the markers)
    # ⛔ THE RED-FIXER ROLE: REFUSE -> SPAWN A FIXER -> RE-RAIL WHEN THE HEAD MOVES.
    #
    # MEASURED 2026-10-20, the week this exists to end: open=17, thirteen rails "running", ONE merge
    # that day, and ZERO agent lanes on the cells. Rails are bash and refuse a red tree by design
    # (correct). Nothing in this loop ever turned a REFUSAL into work: the fixer arms in the acting
    # case below are keyed on CHECK CLASSES, and a rail refusal is not a check class — it is the
    # rail's verdict on the tree, which can name a check that is not in this repo's required set.
    # So the PR sat refused, the sweep reported it as un-owned with a reason, and no actor on the box
    # could move it. After hand-spawned fixers: merged 1 -> 6 in ~40 min, open 19 -> 16.
    #
    # ⛔ IT RUNS BEFORE THE PARKED GUARD, and that ordering is the whole point. `parked-<PR>` is
    # written by `merge-one.sh` at RAIL_TRIES and by the fixer caps — a head that has been parked is
    # exactly the head nobody will repair, so a guard that runs first would keep the refusal in the
    # "needs a human" state forever. This role spends ITS OWN head-keyed budget and writes its own
    # park at the end, so it cannot become the unbounded retry loop the park exists to prevent.
    #
    # ⛔ ONE FIXER PER PR, and the session name is `fix-<PR>` — the SAME name the other fixer arms
    # use. That is deliberate: every census on this box (`reap_stale_workers`, the `^fix-` ceiling
    # counts, the worker count in `[cap]`, the cell supervisor's prune guard, the cell doctor) already
    # knows that name, and a second namespace would be invisible to all of them — a wedged red-fixer
    # no reaper can find, and an uncounted worker a prune may delete the caches of (agent-infra#1932's
    # class). It also makes "a reviewer-findings fixer and a red-fixer for one PR" impossible.
    #
    # ⛔ IT REPLACES THE ORDINARY ARMS FOR THIS PR THIS CYCLE (`continue` below): one disposition per
    # PR per cycle, so the GREEN arm cannot spawn a `merge-<PR>` to re-run a rail that has already
    # spoken about this head, and the CI-red arm cannot spawn a second fixer.
    # ⛔ THE AUTHORITY GUARD IS BELOW THIS BLOCK, AND THAT MATTERS (review P2, cycle 5). The sweep
    # states `AUTHORITY_UNKNOWN=1 -> the sweep merges, auto-arms and spawns NOTHING this cycle
    # (fail-closed)` — but its guard runs AFTER this block. A cell whose merge contract cannot be read
    # (the very fail-closed state that guard exists for) could therefore still be handed a PAID lane by
    # this role: `cloud-cell-doctor.sh` runs the rail with no authority gate, so it can leave a
    # refusal. Refusing here keeps the guarantee the other line already prints.
    RF_FALLTHROUGH=0
    if [ "${REDFIX:-0}" = "1" ] && [ "${AUTHORITY_UNKNOWN:-0}" != "1" ] \
       && [ -n "${HEAD_N:-}" ] && [ -f "$O/state/railrefusal-$PR" ]; then
      # ONE snapshot, then parse (review P3, cycle 3): two writers replace this record, and each
      # `mv` is atomic but four separate reads are not — the head could come from one record and the
      # class from the next. `cat` once, parse the string.
      RF_REC="$(cat "$O/state/railrefusal-$PR" 2>/dev/null)"
      RF_HEAD="$(rail_refusal_get "$RF_REC" head 2>/dev/null)"
      RF_CLASS="$(rail_refusal_get "$RF_REC" class 2>/dev/null)"
      RF_REASON="$(rail_refusal_get "$RF_REC" reason 2>/dev/null)"
      RF_DETAIL="$(rail_refusal_get "$RF_REC" detail 2>/dev/null)"
      # ⛔ A HEAD CAN GO GREEN WITHOUT A PUSH (review P1, cycle 2, 2026-10-21). A re-run of a flaky
      # check (`gh run rerun --failed`, the rail's own flake re-run, the button in the UI) leaves the
      # sha IDENTICAL, so the stored refusal would keep describing a tree that no longer exists — and
      # the `continue` below would suppress the GREEN arm that could merge it AND the CI-rerun actuator,
      # parking a mergeable PR "needs a human" after burning the budget on it. So the surface is
      # RE-READ for a refused PR (only a refused PR — this costs nothing on the common path).
      RF_SURF=""
      [ "${RF_CLASS:-}" = "red-tree" ] && RF_SURF="$(head_reds "$PR")"
      if [ -n "${RF_HEAD:-}" ] && [ "$RF_HEAD" != "$HEAD_N" ]; then
        # (4) A NEW HEAD INVALIDATES THE OLD REFUSAL. A refusal describes ONE tree; keeping it after
        # a push is how a repaired PR stays skipped ("a fixer pushed, the old refusal still stands").
        # Dropping it here hands the NEW head back to the ordinary arms, i.e. it is RE-RAILED.
        rail_refusal_clear "$O" "$PR" 2>/dev/null || true
        rm -f "$O/state/redfix-$PR" 2>/dev/null || true
        rm -f "$O/state/fixgate-$PR-"* 2>/dev/null || true
        echo "#$PR rail refusal at head=$RF_HEAD is STALE (the head is now $HEAD_N) — dropped; this head is re-railed instead of inheriting the old verdict" >>"$LOG"
      elif [ "${RF_CLASS:-}" = "red-tree" ] && [ "${RF_SURF:-}" = "GREEN" ]; then
        # THE REFUSAL NO LONGER DESCRIBES THIS HEAD, and no push happened: the tree went green under
        # the same sha. Dropping the record and falling through is the RE-RAIL (the GREEN arm runs).
        rail_refusal_clear "$O" "$PR" 2>/dev/null || true
        rm -f "$O/state/redfix-$PR" 2>/dev/null || true
        rm -f "$O/state/fixgate-$PR-"* 2>/dev/null || true
        # ⛔ THE PARK ITS OWN CAP WROTE MUST GO TOO (review P1, cycle 4). The parked guard is the
        # NEXT statement in the sweep, and it compares `parked-$PR` to the current head — so a park
        # left at this head made the loop `continue` with "needs a human" while the line above said
        # "re-railing": the PR would never be re-railed, which is exactly the case this branch exists
        # for. A non-red surface DISPROVES the park's premise ("still red after N attempts").
        # `railcount-<PR>` is reset with it: it is head-keyed and may already be at RAIL_TRIES for
        # this head, which would park the freshly re-railed head on its first refusal.
        if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" = "$HEAD_N" ]; then
          # ⛔ READ THE REASON BEFORE DELETING IT (review P3, cycle 5 — the first version removed the
          # file and then printed its contents in the same command, so the audit line always said
          # \`?\`). And only lift a park THIS role or the rail wrote: a park a human created, or another
          # arm's ("still CONFLICTING", "still needs fixes"), records a judgement about the PR that a
          # green check surface does not settle. An ABSENT reason is the rail's own park
          # (`merge-one.sh` writes `parked` without a reason), which is exactly the one this branch is
          # entitled to lift when the tree it complained about is gone.
          RF_WHY="$(cat "$O/state/parkreason-$PR" 2>/dev/null)"
          case "${RF_WHY:-}" in
            ''|*'RED TREE'*|*'rail refused'*)
              rm -f "$O/state/parked-$PR" "$O/state/parkreason-$PR" 2>/dev/null || true
              echo "#$PR park at head=$HEAD_N lifted: the tree is non-red now, so the premise it recorded is false (reason was: ${RF_WHY:-<none: the rail wrote it>})" >>"$LOG" ;;
            *)
              echo "#$PR park at head=$HEAD_N NOT lifted: its reason is '${RF_WHY}' (not this role's and not the rail's) — a green check surface does not settle it, so a human's decision stands" >>"$LOG" ;;
          esac
        fi
        rm -f "$O/state/railcount-$PR" 2>/dev/null || true
        echo "#$PR rail refusal at head=$HEAD_N no longer describes the tree: every check is non-red WITHOUT a push (a re-run) — dropped, re-railing. REFUSAL WAS: ${RF_REASON:-<none recorded>}" >>"$LOG"
      elif [ "${RF_CLASS:-}" != "red-tree" ]; then
        # NOT a red tree, so NOT a fixer's work: a draft, an unreadable surface, a rate limit, a
        # conflict (the CONFLICTING router below owns those) or the audited override. Said out loud
        # every cycle on purpose — #2126's rule is that a non-action must carry a printed reason,
        # and "the rail refused and nothing happened" with no reason is the shape that hid the stall.
        # ⛔ NO LEDGER ROW HERE, ON PURPOSE. This branch does not act, so the PR keeps its ONE
        # disposition row from the ordinary arms below (a second row would make a zero-spawn cycle
        # report two PRs for one — the arithmetic #2126's sidecar exists to keep closed). It DOES
        # print the reason: falling through silently is what made the stall invisible.
        echo "#$PR rail refused (class=${RF_CLASS:-?}) at head=$HEAD_N — NO red-fixer spawned (only a RED TREE is a fixer's work): ${RF_REASON:-<no refusal line recorded>}" >>"$LOG"
      else
        # The refusal stands at THIS head. Attempts are head-keyed: a new head is new work.
        #
        # ⛔ THE BUDGET IS FAIL-CLOSED (review P1, 2026-10-21). `is_limit "$RF_N" || RF_N=0` on an
        # UNREADABLE counter is a cap silently disabled: the read fails, the count reads 0, the lane
        # spawns, the increment cannot be written either — and every cycle re-reads the old value and
        # spawns again. The per-head cap would never bind while the log said `attempt 1/2` forever.
        # So a counter that exists but cannot be READ, or holds a value that is not a count, STOPS
        # the role (park + say why) instead of resetting itself to zero. A zero-byte counter is
        # distinguished from both: that is a torn write, it is reset and NOT spawned on this cycle,
        # which is the direction that cannot spawn twice.
        RF_CF="$O/state/redfix-$PR"; RF_N=""; RF_H=""; RF_BAD=""
        # ⛔ REPORT-ONLY IS DECIDED BEFORE THE COUNTER IS EVEN READ (review P2, cycle 7). The
        # cycle-6 fix put this test after the counter checks, so a report-only box still PARKED a PR
        # on a torn or unreadable counter — with a reason ("the per-head cap cannot be kept") that is
        # false on a box whose configuration is "never spawn a red-fixer". The counter is irrelevant
        # here, so it is not consulted; the PR goes back to the ordinary arms (which own its row).
        if [ "${MAX_RED_FIX_TRIES:-2}" = "0" ]; then
          echo "#$PR RED TREE at head=$HEAD_N — the red-fixer role is REPORT-ONLY on this box (MAX_RED_FIX_TRIES=0): nothing spawned, nothing parked. REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
          # ⛔ AND IT MUST ACTUALLY FALL THROUGH (review P2, cycle 6). The first version SAID "falling
          # through is what report-only means" and then reached the block's single `continue` like every
          # other branch — so a box configured report-only suppressed the ordinary arms for every
          # red-tree PR: no merge, no re-rail, no CI-red fixer, no ledger row. That is the stall this
          # role exists to end, shipped as a setting.
          # NO `disp` HERE on purpose: the ordinary arms own this PR's ONE row for the cycle, and a row
          # written here as well would report two dispositions for one PR (#2126).
          RF_FALLTHROUGH=1
        elif [ -f "$RF_CF" ]; then
          if [ ! -s "$RF_CF" ]; then
            rm -f "$RF_CF" 2>/dev/null || true
            echo "#$PR red-fixer counter $RF_CF was TORN (0 bytes) — reset; NO spawn this cycle (fix-$PR). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "red-fixer counter was torn — reset, nothing spawned this cycle"
            continue
          fi
          # ⛔ RF_N STARTS EMPTY, NOT 0 (review P1, 2026-10-21). Seeding it with 0 made a FAILED read
          # indistinguishable from a fresh counter: the redirect to an unreadable file never populates
          # the variable, the initialiser stood, `is_limit 0` passed, and the lane spawned on every
          # cycle while the increment failed too — an unbounded spawn loop behind a cap that never
          # bound. An existing counter must therefore read as a real number or the role stops.
          # `{ …; } 2>/dev/null` is where the suppression belongs: a redirect FAILURE is reported by
          # the shell, not by `read`, so `read … 2>/dev/null` does not silence it.
          { read -r RF_H RF_N < "$RF_CF"; } 2>/dev/null || true
          if [ -z "${RF_N:-}" ] || ! is_limit "$RF_N"; then
            RF_BAD="the attempt counter is unreadable or not a count ([${RF_N:-<empty>}])"
          fi
        fi
        [ -n "${RF_N:-}" ] || RF_N=0
        # ⛔ REPORT-ONLY MUST NOT FALL INTO THE CAP ARITHMETIC BELOW (review P2, cycle 7, second pass).
        # `MAX_RED_FIX_TRIES=0` makes `0 -ge 0` TRUE, so without this the report-only branch fell
        # straight into the "cap reached" park one line further down — the very park it exists to
        # avoid. The flag made the branch exclusive and testable in one place.
        if [ "${RF_FALLTHROUGH:-0}" = "1" ]; then
          :
        elif [ -n "$RF_BAD" ]; then
          # Novel-only, like every other park site here: this branch is re-entered every cycle until
          # a human repairs the counter, and a repeated identical line is how a real change is missed.
          if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "$HEAD_N" ]; then
            echo "#$PR RED TREE but $RF_BAD — PARKED, no fix-$PR spawned (a counter it cannot read is a cap it cannot keep). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
          fi
          park_ctrl "$PR" "$HEAD_N" "the rail refuses a RED TREE, but $RF_BAD in '$RF_CF', so the per-head cap CANNOT be kept — refusing to spawn blind (fix-$PR, MAX_RED_FIX_TRIES=${MAX_RED_FIX_TRIES:-2}). REPAIR: rm -f '$O/state/redfix-$PR' to restart the budget. REFUSAL (verbatim): ${RF_REASON:-<none recorded>}"
          disp "$PR" "$HEAD_N" "RED-TREE" wait "red-fixer attempt counter is unreadable/corrupt — the per-head cap cannot be kept, so nothing spawned"
        else
          [ "${RF_H:-}" = "$HEAD_N" ] || RF_N=0
          # ⛔ A CROSS-BOX BAIL IS NOT AN ATTEMPT (the same P2 the fixcount refund documents):
          # `fix-one.sh` writes `fixbail-<PR>-<head>` when another box already owns this head, having
          # done NO work. `refund_bailed_fixer` consumes that marker for `fixcount`; this role's own
          # counter must be given back too, or three peer bails park a PR no fixer ever touched.
          # ⛔ ONLY CONSUME A BAIL MARKER WHEN THIS ROLE BOOKED SOMETHING (review P2, cycle 7). The
          # marker is not arm-tagged: a `fixbail` written by a REVIEW-GATE fixer is that arm's own
          # evidence, and that arm is the only party that restores `needsfix-<PR>-<head>` (which it
          # deletes at spawn) by calling this helper with restore=1. Consuming it here with restore=0
          # would silently lose the reviewer's findings and buy a second full-context review — and the
          # helper also un-parks, which from this site would lift a park this role did not write. With
          # `RF_N` at 0 there is nothing of OURS to refund, so the marker is left for its owner.
          RF_BAILED=0
          [ -f "$O/state/fixbail-$PR-$HEAD_N" ] && RF_BAILED=1
          if [ "$RF_BAILED" = "1" ] && [ "$RF_N" -gt 0 ]; then
            refund_bailed_fixer "$PR" "$HEAD_N" 0
            RF_N=$(( RF_N - 1 ))
            printf '%s %s\n' "$HEAD_N" "$RF_N" > "$RF_CF" 2>/dev/null || true
            echo "#$PR red-fixer bailed at head=$HEAD_N (another box holds the claim) — attempt refunded to $RF_N (fix-$PR)" >>"$LOG"
          fi
          # ⛔ A GATE REFUSAL IS NOT AN ATTEMPT (review P1, cycle 3). `fix-one.sh` writes
          # `fixgate-<PR>-<head>` when the load/disk gate refused the agent at the spawn point, so
          # nothing ran. The controller books the per-head attempt at spawn and only this worker knows
          # no agent started — without consuming that marker, two gate refusals (a DISK refusal never
          # clears by waiting, so it is deterministic) reach the cap and park a red PR saying "2 fixer
          # attempt(s) did not clear it", which is false. Consumed once, then refunded.
          # ⛔ RECLAIM UNCONDITIONALLY (review P3, cycle 5). `fix-one.sh` writes this marker on EVERY
          # controller-spawned fixer that the gate refused — including the reviewer-findings, CI-red
          # and conflict arms — so consuming it only inside "the current head's marker exists" left one
          # file per (PR, head) forever for every other arm. One glob per refused PR is cheap; the
          # marker for THIS head is the one whose refund applies.
          RF_HAD_GATE=0
          [ -f "$O/state/fixgate-$PR-$HEAD_N" ] && RF_HAD_GATE=1
          rm -f "$O/state/fixgate-$PR-"* 2>/dev/null || true
          if [ "$RF_HAD_GATE" = "1" ]; then
            if [ "$RF_N" -gt 0 ]; then
              RF_N=$(( RF_N - 1 ))
              printf '%s %s\n' "$HEAD_N" "$RF_N" > "$RF_CF" 2>/dev/null || true
              echo "#$PR red-fixer did not start at head=$HEAD_N (spawn gate refused: load/disk) — per-head attempt refunded to $RF_N (fix-$PR)" >>"$LOG"
            fi
          fi
          # ⛔ THE PER-HEAD BUDGET ALONE IS UNBOUNDED ACROSS HEADS (review P1, cycle 2, 2026-10-21). A
          # fixer that pushes a commit which does NOT clear the tree creates a NEW head, which buys a
          # fresh 2-attempt budget — so `push -> re-refuse -> spawn -> push` would run forever, one lane
          # at a time, while the comment above claimed the role never loops. The fleet already owns the
          # bound for exactly this work: `MAX_FIX_TRIES` on `fixcount-<PR>`, which this role already
          # books (and `fix-one.sh` already refunds on a gate refusal). Reading it here makes the total
          # fixer spend per PR bind across heads, whichever arm spent it.
          RF_FN_NOW=""; RF_FN_BAD=""
          if [ -f "$O/state/fixcount-$PR" ]; then
            RF_FN_NOW="$(cat "$O/state/fixcount-$PR" 2>/dev/null)"
            # ⛔ is_limit, NOT is_num, AND NOT A RESET (review P2, cycle 5). This value feeds
            # `[ … -ge … ]`; a 20-digit string makes that test ERROR (false on bash 3.2) while
            # `is_num` calls it valid. Resetting a corrupt TOTAL to 0 would be the same fail-open the
            # per-head counter refuses a few lines up (this role would then be bounded by nothing
            # across heads), so it fails CLOSED like that one does: park, with the cause named.
            is_limit "${RF_FN_NOW:-}" || RF_FN_BAD="its total fixer counter (state/fixcount-$PR) is unreadable or not a count ([${RF_FN_NOW:-<empty>}])"
          fi
          [ -n "${RF_FN_NOW:-}" ] || RF_FN_NOW=0
          if [ -n "$RF_FN_BAD" ]; then
            if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "$HEAD_N" ]; then
              echo "#$PR RED TREE but $RF_FN_BAD — PARKED, no fix-$PR spawned (a total the role cannot read is a bound it cannot keep). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            fi
            park_ctrl "$PR" "$HEAD_N" "the rail refuses a RED TREE, but $RF_FN_BAD, so the ACROSS-HEADS cap (MAX_FIX_TRIES) cannot be kept — refusing to spawn (fix-$PR). REPAIR: rm -f '$O/state/fixcount-$PR' to restart the total budget. REFUSAL (verbatim): ${RF_REASON:-<none recorded>}"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "total fixer counter is unreadable/corrupt — the across-heads cap cannot be kept, so nothing spawned"
          elif [ "$RF_FN_NOW" -ge "${MAX_FIX_TRIES:-3}" ]; then
            if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "$HEAD_N" ]; then
              echo "#$PR RED TREE and $RF_FN_NOW fixer attempt(s) spent on this PR in total (MAX_FIX_TRIES=${MAX_FIX_TRIES:-3}, across heads) — PARKED, needs a human (fix-$PR). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            fi
            park_ctrl "$PR" "$HEAD_N" "rail refused a RED TREE and $RF_FN_NOW fixer attempt(s) have been spent on this PR in total (MAX_FIX_TRIES=${MAX_FIX_TRIES:-3}, across heads) — a further fixer push would be the same repair again. REFUSAL (verbatim): ${RF_REASON:-<none recorded>} -- a human must decide; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR' '$O/state/fixcount-$PR'"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "parked: $RF_FN_NOW fixer attempt(s) spent in total (MAX_FIX_TRIES) and the tree is still red"
          elif [ "${RF_SURF:-}" != "RED" ]; then
            # NO MEASUREMENT, NO LANE — and the test is `!= RED`, not `= UNKNOWN` (review P2, cycle 3).
            # `head_reds` prints NOTHING when python3 is missing or crashes, and an empty value is not
            # the string UNKNOWN: keyed on the positive name, that case fell straight through to the
            # spawn and spent an attempt on a tree it had never read. Allow-list polarity — the same
            # rule the check classifiers use. An unreadable surface (a gh blip) or a check still in
            # flight is not evidence that a fixer could help: the refusal is kept and the next cycle
            # re-reads.
            echo "#$PR RED TREE refusal stands at head=$HEAD_N, but the check surface is not measurable yet (${RF_SURF:-UNKNOWN}) — no fix-$PR spawned, attempt $RF_N/${MAX_RED_FIX_TRIES:-2} NOT consumed. REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "check surface unreadable or in flight — the refusal stands, nothing spawned yet"
          elif [ "$RF_N" -ge "${MAX_RED_FIX_TRIES:-2}" ]; then
            # (3) BOUNDED, THEN REPORTED. The refusal is kept (it is the evidence a human needs), the
            # park carries its VERBATIM line, and the loop stops — the role never retries a head that
            # its own budget says it cannot repair.
            # The LOG line is NOVEL-ONLY (evaluated before the write, like the other park sites in this
            # file): this branch is reached on every cycle until a push re-arms the head, and a repeated
            # identical line is how a real change gets missed.
            if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "$HEAD_N" ]; then
              echo "#$PR RED TREE after $RF_N red-fixer attempt(s) at head=$HEAD_N — PARKED, needs a human (fix-$PR, MAX_RED_FIX_TRIES=${MAX_RED_FIX_TRIES:-2}). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            fi
            park_ctrl "$PR" "$HEAD_N" "rail refused a RED TREE and $RF_N red-fixer attempt(s) at this head did not clear it (MAX_RED_FIX_TRIES=${MAX_RED_FIX_TRIES:-2}). REFUSAL (verbatim): ${RF_REASON:-<none recorded>} -- a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR' '$O/state/railrefusal-$PR' '$O/state/redfix-$PR' '$O/state/fixcount-$PR'"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "parked: the rail still refuses a RED TREE after $RF_N fixer attempt(s) at this head"
          elif sess "fix-$PR" || sess "merge-$PR" || claim_live "$PR" "$HEAD_N"; then
            # (2) EXACTLY ONE LIVE FIXER PER PR. The key is the PR number in the session/lock name, so a
            # second refusal while a fixer works spawns NOTHING (a second lane is how two workers push
            # to one branch).
            echo "#$PR RED TREE at head=$HEAD_N — a worker already owns this PR (fix-$PR/merge-$PR live, or the cross-box claim holds it), NOT spawning a second (attempt $RF_N/${MAX_RED_FIX_TRIES:-2} spent). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "a worker already owns this PR — the rail refusal stands at this head"
          elif [ "$(wt_count fix-)" -lt "${MAX_RED_FIX:-4}" ] && can_spawn; then
            # (1) THE SPAWN. Through the launcher (`wt_spawn`), so on a cell the red-fixer gets a
            # daemon-owned DURABLE TERMINAL exactly like every other worker — a tmux window or a
            # transient `cloud exec` child dies at ~21 log lines (measured on all three cells, see
            # `worker-terminal.sh`'s header), and a dead red-fixer is indistinguishable from one that
            # found nothing to fix. Args go in a FILE so no PR-derived value reaches `sh -c`, and
            # `fix-one.sh` — which materialises the branch's OWN worktree from origin, captures the
            # failing checks and their logs, and re-runs the merge chain (which re-rails) when it
            # pushes. A red-fixer never runs in the hub checkout: the fixer script cd's into the
            # worktree and its prompt says so.
            #
            # (6) THE MODEL/PROVIDER IS EXPLICIT AND NOT AMBIENT. The one gated `pi` invocation
            # (`spawn-gate.sh`'s run_agent) names `--provider deepseek --model deepseek-v4-flash`
            # (#2208). ⛔ The image's OPENAI_API_KEY is unset HERE because it otherwise shadows provider
            # selection (#2208 family): an ambient credential silently outranks the pin, and the lane
            # then runs on a provider nobody configured.
            #
            # ⛔ BOTH COUNTERS ARE BOOKED *BEFORE* THE SESSION EXISTS (review P2, cycle 4). Booking
            # after the spawn raced the fixer: the lane is already running when the controller reads
            # `fixcount`, so a fixer that reached its gate first decremented it and the controller then
            # OVERWROTE that refund with the pre-refusal value — losing the refund, and eventually
            # parking a PR that never had an agent run. A failed spawn is synchronous and observable,
            # so it rolls both back exactly (below), which preserves "a failed spawn consumes no
            # attempt".
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            RF_FC="$O/state/fixcount-$PR"; RF_FN="$(cat "$RF_FC" 2>/dev/null || echo 0)"
            is_num "$RF_FN" || RF_FN=0
            RF_BOOK=$(( RF_N + 1 ))
            if printf '%s %s\n' "$HEAD_N" "$RF_BOOK" > "$RF_CF" 2>/dev/null \
               && printf '%s\n' "$(( RF_FN + 1 ))" > "$RF_FC" 2>/dev/null; then
              if wt_spawn "fix-$PR" "$SPAWN_CWD" "unset OPENAI_API_KEY OPENAI_BASE_URL; bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'"; then
                RF_N="$RF_BOOK"
                # (7) PR NUMBER, the refusal VERBATIM, the attempt counter and the session name, in ONE
                # line: an operator reading this log must not have to join three files to learn why a
                # lane exists.
                # agent-infra#2215 rule 3: a lane spawned from a checkout that is BEHIND origin/main must
                # carry that fact on the SPAWN line (the `disp` row already carries it — this is the log).
                echo "#$PR RED TREE -> fix-$PR spawned (attempt $RF_N/${MAX_RED_FIX_TRIES:-2} at head=$HEAD_N)${HARNESS_TOKEN:+ [harness=$HARNESS_TOKEN]}. REFUSAL: ${RF_REASON:-<none recorded>}${RF_DETAIL:+ | $RF_DETAIL}" >>"$LOG"
                disp "$PR" "$HEAD_N" "RED-TREE" act "red-fixer fix-$PR spawned (attempt $RF_N/${MAX_RED_FIX_TRIES:-2})"
              else
                # ROLL BOTH BACK: nothing ran, so nothing may be consumed.
                printf '%s %s\n' "$HEAD_N" "$RF_N" > "$RF_CF" 2>/dev/null || rm -f "$RF_CF" 2>/dev/null || true
                printf '%s\n' "$RF_FN" > "$RF_FC" 2>/dev/null || true
                echo "#$PR RED TREE, fix-$PR spawn FAILED (attempt not consumed — nothing ran; both counters rolled back). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
                disp "$PR" "$HEAD_N" "RED-TREE" wait "red-fixer spawn FAILED (attempt not consumed)"
              fi
            else
              # ⛔ THE BOOKING IS THE CAP. A spawn whose attempt cannot be recorded is exactly the
              # unbounded loop the cap exists to prevent, so the role stops here instead of spawning.
              if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "$HEAD_N" ]; then
                echo "#$PR RED TREE, and the attempt counters could not be written ('$RF_CF'/'$RF_FC') — PARKED, NO fix-$PR spawned (the cap cannot be kept). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
              fi
              park_ctrl "$PR" "$HEAD_N" "the rail refuses a RED TREE, but this role's attempt counters could not be written ('$RF_CF'/'$RF_FC'), so the cap cannot be kept — refusing to spawn blind (fix-$PR). REPAIR: free space / fix permissions on '$O/state'. REFUSAL (verbatim): ${RF_REASON:-<none recorded>}"
              disp "$PR" "$HEAD_N" "RED-TREE" wait "attempt counters unwritable — the cap cannot be kept, so nothing spawned"
            fi
          else
            # (3) THE BOX CAP. Nothing is consumed: the refusal stays, the next cycle retries when a
            # slot frees, and the reason names the ceiling AND the load gate (the silent-capacity-refusal
            # shape #2126 T5 removed from the other five sites).
            echo "#$PR RED TREE but NO red-fixer slot (fix lanes=$(wt_count fix-)/${MAX_RED_FIX:-4}, load-gate=L/${MAX_LOAD:-?}) — attempt $RF_N/${MAX_RED_FIX_TRIES:-2} NOT consumed, no fix-$PR. REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "capacity: red-fixer ceiling ${MAX_RED_FIX:-4} reached or the spawn gate refused"
          fi
        fi
        # ⛔ ONE `continue`, GATED (review P2, cycle 6): every ACTING/WAITING/PARKING branch owns the
        # PR for the cycle, but the report-only branch must hand it back to the ordinary arms.
        [ "${RF_FALLTHROUGH:-0}" = "1" ] || continue
      fi
    fi
    # [redfix:end]
    # parked = the fixer cap was reached at THIS head; a later push re-arms the PR.
    [ -n "${HEAD_N:-}" ] && [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" = "$HEAD_N" ] && { disp "$PR" "$HEAD_N" - wait "parked at this head — needs a human"; continue; }
    # Authority UNKNOWN (unreadable branch protection, above): no merge, no auto-arm, no worker
    # spawns — the one action worse than doing nothing here would be acting on a contract this
    # repo never declared (review P2, round 1).
    [ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && { disp "$PR" "${HEAD_N:-}" - wait "merge authority UNREADABLE this cycle (fail-closed: nothing spawned)"; continue; }
    V="$(gh pr checks "$PR" --repo "$OR" --json name,state,workflow 2>/dev/null | REQ="$REQ" REVIEW_GATE="$REVIEW_GATE" python3 -c "
import sys,json
import os
try: d=json.load(sys.stdin)
except Exception: print('NOCHECKS'); raise SystemExit
# The source is either the check-runs API shape (an object carrying a check_runs list) or the flat
# list \`gh pr checks --json\` prints. Both normalise to one row list; anything else is unreadable.
rows=d.get('check_runs') if isinstance(d,dict) else d
if not isinstance(rows,list): print('NOCHECKS'); raise SystemExit
want=(os.environ.get('REQ') or '').split()
# ⛔ ALLOW-LISTS, NEVER A DENY-LIST (agent-infra#1714). A conclusion is NON-RED only if it is NAMED
# here - the identical five spellings admin-merge.sh (NON_RED_CONC) and record-review.sh
# (target_head_red) use, so the harness and the merge rail cannot disagree. 'not in the red set' is
# not a synonym for non-red: a token this code has never seen (a vendor adds a conclusion, GitHub
# returns a newer spelling, the value is null) must FAIL CLOSED, so it is RED. The deny-list this
# replaced named the red tokens and filed EVERYTHING ELSE as PENDING, so an unrecognised or NULL
# conclusion reached \`gh pr merge --auto\` instead of blocking - the fail-open the issue is about.
NONRED=('success','neutral','skipped','cancelled','stale')
# IN FLIGHT means a status the API NAMES as in flight - the same five the rail uses. Any OTHER
# non-completed spelling is judged by its CONCLUSION under the allow-list, so an unrecognised status
# with a null conclusion is RED, not pending (the rail's #1353 fail-open shape, closed the same
# way). \`expected\` is deliberately NOT here: it is not a named in-flight spelling, so a check
# GitHub has announced but not reported reads RED - the fail-closed direction, matching the rule.
INFLIGHT=('queued','in_progress','waiting','requested','pending')
# One entry per (app, name) - NOT per name: a same-named check under two apps must not let one
# app's result mask the other's (agent-infra#1714). \`app.slug\` when the source supplies it (the
# check-runs API), otherwise the workflow name (\`gh pr checks\` exposes no app field), and the
# NEWEST attempt by id when the source supplies one. Ties, and sources with no id at all, take the
# last row seen - all the information \`gh pr checks\` carries.
groups={}
for c in rows:
    if not isinstance(c,dict): continue
    name=str(c.get('name') or '')
    app=c.get('app')
    if isinstance(app,dict): app=app.get('slug') or ''
    if not app: app=c.get('workflow') or ''
    try: cid=int(c.get('id') or c.get('databaseId') or 0)
    except Exception: cid=0
    if 'status' in c or 'conclusion' in c:
        status=str(c.get('status') or '').lower(); concl=str(c.get('conclusion') or '').lower()
    else:
        st=str(c.get('state') or '').lower()
        status,concl=(st,'') if st in INFLIGHT else ('completed',st)
    k=(str(app),name)
    prev=groups.get(k)
    if prev is None or cid>=prev[0]: groups[k]=(cid,status,concl)
rank={'nonred':0,'pending':1,'red':2}
# The repo's review-gate NAME is an INPUT (agent-infra#1764), not the literal 'ai-review-gate'.
# It is read from the env the bash side passes in, with the same default repo-authority.sh uses.
rgate=os.environ.get('REVIEW_GATE') or 'ai-review-gate'
named={}
gate=[]
for k in groups:
    status=groups[k][1]; concl=groups[k][2]
    v='pending' if status in INFLIGHT else ('nonred' if concl in NONRED else 'red')
    if k[1]==rgate: gate.append((v,concl))
    if k[1] not in named or rank[v]>rank[named[k[1]]]: named[k[1]]=v
# THE REVIEW GATE IS THE MERGE AUTHORITY **WHERE THE REPO REQUIRES IT**, so it must be an explicit
# SUCCESS there. SKIPPED/NEUTRAL means no signed review exists; reading that as satisfied would
# merge without evidence. This is also why GREEN always carries at least one MEASURING success: a
# surface of nothing but cancelled/stale/skipped/neutral rows can never read green - those are
# non-red, never green.
# ⛔ SCOPED BY 'rgate in want', WHICH IS THE WHOLE POINT (#1764). On a repo whose protection does
# not require the gate (agent-infra), the name is NOT in 'want' and the rule below never fires -
# otherwise its ABSENCE forced RED and deadlocked the queue. The rule is NOT weakened: on tortoise
# the gate IS required, so a missing/red/skipped gate still blocks exactly as before. The
# fail-closed posture is unchanged and stays INSIDE the repo's own required set.
gate_ok=len(gate)>0 and all(v=='nonred' and c=='success' for v,c in gate)
# Read it in this order: RED if any required check is red (a completed red is final - nothing in
# flight can un-fail it); otherwise NOT YET KNOWN while any is in flight or never reported;
# otherwise GREEN. An EMPTY surface is NOCHECKS, never GREEN - a missing check is not a green check,
# and NOCHECKS reaches neither the merge nor the fixer arm below.
fail=[n for n in want if named.get(n)=='red']
pend=[n for n in want if named.get(n)=='pending' or n not in named]
if rgate in want and not gate_ok and rgate not in fail: fail.insert(0,rgate)
print('NOCHECKS' if not groups else ('FAILED:'+','.join(fail) if fail else ('PENDING:'+','.join(pend) if pend else ('GREEN' if want else 'NOCHECKS'))))
" 2>/dev/null)"
    # ── the class cache the NEXT cycle's ordering reads (see lo_order) ─────────────
    # Written from the observation this loop just made, one row per PR per cycle; lo_class_compact
    # folds it at the top of the next cycle. It decides ONLY which PR gets a scarce fixer/reviewer
    # slot — never whether a PR is worked or merged.
    case "${V:-}" in
      GREEN)   _cl=GREEN ;; PENDING:*) _cl=PENDING ;; FAILED:*) _cl=RED ;; *) _cl=NOCHECKS ;;
    esac
    printf '%s\t%s\t%s\n' "$PR" "${HEAD_N:-}" "$_cl" >> "$O/state/prclass.tsv" 2>/dev/null || true
    # A CONFLICTING PR can never merge: `gh pr merge` fails every cycle and the queue looks stuck
    # while nothing changes. Route it to the fixer, which integrates origin/main and resolves the
    # conflict, then re-runs the review chain. Capped and parkable like any other fix loop.
    # [conflict-case:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
    case "$V" in
      GREEN|PENDING:*)
        MSTAT="$(gh pr view "$PR" --repo "$OR" --json mergeable --jq .mergeable 2>/dev/null)"
        if [ "${MSTAT:-}" = "CONFLICTING" ]; then
          # A bailed fixer must not have consumed an attempt here (P2, second review round).
          refund_bailed_fixer "$PR" "${HEAD_N:-}" 0
          CF="$O/state/fixcount-$PR"; NFC="$(cat "$CF" 2>/dev/null || echo 0)"
          is_num "$NFC" || NFC=0
          if [ "$NFC" -ge "${MAX_FIX_TRIES:-3}" ]; then
            # Unconditional park write (review P1, round 1, same class as merge-one's rail park):
            # a park left by a previous head must be REFRESHED or the new head never parks. The log
            # line stays novel-only (evaluated BEFORE the write) so the log does not repeat.
            if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "${HEAD_N:-}" ]; then
              echo "#$PR PARKED (still CONFLICTING after $NFC fixes)" >>"$LOG"
            fi
            park_ctrl "$PR" "${HEAD_N:-}" "still CONFLICTING after $NFC fixes (MAX_FIX_TRIES=$MAX_FIX_TRIES) -- a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
            disp "$PR" "${HEAD_N:-}" CONFLICTED wait "parked: still conflicted after $NFC fixes — needs a human"
          elif claim_live "$PR" "${HEAD_N:-}" || sess "fix-$PR" || sess "merge-$PR"; then
            : # a worker is already rebasing it
            disp "$PR" "${HEAD_N:-}" CONFLICTED wait "a worker already owns this PR"
          elif [ "$(wt_count fix-)" -lt "$MF" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            if wt_spawn "fix-$PR" "$SPAWN_CWD" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'"; then
              echo $((NFC + 1)) > "$CF"
              echo "#$PR CONFLICTING -> fixer attempt $((NFC + 1))" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" CONFLICTED act "conflict fixer spawned (attempt $((NFC + 1)))"
            else
              echo "#$PR CONFLICTING, fixer spawn FAILED" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" CONFLICTED wait "conflict fixer spawn FAILED"
            fi
          else
            # ⛔ THE SILENT REFUSAL (#2126 T5). Five capacity sites used to test their ceiling in an
            # `elif` with no `else`, so a saturated box logged NOTHING and `lanes=0` was unexplained.
            echo "#$PR CONFLICTING but NO fixer slot (fix lanes=$(wt_count fix-)/$MF, load-gate=L/${MAX_LOAD:-?})" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" CONFLICTED wait "capacity: fix-lane ceiling $MF reached or the spawn gate refused"
          fi
          continue
        fi ;;
    esac
    # [conflict-case:end]
    # [acting-case:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
    case "$V" in
      GREEN)
        gh pr ready "$PR" --repo "$OR" >/dev/null 2>&1 || true
        if [ "$MERGE_AUTHORITY" = "rail" ]; then
          # RAIL MODE (agent-infra#1764). The repo does NOT require the review gate, so the merge
          # authority is its own rail (scripts/admin-merge.sh), which computes head-bound evidence
          # and merges. We NEVER call `gh pr merge` here: on this repo it would land the PR on the
          # required checks alone, bypassing the rail — the bypass agent-infra's AGENTS.md forbids.
          #
          # IT RUNS IN A WORKER, NOT INLINE. MEASURED 2026-10-15: one rail run on a green
          # agent-infra PR (#1763, all 22 checks non-red) takes ~27s even with --dry-run --no-rerun,
          # and the rail's re-run path waits for a re-run to finish. Inline, a 30-PR drain is ~13
          # minutes of a BLOCKED controller cycle with dispatch halted — the very starvation this
          # issue is about. The worker is single-owner (merge-one.sh's local lock + cross-box claim)
          # and slot- and load-gated like every other spawn.
          if sess "merge-$PR" || claim_live "$PR" "${HEAD_N:-}"; then
            : # a rail worker already owns this PR
            disp "$PR" "${HEAD_N:-}" GREEN wait "a rail worker already owns this PR"
          elif [ "$(wt_count merge-)" -lt "$MR" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            # ⚠️ carry the RESOLVED contract into the worker (review P2, round 1): the controller
            # resolved REQ/REVIEW_GATE for THIS cycle, but a worker that re-resolves independently
            # can disagree (e.g. an operator REVIEW_GATE the tmux server does not export) and merge
            # under a different authority than the one that classified the PR. Passing the resolved
            # set as the worker's REQ makes it the override — one resolution, one authority.
            # ⛔ shq, never %q: `%q` emits `$'…'` for a non-printable byte and dash does not parse
            # that as quoting, so the value would execute (round-8 adversarial review, B6).
            if wt_spawn "merge-$PR" "$SPAWN_CWD" "REQ=$(shq "$REQ") REVIEW_GATE=$(shq "$REVIEW_GATE") bash '$O/merge-one.sh' --argv '$O/state/argv-$PR'"; then
              echo "#$PR GREEN -> rail worker merge-$PR" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" GREEN act "rail worker merge-$PR spawned"
            else
              echo "#$PR GREEN but the rail worker spawn FAILED" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" GREEN wait "rail worker spawn FAILED"
            fi
          else
            echo "#$PR GREEN but NO merge slot (merge lanes=$(wt_count merge-)/$MR, load-gate=L/${MAX_LOAD:-?})" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" GREEN wait "capacity: merge-lane ceiling $MR reached or the spawn gate refused"
          fi
        elif [ "$MERGE_AUTHORITY" = "gate" ]; then
          # ⛔ EXPLICIT `gate` ONLY (round-10 review, P2). This arm used to be a bare `else`, so
          # ANY authority that was not `rail` — INCLUDING `unknown` — reached a RAW `gh pr merge`,
          # the exact bypass this whole change exists to prevent. Allow-list polarity: a raw merge
          # happens only on an authority that NAMES the gate.
          if gh pr merge "$PR" --repo "$OR" --squash >>"$LOG" 2>&1; then
            echo "#$PR MERGED" >>"$LOG"; disp "$PR" "${HEAD_N:-}" GREEN act "merged (gate authority)"
          else
            echo "#$PR merge fail" >>"$LOG"; disp "$PR" "${HEAD_N:-}" GREEN wait "gate-authority merge FAILED (retried next cycle)"
          fi
        else
          echo "#$PR GREEN but the merge authority is '${MERGE_AUTHORITY:-<unset>}' — NO merge (fail-closed: only an explicit 'gate' or 'rail' authority may merge)" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" GREEN wait "merge authority '${MERGE_AUTHORITY:-<unset>}' is neither gate nor rail (fail-closed)"
        fi ;;
      PENDING:*)
        gh pr ready "$PR" --repo "$OR" >/dev/null 2>&1 || true
        if [ "$MERGE_AUTHORITY" = "gate" ]; then
          if gh pr merge "$PR" --repo "$OR" --squash --auto >>"$LOG" 2>&1; then
            echo "#$PR auto-armed" >>"$LOG"; disp "$PR" "${HEAD_N:-}" "$V" act "auto-merge armed (gate authority)"
          else
            disp "$PR" "${HEAD_N:-}" "$V" wait "auto-merge arm FAILED (retried next cycle)"
          fi
        else
          # RAIL MODE: `--auto` must NOT be armed. It merges the moment the REPO'S required checks
          # pass, which on a rail-managed repo bypasses the rail entirely — the same bypass the
          # GREEN arm avoids. Wait for the next cycle; once every required check is non-red the
          # GREEN arm dispatches the rail.
          echo "#$PR PENDING (rail mode: auto-merge deliberately NOT armed — arming it would bypass the rail)" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" "$V" wait "waiting: checks pending (rail mode — auto-merge deliberately not armed)"
        fi ;;
      FAILED:*)
        echo "#$PR $V" >>"$LOG"
        # Which red names are REQUIRED checks other than the review gate? Derived from the
        # classifier's own output and from THIS repo's required set ($REQ) — never from a literal
        # name list. The arm below used to name tortoise's five doc/CI checks, so a red
        # `pipeline-compliance` on agent-infra matched NOTHING and the PR sat red with no worker at
        # all: the same repo-dependent-constant defect as the required-check list (#1764).
        # ⚠️ review P2, round 1: the pre-#1764 arm deliberately EXCLUDED python-ci-gate — the
        # rerun block at the bottom of this case owns it, and routing a flaky CI lane into the
        # code-pushing fixer is churn the rerun already handles. RERUN_RED names that one check
        # (the same name the rerun block greps for); a repo that does not carry it is unaffected
        # and every OTHER required red name still reaches the fixer — including agent-infra's
        # pipeline-compliance, which the old literal arm could not match at all.
        RERUN_RED="python-ci-gate"
        CI_RED=""
        _redifs="$IFS"; IFS=','; set -f
        for _rn in ${V#FAILED:}; do
          [ -n "$_rn" ] || continue
          [ "$_rn" = "$REVIEW_GATE" ] && continue
          [ "$_rn" = "$RERUN_RED" ] && continue
          case " $REQ " in *" $_rn "*) CI_RED="$_rn"; break ;; esac
        done
        set +f; IFS="$_redifs"
        # Whole-NAME gate test (review P2, round 2): `grep -qF` matched a SUBSTRING, so a
        # REVIEW_GATE that is a substring of another red required check (compliance vs
        # pipeline-compliance) misrouted that check into the review arm instead of the CI fixer
        # that fetches its failing log — while merge_authority and CI_RED test whole names.
        _gate_hit=0; _gifs="$IFS"; IFS=','; set -f
        for _vn in ${V#FAILED:}; do
          [ "$_vn" = "$REVIEW_GATE" ] && _gate_hit=1
        done
        set +f; IFS="$_gifs"
        if [ "$_gate_hit" = "1" ]; then
          # A bailed fixer must not have consumed an attempt, and this arm DELETED the findings
          # marker at spawn — so restore it too (P2, second review round).
          refund_bailed_fixer "$PR" "${HEAD_N:-}" 1
          # The claim file is written by merge-one.sh itself, so it also covers the chain-<N>
          # path (which invokes merge-one.sh directly and whose session name is invisible here).
          if claim_live "$PR" "${HEAD_N:-}" || sess "fix-$PR" || sess "merge-$PR"; then
            : # this PR already has a worker in flight
            disp "$PR" "${HEAD_N:-}" "$V" wait "a worker already owns this PR"
          else
            FIXN="$O/state/fixcount-$PR"; NF="$(cat "$FIXN" 2>/dev/null || echo 0)"
            is_num "$NF" || NF=0
            # a reviewer already reported real issues AT THIS HEAD -> fix them and re-run the chain.
            # otherwise the gate is probably just missing evidence -> re-record (fresh review).
            if [ -n "${HEAD_N:-}" ] && [ -f "$O/state/needsfix-$PR-$HEAD_N" ] \
               && [ "$NF" -lt "${MAX_FIX_TRIES:-3}" ] \
               && can_spawn \
               && [ "$(wt_count fix-)" -lt "$MF" ]; then
              # Spawn FIRST, bookkeep only on success: recording the attempt before the spawn
              # means a killed/failed spawn consumes one of MAX_FIX_TRIES and deletes the
              # findings marker, so no fixer ever runs and the findings are lost.
              # Args travel in a file, not interpolated into the tmux command string, so no
              # PR-derived value can reach `sh -c`. Only $O (validated at startup) and the
              # numeric $PR are embedded.
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              if wt_spawn "fix-$PR" "$SPAWN_CWD" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'"; then
                echo $((NF + 1)) > "$FIXN"; rm -f "$O/state/needsfix-$PR-$HEAD_N"
                echo "#$PR fixer attempt $((NF + 1))" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" act "review-gate fixer spawned (attempt $((NF + 1)))"
              else
                echo "#$PR fixer spawn FAILED (attempt not consumed, marker kept)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "review-gate fixer spawn FAILED (attempt not consumed)"
              fi
            elif [ "$NF" -ge "${MAX_FIX_TRIES:-3}" ] && [ -f "$O/state/needsfix-$PR-$HEAD_N" ]; then
              # Terminal state. Without this the cap just falls through to the re-record branch
              # every cycle: an unfixable PR would burn a full fresh-context review forever.
              park_ctrl "$PR" "${HEAD_N:-}" "still needs fixes after $NF attempts at head=${HEAD_N:-?} (MAX_FIX_TRIES=$MAX_FIX_TRIES) -- a human must decide; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
              echo "#$PR PARKED after $NF fixes at head=${HEAD_N:-?} — needs a human" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "parked: still needs fixes after $NF attempts — needs a human"
            elif [ "$(wt_count merge-)" -lt "$MR" ] && can_spawn; then
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              # Same carried contract as the GREEN rail spawn above (review P2, round 1), and the
              # same shq rule as there: `%q` is dash-unsafe (round-8 adversarial review, B6).
              # ⛔ A SPAWN THAT DID NOT HAPPEN MUST SAY SO (#2126 T1). This line was `tmux … && echo`,
              # so a FAILED re-record spawn was completely unremarked — the PR looked idle with no
              # reason. Every other spawn site in this file has an explicit failure branch.
              if wt_spawn "merge-$PR" "$SPAWN_CWD" "REQ=$(shq "$REQ") REVIEW_GATE=$(shq "$REVIEW_GATE") bash '$O/merge-one.sh' --argv '$O/state/argv-$PR'"; then
                echo "#$PR re-record" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" act "re-record worker merge-$PR spawned (fresh review)"
              else
                echo "#$PR re-record spawn FAILED (no review worker started this cycle)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "re-record spawn FAILED"
              fi
            else
              echo "#$PR $V but NO re-record slot (review lanes=$(wt_count merge-)/$MR, load-gate=L/${MAX_LOAD:-?})" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "capacity: review-lane ceiling $MR reached or the spawn gate refused"
            fi
          fi
        elif [ -n "$CI_RED" ]; then
          # CI-red arm (agent-infra#1764: derived from the repo's required set, not a name list)
          # A required check OTHER than the review gate is red — docs lint, a committed conflict
          # marker, legal-e2e, test isolation, or agent-infra's `pipeline-compliance`. Nothing
          # re-recorded or reran those, so such a PR sat red forever with no worker at all
          # (observed: #8278 carried two docs-lint findings — MD056, an unescaped '|' in a table
          # row, and MD046, fence style; #8193 a new MD018 finding; both had zero workers for
          # hours). Route them to the fixer, which now also receives the failing CI log, capped
          # like every other fix loop.
          # ⛔ THE REFUND MUST PRECEDE THE READ (P2, third review round, 2026-10-14). The CONFLICTING
          # arm above and the ai-review-gate arm below both read the count AFTER the refund; this arm
          # read it BEFORE, so the decrement was immediately overwritten by `$NFC2 + 1` and the refund
          # was a NO-OP here. fix-one.sh exits 0 — having done no work — when the cross-box CAS
          # refuses it, so three no-op cross-box refusals still PARKED the PR as needs-a-human,
          # exactly the defect the previous round claimed to close. Keep this ordering; selftest §15
          # drives the shipped sequence and goes RED if the read moves back above the refund.
          # A bailed fixer must not have consumed an attempt here. This arm never deleted a findings
          # marker, so restore is 0 (P2, second review round).
          refund_bailed_fixer "$PR" "${HEAD_N:-}" 0
          NFC2="$(cat "$O/state/fixcount-$PR" 2>/dev/null || echo 0)"
          is_num "$NFC2" || NFC2=0
          if [ "$NFC2" -ge "${MAX_FIX_TRIES:-3}" ]; then
            # Unconditional park write (review P1, round 1, same class as merge-one's rail park).
            # The log line stays novel-only (evaluated BEFORE the write) so the log does not repeat.
            if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "${HEAD_N:-}" ]; then
              echo "#$PR PARKED (CI still red after $NFC2 fixes: $V)" >>"$LOG"
            fi
            park_ctrl "$PR" "${HEAD_N:-}" "CI still red after $NFC2 fixes: $V -- a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
            disp "$PR" "${HEAD_N:-}" "$V" wait "parked: CI still red after $NFC2 fixes — needs a human"
          elif claim_live "$PR" "${HEAD_N:-}" || sess "fix-$PR" || sess "merge-$PR"; then
            : # a worker is already on it
            disp "$PR" "${HEAD_N:-}" "$V" wait "a worker already owns this PR"
          elif [ "$(wt_count fix-)" -lt "$MF" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            if wt_spawn "fix-$PR" "$SPAWN_CWD" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'"; then
              echo $((NFC2 + 1)) > "$O/state/fixcount-$PR"
              echo "#$PR CI-red ($V) -> fixer attempt $((NFC2 + 1))" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" act "CI-red fixer spawned (attempt $((NFC2 + 1)))"
            else
              echo "#$PR CI-red, fixer spawn FAILED" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "CI-red fixer spawn FAILED"
            fi
          else
            echo "#$PR CI-red ($V) but NO fixer slot (fix lanes=$(wt_count fix-)/$MF, load-gate=L/${MAX_LOAD:-?})" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "capacity: fix-lane ceiling $MF reached or the spawn gate refused"
          fi
        else
          # ⛔ THE FOURTH DANGLING CASE (#2126 T2, found by the drive): a PR is RED, but no red name in
          # `$V` is a REQUIRED check for this repo (or python-ci-gate, which the rerun owns) — so
          # neither arm fires and nothing is printed. The PR is still counted un-owned, so it holds the
          # issue path shut while the log says nothing about it. Not acting is right (a non-required red
          # is not this box's work); being SILENT about it is the defect.
          echo "#$PR $V — no arm: no red check in this class is in this repo's required set (REQ='$REQ'); nothing spawned" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" "$V" wait "red checks are not in this repo's required set — nothing to act on"
        fi
        # ⛔ THE RERUN IS A SECOND ACTUATOR ON THE SAME PR (#2126, residual T3). It sits AFTER the
        # arm chain, so `FAILED:ai-review-gate,python-ci-gate` spawns a fixer AND reruns CI in one
        # cycle. Dropping one of them is a PRECEDENCE DECISION (rerun-first vs fixer-first), not an
        # honesty repair, so this change does NOT take it: both still fire, but the double act is now
        # SAID OUT LOUD instead of being invisible. The PR keeps its ONE disposition row (the arm
        # already wrote it) — a second `act` row would make the cycle's act count exceed the number
        # of units actually spawned, which is the arithmetic this sidecar exists to keep closed.
        if grep -q python-ci-gate <<<"$V"; then
          RID="$(gh pr checks "$PR" --repo "$OR" --json name,link --jq '.[]|select(.name=="python-ci-gate")|.link' 2>/dev/null | sed -nE 's#.*/runs/([0-9]+).*#\1#p')"
          if [ -n "${RID:-}" ] && [ ! -f "$O/state/rerun-$PR-$RID" ]; then
            if gh run rerun "$RID" --repo "$OR" --failed >>"$LOG" 2>&1; then
              touch "$O/state/rerun-$PR-$RID"; echo "#$PR rerun CI" >>"$LOG"
              _prior="$(awk -F'\t' -v p="$PR" '$1==p && $4=="act"{printf "%s", $5}' "$PRDISP" 2>/dev/null | tail -1)"
              if [ -n "${_prior:-}" ]; then
                echo "#$PR DOUBLE ACT this cycle: [${_prior}] + CI rerun — precedence undecided, see #2126" >>"$LOG"
              fi
              # ONE ROW: the rerun SUPERSEDES any wait the arm above wrote for this PR (an earlier
              # version appended a second row, which reported two PRs for one and let a zero-spawn
              # cycle print `1 acted`).
              dispreplace "$PR" "${HEAD_N:-}" "$V" act "CI rerun dispatched (run $RID)"
            fi
          fi
        fi ;;
      *)
        # ⛔ THE DANGLING CLASS (#2126 T4). `NOCHECKS` (an empty check surface, or an unreadable
        # `gh pr checks` — the pipeline's stderr is discarded, so a FAILED read and an empty surface
        # both arrive here) used to reach NO arm: no merge, no fixer, and not one line. A PR could
        # therefore hold the issue path shut while the log said nothing at all about it.
        # ⛔ WAIT-ONLY: this arm must never spawn. `NOCHECKS` is not evidence of health (an empty
        # surface is never GREEN in this file) and it is not evidence of breakage either, so the only
        # honest action is to name it and re-read next cycle.
        echo "#$PR no acting arm for class '${V:-<empty>}' — nothing spawned (unreadable/empty check surface; re-read next cycle)" >>"$LOG"
        disp "$PR" "${HEAD_N:-}" "${V:-NONE}" wait "check surface unreadable or empty (${V:-no class}) — nothing spawned" ;;
    esac
    # [acting-case:end]
  done
  # ── THE PR PATH'S OWN OUTCOME, IN ONE LINE (agent-infra#2126) ───────────────────────────────────
  # ⛔ THE LEDGER'S SECOND HALF, and it has to run in the PARENT: the sweep above is a pipeline, so
  # only the sidecar survived it. Every COUNTED un-owned PR that the sweep never saw gets its reason
  # HERE — the swept set is scope-filtered (`SCOPE=own` keeps only `-tm$|-cap$|^fix/`), drafts on
  # non-matching branches are dropped by the listing, and a 304/deferral cycle yields no rows at all.
  # Without this block those PRs are the darkest form of the defect: counted into `UPN`, so the issue
  # path stays shut, and named nowhere.
  # ⛔ NO gh CALL HERE. `OPEN_ROWS` is the same row set the count was taken from; a disposition that
  # cost a request per PR would make the honesty repair the most expensive thing in the cycle.
  # [prdisp-apply:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
  for _tok in ${OPEN_ROWS:-}; do
    _p="${_tok%%:*}"; _rest="${_tok#*:}"; _osha="${_rest%%:*}"; _obr="${_rest#*:}"
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    # ⛔ UN-OWNED ONLY. `OPEN_ROWS` is the whole open listing — an OWNED PR is not work this box owes
    # and must not inflate the waits (the invariant is about the COUNTED set, and the count excludes
    # owned PRs). `pr_owned` is the same predicate the count uses, on the same row, so the two cannot
    # disagree about who owns what.
    [ "$_obr" = "$_osha" ] && _obr=""   # a legacy two-field row: no branch, so only the local arms apply
    pr_owned "$_p" "$_osha" "$_obr" && continue
    grep -q "^${_p}"$'\t' "$PRDISP" 2>/dev/null && continue
    if [ -z "${SWEEP_LIST:-}" ]; then
      disp "$_p" - - wait "no per-PR read this cycle (the open-PR listing was unchanged — 304 — or unreadable)"
    else
      disp "$_p" - - wait "not in this cycle's swept set (scope=$SCOPE_MODE; drafts and non-matching branches are filtered out)"
    fi
  done
  # [prdisp-apply:end]
  # [prsum:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
  # TALLY. `act` = an action this cycle ACTUALLY took (a worker spawned, a merge issued, an auto-arm,
  # a draft readied, a rerun); `wait` = a row with a printed reason. Both are counts of LEDGER ROWS,
  # not of un-owned PRs: the swept set also carries owned PRs (the sweep never filters the OWN column),
  # so the line counts `row(s)` and never claims a denominator it does not have. Deliberately NOT
  # printed beside `$UPN`, whose population is the whole open listing.
  PRDISP_ACTS=0; PRDISP_WAITS=0; PRDISP_FIRST=""; PRDISP_ACTED=""; PRDISP_TOP=""; PRDISP_ROWS=0
  [ -s "$PRDISP" ] && PRDISP_ROWS="$(awk 'END{print NR+0}' "$PRDISP" 2>/dev/null)"
  is_num "${PRDISP_ROWS:-}" || PRDISP_ROWS=0
  if [ "$PRDISP_ROWS" -gt 0 ]; then
    PRDISP_ACTS="$(awk -F'\t' '$4=="act"'  "$PRDISP" 2>/dev/null | wc -l | tr -d ' ')"
    PRDISP_WAITS="$(awk -F'\t' '$4=="wait"' "$PRDISP" 2>/dev/null | wc -l | tr -d ' ')"
    PRDISP_FIRST="$(awk -F'\t' '$4=="act"{print $1; exit}' "$PRDISP" 2>/dev/null)"
    PRDISP_ACTED="$(awk -F'\t' '$4=="act"{printf "%s#%s", (n++?",":""), $1}' "$PRDISP" 2>/dev/null)"
    is_num "${PRDISP_ACTS:-}"  || PRDISP_ACTS=0
    is_num "${PRDISP_WAITS:-}" || PRDISP_WAITS=0
    PRDISP_TOP="$(awk -F'\t' '$4=="wait"{print $5}' "$PRDISP" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | sed 's/^ *//')"
  fi
  # ⛔ THE POPULATION CAVEAT IS NOT OPTIONAL. `OPEN_ROWS` is the only enumerable list of the COUNTED
  # set; without it (GraphQL failed and `open_pr_count` deleted its rows, or the fallback fired) the
  # ledger covers the SWEPT set only, while the gate is reading the listing count. Saying "N named
  # waits" unqualified there would present a narrower population as the whole one — the arithmetic
  # that does not close this block exists to end. And if `state/` is unwritable the ledger is empty by
  # CONSTRUCTION: the outcome is then UNKNOWN, never "nothing happened".
  if [ "${PRDISP_OK:-1}" != "1" ]; then
    echo "[pr] PR path: record UNWRITABLE (state/ is not writable) — this cycle's PR actions are UNKNOWN, not zero; ${UPN_WORK:-?} un-owned PR(s) are counted" >>"$LOG"
    PR_FIRST_TOK="unknown (the PR record is unwritable — see the [pr] line)"
  elif [ "$PRDISP_ROWS" -eq 0 ]; then
    # ⛔ A ZERO ROW COUNT HAS TWO CAUSES AND THE COUNT CANNOT TELL THEM APART (review cycle 2, P2): no
    # listing rows, OR rows were read and NOT ONE WRITE LANDED (a truncate succeeds with no allocation,
    # so a full `state/` passes the `PRDISP_OK` probe at the top and then every `disp` fails). Naming
    # only the first would send an operator to repair the GraphQL listing when the state filesystem is
    # the broken thing. Both are stated; neither is asserted.
    echo "[pr] PR path: NO ROWS — no per-PR disposition was recorded this cycle (either the listing returned no rows, or the record could not be written), so not one PR can be named; PR actions are UNKNOWN, not zero; ${UPN_WORK:-?} un-owned remain (see the [select] population line)" >>"$LOG"
    PR_FIRST_TOK="none enumerable (no per-PR rows this cycle)"
  elif [ "$PRDISP_ACTS" -gt 0 ]; then
    echo "[pr] PR path: ${PRDISP_ACTS} acted (${PRDISP_ACTED}), ${PRDISP_WAITS} named wait(s) across ${PRDISP_ROWS} row(s) — ${SCOPE_MODE} scope, $(wt_count merge- fix-) worker(s) in flight" >>"$LOG"
    PR_FIRST_TOK="#${PRDISP_FIRST}"
    [ -n "${PRDISP_FIRST:-}" ] || PR_FIRST_TOK="none named"
  else
    # NOTHING WAS ACTED ON. This is the line that makes a stalled drain distinguishable from an idle
    # one: no unit ran, and the dominant reason is named rather than inferred. It does NOT claim what
    # the issue path will do — the gate is decided further down, and a forward claim here would be the
    # same defect sign-reversed (all counted PRs parked is a state where the gate legitimately opens).
    echo "[pr] PR path: NO UNIT SPAWNED this cycle — ${PRDISP_WAITS} row(s) with a named reason${PRDISP_TOP:+ (most common: ${PRDISP_TOP})}" >>"$LOG"
    PR_FIRST_TOK="none acted — see the [pr] line"
  fi
  # ⛔ THE FUNNEL TAKES THE SAME THREE FACTS, INCLUDING WHETHER THEY WERE MEASURED AT ALL: 0 acts with a
  # written ledger is a measured idle cycle; 0 acts with no ledger is UNKNOWN, and the funnel must not
  # print the negative (review cycle 2, P1).
  PRDISP_REC=ok
  if [ "${PRDISP_OK:-1}" != "1" ] || [ "$PRDISP_ROWS" -eq 0 ]; then PRDISP_REC=unknown; fi
  [ "${POP:-open-rows}" != "open-rows" ] \
    && echo "[pr] ⚠️ the counted population is NOT enumerable this cycle (population=${POP:-?}): the rows above cover the SWEPT set only, while the gate reads ${UPN_WORK:-?} un-owned over the listing — the difference cannot be named per-PR" >>"$LOG"
  # [prsum:end]
  # ⛔ `FIRST_PR` MAY ONLY NAME A PR A UNIT ACTUALLY TOUCHED (#2126). It is computed above from the
  # SELECTED rows — before the sweep — so the first un-owned row can be a parked PR, a PR whose
  # branch this box does not scope, or a row a 304 never let the sweep read. Naming that PR as "this
  # cycle's work" is the instrument claiming a target it never dispatched. Re-derive it from the
  # ledger; `-` when nothing was acted (the funnel and the [dispatch] line both say so, with reason).
  if [ -n "${PRDISP_FIRST:-}" ]; then FIRST_PR="$PRDISP_FIRST"; else FIRST_PR="-"; fi
  heartbeat

  # ---- 2) capacity-gated dispatch ----------------------------------------
  # prune the backlog of already-dispatched issues (otherwise it reads as non-empty but yields nothing)
  if [ -s "$O/candidates.txt" ]; then
    python3 - "$O/candidates.txt" "$O/dispatched.txt" <<'PY'
import sys
cand=[l.strip() for l in open(sys.argv[1]) if l.strip()]
done=set(l.strip() for l in open(sys.argv[2]) if l.strip())
keep=[x for x in cand if x not in done]
open(sys.argv[1],"w").write("\n".join(keep)+("\n" if keep else ""))
PY
  fi
  L="$(load1)"; LANES="$(wt_count lane-)"
  # agent-infra#1709 item 4: WORKERS counts the non-lane agent sessions (reviewers + fixers)
  # live at this instant, so the dispatch block line below can distinguish "blocked while the box
  # was idle" (lanes=0 workers=0 -> raising the ceiling helps) from "blocked while busy" (it does
  # not). Total in-flight agents = lanes + workers.
  WORKERS="$(wt_count merge- fix-)"
  # A load reading that is empty or non-numeric is the DOCUMENTED FAIL-OPEN (can_spawn() defaults it
  # to 0). Kept deliberately (#1702): both supported platforms are measurable now, and failing CLOSED
  # on an unreadable probe would convert "no load back-pressure" into a permanent controller outage on
  # a host with no procfs and no sysctl — a worse and less recoverable failure than the gate it guards.
  # The remaining gates (MAX_LANES, memory, merge-priority) still bound dispatch. Coerced here as well
  # so the gate chain cannot emit "integer expression expected", and so the logged value IS the value
  # the gate used.
  is_num "${L:-}" || L=0
  # swap_total=0 => swap uninitialised (fresh boot), NOT pressure — allow. An UNREADABLE probe is
  # UNKNOWN and takes that same allow, for the reason above; unlike 0 it is a distinguishable state
  # (swap_usage_mb returns non-zero), so a future decision to fail closed there has a seam to use.
  SWFREE=9999; SWTOTAL=0
  if _sw="$(swap_usage_mb)"; then SWFREE="${_sw%% *}"; SWTOTAL="${_sw##* }"; fi
  is_num "$SWFREE" || SWFREE=9999
  is_num "$SWTOTAL" || SWTOTAL=0
  # Available memory through the portable helper: /proc/meminfo (MemAvailable, else MemFree+Cached)
  # on a cell; `free`+`inactive` vm_stat pages on macOS. It fails CLOSED (rc != 0 -> UNKNOWN -> do
  # not add work) -- before #1702 the probe was vm_stat-only and therefore failed closed on EVERY
  # Linux cell, which is the false green (cycles complete, nothing ever dispatches) this PR removes.
  if MEMAVAIL_MB="$(mem_avail_mb)"; then
    MEM_UNKNOWN=0
  else
    # The probe itself failed. UNKNOWN, not ample: we cannot see capacity, so we do not add work.
    MEMAVAIL_MB=0; MEM_UNKNOWN=1
  fi
  # ⛔ COERCE like L / SWFREE / SWTOTAL (#1985 review, P2). Those three are is_num-guarded; MEMAVAIL_MB
  # was not, so an empty value reached `[ "$MEMAVAIL_MB" -le … ]` as `[: : integer expression expected`
  # — an ERRORED test, which is FALSE, which leaves GATE_WHY empty and OPENS the gate. Unreachable
  # through mem_avail_mb() today, but it is the one seam where a probe fault would admit work.
  if ! is_num "${MEMAVAIL_MB:-}"; then MEMAVAIL_MB=0; MEM_UNKNOWN=1; fi
  # ⛔ THE MERGE-PRIORITY GATE IS HANDED ITS EVIDENCE, NOT ITS CONCLUSION (see mp_reason): the unowned
  # COUNT, the epoch of the last recorded land, and the cap it is measured against. All of them are
  # read HERE, once, and BEFORE the [cap] line that prints them — read after it, that line printed `?`
  # on the first cycle and the PREVIOUS cycle's reading on every one after (a stale record presented
  # as current: exactly what this change removes). There is deliberately NO age here: `unowned_scan`
  # echoes the count alone and `mp_reason` takes four args, none of them an age (see its definition).
  LAND_EPOCH="$(mp_recent_land)"
  # A window the ULTIMATE BOUND opened (see mp_reason(0)): while it is in the future the gate does not
  # arm, so a bound-driven release is a WINDOW of dispatch rather than the single pulse the next
  # cycle's re-arm would otherwise leave (review round 3, finding 7).
  LAND_AGE=""
  if is_num "${LAND_EPOCH:-}"; then
    _now_a="$(date +%s)"; is_num "$_now_a" || _now_a=0
    [ "$LAND_EPOCH" -gt "$_now_a" ] && LAND_EPOCH="$_now_a"
    LAND_AGE=$(( (_now_a - (10#$LAND_EPOCH)) / 60 ))
  fi
  # `@${OR}` is part of this line on purpose: the repo the count came from is the datum whose absence
  # let a wrong-surface read run for hours. bare `$OR` is avoided for the same reason `${OR:-}` is used
  # below — selftest.sh extracts and drives parts of this file in a subshell with no OR.
  echo "[cap] load=$L/$MAX_LOAD lanes=$LANES/$MAX_LANES mem_avail=${MEMAVAIL_MB}M/${MIN_MEM_FREE_MB}M swap_free=${SWFREE}M/${MIN_SWAP_FREE}M open=${OPEN_N:-?}@${OR:-?} unowned=${UPN:-?} last_land=${LAND_AGE:-?}m review_slots=${MR:-?} fix_slots=${MF:-?}" >> "$LOG"
  # Four gates. swap_total=0 => swap uninitialised (fresh boot), NOT pressure — allow.
  # Name the binding gate: an earlier version logged "skipped (load=…)" while load was never
  # consulted, so a lanes-bound or swap-bound stall looked like a load stall.
  GATE_WHY="$(mp_reason "${UPN_WORK:-${UPN:-0}}" "$LANES" "$WORKERS" "${SEL_TOTAL:-${OPEN_N:-0}}")"
  if [ -n "$GATE_WHY" ]; then :
  elif [ "$L" -ge "$MAX_LOAD" ]; then GATE_WHY="load=$L>=max_load=$MAX_LOAD"
  elif [ "$LANES" -ge "$MAX_LANES" ]; then GATE_WHY="lanes=$LANES>=max_lanes=$MAX_LANES"
  # ⛔ SWAP IS CUMULATIVE, RAM IS PRESENT (#1985). On macOS a 1 GB swap file stays roughly half
  # occupied for the life of the boot after ANY spike, so this arm vetoed dispatch forever while the
  # box had 1.4 GB available RAM (53 MB free + 1297 MB inactive) and 20 of 20 lane slots idle:
  # measured 2026-10-18, every cycle, "lanes=0/20 … swap_free=506M<=min_swap_free=600M". The metric
  # described the PAST, and with the RAM gate PASSING underneath it, "no create activity" was
  # indistinguishable from "nothing to do".
  # Swap exhaustion only matters when RAM is ALSO tight, so require both. An UNKNOWN memory read
  # keeps the veto (fail closed) — never let a probe failure open the gate.
  elif [ "$SWTOTAL" -ne 0 ] && [ "$SWFREE" -le "${MIN_SWAP_FREE:-600}" ] \
       && { [ "${MEM_UNKNOWN:-0}" = "1" ] || [ "${MEMAVAIL_MB:-0}" -le "$(( MIN_MEM_FREE_MB * 2 ))" ]; }; then
    GATE_WHY="swap_free=${SWFREE}M<=min_swap_free=${MIN_SWAP_FREE:-600}M AND mem_avail=${MEMAVAIL_MB}M<=$(( MIN_MEM_FREE_MB * 2 ))M (both tight)"
  # "A failed probe is UNKNOWN, not ample" is only true if MEM_UNKNOWN can be SET, and it is set
  # from mem_avail_mb()'s EXIT STATUS (its awk `exit 1`s on absent fields) rather than from an empty
  # string: awk's END block always ran, so `printf "%d"` yielded 0 for unset fields and a test for
  # an empty MEMAVAIL_MB could never be true. The helper is therefore tested on its own, above.
  elif [ "${MEM_UNKNOWN:-0}" = "1" ]; then GATE_WHY="mem_probe_failed (capacity unknown -> do not add work)"
  elif [ "$MEMAVAIL_MB" -le "$MIN_MEM_FREE_MB" ]; then GATE_WHY="mem_avail=${MEMAVAIL_MB}M<=min_mem_free_mb=${MIN_MEM_FREE_MB}M"
  fi
  # ── THE FUNNEL: ONE AUDITABLE LINE PER CYCLE (owner ruling, 2026-10-18) ────────────────────
  # The choice between "work the PR queue" and "open more work" is printed, not inferred: the counts
  # it was made from, the PR it will take first, and — when the issue path is shut — WHY. Without
  # this line `[dispatch] skipped` and "nothing to do" are the same reading, and the box can sit on a
  # 50-PR queue that nothing is working while the log looks busy (the measured defect).
  # ⛔ NOT IN A COMMAND SUBSTITUTION: `lo_select` sets LO_CHOICE, and a `$( )` would set it inside a
  # subshell that ends immediately — the funnel would print while the decision was lost, which is the
  # exact class of bug this change exists to remove (a printed claim with no artifact behind it).
  # A redirect is not a subshell: `> file` runs in THIS shell, so LO_CHOICE survives.
  SELFILE="$O/state/.select-line"
  # ⛔ THE GATE'S INPUT IS THE WORKABLE UN-OWNED COUNT (UPN_WORK): un-owned PRs the harness has NOT
  # already declared needs-a-human. A parked PR no lane may touch must not latch this shut forever.
  # ⛔ SEL_TOTAL / OWN_N / UPN_WORK were computed together, from ONE chosen source, in the ownership
  # stage above. They are NOT re-derived here: a second derivation is how the total and its parts came
  # to disagree in the first live cycle of this change.
  LO_SELECT_DEFINED=0
  declare -f lo_select >/dev/null 2>&1 && LO_SELECT_DEFINED=1
  SEL_LINE=""
  if [ "$LO_SELECT_DEFINED" = "1" ]; then
    lo_select "$SEL_TOTAL" "${OWN_N:-0}" "${UPN_WORK:-${UPN:-?}}" "${SEL_PARKED:-0}" "${FIRST_PR:--}" "${GATE_WHY:-}" "$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')" "${PRDISP_ACTS:-}" "${PRDISP_WAITS:-}" "${PRDISP_REC:-unknown}" > "$SELFILE" 2>/dev/null || true
    SEL_LINE="$(cat "$SELFILE" 2>/dev/null)"
  fi
  rm -f "$SELFILE"
  if [ -z "$SEL_LINE" ]; then
    # ⛔ A LOST FUNNEL LINE IS NOT A DECISION (review P2). This fallback used to key on the line being
    # EMPTY — so a failed write (ENOSPC/EIO on `state/`, a condition this harness watches for) silently
    # re-decided the cycle from GATE_WHY alone, and with no capacity gate firing that OPENS the issue
    # path while the funnel had chosen PR work: the printed decision and the acted-on decision differ,
    # which is the class this whole change exists to remove. Availability now decides: module PRESENT
    # but silent ⇒ HOLD (issue path closed, reason named); module ABSENT ⇒ the documented registry-only
    # degrade, which is the pre-change behaviour and is stated as such.
    if [ "$LO_SELECT_DEFINED" = "1" ]; then
      SEL_LINE="[select] FUNNEL UNAVAILABLE (lo_select printed nothing — state/ unwritable or the module failed); HOLDING: no issue work this cycle"
      LO_CHOICE=none
    else
      SEL_LINE="[select] FUNNEL UNAVAILABLE (\$O/live-ownership.sh missing — ownership is registry-only this cycle)"
      LO_CHOICE=$([ -n "$GATE_WHY" ] && echo none || echo issue)
    fi
  fi
  echo "$SEL_LINE" >> "$LOG"
  [ -n "${FLOOR_NOTE:-}" ] && echo "$FLOOR_NOTE" >> "$LOG"
  [ "${LO_STATUS:-ok}" = "ok" ] || echo "[select] ⚠️ live ownership scan $LO_STATUS — un-owned counts fall back to the registry arms (a cwd probe that reads nothing is UNKNOWN, not 'nobody is working')" >> "$LOG"
  # ⛔ THE ISSUE PATH IS BLOCKED WHILE A WORKABLE UN-OWNED PR EXISTS — in one line, on its own, so
  # "the fleet is busy" and "the fleet is draining" are different readings of the log.
  if [ "${LO_CHOICE:-}" = "pr" ]; then
    echo "[dispatch] issues BLOCKED — ${UPN_WORK:-?} un-owned PR(s) remain; this cycle's work is the PR queue (first ${PR_FIRST_TOK:-#${FIRST_PR:--}})" >> "$LOG"
    # ── THE DRAIN'S OWN HEALTH (a DIAGNOSTIC, never an input to the selection) ───────────────────
    # [drain-health:begin] (extracted and DRIVEN by test-gates.sh — keep the marker)
    # ⛔ THIS LINE IS THE ANSWER TO "but then the queue can block forever", AND IT IS *NOT* A RELEASE
    # VALVE. The owner's rule (2026-10-18, verbatim): "Only when NO un-owned PR remains may the
    # dispatcher create new work by picking issues." A stalled drain is a LANE/CAPACITY problem, and
    # opening new work because PRs are not landing is the failure the ruling exists to stop — it hides
    # the stall behind fresh activity. So what a stall gets is a NAME, in one line, beside the gate it
    # explains: "nothing has landed in 4h while 56 un-owned PRs wait" is a fleet alarm; dispatching
    # issues would have made it invisible.
    # ⛔ The datum already exists and needs no new state: `mp_recent_land` reads the
    # `state/merged-<PR>.done` markers the merge sweep writes on every land. Its shortlist is bounded
    # (2x the merge-priority window), so an EMPTY answer means "no land inside that bound" — which is
    # the stalled condition, not an absence of evidence, PROVIDED a marker exists at all. A box that
    # has never landed anything prints nothing: an unread baseline must not be reported as a stall
    # (agent-infra#1931).
    _land_any=0
    for _f in "$O"/state/merged-*.done; do [ -e "$_f" ] && { _land_any=1; break; }; done
    # ⛔ NORMALISE THE TUNABLE (review P3): `[ "200m" -ge … ]` ERRORS (rc 2), an errored test is
    # FALSE, and the else arm would print "drain alive" — a false all-clear on the very condition this
    # line exists to name, every cycle. Every other knob in this file is normalised first (`is_num`,
    # `10#`); this one is display-only, so a bad value falls back.
    # ⛔ THE DEFAULT BELONGS ON A VARIABLE, NOT IN A `case` SUBJECT (measured on a live cycle): with
    # `set -u`, `case "${MERGE_STALL_MIN:-180}" in … ) _stallmin=$(( 10#${MERGE_STALL_MIN} )) …` still
    # references the BARE name inside the arm — where the `:-` default is gone — so an unset tunable
    # ABORTED the whole cycle right after `[dispatch] issues BLOCKED`, every cycle, silently (rc=5).
    # Text pins could not catch that; the block is now DRIVEN by a test.
    _stallraw="${MERGE_STALL_MIN:-180}"
    _stallmin=180
    case "$_stallraw" in ''|*[!0-9]*) : ;; *) _stallmin=$(( 10#$_stallraw )) ;; esac
    _lm="$(mp_recent_land 2>/dev/null || true)"
    if is_num "${_lm:-}"; then
      _lage=$(( ( $(date +%s) - (10#${_lm}) ) / 60 ))
      # ⛔ A FUTURE STAMP IS NOT A FRESH LAND (review cycle 3, P2). `find -mmin -N` passes a file
      # stamped in the future (a negative age is "less than N minutes ago"), so clamping it to 0 would
      # render a clock step-back as "drain alive" — and after the release valve was removed this line
      # is the ONLY signal a stall has left, so an invented fresh reading is precisely the silence the
      # ruling removed. `dispatch_funnel` refuses the same shape for its own record ("A FUTURE at= IS
      # NOT A FRESH RECORD"). Print the UNMEASURED
      # case instead: it is neither a stall nor an all-clear, and it says which it is.
      if [ "$_lage" -lt 0 ]; then
        echo "[dispatch] DRAIN STALL UNMEASURED — the newest land marker (state/merged-*.done) is stamped ${_lage#-}m in the FUTURE, so the drain's age cannot be read. This is neither a stall nor an all-clear; ${UPN_WORK:-?} un-owned remain and the issue path stays CLOSED (un-owned PRs first)." >> "$LOG"
      elif [ "$_lage" -ge "$_stallmin" ]; then
        echo "[dispatch] DRAIN STALLED — no PR merged in ${_lage}m while ${UPN_WORK:-?} un-owned remain. The issue path stays CLOSED (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work." >> "$LOG"
      else
        echo "[dispatch] drain alive — last land ${_lage}m ago; ${UPN_WORK:-?} un-owned remain" >> "$LOG"
      fi
    elif [ "${_land_any:-0}" = "1" ]; then
      echo "[dispatch] DRAIN STALLED — no PR merged within the last $(( 10#${MERGE_PRIORITY_MAX_AGE_MIN:-180} * 2 ))m while ${UPN_WORK:-?} un-owned remain. The issue path stays CLOSED (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work." >> "$LOG"
    fi
    # [drain-health:end]
  fi
  # The printed decision is AUTHORITATIVE over the issue path: if the funnel did not choose issue
  # work, nothing opens a lane for an issue, even if every capacity gate below happens to pass.
  # ⛔ FAIL-CLOSED DEFAULT, AND IT IS LOAD-BEARING (#2126). `LO_CHOICE` is set by `lo_select`, but the
  # funnel-unavailable HOLD path assigns `none` and a truncated/stale module can leave it UNSET — and
  # this is the ONE line that turns a HOLD into a closed issue path. With `:-issue` an unset value read
  # as "dispatch issues", i.e. a lost funnel decision opened the work queue while un-owned PRs sat
  # (the fail-open direction of the owner's rule). `:-none` closes instead. It can only ever CLOSE the
  # path — `pr`/`none` both fall through to the same GATE_WHY assignment below — so this cannot release
  # the gate, only refuse to open it.
  if [ "${LO_CHOICE:-none}" != "issue" ] && [ -z "$GATE_WHY" ]; then
    GATE_WHY="selection (funnel chose '${LO_CHOICE:-?}', not issues)"
  fi
  if [ -z "$GATE_WHY" ]; then
    : > "$O/.batch"; K=0
    # ⛔ `Y` IS ON ITS OWN LINE, NOT TAGGED ONTO THE ANCHOR ABOVE (#1909 merge resolution).
    # `refresh-scout.test.sh` extracts this dispatch block VERBATIM and anchors on the exact
    # `: > "$O/.batch"; K=0` line (and pins the `if [ -z "$GATE_WHY" ]` immediately above it).
    # Appending `; Y=0` to that line silently emptied the extraction — the suite's claim
    # assertion then graded a block it never read, which is the "a test that cannot run" shape,
    # not a test that fails. Keep the anchor line byte-identical and initialise the yield counter
    # inside the block.
    Y=0
    while read -r ISS; do
      [ -z "${ISS:-}" ] && continue
      grep -qx "$ISS" "$O/dispatched.txt" 2>/dev/null && continue
      # ── CAPACITY TRANSFER (agent-infra#1909): a refused item is a PEER's to take ─────────────
      # `continue` WITHOUT touching `dispatched.txt` or claiming the ref: the issue stays in
      # `candidates.txt` (so this box may take it once the yield expires) and stays unowned in the
      # shared registry (so every peer may claim it NOW). Consuming the item's turn here would be
      # the `parked-*` failure R8 names, on a per-machine capacity signal.
      if capacity_yield_live "$ISS"; then
        Y=$((Y+1))
        echo "[dispatch] #$ISS yielded to peers — this box refused it for capacity and is standing down until the yield expires (${CAPACITY_YIELD_WHY})" >> "$LOG"
        continue
      fi
      # ── CLAIM THE ISSUE ACROSS BOXES BEFORE IT ENTERS THE BATCH (agent-infra#1850) ──────────
      # `refresh-candidates.sh` certifies an issue CLEAN by reading the registry, but a
      # certification is NOT a lock: it runs BEFORE the claim, so two boxes can both read CLEAN and
      # both arrive here. The claim IS the lock — pushing a root commit to `refs/claims/issue-<N>`
      # is an atomic CAS, so exactly one box wins and the loser is told which owner holds it.
      #
      # ⛔ CLAIMED HERE, NOT IN dispatch-merge.sh, so the bookkeeping stays honest: a REFUSED issue
      # is not appended to `dispatched.txt` and not put in `.batch`, so it stays in `candidates.txt`
      # and is simply re-attempted next cycle — no blacklist for the reaper to undo, and no lane, no
      # worktree and no chain spawned for work another box already owns.
      #
      # ⛔ BOTH REFUSALS STOP THE DISPATCH — INCLUDING THE INFRA ONE (rc=2). claims.sh fails OPEN on
      # an unreachable remote for a PR claim, because refusing there costs one merge; here the safe
      # reading is the opposite: an UNREADABLE registry is not evidence of freedom, and dispatching
      # on it is the exact duplicate this issue exists to remove.
      # ⛔ ITS BLAST RADIUS IS THE FLEET, NOT THIS BOX — DO NOT SOFTEN THE REFUSAL ON THE ASSUMPTION
      # THAT `gh` IS DOWN TOO (2026-10-16 review). This comment used to assert "the same outage fails
      # the pre-flight's `gh` surfaces, so the cell is already stalled"; that is FALSE, and the
      # regression case for it (`claim-unreachable`) disproves it with a WORKING gh stub: the
      # registry read is `git ls-remote` — a GIT transport — while the pre-flight tool and the whole
      # merge path use the `gh` REST API. A git-only failure (credentials, a ruleset, a transport
      # block) therefore refuses every issue on EVERY box pointed at this repo, so nothing is queued
      # and nothing is dispatched, while merges keep working. That is the intended direction (a
      # registry outage must never become a duplicate dispatch), but it is a fleet-wide stop on
      # dispatch and it must be visible: refresh-candidates.sh reports it in aggregate and exits
      # non-zero, so the controller never reads it as "no work available".
      #
      # ⚠️ NO KILL-SWITCH. An ambient env var that turns this off is the "disable a gate by ambient
      # env" shape (a bypass), so the ONLY fallback is a registry that is genuinely NOT PROVISIONED
      # (no file at all), and it says so in the log every time it is used. ⛔ A registry that EXISTS
      # but is too old to take a claim is NOT that case (2026-10-16 review): it is local drift on
      # THIS box, and dispatching unclaimed while this same box's pre-flight refuses every issue as
      # INCOMPLETE is a fail-open that can duplicate a peer's work — so it stops the dispatch, names
      # the fix, and `refresh-candidates.sh --check` refuses the cell up front. Pre-flight and
      # dispatch now take the SAME polarity on the same condition.
      if [ -f "$O/claims.sh" ] && declare -f claim_issue_acquire >/dev/null 2>&1; then
        if claim_issue_acquire "" "$ISS"; then
          # The commit this box pushed, for the FENCED release. Written only on a successful acquire,
          # so a refusal can never leave a release path pointing at someone else's claim.
          claim_issue_record "$O" "$ISS" "${CLAIM_COMMIT:-}" \
            || echo "[dispatch] ⚠️ #$ISS: could not record the claim commit — chain-merge.sh cannot FENCE the release (the claim will run to its lease)" >> "$LOG"
          # ⛔ A RECLAIM IS AN EVENT, NOT AN ORDINARY ACQUIRE (agent-infra#2094). This path used to
          # discard CLAIM_RESULT, so an ORPHANED claim taken over here — the incident's exact repair —
          # left NO log line, and the operator's only evidence was the absence of a refusal. The
          # `held-by-orphan` / `reclaimed …` token is printed when it applies, and only then, so a
          # normal dispatch is not made chattier.
          case "${CLAIM_RESULT:-}" in
            *reclaim*|*rphan*)
              echo "[dispatch] #$ISS claim $CLAIM_RESULT" >> "$LOG" ;;
          esac
        else
          acq_rc=$?
          # ⛔ rc=2 WITH A COMMIT IN HAND IS A RELEASE PATH, NOT JUST A REFUSAL (2026-10-16 review).
          # claims.sh sets CLAIM_COMMIT on the create/reclaim paths whose push MAY have landed and
          # only the read-back failed — its own comment says the caller can attempt a FENCED release,
          # and merge-one.sh already does exactly that for the same condition. Discarding it here
          # orphaned a claim THIS BOX created for the whole lease, with every peer reading the issue
          # as taken: the abandoned-claim class this change exists to close.
          if [ "$acq_rc" = "2" ] && [ -n "${CLAIM_COMMIT:-}" ]; then
            claim_issue_record "$O" "$ISS" "$CLAIM_COMMIT" 2>/dev/null
            if claim_issue_release_record "$O" "$REPO" "$ISS" "$CLAIM_COMMIT" >/dev/null 2>&1; then
              echo "[dispatch] #$ISS NOT dispatched (claim infra error) — the claim commit this box may have pushed WAS released (fenced on $CLAIM_COMMIT)" >> "$LOG"
            else
              echo "[dispatch] #$ISS NOT dispatched — ${CLAIM_RESULT:-issue claim refused}; the possibly-created claim could NOT be released — it will expire with its lease" >> "$LOG"
            fi
          else
            echo "[dispatch] #$ISS NOT dispatched — ${CLAIM_RESULT:-issue claim refused}" >> "$LOG"
          fi
          continue
        fi
      elif [ -f "$O/claims.sh" ]; then
        # PRESENT BUT STALE — see the polarity note above. The box would have to dispatch unclaimed,
        # which is the fail-open this branch now refuses.
        echo "[dispatch] #$ISS NOT dispatched — \$O/claims.sh predates the issue key (no claim_issue_acquire), so this box cannot take the claim; fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/" >> "$LOG"
        continue
      else
        echo "[dispatch] ⚠️ #$ISS: no claim registry at \$O/claims.sh — dispatching WITHOUT a cross-box claim (seed it: cp scripts/orchestrator-harness/*.sh ~/orchestrator/)" >> "$LOG"
      fi
      echo "$ISS" >> "$O/.batch"; echo "$ISS" >> "$O/dispatched.txt"; K=$((K+1)); [ "$K" -ge "$BATCH" ] && break
    done < "$O/candidates.txt"
    if [ -s "$O/.batch" ]; then
      dispatch_funnel "$K" "$(queue_state_token)" "" "" "${Y:-0}" >> "$LOG"
      echo "[dispatch] load=$L lanes=$LANES -> $(tr '\n' ' ' < "$O/.batch")" >> "$LOG"
      bash "$O/dispatch-merge.sh" "$REPO" "$OR" $(tr '\n' ' ' < "$O/.batch") >> "$LOG" 2>&1
    # ⛔ "backlog empty" IS A CLAIM, NOT A NEUTRAL FACT (agent-infra#1931). On its own it reads as
    # "the fleet has nothing to do", and the SAME line was printed when 223 candidates had been READ
    # and every one of them was filtered away (#2040) — the contradiction that hid a total dispatch
    # stop for hours. The funnel replaces it: it names where the candidates went, and `queue=EMPTY`
    # remains the only form that means "no work".
    # ⛔ AND #1909's THIRD READING RIDES THE FUNNEL, not a resurrected claim: a cycle in which every
    # candidate was YIELDED to a peer leaves `.batch` empty while the backlog is full, and Y counts
    # those. Passing it here is what stops a fully-yielded backlog reading as stillness — the
    # capacity transfer's whole point — without re-introducing the false "backlog empty" sentence.
    else dispatch_funnel 0 "$(queue_state_token)" "" "" "${Y:-0}" >> "$LOG"; fi
  else
    dispatch_funnel 0 "$(queue_state_token)" "$GATE_WHY" >> "$LOG"
    # ⛔ THE PR-PATH TAIL IS DERIVED FROM THE SAME THREE CASES AS THE `[pr]` LINE, never from a bare
    # count: with an unwritable ledger every count is 0 and `NO UNIT SPAWNED` would be a printed claim
    # about a cycle nobody recorded (#2126 review).
    if [ "${PRDISP_OK:-1}" != "1" ]; then _prtail="record UNWRITABLE — PR actions UNKNOWN, not zero"
    elif [ "${PRDISP_ROWS:-0}" -eq 0 ]; then _prtail="no per-PR rows this cycle — nothing could be named"
    elif [ "${PRDISP_ACTS:-0}" -gt 0 ]; then _prtail="${PRDISP_ACTS} acted, ${PRDISP_WAITS} named wait(s)"
    else _prtail="NO UNIT SPAWNED, ${PRDISP_WAITS} named wait(s) — see the [pr] line"; fi
    echo "[dispatch] skipped ($GATE_WHY) lanes=$LANES workers=$WORKERS | PR path: $_prtail" >> "$LOG"
  fi
  heartbeat

  # ---- 3) background backlog refresh (locked, small, non-blocking) --------
  BL="$(wc -l < "$O/candidates.txt" | tr -d ' ')"
  if [ "$BL" -lt 6 ]; then
    if [ -f "$O/.refresh-blocked" ]; then
      # agent-infra#1736: a PERMANENT provisioning failure (exit 3) is recorded here so it is
      # neither retried forever nor silent. `lanes: 0` alone also describes a healthy idle cell,
      # so the reason is printed every cycle AND surfaced by `cloud-cell-supervisor.sh status`.
      echo "[refresh] blocked (not retrying): $(head -1 "$O/.refresh-blocked")" >> "$LOG"
    elif [ ! -d "$O/.refresh.lock" ]; then
      mkdir -p "$O/.refresh.lock"
      echo "[refresh] spawning (backlog=$BL)" >> "$LOG"
      # ⛔ `&` discards the refresh's exit status, so a refresh that aborts EVERY cycle reads as a
      # healthy cell with `lanes: 0` forever (#1736, measured on the first cmux cloud cell).
      # Capture rc: 3 is refresh-candidates.sh's NOT_PROVISIONABLE code — permanent, so retrying
      # cannot help; record it and stop re-spawning. Any OTHER non-zero is transient (network, a
      # failed listing) and IS retried next cycle.
      # ⛔ BOUND THE EVIDENCE TO THIS RUN. $LOG is append-only and never rotated, so a bare
      # `grep NOT PROVISIONABLE "$LOG"` would quote a PREVIOUS cycle's refusal as this block's
      # "verbatim" reason — presenting a cause that no longer fired (#1853 review).
      # The mark is a LINE index, and the `echo` above has just terminated any partial tail.
      log_mark="$(awk 'END{print NR}' "$LOG" 2>/dev/null)"; [ -n "$log_mark" ] || log_mark=0
      ( bash "$O/refresh-candidates.sh" 6 >> "$LOG" 2>&1; rc=$?
        rm -rf "$O/.refresh.lock"
        if [ "$rc" -eq 3 ]; then
          echo "[refresh] BLOCKED (permanent): this repo cannot be provisioned for dispatch — see the reason above. Not retrying (agent-infra#1736); fix it, then delete $O/.refresh-blocked" >> "$LOG"
          # The reason is quoted from the refresh's OWN refusal, not restated here: a marker that
          # hardcodes one remedy is a FALSE remedy for the other causes the same rc=3 now covers
          # (no pre-flight tool, an unauthenticated gh in an unusable HOME, an interpreter older
          # than the tool's minimum). Only the refresh knows which one fired.
          {
            echo "MERGE-ONLY: dispatch provisioning is BLOCKED — no implementation lane will be dispatched until this is fixed."
            echo "Reason and evidence (the refresh's own refusal, verbatim):"
            tail -n +"$((log_mark + 1))" "$LOG" 2>/dev/null | grep 'NOT PROVISIONABLE' | tail -3 | sed 's/^/  /'
            echo "Those lines name the failing link; the knobs are TORTOISE_REPO=<a tortoise checkout> in keys.env (the controller session re-sources it; an ambient export does not reach a pre-existing tmux server), a vendored tools/collision_preflight.py in the repo, SCOUT_PY=<a Python >= 3.12>, or a writable, gh-authenticated HOME."
            echo "After fixing it, delete this file. The refresh re-writes it, with the current reason, if the cause persists."
          } > "$O/.refresh-blocked"
        elif [ "$rc" -eq 78 ]; then
          # ⛔ 78 IS A CONFIGURATION REFUSAL, NOT A TRANSIENT FAILURE (review round 3, finding 9).
          # The refresh exits 78 when repo-slug.sh is missing or stale — the one condition where it
          # cannot attribute the pool to a repo. Classified transient it was retried forever, and the
          # only place that would print the remedy (the .refresh-blocked file) never fired, so the
          # sole symptom was a `funnel STALE` line half an hour later. Same handling as rc=3: say it
          # once, name the re-seed, and do not retry a config error every cycle.
          echo "[refresh] BLOCKED (permanent): repo-slug.sh missing/stale in \$O — the pool cannot be attributed to a repo, so nothing may be queued. Re-seed: cp scripts/orchestrator-harness/*.sh \$O/ then delete \$O/.refresh-blocked (agent-infra#2040)" >> "$LOG"
          {
            echo "MERGE-ONLY: dispatch is BLOCKED — repo-slug.sh is missing or stale in \$O."
            echo "The refresh refuses to read a candidate pool it cannot attribute to a repo (agent-infra#2040)."
            echo "Fix: cp scripts/orchestrator-harness/*.sh <your \$O>/   then delete this file."
          } > "$O/.refresh-blocked" 2>/dev/null
        elif [ "$rc" -ne 0 ]; then
          echo "[refresh] FAILED rc=$rc (transient — retried next cycle)" >> "$LOG"
        fi ) &
    else
      # stale lock guard (>20 min)
      if [ -n "$(find "$O/.refresh.lock" -mmin +20 2>/dev/null)" ]; then rm -rf "$O/.refresh.lock"; echo "[refresh] cleared stale lock" >> "$LOG"; fi
    fi
  fi

  # agent-infra#1709 rec 4: JITTER. Three boxes on the same 240s cycle wake together — the
  # classic thundering-herd trigger, and the sources name randomised expiry/backoff as the fix.
  # Spread each box's wake-up by up to ±20% of the cycle. Cheap, and it matters more at 3 boxes
  # than at 2: the claim CAS resolves the collision, but jitter means far fewer collisions to
  # resolve at all.
  JIT=$(( 10#${CYC} / 5 ))
  # `& wait`, not a bare sleep: bash runs a trap only AFTER the current foreground command
  # completes, so `sleep 240` deferred the stop for up to a whole cycle — measured 5.07s of a 6s
  # sleep, vs 0.09s with the background form. The lock is held either way, but "kill -TERM ends
  # the process" (agent-infra#1715's indicator) is then true in ~0.1s, not in four minutes.
  # ⛔ `10#` on BOTH arithmetic sites (P1, second review round, 2026-10-14): the predicate above
  # coerces CYC=08 to 240, but this is defence in depth — this line is where a leading zero used to
  # DISCARD the entire `while true` loop and exit 0 after one cycle (relaunch-per-cycle under
  # KeepAlive). `10#${CYC}` reads it base 10 whatever the predicate did.
  sleep $(( 10#${CYC} - JIT + RANDOM % (2 * JIT + 1) )) & wait $!
done
