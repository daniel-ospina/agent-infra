#!/usr/bin/env bash
# worktree-hygiene-sweep.test.sh — self-check for scripts/worktree-hygiene-sweep.sh
# and for the ARMING contract of templates/launchd/com.tortoise.worktree-hygiene.plist
# (PR #2053 review finding 1, and the #10 prerequisite it depends on).
#
# Run: bash scripts/worktree-hygiene-sweep.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHY THIS SUITE EXISTS, and why its shape is what it is. The sweep is 300 lines
# of NEW code whose job is to DELETE — worktree checkouts, then local branch refs,
# on a 6-hourly timer — and it shipped with ZERO assertions. Everything dangerous
# about it was therefore unchecked, and one behavioural claim was actually wrong:
# it counted its removals with `grep -c '^remove '` while the engine prints
# TAB-separated rows, so a pass that removed twenty worktrees logged
# `remove-rows=0`. A test is the only thing that reads that line back.
#
# THE FOUR THINGS PINNED HERE, in the order the review named them:
#   1. THE rc MAPPING (T2). 0 / 2 INCOMPLETE / 3 usage / 4 PARTIAL / 6 PREREQUISITE.
#      A degraded pass must never read as clean, and a pass that cannot run at all
#      must not hide behind the generic 2 (that is the #10 land-order failure).
#   2. THE REMOVE-ROW COUNT, on a CONSTRUCTED fixture engine (T3): tab-separated
#      `remove` rows are counted, `preserve` rows are not, and a row that merely
#      CONTAINS the word does not inflate it.
#   3. A DRY RUN WRITES AND REMOVES NOTHING (T4) — asserted on the repository's
#      own state (worktree list, branch refs, working tree, the dispatch-scout
#      path), not on "the script exited 0". The scout carve-out used to run
#      OUTSIDE the mode guard, so a dry run could create a worktree.
#   4. THE ARMING CONTRACT (T6-T8): the template ships `--dry-run`; the routine
#      no-argument install that pi-bootstrap/setup.sh runs CANNOT arm it; arming
#      is a dated record written by an explicit verb, and that verb REFUSES a box
#      whose sweep prerequisites do not resolve (the #10 hazard: an armed job that
#      exits 3 every pass and deletes nothing, looking installed and healthy).
#
# NON-VACUITY. `SWEEP=` may point at another copy of the script, which is how this
# suite was run against the PRE-FIX blob (the PR head 985dbd2a) to prove the
# assertions falsify: on that tree T3 reports `remove-rows=0` where the fixture
# prints two remove rows, and T4 fails because the dry run creates the scout
# checkout. See the PR body for the measured output.
#
# Hermetic: every fixture is under $T; HOME, the state dir, the backup dir, the
# launchd Agents dir and the arming record are all redirected; `launchctl` is a
# shim. Nothing outside $T is read or written, and no real worktree is reaped.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="${SWEEP:-$HERE/worktree-hygiene-sweep.sh}"
INSTALLER="${INSTALLER:-$HERE/install-launchd.sh}"
TEMPLATE="$HERE/../templates/launchd/com.tortoise.worktree-hygiene.plist"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nofile()   { if [ -f "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }

[ -f "$SWEEP" ] || { echo "FATAL: $SWEEP missing — this suite tests the sweep, and there is none"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/worktree-hygiene-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_GIT="$(command -v git)"

# ── fixtures ──────────────────────────────────────────────────────────────────
# The fixture repo carries the branch reaper as a COMMITTED stub: the sweep runs
# the reaper from a throwaway worktree of `origin/main`, so a stub that exists
# only as an untracked file would be invisible from inside that worktree.
STUB_ENGINE="$T/bin/stub-engine.sh"
mkdir -p "$T/bin"
cat > "$STUB_ENGINE" <<'SH'
#!/usr/bin/env bash
# Fixture worktree engine: records its argv, replays a row file, exits a set rc.
printf '%s\n' "$*" >> "${STUB_ENGINE_ARGV:-/dev/null}"
[ -n "${STUB_ENGINE_ROWS_FILE:-}" ] && cat "$STUB_ENGINE_ROWS_FILE"
exit "${STUB_ENGINE_RC:-0}"
SH
chmod +x "$STUB_ENGINE"

# Two remove rows in the engine's REAL wire format (tab-separated), one preserve
# row, and — the trap — a SPACE-separated `remove ` line that is NOT a row of this
# protocol. A counter that greps a prefix gets 3 here; the fixture's answer is 2.
ROWS_TWO_REMOVE="$T/rows-two-remove.txt"
printf 'remove\treclaimable\t120K\trefs=merged age=9d clean=disposable-only unref=no-proc,no-pr\n' >  "$ROWS_TWO_REMOVE"
printf 'remove\tprunable\t\tcheckout already absent; commits survive via merged\n'               >> "$ROWS_TWO_REMOVE"
printf 'preserve\tdirty\t\t1 modified file\n'                                                    >> "$ROWS_TWO_REMOVE"
printf 'remove this line is not a row of the protocol\n'                                         >> "$ROWS_TWO_REMOVE"
ROWS_NONE="$T/rows-none.txt"
printf 'preserve\tlive-process\t\tpid 42 holds the path\n' > "$ROWS_NONE"

mk_repo() { # mk_repo <name> -> path; one commit, an origin/main ref, a scout branch
    local r="$T/$1"
    mkdir -p "$r/tools"
    "$REAL_GIT" -C "$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$r" init -q
    cat > "$r/tools/branch_reaper.py" <<'PY'
import os, sys
with open(os.environ.get("STUB_REAPER_ARGV", os.devnull), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
print('{"fixture": true}')
sys.exit(int(os.environ.get("STUB_REAPER_RC", "0")))
PY
    printf 'base\n' > "$r/f.txt"
    "$REAL_GIT" -C "$r" add -A
    "$REAL_GIT" -C "$r" commit -qm init
    "$REAL_GIT" -C "$r" update-ref refs/remotes/origin/main HEAD
    "$REAL_GIT" -C "$r" branch chore/dispatch-scout HEAD
    printf '%s\n' "$r"
}

REPO="$(mk_repo repo)"
HOME_T="$T/home"
mkdir -p "$HOME_T"

# Env every sweep invocation shares. HYGIENE_* keep the pass out of the real state
# and backup dirs; STUB_* drive the two fixture engines.
sweep_env() {
    export HOME="$HOME_T"
    export HYGIENE_STATE_DIR="$T/state"
    export HYGIENE_BACKUP_DIR="$T/backup"
    export STUB_ENGINE_ARGV="$T/engine-argv.txt"
    export STUB_REAPER_ARGV="$T/reaper-argv.txt"
}
STATE="$T/state"
MARKER="$STATE/worktree-hygiene-blocked"
LOG="$STATE/worktree-hygiene.log"

run_sweep() { # run_sweep <args...> -> stdout+stderr in $OUT, rc in $RC
    local out
    out="$(sweep_env; bash "$SWEEP" "$@" 2>&1)"
    RC=$?
    OUT="$out"
}

reset_state() {
    rm -rf "$STATE" "$T/backup" "$T/engine-argv.txt" "$T/reaper-argv.txt"
    mkdir -p "$STATE"
}

echo "══ worktree-hygiene-sweep.test.sh ══"
echo "sweep: $SWEEP"

# ── T1: usage, and the static pins on the shipped template ───────────────────
echo ""
echo "── T1. usage + the shipped template may not arm itself ──"
run_sweep --help
assert_eq "$RC" "0" "--help exits 0"
assert_contains "$OUT" "--preflight" "--help documents --preflight"
assert_contains "$OUT" "6 PREREQUISITE MISSING" "--help documents the prerequisite exit code"
assert_contains "$OUT" "SHIPS DISARMED" "--help states the shipped mode"
# Static pin: a literal `--apply` (or `--arm`) in the TEMPLATE's ProgramArguments
# is the fleet-wide arming the arming gate exists to prevent. The mode must be a
# placeholder the INSTALLER resolves from a dated record.
assert_file "$TEMPLATE" "the hygiene template ships"
tpl_prog_args="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$TEMPLATE")"
assert_contains "$tpl_prog_args" "{{WORKTREE_HYGIENE_MODE}}" "template mode is the arming placeholder"
assert_absent "$tpl_prog_args" "<string>--apply</string>" "template ProgramArguments carries NO literal --apply"
assert_contains "$(cat "$TEMPLATE")" "SHIPS DISARMED" "template says, in its own text, that it ships disarmed"

# ── T2: the rc mapping ───────────────────────────────────────────────────────
echo ""
echo "── T2. the rc mapping (a degraded pass is never a clean one) ──"
reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "0" "both engines clean → 0"
assert_nofile "$MARKER" "a clean pass leaves NO blocked marker"

reset_state
STUB_ENGINE_RC=3 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "2" "engine FAIL-CLOSED (rc=3) → 2 INCOMPLETE"
assert_file "$MARKER" "an incomplete pass records a blocked marker"
assert_contains "$(cat "$MARKER")" "rc=3 worktree engine FAIL-CLOSED" "the marker names the engine's fail-closed rc"

reset_state
STUB_ENGINE_RC=9 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "2" "an unexpected engine rc → 2 INCOMPLETE (never 0)"

reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=2 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "2" "branch reaper INCOMPLETE (rc=2) → 2"
assert_contains "$(cat "$MARKER" 2>/dev/null)" "rc=2 branch reaper INCOMPLETE" "the marker names the reaper's rc=2"

reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=4 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "4" "branch reaper PARTIAL (rc=4) → 4 PARTIAL"

reset_state
run_sweep --repo "$REPO" --engine "$STUB_ENGINE" --aged-days abc
assert_eq "$RC" "3" "a non-numeric --aged-days → 3 usage (no coercion)"
run_sweep --repo "$REPO" --engine "$STUB_ENGINE" --nonsense
assert_eq "$RC" "3" "an unknown flag → 3 usage"
run_sweep --repo "$T/does-not-exist" --engine "$STUB_ENGINE"
assert_eq "$RC" "3" "a missing repo → 3 usage"

# A clean pass must CLEAR a marker an earlier pass left: otherwise "is the last
# pass healthy?" is answered by history, not by the last pass.
reset_state
mkdir -p "$STATE"; printf 'stale reason\n' > "$MARKER"
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "0" "the recovery pass exits 0"
assert_nofile "$MARKER" "the recovery pass CLEARS the earlier blocked marker"

# ── T3: the remove-row count, on a constructed fixture ───────────────────────
echo ""
echo "── T3. the remove-row count (the engine's rows are TAB-separated) ──"
reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_TWO_REMOVE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "0" "the fixture pass is clean"
assert_contains "$OUT" "remove-rows=2" "two remove rows are counted (the fixture also carries one preserve row and one space-separated decoy)"
assert_absent "$OUT" "remove-rows=3" "the decoy line does not inflate the count"
assert_absent "$OUT" "remove-rows=0" "the count is not the pre-fix constant 0"
assert_contains "$OUT" "worktree engine: mode=--dry-run rc=0 remove-rows=2" "the count is reported WITH the mode it was measured in"

reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_contains "$OUT" "remove-rows=0" "a pass with no remove rows reports 0 (the counter is not simply always-on)"

# ── T4: a dry run writes and removes nothing ─────────────────────────────────
echo ""
echo "── T4. a dry run writes NOTHING and removes NOTHING ──"
reset_state
# The scout branch EXISTS and the scout checkout does NOT: this is exactly the
# shape in which the pre-fix carve-out created a worktree during a dry run.
assert_nodir "$REPO/.worktrees/dispatch-scout" "fixture precondition: the scout checkout is absent"
wts_before="$("$REAL_GIT" -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')"
refs_before="$("$REAL_GIT" -C "$REPO" for-each-ref refs/heads --format='%(refname) %(objectname)')"
tree_before="$("$REAL_GIT" -C "$REPO" status --porcelain --ignored=no 2>/dev/null; find "$REPO" -path "$REPO/.git" -prune -o -print | sort)"
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_TWO_REMOVE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$STUB_ENGINE"
assert_eq "$RC" "0" "the dry run exits 0"
assert_contains "$(cat "$T/engine-argv.txt" 2>/dev/null)" "--dry-run" "the engine was invoked in DRY-RUN"
assert_absent "$(cat "$T/engine-argv.txt" 2>/dev/null)" "--apply" "the engine was never armed"
assert_absent "$(cat "$T/reaper-argv.txt" 2>/dev/null)" "--apply" "the branch reaper was never armed"
assert_absent "$(cat "$T/reaper-argv.txt" 2>/dev/null)" "--backup-bundle" "a dry run writes no recovery bundle"
assert_nodir "$REPO/.worktrees/dispatch-scout" "the dry run did NOT create the dispatch-scout worktree"
assert_eq "$("$REAL_GIT" -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')" "$wts_before" "the worktree list is UNCHANGED"
assert_eq "$("$REAL_GIT" -C "$REPO" for-each-ref refs/heads --format='%(refname) %(objectname)')" "$refs_before" "every branch ref is UNCHANGED (no deletion, no creation)"
assert_eq "$("$REAL_GIT" -C "$REPO" status --porcelain --ignored=no 2>/dev/null; find "$REPO" -path "$REPO/.git" -prune -o -print | sort)" "$tree_before" "the working tree is byte-for-byte UNCHANGED"
assert_nodir "$T/backup/$(date +%Y-%m-%d)" "a dry run creates no dated backup dir"
# The scout carve-out must still work when ARMED — the fix is the mode guard, not
# the removal of the feature. (Asserted here so a future "fix" cannot delete it.)
reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_NONE" STUB_REAPER_RC=0 run_sweep --apply --repo "$REPO" --engine "$STUB_ENGINE"
assert_contains "$(cat "$T/engine-argv.txt" 2>/dev/null)" "--apply" "an armed pass arms the engine"
assert_dir "$REPO/.worktrees/dispatch-scout" "an ARMED pass still re-establishes the dispatch-scout checkout"
assert_contains "$(cat "$T/reaper-argv.txt" 2>/dev/null)" "--apply" "an armed pass arms the branch reaper"
assert_dir "$T/backup/$(date +%Y-%m-%d)" "an armed pass creates the dated backup dir (the bundle needs a home)"

# ── T5: the prerequisite probe (the #10 hazard) ──────────────────────────────
echo ""
echo "── T5. a prerequisite that does not resolve is rc=6 and is NAMED ──"
# The engine shape that agent-infra#2052 creates: a farmed script that sources a
# sibling library from its own directory. Without the library it exits 3 on every
# pass — the armed-job-sits-inert failure — so the sweep must refuse BY NAME.
NEEDY_DIR="$T/needy"; mkdir -p "$NEEDY_DIR"
NEEDY_ENGINE="$NEEDY_DIR/pi-reap-worktrees.sh"
printf '#!/usr/bin/env bash\n. "$(dirname "${BASH_SOURCE[0]}")/lib/bounded.sh"\nexit 0\n' > "$NEEDY_ENGINE"
chmod +x "$NEEDY_ENGINE"
reset_state
sweep_env; OUT="$(HYGIENE_STATE_DIR="$T/state-preflight" bash "$SWEEP" --preflight --repo "$REPO" --engine "$NEEDY_ENGINE" 2>&1)"; RC=$?
assert_eq "$RC" "6" "--preflight is rc=6 when a sourced library is absent"
assert_contains "$OUT" "lib/bounded.sh" "--preflight NAMES the missing library"
assert_contains "$OUT" "PREREQ BLOCKED" "--preflight verdict is explicit"
assert_nodir "$T/state-preflight" "--preflight writes nothing (not even its own state dir)"

reset_state
STUB_ENGINE_RC=0 STUB_ENGINE_ROWS_FILE="$ROWS_TWO_REMOVE" STUB_REAPER_RC=0 run_sweep --repo "$REPO" --engine "$NEEDY_ENGINE"
assert_eq "$RC" "6" "a PASS with a missing prerequisite is rc=6, not the generic 2"
assert_absent "$OUT" "remove-rows=" "the pass never reached the engine (nothing was attempted)"
assert_contains "$(cat "$MARKER" 2>/dev/null)" "lib/bounded.sh" "the blocked marker names the missing prerequisite"

mkdir -p "$NEEDY_DIR/lib"; printf ':\n' > "$NEEDY_DIR/lib/bounded.sh"
sweep_env; OUT="$(bash "$SWEEP" --preflight --repo "$REPO" --engine "$NEEDY_ENGINE" 2>&1)"; RC=$?
assert_eq "$RC" "0" "--preflight is rc=0 once the library resolves"
assert_contains "$OUT" "PREREQ OK" "--preflight prints the ready verdict"

reset_state
sweep_env; OUT="$(bash "$SWEEP" --preflight --repo "$REPO" --engine "$T/bin/absent-engine.sh" 2>&1)"; RC=$?
assert_eq "$RC" "6" "--preflight is rc=6 when the engine itself is absent"

# ── T6-T8: the arming contract ───────────────────────────────────────────────
echo ""
echo "── T6. the routine install CANNOT arm the job ──"
# A templates dir with ONLY this template, so the install loop is one job.
TPL_DIR="$T/tpl"; mkdir -p "$TPL_DIR"
cp "$TEMPLATE" "$TPL_DIR/"

# launchctl shim: nothing here may reach the real launchd domain.
mkdir -p "$T/shim"
cat > "$T/shim/launchctl" <<'SHIM'
#!/usr/bin/env bash
echo "launchctl $*" >> "${FAKE_LAUNCHCTL_LOG:-/dev/null}"
exit 0
SHIM
chmod +x "$T/shim/launchctl"

A_HOME="$T/armhome"; AGENTS="$A_HOME/Library/LaunchAgents"
ARM_FILE="$T/state-arm/worktree-hygiene.armed"
mkdir -p "$AGENTS" "$A_HOME/.pi/agent/scripts"
# The farmed copy the unit executes, and the farmed engine the sweep resolves.
cp "$SWEEP" "$A_HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh"
cp "$STUB_ENGINE" "$A_HOME/.pi/agent/scripts/pi-reap-worktrees.sh"
INSTALLED="$AGENTS/com.tortoise.worktree-hygiene.plist"

run_installer() { # run_installer <args...>
    local out
    out="$(
        HOME="$A_HOME" PATH="$T/shim:$PATH" FAKE_LAUNCHCTL_LOG="$T/launchctl.log" \
        TEMPLATES_DIR="$TPL_DIR" AGENTS_DIR="$AGENTS" \
        WORKTREE_HYGIENE_ARM_FILE="$ARM_FILE" \
        TORTOISE_REPO="$REPO" ELDATO_ALLOW_TEST_HOME=1 \
        HYGIENE_STATE_DIR="$T/state-arm" HYGIENE_BACKUP_DIR="$T/backup-arm" \
        bash "$INSTALLER" "$@" 2>&1
    )"
    RC=$?
    OUT="$out"
}

rm -f "$INSTALLED" "$ARM_FILE"
run_installer
assert_eq "$RC" "0" "the no-argument install exits 0"
assert_file "$INSTALLED" "the no-argument install writes the unit"
assert_contains "$(cat "$INSTALLED")" "<string>--dry-run</string>" "the ROUTINE install renders --dry-run (this is what pi-bootstrap/setup.sh runs on every Mac)"
assert_absent "$(cat "$INSTALLED")" "<string>--apply</string>" "the routine install never renders --apply"
assert_absent "$(cat "$INSTALLED")" "{{" "no placeholder survives into the installed unit"
assert_nofile "$ARM_FILE" "the routine install writes no arming record"

echo ""
echo "── T7. arming refuses a box whose sweep cannot run (#10) ──"
# (a) the farmed copy the unit executes is absent → refuse, or the unit points at nothing.
mv "$A_HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh" "$T/farmed-away.sh"
rm -f "$ARM_FILE"
run_installer --arm-worktree-hygiene --reason "test"
assert_eq "$RC" "1" "arming is REFUSED when the farmed sweep is absent"
assert_contains "$OUT" "farmed copy" "the refusal names the missing farmed copy"
assert_nofile "$ARM_FILE" "no arming record was written"
mv "$T/farmed-away.sh" "$A_HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh"

# (b) farmed copy present, the ENGINE it drives absent → the sweep's preflight is
# rc=6 and arming must refuse. This is the #10 shape: an armed 6-hourly job that
# exits 6 and deletes nothing, looking installed and healthy.
mv "$A_HOME/.pi/agent/scripts/pi-reap-worktrees.sh" "$T/engine-away.sh"
rm -f "$ARM_FILE" "$INSTALLED"
run_installer --arm-worktree-hygiene --reason "test"
assert_eq "$RC" "1" "arming is REFUSED when the engine prerequisite does not resolve"
assert_contains "$OUT" "prerequisites do not resolve" "the refusal says why"
assert_contains "$OUT" "no worktree engine found" "the refusal carries the sweep's own named reason"
assert_nofile "$ARM_FILE" "no arming record was written for an inert box"
mv "$T/engine-away.sh" "$A_HOME/.pi/agent/scripts/pi-reap-worktrees.sh"

echo ""
echo "── T8. arming is dated, visible in the unit, and reversible ──"
rm -f "$ARM_FILE" "$INSTALLED"
run_installer --arm-worktree-hygiene --reason "review finding 1 fixture"
assert_eq "$RC" "0" "arming a ready box exits 0"
assert_file "$ARM_FILE" "arming writes the record"
assert_contains "$(cat "$ARM_FILE" 2>/dev/null)" "armed-by=" "the record names WHO armed it"
assert_contains "$(cat "$ARM_FILE" 2>/dev/null)" "armed-date=" "the record is DATED"
assert_contains "$(cat "$ARM_FILE" 2>/dev/null)" "reason=review finding 1 fixture" "the record carries the reason"
assert_file "$INSTALLED" "arming re-installs the unit in the same command"
assert_contains "$(cat "$INSTALLED")" "<string>--apply</string>" "the ARMED unit carries a visible --apply in ProgramArguments"

# Idempotent re-arm keeps the ORIGINAL date (the date is the audit datum).
first_date="$(sed -n 's/^armed-date=//p' "$ARM_FILE" | head -1)"
run_installer --arm-worktree-hygiene --reason "again"
assert_eq "$RC" "0" "re-arming an armed box exits 0"
assert_contains "$OUT" "ALREADY ARMED" "re-arming reports that it was already armed"
assert_eq "$(sed -n 's/^armed-date=//p' "$ARM_FILE" | head -1)" "$first_date" "re-arming does NOT re-date the record"

# ⛔ NOT AN ENVIRONMENT DEFAULT. With the same ambient env an operator could
# export by accident, and NO record, the unit must still render --dry-run: the
# mode is derived from a dated FILE, never from the environment.
arm_copy="$(cat "$ARM_FILE")"
rm -f "$ARM_FILE" "$INSTALLED"
run_installer_env() { # run_installer_env <VAR=value>... — installs with ambient env overrides
    local out
    out="$(
        env "$@" HOME="$A_HOME" PATH="$T/shim:$PATH" FAKE_LAUNCHCTL_LOG="$T/launchctl.log" \
        TEMPLATES_DIR="$TPL_DIR" AGENTS_DIR="$AGENTS" \
        WORKTREE_HYGIENE_ARM_FILE="$ARM_FILE" \
        TORTOISE_REPO="$REPO" ELDATO_ALLOW_TEST_HOME=1 \
        HYGIENE_STATE_DIR="$T/state-arm" HYGIENE_BACKUP_DIR="$T/backup-arm" \
        bash "$INSTALLER" 2>&1
    )"
    RC=$?
    OUT="$out"
}
run_installer_env WORKTREE_HYGIENE_MODE=--apply
assert_eq "$RC" "0" "the install with an ambient mode exits 0"
assert_contains "$(cat "$INSTALLED" 2>/dev/null)" "<string>--dry-run</string>" "an ambient WORKTREE_HYGIENE_MODE=--apply CANNOT arm the job (the mode is a record, not an env default)"
printf '%s\n' "$arm_copy" > "$ARM_FILE"

# Disarm reverses it, in one command, and the unit goes back to dry-run.
run_installer --disarm-worktree-hygiene
assert_eq "$RC" "0" "disarming exits 0"
assert_nofile "$ARM_FILE" "disarming removes the record"
assert_contains "$(cat "$INSTALLED")" "<string>--dry-run</string>" "the DISARMED unit goes back to --dry-run"
assert_absent "$(cat "$INSTALLED")" "<string>--apply</string>" "no --apply survives a disarm"
run_installer --disarm-worktree-hygiene
assert_eq "$RC" "0" "disarming a disarmed box exits 0 (idempotent)"

# A TRUNCATED record must read as DISARMED: a half-written arming file is not an
# arming, and it must fail in the safe direction.
rm -f "$INSTALLED"; mkdir -p "$(dirname "$ARM_FILE")"; printf 'armed-by=someone\n' > "$ARM_FILE"
run_installer
assert_contains "$(cat "$INSTALLED")" "<string>--dry-run</string>" "a record without a date renders DISARMED (fail-safe)"
rm -f "$ARM_FILE"

# --status must answer the arming question without reading code.
run_installer --status
assert_contains "$OUT" "worktree-hygiene: DISARMED" "--status reports the disarmed state"
mkdir -p "$(dirname "$ARM_FILE")"
printf 'armed-by=t\narmed-date=2026-10-18T00:00:00Z\n' > "$ARM_FILE"
run_installer --status
assert_contains "$OUT" "worktree-hygiene: ARMED" "--status reports the armed state"
rm -f "$ARM_FILE"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
