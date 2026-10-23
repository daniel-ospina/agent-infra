#!/bin/bash
# #498/#502 — pi-config extension-farm parity gate tests.
#
# Exercises scripts/check-pi-config-extensions.sh semantics against
# runtime-built fixture trees (mechanism: cost-config test 10 — the gate
# computes ROOT from its own path, so a copy under a tmp tree gates that
# tree; no committed fixtures, no gate-script override needed):
#   1. clean farm (links resolve into extensions/, *.test.ts unwired, manifest
#      rows match tree) → PASS
#   2. materialized copy over a link  (check 1)  → BLOCK, exit 1
#   3. mistargeted link (check 2)                → BLOCK, exit 1
#   4. broken farm link (check 2, resolve "")    → BLOCK, exit 1
#   5. extension present but not wired (check 3) + no manifest row (check 4a)
#      → BLOCK, exit 1, both diagnostics reported
#   6. extension in tree+farm but no manifest row (check 4a, #502) → BLOCK
#   7. manifest row with no matching tree entry (check 4b, #502)   → BLOCK
#   8. no manifest.json at all (check 4 fail-closed)               → BLOCK
#   9. malformed manifest.json (check 4 fail-closed)               → BLOCK
#  10. live farm link whose target is gone (check 5, #1214b)       → BLOCK
#  11. live farm links that all resolve (check 5)                  → PASS
#  12. no live farm at all — the CI shape (check 5)                → PASS +
#      an explicit ⏭️ skip line (never a silent pass)
#  13. directory whose ENTIRE content is git-ignored (the #2425 shape: an
#      untracked extensions/<x>/node_modules tree)                   → PASS, and
#      the skip line NAMES it (nothing is silently ignored)
#  14. TRACKED extension that ALSO carries an ignored node_modules
#      tree, but is unwired + unlisted                               → BLOCK — the
#      fix keys on tracked content per entry, so a real extension is never
#      exempted by a stray ignored tree inside it (#2425 constraint 2)
#  15. fixture that is not a git work tree                          → BLOCK
#      (fail-closed: the gate refuses to fall back to a filesystem scan, which
#      would reinstate #2425 silently)
#  16. a repo whose extensions/ are ALL unindexed                     → BLOCK
#      (vacuity floor: if the index names none of the extension-shaped paths
#      that exist on disk, the READING is wrong — checks 3/4a would otherwise
#      pass vacuously forever, the "check that cannot fail" class)
#  17. a tree that is a SUBDIRECTORY of a git repo (not its toplevel)  → BLOCK
#      (the second fail-closed branch: enumerating the OUTER repo's index would
#      answer about the wrong tree)
#  18. a TRACKED path whose name contains a newline                    → BLOCK
#      (the name is derived line-wise, so such a path would be silently
#      truncated — and an LF-bearing `grep -F` pattern can match another entry,
#      hiding the directory from the ⏭️ line; refuse instead of mis-name)
#
# Fixture trees mirror the real farm: relative symlinks ../../../extensions/<e>
# from pi-bootstrap/pi-config/extensions/ into extensions/, plus a manifest.json
# at the tree root (the consumer ship-list check 4 gates).
#
# EVERY fixture is a real git repo (`git init` + an explicit `git add`, #2425): checks 3
# and 4a ask what GIT TRACKS under extensions/, so a fixture that was not a repo
# would only ever exercise the fail-closed branch. `git add` needs no identity;
# the fixture's own .gitignore is what keeps an ignored node_modules tree
# untracked, exactly as on a developer machine.
#
# Check 5 (the machine-local live farm at ~/.pi/agent/extensions) is aimed at a
# fixture dir via PI_EXTENSIONS_DIR in EVERY case, so this suite's verdict never
# depends on the developer's own ~/.pi state.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-pi-config-extensions.sh"
OUT="$(mktemp /tmp/pi-config-ext-out.XXXXXX)"
failures=0

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# write_manifest <path> <entry>... — manifest.json with files.extensions.entries
# holding exactly the given rows (dirs recorded with a trailing slash, matching
# the real manifest format). No trailing comma (invalid JSON).
write_manifest() {
  local path="$1"; shift
  local entries=""
  local first=1
  for entry in "$@"; do
    if [ "$first" -eq 1 ]; then
      entries="    \"${entry}\""
      first=0
    else
      entries="${entries},
    \"${entry}\""
    fi
  done
  # printf interprets \n (SC2059 is a style hint only — expansion is intended)
  printf '{\n  "files": {\n    "extensions/": {\n      "kind": "symlink",\n      "essential": true,\n      "entries": [\n%b\n  ]\n    }\n  }\n}\n' "$entries" > "$path"
}

# build_farm <mode> — fresh tmp tree per case; echoes the tree path.
# mode: clean | copy | retarget | broken | unwired | manifest-missing |
#       manifest-stale | no-manifest | bad-manifest | live-healthy |
#       live-dangling | ignored-node-modules | mixed-ignored | no-git |
#       all-untracked | nested-git | newline-name
# The live-farm dir is always $TMP/live-extensions (run_gate points
# PI_EXTENSIONS_DIR at it); only the live-* modes create it, so every other mode
# exercises check 5's explicit skip.
build_farm() {
  local mode="$1"
  local TMP
  TMP="$(mktemp -d /tmp/pi-config-ext-fixture.XXXXXX)"
  # The gate copy run_gate executes. `nested-git` moves the whole tree under
  # $TMP/inner (so ROOT is a subdirectory of a repo), and points this at it.
  FIXTURE_GATE="$TMP/scripts/check-pi-config-extensions.sh"
  mkdir -p "$TMP/scripts" "$TMP/extensions" "$TMP/pi-bootstrap/pi-config/extensions"
  cp "$GUARD" "$TMP/scripts/check-pi-config-extensions.sh"

  # extensions/ tree: two single-file extensions, one dir extension, one
  # *.test.ts (test files are not extensions — never shipped, never wired).
  : > "$TMP/extensions/a.ts"
  : > "$TMP/extensions/b.ts"
  : > "$TMP/extensions/c.test.ts"
  mkdir -p "$TMP/extensions/d"
  : > "$TMP/extensions/d/index.ts"

  local FARM="$TMP/pi-bootstrap/pi-config/extensions"
  ln -s ../../../extensions/a.ts "$FARM/a.ts"
  ln -s ../../../extensions/d "$FARM/d"

  case "$mode" in
    clean)    ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
    live-healthy)  ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # farm fine; live link resolves
    live-dangling) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # farm fine; live link dangles
    copy)     : > "$FARM/b.ts" ;;                                    # materialized copy
    retarget) ln -s ../../../extensions/a.ts "$FARM/b.ts" ;;         # resolves, wrong target
    broken)   ln -s ../../../extensions/missing.ts "$FARM/b.ts" ;;   # resolves to ""
    unwired)  ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/e.ts" ;;                          # new ext, NOT wired
    manifest-missing) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest omits b.ts
    manifest-stale)   ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest lists z.ts below
    no-manifest)      ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, no manifest.json at all
    bad-manifest)     ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest.json unparseable
    # #2425 — the measured shape: a directory under extensions/ whose ONLY
    # content is a git-ignored node_modules tree (no package.json, nothing
    # tracked). It is not an extension and no bootstrap could ship it.
    ignored-node-modules) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/vision-interceptor/node_modules/foo"
              : > "$TMP/extensions/vision-interceptor/node_modules/foo/package.json"
              printf 'node_modules/\n' > "$TMP/.gitignore" ;;
    # #2425 constraint 2 — a TRACKED extension that happens to carry an ignored
    # node_modules tree INSIDE it must still be gated: the ignored child must not
    # exempt the tracked entry.
    mixed-ignored) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/f/node_modules/foo"
              : > "$TMP/extensions/f/index.ts"
              : > "$TMP/extensions/f/node_modules/foo/package.json"
              printf 'node_modules/\n' > "$TMP/.gitignore" ;;
    no-git)   ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # index unreadable on purpose
    # #2425 review — ROOT is a SUBDIRECTORY of a repo, not its toplevel: the
    # second fail-closed branch (enumerating the outer index answers about the
    # wrong tree). Relocated into $TMP/inner after the git block below.
    nested-git) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
    # #2425 review — a TRACKED extension whose NAME contains a newline. The
    # top-level name is derived line-wise, so this path would truncate to `ext`
    # and (via grep -F's multi-pattern reading) could even collide with a real
    # entry, hiding it from the ⏭️ line. Must refuse, never mis-name.
    newline-name) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/ext"$'\n'"ing"
              : > "$TMP/extensions/ext"$'\n'"ing/index.ts" ;;
  esac

  # manifest.json rows: tree extensions a.ts + d/ always present; b.ts unless
  # mode is manifest-missing; e.ts absent in unwired (its own drift); z.ts
  # listed ONLY in manifest-stale (stale row — no tree counterpart).
  # no-manifest: omit the file (check 4 fail-closed on missing manifest).
  # bad-manifest: write malformed JSON (check 4 fail-closed on parse error).
  case "$mode" in
    manifest-missing) write_manifest "$TMP/manifest.json" a.ts d/ ;;
    manifest-stale)   write_manifest "$TMP/manifest.json" a.ts b.ts d/ z.ts ;;
    no-manifest)      : ;;   # no manifest.json written
    bad-manifest)     printf '{ this is not json
' > "$TMP/manifest.json" ;;
    *)                write_manifest "$TMP/manifest.json" a.ts b.ts d/ ;;
  esac

  # Live farm (check 5) — the materialized ~/.pi/agent/extensions shape. A
  # shipped row farmed as a symlink: live-healthy resolves, live-dangling does
  # not. Any other mode leaves $TMP/live-extensions absent (the CI shape).
  case "$mode" in
    live-healthy)  mkdir -p "$TMP/live-extensions"
                   ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts" ;;
    live-dangling) mkdir -p "$TMP/live-extensions"
                   ln -s "$TMP/extensions/gone.ts" "$TMP/live-extensions/a.ts" ;;
  esac

  # #2425 — checks 3/4a read the GIT INDEX, so every fixture is a real repo with
  # exactly the shippable files staged. The fixture's own .gitignore is what makes
  # the ignored-node_modules case a real test rather than a filesystem-only one.
  # `no-git` deliberately skips the init so the fail-closed branch is pinned too.
  # (No commit and no identity needed: `git ls-files` reads the index.) Staged by
  # explicit path, never `add -A` — the worktree guard refuses a repo-wide stage,
  # and a directory stage still honours .gitignore. `init` is spelled `git init -q
  # "$TMP"`, NOT `git -C "$TMP" init`: the worktree guard refuses a `-C` whose
  # target is a variable inside a repo script ("unverifiable-verb") and accepted
  # the directory form — measured, the `-C` spelling blocked this suite outright.
  if [ "$mode" != "no-git" ]; then
    git init -q "$TMP" || return 1
    # `all-untracked` stages everything EXCEPT extensions/ — the vacuity floor
    # needs a repo whose whole extensions/ tree is unindexed (#2425).
    if [ "$mode" != "all-untracked" ]; then
      git -C "$TMP" add -- extensions || return 1
    fi
    git -C "$TMP" add -- pi-bootstrap || return 1
    if [ -f "$TMP/manifest.json" ]; then git -C "$TMP" add -- manifest.json || return 1; fi
    if [ -f "$TMP/.gitignore" ]; then git -C "$TMP" add -- .gitignore || return 1; fi
  fi

  # #2425 review — the nested-repo shape: the repo toplevel is $TMP but the gate's
  # ROOT is $TMP/inner, so the index it can reach describes a DIFFERENT tree.
  # Relocate the whole fixture tree (the gate derives ROOT from its own path).
  if [ "$mode" = "nested-git" ]; then
    mkdir -p "$TMP/inner"
    mv "$TMP/scripts" "$TMP/extensions" "$TMP/pi-bootstrap" "$TMP/inner/" || return 1
    if [ -f "$TMP/manifest.json" ]; then mv "$TMP/manifest.json" "$TMP/inner/" || return 1; fi
    FIXTURE_GATE="$TMP/inner/scripts/check-pi-config-extensions.sh"
  fi

  # build_farm must NOT run in a command substitution: it sets FIXTURE_GATE
  # (nested-git relocates the tree), and a subshell would drop that assignment.
  FIXTURE_TMP="$TMP"
  return 0
}

# run_gate <expected-exit> <label> <mode> [grep-for]... — each grep-for must
# appear in the gate output (multiple = all required).
run_gate() {
  local expected="$1"; shift
  local label="$1"; shift
  local mode="$1"; shift
  local TMP
  build_farm "$mode" || { fail "$label — fixture build failed ($mode)"; return; }
  TMP="$FIXTURE_TMP"
  # Check 5 is aimed at the fixture dir in every case (see the suite header), so
  # the verdict is hermetic and the real ~/.pi never participates.
  export PI_EXTENSIONS_DIR="$TMP/live-extensions"
  bash "${FIXTURE_GATE:-$TMP/scripts/check-pi-config-extensions.sh}" >"$OUT" 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,60p' "$OUT"
  fi
  for grep_for in "$@"; do
    if grep -q "$grep_for" "$OUT"; then
      pass "diagnostic present: $grep_for"
    else
      fail "expected diagnostic: $grep_for"
      sed -n '1,40p' "$OUT"
    fi
  done
  rm -rf "$TMP"
}

echo "== pi-config extension-farm parity gate tests (#498) =="
echo ""

echo "1. Clean farm → PASS, exit 0 (a.ts + d/ wired; *.test.ts excluded)"
run_gate 0 "clean farm" clean "symlink farm into extensions/"

echo ""
echo "2. Materialized copy over a link (check 1) → BLOCK, exit 1"
run_gate 1 "materialized copy" copy "NOT a symlink"

echo ""
echo "3. Mistargeted link (check 2) → BLOCK, exit 1"
run_gate 1 "mistargeted link" retarget "does not resolve"

echo ""
echo "4. Broken farm link (check 2, resolve empty) → BLOCK, exit 1"
run_gate 1 "broken link" broken "does not resolve"

echo ""
echo "5. Extension present but not wired (check 3) + no manifest row (check 4a) → BLOCK, exit 1, both reported"
run_gate 1 "unwired extension" unwired "not wired into pi-config" "has no manifest.json files.extensions.entries row" "tracked extension e.ts"

echo ""
echo "6. Extension in tree+farm but no manifest row (check 4a, #502) → BLOCK, exit 1"
run_gate 1 "manifest row missing" manifest-missing "has no manifest.json files.extensions.entries row" "tracked extension b.ts"

echo ""
echo "7. Manifest row with no matching tree entry (check 4b, #502) → BLOCK, exit 1"
run_gate 1 "stale manifest row" manifest-stale "has no matching extensions/ entry"

echo ""
echo "8. No manifest.json at all (check 4 fail-closed, #502) → BLOCK, exit 1"
run_gate 1 "missing manifest file" no-manifest "manifest.json missing at"

echo ""
echo "9. Malformed manifest.json (check 4 fail-closed, #502) → BLOCK, exit 1"
run_gate 1 "malformed manifest" bad-manifest "cannot parse"

echo ""
echo "10. Live farm link whose target is gone (check 5, #1214b) → BLOCK, exit 1"
run_gate 1 "dangling live farm link" live-dangling "is DANGLING"

echo ""
echo "11. Live farm links that all resolve (check 5) → PASS, exit 0"
run_gate 0 "healthy live farm links" live-healthy "symlink farm into extensions/"

echo ""
echo "12. No live farm at all — the CI shape (check 5) → PASS + explicit skip line"
run_gate 0 "absent live farm" clean "check 5 (dangling shipped links) skipped"

echo ""
echo "13. #2425 — directory whose ONLY content is a git-ignored node_modules tree → PASS"
run_gate 0 "ignored node_modules-only dir is not an extension" ignored-node-modules \
  "⏭️  not gated (UNTRACKED" \
  "vision-interceptor" \
  "TRACKED extensions/ tree parity"

echo ""
echo "14. #2425 constraint 2 — a TRACKED extension carrying an ignored node_modules tree is STILL gated"
run_gate 1 "tracked extension with an ignored child is not exempt" mixed-ignored \
  "tracked extension f exists in extensions/" \
  "not wired into pi-config" \
  "has no manifest.json files.extensions.entries row"

echo ""
echo "15. #2425 fail-closed — not a git work tree: refuse, never fall back to the filesystem scan"
run_gate 1 "unreadable index" no-git "cannot read the git index"

echo ""
echo "16. #2425 vacuity floor — a repo whose extensions/ are ALL unindexed cannot pass vacuously"
run_gate 1 "empty tracked set over a populated tree" all-untracked "tracks NO extension under extensions/"

echo ""
echo "17. #2425 review — ROOT inside a repo but not its toplevel: refuse (never read the outer index)"
run_gate 1 "nested tree inside another repo" nested-git "cannot read the git index"

echo ""
echo "18. #2425 review — a TRACKED path whose name contains a newline: refuse, never mis-name"
run_gate 1 "tracked newline name" newline-name "contains a newline"

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pi-config extension gate test(s) failed"
  exit 1
fi
echo "✅ All pi-config extension-farm parity gate tests passed"
