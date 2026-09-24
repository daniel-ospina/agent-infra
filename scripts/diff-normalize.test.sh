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
# The 2026-09-23 AMENDMENT (recorded on agent-infra#1362) makes the `index` drop
# ENTRY-SCOPED: a binary entry has NO hunk, so its `index` line is the entry's
# ONLY content-bearing field and dropping it made two different binaries
# normalize to the SAME digest (a fail-open in a required merge gate). The
# contract sentence is "drop the `index` line exactly when the hunk content
# already carries the change"; the §amendment section pins the carve-out, its
# siblings, and the mutation that re-opens the hole.
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
# The index drop is ENTRY-SCOPED (2026-09-23 amendment): it fires only when the
# entry's hunk content already carries the change, so both drop vectors are real
# hunk-bearing entries. A bare index line is hunk-less and is KEPT — pinned as
# §amendment (f).
E_IDX_MODE='diff --git a/f b/f
index 1a2b3c4..5d6e7f8 100644
--- a/f
+++ b/f
@@ -1 +1 @@
-a
+b'
assert_eq "$(printf '%s\n' "$E_IDX_MODE" | norm)" \
    "$(printf '%s\n' 'diff --git a/f b/f' '--- a/f' '+++ b/f' '@@ -0,1 +0,1 @@' '-a' '+b')" \
    "index line WITH mode inside a hunk entry: dropped"
E_IDX_NOMODE='diff --git a/f b/f
old mode 100644
new mode 100755
index 1a2b3c4..5d6e7f8
--- a/f
+++ b/f
@@ -1 +1 @@
-a
+b'
assert_eq "$(printf '%s\n' "$E_IDX_NOMODE" | norm)" \
    "$(printf '%s\n' 'diff --git a/f b/f' 'old mode 100644' 'new mode 100755' '--- a/f' '+++ b/f' '@@ -0,1 +0,1 @@' '-a' '+b')" \
    "index line WITHOUT mode inside a hunk entry (mode change): dropped"

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

echo "── AMENDMENT 2026-09-23: the index drop is ENTRY-SCOPED ──────────"
# Contract: drop the `index` line exactly when the hunk content already carries
# the change. A binary entry has NO hunk, so its `index` line is its only
# content-bearing field; dropping it made two different binaries normalize to
# the identical digest — a fail-open in a required merge gate (review binary v1,
# sign the marker, swap in binary v2, digest unchanged → the gate accepts an
# unreviewed binary).
norm_sha_with() { python3 "$1" < "$2" | sha; }

# ── (a) THE FAIL-OPEN IS CLOSED: two DIFFERENT binaries at the same path ──
BINA="$T/am-bin-a.diff"; printf 'diff --git a/f.bin b/f.bin\nindex 1111111..2222222 100644\nBinary files a/f.bin and b/f.bin differ\n' > "$BINA"
BINB="$T/am-bin-b.diff"; printf 'diff --git a/f.bin b/f.bin\nindex 1111111..3333333 100644\nBinary files a/f.bin and b/f.bin differ\n' > "$BINB"
assert_ne "$(nsha "$BINA")" "$(nsha "$BINB")"     "amendment (a): two DIFFERENT binaries normalize to DIFFERENT digests (fail-open closed)"
assert_ne "$(rsha "$BINA")" "$(rsha "$BINB")"     "amendment (a) control: the RAW digests also differ (the fixtures are not degenerate)"
assert_eq "$(norm < "$BINA")" "$(printf 'diff --git a/f.bin b/f.bin\nindex 1111111..2222222 100644\nBinary files a/f.bin and b/f.bin differ')" \
    "amendment (a): the binary entry's index line is KEPT verbatim"
# MUTATION PIN — restore the pre-amendment rule (unconditional index drop) and
# (a) collapses: the two binaries produce the IDENTICAL digest. That is why the
# shipped (a) assertion is load-bearing: with entry-scoping removed it goes red.
MUT_UNSCOPED="$T/mut-unscoped.py"
cat > "$MUT_UNSCOPED" <<'PY'
import re, sys
out = []
for line in sys.stdin.buffer.read().decode("latin-1").split("\n"):
    if re.match(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$", line):
        continue   # MUTATION: unconditional drop (the pre-amendment rule)
    m = re.match(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$", line)
    if m:
        line = "@@ -0,%s +0,%s @@%s" % (m.group(3) or "1", m.group(6) or "1", m.group(7))
    out.append(line)
sys.stdout.buffer.write("\n".join(out).encode("latin-1"))
PY
assert_eq "$(python3 "$MUT_UNSCOPED" < "$BINA")" "$(printf 'diff --git a/f.bin b/f.bin\nBinary files a/f.bin and b/f.bin differ')" \
    "amendment (a) mutation control: the mutant really drops the index line"
assert_eq "$(norm_sha_with "$MUT_UNSCOPED" "$BINA")" "$(norm_sha_with "$MUT_UNSCOPED" "$BINB")" \
    "amendment (a) MUTATION PIN: with entry-scoping REMOVED the two binaries COLLAPSE to one digest — (a) reddens"

# ── (b) TEXT base-move is still invariant (the ruling's win) ──
TBA="$T/am-txt-a.diff"; printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n ctx\n+added\n ctx2\n' > "$TBA"
TBB="$T/am-txt-b.diff"; printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+added\n ctx2\n' > "$TBB"
assert_eq "$(nsha "$TBA")" "$(nsha "$TBB")"     "amendment (b): a TEXT base move (index + hunk starts moved) is still invariant"
assert_ne "$(rsha "$TBA")" "$(rsha "$TBB")"     "amendment (b) control: the raw digest DID move"

# ── (c) BINARY base-move is invariant ──
# The binary entry's OWN index line does not move in a base move (the blob OIDs
# are content, not rendering); its neighbouring text entry's index and hunk
# starts do. That is the realistic base-move shape, and it must stay invariant.
CBA="$T/am-mix-a.diff"; printf 'diff --git a/f.bin b/f.bin\nindex da6639b..382c7b7 100644\nBinary files a/f.bin and b/f.bin differ\ndiff --git a/t b/t\nindex 1111111..2222222 100644\n--- a/t\n+++ b/t\n@@ -1,3 +1,4 @@\n ctx\n+added\n ctx2\n' > "$CBA"
CBB="$T/am-mix-b.diff"; printf 'diff --git a/f.bin b/f.bin\nindex da6639b..382c7b7 100644\nBinary files a/f.bin and b/f.bin differ\ndiff --git a/t b/t\nindex aaaaaaa..bbbbbbb 100644\n--- a/t\n+++ b/t\n@@ -10,3 +11,4 @@\n ctx\n+added\n ctx2\n' > "$CBB"
assert_eq "$(nsha "$CBA")" "$(nsha "$CBB")"     "amendment (c): a base move with a binary entry present is invariant"
assert_ne "$(rsha "$CBA")" "$(rsha "$CBB")"     "amendment (c) control: the raw digest DID move"
if python3 "$NORM" < "$CBA" | grep -qF 'index da6639b..382c7b7 100644'; then
    ok "amendment (c): the binary entry's index line is retained across the base move"
else bad "amendment (c): the binary entry's index line was dropped"; fi

# ── (d) binary ADD and binary DELETE → index kept ──
BADD="$T/am-bin-add.diff";  printf 'diff --git a/new.bin b/new.bin\nnew file mode 100644\nindex 0000000..382c7b7\nBinary files /dev/null and b/new.bin differ\n' > "$BADD"
BDEL="$T/am-bin-del.diff";  printf 'diff --git a/gone.bin b/gone.bin\ndeleted file mode 100644\nindex 382c7b7..0000000\nBinary files a/gone.bin and /dev/null differ\n' > "$BDEL"
assert_eq "$(norm < "$BADD")" "$(printf 'diff --git a/new.bin b/new.bin\nnew file mode 100644\nindex 0000000..382c7b7\nBinary files /dev/null and b/new.bin differ')" \
    "amendment (d): a binary ADD keeps its index line (0000000..<new>) byte-for-byte"
assert_eq "$(norm < "$BDEL")" "$(printf 'diff --git a/gone.bin b/gone.bin\ndeleted file mode 100644\nindex 382c7b7..0000000\nBinary files a/gone.bin and /dev/null differ')" \
    "amendment (d): a binary DELETE keeps its index line (<old>..0000000) byte-for-byte"
GITBIN="$T/am-gitbin.diff"; printf 'diff --git a/f.bin b/f.bin\nindex 1111111..2222222 100644\nGIT binary patch\nliteral 4\nLcmZQzU|;|M00aO8000000\n\nliteral 0\nHcmV?d00001\n\n' > "$GITBIN"
if python3 "$NORM" < "$GITBIN" | grep -qF 'index 1111111..2222222 100644'; then
    ok "amendment (d): a GIT binary patch entry keeps its index line (no hunk line)"
else bad "amendment (d): a GIT binary patch entry dropped its index line"; fi

# ── (e) binary + MODE change (index carries NO mode token) ──
BMODE="$T/am-bin-mode.diff"; printf 'diff --git a/f.bin b/f.bin\nold mode 100644\nnew mode 100755\nindex da6639b..382c7b7\nBinary files a/f.bin and b/f.bin differ\n' > "$BMODE"
assert_eq "$(norm < "$BMODE")" "$(printf 'diff --git a/f.bin b/f.bin\nold mode 100644\nnew mode 100755\nindex da6639b..382c7b7\nBinary files a/f.bin and b/f.bin differ')" \
    "amendment (e): a binary entry with a mode change keeps its (mode-less) index line"

# ── (f) HUNK-LESS non-binary entry: the predicate is hunk PRESENCE ──
EADD="$T/am-empty-add.diff"; printf 'diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29\n' > "$EADD"
EDEL="$T/am-empty-del.diff"; printf 'diff --git a/empty b/empty\ndeleted file mode 100644\nindex e69de29..0000000\n' > "$EDEL"
assert_eq "$(norm < "$EADD")" "$(printf 'diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29')" \
    "amendment (f): a hunk-less empty-file ADD keeps its index line (no binary marker is required)"
assert_eq "$(norm < "$EDEL")" "$(printf 'diff --git a/empty b/empty\ndeleted file mode 100644\nindex e69de29..0000000')" \
    "amendment (f): a hunk-less empty-file DELETE keeps its index line"

# ── (g) mode-only text entry (no index line, no hunk) → unaffected ──
GONLY="$T/am-mode-only.diff"; printf 'diff --git a/f b/f\nold mode 100644\nnew mode 100755\n' > "$GONLY"
assert_eq "$(norm < "$GONLY")" "$(printf 'diff --git a/f b/f\nold mode 100644\nnew mode 100755')" \
    "amendment (g): a mode-only text entry is unaffected"

# ── (h) symlink 120000 → an ordinary text hunk, unaffected ──
SYM="$T/am-symlink.diff"; printf 'diff --git a/l b/l\nindex 1111111..2222222 120000\n--- a/l\n+++ b/l\n@@ -1 +1 @@\n-oldlink\n\\ No newline at end of file\n+newlink\n\\ No newline at end of file\n' > "$SYM"
assert_eq "$(norm < "$SYM")" "$(printf 'diff --git a/l b/l\n--- a/l\n+++ b/l\n@@ -0,1 +0,1 @@\n-oldlink\n\\ No newline at end of file\n+newlink\n\\ No newline at end of file')" \
    "amendment (h): a symlink (120000) is an ordinary text hunk — index dropped, @@ normalized"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
