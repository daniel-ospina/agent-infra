#!/bin/bash
# deploy-crossbox.sh — put the reviewed harness (with the cross-box claim registry) onto a cell.
#
# Runs ON THE CELL (Linux). Pushed and invoked by the orchestrator.
#
# WHY THE PATH-SCOPED CHECKOUT. The cell's clone of agent-infra is also the repo the
# controller operates on, so it must stay on main. `git checkout <ref> -- <path>` moves
# ONLY the harness subtree, leaving the rest of the tree (and HEAD) alone.
#
# WHY ALL *.sh ARE RE-SEEDED. The registry lives in a NEW file (claims.sh). `orch-loop.sh`
# and `merge-one.sh` source it from $O and gate on `[ -f "$O/claims.sh" ]`, so a partial
# deploy would silently leave the registry OFF (fail-open) rather than error. README §4.
#
# WHY THE CONTROLLER IS STOPPED FIRST. `cp` over a script that bash is mid-read from can
# execute mixed content — the running loop holds orch-loop.sh open.
set -uo pipefail

BR="${BR:-}"   # unused now the deploy fast-forwards main; kept for callers
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
AI="${AI:-/tmp/cell-ai}"
O="${O:-$CELL_HOME/orchestrator}"
H="$AI/scripts/orchestrator-harness"
REPO="${REPO:-/tmp/cell-ai}"
OR="${OR:-daniel-ospina/agent-infra}"
SCOPE="${SCOPE:-broad}"
MAX_LANES="${MAX_LANES:-3}"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

export HOME="$CELL_HOME"
cd "$AI" || die "no $AI"

say "repo HEAD=$(git rev-parse --short HEAD)  branch=$(git rev-parse --abbrev-ref HEAD)"

# ── 1. stop the controller before touching the files it is reading ────────────
if tmux has-session -t orch 2>/dev/null; then
  say "stopping controller (tmux orch)"
  tmux kill-session -t orch 2>/dev/null
  sleep 2
fi

# ── 2. fast-forward the whole clone to main ───────────────────────────────────
# NOT a path-scoped checkout: for a cell whose REPO is this clone, `git checkout <ref> --
# <path>` leaves the index dirty, which the controller then sees. Once the registry is on
# main, a plain fast-forward updates BOTH the harness and the operator's repo, cleanly.
say "fetching origin/main"
git fetch -q origin main || die "git fetch failed"
BEFORE="$(git rev-parse --short HEAD)"
git merge --ff-only origin/main >/dev/null 2>&1 || die "cannot fast-forward to main (local changes in $AI?)"
say "clone -> $(git rev-parse --short HEAD) (was $BEFORE)"

[ -f "$H/claims.sh" ]               || die "claims.sh missing on main — is the registry merged?"
[ -f "$H/test-claims.sh" ]          || die "test-claims.sh missing on main"
say "claims.sh present: $(wc -c < "$H/claims.sh" | tr -d ' ') bytes"

# ── 3. re-seed the runtime dir with EVERY harness script ──────────────────────
mkdir -p "$O" || die "cannot create $O"
cp -p "$H"/*.sh "$O"/ || die "seed failed"
[ -f "$O/claims.sh" ] || die "claims.sh did NOT land in $O — the registry would be silently OFF"
say "seeded $O with $(ls "$O"/*.sh | wc -l | tr -d ' ') scripts (claims.sh present)"

# ── 4. restart the controller, cold, with HOME carried into tmux ──────────────
say "starting controller: OR=$OR REPO=$REPO SCOPE=$SCOPE MAX_LANES=$MAX_LANES"
tmux new-session -d -s orch -c "$H" \
  "set -a; [ ! -f '$CELL_HOME/keys.env' ] || . '$CELL_HOME/keys.env'; set +a; \
   HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' MAX_LANES='$MAX_LANES' \
   bash '$H/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
sleep 8

tmux has-session -t orch 2>/dev/null && say "controller UP" || die "controller did not start"
if [ -f "$O/claims.sh" ] && grep -q 'refs/claims' "$O/orch-loop.sh"; then
  say "VERIFIED: $O/orch-loop.sh references refs/claims and $O/claims.sh is present"
else
  say "WARN: registry wiring not visible in $O — check"
fi
say "DONE"
