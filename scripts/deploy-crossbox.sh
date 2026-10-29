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
# ⛔ `REPO` HAS NO DEFAULT HERE, AND THAT IS THE FIX. This line used to read
# `REPO="${REPO:-/tmp/cell-ai}"` — a CELL path. This script is pushed to and run ON a cell, but it is
# also run on a LAPTOP against a cell-shaped AI, and on any such box the default names a directory that
# is not there; the controller then starts with `REPO=/tmp/cell-ai` (line 106 passes it through to the
# tmux command below), and the failure arrives one generation later as a dispatch path that resolves
# nothing. `REPO` is the operator's, set ONCE per box, and `repo-slug.sh`'s `resolve_repo` is the ONE
# place that reads it — it refuses by name rather than guessing. Resolved below, once `$H` and `die`
# exist.
OR="${OR:-daniel-ospina/agent-infra}"
SCOPE="${SCOPE:-broad}"
MAX_LANES="${MAX_LANES:-3}"

log_line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log_line "FATAL: $*" >&2; exit 1; }

# ⛔ SOURCED FROM `$H`, THE CELL'S OWN CHECKOUT: that copy is on main (keeping it there is this
# deploy's job), so the resolver that runs is the shipped one. A `$H` predating `resolve_repo` is
# REFUSED BY NAME rather than silently falling back to a path default — that fallback is the defect.
[ -f "$H/repo-slug.sh" ] || die "repo-slug.sh missing from $H — cannot resolve REPO, and this script will not guess one"
# shellcheck source=scripts/orchestrator-harness/repo-slug.sh
. "$H/repo-slug.sh" || die "cannot source $H/repo-slug.sh — cannot resolve REPO"
command -v resolve_repo >/dev/null 2>&1 || die "$H/repo-slug.sh is stale (no resolve_repo) — re-seed the cell's harness first: bash $H/deploy-harness.sh --src <agent-infra checkout> --o $O"
REPO="$(resolve_repo)" || exit $?

export HOME="$CELL_HOME"
cd "$AI" || die "no $AI"

log_line "repo HEAD=$(git rev-parse --short HEAD)  branch=$(git rev-parse --abbrev-ref HEAD)"

# ── 1. stop the controller before touching the files it is reading ────────────
if tmux has-session -t orch 2>/dev/null; then
  log_line "stopping controller (tmux orch)"
  tmux kill-session -t orch 2>/dev/null
  sleep 2
fi

# ── 2. fast-forward the whole clone to main ───────────────────────────────────
# NOT a path-scoped checkout: for a cell whose REPO is this clone, `git checkout <ref> --
# <path>` leaves the index dirty, which the controller then sees. Once the registry is on
# main, a plain fast-forward updates BOTH the harness and the operator's repo, cleanly.
log_line "fetching origin/main"
git fetch -q origin main || die "git fetch failed"
BEFORE="$(git rev-parse --short HEAD)"
git merge --ff-only origin/main >/dev/null 2>&1 || die "cannot fast-forward to main (local changes in $AI?)"
log_line "clone -> $(git rev-parse --short HEAD) (was $BEFORE)"

[ -f "$H/claims.sh" ]               || die "claims.sh missing on main — is the registry merged?"
[ -f "$H/test-claims.sh" ]          || die "test-claims.sh missing on main"
log_line "claims.sh present: $(wc -c < "$H/claims.sh" | tr -d ' ') bytes"

# ── 3. re-seed the runtime dir with EVERY harness script ──────────────────────
mkdir -p "$O" || die "cannot create $O"
cp -p "$H"/*.sh "$O"/ || die "seed failed"
[ -f "$O/claims.sh" ] || die "claims.sh did NOT land in $O — the registry would be silently OFF"
# ── the gh-limit layer (#1988) ────────────────────────────────────────────────
# Seeded with the same mirror rule as the *.sh files, because a cell without it spends the SHARED
# account's quota unserialised: four boxes, one bucket. Not fatal — a cell that cannot find the
# layer still merges (the wrapper fails open with a warning); what is lost is the serialisation.
# ⛔ STAGE-THEN-RENAME. Both files are EXECUTED by every gh call on the live cell, and a plain `cp`
# truncates before it writes — a call in that window would run `python3` on half a file. The
# supervisor seeds the same pair this way for the same reason.
if [ -f "$H/gh-limit/gh" ] && [ -f "$H/gh-limit.py" ]; then
  mkdir -p "$O/gh-limit" || die "cannot create $O/gh-limit"
  _seed_one() {  # <src> <dest>
    local _src="$1" _dst="$2" _tmp="$O/.seed-$(basename "$2").$$"
    cp -p "$_src" "$_tmp" || { rm -f "$_tmp"; die "cannot stage $(basename "$_dst") into $O"; }
    chmod +x "$_tmp"      || { rm -f "$_tmp"; die "cannot chmod $(basename "$_dst")"; }
    mv -f "$_tmp" "$_dst" || { rm -f "$_tmp"; die "cannot install $_dst"; }
  }
  _seed_one "$H/gh-limit/gh" "$O/gh-limit/gh"
  _seed_one "$H/gh-limit.py" "$O/gh-limit.py"
  log_line "seeded the gh-limit layer (serialised gh; path=$O/gh-limit)"
else
  # ⛔ MIRROR, not merely overlay — the same rule the *.sh loop above states. A stale `$O/gh-limit/gh`
  # left by an earlier harness stays on the controller PATH (orch-loop.sh re-asserts it on `[ -d ]`)
  # with its helper gone: a shim that cannot serialise anything, and before #1988's sentinel line the
  # pair could even resolve into itself. A cell without the layer falls back to PATH's real gh with a
  # warning, which is the documented fail-open.
  if [ -e "$O/gh-limit/gh" ] || [ -e "$O/gh-limit.py" ]; then
    rm -f "$O/gh-limit/gh" "$O/gh-limit.py" || die "cannot remove the stale gh-limit layer from $O"
    rmdir "$O/gh-limit" 2>/dev/null || true
    log_line "seed: removed the stale gh-limit layer — the harness no longer ships it"
  fi
  log_line "WARN: this harness ships no gh-limit layer — gh calls on this cell will NOT be serialised (#1988)"
fi
log_line "seeded $O with $(ls "$O"/*.sh | wc -l | tr -d ' ') scripts (claims.sh present)"

# ── 4. restart the controller, cold, with HOME carried into tmux ──────────────
# ⛔ `unset GH_REPO` AFTER `set +a` (#2235). `keys.env` is re-sourced INSIDE the session, so a
# global `export GH_REPO=…` in it answers every `gh` call that omits `--repo` from this controller
# onward — the fail-open that made `admin-merge.sh 2232` print '✅ PR #2232 is ALREADY MERGED' for a
# September TORTOISE PR over an open agent-infra one, exit 0. This is the fourth place that creates
# a session (with the supervisor's two and cloud-cell-quiesce.sh's one), so it carries the same
# strip; `cloud-cell-supervisor.test.sh` sweeps every session creator for it rather than naming
# files, so a fifth cannot be forgotten.
log_line "starting controller: OR=$OR REPO=$REPO SCOPE=$SCOPE MAX_LANES=$MAX_LANES"
tmux new-session -d -s orch -c "$H" \
  "set -a; [ ! -f '$CELL_HOME/keys.env' ] || . '$CELL_HOME/keys.env'; set +a; unset GH_REPO; \
   PATH='$O/gh-limit':\"\$PATH\" \
   HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' MAX_LANES='$MAX_LANES' \
   bash '$H/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
sleep 8

tmux has-session -t orch 2>/dev/null && log_line "controller UP" || die "controller did not start"
if [ -f "$O/claims.sh" ] && grep -q 'refs/claims' "$O/orch-loop.sh"; then
  log_line "VERIFIED: $O/orch-loop.sh references refs/claims and $O/claims.sh is present"
else
  log_line "WARN: registry wiring not visible in $O — check"
fi
log_line "DONE"
