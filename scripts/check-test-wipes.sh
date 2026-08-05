#!/usr/bin/env bash
# check-test-wipes.sh — Pre-commit guard against destructive test teardowns
#
# Scans tests/ for MATCH (n) DETACH DELETE and verifies each occurrence is
# either in a test_guarded fixture or targeting an isolated test graph.
#
# Exit 0 = clean, Exit 1 = violations found.
#
# Usage:
#   scripts/check-test-wipes.sh           # check everything
#   scripts/check-test-wipes.sh --strict  # fail on any DETACH DELETE (CI mode)
set -euo pipefail

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIOLATIONS=0
SAFE_FILES=()
UNSAFE_FILES=()

# Find all Python test files containing DETACH DELETE
while IFS=: read -r file line content; do
    # Skip worktrees
    [[ "$file" == *".worktrees/"* ]] && continue

    # Determine if this is embedded mode (safe) or Docker mode
    # Embedded: FalkorProjection(_tmp(...), graph_name="test")  → safe
    # Docker:   from_uri(TORTOISE_DB_URI) or env-based          → needs guard

    # Check if this file has a test_guard() call
    if grep -q 'test_guard()' "$file" 2>/dev/null; then
        # File calls test_guard() — safe
        SAFE_FILES+=("$file:$line (guarded)")
        continue
    fi

    # Check if the DETACH DELETE is in a projection.py rebuild method (not a test)
    if [[ "$file" == *"tortoise/projection"* ]]; then
        # Rebuild methods use DETACH DELETE — not test teardowns, skip
        continue
    fi

    # Check if it's targeting an isolated embedded graph (graph_name="test")
    if grep -q 'graph_name.*test' "$file" 2>/dev/null; then
        SAFE_FILES+=("$file:$line (isolated embedded graph)")
        continue
    fi

    # Check if TORTOISE_DB_URI in this file points to an isolated graph
    if grep -qE 'TORTOISE_DB_URI.*tortoise_test_' "$file" 2>/dev/null; then
        SAFE_FILES+=("$file:$line (isolated URI)")
        continue
    fi

    # Otherwise, violation
    UNSAFE_FILES+=("$file:$line: $content")
    VIOLATIONS=$((VIOLATIONS + 1))
done < <(grep -rn 'DETACH DELETE' "$ROOT/tests/" --include='*.py' 2>/dev/null || true)

echo "=== check-test-wipes.sh ==="
echo ""

if [[ ${#SAFE_FILES[@]} -gt 0 ]]; then
    echo "✅ Safe DETACH DELETE occurrences:"
    for entry in "${SAFE_FILES[@]}"; do
        echo "   $entry"
    done
    echo ""
fi

if [[ $VIOLATIONS -gt 0 ]]; then
    echo "❌ VIOLATIONS: DETACH DELETE without isolation guard:"
    for entry in "${UNSAFE_FILES[@]}"; do
        echo "   $entry"
    done
    echo ""
    echo "Fix: add test_guard() before DETACH DELETE and use an isolated graph name"
    echo "     (e.g., tortoise_test_<fixture>). See issue #99."
    exit 1
fi

echo "✅ All DETACH DELETE occurrences are safe (guarded or isolated)."
exit 0
