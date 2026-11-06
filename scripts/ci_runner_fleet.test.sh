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
#   * MUTANTS at the end prove three assertions are live: the measured gate, the attribution guard,
#     and the claim key.
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
cell cell-b 0 "$(block cell-b 4 2 1 9000 3584 "gh-runner-b-1            333       live      pi-runner-b-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-a-2 online true pi-runner-b-1 online false
reg o/b pi-runner-b-1 online false
run_fleet bash "$FLEET"
assert_eq "$RC" 0 "A: every cell measured and every registration claimed => exit 0"
assert_contains "$OUT" "cell label=cell-a read=ok host=cell-a ncpu=8 ceiling=3 slots=2 mem_available_mb=14375 floor_mb=3584" \
  "A: the cell line carries the box's OWN readings (host, cores, ceiling, slots, MEMORY, floor)"
assert_contains "$OUT" "runner cell=cell-a name=gh-runner-a-1 github_name=pi-runner-a-1 listener=111 local=live github=online" \
  "A: a registered name, its listener pid and its GitHub state are reconciled on ONE row"
assert_contains "$OUT" "runner cell=cell-a name=gh-runner-a-2 github_name=pi-runner-a-2 listener=222 local=live github=online busy=true" \
  "A: busy-ness comes from the registry (the local view cannot know it)"
assert_contains "$OUT" "cell label=cell-b read=ok host=cell-b ncpu=4 ceiling=2 slots=1 mem_available_mb=9000" \
  "A: a SECOND cell is reported with ITS OWN memory reading and ceiling, not the first cell's"
assert_contains "$OUT" "verdict=ok" "A: a row that both sources agree on is ok"
assert_contains "$OUT" "summary cells=2 measured=2 unmeasured=0 registry=4 claimed=4 unclaimed=0 unregistered=0" \
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
assert_contains "$OUT" "registry-unclaimed name=pi-runner-y-1 registry=a status=online reason=cannot-attribute(1-cell-unmeasured)" \
  "B: while a cell is unmeasured, an unclaimed name is cannot-attribute — never a phantom"
assert_omits "$OUT" "no-measured-cell-claims-it" "B: no phantom is claimed from an incomplete fleet"
assert_contains "$OUT" "measured=1 unmeasured=1" "B: the summary counts BOTH sides"

# ══ C. THE OTHER DIRECTION: a registration no measured cell carries IS a phantom (all measured) ══
world
export RUNNER_FLEET_BOXES="cell-a"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-lost-9 offline false
run_fleet bash "$FLEET"
assert_eq "$RC" 3 "C: a measured fleet that does not account for a registration => exit 3"
assert_contains "$OUT" "registry-unclaimed name=pi-runner-lost-9 registry=a status=offline reason=no-measured-cell-claims-it" \
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
assert_contains "$OUT" "name=gh-runner-dead github_name=pi-runner-dead listener=- local=DEAD github=online busy=false registry=a verdict=dead-listener" \
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
assert_contains "$OUT" "registry repo=a read=cannot-measure why=registry-unreadable" "G: the registry half reports its own failure"
assert_omits "$OUT" "registry repo=a read=ok runners=0" "G: a refused registry never reads as an EMPTY one"
assert_omits "$OUT" "registry-unclaimed" "G: and nothing is attributed as a phantom from a read that did not happen"

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
assert_contains "$OUT" "cell label=cell-4 read=cannot-measure why=pool-unreadable" "K: and is reported as unmeasured"
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

# ══ N. THE MUTANTS — each one must make a named case FAIL ══════════════════════════════════════
# ⛔ A TEST THAT PASSES AGAINST THE MUTANT PINS NOTHING. Each mutant below removes exactly ONE guard
# this suite claims to cover, and the assertion is that the case built for that guard FLIPS.
mutant_case() {  # mutant_case <name> <sed-expr> <the line the MUTANT must now emit>
  local name="$1" expr="$2" expect="$3" m="$T/mutant-$1.sh" out
  # portability: `sed -i` differs between GNU and BSD, so the edit is a rewrite through stdout
  sed "$expr" "$FLEET" >"$m"
  if cmp -s "$FLEET" "$m"; then bad "N/$name: the mutation did not apply (the guard moved?)"; return; fi
  out="$(bash "$m" 2>&1)"
  case "$out" in
    *"$expect"*) ok "N/$name: with this guard removed the report emits '$expect' — the guard is LIVE" ;;
    *)           bad "N/$name: the mutant did not change the report, so the mutation was not the guard" ;;
  esac
}

# N1 — delete the measured gate (host= AND summary= must both arrive)
world
export RUNNER_FLEET_BOXES="cell-a cell-y"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
# cell-y emits a HALF block: a host= line and rows but NO summary — the truncated-read shape
printf 'host=cell-y ncpu=4 ceiling=2 slots=9 mem_available=100 MB (0.1 GB) floor=3584 MB (3.50 GB)\ngh-runner-y-1 1 live pi-runner-y-1\n' >"$FIXTURE/cell-y.out"
printf '0\n' >"$FIXTURE/cell-y.rc"
reg o/a pi-runner-a-1 online false
mutant_case measured-gate 's/if (!seen_host || !seen_sum) { print "M|0"; if (CM != "") print "C|" CM; exit 0 }/if (0) { print "M|0"; if (CM != "") print "C|" CM; exit 0 }/' 'cell label=cell-y read=ok host=cell-y'

# N2 — delete the attribution guard (a phantom must not be claimed from an incomplete fleet)
world
export RUNNER_FLEET_BOXES="cell-a cell-y"
cell cell-a 0 "$(block cell-a 8 3 1 14375 3584 "gh-runner-a-1            111       live      pi-runner-a-1" 1 0 0 0 1 0)"
reg o/a pi-runner-a-1 online false pi-runner-y-1 online false
mutant_case attribution-guard 's/if \[ "\$unmeasured" -eq 0 \]; then/if [ 1 -eq 1 ]; then/' 'reason=no-measured-cell-claims-it'

# N3 — match the claim on the INSTANCE DIRECTORY instead of the agentName
world
export RUNNER_FLEET_BOXES="cell-5"
cell cell-5 0 "$(block cell-5 16 6 1 21000 3584 "gh-runner-x64-2          471879    live      pi-runner-c5-x64-2" 1 0 0 0 1 0)"
reg o/a pi-runner-c5-x64-2 online false
mutant_case claim-key 's/-v n="\$ghname" /-v n="$name" /' 'verdict=unregistered'

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
