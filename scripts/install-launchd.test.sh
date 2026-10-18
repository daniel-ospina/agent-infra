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
#   #1719 runner gate      templates/launchd/com.tortoise.ci-runner-gate.plist installs
#                          the farmed ci_runner_gate.sh under the label the hand-made
#                          duplicate used, AND no rendered plist PATH carries the pi
#                          shim dir (launchd cannot exec into ~/Documents, #427)
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
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
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
    for f in fleet-cost-weekly.sh fleet-cost-report.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh pi-task-session-prune.sh pi-cache-reap.sh pi-reap-worktrees.sh pi-reap-worktrees-launchd.py cleanup-stale-branches.sh ci_runner_gate.sh; do
        touch "$1/.pi/agent/scripts/$f"
        chmod +x "$1/.pi/agent/scripts/$f"
    done
    # #1719 — the gate job's plist target. Its farm entry is `fleet_srcs` (setup.sh copies it to
    # scripts/), so it must resolve here or the broken-target guard refuses the install.
    # The shim dir is created too: it is the path the installer must NOT hand to a launchd job
    # (symlinks into ~/Documents → EPERM under TCC, #427), and run_installer puts it on PATH.
    mkdir -p "$1/.pi/agent/shims"
    touch "$1/.pi/agent/shims/gh"
    # #1719 (review E2) — a PATH entry that is a SYMLINK to the shim dir matches no literal name
    # pattern, so the helper must resolve the PHYSICAL path to drop it. Created here so run_installer
    # can put it on PATH; its presence in a rendered plist is a failure.
    ln -sfn "$1/.pi/agent/shims" "$1/.pi/agent/shimlink"
    # #1719 (review E2) — the REVERSE control: ~/.pi/agent/bin holds REAL fd/rg binaries and is
    # outside the TCC-protected tree, so it must SURVIVE the filter. Mirrors install.sh:add_dir(),
    # whose blanket `*/.pi/*` exclusion would wrongly drop it here.
    mkdir -p "$1/.pi/agent/bin"
    touch "$1/.pi/agent/bin/rg"
    chmod +x "$1/.pi/agent/bin/rg"
    # #1719 (review D2-3) — a PATH entry containing `&`, the sed replacement's "whole match" token.
    # Without escaping, `render` turns it into a corrupted entry with a literal {{PATH}} left in the
    # middle of it, and nothing downstream notices (verify_targets inspects ProgramArguments only).
    mkdir -p "$1/.pi/agent/r&d"
    # #1719 (review D3) — a PATH entry carrying a GLOB character. `for p in $PATH` splits on IFS=: as
    # intended, but it ALSO pathname-expands each entry, so `.../globs/a*` was silently rewritten as
    # the entries it matched — a job PATH the installer's own shell never had, and no test noticed.
    # Two real dirs exist so an expansion has something to match; the assertion below reads the
    # RENDERED PATH and fails if either fabricated entry appears.
    mkdir -p "$1/.pi/agent/globs/aa" "$1/.pi/agent/globs/ab"
    # #1719 (review B4-2/E5) — the `CDPATH= cd` fix needs a CASE, not just code: `cd` honours CDPATH,
    # so a bare `cd` KEEPS a relative PATH entry that does not resolve from the installer's cwd, as
    # long as some CDPATH directory happens to carry that name. run_installer exports CDPATH here and
    # puts the relative name on PATH; the entry must come out DROPPED (the helper drops whatever does
    # not resolve), so its presence in a rendered plist means the fix was reverted.
    mkdir -p "$1/.pi/agent/cdpath/cdpathphantom"
    mkdir -p "$1/.pi/agent/scripts/lib"
    touch "$1/.pi/agent/scripts/lib/pid-identity.sh"
    chmod +x "$1/.pi/agent/scripts/lib/pid-identity.sh"
    # #1178 unit 3 — the scheduled lane-liveness report runs the FARMED tools:
    # the driver + its sibling classifier under scripts/fleet/ (the broken-target
    # guard refuses the install when they are absent). NOT tools/fleet/: pi's
    # startup scan blocks interactive boot on any non-fd/rg entry there (#1277).
    mkdir -p "$1/.pi/agent/scripts/fleet"
    touch "$1/.pi/agent/scripts/fleet/lane_liveness.py"
    touch "$1/.pi/agent/scripts/fleet/liveness.py"
    chmod +x "$1/.pi/agent/scripts/fleet/lane_liveness.py"
    chmod +x "$1/.pi/agent/scripts/fleet/liveness.py"
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
        # #1719: the shim dir is FIRST on an interactive session's PATH, exactly as it is on a real
        # box — the renderer must strip it, so the suite puts it there deliberately (otherwise the
        # PATH assertion below would be vacuous). A SYMLINK to it and the real-binary dir
        # (~/.pi/agent/bin, holding fd/rg) are on PATH too: the first must be dropped by physical
        # path, the second must be KEPT (review E2).
        export CDPATH="$HOME/.pi/agent/cdpath"
        export PATH="$T/bin:$HOME/.pi/agent/shims:$HOME/.pi/agent/shimlink:$HOME/.pi/agent/bin:$HOME/.pi/agent/r&d:$HOME/.pi/agent/globs/a*:cdpathphantom:$PATH"
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
assert_contains "$OUT" "pi-task-session-prune: installed + loaded" "pi-task-session-prune installed on fresh machine (#783)"
assert_contains "$OUT" "pi-cache-reap: installed + loaded" "pi-cache-reap installed on fresh machine (#1987)"
assert_contains "$OUT" "lane-liveness: installed + loaded" "lane-liveness installed on fresh machine (#1178)"
assert_contains "$OUT" "deepseek-balance-watch: installed + loaded" "deepseek-balance-watch installed on fresh machine (#476)"
assert_contains "$OUT" "ci-runner-gate: installed + loaded" "ci-runner-gate installed on fresh machine (#1719)"
CANARY_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.corruption-canary.plist"
TRIPWIRE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.provider-latency-tripwire.plist"
FLEET_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.fleet-cost-weekly.plist"
REAPER_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-session-reaper.plist"
PRUNE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-task-session-prune.plist"
CACHE_REAP_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-cache-reap.plist"
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
# #947 — the DEPLOYED invariant: the hourly job must never arm the stuck set
# (arming is a manual, per-machine decision). Without this assertion a later
# template edit adding REAP_REAP_STUCK=1 would satisfy every other plist check
# and silently broaden the kill set on every host at the next sync.
assert_not_contains "$(cat "$REAPER_INSTALLED")" "REAP_REAP_STUCK" "reaper plist does NOT arm the STUCK set (#947)"
assert_not_contains "$(cat "$REAPER_INSTALLED")" "REAP_STUCK_HOURS" "reaper plist does not override the stuck bound (#947)"
# #783 Task 6 — pi-task-session-prune rendered-plist content asserts (farmed
# path, DISARMED TASK_SESSION_PRUNE_DRY_RUN=1, hourly StartInterval 3600)
assert_contains "$(cat "$PRUNE_INSTALLED")" "$HOME1/.pi/agent/scripts/pi-task-session-prune.sh" "prune plist rendered with fake HOME (farmed path)"
assert_contains "$(cat "$PRUNE_INSTALLED")" "TASK_SESSION_PRUNE_DRY_RUN" "prune plist carries TASK_SESSION_PRUNE_DRY_RUN env"
assert_contains "$(cat "$PRUNE_INSTALLED")" "<string>1</string>" "prune plist SHIPS DRY-RUN (TASK_SESSION_PRUNE_DRY_RUN=1)"
assert_contains "$(cat "$PRUNE_INSTALLED")" "StartInterval" "prune job is interval-scheduled"
assert_contains "$(cat "$PRUNE_INSTALLED")" "<integer>3600</integer>" "prune job hourly (StartInterval 3600)"
assert_contains "$(cat "$PRUNE_INSTALLED")" "agent-infra-plist-version: 0.1.0" "prune template carries version marker"
# #1987 — the machine-global cache bound. It ships DRY-RUN like every sibling reaper: arming a
# scheduled DELETION is an owner-level consequence decision (agent-infra#1678, owner ruling
# 2026-10-11: "the reaper may run unattended; arming it may not"). ⚠️ NOTHING ENFORCES THIS: the
# arming route is a tracked-template edit plus an installer re-run, which is exactly what #1678's
# requirement 3 says the installer should refuse without an owner marker. These asserts pin the
# COMMITTED stance; they are not a gate.
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "$HOME1/.pi/agent/scripts/pi-cache-reap.sh" "cache-reap plist rendered with fake HOME (farmed path)"
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "<string>--dry-run</string>" "cache-reap plist SHIPS DRY-RUN (#1987 / #1678 arming ruling)"
assert_not_contains "$(cat "$CACHE_REAP_INSTALLED")" "<string>--apply</string>" "cache-reap plist is NOT armed by a lane"
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "<key>CACHE_REAP_MAX_MB</key>" "cache-reap plist pins the size bound in the plist, not the shell"
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "<string>2048</string>" "cache-reap plist pins the bound's VALUE (a key-only assert passes on a typo that mints a dead timer)"
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "<integer>3600</integer>" "cache-reap job hourly (StartInterval 3600)"
assert_contains "$(cat "$CACHE_REAP_INSTALLED")" "agent-infra-plist-version: 0.1.0" "cache-reap template carries version marker"
# #1178 unit 3 — lane-liveness rendered-plist content asserts (farmed tools path,
# the PINNED probe library, and the interval schedule). #1277: the farmed path is
# scripts/fleet/, never tools/fleet/ (pi's startup scan blocks interactive boot on
# any non-fd/rg entry in tools/).
LANE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.lane-liveness.plist"
assert_contains "$(cat "$LANE_INSTALLED")" "$HOME1/.pi/agent/scripts/fleet/lane_liveness.py" "lane-liveness plist rendered with fake HOME (farmed scripts/fleet path, #1277)"
assert_not_contains "$(cat "$LANE_INSTALLED")" "$HOME1/.pi/agent/tools/fleet/lane_liveness.py" "lane-liveness plist does NOT point at the deprecated tools/fleet/ (#1277)"
assert_contains "$(cat "$LANE_INSTALLED")" "PI_PID_IDENTITY_LIB" "lane-liveness plist pins the shared identity library"
assert_contains "$(cat "$LANE_INSTALLED")" "$HOME1/.pi/agent/scripts/lib/pid-identity.sh" "lane-liveness plist pins the FARMED library (never ~/Documents)"
assert_contains "$(cat "$LANE_INSTALLED")" "python3" "lane-liveness plist runs the python driver"
assert_contains "$(cat "$LANE_INSTALLED")" "StartInterval" "lane-liveness is interval-scheduled"
assert_contains "$(cat "$LANE_INSTALLED")" "<integer>1800</integer>" "lane-liveness every 30 min (StartInterval 1800)"
assert_contains "$(cat "$LANE_INSTALLED")" "agent-infra-plist-version: 0.1.0" "lane-liveness template carries version marker"
assert_contains "$(cat "$DBW_INSTALLED")" "$HOME1/.pi/agent/scripts/checkout-hygiene/deepseek-balance-watch.sh" "balance-watch plist rendered with fake HOME (#476)"
assert_contains "$(cat "$DBW_INSTALLED")" "agent-infra-plist-version: 0.1.0" "balance-watch template carries version marker"
# #476 — the balance poller is the SINGLE restore authority: must run every
# 15min (StartInterval 900, not calendar) and carry the installer PATH (launchd
# default PATH lacks python3/curl used by the poller).
assert_contains "$(cat "$DBW_INSTALLED")" "<integer>900</integer>" "balance-watch runs every 15min (StartInterval 900)"
assert_not_contains "$(cat "$DBW_INSTALLED")" "StartCalendarInterval" "balance-watch is interval-scheduled, not calendar"
assert_contains "$(cat "$DBW_INSTALLED")" "<key>PATH</key>" "balance-watch plist carries an explicit PATH env"
# #1719 — the runner-label gate: the repo's copy must be the one launchd executes, on the SAME
# label the hand-made duplicate occupied, and it must never be handed the shim dir.
GATE_INSTALLED="$HOME1/Library/LaunchAgents/com.tortoise.ci-runner-gate.plist"
if [ -f "$GATE_INSTALLED" ]; then
  ok "runner-gate plist installed at the hand-made duplicate's own label (#1719)"
else
  bad "runner-gate plist NOT installed — the versioned template is wired to nothing (#1719)"
fi
assert_contains "$(cat "$GATE_INSTALLED" 2>/dev/null)" "$HOME1/.pi/agent/scripts/ci_runner_gate.sh" "runner-gate plist rendered with fake HOME (farmed path)"
assert_contains "$(cat "$GATE_INSTALLED" 2>/dev/null)" "<integer>300</integer>" "runner-gate every 5 min (StartInterval 300)"
assert_contains "$(cat "$GATE_INSTALLED" 2>/dev/null)" "RunAtLoad" "runner-gate runs once at load (a freshness kick)"
assert_contains "$(cat "$GATE_INSTALLED" 2>/dev/null)" "agent-infra-plist-version: 0.1.0" "runner-gate template carries version marker"
# #1719 — these assertions read the RENDERED PATH VALUE, not the whole plist (review E2-3). The
# rendered plist keeps the template's comments, and a purely documentary edit that NAMES the shim
# path (e.g. `~/.pi/agent/shims`, which the installer's own comment uses) would red a whole-file
# `assert_not_contains "/shims"` while the PATH was correct — a false RED. Extract the value.
installed_path() { # $1 = plist → the PATH string from EnvironmentVariables
  sed -n '/<key>PATH<\/key>/{n;s@.*<string>\(.*\)</string>.*@\1@p;}' "$1"
}
GATE_PATH_VAL="$(installed_path "$GATE_INSTALLED")"
assert_contains "$GATE_PATH_VAL" "/usr/bin" "runner-gate plist PATH is rendered from the installer's PATH (non-empty)"
assert_not_contains "$GATE_PATH_VAL" "/shims" "runner-gate plist PATH carries no shim dir (#1719/#427)"
assert_not_contains "$GATE_PATH_VAL" "shimlink" "runner-gate plist PATH drops a SYMLINK to the shim dir (physical-path match, review E2)"
assert_contains "$GATE_PATH_VAL" "/.pi/agent/bin" "runner-gate plist PATH KEEPS ~/.pi/agent/bin (real fd/rg — not a shim, review E2)"
assert_not_contains "$GATE_PATH_VAL" "{{PATH}}" "no placeholder survives into the rendered PATH value (review D2-3)"
assert_contains "$GATE_PATH_VAL" "r&amp;d" "a PATH entry containing & is XML-escaped in the rendered value (sed replacement escaped, review D2-3)"
# #1719 (review D3) — a PATH entry containing a GLOB character must never be EXPANDED into its
# matches (review E4-4 corrected this comment: it does not "reach the plist unexpanded" — with
# globbing suppressed the literal `globs/a*` no longer resolves, so it is DROPPED, exactly like any
# other unresolvable entry. What is asserted below is that the FABRICATED matches never appear).
assert_not_contains "$GATE_PATH_VAL" "globs/aa" "a glob-char PATH entry is not expanded into its matches (review D3)"
assert_not_contains "$GATE_PATH_VAL" "globs/ab" "…nor into its second match (review D3)"
# #1719 (review E5) — the `CDPATH= cd` fix in `launchd_path` is otherwise untested: every other PATH
# entry in this suite is absolute, and CDPATH only affects RELATIVE entries, so reverting the fix left
# the suite green while the installer rendered an unresolvable relative entry into every plist.
assert_not_contains "$GATE_PATH_VAL" "cdpathphantom" \
  "a RELATIVE PATH entry that only CDPATH can resolve is DROPPED, not rendered (review B4-2/E5)"

# #1719 (review D3, run as a RUN not a grep — review E3-5 corrected the earlier claim) — the guard
# that refuses a job whose rendered PATH came out EMPTY. It IS dynamically reachable: with PATH
# pointing ONLY at a directory literally NAMED `shims`, every entry is filtered by PHYSICAL path while
# the installer's own `sed`/`grep`/`mktemp` still resolve THROUGH that directory (they are symlinks
# inside it) — so `launchd_path` is empty for every {{PATH}} template and the guard must fire. The
# earlier version of this pin grepped the installer for the guard's MESSAGE, which a deleted guard
# would satisfy for as long as the string remained anywhere in the file, and it justified the grep
# with the false claim that the guard could never be reached.
HOME_GUARD="$T/home-guard"; mkfakehome "$HOME_GUARD"
SHIMONLY="$T/shimonly/shims"; mkdir -p "$SHIMONLY"
for tool in bash sh sed grep mktemp cmp cat dirname basename mkdir rm mv chmod awk tr cut head sort stat id; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sfn "$src" "$SHIMONLY/$tool"
done
ln -sfn "$T/bin/launchctl" "$SHIMONLY/launchctl"
LOG_GUARD="$T/launchctl-emptypath.log"; : > "$LOG_GUARD"
set +e
OUT="$(HOME="$HOME_GUARD" PATH="$SHIMONLY" FAKE_LAUNCHCTL_LOG="$LOG_GUARD" \
    TEMPLATES_DIR="$TEMPLATES" AGENTS_DIR="$HOME_GUARD/Library/LaunchAgents" \
    AGENT_INFRA_PATH="$(cd "$SCRIPT_DIR/.." && pwd)" TORTOISE_REPO="$HOME_GUARD/tortoise" \
    SWARM_ROOT="$HOME_GUARD/swarm" PYTHON_BIN="$HOME_GUARD/swarm/.venv/bin/python" \
    ELDATO_ALLOW_TEST_HOME=1 bash "$INSTALLER" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "0" "an all-shim PATH is a clean SKIP, not a failure (exit 0)"
assert_contains "$OUT" "SKIP com.tortoise.ci-runner-gate: unresolved placeholder(s) {{PATH}} — every PATH entry is unreadable" \
  "the empty-rendered-PATH guard FIRES (review D3) — a filtered-away PATH never installs an inert job"
[ ! -f "$HOME_GUARD/Library/LaunchAgents/com.tortoise.ci-runner-gate.plist" ] \
  && ok "no runner-gate plist installed while every rendered PATH was empty" \
  || bad "the runner-gate plist WAS installed with an empty PATH (the guard did not fire)"
# Positive control — the one template with no {{PATH}} must still install through the SAME run, or
# the two assertions above could pass because the run did nothing at all.
[ -f "$HOME_GUARD/Library/LaunchAgents/com.eldato.corruption-canary.plist" ] \
  && ok "control: the {{PATH}}-free canary still installs in that run (the guard is scoped to {{PATH}})" \
  || bad "control: the canary did not install — that run proved nothing about the PATH guard"
assert_not_contains "$(installed_path "$TRIPWIRE_INSTALLED")" "/shims" "tripwire plist PATH carries no shim dir either (#1719)"
# #432 — hub-state-check + skill-lint-oracle are RETIRED from launchd (their
# work moved to extensions/session-checks.ts — macOS TCC blocks launchd from
# ~/Documents, so they run from pi's session_start instead).
assert_not_contains "$OUT" "hub-state-check: installed + loaded" "retired hub job NOT installed on fresh machine"
assert_not_contains "$OUT" "skill-lint-oracle: installed + loaded" "retired oracle job NOT installed on fresh machine"
[ ! -f "$HUB_RETIRED" ] && ok "no retired hub plist left behind" || bad "no retired hub plist left behind"
[ ! -f "$ORACLE_RETIRED" ] && ok "no retired oracle plist left behind" || bad "no retired oracle plist left behind"
BOOTSTRAP_COUNT1="$(grep -c 'launchctl bootstrap' "$LOG")"
assert_eq "$BOOTSTRAP_COUNT1" "9" "fresh install bootstraps only active jobs (canary + tripwire + fleet + pi-session-reaper + balance-watch + pi-task-session-prune + pi-cache-reap + lane-liveness + ci-runner-gate)"

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

# plutil -lint is LENIENT: it accepts a template whose XML comment contains
# `--`, which is ILLEGAL inside an XML comment and makes the file unparseable by
# a strict reader (launchd's own loader is strict). A strict parse is therefore
# the real check, and it does NOT depend on plutil, so it lives OUTSIDE the plutil
# branch — otherwise a host with python3 but no plutil would skip it. #1311.
if command -v python3 >/dev/null 2>&1; then
    STRICT_FAIL=""
    for t in "$REPO_TEMPLATES"/*.plist; do
        python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$t" >/dev/null 2>&1 \
            || STRICT_FAIL="$STRICT_FAIL $(basename "$t")"
    done
    [ -z "$STRICT_FAIL" ] && ok "all repo templates parse under a strict plist reader" \
        || bad "strict plist parse failed:$STRICT_FAIL"
else
    echo "  ⚠️  python3 not found — strict-parse check skipped"
fi

echo ""
echo "── 13. worktree-reaper installs under the TCC-holding interpreter (#1311) ──"
# This template is SKIPPED whenever {{TORTOISE_REPO}} is unresolved — and no
# other section sets it — so without this section the installer suite would
# never exercise the worktree-reaper template at all (it would ship green on
# XML lint alone). A fake tortoise with its own .venv python is the minimum
# that lets the template resolve and install.
HOME3="$T/home3"; mkfakehome "$HOME3"
mkdir -p "$HOME3/tortoise/.venv/bin" "$HOME3/tortoise/.git"
touch "$HOME3/tortoise/.venv/bin/python"; chmod +x "$HOME3/tortoise/.venv/bin/python"
WT_INSTALLED="$HOME3/Library/LaunchAgents/com.tortoise.worktree-reaper.plist"
(
    export HOME="$HOME3"
    export PATH="$T/bin:$PATH"
    export FAKE_LAUNCHCTL_LOG="$LOG"
    export TEMPLATES_DIR="$TEMPLATES"
    export AGENTS_DIR="$HOME3/Library/LaunchAgents"
    export SWARM_ROOT="$HOME3/swarm"
    export PYTHON_BIN="$HOME3/swarm/.venv/bin/python"
    export TORTOISE_REPO="$HOME3/tortoise"
    export ELDATO_ALLOW_TEST_HOME=1
    bash "$INSTALLER" >/dev/null 2>&1
)
if [ -f "$WT_INSTALLED" ]; then
    ok "worktree-reaper installs when {{TORTOISE_REPO}} resolves"
    # The entry point MUST be the checkout's own interpreter: a launchd-spawned
    # `bash` is denied BOTH the ~/Documents script read and the repo read a
    # `git` needs, so a `bash <script>` entry point installs a job that can
    # never classify a worktree.
    grep -q "$HOME3/tortoise/.venv/bin/python" "$WT_INSTALLED" \
        && ok "entry point is the TCC-holding checkout interpreter" \
        || bad "entry point is the TCC-holding checkout interpreter"
    grep -q "$HOME3/.pi/agent/scripts/pi-reap-worktrees-launchd.py" "$WT_INSTALLED" \
        && ok "entry point reaches the FARMED launcher" \
        || bad "entry point reaches the FARMED launcher"
    grep -q "$HOME3/.pi/agent/scripts/pi-reap-worktrees.sh" "$WT_INSTALLED" \
        && ok "launcher targets the FARMED reaper script" \
        || bad "launcher targets the FARMED reaper script"
    grep -q "<string>--dry-run</string>" "$WT_INSTALLED" \
        && ok "worktree-reaper ships UNARMED (--dry-run)" \
        || bad "worktree-reaper ships UNARMED (--dry-run)"
    grep -q '{{' "$WT_INSTALLED" \
        && bad "no unresolved placeholders remain" \
        || ok "no unresolved placeholders remain"

    # EXECUTE the real launcher against a fake reaper. The text assertions above
    # cannot see an ARGUMENT-FORWARDING defect, and one shipped: the launcher
    # once used argparse.REMAINDER, which does NOT absorb unknown OPTIONALS, so
    # the installed job ("--script x --repo y --dry-run") exited 2 before it
    # read the script at all — every pass a no-op, green through this suite.
    FAKE_REAPER="$T/fake-reaper.sh"
    printf '#!/bin/bash\necho "ARGS: $@"\n' > "$FAKE_REAPER"
    OUT="$(python3 "$SCRIPT_DIR/../scripts/pi-reap-worktrees-launchd.py" \
        --script "$FAKE_REAPER" --repo /tmp/some-repo --dry-run 2>&1)"
    assert_eq "$OUT" "ARGS: --repo /tmp/some-repo --dry-run" \
        "launcher forwards the repo and mode args to the reaper (no separator needed)"
    OUT="$(python3 "$SCRIPT_DIR/../scripts/pi-reap-worktrees-launchd.py" \
        --script /tmp/does-not-exist-launcher-probe.sh --repo /tmp/x 2>&1; echo "rc=$?")"
    case "$OUT" in
        *"cannot read"*rc=1) ok "launcher fails cleanly (no traceback) on an unreadable script" ;;
        *) bad "launcher fails cleanly on an unreadable script (got: $OUT)" ;;
    esac
else
    bad "worktree-reaper installs when {{TORTOISE_REPO}} resolves"
fi

echo ""
echo "── 14. branch-reaper installs UNARMED via the shared launcher (#1787) ──"
# Same {{TORTOISE_REPO}}-gated shape as §13 (so it is skipped on a box with no
# tortoise checkout). The pins that matter: the SHARED launcher is the entry
# point, the FARMED reaper is its target, the checkout is passed explicitly,
# and NO execute flag is present — the shipped state must dry-run.
BR_INSTALLED="$HOME3/Library/LaunchAgents/com.tortoise.branch-reaper.plist"
if [ -f "$BR_INSTALLED" ]; then
    ok "branch-reaper installs when {{TORTOISE_REPO}} resolves"
    grep -q "$HOME3/tortoise/.venv/bin/python" "$BR_INSTALLED" \
        && ok "branch-reaper entry point is the TCC-holding checkout interpreter" \
        || bad "branch-reaper entry point is the TCC-holding checkout interpreter"
    grep -q "$HOME3/.pi/agent/scripts/pi-reap-worktrees-launchd.py" "$BR_INSTALLED" \
        && ok "branch-reaper uses the SHARED launcher (no branch-specific one)" \
        || bad "branch-reaper uses the SHARED launcher"
    grep -q "$HOME3/.pi/agent/scripts/cleanup-stale-branches.sh" "$BR_INSTALLED" \
        && ok "branch-reaper launcher targets the FARMED reaper script" \
        || bad "branch-reaper launcher targets the FARMED reaper script"
    grep -q "<string>--repo</string>" "$BR_INSTALLED" \
        && grep -q "<string>$HOME3/tortoise</string>" "$BR_INSTALLED" \
        && ok "branch-reaper passes the checkout explicitly (bash -s empties BASH_SOURCE)" \
        || bad "branch-reaper passes the checkout explicitly"
    # ⛔ BOTH the flag AND its value: a plist that ships `--scope remote` (a
    # different, and when armed differently destructive, job) must not pass an
    # assertion that exists to pin the LOCAL scope. This is the only place in
    # the repo that reads the value, so pinning the flag alone was a false PASS.
    grep -q "<string>--scope</string>" "$BR_INSTALLED" \
        && grep -q "<string>local</string>" "$BR_INSTALLED" \
        && ok "branch-reaper selects the local scope" \
        || bad "branch-reaper selects the local scope"
    grep -q "<string>--execute</string>" "$BR_INSTALLED" \
        && bad "branch-reaper SHIPS UNARMED (no execute flag)" \
        || ok "branch-reaper SHIPS UNARMED (no execute flag)"
    # The report must be RETRIEVABLE: the reaper writes no file on its own, so a
    # plist without this key sends every pass to the unified log. The script
    # caps the file (CLEANUP_BRANCH_LOG_MAX_BYTES), so no StandardOutPath.
    grep -q "<key>CLEANUP_BRANCH_LOG</key>" "$BR_INSTALLED" \
        && grep -q "$HOME3/.pi/agent/state/cleanup-stale-branches.log" "$BR_INSTALLED" \
        && ok "branch-reaper points its pass report at a retrievable capped log" \
        || bad "branch-reaper points its pass report at a retrievable capped log"
    grep -q '{{' "$BR_INSTALLED" \
        && bad "no unresolved placeholders remain in the branch-reaper plist" \
        || ok "no unresolved placeholders remain in the branch-reaper plist"
else
    bad "branch-reaper installs when {{TORTOISE_REPO}} resolves"
fi

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
