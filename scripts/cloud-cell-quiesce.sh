#!/usr/bin/env bash
# cloud-cell-quiesce.sh — reset ONE cloud cell to a single, known controller.
#
# Why this exists: a cell accumulates tmux sessions and orch-loop processes from
# every earlier configuration it ever ran. A `ps | grep orch-loop | head -1` check
# shows one and hides the rest, so a cell can silently be draining TWO repos at
# once (observed 2026-10-14: cell 2 held 3 orch-loop processes and sessions in
# both /tmp/cell-ai and /tmp/cell-t). This makes the cell's actor set exactly one.
#
# Usage (on the cell):
#   REPO=/tmp/cell OR=daniel-ospina/tortoise SCOPE=own MAX_LANES=3 \
#     bash cloud-cell-quiesce.sh
#
# Env: REPO (required) OR (required) SCOPE (default own) MAX_LANES (default 3)
#      CELL_HOME (default: DERIVED — the box's durable home, see scripts/lib/cell-home.sh)
#      ENV_FILE (default $CELL_HOME/keys.env)
#      HARNESS (default $REPO/scripts/orchestrator-harness)
set -uo pipefail

# ── THE ONE HOME (agent-infra#3453) — DERIVED, never re-spelled ──────────────────────────────────
# This default used to be `/tmp/cell-home`, the legacy volatile home: the quiesce then re-created the
# controller session with `HOME=/tmp/cell-home` while the unit that spawns lanes gave them
# `/home/cmux`, so the relaunched controller's `git push` read a `contents=read` PAT while its `gh`
# reads worked. One derivation, one home: `scripts/lib/cell-home.sh`.
# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""     # under `bash -s` $0 is literally `bash` -> `.`
QUIESCE_SELF_DIR=""
if [ -n "$_SELF" ]; then QUIESCE_SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd -P)"; fi
CELL_HOME_LIB="${QUIESCE_SELF_DIR:+$QUIESCE_SELF_DIR/lib/cell-home.sh}"
if [ -n "$CELL_HOME_LIB" ] && [ -r "$CELL_HOME_LIB" ]; then
  . "$CELL_HOME_LIB"
  CELL_HOME="$(cell_home_resolve)"
elif [ -n "${CELL_HOME:-}" ]; then
  :   # an explicit CELL_HOME is a complete answer; the resolver only supplies the DEFAULT
elif [ -n "${HOME:-}" ]; then
  CELL_HOME="$HOME"
  printf '%s: warn: %s is not readable — using HOME (%s) as the cell home; the durable-home default is unavailable on this copy (agent-infra#3453)\n' "${0##*/}" "${CELL_HOME_LIB:-lib/cell-home.sh}" "$CELL_HOME" >&2
else
  printf '%s: FATAL: %s is not readable and neither CELL_HOME nor HOME is set — refusing to default the cell home to the legacy /tmp/cell-home (agent-infra#3453)\n' "${0##*/}" "${CELL_HOME_LIB:-lib/cell-home.sh}" >&2
  exit 78
fi

REPO="${REPO:?REPO is required}"
OR="${OR:?OR is required}"
SCOPE="${SCOPE:-own}"
MAX_LANES="${MAX_LANES:-3}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
HARNESS="${HARNESS:-$REPO/scripts/orchestrator-harness}"

step() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

step "=== QUIESCE REPO=$REPO OR=$OR SCOPE=$SCOPE ==="

# 1. Before: record what was actually there, so the change is auditable.
step "before: $(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh') orch-loop process(es)"
ps -eo etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | sed 's/^/  before: /' | cut -c1-160
step "before: $(tmux ls 2>/dev/null | wc -l | tr -d ' ') tmux session(s)"
tmux ls 2>/dev/null | cut -d: -f1 | while read -r s; do
  p="$(tmux list-panes -t "$s" -F '#{pane_current_path}' 2>/dev/null | head -1)"
  printf '  before: %-16s -> %s\n' "$s" "$p"
done

# Locate the supervisor. It is NOT in the harness dir: the cells keep it at
# <clone>/scripts/cloud-cell-supervisor.sh (agent-infra) or in the runtime dir.
SW=""
for c in "$REPO/scripts/cloud-cell-supervisor.sh" \
         "$O/cloud-cell-supervisor.sh" \
         /tmp/cell-ai/scripts/cloud-cell-supervisor.sh \
         /tmp/cell/scripts/cloud-cell-supervisor.sh; do
  [ -f "$c" ] && { SW="$c"; break; }
done
step "supervisor: ${SW:-<none found — will start tmux directly>}"

# Locate the WIP sweep (agent-infra#3485). It lives beside bg-rescue-wip.sh in the clone's scripts/
# (they are a pair: the sweep classifies with `bg-rescue-wip.sh --verdict` and archives with
# `bg-rescue-wip.sh`), with the PINNED HARNESS TREE, the runtime dir and the farmed home as fallbacks.
#
# ⛔ THE PIN IS A FILE THAT CONTAINS A PATH, NOT A DIRECTORY (review finding). `.harness-path` is the
# pin's PATH RECORD — a regular file holding the harness directory the controller execs
# (`scripts/harness-exec.sh:67`, `scripts/orchestrator-harness/orch-pin-exec.sh:78`,
# `scripts/harness-apply-pass.sh:207`). A candidate spelled `<root>/.harness-path/scripts/wip-sweep.sh`
# is therefore not a file and could never match: on a box where the sweep exists ONLY in the pinned
# tree, this script would have reported `FATAL: wip-sweep.sh not found`, archived NOTHING, and named a
# path that cannot exist — #3485's gap un-closed on exactly that box, with a misleading remedy. Read
# the record and use its CONTENT, the same way the harness launcher does.
HARNESS_PIN_REC="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
PINNED_DIR=""
# Read it the way the launcher reads it — FIRST LINE, CR/LF stripped
# (`scripts/harness-exec.sh:83`, `scripts/orchestrator-harness/orch-pin-exec.sh:86`). A record rewritten
# on a box that ever wrote CRLF otherwise yields `<dir>\r`, a candidate that cannot exist, and the sweep
# reads as absent on the one box this fallback exists for.
[ -f "$HARNESS_PIN_REC" ] && PINNED_DIR="$(head -1 "$HARNESS_PIN_REC" 2>/dev/null | tr -d '\r\n')"
# ⛔ EXISTS IS NOT RUNS (#3588 review). `[ -f ]` selected a 0-BYTE `wip-sweep.sh`, and `bash <empty> --apply`
# exits 0 — so the hook printed "every dirty worktree … is archived on origin" and `DONE`, rc=0, having
# archived NOTHING. That is the false PASS this hook exists to prevent, on the one path where the disk stops
# existing. `pi-bootstrap/setup.sh` farms with `cp -f` + `chmod +x`, so an interrupted copy leaves a 0-byte
# executable: mechanically producible, not hypothetical. A candidate must be non-empty AND parse; if none is
# usable, `SWEEP` stays empty and the existing loud "WORK ON THIS BOX WILL NOT BE ARCHIVED" path fires.
SWEEP=""
# ⛔ THE RECORD HOLDS THE HARNESS DIR, SO THE SWEEP IS ITS SIBLING — NOT ITS CHILD (#3588 review, cycle 6).
# `.harness-path` holds `<pinroot>/scripts/orchestrator-harness` (`scripts/cloud-cell-supervisor.sh:2315`
# writes `HARNESS="$dir/scripts/orchestrator-harness"` into it; `scripts/harness-exec.sh:83` and
# `scripts/orchestrator-harness/orch-pin-exec.sh:78` exec that same record). Appending `/scripts/wip-sweep.sh`
# to it therefore built `<pinroot>/scripts/orchestrator-harness/scripts/wip-sweep.sh`, which CANNOT EXIST:
# the sweep in a pinned tree sits at `<pinroot>/scripts/wip-sweep.sh`, exactly the relationship this script
# already gets right for `$REPO` above. MEASURED on a real pin shape — record `…/pin/<sha>/scripts/
# orchestrator-harness`, sweep at `…/pin/<sha>/scripts/wip-sweep.sh` (exists), candidate built by the old
# spelling (absent). So on the one box this fallback exists for, the hook printed `FATAL: wip-sweep … WORK ON
# THIS BOX WILL NOT BE ARCHIVED` and archived NOTHING, while the comment above it claimed the box was fixed.
# It failed loud (never a false green) but the fallback was INERT, and no arm created a `.harness-path`
# record at all — which is how a candidate that can never match stayed green.
# Both shapes are tried, sibling first: the record-as-harness-dir is what every writer produces today, and
# the record-as-pinroot spelling costs one `[ -s ]` test and removes the ambiguity if a writer ever moves.
PINNED_ROOT=""
[ -n "$PINNED_DIR" ] && PINNED_ROOT="$(dirname "$PINNED_DIR")"
# ⛔ PARSES IS NOT SWEEPS — THE LAST FALSE PASS ON THIS HOOK (#3588 review). `-s` + `bash -n` accepted a
# TRUNCATED PREFIX of a real `wip-sweep.sh`, and that is mechanically producible: `pi-bootstrap/setup.sh`
# farms with `cp -f`, so an interrupted copy leaves a whole-line prefix. MEASURED on whole-line truncations
# of the shipped sweep at 60/80/100/150 lines: all four PARSE, and `bash <prefix> --apply` exits **0 having
# archived nothing** — so this hook printed "every dirty worktree … is archived on origin", set rc=0 and
# `DONE`, over a box where NOTHING was archived, on the one path where the disk stops existing. That is the
# exact false PASS the `-s` check was added to prevent, one level up.
# So the candidate must BEHAVE in the read-only mode this hook already relies on: against a FRESH state dir
# a usable sweep answers `status=never` with `rc=3` and a `detail=` naming the missing record. MEASURED
# against the same truncations: 60/80/100/150 print NOTHING and exit 0 (refused); a 400-line prefix that
# reaches partway into the reader answers `status=failed`/3 (refused — it is not `never`); the shipped
# sweep answers `status=never`/3/`detail=no pass record at …` (accepted).
# ⛔ `--print-status` WRITES NOTHING (its branch exits before the pass-start marker), and the state dir it
# reads is a scratch `mktemp -d`, never `$O/state` — so probing a candidate can neither consume nor create
# the record this hook is about to grade. `WIP_SWEEP_STATUS_FILE` is pointed into that scratch dir too, so
# an inherited override cannot make the probe read a real record and answer `ok` for a broken candidate.
# ⛔ IT IS NOT TIMEOUT-BOUNDED, and that is stated rather than implied: the bound would have to come from
# `scripts/lib/bounded.sh`, which is resolved by the very candidate under test (it is not yet sourced
# here), and `--print-status` runs only local `sed`/`date` work. A candidate that hangs there is a broken
# install, the same class `docs/ops/wip-sweep.md` names for `bounded_lib_path`'s own probe.
sweep_usable() { # sweep_usable <path> — it must ANSWER the reader's contract, not merely parse
  [ -s "$1" ] || return 1
  bash -n "$1" >/dev/null 2>&1 || return 1
  local sd out rc st det
  sd="$(mktemp -d 2>/dev/null)" || return 1
  out="$(WIP_SWEEP_STATE_DIR="$sd" WIP_SWEEP_STATUS_FILE="$sd/wip-sweep.status" \
        bash "$1" --print-status </dev/null 2>/dev/null)"; rc=$?
  rm -rf "$sd" 2>/dev/null || true
  [ "$rc" -eq 3 ] || return 1
  st="$(printf '%s\n' "$out" | sed -n 's/^status=//p' | sed -n '1p')"
  det="$(printf '%s\n' "$out" | sed -n 's/^detail=//p' | sed -n '1p')"
  [ "$st" = never ] && [ -n "$det" ]
}
for c in "$REPO/scripts/wip-sweep.sh" \
         ${PINNED_ROOT:+"$PINNED_ROOT/wip-sweep.sh"} \
         ${PINNED_DIR:+"$PINNED_DIR/scripts/wip-sweep.sh"} \
         "$O/wip-sweep.sh" \
         "${HOME:-/nonexistent}/.pi/agent/scripts/wip-sweep.sh"; do
  sweep_usable "$c" && { SWEEP="$c"; break; }
done
step "wip-sweep: ${SWEEP:-<none found — WORK ON THIS BOX WILL NOT BE ARCHIVED>}"

# 2. Stop the supervised controller, then kill EVERY session and ANY stray
#    controller. tmux kill-server is the only reliable sweep: kill-session -t orch
#    leaves the fix-*/merge-*/chain-* sessions (and their claim leases) behind.
[ -n "$SW" ] && bash "$SW" stop >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
sleep 2
# The bracket keeps this pattern from matching this script's own argv.
pkill -f '[o]rch-loop\.sh' >/dev/null 2>&1 || true
pkill -f '[m]erge-one\.sh' >/dev/null 2>&1 || true
pkill -f '[f]ix-one\.sh' >/dev/null 2>&1 || true
sleep 2

# 3. ⛔ ARCHIVE EVERY DIRTY WORKTREE BEFORE THIS BOX IS HANDED ON (#3485) — THE TOTAL-LOSS ROW.
# A lane's uncommitted work is rescued by `bg-rescue-wip.sh` from inside `run_agent`, so it survives a
# cap kill. It does NOT survive the two routes that bypass that function, and this script is one of
# them: an OOM-killed lane, or any lane this quiesce just killed, leaves its work in the working tree
# and nothing in the object database. Everything else this script does — kill the sessions, re-seed,
# restart — is fine; reclaiming or rebuilding the VM afterwards is what makes the disk stop existing.
# `refs/wip/*` lives on ORIGIN, so archiving is what turns "the work was on that box" into "the work is
# still there".
#
# ARMED (`--apply`), and ⛔ THAT IS **NOT** A DEPARTURE FROM #1678 — it is that rule applied by its own
# owner. #1678 says a tool acting on a box ships dry-run; `wip-sweep.sh` honours it exactly (`DRY_RUN=1`
# is its default, `scripts/wip-sweep.sh:150`), and the ARMING DECISION lives here, in the CALLER's command
# line, which is where the rule puts it — the same split `pi-reap-worktrees.sh`'s contract uses. So no
# `OVERRIDES:` line is owed on either artifact, and the reason this note is worth the ink is that an
# earlier draft of it called this "a deliberate departure … that rule governs DELETION, where the default
# must be safe": that characterisation was FALSE, and a false departure is worse than none — the next
# reader who trusts it either writes an `OVERRIDES:` line for a ruling nobody departed from, or "restores"
# dry-run as the default on the one path where the disk stops existing, which would archive nothing for
# ever while reading as a safeguard (the inert-enforcer shape). The sweep's own justification for adding
# data to origin still stands and is not a concession: it ADDS data (`refs/wip/*`), touches nothing
# locally (a throwaway index, no branch move, no working-tree write).
#
# ⛔ THE FAILURE IS LOUD AND IT IS NOT SWALLOWED, BUT IT DOES NOT STOP SUPERVISION BEING RESTORED.
# Aborting here would leave the cell with ZERO controllers — a worse state than the one this script
# exists to end. So the pass runs to completion and this script exits NON-ZERO at the end, which is
# what the CALLER of this quiesce reads — nothing reads it automatically yet (no `check_wip_sweep` exists
# in `cloud-cell-bringup.sh`; adding one is follow-up, and claiming it here would be an inert alarm
# channel). A missing sweep is the same class as a
# failing one: "a missing rescuer must never read as nothing to rescue".
# ⛔ AND IT RUNS UNCONDITIONALLY, BEFORE THE STRAY-CONTROLLER INVARIANT BELOW (#3588 review, cycle 8).
# The invariant check used to sit here — `LEFT != 0` → `exit 1` — and the archive was step 3b, AFTER it.
# So on any cell where one orch-loop-looking process outlived the 2 s + 2 s kill window, the script exited
# before archiving ANYTHING, and the only FATAL named the stray process: nothing on the run said the work
# had not been archived. That is reachable without a real survivor — the pattern matches any argv
# containing the string (a `tail -f …/orch-loop.log`, an editor, a monitor grepping it) and a controller
# still winding down after TERM counts. Preserving the work is unconditional; refusing to REOPEN the cell
# is the invariant. So the archive runs first, the invariant still aborts (with the archive's own verdict
# stated in the abort message), and neither concern can silence the other.
#
# RESIDUAL, stated rather than implied: a tree a surviving process is still writing may be archived
# mid-write. That snapshot is incomplete — and it is still strictly better than no snapshot on a box whose
# disk is about to stop existing, which is what the old ordering produced.
WIP_RC=0; WIP_WHY=""
WIP_ONLY_LOCAL=0; WIP_LOCAL_WHY=""
if [ -z "$SWEEP" ]; then
  WIP_RC=3; WIP_WHY="no USABLE wip-sweep.sh (looked at \$REPO/scripts, the tree the pin record ${HARNESS_PIN_REC} names, $O, \$HOME/.pi/agent/scripts; a candidate must answer '--print-status' with status=never/rc=3, so a 0-byte, non-parsing or TRUNCATED copy is refused)"
  step "FATAL: wip-sweep: $WIP_WHY"
  step "FATAL: wip-sweep: UNCOMMITTED WORK ON THIS BOX WAS NOT ARCHIVED. Any dirty worktree here is lost if this cell is reclaimed."
else
  step "wip-sweep: archiving uncommitted work to refs/wip/* on origin BEFORE this cell is handed on"
  # ⛔ `--max 0` ON THIS PATH, AND ONLY ON THIS PATH (review finding). The sweep's default cap (25
  # archives) exists to bound a PERIODIC pass. Here the disk is about to stop existing and nothing re-runs
  # the pass, so a cap is a silent partial archive: on a cell holding 40 dirty lane trees, 25 are archived,
  # 15 are deferred, and the box is handed on. `--max 0` is the documented "no cap" value and it is the
  # configuration that matches this caller's intent.
  # ⛔ REMOVE THE PREVIOUS PASS'S RECORD BEFORE THIS ONE RUNS (#3588 review, cycle 8, second pass).
  # The record is read below to decide `DONE`, and a record left by an EARLIER pass says
  # `unpushed_worktrees=0` because it described a different moment. Leaving it in place makes the check
  # satisfiable by a stale file: a sweep that exited 0 without writing its record (a foreign or older
  # tool resolved from one of the fallback candidates) would be graded against the LAST pass's verdict
  # and print `DONE` over commits this pass never counted. The sweep writes the record LAST and
  # atomically, so "no record after an exit-0 pass" means THIS pass did not report — which is
  # unverifiable, not zero. Removing it first is what makes the absence mean that.
  WIP_ST="${WIP_SWEEP_STATUS_FILE:-$O/state/wip-sweep.status}"
  rm -f "$WIP_ST" 2>/dev/null || true
  WIP_OUT="$(O="$O" WIP_SWEEP_STATE_DIR="$O/state" bash "$SWEEP" --apply --max 0 --repo "$REPO" 2>&1)"; WIP_RC=$?
  printf '%s\n' "$WIP_OUT" | sed 's/^/  wip-sweep: /'
  case "$WIP_RC" in
    0)
       step "wip-sweep: every dirty worktree of $REPO is archived on origin (other clones on this box were NOT swept)"
       # ⛔ EXIT 0 IS NOT "THE WORK IS ON ORIGIN" (#3588 review, cycle 8). The sweep exits 0 when
       # `unpushed_worktrees>0`, and that is CORRECT for the sweep: it cannot archive commits, since
       # bg-rescue-wip archives UNCOMMITTED work only. But this script's own step-8 invariant is "the work
       # that was on this box is on origin", so a lane that COMMITTED and never pushed is a clean tree —
       # nothing dirty, nothing archived, sweep exit 0 — and the old code printed DONE and exited 0 over
       # commits that died with the VM. The counter that would have caught it was already sitting in the
       # record, and the sweep's own comment says it is there so "the pass was green and three commits died
       # with the box" cannot be read off a clean summary — which is exactly what this caller did.
       # Unreadable is treated as unverified, never as zero: the record is written LAST by the sweep and a
       # pass that could not write it exits 3, so "exit 0 and no record" means the tool that ran was not
       # the one that shipped with this hook, and its silence is not evidence.
       WIP_UNP=""
       [ -r "$WIP_ST" ] && WIP_UNP="$(awk -F= '$1=="unpushed_worktrees"{v=$2} END{print v}' "$WIP_ST" 2>/dev/null)"
       case "${WIP_UNP:-}" in
         ''|*[!0-9]*)
           WIP_ONLY_LOCAL=1
           WIP_LOCAL_WHY="the pass record $WIP_ST is missing or carries no usable unpushed_worktrees= count, so 'every commit on this box is on origin' CANNOT be verified"
           step "FATAL: wip-sweep: $WIP_LOCAL_WHY" ;;
         0) : ;;
         *)
           WIP_ONLY_LOCAL=1
           WIP_LOCAL_WHY="$WIP_UNP worktree(s) hold commit(s) that no remote has — bg-rescue-wip archives UNCOMMITTED work only, so those commits exist ONLY on this disk"
           step "FATAL: wip-sweep: $WIP_LOCAL_WHY" ;;
       esac ;;
    1) WIP_WHY="the pass was INCOMPLETE (exit 1: work was deferred by the per-pass cap or the budget, so it is NOT archived)"
       step "FATAL: wip-sweep: $WIP_WHY" ;;
    *) WIP_WHY="the pass FAILED (exit $WIP_RC) — see the run above"
       step "FATAL: wip-sweep: $WIP_WHY"
       step "FATAL: wip-sweep: work on this box is NOT fully archived; it is LOST if this cell is reclaimed. Record: $O/state/wip-sweep.tsv" ;;
  esac
fi

# 3b. Prove the KILL sweep is complete before restarting — a restart on a cell that still holds a second
#     controller re-creates the state this script exists to end. This runs AFTER the archive (see the note
#     above step 3): the invariant governs the restart, never the rescue.
LEFT="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
if [ "$LEFT" != "0" ]; then
  step "FATAL: $LEFT orch-loop process(es) survived the kill sweep"
  ps -eo pid,etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | cut -c1-160
  # The archive DID run by now, so say what it concluded. Without this the abort reads as "nothing was at
  # risk", which is the same false assurance the old ordering produced by never archiving at all.
  if [ "$WIP_RC" = "0" ] && [ "$WIP_ONLY_LOCAL" = "0" ]; then
    step "  (the WIP archive HAD already run: every dirty worktree of $REPO is on origin)"
  else
    step "FATAL: and the WIP archive is NOT a success: ${WIP_WHY}${WIP_LOCAL_WHY}"
  fi
  exit 1
fi
step "kill sweep clean: 0 orch-loop, $(tmux ls 2>/dev/null | wc -l | tr -d ' ') tmux session(s)"

# 4. Re-seed the runtime from the harness (the source of truth) and restart ONE.
[ -d "$REPO" ] || { step "FATAL: no clone at $REPO"; exit 1; }
[ -f "$HARNESS/claims.sh" ] || { step "FATAL: no claims.sh in $HARNESS"; exit 1; }
mkdir -p "$O"
cp "$HARNESS"/*.sh "$O"/ 2>/dev/null || true
step "seeded $O with $(ls "$O"/*.sh 2>/dev/null | wc -l | tr -d ' ') scripts (claims.sh: $([ -f "$O/claims.sh" ] && echo yes || echo NO))"

# 5. Start exactly one controller.
step "starting controller: OR=$OR REPO=$REPO SCOPE=$SCOPE MAX_LANES=$MAX_LANES"
if [ -n "$SW" ]; then
  # ⛔ ORCH_FOREGROUND DESCRIBES THE CALLER, AND THIS CALLER IS NOT THE SERVICE MANAGER (review P1 round 19,
  # #2402 / C). The unit exports `ORCH_FOREGROUND=1` and every lane shell inherits it through the tmux server
  # the controller created; quiesce is the LAST unpinned `start` caller. It is also the worst one to leave
  # unpinned: quiesce STOPS the unit a few lines above, so `foreground_handover` has nothing to wait for and
  # `start` execs `orch-loop.sh` inside quiesce's own child — a dispatcher OUTSIDE the unit's cgroup while the
  # enabled unit is stopped. Quiesce's own "exactly one orch-loop" assertions then pass and it prints DONE:
  # the cell is left unsupervised with a green report, which is #2402 restored silently.
  CELL_HOME="$CELL_HOME" ENV_FILE="$ENV_FILE" REPO="$REPO" O="$O" OR="$OR" \
    SCOPE="$SCOPE" MAX_LANES="$MAX_LANES" ORCH_FOREGROUND=0 \
    bash "$SW" start >/dev/null 2>&1 || true
else
  # Direct start, mirroring the supervisor's launch line.
  #
  # ⛔ `unset GH_REPO` AFTER `set +a`, the same two-token strip the supervisor's session command
  # carries: `$ENV_FILE` is re-sourced INSIDE the session, so a global `export GH_REPO=…` in it
  # answers every `gh` call that omits `--repo` from this controller onward — the #2235 fail-open
  # (a rail printing '✅ PR #2232 is ALREADY MERGED' for a tortoise PR while grading agent-infra).
  # This path builds its OWN session instead of going through the supervisor, so it needs its own
  # strip; `cloud-cell-supervisor.test.sh` §12 pins the supervisor's two and cannot see this one.
  #
  # ⛔ WHY THESE COMMENTS ARE HERE AND NOT INSIDE THE CONTINUATION BELOW (#2235 review P1): a
  # backslash-newline is joined LEXICALLY, so a `#` line placed between `tmux new-session … \` and
  # the command string ENDS THE COMMAND — tmux then starts a bare default shell named `orch` with
  # NO command argument, the string runs as a separate command (127, swallowed by `2>/dev/null ||
  # true`), and the script reports success having started nothing. Verified by the reviewer with a
  # stub `tmux` recording `new-session -d -s orch -c <dir>` and no argv[7].
  tmux new-session -d -s orch -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; unset GH_REPO; \
     HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' MAX_LANES='$MAX_LANES' \
     bash '$O/orch-loop.sh' >> '$O/logs/orch-loop.log' 2>&1" >/dev/null 2>&1 || true
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  n="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
  [ "$n" = "1" ] && break
done

# 6. After: assert the invariant. ONE controller, and it is on the intended repo.
AFTER="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
step "after: $AFTER orch-loop process(es), $(tmux ls 2>/dev/null | wc -l | tr -d ' ') session(s) $(tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
if [ "$AFTER" != "1" ]; then
  step "FATAL: expected exactly 1 controller, found $AFTER"
  ps -eo pid,etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | cut -c1-160
  exit 1
fi

# 7. Confirm it is pointed at the right repo, read from the live process env.
PID="$(pgrep -f '[o]rch-loop\.sh' | head -1)"
EFF_REPO="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^REPO=' | head -1)"
EFF_OR="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^OR=' | head -1)"
EFF_SCOPE="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^SCOPE=' | head -1)"
step "live controller pid=$PID  $EFF_REPO  $EFF_OR  $EFF_SCOPE"
case "$EFF_REPO" in
  "REPO=$REPO") : ;;
  *) step "FATAL: live REPO does not match intended ($EFF_REPO vs REPO=$REPO)"; exit 1 ;;
esac

# 8. The quiesce is only DONE when the work that was on this box is on origin (#3485). One controller
# restored AND zero archived work is not a success: the next reclaim takes the work with it. Reported
# last, so the operator sees the true state of the cell, and via the exit code, so a scripted bring-up
# sees it too.
if [ "$WIP_RC" != "0" ]; then
  step "NOT DONE — one controller IS restored on $REPO, but the WIP archive did not complete: $WIP_WHY"
  exit 1
fi
# The same invariant, one level finer: an archive that succeeded over DIRTY trees does not cover commits
# that were never pushed, so the count in the record decides this too (#3588 review, cycle 8).
if [ "$WIP_ONLY_LOCAL" != "0" ]; then
  step "NOT DONE — one controller IS restored on $REPO, but WIP exists only on this disk: $WIP_LOCAL_WHY"
  exit 1
fi
step "DONE — cell has exactly one controller on $REPO"
