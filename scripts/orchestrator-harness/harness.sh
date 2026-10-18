#!/usr/bin/env bash
# harness.sh — ONE entry point for the orchestrator harness on this machine: deploy it, restart the
# whole thing as one act, and say whether it came up.
#
#   harness.sh status      read-only report — everything a reader needs to answer "where is it?"
#   harness.sh verify      read-only ASSERTION — exit 0 healthy · 1 unhealthy · 2 cannot determine
#   harness.sh drift       does the deployed copy match the repo? per-file, with --all
#   harness.sh deploy      mirror the repo's harness dir into $O + render the plist + record provenance
#   harness.sh restart     STOP the stack → deploy → start → VERIFY   ← the whole thing, one command
#   harness.sh stop        stop the whole stack (verified; never signals a pid it did not identify)
#
# WHY THIS EXISTS (2026-10-18, owner's requirement verbatim):
#
#   "our harness system is not a collection of disparate scripts that each needs deploying by itself,
#    activating by itself, etc but a cohesive system that self-heals, self-tests, and is easily
#    launched as a whole as a restart"
#
# What the box actually had was three unrelated acts with three different vocabularies and no
# verification between them:
#
#   deploy   `cp -R "$R"/scripts/orchestrator-harness/. "$O"/` — inside bg/finish.sh, a raw copy that
#            overwrites `orch-loop.sh` WHILE the controller is executing it (bash reads a script
#            incrementally: the running controller then reads the NEW bytes at the OLD offset), writes
#            no provenance record (so `check-deployed-drift.sh` answered UNKNOWN — cannot verify), and
#            cannot remove a script the harness no longer ships.
#   activate `launchd-cycle.sh`, reached only through `install.sh --start|--restart`, which rendered
#            label com.eldato.orchestrator-loop — a job that runs `$O/orch-loop.sh` ALONE — while the
#            box ran com.eldato.orchestrator-stack (`$O/supervisor.sh` + three workers). The documented
#            recovery would have replaced a supervised stack with a bare loop, silently.
#   verify   `install.sh --start` proves pid+heartbeat for the job IT rendered, and nothing proved that
#            the bytes running were the bytes in the repo, or that the workers were alive at all.
#
# This file composes those three into one verb set. It re-implements NOTHING that already has an
# authority: the plist render and the provenance record are install.sh's, the launchd sequence and the
# heartbeat arithmetic are launchd-cycle.sh's, the byte comparison is check-deployed-drift.sh's. It
# owns exactly two things those did not: the ORDER (stop before overwriting a running script) and the
# VERDICT (one exit code for the whole stack, not one per script).
#
# EXIT CODES — the same contract as scripts/orchestrator-bringup.sh, deliberately:
#   0  ok             1  refused / unhealthy (one actionable line on stderr)   2  cannot determine
# ⛔ 2 IS NOT 1 AND NEITHER IS 0. "I could not read the datum" is never a pass in this repo
# (agent-infra#1745). A verb that cannot answer says so and exits 2.
#
# Runs from the REPO or from the deployed $O: `status`/`verify`/`drift` work from either, since
# check-deployed-drift.sh finds the checkout itself. `deploy`/`restart` REFUSE from a non-checkout —
# there is nothing to deploy from there, and the old raw `cp` did exactly that from whatever tree
# happened to be on disk.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="${O:-$HOME/orchestrator}"
# The job a whole-box orchestrator runs. NOT a constant: it is DISCOVERED from what launchd actually
# has loaded and pointing into this $O (see discover_label). Set LABEL=… to pin it.
LABEL="${LABEL:-}"
# Seconds install.sh may wait for "the job has a pid AND the heartbeat advanced". A cold start under
# launchd is seconds; a wrong REPO fails this and must NOT be reported as success.
START_TIMEOUT="${START_TIMEOUT:-45}"
REF="${HARNESS_REF:-origin/main}"
# How old $O/heartbeat may be before a LOADED job counts as "running but not cycling". install.sh derives
# the same bound from CYC (a quiet cell is not wedged); this is the caller-side default for status.
CYC="${CYC:-240}"
HB_STALE="${HB_STALE:-$(( CYC * 2 + 300 ))}"

case "$O" in *"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) echo "harness: \$O must not contain shell metacharacters: $O" >&2; exit 1 ;; esac
[ -d "$O" ] || { echo "harness: REFUSED: no harness at $O (O=$O) — nothing to inspect or deploy into" >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok: %s\n' "$*"; }
warn() { printf '  warn: %s\n' "$*" >&2; }
refuse()  { printf 'harness: REFUSED: %s\n' "$1" >&2; exit 1; }
unknown() { printf 'harness: CANNOT DETERMINE: %s\n' "$1" >&2; exit 2; }

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -u$/d'
}

# ── the launchd lifecycle seam ───────────────────────────────────────────────────────────────────
# ⛔ ONE implementation of enable/bootout/bootstrap and of the heartbeat arithmetic — sourced, never
# copied (install.sh makes the same choice and dies if the library is missing, #1975). Sourcing is
# side-effect free: launchd-cycle.sh defines functions only.
LC_LIB="$HERE/launchd-cycle.sh"
[ -f "$LC_LIB" ] || { [ -f "$O/launchd-cycle.sh" ] && LC_LIB="$O/launchd-cycle.sh"; }
[ -f "$LC_LIB" ] || refuse "missing launchd-cycle.sh next to this script and in $O — refusing to touch launchd without the safe lifecycle helper (#1975)"
# shellcheck source=launchd-cycle.sh
. "$LC_LIB"

# ── the checkout this harness is deployed FROM ──────────────────────────────────────────────────
# `--show-toplevel` is WORKTREE-aware: in a linked worktree it names that worktree, so `--ref HEAD`
# means the branch a lane is actually testing. (`git worktree list` names the MAIN worktree first, which
# is the right answer for "which repo is this a copy of" and the WRONG ref source: measured 2026-10-18,
# resolving HEAD there read the main checkout's commit, so a sandbox deploy of this branch was graded
# against a tree that does not contain it — "cannot read the harness tree at <main's tip>".)
# Empty when $HERE is not a checkout at all — the deployed $O, the measured #1745 laptop state.
GITROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$GITROOT" ] && [ -d "$GITROOT" ] || GITROOT=""
HARNESS_REL="$(git -C "$HERE" rev-parse --show-prefix 2>/dev/null || true)"; HARNESS_REL="${HARNESS_REL%/}"

# ── which label is OURS ─────────────────────────────────────────────────────────────────────────
# ⛔ THE LABEL IS A DATUM, NOT A GUESS. A hardcoded label is how the documented recovery command
# (`install.sh --restart`) came to target a job the box was not running: restarting the wrong label
# either does nothing (the operator believes the fleet was restarted) or starts a SECOND controller
# path beside the live one. So: ask launchd which of this account's eldato jobs has a plist that
# exec's something under $O. Exactly one → that is ours. Several → refuse and name them. None →
# fall back to the stack label and SAY SO.
label_plist_path() { # <label> — the plist path launchd loaded this job from, or empty
  local out
  out="$(lc_probe "$1")" || return 0
  awk '/^[[:space:]]*path = /{ sub(/^[[:space:]]*path = /, ""); print; exit }' <<<"$out"
}
label_program() { # <plist> — the executable path from ProgramArguments
  [ -f "$1" ] || return 0
  plutil -extract ProgramArguments.1 raw -o - "$1" 2>/dev/null || true
}
discover_label() {
  local l p prog found="" n=0
  for l in $(launchctl list 2>/dev/null | awk '{print $3}' | grep -E '^com\.eldato\.orchestrator' || true); do
    p="$(label_plist_path "$l")"
    [ -n "$p" ] || p="$HOME/Library/LaunchAgents/$l.plist"
    prog="$(label_program "$p")"
    case "$prog" in
      "$O"/*) found="$found $l"; n=$((n + 1)) ;;
    esac
  done
  if [ "$n" -eq 1 ]; then printf '%s' "${found# }"; return 0; fi
  if [ "$n" -gt 1 ]; then
    refuse "more than one loaded launchd job runs a program under $O (${found# }) — pin the one this box should run with LABEL=<label>; refusing to guess which stack to restart"
  fi
  return 1   # none found
}

if [ -n "$LABEL" ]; then
  LABEL_SOURCE=explicit
elif LABEL="$(discover_label)"; then
  LABEL_SOURCE=discovered
else
  LABEL="com.eldato.orchestrator-stack"
  LABEL_SOURCE=assumed
fi
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# The template travels WITH the label: a stack label rendered from the single-loop template would boot
# a supervisor job out and put a bare `orch-loop.sh` in its place (see launchd-stack.plist.template).
case "$LABEL" in
  *-stack) TEMPLATE="$HERE/launchd-stack.plist.template" ;;
  *)       TEMPLATE="$HERE/launchd.plist.template" ;;
esac

# ── reads ───────────────────────────────────────────────────────────────────────────────────────
# ⛔ A SUBSHELL WEARS ITS PARENT'S ARGV. `( … )` / `$( … )` inside orch-loop.sh appear in `ps` as
# `bash $O/orch-loop.sh` with the CONTROLLER as their ppid, so a pgrep count reads "2 controllers"
# while exactly one exists (measured 2026-10-18 13:26: pid 41679 the controller, plus a child that was
# its own subshell, plus that subshell's subshell — `bg/status.sh` printed `orch-loop-procs=2` for a
# single controller). The authoritative identity is the pid the controller RECORDS in `.orch.lock`,
# re-checked against the cmdline at the moment of use (a pid is not an identity — it can be reused).
# pgrep is the fallback for "the lock has not been written yet", and it is the only way to see a
# controller whose lock was removed while it kept running.
controller_pids() {
  local lp cmd
  lp="$(lock_pid)"
  if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
    cmd="$(ps -o command= -p "$lp" 2>/dev/null)" || cmd=""
    case "$cmd" in
      "bash $O/orch-loop.sh"|"/bin/bash $O/orch-loop.sh") printf '%s' "$lp"; return 0 ;;
    esac
  fi
  pgrep -f "bash $O/orch-loop.sh" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}
worker_pids() { # <worker name>
  pgrep -f "bash $O/bg/$1.sh" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}
lock_pid() { tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null || true; }

# ── drift ───────────────────────────────────────────────────────────────────────────────────────
# ⛔ THE BYTE COMPARISON IS NOT RE-IMPLEMENTED HERE (agent-infra#1745). check-deployed-drift.sh owns
# it: identity (the record install.sh writes), relation (recorded commit vs ref, recomputed live) and
# bytes (git blob sha per shipped file, both directions). It answers 0/1/2 and this verb passes that
# through unchanged, so `harness.sh drift` and the check can never disagree.
DRIFT_RC=2; DRIFT_TEXT=""
run_drift() { # [--all]
  local all="${1:-}" out rc nofetch="${HARNESS_NO_FETCH:-}"
  [ -n "$GITROOT" ] || { DRIFT_RC=2; DRIFT_TEXT="no checkout at $HERE — run from the repo to compare against it (the deployed $O is not a git tree, #1745)"; return 0; }
  # ⛔ A REF IS ONLY AS FRESH AS THE LAST FETCH: reading origin/main from a stale remote-tracking ref is
  # how a drifted box reads as MATCH. So the check fetches by default; HARNESS_NO_FETCH=1 is the
  # offline opt-out, and it is named rather than silent.
  out="$(bash "$HERE/check-deployed-drift.sh" --o "$O" --repo "$GITROOT" --ref "$REF" ${all:+--all} ${nofetch:+--no-fetch} 2>&1)"; rc=$?
  DRIFT_RC="$rc"; DRIFT_TEXT="$out"
  return 0
}
drift_word() { case "$1" in 0) printf MATCH ;; 1) printf DRIFT ;; *) printf UNKNOWN ;; esac; }
verdict_word() { case "$1" in 0) printf HEALTHY ;; 1) printf UNHEALTHY ;; *) printf 'CANNOT DETERMINE' ;; esac; }

cmd_drift() {
  local all=""
  [ "${1:-}" = "--all" ] && all="--all"
  run_drift "$all"
  printf '%s\n' "$DRIFT_TEXT"
  case "$DRIFT_RC" in
    0) say "drift: MATCH — $O matches $REF" ;;
    1) say "drift: DRIFT — $O does NOT match $REF (remedy: harness.sh restart)" ;;
    *) say "drift: UNKNOWN — could not verify (this is NOT a pass)" ;;
  esac
  exit "$DRIFT_RC"
}

# ── verify ─────────────────────────────────────────────────────────────────────────────────────
# Every datum is read, never assumed, and every read has three outcomes. RED beats UNKNOWN beats GREEN.
V_RED=0; V_UNK=0
red() { V_RED=$((V_RED + 1)); printf '  RED    %s\n' "$*"; }
unk() { V_UNK=$((V_UNK + 1)); printf '  UNKNOWN %s\n' "$*"; }
grn() { printf '  GREEN  %s\n' "$*"; }

gather_and_verify() {
  local prc blk pid age lp pids workers_missing="" w
  printf '== harness %s — %s\n' "$LABEL" "$(date '+%F %H:%M:%S')"

  # 1. the launchd job
  prc=0; blk=""; blk="$(lc_probe "$LABEL")" || prc=$?
  case "$prc" in
    1) red "$LABEL is NOT loaded — nothing is supervising this stack (remedy: harness.sh restart)" ;;
    2) unk "launchd's state for $LABEL could not be read (${blk:-no output}) — 'running' and 'not loaded' are both unproven" ;;
    *)
      pid="$(awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$blk")"
      if [ -n "$pid" ]; then grn "$LABEL loaded, pid $pid"
      else red "$LABEL is loaded but has NO pid — inside its respawn throttle, or crash-looping (remedy: harness.sh restart; then tail -40 $O/logs/stack.err)"; fi ;;
  esac

  # 2. the controller — alive is not cycling
  pids="$(controller_pids)"
  lp="$(lock_pid)"
  if [ -z "$pids" ]; then
    red "no controller process (bash $O/orch-loop.sh) is running — the stack is supervised but dispatching nothing"
  else
    grn "controller running (pid $pids)"
    case " $pids " in
      *" $lp "*) : ;;
      *) [ -n "$lp" ] && warn "the lock records pid $lp, which is not among the running controllers ($pids) — a reclaim is in flight, or the lock names a foreign pid" ;;
    esac
  fi
  age="$(lc_hb_age "$O")"
  case "$age" in
    '') unk "$O/heartbeat is missing or not a usable instant — 'cycling' is unproven (a missing heartbeat is NOT fresh)" ;;
    *)  if [ "$age" -le "$HB_STALE" ]; then grn "heartbeat ${age}s old (limit ${HB_STALE}s — written at the top of every cycle)"
        else red "heartbeat ${age}s old (limit ${HB_STALE}s) — the controller is ALIVE BUT NOT CYCLING; processes being up proves nothing here (remedy: harness.sh restart)"; fi ;;
  esac

  # 3. the workers the supervisor promises
  for w in digest watch-prs finish; do
    [ -f "$O/bg/$w.sh" ] || { workers_missing="$workers_missing $w"; continue; }
    pids="$(worker_pids "$w")"
    [ -n "$pids" ] && grn "worker $w running (pid $pids)" || red "worker $w is NOT running (supervisor should have it — check $O/logs/supervisor.log)"
  done
  if [ -n "$workers_missing" ]; then unk "cannot check worker(s)$workers_missing — $O/bg/<name>.sh is not deployed (the workers are NOT shipped in this repo: a $O rebuilt by deploy alone would have none)"; fi

  # 4. are the running bytes the repo's bytes?
  run_drift
  case "$DRIFT_RC" in
    0) grn "deployed bytes match $REF" ;;
    1) red "deployed bytes do NOT match $REF — the box runs older/different scripts than the repo ships:"; printf '%s\n' "$DRIFT_TEXT" | sed 's/^/         /' ;;
    *) unk "cannot compare the deployed bytes with $REF: $(printf '%s' "$DRIFT_TEXT" | head -1)" ;;
  esac

  printf -- '-- verdict: '
  if [ "$V_RED" -gt 0 ]; then printf 'UNHEALTHY (%d red, %d unknown)\n' "$V_RED" "$V_UNK"; return 1; fi
  if [ "$V_UNK" -gt 0 ]; then printf 'CANNOT DETERMINE (%d unknown)\n' "$V_UNK"; return 2; fi
  printf 'HEALTHY\n'; return 0
}

cmd_status() { gather_and_verify; exit $?; }
cmd_verify() { # machine-readable-ish: one verdict line per component, then the verdict
  gather_and_verify
  exit $?
}

# ── deploy ─────────────────────────────────────────────────────────────────────────────────────
# Mirror, not overlay: a script the harness no longer ships must not stay invocable in $O (the same
# rule orchestrator-bringup.sh applies). Atomic per file: stage next to the target, then rename, so a
# lane that spawns `bash $O/<worker>.sh` in the window never reads a half-written file.
DEPLOYED=0; REMOVED=0
# ⛔ PLAN, THEN APPLY — NEVER HALF A DEPLOY. The first version of this function copied file by file and
# discovered the orch-loop.sh hazard when it reached that file, so it had already replaced install.sh
# and four other scripts by the time it refused: a half-updated harness that no message describes, and
# exactly the "deploy ≠ copy-and-hope" defect this verb exists to remove. Every refusal now happens
# before the first `mv`.
PLAN_CHANGED=""; PLAN_REMOVE=""
deploy_plan() {
  [ -n "$GITROOT" ] || refuse "no checkout at $HERE — deploy must run from the repo, not from the deployed copy (the old raw 'cp -R' is exactly how $O drifted with no record)"
  local src f
  for src in "$HERE"/*.sh "$HERE"/*.template "$HERE"/port-provenance.txt; do
    [ -f "$src" ] || continue
    f="$(basename "$src")"
    if [ -f "$O/$f" ] && cmp -s "$src" "$O/$f"; then continue; fi
    PLAN_CHANGED="$PLAN_CHANGED $f"
  done
  # MIRROR, not overlay: a script the harness no longer ships must not stay invocable in $O (the same
  # rule orchestrator-bringup.sh applies). Removal is planned here and applied below.
  for f in "$O"/*.sh; do
    [ -f "$f" ] || continue
    [ -f "$HERE/$(basename "$f")" ] || PLAN_REMOVE="$PLAN_REMOVE $(basename "$f")"
  done
  # ⛔ THE ONE FILE THAT MUST NOT BE SWAPPED UNDER A RUNNING READER. bash reads a script INCREMENTALLY,
  # so replacing orch-loop.sh while the controller is executing it means the controller reads the NEW
  # bytes at its OLD offset — a silent mid-script corruption of the process that owns the fleet
  # (supervisor.sh's own rule #3: "never overwrite a running orch-loop.sh. Stop → copy → start").
  case " $PLAN_CHANGED " in
    *" orch-loop.sh "*)
      if [ -n "$(controller_pids)" ]; then
        refuse "refusing to deploy: $O/orch-loop.sh differs and a controller (pid $(controller_pids)) is executing it — bash reads scripts incrementally, so replacing it mid-run corrupts the process that owns the fleet. Nothing was written. Use: harness.sh restart (stop → deploy → start → verify)"
      fi ;;
  esac
  if [ -z "$PLAN_CHANGED" ] && [ -z "$PLAN_REMOVE" ]; then say "deploy: $O is already current (0 files differ)"; return 0; fi
  say "deploy plan: update${PLAN_CHANGED:- <none>} ; remove${PLAN_REMOVE:- <none>}"
  return 0
}
deploy_apply() {
  local f tmp
  for f in $PLAN_CHANGED; do
    tmp="$O/.seed-$f.$$"
    # Stage next to the target, then rename: a lane that spawns `bash $O/<worker>.sh` in the window
    # never reads a half-written file.
    cp -p "$HERE/$f" "$tmp" || { rm -f "$tmp"; refuse "cannot stage $f into $O — check free space (nothing else was written)"; }
    mv -f "$tmp" "$O/$f" || { rm -f "$tmp"; refuse "cannot install $f into $O"; }
    ok "deployed $f"; DEPLOYED=$((DEPLOYED + 1))
  done
  for f in $PLAN_REMOVE; do
    warn "removing $O/$f — the harness no longer ships it (a renamed or retired script must not stay invocable)"
    rm -f "$O/$f"; REMOVED=$((REMOVED + 1))
  done
  say "deploy: $DEPLOYED file(s) updated, $REMOVED removed"
}

# The provenance record + the plist render are install.sh's, not this script's: it already writes
# $O/.agent-infra-stamp.json (the record check-deployed-drift.sh reads) and refuses to render a plist
# with a surviving __TOKEN__. Called with ACTION=none, it mutates NO launchd state — that property is
# what makes it safe here and is asserted by install-launchd-durability.test.sh.
RENDER_REPO=""; RENDER_OR=""; RENDER_SCOPE=""
resolve_render_params() {
  local repo="${REPO:-}"
  # REPO is what the CONTROLLER targets. Take it from the live plist when the caller did not pass one,
  # so a restart cannot silently retarget the fleet at a different checkout.
  if [ -z "$repo" ] && [ -f "$PLIST" ]; then
    repo="$(plutil -extract EnvironmentVariables.REPO raw -o - "$PLIST" 2>/dev/null || true)"
  fi
  [ -n "$repo" ] || refuse "REPO is unset and $PLIST names none — pass REPO=<checkout> (the controller cannot start without it, exit 78)"
  [ -d "$repo" ] || refuse "REPO=$repo does not exist — this stack would crash-loop under KeepAlive"
  [ -f "$TEMPLATE" ] || refuse "missing template $TEMPLATE — refusing to render a job with no program definition"
  local or="${OR:-}"
  [ -n "$or" ] || or="$(plutil -extract EnvironmentVariables.OR raw -o - "$PLIST" 2>/dev/null || true)"
  [ -n "$or" ] || or="daniel-ospina/tortoise"
  local scope="${SCOPE:-}"
  [ -n "$scope" ] || scope="$(plutil -extract EnvironmentVariables.SCOPE raw -o - "$PLIST" 2>/dev/null || true)"
  [ -n "$scope" ] || scope="auto"
  RENDER_REPO="$repo"; RENDER_OR="$or"; RENDER_SCOPE="$scope"
}
run_install() { # [--restart]
  # ⛔ THE START IS install.sh's --restart, NOT a second `lc_restart` call from here. install.sh already
  # owns render → validate → stamp → lc_restart (pid + heartbeat advance + not-relaunching), AND it
  # records `$O/state/launchd-loaded.sha256` — the "which render did launchd load" datum the NEXT run
  # compares against. Calling lc_restart directly got the same start with that record missing, so the
  # next `install.sh --start` would report the loaded render as UNKNOWN and reload a healthy job.
  local action="${1:-}" repo="$RENDER_REPO" or="$RENDER_OR" scope="$RENDER_SCOPE"
  say "==> installing $PLIST from $(basename "$TEMPLATE")${action:+ $action} (label $LABEL, REPO=$repo, OR=$or, SCOPE=$scope)"
  env -i HOME="$HOME" PATH="$PATH" \
    O="$O" REPO="$repo" OR="$or" SCOPE="$scope" LABEL="$LABEL" TEMPLATE="$TEMPLATE" CYC="$CYC" \
    START_TIMEOUT="$START_TIMEOUT" ${LC_HB_STALE:+LC_HB_STALE="$LC_HB_STALE"} \
    bash "$HERE/install.sh" $action \
    || refuse "install.sh${action:+ --restart} failed (its own output above says why: a render problem, or a start that could not be PROVEN) — this is NOT a successful ${action:+restart}${action:-install}"
  # ⛔ A RENDER THAT WROTE NO RECORD IS NOT A DEPLOY. check-deployed-drift.sh answers UNKNOWN without
  # this file, which is the state the live box was in: the deployed installer was 10 lines stale and
  # NOTHING could say so.
  [ -f "$O/.agent-infra-stamp.json" ] || refuse "install.sh reported success but wrote no provenance record at $O/.agent-infra-stamp.json — the deploy cannot be verified, so it is not a pass"
  ok "provenance recorded at $O/.agent-infra-stamp.json"
}

cmd_deploy() {
  resolve_render_params
  deploy_plan
  deploy_apply
  run_install
  run_drift
  say "deploy: drift after deploy = $(drift_word "$DRIFT_RC")"
  [ "$DRIFT_RC" -eq 0 ] || { printf '%s\n' "$DRIFT_TEXT" | sed 's/^/  /' >&2
    [ "$DRIFT_RC" -eq 2 ] && unknown "the deployed copy cannot be compared with $REF (see above) — not a pass"
    refuse "the deployed copy still does not match $REF after deploy (see above) — most often the checkout is DIRTY vs $REF; deploy the committed bytes (git stash / use HARNESS_REF=<branch>) rather than hand-copied ones"; }
  say "deploy: OK — $O matches $REF"
  exit 0
}

# ── stop ──────────────────────────────────────────────────────────────────────────────────────
# Kill nothing you have not identified. A pid read out of a state file is a CACHE of a past state and
# can belong to any process after a reboot (pid reuse); the cmdline is re-read at the moment of action.
stop_identified() { # <pattern...> — signal only pids whose cmdline matches
  local pat="$1" pid cmd i pids rc=0
  pids="$(pgrep -f "$pat" 2>/dev/null || true)"
  for pid in $pids; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || continue
    # ⛔ THE CMDLINE, RE-READ AT THE MOMENT OF ACTION. pgrep matched a regex; this decides whether the
    # process is one of THIS deployment's scripts by name, so a pid reused after a reboot (or a lane
    # running another repo's controller) is never signalled.
    case "$cmd" in
      bash\ "$O"/*|/bin/bash\ "$O"/*) ;;
      *) warn "REFUSED to signal pid $pid — its command is not one of ours ('$cmd')"; continue ;;
    esac
    log_stop "$pid" "$cmd"
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then warn "pid $pid ignored TERM for 30s — sending KILL"; kill -KILL "$pid" 2>/dev/null || true; sleep 1; fi
    kill -0 "$pid" 2>/dev/null && { warn "pid $pid is STILL alive after KILL — not continuing as if it stopped"; rc=1; }
  done
  return "$rc"
}
log_stop() { say "  stopping pid $1 ($2)"; }

cmd_stop() {
  local prc=0 blk
  # 1. the launchd job first, or it relaunches what we are about to stop (KeepAlive).
  blk=""; blk="$(lc_probe "$LABEL")" || prc=$?
  case "$prc" in
    0) say "==> booting out $LABEL"
       lc_bootout "$LABEL" "$PLIST" || refuse "could not boot out $LABEL — nothing was stopped, and stopping the controller under a live KeepAlive job would only make launchd respawn it"
       prc=0; blk=""; blk="$(lc_probe "$LABEL")" || prc=$?
       [ "$prc" -eq 1 ] || refuse "launchd still holds $LABEL after bootout — refusing to continue (a supervisor that comes back mid-restart would start a second controller)";;
    1) say "==> $LABEL is not loaded — nothing to boot out";;
    *) refuse "launchd's state for $LABEL could not be read (${blk:-no output}) — refusing to stop anything on an unproven 'not loaded'";;
  esac
  # 2. the processes the job supervised (bootout kills the supervisor; its nohup'd children survive).
  stop_identified "bash $O/orch-loop.sh" || refuse "the controller did not stop — refusing to continue"
  local w
  for w in digest watch-prs finish; do
    stop_identified "bash $O/bg/$w.sh" || warn "worker $w did not stop"
  done
  # 3. the lock, only once its owner is verifiably gone.
  if [ -f "$O/.orch.lock" ]; then
    if kill -0 "$(lock_pid)" 2>/dev/null; then warn "$O/.orch.lock names a LIVE pid $(lock_pid) — left in place; the next start will refuse rather than manufacture a restart storm"
    else rm -f "$O/.orch.lock"; say "  cleared the stale lock ($O/.orch.lock)"; fi
  fi
  say "stop: OK"
  exit 0
}

# ── restart ──────────────────────────────────────────────────────────────────────────────────
cmd_restart() {
  # ⛔ EVERY REFUSAL THAT CAN BE MADE BEFORE THE STOP IS MADE BEFORE THE STOP. Measured in review of the
  # first draft: `restart` booted the stack out, stopped the controller and only THEN reached
  # deploy_plan, which refuses when $HERE is not a checkout — leaving the fleet down on an error that was
  # knowable at argv time. A restart that can fail must fail while everything is still running.
  [ -n "$GITROOT" ] || refuse "no checkout at $HERE — restart must run from the repo (deploy has nothing to deploy from a deployed copy). Nothing was stopped."
  resolve_render_params   # read-only: refuse a bad REPO/TEMPLATE BEFORE stopping anything
  say "==> restarting the harness as one act: stop → deploy → render → start → verify"
  say "    O=$O label=$LABEL ($LABEL_SOURCE)$([ -n "$GITROOT" ] && printf ' repo=%s' "$GITROOT") ref=$REF"
  # stop is a function that exits, so run the stop half in a subshell-free way: inline the same steps.
  local prc=0 blk w
  blk=""; blk="$(lc_probe "$LABEL")" || prc=$?
  case "$prc" in
    0) say "==> booting out $LABEL"
       lc_bootout "$LABEL" "$PLIST" || refuse "could not boot out $LABEL — nothing was changed (a partial restart is how a box ends up with two controllers)"
       prc=0; blk=""; blk="$(lc_probe "$LABEL")" || prc=$?
       [ "$prc" -eq 1 ] || refuse "launchd still holds $LABEL after bootout — refusing to deploy under a job that may come back";;
    1) say "==> $LABEL is not loaded — nothing to boot out";;
    *) refuse "launchd's state for $LABEL could not be read (${blk:-no output}) — refusing to restart on an unproven state";;
  esac
  stop_identified "bash $O/orch-loop.sh" || refuse "the controller did not stop — refusing to overwrite a script a running bash is reading"
  for w in digest watch-prs finish; do stop_identified "bash $O/bg/$w.sh" || warn "worker $w did not stop"; done
  [ -f "$O/.orch.lock" ] && { if kill -0 "$(lock_pid)" 2>/dev/null; then refuse "$O/.orch.lock names a LIVE pid $(lock_pid) that is not this stack's controller — refusing to start a second one beside it"; else rm -f "$O/.orch.lock"; say "  cleared the stale lock"; fi; }

  deploy_plan
  deploy_apply
  # install.sh --restart: render → validate → stamp → enable → bootout → bootstrap → PROVE (pid, new
  # process, heartbeat advanced, not relaunching) → record the loaded render. Non-zero exits here.
  run_install --restart

  # ⛔ THE POST-RESTART CHECK IS THE POINT OF THE WHOLE VERB. A restart that reports success because
  # the *launchctl* calls returned 0 is the false PASS this repo has paid for twice (#1975: installer
  # exited 0 with the controller removed and disabled). The verdict comes from reading the stack back.
  say ""
  say "==> verifying the stack as configured"
  gather_and_verify
  local v=$?
  say ""
  say "restart: done — verify verdict $(verdict_word "$v")"
  exit "$v"
}

# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  status)  cmd_status ;;
  verify)  cmd_verify ;;
  drift)   shift; cmd_drift "${1:-}" ;;
  deploy)  cmd_deploy ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  -h|--help|help) usage; exit 0 ;;
  '')      usage; exit 2 ;;
  *)       printf 'harness: unknown verb %s\n\n' "$1" >&2; usage; exit 2 ;;
esac
