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
# and it REFUSES LOUDLY (exit 2, a named reason) when the record cannot answer.
#
# ── WHAT `--install` RESOLVES, AND WHERE EACH VALUE COMES FROM ─────────────────────────────────
#   base       ${CELL_HOME:-$HOME}                — the expression this file, the unit's rendered
#                                                   `Environment=CELL_HOME=` and every sibling installer
#                                                   agree on. ⛔ Note the SUPERVISOR's own fallback is
#                                                   `/tmp/cell-home` (cloud-cell-supervisor.sh:134), NOT
#                                                   `$HOME`; that is why the unit renders CELL_HOME
#                                                   EXPLICITLY rather than trusting the manager's HOME.
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

# ⛔ REMEMBERED BEFORE IT IS DEFAULTED, because the DEFAULT IS THE DEFECT. `cloud-cell-supervisor.sh`'s own
# fallback is `/tmp/cell-home` (measured: cloud-cell-supervisor.sh:134), NOT `$HOME` — so an install run
# with CELL_HOME unset would render `Environment=CELL_HOME=$HOME` into a unit whose reader is looking
# somewhere else, i.e. the pin pass reads `$HOME/.harness-path` while the controller reads
# `$CELL_HOME/.harness-path`: the #2215 skew this whole change exists to remove, installed permanently
# into /etc/systemd/system. Rendering refuses when this is empty (see `print_unit`); a bare PASS keeps
# the tolerant default, because a manual run must not be refused over an environment variable.
CELL_HOME_GIVEN="${CELL_HOME:-}"
CELL_HOME="${CELL_HOME:-$HOME}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
HARNESS_REF="${HARNESS_REF:-origin/main}"
# ⛔ THE FETCH TARGET IS THE REF THE COMPARISON USES. `HARNESS_REF` is a documented knob (see the header),
# and both verbs fetched `origin main` while DECIDING on `$HARNESS_REF` — so for any other value the pass
# refreshed one ref and compared another, and `--status` printed "`origin/rel` fetched just now" about a ref
# it never touched. A knob read one way and refreshed another is two facts pretending to be one, which is
# the #2215 skew this file exists to remove — one variable over.
ref_fetch_branch() { # the REMOTE branch to fetch for $HARNESS_REF (see the three forms below)
  local r
  # ⛔ THREE SPELLINGS NAME THE SAME REMOTE BRANCH, AND ONE OF THEM IS NOT A REMOTE REF AT ALL. Only
  # `origin/<b>` and `refs/heads/<b>` were stripped, so `refs/remotes/origin/<b>` — the canonical name of
  # the DEFAULT knob value, and the spelling the sibling reader accepts
  # (`git rev-parse refs/remotes/origin/main^{commit}`, rc=0) — was handed to `git fetch` verbatim as a
  # REMOTE source: `fatal: couldn't find remote ref refs/remotes/origin/main`, rc=128 (MEASURED). The tick
  # then exited 2 `fetch-failed` for EVER on a value that worked before this file decided on the fetched
  # commit, and the `2>/dev/null` on that fetch discarded git's reason, so the journal could not even say
  # why. `refs/remotes/origin/<b>` is this repo's tracking ref; the thing to ask the REMOTE for is `<b>`.
  case "$HARNESS_REF" in
    refs/remotes/*/*) r="${HARNESS_REF#refs/remotes/}"; r="${r#*/}" ;;
    *) r="${HARNESS_REF#origin/}"; r="${r#refs/heads/}" ;;
  esac
  printf '%s\n' "${r:-main}"
}
# ⛔ THE DECISION READS A REF THIS RUN OWNS, NOT `FETCH_HEAD`. `FETCH_HEAD` is an ordinary mutable file in
# the worktree, bound to no run: any other git process in the SAME tree that fetches between our fetch and
# our read is read as OUR result. That is not hypothetical here — `cloud-cell-supervisor.sh:1698`/`:2116`
# run `git fetch origin main` in this very repository, and bring-up re-arms `eldato-harness-apply.timer`
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
# (cloud-cell-supervisor.sh:2137 sets `HARNESS_APPLIED=unchanged` for a pin already at the tip; :2160 is
# the only write). So `apply --force --pin-only` on a box whose record was lost exits 0, writes NOTHING
# and reports `unchanged` — leaving this pass reading an empty record on every tick, for ever. That is
# #3133 (merged) one layer up: an unhealable RED is as useless as a false GREEN, and the recorded answer
# is the one `harness-apply-pass.sh` already uses — MEND the record to what the box actually runs, and
# report it with the code that vocabulary already owns (11, `mended`).
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
#     (HARDCODED, `:2115`) and then pins `$(git rev-parse "$HARNESS_REF^{commit}")` (`:2118`) — a LOCAL read;
#   · a fetch of `main` moves `refs/remotes/origin/main` and NEVER `refs/heads/main`, so `HARNESS_REF=main`
#     (or `refs/heads/main`) pins this repo's local branch, the record does not move, and `:387`'s containment
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
  loud 2 ref-spelling "HARNESS_REF=${HARNESS_REF} resolves LOCALLY to ${local_target} in ${repo}, but this run fetched ${target} — 'apply' pins the LOCAL ref (cloud-cell-supervisor.sh:2118), so the record could never advance and every tick would re-apply for ever. Use the remote spelling: HARNESS_REF=origin/<branch>"
}

do_pass() {
  local dry="${1:-}" layer repo sup target applied now rc fetch_branch fetch_ref
  # ⛔ THE ONE-ACTOR INVARIANT IS RE-CHECKED HERE, ON EVERY TICK, BEFORE ANYTHING ELSE — see
  # `one_actor_check` for why install time cannot be the only reading.
  one_actor_check "$([ "$dry" = dry ] && printf dry || printf apply)"
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
  fetch_branch="$(ref_fetch_branch)"
  fetch_ref="$(pin_fetch_ref "$fetch_branch")"
  # ⛔ ONE FETCH, TWO REFSPECS: the bare one keeps `refs/remotes/origin/<branch>` fresh exactly as before
  # (the `--status-nofetch` reading and every other reader of the tracking ref depend on it), and the second
  # lands this very fetch in the run-private ref — see `PIN_FETCH_REF_BASE` for why `FETCH_HEAD` is not ours
  # and why the destination is keyed by source.
  git fetch -q origin "$fetch_branch" "+${fetch_branch}:${fetch_ref}" 2>/dev/null \
    || loud 2 fetch-failed "git fetch origin ${fetch_branch} failed in ${repo} — an unreadable ref is never treated as current"
  # ⛔ DECIDE ON THE COMMIT THE FETCH BROUGHT — NOT ON THE KNOB'S SPELLING. `git rev-parse "$HARNESS_REF"`
  # resolves whatever that spelling names LOCALLY, and a fetch of `main` only moves
  # `refs/remotes/origin/main`: so `HARNESS_REF=refs/heads/main` (or a bare `main`) read the STALE local
  # branch the fetch never touched, and printed `current` + exit 0 against a newer remote tip — #3194's own
  # symptom through the knob this file documents. The specifier fetched above is the commit the fetch just
  # brought, whatever the spelling, and `^{commit}` peels an annotated tag (comparing a tag OBJECT sha to a
  # commit is a false DRIFT that can never be `current`). MEASURED, both directions, before this line existed.
  target="$(git rev-parse --verify --quiet "${fetch_ref}^{commit}" 2>/dev/null)" \
    || loud 2 unreadable-ref "${HARNESS_REF} did not resolve to a commit after the fetch in ${repo}"
  applied="$(pinned_head)"
  if [ -z "$applied" ]; then
    log "no readable pin record at ${HARNESS_PIN_FILE} -- applying (a pin nobody can read is not a pin)"
  elif [ "$target" = "$applied" ]; then
    # ⛔ THE GREEN LINE NAMES WHAT IT DID NOT CHECK. The template states that a pin which is current while
    # the RUNNING controller sits on a stale layer is a real state and that "the pass says so in its log line
    # rather than greening it away" — but only the APPLIED branch said so, and this is the branch that runs on
    # every converged tick. #3194's whole punishment was "the record said current while the pid executed a
    # tree 17 commits behind", so the no-op line is exactly where that belief is re-asserted: it must carry
    # the same caveat, or the one surface an operator reads all day is the one that overclaims.
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
    # `harness_apply` writes $HARNESS_PIN_FILE only inside its CHANGED branch (`:1926`/`:1949`), so a
    # pin that is ALREADY at the tip takes `HARNESS_APPLIED=unchanged` and the record is never written.
    # A cell whose record was lost therefore reads an empty record every tick and REDs for ever on a
    # box that is in fact correct — the #3133 defect (merged), reproduced one layer up. The recorded
    # answer for exactly this state already exists in `harness-apply-pass.sh`: MEND the record to what
    # the box actually runs, and say so with its own exit code, 11 (`mended`).
    if mend_record "$target"; then
      now="$(pinned_head)"
      log "mended: the pin RECORD was missing/empty and now names ${now} (the tree apply created for ${target})"
      record_outcome "mended ${now} (record was missing; now names the tree apply created)"
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
  record_outcome "applied -> ${now}"
  log "applied -> ${now} (record verified; ctrl=$(systemctl is-active eldato-orchestrator 2>/dev/null); note: a RUNNING controller keeps the layer it started on until it is restarted)"
  return 0
}

do_status() { # [fetch|nofetch] — read-only; exit 0 = current, 1 = DRIFT, 2 = UNRESOLVED (repo vocabulary)
  local layer sup target mode="${1:-fetch}" last="<none recorded>" dup fetch_failed=0 fetch_branch fetch_ref
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
    if dup="$(actuator_scopes)"; then
      printf '  second actuator %s manager(s) — eldato-harness-apply.timer is ENABLED beside this unit (a tick retires it again; an operator can end it with --install --takeover)\n' "$(printf '%s' "$dup" | tr '\n' ' ')"
    else
      printf '  second actuator <none>\n'
    fi
    # ⛔ A STATUS THAT DOES NOT FETCH IS BLIND IN THE EXACT STATE THIS FILE EXISTS TO CATCH. #3194 was
    # a pin RECORD that disagreed with the layer the cell executed for ~a day: "current" against a
    # stale local `origin/main` is that same lie with a green verdict, so the ref is FETCHED here and
    # the reading SAYS which of the two it is. `--dry-run` stays the verb that touches nothing; a failed
    # fetch is reported as possibly stale, never as current-but-unverified silence.
    case "$mode" in
      nofetch) printf '  (%s NOT fetched — the reading below may be STALE)\n' "$HARNESS_REF" ;;
      *) fetch_branch="$(ref_fetch_branch)"
         fetch_ref="$(pin_fetch_ref "$fetch_branch")"
         if git -C "$layer" fetch -q origin "$fetch_branch" "+${fetch_branch}:${fetch_ref}" 2>/dev/null; then
           printf '  (%s fetched just now)\n' "$HARNESS_REF"
         else
           printf '  (git fetch FAILED in %s — the reading below is against an UNREFRESHED local ref; this is not a green)\n' "$layer"
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
    if [ -n "${target:-}" ] && [ "${target:-}" = "$(pinned_head)" ]; then printf '  verdict        current\n'; printf '                 (the RECORD is current — a RUNNING controller keeps the layer it STARTED on until it is restarted, so this is not a claim about the executed tree)\n'; return 0; fi
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
  # ⛔ A RENDER OF A BASE NOBODY GAVE IS A LIE THE UNIT CANNOT TAKE BACK. `CELL_HOME` unset defaults to
  # $HOME here, but the READER of the record this file derives from defaults to /tmp/cell-home — so the
  # rendered `Environment=CELL_HOME=` would permanently disagree with the controller, and the only guard on
  # it (`verify_unit`'s CELL_HOME assertion) compares the artifact against that SAME already-wrong value.
  # Refusing is the only fail-closed answer at the one moment the value becomes permanent.
  if [ -z "$CELL_HOME_GIVEN" ]; then
    bad "CELL_HOME is not set in this environment — this file would default it to \$HOME (${HOME}), while cloud-cell-supervisor.sh's own default is /tmp/cell-home, so the rendered unit would pin a DIFFERENT record than the controller reads (the #2215 skew). Set CELL_HOME to the cell home and re-run."
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
  local n_home home_val _env _kv
  # ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE. The template documents the defect it replaced, and that prose
  # legitimately contains `/tmp/cell-ai`; a guard that also refused the documentation would force the
  # next reader to delete the only explanation of why the line is banned. Strip comments first.
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  refuse_raw_text_tricks "the rendered unit" "$body" || return 1
  refuse_env_reset "the rendered unit" "$body" || return 1
  refuse_env_mutators "the rendered unit" "$body" || return 1
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
  exec_dir="$(cd "$(dirname "$exec_path")" 2>/dev/null && pwd -P)" || exec_dir=""
  if [ -n "$exec_dir" ]; then
    exec_real="${exec_dir%/}/$(basename "$exec_path")"
  else
    case "$exec_path" in
      */../*|*/..|../*|..)
        bad "the rendered unit's ExecStart payload '${exec_path}' traverses '..' through a directory that does not resolve — the containment rule this file holds cannot be evaluated on it, so it is refused rather than guessed"; return 1 ;;
    esac
    exec_real="$exec_path"
  fi
  home_real="$(cd "$CELL_HOME" 2>/dev/null && pwd -P)" || home_real="$CELL_HOME"
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
  envs="$(directive "$body" Environment)"
  n_home=0
  home_val=""
  while IFS= read -r _env; do
    for _kv in $_env; do
      _kv="${_kv%\"}"; _kv="${_kv#\"}"
      case $_kv in
        CELL_HOME=*) n_home=$((n_home + 1)); home_val="${_kv#CELL_HOME=}" ;;
      esac
    done
  done <<<"$envs"
  if [ "$n_home" -ne 1 ]; then
    bad "the rendered unit declares ${n_home} 'Environment=CELL_HOME=' assignment(s) — exactly one is installable (systemd is LAST-WINS, so a second one silently re-bases the pass onto a DIFFERENT pin record than the controller)"; return 1
  fi
  if [ "$home_val" != "$CELL_HOME" ]; then
    bad "the rendered unit's Environment=CELL_HOME='${home_val}' is not the cell home '${CELL_HOME}' — the pass would derive its base from a value the controller never read, so it pins a different record"; return 1
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
      RootDirectory|RootImage)
        # ⛔ THE HEADER NAMES THIS DIRECTIVE AND NOTHING CHECKED IT. `RootDirectory=`/`RootImage=` make
        # systemd chroot()/pivot_root() the payload into that path (`systemd.exec(5)`) BEFORE any line of it
        # runs — so a path that is not a live-cell invariant is the same "unit that never began" class as
        # `WorkingDirectory=`, just one syscall over (and `EnvironmentFile=` was the sibling this file
        # already refused). MEASURED rc=0 before this arm. The pass resolves its own layer instead.
        bad "the rendered unit declares ${_c}= — systemd enters that root BEFORE the payload runs, so a path that is not a live-cell invariant turns the pin into a unit that never began (the 200/CHDIR class); the pass resolves its own layer instead"; return 1 ;;
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
  ok_vals="$(printf '%s\n' "$body" | awk '
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
# THE RULE. A drop-in MAY adjust IDENTITY (`User=`, `Environment=HOME=`): that is how an operator corrects
# the render without a second copy of the unit. It MAY NOT re-open a class `verify_unit` closed — an
# executable directive, a working directory, a condition (a green skip), a wider success vocabulary, or any
# directive that changes the pass's ENVIRONMENT behind the `Environment=` rules — because every one of those
# is a directive this file does not verify and systemd applies anyway.
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
# ⛔ THE ROOT LIST MUST BE systemd's OWN LOAD PATH, AND IT WAS THREE PATHS SOMEBODY THOUGHT OF. On systemd
# 255 `systemd-analyze unit-paths` lists `/etc/systemd/system`, `/run/systemd/system`,
# `/usr/local/lib/systemd/system` and `/usr/lib/systemd/system` as SYSTEM unit directories, and
# `systemd.unit(5)` Table 1 puts `/usr/local/lib/systemd/system` — "System units installed by the
# administrator" — ABOVE `/usr/lib/systemd/system`. The list below omitted it, so a legacy
# `cell-self-pin.service.d/*.conf` carrying the very `WorkingDirectory=/tmp/cell-ai` this change exists to
# remove was merged OVER the rendered unit by systemd and read by NOTHING, while `--install` printed
# "installed — ONE actuator on this pin" and exited 0: the exact false PASS this section exists to close,
# in the directory an administrator building a cell by hand is most likely to use. `/lib/systemd/system` is
# the same directory on a non-usrmerge host, and `/etc/systemd/system` is scanned even when the caller
# redirects the unit dir (`SYSTEMD_UNIT_DIR`, which the suite uses), because systemd loads it regardless.
# `CELL_SELF_PIN_DROPIN_ROOTS` is the SEAM the suite plants a drop-in under: the real roots are root-owned,
# so a leg that cannot write them proves nothing about the enumeration — and MEASURED, deleting `/run` and
# `/usr/lib` from this list left the suite at 240 ok / 0 failed, i.e. nothing pinned it at all.
SYSTEMD_UNIT_ROOTS="/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system"
dropin_dirs() { # <unit-dir> <unit-name> — every directory systemd merges for this unit
  local unit_dir="$1" name="$2" root base svc short seen=" " d
  svc="${name##*.}"
  base="${name%.*}"
  for root in "$unit_dir" ${CELL_SELF_PIN_DROPIN_ROOTS:-$SYSTEMD_UNIT_ROOTS}; do
    [ -d "$root" ] || continue
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
  done
}

verify_dropins() { # <unit-dir> <unit-name>
  local _dir f
  for _dir in $(dropin_dirs "$1" "$2"); do
    for f in "$_dir"/*.conf; do
      [ -f "$f" ] || continue
      verify_dropin_file "$f" || return 1
    done
  done
  return 0
}

verify_dropin_file() { # <drop-in .conf> — one file's rules; split out so the search-path loop stays a loop
  local f="$1" body _c _kv
    body="$(grep -vE '^[[:space:]]*#' "$f")"
    # The same three parse-level rules the rendered unit gets, in the same one place: a drop-in is NOT a
    # safer place for a continuation, a C-style escape, an `Environment=` reset, or an
    # `EnvironmentFile=`/`UnsetEnvironment=`/`PassEnvironment=` — it is a MORE dangerous one, because it is
    # merged OVER the unit and an operator reading the unit will never see it.
    refuse_raw_text_tricks "the installed drop-in ${f}" "$body" || return 1
    refuse_env_reset "the installed drop-in ${f}" "$body" || return 1
    refuse_env_mutators "the installed drop-in ${f}" "$body" || return 1
    if [[ $body =~ (^|[[:space:]=])/(private/)?(var/)?tmp/cell-ai(/|[[:space:]]|$) ]]; then
      bad "the installed drop-in ${f} names the provisioning clone (/tmp/cell-ai) — a drop-in OVERRIDES the rendered unit, so rewriting only the unit cannot remove that path; remove ${f} and re-run (a pin unit needs no drop-in)"; return 1
    fi
    for _c in $(directive_names "$body"); do
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
        Exec*)
          bad "the installed drop-in ${f} declares ${_c}= — an executable directive this verification does not read, which systemd RUNS anyway; the pass needs exactly ONE executable directive, ExecStart="; return 1 ;;
        SuccessExitStatus)
          bad "the installed drop-in ${f} declares SuccessExitStatus= — it would widen the unit's green vocabulary past 0/11, which is a false PASS; remove ${f}"; return 1 ;;
        Unit|On*)
          # ⛔ A TIMER DROP-IN CAN RE-TARGET OR RE-SCHEDULE THE PIN. `Unit=` names the unit the timer
          # activates and the `On*=` family sets when it fires, so a drop-in carrying either makes the timer
          # activate something else, or stop firing on the ten-minute clock — a pin that silently never
          # runs, which is #3194's own symptom reached from the timer's side. Both are closed by prefix
          # (`On*`) rather than one name at a time, the same rule this file uses for `Condition*`.
          bad "the installed drop-in ${f} declares ${_c}= — it re-targets or re-schedules the timer/unit pair this verification installed (a pin that silently never runs is #3194's symptom), or is a unit-level directive this check cannot honour; remove ${f}"; return 1 ;;
        Environment)
          # ⛔ A DROP-IN MAY ADJUST IDENTITY, AND THAT ALLOWANCE IS EXACTLY ONE VARIABLE WIDE. The
          # comment above this function names the remedy as `User=` and `Environment=HOME=` — so allow
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
                bad "the installed drop-in ${f} sets 'Environment=${_kv%%=*}=' — a drop-in OVERRIDES the rendered unit, so an environment value other than HOME= can re-point the pass at a different pin record than the controller; a drop-in may adjust IDENTITY (User=, Environment=HOME=), never the base or the record it reads; remove ${f}"; return 1 ;;
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
  [ "$rc" -eq 0 ] && printf 'enabled\n' || printf 'disabled\n'
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
# retire_actuator <scope> — RETIRE the shipped timer, explicitly. This is the one-actor decision, taken.
# ⛔ VERIFIED, NOT ASSUMED: a `disable` that did not take leaves exactly the state this whole guard exists
# to prevent, so the refusal is on the READ-BACK, not on the exit code.
retire_actuator() {
  local scope="$1"
  case "$scope" in
    user)   systemctl --user disable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    system) systemctl disable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac || { bad "could not disable eldato-harness-apply.timer in the ${scope} manager — REFUSING to install a second actuator beside one I cannot retire (that is the race, not redundancy)"; return 1; }
  if actuator_enabled_in "$scope"; then
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
    system) systemctl enable --now eldato-harness-apply.timer >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac || return 1
  actuator_enabled_in "$scope"
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
  done
  log "re-took the pin: eldato-harness-apply.timer was RE-ARMED (${who# }) after --takeover and has been retired again -- ONE actuator on this pin, re-verified rather than assumed"
  record_outcome "re-took the pin (retired a re-armed eldato-harness-apply.timer in ${who# })"
  return 0
}

do_install() { # [--takeover]
  local takeover="${1:-}" unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}" tmp rc=0 u script scopes="" retired="" who="" s unknown=""
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
  if [ -n "$scopes" ] && [ "$takeover" = --takeover ]; then
    # ⛔ A BLIND RETIREMENT IS REFUSED. `--takeover` DISABLES the shipped actuator, so if a scope cannot be
    # read the run cannot know what it is leaving behind there — and the failure modes are both bad: leave a
    # duplicate (two actors) or disable the only one (zero actors, #3194's own state). Verified by the READ
    # in every scope, never by the exit code of a disable we could not confirm.
    unknown="$(actuator_unknown_scopes)"
    if [ -n "$unknown" ]; then
      who=""
      for s in $unknown; do who="$who ${s}"; done
      bad "--takeover cannot retire safely: the${who} manager did not answer, so this run cannot see whether a shipped eldato-harness-apply.timer is ENABLED there — retiring blind could leave TWO actors (a race) or ZERO (no pin at all). Nothing was written and nothing was retired. Re-run where that manager is reachable, or run 'systemctl --user is-enabled eldato-harness-apply.timer' yourself first."
      rm -rf "$tmp"; return 1
    fi
  fi
  if [ -n "$scopes" ] && [ "$takeover" = --takeover ]; then
    note "installing into $unit_dir (retiring the duplicate actuator in the ${who} manager(s) LAST, after the units are placed)"
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
    note "installed (TWO actuators on this pin, as CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR declares). Read it with: systemctl list-timers cell-self-pin.timer ; systemctl --failed ; $0 --status"
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
  --print-dropin-roots) printf '%s\n' ${CELL_SELF_PIN_DROPIN_ROOTS:-$SYSTEMD_UNIT_ROOTS} ;;
  --install)      shift; do_install "${1:-}" ;;
  --takeover)     err "--takeover is an argument to --install: '$0 --install --takeover'"; exit 64 ;;
  # ⛔ THE RANGE IS DERIVED, NOT TYPED. `sed -n '2,68p'` cut mid-sentence and printed `set -u` plus the
  # assignments once the header grew — a help screen that is a lie about the file. Print the leading
  # comment block only, whatever its length is today.
  --help|-h)      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}" ;;
  *)              err "unknown argument '$1' (try --help)"; exit 64 ;;
esac
