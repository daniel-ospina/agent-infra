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
#   producer path    #1921: the Transcript Patterns producer resolves as a SIBLING of this
#                    script (a copy run from a cell-shaped temp root with no /Users), the
#                    consumer carries no /Users/ path in code, and an ABSENT or FAILING
#                    producer fails the section (banner in the report, reason on stderr) and
#                    the RUN (non-zero) instead of leaving a placeholder that reads as produced
#   parser contract  the vendored producer's own output: friction taxonomy counts, batch
#                    classification, skills, improvements, and survival of a transcript with
#                    no #NNN (the vendored-as-received source died there, rc=1, truncated)

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
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
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

# ══════════════════════════════════════════════════════════════════════════
# #1921 — the Transcript Patterns producer is a FARMED SIBLING, not a Mac
# absolute path. Every assertion below FAILS on the pre-fix code:
#   • A/B fail because the consumer's default producer was
#     /Users/<owner>/…/eldato/scripts/postmortem.sh — on this Linux-style root that
#     path does not exist, so the report carried the italic placeholder
#     "_postmortem.sh not found … transcript-only report_" instead of a section;
#   • C/D fail because an absent producer was a one-line placeholder inside the
#     report and the run still exited 0;
#   • E/F fail because the producer as received ABORTS under `set -euo pipefail` when
#     the transcript references no `#123` (grep finds nothing → pipefail → exit 1),
#     leaving a truncated section and rc=1.
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Transcript Patterns producer: sibling-resolved, fails loud (#1921) ──"

PATTERN_LIB="$SCRIPT_DIR/lib/transcript-patterns.sh"

# A CELL-shaped root: the tree is a copy under a temp dir, so /Users does not exist here and
# the ONLY way the consumer can find the producer is by deriving it from its own location.
# Running the repo copy instead would prove nothing about the cells (the repro line is a Mac
# path that happens to exist on the author's box).
CELL="$T/cell"
mkdir -p "$CELL/scripts/lib" "$CELL/sessions" "$CELL/out" "$T/home"
cp "$SPM" "$CELL/scripts/"
cp "$PATTERN_LIB" "$CELL/scripts/lib/"
python3 - "$CELL/sessions/2026-10-01T10-00-00-000Z_cell.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "message", "message": {"role": "user", "content": [{"type": "text", "text": "the gate blocked my work"}]},
     "usage": {"input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0,
               "cost": {"total": 0.001}}},
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
        "content": [{"type": "text", "text": "malformed json: unterminated; a workaround was needed. See #1921"}]},
     "usage": {"input": 100, "output": 50, "cacheRead": 200, "cacheWrite": 0, "reasoning": 0,
               "cost": {"total": 0.002}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY
CELL_SESSION="$CELL/sessions/2026-10-01T10-00-00-000Z_cell.jsonl"
case "$CELL" in
  */Users/*) bad "fixture root contains /Users — it cannot prove anything about a cell" ;;
  *) ok "fixture root is cell-shaped (no /Users in: $CELL)" ;;
esac

cell_rc=0
cell_err=""
cell_out="$(env -u POSTMORTEM_SH HOME="$T/home" PI_SESSIONS_DIR="$CELL/sessions" \
    bash "$CELL/scripts/session-postmortem.sh" "$CELL_SESSION" --out "$CELL/out" 2>"$T/cell.err")" || cell_rc=$?
cell_err="$(cat "$T/cell.err")"
CELL_REPORT="$(cat "$CELL/out"/*.md 2>/dev/null || true)"
assert_eq "$cell_rc" "0" "consumer exits 0 on a cell-style root (rc=0 with a missing section is the OLD bug)"
assert_contains "$CELL_REPORT" "=== Session Postmortem ===" "producer RAN from its sibling path — the report has real patterns, not the placeholder"
assert_contains "$CELL_REPORT" "gate/block/fail: 1 occurrence(s)" "the produced section carries the transcript's actual friction counts"
if grep -qF "DID NOT RUN" <<<"$CELL_REPORT"; then
  bad "sibling-resolved producer still reported the section as not run"
else
  ok "no failure banner when the producer resolves as a sibling"
fi

# The literal that caused the defect, in CODE (a comment may cite the old path — the default is
# what execs). Paired with the resolution assertion above: together they prove the producer is
# derived from the script's own location, never a host-specific home path.
# Capture first, then test: `grep -v … | grep -qF …` is the #841/#864 false-negative idiom — a
# quiet grep exits at its first match, and the writer's SIGPIPE fails the pipeline under
# `pipefail`, so a match can read as no-match.
spm_code="$(grep -vE '^[[:space:]]*#' "$SPM" || true)"
if grep -qF '/Users/' <<<"$spm_code"; then
  bad "session-postmortem.sh still carries a /Users/ literal in code: $(grep -nF '/Users/' <<<"$spm_code" | tr '\n' ' ')"
else
  ok "session-postmortem.sh has no /Users/ path in code (farmed: a Mac literal is a defect everywhere)"
fi
if grep -qE '(/Users/|/home/[^/$]+/)' "$PATTERN_LIB"; then
  bad "the vendored producer carries an absolute home path: $(grep -nE '(/Users/|/home/[^/$]+/)' "$PATTERN_LIB" | tr '\n' ' ')"
else
  ok "the vendored producer carries no absolute home path"
fi

# Absent producer → the SECTION fails loudly, the RUN exits non-zero. Never a placeholder.
BARE="$T/bare"
mkdir -p "$BARE/scripts" "$BARE/out"
cp "$SPM" "$BARE/scripts/"
bare_rc=0
env -u POSTMORTEM_SH HOME="$T/home" PI_SESSIONS_DIR="$CELL/sessions" \
  bash "$BARE/scripts/session-postmortem.sh" "$CELL_SESSION" --out "$BARE/out" \
  >"$T/bare.out" 2>"$T/bare.err" || bare_rc=$?
BARE_REPORT="$(cat "$BARE/out"/*.md 2>/dev/null || true)"
if [ "$bare_rc" -ne 0 ]; then
  ok "absent producer makes the RUN exit non-zero (rc=$bare_rc), not a silent placeholder"
else
  bad "absent producer still exited 0 — an incomplete report read as a success"
fi
assert_contains "$BARE_REPORT" "TRANSCRIPT PATTERNS SECTION DID NOT RUN" "absent producer is a banner INSIDE the report, not an italic aside"
assert_contains "$(cat "$T/bare.err")" "producer not found" "absent producer is named on stderr with its resolved path"
assert_contains "$(cat "$T/bare.err")" "$BARE/scripts/lib/transcript-patterns.sh" "the stderr reason names the SIBLING path it derived (not a Mac literal)"

# A producer that RUNS but fails must not be reported as content.
BROKEN="$T/broken"
mkdir -p "$BROKEN/scripts/lib" "$BROKEN/out"
cp "$SPM" "$BROKEN/scripts/"
printf '#!/usr/bin/env bash\nexit 7\n' > "$BROKEN/scripts/lib/transcript-patterns.sh"
broken_rc=0
env -u POSTMORTEM_SH HOME="$T/home" PI_SESSIONS_DIR="$CELL/sessions" \
  bash "$BROKEN/scripts/session-postmortem.sh" "$CELL_SESSION" --out "$BROKEN/out" \
  >"$T/broken.out" 2>"$T/broken.err" || broken_rc=$?
BROKEN_REPORT="$(cat "$BROKEN/out"/*.md 2>/dev/null || true)"
if [ "$broken_rc" -ne 0 ]; then
  ok "a producer exiting non-zero fails the run (rc=$broken_rc)"
else
  bad "a producer exiting non-zero still exited 0 — a partial section read as produced"
fi
assert_contains "$BROKEN_REPORT" "TRANSCRIPT PATTERNS SECTION DID NOT RUN" "non-zero producer is a banner inside the report"
assert_contains "$BROKEN_REPORT" "producer exited 7" "the report names the producer's exit code"

# The producer's OWN contract. Plain transcript, NO `#123` and no `/skill:` — the shape that
# killed the vendored-as-received source at "## What Shipped" (grep no-match + pipefail).
plain_rc=0
PLAIN="$(printf '[User] hi\n[Assistant] nothing interesting here\n' | bash "$PATTERN_LIB" 2>&1)" || plain_rc=$?
assert_eq "$plain_rc" "0" "producer survives a transcript with no #NNN reference (rc was 1 before)"
assert_contains "$PLAIN" "## Summary" "producer reaches its Summary on a transcript with no #NNN (output was truncated at '## What Shipped')"
assert_contains "$PLAIN" "_No batch patterns detected_" "no batch patterns is an explicit line, not a dead section"

# Exact-counts contract for the vendored parser (friction taxonomy + batch + improvements).
PATTERNS="$(printf '%s\n' \
  '[User] the gate blocked my work' \
  '[Assistant] gate again, and a workaround' \
  '[Assistant] malformed json: unterminated' \
  '[Assistant] this is counterproductive' \
  '[Assistant] restart required after deploy' \
  '[Assistant] see #100 #200 #300' \
  '[Assistant] /skill:commit-workflow' | bash "$PATTERN_LIB")"
assert_contains "$PATTERNS" "PRs referenced: 3" "parser counts unique PR references"
assert_contains "$PATTERNS" "  - gate/block/fail: 2 occurrence(s)" "parser counts gate/block/fail lines"
assert_contains "$PATTERNS" "  - workaround/hack: 1 occurrence(s)" "parser counts workaround/hack"
assert_contains "$PATTERNS" "  - restart-needed: 1 occurrence(s)" "parser counts restart-needed"
assert_contains "$PATTERNS" "  - parse/syntax error: 1 occurrence(s)" "parser counts parse/syntax errors"
assert_contains "$PATTERNS" "  - counterproductive: 1 occurrence(s)" "parser counts counterproductive"
assert_contains "$PATTERNS" "  - batch:multi-pr(3)" "parser classifies a multi-PR session"
assert_contains "$PATTERNS" "  - commit-workflow" "parser lists invoked skills"
assert_contains "$PATTERNS" "Shipped: 0 PRs, 0 issues" "summary line is ONE line (upstream's grep -c printed 0 twice and split it)"
assert_contains "$PATTERNS" "Improvements: 5" "improvements derive from every detected pattern class"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
