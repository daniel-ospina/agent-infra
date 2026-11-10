#!/usr/bin/env bash
# reap-abandoned-worktrees.sh — reclaim ABANDONED scratch worktree directories (#2542).
#
# THE MEASURED DEFECT THIS EXISTS FOR. On 2026-10-24 the interim disk guard fired six times in 25
# minutes on cell-1, at 95% used, and reclaimed **4 MB per cycle** (`LOW free=6618MB use=95%` ->
# `reclaimed: 6618MB -> 6614MB`). Its classes (`uv`, `venv`, `worktree`) matched NOTHING, because the
# consumer was not a registered worktree of a live repo layout: it was ~120 directories under `/tmp`,
# most belonging to lanes that had finished or died days earlier.
#
# Reclaimed by hand with the predicate below, on the same three cells (`df` deltas, never a `du` sum):
#   c4  6,245 MB -> 11,840 MB  (+5,595)  57 reaped, 5 kept
#   c1  6,178 MB ->  9,179 MB  (+3,001)  41 reaped, 1 kept
#   c3 13,144 MB -> 16,882 MB  (+3,738)  35 reaped
# = 12.3 GB and 133 directories, the oldest 4,801 minutes (3+ days) old, the newest 5 GB each.
#
# THE RULE (two dials, and they are BOTH required):
#   1. AGE      the directory's mtime is older than --aged-minutes (default 180). A young worktree
#               may belong to a lane that has not written yet.
#   2. LIVE-CWD no live process's cwd or exe resolves inside it — enumerated by reading
#               `/proc/<pid>/cwd` (+ exe, + argv) for EVERY pid, NEVER by `pgrep -f` (which
#               self-matches the shell running the check and shows the nesting stack, not the
#               population). One implementation: `scripts/lib/live-paths.sh`.
#
#   Dial 2 is what makes this safe rather than a guess, and it earned its place on the first run: it
#   KEPT five directories whose age alone would have condemned them — `cell-wt-tmainred70` (226 m),
#   `cell-wt-zombiepi` (742 m), `cell-wt-trebase6` (823 m), `cell-wt-venvlink` (1,080 m),
#   `wt-pinfix` (2,200 m) — each with a live process sitting inside. A reaper without this arm
#   deletes live work, which is worse than a full disk.
#
# ⛔ FAIL-CLOSED. If the process list cannot be read at all, NOTHING is reaped and the pass says
# `SKIP reason=census-unreadable` (exit 3). "Could not enumerate" is never read as "nothing is live".
# A PARTIAL read (this user cannot see root's entries) is a real census and is reported as one, with
# the population size — refusing on a partial read would make the sweep inert on every real box,
# which is the inert-enforcer shape this family exists to remove.
#
# ⛔ WHAT IS A CANDIDATE, EXACTLY. A directory immediately under a scratch root (`--root`, default
# `/tmp`) whose `.git` is a FILE — i.e. a LINKED git worktree. That single test is what keeps a
# reaper for `worktree` debris from being a reaper for the machine:
#   * a primary checkout has `.git` as a DIRECTORY, so `/tmp/cell-ai` (the hub) and `/tmp/cell-t3`
#     (the cell's repo) are NOT candidates — no age or liveness accident can reach them;
#   * depth 1 means `/tmp/cell-home/...` (state, harness pins) is NOT a candidate either: its
#     children are the `harness` class's business (#2542's pin rule), not this arm's;
#   * anything that is not a git checkout at all (a user's scratch directory, an archive) is not a
#     candidate — this arm reaps checkouts, not "old things in /tmp".
#
# THE OTHER THREE ARMS (the contract from #2542/#2594, kept verbatim):
#   * the sha pinned in `.agent-infra-stamp.json` is NEVER reaped (path, or a name carrying the
#     commit), because a cell whose harness dir is deleted mid-run loses its controller;
#   * a path a LIVE process's `/proc/<pid>/args` names is NEVER reaped — a controller can be started
#     elsewhere and still hold the tree it was pointed at;
#   * a live lane's worktree is never reaped — that IS dial 2;
# and the REPORT is a `df` delta taken by the caller (disk-reaper.sh), never a `du` sum (this script
# prints no byte figure at all; `du` over /tmp is shared-block over-counting and an unbounded
# `du -sm /tmp/*` times out — measured three times on 2026-10-24).
#
# ⚠️ THE THIRD DIAL, AND WHY IT EXISTS. `--dirty keep` (the DEFAULT) keeps a candidate whose
# `git status --porcelain` is non-empty and names it (`reason=dirty(<n>)`); `--dirty reap` removes it
# like any other candidate, which is exactly what the measured hand reclaim did (age + live-cwd only).
# The distinction is the DIFFERENCE BETWEEN RECOVERABLE AND NOT: `git worktree remove` never deletes a
# branch, the commits live in the shared object store, and a detached sha is still findable with
# `git fsck --unreachable` — so what the two-dial predicate actually destroys is UNCOMMITTED WORK,
# which nothing can recover (measured on the same box: one 33-hour-old abandoned checkout held 212
# dirty entries). Default KEEP; the owner's ruling can be restored per pass without a code change,
# and both dial settings are reported so the choice is never implicit.
#
# ⚠️ WHAT IS STILL DISCARDED, SAID PLAINLY. With `--dirty reap` (or on a clean candidate) the
# removal may drop a detached HEAD whose commit no `refs/heads/*` ref holds. That commit survives in
# the object DB (it is squashed into main in every case measured) and the branch a worktree is ON
# survives unconditionally, so nothing reachable is lost; every removal NAMES what it discarded
# (`branch=`, `head=`, `dirty=<n>`) so the loss is legible after the fact rather than invisible.
#
# Usage:
#   reap-abandoned-worktrees.sh [--dry-run|--apply] [--root DIR]... [--aged-minutes N]
#                               [--print-config] [--list] [--help]
#
#   (no mode flag) dry-run  report what WOULD be removed; remove NOTHING
#   --dry-run               explicit dry-run (wins over REAP_AW_DRY_RUN=0)
#   --apply                 armed pass
#   --root DIR              scratch root to sweep at depth 1 (repeatable; default /tmp)
#   --aged-minutes N        the age dial (default 180)
#   --dirty keep|reap       the uncommitted-work dial (default keep; see the header)
#   --print-config          `roots=…` / `aged_minutes=…` for the caller's df accounting
#   --list                  print every candidate and every keep with its reason, remove nothing
#
# Env seams:
#   REAP_AW_ROOTS           colon-separated scratch roots (same as --root)
#   REAP_AW_AGED_MINUTES    the age dial (default 180)
#   REAP_AW_DRY_RUN         0 supplies the default mode only (an explicit flag always wins)
#   REAP_AW_DIRTY           keep|reap — the uncommitted-work dial (default keep)
#   REAP_AW_STATE_DIR       lock + log dir (default $HOME/.pi/agent/state)
#   REAP_AW_LOG             pass log (default $REAP_AW_STATE_DIR/reap-abandoned-worktrees.log)
#   REAP_AW_LOCK_STALE_SECONDS  a stale lock is reclaimed after this (default 1800)
#   REAP_AW_STAMP           the pin file (default: $CELL_HOME/orchestrator/.agent-infra-stamp.json,
#                           then $HOME/.pi/orchestrator/.agent-infra-stamp.json; absent = no pin)
#   REAP_AW_BUDGET_SECONDS  the PER-ROOT TIME bound (default 300) — `deadline` is assigned inside
#                           `sweep_root`, so a two-root pass permits two budgets, the same scoping the
#                           count ceiling below has. This is the real guard, for BOTH ARMS: it gates
#                           every EXPENSIVE per-candidate step (the live-pid census,
#                           `git status`, the re-probe, removal). Cheap eligibility (the structural
#                           rejections and the age floor) still runs for the whole population, so an
#                           over-budget pass classifies what it saw and preserves the rest — on the
#                           GITLESS arm it never spends the census on a tree the age floor rejects,
#                           because that floor precedes the census there. ⚠️ NOT so on the LINKED arm:
#                           its age floor sits AFTER the census (a linked worktree's own proof order is
#                           unchanged, and moving the bound above the census is the only change to
#                           that order), so a YOUNG linked worktree does spend one census before the
#                           floor rejects it. ⛔ AND AN EXHAUSTED
#                           CEILING SHORT-CIRCUITS THE SCAN (see REAP_AW_GITLESS_MAX below), so past it a
#                           tree costs one integer compare rather than the ~6 forks the
#                           canonical/keep/state guards need.
#                           It bounds the PER-CANDIDATE work, not the whole class: the eligibility scan
#                           is proportional to the population. The caller (`disk-reaper.sh`) invokes this
#                           delegate ONCE PER ROOT under its own DISK_REAPER_CLASS_TIMEOUT (1800), so an
#                           N-root pass is bounded by N x 1800 — not by 1800.
#   REAP_AW_GITLESS_MAX     the gitless arm's count ceiling (default 10), applied PER ROOT — the
#                           counter is reset inside each `sweep_root`, and `ROOTS` is colon-separated,
#                           so a two-root pass permits two ceilings — and charged PER AGED CANDIDATE:
#                           the unit is taken only after the age floor accepts a tree, so a tree the
#                           floor preserves costs no slot (#3278 P1). ⛔ AND AN EXHAUSTED CEILING
#                           SHORT-CIRCUITS THE SCAN, not only the census: it is one integer compare at
#                           the top of the branch, and without it a capped pass still paid ~6 forks per
#                           entry to print rows that all say `gitless-cap` — measured on a 300-entry
#                           fixture with the census isolated: 0.60 s on `2c18ff89a`, 8.98 s with the
#                           check downstream of the scan, byte-identical pass record. Raising or
#                           removing the ceiling is #3278's P3, an OWNER decision, and is deliberately
#                           NOT done here.
#   REAP_AW_CELL_HOME_DEFAULT  the cell home the gitless guard protects when nothing exports
#                           `CELL_HOME` (default /tmp/cell-home; a TEST SEAM, and only that). It exists
#                           so the fallback has a BEHAVIOURAL test: a fixture cannot live at
#                           /tmp/cell-home, so without this seam reverting the guard loop's reference
#                           left every case green while the real cell home became reapable. It is a
#                           DEFAULT, NOT A SECOND SOURCE OF TRUTH, and it is a SUBSTITUTION, not a
#                           union — the same shape as `load_pin` below, and for the same reason: an
#                           exported `CELL_HOME` still wins, and a WRONG value protects a different
#                           directory **and drops `/tmp/cell-home`**. Measured (review round 9): the same
#                           aged tree is PRESERVED when the seam names it, and becomes `remove` when the
#                           seam names something else. That is the trade an operator already makes by
#                           setting `CELL_HOME` — which is why this seam is TEST-ONLY and must never be
#                           set by the unit, the launcher, or any scheduled artifact.
#   REAP_AW_PROC_ROOT       the process table root (default /proc; a test seam — pointing it at a
#                           missing dir makes the census UNREADABLE, which must skip the sweep)
#   REAP_AW_LIVE_PATHS      the census library (default: lib/live-paths.sh beside this script, then
#                           $HOME/.pi/agent/scripts/lib/); a SET-but-missing value is a refusal
#   REAP_AW_GIT_TIMEOUT     watchdog per git probe (default 60)
#
# Exit codes (the family's vocabulary, so `disk-reaper.sh` maps it unchanged):
#   0  the sweep ran and every action it took succeeded (including "nothing qualified")
#   2  usage
#   3  FAIL-CLOSED — the census could not be read, the lock is held, or the library is missing.
#      Nothing was reaped.
#   4  the sweep ran and at least one REMOVAL failed (named; the directory is still there)
#
set -uo pipefail

SCRIPT_NAME="reap-abandoned-worktrees.sh"
# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS. Under
# `bash -s` (a piped start) `$0` is literally `bash`, so an unguarded `dirname` answers the CALLER's
# working directory and this script would source a library out of it.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""
SELF_DIR=""
[ -n "$_SELF" ] && SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd)"
# ── THE ONE HOME (agent-infra#3453) ──────────────────────────────────────────────────────────────
# This script must not spell `/tmp/cell-home` itself: the one literal lives in `scripts/lib/cell-home.sh`
# and every other shipped file names it through `CELL_HOME_LEGACY`. The pre-#3453 shape here was
# `${REAP_AW_CELL_HOME_DEFAULT:-/tmp/cell-home}` — one seam deeper than the flat alternatives the sweep
# in `lib/cell-home.test.sh` first carried, so it survived a green `c1` (review F3a, verified NO-MATCH).
# FAIL-CLOSED like the `lib/live-paths.sh` block below, for the same reason: a home this script cannot
# name is a guard it cannot enforce, and a silently-empty preserve-set is how `/tmp/cell-home` becomes
# reapable (the measured #3278 defect this guard exists for).
# ⚠️ ACCEPTED TRADE (review F5): this block runs before argument parsing, so `--help`/`-h` also exits 3
# on a box with no farmed library. The alternative — answering `--help` first — means the help text and
# the guard's remedy have two copy sites to drift between, which is worse for a delegate whose only
# scheduler is a timer. The failure NAMES the missing file and the three places it was looked for, so an
# operator is never guessing.
CELL_HOME_LIB=""
# ⛔ `${SELF_DIR:+…}` AND `${HOME:+…}` — AN EMPTY PREFIX MUST NOT BUILD AN ABSOLUTE PATH. `"$SELF_DIR/lib/…"`
# with a piped start (no `SELF_DIR`) yields `/lib/cell-home.sh`, and `"${HOME:-}/.pi/…"` with no HOME
# yields `/.pi/…`: absolute paths outside any checkout, exactly the shape §CONSUMERS forbids (review
# F5). They still fail closed, but a candidate list must not propose a file no checkout can own.
for _cand in ${SELF_DIR:+"$SELF_DIR/lib/cell-home.sh"} \
             ${HOME:+"$HOME/.pi/agent/scripts/lib/cell-home.sh"} \
             ${AGENT_INFRA_PATH:+"$AGENT_INFRA_PATH/scripts/lib/cell-home.sh"}; do
    [ -n "$_cand" ] && [ -r "$_cand" ] && { CELL_HOME_LIB="$_cand"; break; }
    done
if [ -z "$CELL_HOME_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — lib/cell-home.sh not found (looked beside this script, in $HOME/.pi/agent/scripts/lib, and in $AGENT_INFRA_PATH/scripts/lib) — without it this script cannot name the cell home its preserve-set must protect\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=cell-home-library-missing\n'
    exit 3
fi
# shellcheck source=lib/cell-home.sh
. "$CELL_HOME_LIB" || { printf 'SKIP reason=cell-home-library-unreadable path=%s\n' "$CELL_HOME_LIB"; exit 3; }
STATE_DIR="${REAP_AW_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${REAP_AW_LOG:-$STATE_DIR/reap-abandoned-worktrees.log}"
LOCK_DIR="$STATE_DIR/reap-abandoned-worktrees.lock"
LOCK_STALE_SECONDS="${REAP_AW_LOCK_STALE_SECONDS:-1800}"
AGED_MINUTES="${REAP_AW_AGED_MINUTES:-180}"
DIRTY_MODE="${REAP_AW_DIRTY:-keep}"
# ── the GITLESS arm (#3278) ───────────────────────────────────────────────────────────────────
# OFF by default so every existing caller keeps today's exact behaviour (and its tests keep meaning
# what they meant). The scheduled pass opts IN, because the class this arm covers is the one that
# grows: a `/tmp/<name>` scratch tree with NO `.git` was invisible to every arm the hourly pass runs.
INCLUDE_GITLESS=0
# ⛔ A KEEP LIST IS NOT OPTIONAL. A gitless tree cannot be PROVEN to hold no work (there is no
# branch, no remote ref, no PR to consult), so the paths a BOX depends on are named here and are
# never candidates. `/tmp/actions-runner` is the CI runner install on every cell — removing it
# breaks every job on the box, which is a worse outcome than the space it holds.
GITLESS_KEEP="${REAP_AW_GITLESS_KEEP:-/tmp/actions-runner:/tmp/venv-shared*}"
# ⛔ THE CLASS'S EXPENSIVE PER-CANDIDATE WORK IS BOUNDED, PER ROOT, BY **ELAPSED TIME**
# (`REAP_AW_BUDGET_SECONDS`, default 300; the eligibility scan over the whole population is NOT budgeted
# — classifying every entry is the product — and the entry point's `DISK_REAPER_CLASS_TIMEOUT=1800`
# bounds each PER-ROOT invocation, not the whole pass) **AND** by the operator's ceiling on how many
# AGED trees one root may classify per pass (`REAP_AW_GITLESS_MAX`, default 10).
#
# WHY THE CEILING'S UNIT MOVED — AND WHY THE CEILING ITSELF DID NOT (#3278 P1). The count was a
# throughput throttle sized for a standing population of **26 candidates**; the box it runs on now
# holds **thousands**. The damage was not the number, it was WHERE the unit was charged: BEFORE the age
# floor was consulted, so ~89 % of those ten slots went to trees the age test would have preserved
# anyway — a dry run over 3,314 top-level entries classified 10 and printed `gitless-cap` for **3,137**
# of them, and the aged population was never reachable at all. Charging the unit after the age floor (and
# before the census) hands the same ceiling to the population it was calibrated against, which is the
# ~10× throughput lever with **no policy change**.
#
# ⛔ RAISING OR REMOVING THE CEILING IS #3278's **P3** — AN OWNER DECISION — AND IS NOT TAKEN HERE. P3
# reserves that axis in the issue's plan comment (`issues/comments/6698790753`) verbatim: "This is
# destructive against trees a `rm -rf` cannot recover … so it is the owner's call, and it should land
# after P1 and P2." P2 (`scripts/scratch-dir.sh`) has not landed, so the default stays 10: this change
# removes the STARVATION, not the ceiling. An operator who wants a different ceiling for one pass sets
# the seam; the time bound below is what makes any ceiling cheap to honour, because the loop no longer
# buys a full census for every tree it is about to preserve.
GITLESS_MAX="${REAP_AW_GITLESS_MAX:-10}"
ROOTS="${REAP_AW_ROOTS:-/tmp}"
# ⛔ THE CELL HOME THE `home-or-state` GUARD PROTECTS EVEN WHEN NOTHING EXPORTS `CELL_HOME`.
# MEASURED (#3278, 2026-11-06, owner, on a cell): the unit renders `Environment=HOME=/home/cmux`, which
# IS a real directory, so `disk-reaper-run.sh`'s fallback never substituted and its `CELL_HOME=` was
# never exported — so the guard compared against `/home/cmux` alone and `/tmp/cell-home` (a live ~20 GB
# operative home holding the cell's `.pi` state, with no `.git` and therefore no `main-checkout` guard
# of its own) matched NONE of the three references. On the armed pass it survived as
# `reason=gitless-cap` — a rate limit, not a gate.
#
# ⛔ IT IS RESOLVED HERE, NOT BY EXPORTING `CELL_HOME` UPSTREAM — that was tried and measured WRONG.
# `load_pin` (defined BELOW — cite it by name, not by a line number; a stale `:332` sent a reader into
# `acquire_lock`) reads the same variable with FIRST-MATCH-WINS and a `break`
# (`${CELL_HOME}/orchestrator/…` then `${HOME}/.pi/orchestrator/…`), so its list is a SUBSTITUTION, not
# a union: exporting would make one of the two stamps stop being read, i.e. a tree the other stamp
# pinned becomes a candidate and `rm -rf` takes it. A local fallback is additive; an exported variable
# is not. This value touches only the guard loop.
# ⛔ `REAP_AW_CELL_HOME_DEFAULT` EXISTS SO THE FALLBACK ITSELF CAN BE EXERCISED. A fixture cannot live at
# `/tmp/cell-home` on a real box, so without this seam the fallback had a *resolution* test
# (`--print-config`) and no behavioural one: reverting the guard loop's reference to a raw
# `"${CELL_HOME:-}"` left every case GREEN while `/tmp/cell-home` became reapable on the unit's path —
# the exact shape #3278 measured (review round 7). It is a DEFAULT, not a second source of truth: an
# exported `CELL_HOME` still wins, and a deliberately wrong value protects a different directory — the
# same trade an operator already makes by setting `CELL_HOME`, so it adds no new hazard class.
# ⛔ THE LEGACY VALUE COMES FROM THE RESOLVER (`CELL_HOME_LEGACY`), NOT FROM A SECOND LITERAL here — see
# the derivation block above and `lib/cell-home.sh`.
CELL_HOME_DEFAULT="${CELL_HOME:-${REAP_AW_CELL_HOME_DEFAULT:-$CELL_HOME_LEGACY}}"
DRY_RUN="${REAP_AW_DRY_RUN:-1}"
BUDGET="${REAP_AW_BUDGET_SECONDS:-300}"
GIT_TIMEOUT="${REAP_AW_GIT_TIMEOUT:-60}"
LIST_ONLY=0
PRINT_CONFIG=0
ROOTS_GIVEN=0

log_line() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
num() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; esac
    # ⛔ AND IT MUST FIT THE SHELL'S INTEGER — a digit check is NOT enough. `[ "$a" -ge "$b" ]` returns
    # **2** ("integer expression expected") on a value ≥ 2^63, and a `[ ]` failure inside an `if` reads as
    # FALSE, so an unrepresentable seam does not clamp — it INVERTS the guard it feeds:
    # `REAP_AW_GITLESS_MAX` would never fire (the destructive ceiling silently ABSENT — exactly #3278's
    # P3 shape this PR does not ship), and `REAP_AW_AGED_MINUTES` would make EVERY tree read as AGED.
    # 18 digits is < 2^63 by construction, so no value that passes here can reach that error.
    # ⛔ THE PREVIOUS REVISION CHECKED THE DIGIT SHAPE ONLY while its comment claimed this class was
    # closed; it was not (review round 8, measured: a 20-digit ceiling gave `12 removable, 0 capped`,
    # rc=0, and a green SUMMARY — the ceiling gone with no refusal and no log line saying so).
    [ "${#1}" -le 18 ]
}

usage() {
    awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" 2>/dev/null \
        || printf 'usage: %s [--dry-run|--apply] [--root DIR]... [--aged-minutes N]\n' "$SCRIPT_NAME"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --root)    [ $# -ge 2 ] || die "--root needs a path"
                   case "$2" in /*) ;; *) die "--root needs an ABSOLUTE path (got '$2')" ;; esac
                   if [ "$ROOTS_GIVEN" = 1 ]; then ROOTS="$ROOTS:$2"; else ROOTS="$2"; ROOTS_GIVEN=1; fi
                   shift 2 ;;
        --aged-minutes) [ $# -ge 2 ] || die "--aged-minutes needs a number"
                        num "$2" || die "--aged-minutes must be a decimal number of at most 18 digits (got '$2')"
                        AGED_MINUTES="$2"; shift 2 ;;
        --dirty)   [ $# -ge 2 ] || die "--dirty needs keep|reap"
                   case "$2" in keep|reap) DIRTY_MODE="$2" ;; *) die "--dirty must be keep|reap (got '$2')" ;; esac
                   shift 2 ;;
        # ⛔ THE GITLESS ARM IS OPT-IN, and it has NO `--dirty` argument: a tree with no `.git` has no
        # tree state to read, so the dial that governs it is AGE + the live-pid census + the keep
        # list. Asking git whether it is clean would return nothing, and `--dirty keep` reads an
        # unhelpful `dirty=` as `clean-unknown` — i.e. it would keep every one of them forever.
        --include-gitless) INCLUDE_GITLESS=1; shift ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --list)    LIST_ONLY=1; DRY_RUN=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
num "$AGED_MINUTES" || die "REAP_AW_AGED_MINUTES must be a decimal number of at most 18 digits (got '$AGED_MINUTES')"
case "$DIRTY_MODE" in keep|reap) ;; *) die "REAP_AW_DIRTY must be keep|reap (got '$DIRTY_MODE')" ;; esac
num "$BUDGET" || die "REAP_AW_BUDGET_SECONDS must be a decimal number of at most 18 digits (got '$BUDGET')"
# ⛔ THE CEILING IS VALIDATED, NEVER COERCED. A typo must not silently become "no count bound" (the
# fail-open the pre-#3278 `:-0` spelling would have been) and must not silently become "cap reached"
# for every tree either — `num` refuses both. ⛔ AND "A TYPO" INCLUDES ONE THAT IS ALL DIGITS BUT TOO
# LARGE TO COMPARE: `num` bounds the value to the shell's integer range for that reason, because
# `[ "$GITLESS_DONE" -ge "$GITLESS_MAX" ]` returning 2 reads as FALSE and the ceiling stops existing.
# The same bound protects `REAP_AW_AGED_MINUTES`, `REAP_AW_BUDGET_SECONDS` and `REAP_AW_LOCK_STALE_SECONDS`,
# which are validated by this same function.
if [ -n "$GITLESS_MAX" ]; then num "$GITLESS_MAX" || die "REAP_AW_GITLESS_MAX must be a decimal number of at most 18 digits (got '$GITLESS_MAX') — a value that cannot be COMPARED would silently remove the ceiling instead of raising it"; fi
num "$LOCK_STALE_SECONDS" || die "REAP_AW_LOCK_STALE_SECONDS must be a decimal number of at most 18 digits (got '$LOCK_STALE_SECONDS')"

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'roots=%s\n' "$ROOTS"
    printf 'aged_minutes=%s\n' "$AGED_MINUTES"
    printf 'dirty=%s\n' "$DIRTY_MODE"
    # The EFFECTIVE bounds, so the caller can record what the pass was allowed to do: the time bound,
    # the count ceiling (per root, charged per AGED candidate — 10 by default), and the cell home the
    # guard compares against.
    printf 'budget_seconds=%s\n' "$BUDGET"
    printf 'gitless_max=%s\n' "${GITLESS_MAX:-none}"
    # The cell home the guard will protect even with `CELL_HOME` unset (the unit's shape). Reported
    # like the other effective bounds: a pass record must not hide what the guard was comparing.
    printf 'cell_home_default=%s\n' "$CELL_HOME_DEFAULT"
    # ⛔ AND THE DERIVED HOME ITSELF (`cell_home_resolve`), reported next to the legacy guard reference
    # so the operator can see BOTH readings and whether they differ — the state #3453 exists to remove.
    # It is also the call that makes the `(d)` sweep able to certify that this file ASKS the resolver
    # rather than answering "what is this box's home?" on its own (review F3b).
    printf 'cell_home=%s\n' "$(cell_home_resolve)"
    printf 'mode=%s\n' "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 0
fi

# ── the census library ──────────────────────────────────────────────────────────────────────────
# ⛔ A SET-BUT-MISSING PATH IS A REFUSAL, NOT A FALLBACK. An operator who pinned the library must not
# be silently running a different file — the same rule every other delegate in this family follows.
LIVE_PATHS_LIB=""
if [ -n "${REAP_AW_LIVE_PATHS:-}" ]; then
    [ -f "${REAP_AW_LIVE_PATHS}" ] || {
        printf '%s: ⛔ FAIL-CLOSED — REAP_AW_LIVE_PATHS=%s does not exist\n' "$SCRIPT_NAME" "$REAP_AW_LIVE_PATHS" >&2
        printf 'SKIP reason=library-missing path=%s\n' "$REAP_AW_LIVE_PATHS"
        exit 3
    }
    LIVE_PATHS_LIB="${REAP_AW_LIVE_PATHS}"
else
    # ⛔ THE SAME `${VAR:+…}` RULE THIS FILE STATES 180 LINES ABOVE (review F-E): a piped start leaves
    # `SELF_DIR` empty (`/lib/live-paths.sh`) and an unset HOME leaves `/.pi/…`, i.e. absolute paths no
    # checkout owns. Fails closed either way, but a file that states a rule must not break it, or the
    # next reader cannot tell which spelling is correct.
    for cand in ${SELF_DIR:+"$SELF_DIR/lib/live-paths.sh"} \
                ${HOME:+"$HOME/.pi/agent/scripts/lib/live-paths.sh"}; do
        [ -n "$cand" ] && [ -f "$cand" ] && { LIVE_PATHS_LIB="$cand"; break; }
    done
fi
if [ -z "$LIVE_PATHS_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — lib/live-paths.sh not found (looked beside this script and in $HOME/.pi/agent/scripts/lib)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=library-missing\n'
    exit 3
fi
# shellcheck source=lib/live-paths.sh
. "$LIVE_PATHS_LIB" || { printf 'SKIP reason=library-unreadable path=%s\n' "$LIVE_PATHS_LIB"; exit 3; }

now() { date +%s; }
# budget_spent <deadline-epoch> — rc 0 when the pass's TIME bound is spent (#3278).
# ONE named predicate, so the bound is a single thing a test can mutate. The count cap it replaced was
# charged in ONE place and BEFORE the age floor (`GITLESS_DONE=$((GITLESS_DONE + 1))` at `:605` on
# 2c18ff89a, with the cap test at `:587`), which is why ~89 % of its ten slots went to trees the floor
# preserves anyway. That ordering — not a second check site — is what MUT_ORDER pins.
budget_spent() { [ "$(now)" -ge "$1" ]; }
# budget_before_removal <deadline-epoch> — the LAST gate above the destructive call, kept as its OWN
# named predicate rather than a second `budget_spent` line. It answers a different question from the
# pre-census gate ("did the census I just ran consume the budget?") and, unlike that gate, it is
# UNREACHABLE from the `--dry-run` path and from any `BUDGET=0` fixture — which is exactly how it went
# untested until review round 11: deleting it left all 20 cases green because the pre-census gate had
# already fired for every candidate (agent-infra#3442). A named predicate is the shape this file already
# uses for `budget_spent` ("ONE named predicate, so the bound is a single thing a test can mutate"), and
# a test reverts exactly this one.
budget_before_removal() { budget_spent "$1"; }
# file_mtime <path> — epoch mtime, portable across GNU (stat -c %Y) and BSD (stat -f %m).
file_mtime() {
    local m
    m="$(stat -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    stat -f '%m' "$1" 2>/dev/null
}
# gb <cmd...> — run a git/rm probe under a wall-clock bound. `timeout` is GNU; a host without it
# still gets the probe (the bound is a courtesy on a hang, not a correctness gate here) rather than
# silently skipping every classification on macOS.
gb() { if command -v timeout >/dev/null 2>&1; then timeout "$GIT_TIMEOUT" "$@"; else "$@"; fi; }

# ── lock ────────────────────────────────────────────────────────────────────────────────────────
# Two sweeps must not run over one root: each would classify the same directory before either
# removed it, and the loser reports a removal failure for a directory that is already gone. A lock
# we cannot create is a refusal (3), never a pass.
LOCK_HELD=0
acquire_lock() {
    local owner started _lmt _lage
    mkdir -p "$STATE_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    # ⛔ THE TOKEN IS ONE LINE: `pid=<n> started=<epoch>`. Parsing `s/^pid=//` captures the whole
    # tail (`"1234 started=5678"`), which `num` rejects — so the live-owner check never ran, the
    # tokenless arm (anchored `^started=`) never matched either, and EVERY existing lock was declared
    # stale and DELETED WHILE ITS OWNER WAS LIVE. That removed the only exclusion between two
    # concurrent sweeps of one root: both classify the same directory, both remove it, and the loser
    # reports a removal failure for something already gone. Capture the FIELDS, not the tail.
    owner="$(sed -n 's/^.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    if num "$owner" && kill -0 "$owner" 2>/dev/null; then
        log_line "SKIP reason=lock-held pid=$owner"
        return 3
    fi
    # ⛔ ONLY AN UNATTRIBUTABLE LOCK IS "TOKENLESS", AND ONLY WHILE IT IS YOUNG. The old test fired on a
    # token it COULD attribute (pid parsed, `kill -0` says the owner is gone): a SIGKILLed sweep then
    # refused every contender for the whole stale window for no reason, and a `started` in the FUTURE
    # (clock step-back, a token from another box) made `age` negative — `-le stale` always true — so the
    # lock was unreclaimable for the entire skew (measured: `age=-500000s`). A lock whose owner is
    # provably gone is STALE; a future timestamp is stale; an unattributable lock is refused only while
    # it is younger than the window, because a live sweep may be between `mkdir` and its token write.
    if ! num "$owner"; then
        if [ -f "$LOCK_DIR/token" ]; then _lmt="$(file_mtime "$LOCK_DIR/token")"; else _lmt="$(file_mtime "$LOCK_DIR")"; fi
        if num "$_lmt"; then
            _lage=$(( $(now) - _lmt ))
            if [ "$_lage" -ge 0 ] && [ "$_lage" -le "$LOCK_STALE_SECONDS" ]; then
                log_line "SKIP reason=lock-tokenless age=${_lage}s"
                return 3
            fi
        fi
    fi
    log_line "note: reclaiming a STALE lock ($LOCK_DIR, pid ${owner:-?} is gone)"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log_line "SKIP reason=lock-uncreatable path=$LOCK_DIR"; return 3; }
    printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
    LOCK_HELD=1; return 0
}
release_lock() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }; return 0; }
trap release_lock EXIT

# ── the pin ────────────────────────────────────────────────────────────────────────────────────
# "Never prune the sha pinned in .agent-infra-stamp.json" (#2542). The stamp carries the harness
# PATH and the COMMIT; both are read, and both are used:
#   * PIN_PATHS — every absolute path in the stamp (the harness tree, its scripts dir, …)
#   * PIN_SHAS  — the commit, full and 12-char, so a directory NAMED after the pin is protected too
# Absent stamp = no pin (a box with no harness has no pinned tree). Unreadable-but-present stamp IS a
# refusal: the one case this arm exists for is "the pin was there and I could not read it".
PIN_PATHS=""; PIN_SHAS=""
load_pin() {
    local f="" cand _pc _pr _pcan
    if [ -n "${REAP_AW_STAMP:-}" ]; then
        f="$REAP_AW_STAMP"
        [ -r "$f" ] || { log_line "SKIP reason=stamp-unreadable path=$f"; return 3; }
    else
        # ⛔ `${VAR:+…}`, NOT `${VAR:-}` (review round-3 F5): with HOME unset the second candidate is
        # `/.pi/orchestrator/…` — an absolute path no box owns, and the exact spelling the block 290 lines
        # above declares forbidden. Fails closed either way, but a file that states a rule must not break
        # it, or the next reader cannot tell which spelling is correct.
        for cand in ${CELL_HOME:+"$CELL_HOME/orchestrator/.agent-infra-stamp.json"} \
                    ${HOME:+"$HOME/.pi/orchestrator/.agent-infra-stamp.json"}; do
            [ -n "$cand" ] && [ -f "$cand" ] && { f="$cand"; break; }
        done
    fi
    [ -n "$f" ] && [ -f "$f" ] || return 0
    # ⛔ THE KEY CLASS IS `[A-Za-z0-9_]*`, not `[A-Za-z]*`: a stamp key with an underscore or a digit
    # (`harness_alias`, `worker2`) did not match at all, so its path was silently absent from the pin
    # and the tree it named was reapable.
    PIN_PATHS="$(sed -n 's/.*"\([A-Za-z0-9_]*\)": *"\(\/[^"]*\)".*/\2/p' "$f" 2>/dev/null)"
    # ⛔ CANONICALISE THE PINS, KEEPING THE RAW SPELLING. Candidates are compared by their PHYSICAL
    # path, so a stamp that names its tree through a symlink never matched the tree it names: on macOS
    # (`/tmp` -> `/private/tmp`) the default `--root /tmp` makes every candidate `/private/tmp/…`,
    # and the path arm of the pin was dead BY CONSTRUCTION there. Both spellings are kept, so the pin
    # protects the tree however the stamp and the filesystem spell it.
    if [ -n "$PIN_PATHS" ]; then
        _pc=""
        while IFS= read -r _pr; do
            [ -n "$_pr" ] || continue
            _pc="${_pc}${_pc:+
}$_pr"
            _pcan="$(lp_canon "$_pr")" || _pcan=""
            [ -n "$_pcan" ] && [ "$_pcan" != "$_pr" ] && _pc="${_pc}${_pc:+
}$_pcan"
        done <<<"$PIN_PATHS"
        PIN_PATHS="$_pc"
    fi
    PIN_SHAS="$(sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$f" 2>/dev/null)"
    [ -n "$PIN_PATHS$PIN_SHAS" ] || { log_line "SKIP reason=stamp-unparseable path=$f"; return 3; }
    return 0
}

pinned() { # <canonical path> <basename> -> 0 when the pin protects it
    local p="$1" base="$2" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        _lp_rel "$p" "$cand" && return 0
        _lp_rel "$cand" "$p" && return 0
    done <<<"$PIN_PATHS"
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$base" in "$cand"*) return 0 ;; esac
        case "$cand" in "$base"*) return 0 ;; esac
    done <<<"$PIN_SHAS"
    return 1
}

# ── one candidate ──────────────────────────────────────────────────────────────────────────────
# repo_root_of <worktree> — the repo that owns a LINKED worktree, or empty when the record is gone.
# Reads `.git` (a FILE holding `gitdir: <repo>/.git/worktrees/<name>`) rather than running git, so it
# works for a worktree whose own git has already been pruned.
repo_root_of() {
    local wt="$1" line gd
    [ -f "$wt/.git" ] || return 1
    line="$(head -1 "$wt/.git" 2>/dev/null)"
    gd="${line#gitdir: }"
    [ "$gd" != "$line" ] || return 1
    case "$gd" in
        */.git/worktrees/*) printf '%s' "${gd%%/.git/worktrees/*}" ;;
        /*/worktrees/*)     printf '%s' "${gd%%/worktrees/*}" ;;
        *) return 1 ;;
    esac
}

# head_state <worktree> — `branch=<b>|detached` + `head=<sha>` + `dirty=<n>`, best effort (empty when
# git cannot answer: an unreadable checkout is still removable debris, and this is REPORTING only).
head_state() {
    local wt="$1" br sha dirty dirty_raw
    br="$(gb git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null)" || br=""
    sha="$(gb git -C "$wt" rev-parse --short=8 HEAD 2>/dev/null)" || sha=""
    # ⛔ AN UNREADABLE TREE IS NOT A CLEAN TREE. `… | wc -l` on a git that FAILED prints 0, and 0 is
    # the value that clears the default `--dirty keep` dial — so a dangling `.git` file (the record
    # pruned, the gitdir gone: exactly the moved/pruned population this arm exists for) would have read
    # as "clean" and `rm -rf` would have taken uncommitted work with it. Capture the status FIRST and
    # report `?` when git does not answer; the dial then KEEPS it.
    if dirty_raw="$(gb git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        dirty="$(printf '%s\n' "$dirty_raw" | awk 'NF { n++ } END { print n + 0 }')"
    else
        dirty="?"
    fi
    num "$dirty" || dirty="?"
    [ -n "$br" ] && printf 'branch=%s' "$br" || printf 'detached'
    printf ' head=%s dirty=%s' "${sha:-?}" "$dirty"
}

# TOCTOU_REPROBE <worktree> — a FRESH census + a fresh dirty check, immediately before removal.
#   The classification above ran against ONE snapshot taken at pass start; the removal can be up to
#   BUDGET (300s/root) later, and a lane that enters an old, clean worktree during that window used to
#   lose it with a live cwd inside (measured: the witness's cwd read `<path> (deleted)`). The sibling
#   owner re-checks exactly here for the same reason (`pi-reap-worktrees.sh`'s F4/#1105). Any new
#   witness — a live cwd/exe/argv, an unreadable fresh census, or a tree that is no longer clean — is a
#   PRESERVE.
TOCTOU_WHY=""
toctou_preserve() { # <worktree> -> 0 = still removable, 1 = PRESERVE (TOCTOU_WHY names it)
    local wt="$1" fresh rc out dirty_n
    TOCTOU_WHY=""
    fresh="$(mktemp -d "${TMPDIR:-/tmp}/reap-aw-reprobe.XXXXXX" 2>/dev/null)" || { TOCTOU_WHY="re-probe-unavailable"; return 1; }
    if ! lp_census "$fresh" >/dev/null 2>&1; then
        rm -rf "$fresh" 2>/dev/null
        TOCTOU_WHY="re-probe-census-unreadable"
        return 1
    fi
    # ⛔ THE CENSUS FILE, NOT THE DIRECTORY. `lp_census DIR` writes `DIR/live-paths.tsv`, and the two
    # witnesses `read` the path they are given — handed a DIRECTORY they read nothing, found no witness,
    # and returned "clean", so this arm could never preserve anything (and every candidate emitted three
    # `read: read error: 0: Is a directory` lines). The fresh-census half was dead code.
    if lp_path_held "$fresh/live-paths.tsv" "$wt"; then TOCTOU_WHY="entered-during-pass ($LP_HOLD_WHY)"; rm -rf "$fresh"; return 1; fi
    if lp_path_named "$fresh/live-paths.tsv" "$wt"; then TOCTOU_WHY="argv-named-during-pass ($LP_NAME_WHY)"; rm -rf "$fresh"; return 1; fi
    if [ "$DIRTY_MODE" = keep ] && [ -f "$wt/.git" ]; then
        out="$(head_state "$wt")"
        dirty_n="$(printf '%s' "$out" | sed -n 's/.*dirty=\([0-9][0-9]*\).*/\1/p')"
        case "$dirty_n" in
            0) : ;;
            # ⛔ '' = git did NOT answer. The classifier keeps that case (`reason=clean-unknown`); reading
            # it as CLEAN here would remove a tree whose state git cannot report — and the justification
            # "the dial already kept those at classification" reasons about the very snapshot this
            # re-probe exists because it is stale.
            '') TOCTOU_WHY="re-probe-state-unreadable"; rm -rf "$fresh"; return 1 ;;
            *) TOCTOU_WHY="became-dirty(dirty_n=$dirty_n)"; rm -rf "$fresh"; return 1 ;;
        esac
    fi
    rm -rf "$fresh" 2>/dev/null
    return 0
}

remove_one() { # <worktree-canonical-path> <repo> — 0 removed, 1 not removed (named by the caller)
    # ⛔ HOW it was removed is REPORTED, never inferred from a variable that only means "a repo was
    # found": an unregistered (moved) worktree is removed with `rm`, and a report that called that
    # `git-worktree-remove` would tell a reader its branch was preserved by git when it was not —
    # the exact class of claim this script is not allowed to make.
    REMOVE_HOW=""
    local wt="$1" repo="$2" list reg=0 line
    if [ -n "$repo" ] && gb git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        # ⛔ IS **THIS PATH** A WORKING TREE OF THAT REPO? A linked worktree can be MOVED (the admin
        # record keeps the path it was created at, which is how a lane's checkout ends up as
        # `/tmp/<newname>` while git still calls it `wt-2356`). For a moved directory `git worktree
        # remove <new path>` fails with "not a working tree" — 16 of 16 removals on this box, measured
        # — and treating that as "a live holder" would have made the whole class inert while reporting
        # a removal FAILURE, which is the shape this repo keeps removing. `worktree list` is the
        # authority on the CURRENT path, so it decides which arm runs.
        # Capture FIRST, never `| grep -q`: an early grep exit down a pipe lets the producer take
        # SIGPIPE and under `set -o pipefail` a MATCH then reads as no match (the repo's own rule).
        # ⛔ A LIST WE COULD NOT READ IS NOT "NOT REGISTERED". An empty list from a failed or
        # timed-out `worktree list` used to fall through to the `rm -rf` arm below — deleting a worktree
        # git still has registered, which is precisely the "a refusal here is never a licence to
        # `rm -rf`" case. No answer means no removal: report the failure.
        if ! list="$(gb git -C "$repo" worktree list --porcelain 2>/dev/null)"; then
            return 1
        fi
        while IFS= read -r line; do
            [ "$line" = "worktree $wt" ] && { reg=1; break; }
        done <<<"$list"
        if [ "$reg" = 1 ]; then
            # ⛔ REGISTERED, SO GIT OWNS THE REMOVAL — and it never deletes the branch, so the commits
            # survive. A refusal here (a lock, or a holder git itself can see) is a FAILURE to report,
            # never a licence to `rm -rf`: that is the exact "look at what holds it" case.
            if gb git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; then
                REMOVE_HOW="git-worktree-remove"; return 0
            fi
            return 1
        fi
    fi
    # NOT registered at its current path: the admin record is gone or names a different directory, so
    # no git verb can deregister it and the directory IS debris. The dirty dial above already refused
    # uncommitted work, and a linked worktree holds no objects of its own (the commits live in the
    # shared store), so nothing the dials cleared is destroyed by this removal.
    # ⛔ AN `if` WITH NO `else` RETURNS 0, and this was the last command in the function — so a FAILED
    # `rm -rf` (permissions, EBUSY, a live mount) reported itself as a SUCCESSFUL removal and let the
    # entry point credit a `df` delta to a removal that never happened. Return explicitly.
    if gb rm -rf "$wt" >/dev/null 2>&1; then REMOVE_HOW="rm"; return 0; fi
    return 1
}

# ── the gitless arm's tests (#3278) ───────────────────────────────────────────────────────────
# ⛔ WHY THIS ARM EXISTS. The sweep below enumerates directories whose `.git` is a FILE. That is the
# correct test for a LINKED worktree, and it is what keeps a primary checkout out of reach — but it
# also means a `/tmp/<name>` scratch tree with NO `.git` is skipped by EVERY arm the scheduled pass
# runs: `pi-reap-worktrees.sh` only sees REGISTERED checkouts, this file only sees linked ones.
# Measured on cell-3 (2026-11-02): 453 such trees holding 4,594 MB, invisible to the hourly pass,
# while the box reached 0 bytes free and its lanes died. The class is the one that grows.
#
# ⛔ IT IS NOT A WEAKENING OF THE LINKED-WORKTREE PREDICATE. The linked arm keeps its four proofs
# (open-pr, dirty, no-pr, main-checkout) untouched; this arm adds a population those proofs cannot
# describe, and it carries every guard they carry that DOES apply (age floor, live-pid census,
# argv-named, pin, containment, toctou re-proof) plus the keep list.
git_below() { # <dir> — is a git marker INSIDE the tree? Then a git arm owns it, not this one.
    local x y
    # ⛔ DEPTH 3, NOT ONE LEVEL (review of #3278, measured): a repo nested at `x/a/b/.git` was
    # classified gitless and removable by the one-level version.
    # ⛔ AND BY PURE PATH EXPANSION, NOT `find` (measured at 08:0xZ, the reason a scheduled pass exited
    # 124): `find -maxdepth 3` forks and re-walks every directory of a 250 MB scratch tree, ~450 times
    # per pass — the arm overran its class bound and the whole worktree class went RED. These globs
    # readdir exactly three levels and fork nothing.
    for x in "$d"/*/; do
        [ -d "$x" ] || continue
        x="${x%/}"
        [ -e "$x/.git" ] && return 0
        # a BARE repo nested in the tree is the same object class as a nested `.git`: `HEAD` +
        # `objects/` + `refs/` ARE the repository (review of #3278 round 2).
        if [ -e "$x/HEAD" ] && [ -d "$x/objects" ] && [ -d "$x/refs" ]; then return 0; fi
        for y in "$x"/*/; do
            y="${y%/}"
            [ -e "$y/.git" ] && return 0
            if [ -e "$y/HEAD" ] && [ -d "$y/objects" ] && [ -d "$y/refs" ]; then return 0; fi
        done
    done
    return 1
}
gitless_keep() { # <canon> — is it a box dependency named in the keep list?
    # ⛔ COMPARED ON THE CANONICAL PATH, and the list is read with `while read` not `$(…)` word
    # splitting (review of #3278): splitting dropped the meaning of any entry containing a space —
    # `REAP_AW_GITLESS_KEEP='/tmp/keep dir'` silently discarded the entry and DELETED the tree — and a
    # raw-path comparison let `--root /tmp/` (→ `/tmp//actions-runner`) slip past the runner install.
    local k kc
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        kc="$(lp_canon "$k" 2>/dev/null)" || kc=""
        [ -n "$kc" ] || kc="${k%/}"
        [ -n "$kc" ] || continue
        case "$1" in
            "$kc"|"$kc"/*) GITLESS_KEEP_WHY="named in the --include-gitless keep list ($kc)"; return 0 ;;
        esac
        # ⛔ A TRAILING-GLOB ENTRY IS A PREFIX RULE. The documented safe-sweep exclusion set
        # (docs/ops/disk-consumers.md R4) is a family, not a list — `/tmp/venv-shared-py312` holds a
        # lane's INTERPRETER via VIRTUAL_ENV, which the cwd/exe/argv census cannot see, so a prefix
        # entry is the only way to name it (review of #3278).
        case "$kc" in
            *'*'*) case "$1" in $kc|$kc/*) GITLESS_KEEP_WHY="matches keep-list pattern ($kc)"; return 0 ;; esac ;;
        esac
    done <<<"$(printf '%s' "${GITLESS_KEEP:-}" | tr ':' '\n')"
    return 1
}
remove_gitless() { # <canon> — no git, so no branch/ref/reflog exists that could preserve anything
    if gb rm -rf "$1" >/dev/null 2>&1; then REMOVE_HOW="rm-gitless"; return 0; fi
    # ⛔ A READ-ONLY DIRECTORY INSIDE THE TREE DEFEATS `rm -rf` (mode `dr-xr-xr-x`: unlinking an entry
    # needs WRITE on the directory, not just on the file), and the arm then reports
    # `removal-failed` on every pass — measured on cell-3: /tmp/atom-e2e held
    # `…/scripts/olddir` (dr-xr-xr-x, from a 17-day-old test fixture) and kept the hourly pass RED at
    # rc=4 through two runs, long after the tree itself was proven removable. The tree has already been
    # proven removable by every guard above (age, no live pid, no `.git`, not kept, inside the root, no
    # symlink), so restoring the owner's write bit and completing the SAME decision is not a new one.
    gb chmod -R u+rwX -- "$1" >/dev/null 2>&1
    if gb rm -rf "$1" >/dev/null 2>&1; then REMOVE_HOW="rm-gitless(chmod)"; return 0; fi
    return 1
}

# ── the sweep ─────────────────────────────────────────────────────────────────────────────────
CAND=0; REAPED=0; KEPT=0; FAILED=0; REMOVE_HOW=""
sweep_root() { # <root>
    local root="$1" d canon base mt age repo out deadline dirty_n root_canon gitless GITLESS_KEEP_WHY _ref _refc GITLESS_DONE=0
    deadline=$(( $(now) + BUDGET ))
    [ -d "$root" ] || { log_line "note: scratch root $root does not exist — nothing to sweep there"; return 0; }
    root_canon="$(lp_canon "$root")" || root_canon=""
    if [ -z "$root_canon" ]; then
        # The sweep's authority IS the root it was given. If the root cannot be resolved physically we
        # cannot prove that anything we would classify is inside it, so nothing is classified.
        log_line "SKIP reason=root-unresolvable root=$root — cannot prove that a candidate is inside the scratch root; nothing was classified"
        return 3
    fi
    for d in "$root"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        # ⛔ A SYMLINK IS NEVER FOLLOWED. The glob `*/` matches a symlink-to-directory, `-d` follows it,
        # and every later step resolves the TARGET (`lp_canon` = `pwd -P`) — so a link sitting in the
        # scratch root would make this sweep classify, and `rm -rf`, a directory OUTSIDE the root. A
        # link cannot be an abandoned checkout either: a real one is a directory whose `.git` is a
        # file, and a link to one is somebody's alias, not debris.
        if [ -L "$d" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=symlink (never followed: resolving it would leave the scratch root)"; continue
        fi
        # ONLY a linked worktree. A primary checkout's `.git` is a DIRECTORY and is NEVER a candidate
        # (this is the test that keeps the hub and the cell's own repo out of reach, by construction).
        gitless=0
        if [ -f "$d/.git" ]; then
            :   # a linked worktree — the four proofs below own it, unchanged
        elif [ -L "$d/.git" ] || [ -e "$d/.git" ]; then
            # `.git` is a DIRECTORY or a SYMLINK: a primary checkout (or a checkout whose gitdir link
            # went dangling — `-L` also catches a broken link, which `-f`/`-e` both miss and which
            # used to fall through into the gitless arm with the tree's work still in it; review of
            # #3278, measured). Named, so the preservation is visible in the pass log instead of
            # being an anonymous `continue`.
            KEPT=$((KEPT + 1)); log_line "PRESERVED($d, main-checkout) .git is a DIRECTORY/link — a primary checkout is never a candidate"; continue
        else
            # ── NO `.git` AT ALL: the uncovered class (#3278) ─────────────────────────────────────
            if [ "$INCLUDE_GITLESS" != 1 ]; then
                KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=not-a-worktree (no .git; --include-gitless is off)"; continue
            fi
            # ⛔ THE TWO BOUNDS ARE **NOT** HERE ANY MORE (#3278). They used to be checked here, BEFORE
            # the age floor — so a tree the floor would preserve still consumed a cap unit, and on a
            # root with thousands of young trees the ten slots went to trees that could never be
            # removed (measured: 89 % of them). ⛔ TWO DIFFERENT THINGS MOVED, and conflating them is
            # what makes this block read as its own contradiction: the CHARGE (`GITLESS_DONE++` below)
            # moved after the age floor, so a young tree still costs no slot; the REFUSAL did NOT move
            # with it — it is the O(1) check at the TOP of this branch, ahead of the structural
            # rejections and of everything that forks or walks (see the next block). The TIME bound is a
            # separate pre-census gate further down. Cheap structural rejections are the only per-entry
            # work that legitimately precedes the age test.
            # ⛔ THE COUNT CEILING SHORT-CIRCUITS THE SCAN (#3278 P1, completed in review round 11).
            # It needs NO per-entry work — one integer compare — so it sits ABOVE everything that forks
            # or walks. That is the difference between the ceiling being a bound and only a label:
            # with the check downstream of the scan, an exhausted ceiling still paid ~6 forks per entry
            # (`git_below`'s two-level walk, `lp_canon`, the home-or-state loop, the keep list, `pinned`)
            # to print rows that all say `gitless-cap`. MEASURED on a 300-entry fixture with the census
            # isolated behind a synthetic `/proc`: 8.98 s here versus 0.60 s on `2c18ff89a`, for a
            # BYTE-IDENTICAL pass record (`candidates=10 kept=290`); on the 3,314-entry root #3278
            # measured that is ~104 s of the 1800 s class timeout spent classifying trees the ceiling had
            # already refused, against a population growing ~48.8 trees/hour. `2c18ff89a` carried exactly
            # this shape and recorded why: "BOTH LIMITS ARE CHECKED BEFORE ANY PER-TREE WORK … the
            # expensive part of an over-budget arm still ran to the end of the root (measured: 17+ min,
            # class timeout, rc=3 every hour)". The charge stays where P1 put it — after the age floor —
            # so a young tree still costs no slot; what changes is that a tree the *ceiling* refuses now
            # costs one `stat`-free compare instead of the whole scan.
            # ⛔ SO PAST THE CEILING THE ROW NAMES THE CEILING, not the tree's own reason: this arm did
            # not look, and `gitless-cap` is the true statement about why the tree was preserved. Every
            # outcome here is a PRESERVE.
            if [ -n "$GITLESS_MAX" ] && [ "$GITLESS_DONE" -ge "$GITLESS_MAX" ]; then
                KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=gitless-cap (${GITLESS_DONE}/${GITLESS_MAX} classified in THIS ROOT; this root's remainder is PRESERVED for the next run — REAP_AW_GITLESS_MAX is a per-root ceiling, default 10, and it counts AGED candidates only)"; continue
            fi
            if git_below "$d"; then
                KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=git-below (a .git lives inside the tree, so a git arm owns it)"; continue
            fi
            # ⛔ A BARE REPO HAS NO `.git` AT ALL: `HEAD` + `objects/` + `refs/` ARE the repository.
            # Classifying it gitless would take every commit in it (review of #3278, measured).
            if [ -e "$d/HEAD" ] && [ -d "$d/objects" ] && [ -d "$d/refs" ]; then
                KEPT=$((KEPT + 1)); log_line "PRESERVED($d, bare-repo) HEAD+objects/+refs/ — this IS a git repository, not scratch"; continue
            fi
            # ⛔ THE HOME/STATE GUARD IS NOT HERE — it runs on the CANONICAL path below (review of
            # #3278 round 2: comparing the raw `$d` let `--root /tmp/` — `/tmp//cell-home` — delete the
            # cell HOME in an armed pass; the same spelling bug the keep list had).
            # ⛔ `GITLESS_DONE` IS NOT INCREMENTED HERE. Charging the count unit at STRUCTURAL
            # classification — before the age floor — is what spent 89 % of the old cap on trees that
            # could not be removed; the increment sits after the age test, with the bounds it serves.
            gitless=1
        fi
        canon="$(lp_canon "$d")" || canon=""
        base="$(basename "$d")"
        if [ -z "$canon" ] || [ "$canon" = "$root_canon" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=unresolvable"; continue
        fi
        # ⛔ AND THE CONTAINMENT RE-CHECK. `-L` is not the only way out — a bind mount, or a `pwd -P`
        # that reports an ancestor, would leave the canonical path outside the root this sweep was
        # told to cover. The canonical path (not the given one) is what gets classified and removed,
        # so the canonical path is what must be proven inside.
        if ! _lp_rel "$canon" "$root_canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=outside-root ($canon is not inside $root_canon — this sweep has no authority there)"; continue
        fi
        # ⛔ NEVER THE CELL'S OWN HOME, NOR THE PASS'S STATE DIR — compared on the CANONICAL path,
        # with each reference canonicalised too (review of #3278 round 2, measured: a non-canonical
        # `--root` spelling reaped /tmp/cell-home, which holds ~9.8 GB of `.pi` / `.venvs` here, and the
        # structural guard — the stamp's ancestor-pin — is absent on the scheduled path).
        # ⛔ AND `CELL_HOME_DEFAULT` CARRIES THE CELL HOME ITSELF, because the guard must not depend on
        # its callers getting the environment right (see its assignment above for the measurement and
        # for why it is NOT fixed by exporting `CELL_HOME`). Resolving it here covers every caller —
        # the systemd unit, the darwin launcher, a manual run — instead of trusting each to export it.
        if [ "$gitless" = 1 ]; then
            for _ref in "${HOME:-}" "$CELL_HOME_DEFAULT" "${REAP_AW_STATE_DIR:-}"; do
                [ -n "$_ref" ] || continue
                _refc="$(lp_canon "$_ref" 2>/dev/null)" || _refc=""
                [ -n "$_refc" ] || _refc="${_ref%/}"
                [ -n "$_refc" ] || continue
                case "$canon" in
                    "$_refc"|"$_refc"/*)
                        KEPT=$((KEPT + 1)); log_line "PRESERVED($canon, home-or-state) the cell HOME / pass state dir is never a candidate"; continue 2 ;;
                esac
            done
        fi
        # ⛔ THE KEEP LIST IS CHECKED ON THE CANONICAL PATH, and it is checked for GITLESS candidates
        # only: a linked worktree's protection is the four git proofs, not this list (review of #3278).
        if [ "$gitless" = 1 ] && gitless_keep "$canon"; then
            KEPT=$((KEPT + 1)); log_line "PRESERVED($canon, keep-list) ${GITLESS_KEEP_WHY:-named in the gitless keep list}"; continue
        fi
        mt="$(file_mtime "$d")"
        if ! num "$mt"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=no-mtime (cannot prove its age)"; continue
        fi
        age=$(( ( $(now) - mt ) / 60 ))
        [ "$age" -lt 0 ] && age=0
        # ── the guards, in order, each of them NAMED ──────────────────────────────────────────
        if pinned "$canon" "$base"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=pinned (the .agent-infra-stamp.json pin protects it; age=${age}m)"
            continue
        fi
        # ⛔ CHEAP ELIGIBILITY BEFORE THE EXPENSIVE SCAN — FOR THE GITLESS ARM ONLY (#3278).
        # The age floor is the most selective gate this script has and it costs one `stat`; the live-pid
        # census costs SECONDS PER CANDIDATE on a loaded box (3,813 rows, measured 2026-11-07:
        # `lp_path_held` 3.6 s + `lp_path_named` 8.1 s). Running the census first meant every tree the
        # floor was about to preserve still paid for it — so a pass spent its entire budget proving age
        # on thousands of trees it would never remove. `systemd-tmpfiles` orders it the same way: the
        # age field decides what is a candidate, and nothing else is asked about a non-candidate.
        # ⛔ THE LINKED ARM KEEPS ITS ORDER (its census runs first, so a young-and-held checkout reports
        # the WITNESS that preserved it rather than `young` — the property `disk-reaper.test.sh` T2
        # asserts). Its population is tens of trees; the thousands are gitless. Changing its reporting
        # precedence would be a behaviour change with no measured cost behind it.
        if [ "$gitless" = 1 ]; then
            if [ "$age" -lt "$AGED_MINUTES" ]; then
                KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=young (age=${age}m < ${AGED_MINUTES}m)"
                continue
            fi
            # ⛔ THE UNIT IS CHARGED BELOW, after this floor and before the census — that position is
            # #3278's P1, and a young tree costs no slot because of it. There is deliberately NO ceiling
            # TEST in this block: the refusal is the O(1) check at the TOP of the branch, and a second
            # test here could never fire (`GITLESS_DONE` has not moved since the top of this iteration),
            # so it would be an inert guard that reads like protection — the class this PR deletes.
        fi
        # ⛔ THE TIME BOUND IS THE REAL GUARD, FOR BOTH ARMS, AND IT SITS BEFORE THE EXPENSIVE WORK.
        # The census, `git status` and the re-probe are what it exists to bound; an unprocessed
        # candidate is PRESERVED, so stopping here can only fail SAFE. (Before #3278 this check was
        # after the census, so the pass overran its budget by one FULL census per remaining candidate —
        # minutes, on a box with dozens of linked worktrees. Moving it above the census is the only
        # change to the linked arm's order, and it is observable only on a pass that has already spent
        # its budget: `reason=budget` instead of `reason=young`/`reason=live-cwd`. Every one of those
        # outcomes PRESERVES.)
        if budget_spent "$deadline"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=budget (the ${BUDGET}s sweep budget is spent; unprocessed trees are PRESERVED)"; continue
        fi
        if [ "$gitless" = 1 ]; then GITLESS_DONE=$((GITLESS_DONE + 1)); fi
        if lp_path_named "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=argv-named ($LP_NAME_WHY; age=${age}m)"
            continue
        fi
        if lp_path_held "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=live-cwd ($LP_HOLD_WHY; age=${age}m)"
            continue
        fi
        # the LINKED arm's age floor, in its original position (after the census) — see above.
        if [ "$age" -lt "$AGED_MINUTES" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=young (age=${age}m < ${AGED_MINUTES}m)"
            continue
        fi
        if [ "$gitless" = 1 ]; then repo=""; else repo="$(repo_root_of "$d")" || repo=""; fi
        # ⛔ ONLY A LINKED WORKTREE IS ASKED FOR ITS TREE STATE. For a gitless tree `head_state` is
        # three bounded git forks on a directory git rejects — charged against the budget that exists
        # to bound exactly this — and its answer is discarded anyway (review of #3278).
        if [ "$gitless" = 1 ]; then out="kind=gitless"; else out="$(head_state "$d")"; fi
        if [ "$DIRTY_MODE" = keep ] && [ "$gitless" != 1 ]; then
            dirty_n="$(printf '%s' "$out" | sed -n 's/.*dirty=\([0-9][0-9]*\).*/\1/p')"
            case "$dirty_n" in
                '') # git did not answer: `--dirty keep` cannot PROVE the tree is clean, so it keeps it.
                    KEPT=$((KEPT + 1))
                    log_line "KEPT   $canon reason=clean-unknown (git could not report the tree state, so the --dirty keep dial cannot prove it clean; age=${age}m)"
                    continue ;;
                0) ;;
                *)  KEPT=$((KEPT + 1))
                    log_line "KEPT   $canon reason=dirty($dirty_n) (uncommitted work is the one thing removal cannot give back; --dirty reap restores the measured predicate; age=${age}m)"
                    continue ;;
            esac
        fi
        CAND=$((CAND + 1))
        if [ "$DRY_RUN" = 1 ]; then
            # ⛔ THE PATH IS ALONE ON ITS LINE, and the metadata is an indented line beneath it — the
            # SAME shape `pi-reap-worktrees.sh` uses (`preserve <path>` + `reason=…`). The entry point
            # sizes a dry-run candidate with `du` on THE REST OF THE LINE, so a `(age=…)` suffix made
            # every candidate measure as `? bytes unmeasured` (measured: 17 of 17 on this box).
            log_line "remove $canon"
            log_line "         age=${age}m $out"
            continue
        fi
        if budget_before_removal "$deadline"; then
            log_line "KEPT   $canon reason=budget (the ${BUDGET}s sweep budget is spent; unprocessed worktrees are PRESERVED)"
            KEPT=$((KEPT + 1)); continue
        fi
        # ⛔ RE-PROVE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL. Everything above ran against ONE snapshot.
        if ! toctou_preserve "$canon"; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $canon reason=toctou ($TOCTOU_WHY; the pass-start snapshot was up to ${BUDGET}s stale, and a live holder is never a guess; age=${age}m)"
            log "PRESERVE-TOCTOU $canon $TOCTOU_WHY"
            continue
        fi
        if [ "$gitless" = 1 ]; then
            if remove_gitless "$canon"; then
                REAPED=$((REAPED + 1)); log_line "REAPED $canon how=${REMOVE_HOW:-rm} age=${age}m $out"
                log "reaped $canon how=rm-gitless age=${age}m"
            else
                FAILED=$((FAILED + 1)); log_line "ERR    $canon reason=remove-failed (a live holder would fail exactly this way; look before retrying)"
                log "REMOVAL FAILED $canon age=${age}m"
            fi
            continue
        fi
        if remove_one "$canon" "$repo"; then
            # `how=` comes from the ARM THAT RAN, never from "a repo was found": an unregistered
            # (moved) worktree is removed with `rm`, and calling that `git-worktree-remove` told a
            # reader its branch had been preserved by git when it had not.
            REAPED=$((REAPED + 1)); log_line "REAPED $canon how=${REMOVE_HOW:-rm} age=${age}m $out"
            log "reaped $canon age=${age}m $out repo=${repo:-none}"
        else
            FAILED=$((FAILED + 1))
            log_line "ERR    $canon reason=remove-failed (a live holder would fail exactly this way; look before retrying)"
            log "REMOVAL FAILED $canon age=${age}m repo=${repo:-none}"
        fi
    done
    return 0
}

if ! acquire_lock; then exit 3; fi
if ! load_pin; then exit 3; fi

CENSUSDIR="$(mktemp -d "${TMPDIR:-/tmp}/reap-aw-census.XXXXXX" 2>/dev/null)" || CENSUSDIR=""
if [ -z "$CENSUSDIR" ]; then log_line "SKIP reason=census-dir-uncreatable"; exit 3; fi
trap 'release_lock; rm -rf "$CENSUSDIR" 2>/dev/null' EXIT
CENSUS="$CENSUSDIR/live-paths.tsv"

MODE_TEXT=dry-run; [ "$DRY_RUN" = 1 ] || MODE_TEXT=apply
log_line "reap-abandoned-worktrees: pass start mode=$MODE_TEXT roots=$(printf '%s' "$ROOTS" | tr ':' ',') aged=${AGED_MINUTES}m pid=$$"
# ⛔ THE DOCUMENTED SEAM MUST REACH THE LIBRARY. `REAP_AW_PROC_ROOT` drives the fail-closed arm in the
# docs and in this suite, but the census reads `LP_PROC_ROOT`; unmapped, the documented way to simulate
# an unreadable table silently read the REAL one and reported green (`census=ok`).
# An EXPLICIT seam that does not name a readable process table forces the fail-closed arm: the seam
# says WHICH table to read, so falling through to `lsof` would silently read a different one and
# report green — the exact "the documented way to test the refusal cannot reach it" defect.
# "Readable" means it LOOKS like a process table (`self/cwd`, or a numbered pid with a `cwd`): an
# EMPTY directory — the natural spelling of a test seam (`mktemp -d`) — passed an existence check and
# fell through to `lsof`, reading a different table and reporting green.
if [ -n "${REAP_AW_PROC_ROOT:-}" ] && [ ! -e "${REAP_AW_PROC_ROOT}/self/cwd" ] && ! ls "${REAP_AW_PROC_ROOT}"/[0-9]*/cwd >/dev/null 2>&1; then
    log_line "note: REAP_AW_PROC_ROOT=$REAP_AW_PROC_ROOT is not a process table — forcing the fail-closed arm rather than reading a different one"
    LP_CENSUS_UNAVAILABLE=1
fi
export LP_PROC_ROOT="${LP_PROC_ROOT:-${REAP_AW_PROC_ROOT:-/proc}}"
if ! lp_census "$CENSUSDIR"; then
    # ⛔ THE FAIL-CLOSED ARM, SAID OUT LOUD. Nothing is reaped, and the reason names the probe. The
    # caller turns this into a red class: a reaper that cannot prove idleness must never read green.
    log_line "SKIP reason=census-unreadable mechanism=${LP_CENSUS_MECH:-none} — the process list could not be read, so NO directory can be proven free; nothing was reaped (fail closed)"
    log_line "SUMMARY class=abandoned-worktree mode=$MODE_TEXT candidates=0 reaped=0 kept=0 failed=0 census=unreadable"
    log "SKIP census-unreadable mechanism=${LP_CENSUS_MECH:-none}"
    exit 3
fi
log_line "reap-abandoned-worktrees: $(lp_description); pin=$([ -n "$PIN_SHAS" ] && printf '%s' "$(printf '%s' "$PIN_SHAS" | head -1)" || printf none)"

SWEEP_RC=0
while IFS= read -r r; do
    [ -n "$r" ] || continue
    # A root this sweep cannot even resolve is a FAILURE of the sweep, not a quiet skip: nothing was
    # classified there, and a green summary would claim the root was covered. Worst rc wins.
    sweep_root "$r" || SWEEP_RC=3
done <<<"$(printf '%s\n' "$ROOTS" | tr ':' '\n')"

log_line "SUMMARY class=abandoned-worktree mode=$MODE_TEXT candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED census=ok rows=$LP_CENSUS_ROWS pids=$LP_CENSUS_PIDS aged=${AGED_MINUTES}m dirty=$DIRTY_MODE budget=${BUDGET}s gitless_max=${GITLESS_MAX:-none}"
log "SUMMARY mode=$MODE_TEXT candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED"

[ "$FAILED" -gt 0 ] && exit 4
[ "$SWEEP_RC" = 0 ] || exit "$SWEEP_RC"
exit 0
