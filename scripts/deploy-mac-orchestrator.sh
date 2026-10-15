#!/usr/bin/env bash
# deploy-mac-orchestrator.sh — put the VERSIONED agent-infra harness onto this Mac's
# live ~/orchestrator runtime, and bring the cross-box claim registry up for the first time.
#
# Why it is staged (two phases) rather than one atomic swap:
#   bash reads a script incrementally, so overwriting orch-loop.sh while pid N is executing
#   it can run mixed content (half old, half new). And killing the controller kills the
#   lane-* sessions under it, which hold UNCOMMITTED work. So:
#     Phase A (immediate, safe) — copy everything EXCEPT orch-loop.sh. Every worker script is
#       re-read from disk at spawn time, so new merge/fix workers pick up claims.sh at once.
#       This is what activates cross-box claiming, and it activates it WITHOUT a restart.
#     Phase B (when quiet)      — copy orch-loop.sh, restart the controller, verify.
#   Waiting costs nothing and loses no work; skipping the wait can.
#
# Usage:  bash deploy-mac-orchestrator.sh            # A now, B when quiet
#         PHASE=A bash deploy-mac-orchestrator.sh    # A only
#         WAIT=0  bash deploy-mac-orchestrator.sh    # don't wait for quiet (still restarts)
set -uo pipefail

AI_MAIN="${AI_MAIN:-$HOME/Documents/GitHub/agent-infra}"
SRC_REF="${SRC_REF:-origin/main}"
O="${O:-$HOME/orchestrator}"
PHASE="${PHASE:-AB}"
WAIT="${WAIT:-1}"
PATIENCE="${PATIENCE:-2400}"     # seconds to wait for a quiet moment before giving up on B
STAGE="${STAGE:-/tmp/harness-main.$$}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

inflight() { tmux ls 2>/dev/null | grep -cE '^(merge|fix)-'; }
controller_pids() { pgrep -f '[o]rch-loop\.sh' 2>/dev/null; }

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

# ---- 2. Phase A: copy everything but orch-loop.sh --------------------------------------
# Runtime state (candidates.txt, checked.txt, dispatched.txt, state/, logs/, wip/,
# merged-not-closed.sh) is NOT in the harness, so it is never touched. merged-not-closed.sh
# is a Mac-only script the agent-infra harness does not carry — deliberately preserved.
for f in "$H"/*; do
  b="$(basename "$f")"
  [ "$b" = "orch-loop.sh" ] && continue
  if [ -d "$f" ]; then cp -R "$f" "$O/"; else cp "$f" "$O/"; fi
done
log "phase A: copied $(ls "$H" | grep -vc '^orch-loop.sh$') entries"
[ -f "$O/claims.sh" ] || { log "FATAL: claims.sh did not land in $O"; exit 1; }
cmp -s "$H/claims.sh" "$O/claims.sh" || { log "FATAL: $O/claims.sh differs from $SRC_REF"; exit 1; }
log "phase A VERIFIED: $O/claims.sh matches $SRC_REF ($(wc -c < "$O/claims.sh" | tr -d ' ') bytes)"
log "phase A NOTE: merge/fix workers spawned from now on acquire cross-box claims;"
log "               the controller itself still lacks the snapshot/restart half."

[ "$PHASE" = "A" ] && { log "DONE (phase A only)"; rm -rf "$STAGE"; exit 0; }

# ---- 3. Phase B: wait for a quiet moment ----------------------------------------------
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

# ---- 4. Phase B: swap orch-loop.sh, restart, verify ------------------------------------
cp "$H/orch-loop.sh" "$O/orch-loop.sh"
log "phase B: orch-loop.sh replaced ($(shasum -a 256 "$O/orch-loop.sh" | cut -c1-16))"

PIDS="$(controller_pids)"
log "stopping controller pid(s): $(echo $PIDS | tr '\n' ' ')"
[ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
for _ in $(seq 1 15); do sleep 1; [ -z "$(controller_pids)" ] && break; done
[ -n "$(controller_pids)" ] && { pkill -f '[o]rch-loop\.sh' 2>/dev/null || true; sleep 2; }
rm -f "$O/.orch.lock"
log "controller stopped ($(controller_pids | wc -l | tr -d ' ') remaining)"

# Relaunch with the SAME command the live controller was started with (captured from
# ps at deploy time): cd $HOME, fixed PATH, nohup into logs/nohup.out.
cd "$HOME" || exit 1
PATH="/Users/danielospina/.local/bin:/Users/danielospina/.local/share/pi-node/current/bin:/opt/homebrew/bin:/Users/danielospina/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  nohup bash "$O/orch-loop.sh" >> "$O/logs/nohup.out" 2>&1 &
sleep 8

N="$(controller_pids | wc -l | tr -d ' ')"
log "after: $N controller pid(s)"
if [ "$N" != "1" ]; then
  log "FATAL: expected exactly 1 controller, found $N"
  pgrep -fl '[o]rch-loop\.sh' | cut -c1-140
  rm -rf "$STAGE"; exit 1
fi
P="$(controller_pids | head -1)"
log "VERIFIED: controller pid=$P running $O/orch-loop.sh"
log "  registry wiring in the live loop: $(grep -c 'refs/claims' "$O/orch-loop.sh") ref(s)"
log "  claims.sh present: $([ -f "$O/claims.sh" ] && echo yes || echo NO)"
log "  snapshot path: $O/state/claims-snapshot"
rm -rf "$STAGE"
log "DONE — Mac runtime is on $REV with the cross-box claim registry active"
