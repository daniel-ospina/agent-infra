#!/usr/bin/env bash
# venv-real-cost.test.sh — self-check for scripts/venv-real-cost.py (#2159).
#
# Run: bash scripts/venv-real-cost.test.sh
#
# ⛔ WHAT THIS PROVES, and why a plain "it printed something" test would not: the only thing this tool
# can do wrong that matters is CONFUSE THE TWO CLASSES. `du` prices a hardlinked env and a private copy
# of the same package set at the same number (5.66 GB on the measured cell), so a tool that cannot tell
# them apart cannot tell an operator that reaping one frees 99 MB and the other 5.66 GB. Every assertion
# below is therefore a DISCRIMINATION (hardlinked vs private, shared-block-by-link vs not), plus the two
# fail-closed rules: a symlink is never followed, and an unreadable path is UNKNOWN (exit 3) rather than
# a comfortable zero.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/venv-real-cost.py"
PY="${PYTHON_BIN:-$(command -v python3 || true)}"

FAIL=0
ok() { echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vrc.XXXXXX")" || { echo "no tmpdir"; exit 1; }
trap 'rm -rf "$T"' EXIT

echo "── 1. a PRIVATE file costs its full blocks (nlink == 1) ─────────────────────────────────"
mkdir -p "$T/priv/sub"
# 1 MiB of real data: st_blocks reflects allocation, so the file must be written, not sparse.
dd if=/dev/zero of="$T/priv/blob.bin" bs=1024 count=1024 status=none
# A SUBDIRECTORY WITH DATA — the fixture that catches the P1 (#2159 review): a directory's st_nlink
# counts its SUBDIRECTORIES (>= 2), so a walk that lets one fall through reports it as a "shared
# file" and a fully-private tree reads as "sharing is in force".
dd if=/dev/zero of="$T/priv/sub/blob2.bin" bs=1024 count=1024 status=none
out="$("$PY" "$TOOL" --tsv "$T/priv")"
priv="$(printf '%s' "$out" | cut -f1)"
total="$(printf '%s' "$out" | cut -f3)"
dedupe="$(printf '%s' "$out" | cut -f4)"
# ⛔ AN UPPER BOUND AS WELL AS A LOWER ONE (review, P2): `-ge 1000` alone survives a 2x units error
# (st_blocks is already in 512-byte units; multiplying by 1024 doubles every figure and 2048 >= 1000).
[ "$priv" -ge 2000 ] && [ "$priv" -le 2200 ] && ok "two private 1 MiB files are counted as ~2 MiB (${priv} KB)" \
    || bad "private bytes not ~2048 KB (a units error reads 1024 or 4096 here): $priv"
# DIRECTORIES cost blocks and `du` counts them, so they are in `total` but never `private`
# (they are not files, and their st_nlink counts subdirectories — the P1). With nothing shared,
# private is therefore total MINUS the directory blocks: it must sit just under total.
[ "$priv" -lt "$total" ] && [ "$((total - priv))" -le 16 ] && ok "private excludes only the directory blocks ($((total-priv)) KB below total)" \
    || bad "private/total relationship wrong: private=$priv total=$total"
assert_eq "$dedupe" "small" "a tiny tree is 'small', not a verdict about the box's link regime"
# The walk must agree with `du -sk` on the same tree: that pins the block UNIT independently of any
# absolute figure written down in this file.
du_kb="$(du -sk "$T/priv" | cut -f1)"
[ "$((total - du_kb))" -ge -8 ] && [ "$((total - du_kb))" -le 8 ] && ok "total agrees with du -sk (${total} vs ${du_kb} KB)" \
    || bad "total disagrees with du -sk: $total vs $du_kb"
json="$("$PY" "$TOOL" --json "$T/priv")"
case "$json" in
    *'"shared_files": 0'*) ok "a private tree reports ZERO shared files even though it has a SUBDIRECTORY" ;;
    *'"shared_files": '[1-9]*) bad "a directory was counted as a shared file: $json" ;;
    *) bad "shared_files missing from --json: $json" ;;
esac
case "$json" in
    *'"files": 2'*) ok "the file count counts FILES, not directories" ;;
    *) bad "file count wrong (directories counted?): $json" ;;
esac

echo "── 1b. fair_kb still reports the share for PRIVATE files (not 0) ───────────────────────"
# `fair_kb` is "this tree's share of everything it touches"; a private tree touches 100% of its own
# bytes. Reporting 0 for exactly the class this tool exists to name was a real regression.
out="$("$PY" "$TOOL" --tsv "$T/priv")"
fair="$(printf '%s' "$out" | cut -f2)"
[ "$fair" -ge 2000 ] && ok "a private tree's fair share is its own bytes (${fair} KB)" \
    || bad "fair_kb collapsed to $fair for a private tree"

echo "── 2. a HARDLINKED pair is counted ONCE, not twice ──────────────────────────────────────"
mkdir -p "$T/s1" "$T/s2"
dd if=/dev/zero of="$T/s1/blob.bin" bs=1024 count=1024 status=none
ln "$T/s1/blob.bin" "$T/s2/blob.bin" 2>/dev/null || { echo "  (hardlinks unsupported here — SKIP)"; }
if [ "$(stat -c %h "$T/s1/blob.bin" 2>/dev/null || stat -f %l "$T/s1/blob.bin")" = "2" ]; then
    out="$("$PY" "$TOOL" --tsv "$T/s1")"
    priv="$(printf '%s' "$out" | cut -f1)"; fair="$(printf '%s' "$out" | cut -f2)"; total="$(printf '%s' "$out" | cut -f3)"
    [ "$priv" -eq 0 ] && ok "a twice-linked file contributes ZERO private bytes" || bad "hardlinked file read as private: $priv"
    # fair share is half: this is what deleting one of the two trees frees while the other lives.
    [ "$fair" -gt 400 ] && [ "$fair" -lt 600 ] && ok "the fair share is half the file (${fair} KB)" || bad "fair share not halved: $fair"
    [ "$total" -ge 1000 ] && ok "total still reports the full blocks (the \`du\` figure)" || bad "total lost the blocks: $total"
else
    ok "hardlinks unavailable on this filesystem — discrimination not exercised"
fi

echo "── 3. the DEGRADED class is named, and it is not the small-tree case ───────────────────"
mkdir -p "$T/big"
# 60 MiB private: above DEGRADED_MIN_TOTAL_KB, all nlink==1.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    dd if=/dev/zero of="$T/big/blob$i.bin" bs=1024 count=5120 status=none
done
out="$("$PY" "$TOOL" --tsv "$T/big")"
dedupe="$(printf '%s' "$out" | cut -f4)"
assert_eq "$dedupe" "degraded" "an env with no sharing at all is reported DEGRADED (the class that costs the full du figure)"

echo "── 4. a SYMLINK is never followed (a walk must not leave the tree) ─────────────────────"
mkdir -p "$T/outside" "$T/inside"
dd if=/dev/zero of="$T/outside/huge.bin" bs=1024 count=4096 status=none
ln -s "$T/outside" "$T/inside/link"
out="$("$PY" "$TOOL" --tsv "$T/inside")"
total="$(printf '%s' "$out" | cut -f3)"
[ "$total" -lt 100 ] && ok "a symlinked directory contributes nothing (${total} KB) — the walk stayed inside" \
    || bad "the walk followed a symlink: $total KB"

echo "── 5. an unreadable path is UNKNOWN (exit 3), never a comfortable zero ─────────────────"
"$PY" "$TOOL" --tsv "$T/does-not-exist" >/dev/null 2>&1
assert_eq "$?" "3" "an unmeasurable path exits 3, so a caller cannot read it as 'free'"

echo "── 5b. a TRUNCATED walk is not a measurement (exit 3, never 0) ───────────────────────────"
mkdir -p "$T/trunc/ok" "$T/trunc/hidden"
dd if=/dev/zero of="$T/trunc/ok/blob.bin" bs=1024 count=512 status=none
dd if=/dev/zero of="$T/trunc/hidden/big.bin" bs=1024 count=4096 status=none
if chmod 000 "$T/trunc/hidden" 2>/dev/null && [ ! -r "$T/trunc/hidden" ]; then
    trunc_out="$("$PY" "$TOOL" --tsv "$T/trunc" 2>/dev/null)"; trunc_rc=$?
    assert_eq "$trunc_rc" "3" "an unreadable subdirectory makes the reading PARTIAL (exit 3), not a quiet under-count"
    # The exit code alone is not enough: an implementation that exits 3 while still emitting
    # `dedupe=ok` would pass the line above (#2159 review, P2).
    assert_eq "$(printf '%s' "$trunc_out" | cut -f4)" "partial" "and the verdict says 'partial', not 'ok'"
    chmod 755 "$T/trunc/hidden"
else
    ok "cannot make a directory unreadable here (running as root?) — truncation case not exercised"
fi

echo "── 6. --json emits the same numbers (the machine-readable arm agrees with the tsv arm) ──"
json="$("$PY" "$TOOL" --json "$T/big")"
case "$json" in
    *'"dedupe": "degraded"'*) ok "--json carries the dedupe verdict" ;;
    *) bad "--json missing the dedupe verdict: $json" ;;
esac

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES: $FAIL"; exit 1
