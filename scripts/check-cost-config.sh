#!/bin/bash
# check-cost-config.sh — #341 drift guard: deepseek context clamp @300K (shipped w/ #476 guard-sync).
#
# Config-as-authority: models.json is the runtime clamp surface (pi's
# provider-composer resolves override.contextWindow ?? model.contextWindow —
# config wins over the 4h pi.dev catalog refresh, which only rewrites the
# STORE). This guard asserts the clamp never silently drifts back to 1M.
#
# Semantics (detect-not-block for the catalog class — a hard red on the store
# would break auto-sync when pi's refresh legitimately reverts it):
#   models.json    drift (any deepseek-served id > 300000)  → BLOCK (exit 1)
#   settings.json  drift (compaction block / settings-vs-guard
#                  mismatch, or a DERIVED retry/hang window over
#                  ceiling)                                  → BLOCK (exit 1)
#   patch-pi-retry.sh backoff cap != the guard's cap           → BLOCK (exit 1)
#     (unreadable/missing patch script = fail-closed BLOCK — the
#      window arithmetic cannot be asserted without it)
#   models-store.json drift                                   → WARN (detected)
#   MISSING shipped models.json / settings.json              → BLOCK (the
#     clamp authority deleted = clamp gone while CI stays green)
#   MISSING store / live-dir files                           → WARN (4h
#     refresh / first-install path)
# The weekly report (fleet-cost-report.sh) + tripwire are the store alert path.
#
# Escape hatch: COST_CLAMP_OVERRIDE=1 silences the CLAMP BLOCK (models.json /
# models-store/catalog class) — prints a loud warning, still detects
# (exit 0) — documented in docs/ops/cost-config-policy.md; sanctioned only for
# the clamp's rollback window. It does NOT cover the retry/hang contract
# (#1088): those violations count in RETRY_BLOCKS and still exit 1. An ambient
# env var must not be able to defeat the retry bound.
#
# Usage:
#   check-cost-config.sh                  shipped + live (live = $HOME/.pi/agent)
#   check-cost-config.sh --shipped-only   pre-commit / CI (no live dir access)
#   check-cost-config.sh --live-dir PATH  live pass against a specific dir
#
# Dep-free of npm: bash + POSIX coreutils + python3 (stdlib only). The parse is
# a python3 JSON-tree walk — format-independent (pretty-printed, minified,
# reordered fields, nested provider/modelOverrides structures all resolve the
# same). python3 is already the fixture-suite dependency and is present on
# ubuntu-latest + macOS.
set -uo pipefail

# Fail-closed on a missing python3 (the JSON-tree-walk detector depends on it):
# a config we cannot parse must never read green (review P2 — PATH-stripped
# python3 previously produced a PASS on an unparsed config).
command -v python3 >/dev/null 2>&1 || { echo "error: python3 required (stdlib only) — present on ubuntu-latest + macOS" >&2; exit 2; }

# Repo root, resolved once. Defined here (not next to the retry constants below) because the
# compaction-regime block further down READS the fleet regime floor out of two instrument scripts
# under $ROOT — under `set -u` a use-before-assignment would make every run take the fail-closed
# exit-2 path.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# #1213's 300K→700K dial (2026-09-18, PR #1226) is WITHDRAWN (2026-09-21):
# the floor fix it was sequenced behind is deployed (pi-patch #1214(b),
# `MIN_USABLE_MAX_TOKENS = 1024` — never clamp below a usable output budget),
# which closes the one-token silent-death mechanism the wider window was bought
# for, at a recurring ~+20% fleet spend. Re-raising 700K needs a NEW decision
# — see docs/ops/cost-config-policy.md §7's withdrawal record for the residual
# (the floor fix is verified against the silent-death failure only, not every
# failure the wider window covered).
CLAMP=300000

# The compaction trigger the truncation watcher and the cost report band on:
#   FLEET_REGIME_TB = CLAMP − compaction.reserveTokens   (283,616 = 300,000 − 16,384)
#
# Two assertions, and BOTH are needed:
#
#   1. INDEPENDENT — reserveTokens must equal the reviewed value (16384). This is the only
#      constraint that survives a COORDINATED move of the window and the reserve. Asserting only
#      the geometry below reads green on `contextWindow 1000000 / reserveTokens 716384`, which
#      preserves the 283616 trigger while inflating the summarization cap to 0.8 x 716384 — the
#      exact reserve-inflation workaround the recorded owner directive on #1227 forbids
#      ("Do not implement the decoupling by inflating reserveTokens"). Removing this pin
#      introduced that false PASS, and a guard whose only reserve constraint CLAMP can move is
#      not a constraint.
#
#   2. DERIVED — the geometry must match the floor the instruments band on. The FLOOR is READ
#      FROM the instruments (`fleet-cost-report.sh`'s `FLEET_REGIME_TB:-<n>` default and
#      `watch-truncation.sh`'s clamp-bucket boundary), never restated here, so a literal in this
#      file cannot prove the shell agrees with itself. The window term is the guard's own CLAMP —
#      the ceiling the models.json check enforces — not a second copy of the floor. This leg
#      catches a CLAMP drift and an instrument drift (the #1213/#1304 withdrawal moved 50000→16384,
#      the trigger 250000→283616; moving ONE instrument alone must also fail).
REGIME_TB_REPORT_ALL="$(sed -n 's/.*FLEET_REGIME_TB:-\([0-9][0-9]*\)}.*/\1/p' "$ROOT/scripts/fleet-cost-report.sh" 2>/dev/null)"
# Anchored on the BUCKET LABEL, not on the bare `if N <= tb <` shape: the watcher states
# `<= tb <` in more than one bucket boundary (the retired 700K-era `if 650000 <= tb < 900000`
# still sits beside the live one), so the shape alone is ambiguous. The uniqueness assertion
# below is kept as the backstop: if the label moves or a second labelled statement appears,
# the guard refuses rather than picking by source order.
REGIME_TB_WATCH_ALL="$(sed -n 's/.*"300K-clamp[^"]*" if \([0-9][0-9]*\) <= tb <.*/\1/p' "$ROOT/scripts/watch-truncation.sh" 2>/dev/null)"
REGIME_TB_REPORT="$(printf '%s\n' "$REGIME_TB_REPORT_ALL" | sed '/^$/d' | head -1)"
REGIME_TB_WATCH="$(printf '%s\n' "$REGIME_TB_WATCH_ALL" | sed '/^$/d' | head -1)"
if [ -z "$REGIME_TB_REPORT" ] || [ -z "$REGIME_TB_WATCH" ]; then
  echo "error: cannot read the fleet regime floor from scripts/fleet-cost-report.sh ($REGIME_TB_REPORT) / scripts/watch-truncation.sh ($REGIME_TB_WATCH) — the reserve cannot be asserted as a derived relation, so it must not read green" >&2
  exit 2
fi
# AMBIGUITY is a refusal, not a pick. The watcher states the floor in more than one bucket
# boundary (the retired 700K-era `if 650000 <= tb < 900000` still sits beside the live one), so a
# bare `head -1` silently resolves the floor by SOURCE ORDER: a legitimate reorder, or a comment
# line containing `if N <= tb <`, would make the guard report "the instruments disagree" when they
# do not. An ambiguous derivation is not a derivation.
REGIME_TB_REPORT_N="$(printf '%s\n' "$REGIME_TB_REPORT_ALL" | sed '/^$/d' | wc -l | tr -d ' ')"
REGIME_TB_WATCH_N="$(printf '%s\n' "$REGIME_TB_WATCH_ALL" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$REGIME_TB_REPORT_N" != "1" ] || [ "$REGIME_TB_WATCH_N" != "1" ]; then
  echo "error: the fleet regime floor is AMBIGUOUS in the instruments (fleet-cost-report.sh: ${REGIME_TB_REPORT_N} match(es): $(printf '%s' "$REGIME_TB_REPORT_ALL" | tr '\n' ' '); watch-truncation.sh: ${REGIME_TB_WATCH_N} match(es): $(printf '%s' "$REGIME_TB_WATCH_ALL" | tr '\n' ' ')) — exactly one statement per instrument is required, so the floor cannot be derived by source order" >&2
  exit 2
fi
if [ "$REGIME_TB_REPORT" != "$REGIME_TB_WATCH" ]; then
  echo "error: the fleet regime floor disagrees between the instruments: fleet-cost-report.sh says $REGIME_TB_REPORT, watch-truncation.sh says $REGIME_TB_WATCH — the reserve cannot derive a floor the instruments disagree on" >&2
  exit 2
fi
FLEET_REGIME_TB="$REGIME_TB_REPORT"
# The reviewed reserve (#1227). Asserted independently of the geometry — see note 1 above.
REVIEWED_RESERVE=16384

# ── retry/hang contract (#1088) — the bounded-retry window ────────────────
# `retry.maxRetries` is an ATTEMPT budget with no wall-clock deadline in pi,
# so the session's real exposure is (maxRetries+1) x per-attempt ceiling
# + sum(backoff). Pinning the count alone (the pre-#1088 guard) let a
# 10000-attempt x 10-min x 5-min-backoff product (34-104 days) stay green.
# Every number below is therefore asserted BOTH by exact value AND through
# the derived window: change one without the others and this guard fires.
#
#   HTTP_IDLE_TIMEOUT_MS       the SILENT-HANG ceiling — undici's
#                              headers/body idle timeout, i.e. time-to-first-
#                              byte PLUS inter-chunk idle (a hung attempt emits
#                              no bytes; this fires long before the SDK's total
#                              request timeout). #1088's measured signature is
#                              exactly this mode: 0 B of socket traffic on a
#                              session that never terminates. Pinned to pi's own
#                              DEFAULT_HTTP_IDLE_TIMEOUT_MS (300000,
#                              dist/core/http-dispatcher.js) — do NOT go below
#                              it without a measurement: it is also the ceiling
#                              on a 300K-context prefill's time-to-first-byte.
#   RETRY_PROVIDER_TIMEOUT_MS  the legitimate-call ceiling (SDK total request
#                              timeout). Must EXCEED the idle ceiling so a hung
#                              attempt is cut by idle, not by the full budget;
#                              must stay high enough that a 300K-context
#                              compaction/summarization is not false-killed.
#   RETRY_MAX_BACKOFF_MS       the patch's backoff cap (read back out of
#                              scripts/patch-pi-retry.sh — one source of truth).
#   HANG_WINDOW_CEILING_MS     declared bound on the no-progress window.
#   WORST_WINDOW_CEILING_MS    declared bound on the total-timeout window
#                              (every attempt burns its full SDK ceiling).
# Recompute after ANY change with:
#   bash scripts/check-cost-config.sh --live-dir pi-bootstrap/pi-config
HTTP_IDLE_TIMEOUT_MS=300000
RETRY_MAX_RETRIES=7
RETRY_BASE_DELAY_MS=2000
RETRY_MAX_BACKOFF_MS=60000
RETRY_PROVIDER_TIMEOUT_MS=600000
HANG_WINDOW_CEILING_MS=2700000
WORST_WINDOW_CEILING_MS=5400000
PATCH_SCRIPT="$ROOT/scripts/patch-pi-retry.sh"
SHIPPED_DIR="$ROOT/pi-bootstrap/pi-config"
LIVE_DIR="${HOME}/.pi/agent"
SHIPPED_ONLY=0
OVERRIDE="${COST_CLAMP_OVERRIDE:-0}"
BLOCKS=0
RETRY_BLOCKS=0
SETTINGS_BLOCKS=0
WARNS=0

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --shipped-only) SHIPPED_ONLY=1 ;;
    --live-dir) shift; LIVE_DIR="${1:-}"; [ -n "$LIVE_DIR" ] || { echo "error: --live-dir requires a path"; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done

ok()  { echo "  ✅ $1"; }
# detail() — an indented diagnostic line attached to the preceding block/warn.
# Never counts as a block: it only explains one that was already counted.
detail() { echo "      ↳ $1"; }
warn() { echo "  ⚠️  $1"; WARNS=$((WARNS + 1)); }
block() { echo "  ❌ $1"; BLOCKS=$((BLOCKS + 1)); }
# Two block classes the clamp escape must NOT silence, because neither has a
# rollback window (the override exists for exactly one: reverting the models.json
# contextWindow threshold). Both are counted separately and force exit 1 even
# with COST_CLAMP_OVERRIDE=1 set — an ambient env var must not be able to defeat
# the retry bound (#1088 review P1) or to hide a reverted/disabled settings
# contract. `block()` stays for the clamp class (models.json/modelOverrides).
block_retry() { echo "  ❌ $1"; BLOCKS=$((BLOCKS + 1)); RETRY_BLOCKS=$((RETRY_BLOCKS + 1)); }
block_settings() { echo "  ❌ $1"; BLOCKS=$((BLOCKS + 1)); SETTINGS_BLOCKS=$((SETTINGS_BLOCKS + 1)); }

# deepseek_violations <file> — canonical matcher over the PARSED JSON tree.
# Format-independent: walks every dict/list node (pretty, minified, reordered
# fields, nested providers/modelOverrides). Resolves deepseek-served ids two
# ways: (1) model entries (`"id"` + `contextWindow` co-located in
# providers.*.models[]), (2) modelOverrides map keys (the key IS the model id,
# the value dict holds `contextWindow`). Normalizes each id (strips
# `provider/` and `~provider/` prefixes) and flags deepseek-served family ids
# (canonical `deepseek-flash`, its `deepseek-v4-flash` legacy alias, and the
# `deepseek-v4-pro` / future bare `deepseek-pro` family — every variant: dotted
# `v4.1` ids, hyphenated `v4-1` ids (e.g. the venice `deepseek-v4-1-flash`
# row, #747), -0731, -vision-exp, -0813, -latest, and any `:`-suffixed routing
# shape (e.g. the `:batch` control in the fixture suite). Deliberately NOT
# matched: non-family ids such as `deepseek-proxy` / `deepseek-flashlight`)
# whose effective contextWindow exceeds CLAMP. Emits one
# `id contextWindow=N` line per violation; PARSE_ERROR line + exit 1 on
# unparseable input (a file we cannot assert on must never read green).
deepseek_violations() {
  python3 - "$CLAMP" "$1" <<'PYEOF'
import json, re, sys

clamp = int(sys.argv[1])
path = sys.argv[2]
DS = re.compile(r'^deepseek-(?:v4(?:[.\-]\d+)?-)?(?:flash|pro)(?:[-:]|$)')

def norm(id_):
    return re.sub(r'^~?[^/]*/', '', id_) if '/' in id_ else id_

viol = []

def walk(node):
    if isinstance(node, dict):
        # (1) model entries in providers.*.models[] — id + contextWindow co-located
        if isinstance(node.get("id"), str):
            cw = node.get("contextWindow")
            if isinstance(cw, (int, float)) and DS.match(norm(node["id"])) and cw > clamp:
                viol.append(f'{node["id"]} contextWindow={cw}')
        # (2) modelOverrides map keys — the key IS the model id, value holds contextWindow
        for key, val in node.items():
            if (isinstance(key, str) and isinstance(val, dict)
                    and isinstance(val.get("contextWindow"), (int, float))
                    and DS.match(norm(key)) and val["contextWindow"] > clamp):
                viol.append(f'{key} contextWindow={val["contextWindow"]}')
        for val in node.values():
            walk(val)
    elif isinstance(node, list):
        for item in node:
            walk(item)

try:
    with open(path) as f:
        walk(json.load(f))
except Exception as e:
    print(f"PARSE_ERROR: {path}: {e}")
    sys.exit(1)

for v in viol:
    print(v)
sys.exit(1 if viol else 0)
PYEOF
}

# ── resolve the patch's backoff cap by ASKING the patch script ───────────
# The cap is interpolated into the pi dist patch, so `patch-pi-retry.sh` owns
# it; the guard reads it back rather than duplicating it. It is read by
# EXECUTION (`--cap` prints the resolved $CAP_MS), never by parsing the
# assignment text. A static parse cannot bound the ways a shell assigns a
# variable: `declare`/`local`/`eval`/`printf -v`, or a second assignment
# chained with `;` on the same line, were all invisible to a line-anchored
# regex — the guard then read 60000, exited 0, and reported a 60000ms window
# while the script applied 300000 (#1088 review). Those shapes are why the
# value is now obtained from the shell that will use it.
#
# PI_MAX_RETRY_DELAY_MS is UNSET for the call so this reads the script's
# DEFAULT cap (the contract value), not an ambient override. A missing script,
# a non-zero exit, or a non-integer/hollow answer all leave the window
# underivable and fail CLOSED below.
PATCH_CAP_RESOLVED=""
PATCH_CAP_WHY=""
_cap_out="$(env -u PI_MAX_RETRY_DELAY_MS bash "$PATCH_SCRIPT" --cap 2>/dev/null)"
_cap_rc=$?
case "$_cap_out" in
  *[!0-9]*|'')
    PATCH_CAP_WHY="patch-pi-retry.sh --cap did not print a plain integer (got '$_cap_out', rc=$_cap_rc)" ;;
  *)
    # A non-zero exit is NOT tolerated even when a valid-looking integer came
    # back: a script that reports one value and then fails is not one whose
    # answer can be trusted, and the comment above promises this fails closed.
    if [ "$_cap_rc" -ne 0 ]; then
      PATCH_CAP_WHY="patch-pi-retry.sh --cap exited non-zero (rc=$_cap_rc, printed '$_cap_out')"
    else
      PATCH_CAP_RESOLVED="$_cap_out"
    fi ;;
esac

# settings_violations <settings-file> <patch-script> — compaction block
# (enabled must be TRUE, plus reserveTokens/keepRecentTokens) + the bounded
# retry/hang contract (#1088), over the PARSED JSON tree. Emits one issue line
# per drift; PARSE_ERROR line + exit 1 on unparseable input. Always emits a
# `WINDOW hung=<ms> worst=<ms> backoff=<ms>` line on stdout (the derived
# window) so check_settings_file can report the number it actually enforced
# rather than a hardcoded one.
settings_violations() {
  python3 - "$1" "$2" "$HTTP_IDLE_TIMEOUT_MS" "$RETRY_MAX_RETRIES" \
    "$RETRY_BASE_DELAY_MS" "$RETRY_MAX_BACKOFF_MS" "$RETRY_PROVIDER_TIMEOUT_MS" \
    "$HANG_WINDOW_CEILING_MS" "$WORST_WINDOW_CEILING_MS" \
    "$PATCH_CAP_RESOLVED" "$PATCH_CAP_WHY" "$CLAMP" "$FLEET_REGIME_TB" "$REVIEWED_RESERVE" <<'PYEOF'
import json, math, re, sys

path, patch_path = sys.argv[1], sys.argv[2]
# The cap, RESOLVED by the shell that owns it (the resolver above) — never
# parsed out of the assignment text. argv[10] = value or "", argv[11] = why.
CAP_RESOLVED, CAP_WHY = sys.argv[10], sys.argv[11]
CLAMP_VALUE, REGIME_TB, REVIEWED_RESERVE = int(sys.argv[12]), int(sys.argv[13]), int(sys.argv[14])
(IDLE_EXPECTED, MR_EXPECTED, BASE_EXPECTED, CAP_EXPECTED,
 PROVIDER_EXPECTED, HANG_CEILING, WORST_CEILING) = map(int, sys.argv[3:10])

issues = []
retry_issues = []        # emitted with the RETRY_CONTRACT: tag (override-immune)

def q(v):
    if v is None:
        return "'missing'"
    if isinstance(v, bool):
        return str(v).lower()
    return repr(v)

try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR: {path}: {e}")
    sys.exit(1)

# Valid JSON that is not an object (`[1,2,3]`, `"x"`, `42`, `null`) carries no
# `compaction`/`retry` keys at all — the contract is unassertable, and the bare
# `d.get(...)` below used to raise AttributeError, whose traceback reached the
# guard's issue loop as an UNTAGGED line and was therefore emitted with plain
# block(), silencing it under COST_CLAMP_OVERRIDE=1 (#1088 review cycle 3, P1).
if not isinstance(d, dict):
    print(f"RETRY_CONTRACT: {path} is not a JSON object (got {type(d).__name__}) — the compaction + "
          "retry/hang contract cannot be asserted (fail-closed)")
    sys.exit(1)

comp = d.get("compaction")
if not isinstance(comp, dict):
    issues.append(f"compaction.reserveTokens expected (a positive integer deriving the {REGIME_TB} clamp trigger), got 'missing'")
    issues.append("compaction.keepRecentTokens expected 12000, got 'missing'")
    issues.append("compaction.enabled expected true, got 'missing'")
else:
    if comp.get("enabled") is not True:
        issues.append(f"compaction.enabled expected true, got {q(comp.get('enabled'))}")
    # INDEPENDENT leg (#1227): the reserve must be the reviewed value. Without this, a
    # coordinated move of the window AND the reserve satisfies the geometry below while
    # inflating the summarization cap — a false PASS this guard must not produce.
    # Whole-number floats are accepted (JSON `16384.0` IS 16384 — `_as_int` documents the same
    # doctrine elsewhere in this block); bool is not a number.
    reserve = comp.get("reserveTokens")
    # `math.isfinite` FIRST: `json.load` accepts NaN/Infinity, and `int(nan)` raises inside
    # this heredoc — which would turn a clean settings diagnostic into a retry/hang-contract
    # block with a raw traceback (the wrong cause, attributed to the wrong class).
    reserve_ok = (
        not isinstance(reserve, bool)
        and isinstance(reserve, (int, float))
        and math.isfinite(reserve)
        and reserve == int(reserve)
        and reserve > 0
    )
    if not reserve_ok:
        issues.append(f"compaction.reserveTokens expected the reviewed integer {REVIEWED_RESERVE}, got {q(reserve)}")
    else:
        reserve = int(reserve)
        if reserve != REVIEWED_RESERVE:
            issues.append(
                f"compaction.reserveTokens = {reserve}, but the reviewed value is {REVIEWED_RESERVE} "
                f"(owner directive on #1227: the decoupling is not to be faked by inflating the "
                f"reserve — that inflates the summarization cap to 0.8 x reserve)"
            )
        # DERIVED leg: the geometry must match the floor the instruments band on.
        trigger = CLAMP_VALUE - reserve
        if trigger != REGIME_TB:
            issues.append(
                f"the guard's clamp/reserve geometry derives {trigger} "
                f"({CLAMP_VALUE} clamp − {reserve}), but the fleet regime floor is {REGIME_TB} "
                f"(read from scripts/fleet-cost-report.sh / scripts/watch-truncation.sh) — "
                f"the reserve and the regime band have drifted apart"
            )
    if comp.get("keepRecentTokens") != 12000:
        issues.append(f"compaction.keepRecentTokens expected 12000, got {q(comp.get('keepRecentTokens'))}")

retry = d.get("retry") if isinstance(d.get("retry"), dict) else {}
provider = retry.get("provider") if isinstance(retry.get("provider"), dict) else {}
mr = retry.get("maxRetries")
base = retry.get("baseDelayMs")
idle = d.get("httpIdleTimeoutMs")
ptimeout = provider.get("timeoutMs")
pmr = provider.get("maxRetries")

if mr != MR_EXPECTED:
    retry_issues.append(f"retry.maxRetries expected {MR_EXPECTED} (bounded-hang contract), got {q(mr)}")
if base != BASE_EXPECTED:
    retry_issues.append(f"retry.baseDelayMs expected {BASE_EXPECTED} (the hang-window arithmetic), got {q(base)}")
if idle != IDLE_EXPECTED:
    retry_issues.append(f"httpIdleTimeoutMs expected {IDLE_EXPECTED} (the silent-hang ceiling), got {q(idle)}")
if ptimeout != PROVIDER_EXPECTED:
    retry_issues.append(f"retry.provider.timeoutMs expected {PROVIDER_EXPECTED} (the per-call ceiling), got {q(ptimeout)}")
# Provider-level retries multiply the provider calls inside ONE attempt, so they
# are part of the window. pi's own settings doc says keep this at 0.
if pmr not in (None, 0):
    retry_issues.append(f"retry.provider.maxRetries must be absent or 0 (it multiplies calls per attempt), got {q(pmr)}")

# The cap arrives already resolved (see the resolver above): the shell ran
# `patch-pi-retry.sh --cap` and passed the answer in. Nothing here re-parses the
# script — a static parse could not see every assignment form and let the guard
# report a cap the script did not apply (#1088 review).
patch_cap = int(CAP_RESOLVED) if CAP_RESOLVED.isdigit() else None
if patch_cap is None:
    retry_issues.append(f"retry backoff cap unreadable from {patch_path} — cannot bound the hang window (fail-closed)"
                        + (f": {CAP_WHY}" if CAP_WHY else ""))
elif patch_cap != CAP_EXPECTED:
    retry_issues.append(f"patch-pi-retry.sh backoff cap expected {CAP_EXPECTED}, got {patch_cap}")

# Ceiling ordering: a hung attempt must be cut by the IDLE ceiling, not by the
# full per-call budget — otherwise the idle ceiling is inert and the hang
# window silently becomes maxRetries x providerTimeout.
if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (idle, ptimeout)) \
   and ptimeout <= idle:
    retry_issues.append(f"retry.provider.timeoutMs ({ptimeout}) must exceed httpIdleTimeoutMs ({idle}) — "
                        f"otherwise the silent-hang ceiling can never fire first")

# Derived window. The no-progress (hung) window uses the idle ceiling; the
# worst-case window assumes every attempt burns its full SDK request ceiling.
def _as_int(v):
    """Positive whole number as int (JSON `8.0` IS 8 — pi reads it as a number),
    else None. A None anywhere means the window cannot be derived."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        return None
    if v <= 0 or v != int(v):
        return None
    return int(v)

_fields = (("retry.maxRetries", mr), ("retry.baseDelayMs", base),
           ("patch-pi-retry.sh cap", patch_cap),
           ("httpIdleTimeoutMs", idle), ("retry.provider.timeoutMs", ptimeout))
_ints = {k: _as_int(v) for k, v in _fields}
if all(v is not None for v in _ints.values()):
    n = _ints["retry.maxRetries"]
    base = _ints["retry.baseDelayMs"]
    patch_cap = _ints["patch-pi-retry.sh cap"]
    idle = _ints["httpIdleTimeoutMs"]
    ptimeout = _ints["retry.provider.timeoutMs"]
    backoff, v, i = 0, base, 0
    while i < n:
        if v >= patch_cap:
            backoff += patch_cap * (n - i)
            break
        backoff += v
        v *= 2
        i += 1
    hang = (n + 1) * idle + backoff
    worst = (n + 1) * ptimeout + backoff
    print(f"WINDOW hung={hang} worst={worst} backoff={backoff}")
    if hang > HANG_CEILING:
        retry_issues.append(f"hang window {hang}ms ({hang / 60000:.1f} min) exceeds the declared "
                            f"ceiling {HANG_CEILING}ms — the retry budget and the per-attempt "
                            f"ceiling drifted apart")
    if worst > WORST_CEILING:
        retry_issues.append(f"worst-case window {worst}ms ({worst / 60000:.1f} min) exceeds the "
                            f"declared ceiling {WORST_CEILING}ms")
else:
    # NO WINDOW line here. `check_settings_file` treats a MISSING derived window
    # as the fail-closed retry-class block; a zeroed sentinel is a *present*
    # window, so any non-integer input used to skip the ceiling check entirely
    # while the exact-value compares still passed (JSON `"maxRetries": 8.0` == 8).
    # That was a reproduced bypass of the hang ceiling (#1088 review cycle 6, P1):
    # the guard exited 0 reporting `hung 0ms / worst 0ms`.
    _bad = ", ".join(f"{k}={v!r}" for k, v in _fields
                     if _ints[k] is None or _ints[k] <= 0)
    retry_issues.append("the retry/hang window cannot be derived (not a positive whole "
                        f"number: {_bad}) — fail-closed")

for i in issues:
    print(i)
for i in retry_issues:
    print(f"RETRY_CONTRACT: {i}")
sys.exit(1 if (issues or retry_issues) else 0)
PYEOF
}

# check_model_file <file> <label> <class> <missing> — class: models → BLOCK,
# store → WARN; missing: block → BLOCK on absent file (shipped authority),
# warn → WARN (store class / live first-install path).
check_model_file() {
  local file="$1" label="$2" class="$3" missing="$4" viol v
  if [ ! -f "$file" ]; then
    if [ "$missing" = "block" ]; then
      block "$label: file missing ($file) — the clamp authority is gone (deleted = clamp reverted while CI stays green)"
    else
      warn "$label: file missing ($file)"
    fi
    return
  fi
  viol="$(deepseek_violations "$file")"
  if [ -n "$viol" ]; then
    while IFS= read -r v; do
      case "$v" in
        PARSE_ERROR:*)
          if [ "$class" = "models" ]; then
            block "$label — $v (cannot assert the clamp on unparseable config)"
          else
            warn "$label — $v (cannot assert the clamp on unparseable store snapshot)"
          fi
          ;;
        *)
          if [ "$class" = "models" ]; then
            block "$label — deepseek-served $v > ${CLAMP} (models.json is the config authority; a live 1M session means ~50x cold re-ingestion)"
          else
            warn "$label — deepseek-served $v > ${CLAMP} (catalog class — DETECTED, not blocked; the 4h refresh may legitimately revert it)"
          fi
          ;;
      esac
    done <<< "$viol"
  else
    ok "$label — all deepseek-served ids ≤ ${CLAMP}"
  fi
}

# check_settings_file <file> <label> <missing> — compaction block (enabled +
# reserve/keep) + the bounded retry/hang contract, BLOCK on drift.
check_settings_file() {
  local file="$1" label="$2" missing="$3" raw window_hung window_worst issues i
  if [ ! -f "$file" ]; then
    if [ "$missing" = "block" ]; then
      # block_retry, not block: this file carries the bounded retry/hang contract
      # as well as the compaction block, and a DELETED settings file is not a
      # clamp rollback. A plain block here let COST_CLAMP_OVERRIDE=1 exit 0 with
      # the whole contract reverted (#1088 review cycle 2, P1).
      block_retry "$label: file missing ($file) — the compaction + retry/hang contract is gone (deleted = contract reverted while CI stays green; not a clamp rollback, so the override does NOT cover it)"
    else
      warn "$label: file missing ($file)"
    fi
    return
  fi
  raw="$(settings_violations "$file" "$PATCH_SCRIPT" 2>&1)"
  # The WINDOW line reports the derived window the guard actually enforced;
  # it is emitted on every run (also when clean) so the PASS line names a
  # measured number instead of a hardcoded one.
  window_hung="$(printf '%s\n' "$raw" | sed -n 's/^WINDOW hung=\([0-9]*\) .*/\1/p')"
  window_worst="$(printf '%s\n' "$raw" | sed -n 's/^WINDOW hung=[0-9]* worst=\([0-9]*\) .*/\1/p')"
  issues="$(printf '%s\n' "$raw" | sed '/^WINDOW /d')"
  if [ -z "$window_hung" ] || [ "$window_hung" = "0" ]; then
    # settings_violations emits the derived WINDOW line on every run that CAN
    # derive the window. It emits NONE when it dies before deriving (unparseable
    # file, non-object JSON, an internal error) and ALSO none on the underivable
    # arm (a non-positive/non-integer input reports "cannot be derived"). Both
    # are contract-unassertable, so BOTH take this fail-CLOSED **and
    # override-immune** arm: emitting this as a plain block() is what let
    # COST_CLAMP_OVERRIDE=1 exit 0 with the retry/hang contract unasserted
    # (#1088 review cycles 2 and 3, P1). Placed BEFORE the issues loop so every
    # such failure — known shape or not — takes this arm.
    block_retry "$label — the settings file could not be analysed, so the retry/hang contract cannot be asserted (fail-closed; not covered by COST_CLAMP_OVERRIDE=1)"
    # Every diagnostic, not just the first: the analyser emits one line per
    # problem (e.g. an exact-value drift AND the reason the window is
    # underivable), and head -1 hid the cause that matters (#1088 cycle 6).
    while IFS= read -r i; do
      [ -n "$i" ] && detail "$i"
    done <<< "$issues"
  elif [ -n "$issues" ]; then
    while IFS= read -r i; do
      case "$i" in
        RETRY_CONTRACT:*) block_retry "$label — ${i#RETRY_CONTRACT: }" ;;
        # Compaction/settings drift (enabled=false, reserve/keep reverted) has no
        # rollback window either, so the clamp escape must not silence it.
        *) block_settings "$label — $i" ;;
      esac
    done <<< "$issues"
  else
    ok "$label — compaction (enabled + reserve ${REVIEWED_RESERVE} + keep 12000; guard geometry ${CLAMP}−${REVIEWED_RESERVE}=$((CLAMP - REVIEWED_RESERVE)) matches the instruments' ${FLEET_REGIME_TB} floor) + bounded retry contract (maxRetries ${RETRY_MAX_RETRIES}, idle ${HTTP_IDLE_TIMEOUT_MS}ms, backoff cap ${RETRY_MAX_BACKOFF_MS}ms → hung ${window_hung}ms / worst ${window_worst}ms)"
  fi
}

# check_project_settings — pi merges a PROJECT settings file OVER the global one
# (`SettingsManager`: settings = deepMergeSettings(globalSettings, projectSettings),
# path `join(resolvedCwd, ".pi", "settings.json")` when the project is trusted),
# so a project file can revert the whole retry contract while the shipped and
# live files read clean. NOTE the path is resolved from the SESSION CWD, not
# from the repo root — a session started in a subdirectory (e.g. `$ROOT/extensions`)
# merges `$ROOT/extensions/.pi/settings.json`. So this walks the checkout for
# any `.pi/settings.json` (following symlinked `.pi` dirs, at ANY depth) and
# fails CLOSED on each one that touches the contract keys. `.worktrees/` is NOT
# pruned: a linked worktree is physically inside this checkout, is a real session
# cwd, and is gitignored — so an untracked project file there would otherwise be
# invisible to both git and this guard. Everything outside the checkout (other
# repos) is genuinely beyond its reach — a documented scope boundary, see
# docs/ops/cost-config-policy.md §2.
check_project_settings() {
  local listing path hit walk_rc walk_err
  walk_err="$(mktemp "${TMPDIR:-/tmp}/cost-config-walk.XXXXXX")"
  listing="$(python3 - "$ROOT" 2>"$walk_err" <<'PYEOF'
import json, os, sys

root = sys.argv[1]
# Noise directories only. NOTE `.worktrees` is deliberately NOT pruned: a linked
# worktree lives under $ROOT, is a real session cwd, and `.worktrees/` is
# gitignored — so a `.pi/settings.json` written there is invisible to git AND was
# invisible to this walk, while still reverting the contract for any session
# rooted in that worktree (#1088 review cycle 3).
PRUNE = {".git", "node_modules", ".venv", "venv", "__pycache__"}
# Explicit traversal instead of os.walk+MAXDEPTH: a session cwd can be ANY
# directory in the checkout (so `.pi` can sit at any depth), and a depth cap
# silently missed `.pi` deeper than the cap — a reproduced B4 bypass (#1088
# review cycle 6). Cycle safety comes from the visited-set of real paths, which
# also de-duplicates symlinked directories; there is no depth limit to outrun.
seen, stack, out = set(), [root], []
while stack:
    d = stack.pop()
    real = os.path.realpath(d)
    if real in seen:
        continue
    seen.add(real)
    try:
        entries = list(os.scandir(d))
    except OSError as ex:
        # NOT a silent `continue`: an unreadable directory is a hole in the
        # walk, and a hole that reports green is how a project settings file
        # reverting the contract would be missed (#1088 review). Surfaced to
        # the shell as a block, like every other unassertable input.
        out.append(f"{d}\tWALK_ERROR: {ex}")
        continue
    for e in entries:
        # PRUNE is a NAME-only decision, so it is taken before any stat: a
        # pruned entry can never be the source of a hole in the walk.
        if e.name in PRUNE:
            continue
        try:
            is_dir = e.is_dir(follow_symlinks=True)
        except OSError as ex:
            # NOT a silent `continue`: an entry we cannot stat is a hole in the
            # walk, exactly like the unreadable directory above — the same
            # fail-open shape fixed there (#1088 review). A SYMLINK is what
            # reaches this arm: d_type cannot answer `is_dir` for one, so it
            # must be resolved with a stat, and a symlink under a directory
            # without search
            # permission raises EACCES. Skipping it let a contract-reverting
            # `.pi/settings.json` behind that symlink read green —
            # `✅ no project settings file` at `chmod 400`, a block at `chmod
            # 700` (#1088 review cycle 7).
            out.append(f"{e.path}\tWALK_ERROR: {ex}")
            continue
        if not is_dir:
            continue
        if e.name != ".pi":
            stack.append(e.path)
            continue
        # a `.pi` directory: inspect its settings.json AND keep walking, because
        # a session cwd can itself be inside `.pi` (the global layout is
        # `~/.pi/agent`), and then a nested `.pi/settings.json` is a live project
        # file. Not descending was a reproduced B4 miss (#1088 coverage review);
        # the realpath visited-set keeps this cycle-safe.
        # NB: keep apostrophes out of this heredoc body — an unescaped quote here
        # has broken this file parse before (#1088).
        stack.append(e.path)
        p = os.path.join(e.path, "settings.json")
        if not os.path.lexists(p):
            continue
        if not os.path.isfile(p):
            out.append(f"{p}\tNOT_A_FILE")
            continue
        try:
            with open(p) as f:
                d = json.load(f)
        except Exception as ex:
            out.append(f"{p}\tPARSE_ERROR: {ex}")
            continue
        if not isinstance(d, dict):
            out.append(f"{p}\tNOT_AN_OBJECT")
            continue
        keys = [k for k in ("retry", "httpIdleTimeoutMs", "compaction") if k in d]
        out.append(f"{p}\t{', '.join(keys)}")
print("\n".join(out))
PYEOF
)"
  walk_rc=$?
  if [ "$walk_rc" -ne 0 ]; then
    # The walk is the ONLY thing that can assert the project-settings half of
    # the contract. A crash left `listing` empty, and the empty arm below then
    # printed "no project settings file" and exited 0 — a false PASS for a
    # checkout the guard never walked (#1088 review). Fail closed, and name the
    # walker's own error text.
    block_settings "the project-settings walk failed (rc=$walk_rc) — the retry/compaction contract cannot be asserted against project settings (fail-closed): $(tr '\n' ' ' <"$walk_err" | cut -c1-200)"
    rm -f "$walk_err"
    return 0
  fi
  rm -f "$walk_err"
  if [ -z "$listing" ]; then
    ok "no project settings file under $ROOT (pi merges <session-cwd>/.pi/settings.json over the global settings)"
    return 0
  fi
  while IFS=$'\t' read -r path hit; do
    [ -n "$path" ] || continue
    case "$hit" in
      "")
        ok "project settings ($path) does not touch the retry/compaction contract" ;;
      PARSE_ERROR:*|NOT_A_FILE|NOT_AN_OBJECT|WALK_ERROR:*)
        block_settings "project settings ($path) is $hit — cannot assert the retry/compaction contract against a file pi merges over the global settings" ;;
      *)
        block_settings "project settings ($path) overrides the settings contract ($hit) — pi merges project settings OVER the global ones, so this silently reverts the shipped contract; remove the key here" ;;
    esac
  done <<< "$listing"
}

# ── an ambient override must not be able to disagree with the contract ────
# The cap resolver UNSETS PI_MAX_RETRY_DELAY_MS (it wants the script's
# DEFAULT), but the patch honours the ambient value at APPLY time and setup.sh
# passes the operator's environment through. So an exported
# PI_MAX_RETRY_DELAY_MS=300000 let this guard report a 60000ms window and exit 0
# while an install made from the same environment carried 300000 — the guard
# would certify a bound it does not enforce (#1088 review). The knob is
# documented as "MUST equal RETRY_MAX_BACKOFF_MS", so a differing value is a
# contract violation wherever it is set: fail closed, override-immune.

echo "== cost-config guard (#341) — deepseek context clamp @${CLAMP} =="
[ "$OVERRIDE" = "1" ] && echo "   ⛔ COST_CLAMP_OVERRIDE=1 is SET — CLAMP blocks will be SILENCED. Retry/hang-contract (#1088) and settings/compaction blocks are NOT covered by this escape and still exit 1."
echo ""

if [ -n "${PI_MAX_RETRY_DELAY_MS:-}" ] && [ "${PI_MAX_RETRY_DELAY_MS}" != "$RETRY_MAX_BACKOFF_MS" ]; then
  block_retry "PI_MAX_RETRY_DELAY_MS=${PI_MAX_RETRY_DELAY_MS} is exported in this environment but the contract cap is ${RETRY_MAX_BACKOFF_MS} — the guard reads the DEFAULT cap, so an install patched from this environment would carry a different cap while this guard reported the pinned one (the knob must equal RETRY_MAX_BACKOFF_MS)"
fi

check_model_file "$SHIPPED_DIR/models.json" "shipped models.json" models block
check_model_file "$SHIPPED_DIR/models-store.json" "shipped models-store.json" store warn
check_settings_file "$SHIPPED_DIR/settings.json" "shipped settings.json" block
check_project_settings

if [ "$SHIPPED_ONLY" = 1 ]; then
  echo ""
  echo "(live pass skipped — --shipped-only)"
else
  echo ""
  if [ ! -d "$LIVE_DIR" ]; then
    warn "live dir not found: $LIVE_DIR — live pass skipped"
  else
    check_model_file "$LIVE_DIR/models.json" "live models.json ($LIVE_DIR)" models warn
    check_model_file "$LIVE_DIR/models-store.json" "live models-store.json ($LIVE_DIR)" store warn
    check_settings_file "$LIVE_DIR/settings.json" "live settings.json ($LIVE_DIR)" warn
  fi
fi

echo ""
if [ "$OVERRIDE" = "1" ]; then
  if [ "$RETRY_BLOCKS" -gt 0 ] || [ "$SETTINGS_BLOCKS" -gt 0 ]; then
    echo "❌ cost-config guard: $RETRY_BLOCKS retry/hang-contract BLOCK(s) + $SETTINGS_BLOCKS settings-contract"
    echo "   BLOCK(s) — COST_CLAMP_OVERRIDE=1 does NOT cover either class: the clamp rollback window does not"
    echo "   extend to the retry bound (#1088) or to a reverted/disabled compaction contract. Guard: exit 1."
    exit 1
  fi
  echo "⛔ COST_CLAMP_OVERRIDE=1 — clamp BLOCK silenced by documented escape. Violations above are still DETECTED;"
  echo "   this is sanctioned only for the clamp rollback window (revert commit + threshold update in the same commit)."
  echo "⛔ Guard: OVERRIDDEN → exit 0"
  exit 0
fi
if [ "$BLOCKS" -gt 0 ]; then
  # Class-aware: pointing a retry/settings violation at COST_CLAMP_OVERRIDE=1
  # sends the operator to a remedy that cannot work (it exits 1 for both), so
  # the escape is only offered for the clamp class it actually covers.
  if [ "$RETRY_BLOCKS" -gt 0 ] || [ "$SETTINGS_BLOCKS" -gt 0 ]; then
    echo "❌ cost-config guard: $BLOCKS BLOCK-level violation(s) — $RETRY_BLOCKS retry/hang-contract +"
    echo "   $SETTINGS_BLOCKS settings-contract. COST_CLAMP_OVERRIDE=1 does NOT cover either class — fix the"
    echo "   config (only the models.json clamp class has the documented escape)."
  else
    echo "❌ cost-config guard: $BLOCKS BLOCK-level violation(s) — fix the config, or use COST_CLAMP_OVERRIDE=1 (documented escape)."
  fi
  exit 1
fi
if [ "$WARNS" -gt 0 ]; then
  echo "⚠️  cost-config guard: PASS with $WARNS warning(s) (catalog-class drift is DETECTED, not blocked — weekly report + tripwire alert)."
else
  echo "✅ cost-config guard: PASS — all deepseek-served ids ≤ ${CLAMP}; settings contract intact."
fi
exit 0
