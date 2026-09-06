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
#
# Fixture trees mirror the real farm: relative symlinks ../../../extensions/<e>
# from pi-bootstrap/pi-config/extensions/ into extensions/, plus a manifest.json
# at the tree root (the consumer ship-list check 4 gates).
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
#       manifest-stale | no-manifest | bad-manifest
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
    copy)     : > "$FARM/b.ts" ;;                                    # materialized copy
    retarget) ln -s ../../../extensions/a.ts "$FARM/b.ts" ;;         # resolves, wrong target
    broken)   ln -s ../../../extensions/missing.ts "$FARM/b.ts" ;;   # resolves to ""
    unwired)  ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/e.ts" ;;                          # new ext, NOT wired
    manifest-missing) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest omits b.ts
    manifest-stale)   ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest lists z.ts below
    no-manifest)      ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, no manifest.json at all
    bad-manifest)     ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest.json unparseable
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
  echo "$TMP"
}

# run_gate <expected-exit> <label> <mode> [grep-for]... — each grep-for must
# appear in the gate output (multiple = all required).
run_gate() {
  local expected="$1"; shift
  local label="$1"; shift
  local mode="$1"; shift
  local TMP
  TMP="$(build_farm "$mode")"
  bash "$TMP/scripts/check-pi-config-extensions.sh" >"$OUT" 2>&1
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
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pi-config extension gate test(s) failed"
  exit 1
fi
echo "✅ All pi-config extension-farm parity gate tests passed"
