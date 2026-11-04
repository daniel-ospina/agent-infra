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
#   D4  a file that APPEARED since the stamp (was recorded `missing`) is NOT drift
#   D5  the checkout disagrees with the deployed copy => SOURCE-DRIFT, exit 1 (the measured shape:
#       a farm copy byte-identical to origin/main beside a checkout 153 commits behind)
#   D6  the checkout does not have the file at all => drift, named
#   D7  NO record => exit 3 UNSTAMPED, never 0 (an absent record is a set-up gap, not a match)
#   D8  an EMPTY record => exit 3 (a record that names no file verifies nothing)
#   D9  usage errors => exit 2, and --help exits 0
# Hermetic: pure filesystem fixtures under a temp dir; no network, no systemd, no $HOME writes.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/disk-reaper-deployed-check.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
has() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }

[ -x "$CHECK" ] || { echo "  ❌ the checker is not executable: $CHECK"; echo "PASS=0 FAIL=1"; exit 1; }

FILES="disk-reaper.sh disk-reaper-run.sh pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh
reap-abandoned-worktrees.sh reap-duplicate-installs.sh"

# mk_env — a deployed dir + a matching checkout, both carrying the same bytes.
mk_env() {
    T="$(mktemp -d "${TMPDIR:-/tmp}/drdc-test.XXXXXX")"
    mkdir -p "$T/deployed" "$T/src/scripts"
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
has "$OUT" "SUMMARY deployed ok (7 files" "D1 the summary counts every pinned file"
OUT="$(run --dir "$T/deployed" --record "$REC" --source "$T/src")"; RC=$?
eq "$RC" "0" "D1 …and it verifies against the checkout it was stamped from"
has "$OUT" "SUMMARY deployed ok (7 files; matches $T/src)" "D1 the source is named in the summary"

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

# ── D4: a file that APPEARED since the stamp is NOT drift ────────────────────────
mk_env
mv "$T/deployed/pi-reap-worktrees.sh" "$T/deployed/.later"
run --stamp --dir "$T/deployed" --record "$REC" >/dev/null 2>&1
mv "$T/deployed/.later" "$T/deployed/pi-reap-worktrees.sh"
OUT="$(run --dir "$T/deployed" --record "$REC")"; RC=$?
eq "$RC" "0" "D4 a file farmed AFTER the stamp does not fail the pass"
has "$OUT" "appeared  pi-reap-worktrees.sh" "D4 …and the check says so rather than staying silent"

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

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
