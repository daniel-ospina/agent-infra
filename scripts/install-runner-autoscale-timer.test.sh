#!/usr/bin/env bash
# install-runner-autoscale-timer.test.sh — self-check for scripts/install-runner-autoscale-timer.sh
# and the two artifacts it renders (agent-infra#2403).
#
# Run: bash scripts/install-runner-autoscale-timer.test.sh   (exits 0 when every assertion passes)
#
# What each case proves — T0 onwards, and why each one exists — is in docs/ops/runner-autoscale.md
# under the heading: the self-check, case by case. It is kept OUT of this file on purpose: the
# working-tree guard tokenises a script text, and a prose header ahead of the code glues lines
# together until the body reads as an unverifiable heredoc, so the suite cannot be executed at all
# (issue 709, measured three times). Documentation belongs where a reader looks for it; this file
# stays executable, and this header carries no quote characters of any kind for that reason.
#
# Hermetic: home, state dir and install dir are redirected under a mktemp fixture root; the
# scheduler tools are files under it; the converger is a stub. No network, no GitHub, no scheduler.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INST="$HERE/install-runner-autoscale-timer.sh"
# ⛔ `sed -i` IS NOT PORTABLE, AND THIS SUITE MUTATES A RENDERED ARTIFACT IN TEN PLACES TO SET UP THE
# CASES THAT CAN ONLY BE VALIDATED ON A MAC. The repo owns this hazard and pins it (`lib/box.sh`'s own
# header, and `lib/box.test.sh`'s darwin arm asserting the GNU spelling is SILENT there: no edit, exit
# 0). Hand-rolling it here made the suite a false RED on the one platform it exists to validate — the
# mutation did nothing, the artifact stayed healthy, `--status` correctly exited 0, and the case then
# failed its own `assert_eq "$RC" 1`. The installer beside it already uses a portable form, so the two
# files disagreed about the same platform. Every mutation below goes through the shim.
BOX="$HERE/lib/box.sh"
[ -f "$BOX" ] || { echo "missing $BOX — the portability shim this suite's mutations depend on"; exit 1; }
# shellcheck source=scripts/lib/box.sh
. "$BOX"
UNIT_NAME="eldato-runner-autoscale"
LABEL="com.eldato.runner-autoscale"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
# ⛔ A FAILING EXIT-STATUS ASSERTION MUST PRINT WHAT IT CAPTURED. Without this, a red `assert_eq "$RC" 0`
# shows only `got 1` and throws away the very message that names the cause — which is what made a
# 1-in-10 environmental transient in the launchd arm undiagnosable across three attempts.
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', expected '$2')"; if [ -n "${OUT:-}" ]; then echo "--- output ---" >&2; printf '%s\n' "$OUT" | sed 's/^/    /' >&2; fi; fi; }
assert_contains() { case "${1:-}" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)"; echo "--- output ---" >&2; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; esac; }
assert_absent()   { case "${1:-}" in *"$2"*) bad "$3 (found: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; *) ok "$3" ;; esac; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_not_contains() { case "${1:-}" in *"$2"*) bad "$3 (unexpected: $2)"; echo "--- output ---" >&2; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; *) ok "$3" ;; esac; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (unexpected file: $1)"; else ok "$2"; fi; }
say_case()        { echo; echo "── $* ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-inst-test.XXXXXX")" || { echo "cannot create a temp dir"; exit 1; }
cleanup() {
    # ⛔ A DISCARD WHOSE TARGET COULD BE ANYTHING IS REFUSED BY THE TOOLING AND IS WRONG ANYWAY: this
    # removes THIS suite s fixture directories and nothing else. MT is the transient-scratch fixture
    # (T5), whose name must look like a mktemp tree at the TOP level for the guard under test.
    case "$T" in
        */runner-autoscale-inst-test.*) rm -rf "$T" ;;
        *) : ;;
    esac
    case "${MT:-}" in
        */tmp.runnerautoscale.*) rm -rf "$MT" ;;
        *) : ;;
    esac
}
trap cleanup EXIT

# ⛔ HERMETICITY IS ASSERTED, NOT ASSUMED. Every case below is supposed to run against the fixture
# tree; the arming record, the state dir and the install dir are the three paths that, if a case ever
# forgot one, would touch the LIVE schedule and arming record of this box instead of a fixture. So
# suite fails closed on a non-fixture path rather than discovering it later.
ARM="$T/home/.pi/agent/state/runner-autoscale.armed"
FIXTURE_PREFIX="${TMPDIR:-/tmp}/runner-autoscale-inst-test."
if [ "${T#"$FIXTURE_PREFIX"}" = "$T" ] || [ "${ARM#"$T"}" = "$ARM" ]; then
    echo "REFUSING to run: fixtures are not under a mktemp tree (T=$T ARM=$ARM)" >&2
    exit 1
fi

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────
# ⛔ EVERY FIXTURE IS WRITTEN TO A LITERAL PATH, never through a helper function argument. A shim whose
# redirection target is a helper argument is a WRITE TO AN UNVERIFIABLE PATH — the hub guard reads the
# target as a shell expansion, cannot tell which file it would create, and fails closed before the
# suite runs at all (measured while writing this suite). Literal paths keep the suite executable from
# a worktree. (Do not spell a heredoc opener in a comment either: the guard tokenises prose, and the
# unmatched opener swallows the rest of the file as a heredoc body — measured, twice.)
mkdir -p "$T/home/.pi/agent/state" "$T/sysd" "$T/agents" "$T/bin"
# The stub converger: answers --status --json with a CEILING, so the arming preflight has something
# to read.
cat >"$T/home/converger.py" <<'STUB'
import json, sys
print(json.dumps({"repo": "o/r", "verdict": "at-ceiling", "ncpu": 8, "mem_available_mb": 5000,
                  "ceiling": 3, "reading": "ncpu=8 ceiling=3"}))
STUB
# A converger that CANNOT measure (the arming preflight must refuse it).
cat >"$T/home/bad.py" <<'BAD'
import sys
print("UNMEASURABLE: fixture", file=sys.stderr)
raise SystemExit(2)
BAD
# A converger that answers but publishes NO ceiling.
cat >"$T/home/onceiling.py" <<'ONEC'
import json
print(json.dumps({"verdict": "converged"}))
ONEC
# A converger that MEASURED the box and then reports STARVATION (exit 4). 4 is a reason to arm, not a
# reason to refuse, and nothing exercised that decision until T52 (it was carried by a comment only).
cat >"$T/home/starved.py" <<'STARVED'
import json
print(json.dumps({"repo": "o/r", "verdict": "starvation", "ncpu": 8, "mem_available_mb": 5000,
                  "ceiling": 3, "reading": "ncpu=8 ceiling=3"}))
raise SystemExit(4)
STARVED
# A converger whose ACTION failed (exit 3) while still answering — a box that was not measured, so
# `--arm` must refuse it. The other side of the allow-list.
cat >"$T/home/actionfail.py" <<'ACTIONFAIL'
import json
print(json.dumps({"repo": "o/r", "verdict": "action-failed", "ncpu": 8, "mem_available_mb": 5000,
                  "ceiling": 3, "reading": "ncpu=8 ceiling=3"}))
raise SystemExit(3)
ACTIONFAIL
# The systemctl shim: records every call; answers the verbs both the install and the status path use.
cat >"$T/bin/systemctl" <<SYSTEMCTL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/systemctl.log"
# ⛔ A USER-TARGET INSTALL CALLS `systemctl --user <verb>`, so the shim has to model the flag: the
# verb is the first argument THAT IS NOT `--user`. Without this the user arm answered every verb with
# the `*` fallback's silence, which read as `enabled=` / `timer_active=` (empty) — a fixture that
# cannot represent the target the installer supports.
[ "\${1:-}" = "--user" ] && shift
case "\$1" in
  is-enabled)   printf '%s\n' "\${SHIM_ENABLED:-enabled}"; exit 0 ;;
  is-active)    printf '%s\n' "\${SHIM_ACTIVE:-active}"; exit 0 ;;
  list-timers)  printf 'Thu 2026-10-29 15:36:43 UTC  8min left  n/a  now  $UNIT_NAME.timer $UNIT_NAME.service\n'; exit 0 ;;
  show)         printf '%s\n' "\${SHIM_LAST:-0}"; exit 0 ;;
  # `choose_target` probes the user manager with `--user show-environment` (through the SYSTEMCTL seam,
  # so this shim answers it). ⛔ WITHOUT A FAILURE MODE THE PROBE COULD NOT BE EXPRESSED, which is why
  # T47 used to depend on the HOST: it needed a box with no user manager, so it was green on a Mac and
  # red on `ubuntu-latest`. `SHIM_USER_MANAGER=no` is "no user manager here", on any host.
  show-environment) [ "\${SHIM_USER_MANAGER:-yes}" = "no" ] && exit 1; exit 0 ;;
  cat)          cat "$T/sysd/\$2" 2>/dev/null; exit \$? ;;
  *)            exit 0 ;;
esac
SYSTEMCTL_SHIM
# The launchctl shim: list prints the loaded-job table; every other verb succeeds.
cat >"$T/bin/launchctl" <<LAUNCHCTL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/launchctl.log"
case "\$1" in
  list) printf '%s\t%s\t%s\n' "\${SHIM_PID:--}" "\${SHIM_LAST_EXIT:-0}" "$LABEL"; exit 0 ;;
  *)    exit 0 ;;
esac
LAUNCHCTL_SHIM
chmod +x "$T/bin/systemctl" "$T/bin/launchctl"
# The loginctl shim: answers the linger probe, and `enable-linger` succeeds. Created HERE with the other
# shims (not lazily at the first user-target case) so `run_install` can pin `LOGINCTL` for EVERY case —
# the install path reads lingering through `${LOGINCTL:-loginctl}`, and a pinned-but-absent shim would
# make the pin itself the host dependency this suite exists to remove.
cat >"$T/bin/loginctl" <<LOGINCTL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/loginctl.log"
case "\$1" in
  show-user) printf '%s\n' "\${SHIM_LINGER:-yes}"; exit 0 ;;
  *) exit 0 ;;
esac
LOGINCTL_SHIM
chmod +x "$T/bin/loginctl"

# Resolve the interpreter WITHOUT a helper whose own words resemble a git prefix: the working-tree
# guard treats a `command`-prefixed word with an unresolvable verb as an unverifiable git anchor and
# refuses the whole suite (#1484/#709). `type -P` is a plain PATH lookup.
GOOD_PY="$(type -P python3.12 2>/dev/null)" || GOOD_PY=""
if [ -z "$GOOD_PY" ]; then GOOD_PY="$(type -P python3 2>/dev/null)" || GOOD_PY=""; fi
mkdir -p "$T/home/.pi/agent/state" "$T/sysd" "$T/agents" "$T/bin"
ARM="$T/home/.pi/agent/state/runner-autoscale.armed"
# ⛔ THE CROSS-SCOPE SCAN LIST IS PINNED TO A FIXTURE, so no case can read the host's real unit dirs. A
# box that happens to carry a system-scope install would otherwise add a note to every user-target run,
# and the suite's verdict would depend on what the machine running it has installed.
mkdir -p "$T/scopes"

# ENVV carries per-case ENVIRONMENT OVERRIDES (assignments only). They come AFTER the defaults, and
# env applies later assignments last, so an override wins. Kept as a variable rather than inline
# prefixes because a case that changes HOME, the script, the interpreter or the template dir must not
# have to restate the other six.
ENVV=()
# run_install <platform> <installdir|-> [args…] — ONE invocation with a fully redirected environment.
# RUNNER_AUTOSCALE_SCRIPT is pinned to the stub by default: the real converger would talk to GitHub on
# the arming preflight, which no test may do (T14 is the one case that resolves it, and it installs
# only — no preflight).
run_install() {
    local plat="$1" dir="$2"; shift 2
    local dirmap=()
    [ "$dir" != "-" ] && dirmap=(SYSTEMD_UNIT_DIR="$dir" LAUNCHD_AGENTS_DIR="$dir")
    # The installer is invoked by a LITERAL path from its own directory (never "$INST"): a script
    # execution spelled with a shell expansion is an unreadable effect for the hub guard, which fails
    # closed and refuses to run this suite at all from a worktree. The cd makes the literal path
    # resolvable for exactly the same reason.
    cd "$HERE" || return 1
    env HOME="$T/home" \
        RUNNER_AUTOSCALE_SCRIPT="$T/home/converger.py" \
        RUNNER_AUTOSCALE_PYTHON="$GOOD_PY" \
        RUNNER_AUTOSCALE_STATE_DIR="$T/home/.pi/agent/state" \
        RUNNER_AUTOSCALE_ARM_FILE="$ARM" \
        RUNNER_AUTOSCALE_REPO="o/r" \
        ELDATO_PLATFORM="$plat" \
        SYSTEMCTL="$T/bin/systemctl" LAUNCHCTL="$T/bin/launchctl" LOGINCTL="$T/bin/loginctl" \
        RUNNER_AUTOSCALE_SCOPE_SCAN="$T/scopes" \
        ${dirmap[@]+"${dirmap[@]}"} ${ENVV[@]+"${ENVV[@]}"} \
        bash ./install-runner-autoscale-timer.sh "$@" 2>&1
}

# A fresh install dir per case, so one case’s artifact can never satisfy another’s assertion.
# ⛔ NO DISCARD HERE. Every case gets its OWN fresh path under $T (c1..c14), so there is nothing to
# remove — and a `rm -rf "$1"` on a helper argument is an UNVERIFIABLE discard that makes the whole
# suite unexecutable under the working-tree guard (#709), which fails closed on exactly this shape.
fresh() { mkdir -p "$1"; }

# plist_args <plist> — the ProgramArguments, one per line (python3 is the test’s own parser).
plist_args() {
    python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1],"rb"))
for a in d["ProgramArguments"]:
    print(a)' "$1" 2>/dev/null
}
# plist_env <plist> <key> — one EnvironmentVariables value, read by the test's own parser. Needed
# because a plist that PARSES is not a plist that carries a USABLE value: the provisioner pin was
# escaped twice and pinned a path with literal backslashes while the plist still parsed cleanly.
plist_env() {
    python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1],"rb"))
print(d.get("EnvironmentVariables",{}).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

echo "install-runner-autoscale-timer.test.sh — agent-infra#2403"
echo "fixtures: $T"

# ── T0: the artifacts exist, and the timer names the service ────────────────────────────────
say_case "T0 the artifacts exist and agree with each other"
assert_file "$INST" "the installer exists"
assert_file "$REPO/templates/systemd/$UNIT_NAME.service" "the systemd service template exists"
assert_file "$REPO/templates/systemd/$UNIT_NAME.timer" "the systemd timer template exists"
assert_file "$REPO/templates/launchd/runner-autoscale/$LABEL.plist" "the launchd plist template exists"
assert_contains "$(cat "$REPO/templates/systemd/$UNIT_NAME.timer")" "Unit=$UNIT_NAME.service" \
    "the timer triggers the service it is named after"
assert_absent "$(grep -E '^WorkingDirectory=' "$REPO/templates/systemd/$UNIT_NAME.service")" "WorkingDirectory=" \
    "the service carries NO WorkingDirectory directive (a SYSTEM unit's %h is /root — measured 200/CHDIR)"
# ⛔ NO ENVIRONMENT DEFAULT MAY ARM THE PASS. The record is the only input; an ambient export that
# armed a fleet with nothing on disk to show for it is the defect the arming record exists to prevent.
assert_absent "$(grep -v '^ *#' "$INST")" "RUNNER_AUTOSCALE_MODE" \
    "no environment seam renders the mode (only the dated record does)"

# ── T1: the unarmed default is a DRY RUN ────────────────────────────────────────────────────
say_case "T1 an unarmed install renders --dry-run (DISARMED)"
D="$T/c1"; fresh "$D"; rm -f "$ARM"
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 0 "install exits 0"
assert_file "$D/$UNIT_NAME.service" "the service was written"
assert_file "$D/$UNIT_NAME.timer" "the timer was written"
assert_contains "$OUT" "mode:   --dry-run" "the summary names the DISARMED mode"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "the installed ExecStart carries --dry-run"
assert_contains "$OUT" "timer:  enabled" "the install reports the timer enabled (not just written)"
# An env var that LOOKS like a mode must not arm it.
ENVV=(RUNNER_AUTOSCALE_MODE=--apply RUNNER_AUTOSCALE_APPLY=1)
OUT2="$(run_install Linux "$D" --install)"; ENVV=()
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a stray RUNNER_AUTOSCALE_MODE/RUNNER_AUTOSCALE_APPLY export does NOT arm the artifact"
assert_absent "$OUT2" "converge (no mode flag)" "an ambient export does not reach the summary as ARMED"

# ── T2: a dated record arms it; a HALF record does not ─────────────────────────────────────
say_case "T2 the arming record is the only authority, and it fails closed"
printf 'armed-by=someone\n' >"$ARM"                        # half-written: no date
run_install Linux "$D" --install >/dev/null 2>&1
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a HALF-written record renders DISARMED (only armed-by, no armed-date)"
printf 'armed-date=2026-10-29T00:00:00Z\n' >"$ARM"          # the other half only
run_install Linux "$D" --install >/dev/null 2>&1
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a HALF-written record renders DISARMED (only armed-date, no armed-by)"
printf 'armed-by=someone\narmed-date=2026-10-29T00:00:00Z\nceiling=3\n' >"$ARM"
OUT="$(run_install Linux "$D" --install)"
# ⛔ ARMED MEANS NO MODE ARGUMENT — see T3.
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a complete record removes --dry-run (armed)"
assert_contains "$OUT" "ARMED" "the summary says ARMED"
rm -f "$ARM"

# ── T3: --apply is not a renderable flag ───────────────────────────────────────────────────
say_case "T3 the artifacts never emit an --apply flag (the pass has no such verb)"
assert_absent "$(cat "$INST")" "printf '%s' '--apply'" "the installer never prints --apply as a mode"
assert_absent "$(cat "$REPO/templates/systemd/$UNIT_NAME.service")" "--apply" \
    "the service template carries no literal --apply"
assert_absent "$(cat "$REPO/templates/launchd/runner-autoscale/$LABEL.plist")" "--apply" \
    "the plist template carries no literal --apply"

# ── T4: --arm preflights, and refuses a box it cannot measure ──────────────────────────────
say_case "T4 --arm preflights the converger and refuses an unreadable box"
D="$T/c4"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1        # a DISARMED artifact to observe
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/bad.py")
OUT="$(run_install Linux "$D" --arm --reason test)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--arm exits 1 when the preflight cannot measure"
assert_contains "$OUT" "REFUSING to arm" "the refusal is named"
assert_nofile "$ARM" "NO arming record is written when the preflight fails"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "--dry-run" \
    "the artifact stays DISARMED after a refused arm"
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/onceiling.py")
OUT="$(run_install Linux "$D" --arm)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--arm exits 1 when the record carries no ceiling"
assert_contains "$OUT" "NO ceiling" "the refusal names the missing ceiling"
assert_nofile "$ARM" "no record is written for an unread ceiling"
# …and the good shape really arms, with the measured ceiling IN the record.
OUT="$(run_install Linux "$D" --arm --reason 'unit test')"
assert_eq "$?" 0 "--arm exits 0 on a measurable box"
assert_contains "$OUT" "ARMED by 2" "the armed summary names the DATE it was armed (the audit datum)"
assert_file "$ARM" "the arming record was written"
assert_contains "$(cat "$ARM")" "ceiling=3" "the record carries the MEASURED ceiling"
assert_contains "$(cat "$ARM")" "armed-date=" "the record is dated"
assert_contains "$(cat "$ARM")" "reason=unit test" "the record carries the operator's reason"
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "the artifact is re-installed ARMED in the same verb"
say_case "T11 --report-only refuses while a record exists"
OUT="$(run_install Linux "$D" --report-only)"
assert_eq "$?" 1 "--report-only refuses while the box is armed"
assert_contains "$OUT" "--disarm" "the refusal names the verb that actually disarms"
# …and --disarm removes the record and re-renders disarmed.
OUT="$(run_install Linux "$D" --disarm)"
assert_eq "$?" 0 "--disarm exits 0"
assert_nofile "$ARM" "--disarm removed the record"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "--disarm re-installed the DISARMED artifact"

# ── T5: transient scratch is refused ──────────────────────────────────────────────────────
say_case "T5 a unit rendered from a mktemp tree is refused"
MT="/tmp/tmp.runnerautoscale.$$"; mkdir -p "$MT/.pi/agent/scripts" "$MT/.pi/agent/state"
cp "$T/home/converger.py" "$MT/.pi/agent/scripts/"
# ⛔ A GENUINE mktemp SHAPE AT THE TOP LEVEL (/tmp/tmp.…), which is what the guard matches — a nested
# `$T/tmp.abc` is NOT transient by construction and testing it would prove nothing (measured: it
# sailed through and tried the SYSTEM target). No unit-dir override: the override deliberately skips
# this heuristic. SUDO=false removes the system target, so a regressed guard writes inside the
# fixture HOME at worst — a test must never be able to write /etc/systemd.
ENVV=(HOME="$MT" RUNNER_AUTOSCALE_SCRIPT="$MT/.pi/agent/scripts/converger.py"
      RUNNER_AUTOSCALE_STATE_DIR="$MT/.pi/agent/state" RUNNER_AUTOSCALE_ARM_FILE="$MT/arm"
      SUDO=false)
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a transient-scratch install is refused (rc 1)"
assert_contains "$OUT" "REFUSING a scheduled install rendered from transient scratch space" \
    "the refusal names transient scratch, not a scheduler problem"
assert_contains "$OUT" "127" "the refusal names the measured consequence (127 every tick)"

# ── T6: an old interpreter is refused ─────────────────────────────────────────────────────
say_case "T6 an interpreter older than 3.12 is refused"
printf '#!/usr/bin/env bash\ncase "$*" in *version_info*) echo "3.11" ;; *) exit 1 ;; esac\n' >"$T/bin/oldpy"
chmod +x "$T/bin/oldpy"
D="$T/c6"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_PYTHON="$T/bin/oldpy")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a PINNED old interpreter is REFUSED (a named pin is the whole list, never a fallback)"
assert_contains "$OUT" "requires >= 3.12" "the old interpreter is REFUSED with the requirement quoted"
assert_contains "$OUT" "a named pin is the whole list" "the refusal names WHY it was not replaced"
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed with a substituted interpreter"
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "oldpy" \
    "the artifact NEVER pins an interpreter older than 3.12"

# ── T6b: a VALID pin is HONOURED, not quietly replaced ───────────────────────────────────
# Pinning exists so an operator can name a venv (a specific gh/module set). Refusing a bad pin while
# ignoring a good one would be the same substitution one direction over, and no other case pins a
# non-default interpreter, so a regression here would stay green.
say_case "T6b a pinned interpreter is used verbatim"
printf '#!/usr/bin/env bash\ncase "$*" in *version_info*) echo "3.12" ;; *) exec %s "$@" ;; esac\n' "$GOOD_PY" >"$T/bin/pin312"
chmod +x "$T/bin/pin312"
D="$T/c6b"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_PYTHON="$T/bin/pin312")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "a valid pin installs"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "$T/bin/pin312" \
    "the artifact pins the interpreter the operator NAMED, not the one the default resolver would pick"

# ── T7: whitespace — refused on systemd, allowed on launchd ────────────────────────────────
say_case "T7 whitespace is a SYSTEMD rule, not a launchd one"
SP="$T/home/my home"; mkdir -p "$SP"; cp "$T/home/converger.py" "$SP/"
ENVV=(HOME="$SP" RUNNER_AUTOSCALE_SCRIPT="$SP/converger.py")
OUT="$(run_install Linux "$T/c7" --install)"; RC=$?
assert_eq "$RC" 1 "a whitespace HOME is refused on the systemd arm"
assert_contains "$OUT" "whitespace" "the refusal names whitespace"
OUT="$(run_install Darwin "$T/c7d" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "the same whitespace path is ACCEPTED on the launchd arm (a plist string is one field)"

# ── T8: an unresolved placeholder is refused ──────────────────────────────────────────────
say_case "T8 an unresolved placeholder is refused, nothing installed"
mkdir -p "$T/tpl"
cp "$REPO/templates/systemd/$UNIT_NAME.timer" "$T/tpl/"
sed 's|{{PYTHON}}|{{NOT_A_PLACEHOLDER}}|; s|{{SCRIPT}}|{{ALSO_NOT}}|' \
    "$REPO/templates/systemd/$UNIT_NAME.service" >"$T/tpl/$UNIT_NAME.service"
D="$T/c8"; fresh "$D"
ENVV=(TEMPLATES_DIR="$T/tpl")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "an unresolved placeholder is refused"
assert_contains "$OUT" "unresolved placeholder" "the refusal names the placeholder"
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed"

# ── T9: --status is honest about not-installed and about drift ────────────────────────────
say_case "T9 --status: not-installed is a FAILURE, and a hand-edit is DRIFT"
D="$T/c9"; fresh "$D"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status on a box with nothing installed exits 1"
assert_contains "$OUT" "installed=no" "it says installed=no"
assert_contains "$OUT" "remedy=" "it names the remedy"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "--status on a healthy installed box exits 0"
assert_contains "$OUT" "installed=yes" "it says installed=yes"
assert_contains "$OUT" "mode=--dry-run" "it reports the artifact's OWN mode"
assert_contains "$OUT" "drift_artifact=no" "the freshly installed artifact is not drifted"
assert_contains "$OUT" "script_present=yes" "the artifact's target exists"
assert_contains "$OUT" "timer_active=active" "it reports the scheduler's own answer"
# A hand-edit must be reported, not silently blessed.
printf '\n# hand edit\n' >>"$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"
assert_contains "$OUT" "drift_artifact=yes" "a hand-edited artifact is reported as drift"
# A missing target must be a FAILURE, not no-news. The install-time pin is dropped for this read so
# the case tests the ARTIFACT’s target, not the installer’s own argument check.
D="$T/c9b"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
mv "$T/home/converger.py" "$T/home/converger.py.gone"
ENVV=(RUNNER_AUTOSCALE_SCRIPT=)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--status exits 1 when the artifact's target is gone"
assert_contains "$OUT" "script_present=no" "it says the target is gone"
mv "$T/home/converger.py.gone" "$T/home/converger.py"   # restore for the cases below

# ── T10: --uninstall verifies the files are gone ──────────────────────────────────────────
say_case "T10 --uninstall verifies removal and refuses when the files survive"
D="$T/c10"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --uninstall)"
assert_eq "$?" 0 "--uninstall exits 0"
assert_nofile "$D/$UNIT_NAME.service" "the service file is gone"
assert_nofile "$D/$UNIT_NAME.timer" "the timer file is gone"
assert_contains "$(cat "$T/systemctl.log")" "disable --now $UNIT_NAME.timer" \
    "the timer was disabled before removal (a live timer must not outlive its files)"
if [ "$(id -u)" = "0" ]; then
    echo "  ↷ skipping the unremovable-dir case: running as root, a mode-500 dir is still writable"
else
    RO="$T/c10ro"; fresh "$RO"
    run_install Linux "$RO" --install >/dev/null 2>&1
    chmod 500 "$RO"
    OUT="$(run_install Linux "$RO" --uninstall)"; RC=$?
    chmod 700 "$RO"
    assert_eq "$RC" 1 "--uninstall refuses when the files could NOT be removed"
    assert_contains "$OUT" "cannot remove the unit files" "the refusal says the removal failed, naming the dir"
fi

# ── T12: the Darwin artifact ─────────────────────────────────────────────────────────────
say_case "T12 the Darwin artifact renders, parses, and points at real files"
D="$T/c12"; fresh "$D"; rm -f "$ARM"
OUT="$(run_install Darwin "$D" --install)"
assert_eq "$?" 0 "the launchd install exits 0"
assert_file "$D/$LABEL.plist" "the plist was written to the LaunchAgents dir"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$D/$LABEL.plist" 2>/dev/null; then
        ok "the installed plist is well-formed XML"
    else
        bad "the installed plist is NOT well-formed XML (launchd would refuse it)"
    fi
    ARGS="$(plist_args "$D/$LABEL.plist")"
    assert_contains "$ARGS" "$T/home/converger.py" "ProgramArguments names the converger that was installed"
    assert_contains "$ARGS" "--dry-run" "the disarmed plist carries --dry-run"
    assert_eq "$(python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1],"rb"))
print(d["StartInterval"], d["Label"], d["RunAtLoad"], d["Nice"], d["ProcessType"])' "$D/$LABEL.plist" 2>/dev/null)" \
        "540 $LABEL True 10 Background" "the plist carries the cadence, label, load-at-login, niceness and type"
    # The systemd timer must state the same cadence, or the two boxes drift apart silently.
    assert_contains "$(cat "$REPO/templates/systemd/$UNIT_NAME.timer")" "OnUnitActiveSec=9min" \
        "the systemd timer's interval is the plist's (9 min = 540 s)"
    # ⛔ ARMED OMITS THE MODE ELEMENT ENTIRELY: an empty <string> would be a POSITIONAL argument.
    printf 'armed-by=someone\narmed-date=2026-10-29T00:00:00Z\n' >"$ARM"
    OUT="$(run_install Darwin "$D" --install)"
    assert_eq "$?" 0 "the armed launchd install exits 0"
    ARGS="$(plist_args "$D/$LABEL.plist")"
    assert_absent "$ARGS" "--dry-run" "the armed plist carries no --dry-run"
    assert_absent "$ARGS" "--apply" "the armed plist carries no --apply either (no such verb)"
    assert_eq "$(printf '%s\n' "$ARGS" | tail -1)" "o/r" \
        "the armed plist ENDS at the repo value: no empty positional argument"
    rm -f "$ARM"
else
    echo "  ↷ skipping the plist content checks: no python3 on this box"
fi
assert_contains "$(cat "$T/launchctl.log")" "bootstrap" "the job was bootstrapped with launchctl"

# ── T13: idempotence ─────────────────────────────────────────────────────────────────────
say_case "T13 a second install of an unchanged tree changes nothing"
D="$T/c13"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
BEFORE="$(cat "$D/$UNIT_NAME.service")"
OUT="$(run_install Linux "$D" --install)"
assert_contains "$OUT" "changed=0" "the second install reports changed=0"
assert_eq "$BEFORE" "$(cat "$D/$UNIT_NAME.service")" "the artifact bytes are unchanged"

# ── T14: the real converger is installable ───────────────────────────────────────────────
say_case "T14 the repo's own converger is what an unpinned install resolves"
assert_file "$REPO/scripts/orchestrator-harness/runner_autoscale.py" \
    "the converger the templates document exists in this tree"
D="$T/c14"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_SCRIPT=)
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "an install with no RUNNER_AUTOSCALE_SCRIPT override resolves the repo's converger"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "runner_autoscale.py" \
    "the ExecStart names runner_autoscale.py"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "$GOOD_PY" \
    "the ExecStart names the resolved interpreter, absolutely"

# ── T15: a DISARM PREVIEW changes nothing ────────────────────────────────────────────────
# Measured defect this pins: --disarm --dry-run removed the record and THEN returned at the dry-run
# check, so the operator was told DISARMED while the artifact still converged and the audit datum was
# destroyed. The record must survive a preview, and the artifact must be untouched.
say_case "T15 --disarm --dry-run keeps the record and the artifact ARMED"
D="$T/c15"; fresh "$D"
printf 'armed-by=someone\narmed-date=2026-10-29T00:00:00Z\nreason=fixture\n' >"$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
BEFORE="$(cat "$D/$UNIT_NAME.service")"
OUT="$(run_install Linux "$D" --disarm --dry-run)"; RC=$?
assert_eq "$RC" 0 "the preview exits 0"
assert_contains "$OUT" "WOULD disarm" "the preview says what it WOULD do"
assert_file "$ARM" "the arming record SURVIVES a preview"
assert_eq "$BEFORE" "$(cat "$D/$UNIT_NAME.service")" "the artifact is byte-identical after a preview"
# and a REAL disarm does the opposite, in the right order
OUT="$(run_install Linux "$D" --disarm)"; RC=$?
assert_eq "$RC" 0 "a real disarm exits 0"
assert_nofile "$ARM" "the record is gone after a real disarm"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "the re-rendered artifact is provably DISARMED (--dry-run present), not merely missing a word"

# ── T16: a FAILED armed render leaves the box NOT armed ───────────────────────────────────
# A record that outlives a failed --arm is an armed box the operator was told was not armed: the next
# routine --install would silently re-arm from it. The record must be dropped, fail-closed.
# ⚠️ CORRECTED (review finding P1): this case used to assert the record was KEPT, on the rationale that
# "an armed artifact with no record is the state the design forbids" — but there IS NO artifact in this
# fixture, so nothing was converging and the record existed only to arm the box on the next --install.
# The assertion contradicted this case's own header, which already said "the record must be dropped,
# fail-closed". The guard is precise now: the record survives only when an ARMED artifact backs it
# (T42 covers that arm; before the fix, that state was reachable from BOTH branches).
say_case "T16 a failed armed re-render never leaves an armed artifact without a record"
mkdir -p "$T/tpl16"
cp "$REPO/templates/systemd/$UNIT_NAME.timer" "$T/tpl16/"
sed 's|{{PYTHON}}|{{UNRESOLVED_16}}|; s|{{SCRIPT}}|{{ALSO_16}}|' \
    "$REPO/templates/systemd/$UNIT_NAME.service" >"$T/tpl16/$UNIT_NAME.service"
D="$T/c16"; fresh "$D"
rm -f "$ARM"
ENVV=(TEMPLATES_DIR="$T/tpl16")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a failed armed render exits 1"
assert_contains "$OUT" "NOT ARMED" "with no armed artifact to back it, the verb says NOT ARMED"
assert_nofile "$ARM" "and the record is DROPPED, so the next routine --install cannot arm from it"
# The complementary path (armed render fails while the DISARMED render succeeds) is not constructed
# here on purpose: both renders share one template set, so a fixture that breaks one breaks the other.
# An assertion that cannot fail the way it claims is worse than none - this suite shipped one (the
# "no armed flag" line T15 used to carry). T4, T15, T16 and T42 cover the four reachable states.

# ── T17: '%' is a systemd specifier, never a launchd one ──────────────────────────────────
say_case "T17 '%' is refused on the systemd arm and allowed on the launchd arm"
PC="$T/home/pc%h"; mkdir -p "$PC"; cp "$T/home/converger.py" "$PC/"
rm -f "$ARM"                       # no state carried over from T16: this case renders DISARMED
ENVV=(HOME="$PC" RUNNER_AUTOSCALE_SCRIPT="$PC/converger.py")
D="$T/c17"; fresh "$D"
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 1 "a '%' path is REFUSED on the systemd arm (systemd expands it at load time)"
assert_contains "$OUT" "specifier" "the refusal names the specifier expansion"
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed with a path systemd would rewrite"
OUT="$(run_install Darwin "$T/c17d" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "the same '%' path is ACCEPTED on the launchd arm (a plist string is not expanded)"

# ── T18: --status notices a MISSING INTERPRETER ──────────────────────────────────────────
say_case "T18 --status reports a missing interpreter, not a healthy schedule"
D="$T/c18"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
box_sed_i 's|^ExecStart="[^"]*"|ExecStart="/nonexistent/python9.99"|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status exits 1 when the artifact's interpreter is gone (203/EXEC every tick)"
assert_contains "$OUT" "python_present=no" "it reports the interpreter it could not find"
assert_contains "$OUT" "installed=yes" "while still reporting the artifact as installed (the two are different questions)"

# ── T19: --status notices an UNRECOGNISED mode argument ──────────────────────────────────
# The verb used to grep for the literal --dry-run, so an artifact carrying --apply (the exact pi-cell-1
# artifact that made every tick exit 2) was reported `mode=converge (ARMED)` and exit 0. A readiness
# gate keying on this exit code called a schedule that fails every tick healthy.
say_case "T19 --status reports an unrecognised mode argument (the inert-artifact class)"
D="$T/c19"; fresh "$D"
rm -f "$ARM"                                       # a record would render ARMED, with no flag to find
run_install Linux "$D" --install >/dev/null 2>&1
box_sed_i '/^ExecStart=/ s|$| --apply|' "$D/$UNIT_NAME.service"   # the measured pi-cell-1 defect
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status exits 1 for an artifact the converger would reject on every tick"
assert_contains "$OUT" "--apply" "it names the argument it found"
assert_contains "$OUT" "exit 2" "and the consequence"

# ── T20: EVERY writer refuses a sudo-invoked root run ────────────────────────────────────
# The guard lived only in --install, so `sudo … --arm` wrote a record in /root and installed an ARMEd
# User=root unit over the correct one, and `sudo … --disarm` reported DISARMED while removing root's
# record and leaving the user's intact.
say_case "T20 every writer (--install, --arm, --disarm, --uninstall) is refused under sudo"
printf '#!/usr/bin/env bash\ncase "$1" in -u) echo 0 ;; -un) echo root ;; *) echo root ;; esac\n' >"$T/bin/id"
chmod +x "$T/bin/id"
D="$T/c20"; fresh "$D"
for verb in --install --arm --disarm --uninstall; do
    rm -f "$ARM"
    ENVV=(PATH="$T/bin:$PATH" SUDO_USER=cmux)
    OUT="$(run_install Linux "$D" "$verb" --reason fixture)"; RC=$?; ENVV=()
    assert_eq "$RC" 1 "$verb is refused when invoked through sudo"
    assert_contains "$OUT" "REFUSING to run as root" "$verb says why"
    assert_nofile "$ARM" "$verb writes NO arming record under a refused root run"
done
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed as root"

# ── T21: a RELATIVE interpreter pin is refused ───────────────────────────────────────────
# A scheduler resolves a relative command against ITS working directory, not the installer's, so
# `./venv/bin/python` renders a unit that 203/EXECs on every tick while list-timers shows it scheduled.
say_case "T21 a relative interpreter pin is refused (the scheduler does not share our cwd)"
cp "$GOOD_PY" "$T/bin/relpy"; chmod +x "$T/bin/relpy"
D="$T/c21"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_PYTHON="./relpy" PATH="$T/bin:$PATH")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a relative pin is REFUSED"
# Which line refuses is deliberately not pinned: a relative pin fails the version probe first (the probe
# runs it from THIS script dir, where it is not present) and the absolute-path rule in
# refuse_unusable_target is the backstop behind it. Both are refusals, and the property that matters is
# that no artifact is written.
assert_contains "$OUT" "REFUSING" "the refusal is named"
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed with a relative interpreter"

# ── T22: --report-only cannot ride along with a WRITER ──────────────────────────────────
# Measured lies this pins: `--arm --report-only` minted a dated record, rendered the FORCED disarmed
# artifact, verified it as the forced mode, and printed ARMED over a --dry-run unit — after which the
# next routine --install armed from that record on the strength of an output that said it already had.
# `--uninstall --report-only` performed a REAL removal under a preview flag.
say_case "T22 --report-only is refused with --arm, --disarm and --uninstall"
D="$T/c22"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
for verb in --arm --disarm --uninstall; do
    rm -f "$ARM"
    ENVV=()
    OUT="$(run_install Linux "$D" "$verb" --report-only --reason fixture)"; RC=$?; ENVV=()
    assert_eq "$RC" 1 "$verb --report-only is refused"
    assert_contains "$OUT" "render flag for --install only" "$verb says why"
    assert_nofile "$ARM" "$verb --report-only writes no arming record"
    assert_file "$D/$UNIT_NAME.service" "$verb --report-only removed nothing"
done
# and the flag still works where it belongs
OUT="$(run_install Linux "$D" --install --report-only)"; RC=$?
assert_eq "$RC" 0 "--install --report-only still renders the disarmed artifact"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" "and the artifact it wrote really is disarmed"

# ── T23: --uninstall leaves the arming record, and SAYS the next --install will re-arm ──
# Measured: --arm then --uninstall then --install re-rendered the box ARMED from the pre-uninstall
# record while the remedy text handed to the operator promised a DISARMED install.
say_case "T23 --uninstall reports a surviving arming record instead of implying a clean slate"
D="$T/c23"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1
assert_file "$ARM" "precondition: the box is armed"
OUT="$(run_install Linux "$D" --uninstall)"; RC=$?
assert_eq "$RC" 0 "--uninstall still succeeds"
assert_file "$ARM" "the record survives (it is a dated decision, not ours to revoke)"
assert_contains "$OUT" "SURVIVES this uninstall" "and the verb says so"
assert_contains "$OUT" "NEXT --install will render an ARMED unit" "naming the consequence"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status on a box with no artifact exits 1"
assert_contains "$OUT" "when no arming record exists" "the --install remedy no longer promises DISARMED unconditionally"

# ── T24: an ExecStart= DROP-IN makes the base file's mode a lie ──────────────────────────
# systemd merges $UNIT.d/*.conf and a drop-in ExecStart= REPLACES the base one, so every read-back
# answered DISARMED about a unit that in fact converges.
say_case "T24 an ExecStart= drop-in is reported, not mistaken for the unit's command"
D="$T/c24"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
mkdir -p "$D/$UNIT_NAME.service.d"
cat > "$D/$UNIT_NAME.service.d/zz-override.conf" <<CONF
[Service]
ExecStart=
ExecStart=/usr/bin/true --dry-run
CONF
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status exits 1 when a drop-in overrides ExecStart"
assert_contains "$OUT" "dropin_override=" "it names the drop-in"
assert_contains "$OUT" "zz-override.conf" "by path"
rm -f "$ARM"                                        # the record is $T-wide; T23 left one armed
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?
assert_eq "$RC" 1 "--arm REFUSES to arm a unit whose command it cannot verify"
assert_contains "$OUT" "DROP-IN" "saying why"
assert_contains "$OUT" "Nothing was armed" "and that the refusal came BEFORE the record existed"
assert_nofile "$ARM" "and writes no record"
# a drop-in with no ExecStart= is not an override and must not red
rm -f "$D/$UNIT_NAME.service.d/zz-override.conf"
printf '[Service]\nNice=5\n' > "$D/$UNIT_NAME.service.d/harmless.conf"
# ⛔ THE RECORD MUST EXIST FOR THIS CASE TO MEASURE THE DROP-IN. The `--arm` above refused, so it wrote
# no record, while the artifact is still the ARMED render from T23's install — and an ARMED artifact
# with NO record is now refused in its own right (the artifact/record agreement gate), so this case
# would red for a reason that has nothing to do with the harmless drop-in. Re-arm first: `--arm`
# re-renders the artifact and signs the record, leaving the drop-in as the ONLY variable.
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "a drop-in that does not assign ExecStart= is not an override"

# T24b: a BARE `ExecStart=` is the RESET directive, not a comment — it CLEARS the exec list and
# systemd then refuses the unit ("Service has no ExecStart= … Refusing") while the base file still
# states one. Presence-detection on the VALUE missed it, so --install enabled and --arm signed a
# record for a unit that cannot start.
say_case "T24b a bare ExecStart= drop-in (the RESET directive) is an override"
D="$T/c24b"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
mkdir -p "$D/$UNIT_NAME.service.d"
printf '[Service]\nExecStart=\n' > "$D/$UNIT_NAME.service.d/zz-reset.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status exits 1 for a drop-in that CLEARS the exec list"
assert_contains "$OUT" "dropin_override=" "it names the drop-in"
rm -f "$ARM"
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?
assert_eq "$RC" 1 "--arm refuses it too"
assert_nofile "$ARM" "and signs no dated record for a unit systemd would refuse to start"

# ── T25: --status accepts the pass's real switch vocabulary ──────────────────────────────
# The recogniser red anything that was not exactly --dry-run, so `--want 3` (which runner_autoscale.py
# accepts) was reported as a schedule that exits 2 on every tick.
say_case "T25 --status accepts --want/--json/--root/--status, and still reds an invented flag"
D="$T/c25"; fresh "$D"
rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
box_sed_i '/^ExecStart=/ s|$| --want 3 --json|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "a real switch is not reported as a broken schedule"
assert_contains "$OUT" "mode=--dry-run (DISARMED" "and the mode is still read correctly"
assert_not_contains "$OUT" "did not render" "no invented-argument complaint"
box_sed_i '/^ExecStart=/ s| --want 3 --json||' "$D/$UNIT_NAME.service"
box_sed_i '/^ExecStart=/ s|$| --apply|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an invented flag is still red"
assert_contains "$OUT" "did not render" "and is named as such"

# ── T26: a real switch's ABSOLUTE value is a value, not a token to discard ──────────────
# The remainder was built by dropping any token starting with `/` (how the interpreter and script were
# skipped). `--root`'s value is normally an absolute path, so the value was deleted, the orphaned
# `--root` then swallowed the NEXT argument, and the mode came out ARMED for a unit that is disarmed —
# or green for a unit carrying `--apply`.
say_case "T26 an absolute --root value does not swallow the next argument"
D="$T/c26"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1        # armed = no mode argument
box_sed_i '/^ExecStart=/ s|$| --root /opt --apply|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--root /opt --apply is reported as broken (the pass exits 2 on --apply)"
assert_contains "$OUT" "--apply" "and the invented flag is the one named"
box_sed_i '/^ExecStart=/ s| --root /opt --apply||' "$D/$UNIT_NAME.service"
box_sed_i '/^ExecStart=/ s|$| --root /opt/x --dry-run|' "$D/$UNIT_NAME.service"
# ⛔ THE EDIT ABOVE MAKES THE ARTIFACT DISARMED WHILE THE RECORD FROM `--arm` IS STILL VALID, which is
# now refused in its own right (the artifact/record agreement gate) — so the record is revoked here or
# this case measures the disagreement instead of the absolute `--root` value it names. DISARMED with no
# record is the coherent state a `--disarm` leaves, and it is what the rest of T26 varies.
rm -f "$ARM"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "a disarmed unit with an absolute --root is not a broken schedule"
assert_contains "$OUT" "DISARMED" "and its mode is read correctly (not ARMED)"
box_sed_i '/^ExecStart=/ s| --root /opt/x --dry-run||' "$D/$UNIT_NAME.service"
box_sed_i '/^ExecStart=/ s|$| --dry-run --want|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a value-taking switch with NO value is refused (--want alone exits 2)"
assert_contains "$OUT" "--want" "naming the dangling switch"
# a value-taking switch followed by ANOTHER FLAG is a missing value too (argparse: "expected one
# argument"), and swallowing the flag as the value reported ARMED exit 0 for a schedule that fails
# every tick.
for pair in "--want --json" "--root --dry-run"; do
    box_sed_i '/^ExecStart=/ s| --dry-run --want||' "$D/$UNIT_NAME.service"
    box_sed_i '/^ExecStart=/ s|$| '"$pair"'|' "$D/$UNIT_NAME.service"
    OUT="$(run_install Linux "$D" --status)"; RC=$?
    assert_eq "$RC" 1 "'$pair' is refused (the flag after it is not its value)"
    assert_contains "$OUT" "${pair%% *}" "naming the dangling switch"
    box_sed_i "/^ExecStart=/ s| $pair||" "$D/$UNIT_NAME.service"
done

# ── T27: the script is TOKEN 2, not "the argument ending in .py" ─────────────────────────
# `resolve_script` accepts any executable regular file, so a wrapper or a console-script without the
# suffix installs fine. The status reader then matched nothing, discarded EVERY argument, and reported
# `mode=converge (ARMED)` over a DISARMED artifact while exiting 1 — the one question --status exists
# to answer, answered wrong, plus a false block on a working schedule.
say_case "T27 a converger without a .py suffix is still read positionally"
D="$T/c27"; fresh "$D"; rm -f "$ARM"
cp "$T/home/converger.py" "$T/home/runner-autoscale"
chmod +x "$T/home/runner-autoscale"
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/runner-autoscale")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "a suffix-free converger installs"
assert_contains "$OUT" "DISARMED" "and the artifact is disarmed"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "--status on that artifact is green"
assert_contains "$OUT" "DISARMED" "and reads the mode correctly"
assert_contains "$OUT" "script_present=yes" "and finds the script it installed"

# ── T28: a FAILED launchd removal is not reported as uninstalled ────────────────────────
# The only check was "is the label loaded", and a failed `launchctl list` reads the same as "not
# loaded", so a plist that survived in LaunchAgents was reported removed — and launchd loads it again
# at the next login, resuming an ARMED pass.
say_case "T28 --uninstall refuses when the launchd plist survives the removal"
D="$T/c28"; fresh "$D"
run_install Darwin "$D" --install >/dev/null 2>&1
assert_file "$D/$LABEL.plist" "precondition: the Darwin artifact is installed"
chmod 500 "$D"                                   # the removal cannot write to the directory
OUT="$(run_install Darwin "$D" --uninstall)"; RC=$?
chmod 700 "$D"
assert_eq "$RC" 1 "--uninstall exits 1 when the plist cannot be removed"
assert_contains "$OUT" "STILL PRESENT" "saying the artifact survived"

# ── T29: `--status` GATES on `enabled`, not just prints it ──────────────────────────────
# The install path refuses a not-enabled timer ("the converger will not run unattended"); the STATUS
# path only printed `enabled=…`. A timer that is active now but not enabled does not come back at the
# next boot, so the readiness verb an operator (and the health sweep) calls LATER certified a box whose
# converger stops at the first restart — the lenient of two readers of one fact.
say_case "T29 --status refuses a timer that is active but NOT enabled"
D="$T/c29"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
ENVV=(SHIM_ENABLED=disabled)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a disabled timer is NOT a green schedule"
assert_contains "$OUT" "enabled=disabled" "the row still states the raw value (the gate is not a lie about it)"
assert_contains "$OUT" "will not survive a reboot" "naming the consequence, not just the value"
ENVV=(SHIM_ENABLED=static)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "'static' fails too — no [Install] section means nothing links it into timers.target"
OUT="$(run_install Linux "$D" --status)"; RC=$?          # control: SHIM_ENABLED defaults to enabled
assert_eq "$RC" 0 "control: an ENABLED timer on the same artifact is still green (the gate is discriminating)"

# ── T30/T32: the USER target — lingering is re-checked, and drift compares the right file ─
# Reaching TARGET=user needs the user-manager probe to answer (`SYSTEMCTL --user show-environment`) and
# the sudo probes to decline — `SUDO=false` is the installer's documented seam for "skip the sudo probe",
# and setting it (not leaving it unset) is what makes the probe decline rather than pass straight to the
# SYSTEM target. Both the probe and lingering now go through the pinned seams, so `PATH` is no longer
# what decides which binary answers (the shims stay on it for the verbs that are spelled by name).
# ── T30: a user timer without lingering stops converging at logout ──────────────────────
say_case "T30 --status re-checks lingering on a USER timer (the install path is not the last word)"
rm -rf "$T/home/.config"; rm -f "$ARM"
# ⛔ NO `PATH` OVERRIDE, DELIBERATELY. The probe and the lingering calls both go through the pinned
# seams now, so the seam is the ONLY route to the shim. With `$T/bin` on PATH a reverted bare
# `loginctl`/`systemctl` resolves to the SAME shim and answers the SAME — measured: reverting the linger
# seam left this suite at `PASS=322 FAIL=0`, so the install half of that fix was unprovable here.
: >"$T/loginctl.log"
ENVV=(SUDO=false)
OUT="$(run_install Linux - --install)"; RC=$?
assert_eq "$RC" 0 "precondition: a lingering user install succeeds"
assert_contains "$OUT" "target=user" "precondition: the target really is USER (the seam works)"
assert_contains "$(cat "$T/loginctl.log")" "show-user" "the install path read lingering through the LOGINCTL seam, not the bare binary"
envv_status_user() { ENVV=(SUDO=false PATH="$T/bin:$PATH" SHIM_LINGER="$1"); }
envv_status_user no
OUT="$(run_install Linux - --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a user timer with linger=no is NOT green — it dies with the session"
assert_contains "$OUT" "linger=no" "the row names the value it gated on"
assert_contains "$OUT" "after this session ends" "naming the consequence"
envv_status_user yes
OUT="$(run_install Linux - --status)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "control: linger=yes is green (the gate is discriminating)"
# ── T32: drift must compare the artifact the install path would actually write ──────────
# The install path DROPS `User=` for a user target (systemd rejects it there); the status render did
# not, so the two files could never match and a freshly installed, untouched artifact reported
# `drift_artifact=yes`. A signal that fires always is a signal nobody reads — and it was reported by
# the very --status the install hands the operator as its remedy.
say_case "T32 --status reports drift_artifact=no on an untouched USER-scope artifact"
envv_status_user yes
OUT="$(run_install Linux - --status)"; RC=$?; ENVV=()
assert_contains "$OUT" "target=user" "precondition: the status read the USER target, not the host's system one"
assert_eq "$RC" 0 "an untouched user artifact is healthy"
assert_contains "$OUT" "drift_artifact=no" "and is not reported as drifted against itself"
assert_file "$T/home/.config/systemd/user/$UNIT_NAME.service" "the user artifact is where --status looked for it"

# ── T51: the INSTALL path refuses a user timer it cannot make survive logout ─────────────
# The refusal is the reason the lingering block exists at all (`REFUSING to report this as installed: a
# USER timer cannot fire after your session ends`), and NOTHING exercised it: `SHIM_LINGER` was set only
# by `envv_status_user`, which only drives `--status`. So the writer's own gate — the one that stops the
# inert enforcer at CREATE time rather than a day later at read time — was asserted nowhere, and the
# `LOGINCTL` seam this case pins was therefore unprovable (reverting it kept the suite green).
say_case "T51 --install REFUSES a USER timer that cannot survive logout"
rm -rf "$T/home/.config"; rm -f "$ARM"; ENVV=(); : >"$T/loginctl.log"
ENVV=(SUDO=false SHIM_LINGER=no)
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "an install whose linger cannot be enabled REFUSES rather than reporting success"
assert_contains "$OUT" "REFUSING to report this as installed" "naming the refusal in its own words"
assert_contains "$OUT" "without lingering" "and the fact that makes it inert"
assert_absent "$OUT" "linger: enabled" "it does not claim a linger it did not get"
LOG_TXT="$(cat "$T/loginctl.log" 2>/dev/null || true)"
assert_contains "$LOG_TXT" "show-user" "the linger read went through the LOGINCTL seam"
assert_contains "$LOG_TXT" "enable-linger" "and so did the enable attempt"
ENVV=(SUDO=false SHIM_LINGER=yes)
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "control: the same install with lingering available succeeds (the gate is discriminating)"
assert_contains "$OUT" "linger: enabled" "and says the timer will survive logout"

# ── T31: the launchd provisioner pin round-trips a shell-hostile path ───────────────────
# `provisioner_env_for launchd` sed-escaped its value AND `render` sed-escaped the composed
# `{{PROVISIONER_ENV}}` again, so the pin came out with literal backslashes (`…/inst\&x.sh`) — a path
# that does not exist. The plist still parsed, nothing compared the value, and the pass would have
# found no provisioner and exited 3 on every tick that should have added capacity.
say_case "T31 the launchd provisioner pin survives '&' and '<' and names a REAL path"
D="$T/c31"; fresh "$D"; rm -f "$ARM"
PROV="$T/inst&<x>.sh"; printf '#!/bin/sh\n' >"$PROV"; chmod +x "$PROV"
ENVV=(RUNNER_AUTOSCALE_PROVISIONER="$PROV")
run_install Darwin "$D" --install >/dev/null 2>&1; ENVV=()
assert_file "$D/$LABEL.plist" "precondition: the Darwin artifact is installed"
assert_eq "$(plist_env "$D/$LABEL.plist" RUNNER_AUTOSCALE_PROVISIONER)" "$PROV" "the pinned value IS the path (no doubled escape)"
assert_not_contains "$(plist_env "$D/$LABEL.plist" RUNNER_AUTOSCALE_PROVISIONER)" '\' "and carries no literal backslash"
assert_file "$(plist_env "$D/$LABEL.plist" RUNNER_AUTOSCALE_PROVISIONER)" "and that value resolves to a file that exists"
# Control: the systemd arm rendered the same path correctly all along — assert both arms agree, so a
# future divergence between them is a failure here rather than a bug found on a box.
D2="$T/c31b"; fresh "$D2"
ENVV=(RUNNER_AUTOSCALE_PROVISIONER="$PROV")
run_install Linux "$D2" --install >/dev/null 2>&1; ENVV=()
assert_contains "$(cat "$D2/$UNIT_NAME.service")" "RUNNER_AUTOSCALE_PROVISIONER=$PROV" "both arms pin the identical path"

# ── T33: exit 4 (STARVATION) is RED in --status, as the unit renders it ─────────────────
# The service template's exit table says "0 is the ONLY green … greening 4 would silently retire the
# alarm #2875 exists for", and the --status gate had `4` in its green set — so the readiness verb
# certified the one state the unit is best placed to catch. The message is its own arm, because "the
# pass completed and reported starvation" is a different fact from "the pass is not completing".
say_case "T33 --status treats the converger's exit 4 (STARVATION) as RED, on both platforms"
D="$T/c33"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
ENVV=(SHIM_LAST=4)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "systemd: last_run=4 is not a green tick"
assert_contains "$OUT" "STARVATION" "naming starvation, not 'not completing'"
ENVV=(SHIM_LAST=0)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "systemd control: last_run=0 is green"
D="$T/c33d"; fresh "$D"; run_install Darwin "$D" --install >/dev/null 2>&1
ENVV=(SHIM_LAST_EXIT=4)
OUT="$(run_install Darwin "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "launchd: last_exit=4 is not a green tick"
assert_contains "$OUT" "STARVATION" "launchd names starvation too"
ENVV=(SHIM_LAST_EXIT=0)
OUT="$(run_install Darwin "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "launchd control: last_exit=0 is green"

# ── T34: an interpreter that EXISTS but is too OLD is still not a usable schedule ────────
# The pass refuses itself below 3.12 (`raise SystemExit(2)`), and the install path refuses such an
# interpreter — but `--status` checked only presence and executability, so the readiness verb was green
# over a schedule that exits 2 on every tick. The realistic trigger is not exotic: the installer pins an
# ABSOLUTE path and the resolver's own candidate list includes a per-lane venv, so a venv recreated on an
# older interpreter is exactly how the version changes under a unit that never moved.
say_case "T34 --status reds an interpreter that is present but older than 3.12"
D="$T/c34"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the freshly installed artifact's interpreter is green"
printf '#!/usr/bin/env bash\ncase "$1" in -c) echo 3.11 ;; *) exit 0 ;; esac\n' >"$T/bin/oldpy"
chmod +x "$T/bin/oldpy"
box_sed_i "s|^ExecStart=\"[^\"]*\"|ExecStart=\"$T/bin/oldpy\"|" "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an old-but-present interpreter is NOT a green schedule"
assert_contains "$OUT" "python_present=yes" "it is present — that is the whole point"
assert_contains "$OUT" "python_usable=no" "and is reported unusable"
assert_contains "$OUT" "3.11" "naming the version it read"
assert_contains "$OUT" "TOO OLD" "naming the consequence, not just the version"

# ── T35: `--status` is the FIFTH reader, and it must carry the root guard too ────────────
# Under `sudo` HOME resolves to /root, so the ARMING RECORD and the pass's LAST-TICK log are read from
# /root's state dir while the ARTIFACT (absolute paths) is the user's — an armed and ticking box reported
# `mode=converge (ARMED)` beside `arm_record=absent (/root/…)` and `last_tick=none`. The guard's own
# message already names that consequence; the four writers called it and this verb did not.
say_case "T35 --status is refused under a sudo-invoked root run, like every writer"
assert_file "$T/bin/id" "precondition: T20's root-identity shim exists"
ENVV=(PATH="$T/bin:$PATH" SUDO_USER=cmux)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--status does not answer from /root's state dir"
assert_contains "$OUT" "REFUSING to run as root" "and says why, like the writers do"

# ── T36: a SECOND scope is a SECOND schedule — the writers must say so ───────────────────
# The mutual exclusion the service template relies on ("systemd will not start a second instance of an
# active oneshot") is PER-UNIT, not per-account: a user-scope copy plus a system-scope copy are two
# different units, so two passes race to restart and add the same runners. `--uninstall` has always
# scanned for that; the WRITERS did not, and the second install is reachable whenever sudo availability
# changes between invocations.
say_case "T36 --install and --arm report a unit pair already installed in ANOTHER scope"
mkdir -p "$T/scopes/other"; printf 'placeholder\n' >"$T/scopes/other/$UNIT_NAME.service"
envv_user_scope() { ENVV=(SUDO=false PATH="$T/bin:$PATH" RUNNER_AUTOSCALE_SCOPE_SCAN="$T/scopes/other"); }
rm -rf "$T/home/.config"; rm -f "$ARM"
ENVV=(SUDO=false PATH="$T/bin:$PATH")            # control: the pinned-empty $T/scopes reports nothing
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "control: no note when no other scope carries the unit"
assert_not_contains "$OUT" "ALSO installed in" "and the control is silent"
rm -rf "$T/home/.config"; rm -f "$ARM"
envv_user_scope
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "a second source of schedule is reported, not fatal"
assert_contains "$OUT" "ALSO installed in" "the note names the other scope"
assert_contains "$OUT" "another scope" "and says what it is"
assert_contains "$OUT" "$T/scopes/other" "naming the directory an operator has to look at"
# ⛔ `--arm` writes the other half of the same decision, so it is scanned too.
envv_user_scope
OUT="$(run_install Linux - --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "--arm succeeds (the note is not a refusal)"
assert_contains "$OUT" "ALSO installed in" "and --arm also reports the other scope"
rm -rf "$T/scopes/other"
rm -f "$ARM"

# ── T37: the drift comparison covers the artifact that carries the CADENCE ───────────────
# `--install` writes TWO systemd artifacts and `--status` compared ONE. The `.timer` is where
# `OnBootSec=`/`OnUnitActiveSec=` live, and `{{INTERVAL_SEC}}` is rendered into the PLIST only — the
# timer template is static text, so nothing else ever compares it. A hand-edited, foreign, or
# older-cadence timer therefore fired at the wrong interval while the verb whose own comment promises
# to catch "a changed interval" printed `drift_artifact=no` and exited 0: a box converging hourly
# instead of every nine minutes, certified healthy by the readiness gate. Same class as T32 — compare
# everything the install path would write.
say_case "T37 --status compares the TIMER too, not just the service"
D="$T/c37"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "precondition: a freshly installed box is healthy"
assert_contains "$OUT" "drift_artifact=no" "and reports no drift"
assert_contains "$OUT" "drift_parts=service=no timer=no" "naming BOTH artifacts it compared"
# A hand-edit of the TIMER alone — the cadence artifact, and the one the pre-fix code never opened.
printf '\n# hand edit\n' >>"$D/$UNIT_NAME.timer"
OUT="$(run_install Linux "$D" --status)"
assert_contains "$OUT" "drift_artifact=yes" "a hand-edited TIMER is reported as drift"
assert_contains "$OUT" "drift_parts=service=no timer=yes" "and the attribution names the TIMER, not the service"
# A timer that is GONE is drift too, and it is the one drift where nothing fires at all.
D="$T/c37b"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
rm -f "$D/$UNIT_NAME.timer"
OUT="$(run_install Linux "$D" --status)"
assert_contains "$OUT" "drift_artifact=yes" "a MISSING timer is drift, not silence"
assert_contains "$OUT" "drift_parts=service=no timer=yes" "and the attribution says which artifact is absent"
# ⛔ AND THE RENDER IS DRIVEN BY THE ARTIFACT'S OWN DECLARED VALUES, NOT BY THE READER'S ENVIRONMENT.
# Every substituted value (`{{PATH}}`, `{{PYTHON}}` found on it, `{{SCRIPT}}`, `{{PROVISIONER_ENV}}`
# resolved from `$PWD`, `{{REPO}}`, `{{HOME}}`, `{{STATE_DIR}}`) is an input of the invocation that
# RENDERED the artifact, so re-deriving them from the `--status` process reports the operator's shell as
# "drift". Measured: an untouched artifact read `drift_artifact=yes` from a login shell with a different
# PATH, or from any other directory (the provisioner resolves through `$PWD` alone on the boxes this
# exists for) — and the remedy it printed, `--install`, then rewrote the unit WITHOUT the pin, `changed=1`,
# exit 0, permanently removing the FILL half. So: the artifact's declared values drive the comparison, and
# any difference from what THIS invocation resolves is named in `drift_inputs=` instead.
PROV2="$T/home/prov2.sh"; printf '#!/bin/sh\n' >"$PROV2"; chmod +x "$PROV2"
D="$T/c37c"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_PROVISIONER="$PROV2")
run_install Linux "$D" --install >/dev/null 2>&1; ENVV=()
assert_contains "$(cat "$D/$UNIT_NAME.service")" "RUNNER_AUTOSCALE_PROVISIONER=$PROV2" \
    "precondition: the install baked the provisioner pin into the artifact"
ENVV=(RUNNER_AUTOSCALE_PROVISIONER="$PROV2")
OUT="$(run_install Linux "$D" --status)"; ENVV=()
assert_contains "$OUT" "drift_artifact=no" \
    "--status resolves the SAME provisioner, so a pinned artifact is not reported as permanent drift"
assert_contains "$OUT" "drift_parts=service=no timer=no" "…both artifacts match what this installer would write now"
assert_contains "$OUT" "provisioner=$PROV2" "and the readiness report names the pin the artifact carries"
assert_absent "$OUT" "drift_inputs=" "with nothing to report when the reader resolves the same values"
# The reader's environment differs (no pin resolvable from here): the artifact is NOT drifted, but the
# difference is NAMED — this is the control against "make drift unconditionally green".
OUT="$(run_install Linux "$D" --status)"
assert_contains "$OUT" "drift_artifact=no" "a reader that cannot resolve the pin does not turn the artifact into drift"
assert_contains "$OUT" "drift_inputs=provisioner" "…and the difference is named, not swallowed"
assert_contains "$OUT" "provisioner=absent" "the resolution failure has its own reason line"
# ⛔ AND THE RE-INSTALL MUST NOT STRIP IT — the destructive half of the same defect. The remedy
# `--status` hands out is `--install`, and on the boxes this exists for the provisioner resolves through
# `$PWD` alone, so a re-install from any other directory dropped the pin, reported `changed=1` and exit 0.
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 0 "a re-install that cannot resolve a provisioner still succeeds"
assert_contains "$(cat "$D/$UNIT_NAME.service")" "RUNNER_AUTOSCALE_PROVISIONER=$PROV2" \
    "and KEEPS the pin the artifact already carried (no silent loss of the FILL half)"
# A pin that is gone from disk is NOT carried forward — that would bake in a path that cannot run.
rm -f "$PROV2"
run_install Linux "$D" --install >/dev/null 2>&1
assert_absent "$(cat "$D/$UNIT_NAME.service")" "RUNNER_AUTOSCALE_PROVISIONER=" \
    "a pin whose file no longer exists is NOT carried forward (it cannot run)"
rm -f "$ARM"

# ── T39: the timer's cadence has a DROP-IN route that drift cannot see ─────────────────
# The drift `cmp` reads the BASE artifact, so a `$UNIT_NAME.timer.d/*.conf` carrying
# `OnUnitActiveSec=1h` makes the pass fire hourly while the base file stays byte-identical to what
# this installer would write — `drift_artifact=no`, `drift_parts=… timer=no`, exit 0. The service side
# has had this arm all along (T24); the cadence side did not, so the false PASS T37 closes on the base
# file simply moved one directory over.
say_case "T39 a [Timer] drop-in is an override, and a harmless one is not"
D="$T/c39"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
# Control first: a timer drop-in that changes NO cadence must not red the verb (a false block).
mkdir -p "$D/$UNIT_NAME.timer.d"
printf '[Unit]\nDescription=a harmless annotation\n' >"$D/$UNIT_NAME.timer.d/note.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "a timer drop-in that sets no cadence key is NOT a failure (no false block)"
assert_absent "$OUT" "timer_dropin=" "and it is not reported as an override"
# Now the real thing: the cadence itself, exactly as an operator would retune it by hand.
printf '[Timer]\nOnUnitActiveSec=1h\n' >"$D/$UNIT_NAME.timer.d/cadence.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a [Timer] drop-in that changes the cadence exits 1"
assert_contains "$OUT" "timer_dropin=$D/$UNIT_NAME.timer.d/cadence.conf" "naming the drop-in systemd actually reads"
assert_contains "$OUT" "CADENCE" "and naming the fact it overrides"
assert_contains "$OUT" "drift_artifact=no" "the base artifact is untouched — the drop-in is the whole defect"
# ⛔ EVERY `On*` ELAPSE KEY, NOT THE THREE THE BASE TEMPLATE HAPPENS TO USE. systemd fires at every elapse
# point it finds and a drop-in assignment ADDS one, so keying on the base template's own names let
# `OnActiveSec=1min` fire the pass every minute and still report a clean box.
printf '[Timer]\nOnActiveSec=1min\n' >"$D/$UNIT_NAME.timer.d/cadence.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an extra elapse key (OnActiveSec=) added beside the template's own is caught too"
assert_contains "$OUT" "timer_dropin=" "and named"
# ⛔ AND `Persistent=` IS NOT A FALSE BLOCK: it applies to `OnCalendar=` only, and this unit deliberately
# carries none — so a `Persistent=` drop-in changes nothing about when the pass fires.
printf '[Timer]\nPersistent=true\n' >"$D/$UNIT_NAME.timer.d/cadence.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "a Persistent= drop-in is NOT a failure (it changes nothing on an OnUnitActiveSec timer)"
assert_absent "$OUT" "timer_dropin=" "and is not reported as a cadence override"
# ⛔ THE GUARD MUST BE REACHABLE WHERE THE SCHEDULE IS CREATED, NOT ONLY WHERE IT IS READ. `--install` and
# `--arm` refused a service drop-in from the start; a timer drop-in let them print `cadence=9min` and sign
# a dated record for a box that fires hourly.
printf '[Timer]\nOnUnitActiveSec=1h\n' >"$D/$UNIT_NAME.timer.d/cadence.conf"
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 1 "--install REFUSES rather than install/verify a unit pair whose cadence a drop-in overrides"
assert_contains "$OUT" "REFUSING" "and says so"
rm -f "$ARM"
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?
assert_eq "$RC" 1 "--arm refuses BEFORE the dated record exists"
assert_nofile "$ARM" "no arming record was written"
rm -f "$ARM"

# ── T38: --status scans the OTHER scope, and scopes the claim it makes ───────────────────
# `choose_target` resolves the scope from SUDO AVAILABILITY AT THIS INVOCATION. A box installed into
# /etc/systemd/system by the bring-up therefore answers a later `--status` run — where `sudo -n` fails —
# from the USER scope, and printed `installed=no` plus "this box has NO scheduled converger" over a box
# that IS converging, then handed the operator `--install`: the one action that creates the duplicate
# schedule T36 exists to report. The three writers always scanned; the readiness verb did not, and it is
# the verb an operator runs first.
say_case "T38 --status scans the second scope and scopes its own claim"
mkdir -p "$T/scopes/status-other"
printf 'placeholder\n' >"$T/scopes/status-other/$UNIT_NAME.service"
rm -rf "$T/home/.config"; rm -f "$ARM"
ENVV=(SUDO=false PATH="$T/bin:$PATH")          # control: the pinned-empty $T/scopes reports nothing
OUT="$(run_install Linux - --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "control: nothing installed anywhere in the scan exits 1"
assert_not_contains "$OUT" "ALSO installed in" "and the control is silent about other scopes"
assert_contains "$OUT" "no scheduled converger in THIS scope" "the note is SCOPED to what was actually read"
assert_absent "$OUT" "NO scheduled converger" "so the unscoped box-level claim is gone"
rm -rf "$T/home/.config"; rm -f "$ARM"
ENVV=(SUDO=false PATH="$T/bin:$PATH" RUNNER_AUTOSCALE_SCOPE_SCAN="$T/scopes/status-other")
OUT="$(run_install Linux - --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--status still exits 1 (there is nothing in THIS scope)"
assert_contains "$OUT" "ALSO installed in" "a converging box in ANOTHER scope is REPORTED, not denied"
assert_contains "$OUT" "$T/scopes/status-other" "naming the directory an operator has to look at"
assert_contains "$OUT" "no scheduled converger in THIS scope" "and the claim stays scoped to this one"
assert_absent "$OUT" "this box has NO scheduled converger" "the false box-level claim is gone"
rm -rf "$T/scopes/status-other"
rm -rf "$T/home/.config"; rm -f "$ARM"

# ── T40: a SECOND ExecStart= in the BASE file — Type=oneshot runs every one of them ──────
# The read-back took `tail -1`, described as "the one systemd runs". That is true of the default
# `Type=simple` and FALSE of the `Type=oneshot` this template renders, where systemd.service(5) permits
# several ExecStart= and runs them IN SEQUENCE. So a hand-edited base file read as ARMED from the last
# line while the FIRST command was a foreign binary — `drift_artifact=yes` is advisory (rc unchanged), so
# `--status` certified it green. The drop-in arm cannot see this: the multiplicity is in the base file.
say_case "T40 a second ExecStart= in the base unit is not a schedule --status certifies"
D="$T/c40"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the freshly installed unit carries exactly one ExecStart= and is green"
assert_absent "$OUT" "exec_start_count=" "and the count line is not printed when there is nothing to report"
# Append the second command a hand-edit would leave behind. `exec_start_count` reads the BASE file, so
# this must be reported even though the last line is still the managed command.
printf 'ExecStart="/usr/local/bin/old-converger"\n' >>"$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a base unit with TWO ExecStart= is NOT a green schedule"
assert_contains "$OUT" "exec_start_count=2" "naming how many commands systemd would actually run"
assert_contains "$OUT" "IN SEQUENCE" "and naming the consequence, not just the count"
# ⛔ AND THE ARM-TIME VERIFIER REFUSES IT TOO — reached the way it really happens. `--arm` re-renders the
# unit, so a hand-edit is normally CONVERGED AWAY (which is correct, and is why the naive case above
# cannot reach `verify_installed_unit`). The reachable route is the one `unit_exec_line`'s own comment
# names as MEASURED: `install(1)` can leave a pre-existing file in place on some failures while the
# installer still reports success. So the install step is stubbed to change nothing, the render succeeds,
# and the artifact the verifier reads is still the two-command one. Without the count guard the unit arms.
STUBI="$T/stub-c40"; mkdir -p "$STUBI"
# `override` copies with `cp -f`, `user`/`system` write with `install` — both are stubbed, because the
# hazard is that EITHER reports success over a file it did not replace.
printf '#!/bin/sh\nexit 0\n' >"$STUBI/install"; chmod +x "$STUBI/install"
printf '#!/bin/sh\nexit 0\n' >"$STUBI/cp"; chmod +x "$STUBI/cp"
rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
printf 'ExecStart="/usr/local/bin/old-converger"\n' >>"$D/$UNIT_NAME.service"
ENVV=(PATH="$STUBI:$PATH")     # the write step becomes a no-op that reports success
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?
ENVV=()
assert_eq "$RC" 1 "--arm REFUSES when the artifact it would attest carries more than one ExecStart="
# ⛔ ASSERT THE GUARD'S OWN TEXT, not the word REFUSING: a stub that breaks the render would also exit 1,
# and "it refused" would then be satisfied by a refusal of something else entirely.
assert_contains "$OUT" "IN SEQUENCE" "and the refusal names the oneshot multiplicity it found"
assert_nofile "$ARM" "with no arming record written"
rm -f "$ARM" "$STUBI/install" "$STUBI/cp"

# ── T41: this suite does not hand-roll `sed -i` — the macOS false-RED class ────────────
# On BSD sed the GNU spelling consumes the script as the backup suffix and edits NOTHING while reporting
# success, so every mutation in this file would be a silent no-op on the platform the Darwin arm exists
# to validate: the artifact stays healthy, `--status` correctly exits 0, and the case fails its own
# `assert_eq "$RC" 1`. `lib/box.sh` owns this hazard (box_sed_i) and `lib/box.test.sh`'s darwin arm pins
# it as live. This asserts the suite keeps using the shim rather than re-deriving the hazard.
say_case "T41 the suite mutates artifacts through box_sed_i, never a hand-rolled sed -i"
# Match only a real INVOCATION — `sed -i` at the start of a line after optional indentation. A prose
# mention (this case's own title, the comment above) is not a call, and a guard that counts those reds
# itself. Comments are excluded structurally rather than by a `#` test on the matched text.
bare="$(grep -nE '^[[:space:]]*sed[[:space:]]+-i' "$HERE/install-runner-autoscale-timer.test.sh" || true)"
assert_eq "$bare" "" "no bare sed -i invocation (it is silent on BSD and edits nothing)"
assert_eq "$(command -v box_sed_i >/dev/null 2>&1 && echo yes)" "yes" "and the shim is really loaded, so the guard is not vacuous"

# ── T42: an armed artifact DOES back a kept record — the other half of T16 ─────────────────
# T16 proves the record is dropped when nothing is converging. The rule is not "always drop it": a record
# may only be KEPT when an ARMED artifact backs it, because deleting it then would create the one state
# the design forbids (an armed artifact with no record). Before the guard, BOTH branches kept it.
say_case "T42 a kept arming record is backed by an actually-armed artifact"
D="$T/c42"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
# the artifact is DISARMED here, so the failed-arm path must DROP the record (the T16 arm, re-proved)
ENVV=(TEMPLATES_DIR="$T/tpl16")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a failed arm over a DISARMED artifact exits 1"
assert_nofile "$ARM" "and drops the record — nothing armed is converging"
# now make the artifact genuinely ARMED by hand, then fail the arm again
box_sed_i '/^ExecStart=/ s| --dry-run||' "$D/$UNIT_NAME.service"
ENVV=(TEMPLATES_DIR="$T/tpl16")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a failed arm over an ARMED artifact still exits 1"
assert_contains "$OUT" "STILL ARMED" "and says STILL ARMED, because something IS armed"
assert_file "$ARM" "keeping the record — an armed artifact with NO record is the state the design forbids"
rm -f "$ARM"

# ── T43: `--status` in ExecStart is a MEASURE mode, not a benign switch ──────────────────
# The classifier listed `--status` as a switch that "changes nothing about whether a tick CONVERGES".
# `runner_autoscale.py` builds the run as `dry_run=opts.status or opts.dry_run`, so it DOES: every tick
# measures and repairs nothing — the `--apply` class in a word the pass accepts, certified ARMED exit 0.
say_case "T43 an ExecStart carrying --status is not a green ARMED schedule"
D="$T/c43"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1     # armed = no mode argument
box_sed_i '/^ExecStart=/ s|$| --status|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status in ExecStart is red, not certified ARMED"
assert_contains "$OUT" "MEASURE ONLY" "naming what the tick actually does"
assert_contains "$OUT" "dry_run=opts.status" "and the pass's own expression, so the operator can check it"
assert_absent "$OUT" "mode=converge (ARMED" "the false ARMED verdict is gone"
rm -f "$ARM"

# ── T44: `--repo` is read back from the artifact's COMMAND LINE, not its environment ──────
# Both templates pass the repo as an argument, so `artifact_env_value RUNNER_AUTOSCALE_REPO` was always
# empty: `drift_inputs=repo` was dead code and an untouched artifact on a non-default pool reported
# `drift_artifact=yes` for ever.
say_case "T44 a non-default --repo is not permanent drift, and the difference is named"
D="$T/c44"; fresh "$D"; rm -f "$ARM"
ENVV=(RUNNER_AUTOSCALE_REPO="other/pool")
run_install Linux "$D" --install >/dev/null 2>&1
ENVV=()
assert_contains "$(cat "$D/$UNIT_NAME.service")" "--repo \"other/pool\"" "the artifact really converge another pool"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "the untouched artifact is not reported as drift"
assert_contains "$OUT" "drift_artifact=no" "explicitly not drift"
assert_contains "$OUT" "drift_inputs=repo" "and the reader/artifact difference is NAMED, not swallowed"

# ── T45: `OnCalendar=` is an elapse point too ─────────────────────────────────────────────
# `On[A-Za-z]*Sec` has no `Sec` in `OnCalendar`, so an added calendar fire left the base timer
# byte-identical and got certified clean — the T39 false PASS, one key over.
say_case "T45 an OnCalendar= drop-in is a cadence override, not a clean 9-minute box"
D="$T/c45"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
mkdir -p "$D/$UNIT_NAME.timer.d"
printf '[Timer]\nOnCalendar=hourly\n' >"$D/$UNIT_NAME.timer.d/calendar.conf"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a calendar fire added beside the template's own is caught"
assert_contains "$OUT" "timer_dropin=" "and named"
assert_contains "$OUT" "CADENCE" "as a cadence override"
rm -f "$D/$UNIT_NAME.timer.d/calendar.conf"

# ── T46: the unrecognised-argument message names the vocabulary the pass REALLY has ──────
# It listed five of nine switches and claimed every other argument exits 2. `--install-unit` does not:
# it writes and enables a competing unit pair and exits, which is a different consequence.
say_case "T46 a recognised non-converging action gets its own consequence, not 'exit 2'"
D="$T/c46"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
box_sed_i '/^ExecStart=/ s|$| --install-unit|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--install-unit in ExecStart is red"
assert_contains "$OUT" "WRITES AND ENABLES" "naming its real consequence (a competing unit pair)"
# ⛔ NO "EVERY TICK EXITS 2" TEXT AND NO VOCABULARY LIST HERE, DELIBERATELY. `--install-unit` is an
# argument the pass ACCEPTS, so the generic message is false about it — it is now printed only when an
# argument REMAINS that the pass does not accept at all, and the specific consequence above is the whole
# of what this operator needs. The vocabulary assertion moves to the control below, where the generic
# message really does print (an invented flag), so the claim is checked where it is true.
assert_absent "$OUT" "every tick exits 2" "…and the false 'exit 2 on every tick' text is not printed about it"
# ⛔ THE INLINE SPELLING IS THE SAME ARGUMENT. argparse accepts `--want=3` / `--root=<path>` / `--repo=<slug>`
# exactly as it accepts the space form, so a classifier that matched only the space form reported a
# schedule the pass runs happily as "arguments this installer did not render … every tick exits 2" — a
# false block, and one whose remedy (strip the argument) removes a legitimate switch. The space form and
# the inline form must read the same, and the gate must still discriminate the value that really fails.
# ⛔ THE VOCABULARY BELONGS ON THE MESSAGE THAT MAKES THE CLAIM. The generic "arguments this installer
# did not render … every tick exits 2" text is the one that enumerates the pass's switches, so it is
# asserted here — on an argument the pass really does not accept — and NOT on the `--install-unit` case
# above, where that text is deliberately suppressed because it would be false.
box_sed_i '/^ExecStart=/ s| --install-unit| --apply|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an invented flag is still refused"
assert_contains "$OUT" "did not render" "naming it as an argument the installer never rendered"
assert_contains "$OUT" "--check-units" "and the message lists the pass's full vocabulary"
# ⛔ THE INLINE SPELLING IS THE SAME ARGUMENT (restored — this control is what #2403's `--want=` fix
# turns on): `--want=3` must read exactly as `--want 3` does, and the chain below then empties its value.
box_sed_i '/^ExecStart=/ s| --apply| --want=3 --json|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "--want=<n> in the inline spelling is the SAME argument, so the unit is not red"
assert_absent "$OUT" "did not render" "…and it does not get the 'this installer did not render' text"
# Control 1: an EMPTY value is NOT the same argument — the pass exits 2 on `--want=`, so it stays red.
box_sed_i '/^ExecStart=/ s| --want=3 --json| --want=|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an EMPTY inline value is still a value the pass cannot take, so the gate reds it"
assert_contains "$OUT" "--want=" "and names the argument it refused"
# Control 2: `--repo=<slug>` is CONFIGURATION, not a mode — the space pair is dropped, so is this one.
box_sed_i '/^ExecStart=/ s| --want=| --repo=o/r|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "--repo=<slug> is configuration, and the inline spelling is dropped like the space form"
# Control 3: an EMPTY `--repo=` is NOT configuration. `--repo=` reaches the pass as the empty string, its
# pool read becomes `repos//actions/runners` and it exits 2 UNMEASURABLE on every tick — measured at this
# head (`rc=2`, "gh: Not Found (HTTP 404)"). Dropping it unconditionally certified ARMED exit 0 over a
# schedule that is RED every nine minutes: the same false PASS controls 1 and 2 close for
# `--want=` and `--root=`, so the empty value follows the same rule.
box_sed_i '/^ExecStart=/ s| --repo=o/r| --repo=|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an EMPTY --repo= is a value the pass cannot read, so the gate reds it"
assert_contains "$OUT" "--repo=" "and names the argument it refused"
rm -f "$ARM"

# ── T47: `--arm` NAMES why it cannot resolve a target, like every other verb ─────────────
# The arm called `choose_target || return 1` bare, so the one verb an operator runs to make a box GROW
# exited 1 with ZERO bytes of output — indistinguishable from a crash. Every other call site names it.
# Reached the way a box really reaches it: no passwordless sudo (`SUDO=false` is the documented seam) and
# no systemd user manager.
# ⛔ THE MISSING USER MANAGER IS NOW THE FIXTURE'S, NOT THE HOST'S. This case used to rely on the host
# simply not having one: `choose_target` probed the BARE `systemctl`, so the real binary answered — no
# user manager on a Mac (green), a live one on `ubuntu-latest` (red: `--arm` installed a USER unit pair
# into the fixture HOME and wrote an arming record). `SHIM_USER_MANAGER=no` expresses the premise on any
# host, and the probe honours the pinned `SYSTEMCTL` seam, so the shim is what answers it.
say_case "T47 --arm with no resolvable scheduler explains itself"
D="$T/c47"; fresh "$D"; rm -f "$ARM"
: >"$T/systemctl.log"
ENVV=(SUDO=false SHIM_USER_MANAGER=no)
OUT="$(run_install Linux - --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "an unresolvable target refuses"
assert_contains "$OUT" "no scheduler available" "and says which dependency is missing"
assert_contains "$OUT" "NOT silently skipping" "naming the failure this guard exists to prevent"
# ⛔ THE ASSERTION THAT MAKES THE FIX PROVABLE ON EVERY HOST. `SHIM_USER_MANAGER=no` alone is not
# enough: on a box with no user manager at all, a REVERTED bare probe also fails, so the case would pass
# either way and could not tell the fix from the defect. The shim logs every call, so this asserts the
# probe itself went through the seam — a reverted probe never reaches the pinned binary and fails here.
assert_contains "$(cat "$T/systemctl.log")" "--user show-environment" "the probe went through the SYSTEMCTL seam, not the bare binary"
assert_nofile "$ARM" "with no arming record written"
rm -f "$ARM"

# ── T48: the XML escaper is a LAUNCHD rule, never a systemd one ──────────────────────────
# `render` put every placeholder through `xml_sed_repl` on BOTH arms. That helper is deliberately two
# layers — the XML-entity escape PLUS the sed-replacement escape — and the XML half is correct only
# where the value lands in an XML text node, i.e. the plist. On the systemd arm it wrote the ENTITY
# into the unit: `HOME=/home/a&b` rendered `Environment=HOME=/home/a&amp;b`, a path the installer never
# resolved. How that surfaced depended on the placeholder — a value reaching `ExecStart=` (SCRIPT,
# PYTHON) made `verify_installed_unit` REFUSE the install (loud, but a false block: measured, pre-fix
# this case's install assertion fails because the install exits 1), while a value reaching only
# `Environment=` is compared by nothing, so the unit installed, enabled and listed. This fixture folds
# the metacharacter into HOME *and* SCRIPT, which is why it exercises the REFUSED arm; T49 is the
# reader-side case. The escape is chosen per ARM now (`repl_for`), which also makes the placeholder
# family agree with the COMPOSED `{{PROVISIONER_ENV}}` family — that one has always been sed-only on
# systemd, and T31 pins it.
say_case "T48 an '&' and a '<' are LITERAL in the systemd unit and escaped in the plist"
AMPC="$T/home/a&b<c"; mkdir -p "$AMPC"; cp "$T/home/converger.py" "$AMPC/"
rm -f "$ARM"
D="$T/c48"; fresh "$D"
ENVV=(HOME="$AMPC" RUNNER_AUTOSCALE_SCRIPT="$AMPC/converger.py" RUNNER_AUTOSCALE_STATE_DIR="$AMPC/state")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "the systemd arm installs a HOME carrying '&' and '<'"
UNIT_TXT="$(cat "$D/$UNIT_NAME.service" 2>/dev/null || true)"
assert_contains "$UNIT_TXT" "Environment=HOME=$AMPC" "the unit carries the REAL path, not an entity"
assert_contains "$UNIT_TXT" "RUNNER_AUTOSCALE_STATE_DIR=$AMPC/state" "and so does the state dir"
assert_absent "$UNIT_TXT" "&amp;" "no '&' entity was written into the unit"
assert_absent "$UNIT_TXT" "&lt;" "and no '<' entity either"
# Control, and the reason this is an ASYMMETRY and not a blanket relaxation: the plist IS an XML
# document, so the same value must still be entity-escaped there or launchd refuses to parse it. Both
# directions are asserted, so a future divergence between the arms fails here rather than on a box.
D2="$T/c48d"; fresh "$D2"
ENVV=(HOME="$AMPC" RUNNER_AUTOSCALE_SCRIPT="$AMPC/converger.py" RUNNER_AUTOSCALE_STATE_DIR="$AMPC/state")
OUT="$(run_install Darwin "$D2" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "the launchd arm installs the same path"
assert_contains "$(cat "$D2/$LABEL.plist" 2>/dev/null || true)" "&amp;" "the plist is XML, so it still entity-escapes the '&'"
assert_eq "$(plist_env "$D2/$LABEL.plist" HOME)" "$AMPC" "and the PARSED value is the real path (the entity round-trips)"

# ── T49: the readiness verb refuses what the writers refuse to create ────────────────────
# `is_transient_scratch` was reachable only from the three WRITING verbs, so an artifact whose declared
# paths sit in a mktemp tree was refused by `--install`/`--arm` and then CERTIFIED by `--status`. Worse
# than a missing check: the drift render is fed the ARTIFACT's own values, so it compares the file to a
# render of ITSELF, reports `drift_artifact=no`, and exits 0 — green over a unit that exits 127 on every
# tick the moment that tree is removed, i.e. exactly during the window an operator is looking at it.
# Measured before this case: the writer exits 1 ("REFUSING … transient scratch space") on the same paths
# the reader called clean. The writers refuse to CREATE this artifact, so a hand-edited, foreign or
# pre-fix one is how the state is reached — which is when a readiness gate earns its keep.
say_case "T49 --status refuses to certify an artifact pointing into transient scratch space"
SCRATCH="/tmp/tmp.ra-status.$$"
D="$T/c49"; fresh "$D"; rm -f "$ARM"
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 0 "precondition: the artifact installs"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the untouched artifact is green (the gate is discriminating)"
box_sed_i "s|^Environment=HOME=.*|Environment=HOME=$SCRATCH|" "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an artifact in transient scratch is NOT certified green"
assert_contains "$OUT" "TRANSIENT SCRATCH" "the refusal names what it found"
assert_contains "$OUT" "127" "and the measured consequence every tick"
assert_contains "$OUT" "REFUSE TO CREATE" "pointing at the writers, which already refuse this state"

# ── T50: the launchd cadence is READ BACK, not restated from the constant ────────────────
# The status arm printed `cadence=StartInterval=$INTERVAL_SEC` — the value this installer WOULD write —
# and derived `next_run=… fires every ${INTERVAL_SEC}s` from the same constant. On a box whose plist
# carries a hand-edited or foreign interval the readiness gate therefore printed a cadence the artifact
# contradicts, in the same output that flagged `drift_artifact=yes`, and exited 0. The systemd arm has
# never had this defect: its `next_run` comes from `list-timers`, an authoritative read.
say_case "T50 --status reports the StartInterval the plist DECLARES, not the one it would write"
D="$T/c50"; fresh "$D"; rm -f "$ARM"
run_install Darwin "$D" --install >/dev/null 2>&1
OUT="$(run_install Darwin "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the untouched plist is green"
assert_contains "$OUT" "cadence=StartInterval=540" "control: and reports the installed cadence"
box_sed_i 's|<integer>540</integer>|<integer>3600</integer>|' "$D/$LABEL.plist"
OUT="$(run_install Darwin "$D" --status)"; RC=$?
assert_contains "$OUT" "cadence=StartInterval=3600" "an hourly plist is reported as hourly, not as the constant"
assert_absent "$OUT" "cadence=StartInterval=540" "the constant is not restated over the artifact"
assert_contains "$OUT" "fires every 3600s" "and next_run's parenthetical is derived from the same read"
assert_contains "$OUT" "drift_artifact=yes" "the drift verdict independently flags the same edit"

# ── T52: `--arm`'s preflight ALLOW-LIST, which was carried by a comment and pinned by nothing ──────
# `case "$rc" in 0|4)` is a deliberate policy — 4 is STARVATION, which means the box WAS measured, so it
# is a reason to arm rather than a reason to refuse — and no case exercised it: every `--arm` fixture
# exited 0 or 2, so reverting the arm to `0)` kept the suite green. The policy decides whether a starved
# box can be armed at all, which is the box the whole feature exists for.
say_case "T52 --arm ACCEPTS exit 4 (starvation) and REFUSES exit 3 (action failed)"
D="$T/c52"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/actionfail.py")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a pass that FAILED (rc=3) is a box that was not measured, so --arm refuses it"
assert_contains "$OUT" "REFUSING to arm" "and the refusal is named"
assert_nofile "$ARM" "no record is written for an unmeasured box"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "--dry-run" \
    "and the artifact stays DISARMED after the refused arm"
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/starved.py")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "a STARVED box (rc=4) still ARMS — 4 means the box was measured, and starvation is the alarm the timer exists to surface"
assert_contains "$OUT" "ARMED" "the verb reports it armed"
assert_file "$ARM" "the record exists"
assert_contains "$(cat "$ARM" 2>/dev/null)" "ceiling=3" "carrying the ceiling the starved pass still measured"
rm -f "$ARM"

# ── T53: the arming record and the pass log live where the ARTIFACT says, not where this shell looks ─
# `STATE_DIR` defaults to `$HOME/.pi/agent/state`, and BOTH `ARM_FILE` and the last-tick log were derived
# from it ONCE, from the READER's environment — while the artifact EXPORTS the value it was installed with,
# and the service template states the invariant: "Exported so the scheduled pass and an operator's
# `--status` read ONE path, not two that look alike." A box installed and armed WITH the seam, then read
# or re-installed by a routine invocation WITHOUT it, therefore reported `mode=converge (ARMED)` beside
# `arm_record=absent (<the reader's dir>)` and `last_tick=none` — and a routine `--install` rendered
# `--dry-run`, silently DISARMING a box the owner had armed. Both are measured here.
say_case "T53 the record and the pass log are read from the ARTIFACT's declared state dir"
D="$T/c53"; fresh "$D"; rm -f "$ARM"
ST3="$D/custom-state"
ENVV=(RUNNER_AUTOSCALE_STATE_DIR="$ST3" RUNNER_AUTOSCALE_ARM_FILE="$ST3/runner-autoscale.armed")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "an install with the STATE_DIR seam set succeeds"
assert_contains "$(grep '^Environment=RUNNER_AUTOSCALE_STATE_DIR=' "$D/$UNIT_NAME.service" 2>/dev/null)" \
    "RUNNER_AUTOSCALE_STATE_DIR=$ST3" "the artifact EXPORTS the state dir it was installed with (the seam this case reads back)"
ENVV=(RUNNER_AUTOSCALE_STATE_DIR="$ST3" RUNNER_AUTOSCALE_ARM_FILE="$ST3/runner-autoscale.armed")
OUT="$(run_install Linux "$D" --arm --reason fixture)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "an arm with the seam set succeeds"
assert_file "$ST3/runner-autoscale.armed" "the record lives in the artifact's own directory"
printf '%s\n' '{"at":"2026-10-30T00:00:00Z","verdict":"at-ceiling","ceiling":3,"live":3}' >"$ST3/runner-autoscale.log"
# ⭐ THE MEASURED DEFECT: a ROUTINE invocation that does not set the seam — a bring-up, a sync.
ENVV=(RUNNER_AUTOSCALE_STATE_DIR= RUNNER_AUTOSCALE_ARM_FILE=)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "--status is green on a box that is armed and ticking"
assert_contains "$OUT" "arm_record=present ($ST3/runner-autoscale.armed)" \
    "the record is read from the ARTIFACT's directory, not this shell's default"
assert_contains "$OUT" "last_tick=at=2026-10-30T00:00:00Z" "and so is the pass log"
assert_contains "$OUT" "Honouring the ARTIFACT" "and the verb says which path won rather than silently picking one"
# ⭐ THE SILENT DISARM: the same routine invocation must not drop the owner's dated decision.
ENVV=(RUNNER_AUTOSCALE_STATE_DIR= RUNNER_AUTOSCALE_ARM_FILE=)
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "a routine --install (no seam) exits 0"
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "--dry-run" \
    "and does NOT silently re-render an armed box DISARMED"
# CONTROL: the adoption is not "assume armed". An EXPLICIT seam pointing at a directory with no record
# still renders DISARMED, so an operator can disarm deliberately and a fresh box is never armed by this.
D2="$T/c53b"; fresh "$D2"
ENVV=(RUNNER_AUTOSCALE_STATE_DIR="$D2/none" RUNNER_AUTOSCALE_ARM_FILE="$D2/none/runner-autoscale.armed")
OUT="$(run_install Linux "$D2" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "control: an install with an explicit seam and no record succeeds"
assert_contains "$(grep '^ExecStart=' "$D2/$UNIT_NAME.service" 2>/dev/null)" "--dry-run" \
    "…and renders DISARMED, so adoption never arms a box by itself"
rm -f "$ST3/runner-autoscale.armed" "$ARM"

# ── T54: `--status` refuses a record it cannot honour, and a value the WRITERS would refuse ───────
# Two one-fact-two-readers splits on the same verb. (a) The record: every writer asks
# `arm_record_valid` (BOTH `armed-by=` and `armed-date=`), the readiness verb asked `[ -f ]`, so a
# half-written record — the state the file's own rule calls fail-closed — was certified `present`.
# (b) The declared values: the writers refuse a `--repo` that is not a plain `owner/name` and a `%` in
# any rendered value on systemd, and the drift `cmp` structurally cannot catch either, because the
# render is fed the artifact's OWN values and reproduces the bad one exactly.
say_case "T54 --status refuses a half-written record and a declared value the writers would refuse"
D="$T/c54"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: an intact record is green"
grep -v '^armed-date=' "$ARM" >"$D/half.armed" 2>/dev/null && cp "$D/half.armed" "$ARM"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a record missing armed-date= is NOT certified green"
assert_contains "$OUT" "arm_record=INVALID" "it is named INVALID, not merely 'present'"
assert_contains "$OUT" "DISARMED" "and the output names what the next --install will do"
rm -f "$ARM"
D2="$T/c54b"; fresh "$D2"; rm -f "$ARM"
run_install Linux "$D2" --install >/dev/null 2>&1
box_sed_i 's|--repo "o/r"|--repo "o/%h"|' "$D2/$UNIT_NAME.service"
OUT="$(run_install Linux "$D2" --status)"; RC=$?
assert_eq "$RC" 1 "a declared --repo the writers would REFUSE is not certified green"
assert_contains "$OUT" "not a plain owner/name" "the refusal names the rule the writers apply"
rm -f "$ARM"

# ── T55: a VALUELESS `--repo` is not configuration, and the strip used to eat the next token ────────
# The `--repo` strip runs BEFORE classification and removed the flag plus whatever token followed it,
# unconditionally — so `--repo` as the LAST token was dropped for having no value, and `--repo --dry-run`
# had its `--dry-run` EATEN as if it were the value. argparse rejects both (measured: rc=2, "argument
# --repo: expected one argument") while `--status` reported `mode=converge (ARMED)` exit 0 — and
# `artifact_is_armed`, which tests the `--dry-run` SUBSTRING, said the opposite about the same line. Two
# readers of one command line disagreeing, with the readiness verb on the wrong side.
say_case "T55 a --repo with NO value is reported, in both shapes"
D="$T/c55"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the installer's own --repo pair is configuration and stays green"
# Shape 2: `--repo` followed by a FLAG — the flag is not a value, and must not be swallowed as one.
box_sed_i 's|--repo "o/r"|--repo|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--repo followed by a FLAG is not certified green"
assert_contains "$OUT" "--repo" "and it names --repo there too"
assert_absent "$OUT" "mode=converge (ARMED" "the flag that came after it is NOT eaten as a value"
# Shape 1: `--repo` LAST — nothing follows it, so it has no value at all. (The unit is disarmed, so the
# `--dry-run` it carries is removed to leave the flag genuinely trailing.)
box_sed_i 's| --dry-run||' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a TRAILING --repo with no value is not certified green"
assert_contains "$OUT" "--repo" "and the refusal names the argument"
rm -f "$ARM"

# ── T56: `--want` is argparse `type=int`, so "non-empty" is not the rule ────────────────────────────
# The classifier tested EMPTINESS, and the docs asserted the reason ("an EMPTY value is precisely what
# the pass exits 2 on"). Measured: `--want=abc`, `--want abc`, `--want=3x` and `--want 3x` ALL exit 2
# ("argument --want: invalid int value"), while `--status` certified each ARMED exit 0. A whole number is
# the only shape the flag accepts, so the ordinary `--want 3` must stay green (T25 pins that intent).
say_case "T56 a --want value that is not a whole number is reported, in both shapes"
D="$T/c56"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
box_sed_i 's| --repo "o/r"| --repo "o/r" --want 3|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: --want 3 (a whole number) is a legitimate switch and stays green"
box_sed_i 's| --want 3| --want abc|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "the SPACE form with a non-integer is not certified green"
assert_contains "$OUT" "--want" "and the refusal names the argument"
box_sed_i 's| --want abc| --want=3x|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "the INLINE form with a non-integer is not certified green either"
assert_contains "$OUT" "--want=3x" "naming the exact argument it refused"
rm -f "$ARM"

# ── T57: the reader applies the WRITERS' value rules to what it reads back ────────────────────────
# `refuse_systemd_unsafe_values` ('%' and whitespace) and `refuse_unusable_target`'s writability probe
# run in `do_install_systemd`/`do_arm` and NOWHERE in `do_status`, while the drift `cmp` structurally
# cannot catch either (the render is fed the artifact's OWN values, so it compares the file to itself).
# So the readiness verb certified green on facts its own writers refuse — including the one the writers'
# own comment says `--status` "cannot see", which was true only because it never looked.
say_case "T57 --status applies the writers' value rules to the artifact it reads back"
D="$T/c57"; fresh "$D"; rm -f "$ARM"
ST7="$D/state7"
ENVV=(RUNNER_AUTOSCALE_STATE_DIR="$ST7" RUNNER_AUTOSCALE_ARM_FILE="$ST7/runner-autoscale.armed")
run_install Linux "$D" --install >/dev/null 2>&1; ENVV=()
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: the untouched artifact is green"
box_sed_i 's|^Environment=PATH=.*|Environment=PATH=/usr/bin%h|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a declared PATH containing '%' is not certified green"
assert_contains "$OUT" "SPECIFIER" "naming it as the systemd specifier it is"
box_sed_i 's|^Environment=PATH=.*|Environment=PATH=/usr/bin|' "$D/$UNIT_NAME.service"
box_sed_i 's|--repo "o/r"|--repo "nope"|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a declared --repo that is not owner/name is not certified green"
assert_contains "$OUT" "not a plain owner/name" "naming the rule the writers apply"
box_sed_i 's|--repo "nope"|--repo "o/r"|' "$D/$UNIT_NAME.service"
# …and the writers' writability probe, on the fact `last_tick=` depends on: a state dir the pass cannot
# write means that line can NEVER become positive, while the verb stays green. Skipped as root, where a
# 0500 directory is still writable and the premise cannot be expressed — the pass/fail pair is emitted
# either way so the suite's assertion count does not move between hosts.
if [ "$(id -u)" != "0" ]; then
    chmod 500 "$ST7"
    OUT="$(run_install Linux "$D" --status)"; RC=$?
    chmod 700 "$ST7"
    assert_eq "$RC" 1 "a declared state dir that is NOT WRITABLE is not certified green"
    assert_contains "$OUT" "NOT writable" "naming the consequence the writers already refuse"
else
    ok "a declared state dir that is NOT WRITABLE is not certified green (skipped: running as root, where a 0500 dir stays writable)"
    ok "naming the consequence the writers already refuse (skipped: root)"
fi
rm -f "$ST7/runner-autoscale.armed" "$ARM"

# ── T58: the ARTIFACT and the RECORD must agree, in BOTH directions ────────────────────────
# Both WRITERS refuse to create the disagreement (`verify_installed_unit`, and the plist arm's own), which
# is exactly when a readiness verb has to catch it: `--status` is what an operator runs AFTER a hand-edit,
# a partial restore or a foreign artifact, and pre-fix it exited 0 in BOTH directions — an artifact
# hand-stripped of `--dry-run` with NO record (a box growing capacity with no dated owner decision, the
# one state this design exists to forbid) and a hand-reverted artifact beside a VALID record (every tick
# measures and repairs nothing while the box reads armed). The ABSENT case is strictly WEAKER than the
# INVALID record this verb already reds, so the old verdict was incoherent as well as lenient.
# ⛔ THE CONTROL IS WHAT MAKES THE PAIR MEANINGFUL: each red is produced by removing/adding ONE fact from
# a state that is otherwise green, so neither direction can pass by redding everything.
say_case "T58 --status refuses an artifact that disagrees with the record, in both directions"
D="$T/c58"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: DISARMED artifact with NO record is coherent, and green"
assert_contains "$OUT" "arm_record=absent" "…with the absence shown, not implied"
run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: an ARMED artifact WITH its record is coherent, and green"
assert_contains "$OUT" "arm_record=present" "…with the record shown"
# Direction 1: ARMED artifact, record GONE — the state a hand-strip or a foreign artifact leaves.
rm -f "$ARM"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "an ARMED artifact with NO record is refused (nothing dates the decision to grow)"
assert_contains "$OUT" "NO valid arming record" "naming the missing artifact"
assert_contains "$OUT" "--disarm" "and offering the remedy that does not widen the box"
# Direction 2: record VALID, artifact hand-reverted to DISARMED — the state a bad restore leaves.
rm -f "$ARM"; run_install Linux "$D" --arm --reason fixture >/dev/null 2>&1
box_sed_i '/^ExecStart=/ s|$| --dry-run|' "$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "a VALID record beside a DISARMED artifact is refused (the box reads armed, repairs nothing)"
assert_contains "$OUT" "DISAGREE" "naming the disagreement rather than the artifact alone"
# …and the LAUNCHD arm answers the same question, so the two platforms cannot drift apart here.
D="$T/c58b"; fresh "$D"; rm -f "$ARM"
run_install Darwin "$D" --install >/dev/null 2>&1
run_install Darwin "$D" --arm --reason fixture >/dev/null 2>&1
run_install Darwin "$D" --disarm >/dev/null 2>&1
OUT="$(run_install Darwin "$D" --status)"; RC=$?
assert_eq "$RC" 0 "control: a real launchd --disarm leaves a coherent DISARMED pair"
rm -f "$ARM"; run_install Darwin "$D" --arm --reason fixture >/dev/null 2>&1
rm -f "$ARM"
OUT="$(run_install Darwin "$D" --status)"; RC=$?
assert_eq "$RC" 1 "the launchd arm refuses an ARMED plist with NO record too"
rm -f "$ARM"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
