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

# ⛔ Neutralise the AMBIENT environment before anything runs. Every section decides HOME, launchd
# provenance and the checkout for itself, and `run_installer` inherits the caller's exports — so a dev
# box with `ELDATO_ALLOW_TEST_HOME=1`, `FAKE_BOOTSTRAP_FAIL=1`, `FAKE_JOB_NOT_LOADED=1` or a
# `TORTOISE_REPO` pointing at a broken checkout read differently from CI on the same code (measured:
# 138/6, 49/80, 142/2 and §8 red respectively). Sections that need one set it explicitly, per run.
unset ELDATO_ALLOW_TEST_HOME FAKE_BOOTSTRAP_FAIL FAKE_JOB_NOT_LOADED TORTOISE_REPO
# #1863 F10 — and hold it EMPTY for the whole suite, not only inside `run_installer`: several sections
# invoke the installer DIRECTLY (`bash "$INSTALLER" ...`) with a partial env list, so an ambient
# TORTOISE_REPO (the orchestrator box sets it) leaked in and the {{TORTOISE_REPO}}-gated jobs resolved
# against a checkout this fixture never created. Sections that need it set do so explicitly and
# override this. (The bootstrap count is DERIVED below, so a host that still resolves a sibling
# checkout is counted, not reddened — that half is main's stronger form of the same fix.)
export TORTOISE_REPO=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-launchd.sh"
REPO_TEMPLATES="$SCRIPT_DIR/../templates/launchd"

# Note (PR #1949, rebased onto #2006): the ambient-environment neutralisation is the suite-wide
# `unset` above — it already covers `TORTOISE_REPO`, so this file has ONE place that decides
# hermeticity rather than a per-variable list that drifts. #1949 first added a second
# `unset TORTOISE_REPO` here; it was dropped on rebase because #2006's single line supersedes it.
# The CONSEQUENCE #1949 cared about (the two gated jobs silently installing) is still pinned below.

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
# assert_line <haystack> <ERE> <label> — for a claim that must hold of a WHOLE line. `grep -F` cannot
# express "a TCC REFUSAL, not a WARN about one": "TCC-protected target" is a substring of
# "WARN TCC-protected target", so a bare contains-assert passed on the line it exists to exclude
# (measured, review P3 round 5). The installer prints refusals with four leading spaces.
assert_line() {
    if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no line matching: $2)"; fi
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
# mkstub <path> — a NON-EMPTY executable stub. `touch` is not enough: the guard refuses a 0-byte
# executed target (execve gives ENOEXEC, the 126/127 class this change exists for), so a fixture that
# models a farmed script must carry a byte.
mkstub() { printf '#!/bin/bash\nexit 0\n' > "$1"; chmod +x "$1"; }
mkfakehome() { # $1 = home dir
    # #2413-audit — the three jobs whose templates name the FARMED copy. On a real box they pointed
    # at `{{AGENT_INFRA_PATH}}/scripts/…` (inside ~/Documents) and launchd exited 126 on every tick
    # under TCC (#427); the farmed path is the only target it can READ, so the fixture must carry it
    # or the broken-target guard refuses the whole §1 install and every section after it.
    mkdir -p "$1/.pi/agent/scripts/orchestrator-harness"
    for f in objective-reminder.sh orchestrator-harness/worker-supply.sh orchestrator-harness/watchdog-loop.sh; do
        mkstub "$1/.pi/agent/scripts/$f"
    done
    mkdir -p "$1/.pi/agent/scripts/checkout-hygiene"
    mkstub "$1/.pi/agent/scripts/checkout-hygiene/corruption_canary.py"
    mkstub "$1/.pi/agent/scripts/checkout-hygiene/provider-latency-tripwire.sh"
    mkstub "$1/.pi/agent/scripts/checkout-hygiene/deepseek-balance-watch.sh"  # #476 poller
    # #373 fleet-cadence farm + #469 pi-session-reaper + #476 balance-watch
    # (setup.sh copies these to the scripts root): the weekly plist's driver +
    # its sibling report/watch/parser AND the reaper/balance-watch drivers must
    # resolve at
    # install time (broken-target guard).
    mkdir -p "$1/.pi/agent/scripts"
    for f in fleet-cost-weekly.sh fleet-cost-report.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh pi-task-session-prune.sh pi-cache-reap.sh pi-reap-orphans.sh pi-reap-worktrees.sh pi-reap-worktrees-launchd.py worktree-hygiene-sweep.sh cleanup-stale-branches.sh ci_runner_gate.sh pr-doctor.py pr-doctor-machine.sh; do
        # mkstub, not `touch`: a 0-byte executed target is REFUSED by the guard (execve ENOEXEC), so a
        # fixture that models a farmed script must carry a byte.
        mkstub "$1/.pi/agent/scripts/$f"
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
    mkstub "$1/.pi/agent/bin/rg"
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
    mkstub "$1/.pi/agent/scripts/lib/pid-identity.sh"
    # #2281 §1: pr-doctor's unit now execs the machine wrapper (fleet_srcs), which resolves the repo
    # SET reader as a sibling `lib/` file (lib_srcs). ⛔ BOTH ARE FIXTURE DATA, NOT A GUARD: the
    # broken-target arm this loop exists for (`verify_targets`) inspects only ABSOLUTE PATHS in
    # ProgramArguments, so it sees the wrapper and would NOT notice a missing `lib/repo-set.sh`. That
    # sibling is caught at RUN time by the wrapper's own farm-gap refusal, which is loud and named —
    # but it is not an install-time verdict, and a comment here claiming otherwise would send the next
    # lane looking for a guard that does not exist. The pair is created here so the fixture mirrors
    # what `setup.sh` actually delivers.
    mkstub "$1/.pi/agent/scripts/lib/repo-set.sh"
    # #1178 unit 3 — the scheduled lane-liveness report runs the FARMED tools:
    # the driver + its sibling classifier under scripts/fleet/ (the broken-target
    # guard refuses the install when they are absent). NOT tools/fleet/: pi's
    # startup scan blocks interactive boot on any non-fd/rg entry there (#1277).
    mkdir -p "$1/.pi/agent/scripts/fleet"
    mkstub "$1/.pi/agent/scripts/fleet/lane_liveness.py"
    mkstub "$1/.pi/agent/scripts/fleet/liveness.py"
    mkdir -p "$1/swarm/.venv/bin"
    mkstub "$1/swarm/.venv/bin/python"
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
if ! CP_ERR="$(cp -R "$REPO_TEMPLATES" "$TEMPLATES" 2>&1)"; then
    # The template DIR is a precondition, not a test failure — every section below would report noise.
    # Say it once, WITH cp's own diagnostic: "is missing" alone sent an operator hunting a renamed
    # directory when the real cause was `Permission denied`.
    echo "FATAL: cannot seed the fixture's templates from $REPO_TEMPLATES: $CP_ERR" >&2
    exit 1
fi

HOME1="$T/home1"; mkfakehome "$HOME1"
HOME2="$T/home2"; mkfakehome "$HOME2"
LOG="$T/launchctl.log"
LOG2="$T/launchctl-retire.log"  # isolated log for the HOME2 retirement section
: > "$LOG"
: > "$LOG2"

# ⛔ THE CHECKOUT UNDER TEST, PINNED SUITE-WIDE. A template target that names {{AGENT_INFRA_PATH}}
# (the controller watchdog does) is rendered from resolve_infra_main(), which prefers $AGENT_INFRA_PATH
# and otherwise reads `git worktree list` — the developer's MAIN checkout. On a box whose ~/agent-infra
# is an older state that path does not carry the script, so the fixture would hard-fail the install for
# a reason that has nothing to do with the template under test, and the same suite would be green on CI
# and red on the operator's laptop (the host-dependence §1 was fixed for). Pinning it to THIS tree makes
# the rendered target the checkout being tested, which is what every other assertion assumes.
#
# ⛔ NOT `export VAR="$(…)"` (#2569 lane). A DECLARATION builtin's exit status is the builtin's,
# not the substitution's, so a FAILED `cd` and an EMPTY answer were the same observable and the
# suite would pin an installer run against an empty root. A bare assignment carries the
# substitution's status, so the `||` below is a real check — and `check-false-pass-shapes.sh`
# (which scans this file) no longer reports the `discarded-status` shape it was red for on main.
AGENT_INFRA_PATH="$(cd "$SCRIPT_DIR/.." && pwd)" || {
  echo "install-launchd.test.sh: cannot resolve the checkout root from SCRIPT_DIR='$SCRIPT_DIR'" >&2
  exit 1
}
export AGENT_INFRA_PATH

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
        # #1863 F10: TORTOISE_REPO is NOT part of the fresh-HOME fixture, and
        # inheriting an ambient one made the bootstrap-count assertion depend on
        # the operator's box (a real tortoise checkout adds the two
        # {{TORTOISE_REPO}}-gated jobs, so the count became 11, not 9). Clearing
        # it removes the ENV candidate ONLY — resolve_env() still auto-detects a
        # checkout (a sibling of this tree included), so this does NOT by itself
        # make section 1 box-independent. What does is F14's DERIVED expectation
        # below, which recomputes the count from this checkout + the fixture HOME.
        export ELDATO_ALLOW_TEST_HOME=1  # #446: fake HOME + launchctl shim above = isolated
        # #1987 — the job set must not depend on whether THIS host has a tortoise checkout. The two
        # {{TORTOISE_REPO}}-gated jobs (branch-reaper #1787, worktree-reaper #1311) install only when
        # the installer resolves a checkout, from the environment OR from disk, so an inherited value
        # made §1's count read 11 here and 9 on CI — the same suite, two different totals. §13/§14 set
        # TORTOISE_REPO explicitly in their own subshell and are the gated jobs' content coverage.
        unset TORTOISE_REPO
        shift
        bash "$INSTALLER" "$@"
    )
}

echo "── 1. Fresh-HOME simulation ──────────────────────────────────────"
# `set -e` aborts on a failing assignment, so without this pair a broken install killed the suite
# BEFORE `assert_eq "$RC" 0` could print — the "fresh install exits 0" line was decorative and the
# section reported nothing but the installer's own stderr (measured on base ce97fe827: a broken
# ProgramArguments target aborted at this line with zero §1 assertions printed). Every other exit-code
# installer capture in this file now runs inside a set +e/set -e window: every `assert_eq "$RC" "0"`
# site and every bare capture that could abort the run before its Summary. (That also means a failing
# install degrades to reported ❌ lines rather than one silent abort — which is how this file used to
# fail, with no tally at all.)
set +e
OUT="$(run_installer "$HOME1")"
RC=$?
set -e
OUT1="$OUT"  # §1's own output. The all-shim PATH guard below reassigns $OUT, so a §1 assertion
             # that reads $OUT late in the section is reading a DIFFERENT run's log.
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
assert_contains "$OUT" "pi-reap-orphans: installed + loaded" "pi-reap-orphans installed on fresh machine (#1142) — the reaper is SCHEDULED, not merely present"
CANARY_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.corruption-canary.plist"
TRIPWIRE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.provider-latency-tripwire.plist"
FLEET_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.fleet-cost-weekly.plist"
REAPER_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-session-reaper.plist"
PRUNE_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-task-session-prune.plist"
CACHE_REAP_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-cache-reap.plist"
DBW_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.deepseek-balance-watch.plist"
ORPHANS_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.pi-reap-orphans.plist"
HUB_RETIRED="$HOME1/Library/LaunchAgents/com.eldato.hub-state-check.plist"
ORACLE_RETIRED="$HOME1/Library/LaunchAgents/com.eldato.skill-lint-oracle.plist"
# #2413 audit — the three units that were ARMED AND DEAD now point at the FARMED copy, and NOTHING
# pinned those three TEMPLATES (P2-C of the #3413 review): `mkfakehome` carries both candidate paths
# and neither is under the fixture's `~/Documents`, so `verify_targets` passed either way and
# reverting `com.eldato.worker-supply.plist` or `com.eldato.controller-watchdog.plist` to
# `{{AGENT_INFRA_PATH}}` left the whole suite green — on the two units with `runs=1766` and the 126
# deaths this change is about. Both directions are asserted: the farmed path is PRESENT and the
# checkout path is ABSENT, so neither half of a revert can hide.
WS_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.worker-supply.plist"
CW_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.controller-watchdog.plist"
OR_INSTALLED="$HOME1/Library/LaunchAgents/com.eldato.objective-reminder.plist"
# ⛔ READ THE RENDERED ProgramArguments VALUE, never the whole file (the same E2-3 lesson
# `installed_path` below records): these plists legitimately carry `AGENT_INFRA_PATH` in
# `EnvironmentVariables`, so a whole-file `assert_not_contains` reds on a CORRECT unit — a false RED
# that invites weakening the assertion instead of the template.
installed_program_args() { # $1 = installed plist → its ProgramArguments <string> values, one per line
    awk '
        /<key>ProgramArguments<\/key>/ { inargs = 1; next }
        inargs && /<\/array>/          { inargs = 0; next }
        inargs && /<string>/           { sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print }
    ' "$1" 2>/dev/null || true
}
assert_contains "$(installed_program_args "$WS_INSTALLED")" "$HOME1/.pi/agent/scripts/orchestrator-harness/worker-supply.sh" \
    "worker-supply plist execs the FARMED copy, still NESTED (#427/#2413)"
assert_not_contains "$(installed_program_args "$WS_INSTALLED")" "$AGENT_INFRA_PATH/scripts/" \
    "…and does NOT exec the checkout path (the ~/Documents form that exits 126, #427/#2413)"
assert_contains "$(installed_program_args "$CW_INSTALLED")" "$HOME1/.pi/agent/scripts/orchestrator-harness/watchdog-loop.sh" \
    "controller-watchdog plist execs the FARMED copy, still NESTED (#427/#2413)"
assert_not_contains "$(installed_program_args "$CW_INSTALLED")" "$AGENT_INFRA_PATH/scripts/" \
    "…and does NOT exec the checkout path (#427/#2413)"
assert_contains "$(installed_program_args "$OR_INSTALLED")" "$HOME1/.pi/agent/scripts/objective-reminder.sh" \
    "objective-reminder plist execs the FARMED copy (#427/#2413)"
assert_not_contains "$(installed_program_args "$OR_INSTALLED")" "$AGENT_INFRA_PATH/scripts/" \
    "…and does NOT exec the checkout path (#427/#2413)"
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
# #1142/#1862 — the orphan reaper is the artifact this issue restores. The
# assertions below are what make the ACCEPTANCE falsifiable: asserting the file
# EXISTS would pass on the pre-change state (the script survived only under
# state/recovered-1161/), so the test must assert the job is SCHEDULED (the
# rendered+installed plist, its interval, and the farmed path it execs) and that
# a pass WRITES FRESH OUTPUT (section 15 runs the real script and reads the log).
assert_contains "$(cat "$ORPHANS_INSTALLED")" "$HOME1/.pi/agent/scripts/pi-reap-orphans.sh" "orphan reaper plist execs the FARMED script (launchd cannot read ~/Documents, #427)"
assert_contains "$(cat "$ORPHANS_INSTALLED")" "StartInterval" "orphan reaper job is interval-scheduled (#1862)"
assert_contains "$(cat "$ORPHANS_INSTALLED")" "<integer>3600</integer>" "orphan reaper runs hourly (StartInterval 3600)"
assert_contains "$(cat "$ORPHANS_INSTALLED")" "agent-infra-plist-version: 0.1.0" "orphan reaper template carries version marker"
# #1142 acceptance: "dry-run by default". Arming is a manual, per-machine, owned
# decision, so a later template edit flipping this to 0 must fail here — without
# this assertion the flip would satisfy every other plist check and silently arm
# an always-on killer on every host at the next sync.
assert_contains "$(cat "$ORPHANS_INSTALLED")" "REAP_ORPHAN_DRY_RUN" "orphan reaper plist carries REAP_ORPHAN_DRY_RUN env"
assert_contains "$(grep -A1 'REAP_ORPHAN_DRY_RUN' "$ORPHANS_INSTALLED" | tail -1)" "<string>1</string>" "orphan reaper SHIPS DISARMED (REAP_ORPHAN_DRY_RUN=1, #1142)"
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
assert_not_contains "$(cat "$CACHE_REAP_INSTALLED")" "<string>--apply</string>" "the committed cache-reap template ships unarmed"
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
  # `|| true`: sed exits 2 on a MISSING plist, and `set -e` then aborted the whole suite inside this
  # assignment — so a broken target (the runner-gate script unfarmed) killed the run mid-§1 with no
  # Summary, which is the failure class the set +e windows above exist to remove (measured: unarming
  # `ci_runner_gate.sh` ended the run at this line with `exit=2`).
  sed -n '/<key>PATH<\/key>/{n;s@.*<string>\(.*\)</string>.*@\1@p;}' "$1" || true
}
GATE_PATH_VAL="$(installed_path "$GATE_INSTALLED")"
# A missing plist would make every PATH assertion below VACUOUS, so state it once instead of crashing.
[ -s "$GATE_INSTALLED" ] && ok "runner-gate plist exists (the PATH assertions below are not vacuous)" \
                        || bad "runner-gate plist MISSING — the PATH assertions below carry no information (an absent plist makes the negative ones pass on an empty string)"
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
[ -s "$TRIPWIRE_INSTALLED" ] && ok "tripwire plist exists (the PATH assertion above is not vacuous)" || bad "tripwire plist MISSING — the PATH assertion above cannot pass"
# #432 — hub-state-check + skill-lint-oracle are RETIRED from launchd (their
# work moved to extensions/session-checks.ts — macOS TCC blocks launchd from
# ~/Documents, so they run from pi's session_start instead).
assert_not_contains "$OUT1" "hub-state-check: installed + loaded" "retired hub job NOT installed on fresh machine"
assert_not_contains "$OUT1" "skill-lint-oracle: installed + loaded" "retired oracle job NOT installed on fresh machine"
[ ! -f "$HUB_RETIRED" ] && ok "no retired hub plist left behind" || bad "no retired hub plist left behind"
[ ! -f "$ORACLE_RETIRED" ] && ok "no retired oracle plist left behind" || bad "no retired oracle plist left behind"
# ⛔ This count is the inventory of ACTIVE jobs, and part of it is HOST-DEPENDENT BY DESIGN: the
# installer resolves {{TORTOISE_REPO}} from the environment AND from disk (install-launchd.sh:76-82 —
# a sibling of this tree, `$HOME/Documents/GitHub/tortoise`, `$HOME/tortoise`), so a checkout
# beside this one installs branch-reaper (#1787) + worktree-reaper (#1311) and a bare CI checkout
# does not. A pinned total is therefore red on one of the two surfaces whichever number is chosen,
# and a pinned 9 measured here reads 11 beside a checkout. So: the always-installable jobs pinned by
# name, plus whichever {{TORTOISE_REPO}}-gated templates THIS run installed, derived from the
# fixture's own template dir — with the gated inventory itself pinned at 4, so a newly added gated
# job cannot raise both sides of the equation at once. The pin is the ONLY place this count is
# stated: adding a gated template without bumping it here reds this suite on main, which is what
# happened when worktree-hygiene (#1095/#1678) landed, and again when pr-doctor + controller-watchdog
# (#2303) landed: the templates arrived, the pin did not. ⛔ IT WAS STALE AGAIN when this branch reached
# it: the tree carries FOUR gated templates (branch-reaper #1787, worktree-reaper #1311,
# worktree-hygiene #2047, pr-doctor #2303) and the pin still said 3, so this shard was red for a reason
# no PR had anything to do with. The number of always-installable jobs is 13 since #2700 added
# `com.eldato.worker-supply` (the repair-pool supply half: it needs only {{AGENT_INFRA_PATH}} +
# {{PATH}} + {{HOME}}, so there is no tortoise gate to skip it on).
BOOTSTRAP_COUNT1="$(grep -c 'launchctl bootstrap' "$LOG" || true)"  # grep -c exits 1 on ZERO matches; `set -e` would kill the run here
GATED_TEMPLATES1=0
GATED_INSTALLED1=0
for _tpl in "$TEMPLATES"/*.plist; do
    grep -q '{{TORTOISE_REPO}}' "$_tpl" || continue
    GATED_TEMPLATES1=$((GATED_TEMPLATES1 + 1))
    case "$OUT1" in *"$(basename "$_tpl" .plist): installed + loaded"*) GATED_INSTALLED1=$((GATED_INSTALLED1 + 1)) ;; esac
done
# ⛔ THE PIN IS AN ACKNOWLEDGEMENT, NOT A CACHE. A newly added gated job must be named HERE, by a human,
# in the same commit that adds it — that is the point of pinning the count instead of deriving it, so a
# template cannot raise both sides of the equation at once. This number went stale when #2047/#2053 added
# `com.tortoise.worktree-hygiene` to the gated set (branch-reaper #1787 + worktree-reaper #1311 +
# worktree-hygiene #2047), and the result was a RED `bash-suites` on main that had nothing to do with any
# PR that touched it. Keep this list in step with `grep -l '{{TORTOISE_REPO}}' templates/launchd/*.plist`.
assert_eq "$GATED_TEMPLATES1" "4" "the {{TORTOISE_REPO}}-gated inventory is accounted for (branch-reaper #1787 + worktree-reaper #1311 + worktree-hygiene #2047 + pr-doctor #2303)"
# ⛔ THE OUTPUT-LOCATION PARAGRAPH HAS BEEN INVERTED TWICE, SO IT GETS A SENSOR AND NOT A THIRD CORRECTION
# (agent-infra#2281 review round 44, P1 — measured). The prose is operator-facing: it says where a live
# verdict is written, and THREE readers open the canonical STATUS file BY NAME — `heartbeat-loop.sh`,
# `lib/fleet-inventory.sh`'s `_fleet_pr_doctor_bound`, and `objective.py`'s `pr_doctor_last_run` (review
# cycle 2 measured the third; an earlier version of this very comment said two, which is the same
# count-goes-stale defect the paragraph itself had). Round 44's first version said the per-repo pairs sat
# "beside" the canonical one; its "correction" then claimed the canonical pair is never written in
# `all-repos` mode — FALSE, because `run_all_repos()` ends by calling `canonical_paths()` and
# `record_exit` writes the SET's aggregate there (measured over two repos: all six files appear and
# `pr-doctor.status.json` carries `repo = "acme/alpha,acme/beta"` plus a two-row `repos` list). Both false
# phrasings are pinned ABSENT and the aggregate fact pinned PRESENT — a paragraph nobody has got right
# first is a claim, not a comment. The negative arms are the safe shape: they red only if the bug returns.
_PRD_TPL="$(cat "$REPO_TEMPLATES/com.tortoise.pr-doctor.plist")"
assert_contains "$_PRD_TPL" "each repo ALSO gets" "pr-doctor template: per-repo pairs are ADDITIONAL, not a replacement"
# ⛔ NOT `grep -qi aggregate`: that needle is satisfied by the paragraph's own narration of the earlier
# FALSE versions ("silent on the AGGREGATE", "the set's aggregate lands back on the canonical names"),
# so deleting the operator-facing statement — or replacing it with round 44's inversion — left this arm
# GREEN (measured, round 45: PASS=439 FAIL=0 with the fact gone). Pin the FACT's own wording, which
# occurs once, and the rc semantics separately.
assert_contains "$(tr 'A-Z' 'a-z' <<<"$_PRD_TPL")" "written with the set's aggregate verdict" "pr-doctor template: still states the SET aggregate lands on the canonical pair"
assert_contains "$_PRD_TPL" '`rc` = the worst of the set' "pr-doctor template: still states the aggregate rc is the WORST of the set"
assert_contains "$_PRD_TPL" "_fleet_pr_doctor_bound" "pr-doctor template: still names a reader that opens the canonical status file by name"
assert_contains "$_PRD_TPL" "pr_doctor_last_run" "pr-doctor template: still names the beat's reader of the same canonical record"
assert_not_contains "$_PRD_TPL" "NOT written at all" "pr-doctor template: does NOT claim the canonical pair is never written (round 44's inversion)"
assert_not_contains "$_PRD_TPL" "the log and the verdict MOVE to" "pr-doctor template: does NOT claim the canonical pair moves away (round 44's inversion)"
# ⛔ THE THREE READERS OPEN THE STATUS FILE, NOT THE PAIR (review round 45, P1 — measured). The sentence
# said "THREE readers open those canonical **files** BY NAME", which is half false: all three open
# `pr-doctor.status.json` (heartbeat-loop.sh:851, objective.py's `pr_doctor_last_run` at :3264,
# lib/fleet-inventory.sh's `_fleet_pr_doctor_bound` at :953) and NOTHING LIVE READS `pr-doctor.log` —
# it has TWO writers — `pr-doctor.py`'s own `log()` (open(_log_path(), "a")) and the heartbeat launcher
# appending a child's stdout (heartbeat-loop.sh:800) — and nothing reads it; the other references only
# print its path (:902/:906) or are prose. An operator reading "those canonical files" is promised a log
# consumer that does not exist,
# which is the same wrong-place-to-look failure the paragraph exists to prevent, inverted. All three
# facts are pinned: the correction itself (negative, so a re-inversion reds), the log fact (positive),
# and the corrected WRITER COUNT (positive — an earlier version of this very comment said ONE appender,
# so the count is the half that went stale and the one a future editor is most likely to restore).
assert_not_contains "$_PRD_TPL" "canonical files BY NAME" "pr-doctor template: does NOT claim three readers open the canonical PAIR (round 45's overstatement)"
assert_contains "$_PRD_TPL" "nothing live READS \`pr-doctor.log\`" "pr-doctor template: says out loud that the log has no live reader"
assert_contains "$_PRD_TPL" "two things that WRITE it are" "pr-doctor template: pins the corrected writer count (two, not one appender)"
# ⛔ THE PATH SENTENCE NAMED A GUARANTEE THE INSTALLER DOES NOT IMPLEMENT (round 48 review, P3 — measured).
# It said PATH "carries the fleet's gh-wrapper dir FIRST", but `launchd_path()` only DROPS entries (unresolved,
# and `*/shims`) and preserves the AMBIENT order — nothing is prepended, so a job installed from a shell with
# no gh wrapper on PATH has none, and an operator debugging a bypassed wrapper was sent to the wrong file.
# Both halves are pinned: the sentence that was false, and the one that replaced it.
assert_contains "$_PRD_TPL" "PATH is the INSTALLER's PATH" "pr-doctor template: says which PATH the job gets — the installer's, not a curated one"
assert_contains "$_PRD_TPL" "Nothing is prepended" "pr-doctor template: says the renderer DROPS only — the order it keeps is the ambient one"
# ⛔ THE DROP RULE IS NARROWER THAN "a */shims dir" (round 48 review, P3 — measured): `launchd_path()`
# matches `*/shims | */shims/*`, so an entry INSIDE a shims dir is dropped too. The prose said only the dir,
# and nothing asserted the clause at all — reverting it to the narrower sentence red NO check. This is the
# pin: the "inside one" half is the load-bearing part.
assert_contains "$_PRD_TPL" "OR ANYTHING INSIDE ONE" "pr-doctor template: the shims drop covers entries INSIDE a shims dir, as launchd_path() does"
assert_not_contains "$_PRD_TPL" "gh-wrapper dir first" "pr-doctor template: never claims a gh wrapper is placed first (install-launchd.sh does not do that)"
# ⛔ AND THE THREE READERS IT NAMES MUST ACTUALLY EXIST (round 46 review, P2 — measured). The arms above
# pin the paragraph's WORDING only, so renaming or deleting `_fleet_pr_doctor_bound` kept them GREEN while
# the operator-facing text named a function nobody can call — the drift this paragraph's own comment says
# has already happened twice. These read the files the paragraph points at.
_rd_missing=""
grep -q '^_fleet_pr_doctor_bound()' "$SCRIPT_DIR/../scripts/lib/fleet-inventory.sh" || _rd_missing="$_rd_missing fleet-inventory.sh:_fleet_pr_doctor_bound"
grep -q '^def pr_doctor_last_run(' "$SCRIPT_DIR/../scripts/objective.py" || _rd_missing="$_rd_missing objective.py:pr_doctor_last_run"
awk '!/^[[:space:]]*#/ && /pr-doctor\.status\.json/ { f=1 } END { exit !f }' "$SCRIPT_DIR/../scripts/heartbeat-loop.sh" || _rd_missing="$_rd_missing heartbeat-loop.sh:pr-doctor.status.json"
if [ -z "$_rd_missing" ]; then
    ok "pr-doctor template: all three readers it names EXIST (status file, beat, inventory)"
else
    bad "pr-doctor template names reader(s) that do not exist — a renamed or deleted reader leaves the operator text pointing at a dead function:$_rd_missing"
fi
# A visible checkout whose resolution produced NOTHING is a regression, not a host without one. Ask
# the same three candidates install-launchd.sh:76-82 asks (the fixture's HOME is the fake one the run
# used, so §13/§14's seeded checkouts cannot make this look resolved).
GATED_VISIBLE1=0
for _cand in "$HOME1/Documents/GitHub/tortoise" "$(cd "$SCRIPT_DIR/.." && pwd)/../tortoise" "$HOME1/tortoise"; do
    if [ -d "$_cand" ] && [ -d "$_cand/.git" ]; then GATED_VISIBLE1=1; break; fi
done
if [ "$GATED_INSTALLED1" -eq 0 ] && [ "$GATED_VISIBLE1" -eq 0 ]; then
    ok "no {{TORTOISE_REPO}}-gated job installed — this host resolves no tortoise checkout"
elif [ "$GATED_INSTALLED1" -eq 0 ]; then
    bad "a tortoise checkout is visible to the installer but NO {{TORTOISE_REPO}}-gated job installed — either the resolution regressed, or the checkout's .venv/bin/python is missing so verify_targets refused the rendered target"
else
    # A PARTIAL set is reachable, and the total alone would absorb it: with branch-reaper's target
    # removed the installer still installs worktree-reaper, then exits non-zero at the end — so
    # `10 + 1 == 11` matches the 11 bootstraps and only the RC assert fails the run. Name the broken
    # invariant instead of relying on the exit code alone.
    assert_eq "$GATED_INSTALLED1" "$GATED_TEMPLATES1" "every {{TORTOISE_REPO}}-gated template installed, or none did"
fi
assert_eq "$BOOTSTRAP_COUNT1" "$((13 + GATED_INSTALLED1))" "fresh install bootstraps only active jobs (13 always-installable on a non-swarm host: corruption-canary + provider-latency-tripwire + fleet-cost-weekly + pi-session-reaper + balance-watch + pi-task-session-prune + pi-cache-reap + lane-liveness + objective-reminder + ci-runner-gate + the #1862-restored pi-reap-orphans + controller-watchdog (#2303) + worker-supply (#2700); pr-doctor is one of the FOUR {{TORTOISE_REPO}}-gated templates above, NOT always-installable, so a list that names it here is off by one the moment someone follows it)"
# #1949 (rebased onto #2006; re-keyed after review): name the two gated JOBS, so an ambient
# `TORTOISE_REPO` fails with its cause instead of being absorbed by the derived count above.
# ⛔ The guard must be `GATED_VISIBLE1` (derived from the FILESYSTEM), never `GATED_INSTALLED1`:
# `GATED_INSTALLED1` is itself incremented when `$OUT1` contains `"<job>: installed + loaded"`, so
# guarding these assertions on it is TAUTOLOGICAL — `GATED_INSTALLED1 == 0` already implies the needle
# is absent, and the assertions could never go red. Worse, the exact surface they exist to catch — an
# ambient `TORTOISE_REPO` resolving a checkout that NO disk candidate explains (`GATED_VISIBLE1 == 0`
# while `GATED_INSTALLED1 > 0`) — is the one where the count assertion `10 + GATED_INSTALLED1` ABSORBS the
# leak and the else-branch's `installed == templates` still holds. Keyed on the independent observation,
# that case now reds HERE. (`run_installer` also unsets `TORTOISE_REPO` per run since #1987, so the leak
# is currently unreachable — this pin guards that unset's removal.)
if [ "$GATED_VISIBLE1" -eq 0 ]; then
    assert_not_contains "$OUT1" "branch-reaper: installed" "the {{TORTOISE_REPO}}-gated branch-reaper is SKIPPED although no checkout is visible (ambient TORTOISE_REPO must not leak in)"
    assert_not_contains "$OUT1" "worktree-reaper: installed" "the {{TORTOISE_REPO}}-gated worktree-reaper is SKIPPED although no checkout is visible (ambient TORTOISE_REPO must not leak in)"
fi

echo "── 2. Retirement: pre-seeded old plists get unloaded + removed ───"
seed_retired "$HOME2"
set +e
OUT="$(LOG="$LOG2" run_installer "$HOME2")"
RC=$?
set -e
assert_eq "$RC" "0" "installer with seeded retired jobs exits 0"
assert_contains "$OUT" "com.eldato.hub-state-check: RETIRED (unloaded + removed)" "hub retired job unloaded + removed"
assert_contains "$OUT" "com.eldato.skill-lint-oracle: RETIRED (unloaded + removed)" "oracle retired job unloaded + removed"
[ ! -f "$HOME2/Library/LaunchAgents/com.eldato.hub-state-check.plist" ] && ok "hub retired plist file gone" || bad "hub retired plist file gone"
[ ! -f "$HOME2/Library/LaunchAgents/com.eldato.skill-lint-oracle.plist" ] && ok "oracle retired plist file gone" || bad "oracle retired plist file gone"
set +e
OUT="$(LOG="$LOG2" run_installer "$HOME2")"
RC=$?
set -e
assert_eq "$RC" "0" "retirement is idempotent (second run exits 0)"
assert_not_contains "$OUT" "RETIRED (unloaded + removed)" "no repeat retirement chatter"
# A retired label that STILL has a template is a config error → loud + exit 1.
# The `cp` is guarded: a renamed/removed template is a broken target, and under `set -e` a bare `cp`
# ended the whole suite here with `cp: cannot stat …`, exit 1 and no tally at all (§2 through §14
# never ran). Report the missing vehicle template and carry on with the next section.
if cp "$REPO_TEMPLATES/com.eldato.provider-latency-tripwire.plist" "$TEMPLATES/com.eldato.hub-state-check.plist" 2>/dev/null; then
    :  # vehicle template present
else
    bad "retire/template conflict: the vehicle template (provider-latency-tripwire) is missing — this section cannot run"
fi
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
            "$TEMPLATES/com.eldato.corruption-canary.plist" || true)"  # sed exits 2 on a missing template; `set -e` would kill the run here
    r2="$(HOME="$HOME2" TEMPLATES_DIR="$TEMPLATES" SWARM_ROOT="$HOME2/swarm" \
        PYTHON_BIN="$HOME2/swarm/.venv/bin/python" \
        sed -e "s|{{HOME}}|$HOME2|g" -e "s|{{PYTHON_BIN}}|$HOME2/swarm/.venv/bin/python|g" \
            "$TEMPLATES/com.eldato.corruption-canary.plist" || true)"
    # ⛔ An EMPTY render must never read as determinism: two failed reads hash to the same empty
    # string, so a missing template turned this into a vacuous ✅ (measured: the canary-removal run
    # printed `sed: can't read …` and then "same env → byte-identical render").
    if [ -z "$r1" ] || [ -z "$r2" ]; then
        bad "render determinism: a render came back EMPTY (the template could not be read) — nothing was compared"
        return 0
    fi
    assert_eq "$(printf '%s' "$r1" | shasum | cut -d' ' -f1)" \
        "$(printf '%s' "$r2" | shasum | cut -d' ' -f1)" \
        "same env → byte-identical render"
}
render_twice

echo "── 4. Idempotent skip ────────────────────────────────────────────"
set +e
OUT="$(run_installer "$HOME1")"
RC=$?
set -e
assert_eq "$RC" "0" "re-run exits 0"
assert_contains "$OUT" "provider-latency-tripwire: unchanged (skip)" "tripwire job skipped when identical"
assert_contains "$OUT" "corruption-canary: unchanged (skip)" "canary job skipped when identical"
BOOTSTRAP_COUNT2="$(grep -c 'launchctl bootstrap' "$LOG" || true)"  # grep -c exits 1 on ZERO matches; `set -e` would kill the run here
assert_eq "$BOOTSTRAP_COUNT2" "$BOOTSTRAP_COUNT1" "no reload on no-change"

echo "── 5. Change → reload ────────────────────────────────────────────"
sed -i.bak 's/<integer>3600<\/integer>/<integer>3601<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak || true
set +e
OUT="$(run_installer "$HOME1")"
RC=$?
set -e
assert_eq "$RC" "0" "change install exits 0"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "tripwire reloaded on template change"
assert_contains "$(cat "$TRIPWIRE_INSTALLED")" "3601" "new StartInterval applied"
BOOTSTRAP_COUNT3="$(grep -c 'launchctl bootstrap' "$LOG" || true)"  # grep -c exits 1 on ZERO matches; `set -e` would kill the run here
assert_eq "$BOOTSTRAP_COUNT3" "$((BOOTSTRAP_COUNT2 + 1))" "exactly one reload for the changed job"

echo "── 6. Bootstrap failure is loud ──────────────────────────────────"
# Force a change so the installer reloads — with the shim configured to fail
# bootstrap. Must be loud + non-zero.
sed -i.bak 's/<integer>3601<\/integer>/<integer>3600<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak || true
sed -i.bak 's/<integer>3600<\/integer>/<integer>3602<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak || true
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
sed -i.bak 's/<integer>3602<\/integer>/<integer>3601<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak || true
set +e
OUT="$(run_installer "$HOME1" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "broken script target → exit 1"
assert_contains "$OUT" "broken target" "broken target named"
assert_contains "$OUT" "FAIL" "broken target refuses install"
BOOTSTRAP_COUNT4="$(grep -c 'launchctl bootstrap' "$LOG" || true)"  # grep -c exits 1 on ZERO matches; `set -e` would kill the run here
assert_eq "$BOOTSTRAP_COUNT4" "$((BOOTSTRAP_COUNT3 + 1))" "no bootstrap for a refused job (count frozen after test 6's failed reload)"
echo "── 7b. TCC-protected target refusal (#427 / #2413 audit) ─────────"
# MEASURED 2026-11-03 on the orchestrator box: four jobs were loaded, ran (1766 / 44 / 2 times) and
# exited 126/2 because their ProgramArguments named a script inside ~/Documents — a tree macOS TCC
# denies to every launchd-spawned process. `verify_targets` tested EXISTENCE only, so it PASSED them
# and the installer armed a unit that could never start. This section pins the fix: a target inside a
# TCC-protected root is refused BY NAME and nothing is bootstrapped for it.
#
# The guard reads $HOME at install time, so the case is built under the fixture HOME — never the
# operator's real ~/Documents.
mkdir -p "$HOME1/Documents/checkout/scripts"
touch "$HOME1/Documents/checkout/scripts/tcc-dead.sh"
chmod +x "$HOME1/Documents/checkout/scripts/tcc-dead.sh"
sed -i.bak \
    -e 's#<string>{{HOME}}/.pi/agent/scripts/objective-reminder.sh</string>#<string>{{HOME}}/Documents/checkout/scripts/tcc-dead.sh</string>#' \
    "$TEMPLATES/com.eldato.objective-reminder.plist" \
    && rm -f "$TEMPLATES/com.eldato.objective-reminder.plist".bak || true
rm -f "$HOME1/Library/LaunchAgents/com.eldato.objective-reminder.plist"
BOOTSTRAP_OBJ_BEFORE="$(grep -c 'bootstrap.*com\.eldato\.objective-reminder' "$LOG" || true)"
set +e
OUT="$(run_installer "$HOME1" 2>&1)"
RC=$?
set -e
# The verdict is a SKIP of THIS unit, not a failed install — `RC` here is 1 for the tripwire job §7
# broke, so it proves nothing about this case; what is asserted is the UNIT's own verdict. Both
# directions are pinned: `SKIP` present (it is not installed, and not armed) and `FAIL` absent (it does
# not take the whole install down with it, which is the #3413 P1-A consequence `sync.sh` died of).
assert_contains "$OUT" "SKIP com.eldato.objective-reminder" "TCC-protected unit is SKIPPED by name"
assert_not_contains "$OUT" "FAIL com.eldato.objective-reminder" "TCC-protected unit does not FAIL the install (sync.sh would die)"
assert_line "$OUT" '^    TCC-protected target: ' "TCC-protected target named"
assert_contains "$OUT" "Operation not permitted" "the 126 symptom is named in the refusal"
# The whole point: the guard must not merely WARN — the unit is absent, not half-installed. The file
# check can only catch a regression that INSTALLS anyway (the `rm -f` above made it absent); the
# bootstrap count is the other half, because a half-installed unit is `mv`'d into place BEFORE
# `launchctl bootstrap`. Reported with bad/ok, NOT `exit 1`: aborting here would preempt the count
# assertion below in exactly the mutation it exists to catch (review P3).
if [ -e "$HOME1/Library/LaunchAgents/com.eldato.objective-reminder.plist" ]; then
    bad "the TCC-protected unit is absent afterwards (it was installed anyway)"
else
    ok "the TCC-protected unit is absent afterwards"
fi
assert_eq "$(grep -c 'bootstrap.*com\.eldato\.objective-reminder' "$LOG" || true)" "$BOOTSTRAP_OBJ_BEFORE" "no bootstrap for the skipped TCC-protected unit"
# Restore the template + fixture so later sections install cleanly.
# ⛔ NO VERSION-BUMP SED HERE (#3413 review P3). An earlier draft rewrote `agent-infra-plist-version`
# to force a reinstall and rewrote it back; the `rm -f` above already forces that, and the pairs
# hardcoded `0.2.0`, so the next template bump would have made them silent no-ops.
sed -i.bak \
    -e 's#<string>{{HOME}}/Documents/checkout/scripts/tcc-dead.sh</string>#<string>{{HOME}}/.pi/agent/scripts/objective-reminder.sh</string>#' \
    "$TEMPLATES/com.eldato.objective-reminder.plist" \
    && rm -f "$TEMPLATES/com.eldato.objective-reminder.plist".bak || true

echo "── 7c. verify_targets: WHICH argument may refuse, and which resolutions are load-bearing ──"
# §7b proves the WHOLE-installer refusal through a real template. This section proves the rules the
# guard is built on, one ProgramArguments array at a time, by pointing the installer at a
# single-template directory — so a failure here names the rule, not "an install failed".
#
# ⛔ WHY EACH CASE EXISTS (the first five were live holes found in review of the previous revisions;
# the last two are the empty-as-PASS that #1743 named and this change fixes):
#   * SYMLINKED farm entry — `is_tcc_protected` used to resolve only the target's DIRECTORY, so a
#     farm copy that is itself a symlink into ~/Documents was read as a clean path and the dead unit
#     was armed. This case is RED when the physical-target resolution is dropped.
#   * HOME REACHED VIA A SYMLINK — the roots are built from `$HOME`, so when `$HOME` is itself a
#     symlink the LITERAL root never prefixes a physical target. This case is RED when the
#     physical-ROOT comparison is dropped (it is the only case that reaches that block).
#   * `/usr/bin/env bash <script>` — the script sits at argv[2], so a fixed "argv[0..1] are the
#     command" index rule would file it as DATA and merely warn. RED if the classification is
#     replaced by an index.
#   * `/bin/bash -e <script>` — RED if the command prefix is closed at the first option instead of
#     found by locating the script the interpreter READS (the first revision warned here and armed
#     the dead unit).
#   * `{{TORTOISE_REPO}}/.venv/bin/python` at argv[0] — the two shipped `com.tortoise.*` reapers, and
#     the documented default checkout IS a TCC root. RED if an `exec` target is ever reported as a
#     DATA argument (install proceeds, dead unit armed), and RED if it is turned back into a failed
#     install instead of a SKIP of that one unit (the #3413 P1-A consequence: installer exit 1 →
#     `sync.sh` under `set -e` dies before its cost-config and parity gates).
#   * DATA argument under a TCC root — `--repo ~/Documents/GitHub/tortoise` is the DOCUMENTED DEFAULT
#     of three shipped templates (plus `--root {{SWARM_ROOT}}` on the canary). RED if data arguments
#     are refused again.
#   * unreadable plist / no absolute target — RED if either becomes a pass.
PROBE_DIR="$T/probe-templates"
PROBE_HOME="$T/probe-home"
probe_install() { # <home> <program-argument>... → installer stdout+stderr; rc is the installer's
    _probe_install 1 "$@"
}
# Same, but it LEAVES a previously installed probe plist in place — the state every real box is in,
# and the only way to see whether a SKIP disarms what an earlier run armed.
probe_install_keep_installed() { _probe_install 0 "$@"; }
_probe_install() { # <clear-installed:0|1> <home> <program-argument>...
    local clear="$1" home="$2" a body=""; shift 2
    for a in "$@"; do body="$body        <string>$a</string>"$'\n'; done
    rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
    cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
$body    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
</dict>
</plist>
PLIST
    [ "$clear" = "1" ] && rm -f "$home/Library/LaunchAgents/com.eldato.tccprobe.plist"
    ( export HOME="$home"
      export PATH="$T/bin:$PATH"
      export FAKE_LAUNCHCTL_LOG="$LOG"
      export TEMPLATES_DIR="$PROBE_DIR"
      export AGENTS_DIR="$home/Library/LaunchAgents"
      export ELDATO_ALLOW_TEST_HOME=1
      # No {{…}} placeholders in the probe plist, so none of the job env is needed; clearing it keeps
      # an ambient TORTOISE_REPO out of a fixture that is about ProgramArguments only.
      unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
      bash "$INSTALLER" 2>&1 )
}
# Same, but the unit carries launchd's `Program` key instead of a ProgramArguments array — the shape
# whose launcher the guard must file-type-check as well as TCC-check.
probe_install_program() { # <home> <program-path> → installer stdout+stderr; rc is the installer's
    local home="$1" prog="$2"
    rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
    cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>Program</key><string>$prog</string>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
    rm -f "$home/Library/LaunchAgents/com.eldato.tccprobe.plist"
    ( export HOME="$home"
      export PATH="$T/bin:$PATH"
      export FAKE_LAUNCHCTL_LOG="$LOG"
      export TEMPLATES_DIR="$PROBE_DIR"
      export AGENTS_DIR="$home/Library/LaunchAgents"
      export ELDATO_ALLOW_TEST_HOME=1
      unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
      bash "$INSTALLER" 2>&1 )
}
mkfakehome "$PROBE_HOME"
mkdir -p "$PROBE_HOME/Documents/checkout/scripts"
PROBE_DEAD="$PROBE_HOME/Documents/checkout/scripts/tcc-dead.sh"
# ⛔ `mkstub`, NOT `touch`. This fixture models a SCRIPT in the checkout, and the guard refuses a
# 0-byte executed target (execve gives ENOEXEC) — see `mkstub`'s own comment above. It was left empty
# here, which made every "same tree, installing" row below bless an INERT unit without anyone deciding
# to: the fixture's emptiness was incidental to what those rows test (the grant verdict), and it hid
# the hole (c22h2) pins.
mkstub "$PROBE_DEAD"
mkstub "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh"
# the two `com.tortoise.*` reapers exec the CHECKOUT's own interpreter; §7c (c3) reproduces that shape
mkdir -p "$PROBE_HOME/Documents/checkout/.venv/bin"
# a BINARY (magic bytes that are not `#!`): a zero-byte placeholder would be "unreadable/empty", which
# the guard now treats as CANNOT-HOLD-A-GRANT, and the launcher case would flip to a SKIP (correctly).
printf '\177ELF\002\001\001\000' > "$PROBE_HOME/Documents/checkout/.venv/bin/python"
chmod +x "$PROBE_HOME/Documents/checkout/.venv/bin/python"

# control — a clean argv installs, so the refusals below are not "everything fails on this host".
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" --loop 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c control: a farmed exec target + a relative data arg installs"

# ── the guard's own functions, driven directly ────────────────────────────────────────────────
# Going through the installer cannot reach two facts at all: (1) CASE, because a case-varied path
# does not EXIST on a case-sensitive filesystem, so the broken-target check fires first on Linux and
# the TCC branch is never taken; (2) a path that need not exist. Both matter (a case-blind guard is a
# fail-open on every default Mac volume), so the functions are EXTRACTED from the shipped file and
# driven in a subshell exactly as the installer calls them. The extraction is asserted non-empty: a
# silent empty `$GUARD_LIB` would make every probe below vacuously "ok".
GUARD_LIB="$T/guard-lib.sh"
sed -n '/^tcc_protected_roots()/,/^}/p;/^physical_path()/,/^}/p;/^tcc_protected_root()/,/^}/p;/^is_tcc_protected()/,/^}/p' \
    "$INSTALLER" > "$GUARD_LIB"
if grep -q '^is_tcc_protected()' "$GUARD_LIB" && grep -q '^physical_path()' "$GUARD_LIB" \
   && grep -q '^tcc_protected_root()' "$GUARD_LIB" && grep -q '^tcc_protected_roots()' "$GUARD_LIB"; then
    ok "§7d the guard's functions extract from the shipped installer (a probe below is not vacuous)"
else
    bad "§7d could not extract tcc_protected_root/is_tcc_protected/physical_path/tcc_protected_roots — every probe below would be vacuous"
fi
guard() { # <home> <path> → "protected" | "ok"
    ( HOME="$1"; . "$GUARD_LIB"; if is_tcc_protected "$2"; then echo protected; else echo ok; fi )
}
assert_eq "$(guard /h /h/Documents/x)" "protected" "§7d a literal Documents path is protected"
# ⛔ THE CASE VARIANTS ARE THE MACOS FAIL-OPEN: APFS is case-insensitive, so ALL THREE of these are
# the same directory to the kernel. RED if `nocasematch` is dropped.
assert_eq "$(guard /h /h/documents/x)" "protected" "§7d …and its lowercase spelling (/h/documents/x IS /h/Documents/x on APFS)"
assert_eq "$(guard /h /h/DOCUMENTS/x)" "protected" "§7d …and its uppercase spelling"
assert_eq "$(guard /h /h/Desktop/x)" "protected" "§7d Desktop is a root too"
assert_eq "$(guard /h /h/Projects/x)" "ok" "§7d a path outside every root is NOT protected (no blanket refusal)"
# (i) the physical-TARGET resolution, at function level: the file is a symlink into the tree.
T_DOCS="$T/guardhome"; rm -rf "$T_DOCS"; mkdir -p "$T_DOCS/Documents/real" "$T_DOCS/other"
: > "$T_DOCS/Documents/real/dead.sh"
ln -sfn "$T_DOCS/Documents/real/dead.sh" "$T_DOCS/other/alias.sh"
assert_eq "$(guard "$T_DOCS" "$T_DOCS/other/alias.sh")" "protected" "§7d a symlink whose TARGET is inside the tree is protected (physical target)"
# the reverse direction: a symlink whose target is ALSO outside the tree must NOT be refused — the
# physical-target resolution must not turn into a blanket refusal of every symlinked path.
: > "$T_DOCS/other/ok.sh"
ln -sfn "$T_DOCS/other/ok.sh" "$T_DOCS/other/alias-out.sh"
assert_eq "$(guard "$T_DOCS" "$T_DOCS/other/alias-out.sh")" "ok" "§7d a symlink whose TARGET is outside the tree is NOT refused (no blanket)"
# (ii) $HOME itself reached through a symlink: only the physical ROOT matches.
ln -sfn "$T_DOCS" "$T/linkhome"
assert_eq "$(guard "$T/linkhome" "$T_DOCS/Documents/real/dead.sh")" "protected" "§7d a physical target under a SYMLINKED \$HOME is protected (physical ROOT)"
assert_eq "$(guard "$T/linkhome" "$T_DOCS/other/nope-anywhere")" "ok" "§7d …and an unrelated path under it is not (the root match is not a blanket)"

# (a) the farm ENTRY is a symlink into the protected tree → the physical TARGET is what TCC gates.
# A TCC-protected EXEC target is verdict 2: this ONE unit is skipped and the install still exits 0
# (a failed install is what killed `sync.sh`). Both halves are asserted — the SKIP and the exit code.
ln -sfn "$PROBE_DEAD" "$PROBE_HOME/.pi/agent/scripts/farm-alias.sh"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/farm-alias.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a TCC-protected exec target SKIPS the unit and does not fail the install (#3413 P1-A)"
assert_line "$OUT" '^    TCC-protected target: ' "§7c a farm entry that SYMLINKS into ~/Documents is named as TCC-protected (physical TARGET)"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and that unit is SKIPPED by name, not installed"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and nothing is installed for it (an armed unit that exits 126 is the defect)"
else
    ok "§7c …and nothing is installed for it (an armed unit that exits 126 is the defect)"
fi

# (b) $HOME is reached through a symlink, target passed PHYSICALLY: only the physical ROOT matches.
PROBE_LINK="$T/probe-homelink"; ln -sfn "$PROBE_HOME" "$PROBE_LINK"
set +e
OUT="$(probe_install "$PROBE_LINK" /bin/bash "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c a physical target under a SYMLINKED \$HOME is caught (physical ROOT)"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …by the same verdict-2 SKIP"

# (c) `/usr/bin/env bash <script>`: the script is argv[2], and it is still a COMMAND, not data.
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env bash "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c /usr/bin/env bash <TCC script> is an EXEC target (argv order, not an index)"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not misfiled as data"

# (c2) `/bin/bash -e <script>`: the script comes AFTER an option, and is still the executed command.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash -e "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c /bin/bash -e <TCC script> is an EXEC target (the prefix is found by locating the script)"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not misfiled as data"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …so nothing is installed for it"
else
    ok "§7c …so nothing is installed for it"
fi

# (c6) an interpreter option that takes a SEPARATE VALUE (`-o pipefail`, `-W error`): the value is
# not the script. A "first non-option token is the script" rule files the real script as data and
# arms the dead unit (review P3, cycle 2) — this is RED under that rule.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash -o pipefail "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c /bin/bash -o pipefail <TCC script> is an EXEC target (an option value is not the script)"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not misfiled as data"

# (c7) no INTERPRETER ALLOW-LIST: `…/python3.11` executes a script just like `…/python3` does, and a
# name-based list misses it (review P3, cycle 2) — the classification does not depend on the name.
mkdir -p "$PROBE_HOME/.pi/agent/bin"
touch "$PROBE_HOME/.pi/agent/bin/python3.11"; chmod +x "$PROBE_HOME/.pi/agent/bin/python3.11"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_HOME/.pi/agent/bin/python3.11" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c …/python3.11 <TCC script> is an EXEC target (no allow-list to fall outside of)"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not misfiled as data"

# (c8) `bash -- <script>` and `bash --noprofile <script>`: `--` is the POSIX END OF OPTIONS and
# `--noprofile` takes no value, so in both the NEXT token is the script the shell will READ. Treating
# "preceded by a `--…` token" as data armed the dead unit (review P2, cycle 3).
for _probe_opt in -- --noprofile; do
    set +e
    OUT="$(probe_install "$PROBE_HOME" /bin/bash "$_probe_opt" "$PROBE_DEAD" 2>&1)"; RC=$?
    set -e
    assert_line "$OUT" '^    TCC-protected target: ' "§7c /bin/bash $_probe_opt <TCC script> is an EXEC target (no value is introduced)"
    assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and $_probe_opt does not turn the script into data"
    if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
        bad "§7c …so nothing is installed for it ($_probe_opt)"
    else
        ok "§7c …so nothing is installed for it ($_probe_opt)"
    fi
done

# (c9) the `--opt=<path>` form: the value is INSIDE the token, so a reader that only looks at
# elements STARTING with "/" never sees it at all (review P3, cycle 3). `--repo=<TCC dir>` is data
# (installs + WARN); `--script=<TCC script>` is EXECUTED code (SKIP) — the launcher opens it and
# feeds it to `bash -s`, which is why it is not in the data class.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" "--repo=$PROBE_HOME/Documents/checkout" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c --repo=<TCC dir> installs (the = form carries the same value as the space form)"
assert_contains "$OUT" "WARN TCC-protected data argument" "§7c …and the = form is classified as DATA, not invisible"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" "--script=$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c --script=<TCC script> is EXECUTED code, so it verdicts 2"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not filed as data"

# (c10) a SHEBANG SCRIPT at argv[0] inside a TCC root is DEAD: the kernel hands it to its interpreter,
# so the binary that reads it is /bin/bash -- the one #427 measured is denied. Only a BINARY launcher
# can hold the grant (#1311 measured the checkout interpreter). RED if the launcher arm stops checking
# the magic bytes (review P2, round 4).
PROBE_SH="$PROBE_HOME/Documents/checkout/shebang-probe.sh"
printf '#!/bin/bash\nexit 0\n' > "$PROBE_SH"; chmod +x "$PROBE_SH"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_SH" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a shebang launcher inside a TCC root does not fail the install (one dead unit)"
assert_line "$OUT" '^    TCC-protected target: ' "§7c a SHEBANG SCRIPT at argv[0] in a TCC root is refused as a target (its interpreter is the denied bash)"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …and is NOT excused by the launcher arm (that arm is for BINARIES)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …so it is not installed"
else
    ok "§7c …so it is not installed"
fi

# (c11) the launcher's grant is PER TREE: Documents and Desktop are separate Files-and-Folders grants,
# so a TCC binary launcher under Documents does NOT vouch for a script under Desktop. RED if the check
# compares a bare boolean instead of the matched root (review P3, round 4).
mkdir -p "$PROBE_HOME/Desktop"
PROBE_DESK="$PROBE_HOME/Desktop/desktop-dead.sh"
printf 'exit 0\n' > "$PROBE_DESK"; chmod +x "$PROBE_DESK"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_HOME/Documents/checkout/.venv/bin/python" "$PROBE_DESK" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a TCC launcher does not fail the install for a target in ANOTHER TCC tree"
assert_line "$OUT" '^    TCC-protected target: ' "§7c a target in a DIFFERENT TCC tree is refused, not excused by the launcher"
# ⛔ THE NEEDLE MUST BE A STRING THE INSTALLER CAN ACTUALLY PRINT. This used to read `inside the SAME
# TCC tree`, which appears NOWHERE in `scripts/install-launchd.sh` — the same-tree WARN says `inside
# <root>, the SAME tree this unit's launcher holds a grant for` — so the assertion reported PASS under
# EVERY mutant, including the one that restores the bare-boolean grant comparison this case exists to
# exclude (fresh review of #3413 at d9886d32, FINDING 1). Both needles below are behaviour-anchored
# (`WARN TCC-protected target:` is the arm that arms the unit), and the prose half is pinned in the
# POSITIVE direction at (c22h) below, so a reworded WARN reddens there instead of making this pair
# vacuous again.
assert_not_contains "$OUT" "WARN TCC-protected target:" "§7c …and it is REFUSED, not WARNed as a same-tree target"
assert_not_contains "$OUT" "the SAME tree" "§7c …and the message does not claim a shared tree"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …so it is not installed"
else
    ok "§7c …so it is not installed"
fi

# (c12) the PlistBuddy FALLBACK reader (review P3, round 4: no test reached it on Linux, and it could
# disagree with the python reader about which element is argv[0]). The seam makes it drivable: a
# rendered plist python3 refuses (`<integer>not-a-number</integer>` is well-formed XML but not a plist
# integer) is read by the shim, which prints PlistBuddy's own `Array { idx = val }` format.
FAKE_PB="$T/bin/fake-plistbuddy"
cat > "$FAKE_PB" <<'SHIM'
#!/usr/bin/env bash
# PlistBuddy-style output for ProgramArguments, WITHOUT python3 -- this reader is the fallback for a
# host whose python3 cannot parse the plist. Real invocation is `-c CMD <plist>`.
#
# ⛔ THE COMMAND IS HONOURED, because real PlistBuddy is key-scoped: `Print :Program` on a plist with
# no such key EXITS NON-ZERO (the installer reads that as "no Program", not "cannot read"). A shim
# that printed the array for every command made `Program` look present on every fixture, so the
# launcher rule could not be tested at all (fresh review of #3413, P1/P2).
case "$2" in
    *:ProgramArguments*)
        echo "Array {"
        awk '
            /<key>ProgramArguments<\/key>/ { inside = 1; next }
            inside && /<\/array>/          { inside = 0 }
            inside && /<string>/            {
                gsub(/.*<string>/, ""); gsub(/<\/string>.*/, "")
                printf "    %d = %s\n", n++, $0
                found = 1
            }
            END { if (!found) exit 1 }
        ' "$3" || exit 1
        echo "}"
        ;;
    *:Program*)
        # The key and its <string> may share a LINE (`<key>Program</key><string>/x</string>`), so the
        # whole file is matched as one buffer rather than walked line by line -- a line-walker that
        # `next`s on the key line never sees a same-line value (measured: it made every fixture look
        # like it had no Program at all).
        awk '
            { buf = buf $0 "\n" }
            END {
                if (match(buf, /<key>Program<\/key>[[:space:]]*<string>[^<]*<\/string>/)) {
                    s = substr(buf, RSTART, RLENGTH)
                    gsub(/.*<string>/, "", s); gsub(/<\/string>.*/, "", s)
                    print s; found = 1
                }
                if (!found) exit 1
            }
        ' "$3" || exit 1
        ;;
    *)
        exit 1
        ;;
esac
SHIM
chmod +x "$FAKE_PB"
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROBE_DEAD</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_contains "$OUT" "TCC-protected target: $PROBE_DEAD" "§7c the PlistBuddy fallback reader classifies argv[1] as an EXEC target (same rule as python)"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …and does not mistake a later element for argv[0]"
assert_not_contains "$OUT" "cannot read ProgramArguments" "§7c …and an unparseable-by-python plist is still READ by the fallback, not refused"

# (c12b) READER AGREEMENT on an EMPTY element: python counts every element (enumerate), so the element
# AFTER an empty one is argv[1]; an awk that skipped the empty row without advancing would call it
# argv[0] and excuse it as a LAUNCHER instead of verdicting it. Synthetic (a real plist has no empty
# element) and driven through the same seam, because this is the only way the fallback reader is
# exercised on Linux. RED if the awk stops advancing on an empty row.
# ⛔ THE FIXTURE IS A BINARY-INSIDE-A-TCC-ROOT ON PURPOSE. An earlier version put the `#!/bin/bash`
# script `$PROBE_DEAD` here, and BOTH roles (launcher / exec) land in a TCC refusal for a script, so the
# assertions passed whether or not the row advanced — the test claimed a pin it did not have, and that
# is what hid the fail-open it was written to catch (fresh review of #3413, round 3 P2). A BINARY holds
# the grant (#1311), so the two roles give OPPOSITE outcomes: argv[1] → refusal, argv[0] → WARN+install.
PROBE_ALIGN_BIN="$PROBE_HOME/Documents/checkout/.venv/bin/python"
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string></string>
        <string>$PROBE_ALIGN_BIN</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_contains "$OUT" "TCC-protected target: $PROBE_ALIGN_BIN" "§7c an element AFTER an empty one is still argv[1] (the two readers advance alike)"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …so it is verdict-2, not excused as a launcher (a BINARY would have been WARNed+installed)"
assert_not_contains "$OUT" "installed + loaded" "§7c …and the unit is not installed"

# (c12c) an EMPTY element in the MIDDLE, which is the OTHER half of the same alignment rule: python takes
# `prev = argv[i - 1]`, so after an empty element `prev` IS `""` and the next absolute path is EXEC, not
# the value of the `--repo` before the gap. An awk that skipped the empty row without updating `prev`
# still saw `--repo`, called that path `data`, and WARNed + INSTALLED a unit python refuses (fresh review
# of #3413, round 4 P2). RED if the empty row leaves `prev` untouched.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>--repo</string>
        <string></string>
        <string>$PROBE_DEAD</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_contains "$OUT" "TCC-protected target: $PROBE_DEAD" "§7c an element after a MID-LIST empty one is EXEC, not the --repo value before the gap"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …so it is not WARNed as DATA (the empty row clears prev)"
assert_not_contains "$OUT" "installed + loaded" "§7c …and the unit is not installed"

# (c13) launchd's `Program` key IS the executed binary: `ProgramArguments[0]` is only argv[0]. A
# `Program` pointing into a TCC tree is armed-and-dead even when every argument is farmed and readable
# (review P3, round 5 — the reader modelled argv[0] only).
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>Program</key><string>$PROBE_HOME/Documents/checkout/shebang-probe.sh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c a Program= key pointing into a TCC root is the LAUNCHER and verdicts 2 (not invisible)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and the unit is not installed"
else
    ok "§7c …and the unit is not installed"
fi

# (c14) a `Program`-ONLY unit is a VALID launchd unit — it must not be refused for having no
# ProgramArguments array (the mirror error of (c13)).
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>Program</key><string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a Program-ONLY unit installs (a valid launchd unit, not 'no ProgramArguments')"
assert_not_contains "$OUT" "cannot read ProgramArguments" "§7c …and is not refused as unreadable"

# (c15) an UNREADABLE launcher cannot hold a grant: "cannot read" must resolve to the refusal
# direction, never to "is a binary" (review P2, round 5 — a chmod 000 re-opened the fail-open).
PROBE_UNREADABLE="$PROBE_HOME/Documents/checkout/unreadable.sh"
printf '#!/bin/bash\nexit 0\n' > "$PROBE_UNREADABLE"
chmod 000 "$PROBE_UNREADABLE"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_UNREADABLE" 2>&1)"; RC=$?
set -e
# the launcher is INSIDE the tree, so the TCC verdict wins (skip, disarm) — what matters is that
# "cannot read" is NOT read as "is a binary that holds the grant" (fresh review of #3413, P2).
assert_eq "$RC" "0" "§7c an UNREADABLE launcher inside a TCC root is skipped, not failed (a FAIL would kill sync.sh)"
assert_line "$OUT" '^    TCC-protected target: ' "§7c …verdict 2, never excused as a grant-holding binary"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …cannot-read is NOT treated as a binary grant"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and the unit is not installed"
else
    ok "§7c …and the unit is not installed"
fi
chmod 755 "$PROBE_UNREADABLE"

# (c16) the same binary must be judged the same at argv[0] and after `env`: `env <TCC binary> <script>`
# used to be SKIPped (and DISARMED) while the identical argv[0] form installed (review P3, round 5).
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env "$PROBE_HOME/Documents/checkout/.venv/bin/python" "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c env <TCC binary> <script> does not fail the install"
assert_contains "$OUT" "WARN TCC-root launcher" "§7c …because env's program IS the launcher, and it is a binary that holds the grant"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the unit is not skipped (same verdict as argv[0])"

# (c17) a `#!` launcher whose INTERPRETER is a binary inside the tree DOES hold the grant (the
# interpreter is what reads the file), so it installs with a WARN — the mirror of (c10). The message
# must name the ROOT the grant came from, which is what makes "same tree" a comparison and not a
# guess (review P3, rounds 4-5).
PROBE_INTERP="$PROBE_HOME/Documents/checkout/via-python.sh"
printf '#!%s\n' "$PROBE_HOME/Documents/checkout/.venv/bin/python" > "$PROBE_INTERP"
chmod +x "$PROBE_INTERP"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_INTERP" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a shebang launcher whose interpreter is a TCC BINARY does not fail the install"
assert_contains "$OUT" "RUNS a binary from inside $PROBE_HOME/Documents" "§7c …because the grant is the INTERPRETER's, named by root"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so it is not skipped"

# (c18) `env -S '<cmd>'` / `env --split-string=<cmd>`: the value is a COMMAND LINE, so its absolute
# tokens are executed and must be classified. Treating it as an option value installed a unit whose
# script lives in a TCC tree with NO verdict at all (fresh review of #3413, P3).
for _probe_s in -S --split-string; do
    if [ "$_probe_s" = "-S" ]; then
        set +e
        OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
        set -e
    else
        set +e
        OUT="$(probe_install "$PROBE_HOME" /usr/bin/env "--split-string=/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
        set -e
    fi
    assert_line "$OUT" '^    TCC-protected target: ' "§7c env $_probe_s '<cmd with a TCC script>' is classified (the string is a command line, not an option value)"
    # ⛔ AND THE RUN MUST NOT FAIL: the verdict is a SKIP, and a mis-read of the string shows up as a
    # "broken target" FAIL (rc=1) that would take `sync.sh` with it. Without this the "nothing is
    # installed" arm below is satisfied by the BUG (fresh review of #3413, P3).
    assert_eq "$RC" "0" "§7c …and the install does not FAIL (the verdict is a SKIP, not a broken target)"
    assert_not_contains "$OUT" "broken target" "§7c …with no bogus path emitted from the command string"
    if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
        bad "§7c …so nothing is installed for it ($_probe_s)"
    else
        ok "§7c …so nothing is installed for it ($_probe_s)"
    fi
done

# (c19) a DIRECTORY at an executed position: existence alone armed it (`[ -e ]` is satisfied, and the
# interpreter dies 126/127). This is the PR's own premise applied to every path, not only a TCC one.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c a DIRECTORY at an executed position fails the install (not a regular file)"
assert_contains "$OUT" "unreadable or not a regular file" "§7c …and says why"

# (c19b) THE SAME SHAPE ON THE FALLBACK READER. `unknown` used to be excused when it was a directory —
# written when the fallback could not name `--repo`/`--root` and a directory-valued `--repo` aborted the
# install. Once those are `data`, the escape protects nothing and only ARMS a directory at an executed
# position that the python reader refuses: measured on the previous head, py rc=1 / fallback rc=0 with
# `installed + loaded`, then `bash` exits 126 EISDIR every tick. RED if the escape comes back.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROBE_HOME/.pi/agent/scripts</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "1" "§7c the FALLBACK reader also fails the install on a DIRECTORY at an executed position"
assert_contains "$OUT" "unreadable or not a regular file" "§7c …and says why, exactly as the python reader does"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and the unit is not armed"
else
    ok "§7c …and the unit is not armed"
fi

# (c20) a `chmod 000` executed target OUTSIDE any TCC root: readable-only-inside-TCC was the last
# surviving form of "existence is not readability".
PROBE_NOREAD="$PROBE_HOME/.pi/agent/scripts/noread.sh"
printf '#!/bin/bash\nexit 0\n' > "$PROBE_NOREAD"; chmod 000 "$PROBE_NOREAD"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_NOREAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c an unreadable executed target OUTSIDE a TCC root fails the install"
assert_contains "$OUT" "unreadable or not a regular file" "§7c …so 'existence is not readability' holds for every path"
chmod 755 "$PROBE_NOREAD"

# (c21) a symlink that lives under a TCC root but RESOLVES OUTSIDE it is READABLE, so it must install —
# matching the literal spelling as well as the physical one skipped AND DISARMED a unit that starts
# (fresh review of #3413, P2).
mkstub "$PROBE_HOME/.pi/agent/scripts/live-outside.sh"
ln -sfn "$PROBE_HOME/.pi/agent/scripts/live-outside.sh" "$PROBE_HOME/Documents/checkout/alias-out.sh"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/Documents/checkout/alias-out.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a \$HOME/Documents symlink that RESOLVES outside the tree is readable and installs"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …it is NOT skipped (matching the literal spelling disarmed a working unit)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and it really is installed"
else
    bad "§7c …and it really is installed"
fi

# (c22) the PlistBuddy FALLBACK cannot know roles, so it must not claim `exec` for everything: a
# DIRECTORY-valued `--repo` is legitimate, and calling it an unreadable executed target aborted the
# whole install on a host whose python3 cannot parse the plist (fresh review of #3413, P2).
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
        <string>--repo</string>
        <string>$PROBE_HOME/.pi/agent/scripts</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the fallback reader does not FAIL on a DIRECTORY-valued --repo (role is unknown, not exec)"
assert_not_contains "$OUT" "unreadable or not a regular file" "§7c …so no false 'unreadable executed target'"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and the unit installs"
else
    bad "§7c …and the unit installs"
fi

# (c22b) READER AGREEMENT on the OTHER role the fallback can and must derive: the VALUE of a `--repo` /
# `--root` (`DATA_OPTIONS`) sits in the element AFTER the option, so it is a PRECEDING-ELEMENT fact, not
# python knowledge. Emitting `unknown` there made the two readers disagree on the same argv — python
# emitted `data` (a TCC-root value WARNS and the unit installs), the fallback emitted `unknown`
# (`tcc_exec=1` → verdict 2 → `launchctl bootout` + `rm -f` of an ALREADY-INSTALLED unit, exit 0). On the
# documented default box that reached five shipped units, and it is reachable on any Mac whose
# `/usr/bin/python3` shim is executable but exits non-zero (no Command Line Tools). RED if the awk
# fallback loses its DATA_OPTIONS table (the same argv then goes back to SKIP + disarm).
# The PREVIOUS install is left in place ON PURPOSE: the disarm is the failure mode, and only an
# installed unit can show whether this run took it off the box.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR" "$PROBE_HOME/Documents/GitHub/tortoise"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
        <string>--repo</string>
        <string>$PROBE_HOME/Documents/GitHub/tortoise</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
PROBE_TCC_DATA="$PROBE_HOME/Documents/GitHub/tortoise"
printf 'PREVIOUS INSTALL\n' > "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the PlistBuddy fallback reads a TCC-root --repo value as DATA (agrees with the python reader)"
assert_contains "$OUT" "WARN TCC-protected data argument: $PROBE_TCC_DATA" "§7c …so it WARNS like the python reader does"
assert_not_contains "$OUT" "TCC-protected target: $PROBE_TCC_DATA" "§7c …and never as an EXEC refusal"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the unit is not SKIPped"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ] &&
   ! grep -q 'PREVIOUS INSTALL' "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"; then
    ok "§7c …and the unit is REINSTALLED over the previous one, not disarmed and removed"
else
    bad "§7c …and the unit is REINSTALLED over the previous one, not disarmed and removed"
fi

# (c22c) THE LAUNCHER ROLE, which the fallback also derives from POSITION: `Program`, else element 0.
# The two `com.tortoise.*` reapers exec `{{TORTOISE_REPO}}/.venv/bin/python`, a BINARY inside a TCC root,
# and #1311 measured that such a binary DOES hold the grant. Emitting `unknown` for it made the fallback
# SKIP-and-DISARM a working unit while python WARNed and installed — measured on this head (fresh review
# of #3413, P1), same defect class as (c22b). RED if the `idx == 0` launcher rule is dropped.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
PROBE_TCC_BIN="$PROBE_HOME/Documents/checkout/.venv/bin/python"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PROBE_TCC_BIN</string>
        <string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
printf 'PREVIOUS INSTALL\n' > "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the PlistBuddy fallback derives the LAUNCHER role from argv[0] (a TCC-root binary holds a grant)"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …so it WARNS like the python reader instead of refusing"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and the reaper is not SKIPped"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ] &&
   ! grep -q 'PREVIOUS INSTALL' "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"; then
    ok "§7c …and the unit is REINSTALLED over the previously installed one, not disarmed and removed"
else
    bad "§7c …and the unit is REINSTALLED over the previously installed one, not disarmed and removed"
fi

# (c22d) `Program`-ONLY unit: launchd execs the `Program` key and there is no argument array at all.
# The python reader accepts it (`argv = []`, the absolute `Program` is the launcher); the fallback used
# to give up with "cannot read ProgramArguments" — verdict 1, which FAILS the whole install (fresh
# review of #3413, P2). RED if `Print :Program` is dropped or an absent array stops being legal.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>Program</key><string>$PROBE_HOME/.pi/agent/scripts/probe-ok.sh</string>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the fallback reads the Program key, so a Program-only unit installs instead of FAILing"
assert_not_contains "$OUT" "cannot read ProgramArguments" "§7c …and an absent ProgramArguments array is not 'cannot read'"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and the Program-only unit is installed"
else
    bad "§7c …and the Program-only unit is installed"
fi

# (c22e) THE JOINED `--opt=<value>` SPELLING carries its value INSIDE the token, and the fallback used
# to drop it silently — a `--script=<TCC>` then installed armed-and-dead with NO verdict at all, while
# python split it and refused. RED if the `index(line, "=")` split is dropped.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>--script=$PROBE_DEAD</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the fallback splits the JOINED --opt=value spelling (verdict 2 is a skip, not a failed install)"
assert_contains "$OUT" "TCC-protected target: $PROBE_DEAD" "§7c …so a --script=<TCC> gets a verdict at all"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and the unit is SKIPPED loudly"

# (c22f) `Program` WINS, so `ProgramArguments[0]` is ONLY argv[0] and carries no verdict — including a
# `--script=<TCC>` at that position, which python IGNORES (index 0 is in its `skipped` set). The joined
# `--opt=` branch used to run BEFORE that skip, so the fallback emitted `exec` for an element python
# never reads and SKIPped (and disarmed) a unit python installs (fresh review of #3413, round 3 P2).
# A false SKIP rather than a fail-open, but still a reader disagreement in the new code.
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>Program</key><string>/bin/bash</string>
    <key>ProgramArguments</key>
    <array>
        <string>--script=$PROBE_DEAD</string>
    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "0" "§7c the fallback skips element 0 when Program wins (agrees with the python reader)"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so a --script=<TCC> at argv[0] under Program does not skip the unit"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and the unit installs, as it does on the python path"
else
    bad "§7c …and the unit installs, as it does on the python path"
fi

# (c22k) `argv[0]` IS NEVER AN OPTION — in EITHER reader, in BOTH `Program` shapes. With `Program` set,
# `ProgramArguments[0]` is only the argv[0] NAME launchd passes, and `--repo` is a legal name; without
# `Program` it is a relative program name. Neither is an option, so neither may supply the `prev`
# option-context for the element AFTER it. Both readers took `prev = argv[i - 1]` UNCONDITIONALLY, so an
# argv[0] of `--repo` made the REAL argument at index 1 — an EXECUTED TCC-tree script — read as that
# option's VALUE: `data` → WARN → INSTALL, i.e. the armed-and-dead unit this whole change exists to
# remove. MEASURED both directions: `Program=/bin/bash` + `(--repo <TCC script>)` went verdict 2 →
# verdict 0 (python AND awk — they SHARED the rule, so no differential case could see it).
# No shipped template carries a `Program` key, so this is a latent hole a future template can walk into
# (fresh review of #3413, round 10 P2). RED if either reader loses the exemption: the python arm pins
# `i >= 2`, the `Program` arm pins awk `idx == 0 && prog != ""` → `prev = ""`, and the noprogram arm
# pins the fallback's bottom `prev = (idx == 0) ? "" : line` (which is also what keeps the two readers
# in AGREEMENT on the noprogram shape: python's `i >= 2` exempts the same element).
for _reader in python fallback; do
  for _shape in program noprogram; do
    rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
    if [ "$_reader" = python ]; then _interval='<integer>300</integer>'
    else _interval='<integer>not-a-number</integer>'; fi
    if [ "$_shape" = program ]; then _progkey='    <key>Program</key><string>/bin/bash</string>'
    else _progkey=''; fi
    cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
$_progkey
    <key>ProgramArguments</key>
    <array>
        <string>--repo</string>
        <string>$PROBE_DEAD</string>
    </array>
    <key>StartInterval</key>$_interval
</dict>
</plist>
PLIST
    rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
    set +e
    OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
            TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
            INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB" ELDATO_ALLOW_TEST_HOME=1
            unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
            bash "$INSTALLER" 2>&1 ) )"; RC=$?
    set -e
    assert_eq "$RC" "0" "§7c ($_reader/$_shape) a --repo argv[0] does not turn the real argv[1] into DATA"
    assert_contains "$OUT" "TCC-protected target: $PROBE_DEAD" "§7c ($_reader/$_shape) …the EXECUTED argument is verdicted as a TARGET"
    assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c ($_reader/$_shape) …and never as the argv[0] option data value"
    if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
        bad "§7c ($_reader/$_shape) …so the unit is not left armed on the box"
    else
        ok "§7c ($_reader/$_shape) …so the unit is not left armed on the box"
    fi
  done
done

# A helper for the fallback-arm cases below: the same probe plist as `_probe_install`, but with an
# unparseable `StartInterval` (so python3 refuses and the PlistBuddy seam is taken) and with the seam
# pinned. Kept next to its users rather than in the shared helper block, which every OTHER §7c case
# drives through the python reader on purpose.
probe_install_fallback() { # <home> <program-argument>... -> installer stdout+stderr through the seam
    local home="$1" a body=""; shift
    for a in "$@"; do body="$body        <string>$a</string>"$'\n'; done
    rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
    cat > "$PROBE_DIR/com.eldato.tccprobe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- agent-infra-plist-version: 0.0.1 -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.eldato.tccprobe</string>
    <key>ProgramArguments</key>
    <array>
$body    </array>
    <key>StartInterval</key><integer>not-a-number</integer>
</dict>
</plist>
PLIST
    rm -f "$home/Library/LaunchAgents/com.eldato.tccprobe.plist"
    ( export HOME="$home"
      export PATH="$T/bin:$PATH"
      export FAKE_LAUNCHCTL_LOG="$LOG"
      export TEMPLATES_DIR="$PROBE_DIR"
      export AGENTS_DIR="$home/Library/LaunchAgents"
      export INSTALL_LAUNCHD_PLISTBUDDY="$FAKE_PB"
      export ELDATO_ALLOW_TEST_HOME=1
      unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
      bash "$INSTALLER" 2>&1 )
}

# (c22g) THE `env` HOP ON THE FALLBACK READER. `env` execs its first POSITIONAL, and `-S` /
# `--split-string` carries a WHOLE COMMAND LINE inside one element, so neither is a path. Without the
# mirror the fallback had three divergent forms (fresh review of #3413, round 6 P2):
#   `-S "<ok cmd>"`            → the string became ONE path → "broken target" → verdict 1: the WHOLE
#                                install aborted, where python installs;
#   `-S "<cmd with TCC>"`      → same abort, where python SKIPs that one unit;
#   `-S<joined>` / `--split-string=<cmd>` → the element starts with `-S`, is not absolute, and got NO
#                                verdict at all → the unit installed ARMED AND DEAD.
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env -S "/bin/bash $PROBE_HOME/.pi/agent/scripts/probe-ok.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c fallback: env -S with a readable command line INSTALLS (the string is not one path)"
assert_not_contains "$OUT" "broken target" "§7c …so the whole string is not filed as a single target"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env -S "/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_contains "$OUT" "TCC-protected target: $PROBE_DEAD" "§7c fallback: env -S with a TCC-tree script in the string is VERDICTED, not aborted"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and that one unit is SKIPPED, as the python reader does"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env "-S/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c fallback: the JOINED -S<cmd> spelling gets a verdict (it used to get none)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and the unit is not left armed"
else
    ok "§7c …and the unit is not left armed"
fi
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env "--split-string=/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c fallback: --split-string=<cmd> is split, not dropped"

# (c22i) env OPTIONS THAT TAKE A VALUE (`-u NAME`, `-C DIR`, `-P DIR`, `--block-signal SIG`, …) in the
# SPACE form. Skipping only the OPTION left its VALUE as the first positional, so the VALUE was promoted
# to launcher and the real program was classified as a TARGET: `env -u PYTHONPATH <TCC venv python>
# <script>` went from verdict 0 to verdict 2, and `install_job` answers 2 with `launchctl bootout` +
# `rm -f` of an INSTALLED, grant-holding unit (fresh review of #3413, round 8 P2). Both readers carried
# the same defect, so no differential test could see it — hence a case per reader.
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env -u PYTHONPATH "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c fallback: env -u NAME consumes its VALUE, so the real program is still the launcher"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …and the program is a LAUNCHER, not a target"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the reaper is not skipped and disarmed"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -u PYTHONPATH "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: env -u NAME consumes its VALUE too (the two agree)"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …and promotes the program the same way"

# (c22j) THE VALUE OF A REQUIRED-VALUE OPTION MUST ALSO BE **SKIPPED**, not just dropped from the scan:
# the emission loop re-read `/tmp` as a target, so `env -C /tmp /bin/bash <farm>` was verdict 1 — the
# WHOLE install aborted — and a TCC-root value was SKIPped + DISARMED, while the reader that really
# drops it installed. Same for the JOINED spelling, which the `--opt=<value>` arm split into
# `exec /tmp`. And the GNU signal options take an OPTIONAL argument, so listing them consumed the
# PROGRAM instead (fresh review of #3413, round 9 P1/P1/P2 — three shapes, one table).
PROBE_FARM="$PROBE_HOME/.pi/agent/scripts/probe-ok.sh"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -C /tmp /bin/bash "$PROBE_FARM" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: env -C DIR consumes the DIRECTORY, which is not a target"
assert_not_contains "$OUT" "unreadable or not a regular file: /tmp" "§7c …so the option value is not verdict-ed as an executed target"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env --chdir=/tmp /bin/bash "$PROBE_FARM" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: the JOINED --chdir=<dir> spelling is skipped, not split into exec <dir>"
# The signal options take an OPTIONAL argument, so the PROGRAM follows directly. The discriminator is
# WHICH token is promoted to launcher: the binary, or (buggy) the script after it.
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env --ignore-signal "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: --ignore-signal takes an OPTIONAL argument, so the PROGRAM is not swallowed"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …the BINARY is the promoted launcher, not the script after it"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env --ignore-signal "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c fallback: --ignore-signal does not swallow the program either"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …same launcher on both readers"
assert_contains "$OUT" "installed + loaded" "§7c …and the unit installs"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "-u PYTHONPATH $PROBE_TCC_BIN $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: env -S honours a required-value option INSIDE the string"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …so the value is not promoted to launcher inside -S"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env -S "-u PYTHONPATH $PROBE_TCC_BIN $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c fallback: same for the -S form (the two readers agree)"

# (c22h) THE GRANT APPLIES TO THE `unknown` ROLE TOO. `[<TCC-root BINARY>, <script in the SAME TCC
# root>]` is what the two `com.tortoise.*` reapers render whenever the farmed entry resolves into the
# tree: the launcher is a BINARY, which #1311 measured DOES hold the grant for that tree, so the
# python reader WARNs and INSTALLS. The `unknown` arm set `tcc_exec=1` without consulting `$grants` —
# which the fallback now populates, because it derives the launcher role — so the same unit was
# SKIPped AND DISARMED there: a working unit silently removed (fresh review of #3413, round 7 P2).
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c fallback: an executed target in the launcher's OWN TCC tree WARNS (the binary holds the grant)"
assert_contains "$OUT" "WARN TCC-protected target: $PROBE_DEAD" "§7c …and says it is the same tree, as the python reader does"
# ⛔ THE POSITIVE HALF OF THE NEEDLE §7c (c11) RESTS ON. That case asserts the "shared tree" sentence is
# ABSENT for a DIFFERENT tree, and a negative pin only means something while the sentence still exists to
# be printed. Pinned HERE, where the same-tree WARN must emit it: reword the WARN without updating (c11)
# and this row reddens instead of (c11) quietly going vacuous (fresh review of #3413, FINDING 1).
assert_contains "$OUT" "the SAME tree" "§7c …naming the shared tree in the WARN's own sentence"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the reaper is not skipped and disarmed"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and the unit is installed"
else
    bad "§7c …and the unit is installed"
fi

# (c22h2) ⛔ THE GRANT PROVES READABILITY, NOT THAT THE ARGUMENT IS USABLE — the other half of (c22h).
# `$grants` says the launcher can READ the tree; it says NOTHING about whether the value handed on is a
# file. `--script <DIR>` in the launcher's OWN TCC tree is a KNOWN-executed target, and `bash <dir>` is
# 126 EISDIR on every tick whatever tree it lives in — yet it installed as `installed + loaded` with only
# a WARN. That is the armed-and-dead state this change exists to remove, on the one branch that ARMS the
# unit; the remedy (a re-farm, a chmod) IS an install step, so it FAILS, which is verdict 1's own
# definition and the same call the `launcher` arm made for the x bit in round 9. BOTH READERS, because
# python derives `exec` for this value and the fallback derives `unknown`, so a predicate on one arm only
# is a reader divergence (fresh review of #3413, round 10 P2).
PROBE_TCC_DIR="$PROBE_HOME/Documents/checkout/scripts/a-directory"
rm -rf "$PROBE_TCC_DIR"; mkdir -p "$PROBE_TCC_DIR"
PROBE_TCC_EMPTY="$PROBE_HOME/Documents/checkout/scripts/tcc-empty.sh"
: > "$PROBE_TCC_EMPTY"; chmod +x "$PROBE_TCC_EMPTY"
for _probe_shape in "$PROBE_TCC_DIR" "$PROBE_TCC_EMPTY"; do
    _probe_shape_name="$( [ -d "$_probe_shape" ] && echo DIRECTORY || echo 0-byte )"
    set +e
    OUT="$(probe_install "$PROBE_HOME" "$PROBE_TCC_BIN" --script "$_probe_shape" 2>&1)"; RC=$?
    set -e
    assert_eq "$RC" "1" "§7c python reader: a $_probe_shape_name executed target in the launcher's OWN TCC tree FAILS the install"
    assert_contains "$OUT" "unreadable or not a regular file: $_probe_shape" "§7c …and names it, instead of WARNing and arming a dead unit"
    set +e
    OUT="$(probe_install_fallback "$PROBE_HOME" "$PROBE_TCC_BIN" --script "$_probe_shape" 2>&1)"; RC=$?
    set -e
    assert_eq "$RC" "1" "§7c fallback: the same verdict for a $_probe_shape_name target in the granted tree"
    assert_contains "$OUT" "unreadable or not a regular file: $_probe_shape" "§7c …so the two readers still agree"
done
# POSITIVE CONTROL — the arm must not become a blanket refusal of every same-tree target: a REAL script
# there is exactly what (c22h) and the two `com.tortoise.*` reapers are, and it must still install.
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_TCC_BIN" --script "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c control: a REAL script in the launcher's OWN TCC tree still WARNS and installs"
assert_contains "$OUT" "WARN TCC-protected target: $PROBE_DEAD" "§7c …because #1311 measured the launcher's binary holds that grant"
rm -rf "$PROBE_TCC_DIR"

# (c22k) AN EMPTY ELEMENT INSIDE `env`'s ARGUMENT LIST IS STILL A POSITIONAL, SO IT ENDS THE SCAN.
# Python reaches its `if a.startswith("/")` test, finds `""` relative, and `break`s: the next absolute
# element is that program's SCRIPT, not a second program, so it is filed `exec` with no grant → verdict
# 2. The awk's empty-row arm `next`ed BEFORE the env hop, leaving `envmode` set, so the same element was
# promoted to LAUNCHER, `$grants` was populated for its tree, and the unit installed with only a WARN —
# while `env "" <prog>` exits 127 ENOENT on every tick. Python SKIP+disarm (rc 2) vs fallback ARMED
# (rc 0): a role disagreement is a verdict difference, and this one was in the fail-open direction
# (fresh review of #3413, round 11 P2 — the 11th mismatch of a 609-case differential, all one root).
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env "" "$PROBE_TCC_BIN" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c python reader: an EMPTY element ends env's scan, so the next absolute is EXEC"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the unit is skipped and disarmed"
assert_not_contains "$OUT" "installed + loaded" "§7c …and it is NOT armed"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env "" "$PROBE_TCC_BIN" 2>&1)"; RC=$?
set -e
# ⛔ NOT AN `RC` ROW. Verdict 2 (skip) and verdict 0 (install) are BOTH exit 0, so an exit code cannot
# see this defect — measured: with the old awk arm all four `RC=0` rows of this case still passed and
# only the two output rows reddened. The discriminating statement is the SIDE, so it is asserted as one.
assert_eq "$RC" "0" "§7c fallback: the same empty element ends env's scan (no launcher promotion)"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the two readers agree, instead of arming a unit that exits 127"
assert_not_contains "$OUT" "installed + loaded" "§7c …and the fallback does not ARM what python disarms"
# …and the CONTROL: the empty element must NOT swallow a pending option VALUE, or the round-9 fix
# regresses. `env -C "" <TCC python> <script>`: the empty is the -C value, so the binary IS the program
# and the unit WARNs and installs on both readers.
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -C "" "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c control: an empty element after a VALUE option is that option's value, not env's program"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …so the program after it is still promoted"
set +e
OUT="$(probe_install_fallback "$PROBE_HOME" /usr/bin/env -C "" "$PROBE_TCC_BIN" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c control: the fallback consumes the same empty value and keeps scanning"
assert_contains "$OUT" "WARN TCC-root launcher: $PROBE_TCC_BIN" "§7c …so the two readers still agree"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and the unit is ARMED, not skipped (the empty was the option value, not the program)"

# (c23) `env -S` splits with ITS OWN grammar: a BACKSLASH-escaped space (`\_`) keeps the command
# together, and the absolute token after it is still EXECUTED (fresh review of #3413, P3).
mkdir -p "$PROBE_HOME/Documents/checkout/with space"
printf 'exit 0\n' > "$PROBE_HOME/Documents/checkout/with space/tcc-dead.sh"
chmod +x "$PROBE_HOME/Documents/checkout/with space/tcc-dead.sh"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "bash $PROBE_HOME/Documents/checkout/with\\ space/tcc-dead.sh" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c env -S keeps an ESCAPED space inside the path (env's own grammar) and still classifies the script"

# (c24) a 0-BYTE executed target outside any TCC root: existence is not readability, and execve gives
# ENOEXEC (126/127) — the class this change exists for, on the direction that is NOT about TCC.
PROBE_EMPTY="$PROBE_HOME/.pi/agent/scripts/empty-target.sh"
: > "$PROBE_EMPTY"; chmod +x "$PROBE_EMPTY"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_EMPTY" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c a 0-BYTE executed target fails the install (execve gives ENOEXEC)"
assert_contains "$OUT" "unreadable or not a regular file" "§7c …and says why"

# (c25) the LAUNCHER is `execve`d too, so the same file-type guarantee must apply to it — and it must
# additionally be EXECUTABLE, because launchd hands this path to the kernel rather than to an
# interpreter. Without this arm a `Program` that is a DIRECTORY, a 0-byte file, or a readable
# non-executable file installed as `installed + loaded` and died 126/127 on every tick: the same
# category-A false PASS, on the one argument class the TCC model was newly taught to read (review of
# #3413, round 8 — measured on the previous head at rc=0 / `installed + loaded` for all four shapes).
PROBE_LAUNCH_DIR="$PROBE_HOME/.pi/agent/scripts"   # a DIRECTORY: exists, but execve gives EACCES
PROBE_LAUNCH_EMPTY="$PROBE_HOME/.pi/agent/scripts/empty-launcher"
: > "$PROBE_LAUNCH_EMPTY"; chmod +x "$PROBE_LAUNCH_EMPTY"
PROBE_LAUNCH_NOX="$PROBE_HOME/.pi/agent/scripts/noexec-launcher.sh"
mkstub "$PROBE_LAUNCH_NOX"; chmod 644 "$PROBE_LAUNCH_NOX"
for _probe_l in "$PROBE_LAUNCH_DIR" "$PROBE_LAUNCH_EMPTY" "$PROBE_LAUNCH_NOX"; do
    set +e
    OUT="$(probe_install_program "$PROBE_HOME" "$_probe_l" 2>&1)"; RC=$?
    set -e
    assert_eq "$RC" "1" "§7c a non-executable-file launcher FAILS the install ($(basename "$_probe_l"))"
    assert_contains "$OUT" "unreadable or not an executable regular file" "§7c …and names the launcher, not a target (no verdict-2 skip)"
    if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
        bad "§7c …so it is NOT installed ($(basename "$_probe_l"))"
    else
        ok "§7c …so it is NOT installed ($(basename "$_probe_l"))"
    fi
done
chmod 755 "$PROBE_LAUNCH_NOX"
# POSITIVE CONTROL — the arm must not become a blanket refusal of every launcher.
set +e
OUT="$(probe_install_program "$PROBE_HOME" "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c control: an EXECUTABLE regular-file launcher still installs"
assert_not_contains "$OUT" "unreadable or not an executable regular file" "§7c …with no launcher complaint"

# (c26) `env -S '<cmd>'` must classify with the SAME rules as the space form, in BOTH directions.
# A bare `startswith("/")` test made the two disagree: `--script=<TCC>` got no verdict at all (the
# unit installed — fail-open), and a `--repo <TCC>` value was filed as EXEC (the unit was skipped and
# DISARMED, while the space form warns and installs — a false refusal of a runnable unit). Both
# measured on the previous head against the space form (review of #3413, round 8).
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "/bin/bash --script=$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c env -S '--script=<TCC>' does not fail the install"
assert_line "$OUT" '^    TCC-protected target: ' "§7c …env -S '--script=<TCC>' is EXECUTED code, as in the space form (no longer invisible)"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the unit is SKIPPED, not installed with no verdict"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and nothing is installed for it (the fail-open this closes)"
else
    ok "§7c …and nothing is installed for it (the fail-open this closes)"
fi
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "/bin/bash $PROBE_HOME/.pi/agent/scripts/probe-ok.sh --repo $PROBE_HOME/Documents/checkout" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c env -S '--repo <TCC dir>' does not fail the install"
assert_contains "$OUT" "WARN TCC-protected data argument" "§7c …env -S '--repo <TCC>' is DATA, as in the space form (not a false refusal)"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so a runnable unit is NOT skipped and disarmed"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and it really is installed"
else
    bad "§7c …and it really is installed"
fi

# (c27) the executable-file requirement must hold INSIDE a TCC root too. It was enforced only in the
# non-TCC arm, so a readable file with no x bit named by `Program` installed with a WARN whenever its
# path happened to land in the tree — the same category-A false PASS, on the half of the branch the
# round-8 fix did not reach. The x bit is a verdict-1 FAILURE in both arms, because the remedy (a
# chmod, or a re-farm) is an install step (review of #3413, round 9).
PROBE_TCC_NOEXEC="$PROBE_HOME/Documents/checkout/notes.txt"
printf 'not a program\n' > "$PROBE_TCC_NOEXEC"; chmod 644 "$PROBE_TCC_NOEXEC"
set +e
OUT="$(probe_install_program "$PROBE_HOME" "$PROBE_TCC_NOEXEC" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c a non-executable launcher INSIDE a TCC root fails the install (not a WARN+install)"
assert_contains "$OUT" "unreadable or not an executable regular file" "§7c …and names the x bit, not the TCC tree"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …and is not excused as a grant-holding binary"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …so it is NOT installed (arming it is the false PASS)"
else
    ok "§7c …so it is NOT installed (arming it is the false PASS)"
fi
# …and the same rule at the INTERPRETER hop: a `#!` launcher that IS executable still cannot run if
# the interpreter the kernel hands it to is not. `launcher_grant_root` requires the x bit per hop, so
# this resolves to no grant → verdict 2 (skip + disarm), never a WARN+install.
PROBE_TCC_INTERP_NX="$PROBE_HOME/Documents/checkout/.venv/bin/python-noexec"
printf '\177ELF\002\001\001\000' > "$PROBE_TCC_INTERP_NX"; chmod 644 "$PROBE_TCC_INTERP_NX"
PROBE_VIA_NX="$PROBE_HOME/Documents/checkout/via-noexec-interp.sh"
printf '#!%s\n' "$PROBE_TCC_INTERP_NX" > "$PROBE_VIA_NX"; chmod +x "$PROBE_VIA_NX"
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_VIA_NX" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a launcher whose TCC INTERPRETER has no x bit does not fail the install (skip)"
assert_not_contains "$OUT" "WARN TCC-root launcher" "§7c …a non-executable interpreter is NOT treated as a granting binary"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …so the unit is NOT installed (launchd would exit 126)"
else
    ok "§7c …so the unit is NOT installed (launchd would exit 126)"
fi

# (c28) `env -S` must promote env's FIRST POSITIONAL token to LAUNCHER, exactly as the space form
# promotes argv[1]. Without it the two forms disagreed on a TCC binary launcher (SKIP+disarm vs
# WARN+install) and on a non-executable program (installed vs refused) — the third rule the split
# loop was missing (review of #3413, round 9).
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "$PROBE_HOME/Documents/checkout/.venv/bin/python $PROBE_HOME/.pi/agent/scripts/probe-ok.sh" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c env -S '<TCC binary> <script>' does not fail the install"
assert_contains "$OUT" "WARN TCC-root launcher" "§7c …because the split string's program is the LAUNCHER, as in the space form"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so a runnable unit is not skipped and disarmed"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and it really is installed"
else
    bad "§7c …and it really is installed"
fi
PROBE_NOEXEC_PROG="$PROBE_HOME/.pi/agent/scripts/probe-noexec.sh"
mkstub "$PROBE_NOEXEC_PROG"; chmod 644 "$PROBE_NOEXEC_PROG"
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -S "$PROBE_NOEXEC_PROG --loop" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c env -S '<readable non-executable program>' fails the install (as the space form does)"
assert_contains "$OUT" "unreadable or not an executable regular file" "§7c …because the promoted launcher is file-type checked"
chmod 755 "$PROBE_NOEXEC_PROG"

# (c29) getopt's JOINED spelling `-S'<cmd>'` is the same option as `-S '<cmd>'`. Unmatched, the string
# fell into the generic option branch, was dropped, and the unit installed with NO verdict (review of
# #3413, round 9).
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env "-S/bin/bash $PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c env '-S<cmd>' (joined) does not fail the install"
assert_line "$OUT" '^    TCC-protected target: ' "§7c …and its command line IS classified, as in the two-token spelling"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …so the unit is SKIPPED, not installed with no verdict"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and nothing is installed for it (the joined-spelling fail-open)"
else
    ok "§7c …and nothing is installed for it (the joined-spelling fail-open)"
fi

# (c4) `env -i bash <script>`: an option AND env's program hop both sit before the script.
set +e
OUT="$(probe_install "$PROBE_HOME" /usr/bin/env -i bash "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_line "$OUT" '^    TCC-protected target: ' "§7c env -i bash <TCC script> is an EXEC target (the env program hop is skipped)"
assert_not_contains "$OUT" "WARN TCC-protected data argument" "§7c …and is not misfiled as data"

# (c5) a POSITIONAL TCC value that no long option introduced: the conservative direction is to treat
# it as executed, so the unit is SKIPPED rather than armed. This is a deliberate cost, stated: the
# guard cannot tell a positional value from an inline program's script, and arming a unit launchd
# cannot start is the defect this exists for, so the doubt resolves to "do not install".
printf 'data\n' > "$PROBE_HOME/Documents/checkout/positional-data.txt"
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash -c 'echo hi' "$PROBE_HOME/Documents/checkout/positional-data.txt" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a positional TCC value does not fail the install"
assert_line "$OUT" '^    TCC-protected target: ' "§7c …and resolves to a SKIP, not an armed unit (doubt goes to do-not-install)"

# (c3) the shipped reaper shape: the checkout's own interpreter at argv[0] (`{{TORTOISE_REPO}}` is
# inside `~/Documents` on the documented box). #1311 MEASURED that interpreter runs from there
# (WORKTREES=454 / GH=ok) and #427 measured that a launchd `bash` cannot READ such a path — TCC is
# PER-BINARY. So the LAUNCHER is the discriminator: this unit INSTALLS with a loud WARN. It must not
# be skipped, and it must not be disarmed: taking a working daily reaper off the box every sync would
# be a worse defect than the one this guard fixes (review P2, cycle 3).
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_HOME/Documents/checkout/.venv/bin/python" "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" --repo "$PROBE_HOME/Documents/checkout" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a reaper-shaped unit (TCC launcher) does not fail the install"
assert_contains "$OUT" "WARN TCC-root launcher" "§7c …and the TCC-root LAUNCHER is named (#1311 measured it holds the access)"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and the unit is NOT skipped (that would delete a working reaper)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and it really is installed"
else
    bad "§7c …and it really is installed"
fi
# (c3b) the LAUNCHER inside the tree AND the script inside it: the launcher reads the script itself
# (pi-reap-worktrees-launchd.py pipes it to `bash -s` for exactly this reason), so it installs too.
set +e
OUT="$(probe_install "$PROBE_HOME" "$PROBE_HOME/Documents/checkout/.venv/bin/python" "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a TCC script under a TCC LAUNCHER installs (the launcher holds the read)"
assert_contains "$OUT" "WARN TCC-protected target" "§7c …naming the target, as a WARN not a SKIP"
assert_not_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c …and it is not skipped"

# (a2) a SKIP must DISARM what an earlier run ARMED (review P2, cycle 2). REACHABLE BY CONSTRUCTION:
# the box this PR measured was running the PREVIOUS installer, which armed worker-supply /
# objective-reminder / controller-watchdog from `{{AGENT_INFRA_PATH}}` (inside ~/Documents) — they
# stayed loaded and exited 126 for 7 hours. Any template edit that points a bash-launched script back
# into the tree lands in that state, and returning before the install/remove path left it loaded while
# the run said "nothing is installed for it". (The two `com.tortoise.*` reapers are NOT this case —
# their launcher is a BINARY in the tree, which §7c (c3) pins as installed.)
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" 2>&1)"; RC=$?
set -e
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c (a2) precondition: the unit is ARMED by a clean run"
else
    bad "§7c (a2) precondition: the unit is ARMED by a clean run"
fi
BOOTOUT_BEFORE="$(grep -c 'bootout.*com\.eldato\.tccprobe' "$LOG" || true)"
set +e
OUT="$(probe_install_keep_installed "$PROBE_HOME" /bin/bash "$PROBE_DEAD" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c (a2) the TCC verdict still exits 0"
assert_contains "$OUT" "SKIP com.eldato.tccprobe" "§7c (a2) …and skips the unit"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c (a2) …and DISARMS the plist the previous run installed (it was left armed)"
else
    ok "§7c (a2) …and DISARMS the plist the previous run installed"
fi
assert_eq "$(grep -c 'bootout.*com\.eldato\.tccprobe' "$LOG" || true)" "$((BOOTOUT_BEFORE + 1))" "§7c (a2) …with a real launchctl bootout for that label (not just rm)"

# (d) a DATA argument under a TCC root WARNS and the unit still installs — the #3413 regression.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_HOME/.pi/agent/scripts/probe-ok.sh" --repo "$PROBE_HOME/Documents/checkout" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "0" "§7c a TCC-protected DATA argument does not refuse the install (--repo under ~/Documents is the documented default)"
assert_contains "$OUT" "WARN TCC-protected data argument" "§7c the dead-work data argument is named loudly"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    ok "§7c …and the unit really was installed (the WARN was not folded into the refusal)"
else
    bad "§7c …and the unit really was installed (the WARN was not folded into the refusal)"
fi

# (g) VERDICT 1 WINS OVER VERDICT 2 (review P3, cycle 2): a MISSING target is fixable by re-running
# setup.sh, so it must FAIL the install — never be absorbed into the permanent SKIP that a TCC
# TARGET produces. Without this case, swapping the two returns leaves the whole suite green.
set +e
OUT="$(probe_install "$PROBE_HOME" /bin/bash "$PROBE_DEAD" --repo "$PROBE_HOME/does-not-exist" 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c (g) a MISSING target FAILS the install even beside a TCC-protected target (verdict 1 wins)"
assert_contains "$OUT" "FAIL com.eldato.tccprobe" "§7c (g) …reported as FAIL, not absorbed into a SKIP"

# (e) a plist that cannot be READ is a refusal, not an empty target list (#1743 / review P2-E).
# Both readers are defeated: this host may have python3 AND PlistBuddy, so the file is made
# unparseable for BOTH by being plain text rather than by removing a reader.
printf 'this is not a plist\n' > "$PROBE_DIR/com.eldato.tccprobe.plist"
rm -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist"
set +e
OUT="$( ( export HOME="$PROBE_HOME" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" \
        TEMPLATES_DIR="$PROBE_DIR" AGENTS_DIR="$PROBE_HOME/Library/LaunchAgents" \
        ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO SWARM_ROOT PYTHON_BIN
        bash "$INSTALLER" 2>&1 ) )"; RC=$?
set -e
assert_eq "$RC" "1" "§7c an UNPARSEABLE plist refuses the install instead of verifying nothing (#1743)"
assert_contains "$OUT" "cannot read ProgramArguments" "§7c the unreadable plist is named (not an empty pass)"
if [ -f "$PROBE_HOME/Library/LaunchAgents/com.eldato.tccprobe.plist" ]; then
    bad "§7c …and no unit was installed from it"
else
    ok "§7c …and no unit was installed from it"
fi

# (f) a ProgramArguments array with no ABSOLUTE entry verifies nothing → refusal, same rule.
# This is the ITERATION-COUNT half: the feeder returns 0 on a readable plist that names no absolute
# entry, so deleting the count gate is what this case catches (the unreadable case above is the
# feeder's own return code).
set +e
OUT="$(probe_install "$PROBE_HOME" bash self-relative.sh 2>&1)"; RC=$?
set -e
assert_eq "$RC" "1" "§7c ProgramArguments with no absolute target refuses (nothing was verified)"
assert_contains "$OUT" "no absolute ProgramArguments entry was verified" "§7c …and says so, rather than passing on an empty loop"

# Restore the shared fixture: §8+ install through $TEMPLATES, not the probe dir, and $LOG keeps
# growing for the bootstrap-count assertions.
rm -rf "$PROBE_DIR"

# Restore the farmed script so later tests install cleanly
mkfakehome "$HOME1"

echo "── 8. Placeholder skip (no swarm root) ───────────────────────────"
# HOME2 without a swarm root: canary must be SKIPPED (loud, exit 0), tripwire
# still installed. SWARM_ROOT is env-only in the installer — no auto-detect.
rm -rf "$HOME2/swarm"
set +e
# TORTOISE_REPO="" discards whatever the CALLER exported: an ambient value pointing at a broken
# checkout made this run exit 1 and reddened "placeholder skip exits 0" on a dev box while CI stayed
# green — the same host-dependence §1 was fixed for. (Empty, not unset: the installer then falls back
# to its disk candidates, which are valid-or-absent and never this section's subject.)
OUT="$(HOME="$HOME2" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG" TEMPLATES_DIR="$TEMPLATES" \
    AGENTS_DIR="$HOME2/Library/LaunchAgents" SWARM_ROOT="" ELDATO_ALLOW_TEST_HOME=1 \
    PYTHON_BIN="$HOME2/swarm/.venv/bin/python" TORTOISE_REPO="" \
    bash "$INSTALLER" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "0" "placeholder skip exits 0 (non-swarm machine ok)"
assert_contains "$OUT" "SKIP com.eldato.corruption-canary" "canary skipped without swarm root"
assert_contains "$OUT" "provider-latency-tripwire: installed + loaded" "tripwire still installed without swarm"

echo "── 9. --status ───────────────────────────────────────────────────"
# Template is at 3601; HOME1 tripwire is not installed (test 6 rollback + test
# 7 refusal) → install it, then bump the template to show DRIFT in --status.
set +e
OUT="$(run_installer "$HOME1" 2>&1)"
set -e
sed -i.bak 's/<integer>3601<\/integer>/<integer>3603<\/integer>/' "$TEMPLATES/com.eldato.provider-latency-tripwire.plist" && rm -f "$TEMPLATES/com.eldato.provider-latency-tripwire.plist".bak || true
set +e
OUT="$(run_installer "$HOME1" --status)"
RC=$?
set -e
assert_eq "$RC" "0" "--status exits 0"
assert_contains "$OUT" "provider-latency-tripwire: installed=loaded version=v0.1.0 (DRIFTED" "status flags drifted tripwire"
assert_contains "$OUT" "corruption-canary: installed=loaded version=v0.1.0 (in sync)" "status reports canary in sync"
assert_contains "$OUT" "Retired (moved to session-checks, #432)" "status lists retired jobs"

echo "── 10. --uninstall ───────────────────────────────────────────────"
set +e
OUT="$(run_installer "$HOME1" --uninstall)"
RC=$?
set -e
assert_eq "$RC" "0" "--uninstall exits 0"
assert_contains "$OUT" "provider-latency-tripwire: unloaded + removed" "tripwire removed"
assert_contains "$OUT" "corruption-canary: unloaded + removed" "canary removed"
[ ! -f "$TRIPWIRE_INSTALLED" ] && ok "tripwire file gone" || bad "tripwire file gone"
[ ! -f "$CANARY_INSTALLED" ] && ok "canary file gone" || bad "canary file gone"
set +e
OUT="$(run_installer "$HOME1" --status)"
set -e
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
    SWARM_ROOT="$HOME3/swarm" PYTHON_BIN="$HOME3/swarm/.venv/bin/python" TORTOISE_REPO="" \
    bash "$INSTALLER" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "temp-HOME install (no override) → exit 1"
assert_contains "$OUT" "refusing to manage launchd jobs" "refusal names the guard"
assert_contains "$OUT" "not the real home" "refusal explains the HOME mismatch"
[ ! -s "$LOG3" ] && ok "zero launchctl calls on refusal (nothing touched any domain)" || bad "zero launchctl calls on refusal (got: $(cat "$LOG3"))"
set +e
OUT="$(HOME="$HOME3" PATH="$T/bin:$PATH" FAKE_LAUNCHCTL_LOG="$LOG3" TORTOISE_REPO="" \
    bash "$INSTALLER" --uninstall 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "temp-HOME --uninstall (no override) → exit 1"
[ ! -s "$LOG3" ] && ok "zero launchctl calls on --uninstall refusal" || bad "zero launchctl calls on --uninstall refusal"
# With the override the SAME home installs cleanly through the shim (the
# override is the test's explicit isolation proof, #446).
set +e
OUT="$(LOG="$LOG" run_installer "$HOME3" 2>&1)"
RC=$?
set -e
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
mkstub "$HOME3/tortoise/.venv/bin/python"
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
    set +e
    bash "$INSTALLER" >/dev/null 2>&1
    set -e
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
    set +e
    OUT="$(python3 "$SCRIPT_DIR/../scripts/pi-reap-worktrees-launchd.py" \
        --script "$FAKE_REAPER" --repo /tmp/some-repo --dry-run 2>&1)"
    set -e
    assert_eq "$OUT" "ARGS: --repo /tmp/some-repo --dry-run" \
        "launcher forwards the repo and mode args to the reaper (no separator needed)"
    set +e
    OUT="$(python3 "$SCRIPT_DIR/../scripts/pi-reap-worktrees-launchd.py" \
        --script /tmp/does-not-exist-launcher-probe.sh --repo /tmp/x 2>&1; echo "rc=$?")"
    set -e
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
echo "── 15. The orphan reaper WRITES FRESH OUTPUT on a pass (#1862 acceptance) ──"
# The acceptance is explicit: a test that only asserts the FILE exists proves
# nothing (pre-change the script existed only under state/recovered-1161/).
# Section 1 proves the job is SCHEDULED; this section proves a pass produces a
# FRESH log, so "a plist that loads and never runs" — the defect #1862 exists to
# fix — cannot pass this suite.
ORPHAN_REAPER="$SCRIPT_DIR/pi-reap-orphans.sh"
if [ -f "$ORPHAN_REAPER" ]; then
    ok "the reaper is versioned in scripts/ (not only under a machine-local recovery dir)"
    # Run the REAL script in the DEPLOYED shape: the plist sets only
    # REAP_ORPHAN_DRY_RUN=1, so the state dir and log default to
    # $HOME/.pi/agent/state/pi-reap-orphans.log. Assert on THAT path, not a
    # test-only override — otherwise the test would prove a log the deployed
    # job never writes.
    ORPHAN_STATE="$HOME1/.pi/agent/state"; mkdir -p "$ORPHAN_STATE"
    ORPHAN_LOG="$ORPHAN_STATE/pi-reap-orphans.log"; rm -f "$ORPHAN_LOG"
    ORPHAN_START="$(date +%s)"
    set +e
    HOME="$HOME1" REAP_ORPHAN_DRY_RUN=1 REAP_ORPHAN_SAMPLE_SECONDS=0 \
        REAP_ORPHAN_PS_TIMEOUT=10 REAP_ORPHAN_LSOF_TIMEOUT=10 \
        REAP_ORPHAN_BUDGET_SECONDS=20 \
        bash "$ORPHAN_REAPER" --dry-run --sample-seconds 0 >/dev/null 2>&1
    ORPHAN_RC=$?
    set -e
    # 0 = full pass, 3 = fail-closed probe abort (e.g. no lsof on the runner).
    # BOTH write the log; what must NEVER happen is a silent no-op.
    case "$ORPHAN_RC" in
        0|3) ok "a reaper pass exits cleanly (full dry-run pass, or a fail-closed probe abort)" ;;
        *) bad "a reaper pass exits 0 or 3 (got $ORPHAN_RC)" ;;
    esac
    [ -s "$ORPHAN_LOG" ] && ok "the pass WROTE a fresh log (installed-but-inert cannot pass this)" \
        || bad "the pass wrote no log at $ORPHAN_LOG"
    # BSD `stat -f %m` and GNU `stat -c %Y`; on GNU `-f %m` means FILESYSTEM
    # stats and prints a block report, so the flavour must be detected, never
    # tried-then-fallback (the block report is non-numeric and blows up `[ -ge ]`).
    case "$(uname -s 2>/dev/null)" in
        Linux) LOG_MTIME="$(stat -c %Y "$ORPHAN_LOG" 2>/dev/null || echo 0)" ;;
        *)     LOG_MTIME="$(stat -f %m "$ORPHAN_LOG" 2>/dev/null || echo 0)" ;;
    esac
    [ "$LOG_MTIME" -ge "$ORPHAN_START" ] && ok "the log is FRESH (mtime within this pass, not a stale artifact)" \
        || bad "the log is stale (mtime $LOG_MTIME < start $ORPHAN_START)"
    grep -qE 'MODE=dry-run|FAIL-CLOSED' "$ORPHAN_LOG" \
        && ok "the log records the mode (MODE=dry-run) or names the fail-closed abort" \
        || bad "the log does not name the pass (no MODE= / FAIL-CLOSED line)"
    # The paired property #1862 requires: a dry pass signals NOTHING. Only
    # assertable on a completed pass; a fail-closed abort has no footer and is
    # itself a no-signal outcome (it exits before the classification loop).
    if [ "$ORPHAN_RC" = 0 ]; then
        assert_contains "$(cat "$ORPHAN_LOG")" "MODE=dry-run" \
            "the deployed dry-run mode is recorded in the log (#1142 acceptance)"
        assert_not_contains "$(cat "$ORPHAN_LOG")" "REAPED pid=" \
            "the dry-run pass reaped NOTHING (the deployed default signals no one)"
    else
        ok "fail-closed probe abort: the pass exited before any signal could be sent"
    fi
else
    bad "scripts/pi-reap-orphans.sh is MISSING — the reaper is not versioned (#1862)"
fi

echo ""
echo "── 16. Orphan-reaper arming: shipped DISARMED, armable only from a dated record ──"
# #1863 review, ISSUE 2 (P2). Before this section the template carried a LITERAL
# `<string>1</string>`, so the arming step every artifact documents had no reachable
# execution path: `install_job()` re-renders and `mv`s over the installed plist, so a
# hand-edit was silently reverted, and no verb existed to write the armed value.
# The assertions below are what make the fix falsifiable — they read the RENDERED
# unit (what launchd would exec), not the template text:
#   * the default is DISARMED even with no arming record (§1 also pins this);
#   * `--arm-orphan-reaper` REFUSES a box that never farmed the script, writing no
#     record (an armed unit launchd cannot start is the inert shape arming is for);
#   * `--arm-orphan-reaper` REFUSES a farmed script that does not parse (round-2
#     review ISSUE 3: this arm existed and was driven by nothing);
#   * `--arm-orphan-reaper` writes a DATED record and the re-rendered unit carries 0;
#   * a HALF-WRITTEN record (no armed-date) still renders 1 — a truncated file must
#     never count as an arming;
#   * an ambient REAP_ORPHAN_MODE export cannot arm it (the mode is a record);
#   * `--disarm-orphan-reaper` removes the record and the unit goes back to 1;
#   * the template keeps the placeholder (not a literal), so arming stays reachable.
ARM_HOME="$T/home-arm"; mkfakehome "$ARM_HOME"
ARM_FILE="$ARM_HOME/.pi/agent/state/pi-reap-orphans.armed"
ARM_PLIST="$ARM_HOME/Library/LaunchAgents/com.eldato.pi-reap-orphans.plist"
run_arm() { # [installer args...]
    (
        export HOME="$ARM_HOME"
        export PATH="$T/bin:$PATH"
        export FAKE_LAUNCHCTL_LOG="$LOG"
        export TEMPLATES_DIR="$TEMPLATES"
        export AGENTS_DIR="$ARM_HOME/Library/LaunchAgents"
        export SWARM_ROOT="$ARM_HOME/swarm"
        export PYTHON_BIN="$ARM_HOME/swarm/.venv/bin/python"
        export REAP_ORPHAN_ARM_FILE="$ARM_FILE"
        export ELDATO_ALLOW_TEST_HOME=1
        unset TORTOISE_REPO
        bash "$INSTALLER" "$@"
    )
}
arm_value() { grep -A1 'REAP_ORPHAN_DRY_RUN' "$ARM_PLIST" | tail -1 | sed -e 's/.*<string>//' -e 's|</string>.*||'; }
set +e
ARM_OUT="$(run_arm 2>&1)"; ARM_RC=$?
set -e
assert_eq "$ARM_RC" "0" "§16 a fresh install on an unarmed box exits 0"
assert_eq "$(arm_value)" "1" "§16 ... and renders DISARMED (REAP_ORPHAN_DRY_RUN=1) with no arming record"
# ⛔ The refusal arm: arming a box whose FARMED script is absent produces a unit launchd cannot
# start, which is the silent-inert shape arming exists to avoid. This fixture HOME is a bare
# directory (mkfakehome is NOT used), so nothing is farmed into it.
NOFARM_HOME="$T/home-nofarm"; mkdir -p "$NOFARM_HOME/Library/LaunchAgents" "$NOFARM_HOME/.pi/agent/state"
set +e
REFUSE_OUT="$(
    export HOME="$NOFARM_HOME"
    export PATH="$T/bin:$PATH"
    export FAKE_LAUNCHCTL_LOG="$LOG"
    export TEMPLATES_DIR="$TEMPLATES"
    export AGENTS_DIR="$NOFARM_HOME/Library/LaunchAgents"
    export REAP_ORPHAN_ARM_FILE="$NOFARM_HOME/.pi/agent/state/pi-reap-orphans.armed"
    export ELDATO_ALLOW_TEST_HOME=1
    unset TORTOISE_REPO SWARM_ROOT
    bash "$INSTALLER" --arm-orphan-reaper 2>&1
)"
REFUSE_RC=$?
set -e
assert_eq "$REFUSE_RC" "1" "§16 --arm-orphan-reaper REFUSES (exit 1) on a box that never farmed the script"
assert_contains "$REFUSE_OUT" "refusing to arm the orphan reaper" "§16 ... and says so by name"
[ -f "$NOFARM_HOME/.pi/agent/state/pi-reap-orphans.armed" ] \
    && bad "§16 ... and wrote NO arming record on the refusal" \
    || ok "§16 ... and wrote NO arming record on the refusal"
# ⛔ The UNPARSEABLE-farm refusal (#1863 round-2 review, ISSUE 3). This arm existed in the
# installer and was driven by NOTHING: `mkfakehome` `touch`es the farmed scripts, and an
# EMPTY file parses, so `bash -n` always succeeded in §16 and in §1. An armed unit whose
# script cannot parse fails hourly and kills nothing — the exact silent-inert shape — so
# the refusal is pinned here rather than left as prose in the installer.
BADPARSE_HOME="$T/home-badparse"; mkfakehome "$BADPARSE_HOME"
BADPARSE_FILE="$BADPARSE_HOME/.pi/agent/state/pi-reap-orphans.armed"
printf 'if then fi (((\n' > "$BADPARSE_HOME/.pi/agent/scripts/pi-reap-orphans.sh"
set +e
BADPARSE_OUT="$(
    export HOME="$BADPARSE_HOME"
    export PATH="$T/bin:$PATH"
    export FAKE_LAUNCHCTL_LOG="$LOG"
    export TEMPLATES_DIR="$TEMPLATES"
    export AGENTS_DIR="$BADPARSE_HOME/Library/LaunchAgents"
    export SWARM_ROOT="$BADPARSE_HOME/swarm"
    export PYTHON_BIN="$BADPARSE_HOME/swarm/.venv/bin/python"
    export REAP_ORPHAN_ARM_FILE="$BADPARSE_FILE"
    export ELDATO_ALLOW_TEST_HOME=1
    unset TORTOISE_REPO
    bash "$INSTALLER" --arm-orphan-reaper 2>&1
)"
BADPARSE_RC=$?
set -e
assert_eq "$BADPARSE_RC" "1" "§16 --arm-orphan-reaper REFUSES (exit 1) when the farmed script does not parse"
assert_contains "$BADPARSE_OUT" "does not parse" "§16 ... and names the parse failure, not a generic error"
[ -f "$BADPARSE_FILE" ] && bad "§16 ... and wrote NO arming record for an unparseable farm" \
    || ok "§16 ... and wrote NO arming record for an unparseable farm"
set +e
ARM_OUT="$(run_arm --arm-orphan-reaper --reason '§16 arming round trip' 2>&1)"; ARM_RC=$?
set -e
assert_eq "$ARM_RC" "0" "§16 --arm-orphan-reaper exits 0 on a box that farms the script"
assert_contains "$ARM_OUT" "orphan-reaper: ARMED" "§16 ... and says it armed"
assert_contains "$(cat "$ARM_FILE" 2>/dev/null || echo MISSING)" "armed-date=" "§16 ... and the record is DATED (the audit datum)"
assert_contains "$(cat "$ARM_FILE" 2>/dev/null || echo MISSING)" "§16 arming round trip" "§16 ... and records the reason it was armed for"
assert_eq "$(arm_value)" "0" "§16 ... and the INSTALLED unit now renders ARMED (REAP_ORPHAN_DRY_RUN=0)"
# A truncated record (no armed-date) must fail CLOSED, not read as an arming.
printf 'armed-by=someone\n' > "$ARM_FILE"
set +e
run_arm >/dev/null 2>&1; ARM_RC=$?
set -e
assert_eq "$ARM_RC" "0" "§16 a half-written arming record still installs (exit 0)"
assert_eq "$(arm_value)" "1" "§16 ... but renders DISARMED — a truncated record never counts as an arming"
set +e
DISARM_OUT="$(run_arm --disarm-orphan-reaper 2>&1)"; ARM_RC=$?
set -e
assert_eq "$ARM_RC" "0" "§16 --disarm-orphan-reaper exits 0"
assert_contains "$DISARM_OUT" "orphan-reaper: DISARMED" "§16 ... and says it disarmed"
[ -f "$ARM_FILE" ] && bad "§16 ... and the record is gone" || ok "§16 ... and the record is gone"
assert_eq "$(arm_value)" "1" "§16 ... and the installed unit is back to REAP_ORPHAN_DRY_RUN=1"
# An AMBIENT export must not be able to arm the box: the arming state is a RECORD on disk,
# never an environment default (same property the worktree-hygiene suite pins at :392).
AMBIENT_OUT="$(REAP_ORPHAN_MODE=0 run_arm 2>&1)"
[ -n "$AMBIENT_OUT" ] || bad "§16 the ambient-env probe ran the installer"
assert_eq "$(arm_value)" "1" "§16 an ambient REAP_ORPHAN_MODE=0 CANNOT arm the job (the mode is a record, not an env default)"
assert_contains "$(run_arm --status 2>&1)" "orphan-reaper: DISARMED" "§16 --status states the box's arming state (no code reading required)"

# A template that flipped the literal back to an armed value would pass every other
# plist assertion in this file; this one fails it. Deriving it from the TEMPLATE (not a
# rendered copy) keeps it true on any box, armed or not.
assert_contains "$(cat "$TEMPLATES/com.eldato.pi-reap-orphans.plist")" "{{REAP_ORPHAN_MODE}}" \
    "§16 the template carries the {{REAP_ORPHAN_MODE}} placeholder, not a literal — arming stays reachable"


echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
