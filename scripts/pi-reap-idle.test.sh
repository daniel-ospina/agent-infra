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
#   pack E  candidate-ancestry gate 3 (#1207) — ADDITIVE refusal. E1 a
#           Terminal.app chain is report-only; E2 a cmux-rooted chain is
#           report-only; E3 an unresolvable chain is refused (unknown); E4 a
#           RED control: the scenario copy (below) signals the SAME cmux
#           fixture, so E2 is load-bearing and would go RED if the cmux arm
#           were relaxed; E0 pins the scenario copy to a one-line diff.
#
# ── the gate-3-relaxed SCENARIO COPY (#1207) ──────────────────────────
# Under the recorded decision gate 3 refuses EVERY chain class, so the
# shipped reaper signals nothing at all — its kill path is unreachable by
# construction. Packs A–D exercise that machinery (TERM/KILL shape, settle
# suppression, the #947 stuck arm), so `run_reaper` invokes a copy that
# differs from the shipped script by EXACTLY ONE LINE: the cmux arm of
# `gate3_allows` is relaxed to allow. Pack E pins gate 3's refusals against
# the REAL script via `run_reaper_real`, and asserts the copy's diff is one
# line — so the copy can never drift into a different artifact, and every
# other line it runs IS the shipped code.
#
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
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_reap_eligible() { if grep -q "REAP-ELIGIBLE" <<<"$1"; then ok "$2"; else bad "$2"; fi }
assert_skipped_reason() { if grep -qF -- "$3" <<<"$1"; then ok "$2"; else bad "$2 (missing reason: $3)"; fi }

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
    # Deterministic bulk-call failure injection (settle-time probe tests):
    # FAKE_PS_BULK_LOG counts bulk calls; from FAKE_PS_FAIL_BULK_N onward the
    # call fails (rc 1). FAKE_PS_FAIL_PARTIAL=1 still prints the rows first
    # (a partly-failed `ps`). Absent env => unchanged behaviour.
    if [ -n "${FAKE_PS_BULK_LOG:-}" ]; then
        _bn=0; [ -s "$FAKE_PS_BULK_LOG" ] && _bn="$(cat "$FAKE_PS_BULK_LOG")"
        _bn=$(( _bn + 1 )); printf '%s\n' "$_bn" > "$FAKE_PS_BULK_LOG"
        if [ -n "${FAKE_PS_FAIL_BULK_N:-}" ] && [ "$_bn" -ge "$FAKE_PS_FAIL_BULK_N" ]; then
            [ "${FAKE_PS_FAIL_PARTIAL:-0}" = "1" ] && sed 's/^ *//' "$SOURCE"
            exit 1
        fi
    fi
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
    # 400000 carries a full lstart too: the PS_TABLE awk keeps pid/ppid from a
    # yearless row but the chain walk needs 400000's OWN parent link to step
    # past it, and a row the parser reduces to four fields is dropped from the
    # host-class map entirely (the walk then stops at 400000 and answers
    # `unknown`).
    echo "400000 400001 400000 ${FAKE_SELF_TTY:-tts000} Thu Sep  3 20:00:00 2026 S 0 /bin/launchd-self"
    # gate 3 (#1207): the synthetic chain is cmux-ROOTED, mirroring the real
    # fleet (every live lane is spawned by cmux.app; the earlier 400001 -> 1
    # shape had NO recognised host app and would classify `unknown`, which
    # gate 3 fail-closed refuses). The row carries a full lstart because the
    # PS_TABLE awk finds the command only AFTER a 4-digit year token — a
    # yearless row keeps pid/ppid but loses its argv, and the chain walk reads
    # argv[0] to recognise a host app.
    echo "400001 400002 400001 ?? Thu Sep  3 20:00:00 2026 S 0 /Applications/cmux.app/Contents/MacOS/cmux"
    echo "400002 1 400002 ?? S 0 0 /sbin/launchd"
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
if [ -n "${FAKE_ESRCH_PIDS:-}" ] && grep -qx "$TARGET" <<<"$FAKE_ESRCH_PIDS"; then
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

# gate-3-relaxed scenario copy (#1207) — see the header. Exactly one line:
# `cmux) return 1 ;;` (report-only) -> `cmux) return 0 ;;` (may signal).
REAPER_G3OFF="$T/bin/pi-reap-idle-g3off.sh"
sed 's/cmux) return 1 ;;/cmux) return 0 ;;/' "$REAPER" > "$REAPER_G3OFF"

run_reaper_bin() { # <binary> <env-name> args... — reaper with full shim env
    local bin="$1" envname="$2"; shift 2
    HOME="$T/$envname/home" \
    PATH="$T/bin:$PATH" \
    # The scenario copy lives in $T/bin, so the script's own sibling
    # lib/pid-identity.sh lookup would miss (and the reaper FAIL-CLOSES exit 3
    # without it). Point the documented seam at the REAL library.
    PID_IDENTITY_LIB="$SCRIPT_DIR/lib/pid-identity.sh" \
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
    bash "$bin" "$@"
}

# Packs A–D run the gate-3-relaxed scenario copy so their kill-path machinery
# stays reachable; pack E uses run_reaper_real for gate 3's own refusals.
run_reaper() { run_reaper_bin "$REAPER_G3OFF" "$@"; }
run_reaper_real() { run_reaper_bin "$REAPER" "$@"; }

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

# C28: framing bytes in the REAL on-disk session-dir name. esc() neutralizes
# them in store values, so the reaper's encoded dir-glob misses and the find
# fallback surfaces the raw byte-bearing path — round-4 fail-closed: that
# record abstains at classify (never eligible, never signaled). The store is
# written via json.dumps because raw 0x1f is invalid JSON.
python3 - "$T" "$NOW" "$E_SEP3_2000" <<'PY'
import json, os, sys
T, NOW, SEP3 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def env_fixture(name, pid, tty, sid, cwd_bytes, marker):
    env = os.path.join(T, name)
    os.makedirs(os.path.join(env, "home"), exist_ok=True)
    os.makedirs(os.path.join(env, "state"), exist_ok=True)
    # ps-source row (lstart Thu Sep 3 20:00:00 2026 -> SEP3 epoch via lookup)
    with open(os.path.join(env, "ps-source"), "w") as f:
        f.write("%s 400000 %s %s Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd %s\n"
                % (pid, pid, tty, cwd_bytes.decode("latin1")))
    # real sessions dir named with the RAW cwd encoding (byte preserved)
    enc = cwd_bytes.decode("latin1").lstrip("/").replace("/", "-")
    sdir = os.path.join(env, "sessions", "--%s--" % enc)
    os.makedirs(sdir, exist_ok=True)
    with open(os.path.join(sdir, "%d_%s.jsonl" % (SEP3, sid)), "w") as f:
        for ts in ("2026-09-03T20:00:00.000Z", "2026-09-03T20:30:00.000Z",
                   "2026-09-03T21:00:00.000Z"):
            f.write('{"timestamp":"%s","x":"t"}\n' % ts)
        # three datable lines => max epoch Sep 3 21:00 (~29h before NOW):
        # when the framing-byte guard is absent this session IS reap-eligible,
        # so the assert_not_contains REAP-ELIGIBLE below is a true regression
        # test of the round-4b abstain (verified: guard-stripped run prints
        # REAP-ELIGIBLE + RESIDUAL=1)
    store = {"version": 1, "agentHookFailureReportTimestamps": {}, "sessions": {
        sid: {"pid": pid, "pidStartSeconds": SEP3, "pidStartMicroseconds": 0,
              "agentLifecycle": "idle", "runtimeStatus": "idle",
              "cwd": cwd_bytes.decode("utf-8")}}}
    os.makedirs(os.path.join(env, "cmux"), exist_ok=True)
    with open(os.path.join(env, "cmux", "pi-hook-sessions.json"), "w") as f:
        json.dump(store, f)
    return env
env_fixture("C28a", 20281, "ttys341", "c28a", b"/tmp/foo\x1fbar", 1)
env_fixture("C28b", 20282, "ttys342", "c28b", b"/tmp/p|q", 2)
PY
make_lookup "$T/C28a/date.lookup"
make_lookup "$T/C28b/date.lookup"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C28a --apply 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C28a 0x1f-path session never eligible"
assert_contains "$OUT" "SKIP no-jsonl-proof" "C28a 0x1f-path session abstains (framing byte)"
assert_eq "$(cat "$T/C28a/kill.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "C28a no signal for 0x1f path"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=tts900 run_reaper C28b --apply 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "C28b |-path session never eligible"
assert_contains "$OUT" "SKIP no-jsonl-proof" "C28b |-path session abstains (framing byte)"
assert_eq "$(cat "$T/C28b/kill.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "C28b no signal for |-path"
rm -rf "$T/C28a" "$T/C28b"

# C29: settle-3 re-probe fail-closed — A's TERM side effect DELETES B's
# deciding JSONL between classify and settle => B's re-probe returns empty
# and must SUPPRESS (round-4b: "cannot re-probe deciding file"), never
# treat empty as no-advance and signal.
mk_env C29
make_lookup "$T/C29/date.lookup"
printf '%s\n' "$(psrow 12126 400000 12126 ttys305 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c29a")" \
               "$(psrow 12129 400000 12129 ttys305 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/c29b")" > "$T/C29/ps-source"
printf '%s' '{"c29a":{"pid":12126,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c29a"},"c29b":{"pid":12129,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/c29b"}}' | cmux_store C29
session_jsonl C29 /Users/t/c29a c29a "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl C29 /Users/t/c29b c29b "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
cat > "$T/C29/del-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM) rm -f "$T/C29/sessions/--Users-t-c29b--/${E_SEP3_2000}_c29b.jsonl" ;;
esac
SH
chmod +x "$T/C29/del-side.sh"
: > "$T/C29/kill.log"
OUT="$(FAKE_KILL_SIDE="$T/C29/del-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper C29 --apply 2>&1)"
assert_contains "$(cat "$T/C29/kill.log")" "kill -TERM -12126" "C29 candidate A TERM'd normally"
assert_not_contains "$(cat "$T/C29/kill.log")" "kill -TERM -12129" "C29 candidate B suppressed (no TERM) when deciding file deleted"
assert_contains "$(cat "$T/C29/reap.log")" "cannot re-probe deciding file" "C29 re-probe-failure suppress reason logged"
rm -rf "$T/C29"

echo "fixture pack D: bounded veto — stuck classification + arm (#947)"
mk_env D
make_lookup "$T/D/date.lookup"
FAKE_SELF_TTY=tts900
# Real epochs for the two-signal staleness fixtures (122h and 40h before NOW).
E_AUG31_0000="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-08-31T00:00:00+00:00").timestamp()))')"
E_SEP03_1000="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-03T10:00:00+00:00").timestamp()))')"

# running_record_fixture <pid> <tty> <sid> <cwd> <jsonl-last-iso> <updatedAt|cold>
# Emits a ps row (S, no children) + one non-idle cmux record. `cold` omits
# updatedAt (the fail-closed no-freshness-proof case).
running_record_fixture() { # <pid> <tty> <sid> <cwd> <last-iso> <updatedAt|cold>
    local pid="$1" tty="$2" sid="$3" cwd="$4" last="$5" upd="$6"
    printf '%s\n' "$(psrow "$pid" 400000 "$pid" "$tty" "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd $cwd")" > "$T/D/ps-source"
    if [ "$upd" = cold ]; then
        printf '{"%s":{"pid":%s,"pidStartSeconds":%s,"agentLifecycle":"running","runtimeStatus":"idle","cwd":"%s"}}' "$sid" "$pid" "$E_SEP3_2000" "$cwd" | cmux_store D
    else
        printf '{"%s":{"pid":%s,"pidStartSeconds":%s,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":%s,"cwd":"%s"}}' "$sid" "$pid" "$E_SEP3_2000" "$upd" "$cwd" | cmux_store D
    fi
    session_jsonl D "$cwd" "$sid" "$E_SEP3_2000" "$last"
}

# D1: a FRESH non-idle record still vetoes — but the skip line now carries the
# JSONL idle age. Pre-#947 the veto short-circuited BEFORE the JSONL proof, so
# a 122h-frozen session reported only "allowlist lifecycle=running" and its age
# was invisible (the silent-failure class this issue is about).
running_record_fixture 30001 ttys400 d1 /Users/t/d1 "2026-08-31T00:00:00.000Z" "$E_SEP5_0100"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D1 fresh non-idle record still vetoes (no reap)"
assert_contains "$OUT" "jsonl idle 122.0h" "D1 veto line surfaces the JSONL idle age (pre-#947 blindness fixed)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D1 fresh non-idle record is NOT stuck"
rm -rf "$T/D/sessions"

# D2: both independent signals frozen past the bound => STUCK, report-only.
# Even --apply sends ZERO signals for the stuck set by default.
running_record_fixture 30002 ttys401 d2 /Users/t/d2 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$OUT" "STUCK-ESCALATE" "D2 stuck passed the freshness bound -> escalated"
assert_contains "$OUT" "⚠️ STUCK: 1" "D2 stuck audit block surfaced on stdout (no more silent exit 0)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D2 stuck is NOT reap-eligible by default"
[ ! -s "$T/D/kill.log" ] && ok "D2 zero signals for the report-only stuck set" || bad "D2 zero signals for the report-only stuck set"
assert_contains "$(cat "$T/D/reap.log")" "STUCK=1 STUCK_RSS=30000 STUCK_ARMED=0" "D2 footer records STUCK/STUCK_RSS/STUCK_ARMED=0"
rm -rf "$T/D/sessions"

# D3: missing updatedAt => no freshness proof => the veto stands (fail closed).
running_record_fixture 30003 ttys402 d3 /Users/t/d3 "2026-08-31T00:00:00.000Z" cold
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D3 record with no updatedAt is NOT stuck (fail closed)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D3 no-updatedAt veto preserved"
rm -rf "$T/D/sessions"

# D4: a live non-zombie child process (a tool call in flight) blocks STUCK.
# The pre-existing marathon gate only catches *pi* descendants; this catches a
# long-running bash/tool child. The child must be non-pi so the run reaches the
# stuck check rather than the earlier `orchestrating` skip.
running_record_fixture 30004 ttys403 d4 /Users/t/d4 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s\n' "$(psrow 30004 400000 30004 ttys403 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d4")" \
               "$(psrow 30044 30004 30004 ttys403 "Sat Sep  5 01:00:00 2026" S 0 "/bin/bash -c long-tool")" > "$T/D/ps-source"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D4 live non-pi child (tool in flight) blocks STUCK"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D4 no reap while a child process is live"
rm -rf "$T/D/sessions"

# D5: a CPU-accumulating process (stat R) is not provably stuck.
running_record_fixture 30005 ttys404 d5 /Users/t/d5 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s\n' "$(psrow 30005 400000 30005 ttys404 "Thu Sep  3 20:00:00 2026" R 30000 "/usr/local/bin/pi --cwd /Users/t/d5")" > "$T/D/ps-source"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D5 stat R (accumulating CPU) is not stuck"
rm -rf "$T/D/sessions"

# D6: the freshness bound is STRICT (>). JSONL + record both exactly 30h stale:
# --stuck-hours 30 => NOT stuck; --stuck-hours 29 => stuck. Driven through the
# CLI FLAG (its happy path — parse_args position/`shift 2` bugs would otherwise
# hide behind the env var) and the resolved bound is pinned from the footer.
running_record_fixture 30006 ttys405 d6 /Users/t/d6 "2026-09-03T20:00:00.000Z" "$E_SEP3_2000"
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --stuck-hours 30 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D6 exactly-at-bound 30h vs --stuck-hours 30 survives (strict >)"
assert_contains "$OUT" "allowlist lifecycle=running" "D6 at-bound candidate keeps the plain allowlist skip"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_HOURS=30" "D6 --stuck-hours 30 resolves into the footer bound"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --stuck-hours 29 2>&1)"
assert_contains "$OUT" "STUCK-ESCALATE" "D6 30h vs --stuck-hours 29 escalates (strict >)"
rm -rf "$T/D/sessions"

# D7: --idle-hours moves the default stuck bound (3x) with it. 40h stale:
# under --idle-hours 12 the bound is 36h => stuck; at the 24h default it is
# 72h => not stuck.
running_record_fixture 30007 ttys406 d7 /Users/t/d7 "2026-09-03T10:00:00.000Z" "$E_SEP03_1000"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=12 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"
assert_contains "$OUT" "STUCK-ESCALATE" "D7 --idle-hours 12 -> bound 36h -> 40h stale is stuck"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D7 default bound 72h -> 40h stale is not stuck"
rm -rf "$T/D/sessions"

# D8: union freshness — one matched twin with a FRESH updatedAt keeps the veto
# for the whole pid (least-stale record governs), even with the JSONL frozen.
running_record_fixture 30008 ttys407 d8 /Users/t/d8 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s' '{"d8a":{"pid":30008,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d8"},"d8b":{"pid":30008,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_SEP5_0100',"cwd":"/Users/t/d8"}}' | cmux_store D
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D8 one fresh matched twin keeps the veto (least-stale governs)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D8 no reap with a fresh matched record"
rm -rf "$T/D/sessions"

# D8b: STUCK needs BOTH independent signals frozen. THE kill-path conjunct: a
# stale record with a FRESH (actively moving) JSONL must never be STUCK —
# otherwise the arm TERMs a session that is demonstrably working. Without this
# fixture the `idle_age_h > REAP_STUCK_HOURS` half is unexercised (every other
# stuck fixture freezes both signals), so deleting it keeps the suite green.
running_record_fixture 30081 ttys416 d8b /Users/t/d8b "2026-09-05T01:00:00.000Z" "$E_AUG31_0000"
: > "$T/D/kill.log"
OUT="$(REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D8b stale record + FRESH jsonl (1h) is NOT stuck"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D8b stale record + fresh jsonl never eligible"
assert_not_contains "$OUT" "record stale past" "D8b no stuck escalation text"
[ ! -s "$T/D/kill.log" ] && ok "D8b stale record + fresh jsonl sent zero signals" || bad "D8b stale record + fresh jsonl sent zero signals"
rm -rf "$T/D/sessions"

# D8c: freshness unions over EVERY non-idle record for the pid, fence-matched
# or not. A fresh non-idle record with NO pidStartSeconds abstains from voting
# (so it cannot veto the ordinary path — 'abstain != veto' is pinned by B2),
# but it MUST still withhold a STUCK kill: it is direct evidence the pid is
# being written to right now. Live shape: the store has 56 no-pss records, 4 of
# them fresh non-idle.
running_record_fixture 30082 ttys417 d8c /Users/t/d8c "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s' '{"d8c":{"pid":30082,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d8c"},"d8c-nopss":{"pid":30082,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_SEP5_0100',"cwd":"/Users/t/d8c"}}' | cmux_store D
: > "$T/D/kill.log"
OUT="$(REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D8c fresh no-pss non-idle twin withholds the STUCK kill"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D8c fresh no-pss twin never eligible"
[ ! -s "$T/D/kill.log" ] && ok "D8c fresh no-pss twin sent zero signals" || bad "D8c fresh no-pss twin sent zero signals"
rm -rf "$T/D/sessions"

# D9: armed stuck reap (REAP_REAP_STUCK=1) — the ONLY path that signals a stuck
# candidate. Row carries stuck=1; settle guards are unchanged.
running_record_fixture 30009 ttys408 d9 /Users/t/d9 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
cat > "$T/D/stuck-side.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -TERM) sed -i.bak '/^30009 /d' "$FAKE_PS_SOURCE"; rm -f "$FAKE_PS_SOURCE.bak" ;;
esac
SH
chmod +x "$T/D/stuck-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/stuck-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$OUT" "REAP-ELIGIBLE(STUCK)" "D9 armed stuck candidate is reap-eligible"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30009" "D9 armed stuck TERM group shape"
assert_contains "$(cat "$T/D/reap.log")" "stuck=1" "D9 SIGNAL line records stuck=1"
assert_contains "$(cat "$T/D/reap.log")" "KILLED=1" "D9 armed stuck KILLED=1"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_ARMED=1" "D9 footer records STUCK_ARMED=1"
rm -rf "$T/D/sessions" "$T/D/stuck-side.sh"

# D10: --reap-stuck flag is the CLI form of REAP_REAP_STUCK=1 (dry-run: no
# signals, but the candidate is listed as stuck-reapable).
running_record_fixture 30010 ttys409 d10 /Users/t/d10 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
: > "$T/D/kill.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --reap-stuck 2>&1)"
assert_contains "$OUT" "REAP-ELIGIBLE(STUCK)" "D10 --reap-stuck arms the stuck set (dry-run lists it)"
[ ! -s "$T/D/kill.log" ] && ok "D10 dry-run --reap-stuck sends no signals" || bad "D10 dry-run --reap-stuck sends no signals"
rm -rf "$T/D/sessions"

# D11: a non-idle candidate with NO JSONL proof still reports the allowlist
# reason (veto vocabulary precedence preserved by the reorder).
printf '%s\n' "$(psrow 30011 400000 30011 ttys410 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d11missing")" > "$T/D/ps-source"
printf '{"d11":{"pid":30011,"pidStartSeconds":%s,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":%s,"cwd":"/Users/t/d11missing"}}' "$E_SEP3_2000" "$E_AUG31_0000" | cmux_store D
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$OUT" "SKIP allowlist lifecycle=running runtimeStatus=idle" "D11 veto reason wins when there is no JSONL proof"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D11 no proof => never stuck (fail closed)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "D11 no proof => never eligible"
rm -rf "$T/D/sessions"

# D12: bad --stuck-hours / REAP_REAP_STUCK values are usage errors (exit 2).
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --stuck-hours abc 2>&1)"; RC=$?
assert_eq "$RC" "2" "D12 bad --stuck-hours exits 2"
OUT="$(REAP_REAP_STUCK=yes REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "2" "D12 bad REAP_REAP_STUCK exits 2"

# D13: an updatedAt that is digit/dot soup is NOT a freshness stamp. awk would
# coerce "1.2.3" to 1.2 and ".." to 0 => a huge apparent age => a false STUCK.
# These must keep the plain veto (fail closed) — review P1.
for BADSTAMP in '"1.2.3"' '".."' '"."' '"123abc"' '"0"' '"-5"' 'null'; do
    running_record_fixture 30031 ttys411 d13 /Users/t/d13 "2026-08-31T00:00:00.000Z" cold
    printf '{"d13":{"pid":30031,"pidStartSeconds":%s,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":%s,"cwd":"/Users/t/d13"}}' "$E_SEP3_2000" "$BADSTAMP" | cmux_store D
    : > "$T/D/kill.log"
    OUT="$(REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
    assert_not_contains "$OUT" "STUCK-ESCALATE" "D13 updatedAt=$BADSTAMP is not a stamp -> not stuck"
    assert_not_contains "$OUT" "REAP-ELIGIBLE" "D13 updatedAt=$BADSTAMP never eligible"
    # discriminating: an accepted stamp would print a NUMBER for the record age;
    # rejection is only observable through the `?` fallback
    assert_contains "$OUT" "record age ?h" "D13 updatedAt=$BADSTAMP rejected as unusable (age unknown)"
    [ ! -s "$T/D/kill.log" ] && ok "D13 updatedAt=$BADSTAMP sent zero signals" || bad "D13 updatedAt=$BADSTAMP sent zero signals"
    rm -rf "$T/D/sessions"
    : > "$T/D/reap.log"
    : > "$T/D/kill.log"
done

# D14: an implausibly future stamp is not a stamp either (negative age would read
# as fresh, a huge future stamp is garbage) — both keep the veto. Each leg
# asserts the OBSERVABLE rejection, not just the shared "not stuck" verdict: a
# deleted upper bound would accept the stamp and print a negative age, which
# still yields "not stuck" for the wrong reason (review P2).
for BADSTAMP in "$((NOW + 86400 * 30))" 0 1; do
    running_record_fixture 30032 ttys412 d14 /Users/t/d14 "2026-08-31T00:00:00.000Z" "$BADSTAMP"
    : > "$T/D/kill.log"
    OUT="$(REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
    assert_not_contains "$OUT" "STUCK-ESCALATE" "D14 implausible updatedAt=$BADSTAMP -> not stuck"
    [ ! -s "$T/D/kill.log" ] && ok "D14 implausible updatedAt=$BADSTAMP sent zero signals" || bad "D14 implausible updatedAt=$BADSTAMP sent zero signals"
    rm -rf "$T/D/sessions"
    : > "$T/D/reap.log"
    : > "$T/D/kill.log"
done
# positive control: a stamp 1h in the FUTURE is inside the +86400 skew window,
# so it IS accepted (age negative) and the veto must hold on freshness grounds —
# distinguishing "rejected as unusable" from "accepted but negative".
running_record_fixture 30033 ttys412 d14f /Users/t/d14f "2026-08-31T00:00:00.000Z" "$((NOW + 3600))"
OUT="$(REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"
assert_not_contains "$OUT" "STUCK-ESCALATE" "D14 within-skew future stamp is accepted and keeps the veto"
assert_not_contains "$OUT" "record age ?h" "D14 within-skew future stamp was USED as a stamp (age known)"
rm -rf "$T/D/sessions"

# D15: STUCK settle re-verify — A's TERM side effect rewrites B's record to
# idle/fresh => B's FRESH store re-read sees the premise gone and suppresses.
# Two stuck candidates so A's signal runs before B's settle (deterministic).
running_record_fixture 30041 ttys413 d15a /Users/t/d15a "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
running_record_fixture 30042 ttys413 d15b /Users/t/d15b "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s\n' "$(psrow 30041 400000 30041 ttys413 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15a")" \
               "$(psrow 30042 400000 30042 ttys413 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15b")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15a d15a "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15b d15b "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d15a":{"pid":30041,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15a"},"d15b":{"pid":30042,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15b"}}' | cmux_store D
cat > "$T/D/settle-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        sed -i.bak '/^30041 /d' "\$FAKE_PS_SOURCE"; rm -f "\$FAKE_PS_SOURCE.bak"
        printf '%s' '{"d15b":{"pid":30042,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"idle","runtimeStatus":"idle","updatedAt":$E_SEP5_0100,"cwd":"/Users/t/d15b"}}' > "$T/D/cmux/pi-hook-sessions.json"
        ;;
esac
SH
chmod +x "$T/D/settle-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/settle-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30041" "D15 candidate A (stuck) TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30042" "D15 candidate B suppressed (store re-read: record now idle)"
assert_contains "$(cat "$T/D/reap.log")" "stuck row record no longer frozen" "D15 stuck-settle suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/settle-side.sh"

# D15b: the STUCK settle also re-checks the PROCESS STATE. A's TERM side effect
# flips B's ps row to `R` (accumulating CPU) => B's stuck-settle stat branch
# suppresses. Without this fixture that branch is unreachable (D15 only rewrites
# the store; D9's side deletes the candidate's row, which fails earlier).
running_record_fixture 30046 ttys418 d15c /Users/t/d15c "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s\n' "$(psrow 30046 400000 30046 ttys418 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15c")" \
               "$(psrow 30047 400000 30047 ttys418 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15d")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15c d15c "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15d d15d "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d15c":{"pid":30046,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15c"},"d15d":{"pid":30047,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15d"}}' | cmux_store D
cat > "$T/D/stat-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30047 400000 30047 ttys418 Thu Sep  3 20:00:00 2026 R 30000 /usr/local/bin/pi --cwd /Users/t/d15d" > "\$FAKE_PS_SOURCE"
        ;;
esac
SH
chmod +x "$T/D/stat-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/stat-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30046" "D15b trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30047" "D15b stuck row suppressed when the process leaves S at settle"
assert_contains "$(cat "$T/D/reap.log")" "no longer sleeping" "D15b stat-branch suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/stat-side.sh"

# D15c: the store re-read FAILING at settle must suppress (fail-closed). Only
# this fixture reaches stuck_record_still_frozen's store_extract-failure path.
running_record_fixture 30048 ttys419 d15e /Users/t/d15e "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
printf '%s\n' "$(psrow 30048 400000 30048 ttys419 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15e")" \
               "$(psrow 30049 400000 30049 ttys419 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15f")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15e d15e "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15f d15f "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d15e":{"pid":30048,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15e"},"d15f":{"pid":30049,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15f"}}' | cmux_store D
cat > "$T/D/store-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30049 400000 30049 ttys419 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15f" > "\$FAKE_PS_SOURCE"
        printf '%s' 'this-is-not-json' > "$T/D/cmux/pi-hook-sessions.json"
        ;;
esac
SH
chmod +x "$T/D/store-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/store-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30048" "D15c trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30049" "D15c stuck row suppressed when the store re-read fails (fail-closed)"
assert_contains "$(cat "$T/D/reap.log")" "stuck row record no longer frozen" "D15c store-failure suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/store-side.sh"

# D15e (review P1): the settle re-verify must mirror classify's UNION, not just
# the max-epoch deciding sid. pid has TWO matched records: d15gx (max JSONL
# epoch => the deciding sid) and d15gy (older). The TERM side effect refreshes
# d15gy's stamp to 1h while d15gx stays stale — the old sid-filtered re-read saw
# only d15gx and SIGNALED. Under the union rule d15gy is fresh => suppress.
printf '%s\n' "$(psrow 30050 400000 30050 ttys420 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15g")" \
               "$(psrow 30051 400000 30051 ttys420 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15h")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15g d15g "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15h d15gx "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15h d15gy "$E_SEP3_2000" "2026-08-30T00:00:00.000Z"
printf '%s' '{"d15g":{"pid":30050,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15g"},"d15gx":{"pid":30051,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15h"},"d15gy":{"pid":30051,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15h"}}' | cmux_store D
cat > "$T/D/twin-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30051 400000 30051 ttys420 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15h" > "\$FAKE_PS_SOURCE"
        printf '%s' '{"d15gx":{"pid":30051,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":$E_AUG31_0000,"cwd":"/Users/t/d15h"},"d15gy":{"pid":30051,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":$E_SEP5_0100,"cwd":"/Users/t/d15h"}}' > "$T/D/cmux/pi-hook-sessions.json"
        ;;
esac
SH
chmod +x "$T/D/twin-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/twin-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30050" "D15e trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30051" "D15e non-deciding twin going fresh suppresses (union, not sid-filtered)"
assert_contains "$(cat "$T/D/reap.log")" "stuck row record no longer frozen" "D15e twin-refresh suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/twin-side.sh"

# D15f: the declared complement of D15e — a twin going IDLE (with a fresh
# stamp but NO JSONL advance) does NOT suppress: an idle record is the reap
# target itself, not work in progress. Pins the doc's wording so a future
# change to this policy is a deliberate, visible one.
printf '%s\n' "$(psrow 30052 400000 30052 ttys422 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15i")" \
               "$(psrow 30053 400000 30053 ttys422 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15j")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15i d15i "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15j d15hx "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15j d15hy "$E_SEP3_2000" "2026-08-30T00:00:00.000Z"
printf '%s' '{"d15i":{"pid":30052,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15i"},"d15hx":{"pid":30053,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15j"},"d15hy":{"pid":30053,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15j"}}' | cmux_store D
cat > "$T/D/idle-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30053 400000 30053 ttys422 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15j" > "\$FAKE_PS_SOURCE"
        printf '%s' '{"d15hx":{"pid":30053,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":$E_AUG31_0000,"cwd":"/Users/t/d15j"},"d15hy":{"pid":30053,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"idle","runtimeStatus":"idle","updatedAt":$E_SEP5_0100,"cwd":"/Users/t/d15j"}}' > "$T/D/cmux/pi-hook-sessions.json"
        ;;
esac
SH
chmod +x "$T/D/idle-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/idle-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30052" "D15f trigger candidate TERM'd normally"
assert_contains "$(cat "$T/D/kill.log")" "30053" "D15f a twin going IDLE does not suppress (idle is the reap target, not work)"
assert_not_contains "$(cat "$T/D/reap.log")" "SETTLE-SKIP 30053 stuck row" "D15f no stuck-settle suppress for the idle twin"
rm -rf "$T/D/sessions" "$T/D/idle-side.sh"

# D15g (review P1): the stuck row's settle-3 probe set is the UNION of every
# matched record's file, not just the deciding one. The deciding sid (Aug-31)
# is strictly newer than the twin (Aug-30), and at TERM the twin's JSONL — not
# the deciding file, and with its store record left untouched — resumes. Only
# $sfiles_all catches it ("activity advanced"); $sfile would TERM the pid.
printf '%s\n' "$(psrow 30054 400000 30054 ttys423 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15k")" \
               "$(psrow 30055 400000 30055 ttys423 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15l")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15k d15k "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15l d15kx "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15l d15ky "$E_SEP3_2000" "2026-08-30T00:00:00.000Z"
printf '%s' '{"d15k":{"pid":30054,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15k"},"d15kx":{"pid":30055,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15l"},"d15ky":{"pid":30055,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15l"}}' | cmux_store D
cat > "$T/D/union-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30055 400000 30055 ttys423 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15l" > "\$FAKE_PS_SOURCE"
        printf '{"type":"message","role":"user","timestamp":"2026-09-05T01:00:00.000Z","content":"hi"}\n' >> "$T/D/sessions/--Users-t-d15l--/${E_SEP3_2000}_d15ky.jsonl"
        ;;
esac
SH
chmod +x "$T/D/union-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/union-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30054" "D15g trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30055" "D15g non-deciding twin's JSONL advancing suppresses (union probe set)"
assert_contains "$(cat "$T/D/reap.log")" "activity advanced" "D15g union JSONL re-probe reason logged"
rm -rf "$T/D/sessions" "$T/D/union-side.sh"

# D15h (review P2): settle 2c takes a FRESH child probe. A tool child spawned
# after the classify snapshot leaves the parent in S with its record unchanged,
# so only the fresh enumeration catches it.
printf '%s\n' "$(psrow 30056 400000 30056 ttys424 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15m")" \
               "$(psrow 30057 400000 30057 ttys424 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15n")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15m d15m "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15n d15n "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d15m":{"pid":30056,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15m"},"d15n":{"pid":30057,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15n"}}' | cmux_store D
cat > "$T/D/child-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30057 400000 30057 ttys424 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15n" \
                       "30058 30057 30058 ttys424 Thu Sep  3 20:00:00 2026 S 2000 /bin/bash -c 'sleep 300'" > "\$FAKE_PS_SOURCE"
        ;;
esac
SH
chmod +x "$T/D/child-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/child-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30056" "D15h trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30057" "D15h a tool child spawned after classify suppresses (fresh settle probe)"
assert_contains "$(cat "$T/D/reap.log")" "live child/descendant at settle" "D15h fresh-child suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/child-side.sh"

# D15i (review P2): the deciding record vanishing from the store must suppress
# (the `decided` conjunct) — an older stale twin alone is not enough.
printf '%s\n' "$(psrow 30059 400000 30059 ttys425 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15o")" \
               "$(psrow 30060 400000 30060 ttys425 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15p")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15o d15o "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15p d15px "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
session_jsonl D /Users/t/d15p d15py "$E_SEP3_2000" "2026-08-30T00:00:00.000Z"
printf '%s' '{"d15o":{"pid":30059,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15o"},"d15px":{"pid":30060,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15p"},"d15py":{"pid":30060,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15p"}}' | cmux_store D
cat > "$T/D/gone-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '%s\n' "30060 400000 30060 ttys425 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d15p" > "\$FAKE_PS_SOURCE"
        printf '%s' '{"d15py":{"pid":30060,"pidStartSeconds":$E_SEP3_2000,"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":$E_AUG31_0000,"cwd":"/Users/t/d15p"}}' > "$T/D/cmux/pi-hook-sessions.json"
        ;;
esac
SH
chmod +x "$T/D/gone-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/gone-side.sh" REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30059" "D15i trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30060" "D15i deciding record vanishing from the store suppresses"
assert_contains "$(cat "$T/D/reap.log")" "stuck row record no longer frozen" "D15i deciding-record-gone suppress reason logged"
rm -rf "$T/D/sessions" "$T/D/gone-side.sh"

# D16: a value-less --idle-hours / --stuck-hours must exit 2, not spin forever
# (pre-existing hang; the new --stuck-hours inherited it — review P2).
for FLAG in --idle-hours --stuck-hours; do
    REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run "$FLAG" > "$T/D/d16.out" 2>&1 &
    D16PID=$!
    # bounded poll, not a fixed sleep: a loaded box must not report a correct
    # immediate exit as a HANG (review P2)
    D16HUNG=1
    for _ in $(seq 1 200); do
        kill -0 "$D16PID" 2>/dev/null || { D16HUNG=0; break; }
        sleep 0.05
    done
    if [ "$D16HUNG" = 1 ]; then
        # kill the CHILD first (a killed parent reparents it to pid 1 and
        # `pkill -P` then misses it — orphan leak). pkill here is
        # intentionally unshimmed and only ever targets this subshell's own
        # children.
        pkill -9 -P "$D16PID" 2>/dev/null
        kill -9 "$D16PID" 2>/dev/null
        wait "$D16PID" 2>/dev/null
        bad "D16 $FLAG with no value exits 2 (HUNG instead)"
    else
        wait "$D16PID" 2>/dev/null; D16RC=$?
        assert_eq "$D16RC" "2" "D16 $FLAG with no value exits 2 (no hang)"
    fi
done

# D17: 0-valued stale stamp is rejected by the plausibility window (the "0" case
# in D13) — and a REAL epoch just inside the window still works (guards the
# guard: the plausibility bound must not reject live data).
running_record_fixture 30051 ttys414 d17 /Users/t/d17 "2026-08-31T00:00:00.000Z" "$E_AUG31_0000"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"
assert_contains "$OUT" "STUCK-ESCALATE" "D17 a real stale epoch still classifies STUCK (bound did not over-reject)"
rm -rf "$T/D/sessions"

# D18: fail-closed on an unavailable descendant map (pre-existing fail-open
# closed here, because the #947 no-live-child guard leans on the same map). A
# map build failure makes has_live_pi_descendant()/has_live_child() answer "no"
# for EVERY pid, silently disabling the orchestrating-skip and the stuck arm's
# no-child guard => a session running tool work could be reaped.
# Probe: a genuine INTERPRETER failure (a failing python3 shim first on the
# reaper's PATH), installed last so no earlier fixture sees it. Legs: (A) abort
# with candidates; (B) clean no-op with 0 candidates (isolates `pre_count`);
# (C) a malformed ROW is skipped, not fatal.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/python3"
chmod +x "$T/bin/python3"
running_record_fixture 30061 ttys415 d18 /Users/t/d18 "2026-08-31T00:00:00.000Z" cold
: > "$T/D/kill.log"; : > "$T/D/reap.log"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply > "$T/D/d18.out" 2>&1
D18RC=$?
assert_eq "$D18RC" "3" "D18A descendant-map build failure with candidates aborts (exit 3)"
assert_contains "$(cat "$T/D/d18.out")" "FAIL-CLOSED abort: descendant map unavailable" "D18A abort message names the map"
assert_contains "$(cat "$T/D/reap.log")" "descendant map unavailable" "D18A abort recorded in the log footer proof"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_ARMED=" "D18A abort footer keeps the STUCK_ARMED field"
[ ! -s "$T/D/kill.log" ] && ok "D18A zero signals on descendant-map failure" || bad "D18A zero signals on descendant-map failure"
# leg B: same broken interpreter, ZERO candidates => must stay a clean no-op
# (deleting the `pre_count > 0` conjunct would abort the hourly job nightly)
: > "$T/D/ps-source"; : > "$T/D/reap.log"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply > "$T/D/d18b.out" 2>&1
assert_eq "$?" "0" "D18B zero candidates with a failed map is a no-op (not an abort)"
assert_not_contains "$(cat "$T/D/d18b.out")" "FAIL-CLOSED abort" "D18B no-candidate pass never aborts"
# leg C: a malformed row (non-numeric ppid) is now SKIPPED at the row level —
# the map still builds, so the pass runs normally. One stray byte in an argv
# (or one bad row) must never read as "map unavailable" and stop reaping
# forever (review P2: a UnicodeDecodeError here was a quiet hourly DoS).
rm -f "$T/bin/python3"
printf '%s\n' "$(psrow 30061 400000 30061 ttys415 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d18")" \
               "$(psrow 30062 NOPE 30062 ttys415 "Thu Sep  3 20:00:00 2026" S 2000 "/usr/local/bin/pi --cwd /Users/t/d18b")" > "$T/D/ps-source"
: > "$T/D/reap.log"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run > "$T/D/d18c.out" 2>&1
assert_eq "$?" "0" "D18C a malformed ps row is skipped, not fatal (no abort)"
assert_not_contains "$(cat "$T/D/d18c.out")" "FAIL-CLOSED abort" "D18C malformed row never reads as map-unavailable"
assert_contains "$(cat "$T/D/d18c.out")" "30061" "D18C the candidate is still classified after the bad row"
# leg D: the row-level skip must also survive an UNDECODABLE argv byte. BSD ps
# prints argv raw, so ONE non-UTF-8 byte in any process's argv used to raise
# UnicodeDecodeError and sink the whole map => the new abort => a permanent
# hourly no-reap. Only `errors="replace"` protects this (D18C exercises the
# int() skip, not the decoder).
{ printf '%s' "30061 400000 30061 ttys415 Thu Sep  3 20:00:00 2026 S 30000 /usr/local/bin/pi --cwd /Users/t/d18"; printf '\xff'; printf 'b\n'; } > "$T/D/ps-source"
: > "$T/D/reap.log"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run > "$T/D/d18d.out" 2>&1
assert_eq "$?" "0" "D18D an undecodable argv byte does not sink the map (exit 0)"
assert_not_contains "$(cat "$T/D/d18d.out")" "FAIL-CLOSED abort" "D18D undecodable byte never reads as map-unavailable"
assert_contains "$(cat "$T/D/d18d.out")" "30061" "D18D the candidate is still classified with a bad byte present"
# leg E: `--list` is a read-only diagnostic — it must work when the map CANNOT
# build (broken interpreter), print the candidates, and leave the log alone.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/python3"
chmod +x "$T/bin/python3"
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --list 2>&1)"; D18ERC=$?
assert_eq "$D18ERC" "0" "D18E --list works with a broken interpreter (exit 0)"
assert_contains "$OUT" "30061" "D18E --list prints the candidate list"
assert_not_contains "$OUT" "FAIL-CLOSED abort" "D18E --list is never blocked by the abort"
[ ! -s "$T/D/reap.log" ] && ok "D18E --list is read-only (no log write)" || bad "D18E --list is read-only (no log write)"
rm -f "$T/bin/python3"
rm -rf "$T/D/sessions"

# D19b (review P2): `$(( 10#... ))` WRAPS past bash's signed 64-bit range, so a
# huge digit string normalized to 0 — which would make "idle > 0" true for
# every session. Out-of-range values must be usage errors.
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 18446744073709551616 2>&1)"; D19BRC=$?
assert_eq "$D19BRC" "2" "D19b --idle-hours 2^64 (wraps to 0) is rejected, not accepted"
assert_contains "$OUT" "out of range" "D19b out-of-range message names the bound"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --stuck-hours 99999999999999999999 2>&1)"; D19CRC=$?
assert_eq "$D19CRC" "2" "D19b --stuck-hours beyond the cap is rejected"

# D20 (review P1): store values are UNTRUSTED and bash `$(( ))` re-parses an
# operand as an ARITHMETIC EXPRESSION — a crafted pidStartSeconds executed code
# as the user. The record must be treated as unusable (abstain), never
# evaluated: no "INJECTED" on any stream, and the pass must not abort either
# (a bare word used to kill the whole pass with no footer).
printf '%s\n' "$(psrow 30091 400000 30091 ttys426 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d20")" > "$T/D/ps-source"
session_jsonl D /Users/t/d20 d20 "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d20":{"pid":30091,"pidStartSeconds":"epoch[$(echo INJECTED >&2)]","agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d20"}}' | cmux_store D
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"; D20RC=$?
assert_eq "$D20RC" "0" "D20 a crafted pidStartSeconds does not abort the pass"
assert_not_contains "$OUT" "INJECTED" "D20 a crafted pidStartSeconds is never evaluated as shell"
assert_contains "$OUT" "no-pidStartSeconds abstain" "D20 the crafted value is treated as an unusable stamp (abstain)"
assert_contains "$(cat "$T/D/reap.log")" "MODE=dry-run" "D20 the pass still writes its footer proof"
rm -rf "$T/D/sessions"

# D21 (review P2): a broken `ps` must not masquerade as an idle machine. With
# `|| true` the empty table was indistinguishable from "no pi sessions" — exit
# 0 with a healthy footer, every hour, forever.
cp "$T/bin/ps" "$T/bin/ps.orig"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/ps"
chmod +x "$T/bin/ps"
: > "$T/D/reap.log"; : > "$T/D/kill.log"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply > "$T/D/d21.out" 2>&1; D21RC=$?
mv "$T/bin/ps.orig" "$T/bin/ps"
assert_eq "$D21RC" "3" "D21 a failed ps enumeration aborts (exit 3), not a healthy no-op"
assert_contains "$(cat "$T/D/d21.out")" "ps enumeration failed" "D21 abort names the ps failure"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_ARMED=" "D21 abort footer is written"
[ ! -s "$T/D/kill.log" ] && ok "D21 zero signals when ps is broken" || bad "D21 zero signals when ps is broken"
rm -rf "$T/D/sessions"

# D19: the derived stuck bound is DECIMAL. bash's $(( )) reads a zero-padded
# value as octal while awk reads it as decimal, so REAP_IDLE_HOURS=024 gave awk
# 24h but a bound of $((024*3)) = 60 (documented: 72).
running_record_fixture 30071 ttys421 d19 /Users/t/d19 "2026-09-03T20:00:00.000Z" "$E_SEP3_2000"
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 024 2>&1)"; D19RC=$?
assert_eq "$D19RC" "0" "D19 --idle-hours 024 is accepted"
assert_contains "$(cat "$T/D/reap.log")" "THRESHOLD=24 STUCK_HOURS=72" "D19 zero-padded threshold derives the DECIMAL 3x bound (72, not 60)"
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 08 2>&1)"; D19RC=$?
assert_eq "$D19RC" "0" "D19 --idle-hours 08 is accepted (no octal abort)"
assert_contains "$(cat "$T/D/reap.log")" "THRESHOLD=8 STUCK_HOURS=24" "D19 08 normalizes to decimal 8 and derives 24"
rm -rf "$T/D/sessions"

# D15j (review P1): the settle-time fresh enumeration is only EVIDENCE if it
# ran. A failed/empty settle `ps` used to make descendant_map_build "succeed"
# on an empty map, has_live_child answer "no child" for every pid, and the
# guard silently vanish — reproduced as a real TERM+KILL of a session with a
# live tool child. The row must SUPPRESS instead.
printf '%s\n' "$(psrow 30062 400000 30062 ttys427 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d15q")" > "$T/D/ps-source"
session_jsonl D /Users/t/d15q d15q "$E_SEP3_2000" "2026-08-31T00:00:00.000Z"
printf '%s' '{"d15q":{"pid":30062,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"running","runtimeStatus":"idle","updatedAt":'$E_AUG31_0000',"cwd":"/Users/t/d15q"}}' | cmux_store D
: > "$T/D/bulk-count"; : > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_PS_BULK_LOG="$T/D/bulk-count" FAKE_PS_FAIL_BULK_N=2 REAP_REAP_STUCK=1 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"; D15JRC=$?
assert_eq "$D15JRC" "0" "D15j a failed settle enumeration does not abort the pass"
[ ! -s "$T/D/kill.log" ] && ok "D15j failed settle enumeration suppresses the kill (0 signals)" || bad "D15j failed settle enumeration suppresses the kill (0 signals)"
assert_contains "$(cat "$T/D/reap.log")" "fresh ps enumeration unavailable" "D15j the suppress reason is logged"
rm -rf "$T/D/sessions"

# D21b (review P2): a PARTLY failed `ps` (rc!=0 but rows emitted) is the same
# hazard in a quieter form — a truncated table silently reads as "no live
# child", so an armed pass must abort, not proceed on a subset.
: > "$T/D/kill.log"; : > "$T/D/reap.log"; : > "$T/D/bulk-count"
REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY \
    FAKE_PS_BULK_LOG="$T/D/bulk-count" FAKE_PS_FAIL_BULK_N=1 FAKE_PS_FAIL_PARTIAL=1 \
    run_reaper D --apply > "$T/D/d21b.out" 2>&1; D21BRC=$?
assert_eq "$D21BRC" "3" "D21b a partially-failed ps aborts (exit 3) despite emitting rows"
assert_contains "$(cat "$T/D/d21b.out")" "candidates=" "D21b the abort reports the candidate count it saw"
[ ! -s "$T/D/kill.log" ] && ok "D21b zero signals on a truncated ps table" || bad "D21b zero signals on a truncated ps table"
rm -rf "$T/D/sessions"

# D21c (review P2): `--list` is the diagnostic surface an operator reaches for
# when the reaper misbehaves — a silent empty list would look like "no
# sessions". It must report a failed enumeration (stderr, exit 3).
: > "$T/D/reap.log"; : > "$T/D/bulk-count"
OUT="$(FAKE_PS_BULK_LOG="$T/D/bulk-count" FAKE_PS_FAIL_BULK_N=1 REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --list 2>&1)"; D21CRC=$?
assert_eq "$D21CRC" "3" "D21c --list exits 3 when its ps probe failed"
assert_contains "$OUT" "--list: ps enumeration failed" "D21c --list names the failure instead of printing nothing"
[ ! -s "$T/D/reap.log" ] && ok "D21c --list still writes no log on the failure path" || bad "D21c --list still writes no log on the failure path"

# D22 (review P2): REAP_MAX_HOURS is itself an operator env seam gating both
# thresholds; a non-numeric value used to make the range comparison error and
# turn EVERY pass into an exit-2 with no documented knob.
OUT="$(REAP_MAX_HOURS=abc REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"; D22RC=$?
assert_eq "$D22RC" "2" "D22 a non-numeric REAP_MAX_HOURS is a usage error"
assert_contains "$OUT" "bad REAP_MAX_HOURS" "D22 the message names the env seam"

# D22b (review P2): the `LOCK raced` branch must write the same reduced footer
# as the live-owner branch — a monitor keying on STUCK_ARMED must never read
# the previous pass's values on a lock abort. An unwritable STATE_DIR forces the
# raced branch (the lock dir cannot be created at all).
mkdir -p "$T/D/home/.pi/agent/state"
: > "$T/D/reap.log"
chmod 500 "$T/D/home/.pi/agent/state" 2>/dev/null
REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run > "$T/D/d22b.out" 2>&1; D22BRC=$?
chmod 700 "$T/D/home/.pi/agent/state" 2>/dev/null
assert_eq "$D22BRC" "3" "D22b a lock that cannot be created aborts (exit 3)"
assert_contains "$(cat "$T/D/reap.log")" "LOCK raced" "D22b the raced lock branch is the one taken"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_HOURS=72" "D22b the LOCK raced abort footer carries the stuck bound"
assert_contains "$(cat "$T/D/reap.log")" "STUCK_ARMED=0" "D22b the LOCK raced abort footer carries STUCK_ARMED"

# D22c (review P2): a 2^64 multiple wraps to a value INSIDE the bound, so
# bounding the residue accepted it (2^64+1 => THRESHOLD=1 => reap almost
# everything). The RAW digit string must be bounded before normalization.
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 18446744073709551617 2>&1)"; D22CRC=$?
assert_eq "$D22CRC" "2" "D22c --idle-hours 2^64+1 (wraps to 1) is rejected"
assert_contains "$OUT" "out of range" "D22c the wrap-by-multiple case is named"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --stuck-hours 18446744073709551617 2>&1)"; D22DRC=$?
assert_eq "$D22DRC" "2" "D22c --stuck-hours 2^64+1 (wraps to 1) is rejected"
# ...and the derived bound is NOT clamped by REAP_MAX_HOURS (a regression the
# residue check introduced: --idle-hours 333334 => stuck 1000002 > cap =>
# exit 2 naming a flag the user never passed).
: > "$T/D/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 333334 2>&1)"; D22ERC=$?
assert_eq "$D22ERC" "0" "D22c a large in-range --idle-hours is accepted"
assert_contains "$(cat "$T/D/reap.log")" "THRESHOLD=333334 STUCK_HOURS=1000002" "D22c the derived stuck bound is not capped"

# D22d (review P1): the DERIVED stuck bound is arithmetic, so it can wrap. A
# huge REAP_MAX_HOURS makes an accepted --idle-hours overflow signed 64-bit:
# 4e18*3 -> -6446744073709551616, and a NEGATIVE bound makes every age test
# true (`a > -6e18`) — an actively working session classifies STUCK and, under
# the arm, is TERM+KILLed (reproduced end-to-end by review). Pre-fix this input
# was accepted; the old code caught it only by accident (the residue check).
OUT="$(REAP_MAX_HOURS=4000000000000000000 REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 4000000000000000000 2>&1)"; D22DRC=$?
assert_eq "$D22DRC" "2" "D22d a wrapped (negative) derived stuck bound is rejected"
assert_contains "$OUT" "bad derived --stuck-hours" "D22d the message names the derived bound, not the flag the user passed"
OUT="$(REAP_MAX_HOURS=5000000000000000000 REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 5000000000000000000 2>&1)"; D22ERC=$?
assert_eq "$D22ERC" "2" "D22d a second wrapping case (5e18*3) is rejected too"
# positive control: a large derived bound that does NOT wrap stays usable.
OUT="$(REAP_MAX_HOURS=3000000000000000000 REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 3000000000000000000 2>&1)"; D22FRC=$?
assert_eq "$D22FRC" "0" "D22d a large non-wrapping derived bound is still accepted"
# D22e (round-5 review P1): a 64-bit wrap can land POSITIVE, which a positivity
# check accepts. `$(( 6148914691236517206 * 3 ))` = 2 (3N-2^64), so a "7e14-year"
# bound silently became 2 HOURS — a 3h-stale non-idle session flips STUCK and is
# TERM+KILLed under the arm (reproduced end-to-end). Wrap detection must be
# monotonicity, not sign.
for D22E in 6148914691236517206 6148914691236517205 6148914691236517207 9223372036854775807; do
    OUT="$(REAP_MAX_HOURS=$D22E REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours $D22E 2>&1)"; D22ERC=$?
    assert_eq "$D22ERC" "2" "D22e a positive-wrapping derived bound (idle=$D22E) is rejected"
done
assert_contains "$OUT" "bad derived --stuck-hours" "D22e the positive-wrap rejection names the derived bound"
# D22f (round-6 review P2): the stuck bound ESCALATES the idle bound, so an
# explicit value below it is a contradiction — the stuck arm compares
# `idle_age_h > REAP_STUCK_HOURS`, so `--stuck-hours 1` (default idle 24h) TERM'd
# a session idle only 2h, bypassing the idle proof the header contract requires.
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 24 --stuck-hours 1 2>&1)"; D22FRC=$?
assert_eq "$D22FRC" "2" "D22f an explicit --stuck-hours below the idle threshold is rejected"
assert_contains "$OUT" "below the idle threshold" "D22f the message explains the escalation rule"
OUT="$(REAP_NOW_EPOCH=$NOW FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run --idle-hours 24 --stuck-hours 48 2>&1)"; D22GRC=$?
assert_eq "$D22GRC" "0" "D22f an explicit --stuck-hours ABOVE the idle threshold is still accepted"

# D23 (review P2): the post-pass read feeds POST/RESIDUAL only, but a failed
# post-pass must not be reported as a fresh count — a stale candidate list made
# a failed read byte-identical to a clean one.
: > "$T/D/ps-source"; : > "$T/D/reap.log"; : > "$T/D/bulk-count"
OUT="$(FAKE_PS_BULK_LOG="$T/D/bulk-count" FAKE_PS_FAIL_BULK_N=2 REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --dry-run 2>&1)"; D23RC=$?
assert_eq "$D23RC" "0" "D23 a failed POST-pass enumeration does not abort the pass"
assert_contains "$(cat "$T/D/reap.log")" "POST-PASS ps enumeration failed" "D23 the degradation is logged"
assert_contains "$(cat "$T/D/reap.log")" "POST=?" "D23 POST is reported as unknown, not as a stale count"
assert_contains "$(cat "$T/D/reap.log")" "RESIDUAL=?" "D23 RESIDUAL is degraded too (dry-run) — the doc's claim is code-true"

# D24 (round-6 review P2): the UNION settle probe set applies to the NORMAL
# (non-stuck) path too. A strictly-older matched twin that advances in the
# classify->settle window must suppress — probing only the max-epoch deciding
# file (the pre-round-6 field) would TERM it.
printf '%s\n' "$(psrow 30063 400000 30063 ttys428 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d24a")" \
               "$(psrow 30064 400000 30064 ttys428 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/d24b")" > "$T/D/ps-source"
session_jsonl D /Users/t/d24a d24c "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl D /Users/t/d24b d24new "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
session_jsonl D /Users/t/d24b d24old "$E_SEP3_2000" "2026-09-02T20:00:00.000Z"
printf '%s' '{"d24c":{"pid":30063,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/d24a"},"d24new":{"pid":30064,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/d24b"},"d24old":{"pid":30064,"pidStartSeconds":'$E_SEP3_2000',"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/d24b"}}' | cmux_store D
cat > "$T/D/norm-union-side.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    -TERM)
        printf '{"type":"message","role":"user","timestamp":"2026-09-05T01:00:00.000Z","content":"hi"}\n' >> "$T/D/sessions/--Users-t-d24b--/${E_SEP3_2000}_d24old.jsonl"
        ;;
esac
SH
chmod +x "$T/D/norm-union-side.sh"
: > "$T/D/kill.log"; : > "$T/D/reap.log"
OUT="$(FAKE_KILL_SIDE="$T/D/norm-union-side.sh" REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper D --apply 2>&1)"
assert_contains "$(cat "$T/D/kill.log")" "kill -TERM -30063" "D24 trigger candidate TERM'd normally"
assert_not_contains "$(cat "$T/D/kill.log")" "30064" "D24 normal row: a strictly-older twin's advance suppresses (union probe set)"
assert_contains "$(cat "$T/D/reap.log")" "activity advanced" "D24 normal-row union probe reason logged"
rm -rf "$T/D/sessions" "$T/D/norm-union-side.sh"

rm -rf "$T/D"

echo "fixture pack E: candidate-ancestry gate 3 (#1207) — ADDITIVE refusals"
mk_env E
make_lookup "$T/E/date.lookup"
FAKE_SELF_TTY=tts900

# E0: the scenario copy is the shipped script plus EXACTLY the one relaxed
# line. Without this pin the copy could drift into a different artifact while
# every pack below stayed green.
assert_eq "$(diff "$REAPER" "$REAPER_G3OFF" | grep -c '^[<>]')" "2" \
    "E0 scenario copy differs from the shipped reaper by exactly one line (1 removed + 1 added)"
assert_contains "$(cat "$REAPER_G3OFF")" "cmux) return 0 ;;" "E0 scenario copy carries the relaxed cmux arm"
assert_not_contains "$(cat "$REAPER")" "cmux) return 0 ;;" "E0 the SHIPPED reaper keeps cmux report-only (option A)"

# E1: Terminal.app -> login -> -zsh -> <target> with an idle-30h (parked)
# profile. The near-miss shape. Must NOT be signalled, on the REAL reaper, and
# must be refused on the human-terminal ground.
printf '%s\n' \
    "$(psrow 21001 500001 21001 ttys500 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/e1")" \
    "$(psrow 500001 500002 500001 ?? "Thu Sep  3 20:00:00 2026" S 0 "-zsh")" \
    "$(psrow 500002 500003 500002 ?? "Thu Sep  3 20:00:00 2026" S 0 "/usr/bin/login -flp danielospina /bin/bash --noprofile --norc -c exec -l /bin/zsh")" \
    "$(psrow 500003 1 500003 ?? "Thu Sep  3 20:00:00 2026" S 0 "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")" \
    > "$T/E/ps-source"
printf '{"e1":{"pid":21001,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/e1"}}' "$E_SEP3_2000" | cmux_store E
session_jsonl E /Users/t/e1 e1 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
: > "$T/E/kill.log"; : > "$T/E/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper_real E --apply 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "E1 Terminal.app chain is NEVER reap-eligible"
assert_contains "$OUT" "REPORT-ONLY gate3=human-terminal" "E1 refused, and the ground named, as human-terminal"
[ ! -s "$T/E/kill.log" ] && ok "E1 armed pass sent ZERO signals for the human-terminal chain" \
    || bad "E1 armed pass sent ZERO signals for the human-terminal chain"
assert_contains "$(cat "$T/E/reap.log")" "GATE3_REFUSED=1 GATE3_HUMAN=1 GATE3_CMUX=0 GATE3_UNKNOWN=0 GATE3_ALLOWED=0" \
    "E1 footer carries the gate-3 refusal counters by ground"
rm -rf "$T/E/sessions"

# E2: the SAME idle-30h profile on a cmux-rooted chain (the shim's default —
# the live fleet's real shape). Option A: report-only, never signalled. The
# output must also SAY the zero harvest is the intended state, so a future
# reader does not read it as a broken reaper.
idle30h_fixture E 21002 ttys501 e2 /Users/t/e2
: > "$T/E/kill.log"; : > "$T/E/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper_real E --apply 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "E2 cmux-rooted chain is NEVER reap-eligible (option A)"
assert_contains "$OUT" "REPORT-ONLY gate3=cmux" "E2 refused, and the ground named, as cmux-rooted"
assert_contains "$OUT" "the harvest is ZERO by DECISION, not by fault" \
    "E2 the report says the zero harvest is intended, not a fault"
[ ! -s "$T/E/kill.log" ] && ok "E2 armed pass sent ZERO signals for the cmux-rooted chain" \
    || bad "E2 armed pass sent ZERO signals for the cmux-rooted chain"
assert_contains "$(cat "$T/E/reap.log")" "GATE3_REFUSED=1 GATE3_HUMAN=0 GATE3_CMUX=1 GATE3_UNKNOWN=0 GATE3_ALLOWED=0" \
    "E2 footer attributes the refusal to the cmux-rooted ground"
rm -rf "$T/E/sessions"

# E3: an UNRESOLVABLE chain (the candidate's parent is not in the table).
# Fail closed: reported, not killed.
printf '%s\n' \
    "$(psrow 21003 600001 21003 ttys502 "Thu Sep  3 20:00:00 2026" S 30000 "/usr/local/bin/pi --cwd /Users/t/e3")" \
    > "$T/E/ps-source"
printf '{"e3":{"pid":21003,"pidStartSeconds":%s,"agentLifecycle":"idle","runtimeStatus":"idle","cwd":"/Users/t/e3"}}' "$E_SEP3_2000" | cmux_store E
session_jsonl E /Users/t/e3 e3 "$E_SEP3_2000" "2026-09-03T20:00:00.000Z"
: > "$T/E/kill.log"; : > "$T/E/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper_real E --apply 2>&1)"
assert_not_contains "$OUT" "REAP-ELIGIBLE" "E3 unresolvable chain is reported, not killed"
assert_contains "$OUT" "REPORT-ONLY gate3=unknown" "E3 refusal names the unknown (fail-closed) ground"
[ ! -s "$T/E/kill.log" ] && ok "E3 armed pass sent ZERO signals for the unresolvable chain" \
    || bad "E3 armed pass sent ZERO signals for the unresolvable chain"
assert_contains "$(cat "$T/E/reap.log")" "GATE3_REFUSED=1 GATE3_HUMAN=0 GATE3_CMUX=0 GATE3_UNKNOWN=1 GATE3_ALLOWED=0" \
    "E3 footer attributes the refusal to the unknown ground"
rm -rf "$T/E/sessions"

# E4 (RED CONTROL): the very same cmux-rooted idle-30h fixture, run on the
# scenario copy whose cmux arm is relaxed. It IS eligible and IS signalled —
# which is what makes E2 load-bearing: relax the cmux arm and E2 goes RED.
idle30h_fixture E 21004 ttys503 e4 /Users/t/e4
: > "$T/E/kill.log"; : > "$T/E/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper E --apply 2>&1)"
assert_contains "$OUT" "REAP-ELIGIBLE" \
    "E4 RED control: with the cmux arm relaxed the SAME chain IS eligible (E2 would go RED)"
assert_contains "$(cat "$T/E/kill.log")" "kill -TERM -21004" \
    "E4 RED control: the mutated copy actually signals the cmux chain"
assert_contains "$OUT" "GATE 3 (candidate-ancestry)" "E4 the report block is emitted on every classified pass"
assert_not_contains "$OUT" "the harvest is ZERO by DECISION" \
    "E4 the zero-harvest wording is suppressed once a candidate is allowed (truthful on the mutant)"
rm -rf "$T/E/sessions"

# E5 (defence in depth): a candidate whose CLASSIFY-time verdict is bypassed
# is still refused at the SIGNAL point by reap_one's re-ask. Mutant: neutralise
# ONLY the two classify-site checks (the settle-time check is the same
# function and stays live), so the candidate reaches REAP_CANDIDATES and the
# settle gate is the single thing that can stop the signal.
REAPER_NOCLASSIFY="$T/bin/pi-reap-idle-noclassify.sh"
sed 's/if \[ "\$gate3_ok" != 1 \]; then/if [ "$gate3_ok" = 99 ]; then/g' "$REAPER" > "$REAPER_NOCLASSIFY"
assert_eq "$(diff "$REAPER" "$REAPER_NOCLASSIFY" | grep -c '^[<>]')" "4" \
    "E5 precondition: the bypass mutant changed the two classify checks and nothing else"
idle30h_fixture E 21005 ttys504 e5 /Users/t/e5
: > "$T/E/kill.log"; : > "$T/E/reap.log"
OUT="$(REAP_NOW_EPOCH=$NOW REAP_IDLE_HOURS=24 REAP_GRACE_SECONDS=0 FAKE_SELF_TTY=$FAKE_SELF_TTY run_reaper_bin "$REAPER_NOCLASSIFY" E --apply 2>&1)"
assert_contains "$OUT" "REAP-ELIGIBLE" "E5 precondition: the classify-site bypass marks the candidate eligible"
assert_contains "$(cat "$T/E/reap.log")" "SETTLE-SKIP 21005 gate 3 refused" \
    "E5 the settle-time re-ask is what suppresses the signal (defence in depth)"
[ ! -s "$T/E/kill.log" ] && ok "E5 zero signals despite the classify-site bypass" \
    || bad "E5 zero signals despite the classify-site bypass"
rm -rf "$T/E/sessions"

rm -rf "$T/E"

echo "════════════════════════════════════════════════════════════════"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
