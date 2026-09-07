#!/usr/bin/env bash
# check-handoff-size.test.sh — self-check for scripts/check-handoff-size.sh
# (#365 indicator 2). Run:
#   bash scripts/check-handoff-size.test.sh
# Exit 0 all-pass · 1 any failure. Self-contained: temp files only.
#
# Coverage:
#   PASS        file under the default budget → exit 0
#   BLOCK       file over the default budget → exit 1 + remediation line
#   SEAM        HANDOFF_MAX_BYTES env / --max-bytes flag both honored
#   STDIN       piped handoff doc over budget → exit 1
#   USAGE       bad --max-bytes / missing file → exit 2 (never a silent pass)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-handoff-size.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_rc() { # <want> <got> <label>
    if [ "$2" -eq "$1" ]; then ok "$3"; else bad "$3 (want rc=$1, got rc=$2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

T="$(mktemp -d /tmp/check-handoff-size.XXXXXX)"; trap 'rm -rf "$T"' EXIT
SMALL="$T/small.md"; BIG="$T/big.md"
printf '## Completed\n- small handoff under budget\n' > "$SMALL"                      # ~45 B
python3 -c "print('x' * 20000)" > "$BIG"                                             # 20 KB > 16 KiB

# ── PASS: under default budget ────────────────────────────────────────────
OUT="$(bash "$CHECK" "$SMALL" 2>&1)" || RC=$?
assert_rc 0 "${RC:-0}" "small file under default budget exits 0"

# ── BLOCK: over default budget ────────────────────────────────────────────
RC=0; OUT="$(bash "$CHECK" "$BIG" 2>&1)" || RC=$?
assert_rc 1 "$RC" "file over default budget exits 1"
assert_contains "$OUT" "over budget: $BIG" "violation names the offender"
assert_contains "$OUT" "session-lifecycle-contract.md §2" "violation prints the remediation pointer"

# ── SEAM: env + flag budget overrides ─────────────────────────────────────
RC=0; OUT="$(HANDOFF_MAX_BYTES=30000 bash "$CHECK" "$BIG" 2>&1)" || RC=$?
assert_rc 0 "$RC" "HANDOFF_MAX_BYTES=30000 accepts the 20 KB file"
RC=0; OUT="$(bash "$CHECK" --max-bytes 10 "$SMALL" 2>&1)" || RC=$?
assert_rc 1 "$RC" "--max-bytes 10 blocks the ~45 B file"
assert_contains "$OUT" "over budget" "--max-bytes violation is reported"

# ── STDIN form ────────────────────────────────────────────────────────────
RC=0; OUT="$(cat "$BIG" | bash "$CHECK" 2>&1)" || RC=$?
assert_rc 1 "$RC" "piped handoff over budget exits 1"
assert_contains "$OUT" "(stdin)" "stdin offender labelled"

# ── USAGE errors (exit 2, never a silent pass) ────────────────────────────
RC=0; OUT="$(bash "$CHECK" --max-bytes abc "$SMALL" 2>&1)" || RC=$?
assert_rc 2 "$RC" "non-numeric --max-bytes exits 2"
RC=0; OUT="$(bash "$CHECK" "$T/missing.md" 2>&1)" || RC=$?
assert_rc 2 "$RC" "missing file exits 2"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL failure(s), $PASS passed — check-handoff-size.test.sh FAILED"
    exit 1
fi
echo "✅ all $PASS assertions passed — check-handoff-size.test.sh clean"
exit 0
