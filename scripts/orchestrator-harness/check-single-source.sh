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
#      (what the daemon actually sources/runs) must be PRESENT, and every `*.sh` present must be
#      hash-identical to canonical. This is the half that caught `gh-limit.py` sitting one generation
#      behind on the live box while 36 of 37 other files matched.
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
SHARED="orch-loop.sh spawn-gate.sh refresh-candidates.sh claims.sh nonblocking-dispatch.sh lane.sh install.sh selftest.sh"
# ⛔ THE FORK ARM'S SCOPE IS THIS LIST, AND THE EXCLUSIONS ARE NAMED — NOT SILENT (review P1). The arm
# can only detect a fork of a file it lists, so a file left out is a fork this check cannot see. That
# was invisible: the output said "retired location holds no harness scripts" while 18 of 26 *.sh were
# outside the list, and the CI non-vacuity step plants `lane.sh`, so it cannot expose the gap either.
# `merge-one.sh` is the ONE exclusion that is DELIBERATE and must stay: tortoise keeps it because it
# carries the unported #8484/#8589 detached-reviewer fix (README §11), so listing it here would fail
# the real retired location for holding a copy that is still the only home of that fix. Every other
# *.sh is covered by the DEPLOYED arm's byte comparison; the fork arm is a curated set on purpose.
SHARED_EXCLUDED_NOTE="fork arm covers the curated SHARED set (${SHARED// /, }); merge-one.sh is deliberately excluded — tortoise still holds the only copy of the unported #8484/#8589 fix (README section 11)"
# ⛔ PRESENCE-REQUIRED AT $O IS THE EXECUTED SET, NOT EVERY *.sh (review round 2, P2). The daemon
# runs `$O/<script>` for these; `selftest.sh` and `*.test.sh` are developer instruments that a
# deployed box legitimately need not carry — requiring them reported ~24 DIVERGENCEs, 7 of them
# about files no daemon executes, and told the operator "this box cannot run it" about a test suite.
# Byte COMPARISON still covers every *.sh that IS present, which is what keeps the F5 gain (a stale
# repo-slug.sh / report.sh / dispatch-merge.sh is still caught).
EXECUTED="orch-loop.sh spawn-gate.sh refresh-candidates.sh claims.sh nonblocking-dispatch.sh lane.sh install.sh report.sh repo-authority.sh repo-slug.sh live-ownership.sh dispatch-merge.sh chain-merge.sh merge-one.sh fix-one.sh adopt-fix.sh merged-not-closed.sh check-deployed-drift.sh check-port-drift.sh"
# ⛔ `live-ownership.sh` IS IN THIS LIST BECAUSE THE DAEMON SOURCES IT (review P1). orch-loop.sh does
# `source $O/live-ownership.sh` for the ownership predicate that decides whether the box works its PR
# queue or opens new issues, and install.sh carries an explicit warning about a `$O` copy left at a
# pre-selection revision. Leaving it out of the presence list meant a deployment MISSING it passed this
# arm — the same "no record of the file that is gone" shape check-deployed-drift.sh's shipped-surface
# half exists to close, reproduced one instrument over. Presence is about EXECUTION, so the test is
# "does the daemon source/run it", not "did anyone think of it".

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
checked_canon=0
for f in $SHARED; do
  if [ ! -f "$HERE/$f" ]; then
    diverge "canonical copy is MISSING $f — a source of truth missing a file is not the source of truth"
  else
    checked_canon=$((checked_canon + 1))
  fi
done
[ "$checked_canon" -gt 0 ] || unknown "no shared files found in $HERE — is this the harness directory?"

# ── 2. NO RESURRECTED FORK ───────────────────────────────────────────────────────
# A fork is any of the SHARED files existing at a retired location. Presence of a README pointer is
# the intended state and is deliberately NOT a finding.
targets=0
for fork in ${FORKS[@]+"${FORKS[@]}"}; do
  [ -n "$fork" ] || continue
  if [ ! -d "$fork" ]; then
    # An ABSENT retired location is the goal, not a gap — but it is also not a comparison, so it
    # does not count toward --require-target.
    note "ok: retired location is absent ($fork)"
    continue
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
  # set — 17 of the 26 *.sh were outside it, so a fork of `dispatch-merge.sh` alone printed ok and
  # exited 0. The scope is part of the answer, on the same line, in every mode (including --quiet,
  # which suppresses note() — hence the plain echo). The set stays curated: `merge-one.sh` is the
  # DELIBERATE exclusion named on the same line, and the deployed arm byte-compares every `*.sh`.
  [ "$fork_files" -eq 0 ] && echo "ok: $fork holds none of the ${checked_canon} fork-arm files ($(printf '%s\n' $SHARED | paste -sd, - 2>/dev/null || printf '%s\n' $SHARED | tr '\n' ',')) — merge-one.sh deliberately excluded (tortoise keeps the only copy of the unported #8484/#8589 fix, README §11); the other files are covered by the --o byte arm"
done

# ── 3. THE DEPLOYED COPY IS THE SAME BYTES ───────────────────────────────────────
# ⛔ THE DEPLOYED ARM COMPARES EVERY SHIPPED SCRIPT, NOT JUST THE 8 (review finding, P2). The 8 are
# the files whose divergence caused the measured incident, and that is the right set for the
# FORK arm — but the deployed copy is executed as `$O/<script>`, so a stale repo-slug.sh,
# dispatch-merge.sh or adopt-fix.sh is just as broken as a stale lane.sh, and check-deployed-drift.sh
# already compares all of them. Listing only 8 made this arm answer a WEAKER question than the
# instrument beside it and report "identical" where that one reports drift.
DEPLOY_SET=""
for f in "$HERE"/*.sh; do
  [ -f "$f" ] || continue
  DEPLOY_SET="$DEPLOY_SET $(basename "$f")"
done
DEPLOY_SET="$(printf '%s\n' $DEPLOY_SET | sort -u | tr '\n' ' ')"
if [ -n "$O_DIR" ]; then
  if [ ! -d "$O_DIR" ]; then
    note "ok: no deployed copy at $O_DIR (nothing to compare)"
  else
    targets=$((targets + 1))
    # Presence: the executed set. Bytes: every *.sh that is actually there.
    for f in $EXECUTED; do
      [ -f "$O_DIR/$f" ] && continue
      diverge "the deployed copy at $O_DIR is MISSING $f — the daemon executes \$O/<script>, so this box cannot run it"
    done
    for f in $DEPLOY_SET; do
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

if [ "$problems" -gt 0 ]; then
  bad "FAIL: $problems divergence(s) — the harness has more than one source."
  bad "  canonical: $HERE"
  bad "  A fix applied to a copy is not a fix: port it HERE, then re-run this check."
  exit 1
fi
note "ok: one source of truth — $checked_canon shared file(s) in $HERE, targets compared: $targets"
note "    $SHARED_EXCLUDED_NOTE"
exit 0
