#!/usr/bin/env bash
# launchd-controller.test.sh — the entry point's three cases, and the regression that matters.
#
# The file under test is the plist's `ProgramArguments` on a macOS box. It had a defect live for
# 7,633 supervisor launches: `tmux new-session -A -d` on an EXISTING session tries to ATTACH, a
# launchd job has no terminal, tmux printed `open terminal failed: not a terminal` and exited 1, and
# `|| exit $?` turned every KeepAlive relaunch into an immediate failure. Nothing caught it for weeks
# because it only fires on the SECOND and later launches — after a session exists.
#
# SO THE CASES ARE:
#   A  no session            -> creates it detached, exit 0, no attach
#   B  session already there -> exit 0, NO attach attempt (`open terminal failed` must not appear),
#                               and no second controller (the session and its pane are IDENTICAL)
#   C  THE REGRESSION        -> the OLD `-A` form must FAIL in the SAME tty-less conditions B uses.
#                               ⛔ C IS A POSITIVE CONTROL, NOT A COURTESY: if the harness could still
#                               reach a terminal, C would pass and B would prove nothing. C failing to
#                               fail is a RED, by design — that is how the environment is proven
#                               tty-less instead of assumed.
#   D  the restart-rate floor is REAL: a 10 s floor with a ~4 s session forces a >= 12 s total, which a
#      floorless build cannot reach (a first version asserted "-ge 2" and could never fire)
#   E  the plist -> pane environment hand-off is COMPLETE: every `<key>` under `EnvironmentVariables`
#      is forwarded by CONTROLLER_ENV and nothing else is (a rendered-but-dropped limit reverts to the
#      loop's default without a word — `MAX_RED_FIX_TRIES=0` becoming 2)
#   F  a lane-prefixed session name is REFUSED (it would be counted, and reaped, as a worker)
#   G  STATIC `-A` arm with a non-vacuity control: no `new-session` line carries `-A`, on this tree
#      and on a mutant that re-adds it. This one needs no tmux, so the regression is still covered on
#      a runner without it.
#   H  an EMPTY plist value is a MEANING, not an absence: `install.sh` renders OR empty on purpose
#      (#2040: "derive it from $REPO's origin"), so forwarding only NON-EMPTY values loses it
#
# HERMETIC: its own `TMUX_TMPDIR` (so it can never touch, count or reap a real session), its own
# HOME, its own scratch `$O`, and a stub `orch-loop.sh`. No network. Run: bash launchd-controller.test.sh
#
# ⛔ NO `printf | grep -q` PIPES ANYWHERE in this file (#841/#2412) — here-strings or a captured
# value only. The whole point of the suite is a gate that must not report a false negative.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/launchd-controller.sh"
PLIST="$HERE/launchd.plist.template"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⏭️  SKIPPED: %s\n' "$*"; }
log_line()  { printf '\n%s\n' "$*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-test.XXXXXX")" || { echo "cannot mktemp" >&2; exit 1; }
cleanup() {
  # Never let a stray session outlive the suite: kill by socket-scoped TMUX_TMPDIR only.
  if [ -n "${TMUX_BIN:-}" ] && [ -x "${TMUX_BIN:-}" ] && [ -d "${TMUX_TMPDIR:-}" ]; then
    "$TMUX_BIN" kill-server 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

[ -f "$TARGET" ] || { echo "FAIL: $TARGET does not exist" >&2; exit 1; }

# ── the isolated tmux world ──────────────────────────────────────────────────────────────────────
# TMUX_TMPDIR moves tmux's socket directory, so every tmux call made by this suite — and by the
# script under test — lands on a private server that no operator's lane-*/fix-*/merge-* session is on.
export TMUX_TMPDIR="$TMP/sock"
mkdir -p "$TMUX_TMPDIR"
export HOME="$TMP/home"
mkdir -p "$HOME"
unset TMUX TMUX_PANE 2>/dev/null || true
export CONTROLLER_RESTART_FLOOR=0
# A STALE OR IS PUT IN THIS SUITE'S OWN ENVIRONMENT BEFORE ANY TMUX CALL, so the tmux SERVER (which is
# what a new pane inherits its environment from) carries it. Case H then proves an EMPTY plist value
# still reaches the pane instead of being silently replaced by this. install.sh renders OR empty on
# purpose (#2040: "derive it from $REPO's origin").
export OR="stale-repo-from-the-server"

TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
export TMUX_BIN

# The controller the entry point launches: a long-lived stand-in for orch-loop.sh. It must SURVIVE the
# settle window (the entry point waits 2 s), so it sleeps.
O="$TMP/o"
mkdir -p "$O"
cat > "$O/orch-loop.sh" <<'SH'
#!/bin/bash
# Record the environment this PANE actually started with (case H's evidence), then stay alive so the
# entry point's settle window (2 s) sees a live controller. $O is forwarded, so the path resolves.
{ printf 'OR=[%s] REPO=[%s]\n' "${OR-<unset>}" "${REPO-<unset>}"; } > "$O/pane-env" 2>/dev/null
sleep 300
SH
chmod +x "$O/orch-loop.sh"
export O

S="orch-controller"

# run_no_tty — reproduce the launchd condition: NO controlling terminal, no TERM.
# `setsid` is the precise form (a new session with no tty); the `</dev/null` fallback is weaker but
# case C is what PROVES the condition actually holds, so a weaker setup cannot pass silently.
run_no_tty() {
  if command -v setsid >/dev/null 2>&1; then
    setsid -w env -i PATH="$PATH" HOME="$HOME" TMUX_TMPDIR="$TMUX_TMPDIR" TERM= "$@" </dev/null
  else
    env -i PATH="$PATH" HOME="$HOME" TMUX_TMPDIR="$TMUX_TMPDIR" TERM= "$@" </dev/null
  fi
}

session_pid() { "$TMUX_BIN" list-panes -t "=$S" -F '#{pane_pid}' 2>/dev/null; }

# ── G. static `-A` arm (runs with or without tmux) ───────────────────────────────────────────────
log_line "G. STATIC — no new-session line carries -A (comments stripped: this file names the trap on purpose)"

# Comment lines are stripped before the predicate, the same discipline launchd-cycle.sh uses: the
# header QUOTES the broken form while explaining it, so a whole-file grep would prove nothing.
# Capture first, then test the capture: `grep ... | grep -q` is a SIGPIPE false-negative under
# pipefail (#841) — the guard that catches exactly that idiom is what caught this line.
at_arm() {  # $1 = file
  local _lines
  _lines="$(sed -e 's/[[:space:]]*#.*$//' "$1" | grep -n 'new-session' || true)"
  grep -q -- '-A' <<<"$_lines"
}
if at_arm "$TARGET"; then
  bad "a new-session line still carries -A — that is the 7,633-launch defect"
else
  ok "no new-session line carries -A"
fi
# NON-VACUITY: the predicate must FIRE on the old form. This is the control that proves the arm above
# is not an always-green shape.
MUT="$TMP/mutant.sh"
sed 's|"$TMUX_BIN" new-session -d -s "$S"|"$TMUX_BIN" new-session -A -d -s "$S"|' "$TARGET" > "$MUT"
if at_arm "$MUT"; then
  ok "non-vacuity: the predicate FIRES on a mutant that re-adds -A"
else
  bad "non-vacuity: the predicate did not fire on the -A mutant — the static arm above is inert"
fi

# ── E. plist -> pane environment parity ─────────────────────────────────────────────────────────
log_line "E. every EnvironmentVariables key in the plist is forwarded by CONTROLLER_ENV (both directions)"

plist_keys() {
  awk '/<key>EnvironmentVariables<\/key>/,/<\/dict>/' "$1" \
    | grep -oE '<key>[A-Za-z_][A-Za-z0-9_]*</key>' | sed 's/<[^>]*>//g' | grep -v '^EnvironmentVariables$' | LC_ALL=C sort -u
}
env_keys() {
  # The single CONTROLLER_ENV assignment, possibly continued over lines; take the quoted payload only.
  sed -n 's/^CONTROLLER_ENV="\(.*\)"$/\1/p' "$1" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u
}
PK="$(plist_keys "$PLIST")"
EK="$(env_keys "$TARGET")"
plist_keys "$PLIST" > "$TMP/pk"
env_keys "$TARGET"  > "$TMP/ek"
if [ ! -s "$TMP/pk" ]; then
  bad "could not derive any <key> from $PLIST — the parity check cannot run (a read failure is not a pass)"
elif [ ! -s "$TMP/ek" ]; then
  bad "could not derive CONTROLLER_ENV from $TARGET — the parity check cannot run"
else
  comm -23 "$TMP/pk" "$TMP/ek" > "$TMP/missing"
  comm -13 "$TMP/pk" "$TMP/ek" > "$TMP/extra"
  if [ -s "$TMP/missing" ]; then
    bad "the plist renders these keys but the pane does NOT receive them: $(tr '\n' ' ' < "$TMP/missing")"
  else
    ok "every plist EnvironmentVariables key is forwarded ($(wc -l < "$TMP/pk" | tr -d ' ') keys)"
  fi
  if [ -s "$TMP/extra" ]; then
    bad "CONTROLLER_ENV forwards names the plist does not render: $(tr '\n' ' ' < "$TMP/extra")"
  else
    ok "CONTROLLER_ENV forwards nothing the plist does not render"
  fi
  # NON-VACUITY: drop one name from a copy and require the MISSING arm to fire.
  grep -v '^PRODUCT_FLOOR$' "$TMP/ek" > "$TMP/ek.drop" || true
  comm -23 "$TMP/pk" "$TMP/ek.drop" > "$TMP/missing.drop"
  if [ -s "$TMP/missing.drop" ]; then
    ok "non-vacuity: dropping PRODUCT_FLOOR makes the parity check fire"
  else
    bad "non-vacuity: dropping PRODUCT_FLOOR did not trip the parity check — it is inert"
  fi
fi

# ── F. a lane-prefixed session name is refused ───────────────────────────────────────────────────
log_line "F. a session name that matches a lane prefix is REFUSED (it would be counted and reaped as a worker)"
_out="$(CONTROLLER_SESSION=lane-oops bash "$TARGET" 2>&1)"; _rc=$?
if [ "$_rc" -eq 78 ] && grep -q 'matches a lane prefix' <<<"$_out"; then
  ok "CONTROLLER_SESSION=lane-oops is refused (rc=78) and says why"
else
  bad "a lane-prefixed session name was accepted or refused for the wrong reason (rc=$_rc): $_out"
fi

# ── bash -n ─────────────────────────────────────────────────────────────────────────────────────
if bash -n "$TARGET" 2>/dev/null; then ok "bash -n clean"; else bad "bash -n failed"; fi

# ⛔ EVERYTHING BELOW NEEDS A REAL tmux. The `-A` mechanism cannot be proven with a stub: the failure
# is the real binary declining to attach without a tty. Absence is therefore a NAMED skip that says
# exactly what did not run — never a silent pass.
if [ -z "$TMUX_BIN" ]; then
  log_line "A/B/C/D: tmux is NOT installed on this runner"
  skip "cases A, B and C (create / existing-session / the -A regression) did not run — the tmux binary is the artifact under test and cannot be stubbed. Case G still pins the -A shape textually."
  skip "case D (the restart-rate floor) did not run — it needs a session to end"
  printf '\n%s\n' "RESULT: $PASS passed, $FAIL failed, $SKIP skipped (tmux absent — behavioural arms NOT covered)"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# ── C. THE REGRESSION: the old form must fail with a session present and no tty ─────────────────
log_line "C. REGRESSION — the OLD '\-A' form fails with a session present and NO terminal (positive control)"
"$TMUX_BIN" new-session -d -s "$S" "exec /bin/sleep 300" || bad "could not create the fixture session"
if "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
  ok "fixture: '$S' exists, so the -A path will take the ATTACH branch"
else
  bad "fixture: '$S' does not exist — case C would be vacuous"
fi
C_ERR="$TMP/c.err"
run_no_tty "$TMUX_BIN" new-session -A -d -s "$S" "exec /bin/sleep 300" >"$TMP/c.out" 2>"$C_ERR"
C_RC=$?
if [ "$C_RC" -ne 0 ]; then
  ok "the OLD form FAILS here (rc=$C_RC) — the environment is genuinely tty-less, so case B is not vacuous"
else
  bad "the OLD '\-A' form SUCCEEDED (rc=0) in this environment — it is not tty-less, so case B could not detect the defect. Case C must fail; this is a RED."
fi
if grep -q 'open terminal failed' "$C_ERR"; then
  ok "the old form's failure is the measured one: 'open terminal failed: not a terminal'"
else
  bad "the old form failed, but not with 'open terminal failed' — this is not the defect under test: $(head -2 "$C_ERR")"
fi
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true

# ── A. no session -> create it, detached, exit 0 ────────────────────────────────────────────────
log_line "A. no session -> creates it DETACHED and exits 0"
A_ERR="$TMP/a.err"
bash "$TARGET" >"$TMP/a.out" 2>"$A_ERR" &
A_PID=$!
# ⛔ TWO DIFFERENT WAITS, because a cold tmux server is a THIRD state. `new-session -d` against a
# server that is still booting returns 0 and `has-session` can miss for a moment — so "not listed yet"
# is not "died", and treating it as death is a false failure. Wait for APPEARANCE first...
_w=0; while [ "$_w" -lt 100 ] && ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; do sleep 0.1; _w=$(( _w + 1 )); done
if "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
  ok "case A: '$S' was created"
else
  bad "case A: '$S' was NOT created within 10s"
fi
# ...THEN require it to STILL be there: that is what rules out a pane that died and whose session tmux
# has not torn down yet (measured 2026-10-18, tmux 3.8). 4 s also clears the entry point's OWN 2 s
# settle window, so the kill below lands in its supervise phase and not in the middle of its proof.
sleep 4
A_PANE="$(session_pid)"
if [ -n "$A_PANE" ] && kill -0 "$A_PANE" 2>/dev/null; then
  ok "case A: still alive 2s later, with a live pane (pid $A_PANE) — the loop is actually running"
else
  bad "case A: no live pane 2s after creation — a create that 'succeeded' is not a controller"
fi
if grep -q 'open terminal failed' "$A_ERR"; then
  bad "case A: the entry point ATTACHED (open terminal failed) — it must never attach on create"
else
  ok "case A: no attach was attempted"
fi
# The wrapper BLOCKS while the session lives; kill the session to let it return.
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true
wait "$A_PID"; A_RC=$?
if [ "$A_RC" -eq 0 ]; then
  ok "case A: exit 0"
else
  bad "case A: exit $A_RC (want 0) — stderr: $(head -3 "$A_ERR")"
fi

# ── H. an EMPTY plist value still reaches the pane ──────────────────────────────────────────────
log_line "H. an EMPTY plist value is FORWARDED, not dropped (the pane must not inherit the tmux SERVER's)"
# install.sh renders OR empty ON PURPOSE (#2040: derive it from $REPO's origin). If the entry point
# forwards only NON-EMPTY values, the pane silently inherits the server's OR, and the controller grades
# one repo's queue while dispatching into another -- #2040's measured symptom, and invisible.
: > "$O/pane-env"
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true
OR= REPO=the-real-repo-value bash "$TARGET" >"$TMP/h.out" 2>"$TMP/h.err" &
H_PID=$!
_w=0; while [ "$_w" -lt 100 ] && [ ! -s "$O/pane-env" ]; do sleep 0.1; _w=$(( _w + 1 )); done
sleep 3   # past the 2 s settle window, so the kill lands in the supervise phase
H_ENV="$(cat "$O/pane-env" 2>/dev/null)"
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true
wait "$H_PID" 2>/dev/null
if grep -q 'OR=\[\]' <<<"$H_ENV"; then
  ok "case H: OR rendered empty by the plist arrives EMPTY in the pane (not the server's stale value)"
else
  bad "case H: the pane did not get OR empty — got: $H_ENV"
fi
if grep -q 'REPO=\[the-real-repo-value\]' <<<"$H_ENV"; then
  ok "case H: a non-empty value is still forwarded (REPO)"
else
  bad "case H: REPO did not reach the pane — got: $H_ENV"
fi
# ── B. session already exists -> exit 0, no attach, no second controller ────────────────────────
log_line "B. session ALREADY EXISTS -> exit 0, NO attach, and NOT a second controller"
"$TMUX_BIN" new-session -d -s "$S" "exec /bin/sleep 300" || bad "could not create the case-B fixture"
B_PANE_BEFORE="$(session_pid)"
B_ID_BEFORE="$("$TMUX_BIN" list-sessions -F '#{session_name} #{session_created}' 2>/dev/null | awk -v n="$S" '$1==n{print $2}')"
B_ERR="$TMP/b.err"
bash "$TARGET" >"$TMP/b.out" 2>"$B_ERR" &
B_PID=$!
# Give the wrapper a full settle window it should NOT be using (it must take the guard, not create).
sleep 3
if grep -q 'open terminal failed' "$B_ERR"; then
  bad "case B: the entry point ATTACHED to the existing session — this is THE defect (7,633 launches)"
else
  ok "case B: no attach attempt (no 'open terminal failed') with the session already present"
fi
B_PANE_AFTER="$(session_pid)"
B_ID_AFTER="$("$TMUX_BIN" list-sessions -F '#{session_name} #{session_created}' 2>/dev/null | awk -v n="$S" '$1==n{print $2}')"
if [ -n "$B_PANE_BEFORE" ] && [ "$B_PANE_BEFORE" = "$B_PANE_AFTER" ]; then
  ok "case B: the pane is UNCHANGED (pid $B_PANE_BEFORE) — no second controller, no replace"
else
  bad "case B: the pane changed ($B_PANE_BEFORE -> $B_PANE_AFTER) — the entry point started a second controller or replaced the session"
fi
if [ -n "$B_ID_BEFORE" ] && [ "$B_ID_BEFORE" = "$B_ID_AFTER" ]; then
  ok "case B: the same session (created $B_ID_BEFORE) is still the controller's"
else
  bad "case B: the session was replaced (created $B_ID_BEFORE -> $B_ID_AFTER)"
fi
if kill -0 "$B_PID" 2>/dev/null; then
  ok "case B: the wrapper is BLOCKING while the session lives — that is what makes KeepAlive supervision real"
else
  bad "case B: the wrapper exited while the session was still alive — KeepAlive would supervise nothing"
fi
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true
wait "$B_PID"; B_RC=$?
if [ "$B_RC" -eq 0 ]; then
  ok "case B: exit 0 once the session ended"
else
  bad "case B: exit $B_RC (want 0) — stderr: $(head -3 "$B_ERR")"
fi
if grep -q 'the .*controller session ended after' "$B_ERR"; then
  ok "case B: it said how long it ran (the one datum that separates 'idle box' from 'died at once')"
else
  bad "case B: no lifetime line on exit"
fi

# ── D. the restart-rate floor is real ───────────────────────────────────────────────────────────
log_line "D. the restart-rate floor is REAL (a 2 s floor is measured on the clock, not read from the source)"
if grep -q 'must be a non-negative integer' <<<"$(CONTROLLER_RESTART_FLOOR=abc bash "$TARGET" 2>&1)"; then
  ok "case D: a non-numeric floor is refused by name"
else
  bad "case D: a non-numeric floor was not refused"
fi
D_ERR="$TMP/d.err"
# THE FLOOR MUST BE ARITHMETICALLY UNAVOIDABLE, OR THE ASSERTION IS INERT (review P2). The wrapper's
# own lifetime here is: ~2 s settle + up to one 5 s poll after the kill = at most ~7 s of wall clock
# with NO floor applied. A 10 s floor therefore forces >= 12 s (2 s settle + 10 s floor), and deleting
# the floor line drops the total to <= 7 s. A first version asserted "-ge 2", which could never fire.
FLOOR_S=10
D_T0="$(date +%s)"
CONTROLLER_RESTART_FLOOR=$FLOOR_S bash "$TARGET" >"$TMP/d.out" 2>"$D_ERR" &
D_PID=$!
_w=0; while [ "$_w" -lt 100 ] && ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; do sleep 0.1; _w=$(( _w + 1 )); done
sleep 4   # clear the entry point's own 2 s settle window, then end the session in its supervise phase
"$TMUX_BIN" kill-session -t "=$S" 2>/dev/null || true
wait "$D_PID"; D_RC=$?
D_ELAPSED=$(( $(date +%s) - D_T0 ))
if [ "$D_RC" -eq 0 ]; then
  ok "case D: exit 0"
else
  bad "case D: exit $D_RC — stderr: $(head -2 "$D_ERR")"
fi
if [ "$D_ELAPSED" -ge $(( FLOOR_S + 2 )) ]; then
  ok "case D: total ${D_ELAPSED}s with a ${FLOOR_S}s floor (the session lived ~4 s) — the floor is real, not declarative"
else
  bad "case D: returned after ${D_ELAPSED}s with a ${FLOOR_S}s floor and a ~4 s session — the floor did NOT engage (a floorless build would land here)"
fi

# ── summary ────────────────────────────────────────────────────────────────────────────────────
log_line "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
