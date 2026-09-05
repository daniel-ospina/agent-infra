#!/usr/bin/env bash
# session-postmortem.sh — pi session JSONL → retrospective report + shared parser.
#
# Converts a pi session log (~/.pi/agent/sessions/<project-dir>/*.jsonl) into a
# plain-text transcript, runs postmortem.sh pattern detection on it (when the
# eldato postmortem script is reachable), and prepends a token/cost summary
# extracted from the session's usage data. Writes one .md file per session.
#
# Parser contract (#341 PR-B / #373): the per-session metric extraction is the
# SHARED parser for the fleet feedback loop. type:compaction records are
# included (compaction count, tokensBefore, ceiling classification ≥900K,
# usage incl. cost + reasoning — a compaction is a DISTINCT LLM call, not
# double-counted with adjacent messages). `--summary` emits the SAME metrics
# as one JSON object per session so fleet-cost-report.sh + watch-truncation.sh
# shell to ONE parser (no drift between report, watch, and the retro summary).
#
# Usage:
#   bash scripts/session-postmortem.sh <session.jsonl> [output-dir]
#   bash scripts/session-postmortem.sh --latest                # newest session for $PWD
#   bash scripts/session-postmortem.sh --since <days>          # all sessions newer than N days
#   bash scripts/session-postmortem.sh --summary <file>...     # shared parser: JSONL to stdout
#
# Output: <output-dir>/YYYY-MM-DD-<session-id-prefix>.md   (default docs/retrospectives/)
set -euo pipefail

SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
POSTMORTEM_SH="${POSTMORTEM_SH:-/Users/danielospina/Documents/GitHub/eldato/scripts/postmortem.sh}"
OUT_DIR="docs/retrospectives"
SINCE_DAYS=""
LATEST=0
SUMMARY=0
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest) LATEST=1; shift ;;
        --since) SINCE_DAYS="${2:-}"; shift 2 ;;
        --out) OUT_DIR="${2:-}"; shift 2 ;;
        --summary) SUMMARY=1; shift ;;
        *) FILES+=("$1"); shift ;;
    esac
done

# ── Shared parser (python) — metric extraction for retro summary + --summary ──
# One python process, one JSON object emitted per input file. Fields:
#   date/session      filename-derived identity
#   compacting        ≥1 type:compaction record
#   comp_count, ceiling_compactions (tokensBefore ≥ 900000 = 0.9×1M, policy §5),
#   max_tokensBefore
#   msg_calls         assistant MESSAGE usage records (the normal LLM calls)
#   msg_user_turns    user MESSAGE records (for the retro summary header)
#   msg_{input,output,cacheRead,cacheWrite,reasoning}  summed message usage
#   msg_cost_{total,cache}  summed message cost dict (cache = cacheRead+cacheWrite)
#   comp_{input,output,cacheRead,reasoning}, comp_cost_total  compaction-call usage
#   reread_volume     fresh input re-ingested by a compacting session (msg + comp
#                     input) — the watch's re-read leg
#   genuine_len_stops assistant msgs with stopReason==length whose ctx is at the
#                     session's own ceiling (ctx ≥ 0.92 × session max ctx) — the
#                     C8 mid-turn-overrun class; benign output caps never sit at
#                     the ceiling (validated: 111/111 corpus records qualify)
#   max_ctx           max assistant context (input+cacheRead) OR compaction
#                     tokensBefore across the session
parse_sessions() { # <file...> → JSONL on stdout
python3 - "$@" <<'PYEOF'
import json, sys

CEILING_TB = 900000        # 0.9 × 1M (pre-clamp window) — policy §5 drift detector
GENUINE_FLOOR = 0.92       # length-stop ctx must be ≥0.92 × session max ctx

def one(fp):
    out = {"date": None, "session": None, "compacting": False,
           "comp_count": 0, "ceiling_compactions": 0, "max_tokensBefore": 0,
           "msg_calls": 0, "msg_user_turns": 0,
           "msg_input": 0, "msg_output": 0, "msg_cacheRead": 0,
           "msg_cacheWrite": 0, "msg_reasoning": 0,
           "msg_cost_total": 0.0, "msg_cost_cache": 0.0,
           "comp_input": 0, "comp_output": 0, "comp_cacheRead": 0,
           "comp_reasoning": 0, "comp_cost_total": 0.0,
           "reread_volume": 0, "genuine_len_stops": 0, "max_ctx": 0}
    base = fp.rsplit("/", 1)[-1]
    out["date"] = base[:10]
    out["session"] = base
    len_ctxs = []
    n_lines = 0
    n_bad = 0
    for line in open(fp, errors="replace"):
        if not line.strip():
            continue
        n_lines += 1
        try:
            o = json.loads(line)
        except Exception:
            n_bad += 1
            continue
        t = o.get("type")
        if t == "compaction":
            out["compacting"] = True
            out["comp_count"] += 1
            tb = o.get("tokensBefore", 0) or 0
            out["max_tokensBefore"] = max(out["max_tokensBefore"], tb)
            out["max_ctx"] = max(out["max_ctx"], tb)
            if tb >= CEILING_TB:
                out["ceiling_compactions"] += 1
            u = o.get("usage") or {}
            out["comp_input"] += u.get("input", 0) or 0
            out["comp_output"] += u.get("output", 0) or 0
            out["comp_cacheRead"] += u.get("cacheRead", 0) or 0
            out["comp_reasoning"] += u.get("reasoning", 0) or 0
            c = u.get("cost")
            if isinstance(c, dict):
                out["comp_cost_total"] += c.get("total", 0) or 0
        elif t == "message":
            m = o.get("message", {})
            if m.get("role") == "user":
                out["msg_user_turns"] += 1
            if m.get("role") == "assistant":
                u = o.get("usage") or m.get("usage") or {}
                if u.get("input") is not None:
                    out["msg_calls"] += 1
                    out["msg_input"] += u.get("input", 0) or 0
                    out["msg_output"] += u.get("output", 0) or 0
                    out["msg_cacheRead"] += u.get("cacheRead", 0) or 0
                    out["msg_cacheWrite"] += u.get("cacheWrite", 0) or 0
                    out["msg_reasoning"] += u.get("reasoning", 0) or 0
                    c = u.get("cost")
                    if isinstance(c, dict):
                        out["msg_cost_total"] += c.get("total", 0) or 0
                        out["msg_cost_cache"] += (c.get("cacheRead", 0) or 0) + (c.get("cacheWrite", 0) or 0)
                    ctx = (u.get("input", 0) or 0) + (u.get("cacheRead", 0) or 0)
                    out["max_ctx"] = max(out["max_ctx"], ctx)
                    if m.get("stopReason") == "length":
                        len_ctxs.append(ctx)
    out["reread_volume"] = out["msg_input"] + out["comp_input"]
    # genuine ceiling-truncation markers: length stops at ≥0.92 × the session's
    # own observed ceiling (validated: every corpus length record qualifies)
    if out["max_ctx"] > 0:
        for ctx in len_ctxs:
            if ctx >= GENUINE_FLOOR * out["max_ctx"]:
                out["genuine_len_stops"] += 1
    # corrupt-but-readable content must surface (data-absence gate, #373): a
    # file whose lines are ALL unparseable (binary/garbage) or that is EMPTY
    # carries no session records at all — treat as an error row, not a healthy
    # zero session, or the rollback-decision instrument reports CLEAN on data
    # loss. (Partial files with ≥1 parseable line still parse; a crash that
    # drops the tail mid-write is indistinguishable from a shorter session.)
    # Real-corpus check at #373: 0/269 sessions are empty or all-bad, so this
    # tag never fires on the healthy fleet.
    if n_lines == 0:
        out["error"] = "empty file — no session records"
    elif n_bad and n_bad >= n_lines:
        out["error"] = f"{n_bad}/{n_lines} line(s) unparseable — corrupt or binary file"
    return out

out = []
for fp in sys.argv[1:]:
    try:
        out.append(one(fp))
    except Exception as e:
        out.append({"date": None, "session": fp.rsplit("/", 1)[-1], "error": str(e)})
for row in out:
    print(json.dumps(row))
PYEOF
}

# ── --summary: shared parser mode (no files written, no postmortem.sh needed) ──
if [ "$SUMMARY" = "1" ]; then
    if [ "${#FILES[@]}" -eq 0 ]; then
        echo "usage: session-postmortem.sh --summary <session.jsonl> [more...]" >&2
        exit 2
    fi
    parse_sessions "${FILES[@]}"
    exit 0
fi

# ── Resolve session files ──
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
    echo "       session-postmortem.sh --latest | --since <days> | --summary <file>..." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

for SESSION in "${SESSION_FILES[@]}"; do
    [ -f "$SESSION" ] || { echo "skip (not found): $SESSION" >&2; continue; }
    NAME=$(basename "$SESSION" .jsonl)
    DATE="${NAME:0:10}"
    OUTFILE="$OUT_DIR/$DATE-${NAME:11:8}.md"

    # --- 1. Token/cost summary from the SHARED parser (#341 PR-B) ---
    METRIC="$(parse_sessions "$SESSION")"
    # Retro path must mirror the report/watch data-absence contract: an
    # error-tagged row (unreadable/corrupt/empty session) would KeyError the
    # summary below — skip to a short note instead of aborting the batch.
    if printf '%s' "$METRIC" | grep -q '"error"'; then
        ERR_MSG="$(printf '%s' "$METRIC" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('error','unreadable'))" 2>/dev/null || echo unreadable)"
        {
          echo "# Retrospective — $DATE"
          echo ""
          echo "> Generated $(date -u +%Y-%m-%dT%H:%MZ) by scripts/session-postmortem.sh — SKIPPED: parser could not read this session ($ERR_MSG)."
        } > "$OUTFILE"
        echo "skipped (parser error): $SESSION" >&2
        continue
    fi
    python3 - "$METRIC" > /tmp/pm-summary.txt <<'PYEOF'
import json, sys
m = json.loads(sys.argv[1])
print("## Session Metrics")
print(f"- LLM calls: {m['msg_calls']}   user turns: {m['msg_user_turns']}")
print(f"- input tokens: {m['msg_input']:,}   output: {m['msg_output']:,}   "
      f"cache-read: {m['msg_cacheRead']:,}   reasoning: {m['msg_reasoning']:,}")
print(f"- max context (input+cacheRead / compaction tokensBefore): {m['max_ctx']:,}")
if m["compacting"]:
    print(f"- compaction records: {m['comp_count']}   max tokensBefore: {m['max_tokensBefore']:,}"
          f"   ceiling-compactions (≥900K): {m['ceiling_compactions']}")
    print(f"- compaction-call usage: input {m['comp_input']:,}  output {m['comp_output']:,}"
          f"  reasoning {m['comp_reasoning']:,}  (cacheRead ≈ {m['comp_cacheRead']:,} — a distinct LLM call)")
if m["genuine_len_stops"]:
    print(f"- stopReason:length (ceiling truncation) records: {m['genuine_len_stops']}")
cc = m["msg_cost_total"]
if cc > 0:
    cache_share = 100 * m["msg_cost_cache"] / cc
    print(f"- estimated cost: ${cc:.2f} (cache-read ≈ {cache_share:.0f}% of message spend)")
    if m["comp_cost_total"] > 0:
        print(f"- compaction-call cost: ${m['comp_cost_total']:.2f}")
else:
    # estimate cost if the log lacks a cost field (models.json flash rates)
    est = (m["msg_input"]*0.14 + m["msg_output"]*0.28 + (m["msg_cacheRead"]+m["msg_cacheWrite"])*0.0028) / 1e6
    print(f"- estimated cost: ${est:.2f} (fallback rates; log lacked cost dict)")
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
