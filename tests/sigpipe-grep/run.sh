#!/bin/bash
# tests/sigpipe-grep/run.sh — #841 SIGPIPE false-negative regression suite.
#
# The bug: under `set -o pipefail`, `printf … | grep -q PAT` takes the ELSE branch when
# the pattern IS present, because `grep -q` exits at its first match and the still-writing
# producer takes SIGPIPE (141) — and `pipefail` promotes that to the pipeline's status.
# A fail-closed gate then reports "no evidence" for evidence that is right there.
#
# What this suite pins:
#   0. the guard is CLEAN on the real repo (0 UNDECLARED occurrences), and every declared
#      exception is ANNOUNCED on every run — an exception must never become a silent mute
#   1. the guard DETECTS the idiom (single-line)          — mutation, not just "it runs"
#   2. the guard DETECTS the idiom split over a `\` continuation
#   3. the guard DETECTS the `echo … | grep -q` form (same class: echo is also a builtin)
#   4. the guard does NOT false-positive on the here-string fix, on `case`, or on a
#      `| grep` consumer WITHOUT -q (which reads all input and cannot SIGPIPE)
#   5. NON-VACUITY (the regression pin): on a >pipe-buffer MULTI-LINE payload with the
#      match on an early line, the old idiom returns NON-ZERO while the here-string
#      returns 0 — and the two MUST differ. Without this the suite could pass while the
#      bug is fully present.
#   6. size dependence: below the pipe buffer both forms agree — this is why a
#      short-payload test cannot catch the class, and why the bug looked flaky.
#   7. the guard's own CLI contract (missing root / unknown arg → exit 2, --help → 0)
#   8. exception semantics: a STALE declaration, a count DRIFT, and a declaration with no
#      tracking issue each FAIL; an exact one passes and is announced. Load-bearing here:
#      #841's own exception is `scripts/record-review.sh`, blocked by #860.
#   9. SELF-SCAN — the guard includes ITSELF in the scan set. An earlier revision excluded its
#      own path, and review round 1 found a genuine occurrence of this class hiding in that
#      blind spot. This test appends the idiom to a COPY of the guard and requires detection,
#      so re-introducing a self-exclusion fails the suite.
#  10. detection EDGES, each one a defect found in review round 2: combined flags (`-Fqx`) and
#      `--quiet`; comment lines are NOT flagged; a pipeline broken after a bare trailing `|`;
#      a SYMLINKED scan dir is still descended (`find -L`); extensionless `.husky/` hooks are
#      scanned; and the exception CONTENT-HASH defeats a count-preserving swap.
#
# Hermetic: every fixture is written under a temp root; nothing outside it is touched.
# tests/ is deliberately NOT in the guard's scan dirs (this file must contain the idiom
# in order to prove it is detected — see SCAN_DIRS in the guard).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/check-no-sigpipe-grep.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sigpipe-grep.XXXXXX")"
OUT="$TMP/out"
checks=0
failures=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }
note() { echo "   ·  $1"; }

[ -f "$GUARD" ] || { echo "❌ missing $GUARD"; exit 1; }

# guard_rc <root> → prints the guard's exit code
guard_rc() { bash "$GUARD" --root "$1" >"$OUT" 2>&1; echo $?; }

# fixture <dir> <name> <line...> — write a shell file under <dir>/scripts/
fixture() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$@" > "$dir/scripts/$name"
}

echo "== SIGPIPE false-negative regression suite (#841) =="
echo ""

# ── 0 ────────────────────────────────────────────────────────────────────────
echo "0. the guard is clean on the real repo, and declared exceptions are loud"
rc="$(guard_rc "$ROOT")"
if [ "$rc" -eq 0 ]; then
  pass "0 UNDECLARED occurrences of the idiom in scripts/, .husky/, pi-bootstrap/"
else
  fail "the guard found an undeclared occurrence (exit $rc) — see below"
  sed -n '1,20p' "$OUT"
fi
if [ -s "$ROOT/scripts/sigpipe-grep-exceptions.txt" ]; then
  if grep -q 'DECLARED BLOCKED' "$OUT"; then
    pass "the declared blocked exception is ANNOUNCED on every run (never a silent mute)"
  else
    fail "scripts/sigpipe-grep-exceptions.txt exists but the guard did not announce it"
  fi
fi

# ── 1 ────────────────────────────────────────────────────────────────────────
echo ""
echo "1. detection — the classic single-line form"
D="$TMP/f1"; fixture "$D" gate.sh 'if printf '"'"'%s'"'"' "$BODY" | grep -q '"'"'<!-- issue-scoping:'"'"'; then' '  echo scoped' 'fi'
rc="$(guard_rc "$D")"
if [ "$rc" -eq 1 ] && grep -q 'scripts/gate.sh:3' "$OUT"; then
  pass "detected (exit 1) and named the exact file:line (scripts/gate.sh:3)"
else
  fail "expected exit 1 naming scripts/gate.sh:3; got exit $rc:"
  sed -n '1,10p' "$OUT"
fi

# ── 2 ────────────────────────────────────────────────────────────────────────
echo ""
echo "2. detection — split across a \\ continuation line"
D="$TMP/f2"; fixture "$D" split.sh 'if ! printf '"'"'%s'"'"' "$SINCE" \' '    | grep -qE '"'"'^[0-9]{4}$'"'"'; then' '  echo no' 'fi'
rc="$(guard_rc "$D")"
if [ "$rc" -eq 1 ]; then
  pass "detected a pipeline split over a continuation (the pre-#841 shape in watch-truncation.sh)"
else
  fail "expected exit 1 for a continuation-split pipeline; got $rc"
  sed -n '1,10p' "$OUT"
fi

# ── 3 ────────────────────────────────────────────────────────────────────────
echo ""
echo "3. detection — the echo form (same class: echo is a builtin writer too)"
D="$TMP/f3"; fixture "$D" echoer.sh 'echo "$OUTPUT" | grep -q '"'"'REDIS'"'"' && echo found'
rc="$(guard_rc "$D")"
if [ "$rc" -eq 1 ]; then
  pass "detected echo … | grep -q (found 5 such sites in the repo that a printf-only audit missed)"
else
  fail "expected exit 1 for the echo form; got $rc"
fi

# ── 4 ────────────────────────────────────────────────────────────────────────
echo ""
echo "4. no false positive on the fixed / safe forms"
D="$TMP/f4"; fixture "$D" ok.sh \
  'if grep -q '"'"'<!-- issue-scoping:'"'"' <<<"$BODY"; then echo scoped; fi' \
  'case "$X" in *pat*) echo yes ;; esac' \
  'printf '"'"'%s'"'"' "$BODY" | grep '"'"'needle'"'"' >/dev/null'
rc="$(guard_rc "$D")"
if [ "$rc" -eq 0 ]; then
  pass 'here-string, case form, and a "| grep" consumer without -q all pass (exit 0)'
else
  fail "false positive on a safe form (exit $rc):"
  sed -n '1,10p' "$OUT"
fi

# ── 5 ────────────────────────────────────────────────────────────────────────
echo ""
echo "5. NON-VACUITY — the old idiom really does lose the match (this is the regression pin)"
# >pipe-buffer payload, MANY SHORT LINES, match on an early line. A single long line would
# NOT trigger it (grep matches line-by-line and must read the whole line first) — which is
# exactly why the payload shape matters.
BIG="$( { printf 'MARKER <!-- issue-scoping:\n'; i=0; while [ "$i" -lt 40000 ]; do printf 'padding line %d of a PR body\n' "$i"; i=$((i + 1)); done; } )"
note "payload: ${#BIG} bytes, multi-line, match on line 1"

old_idiom() { ( set -o pipefail; printf '%s' "$1" | grep -q 'issue-scoping:' ) 2>/dev/null; }
new_idiom() { ( set -o pipefail; grep -q 'issue-scoping:' <<<"$1" ) 2>/dev/null; }

old_idiom "$BIG"; old_rc=$?
new_idiom "$BIG"; new_rc=$?
note "old idiom rc=$old_rc   here-string rc=$new_rc"

if [ "$new_rc" -eq 0 ]; then
  pass "the here-string form finds the match in a ${#BIG}-byte payload (the fix is correct)"
else
  fail "the here-string form MISSED the match (rc=$new_rc) — the fix is broken"
fi
if [ "$old_rc" -ne 0 ]; then
  pass "the old idiom returns non-zero while the pattern IS present (false negative reproduced)"
else
  fail "could not reproduce the false negative — the pin would be VACUOUS, fix the payload shape"
fi
if [ "$old_rc" -ne "$new_rc" ]; then
  pass "the two forms DIFFER (rc $old_rc vs $new_rc) — this suite fails if the idiom returns"
else
  fail "the two forms agree (rc $old_rc) — the suite cannot detect the regression"
fi

# ── 6 ────────────────────────────────────────────────────────────────────────
echo ""
echo "6. size dependence — below the pipe buffer both forms agree (why short tests are vacuous)"
SMALL="$( { printf 'MARKER <!-- issue-scoping:\n'; printf 'one short body\n'; } )"
old_idiom "$SMALL"; s_old=$?
new_idiom "$SMALL"; s_new=$?
if [ "$s_old" -eq 0 ] && [ "$s_new" -eq 0 ]; then
  pass "a ${#SMALL}-byte payload passes BOTH forms (rc 0/0) — a small-payload test proves nothing"
else
  fail "expected both forms to pass on a small payload; got old=$s_old new=$s_new"
fi

# ── 7 ────────────────────────────────────────────────────────────────────────
echo ""
echo "7. the guard's own CLI contract"
bash "$GUARD" --root "$TMP/definitely-missing" >"$OUT" 2>&1
[ $? -eq 2 ] && pass "--root on a missing directory → exit 2 (not a silent pass)" \
              || fail "expected exit 2 for a missing root"
bash "$GUARD" --bogus >"$OUT" 2>&1
[ $? -eq 2 ] && pass "unknown argument → exit 2 (a typo never degrades to 'clean')" \
              || fail "expected exit 2 for an unknown argument"
bash "$GUARD" --help >"$OUT" 2>&1
[ $? -eq 0 ] && pass "--help → exit 0" || fail "expected exit 0 for --help"

# ── 8 ────────────────────────────────────────────────────────────────────────
echo ""
echo "8. exception semantics — an exception cannot rot, absorb, or be anonymous"
# 8a. STALE: a declared file with no occurrences must FAIL
E="$TMP/f8a"; fixture "$E" clean.sh 'echo nothing here'
printf 'scripts/clean.sh 2 #999\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ] && grep -q 'STALE exception' "$OUT"; then
  pass "a declaration with no occurrences FAILS (stale exceptions must be deleted)"
else
  fail "a stale declaration did not fail (exit $rc):"; sed -n '1,6p' "$OUT"
fi
# 8b. DRIFT: a new occurrence must not be inherited by an existing declaration
E="$TMP/f8b"; fixture "$E" drift.sh \
  'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi' \
  'if printf '\''%s'\'' "$B" | grep -q y; then echo 2; fi'
printf 'scripts/drift.sh 1 bogusbogusbogus1 #999\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ] && grep -q 'but the file has' "$OUT"; then
  pass "count drift FAILS — a 2nd occurrence is not covered by a 1-occurrence declaration"
else
  fail "count drift did not fail (exit $rc):"; sed -n '1,6p' "$OUT"
fi
# 8c. ANONYMOUS: a declaration with no tracking issue must FAIL
E="$TMP/f8c"; fixture "$E" anon.sh 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi'
printf 'scripts/anon.sh 1\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ] && grep -q 'tracking issue' "$OUT"; then
  pass "a declaration without a #issue FAILS (exceptions are always attributable)"
else
  fail "an anonymous declaration did not fail (exit $rc):"; sed -n '1,6p' "$OUT"
fi
# 8d. EXACT: a matching declaration passes AND is announced (positive control for 8a-8c)
E="$TMP/f8d"; fixture "$E" okdecl.sh 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi'
printf 'scripts/okdecl.sh 1 bogusbogusbogus1 #999\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
guard_rc "$E" >/dev/null
ok_hash="$(sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' "$OUT" | head -1)"
printf 'scripts/okdecl.sh 1 %s #999\n' "$ok_hash" > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 0 ] && grep -q 'DECLARED BLOCKED' "$OUT"; then
  pass "an exact declaration (count AND content-hash) passes AND is announced"
else
  fail "an exact declaration should pass loudly (exit $rc, hash '$ok_hash'):"; sed -n '1,6p' "$OUT"
fi

# ── 9 ────────────────────────────────────────────────────────────────────────
echo ""
echo "9. SELF-SCAN — the guard is inside its own scan set (no blind spot)"
E="$TMP/f9"; mkdir -p "$E/scripts"
cp "$GUARD" "$E/scripts/check-no-sigpipe-grep.sh"
rc_before="$(guard_rc "$E")"
# append the idiom to the copy — a self-excluding guard would still report clean
printf 'if printf '\''%%s'\'' "$X" | grep -q y; then echo 1; fi\n' >> "$E/scripts/check-no-sigpipe-grep.sh"
rc_after="$(guard_rc "$E")"
if [ "$rc_before" -eq 0 ] && [ "$rc_after" -eq 1 ] && grep -q 'check-no-sigpipe-grep.sh' "$OUT"; then
  pass "an occurrence inside a copy of the guard is DETECTED (clean before, exit 1 after)"
else
  fail "the guard did not detect the idiom inside itself (before=$rc_before after=$rc_after) — a self-exclusion has been reintroduced"
  sed -n '1,8p' "$OUT"
fi

echo ""
echo "10. detection edges (each one a defect found in review round 2)"

# 10a. combined flags — `-q` was pinned as the FIRST flag, so `-Fqx` was invisible
E="$TMP/f10a"; fixture "$E" comb.sh 'if ! printf '\''%s\n'\'' "$rows" | grep -Fqx "$key"; then echo no; fi'
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ]; then
  pass "combined flags detected (grep -Fqx)"
else
  fail "grep -Fqx was not detected (exit $rc) — the flag list is being pinned again"
fi

# 10b. --quiet
E="$TMP/f10b"; fixture "$E" quiet.sh 'if printf '\''%s'\'' "$V" | grep --quiet pat; then echo y; fi'
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ]; then
  pass "--quiet detected"
else
  fail "grep --quiet was not detected (exit $rc)"
fi

# 10c. comment lines are NOT flagged (a script that merely documents the anti-pattern)
E="$TMP/f10c"; fixture "$E" doc.sh '# never write printf '\''%s'\'' "$V" | grep -q pat  (documentation only)' 'echo ok'
rc="$(guard_rc "$E")"
if [ "$rc" -eq 0 ]; then
  pass "a COMMENT documenting the anti-pattern does not fail the build"
else
  fail "a comment-only mention was flagged as an occurrence (exit $rc)"
fi

# 10d. pipeline broken after a bare trailing `|` (a legal bash line break)
E="$TMP/f10d"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf '\''%s'\'' "$V" |' '  grep -q pat' > "$E/scripts/pipebreak.sh"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ]; then
  pass "a pipeline broken after a trailing | is detected"
else
  fail "a trailing-| line break was missed (exit $rc)"
fi

# 10e. a SYMLINKED scan dir must still be descended (consumer repos symlink scripts/)
E="$TMP/f10e"; mkdir -p "$E/real/scripts" "$E/consumer"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/real/scripts/a.sh"
ln -s ../real/scripts "$E/consumer/scripts"
rc_real="$(guard_rc "$E/real")"; rc_link="$(guard_rc "$E/consumer")"
if [ "$rc_real" -eq 1 ] && [ "$rc_link" -eq 1 ]; then
  pass "a symlinked scripts/ is descended (control $rc_real, symlink $rc_link)"
else
  fail "the symlinked scan dir returned $rc_link (control $rc_real) — 'clean after scanning nothing'"
fi

# 10f. extensionless .husky/ hooks are scanned
E="$TMP/f10f"; mkdir -p "$E/.husky"
printf '%s\n' '#!/usr/bin/env sh' 'printf '\''%s'\'' "$BODY" | grep -q pat' > "$E/.husky/pre-commit"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ]; then
  pass ".husky/ hooks are scanned despite having no .sh extension"
else
  fail "an extensionless .husky hook was not scanned (exit $rc)"
fi

# 10g. the exception CONTENT-HASH defeats a count-preserving swap
E="$TMP/f10g"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi' > "$E/scripts/swap.sh"
printf 'scripts/swap.sh 1 deadbeefdeadbeef #999\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
real_hash="$(sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' "$OUT" | head -1)"
if [ "$rc" -eq 1 ] && [ -n "$real_hash" ]; then
  pass "a WRONG content-hash fails even when the count matches"
else
  fail "a wrong content-hash was accepted (exit $rc, hash '$real_hash')"
fi
printf 'scripts/swap.sh 1 %s #999\n' "$real_hash" > "$E/scripts/sigpipe-grep-exceptions.txt"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 0 ]; then
  pass "the guard's own reported hash round-trips (positive control)"
else
  fail "the extracted hash did not round-trip (exit $rc)"
fi
# swap the CONTENT, keeping the count at 1
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo "$B" | grep -q totally-different' > "$E/scripts/swap.sh"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 1 ] && grep -q 'CONTENT changed' "$OUT"; then
  pass "a count-preserving swap FAILS — an exception cannot be inherited"
else
  fail "a count-preserving swap was accepted (exit $rc)"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All SIGPIPE false-negative tests passed (${checks} assertions)"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
