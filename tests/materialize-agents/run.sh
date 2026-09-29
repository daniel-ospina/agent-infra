#!/bin/bash
# tests/materialize-agents/run.sh — #1027 suite for the AGENTS.md materialize gate.
#
# Covers the adversarial threat surface declared in #1027:
#   T1 required base heading absent            → exit 1
#   T2 base-owned paragraph deleted (heading survives) → drift reported, no plain ✅
#   T3 base-owned line modified                → drift reported
#   T4 repo-specific ADDITION                  → NOT drift (appended AND interleaved)
# plus the pipefail control, the marker-file path, the skip path, the hook-level
# case, the real-repo regression pin and the adversarial-anchor pin.
#
# Fixtures are self-contained: each gets its own copy of the materializer under
# <fixture>/scripts/ so the read-only template resolution (physical script
# location first) picks up the fixture's own templates/AGENTS.base.md.
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
MAT="$ROOT/scripts/materialize-agents.sh"
BASE="$ROOT/templates/AGENTS.base.md"
HOOK="$ROOT/scripts/check-agents-materialized.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# new_fixture <name> [--no-base]: make a dir with scripts/materialize-agents.sh
# and (unless --no-base) templates/AGENTS.base.md + AGENTS.md copied from the base.
new_fixture() {
  local d="$TMP/$1"; shift
  mkdir -p "$d/scripts"
  cp "$MAT" "$d/scripts/materialize-agents.sh"
  if [ "${1:-}" != "--no-base" ]; then
    mkdir -p "$d/templates"
    cp "$BASE" "$d/templates/AGENTS.base.md"
    cp "$BASE" "$d/AGENTS.md"
  else
    : > "$d/AGENTS.md"
  fi
  printf '%s' "$d"
}

# run_check <fixture-dir> [extra env...]: run the fixture's materializer --check.
run_check() {
  local d="$1"; shift
  ( cd "$d" && env "$@" bash "$d/scripts/materialize-agents.sh" --check "$d" 2>&1 )
}

echo "== materialize-agents suite (#1027) =="

# ── T1a: a required heading (`#### Hard Cap`) absent → exit 1 ───────────────
d="$(new_fixture t1a)"
grep -v '^#### Hard Cap$' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'MISSING: #### Hard Cap' <<<"$out"; then
  pass "T1a missing '#### Hard Cap' → exit 1"
else
  fail "T1a expected exit 1 + MISSING line (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── T1b: another required heading absent → exit 1 ───────────────────────────
d="$(new_fixture t1b)"
grep -v '^## Research Discipline$' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'MISSING: Research Discipline' <<<"$out"; then
  pass "T1b missing 'Research Discipline' → exit 1"
else
  fail "T1b expected exit 1 + MISSING line (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── T2: base-owned paragraph deleted, heading survives → drift, no plain ✅ ──
d="$(new_fixture t2)"
awk '/^#### Hard Cap$/{print; insec=1; next} insec && /^This is a \*\*runaway guard/{insec=0} !insec' "$BASE" > "$d/AGENTS.md"
# fallback if the awk pattern missed: drop the run-guard paragraph by line count
if cmp -s "$d/AGENTS.md" "$BASE"; then
  n=$(grep -n '^This is a \*\*runaway guard' "$BASE" | cut -d: -f1)
  sed "${n}d" "$BASE" > "$d/AGENTS.md"
fi
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$out" && ! grep -q '^✅ ' <<<"$out"; then
  pass "T2 base-owned paragraph deleted → drift, no plain ✅ (exit 0)"
else
  fail "T2 expected drift + no ✅ (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── T3: a base-owned line modified → drift ──────────────────────────────────
d="$(new_fixture t3)"
sed 's/^## ⛔ DESIGN PRINCIPLE: Good > Easy$/## ⛔ DESIGN PRINCIPLE: Good > Cheap/' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$out"; then
  pass "T3 base line modified → drift (exit 0)"
else
  fail "T3 expected drift (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── T4a: extra section appended → NOT drift (clean, compare ran) ─────────────
d="$(new_fixture t4a)"
{ cat "$BASE"; echo; echo '<!-- REPO-SPECIFIC (test): appended -->'; echo '## Repo Extra'; echo; echo 'content'; } > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'all base lines present in order' <<<"$out" && ! grep -q 'DRIFTED' <<<"$out"; then
  pass "T4a appended extra → clean (exit 0)"
else
  fail "T4a expected clean (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── T4b: extra block spliced BETWEEN two base lines → NOT drift ─────────────
d="$(new_fixture t4b)"
awk '/^## ⛔ HARD RULE: Process Discipline$/{print "<!-- REPO-SPECIFIC (test): interleaved -->"; print "## Interleaved Extra"; print ""; print "spliced content"; print ""} {print}' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'all base lines present in order' <<<"$out" && ! grep -q 'DRIFTED' <<<"$out"; then
  pass "T4b interleaved extra → clean (exit 0)"
else
  fail "T4b expected clean (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Reorder control: two base lines swapped → drift ─────────────────────────
d="$(new_fixture reorder)"
awk 'NR==1{a=$0} NR==2{print; print a; next} NR>2{print}' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$out"; then
  pass "reorder → drift (exit 0)"
else
  fail "reorder expected drift (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Identical files → clean; pipefail control (counter must not abort) ──────
d="$(new_fixture identical)"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'all base lines present in order' <<<"$out"; then
  pass "identical files → clean (pipefail control, exit 0)"
else
  fail "identical expected clean (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Positive control: one base line removed → drift (counter is not vacuous) ─
d="$(new_fixture positive)"
sed '3d' "$BASE" > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$out"; then
  pass "positive control (one base line removed) → drift"
else
  fail "positive control expected drift (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Marker-file path: head matches → clean; head modified → drift ───────────
d="$(new_fixture markerfile)"
{ cat "$BASE"; echo; echo '<!-- AGENTS-BASE-END -->'; echo; echo '## Repo Tail'; echo; echo 'tail'; } > "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'base head matches' <<<"$out"; then
  pass "marker file, head matches → clean"
else
  fail "marker-file clean expected (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi
sed 's/^## ⛔ DESIGN PRINCIPLE: Good > Easy$/## ⛔ DESIGN PRINCIPLE: Good > Cheap/' "$d/AGENTS.md" > "$d/AGENTS.md.tmp" && mv "$d/AGENTS.md.tmp" "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$out" && ! grep -q '^✅ ' <<<"$out"; then
  pass "marker file, head modified → drift, no plain ✅"
else
  fail "marker-file drift expected (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Skip path: template unresolvable → compare skipped, exit 0 ──────────────
d="$(new_fixture skip --no-base)"
cp "$BASE" "$d/AGENTS.md"   # content is fine, but there is no template to compare against
out="$(run_check "$d" AGENT_INFRA_PATH=)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'content compare skipped' <<<"$out"; then
  pass "unresolvable template → compare skipped, exit 0"
else
  fail "skip path expected (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Real-dir consumer with AGENT_INFRA_PATH set → compare runs via fallback ──
d="$(new_fixture envfallback --no-base)"
cp "$BASE" "$d/AGENTS.md"
out="$(run_check "$d" "AGENT_INFRA_PATH=$ROOT")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'all base lines present in order' <<<"$out"; then
  pass "AGENT_INFRA_PATH fallback resolves the template → clean"
else
  fail "env fallback expected clean (rc=$rc)"; sed -n '1,6p' <<<"$out"
fi

# ── Hook-level: drift is surfaced as ⚠️, never a green 'passed' ─────────────
# `git init` is blocked by the local hub-state gate; print a visible SKIP in that
# case (the case runs in CI, where git works).
GITOK=0
if ( cd "$TMP" && git init -q hookrepo 2>/dev/null ); then GITOK=1; fi
if [ "$GITOK" -eq 1 ]; then
  h="$TMP/hookrepo"
  mkdir -p "$h/templates" "$h/scripts"
  cp "$BASE" "$h/templates/AGENTS.base.md"
  cp "$HOOK" "$h/scripts/check-agents-materialized.sh"
  cp "$MAT" "$h/scripts/materialize-agents.sh"
  grep -v '^#### Hard Cap$' "$BASE" > "$h/AGENTS.md"
  hout="$( cd "$h" && git add AGENTS.md >/dev/null 2>&1; env AGENT_INFRA_PATH="$h" bash scripts/check-agents-materialized.sh 2>&1 )"; hrc=$?
  if [ "$hrc" -eq 1 ] && grep -q 'STUB' <<<"$hout"; then
    pass "hook: missing required heading → STUB block (exit 1)"
  else
    fail "hook STUB expected (rc=$hrc)"; sed -n '1,8p' <<<"$hout"
  fi
  # drift (not a missing heading) → hook must not print a green 'passed'
  cp "$BASE" "$h/AGENTS.md"
  sed -i.bak 's/^## ⛔ DESIGN PRINCIPLE: Good > Easy$/## ⛔ DESIGN PRINCIPLE: Good > Cheap/' "$h/AGENTS.md"; rm -f "$h/AGENTS.md.bak"
  hout="$( cd "$h" && git add AGENTS.md >/dev/null 2>&1; env AGENT_INFRA_PATH="$h" bash scripts/check-agents-materialized.sh 2>&1 )"; hrc=$?
  if [ "$hrc" -eq 0 ] && grep -q 'DRIFTED' <<<"$hout" && ! grep -q '✅ AGENTS.md materialization gate: passed' <<<"$hout"; then
    pass "hook: content drift → ⚠️ DRIFTED, no green 'passed' (exit 0)"
  else
    fail "hook drift expected (rc=$hrc)"; sed -n '1,8p' <<<"$hout"
  fi
  # the hook's SKIP branch (no resolvable template) must not print a bare green
  h2="$TMP/hookskip"; mkdir -p "$h2/scripts"
  cp "$HOOK" "$h2/scripts/check-agents-materialized.sh"
  cp "$MAT" "$h2/scripts/materialize-agents.sh"
  cp "$BASE" "$h2/AGENTS.md"
  hout="$( cd "$h2" && git init -q . >/dev/null 2>&1; git add AGENTS.md >/dev/null 2>&1; env AGENT_INFRA_PATH= bash scripts/check-agents-materialized.sh 2>&1 )"; hrc=$?
  if [ "$hrc" -eq 0 ] && grep -q 'HEADINGS ONLY' <<<"$hout" && ! grep -q '✅ AGENTS.md materialization gate: passed' <<<"$hout"; then
    pass "hook: comparison skipped → 'HEADINGS ONLY', no green 'passed' (exit 0)"
  else
    fail "hook skip expected (rc=$hrc)"; sed -n '1,8p' <<<"$hout"
  fi
else
  echo "   ⏭️  SKIP hook-level case: \`git init\` blocked locally (hub-state gate); runs in CI"
fi

# ── NUL/binary-mode control (#1027 adversarial review): a NUL byte made GNU
# diff switch to binary mode and emit zero `^<` lines, so a file with base-owned
# content deleted printed the CLEAN line. The compare now passes `--text`; this
# case fails without that flag.
d="$(new_fixture nulbyte)"
python3 -c "
import sys
ls = open(sys.argv[1], 'rb').read().split(b'\n')
del ls[20:30]
open(sys.argv[2], 'wb').write(b'\x00' + b'\n'.join(ls))
" "$BASE" "$d/AGENTS.md"
out="$(run_check "$d")"; rc=$?
case "$out" in
  *'BASE-OWNED CONTENT DRIFTED'*)
    if [ "$rc" -eq 0 ] && ! grep -q '^✅ ' <<<"$out"; then
      pass "NUL/binary-mode file with base lines deleted → drift (not a clean ✅)"
    else
      fail "NUL case: drift reported but rc=$rc or a plain ✅ was printed"
    fi ;;
  *)
    fail "NUL case: binary-mode comparison degraded to a non-drift result (rc=$rc)"; sed -n '1,4p' <<<"$out" ;;
esac

# ── Required-heading list ↔ base agreement. The materializer's list carries the
# claim "keep this list in sync with tests/materialize-agents/run.sh"; this is
# the assertion that makes it true. Without it a legitimate base REWORD passes
# agent-infra's own CI while every consumer's --check starts exiting 1 (STUB).
markers="$(sed -n '/for marker in/,/; do$/p' "$MAT" \
  | grep -v 'for marker in' \
  | sed -e 's/^[[:space:]]*//' -e 's/^"//' \
        -e 's/"[[:space:]]*\\\{0,1\}[[:space:]]*; do[[:space:]]*$//' \
        -e 's/"[[:space:]]*\\\{0,1\}[[:space:]]*$//')"
nmarkers="$(printf '%s\n' "$markers" | grep -c . || true)"
if [ "${nmarkers:-0}" -eq 9 ]; then
  pass "materializer declares exactly 9 required headings"
else
  fail "materializer declares ${nmarkers:-0} required headings (expected 9)"
fi
bad=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  grep -qF -- "$m" "$BASE" || { fail "required heading not present in the base: '$m'"; bad=1; }
done <<<"$markers"
# Gate the agreement line on the COUNT as well: if the extraction above yields
# nothing, `bad` stays 0 and this line would print a green "all 9 headings exist"
# for a check that examined no headings (found in review).
if [ "$bad" -eq 0 ] && [ "${nmarkers:-0}" -eq 9 ]; then
  pass "all 9 required headings exist verbatim in templates/AGENTS.base.md"
else
  fail "heading-vs-base agreement not established (${nmarkers:-0} markers extracted, bad=$bad)"
fi

# ── Hook skip path must state that the comparison did not run (#1027 review).
# NOTE: this asserts the MATERIALIZER's skip wording; the hook's own skip branch is
# asserted in the git-fixture block below (a case named for a branch it does not
# execute pins nothing — #991).
d="$(new_fixture mat-skip --no-base)"
cp "$BASE" "$d/AGENTS.md"
out="$(run_check "$d" AGENT_INFRA_PATH=)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'content compare skipped' <<<"$out"; then
  pass "materializer skip path states the comparison did not run (no bare green)"
else
  fail "materializer skip path: expected the explicit 'content compare skipped' wording (rc=$rc)"
fi

# ── Unreadable / empty base template must NOT read as clean (#1027 cycle 2).
# Both hand `diff` an empty left operand: it exits 1 with only `>` lines, so
# neither the rc-2 arm nor the no-`<>`-line arm fires and BASE_ONLY reads 0.
# Reproduced before the fix: a file with a base-owned line deleted printed the
# CLEAN line when the template was unreadable or empty.
for mode in unreadable empty; do
  d="$(new_fixture "tmpl-$mode")"
  grep -v '^When choosing between two approaches, prefer the one that produces' "$BASE" > "$d/AGENTS.md"
  if [ "$mode" = "unreadable" ]; then
    chmod 000 "$d/templates/AGENTS.base.md"
  else
    : > "$d/templates/AGENTS.base.md"
  fi
  out="$(run_check "$d")"; rc=$?
  chmod 644 "$d/templates/AGENTS.base.md" 2>/dev/null || true
  if [ "$rc" -eq 0 ] && grep -q 'compare could not run' <<<"$out" && ! grep -q 'all base lines present in order' <<<"$out"; then
    pass "$mode base template → compare could not run (not a clean ✅)"
  else
    fail "$mode base template: expected a degraded ⚠️, not the clean line (rc=$rc)"; sed -n '1,4p' <<<"$out"
  fi
done

# ── Real-repo regression pin: base is a line-subsequence of AGENTS.md.
# diff's own status is captured, so a `diff` internal failure (rc 2, e.g. an
# unreadable file) FAILS here instead of being swallowed into "no drift".
if DIFF_OUT=$(diff --text "$BASE" "$ROOT/AGENTS.md"); then
  drc=0
else
  drc=$?
fi
if [ "$drc" -eq 2 ]; then
  fail "real-repo pin: diff exited 2 (internal error) — cannot verify the pin"
else
  cnt="$(grep -c '^<' <<<"$DIFF_OUT" || true)"
  if [ "${cnt:-0}" -eq 0 ]; then
    pass "real-repo pin: every base line present in AGENTS.md, in order"
  else
    fail "real-repo pin: ${cnt} base line(s) missing/modified in AGENTS.md"
    grep '^<' <<<"$DIFF_OUT" | sed -n '1,10p'
  fi
fi

# ── Adversarial-anchor pin: exactly one anchor per AGENTS surface ───────────
for f in "$ROOT/AGENTS.md" "$BASE"; do
  n="$(grep -c 'adversarial-bound: cap=2' "$f" || true)"
  if [ "${n:-0}" -eq 1 ]; then pass "anchor ×1 in ${f#"$ROOT"/}"; else fail "anchor count ${n} in ${f#"$ROOT"/}"; fi
done

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ materialize-agents suite: all checks passed"
  exit 0
fi
echo "❌ materialize-agents suite: $failures failure(s)"
exit 1
