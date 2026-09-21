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
#   * BOUNDED VETO (#947): a non-idle cmux record only vetoes while it is
#     FRESH. cmux derives agentLifecycle from hook events (a prompt turn
#     started; a turn-complete has not arrived), so a lost/never-sent
#     turn-complete leaves lifecycle=running FOREVER — an unbounded veto
#     would immunise that pid permanently, however long its JSONL sits
#     untouched (live: 45/47 candidates vetoed, 38 of them
#     lifecycle=running). A non-idle record whose OWN updatedAt is older
#     than REAP_STUCK_HOURS (default 3x REAP_IDLE_HOURS) is therefore no
#     longer current evidence: the pid is classified STUCK. STUCK is
#     REPORTED loudly and is NEVER signaled unless REAP_REAP_STUCK=1 arms
#     it — and even then it must satisfy: JSONL ground truth past
#     REAP_STUCK_HOURS, EVERY matched record stale past the bound (any
#     fresh OR updatedAt-less record keeps the veto — fail closed), a
#     sleeping process (stat S/I — never R/T/D), and NO live non-zombie
#     child process (a tool call in flight). The JSONL proof is computed
#     BEFORE the veto so the stuck population is never invisible.
#   * Incarnation fence: record pidStartSeconds within ±3s of the ps lstart
#     (second-granularity rounding differs up to ~1s in live data).
#   * Never kill active work: settle re-verify BEFORE each signal uses a
#     FRESH per-pid ps probe (lstart changed => pid died+reused => suppress),
#     a FRESH JSONL re-probe (activity advanced => suppress), and — for STUCK
#     rows — a FRESH ps enumeration (a tool child spawned since classify
#     suppresses, since the pass-start map cannot see it) plus a FRESH store
#     re-read: their deciding record must still exist and still be non-idle,
#     and EVERY non-idle record for the pid must still carry a valid stale
#     stamp (classify's union, mirrored), with the union of every matched
#     record's JSONL file re-probed. Stuck rows also require stat S/I at
#     settle.
#     Post-TERM survivor re-check = the same fresh probe (kill -0 is never
#     the oracle).
#   * UNTRUSTED store values never reach arithmetic: `store_number_ok` gates
#     every store-derived number, because bash `$(( ))` re-parses an operand
#     as an ARITHMETIC EXPRESSION (a crafted `pidStartSeconds` is a
#     code-execution vector, not merely a parse risk). A `ps`/parser that
#     FAILED is a fail-closed abort (exit 3), never a healthy "no candidates"
#     pass — and `--list` reports the failure instead of printing an empty
#     list.
#   * Never touch another session's checkout: own tty / own ancestor pids /
#     own PI_SESSION_ID are hard skips. Orchestrating marathons (a live
#     non-zombie pi descendant) are skipped.
#   * Candidate-ancestry gate 3 (#1207) — ADDITIVE, it can only REFUSE, never
#     authorize. Every live candidate is classified by the FIRST RECOGNISED
#     HOST APP anywhere in its chain (recorded decision, option A):
#     `Terminal`/`Terminal.app`/`iTerm`/`iTerm.app` => human-terminal (never
#     signal); `cmux`/`cmux.app` => cmux-rooted, the fleet's own workspace
#     host, but STILL report-only — who spawned a cmux pane is recorded
#     nowhere on this box, so the owner's own interactive pane is
#     indistinguishable from a fleet lane; unrecognised / unresolvable /
#     empty => unknown (never signal, fail closed). Under this decision the
#     reaper's harvest for its candidate population is ZERO, which is the
#     INTENDED state — the report says so in words so a reader does not
#     conclude the reaper is broken. The chain walk is precomputed once per
#     pass from the ps snapshot (one class per pid, same shape as DESC_MAP)
#     and re-asked at the signal point; a failed/empty/unreadable map
#     classifies `unknown`, which refuses.
#   * Bash 3.2-safe only (macOS /bin/bash = 3.2.57): no declare -A /
#     mapfile / ${var,,} — bash 5.x on ubuntu CI would mask 4-only code.
#     Signals always go through ${KILL_BIN} (never the bare builtin).
#   * Version sensitivity: pi/cmux session shapes may drift — see the policy
#     doc. Interactive default is dry-run (warn-first); the MODE= footer
#     makes armed vs dry passes legible in the log.
#
# Usage:
#   pi-reap-idle.sh [--dry-run] [--apply] [--idle-hours N]
#                   [--stuck-hours N] [--reap-stuck] [--list]
#                   [--probe-jsonl FILE...] [--help]
# Env seams: PS_BIN KILL_BIN DATE_BIN CMUX_STATE_DIR PI_SESSIONS_DIR
#   PID_IDENTITY_LIB (the shared identity rule, #1178 — default: lib/
#   pid-identity.sh beside this script)
#   REAP_IDLE_HOURS REAP_STUCK_HOURS REAP_REAP_STUCK REAP_DRY_RUN
#   REAP_GRACE_SECONDS REAP_NOW_EPOCH REAP_LOCK_STALE_SECONDS REAP_LOG
#   REAP_MAX_HOURS (upper sanity bound for an explicitly supplied hour
#   threshold; the raw pre-normalization range check is meaningless without it).
#   The derived stuck bound (3x idle) is positivity-checked after the multiply
#   instead, so a 64-bit wrap cannot make it negative.
#   (default $HOME/.pi/agent/state/pi-reap-idle.log).
# Exit codes: 0 completed passes, 2 usage, 3 fail-closed (store / lock /
#            log-unwritable / ps-enumeration / descendant-map — see the
#            FAIL-CLOSED aborts in run()).

set -uo pipefail

SCRIPT_NAME="pi-reap-idle.sh"
ISSUE_REF="#469"
REAP_LOG="${REAP_LOG:-${HOME:-}/.pi/agent/state/pi-reap-idle.log}"
PS_BIN="${PS_BIN:-/bin/ps}"
KILL_BIN="${KILL_BIN:-/bin/kill}"
DATE_BIN="${DATE_BIN:-/bin/date}"
CMUX_STATE_DIR="${CMUX_STATE_DIR:-${HOME:-}/.cmuxterm}"
CMUX_STORE="$CMUX_STATE_DIR/pi-hook-sessions.json"
PI_SESSIONS_DIR="${PI_SESSIONS_DIR:-${HOME:-}/.pi/agent/sessions}"
REAP_IDLE_HOURS="${REAP_IDLE_HOURS:-24}"
# Bounded-veto freshness bound (#947). Empty => 3x REAP_IDLE_HOURS, resolved
# in run() AFTER the threshold is final (so --idle-hours moves it too).
REAP_STUCK_HOURS="${REAP_STUCK_HOURS:-}"
# 1 arms the stuck set for signaling; 0 (default) reports it only.
REAP_REAP_STUCK="${REAP_REAP_STUCK:-0}"
REAP_GRACE_SECONDS="${REAP_GRACE_SECONDS:-5}"
# Upper sanity bound for both hour thresholds. Also keeps `$(( 10#... ))`
# normalization from WRAPPING on a huge digit string (see run()).
REAP_MAX_HOURS="${REAP_MAX_HOURS:-1000000}"
# ...and it is itself an operator-settable env seam, so validate it before it
# guards anything: a non-numeric value would make the `-le` comparisons error
# and turn EVERY pass into an exit-2 (#947 review P2).
grep -qE '^[0-9]+$' <<<"$REAP_MAX_HOURS" && [ "$REAP_MAX_HOURS" -ge 1 ] \
    || { echo "bad REAP_MAX_HOURS: $REAP_MAX_HOURS (want a positive integer)" >&2; exit 2; }
REAP_MAX_HOURS=$(( 10#${REAP_MAX_HOURS} ))
REAP_LOCK_STALE_SECONDS="${REAP_LOCK_STALE_SECONDS:-1800}"
STATE_DIR="${HOME:-}/.pi/agent/state"
LOCK_DIR="$STATE_DIR/pi-reap-idle.lock"
# Disarm valve: touch $STATE_DIR/pi-reap-idle.disabled to make every pass
# (even --apply) log a MODE=disabled footer and exit 0 without signaling.
# Survives re-syncs that re-install the launchd job (#469).
DISABLED_SENTINEL="$STATE_DIR/pi-reap-idle.disabled"
# ── shared process-identity rule (#1178) ──────────────────────────────
# The incarnation fence, the zombie rule, the untrusted-store-number gate and
# the lstart parser live in ONE place (scripts/lib/pid-identity.sh) so this
# reaper and the fleet liveness classifier (tools/fleet/liveness.py, which
# shells that file's `probe` CLI) cannot drift into two identity opinions.
# Fail CLOSED if it is missing: without it this script cannot decide identity,
# and a silent continue would leave every candidate reading
# `incarnation-unmatched` — a reaper that reaps nothing while its footer looks
# healthy. (In-repo the file is a tracked sibling; the farm copies both.)
PID_IDENTITY_LIB="${PID_IDENTITY_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib/pid-identity.sh}"
if [ ! -f "$PID_IDENTITY_LIB" ]; then
    echo "FAIL-CLOSED abort: identity library missing ($PID_IDENTITY_LIB, exit 3)" >&2
    exit 3
fi
# shellcheck source=lib/pid-identity.sh
. "$PID_IDENTITY_LIB"

MODE=unknown
LIST_ONLY=0
PROBE_FILES=()

usage() {
    cat <<EOF
$SCRIPT_NAME — reap provably-idle interactive pi REPL sessions ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--idle-hours N] [--stuck-hours N]
               [--reap-stuck] [--list] [--probe-jsonl FILE...] [--help]

  (no mode flag)   dry-run: classify + report, send NO signals (default)
  --dry-run        explicit dry-run
  --apply          armed one-shot pass (or env REAP_DRY_RUN=0)
  --idle-hours N   threshold override (env REAP_IDLE_HOURS)
  --stuck-hours N  bounded-veto freshness bound for a non-idle cmux record
                   beyond which the pid is classified STUCK (env
                   REAP_STUCK_HOURS; default 3x the idle threshold)
  --reap-stuck     ARM the STUCK set for signaling (env REAP_REAP_STUCK=1).
                   Off by default: STUCK is reported, never killed.
  --list           list tty'd pi candidate pids and exit (no store read)
  --probe-jsonl F  probe pi session JSONL file(s) (ground-truth parser check;
                   prints {"path","last_timestamp","idle_proven","reason"}
                   per file) and exit
  --help           this text

Fail-closed: absent/unparseable JSONL never proves idle; a non-idle cmux
record only vetoes while fresh (updatedAt within REAP_STUCK_HOURS); a
missing/corrupt cmux store WITH candidates aborts (exit 3) after one retry.
Zero tty'd pi candidates skip the store read entirely and still write a
MODE= footer.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "$*"; }
log() { printf '%s\n' "$*" >>"$REAP_LOG"; }

now_epoch() {
    if [ -n "${REAP_NOW_EPOCH:-}" ]; then printf '%s\n' "$REAP_NOW_EPOCH"; return 0; fi
    /bin/date +%s 2>/dev/null || date +%s
}

# date_bin_probe_mode / lstart_to_epoch / FENCE_TOLERANCE_SECONDS live in
# scripts/lib/pid-identity.sh (sourced above, #1178) — one definition of the
# identity rule for the whole fleet.

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
PS_RC=0        # exit status of the bulk `ps` call (0 = enumeration ran)
post_ps_ok=1   # 0 => the post-pass enumeration failed (POST/RESIDUAL degraded)

ps_enumeration() {
    local raw ps_rc=0 awk_rc=0 cand_rc=0
    [ -n "${PS_TABLE:-}" ] && rm -f "$PS_TABLE" "$PS_TABLE.raw" 2>/dev/null
    # A failed mktemp must not fall through to the literal path ".raw" in the
    # cwd — treat it as an enumeration failure (PS_RC) like any other. Clear
    # CANDIDATES too: a failed enumeration must never leave the PREVIOUS
    # enumeration's candidate list in place for a (post-pass) consumer.
    PS_TABLE="$(mktemp "${TMPDIR:-/tmp}/pi-reap-ps.XXXXXX")" || { PS_TABLE=""; CANDIDATES=""; PS_RC=1; return 1; }
    # Pinned bulk contract carries lstart (documented) but rows are parsed by
    # token scan (4-digit year token => stat/rss/command follow) so spacey
    # command columns never shift the parse.
    # PI_REAP_SELF_PID is exported to the ps child so a shimmed PS_BIN can
    # stamp the reaper's own row deterministically (test harness; real ps
    # ignores it). In a pipeline subshell $$ is still the shell's own pid.
    # The rc is captured OUT of the pipeline (not `|| true`), and the braces
    # are redirected to the file rather than piped — `{ ...; rc=$?; } | cmd`
    # runs in a SUBSHELL and the assignment is lost (which is how the first
    # version of this guard silently read rc=0). A broken `ps` yields an empty
    # table that is otherwise indistinguishable from a genuinely idle machine:
    # exit 0, CANDIDATES=0, healthy-looking footer, forever. run() aborts on
    # that (#947 review P2). The awk below is whitespace-insensitive, so the
    # former `sed 's/^ *//'` pipe is not needed.
    { PI_REAP_SELF_PID="$$" "$PS_BIN" -axo pid=,ppid=,pgid=,tty=,lstart=,stat=,rss=,command= 2>/dev/null; ps_rc=$?; } \
        >"$PS_TABLE.raw"
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
    }' "$PS_TABLE.raw" >"$PS_TABLE" || awk_rc=$?
    rm -f "$PS_TABLE.raw"
    CANDIDATES="$(awk '$NF=="CAND" {print $1}' "$PS_TABLE")" || cand_rc=$?
    # Any leg of the enumeration failing (ps, the parser, the candidate scan)
    # makes the table untrustworthy in the SAME direction — an empty/truncated
    # table reads as "no live child", so the guard disappears. A nonzero rc in
    # a sibling command is not "ps succeeded" (#947 review P2).
    PS_RC=0
    if [ "$ps_rc" != 0 ]; then PS_RC="$ps_rc"
    elif [ "$awk_rc" != 0 ]; then PS_RC="$awk_rc"
    elif [ "$cand_rc" != 0 ]; then PS_RC="$cand_rc"
    fi
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
    grep -qx "$pid" <<<"$SELF_ANCESTORS" && return 0
    return 1
}

# has_live_pi_descendant <pid>: precomputed-map lookup (marathon skip).
# One python pass over PS_TABLE computes, for every pid, whether a live
# (non-zombie) pi process is reachable as a descendant AND whether the pid
# has a live (non-zombie) DIRECT child; classify then greps instead of
# walking the process tree per candidate (O(candidates x tree) awk spawns
# took minutes on the real 814-row table). Zombie descendants (STAT Z*)
# neither propagate nor count as the pi descendant, and a zombie child does
# not count as work in flight. Column shape: "pid pi_descendant live_child".
DESC_MAP=""

descendant_map_build() {
    [ -n "${DESC_MAP:-}" ] && rm -f "$DESC_MAP" 2>/dev/null
    DESC_MAP="$(mktemp "${TMPDIR:-/tmp}/pi-reap-desc.XXXXXX")"
    python3 - "$PS_TABLE" "$DESC_MAP" <<'PYEOF'
import sys

ps_table, out_path = sys.argv[1], sys.argv[2]
parent = {}
has = {}
live = {}
# errors="replace": BSD ps prints argv bytes raw, so ONE undecodable byte in
# any process's argv (a Latin-1 filename, say) would otherwise raise
# UnicodeDecodeError and sink the WHOLE map — and a failed map aborts the pass
# fail-closed, turning a stray byte into a permanent hourly no-reap. A
# malformed ROW is skipped for the same reason: row-level parse hiccups must
# never read as "map unavailable". (#947 review P2)
for ln in open(ps_table, encoding="utf-8", errors="replace"):
    f = ln.split()
    if len(f) < 6:
        continue
    try:
        pid, ppid = int(f[0]), int(f[1])
    except ValueError:
        continue
    stat = f[4]
    cand = (len(f) > 7 and f[-1] == "CAND" and not stat.startswith("Z"))
    parent[pid] = ppid
    has[pid] = False
    live[pid] = not stat.startswith("Z")
    if cand:
        cur = parent.get(pid)
        hops = 0
        while cur in has and hops < 256:
            if has[cur]:
                break
            has[cur] = True
            cur = parent.get(cur)
            hops += 1

# direct live child: a candidate whose turn is really executing a tool has a
# live non-zombie child process (bash / node / MCP helper). Load-bearing for
# the #947 stuck arm: no live child => no tool call in flight.
live_child = {p: False for p in has}
for p, par in parent.items():
    if live.get(p) and par in live_child:
        live_child[par] = True

with open(out_path, "w", encoding="utf-8") as out:
    for pid in sorted(has):
        out.write("%s %s %s\n" % (pid, "1" if has[pid] else "0",
                                  "1" if live_child[pid] else "0"))
PYEOF
}

has_live_pi_descendant() {
    [ -s "$DESC_MAP" ] || return 1
    awk -v p="$1" '$1==p { if ($2=="1") exit 0; exit 1 }' "$DESC_MAP"
    return $?
}

# has_live_child <pid>: snapshot lookup — any live (non-zombie) direct child.
# An unknown pid (absent from the snapshot) matches no row, so awk exits 0 and
# this reports "HAS a live child" — the fail-closed direction (it blocks the
# #947 stuck arm), and deliberately the same shape as has_live_pi_descendant
# above: a missing row is never read as "safe to kill". Do not "fix" the
# no-match exit code — that would invert this into a fail-open.
# NOTE: an unbuildable/empty map is a DIFFERENT case (it returns 1 = "no
# child"); run() aborts fail-closed before any kill decision when the build
# fails and candidates exist.
has_live_child() {
    [ -s "$DESC_MAP" ] || return 1
    awk -v p="$1" '$1==p { if ($3=="1") exit 0; exit 1 }' "$DESC_MAP"
    return $?
}

# ── gate 3: candidate-ancestry (#1207) — ADDITIVE (refuses only) ───────
# Recorded decision (option A): a candidate's chain is classified by its
# recognised host app with HUMAN-TERMINAL DOMINANCE — if ANY node on the walk
# is a human terminal the class is `human-terminal`, and a cmux node classifies
# the chain as `cmux-rooted` only when NO human terminal is present anywhere on
# the walk. That is what makes the recorded rule ("any Terminal.app/iTerm"
# ancestor ⇒ human ⇒ never signal") literally true: a nearer recognised name
# must never mask a human ancestor. It is NOT the chain's root (every chain on
# this box roots at /sbin/launchd, so a root test answers `launchd` for a
# human's terminal and for a fleet lane alike) and NOT the presence of a login
# shell (cmux spawns `/usr/bin/login -flp …` per pane, so that clause matches
# every lane and would make the gate refuse everything indiscriminately).
#
# The chain walk is precomputed ONCE per pass into HOST_MAP ("pid class"), the
# same shape and rationale as DESC_MAP: a per-candidate awk walk over the full
# table repeated the O(candidates x tree) cost the single-pass enumeration
# exists to avoid, while a map makes each lookup one grep. `candidate_host_class`
# is the walk's public face; `gate3_allows` is the ONLY place a class becomes an
# authorization, and under option A it refuses every class.
HOST_MAP=""

host_map_build() {
    [ -n "${HOST_MAP:-}" ] && rm -f "$HOST_MAP" 2>/dev/null
    HOST_MAP="$(mktemp "${TMPDIR:-/tmp}/pi-reap-host.XXXXXX")" || { HOST_MAP=""; return 1; }
    if ! python3 - "$PS_TABLE" "$HOST_MAP" <<'PYEOF'
import sys

ps_table, out_path = sys.argv[1], sys.argv[2]

# Recognised host applications. The walk up from the candidate scans the WHOLE
# chain and classifies it with human-terminal DOMINANCE: any human terminal on
# the walk wins (a nearer cmux node must not mask a human ancestor — that is
# what makes "no chain that REACHES a human terminal can ever be signalled"
# true); a cmux node decides `cmux` only when no human terminal is present
# anywhere on the walk; otherwise `unknown`. `Terminal.app`/`iTerm.app` are
# app-bundle components; the bare names cover a PATH-less or relocated binary. A
# host app is matched by its own argv[0] (executable) only — matching the whole
# command line would let an argument mention (e.g. a script that quotes
# `Terminal.app`) masquerade as a host.
HUMAN_NAMES = {"Terminal", "iTerm", "iTerm2"}
HUMAN_BUNDLES = {"Terminal.app", "iTerm.app"}
CMUX_NAMES = {"cmux"}
CMUX_BUNDLES = {"cmux.app"}


def classify(argv0):
    parts = argv0.split("/")
    base = parts[-1]
    if base in HUMAN_NAMES or any(p in HUMAN_BUNDLES for p in parts):
        return "human-terminal"
    if base in CMUX_NAMES or any(p in CMUX_BUNDLES for p in parts):
        return "cmux"
    return ""


ppid = {}
argv0 = {}
# A row whose command column is EMPTY still carries pid/ppid (the awk writes
# seven space-separated fields, the last empty), and a row the awk reduced to
# four fields still carries pid/ppid. Record the parent link even then:
# dropping it truncated the walk at that pid and reported a RESOLVABLE chain
# as `unknown`. Only the command needs column 7.
for ln in open(ps_table, encoding="utf-8", errors="replace"):
    f = ln.rstrip("\n").split(None, 6)
    if len(f) < 2:
        continue
    try:
        pid, parent = int(f[0]), int(f[1])
    except ValueError:
        continue
    cmd = f[6] if len(f) >= 7 else ""
    if cmd == "CAND":
        cmd = ""
    elif cmd.endswith(" CAND"):
        cmd = cmd[:-5]
    ppid[pid] = parent
    argv0[pid] = cmd.split(None, 1)[0] if cmd else ""


def chain_class(pid):
    """Chain class with human-terminal DOMINANCE, else `unknown`.

    A human terminal ANYWHERE on the walk wins outright; `cmux` is returned
    only when no human terminal was seen; otherwise `unknown`. Never stop at
    the first recognised name: the nearer name could be cmux while the chain
    still reaches the owner's terminal above it.
    """
    cur, hops, seen = pid, 0, set()
    saw_cmux = False
    while cur > 0 and cur not in seen and hops < 256:
        seen.add(cur)
        cls = classify(argv0.get(cur, ""))
        if cls == "human-terminal":
            return "human-terminal"
        if cls == "cmux":
            saw_cmux = True
        nxt = ppid.get(cur)
        if nxt is None or nxt == cur:
            break
        cur = nxt
        hops += 1
    return "cmux" if saw_cmux else "unknown"


with open(out_path, "w", encoding="utf-8") as out:
    for pid in sorted(ppid):
        out.write("%s %s\n" % (pid, chain_class(pid)))
PYEOF
    then
        rm -f "$HOST_MAP" 2>/dev/null
        HOST_MAP=""
        return 1
    fi
    return 0
}

candidate_host_class() { # <pid> -> human-terminal|cmux|unknown
    local pid="$1" cls=""
    # A missing/empty map is `unknown` — never a default class that permits.
    if [ -s "${HOST_MAP:-}" ]; then
        cls="$(awk -v p="$pid" '$1==p {print $2; exit}' "$HOST_MAP" 2>/dev/null)"
    fi
    case "$cls" in
        human-terminal|cmux) printf '%s\n' "$cls" ;;
        *) printf 'unknown\n' ;;
    esac
}

# gate3_allows <pid> -> 0 = MAY signal, 1 = REFUSE. Sets GATE3_CLASS.
# Under the recorded decision EVERY class refuses; the cmux arm is the only one
# that COULD be relaxed, and relaxing it is exactly option B, which the owner
# declined — so it is the mutation site the suite pins with a RED control.
GATE3_CLASS=""
gate3_allows() {
    GATE3_CLASS="$(candidate_host_class "$1")"
    case "$GATE3_CLASS" in
        cmux) return 1 ;;            # fleet-host-rooted: report-only (option A)
        human-terminal) return 1 ;;  # belongs to a human: never signal
        *) GATE3_CLASS=unknown; return 1 ;;  # unrecognised/unresolvable/empty
    esac
}


# ── pass 2: cmux store read (fail-closed; retry-once handled by caller) ─
# TSV rows: pid<TAB>pidStartSeconds<TAB>pidStartMicroseconds<TAB>
# agentLifecycle<TAB>runtimeStatus<TAB>sessionId<TAB>cwd<TAB>updatedAt
# updatedAt (float epoch) is the record's own last-write time — the lossy
# agentLifecycle belief is bounded by it (#947).
STORE_TSV=""
STUCK_TSV=""
# store_extract <store-file> <out-tsv> — 0 on success; 3 on missing/corrupt.
# Split out of store_read so the stuck-settle re-verify can re-read the store
# into a private temp file without disturbing STORE_TSV (#947).
store_extract() {
    python3 - "$1" "$2" <<'PYEOF'
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
    # The reaper's internal framing bytes (\t \n, the '|' cand-row
    # delimiter, and 0x1f the settle tie-separator) are all APFS-legal in
    # names — strip them from store-derived values. Paths that STILL carry a
    # framing byte after this (resolved from real on-disk names by the find
    # fallback, never via the store) are abstained at classify below.
    return str(v).replace("\t", " ").replace("\n", " ").replace("|", " ").replace("\x1f", " ")
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
        esc(rec.get("updatedAt", "")),
    ]))
with open(out_path, "w", encoding="utf-8") as out:
    out.write("\n".join(rows) + ("\n" if rows else ""))
PYEOF
}

store_read() { # 0 on success; 3 on missing/corrupt (python exit)
    [ -n "${STORE_TSV:-}" ] && rm -f "$STORE_TSV" 2>/dev/null
    STORE_TSV="$(mktemp "${TMPDIR:-/tmp}/pi-reap-store.XXXXXX")"
    store_extract "$CMUX_STORE" "$STORE_TSV"
}

store_records_for_pid() { # <pid> -> matching TSV lines ("" when none)
    grep -E "^${1}	" "$STORE_TSV" 2>/dev/null || true
}

# store_number_ok / updated_stamp_ok live in scripts/lib/pid-identity.sh
# (sourced above, #1178) — one definition of the untrusted-store-number gate.

# stuck_record_still_frozen <sid> <pid> <now> — STUCK-settle re-verify. The
# population inspected is deliberately the SAME one classify unions over:
# EVERY record for this pid, fence-matched or not. Three things must hold from
# a FRESH store read —
#   (1) the DECIDING record ($sid) is present and still non-idle; and
#   (2) every non-idle record for this pid still carries a valid, still-stale
#       stamp (a twin that starts a turn rewrites its own stamp => suppress);
#   (3) at least one row must exist at all.
# Every failure mode returns 1 (suppress) — never 0. Re-reading ONLY $sid was a
# fail-open: a twin whose sid is not the max-epoch one could go fresh in the
# classify->settle window and stay invisible (#947 review P1 — reported
# independently by three reviewers).
stuck_record_still_frozen() {
    local sid="$1" pid="$2" now="$3" tsv rec n=0 decided=0 rsid2 al rs ua age
    tsv="$(mktemp "${TMPDIR:-/tmp}/pi-reap-stuck.XXXXXX")" || return 1
    STUCK_TSV="$tsv"
    if ! store_extract "$CMUX_STORE" "$tsv"; then STUCK_TSV=""; rm -f "$tsv"; return 1; fi
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        n=$((n+1))
        rsid2="$(printf '%s' "$rec" | awk -F'\t' '{print $6}')"
        al="$(printf '%s' "$rec" | awk -F'\t' '{print $4}')"
        rs="$(printf '%s' "$rec" | awk -F'\t' '{print $5}')"
        [ "$rsid2" = "$sid" ] && decided=1
        if [ "$al" = "idle" ] && [ "$rs" = "idle" ]; then
            # a record going idle means a turn ENDED; only the deciding record
            # ending proves the whole premise is gone (a sibling going idle
            # just leaves the union — it does not weaken it)
            if [ "$rsid2" = "$sid" ]; then STUCK_TSV=""; rm -f "$tsv"; return 1; fi
            continue
        fi
        ua="$(printf '%s' "$rec" | awk -F'\t' '{print $8}')"
        updated_stamp_ok "$ua" "$now" || { STUCK_TSV=""; rm -f "$tsv"; return 1; }
        age="$(awk -v n="$now" -v u="$ua" 'BEGIN{printf "%.1f", (n-u)/3600}')"
        awk -v a="$age" -v t="$REAP_STUCK_HOURS" 'BEGIN{exit !(a > t)}' || { STUCK_TSV=""; rm -f "$tsv"; return 1; }
    done <<<"$(grep -E "^${pid}	" "$tsv" 2>/dev/null || true)"
    STUCK_TSV=""; rm -f "$tsv"
    [ "$n" -gt 0 ] && [ "$decided" = 1 ]
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
            if not isinstance(obj, dict):
                # valid JSON but not a record (scalar/array) — an undatable
                # write: fail closed like the undatable-dict case
                return None, "unparseable"
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
#   pid|pgid|rss|sessionId|jsonl|idle_h|class_last_epoch|class_lstart|stuck
# (stuck=1 only ever appears under REAP_REAP_STUCK=1; reap_one re-checks it.)
# stuck-classified rows -> STUCK_CANDIDATES (report-only audit list):
#   pid|tty|rss|jsonl_idle_h|record_age_h|sessionId|veto
REAP_CANDIDATES=""
REAP_COUNT=0
STUCK_CANDIDATES=""
STUCK_COUNT=0
STUCK_RSS=0
# Gate 3 (#1207) audit counters, rebuilt on emit=1 only (the silent RESIDUAL
# re-classification must not double-count them).
# GATE3_REFUSED_* is a CENSUS by ground over every classified candidate;
# GATE3_SUPPRESSED counts only the ones refused at an eligibility site — i.e.
# the ones gate 3 actually changed the pass's outcome for. Conflating the two
# let the report read as though gate 3 produced a zero harvest that another
# gate had already produced.
GATE3_REFUSED_TOTAL=0
GATE3_REFUSED_HUMAN=0
GATE3_REFUSED_CMUX=0
GATE3_REFUSED_UNKNOWN=0
GATE3_ALLOWED=0
GATE3_SUPPRESSED=0

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
    # Sid-token boundary match only (`_<sid>_` or `_<sid>.jsonl`): an open
    # `*<sid>*.jsonl` glob could widen to a sibling session whose sid has
    # this one as a substring and bind ITS idle proof (and settle re-probe
    # file) to a candidate whose own session is active — foreign files never
    # advance, so an active session could be TERM'd on stale proof.
    if [ -d "$dir" ]; then
        hit="$(find "$dir" -maxdepth 1 \( -name "*_${sid}_*.jsonl" -o -name "*_${sid}.jsonl" \) 2>/dev/null | head -1)"
        [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
    fi
    hit="$(find "$PI_SESSIONS_DIR" \( -name "*_${sid}_*.jsonl" -o -name "*_${sid}.jsonl" \) -type f 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s\n' "$hit"
}

# classify_candidates <now> <emit:1|0> — fills REAP_CANDIDATES/REAP_COUNT.
# emit=1 prints + logs per-candidate verdict rows; emit=0 is the RESIDUAL
# re-classification sweep (silent). STUCK_* are rebuilt on emit=1 only, so
# the silent residual sweep cannot double-count the audit list.
classify_candidates() {
    local now="$1" emit="$2" pid detail epoch pgid stat rss tty rec al rs sid cwd sfile
    local last_epoch youngest vote abstain matched_cnt veto diff sid_marker rec_pss
    local rec_age_min ruid rage stuck_ok sfiles_all US_ALL ral rrs
    local rsid rcwd rf le US gate3_ok
    REAP_CANDIDATES=""; REAP_COUNT=0
    if [ "$emit" = 1 ]; then STUCK_CANDIDATES=""; STUCK_COUNT=0; STUCK_RSS=0;
        GATE3_REFUSED_TOTAL=0; GATE3_REFUSED_HUMAN=0; GATE3_REFUSED_CMUX=0
        GATE3_REFUSED_UNKNOWN=0; GATE3_ALLOWED=0; GATE3_SUPPRESSED=0; fi
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
        # ── gate 3: candidate-ancestry (#1207) ────────────────────────
        # Classified for EVERY live candidate (whether or not it would
        # otherwise be eligible), so the footer's "refused N on which ground"
        # covers the whole population rather than only the handful that reach
        # an authorization. Under option A every class refuses; the verdict is
        # consulted at BOTH authorization sites below and again at the signal
        # point in reap_one(). `gate3_ok` is per-iteration (declared local).
        gate3_ok=0
        if gate3_allows "$pid"; then gate3_ok=1; fi
        if [ "$emit" = 1 ]; then
            if [ "$gate3_ok" = 1 ]; then
                GATE3_ALLOWED=$((GATE3_ALLOWED+1))
            else
                GATE3_REFUSED_TOTAL=$((GATE3_REFUSED_TOTAL+1))
                case "$GATE3_CLASS" in
                    human-terminal) GATE3_REFUSED_HUMAN=$((GATE3_REFUSED_HUMAN+1)) ;;
                    cmux)           GATE3_REFUSED_CMUX=$((GATE3_REFUSED_CMUX+1)) ;;
                    *)              GATE3_REFUSED_UNKNOWN=$((GATE3_REFUSED_UNKNOWN+1)) ;;
                esac
            fi
        fi
        # own-session veto (PI_SESSION_ID hard gate)
        if [ -n "${PI_SESSION_ID:-}" ]; then
            if grep -qE "	${PI_SESSION_ID}(	|$)" <<<"$(store_records_for_pid "$pid")"; then
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
            # UNTRUSTED value, and the next line is arithmetic: gate it first
            # (see store_number_ok). An unusable pss abstains — it can neither
            # prove nor veto.
            store_number_ok "$rec_pss" "$now" || { abstain=$((abstain+1)); continue; }
            diff="$(pid_fence_diff "$epoch" "$rec_pss")"
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
        # JSONL idle proof FIRST (#947): the ground-truth age must be measured
        # even for a candidate the cmux veto is about to block — otherwise the
        # stuck population is invisible and a permanently immunised pid reads
        # as a healthy "allowlist" skip. Youngest voting matched record wins;
        # no-JSONL records abstain (prove nothing AND veto nothing).
        youngest=""; vote=0; sid=""; sfile=""; sfiles_all=""
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            rsid="$(printf '%s' "$rec" | awk -F'\t' '{print $6}')"
            rcwd="$(printf '%s' "$rec" | awk -F'\t' '{print $7}')"
            # a sid carrying glob metachars would WIDEN the find match to
            # arbitrary files — abstain (garbage store input never selects
            # proof); real pi sids are 36-char hex+dash UUIDs
            case "$rsid" in *[*?[]*) abstain=$((abstain+1)); continue ;; esac
            rf="$(session_file_for "$rsid" "$rcwd")"
            if [ -z "$rf" ] || [ ! -s "$rf" ]; then abstain=$((abstain+1)); continue; fi
            # framing byte in the REAL on-disk path (esc neutralizes store
            # values; the find fallback can surface a raw name): a '|' would
            # shift the cand row, a 0x1f would shred the settle split — such
            # a file can never round-trip the pipeline, so abstain.
            case "$rf" in
                *'|'*|*"$(printf '\037')"*|*$'\n'*)
                    abstain=$((abstain+1)); continue ;;
            esac
            le="$(jsonl_epoch_for "$rf")"
            if [ -z "$le" ]; then abstain=$((abstain+1)); continue; fi
            vote=$((vote+1))
            # every proof-bearing matched file, in match order — the settle-3
            # probe set for a stuck row (see the REAP-eligible emit below)
            US_ALL="$(printf '\037')"
            case "$sfiles_all$US_ALL" in *"$rf$US_ALL"*) ;; *) sfiles_all="$sfiles_all$US_ALL$rf" ;; esac
            # sid/sfile track the MAX-epoch (age-setting) record — settle-3
            # re-probes exactly the file(s) that decided eligibility. TIED
            # equal-max twins are unioned (\x1f unit-separator joined — only
            # clean paths reach the union; framing-byte paths abstained above,
            # so 0x1f is unambiguous) so a resumed twin is never invisible to
            # the settle gate (arbitrary-twin re-probe).
            if [ -z "$youngest" ] || [ "$le" -gt "$youngest" ]; then
                youngest="$le"; sid="$rsid"; sfile="$rf"
            elif [ "$le" = "$youngest" ]; then
                US="$(printf '\037')"  # unit separator — never in file paths
                case "$sfile$US" in *"$rf$US"*) ;; *) sfile="$sfile$US$rf" ;; esac
            fi
        done <<<"$matched"
        # ── bounded veto (#947): a non-idle cmux record is now the ONLY
        # blocker left, but it is a hook-derived belief that can be stuck
        # forever. Measure the least-stale matched record's own updatedAt;
        # any record with a fresh stamp — or no stamp at all — keeps the veto
        # (fail closed).
        rec_age_min=""
        if [ -n "$veto" ]; then
            # Freshness is a UNION over EVERY non-idle record for this pid —
            # not just the fence-matched ones. A record with a missing or
            # off-fence pidStartSeconds abstains from VOTING (the veto itself
            # still comes from $matched only, so the normal path and its pinned
            # 'abstain != veto' contract are unchanged), but it must still be
            # able to WITHHOLD a kill: a fresh or unparseable stamp on it is
            # direct evidence this pid is being written to right now. It can
            # never CAUSE one. (#947 review P2)
            while IFS= read -r rec; do
                [ -n "$rec" ] || continue
                ral="$(printf '%s' "$rec" | awk -F'\t' '{print $4}')"
                rrs="$(printf '%s' "$rec" | awk -F'\t' '{print $5}')"
                [ "$ral" = "idle" ] && [ "$rrs" = "idle" ] && continue
                ruid="$(printf '%s' "$rec" | awk -F'\t' '{print $8}')"
                updated_stamp_ok "$ruid" "$now" || { rec_age_min=""; break; }
                rage="$(awk -v n="$now" -v u="$ruid" 'BEGIN{printf "%.1f", (n-u)/3600}')"
                if [ -z "$rec_age_min" ] || awk -v a="$rage" -v b="$rec_age_min" 'BEGIN{exit !(a < b)}'; then
                    rec_age_min="$rage"
                fi
            done <<<"$(store_records_for_pid "$pid")"
        fi
        if [ -n "$veto" ]; then
            # no JSONL proof => the veto still reports first (the reason
            # vocabulary the suite pins) and nothing is ever signaled.
            if [ "$vote" -eq 0 ]; then
                [ "$emit" = 1 ] && say "$pid tty=$tty SKIP $veto (any non-idle twin vetoes)"
                continue
            fi
            idle_age_h="$(awk -v n="$now" -v y="$youngest" 'BEGIN{printf "%.1f", (n-y)/3600}')"
            # STUCK requires BOTH independent signals frozen past the same long
            # bound, a process not accumulating CPU (S/I), and no live child
            # (no tool call in flight).
            stuck_ok=0
            if [ -n "$rec_age_min" ] \
               && awk -v a="$rec_age_min" -v t="$REAP_STUCK_HOURS" 'BEGIN{exit !(a > t)}' \
               && awk -v a="$idle_age_h" -v t="$REAP_STUCK_HOURS" 'BEGIN{exit !(a > t)}' \
               && ! has_live_child "$pid"; then
                case "$stat" in S*|I*) stuck_ok=1 ;; esac
            fi
            if [ "$stuck_ok" = 1 ]; then
                if [ "$emit" = 1 ]; then
                    STUCK_CANDIDATES="$(printf '%s\n%s' "$STUCK_CANDIDATES" "$pid|$tty|${rss:-0}|$idle_age_h|$rec_age_min|$sid|$veto" | sed '/^$/d')"
                    STUCK_COUNT=$((STUCK_COUNT+1))
                    STUCK_RSS=$((STUCK_RSS + ${rss:-0}))
                fi
                if [ "$REAP_REAP_STUCK" = 1 ]; then
                    # gate 3 (#1207) still applies to an armed stuck row: the
                    # arm is an authorization to signal, and gate 3 can refuse
                    # it. The STUCK audit above already reported the row, so
                    # the refusal is emitted here too (the audit's arm note
                    # names it as report-only).
                    if [ "$gate3_ok" != 1 ]; then
                        [ "$emit" = 1 ] && GATE3_SUPPRESSED=$((GATE3_SUPPRESSED+1))
                        [ "$emit" = 1 ] && say "$pid tty=$tty REPORT-ONLY gate3=$GATE3_CLASS (STUCK arm refused; candidate-ancestry gate — never signalled)"
                        continue
                    fi
                    # a stuck row re-probes the UNION of every matched
                    # proof-bearing file at settle, not just the max-epoch one:
                    # a twin whose JSONL advances then suppresses, and
                    # $youngest is >= the stuck bound old, so a genuine advance
                    # (~now) always exceeds it. (#947 review P1)
                    REAP_CANDIDATES="$(printf '%s\n%s' "$REAP_CANDIDATES" "$pid|$pgid|${rss:-0}|$sid|$sfiles_all|$idle_age_h|$youngest|$epoch|1" | sed '/^$/d')"
                    [ "$emit" = 1 ] && say "$pid tty=$tty REAP-ELIGIBLE(STUCK) rss=${rss:-0} idle_h=${idle_age_h}h record_age_h=${rec_age_min}h session=$sid jsonl=$sfile"
                else
                    [ "$emit" = 1 ] && say "$pid tty=$tty STUCK-ESCALATE rss=${rss:-0} idle_h=${idle_age_h}h record_age_h=${rec_age_min}h session=$sid ($veto, record stale past ${REAP_STUCK_HOURS}h) — report-only"
                fi
                continue
            fi
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP $veto (any non-idle twin vetoes; jsonl idle ${idle_age_h}h, record age ${rec_age_min:-?}h)"
            continue
        fi
        if [ "$vote" -eq 0 ]; then
            [ "$emit" = 1 ] && say "$pid tty=$tty SKIP no-jsonl-proof (${abstain} abstain(s) — fail-closed)"
            continue
        fi
        idle_age_h="$(awk -v n="$now" -v y="$youngest" 'BEGIN{printf "%.1f", (n-y)/3600}')"
        if awk -v n="$now" -v y="$youngest" -v t="$REAP_IDLE_HOURS" 'BEGIN{exit !((n-y)/3600 > t)}'; then
            # gate 3 (#1207): a candidate that passes every other gate is still
            # refused unless its chain class is one the recorded decision
            # authorizes — under option A, none. Reported, never signalled.
            if [ "$gate3_ok" != 1 ]; then
                [ "$emit" = 1 ] && GATE3_SUPPRESSED=$((GATE3_SUPPRESSED+1))
                [ "$emit" = 1 ] && say "$pid tty=$tty REPORT-ONLY gate3=$GATE3_CLASS (candidate-ancestry gate — never signalled) idle_h=${idle_age_h}h session=$sid jsonl=$sfile"
                continue
            fi
            # Field 5 (the settle probe set) carries the UNION of every matched
            # proof file, not just the max-epoch deciding one: a strictly-older
            # matched twin that advances in the classify->settle window must
            # suppress, exactly as for a stuck row. Probing the union only ever
            # narrows the kill set. (#947 review P2)
            REAP_CANDIDATES="$(printf '%s\n%s' "$REAP_CANDIDATES" "$pid|$pgid|${rss:-0}|$sid|$sfiles_all|$idle_age_h|$youngest|$epoch|0" | sed '/^$/d')"
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
    local detail epoch2 pgid2 stat2 sfile2 fresh_epoch stuck_flag epoch3 pgid3 stat3
    pid="$(printf '%s' "$cand" | cut -d'|' -f1)"
    pgid="$(printf '%s' "$cand" | cut -d'|' -f2)"
    rss="$(printf '%s' "$cand" | cut -d'|' -f3)"
    sid="$(printf '%s' "$cand" | cut -d'|' -f4)"
    sfile="$(printf '%s' "$cand" | cut -d'|' -f5)"
    idle_h="$(printf '%s' "$cand" | cut -d'|' -f6)"
    class_epoch="$(printf '%s' "$cand" | cut -d'|' -f7)"
    class_lstart="$(printf '%s' "$cand" | cut -d'|' -f8)"
    stuck_flag="$(printf '%s' "$cand" | cut -d'|' -f9)"
    # fail-closed: a corrupted candidate row (store value containing the
    # unescaped field separator, etc.) must SUPPRESS, never proceed.
    case "$class_epoch" in
        ''|*[!0-9]*) log "SETTLE-SKIP $pid corrupt cand class_epoch — suppress"; return 0 ;;
    esac
    case "$class_lstart" in
        ''|*[!0-9]*) log "SETTLE-SKIP $pid corrupt cand class_lstart — suppress"; return 0 ;;
    esac
    # defense in depth (#947): a stuck-armed row is only ever signaled while
    # REAP_REAP_STUCK is still set for THIS pass. A row whose flag is neither
    # 0/1/empty is corrupt => suppress.
    case "$stuck_flag" in
        ''|0) stuck_flag=0 ;;
        1)
            stuck_flag=1
            if [ "$REAP_REAP_STUCK" != 1 ]; then
                log "SETTLE-SKIP $pid stuck cand but REAP_REAP_STUCK unset — suppress"
                return 0
            fi
            ;;
        *) log "SETTLE-SKIP $pid corrupt cand stuck flag — suppress"; return 0 ;;
    esac
    # settle 1: still self/ancestor?
    is_self_like "$pid" && { log "SETTLE-SKIP $pid now-self — suppress"; return 0; }
    # settle 1b: gate 3 (#1207) — the candidate-ancestry verdict is re-asked
    # immediately before the first possible signal. The re-ask defends against
    # a BYPASSED classify-site check; it is NOT a fresh chain read — the class
    # comes from the pass-start HOST_MAP snapshot (ancestry is stable, and the
    # incarnation fence in settle 2 covers pid reuse). A failed/empty map
    # answers `unknown`, which refuses — a broken read is never "may signal".
    if ! gate3_allows "$pid"; then
        log "SETTLE-SKIP $pid gate 3 refused (chain class=$GATE3_CLASS) — suppress"
        return 0
    fi
    # settle 2: FRESH probe — lstart changed (pid died + reused)?
    detail="$(candidate_detail "$pid")" || { log "SETTLE-SKIP $pid gone (ESRCH at settle) — suppress"; return 0; }
    epoch2="$(printf '%s' "$detail" | awk '{print $1}')"
    pgid2="$(printf '%s' "$detail" | awk '{print $2}')"
    stat2="$(printf '%s' "$detail" | awk '{print $3}')"
    if [ -n "$class_lstart" ] && [ -n "$epoch2" ] && [ "$epoch2" != "$class_lstart" ]; then
        log "SETTLE-SKIP $pid incarnation changed (pid reused) — suppress"
        return 0
    fi
    # settle 2b (STUCK rows only, #947): re-verify the override's premise from a
    # FRESH store read AND require the process to still be sleeping. The stuck
    # warrant is "the cmux record has not advanced past the bound"; if the turn
    # ended (or a tool child appeared) between classify and settle, suppress.
    if [ "$stuck_flag" = 1 ]; then
        case "$stat2" in
            S*|I*) ;;
            *) log "SETTLE-SKIP $pid stuck row process no longer sleeping (stat=$stat2) — suppress"; return 0 ;;
        esac
        # settle 2c (STUCK rows, #947 review P2): a FRESH child probe. The
        # classify-time DESC_MAP is a pass-start snapshot and cannot see a tool
        # child spawned since; a parent `wait`ing on a child stays in S with
        # its cmux record unchanged, so without this a stuck row behind other
        # kills (tens of seconds later at REAP_GRACE_SECONDS each) could
        # group-kill a session that resumed and started working.
        ps_enumeration
        # The fresh probe is only evidence if it RAN and produced a table. A
        # failed/empty enumeration makes descendant_map_build "succeed" on an
        # empty map, has_live_child/has_live_pi_descendant then answer "no
        # child" for every pid, and the guard below silently disappears —
        # reproduced as a real TERM+KILL of a session with a live tool child
        # (#947 review P1). Fail closed instead.
        if [ "$PS_RC" != 0 ] || [ ! -s "$PS_TABLE" ]; then
            log "SETTLE-SKIP $pid stuck row fresh ps enumeration unavailable (rc=$PS_RC) — suppress"
            return 0
        fi
        [ -n "$SELF_TTY" ] || self_ancestors_from_table
        if ! descendant_map_build; then
            log "SETTLE-SKIP $pid stuck row fresh descendant map unavailable — suppress"
            return 0
        fi
        if has_live_child "$pid" || has_live_pi_descendant "$pid"; then
            log "SETTLE-SKIP $pid stuck row live child/descendant at settle (work in flight) — suppress"
            return 0
        fi
        if ! stuck_record_still_frozen "$sid" "$pid" "$now"; then
            log "SETTLE-SKIP $pid stuck row record no longer frozen/idle (union over all its records) — suppress"
            return 0
        fi
    fi
    # settle 3: JSONL activity advanced since classification? Every deciding
    # (max-epoch) file is re-probed — an advance on ANY tied twin suppresses.
    # Decide-file re-probe failure (deleted/truncated/undatable since classify)
    # is FAIL-CLOSED: what cannot be re-verified is never signaled.
    while IFS= read -r sf; do
        [ -n "$sf" ] || continue
        fresh_epoch="$(jsonl_epoch_for "$sf")"
        if [ -z "$fresh_epoch" ]; then
            log "SETTLE-SKIP $pid cannot re-probe deciding file ($sf) — suppress"
            return 0
        fi
        if [ -n "$class_epoch" ] && [ "$fresh_epoch" -gt "$class_epoch" ]; then
            log "SETTLE-SKIP $pid activity advanced ($sf ${class_epoch} -> ${fresh_epoch}) — suppress"
            return 0
        fi
    done <<<"$(printf '%s' "$sfile" | tr "$(printf '\037')" '\n')"
    # (single-file case: one iteration, identical semantics to round 1)
    signal_target "$pid" "$pgid2" TERM
    log "SIGNAL pid=$pid pgid=$pgid2 SIGTERM rss=${rss:-0} idle_h=${idle_h}h stuck=$stuck_flag session=$sid jsonl=$sfile"
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
        # `started` comes from the lock file, which is on disk: never feed it
        # to `$(( ))` unvalidated (same arithmetic-injection class as
        # pidStartSeconds). An unusable value leaves age unknown => the lock is
        # treated as NOT stale (block), the fail-closed direction.
        if [ -n "$started" ] && [ -n "$now" ] && store_number_ok "$started" "$now"; then
            age="$(awk -v a="$now" -v b="$started" 'BEGIN{printf "%d", a-b}')"
        else
            age=0   # unknown age => not-stale => a live owner's lock is honoured
        fi
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$age" -lt "$REAP_LOCK_STALE_SECONDS" ]; then
            log "LOCK held by live pid $owner (age ${age}s) — abort"
            # footer on this path too (#947 review P2): a footer-keyed monitor
            # must not read the PREVIOUS pass's STUCK_ARMED/KILLED as current.
            log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS CANDIDATES=0 STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK KILLED=0 YIELD=0"
            return 1
        fi
        log "LOCK stale (owner=${owner:-?} age=${age}s) — breaking"
        rm -rf "$LOCK_DIR"
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "LOCK raced — abort"
        log "MODE=$MODE NOW=$(now_epoch) THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS CANDIDATES=0 STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK KILLED=0 YIELD=0"
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
            --idle-hours)
                [ $# -ge 2 ] || { echo "bad --idle-hours: missing value" >&2; exit 2; }
                REAP_IDLE_HOURS="$2"; shift 2 ;;
            --stuck-hours)
                [ $# -ge 2 ] || { echo "bad --stuck-hours: missing value" >&2; exit 2; }
                REAP_STUCK_HOURS="$2"; shift 2 ;;
            --reap-stuck) REAP_REAP_STUCK=1; shift ;;
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
    grep -qE '^[0-9]+$' <<<"$REAP_IDLE_HOURS" || { echo "bad --idle-hours: $REAP_IDLE_HOURS" >&2; exit 2; }
    # Bound the RAW string BEFORE normalizing. `$(( 10#... ))` wraps mod 2^64,
    # so 2^64+1 normalized to 1 — a "1 hour" threshold that would reap almost
    # everything — and 2^64 normalized to 0. Checking the residue cannot catch
    # that; checking the raw value can (and the regex above already proved it is
    # all digits, so awk cannot be confused by it). (#947 review P2)
    awk -v v="$REAP_IDLE_HOURS" -v m="$REAP_MAX_HOURS" 'BEGIN{exit !(v >= 1 && v <= m)}' \
        || { echo "bad --idle-hours: out of range (1..$REAP_MAX_HOURS)" >&2; exit 2; }
    # Only NOW is it safe to normalize (bash reads a zero-padded value as OCTAL
    # while awk reads the same string as decimal, so REAP_IDLE_HOURS=024 gave
    # awk 24h but a derived bound of $((024*3)) = 60, silently 12h early).
    REAP_IDLE_HOURS=$(( 10#${REAP_IDLE_HOURS} ))
    # bounded-veto freshness bound (#947): default 3x the (final) idle
    # threshold, so --idle-hours moves it too; an explicit value always wins.
    if [ -z "$REAP_STUCK_HOURS" ]; then
        REAP_STUCK_HOURS=$(( REAP_IDLE_HOURS * 3 ))
        # The derived value is ARITHMETIC, so it can WRAP — and a wrap can land
        # POSITIVE (6148914691236517206 * 3 -> 3N-2^64 = 2), which a
        # positivity check alone accepts: the intended ~7e14-year bound becomes
        # 2 hours, so a 3h-stale non-idle session flips STUCK and is reaped
        # under the arm (reproduced end-to-end by review). Require monotonicity:
        # for any wrap, derived = 3N - 2^64 < N (since N <= 2^63-1, which the
        # REAP_MAX_HOURS validation enforces via `[ -ge 1 ]` erroring above
        # INT64_MAX), so `derived >= idle` rejects EVERY wrap while preserving
        # the "derived bound is not capped by REAP_MAX_HOURS" intent.
        # (#947 review P1)
        grep -qE '^[0-9]+$' <<<"$REAP_STUCK_HOURS" && [ "$REAP_STUCK_HOURS" -ge "$REAP_IDLE_HOURS" ] \
            || { echo "bad derived --stuck-hours: $REAP_STUCK_HOURS (--idle-hours too large)" >&2; exit 2; }
    else
        grep -qE '^[0-9]+$' <<<"$REAP_STUCK_HOURS" || { echo "bad --stuck-hours: $REAP_STUCK_HOURS" >&2; exit 2; }
        awk -v v="$REAP_STUCK_HOURS" -v m="$REAP_MAX_HOURS" 'BEGIN{exit !(v >= 1 && v <= m)}' \
            || { echo "bad --stuck-hours: out of range (1..$REAP_MAX_HOURS)" >&2; exit 2; }
        REAP_STUCK_HOURS=$(( 10#${REAP_STUCK_HOURS} ))
        # The stuck bound is an ESCALATION of the idle bound, so an explicit
        # value below it is a contradiction: the stuck arm compares
        # `idle_age_h > REAP_STUCK_HOURS`, so `--stuck-hours 1` with the default
        # 24h idle would TERM a session idle only 2h — a live session reaped
        # without ever passing the idle proof the header contract requires.
        # Same monotonicity rule as the derived branch. (#947 review P2)
        [ "$REAP_STUCK_HOURS" -ge "$REAP_IDLE_HOURS" ] \
            || { echo "bad --stuck-hours: $REAP_STUCK_HOURS is below the idle threshold ${REAP_IDLE_HOURS}h (the stuck bound escalates it)" >&2; exit 2; }
    fi
    case "$REAP_REAP_STUCK" in
        0|1) ;;
        *) echo "bad REAP_REAP_STUCK: $REAP_REAP_STUCK (want 0 or 1)" >&2; exit 2 ;;
    esac
    mkdir -p "$(dirname "$REAP_LOG")" 2>/dev/null || true
    now="$(now_epoch)"

    # `--list` is a pure read-only diagnostic (no store read, no kill decision,
    # no lock, no log write) and is the surface an operator reaches for when
    # the reaper misbehaves — so it is handled HERE, before the lock, before
    # any log mutation, and before the descendant-map build/abort (which exists
    # only to gate SIGNALING). (#947 review P2)
    if [ "$LIST_ONLY" = 1 ]; then
        ps_enumeration
        trap 'rm -f "$PS_TABLE"' EXIT
        # A diagnostic that prints nothing because its probe FAILED must not
        # look like "no sessions" — the operator's only signal would be an
        # empty list. Report and exit 3. (#947 review P2)
        if [ "$PS_RC" != 0 ]; then
            echo "--list: ps enumeration failed (rc=$PS_RC, exit 3)" >&2
            exit 3
        fi
        printf '%s\n' "$CANDIDATES" | sed '/^$/d'
        exit 0
    fi

    if [ ${#PROBE_FILES[@]} -gt 0 ]; then
        probe_jsonl "${PROBE_FILES[@]}"
        exit 0
    fi

    if ! lock_acquire; then
        echo "FAIL-CLOSED abort: lock held (exit 3)" >&2
        log "FAIL-CLOSED abort: lock (exit 3)"
        exit 3
    fi
    trap 'rm -f "$PS_TABLE" "$STORE_TSV" "$STUCK_TSV" "$DESC_MAP" "$HOST_MAP"; lock_release' EXIT
    # log size guard: keep last ~200 lines. Truncation temp is mktemp'd in
    # the log's own directory (never a predictable sibling name — a local
    # attacker could pre-seed a symlink at a fixed path).
    mkdir -p "${REAP_LOG%/*}" 2>/dev/null || true
    # fail-closed (ARMED passes only): an armed pass must never run with no
    # audit trail — if the log cannot be created/appended, abort (exit 3)
    # before any signal. Dry-run — and --list when mode resolves to dry-run
    # — keep best-effort logging (their verdict surfaces are stdout,
    # warn-first). Runs BEFORE the sentinel:
    # an unwritable log aborts exit 3 even when disarmed (no silent
    # no-trail hourly exit-3s beyond the documented class).
    if [ "$MODE" = apply ] && ! : >>"$REAP_LOG" 2>/dev/null; then
        echo "FAIL-CLOSED abort: REAP_LOG unwritable ($REAP_LOG) (exit 3)" >&2
        exit 3
    fi
    if [ -f "$REAP_LOG" ]; then
        trunc="$(mktemp "${REAP_LOG%/*}/pi-reap-log-trunc.XXXXXX" 2>/dev/null)" || trunc=""
        if [ -n "$trunc" ]; then
            tail -n 200 "$REAP_LOG" >"$trunc" 2>/dev/null && mv "$trunc" "$REAP_LOG" 2>/dev/null || rm -f "$trunc"
        fi
    fi

    if [ -f "$DISABLED_SENTINEL" ]; then
        log "MODE=disabled NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK CANDIDATES=0 KILLED=0 YIELD=0 sentinel=$DISABLED_SENTINEL"
        echo "disabled by sentinel ($DISABLED_SENTINEL) — exiting without signal"
        exit 0
    fi
    log "==== pi-reap-idle pass: MODE=$MODE THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS STUCK_ARMED=$REAP_REAP_STUCK now=$now ===="
    ps_enumeration
    self_ancestors_from_table
    pre_count="$(printf '%s\n' "$CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"
    # FAIL-CLOSED (#947 review P2/P1): a `ps` that FAILED is not an idle
    # machine. Without this, a broken ps/PS_BIN yields an empty table => 0
    # candidates => the store read is skipped and the job exits 0 with a
    # healthy-looking footer, every hour, forever. Abort whenever the
    # enumeration did not fully succeed — with OR without rows: a partly-failed
    # ps yields a TRUNCATED table, and a truncated table silently defeats the
    # no-live-child guard (the same reasoning the settle probe suppresses on).
    if [ "$PS_RC" != 0 ]; then
        echo "FAIL-CLOSED abort: ps enumeration failed (rc=$PS_RC, candidates=$pre_count, exit 3)" >&2
        log "FAIL-CLOSED abort: ps enumeration failed (rc=$PS_RC, candidates=$pre_count, exit 3)"
        log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS CANDIDATES=$pre_count STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK KILLED=0 YIELD=0"
        exit 3
    fi
    descendant_map_ok=1
    descendant_map_build || descendant_map_ok=0
    # gate 3 (#1207): one precomputed chain class per pid from the SAME ps
    # snapshot. A failed build is NOT fatal: an absent map classifies every
    # candidate `unknown`, which gate 3 refuses (fail closed). It IS logged
    # loudly below so a zero harvest is never silent.
    host_map_ok=1
    host_map_build || host_map_ok=0
    pre_count="$(printf '%s\n' "$CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"
    # FAIL-CLOSED (#947): if the map failed to build, has_live_pi_descendant()
    # and has_live_child() both answer "no" for EVERY pid (an absent row is
    # never read as safe-to-kill by accident — but an absent MAP is). That
    # silently disables the orchestrating-skip above AND the #947
    # no-live-child guard, i.e. a session running tool/sub-agent work could be
    # reaped. An empty ps table (no candidates) is not an error — only a
    # failed build with work to decide on.
    if [ "$pre_count" -gt 0 ] && [ "$descendant_map_ok" = 0 ]; then
        echo "FAIL-CLOSED abort: descendant map unavailable (exit 3)" >&2
        log "FAIL-CLOSED abort: descendant map unavailable (exit 3)"
        log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS CANDIDATES=$pre_count STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK KILLED=0 YIELD=0"
        exit 3
    fi
    # gate 3 (#1207): an unbuildable host map is fail-closed (every candidate
    # classifies `unknown` and is refused), NOT an abort — but a zero harvest
    # caused by a broken map must not read as the intended zero harvest, so it
    # is said out loud rather than left to the footer counters.
    if [ "$pre_count" -gt 0 ] && [ "$host_map_ok" = 0 ]; then
        say "⚠️ GATE 3: candidate-ancestry map unavailable — every candidate is fail-closed report-only (unknown); NOTHING can be signalled this pass."
        log "GATE3 host-class map unavailable — every candidate fail-closed report-only (unknown)"
    fi

    # candidates==0 => skip the store read entirely (fail-closed abort only
    # when candidates exist); still write the MODE= footer (job proof).
    if [ -n "$CANDIDATES" ]; then
        if ! store_read; then
            log "STORE read failed (attempt 1) — retrying once"
            sleep 1
            if ! store_read; then
                echo "FAIL-CLOSED abort: cmux store missing/corrupt (attempt 2, exit 3)" >&2
                log "FAIL-CLOSED abort: cmux store missing/corrupt (attempt 2, exit 3)"
                log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS CANDIDATES=$pre_count STUCK=0 STUCK_RSS=0 STUCK_ARMED=$REAP_REAP_STUCK KILLED=0 YIELD=0"
                exit 3
            fi
        fi
        classify_candidates "$now" 1
    else
        say "(no tty'd pi candidates — store read skipped)"
    fi

    # ── STUCK audit block (#947): the population the cmux veto holds forever.
    # Fail-closed default = reported, never signaled; REAP_REAP_STUCK=1 arms
    # it. Surfacing this is the point: exit 0 with a ~2%-of-target reap must
    # not read as health while a large provably-frozen set sits vetoed.
    if [ "$STUCK_COUNT" -gt 0 ]; then
        say ""
        say "⚠️ STUCK: ${STUCK_COUNT} provably-frozen session(s), ~$((STUCK_RSS / 1024))MB — non-idle cmux record with its OWN updatedAt older than ${REAP_STUCK_HOURS}h:"
        local srow spid stty srss sidle srec ssid sveto
        while IFS= read -r srow; do
            [ -n "$srow" ] || continue
            spid="$(printf '%s' "$srow" | cut -d'|' -f1)"
            stty="$(printf '%s' "$srow" | cut -d'|' -f2)"
            srss="$(printf '%s' "$srow" | cut -d'|' -f3)"
            sidle="$(printf '%s' "$srow" | cut -d'|' -f4)"
            srec="$(printf '%s' "$srow" | cut -d'|' -f5)"
            ssid="$(printf '%s' "$srow" | cut -d'|' -f6)"
            sveto="$(printf '%s' "$srow" | cut -d'|' -f7)"
            say "   pid=$spid tty=$stty rss=${srss}KB jsonl_idle=${sidle}h record_age=${srec}h session=$ssid ($sveto)"
        done <<<"$STUCK_CANDIDATES"
        if [ "$REAP_REAP_STUCK" = 1 ]; then
            say "   → ARMED (REAP_REAP_STUCK=1): the arm is on; any row candidate-ancestry gate 3 refuses is still report-only (see the GATE 3 line below)."
        else
            say "   → NOT reaped (fail-closed). Re-run with --reap-stuck / REAP_REAP_STUCK=1 to reap this set."
        fi
        log "STUCK count=$STUCK_COUNT rss=$STUCK_RSS hours=$REAP_STUCK_HOURS armed=$REAP_REAP_STUCK"
    fi

    # ── gate 3 audit block (#1207): the candidate-ancestry decision IN WORDS.
    # The census (classified / by ground) and the SUPPRESSION count (refusals
    # that happened at an eligibility site, i.e. changed the pass's outcome)
    # are reported separately, so a zero harvest another gate produced is never
    # attributed to gate 3. `allowed` is non-zero only when the mutation is
    # present (the suite's RED control), hence the conditional wording — and the
    # zero-harvest sentence additionally requires a NON-EMPTY census
    # (GATE3_REFUSED_TOTAL > 0) AND a non-zero SUPPRESSION count
    # (GATE3_SUPPRESSED > 0): a pass where every candidate was excluded before
    # the census is a zero gate 3 never produced, and a census that classified a
    # candidate but refused none at an eligibility site is a zero ANOTHER gate
    # produced — neither may be attributed to gate 3.
    if [ "$pre_count" -gt 0 ]; then
        say ""
        say "GATE 3 (candidate-ancestry): classified $((GATE3_REFUSED_TOTAL + GATE3_ALLOWED)) live candidate(s) — human-terminal=${GATE3_REFUSED_HUMAN}, cmux-rooted=${GATE3_REFUSED_CMUX}, unknown/unresolvable=${GATE3_REFUSED_UNKNOWN}, allowed=${GATE3_ALLOWED}."
        say "   → suppressed at an eligibility site: ${GATE3_SUPPRESSED} (0 means every candidate was already excluded by another gate; a refusal recorded here is one that changed the pass's outcome)."
        if [ "$GATE3_ALLOWED" -eq 0 ] && [ "$GATE3_REFUSED_TOTAL" -gt 0 ] && [ "$GATE3_SUPPRESSED" -gt 0 ]; then
            say "   → no chain class is authorized, so the harvest for this population is ZERO BY DECISION, not by fault: the recorded rule keeps every class report-only because cmux is the fleet's own workspace host and nothing on this box records who spawned a pane, so the owner's own interactive pane is indistinguishable from a fleet lane. Gate 3 can only refuse — it never authorizes a signal."
        fi
        log "GATE3 classified=$((GATE3_REFUSED_TOTAL + GATE3_ALLOWED)) human=$GATE3_REFUSED_HUMAN cmux=$GATE3_REFUSED_CMUX unknown=$GATE3_REFUSED_UNKNOWN allowed=$GATE3_ALLOWED suppressed=$GATE3_SUPPRESSED"
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
    post_ps_ok=1
    # The post-pass read feeds the POST/RESIDUAL diagnostics only (no kill
    # decision remains), so a failure is not fatal — but it must NOT be
    # reported as a fresh count: a stale candidate list would make a failed
    # post-pass read look byte-identical to a clean one. (#947 review P2)
    if [ "$PS_RC" != 0 ]; then
        post_ps_ok=0
        log "POST-PASS ps enumeration failed (rc=$PS_RC) — POST/RESIDUAL degraded"
    fi
    self_ancestors_from_table
    # Post-pass map: only feeds the RESIDUAL diagnostic (no kill decision is
    # left to make), so a build failure here is logged, not fatal — the
    # initial build above is the one that gates signaling.
    descendant_map_build || log "POST-PASS descendant map unavailable — RESIDUAL diagnostic degraded"
    host_map_build || log "POST-PASS gate-3 host map unavailable — RESIDUAL classification degraded"
    if [ "$post_ps_ok" = 1 ]; then
        post_count="$(printf '%s\n' "$CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')"
    else
        post_count="?"
    fi
    residual_count=0
    if [ "$MODE" = apply ]; then
        if [ "$post_ps_ok" = 1 ] && [ -n "$CANDIDATES" ]; then
            classify_candidates "$now" 0
            residual_count="$REAP_COUNT"
        elif [ "$post_ps_ok" != 1 ]; then
            residual_count="?"
        fi
    else
        if [ "$post_ps_ok" = 1 ]; then
            residual_count="$REAP_COUNT"
        else
            residual_count="?"
        fi
    fi

    if [ "$MODE" = dry-run ]; then
        say "DRY-RUN — no signals sent"
    fi
    log "MODE=$MODE NOW=$now THRESHOLD=$REAP_IDLE_HOURS STUCK_HOURS=$REAP_STUCK_HOURS STUCK=$STUCK_COUNT STUCK_RSS=$STUCK_RSS STUCK_ARMED=$REAP_REAP_STUCK CANDIDATES=$pre_count PRE=$pre_count POST=$post_count RESIDUAL=$residual_count KILLED=$KILLED YIELD=$YIELD_RSS GATE3_CLASSED=$((GATE3_REFUSED_TOTAL + GATE3_ALLOWED)) GATE3_HUMAN=$GATE3_REFUSED_HUMAN GATE3_CMUX=$GATE3_REFUSED_CMUX GATE3_UNKNOWN=$GATE3_REFUSED_UNKNOWN GATE3_ALLOWED=$GATE3_ALLOWED GATE3_SUPPRESSED=$GATE3_SUPPRESSED"
    if [ "$MODE" = apply ]; then
        echo "armed pass complete: KILLED=$KILLED YIELD_RSS=${YIELD_RSS}KB RESIDUAL=$residual_count STUCK=$STUCK_COUNT"
    fi
    exit 0
}

parse_args "$@"
run
