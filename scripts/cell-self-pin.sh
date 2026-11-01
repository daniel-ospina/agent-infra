#!/usr/bin/env bash
# cell-self-pin.sh — keep the layer this cell EXECUTES on origin/main, on a clock (agent-infra #3194).
#
#   ./cell-self-pin.sh                 # one pass: resolve the layer, no-op if current, else apply --force
#   ./cell-self-pin.sh --status        # read-only: what it resolved, where it came from, last outcome
#   ./cell-self-pin.sh --dry-run       # resolve + decide + print, change NOTHING
#   ./cell-self-pin.sh --install       # render templates/systemd/cell-self-pin.{service,timer} and install
#   ./cell-self-pin.sh --print-unit    # render to stdout only (the test asserts on this artifact)
#   ./cell-self-pin.sh --help
#
# Exit: 0 = current or applied, 1 = apply failed, 2 = the layer could NOT be resolved (loud, named).
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

# loud() — the shape of EVERY unresolvable state. stderr (so journald carries it), a NAMED reason, the
# readings it decided from, and exit 2. Never a silent `exit 1`: #3194's cost was a unit whose failure
# said nothing an operator could act on.
loud() { # <code> <reason> [detail…]
  local code="$1" reason="$2"; shift 2
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
    for c in $(ls -1dt "$HARNESS_PIN_DIR"/*/ 2>/dev/null); do
      [ -d "$c" ] || continue
      layer_ok "$c" || continue
      best="${c%/}"; break
    done
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
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/cloud-cell-supervisor.sh" ]; then
    printf '%s\n' "$SELF_DIR/cloud-cell-supervisor.sh"; return 0
  fi
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
    err "STALE-RECORD: apply exited 0 but ${HARNESS_PIN_FILE} names nothing readable -- an exit code is not a convergence"
    exit 1
  fi
  if [ "$now" = "$applied" ] && [ "$now" != "$target" ]; then
    err "STALE-RECORD: apply exited 0 but ${HARNESS_PIN_FILE} still names '${now}' while ${HARNESS_REF} is '${target}' -- an exit code is not a convergence"
    exit 1
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$target" "$now" 2>/dev/null; then
    err "STALE-RECORD: the record names '${now}', which does not contain the ref tip '${target}' -- a pin that is not on the ref's line is not a pin"
    exit 1
  fi
  log "applied -> ${now} (record verified; ctrl=$(systemctl is-active eldato-orchestrator 2>/dev/null); note: a RUNNING controller keeps the layer it started on until it is restarted)"
  return 0
}

do_status() {
  local layer sup target
  printf 'cell-self-pin\n  CELL_HOME      %s\n  pin record     %s -> %s\n  pin root       %s\n  pinned HEAD    %s\n  stamp (legacy) %s -> %s\n' \
    "$CELL_HOME" "$HARNESS_PIN_FILE" "$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null || echo '<absent>')" \
    "$HARNESS_PIN_DIR" "$(pinned_head || echo '<unreadable>')" "$STAMP" "$(read_stamp || true)"
  if layer="$(resolve_layer)"; then
    printf '  resolved layer %s\n' "$layer"
    sup="$(supervisor_in "$layer" && true)"; printf '  supervisor     %s\n' "${sup:-<none>}"
    target="$(git -C "$layer" rev-parse "$HARNESS_REF" 2>/dev/null)"; printf '  %s %s\n' "$HARNESS_REF" "${target:-<unreadable>}"
    if [ -n "${target:-}" ] && [ "${target:-}" = "$(pinned_head)" ]; then printf '  verdict        current\n'
    else printf '  verdict        DRIFT (a RUNNING controller keeps the layer it started on until restarted)\n'; fi
  else
    printf '  resolved layer <UNRESOLVED — this is a RED, see --status output above>\n'; return 2
  fi
  return 0
}

# ── --install ────────────────────────────────────────────────────────────────────────────────────
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
say() { printf '%s\n' "$*"; }
bad() { printf 'REFUSING: %s\n' "$*" >&2; }

# pin_script_for_unit — the absolute path the unit's ExecStart names.
# pin_script_for_unit [place] — the absolute path the unit's ExecStart names.
# ⛔ IT MUST LIVE UNDER $CELL_HOME, AND IT IS ALWAYS (RE)PLACED THERE. Two bugs live in the first version
# of this function, both measured in review:
#   (a) Naming the running copy is a path outliving nothing — rendering from a lane worktree produced
#       `ExecStart=/bin/bash /home/…/.worktrees/ai-3194/scripts/cell-self-pin.sh`, and the worktree is
#       PRUNED when the lane merges, leaving 203/EXEC every tick.
#   (b) An `[ -f "$dest" ] && return` early-exit means a FIXED pass never reaches the box — install once,
#       then re-install from a newer checkout, and the unit keeps the old bytes. That is verbatim #3194
#       ("deployed code that was never deployed") reproduced inside its own fix, silently.
# So the copy is UNCONDITIONAL, which also makes the install idempotent in the useful direction.
pin_script_for_unit() {
  local dest="$CELL_HOME/.pi/agent/scripts/cell-self-pin.sh" src
  src="${SELF_DIR:-}/$(basename "${BASH_SOURCE[0]}")"
  if [ ! -f "$src" ] && [ -f "${SELF_DIR:-}/cell-self-pin.sh" ]; then src="${SELF_DIR}/cell-self-pin.sh"; fi
  [ -f "$src" ] || { err "cannot find the pass to install beside itself (looked in ${SELF_DIR:-<unknown>})"; return 1; }
  if [ "$src" != "$dest" ]; then
    mkdir -p "$(dirname "$dest")" || { err "cannot create $(dirname "$dest")"; return 1; }
    install -m 0755 "$src" "$dest" || { err "cannot place the pass at $dest"; return 1; }
  fi
  printf '%s\n' "$dest"
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
  script="$(pin_script_for_unit)" || { bad "cannot locate an installed cell-self-pin.sh to exec"; return 1; }
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

verify_unit() { # <rendered service> — the properties the ISSUE names, asserted on the ARTIFACT
  local f="$1" body exec_path
  # ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE. The template documents the defect it replaced, and that prose
  # legitimately contains `/tmp/cell-ai`; a guard that also refused the documentation would force the
  # next reader to delete the only explanation of why the line is banned. Strip comments first.
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  # ⛔ THE DEFECT ITSELF, AS AN INVARIANT: a rendered pin unit must carry NO bootstrap-only path, AS A
  # TOKEN — not merely after `=` or at line start. `ExecStart=/bin/bash /tmp/cell-ai/scripts/…` puts a
  # SPACE before the path, and that is the reachable form: `pin_script_for_unit`'s fallback is whatever
  # checkout the installer ran from, which on a provisioning box is exactly the bootstrap clone.
  if printf '%s\n' "$body" | grep -qE '(^|[[:space:]=])/(var/)?tmp/cell-ai(/|[[:space:]]|$)'; then
    bad "a rendered directive names the provisioning clone (/tmp/cell-ai) — that path is absent on a running cell and systemd fails the unit at CHDIR before any payload runs (#3194)"; return 1
  fi
  # ⛔ AND THE EXECSTART MUST LIVE UNDER $CELL_HOME. Any other absolute path can be pruned out from under
  # the unit (a lane worktree, a bootstrap clone); $CELL_HOME is the one root a running cell keeps.
  # ⛔ EVERY ExecStart, AND EXACTLY ONE. `Type=oneshot` permits REPEATED `ExecStart=` and systemd runs all
  # of them, so checking only the first line let an injected second one install green — a fail-open in
  # the one rule this change exists to enforce (measured in review: legit line first, appended
  # `ExecStart=/bin/bash /srv/nowhere/…` → `--install` returned 0 and both lines landed).
  local n_exec; n_exec="$(printf '%s\n' "$body" | grep -c '^ExecStart=')"
  if [ "$n_exec" -ne 1 ]; then
    bad "the rendered unit declares ${n_exec} ExecStart= lines — exactly one is installable (systemd runs them ALL, so a second one is an unverified executable directive)"; return 1
  fi
  exec_path="$(printf '%s\n' "$body" | sed -n 's|^ExecStart=/bin/bash \(.*\)$|\1|p')"
  if [ -z "$exec_path" ]; then
    bad "the rendered unit's ExecStart is not '/bin/bash <absolute script>'"; return 1
  fi
  case "$exec_path" in
    "$CELL_HOME"/*) ;;
    *) bad "ExecStart names '${exec_path}', which is NOT under CELL_HOME ('${CELL_HOME}') — a path outside the one home can be pruned out from under the unit, which is the failure this change exists to remove (203/EXEC every tick)"; return 1 ;;
  esac
  if [ ! -f "$exec_path" ]; then
    bad "ExecStart names '${exec_path}', which does not exist — the unit would fail 203/EXEC before any payload runs"; return 1
  fi
  # ⛔ AND THE UNIT MUST CARRY THE SAME BASE THE EXECSTART USES. The service manager's HOME is not the cell
  # home, so a unit that carried only `HOME=` left the pass defaulting CELL_HOME from an unrelated value
  # while its ExecStart sat under the real one — measured: the pass then read `$HOME/.harness-path` while
  # the controller read `$CELL_HOME/.harness-path`, i.e. it pinned a tree the controller never runs.
  if ! printf '%s\n' "$body" | grep -qxF "Environment=CELL_HOME=${CELL_HOME}"; then
    bad "the rendered unit does not carry 'Environment=CELL_HOME=${CELL_HOME}' — without it the pass derives its base from the service manager's HOME and can read a DIFFERENT pin record than the controller"; return 1
  fi
  # ⛔ AND IT MUST NOT DECLARE A WORKING DIRECTORY AT ALL. Any absolute path here is a bootstrap-time
  # value outliving its directory; the pass `cd`s itself after resolving the layer.
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*WorkingDirectory='; then
    bad "the rendered unit declares WorkingDirectory= — one directive that refuses to start the unit when the directory is gone (EXIT_CHDIR 200); drop it and let the pass resolve its own cwd"; return 1
  fi
  # A skipped CONDITION is a green no-op — see the header. Refuse it on the artifact.
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*ConditionPathExists='; then
    bad "the rendered unit declares ConditionPathExists= — a failed condition SKIPS the unit and leaves it green; the missing-layer case must be a RED payload exit, not a skip"; return 1
  fi
  printf '%s\n' "$body" | grep -qxF 'SuccessExitStatus=0' || { bad "the rendered unit must declare SuccessExitStatus=0 (only 0 is green)"; return 1; }
  return 0
}

do_install() {
  local unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}" tmp rc=0 u
  tmp="$(mktemp -d)" || { bad "mktemp failed"; return 1; }
  print_unit "$tmp" || { err "refusing: the units could not be rendered (reason above)"; rm -rf "$tmp"; return 1; }
  verify_unit "$tmp/cell-self-pin.service" || { err "refusing: the rendered cell-self-pin.service failed verification (reason above)"; rm -rf "$tmp"; return 1; }
  # ⛔ ONE ACTUATOR PER PIN. `eldato-harness-apply.timer` already advances this box's harness on the same
  # 10-minute clock (#2416), and two mutating actors on one pin is a race, not redundancy. Refuse — and
  # name which one to keep — instead of silently installing a second one.
  if [ -z "${CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR:-}" ] \
     && systemctl is-enabled eldato-harness-apply.timer >/dev/null 2>&1; then
    bad "eldato-harness-apply.timer is ENABLED on this box and already advances the harness on a ten-minute clock — two pin actuators race on one pin. Keep ONE: 'scripts/install-harness-apply-timer.sh --install' (the shipped, tested one) supersedes this unit; disable it first, or set CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 to override deliberately."
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$unit_dir" 2>/dev/null || { bad "cannot create $unit_dir"; rm -rf "$tmp"; return 1; }
  say "installing into $unit_dir"
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
  --status)       do_status ;;
  --print-unit)   print_unit ;;
  --install)      do_install ;;
  --help|-h)      sed -n '2,68p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)              err "unknown argument '$1' (try --help)"; exit 64 ;;
esac
