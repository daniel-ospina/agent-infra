#!/usr/bin/env bash
# cell-self-pin.sh — keep the layer this cell EXECUTES on origin/main, on a clock (agent-infra #3194).
#
#   ./cell-self-pin.sh                 # one pass: resolve the layer, no-op if current, else apply --force
#   ./cell-self-pin.sh --status        # what it resolved, where it came from, the LAST OUTCOME (it FETCHES)
#   ./cell-self-pin.sh --status-nofetch # the same reading against the LOCAL ref, saying it may be stale
#   ./cell-self-pin.sh --dry-run       # resolve + decide + print: change NOTHING, fetch NOTHING
#   ./cell-self-pin.sh --install [--takeover]   # render + verify + PLACE the pass + install the units
#   ./cell-self-pin.sh --print-unit    # render the units to stdout ONLY — writes no file, places no pass
#   ./cell-self-pin.sh --help
#
# Exit (pass):   0 = current or applied; 11 = the pin RECORD was missing and was MENDED to the tree
#                `apply` created; 1 = apply failed, or the record did not converge; 2 = the layer
#                could NOT be resolved (loud, named).
# Exit (status): 0 = current, 1 = DRIFT, 2 = the layer could NOT be resolved — the repo's own
#                `0 match / 1 drift / 2 unknown` vocabulary (scripts/check-deployed-drift.sh), reused
#                rather than invented a third time (#1178).
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
#   ExecStart  ${CELL_HOME}/.pi/agent/scripts/cell-self-pin.sh when it exists (where the controller's own
#              unit names its supervisor), else THIS file's resolved absolute path. Both exist for the
#              life of the cell; neither is created by the provisioning recipe.
#   WorkingDirectory                          — **none**. See below.
#
# ⛔ `WorkingDirectory=` IS DELIBERATELY ABSENT FROM THE RENDERED UNIT, and that is the whole fix.
# `WorkingDirectory=` is the ONE directive that makes systemd refuse to start a unit BEFORE any line of
# the payload runs (`EXIT_CHDIR` = 200, systemd.exec(5)) — the worst possible place to name a directory
# that is not a live-cell invariant. With no `WorkingDirectory=`, systemd starts the oneshot in `/` and
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
#   · `--install --takeover` is the ONE-ACTOR MIGRATION: disable+stop that timer, VERIFY the disable,
#     and only then install this unit. `--takeover` is an operator's explicit decision to retire the
#     shipped actuator on this box; a retirement that does not take is a REFUSAL, never two actors.
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

CELL_HOME="${CELL_HOME:-$HOME}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
HARNESS_REF="${HARNESS_REF:-origin/main}"
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
    if [ -n "$best" ]; then printf '%s\n' "$(git -C "$best" rev-parse --show-toplevel 2>/dev/null)"; return 0; fi
  fi
  if layer_ok "$HARNESS"; then printf '%s\n' "$(git -C "$HARNESS" rev-parse --show-toplevel 2>/dev/null)"; return 0; fi
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
# (cloud-cell-supervisor.sh:1926 sets `HARNESS_APPLIED=unchanged` for a pin already at the tip; :1949 is
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

do_pass() {
  local dry="${1:-}" layer repo sup target applied now rc
  layer="$(resolve_layer)" || loud 2 no-layer "no usable layer: ${HARNESS_PIN_FILE} names nothing readable and ${HARNESS_PIN_DIR} holds no tree git can answer from"
  sup="$(supervisor_in "$layer")" || loud 2 no-supervisor "resolved layer ${layer} carries no cloud-cell-supervisor.sh, so there is no verb to pin with"
  repo="$layer"
  target=""
  if [ "$dry" = dry ]; then
    # ⛔ A DRY RUN TOUCHES NOTHING — not even refs. It reports the recorded layer and the ref as it
    # currently resolves locally, and SAYS the reading is possibly stale rather than fetching to freshen
    # it (a "read-only" verb that writes FETCH_HEAD is the kind of lie this file exists to remove).
    target="$(git -C "$repo" rev-parse "$HARNESS_REF" 2>/dev/null)"
    log "dry-run (no fetch) layer=${layer} repo=${repo} supervisor=${sup} pinned=$(pinned_head || echo '<unreadable>') target=${target:-<unreadable, possibly stale>}"
    return 0
  fi
  # ⛔ `cd` — not `git -C` — because the verb below is the one that decides the cwd for the pin, and the
  # unit deliberately declares no `WorkingDirectory=`. This is where that directory is chosen.
  cd "$repo" || loud 2 chdir "cannot enter the resolved layer ${repo}"
  git fetch -q origin main 2>/dev/null || loud 2 fetch-failed "git fetch origin main failed in ${repo} — an unreadable ref is never treated as current"
  target="$(git rev-parse "$HARNESS_REF" 2>/dev/null)" || loud 2 unreadable-ref "${HARNESS_REF} does not resolve in ${repo}"
  applied="$(pinned_head)"
  if [ -z "$applied" ]; then
    log "no readable pin record at ${HARNESS_PIN_FILE} -- applying (a pin nobody can read is not a pin)"
  elif [ "$target" = "$applied" ]; then
    record_outcome "current ${target} (no-op)"
    log "current ${target} (no-op)"; return 0
  else
    log "DRIFT pinned=${applied} target=${target} -- applying --force --pin-only"
  fi
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
  if [ "$now" = "$applied" ] && [ "$now" != "$target" ]; then
    record_outcome "stale-record (${now} unmoved; ${HARNESS_REF} is ${target})"
    err "STALE-RECORD: apply exited 0 but ${HARNESS_PIN_FILE} still names '${now}' while ${HARNESS_REF} is '${target}' -- an exit code is not a convergence"
    exit 1
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$target" "$now" 2>/dev/null; then
    record_outcome "stale-record (${now} does not contain ${target})"
    err "STALE-RECORD: the record names '${now}', which does not contain the ref tip '${target}' -- a pin that is not on the ref's line is not a pin"
    exit 1
  fi
  record_outcome "applied -> ${now}"
  log "applied -> ${now} (record verified; ctrl=$(systemctl is-active eldato-orchestrator 2>/dev/null); note: a RUNNING controller keeps the layer it started on until it is restarted)"
  return 0
}

do_status() { # [fetch|nofetch] — read-only; exit 0 = current, 1 = DRIFT, 2 = UNRESOLVED (repo vocabulary)
  local layer sup target mode="${1:-fetch}" last="<none recorded>"
  [ -f "$O/self-pin.last" ] && last="$(tail -1 "$O/self-pin.last" 2>/dev/null)"
  printf 'cell-self-pin\n  CELL_HOME      %s\n  pin record     %s -> %s\n  pin root       %s\n  pinned HEAD    %s\n  stamp (legacy) %s -> %s\n  last outcome   %s\n' \
    "$CELL_HOME" "$HARNESS_PIN_FILE" "$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null || echo '<absent>')" \
    "$HARNESS_PIN_DIR" "$(pinned_head || echo '<unreadable>')" "$STAMP" "$(read_stamp || true)" "${last:-<empty record>}"
  if layer="$(resolve_layer)"; then
    printf '  resolved layer %s\n' "$layer"
    sup="$(supervisor_in "$layer" && true)"; printf '  supervisor     %s\n' "${sup:-<none>}"
    # ⛔ A STATUS THAT DOES NOT FETCH IS BLIND IN THE EXACT STATE THIS FILE EXISTS TO CATCH. #3194 was
    # a pin RECORD that disagreed with the layer the cell executed for ~a day: "current" against a
    # stale local `origin/main` is that same lie with a green verdict, so the ref is FETCHED here and
    # the reading SAYS which of the two it is. `--dry-run` stays the verb that touches nothing; a failed
    # fetch is reported as possibly stale, never as current-but-unverified silence.
    case "$mode" in
      nofetch) printf '  (%s NOT fetched — the reading below may be STALE)\n' "$HARNESS_REF" ;;
      *) if git -C "$layer" fetch -q origin main 2>/dev/null; then
           printf '  (%s fetched just now)\n' "$HARNESS_REF"
         else
           printf '  (git fetch FAILED in %s — the reading below may be STALE; this is not a green)\n' "$layer"
         fi ;;
    esac
    target="$(git -C "$layer" rev-parse "$HARNESS_REF" 2>/dev/null)"; printf '  %s %s\n' "$HARNESS_REF" "${target:-<unreadable>}"
    # ⛔ 1 FOR DRIFT, NOT 0. `scripts/check-deployed-drift.sh` already speaks `0 match / 1 drift /
    # 2 unknown`; a status verb that reports DRIFT and exits 0 cannot be gated on by anything, which is
    # how a third drift dialect (#1178) is born. Nothing here re-decides the vocabulary.
    if [ -n "${target:-}" ] && [ "${target:-}" = "$(pinned_head)" ]; then printf '  verdict        current\n'; return 0; fi
    printf '  verdict        DRIFT (a RUNNING controller keeps the layer it started on until restarted)\n'; return 1
  else
    printf '  resolved layer <UNRESOLVED — this is a RED, see --status output above>\n'; return 2
  fi
}

# ── --install ────────────────────────────────────────────────────────────────────────────────────
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
say() { printf '%s\n' "$*"; }
bad() { printf 'REFUSING: %s\n' "$*" >&2; }

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
  user="$(id -un)"; home="$HOME"
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
declares() {
  local hit
  hit="$(printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*.*/x/p")"
  [ -n "$hit" ]
}

verify_unit() { # <rendered service> — the properties the ISSUE names, asserted on the ARTIFACT
  local f="$1" body exec_path n_exec execs envs ok_vals v w seen0=0
  # ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE. The template documents the defect it replaced, and that prose
  # legitimately contains `/tmp/cell-ai`; a guard that also refused the documentation would force the
  # next reader to delete the only explanation of why the line is banned. Strip comments first.
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  # ⛔ THE DEFECT ITSELF, AS AN INVARIANT: a rendered pin unit must carry NO bootstrap-only path, AS A
  # TOKEN — not merely after `=` or at line start. `ExecStart=/bin/bash /tmp/cell-ai/scripts/…` puts a
  # SPACE before the path, and that is the reachable form: the placed copy's fallback is whatever
  # checkout the installer ran from, which on a provisioning box is exactly the bootstrap clone.
  if [[ $body =~ (^|[[:space:]=])/(var/)?tmp/cell-ai(/|[[:space:]]|$) ]]; then
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
  exec_path="$execs"
  case "$exec_path" in
    "/bin/bash "*) exec_path="${exec_path#/bin/bash }" ;;
    *) bad "the rendered unit's ExecStart is not '/bin/bash <absolute script>' (it is '${exec_path}') — a oneshot has no shell to resolve one"; return 1 ;;
  esac
  # ⛔ AND IT MUST LIVE UNDER $CELL_HOME. Any other absolute path can be pruned out from under the unit
  # (a lane worktree, a bootstrap clone); $CELL_HOME is the one root a running cell keeps.
  case "$exec_path" in
    "$CELL_HOME"/*) ;;
    *) bad "ExecStart names '${exec_path}', which is NOT under CELL_HOME ('${CELL_HOME}') — a path outside the one home can be pruned out from under the unit, which is the failure this change exists to remove (203/EXEC every tick)"; return 1 ;;
  esac
  # ⛔ AND THE UNIT MUST CARRY THE SAME BASE THE EXECSTART USES. The service manager's HOME is not the cell
  # home, so a unit that carried only `HOME=` left the pass defaulting CELL_HOME from an unrelated value
  # while its ExecStart sat under the real one — measured: the pass then read `$HOME/.harness-path` while
  # the controller read `$CELL_HOME/.harness-path`, i.e. it pinned a tree the controller never runs.
  envs="$(directive "$body" Environment)"
  case $'\n'"$envs"$'\n' in
    *$'\n'"CELL_HOME=${CELL_HOME}"$'\n'*) ;;
    *) bad "the rendered unit does not carry 'Environment=CELL_HOME=${CELL_HOME}' — without it the pass derives its base from the service manager's HOME and can read a DIFFERENT pin record than the controller"; return 1 ;;
  esac
  # ⛔ AND IT MUST NOT DECLARE A WORKING DIRECTORY AT ALL. Any absolute path here is a bootstrap-time
  # value outliving its directory; the pass `cd`s itself after resolving the layer. `declares` (not a
  # value read) so `WorkingDirectory=` with an empty or continued value cannot slip past.
  if declares "$body" WorkingDirectory; then
    bad "the rendered unit declares WorkingDirectory= — one directive that refuses to start the unit when the directory is gone (EXIT_CHDIR 200); drop it and let the pass resolve its own cwd"; return 1
  fi
  # A skipped CONDITION is a green no-op — see the header. Refuse it on the artifact.
  if declares "$body" ConditionPathExists; then
    bad "the rendered unit declares ConditionPathExists= — a failed condition SKIPS the unit and leaves it green; the missing-layer case must be a RED payload exit, not a skip"; return 1
  fi
  # ⛔ ONLY THE PASS'S OWN SUCCESS CODES ARE GREEN. 0 = current/applied and 11 = mended are the whole
  # success vocabulary (`harness-apply-pass.sh`'s recorded codes, adopted rather than re-invented); any
  # other value would green a failure, which is the false PASS #3194 is about.
  ok_vals="$(directive "$body" SuccessExitStatus)"
  [ -n "$ok_vals" ] || { bad "the rendered unit must declare SuccessExitStatus=… — a non-zero exit is how this pass goes RED"; return 1; }
  while IFS= read -r v; do
    for w in $v; do
      case "$w" in
        0)  seen0=1 ;;
        11) ;;
        *)  bad "SuccessExitStatus lists '${w}', which is neither 0 (current/applied) nor 11 (mended) — a wider list greens a failure"; return 1 ;;
      esac
    done
  done <<<"$ok_vals"
  [ "$seen0" -eq 1 ] || { bad "SuccessExitStatus must include 0 — 'current' and 'applied' are only green as 0"; return 1; }
  return 0
}

# ── one actuator per pin, in BOTH systemd managers ──────────────────────────────────────────────────
# ⛔ BARE `systemctl` IS THE SYSTEM MANAGER ONLY, and the sibling installer this file names as the one
# to keep NEGOTIATES THE SCOPE: `install-harness-apply-timer.sh` falls back to `systemctl --user` /
# `$HOME/.config/systemd/user` when passwordless sudo does not answer, and `install-cell-timers.sh`
# does the same. On such a box `systemctl is-enabled eldato-harness-apply.timer` answers "no", the guard
# stays silent, and `--install` puts TWO mutating actors on one pin — precisely the race the guard's own
# comment says it exists to prevent. So ask BOTH, and NAME the scope that answered.
actuator_scope() { # prints "system" | "user" when eldato-harness-apply.timer is ENABLED
  systemctl is-enabled eldato-harness-apply.timer >/dev/null 2>&1 && { printf 'system\n'; return 0; }
  systemctl --user is-enabled eldato-harness-apply.timer >/dev/null 2>&1 && { printf 'user\n'; return 0; }
  return 1
}
actuator_enabled_in() { # <scope>
  case "$1" in
    system) systemctl is-enabled eldato-harness-apply.timer >/dev/null 2>&1 ;;
    user)   systemctl --user is-enabled eldato-harness-apply.timer >/dev/null 2>&1 ;;
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
  say "  RETIRED eldato-harness-apply.timer (${scope} manager) — ONE actuator on this pin, as --takeover declares"
  return 0
}

do_install() { # [--takeover]
  local takeover="${1:-}" unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}" tmp rc=0 u scope script
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
  # ⛔ RENDER → VERIFY → PLACE → INSTALL, in that order, and the order is the fix. Placement used to
  # happen inside the renderer, so a REFUSED install had already replaced the placed pass, and
  # `--print-unit` wrote a file. Verification now runs against the artifact BEFORE anything is written.
  print_unit "$tmp" || { err "refusing: the units could not be rendered (reason above)"; rm -rf "$tmp"; return 1; }
  verify_unit "$tmp/cell-self-pin.service" || { err "refusing: the rendered cell-self-pin.service failed verification (reason above)"; rm -rf "$tmp"; return 1; }
  script="$(pin_script_path)" || { err "refusing: cannot locate the pass this unit would exec"; rm -rf "$tmp"; return 1; }
  place_pass "$script" || { err "refusing: the pass could not be placed at $script"; rm -rf "$tmp"; return 1; }
  [ -f "$script" ] || { bad "the unit names '${script}' and it does not exist after placement — the unit would fail 203/EXEC before any payload runs"; rm -rf "$tmp"; return 1; }
  # ⛔ ONE ACTUATOR PER PIN. `eldato-harness-apply.timer` already advances this box's harness on the same
  # 10-minute clock (#2416), and two mutating actors on one pin is a race, not redundancy. The guard asks
  # BOTH managers, NAMES the scope it saw, and `--takeover` is the one-actor migration that retires it.
  if scope="$(actuator_scope)"; then
    case "$takeover" in
      --takeover)
        say "installing into $unit_dir (retiring the duplicate actuator in the ${scope} manager first)"
        retire_actuator "$scope" || { rm -rf "$tmp"; return 1; }
        ;;
      *)
        if [ -n "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ]; then
          say "  WARNING: eldato-harness-apply.timer is ENABLED (${scope} manager) and CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR is set — two actuators on one pin, deliberately"
        else
          bad "eldato-harness-apply.timer is ENABLED in the ${scope} manager and already advances this harness on a ten-minute clock — two pin actuators race on one pin. Keep ONE: run '$0 --install --takeover' to RETIRE it and install this unit, or keep 'scripts/install-harness-apply-timer.sh --install' (the shipped, tested one) and do not install this one, or set CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 to override deliberately."
          rm -rf "$tmp"; return 1
        fi
        ;;
    esac
  else
    [ "$takeover" = --takeover ] && say "  (--takeover given, and no eldato-harness-apply.timer is enabled — nothing to retire)"
  fi
  [ "$takeover" = --takeover ] || say "installing into $unit_dir"
  mkdir -p "$unit_dir" 2>/dev/null || { bad "cannot create $unit_dir"; rm -rf "$tmp"; return 1; }
  for u in cell-self-pin.service cell-self-pin.timer; do
    if [ -f "$unit_dir/$u" ] && cmp -s "$tmp/$u" "$unit_dir/$u"; then say "  $u unchanged"; continue; fi
    install -m 0644 "$tmp/$u" "$unit_dir/$u" || { bad "cannot write $unit_dir/$u"; rc=1; continue; }
    say "  $u written"
  done
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; return 1; }
  systemctl daemon-reload || rc=1
  systemctl enable --now cell-self-pin.timer || rc=1
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || { bad "systemd did not accept the units — run: systemctl status cell-self-pin.service"; return 1; }
  say "installed. Read it with: systemctl list-timers cell-self-pin.timer ; systemctl --failed ; $0 --status"
  return 0
}

case "${1:---pass}" in
  --pass|"")      do_pass ;;
  --dry-run)      do_pass dry ;;
  --status)       do_status fetch ;;
  --status-nofetch) do_status nofetch ;;
  --print-unit)   print_unit ;;
  --install)      shift; do_install "${1:-}" ;;
  --takeover)     err "--takeover is an argument to --install: '$0 --install --takeover'"; exit 64 ;;
  # ⛔ THE RANGE IS DERIVED, NOT TYPED. `sed -n '2,68p'` cut mid-sentence and printed `set -u` plus the
  # assignments once the header grew — a help screen that is a lie about the file. Print the leading
  # comment block only, whatever its length is today.
  --help|-h)      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}" ;;
  *)              err "unknown argument '$1' (try --help)"; exit 64 ;;
esac
