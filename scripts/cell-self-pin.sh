#!/usr/bin/env bash
# cell-self-pin.sh — keep the layer this cell EXECUTES on origin/main, on a clock (agent-infra #3194).
#
#   ./cell-self-pin.sh                 # one pass: resolve the layer, no-op if current, else apply --force
#   ./cell-self-pin.sh --status        # what it resolved, where it came from, the LAST OUTCOME (it FETCHES)
#   ./cell-self-pin.sh --status-nofetch # the same reading against the LOCAL ref, saying it may be stale
#   ./cell-self-pin.sh --dry-run       # resolve + decide + print: change NOTHING, fetch NOTHING
#   ./cell-self-pin.sh --install [--takeover]   # render + verify + PLACE the pass + install the units
#   ./cell-self-pin.sh --print-unit    # render the units to stdout ONLY — writes no file, places no pass
#   ./cell-self-pin.sh --print-dropin-roots  # the systemd system-unit dirs the drop-in gate scans
#   ./cell-self-pin.sh --help
#
# Exit (pass):   0 = current or applied (and ONE actuator on the pin); 11 = the pin RECORD was missing
#                and was MENDED to the tree `apply` created; 1 = apply failed, the record did not
#                converge, or a RE-ARMED second actuator could not be retired; 2 = the layer could NOT
#                be resolved (loud, named).
# Exit (status): 0 = current, 1 = DRIFT, 2 = UNKNOWN — the layer could not be resolved, OR the ref could
#                not be REFRESHED (an unrefreshed ref cannot tell current from DRIFT, so it decides
#                nothing) — the repo's own `0 match / 1 drift / 2 unknown` vocabulary
#                (scripts/check-deployed-drift.sh), reused rather than invented a third time (#1178).
#
# ── WHY THIS FILE EXISTS (#3194) ────────────────────────────────────────────────────────────────
# `cell-self-pin.service` had exactly this job and could never do it. Its unit drop-in shipped
# `WorkingDirectory=/tmp/cell-ai` and its script began `cd /tmp/cell-ai || REFUSING`. `/tmp/cell-ai` is
# the PROVISIONING RECIPE's clone; it is not a live-cell invariant, and on cell-1 it was absent, so
# systemd failed the unit at the CHDIR step with **200/CHDIR every ten minutes for the box's whole
# life**. MEASURED on cell-1: the pin RECORD said `6da181efd` (= origin/main, carrying #3108) while the
# controller's pid executed `…/harness/56e59010825d/…` — 17 commits behind, a directory that no longer
# exists. #3108 had merged eight hours earlier and had reached no box: deployed code that was never
# deployed.
#
# ⛔ THE LESSON IS NOT "USE A DIFFERENT PATH". A hard-coded path in a rendered unit is stale the moment
# the directory it names goes away, and NOTHING turns that stale into a signal — the unit's own colour
# stayed green. So this pass DERIVES the layer on every tick, from the same record the controller reads,
# and it REFUSES LOUDLY (exit 2, a named reason) when NEITHER the record, NOR the pin root, NOR `$HARNESS`
# names a tree it can pin from. ⛔ The two FALLBACKS (newest tree under the pin root, then `$HARNESS`) are a
# documented narrowing of that sentence, not an exception to it: each one says on STDERR that the tree it
# chose is NOT proven to be the layer the controller executes, so the tick's colour is about the pin, never
# a claim that the executed layer was identified.
#
# ── WHAT `--install` RESOLVES, AND WHERE EACH VALUE COMES FROM ─────────────────────────────────
#   base       ${CELL_HOME} if given, else DERIVED             — this file, the unit's rendered
#                                                   `Environment=CELL_HOME=` and every sibling script
#                                                   now agree on ONE derivation: scripts/lib/cell-home.sh
#                                                   (agent-infra#3453). ⛔ Until that change the
#                                                   SUPERVISOR's own fallback was `/tmp/cell-home`
#                                                   while this file's was `$HOME`, i.e. two answers to
#                                                   one question — the #2215 skew installed into
#                                                   /etc/systemd/system. That divergence is GONE: both
#                                                   sides consume the resolver, whose precedence is
#                                                   CELL_HOME -> the account's passwd home -> $HOME
#                                                   (non-volatile only) -> the fleet default.
#   record     ${HARNESS_PIN_FILE}                — default $CELL_HOME/.harness-path: the file
#              (= $CELL_HOME/.harness-path)          cloud-cell-supervisor.sh's `start` READS to choose
#                                                   the tree it execs (`cmd_start` → `$HARNESS`).
#   pin root   ${HARNESS_PIN_DIR}                 — default $CELL_HOME/harness (one worktree per commit).
#   ref        ${HARNESS_REF}                     — default origin/main.
#   ExecStart  ${CELL_HOME}/.pi/agent/scripts/cell-self-pin.sh ALWAYS — the one path `--install` places
#              this file's own bytes at, under the one root a running cell keeps. ⛔ THERE IS NO
#              FALLBACK TO "this file's own resolved path": that was a bug the older header documented
#              as a feature. Rendering from a checkout (a lane worktree, a /tmp copy) produced
#              `ExecStart=/bin/bash /home/…/.worktrees/ai-3194/scripts/cell-self-pin.sh`, and the worktree
#              is PRUNED when the lane merges, leaving 203/EXEC every tick. `pin_script_path` therefore
#              always prints the $CELL_HOME copy and REFUSES when it cannot find its own source bytes to
#              place there — a refusal, never a path that outlives nothing.
#   WorkingDirectory                          — **none**. See below.
#
# ⛔ `WorkingDirectory=` IS DELIBERATELY ABSENT FROM THE RENDERED UNIT, and that is the whole fix.
# `WorkingDirectory=` refuses to start a unit BEFORE any line of the payload runs (`EXIT_CHDIR` = 200,
# `systemd.exec(5)`) unless it is given the `-` prefix (which makes the failure non-fatal). It is
# therefore the worst possible place to name a directory that is not a live-cell invariant — and it is
# not the ONLY directive with that shape (`EnvironmentFile=`, `RootDirectory=` and `User=` resolve before
# exec too). The rule this file holds is narrower than a superlative: refuse the directives whose
# ABSENCE-from-a-running-cell turns a pin into a unit that never began. With no `WorkingDirectory=`, systemd starts the oneshot in `/` and
# THIS pass `cd`s itself to the layer it just resolved, so "the directory is missing" becomes a named
# non-zero exit with a remedy, instead of a unit that never began.
#
# ⛔ AND `ConditionPathExists=` IS DELIBERATELY NOT USED EITHER. A failed CONDITION *skips* activation
# and leaves the unit's result green (systemd.unit(5)) — so the missing-directory case would be a
# SILENT, GREEN no-op: strictly worse than the 200/CHDIR it replaced, because the old one at least
# coloured the unit red. The correct outcome here is a RED that is TRUE, produced by the payload.
#
# ── ONE ACTUATOR PER PIN, AND WHAT `--install` DOES ABOUT IT ────────────────────────────────────
# ⛔ THIS FILE IS A SECOND SCHEDULED ACTUATOR FOR A JOB `harness-apply-pass.sh` ALREADY DOES, and that
# is a fact to be handled, not papered over. `eldato-harness-apply.timer` runs every ten minutes, calls
# the same `apply --force --pin-only`, already owns the `mended` state and writes an instrumented status
# file, and `cloud-cell-bringup.sh` installs it on EVERY cell (it dies if it cannot). Two mutating
# actors on one pin is a RACE, not redundancy — so this file never silently becomes the second one:
#   · `--install` REFUSES while `eldato-harness-apply.timer` is enabled in EITHER systemd manager —
#     the SYSTEM one and the `--user` one the sibling installer negotiates — and NAMES the scope it saw;
#   · `--install --takeover` is the ONE-ACTOR MIGRATION: place and verify the units FIRST, then
#     disable+stop that timer in EVERY manager that carries it, VERIFY each disable, and only then
#     `enable --now` this unit. `--takeover` is an operator's explicit decision to retire the shipped
#     actuator on this box; a retirement that does not take is a REFUSAL, never two actors — and an
#     install that fails after a retirement ROLLS IT BACK, so the migration never ends at zero actors;
#   · ⛔ AND INSTALL TIME IS NOT ENOUGH: the invariant is RE-CHECKED ON EVERY TICK. `bringup`'s
#     `check_harness_apply` re-runs the sibling installer, whose whole job is to re-arm a timer
#     somebody disabled by hand — so a second actor comes BACK after a successful `--takeover`, with
#     no signal. `do_pass` reads both managers every tick and re-takes the pin (retire, read back,
#     say so), because an invariant nothing re-checks is not an invariant.
# ⛔ AND NOTHING INSTALLS THIS UNIT AUTOMATICALLY. `cloud-cell-bringup.sh` carries no reference to it,
# deliberately: retiring a shipped, tested actuator on every cell is an operator decision, not a side
# effect of a merge. Until that decision is taken, this file is the INSTRUMENT plus its migration and
# `harness-apply-pass.sh` stays the shipped default. A merge of this file is not "the fleet changed":
# adoption is `--install --takeover`, on the box, by a human or a bring-up step that says so.
#
# ── WHAT IT ACTUALLY DOES (it re-implements no activation) ─────────────────────────────────────
# `cloud-cell-supervisor.sh apply` already fetches agent-infra main and pins a detached per-commit
# worktree (#1745); the pin deadlock (#2700 C5) is that `apply` refuses while a controller runs, and a
# live cell's controller always runs — so the verb this pass calls is `apply --force --pin-only`, and it
# calls the copy in the RESOLVED tree, not a bootstrap clone's. ⛔ BOTH FLAGS: `--pin-only` because a bare
# `apply` dies on a running controller, and `--force` WITHOUT it re-seeds the state dir that controller is
# executing from (the #2215 skew). `--pin-only` also writes no state stamp, so this pass reads the pinned
# HEAD out of the RECORD the controller acts on rather than out of the stamp.
set -u

# ⛔ REMEMBERED BEFORE IT IS DEFAULTED, because `CELL_HOME_GIVEN` is what `print_unit` refuses on. The
# DEFAULT is not a second opinion any more: `scripts/lib/cell-home.sh` derives it (agent-infra#3453),
# and `cloud-cell-supervisor.sh` — the reader of the record this file pins — consumes the SAME resolver,
# so "the pass derives from $HOME while the controller derives from /tmp/cell-home" can no longer happen.
# Rendering still refuses an UNSET CELL_HOME (see `print_unit`): the value becomes permanent in
# /etc/systemd/system, and at that one moment an operator saying which home is the cell's is worth
# requiring. A bare PASS keeps the tolerant default, because a manual run must not be refused over an
# environment variable.
# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""     # under `bash -s` $0 is literally `bash` -> `.`
PIN_SELF_DIR=""
if [ -n "$_SELF" ]; then PIN_SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd -P)"; fi
CELL_HOME_LIB="${PIN_SELF_DIR:+$PIN_SELF_DIR/lib/cell-home.sh}"
CELL_HOME_GIVEN="${CELL_HOME:-}"
if [ -n "$CELL_HOME_LIB" ] && [ -r "$CELL_HOME_LIB" ]; then
  . "$CELL_HOME_LIB"
  CELL_HOME="$(cell_home_resolve)"
else
  CELL_HOME="${CELL_HOME:-${HOME:-}}"
fi
[ -n "$CELL_HOME" ] || { printf '%s: FATAL: %s is not readable and neither CELL_HOME nor HOME is set — refusing to default the cell home (agent-infra#3453)\n' "${0##*/}" "${CELL_HOME_LIB:-lib/cell-home.sh}" >&2; exit 78; }
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
HARNESS_REF="${HARNESS_REF:-origin/main}"
# ⛔ THE FETCH TARGET IS THE REF THE COMPARISON USES. `HARNESS_REF` is a documented knob (see the header),
# and both verbs fetched `origin main` while DECIDING on `$HARNESS_REF` — so for any other value the pass
# refreshed one ref and compared another, and `--status` printed "`origin/rel` fetched just now" about a ref
# it never touched. A knob read one way and refreshed another is two facts pretending to be one, which is
# the #2215 skew this file exists to remove — one variable over.
ref_fetch_branch() { # the REMOTE branch to fetch for $HARNESS_REF — 1 when the spelling names ANOTHER remote
  local r
  # ⛔ THREE SPELLINGS NAME THE SAME REMOTE BRANCH, AND ONE OF THEM IS NOT A REMOTE REF AT ALL. Only
  # `origin/<b>` and `refs/heads/<b>` were stripped, so `refs/remotes/origin/<b>` — the canonical name of
  # the DEFAULT knob value, and the spelling the sibling reader accepts
  # (`git rev-parse refs/remotes/origin/main^{commit}`, rc=0) — was handed to `git fetch` verbatim as a
  # REMOTE source: `fatal: couldn't find remote ref refs/remotes/origin/main`, rc=128 (MEASURED). The tick
  # then exited 2 `fetch-failed` for EVER on a value that worked before this file decided on the fetched
  # commit, and the `2>/dev/null` on that fetch discarded git's reason, so the journal could not even say
  # why. `refs/remotes/origin/<b>` is this repo's tracking ref; the thing to ask the REMOTE for is `<b>`.
  # ⛔ AND ONLY `origin` MAY BE STRIPPED. A blanket `refs/remotes/*/*` arm turns
  # `refs/remotes/upstream/main` into the fetch source `main` — i.e. into `ORIGIN`'s `main` — so the run
  # answers a DIFFERENT question than the one asked, prints it under the other ref's name, and `--status`
  # reports `current` + exit 0 for a ref it never fetched (MEASURED: `refs/remotes/upstream/main` printed
  # origin/main's tip as `(refs/remotes/upstream/main fetched just now)` / `verdict current` while the
  # `--status-nofetch` reading of the same ref said DRIFT). Every fetch in this file is hardcoded to
  # `origin`, so a spelling that names another remote has no honest answer here: REFUSE it by name.
  # ⛔ IT RETURNS 1 RATHER THAN CALLING `loud`: both call sites run this in a COMMAND SUBSTITUTION, so an
  # `exit` from here would only leave the subshell and the caller would carry on with an empty branch.
  case "$HARNESS_REF" in
    refs/remotes/origin/*) r="${HARNESS_REF#refs/remotes/origin/}" ;;
    refs/remotes/*/*) return 1 ;;
    *) r="${HARNESS_REF#origin/}"; r="${r#refs/heads/}" ;;
  esac
  # ⛔ AN EMPTY BRANCH PART IS NOT `main`. The fallback here was `${r:-main}`, so a malformed spelling
  # (`origin/`, `refs/remotes/origin/`, `refs/heads/`) was silently RE-WRITTEN to `main`: `--status` fetched
  # `main`, printed `(origin/ fetched just now)` and `origin/ <main's sha>`, and answered `verdict current`
  # + exit 0 about a name that resolves to nothing — while the SAME knob's `--status-nofetch` said UNKNOWN
  # and the timer's own verb refused with `ref-spelling` (MEASURED). Three surfaces of one knob disagreeing
  # is the #2215 skew, and the green one is the first screen an operator reads. Same rule as the arm above:
  # a spelling this fetch cannot answer is REFUSED by name, never answered from some other branch.
  # `HARNESS_REF` is defaulted to `origin/main` at the top of this file, so `r` is empty ONLY for a
  # malformed spelling — the default and every documented form still resolve.
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}
# ⛔ THE DECISION READS A REF THIS RUN OWNS, NOT `FETCH_HEAD`. `FETCH_HEAD` is an ordinary mutable file in
# the worktree, bound to no run: any other git process in the SAME tree that fetches between our fetch and
# our read is read as OUR result. That is not hypothetical here — `cloud-cell-supervisor.sh` has TWO `git … fetch --quiet origin main` sites that run in this very repository
# (`classify_harness` and `harness_apply`), and bring-up re-arms `eldato-harness-apply.timer`
# beside this unit by design, so two actors fetch in one tree. MEASURED: with the record at main's tip, a
# coexisting `git fetch origin main` made `--status` print a MAIN commit under the label `origin/rel` and
# answer `current` + exit 0 — a foreign fetch greening a stale layer.
# ⛔ AND THE DESTINATION IS KEYED BY SOURCE, because ONE shared name is not a ref a run owns. `HARNESS_REF`
# is a documented knob, so a manual `--status` (or the timer) can be asking about `origin/rel` while another
# invocation asks about `main`; with a single destination the two invocations write the SAME ref with
# DIFFERENT sources, and the value is last-writer-wins across runs, not owned by either — the same skew the
# `FETCH_HEAD` bug had, one process further out (measured: a 12-way concurrent fetch of one refspec returned
# 8x success, so contention mostly serialises and silently overwrites rather than failing closed). Keyed by
# the source instead, the two writers cannot collide AT ALL, and two runs asking the SAME question write the
# same commit — contention is idempotent rather than a race.
PIN_FETCH_REF_BASE="refs/cell-self-pin/fetch"
pin_fetch_ref() { # <fetch branch> — the run-private destination for ONE source
  printf '%s-%s\n' "$PIN_FETCH_REF_BASE" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}
HARNESS="${HARNESS:-}"
O="${O:-$CELL_HOME/orchestrator}"
STAMP="$O/.agent-infra-stamp.json"
INTERVAL_MIN="${CELL_SELF_PIN_INTERVAL_MIN:-10}"
TEMPLATES_DIR="${TEMPLATES_DIR:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || SELF_DIR=""

log() { printf '%s self-pin: %s\n' "$(date -u +%FT%TZ)" "$*"; }
err() { printf '%s self-pin: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# record_outcome — ONE line, read back by `--status`'s "last outcome". A verb that advertises a last
# outcome and prints none is a claim this file does not keep; journald is not an answer to "what did
# this timer do last tick" for an operator reading one screen. Best-effort by design: a record that
# cannot be written must never turn a correct pass into a RED.
record_outcome() {
  mkdir -p "$O" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >"$O/self-pin.last" 2>/dev/null || true
  return 0
}

# loud() — the shape of EVERY unresolvable state. stderr (so journald carries it), a NAMED reason, the
# readings it decided from, and exit 2. Never a silent `exit 1`: #3194's cost was a unit whose failure
# said nothing an operator could act on.
loud() { # <code> <reason> [detail…]
  local code="$1" reason="$2"; shift 2
  record_outcome "unresolved($reason) $*"
  err "UNRESOLVED($reason): $*"
  err "  base=${CELL_HOME} pin_file=${HARNESS_PIN_FILE} pin_dir=${HARNESS_PIN_DIR} ref=${HARNESS_REF}"
  err "  This is a RED, not a retry: the cell's executing layer could not be identified, so nothing was"
  err "  pinned. Remedy: cd <layer> && git fetch origin main && bash <layer>/scripts/cloud-cell-supervisor.sh apply --force --pin-only"
  err "  (--pin-only, BECAUSE a live cell always runs a controller: a bare 'apply' dies on it, and a bare"
  err "  '--force' re-seeds the state dir the running controller is executing from — the #2215 skew.)"
  exit "$code"
}

# layer_dir <path> — a candidate tree, accepted only if it is a directory AND git can answer from it.
# `git -C` is the test that matters: a pin worktree whose gitdir was reclaimed (cell-1's shape — every
# worktree's `.git` names `<bare>/.git/worktrees/<sha12>`) is a directory full of files that NO git
# command can operate on, and pinning from it is impossible. Accepting it on `-d` alone would be the
# same class of lie as the unit this replaces.
layer_ok() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1
}

# resolve_layer — the pin tree, derived from the record the CONTROLLER reads. Order is deliberate:
# the record first (it is what `start` execs, so the pin and the run stay one fact), then the pin root's
# newest child (a record that was lost still leaves the trees it named), then an operator's $HARNESS.
# ⛔ NOTHING HERE NAMES A BOOTSTRAP PATH. There is no fallback to a provisioning clone: a cell with no
# record and no pin root has no layer, and saying so is the point of this file.
resolve_layer() {
  local pin="" c best=""
  pin="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
  if layer_ok "$pin"; then printf '%s\n' "$(git -C "$pin" rev-parse --show-toplevel 2>/dev/null)"; return 0; fi
  if [ -n "$pin" ]; then
    err "the record ${HARNESS_PIN_FILE} names '${pin}', which no git command can answer from — IGNORING it (a record nobody can use is not a pin)"
  fi
  if [ -d "$HARNESS_PIN_DIR" ]; then
    # ⛔ NEWEST BY mtime, not lexicographic: a pin root holds one directory per commit and a sha12 is
    # random, so glob order picks an ARBITRARY commit — and it is that commit's supervisor which then
    # executes. A record nobody can read is already an error above; this fallback is the last resort.
    # ⛔ READ THE LISTING LINE BY LINE. `for c in $(ls -1dt …)` WORD-SPLITS on whitespace, so one pin
    # directory whose path contains a space splits into two candidates — and the first fragment can
    # still pass `layer_ok` as a parent and be pinned from. A process substitution keeps both the
    # listing and the assignment in THIS shell (no subshell), so `best` survives the loop.
    while IFS= read -r c; do
      [ -d "$c" ] || continue
      layer_ok "$c" || continue
      best="${c%/}"; break
    done < <(ls -1dt "$HARNESS_PIN_DIR"/*/ 2>/dev/null)
    if [ -n "$best" ]; then
      err "the record ${HARNESS_PIN_FILE} is unusable and the pin root ${HARNESS_PIN_DIR} names no layer it can use — falling back to the NEWEST tree there ('${best}'), which is NOT proven to be the layer the controller EXECUTES"
      printf '%s\n' "$(git -C "$best" rev-parse --show-toplevel 2>/dev/null)"; return 0
    fi
  fi
  if layer_ok "$HARNESS"; then
    err "no usable pin record and no layer under ${HARNESS_PIN_DIR} — falling back to HARNESS='${HARNESS}', which is NOT proven to be the layer the controller EXECUTES"
    printf '%s\n' "$(git -C "$HARNESS" rev-parse --show-toplevel 2>/dev/null)"; return 0
  fi
  return 1
}

# supervisor_in <tree-toplevel> — the existing verb, taken from the tree being pinned (NOT this file's
# repo, which may be a different commit than the one the box runs).
supervisor_in() {
  local t="$1"
  if [ -x "$t/scripts/cloud-cell-supervisor.sh" ] || [ -f "$t/scripts/cloud-cell-supervisor.sh" ]; then
    printf '%s\n' "$t/scripts/cloud-cell-supervisor.sh"; return 0
  fi
  # .harness-path records `<...>/scripts/orchestrator-harness`; accept that spelling too.
  if [ -f "$t/orchestrator-harness/cloud-cell-supervisor.sh" ]; then
    printf '%s\n' "$t/orchestrator-harness/cloud-cell-supervisor.sh"; return 0
  fi
  # ⛔ NO `$SELF_DIR` ARM. There was one, and it was a FALSE GREEN: it let a supervisor from THIS
  # file's own directory (a /tmp copy, a lane worktree, any tree at all) stand in for the resolved
  # layer, so the suite's "the pass follows .harness-path" leg passed through a supervisor belonging
  # to a DIFFERENT tree than the one being pinned — exactly the property the leg claimed to test.
  # A layer with no supervisor is a named RED (`loud 2 no-supervisor`), not a borrowed verb.
  return 1
}

read_stamp() { sed -n 's/.*"refCommit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAMP" 2>/dev/null | head -1; }

# pinned_head — the commit of the tree the RECORD names, i.e. the layer this cell is on. This is the
# reading that matters, and it is the same one `cloud-cell-supervisor.sh start` acts on. The stamp is
# NOT it: `apply --pin-only` deliberately does not write a stamp (it seeds no state dir), so a
# stamp-based comparison would report "drift" for ever on the very path a live cell uses.
pinned_head() {
  local pin; pin="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
  [ -n "$pin" ] || return 1
  git -C "$pin" rev-parse HEAD 2>/dev/null
}

# mend_record <target> — repoint a MISSING/EMPTY record at the tree `apply` just created for <target>.
# ⛔ WHY THIS EXISTS, precisely: `harness_apply` writes $HARNESS_PIN_FILE only inside its CHANGED branch
# (cloud-cell-supervisor.sh:2293 sets `HARNESS_APPLIED=unchanged` for a pin already at the tip; :2316 is
# the only write). So `apply --force --pin-only` on a box whose record was lost exits 0, writes NOTHING
# and reports `unchanged` — leaving this pass reading an empty record on every tick, for ever. That is
# #3133 (merged) one layer up: an unhealable RED is as useless as a false GREEN, and the recorded answer
# is the one `harness-apply-pass.sh` already uses — MEND the record to what the box actually runs, and
# report it with the code that vocabulary already owns (11, `mended`).
# ⛔ AND THESE LINE NUMBERS ARE A LOAD-BEARING CLAIM, NOT A PROSE NICETY: a reader deciding whether the hole
# above is real is being told where to look, so a pointer into the wrong function says "check here" about
# code that does not do the thing. They were `:2137`/`:2160`, correct at `eb7e4e81`, and were shifted by
# later merges from main (round-13 review, P2) — re-derived by grep at this head, not guessed.
# ⛔ AND IT MENDS ONLY FROM THE PIN ROOT. The tree it records is the per-commit worktree `apply` itself
# created for <target> (`$HARNESS_PIN_DIR/<sha12>`), exactly as `harness_apply` would have named it —
# never an operator's ad-hoc checkout, and never a tree that is not AT the target.
mend_record() {
  local target="$1" cand top
  [ -n "$target" ] || return 1
  cand="$HARNESS_PIN_DIR/$(printf '%s' "$target" | cut -c1-12)"
  layer_ok "$cand" || return 1
  [ "$(git -C "$cand" rev-parse HEAD 2>/dev/null)" = "$target" ] || return 1
  top="$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] && [ -d "$top/scripts/orchestrator-harness" ] || return 1
  mkdir -p "$(dirname "$HARNESS_PIN_FILE")" 2>/dev/null || true
  # The record names the HARNESS DIR, not the tree: that is the value `harness_apply` writes and the one
  # `start` execs ($HARNESS/orch-loop.sh). Writing the toplevel instead would "heal" the record into a
  # shape the controller cannot use.
  printf '%s\n' "$top/scripts/orchestrator-harness" >"$HARNESS_PIN_FILE" 2>/dev/null || return 1
  return 0
}

# ⛔ THE PIN VERB RESOLVES `$HARNESS_REF` **LOCALLY**; THIS FILE DECIDES ON THE COMMIT THE FETCH BROUGHT.
# They are two facts, and for a spelling that names a LOCAL ref they are DIFFERENT facts — so the pass could
# never converge, and the failure was neither silent nor honest:
#   · `apply --force --pin-only` runs `cloud-cell-supervisor.sh::harness_apply`, which fetches `origin main`
#     (HARDCODED — its own `fetch --quiet origin main` inside `harness_apply`) and then pins
#     `$(git rev-parse "$HARNESS_REF^{commit}")` (that function's `want=` line) — a LOCAL read;
#   · a fetch of `main` moves `refs/remotes/origin/main` and NEVER `refs/heads/main`, so `HARNESS_REF=main`
#     (or `refs/heads/main`) pins this repo's local branch, the record does not move, and `do_pass`'s containment
#     test REDs with STALE-RECORD — every ten minutes, for ever, while the box is in fact behind;
#   · the remedy the STALE-RECORD line prints (`git fetch origin main && apply --force --pin-only`) cannot
#     change the outcome either, because that fetch does not move the local branch it pins. An UNHEALABLE RED
#     is as useless as a false GREEN, and a useless remedy is worse than a name.
# MEASURED on a two-clone fixture, `HARNESS_REF=main`, tick after tick: `DRIFT … -- applying --force
# --pin-only` then `STALE-RECORD: … does not contain main …`, rc=1, with the pin tree never advancing.
# So the spelling is REFUSED — named, exit 2, BEFORE the mutation — instead of being run ten times an hour.
check_pin_resolution() { # <layer repo> <target commit> — 0 when the pin verb's OWN resolution is our target
  local repo="$1" target="$2" local_target
  local_target="$(git -C "$repo" rev-parse --verify --quiet "${HARNESS_REF}^{commit}" 2>/dev/null)" || local_target=""
  [ "$local_target" = "$target" ] && return 0
  if [ -z "$local_target" ]; then
    loud 2 ref-spelling "HARNESS_REF=${HARNESS_REF} resolves to no commit in ${repo}, and 'apply' pins what IT resolves locally, so the record could never advance. Use the remote spelling: HARNESS_REF=origin/<branch>"
  fi
  loud 2 ref-spelling "HARNESS_REF=${HARNESS_REF} resolves LOCALLY to ${local_target} in ${repo}, but this run fetched ${target} — 'apply' pins the LOCAL ref (the `want=` `rev-parse` in `cloud-cell-supervisor.sh`'s `harness_apply`), so the record could never advance and every tick would re-apply for ever. Use the remote spelling: HARNESS_REF=origin/<branch>"
}

do_pass() {
  local dry="${1:-}" layer repo sup target applied now rc fetch_branch fetch_ref fetch_err
  # ⛔ THE ONE-ACTOR INVARIANT IS RE-CHECKED ON EVERY TICK, BUT IT IS NOT THE FIRST THING THE TICK DOES.
  # `retire_actuator` DISABLES the shipped timer, and the first version of this call sat ABOVE
  # `resolve_layer`, `supervisor_in`, the `cd`, the fetch and the ref check — every one of which can exit
  # non-zero. A tick that retired the box's working actuator and then failed on any of them left the box
  # with ZERO pin actuators: `eldato-harness-apply.timer` disabled and stopped, this unit enabled and RED
  # every ten minutes, nothing advancing the layer — which is #3194's own state, reached by following this
  # change's documented migration. So the retirement is taken only once the pass has ESTABLISHED IT CAN
  # ACT (the same order `do_install` uses: the replacement first, the retirement last), and
  # `pass_rollback` puts it back if the tick fails after that. The DRY reading stays up here because it
  # retires nothing and `--dry-run` must report the duplicate it would retire without fetching.
  PASS_RETIRED=""
  trap pass_rollback EXIT
  # The DRY reading stays FIRST because it retires NOTHING: it needs no establishment, and `--dry-run` on a
  # box with no resolvable layer must still report the duplicate actuator it WOULD retire instead of
  # exiting before it has looked. Only the ACT branch moves down.
  [ "$dry" = dry ] && one_actor_check dry
  layer="$(resolve_layer)" || loud 2 no-layer "no usable layer: ${HARNESS_PIN_FILE} names nothing readable and ${HARNESS_PIN_DIR} holds no tree git can answer from"
  sup="$(supervisor_in "$layer")" || loud 2 no-supervisor "resolved layer ${layer} carries no cloud-cell-supervisor.sh, so there is no verb to pin with"
  repo="$layer"
  target=""
  if [ "$dry" = dry ]; then
    # ⛔ A DRY RUN TOUCHES NOTHING — not even refs. It reports the recorded layer and the ref as it
    # currently resolves locally, and SAYS the reading is possibly stale rather than fetching to freshen
    # it (a "read-only" verb that writes FETCH_HEAD is the kind of lie this file exists to remove).
    target="$(git -C "$repo" rev-parse --verify --quiet "${HARNESS_REF}^{commit}" 2>/dev/null)"
    log "dry-run (no fetch) layer=${layer} repo=${repo} supervisor=${sup} pinned=$(pinned_head || echo '<unreadable>') target=${target:-<unreadable, possibly stale>}"
    return 0
  fi
  # ⛔ `cd` — not `git -C` — because the verb below is the one that decides the cwd for the pin, and the
  # unit deliberately declares no `WorkingDirectory=`. This is where that directory is chosen.
  cd "$repo" || loud 2 chdir "cannot enter the resolved layer ${repo}"
  fetch_branch="$(ref_fetch_branch)" || loud 2 ref-spelling "HARNESS_REF=${HARNESS_REF} names another remote's tracking ref, and every fetch in this pass is hardcoded to the 'origin' remote — so the tick would fetch ORIGIN's branch and answer about a ref the operator never asked about; use origin/<branch> or refs/remotes/origin/<branch>"
  fetch_ref="$(pin_fetch_ref "$fetch_branch")"
  # ⛔ ONE FETCH, TWO REFSPECS: the bare one keeps `refs/remotes/origin/<branch>` fresh exactly as before
  # (the `--status-nofetch` reading and every other reader of the tracking ref depend on it), and the second
  # lands this very fetch in the run-private ref — see `PIN_FETCH_REF_BASE` for why `FETCH_HEAD` is not ours
  # and why the destination is keyed by source.
  # ⛔ AND GIT'S OWN REASON IS THE ONE THING THIS LINE MUST NOT THROW AWAY. It was `2>/dev/null`, so the
  # RED said only "git fetch … failed" — the exact pattern this file's own comment at `:137-138` names as
  # why "the journal could not even say why" an earlier pin tick failed: the operator got a boolean where
  # git had already written `fatal: could not read Username for 'https://github.com'` / `Could not resolve
  # host`. `-q` suppresses progress on stdout, so stdout stays discarded and stderr is CAPTURED into the
  # refusal rather than deleted.
  fetch_err="$(git fetch -q origin "$fetch_branch" "+${fetch_branch}:${fetch_ref}" 2>&1 >/dev/null)" \
    || loud 2 fetch-failed "git fetch origin ${fetch_branch} failed in ${repo} — an unreadable ref is never treated as current; git's own reason: ${fetch_err:-<git wrote nothing to stderr>}"
  # ⛔ DECIDE ON THE COMMIT THE FETCH BROUGHT — NOT ON THE KNOB'S SPELLING. `git rev-parse "$HARNESS_REF"`
  # resolves whatever that spelling names LOCALLY, and a fetch of `main` only moves
  # `refs/remotes/origin/main`: so `HARNESS_REF=refs/heads/main` (or a bare `main`) read the STALE local
  # branch the fetch never touched, and printed `current` + exit 0 against a newer remote tip — #3194's own
  # symptom through the knob this file documents. The specifier fetched above is the commit the fetch just
  # brought, whatever the spelling, and `^{commit}` peels an annotated tag (comparing a tag OBJECT sha to a
  # commit is a false DRIFT that can never be `current`). MEASURED, both directions, before this line existed.
  target="$(git rev-parse --verify --quiet "${fetch_ref}^{commit}" 2>/dev/null)" \
    || loud 2 unreadable-ref "${HARNESS_REF} did not resolve to a commit after the fetch in ${repo}"
  # ⛔ NOW — not one line earlier, not one line later. EARLIER (where this call used to sit) is the
  # zero-actuator window above: the layer, the supervisor, the `cd`, the fetch and the tip resolution have
  # all had to succeed before the shipped timer is touched. LATER is a window with two MUTATING actors on
  # one pin, which is the #2416 race this guard exists to prevent. The remaining fallible steps below are
  # the apply itself and its convergence read, and `pass_rollback` re-enables what this retired if they
  # fail — a migration may not destroy the actuator it is replacing before its replacement has worked.
  one_actor_check apply
  applied="$(pinned_head)"
  if [ -z "$applied" ]; then
    log "no readable pin record at ${HARNESS_PIN_FILE} -- applying (a pin nobody can read is not a pin)"
  # ⛔ ONE CONVERGENCE RULE, ONE PREDICATE (#1178) — and it has to hold on the DECISION, not just on the
  # read-back. This arm decided `current` by EQUALITY while the POST-apply rule below (`do_pass`'s
  # `merge-base --is-ancestor "$target" "$now"`) decides by
  # CONTAINMENT, so ONE state gave TWO verdicts: a record that legitimately sits AHEAD of the ref tip took
  # the mutating path here (`DRIFT … -- applying`) and read `current` + exit 0 from `--status`. Whichever
  # side you call correct, deciding them by different predicates is the third drift dialect this file
  # refuses — and the direction of the disagreement is the dangerous one: `--status` is the verb the header
  # calls the operator's FIRST READ, and it said `current` about a box whose tick was still doing work.
  # Containment is the rule the file's own comment already records as "the convergence rule", it fails on
  # #3194's shape (a record 17 commits BEHIND does not contain the tip), and it does not produce the
  # periodic false RED that equality produced on a record ahead of the ref. Same object database (`$repo`)
  # as the read-back, so the two cannot disagree; `--status` computes this exact test on `$layer`.
  elif git -C "$repo" merge-base --is-ancestor "$target" "$applied" 2>/dev/null; then
    # ⛔ THE GREEN LINE NAMES WHAT IT DID NOT CHECK. The template states that a pin which is current while
    # the RUNNING controller sits on a stale layer is a real state and that "the pass says so in its log line
    # rather than greening it away" — but only the APPLIED branch said so, and this is the branch that runs on
    # every converged tick. #3194's whole punishment was "the record said current while the pid executed a
    # tree 17 commits behind", so the no-op line is exactly where that belief is re-asserted: it must carry
    # the same caveat, or the one surface an operator reads all day is the one that overclaims.
    # A converged tick KEEPS its re-take: the pin is current, so the retirement this tick made (if any) is
    # the correct end state and `pass_rollback` must not undo it on the way out.
    PASS_RETIRED=""
    record_outcome "current ${target} (no-op; record verified — a RUNNING controller keeps the layer it started on)"
    log "current ${target} (no-op; record verified — note: a RUNNING controller keeps the layer it started on until it is restarted)"; return 0
  else
    log "DRIFT pinned=${applied} target=${target} -- applying --force --pin-only"
  fi
  # ⛔ BEFORE ANY MUTATION: IS THE REF THIS RUN DECIDED ON THE REF THE PIN VERB WILL PIN? See
  # `check_pin_resolution` — a spelling the verb resolves to something ELSE cannot converge however many
  # ticks it gets, and this is the last point where refusing costs nothing.
  check_pin_resolution "$repo" "$target"
  mkdir -p "$O" 2>/dev/null || true
  # ⛔ `--force --pin-only`, BOTH FLAGS, AND FOR DIFFERENT REASONS (#2215, honoured rather than
  # re-decided). `--pin-only`: a live cell always runs a controller, so a bare `apply` dies on it — and
  # `--force` WITHOUT it re-seeds the state dir that controller is executing from, which is a standing
  # version-skew generator. This pass only advances the pin; the next `start` seeds from it.
  bash "$sup" apply --force --pin-only >"$O/self-pin-apply.log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    record_outcome "apply-failed rc=${rc} via ${sup}"
    err "APPLY-FAILED rc=${rc} via ${sup}"
    if [ -f "$O/self-pin-apply.log" ]; then
      err "  see ${O}/self-pin-apply.log"
      tail -3 "$O/self-pin-apply.log" 2>/dev/null | while IFS= read -r l; do err "  $l"; done
    fi
    exit 1
  fi
  # ⛔ THE PASS IS NOT GREEN UNTIL THE RECORD MOVED **AND** CONTAINS THE TIP. Equality with a `target` read
  # BEFORE the apply is too strict: `apply` re-fetches, so it can legitimately pin a commit that landed in
  # between — and a periodic false RED on `systemctl --failed` trains operators to ignore the colour this
  # whole change depends on. An UNMOVED record stays RED (that is #3194's own shape).
  now="$(pinned_head)"
  if [ -z "$now" ]; then
    # ⛔ A LOST RECORD MUST NOT BE A PERMANENT, UNHEALABLE RED. `cloud-cell-supervisor.sh`'s
    # `harness_apply` writes $HARNESS_PIN_FILE only inside its CHANGED branch (`:2293`/`:2316`), so a
    # pin that is ALREADY at the tip takes `HARNESS_APPLIED=unchanged` and the record is never written.
    # A cell whose record was lost therefore reads an empty record every tick and REDs for ever on a
    # box that is in fact correct — the #3133 defect (merged), reproduced one layer up. The recorded
    # answer for exactly this state already exists in `harness-apply-pass.sh`: MEND the record to what
    # the box actually runs, and say so with its own exit code, 11 (`mended`).
    if mend_record "$target"; then
      now="$(pinned_head)"
      log "mended: the pin RECORD was missing/empty and now names ${now} (the tree apply created for ${target})"
      record_outcome "mended ${now} (record was missing; now names the tree apply created)"
      # 11 is a SUCCESS verdict (`mended`), not a failure: the record now names the tree apply created, so
      # the retirement this tick made stands.
      PASS_RETIRED=""
      exit 11
    fi
    record_outcome "stale-record (apply exited 0, ${HARNESS_PIN_FILE} names nothing readable, and no tree under ${HARNESS_PIN_DIR} could be recorded)"
    err "STALE-RECORD: apply exited 0 but ${HARNESS_PIN_FILE} names nothing readable, and no tree under ${HARNESS_PIN_DIR} is at ${target} to mend it to -- an exit code is not a convergence"
    exit 1
  fi
  # ⛔ ONE CONVERGENCE RULE, NOT TWO THAT OVERLAP. There were two guards here — "the record must have
  # MOVED" and "the record must CONTAIN the tip" — and on every state where the first fires the second
  # fires too (a record that was behind and did not move is still behind), so NEITHER was individually
  # gated: a mutant disabling either one ALONE left the suite green (measured in review: `:294 → if
  # false` and `:299 → if false` each survived at 66 ok / 0 failed). Containment IS the convergence
  # rule, it fails on #3194's own shape (the unmoved record was 17 commits behind, so it does not
  # contain the tip), and it does NOT produce the false RED the other one would have produced on a
  # record that legitimately sits AHEAD of the ref. The diagnosis still says which shape it saw, because
  # an operator acts differently on "apply did nothing" than on "apply pinned something off the line".
  if ! git -C "$repo" merge-base --is-ancestor "$target" "$now" 2>/dev/null; then
    if [ "$now" = "$applied" ]; then
      record_outcome "stale-record (${now} unmoved; ${HARNESS_REF} is ${target})"
      err "STALE-RECORD: apply exited 0 but ${HARNESS_PIN_FILE} still names '${now}', which does not contain ${HARNESS_REF} '${target}' -- the record did not move, and an exit code is not a convergence"
    else
      record_outcome "stale-record (record moved to ${now}, which does not contain ${target})"
      err "STALE-RECORD: the record moved to '${now}', which does not contain the ref tip '${target}' -- a pin that is not on the ref's line is not a pin"
    fi
    exit 1
  fi
  PASS_RETIRED=""
  record_outcome "applied -> ${now}"
  log "applied -> ${now} (record verified; ctrl=$(systemctl is-active eldato-orchestrator 2>/dev/null); note: a RUNNING controller keeps the layer it started on until it is restarted)"
  return 0
}

do_status() { # [fetch|nofetch] — read-only; exit 0 = current, 1 = DRIFT, 2 = UNRESOLVED (repo vocabulary)
  local layer sup target rec_head mode="${1:-fetch}" last="<none recorded>" dup unknown fetch_failed=0 fetch_branch fetch_ref status_fetch_err
  [ -f "$O/self-pin.last" ] && last="$(tail -1 "$O/self-pin.last" 2>/dev/null)"
  printf 'cell-self-pin\n  CELL_HOME      %s\n  pin record     %s -> %s\n  pin root       %s\n  pinned HEAD    %s\n  stamp (legacy) %s -> %s\n  last outcome   %s\n' \
    "$CELL_HOME" "$HARNESS_PIN_FILE" "$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null || echo '<absent>')" \
    "$HARNESS_PIN_DIR" "$(pinned_head || echo '<unreadable>')" "$STAMP" "$(read_stamp || true)" "${last:-<empty record>}"
  if layer="$(resolve_layer)"; then
    printf '  resolved layer %s\n' "$layer"
    sup="$(supervisor_in "$layer" && true)"; printf '  supervisor     %s\n' "${sup:-<none>}"
    # ⛔ AND THE ONE-ACTOR FACT IS ON THE OPERATOR'S LINE TOO. `do_pass` re-reads it every tick (bringup
    # re-arms the shipped timer by design); the tick's own reading belongs where an operator looks FIRST,
    # otherwise "is a second actor back?" is answerable only by reading a journal. Advisory by design —
    # it does NOT change the 0/1/2 verdict, which is the drift vocabulary and nothing else.
    # ⛔ AND "NOT ASKED" IS NOT "NONE". `actuator_scopes` is exit-code based, so a manager that did not
    # answer contributes nothing — and this line, the FIRST one an operator reads, printed `<none>` for it.
    # The tick and `--install` both consult `actuator_unknown_scopes` (`one_actor_check`, the install
    # read-back) and say UNVERIFIED; this verb alone reported a satisfied invariant from an unread scope,
    # which is the false PASS #3194 is about, on the surface that exists to surface it.
    if dup="$(actuator_scopes)"; then
      printf '  second actuator %s manager(s) — eldato-harness-apply.timer is ENABLED beside this unit (a tick retires it again; an operator can end it with --install --takeover)\n' "$(printf '%s' "$dup" | tr '\n' ' ')"
    else
      unknown="$(actuator_unknown_scopes)"
      if [ -n "$unknown" ]; then
        printf '  second actuator <UNVERIFIED — the%s manager did NOT ANSWER, so a duplicate eldato-harness-apply.timer there could not be checked; this is NOT "none">\n' "$(printf ' %s' $unknown)"
      else
        printf '  second actuator <none>\n'
      fi
    fi
    # ⛔ A STATUS THAT DOES NOT FETCH IS BLIND IN THE EXACT STATE THIS FILE EXISTS TO CATCH. #3194 was
    # a pin RECORD that disagreed with the layer the cell executed for ~a day: "current" against a
    # stale local `origin/main` is that same lie with a green verdict, so the ref is FETCHED here and
    # the reading SAYS which of the two it is. `--dry-run` stays the verb that touches nothing; a failed
    # fetch is reported as possibly stale, never as current-but-unverified silence.
    case "$mode" in
      nofetch) printf '  (%s NOT fetched — the reading below may be STALE)\n' "$HARNESS_REF" ;;
      *) fetch_branch="$(ref_fetch_branch)" || loud 2 ref-spelling "HARNESS_REF=${HARNESS_REF} names another remote's tracking ref, and every fetch in this pass is hardcoded to the 'origin' remote — this reading would be taken from ORIGIN's branch and reported under a ref the operator never asked about; use origin/<branch> or refs/remotes/origin/<branch>"
         fetch_ref="$(pin_fetch_ref "$fetch_branch")"
         # ⛔ AND HERE TOO: `2>/dev/null` deleted git's own reason, so the ONE LINE that tells an operator
         # "this reading is not a green" could not say why the fetch failed. Captured, not discarded — the
         # same rule the tick's refusal follows.
         if status_fetch_err="$(git -C "$layer" fetch -q origin "$fetch_branch" "+${fetch_branch}:${fetch_ref}" 2>&1 >/dev/null)"; then
           printf '  (%s fetched just now)\n' "$HARNESS_REF"
         else
           printf "  (git fetch FAILED in %s — the reading below is against an UNREFRESHED local ref; this is not a green; git's own reason: %s)\n" "$layer" "${status_fetch_err:-<git wrote nothing to stderr>}"
           fetch_failed=1
         fi ;;
    esac
    # ⛔ A FAILED FETCH IS `2 = unknown`, NOT `0 = current`. The line above prints "this is not a green"
    # and the comparison below used to hand back `verdict current` + exit 0 anyway: the artifact
    # contradicted itself in one screen, and the only monitorable signal — the exit code — said green for
    # exactly the reading the header calls unverified. An unrefreshed local ref cannot distinguish current
    # from DRIFT, so it decides NOTHING; the vocabulary this file reuses already has the word for it.
    if [ "${fetch_failed:-0}" -ne 0 ]; then
      printf '  %s %s (NOT refreshed — the value above may be stale)\n' "$HARNESS_REF" "$(git -C "$layer" rev-parse --verify --quiet "${HARNESS_REF}^{commit}" 2>/dev/null || echo '<unreadable>')"
      printf '  verdict        UNKNOWN (2) — the fetch failed, so this reading can NOT be called current\n'
      return 2
    fi
    # ⛔ THE COMMIT, PEELED, OR NOTHING — NEVER A REF NAME IN THE COMMIT COLUMN. `git rev-parse <unknown>`
    # PRINTS ITS ARGUMENT and exits 128, so the unguarded form below put the ref's NAME where a SHA belongs,
    # the equality test failed, and `--status` reported `verdict DRIFT (1)` for a ref the PASS calls
    # `unreadable` — the verb an operator reads first contradicting the tick. And a local annotated tag
    # resolves to its TAG OBJECT, which never equals a commit, so it could never read `current`.
    # ⛔ AND IN FETCH MODE IT IS THE COMMIT THE FETCH BROUGHT, not the spelling of the knob: a fetch of
    # `main` moves only `refs/remotes/origin/main`, while `git rev-parse main` reads the LOCAL branch the
    # fetch never touched — `current` + exit 0 against a newer remote tip (#3194 through a knob).
    # ⛔ AND THAT COMMIT IS READ FROM THE RUN-PRIVATE REF, the refspec this run wrote — NEVER FROM
    # `FETCH_HEAD`, which any coexisting fetch in this tree rewrites (see `PIN_FETCH_REF_BASE`, and the
    # measured false `current`).
    if [ "$mode" = nofetch ]; then
      target="$(git -C "$layer" rev-parse --verify --quiet "${HARNESS_REF}^{commit}" 2>/dev/null)" || target=""
    else
      target="$(git -C "$layer" rev-parse --verify --quiet "${fetch_ref}^{commit}" 2>/dev/null)" || target=""
    fi
    if [ -z "$target" ]; then
      printf '  %s <unreadable — does not resolve to a commit>\n' "$HARNESS_REF"
      printf '  verdict        UNKNOWN (2) — the ref did not resolve to a commit, so it decides NOTHING\n'
      return 2
    fi
    printf '  %s %s\n' "$HARNESS_REF" "$target"
    # ⛔ 1 FOR DRIFT, NOT 0. `scripts/check-deployed-drift.sh` already speaks `0 match / 1 drift /
    # 2 unknown`; a status verb that reports DRIFT and exits 0 cannot be gated on by anything, which is
    # how a third drift dialect (#1178) is born. Nothing here re-decides the vocabulary.
    # ⛔ ONE CONVERGENCE RULE, ONE PREDICATE (#1178). This arm decided `current` by EQUALITY while the PASS
    # decides by CONTAINMENT (`merge-base --is-ancestor`, in `do_pass`), so ONE state gave two answers: a
    # record that legitimately sits AHEAD of the ref tip read `current` from the tick and `DRIFT` from the
    # verb the header calls the operator's FIRST READ — and false-RED-ing the documented
    # `0=current / 1=DRIFT` vocabulary for anything that gates on it. The pass's own comment already records
    # that the equality rule "would have produced a false RED on a record that legitimately sits AHEAD of the
    # ref"; the rule was deleted there and left live here. The containment test is the one the pass uses,
    # computed on the same object database (`$layer`), so the two surfaces cannot disagree.
    rec_head="$(pinned_head)" || rec_head=""
    if [ -n "${target:-}" ] && [ -n "$rec_head" ] && git -C "$layer" merge-base --is-ancestor "$target" "$rec_head" 2>/dev/null; then printf '  verdict        current\n'; printf '                 (the RECORD is current — a RUNNING controller keeps the layer it STARTED on until it is restarted, so this is not a claim about the executed tree)\n'; return 0; fi
    printf '  verdict        DRIFT (a RUNNING controller keeps the layer it started on until restarted)\n'; return 1
  else
    printf '  resolved layer <UNRESOLVED — this is a RED, see --status output above>\n'; return 2
  fi
}

# ── --install ────────────────────────────────────────────────────────────────────────────────────
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
# ⛔ NOT `say`. `tests/no-tts/run.sh` refuses a line-start `say()` definition in any tracked shipped
# script, because on macOS `say` is /usr/bin/say (#2910) — and this file was the third offender keeping
# that shard red. `note` is the same one-line writer with a name that cannot shadow a binary.
note() { printf '%s\n' "$*" ; }
bad() { printf 'REFUSING: %s\n' "$*" >&2; }

# ── WHO the unit runs as: a property of the TREE IT PINS, not of whoever rendered it ───────────────
# ⛔ `{{USER}}`/`{{HOME}}` USED TO COME FROM THE INVOKING IDENTITY (`id -un`/`$HOME`), and the documented
# install path is `sudo … --install` — `--install` writes a SYSTEM unit under /etc/systemd/system and
# needs `systemctl daemon-reload`/`enable --now`, which only root can do. So the render produced
# `User=root`, `Environment=HOME=/root`. The consequences are recorded verbatim in THIS FLEET's own
# drop-in, `cell-self-pin.service.d/user.conf`:
#   "The repo and the stamp are owned by cmux; running as root makes git refuse the fetch (dubious
#    ownership) so the unit could never pin anything."
# That is #3194 reached by following this change's own migration: `resolve_layer` finds no layer and every
# tick exits `UNRESOLVED(no-layer)`. Worse, the `systemctl --user` probes in `actuator_scopes` become
# ROOT's user manager, so the one-actor guard silently misses the operator's timer — the exact false PASS
# that guard was added to close. Derive BOTH from the owner of `$CELL_HOME`: the one identity whose git
# can answer for the tree the pass pins.
# ⛔ `ls -ld`, NOT `stat -c`: `stat -c` is GNU-only and this repo's portability gate refuses it on macOS
# (where the spelling is `stat -f`) — the same trap class that gate exists to catch.
cell_home_owner() {
  local o
  o="$(ls -ld "$CELL_HOME" 2>/dev/null | awk '{print $3}')"
  [ -n "$o" ] || return 1
  printf '%s\n' "$o"
}

# home_of_user <user> — that user's home directory, portably. There is no `getent` on macOS and no `dscl`
# on Linux, so try the one, then fall back to the shell's own `~user` expansion (bash is the interpreter
# this unit declares). The name is validated first, so the expansion is never fed an arbitrary string.
home_of_user() {
  local u="$1" h=""
  case "$u" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  fi
  if [ -z "$h" ]; then
    h="$(eval "printf '%s' ~$u" 2>/dev/null)"
    case "$h" in '~'*) h="" ;; esac
  fi
  [ -n "$h" ] && [ -d "$h" ] || return 1
  printf '%s\n' "$h"
}

# pin_script_path — the absolute path the unit's ExecStart names, **COMPUTED AND NEVER WRITTEN**.
# ⛔ IT MUST LIVE UNDER $CELL_HOME, and that is a bug fix of its own: naming the RUNNING copy is a path
# that outlives nothing — rendering from a lane worktree produced
# `ExecStart=/bin/bash /home/…/.worktrees/ai-3194/scripts/cell-self-pin.sh`, and the worktree is PRUNED
# when the lane merges, leaving 203/EXEC every tick. `$CELL_HOME` is the one root a running cell keeps.
# ⛔ AND IT IS SPLIT FROM PLACEMENT, because a RENDER must write nothing. `--print-unit` is documented
# as a render-only verb and it wrote a file (and failed outright on a read-only $CELL_HOME), and a
# REFUSED `--install` had already replaced the placed copy before `verify_unit` could refuse. Both
# verbs now render the SAME path; only `--install` places it, and only after verification.
pin_script_path() {
  local dest="$CELL_HOME/.pi/agent/scripts/cell-self-pin.sh" src
  src="${SELF_DIR:-}/$(basename "${BASH_SOURCE[0]}")"
  [ -f "$src" ] || src="${SELF_DIR:-}/cell-self-pin.sh"
  [ -n "${SELF_DIR:-}" ] && [ -f "$src" ] \
    || { err "cannot find the pass to install beside itself (looked in ${SELF_DIR:-<unknown>})"; return 1; }
  printf '%s\n' "$dest"
}

# place_pass <dest> — put THIS file's bytes at <dest>, UNCONDITIONALLY.
# ⛔ UNCONDITIONAL, and that is a measured fix: an `[ -f "$dest" ] && return` early-exit meant
# install-once-then-reinstall-from-a-newer-checkout kept the OLD bytes — verbatim #3194 ("deployed code
# that was never deployed") reproduced inside its own fix, silently. Called by `--install` AFTER
# verification, NEVER by the renderer.
place_pass() {
  local dest="$1" src
  src="${SELF_DIR:-}/$(basename "${BASH_SOURCE[0]}")"
  [ -f "$src" ] || src="${SELF_DIR:-}/cell-self-pin.sh"
  [ -f "$src" ] || { err "cannot find the pass to place (looked in ${SELF_DIR:-<unknown>})"; return 1; }
  [ "$src" = "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")" || { err "cannot create $(dirname "$dest")"; return 1; }
  install -m 0755 "$src" "$dest" || { err "cannot place the pass at $dest"; return 1; }
  return 0
}

print_unit() { # [dest-dir] — render both units into a directory, or stdout when no dir is given
  local dest="${1:-}" tpl script user home
  # ⛔ A RENDER OF A BASE NOBODY GAVE IS A LIE THE UNIT CANNOT TAKE BACK. `CELL_HOME` unset is DERIVED
  # here (scripts/lib/cell-home.sh) and the READER of the record this file derives from —
  # cloud-cell-supervisor.sh — consumes the SAME resolver, so the two can no longer disagree about which
  # home is the cell's. What the derivation cannot supply is the OPERATOR's decision, and the rendered
  # `Environment=CELL_HOME=` is permanent the moment it lands in /etc/systemd/system, so an UNSET
  # CELL_HOME is still refused at that one moment.
  if [ -z "$CELL_HOME_GIVEN" ]; then
    bad "CELL_HOME is not set in this environment — the derived value is '${CELL_HOME}', and a render makes that permanent in /etc/systemd/system for every future tick. Set CELL_HOME to the cell home and re-run (agent-infra#3453: both sides consume scripts/lib/cell-home.sh, so the value you set here is the value the controller reads)."
    return 1
  fi
  # The template dir is resolved from THIS file's repo (templates/systemd is its sibling), then the
  # cell's materialized copy. A missing template is a refusal, never an empty unit.
  for d in "${TEMPLATES_DIR:-}" "${SELF_DIR%/scripts}/templates/systemd" "$CELL_HOME/.pi/agent/templates/systemd"; do
    [ -n "$d" ] && [ -d "$d" ] && [ -f "$d/cell-self-pin.service" ] && { TEMPLATES_DIR="$d"; break; }
  done
  [ -n "${TEMPLATES_DIR:-}" ] && [ -f "$TEMPLATES_DIR/cell-self-pin.service" ] \
    || { bad "cannot find cell-self-pin.service in any template dir (tried TEMPLATES_DIR, ${SELF_DIR%/scripts}/templates/systemd, $CELL_HOME/.pi/agent/templates/systemd)"; return 1; }
  script="$(pin_script_path)" || { bad "cannot locate the pass this unit would exec"; return 1; }
  # ⛔ A RENDER SAYS WHAT IT DID NOT DO. The rendered unit names a path that `--install` places; a
  # render that silently printed a unit naming a file it did not create would be the same class of
  # half-truth as the unit this file replaces. stderr, so stdout stays the artifact.
  [ -n "$dest" ] || [ -f "$script" ] || err "note: ${script} is not placed yet — this is a RENDER; '--install' places it and the units"
  # ⛔ THE RENDER'S IDENTITY IS THE TREE'S, NOT THE INVOKER'S — see `cell_home_owner`. A render that
  # cannot answer who owns $CELL_HOME REFUSES rather than silently baking the invoking user in, because
  # "the installer happened to be root" is how `User=root` reached a box that can only pin as its owner.
  user="$(cell_home_owner)" \
    || { bad "cannot determine the owner of CELL_HOME ('${CELL_HOME}') — the unit must run as the user whose git can answer for the tree it pins, and rendering the INVOKING user instead is what produced User=root (see cell_home_owner)"; return 1; }
  home="$(home_of_user "$user")" \
    || { bad "cannot resolve a home directory for '${user}' (the owner of CELL_HOME '${CELL_HOME}') — the unit's HOME= would otherwise point at the installer's home, and the pass derives its base from it"; return 1; }
  for tpl in cell-self-pin.service cell-self-pin.timer; do
    if [ -n "$dest" ]; then
      sed -e "s|{{USER}}|$(sed_esc "$user")|g" -e "s|{{HOME}}|$(sed_esc "$home")|g" \
          -e "s|{{CELL_HOME}}|$(sed_esc "$CELL_HOME")|g" \
          -e "s|{{PIN_SCRIPT}}|$(sed_esc "$script")|g" -e "s|{{INTERVAL_MIN}}|$INTERVAL_MIN|g" \
          "$TEMPLATES_DIR/$tpl" >"$dest/$tpl" || return 1
      if grep -q '{{' "$dest/$tpl"; then
        bad "unresolved placeholder in $dest/$tpl"; grep -n '{{' "$dest/$tpl" >&2; return 1
      fi
    else
      sed -e "s|{{USER}}|$(sed_esc "$user")|g" -e "s|{{HOME}}|$(sed_esc "$home")|g" \
          -e "s|{{CELL_HOME}}|$(sed_esc "$CELL_HOME")|g" \
          -e "s|{{PIN_SCRIPT}}|$(sed_esc "$script")|g" -e "s|{{INTERVAL_MIN}}|$INTERVAL_MIN|g" \
          "$TEMPLATES_DIR/$tpl"
    fi
  done
  # ⛔ EXPLICIT 0. The loop's last command is a `grep -q` that LEGITIMATELY finds nothing, so without this
  # the function inherited grep's 1 and `--install` failed SILENTLY with no reason printed (#3194's own
  # class: a unit that cannot run must say why).
  return 0
}

# ── a unit reader that speaks systemd's own syntax ──────────────────────────────────────────────────
# directive <body> <Name> — every value of <Name>= in the unit body, one per line, in file order.
# declares   <body> <Name> — true when the directive is present AT ALL (even with an empty value).
# ⛔ WHITESPACE-TOLERANT IN BOTH POSITIONS, AND THAT IS A FAIL-OPEN FIX, NOT TIDINESS. systemd's parser
# strips whitespace before a directive NAME and around the `=`, so `Name=value`, ` Name=value` and
# `Name = value` are the SAME directive to the manager. A matcher anchored on column 0 with a literal
# `Name=` is therefore blind to two spellings systemd honours. MEASURED in review, both live:
#   · `WorkingDirectory = /srv/harness-current` / `ExecStart = /bin/bash /srv/nowhere/evil.sh` /
#     `ConditionPathExists = /srv/nope` → `--install` returned 0 and wrote all three;
#   · an INDENTED second `ExecStart=` → not counted, so the count rule, the $CELL_HOME prefix check and
#     the `/tmp/cell-ai` token check all inspected only the first, legitimate line.
# The repo's own unit reader already parses this way (`scripts/orchestrator-harness/harness-roles.sh`:
# `sed -n 's/^[[:space:]]*ExecStart=//p'`), so this is one spelling of one rule, not a third dialect.
directive() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p"
}
# directive_names <body> — every directive NAME present (the left side of `=`), one per line, sorted.
# For FAMILY rules. A prefix test needs the names, because asserting one `<Name>=` spelling at a time is
# how a family of thirty-plus directives comes to be "closed" for exactly one of them.
directive_names() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9]*\)[[:space:]]*=.*/\1/p' | sort -u
}
# unit_section <body> <section> — the lines under `[<section>]`, to the next section header.
# A REPEATED `[<section>]` header CONTINUES the section rather than restarting it (which is what systemd
# does), so its lines are merged into one stream instead of the last block winning.
# ⛔ SECTION-AWARE PARSING IS LOAD-BEARING WHEREVER A RULE IS ABOUT A DIRECTIVE SYSTEMD ONLY HONOURS IN
# ONE SECTION. `directive` reads PHYSICAL lines and tracks no section, so it cannot tell a `Unit=` systemd
# obeys from a `Unit=` in a section it IGNORES — and an unknown or wrong section is not an error, it is a
# silent skip (`systemd-analyze verify`: "Unknown section 'Service'. Ignoring."). A rule built on
# `directive` alone therefore reads a directive that does nothing as satisfied, which is a false PASS.
unit_section() {
  printf '%s\n' "$1" | awk -v want="$2" '
    { line=$0; sub(/^[ \t]*\[/, "", line); sub(/\].*$/, "", line) }
    /^[ \t]*\[/ { sec=line; next }
    sec==want { print }
  '
}
declares() {
  local hit
  hit="$(printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*.*/x/p")"
  [ -n "$hit" ]
}

# ── THE ENVIRONMENT-PARSE CLASS: what systemd reads is NOT what a line reader reads ─────────────────
# ⛔ THREE WAYS TO CHANGE THE PASS'S ENVIRONMENT THAT THE `Environment=` RULES BELOW CANNOT SEE, all
# measured at rc=0 against this file before these rules existed:
#
#  1. `EnvironmentFile=`  — systemd READS the named file and its values OVERRIDE `Environment=`.
#  2. `UnsetEnvironment=` — `systemd.exec(5)`: applied as the FINAL step when the environment is compiled,
#                           so it "may undo assignments from any configuration source, including
#                           assignments made through Environment= or EnvironmentFile=".
#  3. `PassEnvironment=`  — imports named variables from the MANAGER's own environment into the service.
#
# Every one of them can set, re-base or clear `CELL_HOME` while `verify_unit`'s count rule still sees
# exactly one correct `Environment=CELL_HOME=`. They are refused BY NAME, together, in ONE list — the same
# "family closed by name" rule this file already applies to `Exec*` and `Condition*`. Nothing is lost by
# refusing them: the rendered pin unit needs no environment file, nothing to unset and nothing passed in
# (`print_unit` emits every value the pass uses).
ENV_MUTATING_DIRECTIVES="EnvironmentFile UnsetEnvironment PassEnvironment"

# ⛔ AND THE RAW-TEXT PARSE IS ITSELF A BOUNDARY THAT MUST BE CLOSED, not trusted. `directive` reads
# PHYSICAL LINES; systemd reads the file the way `systemd.syntax(7)` specifies:
#   · "Lines ending in a backslash are concatenated with the following line while reading and the
#     backslash is replaced by a space character" — so
#         Environment=HOME=/x \
#         CELL_HOME=/tmp/other-home
#     is ONE directive whose SECOND assignment wins (`Environment=` is LAST-WINS), while a line reader
#     never sees a second `Environment=` at all and counts one correct assignment;
#   · "C-style escapes are supported" — `Environment=\x43ELL_HOME=/tmp/other-home` is `CELL_HOME=…` to the
#     manager (`\x43` = `C`) and an unknown name to the line reader.
# Both installed rc=0. Refusing a backslash in a directive closes BOTH, plus any future spelling built on
# the same two constructs, instead of enumerating them — and it costs nothing: the rendered unit is
# generated from a template of plain paths and numbers, so it needs no continuation and no escape.
refuse_raw_text_tricks() { # <what> <body>
  case "$2" in
    *\\*)
      bad "$1 carries a backslash in a directive — systemd CONCATENATES a backslash-continued line and EXPANDS C-style escapes (\x43 is 'C'), so its parse differs from the line read this verification performs and a second CELL_HOME= assignment could hide there; the pin unit needs no continuation and no escape"; return 1 ;;
  esac
  # ⛔ AND `%` IS A SPECIFIER, NOT A CHARACTER. `systemd.unit(5)`/`systemd.service(5)`: `Environment=`
  # values and the `ExecStart=` command line both take `%` SPECIFIERS, expanded by the manager (`%h` = the
  # user's home, `%n` = the unit name, …). So a base of `/srv/cell%h` is verified as that literal string and
  # RUNS as `/srv/cell/root` — the unit's effective CELL_HOME, and its ExecStart path, stop being the values
  # this verification approved, and the pass then reads a pin record the controller never reads (or goes
  # 203/EXEC), while `--install` says installed. MEASURED rc=0. Refused rather than escaped (`%%` would work)
  # because the values this file renders are plain paths and numbers, none of which legitimately needs a
  # specifier — and a refusal names the thing to change instead of silently rewriting an operator's value.
  case "$2" in
    *%*)
      bad "$1 carries a '%' in a directive — systemd EXPANDS %-specifiers in Environment= and ExecStart= (%h is the manager user's home, %n the unit name), so the value this verification reads literally is not the value systemd runs, and the pass would derive its base from something nobody verified; the pin unit needs no specifier (use a plain path)"; return 1 ;;
  esac
  return 0
}

# refuse_env_mutators <what> <body> — the three directives in ENV_MUTATING_DIRECTIVES, by name.
refuse_env_mutators() { # <what> <body>
  local _n
  for _n in $ENV_MUTATING_DIRECTIVES; do
    if declares "$2" "$_n"; then
      bad "$1 declares ${_n}= — it changes the pass's environment BEHIND the Environment= rules (systemd applies it over or after them, so it can set, re-base or clear CELL_HOME), which would make the pass derive its base from a value this verification never read; the pin unit needs none of ${ENV_MUTATING_DIRECTIVES}"; return 1
    fi
  done
  return 0
}

# refuse_env_reset <what> <body> — `Environment=` with an EMPTY value is a LIST RESET, not a no-op.
# ⛔ `systemd.exec(5)`: "If the empty string is assigned to this option, the list of environment variables
# is reset, all prior assignments have no effect." A word-split read of that value yields NO words, so the
# count rule below never sees it: the unit installs green with `CELL_HOME` GONE, and the pass then derives
# its base from `HOME` (`CELL_HOME="${CELL_HOME:-$HOME}"`) — a pin record the controller never reads.
# MEASURED at rc=0 in the rendered unit AND in a drop-in (in a drop-in it also clears the list the main
# unit built, which is the documented way to remove an entry).
refuse_env_reset() { # <what> <body>
  if printf '%s\n' "$2" | awk '/^[[:space:]]*Environment[[:space:]]*=[[:space:]]*$/{f=1} END{exit(f?0:1)}'; then
    bad "$1 assigns an EMPTY 'Environment=' — systemd treats that as a LIST RESET (all prior assignments have no effect), so it ERASES the CELL_HOME= line this verification just counted and the pass silently falls back to HOME; drop the line instead of clearing the list"; return 1
  fi
  return 0
}

verify_unit() { # <rendered service> [expected ExecStart payload] — the properties the ISSUE names, asserted on the ARTIFACT
  local f="$1" expect="${2:-}" body exec_path exec_real exec_dir home_real n_exec execs envs ok_vals v w seen11=0 _interp _x _c
  local n_home home_val _env _kv svc users n_user user_val expect_user
  # ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE. The template documents the defect it replaced, and that prose
  # legitimately contains `/tmp/cell-ai`; a guard that also refused the documentation would force the
  # next reader to delete the only explanation of why the line is banned. Strip comments first.
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  refuse_raw_text_tricks "the rendered unit" "$body" || return 1
  refuse_env_reset "the rendered unit" "$body" || return 1
  refuse_env_mutators "the rendered unit" "$body" || return 1
  # ⛔ THE BODY-WIDE REFUSALS ABOVE STAY WHOLE-BODY ON PURPOSE (fail-closed: a backslash continuation or
  # an `Environment=` RESET is dangerous in ANY section, because the section that carries it is the next
  # one's problem and we have already established systemd will not complain). The rules BELOW are
  # different: `Environment=`, `SuccessExitStatus=` and `User=` are `[Service]`-only directives, and
  # written anywhere else systemd DROPS them with "Unknown key name … ignoring." A rule built on the
  # section-blind `directive` therefore grades text systemd discards — measured in review: two
  # `Environment=` lines moved under a trailing `[Unit]` head passed the count rule, the value rule and
  # the allow-list, `--install` printed "installed", and `systemd-analyze verify` reported BOTH lines as
  # ignored, so the installed unit ran with NO `CELL_HOME` and fell back to `${CELL_HOME:-$HOME}` (this file's
  # top-level `CELL_HOME=` assignment)
  # — a different pin record than the controller reads, which is #2215's skew made permanent in
  # /etc/systemd/system. `verify_timer` was made section-aware for exactly this class; this is the same
  # fix on the service, and it uses the same helper.
  svc="$(unit_section "$body" Service)"
  [ -n "$svc" ] || { bad "the rendered unit declares no [Service] section (or an empty one) — ExecStart=, Environment=, SuccessExitStatus= and User= are [Service] directives, and systemd ignores them in every other section, so this unit would install green and fail to start (or start under the wrong identity)"; return 1; }
  # ⛔ THE DEFECT ITSELF, AS AN INVARIANT: a rendered pin unit must carry NO bootstrap-only path, AS A
  # TOKEN — not merely after `=` or at line start. `ExecStart=/bin/bash /tmp/cell-ai/scripts/…` puts a
  # SPACE before the path, and that is the reachable form: the placed copy's fallback is whatever
  # checkout the installer ran from, which on a provisioning box is exactly the bootstrap clone.
  # ⛔ AND `/private/tmp` IS THE SAME DIRECTORY, SPELLED THE WAY macOS RESOLVES IT. The token list used to
  # require the literal `/tmp/`, so `Environment=HARNESS_PIN_FILE=/private/tmp/cell-ai/.harness-path`
  # installed GREEN — and the `Environment=` line is the one place nothing else looks (the `declares` and
  # `$CELL_HOME` rules only read `WorkingDirectory=`/`ExecStart=`), so that spelling reached the box and
  # pointed the pass at a different pin record than the controller reads. This suite already compensates
  # for the same resolution for its own git paths (`pwd -P`); the guard has to as well.
  if [[ $body =~ (^|[[:space:]=])/(private/)?(var/)?tmp/cell-ai(/|[[:space:]]|$) ]]; then
    bad "a rendered directive names the provisioning clone (/tmp/cell-ai) — that path is absent on a running cell and systemd fails the unit at CHDIR before any payload runs (#3194)"; return 1
  fi
  # ⛔ EVERY ExecStart, AND EXACTLY ONE — counted and read in EVERY spelling systemd accepts
  # (`ExecStart=`, ` ExecStart=`, `ExecStart = `). `Type=oneshot` permits REPEATED `ExecStart=` and
  # systemd runs all of them, so a guard that inspects only the first line installs an executable
  # directive it never saw. Measured in review: a legitimate line first plus an appended
  # `ExecStart=/bin/bash /srv/nowhere/…` installed green (rc=0, both lines written).
  execs="$(directive "$body" ExecStart)"
  n_exec=0
  [ -z "$execs" ] || n_exec="$(printf '%s\n' "$execs" | wc -l | tr -d ' ')"
  if [ "$n_exec" -ne 1 ]; then
    bad "the rendered unit declares ${n_exec} ExecStart= lines — exactly one is installable (systemd runs them ALL, so a second one is an unverified executable directive)"; return 1
  fi
  # ⛔ THE EXECUTABLE-DIRECTIVE FAMILY IS CLOSED, NOT JUST `ExecStart=`. `Type=oneshot` runs
  # `ExecStartPre=`, `ExecCondition=` and `ExecStopPost=` too, and every one of them is an executable
  # directive this file does not read, prefix-check or token-check (measured: `ExecStartPre=/bin/bash
  # /srv/nowhere/bootstrap.sh` appended to the template installed with rc=0 and every leg green). The pass
  # needs exactly ONE executable directive; any other member of the family is refused BY NAME, because an
  # executable nobody verified is the false PASS class #3194 is about, one directive name over.
  for _x in ExecStartPre ExecStartPost ExecCondition ExecStop ExecStopPost ExecReload; do
    if declares "$body" "$_x"; then
      bad "the rendered unit declares ${_x}= — an executable directive this verification does not read, which systemd RUNS anyway; the pass needs exactly ONE executable directive, ExecStart="; return 1
    fi
  done
  # ⛔ TWO RULES, TWO DIRECTORS, EACH INDIVIDUALLY GATING. `ExecStart=` is INTERPRETER plus PAYLOAD, and
  # the two properties are asserted separately here (interpreter is /bin/bash; payload is an absolute path
  # under $CELL_HOME). Anchoring both on one prefix match made the interpreter rule unreachable on its
  # own: with `[ "/bin/bash "* ]` as the split, a `/bin/sh <path>` doctor fell through to the $CELL_HOME
  # rule and was refused by the WRONG one, so deleting the interpreter rule left the suite green.
  _interp="${execs%% *}"
  exec_path="${execs#"$_interp" }"
  [ "$_interp" = "/bin/bash" ] \
    || { bad "the rendered unit's ExecStart interpreter is '${_interp}', not '/bin/bash' — a oneshot has no shell to resolve one"; return 1; }
  case "$exec_path" in
    /*) ;;
    *) bad "the rendered unit's ExecStart payload '${exec_path}' is not an ABSOLUTE path — a oneshot has no shell to resolve one"; return 1 ;;
  esac
  # ⛔ AND IT MUST LIVE UNDER $CELL_HOME. Any other absolute path can be pruned out from under the unit
  # (a lane worktree, a bootstrap clone); $CELL_HOME is the one root a running cell keeps.
  # ⛔ AND THE PREFIX TEST IS ON THE RESOLVED PATH, NOT THE RAW STRING. `<CELL_HOME>/../nowhere/x.sh` IS
  # `"$CELL_HOME"/*` as a string and resolves OUTSIDE the home — measured rc=0 — so two characters
  # defeated the rule that keeps the pass inside the one root a cell keeps. Resolve the payload's real
  # directory (`pwd -P`, which is also what makes this correct on macOS where /tmp is /private/tmp) and
  # prefix-test THAT. ⛔ A payload whose parent does not resolve at all cannot be resolved by `pwd -P`, so for
  # that case the lexical path is refused if it carries `..` and is otherwise prefix-tested as written — the
  # ">path outside the home" verdict must be reached from the prefix rule, not from a parent-existence rule
  # that would shadow it and report the wrong reason (measured: it did, on the suite's own doctor).
  # ⛔ AND BOTH SIDES OF THE COMPARISON MUST BE RESOLVED — OR LEXICAL — *TOGETHER* (round-14 review, P2).
  # The two sides were mixed: `home_real` was always `cd "$CELL_HOME" && pwd -P` (RESOLVED) while
  # `exec_real` fell back to the RAW `$CELL_HOME/…` string whenever the payload's parent did not resolve —
  # which is EVERY FIRST INSTALL, because `place_pass` runs after `verify_unit` and the parent does not exist
  # yet. So on any box whose `$CELL_HOME` is reached through a symlink (an operator-set
  # `CELL_HOME=/tmp/cell-home` → `/private/tmp/cell-home` on macOS is the measured example — the
  # legacy home is not a DEFAULT anywhere since agent-infra#3453, but it can still be SET) the two
  # strings could never match and
  # the FIRST install was refused with a cause naming the containment rule, on a payload that was inside the
  # home. The second attempt passed only because the first had created the parent in between. MEASURED on
  # this box: `CELL_HOME=$T/symhome -> $T/realhome`, `--install` → rc=1, "ExecStart resolves to
  # '…/symhome/.pi/agent/scripts/cell-self-pin.sh', which is NOT under CELL_HOME ('…/realhome')".
  # Resolved-vs-resolved when the payload's parent resolves; lexical-vs-lexical when it does not. The
  # lexical arm keeps the `..` refusal, so no traversal becomes reachable by taking it.
  exec_dir="$(cd "$(dirname "$exec_path")" 2>/dev/null && pwd -P)" || exec_dir=""
  if [ -n "$exec_dir" ]; then
    exec_real="${exec_dir%/}/$(basename "$exec_path")"
    home_real="$(cd "$CELL_HOME" 2>/dev/null && pwd -P)" || home_real="$CELL_HOME"
  else
    case "$exec_path" in
      */../*|*/..|../*|..)
        bad "the rendered unit's ExecStart payload '${exec_path}' traverses '..' through a directory that does not resolve — the containment rule this file holds cannot be evaluated on it, so it is refused rather than guessed"; return 1 ;;
    esac
    exec_real="$exec_path"
    home_real="$CELL_HOME"
  fi
  case "$exec_real" in
    "${home_real%/}"/*) ;;
    *) bad "ExecStart resolves to '${exec_real}', which is NOT under CELL_HOME ('${home_real}') — a path outside the one home can be pruned out from under the unit, which is the failure this change exists to remove (203/EXEC every tick)"; return 1 ;;
  esac
  # ⛔ AND IT MUST BE THE PASS THIS INSTALL PLACES — not merely SOME path under CELL_HOME. `verify_unit`
  # used to check only that the payload was inside the home, while the existence check after placement read
  # the COMPUTED `pin_script_path`, never the path in the artifact. So a template/code divergence, or a
  # stale payload name, installed green and then went 203/EXEC every tick — measured: a rendered unit naming
  # `${CELL_HOME}/scripts/gone.sh` (absent) installed rc=0. The expected payload is passed in by the caller
  # because only it knows what it is about to place; when the caller passes nothing (the suite's
  # single-argument calls) the identity rule is skipped rather than guessed, and existence is then proved by
  # the `[ -f "$script" ]` assertion after placement.
  if [ -n "$expect" ]; then
    case "$expect" in
      "$exec_real"|"$exec_path") ;;
      *) bad "the rendered unit's ExecStart payload is '${exec_path}' but this install places the pass at '${expect}' — the unit would exec a file this run did not verify (203/EXEC every tick, or a stale pass)"; return 1 ;;
    esac
  fi
  # ⛔ AND THE UNIT MUST CARRY THE SAME BASE THE EXECSTART USES. The service manager's HOME is not the cell
  # home, so a unit that carried only `HOME=` left the pass defaulting CELL_HOME from an unrelated value
  # while its ExecStart sat under the real one — measured: the pass then read `$HOME/.harness-path` while
  # the controller read `$CELL_HOME/.harness-path`, i.e. it pinned a tree the controller never runs.
  # ⛔ EXACTLY ONE `CELL_HOME=` ASSIGNMENT — A COUNT AND VALUE RULE, NOT A PRESENCE TEST. `Environment=` is
  # LAST-WINS in systemd: a SECOND assignment of the same variable OVERRIDES the first. A presence test
  # therefore installs GREEN a unit whose EFFECTIVE base is a different path, while `ExecStart` — and so
  # the `$CELL_HOME` prefix rule above — still sits under the real one, so no other rule catches it and
  # the pass reads a pin record the controller never reads. MEASURED before this rule existed: appending
  # `Environment=CELL_HOME=/tmp/other-home` to the template installed rc=0 and wrote BOTH lines.
  # This is the same defect shape as the `ExecStart=` count rule above, and it is fixed the same way —
  # including the spellings systemd accepts (`Environment="CELL_HOME=/x"` — the quotes are stripped —
  # several assignments on one line, and an indented `Environment=`).
  # ⛔ AND THE ALLOWANCE IS ONE VARIABLE WIDE — THE SAME RULE THE DROP-IN GATE ALREADY STATES. This arm
  # used to COUNT `CELL_HOME=` and ignore every other assignment, while `verify_dropin_file` refused any
  # `Environment=` other than `HOME=` and its own comment named this blocklist as the defect ("every one of
  # those variables is READ by this pass, so a drop-in that sets any of them silently re-points the pass at a
  # different record"). The rendered unit had exactly that hole: MEASURED before this rule existed, a
  # template carrying `Environment=HARNESS_PIN_FILE=/elsewhere/.harness-path` installed rc=0, wrote the line,
  # and `--dry-run` then resolved a layer from that record while the controller read `$CELL_HOME/.harness-path`
  # — #2215's skew, made permanent in /etc/systemd/system, through the one surface this verb is supposed to
  # verify. `HOME=` and `CELL_HOME=` are the closed set: identity, and the base the rules below already check.
  # A name systemd or a future template adds is refused without another review, which is the direction the
  # "family closed by one name" defect this file has fixed three times now requires.
  envs="$(directive "$svc" Environment)"
  n_home=0
  home_val=""
  while IFS= read -r _env; do
    for _kv in $_env; do
      _kv="${_kv%\"}"; _kv="${_kv#\"}"
      [ -n "$_kv" ] || continue
      case $_kv in
        CELL_HOME=*) n_home=$((n_home + 1)); home_val="${_kv#CELL_HOME=}" ;;
        HOME=*) ;;
        *) bad "the rendered unit sets 'Environment=${_kv%%=*}=' — every variable this pass reads (CELL_HOME, HARNESS_PIN_FILE, HARNESS_PIN_DIR, HARNESS, HARNESS_REF, O) is derived from the unit's environment, so an assignment other than HOME=/CELL_HOME= silently re-points the pass at a DIFFERENT pin record than the controller while this install reports success; a unit may adjust IDENTITY (HOME=) and the base (CELL_HOME=), never the record it reads"; return 1 ;;
      esac
    done
  done <<<"$envs"
  if [ "$n_home" -ne 1 ]; then
    bad "the rendered unit declares ${n_home} 'Environment=CELL_HOME=' assignment(s) — exactly one is installable (systemd is LAST-WINS, so a second one silently re-bases the pass onto a DIFFERENT pin record than the controller)"; return 1
  fi
  if [ "$home_val" != "$CELL_HOME" ]; then
    bad "the rendered unit's Environment=CELL_HOME='${home_val}' is not the cell home '${CELL_HOME}' — the pass would derive its base from a value the controller never read, so it pins a different record"; return 1
  fi
  # ⛔ THE ARTIFACT'S IDENTITY WAS THE ONE PROPERTY NOTHING ASSERTED. `print_unit` derives `User=` from
  # the owner of `$CELL_HOME` (`print_unit`'s `user="$(cell_home_owner)"`) because `User=root` was MEASURED to break the pin; this file's own
  # comment quotes the fleet's drop-in: "running as root makes git refuse the fetch (dubious ownership) so
  # the unit could never pin anything" — but no rule read the value back off the rendered artifact, so a
  # template carrying `User=root`, or a second `User=` line (systemd is LAST-WINS for a single-valued
  # key), installed with a positive claim. MEASURED in review, both spellings: rc=0, "installed". That is
  # #3194's own shape one directive over — a unit that can never pin, reported green — and it is worse
  # than a broken pin: the payload the unit execs lives under `$CELL_HOME/.pi/agent/scripts`, which is
  # owned by the cell user, so a `User=root` artifact executes bytes the cell user can replace.
  # Derived here, not passed in, so the rule and the render can never disagree about the expected owner.
  expect_user="$(cell_home_owner)" \
    || { bad "cannot determine the owner of CELL_HOME ('${CELL_HOME}') to verify the rendered unit's User= against — refusing rather than installing a unit whose identity nothing can check"; return 1; }
  users="$(directive "$svc" User)"
  n_user=0
  [ -z "$users" ] || n_user="$(printf '%s\n' "$users" | wc -l | tr -d ' ')"
  if [ "$n_user" -ne 1 ]; then
    bad "the rendered unit declares ${n_user} User= line(s) — exactly one is installable and it must name '${expect_user}', the owner of CELL_HOME (systemd is LAST-WINS, so a second one silently changes the identity the payload runs as; and with none, the unit runs as ROOT)"; return 1
  fi
  if [ "$users" != "$expect_user" ]; then
    bad "the rendered unit's User='${users}' is not '${expect_user}', the owner of CELL_HOME — that user's git is the one that can answer for the tree this pass pins, so any other identity makes the fetch refuse (dubious ownership) and every tick REDs with the unit still reporting installed"; return 1
  fi
  # (`EnvironmentFile=`/`UnsetEnvironment=`/`PassEnvironment=` are refused above, by name, in ONE list — see
  # ENV_MUTATING_DIRECTIVES. They were refused here first and then generalised, because the drop-in path had
  # the same hole and two copies of a rule drift.)
  # ⛔ AND IT MUST NOT DECLARE A WORKING DIRECTORY AT ALL. Any absolute path here is a bootstrap-time
  # value outliving its directory; the pass `cd`s itself after resolving the layer. `declares` (not a
  # value read) so `WorkingDirectory=` with an empty or continued value cannot slip past.
  if declares "$body" WorkingDirectory; then
    bad "the rendered unit declares WorkingDirectory= — one directive that refuses to start the unit when the directory is gone (EXIT_CHDIR 200); drop it and let the pass resolve its own cwd"; return 1
  fi
  # ⛔ A SKIPPED CONDITION IS A GREEN NO-OP, AND THE FAMILY IS THIRTY-PLUS NAMES, NOT ONE.
  # `systemd.unit(5)` lists `ConditionPathExists=`, `ConditionFileNotEmpty=`, `ConditionPathIsDirectory=`,
  # `ConditionEnvironment=`, `ConditionUser=`, `ConditionNeedsUpdate=`, … and EVERY member behaves the same
  # way on a false condition: the unit is SKIPPED and left GREEN — strictly worse than the 200/CHDIR this
  # change replaces. Refusing only `ConditionPathExists=` left the other twenty-nine reachable, which is
  # the same "family closed by one name" defect this file already fixed for the `Exec*` family. The
  # PREFIX is the rule, so a condition name systemd adds later is closed without another review.
  for _c in $(directive_names "$body"); do
    case "$_c" in
      Condition*)
        bad "the rendered unit declares ${_c}= — a failed condition SKIPS the unit and leaves it green; the missing-layer case must be a RED payload exit, not a skip"; return 1 ;;
      DynamicUser)
        # ⛔ THE IDENTITY CLASS IS MORE THAN ONE NAME, WHICH IS THE DEFECT THIS FILE HAS ALREADY FIXED
        # THREE TIMES (`Exec*`, `Condition*`, `EnvironmentFile|UnsetEnvironment|PassEnvironment`). The
        # `User=` rule closed the NAMED identity and left the ALLOCATED one open: measured,
        # `DynamicUser=yes` installs rc=0 (rendered unit and drop-in alike), and `systemd.exec(5)` says the
        # user/group "is dynamically allocated at the time the service is started" — i.e. the payload runs
        # as nobody in particular, NOT as the owner of `$CELL_HOME`, so its git cannot answer for the tree
        # and every tick REDs with the unit reporting installed. A pin unit must run as one KNOWN identity.
        # ⛔ AND THE REASON MUST BE TRUE FOR EVERY VALUE, INCLUDING THE HARMLESS ONES. The first version
        # asserted the directive "allocates or overrides that identity at start-up", which is FALSE for
        # `DynamicUser=no` — the documented default (`systemd.exec(5)`), which allocates nothing — so an
        # operator who wrote `=no` was refused with a cause about a failure that cannot occur (round-3
        # review, P2). Grading the value here would mean re-implementing systemd's boolean parsing for a
        # directive the shipped unit may simply not carry, and this file's rule is to close the FAMILY and
        # name the real reason: this verification does not read the value, so the identity is UNVERIFIED.
        bad "the rendered unit declares ${_c}= — this verification does not read its value, so it cannot tell whether the pass still runs as the OWNER of CELL_HOME (the identity whose git can answer for the tree it pins), and a unit that runs as any other identity fails every tick while reporting installed; the pin unit needs no allocated identity — remove the line"; return 1 ;;
      RootDirectory|RootImage)
        # ⛔ THE HEADER NAMES THIS DIRECTIVE AND NOTHING CHECKED IT. `RootDirectory=`/`RootImage=` make
        # systemd chroot()/pivot_root() the payload into that path (`systemd.exec(5)`) BEFORE any line of it
        # runs — so a path that is not a live-cell invariant is the same "unit that never began" class as
        # `WorkingDirectory=`, just one syscall over (and `EnvironmentFile=` was the sibling this file
        # already refused). MEASURED rc=0 before this arm. The pass resolves its own layer instead.
        bad "the rendered unit declares ${_c}= — systemd enters that root BEFORE the payload runs, so a path that is not a live-cell invariant turns the pin into a unit that never began (the 200/CHDIR class); the pass resolves its own layer instead"; return 1 ;;
      BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountImages|ExtensionImages|ExtensionDirectories)
        # ⛔ THE MOUNT-REDIRECTION MEMBERS OF THE SAME CLASS, WHICH THE ROOT-DIRECTORY ARM LEFT OPEN
        # (round-19 review, P1). `systemd.exec(5)`: `BindPaths=`/`BindReadOnlyPaths=` bind-mount a source
        # OVER a path in the unit's view before any line of the payload runs, and `TemporaryFileSystem=`
        # replaces a path with an empty tmpfs. So `BindPaths=/srv/evil:<the verified ExecStart>` makes the
        # unit execute bytes NO rule in this file has ever read, at a path that EXISTS (no 203/EXEC to turn
        # it into a RED), with the timer enabled and every surface green — the payload-identity class the
        # `$expect` rule above closes, reached one directive over. MEASURED before this arm: rc=0, the unit
        # installed, "ONE actuator" printed. The reason below is true for EVERY value because this
        # verification reads no mount at all, so nothing it approved survives the unit's own filesystem
        # view; grading the VALUE would mean re-implementing systemd's mount resolution, and the pin unit
        # needs no mounts of its own.
        # ⛔ AND THE OVERLAY MEMBERS (round-20 review, P2), the same class one layer down.
        # `ExtensionImages=`/`ExtensionDirectories=` set up a read-only OverlayFS on top of `/usr/` and `/opt/`
        # (`/etc/` for confext) — `systemd.exec(5)`. The payload lives under `$CELL_HOME` and is not reachable
        # that way, but the INTERPRETER is: `ExecStart=` is `/bin/bash`, which on a merged-`/usr` host is
        # `/usr/bin/bash`, so an extension image shadows the shell that executes the verified pass. Different
        # bytes still reach the exec, so it is closed here rather than argued about; MEASURED accepted (rc=0)
        # by `systemd-analyze verify` on a plain oneshot. The pin unit needs no mounts of any kind.
        bad "the rendered unit declares ${_c}= — systemd mounts into the unit's filesystem view BEFORE the payload runs, so the ExecStart this verification read is not necessarily the file that executes (BindPaths=/BindReadOnlyPaths= can put different bytes over it; TemporaryFileSystem= can replace it with an empty tmpfs; ExtensionImages=/ExtensionDirectories= overlay /usr and can shadow the INTERPRETER), and nothing here reads a mount; the pin unit needs no mounts of its own — remove the line"; return 1 ;;
    esac
  done
  # ⛔ NOTHING HERE IS GREEN ON A READING IT COULD NOT TAKE. 0 is ALWAYS a successful exit for a unit
  # (`systemd.service(5)`, `SuccessExitStatus=`: "…will be considered successful termination, IN ADDITION TO
  # THE NORMAL SUCCESSFUL EXIT STATUS 0"), so there is no rule to write about including it — the old
  # "must include 0" gate refused a valid unit and claimed a false PASS it could never prevent. What the
  # list must NOT do is WIDEN the vocabulary (any value beyond 0/11 greens a real failure), and what it MUST
  # do is COUNT 11 green: a lost pin record is mended and exits 11, so a unit that omits it goes RED on a box
  # that is in fact correct (#3133). Both halves are gated, one doctor each.
  declares "$body" SuccessExitStatus || { bad "the rendered unit must declare SuccessExitStatus=… — a non-zero exit is how this pass goes RED"; return 1; }
  # ⛔ THE EFFECTIVE LIST, NOT THE LINES CONCATENATED. `SuccessExitStatus=` may appear more than once and the
  # lists are MERGED — but `systemd.service(5)` adds that "if the empty string is assigned to this option,
  # the list is reset, all prior assignments … will have no effect". A line reader latches `11` from the
  # first line and never sees the empty one, so `SuccessExitStatus=` placed after the template's
  # `SuccessExitStatus=0 11` verified GREEN and wrote a unit whose effective vocabulary EXCLUDES 11 — the
  # unhealable mend RED (#3133) that the required-11 rule exists to prevent. MEASURED at rc=0, installed.
  # The directives are replayed IN ORDER with the reset honoured, so what is asserted on is what systemd
  # loads. (`verify_dropin_file` refuses `SuccessExitStatus=` in a drop-in outright, so this body is the
  # whole of the list.) Refusing the empty line instead was the cheaper fix and would have refused a valid
  # `SuccessExitStatus=` followed by `SuccessExitStatus=11`, which resolves to a correct list.
  ok_vals="$(printf '%s\n' "$svc" | awk '
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^SuccessExitStatus[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "", line)
      if (line == "") { acc = ""; next }
      acc = (acc == "" ? line : acc " " line)
    }
    END { print acc }')"
  [ -n "$ok_vals" ] || { bad "the EFFECTIVE SuccessExitStatus list is EMPTY — an empty 'SuccessExitStatus=' is a LIST RESET (systemd.service(5)), so every value counted above it is discarded and 'mended' (11) is no longer green, which makes every mend an unhealable RED (#3133); drop the empty line instead of clearing the list"; return 1; }
  while IFS= read -r v; do
    for w in $v; do
      case "$w" in
        0)  ;;
        11) seen11=1 ;;
        *)  bad "SuccessExitStatus lists '${w}', which is neither 0 (current/applied) nor 11 (mended) — a wider list greens a failure"; return 1 ;;
      esac
    done
  done <<<"$ok_vals"
  # ⛔ 11 IS REQUIRED, NOT MERELY ALLOWED. 11 is the MENDED code: a box whose pin record was lost has it
  # repaired and exits 11. A unit that does not count 11 green REDs on every mend — an unhealable RED on a
  # box that is in fact correct, the #3133 class this rule's own comment invents 11 for. "Allowed" without
  # "required" also left the rule untestable in the direction that matters: a doctor cannot tell a missing
  # 11 from a wider list, so nothing pinned it.
  [ "$seen11" -eq 1 ] || { bad "SuccessExitStatus must include 11 — 'mended' (a lost pin record was repaired) exits 11, and a unit that does not count it green goes RED on a box that is in fact correct (#3133)"; return 1; }
  return 0
}

# ── THE OTHER ARTIFACT THIS VERB INSTALLS: THE TIMER ───────────────────────────────────────────────────
# ⛔ `--install` WRITES TWO UNITS AND VERIFIED ONE. `verify_unit` is asserted on
# `$tmp/cell-self-pin.service` only; the rendered `cell-self-pin.timer` was written, placed and ENABLED
# with no assertion at all — the timer's DROP-INS are verified (`verify_dropins` above) but the timer
# ARTIFACT ITSELF was not. A timer is the whole mechanism: a pass that is perfect and never invoked is
# #3194's symptom — the pin stops advancing and NOTHING goes red — reached through the artifact path
# instead of the drop-in path. This file states that invariant one screen above the missing check, in its
# own refusal for a timer drop-in (`Unit|On*=`, `verify_dropin_file`): "a pin that silently never runs is
# #3194's symptom, one directive over".
# MEASURED in review against a pristine service template, doctoring ONLY the timer:
#   `Unit=/bin/true.service`   -> rc=0, "installed — ONE actuator"; the wrong target is on the box
#   `OnUnitActiveSec=` deleted -> rc=0; the timer keeps only `OnBootSec=3min`, so it fires ONCE, three
#                                 minutes after boot, and never again — the pin stops for ever
# Nothing reds at runtime either: `--status` prints the LAST OUTCOME and never gates on its age, so a dead
# clock leaves every surface green. The two rules below are what make the clock one that REPEATS and fires
# THE PASS.
# ⛔⛔ THE AUTHORITY ON "CAN systemd PARSE THIS VALUE" IS systemd, NOT THIS FILE (round-14 review).
# Three rounds of review each found ANOTHER spelling this file certified while the manager DISCARDED it
# (`10minx`, then `24:00:00`/`25:00`/`1000000000000000000y`, then `1..5 04:00:00`, `2200-01-01 04:00:00`,
# `32 04:00:00`, `04..03:00`, `04:0/0:00`, duplicate and misordered fields). MEASURED at the head this
# replaces: of a generated 240-form cross-product, 77 forms were accepted here and DISCARDED by systemd.
# That is not a bug to patch spelling-by-spelling — a hand-written re-implementation of systemd's calendar
# grammar is the defect, and each patch moved the boundary. So the parser is now ASKED, not imitated:
# `systemd-analyze calendar|timespan` ships in the same package as the `systemctl` this pass already
# depends on, and it is the only implementation that is faithful to the manager that will load the unit.
#
# ⛔ AND WHEN THERE IS NO PARSER TO ASK, THE FALLBACK IS A WHITELIST, NOT A GRAMMAR. `CELL_SELF_PIN_ANALYZE`
# is the seam (the suite pins it, so no leg depends on the host's binaries):
#   unset  → resolve `systemd-analyze` from PATH, and use it when present
#   none   → pretend there is no parser, which is the tier the by-construction whitelist governs
#   <cmd>  → that command line IS the parser (contract: `calendar -- <v>` / `timespan -- <v>`, rc=0 = ok)
# For `OnCalendar=` that tier accepts ONLY the ten documented shortcut words: any explicit expression is
# REFUSED, because verifying one without the manager's parser means writing that parser — and every
# attempt certified values systemd throws away. That is a REFUSAL (an operator edits one line, or installs
# `systemd-analyze`), never a false PASS — the whole lesson of #3194, and this file's own direction for
# `--install`'s drop-ins: an unverifiable reading is not a PASS.
timer_analyzer() { # prints the parser to ask, or nothing (rc=1) when there is none
  # ⛔ `:-`, NOT `-`: an EMPTY value means "resolve it", never "there is no parser". `-` distinguished
  # unset from empty and made `CELL_SELF_PIN_ANALYZE= ` — which is what a shell expands an unset variable to
  # in common launcher spellings — silently fall into the whitelist tier on a box that HAS the parser.
  # MEASURED while verifying this fix: with `CELL_SELF_PIN_ANALYZE=` set-empty, `OnCalendar=*-*-* 04:00:00`
  # was REFUSED although systemd accepts it. Only the explicit word `none` selects the fallback tier.
  local an="${CELL_SELF_PIN_ANALYZE:-__auto__}"
  case "$an" in
    none) return 1 ;;
    __auto__) an="$(command -v systemd-analyze 2>/dev/null || true)" ;;
  esac
  [ -n "$an" ] || return 1
  printf '%s\n' "$an"
}
# The NARROW timespan grammar, used ONLY when there is no parser. A time span is a closed, small grammar
# (number + unit, repeated), unlike a calendar expression, so this tier can verify it completely — and a
# review measured 31 spellings against `systemd-analyze timespan` without finding one it accepts and the
# manager refuses. The magnitude bound is a POLICY bound (100 years), not systemd's overflow edge: the
# manager accepts as far as ~584000y and refuses past it, and a cadence for a ten-minute pin is nowhere
# near either. `infinity` never reaches here — it is a VALID timespan that means NEVER, and is refused by
# name in `timer_value_ok` before any parser is asked.
timer_timespan_ok() { # <value>
  printf '%s\n' "$1" | awk '
    function unitmul(u) {
      if (u == "" || u == "s" || u == "sec" || u == "secs" || u == "second" || u == "seconds") return 1
      if (u == "ms" || u == "msec") return 0.001
      if (u == "us" || u == "usec") return 0.000001
      if (u == "m" || u == "min" || u == "mins" || u == "minute" || u == "minutes") return 60
      if (u == "h" || u == "hr" || u == "hrs" || u == "hour" || u == "hours") return 3600
      if (u == "d" || u == "day" || u == "days") return 86400
      if (u == "w" || u == "week" || u == "weeks") return 604800
      if (u == "M" || u == "month" || u == "months") return 2629800
      if (u == "y" || u == "year" || u == "years") return 31557600
      return 0
    }
    {
      v = $0
      if (v !~ /^[0-9]+(\.[0-9]+)?(us|msec|ms|usec|s|sec|secs|second|seconds|m|min|mins|minute|minutes|hrs|hr|h|hour|hours|d|day|days|w|week|weeks|M|month|months|y|year|years)?([[:space:]]+[0-9]+(\.[0-9]+)?(us|msec|ms|usec|s|sec|secs|second|seconds|m|min|mins|minute|minutes|hrs|hr|h|hour|hours|d|day|days|w|week|weeks|M|month|months|y|year|years)?)*$/) exit 1
      n = split(v, p, /[[:space:]]+/)
      total = 0
      for (i = 1; i <= n; i++) {
        num = p[i]; sub(/[a-zA-Z]+$/, "", num)
        u = substr(p[i], length(num) + 1)
        mul = unitmul(u)
        if (mul == 0) exit 1
        total += num * mul
      }
      exit (total > 0 && total <= 3153600000) ? 0 : 1
    }'
}
timer_value_ok() { # <directive> <value> — ok iff systemd can ACT on this value
  local k="$1" v="$2" an
  # ⛔ BEFORE ANY PARSER: `infinity` is a VALID timespan that means NEVER, so `systemd-analyze timespan`
  # ACCEPTS it — and a rule that only asked the parser would certify a clock that fires once. Measured, so
  # this refusal is deliberate and must not be "simplified" away by delegating.
  case " $v " in *" infinity "*) return 1 ;; esac
  if an="$(timer_analyzer)"; then
    case "$k" in
      OnCalendar) $an calendar -- "$v" >/dev/null 2>&1 ;;
      *)          $an timespan -- "$v" >/dev/null 2>&1 ;;
    esac
    return $?
  fi
  case "$k" in
    OnCalendar)
      case "$v" in
        minutely|hourly|daily|weekly|monthly|quarterly|semiannually|annually|yearly) return 0 ;;
      esac
      return 1 ;;
    *) timer_timespan_ok "$v" ;;
  esac
}

verify_timer() { # <rendered timer> [expected Unit= target]
  local f="$1" expect="${2:-cell-self-pin.service}" body timer units nunits _rep _badval _c
  local _trigs _reset _n _k _v _inst_vals
  # Comments are stripped for the same reason `verify_unit` strips them: this template documents the
  # cadence decisions it made, and that prose legitimately names the directives the rules below ban.
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  refuse_raw_text_tricks "the rendered timer" "$body" || return 1
  refuse_env_reset "the rendered timer" "$body" || return 1
  refuse_env_mutators "the rendered timer" "$body" || return 1
  # ⛔ A SKIPPED TIMER IS THE SAME GREEN NO-OP A SKIPPED SERVICE IS — and on a TIMER it is worse, because
  # the pass's own loudness never gets a chance to fire (nothing runs). Closed by PREFIX for the reason
  # `verify_unit` closes it by prefix: `Condition*` has thirty-plus members and every one of them leaves
  # the unit GREEN on a false condition.
  for _c in $(directive_names "$body"); do
    case "$_c" in
      Condition*) bad "the rendered timer declares ${_c}= — a failed condition SKIPS the timer and leaves it GREEN, so the pin never runs and nothing reds; a missing layer must be a RED payload exit, not a skip"; return 1 ;;
      RootDirectory|RootImage|WorkingDirectory|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountImages|ExtensionImages|ExtensionDirectories)
        # ⛔ THE ARM IS RIGHT AND THE REASON THIS FILE GAVE FOR IT WAS FALSE — corrected rather than removed,
        # because a directive a render BELIEVES it configured is the false-PASS class this whole file is
        # about, whether or not systemd acts on it. The old text cited `EXIT_CHDIR / 203`, which is a
        # SERVICE failure mode: measured, `systemd-analyze verify` answers `Unknown key name
        # 'WorkingDirectory' in section 'Timer', ignoring.` — the key is INERT in `[Timer]`, it cannot cause
        # CHDIR or 203 because a timer executes nothing. What it does do is survive review looking like a
        # constraint on the pin's clock while the manager drops it in silence, so it is refused for what it
        # is: a no-op that reads as configuration. (a timer needs no working directory and no root — the
        # timer fires the unit and the unit's own rules govern the payload's cwd.)
        bad "the rendered timer declares ${_c}= — that key is a [Service]-only directive, so systemd answers 'Unknown key name '${_c}' in section 'Timer', ignoring.' and the line has NO effect: it survives review as if it constrained the clock while the manager drops it in silence, which is a green no-op on the one surface that must not lie; a timer fires the unit and needs no working directory and no root — delete the line"; return 1 ;;
    esac
  done
  # ⛔ EXACTLY ONE `Unit=`, AND IT MUST NAME THE PASS. systemd defaults a MISSING `Unit=` to the same-name
  # service, so a re-targeted timer is silent on every surface this file prints: the timer is green, the
  # unit it fires is not this one, and the pin is stopped. A COUNT rule, because `[Timer]` is LAST-WINS — a
  # second `Unit=` overrides the first, so a presence test installs the wrong target green (the same
  # count-not-presence defect this file fixed for `Environment=CELL_HOME=` and `ExecStart=`).
  # ⛔ SECTION-BLIND PARSING IS A FAIL-OPEN ON A TIMER (measured in review). Deleting `OnUnitActiveSec=`
  # from `[Timer]` and appending `[Service]` + `OnUnitActiveSec=10min` installed **rc=0** and
  # `systemd-analyze verify` said only "Unknown section 'Service'. Ignoring." — so the timer kept
  # `OnBootSec=3min` alone, fired once three minutes after boot and never again, with every surface green:
  # the exact defect this function exists to refuse, reached THROUGH the rule meant to close it. The same
  # blindness in `verify_unit` fails CLOSED (a mis-sectioned `ExecStart=` makes `enable --now` fail); on a
  # timer there is nothing to fail, so the rules below read ONLY the `[Timer]` section. `Unit=` and the
  # repeating triggers are `[Timer]` directives: written anywhere else systemd ignores them, and a rule
  # that counted them there would be grading text nobody reads.
  timer="$(unit_section "$body" Timer)"
  [ -n "$timer" ] || { bad "the rendered timer declares no [Timer] section (or an empty one) — every trigger this unit needs lives there, and systemd ignores a trigger written in any other section, so this timer would install green and fire nothing"; return 1; }
  units="$(directive "$timer" Unit)"
  nunits=0
  [ -z "$units" ] || nunits="$(printf '%s\n' "$units" | wc -l | tr -d ' ')"
  if [ "$nunits" -ne 1 ]; then
    bad "the rendered timer declares ${nunits} Unit= line(s) — exactly one is installable and it must name the pass this run places ('${expect}'); systemd is LAST-WINS, so a second one silently re-targets the clock"; return 1
  fi
  if [ "${units%/}" != "${expect%/}" ]; then
    bad "the rendered timer's Unit='${units}' is not the pass this install places ('${expect}') — the clock would fire a unit this run never verified, and a timer that fires nothing is #3194's symptom (a pin that silently never runs) with every surface green"; return 1
  fi
  # ⛔ AND THE CLOCK MUST REPEAT. `OnBootSec=`/`OnStartupSec=` fire ONCE per boot and `OnActiveSec=` fires
  # once relative to activation, so a timer carrying only those runs the pass a single time and then never
  # again. THE REPEATING TRIGGERS are `OnUnitActiveSec=` (measured from the last pass — what this template
  # uses, and the cadence the unit states) and `OnCalendar=` (wall clock). At least one must carry a VALUE,
  # because an EMPTY `OnUnitActiveSec=` is ignored by systemd and silently degrades to the one-shot case.
  # ⛔ AND THE RULE MUST READ THE EFFECTIVE LIST, NOT LATCH A LINE. `systemd.timer(5)` on every one of
  # these: "If the empty string is assigned to ANY of these options, the list of timers is reset (both
  # monotonic timers and OnCalendar= timers), and all prior assignments will have no effect." So an
  # `OnCalendar=` (or empty `OnUnitActiveSec=`) placed AFTER a real value DISCARDS it — and `OnBootSec=`
  # with it — leaving a clock that fires once and never again, which is precisely the defect this rule
  # exists to refuse. A latch over `directive` cannot see that: it finds the earlier non-blank value and
  # returns success. MEASURED in review with `OnUnitActiveSec=…` followed by `OnCalendar=` and then
  # `OnBootSec=3min`: `--install` printed "installed", rc=0, effective clock = one-shot.
  # The replay below is the SAME shape the `SuccessExitStatus=` rule already uses (its own `awk` replay) — an empty
  # assignment is a LIST RESET for every list-shaped directive, so the lesson is applied once, here.
  # ⛔ AND THE VALUE MUST BE ONE THE MANAGER CAN PARSE — "non-blank" is not "effective". A rule that asks
  # only whether a value is PRESENT grades text, and systemd DISCARDS a value it cannot parse: `Failed to
  # parse timer value, ignoring: 10minx` (systemd.timer(5)), leaving the one-shot `OnBootSec=` alone. So
  # the rule that exists to refuse a dead clock certified one. MEASURED in review against the live systemd
  # 255 manager (`systemctl show -p TimersMonotonic` on a probe unit): `OnUnitActiveSec=10minx`,
  # `OnUnitActiveSec=10min # every ten minutes` and `OnCalendar=10min` each installed rc=0 with the
  # repeating trigger GONE from the effective list, while the control `10min` read back as
  # `OnUnitActiveUSec=10min ; OnBootUSec=3min`. The inline-comment spelling is the realistic one: an
  # operator editing the cadence appends a comment, and systemd.syntax(7) has NO trailing comments.
  # ⛔ AND THE VALUE MUST BE ONE THE MANAGER CAN ACT ON, NOT MERELY ONE THAT IS SHAPED LIKE ONE. Three
  # review rounds each found another spelling this file certified while systemd DISCARDED it — `10minx`, a
  # trailing comment, `24:00:00`, `25:00`, `1000000000000000000y`, `1..5 04:00:00`, `2200-01-01 04:00:00`,
  # `32 04:00:00`, a duplicate field — and MEASURED at the head before this, 77 of a 240-form cross-product
  # were accepted here and thrown away by the manager. The lesson is not a better grammar: a hand-written
  # re-implementation of systemd's calendar parser IS the defect, and each patch moved its boundary. So the
  # value is referred to `timer_value_ok`, which ASKS the manager's own parser (see above) and, with no
  # parser available, certifies only what it can verify by construction.
  # ⛔ THE ORDER AND THE RESET SEMANTICS ARE READ HERE, THE VALUES ARE JUDGED ELSEWHERE. This awk pass
  # only answers "which trigger directives are EFFECTIVE" — the ones after the LAST empty assignment,
  # because `systemd.timer(5)`: "If the empty string is assigned to any of these options, the list of
  # timers is reset". Whether a value is one the manager can ACT on is `timer_value_ok`'s job, so it is
  # answered by the manager's own parser rather than by a grammar written here.
  _trigs="$(printf '%s\n' "$timer" | awk '
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^(OnBootSec|OnStartupSec|OnActiveSec|OnUnitActiveSec|OnUnitInactiveSec|OnCalendar)[[:space:]]*=/ {
      k = line; sub(/[[:space:]]*=.*/, "", k)
      v = line; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      n++
      if (v == "") { reset = n; next }
      print n "\t" k "\t" v
    }
    END { print "R\t" reset + 0 }')"
  _reset="$(printf '%s\n' "$_trigs" | awk -F'\t' '$1 == "R" { print $2 }')"
  _reset="${_reset:-0}"
  _rep=0
  _badval=""
  while IFS=$'\t' read -r _n _k _v; do
    [ "$_n" = R ] && continue
    [ "$_n" -le "$_reset" ] && continue
    # Only a REPEATING trigger can keep the clock alive: `OnBootSec=`/`OnStartupSec=`/`OnActiveSec=`/
    # `OnUnitInactiveSec=` fire once, so a value of theirs never makes the pin repeat.
    case "$_k" in
      OnUnitActiveSec|OnCalendar) ;;
      *) continue ;;
    esac
    if timer_value_ok "$_k" "$_v"; then _rep=1; else _badval="$_badval $_k=$_v;"; fi
  done < <(printf '%s\n' "$_trigs")
  if [ "$_rep" -ne 1 ] && [ -n "$_badval" ]; then
    bad "the rendered timer's only REPEATING trigger(s) carry a value systemd cannot parse or CANNOT ACT ON (${_badval%; }) and no other one is valid — the manager DISCARDS such a value ('Failed to parse timer value, ignoring' / 'Failed to parse calendar specification, ignoring', systemd.timer(5)), which leaves the ONCE-per-boot OnBootSec=/OnStartupSec=/OnActiveSec= triggers alone, so the pin would run a single time and then stop for ever with every surface green. NOTE systemd.syntax(7): there are NO trailing comments, so a value followed by '#…' is an unparseable value. The verdict is the MANAGER's ('systemd-analyze calendar|timespan'), not this file's; where no parser is available on the box, an explicit OnCalendar= expression is REFUSED rather than certified, because verifying it without the parser means re-implementing it. Write a value the manager accepts ('OnUnitActiveSec=10min', 'OnCalendar=daily', 'OnCalendar=*-*-* 04:00:00'), or make 'systemd-analyze' available"; return 1
  fi
  [ "$_rep" -eq 1 ] || { bad "the rendered timer's EFFECTIVE trigger list declares no REPEATING trigger — OnBootSec=/OnStartupSec=/OnActiveSec= each fire ONCE, and an EMPTY OnUnitActiveSec=/OnCalendar= is a LIST RESET that discards every trigger above it, so the pin would run a single time and then stop for ever with every surface green (this template uses OnUnitActiveSec= for exactly this reason); declare a non-empty OnUnitActiveSec= or OnCalendar= and put no empty assignment after it"; return 1; }
  # ⛔ AND THE ENABLEMENT ITSELF MUST BE VERIFIABLE, NOT ASSUMED (round-16 review, P2). `do_install` ends by
  # running `systemctl enable --now cell-self-pin.timer` and, until this rule, concluded enablement from that
  # command's EXIT CODE. systemd exits **0** and creates **NO SYMLINK** for a unit with no installation
  # config: MEASURED on systemd 255.4, `enable` answers "The unit files have no installation config
  # (WantedBy=, RequiredBy=, UpheldBy=, Also=, or Alias= settings in the [Install] section …)", rc=0, and
  # `timers.target.wants/` is never created — while the same fixture WITH `[Install] WantedBy=timers.target`
  # links, and `is-enabled` answers `enabled` (without it: `static`, rc=0). So a template that lost its
  # `[Install]`, or a stale `$CELL_HOME/.pi/agent/templates/systemd` copy that never had one, installs GREEN
  # over a pin that never fires — #3194's symptom produced by the verb that exists to end it.
  # ⛔ THIS IS THE SAME MEASURED MECHANISM THE DROP-IN RULE ALREADY REFUSES (see `verify_dropin_file`'s
  # `[Install]` arm): a drop-in may not carry `[Install]` at all, and the RENDERED unit — whose enablement is
  # the thing `--install` actually claims — had no rule at all about it.
  # ⛔ THE LIST IS REPLAYED, NOT COUNTED (round-17 review, P3) — the same shape the `SuccessExitStatus=`
  # rule above uses. Each of `WantedBy=`/`RequiredBy=`/`UpheldBy=`/`Alias=` is a LIST, and
  # `systemd.unit(5)` resets it on an EMPTY assignment: `WantedBy=timers.target` followed by `WantedBy=`
  # leaves NO installation config (MEASURED on 255.4: `enable` answers "The unit files have no
  # installation config", rc=0, creates no link, `is-enabled` then says `static`) — and a rule that merely
  # counted non-blank values ABOVE the reset certified that dead clock. Order matters, so the replay honours
  # it rather than latching the first good line.
  # ⛔ AND `UpheldBy=` COUNTS: systemd's own "no installation config" message lists it, and MEASURED on
  # 255.4 a timer carrying only `[Install] UpheldBy=timers.target` DOES link
  # (`timers.target.upholds/<unit>`) and reads `enabled` — so omitting it was a FALSE REFUSAL of a
  # legitimate shape (round-17 review, P3). `Also=` is deliberately NOT in the list: it enables OTHER
  # units, creates no link for this one, and leaves `is-enabled` answering `indirect` — systemd's word for
  # "the unit file itself is not enabled", the exact state `own_state` maps to `disabled`.
  # ⛔ AND `Alias=` IS NOT AN ENABLEMENT EITHER — IT CERTIFIED A DEAD CLOCK (round-18 review, P2). `Alias=`
  # creates a symlink for a DIFFERENT NAME pointing AT this unit; it never puts this unit into any target's
  # `.wants/`, so nothing starts it. It was briefly in this list on the strength of "systemd accepts it",
  # and that was a FALSE PASS in the one shape the read-back cannot catch: MEASURED on 255.4, an
  # `Alias=`-only timer answers `enable` rc=0, creates `cell-self-pin-legacy.timer -> …` with NO
  # `timers.target.wants/`, and then `is-enabled` answers **`enabled`** (rc=0) — so `own_state` goes green
  # and `--install` prints its own success over a pin that never fires. `Also=` fails safe here only
  # because it answers `indirect`; `Alias=` is the one that lies. A link under another name is not a
  # schedule, so it is not an installation config.
  # ⛔ A rule that fires on a state another arm already refuses cannot be gated (its removal changes only
  # the wording), so [Install] PRESENCE is not a separate arm: the replay below reports the same state for
  # a missing section, an empty one, and a fully reset one, and it is the arm a leg reds.
  _inst_vals="$(unit_section "$body" Install | awk '
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^(WantedBy|RequiredBy|UpheldBy)[[:space:]]*=/ {
      key = line; sub(/[[:space:]]*=.*$/, "", key)
      val = line; sub(/^[^=]*=[[:space:]]*/, "", val)
      if (val == "") { acc[key] = ""; next }
      acc[key] = (acc[key] == "" ? val : acc[key] " " val)
    }
    END { for (k in acc) if (acc[k] != "") { print k "=" acc[k]; n++ } }')"
  [ -n "$_inst_vals" ] || { bad "the rendered timer carries NO EFFECTIVE installation config — systemd applies [Install] at ENABLE time, and with no non-blank WantedBy=/RequiredBy=/UpheldBy= left after replaying the list (an EMPTY assignment is a LIST RESET, systemd.unit(5)), 'systemctl enable' exits 0 and creates NO symlink that schedules this unit (measured, systemd 255.4: 'The unit files have no installation config', rc=0, no link, 'is-enabled' then answers 'static'), so '--install' would print its own success over a pin that never fires. NOTE Alias= does NOT count: it links a different NAME at this unit, never this unit into a target, and measures 'enabled' — a green read on a clock that is never started. The template must declare '[Install]' with 'WantedBy=timers.target'"; return 1; }
  return 0
}

# ── the EFFECTIVE unit: the fragment systemd loads, which is NOT the file this run wrote ───────────
# ⛔ `verify_unit` READS THE ARTIFACT THIS RUN RENDERED. systemd does not read that file alone: it MERGES
# every `<unit>.service.d/*.conf` drop-in over it, in both managers, whether the drop-in was written
# before the main unit or after it. So an installed legacy drop-in can reinstate the exact defect this
# change exists to remove while `--install` prints "installed — ONE actuator" and exits 0 — a false PASS
# in the one function whose job is to make the migration safe.
# AND THIS IS THE MEASURED HISTORY, NOT A HYPOTHESIS. The defect in the issue lived in a DROP-IN
# (`WorkingDirectory=/tmp/cell-ai`), and a box in this fleet still carries
# `cell-self-pin.service.d/user.conf` today — so the drop-in directory is the half of the effective unit
# that no check in this file looked at.
# THE RULE. A drop-in MAY adjust IDENTITY only within the ONE identity that can pin — `User=` naming the
# owner of `$CELL_HOME`, and `Environment=HOME=`: that is how an operator corrects the render without a
# second copy of the unit. It MAY NOT re-open a class `verify_unit` closed — an executable directive, a
# working directory, a condition (a green skip), a wider success vocabulary, an ALLOCATED or overridden
# identity (`DynamicUser=`), or any directive that changes the pass's ENVIRONMENT behind the `Environment=`
# rules — because every one of those is a directive this file does not verify and systemd applies anyway.
# ⛔ THIS LIST IS THE THING THAT WAS WRONG TWICE. It once advertised `User=` as freely adjustable while
# `verify_unit` refused it (a drop-in `User=root` installed rc=0), and then it was not updated when
# `DynamicUser=` became a refused class — so the header that the arms below are written FROM said the
# opposite of the code (round-13 and round-3 reviews). A header that enumerates a closed class is a
# specification, and it has to move with the arms.
# ⛔ WHERE systemd ACTUALLY LOOKS — `verify_dropins` READ ONE DIRECTORY, AND THAT IS NOT THE SET.
# `systemd.unit(5)`:
#   · "for unit names containing dashes, the set of directories generated by repeatedly truncating the unit
#     name after all dashes is searched too" — `cell-self-.service.d/` and `cell-.service.d/` BOTH apply to
#     `cell-self-pin.service`;
#   · "Units also support a top-level drop-in with type.d/" — `service.d/` applies to EVERY service;
#   · "the drop-in .d/ directories for system services can be placed in /usr/lib/systemd/system or
#     /run/systemd/system" as well as /etc/systemd/system.
# MEASURED before this: a `cell-.service.d/legacy.conf` carrying `Environment=CELL_HOME=/tmp/other-home`
# installed rc=0 and NOTHING in the run mentioned the file — the same false PASS one directory over, on the
# very defect class (#3194's drop-in) this section exists for. The dirs are enumerated from systemd's own
# rule rather than a list of the paths somebody happened to think of.
# ⛔ THE ROOT LIST MUST BE systemd's OWN LOAD PATH, AND IT WAS THREE PATHS SOMEBODY THOUGHT OF. MEASURED on
# systemd 255, with a probe drop-in planted under each candidate and `systemd-analyze verify --root`:
# `systemd-analyze unit-paths` prints TWELVE entries, and EIGHT of them merge a `<unit>.d/*.conf` over the
# unit — the four `.control`/`.attached` roots, `/etc/systemd/system`, `/run/systemd/system`,
# `/usr/local/lib/systemd/system` and `/usr/lib/systemd/system`. `run/systemd/transient` and the three
# `generator` entries did NOT merge in that measurement, so they are deliberately not listed (listing a
# directory that cannot hold an effective drop-in would only add a refusal surface). The ninth entry,
# `/lib/systemd/system`, is the same directory as `/usr/lib/systemd/system` on a USRMERGE host (`ls -ld /lib`
# -> `usr/lib` there) and a distinct real load path on a non-usrmerge one — which is the only reason it
# earns a line: listing it costs nothing where they alias, and is load-bearing where they do not.
# `systemd.unit(5)` Table 1 puts `/usr/local/lib/systemd/system` — "System units installed by the
# administrator" — ABOVE `/usr/lib/systemd/system`, and lists the `.control`/`.attached` entries as
# "Persistent and transient configuration created using the dbus API", which is ABOVE `/etc/systemd/system`.
# ⛔ AND THIS LIST HAS BEEN WRONG TWICE, BOTH TIMES AS A SUBSET: it once omitted
# `/usr/local/lib/systemd/system`, and then it omitted all four `.control`/`.attached` roots — each time
# leaving a directory systemd MERGES read by NOTHING, so a legacy `cell-self-pin.service.d/*.conf` carrying
# the very `WorkingDirectory=/tmp/cell-ai` this change removes was merged OVER the rendered unit while
# `--install` printed "installed — ONE actuator on this pin" and exited 0: #3194's false PASS inside the
# function whose only job is to close it (review rounds 5 and 4). The static paths stay, because an
# installer must work on a box with no `systemd-analyze`; what changed is that the set is the MEASURED
# merge set rather than the four somebody happened to write down.
# `/etc/systemd/system` is scanned even when the caller redirects the unit dir (`SYSTEMD_UNIT_DIR`, which
# the suite uses), because systemd loads it regardless of what any install targets.
# `CELL_SELF_PIN_DROPIN_ROOTS` is the SEAM the suite plants a drop-in under: the real roots are root-owned,
# so a leg that cannot write them proves nothing about the enumeration — and MEASURED, deleting `/run` and
# `/usr/lib` from this list left the suite at 240 ok / 0 failed, i.e. nothing pinned it at all.
# ⛔ ONE ROOT PER LINE, NOT ONE SPACE-SEPARATED STRING. The consumer reads this line-by-line, and a root
# path containing a space was silently SPLIT by the shell into two paths that do not exist — so `--install`
# reported PASS over a root it never enumerated while the hostile drop-in inside it was merged by systemd
# (measured at this head, round-3 review P2: rc=0 with `CELL_SELF_PIN_DROPIN_ROOTS="$T/root with space"`,
# while the same drop-in in a space-free root is refused). The seam is a LIST OF EQUALITY-KNOWN PATHS, so
# its separator has to be one that cannot be a path character.
SYSTEMD_UNIT_ROOTS="/etc/systemd/system.control
/run/systemd/system.control
/etc/systemd/system
/etc/systemd/system.attached
/run/systemd/system
/run/systemd/system.attached
/usr/local/lib/systemd/system
/usr/lib/systemd/system
/lib/systemd/system"
# ⛔ THE ROOT LIST AND THE ENUMERATION UNDER ONE ROOT ARE TWO DIFFERENT QUESTIONS, and collapsing them into
# one function made the FIRST one unaskable — which is how an unsearchable root became a PASS (see
# `verify_dropins`). `dropin_roots` answers "where does systemd look"; `dropin_dirs` answers "which drop-in
# directories exist under THIS root". The root list is the input to a SEARCHABILITY check, so it has to be
# reachable even when nothing under the root can be listed.
dropin_roots() { # <unit-dir> — systemd's own search order, the unit dir first, ONE PATH PER LINE
  printf '%s\n' "$1"
  # ⛔ NO `for … in ${…}` HERE. A word-splitting loop is what turned a root containing a space into two
  # roots that do not exist — the fail-open the caller's `while IFS= read -r` exists to prevent, one level
  # above it. The seam and the default are both newline-separated lists, and this function passes them
  # through verbatim.
  printf '%s\n' "${CELL_SELF_PIN_DROPIN_ROOTS:-$SYSTEMD_UNIT_ROOTS}"
}

dropin_dirs() { # <root> <unit-name> — every drop-in directory systemd merges FROM THIS ROOT
  local root="$1" name="$2" base svc short seen=" " d
  svc="${name##*.}"
  base="${name%.*}"
  # the unit's OWN drop-in directory is `<unit>.<type>.d` (the full name), not `<unit>.d`
  for d in "$root/$name.d" "$root/$svc.d"; do
    case "$seen" in *" $d "*) continue ;; esac
    if [ -d "$d" ]; then seen="$seen$d "; printf '%s\n' "$d"; fi
  done
  # dash truncation: cell-self-pin.service -> cell-self-.service.d, cell-.service.d
  short="$base"
  while :; do
    case "$short" in *-*) ;; *) break ;; esac
    short="${short%-*}"; short="${short%-}"
    [ -n "$short" ] || break
    d="$root/${short}-.${svc}.d"
    case "$seen" in *" $d "*) continue ;; esac
    if [ -d "$d" ]; then seen="$seen$d "; printf '%s\n' "$d"; fi
  done
}

# root_decidable <path> — 0 when this run can DECIDE whether <path> exists.
# ⛔ `[ -e "$root" ]` IS AN ANSWER, NOT A READING, AND IT IS NOT ALWAYS A TRUE ONE. `stat` needs every
# component of the path to be SEARCHABLE, so a root whose PARENT is mode 000 answers `-e` FALSE — "absent"
# — when the truth is "this run cannot see". Treating that as an absent root is the same false PASS one
# level up from the one `verify_dropins` was just taught to refuse: measured, `$T/par` at 000 with
# `$T/par/root/cell-self-pin.service.d/legacy.conf` carrying `WorkingDirectory=/tmp/cell-ai` installs
# rc=0 and nothing in the run mentions the file. So the ancestors are checked first: an ancestor that
# exists but cannot be searched makes the child's existence UNDECIDABLE, and undecidable is a REFUSAL.
root_decidable() { # <path>
  local p="$1" d
  [ -e "$p" ] && return 0
  d="$p"
  while :; do
    d="$(dirname "$d")"
    if [ -e "$d" ]; then
      # ⛔ A NON-DIRECTORY ANCESTOR IS A DECIDED ANSWER, NOT AN UNDECIDABLE ONE: nothing can live under a
      # regular file, so the root provably does not exist. Treating it as undecidable refused a healthy
      # box and asserted a FALSE cause ("a parent is not searchable") about a searchable directory whose
      # child happens to be a file (measured, round-14 review P2). `-x` is the right test only for a
      # DIRECTORY, where it answers "can I look inside".
      [ -d "$d" ] || return 0
      [ -x "$d" ] && return 0
      return 1
    fi
    [ "$d" = "/" ] && return 0
    [ "$d" = "." ] && return 0
  done
}

verify_dropins() { # <unit-dir> <unit-name>
  local _root _dir f _seen=" "
  # ⛔ AN UNSEARCHABLE ROOT IS NOT A ROOT WITH NO DROP-INS — and it was, because the enumeration tested
  # `[ -d "$root" ]`, which stats the entry itself and needs only the PARENT to be searchable. MEASURED:
  # a root at mode 000 carrying `cell-self-pin.service.d/legacy.conf` with `WorkingDirectory=/tmp/cell-ai`
  # under it installed **rc=0**, and nothing in the run mentioned the file. A 000-mode directory still
  # stats true, so the root was PROCEEDED PAST, not skipped — `[ -d "$root/$name.d" ]` then failed for
  # every candidate under it and "no drop-ins found" was reported about a directory this run could not
  # open. systemd (root, and not bound by this run's permissions) merges whatever is inside. So the verdict
  # is taken on the ROOT, once, BEFORE anything under it is enumerated — a root that exists but cannot be
  # searched is a REFUSAL, never an empty result.
  # ⛔ AND THE ROOT LIST IS READ, NOT WORD-SPLIT. `for _root in $(dropin_roots …)` splits on IFS, so a
  # unit dir containing a space became several bogus roots that each failed `-e` and were skipped — the
  # enumeration would then report PASS while never looking at the real directory. One path per line.
  while IFS= read -r _root; do
    if ! root_decidable "$_root"; then
      bad "the systemd unit root ${_root} cannot be DECIDED by this run — a parent directory of it is not searchable, so 'it does not exist' and 'this run cannot see it' are the same answer here, and systemd (which is not bound by this run's permissions) may well be merging a ${2}.d/*.conf from it; fix the permissions on that parent (or remove the tree) and re-run"; return 1
    fi
    if [ -e "$_root" ]; then
      if [ ! -d "$_root" ]; then
        bad "the systemd unit root ${_root} exists but is NOT a directory, so this run cannot tell whether a drop-in for $2 lives in it — remove it (or make it the directory systemd's own unit-path list expects) and re-run"; return 1
      fi
      if [ ! -r "$_root" ] || [ ! -x "$_root" ]; then
        bad "the systemd unit root ${_root} (mode $(ls -ld "$_root" 2>/dev/null | cut -c1-10)) cannot be READ/SEARCHED by this run, so it was never enumerated — systemd can still merge a ${2}.d/*.conf from it, and 'nothing found here' is not 'nothing installed'; fix its permissions (or remove it) and re-run"; return 1
      fi
    fi
    # ⛔ AND THE ENUMERATION'S OUTPUT IS READ THE SAME WAY THE ROOT LIST IS. Fixing only the root list left
    # the fail-open one level down: `for _dir in $(dropin_dirs …)` splits on IFS, so a unit dir containing a
    # space produced a bogus path that either REFUSED with a false reason (mode blank, a directory that
    # never existed) or — with a same-named relative directory in the CWD — silently inspected the WRONG
    # directory while the real one, whose `.conf` systemd merges, was never read (measured, round-14
    # review P2). One path per line, so the enumeration cannot be re-interpreted by the shell.
    while IFS= read -r _dir; do
      # ⛔ AND THE SAME RULE ONE LEVEL DOWN: a drop-in DIRECTORY this run cannot read/enter expands
      # `"$_dir"/*.conf` to nothing, the loop body never ran, and this function reported PASS over a
      # directory whose contents systemd still merges. A guard on the feeder, not a count of an expansion
      # that already lost the evidence.
      case "$_seen" in *" $_dir "*) continue ;; esac
      _seen="$_seen$_dir "
      if [ ! -r "$_dir" ] || [ ! -x "$_dir" ]; then
        bad "the drop-in directory ${_dir} (mode $(ls -ld "$_dir" 2>/dev/null | cut -c1-10)) cannot be READ/SEARCHED by this run, so its .conf files were never inspected — systemd can still load one from it, and 'nothing found here' is not 'nothing installed'; fix its permissions (or remove it) and re-run"; return 1
      fi
      for f in "$_dir"/*.conf; do
        [ -f "$f" ] || continue
        verify_dropin_file "$f" "$2" || return 1
      done
    done < <(dropin_dirs "$_root" "$2")
  done < <(dropin_roots "$1")
  return 0
}

# ⛔ THIS READER SERVES TWO UNIT NAMES AND MUST SAY SO. `do_install` verifies the SERVICE's drop-ins and the
# TIMER's (`verify_dropins "$unit_dir" cell-self-pin.timer`), and a reason written for a service is FALSE for
# a timer: a timer executes nothing, so `WorkingDirectory=` cannot fail it at CHDIR and `RootDirectory=`
# cannot chroot a payload that does not exist — measured, `systemd-analyze verify` answers "Unknown section
# 'Service'. Ignoring." / "Unknown key name 'WorkingDirectory' in section 'Timer', ignoring." (round-3
# review, P2). The unit name is therefore a PARAMETER, and the inert-key reason is used for a `.timer`.
verify_dropin_file() { # <drop-in .conf> [unit-name] — one file's rules; split out so the search-path loop stays a loop
  local f="$1" unm="${2:-}" body _c _kv grep_rc _expect_user _n_user _u
  local is_timer=0
  case "${unm##*.}" in timer) is_timer=1 ;; esac
    # ⛔ A READ THAT FAILED IS NOT A FILE WITH NOTHING IN IT, and that is the whole false PASS: `grep`'s
    # exit status used to be DISCARDED, so a drop-in this run could not read (0600 and root-owned, an I/O
    # error) produced an EMPTY body, every rule below passed on nothing, and `--install` went on to print
    # "installed — ONE actuator on this pin" while systemd merged that unread file OVER the unit. Measured
    # on this host before the fix: `grep -vE … <0600 file>` → rc=2, empty stdout, PASS. A file systemd can
    # load and this verification cannot see must be a REFUSAL, never a PASS.
    # ⛔ THIS GATE RUNS FIRST, BEFORE ANYTHING READS THE FILE A SECOND WAY: the shell's own `tr <"$f"` on an
    # unreadable path prints its redirection error and yields an EMPTY stream, which the NUL rule below
    # would then mis-report as "a binary file" — the right refusal for the wrong reason, and untestable as
    # a read gate because no leg could reach it.
    # ⛔ AND `grep`'s rc=1 IS NOT A READ FAILURE — it is "this file has no non-comment lines", i.e. a drop-in
    # with NOTHING to verify, which is compliant. Treating every non-zero as a read failure refused an EMPTY
    # or comment-only drop-in with a remedy naming permissions that were already correct (measured: `: >
    # empty.conf`, `-rw-r--r--`, refused). The read-failure arm is rc>=2 (GNU and BSD grep both use 2 for
    # "cannot read"); `-v` selecting nothing is 1.
    body="$(LC_ALL=C grep -vE '^[[:space:]]*#' "$f")"; grep_rc=$?
    if [ "$grep_rc" -gt 1 ]; then
      bad "the installed drop-in ${f} cannot be READ by this run, so its contents were never verified — systemd will still merge it over the rendered unit, and anything inside it (a WorkingDirectory=, a Condition*=, a re-pointed Environment=) is exactly what this gate exists to refuse; fix its permissions (or remove it) and re-run"; return 1
    fi
    # ⛔ A BINARY FILE IS NOT A FILE WITH NO DIRECTIVES. `grep` treats a file carrying a NUL byte as binary
    # and does NOT answer with the matching lines: GNU grep prints one `Binary file <path> matches` line,
    # BSD/macOS grep prints `binary file matches` on STDERR and nothing on stdout — MEASURED on this host,
    # rc=0 with an EMPTY body. So a legacy drop-in holding `\0` and `WorkingDirectory=/tmp/cell-ai` produced
    # a body every rule below passed on nothing, and the gate called it compliant. Refused on the file's
    # BYTES, before grep can decide what to call it, so the verdict does not depend on which grep is in PATH.
    if [ "$(LC_ALL=C tr -d '\000' <"$f" | wc -c | tr -d ' ')" != "$(LC_ALL=C wc -c <"$f" | tr -d ' ')" ]; then
      bad "the installed drop-in ${f} contains a NUL byte, so it is a BINARY file to grep and its directives cannot be read this way (measured: an EMPTY body with rc=0, or a single 'Binary file … matches' line) — every rule in this gate would run on nothing and report COMPLIANT on a file carrying any directive at all; a systemd drop-in is a text file, so remove ${f} and re-run"; return 1
    fi
    # The same three parse-level rules the rendered unit gets, in the same one place: a drop-in is NOT a
    # safer place for a continuation, a C-style escape, an `Environment=` reset, or an
    # `EnvironmentFile=`/`UnsetEnvironment=`/`PassEnvironment=` — it is a MORE dangerous one, because it is
    # merged OVER the unit and an operator reading the unit will never see it.
    refuse_raw_text_tricks "the installed drop-in ${f}" "$body" || return 1
    refuse_env_reset "the installed drop-in ${f}" "$body" || return 1
    # ⛔ A DROP-IN MAY NOT CARRY `[Install]` AT ALL, AND THIS WAS THE LAST DOOR IN THE ENABLEMENT PATH.
    # systemd applies `[Install]` at ENABLE time, not at load time, so none of the load-time rules above
    # can see it — and `WantedBy=`/`RequiredBy=` are LISTS with the same empty-assignment RESET this file
    # already refuses for `Environment=` and `SuccessExitStatus=`. MEASURED on systemd 255: a
    # `cell-self-pin.timer.d/*.conf` carrying `[Install]` + `WantedBy=` makes `systemctl enable` answer
    # "The unit files have no installation config (WantedBy=, RequiredBy=…)" and exit **0** while creating
    # NO symlink, so `--install` prints its positive claim and exits 0 over a pin that is never enabled —
    # #3194's "never runs, every surface green", one boot later, through the drop-in half of the effective
    # unit. (The control with the drop-in removed reads `enabled` and has the symlink.) Refused by SECTION
    # rather than by key, because the whole section is meaningless here: the rendered unit already declares
    # the enablement, and a drop-in can only reset or duplicate it.
    # ⛔ AND IT IS A HERE-STRING, NOT A PIPE: `printf … | grep -q` is the SIGPIPE false-negative idiom
    # (#841/#864) that `scripts/check-no-sigpipe-grep.sh` refuses, and this file's other 13 occurrences were
    # already converted — these two were missed by the later round that added the [Install] rule.
    if grep -qv '^[[:space:]]*$' <<<"$(unit_section "$body" Install)"; then
      bad "the installed drop-in ${f} carries an [Install] section — systemd applies that at ENABLE time, where an empty WantedBy=/RequiredBy= is a LIST RESET that makes 'systemctl enable' exit 0 and create NO symlink (measured: \"The unit files have no installation config\", rc=0), so 'installed' would print over a pin that is never enabled; the rendered unit already declares its enablement — remove ${f}"; return 1
    fi
    refuse_env_mutators "the installed drop-in ${f}" "$body" || return 1
    if [[ $body =~ (^|[[:space:]=])/(private/)?(var/)?tmp/cell-ai(/|[[:space:]]|$) ]]; then
      bad "the installed drop-in ${f} names the provisioning clone (/tmp/cell-ai) — a drop-in OVERRIDES the rendered unit, so rewriting only the unit cannot remove that path; remove ${f} and re-run (a pin unit needs no drop-in)"; return 1
    fi
    for _c in $(directive_names "$body"); do
      # ⛔ A TIMER HAS NO PAYLOAD, SO THE WHOLE [Service]-ONLY FAMILY IS INERT IN ITS DROP-IN — and the
      # per-name arms below state SERVICE causes ("it refuses to start the unit", "systemd enters that root
      # BEFORE the payload runs", "the pass would run as that user"), every one of which is FALSE for a
      # `.timer`. MEASURED: `systemd-analyze verify` answers "Unknown key name 'User' in section 'Timer',
      # ignoring." for `[Timer] User=root`, and the same for DynamicUser/WorkingDirectory/RootDirectory.
      # The refusal is right either way (an inert key that reads as configuration is a green no-op), so the
      # verdict does not change — only the CAUSE, which is the difference between an operator deleting the
      # right line and hunting a failure mode a timer cannot have (round-4 review, P2). Guarding the FAMILY
      # here rather than branching each arm is deliberate: this file has fixed "closed by one name" three
      # times, and a new service-only arm added later is covered without another review.
      if [ "$is_timer" -eq 1 ]; then
        case "$_c" in
          WorkingDirectory|RootDirectory|RootImage|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountImages|ExtensionImages|ExtensionDirectories|Exec*|SuccessExitStatus|DynamicUser|User|Environment|EnvironmentFile|UnsetEnvironment|PassEnvironment)
            bad "the installed drop-in ${f} declares ${_c}= in a TIMER drop-in — that directive is [Service]-only, so systemd IGNORES it in a [Timer] section (measured: \"Unknown key name '…' in section 'Timer', ignoring.\") and no value of it can change what the pin does; the line has NO effect and reads as configuration the manager discards — remove ${f}"; return 1 ;;
        esac
      fi
      case "$_c" in
        WorkingDirectory)
          bad "the installed drop-in ${f} declares WorkingDirectory= — it refuses to start the unit when the directory is gone (EXIT_CHDIR 200), which is the defect this change replaces; remove ${f}"; return 1 ;;
        Condition*)
          bad "the installed drop-in ${f} declares ${_c}= — a failed condition SKIPS the unit and leaves it green; remove ${f}"; return 1 ;;
        RootDirectory|RootImage)
          # The same "never began" class as `WorkingDirectory=`, one syscall over: systemd enters that root
          # before the payload runs. Refused in the drop-in path too, because a drop-in is merged OVER the
          # unit and an operator reading the unit will never see it.
          bad "the installed drop-in ${f} declares ${_c}= — systemd enters that root BEFORE the payload runs, so a path that is not a live-cell invariant is a unit that never began; remove ${f}"; return 1 ;;
        BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountImages|ExtensionImages|ExtensionDirectories)
          # ⛔ THE SAME MOUNT-REDIRECTION CLASS AS `RootDirectory=`, ONE STEP CLOSER (round-19 review, P1),
          # together with its OVERLAY members, which reach the exec one layer lower (round-20 review, P2).
          # `systemd.exec(5)` mounts these into the unit's own view before the payload runs: the bind family
          # and `MountImages=` (destination is FREE-FORM) put different bytes over the exact `ExecStart` path
          # the rendered artifact was verified against; `ExtensionImages=`/`ExtensionDirectories=` overlay
          # `/usr/`+`/opt/` (`/etc/` for confext), which shadows the INTERPRETER — `/bin/bash` is
          # `/usr/bin/bash` on a merged host. All of it reaches the exec through the file systemd merges OVER
          # that artifact, which an operator reading the unit will never see. ONE arm and ONE message for the
          # family, deliberately: the reason is true for every value (this verification reads no mount, so
          # nothing it approved survives the unit's view), and a single arm is what lets the suite gate the
          # list instead of one name per review.
          bad "the installed drop-in ${f} declares ${_c}= — systemd mounts into the unit's filesystem view BEFORE the payload runs and nothing here reads a mount, so the drop-in can put different bytes over the ExecStart the rendered unit was verified with (BindPaths=/BindReadOnlyPaths=), replace that path with an empty tmpfs (TemporaryFileSystem=), mount an image over it (MountImages=), or overlay /usr so the INTERPRETER that runs the pass is a different file (ExtensionImages=/ExtensionDirectories=; /bin/bash is /usr/bin/bash on a merged host); remove ${f}"; return 1 ;;
        Exec*)
          bad "the installed drop-in ${f} declares ${_c}= — an executable directive this verification does not read, which systemd RUNS anyway; the pass needs exactly ONE executable directive, ExecStart="; return 1 ;;
        SuccessExitStatus)
          bad "the installed drop-in ${f} declares SuccessExitStatus= — it would widen the unit's green vocabulary past 0/11, which is a false PASS; remove ${f}"; return 1 ;;
        DynamicUser)
          # ⛔ SAME VALUE-NEUTRAL REASON AS THE RENDERED-UNIT ARM (`DynamicUser=no` allocates nothing, so a
          # reason that names allocation is false for it). What is true for every value: this gate does not
          # read it, so the identity is unverified — and an identity that cannot be shown to be the tree's
          # owner is the drop-in `User=root` defect one directive over (measured rc=0 before this arm).
          bad "the installed drop-in ${f} declares DynamicUser= — this gate does not read its value, so it cannot show that the pass still runs as the owner of CELL_HOME (the identity whose git can answer for the tree it pins); an allocated or otherwise unverified identity is the drop-in User=root defect one directive over — remove ${f}"; return 1 ;;
        User)
          # ⛔ THE ONE DIRECTIVE THIS FUNCTION'S OWN COMMENT ADVERTISED AS ALLOWED AND NEVER READ. The
          # header above used to say a drop-in "MAY adjust IDENTITY (User=, Environment=HOME=)" — that
          # sentence is now restricted to the ONE identity that can pin, and the rule it introduces is that a
          # drop-in MAY NOT re-open a class `verify_unit` closed — and `verify_unit`
          # refuses any `User=` that is not the owner of `$CELL_HOME`, because that is the identity whose
          # git can answer for the tree this pass pins. MEASURED: a drop-in carrying `User=root` installed
          # **rc=0** and printed "installed — ONE actuator on this pin" — the exact #3194 outcome
          # (`UNRESOLVED(no-layer)` every tick, root's git refusing the cell user's checkout as dubious
          # ownership) reached by applying this file's own documented migration. Worse than a dead pin: the
          # payload lives under `$CELL_HOME/.pi/agent/scripts`, owned by the cell user, so a root-runnable
          # artifact executes bytes that user can replace.
          # ⛔ AND AN EMPTY `User=` IS THE SAME DEFECT, not a harmless reset: `systemd.exec(5)` restores the
          # manager's default identity, which for a SYSTEM unit is root. `$(directive …)` cannot see it (an
          # empty value and an absent one both yield the empty string), so the value is read as RAW LINES
          # through a process substitution, which preserves an empty field.
          # Derived here, never passed in, so the drop-in rule and the rendered-unit rule cannot disagree
          # about the expected owner.
          _expect_user="$(cell_home_owner)" \
            || { bad "cannot determine the owner of CELL_HOME ('${CELL_HOME}') to verify the drop-in ${f}'s User= against — refusing rather than accepting an identity nothing can check"; return 1; }
          _n_user=0
          while IFS= read -r _u; do
            _n_user=$((_n_user + 1))
            [ "$_u" = "$_expect_user" ] && continue
            if [ -z "$_u" ]; then
              bad "the installed drop-in ${f} declares an EMPTY User= — systemd resets to the manager's DEFAULT identity, which for a system unit is root, and root's git cannot answer for the tree this pass pins (dubious ownership), so every tick REDs with the unit still reporting installed; a drop-in may adjust IDENTITY, and the only installable identity here is '${_expect_user}', the owner of CELL_HOME; remove ${f}"; return 1
            fi
            bad "the installed drop-in ${f} declares User='${_u}' — it is merged OVER the rendered unit, so the pass would run as that user instead of '${_expect_user}', the owner of CELL_HOME; the pin would then fail on every tick (that identity's git cannot answer for the tree) while this install reported success; a drop-in may adjust IDENTITY, never to an identity that cannot pin; remove ${f}"; return 1
          done < <(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*User[[:space:]]*=[[:space:]]*//p')
          # ⛔ AND THERE IS DELIBERATELY NO `$_n_user -eq 0` ARM. This arm only runs for a name
          # `directive_names` matched, and that regex (`^[[:space:]]*User[[:space:]]*=.*`) requires the
          # same `=` this `sed` splits on, so the sed always yields at least one line — an EMPTY value
          # included, which is what the process substitution is for. Such a branch could never fire; a
          # refusal arm no leg can reach is exactly what this file refuses elsewhere, so it is not
          # written at all (round-14 review, P2). `_n_user` is kept as the count that the loop fills,
          # so a future rule can assert on it without re-deriving it.
          ;;
        Unit|On*)
          # ⛔ A TIMER DROP-IN CAN RE-TARGET OR RE-SCHEDULE THE PIN. `Unit=` names the unit the timer
          # activates and the `On*=` family sets when it fires, so a drop-in carrying either makes the timer
          # activate something else, or stop firing on the ten-minute clock — a pin that silently never
          # runs, which is #3194's own symptom reached from the timer's side. Both are closed by prefix
          # (`On*`) rather than one name at a time, the same rule this file uses for `Condition*`.
          bad "the installed drop-in ${f} declares ${_c}= — it re-targets or re-schedules the timer/unit pair this verification installed (a pin that silently never runs is #3194's symptom), or is a unit-level directive this check cannot honour; remove ${f}"; return 1 ;;
        Environment)
          # ⛔ A DROP-IN MAY ADJUST IDENTITY, AND THAT ALLOWANCE IS EXACTLY ONE VARIABLE WIDE. The
          # comment above this function names the remedy as `User=` (naming the owner) and `Environment=HOME=` — so allow
          # `HOME=` and refuse EVERY other `Environment=` assignment, rather than blocklisting the names
          # this file happens to know (`CELL_HOME`, `HARNESS_PIN_FILE`, `HARNESS`, `HARNESS_PIN_DIR`, …).
          # A blocklist here is the "family closed by one name" defect this file already fixed twice:
          # every one of those variables is READ by this pass, so a drop-in that sets any of them
          # silently re-points the pass at a different record while `--install` reports success. Allowed
          # names are the closed set; a variable systemd or a future revision adds is refused without
          # another review.
          for _kv in $(directive "$body" Environment); do
            _kv="${_kv%\"}"; _kv="${_kv#\"}"
            case $_kv in
              HOME=*) ;;
              *)
                bad "the installed drop-in ${f} sets 'Environment=${_kv%%=*}=' — a drop-in OVERRIDES the rendered unit, so an environment value other than HOME= can re-point the pass at a different pin record than the controller; a drop-in may adjust IDENTITY only to the owner of CELL_HOME (User=) and HOME=, never the base or the record it reads; remove ${f}"; return 1 ;;
            esac
          done ;;
      esac
    done
  return 0
}

# ── one actuator per pin, in BOTH systemd managers ──────────────────────────────────────────────────
# ⛔ BARE `systemctl` IS THE SYSTEM MANAGER ONLY, and the sibling installer this file names as the one
# to keep NEGOTIATES THE SCOPE: `install-harness-apply-timer.sh` falls back to `systemctl --user` /
# `$HOME/.config/systemd/user` when passwordless sudo does not answer, and `install-cell-timers.sh`
# does the same. On such a box `systemctl is-enabled eldato-harness-apply.timer` answers "no", the guard
# stays silent, and `--install` puts TWO mutating actors on one pin — precisely the race the guard's own
# comment says it exists to prevent. So ask BOTH, and NAME EVERY scope that answered — the answer is a
# LIST, not "the" scope (see `actuator_scopes`).
# systemctl_system — the SYSTEM manager, with the privilege the two MUTATING verbs need.
# ⛔ THIS PASS RUNS AS THE CELL USER, AND A NON-ROOT `systemctl disable --now` IS POLKIT'S `Access denied`.
# The rendered unit's `User=` is derived from the owner of `$CELL_HOME` (the identity whose git can answer
# for the tree being pinned), so the per-tick re-take could NEVER take in the system manager: `disable`
# failed, `one_actor_check` RED'd, and the tick exited before the apply — the pin stopped advancing, which
# is #3194's own outcome reached by following this change's documented migration. MEASURED in review as
# the cell identity: `systemctl disable --now <unit>` → `Failed to disable unit: Access denied` (polkit,
# before any unit lookup), while `systemd-run --system` fails the same way.
# READS STAY BARE (`is-enabled` needs no privilege), so the guard's verdicts never depend on privilege;
# only the two MUTATIONS escalate, and the escalation is the one the sibling installer already relies on
# (`install-harness-apply-timer.sh:389`: `[ -z "${SUDO+x}" ] && sudo -n true` → `sudo -n systemctl`).
# `CELL_SELF_PIN_SYSTEMCTL` is the seam that keeps this testable: the suite pins it to the fake manager so
# no leg can ever reach the host's real one, and the escalation leg (a fake `sudo`) exercises the probe.
systemctl_system() { # <args…> — the SYSTEM manager, escalated only when escalation is PROVEN to work
  local sc="${CELL_SELF_PIN_SYSTEMCTL:-}"
  if [ -z "$sc" ]; then
    if [ "$(id -u)" -eq 0 ] || ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
      sc="systemctl"
    else
      sc="sudo -n systemctl"
    fi
  fi
  # ⛔ THE SEAM IS A COMMAND LINE BY CONTRACT (that is how the sibling's `$SC` is used), so it is split
  # here and nowhere else.
  $sc "$@"
}
actuator_enabled_in() { # <scope> — is the SHIPPED timer enabled in that manager?
  case "$1" in
    system) systemctl is-enabled eldato-harness-apply.timer >/dev/null 2>&1 ;;
    user)   systemctl --user is-enabled eldato-harness-apply.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}
# ⛔ A MANAGER THAT DID NOT ANSWER IS NOT A MANAGER WITH NO ACTUATOR. `systemctl --user is-enabled` exits 1
# both for "disabled" and for "cannot reach the bus", and `actuator_enabled_in` discarded stderr, so the two
# were indistinguishable — while `--install` went on to print "read back in both managers". MEASURED on this
# box, in the environment a SYSTEM unit actually has: `systemctl --user is-enabled …` answers "Failed to
# connect to bus: No medium found" rc=1, i.e. indistinguishable from "disabled". That matters twice: a box
# whose shipped timer lives only in the USER manager (the no-sudo fallback `install-harness-apply-timer.sh`
# documents) would be reported as having ONE actuator while carrying TWO, and the per-tick `one_actor_check`
# would read the same non-answer as "clean". So the scope state is THREE-valued and the two callers must say
# which one they got. ⛔ The reachability test is the MANAGER'S OWN failure text, not a second probe: a probe
# that itself fails is one more thing that can lie, and the exit code carries the "disabled" answer already.
BUS_UNREACHABLE_PAT='Failed to connect to bus|No medium found|Failed to get D-Bus connection|Connection refused|Could not connect|Transport endpoint is not connected'
scope_state() { # <scope> — prints enabled | disabled | unknown (an UNANSWERABLE manager is NEVER 'disabled')
  local out rc
  case "$1" in
    system) out="$(systemctl is-enabled eldato-harness-apply.timer 2>&1)"; rc=$? ;;
    user)   out="$(systemctl --user is-enabled eldato-harness-apply.timer 2>&1)"; rc=$? ;;
    *)      printf 'unknown\n'; return 0 ;;
  esac
  # ⛔ ONE PATTERN LIST, NOT TWO. The spellings live in BUS_UNREACHABLE_PAT and are matched HERE, so a
  # vendor message added to that list cannot reach one caller and miss the other (an ERE, because `[[ =~ ]]`
  # is what lets the list stay a single named value; a `case` pattern is parsed before expansion and would
  # read `a|b` as one literal glob).
  if [[ "$out" =~ $BUS_UNREACHABLE_PAT ]]; then printf 'unknown\n'; return 0; fi
  # ⛔ POLARITY, NOT RESIDUE. `disabled` is a CLAIM the manager made about THIS unit, so only the
  # manager's OWN answer words may produce it — every other non-zero (an unrecognised failure text, a
  # D-Bus activation timeout, a vendor build's wording, an empty answer) is UNKNOWN, which is what this
  # function's own docstring promises. The old line was `[ "$rc" -eq 0 ] && enabled || disabled`, a
  # DENY-LIST: any failure spelling not in BUS_UNREACHABLE_PAT fell through to `disabled`, so an
  # unanswerable manager was reported as "no actuator" — the false PASS this block's comment says it
  # fixed, one spelling further out. MEASURED in review: systemd's real system-scope message
  # `Failed to connect to system scope bus via local transport: No such file or directory` (rc=1) does
  # NOT match `Failed to connect to bus` (the words `system scope bus via local transport` sit in
  # between) and read as `disabled`, so `--status` printed `second actuator <none>` over an UNREAD scope.
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      enabled|enabled-runtime) printf 'enabled\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  fi
  case "$out" in
    disabled|masked|masked-runtime|not-found|bad) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
# actuator_unknown_scopes — scopes whose manager did not answer, one per line. A scope listed here was NOT
# verified; a caller may not claim it was.
actuator_unknown_scopes() {
  local s
  for s in system user; do
    [ "$(scope_state "$s")" = unknown ] && printf '%s\n' "$s"
  done
  return 0
}
actuator_scopes() { # EVERY scope in which eldato-harness-apply.timer is ENABLED, one per line, system first
  local s n=0
  for s in system user; do
    if actuator_enabled_in "$s"; then printf '%s\n' "$s"; n=$((n + 1)); fi
  done
  [ "$n" -gt 0 ]
}
# ⛔ `actuator_scope` RETURNED ONLY THE FIRST ENABLED SCOPE, and that was a false PASS of its own: on a
# box that carries the timer in BOTH managers (the system install plus the no-sudo user fallback — the two
# shapes this file's own comment says it must handle) `--takeover` retired ONE of them, read THAT one
# back, and printed "ONE actuator on this pin" while the other stayed enabled. Two mutating actors, exit
# 0, and a claim of single ownership. There is no "the" scope: there is a LIST, and every member of it
# has to be retired and read back.
own_enabled_in() { # <scope> — is THIS unit installed in that manager?
  case "$1" in
    system) systemctl is-enabled cell-self-pin.timer >/dev/null 2>&1 ;;
    user)   systemctl --user is-enabled cell-self-pin.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}
# own_state <scope> — enabled | disabled | unknown, for THIS unit, from the MANAGER'S OWN WORDS.
# ⛔ WHY AN EXIT CODE CANNOT ANSWER THIS, AND WHY IT IS NOT `own_enabled_in` REUSED. `is-enabled` exits **0**
# for `static` — a unit with no installation config, which `enable` can never link. MEASURED on systemd 255.4:
# `systemctl enable` a timer carrying no `[Install] WantedBy=`/`RequiredBy=` prints "The unit files have no
# installation config", exits **0** and creates NO symlink, and `is-enabled` then answers `static`, rc=0. So
# the exit-code form answers "yes" for a timer that is never scheduled — a pin that never runs with every
# surface green, which is #3194's own shape one layer down (`--install` printing its positive claim over
# it). The polarity rule is `scope_state`'s (#1178: one polarity, not a second): only the manager's OWN
# answer word may produce a verdict, and an answer this code does not recognise is UNKNOWN — never `enabled`,
# and never `disabled` (an unanswerable manager is not a manager with no actuator).
# ⚠️ `own_enabled_in` IS DELIBERATELY LEFT AS IT WAS. It is `one_actor_check`'s predicate on the TICK, and
# narrowing it there (a `static` unit stops counting as a scheduled actor of ours) changes which ticks
# retire the shipped actuator — a decision this fix does not own. The install path is the one whose positive
# claim the read-back has to survive, and that is what `own_state` is used for.
own_state() { # <scope> — prints enabled | disabled | unknown
  local out rc
  case "$1" in
    system) out="$(systemctl is-enabled cell-self-pin.timer 2>&1)"; rc=$? ;;
    user)   out="$(systemctl --user is-enabled cell-self-pin.timer 2>&1)"; rc=$? ;;
    *)      printf 'unknown\n'; return 0 ;;
  esac
  if [[ "$out" =~ $BUS_UNREACHABLE_PAT ]]; then printf 'unknown\n'; return 0; fi
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      enabled|enabled-runtime|alias) printf 'enabled\n' ;;
      # systemd's answer for "no installation config": `enable` cannot link it, so it is never scheduled.
      static) printf 'disabled\n' ;;
      # ⛔ `indirect` IS NOT `enabled` (round-17 review, P3). `systemd.unit(5)`: with `indirect` "the unit
      # file itself is not enabled, but it has a non-empty Also= setting in the [Install] section" — i.e.
      # the manager answering `indirect` is telling us THIS unit has no link of its own. Accepting it as
      # enabled would make a read-back green over the very state it exists to catch.
      indirect) printf 'disabled\n' ;;
      # An empty or unrecognised answer is NOT a verdict about this unit.
      *) printf 'unknown\n' ;;
    esac
    return 0
  fi
  case "$out" in
    disabled|masked|masked-runtime|not-found|bad|static) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
# retire_actuator <scope> — RETIRE the shipped timer, explicitly. This is the one-actor decision, taken.
# ⛔ VERIFIED, NOT ASSUMED: a `disable` that did not take leaves exactly the state this whole guard exists
# to prevent, so the refusal is on the READ-BACK, not on the exit code.
retire_actuator() {
  local scope="$1" st
  case "$scope" in
    user)   systemctl --user disable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    system) systemctl_system disable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac || { bad "could not disable eldato-harness-apply.timer in the ${scope} manager — REFUSING to install a second actuator beside one I cannot retire (that is the race, not redundancy). In the system manager this needs root: '$0' runs as the owner of \$CELL_HOME, so check that passwordless sudo works ('sudo -n true') or retire it by hand: 'sudo systemctl disable --now eldato-harness-apply.timer'"; return 1; }
  # ⛔ THE READ-BACK IS `scope_state`, NOT AN EXIT CODE (round-12 review, P2). `actuator_enabled_in` is
  # `systemctl is-enabled … >/dev/null 2>&1`, and that exit code is 1 BOTH for "disabled" and for "cannot
  # reach the bus" — so an UNANSWERABLE manager read as RETIRED, which is the same deny-list polarity this
  # file fixed in `scope_state`, one function over, in the one place whose comment claims 'VERIFIED, NOT
  # ASSUMED'. `scope_state` already answers this question with the manager's OWN words, so it is reused
  # rather than re-implemented (#1178: one predicate, not a second).
  st="$(scope_state "$scope")"
  if [ "$st" = unknown ]; then
    bad "eldato-harness-apply.timer may still be ENABLED in the ${scope} manager: the manager did NOT ANSWER after 'disable --now', so the retirement is UNVERIFIED — REFUSING, because two mutating actors on one pin is a race, not redundancy. Re-run where that manager answers, or check it by hand ('systemctl is-enabled eldato-harness-apply.timer')"; return 1
  fi
  if [ "$st" != disabled ]; then
    bad "eldato-harness-apply.timer still reads ENABLED in the ${scope} manager after 'disable --now' — REFUSING: two mutating actors on one pin is a race, not redundancy"; return 1
  fi
  note "  RETIRED eldato-harness-apply.timer (${scope} manager)"
  return 0
}
# restore_actuator <scope> — put the shipped actuator BACK, and say whether the read-back agrees. Used
# ONLY to undo a retirement whose migration then failed, so the box never ends at zero pin actuators.
restore_actuator() {
  local scope="$1"
  case "$scope" in
    user)   systemctl --user enable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    system) systemctl_system enable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac || return 1
  actuator_enabled_in "$scope"
}

# pass_rollback — the TICK's exit guard, the counterpart of `do_install`'s rollback loop.
# ⛔ WHY THIS EXISTS AT ALL. `do_pass` retires the shipped actuator immediately before the ONE mutation it
# makes, so a failure AFTER that point leaves the shipped timer disabled AND stopped while this unit goes on
# failing every ten minutes — ZERO pin actuators, nothing advancing the layer, which is exactly the state
# #3194 is about. `do_install` already refuses to end there (its "Zero actuators is WORSE than two" arm);
# the tick had no equivalent, so following this change's own migration could reach #3194's own shape.
# EVERY terminal SUCCESS path in `do_pass` clears `PASS_RETIRED` first (`current`, `applied`, and the `mended`
# exit 11), so a non-empty value here means the tick failed — including a `loud 2 …` that exits from inside
# `check_pin_resolution`, which an inline rollback at each `exit` site could not have covered.
pass_rollback() {
  local rc=$? s
  [ -n "${PASS_RETIRED:-}" ] || return 0
  for s in $PASS_RETIRED; do
    if restore_actuator "$s"; then
      err "ROLLED BACK: eldato-harness-apply.timer re-enabled in the ${s} manager — this tick failed AFTER retiring it, so the box keeps the ONE pin actuator it had before the tick instead of none"
    else
      err "ROLLBACK FAILED in the ${s} manager: eldato-harness-apply.timer is DISABLED there and this tick failed, so this box now has NO pin actuator. Re-enable it by hand: 'systemctl enable --now eldato-harness-apply.timer'."
    fi
  done
  PASS_RETIRED=""
  return "$rc"
}

# one_actor_check <dry|apply> — the ONE-ACTOR invariant, re-read on EVERY tick rather than only at
# install time. ⛔ THE RE-ARM IS MEASURED, NOT HYPOTHETICAL: `cloud-cell-bringup.sh`'s
# `check_harness_apply` runs `install-harness-apply-timer.sh --install` on EVERY bring-up (`die` on a
# non-zero rc), and that installer's last act is `systemctl enable --now eldato-harness-apply.timer` —
# deliberately, because "they are what re-arms a timer somebody disabled by hand". So a box that has been
# through `--takeover` gets the second actor BACK at its next bring-up, and before this check nothing
# read it: the invariant the file refuses to break at install time was re-broken minutes later, silently,
# with the box's colour staying green.
#   · this unit is NOT enabled in either manager ⇒ this run is not a second scheduled actor. Say so and
#     touch NOTHING: a manual `bash cell-self-pin.sh` must never retire somebody's actuator.
#   · this unit IS enabled and the shipped timer came back ⇒ RE-TAKE the pin: retire it again in every
#     scope it reappeared in, read each one back, and say so.
#   · a re-take that does not take is a RED (`DUPLICATE-ACTUATOR`, exit 1), never a warning — two
#     mutating `apply --force --pin-only` actors on one pin IS the #2416 race this file exists to avoid.
one_actor_check() {
  local mode="$1" s dups ours="" who="" unknown=""
  # ⛔ AN UNANSWERABLE MANAGER IS NAMED HERE, ON EVERY TICK, AND IT DOES NOT MAKE THE TICK RED. The
  # invariant cannot be RETIRED blind (retiring an actuator in a scope we cannot read could leave the box
  # with ZERO pin actuators — the #3194 failure reached by the fix), and it must not be a permanent RED
  # either: a box whose user manager simply has no session bus would then be red every ten minutes for
  # ever, which is the "unhealable RED" this file refuses elsewhere. So the tick proceeds and the LIE is
  # removed: the log says which scope was not read, instead of implying the guard covered both.
  unknown="$(actuator_unknown_scopes)"
  if [ -n "$unknown" ]; then
    for s in $unknown; do who="$who ${s}"; done
    log "note: the${who} manager did NOT ANSWER (its bus is unreachable from here), so a duplicate actuator in that scope could NOT be checked this tick -- the one-actor invariant is UNVERIFIED there, not satisfied"
    who=""
  fi
  dups="$(actuator_scopes)" || return 0
  for s in system user; do own_enabled_in "$s" && ours="$ours $s"; done
  for s in $dups; do who="$who ${s}"; done
  if [ -z "$ours" ]; then
    log "note: eldato-harness-apply.timer is ENABLED (${who# }) and cell-self-pin.timer is not enabled in either manager -- this run is not a second scheduled actor, so nothing is retired"
    return 0
  fi
  if [ "$mode" = dry ]; then
    log "dry-run: eldato-harness-apply.timer is ENABLED (${who# }) beside this unit (it was RE-ARMED after --takeover) -- a real pass would retire it again in those manager(s). NOTHING was touched"
    return 0
  fi
  for s in $dups; do
    if ! retire_actuator "$s"; then
      record_outcome "duplicate-actuator (re-armed in the ${s} manager and could not be retired)"
      err "DUPLICATE-ACTUATOR: eldato-harness-apply.timer is ENABLED in the ${s} manager beside this unit (bringup re-arms it) and could NOT be retired -- two mutating actors on one pin is the #2416 race, so this tick is a RED. Remedy: disable it by hand in that manager ('systemctl disable --now eldato-harness-apply.timer', plus '--user' for the user manager), then re-run '$0 --install --takeover'."
      exit 1
    fi
    # Remembered so a tick that fails AFTER this retirement can put it back — `pass_rollback`. Recorded
    # here rather than inside `retire_actuator` so `do_install` (which keeps its own `$retired` list) is
    # not affected by the tick's guard.
    PASS_RETIRED="${PASS_RETIRED:-} $s"
  done
  log "re-took the pin: eldato-harness-apply.timer was RE-ARMED (${who# }) after --takeover and has been retired again -- ONE actuator on this pin, re-verified rather than assumed"
  record_outcome "re-took the pin (retired a re-armed eldato-harness-apply.timer in ${who# })"
  return 0
}

do_install() { # [--takeover]
  local takeover="${1:-}" unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}" tmp rc=0 u script scopes="" retired="" who="" s unknown="" still="" scopes_now="" retiring="" _own=""
  case "$takeover" in
    ""|--takeover) ;;
    *) bad "unknown argument '${takeover}' to --install (only --takeover is accepted)"; return 64 ;;
  esac
  # ⛔ A SCOPE THIS FILE DOES NOT RENDER IS A COMPLETE REFUSAL, never a half-install. It writes SYSTEM
  # units only; on a box with no system manager (or where the manager cannot be reached) it says so and
  # writes nothing, instead of leaving units that nothing will ever load — which is how "installed"
  # becomes a claim with no mechanism behind it.
  if [ -z "${SYSTEMD_UNIT_DIR:-}" ] && ! systemctl show-environment >/dev/null 2>&1; then
    bad "no systemd SYSTEM manager on this box ('systemctl show-environment' did not answer) — this unit is rendered for the system scope only, so REFUSING rather than writing units nothing will load. Target a manager you mean to install into with SYSTEMD_UNIT_DIR."
    return 1
  fi
  tmp="$(mktemp -d)" || { bad "mktemp failed"; return 1; }
  # ⛔ BEFORE ANY WRITE, VERIFY THE UNIT SYSTEMD WILL ACTUALLY LOAD — not only the file this run writes.
  # A legacy drop-in (`<unit>.service.d/*.conf`) is merged OVER the rendered unit, so it can carry the very
  # `WorkingDirectory=/tmp/cell-ai` this change removes while every rule below inspects a file nothing else
  # will read. Checking first also means a refusal mutates NOTHING, so a box that carries one keeps the
  # actuator it had instead of being told "installed" while still running the defect.
  verify_dropins "$unit_dir" cell-self-pin.service \
    || { err "refusing: an installed drop-in re-opens a class the rendered unit closed (reason above) — nothing was written and nothing was retired"; rm -rf "$tmp"; return 1; }
  # ⛔ AND THE TIMER'S DROP-INS ARE A SEPARATE SET. `dropin_dirs` enumerates the directories systemd
  # merges FOR THE NAME IT IS GIVEN, so verifying only the service left `cell-self-pin.timer.d/*.conf`,
  # `cell-self-.timer.d/`, `timer.d/` and the `/run` + `/usr/lib` copies completely unread — and the
  # `Unit=|On*=` arm written for exactly that threat could only ever fire on a SERVICE drop-in, where
  # systemd ignores both keys. MEASURED rc=0: a `cell-self-pin.timer.d/legacy.conf` carrying
  # `OnCalendar=` installed green and nothing in the run mentioned the file (and `Unit=/bin/true.service`
  # likewise). That is a pin that silently never runs — #3194's symptom reached from the timer's side.
  verify_dropins "$unit_dir" cell-self-pin.timer \
    || { err "refusing: an installed drop-in re-targets or re-schedules the timer this unit needs (reason above) — nothing was written and nothing was retired"; rm -rf "$tmp"; return 1; }
  # ⛔ RENDER → VERIFY → PLACE → INSTALL, in that order, and the order is the fix. Placement used to
  # happen inside the renderer, so a REFUSED install had already replaced the placed pass, and
  # `--print-unit` wrote a file. Verification now runs against the artifact BEFORE anything is written.
  print_unit "$tmp" || { err "refusing: the units could not be rendered (reason above)"; rm -rf "$tmp"; return 1; }
  # ⛔ THE PLACED PATH IS COMPUTED BEFORE VERIFICATION, so `verify_unit` can assert that the artifact's
  # ExecStart IS the pass this run places — not merely some path under $CELL_HOME. `pin_script_path` is a
  # pure computation (it writes nothing), so moving it up changes no ordering guarantee: the write is
  # still `place_pass`, and it is still AFTER every refusal.
  script="$(pin_script_path)" || { err "refusing: cannot locate the pass this unit would exec"; rm -rf "$tmp"; return 1; }
  verify_unit "$tmp/cell-self-pin.service" "$script" || { err "refusing: the rendered cell-self-pin.service failed verification (reason above)"; rm -rf "$tmp"; return 1; }
  # ⛔ AND THE TIMER IS THE OTHER HALF OF THE ACTUATOR THIS VERB INSTALLS AND ENABLES. Verifying only the
  # service left the whole clock unverified: `Unit=` re-targeted, or a timer with no repeating trigger, both
  # installed with rc=0 under the positive claim "installed — ONE actuator on this pin" and produced a pin
  # that never runs again — #3194's symptom through the artifact path. A COUNT/predicate gate, not a
  # presence test, for the same LAST-WINS reason as every other rule in this block.
  verify_timer "$tmp/cell-self-pin.timer" cell-self-pin.service || { err "refusing: the rendered cell-self-pin.timer failed verification (reason above)"; rm -rf "$tmp"; return 1; }
  # ⛔ ONE ACTUATOR PER PIN, AND THE REFUSAL COMES BEFORE ANY WRITE. `eldato-harness-apply.timer` already
  # advances this box's harness on the same 10-minute clock (#2416), and two mutating actors on one pin is a
  # race, not redundancy. The guard asks BOTH managers, NAMES every scope it saw, and `--takeover` is the
  # one-actor migration that retires it. ⛔ ⛔ THIS BLOCK USED TO SIT AFTER `place_pass`, which made the
  # duplicate-actuator refusal — the DEFAULT case on this fleet, where both timers are enabled today —
  # REPLACE the already-placed pass and then refuse: a refused install that had already mutated the box,
  # which is the exact class the `--install` ordering fix above was made for, left reachable one line later.
  # MEASURED: sentinel bytes at $CELL_HOME/.pi/agent/scripts/cell-self-pin.sh were overwritten by an
  # `--install` that exited 1 and wrote no unit. Nothing could see it either: the suite's refusal legs pass
  # CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1, which switches this very refusal off.
  scopes="$(actuator_scopes)" || scopes=""
  for s in $scopes; do who="$who ${s}"; done
  if [ -n "$scopes" ] && [ "$takeover" != --takeover ] && [ -z "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ]; then
    bad "eldato-harness-apply.timer is ENABLED in the ${who} manager(s) and already advances this harness on a ten-minute clock — two pin actuators race on one pin. Keep ONE: run '$0 --install --takeover' to RETIRE it and install this unit, or keep 'scripts/install-harness-apply-timer.sh --install' (the shipped, tested one) and do not install this one, or set CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 to override deliberately."
    rm -rf "$tmp"; return 1
  fi
  # ⛔ AND THIS REFUSAL DOES NOT DEPEND ON HAVING ALREADY SEEN AN ACTUATOR. It used to be gated on
  # `[ -n "$scopes" ]`, i.e. on the run having READ an enabled shipped timer somewhere — the OPPOSITE of the
  # condition it names. A box whose shipped timer lives ONLY in the manager that does not answer (the
  # documented no-sudo `systemctl --user` fallback, where the system probe answers "not enabled") therefore
  # skipped the refusal entirely, installed and enabled this timer, exited 0 and printed "nothing to retire"
  # — TWO mutating actors and a positive claim about a manager that said nothing, which is the #2416 race and
  # the #3194 punishment in one run. MEASURED with a fake manager whose `--user` answers "Failed to connect
  # to bus: No medium found": rc=0, user-scope shipped timer still ENABLED.
  if [ "$takeover" = --takeover ]; then
    # ⛔ A BLIND RETIREMENT IS REFUSED. `--takeover` DISABLES the shipped actuator, so if a scope cannot be
    # read the run cannot know what it is leaving behind there — and the failure modes are both bad: leave a
    # duplicate (two actors) or disable the only one (zero actors, #3194's own state). Verified by the READ
    # in every scope, never by the exit code of a disable we could not confirm.
    # ⛔ ⛔ AND THE REFUSAL MAY NOT BE A DEAD END, WHICH REACHABILITY MAKES IT (round-9 review, P1). A cell's
    # USER manager is unreachable from the identity that runs this installer (it writes /etc/systemd/system and
    # needs root; `systemctl --user` from root answers "Failed to connect to bus: No medium found" on a host
    # with no /run/user/<uid>). So on the fleet this migration targets, EVERY `systemctl --user` probe is
    # `unknown`, and an unconditional refusal here closes `--takeover` — while plain `--install` refuses too
    # (the duplicate-actuator arm sends the operator here). The two verbs then point at each other and the
    # documented ONE-actuator migration cannot be executed at all, with the remaining routes being the
    # two-actor race this design forbids or a hand `systemctl` retirement that loses `retire_actuator`'s
    # read-back. So the EXISTING deliberate-decision hatch reaches this path: it already means "I accept an
    # unverified/duplicate scope, on the record", and the post-install read-back still names every scope it
    # could not read. The default stays fail-closed; the decision is the operator's, and it is PRINTED.
    unknown="$(actuator_unknown_scopes)"
    if [ -n "$unknown" ] && [ -z "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ]; then
      who=""
      for s in $unknown; do who="$who ${s}"; done
      bad "--takeover cannot retire safely: the${who} manager did not answer, so this run cannot see whether a shipped eldato-harness-apply.timer is ENABLED there — retiring blind could leave TWO actors (a race) or ZERO (no pin at all). Nothing was written and nothing was retired. Re-run where that manager is reachable, or run 'systemctl --user is-enabled eldato-harness-apply.timer' yourself first. ⛔ On a box where that manager can never be reached from this identity (a root install has no user manager of its own), set CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 to accept ONE unverified scope deliberately: the retirement then covers every scope this run could READ, and the read-back names the scope it could not."
      rm -rf "$tmp"; return 1
    fi
    if [ -n "$unknown" ]; then
      who=""
      for s in $unknown; do who="$who ${s}"; done
      note "  ACCEPTED BLINDLY (CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR): the${who} manager did NOT ANSWER, so a shipped eldato-harness-apply.timer in that scope is NOT retired and the one-actor invariant there is UNVERIFIED — the read-back below says so, and it is not counted as verified"
    fi
  fi
  if [ -n "$scopes" ] && [ "$takeover" = --takeover ]; then
    # ⛔ AND IT NAMES THE SCOPES THAT WILL ACTUALLY BE RETIRED (round-14 review, P2). `$who` is reassigned
    # above to the scopes that did NOT ANSWER, so reusing it here printed "retiring the duplicate actuator in
    # the user manager(s)" on the documented no-sudo migration (unreadable `--user` + the hatch) and then
    # retired the SYSTEM one — the operator's only read of the migration naming the wrong manager. The
    # retirement list comes from `$scopes` (what the run could READ as enabled); `$who` stays the
    # unreadable-scope prose.
    retiring=""
    for s in $scopes; do retiring="$retiring ${s}"; done
    note "installing into $unit_dir (retiring the duplicate actuator in the ${retiring# } manager(s) LAST, after the units are placed)"
  elif [ -n "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ] && [ -n "$scopes" ]; then
    note "  WARNING: eldato-harness-apply.timer is ENABLED (${who# }) and CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR is set — two actuators on one pin, deliberately"
  else
    [ "$takeover" = --takeover ] && note "  (--takeover given, and no eldato-harness-apply.timer is enabled — nothing to retire)"
    [ "$takeover" = --takeover ] || note "installing into $unit_dir"
  fi
  # ⛔ AND ONLY NOW THE PLACED PASS — after every refusal that does not need the units on disk. Placement
  # is the first mutation this verb performs; nothing before it writes to the box.
  place_pass "$script" || { err "refusing: the pass could not be placed at $script"; rm -rf "$tmp"; return 1; }
  [ -f "$script" ] || { bad "the unit names '${script}' and it does not exist after placement — the unit would fail 203/EXEC before any payload runs"; rm -rf "$tmp"; return 1; }
  # ⛔ THE UNITS GO IN FIRST, THE RETIREMENT LAST, AND THAT ORDER IS THE FIX. `retire_actuator` used to run
  # before `mkdir`, the writes, `daemon-reload` and `enable --now` — so ANY failure in that second half
  # returned non-zero with the shipped timer already disabled AND stopped, and nothing re-enabled it:
  # measured, `--takeover` against an unwritable unit dir left the box with ZERO pin actuators, i.e. the
  # "nothing advances the layer" state #3194 is about, reached by following this change's own documented
  # migration. A migration may not destroy the thing it is replacing before the replacement exists.
  mkdir -p "$unit_dir" 2>/dev/null || { bad "cannot create $unit_dir — nothing was retired, so the box keeps the actuator it had"; rm -rf "$tmp"; return 1; }
  for u in cell-self-pin.service cell-self-pin.timer; do
    if [ -f "$unit_dir/$u" ] && cmp -s "$tmp/$u" "$unit_dir/$u"; then note "  $u unchanged"; continue; fi
    install -m 0644 "$tmp/$u" "$unit_dir/$u" || { bad "cannot write $unit_dir/$u — nothing was retired, so the box keeps the actuator it had"; rm -rf "$tmp"; return 1; }
    note "  $u written"
  done
  systemctl daemon-reload || { bad "'systemctl daemon-reload' failed — the units are on disk but not loaded, and nothing was retired, so the box keeps the actuator it had"; rm -rf "$tmp"; return 1; }
  # ⛔ NOW, AND ONLY NOW, THE RETIREMENT — immediately before the replacement is enabled. Every scope, and
  # a failure halfway through UNDOES the ones that did take.
  if [ -n "$scopes" ] && [ "$takeover" = --takeover ]; then
    for s in $scopes; do
      if ! retire_actuator "$s"; then
        for u in $retired; do
          restore_actuator "$u" && note "  ROLLED BACK: eldato-harness-apply.timer re-enabled in the ${u} manager (that retirement was not part of a completed migration)" \
            || bad "ROLLBACK FAILED in the ${u} manager: eldato-harness-apply.timer is DISABLED there, this unit is NOT enabled, and that box now has NO pin actuator. Re-enable it by hand:'systemctl enable --now eldato-harness-apply.timer'."
        done
        rm -rf "$tmp"; return 1
      fi
      retired="$retired $s"
    done
  fi
  if ! systemctl enable --now cell-self-pin.timer; then rc=1; fi
  # ⛔ ⛔ AND THE ENABLE IS READ BACK, NOT INFERRED FROM ITS EXIT CODE (round-16 review, P2). `systemctl enable`
  # exits **0** and creates **NO SYMLINK** for a unit with no installation config — MEASURED on systemd 255.4:
  # "The unit files have no installation config (WantedBy=, RequiredBy=, UpheldBy=, Also=, or Alias= …)", rc=0,
  # `timers.target.wants/` never created, and `is-enabled` afterwards answers `static` with rc=0. So the ONE
  # command whose whole job is "this timer will now fire" can succeed at doing nothing, and every line below
  # (the one-actor claim, the final note) would be printed over a pin that never runs — #3194's symptom, with
  # the installer's own green light on top of it. `verify_timer` closes the same hole at the INPUT (the
  # rendered unit must declare an installation config); this is the READ-BACK of the manager's answer at the
  # point where the claim is made, because a template is not the only way to reach it (a manager that ignores
  # the unit dir, a `--root` mismatch, a future `[Install]` spelling).
  # ⛔ POLARITY IS `own_state`'s, NOT `enable`'s: `disabled` is a CLAIM the manager made about THIS unit (it
  # answered with its own word), while an unanswerable manager is UNKNOWN and must not turn a healthy box into
  # a false RED — the same posture `retire_actuator` and the one-actor read-back already take.
  if [ "$rc" -eq 0 ]; then
    _own="$(own_state system)"
    case "$_own" in
      enabled) : ;;
      disabled) bad "'systemctl enable --now cell-self-pin.timer' exited 0, but the manager reads cell-self-pin.timer as NOT enabled — a unit with no installation config is exactly this shape (measured, systemd 255.4: 'The unit files have no installation config', rc=0, NO symlink, 'is-enabled' then answers 'static'), so this box would go on failing to advance its layer every ten minutes with every surface green. Check it with 'systemctl is-enabled cell-self-pin.timer' (it must answer 'enabled') and 'systemctl list-timers cell-self-pin.timer'"; rc=1 ;;
      *) note "  NOT VERIFIED: the system manager did NOT ANSWER the read-back of cell-self-pin.timer, so its enablement was NOT confirmed by this run — check it by hand: 'systemctl is-enabled cell-self-pin.timer'" ;;
    esac
  fi
  if [ "$rc" -ne 0 ]; then
    # ⛔ A MIGRATION THAT CANNOT COMPLETE PUTS ITSELF BACK. Zero actuators is WORSE than two: two race on
    # one target, none leaves the box unpinned with a green-looking nothing.
    for s in $retired; do
      restore_actuator "$s" && note "  ROLLED BACK: eldato-harness-apply.timer re-enabled in the ${s} manager, so this box keeps the ONE actuator it had before this attempt" \
        || bad "ROLLBACK FAILED in the ${s} manager: eldato-harness-apply.timer is DISABLED there, cell-self-pin.timer is NOT enabled, and this box now has NO pin actuator. Re-enable it by hand: 'systemctl enable --now eldato-harness-apply.timer'."
    done
    rm -rf "$tmp"
    bad "systemd did not enable cell-self-pin.timer — run: systemctl status cell-self-pin.service"
    return 1
  fi
  rm -rf "$tmp"
  # ⛔ AND THE CLAIM IS READ BACK, NOT ASSERTED. Printing "ONE actuator" while a scope still carries the
  # shipped timer is the same false PASS this function refuses to create. A DELIBERATE duplicate
  # (CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR) is the one case where the invariant is not the claim.
  if [ -n "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ]; then
    # ⛔ AND THE CLAIM IS THE MEASUREMENT, NOT THE FLAG. This line used to assert "TWO actuators" whenever the
    # hatch was set — but the hatch is now also the accepted route through an UNREADABLE scope, where the
    # true count is unknown: the scope may carry nothing (one actor, fine) or a duplicate (two). Print what
    # was READ and name what was not, so "deliberately accepted" never reads as "verified".
    still=""; unknown=""
    if scopes_now="$(actuator_scopes)"; then for s in $scopes_now; do still="$still ${s}"; done; fi
    for s in $(actuator_unknown_scopes); do unknown="$unknown ${s}"; done
    note "installed — invariant NOT fully verified, as CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR declares: shipped actuator STILL ENABLED in:${still:- none read}; manager(s) that did NOT ANSWER:${unknown:- none}. Read it with: systemctl list-timers cell-self-pin.timer ; systemctl --failed ; $0 --status"
    return 0
  fi
  if scopes="$(actuator_scopes)"; then
    who=""
    for s in $scopes; do who="$who ${s}"; done
    bad "eldato-harness-apply.timer still reads ENABLED in the ${who} manager(s) after the migration — two mutating actors on one pin. Fix it with 'systemctl disable --now eldato-harness-apply.timer' in that manager."
    return 1
  fi
  # ⛔ AND THE CLAIM NAMES WHAT WAS ACTUALLY READ. "read back in both managers" was printed even when one
  # manager never answered (see `scope_state`), which is a positive claim about a manager that said nothing.
  # ⚠️ THIS IS A WARNING, NOT A NON-ZERO EXIT, and the difference is deliberate: the units ARE installed
  # and enabled, so reporting failure would be a false RED on a box that is fine, and `--takeover` is where
  # an unreadable scope is genuinely dangerous (see below) — that is the path that refuses.
  unknown="$(actuator_unknown_scopes)"
  if [ -n "$unknown" ]; then
    who=""
    for s in $unknown; do who="$who ${s}"; done
    note "installed — but the${who} manager did NOT ANSWER, so the one-actor invariant was verified in ONE scope only. A shipped eldato-harness-apply.timer enabled in the${who} manager would be a SECOND mutating actor on this pin and this run could not see it. Check it by hand: 'systemctl --user is-enabled eldato-harness-apply.timer'."
    note "  Read it with: systemctl list-timers cell-self-pin.timer ; systemctl --failed ; $0 --status"
    return 0
  fi
  note "installed — ONE actuator on this pin (read back in both managers). Read it with: systemctl list-timers cell-self-pin.timer ; systemctl --failed ; $0 --status"
  return 0
}

case "${1:---pass}" in
  --pass|"")      do_pass ;;
  --dry-run)      do_pass dry ;;
  --status)       do_status fetch ;;
  --status-nofetch) do_status nofetch ;;
  --print-unit)   print_unit ;;
  # read-only: the SYSTEM unit directories `dropin_dirs` scans, so the enumeration is an assertion a test
  # can make instead of a list nothing reads (see SYSTEMD_UNIT_ROOTS).
  --print-dropin-roots) printf '%s\n' "${CELL_SELF_PIN_DROPIN_ROOTS:-$SYSTEMD_UNIT_ROOTS}" ;;
  --install)      shift; do_install "${1:-}" ;;
  --takeover)     err "--takeover is an argument to --install: '$0 --install --takeover'"; exit 64 ;;
  # ⛔ THE RANGE IS DERIVED, NOT TYPED. `sed -n '2,68p'` cut mid-sentence and printed `set -u` plus the
  # assignments once the header grew — a help screen that is a lie about the file. Print the leading
  # comment block only, whatever its length is today.
  --help|-h)      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}" ;;
  *)              err "unknown argument '$1' (try --help)"; exit 64 ;;
esac
