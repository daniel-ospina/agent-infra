#!/bin/bash
# #341 — cost-config drift-guard tests.
#
# Exercises scripts/check-cost-config.sh semantics:
#   1. clean fixture (deepseek ids @300K clamp)    → PASS (exit 0)
#   2. models.json drift (deepseek id > 300K)      → BLOCK (exit 1)
#      (positive controls: the v4-pro family, the legacy v4-flash alias, the
#      canonical deepseek-flash id + its future bare `deepseek-pro`
#      counterpart, dotted deepseek-v4.1 ids, hyphenated deepseek-v4-1 ids
#      (#747 venice row), `:`-suffixed (routing-tier) shapes;
#      negative controls: deepseek-proxy / deepseek-flashlight — V4.1 Flash
#      adoption 2026-09-10)
#   3. models-store.json drift                     → WARN (exit 0, DETECTED —
#      catalog class must not fail sync; the weekly report + tripwire alert)
#      (also: matcher negatives kimi-k3 + deepseek-chat-v3.2 never flagged;
#      `~deepseek` alias + vision-exp covered)
#   4. settings.json missing compaction block      → BLOCK (exit 1)
#   5. settings.json retry.maxRetries != 7         → BLOCK (exit 1)
#      + the derived retry/hang window (#1088): the guard asserts the exact
#      contract values AND the window computed from them + patch-pi-retry.sh's
#      backoff cap, so guard / settings / patch / doc cannot disagree.
#  15. derived window: guard constants vs independent recomputation (ship-tree)
#  16. DERIVED check in isolation: constants and settings both moved to 8
#      retries (exact-value checks green) → window ceiling still BLOCKs
#  17. patch-pi-retry.sh cap drift (60000 → 300000) → BLOCK
#  18. patch-pi-retry.sh absent → fail-closed BLOCK (window uncomputable)
#  19. policy doc §2 carries the same numbers as the guard (doc↔guard pin)
#  20. COST_CLAMP_OVERRIDE=1 does NOT silence a retry-contract block
#  21. project settings (.pi/settings.json) touching retry/httpIdleTimeoutMs → BLOCK
#  22. COST_CLAMP_OVERRIDE=1 does NOT silence a MISSING or UNPARSEABLE settings
#      file either (a deleted/corrupt file is not a clamp rollback)
#  23. project settings are resolved from the SESSION cwd, so a NESTED
#      `<subdir>/.pi/settings.json` is caught too (sibling worktrees are not)
#  24. patch-pi-retry.sh idempotency/normalization over a fake pi tree:
#      pristine → patched, re-run → byte-identical, stale-comment + wrong cap →
#      rewritten, changed upstream shape → loud failure (never a silent no-op)
#  25. no doc states a stale retry/hang number (the duplicate-drift pin — three
#      copies of the idle value drifted exactly this way twice in review)
#  26. COST_CLAMP_OVERRIDE=1 does NOT silence the compaction/settings class
#      either (the escape is for the models.json clamp rollback window only)
#  27. a non-integer settings value must not skip the derived-window check
#      (a zeroed WINDOW sentinel used to read as "window present" → PASS)
#  28. a project settings file at ANY depth is caught (no depth cap), including
#      a nested `.pi`-in-`.pi` (a session cwd can be inside `.pi`)
#  29. the backoff cap is read from the REAL assignment in patch-pi-retry.sh,
#      not from an earlier assignment-shaped comment
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

# Same discipline for the #1088 retry/hang contract: every one of these is read
# back out of the guard so tests 15-19 cannot be satisfied by a stale copy.
for _c in RETRY_MAX_RETRIES HTTP_IDLE_TIMEOUT_MS RETRY_BASE_DELAY_MS \
          RETRY_MAX_BACKOFF_MS RETRY_PROVIDER_TIMEOUT_MS \
          HANG_WINDOW_CEILING_MS WORST_WINDOW_CEILING_MS; do
  if ! sed -n "s/^${_c}=\([0-9][0-9]*\)$/\1/p" "$GUARD" | head -1 | grep -q .; then
    echo "❌ could not read ${_c}= from $GUARD — the retry-contract assertions need it."
    exit 1
  fi
done

# Test 24-25 need the contract constants as VALUES (the loop above only
# presence-checks them).
CAP_GUARD="$(sed -n 's/^RETRY_MAX_BACKOFF_MS=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"
HTTP_IDLE_TIMEOUT_MS_G="$(sed -n 's/^HTTP_IDLE_TIMEOUT_MS=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"
RETRY_PROVIDER_TIMEOUT_MS_G="$(sed -n 's/^RETRY_PROVIDER_TIMEOUT_MS=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"
RETRY_MAX_RETRIES_G="$(sed -n 's/^RETRY_MAX_RETRIES=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"
RETRY_BASE_DELAY_MS_G="$(sed -n 's/^RETRY_BASE_DELAY_MS=\([0-9][0-9]*\)$/\1/p' "$GUARD" | head -1)"

# mkroot <dir> — a self-contained guard root (guard + patch script + configs)
# so mutation tests can perturb one input without touching the repo.
mkroot() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/pi-bootstrap/pi-config"
  cp "$GUARD" "$root/scripts/check-cost-config.sh"
  cp "$ROOT/scripts/patch-pi-retry.sh" "$root/scripts/patch-pi-retry.sh"
  cp "$FIX/clean/models.json" "$FIX/clean/models-store.json" "$FIX/clean/settings.json" \
     "$root/pi-bootstrap/pi-config/"
}

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
if grep -q "deepseek-v4-1-flash contextWindow=1000000" "$OUT"; then pass "hyphenated v4-1 family flagged (#747)"; else fail "deepseek-v4-1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
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
echo "5. settings.json retry.maxRetries != 7 → BLOCK, exit 1"
run_guard 1 "backdoor-retry" --live-dir "$FIX/backdoor-retry"
if grep -q "retry.maxRetries expected 7" "$OUT"; then pass "retry drift flagged"; else fail "expected retry message"; tail -20 "$OUT"; fi

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
if grep -q "deepseek-v4-1-flash contextWindow=1000000" "$OUT"; then pass "minified hyphenated v4-1 family flagged (#747)"; else fail "minified deepseek-v4-1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
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
DS = re.compile(r'^deepseek-(?:v4(?:[.\-]\d+)?-)?(?:flash|pro)(?:[-:]|$)')

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
               "deepseek-proxy", "deepseek-flashlight", "deepseek-v4-1-flash"]
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
            "deepseek-flash:batch", "deepseek-pro", "deepseek-v4-1-flash"]
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
echo "15. derived retry/hang window — guard constants vs independent arithmetic"
bash "$GUARD" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "ship-tree guard run exits 0"; else fail "ship-tree guard run expected exit 0, got $code"; sed -n '1,40p' "$OUT"; fi
python3 - "$GUARD" "$OUT" "$ROOT/pi-bootstrap/pi-config/settings.json" >"$OUT.window" 2>&1 <<'PY'
import json, re, sys
guard_src = open(sys.argv[1]).read()
out = open(sys.argv[2]).read()
settings = json.load(open(sys.argv[3]))

def const(name):
    m = re.search(rf'^{name}=(\d+)$', guard_src, re.M)
    return int(m.group(1)) if m else None

n = const("RETRY_MAX_RETRIES"); idle = const("HTTP_IDLE_TIMEOUT_MS")
base = const("RETRY_BASE_DELAY_MS"); cap = const("RETRY_MAX_BACKOFF_MS")
ptimeout = const("RETRY_PROVIDER_TIMEOUT_MS")
hangceil = const("HANG_WINDOW_CEILING_MS"); worstceil = const("WORST_WINDOW_CEILING_MS")
assert all(v is not None for v in (n, idle, base, cap, ptimeout, hangceil, worstceil)), \
    "guard retry-contract constants are missing"

# Coupling 1: the SHIPPED settings values must equal the guard's pinned values.
assert settings["retry"]["maxRetries"] == n, "shipped maxRetries != guard RETRY_MAX_RETRIES"
assert settings["httpIdleTimeoutMs"] == idle, "shipped httpIdleTimeoutMs != guard HTTP_IDLE_TIMEOUT_MS"
assert settings["retry"]["baseDelayMs"] == base, "shipped baseDelayMs != guard RETRY_BASE_DELAY_MS"
assert settings["retry"]["provider"]["timeoutMs"] == ptimeout, \
    "shipped provider.timeoutMs != guard RETRY_PROVIDER_TIMEOUT_MS"

# Coupling 2: independent recomputation of the window the guard claims to enforce.
# Closed form (NOT the guard's loop) so a bug in the guard's `while`/`break`
# arithmetic cannot be reproduced identically on both sides (#1088 review P2).
backoff = sum(min(base * 2 ** i, cap) for i in range(n))
hang = (n + 1) * idle + backoff
worst = (n + 1) * ptimeout + backoff
m = re.search(r'hung (\d+)ms / worst (\d+)ms', out)
assert m, "the guard's PASS line did not report the derived window"
gh, gw = map(int, m.groups())
assert (gh, gw) == (hang, worst), \
    f"guard window {gh}/{gw} != independently computed {hang}/{worst}"

# Coupling 3: the declared ceilings actually bind the recomputed window.
assert hang <= hangceil, f"hang window {hang}ms exceeds declared ceiling {hangceil}ms"
assert worst <= worstceil, f"worst window {worst}ms exceeds declared ceiling {worstceil}ms"
# Coupling 4: the silent-hang ceiling must fire before the per-call ceiling.
assert ptimeout > idle, "per-call ceiling must exceed the idle (silent-hang) ceiling"
print(f"OK {n} retries, idle {idle}ms, cap {cap}ms -> hung {hang}ms ({hang/60000:.1f} min) "
      f"<= {hangceil}ms; worst {worst}ms ({worst/60000:.1f} min) <= {worstceil}ms")
PY
if [ $? -eq 0 ]; then pass "$(cat "$OUT.window")"; else fail "window derivation mismatch: $(cat "$OUT.window")"; fi
rm -f "$OUT.window"

echo ""
echo "16. DERIVED check in isolation — constants and settings both at 8 retries"
# The exact-value checks must stay green here: what fires is the window ceiling.
# This is the check the pre-#1088 guard lacked (it pinned the count alone).
TMP16="$(mktemp -d /tmp/cost-config-window.XXXXXX)"
mkroot "$TMP16"
python3 - "$TMP16/scripts/check-cost-config.sh" "$TMP16/pi-bootstrap/pi-config/settings.json" <<'PY'
import json, sys
g, s = sys.argv[1], sys.argv[2]
src = open(g).read()
assert "RETRY_MAX_RETRIES=7" in src, "guard constant shape changed — update this test"
open(g, "w").write(src.replace("RETRY_MAX_RETRIES=7", "RETRY_MAX_RETRIES=8"))
d = json.load(open(s)); d["retry"]["maxRetries"] = 8
open(s, "w").write(json.dumps(d, indent=2) + "\n")
PY
bash "$TMP16/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "aligned 8-retry constant still BLOCKs (window over ceiling)"; else fail "expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -qE 'hang window [0-9]+ms.*exceeds the declared ceiling' "$OUT"; then pass "hang-window ceiling message present"; else fail "expected the hang-window ceiling message (not the worst-case one)"; sed -n '1,30p' "$OUT"; fi
if grep -q "maxRetries expected" "$OUT"; then fail "the exact-value check fired — test 16 must isolate the DERIVED check"; else pass "exact-value checks stayed green (derived check is what fired)"; fi
rm -rf "$TMP16"

echo ""
echo "17. patch-pi-retry.sh backoff cap drift → BLOCK (guard↔patch coupling)"
TMP17="$(mktemp -d /tmp/cost-config-patchcap.XXXXXX)"
mkroot "$TMP17"
python3 - "$TMP17/scripts/patch-pi-retry.sh" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "PI_MAX_RETRY_DELAY_MS:-60000"
assert needle in src, "patch cap default shape changed — update this test"
open(p, "w").write(src.replace(needle, "PI_MAX_RETRY_DELAY_MS:-300000"))
PY
bash "$TMP17/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "cap drift → exit 1"; else fail "expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q "backoff cap expected 60000, got 300000" "$OUT"; then pass "cap-drift message present"; else fail "expected the cap-drift message"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP17"

echo ""
echo "18. patch-pi-retry.sh absent → fail-closed BLOCK (window uncomputable)"
TMP18="$(mktemp -d /tmp/cost-config-nopatch.XXXXXX)"
mkroot "$TMP18"
rm -f "$TMP18/scripts/patch-pi-retry.sh"
bash "$TMP18/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "missing patch script → exit 1"; else fail "expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q "backoff cap unreadable" "$OUT"; then pass "fail-closed message present"; else fail "expected the fail-closed message"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP18"

echo ""
echo "19. policy doc §2 carries the guard's contract numbers (doc↔guard pin)"
python3 - "$GUARD" "$ROOT/docs/ops/cost-config-policy.md" >"$OUT" 2>&1 <<'PY'
import re, sys
guard_src = open(sys.argv[1]).read()
doc = open(sys.argv[2]).read()

def const(name):
    m = re.search(rf'^{name}=(\d+)$', guard_src, re.M)
    return m.group(1) if m else None

m = re.search(r'^## 2\..*?^(?=## )', doc, re.M | re.S)
assert m, "§2 not found in docs/ops/cost-config-policy.md"
sec2 = m.group(0)

pairs = [("retry.maxRetries", const("RETRY_MAX_RETRIES")),
         ("httpIdleTimeoutMs", const("HTTP_IDLE_TIMEOUT_MS")),
         ("retry.baseDelayMs", const("RETRY_BASE_DELAY_MS")),
         ("retry.provider.timeoutMs", const("RETRY_PROVIDER_TIMEOUT_MS"))]
# Require the exact table CELL, not the value anywhere on the line: a substring
# match false-passes on `| retry.maxRetries | 7 | 8 attempts ... |` when the
# guard moves to 8 (the 8 in the description cell satisfies it). #1088 review P2.
table_rows = [ln for ln in sec2.splitlines() if ln.strip().startswith("|")]
for key, val in pairs:
    assert any(re.search(rf"\|\s*`{re.escape(key)}`\s*\|\s*`{val}`\s*\|", ln)
               for ln in table_rows), \
        f"§2 has no table row `{key}` | `{val}`"
cap = const("RETRY_MAX_BACKOFF_MS")
assert any(re.search(rf"\|[^\n]*patch-pi-retry\.sh[^\n]*\|\s*`{cap}`\s*\|", ln) for ln in table_rows), \
    f"§2 must tie the {cap}ms backoff cap to patch-pi-retry.sh in a table row"
ceiling_min = str(int(const("HANG_WINDOW_CEILING_MS")) // 60000)
assert f"{ceiling_min}-minute" in sec2, f"§2 must state the {ceiling_min}-minute hang-window ceiling"
assert "#1088" in sec2, "§2 must cite issue #1088"
# §2 is the SINGLE SOURCE for the derived durations — test 25 bans them from the
# summary docs, so nothing else would notice if §2's own numbers went stale.
_n = int(const("RETRY_MAX_RETRIES")); _idle = int(const("HTTP_IDLE_TIMEOUT_MS"))
_base = int(const("RETRY_BASE_DELAY_MS")); _cap = int(cap)
_ptimeout = int(const("RETRY_PROVIDER_TIMEOUT_MS"))
backoff = sum(min(_base * 2 ** i, _cap) for i in range(_n))
hang = (_n + 1) * _idle + backoff
worst = (_n + 1) * _ptimeout + backoff
for form, label in ((f"{hang:,} ms", "no-progress window (ms)"),
                    (f"{hang / 60000:.1f} min", "no-progress window (min)"),
                    (f"{worst:,} ms", "worst-case window (ms)"),
                    (f"{worst / 60000:.0f} min", "worst-case window (min)"),
                    (f"{backoff // 1000} s", "transient ladder (s)")):
    assert form in sec2, f"§2 must state the derived {label} ({form!r})"
worst_ceiling_min = str(int(const("WORST_WINDOW_CEILING_MS")) // 60000)
assert f"{worst_ceiling_min}-minute" in sec2, \
    f"§2 must state the {worst_ceiling_min}-minute worst-case ceiling"
print(f"OK §2 pins maxRetries={const('RETRY_MAX_RETRIES')}, idle={const('HTTP_IDLE_TIMEOUT_MS')}, "
      f"cap={cap} (patch-pi-retry.sh), ceiling={ceiling_min} min, cites #1088")
PY
if [ $? -eq 0 ]; then pass "$(cat "$OUT")"; else fail "doc↔guard coupling broken: $(cat "$OUT")"; fi

echo ""
echo "20. COST_CLAMP_OVERRIDE=1 must NOT silence a retry-contract block (bypass pin)"
TMP20="$(mktemp -d /tmp/cost-config-override.XXXXXX)"
mkroot "$TMP20"
python3 - "$TMP20/pi-bootstrap/pi-config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["retry"]["maxRetries"] = 9
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
COST_CLAMP_OVERRIDE=1 bash "$TMP20/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "override set + retry drift → still exit 1"; else fail "expected exit 1 under the override, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q "does NOT cover" "$OUT"; then pass "carve-out notice present"; else fail "expected the override carve-out notice"; sed -n '1,30p' "$OUT"; fi
# and the clamp class is STILL silenced by the override (the escape keeps working)
COST_CLAMP_OVERRIDE=1 bash "$GUARD" --live-dir "$FIX/backdoor-models" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "clamp-class block still silenced by the override"; else fail "clamp override regressed — expected exit 0, got $code"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP20"

echo ""
echo "21. project settings (.pi/settings.json) touching the contract → BLOCK"
TMP21="$(mktemp -d /tmp/cost-config-projsettings.XXXXXX)"
mkroot "$TMP21"
mkdir -p "$TMP21/.pi"
echo '{"theme":"dark"}' >"$TMP21/.pi/settings.json"
bash "$TMP21/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "project settings without contract keys → exit 0"; else fail "expected exit 0, got $code"; sed -n '1,30p' "$OUT"; fi
echo '{"retry":{"maxRetries":3}}' >"$TMP21/.pi/settings.json"
bash "$TMP21/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "project settings reverting the contract → exit 1"; else fail "expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q "project settings" "$OUT" && grep -q "overrides the settings contract" "$OUT"; then pass "project-settings block message present"; else fail "expected the project-settings message"; sed -n '1,30p' "$OUT"; fi
# an unparseable project settings file must fail closed too
printf '{ not json' >"$TMP21/.pi/settings.json"
bash "$TMP21/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "unparseable project settings → exit 1 (fail-closed)"; else fail "expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
# ...and so must a compaction-only project file: `compaction` is settings-class,
# which this PR made override-immune, so a project file reverting it is the SAME
# defect class as reverting `retry` (cycle-5 review P1: `compaction` was not in
# the key tuple, so the guard reported "does not touch the retry contract").
echo '{"compaction":{"enabled":false,"reserveTokens":4096}}' >"$TMP21/.pi/settings.json"
bash "$TMP21/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "compaction-only project settings → exit 1"; else fail "expected exit 1 for a compaction-only project settings file, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q 'compaction' "$OUT"; then pass "the block names the offending key"; else fail "expected 'compaction' named in the block"; sed -n '1,30p' "$OUT"; fi
COST_CLAMP_OVERRIDE=1 bash "$TMP21/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "compaction-only project settings + override → still exit 1"; else fail "expected exit 1 under the override, got $code"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP21"

echo ""
echo "22. COST_CLAMP_OVERRIDE=1 must NOT silence a MISSING/unparseable settings file"
TMP22="$(mktemp -d /tmp/cost-config-override-absence.XXXXXX)"
mkroot "$TMP22"
rm -f "$TMP22/pi-bootstrap/pi-config/settings.json"
COST_CLAMP_OVERRIDE=1 bash "$TMP22/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "deleted settings file + override → still exit 1 (deleted != clamp rollback)"
else
  fail "expected exit 1 for a deleted settings file under the override, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q "does NOT cover" "$OUT"; then pass "carve-out notice present (deleted file)"; else fail "expected the override carve-out notice"; sed -n '1,30p' "$OUT"; fi
printf '{ not json' >"$TMP22/pi-bootstrap/pi-config/settings.json"
COST_CLAMP_OVERRIDE=1 bash "$TMP22/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "unparseable settings file + override → still exit 1 (fail-closed, not a clamp rollback)"
else
  fail "expected exit 1 for an unparseable settings file under the override, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q "the retry/hang contract cannot be asserted" "$OUT"; then pass "unparseable-settings fail-closed message present"; else fail "expected the unparseable-settings message"; sed -n '1,30p' "$OUT"; fi
# Valid JSON that is NOT an object: `d.get(...)` used to raise AttributeError, whose
# traceback reached the issue loop as an untagged line → plain block() → the override
# silenced it (cycle-3 P1).
printf '[1,2,3]' >"$TMP22/pi-bootstrap/pi-config/settings.json"
COST_CLAMP_OVERRIDE=1 bash "$TMP22/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "non-object settings JSON + override → still exit 1 (fail-closed)"
else
  fail "expected exit 1 for non-object settings JSON under the override, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q "is not a JSON object" "$OUT"; then pass "non-object diagnostic names the shape (no raw traceback)"; else fail "expected the 'is not a JSON object' diagnostic"; sed -n '1,30p' "$OUT"; fi
if grep -q 'Traceback' "$OUT"; then fail "a raw Python traceback reached the user"; else pass "no raw traceback in the output"; fi
rm -rf "$TMP22"

echo ""
echo "23. NESTED project settings (pi resolves <session-cwd>/.pi/settings.json) → BLOCK"
TMP23="$(mktemp -d /tmp/cost-config-projsettings-nested.XXXXXX)"
mkroot "$TMP23"
mkdir -p "$TMP23/extensions/.pi" "$TMP23/.worktrees/other/.pi"
echo '{"theme":"dark"}' >"$TMP23/extensions/.pi/settings.json"
echo '{"theme":"light"}' >"$TMP23/.worktrees/other/.pi/settings.json"
bash "$TMP23/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then
  pass "nested non-contract project files scanned → exit 0"
else
  fail "expected exit 0, got $code"; sed -n '1,30p' "$OUT"
fi
scanned="$(grep -c "does not touch the retry/compaction contract" "$OUT")"
if [ "$scanned" -eq 2 ]; then pass "both nested project files were walked (subdir + .worktrees)"; else fail "expected 2 walked project files, saw $scanned — the walk missed one"; sed -n '1,30p' "$OUT"; fi
echo '{"retry":{"maxRetries":3}}' >"$TMP23/extensions/.pi/settings.json"
bash "$TMP23/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "nested project settings reverting the contract → exit 1"
else
  fail "expected exit 1 for a nested project settings file, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q "extensions/.pi/settings.json" "$OUT"; then pass "the offending path is named in the block"; else fail "expected the nested path in the message"; sed -n '1,30p' "$OUT"; fi
# `.worktrees/` is gitignored but IS a live session cwd — an untracked project file
# there must not be invisible to the guard (cycle-3 review).
echo '{"theme":"dark"}' >"$TMP23/extensions/.pi/settings.json"
echo '{"retry":{"maxRetries":10000}}' >"$TMP23/.worktrees/other/.pi/settings.json"
bash "$TMP23/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "contract-reverting project file under .worktrees/ → exit 1 (not pruned)"
else
  fail "expected exit 1 for a .worktrees project settings file, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q "worktrees/other/.pi/settings.json" "$OUT"; then pass "the .worktrees path is named in the block"; else fail "expected the .worktrees path in the message"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP23"

echo ""
echo "24. patch-pi-retry.sh shapes over a fake pi tree (idempotency + normalization)"
TMP24="$(mktemp -d /tmp/patch-pi-retry.XXXXXX)"
PKG="$TMP24/node-v99/lib/node_modules/@earendil-works/pi-coding-agent"
PI_AI_DIR="$PKG/node_modules/@earendil-works/pi-ai/dist/utils"
mkdir -p "$PKG/dist/core" "$PI_AI_DIR" "$TMP24/bin"
# A `pi` on PATH that resolves to no package forces find_pi_pkg's $PI_NODE_ROOT
# fallback onto the fake tree. The pristine targets must EXIST before that call —
# the node-root glob requires `dist/core/agent-session.js`, and without it the
# search falls through to `npm root -g` (the real install).
printf '#!/bin/sh\nexit 0\n' >"$TMP24/bin/pi"; chmod +x "$TMP24/bin/pi"
CAP="$CAP_GUARD"
pristine() {
  printf 'function f() {\n        const delayMs = settings.baseDelayMs * 2 ** (this._retryAttempt - 1);\n}\n' >"$PKG/dist/core/agent-session.js"
  printf 'function g() {\n        const delayMs = policy.baseDelayMs * 2 ** (attempt - 1);\n}\n' >"$PI_AI_DIR/retry.js"
}
pristine
PATHS="$(PATH="$TMP24/bin:$PATH" PI_NODE_ROOT="$TMP24" bash "$ROOT/scripts/patch-pi-retry.sh" --paths 2>/dev/null)"
if [ "$(printf '%s\n' "$PATHS" | head -1)" = "$PKG" ]; then
  pass "--paths resolves the fake tree (never the real installed pi)"
else
  fail "fake-tree resolution failed — refusing to run the patch (would touch the real pi): $PATHS"
fi

run_patch() { PATH="$TMP24/bin:$PATH" PI_NODE_ROOT="$TMP24" bash "$ROOT/scripts/patch-pi-retry.sh" >"$OUT" 2>&1; }
if [ "$(printf '%s\n' "$PATHS" | head -1)" = "$PKG" ]; then
  # (a) pristine → both files patched at the guard's cap
  pristine; run_patch; code=$?
  if [ "$code" -eq 0 ]; then pass "pristine shape → exit 0"; else fail "pristine patch run failed (exit $code)"; sed -n '1,20p' "$OUT"; fi
  if grep -qF "const delayMs = Math.min(settings.baseDelayMs * 2 ** (this._retryAttempt - 1), ${CAP});" "$PKG/dist/core/agent-session.js" \
     && grep -qF "const delayMs = Math.min(policy.baseDelayMs * 2 ** (attempt - 1), ${CAP});" "$PI_AI_DIR/retry.js"; then
    pass "both targets capped at the guard's ${CAP}ms (guard↔patch coupling)"
  else fail "applied cap does not match the guard's ${CAP}ms"; sed -n '1,20p' "$OUT"; fi
  if grep -q 'bounded retry (#318/#1088)' "$PKG/dist/core/agent-session.js"; then pass "the new comment token is in the dist"; else fail "COMMENT_TOKEN missing after patch"; fi
  # (b) re-run → byte-identical (the fast path still fires after the rewrite)
  cp "$PKG/dist/core/agent-session.js" "$TMP24/snap.js"
  run_patch; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$TMP24/snap.js" "$PKG/dist/core/agent-session.js"; then
    pass "re-run is byte-identical (idempotent fast path intact)"
  else fail "re-run was not idempotent (exit $code)"; sed -n '1,20p' "$OUT"; fi
  if grep -q 'already patched' "$OUT"; then pass "fast path reported (no redundant re-patch)"; else fail "expected the already-patched fast path"; sed -n '1,20p' "$OUT"; fi
  # (c) an earlier version's install: marker present, stale comment, wrong cap
  pristine
  printf 'function f() {\n        // agent-infra offline-resume patch: cap the exponential backoff.\n        // bounded by settings.retry.maxRetries.\n        const delayMs = Math.min(settings.baseDelayMs * 2 ** (this._retryAttempt - 1), 300000);\n}\n' >"$PKG/dist/core/agent-session.js"
  run_patch; code=$?
  if [ "$code" -eq 0 ]; then pass "stale-comment + wrong-cap shape → exit 0"; else fail "normalization run failed (exit $code)"; sed -n '1,20p' "$OUT"; fi
  if grep -qF ", ${CAP});" "$PKG/dist/core/agent-session.js" && ! grep -q '300000' "$PKG/dist/core/agent-session.js"; then
    pass "stale cap 300000 rewritten to the guard's ${CAP}ms"
  else fail "stale cap was not normalized"; sed -n '1,20p' "$PKG/dist/core/agent-session.js"; fi
  if grep -qF 'patch: cap the exponential backoff.' "$PKG/dist/core/agent-session.js"; then fail "stale comment text survived the normalization"; else pass "stale comment replaced with the current token"; fi
  # (d) a genuinely changed upstream shape → loud failure, never a silent no-op
  pristine
  sed 's/this\._retryAttempt/this.retryAttempt/' "$PKG/dist/core/agent-session.js" >"$TMP24/changed.js" \
    && mv "$TMP24/changed.js" "$PKG/dist/core/agent-session.js"
  sed 's/(attempt - 1)/(attemptNumber - 1)/' "$PI_AI_DIR/retry.js" >"$TMP24/changed2.js" \
    && mv "$TMP24/changed2.js" "$PI_AI_DIR/retry.js"
  run_patch; code=$?
  if [ "$code" -ne 0 ]; then pass "changed upstream shape → non-zero exit ($code)"; else fail "a changed upstream shape exited 0 — silent no-op"; sed -n '1,20p' "$OUT"; fi
  if grep -q 'patch target not found' "$OUT"; then pass "changed shape fails loudly with the upgrade diagnostic"; else fail "expected the 'patch target not found' diagnostic"; sed -n '1,20p' "$OUT"; fi
fi
rm -rf "$TMP24"

echo ""
echo "25. no doc states a stale retry/hang number (duplicate-drift pin)"
python3 - "$ROOT" "$CLAMP_EXPECTED" "$HTTP_IDLE_TIMEOUT_MS_G" "$RETRY_PROVIDER_TIMEOUT_MS_G" "$CAP_GUARD" \
         "$RETRY_MAX_RETRIES_G" "$RETRY_BASE_DELAY_MS_G" <<'PY' >"$OUT" 2>&1
import os, re, sys
root, clamp, idle, prov, cap, n, base = sys.argv[1:8]
IDLE, PROV, CAP, N, BASE = int(idle), int(prov), int(cap), int(n), int(base)
# The derived windows, recomputed in closed form from the guard's constants (the
# same independent arithmetic test 15 uses) so a doc that restates one of them
# wrongly fails here instead of drifting green.
BACKOFF = sum(min(BASE * 2 ** i, CAP) for i in range(N))
HANG_MS = (N + 1) * IDLE + BACKOFF
WORST_MS = (N + 1) * PROV + BACKOFF

# Rule 4: the derived durations are SINGLE-SOURCED in the policy doc, and the
# docs that summarise the contract must not restate them. This replaced a
# regex prose-parser that produced both false blocks (a reverse pattern bridged
# a comma into the next phrase's number) and false passes (a continuation-line
# restatement was unreachable) — #1088 review. A figure the summary docs never
# state cannot drift; §2's own table is pinned by test 19.
# Built FROM the guard's constants, so the ban cannot itself go stale when the
# contract changes: restating a duration in a summary doc is the defect, whatever
# the duration currently is. The two trailing phrase forms catch a restatement
# carrying a WRONG number ("...window is ~40 min"), which the literals cannot.
# Durations are matched as PATTERNS, not literals: a copy-paste of §2's own
# rendering ("43.0 min", "43 minutes", "~43-minute") must not slip past a ban
# that only knows "43 min". Millisecond forms are matched in both plain and
# comma-grouped spellings. The two phrase forms catch a restatement carrying a
# WRONG number, which no value-derived pattern can.
def _dur(ms, unit="min"):
    """Match a prose duration: "43 min" / "43.0 min" / "43-minute" / "182 s"."""
    v = int(ms / 60000) if unit == "min" else int(ms / 1000)
    tail = r"min(?:ute)?s?" if unit == "min" else r"sec(?:ond)?s?"
    return re.compile(rf"(?<![\d.]){v}(?:\.\d+)?[\s-]*{tail}\b")
BANNED_RE = (
    (_dur(HANG_MS), f"no-progress window ({HANG_MS // 60000} min)"),
    (_dur(WORST_MS), f"worst case ({WORST_MS // 60000} min)"),
    (_dur(BACKOFF, "s"), f"retry ladder ({BACKOFF // 1000} s)"),
    (re.compile(rf"(?<![\d.]){HANG_MS:,}(?![\d])"), "no-progress window (ms)"),
    (re.compile(rf"(?<![\d.]){HANG_MS}(?![\d])"), "no-progress window (ms)"),
    (re.compile(rf"(?<![\d.]){WORST_MS:,}(?![\d])"), "worst case (ms)"),
    (re.compile(rf"(?<![\d.]){WORST_MS}(?![\d])"), "worst case (ms)"),
    (re.compile(r"no-progress window is ~"), "no-progress window (restated)"),
    (re.compile(r"retry ladder is ~"), "retry ladder (restated)"),
    # The CAP and the per-step LADDER are derived quantities too — a summary doc
    # restating them drifts exactly like the windows did (#1088 review cycle 6).
    (re.compile(rf"(?:capped at|cap of)[^\n]{{0,10}}?{CAP // 60000}[\s-]*min"),
     f"backoff cap ({CAP // 60000} min)"),
    (re.compile(rf"(?<![\d.]){CAP // 60000}[\s-]*min(?:ute)?s?\s+(?:retry\s+)?cadence"),
     f"backoff cap ({CAP // 60000} min cadence)"),
    (re.compile(rf"(?<![\d.]){BASE // 1000}s[/,\s]+{2 * BASE // 1000}s(?![\d])"),
     "ladder steps (s)"),
    (re.compile(rf"(?<![\d.]){8 * BASE // 1000}s(?![\d])"), "ladder step (s)"),
    # The backoff cap restated as a phrase. Value-derived like the rest, so it
    # stays correct when the cap changes; the 2-line window in the loop below is
    # what lets it see a restatement that wraps mid-phrase.
    (re.compile(rf"(?<![\d.]){CAP // 60000}[\s-]*min(?:ute)?s?\s+backoff\s+cap"),
     f"backoff cap ({CAP // 60000} min)"),
)
# The ban must apply to EVERY current-state doc under docs/ — not a hand-kept
# allowlist. A 2-doc allowlist (`providers.md`, `upstream-pi-bugs.md`) let this
# very PR introduce a derived-cap restatement in a THIRD doc
# (`docs/ops/session-lifecycle-contract.md`: "`retry.maxRetries` 7 / 1-min
# backoff cap") that the pin could not see, so the new text could drift
# silently — the exact defect this test exists to prevent (#1088 review). Only
# two things are exempt and both are declared here.
SOURCE_DOC = "docs/ops/cost-config-policy.md"   # §2 is the single source
# Dated snapshots (plans / research / scoping notes committed at a point in
# time) record what the fleet ran THEN; they are not current-state docs and are
# not edited. `docs/scoping/` is all-dated files; it also carries a coincidental
# numeric collision (a websocket reconnect ladder "8s→16s→…→60s" in
# 2026-08-31-issue-386-lease-fencing.md reaches the same "16s" the LLM retry
# ladder does), which is why the doc CLASS is the exemption rather than a prose
# anchor.
SNAPSHOT_DIRS = ("docs/plans/", "docs/research/", "docs/scoping/")

bad = []
for dirpath, dirnames, filenames in os.walk(os.path.join(root, "docs")):
    dirnames[:] = [d for d in dirnames if d not in {"node_modules", ".git"}]
    for fn in filenames:
        if not fn.endswith(".md"):
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        _lines = open(p, encoding="utf-8").readlines()
        for ln, line in enumerate(_lines, 1):
            # (1) a value ATTACHED to the idle key (`httpIdleTimeoutMs: 300000`,
            # `| httpIdleTimeoutMs | 300000 |`) must be the contract value. The
            # per-call ceiling is only legitimate on such a line when the SAME
            # line names the per-call key it belongs to — otherwise it is this
            # key's pre-#1088 value (600000) and it is stale.
            snap = rel.startswith(SNAPSHOT_DIRS)
            for m in (() if snap else re.finditer(r"httpIdleTimeoutMs[^0-9\n]{0,6}(\d{5,7})", line)):
                v = m.group(1)
                # ONLY the contract's idle value is acceptable attached to the
                # idle key. No carve-out for the per-call 600000 (that is this
                # key's pre-#1088 value wherever it appears) and none for the
                # deepseek contextWindow clamp, which happens to share the
                # digit string today — allowing it made a stale restatement in a
                # summary doc pass (#1088 coverage review). Dated snapshots are
                # skipped wholesale (SNAPSHOT_DIRS below).
                if v != idle:
                    bad.append(f"{rel}:{ln} states httpIdleTimeoutMs {v} "
                               f"(contract idle={IDLE}, per-call={PROV})")
            # (2) the backoff cap, restated in prose as a duration.
            m = None if snap else re.search(r"(\d+)-minute capped retry", line)
            if m and int(m.group(1)) * 60000 != CAP:
                bad.append(f"{rel}:{ln} says '{m.group(1)}-minute capped retry' "
                           f"but the cap is {CAP}ms")
            # (3) the fleet's live idle value, named in passing (the exact drift
            # this pin exists for — it was 600000 in three places after #1088).
            m = None if snap else re.search(r"the fleet runs (\d+)", line)
            if m and m.group(1) != str(IDLE):
                bad.append(f"{rel}:{ln} says 'the fleet runs {m.group(1)}' "
                           f"but the contract idle ceiling is {IDLE}")
            # (4) no current-state doc other than §2 may restate a derived
            # duration at all.
            if snap:
                continue
            if rel != SOURCE_DOC:
                # A 2-line window: the restatement this pin must catch can WRAP
                # ("…7 / 1-min backoff" / "cap, per …") and a line-scoped search
                # is blind to it — the same continuation-line false pass the
                # BANNED_RE rewrite was meant to remove.
                window = line + " " + (_lines[ln] if ln < len(_lines) else "")
                for rx, what in BANNED_RE:
                    m = rx.search(line) or rx.search(window)
                    if m:
                        bad.append(f"{rel}:{ln} restates the derived {what} as "
                                   f"'{m.group(0).strip()}' — those live only in "
                                   f"docs/ops/cost-config-policy.md §2")
if bad:
    print("❌ " + "\n❌ ".join(bad))
    sys.exit(1)
print(f"OK no stale retry/hang numbers (idle={IDLE}, per-call={PROV}, cap={CAP}); derived durations "
      f"single-sourced in §2, absent from every other current-state doc "
      f"(banned {len(BANNED_RE)} derived figures/forms)")
PY
if [ $? -eq 0 ]; then pass "$(cat "$OUT")"; else fail "stale retry/hang number in a doc: $(cat "$OUT")"; fi

echo ""
echo "26. COST_CLAMP_OVERRIDE=1 must NOT silence the compaction/settings class either"
# The escape exists for ONE rollback window (a models.json contextWindow revert).
# A reverted compaction block has no such window, so it must exit 1 too.
COST_CLAMP_OVERRIDE=1 bash "$GUARD" --live-dir "$FIX/backdoor-settings" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then
  pass "compaction drift + override → still exit 1"
else
  fail "expected exit 1 for compaction drift under the override, got $code"; sed -n '1,30p' "$OUT"
fi
if grep -q 'settings-contract' "$OUT" && grep -q 'does NOT cover' "$OUT"; then pass "the carve-out notice names the settings class"; else fail "expected the settings-class carve-out notice"; sed -n '1,30p' "$OUT"; fi
# ...while the clamp class stays silenced (the escape must keep working).
COST_CLAMP_OVERRIDE=1 bash "$GUARD" --live-dir "$FIX/backdoor-models" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then
  pass "clamp-class block still silenced (escape intact)"
else
  fail "the clamp escape stopped working (exit $code)"; sed -n '1,30p' "$OUT"
fi

echo ""
echo "27. a non-integer settings value must NOT skip the derived-window check"
# The window block used to print a zeroed sentinel (`WINDOW hung=0 worst=0`) when
# any input failed a Python `isinstance(int)` test. `0` is a PRESENT window, so
# `check_settings_file` took the PASS arm and the ceilings were never asserted —
# while the exact-value compares still passed, because JSON `8.0 == 8`. That was a
# reproduced bypass of the hang ceiling (#1088 review cycle 6, P1).
TMP27="$(mktemp -d /tmp/cost-config-float.XXXXXX)"
mkroot "$TMP27"
mutate27() { # $1 = raw JSON literal for the maxRetries value
  mkroot "$TMP27"   # clean root each time, so each case is independent
  python3 - "$TMP27/scripts/check-cost-config.sh" "$TMP27/pi-bootstrap/pi-config/settings.json" "$1" <<'PY'
import json, re, sys
g, s, expr = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(g).read()
assert "RETRY_MAX_RETRIES=7" in src, "guard constant shape changed — update this test"
open(g, "w").write(src.replace("RETRY_MAX_RETRIES=7", "RETRY_MAX_RETRIES=8"))
# hand-edit the JSON so a float literal survives (json.dump would normalise 8.0)
text = open(s).read()
text = re.sub(r'("maxRetries"\s*:\s*)\d+', lambda m: m.group(1) + expr, text, count=1)
assert expr in text, "maxRetries not rewritten"
open(s, "w").write(text)
PY
}
mutate27 '8.0'
bash "$TMP27/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "float 8.0 (== 8) still BLOCKs on the window ceiling"; else fail "FLOAT BYPASS: expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -qE 'hang window [0-9]+ms.*exceeds the declared ceiling' "$OUT"; then pass "the window was actually derived from the float"; else fail "expected the ceiling message (window not derived?)"; sed -n '1,30p' "$OUT"; fi
# a value that is not a positive whole number at all must fail CLOSED, not pass
mutate27 '"8"'
bash "$TMP27/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "string maxRetries → exit 1 (window underivable, fail-closed)"; else fail "expected exit 1 for a string maxRetries, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q 'cannot be derived' "$OUT"; then pass "the underivable-window diagnostic names the cause"; else fail "expected the 'cannot be derived' message"; sed -n '1,30p' "$OUT"; fi
if grep -q 'WINDOW hung=0' "$OUT"; then fail "a zeroed WINDOW sentinel is still emitted (the bypass shape)"; else pass "no zeroed WINDOW sentinel"; fi
# ...and a legitimate float equal to the pinned value must NOT false-block
rm -rf "$TMP27"; TMP27="$(mktemp -d /tmp/cost-config-float.XXXXXX)"; mkroot "$TMP27"
python3 - "$TMP27/pi-bootstrap/pi-config/settings.json" <<'PY'
import re, sys
s = sys.argv[1]
text = open(s).read()
text = re.sub(r'("maxRetries"\s*:\s*)\d+', lambda m: m.group(1) + "7.0", text, count=1)
open(s, "w").write(text)
PY
bash "$TMP27/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "float 7.0 == the pinned 7 → exit 0 (no false block)"; else fail "expected exit 0 for 7.0, got $code"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP27"

echo ""
echo "28. a project settings file at ANY depth is caught (no depth cap)"
# The walk was bounded by MAXDEPTH, so `.pi` deeper than the cap was invisible —
# a reproduced B4 bypass (#1088 review cycle 6).
TMP28="$(mktemp -d /tmp/cost-config-deep.XXXXXX)"
mkroot "$TMP28"
mkdir -p "$TMP28/a/b/c/d/.pi"
echo '{"theme":"dark"}' >"$TMP28/a/b/c/d/.pi/settings.json"
bash "$TMP28/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ] && grep -q "a/b/c/d/.pi/settings.json" "$OUT"; then
  pass "a 5-deep project file is walked (non-contract → exit 0)"
else
  fail "deep project file NOT walked (expected exit 0 + the path in the output, got $code)"; sed -n '1,30p' "$OUT"
fi
echo '{"retry":{"maxRetries":10000}}' >"$TMP28/a/b/c/d/.pi/settings.json"
bash "$TMP28/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "a 5-deep project file reverting the contract → exit 1"; else fail "expected exit 1 for a 5-deep project file, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q "a/b/c/d/.pi/settings.json" "$OUT"; then pass "the deep path is named in the block"; else fail "expected the deep path in the message"; sed -n '1,30p' "$OUT"; fi
# ...and a project file inside a `.pi` directory itself (a session cwd can be
# `~/.pi/agent`, so `.pi`-in-`.pi` is a live project file, not a curiosity).
rm -f "$TMP28/a/b/c/d/.pi/settings.json"
mkdir -p "$TMP28/.pi/inner/.pi"
echo '{"retry":{"maxRetries":10000}}' >"$TMP28/.pi/inner/.pi/settings.json"
bash "$TMP28/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ] && grep -q ".pi/inner/.pi/settings.json" "$OUT"; then
  pass "a nested .pi-in-.pi project file → exit 1, path named"
else
  fail "expected exit 1 for .pi/inner/.pi/settings.json, got $code"; sed -n '1,30p' "$OUT"
fi
rm -rf "$TMP28"

echo ""
echo "29. the backoff cap is read from the REAL assignment, not a shadowing comment"
# The parse was an unanchored `re.search`, so a stale assignment-shaped comment
# earlier in the patch script shadowed the live one: the guard read the old cap
# and went green while the script applied the new one (#1088 coverage review).
TMP29="$(mktemp -d /tmp/cost-config-capshadow.XXXXXX)"
mkroot "$TMP29"
python3 - "$TMP29/scripts/patch-pi-retry.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert 'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"' in s, "patch cap shape changed — update this test"
s = s.replace('CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"',
              'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-300000}"', 1)
s = s.replace('#!/usr/bin/env bash\n',
              '#!/usr/bin/env bash\n# legacy default kept for reference: CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"\n', 1)
open(p, "w").write(s)
PY
bash "$TMP29/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "live cap 300000 behind a 60000 comment → exit 1 (cap drift)"; else fail "CAP-PARSE BYPASS: expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q 'backoff cap expected' "$OUT"; then pass "the cap-drift message names both values"; else fail "expected the cap-drift message"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP29"

echo ""
echo "30. a SECOND CAP_MS assignment must NOT shadow the pinned one (fail-open pin)"
# Textual order is not execution order. Taking the LAST regex match let an
# UNCONDITIONAL `CAP_MS=300000` after the pinned line (or a matching assignment
# inside a never-taken branch) make the guard read 60000 while the script
# applied 300000 — a reproduced fail-open that defeated the cap pin the whole
# retry contract rests on (#1088 review). The cap must be the ONLY assignment.
TMP30="$(mktemp -d /tmp/cost-config-capmulti.XXXXXX)"
mkroot "$TMP30"
python3 - "$TMP30/scripts/patch-pi-retry.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert 'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"' in s, "patch cap shape changed — update this test"
s = s.replace('CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"',
              'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"\nCAP_MS=300000', 1)
open(p, "w").write(s)
PY
bash "$TMP30/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "a second unconditional CAP_MS assignment → exit 1 (not read from textual order)"; else fail "CAP-MULTI BYPASS: expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
if grep -q 'backoff cap unreadable' "$OUT"; then pass "the fail-closed diagnostic names the unreadable cap"; else fail "expected the 'backoff cap unreadable' message"; sed -n '1,30p' "$OUT"; fi
if grep -q '2 CAP_MS assignments' "$OUT"; then pass "the diagnostic says why (the assignment count)"; else fail "expected the assignment-count reason in the message"; sed -n '1,30p' "$OUT"; fi
# ...and the same class via a never-taken branch, not just a bare second line.
rm -rf "$TMP30"; TMP30="$(mktemp -d /tmp/cost-config-capdead.XXXXXX)"
mkroot "$TMP30"
python3 - "$TMP30/scripts/patch-pi-retry.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert 'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"' in s, "patch cap shape changed — update this test"
s = s.replace('CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"',
              'CAP_MS="${PI_MAX_RETRY_DELAY_MS:-300000}"\nif false; then\n  CAP_MS="${PI_MAX_RETRY_DELAY_MS:-60000}"\nfi', 1)
open(p, "w").write(s)
PY
bash "$TMP30/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "a matching assignment in a never-taken branch → exit 1"; else fail "DEAD-BRANCH BYPASS: expected exit 1, got $code"; sed -n '1,30p' "$OUT"; fi
rm -rf "$TMP30"

if [ "$failures" -eq 0 ]; then
  echo "✅ All cost-config guard tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
