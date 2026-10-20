#!/usr/bin/env bash
# deploy-mac-orchestrator.sh — put the VERSIONED agent-infra harness onto this Mac's
# live ~/orchestrator runtime, and bring the cross-box claim registry up for the first time.
#
# Why it is staged (two phases) rather than one atomic swap:
#   bash reads a script incrementally, so an IN-PLACE overwrite (`cp over` truncates the same inode)
#   while pid N is executing it can run mixed content (half old, half new). The fix is ATOMIC:
#   write a temp file in the same directory and `mv` it over the target, which gives the target a
#   NEW inode — a running bash keeps reading its old inode through its open fd, so nothing is ever
#   half-read. Every file is installed that way, in BOTH phases.
#   NOT a reason to wait, and this file previously said so wrongly: "killing the controller kills
#   the lane-* sessions under it, which hold UNCOMMITTED work" is FALSE. The controller's only trap
#   is `rm -f "$LOCKF"` (orch-loop.sh:340), and workers are spawned as `tmux new-session -d -s
#   "merge-$PR" "bash '$O/merge-one.sh' …"` — children of the TMUX SERVER, not of the controller.
#   Killing the controller therefore leaves every in-flight worker running; that false premise made
#   phase B wait for a zero-in-flight moment on a Mac that merges ~39 PRs/12h and so deferred it
#   three times (~2.5h of waiting) without protecting anything. `WAIT=1` is now OPT-IN.
#
# Usage:  bash deploy-mac-orchestrator.sh            # A now, B now (atomic swap + restart)
#         PHASE=A bash deploy-mac-orchestrator.sh    # A only
#         WAIT=1  bash deploy-mac-orchestrator.sh    # ALSO wait for a zero-in-flight moment first
#                                                    # (preference, never a safety requirement)
set -uo pipefail

AI_MAIN="${AI_MAIN:-$HOME/Documents/GitHub/agent-infra}"
SRC_REF="${SRC_REF:-origin/main}"
O="${O:-$HOME/orchestrator}"
PHASE="${PHASE:-AB}"
WAIT="${WAIT:-0}"
PATIENCE="${PATIENCE:-2400}"     # seconds to wait for a quiet moment before giving up on B
STAGE="${STAGE:-/tmp/harness-main.$$}"
# ⛔ REPO IS REQUIRED AND IS NOT DEFAULTED (agent-infra#1935) — but only when this run includes
# phase B, which RELAUNCHES the controller. An unset REPO would leave a controller that exits 78 on
# its own guard, and this script's verification would report `after: 0 scoped match(es)` over a
# stopped runtime instead of naming the cause. Refuse BEFORE anything is stopped or copied, so a bad
# deploy leaves the box as it found it. A hardcoded path is not an option: that is the defect this
# guard removes. (PHASE=A only copies files and touches no controller, so it does not need REPO.)
case "$PHASE" in *B*)
  REPO="${REPO:-}"
  [ -n "$REPO" ] || { echo "deploy-mac-orchestrator: FATAL REPO is not set — export REPO=<the target repo's local checkout> (needed because phase B relaunches the controller)" >&2; exit 78; }
  [ -d "$REPO" ] || { echo "deploy-mac-orchestrator: FATAL REPO=$REPO does not exist" >&2; exit 78; }
  # No `export REPO` is needed for the relaunch below: REPO can only get past the guard by ARRIVING
  # in the environment (a value set without `export` never reaches this script), so it is already
  # exported and `nohup bash "$O/orch-loop.sh"` inherits it.
  ;;
esac

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

inflight() { tmux ls 2>/dev/null | grep -cE '^(merge|fix)-'; }
# ⛔ SCOPED to THIS runtime's controller. An unscoped `pgrep -f '[o]rch-loop\.sh'` matches every
# controller-shaped process on the box — measured 2026-10-15 it matched FOUR: this Mac's real
# controller, a leaked 2h-old test fixture running `bash ./orch-loop.sh` in a temp dir, and two
# fixtures of a PEER LANE's test that was running at that moment. An unscoped kill would have taken
# out a peer lane's test. A destructive verb must be scoped to its own target.
controller_pids() { pgrep -f "[b]ash $O/orch-loop\.sh" 2>/dev/null; }
# The runtime names its OWN controller: orch-loop.sh writes its $$ into $O/.orch.lock (acq(), with
# noclobber) and a second launch EXITS immediately while that pid is alive. So the lock is the
# authoritative, SINGULAR handle on this runtime's controller, whereas a `pgrep` POPULATION is
# merely a sample of the box — and this box carries peer lanes' fixtures (measured 2026-10-15: a
# transient `bash $O/orch-loop.sh` appeared inside the scope between the pre-check and the stop,
# because a peer fixture launched the real path and exited at once on the lock).
# Prints the pid only when the lock names a LIVE process that really is this runtime's controller.
lock_pid() { # -> pid on stdout, empty when there is no usable lock
  local p
  p="$(tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null)"
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  ps -o command= -p "$p" 2>/dev/null | grep -q "bash $O/orch-loop\.sh" || return 0
  printf '%s\n' "$p"
}
# Atomic install: temp file in the SAME directory, then rename (new inode). A running bash keeps
# reading its old inode, so a swap can never be read half-old/half-new — the property that makes
# phase A and phase B safe at ANY time, in-flight work or not.
install_file() { # install_file <src> <dst>
  local s="$1" d="$2" t
  t="$(dirname "$d")/.$(basename "$d").new.$$"
  cp "$s" "$t" && mv -f "$t" "$d"
}

log "=== deploy Mac orchestrator: $SRC_REF -> $O (phase $PHASE) ==="

# ---- 0. fetch and stage the harness from the truthful ref, not the working tree --------
git -C "$AI_MAIN" fetch -q origin main 2>/dev/null || true
REV="$(git -C "$AI_MAIN" rev-parse --short "$SRC_REF" 2>/dev/null)"
[ -n "$REV" ] || { log "FATAL: cannot resolve $SRC_REF in $AI_MAIN"; exit 1; }
rm -rf "$STAGE"; mkdir -p "$STAGE"
git -C "$AI_MAIN" archive "$SRC_REF" scripts/orchestrator-harness | tar -x -C "$STAGE" || {
  log "FATAL: could not extract the harness from $SRC_REF"; exit 1; }
H="$STAGE/scripts/orchestrator-harness"
[ -f "$H/claims.sh" ] || { log "FATAL: $SRC_REF has no claims.sh — refusing to deploy"; exit 1; }
[ -f "$H/orch-loop.sh" ] || { log "FATAL: $SRC_REF has no orch-loop.sh"; exit 1; }
log "staged $REV: $(ls "$H" | wc -l | tr -d ' ') entries"
log "  claims.sh $(wc -c < "$H/claims.sh" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$H/claims.sh" | cut -c1-16)"

# ---- 1. record what we are replacing, so the change is auditable -----------------------
log "before: $(controller_pids | wc -l | tr -d ' ') controller pid(s), $(inflight) in-flight lane/merge session(s)"
log "before: $O/claims.sh $([ -f "$O/claims.sh" ] && echo present || echo ABSENT)"

# ---- 2. Phase A: copy everything but orch-loop.sh (atomically) -------------------------
# Runtime state (candidates.txt, checked.txt, dispatched.txt, state/, logs/, wip/,
# merged-not-closed.sh) is NOT in the harness, so it is never touched. merged-not-closed.sh
# is a Mac-only script the agent-infra harness does not carry — deliberately preserved.
for f in "$H"/*; do
  b="$(basename "$f")"
  [ "$b" = "orch-loop.sh" ] && continue
  if [ -d "$f" ]; then cp -R "$f" "$O/"; else install_file "$f" "$O/$b"; fi
done
log "phase A: copied $(ls "$H" | grep -vc '^orch-loop.sh$') entries"
[ -f "$O/claims.sh" ] || { log "FATAL: claims.sh did not land in $O"; exit 1; }
cmp -s "$H/claims.sh" "$O/claims.sh" || { log "FATAL: $O/claims.sh differs from $SRC_REF"; exit 1; }
log "phase A VERIFIED: $O/claims.sh matches $SRC_REF ($(wc -c < "$O/claims.sh" | tr -d ' ') bytes)"
log "phase A NOTE: merge/fix workers spawned from now on acquire cross-box claims;"
log "               the controller itself still lacks the snapshot/restart half."

[ "$PHASE" = "A" ] && { log "DONE (phase A only)"; rm -rf "$STAGE"; exit 0; }

# ---- 3. Phase B: OPTIONAL preference wait for a quiet moment (WAIT=1) ------------------
# Not a safety requirement any more: the swap below is atomic and the controller's exit does not
# touch workers. Kept only as a preference for operators who dislike a mid-iteration restart.
if [ "$WAIT" = "1" ]; then
  t0=$SECONDS
  while :; do
    n="$(inflight)"
    [ "$n" = "0" ] && { log "phase B: quiet after $((SECONDS-t0))s"; break; }
    if [ $((SECONDS-t0)) -ge "$PATIENCE" ]; then
      log "phase B DEFERRED: still $n in-flight after ${PATIENCE}s — not restarting."
      log "  Phase A is live and correct; the control half waits for a quiet moment."
      log "  Re-run with: bash $0        (phase A is idempotent)"
      rm -rf "$STAGE"; exit 0
    fi
    [ $(( (SECONDS-t0) % 120 )) -lt 20 ] && log "phase B: waiting — $n in-flight, $((SECONDS-t0))s elapsed"
    sleep 20
  done
fi

# ---- 4. Phase B: swap orch-loop.sh (atomic), restart, verify ---------------------------
install_file "$H/orch-loop.sh" "$O/orch-loop.sh"
log "phase B: orch-loop.sh replaced (atomic rename; inode now $(ls -i "$O/orch-loop.sh" | awk '{print $1}'))"

OLDPID="$(lock_pid)"
if [ -n "$OLDPID" ]; then
  log "stopping the controller the runtime itself names: pid $OLDPID (from $O/.orch.lock)"
  kill "$OLDPID" 2>/dev/null || true
  for _ in $(seq 1 15); do sleep 1; kill -0 "$OLDPID" 2>/dev/null || break; done
  # Fallback is the SAME scoped pid — never a bare `pkill -f '[o]rch-loop\.sh'`. bash runs a trap
  # only AFTER the current foreground command returns, so a TERM sent while the loop is inside a
  # slow call is handled late; that lateness must not become a licence to signal unrelated procs.
  if kill -0 "$OLDPID" 2>/dev/null; then
    log "fallback: TERM did not clear pid $OLDPID within 15s — KILLing that scoped pid only"
    kill -9 "$OLDPID" 2>/dev/null || true
    sleep 2
  fi
else
  # No usable lock. Fall back to the scoped population — and refuse an AMBIGUOUS one: a scope that
  # matches more than one process is not a scope we may signal. Measured 2026-10-15: an unscoped
  # `pkill -f '[o]rch-loop\.sh'` matches a peer lane's live test fixture running `bash
  # ./orch-loop.sh` from a temp dir, so it would kill a peer's test mid-run. Killing a controller
  # is cheap; killing someone else's work is not. If the target is ambiguous: report, do not reap.
  PIDS="$(controller_pids)"
  NPIDS="$(printf '%s\n' "$PIDS" | grep -c .)"
  log "no usable lock — scoped pgrep matched [$NPIDS]: $(echo $PIDS | tr '\n' ' ')"
  if [ "$NPIDS" -gt 1 ]; then
    log "FATAL: $NPIDS processes match the controller scope and no lock names one — refusing to signal an ambiguous target"
    pgrep -fl "[b]ash $O/orch-loop\.sh" | cut -c1-140
    rm -rf "$STAGE"; exit 1
  fi
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
  for _ in $(seq 1 15); do sleep 1; [ -z "$(controller_pids)" ] && break; done
  # -9 the SAME pids we TERMed, re-checked alive — the rule the lock branch above already follows by
  # reusing $OLDPID. Re-reading the population here would signal whatever appeared in the window
  # instead: this file measures that a transient `bash $O/orch-loop.sh` (a peer fixture launching the
  # real path) can appear inside the scope and exit at once, and signalling it is the failure this
  # branch exists to avoid. The COUNT was asserted above; this keeps the TARGETS the ones asserted.
  # Deliberate consequence, stated: if the captured pid exits inside this window AND a different
  # scoped process is alive at the kill point, that process is NOT signalled — a survivor is reported
  # at the verification step below ("the scope also names [...] — not signalled") and left to the
  # lock, because reaping an unasserted target is the failure this branch exists to avoid.
  _stopped=""
  for _p in $PIDS; do
    if kill -0 "$_p" 2>/dev/null; then kill -9 "$_p" 2>/dev/null || true; _stopped="$_stopped $_p"; fi
  done
  if [ -n "$_stopped" ]; then
    log "fallback: TERM did not clear the scoped controller within 15s — KILLed the captured pid(s) only:$_stopped"
    sleep 2
  fi
fi
rm -f "$O/.orch.lock"
log "controller stopped"

# Relaunch with the SAME command the live controller was started with (captured from
# ps at deploy time): cd $HOME, fixed PATH, nohup into logs/nohup.out.
# PATH for the relaunched controller, probed in THIS shell — the same idea as install.sh's
# `__PATH__` render (`install.sh` probes the same tools, plus `jq`), and the reason there is no
# /Users/<someone>/... literal here any more: a hardcoded home is the landmine class this file's
# REPO guard removes (#1935).
# ⛔ Same REFUSAL as install.sh: a directory under `.pi/` or a `shims` directory is skipped, because a
# shim silently substitutes a different `gh`/`pi` than the one the operator means. (install.sh refuses
# the class for a measured reason: macOS TCC makes such a symlink EPERM under launchd.)
DEPLOY_PATH=""
# Scan PATH ENTRIES and test for an executable file, rather than `command -v` + `dirname`: `command -v`
# reports an exported shell FUNCTION by bare name, so `dirname` would bake `.` into the relaunched
# controller's PATH (install.sh calls that trap (2), `install.sh:157-159`). Scanning the entries also
# keeps a tool findable when its first PATH directory is a refused shim (this box's `gh` is
# `~/.pi/agent/shims/gh`): the refusal drops the DIRECTORY, and the next entry that really owns the
# binary wins — which is what install.sh's resolve-past-a-wrapper loop achieves.
# keeps a tool findable when one of its PATH directories is a refused shim (this box has a `gh` shim
# at `~/.pi/agent/shims/gh`, behind the real `~/bin/gh`): the refusal drops the DIRECTORY, and the next
# entry that really owns the binary wins — the same outcome install.sh's resolve-past-a-wrapper loop
# reaches.
# ⛔ `set -f` for the scan: a PATH entry containing `*` would otherwise be GLOB-EXPANDED into a
# directory that is not on PATH at all (install.sh documents the same trap). And each entry is
# resolved to its PHYSICAL path before the refusal test, because a symlink pointing INTO a shim
# directory passes a name-pattern check while resolving to the shim.
_oldIFS="$IFS"; IFS=:; set -f
for _t in pi tmux gh uv cmux; do
  for _d in $PATH; do
    case "$_d" in ""|.) continue ;; esac
    _rd="$(cd "$_d" 2>/dev/null && pwd -P)" || continue
    case "$_rd" in */.pi/*|*/shims|*/shims/*) continue ;; esac
    [ -x "$_rd/$_t" ] || continue
    case ":$DEPLOY_PATH:" in *":$_rd:"*) ;; *) DEPLOY_PATH="${DEPLOY_PATH:+$DEPLOY_PATH:}$_rd" ;; esac
    break
  done
done
set +f; IFS="$_oldIFS"
for _d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$_d" ] || continue
  case ":$DEPLOY_PATH:" in *":$_d:"*) ;; *) DEPLOY_PATH="${DEPLOY_PATH:+$DEPLOY_PATH:}$_d" ;; esac
done
# ⛔ The fallback list above does NOT contain the pi install on this box: `~/.local/bin/pi` does not
# exist, `~/.local/share/pi-node/current/bin/pi` does. Without this, a deploy run from a bare PATH
# relaunches a controller that cannot spawn a lane. install.sh:185-188 closes the same hole the same
# way (prefer the version-independent `current` symlink).
if [ -x "$HOME/.local/share/pi-node/current/bin/pi" ]; then
  case ":$DEPLOY_PATH:" in *":$HOME/.local/share/pi-node/current/bin:"*) ;; *)
    DEPLOY_PATH="${DEPLOY_PATH:+$DEPLOY_PATH:}$HOME/.local/share/pi-node/current/bin" ;; esac
fi
# ⛔ cmux LIVES IN AN APP BUNDLE, NOT ON ANY PATH ENTRY THE SCAN ABOVE CAN SEE. The relaunched
# controller's collision pre-flight reads lane liveness through `cmux sessions list` (tortoise's
# `fleet_state.live_sessions()`); with cmux unreachable `liveness_measured` is False, the board
# carries `orphans[kind=liveness-unmeasured]`, and the pre-flight marks EVERY candidate INCOMPLETE —
# the refresh then aborts by design (#1736) and the backlog drains to 0 while 203 issues sit open
# (measured 2026-10-18). The scan above only inspects $PATH entries, and an install/relaunch run from
# a non-login shell has no cmux there at all. Appended, never prepended: that directory also holds
# `open`/`ghostty`, so prepending would shadow /usr/bin/open for every lane.
for _d in /Applications/cmux.app/Contents/Resources/bin \
          "$HOME/Applications/cmux.app/Contents/Resources/bin"; do
  [ -x "$_d/cmux" ] || continue
  case ":$DEPLOY_PATH:" in *":$_d:"*) ;; *) DEPLOY_PATH="${DEPLOY_PATH:+$DEPLOY_PATH:}$_d" ;; esac
done
[ -n "$DEPLOY_PATH" ] || DEPLOY_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
log "relaunch PATH: $DEPLOY_PATH"
cd "$HOME" || exit 1
PATH="$DEPLOY_PATH" \
  nohup bash "$O/orch-loop.sh" >> "$O/logs/nohup.out" 2>&1 &
sleep 8

N="$(controller_pids | wc -l | tr -d ' ')"
P="$(lock_pid)"
log "after: $N scoped match(es); the lock names: ${P:-none} (old=${OLDPID:-none})"
# The identity that decides is the LOCK, not the population: orch-loop.sh's acq() makes the lock
# singular by construction (a second launch EXITS on it), while a peer fixture launching the real
# path shows up in the population for milliseconds. So: fail when the lock is absent or still names
# the OLD pid; merely NAME any extra scoped match, and never signal it.
if [ -z "$P" ]; then
  log "FATAL: no controller holds $O/.orch.lock after the restart"
  pgrep -fl "[b]ash $O/orch-loop\.sh" | cut -c1-140
  rm -rf "$STAGE"; exit 1
fi
if [ "$P" = "${OLDPID:-}" ]; then
  log "FATAL: the lock still names the OLD pid $P — the restart did not take"
  rm -rf "$STAGE"; exit 1
fi
EXTRA="$(controller_pids | grep -vx "$P" | tr '\n' ' ')"
[ -n "${EXTRA// /}" ] && log "WARN: the scope also names [$EXTRA] — not signalled (a second launch exits on the lock; treat as a peer fixture)"
log "VERIFIED: controller pid=$P (new inode) holds $O/.orch.lock and runs $O/orch-loop.sh"
log "  registry wiring in the live loop: $(grep -c 'refs/claims' "$O/orch-loop.sh") ref(s)"
log "  claims.sh present: $([ -f "$O/claims.sh" ] && echo yes || echo NO)"
log "  snapshot path: $O/state/claims-snapshot"
rm -rf "$STAGE"
log "DONE — Mac runtime is on $REV with the cross-box claim registry active"
