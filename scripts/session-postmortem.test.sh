#!/usr/bin/env bash
# session-postmortem.test.sh — self-check for the SHARED parser in
# scripts/session-postmortem.sh (--summary mode, #341 PR-B / #373).
#
# Run: bash scripts/session-postmortem.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds
# synthetic session JSONLs in a temp dir — never touches real sessions.
#
# Coverage:
#   message usage    msg_calls + input/output/cacheRead/cacheWrite/reasoning
#                    summed from message.usage (nested shape)
#   compaction usage compaction records parsed SEPARATELY (comp_* fields) with
#                    usage at top level + reasoning + cost
#   ceiling class    compaction tokensBefore ≥ 900000 → ceiling_compactions 1
#   distinct call    compaction does NOT increment msg_calls (not double-count)
#   length marker    stopReason:length at the session ceiling → genuine_len_stops
#   benign length    length stop far below the ceiling → NOT counted (0.92 floor)
#   jsonl contract   one JSON object per input session, error-tagged on unreadable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPM="$SCRIPT_DIR/session-postmortem.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

T="$(mktemp -d /tmp/spm-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ── fixtures ──────────────────────────────────────────────────────────────
mkdir -p "$T/sessions"

# s1: compacting session at the 400K regime with a ceiling-truncation length
# stop + a benign (mid-context) length stop that must NOT count.
python3 - "$T/sessions/2026-08-28T10-00-00-000Z_s1.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "session", "id": "s1", "timestamp": "2026-08-28T10:00:00Z", "cwd": "/x"},
    # compaction record: distinct summarizer LLM call, cacheRead≈0, reasoning
    {"type": "compaction", "timestamp": "2026-08-28T10:05:00Z", "tokensBefore": 390000,
     "usage": {"input": 780000, "output": 2000, "cacheRead": 3, "cacheWrite": 10000,
               "reasoning": 5000, "totalTokens": 797003,
               "cost": {"input": 0.1092, "output": 0.00056, "cacheRead": 0.00000001,
                        "cacheWrite": 0.000028, "total": 0.1098}}},
    # normal message usage (nested at message.usage): cache-heavy assistant call
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
        "content": [{"type": "toolCall", "name": "bash", "arguments": "x"}]},
     "usage": {"input": 3000, "output": 2000, "cacheRead": 300000, "cacheWrite": 0,
               "reasoning": 1500, "totalTokens": 306500,
               "cost": {"input": 0.00042, "output": 0.00056, "cacheRead": 0.00084,
                        "cacheWrite": 0, "total": 0.00182}}},
    # ceiling-truncation: context at the session ceiling, stopReason length
    {"type": "message", "message": {"role": "assistant", "stopReason": "length",
        "content": []},
     "usage": {"input": 1000, "output": 1, "cacheRead": 390000, "cacheWrite": 0,
               "reasoning": 0, "totalTokens": 391001,
               "cost": {"input": 0.00014, "output": 0.00000028, "cacheRead": 0.001092,
                        "cacheWrite": 0, "total": 0.00123}}},
    # benign length stop FAR below the ceiling (mid-context output cap) — the
    # 0.92 × session-max-ctx floor must exclude it from genuine_len_stops
    {"type": "message", "message": {"role": "assistant", "stopReason": "length",
        "content": []},
     "usage": {"input": 2000, "output": 500, "cacheRead": 50000, "cacheWrite": 0,
               "reasoning": 100, "totalTokens": 52600,
               "cost": {"input": 0.00028, "output": 0.00014, "cacheRead": 0.00014,
                        "cacheWrite": 0, "total": 0.00056}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY

# s2: 1M-drift session — compaction at ceiling (tokensBefore 996000 ≥ 900000)
python3 - "$T/sessions/2026-08-18T09-00-00-000Z_s2.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "compaction", "timestamp": "2026-08-18T09:05:00Z", "tokensBefore": 996000,
     "usage": {"input": 900000, "output": 3000, "cacheRead": 0, "cacheWrite": 20000,
               "reasoning": 8000, "totalTokens": 929000,
               "cost": {"input": 0.126, "output": 0.00084, "cacheRead": 0,
                        "cacheWrite": 0.000056, "total": 0.1269}}},
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
        "content": []},
     "usage": {"input": 500, "output": 300, "cacheRead": 5000, "cacheWrite": 0,
               "reasoning": 200, "totalTokens": 6000,
               "cost": {"input": 0.00007, "output": 0.000084, "cacheRead": 0.000014,
                        "cacheWrite": 0, "total": 0.000168}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY

# s2b: boundary — compaction at EXACTLY 900000 must count as ceiling
python3 - "$T/sessions/2026-08-18T10-00-00-000Z_s2b.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "compaction", "timestamp": "2026-08-18T10:05:00Z", "tokensBefore": 900000,
     "usage": {"input": 900000, "output": 3000, "cacheRead": 0, "cacheWrite": 20000,
               "reasoning": 8000, "cost": {"input": 0.126, "output": 0.00084,
                        "cacheRead": 0, "cacheWrite": 0.000056, "total": 0.1269}}},
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse", "content": []},
     "usage": {"input": 500, "output": 300, "cacheRead": 5000, "cacheWrite": 0,
               "reasoning": 200, "cost": {"input": 0.00007, "output": 0.000084,
                        "cacheRead": 0.000014, "cacheWrite": 0, "total": 0.000168}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY

# s2c: boundary below — 899999 must NOT count as ceiling
python3 - "$T/sessions/2026-08-18T11-00-00-000Z_s2c.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "compaction", "timestamp": "2026-08-18T11:05:00Z", "tokensBefore": 899999,
     "usage": {"input": 850000, "output": 3000, "cacheRead": 0, "cacheWrite": 20000,
               "reasoning": 8000, "cost": {"input": 0.126, "output": 0.00084,
                        "cacheRead": 0, "cacheWrite": 0.000056, "total": 0.1269}}},
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse", "content": []},
     "usage": {"input": 500, "output": 300, "cacheRead": 5000, "cacheWrite": 0,
               "reasoning": 200, "cost": {"input": 0.00007, "output": 0.000084,
                        "cacheRead": 0.000014, "cacheWrite": 0, "total": 0.000168}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY

# s3: unreadable file (permission-denied) — parser must error-tag, not crash
touch "$T/sessions/2026-08-28T11-00-00-000Z_s3.jsonl"
chmod 000 "$T/sessions/2026-08-28T11-00-00-000Z_s3.jsonl"

# s4: corrupt-but-READABLE (all-bad lines) — parser must error-tag, not return
# a healthy zero session (the data-absence bypass reviewer found in round 2)
printf 'this is not json\n{also not json\n12345\n' > "$T/sessions/2026-08-18T12-00-00-000Z_s4.jsonl"

# s5: empty file — same data-absence contract
: > "$T/sessions/2026-08-18T13-00-00-000Z_s5.jsonl"

echo "── session-postmortem shared parser ───────────────────────────────"
SUMMARY="$(bash "$SPM" --summary "$T"/sessions/*.jsonl)"
assert_eq "$(printf '%s\n' "$SUMMARY" | wc -l | tr -d ' ')" "7" "one JSON line per input file (incl. error-tagged)"

# select each fixture by its id so glob/sort order never matters
pick() { printf '%s\n' "$SUMMARY" | python3 -c "import json,sys
for line in sys.stdin:
    m = json.loads(line)
    if '_$1.jsonl' in m.get('session',''):
        print(json.dumps(m)); break"; }
S1="$(pick s1)"
python3 - "$S1" <<'PY'
import json, sys
m = json.loads(sys.argv[1])
checks = [
    (m["msg_calls"], 3, "msg_calls counts 3 assistant message records"),
    (m["msg_input"], 3000+1000+2000, "msg_input sums message-usage input"),
    (m["msg_reasoning"], 1500+0+100, "msg_reasoning sums reasoning"),
    (m["compacting"], True, "compacting true when a compaction record exists"),
    (m["comp_count"], 1, "comp_count counts the compaction record"),
    (m["comp_input"], 780000, "comp_input = summarizer input (distinct call)"),
    (m["msg_cost_cache"] > 0, True, "msg cost cache dict summed"),
    (m["comp_cost_total"], 0.1098, "compaction cost.total parsed"),
    (m["ceiling_compactions"], 0, "390K tokensBefore is NOT a ceiling compaction"),
    (m["max_ctx"], 391000, "max_ctx covers the ceiling length-stop ctx"),
    (m["genuine_len_stops"], 1, "only the ceiling length stop counts (benign mid-context excluded)"),
]
for got, want, label in checks:
    if got == want:
        print("PASS", label)
    else:
        print("FAIL", label, "got", got, "want", want)
        raise SystemExit(1)
PY
[ $? -eq 0 ] && ok "s1 parsed: compaction + reasoning + ceiling length marker" || bad "s1 parse mismatch"

S2="$(pick s2)"
python3 - "$S2" <<'PY'
import json, sys
m = json.loads(sys.argv[1])
checks = [
    (m["ceiling_compactions"], 1, "996K tokensBefore IS a ceiling compaction"),
    (m["msg_calls"], 1, "compaction NOT double-counted as a message call"),
]
for got, want, label in checks:
    if got == want:
        print("PASS", label)
    else:
        print("FAIL", label, "got", got, "want", want)
        raise SystemExit(1)
PY
[ $? -eq 0 ] && ok "s2 parsed: 1M-drift ceiling classification" || bad "s2 parse mismatch"

# boundary: 900000 (exactly) counts; 899999 does not — locks the ≥ constant
S2B="$(pick s2b)"
S2C="$(pick s2c)"
python3 - "$S2B" <<'PY'
import json, sys
m = json.loads(sys.argv[1])
if m["ceiling_compactions"] != 1:
    print("FAIL tokensBefore==900000 must be a ceiling compaction"); raise SystemExit(1)
print("PASS boundary 900000 counts as ceiling")
PY
[ $? -eq 0 ] && ok "s2b boundary: 900000 counts" || bad "s2b boundary mismatch"
python3 - "$S2C" <<'PY'
import json, sys
m = json.loads(sys.argv[1])
if m["ceiling_compactions"] != 0:
    print("FAIL tokensBefore==899999 must NOT be a ceiling compaction"); raise SystemExit(1)
print("PASS boundary 899999 is not ceiling")
PY
[ $? -eq 0 ] && ok "s2c boundary: 899999 not ceiling" || bad "s2c boundary mismatch"

S3="$(pick s3)"
assert_contains "$S3" '"error"' "unreadable session error-tagged (batch survives)"
S4="$(pick s4)"
assert_contains "$S4" '"error"' "corrupt-but-readable session error-tagged (no healthy zero row)"
S5="$(pick s5)"
assert_contains "$S5" '"error"' "empty session error-tagged (data-absence contract)"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
