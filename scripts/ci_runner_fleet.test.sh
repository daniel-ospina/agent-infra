#!/usr/bin/env bash
# ci_runner_fleet.test.sh — hermetic suite for scripts/ci_runner_fleet.sh (agent-infra#2429).
#
# Run: bash scripts/ci_runner_fleet.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. NO network, NO `gh`, NO `cmux`, NO real cell:
# the exec transport (`RUNNER_FLEET_EXEC`) is a stub that replays a fixture block and exits with a
# fixture rc, `gh` is a stub on PATH, and the roster is the fixture list. It runs in BOTH bash lanes
# (scripts/run-bash-shards.sh), on the cells' mawk as well as gawk.
#
# WHY THESE CASES — each one is a clause of #2429, or a fail-open that would defeat it:
#   * the four facts PER CELL (registered names, listener count, live/offline, memory reading) — the
#     clause-1 answer, aggregated from the per-box tool rather than re-probed here;
#   * BOTH DIRECTIONS OF DISAGREEMENT (#2429 clause 2): a local registration GitHub does not have
#     (`unregistered`) and a GitHub registration no local pool carries (`registry-unclaimed`). A test
#     that only ever asserted one direction would pass against a build that sums the two sources;
#   * the CLAIM KEY IS THE agentName, not the instance directory. MEASURED on `pi-cell-5`: directory
#     `gh-runner-x64-2` carries agentName `pi-runner-c5-x64-2`. Matching on the directory name
#     reports a healthy runner as BOTH an unregistered local row and a phantom registration, i.e. two
#     defects on a perfect box;
#   * FAIL-CLOSED ON AN UNREADABLE CELL (#2429 clause 3): `cannot-measure`, never "0 runners". The
#     mutant at the end deletes the measured-gate and must make this case FAIL — a suite that passes
#     against a build that publishes `slots=0` for an unreachable box pins nothing;
#   * ATTRIBUTION IS BOUNDED BY WHAT WAS MEASURED: while any cell is unmeasured, a registry name no
#     cell claims is `cannot-attribute`, NOT a phantom. Calling it a phantom sends an operator to
#     `reclaim` a registration that is serving jobs on the box nobody could read;
#   * a `--box` the roster does not carry and an unreadable ROSTER are both refusals, because the
#     alternative is `cells=0` + exit 0 — a clean bill of health built from nothing;
#   * the ROOT RETRY is driven by the refusal's own `outside=` list, happens ONCE, never overrides a
#     root a human pinned, and does NOT resolve an ambiguity it cannot satisfy (two parents);
#   * MUTANTS at the end prove FIVE assertions are live: the measured gate, the producer-rc gate, the
#     attribution guard, the claim key, and the registry-side `unjoinable` counter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/ci_runner_fleet.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
# ⛔ THE NEGATIVE OF assert_contains: "the report does not claim X" is a statement about ABSENCE, and a
# case that only asserts presence passes just as happily against a build that also prints the wrong line.
assert_omits() { case "$1" in *"$2"*) bad "$3 (unexpectedly present: $2)" ;; *) ok "$3" ;; esac; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-fleet-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$T" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

BIN="$T/bin"; mkdir -p "$BIN"
export FIXTURE="$T/fixture"; mkdir -p "$FIXTURE"
export FLEET_CALLS="$T/calls.log"; : >"$FLEET_CALLS"

# ── the transport stub ──────────────────────────────────────────────────────────────────────────
# ⛔ IT MODELS THE REAL ARGV SHAPE, because that is the contract the report binds to:
#     <stub> <box> -- sh -lc '<snippet>'
# The snippet is INSPECTED (not executed), so the root-derivation arm can assert what the reporter
# would have sent. A stub that ignored argv would pass while the shipped template produced
# `cmux vm exec {box --}` — which is exactly the bug the two-step FLEET_EXEC default exists for.
cat >"$BIN/stub-exec" <<'STUB'
#!/usr/bin/env bash
# argv: <box> -- sh -lc <snippet>
box="$1"; snip="${5:-}"   # argv: <box> -- sh -lc <snippet>
root=""; Q="'"
case "$snip" in *"RUNNER_ROOT=$Q"*) root="${snip#*RUNNER_ROOT=$Q}"; root="${root%%$Q*}" ;; esac
printf '%s\t%s\n' "$box" "${root:--}" >>"$FLEET_CALLS"
base="$FIXTURE/$box"
[ -z "$root" ] || [ ! -f "$base.root.out" ] || base="$base.root"
out="$base.out"
if [ ! -f "$out" ]; then
  echo "cmux: link to '$box' exited; see ~/.cmux/peer-links/$box.log" >&2
  exit 3
fi
cat "$out"
if [ -f "$base.rc" ]; then exit "$(cat "$base.rc")"; fi
exit 0
STUB
chmod +x "$BIN/stub-exec"

# ── the registry stub ──────────────────────────────────────────────────────────────────────────
cat >"$BIN/stub-gh" <<'STUB'
#!/usr/bin/env bash
# argv: api --paginate repos/<owner/name>/actions/runners?per_page=100 --jq <filter>
# Only the endpoint is read; `--jq @tsv` output is replayed verbatim from the fixture.
ep=""
for a in "$@"; do case "$a" in repos/*/actions/runners*) ep="$a" ;; esac; done
[ -n "$ep" ] || { echo "stub-gh: no runners endpoint in argv" >&2; exit 2; }
repo="${ep#repos/}"; repo="${repo%%/actions/runners*}"
if [ -f "$FIXTURE/gh.fail" ]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
f="$FIXTURE/gh.$(echo "$repo" | tr '/' '_')"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$BIN/stub-gh"

export RUNNER_FLEET_GH="$BIN/stub-gh"
export RUNNER_FLEET_EXEC="$BIN/stub-exec {box} --"
export RUNNER_FLEET_REPOS="o/a o/b"
export RUNNER_FLEET_TIMEOUT=10
export CAP_CMUX_BIN="$BIN/no-such-cmux"   # the roster is a fixture unless a case says otherwise
# ⛔ ABSOLUTE, because the mutant copies below are written OUTSIDE this checkout and resolve
# `SELF_DIR/orchestrator-harness/capacity.sh` against themselves — without this they would exit 2
# (`capacity-lib-absent`) and every mutation arm would read as "the mutation changed nothing".
export CAPACITY_LIB="$SCRIPT_DIR/orchestrator-harness/capacity.sh"

RC=0
OUT=""
run_fleet() {  # run_fleet [args…] — the report's stdout+stderr into $OUT, its rc into $RC
  OUT="$("$@" 2>&1)"; RC=$?
}

# world <name> — reset the fixture tree (every case owns its own cells/registry/rc).
world() {
  rm -f "$FIXTURE"/*
  : >"$FLEET_CALLS"
  # ⛔ BOTH registries start EMPTY-AND-READABLE. An empty registry is a real reading (a repo whose jobs
  # run on GitHub-hosted runners); a MISSING fixture models a 404, i.e. CANNOT MEASURE, and must be
  # opted into by the one case that is about it — otherwise every case inherits an unmeasured fleet.
  : >"$FIXTURE/gh.o_a"; : >"$FIXTURE/gh.o_b"
}

# cell <label> <rc> <block>  — a fixture pool block, exactly as ci_runner_pool.sh status prints it.
cell() {
  printf '%s\n' "$3" >"$FIXTURE/$1.out"
  printf '%s\n' "$2" >"$FIXTURE/$1.rc"
}
# reg <repo> <name> <status> <busy>…
reg() {
  local f="$FIXTURE/gh.$(echo "$1" | tr '/' '_')"; shift
  : >>"$f"
  while [ "$#" -ge 2 ]; do printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$f"; shift 3; done
}
# block <host> <ncpu> <ceiling> <slots> <mem> <floor> <rows> <live> <dead> <orph> <qn> <regs> <tdef>
block() {
  printf 'host=%s ncpu=%s ceiling=%s slots=%s mem_available=%s MB (14.04 GB) floor=%s MB (3.50 GB)\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
  printf '%-32s %-9s %-9s %s\n' NAME LISTENER STATE GITHUB_NAME
  [ -n "$7" ] && printf '%s\n' "$7"
  printf 'summary live=%s dead=%s slots=%s ceiling=%s pool_read=process-table-live-only orphaned=%s registrations=%s quarantine=%s tmpdir_defects=%s\n' \
    "$8" "$9" "$4" "$3" "${10}" "${12}" "${11}" "${13}"
}

echo "── ci_runner_fleet: the per-cell report (#2429) ────────────────────────────────────────────"

# ══ A. THE FOUR FACTS, PER CELL, AND A CLEAN VERDICT ════════════════════════════════════════════
world
export RUNNER_FLEET_BOXES="cell-a cell-b"
cell cell-a 0 "$(block cell-a 8 3 2 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1
gh-runner-a-2            222       live      pi-runner-a-2" 2 0 0 0 2 0)"
cell cell-b 0 "$(block cell-b 4 2 2 9000 3584 "gh-runner-b-1            333       live      pi-runner-b-1
gh-runner-b-2            334       live      pi-runner-b-2" 2 0 0 0 2 0)"
reg o/a pi-runner-a-1 online false pi-runner-a-2 online true pi-runner-b-1 online false
reg o/b pi-runner-b-2 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 0 "A: every cell measured and every registration claimed => exit 0"
assert_contains "$OUT" "cell label=cell-a read=ok host=cell-a ncpu=8 ceiling=3 slots=2 mem_available_mb=14375 floor_mb=3584" \
  "A: the cell line carries the box's OWN readings (host, cores, ceiling, slots, MEMORY, floor)"
assert_contains "$OUT" "runner cell=cell-a name=gh-runner-a-1 github_name=pi-runner-a-1 listener=111 local=live github=online" \
  "A: a registered name, its listener pid and its GitHub state are reconciled on ONE row"
assert_contains "$OUT" "runner cell=cell-a name=gh-runner-a-2 github_name=pi-runner-a-2 listener=222 local=live github=online busy=true" \
  "A: busy-ness comes from the registry (the local view cannot know it)"
assert_contains "$OUT" "cell label=cell-b read=ok host=cell-b ncpu=4 ceiling=2 slots=2 mem_available_mb=9000" \
  "A: a SECOND cell is reported with ITS OWN memory reading and ceiling, not the first cell's"
assert_contains "$OUT" "verdict=ok" "A: a row that both sources agree on is ok"
assert_contains "$OUT" "summary cells=2 measured=2 unmeasured=0 skipped=0 registry=4 registry_unread=0 claimed=4 unclaimed=0 unregistered=0 unjoinable=0" \
  "A: the summary reconciles the two sources — no name is counted twice, across BOTH registries"
assert_omits "$OUT" "cannot-measure" "A: nothing is reported unmeasured when everything was read"

# ══ B. AN UNREADABLE CELL IS cannot-measure, NEVER "0 runners" (#2429 clause 3) ═════════════════
world
export RUNNER_FLEET_BOXES="cell-a cell-y"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
# cell-y: the transport refuses — no fixture block at all, so the stub exits 3 with its own line
reg o/a pi-runner-a-1 online false pi-runner-y-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "B: a cell that could not be read => exit 2 (cannot measure), not 0 and not 3"
assert_contains "$OUT" "cell label=cell-y read=cannot-measure why=transport-unreachable rc=3" \
  "B: the unreadable cell is NAMED, with the failure class and the transport's own rc"
assert_contains "$OUT" "detail=cmux: link to 'cell-y' exited" \
  "B: the transport's own diagnostic travels with the row (the next step depends on which failure)"
assert_omits "$OUT" "cell label=cell-y read=ok" "B: an unreadable cell is never rendered as a measured one"
assert_omits "$OUT" "slots=0" "B: an unreadable pool never reads as an EMPTY pool (the #2381 class)"
# the registry name only cell-y could claim must NOT be called a phantom
assert_contains "$OUT" "registry-unclaimed name=pi-runner-y-1 registry=o/a status=online reason=cannot-attribute(1-cell-unmeasured)" \
  "B: while a cell is unmeasured, an unclaimed name is cannot-attribute — never a phantom"
assert_omits "$OUT" "no-running-cell-claims-it" "B: no phantom is claimed from an incomplete fleet"
assert_contains "$OUT" "measured=1 unmeasured=1" "B: the summary counts BOTH sides"

# ══ C. THE OTHER DIRECTION: a registration no measured cell carries IS a phantom (all measured) ══
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-lost-9 offline false
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "C: a measured fleet that does not account for a registration => exit 3"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-lost-9 registry=o/a status=offline reason=no-running-cell-claims-it" \
  "C: the registration that lost its box is named, with the reason a measured fleet supports"
assert_contains "$OUT" "unclaimed=1" "C: the summary counts it"

# ══ D. A LOCAL REGISTRATION GITHUB DOES NOT HAVE (the /tmp-wipe's mirror image) ═════════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-9            999       live      pi-runner-gone-9" 1 0 0 0 1 0)"
reg o/a
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "D: a listener whose registration is absent from the registry => exit 3"
assert_contains "$OUT" "runner cell=cell-a name=gh-runner-a-9 github_name=pi-runner-gone-9 listener=999 local=live github=ABSENT" \
  "D: the row says ABSENT for the registry side instead of inventing a status"
assert_contains "$OUT" "verdict=unregistered" "D: and its verdict is unregistered (this install cannot serve a job)"
assert_contains "$OUT" "unregistered=1" "D: the summary counts it"

# ══ E. THE CLAIM KEY IS THE agentName, NOT THE INSTANCE DIRECTORY ═══════════════════════════════
# MEASURED on pi-cell-5: /opt/gh-runner-x64-2 carries agentName pi-runner-c5-x64-2.
world
export RUNNER_FLEET_BOXES="cell-5"
cell cell-5 0 "$(block cell-5 16 6 1 21000 3584 "gh-runner-x64-2          471879    live      pi-runner-c5-x64-2" 1 0 0 0 1 0)"
reg o/a pi-runner-c5-x64-2 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 0 "E: dir name != agentName on a healthy box is NOT a defect"
assert_contains "$OUT" "runner cell=cell-5 name=gh-runner-x64-2 github_name=pi-runner-c5-x64-2 listener=471879 local=live github=online busy=false" \
  "E: claimed by agentName — the identity GitHub knows"
assert_omits "$OUT" "verdict=unregistered" "E: the directory name is never used as the claim key"
assert_omits "$OUT" "registry-unclaimed" "E: and the registration is not reported as a phantom either"

# ══ F. THE TWO DISAGREEMENTS THE RECONCILIATION EXISTS FOR ══════════════════════════════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 2 14375 3584 "gh-runner-dead            -         DEAD      pi-runner-dead
gh-runner-unconn          777       live      pi-runner-unconn" 1 1 0 0 2 0)"
reg o/a pi-runner-dead online false pi-runner-unconn offline false
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "F: a dead listener and a live-but-offline runner => exit 3"
assert_contains "$OUT" "name=gh-runner-dead github_name=pi-runner-dead listener=- local=DEAD github=online busy=false registry=o/a verdict=dead-listener" \
  "F: GitHub says online while the box says DEAD — the incident #2373 measured, named as dead-listener"
assert_contains "$OUT" "name=gh-runner-unconn github_name=pi-runner-unconn listener=777 local=live github=offline" \
  "F: a live listener GitHub reports offline is its own row, not a silent 'ok'"
assert_contains "$OUT" "verdict=github-offline" "F: and its own verdict"
assert_contains "$OUT" "disagreements=2" "F: the summary counts the disagreements between the two sources"

# ══ G. AN UNREADABLE REGISTRY IS cannot-measure, NOT "0 registrations" ══════════════════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
: >"$FIXTURE/gh.fail"
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "G: an unreadable registry => exit 2"
assert_contains "$OUT" "registry repo=o/a read=cannot-measure why=registry-unreadable" "G: the registry half reports its own failure"
assert_omits "$OUT" "registry repo=o/a read=ok runners=0" "G: a refused registry never reads as an EMPTY one"
assert_omits "$OUT" "registry-unclaimed" "G: and nothing is attributed as a phantom from a read that did not happen"
# ⛔ THE JOIN DIRECTION (review P2-7): the registry LINE being honest is not enough — the local row must
# not be turned into a defect the unread registry could neither confirm nor deny.
assert_contains "$OUT" "verdict=cannot-attribute" "G: a local row that cannot be joined is an abstention"
assert_omits "$OUT" "verdict=unregistered" "G: an unread registry NEVER fabricates an unregistered runner"
assert_contains "$OUT" "registry_unread=2" "G: the summary counts BOTH unread registries on their OWN counter"
assert_contains "$OUT" "unjoinable=1" "G: and the unjoinable row on its own too"

# ══ H. A --box THE ROSTER DOES NOT CARRY IS A REFUSAL ═══════════════════════════════════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "" 0 0 0 0 0 0)"
reg o/a
run_fleet bash "$FLEET" --box cell-typo
assert_eq "$RC" 2 "H: an unresolvable --box => exit 2, never a smaller fleet"
assert_contains "$OUT" "cell label=cell-typo read=cannot-measure why=box-not-in-roster" "H: and the missing box is named"

# ══ I. AN UNREADABLE ROSTER IS A REFUSAL (no provider CLI, no explicit roster) ══════════════════
world
unset RUNNER_FLEET_BOXES
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "I: no roster => exit 2"
assert_contains "$OUT" "cell roster=cannot-measure why=roster-unreadable" "I: the roster half reports its own failure with the reason"
assert_contains "$OUT" "summary cells=UNKNOWN" "I: and the summary says UNKNOWN, never cells=0"
export RUNNER_FLEET_BOXES="cell-a cell-b"

# ══ J. THE ROOT RETRY: DRIVEN BY THE REFUSAL'S OWN outside= LIST, ONCE ══════════════════════════
world
export RUNNER_FLEET_BOXES="cell-4"
cell cell-4 2 "cmux: link to 'cell-4' exited
cannot-measure why=pool-root-incomplete root=/tmp/actions-runner outside=/opt/gh-runner-x64-1,/opt/gh-runner-x64-2 — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT"
printf '%s\n' "$(block cell-4 8 3 1 12000 3584 "gh-runner-4-1            444       live      pi-runner-cell4-x64-1" 1 0 0 0 1 0)" >"$FIXTURE/cell-4.root.out"
printf '0\n' >"$FIXTURE/cell-4.root.rc"
reg o/a pi-runner-cell4-x64-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 0 "J: a refused root is retried from the parent the refusal NAMED, and the cell then measures"
assert_contains "$OUT" "cell-note label=cell-4 root_derived=/opt" "J: the retry is STATED, not silent"
assert_contains "$OUT" "cell label=cell-4 read=ok host=cell-4 ncpu=8" "J: the retried read is the one reported"
assert_eq "$(awk -F'\t' '$1=="cell-4" {print $2}' "$FLEET_CALLS" | tr '\n' ' ')" "- /opt " \
  "J: exactly TWO probes, the second carrying RUNNER_ROOT=/opt"

# ══ K. TWO PARENTS CANNOT BE SATISFIED BY ONE ROOT — THE AMBIGUITY IS NOT RESOLVED BY PICKING ═══
world
export RUNNER_FLEET_BOXES="cell-4"
cell cell-4 2 "host=x
cannot-measure why=pool-root-incomplete root=/tmp/actions-runner outside=/opt/gh-runner-x64-1,/tmp/actions-runner/other — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT"
reg o/a
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "K: an ambiguous refusal stays cannot-measure"
assert_contains "$OUT" "cell label=cell-4 read=cannot-measure why=pool-root-incomplete" "K: and is reported as unmeasured, with the producer's own token"
assert_eq "$(wc -l <"$FLEET_CALLS" | tr -d ' ')" "1" "K: NO retry was attempted — one root cannot contain both parents"

# ══ L. A PINNED ROOT IS NEVER MOVED BY THIS TOOL ════════════════════════════════════════════════
world
export RUNNER_FLEET_BOXES="cell-4"
cell cell-4 2 "host=x
cannot-measure why=pool-root-incomplete root=/tmp/actions-runner outside=/opt/gh-runner-x64-1 — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT"
reg o/a
run_fleet bash "$FLEET" --root /tmp/actions-runner
assert_eq "$RC" 2 "L: a pinned root that fails is reported, not second-guessed"
assert_eq "$(awk -F'\t' '{print $2}' "$FLEET_CALLS" | tr '\n' ' ')" "/tmp/actions-runner " \
  "L: exactly ONE probe, carrying the operator's root"
assert_omits "$OUT" "root_derived=" "L: and no derived root was substituted for it"

# ══ M. A QUARANTINE ROW IS NOT A RUNNER (its 4th column is prose, not an agentName) ═════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1
old-install.retired-1     -         QUARANTINE  retired install — rm -rf as its owner" 1 0 0 1 2 0)"
reg o/a pi-runner-a-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "M: a quarantined install is a named defect"
assert_contains "$OUT" "runner cell=cell-a name=old-install.retired-1 github_name=- listener=- local=QUARANTINE" \
  "M: the row is reported with NO github_name (the prose is not read as one)"
assert_omits "$OUT" "rm -rf as its owner" "M: and its remedy prose is not splattered into the report"
assert_omits "$OUT" "registry-unclaimed" "M: nor is it invented as a phantom registration"

# ══ N. A COMPLETE BLOCK WITH A NON-ZERO PRODUCER rc IS NOT A MEASUREMENT (review P1-1) ═════════
# `ci_runner_pool.sh status` exits 2 for "a PARTIAL MEASUREMENT" — `pool-root-incomplete` and an
# UNPROBED quarantine both print a FULL block (host, rows, summary) AND exit 2, saying in the tool's
# own words that `slots=` "counts a PARTIAL pool". Keying "measured" on the block alone certified
# exactly that: `read=ok … rc=2`, `unmeasured=0`, `not_ok=0` → exit 0.
world
export RUNNER_FLEET_BOXES="cell-partial"
cell cell-partial 2 "$(block cell-partial 8 3 1 14375 3584 "gh-runner-p-1            111       live      pi-runner-p-1" 1 0 0 0 1 0)
cannot-measure why=pool-root-incomplete root=/tmp/actions-runner outside=/opt/gh-runner-p-1,/tmp/other — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT"
reg o/a pi-runner-p-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "N: a complete block behind a rc=2 producer read => exit 2"
assert_contains "$OUT" "cell label=cell-partial read=cannot-measure why=pool-root-incomplete rc=2" \
  "N: the producer's OWN refusal token names the reason"
assert_omits "$OUT" "read=ok host=cell-partial" "N: a partial pool is never rendered as a measured one"
assert_omits "$OUT" "verdict=ok" "N: and none of its rows is certified healthy"

# ══ O. A REGISTRY STATUS THE REPORT CANNOT CLASSIFY IS A DEFECT, NEVER "ok" (review P1-2) ═══════
# `gh … @tsv` renders a null `.status` as an EMPTY FIELD (`name<TAB><TAB>false`). A whitespace split
# collapsed that to `name false`, the polarity test `= offline` fell through, and a runner whose
# registry row could not be read was printed `github=false … verdict=ok`.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
printf 'pi-runner-a-1\t\tfalse\n' >"$FIXTURE/gh.o_a"
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "O: an unclassifiable registry status => exit 3"
assert_contains "$OUT" "github=unread busy=false registry=o/a verdict=github-unreadable" \
  "O: the row says UNREAD (not ABSENT, not ok) and names the verdict"
assert_omits "$OUT" "verdict=ok" "O: an empty status field is never agreement"

# ══ P. A LINE THE PARSER CANNOT CLASSIFY MAKES THE BLOCK UNPARSEABLE (review P2-6) ══════════════
# An instance directory whose name contains a space was split into NAME=my / LISTENER=runner /
# STATE=111, printed as a fabricated row, and the REAL registration it carried was reported as a
# PHANTOM on a fully measured fleet — the exact harm clause 2's attribution rule exists to prevent.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "host=cell-a ncpu=8 ceiling=3 slots=1 mem_available=14375 MB (14.04 GB) floor=3584 MB (3.50 GB)
NAME                             LISTENER  STATE     GITHUB_NAME
my runner 111 live pi-runner-a-1
summary live=1 dead=0 slots=1 ceiling=3 pool_read=process-table-live-only orphaned=0 registrations=1 quarantine=0 tmpdir_defects=0"
reg o/a pi-runner-a-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "P: an unclassifiable line => exit 2, never a fabricated row"
assert_contains "$OUT" "read=cannot-measure why=block-unparseable rc=0 unclassified=1 detail=my runner 111 live pi-runner-a-1" \
  "P: the cell is refused, and the offending line is quoted"
assert_omits "$OUT" "verdict=quarantine" "P: no row is invented from it"
assert_omits "$OUT" "reason=no-running-cell-claims-it" "P: and no phantom is claimed from a fleet with a refused cell"

# ══ Q. A defect TOKEN is carried verbatim, so the remedy it names is the one printed (review P3-8) ═
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 1)
defect tmpdir-mode=755 name=gh-runner-a-1 path=/opt/a/_tmp — exists but carries mode 755; run: chmod 700 /opt/a/_tmp"
reg o/a pi-runner-a-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "Q: a tmpdir defect => exit 3"
assert_contains "$OUT" "verdict=defect-tmpdir-mode:755" \
  "Q: the verdict names the MODE defect (remedy: chmod 700), not a missing root (remedy: restart)"
assert_omits "$OUT" "verdict=tmpdir-missing" "Q: and does not mislabel it as missing"

# ══ S. --box IS A SCOPE, NOT A CLAIM THAT THE REST OF THE FLEET DOES NOT EXIST (cycle-2 P1) ══════
# Leaving excluded boxes uncounted made the attribution guard read a scoped run as a COMPLETE one, so
# `--box cell-a` printed cell-b's registration as `registry-unclaimed … no-running-cell-claims-it`
# and exited 3 — advice whose printed remedy is `reclaim`, aimed at a live registration on a box
# nobody asked about.
world
export RUNNER_FLEET_BOXES="cell-a cell-b"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
cell cell-b 0 "$(block cell-b 4 2 1 9000 3584 "gh-runner-b-1            222       live      pi-runner-b-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-b-1 online false
run_fleet bash "$FLEET" --box cell-a
assert_eq "$RC" 0 "S: a scoped run over a healthy fleet is not a defect"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-b-1 registry=o/a status=online reason=cannot-attribute(1-cell-not-requested)" \
  "S: the excluded box's registration is an abstention, and the reason NAMES the exclusion"
assert_omits "$OUT" "no-running-cell-claims-it" "S: never a phantom, so never the destructive 'reclaim' advice"

# ══ T. A REPO SEAM THAT WORD-SPLITS TO NOTHING IS AN UNREAD REGISTRY (cycle-2 P2) ══════════════
# `RUNNER_FLEET_REPOS=" "` iterated zero times, the registry half vanished, and every healthy runner
# became `verdict=unregistered` — the class the malformed-token arm covers, one value over.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
run_fleet env RUNNER_FLEET_REPOS=" " bash "$FLEET"
assert_eq "$RC" 2 "T: an empty repo list => exit 2"
assert_contains "$OUT" "registry repo=- read=cannot-measure why=repo-list-empty" "T: the registry half names the empty seam"
assert_omits "$OUT" "verdict=unregistered" "T: and no healthy runner is turned into a defect by it"
assert_contains "$OUT" "registry_unread=1" "T: the unread registry is counted as one"

# ══ U. AN EMPTY ROSTER SEAM IS A REFUSAL, NOT A FLEET OF ZERO (cycle-2 P2) ══════════════════════
world
run_fleet env RUNNER_FLEET_BOXES=" " bash "$FLEET"
assert_eq "$RC" 2 "U: a whitespace-only roster => exit 2, never 'a clean bill of health from nothing'"
assert_contains "$OUT" "cell roster=cannot-measure why=roster-empty" "U: and the roster half says why"

# ══ V. ONE NAME IN TWO REGISTRIES CANNOT BE ATTRIBUTED TO BOTH (cycle-2 P2) ═════════════════════
# Runner names are unique PER REPO, and two registries are read by default: one local row matching one
# name used to count `claimed=2` and silently swallow the other registry's registration — the very
# lost-its-box class clause 2 exists for.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false
reg o/b pi-runner-a-1 offline false
run_fleet bash "$FLEET"
assert_contains "$OUT" "local=live github=unread busy=? registry=- verdict=cannot-attribute" \
  "V: the LOCAL row refuses to claim either registration (the per-box view does not name the repo)"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-a-1 registry=o/a status=online reason=cannot-attribute(name-carried-by-more-than-one-registry)" \
  "V: the first registry's registration is NAMED, not bound"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-a-1 registry=o/b status=offline reason=cannot-attribute(name-carried-by-more-than-one-registry)" \
  "V: so is the SECOND registry's — neither is swallowed"
assert_omits "$OUT" "name-collision" "V: and two repos' registrations are not a name collision"
assert_eq "$RC" 2 "V: an unattributable registration => exit 2"

# ══ W. THE PRODUCER'S OWN why= TOKEN SURVIVES THE rc-DERIVED ONE (cycle-2 P3) ════════════════════
# `pool-tool-absent` (a peer with no clone) was flattened to `pool-unreadable` — four different causes
# printed as one word a consumer must branch on.
world
export RUNNER_FLEET_BOXES="cell-a"
printf 'cannot-measure why=pool-tool-absent searched=/tmp/cell-ai:\$HOME/agent-infra\n' >"$FIXTURE/cell-a.out"
printf '2\n' >"$FIXTURE/cell-a.rc"
reg o/a
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "W: no clone on the peer => exit 2"
assert_contains "$OUT" "cell label=cell-a read=cannot-measure why=pool-tool-absent rc=2" \
  "W: the producer's own token is reported, not a generic one"

# ══ X. A DEFECT ROW THAT ALSO DISAGREES IS STILL A DISAGREEMENT (cycle-2 P3) ═════════════════════
# The `defect` arm sat before the offline arm, so `disagreements=0` was printed on a box that had one.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 3 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 1)
defect tmpdir-missing name=gh-runner-a-1 path=/opt/a/_tmp — the instance private temp root is missing"
reg o/a pi-runner-a-1 offline false
run_fleet bash "$FLEET"
assert_contains "$OUT" "local=live github=offline" "X: the row carries both facts"
assert_contains "$OUT" "verdict=defect-tmpdir-missing" "X: the defect names the row verdict"
assert_contains "$OUT" "disagreements=1" "X: and the disagreement is STILL counted (it is not the verdict's to hide)"

# ══ Y. THE REGISTRY SIDE ALONE MUST BE ABLE TO MAKE A FLEET UNCLEAN (round-5 P3) ════════════════
# `unjoinable` counts unattributable readings on BOTH sides. Before this case, only the LOCAL increment
# was pinned: deleting the registry-side one left the suite green while a fleet whose every
# registration is unattributable printed `unjoinable=0 not_ok=0` and exited 0 — a clean bill over two
# `cannot-attribute` registrations.
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 0 14375 3584 "" 0 0 0 0 0 0)"
reg o/a pi-runner-x-1 online false pi-runner-x-2 online false
reg o/b pi-runner-x-1 online false pi-runner-x-2 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "Y: no local row can claim any of these, so the fleet is not clean -- exit 2"
assert_contains "$OUT" "unjoinable=4" "Y: every unattributable reading is counted, on BOTH sides"
assert_omits "$OUT" "reason=no-running-cell-claims-it" "Y: and none of them is called a phantom"

# ══ Z. A `|` IN AN INSTANCE NAME IS UNCLASSIFIABLE, NOT A FABRICATED ROW (round-5 P3) ═══════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "host=cell-a ncpu=8 ceiling=3 slots=1 mem_available=14375 MB (14.04 GB) floor=3584 MB (3.50 GB)
NAME                             LISTENER  STATE     GITHUB_NAME
weird|dir 111 live pi-runner-pipe-1
summary live=1 dead=0 slots=1 ceiling=3 pool_read=process-table-live-only orphaned=0 registrations=1 quarantine=0 tmpdir_defects=0"
reg o/a pi-runner-pipe-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 2 "Z: a name carrying the record separator => exit 2"
assert_contains "$OUT" "read=cannot-measure why=block-unparseable" "Z: the cell is refused"
assert_omits "$OUT" "verdict=quarantine" "Z: no row is fabricated from it"
assert_omits "$OUT" "reason=no-running-cell-claims-it" "Z: and no phantom is claimed"

# ══ AA. A REPEATED LABEL IN THE EXPLICIT ROSTER PROBES THE BOX ONCE (round-5 P3) ════════════════
world
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false
run_fleet env RUNNER_FLEET_BOXES="cell-a cell-a" bash "$FLEET"
assert_eq "$RC" 0 "AA: a duplicated roster label is one box, not a collision"
assert_omits "$OUT" "name-collision" "AA: and it does not manufacture a name collision"
assert_contains "$OUT" "cells=1 " "AA: the roster is deduped before the sweep"

# ══ AB. A REPO LISTED TWICE IS ONE REGISTRY, NOT AN AMBIGUITY (round-6 P3) ═══════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false
run_fleet env RUNNER_FLEET_REPOS="o/a o/a" bash "$FLEET"
assert_eq "$RC" 0 "AB: a seam naming one registry twice is that one registry"
assert_contains "$OUT" "busy=false registry=o/a verdict=ok" "AB: the row is joined normally"
assert_omits "$OUT" "name-carried-by-more-than-one-registry" "AB: and no phantom ambiguity is claimed"

# ══ AC. AN EMPTY STATUS SURVIVES TO THE UNCLAIMED LINE (round-6 P3) ══════════════════
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 0 14375 3584 "" 0 0 0 0 0 0)"
printf 'pi-runner-ghost-1\t\tfalse\n' >"$FIXTURE/gh.o_a"
run_fleet bash "$FLEET"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-ghost-1 registry=o/a status=unread" \
  "AC: the empty status is NAMED, not replaced by the busy value"
assert_omits "$OUT" "status=false" "AC: the busy field never migrates into the status field"

# ══ R. THE MUTANTS — each one must make a named case FAIL ══════════════════════════════════════
# ⛔ A TEST THAT PASSES AGAINST THE MUTANT PINS NOTHING. Each mutant below removes exactly ONE guard
# this suite claims to cover, and the assertion is that the case built for that guard FLIPS.
mutant_case() {  # mutant_case <name> <sed-expr> <the line the MUTANT must now emit>
  local name="$1" expr="$2" expect="$3" m="$T/mutant-$1.sh" out
  # portability: `sed -i` differs between GNU and BSD, so the edit is a rewrite through stdout
  sed "$expr" "$FLEET" >"$m"
  if cmp -s "$FLEET" "$m"; then bad "R/$name: the mutation did not apply (the guard moved?)"; return; fi
  out="$(bash "$m" 2>&1)"
  case "$out" in
    *"$expect"*) ok "R/$name: with this guard removed the report emits '$expect' — the guard is LIVE" ;;
    *)           bad "R/$name: the mutant did not change the report, so the mutation was not the guard" ;;
  esac
}

# R1 — delete the measured gate (host= AND summary= must both arrive)
world
export RUNNER_FLEET_BOXES="cell-a cell-y"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
# cell-y emits a HALF block: a host= line and rows but NO summary — the truncated-read shape
printf 'host=cell-y ncpu=4 ceiling=2 slots=9 mem_available=100 MB (0.1 GB) floor=3584 MB (3.50 GB)\ngh-runner-y-1 1 live pi-runner-y-1\n' >"$FIXTURE/cell-y.out"
printf '0\n' >"$FIXTURE/cell-y.rc"
reg o/a pi-runner-a-1 online false
mutant_case measured-gate 's/if (!seen_host || !seen_sum) { print "M|0"; if (CM != "") print "C|" CM; exit 0 }/if (0) { print "M|0"; if (CM != "") print "C|" CM; exit 0 }/' 'cell label=cell-y read=ok host=cell-y'

# R2 — delete the attribution guard (a phantom must not be claimed from an incomplete fleet)
world
export RUNNER_FLEET_BOXES="cell-a cell-y"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-y-1 online false
mutant_case attribution-guard 's/if \[ "\$unmeasured" -eq 0 \] && \[ "\$skipped" -eq 0 \] && \[ "\$reg_unread" -eq 0 \]; then/if [ 1 -eq 1 ]; then/' 'reason=no-running-cell-claims-it'

# R3 — match the claim on the INSTANCE DIRECTORY instead of the agentName
world
export RUNNER_FLEET_BOXES="cell-5"
cell cell-5 0 "$(block cell-5 16 6 1 21000 3584 "gh-runner-x64-2          471879    live      pi-runner-c5-x64-2" 1 0 0 0 1 0)"
reg o/a pi-runner-c5-x64-2 online false
mutant_case claim-key 's/-v n="\$ghname" /-v n="$name" /' 'verdict=unregistered'

# R4 — drop the producer-rc gate (a complete block behind rc 2 must stop being certified)
world
export RUNNER_FLEET_BOXES="cell-partial"
cell cell-partial 2 "$(block cell-partial 8 3 1 14375 3584 "gh-runner-p-1            111       live      pi-runner-p-1" 1 0 0 0 1 0)
cannot-measure why=pool-root-incomplete root=/tmp/actions-runner outside=/opt/a,/tmp/b — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT"
reg o/a pi-runner-p-1 online false
mutant_case producer-rc-gate 's/case "\$rc" in 0|3) : ;; \*)/case "$rc" in 0|3|2) : ;; *)/' 'cell label=cell-partial read=ok host=cell-partial'

# R5 — drop the REGISTRY-side `unjoinable` increment (case Y must stop refusing)
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 0 14375 3584 "" 0 0 0 0 0 0)"
reg o/a pi-runner-x-1 online false
reg o/b pi-runner-x-1 online false
# what flips is the SUMMARY: the mutant stops counting the registry side, so `unjoinable` drops to 0
# and the fleet reads clean (the shipped build reports 2 and exits 2 — case Y).
mutant_case registry-unjoinable 's/reg_unclaimed=$((reg_unclaimed + 1)); unjoinable=$((unjoinable + 1))/reg_unclaimed=$((reg_unclaimed + 1))/' 'unjoinable=0'

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
