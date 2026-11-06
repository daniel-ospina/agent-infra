#!/usr/bin/env bash
# harness-apply-pass.sh — ONE pass that puts this box's harness on origin/main, on a clock (#2416).
#
#   ./harness-apply-pass.sh                 # apply (or advance the pin), recording one pass record
#   ./harness-apply-pass.sh --dry-run       # read + decide + print, change NOTHING
#   ./harness-apply-pass.sh --print-status  # answer "did the last pass succeed" from the record
#   ./harness-apply-pass.sh --help
#
# ⛔ IT OWNS NO ACTIVATION. The capability already exists and is used AS IS:
#     · a CELL advances its harness with `scripts/cloud-cell-supervisor.sh apply` (agent-infra#1745),
#       which fetches agent-infra main and pins a detached per-commit worktree; that is the whole of
#       "apply the proper harness" and this file does not re-implement one line of it.
#     · a MAC syncs its checkout with `./sync.sh` (auto-sync, #1661/#265) — fetch + `pull --ff-only`
#       + pi config refresh + launchd. Also not re-implemented.
#   What was missing is the CLOCK: nothing scheduled either verb, so a box ran whatever code it had
#   when it was last started and `main` moved away underneath it. A harness fix that merged but is
#   not live on a cell has fixed nothing. `scripts/install-harness-apply-timer.sh` installs this pass
#   on the box's scheduler; this file is what the scheduler runs.
#
# ── WHY A WRAPPER AND NOT THE VERB STRAIGHT INTO THE UNIT ────────────────────────────────────────
# Because the verb alone would run on a box that must NOT be moved, and the measured fleet has such
# boxes. The predicates below are the difference between "advance the harness" and "destroy the only
# copy of a lane's work", and they have to run BEFORE the verb, every time:
#
#   AHEAD      The checkout's HEAD carries commits that are NOT on the ref's line. Advancing would
#              drop them. MEASURED: c4 lost three unlanded commits on 2026-10-22, recovered only by
#              `git cherry`. REFUSED, with the ahead count, and nothing is touched.
#   DIVERGED   Neither ancestor nor descendant. Same class, same refusal — the two are NAMED
#              separately because the remedy differs (cherry-pick vs rebase).
#   DIRTY      The tree this pass is about to MOVE (the checkout, on the sync path) has uncommitted
#              changes — the measured Mac defect: ONE modified tracked file
#              (`scripts/orchestrator-harness/install.sh`) made `sync.sh` abort, and NOTHING
#              surfaced it, so the orchestrator aged 91 commits behind main with every signal
#              reading "auto". The files are PRESERVED BY NAME first (a patch plus every untracked
#              file, under `<state>/harness-apply-preserved/<UTC>/`), each path is printed, and only
#              then is the tree restored and fast-forwarded. A box that cannot preserve them is
#              REFUSED (exit 20), never quietly cleaned.
#   LANES      A running lane is NEVER signalled. This pass contains no kill, no stop and no restart of
#              any kind — not even a `kill -0` liveness probe, because it needs none: the advance is
#              ALWAYS `apply --force --pin-only`, so no branch here depends on whether a controller is
#              live. The cell advance is PIN-PER-COMMIT, so a lane keeps the tree it started with and
#              the restart is deferred to the next launch — the recorded design in
#              harness-refresh.sh's header, honoured rather than re-decided. BOTH flags: `--pin-only`
#              keeps the scheduler out of $O (seeding is `start`'s job), and `--force` is what `apply`
#              requires before it will touch a cell whose controller is live — without it the advance
#              is REFUSED on every running cell (measured in review). Neither relaxes anything else.
#              `scripts/harness-apply-timer.test.sh` pins both, statically and at runtime.
#
# ── THE PIN MUST NOT LIE ────────────────────────────────────────────────────────────────────────
# A pin is TWO records: the SHA file (`HARNESS-PIN`) and the PATH file (`.harness-path` → the tree the
# controller execs). MEASURED 2026-10-23: c1's SHA said 54bbb0c6 while the tree it names was at
# ce987bb2 — a pin that disagrees with the checkout is a false record of what is deployed, and every
# reader (cloud-cell-supervisor.sh status, harness-up, harness-refresh) then reports a commit nobody
# runs. After the move this pass re-reads BOTH and, when they disagree, REPAIRS the SHA record to the
# tree's actual HEAD, saying old → new. `--pin-only` deliberately does not do this for a pin that is
# already at the ref, which is exactly the state c1 was in.
#
# ── THE READINGS ARE PRINTED, EVERY PASS ────────────────────────────────────────────────────────
# `harness: head=… ref=… behind=N ahead=0 dirty=0 pin=… pin_tree=… mode=…`, then the action. A verdict
# without the numbers behind it is not auditable, and "behind" is the number that was invisible for
# 91 commits.
#
# ── EXIT VOCABULARY — ONE VOCABULARY, THE ONE THIS REPO ALREADY USES ────────────────────────────
# `scripts/orchestrator-harness/harness-refresh.sh` already speaks exactly this, because it answers
# the same question in-loop. A second set of codes for the same facts would be the two-vocabularies
# defect this repo keeps deleting, so this file adopts it verbatim:
#    0  current       the pin already names the ref tip; NOTHING was changed (the no-op cadence)
#    1  REFUSED deployed-drift  the pass above SUCCEEDED, but a live controller is EXECUTING a harness
#                     tree this box cannot match to this repo (gone, or present with no readable *.sh),
#                     so the code the box runs is not this repo's — a stale copy is not fixed. Recorded
#                     as `action=deployed-drift`; scoped to the `executes:` token alone, because
#                     `behind:`/`surface`/`uncommitted-edit:` legitimately describe a working box
#   10  advanced      the materialiser ran and the pin moved to the ref tip (or the pin record was
#                     repaired to the tree's head, or preserved dirt was restored as part of it)
#   11  mended        the pin was missing/empty/not-a-commit; what this box actually runs was recorded
#   20  REFUSED dirty the tree to move carries uncommitted work AND it could not be preserved
#   21  REFUSED ahead local commits are not on the ref's line — nothing was touched
#   22  REFUSED diverged the running commit is neither ancestor nor descendant — nothing was touched
#   23  REFUSED unknown the ref/repo/running commit cannot be resolved (cannot-verify is not a pass),
#                     the materialiser failed, or the pin record could not be written
#   24  farm-drift    the FARM ($CELL_HOME/.pi/agent/scripts) — the directory this box EXECUTES —
#                     carries bytes the ref does not ship, is missing files it owes, or cannot be
#                     graded at all (tortoise#10114; see PREDICATE 4). 24 is free in BOTH files, so
#                     adding it here keeps the "ONE VOCABULARY" claim above true — `harness-refresh.sh`
#                     already spends 25 (`behind`) and 26 (`REFUSED blocked`), and re-using either
#                     for a different fact is the two-vocabularies defect this header rejects.
#   25  behind        on the ref's line but older, and this box has no materialiser to advance it
#   2   usage
# The systemd unit treats 0/10/11 as success and everything else as RED: a refusal means a HUMAN must
# resolve something (an ahead box, a tree that cannot be preserved), and reddening the unit is the
# only surface that is not a log nobody reads.
#
# ⛔ WHAT IT DELIBERATELY DOES NOT DO
#   · No branch switch and no whole-tree discard anywhere: both are refused inside a cell's main
#     checkout by the same guard the laptop runs, and both can lose work. On the sync path the tracked
#     paths are brought back to HEAD one named path at a time — content, executable bit and symlink mode
#     from HEAD, then each path's INDEX entry set to HEAD's own (mode, blob) with
#     `git update-index --cacheinfo` (a blanket `git add -u` cannot carry a symlink or an exec bit) —
#     and ONLY after every dirty path has been preserved and named.
#   · No probing of `main` more than once per pass, and NO COMMIT COUNTS AS A RELATION: hash equality
#     or `merge-base --is-ancestor`, exactly as the supervisor's provenance block requires (a count
#     reads a tree that is not on main's line at all as "1 behind", and the count MOVES as main
#     advances). The COUNT is printed as a measurement of "how stale", never used to decide.
#   · No spawning, signalling or restarting of the controller or a lane. The only `--now` in this
#     feature is on the TIMER, and it lives in the installer, not here.
#
# Env seams (a cell sets none of these; the suite sets all of them):
#   HARNESS_REPO          the agent-infra checkout that carries the ref (default: this file's repo)
#   HARNESS_REF           the ref to converge on (default origin/main)
#   HARNESS_FETCH         1|0 — fetch origin before comparing (default 1; 0 for a hermetic test)
#   HARNESS_PIN           the SHA record file (default ${CELL_HOME:-$HOME}/.pi/agent/state/HARNESS-PIN)
#   HARNESS_PIN_FILE      the PATH record (default $CELL_HOME/.harness-path)
#   HARNESS_PIN_DIR       the pin root (default $CELL_HOME/harness)
#   CELL_HOME             the cell's home (default $HOME)
#   O                     the orchestrator state dir (default $CELL_HOME/orchestrator)
#   HARNESS_MATERIALISER  the script that materialises a pin (default <repo>/scripts/cloud-cell-supervisor.sh)
#   HARNESS_APPLY_MODE    pin|sync — force one path (default: pin when a pin record exists, else sync
#                         when the checkout carries ./sync.sh, else pin)
#   HARNESS_APPLY_STATE_DIR  the pass record dir (default $HOME/.pi/agent/state)
#   HARNESS_APPLY_STALE_SECONDS  a record older than this is STALE (default 3600 = 6 cadences)
#   HARNESS_APPLY_SYNC_CMD   the sync verb to run on the sync path (default <repo>/sync.sh; the suite
#                            points it at a stub so the fixture never runs pi-bootstrap)
#   HARNESS_APPLY_DRIFT_CHECK  1|0 — read the deployed-drift check on this pass (default 1). `0` is
#                            the KILL SWITCH for `action=deployed-drift`: a box that reds every tick
#                            needs it found here, not by reading the function body.
#   HARNESS_APPLY_DRIFT_CMD  the checker to run instead of the discovered `check-deployed-drift.sh`
#                            (the suite drives the red arm through a stub)
#   HARNESS_APPLY_DRIFT_DIR  OVERRIDE the checker's search root (so `absent` — the state that
#                            leaves a pass green — is reachable in a test, not just in production)
#   HARNESS_APPLY_FARM_CHECK 1|0 — compare the farm against the ref (default 1). A CHECK, never a copy
#   HARNESS_APPLY_FARM_DEST  the farm directory (default $CELL_HOME/.pi/agent/scripts)
#   HARNESS_APPLY_FARM_CHECKER  the instrument to run (default <repo>/scripts/check-farm-drift.sh,
#                            then <this file's dir>/check-farm-drift.sh — and NEVER a copy that lives
#                            inside the farm being graded, see PREDICATE 4)
#
# Run: bash scripts/harness-apply-pass.sh [--dry-run|--print-status|--help]
#
# ⛔ ONE DECLARED LIMIT, AND IT IS THE GUARD WORKING AS DESIGNED. The dirty-preserving restore below
# brings tracked paths back to HEAD from git content, which is what `main-worktree-guard` (#709)
# classifies as a REVERT — so an AGENT executing this file from a checkout that carries uncommitted
# changes is refused before bash runs a line (measured: `--print-status` and even `bash -n`). That is
# the guard doing its job on a shared checkout, not a defect in the pass: under the scheduler
# (systemd/launchd) there is no such guard, and an operator with a dirty checkout can run it with the
# documented hatch. The INSTALLER calls the pass through its own resolved path, so
# `install-harness-apply-timer.sh --status` — the verb this feature documents — is unaffected. The
# same interaction is recorded for `scripts/pi-cache-reap.test.sh` in docs/ops/disk-reaper.md.
set -uo pipefail

# ⛔ `${BASH_SOURCE[0]:-}` IS LOAD-BEARING, not tidiness. The macOS agent runs this file through
# `pi-reap-worktrees-launchd.py`, which pipes it to `bash -s`: there is NO BASH_SOURCE[0] there, and with
# `set -u` the unguarded form printed "BASH_SOURCE[0]: unbound variable" on EVERY tick, left $HERE empty
# (silently degrading the repo-resolution fallback to `.`), and broke `--help` through the launcher. The
# sibling artifact this launcher already runs carries the same note (scripts/disk-reaper.sh).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

log_line()  { printf '%s\n' "$*"; }
err()  { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

help_text() {
    local line n=0 seen=0
    # ⛔ NO EXTERNAL PRODUCER AT ALL. `sed -n "2,Np" "$0" | sed …` reads the file through `$0` and
    # `awk … "$0"` does the same: a static discard guard cannot resolve that producer, fails closed on
    # the payload, and refuses the whole invocation — which makes the script unrunnable by the very
    # lanes it must never disturb (measured, twice). A builtin read loop answers the same question with
    # no producer and no pipe, and it also carries the NO-CONSTANT-FALLBACK rule the sibling installer
    # records: the header is found by its own sentinel, so adding a line cannot truncate `--help`.
    [ -r "$0" ] || { err "cannot read my own header (a piped start has no file) — invoke this FILE: 'bash $(basename "${BASH_SOURCE[0]:-$0}") --help'"; return 2; }
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" = 1 ] && continue
        case "$line" in
            'set -uo pipefail'*) seen=1; break ;;
            '#'*) printf '%s\n' "${line#\# }" ;;
            '') printf '\n' ;;
            *) break ;;
        esac
    done <"$0"
    [ "$seen" = 1 ] || { err "could not find the header sentinel ('set -uo pipefail') in $0"; return 2; }
    return 0
}
usage() { help_text; exit 2; }

MODE=run
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --print-status) MODE=status ;;
        --help|-h)      help_text; exit $? ;;
        *)              err "unknown argument: $1 (try --help)"; usage ;;
    esac
    shift
done

CELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"
O="${O:-$CELL_HOME/orchestrator}"
# ⛔ BOTH SPELLINGS, AND THE UNIT'S IS THE ONE THAT MATTERS IN PRODUCTION. The rendered systemd unit
# and launchd plist export `HARNESS_APPLY_REPO` / `HARNESS_APPLY_REF` (they are the INSTALLER's seams);
# this file used to read only `HARNESS_REPO` / `HARNESS_REF`, so under the scheduler — where there is no
# AGENT_INFRA_PATH and the farmed copy has no checkout beside it — the pass could not resolve a repo at
# all: every tick exited 23, the pin never moved, and the box simply reddened while `list-timers` called
# it scheduled. Measured in review, with `env -i` and the unit's exact environment. The direct-run names
# stay first so an operator's `HARNESS_REPO=… bash harness-apply-pass.sh` keeps working.
REF="${HARNESS_REF:-${HARNESS_APPLY_REF:-origin/main}}"
FETCH="${HARNESS_FETCH:-1}"
PIN_SHA_FILE="${HARNESS_PIN:-$CELL_HOME/.pi/agent/state/HARNESS-PIN}"
PIN_PATH_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
PIN_ROOT="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
STATE_DIR="${HARNESS_APPLY_STATE_DIR:-${HOME}/.pi/agent/state}"
STALE_SECONDS="${HARNESS_APPLY_STALE_SECONDS:-3600}"
RECORD="$STATE_DIR/harness-apply.status"
LOG="$STATE_DIR/harness-apply.log"

# ── the checkout that carries the ref ──────────────────────────────────────────────────────────
# ⛔ THE MAIN WORKTREE, never `--show-toplevel` of this file: on a cell this script may itself be
# running from a PINNED worktree (a linked worktree of the checkout), and deriving the repo from it
# would make the pin its own repo — `apply` would then operate on the tree it is running from. Same
# expression cloud-cell-supervisor.sh and harness-refresh.sh use.
main_worktree() {
    git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}
REPO="${HARNESS_REPO:-${HARNESS_APPLY_REPO:-}}"
if [ -z "$REPO" ]; then
    for cand in "${AGENT_INFRA_PATH:-}" "$(dirname "$HERE")" "$HERE"; do
        [ -n "$cand" ] && [ -d "$cand" ] || continue
        # `rev-parse --git-dir` is the test that this IS a checkout; the worktree listing only prefers
        # the main one. A listing that cannot be read must not turn a confirmed checkout into "no
        # checkout" (the same rule the installer and cloud-cell-bringup apply).
        git -C "$cand" rev-parse --git-dir >/dev/null 2>&1 || continue
        _main="$(main_worktree "$cand")"
        REPO="${_main:-$cand}"
        break
    done
fi

# ⛔ A NUMERIC SEAM IS VALIDATED BEFORE IT IS USED. `[ "$age" -gt "abc" ]` prints "integer expression
# expected" and takes the ELSE arm, so an unvalidated bound would make every record read fresh.
case "$STALE_SECONDS" in
    ''|*[!0-9]*) err "HARNESS_APPLY_STALE_SECONDS must be a whole number of seconds (got '$STALE_SECONDS')"; exit 23 ;;
esac
[ "$STALE_SECONDS" -gt 0 ] || { err "HARNESS_APPLY_STALE_SECONDS must be positive (got '$STALE_SECONDS')"; exit 23; }
# ⛔ AND SO IS THE FARM GATE, for the same reason AND one more: this case used to sit at the END of the
# pass, AFTER the sync/materialiser legs had already moved the box, so a typo in this seam paid for a
# full move and then exited 2 writing NO record — `--print-status` and fleet-health then read the
# PREVIOUS tick as if it were this one. Validated here, a typo costs nothing (#10114 review round 2).
# A seam that silently accepted `true`/`yes`/`flase` would let a typo DISARM a P0 guard and read green.
case "${HARNESS_APPLY_FARM_CHECK:-1}" in
    1) FARM_CHECK_ON=1 ;;
    0) FARM_CHECK_ON=0 ;;
    *) err "HARNESS_APPLY_FARM_CHECK must be 1|0 (got '${HARNESS_APPLY_FARM_CHECK:-}')"; exit 2 ;;
esac
# ⛔ THE FARM PATH IS RESOLVED HERE, WITH THE OTHER SEAMS, AND IT IS CHECKED FOR ABSOLUTENESS *AFTER*
# RESOLUTION — not just as a seam. Two defects came from doing it at the finish line instead: a
# relative `HARNESS_APPLY_FARM_DEST` was refused only at the END of the pass (so the sync/materialiser
# move had already been paid for and NO record was written, leaving `--print-status` showing the
# PREVIOUS tick), and a relative `CELL_HOME` was never checked at all — it produced
# `$CELL_HOME/.pi/agent/scripts`, found nothing there, took the SKIPPED arm and reported the pass GREEN
# over a stale farm (review round 5, reproduced). ⛔ A relative value is never expanded by
# `Environment=` or a plist, and the unit's `cwd` is `/`.
if [ "$FARM_CHECK_ON" = "1" ]; then
    case "${HARNESS_APPLY_FARM_DEST:-}" in
        '') FARM_DEST="$CELL_HOME/.pi/agent/scripts" ;;
        /*) FARM_DEST="$HARNESS_APPLY_FARM_DEST" ;;
        *)  err "HARNESS_APPLY_FARM_DEST must be an ABSOLUTE path (got '$HARNESS_APPLY_FARM_DEST')"; exit 2 ;;
    esac
    case "$FARM_DEST" in
        /*) ;;
        *)  err "the resolved farm path '$FARM_DEST' is not ABSOLUTE (CELL_HOME='$CELL_HOME') — a relative CELL_HOME cannot name the directory this box executes"; exit 2 ;;
    esac
fi

# ── the pass record ────────────────────────────────────────────────────────────────────────────
# One line of key=value, written ATOMICALLY (temp + rename): a truncated record is indistinguishable
# from "no pass has run", and that is the false-PASS shape this feature exists to remove.
REC_HEAD=""; REC_REF=""; REC_BEHIND="unknown"; REC_AHEAD="unknown"; REC_DIRTY="unknown"
REC_PIN="none"; REC_PIN_TREE="none"; REC_ACTION="none"; REC_DETAIL=""; REC_REMEDY=""; PRESERVED_DIR=""; REC_DEPLOYED="unknown"
# ⛔ `REC_REMEDY` IS A FIELD FOR THE SAME REASON `preserved=` IS (review finding, #10114). Measured
# on the deployed-drift refusal: its `detail=` is 706 characters and the word `Remedy:` begins at
# offset 272 — so `cut -c1-240` DISCARDS THE ENTIRE REMEDY from the durable record. stderr still
# showed it, which is exactly why it survived review: an operator reading a LIVE terminal sees the
# remedy, and the operator reading the record (or fleet-health, or `--print-status`, or a lane on
# the next day) sees a refusal that names no action. A refusal whose remedy is lost is a gate that
# names a defect and leaves nobody to clear it — the half-fix this whole change exists to end.
write_record() { # <ok> <rc>
    local tmp ok="$1" rc="$2"
    mkdir -p "$STATE_DIR" 2>/dev/null || { err "cannot create the state dir $STATE_DIR"; return 1; }
    tmp="$RECORD.tmp-$$"
    # ⛔ ONE `key=value` PER LINE, which is the house shape for a pass record: `disk-reaper.status`
    # writes it that way and `tools/fleet/fleet-health.py` reads it that way (a single line of
    # space-separated pairs parses to ONE key there — measured, and it silently reported every pass as
    # "no readable epoch"). A record nobody can read is the same false PASS as no record.
    # `detail` is last and newline-sanitised: it is prose, and a newline in it would forge a field.
    # `preserved=` is a FIELD, not prose inside `detail=`: the preservation directory is where an
    # operator goes to recover work, so it must not be at the mercy of a prose truncation.
    {
        printf 'mode=%s\n' "$PASS_MODE"
        printf 'ok=%s\n' "$ok"
        printf 'rc=%s\n' "$rc"
        printf 'epoch=%s\n' "$(date +%s)"
        printf 'at=%s\n' "$(date -u +%FT%TZ)"
        printf 'head=%s\n' "${REC_HEAD:-unknown}"
        printf 'deployed=%s\n' "$REC_DEPLOYED"
        printf 'ref=%s\n' "${REC_REF:-unknown}"
        printf 'behind=%s\n' "$REC_BEHIND"
        printf 'ahead=%s\n' "$REC_AHEAD"
        printf 'dirty=%s\n' "$REC_DIRTY"
        printf 'pin=%s\n' "$REC_PIN"
        printf 'pin_tree=%s\n' "$REC_PIN_TREE"
        # ⛔ A FIELD, NOT PROSE IN `detail=` (review P1/P2, #10114). The whole point of this reading is
        # that a downstream instrument (fleet-health, --print-status) can see the deployed-drift state;
        # `detail=` is truncated at 240 chars, and this file already argues that an operator-needed
        # fact must not be at the mercy of a prose truncation (`preserved=` carries the same note).
        # ⛔ `${DRIFT_STATE:-not-run}` IS LOAD-BEARING, NOT DEFENSIVE STYLE (review VGATE, fatal).
        # `write_record` is called from the PRE-FLOW refusals long before `read_deployed_drift` exists, so a
        # bare `$DRIFT_STATE` under `set -u` ABORTED the record block — whose stderr is discarded — and every
        # no-checkout / unresolvable-ref pass exited 1 with NO record and no diagnostic instead of the
        # documented 23. `not-run` is also the truthful value there: those paths never reached the reading.
        printf 'drift=%s\n' "${DRIFT_STATE:-not-run}${DRIFT_TOKEN:+:$DRIFT_TOKEN}"
        printf 'preserved=%s\n' "${PRESERVED_DIR:-none}"
        # ⛔ NOT TRUNCATED, and last, for the same reason as `preserved=` above: a remedy is the one
        # line a reader MUST be able to act on, so it is never at the mercy of a prose bound. Bounded
        # by construction (each is a fixed sentence the call sites author), not by `cut`.
        printf 'remedy=%s\n' "$(printf '%s' "${REC_REMEDY:-none}" | tr '\n' ' ')"
        printf 'action=%s\n' "$REC_ACTION"
        printf 'lanes=none-signalled\n'
        printf 'fetch=%s\n' "${FETCH_STATE:-notfetched}"
        printf 'detail=%s\n' "$(printf '%s' "$REC_DETAIL" | tr '\n' ' ' | cut -c1-240)"
    } >"$tmp" 2>/dev/null \
        || { rm -f "$tmp"; err "cannot stage the pass record in $STATE_DIR"; return 1; }
    mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; err "cannot write the pass record at $RECORD"; return 1; }
    { printf '%s ' "$(date -u +%FT%TZ)"; tr '\n' ' ' <"$RECORD"; printf '\n'; } >>"$LOG" 2>/dev/null || true
    return 0
}

short() { [ -n "${1:-}" ] && printf '%s' "$1" | cut -c1-12; }

# ── --print-status: the record answers "did it succeed", and STALENESS is an alarm ─────────────
# ⛔ AN ENABLED TIMER THAT STOPPED FIRING MUST NOT READ AS A HEALTHY NO-OP. A pass whose pin already
# equals the ref exits 0 and writes rc=0 every ten minutes; if the timer dies those records simply
# stop, and only the AGE can say so. Same rule (and the same reason) as disk-reaper.sh's
# `--print-status`.
print_status() {
    [ -f "$RECORD" ] || { log_line "status=never pin=none — no pass has ever completed on this box ($RECORD)"; return 3; }
    local body epoch rc age
    body="$(cat "$RECORD" 2>/dev/null)"
    epoch="$(printf '%s\n' "$body" | sed -n 's/^epoch=\([0-9]*\)$/\1/p' | head -1)"
    rc="$(printf '%s\n' "$body" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
    behind="$(printf '%s\n' "$body" | sed -n 's/^behind=//p' | head -1)"
    fetchs="$(printf '%s\n' "$body" | sed -n 's/^fetch=//p' | head -1)"
    case "${epoch:-}" in
        ''|*[!0-9]*)
            log_line "status=unreadable rc=${rc:-?} — the record carries no usable epoch, so its age cannot be judged (cannot-verify is not fresh)"
            return 3 ;;
    esac
    age=$(( $(date +%s) - epoch ))
    # ⛔ A FUTURE-DATED RECORD IS STALE, NOT `age=0`. Clamping it made the clamp itself the bug: the
    # comment said "stale-by-definition" while the code printed `status=ok age=0s`, so a record dated
    # an hour ahead read fresh for ever — and `fleet-health.py` alarmed on the SAME file, two readers
    # disagreeing about one record with the READINESS GATE being the lenient one (measured in review).
    if [ "$age" -lt 0 ] || [ "$age" -gt "$STALE_SECONDS" ]; then
        if [ "$age" -lt 0 ]; then
            log_line "status=stale rc=${rc:-?} age=${age}s — the record is dated in the FUTURE, so its age proves nothing"
        else
            log_line "status=stale rc=${rc:-?} age=${age}s — the timer is not firing (bound ${STALE_SECONDS}s)"
        fi
        printf '%s\n' "$body" | sed 's/^/  /'
        return 3
    fi
    # ⛔ A GREEN CODE IS NOT A HEALTHY BOX. `behind>0` must not be certified here: fleet-health alarms
    # on that number, so a gate that ignored it gave TWO ANSWERS for one record — with the readiness gate
    # the lenient one (measured in review: `status=ok rc=10` beside `alarm=True behind=3`). Likewise a
    # record written from a FAILED fetch compared against a stale ref: cannot-verify is not fresh.
    case "${rc:-}" in
        0|10|11)
            case "${behind:-unknown}" in
                0) ;;
                *) log_line "status=behind rc=$rc behind=${behind:-unknown} age=${age}s — the pass exited cleanly but the box is NOT on $REF"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
            esac
            case "${fetchs:-}" in
                ok|'') ;;
                *) log_line "status=cannot-verify rc=$rc fetch=$fetchs age=${age}s — the comparison was not fresh"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
            esac
            log_line "status=ok rc=$rc age=${age}s"; printf '%s\n' "$body" | sed 's/^/  /'; return 0 ;;
        *) log_line "status=failed rc=${rc:-?} age=${age}s — a human must look"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
    esac
}

if [ "$MODE" = "status" ]; then print_status; exit $?; fi

# ── readings ───────────────────────────────────────────────────────────────────────────────────
PIN_MODE=0
if [ -f "$PIN_PATH_FILE" ] || [ -f "$PIN_SHA_FILE" ]; then PIN_MODE=1; fi
PASS_MODE="${HARNESS_APPLY_MODE:-}"
if [ -z "$PASS_MODE" ]; then
    if [ "$PIN_MODE" = 1 ]; then PASS_MODE=pin
    elif [ -x "$REPO/sync.sh" ] || [ -n "${HARNESS_APPLY_SYNC_CMD:-}" ]; then PASS_MODE=sync
    else PASS_MODE=pin
    fi
fi
case "$PASS_MODE" in pin|sync) ;; *) err "HARNESS_APPLY_MODE must be pin|sync (got '$PASS_MODE')"; exit 2 ;; esac

# ⛔ `--verify --quiet` IS LOAD-BEARING: a bare `git rev-parse <junk>` ECHOES its argument while
# exiting non-zero, so a plain capture reads an unresolvable ref as a resolved one.
resolve() { git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null; }

# ⛔ EVERY PRE-FLOW REFUSAL NAMES ITS ACTION. These four wrote `action=none` beside `ok=0 rc=23`, and
# `none` is the vocabulary's NO-OP SUCCESS — one field carrying two meanings again, in the record the
# fleet instrument prints.
[ -n "$REPO" ] && [ -d "$REPO" ] || { REC_ACTION=no-checkout; REC_DETAIL="no checkout resolved (set HARNESS_REPO)"; write_record 0 23; err "$REC_DETAIL"; exit 23; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { REC_ACTION=no-checkout; REC_DETAIL="$REPO is not a git checkout"; write_record 0 23; err "$REC_DETAIL"; exit 23; }

FETCH_STATE="notfetched"
if [ "$FETCH" = 1 ]; then
    # ⛔ FETCH THE BRANCH BEING COMPARED, not a hardcoded `main`. `$REF` is a seam rendered into both
    # artifacts; fetching `main` while comparing `origin/<other>` refreshed a ref this pass never used,
    # reported `fetch=ok`, and both readers greened a comparison that was never updated — the exact
    # stale-comparison shape predicate 0 exists to delete.
    case "$REF" in
        origin/*) _fetch_ref="${REF#origin/}" ;;
        *)        _fetch_ref="" ;;
    esac
    if [ -n "$_fetch_ref" ]; then
        git -C "$REPO" fetch --quiet origin "$_fetch_ref" >/dev/null 2>&1 && FETCH_STATE=ok || FETCH_STATE=failed
    else
        git -C "$REPO" fetch --quiet origin >/dev/null 2>&1 && FETCH_STATE=ok || FETCH_STATE=failed
    fi
fi
REF_SHA="$(resolve "$REF")"
[ -n "$REF_SHA" ] || {
    REC_ACTION=unresolvable-ref; REC_REF="unresolved"; REC_DETAIL="cannot resolve $REF in $REPO (fetch=$FETCH_STATE) — cannot-verify is not a pass"
    write_record 0 23; err "$REC_DETAIL"; exit 23; }
HEAD_SHA="$(git -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
[ -n "$HEAD_SHA" ] || {
    REC_ACTION=unresolvable-head; REC_REF="$(short "$REF_SHA")"; REC_DETAIL="cannot resolve HEAD in $REPO — cannot-verify is not a pass"
    write_record 0 23; err "$REC_DETAIL"; exit 23; }

# The relation, by ANCESTRY — never by a count (see the header). The counts are printed, and the
# `behind` count is the one number the fleet instrument alarms on, so it is computed for the commit
# this box RUNS (`deployed`), not merely for the checkout: on a pin-per-commit cell the advance never
# moves the checkout, so a `behind` measured there would be permanently non-zero and the alarm would
# be wallpaper (measured in review: a cell would have been red for ever while its pin was current).
#   R_REL / R_BEHIND / R_AHEAD are the outputs.
relation_of() { # <sha>
    local s="$1"
    R_REL=unknown; R_BEHIND=unknown; R_AHEAD=unknown
    [ -n "$s" ] || return 0
    if [ "$s" = "$REF_SHA" ]; then R_REL=current; R_BEHIND=0; R_AHEAD=0; return 0; fi
    if git -C "$REPO" merge-base --is-ancestor "$s" "$REF_SHA" 2>/dev/null; then
        R_REL=behind
        R_BEHIND="$(git -C "$REPO" rev-list --count "$s..$REF_SHA" 2>/dev/null)"; R_BEHIND="${R_BEHIND:-unknown}"
        R_AHEAD=0
        return 0
    fi
    if git -C "$REPO" merge-base --is-ancestor "$REF_SHA" "$s" 2>/dev/null; then
        R_REL=ahead
        R_AHEAD="$(git -C "$REPO" rev-list --count "$REF_SHA..$s" 2>/dev/null)"; R_AHEAD="${R_AHEAD:-unknown}"
        R_BEHIND=0
        return 0
    fi
    R_REL=diverged
}
relation_of "$HEAD_SHA"
RELATION="$R_REL"; BEHIND="$R_BEHIND"; AHEAD="$R_AHEAD"

# ── the dirty path list, NUL-SAFE ──────────────────────────────────────────────────────────────
# ⛔ `git status --porcelain | cut -c4-` IS NOT A PATH LIST, and using it as one lost work silently:
#   · a RENAME prints `R  old -> new` — the "path" is that whole sentence, so neither side is in HEAD
#     (it was reported as "skipped"), the rename stayed staged, the destination was never copied as
#     untracked, and the pass still printed an `advanced` verdict;
#   · a path with a space (or any non-ASCII name, under `core.quotePath`) is C-QUOTED, so
#     `cat-file HEAD:"has space.txt"` fails and the file is simply not restored — while the MANIFEST
#     records the quotes, which is useless for recovery.
# `-z` is the machine format: NUL-separated, never quoted, and a rename/Copy record is followed by its
# ORIGINAL path as one more NUL field, which this consumes so the destination is what is returned.
list_dirty_paths() { # stdout: one path per NUL; a rename/copy yields BOTH sides
    local entry st p old
    git -C "$REPO" status --porcelain -z 2>/dev/null | {
        while IFS= read -r -d '' entry; do
            st="${entry:0:2}"
            p="${entry:3}"
            case "$st" in
                R*|C*)
                    # ⛔ BOTH SIDES, AND THAT IS NOT REDUNDANT. The DESTINATION is what the tree now
                    # holds (so it is what must be preserved and copied), but the ORIGINAL is the path
                    # that exists in HEAD and is now MISSING from the worktree — restore only the
                    # destination and the tree never converges: HEAD's file stays deleted, the
                    # destination stays an unindexed addition, and the next upstream commit to the old
                    # path makes the fast-forward refuse for ever.
                    IFS= read -r -d '' old || true
                    [ -n "$p" ] && printf '%s\0' "$p"
                    [ -n "${old:-}" ] && printf '%s\0' "$old"
                    continue ;;
            esac
            [ -n "$p" ] && printf '%s\0' "$p"
        done
    }
}
list_deleted_paths() { # stdout: every path whose status carries a D, one per NUL
    local entry st p
    git -C "$REPO" status --porcelain -z 2>/dev/null | {
        while IFS= read -r -d '' entry; do
            st="${entry:0:2}"
            p="${entry:3}"
            case "$st" in
                R*|C*) IFS= read -r -d '' _old || true ;;
                *D*)   [ -n "$p" ] && printf '%s\0' "$p" ;;
            esac
        done
    }
}
list_rename_dests() { # stdout: the DESTINATION of every rename/copy record, one per NUL
    local entry st p
    git -C "$REPO" status --porcelain -z 2>/dev/null | {
        while IFS= read -r -d '' entry; do
            st="${entry:0:2}"
            p="${entry:3}"
            case "$st" in
                R*|C*) IFS= read -r -d '' _old || true; printf '%s\0' "$p" ;;
            esac
        done
    }
}
list_untracked_paths() { # stdout: one path per NUL
    local p
    git -C "$REPO" ls-files --others --exclude-standard -z 2>/dev/null | {
        while IFS= read -r -d '' p; do [ -n "$p" ] && printf '%s\0' "$p"; done
    }
}

# The dirty count, read from the tree this pass will actually MOVE. On the pin path a dirty checkout
# is harmless BY CONSTRUCTION (the advance creates a NEW per-commit worktree, and `apply` re-pins
# rather than reusing a dirty tree) — so it is printed and not acted on. On the sync path it is the
# thing that must be preserved.
# ⛔ THE READ'S OWN EXIT STATUS IS PART OF THE READING. `git status … | wc -l` returns 0 entries for a
# FAILED status (a corrupt index, a full disk — the very conditions this feature runs under), so the
# record would claim `dirty=0` from a read that never happened. Same rule as the earlier pass-record
# readers: cannot-verify is never "clean".
DIRTY_N="unknown"
if git -C "$REPO" status --porcelain >/dev/null 2>&1; then
    DIRTY_N="$(list_dirty_paths | tr -cd '\0' | wc -c | tr -d ' ')"
fi
case "${DIRTY_N:-unknown}" in ''|*[!0-9]*) DIRTY_N=unknown ;; esac

REC_HEAD="$(short "$HEAD_SHA")"; REC_REF="$(short "$REF_SHA")"
REC_BEHIND="$BEHIND"; REC_AHEAD="$AHEAD"; REC_DIRTY="$DIRTY_N"
PIN_SHA=""; PIN_TREE_SHA=""
read_pin() {
    local pv pd
    pv="$(head -1 "$PIN_SHA_FILE" 2>/dev/null | tr -d '[:space:]')"
    # A pin that is not a commit is NOT a pin — `resolve` is the test, for the reason above.
    if [ -n "$pv" ] && [ -z "$(resolve "$pv")" ]; then pv=""; fi
    PIN_SHA="$pv"
    REC_PIN="$(short "${pv:-}")"; [ -n "$REC_PIN" ] || REC_PIN=none
    PIN_TREE_SHA=""
    pd="$(head -1 "$PIN_PATH_FILE" 2>/dev/null)"
    if [ -n "$pd" ] && [ -d "$pd" ]; then
        pd="$(git -C "$pd" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
        if [ -n "$pd" ]; then PIN_TREE_SHA="$pd"; REC_PIN_TREE="$(short "$pd")"; return 0; fi
    fi
    REC_PIN_TREE=none
    return 0
}
[ "$PASS_MODE" = pin ] && read_pin

# The commit this box RUNS, and the readings the fleet instrument alarms on. On the pin path that is
# the tree the path record names (what the controller execs); on the sync path it is the checkout's
# own HEAD. `head=` stays the checkout reading; `deployed=` is the one the verdict is about.
DEPLOYED_SHA=""
recompute_deployed() {
    [ "$PASS_MODE" = pin ] && read_pin
    if [ "$PASS_MODE" = pin ] && [ -n "$PIN_TREE_SHA" ]; then
        DEPLOYED_SHA="$PIN_TREE_SHA"
    elif [ "$PASS_MODE" = pin ] && [ -s "$PIN_PATH_FILE" ]; then
        # ⛔ THE PATH RECORD NAMES A TREE, AND THAT TREE IS GONE. Falling back to the checkout's HEAD
        # claimed the box runs main while `cloud-cell-supervisor.sh` DIES on the same state ("harness not
        # found at … that is the path RECORDED in .harness-path and it no longer exists"). `deployed` is
        # the field the whole alarm is keyed on, so it must say UNKNOWN here, not borrow a fact from
        # another tree.
        DEPLOYED_SHA=""
    else
        DEPLOYED_SHA="$(git -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
    fi
    REC_HEAD="$(short "$(git -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)")"
    REC_DEPLOYED="$(short "${DEPLOYED_SHA:-}")"; [ -n "$REC_DEPLOYED" ] || REC_DEPLOYED=unknown
    relation_of "$DEPLOYED_SHA"
    REC_BEHIND="$R_BEHIND"; REC_AHEAD="$R_AHEAD"
    # ⛔ ONE TREE, ONE NUMBER: the record's `dirty` uses the SAME guarded, NUL-safe read as the printed
    # one. A bare `status | wc -l` reported 0 for a FAILED status (a corrupt index / a full disk — the
    # conditions this runs under) and counted porcelain LINES rather than entries, so a rename read as
    # 1 here and 2 above for the same tree.
    REC_DIRTY="unknown"
    if git -C "$REPO" status --porcelain >/dev/null 2>&1; then
        REC_DIRTY="$(list_dirty_paths | tr -cd '\0' | wc -c | tr -d ' ')"
    fi
    case "${REC_DIRTY:-}" in ''|*[!0-9]*) REC_DIRTY=unknown ;; esac
}

# ⛔ TWO RELATIONS, BOTH NAMED. `$RELATION`/`$BEHIND` describe the CHECKOUT; the record's `behind` is
# measured from the DEPLOYED commit. Printing only the checkout's made the log say `behind=1` on a box
# whose record (correctly) said `behind=0` — two numbers for one box in one pass, and the log's was the
# one an operator is told to trust.
log_line "harness: mode=$PASS_MODE repo=$REPO ref=$REF fetch=$FETCH_STATE head=$(short "$HEAD_SHA") checkout_relation=$RELATION checkout_behind=$BEHIND ref_sha=$(short "$REF_SHA") dirty=$DIRTY_N pin=$REC_PIN pin_tree=$REC_PIN_TREE"
[ "$PASS_MODE" = pin ] && [ "$REC_PIN_TREE" != "none" ] && \
    log_line "harness: deployed=$REC_PIN_TREE (the tree the pin names — this is what the box RUNS; the checkout above is not moved by a pin advance)"

# ── DEPLOYED-DRIFT READING (agent-infra#10114) ────────────────────────────────────────────────
# ⛔ THE BOX CAN BE AT THE PIN AND STILL RUN NOTHING THIS REPO SHIPS. Every reading above answers a
# question about a RECORD (the pin, the stamp, the checkout). None of them answers the one question the
# outage asked: is the code that is EXECUTING equal to $REF? Measured on this class of box: the
# controller executed `<pin-root>/709dfb06eac2/...`, a directory that no longer existed, while the pin
# record, the unit's active state and the control plane all read green — a stale copy is not fixed, and
# it was INVISIBLE because the pass reported success.
# ⛔ ONE PREDICATE (#1178): this calls `check-deployed-drift.sh`, the instrument that already answers
# this, and prints ITS token. It is NOT re-derived here — a second checker is how two instruments come
# to disagree about one box. READ-ONLY: that script changes nothing and is safe beside a working loop.
# ⛔ THE SEAM IS THE POINT. `HARNESS_APPLY_DRIFT_CHECK=0` disables it (the suite runs this pass against
# stub repos that carry no harness dir at all); an ABSENT checker is `not-run`, named as such, never a
# silent pass — we cannot verify what we did not run.
DRIFT_STATE=not-run; DRIFT_RC=not-run; DRIFT_TOKEN=not-run
# ⛔ CALLED ONCE PER RUN, AND NEVER FROM THE READINGS SECTION (review P1). An earlier revision also
# called it here, beside the other readings — so every pass took TWO readings, and on an advancing tick
# the two DISAGREED (this one pre-move, `finish`'s post-move) while the log printed both under the same
# key. That is the "two numbers for one box in one pass" defect this file already documents twice, and
# the checker costs ~3 s, so it doubled the pass's cost too.
# EXACTLY TWO CALL SITES, and they cannot both run: `finish` (a real pass, post-move, the reading the
# record is written from) and the `--dry-run` branch (a PREVIEW, which exits before `finish` and writes
# no record). Adding a third beside the readings is the defect above — not the preview, which exists so
# the read-only verb can answer the executing-tree question at all (review round 21, P2).
read_deployed_drift() {
    [ "${HARNESS_APPLY_DRIFT_CHECK:-1}" = 0 ] && { DRIFT_STATE=disabled; DRIFT_TOKEN=disabled; return 0; }
    local chk="${HARNESS_APPLY_DRIFT_CMD:-}"
    if [ -z "$chk" ]; then
        # ⛔ THE SCHEDULED PASS IS THE **FARMED** COPY, NOT A CHECKOUT COPY — and the farm does NOT ship
        # the checker (review P1, measured on this box). `install-harness-apply-timer.sh` installs the
        # farmed copy first ("that is what a cell has after pi-bootstrap/setup.sh"), the unit runs
        # `<cell-home>/.pi/agent/scripts/harness-apply-pass.sh`, and that directory carries neither
        # `check-deployed-drift.sh` nor an `orchestrator-harness/` subdir — while `pi-bootstrap`'s
        # `fleet_srcs` farms this pass and NOT the checker. So searching only `$HERE` made the whole
        # arm DEAD on every deployed box: `absent` → not-run → never `executes:` → rc 0 over a stale
        # executing harness, which is exactly the silent green this change exists to end.
        # `$O` is where the checker IS deployed, so it is the candidate that works in production.
        # ⛔ AND THE GOVERNED CHECKOUT IS A CANDIDATE (review P2, #10114). `$AGENT_INFRA_PATH` is DEAD
        # under the scheduler — this file says so itself (:188: "under the scheduler — where there is no
        # AGENT_INFRA_PATH and the farmed copy has no checkout beside it") — and `pi-bootstrap`'s
        # `fleet_srcs` farms THIS PASS WITHOUT the checker, so on a box whose `$O` carries no checker
        # candidates 1-4 all miss while the checker sits in `$REPO`, which the unit DOES export
        # (`HARNESS_APPLY_REPO`, templates/systemd/eldato-harness-apply.service:31). That box got
        # `drift=not-run:absent` every tick and `fleet-health` alarmed about a checker it had — an
        # un-actionable alarm, the failure the `executes:`-only scoping exists to avoid. `$REPO` is also
        # the tree this pass GOVERNS, so reading its own committed checker is the closest instrument to
        # the question the pass is asking. LAST, so every deployed copy still wins.
        # ⛔ `HARNESS_APPLY_DRIFT_DIR` IS A SEARCH-ROOT OVERRIDE, not an extra candidate (review round 8,
        # P2). The discovery path is the thing this lane had to fix TWICE because it was dead in the
        # deployed shape, and no test executed it — every drift assertion supplied a checker path
        # directly, and candidate 1 (`$HERE/orchestrator-harness/…`) shadows any fixture on this box.
        # Overriding the root makes both "found through the seam" and "nothing to find" reachable, so
        # `absent → not-run` (the arm that leaves the pass GREEN) can be asserted instead of assumed.
        if [ -n "${HARNESS_APPLY_DRIFT_DIR:-}" ]; then
            [ -f "$HARNESS_APPLY_DRIFT_DIR/check-deployed-drift.sh" ] && chk="$HARNESS_APPLY_DRIFT_DIR/check-deployed-drift.sh"
        else
        for _candidate in "$HERE/orchestrator-harness/check-deployed-drift.sh" \
                          "$HERE/check-deployed-drift.sh" \
                          "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/check-deployed-drift.sh" \
                          "${O:-}/check-deployed-drift.sh" \
                          "${REPO:-}/scripts/orchestrator-harness/check-deployed-drift.sh"; do
            [ -n "$_candidate" ] && [ -f "$_candidate" ] && { chk="$_candidate"; break; }
        done
        fi
    fi
    if [ ! -f "$chk" ]; then
        DRIFT_STATE=not-run; DRIFT_TOKEN=absent
        log_line "harness: deployed_drift=not-run token=absent (no check-deployed-drift.sh beside $HERE, in \$O=$O, at AGENT_INFRA_PATH, or in \$REPO=$REPO) — NOT a clean reading, we did not look"
        return 0
    fi
    local out
    # `--surface` is what includes the EXECUTING tree (read from the process's own argv) alongside $O;
    # `--no-fetch` keeps this pass network-free (the fetch above already happened).
    # ⛔ THE THREE VALUES ARE PASSED EXPLICITLY, NOT INHERITED (review finding, #10114). This pass
    # RESOLVES the pin from `HARNESS_PIN_FILE`/`HARNESS_PIN_DIR` (with `$CELL_HOME` defaults) and
    # `$O` from its own launcher, but a RESOLVED value is not an EXPORTED one: a shell variable set
    # here (`PIN_PATH_FILE=…`, `O=…`) is invisible to a child unless something exported it. The
    # checker then falls back to ITS defaults (`O=$HOME/orchestrator`, pin records from its own
    # env) and answers a DIFFERENT question than the one this pass asked — measured shape: a pass
    # that knows the pin lives at `<cell-home>/.harness-path` while the checker looks at
    # `$HOME/.harness-path`, so `--surface` compares a box it has mis-identified and the reading is
    # reported beside readings taken against the right one. Passing them on the child's command line
    # makes the two instruments answer about ONE box; `O` is also how the checker finds the deployed
    # tree in the FARMED layout, where `$HERE` carries neither the checker nor its subdir.
    out="$(O="$O" HARNESS_PIN_FILE="$PIN_PATH_FILE" HARNESS_PIN_DIR="$PIN_ROOT" bash "$chk" --surface --repo "$REPO" --ref "$REF" --no-fetch 2>&1)"; DRIFT_RC=$?
    DRIFT_TOKEN="$(printf '%s\n' "$out" | sed -n 's/.*harness=//p' | head -1)"
    [ -n "$DRIFT_TOKEN" ] || DRIFT_TOKEN="rc=$DRIFT_RC"
    case "$DRIFT_RC" in
        0) DRIFT_STATE=clean ;;
        1) DRIFT_STATE=drift ;;
        *) DRIFT_STATE="cannot-verify-rc$DRIFT_RC" ;;
    esac
    # ⛔ CANNOT-VERIFY KEEPS ITS REASON (review P2). The checker's exit 2 means "I could not answer" —
    # an unreadable process table, an unexaminable dir, an unresolvable controller path — and its
    # `UNKNOWN:` line is the only place that reason is ever written. Recorded as a bare `token=rc=2` it
    # survived nowhere an operator reads (the record's `detail=` truncates at 240 chars), leaving a box
    # whose executing-tree question was NEVER ANSWERED looking like one that answered clean. This is
    # reported, not turned into a refusal: exit 2 is heavily reachable on a box with no harness at all,
    # and a check that reds every such box is one operators learn to ignore.
    if [ "$DRIFT_RC" -gt 1 ] 2>/dev/null; then
        log_line "harness: deployed_drift_unknown=$(printf '%s\n' "$out" | grep -m1 -E 'UNKNOWN:|BROKEN' || true)"
    fi
    log_line "harness: deployed_drift=$DRIFT_STATE token=$DRIFT_TOKEN (check-deployed-drift.sh --surface)"
    return 0
}

# supervisor_cmd — the repair verb the `deployed-drift` refusal RECORDS, as something an operator can
# paste. ⛔ A REMEDY THAT DOES NOT RUN IS NOT A REMEDY (review P2, #10114). The sentence used to begin
# with the bare name `cloud-cell-supervisor.sh`, and NOTHING in this fleet puts that name on PATH:
# `command -v cloud-cell-supervisor.sh` is empty on a deployed cell, and the farm keeps it at
# `~/.pi/agent/scripts/cloud-cell-supervisor.sh` (`pi-bootstrap`'s `fleet_srcs` farm). So the one
# actionable output of a red that repeats every tick until someone acts was `command not found` on
# exactly the population it fires on. Resolve an EXISTING file, in the order the fleet materialises it:
# an explicit `HARNESS_MATERIALISER`, the farmed shape BESIDE this pass (`$HERE` — measured: the farm
# carries both files in one directory), the deployed harness dir, then a checkout. Only when NOTHING
# exists does it fall back to the bare name, and then it says the path is unknown instead of implying
# a command that resolves.
supervisor_cmd() {
    local c
    for c in "${HARNESS_MATERIALISER:-}" "$HERE/cloud-cell-supervisor.sh" "${O:-}/cloud-cell-supervisor.sh" "${REPO:-}/scripts/cloud-cell-supervisor.sh"; do
        [ -n "$c" ] && [ -f "$c" ] && { printf 'bash %s' "$c"; return 0; }
    done
    printf 'cloud-cell-supervisor.sh (NOT FOUND on this box — set HARNESS_MATERIALISER)'
}

# finish — record the pass and ANSWER IT. The detail is printed in BOTH directions: a silent success
# (`exit 0` with no line saying what it decided) is the shape that let a no-op and a refusal look
# identical from a log, and an operator who reads `current` has to be able to see it WAS current.
finish() { # <ok> <rc> <verdict-phrase>
    # ⛔ THE READINGS ARE RE-READ FROM THE FINAL STATE, AND SO IS THE SENTENCE. Taking the readings
    # before the move told the fleet instrument the box was STILL behind on the pass that fixed it
    # (permanently so on a pin cell, where the checkout is never moved), and expanding `$REC_BEHIND`
    # inside the VERDICT PHRASE kept the stale number in `detail=` — the field `fleet-health` prints and
    # `--print-status` dumps verbatim — while the record beside it said `behind=0`. So the phrase is
    # passed WITHOUT readings and the numbers are appended here, once, after the recompute.
    recompute_deployed
    # ⛔ ONE READING, TAKEN HERE, FROM THE FINAL STATE (review P1). Unconditional so every exit path —
    # advance, no-op, refusal — reports the same post-move fact, and no path can carry a stale one.
    read_deployed_drift
    # ⛔ A STALE DEPLOYED COPY IS NOT A CLEAN PASS (agent-infra#10114). This is the plain form of the
    # "gate that answers before its inputs exist": every reading above can be green while the box
    # executes a tree that is gone, and a `rc=0` there tells every downstream reader the harness is
    # fine. The drift reading itself was taken ONCE, above. It never downgrades a refusal (a passing
    # `$1` is required) and never masks a higher code: a box that could not verify is rc 23 and stays 23.
    if [ "$1" = 1 ]; then
        # ⛔ WHICH DRIFT EARNS A RED. `executes:<dir>` is the measured #10114/#3194 class and the only
        # one that is unambiguously a FAILURE OF THE HARNESS THIS PASS GOVERNS: a live controller
        # executes a directory the box does not have, so NOTHING it runs is this repo's code — and the
        # pass just called that box fine. The other tokens (`behind:`, `payload-differs`,
        # `uncommitted-edit:`, `surface`) can legitimately describe a developer box mid-edit or a
        # deliberately-behind checkout, so they are REPORTED in the log line and in the record's
        # `drift=` field, but they do not convert an ordinary pass into a refusal. A check that reds
        # every working box is a check an operator learns to ignore, which is how the silent one
        # survived. Scoping is stated here rather than implied: only `executes:` fails the pass.
        case "$DRIFT_TOKEN" in
            executes:*)
                REC_ACTION=deployed-drift
                # The remedy lives in its own FIELD (see `REC_REMEDY`), because `detail=` truncates
                # at 240 and this sentence does not fit in it — measured: `Remedy:` begins at 272.
                # ⛔ THE COMMAND IS RESOLVED, NOT NAMED (see `supervisor_cmd`): a bare name is
                # `command not found` on the farmed cells this red fires on.
                REC_REMEDY="$(supervisor_cmd) apply --force --pin-only (--force is REQUIRED: apply refuses a live cell without it, and an executes: state always has a live controller), then restart the controller from the pinned tree (a redeploy does not clear it)"
                REC_DETAIL="REFUSED deployed-drift: a live controller EXECUTES a harness directory that cannot be matched to this repo (gone, or present with no readable *.sh) (harness=$DRIFT_TOKEN) — this pass succeeded and the code the box RUNS is still not this repo's; a stale copy is not fixed. Remedy: $REC_REMEDY. Readings: head=$REC_HEAD deployed=$REC_DEPLOYED ref=$REC_REF behind=$REC_BEHIND ahead=$REC_AHEAD dirty=$REC_DIRTY pin=$REC_PIN pin_tree=$REC_PIN_TREE drift=$DRIFT_STATE:$DRIFT_TOKEN"
                write_record 0 1 || exit 23
                err "$REC_DETAIL"
                exit 1 ;;
        esac
    fi
    REC_DETAIL="$3 — head=$REC_HEAD deployed=$REC_DEPLOYED ref=$REC_REF behind=$REC_BEHIND ahead=$REC_AHEAD dirty=$REC_DIRTY pin=$REC_PIN pin_tree=$REC_PIN_TREE drift=$DRIFT_STATE${DRIFT_TOKEN:+:$DRIFT_TOKEN}${PRESERVED_DIR:+ preserved=$PRESERVED_DIR}"
    write_record "$1" "$2" || exit 23
    if [ "$1" = 1 ]; then log_line "$REC_DETAIL"; else err "$REC_DETAIL"; fi
    exit "$2"
}

# ── PREDICATE 0: THE COMPARISON MUST BE FRESH ─────────────────────────────────────────────────
# ⛔ A FAILED FETCH IS `cannot-verify`, NOT `current`. The old code warned on stderr and carried on
# against the STALE remote-tracking ref, so a box that lost egress (or whose origin moved) saw
# `relation=current`, wrote `behind=0 action=none ok=1 rc=0`, exited 0 (green in the unit's
# SuccessExitStatus), reported `status=ok` and raised no alarm in fleet-health — every signal saying
# "auto" while the box aged. That is precisely the defect this feature exists to delete, and the file's
# own vocabulary already has the answer: 23 cannot-verify. A transient blip costs one red tick and heals
# on the next; being wrong about drift costs the whole point of the feature.
case "$FETCH_STATE" in
    ok) ;;
    *) REC_ACTION=cannot-verify-fetch
       # Its `detail=` is ~250+ chars once the readings suffix is appended, so `cut -c1-240` drops the
       # tail; `remedy=` is a FIELD so the REMEDY survives regardless (review round 3, finding 5).
       # (`action=` is written on its own line at :278-279 and never depended on this — what the prose
       # bound was eating is the sentence a reader has to act on.)
       REC_REMEDY="restore the fetch (check the remote and egress), then re-run"
       finish 0 23 "REFUSED cannot-verify: no fresh fetch was made (fetch=$FETCH_STATE) in $REPO, so 'current' would mean 'current against the ref as of the LAST successful fetch' — the comparison this pass exists to make is not fresh. Nothing was touched." ;;
esac

# ── PREDICATE 1: AHEAD / DIVERGED — refuse before anything is touched ──────────────────────────
# ⛔ THIS IS THE c4 DEFECT. Its local commits existed in no other place; an advance would have
# dropped them and NOTHING in the fleet would have said so. The count is in the message because
# "ahead" alone does not tell an operator whether it is one commit worth keeping or twenty.
if [ "$RELATION" = ahead ]; then
    REC_ACTION=refused-ahead
    REC_REMEDY="recover or land them first: git -C $REPO log $REF..HEAD, then re-run"
    finish 0 21 "REFUSED ahead: $REPO carries $AHEAD commit(s) that are not on $REF — advancing would drop them. Recover or land them first (git log $REF..HEAD), then re-run. Nothing was touched."
fi
if [ "$RELATION" = diverged ]; then
    REC_ACTION=refused-diverged
    REC_REMEDY="a rebase or cherry-pick is an operator decision, not a scheduled one: resolve divergence by hand, then re-run"
    finish 0 22 "REFUSED diverged: HEAD is neither an ancestor nor a descendant of $REF — a rebase or cherry-pick is an operator decision, not a scheduled one. Nothing was touched."
fi

# ── PREDICATE 2: DIRTY — preserve BY NAME, then move (sync path only) ──────────────────────────
# MEASURED (the Mac, 2026-10-23): ONE modified tracked file made `sync.sh` abort for 91 commits and
# nothing reported it. `sync.sh` aborting is CORRECT — it must not discard work. What was missing is a
# path that SAVES the work and then completes the advance, and a record that says so.
preserve_dirty() { # <dest-dir>; prints what it saved; exit 1 if it cannot save everything
    local dest="$1" p n=0
    mkdir -p "$dest" || { err "cannot create the preservation dir $dest"; return 1; }
    # ⛔ TWO PATCHES, NOT ONE. `git diff HEAD` is WORKTREE-vs-HEAD and never reads the INDEX as a source
    # of content, so a path whose bytes exist ONLY in the index (`git add new.txt; rm new.txt` ⇒ `AD`)
    # was in no preserved artifact at all — and the restore then dropped its index entry: measured
    # content loss recorded as a green `advanced`. `--cached` is that half of the record.
    if ! git -C "$REPO" diff --binary HEAD >"$dest/changes.patch" 2>/dev/null; then
        err "cannot write $dest/changes.patch — refusing to touch a tree whose changes are not saved"
        return 1
    fi
    if ! git -C "$REPO" diff --binary --cached HEAD >"$dest/changes.index.patch" 2>/dev/null; then
        err "cannot write $dest/changes.index.patch — refusing to touch a tree whose STAGED changes are not saved"
        return 1
    fi
    : >"$dest/MANIFEST" || return 1
    # ⛔ NUL-SAFE AND READ ONCE. `--porcelain` WITHOUT `-z` is the human rendering: quoted names and a
    # `old -> new` sentence for a rename. Reading it as a path list lost work (see the header of
    # `list_dirty_paths`), and reading it twice would describe two different trees.
    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        # `%q` so a path with a space, quote or newline is still recoverable FROM the manifest; the
        # destination of a rename is what is listed, because that is what the tree now holds.
        printf '%q\n' "$p" >>"$dest/MANIFEST" || return 1
        log_line "preserved: $p -> $dest/changes.patch (+ changes.index.patch for the staged snapshot)"
        n=$((n + 1))
    done < <(list_dirty_paths)
    # ⛔ UNTRACKED FILES ARE COPIED, not just named: a patch cannot carry them, and they are the
    # likeliest thing on a box to exist in no other place. A path that cannot be copied is a refusal.
    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        case "$p" in /*) continue ;; esac
        mkdir -p "$dest/untracked/$(dirname "$p")" 2>/dev/null || return 1
        # ⛔ `-a` (`--no-dereference` among other things) IS REQUIRED. `cp -p` FOLLOWS a symlink: a link
        # to a directory is not copyable without -r and a DANGLING link fails outright, so preservation
        # refused (exit 20) for ever on a box holding either — the outcome this feature exists to end,
        # on a state that is trivially preservable. It also recorded the TARGET's bytes instead of the
        # link, so the recovery copy was not a faithful record of the tree.
        cp -a "$REPO/$p" "$dest/untracked/$p" 2>/dev/null || { err "cannot preserve untracked $p — refusing to touch the tree"; return 1; }
        log_line "preserved: $p -> $dest/untracked/$p"
    done < <(list_untracked_paths)
    # ── bring the tracked paths back to HEAD so a fast-forward is possible ──────────────────────
    # ⛔ THE TWO OBVIOUS WAYS ARE BOTH WRONG HERE, for different reasons. A branch switch is what this
    # repo blocks inside a cell's main checkout (cloud-cell-supervisor.sh's header records why). A
    # whole-tree discard verb is refused by main-worktree-guard (#709) wherever its target is not
    # statically resolvable — which it never is here, because the checkout is a seam — and that refusal
    # would land on the scheduled PASS as well as on the suite. The guard exists to stop an agent
    # discarding a SHARED checkout's work; this runs on the box's own deployment checkout under a
    # scheduler, and every affected byte is already at `$dest` under the names printed above.
    # So the effect is produced one bounded step at a time, per path, on the list already read:
    #   1. the WORKTREE entry is replaced from HEAD — content (via a temp file + rename), the executable
    #      bit, or the symlink itself, whichever the mode says; and
    #   2. the INDEX entry for that path is set to HEAD's own (mode, blob) — or REMOVED when the path is
    #      not in HEAD (a staged addition), so no staged residue is left to block the merge.
    # Nothing is lost that was not first saved, and no untracked file is touched at all.
    #
    # ⛔ THE BLOB GOES TO A TEMP FILE IN THE SAME DIRECTORY AND IS RENAMED OVER THE PATH — never
    # redirected straight at it. `> "$REPO/$p"` FOLLOWS A SYMLINK and writes through it, so restoring a
    # dirty symlink would corrupt the CLEAN file it points at, destroy bytes that were (correctly) never
    # preserved, leave `$p` itself still wrong, and then print "tracked paths match HEAD". This repo
    # tracks 34 symlinks (`pi-bootstrap/pi-config/extensions/*`), so that is a live shape.
    # ⛔ AND THE MODE IS PART OF THE CONTENT. A blob carries bytes only, so a file restored as 0644 that
    # HEAD has as 100755 is a MODE CHANGE staged by any `git add` — the tree stays dirty, a later
    # upstream commit to that path makes the fast-forward refuse for ever, and this repo tracks 207
    # executable files (one of them is the very file the measured Mac defect was about).
    local n_restored=0 n_skipped=0 n_removed=0 tmp mode sha blob _info _type _rest d dests="" _h
    # ⛔ THE RENAME-DESTINATION SET IS BUILT NUL-SAFELY, ONCE, BEFORE THE LOOP. `$(list_rename_dests)`
    # DROPS every NUL (bash warns "ignored null byte in input") and concatenates the destinations into
    # ONE WORD, so with two or more renames nothing matched: the destinations stayed untracked (the tree
    # never converged, and the next upstream commit to one of them was refused for ever) while the pass
    # recorded `advanced`/rc=10 — GREEN — over it. Measured in review; a single-rename fixture passes,
    # which is why the suite did not see it.
    while IFS= read -r -d '' d; do dests="${dests}${d}"$'\n'; done < <(list_rename_dests)
    # ⛔ A PLAIN `mv` IS NOT A RENAME RECORD, and leaving it out was the same defect one shape over: git
    # reports it as ` D old` + `?? new`, so the destination was treated as a keep-in-worktree addition —
    # the tree stayed dirty for ever, and the moment upstream added that path every later merge was
    # refused while the pass re-preserved the whole dirty set on each tick. A file whose CONTENT is the
    # blob a deleted tracked path had is a move: its bytes are preserved, so it converges like a rename.
    local del_blobs="" _dsha
    while IFS= read -r -d '' d; do
        _dsha="$(git -C "$REPO" rev-parse --verify --quiet "HEAD:$d" 2>/dev/null)" || continue
        [ -n "$_dsha" ] && del_blobs="${del_blobs}${_dsha}"$'\n'
    done < <(list_deleted_paths)
    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        case "$p" in /*) n_skipped=$((n_skipped + 1)); continue ;; esac
        # `ls-tree HEAD -- <path>` prints `<mode> <type> <sha>\t<path>`; a path not in HEAD prints
        # nothing. Fields 1 and 3 are what this needs, and they are positional even when the path is
        # quoted or carries a tab.
        # Captured whole, then read: a `git … | head -1` pipe lets the producer take SIGPIPE under
        # `pipefail`, which reads as "no output" (the repo's #841/#864 class).
        _info="$(git -C "$REPO" ls-tree HEAD -- "$p" 2>/dev/null)"
        read -r mode _type sha _rest <<<"$_info"
        if [ -z "${mode:-}" ] || [ -z "${sha:-}" ]; then
            # NOT IN HEAD: a staged addition, or the DESTINATION of a rename.
            # ⛔ A RENAME DESTINATION MUST LEAVE THE WORKTREE, or the tree never converges: its SOURCE is
            # restored from HEAD, so the destination becomes an UNTRACKED file that (a) makes
            # `git status` dirty for ever, and (b) BLOCKS the next merge the moment upstream adds that
            # path ("untracked working tree files would be overwritten") — which then re-preserves the
            # whole dirty set into a fresh directory every tick. Measured in review. Its bytes are in
            # `changes.patch` and it is copied into `untracked/` first, so nothing is lost.
            # A plain staged ADDITION is different: the file may be the only copy a lane has, so it stays
            # in the worktree (its bytes are in the patch, and it is reported as dirty in the record).
            # bash 3.2-safe membership test (macOS ships 3.2): no array expansion under `set -u`, no grep.
            case $'\n'"$dests" in *$'\n'"$p"$'\n'*) _is_rename_dest=1 ;; *) _is_rename_dest=0 ;; esac
            if [ "$_is_rename_dest" = 0 ] && [ -n "$del_blobs" ] && [ -f "$REPO/$p" ]; then
                _h="$(git -C "$REPO" hash-object -- "$REPO/$p" 2>/dev/null)"
                case $'\n'"$del_blobs" in *$'\n'"$_h"$'\n'*) _is_rename_dest=1 ;; esac
            fi
            if [ "$_is_rename_dest" = 1 ]; then
                mkdir -p "$dest/untracked/$(dirname "$p")" 2>/dev/null || true
                cp -a "$REPO/$p" "$dest/untracked/$p" 2>/dev/null || true
                rm -f "$REPO/$p" 2>/dev/null || true
                n_removed=$((n_removed + 1))
            fi
            git -C "$REPO" update-index --force-remove -- "$p" >/dev/null 2>&1 || true
            [ "$_is_rename_dest" = 1 ] || n_skipped=$((n_skipped + 1))
            continue
        fi
        case "$mode" in
            120000)
                # ⛔ A SYMLINK IS RESTORED AS A SYMLINK. Writing its blob (which IS the target string) to
                # the path would replace the link with a regular FILE holding that text — a type change
                # `git status` reports as still dirty, and the merge then refuses to proceed.
                blob="$(git -C "$REPO" cat-file blob "$sha" 2>/dev/null)" \
                    || { err "cannot bring tracked path $p back to HEAD"; return 1; }
                mkdir -p "$(dirname "$REPO/$p")" 2>/dev/null || { err "cannot bring tracked path $p back to HEAD"; return 1; }
                rm -f "$REPO/$p" 2>/dev/null
                ln -sfn "$blob" "$REPO/$p" 2>/dev/null || { err "cannot bring tracked path $p back to HEAD"; return 1; } ;;
            160000)
                # A GITLINK (submodule) is not materialised here; it is left alone and counted as
                # skipped, so the success line cannot claim it.
                n_skipped=$((n_skipped + 1)); continue ;;
            *)
                mkdir -p "$(dirname "$REPO/$p")" 2>/dev/null || { err "cannot bring tracked path $p back to HEAD"; return 1; }
                tmp="$(dirname "$REPO/$p")/.harness-apply-restore.$$"
                # ⛔ REDIRECT THE BLOB, NEVER `printf '%s' "$blob"`. Command substitution strips every
                # trailing newline, so the printf form silently rewrites any text file that ends with one
                # — i.e. almost all of them — to a version that differs from HEAD.
                git -C "$REPO" cat-file blob "$sha" >"$tmp" 2>/dev/null \
                    || { rm -f "$tmp"; err "cannot bring tracked path $p back to HEAD"; return 1; }
                if [ "$mode" = "100755" ]; then chmod 755 "$tmp" 2>/dev/null || true
                else chmod 644 "$tmp" 2>/dev/null || true; fi
                mv -f "$tmp" "$REPO/$p" 2>/dev/null || { rm -f "$tmp"; err "cannot bring tracked path $p back to HEAD"; return 1; } ;;
        esac
        # INDEX := HEAD for this path. `update-index --cacheinfo` names the (mode, blob) pair explicitly,
        # which is the only form that also carries the executable bit and the symlink mode.
        git -C "$REPO" update-index --add --cacheinfo "$mode,$sha,$p" >/dev/null 2>&1 \
            || { err "cannot move the index entry for $p back to HEAD"; return 1; }
        n_restored=$((n_restored + 1))
    done < <(list_dirty_paths)
    # ⛔ THE CLAIM IS COUNTED, NOT ASSUMED. The unconditional "tracked paths match HEAD" was printed
    # even when a path had been skipped — a success line that outran the work it describes.
    # ⛔ THE SENTENCE MUST MATCH THE TREE. "the hand edits exist only in the preserved copies" was false
    # whenever a path was skipped: a skipped staged addition (or a gitlink) is STILL IN THE WORKTREE and
    # keeps the tree dirty, which the record then reports — two contradictory statements about the same
    # edit, in the message an operator reads when recovering work.
    log_line "restored: $n_restored tracked path(s) brought back to HEAD (mode and content); their hand edits exist only in the preserved copies"
    # ⛔ TWO COUNTERS, because the two outcomes are opposite. A move destination is REMOVED from the
    # worktree (its bytes are preserved, and the tree then converges); a staged addition or a gitlink is
    # SKIPPED and STAYS. Folding them into one count made the sentence claim that removed paths "remain
    # in the worktree — they are what keeps the tree dirty" while the record in the same pass said
    # `dirty=0` — the two-readers contradiction this line exists to avoid, reintroduced by the fix that
    # added the move case.
    [ "$n_removed" -gt 0 ] && log_line "restored: $n_removed move destination(s) removed from the worktree after preservation (a same-content copy of a deleted tracked path)"
    [ "$n_skipped" -gt 0 ] && log_line "restored: $n_skipped path(s) SKIPPED (not in HEAD, or a gitlink) and still in the worktree — they are what keeps the tree dirty"
    log_line "preserved: $n path(s) saved under $dest (names in $dest/MANIFEST)"
    return 0
}

if [ "$PASS_MODE" = sync ] && [ "$RELATION" = behind ] && [ "$DIRTY_N" != "unknown" ] && [ "$DIRTY_N" -gt 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log_line "dry-run: would preserve $DIRTY_N dirty path(s) by name and then fast-forward"
    else
        # ⛔ PER-SECOND IS NOT PER-PASS. Two passes in the same second shared one directory, and the
        # SECOND truncated the first's `changes.patch` and `MANIFEST` — which for restored tracked paths
        # is their only remaining copy. The pid makes the name unique in the only way a shell can.
        PRESERVED_DIR="$STATE_DIR/harness-apply-preserved/$(date -u +%Y%m%dT%H%M%SZ)-$$"
        preserve_dirty "$PRESERVED_DIR" || {
            REC_ACTION=refused-dirty
            # ⛔ THE REDDEST REFUSAL MUST NOT RECORD `remedy=none` (review finding 6). This `detail=` is
            # 474 chars, so `cut -c1-240` lands mid-sentence and discards the action clause — the same
            # class of loss the `remedy=` field exists to prevent, left on the one path that most needs it.
            REC_REMEDY="recover the work from $PRESERVED_DIR (changes.patch + changes.index.patch), fix the cause, then re-run"
            # ⛔ NOT "nothing was touched". Preservation and restore are one pass over the list, so a
            # failure in the RESTORE half can leave the checkout part-restored — every affected byte was
            # written to $PRESERVED_DIR first, but claiming the tree is untouched would be false in the
            # one message an operator reads when this refuses.
            finish 0 20 "REFUSED dirty: $DIRTY_N path(s) in $REPO carry uncommitted work that could not be preserved and restored. Everything that WAS saved is under $PRESERVED_DIR, and nothing was discarded; if the restore had begun the checkout may be part-restored. Fix the cause, then re-run."
        }
    fi
fi

# ── the move ──────────────────────────────────────────────────────────────────────────────────
# ⛔ A NO-OP WHEN THE PIN ALREADY NAMES THE REF TIP — that is the cadence requirement, and it is the
# common case: every ten minutes on a box that is already current must change NOTHING and say so.
ACT_RC=0
if [ "$DRY_RUN" = 1 ]; then
    # ⛔ A PREVIEW WRITES NO RECORD. `--dry-run` is documented as "change NOTHING", and rewriting the
    # pass record to `action=dry-run epoch=now` reset the staleness clock: a box whose timer had died
    # then read `status=ok age=0s` in `--print-status`, in the installer's `--status` and in
    # fleet-health — the false PASS this whole feature exists to delete, produced by its preview verb.
    [ "$PASS_MODE" = pin ] && read_pin
    # ⛔ THE PREVIEW ANSWERS THE EXECUTING-TREE QUESTION TOO (review round 21, P2). `read_deployed_drift`
    # had exactly ONE call site (`finish`), and `--dry-run` exits before `finish`, so the read-only verb
    # — the one an operator uses to inspect a box without changing it — still could not say whether the
    # code that is EXECUTING is this repo's, while the merge evidence printed that line under
    # `--dry-run`. It is PRINT-ONLY here: `read_deployed_drift` writes nothing, and a preview must not
    # red a box (it changes nothing, including the exit contract).
    read_deployed_drift
    log_line "dry-run: relation=$RELATION behind=$BEHIND ahead=$AHEAD dirty=$DIRTY_N mode=$PASS_MODE — nothing was changed and no pass record was written"
    # ⛔ THE PREVIEW MUST NOT IMPLY A CLEAN FARM IT NEVER GRADED. PREDICATE 4 runs at the END of a real
    # pass, so a `--dry-run` that printed only `relation=current` left an operator triaging a red unit
    # with no hint of where the red comes from. The check itself is read-only and cheap, but running it
    # here would make the preview's verdict differ from the pass's (different point in the pass), so it
    # is NAMED and declined instead — an abstention that says so, never a silent one.
    if [ "$FARM_CHECK_ON" = "1" ]; then
        log_line "dry-run: the FARM (${HARNESS_APPLY_FARM_DEST:-$CELL_HOME/.pi/agent/scripts}) was NOT graded against $REF — a real pass does that at the finish line and exits 24 on drift"
    else
        log_line "dry-run: the FARM was NOT graded — HARNESS_APPLY_FARM_CHECK=0 (deliberately disarmed; no drift would redden a real pass either)"
    fi
    exit 0
fi

if [ "$PASS_MODE" = pin ]; then
    MATERIALISER="${HARNESS_MATERIALISER:-$REPO/scripts/cloud-cell-supervisor.sh}"
    # ⛔ THE ADVANCE DECISION IS ABOUT THE **DEPLOYED** COMMIT, NOT THE CHECKOUT. A pin advance never
    # moves the checkout, so `RELATION` (computed from HEAD) is `behind` on every tick for ever once
    # main passes it — and `apply --pin-only` exits 0 when the pin already names the tip. Deciding on
    # HEAD therefore made a CONVERGED cell call the materialiser every ten minutes and record
    # `advanced` / rc=10 every time, asserting a move that did not happen and making the documented
    # no-op cadence unreachable in pin mode (measured in review). The pin tree is what runs.
    if [ -n "$PIN_TREE_SHA" ] && [ "$PIN_TREE_SHA" = "$REF_SHA" ]; then
        # Converged. The pin RECORD may still disagree with that tree — c1's state — and it is repaired
        # below.
        log_line "advance: the pin already names $REF ($(short "$REF_SHA")) — no-op"
        REC_ACTION=none
    elif [ -z "$PIN_TREE_SHA" ] && [ "$RELATION" = current ]; then
        # No pin tree materialised (first run on a box that has a pin record, or a checkout whose pin
        # has never been created) and the checkout IS the deployment: nothing to do.
        REC_ACTION=none
    else
        # ⛔ THE MATERIALISER IS REQUIRED ONLY TO ADVANCE. Checking for it ABOVE the converged test made a
        # healthy, up-to-date box record rc=25 ("no way to advance its own pin") beside `behind=0` — a RED
        # unit every ten minutes, `CELL READY` refused, and the documented no-op cadence unreachable in
        # pin mode unless the test happened to hand it a stub (measured in review).
        if [ ! -f "$MATERIALISER" ]; then
            REC_ACTION=unmaterialisable
            # ⛔ `remedy=` CARRIES THE ONLY ACTIONABLE TOKEN (review round 13, finding 2). This
            # message is 208 chars and `finish` appends a 142-char readings suffix, so the
            # `(set HARNESS_MATERIALISER)` hint sat past the 240 cut and was DISCARDED — shipping a red
            # rc=25 the operator could not act on, which is exactly what this field exists to prevent.
            REC_REMEDY="set HARNESS_MATERIALISER to this box's materialiser (cloud-cell-supervisor.sh), then re-run"
            finish 0 25 "this box has no materialiser at $MATERIALISER, so the pin cannot be advanced to $(short "$REF_SHA") (set HARNESS_MATERIALISER)"
        fi
        BEFORE_PIN_TREE="$PIN_TREE_SHA"
        # ⛔ `--force --pin-only`, ALWAYS — BOTH FLAGS, AND FOR DIFFERENT REASONS.
        #   `--pin-only` because a SCHEDULER MUST NOT SEED $O. A plain `apply` runs `seed_and_stamp`,
        #      which swaps the helpers a RUNNING loop is executing under it — the version skew
        #      cloud-cell-supervisor.sh's own header refuses. Seeding belongs to `start`; a pin does
        #      not disturb a lane (it keeps the tree it started with) and the restart is deferred to
        #      the next launch, exactly as harness-refresh.sh's recorded design says.
        #   `--force` because `apply` REFUSES to touch a cell whose controller is live WITHOUT it —
        #      `--pin-only` does not relax that guard. Measured in review: `apply --pin-only` on a
        #      live cell exits 1 with "a controller is RUNNING … re-run with --force", so the pass
        #      recorded rc=23 and the unit went RED every ten minutes on a healthy box while the pin
        #      never moved. harness-refresh.sh passes both flags for the same reason.
        #   The guard `--force` relaxes here is "do not replace the harness tree under a live
        #      controller", and a pin-only advance cannot: it creates a NEW per-commit worktree and
        #      leaves the running one untouched. Nothing else about `apply` changes.
        # ⛔ EVERY VALUE THE CHILD WOULD RESOLVE FOR ITSELF GOES ON ITS OWN COMMAND LINE, like the
        #      checker 400 lines above (agent-infra#3593). The materialiser RESOLVES the same paths
        #      from ITS defaults — `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"`
        #      (cloud-cell-supervisor.sh:139), then `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE` from it — and
        #      a shell variable set HERE is invisible to a child unless it is exported. Measured on a
        #      cell whose unit sets `HOME` and no `CELL_HOME`: this pass resolved `/home/cmux`, the
        #      materialiser pinned into `/tmp/cell-home/harness/<sha12>`, the re-read below saw no move
        #      and reported rc=25 "nothing moved this box" — a TRUE reading of the WRONG records, and
        #      it `finish`es BEFORE predicate 4, so on that box the farm grade this whole feature
        #      exists to emit could never run at all.
        #      ⛔ THE LIST IS EVERY NAME THIS PASS RESOLVES THAT `apply` READS — and `HARNESS_PIN` is
        #      included even though `cmd_apply` does not consult it today: the materialiser's OTHER
        #      verbs do (`cmd_status`, cloud-cell-supervisor.sh:4046), so forwarding it keeps a later
        #      `status` call from answering about a different record. `HARNESS_FETCH` is the one
        #      resolved name deliberately NOT forwarded (:205): the child re-derives the same value
        #      from the identical default (`:1776`), and handing over `0` would change an exit code
        #      on a hermetic box — a verdict this repair does not own. Carried on agent-infra#3593.
        OUT="$(CELL_HOME="$CELL_HOME" HARNESS_PIN="$PIN_SHA_FILE" HARNESS_PIN_FILE="$PIN_PATH_FILE" HARNESS_PIN_DIR="$PIN_ROOT" HARNESS_REPO="$REPO" HARNESS_REF="$REF" bash "$MATERIALISER" apply --force --pin-only 2>&1)"; ACT_RC=$?
        printf '%s\n' "$OUT" | sed 's/^/  /'
        [ "$ACT_RC" -eq 0 ] || {
            REC_ACTION=materialiser-failed
            finish 0 23 "the materialiser exited $ACT_RC — the pin was NOT advanced (nothing was seeded either)"
        }
        # ⛔ "THE VERB EXITED 0" IS NOT EVIDENCE OF A MOVE. Re-read the pin and judge the RESULT: only a
        # tree that is now at the ref tip is `advanced`; a box that did not move is `none` (exit 0) or,
        # when it is still behind after a call that claimed success, a NAMED failure (25) — never a
        # green `advanced` over an unchanged pin.
        read_pin
        if [ "$PIN_TREE_SHA" = "$REF_SHA" ]; then
            REC_ACTION=advanced
        elif [ "$PIN_TREE_SHA" != "${BEFORE_PIN_TREE:-}" ]; then
            # ⛔ A MOVE THAT DOES NOT REACH THE TIP IS NOT `advanced`. `apply` pins `$HARNESS_REF`; if the
            # pin landed somewhere else the box is still off main, and calling that "advanced" (a GREEN
            # unit code) beside `behind=N` made the comment above this block — and the doc's colour
            # table — describe a rule the code did not enforce. 25 is the code for "behind, and this pass
            # has nothing that reaches the ref", and BOTH readers red it on the number anyway.
            REC_ACTION=partial-move
            finish 0 25 "the pin moved to $(short "$PIN_TREE_SHA") but $REF is $(short "$REF_SHA") — the box is still off the ref"
        else
            # ⛔ NO `elif [ "$RELATION" = current ]` ARM. `RELATION` is the CHECKOUT's relation, and a pin
            # advance never moves the checkout — so a pin tree that is BEHIND while the checkout is at the
            # tip fell through here and was recorded `none`/rc=0 (a GREEN unit) with `deployed=<behind>`
            # in the record beside a sentence claiming the pin tree "already names origin/main". The
            # no-pin-tree + current-checkout case is handled in the DECISION above; anything that reaches
            # here did not move and is not at the ref, which is exactly what 25 means.
            REC_ACTION=no-move
            finish 0 25 "the materialiser exited 0 but the pin still names $(short "${PIN_TREE_SHA:-<none>}") while $REF is $(short "$REF_SHA") — nothing moved this box"
        fi
    fi
else
    # sync path — the checkout's OWN verb (fetch + ff-only + config refresh + launchd), never a
    # second implementation of it.
    SYNC_CMD="${HARNESS_APPLY_SYNC_CMD:-$REPO/sync.sh}"
    if [ "$RELATION" = current ]; then
        REC_ACTION=none
    else
        # The checkout is handed to the verb as $1: `./sync.sh` ignores arguments (it cds to its own
        # dir), and a configured verb that needs to know which tree it is syncing gets the answer
        # rather than having to guess it from its cwd. One seam, both shapes.
        # ⛔ THE SYNC VERB IS REQUIRED ONLY TO ADVANCE (see the materialiser note above).
        if [ ! -e "$SYNC_CMD" ]; then
            REC_ACTION=no-sync-verb
            finish 0 25 "this box has no sync verb at $SYNC_CMD, so the checkout cannot be advanced to $(short "$REF_SHA")"
        fi
        OUT="$(bash "$SYNC_CMD" "$REPO" 2>&1)"; ACT_RC=$?
        printf '%s\n' "$OUT" | sed 's/^/  /'
        # ⛔ THE SYNC'S EXIT IS NOT THE ONLY FACT. `sync.sh` exits 0 when the checkout is not on main
        # (the branch-ownership guard, #265), which is a SKIP, not an advance — so the HEAD is re-read
        # and the outcome judged from the tree, never from the verb's own claim.
        NEW_HEAD="$(git -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
        if [ "$ACT_RC" -eq 0 ] && [ "$NEW_HEAD" = "$REF_SHA" ]; then
            REC_ACTION=advanced; HEAD_SHA="$NEW_HEAD"
        elif [ "$ACT_RC" -eq 0 ]; then
            REC_ACTION=sync-skipped; REC_HEAD="$(short "$NEW_HEAD")"
            finish 0 25 "the sync verb exited 0 but HEAD is $(short "$NEW_HEAD"), not $REF — the checkout was not moved (not on main? a skipped guard?). behind=$BEHIND"
        else
            REC_ACTION=sync-failed
            finish 0 23 "the sync verb exited $ACT_RC and HEAD is $(short "$NEW_HEAD") — the checkout was not moved"
        fi
    fi
fi

# ── PREDICATE 3: THE PIN MUST NAME THE TREE'S ACTUAL HEAD ─────────────────────────────────────
# Read AFTER the move: on the pin path `apply` has just written both records, so any disagreement
# that survives is a REAL one. MEASURED (c1, 2026-10-23): HARNESS-PIN 54bbb0c6 while the tree the
# path record names was at ce987bb2 — every reader then reported a commit nobody was running.
if [ "$PASS_MODE" = pin ]; then
    read_pin
    if [ "$REC_PIN_TREE" != "none" ]; then
        TREE_SHA="$(head -1 "$PIN_PATH_FILE" 2>/dev/null)"
        TREE_SHA="$(git -C "$TREE_SHA" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
        if [ -z "$REC_PIN" ] || [ "$REC_PIN" = "none" ]; then
            # MEND: an absent/empty pin is the measured 2026-10-20 fleet state, and recording what
            # this box actually runs is strictly better than leaving the record empty.
            printf '%s\n' "$TREE_SHA" >"$PIN_SHA_FILE.tmp-$$" 2>/dev/null \
                && mv -f "$PIN_SHA_FILE.tmp-$$" "$PIN_SHA_FILE" 2>/dev/null \
                || { REC_ACTION=pin-unwritable; finish 0 23 "cannot record the pin at $PIN_SHA_FILE (the tree runs $(short "$TREE_SHA"))"; }
            log_line "pin: MENDED (was absent) -> $(short "$TREE_SHA")"
            REC_ACTION=mended
        elif [ "$(short "$TREE_SHA")" != "$REC_PIN" ]; then
            OLD_PIN="$REC_PIN"
            printf '%s\n' "$TREE_SHA" >"$PIN_SHA_FILE.tmp-$$" 2>/dev/null \
                && mv -f "$PIN_SHA_FILE.tmp-$$" "$PIN_SHA_FILE" 2>/dev/null \
                || { REC_ACTION=pin-unwritable; finish 0 23 "the pin ($OLD_PIN) disagrees with the tree ($(short "$TREE_SHA")) and $PIN_SHA_FILE could not be rewritten — the pin still lies"; }
            log_line "pin: REPAIRED $OLD_PIN -> $(short "$TREE_SHA") (the pin now names the tree this box actually runs)"
            REC_ACTION=pin-repaired
        fi
    else
        # A pin record that names a tree which is not there, or a box with no PATH record at all:
        # reported, never invented. The sha record may legitimately be the only one on a box whose
        # controller was never started from a pin.
        log_line "pin: no tree at $PIN_PATH_FILE — the sha record ${REC_PIN} cannot be checked against a checkout"
    fi
fi

# ── PREDICATE 4: THE FARM — the directory this box EXECUTES, which no other leg looks at ──────
# ⛔ WHY THIS PREDICATE EXISTS (tortoise#10114, MEASURED 2026-11-03 on a cloud cell). This pass keeps
# `$O` — the harness shell scripts — at the ref, and `check-deployed-drift.sh` grades exactly that
# directory, so both read GREEN. But the actuators this box actually runs (`pr-doctor.py`,
# `objective.py`, `fleet/`, `disk-reaper.sh`) live in the FARM, `$CELL_HOME/.pi/agent/scripts`, which
# NOTHING on the clock compares against the ref: `pi-bootstrap/setup.sh` farms it at INSTALL time and
# then never looks again. The measured result: `$O` clean at the pin while the farm carried a
# `pr-doctor.py` 1445 lines behind the ref — the exact copy that brief-gate refused 100% of, the
# no-op #10114 exists to remove, still running four days after the first hand-repair.
#
# ⛔ SO THE MISSING LEG IS NOT "CHECK HARDER", IT IS "CHECK THE FARM AT ALL". `scripts/
# check-farm-drift.sh` already IS that instrument (it was written for this issue, and its exit
# vocabulary — 0 match / 1 drift / 3 undeployable / 2 unknown — is adopted here rather than invented
# again; a second drift checker is the defect #1178 names). This predicate puts it ON THE CLOCK, in
# the pass that already owns deploy, so a stale farm is a RED PASS BY NAME instead of a green silence.
#
# ⛔ IT DOES NOT RE-FARM, and that is deliberate. Copying over a farm can destroy a local edit that
# exists nowhere else — the `harness-provenance.sh recover` procedure exists for exactly that — so
# this leg reports the drift and names the remedy; a human or an explicit `setup.sh` run decides.
#
# An ABSENT farm is SKIPPED, not red: a controller-only host farms nothing, so there is no stale
# actuator there to be silent about. That is a verifiable fact about the box (the directory is not
# there), not a cannot-verify — unlike an absent or unrunnable CHECKER, which is red.
# ⛔ `-d` FOLLOWS SYMLINKS, so "not a directory" and "nothing is there" are NOT the same fact: a
# DANGLING or relocated `$FARM_DEST` link makes `-d` false while the box still POINTS AT a farm it
# cannot read, and passing that as SKIPPED is the false green `check-farm-drift.sh` names twice. Only
# a path with NOTHING at it (neither a directory nor a link nor a file) may be skipped.
if [ "$FARM_CHECK_ON" = "0" ]; then
    # ⛔ AN ABSTENTION THAT SAYS SO, never a silent one — the same rule the preview arm below follows.
    log_line "farm: SKIPPED — HARNESS_APPLY_FARM_CHECK=0 (deliberately disarmed; a stale farm will NOT redden this pass)"
fi
if [ "$FARM_CHECK_ON" = "1" ]; then
    FARM_CHECKER="${HARNESS_APPLY_FARM_CHECKER:-}"
    if [ -z "$FARM_CHECKER" ]; then
        for _c in "$REPO/scripts/check-farm-drift.sh" "$HERE/check-farm-drift.sh"; do
            [ -f "$_c" ] && { FARM_CHECKER="$_c"; break; }
        done
        unset _c
    fi
    if [ ! -d "$FARM_DEST" ] && [ ! -e "$FARM_DEST" ] && [ ! -L "$FARM_DEST" ]; then
        # ⛔ ABSENT-BY-DEFAULT AND ABSENT-BECAUSE-MISCONFIGURED ARE DIFFERENT FACTS. A controller-only
        # host has no farm and nothing to be stale; a box whose operator NAMED a farm that is not
        # there has a broken config, and calling that `SKIPPED` is the silent green this leg removes.
        if [ -n "${HARNESS_APPLY_FARM_DEST:-}" ]; then
            REC_ACTION=farm-unverifiable
            finish 0 24 "farm: UNKNOWN — HARNESS_APPLY_FARM_DEST names $FARM_DEST, where nothing exists; an explicitly-configured farm that is not there is a misconfiguration, not a controller-only host"
        fi
        # ⛔ ...AND `$HERE` IS THE CHECK ON THE SKIP LINE'S OWN CLAIM. The unit prefers
        # `$HOME/.pi/agent/scripts/harness-apply-pass.sh`, so on a real box THIS FILE runs out of a
        # farm: if `$FARM_DEST` names nothing while `$HERE` is farm-shaped, the line "a host that
        # executes nothing from there cannot be stale" is FALSE about this host, and the skip would be
        # green over the very farm the pass is executing from (review round 6).
        case "$HERE" in
            */.pi/agent/scripts|*/.pi/agent/scripts/)
                REC_ACTION=farm-unverifiable
                finish 0 24 "farm: UNKNOWN — this pass executes FROM a farm ($HERE) but $FARM_DEST names nothing (CELL_HOME='$CELL_HOME'), so the directory that is really running was never graded; pin the farm (HARNESS_APPLY_FARM_DEST, or render CELL_HOME) instead of letting it default to a path with nothing at it" ;;
        esac
        log_line "farm: SKIPPED — no farm at $FARM_DEST (a host that executes nothing from there cannot be stale)"
    elif [ ! -d "$FARM_DEST" ]; then
        REC_ACTION=farm-unverifiable
        finish 0 24 "farm: UNKNOWN — $FARM_DEST exists (or is a link) but is NOT a readable directory, so the scripts this box executes cannot be graded — a dangling record is not an absent farm"
    elif [ -z "$FARM_CHECKER" ] || [ ! -f "$FARM_CHECKER" ]; then
        REC_ACTION=farm-unverifiable
        finish 0 24 "farm: UNKNOWN — $FARM_DEST holds the scripts this box EXECUTES, but no check-farm-drift.sh could be found (looked in $REPO/scripts and $HERE) — cannot-verify is not a pass"
    else
        # `--ref "$REF" --no-pin-identity` deliberately. The fact under test is "are the farmed bytes
        # the bytes the ref ships", so the grade must be pinned to the REF — and `check-farm-drift.sh`
        # enables its PIN-IDENTITY arm by DEFAULT, which would refuse (exit 2, "COMPARING AGAINST THE
        # WRONG TREE") before grading a single file whenever this box's pin record disagrees with the
        # checkout. That refusal is a real finding, but it belongs to the deploy leg's own
        # `pin-lies`/`cannot-verify` arms (exit 25/23 below), not here: without `--no-pin-identity` a
        # perfectly fresh farm on a pin-lagged box would be reported as farm drift with the wrong
        # remedy (#10114 review).
        # ⛔ A CHECKER THAT LIVES INSIDE THE FARM CANNOT GRADE THE FARM. The systemd unit runs this
        # pass FROM the farm (`install-harness-apply-timer.sh` prefers
        # `$HOME/.pi/agent/scripts/harness-apply-pass.sh`), so `$HERE` IS `$FARM_DEST` there — and on a
        # checkout older than this feature `$REPO/scripts/check-farm-drift.sh` is absent, so the
        # fallback would execute the farm's own (possibly stale) checker over the farm's own
        # population. That is the fail-open shape this leg exists to remove, so it refuses instead.
        # ⛔ RESOLVE THE CHECKER'S FINAL TARGET, not just its directory. `pwd -P` resolves the DIR and
        # appends `basename` unresolved, and comparing against `$FARM_DEST/$(basename ...)` only catches
        # a link that keeps its NAME — so `grade.sh -> $FARM/_sub/check-farm-drift.sh` (another name,
        # another path) graded the farm from inside it and printed `farm: ok` (review rounds 2 and 3,
        # both reproduced). ⛔ `readlink -f` is NOT used: it is a BSD portability trap
        # (`check-portability-traps.sh`) and this pass runs on macOS — the loop is bash-3.2 safe, with a
        # bound so a link cycle ends in a refusal instead of a hang.
        FARM_CHECKER_T="$FARM_CHECKER"; _hops=0
        while [ -L "$FARM_CHECKER_T" ] && [ "$_hops" -lt 40 ]; do
            # ⛔ A FAILED `readlink` USED TO `break`, leaving `FARM_CHECKER_T` still the SYMLINK — and a
            # symlink path is only partly resolved below (`pwd -P` on its DIR + the unresolved basename),
            # so the containment test read it as OUTSIDE the farm and the leg then EXECUTED it, letting
            # the farm grade itself green (review round 4, reproduced with a `readlink` that exits 1).
            # A link whose target cannot be located cannot be ruled outside the farm, so it refuses.
            _l="$(readlink "$FARM_CHECKER_T" 2>/dev/null)" || {
                REC_ACTION=farm-unverifiable
                finish 0 24 "farm: UNKNOWN — readlink failed on $FARM_CHECKER_T, so the checker's FINAL target cannot be resolved, and a copy that cannot be located cannot be ruled outside the farm"
            }
            case "$_l" in
                /*) FARM_CHECKER_T="$_l" ;;
                *) FARM_CHECKER_T="$(cd "$(dirname "$FARM_CHECKER_T")" 2>/dev/null && pwd -P)/$_l" ;;
            esac
            _hops=$((_hops + 1))
        done
        unset _l
        # ⛔ THE HOP CAP IS A REFUSAL TOO. A chain longer than the bound exits the loop above with
        # `-L` STILL TRUE, i.e. with the same half-resolved path the failed-`readlink` arm now refuses.
        if [ -L "$FARM_CHECKER_T" ]; then
            REC_ACTION=farm-unverifiable
            finish 0 24 "farm: UNKNOWN — $FARM_CHECKER is a symlink chain that did not resolve within 40 hops, so where it points cannot be established"
        fi
        FARM_CHECKER_REAL="$(cd "$(dirname "$FARM_CHECKER_T")" 2>/dev/null && pwd -P)/$(basename "$FARM_CHECKER_T")"
        FARM_DEST_REAL="$(cd "$FARM_DEST" 2>/dev/null && pwd -P)"
        # ⛔ ...AND IT MUST BE THE FARM THIS PASS RUNS FROM. The `case "$HERE"` refusal above only fires
        # when `$FARM_DEST` names NOTHING; when it names a DIFFERENT farm that exists, the pass grades
        # that one and reports green over the farm it is executing (review round 7, reproduced with two
        # farms on one box). On the production install path the two are equal — the unit runs
        # `$HOME/.pi/agent/scripts/harness-apply-pass.sh` and `$FARM_DEST` defaults to
        # `$CELL_HOME/.pi/agent/scripts` — so this creates no false red where the box is consistent.
        case "$HERE" in
            */.pi/agent/scripts|*/.pi/agent/scripts/)
                HERE_REAL="$(cd "$HERE" 2>/dev/null && pwd -P)"
                if [ -n "$HERE_REAL" ] && [ "$HERE_REAL" != "$FARM_DEST_REAL" ]; then
                    REC_ACTION=farm-unverifiable
                    finish 0 24 "farm: UNKNOWN — this pass executes FROM $HERE_REAL but grades $FARM_DEST_REAL; the farm that is really running was never graded — pin the farm (HARNESS_APPLY_FARM_DEST, or render CELL_HOME) to the one the units execute"
                fi ;;
        esac
        if [ -n "$FARM_DEST_REAL" ] && [ "${FARM_CHECKER_REAL#"$FARM_DEST_REAL"/}" != "$FARM_CHECKER_REAL" ]; then
            REC_ACTION=farm-unverifiable
            finish 0 24 "farm: UNKNOWN — the only check-farm-drift.sh found ($FARM_CHECKER) lives INSIDE the farm it would grade, and a copy that grades itself cannot answer whether it is stale — install the CHECKER from a ref-consistent checkout"
        fi
        FARM_OUT="$(bash "$FARM_CHECKER" --src "$REPO" --ref "$REF" --dest "$FARM_DEST" --no-pin-identity 2>&1)"
        FARM_RC=$?
        # The checker's own per-file vocabulary, matched on the FINAL column, and ONLY the four it
        # actually prints as a verdict. `MISSING` and `LOCAL (undeclared)` are not tokens it emits;
        # `SYMLINK` IS printed (`check-farm-drift.sh:485`, "SYMLINK (graded via its target)") but that
        # row is INFORMATIONAL — a healthy link — so matching the bare token would name a good file as
        # drift the moment the anchor is relaxed (#10114 review round 2).
        FARM_NAMED="$(printf '%s\n' "$FARM_OUT" | awk -F'|' '$NF ~ /(^|[[:space:]])(STALE|UNSOURCED|NOT-EXECUTABLE|DECLARED-BUT-ABSENT)[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}' | head -6 | paste -sd, -)"
        case "$FARM_RC" in
            0)
                log_line "farm: ok — $FARM_DEST matches $REF" ;;
            1|3)
                # 3 ("a deploy cannot fix it") is folded in on purpose: an UNSOURCED or
                # not-farm-declared stale file is drift this box EXECUTES, and the one thing it must
                # never be is a green pass because the fix is awkward.
                REC_ACTION=farm-drift
                # ⛔ THE INSTRUMENT'S OWN REMEDY, NOT ONE OF OURS. `check-farm-drift.sh` separates
                # three classes with three DIFFERENT remedies and says so in its own words ("A deploy
                # cannot fix this one", "declare it LOCAL, delete, or retire … never re-run the farm").
                # Prescribing "re-farm" for an UNSOURCED or not-farm-declared row contradicts the run
                # that just produced it, and the reviewer's own measurement of this box's first repair
                # was exactly that shape (one row was a LAYOUT MOVE, not a copy). So its `Next:` line
                # and per-file rows are forwarded verbatim.
                # ⛔ THE REMEDY IS THE LAST LINE THE INSTRUMENT PRINTS, and it prints one row PER FILE,
                # unbounded (#1552 measured 27 files on one box). A single `head -12` over both cut the
                # remedy off at exactly the states that need it (#10114 review round 7, reproduced with
                # a 20-row farm). So the rows are a bounded excerpt — SAYING it is an excerpt — and the
                # remedy is forwarded separately and unconditionally.
                # ⛔ MATCH THE FINAL COLUMN, NOT THE WHOLE LINE. The instrument prints four unconditional
                # CLASS-PROSE lines ("A STALE file is a copy launchd/systemd will EXECUTE…"), so a
                # whole-line grep counts prose as file rows — 3 real rows measured as "7 row(s)"
                # (#10114 review round 8). `FARM_NAMED` above uses the same predicate; reuse it.
                FARM_ROWS="$(printf '%s\n' "$FARM_OUT" | awk -F'|' '$NF ~ /(^|[[:space:]])(STALE|UNSOURCED|NOT-EXECUTABLE|DECLARED-BUT-ABSENT)[[:space:]]*$/')"
                FARM_NROWS="$(printf '%s' "$FARM_ROWS" | grep -c .)"
                # ⛔ THE REMEDY IS A BLOCK, NOT A LINE. Two of the instrument's three remedies are TWO
                # lines and the CONTINUATION carries the actions ("…, delete it, or retire it in
                # pi-bootstrap/farm-retired.txt; then re-run this."), so forwarding only the `Next:`
                # line cut the remedy mid-word for exactly the classes whose remedy differs from
                # "re-farm" (#10114 review round 8). Everything from the first `Next:` to EOF.
                FARM_REMEDY="$(printf '%s\n' "$FARM_OUT" | sed -n '/^[[:space:]]*Next:/,$p' | head -8)"
                log_line "farm: $REF ships different bytes than $FARM_DEST execute — $FARM_NROWS row(s) from the instrument:"
                printf '%s\n' "$FARM_ROWS" | head -12 | while IFS= read -r _row; do
                    log_line "farm:   $_row"
                done
                if [ "$FARM_NROWS" -gt 12 ]; then
                    log_line "farm:   … and $((FARM_NROWS - 12)) more row(s) in the instrument's own output"
                fi
                [ -n "$FARM_REMEDY" ] && printf '%s\n' "$FARM_REMEDY" | while IFS= read -r _row; do
                    log_line "farm:   $_row"
                done
                finish 0 24 "farm: DRIFT — $FARM_DEST is NOT the code $REF ships (${FARM_NROWS} row(s) above, with the instrument's own remedy — a stale copy, a layout move and an unsourced file do NOT all have the same fix)" ;;
            *)
                REC_ACTION=farm-unknown
                finish 0 24 "farm: UNKNOWN (check-farm-drift rc=$FARM_RC) — $FARM_DEST could not be graded against $REF, and cannot-verify is not a pass: $(printf '%s' "$FARM_OUT" | grep -m1 -iE 'unknown|cannot|refus' || printf 'no reason printed')" ;;
        esac
    fi
fi

# ── the verdict ──────────────────────────────────────────────────────────────────────────────
read_pin_done=0
[ "$PASS_MODE" = pin ] && read_pin_done=1
[ "$read_pin_done" = 1 ] && read_pin
REC_ACTION="${REC_ACTION:-none}"
# Read the DEPLOYED state once here, so the verdict's own branches see the same numbers `finish` will
# record (before this, a branch tested `REC_DEPLOYED` while it was still the initial "unknown" and
# refused a perfectly healthy sync-mode box).
recompute_deployed || true
case "$REC_ACTION" in
    mended)
        # 11, the code `harness-refresh.sh` uses for the same event and the one this file's header and
        # the unit's SuccessExitStatus advertise. Folding it into 10 made the vocabulary a lie: a box
        # whose pin had been EMPTY was recorded as "advanced", and anything keyed on 11 was dead code.
        finish 1 11 "mended: the pin was missing and now names the tree this box runs" ;;
    advanced|pin-repaired)
        if [ "$REC_ACTION" = "pin-repaired" ]; then
            # Neutral on purpose: the RECORD was the thing that disagreed. Whether the tree moved is a
            # separate fact, and this arm fires when the record lagged a tree the materialiser DID move.
            finish 1 10 "pin-repaired: the PIN RECORD now names the tree this box runs"
        fi
        finish 1 10 "advanced: the harness moved onto $REF" ;;
    none)
        # ⛔ CURRENT IS NOT ENOUGH ON ITS OWN. A pin that names the ref tip while the PATH record
        # points at an older tree is `restart-pending` at best and a lie at worst; say which.
        # A pin path record that names nothing resolvable: the box cannot start from it, and this pass
        # must not call that "current" (see recompute_deployed).
        if [ "$REC_DEPLOYED" = "unknown" ] || [ -z "${DEPLOYED_SHA:-}" ]; then
            REC_ACTION=cannot-verify
            finish 0 23 "cannot-verify: $PIN_PATH_FILE names a tree that is not resolvable, so what this box would RUN is unknown — nothing was touched"
        fi
        if [ "$PASS_MODE" = pin ] && [ "$REC_PIN_TREE" != "none" ] && [ "$REC_PIN_TREE" != "$REC_PIN" ]; then
            REC_ACTION=restart-pending
            finish 0 25 "current for the checkout, but the PIN and the tree this box reads disagree — harness-up reports this as restart-pending, and nothing here restarts a live controller"
        fi
        if [ "$PASS_MODE" = pin ]; then
            if [ "$REC_PIN_TREE" != "none" ]; then
                finish 1 0 "current: the pin tree already names $REF — nothing changed"
            fi
            # NO PIN TREE IS MATERIALISED. The supervisor then resolves the harness from this checkout
            # (the pin file is empty or absent), so the checkout IS the deployment and it matches the
            # ref — that is a healthy box, and the message says which basis it used. But an ABSENT sha
            # record is the measured 2026-10-20 fleet state, and recording what the box actually runs is
            # strictly better than leaving the record empty: mend it from the checkout.
            if [ -z "$REC_PIN" ] || [ "$REC_PIN" = "none" ]; then
                if printf '%s\n' "$HEAD_SHA" >"$PIN_SHA_FILE.tmp-$$" 2>/dev/null \
                   && mv -f "$PIN_SHA_FILE.tmp-$$" "$PIN_SHA_FILE" 2>/dev/null; then
                    log_line "pin: MENDED (was absent) -> $(short "$HEAD_SHA") (no pin tree; the checkout is the deployment)"
                    REC_ACTION=mended
                    finish 1 11 "mended: the pin was missing and now names the checkout this box runs"
                fi
                REC_ACTION=pin-unwritable
                finish 0 23 "the pin record is absent and could not be written at $PIN_SHA_FILE — nothing here records what this box runs"
            fi
            # THE SHA RECORD NAMES SOMETHING ELSE, AND NO TREE CAN BE CHECKED AGAINST IT. That is the
            # state this feature is about ("the pin stops lying"); it is NOT success, and the old message
            # ("the pin already names $REF") contradicted the record's own `pin=` field.
            if [ "$REC_PIN" != "$REC_REF" ]; then
                REC_ACTION=pin-lies
                REC_REMEDY="materialise the pin tree named by HARNESS-PIN (apply --pin-only), then re-run; nothing on this box can repair a lying pin record without one"
                finish 0 25 "the sha record names $REC_PIN but no pin tree resolves, so it cannot be compared with what this box RUNS ($REC_DEPLOYED) — the pin is still lying; nothing here can repair it without a materialised tree"
            fi
            finish 1 0 "current: no pin tree is materialised and the checkout already matches $REF — nothing changed"
        fi
        finish 1 0 "current: the checkout already matches $REF — nothing changed" ;;
    *)
        # ⛔ THE DEFAULT ARM IS RED. It used to be `finish 1 0` — any action this case statement did not
        # enumerate would be recorded ok=1 rc=0 with a bare action name, i.e. a fail-open default for
        # every state a future edit might add.
        finish 0 25 "UNRECOGNISED action '$REC_ACTION' — this pass does not know whether that is success, so it will not claim it" ;;
esac
