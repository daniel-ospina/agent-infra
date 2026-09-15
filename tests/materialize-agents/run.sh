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
  hout="$( cd "$h" && git add -A >/dev/null 2>&1; env AGENT_INFRA_PATH="$h" bash scripts/check-agents-materialized.sh 2>&1 )"; hrc=$?
  if [ "$hrc" -eq 1 ] && grep -q 'STUB' <<<"$hout"; then
    pass "hook: missing required heading → STUB block (exit 1)"
  else
    fail "hook STUB expected (rc=$hrc)"; sed -n '1,8p' <<<"$hout"
  fi
  # drift (not a missing heading) → hook must not print a green 'passed'
  cp "$BASE" "$h/AGENTS.md"
  sed -i.bak 's/^## ⛔ DESIGN PRINCIPLE: Good > Easy$/## ⛔ DESIGN PRINCIPLE: Good > Cheap/' "$h/AGENTS.md"; rm -f "$h/AGENTS.md.bak"
  hout="$( cd "$h" && git add -A >/dev/null 2>&1; env AGENT_INFRA_PATH="$h" bash scripts/check-agents-materialized.sh 2>&1 )"; hrc=$?
  if [ "$hrc" -eq 0 ] && grep -q 'DRIFTED' <<<"$hout" && ! grep -q '✅ AGENTS.md materialization gate: passed' <<<"$hout"; then
    pass "hook: content drift → ⚠️ DRIFTED, no green 'passed' (exit 0)"
  else
    fail "hook drift expected (rc=$hrc)"; sed -n '1,8p' <<<"$hout"
  fi
else
  echo "   ⏭️  SKIP hook-level case: \`git init\` blocked locally (hub-state gate); runs in CI"
fi

# ── Real-repo regression pin: base is a line-subsequence of AGENTS.md ───────
cnt="$(diff "$BASE" "$ROOT/AGENTS.md" | grep -c '^<' || true)"
if [ "${cnt:-0}" -eq 0 ]; then
  pass "real-repo pin: every base line present in AGENTS.md, in order"
else
  fail "real-repo pin: ${cnt} base line(s) missing/modified in AGENTS.md"
  diff "$BASE" "$ROOT/AGENTS.md" | grep '^<' | sed -n '1,10p'
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
