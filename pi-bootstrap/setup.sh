#!/bin/bash
# ============================================================
# pi bootstrap — install this machine's pi configuration
# Run once on a new Mac:  ./setup.sh
# Safe to run repeatedly: every re-run refreshes the ACTIVE ~/.pi/agent files
# in place (content-merge), so repo updates flow to the live install and local
# extras survive. Never deletes anything outside ~/.pi/agent.
#
# ⚠️ It DOES delete, INSIDE ~/.pi/agent, exactly three things: a legacy $DEST/tools/fleet/
# (#1277, a pi boot-blocker), the farm artifacts DECLARED in
# pi-bootstrap/farm-retired.txt (#1924 — a retired script must stop existing on the
# machines, not just stop being delivered), and the `exa` server entry in
# $DEST/.mcp.json (owner ruling 2026-10-31, reversing #419: the merge is
# `{**dst, **src}`, so dropping `exa` from the template alone would leave every
# already-provisioned machine loading it). Nothing else is ever removed; a local extra
# that is not declared retired is kept — `exa` is removed because it was a BASE server
# being retired, not a local extra. NOTE the pop keys on the NAME only: a machine whose
# `.mcp.json` carries a hand-rolled server the operator happened to name `exa` will be
# de-configured too, which is why it is listed here rather than happening quietly.
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
  # Merge shipped models.json into the live one WITHOUT dropping live-only entries.
  # The semantics live in lib/merge-models.py — ONE implementation, pinned by
  # pi-bootstrap/tests/test-models-merge.sh (#682). The previous inline
  # `{**dst_providers, **src_providers}` replaced each provider OBJECT wholesale, so
  # every model id (and every modelOverrides key) that existed only live was deleted
  # silently, under a success message. Shipped wins per provider key, per model `id`
  # and per override key; live-only entries are preserved. The module re-derives the
  # "nothing live was lost" invariant independently and refuses to write (exit 1,
  # naming the entries) if it ever fails.
  if ! command -v python3 >/dev/null 2>&1; then
    if [ -f "$DEST/models.json" ]; then
      # No python3 to merge with. A plain copy is exactly the #682 defect — it would
      # drop every live-only entry — and .bak-bootstrap is written only on the FIRST
      # bootstrap, so the loss would be unrecoverable. Refuse loudly instead.
      echo "ERROR: python3 not found — cannot merge models.json without dropping live-only entries (#682)." >&2
      echo "       Refusing to overwrite the existing $DEST/models.json with the shipped file." >&2
      echo "       Install python3 and re-run, or merge $SRC/models.json into it manually." >&2
      return 1
    fi
    cp "$SRC/models.json" "$DEST/models.json"
    echo "    models.json copied (python3 not found - plain copy; no live models.json to preserve)"
    return 0
  fi
  if [ ! -f "$BOOTSTRAP_DIR/lib/merge-models.py" ]; then
    echo "ERROR: $BOOTSTRAP_DIR/lib/merge-models.py is missing — refusing to merge models.json by plain copy (#682)." >&2
    return 1
  fi
  python3 "$BOOTSTRAP_DIR/lib/merge-models.py" "$SRC/models.json" "$DEST/models.json"
}
merge_mcp() {
  # Base MCP config (#104): install templates/.mcp.base.json → ~/.pi/agent/.mcp.json
  # so every pi session gets MCP servers even in repos without a local .mcp.json.
  #
  # ⛔ THE MERGE RULES LIVE IN `pi-bootstrap/lib/merge-mcp.py`, SHARED WITH cell-install.sh.
  # The two callers used to merge inline and had already drifted into the same bug: a plain
  # `{**dst, **src}` source-wins merge silently REPOINTS a self-hosted `tortoise` url at the
  # hosted endpoint on every re-sync — and the base template's own `_comment` tells self-host
  # users to set exactly that url. On a machine with no hosted key the repointed entry then sends
  # `Bearer ` (empty), the server answers 401, and the failure reads as an auth error rather than
  # the silent repoint it is. One implementation is how the rule stops being obeyed on one
  # platform only. The lib also carries the `exa` migration (#419 reversed by the owner
  # 2026-10-31) and the "unusable entry is replaced, never preserved" rule.
  [ -f "$INFRA_ROOT/templates/.mcp.base.json" ] || { echo "    .mcp.base.json missing - skipping MCP config"; return 0; }
  if [ ! -f "$INFRA_ROOT/pi-bootstrap/lib/merge-mcp.py" ]; then
    echo "    ERROR: pi-bootstrap/lib/merge-mcp.py is missing from $INFRA_ROOT — refusing to merge" >&2
    echo "    .mcp.json with a second, private implementation (a wrong merge here repoints a" >&2
    echo "    self-hosted tortoise url at the hosted endpoint on every sync)." >&2
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 "$INFRA_ROOT/pi-bootstrap/lib/merge-mcp.py" "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json"; then
      echo "    ERROR: .mcp.json merge failed — the previous config is untouched" >&2
      return 1
    fi
  else
    # A plain copy CLOSES over a self-hosted tortoise url and drops every local server. It is kept
    # only because a machine with no python3 cannot merge at all, and it is loud.
    #
    # ⛔ IT ALSO KEEPS THE BYTES IT REPLACES (#3374 review, round 10 P2). Every other replace path in
    # this change keeps operator content — `merge-mcp.py`'s `_keep_backup()` runs for an unparseable or
    # wrong-shaped container — so this was the ONE path that told the operator their config had been
    # destroyed at the moment it became unrecoverable, on the ONE box with no python3 to reconstruct
    # it. A warning without a backup is a receipt, not a remedy.
    echo "    WARNING: python3 not found — copying .mcp.json wholesale (any local server and any" >&2
    echo "    self-hosted tortoise url is LOST). Install python3 and re-run to merge properly." >&2
    if [ -f "$DEST/.mcp.json" ]; then
      if cp -f "$DEST/.mcp.json" "$DEST/.mcp.json.bak"; then
        echo "    the replaced file is kept at $DEST/.mcp.json.bak" >&2
      else
        echo "    ⚠️  could not write $DEST/.mcp.json.bak — the replaced config is about to be LOST" >&2
      fi
    fi
    cp "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json"
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
# ⛔ A FAILED `.mcp.json` MERGE MUST NOT TAKE THE WHOLE LAYER WITH IT (#3374 review P1). This call
# used to be BARE under `set -e`, so an unusable template aborted setup.sh AT THE CONFIG STEP —
# measured with this script at 3db7779f4: rc=1 and `~/.pi/agent` was LITERALLY EMPTY (no extensions,
# no skills, no agents, and no farm — so not even record-review.sh, the tool the merge rail needs),
# while the only message was "the previous config is untouched". A refusal belongs to the CONFIG, not
# to the machine: the layer is installed, the previous `.mcp.json` is kept byte-identical, the error
# is named loudly, and this script STILL exits non-zero (below) so a bring-up cannot call it success.
_mcp_merge_failed=0
merge_mcp || _mcp_merge_failed=1
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
  # ⛔ NEVER copy a test file into the live farm (#1509/#2841). pi's extension loader
  # EXECUTES a top-level `.ts` OR `.js` under $DEST/extensions
  # (`dist/core/package-manager.js::collectAutoExtensionEntries`:
  # `entry.name.endsWith(".ts") || entry.name.endsWith(".js")`; pi's
  # `docs/extensions.md` says the same — "direct TypeScript or JavaScript files"), so
  # such a file there is not a test — it is an extension that runs its suite at session
  # start and whose stdout replaces the session's answer. Measured 2026-10-25: 12 test
  # files were farmed by this loop, every dispatched child on the box answered with
  # `auto-sync.test.ts` output instead of a reply, and no log named the cause.
  # THIS LIST IS THE LOADER'S SET, not a subset of it (#2841): the original guard matched
  # `*.test.ts` only, so a `*.spec.ts` / `*.test.js` / `*.spec.js` — all EXECUTED by the
  # same loader — was copied and its suite ran at every session start. `.tsx`, `.mts`
  # and `.cjs` are deliberately absent: the loader does not load them.
  # This loop is COPY-ONLY (like the scripts farm), so skipping here is not
  # enough — a test copied by an earlier run stays until it is removed, and it
  # stays EXECUTING. Remove both halves (see the sweep below).
  case "$base" in
    *.test.ts|*.spec.ts|*.test.js|*.spec.js)
      if [ -e "$dest" ]; then
        rm -f "$dest" && echo "    removed test file from live farm: $base"
      fi
      continue
      ;;
  esac
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
# ⛔ RECURSIVE sweep for test files in the live farm (#1509/#2841). The `case` in the loop
# above only guards TOP-LEVEL entries, and two paths escape it: (a) an entry that is a
# directory is copied with `cp -R`, which brings any `*.test.ts` inside it
# (`builtin-tools/`, `verification-gate/` both carry one), and (b) this loop is
# COPY-ONLY, so a test farmed by an earlier run whose source has since left the repo is
# never visited at all. Both are EXECUTED by pi's extension loader at session start,
# so the sweep is the half that makes the farm safe, not the `case`.
# The name set is the `case`'s set, on purpose: ONE definition of "a test file pi would
# execute", used by the writer and by the gate (scripts/check-pi-config-extensions.sh
# check 6). A name added to one and not the other is the fail-open #2841 measured.
# ⛔ `node_modules` IS PRUNED, because it is not the farm's to sweep: the loader skips it
# (`if (entry.name === "node_modules") continue`), check 6's nested arm skips it
# (`grep -v '/node_modules/'`), and a `*.test.js` inside an installed dependency is a
# THIRD-PARTY file `npm install` put there — npm does not re-extract an already-installed
# package, so deleting it corrupts the tree for good. Measured 2026-10-28 on this box:
# 169 of the farm's 232 name-matching files sit under `/node_modules/`. Widening the set
# without the prune grew a pre-existing over-delete by 10 files (`*.test.js` 9,
# `*.spec.js` 1); the prune removes the whole class instead of only the newly-added names.
# NB the sweep does NOT follow symlinked farm directories (`find` without `-L` does not
# descend into them), which is what keeps a symlink-farmed machine from having its own
# checkout's tracked test files deleted through the link.
while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  rm -f "$tf" && echo "    removed test file from live farm: ${tf#"$DEST/extensions/"}"
done <<< "$(find "$DEST/extensions" -type d -name node_modules -prune -o -type f \( -name '*.test.ts' -o -name '*.spec.ts' -o -name '*.test.js' -o -name '*.spec.js' \) -print 2>/dev/null)"

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

# ⛔ ATOMIC FARM INSTALL (#3991). `$DEST/scripts` is the directory the box EXECUTES, and a lane
# invokes its gates (`record-review.sh`, `admin-merge.sh`, `review-pr.sh`) WHILE a farm runs — this
# farm runs at session_start, and a re-run also happens during merges. A plain
# `cp -f "$src" "$dest"` opens the destination `O_TRUNC` and only then writes, so a concurrent
# reader can observe a zero-byte or half-written script: an attestation minted from half a file, or
# a rail that exits before it grades. A following `chmod +x "$dest"` on the DESTINATION leaves a
# second window in which the file exists but cannot be executed at all — the class
# `scripts/check-farm-drift.sh` names "NOT-EXECUTABLE … the same silent no-op".
# Copy to a sibling temp, make the TEMP executable, then `mv` it into place: same directory ⇒
# rename(2), so a reader sees either the previous complete file or the new one, never a torn one,
# and the `x` bit is already set at the instant the name appears. The `lib_srcs` leg has done
# exactly this since #1362 for exactly this reason; #3991 found that the six legs delivering the
# merge gates themselves were the ones that did not.
# Returns non-zero and leaves any previous copy UNTOUCHED (its temp removed), so every caller
# records the failure in `farm_missing` — a farm that reports success over a file it did not
# deliver is the #1931/#1924 class.
farm_install() {
  local src="$1" dest="$2" tmp
  # `mv -f file existing-directory` MOVES INTO it and exits 0, so a directory at `$dest` would
  # report a successful install while nothing landed at the path (the hazard farm-retire.sh:459
  # names). Refuse it here rather than trust `mv`'s status.
  if [ -d "$dest" ]; then
    echo "    farm_install: $dest is a DIRECTORY — refusing to install over it" >&2
    return 1
  fi
  tmp="$dest.tmp.$$"
  # stderr is NOT discarded on the copy or the rename: a cell running out of disk is a documented
  # failure mode, and `cp: No space left on device` is the only line that names it — the leg reports
  # THAT the install failed, not why.
  if cp -f "$src" "$tmp" \
     && chmod +x "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$dest"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

scripts_dir="$INFRA_ROOT/scripts/checkout-hygiene"
if [ -d "$scripts_dir" ]; then
  mkdir -p "$DEST/scripts/checkout-hygiene"
  copied=0
  hygiene_failed=0
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
    if farm_install "$f" "$dest"; then
      copied=$((copied+1))
    else
      echo "    scripts/checkout-hygiene farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
      farm_missing+="scripts/checkout-hygiene/$base (copy/chmod failed)"$'\n'
      hygiene_failed=$((hygiene_failed+1))
    fi
  done
  # Only a directory that declared NOTHING is "holds no farmable file"; when files declared and
  # every one failed, the per-file COPY/RENAME lines above are the diagnosis (#3991).
  if [ "$copied" -eq 0 ] && [ "$hygiene_failed" -eq 0 ]; then
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
# `DECLARED-*` / `SUMMARY:` lines, not this comment, for the current population. `cloud-cell-supervisor.sh`
# USED TO BE the one NAMED residual here: `cloud-cell-quiesce.sh` execs it through a variable-held
# prefix, so the derivation could not see that edge, and a fresh farm got the consumer without it.
# ⛔ THE DELIVERY RESIDUAL IS CLOSED BY THIS LANDING (#1938): the supervisor is FARMED below in
# `fleet_srcs`, beside the `cloud-cell-quiesce.sh` that calls it. It reaches the derived population
# through a DIFFERENT exec site — `install-controller-service.sh`'s `$(pwd)/cloud-cell-supervisor.sh` —
# which is why pinning it works even though the quiesce leg stays invisible to the scan.
# ⛔ AND THE QUIESCE'S OWN `<none found>` FALLBACK IS UNCHANGED BY THAT ENTRY — an earlier version of
# this paragraph said it was "no longer the only outcome on a fresh farm", which was FALSE and
# contradicted the correction recorded in the same series. `cloud-cell-quiesce.sh` tries
# `$REPO/scripts/…`, `$O/…` and two `/tmp/…/scripts/…` paths — it never looks in `$DEST/scripts/`, and
# nothing seeds the supervisor into `$O` (`cloud-cell-supervisor.sh`'s `seed_and_stamp` seeds from
# `$HARNESS`, which holds `orchestrator-harness/`, not the supervisor). So on a farm-only box the
# quiesce still prints `<none found — will start tmux directly>` in EVERY case, before and after this
# PR. The residual is the quiesce's CANDIDATE LIST, and it is recorded in
# `pi-bootstrap/tests/test-setup-no-nesting.sh`'s DECLARED RESIDUALS block. ⛔ Do not restate it here as
# fixed: two files disagreeing about one outcome is the exact failure this file's own P3 paragraph
# exists to stop.
#
# ⛔ ONE CONSTRAINT HERE IS NOT DERIVED AND MUST BE STATED: `pr-doctor.py` is listed BEFORE
# `objective.py` (#1872). The driver imports the classifier by path and `SystemExit`s when it finds
# an older copy, so the copy leg running in ARRAY ORDER means an interruption between the two leaves
# a NEW driver beside an OLD classifier — which refuses loudly — instead of the reverse window (NEW
# beat, OLD driver), which is SILENT because the assertion lives in the driver. The gate pins the
# order and the presence of both (mutation-verified: reversing them, or deleting either, fails).
# ⛔ `pr-doctor-trigger.py` SITS AFTER `pr-repair-loop.sh` FOR THE SAME ARRAY-ORDER REASON (#2700 C5).
# The trigger is the repair unit's event-driven FRONT END: its pass is
# `dirname($0)/pr-repair-loop.sh`, which owns every gate, the reap and the status row. An
# interruption between the two must therefore leave the PASS present without the trigger (the
# `REPAIR_INTERVAL_S` loop still runs, i.e. the old timer behaviour) rather than a trigger with no
# pass — which would look like a running repair service and start nothing. Because the array is
# copied in ORDER and `pr-repair-loop.sh` sits near the end of it, the trigger is appended AFTER it.
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
# FIVE of them; agent-infra#1874 then retired the lane-table dispatcher, which took TWO of the five
# out of the class with their only readers. The THREE that remain are the live class:
#   * `state/lane-confirm.py`  — read FAIL-SILENTLY (a non-zero exit is read as "screened, not
#                                stalled"; see the filed #1797); exec'd through a hardcoded
#                                /Users/<owner>/ absolute path at orchestrator-heartbeat.sh:336.
#   * `state/lane-triage.py`   — read FAIL-SILENTLY (`2>/dev/null || log "NOTE triage unavailable"`,
#                                orchestrator-heartbeat.sh:636); delivery owned by #1553.
#   * `state/lane-verdict.py`  — the verdict-KEY LOADER (`lane-actions.py:80,1530`); absent it
#                                degrades to `RULE` silently. Found by #1899's derivation, disclosed
#                                to the #1552 umbrella.
# ALL THREE of those fail SILENTLY — two by swallowing the error, one by degrading to a default — so
# an absent file is invisible in every case. That is why this class is tracked at all.
# RETIRED FROM THE CLASS by #1874 (the file stays on disk; nothing execs it, so nothing is owed):
#   * `state/queues/claim.py`          — its ONLY reader was the retired dispatcher's `claim_next()`
#                                        (`QueueReadError`, the one LOUD read in this class). Its
#                                        RELEASE paths (`free`/`done`) always ignored their result;
#                                        with the dispatcher gone that is the whole remaining
#                                        contract. Was untracked per #1567.
#   * `state/queues/refresh-queues.py` — its only exec site was the beat's queue-refresh step, removed
#                                        in the same landing (the queue existed to feed the
#                                        dispatcher). Was untracked per #1567.
# Both left `LANE_PRODUCERS_STATE_RESIDUAL` with their readers: an entry there for a producer nobody
# execs is STALE, and the guard's stale check FAILS on it (`test-setup-no-nesting.sh`).
# None of the five is in any farm list, and `test-setup-no-nesting.sh` names each with its owning
# issue so the class cannot grow a silent member.
# #2716/#2709 adds pr-repair-loop.sh and its installer: the cell's repair loop is a systemd unit whose
# ExecStart is the FARMED copy of the loop (a unit pointed at a checkout would be pointed at a directory
# the reaper is allowed to reclaim, and a unit pointed at a lane worktree is #2697's erased entry point).
# The loop execs the farmed `pr-doctor.py` + `pi-reap-worktrees.sh` beside it, and the installer renders
# the unit from this path. Farming them is what makes `eldato-pr-repair` installable on a cell without a
# `scripts/` checkout at all.
# ⛔ Keep this assignment on ONE line: `scripts/ci_runner_gate.test.sh` reads it with
# `sed -n 's/^fleet_srcs=(\(.*\))$/\1/p'`, so a wrapped array reads as EMPTY and that gate's
# membership assertion goes RED. (Loud, not silent — do not describe it as vacuous.)
# Tests are not farmed (the farm contract above): scripts/test_objective.py and
# scripts/test_turn_classify_state.py land in the repo and stay there.
# #1932 adds reap-lane-venvs.sh: a lane's `.venv` is a build artifact that belongs to a RUNNING lane
# (5 lanes held 7.3 GB on lane-1), and the RUNNERS reap it on exit — `lane.sh`/`fix-one.sh` resolve the
# reaper through spawn-gate.sh's `reap_lane_venv_path()`, which looks in $O, the harness dir,
# $AGENT_INFRA_PATH/scripts and THIS farm. Farming it is what makes the third-party-free lookup work on
# a cell and on a laptop alike: a cell runs the workers from `$O` (harness scripts only), not from a
# `scripts/` checkout, so without the farm the reaper would be "not found" and every lane would log a
# KEPT env. It is also the operator entry point for the one-off GC (`--gc --repo <path> --apply`).
# #1787 adds cleanup-stale-branches.sh: the daily com.tortoise.branch-reaper job
# runs the FARMED copy through the shared launcher with an explicit --repo, and
# install-launchd.sh's broken-target guard refuses the whole install when the
# farmed script is absent.
# #2032 adds disk-reaper.sh and its timer installer: the cell's HOURLY systemd pass runs the FARMED
# copy (the unit's ExecStart is rendered from this path), and the entry point resolves its three
# delegate owners through the same farm. A unit pointed at a checkout would be pointing at a
# directory the tool itself is allowed to reap — the farm is the stable path.
# #1987 adds pi-cache-reap.sh: the hourly com.eldato.pi-cache-reap job (Mac) and
# the cell controller's hourly cache bound (a cell has no launchd) both execute
# the FARMED copy — the machine-global uv/npm/pip caches are the sink that took
# pi-cell-3 to 258MB free, and neither the worktree reaper nor the supervisor's
# prune can reach `$HOME/.cache/uv`. Same broken-target rule: absent from this
# farm, the plist is refused.
# ⛔ RETIRING A NAME IS TWO EDITS IN ONE COMMIT (#1924): drop it from this array AND
# declare its deployed path (`scripts/<name>`) in pi-bootstrap/farm-retired.txt.
# Removing it here alone stops DELIVERY only — every box that already has a copy keeps
# it, executable, in $DEST/scripts. A name left in BOTH places is refused loudly by the
# UNFARM leg at the end of this file (the copy leg would just re-create it); dropping
# it here WITHOUT declaring it is caught by the snapshot check on the next sync.
# #2053 adds worktree-hygiene-sweep.sh: the 6-hourly com.tortoise.worktree-hygiene job
# executes the FARMED copy (its ProgramArguments name that path), and
# install-launchd.sh's broken-target guard refuses the WHOLE install — every other
# template included — when the farmed script is absent. It ships DISARMED: the unit is
# armed per box by `install-launchd.sh --arm-worktree-hygiene`, which itself runs the
# sweep's `--preflight` and refuses a box whose engine prerequisites do not resolve.
# Farming the sweep is what makes that preflight able to run at all (it is executed
# from the farmed path), so the arming can never bless a unit pointed at nothing.
# #1563's `queue_verdicts.py` was farmed BESIDE `queue-dispatch.py` because that dispatcher imported
# it BY PATH from its own directory; without it on the farm the sticky-verdict gate degraded to its
# loud VERDICT-GUARD UNAVAILABLE path on every lane. That dispatcher was retired and unfarmed by
# #1874, so the resolver left the farm in the same landing: it is a RECORD now, kept beside the
# dispatcher at `scripts/orchestrator-harness/retired/queue_verdicts.py` (still importable from
# there, which is what keeps the retired copy runnable as a record). A farmed file that no live step
# execs is a dependency the farm delivers to nobody.
# agent-infra#2834 farms bg-rescue-wip.sh: `run_agent` (`spawn-gate.sh`) now EXECS it on every terminal
# transition, and resolves it from `$O`, the harness dir's parent, `$AGENT_INFRA_PATH/scripts` and
# `~/.pi/agent/scripts` — THIS farm is the fourth of those. It is the only one that works on a box
# whose `$O` is the flat `scripts/orchestrator-harness/*` payload (the file lives one directory ABOVE
# that) and whose launcher does not export `$AGENT_INFRA_PATH` (launchd reads no shell profile):
# without it every at-risk lane recorded `rescue=UNAVAILABLE`, i.e. the rescue was loud and inert.
# agent-infra#3485 farms wip-sweep.sh BESIDE IT: the two are a pair (`wip-sweep.sh` classifies every
# worktree with `bg-rescue-wip.sh --verdict` and archives with `bg-rescue-wip.sh`, both resolved as
# SIBLINGS of its own directory), and `cloud-cell-quiesce.sh` — also farmed, and the one path that
# destroys a cell's disk — resolves the sweep from `$REPO/scripts`, the tree the PIN record
# (`$CELL_HOME/.harness-path`, a FILE holding a path) names, `$O` and THIS farm. Farming the pair FLAT
# is what makes the sibling lookup hold in every one of those homes; farming the sweep alone would leave
# it unable to classify, which is a refusal at startup (exit 3), not a silent clean pass. A sweep that
# nothing can run is #3485's defect one layer up.
# ⛔ THE GRAPH CLIENT IS FARMED BY `graph_srcs` (below), AND THAT ARRAY IS THE ONLY DELIVERY OF IT
# (agent-infra#3253). ⛔ It is NOT also listed in `fleet_srcs`: #3253 first put the pair there, #3374
# gave the hosted-graph fallback its own array (with a farm loop that reports a MISSING entry loudly),
# and a pair declared in BOTH is copied twice and appears twice in `farm_declared_rel` — a duplicate
# declaration is not extra safety, it is two answers to "who delivers this file".
# The owner's mandate (2026-11-02) — read the hosted Tortoise graph before researching, confirm
# direction in it before implementing, write the learning after — was UNEXECUTABLE on every box but
# the one it was written on, because `~/.pi/agent/scripts/tortoise-graph.sh` existed on no cell and
# on no fresh Mac: it had been HAND-COPIED onto the cells that carried it. Measured the same hour:
# cell-1's lane reported `GRAPH-UNREACHABLE(~/.pi/agent/scripts/tortoise-graph.sh: No such file or
# directory)` — the lane behaved correctly, the DEPLOYMENT did not exist, and the next bring-up on a
# fresh box would not have it either. A hand-copy is not a deployment (#3253; the same class as the
# hand-copied harness §11 in cloud-cell-bringup.sh).
#   * `tortoise_graph_client.py` is the EXECUTED half: `tortoise-graph.sh` runs it as the SIBLING
#     `$(dirname "$0")/tortoise_graph_client.py`. Both farm FLAT into $DEST/scripts/ (the
#     `graph_srcs` array), which is the layout that resolution needs — farming the .sh alone yields
#     a client whose first call dies with `can't open file`, a loud failure but a needless one (the
#     same sibling contract as lib_srcs/merge_gate_srcs above).
#   * The CREDENTIAL IT NEEDS IS NOT DELIVERED BY THIS FILE, and saying so is part of the fix: the
#     fleet has no secret store wired to it — `keys.env` on a cell and `pi-keys.env` on a Mac are
#     PUSHED BY HAND. So `TORTOISE_MCP_API_KEY` must be present there for the mandate to run, and
#     until it is, `cloud-cell-bringup.sh --check` WARNS by variable NAME (never its value) after the
#     layer is installed, while the client itself fails CLOSED with `GRAPH-UNREACHABLE(NO-KEY)` when
#     NEITHER name is set (it falls back to `TORTOISE_API_KEY` and lets the endpoint answer). That
#     fallback name USUALLY carries the same token — `skills/research/SKILL.md` records it measured
#     identical, Bearer -> 200 — so a box with only the alias may work fine; where the alias carries
#     the REST token instead (`scripts/tortoise-memory.mjs`'s key, /v1/points), the MCP endpoint may
#     REJECT it with HTTP 401. Neither outcome excuses leaving the MCP name unprovisioned.
#     A silent skip is the one outcome worse than the outage; that is what these two lines prevent.
#   * NOT a second client: `scripts/tortoise-memory.mjs` is the REST client (`TORTOISE_API_KEY`,
#     /v1/points) the research skill uses. Different transport, different key, different failure
#     contract — see scripts/tortoise-graph.sh's header.
# agent-infra#2374 adds registry-sync.sh: `cloud-cell-bringup.sh` runs it (the farmed copy is the
# one a cell finds) to converge the per-box review-record registry with the fleet's before lanes
# are dispatched, and `atomic-land.sh` runs it beside itself. A cell without it boots BLIND —
# every PR another box reviewed reads as unreviewed — which is the state #2374 measures.
# agent-infra#2403 adds install-runner-autoscale-timer.sh: the runner-pool converger
# (`scripts/orchestrator-harness/runner_autoscale.py`, merged in #2877/#2900) had NO scheduler, so a
# box kept whatever runner count it happened to have — pi-cell-1 measured 5 live against a ceiling of
# 3 on 8 cores while tortoise CI sat at 34 queued. The FARMED installer is the arming surface a
# bring-up or an operator reaches for (`~/.pi/agent/scripts/install-runner-autoscale-timer.sh --arm`).
# It resolves the converger from the CHECKOUT by absolute path — the farm is FLAT
# (`$INFRA_ROOT/scripts/<name>`) and the converger lives under `scripts/orchestrator-harness/`, so it
# is not itself farmed; the unit names the checkout copy, which is the artifact #2877 landed and the
# path this installer verifies before rendering. It ships DISARMED: `--install` renders a dry-run
# unit and timer, and `--arm` (a dated owner step) is what lets the pass ACT.
# agent-infra#2413-audit farms the three jobs that were ARMED AND DEAD on the orchestrator box
# (measured 2026-11-03T23:30Z): com.eldato.worker-supply (runs=1766, last exit code=126),
# com.eldato.objective-reminder (runs=44, 126) and com.eldato.controller-watchdog (126). Their
# templates named `{{AGENT_INFRA_PATH}}/scripts/…`, which is `~/Documents/GitHub/agent-infra` on the
# documented default box — a tree macOS TCC denies to every launchd-spawned process, so `/bin/bash`
# logged `Operation not permitted` and exited 126 on every tick while `launchctl list` said "loaded".
# Those three templates now name the FARMED path, which makes this array the delivery mechanism the
# units depend on (#2053's rule for worktree-hygiene-sweep.sh, applied to the same failure).
# ⛔ NESTED NAMES ARE KEPT NESTED (`orchestrator-harness/…`) BECAUSE THE TEMPLATES NAME THAT PATH.
# templates/launchd/com.eldato.worker-supply.plist and com.eldato.controller-watchdog.plist render
# `{{HOME}}/.pi/agent/scripts/orchestrator-harness/<name>`, and `install-launchd.sh` REFUSES a unit
# whose target does not resolve — so flattening the farm would leave both units unrunnable (exit 1,
# nothing installed). The copy leg creates the parent directory for exactly this reason.
# ⚠️ NOT because of `watchdog-loop.sh`'s `$SELF_DIR/../cloud-cell-supervisor.sh` fallback. An earlier
# draft of this comment claimed the nesting preserved that sibling, and it was FALSE THEN:
# `cloud-cell-supervisor.sh` was in NO farm array, so the fallback resolved
# `$SELF_DIR/../cloud-cell-supervisor.sh` to `$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh` and
# found nothing nested OR flat. A justification nobody re-derived is how a false claim outlives the
# shape it described (review P2-G of #3413). No line-numbered claim about any OTHER script belongs
# here for the same reason.
# ⛔ AND THAT FALLBACK NOW RESOLVES — stated PRECISELY, because the first version of this paragraph
# over-claimed it. `watchdog-loop.sh` is farmed NESTED, so its `$SELF_DIR` is
# `$DEST/scripts/orchestrator-harness` and `$SELF_DIR/../cloud-cell-supervisor.sh` is
# `$DEST/scripts/cloud-cell-supervisor.sh` — the file `fleet_srcs` now writes. `[ -f ]` therefore
# becomes true where it was false, and the cell arm's `if [ -n "$sup" ] && [ -f "$sup" ]` can now take
# the `$sup start` branch (`RESTART_VERB="$sup start"`), a failure in which is reported as
# `RESTART-FAILED` naming that verb — never `verb=unknown`.
# ⛔ BUT NO SHIPPED CONSUMER REACHES THAT FALLBACK, so NO DEPLOYED WATCHDOG CHANGES BEHAVIOUR. The two
# fallbacks are guarded by `[ -n "$sup" ] ||`, and the shipped systemd cell unit always sets the
# variable that guard tests: `install-cell-timers.sh` defaults
# `SUPERVISOR="${SUPERVISOR:-$INFRA_ROOT/scripts/cloud-cell-supervisor.sh}"` (the LAYER CHECKOUT, not
# the farm), renders it into `templates/systemd/eldato-controller-watchdog.service` as
# `Environment=SUPERVISOR={{SUPERVISOR}}`, and `cloud-cell-bringup.sh` passes no `SUPERVISOR` in its
# env array — so that default is what every armed cell gets. On macOS the `com.eldato.controller-watchdog`
# plist sets no `SUPERVISOR` either, but Darwin takes the `launchctl` arm, not this one. The arm becomes
# live only for an invocation whose `SUPERVISOR` is UNSET: an ad-hoc/manual run, or a future installer
# that stops hard-coding the checkout path.
# ⚠️ AND ONE PRE-EXISTING FRAGILITY IS VISIBLE FROM HERE, not introduced here: because the guard is
# `[ -n "$sup" ]` (non-empty) and not `[ -f "$sup" ]` (readable), a `SUPERVISOR` that NAMES a path the
# cell cannot read SHORT-CIRCUITS both fallbacks — so when the layer checkout is reaped the arm still
# refuses even though a farmed copy now exists. Changing that guard is a restart-path decision of its
# own; it is recorded here, not taken, so nobody reads this farm entry as having fixed it.
# The nesting is NOT justified by this fallback — the templates naming the nested path is the whole
# reason, above.
# agent-infra#2281 §1 adds pr-doctor-machine.sh: the MACHINE-scoped entry point the
# `com.tortoise.pr-doctor` unit execs. Before it the unit asserted ONE repo in its argv
# (`--repo daniel-ospina/tortoise`), so a box running two repos graded exactly one and the second
# repo's queue was read by nothing. The wrapper reads the machine repo SET (lib_srcs' repo-set.sh,
# below) and grades every repo in it; with no set it runs the single-repo form and LOGS
# `DEGRADED — NO-REPO-SET` every pass. Farming the unit's target is what makes it resolvable on a
# fresh box; install-launchd.sh hard-fails the job otherwise (the same rule every farmed job gets).
# ⛔ agent-infra#2698 (armed 2026-11-07) adds conflict-rebase.py, conflict-rebase-timer.sh and
# install-conflict-rebase-timer.sh. THE PASS AND ITS TIMER WRAPPER MUST FARM TOGETHER: the wrapper
# resolves its bot as `<its own dir>/conflict-rebase.py`, so farming one without the other installs a
# unit whose every tick exits 127 while `list-timers` reads green. Before this line NEITHER was on a
# cell, which is why a capability that had shipped, been tested and carried a header was scheduled on
# zero boxes — the installer could not even find the thing it was meant to install.
fleet_srcs=(fleet-cost-weekly.sh fleet-cost-report.sh fleet-schedule.py conflict-rebase.py conflict-rebase-timer.sh install-conflict-rebase-timer.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh pi-task-session-prune.sh pi-cache-reap.sh pi-reap-orphans.sh pi-reap-worktrees.sh reap-lane-venvs.sh venv-real-cost.py reap-abandoned-worktrees.sh reap-duplicate-installs.sh reap-runner-work.sh disk-reaper.sh disk-reaper-run.sh disk-reaper-deployed-check.sh install-disk-reaper-timer.sh harness-apply-pass.sh install-harness-apply-timer.sh install-runner-autoscale-timer.sh pi-reap-worktrees-launchd.py worktree-disk-probe.sh cleanup-stale-branches.sh ci_runner_gate.sh ask-owner.py beta-progress.py cadence-nudge.sh cadence-timer.sh child-check.py cloud-cell-quiesce.sh install-controller-service.sh cloud-cell-supervisor.sh deploy-crossbox.sh deploy-mac-orchestrator.sh goal-state.py lane-actions.py lane-arm.sh install-lane-arm-timer.sh lane-guard.py lane-read.py lane-scan-fallback.sh lane-watchdog.py lane-wip.py live-workspaces-publisher.py merge-queue.py orch-send.sh orchestrator-heartbeat.sh orphan-reap.py pr-doctor-machine.sh pr-doctor.py objective.py probe-one.py publish-live-workspaces.py safe-send.sh seed-goal-map.py tree-cpu.py _bounce_state.py turn-classify.py turn-end.py unblock-lane.sh undelivered-answers.py worktree-hygiene-sweep.sh registry-sync.sh pr-repair-loop.sh install-repair-service.sh pr-doctor-trigger.py bg-rescue-wip.sh wip-sweep.sh objective-reminder.sh orchestrator-harness/worker-supply.sh orchestrator-harness/watchdog-loop.sh)
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
  # A NESTED entry (orchestrator-harness/worker-supply.sh) needs its parent: `cp -f` into a missing
  # directory fails, and the loop would report the farm as complete. Same rule the merge-gate farm
  # below applies to `gh-shim/gh`.
  if ! mkdir -p "$(dirname "$dest")"; then
    farm_missing+="scripts/$base (cannot create $(dirname "$dest"))"$'\n'
    continue
  fi
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  if farm_install "$f" "$dest"; then
    fleet_copied=$((fleet_copied+1))
  else
    echo "    scripts fleet farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    farm_missing+="scripts/$base (copy/chmod failed)"$'\n'
  fi
done

# ── the orchestrator MCP's own harness module ────────────────────────────────────────────────
# `lane_registry.py` lives in `scripts/orchestrator-harness/` but is farmed FLAT into
# `$DEST/scripts/` deliberately: that flat path is one of the candidate locations the MCP server
# itself searches (`_candidate_paths` in mcp-servers/orchestrator/server.py), so the install
# layout and the server's own lookup cannot drift.
# ⛔ It is NOT a member of `fleet_srcs`. That array resolves every source as
# `$INFRA_ROOT/scripts/$base`, so listing a file that lives one directory DOWN made the install
# treat it as missing, exit 1, and take the whole farm — guards, skills, every assertion after it —
# down with it. Measured on #3486: `FAIL: install exited 1`, then `GUARD MISSING: …` × 6.
# A `src` subdirectory with a flat `dest` is exactly what the installer's own reader models, so the
# test's independent expectation stays a superset of this declaration with no change in semantics.
#
# ⛔ `cloud-cell-doctor.sh` BELONGS IN THIS ARRAY, and the array name is about the SOURCE DIR, not
# about MCP: this is the repo's only src-one-down / dest-flat farm, and the doctor needs exactly that
# (`scripts/orchestrator-harness/cloud-cell-doctor.sh` → `$DEST/scripts/cloud-cell-doctor.sh`). That
# destination is the one `cloud-cell-supervisor.sh`'s `doctor_path()` resolves as
# `$(dirname "$SUP_SELF")/cloud-cell-doctor.sh`, and the supervisor is farmed here FLAT — so without
# this entry a fresh `$DEST/scripts` holds a supervisor whose every role `die`s "cloud-cell-doctor.sh
# not found" (measured shape, #1552/#1899). It was EXEMPTED under #3530 when this array was believed
# closed to it; the exemption claimed "no FARM_ARRAYS entry can carry it", which was false — the
# installer loop below is content-agnostic, and `cell-install.sh:FARM_LAYOUT` already maps this array
# to `scripts/orchestrator-harness → scripts`, so a cell gets it too. Measured 2026-11-07.
# ⚠️ What farming flat does NOT carry is the doctor's OPTIONAL harness siblings (`lane-reap.sh`,
# `rail-refusal.sh`, `live-ownership.sh`), which it resolves from `$SELF_DIR` — still absent on a
# farm-only box, where they degrade rather than die. ⛔ `repo-slug.sh` IS NO LONGER ONE OF THEM: it is
# a PRODUCER the doctor actually execs, so degrading was a farm gap, not an accepted shape — see the
# array below.
# ⛔ THE CANDIDATE ORDER IS NOT "FARMED COPY LAST", and an earlier version of this comment said it
# was. `doctor_path()`'s loop (`cloud-cell-supervisor.sh`) tries, in order: `$O/cloud-cell-doctor.sh`,
# `$(dirname "$SUP_SELF")/orchestrator-harness/cloud-cell-doctor.sh`,
# `$(dirname "$SUP_SELF")/cloud-cell-doctor.sh`, `${HARNESS:-}/scripts/orchestrator-harness/...`,
# `${HARNESS_PIN_DIR:-}/scripts/orchestrator-harness/...`. `$(dirname "$SUP_SELF")` IS `$DEST/scripts`
# for the farmed supervisor, so this entry lands THIRD OF FIVE — ahead of BOTH pinned-harness
# candidates, not behind them.
# ⚠️ THE ACCEPTED EFFECT, named rather than hidden: on an UNSEEDED cell (`$O` not yet populated) with
# a pinned harness holding a different doctor, the farmed copy now WINS over the pinned one — it
# SHADOWS it. That is acceptable here because (a) `$O`, the seed the provenance record describes,
# still wins on a started cell, which is every merge/doctor run that matters; and (b) the flat copy is
# rewritten by every `setup.sh` run, so divergence means the harness was updated without re-running
# the installer — a state the farm is supposed to be the authority on. ⛔ This is therefore NOT a
# reason to reorder `doctor_path()`: that order encodes #2306 (the pinned harness must be consulted at
# all) and reordering it is a design change, not a comment fix.
# Before this entry candidate 3 was simply ABSENT on a farm-only box, so nothing shadowed — and the
# supervisor's every role `die`d.
# ⛔ agent-infra#1899/#1552: `repo-slug.sh` IS A PRODUCER, NOT A SIBLING TO DEGRADE ON. The doctor
# (`cloud-cell-doctor.sh`, farmed flat into `$DEST/scripts/`) resolves it at `:160` as
# `${O%/}/repo-slug.sh $SELF_DIR/repo-slug.sh`, and `$SELF_DIR` IS `$DEST/scripts` for the farmed copy —
# so a farm-only box had the consumer and not the executable it calls, which `test-setup-no-nesting.sh`
# reports as `producer(s) exec'd by a farmed consumer and DELIVERED BY NOTHING: repo-slug.sh` (#1552).
# Same src-one-down/dest-flat shape as the two above, and the same reason: `repo-slug.sh` lives in
# `scripts/orchestrator-harness/`, and its destination is the FLAT `$DEST/scripts/` that the doctor
# already searches. ⛔ NOT THE BRING-UP'S WARNING: `cloud-cell-bringup.sh` resolves its own copy from
# `${BRINGUP_HERE}/orchestrator-harness/repo-slug.sh` or `${CELL_HOME}/orchestrator/repo-slug.sh`
# (`:168-169`), neither of which is `$DEST/scripts` — so its "repo identity UNVERIFIED" walk is
# untouched by this entry and needs its own fix. An earlier revision of this comment claimed the
# warning was the degradation this entry removes; it is not, and the paths were measured.
# ⛔ `brief-gate.sh` (#3958) IS A PRODUCER THE FARM MUST CARRY, and it is the one that decides whether
# the revalidation is a check or a formality. `worker-supply.sh` is farmed by `fleet_srcs` (nested dest
# `$DEST/scripts/orchestrator-harness/`), and its `brief_gate_path()` walks the DISPATCHER's four-rung
# ladder — `$O`, its own directory, `$AGENT_INFRA_PATH/scripts/orchestrator-harness/`, and the FLAT
# `$HOME/.pi/agent/scripts/brief-gate.sh`. On a farmed box with no checkout, three of those four cannot
# exist and the FLAT one is the only rung that can: deliver it anywhere else and `brief_verdict()`
# answers 78 ("no brief-gate.sh on any resolved root") on every pass, so #3958's revalidation degrades
# to the fall-through and the fossil is re-offered exactly as before. That is the
# `producer(s) exec'd by a farmed consumer and DELIVERED BY NOTHING: brief-gate.sh` failure (#1552/#1899)
# measured by `pi-bootstrap/tests/test-setup-no-nesting.sh`, which is why this entry is here and not in
# `fleet_srcs`: the destination this consumer searches is the FLAT `$DEST/scripts/`, the same
# src-one-down/dest-flat shape `repo-slug.sh` above already takes. Its one optional dependency,
# `scripts/lib/bounded.sh`, is already farmed by `lib_srcs` and resolved from the sibling `lib/`.
mcp_harness_srcs=(lane_registry.py cloud-cell-doctor.sh repo-slug.sh brief-gate.sh)
for base in "${mcp_harness_srcs[@]}"; do
  farm_declared_rel+="scripts/$base"$'\n'
  f="$INFRA_ROOT/scripts/orchestrator-harness/$base"
  if [ ! -f "$f" ]; then
    farm_missing+="scripts/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then
    rm -f "$dest"
  fi
  if ! farm_install "$f" "$dest"; then
    echo "    scripts mcp-harness farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    farm_missing+="scripts/$base (copy/chmod failed)"$'\n'
  fi
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
# #1921 adds a FOURTH sibling: the VENDORED transcript-pattern producer
# (`scripts/lib/transcript-patterns.sh`) that the farmed `session-postmortem.sh`
# execs for the Transcript Patterns section of every retrospective. Before this,
# that producer was resolved from an absolute `/Users/<owner>/…/eldato/scripts/`
# path in ANOTHER checkout — so on every box but the owner's (and on every Linux
# cell) the section degraded to a placeholder inside a generated report. Farming
# it beside the consumer is what makes the section exist everywhere the consumer
# does (same `lib/` → `$DEST/scripts/lib/` layout as the three above; the
# consumer resolves `$(dirname "${BASH_SOURCE[0]}")/lib/transcript-patterns.sh`).
# #2046 adds a FIFTH: `scripts/lib/bounded.sh` is the ONE bounded-execution
# helper for the reaper family. `disk-reaper.sh` and `pi-reap-worktrees.sh` both
# source it and both REFUSE at startup (exit 3) without it, because a probe with
# no watchdog is a probe that can hang the host they exist to unload. Farming the
# reapers WITHOUT this sibling re-arms the hourly pass as a startup refusal; on a
# Mac that is strictly better than the pre-#2046 behaviour it replaces (every
# class fail-closed with `timeout: command not found` while the pass completed).
# #1187 adds `cmux_payload.py`: `orch-send.sh` (farmed above) resolves its payload-integrity
# check as `$(dirname "${BASH_SOURCE[0]}")/lib/cmux_payload.py`. Farming the sender WITHOUT the
# checker makes EVERY orchestrator dispatch REFUSE with `NOT SENT` (exit 7) and type nothing —
# a fail-closed FALSE BLOCK on every lane order, which is the right direction and still a box that
# cannot dispatch. Farm them together. (main meanwhile added `live-paths.sh`; both are carried.)
# agent-infra#2281 §4 adds repo-set.sh: the machine's repo SET and the ONE reader of it. Its consumer
# `pr-doctor-machine.sh` (fleet_srcs, above) resolves it as `$(dirname "${BASH_SOURCE[0]}")/lib/repo-set.sh`
# — the same sibling contract and the same `lib/` → `$DEST/scripts/lib/` layout as the seven above.
# Farming the wrapper WITHOUT this reader is a machine-wide unit that refuses every pass with a named
# farm gap (see the wrapper's header), so the pair is delivered together.
# agent-infra#3453 adds cell-home.sh: the ONE derivation of a cell's home. Every unit renderer and
# every script that gives a lane its HOME now CONSUMES it instead of spelling `/tmp/cell-home` (the
# legacy volatile home) or `/home/cmux` as a default, so a farm that omitted this file would leave
# every consumer on its named `$HOME` fallback — and, worse, would leave the RESOLVER absent while the
# consumers that source it look healthy. Farm it with them.
lib_srcs=(pid-identity.sh diff-normalize.py beat-pair.sh bounded.sh transcript-patterns.sh live-paths.sh cmux_payload.py repo-set.sh cmux-dispatch-path.sh cell-home.sh)
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
  # Atomic install (#1362 review, now `farm_install` for every leg — #3991): copy to a sibling
  # temp then rename, so a concurrent reader (record-review.sh runs during merges; this farm runs
  # at session_start) can NEVER observe a truncated/zero-byte lib. An empty normalizer exits 0
  # printing nothing, which would hash the EMPTY string into a constant digest — a false accept —
  # so the reader also guards `[ -s ]`.
  if farm_install "$f" "$dest"; then
    lib_copied=$((lib_copied+1))
  else
    echo "    scripts lib farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    lib_failed=$((lib_failed+1))
  fi
done
# The summary NAMES what it farmed, DERIVED from the array (#1921): a hand-kept list here drifts
# the moment a lib is added, and test-setup-no-nesting.sh asserts every declared lib is named —
# so a stale list turns a correct farm into a red, or worse, names a lib it did not copy.
lib_names="$(printf '%s + ' "${lib_srcs[@]}")"; lib_names="${lib_names% + }"
if [ "$lib_failed" -gt 0 ]; then
  echo "    scripts lib farm: $lib_copied copied, $lib_failed FAILED/MISSING ($lib_names, #1178/#1362/#1897/#2046/#1921)" >&2
  # #1924: a lib that DECLARED but did not land is an INCOMPLETE checkout, not a
  # tolerated skip — record it so the run fails before the UNFARM leg instead of
  # delivering consumers whose sibling is absent.
  farm_missing+="scripts/lib/ ($lib_failed declared sibling(s) FAILED or MISSING)"$'\n'
else
  echo "    scripts lib farm: $lib_copied copied ($lib_names, #1178/#1362/#1897/#2046/#1921)"
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
# claim_lanes.py joined in #1777: the ref-claim registry READER. An orchestrator lane
# (`pi -p --no-session`) writes no transcript and no cmux record, so it is in no
# population lane_liveness.py can build; this reader reads the holder-authored
# `refs/claims/<pr>-<sha12>` refs and feeds the SAME verdict function
# (liveness.py, farmed just above). It must sit BESIDE liveness.py for the same
# reason fleet-health.py does: it imports that sibling classifier. It is NOT
# invoked by the launchd job (no network read behind the TCC wall) — the farm is
# for the operator/agent CLI.
# pr_state.py (#2866): the PR STATE ROUTER — the ONE answer to "what does this PR need next, and
# should anything be running for it right now". Farmed because the harness actors that consume it
# (`pr-sickness.sh`, `lane-merge.sh`, via `scripts/orchestrator-harness/pr-state.sh`) live in `$O`,
# which is NOT a checkout of this repo: without the farm the seam resolves nothing there and every
# actor prints `router unavailable` — the wiring would exist and never run.
fleet_tools=(liveness.py lane_liveness.py claim_lanes.py fleet-health.py map-sessions.py pr_state.py)
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
  if farm_install "$f" "$dest"; then
    tools_copied=$((tools_copied+1))
  else
    echo "    scripts/fleet farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    farm_missing+="scripts/fleet/$base (copy/chmod failed)"$'\n'
  fi
done
echo "    scripts/fleet farm: $tools_copied copied (lane-liveness + claim-lanes + fleet-health + map-sessions + pr-state, #1178/#1777/#2866)"

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
# review-pr.sh rides the SAME farm for the same reason, plus one of its own: it is
# the seam a LANDER types (`scripts/review-pr.sh <PR>`), and on a cell the
# `scripts/` checkout is not where an agent works — `~/.pi/agent/scripts/` is, which
# is where the code-review skill and the lane briefs already point. Farmed WITHOUT
# its recorder is still correct (the script falls back to the sibling, then to
# $DEST/scripts/record-review.sh, and REFUSES loudly when neither is executable),
# but the two are one workflow and belong in one farm.
#
# #984 — THE ARGV-LEVEL `gh` SHIM AND THE EVIDENCE VERIFIER IT DEMANDS. The review-enforcer
# prepends `EXTENSION_DIR/../../scripts/gh-shim` to PATH on every bash call
# (`resolveGhShimDir()`), and the SAME expression means two different things by platform:
#   * on a laptop the extensions are kept as farm SYMLINKS into this checkout (the loop above),
#     so node's module resolution follows the link and `../..` IS the checkout — the shim is
#     found without ever being installed;
#   * on a cloud cell the extensions are real COPIES, so `../..` is `~/.pi/agent` and the shim
#     must exist at `~/.pi/agent/scripts/gh-shim/gh`.
# Nothing farmed that directory, so every cell lane logged
#   `#984 argv-level gh shim not found — only the string scanner is active`
# and ran the merge gate DEGRADED — no argv inspection at all, which is the documented ceiling
# of a string scanner (`--ad""min`, `$'--admin'`, `xargs {}`) — while the box reported its layer
# verified. Farming the shim HERE is what makes the two platforms the SAME gate rather than two
# copies that drift: cell-install.sh PARSES these arrays and keeps no list of its own.
# `gh-shim/gh` is a NESTED name (the shim lives in a directory of its own), and the verifier must
# land as its `../verify-admin-merge-evidence.sh` sibling — the shim resolves the verifier from
# its own location and fails CLOSED without it, so shipping one without the other produces a gate
# that refuses EVERY admin merge.
#
# ⛔ `admin-merge.sh` IS THE SAME RULE ONE LEVEL DEEPER, and an earlier head of the PR that farmed
# it BROKE it: the rail resolves THREE helpers from `$SELF_DIR` and REFUSES when they are missing,
# so landing the rail alone produces a rail that exits 1 immediately on a farm-only box.
#   * `scripts/admin-merge.sh` `CFS="${ADMIN_MERGE_FAILURE_SET_SH:-$SELF_DIR/ci-failure-set.sh}"`,
#     then `[ -x "$CFS" ] || [ -f "$CFS" ] || { say_err "admin-merge: parser not found at $CFS";
#     exit 1; }` in `main()` — reached on EVERY invocation carrying a PR number;
#   * `EXEMPTION_PY="$SELF_DIR/ci_exemption.py"`, refused by name when absent;
#   * `bash "$SELF_DIR/ci-workflow-pr-evaluable.sh"` at three call sites.
# `git grep` over `pi-bootstrap/` found NONE of the three in ANY farm array before this line, so the
# doctor's last-resort rail (`cloud-cell-doctor.sh`, which resolves `admin-merge.sh` beside itself
# and from `$CELL_HOME/.pi/agent/scripts/`) went from ABSENT to PRESENT-BUT-INERT — the #1552 class
# still open for this one producer, just one level down. The trio is a COMPLETE closure, not a
# guess: `ci-failure-set.sh` resolves only `ci_exemption.py` beside itself, and
# `ci-workflow-pr-evaluable.sh` and `ci_exemption.py` resolve nothing further (`rg` for
# `SELF_DIR|dirname.*BASH_SOURCE|__file__` returns no resolution site in either).
# ⛔ AND THE DEPENDENCY IS NOT STATICALLY ATTRIBUTABLE, which is why the gate could not see it: the
# call is spelled `"$BASH" "$CFS"`, not a producer-shaped command, so no consumer scan can find it.
# A farm entry therefore has to be justified by reading the resolved consumer, exactly as this list
# does for `gh-shim/gh` above.
merge_gate_srcs=(record-review.sh review-pr.sh gh-shim/gh verify-admin-merge-evidence.sh admin-merge.sh ci-failure-set.sh ci_exemption.py ci-workflow-pr-evaluable.sh)
# The hosted-graph FALLBACK half (graph-mcp-provision). The MCP entry in
# templates/.mcp.base.json is the PRIMARY path; this script is what a lane can still use when
# the MCP client is unavailable from inside the session (#10605: ${TORTOISE_MCP_API_KEY} expanded
# at process start, so the client sends an EMPTY Bearer while the same key authenticates a
# direct POST). It existed only as a hand-written file on two boxes and in no repo, so a
# rebuilt machine lost it silently — farming it is what makes it durable.
# Keep this array ONE LINE: pi-bootstrap/cell-install.sh parses every top-level `name=(...)`
# array in this file as a FARM and dies on one it cannot map (FARM_LAYOUT).
graph_srcs=(tortoise-graph.sh tortoise_graph_client.py)
mkdir -p "$DEST/scripts"
merge_gate_copied=0
merge_gate_names=""
for base in "${merge_gate_srcs[@]}"; do
  farm_declared_rel+="scripts/$base"$'\n'
  f="$INFRA_ROOT/scripts/$base"
  if [ ! -f "$f" ]; then
    farm_missing+="scripts/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/$base"
  # A NESTED farm entry (gh-shim/gh) needs its parent directory: `cp -f` into a missing parent
  # fails, and the rest of the farm would still report success.
  mkdir -p "$(dirname "$dest")" || { echo "ERROR: cannot create $(dirname "$dest") for farm entry $base" >&2; exit 1; }
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  # ⛔ A SWALLOWED `chmod` FAILURE IS A SILENTLY NON-EXECUTABLE LANDER SEAM (P3, fresh review of
  # #2288). The lane brief and the code-review skill tell a lander to TYPE this path
  # (`~/.pi/agent/scripts/review-pr.sh <PR>`, no `bash`), so a copy that inherits a restrictive
  # umask without `x` — with the failure discarded by `|| true` — ships a seam nobody can invoke,
  # and the farm test (existence + byte-equality only) stays green. Assert it instead: since #3991
  # `farm_install` sets the bit on the TEMP before the rename, so a failed `chmod` fails the whole
  # install and the previous copy stays in place (and a lane merging at that instant keeps a
  # runnable gate rather than this PR's half-delivered one).
  if farm_install "$f" "$dest"; then
    merge_gate_copied=$((merge_gate_copied+1))
    merge_gate_names+="${merge_gate_names:+, }$base"
  else
    echo "    ⚠️  COPY/RENAME FAILED for $f — the lander seam would not be executable" >&2
    farm_missing+="scripts/$base (copy/chmod failed)"$'\n'
  fi
done
# DERIVED from the array, never hard-coded: a summary that omits a name it farmed misreports the
# farm, and the suite pins every declared entry against this line (#1897 precedent).
echo "    scripts merge-gate farm: $merge_gate_copied copied (${merge_gate_names:-none} — #562, #984, #2287)"

# ── the hosted-graph FALLBACK farm (graph-mcp-provision) ─────────────────────
# `tortoise-graph.sh` (+ its python client) is what a lane falls back to when the MCP client
# cannot reach the graph from inside the session (#10605). It was hand-written on two boxes and
# existed in NO repo, so a rebuild lost it in silence — the first fleet-wide attempt to put the
# MCP on the cells found it absent on two of three. Farmed here so it is DELIVERED, not remembered.
# Same real-copy + chmod discipline as the merge-gate farm above, and the same reason: the
# documented invocation TYPES the path, so a copy without `x` is a seam nobody can run.
graph_copied=0
graph_names=""
for base in "${graph_srcs[@]}"; do
  farm_declared_rel+="scripts/$base"$'\n'
  f="$INFRA_ROOT/scripts/$base"
  if [ ! -f "$f" ]; then
    echo "    scripts graph farm: MISSING $f — the hosted-graph fallback would not land" >&2
    farm_missing+="scripts/$base"$'\n'
    continue
  fi
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then rm -f "$dest"; fi
  if farm_install "$f" "$dest"; then
    graph_copied=$((graph_copied+1)); graph_names+="${graph_names:+, }$base"
  else
    echo "    scripts graph farm: COPY/RENAME FAILED for $f — leaving any previous copy in place" >&2
    farm_missing+="scripts/$base (copy/chmod failed)"$'\n'
  fi
done
echo "    scripts graph farm: $graph_copied copied (${graph_names:-none} — hosted-graph fallback, graph-mcp-provision)"

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
  # Atomic like the script farm (#3991): `$DEST/bin/pi` is the name EVERY lane spawn resolves to
  # (it is first on PATH), so a truncated or not-yet-executable copy here is a broken `pi` for any
  # session starting at that instant — the same two windows, on the binary that starts every lane.
  if farm_install "$SPAWN_GATE_SRC" "$DEST/bin/pi"; then
    echo "    pi spawn-point gate installed at $DEST/bin/pi (#1884)"
  else
    echo "    ⚠️  COPY/RENAME FAILED for $SPAWN_GATE_SRC — $DEST/bin/pi left exactly as it was" >&2
    farm_missing+="bin/pi (copy/chmod failed)"$'\n'
  fi
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
# Every farm above is COPY-ONLY: `farm_install` writes the names an array lists (its only
# undeclared output is its own `<name>.tmp.<pid>` scratch, which `check-farm-drift.sh`
# recognises) and does nothing at all to a name it does not list. `[ -f "$f" ] || continue` therefore skips
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
  echo "ERROR: the farm is INCOMPLETE — name(s) this checkout DECLARES were not delivered:" >&2
  while IFS= read -r missed; do
    [ -n "$missed" ] && echo "         $missed" >&2
  done <<<"$farm_missing"
  echo "       Two causes, and they do NOT have the same fix: a name ABSENT from $INFRA_ROOT (an" >&2
  echo "       incomplete checkout), or a COPY/RENAME that FAILED — permissions, a full disk, a path" >&2
  echo "       that is not a regular file — which cp/mv name on their own stderr line above." >&2
  echo "       Nothing below ran: the UNFARM leg, launchd convergence, the shell-profile wiring." >&2
  echo "       A farm that delivers less than it declares is how the repo and the machines drift" >&2
  echo "       apart in silence (#1931) — and, on the UNFARM side, how a file that was never" >&2
  echo "       deployed comes to look retired. For an absent name: re-run from a complete checkout" >&2
  echo "       (git status). For a failed install: fix $DEST (space/permissions), then re-run." >&2
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

# TORTOISE_HOME — for LOCAL / self-hosted tortoise tooling only.
# ⛔ The BASE MCP entry no longer uses it (graph-mcp-provision): templates/.mcp.base.json
# declares the HOSTED server (`https://api.premiselabs.co/mcp/`, `Bearer ${TORTOISE_MCP_API_KEY}`),
# which needs no checkout, no venv and no local FalkorDB. This probe is kept because other
# local tooling still reads the variable and removing a variable the fleet may use is a bigger
# change than this one — but the message below must not be allowed to imply the graph is wired
# because TORTOISE_HOME exists. The graph needs TORTOISE_MCP_API_KEY in ~/keys.env.
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
  echo "    TORTOISE_HOME wired (LOCAL/self-hosted tortoise tooling) — the graph MCP itself is the HOSTED server and needs TORTOISE_MCP_API_KEY in ~/pi-keys.env (interactive shells) or ~/keys.env (lanes a controller spawns)"
else
  echo "    note: TORTOISE_HOME not set and no tortoise checkout found — local/self-hosted tortoise tooling unavailable (the base MCP entry does not need it; it needs TORTOISE_MCP_API_KEY in ~/pi-keys.env for an interactive shell, or ~/keys.env for lanes)"
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

# ── 7b. THE DEPLOY VERIFIES ITSELF (tortoise#10114) ───────────────────────────────────────────
# Every farm leg above copies from $INFRA_ROOT. A copy that has just been written is NOT evidence
# that the DEPLOYED bytes are the SHIPPED bytes — and it is no evidence at all when $INFRA_ROOT is
# not the tree this box is pinned to. That is exactly how the original defect survived a "successful"
# install: the farm refreshed from an Aug-7 checkout while the box was pinned elsewhere, so every
# file it wrote was stale and NOTHING said so. launchd then executed that stale copy
# (the `com.tortoise.pr-doctor` unit targets $DEST/scripts/pr-doctor-machine.sh, which `exec`s the
# `pr-doctor.py` beside it — one farm, one stale-bytes class) and the whole PR-repair fleet
# dispatched 0 orders for nine hours while each pass reported rc=0.
#
# So the deploy ends by GRADING ITS OWN RESULT: `check-farm-drift.sh` compares every deployed file
# against the source at the ref and prints `file | deployed sha | source sha | verdict`.
#   rc=1 (a farm-DECLARED file differs, or a declared file never landed) → FATAL. The farm owes these
#                                        and did not converge them, and a stale script would be
#                                        executed. A failed install is louder than a silent no-op
#                                        fleet.
#   rc=2 (cannot compare / not the pin) → LOUD WARNING naming both shas, and the install continues:
#                                        a fresh box legitimately has no pin record yet, and aborting
#                                        there would fail every first-time install for a reason that
#                                        is not a defect. The line prints on every run until it is
#                                        resolved, which is what makes it observable.
#   rc=3 (drift NO FARM ARRAY DELIVERS — an UNSOURCED file, or a STALE file outside the declaration)
#                                      → LOUD WARNING and the install continues. This arm exists
#                                        because rc=1 was fatal for them too and a deploy cannot fix
#                                        either: measured 2026-10-31, ONE such file → rc=1 → exit 1,
#                                        and a second full run left it stale, so the printed remedy
#                                        could never clear it. Fatal only over what the farm owes.
if [ -f "$INFRA_ROOT/scripts/check-farm-drift.sh" ]; then
  echo ""
  echo "==> Farm drift (deployed vs shipped)"
  # GRADES WORKTREE BYTES, because that is what the farm legs above just `cp`'d. Grading against HEAD
  # would red a farm that is byte-identical to the tree this script was told to farm from (the normal
  # hot-fix path: box at pin, a farmed script edited, setup.sh re-run) — a false CRASH, the mirror of
  # the false PASS this whole leg exists against. Pin identity is still checked inside.
  # NOTHING IS WRITTEN INTO $DEST/state: that directory is not created by this file (:466 says so), and
  # a log path there failed closed in the worst way — the STALE detail went to /dev/null and a
  # non-writable dir turned a MATCHING farm into "FARM DID NOT CONVERGE". The detail is captured in a
  # shell variable and always printed.
  _farm_rc=0
  _farm_msg="$(bash "$INFRA_ROOT/scripts/check-farm-drift.sh" \
                --dest "$DEST/scripts" --src "$INFRA_ROOT" --ref HEAD --src-mode worktree \
                --pin-file "$DEST/state/HARNESS-PIN" --quiet 2>&1 >/dev/null)" || _farm_rc=$?
  case "$_farm_rc" in
    0) echo "    farm: OK — every sourced file matches the bytes the farm copied"
       # The pass can still carry a NOTE (e.g. "no pin record: pin identity NOT verified"). Printing it
       # is the difference between "verified" and "verified except the trap arm", and --quiet put it on
       # stderr while this line hid it.
       [ -z "$_farm_msg" ] || printf '%s\n' "$_farm_msg" | sed 's/^/      /' ;;
    1) echo "    ⛔ FARM DID NOT CONVERGE — a deployed script is not the shipped code:"
       printf '%s\n' "$_farm_msg" | sed 's/^/      /'
       echo "    Refusing to report a successful install over a farm that launchd would execute as stale code."
       exit 1 ;;
    3) echo "    ⚠️  farm: files a DEPLOY CANNOT FIX (exit 3) — this is NOT a pass:"
       printf '%s\n' "$_farm_msg" | sed 's/^/      /' ;;
    *) echo "    ⚠️  farm: COULD NOT VERIFY (exit $_farm_rc) — this is NOT a pass:"
       printf '%s\n' "$_farm_msg" | sed 's/^/      /' ;;
  esac
else
  echo ""
  echo "    ⚠️  farm drift NOT verified — $INFRA_ROOT/scripts/check-farm-drift.sh is absent"
fi

if [ "$_mcp_merge_failed" -ne 0 ]; then
  echo ""
  echo "⛔ .mcp.json WAS NOT MERGED — the template declares a tortoise entry no lane could use, or"
  echo "   the merge could not run (the FATAL/ERROR line above names which). The rest of the pi"
  echo "   layer IS installed and usable; your existing .mcp.json is byte-identical to before this"
  echo "   run, so the graph is whatever it already was. Fix templates/.mcp.base.json, then re-run."
  exit 1
fi

echo ""
echo "Done! Next steps:"
echo "  1. Open a NEW terminal window (so the shell profile takes effect), then run:  pi"
echo "  2. Models should already work (keys from ~/pi-keys.env, if present). Otherwise /login."
echo "  3. Press Ctrl+L (/model) to pick a model and confirm it works"
echo "  4. Auto-sync: pi now pulls + refreshes this config automatically on start (Level 1)"
echo "     - Manual refresh anytime:  cd ~/agent-infra && ./sync.sh"
echo "  5. Read pi-bootstrap/HANDOFF.md — it tells pi what this machine is for"
