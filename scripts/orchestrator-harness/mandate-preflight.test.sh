#!/usr/bin/env bash
# mandate-preflight.test.sh — #3377: a mandate a lane cannot satisfy must be NAMED, not silently skipped.
#
# THE DEFECT (measured 2026-11-03, cell-3 `vm-915c3930…`). The dispatch brief for this lane opens with
# "READ §0 and §0b of LANE-BRIEF-PREAMBLE.md FIRST", and a consumer repo's (tortoise) `AGENTS.md` skill
# table orders every lane to
# read `~/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md` before it derives anything. On the cell BOTH `ls -l`
# calls are rc=2 — the files do not exist — and NOTHING said so. Every lane on that box proceeded as
# though it had read them, and the mandate was an inert enforcer: present in the brief, absent from
# reality, invisible to both the lane and the operator.
#
# WHAT THIS SUITE PINS, and why each check reads RUNTIME OUTPUT rather than this repo's source:
#   §A  all-present is SILENT (rc 0, empty `--line`). An always-on banner is noise a reader learns to
#       skip, and a warning that is always printed is not a warning — so the trivial positive case is a
#       test, not an afterthought.
#   §B  ONE missing is named BY PATH, the present one is NOT — an assertion that only counts lines would
#       pass on a helper that names the wrong file.
#   §C  the state dir being ABSENT is the missing case (rc 1), not a cannot-verify: the remedy is "ship
#       the file", and calling it `2` would send the reader to the wrong remedy.
#   §D  CANNOT VERIFY is a separate verdict from absent, for the state dir AND for a single file: a file
#       that exists with mode 000 is not "missing" (its remedy is `chmod`, not a deployment), and a
#       `[ -f ]`-only check called that case `ok` — a false PASS this section exists because the first
#       cut of this helper had it.
#   §E  BOTH dispatch seams are wired — `spawn-gate.sh::run_agent` AND `merge-one.sh::run_agent` (which
#       carries its own copy and spawns the reviewer, the harness's highest-volume `pi` call). They call
#       ONE implementation, and it APPENDS the block to the BRIEF (not only to the log), marker-guarded.
#       A helper nobody calls is the defect it exists to fix, one level up — the "test that cannot fail"
#       class this repo's rig exists to prevent. #2208 is the precedent for covering BOTH: a fix in one
#       `run_agent` left the identical defect in the other, "exactly where it costs most".
#   §F  non-vacuity, and the DEPLOYMENT manifests: a `$O` that lost the file is a box where the
#       disclosure silently does not happen, so the two lists that name executed harness files must
#       carry it.
#
# SCOPE: the content of the mandate files is NOT this suite's business and must not be invented here
# (#1193 owns it): this pins the REPORT, never the file.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/mandate-preflight.sh"
SPAWN="$HERE/spawn-gate.sh"
MERGE="$HERE/merge-one.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

[ -f "$HELPER" ] || { echo "❌ no mandate-preflight.sh at $HELPER"; exit 2; }
[ -f "$SPAWN" ]  || { echo "❌ no spawn-gate.sh at $SPAWN"; exit 2; }
[ -f "$MERGE" ]  || { echo "❌ no merge-one.sh at $MERGE"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mandate-preflight.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
# CELL_HOME is the resolution the bring-up uses (§1 of the cmux-cells skill) and it keeps this suite off
# the real ~/.pi/agent/state — a test that reads the developer's own box reports the developer's box.
mkstate() { rm -rf "$TMP/home"; mkdir -p "$TMP/home/.pi/agent/state"; }
run()     { CELL_HOME="$TMP/home" bash "$HELPER" "$@"; }
# seam_brief <file> — the MINIMAL brief that satisfies brief-gate.sh's schema, written statically.
# ⛔ Not produced by invoking the brief-gate helper from inside this suite (see the note at the seam
# fixture): a nested script invocation under a variable path makes the working-tree guard refuse to run
# this file at all, and the mandate arm is not the place to re-test brief-gate's own text.
# ⛔ EVERY SECTION THE GATE REQUIRES FOR `role: reviewer` MUST BE HERE, OR THE WHOLE §E CLUSTER REDS
# FOR A REASON THAT HAS NOTHING TO DO WITH THE MANDATE DISCLOSURE (measured 2026-11-10, 18 arms).
# `brief-gate.sh` gained the `## MUTATION ATTRIBUTION` requirement later (#3442), and this fixture kept
# the older shape — so `run_agent` refused the brief at the gate (exit 80, "nothing was started"), and
# every assertion downstream of the dispatch reddened: the append, the log, `STUB-PI-RAN`, the last-line
# arms, all of it, with the mandate emit never reached. The fixture is the SUBJECT of the appendix, not
# the gate: the gate's own text is `brief-gate.test.sh`'s subject, and re-testing it here is what let a
# schema change silently disable 18 arms of a different suite. The `NO NEW ASSERTIONS:` line is written
# at COLUMN 0 on purpose — the gate skips the indented form, and this brief carries no diff.
seam_brief() {
  cat > "$1" <<'BRIEF'
# a brief for the seam
## RESEARCH FIRST
INTERNAL: nothing — this is a TEST FIXTURE; its subject is the mandate disclosure, not research.
EXTERNAL: nothing — see INTERNAL.
RUNG: 3 — web_fetch
CONTRADICTION TEST: no recorded decision reaches this work — it is a test fixture.
## PREVIOUS WORK
CLAIM: unclaimed — test fixture
WIP: keyless — test fixture: this brief is the subject of another suite, not a real dispatch
BRANCH: none — test fixture
WORKTREE: none — test fixture
PRIOR: no previous attempt — test fixture
## MUTATION ATTRIBUTION
NO NEW ASSERTIONS: test fixture — this brief carries no diff; it exists to exercise the mandate disclosure.
BRIEF
}

echo "§A all present → SILENT"
mkstate
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
: > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
run --check >/dev/null 2>&1; ck $? "both present → rc 0"
LINE="$(run --line)"; [ -z "$LINE" ]; ck $? "both present → --line renders NOTHING (empty, not a banner)"
MISS="$(run --missing)"; [ -z "$MISS" ]; ck $? "--missing is empty when both are present"
# ⛔ THE POSITIVE CONTROL FOR EVERY `--missing` rc-2 ARM (#3379 review cycle 27): a verb that answered 2
# unconditionally would satisfy all of them, so the healthy box is asserted at rc 0 here.
run --missing >/dev/null 2>&1; ck $? "…and --missing is rc 0 on a healthy box (the control that stops a '2 to everything' helper passing the CANNOT-VERIFY arms)"

echo "§B one missing → named BY PATH, the present one NOT named"
rm -f "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
run --check >/dev/null 2>&1; [ $? -eq 1 ]; ck $? "one missing → rc 1"
LINE="$(run --line)"
# ⛔ NOT `printf … | grep -q` (check-no-sigpipe-grep.sh, #841/#864): under `pipefail` a `grep -q` that
# exits at the first match gives the producer SIGPIPE, so the pipeline reports the DEATH OF THE PRODUCER
# rather than grep's answer — and the arm would pass or fail for the wrong reason. `case` has no such
# failure mode; the searches below are literal substring tests by design.
case "$LINE" in *TORTOISE-GRAPH-BRIEF.md*) _rc=0;; *) _rc=1;; esac; ck $_rc "--line NAMES the missing file"
case "$LINE" in *LANE-BRIEF-PREAMBLE.md*) bad "--line names the PRESENT file too (it must not)";; *) ok "--line does NOT name the file that is present";; esac
LINE_LC="$(printf '%s' "$LINE" | tr '[:upper:]' '[:lower:]')"
case "$LINE_LC" in *"cannot be obeyed"*) _rc=0;; *) _rc=1;; esac; ck $_rc "--line says the instruction cannot be OBEYED (the fact, not just a path)"
case "$LINE" in *#3377*) _rc=0;; *) _rc=1;; esac; ck $_rc "--line cites the issue, so a reader has a home to file against"

echo "§C state dir ABSENT → the missing case (rc 1), not cannot-verify"
rm -rf "$TMP/home/.pi/agent"
run --check >/dev/null 2>&1; [ $? -eq 1 ]; ck $? "no state dir at all → rc 1 (remedy: ship the file)"
MISS="$(run --missing)"
[ "$(printf '%s\n' "$MISS" | grep -c '\.md$')" = "2" ]; ck $? "both declared files are reported missing"

echo "§D CANNOT VERIFY (rc 2) is a separate verdict from ABSENT"
mkstate; chmod 000 "$TMP/home/.pi/agent/state"
if [ -r "$TMP/home/.pi/agent/state" ]; then
  ok "(skipped: this user can read a 000 dir — running as root?)"
else
  run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "unreadable state dir → rc 2 CANNOT VERIFY"
  run --check 2>&1 | grep -qF 'CANNOT VERIFY'; ck $? "and it SAYS so on stderr"
  LINE="$(run --line)"
  case "$LINE" in *UNREADABLE*|*"CANNOT VERIFY"*) _rc=0;; *) _rc=1;; esac; ck $_rc "--line reports an unreadable dir as CANNOT VERIFY / UNREADABLE (not as MISSING)"
  case "$LINE" in *MISSING*) bad "--line makes a MISSING claim through an unreadable dir (a false absence claim)";; *) ok "--line makes no absence claim about an unreadable dir";; esac
  # ⛔ THE `--missing` VERB TOO (review cycle 6, P2): `[ -f ]` is false for every file under an unreadable
  # dir, so this verb used to print both paths and rc 0 — telling an operator to SHIP files that may be
  # perfectly present. A documented operator surface must not hand out the wrong remedy.
  MISS_UR="$(run --missing 2>/dev/null)"; [ -z "$MISS_UR" ]; ck $? "--missing prints NOTHING through an unreadable dir (no false 'ship it' advice)"
  # ⛔ READABLE IS NOT SEARCHABLE (review cycle 7, P2, measured): `chmod -R 640` leaves the dir READABLE
  # (`[ -r ]` true) but with no SEARCH bit, so `[ -f "$root/<name>"`] fails for every entry and the check
  # reported both present files as MISSING — the same wrong remedy, one mode bit away from the case
  # above. The predicate must ask whether ANYTHING can be decided about entries here, so it tests `-x` too.
  chmod 640 "$TMP/home/.pi/agent/state"
  if [ -x "$TMP/home/.pi/agent/state" ]; then
    ok "(skipped: this user keeps search permission on a 640 dir — running as root?)"
  else
    run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a readable-but-UNSEARCHABLE dir → rc 2, not 1 (present files must not be called missing)"
    MISS_NS="$(run --missing 2>/dev/null)"; [ -z "$MISS_NS" ]; ck $? "--missing prints NOTHING through a search-less dir"
    run --line | grep -qF 'CANNOT VERIFY'; ck $? "--line says CANNOT VERIFY for a search-less dir"
  fi
  chmod 755 "$TMP/home/.pi/agent/state"
  # ⛔ AND THE CONVERSE (review cycle 8, P2, measured): only the SEARCH bit gates resolving a name, so a
  # dir that is searchable but NOT listable (`chmod 100`, or an ordinary `711` owned by another user) must
  # be ANSWERED, not abstained from — `[ -f ]`/`[ -r ]` on each declared file both work under `--x`. A
  # `-r`-based predicate returned a false CANNOT VERIFY there and told the lane its own readable files were
  # unreadable. This arm exists so the fix cannot regress back to abstaining on a decided case.
  # NOTE: the §D fixture dir is EMPTY, so this arm must create the two files itself — an rc-0 assertion
  # through an empty dir would be asserting the wrong answer (correct there is rc 1), and it is exactly how
  # this arm first failed.
  : > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
  : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  chmod 100 "$TMP/home/.pi/agent/state"
  if [ -r "$TMP/home/.pi/agent/state" ]; then
    ok "(skipped: this user keeps list permission on a 100 dir — running as root?)"
  else
    run --check >/dev/null 2>&1; ck $? "a SEARCHABLE-but-unlistable dir with both files present → rc 0 (the answer IS knowable)"
    MISS_X="$(run --missing)"; [ -z "$MISS_X" ]; ck $? "--missing prints nothing under a searchable-but-unlistable dir"
  fi
  chmod 755 "$TMP/home/.pi/agent/state"
  rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  # ⛔ ONE DIRECTORY UP (review cycle 9, P2, measured): an unsearchable ANCESTOR makes `[ -d "$root" ]`
  # itself false, so the state dir looked ABSENT and both PRESENT files were reported MISSING with the
  # `ship it` remedy — the same false-absence claim as mode 000 on the dir itself, but reachable while the
  # dir is 755. A genuinely-absent chain (§C) must stay rc 1, and this arm's second half proves the fix did
  # not turn "not provisioned yet" into "cannot verify".
  : > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
  : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  chmod 000 "$TMP/home/.pi/agent"
  if [ -x "$TMP/home/.pi/agent" ]; then
    ok "(skipped: this user keeps search permission on a 000 dir — running as root?)"
  else
    run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "an UNSEARCHABLE ANCESTOR → rc 2, not 1 (present files must not be called missing)"
    MISS_AN="$(run --missing 2>/dev/null)"; [ -z "$MISS_AN" ]; ck $? "--missing prints NOTHING when an ancestor is unsearchable"
    run --line | grep -qF 'CANNOT VERIFY'; ck $? "--line says CANNOT VERIFY, and never MISSING, when an ancestor is unsearchable"
  fi
  chmod 755 "$TMP/home/.pi/agent"
  # ⛔ READABLE IS NOT SEARCHABLE — THE ANCESTOR LEG TOO (#3379 review cycle 27, P2, MEASURED). The arm above
  # exercises `chmod 000` on the ancestor, which clears BOTH bits, so it cannot tell `-x` from `-r`: replacing
  # `[ -x "$p" ] || return 0` with `[ -r "$p" ] || return 0` leaves the suite GREEN while an ancestor at
  # `chmod 640` (readable, not searchable — the mode the function's own comment names as realistic: "an
  # ordinary 711 owned by another user", "a dir owned by another user without x") makes both PRESENT files
  # MISSING again, with the `ship it` remedy: the cycle-7/cycle-9 false-absence claim, one bit away.
  : > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
  : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  chmod 640 "$TMP/home/.pi/agent"
  if [ -x "$TMP/home/.pi/agent" ]; then
    ok "(skipped: this user keeps search permission on a 640 dir — running as root?)"
  else
    run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a READABLE-but-UNSEARCHABLE ANCESTOR → rc 2, not 1 (only -x gates resolving a name; a -r-based ancestor leg calls both PRESENT files missing)"
    MISS_ANR="$(run --missing 2>/dev/null)"; [ -z "$MISS_ANR" ]; ck $? "--missing prints NOTHING when an ancestor is readable but unsearchable (no false 'ship it' advice)"
  fi
  chmod 755 "$TMP/home/.pi/agent"
  rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  # …and a state path that is a FILE where a dir belongs is a deployment fault, never an ABSENCE.
  rmdir "$TMP/home/.pi/agent/state" && : > "$TMP/home/.pi/agent/state"
  run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a FILE where the state dir belongs → rc 2, not 1"
  rm -f "$TMP/home/.pi/agent/state"; mkdir -p "$TMP/home/.pi/agent/state"
fi
chmod 755 "$TMP/home/.pi/agent/state"
# …and the SAME distinction inside a READABLE dir: one file present with mode 000. This is the arm the
# first cut of the helper failed — `[ -f ]` alone printed "ok: every mandated file is present" with rc 0
# while the lane could not read it (measured in this change's own review).
mkstate
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
chmod 000 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
if [ -r "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" ]; then
  ok "(skipped: this user can read a 000 file — running as root?)"
else
  run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a present-but-unreadable FILE → rc 2, not 0 (the false-PASS arm)"
  run --missing | grep -qF 'LANE-BRIEF-PREAMBLE.md' && bad "--missing reports an unreadable file as ABSENT (wrong remedy: ship vs chmod)" || ok "--missing does NOT call an unreadable file absent"
  run --line | grep -qF 'UNREADABLE'; ck $? "--line names the unreadable file as UNREADABLE"
  # ⛔ AND `--missing` MUST ANSWER CANNOT-VERIFY, NOT 0-WITH-AN-EMPTY-LIST (#3379 review cycle 27, P2,
  # MEASURED). The arm above only asserts it does not CALL the file absent — which an rc 0 with no output
  # satisfies. Measured on this fixture: `--check` rc 2 naming the path, `--missing` rc 0 printing nothing,
  # so a consumer reading the empty list as "nothing is missing" read a can't-verify box as clean — the
  # same disagreement the occupied-path arm closes for a directory, one state over.
  MISS_UF_ERR="$(run --missing 2>&1 >/dev/null)"; MISS_UF_RC="$(run --missing >/dev/null 2>&1; printf %s $?)"
  [ "$MISS_UF_RC" = "2" ]; ck $? "--missing on a present-but-UNREADABLE file is 2, not 0 with an empty list (measured rc=$MISS_UF_RC; the empty list is a can't-verify claim wearing the healthy answer's clothes)"
  case "$MISS_UF_ERR" in *'CANNOT VERIFY (unreadable)'*'LANE-BRIEF-PREAMBLE.md'*) ok "…and it NAMES the unreadable path on stderr, so the reader knows the remedy is a chmod (the property is the SUBJECT, not the label: an honest 'unreadable' verdict that named nothing stayed green here, measured)" ;; *) bad "--missing did not report the unreadable file AS unreadable and BY PATH (measured rc=$MISS_UF_RC, stderr=[$MISS_UF_ERR]) — a verdict with no subject sends the operator looking for nothing" ;; esac
fi
chmod 644 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" 2>/dev/null
# ⛔ …AND THE THIRD CELL OF THE SAME TABLE: a path OCCUPIED by something that is not a regular file
# (this change's review, P2, measured). `[ -f ]` is false for a directory, so the helper called it ABSENT
# and told the operator to SHIP a file the path cannot hold — while the state-dir arm ONE LEVEL UP already
# treats the same shape as a deployment fault ("exists but is not a directory … must not be answered with
# 'ship the file'"). The remedy here is neither `ship` nor `chmod`: the occupant has to move.
mkstate
: > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
mkdir "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a DIRECTORY where a declared FILE belongs → rc 2 CANNOT VERIFY, not 1 MISSING"
run --check 2>&1 | grep -qF 'not a regular file'; ck $? "…and the verdict NAMES the shape, so the operator knows it is not a deployment"
run --missing | grep -qF 'LANE-BRIEF-PREAMBLE.md' && bad "--missing reports an occupied path as ABSENT (wrong remedy: move the occupant, not ship a file)" || ok "--missing does NOT call an occupied path absent"
run --line | grep -qF 'NOT-A-FILE'; ck $? "--line names it NOT-A-FILE — neither MISSING nor UNREADABLE, each of which prescribes the wrong fix"
# THE CONTROL: the SAME fixture with a regular file must be rc 0, else the arm above passes on a helper that
# answers 2 to everything.
rmdir "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
run --check >/dev/null 2>&1; [ $? -eq 0 ]; ck $? "…and the same fixture with a REGULAR file is rc 0 (the arm above can fail)"

echo "§E BOTH dispatch seams are WIRED — BEHAVIOURALLY, not by grepping their source"
# ⛔ THIS SECTION WAS SOURCE-GREPS AND COULD NOT FAIL (this change's review cycle 2, P1, MEASURED): with
# `merge-one.sh`'s emit wrapped in `if false;` the suite still reported 30/30, and with the marker guard
# disabled it still reported 30/30 while a re-dispatch stacked two blocks into one brief. A gate that
# cannot redden is the class this repo's rig exists to prevent, so E1-E4 DRIVE the behaviour: they call
# the real emit and run the real `run_agent`, and each has a positive control so it cannot pass
# vacuously. E5 keeps SIX source pins (three per seam), but as DRIFT pins — not as the proof the seam works.
# ── E1: the emit appends to the BRIEF, exactly once, and is idempotent ────────────────────────────
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF="$TMP/brief-emit.txt"; printf '# a brief\n' > "$BRIEF"; : > "$TMP/emit.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" first; mandate_preflight_emit "$2" "$3" second' \
  _ "$HELPER" "$TMP/emit.log" "$BRIEF" >/dev/null 2>&1
grep -qF 'mandate-preflight #3377' "$BRIEF"; ck $? "the emit APPENDS the block to the brief (the lane's context)"
[ "$(grep -cF 'mandate-preflight #3377' "$BRIEF")" = "1" ]; ck $? "TWO emits append exactly ONE block (the marker guard is real, not decorative)"
grep -qF '[mandate-preflight]' "$TMP/emit.log"; ck $? "…and the OPERATOR log names it too (both readers are served)"
grep -qF 'second' "$TMP/emit.log"; ck $? "…and the second emit took the already-named branch (idempotence, not a silent skip)"
# ── E1b: the SENTINEL SURVIVES IN THE CANNOT-VERIFY SHAPE — the ONE shape whose marker was absent which
# is the defect this file's header records as MEASURED ("the guard used to key on the MISSING shape's
# prose, so the CANNOT-VERIFY shape carried no marker at all … two emits gave two blocks"). §E1 drives
# only the MISSING shape, so before this arm DELETING the sentinel from the undecidable branch left the
# suite at 50 passed / 0 failed (this change's review, P2, measured) while two emits stacked two blocks
# and zero sentinels — the "gate that cannot redden" class §E's own header names.
mkstate; chmod 000 "$TMP/home/.pi/agent/state"
if [ -x "$TMP/home/.pi/agent/state" ]; then
  ok "(skipped: this user keeps search permission on a 000 state dir — running as root?)"
else
  BRIEF1B="$TMP/brief-cannotverify.txt"; printf '# a brief\n' > "$BRIEF1B"; : > "$TMP/cv.log"
  CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" cv1; mandate_preflight_emit "$2" "$3" cv2' \
    _ "$HELPER" "$TMP/cv.log" "$BRIEF1B" >/dev/null 2>&1
  [ "$(grep -cF 'mandate-preflight #3377' "$BRIEF1B")" = "1" ]; ck $? "CANNOT VERIFY carries the sentinel — exactly ONCE across TWO emits (the measured two-block stacking)"
  [ "$(grep -cF 'CANNOT VERIFY on this box' "$BRIEF1B")" = "1" ]; ck $? "…and exactly ONE cannot-verify block (an unguarded append stacks them)"
  grep -qF 'CANNOT VERIFY' "$BRIEF1B"; ck $? "…and the brief says CANNOT VERIFY, never MISSING (the wrong remedy)"
fi
chmod 755 "$TMP/home/.pi/agent/state"
# ── E1c: the GUARD IS CONTENT-AWARE — a changed box state reaches the brief, in BOTH directions ────
# A brief's block is a reading about BOX STATE, and #1193 is going to change that state. A presence-only
# guard answered "the sentinel is there" as "still true", so (a) a brief stamped for one absence set
# SUPPRESSED a different, real absence discovered later — the #3377 silence, restored by its own guard —
# and (b) a brief stamped while files were missing kept ordering the lane to report a falsehood after the
# box was provisioned. Both were measured on the shipped helper before this arm existed; the policy is
# #2981's (append the current block behind a one-line supersession notice, never rewrite the stale one).
mkstate
STATE="$TMP/home/.pi/agent/state"
: > "$STATE/TORTOISE-GRAPH-BRIEF.md"                 # only the PREAMBLE is missing → stamp
BRIEF1C="$TMP/brief-restate.txt"; printf '# a brief\n' > "$BRIEF1C"; : > "$TMP/restate.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" s1' _ "$HELPER" "$TMP/restate.log" "$BRIEF1C" >/dev/null 2>&1
grep -qF 'LANE-BRIEF-PREAMBLE.md' "$BRIEF1C"; ck $? "E1c fixture: the first state names the missing PREAMBLE (the arm cannot pass vacuously)"
# flip the absence set: provision the preamble, LOSE the graph brief
: > "$STATE/LANE-BRIEF-PREAMBLE.md"; rm -f "$STATE/TORTOISE-GRAPH-BRIEF.md"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" s2' _ "$HELPER" "$TMP/restate.log" "$BRIEF1C" >/dev/null 2>&1
grep -qF 'TORTOISE-GRAPH-BRIEF.md' "$BRIEF1C"; ck $? "a CHANGED absence set is named in the brief — the stale-negative case is not suppressed by the sentinel"
grep -qF 'SUPERSEDES' "$BRIEF1C"; ck $? "…and it is appended behind a SUPERSESSION notice, so the lane cannot read both blocks as true"
[ "$(grep -cF 'mandate-preflight #3377' "$BRIEF1C")" = "2" ]; ck $? "…with exactly TWO sentinels (one per STATE — a per-state block, not per-dispatch noise)"
# and the stale POSITIVE direction: stamped while missing, box then provisioned
touch "$STATE/LANE-BRIEF-PREAMBLE.md" "$STATE/TORTOISE-GRAPH-BRIEF.md"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" s3' _ "$HELPER" "$TMP/restate.log" "$BRIEF1C" >/dev/null 2>&1
grep -qF 'BOTH mandated files are now PRESENT' "$BRIEF1C"; ck $? "a PROVISIONED box retires its stale block loudly — the lane is no longer ordered to report a false absence"
grep -qF 's3' "$TMP/restate.log"; ck $? "…and the operator log records that supersession (it used to record NOTHING)"
# ── E1d: the FLIP-BACK (A → provisioned → A), and the notice's own two failure modes ─────────────−
# The first cut of the content guard compared a SUBSTRING over the whole brief, so block A was still
# "present" from the first stamp and the emit short-circuited — while the LAST thing the brief said was
# "BOTH mandated files are now PRESENT". The lane therefore read a CURRENT, FALSE present claim with no
# correcting block: the stale-negative again, reached through the very transition the guard advertises
# (this change's review, P1, measured). "Current" must mean the brief ENDS with this block.
: > "$STATE/TORTOISE-GRAPH-BRIEF.md"; rm -f "$STATE/LANE-BRIEF-PREAMBLE.md"   # only PREAMBLE missing
BRIEF1D="$TMP/brief-flipback.txt"; printf '# a brief\n' > "$BRIEF1D"; : > "$TMP/flip.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" f1' _ "$HELPER" "$TMP/flip.log" "$BRIEF1D" >/dev/null 2>&1
: > "$STATE/LANE-BRIEF-PREAMBLE.md"                                           # provisioned
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" f2' _ "$HELPER" "$TMP/flip.log" "$BRIEF1D" >/dev/null 2>&1
rm -f "$STATE/LANE-BRIEF-PREAMBLE.md"                                         # THE SAME ABSENCE RETURNS
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" f3' _ "$HELPER" "$TMP/flip.log" "$BRIEF1D" >/dev/null 2>&1
# The brief's LAST claim must be the CURRENT one: a missing-PREAMBLE block, not the earlier "now present"
# notice. Assert on ORDER, not on presence — both strings are in the file, so a substring test would pass
# on the buggy code.
LASTP_CLAIM="$(grep -E 'BOTH mandated files are now PRESENT|MISSING .*LANE-BRIEF-PREAMBLE\.md' "$BRIEF1D" | tail -1)"
case "$LASTP_CLAIM" in *MISSING*LANE-BRIEF-PREAMBLE.md*) ok "the FLIP-BACK re-discloses the absence — the brief's LAST claim is the current missing file, not a stale 'now PRESENT'" ;; *) bad "the FLIP-BACK left the stale 'now PRESENT' notice as the brief's last word (got: $LASTP_CLAIM)" ;; esac
# ⛔ THE NOTICE MUST NAME THE BOX AND HAVE NO EMPTY `()` — the first cut passed ONE argument for TWO `%s`,
# so the hostname split onto its own line and the box name rendered empty.
grep -qF 'on this box ()' "$BRIEF1D" && bad "the supersession notice rendered an EMPTY box name — a printf with more conversions than arguments" || ok "the supersession notice's box name is populated (no empty () )"
# ⛔ AND IT IS IDEMPOTENT: `stamped` never clears, so without a guard every later dispatch appended
# ANOTHER notice (measured: five dispatches on a provisioned box → five notices, brief grown to 2195 B).
touch "$STATE/LANE-BRIEF-PREAMBLE.md" "$STATE/TORTOISE-GRAPH-BRIEF.md"
: > "$TMP/flip2.log"
BEFORE_N="$(grep -cF 'SUPERSEDES' "$BRIEF1D")"
for _i in 1 2 3 4 5; do
  CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" r' _ "$HELPER" "$TMP/flip2.log" "$BRIEF1D" >/dev/null 2>&1
done
AFTER_N="$(grep -cF 'SUPERSEDES' "$BRIEF1D")"
# ONE notice for the STATE TRANSITION (this batch's first emit sees the flip-back's block as the last
# word), and then NOTHING for the four dispatches after it — that is the property: a notice per state
# change, never per dispatch. Asserting an absolute count would have been wrong (a transition is entitled
# to one); asserting growth per dispatch is what the measured defect was.
[ "$AFTER_N" -eq "$((BEFORE_N + 1))" ]; ck $? "a state flip adds ONE notice, and the four dispatches after it add none (before=$BEFORE_N after=$AFTER_N)"
for _i in 1 2 3 4 5; do
  CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" r' _ "$HELPER" "$TMP/flip2.log" "$BRIEF1D" >/dev/null 2>&1
done
FINAL_N="$(grep -cF 'SUPERSEDES' "$BRIEF1D")"
[ "$FINAL_N" -eq "$AFTER_N" ]; ck $? "…and FIVE MORE dispatches on a provisioned box add nothing at all (a reused brief cannot grow without bound)"
# ── E1e: an unwritable LOG must not ABORT a `set -e` caller ──────────────────────────────────────
# This was the file's ONE bare redirection — every neighbour sits inside an `if` — so an unwritable log
# (full disk, read-only dir, a rotated path) made the group non-zero and TERMINATED a caller with
# `errexit` half-way through a dispatch, against the header's sourced-mode promise that sourcing cannot
# abort its caller. That promise is what a future seam author will rely on, so it is pinned here rather
# than left as prose (this change's review, P2, measured: rc=1 and the caller never continued).
mkstate
RO_LOG="$TMP/readonly.log"; : > "$RO_LOG"; chmod 400 "$RO_LOG"
BRIEF1E="$TMP/brief-errexit.txt"; printf '# a brief\n' > "$BRIEF1E"
if [ -w "$RO_LOG" ]; then
  ok "(skipped: this user can write a 400 file — running as root?)"
else
  CELL_HOME="$TMP/home" bash -c 'set -e; . "$1"; mandate_preflight_emit "$2" "$3" errexit; printf REACHED-AFTER-EMIT' \
    _ "$HELPER" "$RO_LOG" "$BRIEF1E" > "$TMP/errexit.out" 2>/dev/null
  ERC=$?
  [ "$ERC" -eq 0 ]; ck $? "an unwritable LOG under a set -e caller: the emit still returns 0 (rc=$ERC)"
  grep -qF 'REACHED-AFTER-EMIT' "$TMP/errexit.out"; ck $? "…and the CALLER kept running past it (the sourced-mode promise, not just the return code)"
fi
chmod 600 "$RO_LOG" 2>/dev/null
# ── E1f: an UNREADABLE BRIEF must not abort a `set -e` caller either — the E1e bug, one argument along ──
# E1e pinned the LOG write. The SAME class sat on `brief_text="$(cat "$prompt" 2>/dev/null)"`: `[ -f ]`
# passes a mode-000 file, the substitution then fails, and a BARE assignment takes ITS status — so the
# caller died at the assignment, before the disclosure was appended AND before the dispatch started, which
# is the very over-block the header forbids (this change's review, P2, measured: rc=1, no
# REACHED-AFTER-EMIT). Pinned behaviourally here, and the sibling renderer assignment that cannot be made
# to fail from a fixture is pinned as a source-drift rule below — because a fix to one line does not cover
# the other, and the next author will meet both.
mkstate
BRIEF1F="$TMP/brief-000.txt"; printf '# a brief\n' > "$BRIEF1F"; chmod 000 "$BRIEF1F"
if [ -r "$BRIEF1F" ]; then
  ok "(skipped: this user can read a 000 brief — running as root?)"
else
  CELL_HOME="$TMP/home" bash -c 'set -e; . "$1"; mandate_preflight_emit "$2" "$3" f; printf REACHED-AFTER-EMIT' \
    _ "$HELPER" "$TMP/errexit-f.log" "$BRIEF1F" > "$TMP/errexit-f.out" 2>/dev/null
  ERC=$?
  [ "$ERC" -eq 0 ]; ck $? "an unreadable BRIEF under a set -e caller: the emit still returns 0 (rc=$ERC)"
  grep -qF 'REACHED-AFTER-EMIT' "$TMP/errexit-f.out"; ck $? "…and the CALLER kept running past it (the abort happened at the assignment, not the log write)"
fi
chmod 600 "$BRIEF1F" 2>/dev/null
# ⛔ EVERY COMMAND-SUBSTITUTION ASSIGNMENT IN THE EMIT CARRIES A GUARD — the drift rule behind E1e/E1f.
# A new `v="$(cmd)"` added later without `|| :` re-opens the abort for whatever data it reads, and E1e/E1f
# would stay GREEN because they drive only the two that exist today. This asserts the CLASS, so the guard
# cannot be lost by adding a third.
# ⛔ THE FIRST CUT OF THIS ARM WAS VACUOUS (this change's review, P2, MEASURED). It matched
# `^\s+[a-z_]+="\$\([^)]*\)"\s*$` — a substitution whose RHS contains NO `)` and which ENDS the line.
# Neither holds for any assignment in the emit: each carries a `)` inside its format string or a nested
# `$( … )`, and the guarded ones end in `|| :`. Measured on the real file: the grep matched ZERO lines
# while SIX assignments existed, THREE of them unguarded — so the arm printed "unguarded: none" about a
# file it had not read, the "gate that cannot redden" class §E's own header names. The predicate below
# anchors only on HOW an assignment starts and on what a GUARDED one ends with, so nesting cannot hide a
# line from it, and it is exercised by a control on each side (below) instead of being trusted.
unguarded_subs() { grep -nE '^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=("|)?\$\(' | grep -vE '\|\|[[:space:]]*:[[:space:]]*$'; }
UNGUARDED="$(awk '/^mandate_preflight_emit\(\)/,/^}/' "$HELPER" | unguarded_subs | sed 's/^/emit+/')"; [ -z "$UNGUARDED" ]; ck $? "every command-substitution assignment in the emit carries a guard against a set -e caller (unguarded:${UNGUARDED:- none})"
# ── E1e-b / E1f-b / E1f-c: EVERY redirect failure is SUPPRESSED and RECORDED, not just swallowed ──────
# E1e and E1f drove the same writes with `2>/dev/null`, so they could not see the defect those writes were
# FIXED for: an ungrouped `printf … >> file` applies redirections left to right, so a failing `>>` writes its
# own `line N: <path>: Permission denied` to the CALLER's stderr before any trailing suppression takes
# effect. Measured in cycle 6: de-grouping any of the emit's three redirects, or deleting its append WARN,
# left 138 passed / 0 failed. Each of the three is now driven with stderr CAPTURED.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF_R="$TMP/brief-444.txt"; printf '# a brief\n' > "$BRIEF_R"; chmod 444 "$BRIEF_R"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" ro444' _ "$HELPER" "$TMP/ro444.log" "$BRIEF_R" >/dev/null 2>"$TMP/ro444.err"
if grep -q 'Permission denied' "$TMP/ro444.err" 2>/dev/null; then
  bad "an UNWRITABLE brief leaked a raw bash error to the caller's stderr — the redirect must be GROUPED so its own failure is suppressible"
else
  ok "an UNWRITABLE brief leaks NOTHING to the caller's stderr (the redirect is grouped with the command)"
fi
grep -qF 'WARN ro444: could not append the mandate block' "$TMP/ro444.log"; ck $? "…and the LOG records that the LANE was NOT told (without it the success and failure paths read identically)"
chmod 644 "$BRIEF_R"
# the SUPERSESSION append: stamp a block on a missing box, provision it, then make the brief unwritable.
BRIEF_S="$TMP/brief-supersede.txt"; printf '# a brief\n' > "$BRIEF_S"; : > "$TMP/sup1.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" sup1' _ "$HELPER" "$TMP/sup1.log" "$BRIEF_S" >/dev/null 2>&1
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
chmod 444 "$BRIEF_S"; : > "$TMP/sup2.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" sup2' _ "$HELPER" "$TMP/sup2.log" "$BRIEF_S" >/dev/null 2>"$TMP/sup2.err"
if grep -q 'Permission denied' "$TMP/sup2.err" 2>/dev/null; then
  bad "the SUPERSESSION append leaked a raw bash error to the caller's stderr — the third grouped redirect, unguarded"
else
  ok "the SUPERSESSION append leaks NOTHING to the caller's stderr either"
fi
grep -qF 'WARN sup2: the brief at' "$TMP/sup2.log"; ck $? "…and it records that the supersession notice could NOT be appended (a stale block the lane would keep reading)"
chmod 644 "$BRIEF_S"
# the LOG write: E1e proved it cannot abort an errexit caller, this proves it cannot leak either.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
LOG_R="$TMP/log-400.log"; : > "$LOG_R"; chmod 400 "$LOG_R"
BRIEF_L="$TMP/brief-log400.txt"; printf '# a brief\n' > "$BRIEF_L"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" log400' _ "$HELPER" "$LOG_R" "$BRIEF_L" >/dev/null 2>"$TMP/log400.err"
if grep -q 'Permission denied' "$TMP/log400.err" 2>/dev/null; then
  bad "an UNWRITABLE log leaked a raw bash error to the caller's stderr — E1e drove this same write with stderr discarded, so it could not see it"
else
  ok "an UNWRITABLE log leaks NOTHING to the caller's stderr (its redirect is grouped too)"
fi
chmod 600 "$LOG_R"
# ── E1g: THE CONTROL — the arm above can REDDEN, and does so on the shapes the vacuous version missed ──
# Three arms, because a one-sided control only proves the predicate is not always-true: a bare assignment
# must be REPORTED, a guarded one must NOT be, and a NESTED/`(`-bearing one — the exact shape the first
# cut could not see — must be REPORTED. Without these, E1f's rule is prose with a passing line next to it.
printf '  v="$(cmd)" || :\n' | unguarded_subs > /dev/null; [ $? -ne 0 ]; ck $? "control: a GUARDED assignment is NOT reported (the predicate is not always-true)"
printf '  v="$(cmd)"\n' | unguarded_subs | grep -q .; ck $? "control: a BARE assignment IS reported (the arm can redden)"
printf '  v="$(printf '\''%%s (%s)'\'' "$(hostname)")"\n' | unguarded_subs | grep -q .; ck $? "control: a NESTED / paren-bearing bare assignment IS reported — the shape the vacuous first cut could not match"
# ⛔ AND THE NAME SHAPE IS NOT JUST LOWERCASE (review cycle 2, P2, MEASURED). The first predicate written
# here anchored on `[a-z_]+`, so an added `MP_NOTICE="$(cmd)"` or `notice2="$(cmd)"` — the ordinary shape
# in the rest of this harness — was invisible and the arm still printed "unguarded: none". Env-style and
# digit-bearing names are now covered, and both are driven below so the hole cannot reopen quietly.
printf '  MP_NOTICE="$(printf x)"\n' | unguarded_subs | grep -q .; ck $? "control: an UPPERCASE assignment name IS reported (a lowercase-only predicate is the same class of hole)"
printf '  notice2="$(printf y)"\n' | unguarded_subs | grep -q .; ck $? "control: a DIGIT-bearing assignment name IS reported"
# ⛔ AND THE QUOTING IS NOT PART OF IT EITHER (review cycle 3, P2, MEASURED): requiring `="$(` meant an
# UNQUOTED `v=$(cmd)` was invisible — and that shape DOES abort an `errexit` caller (`v=$(false)` under
# `set -e` exits 1), which is the failure this arm exists to prevent. (`local x="$(cmd)"` stays out of
# scope on purpose: `local` masks the substitution's status and cannot abort — verified.)
printf '  mp_y=$(printf y)\n' | unguarded_subs | grep -q .; ck $? "control: an UNQUOTED substitution assignment IS reported (quoted-only was the same class of hole)"
printf '  local mp_z="$(printf z)"\n' | unguarded_subs > /dev/null; [ $? -ne 0 ]; ck $? "…and a local-assignment is NOT reported (local masks the status, so it cannot abort a set -e caller)"
# ── E1j: A DECLARATION THAT RENDERS NOTHING IS CANNOT-VERIFY, NEVER "ALL PRESENT" (cycle 2, P1) ──
# Every collector iterates the declaration, so an empty `mandate_files` empties the whole POPULATION: the
# three lists come back empty, the directory is fine, and "nothing is declared" was graded as "everything
# is present" — a false PASS in `--check`, and a "BOTH files are now PRESENT" block as the LAST claim a
# lane reads while both are absent. Measured here by stubbing the declaration (a function override, so no
# fixture is needed). Both surfaces are driven, because they failed independently.
DECL_RC="$(bash -c '. "$1"; mandate_files() { :; }; mandate_verdict >/dev/null 2>&1; printf %s $?' _ "$HELPER")"
[ "$DECL_RC" = "2" ]; ck $? "--check with a declaration that renders NOTHING is CANNOT VERIFY (2), not 0 'all present' (measured rc=$DECL_RC)"
BRIEF1J="$TMP/brief-decl.txt"; printf '# a brief\n' > "$BRIEF1J"
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" declstamp' _ "$HELPER" "$TMP/decl.log" "$BRIEF1J" >/dev/null 2>&1
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; mandate_preflight_emit "$2" "$3" declempty' _ "$HELPER" "$TMP/decl.log" "$BRIEF1J" >/dev/null 2>&1
if grep -qF 'BOTH mandated files are now PRESENT' "$BRIEF1J"; then
  bad "…and an empty DECLARATION still produced the 'now PRESENT' claim on a box where both files are absent"
else
  ok "…and it never claims they are present (an empty population is not a clean one)"
fi
# ── E1h: AN EMPTY NEEDLE MUST NEVER MATCH — the measured `case *""` hole (review P1) ────────────
# `case "$x" in *"")` matches EVERY string. Both of the emit's idempotence tests keyed on a RENDERED
# string, so one failed render meant "the brief already ends with this" about a brief that ends with
# anything at all. Driven directly on the primitive, in both directions, because that is where the bug was.
if bash -c '. "$1"; mandate_ends_with "ANY TEXT AT ALL" ""' _ "$HELPER"; then
  # ⛔ NO BACKTICKS IN THIS MESSAGE (this change's review cycle 3, P2): the first version quoted the
  # measured `case *""` shape in backticks INSIDE a double-quoted string, so bash EXECUTED it — the
  # diagnostic printed a truncated sentence and added `syntax error: unexpected end of file` to the CI log,
  # in an arm whose whole purpose is to teach the next reader about that trap.
  bad "an EMPTY needle counts as a match — a case pattern of *<empty> matches every string, so an unrendered claim reads as 'already stated'"
else
  ok "an EMPTY needle is NOT a match (an unrendered claim is never already stated)"
fi
bash -c '. "$1"; mandate_ends_with "prefix[block]" "[block]"' _ "$HELPER"; ck $? "a real needle at the END still matches (the arm above is not always-false)"
if bash -c '. "$1"; mandate_ends_with "[block] then something else" "[block]"' _ "$HELPER"; then
  bad "an EARLIER block counts as the brief's last statement — only the END may match"
else
  ok "a needle that is NOT at the end does not match (the block must be the brief's LAST statement)"
fi
# ── E1p: THE REASON HALF OF THE DECLARATION (#3379 review cycle 18, P2, MEASURED) ────────────────
# `§F` pins the NAMES half (`mandate_files` is defined exactly once) and nothing looked at the `why` half, so
# replacing `mandate_why`'s lookup with `:` left the suite at 182 passed, 0 failed while all three renderers
# fell back to the generic phrase — silently dropping the actionable part of the disclosure, the part that
# tells an operator WHY the file is mandated. The reasons are prose in the declaration, so they are asserted
# as prose: a distinctive fragment of each spec must reach the rendered block.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
WHY_LINE="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
case "$WHY_LINE" in *"READ §0 and §0b of this file FIRST"*) ok "the MISSING block carries the PREAMBLE's own declared REASON, not a generic phrase (mandate_why is live)" ;; *) bad "the rendered block lost the declared reason for LANE-BRIEF-PREAMBLE.md — mandate_why returned nothing and the disclosure became generic" ;; esac
case "$WHY_LINE" in *"orders a lane to read this BEFORE it derives"*) ok "…and the GRAPH brief's reason too (both specs reach the renderer, so no spec row is dropped)" ;; *) bad "…but the TOURTOISE-GRAPH-BRIEF.md reason never reached the renderer" ;; esac
# The UNREADABLE and NOT-A-FILE renderers take the same argument, so one arm each keeps them honest too.
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; chmod 000 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
WHY_UR="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
chmod 644 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
case "$WHY_UR" in
  *"READ §0 and §0b of this file FIRST"*) ok "…and the UNREADABLE renderer carries the reason as well" ;;
  *UNREADABLE*) bad "the UNREADABLE renderer dropped the reason (mandate_why is not reaching it)" ;;
  # ⛔ A SILENT SKIP IS NOT A VACUITY GUARD (#3379 review cycle 19, P3, MEASURED): this branch used to be
  # `*) : ;;`, which prints and counts NOTHING — so a render that never reached this arm made it DISAPPEAR
  # from the count rather than pass or fail (measured: reverting `mandate_unreadable`'s predicate left 185
  # counted arms instead of 186, and this arm simply gone). Reach is pinned elsewhere (§D reddens), but an
  # arm that can vanish is not an arm. It now fails loudly.
  *) bad "the UNREADABLE render never produced a block at all, so nothing about its reason was tested" ;;
esac
rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; mkdir -p "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
WHY_NF="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
rm -rf "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
case "$WHY_NF" in
  *"READ §0 and §0b of this file FIRST"*) ok "…and the NOT-A-FILE renderer carries it" ;;
  *NOT-A-FILE*) bad "the NOT-A-FILE renderer dropped the reason (mandate_why is not reaching it)" ;;
  *) bad "the NOT-A-FILE render never produced a block at all (an arm that can vanish is not an arm)" ;;
esac

# ── E1t: THE SENTINEL IN THE THIRD SHAPE (#3379 review cycle 25, P2, MEASURED) ──────────────────────
# §E1b pins the sentinel for the UNDECIDABLE shape; the unread-declaration shape added later carried it too and
# nothing checked: deleting that one `printf` left 221/0, and the block became UNRETIRABLE — the emit's
# `stamped` guard can never fire without the marker, so a healed box keeps a false "treat every mandated file
# as unread" as its last mandate claim, silently. ARCHITECTURE.md states the invariant as "ONE sentinel line …
# that every shape carries", so every shape is now checked through the same predicate.
SENT_P="$(bash -c '. "$1"; mandate_sentinel' _ "$HELPER")"
for _shape in unread-decl undecidable; do
  if [ "$_shape" = "unread-decl" ]; then
    _out="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
  else
    _ud="$(mktemp -d)"; mkdir -p "$_ud/.pi/agent/state"; chmod 000 "$_ud/.pi/agent/state"
    _out="$(CELL_HOME="$_ud" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
    chmod 755 "$_ud/.pi/agent/state"; rm -rf "$_ud"
  fi
  [ "$(printf '%s\n' "$_out" | head -1)" = "$SENT_P" ]; ck $? "$_shape: the block's FIRST line is the sentinel (without it the block is unretirable — the stale-positive hole, reopened)"
done

# ── E1q: `--files` EMITS NAMES, NOT `name|reason` (#3379 review cycle 19, P2, MEASURED) ─────────
# The projection `mandate_files | cut -d'|' -f1` was unpinned: reverting it to bare `mandate_files` left
# 186/0 while the verb's output became `LANE-BRIEF-PREAMBLE.md|a dispatch brief may open with …` — a
# documented output shape (`--help`: "the declared names, one per line") silently broken, on the verb whose
# stated consumer PROVISIONS from it. A consumer splitting on the field would create files with prose names.
mkstate
FILES_PROJ="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --files 2>/dev/null' _ "$HELPER")"
case "$FILES_PROJ" in
  *'|'*) bad "--files emitted the declaration's REASON field too — a provisioning consumer would take prose as a filename" ;;
  *) ok "--files emits NAMES ONLY (the projection is pinned; a revert to bare mandate_files used to pass)" ;;
esac
NALIAS="$(printf '%s\n' "$FILES_PROJ" | grep -c '^LANE-BRIEF-PREAMBLE\.md$')"
[ "$NALIAS" = "1" ]; ck $? "--and the first name is exactly LANE-BRIEF-PREAMBLE.md on its own line (measured $NALIAS)"

# ── E1r: TWO CLI CONTRACTS WITH NO ARM (#3379 review cycle 19, P3, MEASURED) ─────────────────────
# `--check`'s MISSING tag and the unknown-argument rc are both documented contracts and neither was tested:
# reverting `mandate_missing | sed 's|^|[mandate-preflight] MISSING |'` to bare `mandate_missing` left 186/0
# (bare paths on stderr, breaking the file's own "every line is tagged" contract), and `return 78` → `return 1`
# for an unknown verb also stayed green.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
CHECK_ERR="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --check 2>&1 >/dev/null' _ "$HELPER")"
case "$CHECK_ERR" in *'[mandate-preflight] MISSING'*) ok "--check TAGS each missing path on stderr (the log contract; an untagged bare path used to pass)" ;; *) bad "--check wrote an UNTAGGED path to stderr — the line is not identifiable as a mandate reading" ;; esac
bash "$HELPER" --bogus-verb >/dev/null 2>&1; BOGUS_RC=$?
[ "$BOGUS_RC" = "78" ]; ck $? "an UNKNOWN argument answers 78, the repo's config-error convention (measured rc=$BOGUS_RC; \`return 1\` used to pass)"

# ── E1s: THE OTHER TWO `--check` TAGS, AND THE NAME OF THE ROOT IT READ (#3379 review cycle 20, P2/P3) ─
# Cycle 19 pinned the MISSING tag one `elif` away and left its two siblings — the tags on the state this whole
# file exists to distinguish ("ABSENT is not UNREADABLE"). Measured: dropping the UNREADABLE tag (bare absolute
# paths on stderr) and dropping the NOT-A-FILE tag both left 190/0, and reducing the success line to a bare
# `ok` did too — so a healthy run no longer named WHICH state dir it read, which is the surface of the earlier
# "a wrong root reported as fact" P1.
mkstate; : > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
OK_ERR="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --check 2>&1' _ "$HELPER")"
case "$OK_ERR" in *"[mandate-preflight] ok: every mandated file is present under $TMP/home/.pi/agent/state"*) ok "a HEALTHY --check names the state dir it read (a bare 'ok' would hide a wrong root)" ;; *) bad "a healthy --check did not name the state dir it read: $OK_ERR" ;; esac
chmod 000 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
UR_ERR="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --check 2>&1 >/dev/null' _ "$HELPER")"
chmod 644 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
case "$UR_ERR" in *'[mandate-preflight] CANNOT VERIFY (unreadable)'*) ok "--check TAGS the UNREADABLE path (its MISSING sibling was pinned one elif away and this was not)" ;; *) bad "--check wrote an UNTAGGED unreadable path to stderr: $UR_ERR" ;; esac
rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; mkdir -p "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
NF_ERR="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --check 2>&1 >/dev/null' _ "$HELPER")"
rm -rf "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
case "$NF_ERR" in *'[mandate-preflight] CANNOT VERIFY (not a regular file)'*) ok "--check TAGS the OCCUPIED path too (all three can't-verify tags now carry an identification)" ;; *) bad "--check wrote an UNTAGGED occupied-path line to stderr: $NF_ERR" ;; esac

# ── E1i: A RENDER THAT PRODUCES NOTHING MUST NOT READ AS "EVERY FILE PRESENT" (review P1) ─────────
# The disclosure is rendered into `line`; when that render fails the OLD code took the empty result as
# "nothing to declare" and — if a second read also failed — appended "BOTH mandated files are now PRESENT"
# to a brief on a box where they are missing, i.e. #3377's false claim restored inside the fix.
# ⛔ THE ARMS BELOW WERE DECORATION FOR THAT P1 AND THE PROPERTY IS COVERED BY E1i-b (this change's review,
# P2, MEASURED): they stubbed only `mandate_preflight_line`, while `mandate_missing` still returned both
# paths, so the OLD code reached CANNOT VERIFY too and every assertion stayed GREEN under a revert of the
# `healthy` determination (measured: 101 passed, the single red being E1j's declaration arm). What they do
# falsify is narrower and still worth having: a render failure on a box whose verdict IS decidable must not
# be answered with a present claim. The P1's actual mechanism — BOTH reads failing for the SAME cause — is
# E1i-b's subject, and it is the arm that reddens.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF1I="$TMP/brief-renderfail.txt"; printf '# a brief\n' > "$BRIEF1I"
# ⛔ THE FIXTURE MUST BE STAMPED FIRST (MEASURED while writing this arm): on a FRESH brief the emit returns
# early at `[ -n "$stamped" ] || return 0`, so a failed render appends nothing and the false-present branch
# is never reached — the arm passed for the wrong reason and could not redden. The state that actually
# produces the false claim is a brief that ALREADY carries a mandate block and whose box is still bad.
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" stamp' _ "$HELPER" "$TMP/renderfail.log" "$BRIEF1I" >/dev/null 2>&1
grep -qF 'MISSING' "$BRIEF1I"; ck $? "E1i fixture: the brief is STAMPED with a real MISSING block before the failing render (the arm below needs that state)"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_line() { return 1; }; mandate_preflight_emit "$2" "$3" renderfail' \
  _ "$HELPER" "$TMP/renderfail.log" "$BRIEF1I" >/dev/null 2>&1
grep -qF 'CANNOT VERIFY' "$BRIEF1I"; ck $? "a render that produces NOTHING while the box is bad still tells the LANE it cannot verify"
if grep -qF 'BOTH mandated files are now PRESENT' "$BRIEF1I"; then
  bad "…but it ALSO claimed both files are now PRESENT while they are missing — a false claim is worse than the silence it replaced"
else
  ok "…and it does NOT claim they are present (the false-present branch is unreachable from a failed render)"
fi
# ── E1i-b: BOTH READS FAIL FOR THE SAME CAUSE — the P1's actual mechanism, and the ONLY arm that reddens
# on it (this change's review, P2, MEASURED). A state dir with no search bit empties the render AND every
# second-read verb at once (they short-circuit to nothing), so "the render failed" and "the state reads
# clean" become the SAME observation — and the OLD shape answered that with a present claim. The stub
# supplies the empty render (the failure the dir causes), the chmod supplies the genuinely-failed re-read;
# a revert that drops the `! mandate_state_root_undecidable` guard turns this arm RED (measured on that
# mutant: it is the only arm that does, which is why E1i alone could not carry the P1).
UD="$(mktemp -d)"; mkdir -p "$UD/.pi/agent/state"
: > "$UD/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$UD/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF1IB="$TMP/brief-undecidable.txt"; printf '# a brief\n' > "$BRIEF1IB"
CELL_HOME="$UD" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" stamp' _ "$HELPER" "$TMP/undec.log" "$BRIEF1IB" >/dev/null 2>&1
chmod 000 "$UD/.pi/agent/state"
CELL_HOME="$UD" bash -c '. "$1"; mandate_preflight_line() { :; }; mandate_preflight_emit "$2" "$3" undecidable' \
  _ "$HELPER" "$TMP/undec.log" "$BRIEF1IB" >/dev/null 2>&1
chmod 755 "$UD/.pi/agent/state"; rm -rf "$UD"
grep -qF 'CANNOT VERIFY' "$BRIEF1IB"; ck $? "E1i-b: an empty render on an UNDECIDABLE box still says CANNOT VERIFY (dropping the undecidable guard reddens THIS arm)"
if grep -qF 'BOTH mandated files are now PRESENT' "$BRIEF1IB"; then
  bad "…and an undecidable box is NOT answered with a present claim (this is #3377's own false claim, restored inside the fix)"
else
  ok "…and an undecidable box is never answered with a present claim"
fi
# The last-resort literal must carry the ONE sentinel, or the block stops being idempotent on that path.
grep -qF "line='$(bash -c '. "$1"; mandate_sentinel' _ "$HELPER")" "$HELPER"; ck $? "the last-resort literal's first line IS mandate_sentinel's value (the ONE marker cannot drift into two)"
# ── E1k: NO BASE TO NAME IS CANNOT-VERIFY, AND `--missing` IS NEVER AN EMPTY LIST (cycle 3, P1/P2) ──
# `"${CELL_HOME:-${HOME:-}}"` with BOTH unset is the EMPTY STRING, so the root became `/.pi/agent/state` — a
# path no box reads — and `--check` answered MISSING for two files under `/`, `--line` rendered a full
# MANDATE-UNSATISFIABLE block, and the emit appended it to the dispatched lane's brief as its LAST
# instruction. Measured below with `env -u HOME -u CELL_HOME`, which is the reachable state
# (`spawn-gate.sh` handles "neither is set" a few blocks above the same emit).
NOBASE_RC="$(env -u HOME -u CELL_HOME bash "$HELPER" --check >/dev/null 2>&1; printf %s $?)"
[ "$NOBASE_RC" = "2" ]; ck $? "no base to name (CELL_HOME and HOME both unset) → --check is CANNOT VERIFY (2), not 0 or 1 (measured rc=$NOBASE_RC)"
NOBASE_LINE="$(env -u HOME -u CELL_HOME bash "$HELPER" --line 2>/dev/null)"
case "$NOBASE_LINE" in *'MISSING'*) bad "…and --line calls the files MISSING under a path that exists nowhere (the wrong remedy, delivered as the brief's last word)" ;; *) ok "…and --line never calls them MISSING when there is no base to look under" ;; esac
case "$NOBASE_LINE" in *'CANNOT VERIFY'*) ok "…and it says CANNOT VERIFY instead (the only truthful verdict)" ;; *) bad "…but --line did not say CANNOT VERIFY either" ;; esac
# --missing: an UNKNOWN state must not look like the empty list that means "nothing missing".
MISS_UNDEC_RC="$(T=$(mktemp -d); mkdir -p "$T/.pi/agent/state"; chmod 000 "$T/.pi/agent/state"; CELL_HOME="$T" bash "$HELPER" --missing >/dev/null 2>&1; _r=$?; chmod 755 "$T/.pi/agent/state"; rm -rf "$T"; printf %s "$_r")"
[ "$MISS_UNDEC_RC" = "2" ]; ck $? "--missing on an UNRESOLVABLE state dir is 2, not 0-with-empty-output (a consumer reading 0 as 'all present' was reading unknown as clean; measured rc=$MISS_UNDEC_RC)"
# ── E1k-b: A SET-BUT-EMPTY `CELL_HOME` FALLS BACK TO `HOME` (#3379 review cycle 27, P2, MEASURED) ─────
# The fixture above covers `CELL_HOME` UNSET, never SET-AND-EMPTY — the state the cycle-3 P1 was about
# (`/.pi/agent/state`). `${CELL_HOME:-${HOME:-}}` falls back on an empty value; the one-character revert to
# `${CELL_HOME-${HOME:-}}` leaves the suite green and emits a sentence that is FALSE on that box ("neither
# CELL_HOME nor HOME is set") plus the wrong remedy (an environment fix, where the truth is "ship the file").
mkstate
SE_RC="$(CELL_HOME= HOME="$TMP/home" bash "$HELPER" --check >/dev/null 2>&1; printf %s $?)"
[ "$SE_RC" = "1" ]; ck $? "a SET-BUT-EMPTY CELL_HOME falls back to HOME → rc 1 MISSING (measured rc=$SE_RC; \${CELL_HOME-…} makes it rc 2 with an untrue 'neither is set' sentence)"
SE_LINE="$(CELL_HOME= HOME="$TMP/home" bash "$HELPER" --line 2>/dev/null)"
case "$SE_LINE" in *'neither CELL_HOME nor HOME is set'*) bad "…and with HOME set it still claims NEITHER is set (a wrong diagnosis, and the remedy it prints is an environment fix for a box that needs a deployment)" ;; *) ok "…and it never claims both are unset when HOME is set" ;; esac
# ── E1l: AN ANCESTOR THAT IS NOT A DIRECTORY IS UNDECIDABLE TOO (cycle 4, P2, MEASURED) ─────────══
# The walk tested only the EXECUTE bit, never `-d`, so an ancestor that exists, is executable, and is a
# FILE was graded decidable — and the answer was `MISSING … ship the file` for a path that can never exist.
# That is the function's own leg (d) ("a file where a dir belongs — a deployment fault, not an absence")
# applied at the exact root and forgotten one level up.
ANC=$(mktemp -d); : > "$ANC/.pi"; chmod 755 "$ANC/.pi"
ANC_RC="$(CELL_HOME="$ANC" bash "$HELPER" --check >/dev/null 2>&1; printf %s $?)"
[ "$ANC_RC" = "2" ]; ck $? "an ANCESTOR that is a non-directory → CANNOT VERIFY (2), not 1 'MISSING' with the ship-the-file remedy (measured rc=$ANC_RC)"
case "$(CELL_HOME="$ANC" bash "$HELPER" --line 2>/dev/null)" in *'MISSING'*) bad "…and --line calls the files MISSING through a non-directory ancestor (wrong remedy)" ;; *) ok "…and --line never calls them MISSING through it" ;; esac
rm -rf "$ANC"
# ── E1m: AN OCCUPIED PATH IS CANNOT-VERIFY FOR `--missing` TOO (#3379 review, P2, MEASURED) ──────
# `mandate_missing` deliberately SKIPS a path that exists (a directory where a declared file belongs is a
# deployment fault whose remedy is `mv`, not `ship the file`), so on that box `--missing` answered 0 with a
# list that silently OMITTED the occupied path while `--check` said CANNOT VERIFY about the SAME box: a
# consumer reading the list as "what to ship" never saw the one path needing another remedy, and rc 0 read
# as "nothing absent". Same doctrine as the undecidable arm above — a cannot-verify is never an empty or
# quietly short list — applied one arm over.
OCC=$(mktemp -d); mkdir -p "$OCC/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
OCC_MISS_RC="$(CELL_HOME="$OCC" bash "$HELPER" --missing >/dev/null 2>&1; printf %s $?)"
[ "$OCC_MISS_RC" = "2" ]; ck $? "a path OCCUPIED by a directory → --missing is 2, not 0 with a silently short list (measured rc=$OCC_MISS_RC)"
OCC_MSG="$(CELL_HOME="$OCC" bash "$HELPER" --missing 2>&1 >/dev/null)"
case "$OCC_MSG" in *'CANNOT VERIFY'*) ok "…and it SAYS cannot-verify on stderr instead of leaving the occupied path out of the list" ;; *) bad "…but --missing said nothing about the occupied path (it is absent from the list AND from stderr)" ;; esac
OCC_CHECK_RC="$(CELL_HOME="$OCC" bash "$HELPER" --check >/dev/null 2>&1; printf %s $?)"
[ "$OCC_CHECK_RC" = "2" ]; ck $? "…and --check agrees on the same box, so the two verbs cannot disagree about it"
rm -rf "$OCC"
# ── E1m-b: …AND THE *DECLARATION* ARM OF THE SAME VERB (#3379 review cycle 5, P2, MEASURED) ──────
# Every collector iterates the declaration, so a declaration that renders NOTHING empties the whole
# POPULATION: `--check` and the emit answered CANNOT VERIFY (cycle 2's P1) while `--missing` answered rc 0
# with an EMPTY list — "nothing is missing" about a set nobody looked for — on the same box. Driven with
# the same function override §E1j uses, so the state needs no fixture and cannot drift from it.
DECL_MISS_RC="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --missing >/dev/null 2>&1; printf %s $?' _ "$HELPER")"
[ "$DECL_MISS_RC" = "2" ]; ck $? "a declaration that renders NOTHING → --missing is 2, not 0 with an empty list (measured rc=$DECL_MISS_RC)"
DECL_CHECK_RC="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; mandate_verdict >/dev/null 2>&1; printf %s $?' _ "$HELPER")"
[ "$DECL_CHECK_RC" = "2" ]; ck $? "…and --check agrees about that box, so no consumer can read one verb as clean while the other says cannot-verify"
DECL_MISS_MSG="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --missing 2>&1 >/dev/null' _ "$HELPER")"
case "$DECL_MISS_MSG" in *'CANNOT VERIFY'*) ok "…and --missing SAYS cannot-verify on stderr (silence was the defect)" ;; *) bad "…but --missing said nothing while answering 0 on an unread declaration" ;; esac
# ── E1n: `--line` CANNOT CALL AN UNREAD DECLARATION "NOTHING TO DISCLOSE" (#3379 review cycle 6, P1) ──
# The third surface of the state cycles 2 and 5 each fixed one of. `mandate_preflight_line` tested the dir
# and then the three collectors, all of which iterate `$(mandate_files)`, so an empty declaration emptied
# the population and the renderer returned EMPTY at rc 0 — this tool's own word for "every mandated file is
# present" — on the surface a LANE actually reads. The emit survived only because its `healthy` gate
# re-reads the state, i.e. the fix lived in the caller. Reachable without a stub: a truncated `$O` copy
# that lost the two `name|reason` SPEC lines parses fine and answers this.
DECL_LINE_OUT="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
case "$DECL_LINE_OUT" in
  *'CANNOT VERIFY'*) ok "an unread declaration → --line renders a CANNOT VERIFY block, not an empty string (which IS the "all present" answer)" ;;
  *) bad "…but --line rendered nothing for a declaration that names no files — the block a lane reads reads as CLEAN" ;;
esac
DECL_DEF_OUT="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli "" 2>/dev/null' _ "$HELPER")"
case "$DECL_DEF_OUT" in *'CANNOT VERIFY'*) ok "…and the NO-ARG default action agrees (same renderer, so the two cannot drift)" ;; *) bad "…but the no-arg default action still rendered empty on an unread declaration" ;; esac
case "$DECL_LINE_OUT" in *'MISSING'*) bad "…and it must NOT tell the operator to ship files on a box whose declaration could not be read" ;; *) ok "…and it never calls the files MISSING (the remedy is a complete helper, not a deployment)" ;; esac
# ── E1o: THE FOURTH SURFACE — `--files` (#3379 review cycle 8, P2, MEASURED) ─────────────────────
# Cycles 2, 5 and 7 each closed this state on ONE verb and left the next one open: `--check`, then
# `--missing`, then `--line`. `--files` was the last, and it was unguarded and untested — `grep -c -- '--files'
# mandate-preflight.test.sh` was 0 — so it rendered ZERO BYTES at rc 0 for a declaration that names nothing,
# which is byte-for-byte the healthy answer. A consumer that PROVISIONS from this list provisions nothing,
# silently: #3377's silence reached through the helper written to end it. Each arm below is paired with a
# POSITIVE control, or a helper that always answers 2 would pass it.
DECL_FILES_RC="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --files >/dev/null 2>&1; printf %s $?' _ "$HELPER")"
[ "$DECL_FILES_RC" = "2" ]; ck $? "an unread declaration → --files is 2, not 0 with an empty list (measured rc=$DECL_FILES_RC)"
DECL_FILES_MSG="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --files 2>&1 >/dev/null' _ "$HELPER")"
case "$DECL_FILES_MSG" in *'CANNOT VERIFY'*) ok "…and --files SAYS cannot-verify on stderr (silence was the defect)" ;; *) bad "…but --files said nothing while answering 0 on an unread declaration" ;; esac
DECL_FILES_OUT="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; _mandate_cli --files 2>/dev/null' _ "$HELPER")"
[ -z "$DECL_FILES_OUT" ]; ck $? "…and it emits NOTHING on stdout, so a consumer cannot mistake the failure for a short list either"
mkstate
FILES_OK="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --files 2>/dev/null' _ "$HELPER")"
[ "$(printf '%s\n' "$FILES_OK" | grep -c .)" = "2" ]; ck $? "POSITIVE CONTROL: a readable declaration still lists both names at rc 0 ($(printf '%s\n' "$FILES_OK" | grep -c .) names) — the guard is not always-2"
# ⛔ THE NAMES ARE STATIC, SO AN UNRESOLVABLE STATE DIR MUST NOT BLOCK THEM (#3379 review cycle 9, P2,
# MEASURED). This verb's first version also answered 2 when the state dir could not be resolved, on the
# claim that the names "cannot be enumerated" — false: `mandate_files` is a here-doc that reads no box state
# and renders both lines (336 bytes) in exactly that state. So the guard refused a service the tool
# delivers, fail-closed, with no exercise behind it. This arm is what keeps that over-block from returning:
# a box whose state dir is unreadable still gets its declared names.
UD2="$(mktemp -d)"; mkdir -p "$UD2/.pi/agent/state"; chmod 000 "$UD2/.pi/agent/state"
FILES_UD="$(CELL_HOME="$UD2" bash -c '. "$1"; _mandate_cli --files 2>/dev/null' _ "$HELPER"; printf 'rc=%s' $?)"
chmod 755 "$UD2/.pi/agent/state"; rm -rf "$UD2"
case "$FILES_UD" in
  *LANE-BRIEF-PREAMBLE.md*TORTOISE-GRAPH-BRIEF.md*'rc=0'*) ok "an UNRESOLVABLE state dir still yields the declared names at rc 0 — the names are static, and a presence question is not this verb's to answer" ;;
  *) bad "--files withheld the declared names on a box whose STATE DIR is unreadable — an over-block: the list is static and knowable ($(printf '%s' "$FILES_UD" | tr '\n' ' '))" ;;
esac
# ⛔ `--help` IS THE CONTRACT AN OPERATOR READS, AND IT WAS INVISIBLE TO THIS SUITE (review cycle 10, P2,
# MEASURED): `grep -c 'usage:' mandate-preflight.test.sh` was 0, so cycle 9's own fix — which existed to
# remove an untrue sentence from BOTH the comment and the `--help` — could be reverted on the `--help` half
# and stay at 151 passed, 0 failed. The comment half is inert; the help half is what tells a consumer what
# rc 2 means. Both halves are pinned: the true sentence must be there, and the false one must not.
HELP_OUT="$(bash "$HELPER" --help 2>&1)"
case "$HELP_OUT" in *'the names are static'*) ok "--help states WHY --files can answer 2 (the declaration renders no names) — the true contract, not the withdrawn over-block" ;; *) bad "--help no longer explains when --files answers 2 — revertible prose with no red" ;; esac
# ⛔ THE NEGATIVE HALF WAS ITSELF UNFALSIFIABLE (review cycle 11, P1, MEASURED): its alternatives were a token
# that appears NOWHERE (`error_state_dir`) and a pattern with a LITERAL `…` where a wildcard was meant, which
# matched neither the withdrawn sentence nor anything else — so restoring that sentence as an extra `--files`
# help line left 158 passed, 0 failed. It now anchors on the real phrase from `git show 2a94471c` ("an unread
# declaration or an unresolvable state dir renders no names"), which the current true sentence does not contain.
case "$HELP_OUT" in *'unresolvable state dir renders no names'*) bad "--help still claims the withdrawn over-block (an unresolvable state dir does not block the names)" ;; *) ok "…and it does NOT claim the withdrawn over-block (anchored on the real withdrawn phrase, not a fabricated token)" ;; esac
# ⛔ THE SAME SURFACE ON THE LINE THE `--missing` FIX EDITED (#3379 review cycle 28, P2, MEASURED): that
# commit added a NEW rc-2 cause to the operator-facing contract (a declared file that exists but cannot be
# read) and no arm covered the sentence — reverting the help line to its pre-fix wording left the suite at
# 242 passed, 0 failed. Cycle 10's finding verbatim, one line over: an operator reading the reverted help goes
# hunting for a directory fault when the real cause is a `chmod`.
case "$HELP_OUT" in *'a declared file that exists but cannot be read'*) ok "--help documents the UNREADABLE cause of --missing's rc 2 (the contract this diff changed, pinned)" ;; *) bad "--help no longer documents that --missing answers 2 for a file that exists but cannot be read — the one cause this diff added to the contract" ;; esac
# ⛔ THE THREE COLLECTORS ARE LISTS, NOT VERDICTS (review cycle 10, P2, MEASURED): each iterates the
# declaration, so an unread declaration makes all three print nothing at rc 0 — the same false-clean the
# guarded verbs answer 2 for. Driven directly, the way a future sourced consumer would call them.
for _coll in mandate_missing mandate_unreadable mandate_irregular; do
  _coll_out="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_files() { :; }; '"$_coll"' 2>/dev/null' _ "$HELPER")"
  [ -z "$_coll_out" ]; ck $? "$_coll answers NOTHING for an unread declaration (the contract in this file's header: meaningful only behind mandate_declaration_readable; the VERDICT is the guarded verbs' job)"
done
# ⛔ …AND THEY STILL WORK BEHIND IT (the positive control, or a collector that always returned nothing passes).
mkstate
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
MISS_OK="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_missing' _ "$HELPER")"
[ "$(printf '%s\n' "$MISS_OK" | grep -c .)" = "1" ]; ck $? "POSITIVE CONTROL: with a readable declaration and the preamble present, mandate_missing names exactly the ONE absent file (measured $(printf '%s\n' "$MISS_OK" | grep -c .)) — the collector is not disabled"
MISS_ONE="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_missing' _ "$HELPER" | grep -c 'TORTOISE-GRAPH-BRIEF')"
[ "$MISS_ONE" = "1" ]; ck $? "…and it names the file that IS missing (so the collector was not disabled)"
# ── E1p: the `--log`-ONLY path SAYS the lane will not see it (the un-pinned WARN) ───────────────────
# Both in-tree seams always pass an existing brief, so this branch is defensive-only — but under a
# `--log`-only invocation a silent success and "the lane was never told" read identically, which is the
# class its two sibling WARNs (`could not append`, `still carries a STALE block`) are each pinned for.
# Measured: deleting this WARN left the suite green.
mkstate; rm -f "$TMP/home/.pi/agent/state/"*.md
: > "$TMP/nobrief.log"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" nobrief' _ "$HELPER" "$TMP/nobrief.log" "$TMP/no-such-brief.txt" >/dev/null 2>&1
grep -qF 'WARN nobrief: no brief file to append to' "$TMP/nobrief.log"; ck $? "a MISSING brief is recorded, not silently skipped (under --log-only the two read identically)"
grep -qF 'the LANE will not see it' "$TMP/nobrief.log"; ck $? "…and the record says the LANE will not see it, not merely that a path was absent"
# ── E2: THE POSITIVE CONTROL — with every file present the brief is NOT touched ───────────────────
# Without this arm E1 passes vacuously on a helper that always appends.
mkstate
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
: > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF2="$TMP/brief-clean.txt"; printf '# a brief\n' > "$BRIEF2"; BEFORE="$(cksum < "$BRIEF2")"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" clean' _ "$HELPER" "$TMP/emit2.log" "$BRIEF2" >/dev/null 2>&1
[ "$(cksum < "$BRIEF2")" = "$BEFORE" ]; ck $? "all files present → the brief is BYTE-FOR-BYTE untouched (E1 can fail)"
# ── E3: the REAL `run_agent` appends the block to the brief it is about to launch ────────────────
# A stub `pi` on PATH — the pattern spawn-gate.test.sh §drive uses: every assertion is on whether the
# agent RAN and what the seam WROTE, never on a model. `KIND=reviewer` is the harness's OWN seam for
# "this spawn's product is the drain" (`fixer|reviewer` skip the creation back-pressure gate, #2409);
# without it the fixture's fake GitHub slug makes that gate refuse 74 on an unreadable gh read, which is
# a different subject entirely.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "STUB-PI-RAN $*" >> "$PI_LOG"\nexit 0\n' > "$TMP/bin/pi"
chmod +x "$TMP/bin/pi"
# ⛔ THE SEAM IS DRIVEN IN THIS REAL CHECKOUT, NOT IN A FIXTURE REPO (lesson from running this suite
# through an agent harness): the working-tree guard refuses to execute a file whose body contains a git
# command at a command position, or a nested script invocation under a variable path, when it cannot
# statically resolve them — so the guard once refused to run the very suite that proves the disclosure
# works: a test nobody can run. The checkout is already a git repository, so `run_agent` needs no fixture,
# and the brief below is written statically for the same reason.
FIXREPO="$(cd "$HERE/../.." && pwd)"
BRIEF3="$TMP/brief-seam.txt"
seam_brief "$BRIEF3"
rm -rf "$TMP/home2"; mkdir -p "$TMP/home2/.pi/agent/state"
: > "$TMP/seam.log"
E3_MARK="$FAIL"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran.log" O="$TMP/O" CELL_HOME="$TMP/home2" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; run_agent 5 "$3" "$4" seamtest; echo "run_agent_rc=$?"' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam.log" "$BRIEF3" >"$TMP/seam.out" 2>"$TMP/seam.err"
grep -qF 'mandate-preflight #3377' "$BRIEF3"; ck $? "run_agent APPENDS the block to the brief it launches (a missing mandate is named to the LANE)"
grep -qF '[mandate-preflight]' "$TMP/seam.log"; ck $? "…and writes it to the operator log"
grep -qF 'STUB-PI-RAN' "$TMP/pi-ran.log" 2>/dev/null; ck $? "…and the agent STILL STARTED (the disclosure never blocks the dispatch)"
# ⛔ THE ARM ABOVE IS SATISFIED BY THE CAPABILITY PROBE TOO (this change's review, P2, measured):
# `run_agent`'s `cell-lane-preflight.sh` invokes `pi -p …` ITSELF, through the same PATH stub and the same
# PI_LOG, so a refusal between the mandate emit and the launch would still leave `STUB-PI-RAN` present.
# Two arms make it launch-specific: the launch is the only invocation carrying the BRIEF in argv
# (`pi -p … "$(cat "$prompt")"`), and `LANE_PREFLIGHT=0` above keeps the probe out of the population so
# the count is exactly one.
grep -qF 'RESEARCH FIRST' "$TMP/pi-ran.log" 2>/dev/null; ck $? "…and that invocation is the LAUNCH (it carries the brief in argv, which the probe never does)"
[ "$(grep -cF 'STUB-PI-RAN' "$TMP/pi-ran.log" 2>/dev/null)" = "1" ]; ck $? "…and it is the ONLY stub invocation (LANE_PREFLIGHT=0 keeps the probe out; a probe-satisfied arm cannot pass this)"
# ⛔ THE BLOCK MUST BE IN THE **LAUNCHED ARGV**, NOT ONLY IN THE FILE (this change's review cycle 4, P1,
# MEASURED). The arms above prove the FILE was stamped and that a launch happened — nothing tied the two,
# so reading the brief into a variable BEFORE the emit and launching from that variable leaves the file
# stamped, the log correct, `RESEARCH FIRST` in argv and exactly one invocation: 97 passed, 0 failed, while
# the block never reached the lane's context. That is precisely the log-only disclosure #3377 exists to
# end ("the lane's context is the file `pi` reads"), and it is the half the change is FOR.
grep -qF 'mandate-preflight #3377' "$TMP/pi-ran.log" 2>/dev/null; ck $? "…and the block is in the LAUNCHED ARGV — the lane's own context, not only the brief file (a read-before-emit refactor cannot pass this)"
# DIAGNOSTICS: when a seam arm fails, print what the seam actually wrote — an assertion that only says
# "not found" sends the next reader to re-run the suite by hand, which is the friction this avoids.
if [ "$FAIL" -gt "$E3_MARK" ]; then
  printf '%s\n' "--- run_agent log ($TMP/seam.log) ---"; tail -30 "$TMP/seam.log" 2>/dev/null
  printf '%s\n' "--- stub pi log ---"; cat "$TMP/pi-ran.log" 2>/dev/null || printf '%s\n' "(no pi run)"
  printf '%s\n' "--- stdout ---"; tail -10 "$TMP/seam.out" 2>/dev/null
  printf '%s\n' "--- stderr ---"; tail -10 "$TMP/seam.err" 2>/dev/null
fi
# ── E3b: THE DEGRADED BRANCH'S BRIEF APPEND IS BRANCHED ON, NOT LEAKED (#3379 review, P2, MEASURED) ──
# The un-provisioned box takes the `CANNOT VERIFY` branch, whose whole point is that the LANE is told. An
# ungrouped `printf … >> "$prompt"` on an UNWRITABLE brief emits its own `line N: <path>: Permission denied`
# to the CALLER's stderr (a trailing `2>/dev/null` cannot retract it) and nothing recorded that the append
# failed — the log line above read identically either way. Driven through the REAL `run_agent` with the
# resolver forced to fail (`mandate_preflight_lib() { return 1; }`, the reviewer's own instrument) and a
# mode-444 brief, so the branch under test is the one an un-provisioned box takes.
BRIEF3B="$TMP/brief-degraded.txt"; seam_brief "$BRIEF3B"; chmod 444 "$BRIEF3B"
BEFORE3B="$(cksum < "$BRIEF3B")"; : > "$TMP/seam3b.log"; rm -f "$TMP/pi-ran3b.log"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3b.log" O="$TMP/O" CELL_HOME="$TMP/home2" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; mandate_preflight_lib() { return 1; }; run_agent 5 "$3" "$4" degraded; echo "run_agent_rc=$?"' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3b.log" "$BRIEF3B" >"$TMP/seam3b.out" 2>"$TMP/seam3b.err"
[ "$(cksum < "$BRIEF3B")" = "$BEFORE3B" ]; ck $? "a READ-ONLY brief on the degraded branch is left untouched (the append cannot land — so the arm is measuring the FAILURE path)"
grep -qF 'WARN degraded: could not append the degraded notice' "$TMP/seam3b.log"; ck $? "…and the LOG records that the LANE was NOT told (without it the CANNOT VERIFY line reads identically on success and failure)"
if grep -q 'Permission denied' "$TMP/seam3b.err"; then
  bad "…but a raw bash error escaped to the caller's stderr — the untagged redirect leak, which is what the grouped form prevents"
else
  ok "…and no raw bash error escaped to the caller's stderr (the redirect is GROUPED, so its failure is suppressible)"
fi
grep -qF 'STUB-PI-RAN' "$TMP/pi-ran3b.log" 2>/dev/null; ck $? "…and the agent STILL STARTED (a failed disclosure is never a gate)"
chmod 644 "$BRIEF3B"
# ── E3c: THE DEGRADED NOTICE IS RETIRABLE — a healed box must not keep a false instruction (#3379 P1) ──
# The emit retires a stale block only through its SENTINEL (`stamped`). The degraded branch's notice is the
# one shape EVERY un-provisioned box takes, and it carried no sentinel — so executing the remedy that very
# line prints (`Sync it: cp …`) left the lane reading "treat every mandated file as unread … never claim to
# have read one" as its LAST mandate claim, permanently, with nothing in the log. ARCHITECTURE.md states the
# invariant ("ONE sentinel line … that every shape carries"); this was the one shape that broke it. Driven
# end to end: degraded dispatch → heal the box → re-dispatch the SAME brief.
mkdir -p "$TMP/home5/.pi/agent/state"
BRIEF3C="$TMP/brief-heal.txt"; seam_brief "$BRIEF3C"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3c1.log" O="$TMP/O" CELL_HOME="$TMP/home5" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; mandate_preflight_lib() { return 1; }; run_agent 5 "$3" "$4" degraded' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3c1.log" "$BRIEF3C" >/dev/null 2>&1
grep -qF '<!-- mandate-preflight #3377 -->' "$BRIEF3C"; ck $? "the DEGRADED notice carries the sentinel line, like every other shape (without it no later dispatch can retire it)"
grep -qF 'never claim to have read one' "$BRIEF3C"; ck $? "…and it is the notice the lane actually reads (a control on the arm above: it is not matching a stale brief)"
: > "$TMP/home5/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$TMP/home5/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3c2.log" O="$TMP/O" CELL_HOME="$TMP/home5" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; run_agent 5 "$3" "$4" healed' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3c2.log" "$BRIEF3C" >/dev/null 2>&1
grep -qF 'SUPERSEDES' "$BRIEF3C"; ck $? "…and once the box is provisioned the notice is RETIRED by a supersession block (the stale false instruction does not survive the remedy it printed)"
case "$(tail -1 "$BRIEF3C")" in
  *'never claim to have read one'*) bad "…but the brief's LAST line is still the stale degraded notice — the lane is still ordered to report a falsehood" ;;
  *) ok "…and the stale claim is no longer the brief's last word" ;;
esac
# ── E3d: THE FLIP-BACK (heal → helper gone again) must not leave a stale PRESENT claim last (#3379 P2) ──
# The seam's guard used to be a whole-FILE grep for `[mandate-preflight] CANNOT VERIFY`. After a heal the brief
# ENDS with the emit's "BOTH mandated files are now PRESENT … do not claim a mandated file is missing" while an
# OLD degraded notice survives earlier in the brief — so the grep matched that old copy, appended NOTHING, and
# the lane's last word was a stale PRESENT claim while the log said CANNOT VERIFY. End-anchored now: the branch
# appends whenever the brief does not END with the degraded notice.
mkdir -p "$TMP/home6/.pi/agent/state"
BRIEF3D="$TMP/brief-flipback.txt"; seam_brief "$BRIEF3D"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3d1.log" O="$TMP/O" CELL_HOME="$TMP/home6" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; mandate_preflight_lib() { return 1; }; run_agent 5 "$3" "$4" degraded' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3d1.log" "$BRIEF3D" >/dev/null 2>&1
: > "$TMP/home6/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$TMP/home6/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3d2.log" O="$TMP/O" CELL_HOME="$TMP/home6" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; run_agent 5 "$3" "$4" healed' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3d2.log" "$BRIEF3D" >/dev/null 2>&1
case "$(tail -1 "$BRIEF3D")" in
  *'BOTH mandated files are now PRESENT'*) ok "…setup: after the heal the brief ENDS with the emit's PRESENT notice (the state the flip-back starts from)" ;;
  *) bad "…setup failed: the healed dispatch did not end the brief with the PRESENT notice (got: $(tail -1 "$BRIEF3D"))" ;;
esac
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran3d3.log" O="$TMP/O" CELL_HOME="$TMP/home6" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; mandate_preflight_lib() { return 1; }; run_agent 5 "$3" "$4" degraded2' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam3d3.log" "$BRIEF3D" >/dev/null 2>&1
case "$(tail -1 "$BRIEF3D")" in
  *'BOTH mandated files are now PRESENT'*) bad "FLIP-BACK: the brief still ENDS with the stale PRESENT claim — the helper is gone again and the lane is told nothing (the whole-file guard matched an old notice earlier in the brief)" ;;
  *'CANNOT VERIFY degraded2'*) ok "FLIP-BACK: the degraded notice is appended again, so the lane's last claim is CURRENT" ;;
  *) bad "FLIP-BACK: the brief's last line is neither the degraded notice nor the stale claim (got: $(tail -1 "$BRIEF3D"))" ;;
esac
# ── E4: THE POSITIVE CONTROL FOR THE SEAM — present files leave the brief untouched ───────────────
mkdir -p "$TMP/home3/.pi/agent/state"
: > "$TMP/home3/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
: > "$TMP/home3/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF4="$TMP/brief-seam-clean.txt"
seam_brief "$BRIEF4"
BEFORE4="$(cksum < "$BRIEF4")"; : > "$TMP/seam2.log"; rm -f "$TMP/pi-ran2.log"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran2.log" O="$TMP/O" CELL_HOME="$TMP/home3" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; cd "$2" || exit 2; run_agent 5 "$3" "$4" seamclean' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam2.log" "$BRIEF4" >/dev/null 2>&1
[ "$(cksum < "$BRIEF4")" = "$BEFORE4" ]; ck $? "present files → run_agent leaves the brief untouched (E3 can fail)"
if grep -qF 'mandate-preflight #3377' "$TMP/seam2.log" 2>/dev/null; then
  bad "the log claims a missing mandate on a box that has both"
else
  ok "…and the log does NOT claim a missing mandate on a healthy box"
fi
# ── E5: source DRIFT pins (not the behavioural proof above) ──────────────────────────────────────
# ⛔ STATED LIMIT, so nobody over-trusts these: E1-E4 drive the SHARED implementation through
# `spawn-gate.sh`'s real `run_agent`. `merge-one.sh`'s call is a DELEGATE to that same implementation,
# and a mutation that wrapped ITS call in a dead branch is NOT CAUGHT BY ANYTHING IN THIS SUITE — the
# greps below still match the call text inside the dead branch (measured: all three stay green on a
# wrapped copy). Driving merge-one's own `run_agent` needs a PR, a chain context and a merge queue — a
# different subject, and a fixture heavy enough that it would be the thing under test. So the greps are
# a presence check on the delegate, never a claim that the delegate's behaviour is exercised here; that
# dead-branch wrap is the disclosed residual of this suite.
grep -qF 'mandate_preflight_lib' "$SPAWN";  ck $? "spawn-gate.sh still defines its resolver"
grep -qF 'mandate_sh="$_ms"; break;' "$MERGE"; ck $? "merge-one.sh still resolves the helper (its own run_agent copy)"
grep -qF 'mandate_preflight_emit "$log" "$prompt" "$label"' "$SPAWN";           ck $? "spawn-gate.sh calls the shared emit"
grep -qF 'mandate_preflight_emit "$log" "$prompt" "reviewer PR #$PR"' "$MERGE"; ck $? "merge-one.sh calls the SAME shared emit"
# ⛔ A GREP FOR A NAME IS SATISFIED BY THAT NAME'S OWN DEFINITION OR INITIALISATION (this change's review,
# P2, MEASURED): `grep -qF 'mandate_preflight_lib' "$SPAWN"` stayed GREEN with the resolver CALL deleted at
# `spawn-gate.sh`'s `_mp_sh="$(mandate_preflight_lib)"`, because the function's own declaration contains the
# string; and `grep -qF 'mandate_sh' "$MERGE"` stayed GREEN on an empty-string initialisation. Each arm is
# therefore pinned to the CALL/ASSIGNMENT SHAPE, never to the bare name.
grep -qF '_mp_sh="$(mandate_preflight_lib)"' "$SPAWN"; ck $? "spawn-gate.sh CALLS its resolver into _mp_sh (a name-grep was satisfied by the declaration)"
grep -qF 'declare -F mandate_preflight_emit' "$SPAWN"; ck $? "spawn-gate.sh checks the helper is USABLE, not merely sourceable"
grep -qF 'declare -F mandate_preflight_emit' "$MERGE"; ck $? "merge-one.sh checks the helper is USABLE too"
# ── E5b: THE TWO HALVES OF THE "helper is UNUSABLE" DIAGNOSTIC (#3379 review cycle 21, P3, MEASURED) ──
# Both seams carry a reason string and a redirect on the sourcing line, and all four were unpinned: deleting
# `2>>"$log"` from EITHER `. "$helper"` call left 193/0 (bash's own `.: <path>: line N:` would go to the
# CALLER's stderr untagged — the "untagged bash error escaping run_agent's log contract" these same lines
# were written to fix), and collapsing `at $<path> is unusable` to a constant "not found" left 193/0 while
# the log then prescribes the WRONG REMEDY: "not found" says sync a missing file, "at <path> is unusable" says
# the file is present and the copy is bad. Both are source pins for §E5's stated reason.
grep -qF '. "$_mp_sh" 2>>"$log"' "$SPAWN"; ck $? "spawn-gate.sh sends the helper's own sourcing errors to the LOG (untagged bash errors escaping to the caller was the defect)"
grep -qF '. "$mandate_sh" 2>>"$log"' "$MERGE"; ck $? "…and merge-one.sh does the same on the reviewer seam"
grep -qF '_mp_why="at $_mp_sh is unusable"' "$SPAWN"; ck $? "spawn-gate.sh names WHICH helper is unusable (a constant 'not found' prescribes the wrong remedy: sync vs replace)"
grep -qF '_mt_why="at $mandate_sh is unusable"' "$MERGE"; ck $? "…and merge-one.sh does too"

# ── E5c: THE REMAINING DIAGNOSTIC HALVES AND THE ONE INSTRUCTION THE LANE READS (#3379 review cycle 22) ─
# Six more measured-green reverts, all on lines an operator or the LANE actually reads:
#   * merge-one's `_md_last="$(tail -n 1 "$prompt")"` — the DATUM the idempotence guard compares. Replacing it
#     with `cat`/`head -n 1` left 197/0 while the arms that claim to cover it pin the COMPARISON, not the
#     datum: the guard then never matches, so the reviewer seam re-appends its notice on every dispatch and
#     the brief grows without bound — the "five dispatches, five notices" defect, free on the one seam that
#     cannot be driven here.
#   * the NOT-FOUND arm of the reason ternary, on BOTH seams (cycle 21 pinned only its `at … unusable`
#     sibling). On the un-provisioned box — the population #3377 measured — this is the arm taken, and its
#     only actionable content is the four search locations.
#   * the closing line the LANE reads. Inverting "There is NO provisioning path" → "a provisioning path"
#     left 197/0: the sentence that tells the lane what to do with the absence is the surface this PR exists
#     to deliver, and nothing could see it flip.
#   * `mandate_why`'s `${spec#*|}` → `${spec#|}`, which leaks the NAME into the reason field
#     (`— LANE-BRIEF-PREAMBLE.md|a dispatch brief may open …`) while cycle 18's arms still matched, because
#     they grep the reason as a SUBSTRING of a string that still contains it.
#   * the executable branch's `set -u`, which the file's header states as a requirement.
# Source pins for §E5's stated reason; the last two are source pins because nothing can drive them.
grep -qF '_md_last="$(tail -n 1 "$prompt" 2>/dev/null)"' "$MERGE"; ck $? "merge-one.sh's idempotence guard compares the brief's LAST LINE (the DATUM was free; pinning the comparison is not pinning it)"
grep -qF '_mp_why="not found (looked in \$O, this helper'"'"'s dir, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts)"' "$SPAWN"; ck $? "spawn-gate.sh's NOT-FOUND reason names the FOUR PLACES it looked (the only actionable content on an un-provisioned box)"
grep -qF '_mt_why="not found (looked in $O,' "$MERGE"; ck $? "…and merge-one.sh's not-found reason keeps its search locations"
grep -qF 'There is NO provisioning path for these files today' "$HELPER"; ck $? "the block's CLOSING INSTRUCTION still tells the lane there is NO provisioning path (inverting it is a silent wrong instruction on the surface this PR exists to deliver)"
WHY_FIELD="$(CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_why LANE-BRIEF-PREAMBLE.md' _ "$HELPER" 2>/dev/null)"
case "$WHY_FIELD" in
  *'|'*) bad "mandate_why returned the NAME as well as the reason — the field split leaked (a revert of \${spec#*|} to \${spec#|} reads as pinned because the reason is still a substring)" ;;
  *) case "$WHY_FIELD" in *"READ §0 and §0b"*) ok "mandate_why returns the REASON ALONE, with no '|' and no name prefix (the field split is pinned, not just the substring)" ;; *) bad "mandate_why returned no reason at all" ;; esac ;;
esac
# ⛔ AND A GREP FOR `set -u` IS SATISFIED BY THE HEADER COMMENT THAT NAMES IT (#3379 review cycle 22,
# MEASURED — my first version of this very arm passed on the prose at line 86 while the executable branch's
# option was deleted). Anchor on the EXECUTED line, indented and alone.
grep -qE '^[[:space:]]+set -u$' "$HELPER"; ck $? "the EXECUTABLE branch sets -u as the header requires (anchored on the executed line, not on the comment that names it)"

# ── E5d: THE REMEDY TEXT, AND THE CANDIDATE PRECEDENCE (#3379 review cycle 23, P2, MEASURED) ──────────
# Five more measured-green reverts. Four are the REMEDY half of a diagnosis: the state exists because its
# remedy differs from the alternatives', and the arms pinned the tag and the path but never the remedy, so
# each could become a diagnosis with no next step. The fifth is rank: the resolvers' candidate ORDER.
grep -qF 'The remedy is a COMPLETE copy of this helper' "$HELPER"; ck $? "the unread-declaration block keeps its REMEDY (a truncated/stale \$O copy — reachable with no stub, and the only actionable content there)"
grep -qF 'remedy is a mode fix, NOT a missing deployment' "$HELPER"; ck $? "the UNREADABLE line keeps its remedy (a mode fix) — the whole reason the state is distinguished from MISSING"
grep -qF 'move the occupant aside' "$HELPER"; ck $? "the NOT-A-FILE line keeps its remedy (move the occupant) — the third state exists BECAUSE neither ship nor chmod applies"
grep -qF 'no search/execute bit on it or on a parent directory, or it is not a directory' "$HELPER"; ck $? "the undecidable-state verdict names WHICH faults to look for (the operator's only cue)"
# ⛔ PRECEDENCE IS THE POINT OF AN ORDERED LIST (this change's own P2, one variable over): a stale legacy copy
# ranked ahead of the box's deployed `$O` is exactly the short-circuit that was fixed. The suite pinned which
# candidates EXIST and that each is file-tested, never their RANK — so moving the legacy farmed path ahead of
# `$O` left 203/0 on BOTH seams.
_mp_rank() { # <file> <for-regex> <earlier-marker> <later-marker> → 0 when earlier precedes later
  awk -v r="$2" -v a="$3" -v b="$4" '$0 ~ r {buf=$0; while (buf !~ /do[[:space:]]*$/ && (getline nx) > 0) buf=buf" "nx; i=index(buf,a); j=index(buf,b); if (i == 0 || j == 0) {print "MISS"; exit} print (i < j ? "OK" : "REVERSED"); exit}' "$1"
}
SP_RANK="$(_mp_rank "$SPAWN" '^[[:space:]]*for c in .*mandate-preflight\.sh' '${O:-}/' '.pi/agent/scripts')"
M1_RANK="$(_mp_rank "$MERGE" '^[[:space:]]*for _ms in .*mandate-preflight\.sh' '$O/' '.pi/agent/scripts')"
[ "$SP_RANK" = "OK" ]; ck $? "spawn-gate.sh ranks the box's \$O copy AHEAD of the legacy ~/.pi/agent/scripts one (measured $SP_RANK; a reordering that puts the stale farmed copy first used to pass)"
[ "$M1_RANK" = "OK" ]; ck $? "…and merge-one.sh ranks them the same way (measured $M1_RANK — the two seams must agree on ORDER, not just membership)"

# ── E5e: REASON SELECTION, AND THE LANE-FACING REMEDIES (#3379 review cycle 24, P2, MEASURED) ──────────
# Cycle 21/22 pinned the two reason SENTENCES with source greps and left the branch that CHOOSES between them
# free: inverting `[ -z "$_mp_sh" ]` → `[ -n "$_mp_sh" ]` left 209/0 on BOTH seams, and both sentences are
# still in the file so both greps still pass. On the population #3377 measured the operator is then told
# "at  is unusable" (replace a file that does not exist) while a present-but-unusable helper reports "not
# found (looked in $O …)" (sync a file that is right there) — the sync-vs-replace defect those cycles closed.
grep -qF '[ -z "$_mp_sh" ]' "$SPAWN"; ck $? "spawn-gate.sh CHOOSES the not-found reason when the helper was not found (the two sentences were pinned; the branch between them was not)"
grep -qF '[ -z "${mandate_sh:-}" ]' "$MERGE"; ck $? "…and merge-one.sh makes the same choice the same way"
# The LANE-FACING remedies, read from the rendered block rather than grepped in the source.
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
L24="$(CELL_HOME="$TMP/home" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
case "$L24" in *'Say so plainly in your report; do NOT claim to have read it'*) ok "the MISSING block tells the LANE what to do with the absence (say it, do not claim to have read it) — identification pinned without its instruction was the c23 class" ;; *) bad "the MISSING block lost its instruction to the lane" ;; esac
case "$L24" in *'Proceed with the BRIEF'*) ok "…and the block still ENDS with its closing instruction, so the last line the lane reads is present (a colon in place of the write used to pass a source grep)" ;; *) bad "the block lost its closing instruction — the last line the LANE reads" ;; esac
UD24="$(mktemp -d)"; mkdir -p "$UD24/.pi/agent/state"; chmod 000 "$UD24/.pi/agent/state"
L24UD="$(CELL_HOME="$UD24" bash -c '. "$1"; _mandate_cli --line 2>/dev/null' _ "$HELPER")"
chmod 755 "$UD24/.pi/agent/state"; rm -rf "$UD24"
case "$L24UD" in *'remedy is a mode fix on that directory, NOT a missing deployment'*) ok "the undecidable renderer names the mode-fix remedy (a chmod on the dir, not a deployment) — read from the block an unsearchable state dir actually renders" ;; *) bad "the undecidable renderer dropped its remedy" ;; esac
# ⛔ AND THE FAULT LIST, IN THE RENDERER THE LANE ACTUALLY READS (#3379 review cycle 27, P2, MEASURED): the
# same fault list was pinned only for `mandate_verdict` (the `--check` text), so deleting the parenthetical
# from `cv_where` left 233/0 while `--check` kept it — the lane and its operator lost the only cue that
# distinguishes a mode fault from "not provisioned yet", in the section written to stop exactly that split.
case "$L24UD" in *'parent directory search (execute) bit is clear'*) ok "…and the LANE-facing renderer names the faults to look for, not only the remedy (the --check twin was pinned; this sentence was free)" ;; *) bad "the lane-facing undecidable renderer dropped its fault list while --check kept it (the lane is told the remedy but not what to look for)" ;; esac
case "$L24UD" in *'so whether the lane can obey its'*) ok "…and still says what is UNKNOWN, not merely that something is" ;; *) bad "the undecidable renderer no longer states what is unknown" ;; esac
NOBASE_L24="$(env -u HOME -u CELL_HOME bash "$HELPER" --line 2>/dev/null)"
case "$NOBASE_L24" in *'remedy is an environment fix'*) ok "…and with no base to name it prescribes an ENVIRONMENT fix instead of a chmod on a path that does not exist" ;; *) bad "the no-base renderer lost its distinct remedy" ;; esac
case "$NOBASE_L24" in *'neither CELL_HOME nor HOME is set'*) ok "…and still says WHY no base can be named" ;; *) bad "the no-base renderer no longer says why" ;; esac
# ⛔ THE THIRD LEG OF `healthy` IS PINNED LIKE ITS SIBLINGS (#3379 review cycle 24, P2, MEASURED): the comment
# claimed "the three collectors are each pinned" and only `mandate_missing` was. Stubbing each in turn is the
# instrument that already reddens for the missing one.
for _coll24 in mandate_unreadable mandate_irregular; do
  # ⛔ THREE THINGS MUST BE TRUE FOR THIS ARM TO SEE ITS LEG AT ALL (#3379 review cycle 24, MEASURED — the arm
  # passed green twice before the fixture was right): (1) the brief must ALREADY carry a SENTINEL block, or
  # the emit returns early; (2) the box must be otherwise PERFECT, or `mandate_missing` blocks the `healthy`
  # gate regardless and the leg under test is invisible; (3) the renderer must be stubbed empty, which is the
  # failure the leg exists to catch. Then leg present → no PRESENT claim; leg deleted → a PRESENT claim.
  _b24="$TMP/brief-hl-$_coll24.txt"; seam_brief "$_b24"
  mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" stamp' _ "$HELPER" "$TMP/hl24.log" "$_b24" >/dev/null 2>&1
  grep -qF 'MANDATE-UNSATISFIABLE' "$_b24"; ck $? "E5e fixture ($_coll24): a SENTINEL block is stamped first (an unstamped brief returns early and the arm cannot fail)"
  : > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"; : > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
  CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_line() { :; }; '"$_coll24"'() { printf "%s\n" /x/y; }; mandate_preflight_emit "$2" "$3" hl' _ "$HELPER" "$TMP/hl24.log" "$_b24" >/dev/null 2>&1
  if grep -qF 'BOTH mandated files are now PRESENT' "$_b24"; then bad "an empty render on a $_coll24-non-empty box was answered with a PRESENT claim — that leg of the healthy gate is load-bearing and unpinned"; else ok "…and the healthy gate refuses on a non-empty $_coll24 ALONE, every other leg clean (leg pinned, as the comment claimed)"; fi
done

# ── E5f: THE GATE THAT REACHES THE REVIEWER SEAM'S EMIT (#3379 review cycle 25, P1, MEASURED) ───────────
# §E5 pinned the PARTS of merge-one's seam — the resolver assignment, the sourcing redirect, the `declare -F`
# probe, the emit call text, and the reason-selection branch — and left the CONDITION that gates them free.
# Inverting `[ -n "${mandate_sh:-}" ]` → `[ -z … ]` (or replacing it with `false`) left 221/0 GREEN: on every
# provisioned box the reviewer session's real disclosure never ran, and the DEGRADED branch instead told the
# reviewer to "treat every mandated file as unread" and logged CANNOT VERIFY — a false box-state claim on the
# highest-volume model call in the harness, with nothing red. The identical condition on spawn-gate reddens
# (E3d's flip-back arms drive the real run_agent), so this pins the text on the seam that cannot be driven.
grep -qF 'if [ -n "${mandate_sh:-}" ] && . "$mandate_sh" 2>>"$log" && declare -F mandate_preflight_emit' "$MERGE"; ck $? "merge-one.sh's emit is gated on the helper being PRESENT and USABLE — the whole condition, not its parts (inverting it sent every provisioned reviewer to the degraded branch with nothing red)"

# ── E5h: THE EMIT MUST PRECEDE THE LAUNCH THAT READS THE BRIEF (#3379 review cycle 27, P2, MEASURED) ──
# Every pin above is a STRING in the file, and none is POSITIONAL: cutting the whole mandate block out of
# `run_agent` and re-inserting it AFTER `pid=$!` — i.e. after `pi -p … "$(cat "$prompt")"` has already
# captured the brief into argv — left this suite at 233 passed, 0 failed. The reviewer is then never told
# anything the emit wrote, which is the #3377 defect restored on the highest-volume model call in the
# harness. The lane seam reddens for the same relocation because E3 drives its launched argv; this seam
# cannot be driven (§E5's limit), so its ORDER is pinned instead of its text.
_MOE="$(grep -nF 'mandate_preflight_emit "$log" "$prompt" "reviewer PR #$PR"' "$MERGE" | head -1 | cut -d: -f1)"
_MOL="$(grep -nF 'pi -p --provider "$lane_provider"' "$MERGE" | head -1 | cut -d: -f1)"
{ [ -n "$_MOE" ] && [ -n "$_MOL" ] && [ "$_MOE" -lt "$_MOL" ]; }; ck $? "merge-one.sh's emit runs BEFORE the launch that captures the brief into argv (measured emit line=$_MOE, launch line=$_MOL; relocating the block below the launch left the reviewer untold at 233/0)"

# ── E5g: THE REMAINING SENTENCES AND COLLECTOR RULES (#3379 review cycle 25, P3, MEASURED) ─────────────
# Twelve more reverts stayed green. None changes a VERDICT, so they are pinned as the code text they are —
# but each one is a sentence an operator or a sourced consumer reads, and this branch spent four cycles
# arguing that a diagnosis without its reason or its remedy is half a diagnosis.
grep -qF 'the brief ALREADY ends with this mandate block' "$HELPER";        ck $? "the emit's no-op log line still names WHY it appended nothing (a bare 'skipping append' leaves the operator guessing)"
grep -qF 'SUPERSEDES the mandate block earlier in this brief' "$HELPER";    ck $? "the supersession log line still names WHAT it superseded"
grep -qF '(a permission problem)' "$HELPER" && bad "the undecidable renderer collapsed its fault list to '(a permission problem)'" || ok "the undecidable renderer still names the faults to look for, not a vague class"
grep -qF 'see --help' "$HELPER";                                            ck $? "an unknown argument still points the reader at --help"
grep -qF '"nothing to disclose" cannot be concluded' "$HELPER";             ck $? "the unread-declaration block still says what CANNOT be concluded, not merely that something cannot"
# ⛔ THE COLLECTORS' OWN RULES, WHICH THEIR SHIPPED CALLERS MASK (#3379 review cycle 25, P3, MEASURED): every
# shipped verb consults `mandate_irregular` first, so `mandate_missing`'s `[ -e ] && continue` — the rule
# that stops a DIRECTORY being reported as MISSING — is unobservable through them and free to revert. The
# header advertises these collectors as a consumer-facing contract, so the rule is pinned where it lives.
grep -qF '[ -e "$root/$name" ] && continue' "$HELPER";                      ck $? "mandate_missing SKIPS an occupied path (a directory where a file belongs is not 'missing' — the comment's own fixed defect)"
grep -qF 'if [ -f "$root/$name" ] && [ ! -r "$root/$name" ]; then' "$HELPER"; ck $? "mandate_unreadable tests REGULAR-AND-UNREADABLE (an occupied path is mandate_irregular's fact, not this one's)"
# ⛔ AND TWO DEFENSIVE LITERALS THAT ARE NOT DEAD (#3379 review cycle 25, P3, MEASURED): removing
# `mandate_why`'s `return 0` makes EVERY rendered reason gain a trailing generic phrase (measured), so the
# "unreachable" fallback is reachable exactly that way; and the brief read's `2>/dev/null` is what keeps an
# unreadable brief's `cat: … Permission denied` off the caller's stderr.
grep -qF 'printf '\''%s'\'' "${spec#*|}"; return 0 ;; esac' "$HELPER";      ck $? "mandate_why RETURNS after the matched spec (without it every reason gains a trailing generic phrase)"
grep -qF 'brief_text="$(cat "$prompt" 2>/dev/null)"' "$HELPER";              ck $? "the brief read SUPPRESSES its own stderr (an unreadable brief must not print cat's error at the caller)"

# ── E6: THE TWO RESOLVERS MUST AGREE (review cycle 1 P2; the arms were RE-DRIVEN in cycle 2) ─────
# ⛔ CYCLE 1'S ARMS WERE VACUOUS (measured in cycle 2): they grepped for the STRING `MANDATE_PREFLIGHT_SH`,
# which the explanatory COMMENT above the resolver also contains — so reverting the whole merge-one.sh fix
# left the suite at 86 passed, 0 failed. An arm satisfied by prose guards nothing. The spawn-gate arms are
# therefore BEHAVIOURAL (source the helper and call the resolver), and merge-one's are pinned to its
# candidate LINE — its top-level body cannot be sourced, so that one is a source pin and says so, the same
# stated limit §E5 carries for the delegate.
RESOLVED="$(MANDATE_PREFLIGHT_SH="$HELPER" bash -c '. "$1"; mandate_preflight_lib' _ "$SPAWN" 2>/dev/null)"
[ "$RESOLVED" = "$HELPER" ]; ck $? "spawn-gate.sh's resolver RETURNS a valid MANDATE_PREFLIGHT_SH (driven, not grepped)"
STALE="$(MANDATE_PREFLIGHT_SH="$TMP/does-not-exist/mandate-preflight.sh" bash -c '. "$1"; mandate_preflight_lib' _ "$SPAWN" 2>/dev/null)"
if [ "$STALE" = "$TMP/does-not-exist/mandate-preflight.sh" ]; then
  bad "a STALE MANDATE_PREFLIGHT_SH short-circuits the resolver — the disclosure then degrades to log-only on a box whose own copy is fine"
else
  [ -f "$STALE" ]; ck $? "…and a STALE override is SKIPPED, falling through to a real candidate ($STALE)"
fi
# merge-one.sh: its `run_agent` copy lives in a file whose top-level body cannot be sourced, so this is a
# SOURCE pin on the resolver line — and it pins CODE, not the comment above it (cycle 2's finding).
grep -qF 'for _ms in "${MANDATE_PREFLIGHT_SH:-}"' "$MERGE"; ck $? "merge-one.sh's resolver STARTS its candidate list with MANDATE_PREFLIGHT_SH (the copy had diverged — an override that worked for every lane but the reviewer)"
grep -qF '[ -n "$_ms" ] && [ -f "$_ms" ]' "$MERGE"; ck $? "…and merge-one.sh tests each candidate is a FILE (the stale-override degradation is not re-introduced on the reviewer seam)"
# ⛔ PINNING THE LOOP'S FIRST CANDIDATE DOES NOT PIN THE LIST (this change's review, P2, MEASURED): dropping
# the `$_M1_HERE/mandate-preflight.sh` entry from `merge-one.sh`'s list left the suite at 102 passed, 0
# failed, while the two resolvers now disagreed about where the helper is — E6's exact subject, in the
# green. And dropping the ASSIGNMENT (`mandate_sh="$_ms"; break;` → `break;`) left the same 102/0 while
# the reviewer seam became PERMANENTLY LOG-ONLY: the loop ran, found nothing, `mandate_preflight_emit` was
# never called, and every reviewer `pi` session got no block — #3377 restored on that seam with a green
# suite.
# ⛔ AND PINNING ONE FILE'S LIST PINS NOTHING ABOUT THE OTHER (this change's review cycle 2, P1, MEASURED):
# the first fix ran this loop against `merge-one.sh` ONLY. Deleting `"${O:-}/mandate-preflight.sh"` from
# `spawn-gate.sh`'s list left the suite at 110 passed, 0 failed — and `$O` is the entry the resolver's own
# comment calls THE BOX'S HOME, the only candidate that resolves on a cell, so the disclosure would go
# log-only on every lane, fixer and worker with a green suite. So BOTH files are pinned, EACH candidate by
# its own token, and their candidate COUNTS are required to agree — a removal reddens a token pin, an
# addition (a one-sided divergence) reddens the count.
_mp_cand_count() { # _mp_cand_count <file> <for-line regex> → `mandate-preflight.sh` tokens in the resolver's for-STATEMENT
  # ⛔ PROSE IS NOT A CANDIDATE (measured): the resolver's explanatory comment names `$O/mandate-preflight.sh`, so
  # a whole-region count read 5 for spawn-gate against 4 for merge-one and the arm reddened on a healthy tree.
  # ⛔ AND A COUNT THAT CAN SILENTLY BE EMPTY IS 0==0 (this change's review cycle 3, P1, MEASURED): the previous
  # version printed only from its END-marker branch, so a renamed start marker yielded `""` for BOTH files and
  # `[ "" = "" ]` PASSED — the arm said "the resolvers agree" having counted nothing. It also made the two end
  # markers behave differently: an INDENTED `done` (a purely cosmetic reindent) returned `""` and reddened the
  # suite on healthy code, while an indented `}` was simply dead. Counting the `for` STATEMENT removes the end
  # markers altogether: it terminates on its own `do`, and `print n+0` can never emit an empty string.
  awk -v r="$2" '$0 ~ r {buf=$0; while (buf !~ /do[[:space:]]*$/ && (getline nx) > 0) buf=buf" "nx; n=gsub(/mandate-preflight\.sh/,"&",buf); print n+0; exit}' "$1"
}
SP_NCA="$(_mp_cand_count "$SPAWN" '^[[:space:]]*for c in .*mandate-preflight\.sh')"
M1_NCA="$(_mp_cand_count "$MERGE" '^[[:space:]]*for _ms in .*mandate-preflight\.sh')"
{ [ -n "$SP_NCA" ] && [ -n "$M1_NCA" ] && [ "$SP_NCA" = "$M1_NCA" ]; }; ck $? "the two resolvers carry the SAME number of candidates (spawn-gate=${SP_NCA:-NOT-FOUND}, merge-one=${M1_NCA:-NOT-FOUND}) — a one-sided addition is a disagreement, and an unmatched list is not agreement"
for _mf_cand in '${MANDATE_PREFLIGHT_SH:-}' '$O/mandate-preflight.sh' '$_M1_HERE/mandate-preflight.sh' \
                '${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/mandate-preflight.sh' \
                '${HOME:-}/.pi/agent/scripts/mandate-preflight.sh'; do
  grep -qF -- "$_mf_cand" "$MERGE"; ck $? "merge-one.sh's candidate list still contains $_mf_cand (a dropped entry is a resolver disagreement, not a tidying)"
done
for _mf_cand in '${MANDATE_PREFLIGHT_SH:-}' '${O:-}/mandate-preflight.sh' '$here/mandate-preflight.sh' \
                '${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/mandate-preflight.sh' \
                '${HOME:-}/.pi/agent/scripts/mandate-preflight.sh'; do
  grep -qF -- "$_mf_cand" "$SPAWN"; ck $? "spawn-gate.sh's candidate list still contains $_mf_cand (dropping \$O made the disclosure log-only on every cell)"
done
# ⛔ THE DEGRADED BRANCH IS THE ONE EVERY ALREADY-DEPLOYED BOX TAKES (this change's review cycle 2, P1,
# MEASURED): replacing EITHER `else` body below with `:` left the suite at 110 passed, 0 failed, while
# nothing at all was written — the silence #3377 exists to end.
# ⛔ A GREP FOR THE SENTENCE IS NOT A TEST THAT ANYTHING WAS WRITTEN (review cycle 11, P1, MEASURED, and
# this is the arm's own history repeating): `: "[mandate-preflight] CANNOT VERIFY …" >> "$log"` keeps every
# word of the notice and writes NOTHING — 158 passed, 0 failed. The arms below therefore assert the WRITE,
# not the prose: spawn-gate's is DRIVEN (the real `run_agent` with the resolver forced to fail, so the
# operator log is read back), and merge-one's is pinned to the `echo` that performs the write (§E5's limit
# means it cannot be driven). A cycle-8 finding said exactly this and was wrongly recorded as falsified: the
# counter-mutant had deleted the sentence as well, which reddens a text grep for the wrong reason.
grep -qF 'echo "[mandate-preflight] CANNOT VERIFY $label:' "$SPAWN"; ck $? "spawn-gate.sh performs the degraded-branch LOG WRITE with its notice (a bare grep for the sentence passed on a mutant that wrote nothing)"
# ⛔ A PIN THAT STOPS AT THE COMMAND LEAVES THE DESTINATION FREE (#3379 review cycle 12, P1, MEASURED): the
# previous version matched whatever line 204 redirected to — `>> "$log"` → `>> /dev/null` (sentence and
# `echo` intact) stayed at 162 passed, 0 failed, and `>>` → `>` truncating the log likewise. Since §E5 rules
# out driving merge-one's `run_agent`, this grep is the ONLY coverage of that operator record, so it must pin
# the redirect too, not just the words in front of it.
# ⛔ AND THE COMMAND IS PINNED SEPARATELY, BECAUSE THE DESTINATION ANCHOR ALONE IS SATISFIED BY `:`
# (#3379 review cycle 13, P1, MEASURED — a REGRESSION this very commit introduced): `: "[mandate-preflight]
# CANNOT VERIFY reviewer PR #$PR: …is not a reading about the box." >> "$log"` keeps the message, the redirect
# AND the destination, drops the write, and passed at 165/0 — while the same mutant reddened at the parent.
# Cycle 12 REPLACED the cycle-11 `echo` anchor instead of adding to it. BOTH are now asserted, because they
# pin two different halves of one line and either alone leaves the other half free.
grep -qF 'echo "[mandate-preflight] CANNOT VERIFY reviewer PR #$PR:' "$MERGE"; ck $? "merge-one.sh's degraded notice is WRITTEN (the echo that performs it - a colon keeps the message and drops the write)"
grep -qF 'is not a reading about the box." >> "$log"' "$MERGE"; ck $? "…AND to the OPERATOR LOG (destination pinned; a redirect to /dev/null used to pass)"
grep -qF '[mandate-preflight] CANNOT VERIFY' "$SPAWN"; ck $? "spawn-gate.sh still carries the notice text on the degraded branch"
grep -qF 'Sync it: cp scripts/orchestrator-harness/mandate-preflight.sh' "$SPAWN"; ck $? "…with its remedy (a bare grep for the notice was satisfied by the BRIEF append 16 lines below)"
grep -qF '[mandate-preflight] CANNOT VERIFY' "$MERGE"; ck $? "merge-one.sh still carries the notice text on the degraded branch"
grep -qF 'orders a reviewer to read exist (#3377). Proceeding: a helper that cannot run is not a reading about the box' "$MERGE"; ck $? "…with the reason (its parenthetical claim that 'no other notice' exists on that path was inverted — the brief append satisfied the bare grep)"
# merge-one's BRIEF APPEND and its IDEMPOTENCE GUARD are both SOURCE pins for §E5's stated reason (its
# `run_agent` needs a PR, a chain context and a merge queue, so its behaviour cannot be driven here). Each
# is pinned to text ONLY that line carries, because a bare grep for the notice was satisfied by the OTHER
# line in the same branch — measured green with the line deleted either way.
# ⛔ THE GUARD IS THE WHOLE POINT (this change's review cycle 3, P1, MEASURED): without it the seam appends
# one notice PER DISPATCH (measured 2 on two dispatches against 1 on the real tree), i.e. the unbounded
# brief growth the emit's own guard exists to prevent, re-opened on the branch every un-provisioned box
# takes. Deleting it left 121 passed, 0 failed.
# ⛔ THREE PARTS, THREE PINS: the message, the COMMAND, and the destination (#3379 review cycle 14, P2,
# MEASURED): `printf '%s\n' "…is not available to this spawn…" >> "$prompt"` → `: "…" >> "$prompt"` keeps every
# word AND the redirect, drops the write, and left 169 passed, 0 failed. The message-only pin could not see it,
# and §E5's limit means no behavioural arm can. The `printf` that performs the write is pinned here.
grep -qF 'is not available to this spawn' "$MERGE"; ck $? "merge-one.sh APPENDS the notice to the brief, not only to the log (source pin, §E5's limit)"
# (the `printf` now prepends the sentinel, so the pin follows the CODE — the command AND the message it
# writes — rather than a shape that changed under it: the cycle-14 lesson that a pin must track the line
# it guards, applied to a sibling commit that legitimately respelled that line.)
grep -qF "if { printf '%s\\n%s\\n' '<!-- mandate-preflight #3377 -->' \"[mandate-preflight] CANNOT VERIFY reviewer PR #\$PR:" "$MERGE"; ck $? "…and the printf that PERFORMS that write is pinned (a colon keeps the prose and the redirect and writes nothing)"
# ⛔ AND THE GUARD IS END-ANCHORED NOW (#3379 review, P2): a whole-file grep matched an OLD copy of the notice
# earlier in the brief, so on a flip-back the seam appended nothing and left a stale "BOTH mandated files are
# now PRESENT" as the last claim. Pin the CODE, not the prose (the cycle-2 lesson).
grep -qF '_md_prefix="[mandate-preflight] CANNOT VERIFY reviewer PR #$PR:"' "$MERGE"; ck $? "…and that append is IDEMPOTENT, end-anchored on the notice the brief actually ENDS with (a whole-file grep matched a stale copy earlier in the brief)"
grep -qF 'if [ "${_md_last#"$_md_prefix"}" = "$_md_last" ]; then' "$MERGE"; ck $? "…and merge-one.sh tests the brief's LAST LINE, not 'the phrase occurs somewhere' (the flip-back hole)"
grep -qF '<!-- mandate-preflight #3377 -->' "$MERGE"; ck $? "…and merge-one.sh's degraded notice CARRIES the sentinel (without it a provisioned box can never retire it)"
# ⛔ THE OUTER GUARD LINE SURVIVES EVERY REVERT OF THE FIX'S SUBSTANCE (#3379 review cycle 5, P2, MEASURED):
# restoring merge-one's ungrouped `printf … >> "$prompt"` INSIDE the kept `if ! grep …; then`, or deleting
# its WARN `else`, both left this suite at 133 passed / 0 failed. merge-one cannot be driven behaviourally
# (§E5's stated limit), so its two halves are pinned as the code text they are — the grouped redirect, and
# the WARN that records a failed append — because a pin on the surrounding guard alone guards the guard.
grep -qF '>> "$prompt"; } 2>/dev/null; then' "$MERGE"; ck $? "…and merge-one.sh GROUPS the redirect with the command (an ungrouped >> leaks its failure to the caller and no trailing 2>/dev/null can retract it)"
# ⛔ SAME DESTINATION HOLE ON THE WARN (#3379 review cycle 12, P2, MEASURED): the arm said "RECORDS a failed
# append in the operator log" while pinning only the sentence — `>> "$log"` → `>> /dev/null` stayed 162/0. The
# WARN exists to tell an operator the LANE went untold; a WARN written nowhere tells nobody.
grep -qF 'echo "[mandate-preflight] WARN reviewer PR #$PR: could not append' "$MERGE"; ck $? "…and the failed-append WARN is WRITTEN (the echo: a colon keeps the prose and writes nothing)"
grep -qF 'Proceeding (a disclosure, not a gate)." >> "$log"' "$MERGE"; ck $? "…AND RECORDS it IN THE OPERATOR LOG (destination pinned separately; a second ck on one line is vacuous)"
grep -qF '_md_prefix="[mandate-preflight] CANNOT VERIFY $label:"' "$SPAWN"; ck $? "spawn-gate.sh's brief append is IDEMPOTENT too, end-anchored on the notice the brief ENDS with"
grep -qF 'if [ "${_md_last#"$_md_prefix"}" = "$_md_last" ]; then' "$SPAWN"; ck $? "…and it tests the LAST LINE, not 'the phrase occurs somewhere' (the whole-file grep was the flip-back hole)"
# ⛔ THE LOG IS NOT THE LANE, AND THAT WAS THE ACTUAL HOLE (this change's review cycle 2, P1, MEASURED):
# the notice above went to `$log` ONLY, so on a box that has not received the helper the LANE was told
# nothing — #3377 exactly, on the population #3377 measured — and replacing BOTH notices with `:` left the
# suite at 110 passed, 0 failed. Driven, not grepped: the real `run_agent`, with the resolver forced to
# fail, must put CANNOT VERIFY in the argv the agent is launched with. The stub is what makes it a
# mutation-catcher: delete either `printf … >> "$prompt"` and the launched argv loses the line.
BRIEF5="$TMP/brief-nohelper.txt"; seam_brief "$BRIEF5"
rm -f "$TMP/pi-ran5.log"
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran5.log" O="$TMP/O" CELL_HOME="$TMP/home2" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; mandate_preflight_lib() { return 1; }; cd "$2" || exit 2; run_agent 5 "$3" "$4" nohelper' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam5.log" "$BRIEF5" >/dev/null 2>&1
grep -qF '[mandate-preflight] CANNOT VERIFY' "$BRIEF5"; ck $? "an UNRESOLVABLE helper still tells the LANE it cannot verify (#3377's own population: a box without the helper)"
grep -qF '[mandate-preflight] CANNOT VERIFY' "$TMP/pi-ran5.log" 2>/dev/null; ck $? "…and the line is in the ARGV the agent was launched with, not only in a log the lane never reads"
# ⛔ THE OPERATOR LOG MUST ACTUALLY RECEIVE IT (review cycle 11, P1, MEASURED). The two source greps above
# assert the SENTENCE is in the file; `: "[mandate-preflight] CANNOT VERIFY …" >> "$log"` keeps every word,
# writes nothing, and passed at 158/0 — the operator's only record on the branch every un-provisioned box
# takes, gone with a green suite. This arm reads the log back from the SAME drive, so it fails on a mutant
# that keeps the prose.
grep -qF '[mandate-preflight] CANNOT VERIFY' "$TMP/seam5.log" 2>/dev/null; ck $? "the OPERATOR LOG actually receives the degraded notice (a mutant that keeps the sentence but writes nothing used to pass here)"
grep -qF 'Sync it: cp scripts/orchestrator-harness/mandate-preflight.sh' "$TMP/seam5.log" 2>/dev/null; ck $? "…with its remedy in the log, so an operator is told how to fix the box and not merely that it is broken"
# ⛔ ONE NOTICE PER DISPATCH, NOT ONE PER ATTEMPT (this change's review cycle 3, P1, MEASURED): the suite
# drove this branch ONCE, so no arm could see a second append — deleting the idempotence guard left 121
# passed, 0 failed while a degraded box grew its brief by a line per dispatch (measured 2 notices after two
# dispatches, against 1 on the real tree). A re-dispatch is the normal case (the stale-worker reaper retries),
# so this is measured, not hypothetical: drive it a SECOND time and require exactly one notice.
PATH="$TMP/bin:$PATH" PI_LOG="$TMP/pi-ran5.log" O="$TMP/O" CELL_HOME="$TMP/home2" KIND=reviewer \
  WIP_RESCUE_DISABLE=1 LANE_PREFLIGHT=0 \
  DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 MAX_LOAD=99999 \
  PI_LANE_PROVIDER=deepseek PI_LANE_MODEL=deepseek-flash \
  bash -c '. "$1"; mandate_preflight_lib() { return 1; }; cd "$2" || exit 2; run_agent 5 "$3" "$4" nohelper' \
  _ "$SPAWN" "$FIXREPO" "$TMP/seam5.log" "$BRIEF5" >/dev/null 2>&1
NONCE_COUNT="$(grep -cF '[mandate-preflight] CANNOT VERIFY' "$BRIEF5")"
[ "$NONCE_COUNT" = "1" ]; ck $? "a SECOND dispatch does NOT append a second notice (measured $NONCE_COUNT; without the guard the brief grows per dispatch)"
# ⛔ THE EMIT'S OPERATOR-LOG WRITE HAD NO ARM THAT READ IT BACK (#3379 review cycle 12, P2, MEASURED): cycle 7
# pinned its GROUPING (de-grouping reddens) but never its DESTINATION — `{ printf … >> "$log"; }` →
# `>> /dev/null` stayed at 162 passed, 0 failed. Every other emit redirect is covered; this is the one the
# PROVISIONED box takes, i.e. the normal case, and it is operator-only (the lane half is the brief append).
# Driven: the emit is called with a missing mandate, then the log file is read back.
LOGF13="$TMP/emit-logwrite.log"; : > "$LOGF13"
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
BRIEF13="$TMP/brief-logwrite.txt"; seam_brief "$BRIEF13"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "$3" logwrite' _ "$HELPER" "$LOGF13" "$BRIEF13" >/dev/null 2>&1
grep -qF '[mandate-preflight]' "$LOGF13"; ck $? "the emit WRITES to the operator log it is handed (a redirect to /dev/null used to pass — the log is read back, not grepped in the source)"
grep -qF 'MANDATE-UNSATISFIABLE' "$LOGF13"; ck $? "…and what it writes is the verdict, not merely a prefix"
# ⛔ THE ARM ABOVE READS THE LOG BUT DOES NOT IDENTIFY THE LINE (measured): the emit writes to `$log` in more
# than one place, so `>> "$log"` → `>> /dev/null` on the SUCCESS branch alone still left the log populated and
# the suite at 164 passed, 0 failed. The specific line that records a SUCCESSFUL brief append is pinned by its
# own text, so a redirect harvested to /dev/null is caught where it happens.
grep -qF 'named the absence IN THE BRIEF as well' "$LOGF13"; ck $? "…including the line that records the brief append SUCCEEDED (its own redirect to /dev/null used to pass: the log still had other content)"

# ⛔ THE NO-BRIEF BRANCH WAS NEVER DRIVEN AT ALL — NEITHER ITS TEXT NOR ITS DESTINATION (#3379 review cycle 13,
# P2, MEASURED): every call site in this suite passes a real brief, so `{ echo "… no brief file to append to
# …" >> "$log"; }` → `>> /dev/null` stayed at 165 passed, 0 failed, and the in-source claim "every other emit
# redirect is covered" was false. That record is the one that says THE LANE WAS NEVER TOLD — the loudest
# piece of silence this file exists to end — so it is driven: an emit with an explicit empty brief argument,
# then the log read back.
LOGF14="$TMP/emit-nobrief.log"; : > "$LOGF14"
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
CELL_HOME="$TMP/home" bash -c '. "$1"; mandate_preflight_emit "$2" "" nobrief' _ "$HELPER" "$LOGF14" >/dev/null 2>&1
grep -qF 'no brief file to append to' "$LOGF14"; ck $? "an emit with NO brief WRITES the no-brief WARN to the operator log (the branch was never driven; a redirect to /dev/null used to pass)"
grep -qF 'the LANE will not see it' "$LOGF14"; ck $? "…and says the LANE will not see it — the consequence, which is the whole point of the record"

# The emit itself must be non-fatal on every branch.
if awk '/^mandate_preflight_emit\(\)/,/^}/' "$HELPER" | grep -qE '\breturn [1-9]'; then
  bad "mandate_preflight_emit returns non-zero on some branch — callers would treat a disclosure as a refusal"
else
  ok "mandate_preflight_emit never returns non-zero"
fi

echo "§F non-vacuity, and the DEPLOYMENT manifests"
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
N="$(run --line | grep -c .)"; [ "${N:-0}" -ge 3 ]; ck $? "--line renders ${N} lines when both are missing (§A's empty result is not an always-empty bug)"
# ⛔ A PRESENCE TEST IS NOT A UNIQUENESS TEST (this change's review cycle 4, P2, MEASURED): `grep -qF
# 'mandate_files()'` stayed GREEN when a SECOND copy of the population was added to the helper — measured,
# 97 passed, 0 failed — so the arm intended as "the ONE home" guarded nothing, while the declaration's own
# comment nominates it as the drift chase. Count the SPECS instead: each name appears exactly once, and the
# declaration is defined exactly once. Both are falsifiable by adding a copy.
SPEC_COUNT="$(grep -c '^LANE-BRIEF-PREAMBLE\.md|' "$HELPER")"
[ "$SPEC_COUNT" = "1" ]; ck $? "the preamble is declared EXACTLY once (a second copy reddens this; measured count=$SPEC_COUNT)"
SPEC_COUNT2="$(grep -c '^TORTOISE-GRAPH-BRIEF\.md|' "$HELPER")"
[ "$SPEC_COUNT2" = "1" ]; ck $? "the graph brief is declared EXACTLY once (measured count=$SPEC_COUNT2)"
DEF_COUNT="$(grep -c '^mandate_files() {' "$HELPER")"
[ "$DEF_COUNT" = "1" ]; ck $? "…and mandate_files is DEFINED exactly once (measured count=$DEF_COUNT)"
# A `$O` that lost the file is a box where the disclosure silently does not happen — the "hand-copied
# client ⇒ a fresh box receives nothing" class this helper exists to end.
# ⛔ AND THE NAME MUST BE IN THE LIST, NOT IN THE PROSE (review cycle 4, P2, MEASURED): a bare
# `grep -qF 'mandate-preflight.sh'` matched install.sh's own COMMENTS, so deleting it from the `for f in …`
# drift list still left the arm green — a `$O` losing the helper would go unreported. Pin the LIST line.
grep -qE '^for f in .*mandate-preflight\.sh' "$HERE/install.sh" 2>/dev/null; ck $? "install.sh names it in the DRIFT LIST ITSELF, not merely in its comments (a \$O missing it is reported)"
# ⛔ MEMBERSHIP IN THE LIST, NOT PRESENCE IN THE FILE (this change's review cycle 3, P1, MEASURED): a bare
# `grep -qF 'mandate-preflight.sh'` was satisfied by a COMMENT, so moving the name out of EXECUTED into prose
# left 121 passed, 0 failed — the same defect this commit fixed for `install.sh` on the line above. The value
# is extracted and tested as a WORD, so neither a comment nor a substring (`my-mandate-preflight.sh`) passes.
_CSS_EXECUTED="$(sed -nE 's/^EXECUTED="([^"]*)".*/\1/p' "$HERE/check-single-source.sh" 2>/dev/null)"
case " $_CSS_EXECUTED " in
  *' mandate-preflight.sh '*) ok "check-single-source.sh names it in the EXECUTED list itself, not merely in its comments (a \$O missing it is reported)" ;;
  *) bad "check-single-source.sh does NOT name mandate-preflight.sh in EXECUTED — a \$O that lost the helper would go unreported" ;;
esac

# ⛔ A META-ARM, BECAUSE THIS BUG WAS IN THE TEST FILE ITSELF (#3379 review cycle 14, P1, MEASURED): `ck`
# CONSUMES `$?`, so `... ; ck $? "a"; ck $? "b"` tests the FIRST grep's status twice — the second assertion
# reads `$?` of `ok`/`bad`, i.e. 0, and can never fail. I wrote exactly that, and the arm printed ✅ on the
# very mutant its text named. No per-line pin can catch this class, because the damage is the nonexistent
# assertion, not the regex; so the SHAPE is banned outright and this arm reddens if it ever returns.
# (comment lines are excluded: the explanation of this very bug contains the banned shape as prose — measured,
# it was the only hit, which is also a reminder that a prose match is not a code match.)
# ⛔ THE HAZARD IS A STATUS CONSUMER IN A NON-INITIAL POSITION, NOT A SPELLING OF `$?` (this arm's third
# revision, #3379 review cycles 14-17, each MEASURED). `ck`/`ok`/`bad` return 0 unconditionally, so an
# assertion whose argument reads `$?` AFTER another statement has already consumed it ALWAYS passes — the
# arm printed ✅ over a `[ 1 -eq 2 ]` exactly that way. Two earlier versions were wrong in opposite
# directions: a literal `; ck $? …; ck $?` (bans a separator, evaded by `&&`, `ok`, quoted `"$?"`, `${?}`,
# `_s=$?; ck $_s`), then a per-line CONSUMER COUNT (reddened on the file's own `then ok "$2"; else bad "$2"`
# and on messages whose prose contains the word, i.e. a false block). What is actually banned is the
# combination: an assertion at a non-initial position whose argument reads a status.
# Comments are stripped FIRST — whole-line and trailing — because this file documents its own defects inline,
# and a trailing comment quoting the shape must not fail a correct line.
# The diagnostic reports FILE line numbers (FNR on the file itself), not the index of a filtered stream.
# ⛔ AND IT MUST NOT FAIL OPEN WHEN IT CANNOT RUN (this arm's fourth revision; #3379 review cycle 17). The
# third revision used `seg` as BOTH the split array and the per-segment scalar, so awk aborted with
# "illegal reference to array seg", the capture came back EMPTY, and `${DOUBLE_CK:-0}` read empty as 0 —
# the guard reported "measured 0 line(s)" and passed while testing NOTHING. A gate that exits 0 when it
# could not run is the no-op shape this whole branch is about, and it was mine. Distinct names now, and an
# unparseable report is a FAILURE rather than a zero.
DOUBLE_CK_REPORT="$(awk '
  {
    line = $0
    sub(/^[[:space:]]*#.*$/, "", line)      # a whole-line comment
    sub(/[[:space:]]+#.*$/, "", line)       # a trailing comment
    gsub(/\|\|/, ";", line)                 # one separator kind, so the walk need not know which
    gsub(/&&/, ";", line)
    n = split(line, segs, ";")
    seen = 0                                # has a consumer already run on this line?
    for (i = 1; i <= n; i++) {
      sg = segs[i]
      sub(/^[[:space:]]*/, "", sg)
      sub(/^\([[:space:]]*/, "", sg)
      sub(/^\{[[:space:]]*/, "", sg)
      sub(/^then[[:space:]]+/, "", sg)
      sub(/^else[[:space:]]+/, "", sg)
      if (sg !~ /^(ck|ok|bad)[[:space:]]+/) continue
      arg = sg
      sub(/^(ck|ok|bad)[[:space:]]+/, "", arg)
      reads = (arg ~ /\$\?/ || arg ~ /\$\{[[:space:]]*\?/ || arg ~ /^"?\$_[A-Za-z_]/)
      if (seen && reads) { cnt++; hits = hits (cnt == 1 ? "" : ",") FNR; break }
      seen = 1
    }
  }
  END { printf "%d|%s", cnt + 0, hits }
' "$0" 2>/dev/null)"
DOUBLE_CK="${DOUBLE_CK_REPORT%%|*}"
DOUBLE_CK_AT="${DOUBLE_CK_REPORT#*|}"
case "${DOUBLE_CK:-}" in
  ''|*[!0-9]*) bad "the double-status guard COULD NOT RUN (report='${DOUBLE_CK_REPORT:-<empty>}') — an unparseable report is not a pass" ;;
  *) [ "$DOUBLE_CK" = "0" ]; ck $? "no non-initial assertion reads a status (it would read a consumer's 0 and could never fail - measured $DOUBLE_CK line(s)${DOUBLE_CK_AT:+, at $DOUBLE_CK_AT})" ;;
esac

echo
printf 'mandate-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
