#!/bin/bash
# #498 — pi-config extension-farm parity gate tests.
#
# Exercises scripts/check-pi-config-extensions.sh semantics against
# runtime-built fixture trees (mechanism: cost-config test 10 — the gate
# computes ROOT from its own path, so a copy under a tmp tree gates that
# tree; no committed fixtures, no gate-script override needed):
#   1. clean farm (links resolve into extensions/, *.test.ts unwired) → PASS
#   2. materialized copy over a link  (check 1)  → BLOCK, exit 1
#   3. mistargeted link (check 2)                → BLOCK, exit 1
#   4. broken farm link (check 2, resolve "")    → BLOCK, exit 1
#   5. extension present but not wired (check 3) → BLOCK, exit 1
#
# Fixture trees mirror the real farm: relative symlinks ../../../extensions/<e>
# from pi-bootstrap/pi-config/extensions/ into extensions/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-pi-config-extensions.sh"
OUT="$(mktemp /tmp/pi-config-ext-out.XXXXXX)"
failures=0

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# build_farm <mode> — fresh tmp tree per case; echoes the tree path.
# mode: clean | copy | retarget | broken | unwired
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
  esac
  echo "$TMP"
}

# run_gate <expected-exit> <label> <mode> [grep-for]
run_gate() {
  local expected="$1"; shift
  local label="$1"; shift
  local mode="$1"; shift
  local grep_for="${1:-}"
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
  if [ -n "$grep_for" ]; then
    if grep -q "$grep_for" "$OUT"; then
      pass "diagnostic present: $grep_for"
    else
      fail "expected diagnostic: $grep_for"
      sed -n '1,40p' "$OUT"
    fi
  fi
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
echo "5. Extension present but not wired (check 3) → BLOCK, exit 1"
run_gate 1 "unwired extension" unwired "not wired into pi-config"

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pi-config extension gate test(s) failed"
  exit 1
fi
echo "✅ All pi-config extension-farm parity gate tests passed"
