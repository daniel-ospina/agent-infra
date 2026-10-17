#!/bin/bash
# ============================================================
# pi bootstrap — install this machine's pi configuration
# Run once on a new Mac:  ./setup.sh
# Safe to run repeatedly: every re-run refreshes the ACTIVE ~/.pi/agent files
# in place (content-merge), so repo updates flow to the live install and local
# extras survive. Never deletes anything outside ~/.pi/agent.
#
# ⚠️ It DOES delete, INSIDE ~/.pi/agent, exactly two things: a legacy $DEST/tools/fleet/
# (#1277, a pi boot-blocker) and the farm artifacts DECLARED in
# pi-bootstrap/farm-retired.txt (#1924 — a retired script must stop existing on the
# machines, not just stop being delivered). Nothing else is ever removed; a local extra
# that is not declared retired is kept.
# ============================================================
set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$BOOTSTRAP_DIR/pi-config"
INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.pi/agent"

# Resolve a path to an absolute, symlink-free form. Used to decide whether a
# destination symlink still points into THIS repo (realpath equality) instead
# of grepping the raw link target for a path substring — clone path agnostic.
# Prints "" (and exits 0) when the path cannot be resolved.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

mkdir -p "$DEST"

echo "==> Copying config into $DEST"

# Back up any existing settings/models (so nothing is lost)
for f in settings.json models.json models-store.json; do
  if [ -f "$DEST/$f" ] && [ ! -f "$DEST/$f.bak-bootstrap" ]; then
    cp "$DEST/$f" "$DEST/$f.bak-bootstrap"
    echo "    backed up existing $f"
  fi
done

# Core config files
merge_models() {
  # Merge provider blocks: source wins per-provider; local providers survive.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/models.json" "$DEST/models.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
if isinstance(src.get("providers"), dict) and isinstance(dst.get("providers"), dict):
    merged["providers"] = {**dst["providers"], **src["providers"]}
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    models.json merged (local providers preserved)")
PY
  else
    cp "$SRC/models.json" "$DEST/models.json"
    echo "    models.json copied (python3 not found - plain copy)"
  fi
}
merge_mcp() {
  # Base MCP config (#104): install templates/.mcp.base.json → ~/.pi/agent/.mcp.json
  # so every pi session gets MCP servers even in repos without a local .mcp.json.
  # Source wins per server key; local extra servers survive re-syncs.
  [ -f "$INFRA_ROOT/templates/.mcp.base.json" ] || { echo "    .mcp.base.json missing - skipping MCP config"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
src_servers = src.get("mcpServers", {})
dst_servers = dst.get("mcpServers", {})
merged = {**dst, **src, "mcpServers": {**dst_servers, **src_servers}}
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    .mcp.json merged (base servers win; local extras preserved)")
PY
  else
    cp "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json"
    echo "    .mcp.json copied (python3 not found - plain copy)"
  fi
}
merge_settings() {
  # Source wins for keys it defines; target keeps local extras (skills,
  # packages, env, ...) so per-machine bits survive re-syncs. The `retry`
  # subtree is deep-merged per-key (source wins per key it defines, local
  # overrides survive) — a shallow merge would let the source `retry` block
  # silently reset a user's `retry.enabled: false` (the documented kill
  # switch) on every sync (#318 review).
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/settings.json" "$DEST/settings.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
if isinstance(src.get("retry"), dict) and isinstance(dst.get("retry"), dict):
    retry = {**dst["retry"], **src["retry"]}
    if isinstance(src["retry"].get("provider"), dict) and isinstance(dst["retry"].get("provider"), dict):
        retry["provider"] = {**dst["retry"]["provider"], **src["retry"]["provider"]}
    merged["retry"] = retry
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    settings.json merged (local extras preserved; retry deep-merged)")
PY
  else
    cp "$SRC/settings.json" "$DEST/settings.json"
    echo "    settings.json copied (python3 not found - plain copy)"
  fi
}
merge_models_store() {
  # Merge provider blocks: source wins per-provider; local providers survive.
  # Within a provider, keep the entry with the newer checkedAt (pi's runtime
  # catalog refreshes must survive a sync; a freshly-regenerated snapshot still
  # pushes updates). No-op if the snapshot doesn't ship models-store.json.
  [ -f "$SRC/models-store.json" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/models-store.json" "$DEST/models-store.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
for provider, src_entry in src.items():
    dst_entry = dst.get(provider)
    if not isinstance(src_entry, dict) or not isinstance(dst_entry, dict):
        continue
    src_ts = src_entry.get("checkedAt")
    dst_ts = dst_entry.get("checkedAt")
    dst_newer = isinstance(dst_ts, (int, float)) and (
        not isinstance(src_ts, (int, float)) or dst_ts > src_ts
    )
    if dst_newer:
        merged[provider] = dst_entry
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    models-store.json merged (runtime catalog state preserved)")
PY
  else
    cp "$SRC/models-store.json" "$DEST/models-store.json"
    echo "    models-store.json copied (python3 not found - plain copy)"
  fi
}
merge_mcp
merge_settings
merge_models
merge_models_store

# Folders (content-merge; overwrite same-named files). The "SRC/. DEST/" form
# copies CONTENTS into the existing destination — plain `cp -R SRC DEST` on BSD
# NESTS (dest/agents/agents) when DEST already exists, so re-runs would never
# update the active top-level files.
mkdir -p "$DEST/agents"
cp -R "$SRC/agents/."           "$DEST/agents/"
mkdir -p "$DEST/behavior-control"
cp -R "$SRC/behavior-control/." "$DEST/behavior-control/"

# Extensions: if the farm already symlinks into THIS repo, keep the symlinks
# (updates flow through git pull — no copy needed). Otherwise materialize a
# real copy. Links are compared by resolved target (realpath) against
# $INFRA_ROOT/extensions/$base, so any clone path is recognized. Stale or
# foreign links (broken, or pointing at a different checkout) are replaced
# with fresh materialized copies.
mkdir -p "$DEST/extensions"
copied=0; kept=0
for e in "$SRC"/extensions/*; do
  base="$(basename "$e")"
  dest="$DEST/extensions/$base"
  if [ -L "$dest" ]; then
    dest_resolved="$(resolve_path "$dest")"
    repo_resolved="$(resolve_path "$INFRA_ROOT/extensions/$base")"
    if [ -n "$dest_resolved" ] && [ -n "$repo_resolved" ] && [ "$dest_resolved" = "$repo_resolved" ]; then
      kept=$((kept+1))
      continue
    fi
    echo "    replacing stale/foreign symlink: $base"
    rm -f "$dest"
  fi
  if [ -f "$e" ]; then
    cp "$e" "$dest"
  else
    mkdir -p "$dest"
    cp -R "$e/." "$dest/"
  fi
  copied=$((copied+1))
done
echo "    extensions: $copied refreshed, $kept farm symlinks kept"

# Install extension dependencies (needs internet on first run)
if command -v npm >/dev/null 2>&1; then
  for ext in "$DEST"/extensions/*/; do
    if [ -f "$ext/package.json" ]; then
      ( cd "$ext" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 \
        && echo "    deps installed: $(basename "$ext")" ) \
        || echo "    warning: could not npm install $(basename "$ext")"
    fi
  done
else
  echo "    warning: npm not found - extension deps skipped (mcp-client/builtin-tools/loop-enforcer may not load)"
fi

# Bounded retry patch (idempotent, #318/#1088): cap pi's agent-level retry
# backoff at 1 min so the retry ladder is uniform, and keep the budget finite
# (settings.json `retry.maxRetries: 7` + `httpIdleTimeoutMs: 300000`) so a
# persistent failure ends the turn visibly instead of spinning for days.
# Re-applied on every sync so a `pi update` that
# rewrites the dist can't silently lose the patch. Non-zero (pi missing /
# patch target changed by an upgrade) is a warning, not an abort — the
# message is the diagnostic; re-run after a pi update if it failed.
echo "==> Bounded retry patch"
if [ -x "$INFRA_ROOT/scripts/patch-pi-retry.sh" ]; then
  if bash "$INFRA_ROOT/scripts/patch-pi-retry.sh"; then
    echo "    retry patch: ok"
  else
    echo "    WARNING: retry patch reported failures (see above) — run:"
    echo "      $INFRA_ROOT/scripts/patch-pi-retry.sh"
  fi
else
  echo "    WARNING: scripts/patch-pi-retry.sh missing — bounded retry patch NOT applied (sessions stop after 3 quick retries on network loss)."
fi

# Small config / rules files
cp "$SRC/skills-repos.yaml"          "$DEST/skills-repos.yaml"
cp "$SRC/coding-rules.md"            "$DEST/coding-rules.md"
cp "$SRC/response-rules-reminder.md" "$DEST/response-rules-reminder.md"

# Skills: keep a symlink farm if it already points into THIS repo (updates via
# git pull); otherwise materialize a real folder copy so paths never matter.
if [ -L "$DEST/skills" ]; then
  skills_resolved="$(resolve_path "$DEST/skills")"
  repo_skills_resolved="$(resolve_path "$INFRA_ROOT/skills")"
  if [ -n "$skills_resolved" ] && [ -n "$repo_skills_resolved" ] && [ "$skills_resolved" = "$repo_skills_resolved" ]; then
    echo "    skills farm already symlinks into this repo - keeping (updates via git pull)"
  else
    echo "    replacing stale/foreign skills symlink with a real folder"
    rm -f "$DEST/skills"
    mkdir -p "$DEST/skills"
    cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
    echo "    skills copied ($(ls "$DEST/skills" | wc -l | tr -d ' ') items)"
  fi
elif [ -d "$DEST/skills" ]; then
  cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
  echo "    skills refreshed (local extras preserved)"
else
  mkdir -p "$DEST/skills"
  cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
  echo "    skills copied ($(ls "$DEST/skills" | wc -l | tr -d ' ') items)"
fi

# Scripts farm (launchd-invoked): COPY (not symlink) repo scripts into
# ~/.pi/agent/scripts. #427: symlinks into the repo (~/Documents, macOS
# TCC-protected) made launchd-spawned bash fail with EPERM at script-open;
# real files under ~/.pi/agent are readable, so copies revive the two
# remaining launchd jobs — provider-latency-tripwire (#424, self-contained)
# and corruption-canary (watches ~/swarm, an UNPROTECTED path — #431 probe:
# python3 EPERMs on ~/Documents under launchd exactly like bash/git/node;
# the TCC wall is path-based, interpreter-independent).
# hub-state-check + skill-lint-oracle are NOT launchd jobs anymore (#432 —
# Option C): they read ~/Documents repos, which launchd can never do without
# an FDA grant, so extensions/session-checks.ts runs them age-gated from pi's
# session_start (TCC-approved tree). Same model as the skills farm: idempotent
# refresh on each sync.sh. Stale-dest caveat: a farm script removed from the repo is
# NOT deleted from ~/.pi on that alone (extras kept) — so it must ALSO be declared in
# pi-bootstrap/farm-retired.txt, which the UNFARM leg at the end of this file applies
# (#1924). What remains true: install-launchd's broken-target check can no longer
# catch a retired name, so retiring a farmed script must also remove/retire its plist
# job (add the label to templates/launchd/RETIRED). Test files and plist templates are
# not farmed (tests don't ship; plists render from templates/launchd).
#
# The paths every farm DECLARES, RELATIVE TO $DEST (#1924) — the same form the
# retirement list uses (`scripts/…`), so the two sets are compared directly. Recorded by
# each copy loop below (declared, not merely copied: a name whose repo file did not land
# is still declared, and must not be silently removed either). The UNFARM leg at the end
# of this file checks its retirement list against THIS set: a name in both is a
# contradiction and is refused instead of deleted.
# The set is also RECORDED in $DEST/state/farm-declared.txt after each apply, which is
# what makes a DROPPED recording line (or a name quietly removed from a farm array)
# observable: the next run compares against it and fails loudly instead of silently
# leaving the file installed (farm_check_declared_shrink).
# ⛔ A NEWLINE-SEPARATED STRING, deliberately NOT a bash array. pi-bootstrap/cell-install.sh's
# read_farm_set() reads EVERY top-level `name=(...)` array in this file as a FARM and dies
# on one it does not know ("declares farm array(s) this installer does not know") — so a
# bookkeeping array here would break every cell install. Measured: the first version of
# this leg used `farm_declared_rel=()` and `test-cell-install.sh` failed on it.
farm_declared_rel=""

# A farm array is a DECLARATION of what this checkout ships. A name it lists but the
# checkout does not contain is an INCOMPLETE checkout, and skipping it in silence is how a
# farm quietly delivers less than the repo says (#1931) — and, since #1924, how a
# deployment reads as a retirement: the name would be recorded as declared, then look
# orphaned (or worse, get "declared retired" by a reader following the orphan advice).
# So missing names are collected here and the run FAILS before the UNFARM leg.
farm_missing=""

scripts_dir="$INFRA_ROOT/scripts/checkout-hygiene"
if [ -d "$scripts_dir" ]; then
  mkdir -p "$DEST/scripts/checkout-hygiene"
  copied=0
  for f in "$scripts_dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.plist|*.test.*) continue ;;
    esac
    farm_declared_rel+="scripts/checkout-hygiene/$base"$'\n'
    dest="$DEST/scripts/checkout-hygiene/$base"
    if [ -L "$dest" ]; then
      echo "    replacing farm symlink with real copy: $base"
      rm -f "$dest"
    fi
    cp -f "$f" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    copied=$((copied+1))
  done
  if [ "$copied" -eq 0 ]; then
    farm_missing+="scripts/checkout-hygiene/* (the directory exists but holds no farmable file)"$'\n'
  fi
  echo "    scripts/checkout-hygiene farm: $copied copied (real files, #427)"
else
  farm_missing+="scripts/checkout-hygiene/ (the whole directory is absent — $INFRA_ROOT)"$'\n'
fi

# Fleet-scripts farm (#373 + #469 + #783 + #1311): the weekly fleet-cost cadence
# runs under launchd (com.eldato.fleet-cost-weekly plist), the pi-session reaper
# runs hourly (com.eldato.pi-session-reaper plist), the Task 6 child-session
# retention sweep runs hourly (com.eldato.pi-task-session-prune plist), and the
# worktree reaper runs daily (com.tortoise.worktree-reaper plist) —
# launchd cannot read ~/Documents (same TCC wall as #427).
# session-postmortem.sh (the shared parser), the report, the watch, the weekly
# driver, the reaper, the prune sweep, and the worktree reaper must ALL sit in
# ~/.pi/agent/scripts so
# the drivers' sibling calls resolve and the plists' ProgramArguments targets
# exist (broken-target guard). Same idempotent real-copy refresh model.
# #1719 adds ci_runner_gate.sh: the launchd job com.tortoise.ci-runner-gate
# executes $DEST/scripts/ci_runner_gate.sh, so farming it is what makes the REPO
# copy the copy that runs — without it a box keeps executing a hand-copied
# duplicate (a merged fix never reaches it) and a second box has no fallback gate.
#
# #1552 — the LAPTOP-ONLY lane-orchestration layer joins this farm. Each of the 27 entries
# below existed on exactly ONE disk (~/.pi/agent/scripts) and in no repo file, so a repair to the
# fleet's own dispatch guard could not go through the gate that guard exists to protect
# (measured: a fix for a broken gate was applied in place, unreviewed and unreproducible on a
# rebuilt machine — the remedy for a broken gate was itself ungated). They farm FLAT for the same
# reason as the rest of this list: the layer resolves its siblings as `$SCRIPTS/<name>` at
# $DEST/scripts/, which is this farm's destination.
#
# ⚠️ PARTIAL BY CONSTRUCTION — declared here, not left to be discovered. RE-MEASURED 2026-10-16: the
# VERSIONED half of the SAME layer is a set of producers, and the farm used to carry NONE of them, so a
# box rebuilt from this file got every farmed CONSUMER without the PRODUCER it executes. Five were
# added to THIS array by that measurement (`lane-actions.py`, `lane-watchdog.py`, `objective.py`,
# `cadence-nudge.sh`, `publish-live-workspaces.py`) — but WHICH producers exist is **no longer
# measured here**: since #1899 the farm's own completeness gate
# (`pi-bootstrap/tests/test-setup-no-nesting.sh`) DERIVES the set from the exec sites in the farmed
# consumers and fails any producer that is in no array and in no named gap. **That gate is the single
# source of truth for the population; this paragraph explains WHY the class exists, never which
# members it has.** Four of the five are exec'd by a caller THIS array already farms; `lane-watchdog.py`
# is not, and is farmed ahead of its caller (see below). No per-producer caller map is kept here on
# purpose: every line-numbered edge this paragraph used to carry had already drifted (:238 -> :329 by
# 2026-10-16), and the gate derives and pins the real edges on every run. Read the gate's
# `DECLARED-*` / `SUMMARY:` lines, not this comment, for the current population. One producer it
# cannot see is a NAMED residual, not a blank spot: `cloud-cell-supervisor.sh` is exec'd by the farmed
# `cloud-cell-quiesce.sh` through a variable-held prefix, so it is in no array and a fresh farm gets the
# consumer without it (the quiesce then falls back to `supervisor: <none found>`) — #1938 owns whether
# it is delivered or stays cell-only.
# They farm FLAT for the same reason as the rest of this list (the layer resolves siblings as
# `$SCRIPTS/<name>` at $DEST/scripts/).
# `lane-watchdog.py`'s ONLY caller is `heartbeat-loop.sh`, and `heartbeat-loop.sh` is itself withheld
# pending #1553 (below) — so it is farmed NOW, ahead of its caller, so that #1553's landing cannot
# yield a fresh farm whose caller is present and whose producer is absent. The other four are reached
# from callers this array already delivers.
#
# TWO are STILL not carried by this array, deliberately:
#   * `lane-status.py` — the DESTINATION is ahead (repo 1993 lines / live 2005 at the 2026-10-15
#     measurement; the live copy carries the #1777 abstention text, in flight in #1784). Farming the
#     repo copy would OVERWRITE the running classifier with an older one — the fail-dangerous
#     overwrite #1553's review named.
#   * `heartbeat-loop.sh` — byte-identical repo↔live at the same measurement, and held back only
#     because `lane-status.py` is.
# #1553 owns both: it declares `lane_root_srcs=(lane-status.py heartbeat-loop.sh)` and sources them
# from `scripts/` once `lane-status.py`'s live bytes land. Until then the gap is declared, and
# `pi-bootstrap/tests/test-setup-no-nesting.sh` makes the declaration do WORK: since #1899 that check
# DERIVES its population from the exec sites in these consumers (transitively, so `lane-watchdog.py`
# is reached through `heartbeat-loop.sh`) and fails any derived producer that is declared in NEITHER
# farm array nor one of the named gaps. It is no longer a hand list that can fall behind the code —
# adding an exec site is what changes the population, and the change must be dispositioned. The
# repo↔deployed identity instrument that would report drift continuously is #1760/#1759's — not
# this list's.
# The same applies one directory over, to the `state/`-resident dependencies of the farmed consumers.
# The farm NEVER creates or copies into `$DEST/state/` — no `mkdir` and no `cp` target it anywhere in
# this file (measured at #1899) — so these are broken on every fresh farm. #1899's derivation found
# FIVE of them, not three:
#   * `state/lane-confirm.py`  — read FAIL-SILENTLY (a non-zero exit is read as "screened, not
#                                stalled"; see the filed #1797); exec'd through a hardcoded
#                                /Users/<owner>/ absolute path at orchestrator-heartbeat.sh:336.
#   * `state/lane-triage.py`   — read FAIL-SILENTLY (`2>/dev/null || log "NOTE triage unavailable"`,
#                                orchestrator-heartbeat.sh:636); delivery owned by #1553.
#   * `state/lane-verdict.py`  — the verdict-KEY LOADER (`lane-actions.py:80,1530`); absent it
#                                degrades to `RULE` silently. Found by #1899's derivation, disclosed
#                                to the #1552 umbrella.
#   * `state/queues/claim.py`  — NOT in the silent class: its read fails LOUDLY (`claim_next()`
#                                raises `QueueReadError` and the caller prints `READ-FAILED <lane>:
#                                … withholding this lane (NOT read as empty)`), while its RELEASE
#                                paths (`free`/`done`) do ignore their result. Untracked per #1567.
#   * `state/queues/refresh-queues.py` — the queue REFRESH (`heartbeat-loop.sh:415`, non-fatal:
#                                `|| echo "queue refresh failed (non-fatal; dispatcher uses the last
#                                known-good queue)"`), so a fresh farm silently keeps refreshing
#                                nothing. Untracked per #1567.
# None of the five is in any farm list, and `test-setup-no-nesting.sh` names each with its owning
# issue so the class cannot grow a silent member.
# ⛔ Keep this assignment on ONE line: `scripts/ci_runner_gate.test.sh` reads it with
# `sed -n 's/^fleet_srcs=(\(.*\))$/\1/p'`, so a wrapped array reads as EMPTY and that gate's
# membership assertion goes RED. (Loud, not silent — do not describe it as vacuous.)
# Tests are not farmed (the farm contract above): scripts/test_objective.py and
# scripts/test_turn_classify_state.py land in the repo and stay there.
# #1787 adds cleanup-stale-branches.sh: the daily com.tortoise.branch-reaper job
# runs the FARMED copy through the shared launcher with an explicit --repo, and
# install-launchd.sh's broken-target guard refuses the whole install when the
# farmed script is absent.
# ⛔ RETIRING A NAME IS TWO EDITS IN ONE COMMIT (#1924): drop it from this array AND
# declare its deployed path (`scripts/<name>`) in pi-bootstrap/farm-retired.txt.
# Removing it here alone stops DELIVERY only — every box that already has a copy keeps
# it, executable, in $DEST/scripts. A name left in BOTH places is refused loudly by the
# UNFARM leg at the end of this file (the copy leg would just re-create it); dropping
# it here WITHOUT declaring it is caught by the snapshot check on the next sync.
fleet_srcs=(fleet-cost-weekly.sh fleet-cost-report.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh pi-task-session-prune.sh pi-reap-worktrees.sh pi-reap-worktrees-launchd.py cleanup-stale-branches.sh ci_runner_gate.sh ask-owner.py beta-progress.py cadence-nudge.sh cadence-timer.sh child-check.py cloud-cell-quiesce.sh deploy-crossbox.sh deploy-mac-orchestrator.sh goal-state.py lane-actions.py lane-guard.py lane-read.py lane-scan-fallback.sh lane-watchdog.py lane-wip.py live-workspaces-publisher.py merge-queue.py objective.py orch-send.sh orchestrator-heartbeat.sh orphan-reap.py pr-doctor.py probe-one.py publish-live-workspaces.py queue-dispatch.py safe-send.sh seed-goal-map.py tree-cpu.py turn-classify.py turn-end.py unblock-lane.sh undelivered-answers.py)
mkdir -p "$DEST/scripts"
fleet_copied=0
for base in "${fleet_srcs[@]}"; do
  farm_declared_rel+="scripts/$base"$'\n'
  f="$INFRA_ROOT/scripts/$base"
  if [ ! -f "$f" ]; then
    farm_missing+="scripts/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  fleet_copied=$((fleet_copied+1))
done
echo "    scripts fleet farm: $fleet_copied copied (fleet cadence, #373 + runner gate, #1719)"

# Shared-library farm (#1178): the fleet-scripts farm above copies pi-reap-idle.sh
# FLAT into $DEST/scripts/, and that reaper resolves its process-identity rule
# from a SIBLING directory — `$(dirname "${BASH_SOURCE[0]}")/lib/pid-identity.sh`
# — the same sibling-resolution contract the checkout-hygiene drivers rely on.
# Farming the reaper WITHOUT its library re-arms the hourly
# com.eldato.pi-session-reaper job with a FAIL-CLOSED abort (exit 3, "identity
# library missing") on every pass until the farm catches up. So the library is
# farmed WITH it, preserving the relative positions
# (scripts/pi-reap-idle.sh <-> scripts/lib/pid-identity.sh). Same idempotent
# real-copy refresh model as the farms above (real files, not symlinks: #427).
#
# #1362 D1 adds a SECOND sibling: the merge-gate farm copies record-review.sh
# flat into $DEST/scripts/, and it resolves its diff normalizer as
# `$(dirname "${BASH_SOURCE[0]}")/lib/diff-normalize.py` (the ONE implementation of
# the review-evidence normalization, shared with the consumer workflow). Farming
# record-review.sh WITHOUT diff-normalize.py degrades the producer to the raw
# pre-#1362 digest — no false accept, but every base-only update goes back to
# refusing carry-forward. Farm them together.
# #1897 H3 adds a THIRD sibling: the floor (`cadence-nudge.sh`) and the fleet
# heartbeat (`heartbeat-loop.sh`) both have to decide whether the recap/beat pair
# they are about to publish/read is VERIFIABLE, and both must decide it the same
# way — a second copy of the rule is how the two drift apart. They share
# `scripts/lib/beat-pair.sh` (same sibling-resolution contract as above: the
# scripts resolve it as `$(dirname "${BASH_SOURCE[0]}")/lib/beat-pair.sh`). A
# missing lib makes the guard FAIL CLOSED: the pair is treated as unverifiable
# and the act clause is withheld, with a logged reason — never a silent pass.
lib_srcs=(pid-identity.sh diff-normalize.py beat-pair.sh)
mkdir -p "$DEST/scripts/lib"
lib_copied=0
lib_failed=0
for base in "${lib_srcs[@]}"; do
  farm_declared_rel+="scripts/lib/$base"$'\n'
  f="$INFRA_ROOT/scripts/lib/$base"
  if [ ! -f "$f" ]; then
    echo "    scripts lib farm: MISSING $f — a declared sibling did not land, so its consumers cannot verify what it provides" >&2
    lib_failed=$((lib_failed+1))
    continue
  fi
  dest="$DEST/scripts/lib/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: lib/$base"
    rm -f "$dest"
  fi
  # Atomic install (#1362 review): copy to a sibling temp then rename, so a
  # concurrent reader (record-review.sh runs during merges; this farm runs at
  # session_start) can NEVER observe a truncated/zero-byte lib. An empty
  # normalizer exits 0 printing nothing, which would hash the EMPTY string into
  # a constant digest — a false accept — so the reader also guards `[ -s ]`.
  if cp -f "$f" "$dest.tmp.$$" 2>/dev/null \
     && chmod +x "$dest.tmp.$$" 2>/dev/null \
     && mv -f "$dest.tmp.$$" "$dest" 2>/dev/null; then
    lib_copied=$((lib_copied+1))
  else
    echo "    scripts lib farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    rm -f "$dest.tmp.$$"
    lib_failed=$((lib_failed+1))
  fi
done
if [ "$lib_failed" -gt 0 ]; then
  echo "    scripts lib farm: $lib_copied copied, $lib_failed FAILED/MISSING (pid-identity.sh + diff-normalize.py + beat-pair.sh, #1178/#1362)" >&2
  farm_missing+="scripts/lib/ ($lib_failed declared sibling(s) FAILED or MISSING)"$'\n'
else
  echo "    scripts lib farm: $lib_copied copied (pid-identity.sh + diff-normalize.py + beat-pair.sh, #1178/#1362)"
fi

# Fleet-tools farm (#1178 unit 3): the scheduled lane-liveness report
# (templates/launchd/com.eldato.lane-liveness.plist) runs
# $DEST/scripts/fleet/lane_liveness.py under launchd. That driver imports its
# sibling classifier ($DEST/scripts/fleet/liveness.py) and forks the shared
# identity library (scripts/lib/pid-identity.sh, farmed above in the #1178 lib
# farm); launchd cannot read ~/Documents (#427), so these are COPIED, not
# symlinked. A missing classifier is a loud exit 2 in the driver, never a
# silent "no lanes". Same idempotent real-copy refresh model as above.
#
# WHY scripts/fleet/ AND NOT tools/fleet/ (#1277): the installed pi package's
# startup migration (dist/migrations.js checkDeprecatedExtensionDirs) scans
# ~/.pi/agent/tools/ and treats ANY entry other than fd/rg/fd.exe/rg.exe as a
# legacy "custom tools" directory (hidden files ignored). On a hit it prints a
# deprecation notice and then BLOCKS in showDeprecationWarnings() — an
# untimed `stdin.once("data")` keypress wait with no end/error handler. Farming
# the fleet tools there made EVERY fresh interactive `pi` hang forever at
# "Press any key to continue...", which is the fleet's entire dispatch path
# (every lane is an interactive pi). scripts/fleet/ is outside that scan.
#
# The relative resolution the driver relies on is preserved: liveness.lib_path()
# resolves <here>/../../scripts/lib/pid-identity.sh, which at
# $DEST/scripts/fleet/ is exactly $DEST/scripts/lib/pid-identity.sh — the same
# FARMED library the plist pins as PI_PID_IDENTITY_LIB. The farmed fleet/ now
# sits visibly beside the farmed lib/, so the layout no longer merely coincides
# with the pin. The plist still pins the env var, but the layout is what makes
# the relative fallback safe.
# fleet-health.py and map-sessions.py joined this farm in #1178 unit 4: both lived
# ONLY as untracked files in ~/.pi/agent/state/, so one disk loss took the recovery
# primitive (map-sessions.py identifies every session by its FIRST USER MESSAGE —
# how a lane holding an issue is found) and the only untracked tool that computed
# `PID DEAD` from its own private rule (fleet-health.py; the fleet's shared verdict
# lives in tools/fleet/liveness.py, farmed just above — the REPO path; only the
# farmed destination is scripts/fleet/). fleet-health.py must sit BESIDE
# liveness.py: it imports that sibling classifier for the identity probe, and
# that classifier resolves the rule from the sibling scripts/lib/ above.
fleet_tools=(liveness.py lane_liveness.py fleet-health.py map-sessions.py)
mkdir -p "$DEST/scripts/fleet"
tools_copied=0
for base in "${fleet_tools[@]}"; do
  farm_declared_rel+="scripts/fleet/$base"$'\n'
  f="$INFRA_ROOT/tools/fleet/$base"
  if [ ! -f "$f" ]; then
    farm_missing+="scripts/fleet/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/fleet/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: scripts/fleet/$base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  tools_copied=$((tools_copied+1))
done
echo "    scripts/fleet farm: $tools_copied copied (lane-liveness + fleet-health + map-sessions, #1178)"

# Migration off the deprecated location (#1277). The farm used to write
# $DEST/tools/fleet/, one of the very paths pi's startup scan rejects — so a
# machine that already has it keeps hanging on every interactive boot until the
# directory is GONE. Copying to the new path is not enough; remove the old one.
# Never touch $DEST/tools/fd or $DEST/tools/rg (pi auto-extracts those binaries
# there and they are the one entry the scan permits): remove only fleet/, then
# remove tools/ itself only when the removal left it empty.
if [ -d "$DEST/tools/fleet" ]; then
  rm -rf "$DEST/tools/fleet"
  echo "    migrated fleet farm out of the deprecated tools/fleet/ (pi boot-blocker)"
fi
if [ -d "$DEST/tools" ] && [ -z "$(ls -A "$DEST/tools" 2>/dev/null)" ]; then
  if rmdir "$DEST/tools" 2>/dev/null; then
    echo "    removed now-empty $DEST/tools/"
  fi
fi

# Regression guard (#1277): the farm must NEVER leave a non-fd/rg entry in
# $DEST/tools/. pi's startup scan blocks interactive boot on one (see the
# WHY comment above), and a local workaround is not durable — this farm
# re-creates whatever it is told to, within minutes. Fail LOUD here instead of
# shipping a machine on which no interactive pi can start: this is the durable
# fix; farming to scripts/fleet/ is the immediate one.
if [ -d "$DEST/tools" ]; then
  tools_stray=""
  tools_entry=""
  while IFS= read -r tools_entry; do
    [ -n "$tools_entry" ] || continue
    case "$(printf '%s' "$tools_entry" | tr '[:upper:]' '[:lower:]')" in
      fd|rg|fd.exe|rg.exe) ;;   # pi's own auto-extracted binaries — permitted
      .*) ;;                    # hidden entries (.DS_Store etc.) — pi ignores them
      *) tools_stray="$tools_stray $tools_entry" ;;
    esac
  done <<< "$(ls -A "$DEST/tools" 2>/dev/null)"
  if [ -n "$tools_stray" ]; then
    echo "ERROR: $DEST/tools/ contains non-fd/rg entries:$tools_stray" >&2
    echo "       pi's startup scan blocks EVERY interactive boot on these" >&2
    echo "       (deprecation notice + an untimed keypress prompt)." >&2
    echo "       Fleet tools belong in $DEST/scripts/fleet/, never tools/." >&2
    exit 1
  fi
fi

# Merge-gate scripts farm (#562): record-review.sh — the review-enforcer's
# merge-registry writer (issue #138).
# NOT launchd-invoked (pi-session code resolves record-review.sh explicitly:
# code-review SKILL.md Step 10 + commit-workflow 04-merge-deploy), so it never
# joined the #427/#373 farms and drifted: the repo copy is CI-tested while
# production mints execute the ~/.pi copy. Same idempotent real-copy refresh
# model as the farms above.
merge_gate_srcs=(record-review.sh)
mkdir -p "$DEST/scripts"
merge_gate_copied=0
for base in "${merge_gate_srcs[@]}"; do
  farm_declared_rel+="scripts/$base"$'\n'
  f="$INFRA_ROOT/scripts/$base"
  if [ ! -f "$f" ]; then
    farm_missing+="scripts/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  merge_gate_copied=$((merge_gate_copied+1))
done
echo "    scripts merge-gate farm: $merge_gate_copied copied (record-review.sh, #562)"

# ── the pi spawn-point gate (#1884) ──────────────────────────────────────────
# Installed as `pi` — not as a farmed script — because that is the whole point: `spawn-gate.sh` is
# ALSO an executable whose invoked identity IS the gate (see "THE SPAWN POINT" in that file), and it
# is installed under the name a caller actually types. $DEST/bin is FIRST on PATH on this fleet
# (measured on the laptop and on a cmux cell, and install-launchd.sh keeps it in the runner-gate
# plist PATH so the daemon and the tmux children it starts inherit it), so every `pi` invocation
# resolves here: lane.sh, fix-one.sh, merge-one.sh, a hand-written tmux runner, an interactive
# session. Before #1884 the gate was reachable only by callers that sourced it, and a runner that
# did not was UNGATED AND SILENT — that is how a box reached load 258 against its own ceiling of 100.
#
# ONE COPY, from ONE source: the same file the harness callers source, so the ceiling a caller applies
# and the ceiling the spawn point applies cannot drift. A real copy rather than a symlink for the
# #427 reason (a symlink into the checkout EPERMs under launchd/TCC and dangles when a worktree is
# reaped — a dangling `pi` on PATH breaks every lane on the box).
SPAWN_GATE_SRC="$INFRA_ROOT/scripts/orchestrator-harness/spawn-gate.sh"
if [ -f "$SPAWN_GATE_SRC" ]; then
  mkdir -p "$DEST/bin"
  if [ -e "$DEST/bin/pi" ] && ! cmp -s "$SPAWN_GATE_SRC" "$DEST/bin/pi"; then
    # Someone else's `pi` in this directory would be silently REPLACED by the line below, and a
    # different `pi` launcher is exactly the kind of local tooling an operator would not want
    # clobbered unnoticed — so keep it, loudly.
    cp -f "$DEST/bin/pi" "$DEST/bin/pi.bak-bootstrap" 2>/dev/null || true
    echo "    backed up a pre-existing $DEST/bin/pi to pi.bak-bootstrap (it is not this repo's gate)"
  fi
  cp -f "$SPAWN_GATE_SRC" "$DEST/bin/pi"
  chmod +x "$DEST/bin/pi" 2>/dev/null || true
  echo "    pi spawn-point gate installed at $DEST/bin/pi (#1884)"
  # A gate that is installed but NOT ahead of the real pi on PATH is a false install: it would report
  # success here while every spawn resolved past it. Say so at install time, when it is cheap to fix.
  case ":$PATH:" in
    *"/.pi/agent/bin:"*) ;;
    *) echo "    WARNING: $DEST/bin is not on this shell's PATH, so the spawn-point gate is NOT in front of \`pi\` here." >&2 ;;
  esac
else
  echo "ERROR: $SPAWN_GATE_SRC is missing — the pi spawn-point gate (#1884) was NOT installed." >&2
  echo "       Every \`pi\` a hand-written runner starts would then be ungated and silent, which is the" >&2
  echo "       defect #1884 records. Re-clone agent-infra and re-run this script." >&2
  exit 1
fi

# ── UNFARM leg (#1924) ────────────────────────────────────────────────────
# Every farm above is COPY-ONLY: `cp -f` writes the names an array lists and does
# nothing at all to a name it does not list. `[ -f "$f" ] || continue` therefore skips
# a retired name in SILENCE, and the copy already deployed stays in $DEST/scripts —
# executable, and sitting in the exact directory the fleet launches from
# (heartbeat-loop.sh resolves its dispatchers there). The repo then says the tool is
# retired while every box keeps running it, and nothing reports the divergence:
# install-launchd's broken-target check only sees a plist whose target is MISSING, and
# check-deployed-drift.sh compares $O harness *.sh only.
#
# The gap is real, not hypothetical: `templates/launchd/RETIRED` + retire_pass()
# already implement the delete leg for launchd JOBS for this same reason, and the
# #1277 fleet-tools migration had to hand-roll `rm -rf $DEST/tools/fleet` because the
# copy leg cannot remove. What did not exist was the script side of that rule.
#
# A retirement is DECLARED (pi-bootstrap/farm-retired.txt) and applied HERE, on the
# same sync that applies the copy legs — not by a human remembering to `rm`. Declared
# and never inferred from absence: absence cannot tell "retired" from "the farm file
# failed to land" (the #1931 blindness class), and inference would delete working
# scripts on a box whose checkout was incomplete.
#
# Retiring a name is THREE edits in ONE commit:
#   1. drop it from every farm array above,
#   2. declare its deployed path in pi-bootstrap/farm-retired.txt, and
#   3. if a plist still targets it, add that label to templates/launchd/RETIRED.
# Miss 1 or 2 and the deployed copy stays forever: a name left in BOTH lists is a
# contradiction (the copy leg has just re-created it), so the leg below REFUSES to
# remove it and this script exits non-zero; a name left in NEITHER list is caught by
# the snapshot check (it was farmed here last run). Miss 3 and every later sync FAILS
# at the launchd step on a broken target — loud, but it strands the whole sync, which
# pi-bootstrap/tests/test-farm-unfarm.sh now catches at merge time.
if [ -n "$farm_missing" ]; then
  echo "ERROR: this checkout is INCOMPLETE — farm name(s) it DECLARES are not in $INFRA_ROOT:" >&2
  while IFS= read -r missed; do
    [ -n "$missed" ] && echo "         $missed" >&2
  done <<<"$farm_missing"
  echo "       Nothing below ran: the UNFARM leg, launchd convergence, the shell-profile wiring." >&2
  echo "       A farm that delivers less than it declares is how the repo and the machines drift" >&2
  echo "       apart in silence (#1931) — and, on the UNFARM side, how a file that was never" >&2
  echo "       deployed comes to look retired. Re-run from a complete checkout (git status)." >&2
  exit 1
fi
if [ ! -f "$BOOTSTRAP_DIR/lib/farm-retire.sh" ]; then
  echo "ERROR: $BOOTSTRAP_DIR/lib/farm-retire.sh is missing — the UNFARM leg cannot run, so a" >&2
  echo "       retired farm script would stay executable in $DEST/scripts with nothing to remove it." >&2
  exit 1
fi
# shellcheck source=lib/farm-retire.sh
. "$BOOTSTRAP_DIR/lib/farm-retire.sh"
if ! farm_check_declared_shrink "$DEST" "$BOOTSTRAP_DIR/farm-retired.txt" "$farm_declared_rel"; then
  echo "ERROR: the farm retirement check FAILED (see above): either a name farmed on this box by a" >&2
  echo "       previous run is now neither farmed nor retired (it would be ORPHANED), or the" >&2
  echo "       retirement list could not be read. Everything below this point" >&2
  echo "       did NOT run: launchd convergence, the shell-profile wiring, the TORTOISE_HOME probe." >&2
  echo "       The retirement leg has not run, so IT deleted nothing (the earlier legacy-path cleanup" >&2
  echo "       may have removed a deprecated directory). This is NOT proof the farm is current: an" >&2
  echo "       OLDER checkout declares fewer names than this box already has. Decide which cause it" >&2
  echo "       is — the two remedies are opposite (see above)." >&2
  exit 1
fi
if ! farm_unfarm "$DEST" "$BOOTSTRAP_DIR/farm-retired.txt" "$farm_declared_rel"; then
  echo "ERROR: the UNFARM leg failed (see above) — a retirement the farm cannot apply is NOT applied." >&2
  echo "       Everything below this point did NOT run: launchd convergence, the shell-profile wiring," >&2
  echo "       the TORTOISE_HOME probe. The whole retirement set is validated before the first" >&2
  echo "       removal, so a REFUSED set deleted nothing; if a removal itself failed, the message" >&2
  echo "       above says exactly which entry was removed and which was not (HALF-APPLIED)." >&2
  echo "       Remedy: fix or remove the path(s) named above, then re-run ./sync.sh." >&2
  exit 1
fi
# Record what this apply declared, AFTER the removal leg succeeded — a failed run never
# moves the baseline the shrink check compares against.
if ! farm_record_declared "$DEST" "$farm_declared_rel"; then
  echo "ERROR: could not record the farm declaration snapshot (see above) — the next run cannot" >&2
  echo "       detect a name dropped from a farm array without being declared." >&2
  exit 1
fi

# Wire shell profile (idempotent): auto-sync env + optional keys file
ZSHRC="$HOME/.zshrc"
[ -f "$ZSHRC" ] || touch "$ZSHRC"
grep -q "AGENT_INFRA_PATH" "$ZSHRC" 2>/dev/null || printf '\nexport AGENT_INFRA_PATH="%s"\n' "$INFRA_ROOT" >> "$ZSHRC"
grep -q "AGENT_SYNC_MODE" "$ZSHRC" 2>/dev/null || printf 'export AGENT_SYNC_MODE=auto\n' >> "$ZSHRC"
if [ -f "$HOME/pi-keys.env" ]; then
  chmod 600 "$HOME/pi-keys.env"
  grep -q "pi-keys.env" "$ZSHRC" 2>/dev/null || printf '[ -f "$HOME/pi-keys.env" ] && source "$HOME/pi-keys.env"  # pi API keys\n' >> "$ZSHRC"
  echo "    pi-keys.env wired into .zshrc (active in NEW terminals)"
else
  echo "    note: ~/pi-keys.env not found - keys must be added via /login or shell env"
fi
echo "    shell profile wired: AGENT_INFRA_PATH + AGENT_SYNC_MODE"

# MCP base config needs TORTOISE_HOME for the local tortoise MCP server.
# Detect a checkout in standard locations (sibling of the agent-infra clone
# first, then common layouts) and wire it into the shell profile when the var
# is unset and not already present (idempotent, mirrors AGENT_INFRA_PATH).
TORTOISE_HOME_SET=0
if [ -n "${TORTOISE_HOME:-}" ]; then
  TORTOISE_HOME_SET=1
elif grep -q "^export TORTOISE_HOME=" "$ZSHRC" 2>/dev/null; then
  TORTOISE_HOME_SET=1
else
  for cand in "$INFRA_ROOT/../tortoise" "$HOME/Documents/GitHub/tortoise" "$HOME/Documents/tortoise" "$HOME/tortoise"; do
    if [ -f "$cand/tortoise/mcp_server.py" ] && [ -x "$cand/.venv/bin/python3" ]; then
      printf 'export TORTOISE_HOME="%s"\n' "$(cd "$cand" && pwd)" >> "$ZSHRC"
      echo "    TORTOISE_HOME wired into .zshrc: $(cd "$cand" && pwd)"
      TORTOISE_HOME_SET=1
      break
    fi
  done
fi
if [ "$TORTOISE_HOME_SET" -eq 1 ]; then
  echo "    MCP: tortoise will use TORTOISE_HOME for its local MCP server"
else
  echo "    note: TORTOISE_HOME not set and no tortoise checkout found — tortoise MCP server unavailable until set"
fi

# Launchd agents (idempotent, #304): install the versioned plist templates
# (hub-state-check + corruption-canary). The installer renders → diffs vs the
# installed plist → skips when identical, reloads on change — safe on every
# run. Broken script targets fail loudly (non-zero) but don't abort setup:
# the message + --status are the diagnostic. macOS only (launchctl).
if [[ "$(uname)" == "Darwin" ]] && [ -x "$INFRA_ROOT/scripts/install-launchd.sh" ]; then
  echo ""
  echo "==> Launchd agents"
  if bash "$INFRA_ROOT/scripts/install-launchd.sh"; then
    echo "    launchd: in sync (see --status for detail)"
  else
    echo "    WARNING: launchd install reported failures (see above) — run:"
    echo "      $INFRA_ROOT/scripts/install-launchd.sh --status"
  fi
fi

echo ""
echo "Done! Next steps:"
echo "  1. Open a NEW terminal window (so the shell profile takes effect), then run:  pi"
echo "  2. Models should already work (keys from ~/pi-keys.env, if present). Otherwise /login."
echo "  3. Press Ctrl+L (/model) to pick a model and confirm it works"
echo "  4. Auto-sync: pi now pulls + refreshes this config automatically on start (Level 1)"
echo "     - Manual refresh anytime:  cd ~/agent-infra && ./sync.sh"
echo "  5. Read pi-bootstrap/HANDOFF.md — it tells pi what this machine is for"
