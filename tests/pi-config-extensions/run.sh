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
#  13. a directory whose ONLY content is git-ignored (the #2425 incident:
#      extensions/<x>/node_modules/ left by `npm install`) → PASS, and its
#      pass line NAMES the tracked reading.
#  13b. RED CONTROL — the same fixture with the ignore rule removed → BLOCK (so
#      case 13 is a pin, not a decorative pass: same bytes, one `.gitignore`
#      line apart).
#  14. a farm entry / manifest row naming an entry that has no tracked content
#      (ignored leftovers) → BLOCK in both directions, exit 1 (#2425 mirror)
#  15. not a git work tree at all (git cannot be asked) → BLOCK, exit 1 — the
#      reading is never silently taken from the filesystem (#2425)
#  16. an extension created but NOT `git add`ed and not ignored → BLOCK (pins the
#      `--others` half; bare `--cached` would MISS it)
#  17. the user's GLOBAL excludes file names the directory, the repo's .gitignore
#      does not → BLOCK (pins `--exclude-per-directory=.gitignore`; the ambient
#      `--exclude-standard` would consult it and pass)
#  18. a script tree nested inside a repo → answers about its OWN extensions/
#      (ROOT-relative reading), never the enclosing repo's
#  19. nothing under extensions/ at all → BLOCK (a gate that read nothing must
#      not pass)
#  20. a tracked entry erased from THIS worktree → its manifest row is not called
#      stale (4b asks git first)
#  21. ambient `GIT_DIR` naming a FOREIGN repo → the gate still answers about
#      THIS checkout (the redirect vars are unset)
#
# Every case is mutation-checked in the PR body: the suite must go RED when the
# behaviour it pins is reverted.
#
# NOT pinned here, by design: the `git is not on PATH` and `git ls-files`
# non-zero branches of the fail-closed chain. Both need a hostile PATH or a
# corrupted `.git` (non-hermetic / mutating the fixture's repo metadata) to
# reach, and the two branches that ARE reachable hermetically — not a work tree
# (15) and an empty reading (19) — are pinned. Leaving them untested is stated
# here rather than silently assumed.
#
# Fixture trees mirror the real farm: relative symlinks ../../../extensions/<e>
# from pi-bootstrap/pi-config/extensions/ into extensions/, plus a manifest.json
# at the tree root (the consumer ship-list check 4 gates).
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
#       live-dangling | ignored-only | node-modules-unignored | ignored-refd |
#       untracked | global-exclude | subdir | empty | no-git
# The live-farm dir is always $TMP/live-extensions (run_gate points
# PI_EXTENSIONS_DIR at it); only the live-* modes create it, so every other mode
# exercises check 5's explicit skip.
#
# Every fixture tree is a REAL git work tree (#2425): the gate answers its
# tree-side questions over tracked content, so a fixture without `.git` would
# exercise the fail-closed "not a git work tree" path instead of the case under
# test. `git add -A` marks the fixture's content tracked; ignoring is decided by
# the fixture's own `.gitignore`, exactly as in a real checkout.
build_farm() {
  local mode="$1"
  local TMP
  TMP="$(mktemp -d /tmp/pi-config-ext-fixture.XXXXXX)"
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
    # #2425 fixtures keep the clean farm wiring — the ignore rule is the ONLY
    # variable, so no other drift can mask or manufacture the verdict.
    ignored-only|node-modules-unignored|no-git|untracked|global-exclude|subdir|tracked-absent-on-disk|foreign-git-dir) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
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
    ignored-refd)     ln -s ../../../extensions/b.ts "$FARM/b.ts"
                      ln -s ../../../extensions/vision-interceptor "$FARM/vision-interceptor" ;; # farm entry → ignored-only dir
  esac

  # #2425 fixtures — the shape the incident reported: `npm install` inside
  # extensions/<x>/ leaves a directory whose ONLY content is git-ignored. It has
  # no package.json, no tracking, nothing to wire, nothing to ship.
  #   ignored-only          → ignored, unreferenced  → MUST PASS (the incident)
  #   node-modules-unignored → same bytes, NO ignore rule → MUST BLOCK (red control)
  #   ignored-refd          → ignored dir referenced by the farm AND the manifest
  #                           → MUST BLOCK in both directions
  case "$mode" in
    ignored-only|node-modules-unignored|ignored-refd)
      mkdir -p "$TMP/extensions/vision-interceptor/node_modules/left-pad"
      : > "$TMP/extensions/vision-interceptor/node_modules/left-pad/index.js" ;;
  esac
  case "$mode" in
    ignored-only|ignored-refd) printf 'node_modules/\n' > "$TMP/.gitignore" ;;
  esac

  # manifest.json rows: tree extensions a.ts + d/ always present; b.ts unless
  # mode is manifest-missing; e.ts absent in unwired (its own drift); z.ts
  # listed ONLY in manifest-stale (stale row — no tree counterpart).
  # no-manifest: omit the file (check 4 fail-closed on missing manifest).
  # bad-manifest: write malformed JSON (check 4 fail-closed on parse error).
  case "$mode" in
    manifest-missing) write_manifest "$TMP/manifest.json" a.ts d/ ;;
    manifest-stale)   write_manifest "$TMP/manifest.json" a.ts b.ts d/ z.ts ;;
    ignored-refd)     write_manifest "$TMP/manifest.json" a.ts b.ts d/ vision-interceptor/ ;;
    empty)            write_manifest "$TMP/manifest.json" ;;   # no rows: the reading is empty
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

  if [ "$mode" = "empty" ]; then
    # Nothing in the tree, nothing wired, nothing in the manifest — the gate's
    # reading is EMPTY. It must refuse rather than pass having read nothing.
    rm -rf "$TMP/extensions"/* "$FARM"/*
  fi

  # Every fixture is a REAL git work tree (#2425): the gate's tree-side
  # questions are answered over tracked content, so a fixture with no `.git`
  # would exercise the fail-closed "no git" path instead of the case under test.
  # `git add -A` is what makes content TRACKED — and it deliberately cannot add
  # an ignored path, which is precisely the distinction cases 13-14 pin.
  # `no-git` is the single fixture left outside a repo, to pin that fail-closed
  # reading.
  if [ "$mode" != "no-git" ]; then
    if ! git -C "$TMP" init -q 2>/dev/null; then
      # build_farm's stdout is captured as the tree path — a diagnostic printed
      # here would corrupt it, so fixture errors go to stderr.
      echo "   ❌ FIXTURE: git init failed in $TMP (the gate now needs a real work tree)" >&2
      failures=$((failures + 1))
    fi
    git -C "$TMP" add -A >/dev/null 2>&1 || true
  fi

  # Post-add content: pins the `--others` half of the reading. This extension is
  # NOT ignored and NOT staged — exactly the state of a directory an author just
  # created and has not `git add`ed. Dropping `--others` (reverting to bare
  # `--cached`) must make this fixture PASS, failing the case below.
  case "$mode" in
    untracked) : > "$TMP/extensions/fresh-off-the-disk.ts" ;;
  esac

  # Machine-local exclude config: the repo's own .gitignore does NOT ignore this
  # extension, but the user's GLOBAL excludes file does. The reading must not
  # depend on ambient machine state (`--exclude-standard` would consult it and
  # silently drop the entry, the very defect this gate closes). run_gate exports
  # GIT_CONFIG_GLOBAL at the fixture's config for this one mode.
  case "$mode" in
    global-exclude)
      mkdir -p "$TMP/extensions/locally-hidden"
      : > "$TMP/extensions/locally-hidden/index.ts"
      printf 'locally-hidden/\n' > "$TMP/global-excludes"
      printf '[core]\n\texcludesFile = %s/global-excludes\n' "$TMP" > "$TMP/gitconfig" ;;
  esac

  # A tracked entry erased from THIS worktree (the sparse-checkout / local-delete
  # shape): git still carries it, so its manifest row must NOT be reported as
  # stale. 4b's tracked leg runs first for exactly this case.
  # The farm link for `d` is REMOVED with it: leaving it would dangle, and check
  # 2's realpath is platform-dependent for a missing target (GNU realpath
  # resolves it, BSD/macOS returns empty), which would red this case for a reason
  # it does not pin. With no farm link, the unavoidable companion diagnostic is
  # check 3's "carried but not wired" — and the ABSENT needle below is what pins
  # 4b's ordering.
  case "$mode" in
    tracked-absent-on-disk)
      rm -rf "$TMP/extensions/d" "$TMP/pi-bootstrap/pi-config/extensions/d" ;;
  esac

  # A foreign GIT_DIR must not decide this repository's verdict: ambient
  # `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` can point the reading at ANOTHER
  # repo (the reviewer reproduced a gate answering about a foreign index). The
  # gate unsets them; this fixture gives the gate a foreign repo whose extension
  # list (`ghost`) is NOT this tree's, so a reading that honoured the ambient
  # value would report `ghost` and fail.
  case "$mode" in
    foreign-git-dir)
      mkdir -p "$TMP/foreign/extensions/ghost"
      : > "$TMP/foreign/extensions/ghost/index.ts"
      git -C "$TMP/foreign" init -q
      git -C "$TMP/foreign" add -A >/dev/null 2>&1 ;;
  esac

  # A script tree NESTED inside a repo must answer about ITS OWN extensions/:
  # git resolves the `extensions/` pathspec against $ROOT (verified), so a nested
  # ROOT reads $ROOT/extensions, never the enclosing repo's. The nested tree here
  # is fully consistent while the OUTER tree carries an unwired extension — so a
  # gate that answered about the outer tree would report `outer-orphan` and fail.
  case "$mode" in
    subdir)
      mkdir -p "$TMP/sub/scripts" "$TMP/sub/extensions/nested-d" \
               "$TMP/sub/pi-bootstrap/pi-config/extensions"
      cp "$GUARD" "$TMP/sub/scripts/check-pi-config-extensions.sh"
      : > "$TMP/sub/extensions/nested-a.ts"
      : > "$TMP/sub/extensions/nested-d/index.ts"
      ln -s ../../../extensions/nested-a.ts "$TMP/sub/pi-bootstrap/pi-config/extensions/nested-a.ts"
      ln -s ../../../extensions/nested-d "$TMP/sub/pi-bootstrap/pi-config/extensions/nested-d"
      write_manifest "$TMP/sub/manifest.json" nested-a.ts nested-d/
      : > "$TMP/extensions/outer-orphan.ts" ;;
  esac
  echo "$TMP"
}

# run_gate <expected-exit> <label> <mode> [grep-for]... — each grep-for must
# appear in the gate output (multiple = all required). A grep-for prefixed with
# `!` must NOT appear — the only way to pin an ABSENCE (an ignored directory
# must produce no "not wired" diagnostic at all, not merely a green exit).
run_gate() {
  local expected="$1"; shift
  local label="$1"; shift
  local mode="$1"; shift
  local TMP
  TMP="$(build_farm "$mode")"
  # A vacuous pass is worse than no test: assert the ignore rule actually
  # ignores, so case 13 cannot pass because the fixture forgot to ignore.
  case "$mode" in
    ignored-only|ignored-refd)
      if git -C "$TMP" check-ignore -q extensions/vision-interceptor/node_modules/left-pad/index.js; then
        pass "FIXTURE: node_modules content is git-ignored in the fixture"
      else
        fail "FIXTURE: node_modules content is NOT ignored — the case would be vacuous"
      fi ;;
  esac
  # Check 5 is aimed at the fixture dir in every case (see the suite header), so
  # the verdict is hermetic and the real ~/.pi never participates.
  export PI_EXTENSIONS_DIR="$TMP/live-extensions"
  # Per-case gate entry point: `subdir` runs the gate from BELOW the work-tree
  # root (its ROOT is $TMP/sub, not the toplevel) — the case that must be
  # refused rather than answered from an empty pathspec.
  local GATE_PATH="$TMP/scripts/check-pi-config-extensions.sh"
  [ "$mode" = "subdir" ] && GATE_PATH="$TMP/sub/scripts/check-pi-config-extensions.sh"
  # `foreign-git-dir` gives the gate's own git an ambient GIT_DIR naming another
  # repo, which must NOT change the reading (the gate unsets the redirect vars).
  # `global-exclude` gives it an ambient GLOBAL excludes file, which must NOT
  # change the reading either (only .gitignore files may).
  if [ "$mode" = "foreign-git-dir" ]; then
    GIT_DIR="$TMP/foreign/.git" bash "$GATE_PATH" >"$OUT" 2>&1
    local code=$?
  elif [ "$mode" = "global-exclude" ]; then
    GIT_CONFIG_GLOBAL="$TMP/gitconfig" bash "$GATE_PATH" >"$OUT" 2>&1
    local code=$?
  else
    bash "$GATE_PATH" >"$OUT" 2>&1
    local code=$?
  fi
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,60p' "$OUT"
  fi
  for grep_for in "$@"; do
    case "$grep_for" in
      '!'*)
        # absent() — the fixture must NOT produce this line.
        if grep -q "${grep_for#!}" "$OUT"; then
          fail "unexpected diagnostic (must be absent): ${grep_for#!}"
          sed -n '1,40p' "$OUT"
        else
          pass "diagnostic absent: ${grep_for#!}"
        fi
        continue ;;
    esac
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
run_gate 1 "unwired extension" unwired "not wired into pi-config" "has no manifest.json files.extensions.entries row"

echo ""
echo "6. Extension in tree+farm but no manifest row (check 4a, #502) → BLOCK, exit 1"
run_gate 1 "manifest row missing" manifest-missing "has no manifest.json files.extensions.entries row"

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
echo "13. A directory whose only content is git-ignored (#2425 incident) → PASS, and the pass line names the TRACKED reading"
run_gate 0 "ignored node_modules-only dir" ignored-only \
  "answered over TRACKED content" \
  "!not wired into pi-config" \
  "!has no manifest.json files.extensions.entries row" \
  "!carries NO tracked or non-ignored content"

echo ""
echo "13b. RED CONTROL — the same directory with the ignore rule removed → BLOCK, exit 1"
# Same bytes, same farm, same manifest as case 13: only `.gitignore` differs.
# If this case ever passes, case 13 proves nothing.
run_gate 1 "unignored node_modules dir" node-modules-unignored \
  "extension vision-interceptor is carried by this repo (git has content for it: tracked, or untracked and not git-ignored) but is not wired into pi-config" \
  "has no manifest.json files.extensions.entries row"

echo ""
echo "14. Farm entry + manifest row naming an entry with NO tracked content → BLOCK both directions, exit 1"
run_gate 1 "rows over ignored-only content" ignored-refd \
  "nothing ships for this farm entry" \
  "nothing ships for this row"

echo ""
echo "15. Not a git work tree at all → BLOCK, exit 1 (the reading is never taken from the filesystem)"
run_gate 1 "no git work tree" no-git "is not inside a git work tree"

echo ""
echo "16. An extension created but NOT yet \`git add\`ed (not ignored either) → BLOCK, exit 1 (pins the \`--others\` half: reverting to bare \`--cached\` makes this PASS)"
run_gate 1 "un-added extension still counts" untracked \
  "extension fresh-off-the-disk.ts is carried by this repo"

echo ""
echo "17. Machine-local GLOBAL excludes name the directory, the repo's .gitignore does not → BLOCK, exit 1 (pins \`--exclude-per-directory=.gitignore\`; \`--exclude-standard\` would consult the global file and pass)"
run_gate 1 "ambient global excludes ignored" global-exclude \
  "extension locally-hidden is carried by this repo"

echo ""
echo "18. A script tree NESTED inside a repo → PASS, exit 0, answering about its OWN extensions/ (the enclosing tree's unwired extension must not be reported)"
run_gate 0 "nested root reads its own extensions" subdir \
  "answered over TRACKED content" \
  "!outer-orphan"

echo ""
echo "19. Nothing in extensions/ at all → BLOCK, exit 1 (a gate that read nothing must not pass)"
run_gate 1 "empty reading" empty \
  "no tracked or non-ignored content under"

echo ""
echo "20. A tracked extension erased from THIS worktree (sparse/local-delete) → its manifest row is NOT called stale: 4b asks git first, and git carries the entry the worktree no longer has"
run_gate 1 "tracked-but-absent entry is not stale" tracked-absent-on-disk \
  "extension d is carried by this repo" \
  "!has no matching extensions/ entry"

echo ""
echo "21. Ambient GIT_DIR pointing at a FOREIGN repo → the gate still answers about THIS checkout (unsets the redirect vars); a reading that honoured it would report the foreign extension 'ghost'"
run_gate 0 "foreign GIT_DIR ignored" foreign-git-dir \
  "answered over TRACKED content" \
  "!ghost"

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pi-config extension gate test(s) failed"
  exit 1
fi
echo "✅ All pi-config extension-farm parity gate tests passed"
