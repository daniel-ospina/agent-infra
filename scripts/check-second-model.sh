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
#                          the provider/id to stdout. Honours `$SECOND_MODEL`.
#                          Exit 0 = a usable id; 1 = no valid config candidate
#                          (prints `**DEGRADED`); 2 = unusable authority
#                          (missing/unparseable config, non-string model).
#   --check                offline deterministic guard (default): validates
#                          config shape, asserts every preference candidate is
#                          present in the runtime authority, NOT in the
#                          primary's build-equivalence set, and unique after
#                          normalization; and (when probe results are injected)
#                          that the first solvent+reachable candidate is
#                          independent; otherwise BLOCK DEGRADED.
#   --probe                network mode: vendor offer + solvency per candidate,
#                          first solvent+reachable wins → `RESOLVED=<id>`;
#                          none → `DEGRADED` (exit 1). Applies the SAME
#                          build-equivalence filter as `--print`, and probes a
#                          `$SECOND_MODEL` override first. NEVER run by
#                          pre-commit.
#   --equivalence <id>     exit 0 when <id> IS in the primary's build-equivalence
#                          set (build-equivalent), 1 when independent, 2 when
#                          the authority itself is unusable (fail closed). Used
#                          by check-pipeline-compliance.sh check (f).
#
# Flags: --shipped-only (no live dir), --live-dir PATH (authority =
# PATH/second-model.json), --probe-fixture FILE (hermetic probe injection —
# ZERO network), --allow-file-probe (test-only: permit file:// probe URLs;
# REFUSED otherwise, so a config cannot point the probe at local files),
# --model ID (equivalence target), -h/--help.
#
# Probe security (B1): the probe NEVER sends a credential dictated by an
# untrusted config. Probe URLs must be https:// (file:// only under
# --allow-file-probe), the destination host must be an allowlisted host for the
# candidate's own vendor (fixed vendor→host map + registrable-domain match),
# `authEnv` must name a fixed known vendor env var, and cross-host redirects are
# REFUSED outright so the Authorization header is never re-sent to a new host.
# Keys are never printed, logged, or written.
#
# Exit codes: 0 pass / 1 BLOCK (invariant violation, incl. DEGRADED) /
# 2 usage or unusable authority (fail closed: missing/unparseable config, a
# preference entry with no runtimeVia or non-string model, an empty
# build-equivalence set, a missing/unparseable probe fixture).
#
# Escape-hatch policy: SECOND_MODEL_GATE_OVERRIDE=1 silences BLOCKs (exit 1)
# with a loud notice (detection still printed), but NEVER silences an
# unusable-authority fatal (exit 2) — an override cannot authorize a
# designation that does not exist. Sanctioned only for the documented
# bootstrap/rollback window (see docs/providers.md §Second-model gate).
#
# Operator override: `$SECOND_MODEL` stays supported (AGENTS.md §284) —
# config-default fail-closed, operator-override-open-by-design. `--print`
# returns it and WARNs; `--probe` probes it FIRST when the id is declared in
# `preference` (so liveness is gated), and cannot certify an id that declares
# no probe endpoint (the probe never emits RESOLVED for an unprobeable id).
# An override is WARNed and annotated, never blocked.
#
# Dep-free of npm: bash + python3 stdlib only (urllib is imported lazily inside
# the network helper so offline modes pay no import cost). python3 is the
# repo's sanctioned scripts/ dependency (check-cost-config.sh:30).
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
ALLOW_FILE_PROBE=0
OVERRIDE="${SECOND_MODEL_GATE_OVERRIDE:-0}"

usage() {
  # Derive the header range from the shebang to the first `set` line so the
  # help text can never truncate mid-sentence when the header grows (A7).
  local end
  end="$(awk '/^set -/{print NR-1; exit}' "$0")"
  [ -n "$end" ] || end=60
  sed -n "2,${end}p" "$0" | sed 's/^# \{0,1\}//'
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
    --allow-file-probe) ALLOW_FILE_PROBE=1 ;;
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
         "${SECOND_MODEL:-}" "$OVERRIDE" "$SHIPPED_ONLY" "$ALLOW_FILE_PROBE" <<'PYEOF'
import json, os, re, sys

mode, authority, shipped, probe_fixture, equiv_model, operator_override, \
    override_flag, shipped_only, allow_file_probe = sys.argv[1:10]
allow_file_probe = allow_file_probe == "1"

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
    `~venice/deepseek-v4-flash` → `deepseek-v4-flash`. An unparseable id
    (e.g. a trailing `/`) normalizes to `""` — callers must treat that as
    NEVER independent (see is_equivalent)."""
    s = str(mid).strip()
    s = s[1:] if s.startswith("~") else s
    if "/" in s:
        s = s.split("/", 1)[1]
    last = s.split("/")[-1]
    return last.split(":")[0].lower()


# Reserved marker values that must never be read as a resolved model id.
RESERVED_MODEL_RE = re.compile(r"^\**DEGRADED$", re.I)
# A dispatchable model id: optional `~` prefix, one or more `[A-Za-z0-9._-]`
# segments, optional `:routing-tier`. Deliberately excludes `*`, whitespace,
# and shell metacharacters.
MODEL_ID_RE = re.compile(r"^~?[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*(?::[A-Za-z0-9._-]+)?$")


def is_reserved_model(mid):
    return bool(RESERVED_MODEL_RE.match(str(mid).strip()))


def is_model_id(mid):
    """A non-empty string that is neither the reserved DEGRADED token nor a
    malformed id. Used by `--print` (A4) and by check (f) (C3)."""
    s = str(mid).strip()
    if not s or is_reserved_model(s):
        return False
    return bool(MODEL_ID_RE.match(s))


# ── Probe destination policy (B1) ───────────────────────────────────────────
# A credential named by the config must never travel to a host the config also
# chooses. Two independent gates: the host must be a known host for the
# candidate's OWN vendor, and the credential must be a known vendor env var.
VENDOR_HOST_ALLOW = {
    "moonshot": ("api.moonshot.ai", "api.moonshot.cn"),
    "openrouter": ("openrouter.ai",),
    "anthropic": ("api.anthropic.com",),
    "openai": ("api.openai.com",),
    "deepseek": ("api.deepseek.com",),
    "google": ("generativelanguage.googleapis.com",),
    "qwen": ("dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"),
    "zai": ("api.z.ai",),
    "venice": ("api.venice.ai",),
    "xai": ("api.x.ai",),
    "mistral": ("api.mistral.ai",),
}
AUTH_ENV_ALLOW = {
    "MOONSHOT_API_KEY", "MOONSHOT_KEY",
    "OPENROUTER_API_KEY",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "GOOGLE_API_KEY", "GEMINI_API_KEY",
    "DASHSCOPE_API_KEY",
    "ZAI_API_KEY",
    "VENICE_API_KEY",
    "XAI_API_KEY",
    "MISTRAL_API_KEY",
}


def vendor_of(model):
    return str(model).lstrip("~").split("/", 1)[0].lower()


def host_allowed(host, vendor):
    host = (host or "").lower().rstrip(".")
    if not host:
        return False
    if host in {h.lower() for h in VENDOR_HOST_ALLOW.get(vendor, ())}:
        return True
    # General rule: the registrable-domain label must equal the vendor token.
    # `api.moonshot.ai` → "moonshot" ✓; `moonshot.evil.com` → "evil" ✗.
    labels = host.split(".")
    return len(labels) >= 2 and labels[-2] == vendor


def url_parts(url):
    if not isinstance(url, str) or "://" not in url:
        return "", "", ""
    scheme, rest = url.split("://", 1)
    host = rest.split("/", 1)[0].split("@")[-1].split(":")[0]
    return scheme.lower(), host.lower(), rest


def probe_url_error(url, vendor):
    if not isinstance(url, str) or not url.strip():
        return "probe URL is empty"
    scheme, host, _ = url_parts(url)
    if not scheme:
        return f"probe URL has no scheme ({url!r})"
    if scheme == "file":
        if not allow_file_probe:
            return f"file:// probe URL refused — file:// is permitted only under --allow-file-probe (got {url!r})"
        return None
    if scheme != "https":
        return f"probe URL must be https:// (got {scheme}:// — refusing to send a credential over an insecure scheme)"
    if not host_allowed(host, vendor):
        return f"probe host {host!r} is not an allowlisted {vendor!r} vendor host (refusing to send a credential to a host chosen by config)"
    return None


def auth_env_error(env):
    if not env:
        return None
    if env not in AUTH_ENV_ALLOW:
        return f"authEnv {env!r} is not an allowlisted vendor env name (refusing to forward an arbitrary environment variable)"
    return None


# ── Authority loading (shared by EVERY mode — A1) ───────────────────────────
def load_config(path):
    try:
        with open(path) as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, f"config not found: {path}"
    except Exception as e:
        return None, f"config unparseable: {path}: {e}"


def load_authority(path):
    """Return (cfg, err). A config that is not a JSON object is unusable for
    every mode — never let a list/string flow into .get() and crash, and never
    let it read as "independent"."""
    cfg, err = load_config(path)
    if cfg is None:
        return None, err
    if not isinstance(cfg, dict):
        return None, f"config must be a JSON object, got {type(cfg).__name__}: {path}"
    return cfg, None


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
    if not n:
        # An id that cannot be parsed must NEVER read as independent (A3): a
        # trailing-slash spelling like `deepseek/deepseek-v4-pro/` normalizes to
        # "" and would otherwise classify INDEPENDENT — a false pass.
        return True
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


def validate(cfg, label, probe_urls=False):
    """Structural validation. Records OK/WARN/BLOCK/die lines; returns the
    preference list (possibly empty). Called by `--check`, `--probe` and
    `--equivalence` so no mode can act on an authority another mode rejects."""
    if not isinstance(cfg, dict):
        die(f"{label}: authority is not a JSON object — unusable (fail closed)")
        return []
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

    seen_models = {}
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
        n = norm_model(model)
        if n in seen_models:
            warn(f"{label}: preference[{i}] ({model}) duplicates preference[{seen_models[n]}] ({pref[seen_models[n]].get('model')}) after normalization — dedupe the ordered preference (a duplicate wastes a probe and can mask a funding change)")
        else:
            seen_models[n] = i
        if is_equivalent(model, eq):
            block(f"{label}: preference[{i}] ({model}) is the SAME served build as the primary ({primary}) — build-equivalent ids (incl. the provider-less `deepseek-flash` alias) are NOT an independent reviewer")
        else:
            ok(f"{label}: preference[{i}] {model} — independent of primary {primary}")
        if probe_urls:
            # Static destination policy (B1) — a hostile config is rejected by
            # `--check` even before any network call.
            for key in ("offerUrl", "solvencyUrl"):
                pu = entry.get("probe", {}).get(key) if isinstance(entry.get("probe"), dict) else None
                if pu:
                    perr = probe_url_error(pu, vendor_of(model))
                    if perr:
                        # A BLOCK, not a fatal: a misdeclared probe destination
                        # is a config defect (fixable in the authority), and the
                        # probe refuses at runtime regardless. Keeps --check
                        # exit 1 (BLOCK) rather than 2 (unusable authority).
                        block(f"{label}: preference[{i}] {key}: {perr}")
            aerr = auth_env_error(entry.get("probe", {}).get("authEnv", "") if isinstance(entry.get("probe"), dict) else "")
            if aerr:
                block(f"{label}: preference[{i}] {aerr}")

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
    offer = res.get("offer") or {}
    must = probe.get("offerMustInclude")
    if must:
        # A vendor catalogue can exceed any fixed read cap (OpenRouter's
        # /models is >700KB, #716) — so http_get() searches the stream for the
        # needle and reports `needleFound`. `None` = a fixture/injected body,
        # which is searched in full directly.
        found = offer.get("needleFound")
        if found is False:
            return False, f"vendor offer does not include {must}"
        if found is None and str(must) not in (offer.get("body") or ""):
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


def http_get(url, auth_env, timeout=15, needle=None):
    """GET `url`. With `needle`, stream the body in chunks and report
    `needleFound` instead of trusting a truncated prefix — a vendor catalogue
    routinely exceeds a fixed read cap (OpenRouter /models is ~730KB and the
    designated id sits at byte ~222k, #716), which would otherwise produce a
    spurious "offer does not include" and a permanent DEGRADED.

    Security (B1): urllib is imported LAZILY (offline modes pay nothing), the
    scheme is re-checked, and cross-host redirects are REFUSED so the
    Authorization header can never be re-sent to a host the config chose."""
    import urllib.error, urllib.parse, urllib.request
    scheme, _host, _rest = url_parts(url)
    if not scheme:
        return {"httpCode": None, "body": "", "error": "invalid URL"}
    if scheme == "file" and not allow_file_probe:
        return {"httpCode": None, "body": "", "error": "file:// refused (test-only)"}
    if scheme not in ("https", "file"):
        return {"httpCode": None, "body": "", "error": f"scheme {scheme} refused"}
    headers = {"Accept": "application/json", "User-Agent": "agent-infra-second-model-guard/1"}
    key = os.environ.get(auth_env, "") if auth_env else ""
    if key:
        headers["Authorization"] = "Bearer " + key

    class _SameHostRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, hdrs, newurl):
            try:
                old = urllib.parse.urlsplit(req.full_url).hostname
                new = urllib.parse.urlsplit(newurl).hostname
            except Exception:
                return None
            if old != new:
                return None  # refuse cross-host redirect — never re-send the key
            return super().redirect_request(req, fp, code, msg, hdrs, newurl)

    opener = urllib.request.build_opener(_SameHostRedirect)
    try:
        req = urllib.request.Request(url, headers=headers)
        with opener.open(req, timeout=timeout) as r:
            code = getattr(r, "status", None)
            if code is None:
                try:
                    code = r.getcode()
                except Exception:
                    code = None
            # Non-HTTP schemes (file://, used by the hermetic large-offer test)
            # have no status code; a successful open is a 200-equivalent.
            if code is None:
                code = 200
            if needle is None:
                return {"httpCode": code, "body": r.read(50000).decode("utf-8", "replace")}
            needle = str(needle)
            out = {"httpCode": code, "body": "", "needleFound": False}
            prefix, tail, total = b"", "", 0
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if len(prefix) < 50000:
                    prefix += chunk
                text = tail + chunk.decode("utf-8", "replace")
                if needle in text:
                    out["needleFound"] = True
                    break
                tail = text[-(len(needle) - 1):] if len(needle) > 1 else ""
                if total >= 8_000_000:
                    break
            out["body"] = prefix[:50000].decode("utf-8", "replace")
            return out
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
    otherwise performs real HTTP probes with the candidate's auth env — after
    enforcing the probe destination policy (B1)."""
    model = entry.get("model", "")
    if fixture is not None:
        res = fixture.get(model)
        if not isinstance(res, dict):
            return None, f"no fixture entry for {model}"
        return res, ""
    probe = entry.get("probe", {}) if isinstance(entry.get("probe"), dict) else {}
    vendor = vendor_of(model)
    env = probe.get("authEnv", "")
    err = (auth_env_error(env)
           or probe_url_error(probe.get("offerUrl", ""), vendor)
           or probe_url_error(probe.get("solvencyUrl", ""), vendor))
    if err:
        return {"offer": {"httpCode": None, "error": err},
                "solvency": {"httpCode": None, "error": err}}, ""
    if env and not os.environ.get(env):
        return {"offer": {"httpCode": None, "error": f"{env} unset"},
                "solvency": {"httpCode": None, "error": f"{env} unset"}}, ""
    return {"offer": http_get(probe.get("offerUrl", ""), env,
                              needle=probe.get("offerMustInclude") or None),
            "solvency": http_get(probe.get("solvencyUrl", ""), env)}, ""


def ordered_candidates(pref, override):
    """Order the probe candidates. With an override that matches a preference
    entry, that entry goes FIRST (A5: the override is probed first). Without a
    match, a synthetic entry carries the override id — it has no probe
    endpoint, so it will be reported as unprobeable rather than silently
    resolving."""
    entries = [e for e in pref if isinstance(e, dict)]
    if not override:
        return entries
    ov = norm_model(override)
    match = next((e for e in entries if norm_model(e.get("model", "")) == ov), None)
    if match is not None:
        return [match] + [e for e in entries if e is not match]
    return [{"model": override}] + entries


def resolve(cfg, pref, fixture):
    """First solvent+reachable+independent candidate → (model|None, notes[]).
    Applies the build-equivalence filter (A2) — a same-build candidate is never
    a resolution, even in a fixture-backed probe."""
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
# A1: this mode MUST reject an unusable authority and apply the same
# non-vacuity checks — otherwise it prints INDEPENDENT (exit 1) for a config
# check (f) reads as a pass, defeating the gate's own backstop.
if mode == "equivalence":
    cfg, err = load_authority(authority)
    if cfg is None:
        print(f"❌ second-model guard: {err}", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    validate(cfg, "authority")
    if fatals > 0:
        for sev, msg in lines:
            if sev == BLOCK:
                print(f"❌ {msg}", file=sys.stderr)
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
    cfg, err = load_authority(authority) if authority else (None, "no authority path")
    if cfg is None:
        # A4: a missing/unparseable authority is exit 2, not 0. A caller doing
        # `id=$(… --print) || fail` must NOT read junk as "resolved".
        print(f"❌ second-model gate: {err} — the designation authority is unusable (fail closed; run pi-bootstrap/setup.sh to install it)", file=sys.stderr)
        print("**DEGRADED")
        sys.exit(2)
    pref = cfg.get("preference") if isinstance(cfg.get("preference"), list) else []
    if not pref:
        print("⚠️  second-model gate: config has no usable `preference` list — DEGRADED", file=sys.stderr)
        print("**DEGRADED")
        sys.exit(1)
    for i, entry in enumerate(pref):
        if not isinstance(entry, dict):
            print(f"❌ second-model gate: preference[{i}] is not an object — DEGRADED (fail closed)", file=sys.stderr)
            print("**DEGRADED")
            sys.exit(2)
        model = entry.get("model")
        if not isinstance(model, str) or not model:
            print(f"❌ second-model gate: preference[{i}].model is not a non-empty string — DEGRADED (fail closed)", file=sys.stderr)
            print("**DEGRADED")
            sys.exit(2)
    eq = equivalence_set(cfg)
    if probe_fixture:
        fixture, err = load_fixture(probe_fixture)
        if err:
            print(f"❌ second-model gate: {err}", file=sys.stderr)
            print("**DEGRADED")
            sys.exit(2)
        model, notes = resolve(cfg, [e for e in pref if isinstance(e, dict)], fixture)
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
    cfg, err = load_authority(authority) if authority else (None, "no authority path")
    if cfg is None:
        print(f"❌ second-model guard: {err}", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    # Shared validator: the probe refuses an authority `--check` would reject.
    validate(cfg, "authority", probe_urls=True)
    if fatals > 0:
        for sev, msg in lines:
            if sev == BLOCK:
                print(f"❌ {msg}", file=sys.stderr)
        print("DEGRADED")
        sys.exit(2)
    pref = [e for e in (cfg.get("preference") or []) if isinstance(e, dict)]
    patterns = cfg.get("unreachablePatterns", [])
    fixture = None
    if probe_fixture:
        fixture, err = load_fixture(probe_fixture)
        if fixture is None:
            print(f"❌ second-model guard: {err}", file=sys.stderr)
            print("DEGRADED")
            sys.exit(2)
    print("== second-model probe (#716) — vendor offer + solvency ==")
    if operator_override:
        print(f"   ⚠️  $SECOND_MODEL={operator_override} operator override active — probed FIRST; config-default fail-closed, operator-override-open-by-design", file=sys.stderr)
    eq = equivalence_set(cfg)
    candidates = ordered_candidates(pref, operator_override)
    model = None
    for entry in candidates:
        mid = entry.get("model", "")
        if is_equivalent(mid, eq):
            # A2: the probe loop applies the SAME equivalence filter as --print.
            print(f"  ⚠️  {mid}: build-equivalent (skipped)")
            continue
        if operator_override and norm_model(mid) == norm_model(operator_override) \
                and not any(norm_model(e.get("model", "")) == norm_model(operator_override) and e.get("probe") for e in pref):
            # An override with no declared probe endpoint cannot be certified:
            # the probe gates liveness, so it must not emit RESOLVED for it.
            print(f"  ⚠️  {mid}: $SECOND_MODEL override declares no probe endpoint in `preference` — liveness UNVERIFIED; the probe cannot certify it (use --print for dispatch authority)")
            continue
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
    print("   ⛔ SECOND_MODEL_GATE_OVERRIDE=1 is SET — guard BLOCKs will be SILENCED (escape hatch, see docs/providers.md §Second-model gate)")
print("")

cfg, err = load_authority(authority) if authority else (None, "no authority path")
if cfg is None:
    die(f"authority unusable: {err} — the second-model designation is gone (fail closed)")
    print("")
    print("❌ second-model gate: fail-closed exit 2 — no usable designation authority.")
    sys.exit(2)

print(f"authority: {authority}")
if operator_override:
    warn(f"$SECOND_MODEL={operator_override} operator override active — the config default is NOT what a gate would dispatch; annotate the gate line with the resolved id")
pref = validate(cfg, "authority", probe_urls=True)
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

# Escape-hatch policy (D7): the override silences BLOCKs only. An
# unusable-authority fatal (exit 2) is NEVER overridable — there is nothing to
# override when the designation authority is missing or invalid.
if fatals > 0:
    print(f"❌ second-model gate: fail-closed exit 2 — {fatals} unusable-authority violation(s) (missing/unparseable config, non-object config, undeclared runtimeVia, empty equivalence set, insecure probe destination).")
    sys.exit(2)
if override_flag == "1":
    print("⛔ SECOND_MODEL_GATE_OVERRIDE=1 — BLOCK silenced by the documented escape hatch. Violations above are still DETECTED;")
    print("   sanctioned only for the bootstrap/rollback window (see #716).")
    print("⛔ Guard: OVERRIDDEN → exit 0")
    sys.exit(0)
if blocks > 0:
    print(f"❌ second-model gate: {blocks} BLOCK-level violation(s) — fix pi-bootstrap/pi-config/second-model.json, or use SECOND_MODEL_GATE_OVERRIDE=1 (documented escape).")
    sys.exit(1)
if warns > 0:
    print(f"⚠️  second-model gate: PASS with {warns} warning(s).")
else:
    print("✅ second-model gate: PASS — the ordered preference is independent of the primary's served build and every candidate declares its dispatch authority.")
sys.exit(0)
PYEOF
