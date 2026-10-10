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
#      tracking issue each FAIL; an exact one passes and is announced. The announcement
#      property is pinned POSITIVELY by the synthetic fixture in 8d. The one real exception
#      this repo ever carried (`scripts/record-review.sh`, blocked by #860) was deleted when
#      #860 was resolved by funding — see the exceptions file. Section 0 therefore pins the
#      shipped state too: zero live exception lines and no phantom exemption.
#   9. SELF-SCAN — the guard includes ITSELF in the scan set. An earlier revision excluded its
#      own path, and review round 1 found a genuine occurrence of this class hiding in that
#      blind spot. This test appends the idiom to a COPY of the guard and requires detection,
#      so re-introducing a self-exclusion fails the suite.
#  10. detection EDGES, each one a defect found in review round 2: combined flags (`-Fqx`) and
#      `--quiet`; comment lines are NOT flagged; a pipeline broken after a bare trailing `|`;
#      a SYMLINKED scan dir is still descended (`find -L`); extensionless `.husky/` hooks are
#      scanned; and the exception CONTENT-HASH defeats a count-preserving swap.
#  11. the CONSUMER-REPO knobs (tortoise#7588). This guard is shared by SYMLINK, so in a
#      consumer repo `scripts/` points back here: the default scan set reads the wrong tree
#      and the shared exceptions path is one the consumer cannot write. `--dirs` /
#      SIGPIPE_SCAN_DIRS set the scan set, a ROOT `.sigpipe-grep-exceptions.txt` is honoured
#      and announced, and selection is by NAME **OR SHEBANG** — an extensionless
#      `.github/scripts/` entry (the shape two of the four shipped sites had) is scanned,
#      while an extensionless non-shell file still is not. Round 2 of review added: the
#      BASENAME rule (a dotted DIRECTORY must not hide an extensionless script), `--dirs ''`
#      and a whitespace-only set must be usage errors, a typo'd dir in an EXPLICIT set must
#      fail while the DEFAULT set still tolerates an absent dir, the root file's precedence
#      over the shared one, a non-shell interpreter not being claimed, and the file count in
#      the clean message that makes "scanned nothing" visible.
#  11aa. a SYMLINK CYCLE is not a partial scan. `find -L` is required so a consumer's symlinked
#      `scripts/` is descended, so it can also meet a cycle — and everything a cycle reaches
#      is reachable without it, so the file is still read. Only findutils' own cycle report is
#      exempt: the ELOOP wording means a path did not resolve at all (a chain, reachable no
#      other way) and stays fatal (11af); a tree holding BOTH a cycle and an unreadable dir is
#      still exit 2 (11ab). The cycle pin has teeth on GNU find (CI); BSD find emits no cycle
#      diagnostic, so there it passes with or without the exclusion; 11ai therefore stubs `find`
#      to pin BOTH the exemption and the ANCHOR of its match on every platform. 11af runs only
#      where find reports an unresolvable chain, so the suite's assertion count is
#      platform-dependent (67 on BSD/macOS, 69 on GNU findutils — the platform CI runs).
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
# The shipped repo carries no LIVE exception lines (comments only). A declared
# exception must always be announced — that property is proven positively on a
# synthetic fixture in section 8d. Here we pin that the shipped file declares
# nothing, so the guard must not print a phantom exemption.
live_exc="$(grep -vcE '^[[:space:]]*(#|$)' "$ROOT/scripts/sigpipe-grep-exceptions.txt" 2>/dev/null || true)"
live_exc="${live_exc:-0}"
if [ "$live_exc" -eq 0 ]; then
  if grep -q 'DECLARED BLOCKED' "$OUT"; then
    fail "the guard announced a DECLARED BLOCKED exception but the shipped exceptions file has no live lines"
  else
    pass "no live exception lines shipped — the scan set is clean with no exemption claimed"
  fi
elif grep -q 'DECLARED BLOCKED' "$OUT"; then
  pass "$live_exc declared exception(s) ANNOUNCED on every run (never a silent mute)"
else
  fail "$live_exc live exception line(s) present but the guard did not announce them"
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
echo "11. consumer-repo knobs — settable scan set, ROOT exceptions file, shebang selection"
echo ""

# 11a. --dirs selects the consumer's own layout. The control is the SAME fixture with the
# default set, so the idiom being found only when the dir is named is what is pinned.
E="$TMP/f11a"; mkdir -p "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if printf '\''%s'\'' "$R" | grep -q refs/heads/main; then echo y; fi' > "$E/.github/scripts/deploy"
rc_default="$(guard_rc "$E")"
rc_dirs="$(bash "$GUARD" --root "$E" --dirs '.github/scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc_default" -eq 0 ] && [ "$rc_dirs" -eq 1 ]; then
  pass "--dirs selects the consumer layout (default $rc_default, --dirs $rc_dirs)"
else
  fail "--dirs did not change the scan set (default $rc_default, --dirs $rc_dirs)"
fi

# 11b. SIGPIPE_SCAN_DIRS is the same knob for callers that cannot pass an argument
rc_env="$(SIGPIPE_SCAN_DIRS='.github/scripts' bash "$GUARD" --root "$E" >"$OUT" 2>&1; echo $?)"
if [ "$rc_env" -eq 1 ]; then
  pass "SIGPIPE_SCAN_DIRS is honoured (exit $rc_env)"
else
  fail "SIGPIPE_SCAN_DIRS was ignored (exit $rc_env)"
fi

# 11c. SELECTION BY SHEBANG. Two of the four sites that shipped this bug were extensionless
# `.github/scripts/` entries; a `-name '*.sh'` filter reads them as a clean run.
E="$TMP/f11c"; mkdir -p "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.github/scripts/check-thing"
rc="$(bash "$GUARD" --root "$E" --dirs '.github/scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc" -eq 1 ]; then
  pass "an extensionless script WITH a shebang is scanned (exit $rc)"
else
  fail "an extensionless shebang script was skipped (exit $rc) — the .github/scripts blind spot"
fi

# 11d. ...and the widening is not a blanket: an extensionless NON-shell file is still skipped
E="$TMP/f11d"; mkdir -p "$E/.github"
printf '%s\n' 'prose about printf '\''%s'\'' "$V" | grep -q pat — not shell at all' > "$E/.github/NOTES"
rc="$(bash "$GUARD" --root "$E" --dirs '.github' >"$OUT" 2>&1; echo $?)"
if [ "$rc" -eq 0 ]; then
  pass "an extensionless non-shell file is not scanned (no false positive)"
else
  fail "a non-shell extensionless file was flagged (exit $rc)"
fi

# 11e. a ROOT exceptions file is honoured AND announced. A consumer's `scripts/` is a symlink
# it cannot write through, so the shared path must not be the only place an exception can live.
E="$TMP/f11e"; mkdir -p "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi' > "$E/.github/scripts/b.sh"
rc="$(bash "$GUARD" --root "$E" --dirs '.github/scripts' >"$OUT" 2>&1; echo $?)"
# learn the fingerprint the same way 10g does: declare a WRONG hash and read the actual one
printf '.github/scripts/b.sh 1 deadbeefdeadbeef #7588\n' > "$E/.sigpipe-grep-exceptions.txt"
rc_hash="$(bash "$GUARD" --root "$E" --dirs '.github/scripts' >"$OUT" 2>&1; echo $?)"
real_hash="$(sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' "$OUT" | head -1)"
printf '.github/scripts/b.sh 1 %s #7588\n' "$real_hash" > "$E/.sigpipe-grep-exceptions.txt"
rc2="$(bash "$GUARD" --root "$E" --dirs '.github/scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc" -eq 1 ] && [ -n "$real_hash" ] && [ "$rc2" -eq 0 ] && grep -q 'DECLARED BLOCKED' "$OUT"; then
  pass "a ROOT .sigpipe-grep-exceptions.txt is honoured and announced (undeclared $rc, wrong-hash $rc_hash, declared $rc2)"
else
  fail "the root exceptions file was ignored (undeclared exit $rc, wrong-hash exit $rc_hash, declared exit $rc2, hash '$real_hash')"
fi

# 11f. `--dirs` with no value is a usage error — never a silent fall back to the default set
bash "$GUARD" --dirs >"$OUT" 2>&1
[ $? -eq 2 ] && pass "--dirs without a value → exit 2" \
             || fail "expected exit 2 for --dirs with no value"

# 11g. the BASENAME rule. `*/*.*` let a dot in a DIRECTORY component hide an extensionless
# script, so the fix's whole point was defeated for `scripts/v2.1/deploy` — a clean run on a
# file that contains the idiom. Uses the DEFAULT set, so it also pins that selection.
E="$TMP/f11g"; mkdir -p "$E/scripts/v2.1"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/v2.1/deploy"
rc="$(guard_rc "$E")"
[ "$rc" -eq 1 ] && pass "an extensionless script under a DOTTED directory is scanned" \
             || fail "a dotted directory hid an extensionless script (exit $rc) — a false clean"

# 11h. `--dirs ''` must NOT fall back to the default set. In a consumer whose `scripts/`
# symlinks back here that fallback scans the wrong tree and prints a clean run — the #7588
# failure this change exists to end.
E="$TMP/f11h"; mkdir -p "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.github/scripts/deploy"
rc="$(bash "$GUARD" --root "$E" --dirs '' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && pass "--dirs '' → exit 2 (never a silent fall back to the default set)" \
             || fail "--dirs '' fell back to the default set (exit $rc)"

# 11i. a whitespace-only set resolves to a ZERO-ELEMENT array: a usage error, not a zero-file
# scan reported as clean (and not a `set -u` crash on bash 3.2).
E="$TMP/f11i"; mkdir -p "$E/scripts"; printf 'echo hi\n' > "$E/scripts/a.sh"
rc="$(bash "$GUARD" --root "$E" --dirs '   ' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && pass "a whitespace-only scan set → exit 2" \
             || fail "a whitespace-only scan set was not rejected (exit $rc)"

# 11j. an EXPLICIT set names dirs the caller believes exist: a typo must fail, not scan nothing
E="$TMP/f11j"; mkdir -p "$E/.github/scripts"
rc="$(bash "$GUARD" --root "$E" --dirs '.github/scrips' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && pass "a misspelled dir in an explicit set → exit 2" \
             || fail "a misspelled dir was silently skipped (exit $rc)"

# 11k. the DEFAULT set still TOLERATES an absent dir — `.husky`/`pi-bootstrap` are not in
# every repo, so this must not become a hard error (it would break every existing caller).
E="$TMP/f11k"; mkdir -p "$E/scripts"; printf 'echo hi\n' > "$E/scripts/a.sh"
rc="$(guard_rc "$E")"
[ "$rc" -eq 0 ] && pass "the default set tolerates an absent dir (exit 0)" \
             || fail "the default set errored on an absent dir (exit $rc)"

# 11l. PRECEDENCE: a root file SHADOWS the shared one. A root file can only make the guard
# STRICTER (it cannot weaken a shared declaration it does not repeat), and this pins that
# exactly: a valid shared declaration works alone, and an EMPTY root file makes it unusable.
E="$TMP/f11l"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi' > "$E/scripts/b.sh"
printf 'scripts/b.sh 1 deadbeefdeadbeef #999\n' > "$E/scripts/sigpipe-grep-exceptions.txt"
guard_rc "$E" >/dev/null
real_hash="$(sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' "$OUT" | head -1)"
printf 'scripts/b.sh 1 %s #999\n' "$real_hash" > "$E/scripts/sigpipe-grep-exceptions.txt"
rc_shared="$(guard_rc "$E")"
printf '# a root file exists, declaring nothing\n' > "$E/.sigpipe-grep-exceptions.txt"
rc_shadowed="$(guard_rc "$E")"
if [ "$rc_shared" -eq 0 ] && [ "$rc_shadowed" -eq 1 ]; then
  pass "the shared declaration works alone ($rc_shared) and a root file SHADOWS it ($rc_shadowed)"
else
  fail "precedence is not root-over-shared (shared $rc_shared, shadowed $rc_shadowed)"
fi

# 11m. a NON-SHELL interpreter is not claimed. `*sh*` also matched fish/tcsh/zsh/xonsh, which
# have no pipefail and where the printed bash-only remedy is invalid advice.
E="$TMP/f11m"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env fish' 'printf x | grep -q y' > "$E/scripts/fishscript"
printf '%s\n' '#!/bin/zsh' 'printf x | grep -q y' > "$E/scripts/zshscript"
rc="$(guard_rc "$E")"
[ "$rc" -eq 0 ] && pass "fish/zsh shebangs are not claimed (no inapplicable remedy)" \
             || fail "a non-shell interpreter was claimed (exit $rc)"

# 11n. the clean message carries a FILE COUNT, so "scanned nothing" is distinguishable from
# "scanned and clean" — indistinguishable before, and why a wrong-tree run looked fine.
E="$TMP/f11n"; mkdir -p "$E/scripts"; printf '#!/usr/bin/env bash\necho hi\n' > "$E/scripts/a.sh"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 0 ] && grep -qE 'scanned [1-9][0-9]* file' "$OUT"; then
  pass "the clean message reports the number of files scanned"
else
  fail "the clean message does not report a file count (exit $rc)"
fi

# 11p. SIGPIPE_SCAN_DIRS set-but-EMPTY must be an error too. It is the same false-clean
# class as `--dirs ''`, reached through the env knob: a caller forwarding a possibly-unset
# variable would otherwise scan the DEFAULT set — here a `scripts/` symlinked to a clean
# tree, which is exactly the #7588 shape and reports ✅ on a repo that has the idiom.
E="$TMP/f11p"; mkdir -p "$E/.github/scripts" "$E/shared/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.github/scripts/deploy"
printf '%s\n' '#!/usr/bin/env bash' 'echo clean' > "$E/shared/scripts/ok.sh"
ln -s ../shared/scripts "$E/scripts"
rc_empty="$(SIGPIPE_SCAN_DIRS='' bash "$GUARD" --root "$E" >"$OUT" 2>&1; echo $?)"
rc_ws="$(SIGPIPE_SCAN_DIRS='   ' bash "$GUARD" --root "$E" >"$OUT" 2>&1; echo $?)"
if [ "$rc_empty" -eq 2 ] && [ "$rc_ws" -eq 2 ]; then
  pass "an EMPTY SIGPIPE_SCAN_DIRS is a usage error, not a fall back (empty $rc_empty, ws $rc_ws)"
else
  fail "an empty SIGPIPE_SCAN_DIRS fell back to the default set (empty $rc_empty, ws $rc_ws)"
fi

# 11q. an ABSOLUTE --dirs is honoured — a legitimate caller shape must not be a false block
E="$TMP/f11q"; mkdir -p "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.github/scripts/deploy"
rc="$(bash "$GUARD" --root "$E" --dirs "$E/.github/scripts" >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "an absolute --dirs is honoured (exit 1)" \
             || fail "an absolute --dirs was rejected or missed (exit $rc)"

# 11r. the count and the scan must select .husky IDENTICALLY (the .husky case matches on the
# basename, so a `$ROOT/`-qualified path does not silently fall to the name/shebang filter)
E="$TMP/f11r"; mkdir -p "$E/.husky" "$E/scripts"
printf '%s\n' '#!/usr/bin/env sh' 'echo hi' > "$E/.husky/pre-commit"
printf '#!/usr/bin/env bash\necho hi\n' > "$E/scripts/a.sh"
rc="$(guard_rc "$E")"
if [ "$rc" -eq 0 ] && grep -qE 'scanned 2 file' "$OUT"; then
  pass "the count includes .husky files (scanned 2)"
else
  fail "the count and the scan disagree about .husky (exit $rc)"
fi

# 11s. a TRAILING SLASH on a scan dir must not change selection: `${dir##*/}` on `.husky/`
# is empty, so `.husky/` fell to the name/shebang filter and skipped the extensionless
# hooks — a green run over zero files.
E="$TMP/f11s"; mkdir -p "$E/.husky"
printf '%s\n' 'set -euo pipefail' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.husky/pre-commit"
rc_plain="$(bash "$GUARD" --root "$E" --dirs '.husky' >"$OUT" 2>&1; echo $?)"
rc_slash="$(bash "$GUARD" --root "$E" --dirs '.husky/' >"$OUT" 2>&1; echo $?)"
if [ "$rc_plain" -eq 1 ] && [ "$rc_slash" -eq 1 ]; then
  pass "a trailing slash does not change selection ('.husky' $rc_plain, '.husky/' $rc_slash)"
else
  fail "'.husky/' scanned nothing (plain $rc_plain, slash $rc_slash) — a false clean"
fi

# 11t. a NEWLINE in the value is refused: `read -a` takes one line, so the rest would be
# silently dropped and never validated (a CI variable delivered as a YAML block).
E="$TMP/f11t"; mkdir -p "$E/scripts" "$E/.github/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/deploy"
rc="$(bash "$GUARD" --root "$E" --dirs $'.github/scripts\nscripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && pass "a newline in --dirs → exit 2 (never a silently truncated set)" \
             || fail "a multi-line scan set was silently truncated (exit $rc)"

# 11u. a scan dir whose name begins with `-` is a `find` predicate, so it failed into a
# discarded stderr and an empty list — green, nothing scanned. Newly reachable via --dirs.
E="$TMP/f11u"; mkdir -p "$E/-weird"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/-weird/a.sh"
rc="$(bash "$GUARD" --root "$E" --dirs '-weird' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "a '-'-prefixed scan dir is scanned (exit 1)" \
             || fail "a '-'-prefixed scan dir was skipped (exit $rc) — a false clean"

# 11v. the bounded shebang read must not clip the interpreter token: a long shebang line
# still names its shell (this is the case a 512-byte cap got wrong).
E="$TMP/f11v"; mkdir -p "$E/scripts"
pad="$(printf 'a%.0s' {1..501})"
printf '%s\n' "#!/${pad}/bin/bash" 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/prog"
rc="$(bash "$GUARD" --root "$E" --dirs scripts >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "a long shebang line still names its shell (exit 1)" \
             || fail "the bounded read clipped the interpreter token (exit $rc)"

# 11w. slash NORMALISATION is complete: `//` and a trailing `/.` are the same dir as `/`.
# `${dir%/}` strips one slash, so `.husky//` fell to the name/shebang filter — a green run
# over zero files, the very shape 11s closes for a single slash.
E="$TMP/f11w"; mkdir -p "$E/.husky"
printf '%s\n' 'set -euo pipefail' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.husky/pre-commit"
rc_double="$(bash "$GUARD" --root "$E" --dirs '.husky//' >"$OUT" 2>&1; echo $?)"
rc_dot="$(bash "$GUARD" --root "$E" --dirs '.husky/.' >"$OUT" 2>&1; echo $?)"
if [ "$rc_double" -eq 1 ] && [ "$rc_dot" -eq 1 ]; then
  pass "'.husky//' and '.husky/.' select like '.husky' ($rc_double, $rc_dot)"
else
  fail "slash normalisation is incomplete (double $rc_double, dot $rc_dot) — a false clean"
fi

# 11x. an existing but UNREADABLE explicit dir is a false clean: `test -e` passes, `find`
# fails into a discarded stderr, and the guard reports a clean run over zero files.
E="$TMP/f11x"; mkdir -p "$E/locked"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/locked/a.sh"
chmod 000 "$E/locked"
rc="$(bash "$GUARD" --root "$E" --dirs 'locked' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/locked"
[ "$rc" -eq 2 ] && pass "an unreadable explicit scan dir → exit 2 (never a clean run)" \
             || fail "an unreadable scan dir produced a false clean (exit $rc)"

# 11y. a readable-but-NOT-SEARCHABLE explicit dir is the same false clean: `test -r` passes
# for a 0444 dir, but `find` needs `-x` to descend, so it yielded an empty list.
E="$TMP/f11y"; mkdir -p "$E/locked"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/locked/a.sh"
chmod 444 "$E/locked"
rc="$(bash "$GUARD" --root "$E" --dirs 'locked' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/locked"
[ "$rc" -eq 2 ] && pass "a search-denied explicit scan dir → exit 2" \
             || fail "a search-denied scan dir produced a false clean (exit $rc)"

# 11z. and the same class BENEATH a readable dir: `find` prints an error and yields a PARTIAL
# list, which was reported as a clean run over files it never read.
E="$TMP/f11z"; mkdir -p "$E/nested/deep"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/nested/deep/a.sh"
chmod 000 "$E/nested/deep"
rc="$(bash "$GUARD" --root "$E" --dirs 'nested' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/nested/deep"
[ "$rc" -eq 2 ] && pass "a partial scan beneath a readable dir → exit 2, not a clean run" \
             || fail "a partial scan was reported clean (exit $rc)"

# 11aa. a symlink CYCLE is NOT a missed-file defect — everything reachable through it is
# reachable without it — so the pin is that the file is still read, not that `find` errors.
# This pin needs findutils: it depends on find's own cycle report being emitted for a self-loop
# (GNU/CI: `File system loop detected`). Two known limits, deliberate and fail-closed:
#   · BSD find prints no cycle diagnostic at all, so here the pin passes with or without the
#     exemption it holds (the guard cannot see the difference);
#   · a MUTUAL PAIR (`one -> other`, `other -> one`) is a cycle find reports as ELOOP, so it
#     exits 2 — an accepted false BLOCK, never a missed file;
# and BusyBox `find` (a bare Alpine, no findutils) reports EVERY cycle as `Symbolic link loop`,
# which stays fatal — so the guard requires findutils, as this repo's CI installs.
E="$TMP/f11aa"; mkdir -p "$E/scripts"; ln -s . "$E/scripts/loop"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "a symlink loop does not hide a file reachable through it" \
             || fail "a file was missed in a tree containing a symlink loop (exit $rc)"

# 11ab. ...and partitioning the loop diagnostic out must NOT swallow a real one: a tree that
# holds BOTH a loop and an unreadable directory is still a partial scan (exit 2). Without this
# pin the loop filter could be widened into "ignore find's stderr" and stay green.
E="$TMP/f11abloop"; mkdir -p "$E/scripts/locked"; ln -s . "$E/scripts/loop"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked/a.sh"
chmod 000 "$E/scripts/locked"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/scripts/locked"
[ "$rc" -eq 2 ] && pass "a loop does not excuse a genuine partial scan (exit 2)" \
             || fail "a partial scan was reported clean in a tree that also holds a loop (exit $rc)"

# 11ac. a named non-executable FILE is not a false block: `-x` means SEARCH for a directory
# but EXECUTABLE for a file, and requiring it made `--dirs somefile.sh` exit 2.
E="$TMP/f11ac"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/entrypoint.sh"
chmod 644 "$E/scripts/entrypoint.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts/entrypoint.sh' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "a named non-executable file is scanned, not blocked (exit 1)" \
             || fail "a named non-executable file was a false block (exit $rc)"

# 11ad. an exception declared for a file OUTSIDE this run's scan set is UNVERIFIED, not
# STALE: the guard cannot confirm a declaration it did not scan, and calling that stale
# reds every narrowed --dirs a consumer runs.
E="$TMP/f11ad"; mkdir -p "$E/scripts" "$E/other"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if printf '\''%s'\'' "$A" | grep -q x; then echo 1; fi' > "$E/other/c.sh"
printf 'other/c.sh 1 deadbeefdeadbeef #999\n' > "$E/.sigpipe-grep-exceptions.txt"
bash "$GUARD" --root "$E" --dirs 'scripts other' >"$OUT" 2>&1
h="$(sed -n 's/.*other\/c\.sh .*actual \([0-9a-f]\{16\}\).*/\1/p' "$OUT" | head -1)"
printf 'other/c.sh 1 %s #999\n' "$h" > "$E/.sigpipe-grep-exceptions.txt"
rc_full="$(bash "$GUARD" --root "$E" --dirs 'scripts other' >"$OUT" 2>&1; echo $?)"
# scanning ONLY scripts/: other/c.sh is outside the scan set and must NOT read as stale
rc_narrow="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc_full" -eq 0 ] && [ "$rc_narrow" -eq 0 ] && ! grep -q 'STALE exception' "$OUT"; then
  pass "a declaration outside the scan set is UNVERIFIED, not stale (full $rc_full, narrow $rc_narrow)"
else
  fail "a narrowed scan read an out-of-scope declaration as stale (full $rc_full, narrow $rc_narrow)"
fi

# 11ae. ...and a declaration for a file that IS scanned and clean is still stale — the check
# must not have been weakened away.
E="$TMP/f11ae"; mkdir -p "$E/scripts"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/d.sh"
printf 'scripts/d.sh 1 deadbeefdeadbeef #999\n' > "$E/.sigpipe-grep-exceptions.txt"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && grep -q 'STALE exception' "$OUT" && pass "a scanned-and-clean declared file is still STALE (exit 1)" \
             || fail "the stale check was weakened (exit $rc)"

# 11af. ELOOP IS NOT A CYCLE. The kernel raises ELOOP whenever a path fails to resolve within
# its symlink budget, which includes a NON-cyclic chain — and a chain's target is reachable no
# other way, so it is a genuine partial scan. Exempting the ELOOP wording is a false clean, and
# this pin is what fails if that exemption returns.
# The pin runs only where find reports the failure, which is SHAPE- AND PLATFORM-dependent —
# an entry whose whole resolution fails is skipped in silence by BSD find (exit 0, the deep
# links unlisted, so there is nothing for the guard to see), while GNU findutils reports it.
# The probe below queries find the way the GUARD does (from $E, on the same relative path),
# so the skip decision measures the invocation that is actually asserted about. The reason for
# any skip is printed rather than passed over in silence.
E="$TMP/f11af"; mkdir -p "$E/scripts" "$E/chain" "$E/outside"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/outside/bad.sh"
ln -s ../outside "$E/chain/l0"
i=1
while [ "$i" -le 45 ]; do ln -s "l$((i-1))" "$E/chain/l$i"; i=$((i+1)); done
ln -s ../chain/l45 "$E/scripts/entry"
chain_errs="$(cd "$E" && find -L scripts -type f 2>&1 >/dev/null)"
if [ -z "$chain_errs" ]; then
  echo "   ⏭️  a chain that cannot resolve: this platform's find reports no failure for this shape (BSD) — pin skipped; it runs wherever find reports the failure (GNU findutils, CI)"
else
  rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
  [ "$rc" -eq 2 ] && pass "a symlink chain that cannot resolve is a partial scan (exit 2)" \
               || fail "an unresolved symlink chain was reported clean (exit $rc)"
fi

# 11ag. the diagnostics sink is a fail-closed precondition. If it cannot be created OR cannot be
# written, find's stderr goes nowhere, the partition sees an empty file, and a partial scan reads
# as a clean one. The guard must refuse rather than report a verdict. `mktemp` is stubbed rather
# than pointed at a bad TMPDIR, because BSD `mktemp` ignores TMPDIR — a stub is the only form
# that asserts this on both platforms. Both failure shapes are pinned: a `mktemp` that FAILS
# while naming a usable path (so ONLY the status check can refuse), and one that claims success
# while producing an unusable sink.
E="$TMP/f11ag"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' "printf '%s' '$E/sink'" 'exit 1' > "$E/fakebin/mktemp"
chmod +x "$E/fakebin/mktemp"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a diagnostics sink that cannot be created refuses a verdict (exit 2)" \
             || fail "a failed mktemp still produced a verdict (exit $rc)"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$E/fakebin/mktemp"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a diagnostics sink that cannot be written refuses a verdict (exit 2)" \
             || fail "an unusable diagnostics sink still produced a verdict (exit $rc)"

# 11ah. OPENABILITY IS NOT WRITABILITY. A sink that takes the open and then refuses the write —
# a full volume — swallows find's diagnostics exactly as a missing file does, so the partition
# reads empty over a partial scan. `/dev/full` is that state on tap. The sink goes through a
# SYMLINK so the guard's exit trap — an unconditional `rm -f "$FIND_ERRS"` — can only ever
# remove the link, never the device. Where /dev/full does not exist (BSD/macOS) the pin says so
# rather than passing vacuously.
E="$TMP/f11ah"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
sink_state="unavailable"
if [ -e /dev/full ] && { : >>/dev/full; } 2>/dev/null; then
  if { printf x >>/dev/full; } 2>/dev/null; then sink_state="writable"; else sink_state="full"; fi
fi
if [ "$sink_state" != full ]; then
  echo "   ⏭️  a sink that opens but rejects the write: /dev/full is $sink_state here — pin skipped; it runs where /dev/full is an always-full device (Linux/CI)"
else
  ln -s /dev/full "$E/sink"
  printf '%s\n' '#!/bin/sh' "printf '%s' '$E/sink'" 'exit 0' > "$E/fakebin/mktemp"
  chmod +x "$E/fakebin/mktemp"
  rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
  [ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a sink that opens but rejects the write refuses a verdict (exit 2)" \
               || fail "a write-rejecting sink still produced a verdict (exit $rc)"
fi

# 11ai. ...and the cycle EXEMPTION and its ANCHOR are pinned on every platform. 11aa needs
# findutils' own cycle report, which BSD find never emits — so on macOS it passes with or
# without the exemption, and an edit that deletes the exempt arm or loosens its match would be
# caught only on CI. `find` is stubbed (as 11ag stubs `mktemp`) so both polarities are asserted
# here. (b) is what pins the ANCHOR: an unanchored `*'File system loop detected'*` matches a
# permission error whose PATH merely contains that text — a path the tree under scan controls —
# and so exempts a real partial scan. That is a reachable fail-open, not a theoretical one.
E="$TMP/f11ai"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
# (a) a GNU-shaped cycle report, with everything reachable still listed
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "find: File system loop detected; ‘scripts/loop’ is part of the same file system loop as ‘scripts’." >&2' \
  'printf "%s\n" "scripts/a.sh"' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "find's cycle report is EXEMPT: the file it did not hide is still read (exit 1)" \
             || fail "the cycle exemption is not what makes the loop case clean (exit $rc)"
# (b) a permission error whose path merely CONTAINS the cycle text must NOT be exempt
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "find: scripts/File system loop detected/x: Permission denied" >&2' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "the cycle match is ANCHORED: an error whose path contains the text is still fatal (exit 2)" \
             || fail "an unanchored cycle match exempted a real partial scan (exit $rc)"

# 11aj. A file the scan LISTED but cannot OPEN is not "clean". `find -L` STAT'd it, so no
# diagnostic reaches the partition, and `awk` fails on it with a status nothing checks — the run
# would print a verdict over a file it never read. Pinned with a mode-000 `*.sh`, which is
# claimed by NAME, so no shebang read is involved and the pin isolates this path.
E="$TMP/f11aj"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked.sh"
chmod 000 "$E/scripts/locked.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 644 "$E/scripts/locked.sh"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "an unreadable LISTED file refuses a verdict (exit 2)" \
             || fail "the idiom in an unreadable file was reported clean (exit $rc)"

# 11ak. ...and the sink must be ABSOLUTE. The precondition and the partition read run in the
# guard's OWN cwd, but `find` writes to it after `cd "$ROOT"` — so a RELATIVE mktemp result names
# two different files: find's errors land in $ROOT/<name>, the partition reads $PWD/<name> empty,
# and a partial scan reads as a clean one. GNU `mktemp` emits exactly that shape when TMPDIR is
# relative, so `mktemp` is stubbed to emit it without depending on the platform's mktemp. The
# cwd MUST differ from --root, or the two resolutions coincide and the pin is vacuous.
E="$TMP/f11ak"; mkdir -p "$E/scripts/locked" "$E/fakebin" "$E/run"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked/a.sh"
chmod 000 "$E/scripts/locked"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "rel-sink.$$"' ': >"rel-sink.$$"' > "$E/fakebin/mktemp"
chmod +x "$E/fakebin/mktemp"
rc="$(cd "$E/run" && PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/scripts/locked"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a RELATIVE diagnostics sink still refuses a verdict (exit 2)" \
             || fail "a relative sink made the partition read empty over a partial scan (exit $rc)"

# 11al. ...and a sink that ACCEPTS the write and discards it is not usable either. Reading the
# byte back is the only form that catches it: the write succeeds, so a write-only precondition
# passes while the partition reads empty over a partial scan. `/dev/null` exists on both
# platforms, so this pin is never skipped.
E="$TMP/f11al"; mkdir -p "$E/scripts/locked" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked/a.sh"
chmod 000 "$E/scripts/locked"
# Reached through a SYMLINK, as 11ah does, so the guard's exit trap (`rm -f "$FIND_ERRS"`) can
# only ever remove the link, never the device.
ln -s /dev/null "$E/sink"
printf '%s\n' '#!/bin/sh' "printf '%s' '$E/sink'" > "$E/fakebin/mktemp"
chmod +x "$E/fakebin/mktemp"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 755 "$E/scripts/locked"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a write-DISCARDING sink refuses a verdict (exit 2)" \
             || fail "a sink that swallows find's stderr produced a verdict anyway (exit $rc)"

# 11am. ...and the unreadable-file probe must not OVER-block. A basename carrying an extension
# (`notes.txt`) is excluded by the NAME rule alone with no read, so the guard would never have
# opened it and making it fatal is a real false BLOCK on a tree the guard can clear. The other
# half is pinned too, because the tempting simplification (probe only AFTER `is_shell_file`)
# reopens the fail-open: an unreadable EXTENSIONLESS file cannot be ruled out as a shell script.
E="$TMP/f11am"; mkdir -p "$E/scripts"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/ok.sh"
printf 'notes, not shell\n' > "$E/scripts/notes.txt"
chmod 000 "$E/scripts/notes.txt"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 644 "$E/scripts/notes.txt"
[ "$rc" -eq 0 ] && pass "an unreadable file the guard never reads is not a false block (exit 0)" \
             || fail "an unreadable .txt was refused (exit $rc) — a false block"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/deploy"
chmod 000 "$E/scripts/deploy"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 644 "$E/scripts/deploy"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "an unreadable EXTENSIONLESS file is still fatal (exit 2)" \
             || fail "an unreadable extensionless file was reported clean (exit $rc)"

# 11an. the SCAN PASS's own status is part of the fail-closed contract, and it was the last hole
# in it: a scanner that is missing or that fails prints no hits, and no hits is indistinguishable
# from a clean tree — the guard would print ✅ over files it never read. `awk` is stubbed through
# PATH, as 11ag stubs `mktemp`, so the pin does not depend on uninstalling anything.
E="$TMP/f11an"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$E/fakebin/awk"
chmod +x "$E/fakebin/awk"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING scanner refuses a verdict (exit 2)" \
             || fail "a failing scanner still produced a verdict (exit $rc)"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All SIGPIPE false-negative tests passed (${checks} assertions)"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
