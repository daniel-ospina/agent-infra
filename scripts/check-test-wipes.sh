#!/usr/bin/env bash
# check-test-wipes.sh — Pre-commit guard against destructive test teardowns
#
# Scans tests/ for MATCH (n) DETACH DELETE and verifies each occurrence is
# either preceded by test_guard() in the same file or targets an isolated
# test graph. Per-occurrence detection: a file with one guarded + one
# unguarded DETACH DELETE correctly flags the unguarded one.
#
# Also scans conftest.py files for DETACH DELETE in fixtures without
# test_guard() protection.
#
# Exit 0 = clean, Exit 1 = violations found.
#
# Usage:
#   scripts/check-test-wipes.sh           # check everything
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIOLATIONS=0
SAFE_OCCURRENCES=()
UNSAFE_OCCURRENCES=()

# ── Per-occurrence scan of test files ─────────────────────────────────────
while IFS=: read -r file line content; do
    # Skip worktrees
    [[ "$file" == *".worktrees/"* ]] && continue

    # Skip projection.py rebuild methods (not test teardowns)
    if [[ "$file" == *"tortoise/projection"* ]]; then
        continue
    fi

    # P0 fix: per-occurrence check — does test_guard() appear on or before
    # this DETACH DELETE line? Scan lines 1..$line excluding Python comments.
    if head -n "$line" "$file" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -q 'test_guard()'; then
        SAFE_OCCURRENCES+=("$file:$line (guarded)")
        continue
    fi

    # Check if it's targeting an isolated embedded graph (graph_name="test")
    if grep -q 'graph_name.*test' "$file" 2>/dev/null; then
        SAFE_OCCURRENCES+=("$file:$line (isolated embedded graph)")
        continue
    fi

    # Check if TORTOISE_DB_URI in this file points to an isolated graph
    if grep -qE 'TORTOISE_DB_URI.*tortoise_test_' "$file" 2>/dev/null; then
        SAFE_OCCURRENCES+=("$file:$line (isolated URI)")
        continue
    fi

    # Otherwise, violation — this specific DETACH DELETE lacks a guard
    UNSAFE_OCCURRENCES+=("$file:$line: $content")
    VIOLATIONS=$((VIOLATIONS + 1))
done < <(grep -rn 'DETACH DELETE' "$ROOT/tests/" --include='*.py' 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#.*DETACH DELETE' || true)

# ── P1: Scan conftest.py files for DETACH DELETE in fixtures ──────────────
CONFTEST_VIOLATIONS=0
while IFS= read -r conftest_file; do
    if grep -q 'DETACH DELETE' "$conftest_file" 2>/dev/null; then
        if ! grep -q 'test_guard()' "$conftest_file" 2>/dev/null; then
            DETACH_LINES=$(grep -n 'DETACH DELETE' "$conftest_file" | cut -d: -f1 | tr '\n' ' ')
            UNSAFE_OCCURRENCES+=("$conftest_file:${DETACH_LINES%% } (conftest fixture without test_guard())")
            CONFTEST_VIOLATIONS=$((CONFTEST_VIOLATIONS + 1))
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi
done < <(find "$ROOT/tests/" -name 'conftest.py' -type f 2>/dev/null || true)

# ── Report ─────────────────────────────────────────────────────────────────
echo "=== check-test-wipes.sh ==="
echo ""

if [[ ${#SAFE_OCCURRENCES[@]} -gt 0 ]]; then
    echo "✅ Safe DETACH DELETE occurrences:"
    for entry in "${SAFE_OCCURRENCES[@]}"; do
        echo "   $entry"
    done
    echo ""
fi

if [[ $VIOLATIONS -gt 0 ]]; then
    echo "❌ VIOLATIONS: DETACH DELETE without isolation guard:"
    for entry in "${UNSAFE_OCCURRENCES[@]}"; do
        echo "   $entry"
    done
    echo ""
    echo "Fix: add test_guard() before DETACH DELETE and use an isolated graph name"
    echo "     (e.g., tortoise_test_<fixture>). See issue #99."
    exit 1
fi

echo "✅ All DETACH DELETE occurrences are safe (guarded or isolated)."
exit 0
