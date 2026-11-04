#!/usr/bin/env bash
# # shard: disk-reaper-deployed-check
# disk-reaper-deployed-check.test.sh — self-check for scripts/disk-reaper-deployed-check.sh
#
# WHY THIS SUITE EXISTS. The checker answers "is the copy that RUNS the copy we think it is?" — and a
# checker that cannot FAIL is worse than none, because it certifies a stale deployment. So every case
# here is driven to its red path as well as its green one:
#   D1  a fresh stamp verifies (control — without this every case below could be red for the wrong reason)
#   D2  ONE BYTE changed in a deployed delegate => DRIFT, exit 1, and the file is NAMED
#   D3  a delegate DELETED from the deployed dir => DRIFT (the unit pins it; the pass would fail closed)
#   D4  a file farmed after the stamp is APPEARED => re-stamp required (never green); the
#       same stamp re-taken over it verifies (a measurement, not a latch)
#   D5  the checkout disagrees with the deployed copy => SOURCE-DRIFT, exit 1 (the measured shape:
#       a farm copy byte-identical to origin/main beside a checkout 153 commits behind)
#   D6  the checkout does not have the file at all => drift, named
#   D7  NO record => exit 3 UNSTAMPED, never 0 (an absent record is a set-up gap, not a match)
#   D8  an EMPTY record => exit 3 (a record that names no file verifies nothing)
#   D9  usage errors => exit 2, unreadable record => 2, --help => 0; D9c a pinned file the record
#       never mentions is UNRECORDED (the pinned set is reconciled, not trusted)
#   D10 a stamp taken over an INCOMPLETE deployed set can never verify (a missing pinned file is drift)
# Hermetic: pure filesystem fixtures under a temp dir; no network, no systemd, no $HOME writes.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/disk-reaper-deployed-check.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
neq() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (unexpectedly got: $1)"; fi; }
has() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }

# ⛔ A MISSING HELPER IS A SILENTLY-SKIPPED ASSERTION, NOT A TEST FAILURE (review of #3405 round 3).
# `neq` was called here for a whole round while defined nowhere: bash printed "command not found", no
# assertion was recorded, and the suite still reported `PASS=44 FAIL=0` — one arm short, green. The
# vocabulary is therefore DERIVED from the file rather than hardcoded: every helper-shaped name the
# script uses must be defined by a `name()` in the same file (a hardcoded list just moves the hole).
_self="${BASH_SOURCE[0]}"
_used="$(grep -oE '\b(assert_[a-z_]+|eq|neq|ok|bad|has)\b' "$_self" | sort -u)"
_defined="$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$_self" | sed -E 's/\(\).*$//' | sort -u)"
# ⛔ NO PIPE IN THE LOOKUP: `printf | grep -q` under `set -o pipefail` is a FALSE-RED GENERATOR.
# grep -q exits at the first match, printf takes SIGPIPE (141), pipefail propagates it, and `if !`
# then reports a helper that IS defined as missing — measured 49/100 runs on the unmodified file.
# A membership test must not be a pipeline: `case` on a newline-delimited string is pure bash.
for _h in $_used; do
    case $'\n'"$_defined"$'\n' in
        *$'\n'"$_h"$'\n'*) : ;;
        *)
            if grep -qE "(^|[;&|]|then |else |if |while |! )$_h( |\$)" "$_self"; then
                echo "  ❌ harness bug: assertion helper '$_h' is CALLED but never DEFINED"; exit 1
            fi
            ;;
    esac
done

[ -x "$CHECK" ] || { echo "  ❌ the checker is not executable: $CHECK"; echo "PASS=0 FAIL=1"; exit 1; }

FILES="disk-reaper.sh disk-reaper-run.sh pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh
reap-abandoned-worktrees.sh reap-duplicate-installs.sh lib/bounded.sh lib/live-paths.sh"

# mk_env — a deployed dir + a matching checkout, both carrying the same bytes.
mk_env() {
    T="$(mktemp -d "${TMPDIR:-/tmp}/drdc-test.XXXXXX")"
    mkdir -p "$T/deployed/lib" "$T/src/scripts/lib"
    local f
    for f in $FILES; do
        printf '#!/bin/bash\n# %s v1\n' "$f" >"$T/deployed/$f"
        printf '#!/bin/bash\n# %s v1\n' "$f" >"$T/src/scripts/$f"
    done
    REC="$T/deployed.record"
}
run() { bash "$CHECK" "$@" 2>&1; }

echo "── disk-reaper-deployed-check.test.sh ─────────────────────────────────────────────"

# ── D1: control — a fresh stamp verifies, WITH and WITHOUT a source ──────────────
mk_env
OUT="$(run --stamp --dir "$T/deployed" --record "$REC" --source "$T/src")"; RC=$?
eq "$RC" "0" "D1 --stamp exits 0"
has "$OUT" "STAMPED" "D1 --stamp says what it did"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D1 a fresh stamp VERIFIES (control: the cases below are not red by default)"
has "$OUT" "SUMMARY deployed ok (9 files" "D1 the summary counts every pinned file"
OUT="$(run --dir "$T/deployed" --record "$REC" --source "$T/src")"; RC=$?
eq "$RC" "0" "D1 …and it verifies against the checkout it was stamped from"
has "$OUT" "SUMMARY deployed ok (9 files; matches $T/src)" "D1 the source is named in the summary"

# ── D2: ONE BYTE changed in one delegate => DRIFT, named ─────────────────────────
printf '#!/bin/bash\n# pi-reap-worktrees.sh v2\n' >"$T/deployed/pi-reap-worktrees.sh"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "1" "D2 a changed deployed file is DRIFT (exit 1)"
has "$OUT" "DRIFT     pi-reap-worktrees.sh" "D2 the drifted file is NAMED"
has "$OUT" "deployed drift detected" "D2 the summary says drift, never 'ok'"
# D2b: the SAME bytes restored => green again (so D2 is not a one-way latch).
printf '#!/bin/bash\n# pi-reap-worktrees.sh v1\n' >"$T/deployed/pi-reap-worktrees.sh"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D2b restoring the byte restores the verdict (the check is a measurement, not a latch)"

# ── D3: a delegate the unit pins is MISSING => drift ─────────────────────────────
mv "$T/deployed/reap-lane-venvs.sh" "$T/deployed/.gone"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "1" "D3 a MISSING pinned delegate is drift (exit 1)"
has "$OUT" "reap-lane-venvs.sh — MISSING" "D3 the missing file is named, with why it matters"
mv "$T/deployed/.gone" "$T/deployed/reap-lane-venvs.sh"

# ── D4: a file farmed after the stamp is APPARENT, not verified (review of #3405) ─────
# It used to continue to a green summary, i.e. exit 0 for bytes nobody had ever hashed. A delegate the
# record called absent and someone then hand-copied in is exactly the "stale copy that quietly runs"
# shape, so it is now a re-stamp requirement.
mk_env
mv "$T/deployed/pi-reap-worktrees.sh" "$T/deployed/.later"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
mv "$T/deployed/.later" "$T/deployed/pi-reap-worktrees.sh"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "1" "D4 a file farmed AFTER the stamp is not claimed as verified (exit 1)"
has "$OUT" "APPEARED  pi-reap-worktrees.sh" "D4 …and the check names it as unmeasured, not as ok"
has "$OUT" "re-stamp" "D4 …and says what makes it accountable again"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D4 …re-stamping makes it green again (a measurement, not a permanent error)"

# ── D5/D6: the deployed-vs-SOURCE comparison ────────────────────────────────────
mk_env
run --stamp --dir "$T/deployed" --record "$REC" --source "$T/src" >/dev/null 2>&1
printf '#!/bin/bash\n# pi-reap-worktrees.sh FIXED\n' >"$T/deployed/pi-reap-worktrees.sh"
run --stamp --dir "$T/deployed" --record "$REC" --source "$T/src" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D5 precondition: the deployed set matches its (re-)stamp"
OUT="$(run --dir "$T/deployed" --record "$REC" --source "$T/src")"; RC=$?
eq "$RC" "1" "D5 deployed != checkout => SOURCE-DRIFT (the measured 153-commit shape)"
has "$OUT" "SOURCE-DRIFT pi-reap-worktrees.sh" "D5 the file and both digests are named"
rm -f "$T/src/scripts/reap-duplicate-installs.sh"
OUT="$(run --dir "$T/deployed" --record "$REC" --source "$T/src")"; RC=$?
eq "$RC" "1" "D6 a checkout that does not carry the file is drift, never a silent pass"
has "$OUT" "reap-duplicate-installs.sh — $T/src/scripts does not have it" "D6 …and it says the checkout cannot explain it"

# ── D7/D8: an unproven deployment is exit 3, never 0 ────────────────────────────
mk_env
OUT="$(run --dir "$T/deployed" --record "$T/no-such-record")"; RC=$?
eq "$RC" "3" "D7 no record => UNSTAMPED (3), never 'ok'"
has "$OUT" "UNPROVEN" "D7 the refusal says the question is unanswered, and names the remedy"
has "$OUT" "--stamp" "D7 …and gives the verb that answers it"
printf '# only a header\n' >"$T/empty.record"
OUT="$(run --dir "$T/deployed" --record "$T/empty.record")"; RC=$?
eq "$RC" "3" "D8 an EMPTY record verifies nothing (3)"
has "$OUT" "names no file" "D8 …and says why"

# ── D9: usage ──────────────────────────────────────────────────────────────────
run --bogus >/dev/null 2>&1; eq "$?" "2" "D9 an unknown flag is a usage error (2)"
run --help >/dev/null 2>&1; eq "$?" "0" "D9 --help exits 0"
run --stamp --dir "$T/does-not-exist" --record "$T/r2" >/dev/null 2>&1; eq "$?" "2" \
    "D9 --stamp on a directory that does not exist is refused (a stamp of nothing is a false PASS)"
# D9b: an UNREADABLE record is 2 (a permissions problem), never 3 ("nobody stamped it").
mk_env
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
chmod 000 "$REC"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
chmod 644 "$REC"
if [ "$(id -u)" = 0 ]; then
    echo "  · D9b skipped (root can read anything)"
else
    eq "$RC" "2" "D9b an unreadable record is exit 2, not 'unstamped'"
    has "$OUT" "cannot be read" "D9b …and the refusal says it is a permissions problem"
fi
# D9c: a pinned file that the record never mentions is UNMEASURED, not fine.
printf '# trimmed record\n' >"$T/trim.record"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
grep -vF '  reap-duplicate-installs.sh' "$REC" >"$T/trim.record"
OUT="$(run --dir "$T/deployed" --record "$T/trim.record")"; RC=$?
eq "$RC" "1" "D9c a pinned delegate missing from the record makes the check fail (the set is reconciled, not trusted)"
has "$OUT" "UNRECORDED reap-duplicate-installs.sh" "D9c …and it is named"

# ── D10: a stamp taken over an INCOMPLETE deployed set must not verify (round 2) ────────
# The first fix only caught "farmed after the stamp". A file stamped MISSING and STILL absent fell
# through to a green summary — so stamping an empty directory printed `deployed ok` and exited 0 with
# every pinned file, entry point included, gone. A pinned file that is missing IS the exit-1 arm.
mk_env
rm -f "$T/deployed/disk-reaper.sh"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "1" "D10 a stamp taken over an incomplete set does NOT verify (exit 1)"
has "$OUT" "DRIFT     disk-reaper.sh — stamped MISSING and still absent" "D10 …and the missing pinned file is named"
mk_env
OUT="$(run --dir "$T/deployed" --record "$T/never" 2>/dev/null)"; RC=$?
eq "$RC" "3" "D10 control: a directory nobody stamped is UNSTAMPED (3), not drift"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D10 control: the complete set still verifies"

# ── D11: a digest that could not be taken is UNMEASURED, and that is drift (round 3) ─────
# `printf '%s  %s' "" x` writes two spaces and no digest; the check loop discarded it before counting
# AND the reconciliation matched it as recorded, so an unreadable file was permanently outside the
# check while the summary read ok — a file that could then be replaced with anything.
mk_env
chmod 000 "$T/deployed/lib/live-paths.sh"
OUT="$(run --stamp --dir "$T/deployed" --record "$REC" 2>&1)"; RC=$?
neq "$RC" "0" "D11 stamping a file it cannot hash is NOT success"
has "$OUT" "INCOMPLETE stamp" "D11 …and says the stamp is incomplete"
has "$(cat "$REC")" "unmeasured  lib/live-paths.sh" "D11 …and the record names it unmeasured (never an empty digest field)"
chmod 644 "$T/deployed/lib/live-paths.sh"
OUT="$(run --dir "$T/deployed" --record "$REC" 2>&1)"; RC=$?
eq "$RC" "1" "D11 the check treats UNMEASURED as drift (exit 1), so the file cannot sit outside the check"
has "$OUT" "DRIFT     lib/live-paths.sh — recorded as UNMEASURED" "D11 …naming it as unmeasured, never as ok"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D11 control: a complete stamp over the same set still verifies"
# ── D12: the two-delegate library is in the pinned set (round 3, P1) ────────────────────
# reap-abandoned-worktrees.sh and reap-duplicate-installs.sh both `exit 3` without lib/live-paths.sh,
# and it is the shared process-census code every live-process KEEP verdict comes from.
mk_env
printf 'v9 current\n' >"$T/src/scripts/lib/live-paths.sh"
run --stamp --dir "$T/deployed" --record "$REC" --source "$T/src" >/dev/null 2>&1
OUT="$(run --dir "$T/deployed" --record "$REC" --source "$T/src" 2>&1)"; RC=$?
eq "$RC" "1" "D12 a STALE deployed lib/live-paths.sh is drift, not ok"
has "$OUT" "SOURCE-DRIFT lib/live-paths.sh" "D12 …and it is named as a deployed-vs-source mismatch"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
