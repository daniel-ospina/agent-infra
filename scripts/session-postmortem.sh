#!/usr/bin/env bash
# session-postmortem.sh — pi session JSONL → retrospective report.
#
# Converts a pi session log (~/.pi/agent/sessions/<project-dir>/*.jsonl) into a
# plain-text transcript, runs postmortem.sh pattern detection on it (when the
# eldato postmortem script is reachable), and prepends a token/cost summary
# extracted from the session's usage data. Writes one .md file per session.
#
# Usage:
#   bash scripts/session-postmortem.sh <session.jsonl> [output-dir]
#   bash scripts/session-postmortem.sh --latest                # newest session for $PWD
#   bash scripts/session-postmortem.sh --since <days>          # all sessions newer than N days
#
# Output: <output-dir>/YYYY-MM-DD-<session-id-prefix>.md   (default docs/retrospectives/)
set -euo pipefail

SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
POSTMORTEM_SH="${POSTMORTEM_SH:-/Users/danielospina/Documents/GitHub/eldato/scripts/postmortem.sh}"
OUT_DIR="docs/retrospectives"
SINCE_DAYS=""
LATEST=0
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest) LATEST=1; shift ;;
        --since) SINCE_DAYS="${2:-}"; shift 2 ;;
        --out) OUT_DIR="${2:-}"; shift 2 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

# --- Resolve session files ---
if [ "${#FILES[@]}" -gt 0 ]; then
    SESSION_FILES=("${FILES[@]}")
elif [ "$LATEST" = "1" ]; then
    # Session dir names mirror the cwd path with '/' -> '-' and '--' framing,
    # e.g. ~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/
    DIRSEG="--$(pwd | sed 's|/|-|g')--"
    GLOB="$SESSIONS_DIR/$DIRSEG/"*.jsonl
    MATCHES=()
    while IFS= read -r f; do MATCHES+=("$f"); done < <(compgen -G "$GLOB" 2>/dev/null | sort || true)
    if [ "${#MATCHES[@]}" -eq 0 ]; then
        echo "No session found for $(pwd) in $SESSIONS_DIR (looked in $DIRSEG)" >&2
        exit 1
    fi
    # newest first
    SESSION_FILES=($(ls -t "${MATCHES[@]}" 2>/dev/null | head -1 || true))
    if [ -z "${SESSION_FILES:-}" ] || [ ! -f "${SESSION_FILES[0]:-}" ]; then
        echo "No session found for project '$PROJ_DIR' in $SESSIONS_DIR" >&2
        exit 1
    fi
elif [ -n "$SINCE_DAYS" ]; then
    SESSION_FILES=()
    while IFS= read -r f; do
        SESSION_FILES+=("$f")
    done < <(find "$SESSIONS_DIR" -name "*.jsonl" -mtime -"$SINCE_DAYS" 2>/dev/null | sort)
else
    echo "Usage: session-postmortem.sh <session.jsonl> [--out docs/retrospectives]" >&2
    echo "       session-postmortem.sh --latest | --since <days>" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

for SESSION in "${SESSION_FILES[@]}"; do
    [ -f "$SESSION" ] || { echo "skip (not found): $SESSION" >&2; continue; }
    NAME=$(basename "$SESSION" .jsonl)
    DATE="${NAME:0:10}"
    OUTFILE="$OUT_DIR/$DATE-${NAME:11:8}.md"

    # --- 1. Token/cost summary from usage records ---
    python3 - "$SESSION" > /tmp/pm-summary.txt <<'PYEOF'
import json, sys
fp = sys.argv[1]
tot = {"input":0,"output":0,"cache":0,"reason":0,"cost":0.0}
calls = 0
turns = 0
maxin = 0
for line in open(fp):
    try: o = json.loads(line)
    except: continue
    if o.get("type") == "message":
        m = o.get("message", {})
        if m.get("role") == "assistant":
            u = o.get("usage") or m.get("usage") or {}
            if u.get("input") is not None:
                calls += 1
                tot["input"] += u.get("input",0); tot["output"] += u.get("output",0)
                tot["cache"] += u.get("cacheRead",0)+u.get("cacheWrite",0)
                tot["reason"] += u.get("reasoning",0)
                c = u.get("cost") or {}
                if isinstance(c, dict):
                    tot["cost"] += c.get("total",0) or 0
                maxin = max(maxin, u.get("input",0) + u.get("cacheRead",0))
        elif m.get("role") == "user":
            turns += 1
# estimate cost if the log lacks a cost field (models.json flash rates)
if tot["cost"] <= 0:
    tot["cost"] = tot["input"]*0.14/1e6 + tot["output"]*0.28/1e6 + tot["cache"]*0.0028/1e6
print(f"## Session Metrics")
print(f"- LLM calls: {calls}   user turns: {turns}")
print(f"- input tokens: {tot['input']:,}   output: {tot['output']:,}   cache-read: {tot['cache']:,}   reasoning: {tot['reason']:,}")
print(f"- max context (input+cacheRead): {maxin:,}")
print(f"- estimated cost: ${tot['cost']:.2f} (cache-read ≈ {100*tot['cache']*0.0028/1e6/max(tot['cost'],1e-9):.0f}% of spend)")
PYEOF

    # --- 2. Transcript conversion ---
    python3 - "$SESSION" > /tmp/pm-transcript.txt <<'PYEOF'
import json, sys
fp = sys.argv[1]
for line in open(fp):
    try: o = json.loads(line)
    except: continue
    if o.get("type") != "message":
        continue
    m = o.get("message", {})
    role = m.get("role")
    if role == "user":
        for c in m.get("content", []):
            if c.get("type") == "text":
                print(f"[User] {c.get('text','')}")
    elif role == "assistant":
        for c in m.get("content", []):
            t = c.get("type")
            if t == "text":
                print(f"[Assistant] {c.get('text','')}")
            elif t == "toolCall":
                args = c.get("arguments") or ""
                if isinstance(args, dict):
                    args = json.dumps(args)[:200]
                print(f"[Assistant tool] {c.get('name','?')}({str(args)[:200]})")
            elif t == "thinking":
                pass  # skip internal reasoning noise
    elif role == "toolResult":
        txt = ""
        for c in m.get("content", []):
            if isinstance(c, dict) and c.get("type") == "text":
                txt = c.get("text","")
            elif isinstance(c, str):
                txt = c
        print(f"[Tool result] {txt[:2000]}")
PYEOF

    # --- 3. Assemble report ---
    {
        echo "# Retrospective — $NAME"
        echo ""
        echo "> Generated $(date -u +%Y-%m-%dT%H:%MZ) by scripts/session-postmortem.sh from \`$SESSION\`"
        echo ""
        cat /tmp/pm-summary.txt
        echo ""
        echo "## Transcript Patterns"
        echo ""
        if [ -f "$POSTMORTEM_SH" ]; then
            cat /tmp/pm-transcript.txt | bash "$POSTMORTEM_SH"
        else
            echo "_postmortem.sh not found at $POSTMORTEM_SH — transcript-only report_"
            echo ""
            echo '```'
            cat /tmp/pm-transcript.txt
            echo '```'
        fi
    } > "$OUTFILE"

    echo "wrote $OUTFILE ($(wc -c < "$OUTFILE" | tr -d ' ') bytes)"
done

rm -f /tmp/pm-summary.txt /tmp/pm-transcript.txt
