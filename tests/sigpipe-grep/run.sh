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
#      still exit 2 (11ab). NO pin distinguishes this on a real `find` alone: BSD find emits no
#      cycle diagnostic at all, and GNU findutils reports it but ALSO exits 1 while listing every
#      file — so a raw-status refusal turned that into a false block (it reddened `sigpipe-grep` on
#      CI). 11ai therefore stubs `find` to pin all three halves on every platform: the exemption
#      (a), the enumerator's status being judged AFTER the exemption so GNU's exit 1 is not a false
#      block (a2), and the ANCHOR of the match (b). TWO pins are platform-gated, so the assertion
#      count depends on it: 11af runs only where find reports an unresolvable chain, and 11ah only
#      where /dev/full exists — both GNU/Linux. The count is therefore platform-dependent; read it
#      from the suite's own summary line rather than pinning a number here.
#
#  12be. a shell option between `-c` and its command string is not read as the body.
#  13. NON-BUILTIN PRODUCER (#864). The guard matches `printf`/`echo` PLUS a `grep`: the failure
#      is `pipefail` + the quiet grep early exit, not the producer identity. 13a pins DETECTION
#      (bare, via an intermediary, by path, with an env prefix, with a data pipe in the
#      producer's own argument, continued, in a substitution, and the by-path-plus-data-pipe
#      CONJUNCTION) and is the only sub-section that fails on the un-widened guard; 13b is an
#      over-block CONTROL (safe forms: capture-then-case, here-string, non-quiet consumer);
#      13c is a NON-VACUITY pin that the idiom really does lose the match on a >64 KiB payload;
#      13d pins the ACCEPTED over-block (a producer that writes nothing) so it stays deliberate.
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
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if printf '\''%s'\'' "$R" | grep -q "$DEPLOY_REF"; then echo y; fi' > "$E/.github/scripts/deploy"
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
[ "$rc" -eq 2 ] && grep -q 'the scan set is empty' "$OUT" && pass "--dirs '' → exit 2 (never a silent fall back to the default set)" \
             || fail "--dirs '' fell back to the default set (exit $rc)"

# 11i. a whitespace-only set resolves to a ZERO-ELEMENT array: a usage error, not a zero-file
# scan reported as clean (and not a `set -u` crash on bash 3.2). On 3.2 the empty array also trips
# `set -u` in the enumeration subshell, so the refusal has two independent sources there; this pin
# asserts the refusal itself, not which of the two produced it. The message is asserted because on
# this platform the `set -u` crash refuses the same case: without it the pin stays green if the
# check is deleted, so it would not be covering what it is named for (measured: deleting the check
# leaves the suite green on bash 3.2 and fails on bash 5).
E="$TMP/f11i"; mkdir -p "$E/scripts"; printf 'echo hi\n' > "$E/scripts/a.sh"
rc="$(bash "$GUARD" --root "$E" --dirs '   ' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && grep -q 'the scan set is empty' "$OUT" && pass "a whitespace-only scan set → exit 2" \
             || fail "a whitespace-only scan set was not rejected as empty (exit $rc)"

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
if [ "$rc_empty" -eq 2 ] && [ "$rc_ws" -eq 2 ] && grep -q 'the scan set is empty' "$OUT"; then
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
# (a2) ...and the ENUMERATOR'S STATUS must be judged after the exemption, not before it. GNU
# findutils reports a cycle AND exits 1 while listing every file, so a raw status refusal turns the
# benign case into a false block — it reddened `sigpipe-grep` on CI. This pin is the GNU shape.
printf '%s\n' '#!/bin/sh' \
  'case "$*" in *-maxdepth\ 0*) printf "%s\n" "scripts"; exit 0 ;; esac' \
  'printf "%s\n" "find: File system loop detected; ‘scripts/loop’ is part of the same file system loop as ‘scripts’." >&2' \
  'printf "%s\n" "scripts/a.sh"' 'exit 1' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && pass "a cycle that ALSO exits 1 is still exempt (exit 1, not a false block)" \
             || fail "find's exit 1 on a cycle became a false block (exit $rc)"
# (b) a permission error whose path merely CONTAINS the cycle text must NOT be exempt. The stub
# answers the `-maxdepth 0` probe on stdout, so ONLY the partition can decide this — writing only
# to stderr would make the probe refuse first and pass this pin for the wrong reason.
printf '%s\n' '#!/bin/sh' \
  'case "$*" in *-maxdepth\ 0*) printf "%s\n" "scripts" ;; esac' \
  'printf "%s\n" "find: scripts/File system loop detected/x: Permission denied" >&2' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "the cycle match is ANCHORED: an error whose path contains the text is still fatal (exit 2)" \
             || fail "an unanchored cycle match exempted a real partial scan (exit $rc)"

# (a3) ...and the exemption is scoped PER DIRECTORY: a cycle report from one dir must not excuse a
# DIFFERENT dir that exited non-zero with no diagnostic at all. Exempting it globally reports a clean
# scan over that dir's unenumerated files — and a silent or shimmed enumerator is precisely the case
# this status check exists for.
E="$TMP/f11ai3"; mkdir -p "$E/a" "$E/b" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/b/withheld.sh"
printf '%s\n' '#!/bin/sh' \
  't="$2"' \
  'case "$*" in *-maxdepth\ 0*) printf "%s\n" "$t"; exit 0 ;; esac' \
  'case "$t" in *a*) printf "%s\n" "find: File system loop detected; ‘a/loop’ is part of the same file system loop as ‘a’." >&2; exit 1 ;; esac' \
  'exit 1' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc_one="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'b' >"$OUT" 2>&1; echo $?)"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'a b' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && [ "$rc_one" -eq 2 ] && ! grep -q '✅' "$OUT" \
  && pass "a cycle in one dir does not exempt another dir's silent failure (exit 2)" \
  || fail "a cycle report globally exempted a different dir's silent failure (exit $rc, alone $rc_one)"

# 11aj. A file the scan LISTED but cannot OPEN is not "clean". `find -L` STAT'd it, so no
# diagnostic reaches the partition, and the readiness probe is what names it — but the probe is not
# the only defence: the scanner's own status (SCAN_RC) refuses the same case, so this pin asserts the
# REFUSAL (exit 2), which either path provides, rather than the probe specifically (measured:
# deleting the probe still exits 2 via SCAN_RC). Pinned with a mode-000 `*.sh`, which is claimed by
# NAME, so no shebang read is involved and the pin isolates this case.
E="$TMP/f11aj"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked.sh"
chmod 000 "$E/scripts/locked.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
chmod 644 "$E/scripts/locked.sh"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "an unreadable LISTED file refuses a verdict (exit 2)" \
             || fail "the idiom in an unreadable file was reported clean (exit $rc)"

# 11aj2. ...and a CLIPPED first line is the same undecidable case as an empty read: the reader stops
# at 4096 bytes, so a longer first line has its interpreter token cut off, names no shell, and the
# file is dropped from the scan set — a clean verdict over an extensionless file that holds the
# idiom. The refusal is bounded to a genuinely clipped line, so the boundary control below (a file
# SHORT enough to be read whole, whose first line is just as long) must stay clean.
E="$TMP/f11aj2"; mkdir -p "$E/scripts"
{
  printf '#!'; printf 'a%.0s' $(seq 1 4090); printf '/bin/bash\n'
  printf 'printf '\''%s'\'' "$V" | grep -q pat\n'
} > "$E/scripts/longshebang"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a first line longer than the reader reads refuses a verdict (exit 2)" \
             || fail "a clipped shebang line dropped an extensionless file from the scan set (exit $rc)"
# the boundary: the same long first line, in a file small enough to be read to the end, is decided
# by its content — and that tree is CLEAN, so the refusal keys on the CLIP, not on a long line
E="$TMP/f11aj2b"; mkdir -p "$E/scripts"
{
  printf '#!'; printf 'a%.0s' $(seq 1 4000); printf '/bin/bash\n'
} > "$E/scripts/shortshebang"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] && grep -q '✅' "$OUT" && pass "a long first line in a file read WHOLE is classified, not refused (exit 0)" \
             || fail "a fully-read long first line was refused by length alone (exit $rc)"

# 11ak. ...and the sink must be ABSOLUTE. The precondition and the partition read run in the
# guard's OWN cwd, but `find` writes to it after `cd "$ROOT"` — so a RELATIVE mktemp result names
# two different files: find's errors land in $ROOT/<name>, the partition reads $PWD/<name> empty,
# and a partial scan reads as a clean one. GNU `mktemp` emits exactly that shape when TMPDIR is
# relative, so `mktemp` is stubbed to emit it without depending on the platform's mktemp. The
# cwd MUST differ from --root, or the two resolutions coincide and the pin is vacuous.
E="$TMP/f11ak"; mkdir -p "$E/scripts/locked" "$E/fakebin" "$E/run"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/locked/a.sh"
chmod 000 "$E/scripts/locked"
# The enumerator is stubbed to print the PROBE answer AND a permission diagnostic, then exit 0 — so
# it is find's SILENCE about the unreadable dir, not its exit status, that must refuse. With a real
# `find` the enumerator-status guard fired first and this pin (and 11al below) passed without
# exercising the sink at all.
printf '%s\n' '#!/bin/sh' 'case "$*" in *-maxdepth\ 0*) printf "%s\n" "scripts"; exit 0 ;; esac' 'printf "%s\n" "find: scripts/locked: Permission denied" >&2' 'exit 0' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
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
printf '%s\n' '#!/bin/sh' 'case "$*" in *-maxdepth\ 0*) printf "%s\n" "scripts"; exit 0 ;; esac' 'printf "%s\n" "find: scripts/locked: Permission denied" >&2' 'exit 0' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
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

# 11an. the SCAN PASS's own status is part of the fail-closed contract: a scanner that is missing
# or that fails prints no hits, and no hits is indistinguishable
# from a clean tree — the guard would print ✅ over files it never read. `awk` is stubbed through
# PATH, as 11ag stubs `mktemp`, so the pin does not depend on uninstalling anything.
E="$TMP/f11an"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$E/fakebin/awk"
chmod +x "$E/fakebin/awk"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING scanner refuses a verdict (exit 2)" \
             || fail "a failing scanner still produced a verdict (exit $rc)"

# 11ao. a FAILING READER is not a clean file. `is_shell_file` reads a bounded shebang prefix with
# `head`; an empty read names no interpreter, so an EXTENSIONLESS shell file is dropped from the
# scan set and the guard reports clean over a file it never read — the exact tortoise#7588 shape,
# since the files that arm exists to claim are precisely the extensionless ones. `head` is stubbed
# through PATH, as 11ag stubs `mktemp`.
E="$TMP/f11ao"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/deploy"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$E/fakebin/head"
chmod +x "$E/fakebin/head"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING shebang reader refuses a verdict (exit 2)" \
             || fail "a failing reader dropped an extensionless shell file (exit $rc)"

# 11ap. ...and the CLASSIFICATION pass is the same class: if it fails while HITS is non-empty, the
# verdict loop is skipped and an idiom that WAS found is never reported. `cut` is the only tool in
# that pipeline the scan-status guard cannot see, so it is pinned separately.
E="$TMP/f11ap"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$E/fakebin/cut"
chmod +x "$E/fakebin/cut"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING classifier refuses a verdict (exit 2)" \
             || fail "a found idiom was dropped by a failing classifier (exit $rc)"
# ...and the PARTIAL classifier is the shape the value cross-check CANNOT see: TWO files really do
# contain the idiom, and the classifier reports ONE of them — a genuine entry, so its list is
# non-empty and every path in it is real — and exits 3, withholding the other. Nothing downstream
# can tell the second was dropped, so the STATUS is the only thing that can refuse. The stub must
# fail ONLY on the classifying invocation: a blanket `cut` stub also intercepts `fingerprint`'s
# `cut -c1-16`, and the fingerprint refusal then yields the same exit 2, hiding the mutation
# (measured — with a blanket stub, deleting the classifier's status check left the suite green).
E="$TMP/f11ap2"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/b.sh"
printf '%s\n' '#!/bin/sh' 'case "$*" in *"-d: -f1"*) printf "%s\n" "scripts/a.sh"; exit 3 ;; esac' 'exec /usr/bin/cut "$@"' > "$E/fakebin/cut"
chmod +x "$E/fakebin/cut"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a PARTIAL classifier refuses a verdict (exit 2)" \
             || fail "a partial classification hid an undeclared idiom (exit $rc)"

# 11aq. a SILENTLY failing `find` is the one failure the diagnostics partition cannot see: it
# writes no error, so it lists nothing and the guard reports a clean run over a tree it never
# enumerated. What is checked is find's OWN status, not the pipeline's (which is only the loop's
# last iteration). `find` is stubbed through PATH, as 11ag stubs `mktemp`.
E="$TMP/f11aq"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SILENTLY failing enumerator refuses a verdict (exit 2)" \
             || fail "a silently failing find reported a tree it never listed (exit $rc)"

# 11ar. ...and membership is decided IN THE SHELL, so a `grep` that lies successfully cannot decide
# it. `grep` exits 0 (match), 1 (none) or >1 (error); a shim printing nothing and exiting 0 reports
# BOTH memberships as MATCHES, which suppresses the stale check and lets a stale declaration pass.
# The stub fails that way only on `-qx`, so the declaration lookup (which the real `grep` handles)
# still works. The idiom file must be DECLARED CORRECTLY, so the STALE line is the only finding.
E="$TMP/f11ar"; mkdir -p "$E/scripts" "$E/fakebin"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/b.sh"
printf 'scripts/b.sh 1 deadbeefdeadbeef #999\nscripts/a.sh 1 deadbeefdeadbeef #999\n' > "$E/.sigpipe-grep-exceptions.txt"
h="$(bash "$GUARD" --root "$E" --dirs 'scripts' 2>&1 | sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' | head -1)"
printf 'scripts/b.sh 1 %s #999\nscripts/a.sh 1 deadbeefdeadbeef #999\n' "$h" > "$E/.sigpipe-grep-exceptions.txt"
printf '%s\n' '#!/bin/sh' 'case "$1" in -qx) exit 0 ;; esac' 'exec /usr/bin/grep "$@"' > "$E/fakebin/grep"
chmod +x "$E/fakebin/grep"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 1 ] && grep -q 'STALE exception' "$OUT" && pass "a SILENT-SUCCESS grep cannot suppress the stale check (exit 1)" \
             || fail "a lying grep suppressed the stale check (exit $rc)"

# 11as. ...and the occurrence COUNT is the same shape once more. `grep -c` exits 1 for a zero
# count, so only >1 is an error — absorbed as a boolean, an error left `actual` EMPTY, the count
# comparison then failed SILENTLY (`integer expression expected`, `if` false), the COUNT check was
# skipped, and control fell through to the CONTENT-HASH check. A declaration whose count
# contradicts its own hash therefore passed as a warning and the guard exited 0. The declaration
# is first written with the RIGHT hash (so the hash check cannot save it) and the WRONG count.
E="$TMP/f11as"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf 'scripts/a.sh 1 deadbeefdeadbeef #999\n' > "$E/.sigpipe-grep-exceptions.txt"
h="$(bash "$GUARD" --root "$E" --dirs 'scripts' 2>&1 | sed -n 's/.*actual \([0-9a-f]\{16\}\).*/\1/p' | head -1)"
printf 'scripts/a.sh 2 %s #999\n' "$h" > "$E/.sigpipe-grep-exceptions.txt"
rc_real="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
printf '%s\n' '#!/bin/sh' 'case "$1" in -c) exit 3 ;; esac' 'exec /usr/bin/grep "$@"' > "$E/fakebin/grep"
chmod +x "$E/fakebin/grep"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc_real" -eq 1 ] && [ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING occurrence count refuses a verdict (exit 2)" \
             || fail "a failing occurrence count skipped the count check (real $rc_real, stub $rc)"
# ...and the SAME hole opens one exit code over, which is why the guard validates the VALUE and
# not the status: a shim printing nothing and exiting 1 leaves `actual` empty exactly as exit 3
# did. `grep -c` legitimately exits 1 for a ZERO count, so a status gate cannot separate them.
printf '%s\n' '#!/bin/sh' 'case "$1" in -c) exit 1 ;; esac' 'exec /usr/bin/grep "$@"' > "$E/fakebin/grep"
chmod +x "$E/fakebin/grep"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SILENT count (exit 1, no output) refuses too (exit 2)" \
             || fail "a silent count was read as zero and skipped the check (exit $rc)"

# 11at. ...and the CONTENT fingerprint is the last input to that comparison, with a failure mode a
# shape check CANNOT catch: a failing fingerprint pipeline yields the hash of EMPTY INPUT
# (`e3b0c44298fc1c14…`), which is a perfectly well-formed 16 hex chars. A declaration carrying it
# would therefore be ACCEPTED, defeating the guarantee that a count-preserving swap does not
# inherit an exception. The stub fails only on the pattern-FIRST invocation (the fingerprint),
# leaving the flag-first lookups working.
E="$TMP/f11at"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf 'scripts/a.sh 1 e3b0c44298fc1c14 #999\n' > "$E/.sigpipe-grep-exceptions.txt"
printf '%s\n' '#!/bin/sh' 'case "$1" in -*) exec /usr/bin/grep "$@" ;; esac' 'exit 3' > "$E/fakebin/grep"
chmod +x "$E/fakebin/grep"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a FAILING fingerprint refuses a verdict (exit 2)" \
             || fail "the hash of empty input was accepted as a declaration (exit $rc)"
# ...and the SILENT-SUCCESS twin, which no status check can catch: the fingerprint pipeline swallows
# its input, prints nothing and exits 0, so the digest is that of EMPTY input. Only an explicit
# value check sees it — and it is the exact failure the comment above names as un-catchable by shape.
printf '%s\n' '#!/bin/sh' 'case "$1" in -*) exec /usr/bin/grep "$@" ;; esac' 'cat >/dev/null' 'exit 0' > "$E/fakebin/grep"
chmod +x "$E/fakebin/grep"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SWALLOWING fingerprint refuses a verdict (exit 2)" \
             || fail "the empty-input digest was accepted from a silent pipeline (exit $rc)"
# ...and a fingerprint that emits a WELL-FORMED digest and FAILS is the shape neither the
# empty-value nor the empty-digest check can see; only the status can. Without it a
# count-preserving CONTENT SWAP inherits an existing exception (the fingerprint becomes a constant).
E="$TMP/f11at2"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf 'scripts/a.sh 1 aaaaaaaaaaaaaaaa #999\n' > "$E/.sigpipe-grep-exceptions.txt"
printf '%s\n' '#!/bin/sh' 'case "$*" in *256*) printf "%s\n" "aaaaaaaaaaaaaaaa"; exit 3 ;; esac' 'exec /usr/bin/shasum "$@"' > "$E/fakebin/shasum"
chmod +x "$E/fakebin/shasum"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a WELL-FORMED but failing fingerprint refuses (exit 2)" \
             || fail "a constant fingerprint let a content swap inherit an exception (exit $rc)"

# 11au. ...and a CLASSIFIER that swallows its input is the same shape: with `cut` printing nothing
# and exiting 0, FILES_WITH_HITS is empty while HITS is not, so the whole per-file loop is skipped
# and the guard reports clean with the idiom sitting in HITS. The cross-check between those two
# VALUES needs no external, so it cannot itself fail open. The stub leaves the fingerprint's
# `cut -c1-16` working so this pin isolates the classification path.
E="$TMP/f11au"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-c1-16*) exec /usr/bin/cut "$@" ;; esac' 'cat >/dev/null' 'exit 0' > "$E/fakebin/cut"
chmod +x "$E/fakebin/cut"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SWALLOWING classifier refuses a verdict (exit 2)" \
             || fail "unclassified hits were reported clean (exit $rc)"

# 11av. a SWALLOWING shebang reader (exit 0, no output) is invisible to the status check and leaves
# `chunk` empty, so an EXTENSIONLESS shell file is dropped from the scan set — the tortoise#7588
# shape, in the arm that exists to claim exactly those files. The invariant is exact and needs no
# external: a non-empty file cannot yield an empty read.
E="$TMP/f11av"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/check-migration-drift"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/clean.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$E/fakebin/head"
chmod +x "$E/fakebin/head"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SWALLOWING shebang reader refuses a verdict (exit 2)" \
             || fail "a silent reader dropped an extensionless shell file (exit $rc)"

# 11aw. ...and a SWALLOWING enumerator (exit 0, no output) lists an empty tree, so the guard reports
# `scanned 0 file(s)` and exits 0 over files that are there. Pinned because the existing enumerator
# pin (11aq) covers only a NON-ZERO exit, which is a different member of the family.
E="$TMP/f11aw"; mkdir -p "$E/scripts" "$E/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/a.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a SWALLOWING enumerator refuses a verdict (exit 2)" \
             || fail "a silently empty tree was reported clean (exit $rc)"

# 11ax. ...and a PARTIAL list with a non-zero exit is a different member again, and the only one the
# `find -maxdepth 0` probe above cannot see (that probe catches total silence). A `find` that lists
# SOME files, withholds the one holding the idiom, and exits 1 would otherwise scan an unknown
# subset and report clean — which is what find's OWN status (`PIPESTATUS[0]`, not the loop's last
# iteration) is for. The stub answers the probe, then lists a clean file only.
E="$TMP/f11ax"; mkdir -p "$E/scripts" "$E/fakebin"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/seen.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/scripts/withheld.sh"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-maxdepth\ 0*) printf "%s\n" "scripts"; exit 0 ;; esac' 'printf "%s\n" "scripts/seen.sh"' 'exit 1' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a PARTIAL list with a non-zero exit refuses (exit 2)" \
             || fail "a partial enumeration was reported clean (exit $rc)"

# 11ay. ...and the empty-read invariant must NOT fire on a file that is non-empty but CAPTURES as
# empty. Command substitution strips trailing newlines and every NUL, so a newline-only or NUL-only
# extensionless file (a `.gitkeep`) looks like an empty read in the captured text — testing the BYTE
# COUNT is what keeps that from being a false BLOCK, so this pin is a tree that must come back CLEAN.
E="$TMP/f11ay"; mkdir -p "$E/scripts"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/scripts/ok.sh"
printf '\n\n\n' > "$E/scripts/BLANK"
: > "$E/scripts/ZERO"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] && pass "a BLANK extensionless file is not a false block (exit 0)" \
             || fail "a newline-only file was refused as an empty read (exit $rc)"

# 11az. ...and `scan_files` has TWO arms, each carrying its own `return "${PIPESTATUS[0]}"`, so the
# partial-list pin above covers only the filtered one. A `.husky` hook withheld from the list is the
# same silent miss, and nothing else would notice because `.husky` files are ALL scanned. NOTE
# what this pin actually covers: with `set -o pipefail` the pipeline already yields find's non-zero
# status, so DELETEING the return is still caught; what was unpinned is an explicit WRONG one
# (`return 0`), which is what the mutation uses.
E="$TMP/f11az"; mkdir -p "$E/.husky" "$E/fakebin"
printf '#!/usr/bin/env bash\necho clean\n' > "$E/.husky/seen"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "$V" | grep -q pat' > "$E/.husky/withheld"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-maxdepth\ 0*) printf "%s\n" ".husky"; exit 0 ;; esac' 'printf "%s\n" ".husky/seen"' 'exit 1' > "$E/fakebin/find"
chmod +x "$E/fakebin/find"
rc="$(PATH="$E/fakebin:$PATH" bash "$GUARD" --root "$E" --dirs '.husky' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 2 ] && ! grep -q '✅' "$OUT" && pass "a partial .husky enumeration refuses (exit 2)" \
             || fail "a withheld .husky hook was reported clean (exit $rc)"

# ============================================================================
# 12. THE MATCHER ITSELF — the four shapes the guard used to report CLEAN (#1645)
#
#     Each of these is a FALSE CLEAN: the file is CLAIMED and counted inside
#     "scanned N file(s)" while it contains the idiom, so the gate passes over a tree
#     that has the bug. That is the one verdict a guard must never produce.
#
#     WHICH PINS DEPEND ON THIS CHANGE. Forty fail under the origin/main guard: 12a (`-qm1`),
#     12b (`/bin/grep`), 12c (`command grep`), 12d (a literal pipe in the writer argument),
#     12o (`-1q`), 12t (an invalid byte must not abort the awk scan), 12u (a long option list),
#     12v (a `--quiet` abbreviation), 12w (a separated option argument), 12x (the deliberate
#     narrowing of a `q` that an option consumed), 12y (a flag placed after the pattern, which grep
#     permutes), 12z (an `-m0` that reads all its input), 12aa (a line longer than the scan budget),
#     12ab (the command prefixes grep is reached by), 12ac (a quoted or escaped flag), 12ad (an
#     unquoted separator as a command boundary, both directions), 12af (writers after an earlier
#     writer), 12ag (a writer inside a quoted command substitution), 12ah (an option on a prefix
#     command), 12aj (a metacharacter inside a quoted option token), 12ak (a brace group carrying
#     the writer's stdout to the pipe), 12al (a subshell versus a command substitution), 12am (a
#     backtick writer boundary), 12an (a separated long option on a prefix command), 12ao (`exec` as
#     a prefix), 12ap (a consumer-side group), 12aq (a signed or zero-padded zero max-count),
#     12ar (`--silent` and its abbreviations), 12as (a wrapper that takes a bare operand before the
#     command) and 12at (a quoted shell-out body that inherits the wrapper's stdin), 12av (a body
#     reached through a path, an assignment or a substitution), 12aw (a quiet flag immediately
#     before a closer), 12ax (a clustered option on a wrapper), 12ay (a shell -c inside a cluster),
#     12az (a body past the token cap, a quoted command word, a word split by a line continuation)
#     and 12ba (a long quiet option immediately before a separator), 12bb (a body that quotes or
#     escapes its command or flag the other way), 12bc (a shell's own option arguments) and 12bd
#     (a command string attached to `env --split-string`/`-S`) and 12be (a shell option between
#     `-c` and its command string). 12au is a
#     CONTROL and passes on both guards: it pins that the ordinary adjacency match is unchanged. The
#     rest already passed there, and are kept
#     because an intermediate revision of this very change broke them: they pin PARITY with
#     origin/main, and fail if a future refactor narrows the writer word, the bridge, or the
#     recognised `grep` forms again. 12ae is one of those — a 200-option list was flagged by
#     origin/main too, so it guards a cap introduced and removed inside THIS change, and would not
#     have failed there. Measured: with GUARD pointed at origin/main's guard, exactly
#     those forty fail and no other pin does.
#
#     No single matcher covers all four, and trying to make one do it is what produced the
#     earlier false cleans. 12d needs a reader that skips quoted text; 12f/12g need a reader
#     that sees THROUGH it. The guard runs both and flags if either matches.
# ----------------------------------------------------------------------------

# 12a. `-qm1` — a digit in the same token as `q`. has_quiet() matched /^-[A-Za-z]*q[A-Za-z]*$/,
#      so the combined form was not recognised, and because the token still began with `-`
#      the loop did not stop either: it walked on to the pattern and returned 0.
E="$TMP/f12a"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -qm1 pat' > "$E/scripts/combined.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'combined\.sh' "$OUT" \
  && pass "a quiet flag carrying a digit (-qm1) is caught" \
  || fail "grep -qm1 was reported clean (exit $rc) — the false clean #1645 describes"

# 12b. `/bin/grep` — the matcher required the bare word `grep`, so a fully qualified
#      invocation was invisible to it.
E="$TMP/f12b"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | /bin/grep -q pat' > "$E/scripts/bypath.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'bypath\.sh' "$OUT" \
  && pass "a by-path invocation (/bin/grep) is caught" \
  || fail "/bin/grep -q was reported clean (exit $rc)"

# 12c. `command grep` — the form a shell function shadowing grep invites, which makes it the
#      likeliest one inside a hook.
E="$TMP/f12c"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | command grep -q pat' > "$E/scripts/shadowed.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'shadowed\.sh' "$OUT" \
  && pass "command grep is caught (the shadowing form)" \
  || fail "command grep -q was reported clean (exit $rc)"

# 12d. a literal `|` INSIDE the writer argument. The `[^|]*` bridge cannot cross it, so the
#      shape was missed even though that pipe is data rather than a pipeline break.
E="$TMP/f12d"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "a|b" | grep -q pat' > "$E/scripts/pipearg.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'pipearg\.sh' "$OUT" \
  && pass "a literal pipe inside the writer argument is caught" \
  || fail "a quoted pipe defeated the bridge and the file was reported clean (exit $rc)"

# 12e. THE COUNTERWEIGHT. A false CLEAN is the cardinal sin, but a false BLOCK is a real cost,
#      and the widened matcher must not become an over-match machine. Three near-misses must
#      stay clean — a grep with no writer, a writer whose consumer is not quiet, and a quoted
#      pipe with no grep at all — while the ONE real idiom in the same tree is still flagged.
#      This is what keeps the fix from being "match more" rather than "match correctly".
E="$TMP/f12e"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'grep -q pat file' > "$E/scripts/nowriter.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep pat' > "$E/scripts/notquiet.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "a | b"' > "$E/scripts/justdata.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -q pat' > "$E/scripts/real.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'real\.sh' "$OUT" \
  && ! grep -q 'nowriter' "$OUT" && ! grep -q 'notquiet' "$OUT" && ! grep -q 'justdata' "$OUT" \
  && pass "only the real idiom is flagged — 3 near-misses stay clean (no over-match)" \
  || fail "over-match: a near-miss was reported as the idiom (exit $rc)"

# 12f. AN ESCAPED QUOTE inside a double-quoted writer argument. Quote tracking that toggles on
#      a bare `"` closes the string at the escaped quote, so the real pipeline lands inside the
#      (apparent) string and the file is reported CLEAN — the same cardinal sin, reintroduced
#      by the quote-stripping that fixed 12d. Escape-aware tracking is the fix.
E="$TMP/f12f"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s'\'' "a \"b" | grep -q pat' > "$E/scripts/escquote.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'escquote\.sh' "$OUT" \
  && pass "an escaped quote inside the writer argument is caught" \
  || fail "a \"-escaped quote defeated quote tracking and the file was reported clean (exit $rc)"

# 12g. AN IDIOM NESTED IN A SHELL COMMAND STRING. An intermediate revision dropped the whole
#      quoted body before matching, so `bash -c '… | grep -q …'` went invisible while the
#      origin/main matcher, which reads the raw line, flagged it. Matching the raw line keeps
#      this at parity with origin/main (this pin passes under the old matcher too).
E="$TMP/f12g"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "bash -c 'printf \"%s\" \"\$V\" | grep -q pat'" > "$E/scripts/nested.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'nested\.sh' "$OUT" \
  && pass "an idiom nested in a shell command string (bash -c '…') is caught" \
  || fail "the nested shell-command idiom was reported clean (exit $rc) — a regression vs origin/main"

# 12m. THE WRITER WORD IS NOT ALWAYS A BARE, UNQUOTED, SPACE-SEPARATED TOKEN. Bounding the
#      writer to a command boundary regressed six of these to CLEAN — a quoted word, an
#      escaped word, a backtick substitution, and a writer with no space before the pipe were
#      all flagged by origin/main and went silent. The matcher is a superset of origin/main, so
#      every one of them stays flagged.
E="$TMP/f12m"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' '"printf" "%s" "$V" | grep -q pat'      > "$E/scripts/qword.sh"
printf '%s\n' '#!/usr/bin/env bash' '\printf "%s" "$V" | grep -q pat'        > "$E/scripts/escword.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=`printf "%s" "$V" | grep -q pat`'      > "$E/scripts/btick.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo|grep -q pat'                          > "$E/scripts/nospace.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
missed=""
for f in qword escword btick nospace; do grep -q "$f\.sh" "$OUT" || missed="$missed $f"; done
[ "$rc" -ne 0 ] && [ -z "$missed" ] \
  && pass "a quoted, escaped, backticked or unspaced writer word is still caught" \
  || fail "bounding the writer word to a command start lost:$missed (exit $rc)"

# 12h. A QUOTED PIPE IS NOT A BRIDGE. Quote-stripping could let the bridge cross a `;` and
#      charge an unrelated later pipeline to the `echo` — a false BLOCK, the opposite failure.
#      Kept at parity with origin/main (this pin passes under the old matcher too).
E="$TMP/f12h"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'echo "a|b" ; ls | grep -q p' > "$E/scripts/stmtsep.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -q pat' > "$E/scripts/real2.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'real2\.sh' "$OUT" && ! grep -q 'stmtsep\.sh' "$OUT" \
  && pass "a quoted pipe followed by an unrelated pipeline is not a false block" \
  || fail "the bridge crossed a statement separator and reported stmtsep.sh (exit $rc)"

# 12i. A REDIRECTION between the writer and the pipe. `2>&1` contains an `&`, and a bridge
#      narrowed to exclude `&` (to stop it crossing `&&`) also stops here and reports the
#      idiom clean — a regression vs origin/main, which crosses it.
E="$TMP/f12i"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" 2>&1 | grep -q pat' > "$E/scripts/redir.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'redir\.sh' "$OUT" \
  && pass "a 2>&1 redirection before the pipe does not hide the idiom" \
  || fail "the idiom behind a 2>&1 redirect was reported clean (exit $rc)"

# 12j. A GROUP as the writer. The `;` inside `{ ... }` does not break the pipeline, and a
#      scanner that stops at the first `;` reports the idiom clean.
E="$TMP/f12j"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' '{ printf "%s" "$V"; } | grep -q pat' > "$E/scripts/group.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'group\.sh' "$OUT" \
  && pass "the idiom in a brace group is caught" \
  || fail "a brace-grouped writer was reported clean (exit $rc)"

# 12k. THE IDIOM IS NOT THE FIRST WRITER ON THE LINE. Stopping at the first `printf|echo`
#      reported the second one clean when it was the only one in the idiom.
E="$TMP/f12k"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "bash -c 'echo hi'; bash -c 'printf \"%s\" \"\$V\" | grep -q pat'" > "$E/scripts/second.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'second\.sh' "$OUT" \
  && pass "a later writer on the line is still scanned" \
  || fail "only the first writer on the line was examined (exit $rc)"

# 12l. THE FALSE-BLOCK DIRECTION. `-e1q` is `-e` with pattern `1q`, NOT quiet. A widen that
#      accepts a digit anywhere in the token flags a pipeline that cannot SIGPIPE.
E="$TMP/f12l"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -e1q' > "$E/scripts/notquiet.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -q pat' > "$E/scripts/real3.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'real3\.sh' "$OUT" && ! grep -q 'notquiet\.sh' "$OUT" \
  && pass "grep -e1q is not mistaken for a quiet flag" \
  || fail "a digit before the q in a grep flag was treated as quiet (exit $rc)"

# 12n. A LATER SITE MUST NOT BE MASKED BY AN EARLIER NON-QUIET ONE. `match()` returns only the
#      LEFTMOST hit, so `printf x | grep -v; echo|grep -q p` was reported clean — the first site
#      (`grep -v`) matched, was found non-quiet, and the genuine idiom after it was never
#      examined. The widenings made this reachable on lines the old matcher flagged, so it is a
#      regression, not a latent quirk.
E="$TMP/f12n"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | /bin/grep -v; echo|grep -q pat' > "$E/scripts/masked.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'masked\.sh' "$OUT" \
  && pass "an earlier non-quiet grep does not mask a later idiom" \
  || fail "the first match masked the real idiom and the file was reported clean (exit $rc)"

# 12o. `-1q` IS QUIET; `-e1q` AND `-m1q` ARE NOT. A leading run of digits is grep's -NUM context
#      option (`grep -1 -q`), but a digit that is an option's ARGUMENT is not: `-e1q` is `-e`
#      with pattern `1q`, and `-m1q` is `-m` with junk. Both directions are pinned here.
E="$TMP/f12o"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -1q pat' > "$E/scripts/numopt.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -e1q' > "$E/scripts/earg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -m1q' > "$E/scripts/marg.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'numopt\.sh' "$OUT" \
  && ! grep -q 'earg\.sh' "$OUT" && ! grep -q 'marg\.sh' "$OUT" \
  && pass "grep -1q is quiet but -e1q and -m1q are not" \
  || fail "the leading-context digit was confused with an option argument (exit $rc)"

# 12p. A WRITER THAT IS AN ARGUMENT IS NOT A WRITER. `grep -e echo ... | grep -q p` pipes the
#      first grep's output; charging that pipe to `echo`, or to a path-like token after a `;`,
#      flags lines the old matcher left clean — a new false block.
E="$TMP/f12p"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'foo -e echo -e "OK|FAIL" "$f" | grep -q FAIL' > "$E/scripts/argwriter.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | foo;/bin/grep -q p' > "$E/scripts/pathsep.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] \
  && pass "a writer that is an argument, and a grep after a statement separator, stay clean" \
  || fail "a new false block: $(grep -o '[a-z]*\.sh' "$OUT" | tr '\n' ' ')(exit $rc)"

# 12q. THE SCANNER MUST NOT CHARGE A PIPE THE WRITER CANNOT REACH. Each fixture carries a quoted
#      pipe, which is what defeats raw_idiom — so this pins scan_idiom alone. It does NOT claim the
#      guard ignores these constructs in general: raw_idiom is blind to a redirect exactly as
#      origin/main is, so a pipe-free payload such as `printf x >f | grep -q p` is flagged by BOTH
#      guards (pre-existing, and recoverable through the exceptions file).
E="$TMP/f12q"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "a|b" >f | grep -q p'            > "$E/scripts/redirout.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "a|b" > /dev/null | grep -q p'    > "$E/scripts/redirnull.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "a|b" & cat | grep -q p'           > "$E/scripts/background.sh"
printf '%s\n' '#!/usr/bin/env bash' 'wc <(echo "a|b") | grep -q p'          > "$E/scripts/procsub.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf -v x "a|b" | grep -q p'          > "$E/scripts/printfv.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] \
  && pass "a redirect, background job, process substitution or printf -v is not charged to the scanner" \
  || fail "the scanner charged a pipe the writer cannot reach: $(grep -o '[a-z]*\.sh' "$OUT" | tr '\n' ' ')(exit $rc)"

# 12r. A `q` CONSUMED BY AN OPTION ARGUMENT IS NOT A QUIET FLAG. In `-eq1` and `-1eq` the `q` is
#      part of the pattern `-e` takes, so grep reads all its input; a rule that accepted any digit
#      after the `q` called these quiet — a new false block. `-1q`/`-q1` are the mirror case and
#      must still be caught (a leading digit run is the -NUM context option).
E="$TMP/f12r"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -eq1 p'  > "$E/scripts/eq1.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -1eq p'  > "$E/scripts/oneeq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -fq1 p'  > "$E/scripts/fq1.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -mq1 p'  > "$E/scripts/mq1.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] \
  && pass "a q consumed as an option argument is not a quiet flag" \
  || fail "a new false block: $(grep -o '[a-z0-9]*\.sh' "$OUT" | tr '\n' ' ')(exit $rc)"

# 12s. THE SCAN IS BOUNDED. Scanning the remainder from every writer made the cost grow with the
#      square of the line length (an 800-token line took 18s and a 2,000-token line 92s, against
#      0.13s before). A line with no pipe at all is skipped outright. This pin fails loudly (by
#      stalling the suite) if the per-writer scan is ever unbounded again.
E="$TMP/f12s"; mkdir -p "$E/scripts"
{ printf '#!/usr/bin/env bash\n'; i=0; while [ "$i" -lt 2000 ]; do printf 'echo '; i=$((i + 1)); done; printf '\n'; } > "$E/scripts/longline.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -eq 0 ] \
  && pass "a 2,000-writer line is scanned without the quadratic blow-up" \
  || fail "the scanner did not handle a long writer-dense line (exit $rc)"

# 12t. AN INVALID UTF-8 BYTE MUST NOT ABORT THE AWK SCAN. Under a UTF-8 locale awk substr is
#      multibyte-aware and a file with a bad byte fails with a towc multibyte conversion error,
#      which the guard turns into exit 2 — refusing a verdict over a file it could have read.
#      The awk now runs under LC_ALL=C, where substr is byte-oriented. (The guard may still
#      refuse LATER, in its classification pass, whose sed also fails closed on an invalid byte;
#      that is pre-existing and is a refusal, not a verdict, so only the awk abort is pinned.)
E="$TMP/f12t"; mkdir -p "$E/scripts"
printf '#!/usr/bin/env bash\nprintf "\377" | grep -q p\n' > "$E/scripts/badbyte.sh"
bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1
! grep -qi 'multibyte' "$OUT" \
  && pass "an invalid UTF-8 byte does not abort the awk scan" \
  || fail "awk aborted on an invalid byte: $(grep -i multibyte "$OUT" | head -1)"

# 12u. A LONG OPTION LIST MUST NOT HIDE THE FLAG — on EITHER matcher. `has_quiet` walks grep's
#      options from an offset and stops at the first non-option token, and the scanner takes the
#      full remainder; both are unbounded in what they can read. Handing either a fixed-size window
#      made a `-q` beyond it invisible and reported a genuine idiom clean, so this pins both paths
#      at 9,000 bytes of options (the size at which the window was measured to break).
E="$TMP/f12u"; mkdir -p "$E/scripts"
LONG=""; _i=0; while [ "$_i" -lt 9000 ]; do LONG="${LONG}a"; _i=$((_i + 1)); done
printf '%s\n' '#!/usr/bin/env bash' "printf x | grep --include=$LONG -q pat"       > "$E/scripts/longopt.sh"
printf '%s\n' '#!/usr/bin/env bash' "echo \"a|b\" | grep --include=$LONG -q pat" > "$E/scripts/longoptscan.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'longopt\.sh' "$OUT" && grep -q 'longoptscan\.sh' "$OUT" \
  && pass "a quiet flag beyond a long option list is still found, on both matchers" \
  || fail "a long option list hid the flag and an idiom was reported clean (exit $rc)"

# 12v. `--quiet` ABBREVIATIONS ARE QUIET. getopt accepts any unambiguous prefix of a long option,
#      and only `--quiet` begins with `q`, so `--q`, `--qu`, `--qui` and `--quie` are the same
#      flag. Only the full spelling was recognised, so the rest were reported clean.
E="$TMP/f12v"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --quie pat' > "$E/scripts/abbrev.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --q pat'    > "$E/scripts/shortabbrev.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'abbrev\.sh' "$OUT" && grep -q 'shortabbrev\.sh' "$OUT" \
  && pass "an unambiguous abbreviation of --quiet is treated as quiet" \
  || fail "a --quiet abbreviation was reported clean (exit $rc)"

# 12w. A SEPARATED OPTION ARGUMENT. `-e`, `-f`, `-m`, `-A`, `-B`, `-C`, `-d`, `-D` consume the NEXT
#      token, so `grep -e pat -q` IS quiet - and the walk used to stop at `pat` as though it were
#      the pattern, reporting CLEAN. Measured against real grep on a large payload: rc 141.
E="$TMP/f12w"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -e pat -q'     > "$E/scripts/shortarg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -m 1 -q'       > "$E/scripts/numarg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --include x -q' > "$E/scripts/longarg.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'shortarg\.sh' "$OUT" && grep -q 'numarg\.sh' "$OUT" && grep -q 'longarg\.sh' "$OUT" \
  && pass "an option argument separated from its flag does not hide a later -q" \
  || fail "a separated option argument stopped the walk and an idiom was reported clean (exit $rc)"

# 12x. THE `q` AFTER A CONSUMING OPTION IS ITS ARGUMENT, NOT A FLAG. origin/main flagged `-eq`,
#      `-fq`, `-Aq` and the rest; real grep treats `-eq` as `-e q` and reads all its input, so
#      THIS change deliberately reports them clean. Pinned so the narrowing is not mistaken for a
#      regression and re-broadened back into a false block.
E="$TMP/f12x"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -eq pat' > "$E/scripts/eqbare.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -fq p'   > "$E/scripts/fqbare.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -Aq p'   > "$E/scripts/aqbare.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -q pat'   > "$E/scripts/real4.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'real4\.sh' "$OUT" \
  && ! grep -q 'eqbare\.sh' "$OUT" && ! grep -q 'fqbare\.sh' "$OUT" && ! grep -q 'aqbare\.sh' "$OUT" \
  && pass "a q consumed as an option argument is not a flag (a deliberate narrowing)" \
  || fail "the q-as-option-argument narrowing was lost (exit $rc)"

# 12y. GREP PERMUTES OPTIONS. `grep PATTERN -q` IS quiet (measured rc 141 against GNU grep 3.8) —
#      the walk used to stop at the first non-option token, treating the pattern as the end of the
#      options, and reported the idiom clean.
E="$TMP/f12y"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep pat -q'        > "$E/scripts/operandfirst.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -F pat --quiet' > "$E/scripts/operandlong.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep pat -A 2 -q'  > "$E/scripts/operandctx.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'operandfirst\.sh' "$OUT" && grep -q 'operandlong\.sh' "$OUT" && grep -q 'operandctx\.sh' "$OUT" \
  && pass "a quiet flag after the pattern is still found (grep permutes options)" \
  || fail "the walk stopped at the pattern and an idiom was reported clean (exit $rc)"

# 12z. `-m0` CANCELS QUIET. max-count 0 makes grep read ALL its input, so the writer cannot die
#      (measured rc 1, not 141). Flagging the attached form was a NEW false block; the separated
#      `-q -m0` was already a false block in origin/main.
E="$TMP/f12z"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -qm0 pat'  > "$E/scripts/m0attached.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -q -m0 pat' > "$E/scripts/m0separate.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$V" | grep -q pat'     > "$E/scripts/real5.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'real5\.sh' "$OUT" \
  && ! grep -q 'm0attached\.sh' "$OUT" && ! grep -q 'm0separate\.sh' "$OUT" \
  && pass "a max-count of zero cancels quiet, attached or separated" \
  || fail "an -m0 pipeline was flagged although grep reads all its input (exit $rc)"

# 12aa. A LONG LINE IS STILL READ. The scan is bounded per LINE and never truncated per writer,
#       and it is bounded per COMMAND rather than per token count: a byte window, a token cap or a
#       per-line budget each ended the scan on a CLEAN verdict, which is the one verdict a guard
#       must never reach without reading. This is the shape that made the old budget refuse or
#       report clean.
E="$TMP/f12aa"; mkdir -p "$E/scripts"
PAD="$(head -c 1100000 /dev/zero | tr '\000' 'a')"
printf '%s\n' '#!/usr/bin/env bash' "printf \"%s\" \"a|b\" \"\$V\" | grep -q pat # $PAD" > "$E/scripts/longline2.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'longline2\.sh' "$OUT" \
  && pass "a data-pipe idiom on a line longer than the scan budget is still found" \
  || fail "a line longer than the budget was reported clean without being scanned (exit $rc)"

# 12ab. THE COMMAND PREFIXES grep IS REACHED THROUGH. `printf x | LC_ALL=C grep -q p` IS the idiom
#       (measured rc 141), and a prefix run — an environment assignment, or env/nice/command/time/
#       sudo bare or by path — was admitted by neither matcher, so each was reported clean.
E="$TMP/f12ab"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | LC_ALL=C grep -q pat'        > "$E/scripts/envassign.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env grep -q pat'             > "$E/scripts/envcmd.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | nice grep -q pat'            > "$E/scripts/nicecmd.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sudo grep -q pat'            > "$E/scripts/sudocmd.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | time grep -q pat'            > "$E/scripts/timecmd.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | /usr/bin/env grep -q pat'    > "$E/scripts/envpath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | LC_ALL=C /bin/grep -q pat'   > "$E/scripts/envandpath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | LC_ALL=C grep pat'           > "$E/scripts/envnotquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'envassign\.sh' "$OUT" && grep -q 'envcmd\.sh' "$OUT" \
  && grep -q 'nicecmd\.sh' "$OUT" && grep -q 'sudocmd\.sh' "$OUT" && grep -q 'timecmd\.sh' "$OUT" \
  && grep -q 'envpath\.sh' "$OUT" && grep -q 'envandpath\.sh' "$OUT" \
  && ! grep -q 'envnotquiet\.sh' "$OUT" \
  && pass "grep is recognised through the command prefixes it is reached by" \
  || fail "a prefixed grep was reported clean, or a prefix alone was flagged (exit $rc)"

# 12ac. THE SHELL REMOVES THE QUOTING BEFORE GREP SEES IT. A flag written inside double quotes, inside
#       single quotes, escaped with a backslash, or as an ANSI-C string all reach grep as `-q`
#       (measured rc 141); the walk tokenised the raw text and read none of them as an option.
E="$TMP/f12ac"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep "-q" pat'    > "$E/scripts/dqflag.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep '\''-q'\'' pat' > "$E/scripts/sqflag.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep \-q pat'     > "$E/scripts/escflag.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep $'\''-q'\'' pat' > "$E/scripts/ansiflag.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep "-v" pat'    > "$E/scripts/dqnotquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'dqflag\.sh' "$OUT" && grep -q 'sqflag\.sh' "$OUT" \
  && grep -q 'escflag\.sh' "$OUT" && grep -q 'ansiflag\.sh' "$OUT" && ! grep -q 'dqnotquiet\.sh' "$OUT" \
  && pass "a quoted or escaped -q is read as the flag the shell hands grep" \
  || fail "a quoted flag was reported clean, or quoted non-flag text was flagged (exit $rc)"

# 12ad. A SEPARATOR IS A COMMAND BOUNDARY ONLY WHEN IT IS UNQUOTED. A pattern operand that merely
#       CONTAINS a pipe or a semicolon is still the operand (`grep -E 'a|b' -q` is quiet, measured
#       rc 141), while an option carrying a real `;` ends the command (`grep -x;y -q pat` runs
#       grep -x, so the -q belongs to another command and the writer cannot die). A raw separator
#       test got both backwards: it reported the first clean and the second flagged.
E="$TMP/f12ad"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -E '\''a|b'\'' -q'  > "$E/scripts/qpattern.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep '\''a;b'\'' -q'     > "$E/scripts/qsemi.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep '\''a|b'\'' pat'    > "$E/scripts/notquiet.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -x;y -q pat'        > "$E/scripts/optsep.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'qpattern\.sh' "$OUT" && grep -q 'qsemi\.sh' "$OUT" \
  && ! grep -q 'notquiet\.sh' "$OUT" && ! grep -q 'optsep\.sh' "$OUT" \
  && pass "a quoted separator stays in its operand, an unquoted one ends the command" \
  || fail "a quoted pattern hid the flag, or a separator-joined command borrowed one (exit $rc)"

# 12ae. THERE IS NO TOKEN CAP ON THE OPTION WALK. A 200-token cap ended the walk on a CLEAN verdict,
#       so a -q past it was invisible — 200 harmless options sufficed (a regression against
#       origin/main, whose walk was unbounded). Both sides of the boundary are pinned.
E="$TMP/f12ae"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "printf x | grep$(printf ' -i%.0s' $(seq 1 200)) -q pat" > "$E/scripts/tok200.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | grep$(printf ' -i%.0s' $(seq 1 199)) -q pat" > "$E/scripts/tok199.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'tok200\.sh' "$OUT" && grep -q 'tok199\.sh' "$OUT" \
  && pass "a quiet flag is found however many options precede it" \
  || fail "an option count ended the walk and hid a later flag (exit $rc)"

# 12af. ONE PASS OVER THE LINE, NOT ONE SCAN PER WRITER. The scanner used to re-walk the remainder
#       from every writer — quadratic in the writer count — and a per-line budget that could only
#       be spent on scanning less (a false clean) or refusing a verdict. A genuine idiom that
#       follows a long run of writers was reported clean once that budget ran out.
E="$TMP/f12af"; mkdir -p "$E/scripts"
MANY="$(printf 'echo x ; %.0s' $(seq 1 600))printf '%s' \"a|b\" | grep -q pat"
printf '%s\n' '#!/usr/bin/env bash' "$MANY" > "$E/scripts/manywriters.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'manywriters\.sh' "$OUT" \
  && pass "an idiom after hundreds of writers on one line is still found" \
  || fail "the writer count on a line hid a later idiom (exit $rc)"

# 12ag. A WRITER INSIDE A QUOTED REGION IS SCANNED IN ITS OWN CONTEXT. `out="$(printf ... | grep -q
#       p)"` puts the writer inside the outer double quotes while its own argument holds a data pipe,
#       so the streaming pass sees a quoted `printf` and raw_idiom's `[^|]*` bridge stops at the
#       data pipe — both blind at once, and the file was reported clean. Quoting RESTARTS inside a
#       command substitution, so the scan restarts at the writer.
E="$TMP/f12ag"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'out="$(printf "%s" "a|b" | grep -q pat)"'    > "$E/scripts/subassign.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$(printf "%s" "a|b" | grep -q pat)"'    > "$E/scripts/subecho.sh"
printf '%s\n' '#!/usr/bin/env bash' '"$(printf "%s" "a|b" | /bin/grep -q pat)"'    > "$E/scripts/subpath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'out="$(printf "%s" "a|b" | grep pat)"'        > "$E/scripts/subnotquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'subassign\.sh' "$OUT" && grep -q 'subecho\.sh' "$OUT" \
  && grep -q 'subpath\.sh' "$OUT" && ! grep -q 'subnotquiet\.sh' "$OUT" \
  && pass "a writer inside a quoted command substitution is scanned in its own quoting context" \
  || fail "a quoted command substitution hid an idiom with a data pipe (exit $rc)"

# 12ah. PREFIXES ARE COMMANDS WITH THEIR OWN OPTIONS. `env -i grep -q p`, `nice -n 5 grep -q p` and
#       `sudo -u root grep -q p` are all quiet (measured with the oracle), and the prefix walk used to
#       stop at the option token. The argument forms are separated ON PURPOSE: treating `-i` as
#       argument-taking would swallow the `grep` and report a false clean instead.
E="$TMP/f12ah"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env -i grep -q pat'     > "$E/scripts/envopt.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | nice -n 5 grep -q pat'  > "$E/scripts/nicearg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sudo -u root grep -q pat' > "$E/scripts/sudoarg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | command -p grep -q pat' > "$E/scripts/cmdopt.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env -u VAR grep -q pat' > "$E/scripts/envunset.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env cat grep -q pat'    > "$E/scripts/envcat.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | nice -n 5 cat'          > "$E/scripts/nicecat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'envopt\.sh' "$OUT" && grep -q 'nicearg\.sh' "$OUT" \
  && grep -q 'sudoarg\.sh' "$OUT" && grep -q 'cmdopt\.sh' "$OUT" && grep -q 'envunset\.sh' "$OUT" \
  && ! grep -q 'envcat\.sh' "$OUT" && ! grep -q 'nicecat\.sh' "$OUT" \
  && pass "an option on a prefix command does not hide the grep it prefixes" \
  || fail "a prefixed command with an option was reported clean, or another command was flagged (exit $rc)"

# 12ai. THE OPTION ANALYSIS IS NOT CAPPED, ONLY THE TOKEN VALUE IS. The token string is capped
#       because concatenating a huge token is quadratic in this awk, but a `q` PAST the cap was then
#       invisible - a false clean introduced by this change and caught by review.
E="$TMP/f12ai"; mkdir -p "$E/scripts"
LONGOPT="$(printf 'i%.0s' $(seq 1 399))"
printf '%s\n' '#!/usr/bin/env bash' "printf x | grep -${LONGOPT}q pat" > "$E/scripts/longcluster.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'longcluster\.sh' "$OUT" \
  && pass "a quiet flag in an option cluster longer than the token cap is still found" \
  || fail "the token cap hid a trailing flag (exit $rc)"

# 12aj. AN OPTION CLUSTER CANNOT CONTAIN A SHELL METACHARACTER. `grep "-q;x" pat` hands grep the
#       single argument `-q;x`, which grep rejects (exit 2) - it never reads, so it is not a quiet
#       grep, and the pipeline fails loudly rather than silently. Unquoting the token made it read
#       as `-q` and flagged it.
E="$TMP/f12aj"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep "-q;x" pat' > "$E/scripts/quotedmetachar.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep "-q" pat'    > "$E/scripts/stillquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'stillquiet\.sh' "$OUT" && ! grep -q 'quotedmetachar\.sh' "$OUT" \
  && pass "a metacharacter inside an option token is not a quiet flag" \
  || fail "an unquoted metacharacter was read as a flag, or a real flag was missed (exit $rc)"

# 12ak. A BRACE GROUP SENDS ITS STDOUT TO THE PIPE. `{ printf "%s" "a|b"; } | grep -q pat` is the
#       idiom (measured rc 141), but the `;` and the closing `}` cleared the writer, and raw_idiom is
#       blocked by the data pipe. The `;` only ends the command when no group is open.
E="$TMP/f12ak"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' '{ printf "%s" "a|b"; } | grep -q pat'  > "$E/scripts/bracegroup.sh"
printf '%s\n' '#!/usr/bin/env bash' '{ printf "%s" "a|b"; } | grep pat'     > "$E/scripts/bracenotquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'bracegroup\.sh' "$OUT" && ! grep -q 'bracenotquiet\.sh' "$OUT" \
  && pass "a brace group carrying the writer's stdout to the pipe is found" \
  || fail "the group separator cleared a writer whose stdout reaches the pipe (exit $rc)"

# 12al. A SUBSHELL PASSES STDOUT ON; A COMMAND SUBSTITUTION CAPTURES IT. `( printf ... ) | grep -q
#       p` is the idiom (the subshell stdout is the pipe), while `$(echo p) | grep -q p` is not (the
#       substitution output is captured, so nothing reaches the pipe). Clearing the writer on every
#       `)` got both backwards, and also lost the pipe when the substitution was merely an ARGUMENT
#       of the writer.
E="$TMP/f12al"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "( printf '%s|%s' a b ) | grep -q pat"                > "$E/scripts/subshell.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" $(echo) "a|b" | grep -q pat'             > "$E/scripts/argcapture.sh"
printf '%s\n' '#!/usr/bin/env bash' '$(echo "a|b") | grep -q pat'                         > "$E/scripts/captured.sh"
printf '%s\n' '#!/usr/bin/env bash' 'wc <(echo "a|b") | grep -q pat'                      > "$E/scripts/procsub.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'subshell\.sh' "$OUT" && grep -q 'argcapture\.sh' "$OUT" \
  && ! grep -q 'captured\.sh' "$OUT" && ! grep -q 'procsub\.sh' "$OUT" \
  && pass "a subshell keeps the pipe and a command substitution captures it" \
  || fail "a captured or subshell-captured writer was mis-charged (exit $rc)"

# 12am. A BACKTICK STARTS A COMMAND SUBSTITUTION. It is a command boundary like `$(`, so a writer
#       right after one is a writer - and, like `$(`, its stdout is CAPTURED, so a pipe after the
#       closer is not the writer's.
E="$TMP/f12am"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'x=`printf "%s" "a|b" | grep -q pat`'  > "$E/scripts/backtick.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=`printf "%s" "a|b" | /bin/grep -q pat`' > "$E/scripts/backtickpath.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'backtick\.sh' "$OUT" && grep -q 'backtickpath\.sh' "$OUT" \
  && pass "a writer inside a backtick substitution is found" \
  || fail "the backtick writer boundary was not recognised (exit $rc)"

# 12an. A PREFIX COMMAND'S LONG OPTIONS. `env --unset VAR grep -q p`, `nice --adjustment 5 grep -q p`
#       and `stdbuf --output 0 grep -q p` are quiet (oracle), and the argument is SEPARATED - so the
#       walk has to know which long options take one. The attached spelling needs no rule and is
#       pinned as the control.
E="$TMP/f12an"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env --unset VAR grep -q pat'    > "$E/scripts/envlong.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | nice --adjustment 5 grep -q pat' > "$E/scripts/nicelong.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | stdbuf --output 0 grep -q pat'   > "$E/scripts/stdfbuflong.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sudo --user root grep -q pat'    > "$E/scripts/sudolong.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env --unset=VAR grep -q pat'     > "$E/scripts/envlongattached.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'envlong\.sh' "$OUT" && grep -q 'nicelong\.sh' "$OUT" \
  && grep -q 'stdfbuflong\.sh' "$OUT" && grep -q 'sudolong\.sh' "$OUT" && grep -q 'envlongattached\.sh' "$OUT" \
  && pass "a separated long option on a prefix command does not hide the grep it prefixes" \
  || fail "a prefix long option hid the grep (exit $rc)"

# 12ao. `exec` IS A PREFIX. `printf x | exec grep -q pat` replaces the subshell with grep, which reads
#       the pipe and exits at its first match - the writer can die. Add it to the prefix run.
E="$TMP/f12ao"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | exec grep -q pat'  > "$E/scripts/execgrep.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | exec cat'          > "$E/scripts/execcat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'execgrep\.sh' "$OUT" && ! grep -q 'execcat\.sh' "$OUT" \
  && pass "grep reached through exec is recognised, other exec commands are not" \
  || fail "exec grep was reported clean, or a non-grep exec was flagged (exit $rc)"

# 12ap. A CONSUMER-SIDE GROUP IS TRANSPARENT. `| (grep -q pat)` and `| { grep -q pat; }` send the
#       group stdout to the pipe, so grep inside reads the writer - the group char arrives attached
#       to the command word.
E="$TMP/f12ap"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | (grep -q pat)'        > "$E/scripts/parengroup.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | { grep -q pat; }'     > "$E/scripts/bracegroup2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "a|b" | (grep -q pat)' > "$E/scripts/parengroup2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | (cat)'                > "$E/scripts/parencat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'parengroup\.sh' "$OUT" && grep -q 'bracegroup2\.sh' "$OUT" \
  && grep -q 'parengroup2\.sh' "$OUT" && ! grep -q 'parencat\.sh' "$OUT" \
  && pass "a group on the consumer side of the pipe is transparent to the grep inside it" \
  || fail "a grouped quiet grep was reported clean, or a grouped other command was flagged (exit $rc)"

# 12aq. A ZERO max-count CARRIES A SIGN OR EXTRA ZEROS. `--max-count=0000`, `--max-count=+0` and
#       `-m +0` all mean max-count ZERO, so grep reads all its input (oracle rc 1, not 141) and the
#       writer cannot die. An exact `=0` spelling test flagged all three.
E="$TMP/f12aq"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --max-count=0000 -q pat' > "$E/scripts/mczeros.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --max-count=+0 -q pat'   > "$E/scripts/mcplus.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -m +0 -q pat'            > "$E/scripts/mplus.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --max-count=1 -q pat'    > "$E/scripts/mcone.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'mcone\.sh' "$OUT" && ! grep -q 'mczeros\.sh' "$OUT" \
  && ! grep -q 'mcplus\.sh' "$OUT" && ! grep -q 'mplus\.sh' "$OUT" \
  && pass "a zero max-count is zero however it is spelled" \
  || fail "a zero max-count was treated as quiet, or a non-zero one as quiet cancelling (exit $rc)"

# 12ar. `--silent` IS `--quiet`. GNU grep documents `-q, --quiet, --silent` as ONE option, and it
#       accepts any unambiguous abbreviation of a long option, so `--s`, `--si`, `--sil`, `--sile`
#       and `--silen` are all quiet too. Only the `--quiet` ladder was recognised, so
#       `printf x | grep --silent pat` reported CLEAN while grep exited at its first match and the
#       writer died (measured rc 141 against GNU grep 3.8 under pipefail).
E="$TMP/f12ar"; mkdir -p "$E/scripts"
printf '%s
' '#!/usr/bin/env bash' 'printf x | grep --silent pat'  > "$E/scripts/long.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | grep --sil pat'     > "$E/scripts/abbr3.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | grep --si pat'      > "$E/scripts/abbr2.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | grep --silent'      > "$E/scripts/nopat.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | grep --no-messages pat' > "$E/scripts/control.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'long\.sh' "$OUT" && grep -q 'abbr3\.sh' "$OUT" && grep -q 'abbr2\.sh' "$OUT" && grep -q 'nopat\.sh' "$OUT" \
  && ! grep -q 'control\.sh' "$OUT" \
  && pass "--silent and its abbreviations are quiet (and --no-messages is not)" \
  || fail "a --silent spelling was reported clean, or --no-messages was called quiet (exit $rc)"

# 12as. A WRAPPER THAT TAKES AN OPERAND. `timeout 5 grep -q pat` pipes the writer into a quiet grep
#       (measured rc 141), and `timeout` puts its DURATION — a bare operand — before the command, so
#       a walk that stops at the duration reports CLEAN. The same hold for `nohup`/`setsid`/`busybox`,
#       and `timeout --kill-after 5 10` consumes its option value AND a duration before the command.
E="$TMP/f12as"; mkdir -p "$E/scripts"
printf '%s
' '#!/usr/bin/env bash' 'printf x | timeout 5 grep -q pat'                    > "$E/scripts/tmo.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | timeout -k 5 10 grep -q pat'              > "$E/scripts/tmok.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | timeout --kill-after 5 10 grep -q pat'    > "$E/scripts/tmolong.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | nohup grep -q pat'                        > "$E/scripts/nohup.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | setsid grep -q pat'                       > "$E/scripts/setsid.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | busybox grep -q pat'                      > "$E/scripts/busybox.sh"
printf '%s
' '#!/usr/bin/env bash' 'printf x | timeout 5 cat'                            > "$E/scripts/tmocat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'tmo\.sh' "$OUT" && grep -q 'tmok\.sh' "$OUT" && grep -q 'tmolong\.sh' "$OUT" \
  && grep -q 'nohup\.sh' "$OUT" && grep -q 'setsid\.sh' "$OUT" && grep -q 'busybox\.sh' "$OUT" \
  && ! grep -q 'tmocat\.sh' "$OUT" \
  && pass "a wrapper with a bare operand before the command is seen through" \
  || fail "a wrapper's operand hid the grep, or a non-grep wrapper command was flagged (exit $rc)"

# 12at. A QUOTED SHELL-OUT BODY IS A COMMAND. `printf x | sh -c 'grep -q pat'` and
#       `printf x | eval "grep -q pat"` both pipe the writer into a quiet grep (measured rc 141):
#       the body inherits the wrapper's stdin, so a separator INSIDE the body does not end the
#       command the way an unquoted one does. The walk saw one opaque token and reported CLEAN.
E="$TMP/f12at"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c 'grep -q pat'"                > "$E/scripts/shc.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -c "grep -q pat"'             > "$E/scripts/bashc.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | eval "grep -q pat"'                > "$E/scripts/evalq.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c 'set -e; grep -q pat'"       > "$E/scripts/shcsep.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c 'cat'"                       > "$E/scripts/shccat.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c 'grep pat'"                  > "$E/scripts/shcnq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | eval cat'                           > "$E/scripts/evalcat.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sed "s/grep -q//"'                > "$E/scripts/sedctl.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -x;y -q pat'                  > "$E/scripts/unqsep.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'shc\.sh' "$OUT" && grep -q 'bashc\.sh' "$OUT" && grep -q 'evalq\.sh' "$OUT" && grep -q 'shcsep\.sh' "$OUT" \
  && ! grep -q 'shccat\.sh' "$OUT" && ! grep -q 'shcnq\.sh' "$OUT" && ! grep -q 'evalcat\.sh' "$OUT" \
  && ! grep -q 'sedctl\.sh' "$OUT" && ! grep -q 'unqsep\.sh' "$OUT" \
  && pass "a quoted shell-out body is read as the command it is, and only when it has a quiet grep" \
  || fail "a shell-out body with a quiet grep was clean, or a body without one was flagged (exit $rc)"

# 12au. CONTROL: the wrapper set did not disturb the ordinary match. `printf x | grep -q pat` is the
#       adjacency the guard has always flagged and `--quiet` is still the long spelling of it, while
#       `printf x | cat | grep -q pat` stays CLEAN: the writer is piped into `cat`, not into grep, and
#       charging that later pipe to the writer is the two-stage false block the guard deliberately
#       does not make.
E="$TMP/f12au"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -q pat'            > "$E/scripts/plain.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | cat | grep -q pat'      > "$E/scripts/twostage.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --quiet pat'       > "$E/scripts/quietlong.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'plain\.sh' "$OUT" && grep -q 'quietlong\.sh' "$OUT" && ! grep -q 'twostage\.sh' "$OUT" \
  && pass "the ordinary adjacency match is unchanged by the wrapper set" \
  || fail "a plain quiet grep or --quiet was missed, or the two-stage form was flagged (exit $rc)"

# 12av. A BODY REACHED THROUGH SOMETHING ELSE. The body is read before the token is classified, so
#       an absolute path, an environment assignment or a command substitution at its start does not
#       hide the grep: `/bin/grep -q pat`, `LC_ALL=C grep -q pat`, `FOO=1 grep -q pat`,
#       `y=$(grep -q pat)` and a backtick form all inherit the wrapper's stdin. The path group in
#       the body pattern was `+` while the non-body one was `*`, so a body that STARTED with `/`
#       never matched at all; the assignment skip ran before the body was read; and a backtick was
#       not in the boundary class.
E="$TMP/f12av"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c '/bin/grep -q pat'"       > "$E/scripts/abspath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "LC_ALL=C grep -q pat"' > "$E/scripts/assign.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "FOO=1 grep -q pat"'    > "$E/scripts/assign2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "y=$(grep -q pat)"'     > "$E/scripts/subst.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "echo `grep -q pat`"'   > "$E/scripts/backtick.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "cat"'                  > "$E/scripts/bodycat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'abspath\.sh' "$OUT" && grep -q 'assign\.sh' "$OUT" && grep -q 'assign2\.sh' "$OUT" \
  && grep -q 'subst\.sh' "$OUT" && grep -q 'backtick\.sh' "$OUT" && ! grep -q 'bodycat\.sh' "$OUT" \
  && pass "a body starting with a path, an assignment or a substitution is still read" \
  || fail "a wrapper body was skipped because of how its first word looked (exit $rc)"

# 12aw. A QUIET FLAG IMMEDIATELY BEFORE A CLOSER. `grep pat -q; echo done`, `{ grep pat -q; }`,
#       `(grep pat -q)` and `grep pat -q)` ARE quiet: the separator ends the COMMAND, not the
#       option, and discarding the whole token threw the `q` away with it. An EMBEDDED separator
#       still ends the command (`grep -x;y -q pat`), and the control pins that the re-analysis
#       keeps the max-count-zero cancellation: `grep -qm0; echo x` is NOT quiet.
E="$TMP/f12aw"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep pat -q; echo done' > "$E/scripts/semi.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | { grep pat -q; }'       > "$E/scripts/brace.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | (grep pat -q)'          > "$E/scripts/paren.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep pat -q)'           > "$E/scripts/stray.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -x;y -q pat'       > "$E/scripts/embedded.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -qm0; echo x'      > "$E/scripts/m0semi.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'semi\.sh' "$OUT" && grep -q 'brace\.sh' "$OUT" && grep -q 'paren\.sh' "$OUT" && grep -q 'stray\.sh' "$OUT" \
  && ! grep -q 'embedded\.sh' "$OUT" && ! grep -q 'm0semi\.sh' "$OUT" \
  && pass "a quiet flag before a closer is quiet, an embedded separator still ends the command" \
  || fail "a trailing closer swallowed the flag, or an embedded separator did not end the command (exit $rc)"

# 12ax. A CLUSTERED OPTION ON A WRAPPER. getopt groups, so `timeout -vk 5 10 grep -q pat` is the
#       same command as `timeout -v -k 5 10 grep -q pat` (already flagged): `-v` takes no argument
#       and `-k` does. Reading only the letter after the dash made `-vk` look argument-less, so the
#       duration was taken for the command and the idiom was reported clean. The control keeps a
#       wrapper whose command is not a grep clean.
E="$TMP/f12ax"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout -vk 5 10 grep -q pat' > "$E/scripts/vk.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout -vs 9 5 grep -q pat'  > "$E/scripts/vs.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout -v -k 5 10 grep -q pat' > "$E/scripts/sep.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout -k5 10 grep -q pat'    > "$E/scripts/attached.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout -vk 5 10 cat'          > "$E/scripts/vkcat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'vk\.sh' "$OUT" && grep -q 'vs\.sh' "$OUT" && grep -q 'sep\.sh' "$OUT" && grep -q 'attached\.sh' "$OUT" \
  && ! grep -q 'vkcat\.sh' "$OUT" \
  && pass "a clustered wrapper option is read whole, attached or separated" \
  || fail "a clustered option on a wrapper hid the grep, or a non-grep command was flagged (exit $rc)"

# 12ay. A SHELL `-c` IN A CLUSTER. `sh -ce "grep -q pat"` is the grouped spelling of `sh -c -e ...`,
#       and a shell command string is ALWAYS the next argv operand (an attached form is an error, not
#       an attached argument). The generic attached-argument rule read `-ce` as argument-less, so the
#       body was never offered to the reader and the idiom was reported clean - inside the wrapper
#       allowlist the header claims to see through. The control keeps `sh -c` with a non-grep body
#       clean and pins that a `-c`-less cluster is not treated as a body host.
E="$TMP/f12ay"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -ce "grep -q pat"'      > "$E/scripts/ce.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -cx "grep -q pat"'    > "$E/scripts/cx.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | dash -cl "grep -q pat"'    > "$E/scripts/cl.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | timeout 5 sh -ce "grep -q pat"' > "$E/scripts/tmo.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -ce "cat"'              > "$E/scripts/cecat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'ce\.sh' "$OUT" && grep -q 'cx\.sh' "$OUT" && grep -q 'cl\.sh' "$OUT" && grep -q 'tmo\.sh' "$OUT" \
  && ! grep -q 'cecat\.sh' "$OUT" \
  && pass "a shell -c inside a cluster still hands over its body" \
  || fail "a clustered shell -c hid its body, or a non-grep body was flagged (exit $rc)"

# 12az. A WRAPPER BODY LONGER THAN THE TOKEN CAP, AND A WIDE BODY SHAPE. The body is read from the
#       LINE, not from the 400-character stored token: a body whose `grep` sits past the cap used to
#       be invisible. The extra files pin two more ways a body reaches its command - a quoted command
#       word (quote characters are blanked before the test) and a word split by a backslash-newline,
#       which the shell joins with NOTHING while the guard used to join with a space (`gr` + `ep`
#       became two words and stopped being `grep`).
E="$TMP/f12az"; mkdir -p "$E/scripts"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf x | sh -c "%s; grep -q pat"\n' "$(printf 'A%.0s' $(seq 1 500))"
} > "$E/scripts/long.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c \"'grep' -q pat\"" > "$E/scripts/quoted.sh"
printf '#!/usr/bin/env bash\nprintf x | sh -c "gr\\\nep -q pat"\n' > "$E/scripts/continuation.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "cat"'             > "$E/scripts/longcat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'long\.sh' "$OUT" && grep -q 'quoted\.sh' "$OUT" && grep -q 'continuation\.sh' "$OUT" \
  && ! grep -q 'longcat\.sh' "$OUT" \
  && pass "a body past the token cap, a quoted command word, and a split word are all read" \
  || fail "a long body, a quoted command word or a split word hid the grep (exit $rc)"

# 12ba. A LONG QUIET OPTION BEFORE A SEPARATOR. `grep -e pat --quiet;echo done` IS quiet: the
#       separator ends the COMMAND, and the token is read up to the FIRST one, so the same rule now
#       serves both directions - `-q;echo` has the flag BEFORE the separator and is quiet, while
#       `-x;y -q pat` has it after and is not. The long-option ladder had no separator handling at
#       all, so `--quiet;` matched neither it nor the invalid-option test. The control is the
#       max-count-zero cancellation surviving the same strip.
E="$TMP/f12ba"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -e pat --quiet;echo done'  > "$E/scripts/lq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -e pat --silent;echo done' > "$E/scripts/ls.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -e pat -q;echo done'      > "$E/scripts/sq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -f pfile -q;echo done'    > "$E/scripts/fq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep -x;y -q pat'              > "$E/scripts/embedded.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | grep --max-count=0 -q;echo x'  > "$E/scripts/m0long.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'lq\.sh' "$OUT" && grep -q 'ls\.sh' "$OUT" && grep -q 'sq\.sh' "$OUT" && grep -q 'fq\.sh' "$OUT" \
  && ! grep -q 'embedded\.sh' "$OUT" && ! grep -q 'm0long\.sh' "$OUT" \
  && pass "a flag before a separator is quiet, and a flag after it is not, for long and short options" \
  || fail "a long quiet option before a separator was dropped, or an embedded separator borrowed a flag (exit $rc)"

# 12bb. A BODY THAT SPELLS ITS COMMAND OR ITS FLAG WITH QUOTING OR BACKSLASHES. The INNER shell
#       removes BOTH quote flavours and backslashes before it execs the body, so every one of these
#       runs a quiet grep. Only the single quote was blanked, which fixed one direction of quoting
#       and left the other, plus every escaped spelling, a false clean. The control is a body with
#       no quiet grep in it.
E="$TMP/f12bb"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "\"grep\" -q x"'   > "$E/scripts/dq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "\grep -q x"'       > "$E/scripts/esc.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "g\rep -q x"'       > "$E/scripts/midesc.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "grep -\q x"'       > "$E/scripts/flagesc.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "grep -\"q\" x"'  > "$E/scripts/flagdq.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c "grep -v x"'         > "$E/scripts/control.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'dq\.sh' "$OUT" && grep -q 'esc\.sh' "$OUT" && grep -q 'midesc\.sh' "$OUT" \
  && grep -q 'flagesc\.sh' "$OUT" && grep -q 'flagdq\.sh' "$OUT" && ! grep -q 'control\.sh' "$OUT" \
  && pass "a body that quotes or escapes its command or flag the other way is still read" \
  || fail "a quoted or escaped body spelling was reported clean (exit $rc)"

# 12bc. A SHELL OWN OPTIONS. A shell's `-c` does NOT take an attached argument - it takes the FIRST
#       NON-OPTION operand - while `-o`/`-O` DO take a separated one, and the long forms
#       `--init-file`/`--rcfile` take a value. Treating `-o` as argument-less made its VALUE the
#       command and stopped the walk before the `-c` that carried the body; `+o`/`+O` were not even
#       dispatched. The controls keep a shell whose body is not a grep CLEAN.
E="$TMP/f12bc"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -o pipefail -c "grep -q p"'      > "$E/scripts/o.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -euo pipefail -c "grep -q p"'    > "$E/scripts/uo.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -O extglob -c "grep -q p"'      > "$E/scripts/bigO.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash +o pipefail -c "grep -q p"'     > "$E/scripts/pluso.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash +O extglob -c "grep -q p"'      > "$E/scripts/plusbigO.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash --init-file /dev/null -c "grep -q p"' > "$E/scripts/initf.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -co pipefail "grep -q p"'       > "$E/scripts/co.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash -o pipefail -c "cat"'           > "$E/scripts/ocat.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | bash --rcfile /dev/null -c "cat"'    > "$E/scripts/rccat.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'o\.sh' "$OUT" && grep -q 'uo\.sh' "$OUT" && grep -q 'pluso\.sh' "$OUT" \
  && grep -q 'plusbigO\.sh' "$OUT" && grep -q 'initf\.sh' "$OUT" && grep -q 'co\.sh' "$OUT" \
  && ! grep -q 'ocat\.sh' "$OUT" && ! grep -q 'rccat\.sh' "$OUT" \
  && pass "a shell option argument is not mistaken for the shell command string" \
  || fail "a shell option argument was read as the command, or a non-grep body was flagged (exit $rc)"

# 12bd. `env --split-string=CMD` AND ITS ATTACHED SHORT FORM. GNU coreutils adds an option whose
#       ATTACHED value is a command string, the only one in the allowlist: the generic attached-value
#       rule discards it, and the body must be read from the value with the option prefix removed
#       (otherwise the command word has no boundary before it). The control keeps a non-grep value
#       clean.
E="$TMP/f12bd"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env --split-string="grep -q p"' > "$E/scripts/long.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | env -S'grep -q p'"            > "$E/scripts/short.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | env --split-string="cat"'    > "$E/scripts/control.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'long\.sh' "$OUT" && grep -q 'short\.sh' "$OUT" && ! grep -q 'control\.sh' "$OUT" \
  && pass "a command string attached to env --split-string or -S is read" \
  || fail "an env attached command string was reported clean (exit $rc)"

# 12be. A SHELL OPTION BETWEEN `-c` AND ITS COMMAND STRING. A shell accepts further options after
#       `-c` (`sh -c -e 'grep -q pat'`, `bash -c -x ...`, `sh -c -c ...`), so the option is not the
#       command string. The pending-body slot consumed the OPTION, `body_quiet` saw `-e` for a body,
#       and the real body was never read. The control keeps a shell option with a non-grep body
#       CLEAN, and `sh -c` with nothing after it is clean too (nothing is executed).
E="$TMP/f12be"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c -e 'grep -q pat'"     > "$E/scripts/e.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | bash -c -x 'grep -q pat'"   > "$E/scripts/x.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c -c 'grep -q pat'"     > "$E/scripts/cc.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c -- 'grep -q pat'"     > "$E/scripts/dd.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c -e -x 'grep -q pat'" > "$E/scripts/ex.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf x | sh -c -e 'cat'"            > "$E/scripts/ecat.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf x | sh -c'                    > "$E/scripts/nobody.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
[ "$rc" -ne 0 ] && grep -q 'e\.sh' "$OUT" && grep -q 'x\.sh' "$OUT" && grep -q 'cc\.sh' "$OUT" && grep -q 'dd\.sh' "$OUT" \
  && grep -q 'ex\.sh' "$OUT" && ! grep -q 'ecat\.sh' "$OUT" && ! grep -q 'nobody\.sh' "$OUT" \
  && pass "a shell option between -c and its command string is not mistaken for the body" \
  || fail "an option was consumed as the shell command string (exit $rc)"

echo ""
echo "13. NON-BUILTIN PRODUCER — a grep upstream (#864)"
# #841's guard matched the builtin writers only, so the same false negative with a `grep`
# producer (`grep -v … | grep -q …`) sat outside it: measured on a 1.4 MB multi-line payload
# with the match on line 1, the idiom returns 141 under `pipefail` and the downstream `-q`
# never reports the match.
#
# WHAT EACH SUB-SECTION PINS (they are not interchangeable):
#   13a  DETECTION — the TWENTY-NINE fixtures below. NON-VACUOUS: all twenty-nine are reported
#        CLEAN by #841's guard — the PRE-change guard, which is `git show origin/main:scripts/check-no-sigpipe-grep.sh`
#        (NOT `HEAD`, which by the time you read this is the widened guard and reports all
#        twenty-nine as hits at rc 1) — so this whole block fails before the widening. Verified
#        2026: the pre-change guard exits 0 on all twenty-nine, the head guard exits 1 naming all
#        twenty-nine.
#   13b  OVER-BLOCK CONTROL — the safe forms. Expected to PASS on the old guard AND the new
#        one; it does not detect the widening, it detects an over-broad version of it.
#   13c  NON-VACUITY — no guard is invoked at all; it pins the CLASS (the idiom really does
#        lose the match), not the matcher.
#   13d  ACCEPTED OVER-BLOCK — the producer that writes nothing. Documented, not accidental.
E="$TMP/f13"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'grep -vxF -f list f | grep -q "[^[:space:]]"'  > "$E/scripts/plain.sh"
printf '%s\n' '#!/usr/bin/env bash' 'head -n 5 f | grep -vE "#" | grep -q needle'   > "$E/scripts/staged.sh"
printf '%s\n' '#!/usr/bin/env bash' '/bin/grep -v foo f | command grep -qx bar'     > "$E/scripts/aliased.sh"
printf '%s\n' '#!/usr/bin/env bash' 'LC_ALL=C grep -v foo f | LC_ALL=C grep -q bar' > "$E/scripts/prefixed.sh"
# The classes the DECLARED threat surface for this change requires: the producer's own
# argument carrying a literal `|` (which a single-line regex bridge cannot cross), a producer
# split from its pipe by a line continuation, a producer inside a wrapper body, and a producer
# in command substitution. Each is an attacker-shaped spelling of the ONE bypass under test —
# "get a grep producer past the matcher" — so each is a pin, not a nicety.
printf '%s\n' '#!/usr/bin/env bash' 'grep "a|b" f | grep -q bar'                  > "$E/scripts/quotepipe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -v foo f \' '  | grep -q bar'            > "$E/scripts/continued.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=$(grep -v foo f | grep -q bar)'               > "$E/scripts/subst.sh"
# COMPOSED fixtures. The blind spots of the two matchers MEET where a path-qualified producer
# also carries a data pipe in its own argument: raw_idiom's `[^|]*` bridge cannot cross that
# pipe, and scan_idiom's boundary test rejected the path — so the conjunction was reported
# CLEAN at rc 141 while every single-dimension fixture above was flagged (review of #864).
# These four are that conjunction, and each FAILS on the widening without the path handling.
printf '%s\n' '#!/usr/bin/env bash' '/usr/bin/grep -E "a|b" f | grep -q bar'      > "$E/scripts/bypath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'env /usr/bin/grep -E "a|b" f | grep -q bar'  > "$E/scripts/wrapbypath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'head -n 5 f | /usr/bin/grep -E "a|b" | grep -q needle' > "$E/scripts/stagedbypath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=$(/usr/bin/grep -E "a|b" f | grep -q bar)' > "$E/scripts/substbypath.sh"
# The prefix spellings that reach the SAME false clean, each measured at rc 141 on a >64 KiB
# payload with the match on line 1: a WRAPPER option before the word (the option belongs to the
# wrapper, not to another command), a QUOTED or ESCAPED word, a $-rooted path, and a PROCESS
# SUBSTITUTION in the producer's own argument (which is INPUT redirection — it does not move the
# stdout off the pipe). Each was CLEAN before this widening and is pinned so it stays flagged.
printf '%s\n' '#!/usr/bin/env bash' 'env -i grep -E "a|b" f | grep -q bar'         > "$E/scripts/wrapopt.sh"
printf '%s\n' '#!/usr/bin/env bash' '"grep" -E "a|b" f | grep -q bar'            > "$E/scripts/quotedword.sh"
printf '%s\n' '#!/usr/bin/env bash' '\grep -E "a|b" f | grep -q bar'             > "$E/scripts/escapedword.sh"
printf '%s\n' '#!/usr/bin/env bash' '$HOME/bin/grep -E "a|b" f | grep -q bar'     > "$E/scripts/varpath.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -f <(cat list | head -2) f | grep -q bar' > "$E/scripts/procsubst.sh"
# The fourth declared class: a producer INSIDE a WRAPPER BODY, where the producer own argument
# carries the data pipe of the quotepipe class. Both original matchers miss it — raw_idiom cannot
# cross the data pipe, and scan_from reads the body level-0 escaped quote as a level-1 escape, so
# the data pipe looks like a real break — and the quoted-body pass in the guard resolves the body
# and hands it BACK to those matchers. Both measured rc 141 on a >64 KiB payload with the match on
# line 1, and CLEAN on the pre-change guard.
printf '%s\n' '#!/usr/bin/env bash' 'eval "grep -vE \"x|y\" f | grep -q needle"' > "$E/scripts/evalbody.sh"
printf '%s\n' '#!/usr/bin/env bash' 'env -S "grep -vE x|y f" | grep -q needle'    > "$E/scripts/envsbody.sh"
# The NESTED-WRITER conjunction: the enclosing writer state is a single pair of globals, so a
# writer INSIDE a capture overwrote it and a pipe inside the capture was judged against the INNER
# writer — the enclosing writer ownership was gone by the time the capture closed and its real
# pipe was never evaluated, so the line was CLEAN at rc 141 (#864 review). The enclosing state is
# now saved and restored across the capture. The wrapper-body spellings carry the same shape
# inside a body, so the quoted-body pass hands it back to the same matcher and the fix applies
# there too. All five are CLEAN on the pre-change guard; the process-substitution and printf
# forms measured rc 141 under `pipefail` on a >64 KiB payload with the match on line 1 (13c
# measures the underlying idiom), and `sh -c` is the same shape for a shell that has `<(`.
printf '%s\n' '#!/usr/bin/env bash' 'grep -f <(grep -v x f | head) f | grep -q bar'        > "$E/scripts/nestedsubst.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -f $(grep -v x f | head -1) f | grep -q bar'     > "$E/scripts/nestedcmdsubst.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -f <(printf x | head) f | grep -q bar'           > "$E/scripts/nestedprintf.sh"
printf '%s\n' '#!/usr/bin/env bash' 'eval "grep -f <(grep -v x f | head) f | grep -q bar"' > "$E/scripts/evalnest.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sh -c "grep -f <(grep -v x f | head) f | grep -q bar"' > "$E/scripts/shcnest.sh"
# The spellings that reach the SAME false clean THROUGH a MULTI-TOKEN prefix, each measured at
# rc 141 on the same payload: a wrapper two or more tokens back because its option has a
# SEPARATED ARGUMENT (`env -u FOO -i grep`, `env -u FOO -- grep`) or because it carries several
# options (`stdbuf -i0 -o0 grep`) — a one-token lookback lands on the option or on its argument
# and never reaches the wrapper; a QUOTED `env -S` BODY carrying a data pipe (the single-quoted
# spelling; `envsbody.sh` above is the double-quoted one), where restarting at the body close
# re-opened quoting so the outer pipe was never charged; and an unquoted BRACED VARIABLE among
# the producer arguments, whose `}` a group-depth-0 test read as a group close and so cleared the
# writer. Each was reported CLEAN before this round (review of #864); `envbody.sh` is covered by
# the wrapper-body pass already, and is kept as the single-quoted pin of that class.
printf '%s\n' '#!/usr/bin/env bash' 'env -u FOO -i grep -E "a|b" f | grep -q bar'  > "$E/scripts/multiopt.sh"
printf '%s\n' '#!/usr/bin/env bash' 'stdbuf -i0 -o0 grep -E "a|b" f | grep -q bar' > "$E/scripts/multiopt2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'env -u FOO -- grep -E "a|b" f | grep -q bar'  > "$E/scripts/multiopt3.sh"
printf '%s\n' '#!/usr/bin/env bash' "env -S 'grep -E \"a|b\" f' | grep -q bar"     > "$E/scripts/envbody.sh"
printf '%s\n' '#!/usr/bin/env bash' '/usr/bin/grep -E "a|b" ${y} f | grep -q bar'  > "$E/scripts/vararg.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -f <(cat list | head) ${y} f | grep -q bar' > "$E/scripts/procsubstvar.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc" -eq 1 ] && grep -q 'plain\.sh' "$OUT" && grep -q 'staged\.sh' "$OUT" \
   && grep -q 'aliased\.sh' "$OUT" && grep -q 'prefixed\.sh' "$OUT" \
   && grep -q 'quotepipe\.sh' "$OUT" && grep -q 'continued\.sh' "$OUT" \
   && grep -q 'subst\.sh' "$OUT" && grep -q 'bypath\.sh' "$OUT" \
   && grep -q 'wrapbypath\.sh' "$OUT" && grep -q 'stagedbypath\.sh' "$OUT" \
   && grep -q 'substbypath\.sh' "$OUT" && grep -q 'wrapopt\.sh' "$OUT" \
   && grep -q 'quotedword\.sh' "$OUT" && grep -q 'escapedword\.sh' "$OUT" \
   && grep -q 'varpath\.sh' "$OUT" && grep -q 'procsubst\.sh' "$OUT" \
   && grep -q 'evalbody\.sh' "$OUT" && grep -q 'envsbody\.sh' "$OUT" \
   && grep -q 'nestedsubst\.sh' "$OUT" && grep -q 'nestedcmdsubst\.sh' "$OUT" \
   && grep -q 'nestedprintf\.sh' "$OUT" && grep -q 'evalnest\.sh' "$OUT" \
   && grep -q 'shcnest\.sh' "$OUT" \
   && grep -q 'multiopt\.sh' "$OUT" && grep -q 'multiopt2\.sh' "$OUT" \
   && grep -q 'multiopt3\.sh' "$OUT" && grep -q 'envbody\.sh' "$OUT" \
   && grep -q 'vararg\.sh' "$OUT" && grep -q 'procsubstvar\.sh' "$OUT"; then
  pass "a grep producer piped into a quiet grep is DETECTED (bare, intermediary, by path, wrapper-prefixed, env prefix, a data pipe in the producer argument, continuation, substitution, a producer inside a wrapper body, a nested writer inside a capture, and the by-path / wrapper-option / quoted-word / escaped-word / variable-rooted / process-substitution / multi-token-wrapper / env-body / braced-variable conjunctions)"
else
  fail "a grep producer was reported CLEAN (exit $rc) — #864 regression:"
  sed -n '1,20p' "$OUT"
fi
# 13b. The SAFE forms a grep producer must not be flagged on: the capture-then-case fix, a
#      here-string, and a NON-QUIET consumer (which reads all input and cannot SIGPIPE).
#      A CONTROL, not a detection pin: the old guard exits 0 here too, so it catches only an
#      over-broad version of the widening.
E="$TMP/f13b"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'out="$(grep -vxF -f list f || true)"' 'case "$out" in *needle*) : ;; esac' > "$E/scripts/fixed.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -q needle <<<"$(grep -v x f || true)"'                                > "$E/scripts/herestring.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -v foo f | grep needle'                                                > "$E/scripts/notquiet.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
if [ "$rc" -eq 0 ]; then
  pass "the capture-then-case fix, a grep producer into a here-string, and a non-quiet consumer all pass (exit 0)"
else
  fail "false positive on a safe grep-producer form (exit $rc):"
  sed -n '1,10p' "$OUT"
fi
# 13c. NON-VACUITY for the grep producer: the class is REAL, not merely a shape. No guard is
#      invoked here — the two shell functions below ARE the measurement. On a >64 KiB multi-line
#      payload with the match on line 1, the piped idiom returns NON-ZERO while the
#      capture-then-case form returns 0, and the two MUST differ (a small payload lets the
#      producer finish before grep exits, and the pin would then pass for the wrong reason).
BIGF="$TMP/f13-big.txt"
{ printf 'MARKER needle\n'; i=0; while [ "$i" -lt 40000 ]; do printf 'padding line %d of a big payload\n' "$i"; i=$((i + 1)); done; } > "$BIGF"
note "payload: $(wc -c <"$BIGF" | tr -d ' ') bytes, multi-line, match on line 1"
grep_old() { ( set -o pipefail; grep -vxF -f /dev/null "$BIGF" | grep -q needle ) 2>/dev/null; }
grep_new() { ( set -o pipefail; out="$(grep -vxF -f /dev/null "$BIGF" || true)"; case "$out" in *needle*) return 0 ;; esac; return 1 ) 2>/dev/null; }
grep_old; g_old=$?
grep_new; g_new=$?
note "grep-producer idiom rc=$g_old   capture-then-case rc=$g_new"
if [ "$g_new" -eq 0 ] && [ "$g_old" -ne 0 ]; then
  pass "the grep-producer idiom LOSES the match (rc $g_old) while the pipe-free form finds it (rc 0)"
else
  fail "the grep-producer class did not reproduce (old=$g_old new=$g_new) — the pin would be vacuous"
fi
# 13d. ACCEPTED OVER-BLOCK, PINNED SO IT IS DELIBERATE. A producer that writes NOTHING to the
#      pipe cannot itself take the signal, so flagging it is a SHAPE flag, not a live false
#      negative — and the guard flags it anyway (see the SCOPE header). It is pinned here so
#      that narrowing it later is a CONSCIOUS change with a failing test, not a silent edit.
#      The rc is measured alongside, so the test itself records that this shape is NOT the
#      mechanism: a quiet producer never reproduces the 141 that 13c measures.
E="$TMP/f13d"; mkdir -p "$E/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'grep -q foo f | grep -q bar' > "$E/scripts/quietproducer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'grep -c foo f | grep -q bar' > "$E/scripts/countproducer.sh"
rc="$(bash "$GUARD" --root "$E" --dirs 'scripts' >"$OUT" 2>&1; echo $?)"
( set -o pipefail; grep -q needle "$BIGF" | grep -q needle ) 2>/dev/null; q_rc=$?
note "quiet-producer idiom rc=$q_rc (never 141 — it writes nothing to the pipe)"
if [ "$rc" -eq 1 ] && grep -q 'quietproducer\.sh' "$OUT" && grep -q 'countproducer\.sh' "$OUT" \
   && [ "$q_rc" -ne 141 ]; then
  pass "a producer that writes NOTHING is flagged as a documented SHAPE, and its rc is not 141 (over-block is deliberate, not the mechanism)"
else
  fail "the accepted over-block changed (guard rc=$rc, quiet-producer rc=$q_rc) — was the predicate narrowed? Then move this pin to a clean-form assertion and update the SCOPE header"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All SIGPIPE false-negative tests passed (${checks} assertions)"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
