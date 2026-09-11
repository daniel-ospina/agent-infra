#!/bin/bash
# #341 — cost-config drift-guard tests.
#
# Exercises scripts/check-cost-config.sh semantics:
#   1. clean fixture (deepseek ids @300K clamp)    → PASS (exit 0)
#   2. models.json drift (deepseek id > 300K)      → BLOCK (exit 1)
#      (positive controls: the v4-pro family, the legacy v4-flash alias, the
#      canonical deepseek-flash id + its future bare `deepseek-pro`
#      counterpart, dotted deepseek-v4.1 ids, `:`-suffixed (routing-tier)
#      shapes;
#      negative controls: deepseek-proxy / deepseek-flashlight — V4.1 Flash
#      adoption 2026-09-10)
#   3. models-store.json drift                     → WARN (exit 0, DETECTED —
#      catalog class must not fail sync; the weekly report + tripwire alert)
#      (also: matcher negatives kimi-k3 + deepseek-chat-v3.2 never flagged;
#      `~deepseek` alias + vision-exp covered)
#   4. settings.json missing compaction block      → BLOCK (exit 1)
#   5. settings.json retry.maxRetries != 10000     → BLOCK (exit 1)
#   6. COST_CLAMP_OVERRIDE=1                       → exit 0 + loud notice
#   7. --shipped-only                              → exit 0, no live-dir access
#   8. MINIFIED models.json (1M backdoor)           → BLOCK (exit 1) —
#      format-independent detection (P1 regression pin)
#   9. MINIFIED clean models.json (300K clamp)     → PASS (exit 0)
#  10. missing SHIPPED models.json                  → BLOCK (exit 1, authority
#      deleted = clamp gone)
#  11. missing LIVE models.json (first-install)     → WARN (exit 0)
#  12. compaction.enabled=false                     → BLOCK (exit 1)
#
# Fixtures under tests/fixtures/cost-config/ are regenerated from the LIVE
# store at implementation time; clean + clean-minified hold canonical-JSON
# copies of the three shipped config files, and each backdoor-* tree
# re-introduces exactly one defect (backdoor-models/backdoor-minified
# models.json hold 1M deepseek ids; backdoor-store/models-store.json holds
# the pre-#476 curated snapshot with the alias + vision-exp rows at 1M; the
# guard's canonical matcher must catch exactly the deepseek-served family).
#  13. clean/clean-minified mirror the shipped tree (canonical JSON, all
#      three config files) and the four backdoor trees whose defect lives
#      outside models.json keep clean's models.json → parity pin so the #630
#      review's mirror invariant cannot rot silently.
#  14. fixture invariants: each backdoor tree differs from clean in exactly
#      its one documented defect (bounded delta), and the near-miss negative
#      controls are PRESENT in the fixtures — so an absence assertion can
#      never become vacuous.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-cost-config.sh"
FIX="$ROOT/tests/fixtures/cost-config"
OUT="$(mktemp /tmp/cost-config-out.XXXXXX)"
failures=0

# Single source of truth: read the clamp out of the guard rather than hardcoding
# it here, so the fixture assertions cannot drift from the enforced value.
CLAMP_EXPECTED="$(sed -n 's/^CLAMP=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"
if [ -z "$CLAMP_EXPECTED" ]; then
  echo "❌ could not read CLAMP= from $GUARD — the fixture controls assert against it."
  exit 1
fi

# Guard: never modify fixtures. Fail early if the fixture tree is dirty
# (same clobber-protection as tests/drift/run.sh).
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/cost-config; then
  echo "❌ tests/fixtures/cost-config has uncommitted modifications — commit them first."
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

echo "== cost-config guard tests (#341) =="
echo ""

echo "0. Fixture JSON validity"
ok=1
for f in "$FIX"/*/*.json; do
  python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null || { ok=0; fail "invalid JSON: $f"; }
done
[ "$ok" = 1 ] && pass "all fixture JSON files parse"

echo ""
echo "1. Clean fixture (300K clamp) → PASS"
run_guard 0 "clean fixture" --live-dir "$FIX/clean"
if grep -q "✅ cost-config guard: PASS" "$OUT"; then pass "summary PASS"; else fail "expected PASS summary"; tail -20 "$OUT"; fi

echo ""
echo "2. models.json drift (deepseek id at 1M) → BLOCK, exit 1"
run_guard 1 "backdoor-models" --live-dir "$FIX/backdoor-models"
if grep -q "BLOCK-level violation" "$OUT"; then pass "BLOCK summary present"; else fail "expected BLOCK summary"; tail -20 "$OUT"; fi
if grep -q "deepseek-v4-pro contextWindow=1000000" "$OUT"; then pass "deepseek-v4-pro flagged"; else fail "deepseek-v4-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4-flash contextWindow=1000000" "$OUT"; then pass "legacy v4-flash alias flagged"; else fail "legacy v4-flash alias not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash contextWindow=1000000" "$OUT"; then pass "canonical deepseek-flash flagged"; else fail "canonical deepseek-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash contextWindow=1000000" "$OUT"; then pass "dotted v4.1 family flagged"; else fail "deepseek-v4.1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash-expires-on-0910 contextWindow=1000000" "$OUT"; then pass "dotted beta id flagged"; else fail "dotted beta id not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4-pro:batch contextWindow=1000000" "$OUT"; then pass ":batch terminator flagged"; else fail ":batch terminator not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash:batch contextWindow=1000000" "$OUT"; then pass "canonical :batch flagged"; else fail "canonical :batch not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-pro contextWindow=1000000" "$OUT"; then pass "bare deepseek-pro flagged"; else fail "bare deepseek-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-proxy" "$OUT"; then fail "negative control deepseek-proxy was flagged"; else pass "deepseek-proxy (non-family) not flagged"; fi
if grep -q "deepseek-flashlight" "$OUT"; then fail "negative control deepseek-flashlight was flagged"; else pass "deepseek-flashlight (non-family) not flagged"; fi

echo ""
echo "3. models-store.json drift → WARN, exit 0 (DETECTED, not blocked)"
run_guard 0 "backdoor-store" --live-dir "$FIX/backdoor-store"
if grep -q "catalog class — DETECTED, not blocked" "$OUT"; then pass "store drift DETECTED"; else fail "expected catalog-class warn"; tail -25 "$OUT"; fi
if grep -q "~deepseek/deepseek-v4-flash-latest" "$OUT"; then pass "~deepseek alias covered"; else fail "~deepseek alias missing from output"; tail -25 "$OUT"; fi
if grep -q "deepseek-v4-flash-vision-exp" "$OUT"; then pass "vision-exp covered"; else fail "vision-exp missing from output"; tail -25 "$OUT"; fi
if grep -q "kimi-k3" "$OUT"; then fail "negative control kimi-k3 was flagged"; else pass "kimi-k3 (excluded by decision) not flagged"; fi
if grep -q "deepseek-chat-v3.2" "$OUT"; then fail "negative control deepseek-chat-v3.2 was flagged"; else pass "deepseek-chat-v3.2 (non-served catalog id) not flagged"; fi

echo ""
echo "4. settings.json missing compaction block → BLOCK, exit 1"
run_guard 1 "backdoor-settings" --live-dir "$FIX/backdoor-settings"
if grep -q "compaction.reserveTokens" "$OUT"; then pass "compaction drift flagged"; else fail "expected compaction message"; tail -20 "$OUT"; fi

echo ""
echo "5. settings.json retry.maxRetries != 10000 → BLOCK, exit 1"
run_guard 1 "backdoor-retry" --live-dir "$FIX/backdoor-retry"
if grep -q "retry.maxRetries expected 10000" "$OUT"; then pass "retry drift flagged"; else fail "expected retry message"; tail -20 "$OUT"; fi

echo ""
echo "6. COST_CLAMP_OVERRIDE=1 silences the block (escape hatch)"
COST_CLAMP_OVERRIDE=1 bash "$GUARD" --live-dir "$FIX/backdoor-models" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "override → exit 0"; else fail "override — expected exit 0, got $code"; tail -20 "$OUT"; fi
if grep -q "COST_CLAMP_OVERRIDE=1" "$OUT"; then pass "loud override notice present"; else fail "override notice missing"; tail -20 "$OUT"; fi

echo ""
echo "7. --shipped-only runs without a live dir (CI/pre-commit shape)"
run_guard 0 "--shipped-only" --shipped-only
if grep -q "live pass skipped" "$OUT"; then pass "live pass skipped"; else fail "expected skip notice"; tail -10 "$OUT"; fi

echo ""
echo "8. MINIFIED models.json (1M backdoor) → BLOCK, exit 1 (P1 regression pin)"
run_guard 1 "backdoor-minified" --live-dir "$FIX/backdoor-minified"
if grep -q "BLOCK-level violation" "$OUT"; then pass "BLOCK summary present"; else fail "expected BLOCK summary"; tail -20 "$OUT"; fi
if grep -q "deepseek-v4-pro contextWindow=1000000" "$OUT"; then pass "minified deepseek-v4-pro flagged"; else fail "minified deepseek-v4-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4-flash contextWindow=1000000" "$OUT"; then pass "minified legacy v4-flash alias flagged"; else fail "minified legacy v4-flash alias not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash contextWindow=1000000" "$OUT"; then pass "minified canonical deepseek-flash flagged"; else fail "minified canonical deepseek-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash contextWindow=1000000" "$OUT"; then pass "minified dotted v4.1 family flagged"; else fail "minified deepseek-v4.1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash-expires-on-0910 contextWindow=1000000" "$OUT"; then pass "minified dotted beta id flagged"; else fail "minified dotted beta id not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash:batch contextWindow=1000000" "$OUT"; then pass "minified canonical :batch flagged"; else fail "minified canonical :batch not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-pro contextWindow=1000000" "$OUT"; then pass "minified bare deepseek-pro flagged"; else fail "minified bare deepseek-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-proxy" "$OUT"; then fail "minified negative control deepseek-proxy was flagged"; else pass "minified deepseek-proxy (non-family) not flagged"; fi
if grep -q "deepseek-flashlight" "$OUT"; then fail "minified negative control deepseek-flashlight was flagged"; else pass "minified deepseek-flashlight (non-family) not flagged"; fi

echo ""
echo "9. MINIFIED clean models.json (300K clamp) → PASS, exit 0"
run_guard 0 "clean-minified" --live-dir "$FIX/clean-minified"
if grep -q "✅ cost-config guard: PASS" "$OUT"; then pass "summary PASS"; else fail "expected PASS summary"; tail -20 "$OUT"; fi

echo ""
echo "10. missing SHIPPED models.json → BLOCK, exit 1 (clamp authority deleted)"
TMP_ROOT="$(mktemp -d /tmp/cost-config-missing.XXXXXX)"
mkdir -p "$TMP_ROOT/scripts"
cp "$GUARD" "$TMP_ROOT/scripts/check-cost-config.sh"
mkdir -p "$TMP_ROOT/pi-bootstrap/pi-config"
cp "$FIX/missing-models/models-store.json" "$FIX/missing-models/settings.json" "$TMP_ROOT/pi-bootstrap/pi-config/"
bash "$TMP_ROOT/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "missing shipped models.json → exit 1"; else fail "expected exit 1, got $code"; tail -20 "$OUT"; fi
if grep -q "file missing" "$OUT"; then pass "missing-file block reported"; else fail "expected missing-file message"; tail -20 "$OUT"; fi
rm -rf "$TMP_ROOT"

echo ""
echo "11. missing LIVE models.json (first-install path) → WARN, exit 0"
run_guard 0 "missing-live-models" --live-dir "$FIX/missing-models"
if grep -q "file missing" "$OUT"; then pass "live missing reported as warn"; else fail "expected missing-file warn"; tail -20 "$OUT"; fi
if grep -q "BLOCK-level violation" "$OUT"; then fail "live missing must NOT block"; else pass "live missing is warn-only"; fi

echo ""
echo "12. compaction.enabled=false → BLOCK, exit 1"
run_guard 1 "backdoor-compaction-disabled" --live-dir "$FIX/backdoor-compaction-disabled"
if grep -q "compaction.enabled expected true" "$OUT"; then pass "compaction.enabled drift flagged"; else fail "expected enabled message"; tail -20 "$OUT"; fi

echo ""
echo "13. clean fixtures mirror the shipped tree (parity pin)"
python3 - "$ROOT/pi-bootstrap/pi-config" "$FIX/clean" <<'PY'
import json, sys, os
shipped, clean = sys.argv[1:3]
for f in ("models.json", "settings.json", "models-store.json"):
    if json.load(open(os.path.join(shipped, f))) != json.load(open(os.path.join(clean, f))):
        sys.exit(1)
sys.exit(0)
PY
if [ $? -eq 0 ]; then pass "clean mirrors shipped (models.json + settings.json + models-store.json)"; else fail "clean fixtures diverge from shipped — regenerate them"; fi
python3 - "$FIX/clean" "$FIX/clean-minified" <<'PY'
import json, sys, os
clean, mini = sys.argv[1:3]
for f in ("models.json", "settings.json", "models-store.json"):
    if json.load(open(os.path.join(clean, f))) != json.load(open(os.path.join(mini, f))):
        sys.exit(1)
sys.exit(0)
PY
if [ $? -eq 0 ]; then pass "clean-minified mirrors clean (canonical JSON)"; else fail "clean-minified diverges from clean"; fi
# The minified twins must actually BE minified — tests 8/9 claim to cover the
# format-independence path, and pretty-printing them would silently turn those
# into duplicates of tests 1/2.
for f in clean-minified/models.json clean-minified/settings.json clean-minified/models-store.json \
         backdoor-minified/models.json backdoor-minified/settings.json backdoor-minified/models-store.json; do
  if [ "$(tr -cd '\n' <"$FIX/$f" | wc -c)" -eq 0 ]; then pass "$f is single-line (minified)"; else fail "$f is not minified — tests 8/9 would be vacuous"; fi
done
for d in backdoor-settings backdoor-retry backdoor-compaction-disabled backdoor-store; do
  python3 - "$FIX/clean/models.json" "$FIX/$d/models.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
PY
  if [ $? -eq 0 ]; then pass "$d models.json untouched (its defect lives elsewhere)"; else fail "$d models.json drifted from clean — its one injected defect must live in settings.json/models-store.json"; fi
done

echo ""
echo "14. fixture invariants: bounded per-tree delta + non-vacuous controls"
python3 - "$FIX" "$CLAMP_EXPECTED" <<'PY' >"$OUT" 2>&1
import json, os, re, sys, hashlib

fix, clamp = sys.argv[1], int(sys.argv[2])
DS = re.compile(r'^deepseek-(?:v4(?:\.\d+)?-)?(?:flash|pro)(?:[-:]|$)')

def norm(i):
    return re.sub(r'^~?[^/]*/', '', i) if '/' in i else i

def scanned(node):
    """Normalized id -> MAX effective contextWindow across every row the guard
    scans: model entries with a co-located id+contextWindow, and
    modelOverrides-style keys. Max (not first) so a 1M control row cannot be
    masked by an under-clamp row for the same normalized id."""
    found = {}
    def note(k, ctx):
        n = norm(k)
        if n not in found or ctx > found[n]:
            found[n] = ctx
    def walk(n):
        if isinstance(n, dict):
            if isinstance(n.get('id'), str) and isinstance(n.get('contextWindow'), int):
                note(n['id'], n['contextWindow'])
            for k, v in n.items():
                if isinstance(v, dict) and isinstance(v.get('contextWindow'), int):
                    note(k, v['contextWindow'])
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(node)
    return found

def sdiff(a, b, p=""):
    """Structural diff: records added/removed keys and container changes, so an
    added empty object/array cannot hide from a leaf-only comparison."""
    out = set()
    if type(a) is not type(b):
        return {p}
    if isinstance(a, dict):
        for k in set(a) | set(b):
            if k not in a or k not in b:
                out.add(f"{p}.{k}")
            else:
                out |= sdiff(a[k], b[k], f"{p}.{k}")
    elif isinstance(a, list):
        if len(a) != len(b):
            out.add(p)
        for i, (x, y) in enumerate(zip(a, b)):
            out |= sdiff(x, y, f"{p}[{i}]")
    elif a != b:
        out.add(p)
    return out



def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    return 0 if cond else 1

fails = 0
files = ("models.json", "settings.json", "models-store.json")
raw = {t: {f: json.load(open(os.path.join(fix, t, f))) for f in files}
       for t in ("clean", "backdoor-settings", "backdoor-retry",
                 "backdoor-compaction-disabled", "backdoor-store",
                 "backdoor-models", "backdoor-minified")}
clean = raw["clean"]

# Each backdoor tree must differ from clean in EXACTLY its one injected defect.
# models: "same" | "control-bumped" | "differs"; settings: exact structural
# delta set; store: "same" | "snapshot".
EXPECTED = {
    "backdoor-settings": ("same", {".compaction"}, "same"),
    "backdoor-retry": ("same", {".retry.maxRetries"}, "same"),
    "backdoor-compaction-disabled": ("same", {".compaction.enabled"}, "same"),
    "backdoor-store": ("same", set(), "snapshot"),
    "backdoor-models": ("control-bumped", set(), "same"),
    "backdoor-minified": ("control-bumped", set(), "same"),
}

# The only allowed models.json delta in the control trees: the three clean
# deepseek rows bumped to 1M, plus the appended control rows. Any other id,
# cost, name or container change must fail.
CONTROL_IDS = ["deepseek-v4.1-flash", "deepseek-v4.1-flash-expires-on-0910",
               "deepseek-v4-pro:batch", "deepseek-flash:batch", "deepseek-pro",
               "deepseek-proxy", "deepseek-flashlight"]
CLEAN_IDS = [m["id"] for m in clean["models.json"]["providers"]["deepseek"]["models"]]
MODELS_BOUND = {".providers.deepseek.models"} | {
    f".providers.deepseek.models[{i}].contextWindow" for i in range(len(CLEAN_IDS))}
# The store tree is a frozen pre-#476 snapshot, so "one defect" there means
# "byte-for-byte the recorded snapshot": shape checks alone let a second
# injected defect (an extra openrouter/qwen-token-plan row) ride green. Pin the
# canonical content hash instead; an intended regeneration must update the pin.
STORE_SNAPSHOT_SHA = "bd7e8e664124c49e26282c63c44d63a73be274c731b5b2af5404ad4d714d58cc"

for tree, (want_models, want_settings, want_store) in EXPECTED.items():
    bad = []
    dm = sdiff(clean["models.json"], raw[tree]["models.json"])
    ds = sdiff(clean["settings.json"], raw[tree]["settings.json"])
    dt = sdiff(clean["models-store.json"], raw[tree]["models-store.json"])
    if want_models == "same" and dm != set():
        bad.append(f"models.json delta {sorted(dm)}")
    elif want_models == "control-bumped":
        if not dm <= MODELS_BOUND:
            bad.append(f"models.json delta outside the control bound: {sorted(dm - MODELS_BOUND)}")
        got_ids = [m["id"] for m in raw[tree]["models.json"]["providers"]["deepseek"]["models"]]
        # Only the clean-rows-first ordering is structural; the control rows'
        # relative order is incidental and must not be over-pinned.
        if got_ids[:len(CLEAN_IDS)] != CLEAN_IDS or sorted(got_ids) != sorted(CLEAN_IDS + CONTROL_IDS):
            bad.append(f"deepseek model ids (clean rows must come first; the control set must "
                       f"match exactly): {got_ids}")
        for i, m in enumerate(raw[tree]["models.json"]["providers"]["deepseek"]["models"][:len(CLEAN_IDS)]):
            cm = clean["models.json"]["providers"]["deepseek"]["models"][i]
            strip = lambda r: {k: v for k, v in r.items() if k != "contextWindow"}
            if strip(m) != strip(cm):
                bad.append(f"deepseek row {m['id']} differs outside contextWindow")
    if ds != want_settings:
        bad.append(f"settings.json delta {sorted(ds)} (want {sorted(want_settings)})")
    if want_store == "same" and dt != set():
        bad.append(f"models-store.json delta {len(dt)} path(s)")
    elif want_store == "snapshot":
        if dt == set():
            bad.append("models-store.json is identical to clean — the pre-#476 snapshot defect is gone")
        blob = json.dumps(raw[tree]["models-store.json"], sort_keys=True, separators=(",", ":"))
        if hashlib.sha256(blob.encode()).hexdigest() != STORE_SNAPSHOT_SHA:
            bad.append("models-store.json content differs from the pinned snapshot — if this is an "
                       "intended regeneration, update STORE_SNAPSHOT_SHA")
    fails += check(not bad,
                   f"{tree} differs from clean only in its documented defect"
                   + (f": {'; '.join(bad)}" if bad else ""))
# The compactment defect must be a MISSING block, not a present-but-wrong one.
sett = raw["backdoor-settings"]["settings.json"]
fails += check(isinstance(sett.get("compaction"), dict) is False,
               "backdoor-settings defect kind is a MISSING compaction block (guard's "
               "not-a-dict branch stays covered)")

# Controls must exist as SCANNED id rows (not just appear somewhere in the file),
# and sit ABOVE the clamp — otherwise the absence assertions prove nothing.
POSITIVE = ["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-flash", "deepseek-v4.1-flash",
            "deepseek-v4.1-flash-expires-on-0910", "deepseek-v4-pro:batch",
            "deepseek-flash:batch", "deepseek-pro"]
NEGATIVE = ["deepseek-proxy", "deepseek-flashlight"]
for tree in ("backdoor-models", "backdoor-minified"):
    ids = scanned(raw[tree]["models.json"])
    miss = [i for i in POSITIVE if i not in ids or ids[i] <= clamp]
    fails += check(not miss,
                   f"{tree} carries every positive control as a scanned id over the clamp"
                   + (f" — missing/under-clamp: {miss}" if miss else ""))
    miss = [i for i in NEGATIVE if i not in ids or ids[i] <= clamp]
    fails += check(not miss,
                   f"{tree} carries every negative control as a scanned id over the clamp "
                   f"(so the matcher really had to reject it)"
                   + (f" — missing/under-clamp: {miss}" if miss else ""))
    wrong = [i for i in NEGATIVE if DS.match(norm(i))]
    fails += check(not wrong, f"{tree} negative controls are genuinely non-matching ids {wrong}")

ids = scanned(raw["backdoor-store"]["models-store.json"])
for ctl in ("deepseek-chat-v3.2", "kimi-k3"):
    fails += check(ids.get(norm(ctl), 0) > clamp and not DS.match(norm(ctl)),
                   f"backdoor-store control {ctl} is a scanned, over-clamp, non-matching row "
                   f"(test 3's absence assertion is meaningful)")
for ctl in ("~deepseek/deepseek-v4-flash-latest", "deepseek-v4-flash-vision-exp"):
    fails += check(ids.get(norm(ctl), 0) > clamp and DS.match(norm(ctl)),
                   f"backdoor-store control {ctl} is a scanned, over-clamp, matching row "
                   f"(test 3's detection assertion is meaningful)")

sys.exit(1 if fails else 0)
PY
py=$?
if grep -q "Traceback" "$OUT"; then fail "test 14 checker crashed — see traceback above"; fi
if ! grep -qE '^(PASS|FAIL) ' "$OUT"; then fail "test 14 checker produced no PASS/FAIL lines (exit $py) — see traceback above"; fi
if [ "$py" -ne 0 ] && ! grep -q '^FAIL ' "$OUT"; then fail "test 14 checker exited $py without a FAIL line"; fi
while IFS= read -r line; do
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
    *) [ -n "$line" ] && echo "      $line" ;;
  esac
done <"$OUT"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All cost-config guard tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
