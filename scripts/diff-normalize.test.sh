#!/usr/bin/env bash
# diff-normalize.test.sh — the unit contract for scripts/lib/diff-normalize.py
# (agent-infra #1362, unit D1; owner ruling 2026-09-23).
#
# The normalizer is the ONE implementation of the review-evidence diff
# normalization, and it is a CROSS-REPO CONTRACT: the consumer (`tortoise`
# .github/workflows/ai-review-gate.yml) mirrors it. If the two sides normalize
# differently, one produces a digest the other cannot verify and every
# freshly-signed marker stops matching fleet-wide (the #3076 shape). These
# assertions therefore pin the contract's EXACT output bytes, not a summary of
# them.
#
# Run: bash scripts/diff-normalize.test.sh
# Hermetic: no network, no git, no gh; temp files only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORM="$SCRIPT_DIR/lib/diff-normalize.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else
        bad "$3"
        printf '      got:  %q\n      want: %q\n' "$1" "$2"
    fi
}
assert_ne() {
    if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (both: $1)"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/diff-normalize-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
[ -x "$NORM" ] && ok "normalizer is executable ($(basename "$NORM"))" || bad "normalizer is not executable: $NORM"

norm() { python3 "$NORM"; }                       # stdin → normalized stdout
sha()  { openssl dgst -sha256 | awk '{print $NF}'; }

echo "── the 5 REQUIRED vectors (exact) ─────────────────────────────────"
assert_eq "$(printf '%s\n' '@@ -1,5 +1,7 @@' | norm)"           '@@ -0,5 +0,7 @@'         "hunk: counts kept, start lines zeroed"
assert_eq "$(printf '%s\n' '@@ -12 +12 @@' | norm)"              '@@ -0,1 +0,1 @@'        "hunk: absent counts default to 1"
assert_eq "$(printf '%s\n' '@@ -12,0 +13,4 @@ def f():' | norm)" '@@ -0,0 +0,4 @@ def f():' "hunk: section heading preserved verbatim"
assert_eq "$(printf '%s\n' 'index 1a2b3c4..5d6e7f8 100644' | norm)" ''                     "index line WITH mode: dropped"
assert_eq "$(printf '%s\n' 'index 1a2b3c4..5d6e7f8' | norm)"         ''                     "index line WITHOUT mode: dropped"

echo "── what must NOT be normalized ────────────────────────────────────"
assert_eq "$(printf '%s\n' 'index 1A2B3C4..5D6E7F8 100644' | norm)" 'index 1A2B3C4..5D6E7F8 100644' \
    "uppercase hex is NOT git's format: passed through, not dropped"
assert_eq "$(printf '%s\n' 'index 1a2b3c4..5d6e7f8 10064' | norm)" 'index 1a2b3c4..5d6e7f8 10064' \
    "a 5-digit mode does not match the ERE: passed through"
assert_eq "$(printf '%s\n' 'new file mode 100644' | norm)" 'new file mode 100644'   "mode line passes through"
assert_eq "$(printf '%s\n' 'rename from a' 'rename to b' | norm)" "$(printf 'rename from a\nrename to b')" "rename lines pass through"
assert_eq "$(printf '%s\n' '@@ -0,3 +0,4 @@' | norm)" '@@ -0,3 +0,4 @@'             "already-normalized hunk is a fixed point"
# Counts are DERIVED data and are kept — only the START line is zeroed.
assert_ne "$(printf '%s\n' '@@ -1,3 +1,4 @@' | norm)" "$(printf '%s\n' '@@ -1,4 +1,5 @@' | norm)" \
    "hunk COUNTS are kept (a count change survives)"
# The section heading is part of the reviewed context and is kept.
assert_ne "$(printf '%s\n' '@@ -1,3 +1,4 @@ func a()' | norm)" "$(printf '%s\n' '@@ -1,3 +1,4 @@ func b()' | norm)" \
    "hunk section heading is kept"

echo "── byte preservation (trailing newline + non-ASCII) ───────────────"
printf 'plain line'   | norm > "$T/no-nl"
printf 'plain line\n' | norm > "$T/with-nl"
assert_eq "$(wc -c < "$T/no-nl" | tr -d ' ')"   "10" "a MISSING trailing newline is preserved (10 bytes)"
assert_eq "$(wc -c < "$T/with-nl" | tr -d ' ')" "11" "a PRESENT trailing newline is preserved (11 bytes)"
if cmp -s "$T/no-nl" "$T/with-nl"; then bad "trailing newline did not change the bytes"; else ok "trailing newline changes the bytes (the digest is byte-exact)"; fi
assert_eq "$(printf '' | norm | wc -c | tr -d ' ')" "0" "empty input → empty output"
assert_eq "$(printf '\n' | norm | wc -c | tr -d ' ')" "1" "a lone newline survives"
# Non-ASCII content must round-trip byte-for-byte (latin-1 1:1 codec).
printf 'caf\xc3\xa9 \xf0\x9f\x98\x80\n' | norm > "$T/utf8"
printf 'caf\xc3\xa9 \xf0\x9f\x98\x80\n' > "$T/utf8.expected"
if cmp -s "$T/utf8" "$T/utf8.expected"; then ok "non-ASCII bytes round-trip exactly"; else bad "non-ASCII bytes were altered"; fi
# Idempotence: the normalized form is a fixed point.
printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n@@ -1,3 +1,4 @@\n ctx\n+added\n' | norm > "$T/once"
norm < "$T/once" > "$T/twice"
if cmp -s "$T/once" "$T/twice"; then ok "normalization is idempotent"; else bad "normalization is NOT idempotent"; fi

echo "── the three D1 properties, as bytes ──────────────────────────────"
# The SAME change rendered against two different bases (index + hunk start
# lines moved, every content line identical) — the base-move shape.
B1="$T/b1.diff";  printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n ctx\n+added\n ctx2\n' > "$B1"
B2="$T/b2.diff";  printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+added\n ctx2\n' > "$B2"
CX="$T/content.diff"; printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+added-CHANGED\n ctx2\n' > "$CX"
WS="$T/ws.diff";      printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+ added\n ctx2\n' > "$WS"
nsha() { python3 "$NORM" < "$1" | sha; }
rsha() { sha < "$1"; }

assert_eq "$(nsha "$B1")" "$(nsha "$B2")" "D1(a): a base-only update leaves the normalized digest UNCHANGED"
assert_ne "$(rsha "$B1")" "$(rsha "$B2")" "D1(a): the raw digest DID move (so this is the normalization, not the fixture)"
assert_ne "$(nsha "$B2")" "$(nsha "$CX")" "D1(b): a content change DOES change the normalized digest"
assert_ne "$(nsha "$B2")" "$(nsha "$WS")" "D1(c): a whitespace-only change DOES change the normalized digest"
assert_ne "$(rsha "$B2")" "$(rsha "$CX")" "D1(b) control: the raw digest also moved on the content change"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
