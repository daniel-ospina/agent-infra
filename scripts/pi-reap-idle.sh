#!/usr/bin/env bash
# pi-reap-idle.sh — reap provably-idle interactive pi REPL sessions (#469).
#
# Policy contract: docs/ops/pi-idle-repl-reaper-policy.md + scope doc
# docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md. Design gates:
#   * FAIL-CLOSED idle proof: a session is reaped ONLY when its pi session
#     JSONL's last parseable entry is strictly older than REAP_IDLE_HOURS
#     (strict >; an exactly-24h session survives). No proof (missing/garbage/
#     unparseable file) => NOT idle => never kill. cmux lifecycle records are
#     VETO-only, never proof.
#   * ALLOWLIST per-pid union veto: EVERY incarnation-matched cmux record
#     must carry agentLifecycle==idle AND runtimeStatus==idle. Any other
#     value on either key (running/needsInput/unknown/error/None/absent)
#     vetoes the pid. Stale (>±3s) sibling records neither prove nor veto.
#   * Incarnation fence: record pidStartSeconds within ±3s of the ps lstart
#     (second-granularity rounding differs up to ~1s in live data).
#   * Never kill active work: settle re-verify BEFORE each signal uses a
#     FRESH per-pid ps probe (lstart changed => pid died+reused => suppress)
#     and a FRESH JSONL re-probe (activity advanced => suppress). Post-TERM
#     survivor re-check = the same fresh probe (kill -0 is never the oracle).
#   * Never touch another session's checkout: own tty / own ancestor pids /
#     own PI_SESSION_ID are hard skips. Orchestrating marathons (a live
#     non-zombie pi descendant) are skipped.
#   * Bash 3.2-safe only (macOS /bin/bash = 3.2.57): no declare -A /
#     mapfile / ${var,,} — bash 5.x on ubuntu CI would mask 4-only code.
#     Signals always go through ${KILL_BIN} (never the bare builtin).
#   * Version sensitivity: pi/cmux session shapes may drift — see the policy
#     doc. Interactive default is dry-run (warn-first); the MODE= footer
#     makes armed vs dry passes legible in the log.
#
# Usage:
#   pi-reap-idle.sh [--dry-run] [--apply] [--idle-hours N] [--list]
#                   [--probe-jsonl FILE...] [--help]
# Env seams: PS_BIN KILL_BIN DATE_BIN CMUX_STATE_DIR PI_SESSIONS_DIR
#   REAP_IDLE_HOURS REAP_DRY_RUN REAP_GRACE_SECONDS REAP_NOW_EPOCH
#   REAP_LOCK_STALE_SECONDS REAP_LOG (default $HOME/.pi/agent/state/
#   pi-reap-idle.log).
# Exit codes: 0 completed passes, 2 usage, 3 fail-closed (store/lock abort).

set -uo pipefail

SCRIPT_NAME="pi-reap-idle.sh"
ISSUE_REF="#469"
REAP_LOG="${REAP_LOG:-$HOME/.pi/agent/state/pi-reap-idle.log}"
PS_BIN="${PS_BIN:-/bin/ps}"
KILL_BIN="${KILL_BIN:-/bin/kill}"
DATE_BIN="${DATE_BIN:-/bin/date}"
CMUX_STATE_DIR="${CMUX_STATE_DIR:-$HOME/.cmuxterm}"
CMUX_STORE="$CMUX_STATE_DIR/pi-hook-sessions.json"
PI_SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
REAP_IDLE_HOURS="${REAP_IDLE_HOURS:-24}"
REAP_GRACE_SECONDS="${REAP_GRACE_SECONDS:-5}"
REAP_LOCK_STALE_SECONDS="${REAP_LOCK_STALE_SECONDS:-1800}"
STATE_DIR="$HOME/.pi/agent/state"
LOCK_DIR="$STATE_DIR/pi-reap-idle.lock"
# Disarm valve: touch $STATE_DIR/pi-reap-idle.disabled to make every pass
# (even --apply) log a MODE=disabled footer and exit 0 without signaling.
# Survives re-syncs that re-install the launchd job (#469).
DISABLED_SENTINEL="$STATE_DIR/pi-reap-idle.disabled"
FENCE_TOLERANCE_SECONDS=3

MODE=unknown
LIST_ONLY=0
PROBE_FILES=()

usage() {
    cat <<EOF
$SCRIPT_NAME — reap provably-idle interactive pi REPL sessions ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--idle-hours N] [--list]
               [--probe-jsonl FILE...] [--help]

  (no mode flag)   dry-run: classify + report, send NO signals (default)
  --dry-run        explicit dry-run
  --apply          armed one-shot pass (or env REAP_DRY_RUN=0)
  --idle-hours N   threshold override (env REAP_IDLE_HOURS)
  --list           list tty'd pi candidate pids and exit (no store read)
  --probe-jsonl F  probe pi session JSONL file(s) (ground-truth parser check;
                   prints {"path","last_timestamp","idle_proven","reason"}
                   per file) and exit
  --help           this text

Fail-closed: absent/unparseable JSONL never proves idle; a missing/corrupt
cmux store WITH candidates aborts (exit 3) after one retry. Zero tty'd pi
candidates skip the store read entirely and still write a MODE= footer.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "$*"; }
log() { printf '%s\n' "$*" >>"$REAP_LOG"; }

now_epoch() {
    if [ -n "${REAP_NOW_EPOCH:-}" ]; then printf '%s\n' "$REAP_NOW_EPOCH"; return 0; fi
    /bin/date +%s 2>/dev/null || date +%s
}

# date_bin_probe_mode — capability-probe ${DATE_BIN} (never uname): feed a
# BSD-shaped invocation; exit 0 => BSD -j branch, else GNU -d branch. A
# macOS-shape-only stub therefore forces the BSD branch on ANY platform.
DATE_MODE=""
date_bin_probe_mode() {
    if [ -n "$DATE_MODE" ]; then printf '%s\n' "$DATE_MODE"; return 0; fi
    if LC_ALL=C "$DATE_BIN" -j -f '%a %b %e %H:%M:%S %Y' 'Sat Jan  1 00:00:00 2000' +%s >/dev/null 2>&1; then
        DATE_MODE=bsd
    else
        DATE_MODE=gnu
    fi
    printf '%s\n' "$DATE_MODE"
}

# lstart_to_epoch <ps-lstart-str> — "Sat Sep  5 12:34:56 2026" OR the
# real macOS ps day-first order "Sat  5 Sep 12:34:56 2026" -> epoch.
# Both orders are attempted on the BSD branch (ps lstart has shipped both).
lstart_to_epoch() {
    local lstart="$1" mode fmt e
    mode="$(date_bin_probe_mode)"
    if [ "$mode" = bsd ]; then
        for fmt in '%a %b %e %H:%M:%S %Y' '%a %e %b %H:%M:%S %Y'; do
            e="$(LC_ALL=C "$DATE_BIN" -j -f "$fmt" "$lstart" +%s 2>/dev/null)"
            if [ -n "$e" ] && [ "$e" -gt 0 ] 2>/dev/null; then printf '%s\n' "$e"; return 0; fi
        done
        echo 0
    else
        LC_ALL=C "$DATE_BIN" -d "$lstart" +%s 2>/dev/null || echo 0
    fi
}

# ── pass 1: ps enumeration (single-pass awk — NO per-row subprocesses) ─
# Retained full table "$PS_TABLE": "pid ppid pgid tty stat rss command [CAND]" —
# WALKS-ONLY invariant: the snapshot serves ancestor/descendant walks; all
# lstart/pgid/stat/rss classification and settle values come from FRESH
# per-pid detail probes (a static table cannot observe pid-reuse). Trailing
# CAND marks tty'd pi candidates via the argv classifier (runner basename
# pi, path /pi, or node-launched with a pi argv token). An 814-row real ps
# table previously cost ~65s+ in per-row awk spawns; one awk pass over the
# raw dump makes enumeration ~2 subprocesses total.
PS_TABLE=""
CANDIDATES=""  # newline-separated candidate pids (tty'd + pi-argv)

ps_enumeration() {
    local raw
    PS_TABLE="$(mktemp "${TMPDIR:-/tmp}/pi-reap-ps.XXXXXX")"
    # Pinned bulk contract carries lstart (documented) but rows are parsed by
    # token scan (4-digit year token => stat/rss/command follow) so spacey
    # command columns never shift the parse.
    { "$PS_BIN" -axo pid=,ppid=,pgid=,tty=,lstart=,stat=,rss=,command= 2>/dev/null || true; } \
        | sed 's/^ *//' >"$PS_TABLE.raw"
    awk '{
        pid=$1; ppid=$2; pgid=$3; tty=$4
        if (pid !~ /^[0-9]+$/ || pid+0 <= 0) next
        yr=0
        for (i=5;i<=NF;i++) { if ($i ~ /^[0-9]{4}$/) { yr=i; break } }
        stat=""; rss="0"; cmd=""; cand=0
        if (yr > 0) {
            stat=$(yr+1); rss=$(yr+2)
            for (j=yr+3;j<=NF;j++) cmd=cmd " " $j
            sub(/^ /, "", cmd)
            if (tty ~ /^ttys/) {
                base=$(yr+3); sub(/^.*\//, "", base)
                if (base == "pi") cand=1
                else if ($(yr+3) ~ /\/pi$/) cand=1
                else if (base == "node" || base == "nodejs") {
                    for (j=yr+3;j<=NF;j++) { if ($j == "pi" || $j ~ /\/pi$/) { cand=1; break } }
                }
            }
        }
        printf "%s %s %s %s %s %s %s", pid, ppid, pgid, tty, stat, rss, cmd
        if (cand) printf " CAND"
        printf "\n"
    }' "$PS_TABLE.raw" >"$PS_TABLE"
    rm -f "$PS_TABLE.raw"
    CANDIDATES="$(awk '$NF=="CAND" {print $1}' "$PS_TABLE")"
}

self_pid="$$"
SELF_TTY=""
SELF_ANCESTORS=""

self_ancestors_from_table() {
    local pid="$self_pid" ppid depth=0
    SELF_TTY="$(awk -v p="$pid" '$1==p {print $4}' "$PS_TABLE" | head -1)"
    SELF_ANCESTORS=""
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
        ppid="$(awk -v p="$pid" '$1==p {print $2}' "$PS_TABLE" | head -1)"
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        SELF_ANCESTORS="$(printf '%s\n%s' "$SELF_ANCESTORS" "$ppid" | sed '/^$/d')"
        pid="$ppid"; depth=$((depth+1))
    done
}

# is_self_like <pid>: reaper's own pid, own tty, or own ancestor chain.
is_self_like() {
    local pid="$1" t
    [ "$pid" = "$self_pid" ] && return 0
    if [ -n "$SELF_TTY" ]; then
        t="$(awk -v p="$pid" '$1==p {print $4}' "$PS_TABLE" | head -1)"
        [ "$t" = "$SELF_TTY" ] && return 0
    fi
    printf '%s\n' "$SELF_ANCESTORS" | grep -qx "$pid" && return 0
    return 1
}

# has_live_pi_descendant <pid>: precomputed-map lookup (marathon skip).
# One python pass over PS_TABLE computes, for every pid, whether a live
# (non-zombie) pi process is reachable as a descendant; classify then greps
# instead of walking the process tree per candidate (O(candidates x tree)
# awk spawns took minutes on the real 814-row table). Zombie descendants
# (STAT Z*) neither propagate nor count as the pi descendant.
DESC_MAP=""

descendant_map_build() {
    DESC_MAP="$(mktemp "${TMPDIR:-/tmp}/pi-reap-desc.XXXXXX")"
    python3 - "$PS_TABLE" "$DESC_MAP" <<'PYEOF'
import sys

ps_table, out_path = sys.argv[1], sys.argv[2]
parent = {}
has = {}
for ln in open(ps_table, encoding="utf-8"):
    f = ln.split()
    if len(f) < 6:
        continue
    pid, ppid = int(f[0]), int(f[1])
    stat = f[4]
    cand = (len(f) > 7 and f[-1] == "CAND" and not stat.startswith("Z"))
    parent[pid] = ppid
    has[pid] = False
    if cand:
        cur = parent.get(pid)
        hops = 0
        while cur in has and hops < 256:
            if has[cur]:
                break
            has[cur] = True
            cur = parent.get(cur)
            hops += 1

with open(out_path, "w", encoding="utf-8") as out:
    for pid in sorted(has):
        out.write("%s %s\n" % (pid, "1" if has[pid] else "0"))
PYEOF
}

has_live_pi_descendant() {
    [ -s "$DESC_MAP" ] || return 1
    awk -v p="$1" '$1==p { if ($2=="1") exit 0; exit 1 }' "$DESC_MAP"
    return $?
}


# ── pass 2: cmux store read (fail-closed; retry-once handled by caller) ─
# TSV rows: pid<TAB>pidStartSeconds<TAB>pidStartMicroseconds<TAB>
# agentLifecycle<TAB>runtimeStatus<TAB>sessionId<TAB>cwd
STORE_TSV=""
store_read() { # 0 on success; 3 on missing/corrupt (python exit)
    STORE_TSV="$(mktemp "${TMPDIR:-/tmp}/pi-reap-store.XXXXXX")"
    python3 - "$CMUX_STORE" "$STORE_TSV" <<'PYEOF'
import json, sys

store_path, out_path = sys.argv[1], sys.argv[2]
with open(store_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    sys.exit(3)
# Live pi-hook store nests sessions under {"sessions": {...}} with top-level
# version/agentHookFailureReportTimestamps; accept a flat keyed-by-sid shape
# too (older/alternative writers, tests).
sessions = data.get("sessions")
if isinstance(sessions, dict):
    data = sessions
rows = []
def esc(v):
    if v is None:
        return ""
    return str(v).replace("\t", " ").replace("\n", " ")
for sid, rec in data.items():
    if not isinstance(rec, dict) or rec.get("pid") is None:
        continue
    rows.append("\t".join([
        esc(rec["pid"]),
        esc(rec.get("pidStartSeconds", "")),
        esc(rec.get("pidStartMicroseconds", "")),
        esc(rec.get("agentLifecycle", "")),
        esc(rec.get("runtimeStatus", "")),
        esc(sid),
        esc(rec.get("cwd", "")),
    ]))
with open(out_path, "w", encoding="utf-8") as out:
    out.write("\n".join(rows) + ("\n" if rows else ""))
PYEOF
}

store_records_for_pid() { # <pid> -> matching TSV lines ("" when none)
    grep -E "^${1}	" "$STORE_TSV" 2>/dev/null || true
}

# ── pass 3: JSONL ground truth (inline python, reverse tail scan) ──────
# probe_jsonl <file...> -> stdout one JSON line per input:
# {"path":..., "last_timestamp":<int epoch>|null, "idle_proven":bool, "reason":...}
probe_jsonl() {
    [ $# -gt 0 ] || return 0
    python3 - "$@" <<'PYEOF'
import datetime, json, sys

def parse_ts(ts):
    if ts is None:
        return None
    if isinstance(ts, (int, float)):
        return int(ts)
    if isinstance(ts, str):
        s = ts.strip()
        if not s:
            return None
        try:
            if s[-1] in "Zz":
                s = s[:-1] + "+00:00"
            dt = datetime.datetime.fromisoformat(s)
            return int(dt.timestamp())
        except Exception:
            return None
    return None

def last_entry(path):
    try:
        fh = open(path, "rb")
    except OSError:
        return None, "missing"
    try:
        fh.seek(0, 2)
        size = fh.tell()
        if size == 0:
            return None, "empty"
        # Read the tail (up to 768KB; giant ~149KB lines need ~2x headroom).
        read_len = min(786432, size)
        fh.seek(size - read_len)
        chunk = fh.read(read_len).decode("utf-8", "replace")
        # Iterate complete-looking lines from the END. A trailing partial
        # write (no newline, truncated JSON) fails json.loads and is skipped;
        # a complete line lacking a trailing newline is legitimately parseable.
        lines = [ln for ln in chunk.split("\n")]
        for raw in reversed(lines):
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                # torn / partial trailing write — keep scanning older lines
                continue
            ep = parse_ts(obj.get("timestamp"))
            if ep is None:
                # newest COMPLETE line is undatable — a write we cannot age;
                # fail-closed: abstain rather than date the session by an
                # older entry (policy: missing/unparseable => never idle).
                return None, "unparseable"
            return ep, "ok"
        return None, "unparseable"
    finally:
        fh.close()

for path in sys.argv[1:]:
    ep, reason = last_entry(path)
    print(json.dumps({"path": path, "last_timestamp": ep,
                      "idle_proven": reason == "ok", "reason": reason}))
PYEOF
}

# jsonl_epoch_for <session file> -> last-entry epoch ("" when no proof).
jsonl_epoch_for() {
    local f="$1" out
    [ -s "$f" ] || { echo ""; return 0; }
    out="$(probe_jsonl "$f" 2>/dev/null | head -1 | python3 -c '
import json,sys
line=sys.stdin.readline().strip()
if not line: sys.exit(0)
try:
    d=json.loads(line); print(d["last_timestamp"] if d.get("idle_proven") else "")
except Exception: pass
')"
    printf '%s\n' "$out"
}

# ── pass 4: classification ─────────────────────────────────────────────
# reap-eligible rows -> REAP_CANDIDATES:
#   pid|pgid|rss|sessionId|jsonl|idle_h|class_last_epoch|class_lstart
REAP_CANDIDATES=""
REAP_COUNT=0

candidate_detail() { # <pid> -> "lstart_epoch pgid stat rss" via FRESH probe
    local pid="$1" line lstart epoch pgid stat rss
    line="$("$PS_BIN" -o lstart=,pgid=,stat=,rss= -p "$pid" 2>/dev/null | sed 's/^ *//')"
    [ -n "$line" ] || return 1
    # ps row: lstart-tokens...(incl. 4-digit year) pgid stat rss; the year is
    # the LAST lstart token and MUST stay in the string for date parsing.
    lstart="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]{4}$/){for(j=1;j<=i;j++){printf "%s ", $j}; exit}}}' | sed 's/ $//')"
    epoch="$(lstart_to_epoch "$lstart")"
    pgid="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]{4}$/){print $(i+1); exit}}}')"
    stat="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]{4}$/){print $(i+2); exit}}}')"
    rss="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]{4}$/){print $(i+3); exit}}}')"
    [ -n "$epoch" ] || return 1
    printf '%s %s %s %s\n' "$epoch" "$pgid" "$stat" "${rss:-0}"
}

session_file_for() { # <sessionId> <cwd> -> first matching JSONL ("" if none)
    local sid="$1" cwd="$2" enc dir hit
    enc="$(printf '%s' "$cwd" | sed 's|^/||; s|/|-|g')"
    dir="$PI_SESSIONS_DIR/--${enc}--"
    if [ -d "$dir" ]; then
        hit="$(find "$dir" -maxdepth 1 \( -name "*_${sid}*.jsonl" -o -name "*${sid}*.jsonl" \) 2>/dev/null | head -1)"
        [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
    fi
    hit="$(find "$PI_SESSIONS_DIR" -name "*${sid}*.jsonl" -type f 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s\n' "$hit"
}

# classify_candidates <now> <emit:1|0> — fills REAP_CANDIDATES/REAP_COUNT.
# emit=1 prints + logs per-candidate verdict rows; emit=0 is the RESIDUAL
# re-classification sweep (silent).
classify_candidates() {
    local now="$1" emit="$2" pid detail epoch pgid stat rss tty rec al rs sid cwd sfile
    local last_epoch youngest vote abstain matched_cnt veto diff sid_marker rec_pss
    REAP_CANDIDATES=""; REAP_COUNT=0
    if [ -z "$CANDIDATES" ]; then
        [ "$emit" = 1 ] && say "(no tty'd pi candidates)"
        return 0
    fi
    for pid in $CANDIDATES; do
        [ -n "$pid" ] || continue
        tty="$(awk -v p="$pid" '$1==p {print $4}' "$PS_TABLE" | head -1)"
        if is_self_like "$pid"; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP self-tty/ancestor (never reap the running session)"
            continue
        fi
        if has_live_pi_descendant "$pid"; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP orchestrating (live non-zombie pi descendant)"
            continue
        fi
        detail="$(candidate_detail "$pid")" || { [ "$emit" = 1 ] && say "$pid tty=$tty SKIP gone (no fresh ps row)"; continue; }
        epoch="$(printf '%s' "$detail" | awk '{print $1}')"
        pgid="$(printf '%s' "$detail" | awk '{print $2}')"
        stat="$(printf '%s' "$detail" | awk '{print $3}')"
        rss="$(printf '%s' "$detail" | awk '{print $4}')"
        case "$stat" in Z*) continue ;; esac
        # own-session veto (PI_SESSION_ID hard gate)
        if [ -n "${PI_SESSION_ID:-}" ]; then
            if printf '%s\n' "$(store_records_for_pid "$pid")" | grep -qE "	${PI_SESSION_ID}(\t|$)"; then
                [ "$emit" = 1 ] && say "$pid tty=$tty SKIP own-session (PI_SESSION_ID match)"
                continue
            fi
        fi
        # incarnation fence + ALLOWLIST union veto over MATCHED records only
        matched=""; veto=""; matched_cnt=0; abstain=0
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            rec_pss="$(printf '%s' "$rec" | awk -F'\t' '{print $2}')"
            if [ -z "$rec_pss" ]; then abstain=$((abstain+1)); continue; fi
            diff=$(( epoch - rec_pss )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            [ "$diff" -gt "$FENCE_TOLERANCE_SECONDS" ] && continue  # stale sibling: no vote
            matched_cnt=$((matched_cnt+1))
            matched="$(printf '%s\n%s' "$matched" "$rec" | sed '/^$/d')"
            al="$(printf '%s' "$rec" | awk -F'\t' '{print $4}')"
            rs="$(printf '%s' "$rec" | awk -F'\t' '{print $5}')"
            if [ "$al" != "idle" ] || [ "$rs" != "idle" ]; then
                veto="allowlist lifecycle=${al:-None} runtimeStatus=${rs:-None}"
            fi
        done <<<"$(store_records_for_pid "$pid")"
        if [ "$matched_cnt" -eq 0 ]; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP incarnation-unmatched (fence ±${FENCE_TOLERANCE_SECONDS}s; ${abstain} no-pidStartSeconds abstain(s))"
            continue
        fi
        if [ -n "$veto" ]; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP $veto (any non-idle twin vetoes)"
            continue
        fi
        # JSONL idle proof: youngest voting matched record wins; no-JSONL
        # records abstain (prove nothing AND veto nothing).
        youngest=""; vote=0; sid=""; sfile=""
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            rsid="$(printf '%s' "$rec" | awk -F'\t' '{print $6}')"
            rcwd="$(printf '%s' "$rec" | awk -F'\t' '{print $7}')"
            rf="$(session_file_for "$rsid" "$rcwd")"
            if [ -z "$rf" ] || [ ! -s "$rf" ]; then abstain=$((abstain+1)); continue; fi
            le="$(jsonl_epoch_for "$rf")"
            if [ -z "$le" ]; then abstain=$((abstain+1)); continue; fi
            vote=$((vote+1))
            # sid/sfile stay in lockstep with the MAX-epoch (age-setting)
            # record — settle-3 re-probes exactly the file that decided
            # eligibility, never a younger sibling.
            if [ -z "$youngest" ] || [ "$le" -gt "$youngest" ]; then
                youngest="$le"; sid="$rsid"; sfile="$rf"
            fi
        done <<<"$matched"
        if [ "$vote" -eq 0 ]; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP no-jsonl-proof (${abstain} abstain(s) — fail-closed)"
            continue
        fi
        idle_age_h="$(awk -v n="$now" -v y="$youngest" 'BEGIN{printf "%.1f", (n-y)/3600}')"
        if awk -v n="$now" -v y="$youngest" -v t="$REAP_IDLE_HOURS" 'BEGIN{exit !((n-y)/3600 > t)}'; then
            REAP_CANDIDATES="$(printf '%s\n%s' "$REAP_CANDIDATES" "$pid|$pgid|${rss:-0}|$sid|$sfile|$idle_age_h|$youngest|$epoch" | sed '/^$/d')"
            [ "$emit" = 1 ] && say "$pid tty=$tty REAP-ELIGIBLE rss=${rss:-0} idle_h=${idle_age_h}h session=$sid jsonl=$sfile"
        else
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP active (idle_h=${idle_age_h}h ≤ threshold ${REAP_IDLE_HOURS}h)"
        fi
    done
    REAP_COUNT=0
    [ -n "$REAP_CANDIDATES" ] && REAP_COUNT="$(printf '%s\n' "$REAP_CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"
}

# ── kill pass ──────────────────────────────────────────────────────────
KILLED=0
YIELD_RSS=0

signal_target() { # <pid> <pgid> <TERM|KILL> — group signal when pgid==pid else per-pid
    local pid="$1" pgid="$2" sig="$3"
    if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
        "$KILL_BIN" "-${sig}" "-${pgid}" 2>/dev/null
    else
        "$KILL_BIN" "-${sig}" "$pid" 2>/dev/null
    fi
}

reap_one() { # <cand-line> <now>
    local cand="$1" now="$2"
    local pid pgid rss sid sfile idle_h class_epoch class_lstart
    local detail epoch2 pgid2 sfile2 fresh_epoch
    pid="$(printf '%s' "$cand" | cut -d'|' -f1)"
    pgid="$(printf '%s' "$cand" | cut -d'|' -f2)"
    rss="$(printf '%s' "$cand" | cut -d'|' -f3)"
    sid="$(printf '%s' "$cand" | cut -d'|' -f4)"
    sfile="$(printf '%s' "$cand" | cut -d'|' -f5)"
    idle_h="$(printf '%s' "$cand" | cut -d'|' -f6)"
    class_epoch="$(printf '%s' "$cand" | cut -d'|' -f7)"
    class_lstart="$(printf '%s' "$cand" | cut -d'|' -f8)"
    # fail-closed: a corrupted candidate row (store value containing the
    # unescaped field separator, etc.) must SUPPRESS, never proceed.
    case "$class_epoch" in
        ''|*[!0-9]*) log "SETTLE-SKIP $pid corrupt cand class_epoch — suppress"; return 0 ;;
    esac
    case "$class_lstart" in
        ''|*[!0-9]*) log "SETTLE-SKIP $pid corrupt cand class_lstart — suppress"; return 0 ;;
    esac
    # settle 1: still self/ancestor?
    is_self_like "$pid" && { log "SETTLE-SKIP $pid now-self — suppress"; return 0; }
    # settle 2: FRESH probe — lstart changed (pid died + reused)?
    detail="$(candidate_detail "$pid")" || { log "SETTLE-SKIP $pid gone (ESRCH at settle) — suppress"; return 0; }
    epoch2="$(printf '%s' "$detail" | awk '{print $1}')"
    pgid2="$(printf '%s' "$detail" | awk '{print $2}')"
    if [ -n "$class_lstart" ] && [ -n "$epoch2" ] && [ "$epoch2" != "$class_lstart" ]; then
        log "SETTLE-SKIP $pid incarnation changed (pid reused) — suppress"
        return 0
    fi
    # settle 3: JSONL activity advanced since classification?
    fresh_epoch="$(jsonl_epoch_for "$sfile")"
    if [ -n "$class_epoch" ] && [ -n "$fresh_epoch" ] && [ "$fresh_epoch" -gt "$class_epoch" ]; then
        log "SETTLE-SKIP $pid activity advanced (jsonl ${class_epoch} -> ${fresh_epoch}) — suppress"
        return 0
    fi
    signal_target "$pid" "$pgid2" TERM
    log "SIGNAL pid=$pid pgid=$pgid2 SIGTERM rss=${rss:-0} idle_h=${idle_h}h session=$sid jsonl=$sfile"
    sleep "$REAP_GRACE_SECONDS"
    # survivor re-check = fresh probe (kill -0 would ESRCH on fake pids).
    # The same incarnation fence applies BEFORE SIGKILL: if the pid was
    # recycled during the grace window the fresh lstart differs from
    # class_lstart and the group is NOT provably the reaped session —
    # suppress the KILL (the TERM already achieved the reap). Zombie rows
    # are skipped too (TERM landed; the parent has not reaped yet).
    if detail="$(candidate_detail "$pid")"; then
        epoch3="$(printf '%s' "$detail" | awk '{print $1}')"
        pgid3="$(printf '%s' "$detail" | awk '{print $2}')"
        stat3="$(printf '%s' "$detail" | awk '{print $3}')"
        if [ -n "$class_lstart" ] && [ -n "$epoch3" ] && [ "$epoch3" != "$class_lstart" ]; then
            log "SETTLE-SKIP $pid pid reused after TERM (lstart ${class_lstart} -> ${epoch3}) — no SIGKILL"
            KILLED=$((KILLED+1)); YIELD_RSS=$((YIELD_RSS + ${rss:-0}))
            return 0
        fi
        case "$stat3" in
            Z*) log "SIGNAL pid=$pid SIGKILL skipped (zombie after TERM)"
                KILLED=$((KILLED+1)); YIELD_RSS=$((YIELD_RSS + ${rss:-0}))
                return 0 ;;
        esac
        signal_target "$pid" "$pgid3" KILL
        log "SIGNAL pid=$pid pgid=$pgid3 SIGKILL (survived TERM)"
    fi
    KILLED=$((KILLED+1))
    YIELD_RSS=$((YIELD_RSS + ${rss:-0}))
}

# ── mkdir-lock (macOS has no flock) ────────────────────────────────────
LOCK_HELD=0
lock_acquire() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ -d "$LOCK_DIR" ]; then
        local owner="" age=0 now="" started=""
        owner="$(cat "$LOCK_DIR/owner" 2>/dev/null)"
        started="$(cat "$LOCK_DIR/started" 2>/dev/null)"
        now="$(now_epoch)"
        if [ -n "$started" ] && [ -n "$now" ]; then age=$(( now - started )); fi
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$age" -lt "$REAP_LOCK_STALE_SECONDS" ]; then
            log "LOCK held by live pid $owner (age ${age}s) — abort"
            return 1
        fi
        log "LOCK stale (owner=${owner:-?} age=${age}s) — breaking"
        rm -rf "$LOCK_DIR"
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "LOCK raced — abort"
        return 1
    fi
    printf '%s\n' "$$" >"$LOCK_DIR/owner"
    printf '%s\n' "$(now_epoch)" >"$LOCK_DIR/started"
    LOCK_HELD=1
    return 0
}
lock_release() {
    [ "$LOCK_HELD" = 1 ] || return 0
    rm -rf "$LOCK_DIR"
    LOCK_HELD=0
}

# ── main ───────────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) MODE=dry-run; shift ;;
            --apply) MODE=apply; shift ;;
            --list) LIST_ONLY=1; shift ;;
            --idle-hours) REAP_IDLE_HOURS="${2:-}"; shift 2 ;;
            --probe-jsonl) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do PROBE_FILES+=("$1"); shift; done ;;
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
}

post_count=0
pre_count=0
residual_count=0

run() {
    local now
    if [ "$MODE" = unknown ]; then
        if [ "${REAP_DRY_RUN:-1}" = "0" ]; then MODE=apply; else MODE=dry-run; fi
    fi
    case "$MODE" in dry-run|apply) ;; *) usage >&2; exit 2 ;; esac
    printf '%s' "$REAP_IDLE_HOURS" | grep -qE '^[0-9]+$' || { echo "bad --idle-hours: $REAP_IDLE_HOURS" >&2; exit 2; }
    mkdir -p "$(dirname "$REAP_LOG")" 2>/dev/null || true
    now="$(now_epoch)"

    if [ ${#PROBE_FILES[@]} -gt 0 ]; then
        probe_jsonl "${PROBE_FILES[@]}"
        exit 0
    fi

    if ! lock_acquire; then
        log "FAIL-CLOSED abort: lock (exit 3)"
        exit 3
    fi
    trap 'rm -f "$PS_TABLE" "$STORE_TSV" "$DESC_MAP"; lock_release' EXIT
    # log size guard: keep last ~200 lines. Truncation temp is mktemp'd in
    # the log's own directory (never a predictable sibling name — a local
    # attacker could pre-seed a symlink at a fixed path).
    mkdir -p "${REAP_LOG%/*}" 2>/dev/null || true
    if [ -f "$REAP_LOG" ]; then
        trunc="$(mktemp "${REAP_LOG%/*}/pi-reap-log-trunc.XXXXXX" 2>/dev/null)" || trunc=""
        if [ -n "$trunc" ]; then
            tail -n 200 "$REAP_LOG" >"$trunc" 2>/dev/null && mv "$trunc" "$REAP_LOG" 2>/dev/null || rm -f "$trunc"
        fi
    fi

    if [ -f "$DISABLED_SENTINEL" ]; then
        log "MODE=disabled NOW=$now THRESHOLD=$REAP_IDLE_HOURS sentinel=$DISABLED_SENTINEL KILLED=0 YIELD=0"
        echo "disabled by sentinel ($DISABLED_SENTINEL) — exiting without signal"
        exit 0
    fi
    log "==== pi-reap-idle pass: MODE=$MODE THRESHOLD=$REAP_IDLE_HOURS now=$now ===="
    ps_enumeration
    self_ancestors_from_table
    descendant_map_build
    pre_count="$(printf '%s\n' "$CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [ "$LIST_ONLY" = 1 ]; then
        printf '%s\n' "$CANDIDATES" | sed '/^$/d'
        exit 0
    fi

    # candidates==0 => skip the store read entirely (fail-closed abort only
    # when candidates exist); still write the MODE= footer (job proof).
    if [ -n "$CANDIDATES" ]; then
        if ! store_read; then
            log "STORE read failed (attempt 1) — retrying once"
            sleep 1
            if ! store_read; then
                log "FAIL-CLOSED abort: cmux store missing/corrupt (attempt 2, exit 3)"
                log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS CANDIDATES=$pre_count KILLED=0 YIELD=0"
                exit 3
            fi
        fi
        classify_candidates "$now" 1
    else
        say "(no tty'd pi candidates — store read skipped)"
    fi

    if [ "$MODE" = apply ] && [ -n "$REAP_CANDIDATES" ]; then
        local cand_line
        while IFS= read -r cand_line; do
            [ -n "$cand_line" ] || continue
            reap_one "$cand_line" "$now"
        done <<<"$REAP_CANDIDATES"
    fi

    # POST + RESIDUAL from a FRESH post-pass read (walks-only invariant):
    # armed — killed pids are gone => RESIDUAL=0 by construction; dry-run —
    # nothing killed => RESIDUAL = the would-be-reaped count.
    ps_enumeration
    self_ancestors_from_table
    descendant_map_build
    post_count="$(printf '%s\n' "$CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"
    residual_count=0
    if [ "$MODE" = apply ]; then
        if [ -n "$CANDIDATES" ]; then
            classify_candidates "$now" 0
            residual_count="$REAP_COUNT"
        fi
    else
        residual_count="$REAP_COUNT"
    fi

    if [ "$MODE" = dry-run ]; then
        say "DRY-RUN — no signals sent"
    fi
    log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS CANDIDATES=$pre_count PRE=$pre_count POST=$post_count RESIDUAL=$residual_count KILLED=$KILLED YIELD=$YIELD_RSS"
    if [ "$MODE" = apply ]; then
        echo "armed pass complete: KILLED=$KILLED YIELD_RSS=${YIELD_RSS}KB RESIDUAL=$residual_count"
    fi
    exit 0
}

parse_args "$@"
run
