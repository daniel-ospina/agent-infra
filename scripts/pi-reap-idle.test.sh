#!/usr/bin/env bash
# pi-reap-idle.test.sh — self-check for scripts/pi-reap-idle.sh (#469).
#
# Run: bash scripts/pi-reap-idle.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: fake PS_BIN /
# KILL_BIN / DATE_BIN shims + temp CMUX_STATE_DIR / PI_SESSIONS_DIR / HOME /
# REAP_LOG — never signals a real process, never touches real ~/.cmuxterm or
# ~/.pi. Coverage (plan Task 5 fixture packs A/B/C, CI-safe subset):
#   pack A  parser: giant ~150KB lines, trailing partial, empty/whitespace/
#           garbage/missing files, newest-undatable-line abstain, .228Z /
#           +00:00 / numeric timestamps, JSON shape (probe is parser-only:
#           idle_proven = "a parseable last entry exists"; the strict->
#           24h boundary incl. exact-24h lives at classify — C15)
#   pack B  join/veto/resolution: fake-ps row sets (self tty/ancestors,
#           non-pi, headless `??` pi), --list contract, 2-records-per-pid,
#           allowlist veto vocabulary on BOTH keys + AND, stale-sibling
#           union-exclusion both directions, neutral no-JSONL twin (abstain
#           != veto), incarnation fence positive + negative (±3s), lone
#           no-JSONL abstain, marathon child skip, zombie not-a-skip,
#           PI_SESSION_ID veto, resolution (nested-slash cwd encoding,
#           uuid-suffix fallback), stale .tmp ignored, store missing/
#           corrupt/persistent/transient, zero-candidates skip-store+footer
#   pack C  kill/lock/log: dry-run footer + no signals; armed TERM +
#           MODE=apply footer + group shape; pgid!=pid per-pid shape; SIGKILL
#           survivor escalation (both directions); ESRCH; settle activity +
#           pid-reuse vetos (deterministic two-candidate side effects); lock
#           block + stale-break; RESIDUAL semantics (fresh-read, dry-run =
#           would-be-reaped); strict-> boundary; threshold override; DATE_BIN
#           branch seam (BSD forced on any platform via capability probe)
# Real-tty assertions are NOT in this suite (the self-skip contract is
# exercised by shims); real-tty verification is dev-box steps (plan/scope).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-reap-idle.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_reap_eligible() { if printf '%s' "$1" | grep -q "REAP-ELIGIBLE"; then ok "$2"; else bad "$2"; fi }
assert_skipped_reason() { if printf '%s' "$1" | grep -qF -- "$3"; then ok "$2"; else bad "$2 (missing reason: $3)"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# field_of <probe-out> <field> — probe_jsonl emits ONE dict per file per line
field_of() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())[sys.argv[1]])' "$2"
}

# ── real UTC epochs (python-computed so expectations can never drift) ──
# Anchor: "2026-09-05T02:00:00Z" = the pass clock (REAP_NOW_EPOCH default).
NOW="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-05T02:00:00+00:00").timestamp()))')"
E_SEP3_2000="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-03T20:00:00+00:00").timestamp()))')"  # 30h idle anchor
E_SEP4_1200="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-04T12:00:00+00:00").timestamp()))')"
E_SEP4_0200="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-04T02:00:00+00:00").timestamp()))')"  # exactly 24h before NOW
E_SEP5_0100="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-05T01:00:00+00:00").timestamp()))')"
E_SEP4_1159="$((E_SEP4_1200 - 1))"
E_SEP4_1203="$((E_SEP4_1200 + 3))"
E_SEP4_1157="$((E_SEP4_1200 - 3))"
E_SEP4_1204="$((E_SEP4_1200 + 4))"
E_SEP4_1156="$((E_SEP4_1200 - 4))"
ACTIVE_1H="$((NOW - 3600))"
BOUNDARY_EXACT="$((NOW - 86400))"     # = E_SEP4_0200

# ── shims ──────────────────────────────────────────────────────────────
# PS_BIN: bulk call prints FAKE_PS_SOURCE rows + injects a self row (pid = the
# reaper, found via our own PPID) stamped FAKE_SELF_TTY, plus an ancestor
# chain to pid 1. Detail call (-o lstart=,pgid=,stat=,rss= -p PID) emits the
# row's ps-style fields IN ORDER: lstart tokens, pgid, stat, rss (identical
# shape to real `ps -o lstart=,pgid=,stat=,rss=`).
mkdir -p "$T/bin"
cat > "$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
SOURCE="${FAKE_PS_SOURCE:?}"
if [ "${1:-}" = "-axo" ]; then
    sed 's/^ *//' "$SOURCE"
    # Inject a self row whose pid is the REAPER, not the shim. The reaper
    # exports PI_REAP_SELF_PID=$$ on its bulk ps call (real ps ignores it) —
    # deterministic, no real-process ancestry walk (walks race under fork
    # churn: a stranded walk emits the row at the wrong pid, silently
    # disabling B9's self-tty/ancestor skips). Fall back to $PPID when the
    # var is absent. Ancestor rows 400000/400001 follow so the ancestor-walk
    # self-exclusion is exercised deterministically.
    SELF_PID="${PI_REAP_SELF_PID:-$PPID}"
    echo "$SELF_PID 400000 400000 ${FAKE_SELF_TTY:-tts000} R 0 0 /usr/bin/env bash pi-reap-idle-self"
    echo "400000 400001 400000 ${FAKE_SELF_TTY:-tts000} S 0 0 /bin/launchd-self"
    echo "400001 1 400001 ?? S 0 0 /sbin/launchd"
    exit 0
fi
PID=""
while [ $# -gt 0 ]; do
    [ "$1" = "-p" ] && { PID="$2"; shift 2; continue; }
    shift
done
[ -n "$PID" ] || exit 1
awk -v p="$PID" '$1==p {
    for(i=5;i<=NF;i++){ if($i ~ /^[0-9]{4}$/){ yr=i; break } }
    if(!yr) exit 1
    for(j=5;j<=yr;j++) printf "%s ", $j     # lstart tokens incl. year
    printf "%s %s %s\n", $3, $(yr+1), $(yr+2)   # pgid stat rss
    exit 0
}' "$SOURCE"
SHIM
chmod +x "$T/bin/ps"

# KILL_BIN: logs each signal; FAKE_KILL_SIDE script runs first (deterministic
# settle side effects); FAKE_ESRCH_PIDS honored.
cat > "$T/bin/kill" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_KILL_LOG:?}" ] || exit 0
echo "kill $*" >> "$FAKE_KILL_LOG"
if [ -n "${FAKE_KILL_SIDE:-}" ] && [ -x "$FAKE_KILL_SIDE" ]; then
    "$FAKE_KILL_SIDE" "$@" >> "$FAKE_KILL_LOG.side" 2>&1 || true
fi
SIG="${1#-}"
TARGET="${2#-}"
case "$SIG" in TERM|KILL) ;; *) exit 0 ;; esac
if [ -n "${FAKE_ESRCH_PIDS:-}" ] && printf '%s\n' "$FAKE_ESRCH_PIDS" | grep -qx "$TARGET"; then
    exit 1
fi
exit 0
SHIM
chmod +x "$T/bin/kill"

# DATE_BIN: FAKE_DATE_MODE=bsd accepts only the BSD -j shape; =gnu only -d.
# Lookup table FAKE_DATE_LOOKUP ("lstart<TAB>epoch") returns deterministic
# epochs. The capability probe is answered in both modes.
cat > "$T/bin/date" <<'SHIM'
#!/usr/bin/env bash
MODE="${FAKE_DATE_MODE:-bsd}"
LOOKUP="${FAKE_DATE_LOOKUP:-}"
case "$MODE" in
    bsd) case "$*" in *"-j -f"*) ;; *) exit 1 ;; esac ;;
    gnu) case "$*" in *"-d"*) ;; *) exit 1 ;; esac ;;
esac
case "$*" in
    *"Sat Jan  1 00:00:00 2000"*) echo 946684800; exit 0 ;;
esac
if [ -n "$LOOKUP" ]; then
    ARG=""
    for a in "$@"; do
        case "$a" in %*|+%s|-j|-f|-d) continue ;; esac
        ARG="$a"
    done
    HIT="$(awk -F'\t' -v k="$ARG" '$1==k {print $2}' "$LOOKUP" | head -1)"
    [ -n "$HIT" ] && { echo "$HIT"; exit 0; }
    exit 1
fi
exit 1
SHIM
chmod +x "$T/bin/date"

make_lookup() { # <out-file> — deterministic lstart -> epoch map (real UTC).
    # Keys are single-space-normalized (fixture lstart strings use unpadded
    # day-of-month "Sep 3") so byte-match is guaranteed regardless of ps's
    # %e padding style.
    tr -s ' ' > "$1" <<LOOK
Thu Sep  3 20:00:00 2026	${E_SEP3_2000}
Fri Sep  4 12:00:00 2026	${E_SEP4_1200}
Fri Sep  4 11:59:57 2026	${E_SEP4_1157}
Fri Sep  4 12:00:03 2026	${E_SEP4_1203}
Fri Sep  4 11:59:56 2026	${E_SEP4_1156}
Fri Sep  4 12:00:04 2026	${E_SEP4_1204}
Sat Sep  5 01:00:00 2026	${E_SEP5_0100}
Sat Sep  5 02:00:00 2026	${NOW}
LOOK
}

# Environment builder. NOTE: macOS FS is case-insensitive — never create a
# `home` dir and a `HOME` file in the same base (they collide).
mk_env() { mkdir -p "$T/$1/home" "$T/$1/state"; }

run_reaper() { # <env-name> args... — reaper with full shim env
    local envname="$1"; shift
    HOME="$T/$envname/home" \
    PATH="$T/bin:$PATH" \
    PS_BIN="$T/bin/ps" KILL_BIN="$T/bin/kill" DATE_BIN="${DATE_BIN:-$T/bin/date}" \
    FAKE_PS_SOURCE="$T/$envname/ps-source" \
    FAKE_SELF_TTY="${FAKE_SELF_TTY:-tts900}" \
    FAKE_KILL_LOG="$T/$envname/kill.log" \
    FAKE_ESRCH_PIDS="${FAKE_ESRCH_PIDS:-}" \
    FAKE_KILL_SIDE="${FAKE_KILL_SIDE:-}" \
    FAKE_DATE_MODE="${FAKE_DATE_MODE:-bsd}" \
    FAKE_DATE_LOOKUP="$T/$envname/date.lookup" \
    CMUX_STATE_DIR="$T/$envname/cmux" \
    PI_SESSIONS_DIR="$T/$envname/sessions" \
    REAP_LOG="$T/$envname/reap.log" \
    REAP_LOCK_STALE_SECONDS="${REAP_LOCK_STALE_SECONDS:-5}" \
    bash "$REAPER" "$@"
}

# ps row builder: pid ppid pgid tty lstart stat rss cmd
psrow() { printf '%s %s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; }

cmux_store() { # <env-name> — flat sessions JSON on stdin; wraps into the REAL
    # pi-hook store shape {version, agentHookFailureReportTimestamps, sessions}
    mkdir -p "$T/$1/cmux"
    { printf '%s' '{"version":1,"agentHookFailureReportTimestamps":{},"sessions":'; cat; printf '%s' '}' ; } > "$T/$1/cmux/pi-hook-sessions.json"
}

session_jsonl() { # <env-name> <cwd> <sessionId> <startedAt> <lastTs>
    local envname="$1" cwd="$2" sid="$3" started="$4" last="$5"
    local enc dir
    enc="$(printf '%s' "$cwd" | sed 's|^/||; s|/|-|g')"
    dir="$T/$envname/sessions/--${enc}--"
    mkdir -p "$dir"
    cat > "$dir/${started}_${sid}.jsonl"
    printf '{"type":"message","role":"user","timestamp":"%s","content":"hi"}\n' "$last" >> "$dir/${started}_${sid}.jsonl"
}

# common ps-row + session fixture for one reap-eligible candidate at pid $1
idle30h_fixture() { # <env-name> <pid> <tty> <sid> <cwd> [extra-ps-rows...]
    local envname="$1" pid="$2" tty="$3" sid="$4" cwd="$5"; shift 5
    {
        printf '%s\n' "$(psrow "$pid" 400000 "$pid" "$tty" "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd $cwd")"
        for r in "$@"; do printf '%s\n' "$r"; done
    } > "$T/$envname/ps-source"
    printf '{"%s":{"pid":%s,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"%s"}}' "$sid" "$pid" "$E_SEP3_2000" "$cwd" | cmux_store "$envname"
    session_jsonl "$envname" "$cwd" "$sid" "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
}

echo "── pi-reap-idle.test.sh ─────────────────────────────────────────"
echo "fixture pack A: JSONL parser (--probe-jsonl)"

# A1: giant single complete line ≥150KB parses (last entry wins)
mk_env A1; mkdir -p "$T/A1/sessions"
G="$T/A1/sessions/giant.jsonl"
python3 - "$G" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in range(40):
        fh.write(json.dumps({"type":"m","timestamp":"2026-09-03T12:00:00.000Z","pad":"x"*4000})+"\n")
    fh.write(json.dumps({"type":"m","timestamp":"2026-09-03T20:00:00.000Z","pad":"x"*4000})+"\n")
PY
SZ="$(wc -c < "$G" | tr -d ' ')"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A1/r.log" bash "$REAPER" --probe-jsonl "$G")"
assert_eq "$(field_of "$OUT" idle_proven) $(field_of "$OUT" last_timestamp)" "True $E_SEP3_2000" "A1 giant ≥150KB line parses (${SZ}B)"
rm -rf "$T/A1"

# A2: trailing partial write -> previous complete line wins
mk_env A2; mkdir -p "$T/A2/sessions"
G="$T/A2/sessions/p.jsonl"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$G"
printf '%s' '{"timestamp":"2026-09-05T01:00:00.00' >> "$G"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A2/r.log" bash "$REAPER" --probe-jsonl "$G")"
assert_eq "$(field_of "$OUT" last_timestamp) $(field_of "$OUT" idle_proven)" "$E_SEP3_2000 True" "A2 trailing partial write -> previous complete line"
rm -rf "$T/A2"

# A3: empty / whitespace / garbage / missing files -> not idle (fail-closed)
mk_env A3
for CASE in empty ws garbage missing; do
    G="$T/A3/$CASE.jsonl"
    case "$CASE" in
        empty) : > "$G" ;;
        ws) printf '   \n  \n' > "$G" ;;
        garbage) printf 'not json at all\n{also no\n' > "$G" ;;
        missing) rm -f "$G" ;;
    esac
    OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A3/r.log" bash "$REAPER" --probe-jsonl "$G" 2>&1)"
    assert_eq "$(field_of "$OUT" idle_proven)" "False" "A3 $CASE file -> idle_proven False (fail-closed)"
done
rm -rf "$T/A3"

# A4: timestamp variants (.228Z, +00:00 micro, numeric epoch)
mk_env A4; mkdir -p "$T/A4/sessions"
for V in Z OFFSET NUM; do
    G="$T/A4/sessions/v$V.jsonl"
    case "$V" in
        Z)      printf '{"timestamp":"%s"}\n' "2026-09-03T20:00:00.228Z" > "$G" ;;
        OFFSET) printf '{"timestamp":"%s"}\n' "2026-09-03T20:00:00.123456+00:00" > "$G" ;;
        NUM)    printf '{"timestamp":%s}\n' "$E_SEP3_2000.5" > "$G" ;;
    esac
    OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A4/r.log" bash "$REAPER" --probe-jsonl "$G")"
    assert_eq "$(field_of "$OUT" last_timestamp)" "$E_SEP3_2000" "A4 timestamp variant $V -> $E_SEP3_2000"
done
rm -rf "$T/A4"

# A5: newest line COMPLETE but undatable -> abstain (fail-closed), never date
# the session by an older entry (policy: missing/unparseable => never idle)
mk_env A5; mkdir -p "$T/A5/sessions"
G="$T/A5/sessions/u.jsonl"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$G"
printf '%s\n' '{"type":"activity","note":"no timestamp field"}' >> "$G"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A5/r.log" bash "$REAPER" --probe-jsonl "$G")"
assert_eq "$(field_of "$OUT" idle_proven)" "False" "A5 undatable newest line abstains (no older-line fallback)"
assert_eq "$(field_of "$OUT" reason)" "unparseable" "A5 reason=unparseable"
rm -rf "$T/A5"

# A6: newest line valid JSON but a SCALAR (42/true/"str"/[1,2]) — not a record
# -> fail-closed unparseable, no crash, one row still emitted for the file
mk_env A6; mkdir -p "$T/A6/sessions"
for SC in 42 true 'null' '"astring"'; do
    G="$T/A6/sessions/s$SC.jsonl"
    printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$G"
    printf '%s\n' "$SC" >> "$G"
    OUT="$(REAP_NOW_EPOCH=$NOW REAP_LOG="$T/A6/r.log" bash "$REAPER" --probe-jsonl "$G" 2>&1)"
    assert_eq "$(field_of "$OUT" idle_proven)" "False" "A6 scalar-tail $SC -> not idle (no crash)"
    assert_eq "$(field_of "$OUT" reason)" "unparseable" "A6 scalar-tail $SC reason=unparseable"
done
rm -rf "$T/A6"

echo "fixture pack B: cmux join + vetoes + resolution (dry-run verdicts)"
mk_env B
make_lookup "$T/B/date.lookup"
FAKE_SELF_TTY=tts900

# B1: single idle-30h session -> REAP-ELIGIBLE; dry-run RESIDUAL=1 KILLED=0
idle30h_fixture B 1111 ttys100 b1 /Users/t/b1
: > "$T/B/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_reap_eligible "$OUT" "B1 idle-30h single session REAP-ELIGIBLE"
assert_contains "$(cat "$T/B/reap.log")" "RESIDUAL=1" "B1 dry-run RESIDUAL=1 (would-be-reaped)"
assert_contains "$(cat "$T/B/reap.log")" "MODE=dry-run" "B1 footer MODE=dry-run"
assert_contains "$OUT" "DRY-RUN — no signals sent" "B1 DRY-RUN warning line"
[ ! -s "$T/B/kill.log" ] && ok "B1 zero signals in dry-run" || bad "B1 zero signals in dry-run"
rm -rf "$T/B/sessions"

# B2: 2-records-per-pid — idle twin + running twin SAME pidStartSeconds => veto
idle30h_fixture B 1111 ttys100 b2 /Users/t/b2
printf '%s' '{"b2":{"pid":1111,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b2"},"b2r":{"pid":1111,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"running","cwd":"/Users/t/b2"}}' | cmux_store B
: > "$T/B/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B2 running twin vetoes (no reap)"
assert_skipped_reason "$OUT" "B2 veto reason recorded" "allowlist lifecycle=running runtimeStatus=running"
rm -rf "$T/B/sessions"

# B3: allowlist veto vocabulary — each value on each key vetoes (parametrized)
VETO_CASES=(
    "agentLifecycle:running runtimeStatus:idle"
    "agentLifecycle:idle runtimeStatus:running"
    "agentLifecycle:idle runtimeStatus:needsInput"
    "agentLifecycle:needsInput runtimeStatus:idle"
    "agentLifecycle:unknown runtimeStatus:idle"
    "agentLifecycle:idle runtimeStatus:unknown"
    "agentLifecycle:idle runtimeStatus:error"
    "agentLifecycle:idle runtimeStatus:None"
    "agentLifecycle:idle runtimeStatus:absent"
)
B3N=0
for VC in "${VETO_CASES[@]}"; do
    B3N=$((B3N+1))
    AL="${VC%% *}"; AL="${AL#agentLifecycle:}"
    RS="${VC##*runtimeStatus:}"
    PID=$((2222 + B3N))
    printf '%s\n' "$(psrow $PID 400000 $PID ttys1$B3N "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /x")" > "$T/B/ps-source"
    if [ "$RS" = absent ]; then
        printf '{"v":{"pid":%s,"pidStartSeconds":%s,"agentLifecycle":"%s","runtimeStatus":"idle","cwd":"/x"}}' "$PID" "$E_SEP3_2000" "$AL" | cmux_store B
    else
        printf '{"v":{"pid":%s,"pidStartSeconds":%s,"agentLifecycle":"%s","runtimeStatus":"%s","cwd":"/x"}}' "$PID" "$E_SEP3_2000" "$AL" "$RS" | cmux_store B
    fi
    OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
    assert_not_contains "$OUT" "REAP-ELIGIBLE" "B3 veto al=$AL rs=$RS (never reaped)"
done
rm -rf "$T/B/sessions" 2>/dev/null || true

# B4: stale-sibling union-exclusion BOTH directions
# (a) matching idle + stale (>±3s) running sibling => REAPED
printf '%s\n' "$(psrow 3333 400000 3333 ttys200 "Thu Sep  3 20:00:00 2026" S 40000 "/usr/local/bin/pi --cwd /Users/t/b4")" > "$T/B/ps-source"
printf '%s' '{"b4":{"pid":3333,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b4"},"b4s":{"pid":3333,"pidStartSeconds":'$E_SEP4_1204',"agentLifecycle":"running","runtimeStatus":"running","cwd":"/Users/t/b4"}}' | cmux_store B
session_jsonl B /Users/t/b4 b4 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_reap_eligible "$OUT" "B4a matching idle + stale running sibling -> REAPED (stale neither proves nor vetoes)"
# (b) matching running + stale idle sibling => skipped for MATCHING reason
printf '%s' '{"b4":{"pid":3333,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"running","cwd":"/Users/t/b4"},"b4s":{"pid":3333,"pidStartSeconds":'$E_SEP4_1204',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b4"}}' | cmux_store B
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B4b matching running vetoes regardless of stale idle sibling"
assert_skipped_reason "$OUT" "B4b reason references matching record" "allowlist lifecycle=running"
rm -rf "$T/B/sessions"

# B5: neutral no-JSONL twin — JSONL-backed idle twin + no-session sibling => REAPED
printf '%s\n' "$(psrow 4444 400000 4444 ttys201 "Thu Sep  3 20:00:00 2026" S 20000 "/usr/local/bin/pi --cwd /Users/t/alpha")" > "$T/B/ps-source"
printf '%s' '{"b5":{"pid":4444,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/alpha"},"b5g":{"pid":4444,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/ghost-no-files"}}' | cmux_store B
session_jsonl B /Users/t/alpha b5 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_reap_eligible "$OUT" "B5 no-JSONL twin abstains, does not veto -> REAPED"
rm -rf "$T/B/sessions"

# B6: lone no-JSONL record abstains (no proof -> no reap)
printf '%s\n' "$(psrow 5555 400000 5555 ttys202 "Thu Sep  3 20:00:00 2026" S 10000 "/usr/local/bin/pi --cwd /Users/t/onlyghost")" > "$T/B/ps-source"
printf '%s' '{"b6":{"pid":5555,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/onlyghost"}}' | cmux_store B
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B6 lone no-JSONL abstains (fail-closed no-proof no-kill)"
assert_skipped_reason "$OUT" "B6 abstain reason" "no-jsonl-proof"

# B7: incarnation fence positive side (2s/3s inside tolerance) + negative (4s)
for OFFSET in 2 -2 3 -3; do
    printf '%s\n' "$(psrow 6666 400000 6666 ttys203 "Thu Sep  3 20:00:00 2026" S 20000 "/usr/local/bin/pi --cwd /Users/t/b7")" > "$T/B/ps-source"
    PSS=$((E_SEP3_2000 + OFFSET))
    printf '{"b7":{"pid":6666,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b7"}}' "$PSS" | cmux_store B
    session_jsonl B /Users/t/b7 b7 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
    OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
    assert_reap_eligible "$OUT" "B7 fence offset ${OFFSET}s -> REAPED (within ±3s)"
    rm -rf "$T/B/sessions"
done
printf '%s\n' "$(psrow 6666 400000 6666 ttys203 "Thu Sep  3 20:00:00 2026" S 20000 "/usr/local/bin/pi --cwd /Users/t/b7")" > "$T/B/ps-source"
printf '{"b7":{"pid":6666,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b7"}}' "$((E_SEP3_2000 + 4))" | cmux_store B
session_jsonl B /Users/t/b7 b7 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B7 fence offset +4s -> incarnation-unmatched (not reaped)"
rm -rf "$T/B/sessions"

# B8: marathon-child skip + zombie-not-a-skip
CHILD_LIVE="$(psrow 7778 7777 7777 ttys204 "Sat Sep  5 01:00:00 2026" R 0 "/usr/local/bin/pi -p --cwd /Users/t/b8")"
CHILD_ZOMBIE="$(psrow 7778 7777 7777 ttys204 "Sat Sep  5 01:00:00 2026" Z 0 "/usr/local/bin/pi -p --cwd /Users/t/b8")"
printf '%s\n' "$(psrow 7777 400000 7777 ttys204 "Thu Sep  3 20:00:00 2026" S 50000 "/usr/local/bin/pi --cwd /Users/t/b8")" "$CHILD_LIVE" > "$T/B/ps-source"
printf '%s' '{"b8":{"pid":7777,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b8"}}' | cmux_store B
session_jsonl B /Users/t/b8 b8 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B8 marathon parent with live pi descendant skipped"
assert_skipped_reason "$OUT" "B8 skip reason recorded" "orchestrating"
printf '%s\n' "$(psrow 7777 400000 7777 ttys204 "Thu Sep  3 20:00:00 2026" S 50000 "/usr/local/bin/pi --cwd /Users/t/b8")" "$CHILD_ZOMBIE" > "$T/B/ps-source"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_reap_eligible "$OUT" "B8 zombie descendant is NOT a skip (parent still reap-eligible)"
rm -rf "$T/B/sessions"

# B9: own tty / ancestor / PI_SESSION_ID hard skips — the own-tty candidate's
# tty must BOTH pass the ttys* candidate filter AND equal FAKE_SELF_TTY.
FAKE_SELF_TTY=ttys900
printf '%s\n' "$(psrow 8881 400000 8881 ttys900 "Thu Sep  3 20:00:00 2026" S 40000 "/usr/local/bin/pi --cwd /Users/t/b9o")" \
               "$(psrow 400000 400001 400000 ttys206 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/b9a")" \
               "$(psrow 8882 400000 8882 ttys207 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/b9m")" > "$T/B/ps-source"
printf '%s' '{"b9o":{"pid":8881,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b9o"},"b9a":{"pid":400000,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b9a"},"b9m":{"pid":8882,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/b9m"}}' | cmux_store B
session_jsonl B /Users/t/b9o b9o "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl B /Users/t/b9a b9a "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl B /Users/t/b9m b9m "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
OUT="$(PI_SESSION_ID=b9m REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --dry-run 2>&1)"
assert_contains "$OUT" "8881 tty=ttys900 SKIP self-tty" "B9 own-tty candidate skipped"
assert_contains "$OUT" "400000 tty=ttys206 SKIP self-tty" "B9 ancestor candidate skipped"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "B9 own-session + self-tty + ancestor all skipped (zero reap)"
assert_skipped_reason "$OUT" "B9 PI_SESSION_ID veto reason" "own-session"
FAKE_SELF_TTY=tts900
rm -rf "$T/B/sessions"

# B10: headless `??` pi + non-pi tty rows never candidates; --list quiet
printf '%s\n' "$(psrow 9991 1 9991 ?? "Thu Sep  3 20:00:00 2026" S 50000 "/usr/local/bin/pi --cwd /headless")" \
               "$(psrow 9992 1 9992 ttys208 "Thu Sep  3 20:00:00 2026" S 50000 "/usr/bin/vim notes.md")" > "$T/B/ps-source"
printf '%s' '{}' | cmux_store B
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper B --list 2>&1)"
assert_not_contains "$OUT" "9991" "B10 headless ?? pi never listed"
assert_not_contains "$OUT" "9992" "B10 non-pi tty never listed"

echo "fixture pack C: kill/lock/log (armed)"
mk_env C
make_lookup "$T/C/date.lookup"
FAKE_SELF_TTY=tts900

# C1: armed one killable -> TERM group -pgid; KILLED=1 POST=PRE-1 RESIDUAL=0.
# The KILL side script removes the pid from the fake-ps source on TERM so the
# FRESH post-pass read no longer lists it => RESIDUAL=0 by construction and no
# SIGKILL (row gone at the survivor probe).
idle30h_fixture C 12121 ttys300 c1 /Users/t/c1
cat > "$T/C/kill-side.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -TERM) sed -i.bak '/^12121 /d' "$FAKE_PS_SOURCE"; rm -f "$FAKE_PS_SOURCE.bak" ;;
esac
SH
chmod +x "$T/C/kill-side.sh"
: > "$T/C/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C/kill-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_contains "$(cat "$T/C/kill.log")" "kill -TERM -12121" "C1 armed group TERM -pgid shape"
assert_contains "$(cat "$T/C/reap.log")" "MODE=apply" "C1 footer MODE=apply"
assert_contains "$(cat "$T/C/reap.log")" "KILLED=1" "C1 KILLED=1"
assert_contains "$(cat "$T/C/reap.log")" "RESIDUAL=0" "C1 RESIDUAL=0 after clean armed pass (fresh-read)"
assert_contains "$(cat "$T/C/reap.log")" "YIELD=30000" "C1 YIELD=30000 (yield = Σ per-target rss)"
assert_contains "$OUT" "armed pass complete" "C1 apply summary on stdout"
rm -rf "$T/C/sessions" "$T/C/kill-side.sh"

# C2: dry-run RESIDUAL semantics — reap-eligible present => RESIDUAL=1 KILLED=0
idle30h_fixture C 12122 ttys301 c2 /Users/t/c2
: > "$T/C/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --dry-run 2>&1)"
assert_contains "$(cat "$T/C/reap.log")" "RESIDUAL=1" "C2 dry-run RESIDUAL=1 (would-be-reaped)"
assert_contains "$(cat "$T/C/reap.log")" "KILLED=0" "C2 dry-run KILLED=0"
[ ! -s "$T/C/kill.log" ] && ok "C2 no signals" || bad "C2 no signals"
rm -rf "$T/C/sessions"

# C3: pgid != pid -> per-pid TERM shape (NOT -pgid)
printf '%s\n' "$(psrow 12123 400000 9000 ttys302 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c3")" > "$T/C/ps-source"
printf '{"c3":{"pid":12123,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c3"}}' "$E_SEP3_2000" | cmux_store C
session_jsonl C /Users/t/c3 c3 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
: > "$T/C/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_contains "$(cat "$T/C/kill.log")" "kill -TERM 12123" "C3 pgid!=pid per-pid TERM shape"
assert_not_contains "$(cat "$T/C/kill.log")" "kill -TERM -9000" "C3 no group signal for non-leader"
rm -rf "$T/C/sessions"

# C4: SIGKILL survivor escalation — pid STILL listed after TERM => SIGKILL
idle30h_fixture C 12124 ttys303 c4 /Users/t/c4
: > "$T/C/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_contains "$(cat "$T/C/kill.log")" "kill -KILL -12124" "C4 survivor still listed -> SIGKILL recorded"
rm -rf "$T/C/sessions"

# C5: no SIGKILL when pid gone after TERM — KILL side script advances the source
idle30h_fixture C 12125 ttys304 c5 /Users/t/c5
cat > "$T/C/kill-side.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -TERM) sed -i.bak '/^12125 /d' "$FAKE_PS_SOURCE"; rm -f "$FAKE_PS_SOURCE.bak" ;;
esac
SH
chmod +x "$T/C/kill-side.sh"
: > "$T/C/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C/kill-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_not_contains "$(cat "$T/C/kill.log")" "kill -KILL" "C5 pid gone after TERM -> no SIGKILL"
assert_contains "$(cat "$T/C/reap.log")" "KILLED=1" "C5 graceful exit still counted KILLED=1"
rm -rf "$T/C/sessions" "$T/C/kill-side.sh"

# C6: settle-gate activity veto — two candidates A+B; A's TERM (KILL_BIN side
# effect) appends a fresh JSONL entry to B's file => B's LATER settle re-verify
# deterministically sees advanced activity and suppresses (no wall-clock race).
printf '%s\n' "$(psrow 12126 400000 12126 ttys305 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c6a")" \
               "$(psrow 12129 400000 12129 ttys305 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c6b")" > "$T/C/ps-source"
printf '%s' '{"c6a":{"pid":12126,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c6a"},"c6b":{"pid":12129,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c6b"}}' | cmux_store C
session_jsonl C /Users/t/c6a c6a "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl C /Users/t/c6b c6b "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
cat > "$T/C/settle-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM) printf '%s\n' '{"timestamp":"2026-09-05T01:00:00.000Z","x":"fresh"}' >> "$T/C/sessions/--Users-t-c6b--/${E_SEP3_2000}_c6b.jsonl" ;;
esac
SH
chmod +x "$T/C/settle-side.sh"
: > "$T/C/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C/settle-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_contains "$(cat "$T/C/kill.log")" "kill -TERM -12126" "C6 candidate A TERM'd normally"
assert_not_contains "$(cat "$T/C/kill.log")" "kill -TERM -12129" "C6 candidate B settle-suppressed (no TERM)"
assert_contains "$(cat "$T/C/reap.log")" "activity advanced" "C6 activity-advance suppress reason logged"
rm -rf "$T/C/sessions" "$T/C/settle-side.sh"

# C7: settle-gate pid-reuse veto — A's TERM rewrites B's ps row lstart => B's
# settle FRESH probe sees a changed lstart and suppresses. Only observable
# because settle re-queries ${PS_BIN}, never the pass-start snapshot.
printf '%s\n' "$(psrow 12127 400000 12127 ttys306 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c7a")" \
               "$(psrow 12130 400000 12130 ttys306 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c7b")" > "$T/C/ps-source"
printf '%s' '{"c7a":{"pid":12127,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c7a"},"c7b":{"pid":12130,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c7b"}}' | cmux_store C
session_jsonl C /Users/t/c7a c7a "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl C /Users/t/c7b c7b "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
cat > "$T/C/reuse-side.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -TERM) awk '$1!=12130' "$FAKE_PS_SOURCE" > "$FAKE_PS_SOURCE.new" && \
           printf '%s\n' "12130 400000 12130 ttys306 Sat Sep  5 01:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/c7b" >> "$FAKE_PS_SOURCE.new" && \
           mv "$FAKE_PS_SOURCE.new" "$FAKE_PS_SOURCE" ;;
esac
SH
chmod +x "$T/C/reuse-side.sh"
: > "$T/C/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C/reuse-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_contains "$(cat "$T/C/kill.log")" "kill -TERM -12127" "C7 candidate A TERM'd normally"
assert_not_contains "$(cat "$T/C/kill.log")" "kill -TERM -12130" "C7 candidate B settle-suppressed (no TERM)"
assert_contains "$(cat "$T/C/reap.log")" "incarnation changed" "C7 pid-reuse suppress reason logged"
rm -rf "$T/C/sessions" "$T/C/reuse-side.sh"

# C8: ESRCH swallowed (KILL returns 1 for the target — no crash, pass completes)
idle30h_fixture C 12128 ttys307 c8 /Users/t/c8
: > "$T/C/kill.log"
OUT="$(FAKE_ESRCH_PIDS=12128 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C --apply 2>&1)"
assert_eq "$?" "0" "C8 ESRCH path exits 0"
assert_contains "$(cat "$T/C/reap.log")" "MODE=apply" "C8 pass completes with footer"
rm -rf "$T/C/sessions"

# C9: zero tty'd-pi candidates -> exit 0; store never read (missing store OK)
mk_env C9
make_lookup "$T/C9/date.lookup"
printf '%s\n' "$(psrow 99999 1 99999 ?? "Thu Sep  3 20:00:00 2026" S 50000 "/usr/bin/vim x")" > "$T/C9/ps-source"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C9 --apply 2>&1)"
assert_eq "$?" "0" "C9 zero tty'd-pi candidates exit 0 (no store => no exit 3)"
assert_contains "$(cat "$T/C9/reap.log")" "MODE=apply" "C9 footer written to log (job proof)"
assert_contains "$(cat "$T/C9/reap.log")" "RESIDUAL=0" "C9 zero-candidate footer RESIDUAL=0"

# C10: non-pi tty rows only -> exit 0, dry-run footer CANDIDATES=0
printf '%s\n' "$(psrow 99998 1 99998 ttys308 "Thu Sep  3 20:00:00 2026" S 40000 "/usr/bin/top")" > "$T/C9/ps-source"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C9 --dry-run 2>&1)"
assert_eq "$?" "0" "C10 non-pi tty rows only -> exit 0"
assert_contains "$OUT" "no tty'd pi candidates" "C10 notice printed"

# C11: store missing WITH candidates -> retry-once then exit 3 (fail-closed)
mk_env C11
make_lookup "$T/C11/date.lookup"
printf '%s\n' "$(psrow 13131 400000 13131 ttys309 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c11")" > "$T/C11/ps-source"
mkdir -p "$T/C11/cmux"  # no pi-hook-sessions.json
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C11 --dry-run 2>&1)"
assert_eq "$?" "3" "C11 store missing WITH candidates -> exit 3"
assert_contains "$(cat "$T/C11/reap.log")" "FAIL-CLOSED abort: cmux store" "C11 fail-closed abort logged"

# C12: persistent-corrupt store -> retry-once then exit 3
printf '%s' '{not json' > "$T/C11/cmux/pi-hook-sessions.json"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C11 --dry-run 2>&1)"
assert_eq "$?" "3" "C12 persistent-corrupt store -> exit 3 after retry"
assert_contains "$(cat "$T/C11/reap.log")" "retrying once" "C12 retry-once logged"

# C13: transient corruption (retry read succeeds) -> pass proceeds
printf '%s' '{bad' > "$T/C11/cmux/pi-hook-sessions.json"
mkdir -p "$T/C11/sessions/--Users-t-c11--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C11/sessions/--Users-t-c11--/${E_SEP3_2000}_c11.jsonl"
cat > "$T/C11/fix-store.sh" <<SH
#!/usr/bin/env bash
sleep 0.2
printf '%s' '{"c11":{"pid":13131,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c11"}}' > "$T/C11/cmux/pi-hook-sessions.json"
SH
chmod +x "$T/C11/fix-store.sh"
( sleep 0.1; bash "$T/C11/fix-store.sh" ) &
FIXER=$!
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C11 --dry-run 2>&1)"
wait "$FIXER" 2>/dev/null
assert_reap_eligible "$OUT" "C13 transient corruption: retry read succeeds -> pass proceeds"
rm -rf "$T/C11/sessions" "$T/C11/fix-store.sh"

# C14: stale .tmp store sibling ignored (canonical file only)
printf '%s' '{"c14":{"pid":13132,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c14"}}' > "$T/C11/cmux/pi-hook-sessions.json"
printf '%s' '{corrupt-tmp-crash-leftover' > "$T/C11/cmux/pi-hook-sessions.json.tmp"
printf '%s\n' "$(psrow 13132 400000 13132 ttys310 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c14")" > "$T/C11/ps-source"
mkdir -p "$T/C11/sessions/--Users-t-c14--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C11/sessions/--Users-t-c14--/${E_SEP3_2000}_c14.jsonl"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C11 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C14 stale .tmp store sibling ignored (canonical file read)"
rm -rf "$T/C11/sessions"

# C15: strict-> threshold boundary — exactly 24h survives; 24h+2s reaped.
# Exact-24h clock = last entry (Sep 3 20:00Z = E_SEP3_2000) + 86400s.
EXACT_NOW=$((E_SEP3_2000 + 86400))
mk_env C15
make_lookup "$T/C15/date.lookup"
printf '%s\n' "$(psrow 14141 400000 14141 ttys311 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c15")" > "$T/C15/ps-source"
printf '{"c15":{"pid":14141,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c15"}}' "$E_SEP3_2000" | cmux_store C15
mkdir -p "$T/C15/sessions/--Users-t-c15--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C15/sessions/--Users-t-c15--/${E_SEP3_2000}_c15.jsonl"
OUT="$(REAP_NOW_EPOCH=$EXACT_NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=tts900 run_reaper C15 --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C15 exactly-24h idle survives (strict >)"
OUT="$(REAP_NOW_EPOCH=$((EXACT_NOW + 2)) REAP_IDLE_HOURS=24 FAKE_SELF_TTY=tts900 run_reaper C15 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C15 24h+2s idle reaped (strict >)"

# C16: REAP_IDLE_HOURS override flips a 20h-old session
printf '%s\n' '{"timestamp":"2026-09-04T06:00:00.000Z","x":1}' > "$T/C15/sessions/--Users-t-c15--/${E_SEP3_2000}_c15.jsonl"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=19 FAKE_SELF_TTY=tts900 run_reaper C15 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C16 --idle-hours 19 reaps a 20h-old session"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=tts900 run_reaper C15 --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C16 same session under 24h survives"
rm -rf "$T/C15/sessions"

# C17: mkdir-lock — live-held blocks (exit 3); aged lock breaks; dead owner breaks
mk_env C17
make_lookup "$T/C17/date.lookup"
idle30h_fixture C17 15151 ttys312 c17 /Users/t/c17
HOME_C17="$T/C17/home"
mkdir -p "$HOME_C17/.pi/agent/state/pi-reap-idle.lock"
printf '%s\n' "$$" > "$HOME_C17/.pi/agent/state/pi-reap-idle.lock/owner"
printf '%s\n' "$NOW" > "$HOME_C17/.pi/agent/state/pi-reap-idle.lock/started"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_LOCK_STALE_SECONDS=99999 FAKE_SELF_TTY=tts900 run_reaper C17 --dry-run 2>&1)"
assert_eq "$?" "3" "C17 live-held lock -> exit 3"
assert_contains "$(cat "$T/C17/reap.log")" "LOCK held by live pid" "C17 lock-abort logged"
printf '%s\n' "$((NOW - 200000))" > "$HOME_C17/.pi/agent/state/pi-reap-idle.lock/started"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_LOCK_STALE_SECONDS=99999 FAKE_SELF_TTY=tts900 run_reaper C17 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C17 aged lock breaks stale -> pass proceeds"
rm -rf "$HOME_C17/.pi/agent/state/pi-reap-idle.lock"
mkdir -p "$HOME_C17/.pi/agent/state/pi-reap-idle.lock"
printf '%s\n' "4194299" > "$HOME_C17/.pi/agent/state/pi-reap-idle.lock/owner"
printf '%s\n' "$NOW" > "$HOME_C17/.pi/agent/state/pi-reap-idle.lock/started"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_LOCK_STALE_SECONDS=99999 FAKE_SELF_TTY=tts900 run_reaper C17 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C17 dead-owner lock breaks -> pass proceeds"
rm -rf "$T/C17/sessions" "$HOME_C17/.pi/agent/state/pi-reap-idle.lock"

# C18: RESIDUAL excludes legitimately-skipped >24h candidates (marathon vetoed)
mk_env C18
make_lookup "$T/C18/date.lookup"
printf '%s\n' "$(psrow 16161 400000 16161 ttys313 "Thu Sep  3 20:00:00 2026" S 50000 "/usr/local/bin/pi --cwd /Users/t/c18")" \
               "$(psrow 16162 16161 16161 ttys313 "Sat Sep  5 01:00:00 2026" R 0 "/usr/local/bin/pi -p --cwd /Users/t/c18")" > "$T/C18/ps-source"
printf '%s' '{"c18":{"pid":16161,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c18"}}' | cmux_store C18
mkdir -p "$T/C18/sessions/--Users-t-c18--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C18/sessions/--Users-t-c18--/${E_SEP3_2000}_c18.jsonl"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=tts900 run_reaper C18 --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C18 marathon-skipped candidate not reap-eligible"
assert_contains "$(cat "$T/C18/reap.log")" "RESIDUAL=0" "C18 RESIDUAL=0 (legit skips excluded from residual)"

# C19: resolution fixtures — nested-slash cwd encoding + uuid-suffix fallback
mk_env C19
make_lookup "$T/C19/date.lookup"
printf '%s\n' "$(psrow 17171 400000 17171 ttys314 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/deep/nest/proj")" \
               "$(psrow 17172 400000 17172 ttys315 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/fallback")" > "$T/C19/ps-source"
printf '%s' '{"deep":{"pid":17171,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/deep/nest/proj"},"fb":{"pid":17172,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/fallback"}}' | cmux_store C19
mkdir -p "$T/C19/sessions/--Users-t-deep-nest-proj--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C19/sessions/--Users-t-deep-nest-proj--/${E_SEP3_2000}_deep.jsonl"
mkdir -p "$T/C19/sessions/--Users-t-elsewhere--"
printf '%s\n' '{"timestamp":"2026-09-03T20:00:00.000Z","x":1}' > "$T/C19/sessions/--Users-t-elsewhere--/${E_SEP3_2000}_fb.jsonl"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C19 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C19 nested-slash cwd encoding resolves (deep)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c REAP-ELIGIBLE)" "2" "C19 uuid-suffix find fallback resolves (fb) — 2 reap-eligible"

# C20: PI_SESSION_ID veto with cwd-empty record (line-end anchor match)
mk_env C20
make_lookup "$T/C20/date.lookup"
printf '%s\n' "$(psrow 18181 400000 18181 ttys316 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c20")" > "$T/C20/ps-source"
printf '%s' '{"own":{"pid":18181,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle"}}' | cmux_store C20
OUT="$(PI_SESSION_ID=own REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C20 --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C20 PI_SESSION_ID veto (no trailing tab after sid)"
assert_skipped_reason "$OUT" "C20 own-session reason" "own-session"

# C21: DATE_BIN branch seam — BSD mode forced deterministically (macOS branch)
mk_env C21
make_lookup "$T/C21/date.lookup"
idle30h_fixture C21 19191 ttys317 c21 /Users/t/c21
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C21 --dry-run 2>&1)"
assert_reap_eligible "$OUT" "C21 BSD date branch forced + epoch correct (macOS production branch)"
rm -rf "$T/C21/sessions"

# C22: REAL /bin/date + REAL ps day-first lstart order
# ("Mon 31 Aug 03:52:07 2026" = %a %e %b …) end-to-end through the true
# production date binary — the month-first fixture format masked the order
# difference (Sep 3 == 3 Sep under lenient parsing). GNU coreutils date has
# no -j: the legs are capability-gated (skip cleanly where the BSD shape is
# absent — ubuntu CI); the C21 shim forces the BSD parse branch anywhere.
mk_env C22
make_lookup "$T/C22/date.lookup"
if LC_ALL=C /bin/date -j -f '%a %e %b %H:%M:%S %Y' 'Mon 31 Aug 03:52:07 2026' +%s >/dev/null 2>&1; then
    E_MON31AUG="$(LC_ALL=C /bin/date -j -f '%a %e %b %H:%M:%S %Y' 'Mon 31 Aug 03:52:07 2026' +%s)"
    printf '%s\n' "$(psrow 20221 400000 20221 ttys333 "Mon 31 Aug 03:52:07 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c22")" > "$T/C22/ps-source"
    printf '%s' '{"c22s":{"pid":20221,"pidStartSeconds":'$E_MON31AUG',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c22"}}' | cmux_store C22
    session_jsonl C22 /Users/t/c22 c22s 1788166327 "2026-08-31T03:52:07.000Z"
    OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 DATE_BIN=/bin/date run_reaper C22 --dry-run 2>&1)"
    assert_reap_eligible "$OUT" "C22 real /bin/date + day-first lstart parses (macOS production shape)"
    OUT2="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 DATE_BIN=/bin/date run_reaper C22 --apply 2>&1)"
    assert_contains "$OUT2" "KILLED=1" "C22 armed pass kills under real date binary"
else
    echo "  → C22 real-date legs skipped (no BSD date on this platform) — C21 shim covers the BSD branch"
fi
rm -rf "$T/C22/sessions"

# C23: disarm sentinel — pi-reap-idle.disabled suppresses even --apply
mk_env C23
make_lookup "$T/C23/date.lookup"
idle30h_fixture C23 20231 ttys334 c23 /Users/t/c23
mkdir -p "$T/C23/home/.pi/agent/state"
touch "$T/C23/home/.pi/agent/state/pi-reap-idle.disabled"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C23 --apply 2>&1)"
assert_not_contains "$OUT" "SIGNAL" "C23 sentinel suppresses all signaling"
assert_contains "$(cat "$T/C23/reap.log")" "MODE=disabled" "C23 sentinel footer logged"
assert_eq "$(cat "$T/C23/kill.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "C23 no kill issued"
rm -rf "$T/C23"

# C24: launchd default-mode seam — REAP_DRY_RUN=0 with no mode flag arms;
# an explicit --dry-run still wins over REAP_DRY_RUN=0
mk_env C24
make_lookup "$T/C24/date.lookup"
idle30h_fixture C24 20241 ttys335 c24 /Users/t/c24
: > "$T/C24/kill.log"
OUT="$(REAP_DRY_RUN=0 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=tts900 run_reaper C24 2>&1)"
assert_contains "$(cat "$T/C24/kill.log")" "kill -TERM" "C24 REAP_DRY_RUN=0 + no flag -> armed TERM"
assert_contains "$(cat "$T/C24/reap.log")" "MODE=apply" "C24 default-mode footer MODE=apply"
rm -rf "$T/C24/sessions"
mk_env C24b
make_lookup "$T/C24b/date.lookup"
idle30h_fixture C24b 20242 ttys336 c24b /Users/t/c24b
: > "$T/C24b/kill.log"
OUT="$(REAP_DRY_RUN=0 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=tts900 run_reaper C24b --dry-run 2>&1)"
assert_not_contains "$(cat "$T/C24b/kill.log")" "kill" "C24b explicit --dry-run beats REAP_DRY_RUN=0"
assert_contains "$(cat "$T/C24b/reap.log")" "MODE=dry-run" "C24b flag-wins footer MODE=dry-run"
rm -rf "$T/C24b"

# C25: pid recycled AFTER TERM (grace window) -> incarnation fence suppresses
# the SIGKILL (fresh lstart differs from class_lstart); KILLED still counts
# the achieved TERM.
mk_env C25
make_lookup "$T/C25/date.lookup"
idle30h_fixture C25 20251 ttys337 c25 /Users/t/c25
cat > "$T/C25/reuse-side.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -TERM) awk '$1!=20251' "$FAKE_PS_SOURCE" > "$FAKE_PS_SOURCE.new" && \
           printf '%s\n' "20251 400000 20251 ttys337 Sat Sep  5 01:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/c25" >> "$FAKE_PS_SOURCE.new" && \
           mv "$FAKE_PS_SOURCE.new" "$FAKE_PS_SOURCE" ;;
esac
SH
chmod +x "$T/C25/reuse-side.sh"
: > "$T/C25/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C25/reuse-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=tts900 run_reaper C25 --apply 2>&1)"
assert_contains "$(cat "$T/C25/kill.log")" "kill -TERM -20251" "C25 TERM issued"
assert_not_contains "$(cat "$T/C25/kill.log")" "KILL" "C25 SIGKILL suppressed on pid reuse after TERM"
assert_contains "$(cat "$T/C25/reap.log")" "pid reused after TERM" "C25 reuse-after-TERM suppress reason logged"
rm -rf "$T/C25"

# C26: equal-epoch TIED twins — the settle gate must re-probe BOTH deciding
# files, not the store-order-first twin. Candidates A (pid 20260) and B
# (pid 20261, whose cmux twins x+y share one equal max epoch). A's TERM
# (kill-side) appends a fresh entry to B's TWIN-y file; B's settle re-probe
# must see it via the tied union (pre-fix it re-probed only twin x, the
# store-order-first file, and would have TERM'd a just-active session).
mk_env C26
make_lookup "$T/C26/date.lookup"
printf '%s\n' "$(psrow 20260 400000 20260 ttys338 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c26a")" \
               "$(psrow 20261 400000 20261 ttys338 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c26b")" > "$T/C26/ps-source"
printf '%s' '{"c26a":{"pid":20260,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c26a"},"c26x":{"pid":20261,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c26b"},"c26y":{"pid":20261,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c26b"}}' | cmux_store C26
session_jsonl C26 /Users/t/c26a c26a "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl C26 /Users/t/c26b c26x "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl C26 /Users/t/c26b c26y "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
cat > "$T/C26/settle-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM) printf '%s\n' '{"timestamp":"2026-09-05T01:00:00.000Z","x":"fresh"}' >> "$T/C26/sessions/--Users-t-c26b--/${E_SEP3_2000}_c26y.jsonl" ;;
esac
SH
chmod +x "$T/C26/settle-side.sh"
: > "$T/C26/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C26/settle-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=tts900 run_reaper C26 --apply 2>&1)"
assert_contains "$(cat "$T/C26/kill.log")" "kill -TERM -20260" "C26 candidate A TERM'd normally"
assert_not_contains "$(cat "$T/C26/kill.log")" "kill -TERM -20261" "C26 tied-twin advance suppresses B's TERM"
assert_contains "$(cat "$T/C26/reap.log")" "activity advanced" "C26 tied-twin advance suppress reason logged"
rm -rf "$T/C26"

# C27a: dry-run + unwritable REAP_LOG -> exit 0, stdout verdict (no audit abort)
mk_env C27a
make_lookup "$T/C27a/date.lookup"
idle30h_fixture C27a 20271 ttys339 c27a /Users/t/c27a
mkdir "$T/C27a/reap.log"   # run_reaper hard-sets REAP_LOG=$T/C27a/reap.log
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C27a --dry-run 2>&1)"
assert_eq "$?" "0" "C27a dry-run + unwritable log exits 0"
assert_reap_eligible "$OUT" "C27a dry-run verdict still on stdout"
rm -rf "$T/C27a"

# C27b: --apply + sentinel + unwritable REAP_LOG -> exit 3 (probe precedes
# sentinel; no silent no-trail armed pass)
mk_env C27b
make_lookup "$T/C27b/date.lookup"
idle30h_fixture C27b 20272 ttys340 c27b /Users/t/c27b
mkdir -p "$T/C27b/home/.pi/agent/state"
touch "$T/C27b/home/.pi/agent/state/pi-reap-idle.disabled"
mkdir "$T/C27b/reap.log"   # run_reaper hard-sets REAP_LOG=$T/C27b/reap.log
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C27b --apply 2>&1)"
assert_eq "$?" "3" "C27b apply + sentinel + unwritable log exits 3 (probe first)"
assert_contains "$OUT" "FAIL-CLOSED abort: REAP_LOG unwritable" "C27b stderr names the log abort"
rm -rf "$T/C27b"

# C27c: --apply + unwritable REAP_LOG -> exit 3 with stderr message
mk_env C27c
make_lookup "$T/C27c/date.lookup"
idle30h_fixture C27c 20273 ttys341 c27c /Users/t/c27c
mkdir "$T/C27c/reap.log"   # run_reaper hard-sets REAP_LOG=$T/C27c/reap.log
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C27c --apply 2>&1)"
assert_eq "$?" "3" "C27c apply + unwritable log exits 3"
assert_eq "$(cat "$T/C27c/kill.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "C27c no signal before the abort"
rm -rf "$T/C27c"

# C27d: HOME unset survives (no set -u unbound crash); fail-closed exit
OUT="$(env -u HOME REAP_LOG="/tmp/c27d-$$.log" bash "$REAPER" --help 2>&1)"
assert_eq "$?" "0" "C27d env -u HOME --help exits 0 (no unbound crash)"
rm -f "/tmp/c27d-$$.log"

echo "════════════════════════════════════════════════════════════════"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
