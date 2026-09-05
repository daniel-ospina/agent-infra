#!/usr/bin/env bash
# fleet-cost-weekly.test.sh — self-check for the weekly cadence driver
# scripts/fleet-cost-weekly.sh (#373). Uses a stubbed GH_BIN that records
# invocations — no network, no real ~/.pi/agent sessions. Run:
#   bash scripts/fleet-cost-weekly.test.sh
# Exit 0 all-pass · 1 any failure.
#
# Coverage:
#   CLEAN       no escalations → exit 0, no gh call, PASS logged
#   TRIGGER     report trips (ceiling) → exit 1, gh issue CREATE with the
#               combined report+watch body
#   DEDUP       second trip with an OPEN issue present → gh issue COMMENT
#               (never a second create)
#   DRY-RUN     --dry-run on a trigger → exit 1, prints body, NO gh call
#   report rc only / watch rc only each escalate (exit 1)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEEKLY="$SCRIPT_DIR/fleet-cost-weekly.sh"
export SPM_SH="$SCRIPT_DIR/session-postmortem.sh"
export FLEET_REPO="test-owner/agent-infra"
TODAY="$(date +%Y-%m-%d)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
T="$(mktemp -d /tmp/weekly-test.XXXXXX)"; trap 'rm -rf "$T"' EXIT
export FLEET_LOG="$T/weekly.log"
export GH_BIN="$T/gh"
export GH_LOG="$T/gh.log"

# gh stub: record every invocation; state comes from GH_EXISTING env
cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG:?}"
case "$1" in
  issue) shift
    case "$1" in
      list) echo "${GH_EXISTING:-[]}" ;;
      create) echo "https://github.com/mock/issue/99" ;;
      comment) echo ok ;;
    esac ;;
esac
EOF
chmod +x "$T/gh"

# ── fixtures ────────────────────────────────────────────────────────────────
# compacting clamp-regime session generator: $1 dir $2 idx $3 tokensBefore
# $4 length(0|1). A ceiling session (tokensBefore ≥900K) trips the REPORT; a
# length session trips the WATCH.
mk_sess() { # dir idx tokensBefore length
    local d="$1/sessions"; mkdir -p "$d"
    python3 - "$d/${TODAY}T10-${2}-00-000Z_s${2}.jsonl" "$3" "$4" <<'PY'
import json, sys
fp, tb, length = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = [
    {"type": "compaction", "timestamp": "x", "tokensBefore": tb,
     "usage": {"input": 500000, "output": 2000, "cacheRead": 3, "cacheWrite": 0,
               "reasoning": 1000, "cost": {"input": 0.01, "total": 0.0105}}},
    {"type": "message", "message": {"role": "assistant",
                                    "stopReason": "length" if length else "toolUse",
                                    "content": []},
     "usage": {"input": 300, "output": 100, "cacheRead": 400000,
               "cacheWrite": 0, "reasoning": 50,
               "cost": {"input": 0.0001, "cacheRead": 0.0005, "total": 0.0006}}},
]
with open(fp, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY
}

echo "── fleet-cost-weekly driver ────────────────────────────────"

# CLEAN: 3 clamp-regime sessions, healthy cache-share, no length stops
D="$T/clean"
mk_sess "$D" 1 383000 0; mk_sess "$D" 2 383000 0; mk_sess "$D" 3 383000 0
rm -f "$T/gh.log"; GH_LOG="$T/gh.log"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WEEKLY" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "0" "clean fixture exits 0"
assert_contains "$OUT" "PASS window=1d" "clean fixture logs PASS"
[ ! -s "$T/gh.log" ] && ok "clean fixture makes no gh call" || bad "clean fixture called gh: $(cat "$T/gh.log")"

# WATCH-only trigger (length) → create
D="$T/len"; mk_sess "$D" 9 383000 1
rm -f "$T/gh.log"; unset GH_EXISTING
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WEEKLY" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "watch-trigger fixture exits 1"
assert_contains "$OUT" "opened fleet-cost issue" "watch-trigger opens an issue"
assert_contains "$(cat "$T/gh.log")" "issue create" "watch-trigger ran gh issue create"
assert_contains "$(cat "$T/gh.log")" "TRIGGERED" "create body carries the watch escalation"

# REPORT-only trigger (ceiling) → create
D="$T/ceil"; mk_sess "$D" 8 996000 0
rm -f "$T/gh.log"; unset GH_EXISTING
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WEEKLY" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "report-trigger fixture exits 1"
assert_contains "$OUT" "opened fleet-cost issue" "report-trigger opens an issue"

# DEDUP: existing OPEN issue number returned by list → comment, not create
export GH_EXISTING='[{"number": 42}]'
rm -f "$T/gh.log"
RC=0; OUT="$(PI_SESSIONS_DIR="$T/len/sessions" bash "$WEEKLY" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "dedup fixture exits 1"
assert_contains "$OUT" "commented on existing fleet-cost issue" "dedup comments on open issue"
assert_contains "$(cat "$T/gh.log")" "issue comment" "dedup ran gh issue comment"
if grep -q "issue create" "$T/gh.log"; then bad "dedup must NOT create a second issue"; else ok "dedup never creates while an issue is open"; fi

# ENV-ERROR: bogus sessions dir → report/watch exit 2 → no issue, exit 2
rm -f "$T/gh.log"
RC=0; OUT="$(PI_SESSIONS_DIR="$T/nonexistent" bash "$WEEKLY" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "2" "missing sessions dir exits 2 (env error, not escalation)"
assert_contains "$OUT" "env failure, not an escalation" "env error logged distinctly"
[ ! -s "$T/gh.log" ] && ok "env error files no issue" || bad "env error called gh: $(cat "$T/gh.log")"

# DRY-RUN: trigger + --dry-run → no gh call, body printed
unset GH_EXISTING; rm -f "$T/gh.log"
RC=0; OUT="$(PI_SESSIONS_DIR="$T/len/sessions" bash "$WEEKLY" --days 1 --dry-run 2>&1)" || RC=$?
assert_eq "$RC" "1" "--dry-run exits 1 on trigger (escalation still signalled)"
assert_contains "$OUT" "[dry-run] would file" "--dry-run announces would-file"
[ ! -s "$T/gh.log" ] && ok "--dry-run makes no gh call" || bad "--dry-run called gh: $(cat "$T/gh.log")"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
