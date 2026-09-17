#!/usr/bin/env bash
# pi-reap-orphans.test.sh — self-check for scripts/pi-reap-orphans.sh (#1142).
#
# Run: bash scripts/pi-reap-orphans.test.sh [--repro]
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic by default: `ps` / `lsof` / `kill` are shimmed through the script's
# env seams, so NO real process is enumerated, NO real process is signalled, and
# no real ~/.pi state is touched. The ps shim walks a SEQUENCE of fixture tables
# (one per call), which is what makes the two-snapshot cpu-time delta — and the
# post-signal re-probe — deterministic instead of racy.
#
# `--repro` additionally runs the REAL reproduction from the issue on the real
# host: spawn a child, delete its cwd, let it reparent to launchd, and prove the
# detector identifies it while leaving a live-cwd process alone. It is opt-in
# (not part of the hermetic suite) because it needs a real ppid=1 reparent, and
# it always trap-kills what it spawned.
#
# Coverage — each gate driven to its fail path:
#   reapable                 O1   (ppid=1 + deleted cwd + cpu advancing)
#   dry-run is default       O2   (no flag => kill shim NEVER invoked)
#   apply / SIGTERM          O3   (TERM sent, REAPED, exit 0)
#   ignores SIGTERM          O4   (TERM then KILL, REAPED=2nd signal)
#   survives KILL            O5   (KILL-FAILED + FAILED=1 + exit 4)
#   cwd-live                 O6   (a live cwd is left ALONE)
#   cpu-idle                 O7
#   centisecond resolution   O8   (0.20s -> 0.40s over the window is a REAP;
#                                  integer-second truncation read it as 0 -> 0
#                                  and hid a sustained 10%-of-a-core leak)
#   cpu goes backwards       O8b  (cpu-unmeasurable)
#   cpu unmeasurable         O8c  (absent from snapshot A)
#   too-young                O9
#   wrong-uid                O10
#   not-orphan               O11  (ppid != 1 => never even classified)
#   cwd-unknown              O12  (lsof has no entry => PRESERVE, not a reap)
#   cwd-unreadable           O13  (an ancestor that is not a directory)
#   cwd-out-of-scope         O14  (deleted cwd outside the roots; --any-cwd)
#   ps failed/empty          O15  (exit 3, NOTHING signalled)
#   lsof failed/empty        O16  (exit 3, NOTHING signalled — the fail-closed
#                                  probe the #1095 review found twice)
#   lsof missing             O16b
#   --list                   O17  (read-only: no lock, no log, no signal)
#   lock held                O18  (exit 3)
#   log unwritable (armed)   O19  (exit 3)
#   flags / env validation   O20  (--help, unknown arg, bad numbers)
#   verbose vs summary       O21  (non-verbose still reports exact counts)
#   real reproduction        R1   (--repro only)

set -uo pipefail

bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-reap-orphans.sh"
# Invoke the reaper through a function so no `bash <path>` appears INSIDE a
# `$( )` span: the main-worktree-guard script-content walker (#1484) cannot
# verify that form and fails closed, which would make this suite unrunnable
# from any session rooted in the shared main checkout (cf. #1095's note).
reap_invoke() { bash "$REAPER" "$@"; }
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }
assert_rc()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (rc=$1, want $2)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-orphans-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
SPAWNED=""
cleanup() {
    for p in $SPAWNED; do kill -9 "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT

REAPER_UNDER_TEST="$REAPER"
# The real reproduction spawns real processes; keep their pids for the trap.
add_spawned() { SPAWNED="$SPAWNED $1"; }

# ── shims ──────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat >"$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
# Emits the Nth fixture table from FAKE_PS_SEQ (colon-separated paths); past the
# end the LAST table repeats. A counter file makes the walk deterministic across
# the reaper's A / B / post-signal probes.
idx=0
if [ -n "${FAKE_PS_COUNTER:-}" ]; then
    idx="$(cat "$FAKE_PS_COUNTER" 2>/dev/null || printf 0)"
    printf '%s' "$((idx + 1))" >"$FAKE_PS_COUNTER"
fi
IFS=':' read -r -a files <<<"${FAKE_PS_SEQ:-}"
if [ "${#files[@]}" -eq 0 ]; then exit 0; fi
last=$((${#files[@]} - 1))
[ "$idx" -gt "$last" ] && idx="$last"
cat "${files[$idx]}" 2>/dev/null
exit 0
SHIM
cat >"$T/bin/ps-fail" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
cat >"$T/bin/lsof" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_LSOF_ARGS_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_LSOF_ARGS_LOG"
cat "${FAKE_LSOF_TABLE:-/dev/null}" 2>/dev/null
exit 0
SHIM
cat >"$T/bin/lsof-fail" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
cat >"$T/bin/kill" <<'SHIM'
#!/usr/bin/env bash
# Records the signal instead of delivering it. NEVER kills a real process.
[ -n "${FAKE_KILL_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_KILL_LOG"
exit 0
SHIM
cat >"$T/bin/kill-fail" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_KILL_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_KILL_LOG"
exit 1
SHIM
cat >"$T/bin/uname" <<'SHIM'
#!/usr/bin/env bash
# Keeps the scratch reaper's stat-flavor detection out of this suite's way.
printf 'Darwin\n'
SHIM
chmod +x "$T"/bin/*

MY_UID="$(id -u)"

# ── fixtures ───────────────────────────────────────────────────────────
# A root in which the orphan's cwd can be created and then deleted, so the
# `deleted` cwd state is REAL (not a shimmed notion).
CWD_ROOT="$T/scratch"
mkdir -p "$CWD_ROOT"

# fake_ps <name> <rows...>  — write a ps-shaped fixture table.
fake_ps() {
    local name="$1"; shift
    printf '%s\n' "$@" >"$T/$name.ps"
    printf '%s' "$T/$name.ps"
}
# ps_row_line <pid> <ppid> <uid> <cpu> <elapsed> <cmd>
ps_row_line() { printf '%s %s %s %s %s %s' "$1" "$2" "$3" "$4" "$5" "$6"; }

# lsof_fixture <name> <pid:path>...
lsof_fixture() {
    local name="$1"; shift
    : >"$T/$name.lsof"
    local spec pid path
    for spec in "$@"; do
        pid="${spec%%:*}"; path="${spec#*:}"
        printf 'p%s\nfcwd\nn%s\n' "$pid" "$path" >>"$T/$name.lsof"
    done
    printf '%s' "$T/$name.lsof"
}

# run_reaper <label> <ps-seq> <lsof-table> [extra args...]
# Prints "RC=<n>" then the reaper's output. Reads $RUN_ARGS for flags.
RUN_LOG=""
RUN_KILL=""
run_reaper() {
    local label="$1" ps_seq="$2" lsof_table="$3"; shift 3
    # These MUST be set OUTSIDE the command substitution below: assignments made
    # inside `out="$( ... )"` happen in the subshell and are invisible to the
    # caller, so the kill-log assertions silently read a stale file.
    RUN_LOG="$T/$label.state/log"
    RUN_KILL="$T/$label.kills"
    rm -f "$RUN_KILL"
    : >"$T/$label.counter"
    local rc=0
    out="$(
        FAKE_PS_SEQ="$ps_seq" FAKE_PS_COUNTER="$T/$label.counter" \
        FAKE_LSOF_TABLE="$lsof_table" FAKE_KILL_LOG="$RUN_KILL" \
        PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" KILL_BIN="$T/bin/kill" \
        REAP_ORPHAN_STATE_DIR="$T/$label.state" REAP_ORPHAN_LOG="$RUN_LOG" \
        reap_invoke "$@" 2>&1
    )" || rc=$?
    printf 'RC=%s\n%s\n' "$rc" "$out"
}
kills() { [ -f "$T/$1.kills" ] && cat "$T/$1.kills" || printf ''; }

echo "=== pi-reap-orphans.test.sh (#1142) ==="

# ── O1: the reapable case, dry-run default ─────────────────────────────
echo "— O1/O2: reapable + dry-run is the default —"
DEADCWD1="$CWD_ROOT/gone1"; mkdir -p "$DEADCWD1"
ORPH=4001
A="$(fake_ps psA "$(ps_row_line 1 0 0 '0:10.00' '01:00:00' /sbin/launchd)" \
                     "$(ps_row_line $ORPH 1 "$MY_UID" '0:00.50' '00:05:00' /bin/sh-spin)" \
                     "$(ps_row_line 9999 1 "$MY_UID" '0:03.00' '02:00:00' /usr/bin/idle-daemon)")"
B="$(fake_ps psB "$(ps_row_line 1 0 0 '0:10.00' '01:00:01' /sbin/launchd)" \
                     "$(ps_row_line $ORPH 1 "$MY_UID" '0:00.90' '00:05:20' /bin/sh-spin)" \
                     "$(ps_row_line 9999 1 "$MY_UID" '0:03.00' '02:00:20' /usr/bin/idle-daemon)")"
L="$(lsof_fixture ls1 "$ORPH:$DEADCWD1" "9999:/usr/bin")"
rmdir "$DEADCWD1"
OUT="$(run_reaper o1 "$A:$B" "$L" --min-elapsed-seconds 1 --sample-seconds 0 --verbose)"
assert_rc "$(sed -n 's/^RC=//p' <<<"$OUT")" 0 "O1 dry-run exits 0"
assert_contains "$OUT" "reason=reapable" "O1 the deleted-cwd orphan is classified reapable"
assert_contains "$OUT" "pid=$ORPH" "O1 ... naming the orphan pid"
assert_contains "$OUT" "reason=cpu-idle" "O1 the idle but otherwise-eligible pid is preserved"
assert_contains "$OUT" "reapable=1" "O1 exactly one reapable"
assert_nofile "$T/o1.kills" "O2 dry-run is the DEFAULT: the kill shim was NEVER invoked"
assert_contains "$OUT" "dry-run: NOTHING was signalled" "O2 the dry-run line says so in words"

# ── O3: apply sends SIGTERM; the process honours it ────────────────────
echo "— O3: --apply SIGTERMs, and a process that exits on TERM is not KILLed —"
DEADCWD3="$CWD_ROOT/gone3"; mkdir -p "$DEADCWD3"
GONE="$(fake_ps psGone "$(ps_row_line 1 0 0 '0:10.00' '01:00:00' /sbin/launchd)")"
L3="$(lsof_fixture ls3 "$ORPH:$DEADCWD3")"
rmdir "$DEADCWD3"
OUT="$(run_reaper o3 "$A:$B:$GONE" "$L3" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_rc "$(sed -n 's/^RC=//p' <<<"$OUT")" 0 "O3 apply exits 0"
assert_contains "$(kills o3)" "-TERM $ORPH" "O3 SIGTERM was delivered to the orphan"
assert_absent "$(kills o3)" "-KILL" "O3 a process that exited on TERM is NEVER KILLed"
assert_contains "$OUT" "REAPED — exited on SIGTERM" "O3 the reap is reported"
assert_contains "$(cat "$T/o3.state/log")" "REAPED=1" "O3 the log records REAPED=1"
assert_contains "$OUT" "reaped=1" "O3 the summary reports reaped=1"

# ── O4/O5: ignores TERM -> KILL; survives KILL -> exit 4 ───────────────
echo "— O4/O5: TERM ignored escalates to KILL; surviving KILL is a FAILURE —"
DEADCWD4="$CWD_ROOT/gone4"; mkdir -p "$DEADCWD4"
STILL="$(fake_ps psStill "$(ps_row_line 1 0 0 '0:10.00' '01:00:00' /sbin/launchd)" \
                           "$(ps_row_line $ORPH 1 "$MY_UID" '0:01.00' '00:05:00' /bin/sh-spin)")"
L4="$(lsof_fixture ls4 "$ORPH:$DEADCWD4")"
rmdir "$DEADCWD4"
OUT="$(run_reaper o4 "$A:$B:$STILL:$GONE" "$L4" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$(kills o4)" "-TERM $ORPH" "O4 TERM is tried first"
assert_contains "$(kills o4)" "-KILL $ORPH" "O4 a process still present after the grace is KILLed"
assert_contains "$OUT" "REAPED — required SIGKILL" "O4 the SIGKILL reap is reported"
assert_rc "$(sed -n 's/^RC=//p' <<<"$OUT")" 0 "O4 escalating to KILL is still a clean pass"

DEADCWD5="$CWD_ROOT/gone5"; mkdir -p "$DEADCWD5"
L5="$(lsof_fixture ls5 "$ORPH:$DEADCWD5")"
rmdir "$DEADCWD5"
OUT="$(run_reaper o5 "$A:$B:$STILL:$STILL:$STILL:$STILL" "$L5" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_rc "$(sed -n 's/^RC=//p' <<<"$OUT")" 4 "O5 a process that survives KILL exits 4"
assert_contains "$OUT" "KILL-FAILED" "O5 an unproven death is reported as KILL-FAILED, never as a reap"
assert_contains "$OUT" "failed=1" "O5 the summary counts the failure"

# ── O6: live cwd is left ALONE (the acceptance's "legitimate process") ──
echo "— O6: a legitimate ppid=1 process with a LIVE cwd is left alone —"
LIVE6="$CWD_ROOT/live6"; mkdir -p "$LIVE6"
L6="$(lsof_fixture ls6 "$ORPH:$LIVE6")"
OUT="$(run_reaper o6 "$A:$B" "$L6" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cwd-live" "O6 a live cwd is preserved"
assert_contains "$OUT" "reapable=0" "O6 nothing is reapable"
assert_nofile "$T/o6.kills" "O6 no signal was sent"

# ── O7: cpu-idle ───────────────────────────────────────────────────────
echo "— O7/O8: cpu gates — idle, centisecond advance, backwards, unmeasurable —"
DEADCWD7="$CWD_ROOT/gone7"; mkdir -p "$DEADCWD7"
IDLE_A="$(fake_ps psIa "$(ps_row_line $ORPH 1 "$MY_UID" '0:05.00' '00:05:00' /bin/sh-spin)")"
IDLE_B="$(fake_ps psIb "$(ps_row_line $ORPH 1 "$MY_UID" '0:05.00' '00:05:20' /bin/sh-spin)")"
L7="$(lsof_fixture ls7 "$ORPH:$DEADCWD7")"
rmdir "$DEADCWD7"
OUT="$(run_reaper o7 "$IDLE_A:$IDLE_B" "$L7" --apply --verbose --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cpu-idle" "O7 a zero CPU delta is preserved"
assert_nofile "$T/o7.kills" "O7 no signal was sent"

# O8: 0.20s -> 0.40s over the window = a 20cs advance. Integer-second truncation
# read BOTH as 0 and classified a sustained 10%-of-a-core leak as cpu-idle.
CS_A="$(fake_ps psCa "$(ps_row_line $ORPH 1 "$MY_UID" '0:00.20' '00:05:00' /bin/sh-spin)")"
CS_B="$(fake_ps psCb "$(ps_row_line $ORPH 1 "$MY_UID" '0:00.40' '00:05:20' /bin/sh-spin)")"
OUT="$(run_reaper o8 "$CS_A:$CS_B" "$L7" --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=reapable cpu +20cs" "O8 a 20-centisecond advance is a REAP (regression: seconds-truncation hid it)"
assert_contains "$OUT" "reapable=1" "O8 ... and it is the only reclaimable row"

BACK_A="$(fake_ps psBa "$(ps_row_line $ORPH 1 "$MY_UID" '0:09.00' '00:05:00' /bin/sh-spin)")"
BACK_B="$(fake_ps psBb "$(ps_row_line $ORPH 1 "$MY_UID" '0:02.00' '00:05:20' /bin/sh-spin)")"
OUT="$(run_reaper o8b "$BACK_A:$BACK_B" "$L7" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cpu-unmeasurable" "O8b a cpu-time that goes BACKWARDS is unevaluable, not a reap"
assert_nofile "$T/o8b.kills" "O8b ... and nothing is signalled"

ABSENT_B="$(fake_ps psAb "$(ps_row_line $ORPH 1 "$MY_UID" '0:02.00' '00:05:20' /bin/sh-spin)")"
OUT="$(run_reaper o8c "$GONE:$ABSENT_B" "$L7" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cpu-unmeasurable" "O8c a pid absent from snapshot A is unevaluable, not a reap"
assert_nofile "$T/o8c.kills" "O8c ... and nothing is signalled"

# ── O9: too-young ──────────────────────────────────────────────────────
echo "— O9/O10/O11: age floor, uid, and the orphan requirement itself —"
DEADCWD9="$CWD_ROOT/gone9"; mkdir -p "$DEADCWD9"
L9="$(lsof_fixture ls9 "$ORPH:$DEADCWD9")"
rmdir "$DEADCWD9"
OUT="$(run_reaper o9 "$A:$B" "$L9" --apply --verbose --min-elapsed-seconds 99999 --sample-seconds 0)"
assert_contains "$OUT" "reason=too-young" "O9 a process younger than the floor is preserved"
assert_nofile "$T/o9.kills" "O9 ... and nothing is signalled"

OTHER_UID=4002
OA="$(fake_ps psOa "$(ps_row_line $OTHER_UID 1 4242 '0:00.10' '01:00:00' /usr/bin/other)")"
OB="$(fake_ps psOb "$(ps_row_line $OTHER_UID 1 4242 '0:09.00' '01:00:20' /usr/bin/other)")"
OL="$(lsof_fixture lsOther "$OTHER_UID:$DEADCWD9")"
if [ "$MY_UID" = "4242" ]; then
    ok "O10 skipped (uid 4242 is ours; cannot build a wrong-uid fixture)"
else
    OUT="$(run_reaper o10 "$OA:$OB" "$OL" --apply --verbose --min-elapsed-seconds 1 --sample-seconds 0)"
    assert_contains "$OUT" "reason=wrong-uid" "O10 another user's process is never signalled"
    assert_nofile "$T/o10.kills" "O10 ... and nothing is signalled"
fi

DEADCWD11="$CWD_ROOT/gone11"; mkdir -p "$DEADCWD11"
NA="$(fake_ps psNa "$(ps_row_line $ORPH 7777 "$MY_UID" '0:00.10' '01:00:00' /bin/sh-spin)")"
NB="$(fake_ps psNb "$(ps_row_line $ORPH 7777 "$MY_UID" '0:09.00' '01:00:20' /bin/sh-spin)")"
NL="$(lsof_fixture lsNo "$ORPH:$DEADCWD11")"
rmdir "$DEADCWD11"
OUT="$(run_reaper o11 "$NA:$NB" "$NL" --apply --min-elapsed-seconds 1 --sample-seconds 0 --verbose)"
assert_absent "$OUT" "pid=$ORPH" "O11 a process with a live parent (ppid != 1) is never even classified"
assert_contains "$OUT" "reapable=0" "O11 ... and nothing is reapable"

# ── O12/O13/O14: the cwd gates ─────────────────────────────────────────
echo "— O12/O13/O14: cwd-unknown, cwd-unreadable, cwd-out-of-scope —"
OUT="$(run_reaper o12 "$A:$B" "$(lsof_fixture lsUnknown 1:/sbin/launchd)" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cwd-unknown" "O12 a pid with NO lsof entry is preserved (absence is not evidence)"
assert_nofile "$T/o12.kills" "O12 ... and nothing is signalled"

# unreadable: an ANCESTOR that exists but is not a directory. `[ -e ]` is true
# and `[ -d ]` false, so absence cannot be proven -> preserve.
NOTADIR="$T/notadir"; : >"$NOTADIR"
L13="$(lsof_fixture lsUnreadable "$ORPH:$NOTADIR/child")"
OUT="$(run_reaper o13 "$A:$B" "$L13" --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cwd-unreadable" "O13 an unprovable absence is preserved, never reaped"
assert_nofile "$T/o13.kills" "O13 ... and nothing is signalled"

OUTER="$T/outside"; mkdir -p "$OUTER"; rmdir "$OUTER"
OUT="$(REAP_ORPHAN_CWD_ROOTS="$CWD_ROOT" run_reaper o14 "$A:$B" "$(lsof_fixture lsScope "$ORPH:$OUTER")" \
        --apply --min-elapsed-seconds 1 --sample-seconds 0)"
assert_contains "$OUT" "reason=cwd-out-of-scope" "O14 a deleted cwd outside the scratch roots is not reaped"
assert_contains "$OUT" "use --any-cwd to widen" "O14 ... and the output names the flag that widens it"
assert_nofile "$T/o14.kills" "O14 ... and nothing is signalled"
OUT="$(REAP_ORPHAN_CWD_ROOTS="$CWD_ROOT" run_reaper o14b "$A:$B" "$(lsof_fixture lsScope2 "$ORPH:$OUTER")" \
        --min-elapsed-seconds 1 --sample-seconds 0 --any-cwd)"
assert_contains "$OUT" "reason=reapable" "O14 --any-cwd widens the scope deliberately"

# ── O15/O16: FAIL-CLOSED on unevaluable probes ─────────────────────────
echo "— O15/O16: an unevaluable probe must NOT reclaim —"
# ps failed: point PS_BIN at the failing shim.
RUN_LOG="$T/o15.state/log"; RUN_KILL="$T/o15.kills"; rm -f "$RUN_KILL"
rc=0
out="$(FAKE_LSOF_TABLE="$L" FAKE_KILL_LOG="$RUN_KILL" PS_BIN="$T/bin/ps-fail" LSOF_BIN="$T/bin/lsof" \
       KILL_BIN="$T/bin/kill" REAP_ORPHAN_STATE_DIR="$T/o15.state" REAP_ORPHAN_LOG="$RUN_LOG" \
       reap_invoke --apply --min-elapsed-seconds 1 --sample-seconds 0 2>&1)" || rc=$?
assert_rc "$rc" 3 "O15 ps failure aborts with exit 3"
assert_contains "$out" "FAIL-CLOSED abort: ps enumeration failed" "O15 ... naming the failing probe"
assert_nofile "$T/o15.kills" "O15 ... and NOTHING is signalled (fail-closed, not fail-open)"

# ps empty (a FAILED probe, not "no orphaned processes").
EMPTY_PS="$T/empty.ps"; : >"$EMPTY_PS"
RUN_KILL="$T/o15b.kills"; rm -f "$RUN_KILL"
rc=0
out="$(FAKE_PS_SEQ="$EMPTY_PS" FAKE_PS_COUNTER="$T/o15b.counter" FAKE_LSOF_TABLE="$L" FAKE_KILL_LOG="$RUN_KILL" \
       PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" KILL_BIN="$T/bin/kill" \
       REAP_ORPHAN_STATE_DIR="$T/o15b.state" REAP_ORPHAN_LOG="$T/o15b.state/log" \
       reap_invoke --apply --min-elapsed-seconds 1 --sample-seconds 0 2>&1)" || rc=$?
assert_rc "$rc" 3 "O15b an EMPTY ps table aborts with exit 3 (not 'no orphans')"
assert_nofile "$T/o15b.kills" "O15b ... and NOTHING is signalled"

for kind in fail empty missing; do
    RUN_KILL="$T/o16$kind.kills"; rm -f "$RUN_KILL"
    lsof_bin="$T/bin/lsof"; [ "$kind" = fail ] && lsof_bin="$T/bin/lsof-fail"
    [ "$kind" = missing ] && lsof_bin="$T/bin/lsof-does-not-exist"
    tbl="$L"; [ "$kind" = empty ] && tbl="$T/empty.lsof"
    [ -f "$tbl" ] || : >"$tbl"
    rc=0
    out="$(FAKE_PS_SEQ="$A:$B" FAKE_PS_COUNTER="$T/o16$kind.counter" FAKE_LSOF_TABLE="$tbl" \
           FAKE_KILL_LOG="$RUN_KILL" PS_BIN="$T/bin/ps" LSOF_BIN="$lsof_bin" KILL_BIN="$T/bin/kill" \
           REAP_ORPHAN_STATE_DIR="$T/o16$kind.state" REAP_ORPHAN_LOG="$T/o16$kind.state/log" \
           reap_invoke --apply --min-elapsed-seconds 1 --sample-seconds 0 2>&1)" || rc=$?
    assert_rc "$rc" 3 "O16 lsof $kind aborts with exit 3"
    assert_contains "$out" "FAIL-CLOSED abort: lsof cwd enumeration" "O16 ... naming the cwd probe"
    assert_nofile "$T/o16$kind.kills" "O16 lsof $kind: NOTHING is signalled"
done

# ── O17: --list is read-only ───────────────────────────────────────────
echo "— O17/O18/O19: --list, lock, and log guards —"
OUT="$(run_reaper o17 "$A:$B" "$L" --list)"
assert_rc "$(sed -n 's/^RC=//p' <<<"$OUT")" 0 "--list exits 0"
assert_contains "$OUT" "ppid=1" "--list prints the orphan population"
assert_nofile "$T/o17.kills" "--list signals nothing"
assert_nofile "$T/o17.state/log" "--list does NOT write the log"
assert_nofile "$T/o17.state/pi-reap-orphans.lock" "--list does NOT take the lock"

mkdir -p "$T/o18.state/pi-reap-orphans.lock"
printf '%s\n' "$$" >"$T/o18.state/pi-reap-orphans.lock/pid"
rc=0
out="$(FAKE_PS_SEQ="$A:$B" FAKE_PS_COUNTER="$T/o18.counter" FAKE_LSOF_TABLE="$L" \
       PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" KILL_BIN="$T/bin/kill" \
       REAP_ORPHAN_STATE_DIR="$T/o18.state" REAP_ORPHAN_LOG="$T/o18.state/log" \
       reap_invoke --apply --min-elapsed-seconds 1 --sample-seconds 0 2>&1)" || rc=$?
assert_rc "$rc" 3 "O18 a held lock aborts with exit 3"
assert_contains "$out" "lock held" "O18 ... naming the lock"
rm -rf "$T/o18.state/pi-reap-orphans.lock"

REAP_ORPHAN_STATE_DIR="$T/o19.state" REAP_ORPHAN_LOG="$T/o19-blocked/log" \
  bash -c 'mkdir -p "$(dirname "$REAP_ORPHAN_LOG")" 2>/dev/null; :' 2>/dev/null
mkdir -p "$T/o19.state"; mkdir -p "$T/o19-blocked/log"   # a DIRECTORY at the log path
rc=0
out="$(FAKE_PS_SEQ="$A:$B" FAKE_PS_COUNTER="$T/o19.counter" FAKE_LSOF_TABLE="$L" \
       PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" KILL_BIN="$T/bin/kill" \
       REAP_ORPHAN_STATE_DIR="$T/o19.state" REAP_ORPHAN_LOG="$T/o19-blocked/log" \
       reap_invoke --apply --min-elapsed-seconds 1 --sample-seconds 0 2>&1)" || rc=$?
assert_rc "$rc" 3 "O19 an unwritable log on an ARMED pass aborts with exit 3"
assert_contains "$out" "REAP_ORPHAN_LOG unwritable" "O19 ... naming the log"

# ── O20: flags and env validation ──────────────────────────────────────
echo "— O20/O21: flags, env validation, and honest reporting —"
reap_invoke --help >/dev/null 2>&1; assert_rc "$?" 0 "--help exits 0"
reap_invoke --nope >/dev/null 2>&1; assert_rc "$?" 2 "an unknown flag exits 2"
reap_invoke --min-cpu-centiseconds 3 --help >/dev/null 2>&1; assert_rc "$?" 0 "--min-cpu-centiseconds is accepted"
reap_invoke --min-cpu-centiseconds >/dev/null 2>&1; assert_rc "$?" 2 "a missing flag value exits 2"
REAP_ORPHAN_PS_TIMEOUT=abc reap_invoke --dry-run >/dev/null 2>&1
assert_rc "$?" 2 "a non-numeric timeout is refused BEFORE it can disable a watchdog"
REAP_ORPHAN_LSOF_TIMEOUT=abc reap_invoke --dry-run >/dev/null 2>&1
assert_rc "$?" 2 "a non-numeric lsof timeout is refused"

# A non-verbose pass must still report EXACT counts for the rows it does not
# print (a skipped pass must not look like a successful one).
BIG_A="$(fake_ps psBig "$(ps_row_line 1 0 0 '0:01.00' '01:00:00' /sbin/launchd)" \
                        "$(ps_row_line 5001 1 "$MY_UID" '0:00.00' '01:00:00' /usr/bin/quiet1)" \
                        "$(ps_row_line 5002 1 "$MY_UID" '0:00.00' '01:00:00' /usr/bin/quiet2)")"
BIG_B="$(fake_ps psBigB "$(ps_row_line 1 0 0 '0:01.00' '01:00:20' /sbin/launchd)" \
                        "$(ps_row_line 5001 1 "$MY_UID" '0:00.00' '01:00:20' /usr/bin/quiet1)" \
                        "$(ps_row_line 5002 1 "$MY_UID" '0:00.00' '01:00:20' /usr/bin/quiet2)")"
OUT="$(run_reaper o21 "$BIG_A:$BIG_B" "$(lsof_fixture lsNope 1:/)" --min-elapsed-seconds 1 --sample-seconds 0)"
assert_absent "$OUT" "pid=5001" "O21 non-verbose does not print every preserved row"
assert_contains "$OUT" "cpu-idle" "O21 ... but the reason histogram still reports the exact count"
assert_contains "$OUT" "     2  cpu-idle" "O21 ... with the exact number"

echo ""
echo "── hermetic suite: $PASS passed, $FAIL failed ──"

# ── R1: the real reproduction (opt-in) ─────────────────────────────────
if [ "${1:-}" = "--repro" ]; then
    echo ""
    echo "=== R1: REAL reproduction — spawn, delete cwd, reparent to launchd ==="
    RSA="$T/repro"; mkdir -p "$RSA/deadcwd" "$RSA/livecwd"
    # Double-fork: the inner subshell's parent (the outer subshell) exits
    # immediately, so the grandchild is reparented to pid 1.
    ( ( cd "$RSA/deadcwd" && exec /bin/sh -c 'SUITE_ORPHAN_QQA=1; while :; do :; done' ) >/dev/null 2>&1 & )
    ( ( cd "$RSA/livecwd" && exec /bin/sh -c 'SUITE_LEGIT_QQB=1; while :; do :; done' ) >/dev/null 2>&1 & )
    sleep 2
    P_ORPH="$(ps -axo pid=,command= | awk '/SUITE_ORPHAN_QQA/ && !/awk|grep/ {print $1; exit}')"
    P_LEGIT="$(ps -axo pid=,command= | awk '/SUITE_LEGIT_QQB/ && !/awk|grep/ {print $1; exit}')"
    add_spawned "$P_ORPH"; add_spawned "$P_LEGIT"
    CANON="$(cd "$RSA" && pwd -P)"
    rmdir "$RSA/deadcwd"
    echo "  orphan pid=$P_ORPH (ppid=$(ps -p "$P_ORPH" -o ppid= 2>/dev/null | tr -d ' '))  legit pid=$P_LEGIT"
    # Scope the cwd roots to THIS reproduction's scratch dir: nothing else on
    # the host can match, so the demo cannot signal an unrelated process.
    ROUT="$(REAP_ORPHAN_CWD_ROOTS="$CANON" REAP_ORPHAN_STATE_DIR="$T/repro.state" \
            REAP_ORPHAN_LOG="$T/repro.state/log" \
            reap_invoke --min-elapsed-seconds 1 --sample-seconds 2 --verbose 2>&1)"
    echo "$ROUT" | grep -E "^reap|reapable=|cwd-live" | sed 's/^/  /'
    assert_contains "$ROUT" "pid=$P_ORPH" "R1 the deleted-cwd orphan IS identified"
    assert_contains "$ROUT" "reason=reapable" "R1 ... as reapable"
    assert_contains "$ROUT" "reason=cwd-live" "R1 the live-cwd process is preserved"
    if kill -0 "$P_LEGIT" 2>/dev/null; then ok "R1 the legitimate process is STILL ALIVE after the dry-run"; else bad "R1 the legitimate process died"; fi
    if kill -0 "$P_ORPH" 2>/dev/null; then ok "R1 the orphan is still alive (dry-run signalled nothing)"; else bad "R1 the orphan died in a dry-run"; fi
    echo ""
    echo "── with --repro: $PASS passed, $FAIL failed ──"
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
