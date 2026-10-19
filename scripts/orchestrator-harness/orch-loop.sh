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
# ⛔ THE GATE IS BOUNDED IN TIME AND IN EVIDENCE, because a gate whose OPENING condition the
# automation cannot meet is not a gate — it is a permanent stop. Merge priority holds dispatch
# while unowned PRs fall; but an unowned PR on a one-account fleet is not something an unattended
# lane can clear (every session authenticates as the same GitHub user, so ownership is not visible
# from the PR author and nobody hand-assigns them), and the harness cannot merge what no worker is
# touching. Measured 2026-10-18 on all three cloud cells: `merge-priority (52 unowned of 54 open
# PRs — draining before opening more)` at `lanes=0` for HOURS, with a 219-issue candidate pool
# behind it, i.e. the drain never started and nothing could start it. So the block now also
# requires POSITIVE evidence that a drain is happening:
#
#   (a) work in flight AND a land inside the window — a merge/fix worker is live AND some PR
#       actually landed within MERGE_PRIORITY_MAX_AGE_MIN (`state/merged-<PR>.done`), i.e. a
#       railed PR is PROGRESSING, not merely present; and
#   (b) the youngest UNOWNED open PR is younger than MERGE_PRIORITY_MAX_AGE_MIN — there is recently
#       opened review work that could still be drained.
#
# If either is missing, the cell DISPATCHES and the log says which condition released it. Both are
# measured, not assumed: an unreadable age or an unreadable land record RELEASES (the gate blocks
# only on evidence it actually has), the age bound is stated in minutes in the line itself, and the
# unowned threshold is unchanged. MAX_LANES is unchanged — this bounds a gate, it does not raise a
# ceiling. Policy it bounds: agent-infra#1709 item 4 (the in-flight requirement) and the owner
# ruling behind MERGE_PRIORITY_AT=25 ("we should have something more like 10 PRs who are not being
# processed") — neither of which ever said `forever`.
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
  local sha="${2:-}" ref until
  [ -n "$sha" ] || return 1
  [ -f "$O/state/claims-snapshot" ] || return 1
  if command -v claim_ref >/dev/null 2>&1; then ref="$(claim_ref "$1" "$sha")"; else ref="refs/claims/$1-${sha:0:12}"; fi
  until="$(awk -F'\t' -v r="$ref" '$1==r{print $3; exit}' "$O/state/claims-snapshot" 2>/dev/null)"
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
  [ "$(date +%s)" -le "$until" ] && return 0
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
# Kill a worker that has gone silent. It only ever touches tmux sessions, so it can never reach
# the operator's own shell or any process outside the harness. The PR is re-dispatched by the
# normal sweep on the next cycle (the claim_live() check then sees a dead owner and frees it).
reap_stale_workers() {
  local s f age pid m
  for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^(merge|lane|fix)-'); do
    f="$O/logs/$s.log"
    [ -f "$f" ] || continue
    # An unreadable mtime means the age is UNKNOWN, and unknown is not evidence of a hang: skip the
    # session rather than reap it. Never let the probe's failure escape as an arithmetic error — on
    # a Linux cell that is exactly what aborted the controller one cycle after the first dispatch
    # (#1702): set -u turned the unassigned `age` into `File: unbound variable`.
    m="$(file_mtime_epoch "$f")" || continue
    age=$(( $(date +%s) - m ))
    [ "$age" -gt $(( 10#${STALE_MIN} * 60 )) ] || continue
    pid="$(tmux list-panes -t "=$s" -F '#{pane_pid}' 2>/dev/null | head -1)"
    echo "[reap-worker] $s silent ${age}s -> killing session (pane_pid=${pid:-?})" >> "$LOG"
    # `=name` forces an EXACT session match. Without it tmux prefix-matches, so if this session
    # exited between the `tmux ls` snapshot above and here, `-t merge-82` would resolve to the
    # healthy `merge-821` and kill an in-flight worker (verified: `-t zzproof-10` killed
    # `zzproof-101`, while `-t =zzproof-10` errors instead).
    tmux kill-session -t "=$s" 2>/dev/null
    # tmux HUPs the pane's process group; a child that ignored it (e.g. a stuck find) is killed here.
    if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; fi
  done
}

heartbeat() { date +%s > "$O/heartbeat"; }

# ── LANES, BY EVIDENCE (#2163) ─────────────────────────────────────────────────────────────────
# ⛔ THE OLD READING WAS `tmux ls | grep -c '^lane-'`, and it is wrong in both directions. It counts
# SESSIONS: a leaked lane whose tmux pane died is invisible, while every wrapper and `pi` process the
# box is actually carrying is uncounted. Measured 2026-10-19 on the Mac: `ps -eo command |
# grep -c 'pi --model'` said **76 pi processes** for **14 working lanes**, and the cell boxes were
# filled on the strength of a number that was wrong both ways. `lane-reap.sh count` answers the real
# question — a lane is LIVE iff its process tree exists AND its log/turn advanced inside a bounded
# window — and counts the box's zombies, so a box that LOOKS busy but is not says so:
#
#     [cap] … lanes=14/76 max_lanes=25 … zombie=52
#
# `LANES` (live) keeps the meaning the MAX_LANES gate has always applied. `LANES_TOTAL` is every
# resident lane tree: `lanes=14/76` cannot hide 62 finished residents, and the pair is what makes the
# leak visible instead of silently consuming the box (agent-infra#2159: cell-2 OOM-killed 37
# processes and the tmux server, losing every lane on it).
#
# A FAILED read prints `?`, never 0: `lanes=0/0` and "ps is broken" must not render identically (the
# false-green class this loop refuses everywhere else). The dispatch gate then falls back to the OLD
# tmux count — a conservative under-count of live work refuses work, and refusing costs a cycle while
# over-dispatch costs the box.
LANE_REAP_SH=""
for _c in "${O:-}/lane-reap.sh" "${_HERE_RS:-}/lane-reap.sh"; do
  [ -n "$_c" ] && [ -f "$_c" ] && { LANE_REAP_SH="$_c"; break; }
done
measure_lanes() {
  local out live total z
  LANES=""; LANES_TOTAL="?"; ZOMBIES="?"
  if [ -n "$LANE_REAP_SH" ]; then
    out="$(bash "$LANE_REAP_SH" count 2>/dev/null)"
    # lanes=<live>/<total> zombie=<n>   (one line, no other output)
    live="${out#lanes=}"; live="${live%%/*}"
    total="${out#*/}"; total="${total%% *}"
    z="${out##*zombie=}"
    if is_num "${live:-}" && is_num "${total:-}" && is_num "${z:-}"; then
      LANES="$live"; LANES_TOTAL="$total"; ZOMBIES="$z"
    fi
  fi
  if ! is_num "${LANES:-}"; then
    LANES="$(tmux ls 2>/dev/null | grep -c '^lane-')"
    is_num "${LANES:-}" || LANES=0
  fi
}

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
dispatch_funnel() { # <dispatched_count> <queue_token> [<held_reason>] [<now_epoch>]
  local k="${1:-0}" qtok="${2:-?}" held="${3:-}" now="${4:-}" f key val kv backlog=0
  # ⛔ EVERY ONE OF THESE IS INITIALISED. They are assigned only when their key is present in the
  # record, and under `set -u` a declared-but-unassigned local is UNBOUND: a record missing one key
  # (a rename, a hand-edited or half-synced $O) exited the whole controller — a KeepAlive crash loop
  # on a record that persists. Measured in review round 2: `unj: unbound variable`, exit 1.
  local listed="" judged="" queued="" col="" land="" unj="" sk_ck="" sk_dp="" notr="" at="" reconciled=""
  local age=""
  is_num "$now" || now="$(date +%s)"
  [ -f "$O/state/refresh-funnel" ] && f="$(cat "$O/state/refresh-funnel" 2>/dev/null || true)"
  for kv in ${f:-}; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      listed) listed="$val" ;; judged) judged="$val" ;; queued) queued="$val" ;;
      collision) col="$val" ;; landed) land="$val" ;; unjudged) unj="$val" ;;
      skipped_checked) sk_ck="$val" ;; skipped_dispatched) sk_dp="$val" ;;
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
      printf '[dispatch] %s queued of an UNRECORDED pool (state/refresh-funnel exists but is unreadable/empty) -> %s dispatched%s (queue=%s)\n' \
        "$backlog" "$k" "${held:+ | held: $held}" "$qtok"
    else
      printf '[dispatch] %s queued of an UNRECORDED pool (no state/refresh-funnel — no refresh pass has recorded its funnel yet) -> %s dispatched%s (queue=%s)\n' \
        "$backlog" "$k" "${held:+ | held: $held}" "$qtok"
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
      printf '[dispatch] funnel STALE(%sm > %sm) — the last recorded pass listed %s candidates; %s dispatched THIS cycle%s (backlog=%s, queue=%s)\n' \
        "$age" "${FUNNEL_MAX_AGE_MIN:-30}" "${listed:-?}" "$k" "${held:+ | held: $held}" "$backlog" "$qtok"
      return 0
    fi
  else
    printf '[dispatch] funnel STALE(age unknown — no usable `at=` in state/refresh-funnel) — the recorded pass listed %s candidates; %s dispatched THIS cycle%s (backlog=%s, queue=%s)\n' \
      "${listed:-?}" "$k" "${held:+ | held: $held}" "$backlog" "$qtok"
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
  printf '[dispatch] %s candidates -> %s -> %s dispatched%s (backlog=%s, queue=%s%s)\n' \
    "${listed:-?}" "${joined:-no reason recorded}" "$k" \
    "${held:+ | held: $held}" "$backlog" "$qtok" "${age:+, funnel ${age}m old}"
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
# Exact session-name test. `tmux has-session -t <name>` prefix-matches, so a guard for PR #82
# would report "in flight" because `fix-820` exists — starving #82 while that worker lives.
sess() { tmux ls -F '#{session_name}' 2>/dev/null | grep -qx "$1"; }
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
  # ⛔ THE LEASE ALONE DECIDES — NEVER `claim_live` (review R2, P1). `claim_live` is the SPAWN GUARD and
  # its first arm is a deliberately-loose local-lock pid test; delegating ownership to it let a STALE
  # `mergeclaim-<pr>.lock` whose pid had been recycled make even an EXPIRED foreign lease read live, so
  # a PR left the un-owned queue for ever — the dangerous direction, reached through the cross-box arm
  # after arm 2 was already fixed. One lease reader, no lock arm.
  claim_lease_live "$pr" "$sha"
}
_this_host() { hostname -s 2>/dev/null || echo box; }

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

# ── ONE scan, ONE parser, TWO facts: the unowned count and the youngest unowned PR (#2040) ───────
# `unowned_pr_count` and the merge-priority age probe read the SAME rows, so they must read them the
# SAME way. The first draft of the age probe re-parsed the token and the two disagreed about the
# head — a bug that presented as one PR being counted unowned while its age was read from another
# (measured in review: a 3-field token `number:sha:epoch` left `sha="<sha>:<epoch>"` in the count,
# so every `needsfix-<pr>-<head>` marker stopped matching and EVERY PR read as unowned — inflating
# the very number the gate blocks on). One function, one answer.
#
# Row format: `number:headOid:createdEpoch`. TWO fields is the older on-disk format and is still
# accepted (an aged `state/last-open-prs` must not be misread); the third is absent there.
#
# Echoes `<unowned> <youngest_unowned_created_epoch|->`. The epoch is `-` when no row carries one
# (older format, or `createdAt` was unreadable) — the AGE probe then reports "unmeasurable" and the
# gate RELEASES, which is the documented polarity: block only on evidence actually held.
# ⚠️ POLARITY, ONCE, FOR BOTH FACTS (review, #2040). No rows => NOTHING is owned, so the whole count
# reads as unowned. That used to be "the conservative direction: more unowned CLOSES the gate" —
# and it still is for `unowned`, `review_slots` and `fix_slots` (drain headroom). But since the gate
# is now BOUNDED, a listing that could not be read can no longer keep dispatch shut on this count
# alone: no probe can answer from a deleted row file, so it returns
# unreadable and `mp_reason` RELEASES. That is deliberate and stated: the gate blocks only on
# evidence it actually holds, and an unpriced backlog is not evidence. The fallback above remains
# because it is what the LOG and the budgets report — it is no longer the thing that holds the gate.
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
  L="$(load1)"
  # Read the gh-limit record ONCE per cycle; the token is age-bounded inside (see gh_limit_token).
  GHL="$(gh_limit_token)"
  echo "=== $(date) load=$L lanes=$(tmux ls 2>/dev/null | grep -c '^lane-') backlog=$(wc -l < "$O/candidates.txt" | tr -d ' ') queue=$(queue_state_token)${GHL:+ $GHL} ===" >> "$LOG"

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
    # survives a non-200 sweep (304 keeps the previous cycle's list), so a swept set that reads fully
    # owned IS a normal state in exactly the cycle this fallback exists for. Taking its smaller number
    # there would open the issue path on the very defect this change removes — the one direction that
    # must never happen. Floor it, and say so on its own line (the funnel's arithmetic stays closed
    # per-source; this line states which number the GATE actually used).
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

  printf '%s\n' "$SEL_ROWS" |
  while IFS="$(printf '\t')" read -r PR BR DRAFT OWN; do
    [ -z "${PR:-}" ] && continue
    # Skip anything that is not a plain integer PR / simple ref — never let API data reach a shell.
    is_num "$PR" || { echo "#${PR:-?} SKIPPED (non-numeric PR id)" >>"$LOG"; continue; }
    safe_ref "$BR" || { echo "#$PR SKIPPED (unsafe branch name: $BR)" >>"$LOG"; continue; }
    if [ "${DRAFT:-}" = "true" ]; then
      gh pr ready "$PR" --repo "$OR" >/dev/null 2>&1 && echo "#$PR readied (was a draft)" >>"$LOG"
      continue
    fi
    PR_ST="$(gh pr view "$PR" --repo "$OR" --json state --jq .state 2>/dev/null)"
    # CLOSED too: a PR listed open can close between `gh pr list` and here. The retired sweep.sh
    # guarded both; the live rewrite kept only MERGED, so a closed PR fell through to
    # `gh pr ready` + `gh pr merge` every cycle and logged `#<PR> merge fail` forever.
    case "${PR_ST:-}" in MERGED|CLOSED) continue ;; esac
    HEAD_N="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
    # parked = the fixer cap was reached at THIS head; a later push re-arms the PR.
    [ -n "${HEAD_N:-}" ] && [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" = "$HEAD_N" ] && continue
    # Authority UNKNOWN (unreadable branch protection, above): no merge, no auto-arm, no worker
    # spawns — the one action worse than doing nothing here would be acting on a contract this
    # repo never declared (review P2, round 1).
    [ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && continue
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
          elif claim_live "$PR" "${HEAD_N:-}" || sess "fix-$PR" || sess "merge-$PR"; then
            : # a worker is already rebasing it
          elif [ "$(tmux ls 2>/dev/null | grep -c '^fix-')" -lt "$MF" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            if tmux new-session -d -s "fix-$PR" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'" 2>/dev/null; then
              echo $((NFC + 1)) > "$CF"
              echo "#$PR CONFLICTING -> fixer attempt $((NFC + 1))" >>"$LOG"
            else
              echo "#$PR CONFLICTING, fixer spawn FAILED" >>"$LOG"
            fi
          fi
          continue
        fi ;;
    esac
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
          elif [ "$(tmux ls 2>/dev/null | grep -c '^merge-')" -lt "$MR" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            # ⚠️ carry the RESOLVED contract into the worker (review P2, round 1): the controller
            # resolved REQ/REVIEW_GATE for THIS cycle, but a worker that re-resolves independently
            # can disagree (e.g. an operator REVIEW_GATE the tmux server does not export) and merge
            # under a different authority than the one that classified the PR. Passing the resolved
            # set as the worker's REQ makes it the override — one resolution, one authority.
            # ⛔ shq, never %q: `%q` emits `$'…'` for a non-printable byte and dash does not parse
            # that as quoting, so the value would execute (round-8 adversarial review, B6).
            if tmux new-session -d -s "merge-$PR" "REQ=$(shq "$REQ") REVIEW_GATE=$(shq "$REVIEW_GATE") bash '$O/merge-one.sh' --argv '$O/state/argv-$PR'" 2>/dev/null; then
              echo "#$PR GREEN -> rail worker merge-$PR" >>"$LOG"
            else
              echo "#$PR GREEN but the rail worker spawn FAILED" >>"$LOG"
            fi
          fi
        elif [ "$MERGE_AUTHORITY" = "gate" ]; then
          # ⛔ EXPLICIT `gate` ONLY (round-10 review, P2). This arm used to be a bare `else`, so
          # ANY authority that was not `rail` — INCLUDING `unknown` — reached a RAW `gh pr merge`,
          # the exact bypass this whole change exists to prevent. Allow-list polarity: a raw merge
          # happens only on an authority that NAMES the gate.
          gh pr merge "$PR" --repo "$OR" --squash >>"$LOG" 2>&1 && echo "#$PR MERGED" >>"$LOG" || echo "#$PR merge fail" >>"$LOG"
        else
          echo "#$PR GREEN but the merge authority is '${MERGE_AUTHORITY:-<unset>}' — NO merge (fail-closed: only an explicit 'gate' or 'rail' authority may merge)" >>"$LOG"
        fi ;;
      PENDING:*)
        gh pr ready "$PR" --repo "$OR" >/dev/null 2>&1 || true
        if [ "$MERGE_AUTHORITY" = "gate" ]; then
          gh pr merge "$PR" --repo "$OR" --squash --auto >>"$LOG" 2>&1 && echo "#$PR auto-armed" >>"$LOG" || true
        else
          # RAIL MODE: `--auto` must NOT be armed. It merges the moment the REPO'S required checks
          # pass, which on a rail-managed repo bypasses the rail entirely — the same bypass the
          # GREEN arm avoids. Wait for the next cycle; once every required check is non-red the
          # GREEN arm dispatches the rail.
          echo "#$PR PENDING (rail mode: auto-merge deliberately NOT armed — arming it would bypass the rail)" >>"$LOG"
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
          else
            FIXN="$O/state/fixcount-$PR"; NF="$(cat "$FIXN" 2>/dev/null || echo 0)"
            is_num "$NF" || NF=0
            # a reviewer already reported real issues AT THIS HEAD -> fix them and re-run the chain.
            # otherwise the gate is probably just missing evidence -> re-record (fresh review).
            if [ -n "${HEAD_N:-}" ] && [ -f "$O/state/needsfix-$PR-$HEAD_N" ] \
               && [ "$NF" -lt "${MAX_FIX_TRIES:-3}" ] \
               && can_spawn \
               && [ "$(tmux ls 2>/dev/null | grep -c '^fix-')" -lt "$MF" ]; then
              # Spawn FIRST, bookkeep only on success: recording the attempt before the spawn
              # means a killed/failed spawn consumes one of MAX_FIX_TRIES and deletes the
              # findings marker, so no fixer ever runs and the findings are lost.
              # Args travel in a file, not interpolated into the tmux command string, so no
              # PR-derived value can reach `sh -c`. Only $O (validated at startup) and the
              # numeric $PR are embedded.
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              if tmux new-session -d -s "fix-$PR" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'" 2>/dev/null; then
                echo $((NF + 1)) > "$FIXN"; rm -f "$O/state/needsfix-$PR-$HEAD_N"
                echo "#$PR fixer attempt $((NF + 1))" >>"$LOG"
              else
                echo "#$PR fixer spawn FAILED (attempt not consumed, marker kept)" >>"$LOG"
              fi
            elif [ "$NF" -ge "${MAX_FIX_TRIES:-3}" ] && [ -f "$O/state/needsfix-$PR-$HEAD_N" ]; then
              # Terminal state. Without this the cap just falls through to the re-record branch
              # every cycle: an unfixable PR would burn a full fresh-context review forever.
              park_ctrl "$PR" "${HEAD_N:-}" "still needs fixes after $NF attempts at head=${HEAD_N:-?} (MAX_FIX_TRIES=$MAX_FIX_TRIES) -- a human must decide; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
              echo "#$PR PARKED after $NF fixes at head=${HEAD_N:-?} — needs a human" >>"$LOG"
            elif [ "$(tmux ls 2>/dev/null | grep -c '^merge-')" -lt "$MR" ] && can_spawn; then
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              # Same carried contract as the GREEN rail spawn above (review P2, round 1), and the
              # same shq rule as there: `%q` is dash-unsafe (round-8 adversarial review, B6).
              tmux new-session -d -s "merge-$PR" "REQ=$(shq "$REQ") REVIEW_GATE=$(shq "$REVIEW_GATE") bash '$O/merge-one.sh' --argv '$O/state/argv-$PR'" 2>/dev/null \
                && echo "#$PR re-record" >>"$LOG"
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
          elif claim_live "$PR" "${HEAD_N:-}" || sess "fix-$PR" || sess "merge-$PR"; then
            : # a worker is already on it
          elif [ "$(tmux ls 2>/dev/null | grep -c '^fix-')" -lt "$MF" ] && can_spawn; then
            printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
            if tmux new-session -d -s "fix-$PR" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'" 2>/dev/null; then
              echo $((NFC2 + 1)) > "$O/state/fixcount-$PR"
              echo "#$PR CI-red ($V) -> fixer attempt $((NFC2 + 1))" >>"$LOG"
            else
              echo "#$PR CI-red, fixer spawn FAILED" >>"$LOG"
            fi
          fi
        fi
        if grep -q python-ci-gate <<<"$V"; then
          RID="$(gh pr checks "$PR" --repo "$OR" --json name,link --jq '.[]|select(.name=="python-ci-gate")|.link' 2>/dev/null | sed -nE 's#.*/runs/([0-9]+).*#\1#p')"
          if [ -n "${RID:-}" ] && [ ! -f "$O/state/rerun-$PR-$RID" ]; then
            gh run rerun "$RID" --repo "$OR" --failed >>"$LOG" 2>&1 && { touch "$O/state/rerun-$PR-$RID"; echo "#$PR rerun CI" >>"$LOG"; }
          fi
        fi ;;
    esac
  done
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
  L="$(load1)"; measure_lanes
  # agent-infra#1709 item 4: WORKERS counts the non-lane agent sessions (reviewers + fixers)
  # live at this instant, so the dispatch block line below can distinguish "blocked while the box
  # was idle" (lanes=0 workers=0 -> raising the ceiling helps) from "blocked while busy" (it does
  # not). Total in-flight agents = lanes + workers.
  WORKERS="$(tmux ls 2>/dev/null | grep -cE '^(merge|fix)-')"
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
  # ⛔ THE MERGE-PRIORITY GATE IS HANDED ITS EVIDENCE, NOT ITS CONCLUSION (see mp_reason): the age
  # of the youngest unowned PR, the epoch of the last recorded land, and how long the current block
  # has been held. All three are measured HERE, once, and BEFORE the [cap] line that prints them —
  # measured after it, that line printed `?` on the first cycle and the PREVIOUS cycle's reading on
  # every one after (a stale record presented as current: exactly what this change removes).
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
  # ⛔ `lanes=<live>/<total>` and `zombie=<n>` (#2163). The TOTAL is the field that makes a leak
  # visible: `lanes=14/25` still reads "full" while `lanes=14/76` says the box is carrying 62 finished
  # residents. `max_lanes=` keeps the ceiling the gate applies, so no reader has to infer it.
  echo "[cap] load=$L/$MAX_LOAD lanes=$LANES/$LANES_TOTAL max_lanes=$MAX_LANES zombie=$ZOMBIES mem_avail=${MEMAVAIL_MB}M/${MIN_MEM_FREE_MB}M swap_free=${SWFREE}M/${MIN_SWAP_FREE}M open=${OPEN_N:-?}@${OR:-?} unowned=${UPN:-?} last_land=${LAND_AGE:-?}m review_slots=${MR:-?} fix_slots=${MF:-?}" >> "$LOG"
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
    lo_select "$SEL_TOTAL" "${OWN_N:-0}" "${UPN_WORK:-${UPN:-?}}" "${SEL_PARKED:-0}" "${FIRST_PR:--}" "${GATE_WHY:-}" "$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')" > "$SELFILE" 2>/dev/null || true
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
    echo "[dispatch] issues BLOCKED — ${UPN_WORK:-?} un-owned PR(s) remain; this cycle's work is the PR queue (first #${FIRST_PR:--})" >> "$LOG"
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
  if [ "${LO_CHOICE:-issue}" != "issue" ] && [ -z "$GATE_WHY" ]; then
    GATE_WHY="selection (funnel chose '${LO_CHOICE:-?}', not issues)"
  fi
  if [ -z "$GATE_WHY" ]; then
    : > "$O/.batch"; K=0
    while read -r ISS; do
      [ -z "${ISS:-}" ] && continue
      grep -qx "$ISS" "$O/dispatched.txt" 2>/dev/null && continue
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
      dispatch_funnel "$K" "$(queue_state_token)" >> "$LOG"
      echo "[dispatch] load=$L lanes=$LANES -> $(tr '\n' ' ' < "$O/.batch")" >> "$LOG"
      bash "$O/dispatch-merge.sh" "$REPO" "$OR" $(tr '\n' ' ' < "$O/.batch") >> "$LOG" 2>&1
    # ⛔ "backlog empty" IS A CLAIM, NOT A NEUTRAL FACT (agent-infra#1931). On its own it reads as
    # "the fleet has nothing to do", and the SAME line was printed when 223 candidates had been READ
    # and every one of them was filtered away (#2040) — the contradiction that hid a total dispatch
    # stop for hours. The funnel replaces it: it names where the candidates went, and `queue=EMPTY`
    # remains the only form that means "no work".
    else dispatch_funnel 0 "$(queue_state_token)" >> "$LOG"; fi
  else
    dispatch_funnel 0 "$(queue_state_token)" "$GATE_WHY" >> "$LOG"
    echo "[dispatch] skipped ($GATE_WHY) lanes=$LANES workers=$WORKERS" >> "$LOG"
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
