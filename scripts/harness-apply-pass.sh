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
#              keeps the scheduler out of $O (seeding is `start`'s job), and `--force` is kept WITH it
#              for the reason `--pin-only` alone used to be refused: the supervisor's running-controller
#              guard fired on the pin-only path too, so this pass recorded rc=23 and the unit went RED
#              every ten minutes on a healthy cell while the pin never moved (measured in review).
#              ⛔ THAT GUARD NO LONGER COVERS THIS PATH (agent-infra#2738 — `apply --pin-only` is exempt,
#              because it never touches $O), so `--force` here is belt-and-braces rather than the price
#              of admission: a pass that must never redden on a healthy cell should not depend on the
#              guard's exact scope. Neither flag relaxes anything else.
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
#   27  REFUSED split-home  this pass would write the pin under a home its own controller does not
#                     read — the unit's `$HOME` disagrees with the derivation, so the box is
#                     mid-migration and BOTH homes are still live. Nothing was touched. 26 is
#                     already `REFUSED blocked` in `harness-refresh.sh`; a different fact may not
#                     share a code (the ONE VOCABULARY rule above)
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
#   CELL_HOME             the cell's home (default: DERIVED by scripts/lib/cell-home.sh — the box's
#                         durable home, never the legacy /tmp/cell-home; $HOME only when the resolver
#                         is absent, e.g. a `bash -s` piped start with no sibling file)
#   O                     the orchestrator state dir (default $CELL_HOME/orchestrator)
#   HARNESS_MATERIALISER  the script that materialises a pin (default <repo>/scripts/cloud-cell-supervisor.sh)
#   HARNESS_APPLY_MODE    pin|sync — force one path (default: pin when a pin record exists, else sync
#                         when the checkout carries ./sync.sh, else pin)
#   HARNESS_APPLY_STATE_DIR  the pass record dir (default $CELL_HOME/.pi/agent/state — the ONE home, so
#                         the record lands beside the pin record the same pass writes)
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
# `set -u` the unguarded form printed "BASH_SOURCE[0]: unbound variable" on EVERY tick, left `$HERE`
# degrading to `.` (silently degrading the repo-resolution fallback to `.`), and broke `--help` through the
# launcher. ⛔ AND `:-$0` IS NOT A FIX FOR THAT, which is what a later version of this comment claimed: a
# piped start's `$0` is LITERALLY `bash`, so `dirname bash` is `.` and `$HERE` is the CURRENT WORKING
# DIRECTORY — not empty. `$HERE/lib/cell-home.sh` is then `$PWD/lib/cell-home.sh`, i.e. a piped start would
# SOURCE THE RESOLVER FROM A DIRECTORY THIS SCRIPT DOES NOT OWN (the code-execution-from-CWD shape
# `pi-bootstrap/cell-install.sh` refuses for `keys.env`). `SELF_FILE` therefore counts only when it names
# the file being executed, and the lookup below is skipped otherwise. The sibling artifact this launcher
# already runs carries the same note (scripts/disk-reaper.sh).
# ⛔ `CDPATH=` ON EVERY CAPTURED `cd` (review round 5). bash's `cd` PRINTS the resolved directory when it
# resolves through an inherited CDPATH, so the captured value holds TWO lines — and every containment
# test below then compares against a string containing a newline. Measured consequence (reproduced):
# with a RELATIVE `HARNESS_APPLY_FARM_CHECKER` and a CDPATH that resolves its directory,
# `$FARM_CHECKER_REAL` could never carry the `$FARM_DEST_REAL/` prefix, so a FARM-LOCAL checker read as
# "outside the farm" and the farm GRADED ITSELF GREEN — the exact fail-open this leg exists to remove.
# `$HERE` is the same hazard when this file is invoked by a relative path (a two-line `$HERE` would
# defeat `$REPO` resolution and any EXACT comparison against it). ⛔ THIS SITE **IS** PINNED — `T28` —
# and the earlier note that it could not be was wrong about WHERE to look. The `case "$HERE"` farm-shape
# refusals below are SUFFIX matches, so they cannot discriminate a doubled value; the observable that
# does is the `deployed_drift=not-run` line (the `log_line` that spells it), which QUOTES `$HERE` — a two-line value pushes a
# newline into the text that must follow it on the same line. So T28 invokes this file by a RELATIVE
# path from a cwd carrying `CDPATH` (the pair that makes `cd <dirname>` print) and asserts the boundary
# after the quoted path: removing this `CDPATH=` reds that row and nothing else. Note the directory must
# NOT begin with `.` — `cd` ignores CDPATH for a `.`-prefixed argument, so no `.pi/agent/scripts`-shaped
# dirname can reach the hazard, which is why a farm-shaped fixture pins nothing. (`$FARM_DEST_REAL`/
# `$HERE_REAL` carry the prefix too, but both `cd` targets are already absolute — `$FARM_DEST` is refused
# when relative and `$HERE` comes from `pwd` — so those two are inert defence.) ⛔ THE SYMLINK HOP
# (`*)` in the loop below) IS THE SIXTH SITE AND IT IS PINNED TOO — `T24x2`, one site over from `T24x`:
# a RELATIVE LINK checker inside the farm, run from a cwd carrying a CDPATH that resolves its directory,
# resolved to a TWO-LINE `$FARM_CHECKER_T`, was read as OUTSIDE the farm, and GRADED ITSELF `farm: ok` at
# rc=0. MEASURED at this head: dropping this `CDPATH=` reds TWO rows — `T24x2`'s containment row and its
# "not the missing-instrument sentence" row — and leaves the rc and `farm: ok` rows green, because the
# `[ ! -f "$FARM_CHECKER_T" ]` refusal added in review round 20 stops the two-line path before it can be
# executed, so the wrong ANSWER replaces the wrong ACTION. Both red rows pin the prefix; the other two are
# not pins for it and must not be counted as such.
HERE="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
SELF_FILE="${BASH_SOURCE[0]:-}"
[ -f "$SELF_FILE" ] || SELF_FILE=""

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

# ── THE ONE HOME (agent-infra#3453) — DERIVED, not a bare $HOME spelled at the call site ────────
# This pass hands CELL_HOME to the materialiser (`cloud-cell-supervisor.sh apply`), which resolves it
# with `scripts/lib/cell-home.sh`; an un-derived `$HOME` here (e.g. `cmux vm exec`'s HOME=/home/ubuntu,
# a directory that does not exist on the image) would pin and record under one home while the
# supervisor resolves another — the two-home split #3453 removes, on the pass that advances the
# harness. The rule and the ONLY literal live in `scripts/lib/cell-home.sh`; a copy without it (a
# `bash -s` start has no file, so `$SELF_FILE` is empty and the lookup is SKIPPED) falls back to $HOME
# exactly as before. ⛔ See `lib/cell-home.sh` §CONSUMERS for why `$HERE` is not used in a piped start.
# ⛔ ONE HOME, OR NO PASS (review F1, blocking). Deriving is only half the rule: the CONSUMER that
# reads what this pass writes is the controller, and the controller resolves its own home from ITS
# unit. Measured on the population this change exists to migrate — a box whose units still name
# /tmp/cell-home — the two disagree:
#
#   harness-apply unit   Environment=HOME=/tmp/cell-home, no CELL_HOME  -> derive -> /home/cmux
#   controller unit      Environment=HOME=/tmp/cell-home CELL_HOME=... -> /tmp/cell-home
#
# so one tick wrote $CELL_HOME/.pi/agent/state/HARNESS-PIN, $CELL_HOME/.harness-path and the pin root
# under /home/cmux while the controller read them from /tmp/cell-home — and then re-read its OWN record
# (`read_pin`) and exited 10, a GREEN unit over a pin the controller never sees. That is the same
# two-surface disagreement #3453 removes, re-created on the pass/controller boundary. systemd's `%h`
# does NOT close it (it expands to the passwd record = the same /home/cmux the derivation already
# answers while the controller's unit still pins the legacy value), so the pass REFUSES instead: a
# human-visible RED is the only surface that is not a log nobody reads, and `cell-home-migrate.sh` is
# the named remedy. ⛔ An EXPLICIT CELL_HOME is an operator's answer and is never second-guessed
# (`cell_home_resolve` step 1) — the refusal exists for the box where nothing said what the home is.
# ⛔ THE HOME THAT MATTERS IS THE **CONTROLLER'S** (review F1, verified). Comparing this pass's own
# `$HOME` with the derivation closes only ONE of the two shapes. When the pass's unit was repointed but
# the CONTROLLER's was not — exactly what a `cell-home-migrate.sh --apply` leaves behind when rule 4
# refuses a single unit — the pass sees `HOME == derivation`, refuses nothing, and writes a green pin set
# (exit 10, in `SuccessExitStatus`) under a home the controller never reads. So the controller's own
# pinned `CELL_HOME` is read too, and a disagreement is the same split.
# ⛔ WHICH UNITS ARE "THE CONTROLLER" IS NAMED, NOT DISCOVERED: a glob over every unit in the directory
# would call this pass's own sibling units controllers. Drop-ins are read because that is the documented
# mechanism by which a box pins the home (`…/cell-self-pin.service.d/*.conf`), lexical order, last wins.
# A value this file cannot resolve (`{{CELL_HOME}}` unrendered, a `%h` specifier) is CANNOT MEASURE and
# is skipped — never compared, because a string comparison against a placeholder is not a reading.
# No controller unit at all (a Mac) means no comparison: this guard never invents a home.
#
# ⛔ TWO FAIL-OPEN DOORS THE FIRST CUT LEFT OPEN (review F-B/F-C, both verified). A guard that silently
# measures NOTHING is worse than no guard, because the readings then print `split_home=none` and every
# reader infers agreement.
#   (F-B) `Environment=` IS A LIST, NOT A SCALAR. systemd.exec(5): each line is unquoted and "becomes a
#         list of variable assignments" — `Environment="VAR1=word1 word2" VAR2=word3`. A pattern
#         anchored at `Environment=CELL_HOME=` matches neither the QUOTED nor the MULTI-ASSIGNMENT form,
#         and the multi-assignment form is literally the row this file's own comment documents. The line
#         is now split into tokens first, so both parse.
#   (F-C) THE UNIT NAME AND ITS DIRECTORIES ARE NOT CONSTANTS. `install-controller-service.sh` renders
#         and validates `CONTROLLER_UNIT=<bare name>` and honours `CONTROLLER_SYSTEM_UNIT_DIR`, and
#         systemd.unit(5) applies drop-ins from `/etc`, `/run` AND `/usr/lib` "in lexicographic order,
#         regardless of which of the directories they reside in", the higher-precedence directory winning
#         a name collision. All of that is honoured below.
# `split_env_tokens <line>` — one token per line, honouring ONE level of `'…'` / `"…"` quoting.
# ⛔ THIS EXISTS BECAUSE `tr -d '"'` IS NOT "UNQUOTING" (review round-3 F1, verified). systemd.syntax(7):
# "Whitespace immediately before or after the `=` is ignored", and "double quotes (…) AND SINGLE QUOTES
# (…) may be used to wrap a whole item … Quotes themselves are removed". Measured failures of the first
# cut: `Environment='CELL_HOME=/sq'` measured NOTHING; `Environment = CELL_HOME=/spaced` (a space before
# the `=`) measured NOTHING; and a quoted value containing a space was compared as a TRUNCATED PREFIX —
# `"CELL_HOME=/home/x with-suffix"` read as `/home/x`, i.e. it compared EQUAL to a converged box's
# derived home and the guard reported agreement. A split that respects quotes fixes all three, and
# stripping only the WRAPPING pair (not every quote character) keeps a value like `/Users/o'brien` intact.
split_env_tokens() {
    local str="$1" out="" cur="" q="" i=0 n=0 ch
    n=${#str}
    while [ "$i" -lt "$n" ]; do
        ch="${str:$i:1}"; i=$((i + 1))
        if [ -n "$q" ]; then
            if [ "$ch" = "$q" ]; then q="" ; else cur="$cur$ch"; fi
        else
            case "$ch" in
                "'"|'"') q="$ch" ;;
                ' '|"	") [ -n "$cur" ] && { out="$out$cur"$'\n'; cur=""; } ;;
                *) cur="$cur$ch" ;;
            esac
        fi
    done
    [ -n "$q" ] && return 0     # an UNTERMINATED quote is not a reading — say nothing, never half a value
    [ -n "$cur" ] && out="$out$cur"$'\n'
    printf '%s' "$out"
}

# logical_lines <file> — the file as systemd READS it: one LOGICAL line per output line.
# ⛔ A BACKSLASH-CONTINUED DIRECTIVE IS ONE DIRECTIVE, AND A PHYSICAL-LINE READER CANNOT SEE IT
# (review F2, measured on this head). systemd.syntax(7): *"Lines ending in a backslash are concatenated
# with the following line while reading and the backslash is replaced by a space character"*, and *"When a
# comment line or lines follow a line ending with a backslash, the comment block is ignored, so the
# continued line is concatenated with whatever follows the comment block."* So
#     Environment=HOME=/home/x \
#     CELL_HOME=/tmp/other-home
# is ONE directive in which the SECOND assignment wins (`Environment=` is last-wins), while the reader
# below — reading physical lines — never saw a `CELL_HOME` at all. `[]` is not "no CELL_HOME": it became
# `split_home=none` in the readings, and every reader infers agreement from that. On the population this
# guard targets (T27's "pass agrees, controller disagrees" shape) the pass's own unit was repointed, so
# the HOME leg is silent; the controller's drop-in pins `CELL_HOME` on a continuation line, so
# `split_home_controller` measured NOTHING either; no refusal, so the tick wrote HARNESS-PIN,
# `.harness-path` and the pin root under the derivation while the controller re-read ITS OWN record and
# exited 10 — in `SuccessExitStatus`, a green unit over a pin the controller never sees.
# It is the fourth spelling of one hole this file has closed three times (quoted/multi-assignment → F-B,
# whitespace around `=` → F-G), and this tree's two other readers of the same question already agree on
# the logical line: `cell-home-migrate.sh`'s `unit_scan` joins it, and `scripts/cell-self-pin.sh`
# refuses the spelling by name. Joining is the fix here because a drop-in an OPERATOR wrote is not a
# rendered unit — refusing it would leave the guard blind to the home that operator really pinned.
# ⛔ A COMMENT OR EMPTY LINE IS SKIPPED AND NEITHER CLOSES A CONTINUATION (the same man page, above).
# ⛔ THE DIRECTIVE NAME COMES FROM THE LOGICAL LINE, NOT FROM A PHYSICAL ONE: `ExecStart=/bin/foo \` +
# `Environment=CELL_HOME=/x` is ONE `ExecStart=` whose VALUE contains that text, which systemd does not
# parse as an `Environment=` — so joining happens BEFORE the name is matched, never after.
logical_lines() { # <file>
    local line acc="" stripped
    [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="$line"
        while :; do case "$stripped" in [[:space:]]*) stripped="${stripped#?}" ;; *) break ;; esac; done
        case "$stripped" in ''|'#'*|';'*) continue ;; esac
        line="$stripped"
        # trailing blanks are not part of the continuation marker
        while :; do case "$line" in *[[:space:]]) line="${line%?}" ;; *) break ;; esac; done
        case "$line" in
            *\\ )
                acc="$acc${line%?} "   # the backslash is replaced by a SPACE (systemd.syntax(7))
                continue ;;
        esac
        printf '%s\n' "$acc$line"
        acc=""
    done <"$1" 2>/dev/null
    [ -n "$acc" ] && printf '%s\n' "$acc"
    return 0
}

environment_cell_home() { # <file> — the CELL_HOME its Environment= lines set (last wins), or nothing
    local line body tok out=""
    # ⛔ THE LINES ARE LOGICAL (review F2): a backslash continuation is part of THIS directive, so the
    # CELL_HOME systemd would apply is the one measured here.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # `Environment` followed by optional blanks, then `=` — and NOT `EnvironmentFile=`/`UnsetEnvironment=`.
        case "$line" in Environment*) ;; *) continue ;; esac
        body="${line#Environment}"
        while :; do case "$body" in [[:space:]]*) body="${body#?}" ;; *) break ;; esac; done
        case "$body" in =*) body="${body#=}" ;; *) continue ;; esac
        while :; do case "$body" in [[:space:]]*) body="${body#?}" ;; *) break ;; esac; done
        [ -n "$body" ] || continue
        tok="$(split_env_tokens "$body" | sed -n 's/^CELL_HOME=//p' | tail -1)"
        [ -n "$tok" ] && out="$tok"
    done <<EOF
$(logical_lines "$1")
EOF
    case "$out" in
        '') return 0 ;;   # no CELL_HOME= on this unit: a reading, and it is "nothing pinned"
        # ⛔ AN UNRENDERED VALUE IS NOT A READING, AND IT IS NOT AGREEMENT EITHER (review cycle-9 #6).
        # `{{CELL_HOME}}` (a template the installer never expanded) and `%h` (a systemd specifier) are both
        # values this function cannot turn into a home. It used to answer '' for them — indistinguishable
        # from "this unit pins no home", so the split test read `split_home=none` and every reader took it
        # as measured agreement. Exit 3 is a THIRD ANSWER, carried up to `SPLIT_HOME_STATE=unmeasurable`:
        # the split could not be measured, so nothing may claim it was.
        *'{'*|*'%'*) return 3 ;;
    esac
    printf '%s\n' "$out"
}

dropin_cell_home() { # <unit-path> — the last CELL_HOME its drop-ins set, systemd's precedence order
    local unit="$1" base d g name out="" v pre stem typ _rc unrend=0
    base="${unit##*/}"
    local -a dirs=() names=() pres=()
    # ⛔ DROP-INS ARE NOT "THE DIRECTORY THE UNIT FILE WAS FOUND IN" (review round-3 F3, verified).
    # systemd.unit(5): drop-in files live in /etc, /run, /usr/local/lib and /usr/lib "regardless of where
    # the unit file itself is located" — so an /etc drop-in for a /usr/lib-installed unit IS applied, and
    # a `${unit}.d`-only reader misses it. Measured in a container: a unit under /usr/lib with its drop-in
    # under /etc/systemd/system/<name>.service.d read NOTHING.
    # ⛔ AND A UNIT NAME CONTAINING `-` ALSO GETS DASH-TRUNCATED PREFIX DIRECTORIES — with the TYPE
    # SUFFIX KEPT AND EVERY DASH BOUNDARY A CANDIDATE (review F3, both reviewers). `systemd.unit(5)`:
    # for `foo-bar-baz.service` the drop-in dirs are `foo-bar-baz.service.d`, `foo-bar-.service.d` and
    # `foo-.service.d`. This used to build `<prefix>-.d` (`eldato-.d`), which systemd NEVER reads, and
    # only ever built the FIRST truncation — so a `CELL_HOME=` pinned through a truncated drop-in
    # measured nothing, `split_home` came back `none`, and a reading that did not happen read as
    # agreement (the F-B/F-C class this file already closed twice).
    pres=("${base}.d")
    case "$base" in
        *-*)
            # ⛔ THE TYPE SUFFIX IS EVERYTHING AFTER THE **LAST** DOT, NOT THE FIRST (review P2, measured).
            # `${base%%.*}`/`${base#*.}` split on the FIRST dot, and a dot is legal in a unit's name prefix
            # (`systemd.unit(5)`), so `foo.bar-baz.service` produced `stem=foo` / `typ=bar-baz.service` —
            # `[ "$typ" = "$stem" ]` did not fire, the loop found no `-` in `foo`, and the truncated dir
            # `foo.bar-.service.d` was NEVER built (that name has ONE dash, so it has exactly one truncation).
            # A `CELL_HOME=` pinned through it then measured nothing, `split_home` read `none`, and a reading
            # that did not happen read as agreement — the exact class this block exists to close, one
            # character of the name away.
            stem="${base%.*}"; typ="${base##*.}"
            [ "$typ" = "$stem" ] && typ=""          # no type suffix: nothing to keep
            while :; do
                case "$stem" in *-*) stem="${stem%-*}"; pres+=("${stem}-${typ:+.$typ}.d") ;; *) break ;; esac
            done ;;
    esac
    # ⛔ `"${unit}.d"` FIRST: a unit found at an ARBITRARY path (the `HARNESS_APPLY_CONTROLLER_UNIT`
    # seam, or a `CONTROLLER_SYSTEM_UNIT_DIR` override) keeps its own drop-in directory. Dropping it in
    # favour of the standard dirs alone made the reader blind to the seam's own `.d` — measured by the
    # T27 drop-in arm going red — which is the same class of blindness this function exists to remove.
    [ -d "${unit}.d" ] && dirs+=("${unit}.d")
    for pre in "${pres[@]}"; do
        for d in "/etc/systemd/system/$pre" "/run/systemd/system/$pre" \
                 "/usr/local/lib/systemd/system/$pre" "/usr/lib/systemd/system/$pre" \
                 ${HOME:+"$HOME/.config/systemd/user/$pre"} "/etc/systemd/user/$pre" \
                 "/run/systemd/user/$pre" "/usr/local/lib/systemd/user/$pre" \
                 "/usr/lib/systemd/user/$pre"; do
            [ -d "$d" ] && dirs+=("$d")
        done
    done
    [ "${#dirs[@]}" -eq 0 ] && return 0
    # ⛔ LEXICOGRAPHIC BY FILE NAME ACROSS ALL THE DIRECTORIES, with the first (highest-precedence)
    # directory winning a NAME collision — not "directory by directory", which would let a /usr/lib
    # drop-in named `z.conf` override an /etc one named `a.conf`, reversing systemd's own order.
    names="$(for d in "${dirs[@]}"; do for g in "$d"/*.conf; do [ -r "$g" ] && printf '%s\n' "${g##*/}"; done; done | LC_ALL=C sort -u)"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for d in "${dirs[@]}"; do
            [ -r "$d/$name" ] || continue
            v="$(environment_cell_home "$d/$name")"; _rc=$?
            # ⛔ AN UNMEASURABLE VALUE MUST DISPLACE A MEASURED ONE IT OVERRIDES (review cycle-10 #1,
            # reproduced). This loop walks NAMES lexicographically and DIRECTORIES by precedence, so the
            # LAST assignment here is the value systemd would apply. The first cut only LATCHED the
            # unmeasurable flag, so a higher-precedence drop-in pinning `{{CELL_HOME}}` over a lower one
            # pinning a real home left `out` holding the LOWER value: the reading printed agreement for a
            # value the box does not run. The effective value is what must be reported, so an unmeasurable
            # answer CLEARS `out` here and a measured one clears the flag — last mention wins either way.
            if [ "$_rc" -eq 3 ]; then out=""; unrend=1
            elif [ -n "$v" ]; then out="$v"; unrend=0; fi
            break   # the highest-precedence directory owns this NAME
        done
    done <<EOF
$names
EOF
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    # a drop-in that pins an unrenderable CELL_HOME: the drop-in was READ and could not be measured
    [ "${unrend:-0}" -eq 1 ] && return 3
    return 0
}

split_home_controller() { # prints the controller's pinned CELL_HOME, or nothing when it cannot be measured
    local f v out="" name _rc unrend=0
    local -a units=()
    if [ -n "${HARNESS_APPLY_CONTROLLER_UNIT:-}" ]; then
        units=("$HARNESS_APPLY_CONTROLLER_UNIT")
    else
        # ⛔ THE NAME IS NOT ASSUMED: a renamed controller is a supported install.
        name="${CONTROLLER_UNIT:-eldato-orchestrator}"
        case "$name" in *.service) : ;; *) name="$name.service" ;; esac
        # ⛔ `/usr/local/lib/systemd/system` IS ON SYSTEMD'S LOAD PATH TOO ("System units installed by
        # the administrator", systemd.unit(5)) and it sits between /run and /usr/lib (review round-3 F3).
        for f in "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" /etc/systemd/system \
                 /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system \
                 ${HOME:+"$HOME/.config/systemd/user"} /etc/systemd/user \
                 /run/systemd/user /usr/local/lib/systemd/user /usr/lib/systemd/user; do
            units+=("$f/$name")
        done
    fi
    for f in "${units[@]}"; do
        [ -r "$f" ] || continue
        # ⛔ SAME PRECEDENCE RULE AS `dropin_cell_home`: the LAST measurable-or-not answer wins, and an
        # unmeasurable drop-in OVERRIDES the unit's measured value because systemd applies the drop-in
        # (review cycle-10 #1 — the flag alone left `out` holding the value the box does not run).
        v="$(environment_cell_home "$f")"; _rc=$?
        if [ "$_rc" -eq 3 ]; then out=""; unrend=1
        elif [ -n "$v" ]; then out="$v"; unrend=0; fi
        v="$(dropin_cell_home "$f")"; _rc=$?
        if [ "$_rc" -eq 3 ]; then out=""; unrend=1
        elif [ -n "$v" ]; then out="$v"; unrend=0; fi
        break   # the first READABLE controller unit wins: a box has one controller
    done
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    # ⛔ READ, BUT NOT MEASURABLE (review cycle-9 #6). The unit exists and was read; its CELL_HOME is a
    # value this function refuses to interpret. Answering '' made that a `none` — the reading-did-not-
    # happen class — so it answers exit 3 instead and the caller records `unmeasurable`.
    [ "${unrend:-0}" -eq 1 ] && return 3
    return 0
}
CELL_HOME_LIB=""
if [ -n "$SELF_FILE" ]; then
  for _cand in "$HERE/lib/cell-home.sh" "$HERE/../lib/cell-home.sh"; do
    [ -r "$_cand" ] && { CELL_HOME_LIB="$_cand"; break; }
  done
fi
_CELL_HOME_EXPLICIT="${CELL_HOME:-}"
SPLIT_HOME=""
SPLIT_HOME_WHY=""
SPLIT_HOME_SRC=""
SPLIT_HOME_STATE=""
SPLIT_HOME_STATE_WHY=""
if [ -n "$CELL_HOME_LIB" ]; then
  . "$CELL_HOME_LIB"
  CELL_HOME="$(cell_home_resolve)"
  # ⛔ RECORDED HERE, ACTED ON ONLY WHERE SOMETHING WOULD BE WRITTEN (review F3). The first cut refused
  # at this line, which also reddened `--print-status` (a RECORD read) and `--dry-run` (a PREVIEW) —
  # contradicting this file's own two recorded rules: a refusal that exits before `write_record` leaves
  # `--print-status`/fleet-health reading the PREVIOUS tick as if it were this one, and `--dry-run`
  # "must not red a box (it changes nothing, including the exit contract)". The split is therefore a
  # READING on every verb, and a REFUSAL only on the acting one.
  #
  # ⛔ A `HOME` THAT DISAGREES IS A UNIT'S CLAIM ONLY WHEN A UNIT IS THE ONE CLAIMING IT (review F2). The
  # premise of `SPLIT_HOME_WHY` — "the unit that starts this pass exports HOME=…" — holds only when a
  # unit DID start this pass. An operator running it by hand in a `cmux vm exec` shell has
  # `HOME=/home/ubuntu` and no unit in the picture, while the derived home is the passwd home `/home/cmux`
  # — i.e. the home the controller reads, so the pin this run would write is the CORRECT one, yet the run
  # refused (exit 27) with a diagnostic asserting a unit exported a value it never did. That is a false
  # block AND a false statement, on the invocation shape this file's own header calls ordinary.
  #
  # THE MARKER IS THE UNIT'S OWN, NOT A GUESS: systemd sets `INVOCATION_ID` (and `JOURNAL_STREAM`) per
  # activation for every service it starts, so their presence is what distinguishes "a unit exported
  # this HOME" from "this shell's HOME". ⛔ IT IS A ONE-WAY MARKER, AND THE WEAKER DIRECTION IS THE
  # SAFE ONE HERE: it can be INHERITED by a manual run inside a unit's shell (which then still refuses,
  # as before), but a unit invocation does not omit it — so this cannot turn a real unit split into a
  # warning. The leg that can genuinely MIS-PLACE a pin is the controller's, below, and that one refuses
  # unconditionally on every invocation shape.
  _unit_invoked=0
  if [ -n "${INVOCATION_ID:-}" ] || [ -n "${JOURNAL_STREAM:-}" ]; then _unit_invoked=1; fi
  # ⛔ THE COMPARISON NORMALISES THE TRAILING SLASH (review P2, measured). It compared RAW strings, so a
  # unit rendering `Environment=HOME=/home/cmux/` against the derived `/home/cmux` — one home, one
  # character apart — exited 27 with "two live homes on one box". The installer refuses whitespace and
  # backslashes in that value, NOT a trailing slash, and `/home/cmux/` is exactly the home this guard
  # exists to protect; the sibling tool now normalises its own `HOME_DURABLE` once at startup
  # (`cell-home-migrate.sh`). ⛔ WHAT PROTECTS THE SIBLING IS ITS `[ -n "${HOME:-}" ] &&` SHORT-CIRCUIT,
  # NOT THE SPELLING (review cycle-5 #4 + cycle-6 #3): its line is
  # `[ -n "${HOME:-}" ] && [ "${HOME%/}" != "$HOME_DURABLE" ] && printf …`, so the bare `${HOME%/}` is
  # only ever evaluated when `HOME` is non-empty. Copying that expression WITHOUT the guard would abort
  # under `set -u`. What is borrowed here is the RULE, not the expression: `${HOME:-}` above, then a
  # separate strip, then `/` preserved as `/`.
  # ⛔ `${HOME:-}`, NOT `${HOME}` (review N1, measured). This file runs under `set -uo pipefail` (see the
  # `set` at the top), and these are STANDALONE assignments: a bare `${HOME%/}` on an unset `HOME` is a
  # fatal expansion that ABORTS every verb before `write_record` — the installer then reports "the pass
  # record is not healthy" and the
  # tick leaves no record, i.e. exactly the silence this pass's doctrine refuses. The pre-change one-liner
  # was safe only because `[ -n "${HOME:-}" ]` short-circuited BEFORE it touched `HOME`; the sibling
  # spelling quoted above is safe for the same reason, which the normalisation dropped. Reachable by any
  # HOME-less launcher (`env -i`, a minimal container/cron shape) that carries a `lib/cell-home.sh`
  # sibling. `CELL_HOME` is always set by this point (the resolver prints exactly one line), and `:-` on it
  # too keeps the two assignments identical in shape.
  _home_n="${HOME:-}"; _home_n="${_home_n%/}"; [ -n "$_home_n" ] || _home_n=/
  _cell_n="${CELL_HOME:-}"; _cell_n="${_cell_n%/}"; [ -n "$_cell_n" ] || _cell_n=/
  if [ -z "$_CELL_HOME_EXPLICIT" ] && [ -n "${HOME:-}" ] && [ "$_home_n" != "$_cell_n" ]; then
    if [ "$_unit_invoked" = 1 ]; then
      SPLIT_HOME="$HOME"
      SPLIT_HOME_SRC="unit"
      SPLIT_HOME_WHY="the unit that starts this pass exports HOME=$HOME"
    else
      # A READING, NEVER A REFUSAL — and worded as what it actually measured, so the operator is not told
      # a unit said something it did not. Stderr, because it must not disturb a `--dry-run`/`--print-status`
      # exit contract, and because the unit captures stderr into the tick's log.
      printf '%s: note: the HOME of this process (%s) differs from the derived CELL_HOME (%s), and no unit started this run (no INVOCATION_ID/JOURNAL_STREAM) — a HOME set by a shell is not a claim made by a unit, so the pin goes under the DERIVED home (agent-infra#3453)\n' "${0##*/}" "$HOME" "$CELL_HOME" >&2
    fi
  fi
  unset _unit_invoked
  # …and the controller's own home, which is the one a pin must land under. ⛔ RESOLVED EVEN WHEN THE
  # `HOME` READING ABOVE ALREADY FIRED (review F2): the two are independent claims, and the controller's
  # is the authoritative one — short-circuiting on `HOME` is what made a manual run's harmless reading
  # silence (or, before, pre-empt) the leg that can really mis-place a pin.
  if [ -z "$SPLIT_HOME" ]; then
    _ctrl_home="$(split_home_controller)"; _ctrl_rc=$?
    # ⛔ THE SAME THREE-STEP NORMALISATION AS `_home_n`, NOT A BARE `%/` (review cycle-4 #6, measured):
    # `%/` alone turns a controller pinning `/` into the EMPTY string, which was then compared against
    # `_cell_n=/` — so the one configuration where the two sides AGREE (`CELL_HOME=/` explicit and a
    # controller pinning `/`) exited 27 claiming "two live homes on one box", a false block whose message
    # is false. The empty-to-`/` recovery is what keeps the two legs symmetric.
    _ctrl_n="${_ctrl_home:-}"; _ctrl_n="${_ctrl_n%/}"; [ -n "$_ctrl_n" ] || _ctrl_n=/
    if [ -n "$_ctrl_home" ] && [ "$_ctrl_n" != "$_cell_n" ]; then
      SPLIT_HOME="$_ctrl_home"
      SPLIT_HOME_SRC="controller"
      SPLIT_HOME_WHY="the controller's unit pins CELL_HOME=$_ctrl_home"
    fi
    # ⛔ A READABLE UNIT WITH AN UNREADABLE VALUE IS A THIRD STATE, NOT AGREEMENT (review cycle-9 #6).
    # `environment_cell_home` answers exit 3 for a CELL_HOME it cannot turn into a home (`{{CELL_HOME}}`
    # from an unrendered template, `%h` a systemd specifier). Without this arm `_ctrl_home` was empty, the
    # split test concluded `none`, and every reader took "I could not read the controller" as "the
    # controller agrees" — which is the same class the `unmeasurable` state was added for, reached by a
    # second route. The reason is carried so the reading can say WHICH route it came by.
    if [ "$_ctrl_rc" -eq 3 ] && [ -z "$SPLIT_HOME" ]; then
      SPLIT_HOME_STATE="unmeasurable"
      SPLIT_HOME_STATE_WHY="the controller's unit was read but its CELL_HOME is not a value this box can interpret (an unrendered template, or a systemd specifier)"
    fi
    unset _ctrl_home _ctrl_n _ctrl_rc
  fi
  unset _home_n _cell_n
else
  # ⛔ NO RESOLVER IS A THIRD STATE, NOT "NO SPLIT" (review P2). Without `lib/cell-home.sh` neither split
  # leg runs, so `SPLIT_HOME` stays empty — and the acting path's reading line
  # (`harness: … split_home=…`, the `log_line` that spells the whole reading) then reads as a MEASUREMENT
  # that found agreement, which is the reading this file's own notes call worse than no guard. ⛔ IT IS A
  # LOG FIELD, NOT A RECORD FIELD (review cycle-5 #3): `write_record` never writes `split_home`, so a
  # reader chasing this justification into the record file would find nothing there and conclude the
  # reading is unrecorded. The pass is the guard; every sibling consumer REFUSES (exit 78) when it cannot
  # resolve, so the guard degrading silently is the one place that must not. The verdict is spelled in the
  # reading, and the refusal on the acting verb is deliberately NOT invented (a piped `bash -s` start has
  # no sibling file at all, which this file documents as ordinary): the reading says which of the two it is.
  CELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"
  SPLIT_HOME_STATE="unmeasurable"
  SPLIT_HOME_STATE_WHY="scripts/lib/cell-home.sh was not found beside this pass, so neither this pass's HOME nor the controller's CELL_HOME could be compared"
fi
if [ -z "${SPLIT_HOME_STATE:-}" ]; then
  if [ -n "$SPLIT_HOME" ]; then SPLIT_HOME_STATE="$SPLIT_HOME"; else SPLIT_HOME_STATE="none"; fi
fi
unset _CELL_HOME_EXPLICIT
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
# ⛔ THE RECORD LIVES UNDER THE ONE HOME, NOT UNDER `$HOME` (review cycle-5 #5). The pin record three
# lines above (`HARNESS_PIN`, `.harness-path`, `harness/`) is rooted at `$CELL_HOME`; rooting the STATUS
# record at `$HOME` made the pass write its pins under the DERIVED home and its own `.status` record under
# the INVOKING shell's home — so on exactly the shapes this change is about (`cmux vm exec`, `HOME` at a
# directory that does not exist on the image) a reader looking under the cell home finds the pins and no
# record: a reading that does not happen, and it reads as "no pass yet". `$CELL_HOME` is already resolved
# above, and the installer renders `HARNESS_APPLY_STATE_DIR` explicitly, so this default is the
# manual/fallback answer and it is now the SAME home as everything else the pass writes.
# ⛔ SCOPE, STATED PLAINLY (review cycle-6 #1, corrected cycle-10 #2): this makes the pass agree with the
# installer's `--status`, with its own `--print-status`, and with the rendered unit, which exports
# `HARNESS_APPLY_STATE_DIR` on both platforms. TWO in-repo readers resolve the same file WITHOUT that
# export and therefore differ on the HAND-RUN shape only: `tools/fleet/fleet-health.py` reads the variable
# but DEFAULTS to `~` (it does not resolve `CELL_HOME`), and `scripts/orchestrator-harness/harness-roles.sh`
# resolves the apply LOG the same way (`${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply.log`).
# ⛔ "DOES NOT HONOUR THE VARIABLE" WOULD BE FALSE FOR BOTH — each honours it and defaults to `$HOME`, so
# EXPORTING THE SEAM IS A WORKING FIX for either (that is the correction: the earlier text said
# `fleet-health.py` ignores it, which would have told whoever fixes #3870 that exporting cannot help). On a
# box whose `HOME` is not the derived home a hand-run pass's record/log is visible to `--print-status` and
# to neither of those two; the SCHEDULED record agrees with all of them, because the unit exports the
# variable. That gap is agent-infra#3870 (filed, category A: an alarm surface that silently misses a
# record) and this comment must not be read as closing it.
# ⛔ AND IT REMOVES A `set -u` FATAL: the old default spelled `${HOME}` inside a `:-`, which aborts on a
# HOME-less launcher (`env -i`, a minimal cron shape) before `write_record`.
STATE_DIR="${HARNESS_APPLY_STATE_DIR:-$CELL_HOME/.pi/agent/state}"
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
# ⛔ THE FARM ROWS ARE FIELDS, NOT PROSE (tortoise#10114 arm 2, review round 9). The acceptance arm is
# "a scheduled check that NAMES EACH drifting file"; the journal excerpt below is bounded at 12 so a
# 30-row farm had 18 files that were COUNTED and never named anywhere durable. `not-graded` means NO
# USABLE GRADE was produced, and FOUR states produce it: the switch is off, there was NO FARM TO GRADE,
# a pre-flow refusal exited first, or the instrument's rc was unreadable. `action=` names only the last
# two (`farm-unknown`, or the refusal's own action): BOTH of the first two carry `action=none`, the same
# value a clean no-op carries, so `farm_rows=` cannot split them either — the journal line is what does
# (`farm: SKIPPED — HARNESS_APPLY_FARM_CHECK=0 (deliberately disarmed…)` vs `farm: SKIPPED — no farm at
# …`). Neither may ever read like a pass that graded and found nothing to name.
REC_FARM_ROWS="not-graded"; REC_FARM_NROWS="not-graded"
# ⛔ THE DRIFT ROWS ARTIFACT IS SELF-DATING AND IS NEVER DELETED BY A LATER PASS (review round 2).
# Round 1 deleted it on every pass so a stale list could not be read as current — and that delete was
# wrong three ways: it fired on the READ-ONLY verbs (`--print-status`, the readiness verb the timer
# installer itself calls, would have destroyed the list its own record names), it sat below the seam
# validations so those refusals still orphaned it, and a fixed-path delete can unlink a CONCURRENT
# pass's just-published file between its write and its record (nothing serialises them; the timer
# fires while an operator may run the pass by hand). So the artifact is WRITTEN WITH ITS OWN HEADER
# (UTC, ref, dest, n) and left alone: a reader can always date it, and `farm_rows=` is the currency
# indicator — `none`/`not-graded` means the list on disk is NOT today's answer.
# ⛔ AND ONLY THIS PASS'S OWN TEMP IS EVER REMOVED: a `$FARM_ROWS_FILE.tmp-*` glob would unlink a
# concurrent pass's in-flight temp and turn its successful write into a false `unwritable`.
FARM_ROWS_FILE="$STATE_DIR/harness-apply-farm-rows.txt"
# ⛔ `REC_REMEDY` IS A FIELD FOR THE SAME REASON `preserved=` IS (review finding, #10114). Measured
# on the deployed-drift refusal: its `detail=` is 706 characters and the word `Remedy:` begins at
# offset 272 — so the 240-byte `detail=` bound DISCARDS THE ENTIRE REMEDY from the durable record. stderr still
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
        # ⛔ `farm_rows=` NAMES THE FILE THAT NAMES EVERY DRIFTING FILE (tortoise#10114 arm 2). Besides
        # a path it can be `none` (the farm matched — this pass wrote NO list, and whatever is on disk
        # is not today's answer), `unwritable` (the rows write failed while this record still wrote:
        # said out loud rather than silently leaving 18 files named nowhere) or `not-graded` (NO USABLE
        # GRADE was produced: the switch is off, there was no farm to grade, a refusal exited first, or
        # the instrument's rc was unreadable). ⛔ `action=` DOES NOT NAME ALL OF THEM: the DISARMED arm
        # and the farmless SKIPPED arm both write `action=none`, which is also what a graded-clean pass
        # writes — there `farm_rows=` itself is the signal, and only the journal's `farm: SKIPPED` line
        # says which of the two it was.
        printf 'farm_rows=%s\n' "$REC_FARM_ROWS"
        printf 'farm_n=%s\n' "$REC_FARM_NROWS"
        printf 'preserved=%s\n' "${PRESERVED_DIR:-none}"
        # ⛔ NOT TRUNCATED, and last, for the same reason as `preserved=` above: a remedy is the one
        # line a reader MUST be able to act on, so it is never at the mercy of a prose bound. Bounded
        # by construction (each is a fixed sentence the call sites author), not by `cut`.
        printf 'remedy=%s\n' "$(printf '%s' "${REC_REMEDY:-none}" | tr '\n' ' ')"
        printf 'action=%s\n' "$REC_ACTION"
        printf 'lanes=none-signalled\n'
        printf 'fetch=%s\n' "${FETCH_STATE:-notfetched}"
        printf 'detail=%s\n' "$(bounded "$(printf '%s' "$REC_DETAIL" | tr '\n' ' ')")"
    } >"$tmp" 2>/dev/null \
        || { rm -f "$tmp"; err "cannot stage the pass record in $STATE_DIR"; return 1; }
    mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; err "cannot write the pass record at $RECORD"; return 1; }
    { printf '%s ' "$(date -u +%FT%TZ)"; tr '\n' ' ' <"$RECORD"; printf '\n'; } >>"$LOG" 2>/dev/null || true
    return 0
}

short() { [ -n "${1:-}" ] && printf '%s' "$1" | cut -c1-12; }

# ⛔ A BOUNDED FIELD MUST STILL BE READABLE TEXT (review round 11, reproduced). `cut -c1-240` is
# BYTE-oriented on GNU coreutils, so a multi-byte character straddling byte 240 is SPLIT and the record
# then holds an invalid UTF-8 sequence — and `grep '^detail=' <record>`, which is how every key=value
# reader (fleet-health, the suite's own assertions) reads the record, classifies the whole file as
# BINARY and prints NOTHING for the pattern. Measured on a record whose byte 240 landed inside a
# multi-byte character: `grep '^detail='` printed ``binary file matches`` on stderr and zero bytes on
# stdout, so the one field that answers "what happened" read as ABSENT. (Which character straddles the
# bound is an accident of the record's own length — do not read the sentence above as naming one.) So
# the truncation stops at the
# last ASCII byte: every multi-byte UTF-8 sequence is composed of bytes >= 0x80, so a prefix that ends
# on an ASCII byte cannot split one — no locale, iconv or multibyte-aware `substr` required.
bounded() {
    printf '%s' "$1" | LC_ALL=C awk -v n=240 '
        { if (length($0) > n) { s = substr($0, 1, n); sub(/[^ -~]+$/, "", s); print s } else print }'
}

# ⛔ ONE ROW VOCABULARY AND ONE SUMMARY PROOF, SHARED BY BOTH ARMS THAT READ A CHECKER'S OUTPUT (review
# round 24, measured). The rc=0 contradiction check had grown its OWN row predicate (`NF>=4` and a
# `stale`-only summary read) while the drift arm had another — so a report whose drift lay entirely in
# the other two classes was refused at rc=3 and certified CLEAN at rc=0: measured with
# `handmade-a.py | drift` rows and `DRIFT — 0 stale …, 0 declared-but-absent, 2 unsourced`, a `tee`
# wrapper made the pass print `farm: ok` / `farm_rows=none` / `farm_n=0` and publish NO artifact, both
# names durable nowhere. One predicate governs both branches now; there is no second copy to keep in step.
farm_drift_rows() {
    printf '%s\n' "$1" | awk -F'|' '$NF ~ /(^|[[:space:]])(STALE|UNSOURCED|NOT-EXECUTABLE|DECLARED-BUT-ABSENT)[[:space:]]*$/'
}

# The instrument's own drift TOTAL, from its VERDICT LINE, and ONLY when the proof is CLOSED — the same
# proof the drift arm uses. Prints NOTHING when a label is absent, the line is not the verdict, or the
# line carries a class this pass does not count, so "cannot prove" never degenerates to 0 and never
# silently shrinks to the classes it knows.
# ⛔ ANCHORED ON "NO PIPE ON THE LINE", NOT ON THE WORD (review round 31, measured twice): a per-file
# ROW's first field is its PATH, so `grep -m1 '[0-9]* stale'` took a row for a file literally named
# `3 stale.py` as the summary and reported a complete, parsable summary as ABSENT (over-block plus a
# false reason: "no COMPLETE, parsable summary"). A ROW always carries its separators, a summary line
# never does — the same invariant `FARM_VERDICT0` uses one level over — and it is the weaker anchor on
# purpose: a lagging farmed copy may print its summary without the `PROG: DRIFT — ` prefix (or as
# `PROG: summary — …`), and those lines must still prove or refute the extraction.
# ⛔ AND THE VOCABULARY IS CLOSED (review round 31, measured): the total was built from the labels this
# pass knows (`stale` + `declared-but-absent` + `unsourced`), so a report carrying a FOURTH class
# (`3 not-landed`) excluded those rows from the numerator AND the denominator — `2 == 2` then took the
# COMPLETE arm and certified "every one named" over a list that dropped three files the instrument
# reported. An unrecognised `<n> <label>` component means the proof is ABSENT, exactly like an
# unparsable one; the bookkeeping labels the instrument prints alongside are allow-listed by name.
farm_sum_count() {
    local _l="" _a="" _b="" _c="" _bad=""
    _l="$(printf '%s\n' "$1" | grep -E '^[^|]*$' | grep -m1 '[0-9][0-9]* stale' || true)"
    [ -n "$_l" ] || return 0
    # ⛔ THE COUNT MAY START THE LINE (review round 31, measured: the label seds required a NON-DIGIT
    # before the number, so a copy that prints its summary without the `PROG: DRIFT — ` prefix — the
    # count at column 1 — was reported as having printed no parsable summary at all, an over-block with a
    # false reason over a summary that was printed and does parse). Two expressions per label: the
    # start-of-line form and the preceded-by-anything form, in that order.
    _a="$(printf '%s' "$_l" | sed -n -e 's/^\([0-9][0-9]*\) stale.*/\1/p' \
                                     -e 's/.*[^0-9]\([0-9][0-9]*\) stale.*/\1/p')"
    _b="$(printf '%s' "$_l" | sed -n -e 's/^\([0-9][0-9]*\) declared-but-absent.*/\1/p' \
                                     -e 's/.*[^0-9]\([0-9][0-9]*\) declared-but-absent.*/\1/p')"
    _c="$(printf '%s' "$_l" | sed -n -e 's/^\([0-9][0-9]*\) unsourced.*/\1/p' \
                                     -e 's/.*[^0-9]\([0-9][0-9]*\) unsourced.*/\1/p')"
    # ⛔ `_a` IS NOT A SEPARATE GATE. The pre-filter above ALREADY matched `<n> stale`, so a second test on
    # the same occurrence can never fail — it was a guard whose condition could not be false (the
    # "inert enforcer" class this file's own rules forbid). `_b`/`_c` are genuinely optional in the
    # instrument's output, so they still gate the proof.
    [ -n "$_a" ] || return 0
    { [ -n "$_b" ] && [ -n "$_c" ]; } || return 0
    _bad="$(printf '%s\n' "$_l" \
        | grep -oE '[0-9][0-9]* [A-Za-z][A-Za-z-]*' \
        | awk '{ print tolower($2) }' \
        | grep -vxE 'stale|declared-but-absent|unsourced|farm-declared|outside|deployed|sourced|matching' \
        || true)"
    [ -n "$_bad" ] && return 0
    printf '%s' "$(( _a + _b + _c ))"
}

# ⛔ ONE PUBLISH PATH FOR EVERY ARM THAT HAS SOMETHING TO NAME (review round 13, reproduced). The
# `farm-unknown` arm (instrument exit 2) ALSO prints per-file rows BEFORE it gives up — the POST-LOOP
# give-up exits in `check-farm-drift.sh` (its `matched -eq 0` arm and the mixed-ungradeable pair, the two
# this parenthetical names) come after the per-file loop, so "no grade" was taken to mean "nothing was
# reported" and those names were dropped. ⛔ NO UNIVERSAL (review cycle-9 #2, corrected cycle-10 #4): the
# instrument ALSO gives up in places that are not post-loop — before its loop on an unresolvable `--src`,
# a missing `$DEST`, an unresolvable `--ref` or a broken symlinked layer (which have no row to publish),
# and INSIDE the loop on a file it cannot grade (which has already published the earlier rows). "Every
# give-up exit" and "every post-loop exit" were both wrong; the two arms are named instead.
# Measured: 2 UNSOURCED rows then exit 2 printed only the UNKNOWN reason, wrote no artifact, and named
# both files NOWHERE. The write is atomic (temp + rename), REFUSES a directory at the published path,
# and records its own outcome, so neither arm can drift from the other.
publish_farm_rows() {   # $1 body, $2 header note → sets REC_FARM_ROWS, FARM_ROWS_OK
    local _body="$1" _note="$2" _sd=""
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ "${FARM_ROWS_FILE#/}" = "$FARM_ROWS_FILE" ]; then
        # ⛔ `CDPATH=` IS LOAD-BEARING (review round 3): bash's `cd` PRINTS the resolved directory when
        # it resolves through an inherited CDPATH, so `_sd` would hold two lines and the "absolute"
        # path would name a directory containing a newline.
        _sd="$(CDPATH= cd "$STATE_DIR" 2>/dev/null && pwd)" || _sd=""
        [ -n "$_sd" ] && FARM_ROWS_FILE="$_sd/harness-apply-farm-rows.txt"
    fi
    # ⛔ THE POST-CONDITION IS THE PUBLISHED PATH, NOT `mv`'s EXIT CODE. `mv src dir` where the
    # artifact path is a DIRECTORY moves the tempfile INTO it and returns 0, so an exit-code-only test
    # would record a path that holds no list. The `[ ! -d ]` pre-check refuses that state UP FRONT
    # (replacing it with `[ -n … ]` strands the temp inside the directory and reds T24r); the trailing
    # `[ -f ]` is DEFENCE IN DEPTH for the concurrent case and is stated as such (#3442).
    # ⛔ AND IT IS UNPINNED BY CONSTRUCTION — one of this file's DECLARED inert-defence sites. The
    # others, each measured to leave the suite green when deleted (review rounds 25 and 30):
    #   * the `CDPATH=` on the `$FARM_DEST_REAL`/`$HERE_REAL` legs (two `CDPATH=` prefixes),
    #   * `[ -n "$HERE_REAL" ] &&` in the self-grade comparison (the self-grade leg),
    #   * `[ -n "$FARM_DEST_REAL" ] &&` in the inside-the-farm containment test (the containment leg) — searched
    #     for by the round-30 reviewer precisely because this list did not name it.
    # Measured (review round 25): deleting `&& [ -f "$FARM_ROWS_FILE" ]` leaves the suite green. That is not an oversight — the only
    # state it can catch is a race (something replacing the published path with a directory between the
    # `rename` and this test), and a fixture cannot produce that race deterministically without stubbing
    # `mv`. It is kept because it is cheap and it is the one post-condition that cannot be forged, and it
    # is DECLARED here so that "every new guard has an attributable mutant" is not left standing as a
    # claim this file contradicts.
    FARM_ROWS_OK=0
    # ⛔ AN EMPTY BODY WRITES NO BODY LINE (review round 15, measured): `printf '%s\n' ""` emits one
    # BLANK line, so the mute-instrument artifact was a header plus a stray empty row — a reader sizing
    # the list with `wc -l - 1` counted a row in the one state where the pass says no name exists.
    if [ ! -d "$FARM_ROWS_FILE" ] \
       && { printf '# harness-apply farm drift rows — %s — ref=%s dest=%s %s\n' \
                "$(date -u +%FT%TZ)" "$REF" "$FARM_DEST" "$_note" >"$FARM_ROWS_FILE.tmp-$$" 2>/dev/null \
            && { [ -z "$_body" ] || printf '%s\n' "$_body" >>"$FARM_ROWS_FILE.tmp-$$" 2>/dev/null; }; } \
       && mv -f "$FARM_ROWS_FILE.tmp-$$" "$FARM_ROWS_FILE" 2>/dev/null \
       && [ -f "$FARM_ROWS_FILE" ]; then
        REC_FARM_ROWS="$FARM_ROWS_FILE"; FARM_ROWS_OK=1
    else
        rm -f "$FARM_ROWS_FILE.tmp-$$" 2>/dev/null || true
        REC_FARM_ROWS=unwritable
    fi
}

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

# ⛔ THE SPLIT IS A READING ON EVERY VERB AND A REFUSAL ONLY ON THE ACTING ONE (review F3). A
# `--print-status` answers "did the last pass succeed" from the RECORD and a `--dry-run` preview changes
# nothing (including its exit contract), so neither may exit 27 — but both must be able to SAY the split,
# or an operator inspecting a box is the last to learn why it is red.
if [ -n "$SPLIT_HOME" ]; then
    log_line "split_home=$SPLIT_HOME derived=$CELL_HOME from=${SPLIT_HOME_SRC:-unknown} why=[$SPLIT_HOME_WHY] — two live homes on one box (agent-infra#3453); the refusal on the acting verb names the instrument that resolves it"
elif [ "$SPLIT_HOME_STATE" = unmeasurable ]; then
    # ⛔ SAY THE THIRD STATE (review P2). Silence here was indistinguishable from "measured, no split",
    # and `--print-status`/`--dry-run` are exactly the verbs an operator uses to find out.
    log_line "split_home=unmeasurable — ${SPLIT_HOME_STATE_WHY:-the split could not be measured}; NOTHING was measured, so this is not agreement (agent-infra#3453)"
fi

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
log_line "harness: mode=$PASS_MODE repo=$REPO ref=$REF fetch=$FETCH_STATE head=$(short "$HEAD_SHA") checkout_relation=$RELATION checkout_behind=$BEHIND ref_sha=$(short "$REF_SHA") dirty=$DIRTY_N pin=$REC_PIN pin_tree=$REC_PIN_TREE split_home=$SPLIT_HOME_STATE"
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
        # under the scheduler — this file says so itself (the `HARNESS_APPLY_REPO`/`HARNESS_APPLY_REF` note: "under the scheduler — where there is no
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
                REC_REMEDY="$(supervisor_cmd) apply --force --pin-only, then restart the controller from the pinned tree (a redeploy does not clear it)"
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
       # Its `detail=` is ~250+ chars once the readings suffix is appended, so the 240-byte bound drops the
       # tail; `remedy=` is a FIELD so the REMEDY survives regardless (review round 3, finding 5).
       # (`action=` is written on its own line at :383 and never depended on this — what the prose
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

# ⛔ THE SPLIT REFUSES **HERE** — after the readings, THROUGH the record, and BEFORE THE FIRST MUTATION
# (review F3 + F-A). Two placement errors were measured and both are fixed by this one position:
#   · at the derivation (the first cut) it aborted `--print-status` and `--dry-run` and left the PREVIOUS
#     tick's green record standing for up to `HARNESS_APPLY_STALE_SECONDS` (3600 s) while the unit was red;
#   · after the dirty-preservation block (the second cut) it PRESERVED AND RESTORED the tree — rewriting
#     tracked files to HEAD and removing move destinations — and then said "Nothing was touched". The
#     default mode on the population this guard targets is exactly that path (an un-migrated box has no
#     pin record under the derived home, carries `./sync.sh`, and is behind), so the false sentence was
#     the common case, not an edge.
# A refusal must precede every write, and its message must be true.
if [ -n "$SPLIT_HOME" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log_line "dry-run: would REFUSE split-home — $SPLIT_HOME_WHY, and this pass derives CELL_HOME=$CELL_HOME; nothing was touched (a real run exits 27)"
        exit 0
    fi
    REC_ACTION=refused-split-home
    REC_DETAIL="split home: $SPLIT_HOME_WHY but this pass derives CELL_HOME=$CELL_HOME"
    # ⛔ THE REMEDY MUST BE ABLE TO RESOLVE THE REFUSAL (review F1). This field used to send EVERY split
    # to `cell-home-migrate.sh` — but that tool's whole graded population is the LEGACY literal, so on a
    # box whose unit pins some OTHER wrong home (a stale `/home/ubuntu`, the measured `cmux vm exec`
    # value, baked in by an older installer) it answers "one home — nothing to do", the operator's only
    # printed remedy is a no-op, and the tick stays red forever. The remedy is now derived from WHERE the
    # disagreement came from: the legacy literal → the migration really is the tool; any other home →
    # the installer that rendered the unit, which is the thing that must be re-run.
    # ⛔ COMPARED NORMALISED, LIKE THE GUARD ABOVE (review cycle-9 #4). `$SPLIT_HOME` is the RAW pin, and a
    # unit whose value ends in `/` is refused by the split test (both sides are stripped there) yet failed
    # this selector, which sent the operator to the installer with a sentence claiming the migration
    # "reports this box converged" — false: `cell_home_project_line` treats a trailing `/` as a component
    # boundary, so `--check` DOES report drift and `--apply` DOES repoint it. One normalisation, used by
    # both, so the branch cannot disagree with the refusal it explains.
    case "${SPLIT_HOME%/}" in
      "${CELL_HOME_LEGACY%/}")
        REC_REMEDY="converge the box: bash scripts/cell-home-migrate.sh --check, then --apply (it repoints the legacy $CELL_HOME_LEGACY)" ;;
      *)
        if [ "$SPLIT_HOME_SRC" = controller ]; then
          REC_REMEDY="re-render the controller's unit so it exports the ONE home: bash scripts/install-controller-service.sh --install (or set CELL_HOME explicitly if $SPLIT_HOME is the home this box's controller really reads). cell-home-migrate.sh grades only the legacy literal, so it reports this box converged"
        else
          REC_REMEDY="re-render this pass's own unit so it exports the ONE home: bash scripts/install-harness-apply-timer.sh --install (or set CELL_HOME explicitly if $SPLIT_HOME is the home this box's controller really reads). cell-home-migrate.sh grades only the legacy literal, so it reports this box converged"
        fi ;;
    esac
    err "REFUSED split-home: $SPLIT_HOME_WHY, but this pass derives CELL_HOME='$CELL_HOME' — two live homes on one box, so the pin this pass would write is not the pin the controller reads (agent-infra#3453)"
    # ⛔ NOT "nothing was touched" WITHOUT A QUALIFIER (review round-3 F6, measured): the fetch that
    # refreshed the ref already ran, and it writes `.git/FETCH_HEAD` and the remote-tracking ref. The
    # WORKTREE is untouched — which is what an operator reaching for `git status` cares about — so say
    # exactly that, and name the fetch rather than pretending it did not happen.
    err "  Nothing in the worktree was touched — this refusal precedes the dirty-preservation pass and every other write (the fetch that refreshed $REF was the last thing that ran). $REC_REMEDY"
    write_record 0 27 || exit 23
    exit 27
fi

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
            # 474 chars, so the 240-byte bound lands mid-sentence and discards the action clause — the same
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
        #   `--force` because when this line was written `apply` REFUSED to touch a cell whose
        #      controller was live even on the pin-only path. Measured in review: `apply --pin-only` on
        #      a live cell exited 1 with "a controller is RUNNING … re-run with --force", so the pass
        #      recorded rc=23 and the unit went RED every ten minutes on a healthy box while the pin
        #      never moved.
        #   ⛔ THAT REFUSAL IS GONE (agent-infra#2738): the supervisor now EXEMPTS `--pin-only` from the
        #      running-controller guard, because the guard protects `seed_and_stamp` (which this path
        #      returns before) and a pin-only advance only creates a NEW per-commit worktree. `--force`
        #      is therefore belt-and-braces here, kept deliberately: this unit must never redden on a
        #      healthy cell, so it must not depend on where that guard's scope happens to sit. The
        #      load-bearing flag is `--pin-only`; dropping THAT is still a regression.
        # ⛔ EVERY RESOLVED VALUE GOES TO THE CHILD ON ITS OWN COMMAND LINE, like the checker 400
        #      lines above (agent-infra#3593). The materialiser RESOLVES the same paths from ITS
        #      defaults — it used to be `CELL_HOME="${CELL_HOME:-/tmp/cell-home}"`
        #      (cloud-cell-supervisor.sh; unified on the durable home by agent-infra#3453, which does
        #      NOT remove the need for this line), then `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE` from it —
        #      and a shell variable set HERE is
        #      invisible to a child unless it is exported. Measured on a cell whose unit sets `HOME`
        #      and no `CELL_HOME`: this pass resolved `/home/cmux`, the materialiser pinned into
        #      `/tmp/cell-home/harness/<sha12>`, the re-read below saw no move and reported rc=25
        #      "nothing moved this box" — a TRUE reading of the WRONG records, and it `finish`es
        #      BEFORE predicate 4, so on that box the farm grade this whole feature exists to emit
        #      could never run at all.
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
            # ⛔ EVERY REFUSAL CARRIES A REMEDY (review round 17, measured: all eight arms of this
            # predicate wrote `remedy=none` while three of them lose their only action to the 240-byte
            # `detail=` bound — "…install the CHECKER from a ref-c" — so the record named a defect and
            # left nobody an action, the class this PR exists to remove).
            REC_REMEDY="point HARNESS_APPLY_FARM_DEST at the farm this box executes (or unset it to accept the default), then re-run"
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
                REC_REMEDY="set HARNESS_APPLY_FARM_DEST (or render CELL_HOME) to the farm this pass executes from ($HERE), then re-run"
                finish 0 24 "farm: UNKNOWN — this pass executes FROM a farm ($HERE) but $FARM_DEST names nothing (CELL_HOME='$CELL_HOME'), so the directory that is really running was never graded; pin the farm (HARNESS_APPLY_FARM_DEST, or render CELL_HOME) instead of letting it default to a path with nothing at it" ;;
        esac
        log_line "farm: SKIPPED — no farm at $FARM_DEST (a host that executes nothing from there cannot be stale)"
    elif [ ! -d "$FARM_DEST" ]; then
        REC_ACTION=farm-unverifiable
        REC_REMEDY="make $FARM_DEST a readable directory holding the scripts this box executes (repair or remove the dangling link), then re-run"
        finish 0 24 "farm: UNKNOWN — $FARM_DEST exists (or is a link) but is NOT a readable directory, so the scripts this box executes cannot be graded — a dangling record is not an absent farm"
    elif [ -z "$FARM_CHECKER" ] || { [ ! -f "$FARM_CHECKER" ] && [ ! -L "$FARM_CHECKER" ]; }; then
        # ⛔ A SYMLINK THAT DOES NOT RESOLVE TO A FILE IS NOT YET A "NOT FOUND" (review round 20,
        # measured). `-f` follows links, so a CYCLE made it false and this arm answered first — which
        # left the hop-cap refusal below UNREACHABLE dead code (an inert enforcer: its condition could
        # never fire while it looked like a guard) and told an operator with a cyclic link that the
        # instrument "could not be found". A `-L` path is let through to the resolution loop, which is
        # the only place that can tell a cycle from a dangling link; the `! -f` refusal after it keeps
        # the dangling-link answer identical to the one this arm used to give.
        REC_ACTION=farm-unverifiable
        REC_REMEDY="point HARNESS_APPLY_FARM_CHECKER at a check-farm-drift.sh from a ref-consistent checkout, then re-run"
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
                REC_REMEDY="replace HARNESS_APPLY_FARM_CHECKER with a real file (not a link whose target cannot be read), then re-run"
                finish 0 24 "farm: UNKNOWN — readlink failed on $FARM_CHECKER_T, so the checker's FINAL target cannot be resolved, and a copy that cannot be located cannot be ruled outside the farm"
            }
            case "$_l" in
                /*) FARM_CHECKER_T="$_l" ;;
                *) FARM_CHECKER_T="$(CDPATH= cd "$(dirname "$FARM_CHECKER_T")" 2>/dev/null && pwd -P)/$_l" ;;
            esac
            _hops=$((_hops + 1))
        done
        unset _l
        # ⛔ THE HOP CAP IS A REFUSAL TOO. A chain longer than the bound exits the loop above with
        # `-L` STILL TRUE, i.e. with the same half-resolved path the failed-`readlink` arm now refuses.
        if [ -L "$FARM_CHECKER_T" ]; then
            REC_ACTION=farm-unverifiable
            REC_REMEDY="replace HARNESS_APPLY_FARM_CHECKER with a real file (break the link cycle), then re-run"
            finish 0 24 "farm: UNKNOWN — $FARM_CHECKER is a symlink chain that did not resolve within 40 hops, so where it points cannot be established"
        fi
        # ⛔ THE DANGLING-LINK ANSWER MOVED HERE, UNCHANGED (review round 20). The `! -f` refusal above
        # could only be reached for a NON-link before this round, because a link was let through to the
        # loop above it; a link whose target does not exist must still get the same "no checker could be
        # found" sentence and remedy, not fall through to `bash` and be recorded as a bad grade.
        if [ ! -f "$FARM_CHECKER_T" ]; then
            REC_ACTION=farm-unverifiable
            REC_REMEDY="point HARNESS_APPLY_FARM_CHECKER at a check-farm-drift.sh from a ref-consistent checkout, then re-run"
            finish 0 24 "farm: UNKNOWN — $FARM_DEST holds the scripts this box EXECUTES, but no check-farm-drift.sh could be found (looked in $REPO/scripts and $HERE) — cannot-verify is not a pass"
        fi
        FARM_CHECKER_REAL="$(CDPATH= cd "$(dirname "$FARM_CHECKER_T")" 2>/dev/null && pwd -P)/$(basename "$FARM_CHECKER_T")"
        FARM_DEST_REAL="$(CDPATH= cd "$FARM_DEST" 2>/dev/null && pwd -P)"
        # ⛔ ...AND IT MUST BE THE FARM THIS PASS RUNS FROM. The `case "$HERE"` refusal above only fires
        # when `$FARM_DEST` names NOTHING; when it names a DIFFERENT farm that exists, the pass grades
        # that one and reports green over the farm it is executing (review round 7, reproduced with two
        # farms on one box). On the production install path the two are equal — the unit runs
        # `$HOME/.pi/agent/scripts/harness-apply-pass.sh` and `$FARM_DEST` defaults to
        # `$CELL_HOME/.pi/agent/scripts` — so this creates no false red where the box is consistent.
        case "$HERE" in
            */.pi/agent/scripts|*/.pi/agent/scripts/)
                HERE_REAL="$(CDPATH= cd "$HERE" 2>/dev/null && pwd -P)"
                if [ -n "$HERE_REAL" ] && [ "$HERE_REAL" != "$FARM_DEST_REAL" ]; then
                    REC_ACTION=farm-unverifiable
                    REC_REMEDY="pin HARNESS_APPLY_FARM_DEST (or render CELL_HOME) to the farm the units execute ($HERE_REAL), then re-run"
                    finish 0 24 "farm: UNKNOWN — this pass executes FROM $HERE_REAL but grades $FARM_DEST_REAL; the farm that is really running was never graded — pin the farm (HARNESS_APPLY_FARM_DEST, or render CELL_HOME) to the one the units execute"
                fi ;;
        esac
        if [ -n "$FARM_DEST_REAL" ] && [ "${FARM_CHECKER_REAL#"$FARM_DEST_REAL"/}" != "$FARM_CHECKER_REAL" ]; then
            REC_ACTION=farm-unverifiable
            REC_REMEDY="install the CHECKER from a ref-consistent checkout (HARNESS_APPLY_FARM_CHECKER) so it is not a copy inside the farm it grades, then re-run"
            finish 0 24 "farm: UNKNOWN — the only check-farm-drift.sh found ($FARM_CHECKER) lives INSIDE the farm it would grade, and a copy that grades itself cannot answer whether it is stale — install the CHECKER from a ref-consistent checkout"
        fi
        FARM_OUT="$(bash "$FARM_CHECKER" --src "$REPO" --ref "$REF" --dest "$FARM_DEST" --no-pin-identity 2>&1)"
        FARM_RC=$?
        # The checker's own per-file vocabulary, matched on the FINAL column, and ONLY the four it
        # actually prints as a verdict. `MISSING` and `LOCAL (undeclared)` are not tokens it emits;
        # `SYMLINK` IS printed (the instrument's `SYMLINK (graded via its target)` line) but that
        # row is INFORMATIONAL — a healthy link — so matching the bare token would name a good file as
        # drift the moment the anchor is relaxed (#10114 review round 2).
        # (A `FARM_NAMED` short list was computed here and never read — the row extraction below owns
        # the predicate, so it was dead code plus a redundant `awk|head|paste` subprocess on the red
        # path. Removed in batch-ai2 review cycle 2, F7.)
        # ⛔ THIS BRANCH OWNS NO DELETION (review round 2). A pass that finds no drift writes no list;
        # a pass that finds drift OVERWRITES it atomically with its own header. The previous list is
        # deliberately left in place — see the artifact note beside the record-field init above.
        # ⛔ ONE REMEDY EXTRACTION, FOR EVERY ARM THAT REFUSES (review round 16, measured). It used to
        # live inside the `1|3` arm, so the `farm-unknown` (rc=2) refusal — the one that most often
        # CARRIES a `Next:` block, because the instrument prints it before giving up — recorded
        # `remedy=none` while its artifact held the block. Measured: a checker printing an UNSOURCED row,
        # an UNKNOWN reason and `   Next: fix the declaration entries … then re-run this.` produced
        # `action=farm-unknown` + `remedy=none`, with the word `Next` nowhere in the record.
        # ⛔ AND IT IS NOT CAPPED (review round 27, measured): this used to end `| head -8`, so a `Next:`
        # block of ten actions recorded `remedy=` with the first eight and dropped the ninth and tenth —
        # named NOWHERE, because `detail=` deliberately carries no remedy clause. The shipped instrument
        # prints one or two lines today, which is why nothing failed: the cap bites the moment a class
        # grows a line, and it is a cap on the ONE field the record exists to guarantee. `write_record`
        # flattens NEWLINES (`tr`), so the field is still one line; length was never its bound.
        FARM_REMEDY="$(printf '%s\n' "$FARM_OUT" | sed -n '/^[[:space:]]*Next:/,$p')"
        # ⛔ THE EXIT CODE IS NOT THE GRADE — THIS PROCESS MAY NOT BE THE INSTRUMENT (review round 21,
        # measured). `HARNESS_APPLY_FARM_CHECKER` is a documented seam, and an operator wrapper that
        # reports the PIPELINE's status (`bash inner "$@" 2>&1 | tee -a log`) exits 0 no matter what
        # the instrument said. Measured with such a wrapper over a checker printing one STALE row and
        # `DRIFT — 1 stale …`: the pass recorded `action=none farm_rows=none farm_n=0` + `detail=current`
        # and printed `farm: ok`, so the one drifting file the instrument named was durable NOWHERE
        # while the record positively certified a match — the exact green-over-drift the whole predicate
        # exists to remove, at the one arm that trusted its input absolutely. So a rc=0 that also
        # reported drift is CONTRADICTORY, and a contradiction is not a grade: the output is published
        # under a NO GRADE header and the pass refuses, exactly as an unreadable grade does.
        # ⛔ THE SAME PREDICATE AND THE SAME PROOF AS THE DRIFT ARM (review round 24, measured: a
        # private `NF>=4` row test plus a `stale`-only summary read certified a report CLEAN at rc=0
        # whose drift was all `unsourced` — the drift arm refuses those same bytes at rc=1, so the guard
        # was weaker than the arm it guards, for the class the instrument calls its normal historical
        # state). Both halves now come from the shared helpers above.
        FARM_ROWS0="$(farm_drift_rows "$FARM_OUT")"
        FARM_NROWS0="$(printf '%s' "$FARM_ROWS0" | grep -c .)"
        # ⛔ THE CONTRADICTION IS THE *VERDICT*, NOT ONE OF ITS COUNTS (review: the parse read only the
        # `stale` count, so `rc=0` over `DRIFT — 0 stale …, 2 declared-but-absent, 0 unsourced` — drift
        # this pass's row vocabulary did not match, which is the premise the whole extraction arm exists
        # for — recorded `farm: ok` / `farm_rows=none` / `farm_n=0`. The instrument prints `OK — ` on a
        # match and `DRIFT — ` otherwise, so the verdict line ALONE is the contradiction; summing three
        # counts answers a narrower question than the one being asked.)
        # ⛔ ANCHORED ON THE INSTRUMENT'S LINE SHAPE, NOT ON A BARE TOKEN (review round 26, measured).
        # `grep 'OK — '` matched the token ANYWHERE, so a per-file row reading `OK — handmade-note.py`
        # certified a match with the drifting file named durably nowhere — the very hazard this chain
        # anchored away in `farm_sum_count` (`DRIFT-log.txt | …` read as the summary). Its mirror was
        # worse: an unanchored `DRIFT — ` OVER-BLOCKED a legitimate match whose output merely contained
        # the text. The instrument prints `check-farm-drift: OK — …` / `…: DRIFT — …` (PROG + ': '), and a
        # VERDICT LINE CARRIES NO PIPE ANYWHERE while a per-file row always does — so the test is "no pipe
        # on the whole line", `^[^|]*: … [^|]*$`, not merely "no pipe before the token": a row's FIRST
        # field is its PATH, so `weird: OK — x.py | … | DRIFTED` matched a prefix-only anchor and certified
        # a match with the drifting name durable nowhere (measured, review round 27).
        FARM_VERDICT0="$(printf '%s\n' "$FARM_OUT" | sed -n '/^[^|]*: DRIFT — [^|]*$/{p;q;}')"
        # ⛔ AND THE SUMMARY IS THE THIRD HALF — THE ROW PREDICATE ALONE IS BLIND TO IT (review round 29,
        # measured). The row half matches only this pass's own class TOKENS, so a report whose rows use a
        # word it does not know (`… | drift`, `… | missing`) is invisible there, and the three-label
        # summary was never read on this arm at all — `farm_sum_count` was called ONCE, inside the `1|3`
        # arm. Measured: the same bytes — an `OK — 5/5 …` line, two such rows, and
        # `… — 2 stale, 0 declared-but-absent, 0 unsourced` — recorded `farm: ok` / `farm_rows=none` /
        # `farm_n=0` at rc=0 and `rc=24` with both names published at rc=1. The doc claims this arm uses
        # "the SAME three-label summary proof as the drift arm"; it did not. It does now: a summary whose
        # own total is non-zero says rows exist, and a status of 0 beside it is a contradiction.
        FARM_EXPECT0="$(farm_sum_count "$FARM_OUT" || true)"
        # ⛔ ABSENCE OF EVIDENCE IS NOT A MATCH EITHER (review round 32, measured). Every test above fires
        # on something this pass can POSITIVELY recognise, so a report it cannot classify on ANY axis was
        # certified: measured with `OK — 5/5 …`, rows `handmade.py | … | drift` / `gone.py | … | missing`
        # and `summary — 2 drift, 0 stale, 0 declared-but-absent, 0 unsourced`, the pass printed
        # `farm: ok`, recorded `farm_rows=none farm_n=0`, wrote NO artifact — two drifting names durable
        # nowhere — while the same bytes at `exit 1` were RED with both published. `farm_sum_count`'s
        # closed vocabulary returns EMPTY for that summary and the row predicate returns EMPTY for those
        # rows, and empty was read as "nothing to contradict" instead of "no evidence". Two signals:
        #   * a SUMMARY line this pass cannot count (two of the three label words, no parsable total),
        #   * a per-file ROW whose verdict token is neither benign nor a class it knows.
        FARM_UNC0=""
        if [ -z "$FARM_EXPECT0" ]; then
            FARM_UNC0="$(printf '%s\n' "$FARM_OUT" | grep -E '^[^|]*$' | grep -ivE '^[^|]*: OK — ' \
                | awk '{ l = tolower($0); n = 0
                         if (l ~ /stale/) n++
                         if (l ~ /declared-but-absent/) n++
                         if (l ~ /unsourced/) n++
                         if (n >= 2) { print "summary"; exit } }')"
        fi
        # ⛔ AND THE ROW SCAN MUST COVER EVERY ROW SHAPE (review round 33, measured: `NF >= 4` skipped a
        # two-field row entirely, and a token with a digit or an underscore (`drift_v2`, `NOT-LANDED2`) fell
        # outside the alphabetic class, so a report this pass could not read still certified a match with
        # every name durable nowhere — the exact class round 32 closed one shape over). Two fields is the
        # minimum that can carry a verdict token; a row with a trailing separator (`docs/y.md | a | b |`)
        # splits to `NF=4` with an EMPTY last field, which is an unreadable row and not a non-row (round 35:
        # the empty token matched no clause and the row was silently dropped while the record certified a
        # match — the instrument never emits a trailing separator, so nothing legitimate is caught here).
        # ⛔ AND A ROW IS A PATH, NOT A PHASE LINE, AND ITS VERDICT VOCABULARY IS CLOSED (review rounds
        # 34-35, measured). The instrument RIGHT-PADS field 1 (printf with a 46-column width), so trailing
        # spaces are trimmed FIRST — an anchored shape test over the raw field rejected every genuine row
        # and the scan fell open. A row is then a first field with no whitespace, OR one carrying a `/`: a
        # wrapper tag or phase line has spaces and no slash (`harness-apply: checking farm`,
        # `12:00:03 harness-apply checking farm`, `[harness-apply] phase two`) and is skipped, while a
        # repo-relative path is a row EVEN when its own name carries a colon-space (`docs/review: notes.md`)
        # — round 34's prefix test skipped that row and certified a match with the name durable nowhere.
        # Residual, declared rather than implied: a field-1 path carrying a SPACE and no `/` at all is still
        # read as chatter.
        # The token test is a CLOSED, case-sensitive allow-list of the instrument's OWN vocabulary, not a
        # shape: as a block-list, `N/A`, `DRIFT/2`, `drift+1`, `x=y`, `#2` and `2-drift` all escaped it and
        # certified `farm: ok` / `farm_rows=none` / `farm_n=0` with the drifting name durable nowhere. A new
        # class now needs a deliberate edit here rather than another character-class patch.
        # NOTE: no apostrophes in these comments — the awk program is single-quoted, and one closes it.
        [ -n "$FARM_UNC0" ] || FARM_UNC0="$(printf '%s\n' "$FARM_OUT" | awk -F'|' '
            NF >= 2 {
                f1 = $1
                gsub(/[[:space:]]+$/, "", f1)
                if (f1 ~ /[[:space:]]/ && f1 !~ /\//) next
                v = $NF
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                if (v == "") { print "(an empty verdict field)"; exit }
                if (v == "verdict" || v == "ok") next
                if (v == "LOCAL (declared)" || v == "SYMLINK (graded via its target)") next
                if (v == "STALE" || v == "UNSOURCED") next
                if (v == "NOT-EXECUTABLE" || v == "DECLARED-BUT-ABSENT") next
                print v; exit
            }')"

        # ⛔ AND A SILENT rc=0 IS NOT A MATCH (review round 24). The instrument always prints a summary,
        # so a checker that exits 0 with NO output produced no evidence at all. ⛔ AND NEITHER IS AN rc=0
        # WHOSE OUTPUT CARRIES NO VERDICT (review round 25, measured): this check used to test only for
        # an EMPTY output, so the wrapper shape this file's own comment names —
        # `bash inner "$@" 2>&1 | tee -a log` — still certified a match when `inner` was MISSING, because
        # `tee` supplies the 0 and the output is bash's `No such file or directory` line: non-empty,
        # verdictless, and recorded `farm_rows=none` / `farm_n=0` / `farm: ok` — the values the doc
        # defines as "the farm matched", over a farm that was never graded, with `--print-status`
        # answering `status=ok`. A match is PROVEN by the instrument's own `OK —` line
        # (the instrument's own `OK —` line), which it prints before exiting; anything else is a grade nobody
        # can read, and it fails CLOSED. This SUBSUMES the emptiness test (empty output carries no
        # verdict either), so the two are one condition rather than two that can drift apart.
        # Case-insensitive because the suite's clean stubs print `check-farm-drift: ok — 0 stale …`.
        FARM_OK0="$(printf '%s\n' "$FARM_OUT" | grep -Eim1 '^[^|]*: OK — [^|]*$')"
        case "$FARM_RC" in
            0)
                if [ -z "$FARM_OK0" ] && [ "$FARM_NROWS0" -eq 0 ] && [ -z "$FARM_VERDICT0" ]; then
                    # ⛔ A CHECKER THAT PROVED NOTHING CANNOT CERTIFY A MATCH. Its own arm, because its
                    # own sentence: "reports drift" is false here, and a reader sent looking for drift
                    # rows that were never printed is a second defect.
                    REC_ACTION=farm-unknown
                    # ⛔ IT PUBLISHES, LIKE ITS SIBLING (review round 26, measured): this arm refused
                    # without publishing, so a checker that printed two file names with a foreign
                    # verdict word — and no verdict line — left both names durable NOWHERE, which is
                    # the acceptance arm (tortoise#10114 arm 2) lost inside `action=farm-unknown`.
                    # `publish_farm_rows`'s own doctrine: "no grade" never meant "nothing was reported".
                    # ⛔ AND SILENCE PUBLISHES NOTHING (review round 26, measured): an unguarded publish
                    # wrote a HEADER-ONLY artifact for a checker that printed no output at all, whose own
                    # note then claimed "this is its output verbatim" over nothing — while the give-up arm
                    # records `farm_rows=not-graded` and writes no file for the same silence. One state,
                    # one artifact outcome: a mute checker names no file because it printed none.
                    if [ -n "$(printf '%s\n' "$FARM_OUT" | grep -v '^[[:space:]]*$' || true)" ]; then
                        publish_farm_rows "$FARM_OUT" "n=unparsed (NO GRADE — the checker exited 0 without a verdict line, so nothing it printed can certify a match; this is its output verbatim, not a grade; farm_n=not-graded)"
                        REC_FARM_NROWS=not-graded
                    fi
                    REC_REMEDY="the checker exited 0 without printing the instrument's 'OK —' line — point HARNESS_APPLY_FARM_CHECKER at check-farm-drift.sh itself and run it WITHOUT --quiet (a wrapper, a broken copy, or the instrument's own --quiet, which suppresses the OK summary, cannot certify a match), then re-run"
                    log_line "farm: UNKNOWN — the checker exited 0 but printed NO verdict line (neither 'OK —' nor 'DRIFT —'), so nothing it printed can certify a match (the instrument's own --quiet suppresses the OK summary)"
                    finish 0 24 "farm: UNKNOWN (check-farm-drift rc=0) — no readable grade (see farm_rows=), so a status of 0 is not a match for $FARM_DEST against $REF: the checker printed no verdict line at all"
                fi
                if [ "$FARM_NROWS0" -gt 0 ] || [ -n "$FARM_VERDICT0" ] || { [ -n "$FARM_EXPECT0" ] && [ "$FARM_EXPECT0" -gt 0 ]; } || [ -n "$FARM_UNC0" ]; then
                    REC_ACTION=farm-unknown
                    publish_farm_rows "$FARM_OUT" "n=unparsed (NO GRADE — the checker exited 0 while reporting drift, so its exit status and its report contradict each other; this is its output verbatim, not a grade; farm_n=not-graded)"
                    REC_FARM_NROWS=not-graded
                    if [ -n "$FARM_UNC0" ]; then
                        REC_REMEDY="the checker exited 0 while printing a report this pass cannot read (an unclassifiable ${FARM_UNC0}) — point HARNESS_APPLY_FARM_CHECKER at check-farm-drift.sh itself (a farmed copy whose vocabulary has moved on cannot be graded here), then re-run"
                    else
                        REC_REMEDY="the checker exited 0 while reporting drift — point HARNESS_APPLY_FARM_CHECKER at check-farm-drift.sh itself (a wrapper that reports the pipeline's status hides the instrument's), then re-run"
                    fi
                    # ⛔ AND IT QUOTES THE EVIDENCE IT REFUSED ON (review round 29): with the summary
                    # half added, naming only "rows" would send the reader looking for rows the
                    # extractor never matched — the class whose vocabulary this pass does not know.
                    _v0="verdict: ${FARM_VERDICT0:-no DRIFT line}"
                    [ -n "$FARM_VERDICT0" ] || _v0="$_v0, rows only"
                    [ -n "$FARM_EXPECT0" ] && _v0="$_v0; summary reports $FARM_EXPECT0 row(s)"
                    # ⛔ AND AN UNREADABLE REPORT IS ITS OWN REASON (review round 32): the two signals
                    # above are "this pass could not classify it", not "it reported drift", and the
                    # remedy differs — the reader must re-farm or fix the checker, not go looking for
                    # drift rows that this vocabulary cannot name.
                    [ -n "$FARM_UNC0" ] && _v0="$_v0; an unclassifiable ${FARM_UNC0} — this pass cannot count or grade it"
                    log_line "farm: UNKNOWN — the checker exited 0 but its output reports drift ($FARM_NROWS0 row(s) matched; $_v0); an exit status that contradicts its own report is not a grade"
                    unset _v0
                    # ⛔ NO `detail=` SENTENCE INLINES THE ARTIFACT PATH, AND THE POINTER MUST SURVIVE THE
                    # 240-BYTE BOUND (review round 23, measured twice): the sentence used to END in "published
                    # in $REC_FARM_ROWS", which both inlined the path the doc forbids (and would have read
                    # "published in unwritable" on a failed publish — a publication that never happened) AND
                    # sat past the cut, so the record ended mid-word naming no file. Naming the diagnosis
                    # FIRST and the field pointer immediately after it is what keeps the pointer inside the
                    # bound; a pointer at the tail is lost at exactly the farms with the longest paths.
                    finish 0 24 "farm: UNKNOWN (check-farm-drift rc=0) — the checker exited 0 while reporting drift (see farm_rows=), so its exit status and its report contradict each other; an unreadable grade is not a pass for $FARM_DEST against $REF"
                fi
                REC_FARM_ROWS=none; REC_FARM_NROWS=0
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
                # (#10114 review round 8). The predicate below is the ONLY row extraction — there is no
                # second copy to keep in step.
                FARM_ROWS="$(farm_drift_rows "$FARM_OUT")"
                FARM_NROWS="$(printf '%s' "$FARM_ROWS" | grep -c .)"
                # ⛔ THE REMEDY IS A BLOCK, NOT A LINE. Two of the instrument's three remedies are TWO
                # lines and the CONTINUATION carries the actions ("…, delete it, or retire it in
                # pi-bootstrap/farm-retired.txt; then re-run this."), so forwarding only the `Next:`
                # line cut the remedy mid-word for exactly the classes whose remedy differs from
                # "re-farm" (#10114 review round 8). Everything from the first `Next:` to EOF.
                # `FARM_REMEDY` is extracted ONCE, above the `case` (review round 16).
                # ⛔ "MATCHED BY THIS PASS'S EXTRACTOR", NOT "FROM THE INSTRUMENT" (review round 8). On the
                # raw arm FARM_NROWS is 0 because THIS PASS's extractor matched nothing — the instrument
                # did report rows, and up to 12 of them are printed immediately BELOW this line.
                log_line "farm: $REF ships different bytes than $FARM_DEST execute — $FARM_NROWS row(s) matched by this pass's extractor:"
                # ⛔ AN INCOMPLETE EXTRACTION IS NOT "EVERY FILE NAMED" (review rounds 5 and 10, both
                # reproduced). The row extractor's vocabulary is a COPY of the instrument's, and the
                # checker this pass runs can be an OLDER FARMED copy whose rows it does not match —
                # so a RED grade (rc 1|3) can yield ZERO extracted rows, or a PARTIAL set. Both were
                # published as "N row(s), every one named in <file>": the one field that exists to
                # NAME files named fewer than the instrument reported, while positively certifying
                # completeness (and the doc's own trust rule validates the truncated list, because
                # header `n=` and `farm_n=` agree). The instrument's RAW output carries every name, so
                # that is what is published when the extraction is not PROVEN complete, the header
                # says `n=unparsed`, and every sentence below says "raw".
                # The proof is the instrument's own summary — "DRIFT — <n> stale (…), <n>
                # declared-but-absent, <n> unsourced" — which a partial extraction cannot satisfy.
                # ⛔ ALL THREE LABELS MUST PARSE, NOT JUST THE FIRST (review round 12, reproduced). The
                # sum used `${_fb:-0}`/`${_fc:-0}`, so an instrument whose OTHER classes are labelled
                # differently — `2 missing` instead of `2 declared-but-absent` — silently reduced the
                # proof to the stale count alone: measured with 3 STALE + 2 DECLARED-BUT-ABSENT rows and
                # the summary "3 stale …, 2 missing, 0 unsourced", matched 3 == expect 3 took the COMPLETE
                # arm and published `farm_n=3` / "every one named in <file>" with the two absent names in
                # NEITHER the artifact NOR the record. A lagging farmed copy is exactly the premise this
                # arm exists for, so an unparseable label means the proof is ABSENT, not that the class
                # counted zero.
                # ⛔ ONE POPULATION FOR "HOW MUCH OUTPUT IS THERE" (VGATE round 14, measured). The
                # excerpt prints the blank-stripped population while the elision counted `grep -c .`
                # over the RAW text — `grep -c .` counts a whitespace-only line, so 12 rows + one
                # 3-space line + summary read as "and 3 more line(s)" while only 2 were withheld. The
                # stripped population is computed ONCE here, before any decision reads it.
                FARM_OUT_NB="$(printf '%s\n' "$FARM_OUT" | grep -v '^[[:space:]]*$' || true)"
                FARM_OUT_LINES=0
                [ -n "$FARM_OUT_NB" ] && FARM_OUT_LINES="$(printf '%s\n' "$FARM_OUT_NB" | grep -c . || true)"
                FARM_EXPECT="$(farm_sum_count "$FARM_OUT")"
                FARM_ROWS_RAW=0; PERSIST_BODY="$FARM_ROWS"; FARM_RAW_WHY=""
                HDR_NOTE="n=$FARM_NROWS (the rows below are EXACTLY this run; farm_rows= in harness-apply.status is the currency indicator)"
                if [ "$FARM_NROWS" -eq 0 ] && [ "$FARM_OUT_LINES" -eq 0 ]; then
                    # ⛔ NO OUTPUT AT ALL IS ITS OWN STATE (review round 13; the note was DEAD CODE
                    # until VGATE round 14 — it was assigned after `publish_farm_rows` had already read
                    # the old one, so a silent instrument still published "the RAW output follows
                    # verbatim" over a header-only file).
                    # ⛔ AND ITS BODY IS EMPTY (review round 16, measured). The state is DEFINED as "no
                    # blank-stripped line", but it persisted the UNSTRIPPED output — so a checker that
                    # printed one whitespace-only line wrote a stray body line into the artifact that
                    # says "no name in this file because none was printed", and `wc -l - 1` counted a row.
                    FARM_ROWS_RAW=1; PERSIST_BODY=""; FARM_RAW_WHY=empty
                    HDR_NOTE="n=unparsed (the instrument printed NO output for a RED grade — farm_n=unparsed says the count is UNKNOWN, and there is no name in this file because none was printed)"
                elif [ "$FARM_NROWS" -eq 0 ]; then
                    FARM_ROWS_RAW=1; PERSIST_BODY="$FARM_OUT"; FARM_RAW_WHY=zero
                    HDR_NOTE="n=unparsed (NO row matched this pass's extractor — the instrument's RAW output follows verbatim; farm_n=unparsed says the count is UNKNOWN, not that nothing drifted)"
                elif [ -z "$FARM_EXPECT" ]; then
                    # ⛔ AN ABSENT OR UNREADABLE PROOF IS NOT PROOF (review round 11, reproduced). The
                    # branch below used to read `[ -n "$FARM_EXPECT" ] && …`, so an instrument that
                    # printed its drift rows but NO readable `DRIFT — <n> stale …` summary fell through
                    # to the COMPLETE arm: header "EXACTLY this run", `farm_n=<matched>`, detail "N
                    # row(s), every one named in <file>" — over an extraction nothing had checked. A
                    # re-worded or pre-summary farmed copy is exactly the premise this whole arm exists
                    # for, so "cannot prove it" must take the same door as "proved it wrong".
                    FARM_ROWS_RAW=1; PERSIST_BODY="$FARM_OUT"; FARM_RAW_WHY=noproof
                    # ⛔ AND THE NOTE MUST NAME THE RIGHT DEFECT (review round 26, measured: this arm
                    # covers TWO sub-states — no summary printed at all, and a summary this pass could
                    # not PARSE (one of the three labels missing or unreadable) — and the note claimed the
                    # first for both, so an artifact whose summary WAS printed told its reader "no readable
                    # summary" while `detail=` said "no readable or complete". The wording covers both.)
                    HDR_NOTE="n=unparsed (no COMPLETE, parsable 'DRIFT — <n> stale …, <n> declared-but-absent, <n> unsourced' summary (either none was printed or a label did not parse), so this pass cannot PROVE its $FARM_NROWS extracted row(s) are all of them — the instrument's output follows verbatim; farm_n=unparsed)"
                elif [ "$FARM_NROWS" -ne "$FARM_EXPECT" ]; then
                    FARM_ROWS_RAW=1; PERSIST_BODY="$FARM_OUT"; FARM_RAW_WHY=partial
                    if [ "$FARM_NROWS" -lt "$FARM_EXPECT" ]; then
                        HDR_NOTE="n=unparsed (this pass's extractor matched $FARM_NROWS row(s), the instrument reports $FARM_EXPECT — the names it could not match are in the RAW output that follows verbatim; farm_n=unparsed)"
                    else
                        HDR_NOTE="n=unparsed (this pass's extractor matched $FARM_NROWS row(s), MORE than the $FARM_EXPECT the instrument reports — its vocabulary is too wide, so a row it named may not be drift; the RAW output follows verbatim, farm_n=unparsed)"
                    fi
                fi
                # ⛔ EVERY ROW IS PERSISTED, NOT JUST THE EXCERPT (tortoise#10114 arm 2). The journal
                # keeps a bounded human view, but the durable answer to "which files have drifted" is
                # this file, written atomically (temp + rename) so a reader never sees a half list, and
                # named in the record (`farm_rows=`) so it is reachable without reading the journal.
                # A truncation that is only COUNTED is not a check that names each drifting file:
                # measured on the `cmux` cell, 30 rows — 12 named, 18 counted, 0 named anywhere durable.
                # The ONE write path lives in `publish_farm_rows` (the same function the `farm-unknown`
                # arm uses, so the two can never drift apart).
                publish_farm_rows "$PERSIST_BODY" "$HDR_NOTE"
                # ⛔ `farm_n=unparsed` ON THE RAW ARM, NEVER `0` (review round 6). `farm_n=0` already
                # means "the farm matched" in every other record, so a RED record carrying `0` reads as
                # "zero rows drifted" — one field with two meanings is the class this pass deletes.
                # Nothing reads `farm_n` numerically (fleet-health parses key=value and ignores it), so
                # the value is free to carry the truth: a count when the extraction parsed, `unparsed`
                # when it did not, `not-graded` when no grade was produced.
                if [ "$FARM_ROWS_RAW" = 1 ]; then REC_FARM_NROWS=unparsed; else REC_FARM_NROWS="$FARM_NROWS"; fi
                # ⛔ THE JOURNAL EXCERPT IS THE EXTRACTED ROWS EVEN ON THE RAW ARM (review round 11).
                # It used to `head -12` the PERSIST body, i.e. the instrument's RAW output — while the
                # "… and N more" line below counted EXTRACTED rows, so a 34-line report whose drift rows
                # came last printed twelve `ok`/header lines and then said "and 2 more row(s) — ALL 14
                # are named in <file>". Two different populations in one journal block. The bounded
                # human view is now always the rows THIS PASS matched; the file still carries everything
                # (raw, when the extraction is unproven).
                FARM_EXCERPT="$FARM_ROWS"
                if [ "$FARM_NROWS" -eq 0 ]; then
                    # ⛔ ONE POPULATION, ONE COUNT (review round 12, reproduced). The excerpt was
                    # `head -12` of the raw output while the elision counted `grep -c .` — NON-BLANK
                    # lines — and the real instrument prints a blank line before its summary
                    # (the instrument prints it after its rows). Measured: 11 rows + a blank + the summary (13 lines,
                    # 12 non-blank) printed a 12-line excerpt that swallowed the summary, then said
                    # nothing at all because `12 -gt 12` is false; 20 rows + 4 blanks printed 12 lines
                    # holding 10 rows and claimed "and 8 more line(s)". Blanks are dropped ONCE, in the
                    # population both the excerpt and the arithmetic read.
                    FARM_EXCERPT="$FARM_OUT_NB"
                fi
                if [ -n "$FARM_EXCERPT" ]; then
                    printf '%s\n' "$FARM_EXCERPT" | head -12 | while IFS= read -r _row; do
                        log_line "farm:   $_row"
                    done
                fi
                if [ "$FARM_ROWS_RAW" = 1 ]; then
                    if [ "$FARM_ROWS_OK" = 1 ]; then
                        # ⛔ THE EXCERPT ABOVE IS NOT THE RAW OUTPUT WHENEVER ANYTHING WAS EXTRACTED
                        # (VGATE round 12, measured on the noproof arm): the excerpt is now ALWAYS the
                        # rows this pass matched, so "the RAW output above" pointed at matched rows —
                        # the same two-populations-in-one-block defect this round removed from the
                        # excerpt. It stays truthful only on the zero-extraction arm, where the
                        # excerpt fallback really is the instrument's output.
                        if [ "$FARM_RAW_WHY" = empty ]; then
                            log_line "farm:   the instrument printed NO output for a red grade — there is no name to publish, and NO output is not a pass"
                        elif [ "$FARM_NROWS" -eq 0 ]; then
                            log_line "farm:   the extraction was NOT PROVEN complete — the instrument's RAW output above is published in $REC_FARM_ROWS"
                        else
                            log_line "farm:   the extraction was NOT PROVEN complete — the excerpt above is the rows THIS PASS matched; the instrument's RAW output is published in $REC_FARM_ROWS"
                        fi
                    elif [ "$FARM_RAW_WHY" = empty ]; then
                        # ⛔ NO OUTPUT AND NO TEMP FILE IS NOT "RAW OUTPUT COULD NOT BE PERSISTED" (review
                        # round 17, measured): with a directory at the rows path, a mute instrument printed
                        # a sentence about raw output it never produced, over an excerpt of no lines.
                        log_line "farm:   the instrument printed NO output for a red grade, and the header-only artifact could not be published ($REC_FARM_ROWS) — there is no name to lose"
                    else
                        log_line "farm:   the extraction was NOT PROVEN complete, and the RAW output could not be persisted ($REC_FARM_ROWS) — only the line(s) excerpted above are in this run's output, and any past the 12-line excerpt are named nowhere"
                    fi
                elif [ "$FARM_ROWS_OK" != 1 ] && [ "$FARM_NROWS" -gt 0 ] && [ "$FARM_NROWS" -le 12 ]; then
                    # ⛔ A FAILED PUBLISH IS NOT ONLY AN ELISION PROBLEM (review round 30, measured). The
                    # durability sentence lived inside `if [ "$FARM_NROWS" -gt 12 ]`, so a COMPLETE
                    # extraction of 3 rows with the artifact path blocked said nothing at all about
                    # durability: the journal printed the rows, the remedy, and stopped — while the doc
                    # promises the journal says in as many words that those names are durable nowhere,
                    # and a reader who trusts it opens whatever an EARLIER pass left at the fixed path
                    # (whose header is the previous run's, reading `n=3 (EXACTLY this run)`). The record
                    # was right; the log was the surface that lied.
                    # ⛔ AND IT OWNS ONLY THE NON-ELIDED STATE (VGATE round 30, measured): with more than
                    # 12 rows the excerpt holds 12 and the `-gt 12` arm below says "rows 13..N are named
                    # NOWHERE durable", so firing here too printed "the 15 row(s) above" over 12 printed
                    # rows AND said the failure twice. The cut arm owns that state; this one owns the
                    # state that has no other sentence.
                    log_line "farm:   the full list could not be persisted ($REC_FARM_ROWS) — the $FARM_NROWS row(s) above are in this run's output only, and a stale artifact may still sit at that path"
                fi
                if [ "$FARM_NROWS" -gt 12 ]; then
                    # The count is NOT the answer (tortoise#10114 arm 2): the other rows are named, and
                    # this line says where — an operator reading the journal must be able to get from
                    # "18 more" to the 18 names without re-running the instrument by hand.
                    if [ "$FARM_ROWS_OK" = 1 ]; then
                        log_line "farm:   … and $((FARM_NROWS - 12)) more row(s) — ALL $FARM_NROWS are named in $REC_FARM_ROWS"
                    else
                        log_line "farm:   … and $((FARM_NROWS - 12)) more row(s) — the full list could NOT be persisted ($REC_FARM_ROWS), so rows 13..$FARM_NROWS are named NOWHERE durable"
                    fi
                elif [ "$FARM_NROWS" -eq 0 ]; then
                    # ⛔ AND WHEN NOTHING WAS EXTRACTED THE EXCERPT IS RAW LINES, so the elision is
                    # counted in LINES (review round 11). `$FARM_NROWS - 12` is -12 here and never
                    # fired, so a 30-line raw output truncated to 12 said nothing at all about the
                    # other 18 lines and whether they were durable.
                    _oline="$FARM_OUT_LINES"
                    if [ "$_oline" -gt 12 ]; then
                        if [ "$FARM_ROWS_OK" = 1 ]; then
                            log_line "farm:   … and $((_oline - 12)) more line(s) of the instrument's output — ALL $_oline are named in $REC_FARM_ROWS"
                        else
                            log_line "farm:   … and $((_oline - 12)) more line(s) of the instrument's output — the full output could NOT be persisted ($REC_FARM_ROWS), so lines 13..$_oline are named NOWHERE durable"
                        fi
                    fi
                    unset _oline
                fi
                [ -n "$FARM_REMEDY" ] && printf '%s\n' "$FARM_REMEDY" | while IFS= read -r _row; do
                    log_line "farm:   $_row"
                done
                if [ "$FARM_ROWS_RAW" = 1 ] && [ "$FARM_ROWS_OK" = 1 ]; then
                    # ⛔ NO PATH IN THESE SENTENCES (review round 11). `detail=` is cut at 240, and the
                    # prefix already spends ~106 chars on the farm + ref, so "… published verbatim in
                    # <path>" was cut MID-FILENAME: key=value readers printed a path that does not
                    # exist. `farm_rows=` in the same record carries the path, so the sentence names the
                    # FIELD instead.
                    case "$FARM_RAW_WHY" in
                        empty)   FARM_ROW_SENTENCE="the instrument printed NO output for a red grade, so no drifting file is named anywhere" ;;
                        noproof) FARM_ROW_SENTENCE="its extraction is unproven (no readable or complete 'DRIFT' summary); RAW output published verbatim (see farm_rows=)" ;;
                        partial)
                            # ⛔ AN OVER-MATCH IS NOT A SHORTFALL (review round 12, measured): "matched
                            # only 5 of the 3 row(s)" told a reader 2 rows were MISSING when 2 EXTRA
                            # were matched — the widened-vocabulary case, described backwards. The two
                            # directions now have their own sentences.
                            if [ "$FARM_NROWS" -lt "$FARM_EXPECT" ]; then
                                FARM_ROW_SENTENCE="matched only $FARM_NROWS of the $FARM_EXPECT row(s) the instrument reports; its RAW output is published verbatim (see farm_rows=)"
                            else
                                FARM_ROW_SENTENCE="matched $FARM_NROWS row(s), MORE than the $FARM_EXPECT the instrument reports; its RAW output is published verbatim (see farm_rows=)"
                            fi ;;
                        *)       FARM_ROW_SENTENCE="no row matched this pass's extractor; its RAW output is published verbatim (see farm_rows=)" ;;
                    esac
                elif [ "$FARM_ROWS_OK" = 1 ]; then
                    # ⛔ NO PATH HERE EITHER (review round 12, measured): with a 140-char farm path plus
                    # the state path the prefix + sentence exceeded 240 and `detail=` ended
                    # "… every one named in /tmp/meas2/state/h" — a path that does not exist, the exact
                    # defect fixed above for the raw arms. Threshold measured: farm+state ≥ 132 chars.
                    FARM_ROW_SENTENCE="${FARM_NROWS} row(s), every one named (see farm_rows=)"
                elif [ "$FARM_ROWS_RAW" = 1 ] && [ "$FARM_RAW_WHY" = empty ]; then
                    FARM_ROW_SENTENCE="the instrument printed NO output for a red grade, and the header-only artifact could not be published either (farm_rows= names the failure)"
                elif [ "$FARM_ROWS_RAW" = 1 ]; then
                    FARM_ROW_SENTENCE="the instrument's RAW output could not be persisted (farm_rows= names the failure, not a file)"
                else
                    FARM_ROW_SENTENCE="${FARM_NROWS} row(s) matched, and the full list could not be persisted (farm_rows= names the failure, not a file)"
                fi
                # ⛔ THE SENTENCE LEADS, THE PATH FOLLOWS (review round 13, measured). With the farm
                # path first, a 92-char dest pushed the diagnosis past the 240-byte bound
                # (`…; RAW output published verba`) and a 223-char dest left ONLY the path — the record
                # then stated no diagnosis at all. The arm sentence is what a reader must never lose;
                # the farm path it names is ALSO in the artifact's own `dest=` header.
                # ⛔ NEVER PROMISE A REMEDY SOMEONE COULD NOT SEND (review round 14, measured). The
                # sentence said "with the instrument's own remedy" UNCONDITIONALLY while
                # `REC_REMEDY="$FARM_REMEDY"` is empty whenever the instrument printed no `Next:` block
                # (a mis-worded farmed copy, or one that died after its rows) — and `write_record` then
                # emitted `remedy=none`, i.e. a refusal that names a defect and leaves nobody an action,
                # the very class the `remedy=` field exists to remove. Without a forwarded block the
                # field says so and names the manual route.
                # ⛔ AND THE CLAUSE IS NOT REPEATED IN `detail=` (review round 14, measured). It used to
                # sit after `$FARM_DEST`, i.e. at the very end of a 240-byte field whose tail is what
                # gets cut — measured: 279 bytes, cut at 241, the clause truncated mid-word, on a
                # fixture whose farm path alone is 60 chars. The remedy is `remedy=`'s job, and that
                # field is never truncated (it is bounded by construction, not by `cut`).
                if [ -n "$FARM_REMEDY" ]; then
                    REC_REMEDY="$FARM_REMEDY"
                else
                    REC_REMEDY="the instrument printed no 'Next:' remedy — read farm_rows= (or this run's excerpt) and re-run check-farm-drift.sh by hand"
                fi
                finish 0 24 "farm: DRIFT — $FARM_ROW_SENTENCE; $FARM_DEST is NOT the code $REF ships" ;;
            *)
                REC_ACTION=farm-unknown
                # ⛔ BUT WHAT IT DID PRINT IS STILL PUBLISHED (review round 13, reproduced). The
                # instrument prints its per-file rows BEFORE the exits that give up after GRADING (the
                # instrument's pre-loop exits have no rows to publish — see `publish_farm_rows`), so
                # "no grade" never meant "nothing was
                # reported": measured, 2 UNSOURCED rows then exit 2 was recorded as `farm_rows=not-graded`
                # with both names durable NOWHERE. `action=farm-unknown` still says no grade was
                # produced; the file now carries the instrument's output when it printed any.
                if [ -n "$(printf '%s\n' "$FARM_OUT" | grep -v '^[[:space:]]*$' || true)" ]; then
                    publish_farm_rows "$FARM_OUT" "n=unparsed (NO GRADE — the instrument exited $FARM_RC, so this is its output verbatim, not a complete list; farm_n=not-graded)"
                    REC_FARM_NROWS=not-graded
                fi
                # ⛔ AND ITS REMEDY, WHICH IS THE ONE THING THIS ARM OFTEN HAS (review round 16,
                # measured: `remedy=none` beside an artifact holding the instrument's `Next:` block).
                if [ -n "$FARM_REMEDY" ]; then
                    REC_REMEDY="$FARM_REMEDY"
                else
                    REC_REMEDY="the instrument printed no 'Next:' remedy — read farm_rows= (or this run's output) and re-run check-farm-drift.sh by hand"
                fi
                # ⛔ `not-graded` STAYS HERE ON PURPOSE (review round 3): an UNREADABLE grade is not a
                # grade, and the rows fields must never imply one. `action=farm-unknown` is the field
                # that says the farm WAS looked at and could not be read — the two together are the
                # truth, and neither alone would be.
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
