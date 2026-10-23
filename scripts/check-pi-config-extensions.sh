#!/bin/bash
# ============================================================
# check-pi-config-extensions.sh — pi-config extensions drift gate (issue #95)
#
# Enforces the single-source-of-truth invariant:
#   pi-bootstrap/pi-config/extensions/* MUST be symlinks resolving into
#   extensions/ — never materialized copies, which is what went stale before.
#
# Checks:
#   1. Every pi-config/extensions entry is a symlink (a real copy = drift risk).
#   2. Every entry resolves (realpath) to extensions/<name> — clone-path agnostic.
#   3. Set parity: every CARRIED extension except *.test.ts is wired into
#      pi-config (a new extension that isn't wired ships on NO machine).
#   4. Manifest parity: manifest.json files.extensions.entries (the consumer
#      ship-list materialized by bin/agent-infra.js into ~/.pi/agent/extensions/)
#      and the CARRIED extensions must name the SAME set (dirs normalized — the
#      manifest records "dir/", the tree "dir" — and *.test.ts excluded from
#      both sides). A new extension with no manifest row ships on NO consumer
#      (#498 staleness class); a stale manifest row for a deleted extension
#      breaks every consumer bootstrap.
#   5. LIVE-FARM LIVENESS (machine-local — checks 1-4 gate the repo, this one
#      gates the materialized farm at ~/.pi/agent/extensions/). Every
#      manifest-listed entry that IS a symlink there must RESOLVE to a path
#      that exists. A dangling link is silent: pi does not load the extension,
#      so a guard the link was carrying is simply ABSENT with nothing anywhere
#      reporting it (#1214b parked the clamp-output-floor link on a worktree
#      while its PR was open; that link dies the moment the worktree is
#      removed). Scope is the manifest ship-list on purpose — machine-local
#      links this repo does not ship are not this gate's business, so it cannot
#      false-block on someone else's half-installed farm. An absent farm prints
#      an explicit STOP line and passes, and an absent link for a row is simply
#      not inspected; PI_EXTENSIONS_DIR overrides the farm root for
#      tests/pi-config-extensions/run.sh.
#
# Because each entry IS the extensions/ file/dir (via symlink), content can
# never drift between the two trees; checks 1-3 close every farm drift mode:
#   - copy materialized over a link            -> fails check 1
#   - link retargeted elsewhere / broken       -> fails check 2
#   - entry deleted, or new ext not added      -> fails check 3
# Check 4 closes the manifest drift mode:
#   - tree and manifest rows diverge           -> fails check 4
# Check 5 closes the machine-local half of that same row set:
#   - a shipped link's target was removed      -> fails check 5
#
# THE READING (issue #2425): checks 3 and 4a, the tracked leg of 4b, and the
# tracked-content leg of check 2 are answered over WHAT THE REPO CARRIES, never
# over "what files happen to be on this disk". The set is git's own ship-list
# for the tree: `git ls-files --cached --others --exclude-per-directory=.gitignore`
# under extensions/, i.e. tracked content plus untracked-but-not-ignored content
# — what this checkout would ship ("tracked" below means exactly that set: an
# extension whose content git carries, whether or not it is committed yet).
# Bare `--cached` would also be defensible, but it would hide a brand-new
# extension directory until its author ran `git add`, and this gate's local run
# is the first place an author sees the mistake. A directory whose entire
# content git ignores cannot be shipped by any clone, so it cannot be an
# extension that is "not wired": an `npm install` inside extensions/<x>/ used to
# leave a 5.8 MB node_modules-only tree that failed the bootstrap of a repo
# whose whole job is shipping a correct machine — over a directory the
# bootstrap would never ship.
#
# ⚠️ `--exclude-per-directory=.gitignore`, NOT `--exclude-standard`: the latter
# also consults `.git/info/exclude` and the user's GLOBAL excludes file
# (core.excludesFile), which are machine-local state the repo does not carry — a
# developer with a global `*.local` rule would get a different answer from CI,
# which is the very defect this closes. `--exclude-per-directory=.gitignore`
# reads the .gitignore files present in the working tree (in practice the
# committed ones) and nothing else. The global half is pinned by tests case 17;
# the `.git/info/exclude` half is the same flag semantics (reviewer-verified) and
# is the residual reason that flag is named explicitly here.
#
# ⚠️ SCOPE OF THE CLAIM — what is STILL a filesystem read, deliberately:
#   - check 2's realpath resolve (is the farm symlink pointing at its own tree?)
#   - check 4b's existence leg, and check 1's shape test
#   Those are shape/existence questions about this checkout, so a red there can
#   still be local dirt (a sparse checkout that omits an entry makes 4b's
#   existence leg false). Everything that decides WHICH EXTENSIONS THE REPO
#   CARRIES is the git reading — that is the part #2425 was about, and 4b's
#   tracked leg now runs FIRST so an ignored-only directory can no longer make a
#   row look satisfied.
#
# The failure text names the reading so no reader has to infer the scope, and an
# unreadable reading is a FAILURE, never a silent fall back to the filesystem
# (that fallback IS the defect). Check 5 is a deliberate exception: the live
# farm at ~/.pi/agent/extensions is machine-local by definition, so a
# filesystem read is the CORRECT instrument there — do not "fix" it into a git
# read.
#
# Usage:  bash scripts/check-pi-config-extensions.sh
# Exit:   0 = invariant holds, 1 = drift found (details printed to stdout).
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/pi-bootstrap/pi-config/extensions"
DST="$ROOT/extensions"
FAILURES=0

# Resolve to an absolute, symlink-free path ("" when unresolvable).
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

if [ ! -d "$SRC" ]; then
  echo "❌ pi-config/extensions missing at $SRC — nothing to gate"
  exit 1
fi
if [ ! -d "$DST" ]; then
  echo "❌ extensions/ missing at $DST — nothing to compare against"
  exit 1
fi

# --- the TRACKED reading shared by checks 2 (tree half), 3, 4a and 4b -------
# The reading is ROOT-relative by construction: git resolves the `extensions/`
# pathspec against $ROOT, so a script tree nested inside another repo reads ITS
# OWN extensions/ — never the enclosing repo's (verified 2026-10-23: a nested
# ROOT with its own extensions/ lists exactly those entries). No toplevel
# equality is required, and demanding one would false-block that layout.
# Git is pinned to THIS checkout at every call site: GIT_DIR / GIT_WORK_TREE /
# GIT_INDEX_FILE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY are AMBIENT state that
# can point the reading at another repo — a foreign GIT_DIR makes even
# `git -C "$ROOT"` answer about a different index (reviewer-reproduced). That is
# the same class as the `core.excludesFile` hazard this gate closes, and when the
# foreign index happens to satisfy this tree's farm + manifest it is a silent
# FAIL-OPEN with a pass line naming $ROOT. Hence the `env -u` prefix, written out
# at each site: a git wrapper taking "$@" cannot be classified by the fleet's
# worktree guard, which then refuses to RUN this script at all.
tracked_entries=""
reading_ok=1
if ! command -v git >/dev/null 2>&1; then
  echo "❌ git is required to answer which extensions are TRACKED (checks 3/4) and is not on PATH — refusing to fall back to the filesystem, which cannot tell a shipped extension from ignored leftovers (#2425)"
  FAILURES=$((FAILURES + 1))
  reading_ok=0
elif ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
         -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
         git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ $ROOT is not inside a git work tree — the parity question is \"which extensions does this REPO carry\" and git cannot be asked; refusing to fall back to the filesystem (#2425)"
  FAILURES=$((FAILURES + 1))
  reading_ok=0
elif ! tracked_entries="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git -C "$ROOT" ls-files -z --cached --others --exclude-per-directory=.gitignore -- extensions/ \
      | tr '\0' '\n' | sed -n 's|^extensions/||p' | awk -F/ 'NF {print $1}' | sort -u)"; then
  echo "❌ git ls-files failed under $ROOT/extensions/ — cannot answer which extensions are TRACKED; refusing to guess (#2425)"
  FAILURES=$((FAILURES + 1))
  reading_ok=0
elif [ -z "$tracked_entries" ]; then
  echo "❌ no tracked or non-ignored content under $DST — a gate that read nothing must not pass (#2425)"
  FAILURES=$((FAILURES + 1))
  reading_ok=0
fi

# --- checks 1 + 2: every pi-config entry is a symlink into extensions/ -------
for e in "$SRC"/*; do
  [ -e "$e" ] || [ -L "$e" ] || continue   # skip empty glob only, NOT broken links (P2 #95-review)
  base="$(basename "$e")"

  if [ ! -L "$e" ]; then
    echo "❌ pi-config/extensions/$base is NOT a symlink (materialized copy — will drift)"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  src_res="$(resolve_path "$e")"
  dst_res="$(resolve_path "$DST/$base")"
  if [ -z "$src_res" ] || [ -z "$dst_res" ] || [ "$src_res" != "$dst_res" ]; then
    echo "❌ pi-config/extensions/$base -> $(readlink "$e") does not resolve to extensions/$base"
    FAILURES=$((FAILURES + 1))
  elif [ "$reading_ok" -eq 1 ] && ! grep -Fqx -- "$base" <<<"$tracked_entries"; then
    # Resolves, but git carries nothing for the target: a clone gets a DANGLING
    # link here and pi loads nothing (#2425). The wording states the observation
    # (git lists nothing under the path) rather than a cause it did not check —
    # an EMPTY directory has nothing ignored, so "everything there is ignored"
    # would be a false cause of exactly the kind #2425 was about.
    echo "❌ pi-config/extensions/$base resolves to extensions/$base, but this repo carries NO tracked or non-ignored content for it (git ls-files lists nothing under it) — nothing ships for this farm entry, so every clone gets a dangling link"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- check 3: set parity — every TRACKED extension is wired into pi-config --
# Reading: TRACKED top-level entries under extensions/ (#2425). A git-ignored
# directory (node_modules leftovers) is not an extension and cannot be unwired.
if [ "$reading_ok" -eq 1 ]; then
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    case "$base" in
      *.test.ts) continue ;;   # test files are not extensions; not shipped
    esac
    if [ ! -L "$SRC/$base" ]; then
      echo "❌ extension $base is carried by this repo (git has content for it: tracked, or untracked and not git-ignored) but is not wired into pi-config/extensions (fresh machines won't get it)"
      FAILURES=$((FAILURES + 1))
    fi
  done <<< "$tracked_entries"
fi

# --- check 4: manifest ↔ tree set parity (issue #502) ------------------------
# manifest.json files.extensions.entries is the consumer ship-list that
# bin/agent-infra.js materializes into ~/.pi/agent/extensions/ on every
# bootstrap. Checks 1-3 gate the farm ↔ tree pair; the manifest is a THIRD
# surface that can silently lose/gain rows (#498 fixed one such stale row —
# session-checks.ts existed in the tree but had no manifest entry, so
# consumers farmed via bin/agent-infra.js never got it).
#
# JSON is parsed with python3 stdlib (the sibling gate check-cost-config.sh
# sets the convention: "bash + POSIX coreutils + python3 (stdlib only)").
MANIFEST="$ROOT/manifest.json"
parse_ok=1
if [ ! -f "$MANIFEST" ]; then
  echo "❌ manifest.json missing at $MANIFEST — consumer ship-list is ungated"
  FAILURES=$((FAILURES + 1))
  parse_ok=0
elif ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 required (stdlib json) to read $MANIFEST entries — present on ubuntu-latest + macOS"
  FAILURES=$((FAILURES + 1))
  parse_ok=0
else
  # Normalized manifest rows (trailing slash stripped — manifest records dirs
  # as "dir/"; the tree lists bare basenames). One row per line; empty when
  # the entries array is missing/empty (fail-closed on the tree→manifest loop
  # below).
  manifest_rows="$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except (OSError, ValueError):
    sys.exit(1)

for e in (m.get("files") or {}).get("extensions/", {}).get("entries") or []:
    print(str(e).rstrip("/"))
PYEOF
)" || {
    echo "❌ cannot parse $MANIFEST — malformed JSON or missing files.extensions.entries"
    FAILURES=$((FAILURES + 1))
    parse_ok=0
  }
fi

# 4a/4b run whenever the manifest parsed cleanly, INDEPENDENT of farm checks
# 1-3 — masking manifest drift behind farm drift would let a merged PR ship
# both at once. (Guard on parse_ok, not FAILURES: prior failures must not
# suppress the manifest report.)
if [ "$parse_ok" -eq 1 ]; then
  # 4a — every TRACKED extension (except *.test.ts) must have a manifest row.
  # Same reading as check 3 (#2425): a git-ignored directory is not an
  # extension, so it is not a row that is missing.
  if [ "$reading_ok" -eq 1 ]; then
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      case "$base" in
        *.test.ts) continue ;;   # test files are not shipped; never in manifest
      esac
      if ! grep -Fqx -- "$base" <<<"$manifest_rows"; then
        echo "❌ extension $base is carried by this repo (git has content for it: tracked, or untracked and not git-ignored) but has no manifest.json files.extensions.entries row (bin/agent-infra.js consumers won't get it)"
        FAILURES=$((FAILURES + 1))
      fi
    done <<< "$tracked_entries"
  fi

  # 4b — every manifest row must name an extension this repo CARRIES, and that
  # entry must also exist in this checkout. The tracked leg runs FIRST so a row
  # whose target exists only as git-ignored leftovers is refused (it ships
  # nothing: a clone has no such path, so every consumer bootstrap fails) — the
  # same defect class as #2425 in the fail-open direction — while the existence
  # leg stays a checkout-shape question and can only refine the message.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "$reading_ok" -eq 1 ]; then
      if ! grep -Fqx -- "$row" <<<"$tracked_entries"; then
        if [ -e "$DST/$row" ]; then
          echo "❌ manifest.json row \"$row\" names extensions/$row, but this repo carries NO tracked or non-ignored content for it (git ls-files lists nothing under it) — nothing ships for this row, so every consumer bootstrap fails"
        else
          echo "❌ manifest.json row \"$row\" has no matching extensions/ entry (stale, and git carries no content for it either — every consumer bootstrap will fail)"
        fi
        FAILURES=$((FAILURES + 1))
      fi
    elif [ ! -e "$DST/$row" ]; then
      # Only reachable when the git reading is unavailable — keep the pre-#2425
      # fail-closed shape rather than passing a row nobody can confirm.
      echo "❌ manifest.json row \"$row\" has no matching extensions/ entry (stale — every consumer bootstrap will fail)"
      FAILURES=$((FAILURES + 1))
    fi
  done <<< "$manifest_rows"
fi

# --- check 5: live-farm liveness (machine-local; CI has no ~/.pi) ------------
# See the header. Only manifest-listed entries are inspected, and only when they
# are present as symlinks: an absent live link is not this gate's business (the
# machine may simply not be bootstrapped for that row), and a link this repo
# does not ship is somebody else's state. Guarded by parse_ok because
# manifest_rows only exists once the manifest parsed.
if [ "$parse_ok" -eq 1 ]; then
  LIVE_FARM="${PI_EXTENSIONS_DIR:-${HOME:-}/.pi/agent/extensions}"
  if [ ! -d "$LIVE_FARM" ]; then
    echo "⏭️  live extension farm not found at $LIVE_FARM — check 5 (dangling shipped links) skipped; set PI_EXTENSIONS_DIR to aim it at a farm"
  else
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      live="$LIVE_FARM/$row"
      [ -L "$live" ] || continue   # not farmed as a link here — not this gate's row
      if [ ! -e "$live" ]; then
        echo "❌ live farm link $row -> $(readlink "$live") is DANGLING (target does not exist) — pi loads NOTHING for it, so that extension is silently absent; repoint it at an existing checkout (bin/agent-infra.js, or \`ln -sf\`)"
        FAILURES=$((FAILURES + 1))
      fi
    done <<< "$manifest_rows"
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "❌ $FAILURES pi-config/extensions drift issue(s) — fix or the bootstrap ships stale/partial extensions"
  exit 1
fi

echo "✅ pi-config/extensions = symlink farm into extensions/ (single source of truth, $(( $(ls -1 "$SRC" | wc -l | tr -d ' ') )) entries)"
echo "✅ extensions/ parity was answered over TRACKED content — $(( $(grep -vc '\.test\.ts$' <<<"$tracked_entries") )) extension(s) carried by this repo (git ls-files --cached --others --exclude-per-directory=.gitignore; a directory git ignores is not an extension and cannot be "unwired", #2425)"
echo "✅ every carried extension is wired into pi-config/extensions (check 3) and has a manifest.json files.extensions.entries row (check 4a); every manifest row names a carried entry (check 4b)"
