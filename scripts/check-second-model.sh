#!/usr/bin/env bash
# check-second-model.sh — #716: second-model gate identity + dispatchability guard.
#
# The four graded second-model review gates (code-review §6.6, issue-scoping
# §5.6, plan-review §4.5, subagent-driven-development final reviewer) must run
# on a model whose SERVED BUILD differs from the primary session's. From
# 2026-09-14 12:00 Beijing, `deepseek-v4-pro` is served by the SAME V4.1 Flash
# build as the primary (`deepseek-flash`) — and `deepseek-flash` is itself a
# different id for the same build. This guard closes that drift class.
#
# Config-as-authority: `pi-bootstrap/pi-config/second-model.json` is the single
# source of truth. It declares an ordered `preference` list (first
# solvent+reachable candidate wins), each candidate's `runtimeVia` dispatch
# authority, the primary's build-equivalence set, the probe endpoints, and an
# integer-cents cost estimate. Adding a funded model needs a config edit only —
# never a code edit.
#
# Modes:
#   --print                resolve the effective designation (offline) — writes
#                          the provider/id to stdout, or `**DEGRADED` when no
#                          candidate is usable. Honours `$SECOND_MODEL`.
#   --check                offline deterministic guard (default): validates
#                          config shape, asserts every preference candidate is
#                          present in the runtime authority and NOT in the
#                          primary's build-equivalence set, and (when probe
#                          results are injected) that the first solvent+reachable
#                          candidate is independent; otherwise BLOCK DEGRADED.
#   --probe                network mode: vendor offer + solvency per candidate,
#                          first solvent+reachable wins → `RESOLVED=<id>`;
#                          none → `DEGRADED` (exit 1). NEVER run by pre-commit.
#   --equivalence <id>     exit 0 when <id> IS in the primary's build-equivalence
#                          set (build-equivalent), 1 when independent. Used by
#                          check-pipeline-compliance.sh check (f).
#
# Flags: --shipped-only (no live dir), --live-dir PATH (authority =
# PATH/second-model.json), --probe-fixture FILE (hermetic probe injection —
# ZERO network), --model ID (equivalence target), -h/--help.
#
# Exit codes: 0 pass / 1 BLOCK (invariant violation, incl. DEGRADED) /
# 2 usage or unusable authority (fail closed: missing/unparseable config, a
# preference entry with no runtimeVia, an empty build-equivalence set).
#
# Escape hatch: SECOND_MODEL_GATE_OVERRIDE=1 silences BLOCKs with a loud
# notice (detection still printed). Sanctioned only for the documented
# bootstrap/rollback window (see #716).
#
# Operator override: `$SECOND_MODEL` stays supported (AGENTS.md §284) —
# config-default fail-closed, operator-override-open-by-design. An override is
# WARNed and annotated, never blocked.
#
# Dep-free of npm: bash + python3 stdlib only (urllib for the probe). python3
# is the repo's sanctioned scripts/ dependency (check-cost-config.sh:30).
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "error: python3 required (stdlib only) — present on ubuntu-latest + macOS" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIPPED_FILE="$ROOT/pi-bootstrap/pi-config/second-model.json"
LIVE_DIR="${HOME}/.pi/agent"
MODE="check"
SHIPPED_ONLY=0
LIVE_DIR_ARG=""
PROBE_FIXTURE="${SECOND_MODEL_PROBE_RESULT:-}"
EQUIV_MODEL=""
OVERRIDE="${SECOND_MODEL_GATE_OVERRIDE:-0}"

usage() {
  sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE="print" ;;
    --check) MODE="check" ;;
    --probe) MODE="probe" ;;
    --equivalence)
      MODE="equivalence"; shift
      EQUIV_MODEL="${1:-}"
      [ -n "$EQUIV_MODEL" ] || { echo "error: --equivalence requires a model id" >&2; exit 2; }
      ;;
    --model) shift; EQUIV_MODEL="${1:-}"; [ -n "$EQUIV_MODEL" ] || { echo "error: --model requires a model id" >&2; exit 2; } ;;
    --shipped-only) SHIPPED_ONLY=1 ;;
    --live-dir) shift; LIVE_DIR_ARG="${1:-}"; [ -n "$LIVE_DIR_ARG" ] || { echo "error: --live-dir requires a path" >&2; exit 2; } ;;
    --probe-fixture) shift; PROBE_FIXTURE="${1:-}"; [ -n "$PROBE_FIXTURE" ] || { echo "error: --probe-fixture requires a path" >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ── Authority resolution ─────────────────────────────────────────────────────
#   --live-dir PATH   → PATH/second-model.json (authority; tests/first-install)
#   --shipped-only    → the repo's shipped copy
#   default           → the live copy when present, else the shipped copy
if [ -n "$LIVE_DIR_ARG" ]; then
  AUTHORITY="$LIVE_DIR_ARG/second-model.json"
elif [ "$SHIPPED_ONLY" = "1" ]; then
  AUTHORITY="$SHIPPED_FILE"
elif [ -f "$LIVE_DIR/second-model.json" ]; then
  AUTHORITY="$LIVE_DIR/second-model.json"
else
  AUTHORITY="$SHIPPED_FILE"
fi

python3 - "$MODE" "$AUTHORITY" "$SHIPPED_FILE" "$PROBE_FIXTURE" "$EQUIV_MODEL" \
         "${SECOND_MODEL:-}" "$OVERRIDE" "$SHIPPED_ONLY" <<'PYEOF'
import json, os, re, sys, urllib.error, urllib.request

mode, authority, shipped, probe_fixture, equiv_model, operator_override, \
    override_flag, shipped_only = sys.argv[1:9]

OK, WARN, BLOCK = "OK", "WARN", "BLOCK"
lines = []
blocks = 0
warns = 0
fatals = 0


def ok(msg):
    lines.append((OK, msg))


def warn(msg):
    global warns
    warns += 1
    lines.append((WARN, msg))


def block(msg):
    global blocks
    blocks += 1
    lines.append((BLOCK, msg))


def die(msg):
    global fatals
    fatals += 1
    lines.append((BLOCK, msg))


def norm_model(mid):
    """Bare model id: drop a provider qualifier, a `~` prefix, and any
    `:routing-tier` suffix. `openrouter/anthropic/claude-opus-4.8` →
    `claude-opus-4.8`; `deepseek-flash` → `deepseek-flash`;
    `~venice/deepseek-v4-flash` → `deepseek-v4-flash`."""
    s = str(mid).strip()
    s = s[1:] if s.startswith("~") else s
    if "/" in s:
        s = s.split("/", 1)[1]
    last = s.split("/")[-1]
    return last.split(":")[0].lower()


def load_config(path):
    try:
        with open(path) as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, f"config not found: {path}"
    except Exception as e:
        return None, f"config unparseable: {path}: {e}"


def load_fixture(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception as e:
        return None, f"probe fixture unusable: {path}: {e}"
    if not isinstance(d, dict):
        return None, f"probe fixture unusable: {path}: must be an object keyed by model id"
    return d, None


def equivalence_set(cfg):
    eq = cfg.get("primary", {}).get("buildEquivalence", {}) if isinstance(cfg, dict) else {}
    return eq if isinstance(eq, dict) else {}


def safe_search(pattern, value):
    try:
        return re.search(pattern, value) is not None
    except re.error:
        return True  # unparseable family regex → fail closed


def is_equivalent(mid, eq):
    n = norm_model(mid)
    if n in {str(x).lower() for x in eq.get("normalized", []) if isinstance(x, str)}:
        return True
    for fam in eq.get("families", []):
        if not isinstance(fam, str):
            return True  # malformed family entry → fail closed
        if safe_search(fam, n):
            return True
    return False


def repo_root():
    if os.path.isfile(shipped):
        return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(shipped))))
    return os.path.dirname(os.path.dirname(os.path.abspath(authority)))


def validate(cfg, label):
    """Structural validation. Records OK/WARN/BLOCK/die lines; returns the
    preference list (possibly empty)."""
    pref = cfg.get("preference")
    if not isinstance(pref, list) or not pref:
        die(f"{label}: `preference` must be a non-empty array — the designation authority is unusable (fail closed)")
        return []
    eq = equivalence_set(cfg)
    if not eq.get("families") and not eq.get("normalized"):
        die(f"{label}: `primary.buildEquivalence` is empty — the guard cannot classify served builds (fail closed)")
        return []
    primary = cfg.get("primary", {}).get("model")
    if not isinstance(primary, str) or not primary:
        die(f"{label}: `primary.model` is missing — cannot assert independence against an unknown primary")
        return []
    # Non-vacuity self-check: the primary's OWN id must classify equivalent. An
    # equivalence set that does not contain the primary (e.g. both lists
    # emptied) would silently pass every candidate.
    if not is_equivalent(primary, eq):
        die(f"{label}: `primary.model` ({primary}) is NOT in its own buildEquivalence set — the equivalence mapping is misconfigured (fail closed)")
        return []
    patterns = cfg.get("unreachablePatterns")
    if not isinstance(patterns, list) or not patterns:
        die(f"{label}: `unreachablePatterns` must be a non-empty array — the probe cannot classify a JSON-200 error body (fail closed)")
        return []

    for i, entry in enumerate(pref):
        if not isinstance(entry, dict):
            die(f"{label}: preference[{i}] is not an object")
            continue
        model = entry.get("model")
        if not isinstance(model, str) or not model:
            die(f"{label}: preference[{i}].model is missing")
            continue
        runtime_via = entry.get("runtimeVia")
        if not isinstance(runtime_via, str) or not runtime_via.strip():
            die(f"{label}: preference[{i}] ({model}) declares no `runtimeVia` dispatch authority (fail closed — a designation we cannot prove dispatchable must not ship)")
            continue
        if is_equivalent(model, eq):
            block(f"{label}: preference[{i}] ({model}) is the SAME served build as the primary ({primary}) — build-equivalent ids (incl. the provider-less `deepseek-flash` alias) are NOT an independent reviewer")
        else:
            ok(f"{label}: preference[{i}] {model} — independent of primary {primary}")

    # Cross-check declared runtimeVia paths against the runtime authority that
    # scripts/ can actually read. The openrouter model list lives in TypeScript
    # (not machine-readable here) → noted, not asserted. models.json
    # declarations ARE asserted.
    for i, entry in enumerate(pref):
        if not isinstance(entry, dict):
            continue
        rv = str(entry.get("runtimeVia", ""))
        if not rv.startswith("pi-bootstrap/pi-config/models.json#"):
            warn(f"{label}: preference[{i}] runtimeVia `{rv}` is an external authority (not machine-readable from scripts/) — dispatchability proven by one real graded gate run (indicator (c)); see #734")
            continue
        parts = rv.split("#", 1)[1].strip()
        m = re.match(r"^providers\.([A-Za-z0-9_.-]+)\.models(?:\[(\d+)\])?$", parts)
        if not m:
            die(f"{label}: preference[{i}] runtimeVia `{rv}` is not a resolvable models.json pointer (fail closed)")
            continue
        provider, idx = m.group(1), m.group(2)
        mpath = os.path.join(repo_root(), rv.split("#", 1)[0])
        mcfg, err = load_config(mpath)
        if err:
            die(f"{label}: preference[{i}] runtimeVia models.json not readable ({err}) — the declaration cannot be cross-checked (fail closed)")
            continue
        models = mcfg.get("providers", {}).get(provider, {}).get("models") if isinstance(mcfg, dict) else None
        if not isinstance(models, list) or not models:
            die(f"{label}: preference[{i}] runtimeVia names providers.{provider}.models but models.json has no such list (fail closed — the declaration contradicts the runtime config)")
            continue
        want = norm_model(entry.get("model", ""))
        ids = [norm_model(mm.get("id", "")) for mm in models if isinstance(mm, dict)]
        if want not in ids:
            die(f"{label}: preference[{i}] model `{entry.get('model')}` is not in models.json providers.{provider}.models ({ids}) — the declaration contradicts the runtime config (fail closed)")
        else:
            ok(f"{label}: preference[{i}] runtimeVia resolved in models.json providers.{provider}.models")
    return pref


def classify(res, entry, patterns):
    """(reachable_and_solvent, reason). A JSON-200 body carrying an error
    signature (`insufficient balance`, `1113`, `exceeded_current_quota_error`,
    `blocked`, …) classifies as UNREACHABLE — the P0 from the #716 scoping
    review (a naive 2xx check would pass a solvent-but-erroring account)."""
    probe = entry.get("probe", {}) if isinstance(entry.get("probe"), dict) else {}
    for key, label in (("offer", "vendor offer"), ("solvency", "solvency")):
        r = res.get(key) if isinstance(res.get(key), dict) else {}
        code = r.get("httpCode")
        body = r.get("body") or ""
        low = body.lower()
        hit = next((p for p in patterns if isinstance(p, str) and p.lower() in low), None)
        if hit is not None:
            return False, f"{label}: error signature {hit!r} in body (HTTP {code}) — UNREACHABLE (JSON-200 error bodies count)"
        if code is None:
            return False, f"{label}: no response ({r.get('error', 'unknown')})"
        if not (isinstance(code, int) and 200 <= code < 300):
            return False, f"{label}: HTTP {code}"
    offer_body = (res.get("offer") or {}).get("body") or ""
    must = probe.get("offerMustInclude")
    if must and str(must) not in offer_body:
        return False, f"vendor offer does not include {must}"
    sol = res.get("solvency") or {}
    kind = probe.get("solvencyKind")
    if kind == "balance":
        try:
            d = json.loads(sol.get("body") or "{}")
        except Exception:
            return False, "solvency: balance body unparseable"
        vals = []
        for key in ("available_balance", "cash_balance", "balance", "total_balance"):
            if isinstance(d.get(key), (int, float)):
                vals.append(float(d[key]))
            if isinstance(d.get("data"), dict) and isinstance(d["data"].get(key), (int, float)):
                vals.append(float(d["data"][key]))
        if not vals or max(vals) <= 0:
            return False, f"solvency: balance not positive ({vals or 'no balance field'})"
    elif kind == "key-limit":
        try:
            d = json.loads(sol.get("body") or "{}")
        except Exception:
            return False, "solvency: key body unparseable"
        data = d.get("data") if isinstance(d.get("data"), dict) else d
        limit = data.get("limit")
        remaining = data.get("limit_remaining")
        if limit is None:
            pass  # unlimited key
        elif not isinstance(remaining, (int, float)) or float(remaining) <= 0:
            return False, f"solvency: key limit exhausted (limit={limit}, remaining={remaining})"
    elif kind == "none":
        pass
    else:
        return False, f"solvency: unknown solvencyKind {kind!r}"
    return True, "reachable + solvent"


def http_get(url, auth_env, timeout=15):
    headers = {"Accept": "application/json", "User-Agent": "agent-infra-second-model-guard/1"}
    key = os.environ.get(auth_env, "") if auth_env else ""
    if key:
        headers["Authorization"] = "Bearer " + key
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return {"httpCode": getattr(r, "status", None) or r.getcode(),
                    "body": r.read(50000).decode("utf-8", "replace")}
    except urllib.error.HTTPError as e:
        try:
            body = e.read(50000).decode("utf-8", "replace")
        except Exception:
            body = ""
        return {"httpCode": e.code, "body": body}
    except Exception as e:
        return {"httpCode": None, "body": "", "error": type(e).__name__}


def probe_entry(entry, fixture):
    """Return (result_dict, err). Uses the fixture when supplied (ZERO network);
    otherwise performs real HTTP probes with the candidate's auth env."""
    model = entry.get("model", "")
    if fixture is not None:
        res = fixture.get(model)
        if not isinstance(res, dict):
            return None, f"no fixture entry for {model}"
        return res, ""
    probe = entry.get("probe", {}) if isinstance(entry.get("probe"), dict) else {}
    env = probe.get("authEnv", "")
    if env and not os.environ.get(env):
        return {"offer": {"httpCode": None, "error": f"{env} unset"},
                "solvency": {"httpCode": None, "error": f"{env} unset"}}, ""
    return {"offer": http_get(probe.get("offerUrl", ""), env),
            "solvency": http_get(probe.get("solvencyUrl", ""), env)}, ""


def resolve(cfg, pref, fixture):
    """First solvent+reachable+independent candidate → (model|None, notes[])."""
    notes = []
    eq = equivalence_set(cfg)
    patterns = cfg.get("unreachablePatterns", [])
    for entry in pref:
        if not isinstance(entry, dict):
            continue
        model = entry.get("model", "")
        if is_equivalent(model, eq):
            notes.append(f"{model}: build-equivalent (skipped)")
            continue
        res, err = probe_entry(entry, fixture)
        if res is None:
            notes.append(f"{model}: {err}")
            continue
        good, reason = classify(res, entry, patterns)
        notes.append(f"{model}: {reason}")
        if good:
            return model, notes
    return None, notes


# ── equivalence mode (used by check-pipeline-compliance.sh check (f)) ───────
if mode == "equivalence":
    cfg, err = load_config(authority)
    if cfg is None:
        print(f"❌ second-model guard: {err}", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    eq = equivalence_set(cfg)
    if is_equivalent(equiv_model, eq):
        print(f"EQUIVALENT {norm_model(equiv_model)}")
        sys.exit(0)
    print(f"INDEPENDENT {norm_model(equiv_model)}")
    sys.exit(1)

# ── print mode (offline resolver for the gate skills) ───────────────────────
if mode == "print":
    if operator_override:
        print(f"⚠️  second-model gate: $SECOND_MODEL={operator_override} operator override active — independence NOT asserted offline (config-default fail-closed, operator-override-open-by-design)", file=sys.stderr)
        print(operator_override)
        sys.exit(0)
    cfg, err = load_config(authority) if authority else (None, "no authority path")
    if cfg is None:
        print(f"⚠️  second-model gate: {err} — first-install/first-bootstrap tree; run pi-bootstrap/setup.sh to install the designation", file=sys.stderr)
        print("**DEGRADED")
        sys.exit(0)
    pref = cfg.get("preference") if isinstance(cfg.get("preference"), list) else []
    eq = equivalence_set(cfg)
    if not pref:
        print("⚠️  second-model gate: config has no usable `preference` list — DEGRADED", file=sys.stderr)
        print("**DEGRADED")
        sys.exit(1)
    if probe_fixture:
        fixture, err = load_fixture(probe_fixture)
        if err:
            print(f"❌ second-model gate: {err}", file=sys.stderr)
            print("**DEGRADED")
            sys.exit(2)
        model, notes = resolve(cfg, pref, fixture)
        if model:
            print(model)
            sys.exit(0)
        print("⚠️  second-model gate: no solvent+reachable candidate — DEGRADED", file=sys.stderr)
        for n in notes:
            print(f"   · {n}", file=sys.stderr)
        print("**DEGRADED")
        sys.exit(1)
    for entry in pref:
        if isinstance(entry, dict):
            model = entry.get("model", "")
            if model and not is_equivalent(model, eq):
                print(model)
                sys.exit(0)
    print("⚠️  second-model gate: no offline-valid candidate — DEGRADED", file=sys.stderr)
    print("**DEGRADED")
    sys.exit(1)

# ── probe mode (network; never pre-commit) ──────────────────────────────────
if mode == "probe":
    cfg, err = load_config(authority) if authority else (None, "no authority path")
    if cfg is None:
        print(f"❌ second-model guard: {err}", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    pref = cfg.get("preference") if isinstance(cfg.get("preference"), list) else []
    patterns = cfg.get("unreachablePatterns", [])
    if not pref or not isinstance(patterns, list) or not patterns:
        print("❌ second-model guard: config has no usable preference/probe patterns", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    fixture = None
    if probe_fixture:
        fixture, err = load_fixture(probe_fixture)
        if fixture is None:
            print(f"❌ second-model guard: {err}", file=sys.stderr)
            print("DEGRADED")
            sys.exit(2)
    print("== second-model probe (#716) — vendor offer + solvency ==")
    model = None
    for entry in pref:
        if not isinstance(entry, dict):
            continue
        mid = entry.get("model", "")
        res, perr = probe_entry(entry, fixture)
        if res is None:
            print(f"  ⚠️  {mid}: {perr}")
            continue
        good, reason = classify(res, entry, patterns)
        print(f"  {'✅' if good else '⚠️ '} {mid}: {reason}")
        if good and model is None:
            model = mid
    if model:
        print(f"RESOLVED={model}")
        sys.exit(0)
    print("DEGRADED — no solvent+reachable candidate; fail closed (do NOT dispatch a substitute)")
    sys.exit(1)

# ── check mode (offline deterministic guard) ────────────────────────────────
print("== second-model gate (#716) — designation identity + dispatchability ==")
if override_flag == "1":
    print("   ⛔ SECOND_MODEL_GATE_OVERRIDE=1 is SET — guard blocks will be SILENCED (escape hatch, see docs/providers.md §Second-model gate)")
print("")

cfg, err = load_config(authority) if authority else (None, "no authority path")
if cfg is None:
    die(f"authority unusable: {err} — the second-model designation is gone (fail closed)")
    print("")
    print("❌ second-model gate: fail-closed exit 2 — no usable designation authority.")
    sys.exit(2)

print(f"authority: {authority}")
if operator_override:
    warn(f"$SECOND_MODEL={operator_override} operator override active — the config default is NOT what a gate would dispatch; annotate the gate line with the resolved id")
pref = validate(cfg, "authority")
print("")

if probe_fixture:
    fixture, ferr = load_fixture(probe_fixture)
    if fixture is None:
        die(ferr)
    else:
        model, notes = resolve(cfg, pref, fixture)
        for n in notes:
            print(f"   · probe {n}")
        if model:
            ok(f"probe resolution: first solvent+reachable independent candidate = {model}")
        else:
            block("DEGRADED — no solvent+reachable candidate in the ordered preference list; the gate MUST fail closed (never dispatch the tool default or a build-equivalent model as an 'independent' review)")
    print("")
else:
    print("   (probe skipped — offline --check; run --probe at gate time / in CI)")
    print("")

for sev, msg in lines:
    print(f"  {'✅' if sev == OK else '⚠️ ' if sev == WARN else '❌'} {msg}")
print("")

if override_flag == "1":
    print("⛔ SECOND_MODEL_GATE_OVERRIDE=1 — BLOCK silenced by the documented escape hatch. Violations above are still DETECTED;")
    print("   sanctioned only for the bootstrap/rollback window (see #716).")
    print("⛔ Guard: OVERRIDDEN → exit 0")
    sys.exit(0)

if fatals > 0:
    print(f"❌ second-model gate: fail-closed exit 2 — {fatals} unusable-authority violation(s) (missing/unparseable config, undeclared runtimeVia, empty equivalence set).")
    sys.exit(2)
if blocks > 0:
    print(f"❌ second-model gate: {blocks} BLOCK-level violation(s) — fix pi-bootstrap/pi-config/second-model.json, or use SECOND_MODEL_GATE_OVERRIDE=1 (documented escape).")
    sys.exit(1)
if warns > 0:
    print(f"⚠️  second-model gate: PASS with {warns} warning(s).")
else:
    print("✅ second-model gate: PASS — the ordered preference is independent of the primary's served build and every candidate declares its dispatch authority.")
sys.exit(0)
PYEOF
