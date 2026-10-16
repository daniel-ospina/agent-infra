#!/bin/bash
# ============================================================
# test-models-merge.sh — regression test for agent-infra#682
#
# THE DEFECT. `pi-bootstrap/setup.sh` merged the shipped pi-config/models.json into
# the live ~/.pi/agent/models.json with ONE per-provider dict replacement:
#
#     merged["providers"] = {**dst["providers"], **src["providers"]}
#
# Shipped won per PROVIDER KEY, so the whole provider object was replaced — including
# its `models[]` array. Every model id that existed only live was deleted, silently,
# under a success message ("local providers preserved") that was true only at
# provider-key granularity. Measured 2026-09-09: live carried
# `deepseek-v4.1-flash-expires-on-0910` with 1,733 recorded calls; one sync removed it.
# `.bak-bootstrap` is written only on the FIRST bootstrap, so the loss was
# unrecoverable. `modelOverrides` keys inside a shipped provider were dropped by
# exactly the same mechanism.
#
# WHAT THIS SUITE PINS (the load-bearing set, not an inventory):
#   (a) a live-only model id SURVIVES the merge, with its live definition, and the
#       shipped ids are all present — the #682 acceptance criterion;
#   (b) the documented precedence rule actually holds: an id present in BOTH takes the
#       SHIPPED definition wholesale (a different cost is the observable), and the
#       shipped-only id is added;
#   (c) the merge is per MODEL, not per provider: live-only modelOverrides keys, a live
#       model on a provider the shipped file ships `modelOverrides`-only (openrouter's
#       shape), a live-only provider, and unrelated top-level keys all survive;
#   (d) the merge reports what it did — `preserved N live-only model(s): …` names the
#       entries, and a second run is idempotent (added 0);
#   (e) it holds against the REAL shipped pi-config/models.json, not only a fixture;
#   (f) RED CONTROL — a mutated copy of the merge module that drops the live-only
#       models must exit NON-ZERO, NAME the dropped entries, and leave the live file
#       BYTE-IDENTICAL (the invariant, not just the bookkeeping);
#   (g) setup.sh's no-python3 path REFUSES to overwrite an existing live models.json
#       instead of plain-copying the shipped file over it (the same silent drop in a
#       second path), while a genuinely fresh install still copies;
#   (h) the END-TO-END wiring: the real setup.sh, against a live file carrying live-only
#       state, leaves that state intact and reports it — (a)-(g) alone would not notice a
#       setup.sh that kept the refusal but merged per-provider again.
#
# Hermetic: temp fixtures only, no network, no live ~/.pi. Nothing outside $TMP is
# written (the repo is read-only here).
#
# Usage:  bash pi-bootstrap/tests/test-models-merge.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MERGE="$ROOT/pi-bootstrap/lib/merge-models.py"
SETUP="$ROOT/pi-bootstrap/setup.sh"
SHIPPED="$ROOT/pi-bootstrap/pi-config/models.json"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/models-merge-test.XXXXXX")"
FAILURES=0
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "ok: $*"; }

[ -f "$MERGE" ] || { echo "FATAL: $MERGE missing — nothing to test" >&2; exit 1; }
[ -f "$SHIPPED" ] || { echo "FATAL: $SHIPPED missing — nothing to test" >&2; exit 1; }

# ── synthetic fixtures ──────────────────────────────────────────────────────
# Deliberately exercise each shape the shipped file uses: a provider with models[]
# (deepseek), a provider shipped with `modelOverrides` ONLY (openrouter), and a
# provider that ships only modelOverrides but carries a live models[] array.
cat > "$TMP/src.json" <<'JSON'
{
  "providers": {
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "apiKey": "$DEEPSEEK_API_KEY",
      "models": [
        {"id": "deepseek-v4-pro", "name": "Shipped Pro", "cost": {"input": 0.66, "output": 1.98}},
        {"id": "deepseek-flash", "name": "Shipped Flash", "cost": {"input": 0.15, "output": 0.6}}
      ]
    },
    "openrouter": {
      "modelOverrides": {"deepseek/deepseek-v4-pro": {"contextWindow": 300000}}
    }
  }
}
JSON

cat > "$TMP/live.json" <<'JSON'
{
  "providers": {
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "apiKey": "$DEEPSEEK_API_KEY",
      "models": [
        {"id": "deepseek-v4-pro", "name": "LIVE Pro (must lose to shipped)", "cost": {"input": 9.99, "output": 9.99}},
        {"id": "deepseek-v4.1-flash-expires-on-0910", "name": "Live only (1733 calls)", "cost": {"input": 0.15, "output": 0.6}},
        {"id": "live-local-tuned", "name": "Live local tuning", "cost": {"input": 1.0}}
      ],
      "modelOverrides": {"live-only-override": {"contextWindow": 1234}}
    },
    "openrouter": {
      "models": [{"id": "live/openrouter-model", "name": "Live OR model"}],
      "modelOverrides": {"live/only": {"contextWindow": 555}}
    },
    "my-local-provider": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "models": [{"id": "llama-local", "name": "Local Llama"}]
    }
  },
  "liveTopLevelKey": {"keep": true}
}
JSON

echo "== (a)-(d) synthetic merge: live-only id survives, shipped wins per id, per-key overrides"
cp "$TMP/live.json" "$TMP/merged1.json"
if ! python3 "$MERGE" "$TMP/src.json" "$TMP/merged1.json" > "$TMP/run1.log" 2>&1; then
  fail "merge exited non-zero on a clean fixture:"
  sed 's/^/    /' "$TMP/run1.log" >&2
else
  ok "merge exited 0 on a clean fixture"
fi

python3 - "$TMP/merged1.json" <<'PY' || FAILURES=$((FAILURES + 1))
import json, sys

doc = json.load(open(sys.argv[1]))
provs = doc.get("providers", {})
bad = []


def check(cond, msg):
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        bad.append(msg)


ds = provs.get("deepseek", {})
models = ds.get("models", [])
ids = [m.get("id") for m in models]
by_id = {m.get("id"): m for m in models}

# (a) the #682 acceptance criterion: the live-only id survives with its live definition
check("deepseek-v4.1-flash-expires-on-0910" in by_id,
      "live-only id deepseek-v4.1-flash-expires-on-0910 survives the merge (#682)")
check(by_id.get("deepseek-v4.1-flash-expires-on-0910", {}).get("name") == "Live only (1733 calls)",
      "the surviving live-only model keeps its LIVE definition (not a stub)")
check("live-local-tuned" in by_id, "a second live-only id survives")

# (b) documented precedence: id in both -> SHIPPED wins WHOLESALE (cost observable)
check(by_id.get("deepseek-v4-pro", {}).get("name") == "Shipped Pro",
      "an id present in both takes the shipped definition (name)")
check(by_id.get("deepseek-v4-pro", {}).get("cost", {}).get("input") == 0.66,
      "an id present in both takes the shipped COST (9.99 live -> 0.66 shipped), not a field-level mix")
check("deepseek-flash" in by_id, "the shipped-only id is added")

# shipped order is authoritative; live-only entries are appended in live order
check(ids == ["deepseek-v4-pro", "deepseek-flash",
              "deepseek-v4.1-flash-expires-on-0910", "live-local-tuned"],
      "shipped model order is kept and live-only models are appended (got %r)" % (ids,))

# (c) per-KEY granularity everywhere the old code was per-provider
check(ds.get("modelOverrides", {}).get("live-only-override") == {"contextWindow": 1234},
      "a live-only modelOverrides key inside a SHIPPED provider survives")

orv = provs.get("openrouter", {})
check(orv.get("modelOverrides", {}).get("deepseek/deepseek-v4-pro") == {"contextWindow": 300000},
      "a shipped modelOverrides key on a modelOverrides-only provider survives")
check(orv.get("modelOverrides", {}).get("live/only") == {"contextWindow": 555},
      "a live-only modelOverrides key on a modelOverrides-only provider survives")
check([m.get("id") for m in orv.get("models", [])] == ["live/openrouter-model"],
      "a live models[] array on a provider the shipped file ships modelOverrides-only survives")

local = provs.get("my-local-provider", {})
check([m.get("id") for m in local.get("models", [])] == ["llama-local"],
      "a live-only provider and its models survive")
check(doc.get("liveTopLevelKey") == {"keep": True}, "unrelated live top-level keys survive")

sys.exit(1 if bad else 0)
PY

# (d) the merge reports what it preserved, and names it
grep -q "preserved 4 live-only model(s)" "$TMP/run1.log" \
  && ok "run reports the preserved live-only model count" \
  || { fail "run did not report 'preserved 4 live-only model(s)'"; cat "$TMP/run1.log" >&2; }
grep -q "deepseek:deepseek-v4.1-flash-expires-on-0910" "$TMP/run1.log" \
  && ok "run names the preserved live-only id" \
  || fail "run did not name the preserved live-only id (target: print what it preserved)"
grep -q "replaced 1 model(s) with shipped definitions, added 1 shipped-only model(s)" "$TMP/run1.log" \
  && ok "run reports replaced/added counts" \
  || { fail "run did not report the expected replaced/added counts"; cat "$TMP/run1.log" >&2; }
grep -q "preserved 2 live-only modelOverrides key(s)" "$TMP/run1.log" \
  && ok "run reports the preserved live-only modelOverrides keys" \
  || fail "run did not report preserved live-only modelOverrides keys"

# idempotence: a second run over its own output adds nothing and preserves the same set
cp "$TMP/merged1.json" "$TMP/merged1b.json"
python3 "$MERGE" "$TMP/src.json" "$TMP/merged1b.json" > "$TMP/run1b.log" 2>&1 \
  || fail "second merge run exited non-zero"
grep -q "replaced 2 model(s) with shipped definitions, added 0 shipped-only model(s)" "$TMP/run1b.log" \
  && ok "a second run is idempotent (nothing left to add)" \
  || fail "second run was not idempotent"
if cmp -s "$TMP/merged1.json" "$TMP/merged1b.json"; then
  ok "a second run is byte-stable"
else
  fail "a second run changed the file (not idempotent)"
fi

echo "== (e) the merge holds against the REAL shipped pi-config/models.json"
python3 - "$SHIPPED" "$TMP/live-real.json" <<'PY'
import json, sys
shipped = json.load(open(sys.argv[1]))
live = json.loads(json.dumps(shipped))          # start from shipped, then add live-only state
live.setdefault("providers", {})["deepseek"]["models"].append(
    {"id": "live-only-against-the-real-file", "name": "live only", "cost": {"input": 0.42}})
live["providers"]["a-provider-no-repo-ships"] = {"models": [{"id": "local-only"}]}
json.dump(live, open(sys.argv[2], "w"), indent=2)
PY
cp "$TMP/live-real.json" "$TMP/merged-real.json"
python3 "$MERGE" "$SHIPPED" "$TMP/merged-real.json" > "$TMP/run-real.log" 2>&1 \
  || { fail "merge against the real shipped file exited non-zero"; cat "$TMP/run-real.log" >&2; }
python3 - "$SHIPPED" "$TMP/merged-real.json" <<'PY' || FAILURES=$((FAILURES + 1))
import json, sys

shipped = json.load(open(sys.argv[1]))["providers"]
merged = json.load(open(sys.argv[2]))["providers"]
bad = []
for name, sp in shipped.items():
    for m in sp.get("models", []):
        if m.get("id") not in {x.get("id") for x in merged.get(name, {}).get("models", [])}:
            bad.append("shipped %s:%s missing from the merge" % (name, m["id"]))
    for k in sp.get("modelOverrides", {}):
        if k not in merged.get(name, {}).get("modelOverrides", {}):
            bad.append("shipped override %s:%s missing from the merge" % (name, k))
ds_ids = {m.get("id") for m in merged.get("deepseek", {}).get("models", [])}
if "live-only-against-the-real-file" not in ds_ids:
    bad.append("live-only id was dropped by the merge against the real shipped file")
if "a-provider-no-repo-ships" not in merged:
    bad.append("live-only provider was dropped by the merge against the real shipped file")
print(("ok: " if not bad else "FAIL: ") + "real shipped file: every shipped entry kept and every live-only entry preserved")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY

echo "== (f) RED CONTROL: a merge that drops live-only models must be refused, not written"
sed 's/prov\["models"\] = list(shipped_models) + live_only/prov["models"] = list(shipped_models)/' \
  "$MERGE" > "$TMP/mutated.py"
if cmp -s "$MERGE" "$TMP/mutated.py"; then
  fail "RED CONTROL is vacuous: the mutation did not apply (the append line moved?)"
else
  ok "RED CONTROL mutation applied (live-only models are dropped by the mutated copy)"
fi
cp "$TMP/live.json" "$TMP/mutated-out.json"
python3 "$TMP/mutated.py" "$TMP/src.json" "$TMP/mutated-out.json" > "$TMP/mutated.log" 2>&1
mut_rc=$?
if [ "$mut_rc" -ne 0 ]; then
  ok "the mutated merge exits $mut_rc (refused) instead of dropping entries"
else
  fail "the mutated merge exited 0 — the drop invariant is inert"
fi
if grep -q "deepseek-v4.1-flash-expires-on-0910" "$TMP/mutated.log"; then
  ok "the refusal NAMES the entry that would have been dropped"
else
  fail "the refusal did not name the dropped entry"
  cat "$TMP/mutated.log" >&2
fi
if cmp -s "$TMP/live.json" "$TMP/mutated-out.json"; then
  ok "the refusal left the live file BYTE-IDENTICAL (nothing written)"
else
  fail "the refusal still wrote the file — a refused merge must not touch live state"
fi

echo "== (g) setup.sh refuses to plain-copy over an existing live models.json without python3"
# Build a PATH whose directories collectively carry every executable EXCEPT python*,
# so `command -v python3` fails while the rest of setup.sh resolves normally. Swept
# from the REAL PATH — an allowlist would silently stop testing if setup.sh grows a
# tool, and setup.sh's no-python3 branch is only reachable through this shim.
SHIM="$TMP/nopython-bin"
mkdir -p "$SHIM"
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] && [ -x "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in python*) continue ;; esac
    [ -e "$SHIM/$b" ] && continue
    ln -s "$f" "$SHIM/$b" 2>/dev/null || true
  done
done <<< "$(printf '%s\n' "$PATH" | tr ':' '\n')"
if PATH="$SHIM" command -v python3 >/dev/null 2>&1; then
  fail "the shim still exposes python3 — (g) cannot be tested (PATH sweep is incomplete)"
else
  ok "shim hides python3 (command -v python3 finds nothing)"
fi

HOME3="$TMP/home3"
mkdir -p "$HOME3/.pi/agent"
cp "$TMP/live.json" "$HOME3/.pi/agent/models.json"
cp "$HOME3/.pi/agent/models.json" "$TMP/live-before.json"
PATH="$SHIM" HOME="$HOME3" bash "$SETUP" > "$TMP/setup-nopython.log" 2>&1
setup_rc=$?
if [ "$setup_rc" -ne 0 ]; then
  ok "setup.sh exits $setup_rc without python3 rather than plain-copying the shipped file"
else
  fail "setup.sh exited 0 without python3 — it plain-copied over the live models.json"
fi
if grep -q "cannot merge models.json without dropping live-only entries (#682)" "$TMP/setup-nopython.log"; then
  ok "the refusal message names the #682 drop risk"
else
  fail "the no-python3 refusal did not name the #682 drop risk"
  tail -5 "$TMP/setup-nopython.log" >&2
fi
if cmp -s "$TMP/live-before.json" "$HOME3/.pi/agent/models.json"; then
  ok "the live models.json is untouched by the refused run"
else
  fail "the refused run still overwrote the live models.json"
fi

# Non-vacuity for (g): the refusal must be the ABSENCE OF PYTHON3, not a broken shim.
# A genuinely fresh install (no live models.json) must still succeed and copy.
HOME4="$TMP/home4"
mkdir -p "$HOME4/.pi/agent"
PATH="$SHIM" HOME="$HOME4" bash "$SETUP" > "$TMP/setup-nopython-fresh.log" 2>&1
fresh_rc=$?
if [ "$fresh_rc" -eq 0 ] && [ -f "$HOME4/.pi/agent/models.json" ]; then
  ok "without python3, a FRESH install still copies models.json (the refusal is conditional)"
else
  fail "without python3 a fresh install failed (rc=$fresh_rc) — (g) would be vacuous"
  tail -5 "$TMP/setup-nopython-fresh.log" >&2
fi

# ── (h) END-TO-END: the REAL setup.sh must run the fix, not just the module ──────
# (a)-(f) pin the merge module and (g) pins setup.sh's no-python3 branch; neither
# pins the WIRING — a setup.sh that kept its refusal but merged per-provider again
# would pass both. This leg runs the real setup.sh against a live file carrying a
# live-only model, provider and override key, and reads the result back.
echo "== (h) end-to-end: the real setup.sh preserves live-only state"
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
printf '#!/bin/bash\nexit 0\n' > "$STUB/npm"
printf '#!/bin/bash\necho "UNEXPECTED launchctl call: $*" >> "${LAUNCHCTL_LOG:-/dev/null}"\nexit 99\n' > "$STUB/launchctl"
chmod +x "$STUB/npm" "$STUB/launchctl"
HOME5="$TMP/home5"
mkdir -p "$HOME5/.pi/agent"
cp "$TMP/live.json" "$HOME5/.pi/agent/models.json"
PATH="$STUB:$PATH" HOME="$HOME5" LAUNCHCTL_LOG="$TMP/launchctl.log" bash "$SETUP" > "$TMP/setup-e2e.log" 2>&1
e2e_rc=$?
if [ "$e2e_rc" -eq 0 ]; then
  ok "the real setup.sh completed (rc=0) with a live-only models.json present"
else
  fail "the real setup.sh exited $e2e_rc with a live-only models.json present"
  tail -20 "$TMP/setup-e2e.log" >&2
fi
grep -q "preserved 4 live-only model(s)" "$TMP/setup-e2e.log" \
  && ok "setup.sh's own output reports the preserved live-only models (the module IS wired)" \
  || fail "setup.sh did not report the preserved live-only models — the merge module is not wired"
python3 - "$HOME5/.pi/agent/models.json" <<'PY' || FAILURES=$((FAILURES + 1))
import json, sys

provs = json.load(open(sys.argv[1])).get("providers", {})
bad = []
ds = provs.get("deepseek", {})
ds_ids = {m.get("id") for m in ds.get("models", [])}
for want in ("deepseek-v4.1-flash-expires-on-0910", "live-local-tuned",
             "deepseek-v4-pro", "deepseek-flash"):
    if want not in ds_ids:
        bad.append("deepseek:%s missing after a REAL setup.sh run" % want)
if "my-local-provider" not in provs:
    bad.append("live-only provider dropped by a REAL setup.sh run")
if ds.get("modelOverrides", {}).get("live-only-override") is None:
    bad.append("live-only modelOverrides key dropped by a REAL setup.sh run")
print(("ok: " if not bad else "FAIL: ") +
      "the real setup.sh preserved live-only models, providers and override keys (#682 end-to-end)")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: models.json merge preserves live-only entries (#682)"
  exit 0
fi
echo "FAIL: $FAILURES assertion(s) failed" >&2
exit 1
