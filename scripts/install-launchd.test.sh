#!/usr/bin/env bash
# install-launchd.test.sh — self-check for scripts/install-launchd.sh + the
# templates/launchd/ versioned plist templates (agent-infra #304).
#
# Run: bash scripts/install-launchd.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds a
# throwaway fake HOME + fake templates dir + fake `launchctl` shim in a temp
# dir — never touches the real ~/Library/LaunchAgents or real launchd.
#
# Coverage (issue #304 test plan):
#   fresh-HOME simulation  both jobs installed with substituted paths
#   render determinism     same env → byte-identical output
#   idempotent skip        second run: "unchanged", no bootout/bootstrap
#   change → reload        template bump → reinstall + one new bootstrap
#   bootstrap failure      shim FAILS bootstrap → installer exits 1, loud
#   broken-target guard    missing script → refuse, exit 1, no install
#   placeholder skip       no swarm root → canary skipped (exit 0), hub installed
#   --status               installed/loaded/drift reporting
#   --uninstall            bootout + remove; re-run reports NOT INSTALLED
#   template lint          plutil -lint the rendered plists (when plutil exists)

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

# Fake HOME with a farmed scripts dir + a swarm checkout.
mkfakehome() { # $1 = home dir
    mkdir -p "$1/.pi/agent/scripts/checkout-hygiene"
    touch "$1/.pi/agent/scripts/checkout-hygiene/hub-state-check.sh"
    touch "$1/.pi/agent/scripts/checkout-hygiene/corruption_canary.py"
    chmod +x "$1/.pi/agent/scripts/checkout-hygiene/hub-state-check.sh"
    chmod +x "$1/.pi/agent/scripts/checkout-hygiene/corruption_canary.py"
    mkdir -p "$1/swarm/.venv/bin"
    touch "$1/swarm/.venv/bin/python"
    chmod +x "$1/swarm/.venv/bin/python"
    mkdir -p "$1/tortoise/.git"
    mkdir -p "$1/Library/LaunchAgents"
}

# Copies repo templates into a scratch dir (installer's template dir is
# env-overridable; tests mutate the COPY, never the repo).
TEMPLATES="$T/templates"
cp -R "$REPO_TEMPLATES" "$TEMPLATES"

HOME1="$T/home1"; mkfakehome "$HOME1"
HOME2="$T/home2"; mkfakehome "$HOME2"
TORTOISE="$T/home1/tortoise"
LOG="$T/launchctl.log"
: > "$LOG"

run_installer() { # <home> [extra env assignments...]
    (
        export HOME="$1"
        export PATH="$T/bin:$PATH"
        export FAKE_LAUNCHCTL_LOG="$LOG"
        export TEMPLATES_DIR="$TEMPLATES"
        export AGENTS_DIR="$HOME/Library/LaunchAgents"
        export SWARM_ROOT="$HOME/swarm"
        export TORTOISE_REPO="$HOME/tortoise"
        export PYTHON_BIN="$HOME/swarm/.venv/bin/python"
        shift
        bash "$INSTALLER" "$@"
    )
}

echo "── 1. Fresh-HOME simulation ──────────────────────────────────────"
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "fresh install exits 0"
assert_contains "$OUT" "hub-state-check: installed + loaded" "hub-state-check installed on fresh machine"
assert_contains "$OUT" "corruption-canary: installed + loaded" "corruption-canary installed on fresh machine"
HUB_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.hub-state-check.plist"
CANARY_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.corruption-canary.plist"
assert_contains "$(cat "$HUB_INSTALLED")" "$HOME1/.pi/agent/scripts/checkout-hygiene/hub-state-check.sh" "hub plist rendered with fake HOME"
assert_contains "$(cat "$HUB_INSTALLED")" "$TORTOISE" "hub plist rendered TORTOISE_REPO env"
assert_contains "$(cat "$CANARY_INSTALLED")" "$HOME1/swarm/.venv/bin/python" "canary plist rendered PYTHON_BIN"
assert_contains "$(cat "$CANARY_INSTALLED")" "--root" "canary plist keeps --root"
assert_contains "$(cat "$CANARY_INSTALLED")" "agent-infra-plist-version: 0.1.0" "canary template carries version marker"
assert_contains "$(cat "$HUB_INSTALLED")" "agent-infra-plist-version: 0.1.0" "hub template carries version marker"
BOOTSTRAP_COUNT1="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT1" "2" "fresh install bootstraps both jobs"

echo "── 2. Render determinism ─────────────────────────────────────────"
# Direct byte-identity check: two renders of the same template with the same
# env must be byte-identical (same placeholder set → same output).
render_twice() {
    local r1 r2
    r1="$(HOME="$HOME2" TEMPLATES_DIR="$TEMPLATES" SWARM_ROOT="$HOME2/swarm" \
        TORTOISE_REPO="$HOME2/tortoise" PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
        sed -e "s|{{HOME}}|$HOME2|g" -e "s|{{TORTOISE_REPO}}|$HOME2/tortoise|g" \
            -e "s|{{SWARM_ROOT}}|$HOME2/swarm|g" -e "s|{{PYTHON_BIN}}|$HOME2/swarm/.venv/bin/python|g" \
            "$TEMPLATES/com.eldato.hub-state-check.plist")"
    r2="$(HOME="$HOME2" TEMPLATES_DIR="$TEMPLATES" SWARM_ROOT="$HOME2/swarm" \
        TORTOISE_REPO="$HOME2/tortoise" PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
        sed -e "s|{{HOME}}|$HOME2|g" -e "s|{{TORTOISE_REPO}}|$HOME2/tortoise|g" \
            -e "s|{{SWARM_ROOT}}|$HOME2/swarm|g" -e "s|{{PYTHON_BIN}}|$HOME2/swarm/.venv/bin/python|g" \
            "$TEMPLATES/com.eldato.hub-state-check.plist")"
    assert_eq "$(printf '%s' "$r1" | shasum | cut -d' ' -f1)" \
        "$(printf '%s' "$r2" | shasum | cut -d' ' -f1)" \
        "same env → byte-identical render"
}
render_twice

echo "── 3. Idempotent skip ────────────────────────────────────────────"
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "re-run exits 0"
assert_contains "$OUT" "hub-state-check: unchanged (skip)" "hub job skipped when identical"
assert_contains "$OUT" "corruption-canary: unchanged (skip)" "canary job skipped when identical"
BOOTSTRAP_COUNT2="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT2" "$BOOTSTRAP_COUNT1" "no reload on no-change"

echo "── 4. Change → reload ────────────────────────────────────────────"
sed -i.bak 's/<integer>21600<\/integer>/<integer>21601<\/integer>/' "$TEMPLATES/com.eldato.hub-state-check.plist" && rm -f "$TEMPLATES/com.eldato.hub-state-check.plist".bak
OUT="$(run_installer "$HOME1")"
RC=$?
assert_eq "$RC" "0" "change install exits 0"
assert_contains "$OUT" "hub-state-check: installed + loaded" "hub reloaded on template change"
assert_contains "$(cat "$HUB_INSTALLED")" "21601" "new StartInterval applied"
BOOTSTRAP_COUNT3="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT3" "$((BOOTSTRAP_COUNT2 + 1))" "exactly one reload for the changed job"

echo "── 5. Bootstrap failure is loud ──────────────────────────────────"
# Restore the template, then force a change so the installer reloads — with
# the shim configured to fail bootstrap. Must be loud + non-zero.
sed -i.bak 's/<integer>21601<\/integer>/<integer>21600<\/integer>/' "$TEMPLATES/com.eldato.hub-state-check.plist" && rm -f "$TEMPLATES/com.eldato.hub-state-check.plist".bak
sed -i.bak 's/<integer>21600<\/integer>/<integer>21602<\/integer>/' "$TEMPLATES/com.eldato.hub-state-check.plist" && rm -f "$TEMPLATES/com.eldato.hub-state-check.plist".bak
set +e
OUT="$(FAKE_BOOTSTRAP_FAIL=1 run_installer "$HOME1" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "bootstrap failure → exit 1"
assert_contains "$OUT" "FAIL" "bootstrap failure reported loudly"

echo "── 6. Broken-target guard ────────────────────────────────────────"
# Remove the farmed script the hub plist points at (the today-broken symlink
# case) → installer must refuse with a non-zero exit and no bootstrap.
rm -f "$HOME1/.pi/agent/scripts/checkout-hygiene/hub-state-check.sh"
rm -f "$HOME1/Library/LaunchAgents/com.eldato.hub-state-check.plist"
sed -i.bak 's/<integer>21602<\/integer>/<integer>21601<\/integer>/' "$TEMPLATES/com.eldato.hub-state-check.plist" && rm -f "$TEMPLATES/com.eldato.hub-state-check.plist".bak
set +e
OUT="$(run_installer "$HOME1" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "broken script target → exit 1"
assert_contains "$OUT" "broken target" "broken target named"
assert_contains "$OUT" "FAIL" "broken target refuses install"
BOOTSTRAP_COUNT4="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT4" "$((BOOTSTRAP_COUNT3 + 1))" "no bootstrap for a refused job (count frozen after test 5's failed reload)"
# Restore the farmed script so later tests install cleanly
mkfakehome "$HOME1"

echo "── 7. Placeholder skip (no swarm root) ───────────────────────────"
# HOME2 without a swarm root: canary must be SKIPPED (loud, exit 0), hub
# installed. SWARM_ROOT is env-only in the installer — no auto-detect.
rm -rf "$HOME2/swarm"
OUT="$(HOME="$HOME2" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" TEMPLATES_DIR="$TEMPLATES" \
    AGENTS_DIR="$HOME2/Library/LaunchAgents" SWARM_ROOT="" \
    TORTOISE_REPO="$TORTOISE" PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
    bash "$INSTALLER" 2>&1)"
RC=$?
assert_eq "$RC" "0" "placeholder skip exits 0 (non-swarm machine ok)"
assert_contains "$OUT" "SKIP com.eldato.corruption-canary" "canary skipped without swarm root"
assert_contains "$OUT" "hub-state-check: installed + loaded" "hub still installed without swarm"

echo "── 8. --status ───────────────────────────────────────────────────"
# Template is at 21601; HOME1 hub is not installed (test 5 rollback + test 6
# refusal) → install it, then bump the template to show DRIFT in --status.
OUT="$(run_installer "$HOME1" 2>&1)"
sed -i.bak 's/<integer>21601<\/integer>/<integer>21603<\/integer>/' "$TEMPLATES/com.eldato.hub-state-check.plist" && rm -f "$TEMPLATES/com.eldato.hub-state-check.plist".bak
OUT="$(run_installer "$HOME1" --status)"
RC=$?
assert_eq "$RC" "0" "--status exits 0"
assert_contains "$OUT" "hub-state-check: installed=loaded version=v0.1.0 (DRIFTED" "status flags drifted hub"
assert_contains "$OUT" "corruption-canary: installed=loaded version=v0.1.0 (in sync)" "status reports canary in sync"

echo "── 9. --uninstall ────────────────────────────────────────────────"
OUT="$(run_installer "$HOME1" --uninstall)"
RC=$?
assert_eq "$RC" "0" "--uninstall exits 0"
assert_contains "$OUT" "hub-state-check: unloaded + removed" "hub removed"
assert_contains "$OUT" "corruption-canary: unloaded + removed" "canary removed"
[ ! -f "$HUB_INSTALLED" ] && ok "hub file gone" || bad "hub file gone"
[ ! -f "$CANARY_INSTALLED" ] && ok "canary file gone" || bad "canary file gone"
OUT="$(run_installer "$HOME1" --status)"
assert_contains "$OUT" "NOT INSTALLED" "status reports clean after uninstall"

echo "── 10. Template lint (plutil, when present) ──────────────────────"
if command -v plutil >/dev/null 2>&1; then
    LINT_OK=1
    for t in "$REPO_TEMPLATES"/*.plist; do
        plutil -lint "$t" >/dev/null 2>&1 || LINT_OK=0
    done
    assert_eq "$LINT_OK" "1" "all repo templates lint clean"
    # rendered output must lint too (fresh HOME render, after uninstall)
    OUT="$(run_installer "$HOME1" >/dev/null; plutil -lint "$HUB_INSTALLED" >/dev/null 2>&1; echo $?)"
    assert_eq "$OUT" "0" "rendered+installed hub plist lints clean"
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
