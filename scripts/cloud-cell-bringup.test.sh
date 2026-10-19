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
# #2100 (the capture extension), added here because the two mechanisms meet in `--check`:
#   * the PROVIDER PROBE reads the provider, not the extension layer — a noisy layer (the measured
#     banner-only shape: `[tortoise-capture] …`, no answer) must NOT turn a healthy provider into
#     `FATAL: provider probe failed`. The stub `pi` reproduces that shape, and the probe's OWN
#     two-probe contract is what is pinned: layer-loaded first, `--no-extensions` second to
#     ATTRIBUTE. So the noisy case must (i) report no provider failure, (ii) NAME the layer as the
#     culprit, and (iii) a broken key must still be blamed on the provider in every mode. Reordering
#     or dropping either probe turns one of those red (the cases prove the fixture emits no
#     LANE_READY with the layer loaded and DOES answer in isolation, so none can pass vacuously);
#   * a cell that CARRIES `tortoise-capture` fails the installer's read-back at the named (b) call
#     (`capture extension present on a cell: …`) and `--check` SURFACES that line — it used to
#     discard the verify output entirely, so the reason the box kept re-breaking itself appeared
#     nowhere in the log. The run then repairs the cell (that IS the fix: the deny removes it), and
#     the evidence asserted here is the named line plus the extension's absence — never a claim of
#     readiness over a failed read-back;
#   * with the extension ABSENT and the provider healthy, `--check` reports NO provider failure.
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
# `chmod -R u+w` first: one case makes a parent directory unwritable to force `rm -f` to fail, and
# the suite must still be able to clean up after itself.
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

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
# The probe stub also has to be able to reproduce the MEASURED #2100 shape: a layer that emits banner
# lines and NEVER reaches the model, so the output carries no answer at all. It only answers when the
# probe asks for a provider with extensions DISABLED (`--no-extensions`). That is what makes the
# two-probe contract testable: the provider verdict comes from the ISOLATED probe, and the LAYER
# probe goes red on this fixture — so the run must FAIL naming the layer, and must NOT report a
# provider failure. `broken` models the other attribution: the provider itself rejects the key in
# EVERY mode, so the run dies on the 401 arm. `echoargv` prints its own argv and never reaches a
# model — the vacuous-pass shape the answer extractor must refuse. `PI_STUB_LOG`, when set, records
# one line per model call, so a case can prove how many probes actually ran.
cat > "$STUB/pi" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "0.85.1"; exit 0; }
[ -n "${PI_STUB_LOG:-}" ] && echo call >> "$PI_STUB_LOG"
has_ne=0
for a in "$@"; do [ "$a" = "--no-extensions" ] && has_ne=1; done
if [ "${PI_STUB_MODE:-normal}" = broken ]; then
  printf '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = echoargv ]; then
  printf 'Reply with exactly: LANE_READY\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = noisy ] && [ "$has_ne" -eq 0 ]; then
  printf '[tortoise-capture] install probe recorded (harness=pi)\n'
  printf '[tortoise-capture] spool flush (session_start): filed 0, deferred 2, skipped 320 (320 waiting on backoff)\n'
  exit 0
fi
echo LANE_READY
STUB
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
# ── the disk-reaper timer installer (#2032) ──────────────────────────────────────────────────────
# The bring-up now INSTALLS an hourly systemd timer. This suite must never touch the real
# /etc/systemd/system, so the unit dir is redirected to a fixture dir and `systemctl` is the shim
# below: an installer that reaches the real systemd during a test is a test that can change the host.
# SYSTEMCTL_STUB_MODE=fail makes `daemon-reload`/`enable` refuse, which is the shape of a cell whose
# scheduler cannot be armed — the bring-up must refuse that cell rather than certify it.
export SYSTEMD_UNIT_DIR="$T/systemd-units"
export SYSTEMCTL="$STUB/systemctl"
printf '#!/bin/sh\ncase "$*" in\n  *is-enabled*) echo enabled ;;\n  *is-active*) echo active ;;\n  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;\n  *show*) echo 0 ;;\n  *enable*|*daemon-reload*) [ "${SYSTEMCTL_STUB_MODE:-ok}" = fail ] && exit 1; exit 0 ;;\n  *) exit 0 ;;\nesac\n' > "$STUB/systemctl"
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
# The probe count is part of the contract: a healthy box makes TWO model calls — the isolated
# PROVIDER verdict and one layer-loaded turn — and the layer check must NOT be retried when it
# answers. A regression that re-runs the layer probe (or drops either one) shows up here.
PI_CALLS="$T/pi-calls.log"; : > "$PI_CALLS"
PI_STUB_LOG="$PI_CALLS" br ok normal --check
[ "$(grep -c . "$PI_CALLS")" -eq 2 ] && ok "a healthy run makes exactly 2 model calls (isolated verdict + one layer turn)" \
  || bad "a healthy run made $(grep -c . "$PI_CALLS") model calls, expected 2 (isolated provider verdict + one layer-loaded turn, no retry on success)"
[ "$BR_RC" -eq 0 ] && ok "bring-up still exits 0 on a clean run" \
                   || bad "clean run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"the extension layer answers a lane-shaped turn"*) ok "the layer-loaded turn is measured and reported (the detector is live on a healthy box)" ;;
  *) bad "a clean run never reports the layer-loaded turn — the layer detector is inert: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) ok "a clean run still reaches CELL READY" ;;
  *) bad "a clean run no longer reaches CELL READY — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "token file removed on the success path (as before the fix)" \
                || bad "token file SURVIVED a successful run"
# #1987 — the machine-global package caches are REPORTED by --check, so a growing disk is visible
# BEFORE it stops dispatch (measured: pi-cell-3 refused every dispatch at 258MB free while a 7.1GB
# ~/.cache/uv went unreported). Report-only by design: a cache over its bound must not refuse a
# cell that has room, so this asserts the LINE, not a failure.
case "$BR_OUT" in
  *"caches:"*) ok "bring-up REPORTS the machine-global package caches (#1987)" ;;
  *) bad "bring-up does not report the package caches — a disk sink is invisible again (#1987): $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"per cache, source "*) ok "the cache report carries the bound AND where it came from (an operator can see what 'too big' means, and whether the plist or this environment set it)" ;;
  *) bad "the cache report does not name the bound and its source: $BR_OUT" ;;
esac

# #2032 — the disk reaper is SCHEDULED by the bring-up, not merely reported. Disk exhaustion is the
# second reason cells stopped working: at ~97% used a controller still beats and every dispatch is
# refused, so a report-only check leaves the box to die on a clock.
case "$BR_OUT" in
  *"disk reaper scheduled"*) ok "bring-up INSTALLS and reports the disk reaper timer (#2032)" ;;
  *) bad "bring-up does not schedule the disk reaper — the sinks are unbounded again: $BR_OUT" ;;
esac
if [ -f "$T/systemd-units/eldato-disk-reaper.timer" ]; then
  ok "the timer unit was rendered and installed"
else
  bad "no timer unit was installed under $T/systemd-units"
fi
if grep -q -- '--apply' "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null; then
  ok "the installed pass is ARMED (--apply), as this feature was instructed to be"
else
  bad "the installed unit is not armed — it would only ever report"
fi
if grep -q 'Environment=DISK_REAPER_REPOS=' "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null; then
  ok "the unit carries the repos the venv/worktree classes scan"
else
  bad "the unit carries no DISK_REAPER_REPOS — those classes would fail closed every hour"
fi

say_case "a cell whose reaper timer cannot be ENABLED is refused (not certified)"
printf '%s\n' "$TOK_BODY" > "$TOK"
SYSTEMCTL_STUB_MODE=fail br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero when the timer cannot be enabled (rc=$BR_RC)" \
                   || bad "bring-up returned 0 with an un-armable timer"
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness on a cell whose disk reaper is not scheduled" ;;
  *) ok "does not claim CELL READY when the reaper is unscheduled" ;;
esac

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

# ── 2c) a NOISY layer cannot turn a healthy provider into a provider failure (#2100) ─────────────
# Measured 2026-10-19 (#2100 — one box unusable while two ran lanes, the extension present on all
# three): the affected cell's `tortoise-capture` consumed the turn and every turn ended with
# banner-only output (259-262 B). The provider probe read `… | tail -3` of `pi -p` with the whole
# extension layer loaded, so those banner lines BECAME the answer and a healthy box was refused with
# `FATAL: provider probe failed` (`pi` returned LANE_READY once the extension was gone).
# The contract now: the PROVIDER verdict comes from the ISOLATED probe first (nothing in the layer
# can answer for it), and the layer-loaded turn is measured separately, twice. So a noisy layer
# cannot produce a provider failure — and it cannot certify the cell either, because a layer that
# produces no answer in two attempts IS a cell that cannot run a lane.
say_case "a noisy extension layer cannot produce a provider failure (#2100)"
# NON-VACUITY first: the fixture really is the measured shape — asked WITH the layer, it emits banner
# lines and no answer, which is exactly what used to be read as "the provider is broken".
probe_out="$(PATH="$STUB:$PATH" PI_STUB_MODE=noisy "$STUB/pi" -p --no-session \
              'Reply with exactly: LANE_READY' 2>&1)"
case "$probe_out" in
  *LANE_READY*) bad "the noisy fixture still answers — this case would pass for the wrong reason" ;;
  *) ok "the fixture reproduces the measured shape: banner-only output, no provider answer" ;;
esac
# ... and the OTHER half: the same fixture DOES answer when the probe isolates, which is what makes
# the verdict "the layer, not the provider" (and not "everything is broken").
probe_iso="$(PATH="$STUB:$PATH" PI_STUB_MODE=noisy "$STUB/pi" -p --no-session --no-extensions \
              'Reply with exactly: LANE_READY' 2>&1)"
case "$probe_iso" in
  *LANE_READY*) ok "the same fixture answers with extensions disabled — the layer is the culprit, provably" ;;
  *) bad "the fixture does not answer even in isolation — the attribution below would be vacuous" ;;
esac
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=noisy br ok normal --check
case "$BR_OUT" in
  *"provider probe failed"*) bad "a NOISY layer turned a healthy provider into a provider failure — the probe is not isolated: $BR_OUT" ;;
  *) ok "the probe reports NO provider failure while the layer emits banner lines" ;;
esac
# The detector must be LIVE, not merely absent: the isolated probe proved the provider healthy, so the
# run has to NAME the layer and state that the provider is not the problem.
case "$BR_OUT" in
  *"the PROVIDER is healthy"*) ok "the failure states the provider is healthy (the layer is the culprit)" ;;
  *) bad "the layer swallowed the turn and the failure does not name the attribution: $BR_OUT" ;;
esac
[ "$BR_RC" -ne 0 ] && ok "the run FAILS on a layer that produces no answer (rc=$BR_RC)" \
                   || bad "the run reported success over a layer that cannot complete a turn"
case "$BR_OUT" in
  *"CELL READY"*) bad "CELL READY was claimed over a box whose turns produce no answer — the mirror false PASS" ;;
  *) ok "no readiness banner is claimed over a layer that cannot complete a turn" ;;
esac

# ── 2c1) an ECHO cannot satisfy either probe: no vacuous pass on the instruction text ─────────────
# The instruction itself contains the token, so a `pi` (or a wrapper) that prints its own argv would
# answer the probe with no model call. The extractor drops a byte-identical echo line; both probes
# must therefore read "no answer" and the run must fail as a provider failure.
say_case "an echoed instruction cannot pass the probe (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=echoargv br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "the run FAILS when the only 'answer' is the echoed instruction" \
                   || bad "an echo of the instruction satisfied the probe — vacuous pass"
case "$BR_OUT" in
  *"provider probe failed"*) ok "the echoed instruction is reported as NO provider answer" ;;
  *) bad "the echoed instruction was not classified as a missing answer: $BR_OUT" ;;
esac

# ── 2c2) a BROKEN provider is still blamed on the provider, whatever the layer does ──────────────
# The two-probe contract must not turn a genuinely dead key into a layer finding. With the provider
# rejecting in EVERY mode (isolated included), the 401 arm is authoritative — this is the case that
# goes red if the isolated probe is ever demoted behind the layer probe or skipped.
say_case "a rejecting provider is still a provider failure, layer or no layer (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=broken br ok normal --check
case "$BR_OUT" in
  *"provider key REJECTED (401)"*) ok "the run blames the PROVIDER when the key is rejected in every mode" ;;
  *) bad "a rejecting provider was not reported as a provider failure — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"the PROVIDER is healthy"*) bad "a dead key was mis-attributed to the extension layer" ;;
  *) ok "no layer attribution is emitted when the provider is the culprit" ;;
esac
[ "$BR_RC" -ne 0 ] && ok "the run FAILS on a rejecting provider" \
                   || bad "the run reported success over a rejecting provider"

# ── 2d) a cell that CARRIES the capture extension: the read-back fails, and --check NAMES it ────
# This is the provisioning half of #2100. The extension is still in the manifest ship-list, so a
# bare bringup re-ships it; the deny in cell-install.sh is what keeps it off the cell, and its
# `--verify` half must REFUSE a cell that carries it. `--check` used to DISCARD the verify output
# (`out` was overwritten by the install) — so the operator saw "the cell does not carry a current
# layer" and never the artifact that was wrong, while the next bringup put the extension back.
# The line below is the whole diagnosis, and it is asserted on its EXACT wording.
say_case "a cell carrying tortoise-capture fails the read-back, and --check names it (#2100)"
CAPTURE_LINE='capture extension present on a cell: it blocks session_start and corrupts the provider probe'
mkdir -p "$T/home/.pi/agent/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$T/home/.pi/agent/extensions/tortoise-capture/index.ts"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
case "$BR_OUT" in
  *"$CAPTURE_LINE"*) ok "--check surfaces the (b) failure verbatim: $CAPTURE_LINE" ;;
  *) bad "--check never names the capture extension — the read-back's refusal is still swallowed: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"provider probe failed"*) bad "the run blamed the PROVIDER — the extension's banner corrupted the probe again" ;;
  *) ok "the failure is attributable to the extension (b), not to the provider probe" ;;
esac
[ ! -e "$T/home/.pi/agent/extensions/tortoise-capture" ] \
  && ok "the run REMOVED the extension (the deny repairs a cell that carries it, instead of certifying it)" \
  || bad "the capture extension SURVIVED the bringup — it would block every lane turn again"
[ "$BR_RC" -eq 0 ] && ok "readiness is reported only AFTER the read-back refused and the repair removed it" \
                   || bad "the run failed after the repair (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"CELL READY"*) ok "the repaired cell reaches CELL READY" ;;
  *) bad "the repaired cell never reaches CELL READY — output: $BR_OUT" ;;
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
