#!/usr/bin/env bash
# install-launchd.test.sh — self-check for scripts/install-launchd.sh + the
# templates/launchd/ versioned plist templates (agent-infra #304).
#
# Run: bash scripts/install-launchd.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds a
# throwaway fake HOME + fake templates dir + fake `launchctl` shim in a temp
# dir — never touches the real ~/Library/LaunchAgents or real launchd.
#
# Coverage (issue #304 test plan + #432 retirement):
#   fresh-HOME simulation  all ACTIVE jobs installed with substituted paths;
#                          retired jobs (hub-state-check, skill-lint-oracle)
#                          never installed
#   retirement             pre-seeded retired plists unloaded + removed
#   render determinism     same env → byte-identical output
#   idempotent skip        second run: "unchanged", no bootout/bootstrap
#   change → reload        template bump → reinstall + one new bootstrap
#   bootstrap failure      shim FAILS bootstrap → installer exits 1, loud
#   broken-target guard    missing script → refuse, exit 1, no install
#   placeholder skip       no swarm root → canary skipped (exit 0), tripwire ok
#   temp-HOME guard (#446) HOME ≠ real home, no override → refuse install AND
#                          --uninstall before any launchctl call (zero calls);
#                          override + shim → isolated install proceeds
#   --status               installed/loaded/drift reporting
#   --uninstall            bootout + remove; re-run reports NOT INSTALLED
#   template lint          plutil -lint the rendered plists (when plutil exists)
#
# Vehicle job for reload/fail/broken-target/status sections = the latency
# tripwire (com.eldato.provider-latency-tripwire, StartInterval 3600); the
# canary (StartInterval 900) is the swarm-root-conditional job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-launchd.sh"
REPO_TEMPLATES="$SCRIPT_DIR/../templates/launchd"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

# ── scaffold ──────────────────────────────────────────────────────────────
T="$(mktemp -d /tmp/install-launchd-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# Fake launchctl: logs every invocation; bootstrap fails when FAKE_BOOTSTRAP_FAIL set.
mkdir -p "$T/bin"
cat > "$T/bin/launchctl" <<'SHIM'
#!/usr/bin/env bash
echo "launchctl $*" >> "${FAKE_LAUNCHCTL_LOG:?}"
case "$1" in
    bootstrap)
        if [ -n "${FAKE_BOOTSTRAP_FAIL:-}" ]; then
            echo "bootstrap failed (simulated)" >&2
            exit 1
        fi ;;
    print)
        # "loaded" always in the fake domain
        [ -n "${FAKE_JOB_NOT_LOADED:-}" ] && exit 1 ;;
esac
exit 0
SHIM
chmod +x "$T/bin/launchctl"

# Deterministic fake real-home for the #446 temp-HOME guard: makes the
# refusal path CI-portable. Ubuntu runners have no dscl, so the guard would
# fail open there and section 11's refusal assertions would fail (install
# proceeds). The stub keeps the guard firing on EVERY platform whenever HOME
# is a temp dir (real_home=/test-real-home never equals a temp HOME). All
# other sections run with ELDATO_ALLOW_TEST_HOME=1 (guard bypassed), so the
# stub only affects the refusal section. Output mirrors real dscl's
# "NFSHomeDirectory: <path>" one-liner the installer parses.
cat > "$T/bin/dscl" <<'SHIM'
#!/usr/bin/env bash
echo "NFSHomeDirectory: /test-real-home"
SHIM
chmod +x "$T/bin/dscl"

# Fake HOME with a farmed scripts dir + a swarm checkout.
mkfakehome() { # $1 = home dir
    mkdir -p "$1/.pi/agent/scripts/checkout-hygiene"
    touch "$1/.pi/agent/scripts/checkout-hygiene/corruption_canary.py"
    touch "$1/.pi/agent/scripts/checkout-hygiene/provider-latency-tripwire.sh"
    touch "$1/.pi/agent/scripts/checkout-hygiene/deepseek-balance-watch.sh"  # #476 poller
    chmod +x "$1/.pi/agent/scripts/checkout-hygiene/corruption_canary.py"
    chmod +x "$1/.pi/agent/scripts/checkout-hygiene/provider-latency-tripwire.sh"
    chmod +x "$1/.pi/agent/scripts/checkout-hygiene/deepseek-balance-watch.sh"
    # #373 fleet-cadence farm + #469 pi-session-reaper + #476 balance-watch
    # (setup.sh copies these to the scripts root): the weekly plist's driver +
    # its sibling report/watch/parser AND the reaper/balance-watch drivers must
    # resolve at
    # install time (broken-target guard).
    mkdir -p "$1/.pi/agent/scripts"
    for f in fleet-cost-weekly.sh fleet-cost-report.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh; do
        touch "$1/.pi/agent/scripts/$f"
        chmod +x "$1/.pi/agent/scripts/$f"
    done
    mkdir -p "$1/swarm/.venv/bin"
    touch "$1/swarm/.venv/bin/python"
    chmod +x "$1/swarm/.venv/bin/python"
    mkdir -p "$1/Library/LaunchAgents"
}

# Retired-job labels: seeds the fake home with their OLD installed plists so
# the retirement pass has something to unload (mirrors real machines that
# installed them pre-retirement — #432).
seed_retired() { # $1 = home dir
    for label in com.eldato.hub-state-check com.eldato.skill-lint-oracle; do
        cat > "$1/Library/LaunchAgents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/x/$label.sh</string></array>
</dict></plist>
EOF
    done
}

# Copies repo templates into a scratch dir (installer's template dir is
# env-overridable; tests mutate the COPY, never the repo).
TEMPLATES="$T/templates"
cp -R "$REPO_TEMPLATES" "$TEMPLATES"

HOME1="$T/home1"; mkfakehome "$HOME1"
HOME2="$T/home2"; mkfakehome "$HOME2"
LOG="$T/launchctl.log"
LOG2="$T/launchctl-retire.log"  # isolated log for the HOME2 retirement section
: > "$LOG"
: > "$LOG2"

run_installer() { # <home> [extra env assignments...]
    (
        export HOME="$1"
        export PATH="$T/bin:$PATH"
        export FAKE_LAUNCHCTL_LOG="$LOG"
        export TEMPLATES_DIR="$TEMPLATES"
        export AGENTS_DIR="$HOME/Library/LaunchAgents"
        export SWARM_ROOT="$HOME/swarm"
        export PYTHON_BIN="$HOME/swarm/.venv/bin/python"
        export ELDATO_ALLOW_TEST_HOME=1  # #446: fake HOME + launchctl shim above = isolated
        shift
        bash "$INSTALLER" "$@"
    )
}

echo "── 1. Fresh-HOME simulation ──────────────────────────────────────"
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "fresh install exits 0"
assert_contains "$OUT" "corruption-canary: installed + loaded" "corruption-canary installed on fresh machine"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "provider-latency-tripwire installed on fresh machine"
assert_contains "$OUT" "fleet-cost-weekly: installed + loaded" "fleet-cost-weekly installed on fresh machine (#373)"
assert_contains "$OUT" "pi-session-reaper: installed + loaded" "pi-session-reaper installed on fresh machine (#469)"
assert_contains "$OUT" "deepseek-balance-watch: installed + loaded" "deepseek-balance-watch installed on fresh machine (#476)"
CANARY_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.corruption-canary.plist"
TRIPWIRE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.provider-latency-tripwire.plist"
FLEET_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.fleet-cost-weekly.plist"
REAPER_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-session-reaper.plist"
DBW_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.deepseek-balance-watch.plist"
HUB_RETIRED="$HOME1/Library/LaunchAgents/com.eldato.hub-state-check.plist"
ORACLE_RETIRED="$HOME1/Library/LaunchAgents/com.eldato.skill-lint-oracle.plist"
assert_contains "$(cat "$CANARY_INSTALLED")" "$HOME1/swarm/.venv/bin/python" "canary plist rendered PYTHON_BIN"
assert_contains "$(cat "$CANARY_INSTALLED")" "--root" "canary plist keeps --root"
assert_contains "$(cat "$CANARY_INSTALLED")" "agent-infra-plist-version: 0.1.0" "canary template carries version marker"
assert_contains "$(cat "$TRIPWIRE_INSTALLED")" "$HOME1/.pi/agent/scripts/checkout-hygiene/provider-latency-tripwire.sh" "tripwire plist rendered with fake HOME"
assert_contains "$(cat "$TRIPWIRE_INSTALLED")" "agent-infra-plist-version: 0.1.0" "tripwire template carries version marker"
assert_contains "$(cat "$FLEET_INSTALLED")" "$HOME1/.pi/agent/scripts/fleet-cost-weekly.sh" "fleet plist rendered with fake HOME (#373)"
assert_contains "$(cat "$FLEET_INSTALLED")" "agent-infra-plist-version: 0.1.0" "fleet template carries version marker"
# #373 — fleet-cost-weekly must run WEEKLY (StartCalendarInterval, not interval)
assert_contains "$(cat "$FLEET_INSTALLED")" "StartCalendarInterval" "fleet job is calendar-scheduled (weekly)"
# #469 — pi-session-reaper rendered-plist content asserts (farmed path,
# ARMED REAP_DRY_RUN=0, hourly StartInterval 3600)
assert_contains "$(cat "$REAPER_INSTALLED")" "$HOME1/.pi/agent/scripts/pi-reap-idle.sh" "reaper plist rendered with fake HOME (farmed path)"
assert_contains "$(cat "$REAPER_INSTALLED")" "REAP_DRY_RUN" "reaper plist carries REAP_DRY_RUN env"
assert_contains "$(cat "$REAPER_INSTALLED")" "<string>0</string>" "reaper plist ARMED (REAP_DRY_RUN=0)"
assert_contains "$(cat "$REAPER_INSTALLED")" "StartInterval" "reaper job is interval-scheduled"
assert_contains "$(cat "$REAPER_INSTALLED")" "<integer>3600</integer>" "reaper job hourly (StartInterval 3600)"
assert_contains "$(cat "$REAPER_INSTALLED")" "agent-infra-plist-version: 0.1.0" "reaper template carries version marker"
assert_contains "$(cat "$DBW_INSTALLED")" "$HOME1/.pi/agent/scripts/checkout-hygiene/deepseek-balance-watch.sh" "balance-watch plist rendered with fake HOME (#476)"
assert_contains "$(cat "$DBW_INSTALLED")" "agent-infra-plist-version: 0.1.0" "balance-watch template carries version marker"
# #476 — the balance poller is the SINGLE restore authority: must run every
# 15min (StartInterval 900, not calendar) and carry the installer PATH (launchd
# default PATH lacks python3/curl used by the poller).
assert_contains "$(cat "$DBW_INSTALLED")" "<integer>900</integer>" "balance-watch runs every 15min (StartInterval 900)"
assert_not_contains "$(cat "$DBW_INSTALLED")" "StartCalendarInterval" "balance-watch is interval-scheduled, not calendar"
assert_contains "$(cat "$DBW_INSTALLED")" "<key>PATH</key>" "balance-watch plist carries an explicit PATH env"
# #432 — hub-state-check + skill-lint-oracle are RETIRED from launchd (their
# work moved to extensions/session-checks.ts — macOS TCC blocks launchd from
# ~/Documents, so they run from pi's session_start instead).
assert_not_contains "$OUT" "hub-state-check: installed + loaded" "retired hub job NOT installed on fresh machine"
assert_not_contains "$OUT" "skill-lint-oracle: installed + loaded" "retired oracle job NOT installed on fresh machine"
[ ! -f "$HUB_RETIRED" ] && ok "no retired hub plist left behind" || bad "no retired hub plist left behind"
[ ! -f "$ORACLE_RETIRED" ] && ok "no retired oracle plist left behind" || bad "no retired oracle plist left behind"
BOOTSTRAP_COUNT1="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT1" "5" "fresh install bootstraps only active jobs (canary + tripwire + fleet + pi-session-reaper + balance-watch)"

echo "── 2. Retirement: pre-seeded old plists get unloaded + removed ───"
seed_retired "$HOME2"
OUT="$(LOG="$LOG2" run_installer "$HOME2")"
RC=$?
assert_eq "$RC" "0" "installer with seeded retired jobs exits 0"
assert_contains "$OUT" "com.eldato.hub-state-check: RETIRED (unloaded + removed)" "hub retired job unloaded + removed"
assert_contains "$OUT" "com.eldato.skill-lint-oracle: RETIRED (unloaded + removed)" "oracle retired job unloaded + removed"
[ ! -f "$HOME2/Library/LaunchAgents/com.eldato.hub-state-check.plist" ] && ok "hub retired plist file gone" || bad "hub retired plist file gone"
[ ! -f "$HOME2/Library/LaunchAgents/com.eldato.skill-lint-oracle.plist" ] && ok "oracle retired plist file gone" || bad "oracle retired plist file gone"
OUT="$(LOG="$LOG2" run_installer "$HOME2")"
RC=$?
assert_eq "$RC" "0" "retirement is idempotent (second run exits 0)"
assert_not_contains "$OUT" "RETIRED (unloaded + removed)" "no repeat retirement chatter"
# A retired label that STILL has a template is a config error → loud + exit 1.
cp "$REPO_TEMPLATES/com.eldato.provider-latency-tripwire.plist" "$TEMPLATES/com.eldato.hub-state-check.plist"
set +e
OUT="$(LOG="$LOG2" run_installer "$HOME2" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "retired label with template → exit 1"
assert_contains "$OUT" "com.eldato.hub-state-check is in RETIRED but a template still exists" "retire/template conflict named loudly"
[ ! -f "$HOME2/Library/LaunchAgents/com.eldato.hub-state-check.plist" ] && ok "conflicting template NOT installed" || bad "conflicting template NOT installed"
rm -f "$TEMPLATES/com.eldato.hub-state-check.plist"

echo "── 3. Render determinism ─────────────────────────────────────────"
# Direct byte-identity check: two renders of the same template with the same
# env must be byte-identical (same placeholder set → same output).
render_twice() {
    local r1 r2
    r1="$(HOME="$HOME2" TEMPLATES_DIR="$TEMPLATES" SWARM_ROOT="$HOME2/swarm" \
        PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
        sed -e "s|{{HOME}}|$HOME2|g" -e "s|{{PYTHON_BIN}}|$HOME2/swarm/.venv/bin/python|g" \
            "$TEMPLATES/com.eldato.corruption-canary.plist")"
    r2="$(HOME="$HOME2" TEMPLATES_DIR="$TEMPLATES" SWARM_ROOT="$HOME2/swarm" \
        PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
        sed -e "s|{{HOME}}|$HOME2|g" -e "s|{{PYTHON_BIN}}|$HOME2/swarm/.venv/bin/python|g" \
            "$TEMPLATES/com.eldato.corruption-canary.plist")"
    assert_eq "$(printf '%s' "$r1" | shasum | cut -d' ' -f1)" \
        "$(printf '%s' "$r2" | shasum | cut -d' ' -f1)" \
        "same env → byte-identical render"
}
render_twice

echo "── 4. Idempotent skip ────────────────────────────────────────────"
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "re-run exits 0"
assert_contains "$OUT" "provider-latency-tripwire: unchanged (skip)" "tripwire job skipped when identical"
assert_contains "$OUT" "corruption-canary: unchanged (skip)" "canary job skipped when identical"
BOOTSTRAP_COUNT2="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT2" "$BOOTSTRAP_COUNT1" "no reload on no-change"

echo "── 5. Change → reload ────────────────────────────────────────────"
sed -i.bak 's/<integer>3600<\/integer>/<integer>3601<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "change install exits 0"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "tripwire reloaded on template change"
assert_contains "$(cat "$TRIPWIRE_INSTALLED")" "3601" "new StartInterval applied"
BOOTSTRAP_COUNT3="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT3" "$((BOOTSTRAP_COUNT2 + 1))" "exactly one reload for the changed job"

echo "── 6. Bootstrap failure is loud ──────────────────────────────────"
# Force a change so the installer reloads — with the shim configured to fail
# bootstrap. Must be loud + non-zero.
sed -i.bak 's/<integer>3601<\/integer>/<integer>3600<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak
sed -i.bak 's/<integer>3600<\/integer>/<integer>3602<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak
set +e
OUT="$(FAKE_BOOTSTRAP_FAIL=1 run_installer "$HOME1" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "bootstrap failure → exit 1"
assert_contains "$OUT" "FAIL" "bootstrap failure reported loudly"

echo "── 7. Broken-target guard ────────────────────────────────────────"
# Remove the farmed script the tripwire plist points at (the today-broken
# symlink case) → installer must refuse with a non-zero exit and no bootstrap.
rm -f "$HOME1/.pi/agent/scripts/checkout-hygiene/provider-latency-tripwire.sh"
rm -f "$TRIPWIRE_INSTALLED"
sed -i.bak 's/<integer>3602<\/integer>/<integer>3601<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak
set +e
OUT="$(run_installer "$HOME1" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "broken script target → exit 1"
assert_contains "$OUT" "broken target" "broken target named"
assert_contains "$OUT" "FAIL" "broken target refuses install"
BOOTSTRAP_COUNT4="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT4" "$((BOOTSTRAP_COUNT3 + 1))" "no bootstrap for a refused job (count frozen after test 6's failed reload)"
# Restore the farmed script so later tests install cleanly
mkfakehome "$HOME1"

echo "── 8. Placeholder skip (no swarm root) ───────────────────────────"
# HOME2 without a swarm root: canary must be SKIPPED (loud, exit 0), tripwire
# still installed. SWARM_ROOT is env-only in the installer — no auto-detect.
rm -rf "$HOME2/swarm"
OUT="$(HOME="$HOME2" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" TEMPLATES_DIR="$TEMPLATES" \
    AGENTS_DIR="$HOME2/Library/LaunchAgents" SWARM_ROOT="" ELDATO_ALLOW_TEST_HOME=1 \
    PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
    bash "$INSTALLER" 2>&1)"
RC=$?
assert_eq "$RC" "0" "placeholder skip exits 0 (non-swarm machine ok)"
assert_contains "$OUT" "SKIP com.eldato.corruption-canary" "canary skipped without swarm root"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "tripwire still installed without swarm"

echo "── 9. --status ───────────────────────────────────────────────────"
# Template is at 3601; HOME1 tripwire is not installed (test 6 rollback + test
# 7 refusal) → install it, then bump the template to show DRIFT in --status.
OUT="$(run_installer "$HOME1" 2>&1)"
sed -i.bak 's/<integer>3601<\/integer>/<integer>3603<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak
OUT="$(run_installer "$HOME1" --status)"
RC=$?
assert_eq "$RC" "0" "--status exits 0"
assert_contains "$OUT" "provider-latency-tripwire: installed=loaded version=v0.1.0 (DRIFTED" "status flags drifted tripwire"
assert_contains "$OUT" "corruption-canary: installed=loaded version=v0.1.0 (in sync)" "status reports canary in sync"
assert_contains "$OUT" "Retired (moved to session-checks, #432)" "status lists retired jobs"

echo "── 10. --uninstall ───────────────────────────────────────────────"
OUT="$(run_installer "$HOME1" --uninstall)"
RC=$?
assert_eq "$RC" "0" "--uninstall exits 0"
assert_contains "$OUT" "provider-latency-tripwire: unloaded + removed" "tripwire removed"
assert_contains "$OUT" "corruption-canary: unloaded + removed" "canary removed"
[ ! -f "$TRIPWIRE_INSTALLED" ] && ok "tripwire file gone" || bad "tripwire file gone"
[ ! -f "$CANARY_INSTALLED" ] && ok "canary file gone" || bad "canary file gone"
OUT="$(run_installer "$HOME1" --status)"
assert_contains "$OUT" "NOT INSTALLED" "status reports clean after uninstall"

echo "── 11. Temp-HOME guard refuses launchd management (#446) ────────────"
# A run with HOME ≠ the real home and NO ELDATO_ALLOW_TEST_HOME override must
# refuse BEFORE any launchctl call — that is what keeps pi-bootstrap's
# setup-test (which runs the REAL setup.sh under a temp HOME) from registering
# real-domain jobs against throwaway plist paths. The shim records every
# invocation, so "zero calls" is directly assertable. Also exercised: the
# guard fires identically for --uninstall (equally destructive to real jobs).
HOME3="$T/home3"; mkfakehome "$HOME3"
LOG3="$T/launchctl-refusal.log"; : > "$LOG3"
set +e
OUT="$(HOME="$HOME3" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG3" \
    TEMPLATES_DIR="$TEMPLATES" AGENTS_DIR="$HOME3/Library/LaunchAgents" \
    SWARM_ROOT="$HOME3/swarm" PYTHON_BIN="$HOME3/swarm/.venv/bin/python" \
    bash "$INSTALLER" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "temp-HOME install (no override) → exit 1"
assert_contains "$OUT" "refusing to manage launchd jobs" "refusal names the guard"
assert_contains "$OUT" "not the real home" "refusal explains the HOME mismatch"
[ ! -s "$LOG3" ] && ok "zero launchctl calls on refusal (nothing touched any domain)" || bad "zero launchctl calls on refusal (got: $(cat "$LOG3"))"
set +e
OUT="$(HOME="$HOME3" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG3" \
    bash "$INSTALLER" --uninstall 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "temp-HOME --uninstall (no override) → exit 1"
[ ! -s "$LOG3" ] && ok "zero launchctl calls on --uninstall refusal" || bad "zero launchctl calls on --uninstall refusal"
# With the override the SAME home installs cleanly through the shim (the
# override is the test's explicit isolation proof, #446).
OUT="$(LOG="$LOG" run_installer "$HOME3" 2>&1)"
RC=$?
assert_eq "$RC" "0" "override + shim → temp-HOME install proceeds (isolated)"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "override install works hermetically"

echo "── 12. Template lint (plutil, when present) ──────────────────────"
if command -v plutil >/dev/null 2>&1; then
    LINT_OK=1
    for t in "$REPO_TEMPLATES"/*.plist; do
        plutil -lint "$t" >/dev/null 2>&1 || LINT_OK=0
    done
    assert_eq "$LINT_OK" "1" "all repo templates lint clean"
    # rendered output must lint too (fresh HOME render, after uninstall)
    OUT="$(run_installer "$HOME1" >/dev/null; plutil -lint "$TRIPWIRE_INSTALLED" >/dev/null 2>&1; echo $?)"
    assert_eq "$OUT" "0" "rendered+installed tripwire plist lints clean"
    OUT="$(plutil -lint "$CANARY_INSTALLED" >/dev/null 2>&1; echo $?)"
    assert_eq "$OUT" "0" "rendered+installed canary plist lints clean"
else
    echo "  ⚠️  plutil not found — lint checks skipped"
fi

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
