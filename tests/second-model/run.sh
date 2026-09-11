#!/bin/bash
# tests/second-model/run.sh — #716 second-model gate tests.
#
# Exercises scripts/check-second-model.sh semantics:
#   1. clean fixture → PASS (exit 0); `--print` resolves `moonshot/kimi-k3`
#   2. backdoor-same-build (`deepseek/deepseek-v4-pro`)     → BLOCK (exit 1)
#   3. backdoor-false-pass (`deepseek-flash`, provider-less) → BLOCK (exit 1)
#      — the canonical #716 false pass a naive id/family check misses
#   4. backdoor-unreachable (probe: 429/403 + error bodies)  → DEGRADED (exit 1)
#   5. backdoor-unreachable-soft (HTTP 200 + insufficient balance) → DEGRADED
#      — solvency, not mere reachability (the scoping-review P0)
#   6. missing-config (no authority file)                    → fail closed (exit 2)
#   7. override-env ($SECOND_MODEL = a DeepSeek id)          → exit 0 + WARN
#   8. escape-hatch (SECOND_MODEL_GATE_OVERRIDE=1)           → exit 0 + loud notice
#   9. --shipped-only with no live dir                       → exit 0, no network
#  10. docs-parity: no stale `deepseek/deepseek-v4-pro` DEFAULT literal and no
#      `stand-in` / `tool default` prose in the 4 skills / AGENTS.md / base
#      template / providers doc; AGENTS.md ≡ base template paragraph
#  11. missing-runtimeVia                                     → fail closed (exit 2)
#  12. check (f) simulation (pipeline-compliance)            → pass/fail cases
#  13. non-vacuity: a genuinely non-DeepSeek, non-equivalent id passes
#      (`openrouter/google/gemini-2.5-pro`) while the DeepSeek positives fail;
#      an emptied equivalence set fails the primary self-check (exit 2)
#  14. clean fixture mirrors the shipped config; each backdoor tree differs from
#      clean only in its one documented defect (bounded delta)
#
# Hermetic: ZERO network. Probe results are injected with `--probe-fixture`
# (never a real HTTP call). The clobber preflight mirrors tests/cost-config.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-second-model.sh"
FIX="$ROOT/tests/fixtures/second-model"
SHIPPED="$ROOT/pi-bootstrap/pi-config/second-model.json"
OUT="$(mktemp /tmp/second-model-out.XXXXXX)"
failures=0

if ! git -C "$ROOT" diff --quiet -- tests/fixtures/second-model; then
  echo "❌ tests/fixtures/second-model has uncommitted modifications — commit them first."
  exit 1
fi

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# run_guard <expected-exit> <label> [args...]
run_guard() {
  local expected="$1"; shift
  local label="$1"; shift
  bash "$GUARD" "$@" >"$OUT" 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,60p' "$OUT"
  fi
}

echo "== second-model gate tests (#716) =="
echo ""

echo "0. Fixture JSON validity"
for f in "$FIX"/*/*.json; do
  python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null || fail "invalid JSON: $f"
done
pass "all fixture JSON files parse"

echo ""
echo "1. clean fixture → PASS (exit 0)"
run_guard 0 "clean fixture" --check --live-dir "$FIX/clean"
grep -q "second-model gate: PASS" "$OUT" && pass "summary PASS" || { fail "expected PASS summary"; tail -20 "$OUT"; }
if grep -q "⚠️  second-model gate: PASS with" "$OUT"; then pass "PASS accepts the external-authority warning"; fi
bash "$GUARD" --print --live-dir "$FIX/clean" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ] && [ "$(cat "$OUT")" = "moonshot/kimi-k3" ]; then
  pass "--print resolves the first preference candidate (moonshot/kimi-k3)"
else
  fail "--print — expected exit 0 + moonshot/kimi-k3, got exit $code / '$(cat "$OUT")'"
fi

echo ""
echo "2. backdoor-same-build (deepseek/deepseek-v4-pro) → BLOCK, exit 1"
run_guard 1 "backdoor-same-build" --check --live-dir "$FIX/backdoor-same-build"
grep -q "SAME served build as the primary" "$OUT" && pass "build-equivalent BLOCK reported" || { fail "expected same-build BLOCK"; tail -25 "$OUT"; }
grep -q "BLOCK-level violation" "$OUT" && pass "BLOCK summary present" || { fail "expected BLOCK summary"; tail -20 "$OUT"; }

echo ""
echo "3. backdoor-false-pass (provider-less deepseek-flash) → BLOCK, exit 1"
run_guard 1 "backdoor-false-pass" --check --live-dir "$FIX/backdoor-false-pass"
grep -q "SAME served build as the primary" "$OUT" && pass "#716 false pass caught" || { fail "the deepseek-flash false pass was NOT caught"; tail -25 "$OUT"; }
grep -q "deepseek-flash" "$OUT" && pass "offending id named in the BLOCK" || fail "offending id not named"

echo ""
echo "4. backdoor-unreachable (429/403 + error bodies) → DEGRADED, exit 1"
run_guard 1 "backdoor-unreachable" --check --live-dir "$FIX/backdoor-unreachable" --probe-fixture "$FIX/backdoor-unreachable/probe.json"
grep -q "DEGRADED" "$OUT" && pass "DEGRADED fail-closed" || { fail "expected DEGRADED"; tail -25 "$OUT"; }
grep -q "insufficient balance" "$OUT" && pass "kimi suspension classified unreachable" || fail "kimi suspension not classified"
grep -q "key limit exceeded" "$OUT" && pass "openrouter key cap classified unreachable" || fail "openrouter key cap not classified"

echo ""
echo "5. backdoor-unreachable-soft (HTTP 200 + error body) → DEGRADED, exit 1"
run_guard 1 "backdoor-unreachable-soft" --check --live-dir "$FIX/backdoor-unreachable-soft" --probe-fixture "$FIX/backdoor-unreachable-soft/probe.json"
grep -q "DEGRADED" "$OUT" && pass "DEGRADED on a JSON-200 error body" || { fail "expected DEGRADED on 200+error body"; tail -25 "$OUT"; }
grep -q "JSON-200 error bodies count" "$OUT" && pass "classifier explicitly counts 200-with-error as UNREACHABLE" || fail "200-body classification message missing"
grep -q "no response" "$OUT" && fail "a 200 response was misread as no-response" || pass "200 response was not misread as no-response"

echo ""
echo "6. missing-config (no authority file) → fail closed, exit 2"
run_guard 2 "missing-config" --check --live-dir "$FIX/missing-config"
grep -q "fail-closed" "$OUT" && pass "fail-closed message present" || { fail "expected fail-closed message"; tail -20 "$OUT"; }

echo ""
echo '7. override-env ($SECOND_MODEL = a DeepSeek id) → exit 0 + WARN'
SECOND_MODEL=deepseek/deepseek-v4-pro bash "$GUARD" --check --live-dir "$FIX/clean" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "override → exit 0 (operator-override-open-by-design)"; else fail "expected exit 0, got $code"; tail -20 "$OUT"; fi
grep -q "operator override active" "$OUT" && pass "override WARNed" || fail "override warning missing"
grep -q "NOT what a gate would dispatch" "$OUT" && pass "override names the config-vs-dispatch gap" || fail "override message incomplete"
SECOND_MODEL=deepseek/deepseek-v4-pro bash "$GUARD" --print --live-dir "$FIX/clean" >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = "deepseek/deepseek-v4-pro" ]; then pass "--print honours the override"; else fail "--print did not honour the override ('$(cat "$OUT")')"; fi

echo ""
echo "8. SECOND_MODEL_GATE_OVERRIDE=1 silences the BLOCK (escape hatch)"
SECOND_MODEL_GATE_OVERRIDE=1 bash "$GUARD" --check --live-dir "$FIX/backdoor-same-build" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "override → exit 0"; else fail "expected exit 0, got $code"; tail -20 "$OUT"; fi
grep -q "SECOND_MODEL_GATE_OVERRIDE=1" "$OUT" && pass "loud override notice present" || fail "override notice missing"
grep -q "SAME served build as the primary" "$OUT" && pass "violation still DETECTED under the override" || fail "violation not detected under the override"

echo ""
echo "9. --shipped-only runs offline (no live dir, no network)"
run_guard 0 "--shipped-only" --check --shipped-only
grep -q "probe skipped — offline" "$OUT" && pass "probe skipped (offline)" || { fail "expected offline skip notice"; tail -10 "$OUT"; }
grep -q "second-model gate: PASS" "$OUT" && pass "shipped-only PASS" || { fail "expected PASS"; tail -15 "$OUT"; }
# Hermetic probe path (fixture, not network): the solvent candidate resolves.
run_guard 0 "probe --probe-fixture" --probe --live-dir "$FIX/probe-kimi-solvent" --probe-fixture "$FIX/probe-kimi-solvent/probe.json"
grep -q "RESOLVED=moonshot/kimi-k3" "$OUT" && pass "hermetic probe resolves the first solvent candidate" || { fail "expected RESOLVED=moonshot/kimi-k3"; tail -15 "$OUT"; }
bash "$GUARD" --print --live-dir "$FIX/probe-kimi-solvent" --probe-fixture "$FIX/probe-kimi-solvent/probe.json" >"$OUT" 2>&1
[ "$(cat "$OUT")" = "moonshot/kimi-k3" ] && pass "--print with probe data resolves kimi" || fail "--print probe resolution got '$(cat "$OUT")'"

echo ""
echo "10. docs-parity: no stale default literal, no stand-in/tool-default prose"
hits="$(grep -rn 'deepseek/deepseek-v4-pro' "$ROOT/skills" "$ROOT/AGENTS.md" "$ROOT/templates" "$ROOT/docs/providers.md" 2>/dev/null || true)"
if [ -z "$hits" ]; then pass "0 default-literal hits"; else fail "stale default literal survives:"; printf '%s\n' "$hits"; fi
hits="$(grep -rnE 'stand-in|tool default' "$ROOT/skills/code-review/SKILL.md" "$ROOT/skills/issue-scoping/SKILL.md" "$ROOT/skills/plan-review/SKILL.md" "$ROOT/skills/subagent-driven-development/SKILL.md" 2>/dev/null || true)"
if [ -z "$hits" ]; then pass "0 stand-in/tool-default prose hits"; else fail "stand-in/tool-default prose survives:"; printf '%s\n' "$hits"; fi
python3 - "$ROOT/AGENTS.md" "$ROOT/templates/AGENTS.base.md" <<'PY'
import re, sys
def para(p):
    txt = open(p).read()
    m = re.search(r'\*\*Second-model gate exception.*?(?=\n\n)', txt, re.S)
    return m.group(0).strip() if m else ""
a, b = para(sys.argv[1]), para(sys.argv[2])
sys.exit(0 if a and a == b else 1)
PY
if [ $? -eq 0 ]; then pass "AGENTS.md ≡ templates/AGENTS.base.md second-model paragraph"; else fail "second-model paragraph drifted from the base template"; fi

echo ""
echo "11. missing-runtimeVia → fail closed, exit 2"
run_guard 2 "missing-runtimeVia" --check --live-dir "$FIX/missing-runtimeVia"
grep -q "runtimeVia" "$OUT" && pass "undeclared dispatch authority named" || { fail "expected runtimeVia message"; tail -20 "$OUT"; }
grep -q "fail-closed exit 2" "$OUT" && pass "fail-closed exit-2 summary" || { fail "expected exit-2 summary"; tail -20 "$OUT"; }

echo ""
echo "12. check (f) simulation (pipeline-compliance)"
PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 GH_REPO=daniel-ospina/agent-infra \
  bash "$ROOT/scripts/check-pipeline-compliance.sh" 999999 >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "simulation ran (exit 1 by design)"; else fail "simulation expected exit 1, got $code"; fi
for marker in \
  "pass 6: check (f) passed" \
  "pass 6b: check (f) blocked DEGRADED" \
  "pass 6c: check (f) blocked independent=NO" \
  "pass 6d: check (f) blocked a build-equivalent recorded id" \
  "pass 6e: check (f) blocked a missing marker" \
  "pass 6f: check (f) bootstrap exemption WARN" \
  "pass 6g: check (f) enforcement on once the file exists on base"; do
  grep -q "$marker" "$OUT" && pass "$marker" || { fail "missing simulation marker: $marker"; tail -5 "$OUT"; }
done

echo ""
echo "13. Non-vacuity: equivalence is build identity, not 'is it DeepSeek'"
# Positive controls (must classify EQUIVALENT, exit 0).
for m in deepseek-flash deepseek/deepseek-v4-pro openrouter/deepseek/deepseek-v4-pro deepseek-v4.1-flash-expires-on-0910; do
  bash "$GUARD" --equivalence "$m" >"$OUT" 2>&1
  if [ $? -eq 0 ] && grep -q "^EQUIVALENT" "$OUT"; then pass "positive control $m → EQUIVALENT"; else fail "positive control $m was not classified equivalent"; fi
done
# Genuinely non-DeepSeek / non-equivalent controls (must classify INDEPENDENT, exit 1).
for m in openrouter/google/gemini-2.5-pro moonshot/kimi-k3 openrouter/anthropic/claude-opus-4.8 deepseek-proxy deepseek-flashlight; do
  bash "$GUARD" --equivalence "$m" >"$OUT" 2>&1
  if [ $? -eq 1 ] && grep -q "^INDEPENDENT" "$OUT"; then pass "negative control $m → INDEPENDENT"; else fail "negative control $m was wrongly classified equivalent"; fi
done
# A whole fixture built on the negative control must PASS (proves the guard
# tests build equivalence, not membership in a DeepSeek allowlist).
run_guard 0 "near-miss-negative fixture" --check --live-dir "$FIX/near-miss-negative"
# An emptied equivalence set must fail the primary self-check (exit 2), not pass vacuously.
run_guard 2 "empty-equivalence fixture" --check --live-dir "$FIX/empty-equivalence"
grep -q "is empty — the guard cannot classify" "$OUT" && pass "emptied equivalence set fails closed" || fail "empty equivalence set not rejected"
# A NON-empty but misconfigured set (primary absent) must also fail closed via
# the primary self-check — the non-vacuity pin.
run_guard 2 "misconfigured-equivalence fixture" --check --live-dir "$FIX/misconfigured-equivalence"
grep -q "NOT in its own buildEquivalence set" "$OUT" && pass "non-vacuity self-check fires on a misconfigured mapping" || fail "self-check did not fire"

echo ""
echo "14. clean mirrors shipped + bounded per-fixture delta"
python3 - "$SHIPPED" "$FIX" <<'PY'
import json, os, sys
shipped, fix = sys.argv[1], sys.argv[2]
clean = json.load(open(os.path.join(fix, "clean", "second-model.json")))
fails = 0
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    return 0 if cond else 1
fails += check(json.load(open(shipped)) == clean,
               "clean fixture mirrors the shipped second-model.json")
SAME = {"clean", "backdoor-unreachable", "backdoor-unreachable-soft", "probe-kimi-solvent"}
for tree in ("backdoor-unreachable", "backdoor-unreachable-soft", "probe-kimi-solvent"):
    fails += check(json.load(open(os.path.join(fix, tree, "second-model.json"))) == clean,
                   f"{tree} second-model.json untouched (defect lives in its probe.json)")
for tree in ("backdoor-same-build", "backdoor-false-pass"):
    d = json.load(open(os.path.join(fix, tree, "second-model.json")))
    diff = json.dumps(d) != json.dumps(clean)
    only = d["preference"][0]["model"] != clean["preference"][0]["model"] and \
        d["preference"][1] == clean["preference"][1] and \
        d["primary"] == clean["primary"] and \
        d["unreachablePatterns"] == clean["unreachablePatterns"]
    fails += check(diff and only, f"{tree} differs from clean only in preference[0] (model + matching runtimeVia)")
d = json.load(open(os.path.join(fix, "missing-runtimeVia", "second-model.json")))
fails += check("runtimeVia" not in d["preference"][0] and
               d["preference"][1] == clean["preference"][1] and d["primary"] == clean["primary"],
               "missing-runtimeVia differs from clean only in the deleted runtimeVia")
d = json.load(open(os.path.join(fix, "near-miss-negative", "second-model.json")))
fails += check(d["preference"][0]["model"] == "openrouter/google/gemini-2.5-pro" and
               d["primary"] == clean["primary"],
               "near-miss-negative carries the non-DeepSeek control with an intact equivalence set")
d = json.load(open(os.path.join(fix, "empty-equivalence", "second-model.json")))
fails += check(d["primary"]["buildEquivalence"]["families"] == [] and
               d["primary"]["buildEquivalence"]["normalized"] == [] and
               d["preference"] == clean["preference"],
               "empty-equivalence differs from clean only in the emptied equivalence set")
d = json.load(open(os.path.join(fix, "misconfigured-equivalence", "second-model.json")))
fails += check(d["primary"]["buildEquivalence"]["families"] == [] and
               d["primary"]["buildEquivalence"]["normalized"] == ["some-unrelated-model-id"] and
               d["preference"] == clean["preference"],
               "misconfigured-equivalence differs from clean only in the equivalence set (primary absent)")
sys.exit(1 if fails else 0)
PY
py=$?
if grep -q "Traceback" "$OUT" 2>/dev/null; then fail "test 14 checker crashed"; fi
if [ "$py" -eq 0 ]; then pass "fixture invariants hold"; else fail "fixture invariant check failed (exit $py)"; fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All second-model gate tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
