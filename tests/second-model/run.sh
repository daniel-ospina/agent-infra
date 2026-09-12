#!/bin/bash
# tests/second-model/run.sh — #716 second-model gate tests.
#
# Exercises scripts/check-second-model.sh semantics:
#   0. every fixture JSON parses; every fixture is canonically encoded
#      (ensure_ascii=False) so the bounded-delta claim is byte-visible
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
#      but an UNUSABLE AUTHORITY is never overridable (exit 2, D7)
#   9. --shipped-only selects the shipped file, and it actually differs from the
#      live default (D3); hermetic probe resolves the first solvent candidate
#  10. docs-parity: no stale `deepseek/deepseek-v4-pro` DEFAULT literal and no
#      `stand-in` / `tool default` prose in the 4 skills / AGENTS.md / base
#      template / providers doc; AGENTS.md ≡ base template paragraph; --help
#      carries the override-hatch text (A7)
#  11. missing-runtimeVia → fail closed (exit 2); missing/empty
#      `unreachablePatterns` → fail closed (exit 2, D1)
#  12. check (f) simulation (pipeline-compliance) → pass/fail/bootstrap cases,
#      including the C1 (unresolvable base), C2 (rename + newly guarded paths)
#      and C3 (laundering / boundary / head-binding) bypasses
#  12b. hermeticity: a corrupt or backdoor ambient $HOME config never leaks into
#      a pinned assertion (D2)
#  13. non-vacuity + the full normalization matrix (A3/D8); duplicate
#      preference entries WARN (D8)
#  14. clean fixture mirrors the shipped config; each backdoor tree differs from
#      clean in EXACTLY its documented leaf-path set (structural, D6)
#  15. large vendor catalogue is not truncation-blind: the needle is searched
#      across the whole streamed body (OpenRouter /models is >700KB and the
#      designated id sat past the old 50KB cap → spurious DEGRADED), with an
#      absent-needle negative control proving the search is non-vacuous.
#  16. probe security (B1): a hostile config cannot send a credential to a
#      config-chosen host; http:// is refused; an arbitrary authEnv is refused
#  17. mode/exit-code pins: --print (A4), --equivalence (A1), --probe
#      equivalence filter (A2) and override-first ordering (A5)
#
# Hermetic: ZERO network. `--check`/`--print`/`--equivalence` are offline by
# construction; the probe is exercised only through `--probe-fixture`
# (injected bodies) or `--allow-file-probe` (local files). No assertion reads
# the ambient `~/.pi/agent/second-model.json` — every authority is pinned with
# `--live-dir`/`--shipped-only` (D2). The clobber preflight mirrors
# tests/cost-config.
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

# Equivalence controls — ALWAYS pin `--live-dir "$FIX/clean"` so the ambient
# $HOME config is never consulted (D2).
equiv_rc() { # <id> → prints guard exit code
  bash "$GUARD" --equivalence "$1" --live-dir "$FIX/clean" >/dev/null 2>&1
  echo $?
}

echo "== second-model gate tests (#716) =="
echo ""

echo "0. Fixture JSON validity + canonical encoding"
for f in "$FIX"/*/*.json; do
  python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null || fail "invalid JSON: $f"
done
pass "all fixture JSON files parse"
python3 - "$FIX" <<'PY' || fail "a fixture is not canonically encoded (run the regenerate step with ensure_ascii=False)"
import json, os, sys
fix = sys.argv[1]
bad = []
for tree in sorted(os.listdir(fix)):
    p = os.path.join(fix, tree, "second-model.json")
    if not os.path.exists(p):
        continue
    raw = open(p).read()
    canon = json.dumps(json.loads(raw), ensure_ascii=False, indent=2) + "\n"
    if raw != canon:
        bad.append(p)
sys.exit(1 if bad else 0)
PY
pass "every fixture second-model.json is canonically encoded (no \\u-escaped em-dash)"

echo ""
echo "1. clean fixture → PASS (exit 0)"
run_guard 0 "clean fixture" --check --live-dir "$FIX/clean"
grep -q "second-model gate: PASS" "$OUT" && pass "summary PASS" || { fail "expected PASS summary"; tail -20 "$OUT"; }
if grep -q "⚠️  second-model gate: PASS with" "$OUT"; then pass "PASS accepts the external-authority warning"; else fail "expected the external-authority PASS cap"; fi
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
# A4: --print on an unusable authority is exit 2, not 0.
run_guard 2 "--print on a missing authority is exit 2 (A4)" --print --live-dir "$FIX/missing-config"

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
# D7 policy: the override silences BLOCKs only — never an unusable-authority
# fatal produced by validate() (the case the old ordering laundered).
SECOND_MODEL_GATE_OVERRIDE=1 bash "$GUARD" --check --live-dir "$FIX/missing-unreachablePatterns" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 2 ]; then pass "override does NOT silence a validate() fatal (exit 2, D7 policy)"; else fail "override laundered a validate() fatal — expected exit 2, got $code"; tail -20 "$OUT"; fi
SECOND_MODEL_GATE_OVERRIDE=1 bash "$GUARD" --check --live-dir "$FIX/missing-config" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 2 ]; then pass "override does NOT silence the missing-config fatal either (exit 2)"; else fail "override laundered the missing-config fatal — expected exit 2, got $code"; tail -20 "$OUT"; fi

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
echo "9b. --shipped-only selects the SHIPPED file, not the live one (D3)"
SHIP_HOME="$(mktemp -d /tmp/second-model-shipped.XXXXXX)"
mkdir -p "$SHIP_HOME/.pi/agent"
cp "$FIX/backdoor-same-build/second-model.json" "$SHIP_HOME/.pi/agent/second-model.json"
HOME="$SHIP_HOME" bash "$GUARD" --check --shipped-only >"$OUT" 2>&1; code=$?
[ "$code" -eq 0 ] && pass "--check --shipped-only ignores a backdoor live config (exit 0)" || { fail "expected 0, got $code"; tail -15 "$OUT"; }
HOME="$SHIP_HOME" bash "$GUARD" --check >"$OUT" 2>&1; code=$?
[ "$code" -eq 1 ] && pass "the default authority DOES read the live config (exit 1) — the flag has a real effect" || { fail "expected the live default to fail (1), got $code"; tail -15 "$OUT"; }
rm -rf "$SHIP_HOME"

echo ""
echo "9c. Consumer-tree symlink resolution + install path (E4/E8)"
# A consumer repo receives `scripts/` as a symlink back to agent-infra and does
# NOT carry pi-bootstrap/. The guard must still resolve the SHIPPED config via
# physical realpath; a logical `dirname $0/..` lands in the consumer and exits 2.
CONSUMER="$(mktemp -d /tmp/second-model-consumer.XXXXXX)"
ln -s "$ROOT/scripts" "$CONSUMER/scripts"
( cd "$CONSUMER" && bash scripts/check-second-model.sh --check --shipped-only ) >"$OUT" 2>&1; code=$?
[ "$code" -eq 0 ] && pass "the guard resolves its shipped config through a consumer scripts/ symlink (exit 0)" || { fail "consumer symlink misresolved the shipped config (exit $code)"; tail -15 "$OUT"; }
grep -q 'shipped config is not reachable' "$ROOT/.husky/pre-commit" && pass "the pre-commit hook gates on the shipped config (E8)" || fail "the hook does not gate on the shipped config"
if grep -q 'merge_gate_srcs=(record-review.sh)' "$ROOT/pi-bootstrap/setup.sh" \
   && ! grep -q 'merge_gate_srcs=.*check-second-model' "$ROOT/pi-bootstrap/setup.sh"; then
  pass "setup.sh does NOT farm the guard (G12: the farmed copy cannot run --check/--probe; \$AGENT_INFRA_PATH is the convention)"
else
  fail "setup.sh still farms check-second-model.sh — its \$HOME/.pi copy resolves ROOT=\$HOME/.pi and exits 2"
fi
( cd "$ROOT" && export AGENT_INFRA_PATH="$ROOT" && bash "$AGENT_INFRA_PATH/scripts/check-second-model.sh" --check --shipped-only ) >"$OUT" 2>&1; code=$?
[ "$code" -eq 0 ] && pass "the documented \$AGENT_INFRA_PATH invocation runs --check (G12)" || { fail "the documented invocation failed (exit $code)"; tail -10 "$OUT"; }
bad="$(grep -rn 'bash scripts/check-second-model.sh' "$ROOT/skills" "$ROOT/AGENTS.md" "$ROOT/templates/AGENTS.base.md" "$ROOT/docs/providers.md" 2>/dev/null || true)"
if [ -z "$bad" ]; then pass "no bare repo-relative guard invocation remains (E4)"; else fail "bare invocations remain:"; printf '%s\n' "$bad"; fi
rm -rf "$CONSUMER"

echo ""
echo "10. docs-parity: no stale default literal, no stand-in/tool-default prose"
hits="$(grep -rn 'deepseek/deepseek-v4-pro' "$ROOT/skills" "$ROOT/AGENTS.md" "$ROOT/templates" "$ROOT/docs/providers.md" 2>/dev/null || true)"
if [ -z "$hits" ]; then pass "0 default-literal hits"; else fail "stale default literal survives:"; printf '%s\n' "$hits"; fi
# D5: the absence grep covers ALL claimed paths, not just the four skills.
hits="$(grep -rnE 'stand-in|tool default' \
  "$ROOT/skills/code-review/SKILL.md" "$ROOT/skills/issue-scoping/SKILL.md" \
  "$ROOT/skills/plan-review/SKILL.md" "$ROOT/skills/subagent-driven-development/SKILL.md" \
  "$ROOT/AGENTS.md" "$ROOT/templates/AGENTS.base.md" "$ROOT/docs/providers.md" 2>/dev/null || true)"
if [ -z "$hits" ]; then pass "0 stand-in/tool-default prose hits (4 skills + AGENTS.md + base template + providers.md)"; else fail "stand-in/tool-default prose survives:"; printf '%s\n' "$hits"; fi
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
# A7: --help must carry the escape-hatch + operator-override header text.
bash "$GUARD" --help >"$OUT" 2>&1
grep -q "SECOND_MODEL_GATE_OVERRIDE" "$OUT" && pass "--help documents the escape hatch (A7)" || fail "--help dropped the escape-hatch paragraph"
grep -q '\$SECOND_MODEL' "$OUT" && pass "--help documents the operator override (A7)" || fail "--help dropped the operator-override paragraph"
grep -q -e '--allow-file-probe' "$OUT" && pass "--help documents the test-only file-probe flag" || fail "--help dropped the probe-security paragraph"
# E1/E2/docs: the fail-closed trigger names a non-zero probe exit (SDD), every
# gate skill tells the success path to record the marker, the escape hatch is
# documented, and the dated research record no longer pins the gate to V4-Pro.
grep -q 'or the probe exits non-zero' "$ROOT/skills/subagent-driven-development/SKILL.md" && pass "SDD fail-closed names the non-zero probe exit (E1)" || fail "SDD still literal-matches only **DEGRADED"
grep -q '\[#476 hop-leg\]' "$ROOT/skills/subagent-driven-development/SKILL.md" && pass "SDD carries the hop-leg stackability sentence (E1)" || fail "SDD lacks the hop-leg sentence"
for sk in code-review issue-scoping plan-review subagent-driven-development; do
  grep -q 'Success path — record the marker' "$ROOT/skills/$sk/SKILL.md" && pass "$sk documents the success-path marker (E2)" || fail "$sk does not document the success-path marker"
done
grep -q 'Escape hatch / rollback' "$ROOT/docs/providers.md" && pass "providers.md documents the escape hatch (E3)" || fail "providers.md does not document the escape hatch"
grep -q 'V4-Pro second-model gate' "$ROOT/docs/research/2026-09-05-local-qwen-32b-decision.md" && fail "the dated research record still pins the gate to V4-Pro (E6)" || pass "the dated research record points at the guard (E6)"
grep -qE 'parity gate    #' "$ROOT/.github/workflows/ci-main.yml" && fail "ci-main.yml still has the joined comment line (E7)" || pass "ci-main.yml comment lines are split (E7)"
# G13: ONE dispatch contract stated in the guard, providers.md, and all four skills.
grep -q 'Dispatch contract (ONE rule' "$ROOT/docs/providers.md" && pass "providers.md states the single dispatch contract (G13)" || fail "providers.md lacks the single dispatch contract"
for sk in code-review issue-scoping plan-review subagent-driven-development; do
  if grep -q 'liveness gate is the dispatch authority' "$ROOT/skills/$sk/SKILL.md"; then
    pass "$sk states the dispatch contract (G13)"
  else
    fail "$sk does not state the dispatch contract (G13)"
  fi
done
# G15: the success-path marker is documented in AGENTS.md and the base template.
for doc in "$ROOT/AGENTS.md" "$ROOT/templates/AGENTS.base.md"; do
  if grep -q 'Success path — record the marker' "$doc" && grep -q 'SECOND_MODEL_GATE_MODEL' "$doc" && grep -q 'independent=yes' "$doc"; then
    pass "$(basename "$doc") documents the success-path marker (G15)"
  else
    fail "$(basename "$doc") lacks the success-path marker instruction (G15)"
  fi
done
# G14: the merge_second_model() comment names the whole-file replacement trap.
grep -q 'WHOLE-FILE replace' "$ROOT/pi-bootstrap/setup.sh" && pass "merge_second_model comment names the wholesale-replace trap (G14)" || fail "merge_second_model comment still hides the drop"
grep -q 'operator top-up needs no' "$ROOT/pi-bootstrap/setup.sh" && fail "the misleading 'no code edit' claim survives (G14)" || pass "the misleading 'no code edit' claim is gone (G14)"
# G12: the farm rationale no longer claims the guard must run without the checkout.
grep -q 'second-model guard is NOT on' "$ROOT/pi-bootstrap/setup.sh" && pass "setup.sh explains why the guard is not farmed (G12)" || fail "setup.sh does not explain the farm removal"
# E5: no volatile vendor health facts are frozen into the shipped policy — the
# dated #716 funding comment holds the evidence; the file keeps only a pointer
# to it (re-adding a re-funded candidate must not first require deleting a stale
# "401"/"insolvent" claim).
vol="$(grep -nE 'HTTP 401|key revoked|insolvent|code 1113' "$SHIPPED" "$FIX/clean/second-model.json" 2>/dev/null || true)"
if [ -z "$vol" ]; then pass "shipped policy carries no volatile vendor health codes (E5)"; else fail "volatile vendor facts frozen into the shipped policy:"; printf '%s\n' "$vol"; fi

echo ""
echo "11. missing-runtimeVia → fail closed, exit 2"
run_guard 2 "missing-runtimeVia" --check --live-dir "$FIX/missing-runtimeVia"
grep -q "runtimeVia" "$OUT" && pass "undeclared dispatch authority named" || { fail "expected runtimeVia message"; tail -20 "$OUT"; }
grep -q "fail-closed exit 2" "$OUT" && pass "fail-closed exit-2 summary" || { fail "expected exit-2 summary"; tail -20 "$OUT"; }

echo ""
echo "11b. unreachablePatterns missing / empty → fail closed, exit 2 (D1)"
run_guard 2 "missing unreachablePatterns" --check --live-dir "$FIX/missing-unreachablePatterns"
grep -q "unreachablePatterns" "$OUT" && pass "missing key named" || { fail "expected unreachablePatterns message"; tail -20 "$OUT"; }
grep -q "fail-closed exit 2" "$OUT" && pass "missing key fails closed (exit 2)" || fail "missing key did not fail closed"
run_guard 2 "empty unreachablePatterns" --check --live-dir "$FIX/empty-unreachablePatterns"
grep -q "unreachablePatterns" "$OUT" && pass "empty array named" || { fail "expected unreachablePatterns message"; tail -20 "$OUT"; }
# The same fatal must gate --equivalence (A1: one shared validator).
run_guard 2 "--equivalence on a missing-patterns authority fails closed" \
  --equivalence deepseek/x --live-dir "$FIX/missing-unreachablePatterns"

echo ""
echo "12. check (f) simulation (pipeline-compliance)"
PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 GH_REPO=daniel-ospina/agent-infra \
  PIPELINE_SECOND_MODEL_LIVE_DIR="$ROOT/pi-bootstrap/pi-config" \
  bash "$ROOT/scripts/check-pipeline-compliance.sh" 999999 >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "simulation ran (exit 1 by design)"; else fail "simulation expected exit 1, got $code"; sed -n '1,40p' "$OUT"; fi
for marker in \
  "pass 6: check (f) passed" \
  "pass 6b: check (f) blocked DEGRADED" \
  "pass 6c: check (f) blocked independent=NO" \
  "pass 6d: check (f) blocked a build-equivalent recorded id" \
  "pass 6y: check (f) blocks the bare deepseek shorthand as independent=yes" \
  "pass 6e: check (f) blocked a missing marker" \
  "pass 6f: check (f) bootstrap exemption WARN" \
  "pass 6g: check (f) enforcement on once the file exists on base" \
  "pass 6h: check (f) FAILS on an unresolvable base" \
  "pass 6i: check (f) enforces across a rename OUT of the guarded surface" \
  "pass 6p-_github_workflows_pipeline-compliance_yml: check (f) enforces on a change to .github/workflows/pipeline-compliance.yml" \
  "pass 6p-pi-bootstrap_setup_sh: check (f) enforces on a change to pi-bootstrap/setup.sh" \
  "pass 6p-sync_sh: check (f) enforces on a change to sync.sh" \
  "pass 6p-pi-bootstrap_pi-config_models_json: check (f) enforces on a change to pi-bootstrap/pi-config/models.json" \
  "pass 6j: check (f) blocks a reserved model laundered as independent=yes" \
  "pass 6o: check (f) blocks the bare DEGRADED token as a model value" \
  "pass 6k: check (f) blocks a trailing-boundary bypass" \
  "pass 6k1: check (f) blocks a numeric-suffixed boundary bypass (independent=yes1)" \
  "pass 6k2: check (f) blocks a hyphen-suffixed boundary bypass (independent=yes-foo)" \
  "pass 6k3: check (f) blocks an underscore-suffixed boundary bypass (independent=yes_foo)" \
  "pass 6k5: check (f) blocks a punctuation-suffixed boundary bypass (independent=yes.)" \
  "pass 6k4: check (f) blocks a duplicated independent= token" \
  "pass 6z: check (f) passes when the body quotes the marker format alongside a valid marker" \
  "pass 6z2: check (f) FAILS on a genuine garbage marker line" \
  "pass 6l: check (f) blocks a marker bound to another head" \
  "pass 6m: check (f) blocks a marker with no head binding" \
  "pass 6n: check (f) blocks a non-id model value" \
  "pass 6p-_github_workflows_ci_yml: check (f) enforces on a change to .github/workflows/ci.yml" \
  "pass 6p-_github_workflows_ci-main_yml: check (f) enforces on a change to .github/workflows/ci-main.yml" \
  "pass 6p-tests_second-model_run_sh: check (f) enforces on a change to tests/second-model/run.sh" \
  "pass 6q: check (f) FAILS on a malformed file row (micro PR, no b-e)" \
  "pass 6r: check (f) FAILS on a FILES_EXPECTED mismatch (micro PR, no b-e)" \
  "pass 6s: check (f) blocks a reserved none-token model laundered as independent=yes" \
  "pass 6t: check (f) blocks a reserved null-token model laundered as independent=yes" \
  "pass 6u: check (f) blocks conflicting markers (later yes must not override DEGRADED)" \
  "pass 6v: check (f) blocks two distinct recorded model ids"; do
  grep -q "✅ $marker" "$OUT" && pass "$marker" || { fail "missing simulation marker: $marker"; tail -5 "$OUT"; }
done

echo ""
echo "12c. Real-git base-state path (G3) — temp repo with the designation on main"
# `git rev-parse --verify --quiet <40-hex>` is vacuously rc=0 for an absent
# object, so the pre-fix guard reported "absent" and check (f) took the
# bootstrap WARN forever. The FAIL_ALL cases 6w/6x drive the REAL git path
# (no PIPELINE_SECOND_MODEL_BASE_FILE seam) and are opt-in, so this suite runs
# them from a temp repo whose main carries the designation while origin/main
# does not. H3: the repo has TWO commits, so HEAD^ DOES resolve while lacking
# the designation — case 6x exercises a resolving-but-wrong fallback (a
# single-commit repo made HEAD^ unresolvable and the case passed vacuously).
TMPREPO="$(mktemp -d /tmp/second-model-gitrepo.XXXXXX)"
mkdir -p "$TMPREPO/scripts" "$TMPREPO/pi-bootstrap/pi-config"
cp "$ROOT/scripts/check-pipeline-compliance.sh" "$ROOT/scripts/check-second-model.sh" "$TMPREPO/scripts/"
cp "$ROOT/pi-bootstrap/pi-config/models.json" "$TMPREPO/pi-bootstrap/pi-config/"
git -C "$TMPREPO" init -q -b main
git -C "$TMPREPO" add scripts pi-bootstrap
git -C "$TMPREPO" -c user.email=test@example.com -c user.name=test commit -qm "init (no designation)"
cp "$SHIPPED" "$TMPREPO/pi-bootstrap/pi-config/second-model.json"
git -C "$TMPREPO" add pi-bootstrap/pi-config/second-model.json
git -C "$TMPREPO" -c user.email=test@example.com -c user.name=test commit -qm "add designation"
PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 PIPELINE_SECOND_MODEL_GIT_CASES=1 \
  GH_REPO=daniel-ospina/agent-infra \
  PIPELINE_SECOND_MODEL_LIVE_DIR="$TMPREPO/pi-bootstrap/pi-config" \
  bash "$TMPREPO/scripts/check-pipeline-compliance.sh" 999999 >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "real-git FAIL_ALL simulation ran (exit 1 by design)"; else fail "real-git simulation expected exit 1, got $code"; tail -25 "$OUT"; fi
for marker in \
  "pass 6w: check (f) FAILS on an absent-but-well-formed real GITHUB_BASE_SHA (real git path)" \
  "pass 6x: check (f) FAILS when a raw-sha PIPELINE_BASE_REF is absent and a fallback ref resolves but lacks the file"; do
  grep -q "✅ $marker" "$OUT" && pass "$marker" || { fail "missing real-git marker: $marker"; tail -15 "$OUT"; }
done
rm -rf "$TMPREPO"

echo ""
echo "12b. Hermeticity: an ambient \$HOME config never leaks in (D2)"
BOGUS_HOME="$(mktemp -d /tmp/second-model-home.XXXXXX)"
mkdir -p "$BOGUS_HOME/.pi/agent"
printf '{ this is not json' > "$BOGUS_HOME/.pi/agent/second-model.json"
HOME="$BOGUS_HOME" bash "$GUARD" --check --live-dir "$FIX/clean" >"$OUT" 2>&1; code=$?
[ "$code" -eq 0 ] && pass "a corrupt ambient authority is ignored by a pinned --live-dir (exit 0)" || { fail "expected 0 with a corrupt \$HOME, got $code"; tail -15 "$OUT"; }
HOME="$BOGUS_HOME" equiv_rc deepseek/deepseek-v4-pro >"$OUT" 2>&1
[ "$(cat "$OUT")" = "0" ] && pass "a corrupt ambient authority is ignored by the pinned equivalence controls" || fail "equivalence control read the corrupt \$HOME ('$(cat "$OUT")')"
rm -rf "$BOGUS_HOME"

echo ""
echo "13. Non-vacuity: equivalence is build identity, not 'is it DeepSeek'"
# Positive controls (must classify EQUIVALENT, exit 0).
# H1: the bare provider shorthand and the short version form are EQUIVALENT,
# because pi's resolver PARTIAL-matches them onto a concrete served build
# (parseModelPattern('deepseek', models) → deepseek/deepseek-v4-pro, the
# primary's served build) — a naive id/family check missed the shorthand.
for m in deepseek deepseek-v4 deepseek-v4.1 deepseek-flash deepseek/deepseek-v4-pro openrouter/deepseek/deepseek-v4-pro deepseek-v4.1-flash-expires-on-0910; do
  rc="$(equiv_rc "$m")"
  if [ "$rc" -eq 0 ]; then pass "positive control $m → EQUIVALENT"; else fail "positive control $m was not classified equivalent (rc=$rc)"; fi
done
# Genuinely non-DeepSeek / non-equivalent controls (must classify INDEPENDENT, exit 1).
# I1: the reroute family must be anchored to v4 — `deepseek-v3.2` is a DISTINCT
# served build (`pi --list-models`), and `deepseek-v5` is a future build. The
# old `^deepseek-v\d+$` family classified BOTH as EQUIVALENT, so designating a
# legitimately independent build yielded DEGRADED (the gate failed closed
# against a valid reviewer).
for m in openrouter/google/gemini-2.5-pro moonshot/kimi-k3 openrouter/anthropic/claude-opus-4.8 deepseek-proxy deepseek-flashlight deepseek-v3.2 deepseek-v5; do
  rc="$(equiv_rc "$m")"
  if [ "$rc" -eq 1 ]; then pass "negative control $m → INDEPENDENT"; else fail "negative control $m was wrongly classified equivalent (rc=$rc)"; fi
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
# A1: --equivalence (check (f)'s backstop) applies the SAME non-vacuity checks.
run_guard 2 "--equivalence on an empty equivalence set is exit 2 (A1)" --equivalence deepseek/x --live-dir "$FIX/empty-equivalence"
run_guard 2 "--equivalence on a misconfigured set is exit 2 (A1)" --equivalence deepseek/x --live-dir "$FIX/misconfigured-equivalence"
# A1: a non-object config must not read as INDEPENDENT.
NONOBJ="$(mktemp -d /tmp/second-model-nonobj.XXXXXX)"
printf '[1,2,3]\n' > "$NONOBJ/second-model.json"
run_guard 2 "--equivalence on a non-object config is exit 2 (A1)" --equivalence deepseek/x --live-dir "$NONOBJ"
run_guard 2 "--check on a non-object config is exit 2" --check --live-dir "$NONOBJ"
run_guard 2 "--print on a non-object config is exit 2 (A4)" --print --live-dir "$NONOBJ"
rm -rf "$NONOBJ"
# A3/D8 normalization matrix. Every spelling of a build-equivalent id must
# classify EQUIVALENT; a trailing slash must NOT normalize to "" (INDEPENDENT).
for m in \
  'deepseek/deepseek-v4-pro/' \
  '~deepseek/deepseek-v4-pro' \
  'deepseek/deepseek-v4-pro:free' \
  'deepseek/deepseek-v4-pro-0731' \
  'deepseek/deepseek-v4.1-flash' \
  'DEEPSEEK/DEEPSEEK-V4-PRO' \
  '  deepseek/deepseek-v4-pro  '; do
  rc="$(equiv_rc "$m")"
  if [ "$rc" -eq 0 ]; then pass "normalization positive: '$m' → EQUIVALENT (A3/D8)"; else fail "normalization positive '$m' was not equivalent (rc=$rc) — an unparseable id must never read independent"; fi
done
# D8: duplicate preference entries WARN (no silent duplicate).
DUP="$(mktemp -d /tmp/second-model-dup.XXXXXX)"
python3 - "$FIX/clean/second-model.json" "$DUP" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["preference"].append(json.loads(json.dumps(cfg["preference"][0])))
json.dump(cfg, open(sys.argv[2] + "/second-model.json", "w"), indent=2)
PY
run_guard 0 "duplicate preference passes but WARNs" --check --live-dir "$DUP"
grep -q "duplicates preference" "$OUT" && pass "duplicate preference dedup WARN present (D8)" || { fail "duplicate preference produced no dedup WARN"; tail -20 "$OUT"; }
rm -rf "$DUP"

echo ""
echo "14. clean mirrors shipped + exact structural delta per fixture (D6)"
python3 - "$SHIPPED" "$FIX" <<'PY'
import json, os, sys
shipped, fix = sys.argv[1], sys.argv[2]
clean = json.load(open(os.path.join(fix, "clean", "second-model.json")))
fails = 0

def leaves(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from leaves(v, (p + "." + k) if p else k)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from leaves(v, (p + "." + str(i)) if p else str(i))
    else:
        yield p, o

def changed(rel):
    d = json.load(open(os.path.join(fix, rel, "second-model.json")))
    cl, dl = dict(leaves(clean)), dict(leaves(d))
    return sorted(k for k in set(cl) | set(dl)
                  if k not in cl or k not in dl or cl[k] != dl[k])

# The documented defect of each fixture, as an EXACT changed leaf-path set.
EXPECTED = {
    "clean": [],
    "backdoor-same-build": ["preference.0.model", "preference.0.runtimeVia"],
    "backdoor-false-pass": ["preference.0.model", "preference.0.runtimeVia"],
    "missing-runtimeVia": ["preference.0.runtimeVia"],
    "missing-unreachablePatterns": [f"unreachablePatterns.{i}" for i in range(7)],
    "empty-unreachablePatterns": [f"unreachablePatterns.{i}" for i in range(7)],
    "empty-equivalence": [f"primary.buildEquivalence.families.{i}" for i in range(3)] + [f"primary.buildEquivalence.normalized.{i}" for i in range(8)],
    "misconfigured-equivalence": [f"primary.buildEquivalence.families.{i}" for i in range(3)] + [f"primary.buildEquivalence.normalized.{i}" for i in range(8)],
    "backdoor-unreachable": [],
    "backdoor-unreachable-soft": [],
    "probe-kimi-solvent": [],
    "probe-order": [],
    "probe-build-equivalent": ["preference.0.model", "preference.0.runtimeVia"],
    "near-miss-negative": [
        "preference.0.model", "preference.0.runtimeVia", "preference.0.costCentsPerPass",
        "preference.0.probe.offerUrl", "preference.0.probe.offerMustInclude",
        "preference.0.probe.solvencyKind", "preference.0.probe.solvencyUrl",
        "preference.0.probe.authEnv",
        "preference.1.model", "preference.1.runtimeVia", "preference.1.costCentsPerPass",
        "preference.1.probe.offerUrl", "preference.1.probe.offerMustInclude",
        "preference.1.probe.solvencyKind", "preference.1.probe.solvencyUrl",
        "preference.1.probe.authEnv",
    ],
}

if json.load(open(shipped)) != clean:
    print("FAIL clean fixture mirrors the shipped second-model.json")
    fails += 1
for rel in sorted(os.listdir(fix)):
    if not os.path.exists(os.path.join(fix, rel, "second-model.json")):
        continue
    got = changed(rel)
    want = sorted(EXPECTED.get(rel, []))
    status = "PASS" if got == want else "FAIL"
    print(f"{status} {rel}: {got}")
    if got != want:
        print(f"     expected exactly: {want}")
        fails += 1
sys.exit(1 if fails else 0)
PY
py=$?
if [ "$py" -eq 0 ]; then pass "fixture invariants hold (exact per-fixture leaf-path sets)"; else fail "fixture structural-delta check failed (exit $py)"; fi

echo ""
echo "15. Large vendor catalogue is not truncation-blind (hermetic file:// probe)"
LARGE="$(mktemp -d /tmp/second-model-large.XXXXXX)"
python3 - "$FIX/clean/second-model.json" "$LARGE" <<'PY'
import json, os, sys
clean = json.load(open(sys.argv[1]))
out = sys.argv[2]
# An offer payload larger than the old fixed read cap, with the designated id
# placed AFTER it (the real OpenRouter shape: ~730KB, id at byte ~222k).
open(os.path.join(out, "offer.json"), "w").write('{"data":[{"id":"' + "x" * 80000 + 'kimi-k3"}]}')
open(os.path.join(out, "balance.json"), "w").write('{"data":{"available_balance":12.5}}')
cfg = json.loads(json.dumps(clean))
cfg["preference"] = cfg["preference"][:1]
cfg["preference"][0]["probe"]["offerUrl"] = "file://" + os.path.join(out, "offer.json")
cfg["preference"][0]["probe"]["solvencyUrl"] = "file://" + os.path.join(out, "balance.json")
cfg["preference"][0]["probe"]["authEnv"] = ""
json.dump(cfg, open(os.path.join(out, "second-model.json"), "w"), indent=2)
PY
run_guard 0 "needle past the 50KB read cap" --probe --allow-file-probe --live-dir "$LARGE"
grep -q "RESOLVED=moonshot/kimi-k3" "$OUT" && pass "streamed needle search found the id past 50KB (no truncation)" || { fail "id past 50KB was missed — truncation regression"; tail -10 "$OUT"; }
# Negative control: identical shape, needle absent → must NOT resolve.
python3 - "$LARGE" <<'PY'
import os, sys
open(os.path.join(sys.argv[1], "offer.json"), "w").write('{"data":[{"id":"' + "y" * 80000 + '"}]}')
PY
run_guard 1 "needle absent in a large catalogue" --probe --allow-file-probe --live-dir "$LARGE"
grep -q "vendor offer does not include kimi-k3" "$OUT" && pass "absent needle still blocks (search is non-vacuous)" || { fail "absent needle did not block"; tail -10 "$OUT"; }
rm -rf "$LARGE"

echo ""
echo "16. Probe security: a hostile config cannot exfiltrate a credential (B1)"
# A local listener records any request it receives. The hostile config names a
# secret (authEnv=GH_TOKEN) and a config-chosen destination (http://127.0.0.1).
LISTENER_DIR="$(mktemp -d /tmp/second-model-listen.XXXXXX)"
LISTENER_PY="$LISTENER_DIR/listen.py"
LISTENER_JSON="$LISTENER_DIR/received.json"
cat > "$LISTENER_PY" <<'PY'
import json, socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
s.settimeout(3)
got = []
try:
    while True:
        c, _ = s.accept()
        got.append(c.recv(65536).decode("utf-8", "replace"))
        c.close()
except Exception:
    pass
open(sys.argv[2], "w").write(json.dumps({"requests": len(got), "blobs": got}))
PY
python3 "$LISTENER_PY" "$LISTENER_DIR/port" "$LISTENER_JSON" &
LISTENER_PID=$!
for _ in $(seq 1 40); do [ -s "$LISTENER_DIR/port" ] && break; sleep 0.05; done
PORT="$(cat "$LISTENER_DIR/port" 2>/dev/null || echo 0)"
HOSTILE="$(mktemp -d /tmp/second-model-hostile.XXXXXX)"
mk_hostile() { # <outdir> <offerUrl> <solvencyUrl> <authEnv>
  python3 - "$FIX/clean/second-model.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
out = sys.argv[2]
cfg["preference"] = cfg["preference"][:1]
cfg["preference"][0]["probe"]["offerUrl"] = sys.argv[3]
cfg["preference"][0]["probe"]["solvencyUrl"] = sys.argv[4]
cfg["preference"][0]["probe"]["authEnv"] = sys.argv[5]
cfg["preference"][0]["probe"]["solvencyKind"] = "none"
json.dump(cfg, open(out + "/second-model.json", "w"), indent=2)
PY
}
mk_hostile "$HOSTILE" "http://127.0.0.1:$PORT/collect" "http://127.0.0.1:$PORT/collect" "GH_TOKEN"
GH_TOKEN="LIVE-DIR-SECRET-xyz" bash "$GUARD" --probe --live-dir "$HOSTILE" >"$OUT" 2>&1; code=$?
if [ "$code" -ne 0 ]; then pass "hostile http:// config fails closed (exit $code)"; else fail "hostile http:// config resolved (exit 0)"; fi
if grep -q "LIVE-DIR-SECRET-xyz" "$OUT"; then fail "the probe PRINTED the secret value"; else pass "the secret value was never printed"; fi
grep -q "GH_TOKEN" "$OUT" && grep -q "not a known 'moonshot' vendor env" "$OUT" && pass "arbitrary authEnv is rejected (B1)" || { fail "GH_TOKEN was not rejected as an authEnv"; tail -10 "$OUT"; }
# The same http:// URL with an ALLOWLISTED env must still be refused on scheme.
mk_hostile "$HOSTILE" "http://127.0.0.1:$PORT/collect" "http://127.0.0.1:$PORT/collect" "MOONSHOT_API_KEY"
MOONSHOT_API_KEY="SECRET-SCHEME" bash "$GUARD" --probe --live-dir "$HOSTILE" >"$OUT" 2>&1; code=$?
[ "$code" -ne 0 ] && pass "http:// fails closed even with an allowlisted env (exit $code)" || fail "http:// resolved with an allowlisted env"
grep -q "must be https://" "$OUT" && pass "http:// probe URL is rejected (B1)" || { fail "http:// was not rejected"; tail -10 "$OUT"; }
wait "$LISTENER_PID" 2>/dev/null || true
REQS="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['requests'])" "$LISTENER_JSON" 2>/dev/null || echo ERR)"
if [ "$REQS" = "0" ]; then pass "no request reached the config-chosen host — the key was NOT transmitted"; else fail "the listener received $REQS request(s) — a credential may have leaked"; fi
# A foreign https host with an allowlisted env name is also refused.
mk_hostile "$HOSTILE" "https://evil.example.com/collect" "https://evil.example.com/collect" "MOONSHOT_API_KEY"
MOONSHOT_API_KEY="SECRET456" bash "$GUARD" --probe --live-dir "$HOSTILE" >"$OUT" 2>&1; code=$?
[ "$code" -ne 0 ] && pass "foreign https host fails closed (exit $code)" || fail "foreign https host resolved"
grep -q "not an allowlisted 'moonshot' vendor host" "$OUT" && pass "foreign host is refused (B1)" || { fail "foreign host was not refused"; tail -10 "$OUT"; }
grep -q "SECRET456" "$OUT" && fail "the probe printed SECRET456" || pass "no secret in output"
# The allowlisted host + allowlisted env is accepted by the static policy
# (proving the allowlist is not vacuously rejecting everything) — the probe
# still fails only because the live network is unavailable/unfunded.
mk_hostile "$HOSTILE" "https://api.moonshot.ai/v1/models" "https://api.moonshot.ai/v1/users/me/balance" "MOONSHOT_API_KEY"
bash "$GUARD" --check --live-dir "$HOSTILE" >"$OUT" 2>&1; code=$?
if grep -q "not an allowlisted" "$OUT"; then fail "the allowlisted moonshot host was refused"; else pass "the allowlisted moonshot host passes the static policy"; fi
rm -rf "$HOSTILE" "$LISTENER_DIR"

echo ""
echo "16b. Probe credential policy: exact vendor host + vendor-bound authEnv (G1)"
# The old `host_allowed()` fell back to `labels[-2] == vendor`, so the CONFIG
# chose the destination host by naming `model=<vendor>/…`; `authEnv` was
# checked against a GLOBAL allowlist, so it could name another vendor's key.
# A hostile authority must fail closed (and, at probe time, transmit nothing).
G1DIR="$(mktemp -d /tmp/second-model-g1.XXXXXX)"
mk_g1() { # <model> <url> <authEnv>
  python3 - "$FIX/clean/second-model.json" "$G1DIR" "$1" "$2" "$3" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["preference"] = cfg["preference"][:1]
e = cfg["preference"][0]
e["model"] = sys.argv[3]
# an external runtimeVia only WARNs — the model id is then the only thing the
# host/env policy sees (no runtimeVia fatal to mask the policy verdict)
e["runtimeVia"] = "extensions/custom-provider-openrouter/index.ts#registerProvider(openrouter).models[0]"
e["probe"]["offerUrl"] = sys.argv[4]
e["probe"]["solvencyUrl"] = sys.argv[4]
e["probe"]["authEnv"] = sys.argv[5]
e["probe"]["solvencyKind"] = "none"
json.dump(cfg, open(sys.argv[2] + "/second-model.json", "w"), indent=2)
PY
}
g1_case() { # <label> <model> <url> <env> <needle>
  mk_g1 "$2" "$3" "$4"
  bash "$GUARD" --check --live-dir "$G1DIR" >"$OUT" 2>&1; local code=$?
  if [ "$code" -ne 0 ] && grep -q "$5" "$OUT"; then
    pass "$1 (fail-closed exit $code)"
  else
    fail "$1 — expected a BLOCK naming '$5', got exit $code"
    tail -15 "$OUT"
  fi
}
g1_case "a vendor-named registrable domain (lvh.me) is refused" "lvh/independent-model" "https://lvh.me/collect" "MOONSHOT_API_KEY" "not an allowlisted 'lvh' vendor host"
g1_case "an attacker vendor host is refused" "attacker/kimi-k3" "https://api.attacker.com/collect" "OPENROUTER_API_KEY" "not an allowlisted 'attacker' vendor host"
g1_case "a fragment-suffixed host is refused (policy host != connection host)" "moonshot/kimi-k3" "https://evil.com#api.moonshot.ai/x" "MOONSHOT_API_KEY" "parses inconsistently"
g1_case "a query-suffixed host is refused" "moonshot/kimi-k3" "https://evil.com?x=api.moonshot.ai" "MOONSHOT_API_KEY" "parses inconsistently"
g1_case "a foreign vendor's credential env is refused" "moonshot/kimi-k3" "https://api.moonshot.ai/v1/models" "ANTHROPIC_API_KEY" "not a known 'moonshot' vendor env name"
g1_case "an unknown vendor has no credential env" "lvh/independent-model" "https://lvh.me/collect" "OPENROUTER_API_KEY" "not a known 'lvh' vendor env name"
# Positive control: the shipped vendor + env pair is still accepted, proving
# the policy is not vacuously refusing everything.
mk_g1 "moonshot/kimi-k3" "https://api.moonshot.ai/v1/models" "MOONSHOT_API_KEY"
bash "$GUARD" --check --live-dir "$G1DIR" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 0 ]; then pass "the shipped moonshot host + env pair still passes the static policy"; else fail "the allowlisted pair was refused (exit $code)"; tail -12 "$OUT"; fi
# Probe-time capture: the fragment-smuggled destination must transmit nothing.
# (The https host is not resolvable here, so this asserts the POLICY refusal —
# the http:// capture in section 16 is the live-listener proof.)
mk_g1 "moonshot/kimi-k3" "https://evil.com#api.moonshot.ai/collect" "MOONSHOT_API_KEY"
MOONSHOT_API_KEY="G1-CANARY-zz" bash "$GUARD" --probe --live-dir "$G1DIR" >"$OUT" 2>&1; code=$?
[ "$code" -ne 0 ] && pass "the fragment-smuggled probe destination is refused at probe time (exit $code)" || fail "the fragment-smuggled destination resolved"
grep -q "G1-CANARY-zz" "$OUT" && fail "the probe printed the canary" || pass "the canary was never printed"
rm -rf "$G1DIR"

echo ""
echo "16c. Redirect policy: a cross-port 302 must not re-send the key (G7/G8)"
# Listener B captures anything it receives; listener A answers a GET with a 302
# to B. Under the old hostname-only guard the Authorization header was re-sent
# to B. The initial probe URL is loopback http (test-only --allow-local-probe);
# the redirect policy itself is NOT relaxed by that flag.
RLOG_DIR="$(mktemp -d /tmp/second-model-redir.XXXXXX)"
cat > "$RLOG_DIR/b.py" <<'PY'
import json, socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
s.settimeout(4)
got = []
try:
    while True:
        c, _ = s.accept()
        got.append(c.recv(65536).decode("utf-8", "replace"))
        c.close()
except Exception:
    pass
open(sys.argv[2], "w").write(json.dumps({"requests": len(got), "blobs": got}))
PY
cat > "$RLOG_DIR/a.py" <<'PY'
import socket, sys
port_file, location = sys.argv[1], sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(5)
open(port_file, "w").write(str(s.getsockname()[1]))
s.settimeout(5)
try:
    c, _ = s.accept()
    c.recv(65536)
    c.sendall(b"HTTP/1.1 302 Found\r\nLocation: " + location.encode() + b"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    c.close()
except Exception:
    pass
PY
python3 "$RLOG_DIR/b.py" "$RLOG_DIR/bport" "$RLOG_DIR/breceived" &
RPID_B=$!
for _ in $(seq 1 40); do [ -s "$RLOG_DIR/bport" ] && break; sleep 0.05; done
RPORT_B="$(cat "$RLOG_DIR/bport" 2>/dev/null || echo 0)"
python3 "$RLOG_DIR/a.py" "$RLOG_DIR/aport" "http://127.0.0.1:$RPORT_B/collect" &
RPID_A=$!
for _ in $(seq 1 40); do [ -s "$RLOG_DIR/aport" ] && break; sleep 0.05; done
RPORT_A="$(cat "$RLOG_DIR/aport" 2>/dev/null || echo 0)"
RCFG="$(mktemp -d /tmp/second-model-rcfg.XXXXXX)"
python3 - "$FIX/clean/second-model.json" "$RCFG" "http://127.0.0.1:$RPORT_A/redirect" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["preference"] = cfg["preference"][:1]
e = cfg["preference"][0]
e["probe"]["offerUrl"] = sys.argv[3]
e["probe"]["solvencyUrl"] = sys.argv[3]
e["probe"]["authEnv"] = "MOONSHOT_API_KEY"
e["probe"]["solvencyKind"] = "none"
json.dump(cfg, open(sys.argv[2] + "/second-model.json", "w"), indent=2)
PY
MOONSHOT_API_KEY="REDIRECT-CANARY-9f" bash "$GUARD" --probe --allow-local-probe --live-dir "$RCFG" >"$OUT" 2>&1; code=$?
wait "$RPID_A" 2>/dev/null || true
wait "$RPID_B" 2>/dev/null || true
RREQS="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['requests'])" "$RLOG_DIR/breceived" 2>/dev/null || echo ERR)"
if [ "$RREQS" = "0" ]; then pass "the cross-port 302 was refused — no request (and no key) reached the second listener"; else fail "the redirect was followed: $RREQS request(s) reached the second listener — the credential was re-sent"; fi
[ "$code" -eq 0 ] && fail "the redirecting probe reported success" || pass "the redirecting probe failed closed (exit $code)"
grep -q "REDIRECT-CANARY-9f" "$OUT" && fail "the probe printed the redirect canary" || pass "the redirect canary was never printed"
rm -rf "$RCFG" "$RLOG_DIR"

echo ""
echo "17. Mode/exit-code pins (A1/A2/A4/A5/D7)"
# A4: --print on an empty preference is exit 1 (no candidate), not 0/2.
EMPTYPREF="$(mktemp -d /tmp/second-model-emptypref.XXXXXX)"
python3 - "$FIX/clean/second-model.json" "$EMPTYPREF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["preference"] = []
json.dump(cfg, open(sys.argv[2] + "/second-model.json", "w"), indent=2)
PY
run_guard 1 "--print on an empty preference is exit 1 (A4)" --print --live-dir "$EMPTYPREF"
rm -rf "$EMPTYPREF"
# A4: an unreadable --probe-fixture is exit 2.
run_guard 2 "--print with an unreadable probe fixture is exit 2 (A4)" --print --live-dir "$FIX/clean" --probe-fixture /nonexistent/probe.json
# A2: --probe skips a solvent build-equivalent candidate and resolves the next.
run_guard 0 "--probe skips a solvent build-equivalent candidate (A2)" \
  --probe --live-dir "$FIX/probe-build-equivalent" --probe-fixture "$FIX/probe-build-equivalent/probe.json"
grep -q "build-equivalent (skipped)" "$OUT" && pass "--probe reports the build-equivalent skip" || { fail "no build-equivalent skip note"; tail -10 "$OUT"; }
grep -q "RESOLVED=openrouter/anthropic/claude-opus-4.8" "$OUT" && pass "--probe resolves the independent candidate, not the same-build one" || { fail "expected RESOLVED=opus-4.8"; tail -10 "$OUT"; }
# --print on the same fixture also skips the same-build candidate (two-step contract).
bash "$GUARD" --print --live-dir "$FIX/probe-build-equivalent" --probe-fixture "$FIX/probe-build-equivalent/probe.json" >"$OUT" 2>&1
[ "$(cat "$OUT")" = "openrouter/anthropic/claude-opus-4.8" ] && pass "--print and --probe agree on the same-build skip" || fail "--print disagreed: '$(cat "$OUT")'"
# A5: --probe probes a matching $SECOND_MODEL override FIRST.
bash "$GUARD" --probe --live-dir "$FIX/probe-order" --probe-fixture "$FIX/probe-order/probe.json" >"$OUT" 2>&1
grep -q "RESOLVED=moonshot/kimi-k3" "$OUT" && pass "--probe without an override resolves the config order (kimi-k3)" || { fail "expected kimi-k3"; tail -10 "$OUT"; }
SECOND_MODEL=openrouter/anthropic/claude-opus-4.8 bash "$GUARD" --probe --live-dir "$FIX/probe-order" --probe-fixture "$FIX/probe-order/probe.json" >"$OUT" 2>&1
grep -q "RESOLVED=openrouter/anthropic/claude-opus-4.8" "$OUT" && pass "--probe honours a matching \$SECOND_MODEL first (A5)" || { fail "expected the override to resolve first"; tail -10 "$OUT"; }
# A5: an override with no declared probe endpoint is NEVER probe-certified.
SECOND_MODEL=openrouter/google/gemini-2.5-pro bash "$GUARD" --probe --live-dir "$FIX/probe-order" --probe-fixture "$FIX/probe-order/probe.json" >"$OUT" 2>&1
grep -q "liveness UNVERIFIED" "$OUT" && pass "an unprobeable override is reported UNVERIFIED (A5)" || { fail "unprobeable override produced no UNVERIFIED note"; tail -10 "$OUT"; }
grep -q "RESOLVED=openrouter/google/gemini-2.5-pro" "$OUT" && fail "the probe certified an unprobeable override" || pass "the probe did NOT certify an unprobeable override"
# A3: a trailing-slash id is EQUIVALENT (never INDEPENDENT) in --equivalence.
bash "$GUARD" --equivalence 'deepseek/deepseek-v4-pro/' --live-dir "$FIX/clean" >"$OUT" 2>&1
[ "$(cat "$OUT" | head -1 | cut -d' ' -f1)" = "EQUIVALENT" ] && pass "trailing-slash id reads EQUIVALENT, not INDEPENDENT (A3)" || { fail "trailing-slash id read '$(head -1 "$OUT")'"; }
# H4: `--model ID` is documented as the equivalence target but never selected
# equivalence mode — it ran --check and returned exit 0 for EVERY id.
bash "$GUARD" --model deepseek/deepseek-v4-pro --live-dir "$FIX/clean" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 0 ] && [ "$(head -1 "$OUT" | cut -d' ' -f1)" = "EQUIVALENT" ]; then
  pass "H4: --model <build-equivalent id> → EQUIVALENT (exit 0)"
else
  fail "H4: --model on a build-equivalent id returned exit $code / '$(head -1 "$OUT")'"
fi
# Mode-selection proof: an independent id must exit 1 under --model. The old
# (check-mode) behaviour returned exit 0 on the same clean authority.
bash "$GUARD" --model openrouter/google/gemini-2.5-pro --live-dir "$FIX/clean" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 1 ] && [ "$(head -1 "$OUT" | cut -d' ' -f1)" = "INDEPENDENT" ]; then
  pass "H4: --model <independent id> → INDEPENDENT (exit 1 — proves equivalence mode, not check mode)"
else
  fail "H4: --model fail-open on an independent id — exit $code / '$(head -1 "$OUT")'"
fi

# G2: --print is the documented offline authority — it must reject what
# --check/--equivalence reject, and never emit a reserved/placeholder id.
run_guard 2 "--print on empty-equivalence is exit 2 (G2)" --print --live-dir "$FIX/empty-equivalence"
run_guard 2 "--print on misconfigured-equivalence is exit 2 (G2)" --print --live-dir "$FIX/misconfigured-equivalence"
# H2: `--print` must not short-circuit the shared validator / the id check
# whenever `$SECOND_MODEL` is set — the old override branch returned from the
# top of print mode, so these all exited 0 while `--check` exited 2.
for bad in '**DEGRADED' none 'hello world'; do
  SECOND_MODEL="$bad" bash "$GUARD" --print --live-dir "$FIX/clean" >"$OUT" 2>&1; code=$?
  if [ "$code" -eq 2 ] && grep -q "not a dispatchable model id" "$OUT"; then
    pass "H2: --print refuses the non-dispatchable override '$bad' (exit 2)"
  else
    fail "H2: --print emitted '$bad' with exit $code (expected a fail-closed exit 2)"; tail -5 "$OUT"
  fi
done
SECOND_MODEL=deepseek/deepseek-v4-pro bash "$GUARD" --print --live-dir "$FIX/empty-equivalence" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "H2: --print override cannot bypass an empty-equivalence fatal (exit 2, --check parity)"; else fail "H2: --print override laundered the empty-equivalence authority (expected 2, got $code)"; tail -5 "$OUT"; fi
SECOND_MODEL=moonshot/kimi-k3 bash "$GUARD" --print --live-dir "$FIX/missing-config" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "H2: --print override does not silence the missing-config fatal (exit 2)"; else fail "H2: --print override laundered the missing-config fatal (expected 2, got $code)"; tail -5 "$OUT"; fi
# Positive control: a dispatchable override still prints verbatim (no over-block).
SECOND_MODEL=moonshot/kimi-k3 bash "$GUARD" --print --live-dir "$FIX/clean" >"$OUT" 2>/dev/null; code=$?
if [ "$code" -eq 0 ] && [ "$(cat "$OUT")" = "moonshot/kimi-k3" ]; then pass "H2: a dispatchable override still prints verbatim (exit 0)"; else fail "H2: valid override regressed (exit $code, '$(cat "$OUT")')"; fi
PRBAD="$(mktemp -d /tmp/second-model-prbad.XXXXXX)"
mk_pref_bad() { # <json-model-literal>
  # An EXTERNAL runtimeVia only WARNs, so the model-type/id guard is the only
  # thing that can reject the literal (a models.json pointer would fatal first
  # and make the assertion pass for the wrong reason).
  python3 - "$FIX/clean/second-model.json" "$PRBAD" "$1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["preference"] = cfg["preference"][:1]
cfg["preference"][0]["model"] = json.loads(sys.argv[3])
cfg["preference"][0]["runtimeVia"] = "extensions/custom-provider-openrouter/index.ts#registerProvider(openrouter).models[0]"
json.dump(cfg, open(sys.argv[2] + "/second-model.json", "w"), indent=2)
PY
}
for lit in '123' '"**DEGRADED"' '"none"' '"hello world"'; do
  mk_pref_bad "$lit"
  bash "$GUARD" --print --live-dir "$PRBAD" >"$OUT" 2>&1; code=$?
  if [ "$code" -eq 2 ]; then pass "--print rejects the non-dispatchable model $lit (exit 2)"; else fail "--print emitted $lit with exit $code"; tail -5 "$OUT"; fi
done
rm -rf "$PRBAD"

# G5/G9: reserved/placeholder tokens are never INDEPENDENT.
for tok in none null 'n/a' unknown '**DEGRADED'; do
  rc="$(equiv_rc "$tok")"
  if [ "$rc" -eq 0 ]; then pass "reserved token '$tok' reads EQUIVALENT (never INDEPENDENT, G5)"; else fail "reserved token '$tok' read INDEPENDENT (rc=$rc) — check (f) would read it as a pass"; fi
done

# G6/G13: with $SECOND_MODEL set, --probe certifies ONLY that id — no fallthrough.
SECOND_MODEL=openrouter/google/gemini-2.5-pro bash "$GUARD" --probe --live-dir "$FIX/probe-order" --probe-fixture "$FIX/probe-order/probe.json" >"$OUT" 2>&1; code=$?
if [ "$code" -eq 1 ]; then pass "--probe DEGRADEs an unprobeable override (exit 1, G6)"; else fail "expected exit 1 for an unprobeable override, got $code"; tail -10 "$OUT"; fi
grep -q "RESOLVED=" "$OUT" && fail "--probe emitted a RESOLVED for an unprobeable override (the operator pin was dropped)" || pass "--probe emitted no RESOLVED — the operator pin is never silently replaced (G6)"
grep -q "liveness UNVERIFIED" "$OUT" && pass "--probe names the unprobeable override" || fail "--probe gave no UNVERIFIED note"

# G8: the policy selftest pins the host/url/authEnv/redirect predicates.
run_guard 0 "policy selftest passes (G1/G5/G7)" --selftest-policy
grep -q "SELFTEST-POLICY PASS" "$OUT" && pass "selftest reports PASS" || { fail "selftest did not report PASS"; tail -10 "$OUT"; }

# G8: file:// is refused without the test-only flag, permitted with it.
FILEPROBE="$(mktemp -d /tmp/second-model-fileprobe.XXXXXX)"
python3 - "$FIX/clean/second-model.json" "$FILEPROBE" <<'PY'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
out = sys.argv[2]
open(os.path.join(out, "offer.json"), "w").write('{"data":[{"id":"kimi-k3"}]}')
open(os.path.join(out, "balance.json"), "w").write('{"data":{"available_balance":5}}')
cfg["preference"] = cfg["preference"][:1]
cfg["preference"][0]["probe"]["offerUrl"] = "file://" + os.path.join(out, "offer.json")
cfg["preference"][0]["probe"]["solvencyUrl"] = "file://" + os.path.join(out, "balance.json")
cfg["preference"][0]["probe"]["authEnv"] = ""
json.dump(cfg, open(os.path.join(out, "second-model.json"), "w"), indent=2)
PY
run_guard 1 "--check refuses a file:// probe URL without --allow-file-probe (G8)" --check --live-dir "$FILEPROBE"
grep -q "file:// probe URL refused" "$OUT" && pass "the static policy names the missing file:// flag" || fail "file:// refusal message missing from --check"
run_guard 1 "--probe refuses a file:// probe URL without --allow-file-probe (G8)" --probe --live-dir "$FILEPROBE"
run_guard 0 "--probe resolves the same config under --allow-file-probe (G8 positive control)" --probe --allow-file-probe --live-dir "$FILEPROBE"
grep -q "RESOLVED=moonshot/kimi-k3" "$OUT" && pass "the file:// seam resolves the designated id" || { fail "expected RESOLVED=moonshot/kimi-k3"; tail -8 "$OUT"; }
rm -rf "$FILEPROBE"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All second-model gate tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
