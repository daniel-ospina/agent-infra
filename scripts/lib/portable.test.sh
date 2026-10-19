#!/usr/bin/env bash
# scripts/lib/portable.test.sh — the portability shim's own proof (agent-infra#2046, #2048).
#
# WHAT THIS SUITE IS FOR. #2046's defect was not "the reaper is wrong" — it was "the reaper cannot
# EXECUTE on this platform, and reports a considered result anyway". A shim that is merely present
# proves nothing: each helper must be shown to return a CORRECT value for THIS platform, at the
# moment it runs. So every assertion below is computed against an INDEPENDENT truth for the host the
# suite is running on (the test carries its own `stat`/`nproc` probes rather than trusting the
# helper's), and the platform is printed at the top so a green run can never be misread as "passed on
# a platform we did not test".
#
#   P1 the platform is reported, non-empty, and agrees with uname(1)
#   P2 _timeout: the child's own status passes through; a real overrun is 124 (THE #2046 assertion —
#      on macOS this is the internal watchdog, because neither `timeout` nor `gtimeout` exists);
#      a non-integer bound is 125 and the command does NOT run (fail-closed, never fail-open);
#      0 means unbounded and still runs the command; the resolved mechanism matches the host
#   P3 _nproc: a positive integer equal to this platform's independent CPU count; with no probe on
#      PATH it returns EMPTY + non-zero rather than a fabricated 1
#   P4 _stat_size: exact bytes, including a name with a space and a newline, a leading-dash name, and
#      an EMPTY file where 0 is a real answer and must not be confused with "unmeasurable"
#   P5 _stat_mtime: epoch seconds, matching the test's own platform probe
#   P6 _date: --epoch/--iso/--parse (ISO, date-only, @epoch, relative, and the anchored epoch 0)/--add
#      agree with each other and with the calendar; garbage returns EMPTY + non-zero, never 0
#   P7 a missing bounded-execution engine is a REFUSAL at source time, naming what is missing
#   P8 the whole shim loads and every helper works under the platform's SYSTEM bash (macOS 3.2 — a
#      bash-4-ism here would pass on Linux CI and break the laptop)
#
# Hermetic: fixtures live under $T, HOME is not read for state, and nothing outside $T is written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/portable.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
assert_num()      { case "${1:-}" in ''|*[!0-9]*) bad "$2 (not a number: '${1:-}')" ;; *) ok "$2" ;; esac; }
assert_empty()    { if [ -z "${1:-}" ]; then ok "$2"; else bad "$2 (expected empty, got: '$1')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_within()   { # assert_within <value> <expected> <tolerance> <label>
    local d=$(( $1 - $2 )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le "$3" ]; then ok "$4 (Δ${d}s ≤ ${3}s)"; else bad "$4 (off by ${d}s)"; fi
}
assert_rc()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (rc=$1, want $2)"; fi; }

[ -f "$SHIM" ] || { echo "FATAL: $SHIM missing — this suite tests the shim, and there is none"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/portable-test.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"

# The shim under test, loaded exactly the way a component loads it.
# shellcheck source=portable.sh
. "$SHIM" || { echo "FATAL: cannot source $SHIM"; exit 1; }

# ── the host's own truth, computed WITHOUT the helper under test ────────────────────────────────
# Deliberately independent implementations: if the shim and this probe ever disagree, the shim is
# wrong on this platform — which is the only thing this suite exists to detect.
HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
host_nproc() {
    case "$HOST_PLATFORM" in
        darwin) sysctl -n hw.ncpu 2>/dev/null ;;
        *)      getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null ;;
    esac
}
host_size()  { wc -c < "$1" 2>/dev/null | tr -d '[:space:]'; }
host_mtime() {
    # Keyed on uname, NOT on the shim's own `_portable_platform`: a probe that shares the helper's
    # detection cannot falsify it. (A `stat -f` PROBE is not usable here — GNU stat accepts -f too,
    # so the probe succeeds on Linux and would silently pick the BSD spelling.)
    case "$HOST_PLATFORM" in
        darwin|*bsd*) stat -f '%m' "$1" 2>/dev/null ;;
        *)            stat -c '%Y' "$1" 2>/dev/null ;;
    esac
}

echo "══ portable shim — running on platform=$HOST_PLATFORM bash=$BASH_VERSION ══"

# ── P1 platform ────────────────────────────────────────────────────────────────────────────────
echo "── P1 platform ──"
assert_eq "$(_portable_platform)" "$HOST_PLATFORM" "P1 _portable_platform agrees with uname -s (lowercased)"
assert_eq "$(PORTABLE_PLATFORM=linux _portable_platform)" "linux" "P1 the detection override is honoured (a test can assert the other branch)"

# ── P2 _timeout ────────────────────────────────────────────────────────────────────────────────
echo "── P2 _timeout ──"
_timeout 5 true; assert_rc $? 0 "P2 a command that succeeds returns 0"
_timeout 5 sh -c 'exit 7'; assert_rc $? 7 "P2 the CHILD's own status is what the caller sees (7)"
MARKER="$T/ran-noninteger"
_timeout notanumber sh -c "touch '$MARKER'"; rc=$?
assert_rc "$rc" 125 "P2 a non-integer bound is 125 (GNU timeout's answer), never unbounded"
[ -f "$MARKER" ] && bad "P2 …and the command did NOT run (fail-closed)" || ok "P2 …and the command did NOT run (fail-closed)"
mkdir -p "$T/ran-zero"
_timeout 0 sh -c 'exit 3'; assert_rc $? 3 "P2 bound 0 means unbounded and still runs the command (rc=3)"

# THE #2046 assertion: a real overrun is 124 and it actually stops. On this Mac there is neither
# `timeout` nor `gtimeout`, so this exercises the internal background watchdog — the path that DID
# NOT EXIST before #2046 and made every class fail closed.
START="$(date +%s)"
_timeout 1 sleep 30; rc=$?
ELAPSED=$(( $(date +%s) - START ))
assert_rc "$rc" 124 "P2 an overrun is 124 (a timeout, the status every caller treats as fail-closed)"
# ⛔ A 1s bound that lands at 9s is not a bound. `< 10` was green for a regression 9x over.
if [ "$ELAPSED" -le 3 ]; then ok "P2 …and it actually STOPPED the child (${ELAPSED}s, not 30s)"; else bad "P2 the child was not stopped (${ELAPSED}s, 9x the bound)"; fi

# ⛔ THE BOUND MUST REACH THE DESCENDANTS. `kill -9 <child>` leaves a grandchild running, so a bounded
# delegate that shells out to `du`/`rm -rf` keeps deleting against a disk whose free-space delta the
# next pass measures mid-deletion. GNU `timeout` signals the process group; so must this.
_timeout 1 sh -c 'sleep 747 & wait' >/dev/null 2>&1; rc=$?
assert_rc "$rc" 124 "P2 a bounded command whose CHILD holds the work still times out"
# Poll rather than sleep-and-look: on a loaded box the group kill can land a moment after the parent
# returns, and a 1s window would report a leak that is only a scheduling delay (measured: this pair went
# red under a full shard sweep and green on a quiet box, same bytes). The claim is "it does not SURVIVE",
# not "it dies within one second" — so give it up to 5s and report the wait actually needed.
_gone=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f 'sleep 747' >/dev/null 2>&1 || { _gone=1; break; }
    sleep 0.5
done
if [ "$_gone" = "1" ]; then
    ok "P2 …and the descendant did not survive the bound (the bound is a process group, not a single pid)"
else
    bad "P2 the DESCENDANT survived the bound (a grandchild is still running after 5s)"
    pkill -f 'sleep 747' 2>/dev/null || true
fi

# ⛔ THE TIMER MUST NOT OUTLIVE THE PROBE. The watchdog's TERM trap can fire in the window between
# `sleep &` and `s=$!`; the timer then survives for the WHOLE bound, reparented to pid 1 — and the
# reaper calls this once per candidate.
for i in 1 2 3 4 5 6 7 8; do _timeout 787 true; done
# Same polling rule as above: the watchdog's own cleanup may need a beat under load.
_gone=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f 'sleep 787' >/dev/null 2>&1 || { _gone=1; break; }
    sleep 0.5
done
if [ "$_gone" = "1" ]; then
    ok "P2 eight fast returns leaked no timers (the parent owns the timer's group)"
else
    bad "P2 a fast return LEAKED its timer (an orphaned 'sleep 787' outlived 5s)"
    pkill -f 'sleep 787' 2>/dev/null || true
fi

# The sentinel's whole purpose: 124 means "the bound fired", 137 means "it killed itself". A caller
# that cannot tell them apart reports the wrong reason for a failed pass.
_timeout 5 sh -c 'kill -9 $$' >/dev/null 2>&1
assert_rc "$?" 137 "P2 a command that SIGKILLs itself is 137, NOT reported as a timeout"

# A full disk is exactly when an unwritable scratch dir happens; the bound must still answer 124 then.
( TMPDIR=/nonexistent-dir _timeout 1 sleep 643 >/dev/null 2>&1 ); rc=$?
assert_rc "$rc" 124 "P2 an unwritable scratch dir still reports 124 (the contract is not lost with the sentinel)"

# The resolved mechanism must match what this host really has — otherwise "it works here" would be
# an accident of an installed coreutils, not a property of the shim.
case "${TB_TIMEOUT_KIND:-}" in
    timeout|gtimeout|internal) ok "P2 the resolved watchdog is named (TB_TIMEOUT_KIND=$TB_TIMEOUT_KIND)" ;;
    *) bad "P2 TB_TIMEOUT_KIND is unset/invalid ('${TB_TIMEOUT_KIND:-}') — the mechanism is not reportable" ;;
esac
if command -v timeout >/dev/null 2>&1; then
    assert_eq "${TB_TIMEOUT_KIND:-}" "timeout" "P2 resolution matches the host (GNU timeout is present)"
elif command -v gtimeout >/dev/null 2>&1; then
    assert_eq "${TB_TIMEOUT_KIND:-}" "gtimeout" "P2 resolution matches the host (gtimeout is present)"
else
    assert_eq "${TB_TIMEOUT_KIND:-}" "internal" "P2 resolution matches the host (neither binary — the internal watchdog)"
fi

# ── P3 _nproc ─────────────────────────────────────────────────────────────────────────────────
echo "── P3 _nproc ──"
N="$(_nproc)"; rc=$?
assert_rc "$rc" 0 "P3 _nproc answers on this platform"
assert_num "$N" "P3 _nproc returns an integer"
[ "${N:-0}" -gt 0 ] 2>/dev/null && ok "P3 …greater than zero ($N)" || bad "P3 _nproc returned '${N:-}' (must be > 0)"
WANT_N="$(host_nproc)"
assert_eq "$N" "$WANT_N" "P3 …equal to this platform's independent CPU count (${HOST_PLATFORM})"
# With no probe reachable, an EMPTY answer is the only honest one. A fabricated 1 would make a
# scheduler believe it is on a single-CPU box and halve every parallelism decision downstream.
OUT="$(PATH=/nonexistent PATH=/nonexistent _nproc 2>/dev/null)"; rc=$?
assert_empty "$OUT" "P3 with no probe on PATH _nproc returns EMPTY (never a fabricated 1)"
[ "$rc" -ne 0 ] && ok "P3 …and a non-zero status ($rc)" || bad "P3 …but it reported success"

# ── P4 _stat_size ─────────────────────────────────────────────────────────────────────────────
echo "── P4 _stat_size ──"
F="$T/plain.txt"; printf 'hello\n' >"$F"
assert_eq "$(_stat_size "$F")" "$(host_size "$F")" "P4 a small file: exact bytes, agreeing with wc -c"
BIG="$T/big.bin"; dd if=/dev/zero of="$BIG" bs=1024 count=1500 >/dev/null 2>&1
assert_eq "$(_stat_size "$BIG")" "1536000" "P4 a 1.5 MB file: exact bytes"
EMPTY="$T/empty.txt"; : >"$EMPTY"
assert_eq "$(_stat_size "$EMPTY")" "0" "P4 an EMPTY file reports 0 — a real answer, not a failure"
_stat_size "$EMPTY" >/dev/null; assert_rc $? 0 "P4 …and the status is 0, so 0 cannot be mistaken for 'unmeasurable'"
# A name that trips quoting, word-splitting and BSD stat at once.
WEIRD="$T/a name with	tab
newline.txt"
printf '1234567890' >"$WEIRD"
assert_eq "$(_stat_size "$WEIRD")" "10" "P4 a name with spaces, a tab and a NEWLINE: 10 bytes"
assert_eq "$(_stat_size "$WEIRD")" "$(host_size "$WEIRD")" "P4 …agreeing with the host's own count"
DASH="-dash-named.txt"
( cd "$T" && printf 'abc' >"./$DASH" )
assert_eq "$(cd "$T" && _stat_size "$DASH")" "3" "P4 a leading-dash name is measured, not read as a flag"
OUT="$(_stat_size "$T/does-not-exist")"; rc=$?
assert_empty "$OUT" "P4 an absent file returns EMPTY (never 0)"
[ "$rc" -ne 0 ] && ok "P4 …with a non-zero status" || bad "P4 …but it reported success"
OUT="$(_stat_size "")"; rc=$?
assert_empty "$OUT" "P4 an empty path argument is a failure, not a measurement of cwd"
[ "$rc" -ne 0 ] && ok "P4 …with a non-zero status" || bad "P4 …but it reported success"

# _stat_dev: the mount-boundary check (`st_dev` cannot see a same-device bind mount) reads this.
DEV="$(_stat_dev "$F")"
assert_eq "$DEV" "$(stat -f %d "$F" 2>/dev/null || stat -c %d "$F" 2>/dev/null)" \
    "P4 _stat_dev agrees with the platform's own stat"
[ -n "$DEV" ] && ok "P4 _stat_dev returns a device id" || bad "P4 _stat_dev returned nothing"
OUT="$(_stat_dev "$T/does-not-exist")"; rc=$?
assert_empty "$OUT" "P4 _stat_dev of an absent path is EMPTY"
[ "$rc" -ne 0 ] && ok "P4 …with a non-zero status" || bad "P4 …but it reported success"

# ── P5 _stat_mtime ───────────────────────────────────────────────────────────────────────────
echo "── P5 _stat_mtime ──"
touch -t 202001010000 "$F" 2>/dev/null || true
M1="$(_stat_mtime "$F")"
assert_eq "$M1" "$(host_mtime "$F")" "P5 epoch mtime, agreeing with the host's own stat"
assert_num "$M1" "P5 …and it is an integer"
touch -t 202101010000 "$F" 2>/dev/null || true
M2="$(_stat_mtime "$F")"
[ "${M2:-0}" -gt "${M1:-0}" ] 2>/dev/null && ok "P5 a NEWER mtime reads larger ($M1 -> $M2), so it is a measurement" || bad "P5 mtime did not move with the file ($M1 -> ${M2:-})"
OUT="$(_stat_mtime "$T/nope")"; rc=$?
assert_empty "$OUT" "P5 an absent file returns EMPTY"
[ "$rc" -ne 0 ] && ok "P5 …with a non-zero status" || bad "P5 …but it reported success"

# ── P6 _date ─────────────────────────────────────────────────────────────────────────────────
echo "── P6 _date ──"
NOW="$(date +%s)"
assert_num "$(_date --epoch)" "P6 --epoch is an integer"
assert_within "$(_date --epoch)" "$NOW" 3 "P6 --epoch is now"
ISO="$(_date --iso)"
case "$ISO" in
    ????-??-??T??:??:??Z) ok "P6 --iso is UTC ISO-8601 ($ISO)" ;;
    *) bad "P6 --iso is not the record format (got '$ISO')" ;;
esac
assert_within "$(_date --parse "$ISO")" "$NOW" 5 "P6 --iso round-trips through --parse"
assert_eq "$(_date --parse '@1792345000')" "1792345000" "P6 @epoch is handed straight back"
assert_eq "$(_date --parse '1970-01-01T00:00:00Z')" "0" "P6 the epoch anchor parses to 0 — and 0 is a VALUE"
assert_eq "$(_date --parse '1970-01-01')" "0" "P6 a date-only anchor parses to 0"
assert_eq "$(( $(_date --parse '2026-10-19') - $(_date --parse '2026-10-18') ))" "86400" \
    "P6 consecutive days differ by exactly 86400s (no DST/zone drift in the parse)"
assert_eq "$(_date --parse '2026-10-18T00:00:00Z')" "$(_date --parse '2026-10-18')" \
    "P6 a date-only value is midnight UTC of that day"
assert_within "$(_date --parse '10 minutes ago')" "$(( NOW - 600 ))" 5 "P6 '10 minutes ago'"
assert_within "$(_date --parse '-10 minutes')"   "$(( NOW - 600 ))" 5 "P6 '-10 minutes' (the other shape)"
assert_within "$(_date --parse '10 minutes')"    "$(( NOW + 600 ))" 5 "P6 '10 minutes' (no 'ago') is AHEAD, exactly as date -d reads it"
assert_within "$(_date --parse '2 hours ago')"   "$(( NOW - 7200 ))" 5 "P6 '2 hours ago'"
assert_within "$(_date --parse '3 days')"        "$(( NOW + 259200 ))" 5 "P6 '3 days' is ahead, as date -d reads it"
assert_within "$(_date --parse '3 days ago')"    "$(( NOW - 259200 ))" 5 "P6 '3 days ago' is behind"
assert_within "$(_date --add 60)"                "$(( NOW + 60 ))" 5 "P6 --add 60 is a minute ahead"
assert_eq "$(_date --add 0)" "$(_date --epoch)" "P6 --add 0 is now"
OUT="$(_date --parse 'not a date')"; rc=$?
assert_empty "$OUT" "P6 garbage returns EMPTY (never 0, which is a real timestamp)"
[ "$rc" -ne 0 ] && ok "P6 …with a non-zero status" || bad "P6 …but it reported success"
assert_eq "$(LANG=C _date -u +%Y)" "$(date -u +%Y)" "P6 any other argument list is passed to date(1) unchanged"

# ⛔ THE ONE FAIL-OPEN SHAPE: `$(( $(date +%s) + delta ))` with a broken `date` is `0 + delta`, so
# `_date --add 60` answered `60` with rc=0 — a plausible epoch indistinguishable from a real answer.
OUT="$(PATH=/nonexistent _date --add 60)"; rc=$?
assert_empty "$OUT" "P6 --add with an unusable date(1) returns EMPTY (never the delta, which looks like an epoch)"
[ "$rc" -ne 0 ] && ok "P6 …with a non-zero status" || bad "P6 …but it reported success (the failure value was \$delta)"
OUT="$(PATH=/nonexistent _date --parse '10 minutes ago')"; rc=$?
assert_empty "$OUT" "P6 relative --parse with an unusable date(1) is EMPTY too, never '-600'"
[ "$rc" -ne 0 ] && ok "P6 …with a non-zero status" || bad "P6 …but it reported success"

# An OFFSET timestamp is a real form (the records carry Z, but a stamp from another host may not).
# The BSD branch used to rebuild `+02+02:00` — a string date(1) can never parse — so this was dead code.
assert_eq "$(_date --parse '2026-10-18T12:00:00+02:00')" "1792317600" \
    "P6 an +HH:MM offset parses to the right instant (the BSD normalisation is real, not just present)"
assert_eq "$(_date --parse '2026-10-18T12:00:00-05:00')" "1792342800" "P6 …and a negative offset"
# The compact forms a migrated `date -d '-7d'` site would use must not be silently refused.
assert_within "$(_date --parse '-7d')" "$(( NOW - 604800 ))" 5 "P6 '-7d' (compact) is accepted, not refused on both platforms"
assert_within "$(_date --parse '7d')"  "$(( NOW + 604800 ))" 5 "P6 '7d' (compact, ahead)"
OUT="$(_date --parse '10m x')"; rc=$?
assert_empty "$OUT" "P6 a malformed compact form is refused (rc=$rc), not guessed"
# --fmt is the shape `cleanup-stale-branches.sh` formats branch dates with.
assert_eq "$(_date --fmt 0 '%Y-%m-%d')" "1970-01-01" "P6 --fmt 0 is the epoch in UTC"
assert_eq "$(_date --fmt 1792345000 '%Y-%m-%d')" "2026-10-18" "P6 --fmt renders the format it is given"
OUT="$(_date --fmt notanepoch '%Y')"; rc=$?
assert_empty "$OUT" "P6 --fmt of a non-epoch is EMPTY"
[ "$rc" -ne 0 ] && ok "P6 …with a non-zero status" || bad "P6 …but it reported success"

# ── P7 a missing engine is a refusal ─────────────────────────────────────────────────────────
echo "── P7 refusal when the engine is missing ──"
OUT="$(PORTABLE_BOUNDED_LIB=/nonexistent/bounded.sh bash -c '. "$0"' "$SHIM" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "P7 sourcing with a SET-but-missing engine fails (rc=$rc)" || bad "P7 a missing engine loaded silently"
assert_contains "$OUT" "FAIL-CLOSED" "P7 the refusal says it is fail-closed"
assert_contains "$OUT" "bounded-execution engine is missing" "P7 …and names what is missing"
# Same rule as BOUNDED_LIB in disk-reaper.sh: a pin that is wrong is NAMED, never replaced by a
# different file that happens to be on the search path.
OUT="$(PORTABLE_BOUNDED_LIB=/nonexistent/bounded.sh bash -c '. "$0" 2>/dev/null; echo LOADED' "$SHIM" 2>/dev/null)"
assert_empty "$OUT" "P7 …and nothing loads afterwards (no half-shim)"

# ── P8 the platform's SYSTEM bash ────────────────────────────────────────────────────────────
echo "── P8 the shim under the system bash ──"
SYS_BASH="/bin/bash"
if [ -x "$SYS_BASH" ]; then
    SYSV="$("$SYS_BASH" -c 'echo "$BASH_VERSION"')"
    OUT="$("$SYS_BASH" -c '. "$0" && _nproc && _stat_size "$1"' "$SHIM" "$F" 2>&1)"; rc=$?
    assert_rc "$rc" 0 "P8 loads and runs under $SYS_BASH ($SYSV) — no bash-4-ism from a Linux-only habit"
    # ⛔ ASK FOR THE VALUE, NOT FOR A DIGIT SOMEWHERE IN THE OUTPUT: `assert_contains "$OUT" 0` was
    # satisfied by `_nproc`'s own `10`, so a `_date` that printed NOTHING still passed this line.
    D8="$("$SYS_BASH" -c '. "$0" && _date --parse "@0"' "$SHIM" 2>&1)"
    assert_eq "$D8" "0" "P8 …and _date still anchors the epoch (asserted on its own value)"
else
    bad "P8 no system bash at $SYS_BASH — a macOS-or-Linux portability proof needs it"
fi

echo
echo "──────────────────────────────────────────────────────────────────────"
echo "platform=$HOST_PLATFORM watchdog=${TB_TIMEOUT_KIND:-?} assertions=$PASS failures=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
