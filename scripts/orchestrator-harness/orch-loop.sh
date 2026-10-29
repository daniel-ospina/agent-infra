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
# that EXISTS but is the wrong repo — #1935/#1977 closed that one too: refresh-candidates.sh no longer
# carries a default of its own either, it derives the checkout and VERIFIES the origin, or refuses.) A path is not a thing this repo can guess — the daemon gets it from install.sh
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
# The directory of the RUNNING script, named once: `resolve_refresh_sh` looks beside the loop for a
# refresh that can write the pass record this loop reads (agent-infra#2308), and the SEED-SKEW line
# names it as the copy the controller itself runs. `_HERE_RS` already resolved it for repo-slug.sh.
# ⛔ THE ENV FORM IS HONOURED ON PURPOSE, and it was NOT (review P2): the unconditional assignment made
# the knob inert on the shipped entrypoint, so the only way to exercise "a capable copy BESIDE the
# loop" was the suite's sourced excerpt. It is a LOOK-HERE hint only — `$O` is still tried first and
# the capability probe still decides, so an ambient value cannot make an incapable copy executable.
REFRESH_SELF_DIR="${REFRESH_SELF_DIR:-$_HERE_RS}"
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
    _fatal_rs="FATAL repo-slug.sh in $O is stale/partial (no derive_or) — re-seed it: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O"
    echo "orch-loop: $_fatal_rs" >&2
    [ -d "$O" ] && { mkdir -p "$O/logs" 2>/dev/null; echo "$(date) [startup] $_fatal_rs" >> "$O/logs/orch-loop.log" 2>/dev/null; }
    exit 78
  }
# ── THE PRE-DISPATCH DISK FLOOR (agent-infra — two cells stopped dispatching on bytes, one night) ──
# A cell whose filesystem fills stops dispatching ENTIRELY and presents as something else: a controller
# that stopped beating with its unit still `active`, or a refresh that failed at
# `stage=provision sub-step=scout-venv` because `uv sync` could not write a torch library. Both were
# BYTES; freeing them fixed both instantly (864MB -> 9378MB). The floor lives in disk-floor.sh, SHARED
# with refresh-candidates.sh for the same reason repo-slug.sh is shared: the loop's cycle and the
# refresh's provision stage must answer this question ONE way, or a box can hold one and provision the
# other. Resolved like repo-slug.sh ($O first, then beside the loop) so a re-seed and a checkout agree.
# ⛔ A MISSING/STALE COPY IS NOT FATAL HERE, AND THAT IS DELIBERATE. `derive_or` above is fatal because
# a wrong guess grades the WRONG REPO — a silent wrong answer. A missing floor is a DEPLOY SKEW, and
# refusing to start the controller over it would take a healthy box down to fix a log line. The cycle
# says CANNOT-VERIFY, once per cycle, and proceeds unguarded for that cycle only: the disclosure is
# what keeps it out of the silent class, and the next re-seed restores the gate.
DISK_FLOOR_STATE=absent    # absent | ok  (decided at load; the CYCLE reads it)
for _dfc in "${O:-}/disk-floor.sh" "${_HERE_RS:-}/disk-floor.sh"; do
  [ -n "$_dfc" ] && [ -f "$_dfc" ] || continue
  # shellcheck disable=SC1090
  . "$_dfc" 2>/dev/null || continue
  # ⛔ THE FILE IS NOT THE FUNCTION (repo-slug.sh's rule, same reason): a stale copy sources cleanly and
  # defines nothing, and a gate that silently does not exist reads exactly like a floor that is met.
  command -v disk_floor_gate >/dev/null 2>&1 || { unset -f disk_floor_gate disk_floor_free_mb 2>/dev/null; continue; }
  DISK_FLOOR_STATE=ok; DISK_FLOOR_SRC="$_dfc"; break
done
[ "$DISK_FLOOR_STATE" = "ok" ] || DISK_FLOOR_STATE=absent
OR_EXPLICIT="${OR:-}"
# ⛔ WHETHER THE OPERATOR NAMED OR, TOLD TO THE CHILD EXPLICITLY (#1977 review, P1). The export
# below is UNCONDITIONAL (#2040), so the child cannot tell an operator's `OR=…` from the default this
# script fell back to — and it must: refresh-candidates.sh REFUSES a checkout whose `origin` is a
# local path only when the queue target was DECLARED, because a path cannot prove a declared pair.
# Reading mere presence as "declared" therefore condemned the exact box the warning below calls
# legitimate (a local mirror / file:// origin), turning a WARN into a dead cell on every pass.
OR_OPERATOR_DECLARED=0
[ -n "$OR_EXPLICIT" ] && OR_OPERATOR_DECLARED=1
export OR_OPERATOR_DECLARED
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
  # ⛔ THIS IS A GRADING DECISION ONLY (#2762 review, 5th cycle, P2). Dispatch is stricter on purpose:
  # `repo-target.sh` compares the ARTIFACT (the worktree's own origin) with the target, so on a box
  # whose origin cannot name a repo EVERY batch is refused 72 — and `set OR=…` cannot help, because
  # the pin is what the artifact is compared TO. The remedy is re-pointing the checkout's origin
  # (`git -C <checkout> remote set-url origin https://github.com/<owner>/<name>.git`); there is
  # deliberately no env override, since an escape hatch that opens the gate is the fail-open the gate
  # exists to remove. Named here so a mirror-origin cell is a known state, not a mystery.
  _or_warn="WARN cannot derive owner/name from REPO=$REPO origin remote ('$(git -C "$REPO" remote get-url origin 2>/dev/null || echo none)') — grading $OR; set OR=<owner/name> to name the repo explicitly"
  echo "orch-loop: $_or_warn" >&2
  [ -d "$O" ] && echo "$(date) [startup] $_or_warn" >> "$O/logs/orch-loop.log" 2>/dev/null
fi
# ⛔ EXPORTED, AND THAT IS LOAD-BEARING (#2040 review). `refresh-candidates.sh` reads its LISTINGS
# from $OR, and it runs as a CHILD — `bash "$REFRESH_SH" 6`, where `$REFRESH_SH` is the copy
# `resolve_refresh_sh` RESOLVED for this cycle (the seed in $O when it can record, a recording copy
# beside the loop when the seed cannot — #2308; the spawn site names no hardcoded path any more).
# A DERIVED value never reached this script through the environment, so without this export the child
# re-derives its own default — the pool would come from one repo while the controller graded another.
# (Before this change the same held true, consistently: both sides used the same literal.)
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
# ── THE GATE DECISION IS MEASURED, NOT ASSUMED (agent-infra#2319) — see lane.sh for the full note.
# The controller is a shell, but every child it spawns INHERITS its environment, so this export used to
# be the fleet-wide permanent bypass even on carriers that also set it themselves.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gate-policy.sh" 2>/dev/null || { echo "orch-loop: FATAL: gate-policy.sh missing — refusing to run a controller that cannot say whether its gates are on" >&2; exit 78; }
apply_gate_policy orch-loop

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
# ── THE PRODUCT WORK FLOOR (agent-infra#2054) ────────────────────────────────────────
# WHY IT EXISTS: the fleet's product/harness MIX is not guaranteed by anything. Harness work has a
# dispatch path that bypasses PRIORITISATION entirely (`nonblocking-dispatch.sh`: an orchestrator
# backgrounds a worker by decision — that path reads no backlog, no tier, no collision pre-flight and
# no lane budget, although it DOES pass the same load gate through `spawn-gate.sh run_agent`, #1720),
# while product work goes through the queue. So the day the queue drains into harness and docs work, the fleet spends all of its capacity
# on its own machinery while product P0/P1s sit idle — and "dispatch is working" is still true, which is
# what makes it silent. Measured 2026-10-18: that bypass path carried 6 harness workers while the
# product channel carried zero.
# WHAT IT IS: a REORDERING WITHIN ONE BATCH. At most PRODUCT_FLOOR of the batch is filled from
# `candidates.product.txt` first; the rest is the merged backlog exactly as before. It adds no
# candidate, removes none, re-verifies nothing, and sits AFTER the merge-priority gate — so it can
# never delay a batch or outrank a drain.
# WHAT IT IS NOT: a cap. The fleet is never reduced to meet it (a floor, not a quota), and an unmet
# floor LOGS AND DEGRADES: refusing to dispatch because no product work is available would be a worse
# failure than the one this prevents.
PRODUCT_FLOOR="${PRODUCT_FLOOR:-1}"
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
# ── AGENT_GH_REAL: pin the ONE real gh this box resolves (agent-infra#2320) ──────────────────────
# MEASURED 2026-10-22: the wrapper chain `gh-limit -> gh-rest -> .pi/agent/shims/gh` resolved to
# ITSELF on the owner's Mac, gh-limit refused at depth 2, and every gh call returned EMPTY — so the
# merge contract read UNREADABLE and NOTHING could land for hours. The shim's own resolution is what
# hopped; a pin exported HERE (per box, DISCOVERED from PATH, never a hardcoded home) means no layer
# needs to guess again. Best-effort and quiet by design: a box with no real gh keeps its current
# behaviour, and `bin/harness status` NAMES that state — a controller that refuses to start because
# its gh could not be pinned would be a worse failure than the one this prevents.
# ⛔ GUARDED ON THE INTERFACE, like every other module here: an `$O` predating this change defines no
# `ensure_agent_gh_real`, and an unguarded call would print a 127 into the cycle log on every pass.
if command -v ensure_agent_gh_real >/dev/null 2>&1; then ensure_agent_gh_real || true; fi

# ── THE NOCHECKS ARM'S TWO FILES (agent-infra#2719) ──────────────────────────────────────────────
# `$O` first (the pinned deployment this controller runs from), the running script's own directory
# second — the same look-here order repo-authority.sh gets, and for the same reason: a rolling deploy
# leaves `$O` one file behind for one cycle, and a harness that can only find its own arm in one of the
# two places would fail exactly then. ⛔ An ABSOLUTE path, resolved ONCE, because the sweep is a
# pipeline subshell and a relative path resolved inside it would follow the subshell's cwd.
# ⛔ `check-class.py` IS NOT "ONE ARM" — IT IS EVERY PR'S CLASSIFICATION, SO ITS ABSENCE FAILS CLOSED
# (review P2, agent-infra#2719). Measured: with the file missing, `python3 <missing>` writes to stderr
# and prints nothing, so `V=""` for EVERY PR — no merge arm, no fixer arm, no reviewer — and the sweep
# falls to the residual `*)` wait arm, re-reading each PR for ever with class `""`. That is a total,
# indefinite stop of the controller's work, so it takes the `exit 78` treatment `repo-authority.sh`
# already gets a few lines above, NOT a warning: a warning on a box whose classification has stopped
# is the "one startup line nobody reads" failure.
# `nochk-resolve.py` is genuinely ONE ARM: without it a NOCHECKS PR is named `READ-FAILED: the arm
# produced no verdict` and re-read next cycle — degraded, honest, not fatal — so that one only warns.

mkdir -p "$O/logs" "$O/state"
LOG="$O/logs/orch-loop.log"
# ── THE WORKER LAUNCHER (worker-terminal.sh) ────────────────────────────────────
# Every worker this loop starts — fixers, reviewers, rail workers — is started, counted and killed
# through ONE module. That is not tidiness: the launcher, the census the caps read, and the reaper
# must all move together or the caps stop binding (a census that still counts `tmux ls` reports 0
# workers for durable terminals and the ceiling never trips). ⛔ On a Linux cell the module's own
# `wt_launcher` decides between a durable terminal (cmux answers) and tmux with an explicit
# HOME+keys.env contract (it does not) — the `~21 log lines` death that once made a cell resolve to
# `none` was an ENVIRONMENT failure, not a tmux one (agent-infra#2210, reopened 2026-10-22), and
# resolving to `none` refused every spawn on every cycle. See that file's header for the measurements
# and for the refusal stance.
for _wt_cand in "$O/worker-terminal.sh" "$(dirname "${BASH_SOURCE[0]:-$0}")/worker-terminal.sh"; do
  [ -f "$_wt_cand" ] && { WT_MOD="$_wt_cand"; break; }
done
[ -n "${WT_MOD:-}" ] && . "$WT_MOD"
# ⛔ A PRESENT-BUT-STALE COPY IS THE SAME DEFECT AS AN ABSENT ONE: if the module does not define the
# verbs this controller actually calls, a spawn silently becomes "no session", the census reports an
# empty box and the loop prints a healthy idle controller. So the guard covers EVERY verb used below —
# not just the three that look load-bearing (`wt_startup_banner` feeds the startup line and
# `wt_table` feeds the reap, and a module missing either would leave the controller logging
# `launcher=` with no reason and 0 workers).
for _wt_v in wt_spawn wt_alive wt_count wt_close wt_launcher wt_launcher_why wt_startup_banner wt_table; do
  command -v "$_wt_v" >/dev/null 2>&1 || { echo "orch-loop: FATAL worker-terminal.sh is missing or stale at ${WT_MOD:-$O} (no $_wt_v; needs wt_spawn/wt_alive/wt_count/wt_close/wt_launcher/wt_launcher_why/wt_startup_banner/wt_table) — refusing to run a controller that cannot start, count or reap its workers; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O" >&2; exit 78; }
done
# ⛔ DEFINING THE VERBS IS NOT HAVING INITIALISED THE MODULE (#2248). The verbs above are FUNCTIONS;
# the two embedded Python programs are VARIABLES assigned by a command substitution at source time,
# and a substitution can come out empty while every function still parses. That is exactly what a
# bash 3.2 mis-parse produced on macOS: `WT_TREE_PY` never got a value, the census fed `python3 -c ''`
# and returned nothing — which reads identically to "no workers" — so the caps silently stopped
# binding and the box logged a `controller … alive but the heartbeat is 3652s old` for an hour while
# `launchctl` and `harness verify` both said GREEN. Check the DATA, and NAME the variable that is
# empty, so the next occurrence costs one log line instead of an hour of false green.
for _wt_py in WT_TREE_PY WT_WS_PY; do
  [ -n "${!_wt_py:-}" ] || { echo "orch-loop: FATAL worker-terminal.sh did not initialise at ${WT_MOD:-$O} — $_wt_py is EMPTY (its embedded Python program was not assigned; on bash 3.2 this is the heredoc-in-command-substitution mis-parse, see agent-infra#2248) — refusing to run a controller whose census would read 0 workers and never trip its caps; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O" >&2; exit 78; }
done
# Where a worker is started from. A tmux session inherited the controller's cwd implicitly; a durable
# terminal's login shell starts in the DAEMON's idea of a cwd, so it is passed explicitly now. The
# workers cd to their own repo/worktree themselves, so this only has to be a sane, existing place.
SPAWN_CWD="$(pwd)"
# Say which launcher this surface got, ONCE, at startup — and WHY when it got none
# (agent-infra#2366). The line is built by `wt_startup_banner` in worker-terminal.sh, beside the verb
# whose verdict it reports, so the shipped text is the text a test drives; a cell that quietly landed
# on `none` would otherwise look like a controller with nothing to do — the exact false green this
# line exists to remove — and `launcher=none` alone names a verdict with no cause.
wt_startup_banner >> "$LOG"
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

# ⛔ THIS BLOCK SITS BELOW `safe_ref()` ON PURPOSE (agent-infra#2719). Several shipped suites
# extract a one-line helper with `sed -n "/^$1()/,/^}/p"`; `is_num()` is such a one-liner, so its
# extraction runs to the NEXT `^}` — anything placed above that brace is swallowed into those
# fixtures, and this block is evaluated in their `set -u` subshell (measured: placing it higher
# took capacity-transfer.test.sh from 90/0 to 89/4 with `_HERE_RS: unbound variable`). Below the
# brace, every peer extraction is unchanged.
# ⛔ THE LOG DIRECTORY IS MADE FIRST (review P3, agent-infra#2719): this message fires exactly on a
# fresh or partially re-seeded `$O`, which is exactly when `$O/logs` may not exist yet — writing the
# warning before the `mkdir -p` below meant the ONE case it exists for was the one where the redirect
# failed and the warning vanished. Same order the repo-slug.sh fatal paths use.
mkdir -p "$O/logs" 2>/dev/null || true
_CK_PY="$O/check-class.py"; [ -f "$_CK_PY" ] || _CK_PY="$_HERE_RS/check-class.py"
_NCHK_PY="$O/nochk-resolve.py"; [ -f "$_NCHK_PY" ] || _NCHK_PY="$_HERE_RS/nochk-resolve.py"
[ -f "$_CK_PY" ] || _CK_PY=""
[ -f "$_NCHK_PY" ] || _NCHK_PY=""
# ⛔ THE STARTUP GUARD LIVES IN ITS OWN MODULE (review P1, agent-infra#2719), for a reason that is
# measured rather than stylistic: several shipped suites extract a ONE-LINE helper with
# `sed -n "/^$1()/,/^}/p"`, so ANY new function with a closing `}` above that point silently re-points
# their extraction — inserting this guard inline took `capacity-transfer.test.sh` from 90/0 to 89/4
# (`_HERE_RS: unbound variable` from the swallowed text). `$O` first, the running script's own
# directory second, the same look-here order repo-authority.sh gets.
if [ -f "$O/nochk-guard.sh" ]; then . "$O/nochk-guard.sh"
elif [ -f "${_HERE_RS:-}/nochk-guard.sh" ]; then . "${_HERE_RS:-}/nochk-guard.sh"
fi
# ⛔ THE MODULE ITSELF CANNOT BE ABSENT: without it the guard below would be a "command not found"
# (127) and the loop would carry on with an unclassified sweep — the fail-open this guard exists to
# prevent, one layer up.
command -v nochk_require_classifier >/dev/null 2>&1 \
  || { _fatal_guard="FATAL nochk-guard.sh is missing (looked in $O and ${_HERE_RS:-<unresolved>}) — the controller cannot prove it can classify a single PR, so it refuses to start; re-seed it: bash $O/deploy-harness.sh --src <harness checkout> --o $O"; echo "orch-loop: $_fatal_guard" >&2; printf '%s [startup] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_fatal_guard" >> "$O/logs/orch-loop.log" 2>/dev/null || true; exit 78; }
nochk_require_classifier "$_CK_PY" "$_NCHK_PY" "$O" "$_HERE_RS"

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
# ⛔ THE REVIEW ROLE'S BUDGET IS THE SAME KIND OF LIMIT, AND IT IS READ HERE NOW (agent-infra#2653).
# `MAX_REVIEW_TRIES` was merge-one.sh's alone; the controller now keys its OWN review dispatches on
# it (`review_disp_decide`), so it is coerced on the same line and to the same default (3) merge-one
# ships — a divergence would put two budgets on one head. `0` stays valid: it means "never re-dispatch
# a review at a head the controller already spent one on".
is_limit "${MAX_REVIEW_TRIES:-}"   || MAX_REVIEW_TRIES=3
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
# measure_mem — the ONE place MEMAVAIL_MB / MEM_UNKNOWN are SET (agent-infra#1732).
#
# ⛔ ONE SEAM, TWO DECISION POINTS, NO SECOND DERIVATION. It read this pair INLINE in the [cap] block
# only — measured on the pre-fix tree: ~620 lines BELOW the FIRST of the six spawn sites, ~225 below
# the last, and ~2,000 below `can_spawn()`'s own definition — so a gate that "consults" these values is
# reading the PREVIOUS cycle's figure, or (cycle 1) nothing at all. Both are a stale record
# presented as current, the exact class this file keeps removing. The function is called at the cycle
# prologue (before the FIRST spawn site) and again at the [cap] block (dispatch decides on a fresh
# reading); the coercion lives HERE so the two cannot disagree about what a failed probe means.
# Polarity is UNCHANGED and deliberate: a probe failure is UNKNOWN, not ample — we cannot see capacity,
# so we do not add work. `MEMAVAIL_MB=0` is set with it so any consumer that compares only the number
# still refuses; MEM_UNKNOWN is kept for consumers that must name WHY.
measure_mem() {
  if MEMAVAIL_MB="$(mem_avail_mb)"; then
    MEM_UNKNOWN=0
  else
    MEMAVAIL_MB=0; MEM_UNKNOWN=1
  fi
  # ⛔ COERCE like L / SWFREE / SWTOTAL (#1985 review, P2). Those three are is_num-guarded; MEMAVAIL_MB
  # was not, so an empty value reached `[ "$MEMAVAIL_MB" -le … ]` as `[: : integer expression expected`
  # — an ERRORED test, which is FALSE, which leaves GATE_WHY empty and OPENS the gate. Unreachable
  # through mem_avail_mb() today, but it is the one seam where a probe fault would admit work.
  if ! is_num "${MEMAVAIL_MB:-}"; then MEMAVAIL_MB=0; MEM_UNKNOWN=1; fi
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

# ── OWNERSHIP PROOF-OF-LIFE AND THE DRAIN ESCAPE (agent-infra#2831) ──────────────────────────────
# `pr-owner-liveness.sh` answers two questions the loop could not answer about itself: "is the thing
# that claims this PR still ALIVE?" and "when the PR path has started nothing for N stalled passes,
# does the box ever get to do its other job?". Sourced from the SAME two homes as every module here,
# and gated on the INTERFACE (`declare -f`), not on the file — a present-but-stale `$O` copy must
# degrade to the pre-#2831 behaviour (the loose lock guard, and no escape) and SAY so, never enable
# half of it. A silent absence would read exactly like a working proof.
PL_MOD=0
_pl_mod=""
if [ -f "$O/pr-owner-liveness.sh" ]; then _pl_mod="$O/pr-owner-liveness.sh"
elif [ -f "$(dirname "$0")/pr-owner-liveness.sh" ]; then _pl_mod="$(dirname "$0")/pr-owner-liveness.sh"
fi
if [ -n "$_pl_mod" ]; then
  # shellcheck source=/dev/null
  . "$_pl_mod"
fi
if declare -f pl_verdict pl_escape_open pl_escape_line pl_escape_record pl_note_pass pl_idle_streak pl_streak_reset pl_escape_bound >/dev/null 2>&1; then
  PL_MOD=1
elif [ -n "$_pl_mod" ]; then
  printf '[select] pr-owner-liveness.sh is present but INCOMPLETE (needs pl_verdict/pl_escape_open/pl_escape_line/pl_escape_record/pl_note_pass/pl_idle_streak/pl_streak_reset/pl_escape_bound) — PR ownership keeps the loose lock guard and DRAIN STALLED keeps its old no-action verdict this cycle\n' >> "$LOG" 2>/dev/null || true
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
  printf '[redfix] rail-refusal.sh is present but INCOMPLETE (needs rail_refusal_field/get/record/class/clear) — every stored rail refusal is IGNORED this cycle; a rail refusal therefore spawns no fixer. Re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o '"$O"'\n' >> "$LOG" 2>/dev/null || true
fi
# ⛔ AND WHEN THE MODULE IS ABSENT ALTOGETHER: no reader exists, so a record already on disk would be
# a refusal nobody acts on and nothing would say so. One line, only while such records exist.
if [ "${REDFIX:-0}" != "1" ]; then
  _rf_orphan=""
  for _f in "$O"/state/railrefusal-*; do [ -f "$_f" ] && { _rf_orphan="$_f"; break; }; done
  [ -n "$_rf_orphan" ] && printf '[redfix] rail-refusal.sh is MISSING (looked in \$O and the script directory) but %s exists — that refusal is IGNORED, so no red-fixer can be spawned for it. Re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o '"$O"'\n' "$_rf_orphan" >> "$LOG" 2>/dev/null || true
fi

# ── FLEET CAPACITY + THE CYCLE RECORD (agent-infra, measured 2026-10-21) ────────
# Two modules, one per half of the same defect: how a LANE is placed across boxes
# (`capacity.sh`), and how this box PROVES it is cycling (`cycle-record.sh`).
# Both are sourced from the SAME two homes and gated on the INTERFACE, like every other module
# here: `$O` is the runtime copy, the script's own directory is the fallback for a box whose `$O`
# predates this change (a fresh controller on an un-seeded `$O` STILL records its cycles — that is
# the whole point, since the unproven case is exactly a box nobody re-seeded). A missing module is
# a DEGRADE, never a crash, and it is named on every cycle it applies to: the local gate chain is
# what dispatches when placement cannot answer, and a box that cannot record is one whose heartbeat
# claim nobody can check (so the status verb reads ABSENT, not HEALTHY).
_cap_mod=""; _cr_mod=""
for _dir in "$O" "$(dirname "$0")"; do
  [ -f "$_cap_mod" ] || [ ! -f "$_dir/capacity.sh" ]    || _cap_mod="$_dir/capacity.sh"
  [ -f "$_cr_mod" ]  || [ ! -f "$_dir/cycle-record.sh" ] || _cr_mod="$_dir/cycle-record.sh"
done
[ -n "$_cap_mod" ] && . "$_cap_mod"
if declare -f cap_probe_local cap_place cap_read_fleet cap_publish >/dev/null 2>&1; then CAPACITY=1; else
  CAPACITY=0
  [ -n "$_cap_mod" ] && printf '[capacity] capacity.sh is present but INCOMPLETE (needs cap_probe_local/cap_place/cap_read_fleet/cap_publish) — placement falls back to the LOCAL gates only; work is NOT moved off a saturated box\n' >> "$LOG" 2>/dev/null || true
fi
[ -n "$_cr_mod" ] && . "$_cr_mod"
if declare -f cycle_record_write cycle_verdict >/dev/null 2>&1; then CYCREC=1; else CYCREC=0; fi

# ── FORK HEADROOM, AND THE ONE PATH THAT MAY NOT FORK (agent-infra#2293) ────────────────────────
# MEASURED 2026-10-21: local `com.eldato.orchestrator-loop` recorded a last exit of **128** and NEVER
# CAME BACK. The mechanism is measured on this tree's bash (5.2.21): a failed `fork()` does not return
# an error to the script — bash prints `fork: retry: …` four times, then `fork: Resource temporarily
# unavailable`, and THE SCRIPT EXITS (rc 254; a `while` loop dies on its first failed fork). launchd's
# KeepAlive then relaunches — which needs the very fork that is failing — so a fork-exhausted box has
# no recovery from inside OR from its supervisor. The only survivable design is: DO NOT MAKE THE FORK.
#
# So the cycle reads fork headroom FIRST (before `date`, before `git`, before anything that spawns),
# and when the box is starved it takes a path built from BUILTINS ONLY: it records the state and naps
# on FOOTER_FIFO (a `read -t` on a pre-opened FIFO — no child process), then retries afterwards. The
# box still cannot be repaired from inside (the issue says so), but the controller stays ALIVE and
# NAMED instead of vanishing into a launchd respawn loop that cannot start.
#
# ⛔ THE HEADROOM READ IS `capacity.sh`'S, NEVER A SECOND ONE (`cap_procs_pair_vars` /
# `cap_fork_bound`). This file already sources that module; a private count here would be the
# duplication the house rule forbids and it would drift from the number placement refuses on.
FORK_STATE=unknown; FORK_WHY=""; FORK_PROCS="?"; FORK_MAX="?"; FORK_HEADROOM="?"; FORK_STARVED=0
FORKFREE_FD_OPEN=0

# cycle_now <varname> — the epoch, WITHOUT FORKING when the shell can do it.
# `printf '%(%s)T'` is a bash builtin (4.2+); bash 3.2 (macOS) has no such format, so the fallback
# derives the epoch from the last MEASURED stamp plus bash's own `SECONDS` counter. The derivation is
# labelled at its use site (`start_src=derived`) so no reader mistakes it for a measured clock.
LAST_EPOCH=""; LAST_SECONDS=""
cycle_now() {
  local __out=""
  printf -v __out '%(%s)T' -1 2>/dev/null || __out=""
  case "$__out" in
    ''|*[!0-9]*)
      if [ -n "${LAST_EPOCH:-}" ] && [ -n "${LAST_SECONDS:-}" ]; then
        printf -v "$1" '%s' "$(( LAST_EPOCH + SECONDS - LAST_SECONDS ))"; return 0
      fi
      return 1 ;;
    *) printf -v "$1" '%s' "$__out"; return 0 ;;
  esac
}

# clock_seed — ANCHOR THE DERIVED CLOCK ONCE, AT STARTUP (review P1, agent-infra#2293).
# bash 3.2 (macOS — what launchd's `/bin/bash` runs, per launchd.plist.template) has no `printf '%(…)T`,
# so `cycle_now` DERIVES the epoch from `LAST_EPOCH + SECONDS - LAST_SECONDS`. The anchor used to be set
# only from a MEASURED stamp — which the starved path cannot take — so a controller whose FIRST cycle
# was held wrote `start=0` on every held cycle FOREVER (`_ft0` can never leave 0 once 0: setting the
# anchor is exactly what the missing measurement would have done). Aged against epoch 0 that record is
# "infinitely old", so `harness status` answered DEGRADED — "start it" — about a controller that was
# alive and writing, which is the wrong remedy on the box that most needs the right one.
# One measurement at startup costs nothing new: this script has already forked several times by here
# (module resolution, mkdir, the FIFO), and NOTHING on the starved path forks after it.
# A seed that cannot be taken leaves the 0-stamp path in place, which `cycle_verdict` reports as
# UNREADABLE (`newest_record_unstamped`) — never as a stale record.
clock_seed() {
  [ -n "${LAST_EPOCH:-}" ] && [ -n "${LAST_SECONDS:-}" ] && return 0
  local __s=""
  printf -v __s '%(%s)T' -1 2>/dev/null || __s=""
  case "$__s" in ''|*[!0-9]*) __s="$(date +%s 2>/dev/null)" ;; esac
  case "$__s" in ''|*[!0-9]*|0) return 1 ;; esac
  LAST_EPOCH="$__s"; LAST_SECONDS="$SECONDS"
  return 0
}
clock_seed || true

# fork_free_sleep <seconds> — wait WITHOUT spawning a process (rc 1 = no fork-free timer available).
# `read -t` on a FIFO opened read-write blocks in select(2): no child, no exec. Verified under
# `ulimit -u 5` on a box that could not fork at all: it waited the full 2s and returned 142.
# The FIFO is created ONCE at startup (when forks still work); on the starved path we may not.
fork_free_sleep() {
  local secs="${1:-60}" rc=0
  case "$secs" in ''|*[!0-9]*) secs=60 ;; esac
  [ "$secs" -ge 1 ] || secs=1
  [ "${FORKFREE_FD_OPEN:-0}" = "1" ] || return 1
  read -t "$secs" -r -u 9 _myforkfree_tick 2>/dev/null; rc=$?
  # 0 = someone wrote (nobody should), >128 = the timeout we asked for: both mean the nap happened.
  [ "$rc" -eq 0 ] || [ "$rc" -gt 128 ] || return 1
  return 0
}

# fork_gate — THE FIRST READ OF THE CYCLE. Sets FORK_STATE (ok|starved|low|unknown) and FORK_WHY.
# ⛔ THE GATE IS NOT FORK-FREE, AND AN EARLIER VERSION OF THIS COMMENT IMPLIED IT WAS (review P3). What
# the design guarantees is narrower and is the part that matters: the PROBE runs in a `( )` child, so a
# refusal inside it costs the CHILD (rc 254) instead of the controller. The PAIR READ spends real forks —
# each `$( )` around a leaf reader is one, and macOS's process count is a `ps | wc | tr` pipeline — which
# `capacity.sh` states plainly at `cap_procs_pair_vars` ("It is NOT claimed to be fork-free"). The
# consequence is not hidden: on a box ALREADY at the wall this gate can die before it answers, which is
# why the STARVED BRANCH below it is builtins-only and why a held cycle is entered as soon as headroom
# reads LOW instead of waiting for the probe to fail.
fork_gate() {
  FORK_STATE=unknown; FORK_WHY=""; FORK_STARVED=0; FORK_PROCS="?"; FORK_MAX="?"; FORK_HEADROOM="?"
  [ "${CAPACITY:-0}" = "1" ] && declare -f cap_procs_pair_vars >/dev/null 2>&1 || return 0
  if ! cap_procs_pair_vars FORK_PROCS FORK_MAX _fork_src; then
    FORK_PROCS="?"; FORK_MAX="?"; FORK_HEADROOM="?"
    # No count and no ceiling: UNKNOWN, not fine. The probe below still answers the only question that
    # matters (can this box fork at all), so an unreadable pair is not by itself a refusal.
    FORK_STATE=unknown
  else
    cap_h_for_vars "$FORK_PROCS" "$FORK_MAX" FORK_HEADROOM || FORK_HEADROOM="?"
    if [ "$FORK_HEADROOM" != "?" ] && [ "$FORK_HEADROOM" != "unbounded" ] \
       && [ "$FORK_HEADROOM" -lt "${CAP_MIN_FORK_HEADROOM:-200}" ]; then
      FORK_STATE=low
      FORK_WHY="fork_headroom=${FORK_HEADROOM}<min_fork_headroom=${CAP_MIN_FORK_HEADROOM:-200}(procs=${FORK_PROCS}/${FORK_MAX}, src=${_fork_src:-?})"
    fi
  fi
  # The two-fork probe, IN A CHILD. rc 254 = the child could not fork => this box cannot spawn.
  local _prc=0
  ( cap_fork_probe ) >/dev/null 2>&1 || _prc=$?
  if [ "$_prc" -eq 254 ]; then
    FORK_STATE=starved; FORK_STARVED=1
    FORK_WHY="fork_probe_failed(rc=254_EAGAIN, procs=${FORK_PROCS}/${FORK_MAX})"
  elif [ "$_prc" -ne 0 ] && [ "$FORK_STATE" = "unknown" ]; then
    FORK_STATE=unknown; FORK_WHY="fork_probe_unreadable(rc=$_prc)"
  elif [ "${FORK_STATE:-unknown}" = "low" ]; then
    # LOW HEADROOM IS TREATED AS STARVED FOR THIS CYCLE'S OWN FORKING, and that is the whole
    # predictive point: the box can still fork (the probe passed), so the safe move is to spend no
    # more forks than necessary, not to spend them until the probe starts failing.
    FORK_STARVED=1
  fi
  return 0
}
# ── CI BACK-PRESSURE (measured 2026-10-22) ─────────────────────────────────────
# The THIRD capacity surface, and the one every gate above is blind to: `load=`, `mem_avail=`,
# `swap_free=` and `capacity-placement` all read THIS BOX, so a box with 20 idle lane slots in front
# of a 92-deep CI queue reads perfectly healthy and dispatches into it. Measured 2026-10-22 13:40:
# tortoise queued=92 running=6 on 5 runners; agent-infra queued=97 running=7 — after a batch of
# rebases took agent-infra from 4 to 31 BLOCKED PRs at once. Nothing finished because everything
# started, and merges/hour fell while the work rose. `ci-queue.sh` is the MEASURED read (queue
# depth vs the runner count, ceiling derived from the measured job duration — its header carries the
# derivation); this block is the wiring, and the wiring is what makes it a gate instead of advice.
_ciq_mod=""
for _dir in "$O" "$(dirname "$0")"; do
  [ -f "$_ciq_mod" ] || [ ! -f "$_dir/ci-queue.sh" ] || _ciq_mod="$_dir/ci-queue.sh"
done
[ -n "$_ciq_mod" ] && . "$_ciq_mod"
if declare -f ciq_read ciq_eval ciq_defer_note_here ciq_ci_allowed ciq_verdict ciq_is_count ciq_ceiling ciq_defer_line ciq_horizon_min ciq_job_p90_min >/dev/null 2>&1; then CIQ=1; else
  CIQ=0
# ⛔ THE DISCLOSURE NAMES EVERY FUNCTION THE GUARD ABOVE REQUIRES (#2333 review cycle 12, P2).
  # Cycle 10 widened the guard to TEN names and left these messages naming six, so a `$O` copy
  # missing only `ciq_ceiling` — the exact stale-copy shape that guard exists for — announced
  # "needs ciq_read/…/ciq_is_count", i.e. named six functions that were all PRESENT and none of the
  # one that was MISSING: a false statement about the box's own state, in the one line an operator
  # reads to decide whether to re-seed. The names are LITERAL, not rendered from a variable defined
  # in the module — an old module would not define it, which is exactly the case being reported.
  # Keep this list IDENTICAL — same names, same ORDER — to the `declare -f` list above. (e13) in
  # ci-queue.test.sh now DERIVES both lists from this file and asserts equality (it used to
  # restate the names, so a widening stayed green); (e8) is the fix-one bail marker, not this.
  [ -n "$_ciq_mod" ] && printf '[ci-queue] ci-queue.sh is present but INCOMPLETE (needs ciq_read/ciq_eval/ciq_defer_note_here/ciq_ci_allowed/ciq_verdict/ciq_is_count/ciq_ceiling/ciq_defer_line/ciq_horizon_min/ciq_job_p90_min) — the CI-queue arm is INERT this cycle; every other gate still applies\n' >> "$LOG" 2>/dev/null || true
fi
# ⛔ A MISSING MODULE MUST NOT BECOME A PERMANENT STOP, so the predicate is defined HERE and its
# degrade is named on the [ci-queue] line every cycle (the same stance `capacity.sh`'s absence takes).
# The defect this replaces is the other polarity: `! ciq_ci_allowed` against an UNSOURCED function
# is `! 127` = TRUE, i.e. a box that shipped no module would defer every fixer forever while
# reporting a healthy controller.
if [ "${CIQ:-0}" = "1" ]; then
  # ⛔ ONE CONSUMER LEFT, AND THAT IS THE POINT (#2927). `ciq_push_ok` gates the CI-RERUN site only.
  # The three FIXER spawn arms no longer call it: they are REPAIR (an existing PR), and the class rule
  # in `ci-queue.sh`'s header says only work that ADDS a new CI run is queue-gated. ⛔ The old gloss here
  # — "whose CI pass is already spent" — was wrong (a repair push DOES start a fresh run); the basis is
  # #2927's decision plus the measurement that the number was demand read as supply. A rerun is exactly that — it queues a fresh run for the same head — so it keeps
  # the gate. Measured 2026-10-27: the fixer arms' call to this predicate was the last-line half of a
  # gate that skipped 41 consecutive repair dispatches with 8 idle runners and ~11 free lane slots.
  # The predicate itself is unchanged (capture + memo); if a future arm needs it, it must be a
  # CI-SPENDING one, and the wiring arms in ci-queue.test.sh count the call sites.
  #   * CAPTURES (#2296 cycle 4, P2): `ciq_ci_allowed` reads in the CALLER's shell, so after it runs
  #     the CIQ_* record IS this decision's reading. The deferral rows below print `${CIQ_VER:-…}`,
  #     and `CIQ_VER` is otherwise assigned only later, in the dispatch block — so they used to render
  #     `ci-queue(unmeasured)` on a cycle where the arm had MEASURED, a row that contradicts itself in
  #     its next clause and sends an operator to check whether the module is installed.
  #   * MEMOIZES (#2296 cycle 5, P2): the module's cache only covers a SUCCESSFUL read — on the
  #     failure path (the outage the gate exists for) every call re-reads live, three `gh api` calls
  #     each. Measured: 5 arms against a failing feed issued 15 calls, versus 3 against a working one.
  #     A sweep of 30 red PRs would then issue ~180 serialised failing calls per cycle, inflating the
  #     very cycle time the gate is meant to protect, while `gh-limit` is already the bottleneck.
  #     ⛔ AND IT BOUNDS A **PASS**, NOT THE CYCLE (#2333 cycle 6 review, P2). The PR sweep below is a
  #     PIPELINE (`printf | while read`), so every arm runs in a subshell and this memo dies with it;
  #     the dispatch block then reads once more. On the failure path a cycle therefore issues at most
  #     TWO live reads (one per pass), never one per arm — which is the property the memo actually
  #     buys, and the only one a reader can check. An earlier version of this comment claimed "one
  #     read per cycle": the dispatch block's own `ciq_read` is the second, so the claim was one the
  #     code never made true, and a cycle-time instrument calibrated on it would undercount. The
  #     `CIQ_ARM_*` pair is reset with the rest of the per-cycle state at the top of the loop, and
  #     the test EXTRACTS that reset (ci-queue.test.sh (h0b)/(h0c)) so a hoisted reset — a memo that
  #     pins cycle 1's verdict for the process's life — cannot pass.
  ciq_push_ok() {
    if [ -n "${CIQ_ARM_RC:-}" ]; then
      CIQ_VER="${CIQ_ARM_VER:-}"; CIQ_RC="$CIQ_ARM_RC"
      [ "$CIQ_ARM_RC" -eq 1 ] && return 0 || return 1
    fi
    # ⛔ THE COLD PATH MUST READ (#2296 cycle 6, P0). `ciq_eval` only EVALUATES the record in CIQ_*;
    # it does not read. This predicate is called from the PR SWEEP, which runs BEFORE the dispatch
    # block's one read, and the record is wiped at the top of every cycle — so evaluating here
    # answered `unknown` on an empty record and refused EVERY fixer and EVERY rerun on EVERY cycle,
    # forever, on a perfectly shallow queue. That is a permanent stop of the repair path, and the
    # memoization below cannot fix it: the memo only remembers what the first call found. The read
    # belongs here, in the cold path, exactly where `ciq_ci_allowed` (this function's original body)
    # did it.
    ciq_read "${OR:-}" >/dev/null 2>&1 || true
    CIQ_VER="$(ciq_eval)"; CIQ_RC=$?
    CIQ_ARM_RC="$CIQ_RC"; CIQ_ARM_VER="$CIQ_VER"
    [ "$CIQ_RC" -eq 1 ]
  }
else
  ciq_push_ok() { return 0; }
fi
# ── THE PR SICKNESS QUEUE (pr-sickness.sh): THE SELECTOR THAT RETURNS TO A RED PR ──────────
# ⛔ THE MISSING HALF OF AUTONOMY, AND WHY IT IS A SELECTOR RATHER THAN A THIRD REACTOR. The PR
# side had two ways to get a lane: the acting-case fixer arms (which fire only for a red check that
# is in THIS repo's REQUIRED set) and the red-fixer role (which fires only when the MERGE RAIL
# already refused). Nothing ever asked "which open PR is red RIGHT NOW?", so a PR that went red on a
# check the required-set did not name — or that no rail had reached — was never visited again.
# MEASURED 2026-10-22: seven lanes finished real work and landed nothing, and 25 tortoise PRs sat
# `blocked`, most red on ONE systemic assertion already fixed on main.
# ⛔ IT EXTENDS THE EXISTING CONTROLLER, IT DOES NOT BECOME A SECOND ONE. It is sourced exactly like
# every other module here (interface-gated, `$O` then the script directory), it spawns the SAME
# `fix-<PR>` worker names every census/reaper/cap already knows, it takes the SAME cross-box claim,
# and it writes its dispositions through the loop's OWN `dispreplace`. Its only budget of its own is
# a READ budget (`PS_MAX_PRS`) — deliberately not a lane cap: the owner ruled (2026-10-17) that
# dispatch is gated on measured capacity, not on lane count, and `fix_slots` below is the measured
# capacity it reuses.
_pss_mod=""
for _dir in "$O" "$(dirname "$0")"; do
  [ -n "$_pss_mod" ] || [ ! -f "$_dir/pr-sickness.sh" ] || _pss_mod="$_dir/pr-sickness.sh"
done
if [ -n "$_pss_mod" ]; then
  # shellcheck source=/dev/null
  . "$_pss_mod" 2>/dev/null
fi
if declare -f ps_select ps_decide ps_polarity ps_verdict ps_held >/dev/null 2>&1; then
  PRSICK=1
  # ⛔ NO QUEUE MODULE IS LOADED FOR THE PR-SICKNESS QUEUE (#2927): every dispatch it makes is
  # REPAIR, which is NOT queue-gated. ⛔ The gloss this line used to carry — "adds no new CI run" — is
  # wrong and is refuted above in `ciq_push_ok`'s note: a repair push DOES start a fresh run. The
  # exclusion rests on #2927's decision plus the measurement that the number was demand read as
  # supply, not on repair being free. Its bound is `--max-spawn` (the fix-lane headroom `fix_slots`
  # computes) exactly as before. The CI-queue read this loop still needs is the dispatch block's own,
  # below.
else
  PRSICK=0
  # ⛔ A MISSING SELECTOR IS NAMED, NOT ASSUMED. Without this line a box that was never re-seeded
  # looks exactly like a box whose every PR is healthy — the failure mode this whole role removes.
  [ -n "$_pss_mod" ] && printf '[prsick] pr-sickness.sh is present but INCOMPLETE (needs ps_select/ps_decide/ps_polarity/ps_verdict/ps_held) — no PR sickness queue this cycle; red PRs are only reached by the acting-case arms and the rail-refusal role
' >> "$LOG" 2>/dev/null || true
  [ -z "$_pss_mod" ] && printf '[prsick] pr-sickness.sh is MISSING (looked in \$O and the script directory) — no PR sickness queue this cycle; a red PR nobody required and no rail reached is not revisited
' >> "$LOG" 2>/dev/null || true
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
# already owns this head) — OR when the CI-queue gate DEFERS the push before any work (fix-one.sh's
# `ciq_ci_allowed` arm, #2296). Both are "no agent work was done", which is the only property this
# marker asserts; the LOG LINE below names both causes, because a deferral logged as a cross-box
# refusal sends an operator hunting for a lease that never existed (the #1720 "the log names the
# wrong cause" class). The controller books the attempt at SPAWN (fixcount+1) and, on the
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
    # ⛔ RESTORE ONLY WHAT THIS DISPATCH ACTUALLY TOOK (review round 4, P3). `restore=1` is passed by the
    # review-gate arm, but a bail can have been written by the CI-red or CONFLICTING arm — which never
    # delete a findings marker — and refunded on a later gate-red cycle. Touching unconditionally then
    # MANUFACTURED a findings record for a head no reviewer had reported findings at, and since
    # agent-infra#2132 that marker is the SOLE fixer authorisation (`review_gate_state()`), so it could
    # authorise a fixer with nothing to fix. `fixspend-<PR>-<head>` is written by the one site that
    # consumes a findings marker (the gate arm's spawn), so its presence is the proof of a real spend.
    if [ -f "$O/state/fixspend-$pr-$head" ]; then
      rm -f "$O/state/fixspend-$pr-$head"
      touch "$O/state/needsfix-$pr-$head"
      echo "#$pr fixer bailed (cross-box refusal or CI-queue deferral) — attempt refunded to $n, findings marker restored" >>"$LOG"
    else
      echo "#$pr fixer bailed (cross-box refusal or CI-queue deferral) — attempt refunded to $n, NO findings marker restored (this dispatch consumed none)" >>"$LOG"
    fi
  else
    echo "#$pr fixer bailed (cross-box refusal or CI-queue deferral) — attempt refunded to $n" >>"$LOG"
  fi
  # A bail is proof the cap was not really reached; drop any park so the next cycle retries.
  rm -f "$O/state/parked-$pr"
  return 0
}

# review_gate_state <pr> <head-sha> — WHY the repo's review gate is red, as the CONTROLLER must act:
#   NEEDS-FIX     a reviewer reported findings at this head  -> a FIXER is authorised
#   NEEDS-REVIEW  no findings exist at this head (evidence stale, or no verdict was produced)
#                 -> re-run the REVIEW; a fixer is NEVER authorised
# ⛔ ONE VOCABULARY WITH THE PRODUCER (agent-infra#2132). merge-one.sh's review_state_record() writes
# exactly these two markers and nothing else may authorise a fixer, so the log line and the dispatch
# decision cannot diverge. Before this the controller logged a bare `FAILED:ai-review-gate`, which is
# indistinguishable from a genuine rejection: a fixer dispatched on stale evidence pushes, the push
# invalidates the signed review by design, and one MAX_FIX_TRIES attempt is burnt per cycle until the
# PR is parked with no owner. Absent BOTH markers reads NEEDS-REVIEW — the fail-closed direction,
# because "nothing says findings exist" must never be spent as if it did.
review_gate_state() {
  if [ -f "$O/state/needsfix-$1-$2" ]; then printf 'NEEDS-FIX'; else printf 'NEEDS-REVIEW'; fi
}

# [reviewdisp:begin]
# ── THE REVIEW-DISPATCH KEY: ONE REVIEW PER (PR, HEAD), BOUNDED, NEVER SILENT (agent-infra#2653) ──
# `state/reviewdisp-<PR>` = "<head> <n>": review ATTEMPTS at that (PR, head), spent by BOTH arms since
# agent-infra#2971 — the CONTROLLER on a dispatch, `merge-one.sh` on a verdict-less run nothing counted
# above it (`REV_PAID=1` marks the dispatcher-paid run, so one attempt is never counted twice). The head
# is the key because a review is evidence ABOUT A HEAD — a push re-arms the budget, and an unchanged head
# must never pay for the same review twice.
# ⛔ WHY THIS EXISTS AT ALL. A review lane IS dispatchable — it was dispatched under `merge-<PR>` until
# agent-infra#2971 split the two identities: the review ORDER is `review-<PR>`, and `merge-<PR>` is now
# only the GREEN arm's landing worker. Before that split a review order and a landing worker carried the
# SAME tag, so a pass that did the right thing (review) read in the controller's own log as a re-run of
# the thing that had just been refused — but the controller kept
# no record of having dispatched one, so a head whose gate stayed red was re-reviewed once per cycle
# forever, and every one of those is a PAID fresh-context reviewer. The mirror image is what the fleet
# actually paid for: with `review_slots` bounded, a review that never binds to a (PR, head) cannot be
# TOLD APART from one already in flight — measured 2026-10-24, `review lanes=11/6` for 26h while the
# box's four stuck PRs had never been reviewed at all (no `state/reviewcount-*`, no record in the
# enforcer's store). Capacity and truth are different instruments; this is the truth one.
# THREE VERDICTS, EACH WITH ITS OWN NAMED LINE — no silent skip, and no fresh review bought twice:
#   ALLOW <n>      dispatch; <n> is what this head has already spent
#   AT-HEAD <n>    the enforcer's record store already holds a CLEAN record at EXACTLY this head. A
#                  second review of an unchanged head is pure waste, so it is REFUSED with that
#                  reason. (The gate re-triggers on `edited`, so the free remedy for a red gate over
#                  a valid record is a RE-RECORD — merge-one.sh's CLEAN path — never a new review.)
#   CAP <n> <max>  the head has spent MAX_REVIEW_TRIES re-records with no verdict: REPORTED as
#                  REVIEW-CAP and PARKED, because an unfixable head must not loop (the same bound, on
#                  the same counter, merge-one.sh applies — and the same reason it applies it).
#   REPORT-ONLY 0  `MAX_REVIEW_TRIES=0`: this box never dispatches a review re-record. Nothing is
#                  parked (a deliberate report-only box still owns its queue) and nothing is spent;
#                  the line says so, mirroring `MAX_RED_FIX_TRIES=0`.
# ⛔ THE STORE IS READ, NOT A SECOND DEFINITION OF "REVIEWED" (agent-infra#2517). `review_store_file`
# is the path `record-review.sh` writes (`FILE="$DIR/${REPO%/*}-${REPO#*/}-$PR.json"`); a reader that
# invents its own layout finds nothing and reports "never reviewed" for every PR. Two fields are read,
# the same two #2517's dispatch floor reads: the EXACT head, and a clean verdict.
# ⛔ EVERY CANDIDATE, NOT THE FIRST NAME (merge-one.sh::record_at_head's rule, and for its reason):
# the producer writes a REPO-QUALIFIED file and keeps the LEGACY `<pr>.json` for a record made
# without `--repo` (a hand record, a pre-#426 leftover). Reading only the qualified name reports
# "never reviewed" for a PR whose evidence is sitting in the legacy one — so the controller would buy
# reviews until the budget was spent and then PARK a head that already had valid evidence.
review_store_candidates() { # <pr> -> one record-store path per line (qualified first, then legacy)
  printf '%s/.pi/agent/reviews/%s-%s-%s.json\n' "$HOME" "${OR%%/*}" "${OR#*/}" "$1"
  printf '%s/.pi/agent/reviews/%s.json\n' "$HOME" "$1"
}
review_disp_read() { # <pr> -> "<head> <n>" (n coerced: it feeds -ge and $(( + 1 )))
  local f="$O/state/reviewdisp-$1" h="" n=0
  if [ -f "$f" ]; then read -r h n < "$f" 2>/dev/null || true; fi
  is_limit "${n:-}" || n=0
  printf '%s %s\n' "${h:-}" "$n"
}
review_disp_decide() { # <pr> <head> -> "ALLOW <n>" | "AT-HEAD <n>" | "CAP <n> <max>"
  local pr="$1" head="${2:-}" rec h="" n=0 sf
  # An unreadable head is not a key. The ARM refuses to spend a review on one (it names the HEAD
  # being unreadable instead); this stays as the helper's own contract for any other caller.
  [ -n "$head" ] || { printf 'ALLOW 0\n'; return 0; }
  # ⛔ REPORT-ONLY IS DECIDED BEFORE ANYTHING ELSE IS READ (review round 4 of #2653, P2). It sat AFTER
  # the store check, so on a report-only box (`MAX_REVIEW_TRIES=0`) a head that already carried a CLEAN
  # record took the AT-HEAD path, where `1 >= 0` is true — the arm PARKED it as `REVIEW-AT-HEAD-STUCK
  # 1/0` on the first refusal, removing the PR from the sweep with a reason naming a budget the box
  # never had, and contradicting the documented "REPORT-ONLY: nothing dispatched, NOTHING parked".
  # The sibling red-fixer role records the same rule: "REPORT-ONLY IS DECIDED BEFORE THE COUNTER IS EVEN
  # READ". This branch therefore precedes the read, not just the arithmetic.
  if [ "${MAX_REVIEW_TRIES:-3}" -eq 0 ]; then printf 'REPORT-ONLY 0\n'; return 0; fi
  rec="$(review_disp_read "$pr")"; n="${rec##* }"; h="${rec% *}"
  # A PUSH RE-ARMS. The count belongs to the head it was spent on, never to the PR.
  [ "${h:-}" = "$head" ] || n=0
  while IFS= read -r sf; do
    [ -f "$sf" ] || continue
    grep -qF "\"head_sha\":\"$head\"" "$sf" 2>/dev/null \
      && grep -qF '"verdict":"clean' "$sf" 2>/dev/null \
      && { printf 'AT-HEAD %s\n' "$n"; return 0; }
  done <<EOF
$(review_store_candidates "$pr")
EOF
  if [ "$n" -ge "${MAX_REVIEW_TRIES:-3}" ]; then
    printf 'CAP %s %s\n' "$n" "${MAX_REVIEW_TRIES:-3}"; return 0
  fi
  printf 'ALLOW %s\n' "$n"
}
# ⛔ THE WRITE MUST BE ABLE TO FAIL LOUDLY (review round 3 of #2653, P2). `… 2>/dev/null || true` made
# the bound itself best-effort: an unwritable `state/` (a stray directory of that name, a read-only
# file, a full disk — the hazard this file names at its own `state/` note) left `review_disp_read` at
# `0` for ever, so `review_disp_decide` returned ALLOW 0 every cycle and the arm bought a fresh PAID
# review again and again, with no REVIEW-CAP ever reached and no line saying the record failed. The
# SAME class the red-fixer counter already fixed ("the per-head cap CANNOT be kept — refusing"). The
# return status is the caller's signal; it is never swallowed.
review_disp_record() { # <pr> <head> <n> — written only AFTER a spawn succeeded (bookkeep on success)
  printf '%s %s\n' "$2" "$3" > "$O/state/reviewdisp-$1"
}
# review_athead_next <pr> <head> -> the number of AT-HEAD refusals now standing for this head.
# ⛔ AT-HEAD IS THE ONE STATE THAT NEITHER DISPATCHES NOR PARKS, SO IT MUST EVENTUALLY ESCALATE
# (review of #2653, P2). Its remedy is a RE-RECORD, which only `merge-one.sh`'s CLEAN path can mint —
# and the branch that withholds the review is exactly what prevents it from running. Left unbounded,
# it is the same "the queue never drains and nothing says why" shape this change exists to end, so
# after `MAX_REVIEW_TRIES` cycles at one head the PR PARKS with a reason naming the action.
review_athead_read() { # <pr> -> "<head> <n>"
  local f="$O/state/reviewathead-$1" h="" n=0
  if [ -f "$f" ]; then read -r h n < "$f" 2>/dev/null || true; fi
  is_limit "${n:-}" || n=0
  printf '%s %s\n' "${h:-}" "$n"
}
review_athead_bump() { # <pr> <head> -> prints the new count
  local rec n h
  rec="$(review_athead_read "$1")"; n="${rec##* }"; h="${rec% *}"
  [ "${h:-}" = "${2:-}" ] || n=0
  n=$(( n + 1 ))
  # Best-effort would make the escalation inert: a failed write never advances, so AT-HEAD would log
  # a wait row every cycle for ever — the state this counter exists to bound (review round 3, P2).
  printf '%s %s\n' "$2" "$n" > "$O/state/reviewathead-$1" || { printf '%s\n' "$n"; return 1; }
  printf '%s\n' "$n"
}
# review_lane_holders — the lanes the review ceiling is counting, WITH their log age.
# ⛔ A COUNT WITHOUT AN OWNER IS WHAT MADE THE STALL INVISIBLE (agent-infra#2653). The live line said
# `review lanes=11/6` for 26 hours; the 11 were dead records whose logs had been silent for 26-30h and
# nothing said so. A refusal that names its holders and their age turns "the box is busy" into "these
# eleven units are not alive", which is the only reading an operator can act on.
review_lane_holders() { # -> "review-<pr>(<age>) merge-<pr>(<age>) …" (max 6, then "+N more")
  local n st f m age out="" extra=0 lim=6 count=0
  while IFS="$(printf '\t')" read -r n st; do
    case "$n" in review-*|merge-*) ;; *) continue ;; esac
    case "$st" in dead) continue ;; esac
    count=$(( count + 1 ))
    if [ "$count" -gt "$lim" ]; then extra=$(( extra + 1 )); continue; fi
    age="?m"
    f="$O/logs/$n.log"
    if [ -f "$f" ] && m="$(file_mtime_epoch "$f" 2>/dev/null)" && is_num "${m:-}"; then
      age="$(( ( $(date +%s) - m ) / 60 ))m"
    fi
    out="$out${out:+, }$n($age)"
  done <<EOF
$(wt_table)
EOF
  [ "$extra" -gt 0 ] && out="$out${out:+, }+${extra} more"
  printf '%s' "${out:-none}"
}
# [reviewdisp:end]

# prune_orphan_markers <open-rows> <row-count> — delete `needsreview-*` / `needsfix-*` / `fixspend-*`
# markers for PRs that are NO LONGER OPEN (agent-infra#2132). The per-PR MERGED|CLOSED sweep fires only
# in the race where a PR terminates between the listing and its `gh pr view`; once a PR leaves the OPEN
# listing it is never visited again, so its markers would live forever — the monotonic `state/` growth
# this file rejects elsewhere. Delete-only, against the listing the cycle already read.
# ⛔ THE GUARD IS "THE LISTING SUCCEEDED AND IS NOT TRUNCATED" — NOT "the row count is nonzero"
# (review rounds 7-9). A row count of 0 WITH `last-open-prs` present is a genuinely EMPTY open set (the
# drained state the fleet aims for), where every marker is orphaned and must go; an ABSENT file is a
# FAILED read and deletes nothing; a row count at the 300 cap is a TRUNCATED read and deletes nothing.
# The header used to claim "a row count of 0 deletes nothing", which the code below contradicts — and a
# maintainer restoring that rule would re-open the drained-box leak.
prune_orphan_markers() {
  local rows="${1:-}" n="${2:-0}" mf mp
  # ⛔ A MALFORMED ROW COUNT FAILS CLOSED (review round 9): coercing it to 0 turned garbage into the
  # MOST destructive reading ("the open set is empty"). Refuse to prune instead.
  case "${n:-}" in ''|*[!0-9]*) return 0 ;; esac
  # `-e last-open-prs` is the success signal (a FAILED listing DELETES that file); the cap check is
  # the other half: both listings are capped at 300, so when the row count reaches the cap the rows may
  # omit open PRs and a marker could be deleted for a PR that IS open.
  [ -e "$O/state/last-open-prs" ] || return 0
  [ "$n" -lt 300 ] || return 0
  # ⛔ `needsfix-*`, `reviewcount-*` AND `-n` (review round 10 final pass). `needsfix` was the one
  # marker family that still leaked; `reviewcount-<PR>` was created by this branch and was in NO sweep
  # family at all. `reviewdisp-*` and `reviewathead-*` are the SAME class (head-bound review budgets
  # written by the controller's review arm, agent-infra#2653): a stale `"<head> 3"` surviving a
  # close-and-reopen would re-arm a spent budget on the same head, and one file per abandoned PR is
  # the monotonic growth this file rejects everywhere else. And `sed` WITHOUT `-n` prints every
  # non-matching line unchanged — so a name outside
  # the three families (say `needsfix-note.txt`) yielded itself as `mp` and was DELETED as an orphan,
  # the opposite of this function's fail-closed posture. `-En` makes a non-conforming name yield
  # nothing, which the `[ -n "$mp" ]` guard then spares.
  for mf in "$O"/state/needsreview-* "$O"/state/needsfix-* "$O"/state/fixspend-* "$O"/state/reviewcount-* "$O"/state/reviewdisp-* "$O"/state/reviewathead-*; do
    [ -e "$mf" ] || continue
    # ⛔ NEVER JUDGE A MARKER THE LISTING COULD NOT HAVE SEEN (review round 6, P3). `last-open-prs` is
    # written when the listing is read; this runs hundreds of lines later, so a marker written in
    # between belongs to a PR the rows cannot contain (a lane's brand-new PR, via chain-merge.sh →
    # merge-one.sh — this repo's main flow) and is TRUE. `-ot` is the cycle boundary.
    [ "$mf" -ot "$O/state/last-open-prs" ] || continue
    # ⛔ sed -E, NOT BRE `\|` (review round 6, P3). BRE has no alternation; BSD sed (macOS — the
    # platform install.sh/launchd target) does not implement `\|`, so `mp` would always be empty and
    # this prune would be an INERT ENFORCER on macOS with no diagnostic, while the Linux suite stayed
    # green. `-E` is portable to both.
    mp="$(basename "$mf" | sed -En 's/^(needsreview|needsfix|fixspend)-([0-9][0-9]*)-.*/\2/p; s/^(reviewcount|reviewdisp|reviewathead)-([0-9][0-9]*)$/\2/p' | head -1)"
    [ -n "$mp" ] || continue
    printf '%s\n' "$rows" | tr ' ' '\n' | grep -q "^$mp:" && continue
    rm -f "$mf"
  done
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
  local rr out rc rel run ref pin act rec line pnd
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
    line="[harness] CANNOT-VERIFY: no harness-refresh.sh in $O or beside the loop — whether this box is behind ${HARNESS_REF:-origin/main} is UNKNOWN, and unknown is not current (re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O)"
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
  rel=""; run=""; ref=""; pin=""; act=""; fst=""; pnd=""
  for kv in $rec; do
    case "$kv" in
      relation=*) rel="${kv#relation=}" ;; running=*) run="${kv#running=}" ;;
      ref=*) ref="${kv#ref=}" ;; pin=*) pin="${kv#pin=}" ;; action=*) act="${kv#action=}" ;;
      fetch=*) fst="${kv#fetch=}" ;;
      # WHY a `restart-pending` is pending (#2641): `inert` / `unprovable` / `deferred` / `safe`. Parsed
      # so the spawn line can carry it — the four are different facts about the box and a token that says
      # only `restart-pending` is the always-on alarm this fixes.
      pending=*) pnd="${kv#pending=}" ;;
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
  # ⛔ THE PENDING REASON RIDES ON THE TOKEN ONLY FOR `restart-pending` (#2641): every other relation
  # carries `pending=none`, and appending it would put a constant on every line — the shape this repo
  # keeps deleting. `restart-pending:deferred:04bc1ddefde` says the box is on an older tree AND why the
  # step that would fix it has not been taken; `restart-pending:unprovable:…` says the identity itself is
  # unknown. `current` stays EMPTY, which is the whole point of the third RUNNING source: on a cell it
  # becomes reachable, so the token finally disappears when the box really is on the pin.
  _pnd=""
  [ "$rel" = restart-pending ] && [ -n "$pnd" ] && [ "$pnd" != none ] && _pnd="$pnd"
  if [ "$rel" = current ]; then HARNESS_TOKEN=""; else HARNESS_TOKEN="$rel${_pnd:+:$_pnd}${run:+:$run}"; fi
  export HARNESS_TOKEN
  # The record other surfaces read (status, the next cycle's diagnosis). Staged then renamed, like
  # every other record this loop writes: a truncated state file must never replace a good one.
  { printf 'relation=%s running=%s ref=%s pin=%s action=%s fetch=%s rc=%s at=%s pending=%s\n' \
      "$rel" "${run:-unknown}" "${ref:-unknown}" "${pin:-none}" "${act:-none}" "${fst:-ok}" "$rc" "$(date +%s)" "${pnd:-none}" \
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
# [refresh-record:begin]
# ── THE REFRESH THAT WRITES THE RECORD MUST BE THE REFRESH THAT RUNS (agent-infra#2308) ─────────
# ⛔ MEASURED 2026-10-22 ON A LIVE LINUX CELL. The beat printed `BLOCKED: a refresh pass wrote its
# start marker 16h ago … so the pass DIED` on EVERY cycle for 16 hours, while `candidates.txt` held
# 17 real issues and the refresh was in fact running (its funnel record was 22 minutes old). The pass
# had not died: this loop executes `$O/refresh-candidates.sh` — the SEEDED copy — and that copy was
# one generation behind the build the controller itself ran, so it could not write
# `state/refresh-last` at all (`refresh_record_write` appears 0 times in it). The record therefore
# could never advance, and its frozen age — the only evidence this reader has — was printed as a
# death. "Nothing on this box can write the file" and "the writer died" are DIFFERENT states and
# must never print as one sentence: the first is a deployment defect with a one-line remedy, the
# second is a crash. The two helpers this loop already capability-probes — worker-terminal.sh
# (`command -v` for `wt_spawn`) and rail-refusal.sh (`declare -f`) — refuse a stale copy; the refresh
# is the one helper whose OUTPUT RECORD this loop parses, and it was the one helper with no probe at
# all. (harness-refresh.sh is existence-tested, not probed: its contract is a record line, not a
# named function — so it is deliberately not in that list.)#
# NOT A SECOND READER, AND NOT A CONVENIENCE FALLBACK: `$O` stays FIRST (an operator's seeded copy
# wins, #2278). A copy is only passed over when it cannot satisfy the contract this loop depends on,
# and when NO copy can, the gate says SEED-SKEW and names every path it tried — it never claims a
# cause it cannot know (#2229's own rule, applied to #2229's own record).
refresh_can_record() {   # <refresh-script> — 0 when it can WRITE the pass record this loop READS
  [ -f "$1" ] || return 1
  # ⛔ THE DEFINITION, NOT A MENTION: this very file's prose contains the word, and a completed
  # pass's output can quote it — so a substring match would report the capability for a script that
  # has none (a false PASS on the probe itself). Same shape as spawn-gate.sh's `run_agent` probe and
  # worker-terminal.sh's `wt_spawn` probe: the controller asks for the function it calls.
  # ⛔ AND THE BODY OPENER, NOT JUST THE SIGNATURE (review P3): excluding `#`-comments answers prose
  # that is COMMENTED, but any non-comment line that merely STARTS with the name satisfies a
  # signature-only match — a heredoc body does exactly that
  # (`why="$(cat <<EOF` / `refresh_record_write() writes the record…` / `EOF` / `)"`), so a box whose
  # seed only QUOTES the name in captured text would be read as a recorder and the SEED-SKEW verdict
  # never fires. Requiring the `{` keeps the match on a definition; the shipped definition puts the
  # brace on the signature line (`refresh_record_write() {      # …`), so this refuses no real copy.
  grep -qE '^[[:space:]]*refresh_record_write[[:space:]]*\(\)[[:space:]]*\{' "$1" 2>/dev/null
}
REFRESH_RESOLVED=0        # 1 once resolution has run THIS cycle (reset per cycle, like _HR_DONE — a
                          # cached answer would keep reporting the skew the remedy just fixed, and a
                          # cached "absent" would keep a re-seeded box from ever spawning again)
REFRESH_RC=0              # the resolution's own answer (0 recorder · 2 found-but-incapable · 1 absent)
REFRESH_SH=""            # the script this loop executes (empty only when NO refresh exists at all)
REFRESH_SH_SKEW=""       # the first copy passed over because it cannot record
REFRESH_TRIED=""         # every path tried, in order — the SEED-SKEW verdict names them
# 0 = a RECORDER was found (possibly beside the loop) · 2 = a script was found but NONE can record
# (the box still runs one — origination keeps queueing, the BEAT just refuses to read its silence as
# a cause) · 1 = no refresh script anywhere. The three answers are kept apart because their remedies
# differ and two of them used to print as the third's symptom.
resolve_refresh_sh() {
  [ "${REFRESH_RESOLVED:-0}" = "1" ] && return "${REFRESH_RC:-1}"
  local _self c _found=""
  _self="${REFRESH_SELF_DIR:-}"
  if [ -z "$_self" ]; then
    # The directory of the RUNNING script (the pinned build on a cell). Never `$PWD`, which is
    # whatever the operator's shell happened to be in.
    _self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || _self=""
  fi
  for c in "$O/refresh-candidates.sh" ${_self:+"$_self/refresh-candidates.sh"}; do
    [ -n "$c" ] || continue
    case " $REFRESH_TRIED " in *" $c "*) continue ;; esac
    REFRESH_TRIED="$REFRESH_TRIED${REFRESH_TRIED:+ }$c"
    [ -f "$c" ] || continue
    if refresh_can_record "$c"; then REFRESH_SH="$c"; REFRESH_RESOLVED=1; REFRESH_RC=0; return 0; fi
    [ -n "$REFRESH_SH_SKEW" ] || REFRESH_SH_SKEW="$c"
    [ -n "$_found" ] || _found="$c"
  done
  REFRESH_RESOLVED=1
  # An INCAPABLE script still runs: refusing to spawn would take a box that can still fill its pool
  # down to merging only, which is a worse outcome than a queue it cannot account for. What must not
  # happen is the reader TURNING ITS SILENCE INTO A CAUSE — that is the flag this sets.
  if [ -n "$_found" ]; then REFRESH_SH="$_found"; REFRESH_RC=2; return 2; fi
  REFRESH_RC=1
  return 1
}
# 0 when the record on disk cannot be ADVANCED by anything this box would execute AND its age would
# otherwise be read as a cause. A YOUNG, AGEABLE record is left alone — it is a pass in flight, and
# calling that SEED-SKEW would be inventing a second wrong cause; that includes a YOUNG `result=ok`,
# which is real evidence and must keep taking the `skipped`/`nothing to defer` branches.
# ⛔ BOTH UNWRITABLE STATES COUNT (review P1): `2` (a script exists that cannot record) AND `1` (no
# refresh script at all — the spawn site refuses to start a pass it cannot run, so nothing will EVER
# write the record). Scoping this to `2` left the measured sentence — "so the pass DIED … nothing will
# replace that marker but a pass that finishes" — printing on a box where the loop has made that event
# impossible; that is the same fabricated cause, for the sibling state.
# ⛔ AND A STALE `result=ok` IS NOT EXEMPT (review P1): the previous guard exempted `ok` at ANY age, so
# a box whose writer was seeded away printed `skipped (… refresh ok, 3h ago)` — a false green that
# claims origination works, the mirror of the defect this verdict exists for. Only FRESHNESS decides,
# and it is decided here, in one place.
refresh_contract_gap() {   # <result> <at> <d>
  local at="${2:-}" d="${3:-}"
  resolve_refresh_sh; case "$?" in 1|2) ;; *) return 1 ;; esac
  [ -z "$at" ] && return 0
  is_num "$at" || return 0            # present but unageable: no evidence of a pass being alive
  is_num "$d" && [ "$d" -lt "$RUNNING_STALE_MIN" ] && return 1   # young => in flight
  return 0
}
# [refresh-record:end]
# [refresh-check:begin]
case "${1:-}" in
  --check-refresh)
    resolve_refresh_sh; _rc=$?
    if [ "$_rc" = "0" ]; then
      if [ "$REFRESH_SH" = "$O/refresh-candidates.sh" ]; then
        printf 'refresh-contract relation=ok executed=%s tried=%s\n' "$REFRESH_SH" "$REFRESH_TRIED"
        exit 0
      fi
      printf 'refresh-contract relation=skew executed=%s passed_over=%s tried=%s\n' \
        "$REFRESH_SH" "${REFRESH_SH_SKEW:-none}" "$REFRESH_TRIED"
      # ⛔ "MISSING OR CANNOT RECORD", NOT "CANNOT RECORD" (review P2): the skew arm is reachable when
      # `$O` has NO copy at all (the resolver then finds the one beside the loop), and calling that a
      # copy that "cannot record" is a false statement about a file that is not there. `passed_over=none`
      # says which it is; the prose names both states.
      printf '  DIVERGENCE: the seeded copy is MISSING or cannot record a pass outcome, so this controller would run a different copy. Fix: re-seed $O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O) — a bare `cp *.sh` can deploy a partial harness with no verdict (agent-infra#2041)\n' >&2
      exit 1
    fi
    if [ "$_rc" = "2" ]; then
      printf 'refresh-contract relation=unwritable executed=%s tried=%s\n' "${REFRESH_SH:-none}" "${REFRESH_TRIED:-none}"
      printf '  BROKEN: no refresh-candidates.sh on this box defines refresh_record_write, so state/refresh-last cannot advance and its age proves nothing. Fix: re-seed $O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O) — a bare `cp *.sh` can deploy a partial harness with no verdict (agent-infra#2041)\n' >&2
      exit 2
    fi
    printf 'refresh-contract relation=absent tried=%s\n' "${REFRESH_TRIED:-none}"
    printf '  UNKNOWN: no refresh-candidates.sh was found at all, so origination cannot run. Fix: re-seed $O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O) — a bare `cp *.sh` can deploy a partial harness with no verdict (agent-infra#2041)\n' >&2
    exit 2 ;;
esac
# [refresh-check:end]

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

# ── THE FORK-FREE TIMER IS OPENED HERE, WHILE THE BOX CAN STILL FORK (agent-infra#2293) ─────────
# The starved path must wait without spawning, and `mkfifo`/`exec` themselves spawn/CREATE — so both
# happen once, at startup, and the descriptor is kept for the life of the controller. A box that is
# already starved at startup simply gets no timer (FORKFREE_FD_OPEN=0) and falls back to `sleep`, which
# is the pre-change behaviour, named in the log rather than silently assumed.
mkdir -p "$O/state" 2>/dev/null || true
FORKFREE_FIFO="$O/state/.forkfree.tick"
if [ -p "$FORKFREE_FIFO" ] || mkfifo -m 600 "$FORKFREE_FIFO" 2>/dev/null; then
  if exec 9<>"$FORKFREE_FIFO" 2>/dev/null; then FORKFREE_FD_OPEN=1; fi
fi
[ "$FORKFREE_FD_OPEN" = "1" ] || echo "[fork] no fork-free timer (no mkfifo, or \$O/state is not writable): a fork-starved cycle will fall back to 'sleep', which itself forks — the backoff is then the only protection" >> "$LOG" 2>/dev/null || true

# A worker whose log has not grown in this many minutes is hung. `pi -p` has no internal
# timeout and a runaway child it spawns (a reviewer's `find /` ran for 8 hours on 2026-10-12)
# keeps the pane alive, so the concurrency caps — which count SESSIONS — silently halve.
# ⛔ 40 -> 50 IN agent-infra#2888: at 40 min (2400 s) this reaper sat BELOW lane's own 45 min (2700 s)
# PROGRESS allowance, i.e. it pre-empted the bound the lane change exists to make primary — the same
# ordering defect, one layer up, killing a WORKING lane on log silence alone (this reaper reads no CPU
# and no lane-bound verdict). 50 min = 3000 s leaves the allowance plus its two confirming samples.
# The floor is enforced at runtime below, so a stale config cannot re-invert it either.
STALE_MIN="${STALE_MIN:-50}"
# §4 documents STALE_MIN and README tells a cell to set it through $ENV_FILE, so it is env-supplied
# like the rest -- but its only read is the arithmetic just below and it had NO coercion, so
# `STALE_MIN=abc` aborted the controller mid-cycle under `set -u` ("abc: unbound variable") instead
# of degrading. Guard-before-use, same rule as every other limit.
is_limit "${STALE_MIN:-}" || STALE_MIN=50
# ⛔ THE FLOOR IS DERIVED FROM THE ALLOWANCE, NEVER RESTATED, AND A VIOLATION IS RAISED *AND* LOGGED
# (agent-infra#2888 review, P1). `LANE_BOUND_IDLE_S` is the same seam `lane-bound.sh` resolves, so a
# re-measured allowance moves this floor with it; the fallback reads the shipped default out of
# `lane-bound.sh` instead of keeping a second copy of 2700 here. '+5 min' covers the two confirming
# samples the progress rule needs before it can reach its verdict. If lane-bound.sh cannot be read the
# floor is SKIPPED (an unreadable sibling is not evidence that the config is inverted), so this can
# never false-block a controller.
_stale_floor_raise() {
  local _allow="" _floor=""
  case "${LANE_BOUND_IDLE_S:-}" in
    ''|*[!0-9]*) : ;;
    *) _allow="$LANE_BOUND_IDLE_S" ;;
  esac
  if [ -z "$_allow" ]; then
    _allow="$(sed -n 's/.*num_or "${LANE_BOUND_IDLE_S:-}" \([0-9][0-9]*\)).*/\1/p' "${_HERE_RS:-.}/lane-bound.sh" 2>/dev/null | head -1)"
  fi
  case "${_allow:-}" in ''|*[!0-9]*) return 0 ;; esac
  _floor=$(( (_allow + 300 + 59) / 60 ))
  [ "$(10#${STALE_MIN:-0})" -ge "$_floor" ] && return 0
  echo "[reap-worker] STALE_MIN=${STALE_MIN}min is NOT above the lane PROGRESS allowance ($((_allow))s + 2 samples) — raising it to ${_floor}min, because a working lane that is quiet in its log would otherwise be closed by THIS reaper with no lane-bound verdict, no walltime row and no cap snapshot (agent-infra#2888). Set STALE_MIN>=${_floor} to silence this." >> "$LOG" 2>/dev/null || true
  STALE_MIN="$_floor"
}
_stale_floor_raise

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
# false-green class this loop refuses everywhere else).
#
# ⛔ AN UNREADABLE CENSUS IS CANNOT-VERIFY, AND CANNOT-VERIFY DOES NOT ADD WORK (#2163 review, P2).
# The earlier wording here had the polarity BACKWARDS: an UNDER-count of live lanes makes
# `[ "$LANES" -ge "$MAX_LANES" ]` FALSE and **dispatches more** — the exact direction that fills the
# box — so falling back to the tmux count silently is a fail-OPEN on the capacity gate. So:
#   * the script is MISSING (a `$O` that predates it) → the LAUNCH SURFACE's own worker census,
#     `wt_count lane-` (worker-terminal.sh), named once in the log: a transition, not a measurement;
#   * the script EXISTS and the census is `?`/unreadable → `LANES_UNKNOWN=1`, and the gate refuses to
#     add work with that reason, on the same doctrine as an unreadable memory probe (memory gate:
#     "a failed probe is UNKNOWN, not ample"). `[cap]` prints `?` (never a fabricated `0`) and the
#     internal `LANES` keeps a lower bound ONLY so the numeric consumers stay numeric; the
#     dispatch lines print `LANES_DISPLAY` too, so no line in the cycle reintroduces a `0` for a
#     read that did not happen.
# ⛔ THE FALLBACK IS THE LAUNCH SURFACE'S OWN WORKER COUNT, NOT `tmux ls` (#2163 review r8, P1; reason
# corrected in cycle 2). It used to be `tmux ls | grep -c '^lane-'` with `LANES_UNKNOWN=0`, which is NOT
# the population it replaced: `tmux ls` sees ONE of the TWO launch surfaces. Where the cmux daemon
# answers, `wt_launcher` selects `terminal` and every harness lane is a durable cmux terminal
# (worker-terminal.sh), so the expression reads **0 on a busy box**; `LANES_UNKNOWN` stays 0, the
# `lanes_unknown` arm never fires and
# `[ "$LANES" -ge "$MAX_LANES" ]` is false — the controller then dispatches onto a box that is
# already full, the exact #2159 OOM direction `lane-reap.sh` exists to close. (tmux IS the launcher
# where the cmux daemon does not answer — on a launchd Mac AND on a cell, #2210 — so the defect is
# the single surface, not tmux itself.) `wt_count` answers for
# EVERY launcher (cmux durable terminals, launchd tmux sessions and the records of both) and treats a
# worker it cannot measure as LIVE, so it cannot under-count either.
LANES_UNKNOWN=0
# Where the `lanes=` number CAME FROM, printed on the `[cap]` line. Without it, a launcher's session
# count and a process census are the same three letters, and a `$O` that predates `lane-reap.sh`
# silently changes the population of the number the capacity gate acts on (#2163 review, P2).
# `terminals` = `wt_count lane-`, the LAUNCH SURFACE's own worker census (launcher-agnostic: durable
# cmux terminals AND tmux sessions), which is the population the pre-census loop gated on.
LANES_SOURCE="unset"
LANE_REAP_SH=""
for _c in "${O:-}/lane-reap.sh" "${_HERE_RS:-}/lane-reap.sh"; do
  [ -n "$_c" ] && [ -f "$_c" ] && { LANE_REAP_SH="$_c"; break; }
done
measure_lanes() {
  local out live total z hint
  LANES=""; LANES_TOTAL="?"; ZOMBIES="?"; LANES_UNKNOWN=0; LANES_DISPLAY="?"
  if [ -n "$LANE_REAP_SH" ]; then
    LANES_SOURCE="unknown"
    out="$(bash "$LANE_REAP_SH" count 2>/dev/null)"
    # lanes=<live>/<total> zombie=<n>   (one line, no other output; live may be `?`)
    live="${out#lanes=}"; live="${live%%/*}"
    total="${out#*/}"; total="${total%% *}"
    z="${out##*zombie=}"
    if is_num "${total:-}" && is_num "${z:-}"; then
      LANES_TOTAL="$total"; ZOMBIES="$z"
    fi
    if is_num "${live:-}"; then
      LANES="$live"; LANES_DISPLAY="$live"; LANES_SOURCE="census"
    else
      # ⛔ READABLE TOTALS WITH AN UNREADABLE NUMERATOR IS STILL AN ABSTENTION (#2163 review, P2).
      # This cycle does not know how many lanes are working, so it does not add work — and it must
      # not PRINT a fabricated 0 either: the internal `LANES` keeps the LAUNCH SURFACE's own worker
      # census as a lower bound because every other consumer (`mp_reason`, the log lines) takes a
      # NUMBER, while `[cap]` prints `?` through LANES_DISPLAY. The earlier shape fell through to the
      # fallback here and printed `lanes=0/11 … lanes_src=unknown`, which reads as "no live lanes",
      # the opposite of the truth — which is also why the bound is `wt_count`, never `tmux ls` (see
      # the fallback arm below).
      LANES_UNKNOWN=1
      LANES="$(wt_count lane-)"
      is_num "${LANES:-}" || LANES=0
    fi
  else
    # The transition case (a `$O` seeded before lane-reap.sh existed). NAMED ONCE, so a cell that
    # silently lost the census is findable instead of reading like a census forever.
    LANES_SOURCE="terminals"
    if [ -n "${O:-}" ] && [ ! -f "$O/state/lane-census-fallback.flag" ]; then
      mkdir -p "$O/state" 2>/dev/null || true
      if [ -n "${LOG:-}" ]; then
        printf '%s [cap] WARN lane-reap.sh NOT FOUND (looked in %s and %s) — lanes= is the LAUNCHER WORKER COUNT (worker-terminal.sh wt_count lane-), not the evidence census, until the cell is re-seeded; re-run start/apply\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${O:-?}" "${_HERE_RS:-?}" >> "$LOG" 2>/dev/null || true
      fi
      : > "$O/state/lane-census-fallback.flag" 2>/dev/null || true
    fi
    LANES="$(wt_count lane-)"
    is_num "${LANES:-}" || LANES=0
    LANES_DISPLAY="$LANES"
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
# ── the product floor's three helpers (agent-infra#2054) ─────────────────────────────────────
# `floor_norm` and `floor_order` are PURE; `floor_choose_order` WRITES `$O/.order` (and removes it when
# the floor is off). The difference is the point: the WRITE is the one part that can go silently inert,
# so it is a named function rather than two inline lines.
# ⛔ EXTRACTABLE ON PURPOSE: product-floor.test.sh `sed`s these three function bodies out of the
# SHIPPED file and drives them, so the daemon's behaviour and the assertions cannot drift. Keep each
# definition a top-level `name() {` block closing on its own `}` line — the extractor matches those.
# floor_norm <raw-floor> <batch> -> the floor to use. Missing/non-numeric falls back to the DEFAULT (1),
# never to 0 (which would silently disable the guarantee) and never to an abort (a bad tunable must not
# stop dispatch). An explicit 0 IS honoured — "turn the floor off" is a legitimate operator setting.
# Clamped to [0, batch]: a floor larger than the batch would make the batch un-meetable on every pass.
floor_norm() {
  local raw="${1:-}" batch="${2:-1}" f
  # ⛔ NO CALL TO `is_limit` HERE. It is a helper of this file, and the test extracts these functions
  # STANDALONE — an unresolvable call would return 127, the clamp would collapse the batch to 1, and a
  # correct floor would read as broken (measured: that is exactly how this line first failed).
  case "${batch:-}" in ''|*[!0-9]*|0*) batch=1 ;; *) batch=$(( 10#$batch )) ;; esac
  f=1
  case "$raw" in
    ''|*[!0-9]*) f=1 ;;
    *) f=$(( 10#$raw )) ;;
  esac
  [ "$f" -ge 0 ] || f=1
  [ "$f" -le "$batch" ] || f="$batch"
  printf '%s' "$f"
}

# floor_order <floor> <product-file> <all-file> -> the ISSUE ORDER to dispatch, one number per line.
# The first <floor> entries are product candidates (in the product file's own order), then EVERY entry of
# the merged backlog in its existing order, de-duplicated. Two properties are load-bearing:
#   • `candidates.txt` stays the AUTHORITY: a product entry that is not in the backlog is never emitted,
#     so a stale `candidates.product.txt` (an issue dispatched, closed or re-pre-flighted away) cannot
#     resurrect work. The floor reorders a set; it does not define one.
#   • a MISSING or unreadable product file is not an error: it degrades to today's order (this is the
#     documented unmet-floor case, and the caller says so in the log).
floor_order() {
  local floor="${1:-0}" pfile="${2:-}" afile="${3:-}" took=0 n w
  [ -s "$afile" ] || return 0
  w="$(mktemp "${TMPDIR:-/tmp}/floor-order.XXXXXX")" || { cat "$afile"; return 0; }
  if [ -s "$pfile" ] && [ "$floor" -gt 0 ] 2>/dev/null; then
    while read -r n; do
      [ -n "$n" ] || continue
      [ "$took" -lt "$floor" ] || break
      grep -qx -- "$n" "$afile" 2>/dev/null || continue
      # ⛔ NO DUPLICATE IN THE HEAD EITHER (cycle-1 review, P2): the docstring promises de-duplication
      # and the first version only got it by accident — `took < floor` stopped a repeated entry only
      # when the floor was 1, so `floor_order 2` over product `[34 34]` emitted `34 34 12 56`. Two
      # slots spent on one issue make the batch shorter than BATCH, and only the loop's
      # `dispatched.txt` arm stood between that and a duplicate dispatch.
      grep -qx -- "$n" "$w" 2>/dev/null && continue
      printf '%s\n' "$n"
      printf '%s\n' "$n" >> "$w"
      took=$((took+1))
    done < "$pfile"
  fi
  # The tail is the merged backlog MINUS what the head already took: the floor REORDERS the batch, it
  # never duplicates an entry (a duplicate would fill two slots with one issue, making the batch
  # shorter than `BATCH` and — worse — dispatching the same issue twice).
  if [ -s "$w" ]; then
    awk 'NR==FNR{skip[$0]=1; next} !($0 in skip)' "$w" "$afile"
  else
    cat "$afile"
  fi
  rm -f "$w"
}

# floor_choose_order <O> <floor> -> the ABSOLUTE PATH of the file the dispatch loop must read.
# ⛔ THIS IS A FUNCTION RATHER THAN FOUR INLINE LINES FOR ONE REASON: the wiring is the part that can go
# silently inert. `done < "$ORDER_FILE"` is the only line that makes the floor real, and when this block
# lived inline a mutation reverting that one line to `done < "$O/candidates.txt"` left every assertion
# in product-floor.test.sh GREEN (measured, cycle-1 review) — a guard ladder that a single edit can
# unhook while the suite still reports success. Here the CHOICE is drivable, and the loop's redirect is
# pinned by name in P8.
floor_choose_order() {
  local o="${1:-}" floor="${2:-0}"
  [ -n "$o" ] || return 1
  if [ "${floor:-0}" -gt 0 ] 2>/dev/null && [ -s "$o/candidates.product.txt" ] \
     && floor_order "$floor" "$o/candidates.product.txt" "$o/candidates.txt" > "$o/.order" 2>/dev/null \
     && [ -s "$o/.order" ]; then
    printf '%s' "$o/.order"
    return 0
  fi
  # The floor could not produce an order (disabled, no product queue, or an unreadable one): the merged
  # backlog is read EXACTLY as before. Removing the file first matters — a stale `.order` from an
  # earlier pass would otherwise sit in $O looking authoritative to the next reader.
  rm -f "$o/.order" 2>/dev/null
  printf '%s' "$o/candidates.txt"
}

# floor_emergency <O> <batch> -> a non-empty REASON when an emergency OUTRANKS the floor; empty otherwise.
# ⛔ WHY THIS EXISTS, IN ONE SENTENCE: the floor reorders a SEVERITY-ordered FIFO, so it can push out the
# row at position `BATCH` of a window that held two P0s — and a floor that makes a P0 (or a red-main
# repair) wait is a worse defect than the starvation it was added to prevent.
# ⛔ WHAT COUNTS AS EVIDENCE, AND WHY NO ISSUE NUMBER IS NAMED HERE:
#   • `p0(#N)` — N is the FIRST entry of `candidates.emergency.txt` (which the refresh derives from the
#      item's own `P0-blocker` LABEL, intersected with `candidates.txt`) that also falls inside the FIRST
#      `<batch>` rows of the backlog. Those are the rows this batch would dispatch in plain severity
#      order, so they are exactly the rows the floor could displace. A P0 further down the backlog is not
#      displaced by anything the floor does this cycle, and an emergency on every box would make the floor
#      a dead letter.
#   • `p0-unknown(…)` — the class could NOT be read (listing failed / truncated / unaffordable / the record
#      is absent or PENDING). See `write_emergency_queue`'s polarity note: an unread class must never be
#      read as "no emergency", because the direction of that error is a P0 delayed behind a share target.
#   • `red-tree(#PR)` — a rail refusal on disk whose recorded class is `red-tree`, for a PR that is NOT
#      parked (`state/parked-<PR>` means the repair budget is spent and a human owns it). The record is
#      HEAD-BOUND and the sweep clears it on merge/close, on a new head, and when the tree goes green — so
#      a record that survives the sweep describes a tree that is red NOW. This is state already on disk:
#      the emergency check spends no API call for it.
# ⛔ A FLOOR WITH NOTHING TO APPLY IS NOT "OVERRIDDEN". It only ever reorders when it holds a product row
# the backlog still holds, so with no such row this returns empty — otherwise a box with no product queue
# would report an override every cycle against a floor that had nothing to apply, in the same cycle it
# reports the floor is N/A.
floor_emergency() {
  local o="${1:-}" batch="${2:-1}" f pr cls n any=0
  [ -n "$o" ] || return 0
  # (0) The floor must actually be able to reorder: a product row that is still in the backlog.
  [ -s "$o/candidates.product.txt" ] && [ -s "$o/candidates.txt" ] || return 0
  while read -r n; do
    [ -n "$n" ] || continue
    if grep -qx -- "$n" "$o/candidates.txt" 2>/dev/null; then any=1; break; fi
  done < "$o/candidates.product.txt"
  [ "$any" = "1" ] || return 0
  # (1) A RED TREE, from the rail-refusal records already on disk. Parsed with `awk` on the `class=` field
  # rather than through `rail_refusal_field`: this function is extracted STANDALONE by the suite, where
  # that module is unbound (measured class of defect — an unresolvable helper returning 127 read as "no
  # emergency", which is the fail-open direction).
  for f in "$o"/state/railrefusal-*; do
    [ -f "$f" ] || continue
    cls="$(awk 'index($0, "class=") == 1 { print substr($0, 7); exit }' "$f" 2>/dev/null)"
    [ "${cls:-}" = "red-tree" ] || continue
    pr="${f##*/railrefusal-}"
    # A PARKED red PR is a human's handoff, not an active repair: yielding the floor to it forever would
    # switch the guarantee off for as long as nobody picked it up — the opposite of what the floor is for.
    [ -f "$o/state/parked-$pr" ] && continue
    printf 'red-tree(#%s)' "$pr"
    return 0
  done
  # (2) The P0 class, as the refresh recorded it.
  # ⛔ AN `OK` PREFIX IS NOT A CLAIM ABOUT *THESE* FILES (P2, fresh-context review). The record can survive
  # a pass whose listing failed — the degrade arm writes `UNKNOWN-…`, but if THAT write fails (a read-only
  # `state/`) the PREVIOUS pass's `OK p0=0` keeps standing. Reading it as "no emergency" is the fail-open
  # direction this class exists to remove, so the record is CROSS-CHECKED against the queue it describes:
  # the file must EXIST (the writer creates it, possibly empty, on a completed read and REMOVES it on every
  # arm that could not classify) and its line count must equal the recorded `p0=`. Anything else is
  # UNKNOWN — which stands the floor down.
  local ec ec_p ec_n
  ec="$(head -1 "$o/state/emergency-class" 2>/dev/null || true)"
  case "${ec:-}" in
    NOT-A-PRODUCT-REPO*) return 0 ;;
    OK*)
      ec_p="${ec#*p0=}"; ec_p="${ec_p%%[!0-9]*}"
      ec_n=""
      # guarded on existence: an input-redirect failure is NOT silenced by `2>/dev/null` on the command.
      [ -f "$o/candidates.emergency.txt" ] && ec_n="$(wc -l < "$o/candidates.emergency.txt" 2>/dev/null | tr -d ' ' || :)"
      if [ -z "$ec_p" ] || [ "${ec_n:-absent}" != "$ec_p" ]; then
        printf 'p0-unknown(%s — the emergency class does NOT describe this queue: record says p0=%s, the queue holds %s)' \
          "$ec" "${ec_p:-?}" "${ec_n:-no file (removed by a pass that could not classify, or never written)}"
        return 0
      fi ;;
    *)
      # Absent, PENDING, or any UNKNOWN- arm: the class is not a measurement of this backlog.
      printf 'p0-unknown(%s)' "${ec:-UNRECORDED: no pass has recorded an emergency class}"
      return 0 ;;
  esac
  [ -s "$o/candidates.emergency.txt" ] || return 0
  n=0
  while read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    [ "$n" -le "$batch" ] || break
    if grep -qx -- "$f" "$o/candidates.emergency.txt" 2>/dev/null; then
      printf 'p0(#%s)' "$f"
      return 0
    fi
  done < "$o/candidates.txt"
  return 0
}

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
# ── THE GATE LINE MUST NOT MASK A BROKEN ORIGINATION (agent-infra#2229) ──────────────────────
# [origination:begin]
# `[dispatch] skipped (merge-priority …)` was printed on EVERY gated cycle, including the ones whose
# refresh had just aborted `judged 12 / usable 0`. Two states with OPPOSITE meanings — "the PR queue
# outranks issue work" and "issue work can never start" — rendered as the same line, so a cell that
# could originate nothing read exactly like a well-run cell that had chosen the PR queue. Measured
# 2026-10-21 on all four cells: nothing queued, 3 P0 + 16 P1 items carrying no PR, and every beat
# line saying merge-priority.
#
# The rule enforced here, in one sentence: **`[dispatch] skipped (` is printed only when the last
# refresh pass says it SUCCEEDED and a usable candidate is queued.** Everything else that is not a
# failure says `deferred (` (a usable candidate exists but no healthy pass is on record yet) and a
# failure says `BLOCKED` with its own stage, exit code and cause. So a monitor — or a human — can
# key on the PREFIX alone: `skipped` = origination worked and the gate is holding real work,
# `deferred` = work is queued but origination is unproven, `BLOCKED` = origination is broken.
#
# ⛔ WHY `deferred` EXISTS AT ALL (review P2, three reviewers). The first version printed `skipped`
# for the "queue seeded by an earlier pass, no outcome on record" case. That case is FINE, not
# blocked — but it is also indistinguishable from a pass that FAILED and could not write its record
# (an unwritable `state/`, a full disk, a SIGKILL), and the second reading is exactly the mask this
# PR exists to remove. The record's own writer announces that residual (`[refresh] WARN: cannot
# record this pass's outcome …`); a prefix that says `skipped` would contradict it. So the no-record
# case keeps its non-alarm truth (nothing is broken *proven*) in a DIFFERENT word.
#
# ⛔ THE RECORD IS READ ONCE, AS A SNAPSHOT (review P2, deep pass). One logical record assembled from
# six separate `sed` opens is assembled across six points in time while a BACKGROUNDED pass replaces
# the file with `mv` — so `result=` could come from a pass that a newer one has already superseded,
# paired with the newer `at=`. `queue_state_token()` beside it reads its record in one `read -r` for
# the same reason; this does now too, and the file's text is passed around instead of reopened.
refresh_record_snapshot() { cat "$O/state/refresh-last" 2>/dev/null || true; }
refresh_record_field() {   # <key> [<snapshot>] — one open, or none when the caller already has it
  local key="$1" rec="${2:-}"
  [ -n "$rec" ] || return 0
  printf '%s\n' "$rec" | sed -n "s/^$key=//p" | head -1
}
# One log-safe line: no newlines, bounded so a long cause cannot swallow the PR-path tail. It takes
# the already-read snapshot, so the cause can never be assembled from two different passes.
refresh_cause_brief() {   # <snapshot>
  local rec="${1:-}" stage why
  stage="$(refresh_record_field stage "$rec")"; why="$(refresh_record_field why "$rec")"
  printf 'stage=%s: %s' "${stage:-?}" "$(printf '%s' "${why:-no cause recorded}" | tr '\n' ' ' | cut -c1-400)"
}
# <count> <noun>-free phrasing helper: the record's own numbers, or `?` when it did not record one.
# ⛔ A `result=running` RECORD IS THE NORMAL STATE OF EVERY IN-FLIGHT PASS (review P1, two reviewers):
# the tombstone is written at entry and the outcome only at exit, so "a pass is running" and "a pass
# died" look identical in the record. The only thing that separates them is TIME, and this file
# already owns that bound — the stale-lock guard (20 min) — so a start marker younger than it is
# reported as in-flight and an older one as a death. Without the bound a healthy 4-minute pass reads
# BLOCKED for its whole duration on a box whose backlog is empty (i.e. the normal case, since the
# refresh runs only while the backlog is short), and an alarm that cries wolf is the failure this PR
# exists to remove.
REFRESH_STALE_LOCK_MIN="${REFRESH_STALE_LOCK_MIN:-20}"
case "$REFRESH_STALE_LOCK_MIN" in ''|*[!0-9]*) REFRESH_STALE_LOCK_MIN=20 ;; esac
RUNNING_STALE_MIN="${REFRESH_RUNNING_STALE_MIN:-$REFRESH_STALE_LOCK_MIN}"
case "$RUNNING_STALE_MIN" in ''|*[!0-9]*) RUNNING_STALE_MIN="$REFRESH_STALE_LOCK_MIN" ;; esac
dispatch_gate_line() {   # <gate_why> <lanes> <workers> <pr_tail>
  local why="${1:-}" lanes="${2:-0}" workers="${3:-0}" prtail="${4:-}"
  local rec result at qrec hrec now backlog head d="" age tailnote unrec="" unrec_at="" age_why=""
  rec="$(refresh_record_snapshot)"
  result="$(refresh_record_field result "$rec")"
  at="$(refresh_record_field at "$rec")"
  qrec="$(refresh_record_field queued "$rec")"
  hrec="$(refresh_record_field handed "$rec")"
  case "${qrec:-}" in ''|*[!0-9]*) qrec="" ;; esac
  case "${hrec:-}" in ''|*[!0-9]*) hrec="" ;; esac
  # ⛔ `2>/dev/null` DOES NOT SUPPRESS A FAILED REDIRECTION (review finding): the shell reports
  # `candidates.txt: No such file or directory` for `<` before the command's stderr is redirected, so a
  # box with no queue file would pollute the very line this function exists to keep clean. The file is
  # tested FIRST instead.
  backlog=0
  [ -r "$O/candidates.txt" ] && backlog="$( { wc -l < "$O/candidates.txt"; } 2>/dev/null | tr -d ' ')"
  case "$backlog" in ''|*[!0-9]*) backlog=0 ;; esac
  # ⛔ `-r`, NOT `-f` (review P2): a mode-000 or foreign-owned queue file passes `-f`, and `wc -l <`
  # then fails with a Permission-denied the `2>/dev/null` does NOT suppress (a failed redirection is
  # reported before the command's stderr is redirected) — so the beat would print "the queue is
  # EMPTY" about a file it never read. Reading is what this line needs, and the group-level redirect
  # covers both the redirection and the command.
  head=""
  [ -r "$O/candidates.txt" ] && head="$(head -1 "$O/candidates.txt" 2>/dev/null || true)"
  case "$head" in ''|*[!0-9]*) head="" ;; esac
  now="$(date +%s 2>/dev/null || echo 0)"; is_num "$now" || now=0
  # ⛔ AGE IS PART OF THE READING, and an UNREADABLE stamp is not "fresh". A record is a state, not a
  # measurement (`queue_state_token` reads its own record the same way): a failure from three hours ago
  # still means no successful pass has run since, and saying so is the point.
  age="age unknown"
  if is_num "${at:-}" && [ "$now" -gt 0 ] && [ "$at" -le "$now" ]; then
    d=$(( (now - at) / 60 ))
    if [ "$d" -lt 1 ]; then age="<1m ago"
    elif [ "$d" -lt 90 ]; then age="${d}m ago"
    else age="$(( d / 60 ))h ago"; fi
  fi
  tailnote=""
  [ "$backlog" -gt 0 ] && tailnote=" [$backlog usable candidate(s) still queued from an earlier pass — deferred work exists, but origination is what is broken]"
  # ⛔ THE UNRECORDED-FAILURE MARKER COMES BEFORE EVERYTHING (review P1, two reviewers). When a pass
  # FAILS and cannot write its record (`$O/state` unwritable while `$O` is writable), the record still
  # holds the PREVIOUS pass's `result=ok` — so a reader that trusts it prints `skipped (refresh ok)`
  # about origination that just failed. The pass therefore drops this marker into `$O` (the directory it
  # could write) whenever a record write fails and removes it on a successful one, so its PRESENCE is a
  # fact the record cannot express: "this pass finished and its outcome is not on disk". Its `rc=` says
  # which pass it was — 0 is a SUCCESS whose write failed, non-zero is a failure — so the line reports
  # the marker rather than asserting "FAILED" about a pass the marker says succeeded (review P1).
  # Reading it first is what makes the fallback a signal instead of a log line.
  if [ -e "$O/.refresh-unrecorded" ]; then
    # ⛔ `-e`, NOT `-s` (review P1): the marker's FIRST job is to exist, and the two states that empty
    # it are exactly the ones it is named for — a full disk creates the inode and THEN the write fails
    # (0 bytes), and a mode-000 / foreign-owned marker is unreadable. `-s` is false for the first and
    # `head` yields nothing for the second, so BOTH fell through to `skipped (` over a pass that
    # failed. The `-s` test was the mask coming back through its own fix.
    # ⛔ AND ALL FOUR KEYS, INCLUDING `why=` (review P1): `head -3` dropped the marker's CAUSE, so the
    # line named a stage and an rc but said nothing about what broke. The writer emits stage/rc/at/why.
    unrec="$(head -4 "$O/.refresh-unrecorded" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
    if [ -z "$unrec" ]; then
      unrec="stage=? rc=? why=? — the marker is PRESENT but unreadable or empty (a full disk can create it before the write fails)"
    fi
    # ⛔ A RECORD NEWER THAN THE MARKER SUPERSEDES IT (review P2): the marker is removed on a successful
    # write, but a failed `rm` (or a marker written by a pass that then succeeded) must not alarm
    # forever. `at=` on both sides is the only ordering evidence either file carries.
    unrec_at="$(sed -n 's/^at=//p' "$O/.refresh-unrecorded" 2>/dev/null | head -1)"
    # STRICTLY newer: on a tie the marker wins, because the fail-closed reading is the one that cannot
    # hide a failed pass (a pass that fails within the same second as the previous record is exactly the
    # case where "the record is newer" would be a guess).
    if is_num "${unrec_at:-}" && is_num "${at:-}" && [ "$at" -gt "$unrec_at" ]; then
      unrec=""
    fi
  fi
  # ⛔ `skipped` IS A CLAIM IN TWO PARTS: a pass SUCCEEDED **and** a usable candidate is deferred. The
  # branches keep it honest in BOTH directions — a failed pass never prints it (the mask this fixes),
  # and a healthy queue is never called BLOCKED merely because no pass has been needed yet (the
  # refresh only runs while the backlog is short, so a box with 8 candidates queued and nothing
  # failing must not alarm — it says `deferred`).
  if [ -n "$unrec" ]; then
    printf '[dispatch] BLOCKED: a refresh pass finished and could not record its outcome (%s) — the record on disk is an EARLIER pass and is NOT the health of this cycle; read the marker: rc=0 means the pass SUCCEEDED and only its record failed%s | %s lanes=%s workers=%s | PR path: %s\n' \
      "$unrec" "$tailnote" "$why" "$lanes" "$workers" "$prtail"
  elif refresh_contract_gap "${result:-}" "${at:-}" "${d:-}"; then
    # ⛔ TWO STATES, TWO SENTENCES (agent-infra#2308). The record below may say `running` (a pass that
    # started and never finished), `fail`, a STALE `ok`, or nothing at all — but when NOTHING on this box
    # can write the record, its age is not evidence about any pass, and this branch must not lend it the
    # authority of a cause. Only FRESHNESS exempts a record (see `refresh_contract_gap`), so a fresh `ok`
    # never reaches this line and a stale one does — which is the point: the frozen content is quoted (so
    # a real past failure, or a real past success, is not lost) and the verdict names the deployment
    # defect plus the paths it tried.
    # ⛔ THE CLAUSE MUST AGREE WITH THE RESOLVER'S OWN ANSWER (review P2). With rc=2 the path in
    # `$REFRESH_SH` is BY DEFINITION a copy that CANNOT record — `resolve_refresh_sh` only falls back
    # to an incapable copy when no recorder was found anywhere — so the old wording ("a copy that can
    # record would run as %s") asserted the capability of the one file it had just proved incapable,
    # and an operator reading it would take the stale seed for healthy. rc=1 names no copy at all.
    local _skew_run
    if [ "${REFRESH_RC:-1}" = "2" ] && [ -n "$REFRESH_SH" ]; then
      _skew_run="the copy this box WOULD run is $REFRESH_SH — it cannot record"
    elif [ -n "$REFRESH_SH" ]; then
      _skew_run="a copy that can record would run as $REFRESH_SH"
    else
      _skew_run="no refresh copy exists on this box to run"
    fi
    printf '[dispatch] BLOCKED (SEED-SKEW): no refresh script on this box can RECORD a pass outcome — so state/refresh-last (age: %s; frozen at result=%s %s) is written by NOTHING here, and its age is NOT evidence that a pass died — whether one is ALSO dying here is UNKNOWABLE from this record (check state/refresh-funnel and the log); what is proved is only that nothing on this box can advance it, which is a deployment defect with a one-line remedy. Tried: %s. Fix: re-seed $O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O) — %s, and the loop looked beside itself in %s;%s %s lanes=%s workers=%s | PR path: %s\n' \
      "$age" "${result:-<no result= recorded>}" "$(refresh_cause_brief "$rec")" \
      "${REFRESH_TRIED:-none}" "$_skew_run" "${REFRESH_SELF_DIR:-?}" \
      "$tailnote" "$why" "$lanes" "$workers" "$prtail"
  elif [ "${result:-}" = "ok" ]; then
    if [ "$backlog" -gt 0 ]; then
      printf '[dispatch] skipped (%s) lanes=%s workers=%s — deferred: %s usable candidate(s) queued, head #%s (refresh ok, %s) | PR path: %s\n' \
        "$why" "$lanes" "$workers" "$backlog" "${head:-?}" "$age" "$prtail"
    else
      # ⛔ WHAT THE PASS RECORDED, NOT WHAT THE QUEUE IMPLIES (review P1, two reviewers). The first
      # version said “the last refresh pass queued 0 usable candidate(s)” because the queue is empty
      # NOW — but the ordinary drain state is “the pass queued 3 and dispatch took all 3”, where that
      # sentence is false and sends an operator after origination that worked. The record carries the
      # truth (`queued=`, `handed=`); it is printed as recorded, and `?` when it recorded nothing.
      if [ -n "$hrec" ]; then
        printf '[dispatch] nothing to defer (%s) lanes=%s workers=%s — the queue is EMPTY now; the last refresh pass (%s) recorded queued=%s and handed #%s to dispatch, so this is drained work, not a stalled origin | PR path: %s\n' \
          "$why" "$lanes" "$workers" "$age" "${qrec:-?}" "$hrec" "$prtail"
      else
        printf '[dispatch] nothing to defer (%s) lanes=%s workers=%s — the queue is EMPTY; the last refresh pass (%s) recorded queued=%s and handed nothing (see its `handed to dispatch: NONE` line for why) | PR path: %s\n' \
          "$why" "$lanes" "$workers" "$age" "${qrec:-?}" "$prtail"
      fi
    fi
  elif [ "${result:-}" = "fail" ]; then
    printf '[dispatch] BLOCKED: refresh failed — %s (%s)%s | %s lanes=%s workers=%s | PR path: %s\n' \
      "$(refresh_cause_brief "$rec")" "$age" "$tailnote" "$why" "$lanes" "$workers" "$prtail"
  elif [ "${result:-}" = "running" ]; then
    # ⛔ SEE `RUNNING_STALE_MIN` ABOVE: a YOUNG start marker is a pass in flight, an OLD one is a pass
    # that died. The record cannot tell them apart and neither can this reader — but TIME can, and the
    # bound is the same one the controller uses to decide a lock is stale.
    if ! is_num "${d:-}"; then
      # ⛔ AN UNREADABLE STAMP IS NOT A FRESH ONE (review P1), AND THE CAUSE MUST BE THE REAL ONE (review
      # P2): three different states land here — the box clock is unreadable (`date +%s` failed, so
      # `now=0`), the stamp is in the FUTURE (the clock stepped back, or a corrupt record), or `at=` is
      # missing/unparseable. `d` is only set when `at` is a number AND `at <= now`, so all three used to
      # be reported as "no readable at=" — a cause the code does not have, on a record whose `at=` is
      # perfectly readable. Each state now names itself.
      if [ "${now:-0}" -le 0 ]; then
        age_why="the box clock is UNREADABLE (date +%s failed), so the start marker cannot be aged"
      elif is_num "${at:-}" && [ "$at" -gt "${now:-0}" ]; then
        age_why="its at= is in the FUTURE (epoch $at > now $now — the clock stepped back, or the record is corrupt), so the age is not knowable"
      else
        age_why="it carries no readable at= (age unknown)"
      fi
      printf '[dispatch] BLOCKED: a refresh pass left a start marker that cannot be aged — %s; an unageable marker is not a fresh one, so this cannot be told apart from a pass that DIED;%s %s lanes=%s workers=%s | PR path: %s\n' \
        "$age_why" "$tailnote" "$why" "$lanes" "$workers" "$prtail"
    elif [ "${d:-0}" -ge "$RUNNING_STALE_MIN" ]; then
      printf '[dispatch] BLOCKED: a refresh pass wrote its start marker %s and has recorded no outcome since — %sm is past the %sm stale bound, so the pass DIED (SIGKILL, OOM, cycle timeout, or an uncaught error) and nothing will replace that marker but a pass that finishes;%s %s lanes=%s workers=%s | PR path: %s\n' \
        "$age" "${d:-?}" "$RUNNING_STALE_MIN" "$tailnote" "$why" "$lanes" "$workers" "$prtail"
    elif [ "$backlog" -gt 0 ]; then
      printf '[dispatch] deferred (%s) lanes=%s workers=%s — %s usable candidate(s) queued, head #%s; a refresh pass wrote its start marker %s and has recorded no outcome yet. A deferral whose origination is UNPROVEN: do not read this as a healthy pass | PR path: %s\n' \
        "$why" "$lanes" "$workers" "$backlog" "${head:-?}" "$age" "$prtail"
    else
      # The empty-queue-yet-fresh case: the pass is in flight and has not queued anything YET. That is
      # the ordinary state for a healthy pass on a short backlog, so it must not be BLOCKED.
      printf '[dispatch] nothing to defer (%s) lanes=%s workers=%s — the queue is EMPTY; a refresh pass wrote its start marker %s and has recorded no outcome yet, so this is work in progress, not a drained queue and not a death | PR path: %s\n' \
        "$why" "$lanes" "$workers" "$age" "$prtail"
    fi
  elif [ -f "$O/state/refresh-last" ]; then
    # The file EXISTS but its `result=` is absent or a value this reader does not know — truncated,
    # hand-edited, half-synced, or written by a NEWER writer than this controller. That is not "no
    # pass has run" and it is not "healthy": stale evidence cannot license `skipped`. ⛔ The message
    # names what it OBSERVED (review P2): saying "no result= key" about a record that visibly has one
    # is the confident-wrong-cause class this change exists to end.
    printf '[dispatch] BLOCKED: the refresh outcome record is UNREADABLE (result=%s is not a value this reader knows — ok/fail/running) — a pass that cannot say how it ended cannot license "skipped"; %s lanes=%s workers=%s | PR path: %s\n' \
      "${result:-<absent>}" "$why" "$lanes" "$workers" "$prtail"
  elif [ "$backlog" -gt 0 ]; then
    printf '[dispatch] deferred (%s) lanes=%s workers=%s — %s usable candidate(s) queued, head #%s, but NO refresh outcome is on record yet: the queue predates this controller, or the backlog has been long enough that no pass was needed. Work is deferred for the gate above; this line is not evidence that origination works | PR path: %s\n' \
      "$why" "$lanes" "$workers" "$backlog" "${head:-?}" "$prtail"
  else
    printf '[dispatch] BLOCKED: no refresh pass has completed on this box — cannot tell "no work" from "origination never ran"; %s lanes=%s workers=%s | PR path: %s\n' \
      "$why" "$lanes" "$workers" "$prtail"
  fi
}
# [origination:end]
dispatch_funnel() { # <dispatched_count> <queue_token> [<held_reason>] [<now_epoch>] [<yields>]
  local k="${1:-0}" qtok="${2:-?}" held="${3:-}" now="${4:-}" f key val kv backlog=0
  # The #1909 yield note. `<yields>` is the count THIS cycle yielded, and it is normalised first:
  # a non-numeric value must not reach a `[ ... -gt ... ]`, which would be FALSE and silently
  # UNDER-report the yields — the same fail-open shape the reader-side cases refuse.
  local yld="${5:-0}" ynote=""
  case "$yld" in ''|*[!0-9]*) yld=0 ;; esac
  if [ "$yld" -gt 0 ]; then
    # ⛔ THE WORDS MUST MATCH THE GATE (#2409). A `land` refusal is REPO-WIDE: every box measures the
    # same open count against the same landing rate, so telling the operator (and the funnel) that this
    # was "for capacity" and the item is "free for other boxes" is FALSE for it — the remedy is to land
    # an open PR, on this box or any other. `capacity_yield_live` exports the gate, so the sentence can
    # name it instead of assuming load.
    ynote=" | yields=$yld (stood down by a GATE refusal — this is NOT \"the fleet has nothing to do\"; a load/disk stand-down leaves them free for other boxes, a land-backlog one is repo-wide and clears only by landing)"
  fi
  # ⛔ EVERY ONE OF THESE IS INITIALISED. They are assigned only when their key is present in the
  # record, and under `set -u` a declared-but-unassigned local is UNBOUND: a record missing one key
  # (a rename, a hand-edited or half-synced $O) exited the whole controller — a KeepAlive crash loop
  # on a record that persists. Measured in review round 2: `unj: unbound variable`, exit 1.
  local listed="" judged="" queued="" col="" land="" unj="" sk_ck="" sk_dp="" sk_ld="" sk_co="" notr="" at="" reconciled=""
  local age=""
  # ── THE CAUSE, THE FAILING SURFACE, AND WHAT THE SUPPRESSION COST (agent-infra#2183) ──────────
  # `not_reached` is DERIVED, so before these keys existed the largest bucket on a starved cell was
  # printed as `(limit)` — an instruction to raise LIMIT that the record itself contradicted when
  # `limit=` appeared at its real value beside it. Measured on cell-1, 2026-10-20: 183 of 195
  # candidates "not reached (limit)" where the true cause was a spent `RUN_BUDGET`. Each key is
  # optional here (a record from an older writer simply omits it) and each is initialised, because
  # under `set -u` a declared-but-unassigned local is UNBOUND and a missing key would crash the
  # controller — the `unj: unbound variable` loop this block already records.
  local stop="" limit="" unusable="" ck_rel="" ck_unjust="" ck_def="" ck_ref="" ck_sort="" stop_cf="" reason_cf=""
  # ⛔ `repo=` IS A RECORD FIELD, NOT A RENDERED ONE (review P3, #2183). It exists so "is this pool
  # the right repo" is answerable from the record — the `[cap]` line beside it already carries
  # `@${OR}` — so the reader must NOT grow a local for it that nothing ever reads (a dead local that
  # reads as "this is shown to the operator" while it is not).
  local sk_q="" sk_d="" sk_p="" sk_l="" sk_c="" sk_cu="" sk_df="" sk_u=""
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
      stop) stop="$val" ;; limit) limit="$val" ;; unusable) unusable="$val" ;;
      checked_released) ck_rel="$val" ;; checked_unjustified) ck_unjust="$val" ;;
      checked_deferred) ck_def="$val" ;; checked_refused) ck_ref="$val" ;;
      checked_sort_failed) ck_sort="$val" ;;
      stop_conflict) stop_cf="$val" ;; reason_conflict) reason_cf="$val" ;;
      skipped_checked_queued) sk_q="$val" ;; skipped_checked_dispatched) sk_d="$val" ;;
      skipped_checked_pr) sk_p="$val" ;; skipped_checked_lane) sk_l="$val" ;;
      skipped_checked_claim) sk_c="$val" ;; skipped_checked_claim_unknown) sk_cu="$val" ;;
      skipped_checked_deferred) sk_df="$val" ;; skipped_checked_unknown) sk_u="$val" ;;
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
      # ⛔ "NO PASS HAS RUN" IS NOT WHAT AN ABSENT FUNNEL MEANS (review E-P2, cycle 4). A pass that
      # refuses on the REST budget (or on provisioning) exits BEFORE writing the funnel, so a box that
      # runs one every cycle and refuses it every cycle printed "no refresh pass has recorded its funnel
      # yet" — a false statement about our own state on the exact box this patch is about. The honest
      # reading is that no pass RECORDED a decomposition; the [refresh] cause is in the log.
      printf '[dispatch] %s queued of an UNRECORDED pool (no state/refresh-funnel — no pass has recorded a decomposition; a pass that refused before listing writes none) -> %s dispatched%s (queue=%s%s)\n' \
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
  # ⛔ THE SUPPRESSION NOW SAYS WHY IT SUPPRESSED. `N blacklisted (checked)` was the same kind of
  # unmeasured number as `not reached (limit)`: checked.txt short-circuits a candidate before any
  # network call, so an operator had no way to see whether those N were waiting, dispatched, owned by
  # a live lane, held by a peer's claim, or held by nothing at all. The breakdown sums to N by
  # construction (the writer counts every reason, `unknown` included); a record without the keys —
  # an older writer — keeps the old wording and invents no zero.
  if is_num "$sk_ck"; then
    if is_num "$sk_q" || is_num "$sk_d" || is_num "$sk_p" || is_num "$sk_l" \
       || is_num "$sk_c" || is_num "$sk_cu" || is_num "$sk_df" || is_num "$sk_u"; then
      parts+=("$sk_ck blacklisted (checked: queued ${sk_q:-0}, dispatched ${sk_d:-0}, pr ${sk_p:-0}, lane ${sk_l:-0}, claim ${sk_c:-0}, claim-unknown ${sk_cu:-0}, deferred ${sk_df:-0}, unknown ${sk_u:-0})")
    else
      parts+=("$sk_ck blacklisted (checked)")
    fi
  fi
  is_num "$sk_dp"    && parts+=("$sk_dp already dispatched")
  is_num "$sk_ld"    && parts+=("$sk_ld already landed (skipped)")
  # ⛔ PEER-HELD IS NOT "NOT REACHED" (review finding P2-1 for #2124). The refresh walks PAST a
  # candidate a recent pass recorded as peer-held, at no network cost. Until this bucket existed the
  # row was counted nowhere, so it landed in the DERIVED `not_reached` bucket and this function
  # printed it as `N not reached (limit)` — the one part that tells an operator to raise `LIMIT`,
  # asserted about a pass whose `limit=` is printed right beside it at its real value. A record that
  # predates this key simply omits the part (no invented zero), and an older reader ignores it.
  is_num "$sk_co"    && parts+=("$sk_co peer-held (ledger skip)")
  # ── WHY THE WALK DID NOT REACH THEM (agent-infra#2183) ──────────────────────────────────────
  # ⛔ `(limit)` WAS A CAUSE NOBODY MEASURED. The refresh wrote no stop reason at all, so this
  # function asserted the one reading that tells an operator to raise LIMIT — about a pass whose
  # `limit=` it prints at its real value in the same sentence, and whose actual stop was usually the
  # `RUN_BUDGET` (pre-flight RUNS, a different budget) or a spent REST reserve. A record that
  # predates `stop=` gets no invented cause; it says the cause was not recorded, which is the truth.
  if is_num "$notr"; then
    case "${stop:-}" in
      limit)      parts+=("$notr not reached (slot limit: ${limit:-?} slot(s) filled)") ;;
      run_budget) parts+=("$notr not reached (run budget: ${judged:-?} pre-flight run(s) spent, ${unj:-?} unjudged)") ;;
      spend)      parts+=("$notr not reached (REST spend reserve)") ;;
      none)       parts+=("$notr not reached (the walk reached the end of the pool)") ;;
      *)          parts+=("$notr not reached (cause not recorded)") ;;
    esac
  fi
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
  # ── APPENDED FACTS — ONE SEPARATOR, ALWAYS (`— `) ────────────────────────────────────────────
  # ⛔ THE FAILING SURFACE IS THE POINT OF THE WHOLE RECORD ON A BROKEN CELL. `12 unjudged` says
  # twelve runs produced nothing actionable; `— failing surface: issue-assignee-holder:12` says it
  # was one surface failing twelve times, which is a different repair. Rendered only when the writer
  # recorded something other than `none`, and never with an extra literal: the occurrence count is
  # already inside the field.
  local tail=""
  case "${unusable:-}" in ''|none) : ;; *) tail="$tail — failing surface: $unusable" ;; esac
  # ⛔ A FAILED REWRITE IS NOT "NOTHING WAS RELEASED". The writer publishes `checked_released=-`
  # when the atomic `checked.txt` rewrite failed — the entries ARE still suppressed and nobody knows
  # how many. Rendering that as nothing made a failed release indistinguishable from a quiet pass on
  # the one line an operator reads, with the only contradicting evidence a WARN in the refresh log
  # that this reader never sees.
  case "${ck_rel:-}" in
    # ⛔ ONE SENTINEL, MORE THAN ONE CAUSE (review A-P3, cycle 4). `-` is published when the count was
    # not recorded — the `checked.txt` rewrite FAILED, the `state/checked-reap` write failed, or the
    # record predates this pass. Naming the rewrite alone sent an operator to the wrong file.
    -) tail="$tail — released from checked: UNKNOWN (the count was not recorded — see the refresh log)" ;;
    *)
      if is_num "$ck_rel" && [ "$ck_rel" -gt 0 ]; then
        tail="$tail — $ck_rel released from checked"
      fi ;;
  esac
  # ⛔ AN UNPROVEN SUPPRESSION IS SHOWN, NOT HIDDEN. An entry kept because the claim registry could
  # not answer is not justified and not released; leaving it inside the checked total would make the
  # line read as fully accounted for. `expected bound: 0` is the writer's own statement.
  if is_num "$ck_unjust" && [ "$ck_unjust" -gt 0 ]; then
    tail="$tail — UNPROVEN suppression: $ck_unjust checked entr(ies) with no proven fact"
  fi
  # ⛔ A BOUND THAT BINDS EVERY CYCLE IS A MEASUREMENT, NOT SILENCE (review E-P2, cycle 2). The reaper
  # published `deferred=` and NOTHING read it, so a cell whose release cap was too small for its
  # `checked.txt` — the one reading that says "raise CHECKED_RELEASE_MAX" — looked exactly like a cell
  # with nothing to release. Only the residue is shown: `0` is the healthy quiet pass and has no line.
  if is_num "$ck_def" && [ "$ck_def" -gt 0 ]; then
    tail="$tail — $ck_def checked entr(ies) deferred by the release cap (a standing residue means CHECKED_RELEASE_MAX is too small for this cell)"
  fi
  # ⛔ A REFUSED CLASSIFICATION IS A STATEMENT, NOT AN ABSENT TAIL (review E-P2, cycle 3). Every
  # refusal records `unjustified=-`, and `-` rendered as nothing — so a permanently undecodable
  # `.pr_brs`, whose refusal is *designed* to repeat on every pass, produced a line byte-for-byte
  # identical to a healthy quiet pass: the #2183 defect this whole patch exists to end, one layer in.
  # The refusal now names the fact that could not be read.
  case "${ck_ref:-}" in
    ''|none) : ;;
    # ⛔ A RELEASE MADE WITHOUT THE CLAIM READ IS A CAVEAT, NOT A REFUSAL (review). The fallback slug
    # means the classification RAN and entries WERE released — on local facts only, because
    # `$O/claims.sh` is not installed. Rendering it with the refusal sentence below would tell the
    # operator "nothing could be released" about the one pass that released without the cross-box check.
    claim-registry-absent) tail="$tail — checked release ran WITHOUT the claim registry (not installed on this box): released on LOCAL facts only, so a peer's cross-box claim would not have been seen" ;;
    *) tail="$tail — checked classification REFUSED this pass ($ck_ref): nothing could be released" ;;
  esac
  # ⛔ AND A RELEASE THAT COULD NOT RUN IS NOT A CAP THAT BOUND (review E-P2, cycle 3): a failed
  # `mktemp`/`sort` left every candidate `unknown`, and the only line an operator reads named
  # `CHECKED_RELEASE_MAX` — the one knob that cannot help.
  case "${ck_sort:-}" in
    ''|'-'|0|None|none) : ;;
    *) tail="$tail — checked release DID NOT RUN (the release sort failed): the suppression is unrevalidated this pass" ;;
  esac
  # ⛔ A CONTRADICTION BETWEEN THE CAUSE AND THE RESIDUE IS ITS OWN STATEMENT, never "the parts do not
  # sum": the parts DID sum, and accusing the pool of an arithmetic failure about a pass whose
  # arithmetic is fine would send the operator to the wrong place. `reconciled=` is left alone.
  if is_num "$stop_cf" && [ "$stop_cf" -gt 0 ]; then
    tail="$tail — STOP CONTRADICTION (the recorded cause and the residue disagree)"
  fi
  if is_num "$reason_cf" && [ "$reason_cf" -gt 0 ]; then
    tail="$tail — CHECKED BREAKDOWN DOES NOT SUM (the record's own accounting is incomplete)"
  fi
  printf '[dispatch] %s candidates -> %s -> %s dispatched%s (backlog=%s, queue=%s%s%s)%s\n' \
    "${listed:-?}" "${joined:-no reason recorded}" "$k" \
    "${held:+ | held: $held}" "$backlog" "$qtok" "${age:+, funnel ${age}m old}" "$ynote" "$tail"
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
  local f rec kv at="" bucket="" reset="" until="" rec_at="" now age
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
      until=*)     until="${kv#until=}" ;;
      recovered=*) rec_at="${kv#recovered=}" ;;
    esac
  done
  is_num "${at:-}" || return 0
  is_num "${reset:-}" || reset=""
  is_num "${until:-}" || until=""
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
  # ⛔ THE WINDOW IS `until=`, NOT `reset=`. A secondary/unclassified refusal retries in ~60 s while the
  # bucket reset is ~43 min out; printing only `reset=` made the ONE line a human reads name a
  # 43-minute block for a limit the layer clears in a minute — the misreading #2137 removes everywhere
  # else. `until=` is the window this box actually honours, and it is printed BESIDE the reset (never
  # instead of it) so every existing reader of the token keeps working.
  printf 'gh=rate_limited(bucket=%s reset=%s until=%s %ss)' "${bucket:-?}" "$reset" "${until:-$reset}" "$age"
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
# (gh pr merge / ready) stay ungated, so merges keep flowing while the spike passes. ⛔ `run rerun` is
# NOT among them any more: it is the one verb here that ADDS to the CI queue the back-pressure gate is
# holding work out of, so it is gated by `ciq_push_ok` (#2296). The merge rail's own second-sample
# re-run is a deliberate exclusion, disclosed in `ci-queue.sh`'s header — it runs inside a merge
# decision that REMOVES queue.
# Nothing is starved: a held-back spawn retries next cycle, because the marker that authorises it
# (needsfix-<PR>-<head>, fixcount-<PR>) is only written on a SUCCESSFUL spawn.
#
# ⛔ MEMORY IS PART OF THE SPAWN GATE (agent-infra#1732), AND IT IS THE BINDING ONE WHEN IT BINDS.
# The load gate alone covered these sites while the DISPATCH gate was bounded by load + lanes + swap +
# available memory — two gates over two different populations, with the resource that actually kills
# this box (measured 2026-10-22: MemAvailable 653MB with 14 lanes, and the box OOM-killed its OWN
# runners; the pool oscillated 12→8 three times) consulted on only one of them. Raising MAX_LOAD
# widens the band in which the spawn sites proceed while memory is already the constraint, so the
# spawn path must read it too.
#
# The polarity is the DISPATCH gate's, not the disk gate's: `mem_avail <= MIN_MEM_FREE_MB` refuses
# (the same boundary for THAT arm, so the two gates cannot disagree about the `mem_avail` reading
# itself), and UNKNOWN is NOT ample — a
# probe we could not take is not evidence of capacity. That is deliberately FAIL-CLOSED while the
# load reading stays fail-open (an unreadable load file must not stop every merge on a host without
# procfs); the two are different probes with different failure costs, and `MEMAVAIL_MB` is only ever
# set by measure_mem(), which zeroes it on failure so this holds even if MEM_UNKNOWN is ever unset.
#
# It reads the CYCLE-LEVEL reading measured in the prologue — the same posture as `L`, which the
# spawn sites have always read from the cycle's own `load1`. The [cap] gate re-measures, because it
# decides a dispatch and must see the present.
# ⚠️ NOT COVERED HERE, BY DESIGN: the dispatch gate's OTHER arms (`lanes=`, `swap_free=`, and the
# swap-joint `mem_avail <= 2*MIN_MEM_FREE_MB` arm that only arms when swap is also tight). A spawn
# refused by those is a different population's decision and is not this gate's to make — so the
# shared boundary is the plain `<= MIN_MEM_FREE_MB` arm, and nothing more.
mem_spawn_ok() { [ "${MEM_UNKNOWN:-0}" != "1" ] && [ "${MEMAVAIL_MB:-0}" -gt "$MIN_MEM_FREE_MB" ]; }
can_spawn() { [ "${L:-0}" -lt "$MAX_LOAD" ] && mem_spawn_ok && [ "${LANES_UNKNOWN:-0}" != "1" ]; }
# ⛔ THE PR PATH IS CAPACITY-GATED ON THE SAME CENSUS AS THE ISSUE BATCH (#2163 review r8, P2).
# `can_spawn` read LOAD (and, after #1732, memory) only, so a box whose lane census was `?/?` still
# had merge-/fix-/review lanes added on the PR side while the cycle logged `[dispatch] skipped
# (lanes_unknown …)` for the issue side — the docs promised "an unreadable census makes the controller
# REFUSE to add work" and the promise stopped at the issue batch. The OOM direction is the reason the
# census exists (#2159): an unreadable census cannot bound how full the box is, and a merge lane is a
# `pi` like any other, so abstaining on ONE add-work path is abstaining on neither. Both paths refuse.
# spawn_gate_tok — the EVIDENCE a held-back spawn records, in the ONE shape all five slot refusals
# print (agent-infra#1732). Before the memory arm these lines printed `load-gate=<L>/<MAX_LOAD>` only,
# and that was complete: load was the whole gate. It is not any more — a memory-only refusal would now
# print two healthy-looking numbers and name no cause, which is the silent-refusal class this file
# removes elsewhere (#2126 T5). The token reports the reading AND the floor for both arms, so the line
# answers "which gate bound" without a second lookup; UNKNOWN is spelled out rather than printed as a
# number, because `0M/512M` is a refused-probe reading that reads like a real measurement.
spawn_gate_tok() {
  local mem="UNKNOWN"
  [ "${MEM_UNKNOWN:-0}" = "1" ] || mem="${MEMAVAIL_MB:-?}M"
  # …and the CENSUS arm (#2163 review r8). A token that named only load/memory would print two
  # healthy numbers for a refusal the census made — the silent-capacity-refusal shape #2126 T5 removed.
  if [ "${LANES_UNKNOWN:-0}" = "1" ]; then
    printf 'lanes_unknown (the lane census could not be read -> do not add work); load-gate=%s/%s mem-gate=%s/%s' "${L:-0}" "${MAX_LOAD:-?}" "$mem" "${MIN_MEM_FREE_MB:-?}"
  else
    printf 'load-gate=%s/%s mem-gate=%s/%s' "${L:-0}" "${MAX_LOAD:-?}" "$mem" "${MIN_MEM_FREE_MB:-?}"
  fi
}
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
park_ctrl() { # park_ctrl <pr> <head> <reason…> — returns non-zero when the park did NOT land
  # ⛔ THE PARK IS THE TERMINATOR, SO ITS WRITE STATUS MATTERS (review round 4 of #2653, P2). Every
  # escalation in this file ends in a park, and the sweep's guard is a `cat` of `parked-<PR>`; if that
  # file cannot be written (a stray directory of that name, a read-only or full `state/` — the hazard
  # this file names at its own `state/` note), the PR is NOT parked: it re-enters the arm every cycle
  # while the log and the ledger both claim "PARKED". The callers that escalate on a bound check this
  # status and say so; the older callers ignore it, so their behaviour is unchanged.
  printf '%s\n' "$3" > "$O/state/parkreason-$1" && printf '%s\n' "$2" > "$O/state/parked-$1"
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
# ── WHAT THIS PASS ACTUALLY STARTED (agent-infra#2590) ───────────────────────────────────────────
# ⛔ `act` IS NOT `spawn` (MEASURED 2026-10-23). A disposition row is `act` for a spawned worker, for
# `gh pr merge`, for `gh run rerun`, for a draft ready and for an auto-merge ARM — so `2 acted` was
# printed beside `#9528 auto-armed` + `#9812 re-record`, and the funnel then said "dispatching
# PR-takeover" on the strength of a button press. `N acted` could never answer "did the fleet move?".
# ⛔ SO THE COUNT IS READ FROM AN ARTIFACT, NEVER FROM A CLAIM: `wt_spawn` writes `state/worker-<tag>`
# with `created=<epoch>` and nothing else creates those records. A spawn that was REFUSED leaves no
# record (PR #2383 measures those separately, in `spawn-refused.tsv`), and a record is what the
# census, the caps and the reaper bind to — so "a record with created >= this cycle's start" is the
# only population that means "a worker of ours is (or was) running because of this pass".
# ⛔ AN UNREADABLE ANSWER IS EMPTY, NOT ZERO: a path we cannot enumerate must not print `NONE`, which
# would be the same lie sign-reversed (a measured negative from no measurement at all).
spawns_since() { # spawns_since <since-epoch>  ->  "<n>\t<tag,tag,...>" (empty n == UNMEASURED)
  local since="${1:-}" dir f name cre n=0 tags=""
  is_num "${since:-}" && [ "$since" -gt 0 ] || return 0
  dir="${WT_DIR:-${O:-$HOME/orchestrator}/state}"
  [ -d "$dir" ] && [ -r "$dir" ] || return 0
  for f in "$dir"/worker-*; do
    [ -f "$f" ] || continue
    name="${f##*/worker-}"
    # Same name predicate the module refuses on: anything else was never a wt_spawn record.
    case "$name" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    cre="$(sed -n 's/^created=//p' "$f" 2>/dev/null | head -1)"
    is_num "${cre:-}" || continue
    [ "$cre" -ge "$since" ] || continue
    n=$((n+1)); tags="${tags:+$tags,}$name"
  done
  printf '%s\t%s\n' "$n" "$tags"
}
# ── THE DRAIN'S PERSISTENT STATE TOKEN (agent-infra#2590) ────────────────────────────────────────
# The stall line is a LOG line, and a log line is read by nobody until someone goes looking — the
# measured cost was a box at `DRAIN STALLED` for 8 passes while its operator read `lanes=0` as "idle".
# The artifact `state/drain-stall` carries the escalation ACROSS passes, and this token puts it on the
# cycle status line, which is the one line every reader already parses.
# ⛔ IT SELF-HEALS ON A LAND: a marker that outlives the condition it names is the "stale flag that
# records a past state and is never revalidated" failure this file keeps removing, so a land newer
# than the marker deletes it here — the writer does not have to remember to.
drain_stall_token() {
  local f="$O/state/drain-stall" at passes spawns unowned lage m lbl
  [ -f "$f" ] || return 0
  at="$(sed -n 's/^at=//p' "$f" 2>/dev/null | head -1)"
  if is_num "${at:-}"; then
    m="$(mp_recent_land 2>/dev/null || true)"
    if is_num "${m:-}" && [ "$m" -gt "$at" ]; then rm -f "$f" 2>/dev/null; return 0; fi
  fi
  passes="$(sed -n 's/^passes=//p' "$f" 2>/dev/null | head -1)"
  spawns="$(sed -n 's/^spawns=//p' "$f" 2>/dev/null | head -1)"
  unowned="$(sed -n 's/^unowned=//p' "$f" 2>/dev/null | head -1)"
  lage="$(sed -n 's/^age=//p' "$f" 2>/dev/null | head -1)"
  lbl="$(drain_stall_label "$f")"
  printf ' drain=%s(passes=%s,unowned=%s,no_land=%sm,spawns=%s)' \
    "${lbl:-UNMEASURED}" "${passes:-?}" "${unowned:--}" "${lage:--}" "${spawns:-?}"
}
# ── THE ESCALATION'S LABEL, DERIVED FROM ITS OWN MEASUREMENT (review c-1, 2026-10-23) ─────────────
# ⛔ THE MARKER IS WRITTEN BY BOTH STALL ARMS, SO ITS *EXISTENCE* CANNOT MEAN "DEADLOCK". A STALLED
# pass records `spawns=4` ("the workers run and nothing lands — a LAND problem, not an idle one"), and
# a token that keyed on the file existing printed `drain=DEADLOCK(…,spawns=4)` for it — a deadlock
# claim over a pass that started four workers. That is precisely the claim-with-no-measurement class
# this change deletes, and it would have ridden the one line every reader parses.
# ⛔ SO THE LABEL IS THE MARKER'S OWN `spawns` FIELD, and the polarity is the same one the log arms use:
# a measured 0 is the deadlock (nothing started AND nothing landing), a measured positive is a stall
# with work in flight, and an ABSENT/garbled count is neither — it is UNMEASURED, never DEADLOCK
# (a deadlock claim from no measurement is the defect sign-reversed).
# ⛔ ONE DEFINITION, TWO READERS: the status-line token and `cycle-record.sh`'s `drain=` field both call
# this, so the two surfaces cannot disagree about what the box is in.
drain_stall_label() { # [<marker>]  -> DEADLOCK | STALLED | UNMEASURED (empty when there is no marker)
  local f="${1:-$O/state/drain-stall}" sp
  [ -f "$f" ] || return 0
  sp="$(sed -n 's/^spawns=//p' "$f" 2>/dev/null | head -1)"
  case "$sp" in
    ''|*[!0-9]*) printf 'UNMEASURED' ;;
    0)           printf 'DEADLOCK' ;;
    *)           printf 'STALLED' ;;
  esac
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
  CAPACITY_YIELD_GATE=""
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
  # The GATE, for callers whose words depend on it (#2409): a `land` refusal is repo-wide, so the
  # dispatch line must not claim the item is a peer's to take.
  CAPACITY_YIELD_GATE="${gate:-}"
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

# ── OWNERSHIP IN THE SPAWN ARMS: PROVEN, OR RELEASED (agent-infra#2831) ─────────────────────────
# ⛔ THE MEASURED DEFECT: `[pr] PR path: NO UNIT SPAWNED this cycle — 8 row(s) with a named reason
# (most common: 5 a worker already owns this PR)` while `lanes=0/0` and NO such workers existed. The
# arms below tested `claim_live` — the SPAWN GUARD, whose first arm is a deliberately-loose "any live
# pid holds the lock" test — so a `mergeclaim-<PR>.lock` whose writer had died (and whose pid was
# recycled by any unrelated process) kept its PR owned for ever: not spawnable (owned), not in the
# un-owned queue (owned), and never released (nothing reaps it). `claim_live`'s looseness is CORRECT
# for its own question ("may I work this?" — one lost merge is cheaper than a second worker); it is
# WRONG for the question these arms are asked, which is "is someone ALREADY working it?". Two
# questions, two predicates — the same split `pr_owned`/`claim_live` already documents above.
# So ownership here is `pr_owned` (a live process's cwd, a cmdline-BOUND lock, or a live foreign lease)
# plus the live worker record, and when NOT ONE of them holds while a lock exists, that lock is
# RELEASED with its reason in the log. That is the same proof-of-life `[reap]` applies to checked.txt
# entries: "no proven fact -> release". The over-release direction is bounded by the arms: a released
# PR simply re-enters the un-owned queue, where the rail and the cross-box CAS still refuse a second
# worker — while staying "owned" is unbounded and is what stopped the box doing either job.
pr_owner_live() { # <pr> [<head-sha>] [<branch>] -> 0 iff a LIVE thing owns it (reaps a stale lock)
  local pr="${1:-}" sha="${2:-}" br="${3:-}" _v _lk
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  # 1. the live facts `pr_owned` already proves (cwd scan, cmdline-bound lock, foreign lease).
  if pr_owned "$pr" "$sha" "$br"; then return 0; fi
  # 2. the worker RECORD (census: a `dead` row is excluded there, `unknown` counts live).
  if sess "fix-$pr" || sess "review-$pr" || sess "merge-$pr"; then return 0; fi
  # 3. NOTHING PROVEN. With the proof module available the verdict is a RELEASE — and it removes the
  #    record, because a verdict of "not owned" that leaves the un-spawnable record on disk would
  #    leave the PR exactly as stuck as before (that is the defect, not the fix). Without the module
  #    the pre-#2831 loose guard stands, unchanged and named, rather than being silently dropped.
  if [ "${PL_MOD:-0}" = "1" ]; then
    _lk="$O/state/mergeclaim-$pr.lock"
    [ -f "$_lk" ] || return 1
    # ⛔ THE VERDICT'S EXIT STATUS IS THE ANSWER (review P1, 2026-10-25). An earlier draft discarded
    # it and returned 1 unconditionally — so when the probe said OWNED (a lock that appeared between the
    # `pr_owned` call and this one, or a claim caught mid-creation) the arms SPAWNED A SECOND WORKER on
    # a live claim and logged it as a release. Only rc=1 is a release.
    if _v="$(pl_verdict "$O/state" "$pr" 1 1 2>/dev/null)"; then return 0; fi
    # Strip the verdict label with a REAL TAB: `${_v#RELEASED\t}` never matched (bash reads `\t` in a
    # pattern as an escaped `t`), so every reap line printed a duplicated label and a raw tab — review P2.
    _tab="$(printf '\t')"
    echo "[reap] #$pr released — ${_v#*"$_tab"}" >> "$LOG" 2>/dev/null || true
    return 1
  fi
  claim_live "$pr" "$sha"
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

# ── `--check-refresh`: IS THIS BOX ABLE TO PROVE ITS OWN ORIGINATION? (agent-infra#2308) ────────
# The loop's answer to a broken refresh is a log line, and a log line is not a signal a monitor, a
# CI job or `harness-status` can read. This mode is read-only and answers the ONE question the record
# contract depends on, with the same exit vocabulary as check-single-source.sh:
#   0  the executed refresh can record a pass outcome, and it is the seeded `$O` copy (no skew)
#   1  DIVERGENCE — `$O`'s copy cannot record; the controller would execute a different copy
#   2  UNKNOWN/BROKEN — no copy on this box can record, so origination cannot be proven at all
# It never exits 0 on "could not look", which is the shape that let a 16-hour false DIED run.
# ⛔ WHAT "READ-ONLY" DOES AND DOES NOT MEAN (review P2, measured): this block writes no record,
# spawns no pass and takes no lock (`LOCKF`/`acq`/the EXIT trap are all BELOW it). An invocation still
# does what EVERY invocation does above it, and that is not nothing: `mkdir -p "$O/logs" "$O/state"`,
# the `[startup] worker launcher=…` append to `$O/logs/orch-loop.log`, `touch` of `candidates.txt` /
# `checked.txt` / `dispatched.txt`, and `chmod +x "$O"/*.sh`. So a monitor pointed at ANOTHER box's
# `$O` creates those files and appends to that log — said plainly rather than claimed away.
# ⛔ AND 78 IS REACHABLE, OUTSIDE THE 0/1/2 BELOW: the startup guards (a missing repo-authority.sh /
# worker-terminal.sh, an unusable REPO) exit 78 before this case runs. That is deliberate — a box that
# cannot run at all has a bigger problem than its record, and answering 0/1/2 would grade a controller
# that would never start. A caller must read 78 as "cannot run", never as "healthy".
while true; do
  # ── 0) FORK HEADROOM, BEFORE THE FIRST FORK OF THE CYCLE (agent-infra#2293) ───────────────────
  # ⛔ THIS BLOCK MUST STAY ABOVE `date`/`git`/`gh`/ANY `$( )`. A box that cannot fork dies on the
  # first spawn (measured: bash exits, rc 254), so a gate placed after the clock is a gate that never
  # runs on the box it exists for. `fork_gate` sets FORK_STATE and, when the box is starved or its
  # headroom is below the margin, FORK_STARVED=1 — which the cycle body and the nap below consult.
  fork_gate
  # ── THE STARVED CYCLE: BUILTINS ONLY, NAMED, AND STILL ALIVE ─────────────────────────────────
  # Nothing here spawns. The record is the ONLY artifact a fork-exhausted box can leave, and it is
  # what `bin/harness status` reads as FORK-STARVED (never silence, never HEALTHY).
  if [ "${FORK_STARVED:-0}" = "1" ]; then
    CYCLE_N=$(( ${CYCLE_N:-0} + 1 ))
    _ft0=""; cycle_now _ft0 || _ft0=0
    # ⛔ A READING OF 0 MEANS "NO CLOCK", NOT "EPOCH ZERO" (review P1). It must never refresh the
    # anchor — that is what froze the derivation at 0 for the life of a bash-3.2 process — and it must
    # never be stamped as if it were a measurement.
    case "${_ft0:-}" in ''|*[!0-9]*|0) _ft0=0 ;; *) LAST_EPOCH="$_ft0"; LAST_SECONDS="$SECONDS" ;; esac
    # The heartbeat is written with a `printf` (a builtin), not `date`: a fresh heartbeat is what stops
    # a supervisor from concluding the controller is GONE and relaunching it into the same fork wall.
    # ⛔ BUT NEVER WITH A FABRICATED STAMP (review P1). A `0` here reads to every consumer as an epoch-0
    # heartbeat — infinitely old — so the doctor reports a STALE controller about a box that is alive:
    # a made-up reading in the one field that exists to prove liveness. No heartbeat, plus a NAMED
    # reason, is the honest arm; the record still carries `start=0`, which `harness status` calls
    # UNREADABLE rather than DEGRADED-stale.
    if [ "$_ft0" != "0" ]; then
      printf '%s\n' "${_ft0}" > "$O/heartbeat" 2>/dev/null || true
    else
      printf '[fork] heartbeat NOT stamped this cycle: no clock could be read without a fork (this shell has no fork-free epoch and this box cannot fork) — the cycle record carries start=0, which `harness status` reports as UNREADABLE, neither HEALTHY nor DEGRADED-stale\n' >> "$LOG" 2>/dev/null || true
    fi
    _cr_fork="${FORK_STATE:-unknown}"; [ "$_cr_fork" = "ok" ] && _cr_fork="unknown"
    _cr_why="fork_exhausted"; _cr_bound="fork_probe"
    [ "${FORK_STATE:-unknown}" = "low" ] && { _cr_why="fork_headroom"; _cr_bound="fork_headroom"; }
    if [ "${CYCREC:-0}" = "1" ]; then
      cycle_record_write "$O" \
        start="${_ft0:-0}" end="${_ft0:-0}" cycle="${CYCLE_N}" interval="${CYC:-240}" \
        selected="none" selected_n=0 dispatched=0 ids=- \
        nothing="$_cr_why" placement="fork_held" placed_on=none bound="$_cr_bound" \
        lpc_self="?" shapes=0 fork="$_cr_fork" fork_procs="${FORK_PROCS:-?}" fork_max="${FORK_MAX:-?}" \
        || printf '[cycle] ⚠️ THIS CYCLE COULD NOT BE RECORDED (state/ unwritable) — a fork-starved box with no record is SILENT, which is the failure this file exists to end\n' >> "$LOG" 2>/dev/null || true
    else
      printf '[cycle] fork_starved (cycle-record.sh absent — this state is NOT recorded anywhere)\n' >> "$LOG" 2>/dev/null || true
    fi
    printf '[fork] HELD cycle %s (%s): %s — this box is below its fork margin or cannot fork right now (procs=%s/%s). NO dispatch, NO refresh, NO git/gh this cycle: every one of them would spend a fork and the next failed fork KILLS this process (measured: bash exits 254). Backing off %ss and retrying. A box in this state cannot be cleaned from inside (agent-infra#2293) — restart it from outside, or let the lanes drain.\n' \
      "${CYCLE_N}" "${FORK_STATE:-unknown}" "${FORK_WHY:-fork_probe_failed}" "${FORK_PROCS:-?}" "${FORK_MAX:-?}" "${CYC:-240}" >> "$LOG" 2>/dev/null || true
    _nap="$(( 10#${CYC:-240} + (10#${CYC:-240} / 5) ))"
    fork_free_sleep "$_nap" || { sleep "$_nap" 2>/dev/null; }
    continue
  fi
  # ── THE CYCLE'S OWN CLOCK, and the record that proves it happened ─────────────────────────────
  # `CYCLE_T0` is the START of this cycle, not the end: a record stamped at the end reports the
  # whole cycle as if it took no time, and a cycle that HUNG would then look fresh for its whole
  # duration. `CYCLE_N` counts cycles in THIS process's life — a restart starts at 1, which is the
  # honest reading of a record file written by two different processes.
  CYCLE_T0="$(date +%s)"; is_num "${CYCLE_T0:-}" || CYCLE_T0=0
  LAST_EPOCH="$CYCLE_T0"; LAST_SECONDS="$SECONDS"
  CYCLE_N=$(( ${CYCLE_N:-0} + 1 ))
  # Per-cycle placement state, reset EVERY cycle: a stale `CAP_PLACE` from a cycle that could not
  # measure would otherwise be read as this cycle's decision (the exact stale-flag class this file
  # keeps removing).
  CAP_STATE=unavailable; CAP_PLACE=""; CAP_BOUND=""; CAP_WHY=""; CAP_LPC_SELF=""
  # ⛔ THE CI-QUEUE VERDICT IS PER-CYCLE STATE TOO, and it is reset HERE rather than at its read site
  # (#2333 review P1). The read happens in the DISPATCH block near the end of the cycle, but the PR
  # sweep that consumes `CIQ_VER` runs EARLY in it — and the sweep is a pipeline subshell, which
  # inherits the parent's variables. Without this reset, `ci-queue(${CIQ_VER:-…})` in the sweep's
  # disposition rows reports the PREVIOUS cycle's verdict from cycle 2 onwards: a row reading
  # `ci-queue(ok(...))` directly beside the `[ci-queue] DEFERRED deep(...)` line that same cycle
  # deferred on. One reset makes "unset here" true and keeps the row honest.
  CIQ_RC=1; CIQ_VER=""; CIQ_STATE=""; CIQ_QUEUED=""; CIQ_RUNNING=""; CIQ_RUNNERS=""
  CIQ_BUSY=""; CIQ_CEILING=""; CIQ_AGE=""
  # …and the per-cycle MEMO of the gate's verdict (`ciq_push_ok`), for the reason its own comment
  # gives: on a failed read the module's cache cannot help, so without this every arm re-reads live.
  CIQ_ARM_RC=""; CIQ_ARM_VER=""
  # `K` is the count of issues queued into `.batch` THIS cycle (the dispatch block below increments
  # it). Reset with the rest of the per-cycle state so the cycle record can never report a previous
  # cycle's count as this one's, and `Y` likewise (yields/placements are per-cycle evidence).
  K=0; Y=0
  heartbeat
  res_line   # MEASURE every resource; decide nothing from it
  # ── 0b) THE PRE-DISPATCH DISK FLOOR (agent-infra — the night two cells stopped on bytes) ──────
  # ⛔ IT RUNS BEFORE `harness_refresh_cycle`, `reap_stale_workers` and EVERY provisioning path, and
  # that placement IS the fix. Measured twice in one night: a cell at 872MB free failed
  # `stage=provision sub-step=scout-venv` (`uv sync` could not write a torch library) and a cell at 0
  # avail died with its unit still `active` — both discovered from the SYMPTOM, never from the cause,
  # because nothing measured the floor before paying for the work. `eldato-disk-reaper.timer` cannot
  # close this: it is hourly, it is not on this path, and the failure it must prevent is what stops it
  # from running.
  # ⛔ IT RUNS AFTER `heartbeat` ON PURPOSE. A held cycle still stamps liveness, because the supervisor
  # treats a missing heartbeat as a DEAD controller and relaunches it into the same wall (the fork arm
  # above documents the same lesson). A hold is a decision, and a decision must not look like a crash.
  # rc 1 = HOLD (below the floor after the reclaim pass): no refresh, no dispatch, no PR sweep this
  # cycle, ONE line naming free/floor/reclaimed, and the box naps like any other held cycle. rc 2 =
  # CANNOT-VERIFY: proceed unguarded, but SAY so — an unseen reading is not a healthy one, and the
  # disk-floor.sh header carries the measured reason that reading must not stop the box.
  if [ "${DISK_FLOOR_STATE:-absent}" = "ok" ]; then
    _df_line="$(disk_floor_gate "$O")"; _df_rc=$?
  else
    _df_line="[disk] CANNOT-VERIFY: no disk-floor.sh in $O or beside the loop (DISK_FLOOR_SRC='${DISK_FLOOR_SRC:-none}') — the pre-dispatch floor did NOT run this cycle, so a full disk will surface again as a provision failure, a stalled controller, or a silent 100%. Fix: re-seed \$O (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)"
    _df_rc=2
  fi
  # Best-effort on BOTH streams: at a full disk the log write is itself the thing that fails, and the
  # line is worthless if it only exists where nobody is reading. `|| true` is not swallowing an error
  # here — the disk is already the error, and this line is the report of it.
  [ -n "${_df_line:-}" ] && { printf '%s\n' "$_df_line" >> "$LOG"; } 2>/dev/null || true
  if [ "${_df_rc:-0}" = "1" ]; then
    # ── THE HELD CYCLE: NAMED, RECORDED, AND STILL ALIVE ────────────────────────────────────────
    # Modelled on the fork-starved arm above rather than invented: same shape (one line, a cycle
    # record with `nothing=`, a nap, a `continue`) so `bin/harness status` and `cycle-record.sh`
    # answer "why did this box dispatch nothing" from the record instead of from a grep.
    printf '%s\n' "$_df_line" >&2 2>/dev/null || true
    if [ "${CYCREC:-0}" = "1" ]; then
      cycle_record_write "$O" \
        start="${CYCLE_T0:-0}" end="$(date +%s 2>/dev/null || echo 0)" cycle="${CYCLE_N:-0}" interval="${CYC:-240}" \
        selected="none" selected_n=0 dispatched=0 ids=- \
        nothing="disk_floor" placement="disk_held" placed_on=none bound="disk_floor" disk="${_df_line:-}" \
        || printf '[cycle] ⚠️ THIS CYCLE COULD NOT BE RECORDED (state/ unwritable) — a disk-held box with no record is SILENT, which is the failure this block exists to end\n' >> "$LOG" 2>/dev/null || true
    else
      printf '[cycle] disk_held (cycle-record.sh absent — this state is NOT recorded anywhere)\n' >> "$LOG" 2>/dev/null || true
    fi
    _nap="$(( 10#${CYC:-240} + (10#${CYC:-240} / 5) ))"
    fork_free_sleep "$_nap" || { sleep "$_nap" 2>/dev/null; }
    continue
  fi
  reap_stale_workers
  # ⛔ THE LATCH IS RELEASED HERE, ONCE PER ITERATION — NOT AT LOAD. `_HR_DONE` starts at 0 and the
  # function sets it on entry, so a per-PROCESS latch would refresh once in the controller's whole
  # lifetime and then return early forever: every later cycle keeps the first cycle's token (empty on a
  # box that started current), a box that falls behind afterwards is spawned silently, and
  # `state/harness-refresh` stops being rewritten. That is the exact failure this block exists to end,
  # so the reset belongs at the call site — the guard still catches a SECOND call in the same cycle.
  _HR_DONE=0
  # ⛔ THE REFRESH RESOLUTION IS A PER-CYCLE FACT (agent-infra#2308), reset with the rest of the cycle
  # state. Cached per PROCESS it was a stale flag: a re-seed would not re-enable spawning (a cached
  # "absent" keeps logging "no refresh-candidates.sh found at all"), and a cached skew keeps printing
  # SEED-SKEW after the remedy — so the next GENUINE death would be misattributed to the seed.
  REFRESH_RESOLVED=0; REFRESH_RC=0; REFRESH_SH=""; REFRESH_SH_SKEW=""; REFRESH_TRIED=""
  harness_refresh_cycle   # re-pin / refuse / name a stale checkout; sets HARNESS_TOKEN
  L="$(load1)"
  # ⛔ MEASURE MEMORY HERE, ONCE, BEFORE THE FIRST SPAWN SITE — not only at the [cap] block below
  # (agent-infra#1732). The six `can_spawn` sites run in section 1-3 of the cycle and the [cap] block
  # runs in section 4, so a gate that read MEMAVAIL_MB there would decide on the PREVIOUS cycle's
  # reading (and on cycle 1, on nothing). Same rule LAND_EPOCH/UPN follow above: a value must be read
  # BEFORE the line that prints it, and before every gate that acts on it.
  measure_mem
  # Read the gh-limit record ONCE per cycle; the token is age-bounded inside (see gh_limit_token).
  GHL="$(gh_limit_token)"
  echo "=== $(date) load=$L lanes=$(wt_count lane-) backlog=$(wc -l < "$O/candidates.txt" | tr -d ' ') queue=$(queue_state_token)${GHL:+ $GHL}${HARNESS_TOKEN:+ harness=$HARNESS_TOKEN}$(drain_stall_token) ===" >> "$LOG"

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
  # ⛔ THE ACTABLE ROW SET MUST OUTLIVE THE PROCESS, NOT JUST THE CYCLE (#2601). `SWEEP_LIST` is the
  # ONLY actable row set the PR path has — `pr 	 branch 	 draft`, which is exactly what the arms
  # need and exactly what `state/pr-meta.tsv` does NOT carry (that file holds `pr \t created_at`, for
  # the selection order only). Before this, the file was memory-only, so any cycle that did not get a
  # fresh 200 had ZERO actable rows and every counted PR got `wait "no per-PR read"`. Measured on the
  # agent-infra controller 2026-10-23: 152 of 221 `[select]` lines were such cycles and the PR path
  # acted ZERO times over 555 cycles while 70 PRs sat open. A 304 is GitHub asserting "identical to
  # what you last cached", so the cached rows ARE this cycle's read — reusing them performs the read
  # instead of dropping it, and the SWEEP_MAX_AGE floor above still bounds how long that can hold.
  SWEEP_CACHED=0
  # Named on every per-PR wait row when there is no actable row set, so the reason says WHICH thing
  # was missing rather than "unchanged — 304 — or unreadable" (three different facts, one string).
  SWEEP_CACHE_NOTE=""
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
    # The cached rows are NOT read either: a deferred cycle made no request, so nothing vouches for
    # them this cycle. Named on every per-PR row rather than folded into the generic string.
    SWEEP_CACHE_NOTE="the sweep is DEFERRED (rate-limited until ${DEFER_UNTIL}) — no listing was requested, so no PR was read this cycle"
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
      # Unchanged: GitHub does not charge a 304 to the primary rate limit. It IS the listing, though,
      # so the rows are restored from the cache this cycle's 304 vouches for — an identical listing
      # means an identical PR set, and the arms need that set to act on. Bounded by SWEEP_MAX_AGE:
      # the conditional header is only sent while the last full sweep is younger than the floor.
      if [ -s "$O/state/sweep-rows.tsv" ]; then
        SWEEP_LIST="$(awk -F"$(printf '\t')" 'NF>=3 && $1 ~ /^[0-9]+$/ {print $1"\t"$2"\t"$3}' "$O/state/sweep-rows.tsv" 2>/dev/null || true)"
        # `pr-meta.tsv` comes back with it: the selection ORDER reads it, and a cache restore that
        # left it stale would order this cycle by another cycle's ages.
        awk -F"$(printf '\t')" 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' "$O/state/sweep-meta.tsv" > "$O/state/pr-meta.tsv" 2>/dev/null \
          || : > "$O/state/pr-meta.tsv"
        if [ -n "${SWEEP_LIST:-}" ]; then
          SWEEP_CACHED=1
          echo "[sweep] listing unchanged (304, etag sent) — restored $(printf '%s\n' "$SWEEP_LIST" | awk 'END{print NR+0}') actable row(s) from state/sweep-rows.tsv (age $(( NOW - LAST_FULL ))s <= ${SWEEP_MAX_AGE}s); per-PR reads run on them; next unconditional sweep in <=$(( SWEEP_MAX_AGE - (NOW - LAST_FULL) ))s" >> "$LOG"
        else
          # ⛔ AN EMPTY ACTABLE SET IS NOT A CORRUPT FILE (#2640 review, P2). `printf` writes a 1-byte
          # file for a 200 that listed zero in-scope PRs, so `-s` passes and the parse yields zero
          # rows — on the HEALTHIEST state (backlog drained, or nothing matching SCOPE/SEL). Naming
          # corruption there would cry "CANNOT MERGE" every 304 cycle for the life of the box, so both
          # readings are stated and neither is asserted.
          SWEEP_CACHE_NOTE="the cached listing holds ZERO actable rows (state/sweep-rows.tsv: the backlog is drained or scope-filtered, or the file was truncated)"
          echo "[sweep] 304 and state/sweep-rows.tsv holds ZERO actable rows — nothing to act on this cycle. That is the drained/scope-filtered state OR a truncated cache; both are named here rather than one being asserted. (Not an error by itself: the next 200 rewrites it.)" >> "$LOG"
        fi
      else
        SWEEP_CACHE_NOTE="state/sweep-rows.tsv is missing/empty (a 304 vouches for a listing this box never cached)"
        # ⛔ DROP THE VALIDATOR ON THE NO-CACHE PATH (#2640 review, P2). Leaving it meant every
        # following cycle kept sending If-None-Match, kept getting 304, and kept having no cache —
        # BLIND for up to SWEEP_MAX_AGE (~10 min, tens of cycles) with a log that said "once". This
        # state is reachable on EVERY cell at the first cycle after an upgrade (the ETag survives it,
        # the rows file does not), so it is the common case, not a corner. Without the ETag the next
        # cycle sends no conditional header and gets a 200.
        rm -f "$O/state/sweep-etag" 2>/dev/null || true
        echo "[sweep] ⛔ 304 with NO CACHE — state/sweep-rows.tsv is missing/empty, so this cycle has no actable rows; the ETag has been DROPPED so the next cycle fetches unconditionally. Nothing is acted on, and the reason is written per PR." >> "$LOG"
      fi
    elif [ "$SWEEP_RC" -ne 0 ]; then
      SWEEP_KIND="$(sweep_fail_kind "${SWEEP_RAW:-}" "$SWEEP_ERR")"
      # ⛔ THE CACHE IS **NOT** SERVED HERE, DELIBERATELY. A failed listing is not an assertion that
      # anything is unchanged, so acting on the last cached rows would be acting on a read the server
      # never confirmed this cycle. The failure is named instead, and the row reason carries it.
      SWEEP_CACHE_NOTE="the PR listing FAILED ($SWEEP_KIND) — the cached rows were NOT used, so no PR was read this cycle"
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
      rm -f "$O/state/sweep-defer-until"
      # ⛔ THREE COLUMNS STAY THE CONTRACT (every reader below, and the sweep-quota suite, splits on
      # SWEEP_LIST's `pr \t branch \t draft`). The listing now also carries each PR's `created_at`
      # and head sha — the SAME request, no extra point — and those two are projected into their own
      # state file for the selection ORDER (oldest-first). Writing them into SWEEP_LIST would break
      # every `read -r PR BR DRAFT` consumer, so the projection, not the request, is what splits.
      SWEEP_LIST="$(printf '%s\n' "${SWEEP_RAW:-}" | awk -F"$(printf '\t')" 'NF>=3 && $1 ~ /^[0-9]+$/ {print $1"\t"$2"\t"$3}')"
      printf '%s\n' "${SWEEP_RAW:-}" | awk -F"$(printf '\t')" 'NF>=5 && $1 ~ /^[0-9]+$/ {print $1"\t"$4}' > "$O/state/pr-meta.tsv" 2>/dev/null \
        || : > "$O/state/pr-meta.tsv"
      # ⛔ PERSIST THE ACTABLE ROWS IN THE SAME BREATH AS THE VALIDATOR (#2601). The ETag is stored so
      # the NEXT cycle can ask "unchanged?", and that question is worthless if the box cannot answer
      # what it is unchanged FROM. Written after the projections so a partial write can never be newer
      # than the ETag that vouches for it: `sweep-rows.tsv` (3 columns, the actable set) and
      # `sweep-meta.tsv` (pr, created_at — what pr-meta.tsv is projected from on a restore).
      printf '%s\n' "${SWEEP_LIST:-}" > "$O/state/sweep-rows.tsv" 2>/dev/null || : > "$O/state/sweep-rows.tsv"
      printf '%s\n' "${SWEEP_RAW:-}" | awk -F"$(printf '\t')" 'NF>=5 && $1 ~ /^[0-9]+$/ {print $1"\t"$4}' > "$O/state/sweep-meta.tsv" 2>/dev/null \
        || : > "$O/state/sweep-meta.tsv"
      # ⛔ THE VALIDATOR IS WRITTEN **AFTER** THE ROWS IT VOUCHES FOR (#2640 review, P2). Before this,
      # a teardown between the two writes left a NEW ETag beside the OLD rows and an advanced stamp,
      # so the next cycle sent `If-None-Match: <new>` for up to SWEEP_MAX_AGE and answered the 304 with
      # rows the server never confirmed — the exact "act on an unconfirmed read" the failure and
      # deferral arms refuse. A teardown here at worst leaves an OLD ETag beside NEW rows: the next
      # conditional request then comes back 200 and rewrites both, which is harmless.
      [ -n "$SWEEP_ETAG_NEW" ] && printf '%s\n' "$SWEEP_ETAG_NEW" > "$O/state/sweep-etag"
      printf '%s\n' "$NOW" > "$O/state/sweep-stamp"
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
    # ⛔ CLAIM_REPO IS STILL SET EXPLICITLY HERE (agent-infra#1996). launchd starts the job at cwd `/`
    # and macOS DENIES the read of it, so a relative registry resolves against a cwd that cannot even
    # be read: every git call inside claims.sh then fails, and the snapshot came back empty with live
    # claims on origin — measured: 3 claims on origin, 0 snapshot lines. Setting it explicitly also
    # means the sweep does not depend on $REPO being exported in this shell. The `.` DEFAULT still
    # exists in claims.sh for the workers that `cd "$REPO"` first; what changed is that the
    # controller no longer relies on it.
    CLAIM_REPO="$REPO"
    # ⛔ ITS FAILURE REASON GOES TO $LOG, not to stderr. This job runs in a DETACHED tmux pane (see
    # launchd-controller.sh), so anything on stderr reaches no file at all: a registry refresh that
    # failed for ever was silent, and the sweep then decided from a frozen snapshot — expired leases
    # read free (spawn -> CAS-refusal churn) and live ones read held (the fleet refuses work) with
    # nothing in the operator's only surface saying why. Same idiom as `claim_prune` below.
    claim_snapshot "$O/state/claims-snapshot" 2>>"$LOG"
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
  # ── THE SWEEP'S PER-CYCLE WINDOW (agent-infra#2601) ────────────────────────────────────────────
  # ⛔ A FULL SWEEP OF THIS BOX'S BACKLOG DOES NOT FIT IN ONE CYCLE, AND THAT IS WHY NOTHING ACTED.
  # Each row costs at least two `gh pr view` calls (state, then headRefOid) plus whatever its class
  # needs; measured 2026-10-23, the controller relaunches roughly every 12-45s while a 70-row sweep
  # costs minutes, so the loop was torn down mid-sweep on every cycle that had rows at all — and
  # `prdisp.tsv`/`prclass.tsv`/the `[pr]` summary never saw a completed pass (measured: 0 `act` rows
  # and 0 `[pr] … acted` lines across 555 cycles). The arms are at the END of the loop, so a sweep
  # that cannot finish cannot spawn, merge or review anything — ever.
  # A rotating window makes progress bounded instead of all-or-nothing: K rows per cycle, resuming
  # where the last cycle stopped, so every swept PR is visited within ceil(N/K) cycles and EVERY
  # cycle's pass COMPLETES. K is a tunable (`SWEEP_ROWS_PER_CYCLE`), bounded like every other one.
  # ⛔ ROWS OUTSIDE THE WINDOW ARE NOT SILENT AND ARE NOT "UNSWEPT": the parent names each one with
  # the window it fell outside of, below. A bounded pass that says what it skipped is honest; an
  # unbounded pass that never finishes is not.
  # [sweep-window:begin] (extracted and DRIVEN by pr-path-reads.test.sh — keep the markers)
  SWEEP_WINDOW_PR=""
  SWEEP_WIN_NOTE=""
  # ⛔ `SEL_WINDOW` IS PER-CYCLE STATE AND MUST BE RESET LIKE THE REST OF IT (#2640 review, P1).
  # This block runs inside `while true`, so an un-reset value carries last cycle's rows into a cycle
  # that read NOTHING: on a deferral, a failed listing, or a cache-less 304, `SEL_N` is 0, the window
  # is never recomputed, and `${SEL_WINDOW:-$SEL_ROWS}` would then hand the sweep loop the PREVIOUS
  # cycle's rows — `gh pr view`/`gh pr ready`/merge arms firing on a listing this cycle never read,
  # which is exactly what the deferral and failure arms refuse. Measured shape: the arms would act on
  # a read the server never confirmed, which is the one direction this file must never take.
  SEL_WINDOW=""
  SEL_N=0
  [ -n "${SEL_ROWS:-}" ] && SEL_N="$(printf '%s\n' "$SEL_ROWS" | awk 'NF{n++} END{print n+0}')"
  is_limit "${SWEEP_ROWS_PER_CYCLE:-}" || SWEEP_ROWS_PER_CYCLE=8
  [ "${SWEEP_ROWS_PER_CYCLE:-0}" -ge 1 ] || SWEEP_ROWS_PER_CYCLE=8
  if [ "$SEL_N" -gt 0 ]; then
    SEL_CUR="$(cat "$O/state/sweep-cursor" 2>/dev/null || true)"
    is_num "${SEL_CUR:-}" || SEL_CUR=0
    [ "${#SEL_CUR}" -le 10 ] || SEL_CUR=0
    # Clamp on READ: a corrupt or hand-edited cursor must rotate from the top, never index past the set.
    [ "$SEL_CUR" -ge "$SEL_N" ] && SEL_CUR=0
    if [ "$SEL_N" -le "$SWEEP_ROWS_PER_CYCLE" ]; then
      # The whole set fits: no rotation needed, and the cursor stays where it is (leaving a stale
      # cursor here would skip rows the moment the backlog grew past K again).
      SEL_WINDOW="$SEL_ROWS"; SEL_CUR=0
    else
      SEL_WINDOW="$(printf '%s\n' "$SEL_ROWS" | awk -F"$(printf '\t')" -v k="$SWEEP_ROWS_PER_CYCLE" -v c="$SEL_CUR" \
        'NF{n++; r[n]=$0} END{ if(n==0) exit; for(i=0;i<k && i<n;i++) print r[((c+i)%n)+1] }')"
    fi
    # ⛔ A WRAPPING WINDOW MUST NOT PRINT A RANGE THAT DOES NOT EXIST (#2640 review, P2). With
    # N=20, K=8 and cursor 16 the covered rows are 17-20 and 1-4, but the naive end printed
    # `window=17-24 of 20` — the one sentence an operator gets, naming row 24 of a 20-row set.
    _wcount="$(printf '%s\n' "$SEL_WINDOW" | awk 'NF{n++} END{print n+0}')"
    if [ $(( SEL_CUR + _wcount )) -gt "$SEL_N" ]; then
      SWEEP_WIN_NOTE="window=$(( SEL_CUR + 1 ))-${SEL_N} then 1-$(( SEL_CUR + _wcount - SEL_N )) of $SEL_N (K=${SWEEP_ROWS_PER_CYCLE}/cycle, rotating; wrapped)"
    else
      SWEEP_WIN_NOTE="window=$(( SEL_CUR + 1 ))-$(( SEL_CUR + _wcount )) of $SEL_N (K=${SWEEP_ROWS_PER_CYCLE}/cycle, rotating)"
    fi
    SWEEP_WINDOW_PR="$(printf '%s\n' "$SEL_WINDOW" | awk -F"$(printf '\t')" 'NF && $1 ~ /^[0-9]+$/ {printf " %s", $1}') "
    # ⛔ THE CURSOR IS NOT ADVANCED HERE (#2640 review, P1). It is advanced AFTER the pass, by the
    # number of window rows that actually produced a disposition — see the block below the sweep
    # loop. Advancing by K up front assumed the whole window was read, and the fix's own premise is
    # that a cycle can be torn down mid-pass: with M of K rows read, the tail of every window was
    # stepped over, and because the start positions then live in one residue class mod gcd(K,N), a
    # whole class of PRs was NEVER read (`K=8, N=70, M=1` → 35 of 70, ever) while each of them was
    # told "it is read within N cycles". Resuming at the unfinished row is the only honest step.
    printf '%s\n' "$SEL_CUR" > "$O/state/sweep-cursor" 2>/dev/null || true
    echo "[sweep] per-cycle window: $SWEEP_WIN_NOTE — every row is visited within $(( (SEL_N + SWEEP_ROWS_PER_CYCLE - 1) / SWEEP_ROWS_PER_CYCLE )) cycle(s)" >> "$LOG"
  fi
  # [sweep-window:end]
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
  prune_orphan_markers "$OPEN_ROWS" "${_nrows:-0}"
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
  # ⛔ THE TRANSPORT BREAKER IS TRUNCATED HERE, WITH THE LEDGER, AND FOR THE SAME REASON (agent-infra
  # #2719). It records "the gh transport was down for THIS sweep", which is a fact about a few seconds
  # — so it must die with the cycle that observed it. A breaker that outlived its cycle would be a
  # stale flag: the next cycle would name every NOCHECKS PR from an outage that had already ended, and
  # (worse) would skip the re-read that recovers the 82% of the class a retry fixes.
  : > "$O/state/nochk-breaker" 2>/dev/null || true
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


  # ── SPAWN REFUSALS: A PER-CYCLE MEASUREMENT, NOT A LOG LINE (measured 2026-10-22) ───────────
  # The controller can only advance the fleet through the launcher. When the launcher refuses, every
  # spawn site below records a per-PR `wait` — and the cycle's own `[pr]`/`[dispatch]` line reads
  # `N acted, M named wait(s)`, which is indistinguishable from a healthy busy cycle. MEASURED: 1,562
  # refusals in one log (`cmux layout apply failed: … database or disk is full` — the registry volume
  # at 100%) while `lanes=0 workers=5` printed every cycle for six hours and not one PR landed. The
  # refusal record is written by the launcher (`wt_refusal_record`, worker-terminal.sh) and TRUNCATED
  # here, before the sweep, so cycle N can never read cycle N-1's refusals as its own.
  # ⛔ ONE RESOLVER, NOT TWO. The path comes from the launcher's OWN `wt_refused_file` when the module
  # provides it (a stale `worker-terminal.sh` must not stop the controller — the guard above does not
  # require this function, and a mixed deploy would otherwise refuse to run): with two independent
  # spellings, a `WT_DIR` test seam made the writer record one file while this reader watched another,
  # and the measurement would read 0 forever (the single-source class).
  # [spawnref:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
  SPAWNREF=""; SPAWNREF_OK=1; SPAWNREF_WHY_BAD=""
  if command -v wt_refused_file >/dev/null 2>&1; then
    SPAWNREF="$(wt_refused_file)" 2>/dev/null
  else
    # ⛔ A STALE LAUNCHER MODULE IS NOT A MEASUREMENT OF ZERO. The guard at the top of this file does
    # not require `wt_refused_file` (a mixed deploy must not stop the controller), so this state is
    # reachable — and with no writer, "0 refusals" would be a claim about a record nothing fills.
    SPAWNREF="$O/state/spawn-refused.tsv"
    SPAWNREF_OK=0
    SPAWNREF_WHY_BAD="the launcher module predates wt_refused_file, so nothing records refusals"
  fi
  if [ "${SPAWNREF_OK:-1}" = "1" ]; then
    # ⛔ A TRUNCATE IS NOT A WRITE PROBE (review, cycle 2). `: > file` is allocation-free and SUCCEEDS
    # on a full filesystem — the exact condition that causes refusals. So the probe is a SENTINEL ROW
    # that must actually be written; its absence is what turns "0 refusals" into "UNMEASURED".
    # ⛔ THE PROBE MUST BE THE SIZE OF A REAL ROW (review, cycle 3). A 13-byte probe passes on a volume
    # with 13–250 bytes free and then every refusal row (up to ~250 B) is dropped: OK=1, N=0, no suffix
    # — a MEASURED zero, which is the false PASS the probe exists to prevent. Pad it to the row bound.
    _pr_probe="$(printf '%*s' 260 '' | tr ' ' x)"
    if : > "$SPAWNREF" 2>/dev/null && printf '#\t%s\n' "$_pr_probe" >> "$SPAWNREF" 2>/dev/null; then :; else
      SPAWNREF=/dev/null; SPAWNREF_OK=0
      SPAWNREF_WHY_BAD="state/ is not writable (the probe row could not be written)"
    fi
  fi
  SPAWNREF_BASE=0
  if [ -s "${SPAWNREF:-/nonexistent}" ]; then
    SPAWNREF_BASE="$(awk 'END{print NR+0}' "$SPAWNREF" 2>/dev/null)"
  fi
  is_num "${SPAWNREF_BASE:-}" || SPAWNREF_BASE=0
  # [spawnref:end]

  printf '%s\n' "${SEL_WINDOW:-$SEL_ROWS}" |
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
    # ⛔ AND ITS STALE-EVIDENCE MARKER GOES WITH IT (review round 1, P2 — agent-infra#2132): this
    # `continue` runs BEFORE every other cleanup path, so a `needsreview-<PR>-<head>` marker written
    # while the PR was open would outlive it and be counted forever by report.sh. The count is only
    # worth publishing if it can return to zero. Kept on ONE line because selftest.sh pins this
    # exact `case` form ("sweep skips CLOSED as well as MERGED").
    # ⛔ TIDY THE STALE-EVIDENCE, FINDINGS AND SPEND MARKERS (review rounds 5-7). The spend sweep is
    # local dispatch bookkeeping; the findings and stale-evidence markers are evidence state and die
    # with the PR. All three on merge/close, because a PR that terminates is never visited again.
    # ⛔ AND THE RAIL'S OWN RECORDS GO WITH IT (main's arm, kept in the SAME case — two consecutive
    # `MERGED|CLOSED)` arms would make the second unreachable behind the first's `continue`, so the
    # rail refusal/red-fix cleanup would silently never run).
    case "${PR_ST:-}" in MERGED|CLOSED)
      rm -f "$O/state/needsreview-$PR-"* "$O/state/fixspend-$PR-"* "$O/state/needsfix-$PR-"* "$O/state/reviewcount-$PR" "$O/state/reviewdisp-$PR" "$O/state/reviewathead-$PR" 2>/dev/null || true
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
            echo "#$PR red-fixer bailed at head=$HEAD_N (another box holds the claim, or the CI-queue gate deferred the push) — attempt refunded to $RF_N (fix-$PR)" >>"$LOG"
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
          # ⛔ THE MARKER REFUNDS EVERY ROLE THAT BOOKED AGAINST IT, not just this one (2026-10-22).
          # `fixgate-<PR>-<HEAD>` says "a load/disk gate refused the agent at this head" — a fact about
          # the HEAD, not about this role. This block glob-deletes it for its own counter, and the PR
          # sickness queue books the same kind of head-keyed attempt; deleting the marker here made
          # that role's refund INERT for exactly the PRs both roles target (a rail-refused red tree),
          # so two load refusals still parked the PR "needs a human" with no agent ever run. The
          # refund is one call, and the module owns it (absent module = nothing to refund).
          declare -f psick_refund_head >/dev/null 2>&1 && psick_refund_head "$O/state" "$PR" "$HEAD_N" >>"$LOG" 2>&1
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
          elif pr_owner_live "$PR" "$HEAD_N" "${BR:-}"; then
            # (2) EXACTLY ONE LIVE FIXER PER PR. The key is the PR number in the session/lock name, so a
            # second refusal while a fixer works spawns NOTHING (a second lane is how two workers push
            # to one branch).
            echo "#$PR RED TREE at head=$HEAD_N — a worker already owns this PR (fix-$PR/merge-$PR live, or the cross-box claim holds it), NOT spawning a second (attempt $RF_N/${MAX_RED_FIX_TRIES:-2} spent). REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
            disp "$PR" "$HEAD_N" "RED-TREE" wait "a worker already owns this PR — the rail refusal stands at this head"
          elif [ "$(wt_count fix-)" -lt "${MAX_RED_FIX:-4}" ] && can_spawn; then
            # (1) THE SPAWN. Through the launcher (`wt_spawn`), so on a cell the red-fixer gets the
            # surface that box actually has — a daemon-owned DURABLE TERMINAL where cmux answers, tmux
            # with an explicit HOME+keys.env contract where it does not (the `~21 log lines` death was
            # the missing environment, and a dead red-fixer is indistinguishable from one that found
            # nothing to fix). Args go in a FILE so no PR-derived value reaches `sh -c`, and
            # `fix-one.sh` — which materialises the branch's OWN worktree from origin, captures the
            # failing checks and their logs, and re-runs the merge chain (which re-rails) when it
            # pushes. A red-fixer never runs in the hub checkout: the fixer script cd's into the
            # worktree and its prompt says so.
            #
            # (6) THE MODEL/PROVIDER IS EXPLICIT AND NOT AMBIENT. The one gated `pi` invocation
            # (`spawn-gate.sh`'s run_agent) names `--provider "$lane_provider" --model "$lane_model"`,
            # resolved from `${PI_LANE_PROVIDER:-deepseek}` / `${PI_LANE_MODEL:-deepseek-flash}` and
            # logged as `[agent] provider=… model=…` before the spawn (#2208). ⛔ The image's OPENAI_API_KEY is unset HERE because it otherwise shadows provider
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
            echo "#$PR RED TREE but NO red-fixer slot (fix lanes=$(wt_count fix-)/${MAX_RED_FIX:-4}, $(spawn_gate_tok)) — attempt $RF_N/${MAX_RED_FIX_TRIES:-2} NOT consumed, no fix-$PR. REFUSAL: ${RF_REASON:-<none recorded>}" >>"$LOG"
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
    # ⛔ THE CLASSIFIER IS A FILE, NOT A HEREDOC (agent-infra#2719). It used to be an inline `python3 -c`
    # here, which meant the ONLY implementation of "what class is this check surface" was a string no
    # other caller could run — and the NOCHECKS arm below has to answer that SAME question on a re-read.
    # Two copies of these rules is exactly how the harness and the merge rail disagreed before (#1714),
    # so the arm calls this file instead of a lookalike. `$_CK_PY` is resolved once at startup (see
    # there) and is an ABSOLUTE path, so this pipeline's subshell inherits it.
    V="$(gh pr checks "$PR" --repo "$OR" --json name,state,workflow 2>/dev/null | REQ="$REQ" REVIEW_GATE="$REVIEW_GATE" python3 "${_CK_PY:-/nonexistent/check-class.py}" 2>/dev/null)"
    # ── THE NOCHECKS CLASS GETS AN ARM (agent-infra#2719) ─────────────────────────────────────────
    # ⛔ WHAT THIS REPLACES. `NOCHECKS` used to mean THREE different events at once — the read failed,
    # no run had registered yet, and no run will ever exist — because the pipeline above discards the
    # read's stderr. The sweep then printed "no acting arm for class 'NOCHECKS' — nothing spawned
    # (re-read next cycle)" and re-read the same PR for ever. MEASURED over every occurrence in this
    # controller's own log (77 occurrences / 42 cycles / 47 PRs, 2026-10-20 → 10-24), classified
    # against the check-runs AUTHORITY at the head that existed then: 63 (82%) had a surface that
    # ALREADY EXISTED and the read failed; 6 (8%) had no check-run and no run at all; 4 (5%) were a
    # head whose surface arrived minutes later; 4 (5%) unresolvable.
    # ⛔ SO THE ARM'S FIRST JOB IS TO RE-ASK, NOT TO RE-READ NEXT CYCLE. A transient transport failure
    # is retried INSIDE this cycle (two attempts, short backoff) — that alone turns most of the class
    # back into a real classification at no cost. Only when the answer is still empty does it consult
    # the authority (which distinguishes "the surface is absent" from "the read is blind"), and only
    # when the surface is genuinely absent does it name a cause.
    # ⛔ IT NEVER MERGES AND NEVER SPAWNS. Every verdict leaves the PR exactly as unmergeable as it
    # was: an empty surface is not a green and not a pending, so the merge arm must not see one. A
    # RECOVERED class is handed to the ORDINARY arms below, so it is treated like any other PR.
    # ⛔ AND IT NEVER STARTS A RUN BEHIND THE REPO'S BACK. The sanctioned repair for a head with no run
    # is the repo's OWN (tortoise: the scheduled `ci-check-repair` workflow, which re-runs a held run or
    # close/reopens the PR); the arm names that owner and counts the wait, then emits a TERMINAL verdict
    # at the bound. A named dead end is the deliverable; an unbounded re-read is the bug.
    # [nochk-begin] (extracted and DRIVEN by nochk-resolve.test.sh — keep the markers)
    if [ "${V:-}" = "NOCHECKS" ]; then
      # ⛔ THE RESOLVER'S OWN STDERR GOES TO THE LOG, NOT TO /dev/null (review P2, agent-infra#2719):
      # a post that FAILED writes its reason there, and discarding it made the ledger's `[post=…]` the
      # only trace of a verdict no human could see.
      _NCHK="$(REQ="$REQ" REVIEW_GATE="$REVIEW_GATE" python3 "${_NCHK_PY:-/nonexistent/nochk-resolve.py}" \
                --repo "$OR" --pr "$PR" --head "${HEAD_N:-}" --state-dir "$O/state" \
                --repo-dir "${REPO:-}" --breaker "$O/state/nochk-breaker" --post 2>>"$LOG")"
      _NTOK="$(printf '%s' "$_NCHK" | cut -f1)"
      _NDET="$(printf '%s' "$_NCHK" | cut -f2-)"
      case "$_NTOK" in
        RECOVERED)
          # ⛔ A RECOVERY THAT CANNOT BE GRADED IS A READ FAILURE, NEVER A VERDICT (review P1,
          # agent-infra#2719). `classify()` answered `NOCHECKS` for four different failures — the
          # classifier file absent (the `$O`-one-file-behind deploy state), an exception, a non-zero rc,
          # no output — and the first version of this arm turned that non-answer into a TERMINAL verdict
          # on cycle 1: no bound, no post, and a false cause ("the repo declares no required check" —
          # with REQ provably non-empty, or the sweep would have stopped long before this arm). So a
          # failure token or a bare `NOCHECKS` leaves the PR IN the class, NAMED, and retried next cycle.
          case "${_NDET:-}" in
            NOCHECKS|UNCLASSIFIABLE:*)
              V="NOCHECKS:READ-FAILED:the re-read answered but could not be graded (${_NDET:-<no label>})"
              echo "#$PR NOCHECKS: the re-read answered but the classifier could not grade it — ${_NDET:-<no label>}" >>"$LOG" ;;
            *)
              V="${_NDET}"
              echo "#$PR NOCHECKS RESOLVED -> '${_NDET}' on a re-read this cycle (the surface was there; the first read failed)" >>"$LOG" ;;
          esac ;;
        UNRESOLVABLE)
          # Terminal. The resolver posted it on the PR (once per head); the arm below parks the head.
          V="NOCHECKS:UNRESOLVABLE:${_NDET}" ;;
        WAIT|DEFERRED-REPAIR|READ-FAILED|BUDGET)
          V="NOCHECKS:${_NTOK}:${_NDET}" ;;
        "")
          # NO VERDICT AT ALL — the arm itself could not run (a missing file, a python error). That is
          # a harness defect, not a state of the PR, and it must be NAMED rather than folded back into
          # the silent `NOCHECKS` this change exists to remove.
          V="NOCHECKS:READ-FAILED:the arm produced no verdict (nochk-resolve.py missing or failed — see $_NCHK_PY)" ;;
        *)
          V="NOCHECKS:UNKNOWN:${_NTOK} ${_NDET}" ;;
      esac
    fi
    # [nochk-end]
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
          elif pr_owner_live "$PR" "${HEAD_N:-}" "${BR:-}"; then
            : # a worker is already rebasing it
            disp "$PR" "${HEAD_N:-}" CONFLICTED wait "a worker already owns this PR"
          elif [ "$(wt_count fix-)" -lt "$MF" ] && can_spawn; then
            # ⛔ NO CI-QUEUE GATE ON THIS SPAWN, AND THIS IS THE ARM THAT PROVES THE RULE (#2927).
            # A CONFLICTED fixer is REPAIR: the PR and its head already exist. ⛔ Not "and its CI pass
            # has already been paid for" — a repair push DOES start a fresh run; the basis is #2927's
            # decision plus the measurement below. Measured 2026-10-27 on cell 4, the queue gate that used to wrap
            # this spawn deferred 41 consecutive repair dispatches against a queue that belonged to
            # GitHub-HOSTED concurrency, while 8 self-hosted runners and ~11 lane slots sat idle —
            # and it reported `ci-queue(deep(…))` as the binding reason for a box whose lanes were
            # free. The REAL bounds on this spawn are the two conditions above it (the `$MF` fix-lane
            # ceiling, the cross-box claim and `can_spawn`'s load/disk/memory gate) plus
            # `fix-one.sh`'s own spawn gate. `ci-queue.sh`'s header states the class rule: only work
            # that ADDS a new CI run is queue-gated. Do not re-nest it here.
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
            echo "#$PR CONFLICTING but NO fixer slot (fix lanes=$(wt_count fix-)/$MF, $(spawn_gate_tok))" >>"$LOG"
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
        # ⛔ ONLY WHERE GREEN MEANS THE EVIDENCE EXISTS (review round 2, P2 — agent-infra#2132). On a
        # RAIL repo `ai-review-gate` is not in `$REQ`, so V=GREEN means "the required checks pass",
        # NOT "a reviewer recorded something" — the exact premise agent-infra#1825 exists to refute.
        # Sweeping there deleted the marker `merge-one.sh`'s rail fall-through had just written, so
        # the stale-evidence count was structurally 0 on agent-infra itself (the repo this harness
        # ships to). The MERGED|CLOSED sweep and `review_state_clear` still give the "can return to
        # zero" property on a rail repo, so nothing leaks.
        # ⛔ THE SPEND RECORD IS A LOCAL DISPATCH FACT, SO IT SWEEPS FOR EVERY AUTHORITY (review
        # round 5, residual 2). ⛔ BUT THE EVIDENCE MARKER MUST NOT (review round 5, P1 — this was a
        # REGRESSION): sweeping `needsreview-*` unconditionally here re-introduced the round-2 defect,
        # because on a RAIL repo V=GREEN means "the required checks pass", NOT "a reviewer recorded
        # something" (#1825). That deleted the marker the rail fall-through had just written and made
        # the stale-evidence count structurally 0 on agent-infra itself. Two separate lines, and the
        # authority test stays the ONLY needsreview sweep on this arm.
        rm -f "$O/state/fixspend-$PR-"* 2>/dev/null || true
        [ "$MERGE_AUTHORITY" = "gate" ] && rm -f "$O/state/needsreview-$PR-"* 2>/dev/null || true
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
          if pr_owner_live "$PR" "${HEAD_N:-}" "${BR:-}"; then
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
            echo "#$PR GREEN but NO merge slot (merge lanes=$(wt_count merge-)/$MR, $(spawn_gate_tok))" >>"$LOG"
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
          # ⛔ ONE STATE, ONE REMEDY (agent-infra#2132). The gate being red is not a diagnosis: a head
          # with FINDINGS needs a fixer, and a head with no findings needs another REVIEW. They were the
          # same log line and the same dispatch before this, so a stale-evidence PR was handed to a
          # fixer whose push invalidated the signed review again, burning one attempt per cycle until
          # the cap parked an issue nobody owned. The classifier is the ONLY input to both the log line
          # and the dispatch decision, so the two cannot disagree.
          # ⛔ AND THIS ARM DOES NOT WRITE THE STALE-EVIDENCE STATE (review round 3, P2). It cannot
          # establish the property the marker names: "no head-bound clean evidence at THIS head" is
          # knowable only from the review store, which merge-one.sh consults and this controller does
          # not. Writing it here published the state for every red gate with no findings marker — a
          # brand-new PR that had simply not been reviewed, and (measured by review) a head whose
          # SIGNED MARKER HAD JUST VERIFIED but whose gate never went green, so the log told the
          # operator to re-record evidence that already existed. merge-one.sh is the single writer of
          # `needsreview-*`; this arm only READS it, and the log line says only what is known here.
          _rgs="$(review_gate_state "$PR" "${HEAD_N:-}")"
          if [ "$_rgs" = "NEEDS-FIX" ]; then
            echo "#$PR NEEDS-FIX (reviewer findings at head=${HEAD_N:-?}) — a fixer is the remedy" >>"$LOG"
          else
            echo "#$PR NEEDS-REVIEW (no findings marker at head=${HEAD_N:-?}) — the remedy is another review, NOT a fixer" >>"$LOG"
          fi
          # The claim file is written by merge-one.sh itself, so it also covers the chain-<N>
          # path (which invokes merge-one.sh directly and whose session name is invisible here).
          if pr_owner_live "$PR" "${HEAD_N:-}" "${BR:-}"; then
            : # this PR already has a worker in flight
            disp "$PR" "${HEAD_N:-}" "$V" wait "a worker already owns this PR"
          else
            FIXN="$O/state/fixcount-$PR"; NF="$(cat "$FIXN" 2>/dev/null || echo 0)"
            is_num "$NF" || NF=0
            # a reviewer already reported real issues AT THIS HEAD -> fix them and re-run the chain.
            # otherwise the gate is probably just missing evidence -> re-record (fresh review).
            # ⛔ NO CI-QUEUE GATE ON THIS SPAWN EITHER (#2927): a review-findings fixer is REPAIR (its
            # head already exists), so the class rule in `ci-queue.sh`'s header excludes it — same
            # measurement, same 41 skips, same idle fleet as the CONFLICTED arm above. ⛔ Not because its
            # "pass is already spent" (a repair push does start a run): the basis is the decision plus
            # the wrong-number measurement. What stays: the eligibility predicate is still HOISTED into
            # `_fix_eligible`, because the arms BELOW it (the attempt cap / park arm and the re-record
            # chain) must ask exactly the question the spawn arm asks — capacity, findings and the
            # attempt budget — and must not drift from it.
            _fix_eligible=0
            if [ -n "${HEAD_N:-}" ] && [ "$_rgs" = "NEEDS-FIX" ] \
               && [ "$NF" -lt "${MAX_FIX_TRIES:-3}" ] \
               && can_spawn \
               && [ "$(wt_count fix-)" -lt "$MF" ]; then
              _fix_eligible=1
            fi
            if [ "$_fix_eligible" = "1" ]; then
              # Spawn FIRST, bookkeep only on success: recording the attempt before the spawn
              # means a killed/failed spawn consumes one of MAX_FIX_TRIES and deletes the
              # findings marker, so no fixer ever runs and the findings are lost.
              # Args travel in a file, not interpolated into the tmux command string, so no
              # PR-derived value can reach `sh -c`. Only $O (validated at startup) and the
              # numeric $PR are embedded.
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              # ⛔ THE SPEND RECORD IS WRITTEN BEFORE THE SPAWN (review round 5, residual 1).
              # `fix-one.sh` starts concurrently inside the tmux session and can write `fixbail-*`
              # before this line returns — and `refund_bailed_fixer` requires this file to restore a
              # findings marker, so a post-spawn write raced a bail into "no spend" (fail-closed: the
              # marker is withheld and one extra review is paid, never a fixer authorised without
              # findings). Writing it first closes the window; the spawn-failure arm removes it again.
              # It is the counterpart `refund_bailed_fixer … 1` requires: this is the ONLY site that
              # consumes a findings marker, so it is the only site that may authorise a restore.
              : > "$O/state/fixspend-$PR-$HEAD_N"
              if wt_spawn "fix-$PR" "$SPAWN_CWD" "bash '$O/fix-one.sh' --argv '$O/state/argv-$PR'"; then
                echo $((NF + 1)) > "$FIXN"; rm -f "$O/state/needsfix-$PR-$HEAD_N"
                echo "#$PR fixer attempt $((NF + 1))" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" act "review-gate fixer spawned (attempt $((NF + 1)))"
              else
                rm -f "$O/state/fixspend-$PR-$HEAD_N"
                echo "#$PR fixer spawn FAILED (attempt not consumed, marker kept)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "review-gate fixer spawn FAILED (attempt not consumed)"
              fi
            elif [ "$NF" -ge "${MAX_FIX_TRIES:-3}" ] && [ "$_rgs" = "NEEDS-FIX" ]; then
              # Terminal state. Without this the cap just falls through to the re-record branch
              # every cycle: an unfixable PR would burn a full fresh-context review forever.
              park_ctrl "$PR" "${HEAD_N:-}" "still needs fixes after $NF attempts at head=${HEAD_N:-?} (MAX_FIX_TRIES=$MAX_FIX_TRIES) -- a human must decide; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
              echo "#$PR PARKED after $NF fixes at head=${HEAD_N:-?} — needs a human" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "parked: still needs fixes after $NF attempts — needs a human"
            # ⛔ A HEAD WITH FINDINGS NEVER REACHES THE REVIEW KEY (review round 5 of #2653, P1). The
            # chain falls through here whenever `_fix_eligible` is 0 — including "the FIXER ceiling is
            # full" — and the review key would then CAP and park that head after MAX_REVIEW_TRIES
            # re-records with a reason claiming "the reviewer produced no usable verdict … a fixer has no
            # findings", when `state/needsfix-<PR>-<head>` exists ON DISK (it is what made `_rgs`
            # NEEDS-FIX this cycle). That parks a PR the fixer could still repair, and sends the operator
            # at the reviewer's budget instead of the fix capacity that actually blocked it.
            # ── THE (PR, HEAD) REVIEW KEY IS CONSULTED BEFORE CAPACITY (agent-infra#2653) ────────
            # ⛔ ORDER IS THE POINT. Capacity is a fact about the BOX; AT-HEAD and CAP are facts about
            # the REVIEW. Testing capacity first reports "review-lane ceiling reached" for a head that
            # should never have been reviewed again at all — the reading an operator gets is then about
            # the machine, and the PR's real state is invisible (the 2026-10-24 stall: eight PRs
            # reported as a capacity problem while four of them were merely un-reviewed).
            # ⛔ AND AN UNREADABLE HEAD IS NOT A KEY (review of #2653, P3). A review is evidence ABOUT A
            # HEAD; spending one on an empty `HEAD_N` (a failed `gh pr view … headRefOid`) records a
            # count under a key nobody can compare, buys up to MAX_REVIEW_TRIES paid reviews, and then
            # parks the PR with a reason claiming the budget when the real cause was an API read.
            elif [ "$_rgs" = "NEEDS-FIX" ]; then
              # Findings at this head, no fixer slot and no spawn gate: name the FIX side, which is what
              # is actually exhausted, and never the review budget.
              echo "#$PR NEEDS-FIX at head=${HEAD_N:-?} but NO fixer slot (fix lanes=$(wt_count fix-)/$MF; try: rm -f a stray $O/state/fixcount-$PR if the attempts were not real, $(spawn_gate_tok)) — a fixer is the remedy, a review is not" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "capacity: fix-lane ceiling $MF reached (findings exist — a fixer is the remedy)"
            elif [ -z "${HEAD_N:-}" ]; then
              echo "#$PR $V but the HEAD is UNREADABLE — no review dispatched (a review is head-scoped evidence; a review spent on an unnamed head cannot be keyed, compared, or recorded, and the budget would be spent against a key that means nothing)" >>"$LOG"
              disp "$PR" - "$V" wait "head unreadable — a review is not spent on a guess (re-read next cycle)"
            elif _rvd="$(review_disp_decide "$PR" "${HEAD_N:-}")"; [ "${_rvd%% *}" = "AT-HEAD" ]; then
              # ⛔ AT-HEAD DOES NOT DISPATCH — AND IT MUST NOT WAIT FOREVER EITHER (review of #2653, P2).
              # Its remedy is a RE-RECORD, which only merge-one.sh's CLEAN path mints, and this branch
              # is what withholds the spawn that would run it. Bounded here, so the state reaches a
              # HUMAN as an action item instead of logging a wait row every cycle for ever.
              # ⛔ A FAILED BUMP IS NAMED, NOT SILENTLY COERCED (review round 3 of #2653, P2): with the
              # counter unwritable the count would restart at 1 every cycle and this state could never
              # escalate — the endless wait it exists to end, wearing a bounded-looking face.
              if ! _ahn="$(review_athead_bump "$PR" "${HEAD_N:-}")"; then
                echo "#$PR REVIEW-AT-HEAD-UNBOUNDED at head=${HEAD_N:-?} — a CLEAN review is recorded here and the gate never went green, and state/reviewathead-$PR CANNOT BE WRITTEN, so this state can no longer escalate to a human (it would log a wait row every cycle for ever). REFUSAL: nothing dispatched; REPAIR: make $O/state writable (rm -rf a stray directory named reviewathead-$PR) and the bound resumes next cycle" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "REVIEW-AT-HEAD-UNBOUNDED: the escalation counter is unwritable — a human must look at this head"
              elif [ "$_ahn" -ge "${MAX_REVIEW_TRIES:-3}" ]; then
                echo "#$PR REVIEW-AT-HEAD-STUCK ${_ahn}/${MAX_REVIEW_TRIES} at head=${HEAD_N:-?} — a CLEAN review is recorded here but the gate never went green, and the controller has no actuator for that: PARKED for a human. The remedy is a RE-RECORD, not a review, and it is one command: record-review.sh $PR ${HEAD_N:-?} clean $OR --evidence comment:<the id of that review comment> --expect-head ${HEAD_N:-?} — ⛔ THE PIN IS PART OF THE REMEDY (#2572, fresh review of PR #2988): this arm fires only when the record IS at this exact head, so the pin is statable and verifies, and WITHOUT it the #2982 carry arm of the recorder may re-bind that verdict to a live head nobody reviewed — the same defect #2572 closes at the two fresh-mint sites, reachable here through the one printed command an operator would run. The gate re-triggers on 'edited'. ⛔ AND THEN LIFT THIS PARK: the park is honoured BEFORE the acting case and the automatic lift only matches RED TREE / rail refusals, so a re-record on its own changes nothing — rm -f $O/state/parked-$PR $O/state/parkreason-$PR $O/state/reviewathead-$PR. ⛔ NO BACKTICKS AND NO APOSTROPHES IN THIS LINE: it is a double-quoted string, so a backticked command is SUBSTITUTED (the command the operator is told to run would be deleted from the log and its output spliced in) — measured on PR #2664 review round 2." >>"$LOG"
                if park_ctrl "$PR" "${HEAD_N:-}" "REVIEW-AT-HEAD-STUCK: a CLEAN review is already recorded at head=${HEAD_N:-?} and the ai-review-gate never went green over it after ${_ahn} cycle(s). No review is dispatched (a second review of an unchanged head is waste) and the controller has no re-record actuator — a human must re-record the existing evidence or re-run the gate. A push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR' '$O/state/reviewathead-$PR'"; then
                  disp "$PR" "${HEAD_N:-}" "$V" wait "parked: REVIEW-AT-HEAD-STUCK ${_ahn}/${MAX_REVIEW_TRIES} — recorded review, red gate, needs a human"
                else
                  echo "#$PR REVIEW-AT-HEAD-STUCK ${_ahn}/${MAX_REVIEW_TRIES} at head=${HEAD_N:-?} — the escalation bound is spent, but the PARK DID NOT LAND (state/parked-$PR is unwritable), so this state is NOT bounded and will re-enter this arm every cycle. REFUSAL: nothing dispatched. REPAIR: make $O/state writable (rm -rf a stray directory named parked-$PR), then re-record the existing evidence" >>"$LOG"
                  disp "$PR" "${HEAD_N:-}" "$V" wait "REVIEW-AT-HEAD-STUCK PARK UNWRITABLE — a human must look at this head"
                fi
              else
                echo "#$PR REVIEW-AT-HEAD at head=${HEAD_N:-?} (refusal ${_ahn}/${MAX_REVIEW_TRIES}) — a CLEAN review is already recorded at this exact head, so NO review is dispatched (a second review of an unchanged head is waste; the gate re-triggers on 'edited', so a RE-RECORD — merge-one.sh's CLEAN path — is the remedy for a red gate over a valid record, never a new review)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "REVIEW-AT-HEAD: a CLEAN review is recorded at this head — no re-review dispatched (the record, not a reviewer, is the missing step)"
              fi
            elif [ "${_rvd%% *}" = "REPORT-ONLY" ]; then
              echo "#$PR $V — NO review re-record dispatched: MAX_REVIEW_TRIES=0 on this box (REPORT-ONLY, the same idiom as MAX_RED_FIX_TRIES=0). Nothing is parked and nothing is spent; this PR keeps its next cycle" >>"$LOG"
              disp "$PR" "${HEAD_N:-}" "$V" wait "report-only box (MAX_REVIEW_TRIES=0) — no review lane dispatched"
            elif [ "${_rvd%% *}" = "CAP" ]; then
              # ⛔ THE MIDDLE FIELD IS THE COUNT (review of #2653, P2): `CAP <n> <max>` — `${_rvd##* }`
              # is the LAST field, i.e. `max`, which only differs from `n` when an operator LOWERS
              # MAX_REVIEW_TRIES — exactly the tuning the park reason invites, and the number the
              # "never a silent stop" line reports would then be the budget instead of the spend.
              _rvn="${_rvd#CAP }"; _rvn="${_rvn%% *}"
              # ⛔ A PARK THAT DID NOT LAND MUST NOT BE REPORTED AS ONE (review round 4 of #2653, P2):
              # the park IS the terminator here, so an unwritable `parked-<PR>` means the PR re-enters
              # this arm every cycle while the log says PARKED — an inert bound with a green face.
              if park_ctrl "$PR" "${HEAD_N:-}" "REVIEW-CAP: ${_rvn}/${MAX_REVIEW_TRIES} review re-records at head=${HEAD_N:-?} — the reviewer never produced a usable verdict at this head, so no signed marker can be minted and a fixer has no findings to act on. Fix the reviewer's budget/cap (REVIEW_TIMEOUT) or its output format; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR' '$O/state/reviewdisp-$PR'"; then
                echo "#$PR REVIEW-CAP ${_rvn}/${MAX_REVIEW_TRIES} at head=${HEAD_N:-?} — review re-records at this head are EXHAUSTED, PARKED (an unfixable head must not loop; a push re-arms it)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "REVIEW-CAP ${_rvn}/${MAX_REVIEW_TRIES} at this head — needs a human (bounded, never a silent stop)"
              else
                echo "#$PR REVIEW-CAP ${_rvn}/${MAX_REVIEW_TRIES} at head=${HEAD_N:-?} — review re-records at this head are EXHAUSTED, but the PARK DID NOT LAND (state/parked-$PR is unwritable), so this head is NOT bounded and will re-enter this arm every cycle. REFUSAL: nothing dispatched. REPAIR: make $O/state writable (rm -rf a stray directory named parked-$PR)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "REVIEW-CAP PARK UNWRITABLE — a human must look at this head"
              fi
            elif [ "$(wt_count review- merge-)" -lt "$MR" ] && can_spawn; then
              # ⛔ THIS SPAWN IS A REVIEW ORDER, AND IT IS NAMED AS ONE (agent-infra#2971). The remedy
              # the NEEDS-REVIEW diagnosis names is a REVIEW, so the worker this arm starts is
              # `review-<PR>` — not `merge-<PR>`. Until this split both arms used the SAME tag, so a
              # pass that dispatched a review read, in the controller's own log, as another MERGE
              # worker: `[spawn] SPAWNED … merge-10213`, `[pr] … spawned=5` (measured 2026-10-28).
              # A reader (and the operator's eye) then cannot tell an ORDER out of the refusal from a
              # re-run of the thing that was refused, which is exactly how the same PR was re-spawned
              # pass after pass. `merge-<PR>` now means ONE thing: the GREEN arm's landing worker.
              # ⛔ AND THE BUDGET IS THE MERGE ARM'S OWN (REV_PAID=1): `merge-one.sh` reads and writes
              # the SAME `reviewdisp-<PR>` record this arm just spent (agent-infra#2971, one book), so
              # the attempt is counted once and the reviewer-side cap and this arm's REVIEW-CAP are
              # the same number instead of two private tallies.
              #
              # ⛔ READ THE COUNT FROM THIS PR'S VERDICT, NOT FROM A VARIABLE LEFT BY THE LAST PR. The
              # sweep loop is one shell, so a bare `_rvn` set in the CAP branch above would still hold
              # THAT PR's count here — and this value is written to `reviewdisp-<PR>` and printed as
              # the attempt number, so a stale carry would silently spend another PR's budget.
              _rvn="${_rvd##* }"
              printf '%s\n' "$REPO" "$OR" "$PR" "$BR" > "$O/state/argv-$PR"
              # Same carried contract as the GREEN rail spawn above (review P2, round 1), and the
              # same shq rule as there: `%q` is dash-unsafe (round-8 adversarial review, B6).
              # ⛔ A SPAWN THAT DID NOT HAPPEN MUST SAY SO (#2126 T1). This line was `tmux … && echo`,
              # so a FAILED re-record spawn was completely unremarked — the PR looked idle with no
              # reason. Every other spawn site in this file has an explicit failure branch.
              if wt_spawn "review-$PR" "$SPAWN_CWD" "REV_PAID=1 REQ=$(shq "$REQ") REVIEW_GATE=$(shq "$REVIEW_GATE") bash '$O/merge-one.sh' --argv '$O/state/argv-$PR'"; then
                # SPEND THE REVIEW BUDGET ONLY ON A SPAWN THAT HAPPENED — the same rule `fixcount`
                # follows one arm above: bookkeeping before the spawn makes a killed/failed spawn cost
                # a real attempt, and this counter is the only thing standing between a wedged reviewer
                # and an unbounded run of paid reviews.
                # ⛔ A RECORD THAT DID NOT LAND MUST NOT LOOK LIKE A SPENT ATTEMPT (review round 3 of
                # #2653, P2): the counter IS the bound, so an unwritable one would re-buy a paid review
                # every cycle. Named, and the head is parked so the loop stops rather than spending again.
                if ! review_disp_record "$PR" "${HEAD_N:-}" "$(( ${_rvn:-0} + 1 ))"; then
                  echo "#$PR review order review-$PR spawned, but state/reviewdisp-$PR CANNOT BE WRITTEN — the per-head review cap cannot be kept, so NO further review is dispatched for this head (attempting to park it — the park's own outcome is reported below). REFUSAL: this cycle's review was spent. REPAIR: make $O/state writable (rm -rf a stray directory named reviewdisp-$PR), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'" >>"$LOG"
                  # ⛔ AND THE PARK IS CHECKED TOO (review round 5 of #2653, P2): if the park did not
                  # land, the PR is NOT bound — it re-enters this arm and buys another paid review every
                  # cycle. Claiming PARKED over an unwritten `parked-<PR>` is the same inert-bound
                  # failure the sibling branches (CAP, AT-HEAD-STUCK) already refuse.
                  if park_ctrl "$PR" "${HEAD_N:-}" "the review budget record state/reviewdisp-$PR cannot be written, so MAX_REVIEW_TRIES cannot bound this head — refusing further dispatch (a review was spent this cycle). Make $O/state writable, then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"; then
                    # ONE row, and it is a WAIT: a second `disp` for the same PR would count one PR twice.
                    disp "$PR" "${HEAD_N:-}" "$V" wait "review budget UNWRITABLE — parked so the cap cannot be outrun"
                  else
                    echo "#$PR review budget UNWRITABLE and the PARK DID NOT LAND (state/parked-$PR is unwritable) — this head is NOT bounded and will buy another review next cycle. REFUSAL: this cycle's review was spent. REPAIR: make $O/state writable (rm -rf stray directories named reviewdisp-$PR / parked-$PR)" >>"$LOG"
                    disp "$PR" "${HEAD_N:-}" "$V" wait "review budget UNWRITABLE and PARK DID NOT LAND — a human must look at this head"
                  fi
                else
                  # The `re-record` legacy token stays in this line (suites and operators read it), but
                  # the ORDER is named: `review-<PR>`, at the head it was ordered for.
                  echo "#$PR re-record" >>"$LOG"
                  echo "#$PR review ORDER review-$PR dispatched for (PR=$PR, head=${HEAD_N:-?}) — the remedy the NEEDS-REVIEW diagnosis names; no merge worker is spawned at an unreviewed head" >>"$LOG"
                  disp "$PR" "${HEAD_N:-}" "$V" act "re-record worker review-$PR spawned (fresh review, attempt $(( ${_rvn:-0} + 1 ))/${MAX_REVIEW_TRIES:-3})"
                fi
              else
                echo "#$PR re-record spawn FAILED (no review worker started this cycle)" >>"$LOG"
                disp "$PR" "${HEAD_N:-}" "$V" wait "re-record spawn FAILED"
              fi
            else
              # ⛔ THE REFUSAL NAMES ITS HOLDERS (agent-infra#2653): a count with no owner is what let 11
              # dead worker records read as "the box is busy" for 26 hours.
              echo "#$PR $V but NO re-record slot (review lanes=$(wt_count review- merge-)/$MR — holding: $(review_lane_holders); $(spawn_gate_tok))" >>"$LOG"
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
          elif pr_owner_live "$PR" "${HEAD_N:-}" "${BR:-}"; then
            : # a worker is already on it
            disp "$PR" "${HEAD_N:-}" "$V" wait "a worker already owns this PR"
          elif [ "$(wt_count fix-)" -lt "$MF" ] && can_spawn; then
            # NO CI-QUEUE GATE — see the CONFLICTED arm above for the rule and the measurement
            # (#2927): a CI-red fixer is REPAIR, and the bounds on it are this `$MF` fix-lane ceiling,
            # `can_spawn`'s load/disk/memory gate and the cross-box claim.
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
            echo "#$PR CI-red ($V) but NO fixer slot (fix lanes=$(wt_count fix-)/$MF, $(spawn_gate_tok))" >>"$LOG"
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
          # ⛔ A RERUN IS A CI-SPENDING ACT, so it is gated like one (#2333 review P2). `gh run rerun`
          # enqueues work on the same runners the gate is holding work OUT of — the one surface in
          # this sweep that ADDS queue while the gate says "do not". Reviewing, re-recording and
          # merging an existing head spends no new CI, which is why those arms stay ungated; a rerun
          # does, so on a deep or unknown queue it is WITHHELD.
          # ⛔ AND THE GATE SITS INSIDE THE `RID` GUARD (#2333 cycle 3, P2). Tested BEFORE it, an
          # unreadable `gh pr checks` (RID empty → no rerun was ever possible) still produced a
          # "rerun withheld" line AND a ledger row — a deferral credited for an act that could not
          # have happened. And it only ever RECORDS the withholding when this PR has no row yet: an
          # existing `act` is a stronger fact, and an existing `wait` may be a stronger reason
          # (`parked: … needs a human`).
          if [ -n "${RID:-}" ] && [ ! -f "$O/state/rerun-$PR-$RID" ] && ! ciq_push_ok; then
            ciq_defer_note_here "CI rerun for #$PR (run ${RID:-?} would enqueue another run behind the backlog)" >> "$LOG"
            if ! awk -F'\t' -v p="$PR" '$1==p{f=1} END{exit f?0:1}' "$PRDISP" 2>/dev/null; then
              dispreplace "$PR" "${HEAD_N:-}" "$V" wait "ci-queue(${CIQ_VER:-unmeasured}) — rerun withheld; a rerun adds a run to the queue the gate is holding work out of"
            else
              echo "#$PR CI rerun WITHHELD by the ci-queue gate — this PR already has a disposition row this cycle, so it is left standing rather than overwritten" >> "$LOG"
            fi
          elif [ -n "${RID:-}" ] && [ ! -f "$O/state/rerun-$PR-$RID" ]; then
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
      NOCHECKS:UNRESOLVABLE:*)
        # ⛔ THE NAMED DEAD END (#2719). The resolver has already decided this head cannot be checked
        # and posted the verdict on the PR (once per head). PARK IT so no further cycle is spent: the
        # sweep's own `parked-<PR>` guard names it from now on, and a push re-arms it automatically.
        # ⛔ STILL WAIT-ONLY, STILL NO SPAWN: a named dead end is a reason to stop spending cycles, not
        # a licence to merge, fix, or fake a check.
        _NR="${V#NOCHECKS:UNRESOLVABLE:}"
        # ⛔ A PARK NEEDS A HEAD TO BE BOUND TO (review P3, agent-infra#2719). `park_ctrl` writes the
        # head it is given, and the sweep's park guard needs a NON-EMPTY head to match the next cycle's
        # row — so parking an unreadable head writes a park that is never honoured while the ledger
        # reports "parked at this head" every cycle. Name it instead.
        if [ -z "${HEAD_N:-}" ]; then
          echo "#$PR NOCHECKS-UNRESOLVABLE but the head is UNREADABLE this cycle, so it cannot be parked: ${_NR}" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (head unreadable — nothing parked, re-named next cycle)"
        # ⛔ A LITERAL, NOT A BRACKET EXPRESSION. `[ "${_NR#*[post=failed]}" != "$_NR" ]` reads
        # `[post=failed]` as a CHARACTER CLASS, so the test matched every detail that contains any of
        # those letters — i.e. always — and the arm never parked at all (measured: 4 assertions red).
        elif case "$_NR" in *"[post=ok-nomarker]"*) true ;; *) false ;; esac; then
          # The verdict WAS published; the marker that stops a second comment could not be written.
          # park_ctrl is the terminator, so the comment cannot be published again.
          if park_ctrl "$PR" "${HEAD_N:-}" "NOCHECKS-UNRESOLVABLE: ${_NR} (published once; the posted marker could not be written)"; then
            echo "#$PR PARKED — NOCHECKS-UNRESOLVABLE was published once and its marker could not be written: ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (parked so the verdict cannot be published twice)"
          else
            echo "#$PR NOCHECKS-UNRESOLVABLE published once, the marker write FAILED and the park write FAILED: ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (post marker unwritable; park write failed)"
          fi
        elif case "$_NR" in *"[post=failed-inert]"*) true ;; *) false ;; esac; then
          # ⛔ THE BOUND ITSELF IS BROKEN (state/ unwritable): the post cannot be counted, so it cannot be
          # bounded — and an unbounded comment loop is worse than a named dead end. Park it, and say so.
          if park_ctrl "$PR" "${HEAD_N:-}" "NOCHECKS-UNRESOLVABLE: ${_NR} (post attempts could not be counted)"; then
            echo "#$PR PARKED — NOCHECKS-UNRESOLVABLE and its post attempts could not be counted (state/ unwritable): ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (parked; the post bound was INERT)"
          else
            echo "#$PR NOCHECKS-UNRESOLVABLE post bound INERT and the park write FAILED: ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (post bound INERT; park write failed)"
          fi
        elif case "$_NR" in *"[post=failed-parked]"*) true ;; *) false ;; esac; then
          # The post has now failed `attempt_bound` times AT THIS HEAD: retrying further is the
          # unbounded loop (measured: 8 attempts / 172 gh calls over 9 cycles). Park it, and make the
          # failure the park REASON, so the next cycle reports WHY nothing was ever published.
          if park_ctrl "$PR" "${HEAD_N:-}" "NOCHECKS-UNRESOLVABLE: ${_NR} (the verdict could not be posted)"; then
            echo "#$PR PARKED — NOCHECKS-UNRESOLVABLE and its verdict could not be posted after N attempts: ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (parked; the verdict could NOT be published)"
          else
            echo "#$PR NOCHECKS-UNRESOLVABLE post kept failing and the park write FAILED too: ${_NR}" >>"$LOG"
            disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (post failed; park write failed — re-enters)"
          fi
        elif case "$_NR" in *"[post=failed]"*) true ;; *) false ;; esac; then
          # ⛔ THE POST IS THE POINT OF A TERMINAL VERDICT (review P2, agent-infra#2719). Parking a head
          # whose verdict never reached the PR dead-ends it with no explanation anywhere a human looks:
          # the arm never re-enters a parked head, so the post is never retried. It stays in the class,
          # NAMED, and the next cycle tries again.
          echo "#$PR NOCHECKS-UNRESOLVABLE but the verdict could NOT be posted, so nothing is parked (it is retried): ${_NR}" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (verdict not posted — not parked, retried)"
        elif park_ctrl "$PR" "${HEAD_N:-}" "NOCHECKS-UNRESOLVABLE: ${_NR}"; then
          echo "#$PR PARKED — NOCHECKS-UNRESOLVABLE: ${_NR}" >>"$LOG"
          # ⛔ THE POST STATUS IS THE RESOLVER'S, NOT THIS LINE'S CLAIM (review P2, agent-infra#2719):
          # the verdict carries `[post=ok|failed|already-posted|off]` and this row repeats it, so a
          # verdict nobody could post is never recorded as delivered.
          disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (parked at this head)"
        else
          echo "#$PR NOCHECKS-UNRESOLVABLE (the park write FAILED, so it re-enters): ${_NR}" >>"$LOG"
          disp "$PR" "${HEAD_N:-}" "$V" wait "NOCHECKS-UNRESOLVABLE: ${_NR} (park write failed — re-enters next cycle)"
        fi ;;
      NOCHECKS:*)
        # ⛔ THE CAUSE IS NAMED, WHICH IS THE WHOLE REPAIR (#2719). Before this, all four causes arrived
        # as one token and the only thing the cycle could say was "re-read next cycle". A budget window,
        # a transport failure, a run that is still executing, and a repo whose repair simply has not
        # fired yet have four different remedies and now read as four different rows.
        # ⛔ WAIT-ONLY: this arm must never spawn and never merge. `NOCHECKS` is not evidence of health
        # (an empty surface is never GREEN in this file) and it is not evidence of breakage either.
        _NR="${V#NOCHECKS:}"
        echo "#$PR no acting arm for class '${V:-<empty>}' — nothing spawned (${_NR})" >>"$LOG"
        disp "$PR" "${HEAD_N:-}" "$V" wait "check surface ${_NR} — nothing spawned" ;;
      *)
        # ⛔ THE DANGLING CLASS (#2126 T4). `NOCHECKS` (an empty check surface, or an unreadable
        # `gh pr checks` — the pipeline's stderr is discarded, so a FAILED read and an empty surface
        # both arrive here) used to reach NO arm: no merge, no fixer, and not one line. A PR could
        # therefore hold the issue path shut while the log said nothing at all about it.
        # ⛔ SINCE #2719 THIS ARM IS THE RESIDUAL, NOT THE CLASS: the sweep resolves `NOCHECKS` into a
        # NAMED verdict above (`NOCHECKS:BUDGET:…`, `NOCHECKS:READ-FAILED:…`, `NOCHECKS:WAIT:…`,
        # `NOCHECKS:DEFERRED-REPAIR:…`, `NOCHECKS:UNRESOLVABLE:…`) and a recovered class is handed to
        # the ordinary arms. What reaches here is a class token this file has never been taught, which
        # still must be named and still must spawn nothing.
        echo "#$PR no acting arm for class '${V:-<empty>}' — nothing spawned (unreadable/empty check surface; re-read next cycle)" >>"$LOG"
        disp "$PR" "${HEAD_N:-}" "${V:-NONE}" wait "check surface unreadable or empty (${V:-no class}) — nothing spawned" ;;
    esac
    # [acting-case:end]
  done
  # [sweep-cursor:begin] (extracted and DRIVEN by pr-path-reads.test.sh — keep the markers)
  # ── THE CURSOR ADVANCES BY WHAT WAS ACTUALLY READ, AFTER THE PASS (#2640) ─────────────────────
  # ⛔ THE RESUME POINT IS THE UNFINISHED ROW, NOT THE START OF THE NEXT WINDOW. The sweep above is a
  # pipeline (a killed cycle dies inside it), so the only proof a row was read is its `prdisp` row.
  # Advancing by that count means an interrupted pass resumes where it stopped instead of stepping
  # over the tail; a cycle killed before ANY row landed leaves the cursor where it was and the same
  # window is retried (at-least-once — the honest direction, and a re-read is cheap next to a PR
  # that is never read at all).
  # The start row is read from state when this block is driven on its own (the window block above
  # persists it there, and persisting the START -- not the next window -- is what makes a resume
  # possible). `SEL_CUR` wins when both exist: it is this cycle's own read.
  _cur="${SEL_CUR:-$(cat "$O/state/sweep-cursor" 2>/dev/null || true)}"
  is_num "${_cur:-}" || _cur=0; [ "${#_cur}" -le 10 ] || _cur=0
  [ "${_cur:-0}" -ge "${SEL_N:-1}" ] && _cur=0
  if [ "${SEL_N:-0}" -gt 0 ] && [ -n "${SEL_WINDOW:-}" ] && [ "${SEL_N:-0}" -gt "${SWEEP_ROWS_PER_CYCLE:-0}" ]; then
    _win_read="$(printf '%s\n' "${SEL_WINDOW:-}" | awk -F"$(printf '\t')" -v disp="$PRDISP" '
      NF==0 {next}
      { n++; split($0, f, "\t"); pr[++m]=f[1] }
      END {
        if (m == 0) { print 0; exit }
        while ((getline line < disp) > 0) { split(line, g, "\t"); got[g[1]]=1 }
        c = 0
        for (i = 1; i <= m; i++) if (pr[i] in got) c++
        print c
      }' 2>/dev/null || echo 0)"
    is_num "${_win_read:-}" || _win_read=0
    if [ "$_win_read" -gt 0 ]; then
      printf '%s\n' "$(( (_cur + _win_read) % SEL_N ))" > "$O/state/sweep-cursor" 2>/dev/null || true
      echo "[sweep] cursor: $_win_read of the window's rows were read this cycle → next start row $(( (_cur + _win_read) % SEL_N + 1 )) of $SEL_N" >> "$LOG"
    else
      echo "[sweep] cursor: NONE of the window's rows produced a disposition — the cursor stays at row $(( _cur + 1 )) and the same window is retried next cycle (a pass that read nothing must not skip anything)" >> "$LOG"
    fi
  fi
  # [sweep-cursor:end]
  # ── THE PR PATH'S OWN OUTCOME, IN ONE LINE (agent-infra#2126) ───────────────────────────────────
  # ⛔ THE LEDGER'S SECOND HALF, and it has to run in the PARENT: the sweep above is a pipeline, so
  # only the sidecar survived it. Every COUNTED un-owned PR that the sweep never saw gets its reason
  # HERE — the swept set is scope-filtered (`SCOPE=own` keeps only `-tm$|-cap$|^fix/`), drafts on
  # non-matching branches are dropped by the listing, and a 304/deferral cycle yields no rows at all.
  # Without this block those PRs are the darkest form of the defect: counted into `UPN`, so the issue
  # path stays shut, and named nowhere.
  # ⛔ NO gh CALL HERE. `OPEN_ROWS` is the same row set the count was taken from; a disposition that
  # cost a request per PR would make the honesty repair the most expensive thing in the cycle.
  # ── THE PR SICKNESS QUEUE — BESIDE THE ISSUE SELECTION, IN THE SAME CYCLE ───────────────────
  # [prsick-pass:begin] (keep the markers; the MODULE is driven by pr-sickness.test.sh — this WIRING is
  # reviewed, not extracted: the suite never reads this file, so do not claim it does)
  # ⛔ WHY HERE (BEFORE THE LEDGER'S SUMMARISER, NOT AFTER IT). The pass runs after the SWEEP (the
  # sweep's own arms own the required-red checks and the rail-refusal role owns a refused tree; this
  # queue's job is what is LEFT), and `dispreplace` SUPERSEDES the "no arm" wait row the sweep wrote
  # for the PR (one row per PR per cycle, #2126's invariant). It must land BEFORE the `[prsum]` tally
  # reads the ledger, or the cycle reports "NO UNIT SPAWNED" and `FIRST_PR=-` while an `act` row
  # exists — the funnel claiming the opposite of what happened, the same #2126 defect mirrored.
  # ⛔ NOT WHILE AUTHORITY IS UNKNOWN: that is the same fail-closed state the sweep refuses to spawn
  # in, and a paid lane is the one thing it must not hand out (agent-infra#1764).
  if [ "${PRSICK:-0}" = "1" ] && [ "${PS_ON:-1}" = "1" ] && [ "${AUTHORITY_UNKNOWN:-0}" != "1" ]; then
    # ⛔ THE ALLOWANCE IS THE REMAINING HEADROOM, NOT THE CEILING. `fix_slots` is the CONCURRENT
    # fixer ceiling every other spawn site enforces as `[ "$(wt_count fix-)" -lt "$MF" ]`; passing it
    # as a per-pass allowance would let one cycle add a full ceiling on top of the fixers the sweep
    # already started (2x the cap the [cap] line reports, each a paid agent + worktree). Headroom is
    # a MEASURED read of what is actually running, so this stays a capacity gate and not a lane cap.
    PS_MAXSPAWN=$(( $(fix_slots "${UPN:-0}") - $(wt_count fix-) ))
    is_num "${PS_MAXSPAWN:-}" || PS_MAXSPAWN=0
    [ "$PS_MAXSPAWN" -lt 0 ] && PS_MAXSPAWN=0
    # ⛔ AND THE LOAD GATE, because every other spawn site in this file ANDs it in
    # (`[ … -lt "$MF" ] && can_spawn`). Without it a box over MAX_LOAD spawns fixers the controller
    # just refused, and `fix-one.sh` materialises the worktree BEFORE its own gate refuses the agent —
    # so the worktree is paid for either way. The pass still RECONCILES and REPORTS (that is how the
    # deferral survives), it just spawns nothing, and says why.
    _ps_L="$(load1)"
    if ! { is_num "${_ps_L:-}" && [ "${_ps_L:-0}" -lt "${MAX_LOAD:-40}" ]; }; then
      PS_MAXSPAWN=0
      echo "[prsick] load gate closed (L=${_ps_L:-?} >= MAX_LOAD=${MAX_LOAD:-?}) — the pass reconciles and reports, spawning nothing; deferred items keep their place" >>"$LOG"
    fi
    PS_STATE_DIR="$O/state" PS_OR="$OR" PS_REPO_PATH="$REPO" PS_SPAWN_CWD="$SPAWN_CWD" \
      ps_select --repo "$OR" --max-spawn "$PS_MAXSPAWN" --verbose >> "$LOG" 2>&1
    _ps_rc=$?
    # ⛔ A FAILED PASS IS ITS OWN LINE, never an empty one. `ps_select` already names the cause (its
    # ENUMERATION FAILED / NOREAD lines land in $LOG above); this records that the QUEUE was not
    # evaluated, so "no [prsick] decisions" can never be read as "no sick PRs".
    [ "$_ps_rc" -ne 0 ] && echo "[prsick] pass did not complete (rc=$_ps_rc) — the PR sickness queue was NOT evaluated this cycle; see the ENUMERATION FAILED / NOREAD line above" >> "$LOG"
  fi
  # [prsick-pass:end]

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
      # ⛔ THE REASON NAMES THE THING THAT WAS MISSING (#2601). "unchanged — 304 — or unreadable"
      # collapsed three different facts into one string, so an operator could not tell a bounded
      # cache-skip from a failed API call from a fresh state dir with no cache at all.
      disp "$_p" - - wait "no per-PR read this cycle (${SWEEP_CACHE_NOTE:-the open-PR listing was unchanged — 304 — or unreadable})"
    else
      # ⛔ OUTSIDE THIS CYCLE'S WINDOW IS NOT "UNSWEPT" (#2601). The sweep is bounded so that a pass
      # COMPLETES (see the window block above); a row it did not reach this cycle carries the window
      # it fell outside of, plus when the rotation returns to it. Named, never silently dropped —
      # and kept DISTINCT from "never in the swept set", which is a scope/draft fact, not a timing one.
      _in_win=0; _in_swept=0
      case "${SWEEP_WINDOW_PR:-}" in *" $_p "*) _in_win=1 ;; esac
      printf '%s\n' "${SWEEP_LIST:-}" | awk -F"$(printf '\t')" -v p="$_p" '$1==p{f=1} END{exit f?0:1}' && _in_swept=1
      if [ "$_in_win" = "1" ]; then
        disp "$_p" - - wait "in this cycle's sweep window but the sweep recorded no disposition for it (re-read next cycle)"
      elif [ "$_in_swept" = "1" ]; then
        _k="${SWEEP_ROWS_PER_CYCLE:-8}"; is_limit "${_k:-}" || _k=8; [ "$_k" -ge 1 ] || _k=8
        disp "$_p" - - wait "outside this cycle's sweep window (${SWEEP_WIN_NOTE:-SWEEP_ROWS_PER_CYCLE}); it is read within $(( (${SEL_N:-1} + _k - 1) / _k )) cycles"
      else
        disp "$_p" - - wait "not in this cycle's swept set (scope=$SCOPE_MODE; drafts and non-matching branches are filtered out)"
      fi
    fi
  done
  # [prdisp-apply:end]
  # [prsum:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
  # ── THE ACTUATOR'S OWN ANSWER, BESIDE THE TALLY ─────────────────────────────────────────────
  # ⛔ `N acted` MUST NEVER HIDE A REFUSED SPAWN. An "act" can be a draft-ready or an auto-arm that
  # starts no worker; the refusal record is the only measurement of "did a lane actually start".
  # Print the count and the launcher's OWN reason (never a guess) on every state of the line below,
  # so `lanes=0` and "the loop is doing nothing" cannot again be printed without the cause beside it.
  SPAWNREF_N=0; SPAWNREF_WHY=""
  if [ "${SPAWNREF_OK:-1}" = "1" ] && [ -s "${SPAWNREF:-/nonexistent}" ]; then
    _srn="$(awk 'END{print NR+0}' "$SPAWNREF" 2>/dev/null)"
    is_num "${_srn:-}" || _srn=0
    SPAWNREF_N=$(( _srn - ${SPAWNREF_BASE:-0} )); [ "$SPAWNREF_N" -lt 0 ] && SPAWNREF_N=0
    # The probe row is `#`, never a worker name; skipping it keeps the reason the launcher's own.
    SPAWNREF_WHY="$(awk -F"$(printf '\t')" 'NF>=2 && $1 != "#"{print $2; exit}' "$SPAWNREF" 2>/dev/null | cut -c1-200)"
  fi
  _refsuf=""
  # ⛔ TWO HONESTY RULES ON THIS SUFFIX (review, cycle 1):
  #  • NO ABSOLUTE CLAIM. "NO LANE COULD START" was printed beside "N worker(s) in flight" on any
  #    PARTIAL refusal — a false statement on the operator's decision line. The count and the
  #    launcher's words are the measurement; the conclusion is the reader's.
  #  • `≥` AT THE CAP. The record is bounded at 200 rows per cycle, so a storm is 200 rows and an
  #    exact count would understate it while reading as exact.
  if [ "${SPAWNREF_OK:-1}" != "1" ]; then
    _refsuf=" ⛔ refusal measurement UNAVAILABLE (${SPAWNREF_WHY_BAD:-state/ is not writable}) — any refused spawn this cycle is UNMEASURED"
  elif [ "${SPAWNREF_N:-0}" -ge 200 ]; then
    _refsuf=" ⛔ ≥200 spawn(s) REFUSED by the launcher (${SPAWNREF_WHY:-reason not recorded}) — the record is capped at 200 rows this cycle"
  elif [ "${SPAWNREF_N:-0}" -gt 0 ]; then
    _refsuf=" ⛔ ${SPAWNREF_N} spawn(s) REFUSED by the launcher (${SPAWNREF_WHY:-reason not recorded})"
  fi
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
  # ── THE EXAMINED WINDOW'S OWN REASONS (agent-infra#2933) ──────────────────────────────────────
  # ⛔ THE MEASURED DEFECT THIS REPLACES (2026-10-27, tortoise target): 26 PRs open, K=8 examined per
  # cycle, and the line printed `most common: 15 outside this cycle's sweep window …` — computed across
  # ALL rows, so a fact about the 15 rows the sweep did NOT look at answered for the 8 it did. The
  # deferred majority always outnumbers the sample, so the modal reason was ALWAYS the deferral and the
  # examined rows' own reasons were never printed. An operator could not tell "everything examined is
  # legitimately waiting" from "the rows the sweep read are being refused by something broken" — the
  # "tool that cannot answer its own question" class (#2590, #2640).
  # ⛔ REPORT THE SAMPLE, NEVER THE POPULATION — AND NEVER ENLARGE IT. K rows/cycle with a rotating
  # cursor is a recorded design decision (#2640, `[sweep-window]` above): the bounded read is what makes
  # a pass COMPLETE, and the arms are at the END of the loop. This block only reports WHICH rows the
  # sweep actually read this cycle and why those did not act. It changes no dispatch decision, no gate
  # and no budget: widening K would reverse that decision.
  # ⛔ THE LABELS ARE THE LEDGER'S OWN STRINGS, GROUPED — never a parallel vocabulary. Each label is
  # derived from field 5 by cutting at its first detail separator (` (`, ` — `, `;`) and collapsing digit
  # runs to `N`, so `capacity: fix-lane ceiling 2 reached` and `… ceiling 4 reached` are ONE class (only
  # the parameter differs) while the words stay exactly the words the per-row record carries. A summary
  # that invented `owned-by-live-worker` would drift from the records it summarises.
  # ⛔ NO CLASS CAP. The examined window is bounded by K (8 by default), so every class in it fits on
  # the line and a cap would re-create the defect one level down: an operator reading "+2 more" still
  # cannot tell whether those two rows are waiting or refused. A test that demands EVERY examined
  # reason be printed cannot be satisfied by a capped summary, and the issue asks for exactly that.
  # The population is the EXAMINED WINDOW when there is one (rows whose PR is in `SWEEP_WINDOW_PR`);
  # with no window at all (nothing was selected to read) it is every row, which is then the same thing.
  PRDISP_WIN_N=0; PRDISP_DEFER_N=0; PRDISP_WIN_REASONS=""
  if [ "$PRDISP_ROWS" -gt 0 ]; then
    PRDISP_WIN_N="$(awk -F'\t' -v win="${SWEEP_WINDOW_PR:-}" '
      BEGIN { _n=split(win, _w, " "); for (_i=1; _i<=_n; _i++) if (_w[_i] ~ /^[0-9]+$/) inwin[_w[_i]]=1 }
      length(win) > 0 && ($1 in inwin) { n++ }
      END { print n+0 }' "$PRDISP" 2>/dev/null)"
    is_num "${PRDISP_WIN_N:-}" || PRDISP_WIN_N=0
    [ "$PRDISP_WIN_N" -gt "$PRDISP_ROWS" ] && PRDISP_WIN_N=$PRDISP_ROWS
    PRDISP_DEFER_N=$(( PRDISP_ROWS - PRDISP_WIN_N ))
    PRDISP_WIN_REASONS="$(awk -F'\t' -v win="${SWEEP_WINDOW_PR:-}" '
      BEGIN { _n=split(win, _w, " "); for (_i=1; _i<=_n; _i++) if (_w[_i] ~ /^[0-9]+$/) inwin[_w[_i]]=1 }
      length(win) > 0 && !($1 in inwin) { next }
      $4 != "wait" { next }
      { r=$5
        sub(/ \[harness=[^]]*\]$/, "", r)
        _c=index(r, " (");  if (_c) r=substr(r, 1, _c-1)
        _c=index(r, " — "); if (_c) r=substr(r, 1, _c-1)
        _c=index(r, ";");   if (_c) r=substr(r, 1, _c-1)
        gsub(/[0-9]+/, "N", r); gsub(/[ \t]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r)
        if (r == "") r="(unnamed reason)"
        cnt[r]++ }
      END { for (k in cnt) printf "%d\t%s\n", cnt[k], k }' "$PRDISP" 2>/dev/null \
      | sort -rn \
      | awk -F'\t' '{ printf "%s%d %s", (n++ ? " · " : ""), $1, $2 }')"
  fi
  # ── THE TERMINAL OUTCOME OF THIS PASS'S PR WORK (agent-infra#2590) ─────────────────────────────
  # Exactly ONE of these three lines is printed, and it answers "what did this pass START?" from the
  # worker records `wt_spawn` wrote — never from a count of dispositions, which an arm or a rerun
  # inflates without starting anything. `PRDISP_SPAWNS` is what the funnel and the drain guard read.
  # ⛔ THREE STATES, THREE READINGS: a measured zero (NONE), a measured positive (SPAWNED), and no
  # measurement at all (UNMEASURED). Collapsing the third into NONE is the same defect sign-reversed
  # — and the drain guard must not manufacture a deadlock claim out of an unread directory.
  PRDISP_SPAWNS=""; PRDISP_SPAWN_TAGS=""
  _spl="$(spawns_since "${CYCLE_T0:-0}" 2>/dev/null || true)"
  _spn="${_spl%%	*}"; _spt="${_spl#*	}"
  [ "$_spt" = "$_spl" ] && _spt=""
  if ! is_num "${_spn:-}"; then
    # ⛔ THIS MEASUREMENT IS SCOPED TO THE PR SWEEP, AND THE LINE SAYS SO (review 4-P2). The sample is
    # taken in the [prsum] block, but the ISSUE lanes are spawned later (dispatch-merge.sh -> wt_spawn).
    # An unscoped "no worker was started by this pass" was therefore FALSE on every issue-dispatching
    # pass — it printed NONE and then the lanes landed — which is the same acted-vs-spawned lie this
    # change exists to delete, on the one question the issue asks.
    echo "[spawn] UNMEASURED — this pass cannot say what its PR sweep started (state/ cannot be enumerated or the cycle clock is unreadable), so the ${PRDISP_ACTS:-?} act row(s) below are actions, NOT spawns; do not read them as work in flight" >>"$LOG"
  elif [ "$_spn" -gt 0 ]; then
    PRDISP_SPAWNS="$_spn"; PRDISP_SPAWN_TAGS="$_spt"
    echo "[spawn] SPAWNED $_spn worker(s) in this pass's PR sweep: ${_spt:--} (each is a state/worker-<tag> record wt_spawn wrote at created>=${CYCLE_T0:-0}; the tag is the handle the census, the caps and the reaper use)" >>"$LOG"
  else
    # A measured 0 owns `none`; UNMEASURED must not also claim it (review 6-P2).
    PRDISP_SPAWNS=0; PRDISP_SPAWN_TAGS="none"
    echo "[spawn] NONE — the PR sweep started no worker this pass (0 state/worker-* records with created>=${CYCLE_T0:-0}); ${PRDISP_ACTS:-0} act row(s) may still exist — an arm, a rerun or a draft-ready — and those start nothing. Issue lanes, if any are dispatched below, are NOT counted here" >>"$LOG"
  fi
  # ⛔ THE POPULATION CAVEAT IS NOT OPTIONAL. `OPEN_ROWS` is the only enumerable list of the COUNTED
  # set; without it (GraphQL failed and `open_pr_count` deleted its rows, or the fallback fired) the
  # ledger covers the SWEPT set only, while the gate is reading the listing count. Saying "N named
  # waits" unqualified there would present a narrower population as the whole one — the arithmetic
  # that does not close this block exists to end. And if `state/` is unwritable the ledger is empty by
  # CONSTRUCTION: the outcome is then UNKNOWN, never "nothing happened".
  if [ "${PRDISP_OK:-1}" != "1" ]; then
    echo "[pr] PR path: record UNWRITABLE (state/ is not writable) — this cycle's PR actions are UNKNOWN, not zero; ${UPN_WORK:-?} un-owned PR(s) are counted${_refsuf:-}" >>"$LOG"
    PR_FIRST_TOK="unknown (the PR record is unwritable — see the [pr] line)"
  elif [ "$PRDISP_ROWS" -eq 0 ]; then
    # ⛔ A ZERO ROW COUNT HAS TWO CAUSES AND THE COUNT CANNOT TELL THEM APART (review cycle 2, P2): no
    # listing rows, OR rows were read and NOT ONE WRITE LANDED (a truncate succeeds with no allocation,
    # so a full `state/` passes the `PRDISP_OK` probe at the top and then every `disp` fails). Naming
    # only the first would send an operator to repair the GraphQL listing when the state filesystem is
    # the broken thing. Both are stated; neither is asserted.
    echo "[pr] PR path: NO ROWS — no per-PR disposition was recorded this cycle (either the listing returned no rows, or the record could not be written), so not one PR can be named; PR actions are UNKNOWN, not zero; ${UPN_WORK:-?} un-owned remain (see the [select] population line)${_refsuf:-}" >>"$LOG"
    PR_FIRST_TOK="none enumerable (no per-PR rows this cycle)"
  elif [ "$PRDISP_ACTS" -gt 0 ]; then
    echo "[pr] PR path: ${PRDISP_ACTS} acted (${PRDISP_ACTED}), ${PRDISP_WAITS} named wait(s) across ${PRDISP_ROWS} row(s) — ${SCOPE_MODE} scope, $(wt_count merge- review- fix-) worker(s) in flight; spawned=${PRDISP_SPAWNS:-UNMEASURED} this pass (see the [spawn] line: acted counts ACTIONS, only a spawn starts a worker)${_refsuf:-}" >>"$LOG"
    PR_FIRST_TOK="#${PRDISP_FIRST}"
    [ -n "${PRDISP_FIRST:-}" ] || PR_FIRST_TOK="none named"
  else
    # NOTHING WAS ACTED ON. This is the line that makes a stalled drain distinguishable from an idle
    # one: no unit ran, and the reason is named rather than inferred. It does NOT claim what the issue
    # path will do — the gate is decided further down, and a forward claim here would be the same
    # defect sign-reversed (all counted PRs parked is a state where the gate legitimately opens).
    # ⛔ THE REASONS ARE THE EXAMINED ROWS' (agent-infra#2933). Printing the modal reason across ALL
    # rows made the deferred majority answer for the sample — measured: `most common: 15 outside this
    # cycle's sweep window` for 26 rows with 8 examined, so the line named a fact about the rows it did
    # NOT look at and never said why the 8 it did look at produced nothing. The examined sample and the
    # deferred count are now separate clauses, and the reasons come from the window's own ledger rows.
    # The contract is unchanged: ONE line, `spawned=N` still named, never silent.
    if [ "${SWEEP_WINDOW_PR:-}" != "" ]; then
      _prwinwhat="${SWEEP_WIN_NOTE#window=}"
      [ -n "$_prwinwhat" ] || _prwinwhat="${SWEEP_ROWS_PER_CYCLE:-?} row(s)/cycle, rotating"
      echo "[pr] PR path: NO UNIT SPAWNED this cycle — ${PRDISP_WAITS} row(s) with a named reason; examined ${PRDISP_WIN_N} (window ${_prwinwhat}); ${PRDISP_DEFER_N} deferred or scope-excluded this cycle (their reasons are not on this line); examined reasons: ${PRDISP_WIN_REASONS:-(none recorded)}; spawned=${PRDISP_SPAWNS:-UNMEASURED} worker(s) this pass (see the [spawn] line)${_refsuf:-}" >>"$LOG"
    else
      # NO WINDOW IS NOT "ZERO EXAMINED": nothing was selected to read at all (a deferral, a failed
      # listing, a cache-less 304), so the only honest population IS every row — and saying "examined
      # 0" here would hide the very reasons this line exists to print.
      echo "[pr] PR path: NO UNIT SPAWNED this cycle — ${PRDISP_WAITS} row(s) with a named reason; NO SWEEP WINDOW this cycle (nothing was selected to read, so there is no examined sample), so the reasons below are for ALL ${PRDISP_ROWS} row(s): ${PRDISP_WIN_REASONS:-(none recorded)}; spawned=${PRDISP_SPAWNS:-UNMEASURED} worker(s) this pass (see the [spawn] line)${_refsuf:-}" >>"$LOG"
    fi
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
  L="$(load1)"; measure_lanes
  # agent-infra#1709 item 4: WORKERS counts the non-lane agent sessions (reviewers + fixers)
  # live at this instant, so the dispatch block line below can distinguish "blocked while the box
  # was idle" (lanes=0 workers=0 -> raising the ceiling helps) from "blocked while busy" (it does
  # not). Total in-flight agents = lanes + workers.
  WORKERS="$(wt_count merge- review- fix-)"
  # A load reading that is empty or non-numeric is the DOCUMENTED FAIL-OPEN (can_spawn() defaults it
  # to 0). Kept deliberately (#1702): both supported platforms are measurable now, and failing CLOSED
  # on an unreadable probe would convert "no load back-pressure" into a permanent controller outage on
  # a host with no procfs and no sysctl — a worse and less recoverable failure than the gate it guards.
  # The remaining gates (MAX_LANES, memory, merge-priority) still bound dispatch. Coerced here as well
  # so the gate chain cannot emit "integer expression expected", and so the logged value IS the value
  # the gate used.
  is_num "${L:-}" || L=0
  # ── FLEET PLACEMENT: MEASURED, EVERY CYCLE, BEFORE A SINGLE LANE IS PLACED ────────────────────
  # The gate chain below is LOCAL: `load=$L>=max_load`, `lanes=`, `swap_free=`, `mem_avail=` all read
  # THIS box. Measured 2026-10-21 09:45 the fleet was cell-1 29.82 load on 8 cpu (saturated), cell-3
  # 8.14 on 4, cell-4 0.56 on 8 (idle, and twice cell-3's size) — and every one of those gates passed
  # or failed on ONE box with no knowledge of the others, so nothing ever moved. Both halves of the
  # reading are collected here, once per cycle:
  #   * this box PUBLISHES its own record (load-per-cpu, lanes, free disk, free memory) to the shared
  #     origin — the same channel and the same `git ls-remote` read `claims.sh` already uses;
  #   * this box READS the whole fleet and asks `cap_place` which box should take the work.
  # ⛔ FAIL-CLOSED IN ONE DIRECTION ONLY: an unreadable probe, an absent peer record or a stale one is
  # INELIGIBLE (never "probably fine"), and if NO box is eligible the dispatch is REFUSED with the
  # bound it hit — it is never placed on the saturated box just because that is the box asking.
  # ⛔ AND IT NEVER TOUCHES THE MERGE PATH. This decides where a NEW LANE goes; the PR sweep above
  # has already run and the red-fixer/merge lanes are gated by the spawn gate, not here.
  if [ "${CAPACITY:-0}" = "1" ]; then
    # ⛔ THE PROBE'S EXIT STATUS IS PART OF THE READING (agent-infra#2293). rc 254 = the probe's own
    # child could not fork: bash terminates on a failed fork, so the child dies instead of answering.
    # Left as `|| CAP_REC=""` this was indistinguishable from "the probe found no numbers", and the
    # cycle wandered on to `git`/`gh`/`wt_spawn` — spending exactly the forks the box does not have.
    CAP_REC="$(cap_probe_local "$REPO" "${LANES:-0}" 2>/dev/null)"; CAP_RC=$?
    CAP_FORK_BOUND_SELF=""
    if [ "${CAP_RC:-0}" -eq 254 ]; then
      CAP_REC=""; CAP_STATE=fork_exhausted; FORK_STARVED=1; FORK_STATE=starved
      FORK_WHY="fork_probe_failed(probe_rc=254, procs=${FORK_PROCS:-?}/${FORK_MAX:-?})"
      echo "[capacity] THIS BOX COULD NOT FORK (probe rc=254 = EAGAIN): it is INELIGIBLE, nothing is placed on it, and no further work is started this cycle — see [fork]" >> "$LOG"
    elif [ -z "${CAP_REC:-}" ]; then
      CAP_STATE=unreadable
      echo "[capacity] this box's probe is UNREADABLE (no load/ncpu/disk/mem reading) — it is INELIGIBLE, and it will not place work on itself blind either" >> "$LOG"
    else
      # THE LOCAL FORK BOUND, from the SAME record placement reads — one implementation, two consumers.
      CAP_FORK_BOUND_SELF="$(cap_fork_bound "$CAP_REC" 2>/dev/null)" || CAP_FORK_BOUND_SELF=""
      CAP_LPC_SELF="$(cap_kv "$CAP_REC" lpc)"
      cap_publish "$REPO" "$CAP_REC" > /dev/null 2>&1 \
        || echo "[capacity] this box's reading could not be PUBLISHED to $CAP_NS — peers are blind to it, so it is INELIGIBLE to them; the dispatch itself is unaffected (peers keep their own readings)" >> "$LOG"
      CAP_FLEET="$(cap_read_fleet "$REPO" 2>/dev/null)" || CAP_FLEET=""
      [ -n "${CAP_FLEET:-}" ] || echo "[capacity] NO peer reading could be read from $CAP_NS — an absent record is not 'fine': every box without one is INELIGIBLE (this box's own record is still used)" >> "$LOG"
      # THIS box's own record is appended even when its publish failed: it is MEASURED, not inferred.
      CAP_VERDICT="$(printf '%s\n' "${CAP_FLEET:-}" "$CAP_REC" | cap_place "$(cap_host)")" || true
      case "${CAP_VERDICT:-}" in
        place=*)  CAP_STATE=place
                  CAP_PLACE="${CAP_VERDICT#place=}"; CAP_PLACE="${CAP_PLACE%% *}" ;;
        refuse=*) CAP_STATE=refuse
                  CAP_BOUND="$(printf '%s\n' "$CAP_VERDICT" | sed -n 's/.*bound=*\([A-Za-z_]*\).*/\1/p')"
                  CAP_WHY="$CAP_VERDICT" ;;
        *)        CAP_STATE=unreadable ;;
      esac
      echo "[capacity] placement=$CAP_STATE place=${CAP_PLACE:-none} lpc_self=${CAP_LPC_SELF:-?} ceiling_lpc=${CAP_LPC_CEILING:-800}${CAP_BOUND:+ bound=$CAP_BOUND} — $( [ "$CAP_STATE" = refuse ] && printf 'REFUSED: %s' "${CAP_VERDICT:-?}" || printf '%s' "${CAP_VERDICT:-?}" )" >> "$LOG"
    fi
  else
    echo "[capacity] capacity.sh is NOT available (looked in \$O and the script directory) — placement falls back to the LOCAL gates ONLY: no box can move work off a saturated box this cycle" >> "$LOG"
  fi
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
  # ⛔ RE-MEASURED HERE ON PURPOSE (agent-infra#1732): the prologue already measured it for the spawn
  # gate, but THIS read decides a dispatch, and a dispatch must see the present — memory can fall a
  # long way during a cycle's sweep. One seam (`measure_mem`) sets the pair, so the two readings can
  # never be derived differently; see measure_mem for the UNKNOWN-not-ample polarity.
  measure_mem
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
  # ⛔ `lanes=<live>/<total>` and `zombie=<n>` (#2163). The TOTAL is the field that makes a leak
  # visible: `lanes=14/25` still reads "full" while `lanes=14/76` says the box is carrying 62 finished
  # residents. `max_lanes=` keeps the ceiling the gate applies, so no reader has to infer it.
  echo "[cap] load=$L/$MAX_LOAD lanes=${LANES_DISPLAY:-?}/$LANES_TOTAL max_lanes=$MAX_LANES zombie=$ZOMBIES lanes_src=${LANES_SOURCE:-unset} mem_avail=${MEMAVAIL_MB}M/${MIN_MEM_FREE_MB}M swap_free=${SWFREE}M/${MIN_SWAP_FREE}M open=${OPEN_N:-?}@${OR:-?} unowned=${UPN:-?} last_land=${LAND_AGE:-?}m review_slots=${MR:-?} fix_slots=${MF:-?}" >> "$LOG"
  # Four gates. swap_total=0 => swap uninitialised (fresh boot), NOT pressure — allow.
  # Name the binding gate: an earlier version logged "skipped (load=…)" while load was never
  # consulted, so a lanes-bound or swap-bound stall looked like a load stall.
  # ── THE CI QUEUE, MEASURED ONCE PER CYCLE (see ci-queue.sh's header for the arithmetic) ──────
  # Read in THIS shell, never in a `$( )`: a command substitution would end the subshell with the
  # record inside it, and every arm below (and the deferral line) would read an empty one.
  CIQ_RC=1; CIQ_VER=""
  if [ "${CIQ:-0}" = "1" ]; then
    ciq_read "${OR:-}" >/dev/null 2>&1
    CIQ_VER="$(ciq_eval)"; CIQ_RC=$?
    echo "[ci-queue] repo=${OR:-?} verdict=$CIQ_VER queued=${CIQ_QUEUED:-?} running=${CIQ_RUNNING:-?} runners=${CIQ_RUNNERS:-?} busy=${CIQ_BUSY:-?} ceiling=${CIQ_CEILING:-?} state=${CIQ_STATE:-?} age=${CIQ_AGE:-?}s horizon=$(ciq_horizon_min)m job_p90=$(ciq_job_p90_min)m" >> "$LOG"
  elif [ -n "${_ciq_mod:-}" ]; then
    # TWO distinct causes of CIQ=0, and THIS line must not confuse them (#2333 review, P2). The
    # module was FOUND and did not source the ten-name interface — the [ci-queue] INCOMPLETE line
    # above already named the missing names, and `_ciq_mod` (a global in this same shell) carries
    # the path. Printing "NOT available" here was a false statement about the box's own state on
    # the next line of the same log: the exact class the INCOMPLETE disclosure was fixed for.
    echo "[ci-queue] $_ciq_mod is present but did not source the ten-name interface (see the [ci-queue] INCOMPLETE line above) — CI capacity is UNMEASURED this cycle, so this arm is INERT; the issue path still has to clear every other gate" >> "$LOG"
  else
    echo "[ci-queue] ci-queue.sh is NOT available (looked in \$O and the script directory) — CI capacity is UNMEASURED this cycle, so this arm is INERT; the issue path still has to clear every other gate" >> "$LOG"
  fi
  GATE_WHY="$(mp_reason "${UPN_WORK:-${UPN:-0}}" "$LANES" "$WORKERS" "${SEL_TOTAL:-${OPEN_N:-0}}")"
  # ── THE GATE VECTOR, AND WHY THE ARMS STOPPED BEING ONE `elif` CHAIN (#2924, #2927) ──────────────
  # ⛔ ONLY THE FIRST GATE THAT FIRED WAS EVER VISIBLE. `GATE_WHY` is ONE string and the arms were an
  # `elif` chain, so the first arm that fired MASKED every arm behind it — and the arm that fires first
  # is `merge-priority`, which is set whenever any workable un-owned PR exists. Measured 2026-10-27:
  # 349 of 384 cycles closed the issue path with `merge-priority` named, while the box had **25 free
  # lane slots**; of those gated cycles **88.5% also had a capacity gate that would have refused**, and
  # **64** were refused with `ci-queue=ok`. So an idle cycle could not say whether it was waiting for
  # the PR sweep (normal, healthy) or being throttled by a capacity gate (a defect) — and the PR side,
  # which is the only population whose movement can lift `merge-priority`, was itself being deferred.
  #
  # ⛔ THE FIX IS NOT A SECOND COPY OF THE PREDICATES. The arms are INDEPENDENT predicates, and the
  # chain encoded exactly one thing with `elif`: the ORDER in which a winner is chosen. Each arm is now
  # its own guard that (a) assigns `GATE_WHY` ONLY IF IT IS STILL UNSET — identical first-wins
  # semantics, byte-for-byte the same winner — and (b) appends its own verdict to `GATE_VEC` whether it
  # won or not. A future arm added here is therefore visible in the vector by construction, and a
  # predicate is never written down twice (the defect that lets a gate and its report drift apart).
  # [gatevec:begin] (extracted and DRIVEN by test-gates.sh — keep the markers)
  GATE_VEC=""
  if [ -n "$GATE_WHY" ]; then
    GATE_VEC="merge-priority(${UPN_WORK:-${UPN:-?}} un-owned PR(s) workable, ${SEL_TOTAL:-${OPEN_N:-?}} candidate(s))"
  else
    GATE_VEC="merge-priority=clear"
  fi
  # ⛔ FORK HEADROOM IS THE FIRST CAPACITY GATE, AHEAD OF LOAD (agent-infra#2293). A box at 0.32x load
  # can be completely unable to spawn, so a chain that reports `load=` first describes the wrong
  # resource and points the operator at a remedy (wait) that cannot work. The order is
  # FORK -> DISK -> LOAD here as it is in capacity.sh's `cap_bound_hit`; DISK is not repeated here
  # because the spawn point (`spawn-gate.sh`) is its ONE implementation and it now runs it after this
  # same fork read.
  if [ "${FORK_STARVED:-0}" = "1" ]; then
    GATE_WHY="${GATE_WHY:-${FORK_WHY:-fork_headroom_below_margin}}"
    GATE_VEC="$GATE_VEC fork=REFUSE(${FORK_WHY:-headroom_below_margin})"
  else GATE_VEC="$GATE_VEC fork=ok"; fi
  if [ -n "${CAP_FORK_BOUND_SELF:-}" ]; then
    GATE_WHY="${GATE_WHY:-fork_${CAP_FORK_BOUND_SELF#fork_}(procs=${FORK_PROCS:-?}/${FORK_MAX:-?})}"
    GATE_VEC="$GATE_VEC fork_bound=REFUSE(procs=${FORK_PROCS:-?}/${FORK_MAX:-?} by ${CAP_FORK_BOUND_SELF#fork_})"
  else GATE_VEC="$GATE_VEC fork_bound=ok(procs=${FORK_PROCS:-?}/${FORK_MAX:-?})"; fi
  if [ "${LANES_UNKNOWN:-0}" = "1" ]; then
    GATE_WHY="${GATE_WHY:-lanes_unknown (the lane census could not be read -> do not add work)}"
    GATE_VEC="$GATE_VEC lanes=UNKNOWN(the census could not be read)"
  else GATE_VEC="$GATE_VEC lanes=$LANES/${MAX_LANES:-?}"; fi
  if [ "$L" -ge "$MAX_LOAD" ]; then
    GATE_WHY="${GATE_WHY:-load=$L>=max_load=$MAX_LOAD}"
    GATE_VEC="$GATE_VEC load=REFUSE($L>=${MAX_LOAD:-?})"
  else GATE_VEC="$GATE_VEC load=ok($L<${MAX_LOAD:-?})"; fi
  # ⛔ NO ELIGIBLE BOX ANYWHERE => NO NEW LANE ANYWHERE (measured placement, 2026-10-21). This arm is
  # reachable only when `cap_place` found a fleet with ZERO eligible boxes; it names the BOUND the
  # refusal hit (load_per_cpu / disk / memory / probe_stale / probe_unreadable / no_probe) so the
  # operator learns which resource to add, instead of reading a bare "skipped". A box that is merely
  # NOT the least-loaded one does NOT reach here — it is `place=<peer>`, which yields the item below
  # so the eligible box can actually take it (a refusal would strand it on a box that is fine).
  if [ "${CAP_STATE:-unavailable}" = "refuse" ] && [ -z "${CAP_PLACE:-}" ]; then
    GATE_WHY="${GATE_WHY:-capacity-placement(bound=${CAP_BOUND:-unknown} no-eligible-box)}"
    GATE_VEC="$GATE_VEC placement=REFUSE(bound=${CAP_BOUND:-unknown} no-eligible-box)"
  else GATE_VEC="$GATE_VEC placement=${CAP_PLACE:-${CAP_STATE:-unavailable}}"; fi
  # ⛔ THE CI-QUEUE ARM: deep (or UNKNOWN) => the ISSUE path is CLOSED, and that is the "prefer work
  # that does not need CI" rule made executable rather than advisory. Issue work opens NEW PRs, and
  # every new PR is another full CI pass queued behind the backlog; the PR sweep above already ran
  # and keeps running — reviewing, re-recording and merging EXISTING heads spends no new CI and
  # REMOVES queue, so this arm costs the fleet nothing it was going to get anyway.
  # UNKNOWN defers too (fail closed): an unreadable queue is not an empty one, and a gh outage would
  # otherwise buy exactly the stampede on the one cycle the fleet could not see. The cache in
  # ci-queue.sh keeps that from firing on a transient error (it reports state=cache, with its age).
  # [ciq-arm:begin] (extracted and DRIVEN by ci-queue.test.sh (h6) — keep the markers)
  if [ "${CIQ:-0}" = "1" ]; then
    if [ "${CIQ_RC:-1}" != "1" ]; then
      GATE_WHY="${GATE_WHY:-ci-queue($CIQ_VER)}"
      GATE_VEC="$GATE_VEC ci-queue=REFUSE(${CIQ_VER:-unmeasured})"
    else
      # ⛔ THE QUEUE THAT WAS READ IS PRINTED EVEN WHEN IT PERMITS (#2927): an `ok` that hides the number
      # it was derived from is the inference-as-measurement class this module exists to end, and on the
      # idle line it is the difference between "the queue is fine" and "the queue is fine on 1 runner".
      GATE_VEC="$GATE_VEC ci-queue=${CIQ_VER:-ok}"
    fi
  else GATE_VEC="$GATE_VEC ci-queue=UNMEASURED(the module is not available this cycle -> this arm is INERT)"; fi
  # [ciq-arm:end]
  if [ "$LANES" -ge "$MAX_LANES" ]; then
    GATE_WHY="${GATE_WHY:-lanes=$LANES>=max_lanes=$MAX_LANES}"
    GATE_VEC="$GATE_VEC lanes_full=$LANES>=${MAX_LANES:-?}(0 slots free)"
  else
    # ⛔ AN UNREADABLE CENSUS IS NOT "20 SLOTS FREE": the lanes token above already says UNKNOWN, and a
    # slot count derived from a count nobody read would be the same inference-as-measurement defect.
    if [ "${LANES_UNKNOWN:-0}" = "1" ]; then GATE_VEC="$GATE_VEC slots=UNKNOWN"
    else GATE_VEC="$GATE_VEC slots=$(( ${MAX_LANES:-0} - ${LANES:-0} )) free of ${MAX_LANES:-?}"; fi
  fi
  # ⛔ SWAP IS CUMULATIVE, RAM IS PRESENT (#1985). On macOS a 1 GB swap file stays roughly half
  # occupied for the life of the boot after ANY spike, so this arm vetoed dispatch forever while the
  # box had 1.4 GB available RAM (53 MB free + 1297 MB inactive) and 20 of 20 lane slots idle:
  # measured 2026-10-18, every cycle, "lanes=0/20 … swap_free=506M<=min_swap_free=600M". The metric
  # described the PAST, and with the RAM gate PASSING underneath it, "no create activity" was
  # indistinguishable from "nothing to do".
  # Swap exhaustion only matters when RAM is ALSO tight, so require both. An UNKNOWN memory read
  # keeps the veto (fail closed) — never let a probe failure open the gate.
  if [ "$SWTOTAL" -ne 0 ] && [ "$SWFREE" -le "${MIN_SWAP_FREE:-600}" ] \
       && { [ "${MEM_UNKNOWN:-0}" = "1" ] || [ "${MEMAVAIL_MB:-0}" -le "$(( MIN_MEM_FREE_MB * 2 ))" ]; }; then
    GATE_WHY="${GATE_WHY:-swap_free=${SWFREE}M<=min_swap_free=${MIN_SWAP_FREE:-600}M AND mem_avail=${MEMAVAIL_MB}M<=$(( MIN_MEM_FREE_MB * 2 ))M (both tight)}"
    GATE_VEC="$GATE_VEC swap=REFUSE(swap_free=${SWFREE}M<=${MIN_SWAP_FREE:-600}M AND mem tight)"
  else GATE_VEC="$GATE_VEC swap=ok(free=${SWFREE}M, min=${MIN_SWAP_FREE:-600}M)"; fi
  # "A failed probe is UNKNOWN, not ample" is only true if MEM_UNKNOWN can be SET, and it is set
  # from mem_avail_mb()'s EXIT STATUS (its awk `exit 1`s on absent fields) rather than from an empty
  # string: awk's END block always ran, so `printf "%d"` yielded 0 for unset fields and a test for
  # an empty MEMAVAIL_MB could never be true. The helper is therefore tested on its own, above.
  if [ "${MEM_UNKNOWN:-0}" = "1" ]; then
    GATE_WHY="${GATE_WHY:-mem_probe_failed (capacity unknown -> do not add work)}"
    GATE_VEC="$GATE_VEC mem=UNKNOWN(the probe failed -> capacity unknown, do not add work)"
  else
    if [ "$MEMAVAIL_MB" -le "$MIN_MEM_FREE_MB" ]; then
      GATE_WHY="${GATE_WHY:-mem_avail=${MEMAVAIL_MB}M<=min_mem_free_mb=${MIN_MEM_FREE_MB}M}"
      GATE_VEC="$GATE_VEC mem=REFUSE(avail=${MEMAVAIL_MB}M<=min=${MIN_MEM_FREE_MB}M)"
    else GATE_VEC="$GATE_VEC mem=ok(avail=${MEMAVAIL_MB}M>min=${MIN_MEM_FREE_MB}M)"; fi
  fi
  # [gatevec:end]
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
    lo_select "$SEL_TOTAL" "${OWN_N:-0}" "${UPN_WORK:-${UPN:-?}}" "${SEL_PARKED:-0}" "${FIRST_PR:--}" "${GATE_WHY:-}" "$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')" "${PRDISP_ACTS:-}" "${PRDISP_WAITS:-}" "${PRDISP_REC:-unknown}" "${PRDISP_SPAWNS:-}" > "$SELFILE" 2>/dev/null || true
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
        # ── THE STALL IS ALSO AN ESCALATION (agent-infra#2590) ───────────────────────────────
        # The stall line alone escalated to nobody: it was printed 8 times on a live box that sat at
        # `lanes=0`, 9 un-owned, nothing landing for 3.4h, and its operator read the log as normal.
        # So a stall now ALSO writes an artifact that outlives the pass and puts a token on the cycle
        # status line — the one line every reader already parses — and it NAMES what the PR path did
        # in this very pass, because "nothing landed and we started nothing" and "nothing landed and
        # we started six workers" are different faults with the same symptom.
        # ⛔ THE ISSUE PATH STAYS CLOSED. The owner ruling (2026-10-18) is that a stalled drain is a
        # land/capacity problem and opening new work is how it gets hidden. This escalation must never
        # grow a release valve — it exists to make the promise VERIFIABLE, not to break it.
        # ⛔ AN UNMEASURED SPAWN COUNT IS NOT ZERO: with `PRDISP_SPAWNS` empty the line reports
        # UNMEASURED and the deadlock claim is about the LAND only, which is the measurement we have.
        _spk="${PRDISP_SPAWNS:-}"; is_num "${_spk:-}" || _spk=""
        _spn_txt="spawned UNMEASURED (the worker record could not be read)"
        is_num "${_spk:-}" && _spn_txt="spawned ${_spk} worker(s) this pass"
        _dpass=0
        [ -f "$O/state/drain-stall" ] && { _p="$(sed -n 's/^passes=//p' "$O/state/drain-stall" 2>/dev/null | head -1)"; is_num "${_p:-}" && _dpass="$_p"; }
        _dpass=$(( _dpass + 1 ))
        # ⛔ THE RECORD IS WRITE-CHECKED, like every other record this loop trusts: an escalation the
        # box cannot persist is an escalation that dies with the pass it was printed in.
        if printf 'at=%s\npasses=%s\nage=%s\nunowned=%s\nspawns=%s\nacts=%s\n' \
             "$(date +%s)" "$_dpass" "$_lage" "${UPN_WORK:-?}" "${_spk:-UNMEASURED}" "${PRDISP_ACTS:-UNMEASURED}" \
             > "$O/state/drain-stall" 2>/dev/null; then
          # ⛔ THE LABEL IS DERIVED, NOT HARD-CODED (review 3-P2). A STALLED pass records `spawns=4`
          # and `drain_stall_label` then prints STALLED, so promising "drain=DEADLOCK" here told the
          # operator to expect a token that is not there — the label drift the "one definition, two
          # readers" contract at drain_stall_label() exists to prevent. Computed on the SUCCESS path
          # only: a failed write must keep the COULD-NOT-RECORD message, not an ESCALATED one.
          _escl="$(drain_stall_label)"; [ -n "${_escl:-}" ] || _escl="UNMEASURED"
          _esc="ESCALATED -> state/drain-stall (pass ${_dpass}); the cycle status line now carries drain=${_escl} until a PR lands"
          # ── THE INERT-PATH COUNTER (#2831) ────────────────────────────────────────────────────
          # ⛔ WHAT MAKES THIS AN ACTION INSTEAD OF A LOG LINE. The stall has always been able to
          # say "nothing landed"; it could not say whether ANYONE STARTED ANYTHING, so a box whose
          # PR path was spawn-dead and a box whose workers were running but blocked read the same and
          # both idled. The counter advances ONLY on a MEASURED zero spawns (`_spk` empty =
          # UNMEASURED, which neither advances nor resets — inventing progress from a directory the
          # cycle could not read is the exact defect this file keeps deleting). Any spawn resets it,
          # so the owner's 2026-10-18 ruling keeps applying unchanged to every real land/capacity
          # stall; only the "started nothing" degenerate state is escaped from, and the escape is
          # bounded because it resets the counter after firing.
          # ⛔ THE GLUE IS GATED TOO (review P2): the module may be ABSENT on a box whose `$O` is
          # stale, and an unguarded call would print `pl_escape_bound: command not found` on launchd's
          # stderr (not `$LOG`) every cycle — invisible exactly where the operator reads.
          _escbound=${DRAIN_ESCAPE_PASSES:-3}
          if [ "${PL_MOD:-0}" = "1" ]; then
            _escbound="$(pl_escape_bound "${DRAIN_ESCAPE_PASSES:-}" 2>/dev/null)" || _escbound=3
            _streak="$(pl_note_pass "$O/state" "${_spk:-}" "${UPN_WORK:-}")"
            is_num "${_streak:-}" || _streak=0
            _esc="$_esc; the PR path has STARTED NOTHING for ${_streak}/${_escbound} consecutive stalled pass(es) — at ${_escbound} the issue path opens (state/pr-path-idle)"
          fi
        else
          _esc="ESCALATION COULD NOT BE RECORDED (state/ is unwritable) — this line is the only trace"
        fi
        # ⛔ THE POPULATION IS NAMED, BECAUSE THIS BOX IS NOT ALWAYS THE LANDER (MEASURED 2026-10-23).
        # `mp_recent_land` reads `state/merged-<PR>.done` and merge-one.sh is its ONLY writer, so the age
        # answers "when did THIS box last land", NOT "when did the queue last move". Measured here: 7 PRs
        # merged on the repo between 21:31Z and 22:40Z while this line said "no PR merged in 264m" — the
        # peer box held the landing claims (merge-9812.log: "landing claim REFUSED: held by … another box
        # is landing this PR"). Unqualified, the escalation names a land/capacity problem on a box whose
        # only "problem" is that it is not the lander — and an escalation that misdiagnoses is one an
        # operator learns to ignore, which is how this whole defect stayed invisible for 3.4h.
        # ⛔ AND THE PASS'S OWN LEDGER IS QUOTED: when it spawned nothing, the dominant NAMED wait IS the
        # reason, and it is already computed above (`PRDISP_TOP`). A datum the line holds and does not
        # read is the "tool that cannot answer its own question" class.
        _whysrc=" (land markers are THIS box's own merge-one successes only — a peer box landing these is invisible here"
        # ⛔ THE EXAMINED ROWS' REASONS COME FIRST (agent-infra#2933). This line used the modal wait across
        # ALL rows, which is the deferred-majority masking defect again on the escalation line — the
        # escalation would have named "outside this cycle's sweep window" as the reason the box is stuck.
        # The window's grouped reasons are already computed above; `PRDISP_TOP` survives only as the
        # fallback for a cycle with no window (where every row IS the population).
        if [ -n "${PRDISP_WIN_REASONS:-}" ]; then
          _whysrc="$_whysrc; examined-row reasons: \"${PRDISP_WIN_REASONS:0:140}\""
        elif [ -n "${PRDISP_TOP:-}" ]; then
          _whysrc="$_whysrc; dominant named wait: \"${PRDISP_TOP:0:140}\""
        fi
        _whysrc="$_whysrc)"
        if [ "${_spk:-}" = "0" ]; then
          echo "[dispatch] DRAIN DEADLOCK — no PR merged in ${_lage}m, ${UPN_WORK:-?} un-owned remain, and this pass STARTED NO WORKER (0 worker records created; ${PRDISP_ACTS:-?} disposition action(s), none of which spawns)${_whysrc}. The issue path stays CLOSED (owner ruling 2026-10-18: no new work while un-owned PRs remain) — this pass escalates instead of opening work. ${_esc}.${_refsuf:-}" >> "$LOG"
        else
          # ⛔ AN UNMEASURED COUNT MUST NOT CARRY A POSITIVE DIAGNOSIS (review 2-P2). "the workers run
          # and nothing lands" is a claim ABOUT SPAWNS, and the UNMEASURED arm did not measure them —
          # the same claim-without-a-measurement defect this change deletes, sign-reversed.
          if is_num "${_spk:-}"; then
            _spn_tail="the workers run and nothing lands, which is a LAND problem, not an idle one"
          else
            _spn_tail="this pass cannot say whether any worker was started — the LAND problem is measured, the spawn reading is not"
          fi
          echo "[dispatch] DRAIN STALLED — no PR merged in ${_lage}m while ${UPN_WORK:-?} un-owned remain, and this pass ${_spn_txt}${_whysrc} — ${_spn_tail}. The issue path stays CLOSED (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work. ${_esc}.${_refsuf:-}" >> "$LOG"
        fi
      else
        echo "[dispatch] drain alive — last land ${_lage}m ago; ${UPN_WORK:-?} un-owned remain" >> "$LOG"
        # A land clears the escalation: a marker that outlives its condition is a stale flag.
        rm -f "$O/state/drain-stall" 2>/dev/null || true
        # ⛔ A LAND ALSO CLEARS THE INERT STREAK (review P2). Without this the counter described "stalled
        # passes since the last escape" rather than "CONSECUTIVE stalled passes": a box that stalled
        # N-1 times, landed for hours, then stalled once opened the issue path on its FIRST stall while
        # its own line claimed N — a false statement about consecutiveness and a bound quietly cut to 1.
        [ "${PL_MOD:-0}" = "1" ] && pl_streak_reset "$O/state"
      fi
    elif [ "${_land_any:-0}" = "1" ]; then
      echo "[dispatch] DRAIN STALLED — no PR merged within the last $(( 10#${MERGE_PRIORITY_MAX_AGE_MIN:-180} * 2 ))m while ${UPN_WORK:-?} un-owned remain. The issue path stays CLOSED (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work.${_refsuf:-}" >> "$LOG"
    fi
    # [drain-health:end]
  else
    # [drain-clear:begin] (extracted and DRIVEN by test-gates.sh — keep the marker)
    # ⛔ THE MARKER MUST NOT OUTLIVE ITS CONDITION WHEN THE DRAIN ENDS (review 1-P1). This whole
    # block runs ONLY while `LO_CHOICE=pr`, and it holds the only unlock-keyed clear — so a box that
    # stalled (marker written, `unowned=9`) and then saw those rows merged by a PEER box fell to
    # `LO_CHOICE=issue` with nothing to delete the marker: `drain_stall_token` runs on EVERY cycle and
    # keeps printing `drain=DEADLOCK(passes=7,unowned=9,…)` on the status line forever, with a count
    # that is no longer true and an age that only grows. That is exactly the stale-flag class this
    # escalation's own comment claims to eliminate, and a false DEADLOCK is how an operator learns to
    # ignore a real one. Clear it on a MEASURED zero, and only then: an unreadable UPN_WORK is not
    # "no un-owned PRs" and must leave the marker alone (fail-closed).
    if is_num "${UPN_WORK:-}" && [ "$UPN_WORK" -eq 0 ]; then
      rm -f "$O/state/drain-stall" 2>/dev/null || true
    fi
    # [drain-clear:end]
  fi
  # [drain-escape:begin] (DRIVEN by pr-owner-liveness.test.sh through the module; the WIRING here is
  # reviewed, not extracted — keep the markers)
  # ⛔ THE DETECTOR NOW ACTS (agent-infra#2831 ask 2). Measured on the live box: `DRAIN STALLED — no PR
  # merged within the last 360m while 3 un-owned remain. The issue path stays CLOSED` printed pass
  # after pass while the PR path had spawned nothing in 93 cycles. The box could neither land nor open
  # work — a detector that cannot act is a log line, not a control.
  # ⛔ THE RULING IS KEPT WHERE IT APPLIES. "No new work while un-owned PRs remain" exists so a
  # stalled drain cannot be hidden behind fresh activity. That reasoning holds while the PR path is
  # WORKING; it does not hold when the PR path has started nothing for N consecutive stalled passes,
  # because then nothing is being hidden and nothing is being drained. Any spawn resets the streak, so
  # a land/capacity stall (workers running, nothing landing) still never opens the issue path —
  # unchanged. OVERRIDES: the 2026-10-18 "never a release valve" ruling, for the "started nothing"
  # state only, bounded and logged here with the counts the decision was taken from.
  # ⛔ ONE ESCAPE PER N INERT PASSES, NOT ONE PER PASS: `pl_escape_record` resets the streak on a
  # successful write, so the loop cannot spin, and it reports when the record could NOT be written.
  _eb=${DRAIN_ESCAPE_PASSES:-3}
  if [ "${PL_MOD:-0}" = "1" ]; then _eb="$(pl_escape_bound "${DRAIN_ESCAPE_PASSES:-}" 2>/dev/null)" || _eb=3; fi
  if [ "${LO_CHOICE:-none}" != "pr" ]; then
    # Not blocked by un-owned PRs: a streak from an earlier stall is a stale flag and is cleared.
    [ "${PL_MOD:-0}" = "1" ] && pl_streak_reset "$O/state"
  elif [ "${PL_MOD:-0}" = "1" ] && pl_escape_open "$O/state" "${UPN_WORK:-}" "$_eb"; then
    printf '%s\n' "$(pl_escape_line "$O/state" "${UPN_WORK:-}" "$_eb")" >> "$LOG"
    if PL_ESCAPE_BOUND="$_eb" pl_escape_record "$O/state" "${UPN_WORK:-}" "${PRDISP_SPAWNS:-}"; then
      echo "[dispatch] DRAIN ESCAPE RECORDED -> state/drain-escape (issue path OPEN this cycle; the inert-path counter reset to 0, so the next escape needs $_eb more stalled pass(es))" >> "$LOG"
    else
      echo "[dispatch] DRAIN ESCAPE RECORD COULD NOT BE WRITTEN (state/ is unwritable) — the issue path still OPENS this cycle (an unpersisted action must not be withheld), but the counter could not be reset and the bound cannot be proven" >> "$LOG"
    fi
    # ⛔ `GATE_WHY` MUST BE CLEARED, OR THE ESCAPE IS A LOG LINE THAT CANNOT ACT (review P0, 2026-10-25).
    # It was set from the SAME un-owned count earlier in this pass (`GATE_WHY="$(mp_reason ...)"`, which
    # echoes a reason whenever un-owned > 0), and the ONE line that opens the dispatch block is
    # `if [ -z "$GATE_WHY" ]`. Setting LO_CHOICE alone therefore printed "OPENING the issue path",
    # recorded the escape, reset the counter — and dispatched NOTHING, for ever. The gate is precisely
    # what the escape exists to lift, so the lift is named in the log.
    _lifted="${GATE_WHY:-<none>}"
    GATE_WHY=""
    echo "[dispatch] DRAIN ESCAPE lifted the issue-path gate (was: ${_lifted}) — the merge-priority gate is what this escape overrides for one cycle" >> "$LOG"
    LO_CHOICE=issue
  fi
  # [drain-escape:end]
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
    # ── THE PRODUCT FLOOR, APPLIED AS AN ORDER (agent-infra#2054) ───────────────────────────────
    # ⛔ IT REACHES THE DISPATCH LOOP ONLY AS A DIFFERENT FILE TO READ, so every contract below is
    # inherited unchanged and none is re-implemented: the `dispatched.txt` check stays first in the
    # body, the pre-flight verdict is unchanged (the whole backlog is already pre-flighted), and the
    # cross-box claim still decides each issue. A product candidate that is COLLIDING is skipped by the
    # existing arms exactly as before — the floor never force-dispatches anything.
    # ⛔ AND IT IS HERE, NOT EARLIER: this branch is reached only after `mp_reason` found no reason to
    # drain, so merge priority still wins outright and the floor cannot delay a batch.
    FLOOR_N="$(floor_norm "${PRODUCT_FLOOR:-1}" "${BATCH:-1}")"
    # ── AN EMERGENCY OUTRANKS THE FLOOR (agent-infra#2054) ─────────────────────────────────────────
    # ⛔ ASKED BEFORE THE ORDER IS CHOSEN, because the answer decides whether there IS a floor order to
    # choose. `floor_emergency` reads only state already on disk (the refresh's `state/emergency-class`
    # + `candidates.emergency.txt`, and the sweep's `state/railrefusal-*`), so this costs no API call and
    # cannot fail into an unknown: an unreadable class yields `p0-unknown(...)`, which stands the floor
    # down. Standing down is the safe direction — a missed product slot costs one cycle, a P0 delayed
    # behind a share target does not. The verdict (with counts) is printed after the batch below, beside
    # the MET/unmet lines, so one cycle cannot report two different things about the same batch.
    FLOOR_ASKED="$FLOOR_N"; FLOOR_EMERGENCY=""
    if [ "${FLOOR_ASKED:-0}" -gt 0 ] 2>/dev/null; then FLOOR_EMERGENCY="$(floor_emergency "$O" "${BATCH:-1}")"; fi
    if [ -n "$FLOOR_EMERGENCY" ]; then FLOOR_N=0; fi
    ORDER_FILE="$(floor_choose_order "$O" "$FLOOR_N")"
    # ⛔ `$ORDER_FILE` EXISTING IS NOT "PRODUCT WENT FIRST" (review cycle 11, P2). This line printed
    # "ordered from … first" whenever `.order` existed, including when ZERO product entries led the batch
    # — a routine state, not an exotic one: dispatched ids are pruned from `candidates.txt` at the top of
    # every dispatch, so after a product candidate is dispatched the QUEUE still names it while the
    # backlog no longer does — and the queues are re-derived ONLY when the backlog is SHORT (`[ "$BL" -lt 6 ]`,
    # the sole refresh spawn site), so in the busy case, which is the case the floor exists for, the queue
    # can name a dispatched issue for as long as the backlog stays long. The line
    # then contradicted the two lines under it (`product=0/2 …`, `product-floor unmet … no dispatchable
    # product candidate`) — the routine case in the same words as the real failure. Count what actually
    # led, and say that.
    if [ "${FLOOR_N:-0}" -gt 0 ] 2>/dev/null && [ "$ORDER_FILE" = "$O/.order" ]; then
      _led=0
      while read -r _n; do
        [ -n "$_n" ] || continue
        grep -qx -- "$_n" "$O/candidates.product.txt" 2>/dev/null && _led=$((_led+1))
      done < <(head -"$FLOOR_N" "$O/.order" 2>/dev/null)
      if [ "$_led" -gt 0 ]; then
        # ⛔ `batch-cap=`, NOT `batch=` (review cycle 20, P2). This block runs BEFORE the batch is built, so
        # only the CAP is known here; every other floor line in the same cycle prints `batch=` for the
        # COUNT (`K`, `product=$PB/$K in this batch`). One label for two quantities is the ambiguity cycle 9
        # removed from the `product=` phrase, so the cap gets its own word.
        echo "[dispatch] product-floor=$FLOOR_N of batch-cap=$BATCH — $_led product entr$( [ "$_led" -eq 1 ] && echo y || echo ies ) of $O/candidates.product.txt led the order" >> "$LOG"
      else
        echo "[dispatch] product-floor=$FLOOR_N of batch-cap=$BATCH — .order exists but NO product entry led it ($O/candidates.product.txt names none that are still in the backlog), so this batch is not a product-led batch" >> "$LOG"
      fi
    fi
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
        if [ "${CAPACITY_YIELD_GATE:-}" = "land" ]; then
          echo "[dispatch] #$ISS stood down — this box refused it at the LAND-BACKLOG gate (the repo's open-PR backlog is over its own landing ceiling; repo-wide, so NO peer can clear it by waiting — the remedy is to land an open PR) until the yield expires (${CAPACITY_YIELD_WHY})" >> "$LOG"
        else
          echo "[dispatch] #$ISS yielded to peers — this box refused it for capacity and is standing down until the yield expires (${CAPACITY_YIELD_WHY})" >> "$LOG"
        fi
        continue
      fi
      # ── PLACEMENT: the LEAST-LOADED ELIGIBLE BOX takes it (measured, agent-infra 2026-10-21) ─────
      # Only reached when some box IS eligible and it is not this one. `continue` WITHOUT touching
      # `dispatched.txt` and WITHOUT taking the claim: the item stays in `candidates.txt` (so this box
      # takes it back if it quietens and the peer stops publishing) and stays unowned in the shared
      # registry (so the chosen box's next refresh pass can claim it). Consuming its turn here would
      # be #1909's parked-the-issue failure again, driven by a MEASUREMENT instead of a refusal.
      # ⛔ AND ONLY WHEN THIS BOX IS ACTUALLY PILING UP (the PREFER-ELSEWHERE line). Yielding on every
      # candidate to whichever peer happens to be a little idler is a THRASH machine: the fleet stands
      # down while all of it is healthy and the work waits for a box that may never pick it up. Below
      # CAP_YIELD_AT_LPC this box TAKES the work; at or above it, it hands it to the less-loaded box.
      if [ "${CAP_STATE:-unavailable}" = "place" ] && [ -n "${CAP_PLACE:-}" ] && [ "$CAP_PLACE" != "$(cap_host)" ] \
         && is_num "${CAP_LPC_SELF:-}" && [ "${CAP_LPC_SELF:-0}" -ge "${CAP_YIELD_AT_LPC:-400}" ]; then
        Y=$((Y+1))
        echo "[dispatch] #$ISS placed-on ${CAP_PLACE} — least-loaded eligible box (this box lpc=${CAP_LPC_SELF:-?} >= prefer-elsewhere ${CAP_YIELD_AT_LPC:-400}); left unclaimed and un-consumed so ${CAP_PLACE} can take it" >> "$LOG"
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
        echo "[dispatch] #$ISS NOT dispatched — \$O/claims.sh predates the issue key (no claim_issue_acquire), so this box cannot take the claim; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator" >> "$LOG"
        continue
      else
        echo "[dispatch] ⚠️ #$ISS: no claim registry at \$O/claims.sh — dispatching WITHOUT a cross-box claim (seed it: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator)" >> "$LOG"
      fi
      echo "$ISS" >> "$O/.batch"; echo "$ISS" >> "$O/dispatched.txt"; K=$((K+1)); [ "$K" -ge "$BATCH" ] && break
    done < "$ORDER_FILE"
    # ⛔ AN UNMET FLOOR LOGS AND DEGRADES (indicator (b)) — and it carries the QUEUE-STATE TOKEN, because
    # otherwise `product-floor unmet` on a blind intake is indistinguishable from "there is no product
    # work", which is the #2042/#1931 masking failure in a new place. A batch is NEVER refused for it:
    # refusing to dispatch because no product candidate was available would be a worse failure than the
    # one the floor exists to prevent, and the fleet must not idle to satisfy a share target.
    if [ -n "${FLOOR_EMERGENCY:-}" ]; then
      # ⛔ THE OVERRIDE IS LABELLED (agent-infra#2054). A floor that silently stopped applying would be
      # indistinguishable from a floor nobody asked for, and the whole point of the guarantee is that its
      # state is legible: OVERRIDDEN names the emergency, the floor it displaced, and the batch it did not
      # govern. Counts are measured here, not assumed — `PB` is the product share the batch actually got.
      PB=0
      if [ -s "$O/.batch" ] && [ -s "$O/candidates.product.txt" ]; then
        while read -r _p; do
          [ -n "$_p" ] || continue
          grep -qx -- "$_p" "$O/.batch" 2>/dev/null && PB=$((PB+1))
        done < <(awk '!seen[$0]++' "$O/candidates.product.txt")
      fi
      # ⛔ THE WORDING MUST SURVIVE AN EMPTY BATCH (K=0 is reachable: an emergency is live and every
      # candidate was skipped, yielded or claimed). "dispatched in plain severity order" would be a claim
      # about a dispatch that did not happen, so the line states what it measured — the floor was not
      # applied, and this is what the batch held — and leaves the plain-FIFO consequence to the order.
      echo "[dispatch] product-floor OVERRIDDEN emergency=$FLOOR_EMERGENCY — its $FLOOR_ASKED slot(s) were NOT applied to this batch, which was filled in the backlog's own severity order (product=$PB batch=$K); an emergency outranks a share target and the floor is never a gate. queue=$(queue_state_token)" >> "$LOG"
    elif [ "${FLOOR_N:-0}" -gt 0 ] 2>/dev/null; then
      # ⛔ NOTHING WAS DISPATCHED, SO NO SLOT WAS OWED (review cycle 18, P1). The arms below were selected by
      # whether a FILE was empty, not by whether a BATCH existed — so an idle box (`K=0`: the backlog is
      # drained, or every candidate was skipped) reported `product-floor unmet`, in exactly the words used for
      # the real failure, and the SAME empty cycle reported `N/A` on a non-product repo and NOTHING when the
      # product queue was non-empty: three verdicts for one shape. `unmet` is a claim about a share that was
      # owed and missed; with an empty batch nothing was owed. The block's own comments say the routine case
      # must never share its words with the real failure — this is that rule applied to the routine case.
      if [ "${K:-0}" -le 0 ]; then
        # ⛔ MEASURE IT HERE — DO NOT READ `$BL` (review cycle 19, P0). `BL` is assigned LATER in the same
        # iteration (in the refresh block, after this one), so under `set -u` the expansion was FATAL: the
        # controller EXITED on the first cycle of any box that dispatched nothing — which is every fresh
        # install, since `candidates.txt` is touched empty above and the refresh that fills it is spawned
        # after this block. Under launchd KeepAlive that is a crash loop. It was green because the test
        # fixture supplied `BL` itself; the number is derived here, from the file this line describes.
        BL_NOW=""; [ -f "$O/candidates.txt" ] && BL_NOW="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ' || :)"
        echo "[dispatch] product-floor not evaluated — the batch is EMPTY (backlog=${BL_NOW:-0}, nothing was dispatched this cycle), so no floor slot was owed. queue=$(queue_state_token)" >> "$LOG"
      elif [ -s "$O/.batch" ] && [ -s "$O/candidates.product.txt" ]; then
        PB=0
        while read -r _p; do
          [ -n "$_p" ] || continue
          grep -qx -- "$_p" "$O/.batch" 2>/dev/null && PB=$((PB+1))
        done < <(awk '!seen[$0]++' "$O/candidates.product.txt")
        echo "[dispatch] product=$PB/$K in this batch (floor=$FLOOR_N)" >> "$LOG"
        # ⛔ A NON-EMPTY QUEUE MUST NOT SILENCE THE RECORD (review cycle 16, P2). The recorded class was read
        # ONLY in the `elif [ ! -s candidates.product.txt ]` arm, so any non-empty product queue skipped it —
        # including a STALE one, which is exactly the state `wpq_degrade` discloses ("may still hold a previous
        # pass's split … do not read that as a class") and the state a dispatched-then-pruned issue leaves
        # behind. The floor then reported itself MET from a queue the intake had just declared untrustworthy,
        # and a `PENDING` record ("no split has run") was presented as a measurement. So: read the record
        # HERE too, and whenever it is not a completed split, say so beside the count — a met floor is only
        # credible if the class behind it was actually read.
        _PB_WHY="$(head -1 "$O/state/product-class" 2>/dev/null || true)"
        case "${_PB_WHY:-}" in
          # ⛔ AN `OK` PREFIX IS NOT A CLAIM ABOUT *THESE* FILES HERE EITHER (review cycle 25, P1). Cycles
          # 21/22 taught the EMPTY-queue arm to cross-check the record's own counts; this arm — the one that
          # reports the floor as MET — still accepted the record on its prefix alone, so a stale
          # `OK product=0 harness=1` beside a queue that now holds a product candidate was published as a
          # trustworthy measurement with no disclosure. A met floor is only credible if the class behind it
          # describes the files on disk, so the same comparison runs here, against the FILES.
          OK*)
            _rec_p="${_PB_WHY#*product=}"; _rec_p="${_rec_p%%[!0-9]*}"
            _rec_h="${_PB_WHY#*harness=}"; _rec_h="${_rec_h%%[!0-9]*}"
            # guarded on existence: a redirect failure is NOT silenced by `2>/dev/null` (measured)
            _fq_p=""; [ -f "$O/candidates.product.txt" ] && _fq_p="$(wc -l < "$O/candidates.product.txt" 2>/dev/null | tr -d ' ' || :)"
            _fq_h=""; [ -f "$O/candidates.harness.txt" ] && _fq_h="$(wc -l < "$O/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :)"
            if [ -n "$_rec_p" ] && { [ "${_fq_p:-0}" != "$_rec_p" ] || { [ -n "$_rec_h" ] && [ "${_fq_h:-0}" != "$_rec_h" ]; }; }; then
              echo "[dispatch] product=$PB/$K is NOT a trustworthy floor measurement — the queue files hold product=${_fq_p:-0} harness=${_fq_h:-0} but state/product-class says [${_PB_WHY}], a record that does NOT describe these files; the count above describes the FILES, not a class this pass read. queue=$(queue_state_token)" >> "$LOG"
            fi ;;
          *) echo "[dispatch] product=$PB/$K is NOT a trustworthy floor measurement — state/product-class says [${_PB_WHY:-UNRECORDED: no record at all}], so this queue may hold a previous split; the count above describes the FILES, not a class this pass read. queue=$(queue_state_token)" >> "$LOG" ;;
        esac
        # ⛔ A SHORTFALL IS UNMET TOO, NOT ONLY A ZERO (review cycle 5, P2). This tested `-eq 0`, so with
        # `PRODUCT_FLOOR=2` a batch that filled one product slot emitted NO unmet line at all: the count
        # line said `product=1/2 in this batch (floor=2)` and the queue token — the thing that makes
        # "no product work" distinguishable from "we could not read the class" — was never printed. The
        # default floor of 1 makes it latent, which is exactly why it has to be driven rather than
        # reasoned about. Both arms carry the token; only the wording differs.
        if [ "$PB" -lt "$FLOOR_N" ]; then
          # ⛔ THE TWO NUMBERS ARE NAMED, SO THE LOG CANNOT CONTRADICT ITSELF (review cycle 9, P2). The
          # count line above says `product=$PB/$K in this batch` (a share of the BATCH); this line said
          # `product = $PB/$FLOOR_N in this batch`, giving the same phrase a second denominator — the
          # floor, not the batch — so the same cycle printed `product=0/2` and `product = 0/1` about one
          # batch. Neither number is guessed here: `batch=$K`, `floor=$FLOOR_N`, `product=$PB`.
          echo "[dispatch] product-floor unmet (product=$PB batch=$K floor=$FLOOR_N — $([ "$PB" -eq 0 ] && echo "no dispatchable product candidate" || echo "a SHORTFALL, not a zero")) queue=$(queue_state_token) — the floor never refuses a batch, so the batch still goes to dispatch; whether the CI-queue gate DEFERRED it is stated below (a deferral sets K=0)" >> "$LOG"
        else
          # ⛔ THE MET VERDICT IS PRINTED, NOT INFERRED FROM SILENCE (agent-infra#2054 indicator (a)). The
          # arms above only ever spoke when the floor MISSED, so "the floor worked" was the absence of a
          # line — indistinguishable from a floor that never ran (a disabled knob, a repo off
          # PRODUCT_REPOS, an order file that was never chosen). One line, with both numbers, makes the
          # report say MET or UNMET in every cycle the floor was applied.
          echo "[dispatch] product-floor MET product=$PB batch=$K floor=$FLOOR_N" >> "$LOG"
        fi
      elif [ ! -s "$O/candidates.product.txt" ]; then
        # ⛔ THIS ARM SAYS "UNKNOWN", NOT "NONE" (cycle-1 review, P2). The original wording reused
        # "(no dispatchable product candidate)", which is an assertion about a class this box never
        # managed to READ — the #2042/#1931 masking shape, in the one line that exists to expose it.
        # ⛔ AND IT NAMES THE RECORDED REASON (review cycle 2, P2): the refresh already KNOWS why the
        # queue is empty (`state/product-class`, written by `write_product_queues`), so asking the
        # operator "is this repo in PRODUCT_REPOS, and did the pass list the harness label?" asked a
        # question that was already answered — and on a repo that is simply NOT a product repo it asked
        # it EVERY pass, which is how a routine case masks the real one (the failure this arm exists to
        # expose). A recorded NOT-A-PRODUCT-REPO is reported as N/A: not an unmet floor, and not a
        # finding about product work.
        # ⛔ AND A `PENDING` RECORD IS AN UNREAD CLASS, not the last pass's measurement (review cycle 3,
        # P2; the mechanism was corrected in cycle 6 and this comment follows the CODE — do not restore a
        # pass-entry invalidation, see `refresh-candidates.sh`'s note above `mkdir -p "$O/state"`). The
        # WRITER invalidates this record as its first action, so a pass that started the split and died
        # before recording an arm leaves `PENDING …` instead of the PREVIOUS pass's `OK product=0
        # harness=3` — which this arm would otherwise repeat as "the split
        # RAN and found none" about a pass that measured nothing. `PENDING` falls to the UNKNOWN arm
        # below on purpose: it carries its own sentence saying no split has run.
        PC_WHY="$(head -1 "$O/state/product-class" 2>/dev/null || true)"
        PC_WHY="${PC_WHY:-UNRECORDED — no refresh pass has recorded a product class (is this repo in PRODUCT_REPOS, and did the pass list the harness label?)}"
        case "$PC_WHY" in
          NOT-A-PRODUCT-REPO*)
            echo "[dispatch] product-floor N/A — the product queue is empty because ${PC_WHY}; this is NOT an unmet floor and NOT a finding about product work. dispatched $K issue(s)" >> "$LOG" ;;
          # ⛔ A MEASURED EMPTY QUEUE IS NOT AN UNREAD ONE (review cycle 2b, P2). `OK product=0 harness=<n>`
          # means the split RAN and every remaining candidate is harness-labelled. That used to fall into
          # the UNKNOWN arm below, which printed "no product candidate could be COUNTED" beside a `reason=`
          # proving it HAD been counted — and because it is the routine all-harness pass on the default
          # product repo, an operator grepping `UNKNOWN` for a blind intake got a false positive every
          # pass. That is the same masking the NOT-A-PRODUCT-REPO arm above was added to remove, one arm
          # over: the line must under-claim exactly as carefully as it over-claims nothing.
          OK*)
            # ⛔ AN `OK` PREFIX IS NOT A CLAIM ABOUT *THESE* FILES (review cycle 21, P2). The writer returns
            # success after a FAILED record write on purpose, so the PREVIOUS pass's `OK product=N …` keeps
            # standing beside queues it no longer describes — and this arm repeated it as "the split RAN and
            # found none", publishing a stale count as this pass's measurement (the #2042 masking shape one
            # arm over). Compare the record's own number with the queue it claims to describe; when they
            # disagree, say that rather than inheriting either claim.
            # ⛔ BOTH NUMBERS, NOT JUST ONE (review cycle 22, P2). The record carries `product=` AND
            # `harness=`; cross-checking only the first still published a stale `harness=` as this pass's
            # measurement (`OK product=0 harness=5` beside a 3-line harness queue printed "the split RAN and
            # found none … harness=5"). Every count the record claims to have measured is checked against
            # the file it describes, so a printed count can never contradict the disk.
            _rec_p="${PC_WHY#*product=}"; _rec_p="${_rec_p%%[!0-9]*}"
            _rec_h="${PC_WHY#*harness=}"; _rec_h="${_rec_h%%[!0-9]*}"
            # ⛔ GUARDED ON EXISTENCE: a `> file` / `< file` REDIRECT failure is NOT silenced by
            # `2>/dev/null` on the same command (measured — the shell reports it before the command runs), so
            # an ABSENT queue put a `No such file or directory` line in the log instead of reading as 0.
            _pq_n=""; [ -f "$O/candidates.product.txt" ] && _pq_n="$(wc -l < "$O/candidates.product.txt" 2>/dev/null | tr -d ' ' || :)"
            _hq_n=""; [ -f "$O/candidates.harness.txt" ] && _hq_n="$(wc -l < "$O/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :)"
            if [ -n "$_rec_p" ] && { [ "${_pq_n:-0}" != "$_rec_p" ] || { [ -n "$_rec_h" ] && [ "${_hq_n:-0}" != "$_rec_h" ]; }; }; then
              echo "[dispatch] product-floor unmet (the product queue is EMPTY and the files hold product=${_pq_n:-0} harness=${_hq_n:-0}, but the record beside them says '${PC_WHY}' — a record that does NOT describe these queues, so this is not a measurement of product work; treat the class as unread) queue=$(queue_state_token) — the floor never refuses a batch, so the batch still goes to dispatch; whether the CI-queue gate DEFERRED it is stated below (a deferral sets K=0)" >> "$LOG"
            else
              echo "[dispatch] product-floor unmet (no dispatchable product candidate — the split RAN and found none: ${PC_WHY}) queue=$(queue_state_token) — the floor never refuses a batch, so the batch still goes to dispatch; whether the CI-queue gate DEFERRED it is stated below (a deferral sets K=0)" >> "$LOG"
            fi ;;
          *)
            echo "[dispatch] product-floor unmet (product class UNKNOWN — $O/candidates.product.txt is absent or empty, so no product candidate could be counted) reason=${PC_WHY} queue=$(queue_state_token) — the floor never refuses a batch, so the batch still goes to dispatch; whether the CI-queue gate DEFERRED it is stated below (a deferral sets K=0)" >> "$LOG" ;;
        esac
      fi
    fi
    if [ -s "$O/.batch" ]; then
      echo "[dispatch] load=$L lanes=${LANES_DISPLAY:-$LANES} -> $(tr '\n' ' ' < "$O/.batch")" >> "$LOG"
      # ⛔ A DEFERRED BATCH WAS NOT DISPATCHED (#2296 cycle 6, P2). `K` was incremented as each issue
      # was CLAIMED, before this call — so a batch that the CI-queue gate refused would otherwise be
      # counted here, in the funnel and in the cycle record, as work that happened. `dispatch-merge.sh`
      # exits 3 on a deferral (after releasing the claims and dropping the rows); this reads it and
      # records `dispatched=0` with the gate named, which is the same fact its own log line states.
      _dmrc=0
      # The recount below reads a file THIS call writes, so a stale one must not be mistaken for it.
      rm -f "$O/.dispatched-ids" 2>/dev/null || true
      bash "$O/dispatch-merge.sh" "$REPO" "$OR" $(tr '\n' ' ' < "$O/.batch") >> "$LOG" 2>&1 || _dmrc=$?
      if [ "$_dmrc" = "3" ]; then
        echo "[dispatch] ci-queue gate DEFERRED the whole batch ($K issue(s)) — nothing was dispatched; claims released, rows dropped, re-decided next cycle" >> "$LOG"
        K=0; : > "$O/.batch"
        [ -n "${GATE_WHY:-}" ] || GATE_WHY="ci-queue(batch deferred)"
      elif [ "$_dmrc" = "72" ]; then
        # ⛔ A REPO-IDENTITY REFUSAL IS NOT A DISPATCH EITHER (#2762 review, P1). Same shape as the
        # deferral arm above: `K` was incremented as each issue was CLAIMED, so without this branch a
        # batch that `dispatch-merge.sh` refused with 72 is counted as `-> N dispatched` and written
        # into the cycle record as `dispatched=N … nothing=none` — a permanent false PASS, because a
        # wrong-repo pair does not clear by waiting. The claims are released and the rows dropped by
        # dispatch-merge.sh itself; only the counting and `.batch` need undoing here.
        echo "[dispatch] repo-target gate REFUSED the whole batch ($K issue(s)) — nothing was dispatched; claims released, rows dropped, re-decided next cycle" >> "$LOG"
        K=0; : > "$O/.batch"
        [ -n "${GATE_WHY:-}" ] || GATE_WHY="repo-target(refused: checkout is not the target)"
      # ⛔ RECOUNT FROM WHAT ACTUALLY SPAWNED (#2762 review, 2nd cycle, P1). `K` counts CLAIMS, and a
      # PER-ISSUE refusal (`continue` in dispatch-merge.sh) leaves the batch's exit status 0 — so a
      # batch whose every lane was refused still printed `-> N dispatched` and recorded
      # `dispatched=N … nothing=none`. That path is reachable in the field (the branch assertion runs
      # against a REUSED `.worktrees/tm-<N>`, e.g. one left on another named branch), and a wrong-repo
      # pair never clears by waiting, so the record would be a permanent false PASS. dispatch-merge.sh
      # publishes the ids that reached a spawn; the cycle's count and ids come from that, not claims.
      # ⛔ THE RECOUNT IS AN `elif` OF THE SAME CHAIN, NOT A SIBLING `if` (#2762 review, 5th cycle,
      # P1). `product-floor.test.sh` P6 pins that every `.batch` reset sits INSIDE a modelled arm of
      # this chain, because a reset outside one is how a batch that started nothing gets recorded as
      # dispatched. A sibling `if` with its own `_dmrc` guard is equivalent in behaviour but invisible
      # to that rule — the suite reds, correctly, on a reset it cannot attribute to an arm.
      # markers: the BODY is extracted and driven by repo-target.test.sh (D6), so they sit inside.
      elif [ -f "$O/.dispatched-ids" ]; then
        # [dmrecount:begin] (extracted and DRIVEN by repo-target.test.sh — keep the markers)
        _dm_spawned="$(sed '/^$/d' "$O/.dispatched-ids" 2>/dev/null || true)"
        _dm_n="$(printf '%s\n' "$_dm_spawned" | sed '/^$/d' | wc -l | tr -d ' ')"
        is_num "${_dm_n:-}" || _dm_n=0
        if [ "$_dm_n" -ne "$K" ]; then
          # ⛔ NAME NO CAUSE (#2762 review, 3rd cycle, P2). `.dispatched-ids` carries bare ids, so a
          # delta between claims and spawns can be a repo-identity refusal, a launcher refusal, or a
          # claim/login skip — the `[repo-target]`/spawn lines in the dispatch log name the cause. An
          # attributed reason here wrote "repo-target refused 1" into the durable cycle record for a
          # launcher failure (where the claim is deliberately KEPT because chain-<N> is alive).
          echo "[dispatch] $((K - _dm_n)) of $K issue(s) did not reach a spawn — counted only the $_dm_n that did (see the dispatch log for the cause)" >> "$LOG"
          K="$_dm_n"
          if [ "$K" -gt 0 ]; then
            printf '%s\n' "$_dm_spawned" > "$O/.batch"
          else
            : > "$O/.batch"
            [ -n "${GATE_WHY:-}" ] || GATE_WHY="dispatch(no lane reached a spawn — see the dispatch log for the cause)"
          fi
        fi
        # [dmrecount:end]
      else
        # [dmnofile:begin] (extracted and DRIVEN by repo-target.test.sh — keep the markers)
        # ⛔ `dispatch-merge.sh` DID NOT RUN AT ALL (#2762 review, 6th cycle, P2). `rm -f` above removed a
        # stale `.dispatched-ids`, so when the call itself cannot execute — bash returns 127 because the
        # script is absent from a HALF-DEPLOYED `$O`, or 126 because it is not executable — no arm above
        # matches, no file is published, and the chain fell through with `K` still counting CLAIMS: the
        # funnel then recorded `dispatched=N … nothing=none` for a batch that spawned nothing. That is
        # the permanent false PASS the recount exists to remove, surviving in the one shape this change is
        # otherwise about (a partial `$O`), so it is its OWN counted arm rather than a silent skip. The
        # cause is named here because `_dmrc` is unambiguous (the call produced no file AND failed), unlike
        # the delta branch above where bare ids cannot say what refused.
        echo "[dispatch] dispatch-merge.sh produced no .dispatched-ids (rc=$_dmrc) — nothing was dispatched; the batch is re-decided next cycle" >> "$LOG"
        K=0; : > "$O/.batch"
        [ -n "${GATE_WHY:-}" ] || GATE_WHY="dispatch(dispatch-merge.sh did not run: rc=$_dmrc)"
        # [dmnofile:end]
      fi
      # …and the deferral's reason rides the SAME funnel line (#2333 cycle 6 review, P2): arg 3 was
      # `""` while `GATE_WHY` had just been set, so the cycle's one `-> 0 dispatched` line dropped the
      # `held:` clause and the reason survived only in the cycle record and a separate log line — the
      # sibling no-batch branch below passes it, so the two halves of one outcome printed differently.
      dispatch_funnel "$K" "$(queue_state_token)" "$GATE_WHY" "" "${Y:-0}" >> "$LOG"
      # ⛔ THE ISSUE PATH SPAWNS AFTER THE `[dispatch]` LINE IS ALREADY PRINTED (review, cycle 1). The
      # refusal count above is read at the end of the PR phase, so without this second read a refused
      # issue-path spawn would be truncated by the NEXT cycle and never appear on any line — the same
      # blindness this change removes, relocated to the path that is open when the PR queue is empty.
      # [issueref:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
      if [ "${SPAWNREF_OK:-1}" = "1" ] && [ -n "${SPAWNREF:-}" ] && [ -s "${SPAWNREF:-/nonexistent}" ]; then
        _irn="$(awk 'END{print NR+0}' "$SPAWNREF" 2>/dev/null)"; is_num "${_irn:-}" || _irn=0
        # ⛔ THE DELTA, NOT THE TOTAL (review, cycle 2): the `[pr]` line already reported the PR
        # phase's refusals, so printing the cumulative count here over-reports this path by exactly
        # that number and hands it the PR phase's reason. Rows before `base + N` belong to that line.
        _iid=$(( _irn - ${SPAWNREF_BASE:-0} - ${SPAWNREF_N:-0} ))
        if [ "$_iid" -le 0 ] && [ "$_irn" -ge 201 ]; then
          # ⛔ THE CAP IS NOT SILENCE (review, cycle 3): the writer stops at 200 refusal rows, so a
          # storm that the PR phase already saturated leaves this path with nothing to add — and a
          # refused issue path would be invisible. Say the measurement stopped instead.
          echo "[dispatch] ⛔ the refusal record is at its 200-row cap, so any ISSUE-path refusal this cycle is UNMEASURED (the [pr] line reports ≥200)" >> "$LOG"
        elif [ "$_iid" -gt 0 ]; then
          _irw="$(awk -F"$(printf '\t')" -v b="$(( ${SPAWNREF_BASE:-0} + ${SPAWNREF_N:-0} ))" \
                   'NR>b && NF>=2 && $1 != "#"{print $2; exit}' "$SPAWNREF" 2>/dev/null | cut -c1-200)"
          [ "$_iid" -ge 200 ] && _iid="≥200"
          echo "[dispatch] ⛔ ${_iid} spawn(s) REFUSED by the launcher (${_irw:-reason not recorded}) on the ISSUE path too — the launcher did not start them; see the [worker-terminal] REFUSED lines" >> "$LOG"
        fi
      fi
      # [issueref:end]
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
    elif [ "${PRDISP_ACTS:-0}" -gt 0 ]; then _prtail="${PRDISP_ACTS} acted, ${PRDISP_WAITS} named wait(s), spawned ${PRDISP_SPAWNS:-UNMEASURED}"
    else _prtail="NO UNIT SPAWNED, ${PRDISP_WAITS} named wait(s), spawned ${PRDISP_SPAWNS:-UNMEASURED} — see the [pr] line"; fi
    # ⛔ THE ACTUATOR'S ANSWER RIDES THE GATE LINE (measured 2026-10-22). `lanes=0` with no reason is
    # the line that let a 100%-full launcher volume freeze the fleet for six hours: this tail is the
    # ONE place the operator (and the beat) reads, so the refusal count and the launcher's own words
    # go here, not only into per-PR rows and a log nobody parses.
    # [prtail:begin] (extracted and DRIVEN by pr-dispatch.test.sh — keep the markers)
    _prtail="${_prtail}${_refsuf:-}"
    # [prtail:end]
    # ⛔ THE GATE VECTOR RIDES THE GATE LINE (agent-infra#2924 indicator (a), #2927's owner-visible
    # requirement). It is APPENDED, after every existing field, so every parser of this line keeps
    # working unchanged and the reason a cycle idled is readable in one place instead of inferred from
    # a single masking arm. Printed on the idle path only: a cycle that DISPATCHED has nothing to
    # explain, and `GATE_VEC` describes refusals, not the work it did.
    _prtail="${_prtail} | gates: ${GATE_VEC:-UNMEASURED}"
    dispatch_gate_line "$GATE_WHY" "${LANES_DISPLAY:-$LANES}" "$WORKERS" "$_prtail" >> "$LOG"
  fi
  heartbeat

  # ── THE CYCLE RECORD (agent-infra, measured 2026-10-21) ──────────────────────────────────
  # This is the artifact that answers "is the controller self-dispatching" without a human reading a
  # pane. MEASURED: the controller log on cell-1 was 37h stale and on the other two cells NO log was
  # found at its expected path, so "the controller is looping" was UNPROVEN — a live pane shows a
  # PROCESS, never a dispatch. One line per cycle: start, what was SELECTED, what was DISPATCHED, and
  # — when nothing was — WHY, plus the placement verdict and the bound it hit.
  # ⛔ NOTHING IS INFERRED: every field is a value this cycle already computed. `nothing=none` is
  # printed only when something WAS dispatched, so an idle cycle can never read as a working one, and
  # a cycle that could not write its record SAYS SO here (the status verb then reads ABSENT/DEGRADED,
  # never HEALTHY).
  if [ "${CYCREC:-0}" = "1" ]; then
    _cr_ids=""
    [ "${K:-0}" -gt 0 ] && _cr_ids="$(tr '\n' ',' < "$O/.batch" 2>/dev/null | sed 's/,$//')"
    case "${LO_CHOICE:-none}" in
      pr)    _cr_sel="pr:${FIRST_PR:--}" ;;
      issue) if [ -n "$_cr_ids" ]; then _cr_sel="issue:#$(printf '%s' "$_cr_ids" | cut -d, -f1)"; else _cr_sel="issue:none"; fi ;;
      *)     _cr_sel="none" ;;
    esac
    if [ "${K:-0}" -gt 0 ]; then _cr_nothing="none"
    elif [ -n "${GATE_WHY:-}" ]; then _cr_nothing="gate:${GATE_WHY}"
    elif [ "${Y:-0}" -gt 0 ]; then _cr_nothing="placed_elsewhere:${Y}"
    else _cr_nothing="no_candidate"; fi
    # The drain field is the marker's own reading, through the SAME helper the status-line token
    # uses (agent-infra#2590 review c-1): a marker that records spawned workers is STALLED, not
    # DEADLOCK, and an unreadable count is UNMEASURED. `draining` is the no-marker state.
    _cr_drain="${LO_CHOICE:-none}"
    if [ "${LO_CHOICE:-none}" = "pr" ]; then
      _cr_drain="$(drain_stall_label)"; [ -n "$_cr_drain" ] || _cr_drain="draining"
      # ⛔ ONE FIELD SAYING "NOT MEASURED" AND THE NEXT SAYING "NONE EXISTED" IS A LIE IN A RECORD
      # (review 6-P2). On an UNMEASURED pass `PRDISP_SPAWN_TAGS` is empty, and the old
      # `${PRDISP_SPAWN_TAGS:-none}` wrote `spawned_pr=UNMEASURED spawn_tags=none` — the second field
      # asserting an absence nobody measured. Only a MEASURED zero owns `none`.
      _cr_tags="${PRDISP_SPAWN_TAGS:-}"
      [ -n "$_cr_tags" ] || { [ -n "${PRDISP_SPAWNS:-}" ] && _cr_tags="none" || _cr_tags="UNMEASURED"; }
    fi
    cycle_record_write "$O" \
      start="${CYCLE_T0:-0}" end="$(date +%s)" cycle="${CYCLE_N:-0}" interval="${CYC:-240}" \
      selected="$_cr_sel" selected_n="${SEL_TOTAL:-0}" dispatched="${K:-0}" ids="${_cr_ids:--}" \
      nothing="$_cr_nothing" placement="${CAP_STATE:-unavailable}" placed_on="${CAP_PLACE:-none}" \
      bound="${CAP_BOUND:-none}" lpc_self="${CAP_LPC_SELF:-?}" shapes="${SEL_TOTAL:-0}" \
      spawned_pr="${PRDISP_SPAWNS:-UNMEASURED}" spawn_tags="$_cr_tags" \
      drain="$_cr_drain" \
      || echo "[cycle] ⚠️ THIS CYCLE COULD NOT BE RECORDED (state/ unwritable or the module is absent) — an absent record is NOT a healthy box: harness status reads it ABSENT/DEGRADED" >> "$LOG"
  else
    echo "[cycle] ⚠️ cycle-record.sh is NOT available (looked in \$O and the script directory) — this cycle leaves NO proof it ran; harness status will read the box ABSENT, never HEALTHY. Re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \"$O\"" >> "$LOG"
  fi

  # ---- 3) background backlog refresh (locked, small, non-blocking) --------
  BL="$(wc -l < "$O/candidates.txt" | tr -d ' ')"
  # ⛔ THE LATCH (agent-infra#2019). The gate was `BL -lt 6` alone, while the refresh it gates fills
  # candidates.txt to exactly the same 6 — so the FIRST pass that filled the queue made the gate
  # permanently FALSE, and it could only reopen by draining, which the PR-before-issues hold can
  # prevent for hours. MEASURED on a live box 2026-10-21: candidates.txt pinned at 6,
  # `state/refresh-funnel` last written 02:24, `[dispatch] funnel STALE(1761m > 30m)` — a 29-HOUR
  # frozen pool, every issue created in that window invisible to the box.
  # The fix is an AGE bound beside the length test: a full queue stays full, but a pass older than
  # LATCH_MAX_AGE_MIN is stale EVIDENCE and is refreshed regardless. The anti-thrash intent survives
  # as that age floor — a two-minute-old pass still suppresses a redundant rebuild.
  _funnel_age_min=99999
  if [ -f "$O/state/refresh-funnel" ]; then
    _fm="$(file_mtime_epoch "$O/state/refresh-funnel" 2>/dev/null)" && \
      _funnel_age_min=$(( ( $(date +%s) - _fm ) / 60 ))
  fi
  LATCH_MAX_AGE_MIN="${LATCH_MAX_AGE_MIN:-30}"
  if [ "$BL" -lt 6 ] || [ "$_funnel_age_min" -gt "$LATCH_MAX_AGE_MIN" ]; then
    [ "$BL" -ge 6 ] && echo "[refresh] latch: queue=$BL but the recorded pass is ${_funnel_age_min}m old (>${LATCH_MAX_AGE_MIN}m) — refreshing anyway (#2019)" >> "$LOG"
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
      # ⛔ THE REFRESH IS RESOLVED, NOT HARDCODED (agent-infra#2308) — see `resolve_refresh_sh`. A pass
      # whose outcome nothing can record is spawned ONLY if that is disclosed and not repeated for
      # nothing: with no recorder anywhere, spawning buys a full pool read whose result this loop is
      # then forbidden to trust. The skew line names the passed-over copy, so a stale seed cannot sit
      # invisible behind a healthy-looking pass — and EVERY arm that picks a copy OTHER than the
      # seeded one speaks.
      # ⛔ KEYED ON THE PATH CHOSEN, NOT ON THE SKEW FLAG (review P2). `REFRESH_SH_SKEW` is set only for
      # a copy that EXISTS but cannot record, so a key of `-n "$REFRESH_SH_SKEW"` left the
      # `rc=0`-with-NO-SEED case in no arm at all: `$O` was never seeded (or its seed was deleted), the
      # resolver found the copy beside the loop and answered rc=0 with no skew recorded, and the beat
      # logged only `spawning` while a script the operator never seeded there ran — a healthy-looking
      # cell whose skew was invisible except to `--check-refresh`, which nobody runs per cycle. The arm
      # below asks the only question the contract is about: is the copy being executed the SEEDED one?
      resolve_refresh_sh; _rrc=$?
      _seeded_refresh="$O/refresh-candidates.sh"
      if [ "$_rrc" = "2" ]; then
        echo "[refresh] SEED-SKEW: no refresh-candidates.sh on this box can record a pass outcome (passed over: ${REFRESH_SH_SKEW:-none}; tried: ${REFRESH_TRIED:-none}) — running $REFRESH_SH anyway so the pool still fills, but the BEAT will report SEED-SKEW, not a dead pass. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)" >> "$LOG"
      elif [ "$_rrc" = "1" ]; then
        echo "[refresh] SEED-SKEW: no refresh-candidates.sh found at all (tried: ${REFRESH_TRIED:-none}) — NOT spawning a pass that cannot run. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)" >> "$LOG"
        rm -rf "$O/.refresh.lock"
      elif [ -n "$REFRESH_SH" ] && [ "$REFRESH_SH" != "$_seeded_refresh" ]; then
        # ⛔ A COPY OTHER THAN THE SEEDED ONE IS DISCLOSED, NOT SILENT (review P2). Two shapes reach this
        # arm and they are named apart, because their remedies read differently: a seed that EXISTS but
        # cannot record (the MEASURED cell — a stale `$O` seed, a recording copy beside the loop), and a
        # seed that is ABSENT entirely. On the pre-fix key, both logged only `spawning`. No lock removal
        # here — a pass IS being spawned; only the CHOICE OF COPY is being announced.
        if [ -n "$REFRESH_SH_SKEW" ]; then
          echo "[refresh] SEED-SKEW: the seeded ${REFRESH_SH_SKEW} cannot record a pass outcome — running the recorder beside the loop (${REFRESH_SH:-none}) instead; the BEAT reads no cause from the seed's silence, it was never the writer. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)" >> "$LOG"
        else
          echo "[refresh] SEED-SKEW: the seeded path ${_seeded_refresh} is MISSING (never seeded, or deleted) — running the copy beside the loop (${REFRESH_SH:-none}) instead, which the operator did not seed here; only the beside-the-loop copy's record is evidence, never the absent seed's. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)" >> "$LOG"
        fi
      elif [ -z "$REFRESH_SH" ]; then
        # ⛔ EVERY ARM RELEASES THE LOCK AND SPEAKS (review P2). An answer this branch does not recognise
        # (a future resolver code, a helper that is `command not found` in an extracted rig) used to fall
        # past `if [ -n "$REFRESH_SH" ]` with no `else`: the log had already said `spawning`, nothing ran,
        # and `.refresh.lock` stayed on disk — a silent no-op wearing a spawn line.
        echo "[refresh] SEED-SKEW: the refresh resolver returned an UNRECOGNISED answer (rc=$_rrc, script='${REFRESH_SH:-none}') — NOT spawning a pass whose writer cannot be identified; tried: ${REFRESH_TRIED:-none}. Fix: re-seed \$O with the VERIFYING seeder (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O)" >> "$LOG"
        rm -rf "$O/.refresh.lock"
      fi
      if [ -n "$REFRESH_SH" ]; then
        ( bash "$REFRESH_SH" 6 >> "$LOG" 2>&1; rc=$?
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
          echo "[refresh] BLOCKED (permanent): repo-slug.sh missing/stale in \$O — the pool cannot be attributed to a repo, so nothing may be queued. Re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O then delete \$O/.refresh-blocked (agent-infra#2040)" >> "$LOG"
          {
            echo "MERGE-ONLY: dispatch is BLOCKED — repo-slug.sh is missing or stale in \$O."
            echo "The refresh refuses to read a candidate pool it cannot attribute to a repo (agent-infra#2040)."
            echo "Fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o <your \$O>   then delete this file."
          } > "$O/.refresh-blocked" 2>/dev/null
        elif [ "$rc" -ne 0 ]; then
          # The pass recorded its own cause in `state/refresh-last` (agent-infra#2229); QUOTE it here
          # rather than restating `transient` alone, so this line and the next beat's BLOCKED line
          # agree on the cause. A missing record is named, not glossed.
          echo "[refresh] FAILED rc=$rc (transient — retried next cycle) — $(refresh_cause_brief "$(refresh_record_snapshot)")" >> "$LOG"
        fi ) &
      fi
    else
      # stale lock guard (default 20 min; REFRESH_STALE_LOCK_MIN). The SAME constant bounds the
      # origination block's "in flight vs died" reading, so the beat and the controller cannot
      # disagree about when a pass is dead.
      if [ -n "$(find "$O/.refresh.lock" -mmin +"$REFRESH_STALE_LOCK_MIN" 2>/dev/null)" ]; then rm -rf "$O/.refresh.lock"; echo "[refresh] cleared stale lock" >> "$LOG"; fi
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
  # ⛔ A FORK-STARVED / LOW-HEADROOM CYCLE NAPS ON A BUILTIN (agent-infra#2293): `sleep … & wait`
  # spawns, and on a box out of pids that spawn is the one that kills the controller (measured: bash
  # exits on a failed fork, and launchd's relaunch needs the same fork). `fork_free_sleep` blocks in
  # `read -t` on the FIFO opened at startup — no child at all.
  if [ "${FORK_STARVED:-0}" = "1" ]; then
    fork_free_sleep $(( 10#${CYC} - JIT + RANDOM % (2 * JIT + 1) )) \
      || sleep $(( 10#${CYC} - JIT + RANDOM % (2 * JIT + 1) )) 2>/dev/null
  else
    sleep $(( 10#${CYC} - JIT + RANDOM % (2 * JIT + 1) )) & wait $!
  fi
done
