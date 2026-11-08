#!/usr/bin/env bash
# install-conflict-rebase-timer.test.sh — self-check for scripts/install-conflict-rebase-timer.sh and
# for the BRAKE half of scripts/conflict-rebase-timer.sh (agent-infra#2698 / PR #3760 review P1-2, P1-4).
#
# Run: bash scripts/install-conflict-rebase-timer.test.sh    (exits 0 when every assertion passes)
#
# ⛔ WHY THIS FILE EXISTS. Before it, `install-conflict-rebase-timer.sh` was executed by NOTHING: the
# launcher's own suite replaces it with a two-line stub (`scripts/activate-harness.test.sh:53-56`) and
# every other gate gives it `bash -n` and no more. The measured consequence: DELETING the installer left
# the whole suite green (119 passed, 0 failed), so F3 — `--report-only` inserted the dry-run key into the
# plist's TOP-LEVEL dict instead of `EnvironmentVariables`, so an operator disarming a bot that REBASES
# AND PUSHES got a valid file, a success message, and a bot that kept acting — was pinned by nothing.
# The same gap covered the `ExecStart=` refusal, the transient-scratch refusal, the interval bounds,
# `--status`, `--uninstall`, and `pause`'s state-dir resolution.
#
# Hermetic: HOME, the checkout, the install dirs and BOTH scheduler CLIs are files under one mktemp
# fixture. No systemctl, no launchctl, no sudo, no network, nothing written outside the fixture (and the
# fixture is removed on exit, including the failure path).
#
# ⛔ NO PLACEHOLDER MAY APPEAR INSIDE AN XML COMMENT in the plist this renders — a doubled dash is
# illegal in XML text — so no option flag is spelled with its dashes in this header either.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALLER="$HERE/install-conflict-rebase-timer.sh"
TIMER="$HERE/conflict-rebase-timer.sh"
[ -f "$INSTALLER" ] || { echo "missing $INSTALLER"; exit 1; }
[ -f "$TIMER" ] || { echo "missing $TIMER"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
ck()  { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }
has()  { case "${1:-}" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
assert_contains() { has "${1:-}" "$2" && ok "$3" || { bad "$3 (missing: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2; }; }
assert_absent()   { has "${1:-}" "$2" && { bad "$3 (found: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2; } || ok "$3"; }
assert_eq()       { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', expected '$2')"; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/act-inst.XXXXXX")" || exit 1
cleanup() { rm -rf "$FX"; }
trap cleanup EXIT

# ⛔ A FIXTURE PATH THAT DOES NOT LOOK LIKE `mktemp`'s OWN SHAPE. The installer refuses a state/unit
# rendered from TRANSIENT SCRATCH (`is_transient_scratch`, which matches `/tmp/tmp.??????` and its
# TMPDIR/TMPDIR-symlinked variants), because such a unit exits 127 every tick while `list-timers` reads
# green. The template above is `act-inst.XXXXXX`, not `tmp.XXXXXX`, so it is an ordinary directory and
# the tests below exercise the REAL guard rather than tripping over their own fixture.
case "$FX" in *'/tmp/tmp.'*) echo "fixture $FX looks like transient scratch — refusing to run"; exit 1 ;; esac

BIN="$FX/bin"
mkdir -p "$BIN" "$FX/checkout/.git" "$FX/units" "$FX/LaunchAgents" "$FX/home" "$FX/state"
# The launcher the plist's ProgramArguments names, and a timer script that is a regular readable file.
: >"$FX/pi-reap-worktrees-launchd.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FX/conflict-rebase-timer.sh"
chmod +x "$FX/conflict-rebase-timer.sh"

# ── scheduler shims: they RECORD every call, so "the installer said it armed" is checked against the
#    call the scheduler actually received, not against the installer's own prose ────────────────────
cat >"$BIN/systemctl" <<'SHIM'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${SHIM_LOG:?}"
case "$*" in
  *LastTriggerUSec*) printf '%s\n' "${SHIM_LAST_FIRE:-}" ;;
  *'Result'*)        printf '%s\n' "${SHIM_RESULT:-success}" ;;
  *'Environment'*)   [ -n "${SHIM_UNIT_STATE:-}" ] && printf 'Environment=CONFLICT_REBASE_STATE=%s\n' "$SHIM_UNIT_STATE" ;;
  *'is-enabled'*)    printf '%s\n' "${SHIM_IS_ENABLED:-enabled}" ;;
  *'is-active'*)     printf '%s\n' "${SHIM_IS_ACTIVE:-active}" ;;
esac
exit 0
SHIM
cat >"$BIN/launchctl" <<'SHIM'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"${SHIM_LOG:?}"
case "$1" in print) exit "${SHIM_PRINT_RC:-0}" ;; esac
exit 0
SHIM
chmod +x "$BIN/systemctl" "$BIN/launchctl"

# ── a service template with NO `ExecStart=` — systemd accepts the FILE and then refuses the TIMER that
#    triggers it, so the installer must refuse at INSTALL time ───────────────────────────────────────
mkdir -p "$FX/tpl-noexec"
for f in "$REPO"/templates/systemd/eldato-conflict-rebase.service "$REPO"/templates/systemd/eldato-conflict-rebase.timer; do
    grep -v '^ExecStart=' "$f" >"$FX/tpl-noexec/$(basename "$f")"
done

OUT=""; RC=0; EXTRA_ENV=()
RUN() { # <installer args...>
    : >"$FX/shim.log"
    OUT="$(env -u CONFLICT_REBASE_STATE -u ELDATO_PLATFORM \
        HOME="${IHOME:-$FX/home}" \
        CONFLICT_REBASE_TIMER="$FX/conflict-rebase-timer.sh" \
        CONFLICT_REBASE_CHECKOUT="$FX/checkout" \
        TEMPLATES_DIR="${TPL_DIR:-$REPO/templates/systemd}" \
        LAUNCHD_TEMPLATES_DIR="$REPO/templates/launchd/conflict-rebase" \
        SYSTEMD_UNIT_DIR="$FX/units" \
        LAUNCHD_AGENTS_DIR="$FX/LaunchAgents" \
        SYSTEMCTL="$BIN/systemctl" \
        LAUNCHCTL="$BIN/launchctl" \
        SHIM_LOG="$FX/shim.log" \
        ELDATO_LAUNCHER_PY="$(command -v python3)" \
        ELDATO_LAUNCHER="$FX/pi-reap-worktrees-launchd.py" \
        SUDO= \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash "$INSTALLER" "$@" 2>&1)"; RC=$?
}

plist_get() { # <plist> <key> [env|top] -> the value, or empty
    python3 - "$1" "$2" "${3:-env}" <<'PY'
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(0)
if sys.argv[3] == "top":
    v = d.get(sys.argv[2])
else:
    v = (d.get("EnvironmentVariables") or {}).get(sys.argv[2])
if isinstance(v, str):
    print(v)
PY
}

echo "== T1: a systemd install writes the pair, arms it, and is verified by RE-READING ──"
EXTRA_ENV=(); RUN --install
assert_eq "$RC" 0 "T1 --install exits 0"
ck "$([ -f "$FX/units/eldato-conflict-rebase.service" ] && [ -f "$FX/units/eldato-conflict-rebase.timer" ]; echo $?)" \
   "T1 both unit files exist in the override dir"
assert_contains "$(cat "$FX/units/eldato-conflict-rebase.service" 2>/dev/null)" 'ExecStart=/bin/bash' \
    "T1 the rendered service names its ExecStart"
assert_contains "$(cat "$FX/units/eldato-conflict-rebase.service" 2>/dev/null)" \
    "Environment=CONFLICT_REBASE_STATE=$FX/home/.pi/agent/state/conflict-rebase" \
    "T1 the unit exports the state dir the pass will use (one path, not two)"
assert_contains "$(cat "$FX/shim.log")" 'daemon-reload' "T1 the installer re-read the units"
assert_contains "$(cat "$FX/shim.log")" 'enable --now eldato-conflict-rebase.timer' "T1 the timer was ARMED, not merely written"
assert_absent   "$(grep -E '^Environment=' "$FX/units/eldato-conflict-rebase.service" 2>/dev/null)" 'CONFLICT_REBASE_DRY_RUN' \
    "T1 a plain --install ships no dry-run key: the arming IS the artifact (#1678)"

echo "== T2: --report-only re-renders the ARMED artifact with the dry-run key (systemd half) ──"
EXTRA_ENV=(); RUN --report-only
assert_eq "$RC" 0 "T2 --report-only exits 0"
assert_contains "$(cat "$FX/units/eldato-conflict-rebase.service" 2>/dev/null)" 'Environment=CONFLICT_REBASE_DRY_RUN=1' \
    "T2 the disarm is visible in the unit, not implied by the installer's message"
EXTRA_ENV=(); RUN --install
assert_absent "$(grep -E '^Environment=' "$FX/units/eldato-conflict-rebase.service" 2>/dev/null)" 'CONFLICT_REBASE_DRY_RUN' \
    "T2 and a following --install REMOVES it (the disarm is re-rendered, never hand-edited)"

echo "== T3: F3 — the launchd dry-run key lands INSIDE EnvironmentVariables, and is readable back ──"
EXTRA_ENV=("ELDATO_PLATFORM=Darwin"); RUN --report-only
assert_eq "$RC" 0 "T3 a Darwin --report-only install exits 0"
PLIST="$FX/LaunchAgents/com.eldato.conflict-rebase.plist"
ck "$([ -f "$PLIST" ]; echo $?)" "T3 the plist was installed"
assert_eq "$(plist_get "$PLIST" CONFLICT_REBASE_DRY_RUN env)" "1" \
    "T3 CONFLICT_REBASE_DRY_RUN is readable from EnvironmentVariables (F3: launchd ignores an unknown top-level key)"
assert_eq "$(plist_get "$PLIST" CONFLICT_REBASE_DRY_RUN top)" "" \
    "T3 and it is NOT at the top level — where the pre-fix insert-before-the-last-dict put it, invisibly"
assert_eq "$(plist_get "$PLIST" CONFLICT_REBASE_STATE env)" "$FX/home/.pi/agent/state/conflict-rebase" \
    "T3 the same dict still carries the state dir (the insert did not replace the env dict)"
assert_contains "$(cat "$FX/shim.log")" 'bootstrap gui/' "T3 the agent was bootstrapped"
assert_contains "$(cat "$FX/shim.log")" 'print gui/' "T3 and LOADED-ness was re-read, not inferred from bootstrap's exit code"

echo "== T4: a plain Darwin install carries no dry-run key, and the job still parses ──"
rm -f "$PLIST"
EXTRA_ENV=("ELDATO_PLATFORM=Darwin"); RUN --install
assert_eq "$RC" 0 "T4 a plain Darwin install exits 0"
assert_eq "$(plist_get "$PLIST" CONFLICT_REBASE_DRY_RUN env)" "" "T4 no dry-run key after a plain install"
assert_contains "$(cat "$PLIST" 2>/dev/null)" '<key>StartInterval</key>' "T4 the plist is a real LaunchAgent, not a fragment"

echo "== T5: P2-5 — a space in a path is legal for launchd and refused for systemd ──"
IHOME="$FX/sp ace"; rm -f "$PLIST"
EXTRA_ENV=("ELDATO_PLATFORM=Darwin"); RUN --dry-run
assert_eq "$RC" 0 "T5 Darwin + HOME containing a space is ACCEPTED (a plist <string> may carry a space)"
assert_absent "$OUT" 'contains whitespace' "T5 and it is not refused over systemd's whitespace rule"
assert_contains "$OUT" "<string>$FX/sp ace/.pi/agent/state/conflict-rebase</string>" \
    "T5 the dry-run render really used the spaced path (an XML <string>, where a space is legal)"
IHOME="$FX/sp ace"
EXTRA_ENV=(); RUN --dry-run
assert_eq "$RC" 1 "T5 Linux + the same path is REFUSED (systemd splits the rendered unit on it)"
assert_contains "$OUT" 'contains whitespace' "T5 and the refusal names the reason"
IHOME=""

echo "== T6: the cadence is validated, because it is BAKED INTO a persistent unit ──"
EXTRA_ENV=("CONFLICT_REBASE_INTERVAL_MIN=0"); RUN --dry-run
assert_eq "$RC" 1 "T6 a cadence of 0 minutes is refused"
assert_contains "$OUT" 'out of range' "T6 and the message says it is out of range"
EXTRA_ENV=("CONFLICT_REBASE_INTERVAL_MIN=1441"); RUN --dry-run
assert_eq "$RC" 1 "T6 a cadence of 1441 minutes is refused"
EXTRA_ENV=("CONFLICT_REBASE_INTERVAL_MIN=45"); RUN --dry-run
assert_eq "$RC" 0 "T6 45 minutes is accepted (the reason the timer is monotonic, not OnCalendar)"

echo "== T7: a rendered service with no ExecStart= is refused at INSTALL time ──"
TPL_DIR="$FX/tpl-noexec"; EXTRA_ENV=(); RUN --install
assert_eq "$RC" 1 "T7 a service template without ExecStart is refused"
assert_contains "$OUT" 'no ExecStart=' "T7 and it names the missing directive rather than installing it"
ck "$([ ! -f "$FX/units/eldato-conflict-rebase.service" ] || ! grep -q 'no ExecStart' "$FX/units/eldato-conflict-rebase.service"; echo 0)" \
   "T7 the refusal did not install the artifact anyway"
TPL_DIR=""

echo "== T8: --status reads the BEACON and the BRAKE, and never calls a never-fired timer armed ──"
EXTRA_ENV=("CONFLICT_REBASE_STATE=$FX/state")
date +%s >"$FX/state/timer.beat"
: >"$FX/state/PAUSED"
RUN --status
assert_contains "$OUT" "beacon: $FX/state/timer.beat" "T8 the beacon is reported from the state dir the unit exports"
assert_contains "$OUT" 'brake: PAUSED' "T8 a brake file is reported as PAUSED"
EXTRA_ENV=("CONFLICT_REBASE_STATE=$FX/state" "SHIM_LAST_FIRE=n/a")
rm -f "$FX/state/PAUSED" "$FX/state/timer.beat"
RUN --status
assert_eq "$RC" 1 "T8 an armed-but-never-fired timer fails --status (rc 1)"
assert_contains "$OUT" 'NEVER FIRED' "T8 and it says NEVER FIRED — an n/a read is not an armed timer (F18)"
assert_contains "$OUT" 'beacon: NEVER' "T8 and a box with no pass reports no beacon"

echo "== T9: --uninstall disarms and removes, and says what it left behind ──"
EXTRA_ENV=("CONFLICT_REBASE_STATE=$FX/state"); RUN --install >/dev/null 2>&1
RUN --uninstall
assert_contains "$(cat "$FX/shim.log")" 'disable --now eldato-conflict-rebase.timer' "T9 the timer was disarmed"
ck "$([ ! -f "$FX/units/eldato-conflict-rebase.service" ] && [ ! -f "$FX/units/eldato-conflict-rebase.timer" ]; echo $?)" \
   "T9 both unit files are gone"
assert_contains "$OUT" 'state and beacon left in place' "T9 it states that the state survived (an uninstall is not a data loss)"

# ── T10: P1-4 — the BRAKE resolves the state dir the SCHEDULED PASS reads ─────────────────────────────
# The defect: `pause` wrote the state dir from the OPERATOR'S ambient shell while the timer's tick read
# the one the INSTALLED unit exports. On a non-default install those differ, so `pause` printed `paused`,
# the brake landed where nothing looks, the pass kept rebasing and PUSHING, and `status` said PAUSED while
# `activate-harness.sh` — which reads the unit — said it was not. One brake, two answers, and the operator
# held the wrong one.
echo "== T10: pause/resume write the INSTALLED state dir, and a divergence is refused ──"
UNIT_STATE="$FX/unit-state"
mkdir -p "$UNIT_STATE"
BRAKE() { # <wrapper args...>
    OUT="$(env -u CONFLICT_REBASE_STATE \
        HOME="$FX/home" \
        CONFLICT_REBASE_SYSTEMCTL="$BIN/systemctl" \
        CONFLICT_REBASE_PLIST="$FX/LaunchAgents/none.plist" \
        SHIM_LOG="$FX/shim.log" \
        SHIM_UNIT_STATE="$UNIT_STATE" \
        ${BRAKE_ENV[@]+"${BRAKE_ENV[@]}"} \
        bash "$TIMER" "$@" 2>&1)"; RC=$?
}
BRAKE_ENV=()
rm -f "$UNIT_STATE/PAUSED"
BRAKE pause
assert_eq "$RC" 0 "T10 pause exits 0"
ck "$([ -f "$UNIT_STATE/PAUSED" ]; echo $?)" \
   "T10 the brake was written to the directory the INSTALLED UNIT exports, not the operator's ambient one"
assert_contains "$OUT" "state dir from the installed systemd unit" "T10 and the operator is told WHICH directory it landed in, and why"
BRAKE resume
assert_eq "$RC" 0 "T10 resume exits 0"
ck "$([ ! -f "$UNIT_STATE/PAUSED" ]; echo $?)" "T10 resume removed the same file it wrote"
BRAKE_ENV=("CONFLICT_REBASE_STATE=$FX/state")
BRAKE pause
assert_eq "$RC" 2 "T10 an ambient CONFLICT_REBASE_STATE that DISAGREES with the installed unit is REFUSED (rc 2)"
assert_contains "$OUT" "$FX/unit-state" "T10 and the refusal names the installed directory"
assert_contains "$OUT" "$FX/state" "T10 …and the ambient one it refused"
ck "$([ ! -f "$FX/state/PAUSED" ]; echo $?)" "T10 nothing was written to the path nobody reads"
BRAKE_ENV=("CONFLICT_REBASE_STATE=$UNIT_STATE")
BRAKE pause
assert_eq "$RC" 0 "T10 an ambient value that AGREES with the unit is accepted"
ck "$([ -f "$UNIT_STATE/PAUSED" ]; echo $?)" "T10 and it lands in the same place"

echo
echo "install-conflict-rebase-timer.test.sh — passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
