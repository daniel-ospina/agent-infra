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
#   3. Set parity: every extensions/ top-level entry GIT TRACKS (except
#      *.test.ts) is wired into pi-config (a new extension that isn't wired
#      ships on NO machine). See "TRACKED, NOT PRESENT (#2425)" below.
#   4. Manifest parity: manifest.json files.extensions.entries (the consumer
#      ship-list materialized by bin/agent-infra.js into ~/.pi/agent/extensions/)
#      and the extensions/ tree must agree BOTH WAYS, each side asked the
#      question it can answer truthfully: 4a asks every TRACKED extension for a
#      row (a new extension with no manifest row ships on NO consumer), and 4b
#      asks every row for an entry that EXISTS on disk (a stale row for a
#      deleted extension breaks every consumer bootstrap). 4b is deliberately
#      ON-DISK scoped, not tracked-scoped: its job is that every SHIPPED row has a
#      target, and a row for a present-but-untracked path passes on the machine
#      that has that path while 4b itself reds it on a clean checkout. Demanding
#      trackedness here would red the developer machine for a machine-local
#      inconsistency — the #2425 false-block family — without adding a ship
#      guarantee, because the row itself ships and the fresh-checkout run
#      already fails on the missing entry. Dirs normalized (the manifest
#      records "dir/", the tree "dir"), *.test.ts excluded from both sides
#      (#498 staleness class).
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
# TRACKED, NOT PRESENT (#2425). Checks 3 and 4a used to enumerate "$DST"/* —
# they asked "which directories EXIST under extensions/" and then reported a
# directory git has never heard of as "an extension that is not wired". One
# `npm install` inside extensions/<x>/ produces exactly that shape: an untracked,
# git-ignored node_modules tree. Measured 2026-10-23 on the Mac: `./sync.sh`
# reported "extension vision-interceptor exists in extensions/ but is not wired"
# for a directory whose ONLY content was node_modules — `git ls-files
# extensions/vision-interceptor` was empty, there was no package.json — and the
# message told the reader a fresh machine "won't get it", the opposite of the
# truth: nothing can ship what git does not track. Deleting the ignored tree
# turned sync green, so the gate had indicted a packaging defect that did not
# exist while a real one (#2424, the doctor loop crashing on a bare $1) sat two
# files over.
#
# The question a SHIP gate must ask is "which extensions does GIT TRACK", and it
# is answered from the index (`git ls-files -- extensions`), not from the
# filesystem: a directory whose entire content is ignored cannot be shipped, so
# it cannot be "not wired". Both error directions stay intact and are pinned by
# tests/pi-config-extensions/run.sh — a TRACKED extension with no farm link fails
# (check 3), and a TRACKED extension with no manifest row fails (check 4a). The
# index is read for checks 3/4a AND for the two guards that keep that reading
# honest (the ⏭️ naming line and the vacuity floor); checks 1, 2, 4b and 5 remain
# filesystem/live-farm checks, which is what they are for.
#
# DOT-NAMED FURNITURE. Switching from the shell glob to the index made
# `extensions/.gitkeep` gated for the first time (the glob could never match a
# leading dot), which would red a machine over repo furniture — the same
# false-block family this issue fixes. The exemption is therefore NARROW: an
# entry is furniture only when it is dot-named AND not extension-shaped — no
# `.ts`/`.js` file name, and (for a directory) no `index.ts`/`index.js`/
# `package.json`. A dot-named entry that IS extension-shaped is a LOADABLE
# extension, not furniture: pi's loader has NO dot filter (measured —
# `.hidden.ts`, `.backup.ts` and a normal `.ts` in one agent dir all loaded;
# `bin/agent-infra.js` farms a manifest row verbatim, dot name included), so
# skipping `extensions/.hidden.ts` or `extensions/.adapter/index.ts` would be a
# false PASS in a ship gate. Those are gated and named like any other extension;
# only furniture is skipped, and it is skipped silently on every side (it is not
# a ship artefact, so naming it in the ⏭️ line would be noise).
#
# Fail-closed, and the reading travels with the verdict: when the index cannot be
# read (no git, or $ROOT is not the work-tree toplevel) the gate FAILS rather
# than falling back to the filesystem scan — a fallback would reinstate exactly
# this bug, silently. A tracked path under extensions/ that CONTAINS A NEWLINE is
# refused for the same reason: the top-level name is derived line-wise, so such a
# path would be silently truncated (and could even collide with another name) —
# better to refuse than to mis-name. resolve_path canonicalizes BOTH sides of the toplevel
# comparison because git resolves symlinks and $ROOT does not (on macOS
# /tmp -> /private/tmp). Untracked extension-shaped paths are named in a ⏭️ line
# instead of being silently ignored, so no reader has to infer what was gated.
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

# is_furniture <path> — true (0) only for a DOT-NAMED entry that is NOT
# extension-shaped: no .ts/.js file name, and for a directory no
# index.ts/index.js/package.json. See "DOT-NAMED FURNITURE" in the header — a
# dot-named extension IS loadable by pi, so it must never be exempted.
is_furniture() {
  case "$(basename "$1")" in
    .*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *.ts|*.js) return 1 ;;   # extension-shaped file — gated like any other
  esac
  if [ -d "$1" ] \
      && { [ -e "$1/index.ts" ] || [ -e "$1/index.js" ] || [ -e "$1/package.json" ]; }; then
    return 1                 # extension-shaped directory — gated like any other
  fi
  return 0
}

if [ ! -d "$SRC" ]; then
  echo "❌ pi-config/extensions missing at $SRC — nothing to gate"
  exit 1
fi
if [ ! -d "$DST" ]; then
  echo "❌ extensions/ missing at $DST — nothing to compare against"
  exit 1
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
  fi
done

# --- tracked set: what CAN ship (see TRACKED, NOT PRESENT in the header) ----
# TRACKED_EXTENSIONS = top-level names under extensions/ that git tracks, one per
# line. Empty is a valid answer for a tree with nothing tracked AND nothing
# extension-shaped on disk; the vacuity floor below refuses the other empty case
# (disk shows extensions, the index names none of them).
TRACKED_EXTENSIONS=""
index_ok=0
if ! command -v git >/dev/null 2>&1; then
  echo "❌ git not found — checks 3/4a ask which extensions GIT TRACKS under extensions/, and the index cannot be read without it"
  FAILURES=$((FAILURES + 1))
else
  repo_top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")"
  root_res="$(resolve_path "$ROOT")"
  top_res=""
  if [ -n "$repo_top" ]; then top_res="$(resolve_path "$repo_top")"; fi
  if [ -z "$top_res" ] || [ "$top_res" != "$root_res" ]; then
    # Fail-closed: a filesystem fallback here would reinstate #2425 silently, and
    # enumerating a nested dir's index would answer about the WRONG tree.
    echo "❌ cannot read the git index for $ROOT (not a git work tree, or not its toplevel) — checks 3/4a ask which extensions GIT TRACKS, so their answer would be a guess; refusing to guess"
    FAILURES=$((FAILURES + 1))
  elif ! nl_bytes="$(git -C "$ROOT" ls-files -z -- extensions 2>/dev/null | tr -cd '\n' | wc -c)"; then
    echo "❌ git ls-files failed under $ROOT — checks 3/4a cannot establish which extensions are tracked; refusing to guess"
    FAILURES=$((FAILURES + 1))
  elif [ "$(printf '%s' "$nl_bytes" | tr -d '[:space:]')" != "0" ]; then
    # Newline guard: the top-level name is derived LINE-WISE below, so a tracked
    # path containing LF would be truncated to a prefix — and because `grep -F`
    # treats an LF-bearing pattern as several patterns, the empty/prefix name
    # could even match another entry and hide the directory from the ⏭️ line.
    # Refuse rather than mis-name it (measured: extensions/ext<LF>ing/index.ts,
    # tracked, unwired and unlisted, passed the gate silently).
    echo "❌ a tracked path under extensions/ contains a newline — checks 3/4a derive the extension name line-wise, so the tracked set cannot be represented; refusing to mis-name it"
    FAILURES=$((FAILURES + 1))
  elif TRACKED_EXTENSIONS="$(git -C "$ROOT" ls-files -z -- extensions 2>/dev/null \
      | tr '\0' '\n' | sed -n 's|^extensions/\([^/]*\).*|\1|p' | sort -u)"; then
    # "extensions/d/index.ts" -> "d"; a dir whose content is entirely ignored
    # yields no path at all, so it never enters this list. -z + tr INSIDE the
    # pipeline on purpose: bash's command substitution silently eats NUL bytes,
    # so capturing `git ls-files -z` into a variable first yields ONE munged
    # line (measured — every tracked name vanished and the gate listed the whole
    # tree as untracked).
    index_ok=1
  else
    echo "❌ git ls-files failed under $ROOT — checks 3/4a cannot establish which extensions are tracked; refusing to guess"
    FAILURES=$((FAILURES + 1))
  fi
fi

# Untracked extension-shaped paths: git never ships them, so they are not drift.
# Named rather than dropped — a silent skip is how the reader of a red (or a
# green) has to infer the scope, which is what #2425 was about.
if [ "$index_ok" -eq 1 ]; then
  untracked_exts=""
  present_exts=""
  for e in "$DST"/* "$DST"/.[!.]*; do
    # `-L` too: a DANGLING SYMLINK is a tracked entry that ships and loads
    # nothing, so it must be examined (and named), not treated as absent — the
    # checks 1/2 loops already make this distinction.
    [ -e "$e" ] || [ -L "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in
      *.test.ts) continue ;;
    esac
    if is_furniture "$e"; then continue; fi   # dot-named, not extension-shaped
    present_exts="${present_exts:+$present_exts }$base"
    grep -Fqx -- "$base" <<<"$TRACKED_EXTENSIONS" || untracked_exts="${untracked_exts:+$untracked_exts }$base"
  done
  if [ -n "$untracked_exts" ]; then
    echo "⏭️  not gated (UNTRACKED — git does not ship these, so they cannot be 'not wired'): $untracked_exts"
  fi
  # Vacuity floor — the "check that cannot fail" class this repo keeps deleting.
  # If extension-shaped paths exist on disk but the index names NONE of them, the
  # READING is wrong (a bad pathspec, a wrong cwd), not the tree: checks 3/4a
  # would then pass over an unwired tree forever. Refuse instead of passing.
  if [ -z "$TRACKED_EXTENSIONS" ] && [ -n "$present_exts" ]; then
    echo "❌ git tracks NO extension under extensions/ although these exist on disk: $present_exts — checks 3/4a would pass vacuously; the index reading is wrong (pathspec/cwd), refusing"
    FAILURES=$((FAILURES + 1))
  fi
fi

# --- check 3: set parity — every TRACKED extension is wired into pi-config ---
# Iterates the tracked set, not the directory listing (#2425): an untracked
# node_modules-only directory is not an extension that needs wiring.
if [ "$index_ok" -eq 1 ]; then
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    case "$base" in
      *.test.ts) continue ;;   # test files are not extensions; not shipped
    esac
    if is_furniture "$DST/$base"; then continue; fi   # dot-named, not extension-shaped
    # Tracked but ABSENT from the worktree means the index and disk disagree (an
    # unstaged `rm`): there is nothing to wire, and demanding a manifest row for a
    # path that is not on disk would report drift that cannot ship. A DANGLING
    # SYMLINK is NOT absent — `-L` makes it pass this guard, because a tracked link
    # ships and loads nothing, which is exactly what this gate must report. A farm
    # link that still points here is not this loop's business — check 2 compares
    # the link's resolved target NAME (realpath returns a path even when only the
    # final component is missing, so it can pass), and check 5 is the liveness arm
    # on a machine where the farm is materialized.
    [ -e "$DST/$base" ] || [ -L "$DST/$base" ] || continue
    if [ ! -L "$SRC/$base" ]; then
      echo "❌ tracked extension $base exists in extensions/ (git tracks it) but is not wired into pi-config/extensions (fresh machines won't get it)"
      FAILURES=$((FAILURES + 1))
    fi
  done <<<"$TRACKED_EXTENSIONS"
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
  # Same index reading as check 3 (#2425): an untracked ignored directory ships
  # to nobody, so it needs no row.
  if [ "$index_ok" -eq 1 ]; then
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      case "$base" in
        *.test.ts) continue ;;   # test files are not shipped; never in manifest
      esac
      if is_furniture "$DST/$base"; then continue; fi   # dot-named, not extension-shaped
      [ -e "$DST/$base" ] || [ -L "$DST/$base" ] || continue   # index/disk disagreement — see check 3
      if ! grep -Fqx -- "$base" <<<"$manifest_rows"; then
        echo "❌ tracked extension $base exists in extensions/ (git tracks it) but has no manifest.json files.extensions.entries row (bin/agent-infra.js consumers won't get it)"
        FAILURES=$((FAILURES + 1))
      fi
    done <<<"$TRACKED_EXTENSIONS"
  fi

  # 4b — every manifest row must resolve to a real extensions/ entry.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ ! -e "$DST/$row" ]; then
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
# The verdict names the reading it was reached from: checks 3/4a ask "which
# extensions does GIT TRACK under extensions/", not "which directories exist"
# (#2425 — an untracked, git-ignored node_modules tree is not an unwired
# extension, and the old wording sent readers hunting a packaging defect).
echo "✅ manifest.json files.extensions.entries ↔ extensions/ parity holds (check 4 — 4a asks whether every TRACKED extension has a row; 4b whether every row has an on-disk entry; tracked = git lists it under extensions/, and an untracked/ignored path cannot ship so it is not drift)"
