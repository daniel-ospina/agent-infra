#!/usr/bin/env bash
# install-launchd-durability.test.sh — the installer must never be able to take the production
# controller down (agent-infra#1975).
#
# Run: bash scripts/orchestrator-harness/install-launchd-durability.test.sh
# Exits 0 when ALL assertions pass, non-zero on any failure. HERMETIC: a throwaway HOME, a throwaway
# `$O`, and a `launchctl` stub first on PATH — it never touches real launchd, the real
# ~/Library/LaunchAgents, or the live controller.
#
# WHAT IT PINS, and the measured failure behind each:
#
#   A. no persistent-disable verb in CODE
#        `launchctl unload -w` sets the job's on-disk Disabled override to true (man launchctl) and
#        `enable|disable` state "persists across boots". The old flow was unload -w then load -w: a
#        DISABLE whose re-enable needed a bootstrap allowed to fail. On 2026-10-17 it failed (EIO) and
#        left com.eldato.orchestrator-loop removed AND disabled while the installer exited 0.
#   B. lc_pid parses a REAL `launchctl print` block
#        fixture captured from this box, so the pid read is pinned to launchd's actual output rather
#        than to an invented shape.
#   C. lc_start: enable → bootout → bootstrap, and reports WHICH path ran
#        the `load` fallback is what recovered the box; an operator debugging the next EIO must be
#        told the job came up on the legacy path, not left to guess.
#   D. lc_ensure leaves a healthy, unchanged controller ALONE
#        a validation run that re-renders identical bytes must make zero mutating launchctl calls.
#   E. THE CORE: no forbidden end state, ever
#        for every start scenario the triple (running?, disabled?, exit code) is checked, and the
#        cell "not running AND (disabled OR exit 0)" fails the suite. This is the regression the issue
#        is about: something died, nothing said so, and the exit code claimed success.
#   F. end-to-end install.sh (macOS only — it renders a launchd plist and needs plutil):
#        plain install = zero mutating calls; --start proves itself; a failed --start exits non-zero
#        with one actionable line; --uninstall bootouts; an unknown flag is refused.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR"
INSTALL="$HARNESS/install.sh"
LIB="$HARNESS/launchd-cycle.sh"
README="$HARNESS/README.md"
PLATFORM="$(uname)"
LABEL="com.eldato.orchestrator-loop"

PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skipd() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi
}
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): under `pipefail` the quiet grep exits on its first
# match, the writer takes SIGPIPE, and the PIPELINE's status becomes 141 — `$?` then records a SIGPIPE
# instead of the match. Checked by `scripts/check-no-sigpipe-grep.sh`, which gates CI on the shape.
assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/install-durability.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

# ⛔ THE STUB. It records every invocation, maintains a tiny state dir, and RECORDS A VIOLATION for
# any invocation carrying the persistent-disable flag or the unload/disable verbs — so "the script
# never writes a persistent disable" is asserted against observed behaviour, not against a grep of
# the source alone.
mkdir -p "$T/bin"
cat > "$T/bin/launchctl" <<'SHIM'
#!/usr/bin/env bash
log="${FAKE_LOG:?}"; st="${FAKE_STATE:?}"
printf '%s\n' "$*" >> "$log"
case " $* " in *" -w "*) printf 'VIOLATION persistent-disable-flag %s\n' "$*" >> "$log" ;; esac
case "${1:-}" in unload|disable) printf 'VIOLATION persistent-disable-verb %s\n' "$*" >> "$log" ;; esac

bump_hb() { # a live controller refreshes $O/heartbeat at the top of every cycle
  local f="${FAKE_O:?}/heartbeat" prev v
  [ -n "${FAKE_NO_HB:-}" ] && return 0
  # A REAL epoch, like orch-loop.sh's `date +%s > $O/heartbeat` — the freshness read compares it
  # against the wall clock, so a counter would make every seeded state look centuries stale. It is
  # forced STRICTLY past the previous value so that two launches inside the same second still read as
  # "it advanced" (a real controller's cycle is minutes, but a test must not depend on the clock).
  prev="$(cat "$f" 2>/dev/null || echo 0)"
  v="$(date +%s)"
  [ "$v" -le "$prev" ] && v=$(( prev + 1 ))
  printf '%s\n' "$v" > "$f"
}
start_ok() { # $1 = the pid launchd would report
  printf 'gui/0/%s = {\n\tactive count = 1\n\tstate = running\n\n\tpid = %s\n}\n' \
    "${FAKE_LABEL:-com.eldato.orchestrator-loop}" "${1:-4242}" > "$st/print"
  : > "$st/loaded"
  bump_hb
}
case "${1:-}" in
  print)
    if [ -n "${FAKE_PRINT_FILE:-}" ]; then cat "$FAKE_PRINT_FILE"; exit 0; fi
    if [ -f "$st/print" ]; then cat "$st/print"; exit 0; fi
    printf 'Bad request.\nCould not find service in domain for user gui: 0\n' >&2; exit 1 ;;
  enable)   : > "$st/enabled"; exit 0 ;;
  bootout)
    if [ -f "$st/loaded" ]; then rm -f "$st/loaded" "$st/print"; exit 0; fi
    exit 3 ;;
  bootstrap)
    [ -n "${FAKE_BOOTSTRAP_FAIL:-}" ] && { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 1; }
    start_ok 4242; exit 0 ;;
  load)
    [ -n "${FAKE_LOAD_FAIL:-}" ] && { printf 'Load failed: 5: Input/output error\n' >&2; exit 1; }
    start_ok 5353; exit 0 ;;
  kickstart) exit 0 ;;
esac
exit 0
SHIM
chmod +x "$T/bin/launchctl"
PATH="$T/bin:$PATH"; export PATH

fresh() { # reset the stub's world; $1 = heartbeat seed (optional)
  rm -rf "$T/state" "$T/o"; mkdir -p "$T/state" "$T/o/logs"
  printf '%s\n' "${1:-100}" > "$T/o/heartbeat"
  : > "$T/o/x.plist"   # lc_bootout is PATH-keyed, so a path must exist for the removal to be issued
  export FAKE_LOG="$T/launchctl.log" FAKE_STATE="$T/state" FAKE_O="$T/o"
  : > "$FAKE_LOG"
  unset FAKE_BOOTSTRAP_FAIL FAKE_LOAD_FAIL FAKE_NO_HB FAKE_PRINT_FILE 2>/dev/null || true
}
calls() { cat "$FAKE_LOG" 2>/dev/null || true; }
verbs() { awk '{print $1}' "$FAKE_LOG" 2>/dev/null | tr '\n' ' '; }
is_loaded() { [ -f "$T/state/loaded" ]; }
violations() { grep '^VIOLATION' "$FAKE_LOG" 2>/dev/null || true; }
# ⛔ LABEL-FORM REMOVALS. `bootout gui/<uid>/<label>` resolves the label in the REAL user domain and
# IGNORES $HOME, so a sandboxed installer run using it would remove the PRODUCTION controller — the
# same failure this suite exists to catch, through a different door. The stub logs argv, so the FORM is
# observable: verb + one target = label form; verb + domain + path = the only form allowed.
label_bootouts() { awk '$1=="bootout" && NF<3 {print}' "$FAKE_LOG" 2>/dev/null || true; }

# ── the forbidden end state (E) — ONE helper, used by every scenario below ────────────────────────
# "Something died, nothing said so, and the exit code claimed success" is the exact shape of
# agent-infra#1975. So the state is read as a TRIPLE, and the one cell that must never occur is:
#   not running  AND  (persistent disable written OR exit code 0)
assert_end_state() { # <rc> <label-for-the-assertion>
  local rc="$1" name="$2" running=no viol
  is_loaded && running=yes
  viol="$(violations)"
  if [ "$running" = "no" ] && { [ -n "$viol" ] || [ "$rc" = "0" ]; }; then
    bad "$name — FORBIDDEN END STATE: not running with (disabled='${viol:-none}' rc=$rc)"
    return 1
  fi
  ok "$name — end state legal (running=$running, disable-writes=${viol:+YES}${viol:-none}, rc=$rc)"
  return 0
}

echo "==> install/launchd durability ($HARNESS)"

# ── A. no persistent-disable verb in CODE ────────────────────────────────────────────────────────
# Comments are excluded deliberately: a comment cannot run, and the whole point of several comments in
# these files is to NAME the trap for the next reader. README has no comments, so its code blocks are
# scanned as commands — those are what an agent copies and pastes.
echo "-- A. no persistent-disable invocation in code"
code_of() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }
A_BAD=""
for f in "$HARNESS"/*.sh "$HARNESS"/*.template; do
  case "$f" in *.test.sh) continue ;; esac
  hit="$(code_of "$f" | grep -nE 'launchctl[^|]*[[:space:]]-w|launchctl[[:space:]]+(unload|disable)[[:space:]]|(unload|load)[[:space:]]+-w[[:space:]]' || true)"
  [ -n "$hit" ] && A_BAD="$A_BAD
$(basename "$f"): $hit"
done
if [ -z "$A_BAD" ]; then ok "no shipped CODE line writes a persistent disable (launchctl … -w / unload / disable)"
else bad "a shipped code line writes a persistent disable:$A_BAD"; fi

# README: every copyable launchctl command must be safe. A line STARTING with `launchctl unload` or
# `launchctl disable` is a command an agent will run; prose that mentions the verbs does not start
# with the binary.
R_BAD="$(grep -nE '^[[:space:]]*launchctl[[:space:]]+(unload|disable)' "$README" 2>/dev/null || true)"
if [ -z "$R_BAD" ]; then ok "README ships no copyable 'launchctl unload'/'launchctl disable' command"
else bad "README still ships a copyable persistent-disable command: $R_BAD"; fi
R_W="$(grep -nE '^[[:space:]]*launchctl[[:space:]]+(load|unload)[^#]*-w' "$README" 2>/dev/null || true)"
if [ -z "$R_W" ]; then ok "README ships no copyable 'launchctl load -w' command"
else bad "README still ships a copyable '-w' command: $R_W"; fi

# The ONE implementation, and the installer must refuse without it (fail closed, never a silent
# degrade to the legacy verbs).
LIB_CODE="$(code_of "$LIB")"
INSTALL_CODE="$(code_of "$INSTALL")"
for v in bootout enable bootstrap; do
  if grep -q "launchctl $v" <<<"$LIB_CODE"; then ok "launchd-cycle.sh uses 'launchctl $v'"
  else bad "launchd-cycle.sh does not use 'launchctl $v'"; fi
done
assert_contains "$INSTALL_CODE" 'launchd-cycle.sh' "install.sh has the helper's path"
if grep -q 'LC_LIB' <<<"$INSTALL_CODE" && grep -q 'die "missing \$LC_LIB' <<<"$INSTALL_CODE"; then
  ok "install.sh FAILS CLOSED when launchd-cycle.sh is missing"
else bad "install.sh would silently proceed without launchd-cycle.sh"; fi
if grep -qE '^[[:space:]]*\. "\$LC_LIB"' <<<"$INSTALL_CODE"; then ok "install.sh sources launchd-cycle.sh"
else bad "install.sh does not source launchd-cycle.sh"; fi

# ── B. lc_pid against a REAL launchctl print block ───────────────────────────────────────────────
echo "-- B. pid read against a captured real 'launchctl print' block"
# Captured from `launchctl print gui/501/com.eldato.orchestrator-loop` on 2026-10-17, trimmed to the
# shape that matters: the job-level `pid = N` line, and the nested `state = active` lines that must
# NOT be read as a pid.
cat > "$T/real-print.txt" <<'REAL'
gui/501/com.eldato.orchestrator-loop = {
	active count = 1
	path = /Users/someone/Library/LaunchAgents/com.eldato.orchestrator-loop.plist
	type = LaunchAgent
	state = running

	program = /bin/bash
	arguments = {
		/bin/bash
		/Users/someone/orchestrator/orch-loop.sh
	}

	pid = 83626

	immediate reason = speculative
	forks = 0
	execs = 0

	resource coalition = {
		state = active
		roles = {
			coalition = {
				state = active
			}
		}
	}

	environment = {
		PATH => /usr/bin:/bin
	}
}
REAL
fresh
# ⛔ EXPORTED, not bare: a bare `FAKE_X=1` on its own line is a shell variable, so the stub (a child
# process) never sees it — the knobs silently do nothing and the test asserts nothing.
export FAKE_PRINT_FILE="$T/real-print.txt"
got="$(
  # shellcheck source=launchd-cycle.sh
  . "$LIB"; lc_pid "$LABEL"
)"
assert_eq "$got" "83626" "lc_pid returns the job's own pid from a real block (not a nested state)"
unset FAKE_PRINT_FILE
got="$( . "$LIB"; lc_pid "$LABEL" )"
assert_eq "$got" "" "lc_pid returns EMPTY for a job that is not loaded (empty, never a guess)"

# ── C. lc_start: order, reporting, and the load fallback ─────────────────────────────────────────
echo "-- C. lc_start"
fresh
via="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" )"; rc=$?
assert_eq "$via" "bootstrap" "a healthy bootstrap reports via=bootstrap"
assert_eq "$rc" "0" "a healthy bootstrap returns 0"
order="$(verbs)"
case "$order" in
  "enable bootout bootstrap "*) ok "invocation order is enable → bootout → bootstrap ($order)" ;;
  *) bad "invocation order is wrong: $order" ;;
esac
assert_eq "$(violations)" "" "no persistent-disable verb was used"
assert_eq "$(label_bootouts)" "" "the removal was PATH-keyed, never label-keyed (a sandboxed run cannot remove the production job)"

fresh
export FAKE_BOOTSTRAP_FAIL=1
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>"$T/err.txt" )"; rc=$?
assert_eq "$out" "load" "a FAILED bootstrap falls back to the legacy load path (reported as via=load)"
assert_eq "$rc" "0" "the fallback path returns 0"
assert_contains "$(cat "$T/err.txt")" "legacy 'load' path" "the fallback SAYS which path ran"
assert_contains "$(calls)" "load" "the legacy load verb was actually invoked"

fresh
export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>"$T/err.txt" )"; rc=$?
assert_eq "$out" "none" "both paths failing reports via=none"
if [ "$rc" -ne 0 ]; then ok "both paths failing returns NON-ZERO"; else bad "both paths failing returned 0"; fi
assert_contains "$(cat "$T/err.txt")" "could not load $LABEL" "the failure names the label"
assert_contains "$(cat "$T/err.txt")" "left ENABLED and NOT running" "the failure states the end state (enabled, not running)"
assert_eq "$(violations)" "" "neither failure path wrote a persistent disable"
if [ -f "$T/state/enabled" ]; then ok "the job was ENABLED before the failed bootstrap"
else bad "the job was never enabled"; fi

# ── D. lc_ensure: safe on a live box ─────────────────────────────────────────────────────────────
echo "-- D. lc_ensure leaves a healthy controller alone"
mutating_calls() { grep -vE '^(print|kickstart)( |$)' "$FAKE_LOG" 2>/dev/null || true; }

fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
before="$(mutating_calls)"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2>&1 )"; rc=$?
assert_eq "$rc" "0" "unchanged plist + healthy controller returns 0"
assert_contains "$out" "left untouched" "it says the controller was left untouched"
assert_eq "$(mutating_calls)" "$before" "ZERO MUTATING launchctl calls were made (the pid read is the only call)"

echo "-- D2. lc_ensure with a stale heartbeat"
fresh "$(( $(date +%s) - 5000 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$T/o/heartbeat"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a loaded-but-not-cycling controller returns NON-ZERO"; else bad "a stale heartbeat returned 0"; fi
assert_contains "$out" "--restart" "it points at --restart rather than restarting silently"

echo "-- D3. lc_ensure reloads when the plist CHANGED"
fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 3 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a changed plist reloads and returns 0"
assert_contains "$out" "loaded via" "it reports the load path"
assert_contains "$(calls)" "bootout" "it booted the old job out"

echo "-- D4. lc_restart refuses while a FOREIGN controller holds the lock"
fresh
printf '%s\n' "$$" > "$T/o/.orch.lock"     # this test's own shell: alive, holds the lock, not launchd
out="$( . "$LIB"; lc_restart "$LABEL" "$T/o/x.plist" "$T/o" 2 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a foreign lock holder makes the start REFUSE (non-zero)"; else bad "it started anyway"; fi
assert_contains "$out" "$T/o/.orch.lock" "the refusal names the lock and its pid"
assert_not_contains "$(calls)" "bootstrap" "nothing was bootstrapped over the foreign controller"
rm -f "$T/o/.orch.lock"

# ── E. the forbidden end state, across every driveable start scenario ───────────────────────────
echo "-- E. no forbidden end state in any start scenario"
drive() { # <name> <0|fail>
  local name="$1" expect="$2" rc
  out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 2 2>&1 )"; rc=$?
  assert_end_state "$rc" "$name"
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -ne 0 ]; then ok "$name — a failed start REPORTS (rc=$rc)"; else bad "$name — exited 0 with no working controller"; fi
  else
    if [ "$rc" -eq 0 ]; then ok "$name — a good start returns 0"; else bad "$name — a good start returned $rc"; fi
  fi
}

fresh;                                                       drive "fresh box, healthy start" 0
fresh; export FAKE_BOOTSTRAP_FAIL=1;                         drive "bootstrap fails, load fallback" 0
fresh; export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1;        drive "bootstrap AND load fail" fail
fresh; export FAKE_NO_HB=1;                                  drive "loaded with a pid but no heartbeat" fail

# ── F. end-to-end install.sh ─────────────────────────────────────────────────────────────────────
echo "-- F. install.sh end to end"
if [ "$PLATFORM" != "Darwin" ]; then
  skipd "install.sh end-to-end — install.sh is macOS-only by construction (launchd + plutil)"
else
  # The installer is driven from a STAGE copy so it cannot reach this checkout's neighbours, and so
  # the only scripts its `bash -n` sweep sees are the ones under test.
  STAGE="$T/stage"; mkdir -p "$STAGE"
  cp "$INSTALL" "$LIB" "$HARNESS/launchd.plist.template" "$STAGE/" 2>/dev/null
  SHOME="$T/home"; mkdir -p "$SHOME/Library/LaunchAgents" "$SHOME/.local/share/pi-node/current/bin" \
    "$SHOME/.pi/agent/scripts"
  # install.sh probes the real binaries: gh (network), tmux, pi, uv.
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/gh"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$SHOME/.local/share/pi-node/current/bin/pi"
  chmod +x "$T/bin/gh" "$T/bin/tmux" "$SHOME/.local/share/pi-node/current/bin/pi"
  PLIST="$SHOME/Library/LaunchAgents/$LABEL.plist"
  ORUN() { # <extra args…>
    env HOME="$SHOME" O="$T/o" REPO="$(cd "$HARNESS/../.." && pwd)" OR="acme/widget" \
      START_TIMEOUT=2 PATH="$SHOME/.local/share/pi-node/current/bin:$T/bin:$PATH" \
      bash "$STAGE/install.sh" "$@"
  }
  mutating() { grep -vE '^(print|kickstart)( |$)' "$FAKE_LOG" 2>/dev/null || true; }

  fresh
  out="$(ORUN 2>&1)"; rc=$?
  assert_eq "$rc" "0" "plain install exits 0"
  [ -f "$PLIST" ] && ok "plain install rendered the plist" || bad "plain install rendered no plist"
  if [ -z "$(mutating)" ]; then ok "plain install made ZERO mutating launchctl calls (a validation run cannot disturb a live controller)"
  else bad "plain install MUTATED launchd: $(mutating)"; fi

  # --start with a healthy box: the job comes up and the start is PROVEN.
  fresh "$(( $(date +%s) - 5 ))"
  out="$(ORUN --start 2>&1)"; rc=$?
  assert_eq "$rc" "0" "--start on a fresh box exits 0"
  is_loaded && ok "--start left the job loaded" || bad "--start did not load the job"
  assert_contains "$out" "heartbeat advanced" "--start VERIFIED the heartbeat advanced"

  # --start where bootstrap AND load fail: MUST be non-zero, with one actionable line.
  fresh
  export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1
  out="$(ORUN --start 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "a failed --start exits NON-ZERO (the old installer exited 0 here)"; else bad "a failed --start exited 0"; fi
  assert_contains "$out" "could not load $LABEL" "the failure prints one actionable line naming the label"
  assert_contains "$out" "Next: launchctl print" "…and names the next command to run"
  assert_eq "$(violations)" "" "the failed start wrote no persistent disable"

  # --start where the job comes up but NEVER cycles: also non-zero, and the message distinguishes
  # "no pid" from "pid but no heartbeat" (they have different remedies).
  fresh
  export FAKE_NO_HB=1
  out="$(ORUN --start 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "loaded-but-not-cycling --start exits NON-ZERO"; else bad "loaded-but-not-cycling exited 0"; fi
  assert_contains "$out" "running but NOT cycling" "the message distinguishes 'not cycling' from 'not running'"

  # --start on a HEALTHY live job with an UNCHANGED plist: left alone.
  fresh "$(( $(date +%s) - 5 ))"
  out="$(ORUN --start 2>&1)"; rc=$?
  assert_eq "$rc" "0" "second --start exits 0"
  : > "$FAKE_LOG"
  out="$(ORUN --start 2>&1)"; rc=$?
  assert_eq "$rc" "0" "idempotent --start exits 0"
  if [ -z "$(mutating)" ]; then ok "an unchanged, healthy box is NOT disturbed by --start"
  else bad "--start disturbed a healthy unchanged controller: $(mutating)"; fi
  assert_contains "$out" "left untouched" "…and says so"

  # an unknown flag must be REFUSED, not ignored: a typo'd --strt would otherwise install and exit 0.
  out="$(ORUN --strt 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "an unknown flag is refused (non-zero)"; else bad "an unknown flag was silently accepted"; fi
  assert_contains "$out" "unknown argument" "the refusal names the problem"

  # --uninstall: bootout, remove the plist, no disable.
  out="$(ORUN --uninstall 2>&1)"; rc=$?
  assert_eq "$rc" "0" "--uninstall exits 0"
  [ ! -f "$PLIST" ] && ok "--uninstall removed the plist" || bad "--uninstall left the plist"
  assert_contains "$(calls)" "bootout" "--uninstall booted the job out"
  assert_eq "$(violations)" "" "--uninstall wrote NO persistent disable (the next start is a plain start)"
  assert_eq "$(label_bootouts)" "" "--uninstall removed by PLIST PATH, so a sandboxed HOME cannot boot out the live job"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '==> all %d checks passed (%d skipped)\n' "$PASS" "$SKIP"
  exit 0
fi
printf '==> %d passed, %d FAILED (%d skipped)\n' "$PASS" "$FAIL" "$SKIP"
exit 1
