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
seam_brief() {
  cat > "$1" <<'BRIEF'
# a brief for the seam
## RESEARCH FIRST
INTERNAL: nothing — this is a TEST FIXTURE; its subject is the mandate disclosure, not research.
EXTERNAL: nothing — see INTERNAL.
RUNG: 3 — web_fetch
CONTRADICTION TEST: no recorded decision reaches this work — it is a test fixture.
BRIEF
}

echo "§A all present → SILENT"
mkstate
: > "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md"
: > "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
run --check >/dev/null 2>&1; ck $? "both present → rc 0"
LINE="$(run --line)"; [ -z "$LINE" ]; ck $? "both present → --line renders NOTHING (empty, not a banner)"
MISS="$(run --missing)"; [ -z "$MISS" ]; ck $? "--missing is empty when both are present"

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
  MISS_UR="$(run --missing)"; [ -z "$MISS_UR" ]; ck $? "--missing prints NOTHING through an unreadable dir (no false 'ship it' advice)"
  # ⛔ READABLE IS NOT SEARCHABLE (review cycle 7, P2, measured): `chmod -R 640` leaves the dir READABLE
  # (`[ -r ]` true) but with no SEARCH bit, so `[ -f "$root/<name>"`] fails for every entry and the check
  # reported both present files as MISSING — the same wrong remedy, one mode bit away from the case
  # above. The predicate must ask whether ANYTHING can be decided about entries here, so it tests `-x` too.
  chmod 640 "$TMP/home/.pi/agent/state"
  if [ -x "$TMP/home/.pi/agent/state" ]; then
    ok "(skipped: this user keeps search permission on a 640 dir — running as root?)"
  else
    run --check >/dev/null 2>&1; [ $? -eq 2 ]; ck $? "a readable-but-UNSEARCHABLE dir → rc 2, not 1 (present files must not be called missing)"
    MISS_NS="$(run --missing)"; [ -z "$MISS_NS" ]; ck $? "--missing prints NOTHING through a search-less dir"
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
    MISS_AN="$(run --missing)"; [ -z "$MISS_AN" ]; ck $? "--missing prints NOTHING when an ancestor is unsearchable"
    run --line | grep -qF 'CANNOT VERIFY'; ck $? "--line says CANNOT VERIFY, and never MISSING, when an ancestor is unsearchable"
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
fi
chmod 644 "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" 2>/dev/null

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
# DIAGNOSTICS: when a seam arm fails, print what the seam actually wrote — an assertion that only says
# "not found" sends the next reader to re-run the suite by hand, which is the friction this avoids.
if [ "$FAIL" -gt "$E3_MARK" ]; then
  printf '%s\n' "--- run_agent log ($TMP/seam.log) ---"; tail -30 "$TMP/seam.log" 2>/dev/null
  printf '%s\n' "--- stub pi log ---"; cat "$TMP/pi-ran.log" 2>/dev/null || printf '%s\n' "(no pi run)"
  printf '%s\n' "--- stdout ---"; tail -10 "$TMP/seam.out" 2>/dev/null
  printf '%s\n' "--- stderr ---"; tail -10 "$TMP/seam.err" 2>/dev/null
fi
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
grep -qF 'mandate_preflight_lib' "$SPAWN";  ck $? "spawn-gate.sh still resolves the helper"
grep -qF 'mandate_sh' "$MERGE";             ck $? "merge-one.sh still resolves the helper (its own run_agent copy)"
grep -qF 'mandate_preflight_emit "$log" "$prompt" "$label"' "$SPAWN";           ck $? "spawn-gate.sh calls the shared emit"
grep -qF 'mandate_preflight_emit "$log" "$prompt" "reviewer PR #$PR"' "$MERGE"; ck $? "merge-one.sh calls the SAME shared emit"
grep -qF 'declare -F mandate_preflight_emit' "$SPAWN"; ck $? "spawn-gate.sh checks the helper is USABLE, not merely sourceable"
grep -qF 'declare -F mandate_preflight_emit' "$MERGE"; ck $? "merge-one.sh checks the helper is USABLE too"
# The emit itself must be non-fatal on every branch.
if awk '/^mandate_preflight_emit\(\)/,/^}/' "$HELPER" | grep -qE '\breturn [1-9]'; then
  bad "mandate_preflight_emit returns non-zero on some branch — callers would treat a disclosure as a refusal"
else
  ok "mandate_preflight_emit never returns non-zero"
fi

echo "§F non-vacuity, and the DEPLOYMENT manifests"
mkstate; rm -f "$TMP/home/.pi/agent/state/LANE-BRIEF-PREAMBLE.md" "$TMP/home/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md"
N="$(run --line | grep -c .)"; [ "${N:-0}" -ge 3 ]; ck $? "--line renders ${N} lines when both are missing (§A's empty result is not an always-empty bug)"
grep -qF 'mandate_files()' "$HELPER"; ck $? "the declaration is a single function (the ONE home)"
# A `$O` that lost the file is a box where the disclosure silently does not happen — the "hand-copied
# client ⇒ a fresh box receives nothing" class this helper exists to end.
grep -qF 'mandate-preflight.sh' "$HERE/install.sh" 2>/dev/null; ck $? "install.sh names it in the drift list (a \$O missing it is reported)"
grep -qF 'mandate-preflight.sh' "$HERE/check-single-source.sh" 2>/dev/null; ck $? "check-single-source.sh names it in EXECUTED (presence-required)"

echo
printf 'mandate-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
