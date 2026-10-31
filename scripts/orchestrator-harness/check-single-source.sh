#!/usr/bin/env bash
# check-single-source.sh — FAIL if the orchestrator harness has forked again.
#
# THE DEFECT THIS EXISTS TO PREVENT (measured 2026-10-19). One system existed in three copies:
#
#     agent-infra  scripts/orchestrator-harness/   8 of 8 files   <- CANONICAL (this directory)
#     tortoise     operations/orchestrator-harness/ 6 of 8         <- retired fork
#     ~/orchestrator                                8 of 8, NO GIT  <- the LIVE copy
#
# Every fix then had to be applied by hand in 3-4 places, every box ran a different generation, and
# "self-healing" was impossible because there was no authority to heal TOWARD. This script is the
# instrument that makes that state detectable instead of discovered months later.
#
# WHAT IT ASSERTS
#   1. CANONICAL COMPLETENESS — every file in SHARED exists here. A copy missing a file is not a
#      source of truth; `claims.sh` and `nonblocking-dispatch.sh` were exactly the two the tortoise
#      fork lacked.
#   2. NO RESURRECTED FORK — for each --fork <dir>, NONE of the SHARED files may exist there. The
#      retired location must stay retired; a pointer README is fine, a script is a fork.
#   3. THE DEPLOYED COPY IS THE SAME BYTES — for the deployed dir (env O, or --o), the EXECUTED set
#      (what an INSTALLED BOX must carry: the daemon's sourced/running scripts PLUS the operator
#      instruments a box is expected to answer questions with — not every one is executed) must be
#      PRESENT, and every SHIPPED FILE present must be hash-identical to canonical. This is the half
#      that caught `gh-limit.py` sitting one generation behind on the live box while 36 of 37 other
#      files matched — so the compared set must include the non-`.sh` payload, which is what makes
#      that claim true (see DEPLOY_SET).
#
# EXIT CODES — the same vocabulary as check-deployed-drift.sh, for the same reason:
#   0  every requested assertion passed
#   1  DIVERGENCE (a fork exists, a file is missing, or bytes differ)
#   2  UNKNOWN — the check could not run, or it was asked to check nothing. NEVER a pass.
#
# ⛔ `--require-target` IS THE CI FORM. Without it, a run given no fork and finding no deployed copy
# would assert only canonical completeness and exit 0 — an inert gate that reports protection while
# it compares nothing. CI passes --require-target so "nothing to compare" is a failure there.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The files whose divergence caused the measured incident. Kept as a list, not a glob: adding a file
# to the harness is a decision, and the check should follow the decision rather than every new file.
# `harness-refresh.sh` is in it for the same reason (agent-infra#2215): a box whose copy of it is
# MISSING or one generation behind either cannot re-pin at all or re-pins on a stale comparison — the
# class this whole list exists for, and the one that ran unobserved for hours on the cells.
# `worker-terminal.sh` is in it because it is the ONE launcher/census/kill surface (#1702/#2210): a box
# whose copy is missing or older spawns lanes on a transient terminal or counts 0 workers.
SHARED="orch-loop.sh harness-refresh.sh spawn-gate.sh refresh-candidates.sh claims.sh nonblocking-dispatch.sh worker-terminal.sh lane.sh install.sh selftest.sh"
# ⛔ THE FORK ARM'S SCOPE IS THIS LIST, AND THE EXCLUSIONS ARE NAMED — NOT SILENT (review P1). The arm
# can only detect a fork of a file it lists, so a file left out is a fork this check cannot see. That
# was invisible: the output said "retired location holds no harness scripts" while MOST of the harness
# scripts were outside the list (the exact count moves as files are added — do NOT pin an integer
# here: the first cut of this comment said "8 of 41 at this head" and was ALREADY WRONG at the head it
# shipped on, which is the stale-measurement class this file exists to catch), and the CI non-vacuity
# step plants `lane.sh`, so it cannot expose the gap either.
# `merge-one.sh` is the ONE exclusion that is DELIBERATE and must stay: tortoise keeps it because it
# carries the unported #8484/#8589 detached-reviewer fix (README §11), so listing it here would fail
# the real retired location for holding a copy that is still the only home of that fix. Every other
# *.sh is covered by the DEPLOYED arm's byte comparison; the fork arm is a curated set on purpose.
SHARED_EXCLUDED_NOTE="fork arm covers the curated SHARED set (${SHARED// /, }); merge-one.sh is deliberately excluded — tortoise still holds the only copy of the unported #8484/#8589 fix (README section 11)"
# ⛔ PRESENCE-REQUIRED AT $O IS THE EXECUTED SET, NOT EVERY *.sh (review round 2, P2). MOST of these are
# what the daemon sources or runs as `$O/<script>`; a few (install.sh, merged-not-closed.sh,
# check-deployed-drift.sh, check-port-drift.sh, adopt-fix.sh) are operator surfaces a box must CARRY
# while nothing executes them on the daemon's behalf. The list is "what an installed box must have",
# not "what runs", and the DIVERGENCE message says so; `selftest.sh` and `*.test.sh` are developer instruments that a
# deployed box legitimately need not carry — requiring them reported ~24 DIVERGENCEs, 7 of them
# about files no daemon executes, and told the operator "this box cannot run it" about a test suite.
# Byte COMPARISON still covers every *.sh that IS present, which is what keeps the F5 gain (a stale
# repo-slug.sh / report.sh / dispatch-merge.sh is still caught).
# UNION of both sides of this merge — neither list is a superset. This branch adds lane-merge.sh and
# merge-rate.sh (#2029); origin/main adds brief-gate.sh (#2258) and repo-target.sh (#2724/#2694). A file
# executed from the installed $O that is absent from this list is a divergence nothing byte-compares.
EXECUTED="orch-loop.sh harness-refresh.sh rail-refusal.sh spawn-gate.sh brief-gate.sh refresh-candidates.sh claims.sh nonblocking-dispatch.sh worker-terminal.sh lane.sh lane-merge.sh lane-bound.sh merge-rate.sh install.sh report.sh repo-authority.sh repo-slug.sh repo-target.sh live-ownership.sh ci-queue.sh dispatch-merge.sh chain-merge.sh merge-one.sh fix-one.sh adopt-fix.sh merged-not-closed.sh check-deployed-drift.sh check-port-drift.sh harness-provenance.sh"
# …`harness-provenance.sh` joins the OPERATOR-SURFACE half of this list on the same test as
# `check-deployed-drift.sh`: nothing on the daemon runs it, and the operator is told to run it from the
# DEPLOYED tree — `bash ~/orchestrator/harness-provenance.sh show --o ~/orchestrator` is README §4.3's
# one-line answer to "which commit is this box running?". So a `$O` that was deployed by a ref
# predating it has NO way to answer that question, and the only two instruments that could say so are
# this presence arm and `check-deployed-drift.sh` (which byte-compares a copy that is PRESENT, so an
# ABSENT one is silent). "The tool that answers the question is missing" is the fail-open direction:
# the operator's command fails to resolve while every gate stays green.
# …`lane-merge.sh` and `merge-rate.sh` are presence-required because install.sh seeds BOTH into `$O`
# (the DRIFTED list) and a lane's brief EXECUTES `$O/lane-merge.sh` from the tree the daemon installed —
# so a `$O` missing it makes every lane's merge phase exit 127. merge-rate.sh is carried for the same
# reason (install.sh seeds it and the harness's own suites/operators run it from `$O`); neither is a
# developer-only instrument like the `*.test.sh` files excluded below. This list byte-compares only
# files that are PRESENT, so before this change an absent lane-merge.sh produced NO divergence.
# `brief-gate.sh` (origin/main, #2258) is presence-required for the same class: it is the RESEARCH
# validator lane.sh/fix-one.sh/merge-one.sh execute, and a $O predating it makes each of them refuse.
# `repo-target.sh` (origin/main, #2724/#2694) is presence-required for the same class one layer down.
# …and `rail-refusal.sh` is here for the same reason `live-ownership.sh` is: the daemon SOURCES it
# (orch-loop.sh reads the record, merge-one.sh and the cell doctor write it). A `$O` without it makes
# every rail refusal invisible to the red-fixer role — a quiet loss of the whole role, not a crash.
# ⛔ `brief-gate.sh` IS PRESENT-REQUIRED FOR THE STRONGEST VERSION OF THIS REASON (#2258): it is
# EXECUTED (not merely sourced) by `lane.sh`, `fix-one.sh`, `merge-one.sh`, `nonblocking-dispatch.sh`,
# `orch-send.sh` and `safe-send.sh`, and every one of those callers fails CLOSED (78, cannot verify)
# when it is absent. So a $O without it is not a degraded box, it is a box that dispatches NOTHING —
# and the operator needs to be told that by name, at install time, rather than by watching five lanes
# refuse in a row and guessing whether the brief or the harness is at fault.
# ⛔ `live-ownership.sh` IS IN THIS LIST BECAUSE THE DAEMON SOURCES IT (review P1). orch-loop.sh does
# `source $O/live-ownership.sh` for the ownership predicate that decides whether the box works its PR
# queue or opens new issues, and install.sh carries an explicit warning about a `$O` copy left at a
# pre-selection revision. Leaving it out of the presence list meant a deployment MISSING it passed this
# arm — the same "no record of the file that is gone" shape check-deployed-drift.sh's shipped-surface
# half exists to close, reproduced one instrument over. Presence is about EXECUTION, so the test is
# "does the daemon source/run it", not "did anyone think of it".
# `ci-queue.sh` (#2296) is here on exactly that test: orch-loop.sh AND dispatch-merge.sh source
# `$O/ci-queue.sh` (#2927 removed `fix-one.sh`'s — repair does not read the queue), so a box without it
# loses the CI-queue gate on both remaining surfaces at once —
# and every one of their interface guards would treat the missing module as "inert" rather than broken.
# ⛔ `lane-bound.sh` IS HERE ON THE SAME TEST, AND ITS ABSENCE IS THE DEGRADED-BUT-SILENT CASE (2026-10-27).
# `run_agent` executes `$O/lane-bound.sh` for EVERY lane's lifetime bound; a `$O` without it does not
# crash — it degrades to the pre-change wall-clock-only watchdog and says so in the lane log. That is
# the right runtime behaviour (a version skew must not halt every lane) and exactly why the missing file
# must be a DIVERGENCE here: "degraded loudly" is still degraded, and this arm is the only place an
# operator is told BEFORE the first stalled lane that the bound is not installed.

FORKS=(); O_DIR=""; REQUIRE_TARGET=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fork) [ $# -ge 2 ] || { echo "check-single-source: --fork needs a path" >&2; exit 2; }
            FORKS+=("$2"); shift 2 ;;
    --o)    [ $# -ge 2 ] || { echo "check-single-source: --o needs a path" >&2; exit 2; }
            O_DIR="$2"; shift 2 ;;
    --require-target) REQUIRE_TARGET=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) awk 'NR>1 && /^set -u$/{exit} NR>1{print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-single-source: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$O_DIR" ] || O_DIR="${O:-}"

note() { [ "$QUIET" -eq 1 ] || echo "$@"; }
bad()  { echo "$@" >&2; }
problems=0
diverge() { bad "DIVERGENCE: $*"; problems=$((problems + 1)); }
unknown() { bad "UNKNOWN: $*"; bad "  cannot verify the harness has a single source — this is NOT a pass"; exit 2; }

# sha256, portably: macOS ships `shasum`, most Linux images ship `sha256sum`.
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
else unknown "neither sha256sum nor shasum is on PATH"; fi
hash_of() { $SHA "$1" 2>/dev/null | awk '{print $1}'; }

# ── 1. CANONICAL COMPLETENESS ────────────────────────────────────────────────────
# The loop also counts the SIZE OF THE SHARED SET, so the fork arm's "ok" line can name the set it
# actually looked for. That is NOT `checked_canon` (the files that were FOUND): with one canonical file
# missing the arm still looks for all of them, and printing the found-count there made the line say
# "none of the 7 fork-arm files" while listing 8 — a wrong scope claim on the very line whose job is
# to state the scope (review P2).
checked_canon=0
shared_total=0
for f in $SHARED; do
  shared_total=$((shared_total + 1))
  if [ ! -f "$HERE/$f" ]; then
    diverge "canonical copy is MISSING $f — a source of truth missing a file is not the source of truth"
  else
    checked_canon=$((checked_canon + 1))
  fi
done
[ "$checked_canon" -gt 0 ] || unknown "no shared files found in $HERE — is this the harness directory?"

# ⛔ "ABSENT" vs "DID NOT RESOLVE" NEEDS A WALK, NOT A ONE-LINER (review P1, cycle 10). `test -L "$p"`
# is FALSE for a path written with a TRAILING SLASH (the shell strips it) and `test -e` is false for
# BOTH an absent path and one whose ANCESTOR is a dangling link — so `--o /tmp/x/dangling/` and
# `--o /tmp/x/dangling/child` both took the clean "no deployed copy" branch and exited 0. This answers
# the question directly: walk up until something exists, and if what exists is a symlink, the path did
# not resolve. Prints `present`, `dangling`, `unreadable` or `absent` (nothing else) — FOUR states,
# and the fourth is load-bearing: an existing-but-unsearchable ancestor is what `stat` SUCCEEDS on, so
# a three-state contract would have both callers read it as `absent` (review P2: the contract said
# three while the function had already grown a fourth, which is how the next reader mis-calls it).
_resolve_state() {
  local p="${1:-}"
  case "$p" in '') printf 'absent\n'; return 0 ;; esac
  while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
  # ⛔ ORDER MATTERS, AND IT IS THE OPPOSITE OF WHAT IT LOOKS LIKE (review P2, cycle 11). A RESOLVING
  # symlink ancestor is the macOS `/tmp -> /private/tmp` shape: testing `-L` first made a genuinely
  # absent child read as `dangling` and invented "a symlink on the way to it is broken". `-e` first
  # answers the real question ("is there something here?"), and `-L` is only consulted when `-e` says no
  # — which is exactly the broken-link case.
  [ -e "$p" ] && { printf 'present\n'; return 0; }
  [ -L "$p" ] && { printf 'dangling\n'; return 0; }
  local q="$p"
  while [ "$q" != "/" ] && [ "$q" != "." ] && [ -n "$q" ]; do
    q="$(dirname "$q" 2>/dev/null)" || { printf 'absent\n'; return 0; }
    [ -z "$q" ] && break
    [ -e "$q" ] && {
      # ⛔ AN ANCESTOR THAT EXISTS BUT CANNOT BE SEARCHED IS NOT "ABSENT" (review P2, cycle 11): `stat`
      # on an untraversable directory SUCCEEDS, so `--fork /root/orchestrator` as a non-root user said
      # "retired location is absent" and exited 0 — the same class as the two P1s above, one ancestor
      # out. 'unreadable' is a fourth state, and both callers answer UNKNOWN for it.
      if [ ! -x "$q" ] || [ ! -r "$q" ]; then printf 'unreadable\n'; else printf 'absent\n'; fi
      return 0
    }
    [ -L "$q" ] && { printf 'dangling\n'; return 0; }
  done
  printf 'absent\n'
}

# ── 2. NO RESURRECTED FORK ───────────────────────────────────────────────────────
# A fork is any of the SHARED files existing at a retired location. Presence of a README pointer is
# the intended state and is deliberately NOT a finding.
targets=0
for fork in ${FORKS[@]+"${FORKS[@]}"}; do
  [ -n "$fork" ] || continue
  # ⛔ A PATH THAT EXISTS BUT DOES NOT RESOLVE IS NOT "ABSENT" (review P1, cycles 9-10). A dangling
  # SYMLINK fails `[ ! -e ]`, and so does ANY path whose ANCESTOR is a dangling link — and `-L` does not
  # see either when the path is written with a TRAILING SLASH. README §11 recommends exactly this
  # symlink-into-a-checkout shape, so the state is reachable by design; `_resolve_state` walks the
  # parents instead of guessing from one test.
  case "$(_resolve_state "$fork")" in
    dangling) unknown "--fork target '$fork' does not RESOLVE (a symlink on the way to it is broken) — it is not an absent location (not a pass)" ;;
    unreadable) unknown "--fork target '$fork' has a parent this user cannot search — absence cannot be established (not a pass)" ;;
    absent)
      # An ABSENT retired location is the goal, not a gap — but it is also not a comparison, so it
      # does not count toward --require-target.
      note "ok: retired location is absent ($fork)"
      continue ;;
  esac
  # ⛔ AN EXISTING PATH THAT IS NOT A DIRECTORY IS NOT "ABSENT" (review P2, cycle 6). `[ ! -d ]` was
  # true for a regular FILE, so `--fork <path/to/lane.sh>` printed "retired location is absent" and
  # exited 0 having compared nothing — the empty-directory defect at line 116, one shape over, and
  # `bin/harness doctor` inherited it as `forks: ok`. A target the check cannot compare is UNKNOWN.
  if [ ! -d "$fork" ]; then
    unknown "--fork target '$fork' exists but is not a directory — cannot compare it (not a pass)"
  fi
  # ⛔ AN UNSEARCHABLE DIRECTORY IS NOT "NO FORK" EITHER (review P2, cycle 8). `[ -f "$fork/$f" ]` is
  # false both when the file is absent AND when the directory cannot be searched, so a retired tree at
  # mode 000 printed "holds none of the 8 fork-arm files" and exited 0 — measured with a real planted
  # lane.sh inside it. The DEPLOYED arm fails closed on the same unreadable path; the two arms must not
  # disagree about one unreadable directory.
  if [ ! -r "$fork" ] || [ ! -x "$fork" ]; then
    unknown "--fork target '$fork' exists but is not SEARCHABLE ($(ls -ld "$fork" 2>/dev/null | cut -c1-10 || echo 'mode unreadable')) — cannot determine whether a fork is there (not a pass)"
  fi
  # ⛔ …AND A DIRECTORY COMPARED WITH ITSELF IS NOT A COMPARISON (review P2, cycle 8 — the twin of the
  # `--o` guard). `--fork <the harness dir>` (or a symlink farm into it, the shape README §11
  # recommends) condemned every file and told the operator to "delete it", naming the canonical copy it
  # had just condemned. Fail-closed, but a message that names the source of truth as the thing to delete
  # is how a good guard gets switched off.
  if [ "$(cd "$fork" 2>/dev/null && pwd -P)" = "$(cd "$HERE" && pwd -P)" ]; then
    unknown "--fork target '$fork' IS this script's canonical directory — a fork check against itself would condemn the source of truth (not a pass)"
  fi
  # ⛔ AN EXISTING BUT EMPTY DIRECTORY IS NOT A COMPARISON (review finding, P2). Counting the
  # DIRECTORY let `--require-target --fork <empty dir>` exit 0 having compared zero files — the
  # "gate that checks nothing" this whole PR is about, reproduced inside the gate. A target is
  # counted only when at least one shared file is actually present and compared.
  fork_files=0
  for f in $SHARED; do
    [ -f "$fork/$f" ] || continue
    fork_files=$((fork_files + 1))
    # Byte-identical is still a fork: the point is that no second copy is READ from.
    diverge "retired fork has reappeared: $fork/$f ($(hash_of "$fork/$f" | cut -c1-12))  → delete it; the canonical copy is $HERE/$f"
  done
  [ "$fork_files" -gt 0 ] && targets=$((targets + 1))
  # ⛔ THE "ok" LINE NAMES WHAT WAS ACTUALLY LOOKED FOR (review P1, cycle 2). It used to say "holds no
  # harness scripts", which reads as "no fork here" when the arm had only looked for the curated SHARED
  # set — most of the harness scripts were outside it (8 of 41 at this head), so a fork of
  # `dispatch-merge.sh` alone printed ok and exited 0. The scope is part of the answer, on the same line, in every mode (including --quiet,
  # which suppresses note() — hence the plain echo). The set stays curated: `merge-one.sh` is the
  # DELIBERATE exclusion named on the same line, and the deployed arm byte-compares every `*.sh`.
  [ "$fork_files" -eq 0 ] && echo "ok: $fork holds none of the ${shared_total} fork-arm files ($(printf '%s\n' $SHARED | paste -sd, - 2>/dev/null || printf '%s\n' $SHARED | tr '\n' ',')) — merge-one.sh deliberately excluded (tortoise keeps the only copy of the unported #8484/#8589 fix, README §11). SCOPE: this arm looks ONLY at those files, at the paths you passed; a fork of any OTHER harness script at a retired path is NOT detected by it — and naming another --fork path does not widen it, because the loop only ever looks for THIS set inside the paths given (no filesystem walk on purpose, #1069)"
done

# ── 3. THE DEPLOYED COPY IS THE SAME BYTES ───────────────────────────────────────
# ⛔ THE DEPLOYED ARM COMPARES EVERY SHIPPED SCRIPT, NOT JUST THE 8 (review finding, P2). The 8 are
# the files whose divergence caused the measured incident, and that is the right set for the
# FORK arm — but the deployed copy is executed as `$O/<script>`, so a stale repo-slug.sh,
# dispatch-merge.sh or adopt-fix.sh is just as broken as a stale lane.sh, and check-deployed-drift.sh
# already compares all of them. Listing only 8 made this arm answer a WEAKER question than the
# instrument beside it and report "identical" where that one reports drift.
DEPLOY_SET=()
# ⛔ THE SHIPPED PAYLOAD IS NOT ALL `*.sh` (review P2, this round — a FALSE PASS, and a false one about
# the very file this arm's header names). `for f in "$HERE"/*.sh` excluded `gh-limit.py` and
# `gh-rest/gh`: both are shipped, both are executed by the daemon, both are on `install.sh`'s DRIFTED
# list, and the header says this is the half that caught `gh-limit.py` one generation behind. Measured
# at this head: a deployed copy identical except a one-line append to `gh-limit.py` (and then to
# `gh-rest/gh`) exited 0 and printed "one source of truth"; appending to `spawn-gate.sh` in the same
# tree exited 1, which proves the arm was live and the glob was the gap. So the compared set is the
# PAYLOAD, not an extension: every regular file beside this script, plus the two shipped subdirectory
# entries. (Bounded to one directory and two known subpaths — this is not the #1069 filesystem walk.)
# ⛔ AND `gh-limit/gh` IS PART OF IT (review P1, re-review round — the widening stopped one file
# short of completing its own claim). Both platforms seed it into `$O/gh-limit/gh`
# (cloud-cell-supervisor.sh:1242; deploy-mac-orchestrator.sh:115 copies the whole entry) and every
# cell controller puts `$O/gh-limit` FIRST on PATH, so a stale deployed copy is executed on every
# gh call. Measured at this head: a deployed tree identical except a one-line append to
# `gh-limit/gh` printed "ok: one source of truth" and exited 0, while the same append to
# `gh-limit.py` exited 1. Neither `check-deployed-drift.sh` (which globs `*.sh`) nor `install.sh`'s
# DRIFTED list covered it, so nothing else would have caught it. The compared set is therefore the
# shipped payload as `install.sh`'s DRIFTED list enumerates it, `gh-limit/gh` included; anything
# else beside this script (a nested dir beyond these two, a test fixture) is NOT compared.
# ⛔ AND THE SET IS AN ARRAY, NOT A WHITESPACE-JOINED STRING (review P2, round 4 — a FALSE PASS). It was
# accumulated with unquoted word-splitting and re-split at the comparison loop, so a shipped file whose
# NAME holds whitespace (legal POSIX; the shape Finder's "Duplicate" produces: `lane 2.sh`) became two
# tokens that name nothing, and `[ -f "$O_DIR/$f" ] || continue` skipped it SILENTLY. Measured with a
# live control: `spawn-gate.sh` diverged → rc 1 naming it; `hotfix 2.sh` diverged → rc 0, "ok: one source
# of truth". An array cannot split a name, and it needs no `sort -u` because the globs cannot overlap.
for f in "$HERE"/*.sh "$HERE"/*.py "$HERE"/gh-rest/gh "$HERE"/gh-limit/gh; do
  [ -f "$f" ] || continue
  DEPLOY_SET+=("${f#"$HERE"/}")
done
[ "${#DEPLOY_SET[@]}" -gt 0 ] || unknown "no shipped files found in $HERE — nothing to compare a deployment against (not a pass)"
if [ -n "$O_DIR" ]; then
  # ⛔ AND THE SAME SHAPES THE FORK ARM CLOSES: does-not-resolve (including a dangling ANCESTOR and a
  # trailing slash), non-directory, unsearchable (review P1/P2, cycles 8-10). The fork arm's comment
  # claimed the two arms agreed about an unreadable directory; measured, they did NOT — `--fork
  # <mode-000 dir>` answered UNKNOWN while `--o <the same dir>` answered eight DIVERGENCEs ("MISSING …
  # this box has no copy") and rc 1, and `doctor` then published `bytes=DIFFERS` for a directory it had
  # never read.
  _ostate="$(_resolve_state "$O_DIR")"
  if [ "$_ostate" = unreadable ]; then
    unknown "--o target '$O_DIR' has a parent this user cannot search — absence cannot be established (not a pass)"
  elif [ "$_ostate" = dangling ]; then
    unknown "--o target '$O_DIR' does not RESOLVE (a symlink on the way to it is broken) — it is not an absent deployment (not a pass)"
  elif [ "$_ostate" = absent ]; then
    note "ok: no deployed copy at $O_DIR (nothing to compare)"
  elif [ ! -d "$O_DIR" ]; then
    # ⛔ THE SAME SHAPE THE FORK ARM CLOSES, ONE LOOP OVER (review P2, cycle 7). `[ ! -d ]` reported a
    # regular FILE as "no deployed copy … nothing to compare" and exited 0: the operator asked "is this
    # deployment the canonical bytes?" about a path that is not a deployment, and got a clean answer.
    # `--require-target` catches it; the README's operator form does not pass it.
    unknown "--o target '$O_DIR' exists but is not a directory — cannot compare a deployment there (not a pass)"
  elif [ ! -r "$O_DIR" ] || [ ! -x "$O_DIR" ]; then
    unknown "--o target '$O_DIR' exists but is not SEARCHABLE ($(ls -ld "$O_DIR" 2>/dev/null | cut -c1-10 || echo 'mode unreadable')) — a directory it could not read is not eight missing files (not a pass)"
  elif [ "$(cd "$O_DIR" 2>/dev/null && pwd -P)" = "$(cd "$HERE" && pwd -P)" ]; then
    # ⛔ COMPARING CANONICAL WITH ITSELF IS NOT A COMPARISON (review P2, cycle 7). This script SHIPS to
    # $O, so the natural question on a deployed box — `$O/check-single-source.sh --o $O`, or the
    # script's own dir — made canonical == target, reported `targets compared: 1`, and stayed green even
    # after a stale edit to the very file under test. `pwd -P` so a symlinked $O still resolves.
    unknown "--o target is this script's own canonical directory ($HERE) — a self-comparison proves nothing (not a pass)"
  else
    targets=$((targets + 1))
    # Presence: the executed set. Bytes: every *.sh that is actually there.
    for f in $EXECUTED; do
      [ -f "$O_DIR/$f" ] && continue
      # ⛔ NOT EVERY ENTRY IN EXECUTED IS DAEMON-EXECUTED (review P2, cycle 4; corrected cycle 7).
      # `merged-not-closed.sh` is an operator instrument — nothing sources or execs it — and it is in the
      # list because a deployment without it cannot answer "which open issue already has a merged PR?".
      # (`check-single-source.sh` is deliberately NOT in the list: this very file is the answer to the
      # single-source question, so requiring it at $O would make the check depend on the copy it grades.)
      # The presence rule still applies to the listed files, but the message must not claim the daemon
      # runs them — and the copiers are the Mac copier / the cell's seed_and_stamp, NOT install.sh.
      diverge "the deployed copy at $O_DIR is MISSING $f — the installed surface is expected to carry it (the Mac copier deploy-mac-orchestrator.sh and the cell seed_and_stamp put the shipped set there) and this box has no copy"
    done
    for f in ${DEPLOY_SET[@]+"${DEPLOY_SET[@]}"}; do
      [ -f "$O_DIR/$f" ] || continue
      a="$(hash_of "$HERE/$f")"; b="$(hash_of "$O_DIR/$f")"
      [ -n "$a" ] && [ -n "$b" ] || unknown "could not hash $f (canonical='$a' deployed='$b')"
      [ "$a" = "$b" ] || diverge "the deployed copy DIFFERS from canonical: $f (canonical ${a:0:12} vs deployed ${b:0:12}) — re-install or make \$O a versioned checkout of agent-infra"
    done
  fi
fi

if [ "$REQUIRE_TARGET" -eq 1 ] && [ "$targets" -eq 0 ]; then
  unknown "--require-target was given but there was nothing to compare (no existing --fork, no deployed copy) — a gate that checks nothing must not pass"
fi

# ── 4. REPO IS SET ONCE PER BOX, NEVER DEFAULTED PER SCRIPT ──────────────────────
# ⛔ THE SAME DEFECT AS THE THREE FORKED DIRECTORIES, ONE VARIABLE OVER. The harness solved "which repo
# do we grade?" for `OR` exactly once (`repo-slug.sh`'s `derive_or`, called once by `orch-loop.sh`), and
# solved it for `REPO` zero times — so each script carried its own private default and three of them
# are WRONG on every box but the one they were written on:
#
#     report.sh            REPO="${REPO:-$HOME/eldato/tortoise}"   ONE DEVELOPER'S HOME DIRECTORY
#     deploy-crossbox.sh   REPO="${REPO:-/tmp/cell-ai}"           a CELL path, wrong on every laptop
#     pi-reap-worktrees.sh REPO="${REPO:-$PWD}"                   WORST: under launchd `$PWD` is `/`,
#                          a real directory that is not a repo, so the pass died as "not a git
#                          repository: /" several probes after the cause
#
# A default is only safe if it is TRUE ON EVERY MACHINE; none of those three is, and `$PWD` is not even
# stable across two runs of the same script. `REPO` is set ONCE per box (the launchd plist on a Mac,
# `keys.env` on a cell) and read through ONE resolver, `repo-slug.sh`'s `resolve_repo`, which refuses by
# name instead of guessing. So this arm forbids a PRIVATE PATH DEFAULT in any shipped script here.
# (Why the population is the harness dir PLUS the repo's `scripts/`: see the loop below.)
#
# WHAT IT DOES NOT FLAG, on purpose — each is a shape that is not this defect:
#   REPO="${REPO:-}"        an explicit "no default" (the shape to converge on)
#   REPO="${X:-}"           an EMPTY default of another variable supplies nothing either, at any depth
#   REPO="$1" / "$2"        assigned from a CALLER (fix-one.sh, merge-one.sh, chain-merge.sh, adopt-fix)
#   REPO=""                initialised empty, then filled by the "--repo" arm or by resolve_repo
#   REPO="$(resolve_repo)" the ONE resolver
#   REPO="$REPO"           re-asserting the operator's OWN value (`${REPO:?…}` is the loud form)
#   a COMMENT mentioning a default     prose is how the defect gets recorded; punishing it deletes the
#                                      record (the same rule the fork arm's prose exemption states)
#   a SLUG default (`…:-owner/name`)   a different defect (REPO is the CHECKOUT PATH, never a slug);
#                                      the shape rule for a slug is repo_slug_valid's, not this arm's
#   a SLUG literal (`REPO="owner/name"`) and a REPO SLUG QUERIED FROM THE REMOTE
#                                      (`$(command gh repo view … nameWithOwner)`) — owner/name is
#                                      never a wrong checkout path, so it is not what this arm refuses
#   a variable THIS FILE ASSIGNS, and a substitution derived from one (`REPO="$L_DIR"`,
#                                      `REPO="$(cd "$cand" && pwd -P)"`, `REPO="$1"; OR="$2"`):
#                                      the value is something the script already MEASURED, not an
#                                      ambient guess. This is the carve-out that keeps every legitimate
#                                      spelling in the shipped population green — the population was
#                                      enumerated with `rg -n 'REPO=' scripts/ …` before the rule was
#                                      narrowed, and each of its ~15 shapes is pinned in a suite arm
#   a COMMAND'S ASSIGNMENT PREFIX (`REPO="$TMP/x" O="$TMP/o" env … bash foo`): the caller supplying
#                                      the value for ONE invocation — the `REPO="$1"` class, not a default
#   a `case` PATTERN (`REPO=*|OR=*|…)`)  a match expression, not an assignment of a value
#   a TEST fixture (`*.test.sh`)       a developer instrument, not a shipped surface — the deployed arm
#                                      already excludes them for the same reason, and a fixture whose
#                                      repo is "/repo" is not operator advice
# Non-vacuity: the arm counts the files it opened and answers UNKNOWN when it opened none, because a
# `REPO` scan that scanned nothing is the inert-gate failure this whole script exists to catch.
# ⛔ THE PENALTY IS A DIVERGENCE (rc 1), not UNKNOWN (rc 2): the harness still has one source — it has
# a script that will point a box at a path it does not have, which is a finding about the artefact.
# `repo_path_default_hits <file>` — prints `file:line: <that line>` per REPO path default. Portability:
# plain POSIX awk, no gawk extensions (CI runs GNU awk, macOS runs BSD awk).
repo_path_default_hits() {
  awk '
    BEGIN { q39 = sprintf("%c", 39) }                     # a single quote, without one in this program
    function pathish(v) {
      # ⛔ BOTH SPELLINGS ARE CHECKED (#3054 review, P2). `\$HOME` is the LITERAL `$HOME`; it does not
      # match `${HOME}`, so matching only the bare form let the exact default this PR removes be
      # re-written one brace away and pass the gate — the "a PR or an agent can defeat it" class.
      # `index()` is used rather than an ERE `\$\{?HOME\}?` because `{` is an interval expression in
      # POSIX awk and BSD/GNU awk differ on escaping it; a substring test cannot be mis-parsed.
      if (v ~ /\$HOME/ || v ~ /\$PWD/) return 1     # $HOME/…, $PWD
      if (index(v, "${HOME}") || index(v, "${PWD}")) return 1   # ${HOME}/…, ${PWD}
      if (v ~ /^\// || v ~ /^~/ || v ~ /^\.\//) return 1  # an absolute, home-relative or ./ path
      return 0
    }
    # ⛔ THE QUESTION IS "IS THERE A DEFAULT", NOT "DOES IT LOOK LIKE A PATH" (#3054 review, P1).
    # Asking the second let every default spelled as ANOTHER VARIABLE through: `$AI` (which IS
    # `/tmp/cell-ai` via the same default in deploy-crossbox.sh — this defect one variable over),
    # `$CELL_HOME/tortoise`, `$O/x`, `$TMPDIR/x`, `$(pwd)`, and any `local`/`readonly` spelling.
    # The rule this PR states is that a default is only safe if it is TRUE ON EVERY MACHINE, so the
    # only defaults that are not a finding are: NO default (empty), a SLUG (what `OR` takes), or the
    # one resolver. Anything else is a private decision about where the repo lives, which is exactly
    # what this arm exists to refuse.
    function allowed_default(v) {
      if (v == "") return 1                              # `${REPO:-}` — no default at all
      if (v == "$(resolve_repo)") return 1                 # the ONE resolver
      if (v ~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/) return 1 # a slug, as `OR` takes
      return 0
    }
    # ⛔ THE SAME QUESTION, NOW ASKED OF THE PLAIN-ASSIGNMENT SPELLING (#3054 review, P1).
    # `allowed_default` above was reached ONLY inside the `${REPO:-…}` branch, so the arm graded the
    # `:-` spelling and not `REPO=<value>` — and the two disagreed on the SAME defect: MEASURED at
    # 637c21c19 with the fixtures planted in `scripts/`, `REPO="${REPO:-$PWD}"` reddened (rc 1) while
    # `REPO="$AI"` and `REPO="$(pwd)"` both passed GREEN (rc 0, "scanned 63+94") — over a live
    # private path default, one token from the defect this PR removes (`AI="${AI:-/tmp/cell-ai}"` is
    # the old default in deploy-crossbox.sh). `$(pwd)` is the exact form the comment above named as
    # covered, so the comment and the code disagreed — the same defect class as the gap.
    # A value is therefore sanctioned only if it comes from a place the BOX decides (an empty default,
    # a positional, the one resolver), is not a path at all (a slug, a `case` pattern), or is a value
    # THIS FILE already holds (`own[]`, collected below) — anything else is a private guess.
    function sanctioned(v,  e, p, rest, nm, named, unknown) {
      # An EMPTY default supplies nothing, at any depth: `${GH_REPO:-}`, `${A:-${B:-}}`.
      e = v; p = ""
      while (e != p) { p = e; sub(/\$\{[A-Za-z_][A-Za-z0-9_]*:?-\}/, "", e) }
      if (e == "") return 1
      if (v ~ /^\$\(resolve_repo\)/) return 1                    # the ONE resolver (also `|| exit $?`)
      if (v ~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/) return 1       # a slug literal
      # a SLUG DEFAULT — the exemption `allowed_default` already makes, so the two spellings agree:
      # `${FLEET_REPO:-daniel-ospina/agent-infra}` is a different defect (REPO-as-SLUG), not a path.
      if (v ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*:?-[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\}$/) return 1
      if (v ~ /^[*?[]/ || index(v, "|") > 0) return 1              # a `case` PATTERN, not a value
      # An ASSIGNMENT PREFIX ON A COMMAND (`REPO="$TMP/x" O="$TMP/o" env …`): the caller supplies the
      # value for ONE invocation — the `REPO="$1"` class. Recognised by a second `NAME=` after the
      # first word.
      if (v ~ /^("[^"]*"|[^ \t]*)[ \t]+[A-Za-z_][A-Za-z0-9_]*=/) return 1
      # Every NAMED expansion must be one this file already holds (`$1`-`$9` are not named and are
      # caller-supplied). `$AI`/`$TMPDIR`/`$CELL_HOME` are assigned NOWHERE in the file that reads
      # them → they are AMBIENT, i.e. a private default one variable over.
      if (!ownready) collect_own()
      rest = v; named = 0; unknown = 0
      while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
        named++
        nm = substr(rest, RSTART, RLENGTH)
        sub(/^\$\{?/, "", nm)
        rest = substr(rest, RSTART + RLENGTH)
        if (nm != "REPO" && !(nm in own)) unknown = 1
      }
      if (named) return !unknown
      if (index(v, "$(") == 0) return 1          # positionals and literals only
      # A COMMAND SUBSTITUTION THAT READS NOTHING is computed from AMBIENT state — `$(pwd)` is the
      # `$PWD` default one indirection over. One carve-out: a value ASKED OF THE REMOTE for the
      # owner/name slug (`nameWithOwner`) is never a wrong checkout path.
      if (index(v, "nameWithOwner") || index(v, "repo view")) return 1
      return 0
    }
    # The names THIS file assigns, collected the FIRST TIME a REPO value actually needs them — the
    # scan is over the whole file (because `REPO="$L_DIR"` may be set hundreds of lines after
    # `L_DIR=`), and only the handful of files whose REPO value is an expansion need it at all, so it
    # is collected lazily rather than re-reading all 157 shipped scripts to grade a dozen. Loop
    # variables (`for cand in …`) and `read` targets count as assignments.
    # A line whose first non-space char is `#` is skipped and a bare-word comment is cut, so a variable
    # merely MENTIONED in prose is not mistaken for one the file holds. ⚠️ This is a textual rule about
    # the FILE, so a file that merely SPELLS `AI=` (inside a string, say) widens the carve-out for the
    # rest of that file. That direction is deliberate and named rather than silent: the alternative —
    # refusing every `REPO="$WORD"` — reddens ~15 legitimate spellings in the shipped population
    # (`$L_DIR`, `$RAIL_REPO`, `$CWD_REPO`, `$repo_path`, `$HERE/../..`, `${_main:-$cand}`), and a gate
    # that refuses honest trees is how a gate gets switched off. The shapes it must NOT refuse are
    # pinned in selftest.sh, and the shapes it MUST flag in the M5 arm of repo-slug.test.sh.
    function collect_own(  aline, a, w, nw, rd, i, nm) {
      split("", own)
      while ((getline aline < FILENAME) > 0) {
        if (aline ~ /^[ \t]*#/) continue
        a = aline
        sub(/[ \t]#.*$/, "", a)
        nw = split(a, w, /[ \t;(){}&|]+/)
        rd = 0
        for (i = 1; i <= nw; i++) {
          if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { nm = w[i]; sub(/=.*/, "", nm); own[nm] = 1 }
          else if (w[i-1] == "for" && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) own[w[i]] = 1
          else if (w[i] == "read") rd = 1
          else if (rd && w[i] !~ /^-/ && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) own[w[i]] = 1
        }
      }
      close(FILENAME)
      ownready = 1
    }
    FNR == 1 { ownready = 0 }
    {
      ln = $0
      sub(/^[ \t]+/, "", ln)
      if (ln ~ /^#/) next                                 # a comment is not a default
      # A DECLARATION PREFIX IS NOT AN EXEMPTION (#3054 review, P1): `local REPO="/tmp/x"` and
      # `readonly REPO=…` were invisible because only `export` was stripped. Strip any of them,
      # repeatedly (so `local -r REPO=` is seen too), then require the assignment itself.
      while (ln ~ /^(export|local|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+/)
        sub(/^(export|local|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+/, "", ln)
      if (ln !~ /^REPO=/) next
      val = ln
      sub(/^REPO=/, "", val)                              # the value, without the assignment
      sub(/[ \t]+$/, "", val)
      # ⛔ A TRAILING COMMENT IS NOT PART OF THE VALUE (#3054 review, P1). `REPO="/tmp/cell-ai" # a
      # cell path` is exactly how someone re-introduces this defect WITH an explanation, and it walked
      # through: the comment stops the value ending in a quote, so the quote-strip below never ran and
      # the value never looked like a path. Strip the comment — but only when what remains is
      # QUOTE-BALANCED, because `REPO="/x # y"` is ONE path that happens to contain a hash and
      # cutting it there would hide it instead.
      vnc = val
      if (sub(/[ \t]+#.*$/, "", vnc)) {
        nq = 0
        for (i = 1; i <= length(vnc); i++)
          if (substr(vnc, i, 1) == "\"" || substr(vnc, i, 1) == q39) nq++
        if (nq % 2 == 0) val = vnc
      }
      # One layer of MATCHING quotes off, so `${REPO:-…}` is seen as the expansion it is (and not as a
      # string that happens to start with a quote). A value quoted only on one side is left alone.
      q = substr(val, 1, 1)
      if ((q == "\"" || q == q39) && length(val) > 1 && substr(val, length(val), 1) == q)
        val = substr(val, 2, length(val) - 2)
      if (val ~ /^\$\{REPO:?-.*\}$/) {                  # ${REPO:-<default>} / ${REPO-<default>}
        inner = val
        sub(/^\$\{REPO:?-/, "", inner)
        sub(/\}$/, "", inner)
        if (allowed_default(inner)) next                   # no default, a slug, or the resolver: not this arm
        print FILENAME ":" FNR ": " $0
        next
      }
      # The two spellings must agree, so the plain-assignment branch asks the SAME question the
      # `${REPO:-…}` branch asks: not "does it look like a path" (which missed `$AI` and `$(pwd)`)
      # but "is this value the decision of the BOX, or a guess by this script".
      if (pathish(val)) { print FILENAME ":" FNR ": " $0; next }
      if (index(val, "$") > 0 && !sanctioned(val)) print FILENAME ":" FNR ": " $0
    }
  ' "$@"
}
# The scripts that STILL carry a path default, kept NAMED so the debt is visible instead of the arm
# being narrowed silently. Every entry is pre-existing and is somebody's separate fix; the arm PRINTS
# them on every run (below) so an operator reads "2 scripts still default REPO", never "REPO is clean".
# ⛔ Deleting an entry is what FIXING the file looks like; adding one is how this arm gets defeated, and
# an entry whose file no longer carries a default is reported as stale.
REPO_DEFAULT_KNOWN="cloud-cell-doctor.sh lane-container-reap.sh stale-main-triage.sh stale-worktrees.sh worktree-hygiene-sweep.sh"
# ⛔ THE POPULATION IS TWO DIRECTORIES, NOT ONE — and the second is not optional. Two of the three
# offenders live in the repo's `scripts/` (`pi-reap-worktrees.sh`, `deploy-crossbox.sh`), so a scan of
# this directory alone left this arm blind to the very file it was written for: measured, re-introducing
# `REPO="${REPO:-$PWD}"` into the reaper reddened NOTHING. The `scripts/` half is scanned only where
# `$HERE/../orchestrator-harness` IS this directory (a checkout); in the flat `$O` that path does not
# exist, `$HERE/..` is `$HOME`, and reading an operator's home for harness scripts would be a different
# and wrong claim — the arm says which half it scanned instead of implying both.
repo_arm_parent=""
_repo_parent="$(cd "$HERE/.." 2>/dev/null && pwd -P)" || _repo_parent=""
if [ -n "$_repo_parent" ] && [ -d "$_repo_parent/orchestrator-harness" ] \
   && [ "$(cd "$_repo_parent/orchestrator-harness" 2>/dev/null && pwd -P)" = "$(cd "$HERE" && pwd -P)" ]; then
  repo_arm_parent="$_repo_parent"
fi
repo_scanned_here=0
repo_scanned_parent=0
repo_known_hits=""
# ⛔ THE SECOND WORD IS QUOTED, AND THAT IS LOAD-BEARING (verification finding, round 2).
# `for _dir in "$HERE" $repo_arm_parent` WORD-SPLITS the parent path, so a checkout under a directory
# with a space in its name (`/Volumes/My Passport/agent-infra` — the shape `bin/harness`'s own comments
# call ordinary) silently scanned only the harness half, exited 0 over a planted
# `REPO="${REPO:-$PWD}"` in `scripts/pi-reap-worktrees.sh`, and printed the opposite of the truth
# ("nothing to scan there"). Quoted, with the empty case skipped explicitly, which is what the unquoted
# form was reaching for.
for _dir in "$HERE" "$repo_arm_parent"; do
  [ -n "$_dir" ] || continue
for f in "$_dir"/*.sh; do
  [ -f "$f" ] || continue
  case "${f##*/}" in *.test.sh) continue ;; esac        # developer instruments, not shipped surfaces
  if [ "$_dir" = "$HERE" ]; then repo_scanned_here=$((repo_scanned_here + 1)); else repo_scanned_parent=$((repo_scanned_parent + 1)); fi
  _base="${f##*/}"
  case " $REPO_DEFAULT_KNOWN " in
    *" $_base "*)
      _hits="$(repo_path_default_hits "$f")"
      if [ -n "$_hits" ]; then
        _first_line="$(printf '%s\n' "$_hits" | head -1 | cut -d: -f2)"
        repo_known_hits="$repo_known_hits $_base:$_first_line"
      else
        note "note: $_base no longer carries a REPO path default — delete its entry from REPO_DEFAULT_KNOWN in $0"
      fi
      continue ;;
  esac
  # ⛔ READ WITH A HEREDOC, NOT A PIPE: a `… | while read` loop runs in a SUBSHELL, so `diverge` would
  # increment a copy of `problems` and the arm could never make the check red — the inert-gate failure
  # inside the arm that exists to catch it.
  while IFS= read -r _hit; do
    [ -n "$_hit" ] || continue
    # ⛔ NO BACKTICKS IN THIS MESSAGE. It is a double-quoted string, so `…` would be COMMAND
    # SUBSTITUTION: measured on a planted hit, the line rendered "(and  is  under launchd)" — the
    # REASON deleted — and executed the cwd and `/` as commands. A diagnostic that corrupts itself
    # exactly on the red it exists to explain, and looks fine on every green run.
    diverge "REPO has a PRIVATE path default: $_hit — REPO is set ONCE per box (the launchd plist on a Mac, keys.env on a cell) and read through repo-slug.sh's resolve_repo, which REFUSES by name. A per-script default points every other box at a path it does not have, and \$PWD is / under launchd, which is a real directory that is not a repo."
  done <<EOF
$(repo_path_default_hits "$f")
EOF
done
done
[ "$repo_scanned_here" -gt 0 ] || unknown "no shipped *.sh found in $HERE — the REPO-default arm compared NOTHING (not a pass)"
# ⛔ PER-DIRECTORY COUNTS, but a NOTE — not UNKNOWN — when the second directory holds no shipped script.
# The counts exist because one combined total hides a whole half dropping out (deploy-harness.test.sh's
# floor lesson). The absence itself is legitimate: a fixture (selftest.sh's `bin/harness doctor` tree is
# exactly this) may copy `scripts/orchestrator-harness/` into an otherwise empty `scripts/`, and failing
# that closed turned three unrelated doctor arms red for a layout that scans cleanly. The narrowing this
# guards against is pinned where it belongs — the selftest arm that PLANTS a default in `scripts/*.sh`
# and requires a red — because a gate that refuses an honest tree is how a gate gets switched off.
if [ -n "$repo_arm_parent" ] && [ "$repo_scanned_parent" -eq 0 ]; then
  note "note: $(basename "$repo_arm_parent")/ beside the harness holds no other shipped *.sh — nothing to scan there (the harness-dir half was scanned)"
fi
# Printed in EVERY mode, including --quiet, for the same reason the fork arm's scope line is: the debt
# is part of the answer, and a `--quiet` run that omits it reads as "no defaults anywhere".
[ -z "$repo_known_hits" ] || echo "note: pre-existing REPO path defaults are NAMED, not silently allowed:$repo_known_hits — each is a separate fix; delete its REPO_DEFAULT_KNOWN entry when it lands"
if [ -n "$repo_arm_parent" ]; then
  note "ok: the REPO path-default arm scanned $repo_scanned_here shipped script(s) in $HERE and $repo_scanned_parent in ${repo_arm_parent##*/}/ (see the fork arm above for what it does NOT cover)"
else
  note "ok: the REPO path-default arm scanned $repo_scanned_here shipped script(s) in $HERE ONLY — $HERE/.. is not this harness's scripts/ dir, so the scripts/*.sh half was NOT scanned here"
fi

if [ "$problems" -gt 0 ]; then
  bad "FAIL: $problems divergence(s) — the harness has more than one source."
  bad "  canonical: $HERE"
  bad "  A fix applied to a copy is not a fix: port it HERE, then re-run this check."
  exit 1
fi
note "ok: one source of truth — $checked_canon shared file(s) in $HERE, targets compared: $targets"
note "    $SHARED_EXCLUDED_NOTE"
exit 0
