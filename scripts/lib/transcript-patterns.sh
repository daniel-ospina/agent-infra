#!/usr/bin/env bash
# transcript-patterns.sh — transcript → friction/batch/improvement pattern report.
#
# VENDORED (#1921). Upstream is `daniel-ospina/eldato` `scripts/postmortem.sh` at
# sha 2b2c367c56071f25881e29a0897012e630dba779 (read 2026-10-17, 219 lines). It was
# vendored — not left referenced by absolute path — because a farmed consumer may not
# exec a producer that lives in ANOTHER checkout: `session-postmortem.sh` is in
# `pi-bootstrap/setup.sh`'s `fleet_srcs`, so it lands on every box, while the producer
# did not, so every box but the owner's silently lost its Transcript Patterns section.
# This file is farmed beside its consumer (scripts/lib/ ← the sibling contract
# pi-reap-idle.sh/record-review.sh/cadence-nudge.sh already use), so it resolves
# anywhere: a Mac, a Linux cell, a rebuilt host.
#
# Upstream's own contract is preserved: stdin = a plain-text transcript, stdout = the
# report, no arguments (it still accepts `--pr/--issues/--from-log/--all`).
#
# DEVIATIONS FROM THE UPSTREAM BYTES — listed in full below (the pipefail-abort class is
# three classes / four sites, all one defect; three further sites/deltas are recorded after it):
# upstream runs under `set -euo pipefail`, and a pipeline whose `grep` finds NO match exits
# 1, which ABORTS the whole producer. Measured on the vendored-as-received source:
#     $ printf '[User] hi\n[Assistant] nothing here\n' | bash postmortem.sh
#     === Session Postmortem ===
#     ## What Shipped          <- ends here, rc=1
# A session that references no `#123` (very common) therefore produced a TRUNCATED
# section — the same silent-degradation class this vendoring exists to remove, and the
# reason the consumer now treats a non-zero producer exit as a failure of the section
# rather than as content. The first two classes add `|| true` so "no match" means 0
# occurrences (`#[0-9]+` in two places, `/skill:[a-z-]+` in one); no pattern changed. The
# third is the Summary's PR/issue counter: upstream's `grep -c . || echo 0` printed `0`
# AND `0` (grep -c prints the count and still exits 1), splitting one line into two
# (`Shipped: 0` / `0 PRs, 0`).
# One non-behavioural delta rides along: the five friction counters are initialised to 0
# before the branch that fills them, so an empty transcript cannot reach the Summary with
# them unset. Upstream's `${GATE_COUNT:-0}` fallbacks already covered that; the init only
# makes the default visible where a reader looks for it.
# A FIFTH delta, added in the same landing (#841/#864): four `echo "$text" | grep -q …`
# sites became here-strings (`grep -q … <<<"$text"`). Same false-negative class, different
# mechanism — `grep -q` exits at its first match, and under `set -o pipefail` the writer's
# SIGPIPE makes the PIPELINE non-zero, so a transcript that DOES match reads as no-match
# once it outgrows the pipe buffer. No pattern, and no output on any input, changed:
# `bash scripts/check-no-sigpipe-grep.sh` is the instrument that refuses the idiom.
#
# Re-syncing with upstream: diff against the sha above; the only intended deltas are
# the ones named here. Anything else is drift, and a second copy of this parser is how
# the two would diverge — so extend THIS file, do not fork it.
#
# Usage:
#   bash scripts/lib/transcript-patterns.sh < /tmp/transcript.txt
#   bash scripts/lib/transcript-patterns.sh --pr 5691,5692 --issues 5691,5692
set -euo pipefail

PRS=""
ISSUES=""
SESSION_FILE=""
SHOW_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr) PRS="${2:-}"; shift 2 ;;
        --issue|--issues) ISSUES="${2:-}"; shift 2 ;;
        --from-log) SESSION_FILE="${2:-}"; shift 2 ;;
        --all) SHOW_ALL=1; shift ;;
        *) shift ;;
    esac
done

# Collect session text
SESSION_TEXT=""
if [ -n "$SESSION_FILE" ] && [ -f "$SESSION_FILE" ]; then
    SESSION_TEXT=$(cat "$SESSION_FILE")
elif [ ! -t 0 ]; then
    SESSION_TEXT=$(cat)
fi

# --- Pattern detection ---

detect_friction() {
    local text="$1"
    local patterns=0

    # Gate/block/fail words
    echo "$text" | grep -ciE '\b(block|blocked|blocking|gate|guard|fail|failed|failure)\b' || true

    # Workaround/hack words
    local wa
    wa=$(echo "$text" | grep -ciE '\b(workaround|bypass|hack|kludge|hotfix)\b' || true)
    echo "$wa"
    patterns=$((patterns + wa))

    # Restart/reload words
    local rr
    rr=$(echo "$text" | grep -ciE '\b(restart|reload).*(need|required|fix|activate)\b' || true)
    echo "$rr"

    # Parse/syntax errors
    local pe
    pe=$(echo "$text" | grep -ciE '\b(parse.error|syntax.error|unterminated|malformed)\b' || true)
    echo "$pe"

    # Counterproductive harness
    local ch
    ch=$(echo "$text" | grep -ciE '\b(counterproductive|should.n.t|should.not)\b' || true)
    echo "$ch"
}

detect_batch() {
    local text="$1"

    # "file issues" + "fix all" patterns
    # Here-string, NOT a pipe (#841/#864): `grep -q` exits at the first match, and under
    # `set -o pipefail` the resulting SIGPIPE on the writer makes the PIPELINE non-zero —
    # so a matching transcript would read as no-match. A here-string has no writer to kill.
    if grep -qiE '(file|create).*issues.*(fix|implement).*all' <<<"$text" 2>/dev/null; then
        echo "batch:issue-then-fix"
    fi

    # Numbered groupings: "all three", "both", "the first two"
    if grep -qiE '\b(all\s+(three|four|five|of\s+them)|the\s+(first|last)\s+(two|three))\b' <<<"$text" 2>/dev/null; then
        echo "batch:numbered-group"
    fi

    # "Do X for every Y" patterns
    if grep -qiE '\b(for\s+every|for\s+each|all\s+the)\b' <<<"$text" 2>/dev/null; then
        echo "batch:for-each"
    fi

    # Multi-PR session detection
    local pr_count
    # `|| true`: NO `#123` anywhere is 0 references, not a dead producer (deviation 1).
    pr_count=$(echo "$text" | grep -oE '#[0-9]+' | sort -u | wc -l | tr -d ' ' || true)
    if [ "${pr_count:-0}" -ge 3 ]; then
        echo "batch:multi-pr($pr_count)"
    fi
}

detect_skills() {
    local text="$1"
    # `|| true`: a transcript with no `/skill:` is normal (deviation 2).
    echo "$text" | grep -oE '/skill:[a-z-]+' | sort -u | sed 's|/skill:||' || true
}

# --- Output ---

echo "=== Session Postmortem ==="
echo ""

# What shipped
echo "## What Shipped"
if [ -n "$PRS" ]; then
    IFS=',' read -ra PR_ARR <<< "$PRS"
    echo "PRs: ${#PR_ARR[@]}"
    for pr in "${PR_ARR[@]}"; do
        echo "  - #$pr"
    done
elif [ -n "$SESSION_TEXT" ]; then
    # `|| true`: no `#123` in the transcript is 0 referenced PRs (deviation 1).
    PR_COUNT=$(echo "$SESSION_TEXT" | grep -oE '#[0-9]+' | sort -u | wc -l | tr -d ' ' || true)
    echo "PRs referenced: ${PR_COUNT:-0}"
else
    echo "_No PR data available_"
fi

if [ -n "$ISSUES" ]; then
    IFS=',' read -ra ISS_ARR <<< "$ISSUES"
    echo "Issues: ${#ISS_ARR[@]}"
else
    echo "Issues: _not provided_"
fi

# Skills invoked
if [ -n "$SESSION_TEXT" ]; then
    SKILLS=$(detect_skills "$SESSION_TEXT")
    if [ -n "$SKILLS" ]; then
        echo ""
        echo "Skills invoked:"
        echo "$SKILLS" | while read -r s; do
            [ -n "$s" ] && echo "  - $s"
        done
    fi
fi
echo ""

# What blocked / friction patterns
echo "## Friction Patterns"
GATE_COUNT=0
WA_COUNT=0
RR_COUNT=0
PE_COUNT=0
CH_COUNT=0
if [ -n "$SESSION_TEXT" ]; then
    FRICTION=$(detect_friction "$SESSION_TEXT")
    GATE_COUNT=$(echo "$FRICTION" | sed -n '1p')
    WA_COUNT=$(echo "$FRICTION" | sed -n '2p')
    RR_COUNT=$(echo "$FRICTION" | sed -n '3p')
    PE_COUNT=$(echo "$FRICTION" | sed -n '4p')
    CH_COUNT=$(echo "$FRICTION" | sed -n '5p')

    [ "${GATE_COUNT:-0}" -gt 0 ] && echo "  - gate/block/fail: ${GATE_COUNT} occurrence(s)"
    [ "${WA_COUNT:-0}" -gt 0 ] && echo "  - workaround/hack: ${WA_COUNT} occurrence(s)"
    [ "${RR_COUNT:-0}" -gt 0 ] && echo "  - restart-needed: ${RR_COUNT} occurrence(s)"
    [ "${PE_COUNT:-0}" -gt 0 ] && echo "  - parse/syntax error: ${PE_COUNT} occurrence(s)"
    [ "${CH_COUNT:-0}" -gt 0 ] && echo "  - counterproductive: ${CH_COUNT} occurrence(s)"

    TOTAL_F=$(( ${GATE_COUNT:-0} + ${WA_COUNT:-0} + ${RR_COUNT:-0} + ${PE_COUNT:-0} + ${CH_COUNT:-0} ))
    [ "$TOTAL_F" -eq 0 ] && echo "  _No friction detected_"
else
    echo "  _No session context provided_"
fi
echo ""

# Batch patterns
echo "## Batch Patterns"
BATCH=""
if [ -n "$SESSION_TEXT" ]; then
    BATCH=$(detect_batch "$SESSION_TEXT")
    if [ -n "$BATCH" ]; then
        echo "$BATCH" | while read -r bp; do
            [ -n "$bp" ] && echo "  - $bp"
        done
    else
        echo "  _No batch patterns detected_"
    fi
else
    echo "  _No session context provided_"
fi
echo ""

# Improvement ideas
echo "## Improvement Ideas"
IMPROVEMENTS=0
if [ -n "$SESSION_TEXT" ]; then
    # Gate-related improvements
    if [ "${GATE_COUNT:-0}" -gt 0 ]; then
        echo "  - Consider standalone pre-commit hooks (no extension dependency)"
        IMPROVEMENTS=$((IMPROVEMENTS + 1))
    fi
    # Workaround patterns → tool issue
    if [ "${WA_COUNT:-0}" -gt 0 ]; then
        echo "  - Workarounds used — file tool improvement issues"
        IMPROVEMENTS=$((IMPROVEMENTS + 1))
    fi
    # Restart patterns → extension deploy gap
    if [ "${RR_COUNT:-0}" -gt 0 ]; then
        echo "  - Restart dependency detected — file extension deploy/activate gap issue"
        IMPROVEMENTS=$((IMPROVEMENTS + 1))
    fi
    # Parse errors → robustness
    if [ "${PE_COUNT:-0}" -gt 0 ]; then
        echo "  - Parse errors — improve validator robustness or add lint step"
        IMPROVEMENTS=$((IMPROVEMENTS + 1))
    fi
    # Batch patterns → auto-continue or bulk tool
    if grep -q . <<<"$BATCH" 2>/dev/null; then
        echo "  - Batch pattern detected — consider bulk-operation tooling or /auto workflow"
        IMPROVEMENTS=$((IMPROVEMENTS + 1))
    fi
fi
[ "$IMPROVEMENTS" -eq 0 ] && echo "  _Run enrich_frontmatter.py for LLM-generated improvements_"
echo ""

# Summary
echo "## Summary"
FRIC_COUNT=$(( ${GATE_COUNT:-0} + ${WA_COUNT:-0} + ${RR_COUNT:-0} + ${PE_COUNT:-0} + ${CH_COUNT:-0} ))
# `|| true`: grep -c prints "0" AND exits 1 on no match, so upstream's `|| echo 0`
# emitted two lines and split the summary (deviation 3).
PR_COUNT_NUM=$(echo "${PRS:-}" | tr ',' '\n' | grep -c . 2>/dev/null || true)
ISS_COUNT_NUM=$(echo "${ISSUES:-}" | tr ',' '\n' | grep -c . 2>/dev/null || true)

echo "Shipped: ${PR_COUNT_NUM:-0} PRs, ${ISS_COUNT_NUM:-0} issues"
echo "Friction: ${FRIC_COUNT:-0} patterns"
echo "Improvements: ${IMPROVEMENTS}"
