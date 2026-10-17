#!/usr/bin/env bash
# cloud-cell-bringup.test.sh — the regression contract for agent-infra#1718.
#
# The operator PUSHES the gh token onto the cell as a FILE, so until it is deleted that file is a
# PUSH-CAPABLE credential sitting on a machine we hand between operators. The pre-fix cleanup was
# placed after the guard it was paired with:
#
#     gh auth login --with-token < "$tokfile" || die "gh auth failed from $tokfile"   # ← exits here
#     rm -f "$tokfile" && ok "token file removed"                                     # ← success only
#
# so `die` exited before the delete and the token SURVIVED every failure, every abort, and every
# signal — silently, because a token still on disk changes nothing the operator can see. The same
# `rm -f … && ok …` also swallowed a FAILED removal: nothing was printed and bring-up still reached
# its `CELL READY` banner with the token there.
#
# This suite drives the SHIPPED script end-to-end (not a re-implementation of the cleanup: a check
# that reimplements the logic passes on the broken copy too) and asserts:
#
#   * a FAILING `gh auth login` still removes the token, and does not reach the readiness banner;
#   * an abort BEFORE check_gh is reached (github unreachable) removes it too — the window the
#     pre-fix code left open, since its removal lived inside check_gh and there was no trap;
#   * the non-`die` exit (unknown mode) removes it;
#   * a SIGTERM removes it — and the load-bearing assertion is that the trap's cleanup RAN: an
#     UNTRAPPED fatal signal reaches the parent as 128+signal too and (measured on bash 3.2.57) runs
#     a bare EXIT trap as well, so the rc alone proves nothing either way;
#   * a removal that FAILS is loud and refuses to report readiness (fail-closed, not fail-open);
#   * a keys.env that runs `trap - EXIT` cannot disarm the cleanup (the handlers are re-asserted after
#     the file is sourced — measured: the token survived when they were not);
#   * a token whose parent directory denies traversal is still reported LOUDLY and never produces a
#     readiness banner — `[ -e ]`/`[ -f ]` are false there, so a stat-gated removal would skip it
#     silently, which is the pre-fix failure mode wearing a different hat;
#   * a DEAD STDOUT during the cleanup (the removal LOG write raises SIGPIPE) does not truncate the
#     loop: with two registered secrets BOTH are removed, not just the entry being logged;
#   * NON-VACUITY: a clean run still exits 0 and still prints CELL READY, and a token that is
#     present is genuinely deleted (a suite that never had the file would pass for the wrong reason).
#
# Hermetic: temp HOME/state/token path, stubbed toolchain, no network, and GH_TOKEN_FILE keeps it
# away from the REAL /tmp/.gh-tok. Run:  bash scripts/cloud-cell-bringup.test.sh
# ⚠️ `--check` now also provisions the operational layer (#1723) from the checkout this script
# lives in, so the clean-run case installs it into the temp CELL_HOME: that is why the stub set
# carries an offline `npm` and leaves `python3` to the host (see the stub block below).
# ⚠️ That hermeticity is a property of the FIXED script: GH_TOKEN_FILE is introduced by this fix, so
# running this suite against the PRE-FIX script (to show it is red) reads and `rm -f`s the real
# /tmp/.gh-tok of whatever host runs it. Do that only where that file does not exist (as here).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⏭ SKIPPED — $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-1718.XXXXXX")"
# The scheduled layer (agent-infra#1864) runs the declarations it is pointed at, so it is pointed at
# a HERMETIC fixture here: without TEMPLATES_DIR the shipped templates would run the REAL reapers
# (pi-reap-idle.sh is armed with REAP_DRY_RUN=0) against this host, which is not a test. The loop is
# stopped on the way out — a detached loop outlives the suite otherwise and keeps ticking at a
# deleted directory.
export TEMPLATES_DIR="$T/schedule-templates"
mkdir -p "$TEMPLATES_DIR"
printf '# fixture: nothing retired\n' > "$TEMPLATES_DIR/RETIRED"
cat > "$TEMPLATES_DIR/com.test.bringup-schedule.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.test.bringup-schedule</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>-c</string><string>echo ran >> "$T/schedule-marker"</string></array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
# `chmod -R u+w` first: one case makes a parent directory unwritable to force `rm -f` to fail, and
# the suite must still be able to clean up after itself.
trap 'HOME="$T/home" CELL_HOME="$T/home" TEMPLATES_DIR="$T/schedule-templates" python3 "$HERE/fleet-schedule.py" --stop >/dev/null 2>&1; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

if [ -f "$BRINGUP" ]; then ok "shipped script present: cloud-cell-bringup.sh"
else bad "missing $BRINGUP"; echo; echo "  PASS=$PASS FAIL=$FAIL"; exit 1; fi

# ── stubbed toolchain (no network, no real gh, no real pi) ───────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
for c in node uv tmux docker; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
# `python3` is deliberately NOT stubbed. The operational layer's installer parses the farm set out
# of setup.sh, reads the ship-list out of manifest.json and merges settings.json with the REAL
# python3 — a no-op stub makes it parse nothing and refuse loudly by its own floor (which is the
# right answer on a cell without python3, so this suite runs against the host's interpreter).
# `npm` is stubbed because the layer installs each extension's declared dependencies: no network,
# and a POPULATED `node_modules` is what the installer reads back as "dependencies present" (a real
# `npm install` writes the lockfile it resolved, and an empty directory is refused by --verify).
printf '#!/bin/sh\nmkdir -p node_modules\necho x > node_modules/.package-lock.json\nexit 0\n' > "$STUB/npm"
# `git --version` is parsed for a version; `git -C <repo> rev-parse --short HEAD` is echoed into the
# "repo present" line. `git -C <repo> config …` output is ignored.
printf '#!/bin/sh\ncase "$1" in --version) echo "git version 2.39.0";; *) echo abc1234;; esac\n' > "$STUB/git"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "0.85.1"; else echo "LANE_READY"; fi\n' > "$STUB/pi"
# check_provider wraps the probe in `timeout 120 pi …`; GNU timeout is not on every dev box (macOS
# has none), so it is stubbed here rather than assumed.
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$STUB/timeout"
# rm shim — delegates to the real rm, but PARKS first when RM_STUB_SLOW is set, so a case can deliver
# a second signal while the EXIT trap's cleanup is genuinely in flight. Leave RM_STUB_SLOW unset and
# it is transparent.
printf '#!/bin/sh\ncase "$*" in\n  *.gh-tok*) if [ -n "${RM_STUB_SLOW:-}" ]; then [ -n "${RM_STUB_MARK:-}" ] && : > "$RM_STUB_MARK"; sleep 2; fi ;;\nesac\nexec /bin/rm "$@"\n' > "$STUB/rm"
# check_network reads the http_code from stdout. `slow` parks the script there so a SIGTERM can be
# delivered while it is genuinely in flight (and writes a marker so the test does not race startup).
printf '#!/bin/sh\ncase "${CURL_STUB_MODE:-normal}" in\n  fail) echo 000 ;;\n  slow) : > "$CURL_STUB_MARK"; sleep 2; echo 200 ;;\n  *) echo 200 ;;\n  esac\n' > "$STUB/curl"
# A gh that can be told to reject the token. Failing `auth login` is the shape the issue measured.
printf '#!/bin/sh\nmode="${GH_STUB_MODE:-ok}"\ncase "$1 $2" in\n  "auth login")   [ "$mode" = fail ] && exit 1; exit 0 ;;\n  "auth status")  exit 0 ;;\n  "api user")     echo tester; exit 0 ;;\n  "api repos"*)   echo true; exit 0 ;;\nesac\nexit 0\n' > "$STUB/gh"
chmod +x "$STUB"/*   # glob, not an explicit "$STUB/git" "$STUB/pi" … list: the main-worktree-guard's script
                     # walker reads the literal token "$STUB/git" + a following $VAR as a NON-STATIC `git`
                     # invocation and fails closed, blocking the suite from running at all.

# ── fixtures: a HOME, a pre-existing clone (so check_repo never reaches the network), a keys.env ──
mkdir -p "$T/home" "$T/cell/.git" "$T/tok"
printf 'DEEPSEEK_API_KEY=fake\n' > "$T/keys.env"
TOK="$T/tok/.gh-tok"
printf 'ghp_FAKE_PUSH_CAPABLE_TOKEN\n' > "$TOK"   # (re-created per case; asserted deleted after)
TOK_BODY="$(cat "$TOK")"

# check_dispatch (agent-infra#1736) runs the REAL `refresh-candidates.sh --check` whenever the
# harness is resolvable, which it is from a full checkout — and this suite's fixture clone has no
# tools/collision_preflight.py, so the real check dies before the banner and every case that expects
# a clean run goes red. HARNESS is the documented override: pinning it at a non-existent directory
# takes check_dispatch's `warn … return 0` path, keeping this suite about #1718's secret lifetime
# and not about whether the fixture repo can be provisioned for dispatch. Exported so it reaches
# `br()` and every inline invocation below (they add vars as a command prefix, which does not clear
# the already-exported environment).
export HARNESS="$T/no-harness"

# br <gh-mode> <curl-mode> [extra args…] — run the REAL script with the stub toolchain. Capture rc
# in BR_RC and combined output in BR_OUT, exactly as cloud-cell-supervisor.test.sh does.
BR_RC=0; BR_OUT=''
br() {
  BR_OUT="$(PATH="$STUB:$PATH" \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
            GH_TOKEN_FILE="$TOK" GH_STUB_MODE="$1" CURL_STUB_MODE="$2" \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" "${@:3}" 2>&1)"
  BR_RC=$?
}

# ── 1) the measured defect: a REJECTED token ─────────────────────────────────────────────────────
say_case "gh auth login FAILS (the measured #1718 shape)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br fail normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) on a failed login" \
                   || bad "bring-up returned 0 on a failed login"
[ ! -e "$TOK" ] && ok "token file REMOVED after the failed login" \
                || bad "token file SURVIVED a failed login — a push-capable credential left on the VM"
case "$BR_OUT" in
  *"gh auth failed"*) ok "the failure names the login that failed" ;;
  *) bad "the failure does not name the login — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness on a failed login" ;;
  *) ok "never claims CELL READY on a failed login" ;;
esac

# ── 2) NON-VACUITY: the clean path still works, and really deletes a present token ───────────────
say_case "clean run (must NOT be broken by the cleanup)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "bring-up still exits 0 on a clean run" \
                   || bad "clean run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"CELL READY"*) ok "a clean run still reaches CELL READY" ;;
  *) bad "a clean run no longer reaches CELL READY — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "token file removed on the success path (as before the fix)" \
                || bad "token file SURVIVED a successful run"

# ── 2b) a cell that ALREADY carries the layer is a read-back, not a re-install (#1723) ───────────
# `--check` verifies first and only installs when the read-back refuses, so a re-run against a
# provisioned cell must not re-copy the layer. The discriminator is the installer's own mode
# banner: "mode=--verify" on the fast path, "mode=--install" if it re-installed.
say_case "second clean run — the layer is verified, not re-installed"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "the second clean run still exits 0" \
                   || bad "second clean run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"mode=--install"*) bad "the second run RE-INSTALLED the layer instead of verifying it" ;;
  *"mode=--verify"*) ok "the second run certified the existing layer by reading it back (no install)" ;;
  *) bad "the second run never reported a verify of the layer — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "the token is removed on the second run too" \
                || bad "token file SURVIVED the second clean run"

# ── 2c) the SCHEDULED layer (#1864): a cell that comes up has jobs that RUN ──────────────────────
# The measured defect was a whole layer that never reached the cells (10 plists, 0 live) and no
# instrument that said so. The acceptance is therefore a RUN, not a loaded unit or a present file:
# a stamp with an rc plus a fresh log line, produced by the job itself.
say_case "the scheduled layer is installed AND proven by a run (#1864)"
printf '%s\n' "$TOK_BODY" > "$TOK"
# Make the fixture job DUE again: it already ran on the earlier clean runs and its interval is an
# hour, so without clearing the stamp this case would assert on a job that had nothing to do — and
# pass for the wrong reason. (A never-run job is due immediately, which is the same path a fresh
# cell takes.)
rm -f "$T/schedule-marker" \
      "$T/home/.pi/agent/state/fleet-schedule/jobs/com.test.bringup-schedule.json"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "bring-up still exits 0 with the scheduled layer" \
                   || bad "bring-up FAILED on the scheduled layer (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"scheduled layer live: SCHEDULE VERIFIED"*) ok "it reports the scheduler's own verified verdict" ;;
  *) bad "no verified schedule verdict in the bring-up output — output: $BR_OUT" ;;
esac
[ -f "$T/schedule-marker" ] && ok "the declared job actually RAN during bring-up (its own marker exists)" \
                            || bad "no job ran — 'scheduled' would be believed, not proven"
log="$T/home/.pi/agent/state/fleet-schedule/logs/com.test.bringup-schedule.log"
grep -q 'fleet-schedule run com.test.bringup-schedule start' "$log" 2>/dev/null \
  && ok "the run left a fresh log line at $log" || bad "no run log line at $log"
[ ! -e "$TOK" ] && ok "the token is still removed on this path" || bad "token SURVIVED the scheduled-layer run"

# ── 2d) a scheduled layer that cannot be honoured REFUSES the cell ──────────────────────────────
# A "CELL READY" over a cell with no reaping/liveness/canary is the false PASS this whole script
# exists to remove, so a broken declaration must be fatal. The broken job's target does not exist —
# the same rule install-launchd.sh applies to a plist ("a dead job must never be installed").
say_case "a broken job declaration refuses the cell (no false CELL READY)"
BROKENDIR="$T/schedule-broken"
mkdir -p "$BROKENDIR"
printf '# fixture: nothing retired\n' > "$BROKENDIR/RETIRED"
cat > "$BROKENDIR/com.test.broken.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.test.broken</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>{{HOME}}/.pi/agent/scripts/cell-bringup-1864-missing.sh</string></array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
printf '%s\n' "$TOK_BODY" > "$TOK"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
          GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=normal TEMPLATES_DIR="$BROKENDIR" \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) on an unhonourable job set" \
                   || bad "bring-up returned 0 over a job set it could not schedule"
case "$BR_OUT" in
  *"broken target"*) ok "the failure names the broken target" ;;
  *) bad "the failure is not diagnosable — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness with no working scheduled layer" ;;
  *) ok "never claims CELL READY with a broken schedule" ;;
esac

# ── 3) an abort BEFORE check_gh is reached — the window the pre-fix code left open ───────────────
# The removal used to live INSIDE check_gh, and there was no trap, so a failure in check_tools or
# check_network left the pushed token on disk for as long as the VM existed.
say_case "abort between the push and check_gh (github unreachable)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok fail --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when github is unreachable" \
                   || bad "bring-up returned 0 with github unreachable"
case "$BR_OUT" in
  *"cannot reach github.com"*) ok "it died at check_network (check_gh was never reached)" ;;
  *) bad "did not fail at check_network — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "token REMOVED although check_gh was never reached" \
                || bad "token SURVIVED an abort that happened before check_gh"

# ── 4) the non-`die` exit path: an unknown mode exits 2 ──────────────────────────────────────────
say_case "unknown mode (the exit-2 path, not a die)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --bogus
[ "$BR_RC" -eq 2 ] && ok "bring-up exits 2 on an unknown mode" || bad "expected rc=2, got $BR_RC"
[ ! -e "$TOK" ] && ok "token REMOVED on the unknown-mode exit" \
                || bad "token SURVIVED the unknown-mode exit"

# ── 5) SIGTERM: the cleanup must RUN — the 143 alone is not the proof ──────────────────────────
say_case "SIGTERM while the run is in flight"
printf '%s\n' "$TOK_BODY" > "$TOK"
rm -f "$T/curl-started"
PATH="$STUB:$PATH" CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
  GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=slow CURL_STUB_MARK="$T/curl-started" \
  REPO_SLUG="daniel-ospina/tortoise" \
  bash "$BRINGUP" --check > "$T/term.out" 2>&1 &
TERM_PID=$!
# Kill only once the script is provably in flight (the curl stub has started), so the TERM cannot
# land before the trap is installed — that race would fail a correct implementation.
i=0
while [ ! -e "$T/curl-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$T/curl-started" ]; then
  bad "the script never reached check_network — cannot test SIGTERM"
  kill -TERM "$TERM_PID" 2>/dev/null
else
  kill -TERM "$TERM_PID" 2>/dev/null
fi
wait "$TERM_PID" 2>/dev/null; TERM_RC=$?
[ "$TERM_RC" -eq 143 ] && ok "the shell reports 143 on TERM" \
                       || bad "expected rc=143 after TERM, got $TERM_RC"
# The real contract is that the trap's cleanup RAN. 143 is a weak signal: an untrapped TERM reaches
# the parent as 143 as well, so the removal log and the token's absence are what this case pins.
case "$(cat "$T/term.out" 2>/dev/null)" in
  *"secret file removed: $TOK"*) ok "the EXIT trap's own cleanup ran on TERM (the real contract)" ;;
  *) bad "no removal log on TERM — the cleanup did not run" ;;
esac
[ ! -e "$TOK" ] && ok "token REMOVED on SIGTERM" || bad "token SURVIVED SIGTERM"

# ── 6) a removal that FAILS must be LOUD and must not report readiness ───────────────────────────
# The pre-fix `rm -f "$tokfile" && ok "token file removed"` printed NOTHING when rm failed, so a
# token that could not be removed fell straight through to the CELL READY banner.
# ⚠️ LIMIT: this case does NOT reproduce the pre-fix defect. The pre-fix script contains no
# GH_TOKEN_FILE at all (grep -c = 0 on 15ee52a's copy) and hardcodes /tmp/.gh-tok, so against that
# copy the case fails because the path is simply IGNORED, not because the removal failed. It is a
# contract test of the shipped implementation (fail-closed on a removal that fails); the
# reproduction of the defect is case 1. The same holds for the unreachable-parent case 8.
say_case "the token file cannot be removed (fail-closed, not fail-open)"
if [ "$(id -u)" = "0" ]; then
  skip "the token file cannot be removed — running as root, a mode-500 parent does not deny rm"
else
  mkdir -p "$T/ro"
  printf '%s\n' "$TOK_BODY" > "$T/ro/.gh-tok"
  chmod 500 "$T/ro"
  BR_OUT="$(PATH="$STUB:$PATH" \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
            GH_TOKEN_FILE="$T/ro/.gh-tok" CURL_STUB_MODE=normal \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" --check 2>&1)"
  BR_RC=$?
  chmod 700 "$T/ro"
  [ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when the token cannot be deleted" \
                     || bad "bring-up returned 0 with the token still on disk"
  case "$BR_OUT" in
    *"could not remove the token file"*) ok "the failure names the file that could not be removed" ;;
    *) bad "the failed removal is not reported — output: $BR_OUT" ;;
  esac
  [ "$(printf '%s\n' "$BR_OUT" | grep -c 'SECURITY:')" -eq 1 ] \
    && ok "the failure is reported exactly once (the pre-banner refusal and the EXIT trap do not double-report)" \
    || bad "the SECURITY report was duplicated or absent — output: $BR_OUT"
  case "$BR_OUT" in
    *"CELL READY"*) bad "CLAIMED readiness with the token still on disk (fail-open)" ;;
    *) ok "never claims CELL READY while the token is still on disk" ;;
  esac
  chmod 700 "$T/ro" 2>/dev/null
  rm -f "$T/ro/.gh-tok" 2>/dev/null
  rmdir "$T/ro" 2>/dev/null
fi

# ── 7) a keys.env that tries to DISARM the cleanup ──────────────────────────────────────────────
# $ENV_FILE is arbitrary shell, and the cleanup lives in a trap in the SAME shell that sources it.
# One line, `trap - EXIT`, removes the handler and the pushed token then outlives the run — the
# #1713 guard cannot see it (the file parses, and it does not end with a top-level exit), so the
# handlers must be (re-)asserted after the source.
say_case "keys.env disarms the cleanup with 'trap - EXIT'"
if [ -f "$T/keys-trap.env" ]; then :; fi
printf 'DEEPSEEK_API_KEY=fake\ntrap - EXIT\n' > "$T/keys-trap.env"
printf '%s\n' "$TOK_BODY" > "$TOK"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys-trap.env" \
          GH_TOKEN_FILE="$TOK" GH_STUB_MODE=fail CURL_STUB_MODE=normal \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up still exits non-zero ($BR_RC) with the trap-disarming keys.env" \
                   || bad "bring-up returned 0 with a trap-disarming keys.env"
[ ! -e "$TOK" ] && ok "token REMOVED although keys.env ran 'trap - EXIT'" \
                || bad "token SURVIVED — keys.env disarmed the EXIT trap"

# ── 8) a token whose parent denies TRAVERSAL (stat cannot see it) ───────────────────────────────
# `[ -e ]`/`[ -f ]` are FALSE for a file under a directory with no +x — the same answer they give
# for an absent file. A cleanup that gates on that stat (the first version of this fix did)
# therefore skipped the removal, printed nothing, and reached CELL READY with the credential still
# on disk. `rm -f`'s own status is the fail-closed signal.
say_case "the token's parent denies traversal (present but unstatable)"
if [ "$(id -u)" = "0" ]; then
  skip "the token's parent denies traversal — running as root bypasses directory permission checks"
else
  mkdir -p "$T/nox"
  printf '%s\n' "$TOK_BODY" > "$T/nox/.gh-tok"
  chmod 400 "$T/nox"
  BR_OUT="$(PATH="$STUB:$PATH" \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
            GH_TOKEN_FILE="$T/nox/.gh-tok" CURL_STUB_MODE=normal \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" --check 2>&1)"
  BR_RC=$?
  chmod 700 "$T/nox"
  [ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when the credential cannot be reached" \
                     || bad "bring-up returned 0 for a token it could not even stat"
  case "$BR_OUT" in
    *"SECURITY:"*) ok "the unreachable credential is reported loudly" ;;
    *) bad "the unreachable credential was IGNORED silently — output: $BR_OUT" ;;
  esac
  [ "$(printf '%s\n' "$BR_OUT" | grep -c 'SECURITY:')" -eq 1 ] \
    && ok "reported exactly once (the refusal and the EXIT trap do not double-report)" \
    || bad "the SECURITY report was duplicated or absent — output: $BR_OUT"
  case "$BR_OUT" in
    *"CELL READY — all links verified"*) bad "CLAIMED readiness while the credential was still on disk (fail-open)" ;;
    *) ok "never claims CELL READY while the credential is still on disk" ;;
  esac
  [ -e "$T/nox/.gh-tok" ] && ok "the suite's fixture is still present (the failure was the script's)" \
                          || bad "the fixture vanished — the case did not test what it claims"
  rm -f "$T/nox/.gh-tok" 2>/dev/null
  rmdir "$T/nox" 2>/dev/null
fi

# ── 9) a SECOND signal while the cleanup is running must not abort it ────────────────────────────
# The EXIT trap IGNORES INT/TERM/HUP/PIPE for the duration of the cleanup. Without that, a second signal
# kills the shell mid-loop and the remaining secrets stay on disk — silently, because a survivor
# changes nothing the operator can see. The `rm` shim parks so the window is real, not theoretical.
# The discriminator is the trap's own REMOVAL LOG: a shell killed mid-cleanup never reaches it (the
# shim's child may still unlink the file), so asserting only the token's absence would pass for the
# wrong reason.
say_case "a second signal during the cleanup cannot abort it"
printf '%s\n' "$TOK_BODY" > "$TOK"
rm -f "$T/curl-started" "$T/rm-started"
PATH="$STUB:$PATH" CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
  GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=slow CURL_STUB_MARK="$T/curl-started" \
  RM_STUB_SLOW=1 RM_STUB_MARK="$T/rm-started" \
  REPO_SLUG="daniel-ospina/tortoise" \
  bash "$BRINGUP" --check > "$T/twice.out" 2>&1 &
TWICE_PID=$!
i=0
while [ ! -e "$T/curl-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$TWICE_PID" 2>/dev/null   # signal 1 — kills the shell, which runs the EXIT trap
i=0
while [ ! -e "$T/rm-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$T/rm-started" ]; then
  bad "the cleanup never started — the second-signal window could not be tested"
else
  kill -TERM "$TWICE_PID" 2>/dev/null # signal 2 — lands INSIDE the cleanup
fi
wait "$TWICE_PID" 2>/dev/null
case "$(cat "$T/twice.out" 2>/dev/null)" in
  *"secret file removed: $TOK"*) ok "the cleanup COMPLETED through the second signal (removal logged)" ;;
  *) bad "the cleanup was ABORTED by the second signal — nothing logged a removal" ;;
esac
[ ! -e "$TOK" ] && ok "the token is gone after the second signal" || bad "the token SURVIVED the second signal"

# ── 10) a DEAD STDOUT while the cleanup is running must not truncate it ──────────────────────────
# The cleanup LOGS every removal to stdout, and a log write to a pipe whose reader is gone raises
# SIGPIPE. If that signal is not ignored for the duration of the cleanup it kills the shell mid-loop
# and every registered secret AFTER the current one stays on disk — silently, because a survivor the
# operator is never told about changes nothing they can see. Reproduced on bash 3.2.57 with
# INT/TERM/HUP ignored and two registered secrets: A removed, B LEFT.
# ⚠️ This sources the SHIPPED definitions (only the final `main "$@"` line is stripped): the shipped
# CLI path registers exactly ONE secret, so a second entry cannot be exercised through it — and the
# file explicitly invites registering another. The cleanup code under test is the shipped cleanup.
say_case "a dead stdout during the cleanup cannot truncate it (two registered secrets)"
LIB="$T/bringup-defs.sh"
if [ "$(tail -n 1 "$BRINGUP")" != 'main "$@"' ]; then
  bad "the shipped entry point is no longer the last line — the definitions copy would run main"
else
  sed '$d' "$BRINGUP" > "$LIB"
  SEC_A="$T/tok/.gh-tok"; SEC_B="$T/tok/.second-tok"
  printf '%s\n' "$TOK_BODY" > "$SEC_A"
  printf '%s\n' "$TOK_BODY" > "$SEC_B"
  (
    GH_TOKEN_FILE="$SEC_A"     # what the lib's top-level `register_secret` picks up (entry 1)
    . "$LIB"
    register_secret "$SEC_B"   # entry 2
    exec 1> >(exec true)       # stdout becomes a pipe whose reader is about to be gone
    sleep 1                    # ...provably gone before the trap logs its first removal
    exit 0
  ) 2>/dev/null
  DEAD_RC=$?
  [ ! -e "$SEC_A" ] && ok "the FIRST registered secret was removed" \
                    || bad "the first registered secret SURVIVED the dead-stdout cleanup (rc=$DEAD_RC)"
  [ ! -e "$SEC_B" ] && ok "the SECOND registered secret was removed (the loop reached the end)" \
                    || bad "the second registered secret SURVIVED — a dead stdout truncated the cleanup (rc=$DEAD_RC)"
fi

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL SKIPPED=$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "  ⚠️  $SKIP case(s) SKIPPED above — the fail-closed removal contract was NOT exercised on this"
  echo "      host. A green run here is partial coverage, not a verified contract."
fi
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
if [ "$SKIP" -gt 0 ]; then
  echo "  ⛔ $SKIP contract case(s) were SKIPPED: this host cannot exercise the fail-closed removal"
  echo "     contract (root bypasses directory permissions). That is NOT a pass — run as a non-root"
  echo "     user. Exiting non-zero so a green shard can never mean 'unverified'."
  exit 1
fi
echo "  ✅ all checks passed"
exit 0
