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
#   10  advanced      the materialiser ran and the pin moved to the ref tip (or the pin record was
#                     repaired to the tree's head, or preserved dirt was restored as part of it)
#   11  mended        the pin was missing/empty/not-a-commit; what this box actually runs was recorded
#   20  REFUSED dirty the tree to move carries uncommitted work AND it could not be preserved
#   21  REFUSED ahead local commits are not on the ref's line — nothing was touched
#   22  REFUSED diverged the running commit is neither ancestor nor descendant — nothing was touched
#   23  REFUSED unknown the ref/repo/running commit cannot be resolved (cannot-verify is not a pass),
#                     the materialiser failed, or the pin record could not be written
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

say()  { printf '%s\n' "$*"; }
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

# ── the pass record ────────────────────────────────────────────────────────────────────────────
# One line of key=value, written ATOMICALLY (temp + rename): a truncated record is indistinguishable
# from "no pass has run", and that is the false-PASS shape this feature exists to remove.
REC_HEAD=""; REC_REF=""; REC_BEHIND="unknown"; REC_AHEAD="unknown"; REC_DIRTY="unknown"
REC_PIN="none"; REC_PIN_TREE="none"; REC_ACTION="none"; REC_DETAIL=""; PRESERVED_DIR=""; REC_DEPLOYED="unknown"
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
        printf 'preserved=%s\n' "${PRESERVED_DIR:-none}"
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
    [ -f "$RECORD" ] || { say "status=never pin=none — no pass has ever completed on this box ($RECORD)"; return 3; }
    local body epoch rc age
    body="$(cat "$RECORD" 2>/dev/null)"
    epoch="$(printf '%s\n' "$body" | sed -n 's/^epoch=\([0-9]*\)$/\1/p' | head -1)"
    rc="$(printf '%s\n' "$body" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
    behind="$(printf '%s\n' "$body" | sed -n 's/^behind=//p' | head -1)"
    fetchs="$(printf '%s\n' "$body" | sed -n 's/^fetch=//p' | head -1)"
    case "${epoch:-}" in
        ''|*[!0-9]*)
            say "status=unreadable rc=${rc:-?} — the record carries no usable epoch, so its age cannot be judged (cannot-verify is not fresh)"
            return 3 ;;
    esac
    age=$(( $(date +%s) - epoch ))
    # ⛔ A FUTURE-DATED RECORD IS STALE, NOT `age=0`. Clamping it made the clamp itself the bug: the
    # comment said "stale-by-definition" while the code printed `status=ok age=0s`, so a record dated
    # an hour ahead read fresh for ever — and `fleet-health.py` alarmed on the SAME file, two readers
    # disagreeing about one record with the READINESS GATE being the lenient one (measured in review).
    if [ "$age" -lt 0 ] || [ "$age" -gt "$STALE_SECONDS" ]; then
        if [ "$age" -lt 0 ]; then
            say "status=stale rc=${rc:-?} age=${age}s — the record is dated in the FUTURE, so its age proves nothing"
        else
            say "status=stale rc=${rc:-?} age=${age}s — the timer is not firing (bound ${STALE_SECONDS}s)"
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
                *) say "status=behind rc=$rc behind=${behind:-unknown} age=${age}s — the pass exited cleanly but the box is NOT on $REF"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
            esac
            case "${fetchs:-}" in
                ok|'') ;;
                *) say "status=cannot-verify rc=$rc fetch=$fetchs age=${age}s — the comparison was not fresh"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
            esac
            say "status=ok rc=$rc age=${age}s"; printf '%s\n' "$body" | sed 's/^/  /'; return 0 ;;
        *)       say "status=failed rc=${rc:-?} age=${age}s — a human must look"; printf '%s\n' "$body" | sed 's/^/  /'; return 3 ;;
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
say "harness: mode=$PASS_MODE repo=$REPO ref=$REF fetch=$FETCH_STATE head=$(short "$HEAD_SHA") checkout_relation=$RELATION checkout_behind=$BEHIND ref_sha=$(short "$REF_SHA") dirty=$DIRTY_N pin=$REC_PIN pin_tree=$REC_PIN_TREE"
[ "$PASS_MODE" = pin ] && [ "$REC_PIN_TREE" != "none" ] && \
    say "harness: deployed=$REC_PIN_TREE (the tree the pin names — this is what the box RUNS; the checkout above is not moved by a pin advance)"

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
    REC_DETAIL="$3 — head=$REC_HEAD deployed=$REC_DEPLOYED ref=$REC_REF behind=$REC_BEHIND ahead=$REC_AHEAD dirty=$REC_DIRTY pin=$REC_PIN pin_tree=$REC_PIN_TREE${PRESERVED_DIR:+ preserved=$PRESERVED_DIR}"
    write_record "$1" "$2" || exit 23
    if [ "$1" = 1 ]; then say "$REC_DETAIL"; else err "$REC_DETAIL"; fi
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
if [ "$FETCH_STATE" = failed ]; then
    REC_ACTION=cannot-verify-fetch
    finish 0 23 "REFUSED cannot-verify: git fetch from origin failed in $REPO, so 'current' would mean 'current against the ref as of the LAST successful fetch' — the comparison this pass exists to make is not fresh. Nothing was touched."
fi

# ── PREDICATE 1: AHEAD / DIVERGED — refuse before anything is touched ──────────────────────────
# ⛔ THIS IS THE c4 DEFECT. Its local commits existed in no other place; an advance would have
# dropped them and NOTHING in the fleet would have said so. The count is in the message because
# "ahead" alone does not tell an operator whether it is one commit worth keeping or twenty.
if [ "$RELATION" = ahead ]; then
    REC_ACTION=refused-ahead
    finish 0 21 "REFUSED ahead: $REPO carries $AHEAD commit(s) that are not on $REF — advancing would drop them. Recover or land them first (git log $REF..HEAD), then re-run. Nothing was touched."
fi
if [ "$RELATION" = diverged ]; then
    REC_ACTION=refused-diverged
    finish 0 22 "REFUSED diverged: HEAD is neither an ancestor nor a descendant of $REF — a rebase or cherry-pick is an operator decision, not a scheduled one. Nothing was touched."
fi

# ── PREDICATE 2: DIRTY — preserve BY NAME, then move (sync path only) ──────────────────────────
# MEASURED (the Mac, 2026-10-23): ONE modified tracked file made `sync.sh` abort for 91 commits and
# nothing reported it. `sync.sh` aborting is CORRECT — it must not discard work. What was missing is a
# path that SAVES the work and then completes the advance, and a record that says so.
preserve_dirty() { # <dest-dir>; prints what it saved; exit 1 if it cannot save everything
    local dest="$1" p n=0
    mkdir -p "$dest" || { err "cannot create the preservation dir $dest"; return 1; }
    # The byte-exact record of every tracked change (staged and unstaged), then one line per path.
    if ! git -C "$REPO" diff --binary HEAD >"$dest/changes.patch" 2>/dev/null; then
        err "cannot write $dest/changes.patch — refusing to touch a tree whose changes are not saved"
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
        say "preserved: $p -> $dest/changes.patch"
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
        say "preserved: $p -> $dest/untracked/$p"
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
    local n_restored=0 n_skipped=0 tmp mode sha blob _info _type _rest
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
            if printf '%s\0' "$(list_rename_dests)" | tr '\0' '\n' | grep -qxF -- "$p"; then
                mkdir -p "$dest/untracked/$(dirname "$p")" 2>/dev/null || true
                cp -a "$REPO/$p" "$dest/untracked/$p" 2>/dev/null || true
                rm -f "$REPO/$p" 2>/dev/null || true
            fi
            git -C "$REPO" update-index --force-remove -- "$p" >/dev/null 2>&1 || true
            n_skipped=$((n_skipped + 1))
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
    say "restored: $n_restored tracked path(s) brought back to HEAD (mode and content)$( [ "$n_skipped" -gt 0 ] && printf ', %s skipped (not in HEAD or a gitlink)' "$n_skipped"); the hand edits above exist only in the preserved copies"
    say "preserved: $n path(s) saved under $dest (names in $dest/MANIFEST)"
    return 0
}

if [ "$PASS_MODE" = sync ] && [ "$RELATION" = behind ] && [ "$DIRTY_N" != "unknown" ] && [ "$DIRTY_N" -gt 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        say "dry-run: would preserve $DIRTY_N dirty path(s) by name and then fast-forward"
    else
        PRESERVED_DIR="$STATE_DIR/harness-apply-preserved/$(date -u +%Y%m%dT%H%M%SZ)"
        preserve_dirty "$PRESERVED_DIR" || {
            REC_ACTION=refused-dirty
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
    say "dry-run: relation=$RELATION behind=$BEHIND ahead=$AHEAD dirty=$DIRTY_N mode=$PASS_MODE — nothing was changed and no pass record was written"
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
        say "advance: the pin already names $REF ($(short "$REF_SHA")) — no-op"
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
        OUT="$(bash "$MATERIALISER" apply --force --pin-only 2>&1)"; ACT_RC=$?
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
            say "pin: MENDED (was absent) -> $(short "$TREE_SHA")"
            REC_ACTION=mended
        elif [ "$(short "$TREE_SHA")" != "$REC_PIN" ]; then
            OLD_PIN="$REC_PIN"
            printf '%s\n' "$TREE_SHA" >"$PIN_SHA_FILE.tmp-$$" 2>/dev/null \
                && mv -f "$PIN_SHA_FILE.tmp-$$" "$PIN_SHA_FILE" 2>/dev/null \
                || { REC_ACTION=pin-unwritable; finish 0 23 "the pin ($OLD_PIN) disagrees with the tree ($(short "$TREE_SHA")) and $PIN_SHA_FILE could not be rewritten — the pin still lies"; }
            say "pin: REPAIRED $OLD_PIN -> $(short "$TREE_SHA") (the pin now names the tree this box actually runs)"
            REC_ACTION=pin-repaired
        fi
    else
        # A pin record that names a tree which is not there, or a box with no PATH record at all:
        # reported, never invented. The sha record may legitimately be the only one on a box whose
        # controller was never started from a pin.
        say "pin: no tree at $PIN_PATH_FILE — the sha record ${REC_PIN} cannot be checked against a checkout"
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
                    say "pin: MENDED (was absent) -> $(short "$HEAD_SHA") (no pin tree; the checkout is the deployment)"
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
