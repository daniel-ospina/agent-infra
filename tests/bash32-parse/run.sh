#!/bin/bash
# shard: off runs in a dedicated job in BOTH lanes (ci.yml `bash32-parse`, ci-main.yml `bash32-parse-guard`) — a shard here would be a second run site (#2439), and it needs docker or a host bash 3.x, which the shard list's hermetic contract ("temp repos / temp HOME / stubbed tools, no network") forbids.
# tests/bash32-parse/run.sh — #2930: the bash-3.2 parse gate (scripts/check-bash32-parse.sh).
#
# WHAT IS PINNED, and why each arm exists:
#   1. the live tree parses under 3.2 — the arm that FAILED before this change (merge-reminder.test.sh
#      line 2629), so the gate is measuring the defect that motivated it;
#   2. three fixtures whose only defect is a here-doc BODY inside a `$( )` carrying an unbalanced
#      quote / parenthesis / backtick — one per character class bash 3.2's substitution scanner gets
#      wrong — are each REFUSED and NAMED;
#   3. a clean fixture (the function-wrapped remedy) is ACCEPTED, and a mixed pair reports ONLY the
#      broken one: a gate that reds everything is as useless as one that greens everything;
#   4. NON-VACUITY: every one of those fixtures parses CLEAN under this host's bash (5.x in CI), so
#      the gate measures the PLATFORM, not a generic syntax error. A merely-malformed fixture would
#      prove nothing, which is why this arm is the reason the fixtures are shaped as they are;
#   5. fail-closed arms: a missing BASH32, a BASH32 that is not 3.x, and an EMPTY population each
#      exit 2 and NAME the cause (#2930's class is a gate reporting OK over a platform it cannot
#      see, so "cannot measure" must never be spelled "passed");
#   6. the image is DIGEST-pinned, and the container half carries its own version check — a retargeted
#      tag would silently measure bash 5 while printing a green line;
#   7. MUTATIONS: deleting the parse-failure branch, or the interpreter-version guard, must make a
#      named arm go green — a pin that cannot fail is not a pin.
#
# The arms drive whichever interpreter path THIS host resolves (CI: the docker image; macOS: the
# system /bin/bash 3.2), so each platform exercises the half it will actually use. The half not
# exercisable here is still pinned statically (arm 6).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-bash32-parse.sh"
FIXDIR="$ROOT/tests/fixtures/bash32-parse"
FIXREL="tests/fixtures/bash32-parse"
OUT="$(mktemp /tmp/bash32-parse-out.XXXXXX)"
TMPD="$(mktemp -d /tmp/bash32-parse.XXXXXX)"
failures=0

# Guard: never modify the fixtures (same clobber-protection as tests/actionlint/run.sh).
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/bash32-parse; then
  echo "❌ tests/fixtures/bash32-parse has uncommitted modifications — commit them first."
  exit 1
fi

cleanup() { rm -f "$OUT"; rm -rf "$TMPD"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }
skip() { echo "   ⏭️  $1"; }

# run_guard <expected-exit> <label> [args...] — the ambient environment is inherited.
run_guard() {
  local expected="$1" label="$2"; shift 2
  bash "$GUARD" "$@" >"$OUT" 2>&1
  local rc=$?
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label: expected exit $expected, got $rc"
    sed 's/^/      /' "$OUT"
  fi
  return 0
}

# env_guard <expected-exit> <label> <VAR=VAL> [args...] — ONE variable for ONE run, so no arm can
# leak an interpreter into the next one.
env_guard() {
  local expected="$1" label="$2" assignment="$3"; shift 3
  env "$assignment" bash "$GUARD" "$@" >"$OUT" 2>&1
  local rc=$?
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label: expected exit $expected, got $rc"
    sed 's/^/      /' "$OUT"
  fi
  return 0
}

expect_out() {
  if grep -qF -- "$1" "$OUT"; then pass "   ↳ names: $1"; else fail "   ↳ output does NOT name '$1'"; sed 's/^/      /' "$OUT"; fi
}
expect_not_out() {
  if grep -qF -- "$1" "$OUT"; then fail "   ↳ output wrongly names '$1'"; sed 's/^/      /' "$OUT"; else pass "   ↳ does not name: $1"; fi
}

echo "── 1. the live tree: every shipped script parses under bash 3.2 ──────────────────────"
# The whole point: this failed on `main` at #2930 (merge-reminder.test.sh line 2629).
run_guard 0 "the repo's own shipped scripts parse under bash 3.2"
if grep -q 'script(s) parse under GNU bash' "$OUT"; then
  pass "   ↳ the success line states WHICH interpreter measured: $(grep -oE '\((native|docker):[^)]*\)' "$OUT" | head -1)"
else
  fail "   ↳ the success line does not say which interpreter measured it"
  sed 's/^/      /' "$OUT"
fi
if grep -q 'parse under GNU bash 3\.' "$OUT"; then
  pass "   ↳ it really was a 3.x parser"
else
  fail "   ↳ the interpreter was not a 3.x bash"
  sed 's/^/      /' "$OUT"
fi
# Which half of the gate this host drives — decided from the gate's OWN report, never re-derived here
# (a second copy of the resolution is a second thing that can disagree).
MODE=native
grep -q '(docker:' "$OUT" && MODE=docker

echo "── 2. the defect class: a here-doc body inside a \$( ), one per character class ──────"
for fx in heredoc-quote-in-body.sh heredoc-paren-in-body.sh heredoc-backtick-in-body.sh; do
  run_guard 1 "$fx is REFUSED" "$FIXREL/$fx"
  expect_out "$FIXREL/$fx"
done

echo "── 3. the remedy is accepted, and only the broken file is named ───────────────────────"
run_guard 0 "the function-wrapped form is accepted" "$FIXREL/clean-function-wrapped.sh"
if grep -q '1 script(s) parse' "$OUT"; then pass "   ↳ it counted the file it read"; else fail "   ↳ it did not count the file it read"; sed 's/^/      /' "$OUT"; fi
run_guard 1 "a clean+broken pair is refused" \
  "$FIXREL/clean-function-wrapped.sh" "$FIXREL/heredoc-quote-in-body.sh"
expect_out "heredoc-quote-in-body.sh"
expect_not_out "clean-function-wrapped.sh"

echo "── 4. NON-VACUITY: the fixtures are 3.2-SPECIFIC, not malformed ──────────────────────"
# Each fixture must parse clean on this host's bash. If one were merely malformed, arms 2/3 would
# prove nothing about the platform — this arm is what makes them evidence.
host_major="$("$BASH" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null)"
if [ "$host_major" = "3" ]; then
  skip "this host's bash is 3.x, so the fixtures cannot be shown clean under a NEWER parser here (CI's bash 5 arm covers it)"
else
  bad=0; nfx=0
  for fx in "$FIXDIR"/*.sh; do
    nfx=$((nfx + 1))
    if ! "$BASH" -n "$fx" 2>/dev/null; then
      bad=$((bad + 1))
      fail "$(basename "$fx") does not parse even under bash $host_major — it is malformed, not a 3.2-only shape"
    fi
  done
  [ "$bad" -eq 0 ] && pass "all $nfx fixtures parse under this host's bash $host_major — so the refusals above are the PLATFORM difference"
fi

echo "── 5. fail-closed: 'cannot measure' is never 'passed' ───────────────────────────────"
env_guard 2 "a BASH32 that does not exist is refused" "BASH32=/nonexistent/bash-3.2" "$FIXREL/clean-function-wrapped.sh"
expect_out "not an executable"
# A fake bash 5.x: it answers the gate's version probe and nothing else.
SHIM="$TMPD/bash5"
printf '#!/bin/bash\nif [ "$1" = "-c" ]; then printf 5; exit 0; fi\nexit 1\n' >"$SHIM"; chmod +x "$SHIM"
env_guard 2 "a BASH32 that is NOT 3.x is refused (a 5.x parser would be a false PASS)" "BASH32=$SHIM" "$FIXREL/clean-function-wrapped.sh"
expect_out "not 3"
mkdir -p "$TMPD/empty"
env_guard 2 "an EMPTY population is refused (no vacuous green)" "CHECK_BASH32_ROOT=$TMPD/empty"
expect_out "no *.sh"

echo "── 6. the platform is PINNED, not inherited from a mutable tag ───────────────────────"
if grep -qE 'IMAGE="\$\{BASH32_IMAGE:-bash:3\.2@sha256:[0-9a-f]{64}\}"' "$GUARD"; then
  pass "the default image is pinned by digest"
else
  fail "the default image is NOT digest-pinned — a retargeted tag would measure the wrong platform"
fi
if grep -q 'BASH_VERSINFO\[0\]}" != "3"' "$GUARD"; then
  pass "the container half carries its own 3.x check"
else
  fail "the container half has no version check — an override could run bash 5 and report OK"
fi

echo "── 7. mutations: the pins are load-bearing ──────────────────────────────────────────"
# mutant <needle> <replacement> <label> <expected-exit-of-the-mutant> [args...]
# The substitution must land EXACTLY once: a gate whose text moved would silently measure something
# else, and an unapplied mutation is an arm that reads green while proving nothing.
mutant() {
  local needle="$1" repl="$2" label="$3" want="$4"; shift 4
  local copy="$TMPD/mutant$(printf '%s' "$label" | cksum | cut -d' ' -f1).sh"
  if ! NEEDLE="$needle" REPL="$repl" python3 - "$GUARD" "$copy" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
n = s.count(os.environ["NEEDLE"])
if n != 1:
    sys.stderr.write(f"mutation site appears {n} time(s), expected exactly 1\n")
    raise SystemExit(1)
open(sys.argv[2], "w").write(s.replace(os.environ["NEEDLE"], os.environ["REPL"]))
PY
  then
    fail "$label: the mutation could not be applied (the gate's text moved) — the arm is NOT evidence"
    return 0
  fi
  chmod +x "$copy"
  bash "$copy" "$@" >"$OUT" 2>&1
  local rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label (mutant exit $rc)"
  else
    fail "$label: the mutant exited $rc, expected $want — the arm it should defeat is NOT live"
    sed 's/^/      /' "$OUT"
  fi
  return 0
}

if [ "$MODE" = "docker" ]; then
  mutant 'if ! out="$(cd /repo && bash -n "$rel" 2>&1)"; then' 'if false; then' \
    "M1 container: removing the parse-failure branch makes a broken file read green" 0 \
    "$FIXREL/heredoc-quote-in-body.sh"
else
  mutant 'if ! out="$("$NATIVE" -n "$f" 2>&1)"; then' 'if false; then' \
    "M1 native: removing the parse-failure branch makes a broken file read green" 0 \
    "$FIXREL/heredoc-quote-in-body.sh"
fi
# M2: with the version guard gone, a 5.x interpreter is accepted instead of refused. The shim is not a
# real bash, so the mutant reaches the parse loop and fails there (exit 1) — the point is that it no
# longer REFUSES (exit 2) with the version message, i.e. the guard was the thing doing the work.
env_guard 2 "M2 control: the real gate refuses a 5.x BASH32" "BASH32=$SHIM" "$FIXREL/clean-function-wrapped.sh"
MUT="$TMPD/mutant-m2.sh"
if NEEDLE='[ "$major" = "3" ] || die' REPL=': || die' python3 - "$GUARD" "$MUT" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
n = s.count(os.environ["NEEDLE"])
if n != 1:
    sys.stderr.write(f"mutation site appears {n} time(s), expected exactly 1\n")
    raise SystemExit(1)
open(sys.argv[2], "w").write(s.replace(os.environ["NEEDLE"], os.environ["REPL"]))
PY
then
  chmod +x "$MUT"
  env BASH32="$SHIM" bash "$MUT" "$FIXREL/clean-function-wrapped.sh" >"$OUT" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'not 3' "$OUT"; then
    fail "M2: the mutant STILL refuses a 5.x BASH32 — the guard mutation defeated nothing"
  else
    pass "M2: removing the interpreter-version guard drops the 5.x refusal (mutant exit $rc, no version message)"
  fi
else
  fail "M2: the mutation could not be applied (the gate's text moved) — the arm is NOT evidence"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "✅ All bash32-parse tests passed"
  exit 0
fi
echo "❌ $failures bash32-parse test(s) failed"
exit 1
