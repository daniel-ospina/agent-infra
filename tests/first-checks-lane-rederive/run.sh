#!/usr/bin/env bash
# first-checks-lane-rederive.test.sh — #2862: the FIRST-CHECKS wait must not
# assume the repo's CI is named `python-ci.yml`.
#
# ⛔ WHY THIS IS A SCOPED SUITE AND NOT A NEW ARM IN tests/admin-merge/run.sh.
# That suite is 15k lines and 16m37s wall-clock (ci.yml:1177). Its subject is the
# WHOLE rail: the failure-set parser, the flake re-run, the evidence comment, the
# merge call. The defect here is ONE wait, and the four arms that must be answered
# are all inside it. So this file extracts the TWO functions from the REAL source
# (awk over `scripts/admin-merge.sh`, never a copy — a copy would drift) and drives
# them against a fake `gh` in seconds. The extraction is asserted to be non-empty
# and to terminate at the function's own closing brace, so a refactor that breaks
# the seam fails loudly here instead of silently testing nothing.
#
# ⛔ WHAT THIS FILE DOES *NOT* CLAIM. It does not re-run the rail's §4.5 tree
# probe, so it is not evidence that a red required check is still refused — that
# arm is proven two ways elsewhere and this file PINS the reason it stays true:
#   1. `git diff` touches no line of `check_surface_probe` / `TREE_*` (§4.5 is the
#      gate, and it reads EVERY workflow — the filter only ever chose which runs
#      the WAIT watched).
#   2. the extracted wait is asserted to never assign `ANY_WORKFLOW`, so the
#      failure-set lane (what actually decides red) cannot be widened by this fix.
#   3. a behavioural equality arm: the dropped-filter path is asserted to reach the
#      SAME verdict as `--any-workflow`, the operator's own proven-safe escape
#      (premise-labs#572 merged on it: 12 checks, 0 failing).
#
# THE FOUR ARMS (#2862):
#   (a) repo whose CI IS `python-ci.yml`  → filtered list is non-empty, the wait
#       clears, and the check-runs probe is NEVER CALLED (no new REST cost).
#   (b) differently-named CI (`ci.yml`)   → filtered list is empty while the head
#       carries check-runs, so the filter is DROPPED and the unfiltered read clears
#       the wait. This is the arm that hung premise-labs#572.
#   (c) a required context that never reports → the wait still TERMINATES (rc 0,
#       terminal surface, in bounded time) and never reports "no run appeared";
#       refusing for the absent name is the classifier's job, not the wait's.
#   (d) an EMPTY check-run set → the empty list was TRUE, the wait fails CLOSED at
#       the legacy window and its refusal says the head carries no check-run.
#   (e) FAIL-CLOSED sibling: an UNREADABLE check-runs probe drops NOTHING. An
#       unread instrument is not a misconfiguration.
#
# THE BOUNDS ARE UNCHANGED AND THEIR PROVENANCE IS THE RAIL'S OWN: stall 8760s (2 ×
# the longest measured silent STEP, 4380s), ceiling 18064s (2 × the slowest measured
# green run, 9032s), legacy window 3900s for the states with no object whose
# progress could be observed. This fix adds a COUNT bound, not a time bound
# (`ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX`, default 1), so the re-derivation cannot
# become an unbounded retry: every arm below still exits through that table, and
# arm (d) is asserted to exit INSIDE the window rather than hang.
#
# Usage: bash tests/admin-merge/first-checks-lane-rederive.test.sh
#        (ADMIN_MERGE_SRC=<path> to point at a MUTANT — see the mutation run)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="${ADMIN_MERGE_SRC:-$ROOT/scripts/admin-merge.sh}"
[ -f "$SRC" ] || { echo "❌ no rail at $SRC" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fc-rederive.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
ck()  { local d="$1" rc="$2"; if [ "$rc" -eq 0 ]; then ok "$d"; else bad "$d"; fi; }

# ── extract the REAL functions ───────────────────────────────────────────────
# The terminator is the function's own column-0 `}`; both functions are asserted to
# be non-empty and to have a body, so a rename cannot leave the suite testing an
# empty file (the "green because it ran nothing" shape).
extract() { awk -v head="$1() {" 'index($0,head)==1{o=1} o{print} o&&/^}$/{exit}' "$SRC"; }
PROBE="$(extract first_checks_head_check_count)"
WAIT="$(extract wait_for_first_checks)"
BLOCK="$(extract block_on_first_checks)"
ck "extracted first_checks_head_check_count from $(basename "$SRC") (non-empty)" \
   "$([ "$(printf '%s\n' "$PROBE" | grep -c .)" -ge 8 ] && echo 0 || echo 1)"
ck "extracted wait_for_first_checks from $(basename "$SRC") (non-empty, ≥200 lines)" \
   "$([ "$(printf '%s\n' "$WAIT" | grep -c .)" -ge 200 ] && echo 0 || echo 1)"
# The fix must be IN the extracted text, or every arm below would pass vacuously.
ck "the extracted wait contains the #2862 re-derive block (the DROP itself, not just its flag)" \
   "$(grep -q 'DROPPING the lane filter' <<<"$WAIT" && echo 0 || echo 1)"
ck "the extracted probe reads total_count (the discriminator, not a run list)" \
   "$(grep -q 'total_count' <<<"$PROBE" && echo 0 || echo 1)"
ck "extracted block_on_first_checks (the refusal TEXT this suite asserts on)" \
   "$([ "$(printf '%s\n' "$BLOCK" | grep -c .)" -ge 40 ] && echo 0 || echo 1)"

LIB="$TMP/lib.sh"
# The knob DERIVATION is part of the code under test (a `FIRST_CHECKS_*` value is
# computed once at the rail's top level, never inside the wait), so it is extracted
# from the source too — a hardcoded copy here would let the env NAME drift away
# from the rail's without this suite noticing.
KNOB="$(awk '/^FIRST_CHECKS_REDERIVE_MAX=/{print; exit}' "$SRC")"
ck "extracted the FIRST_CHECKS_REDERIVE_MAX derivation (the env NAME is pinned, not copied)" \
   "$(grep -q 'ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX' <<<"$KNOB" && echo 0 || echo 1)"
{
  printf '%s\n' 'info() { printf "%s\n" "$*" >&2; }'
  printf '%s\n' 'say_err() { printf "%s\n" "$*" >&2; }'
  # Stubs for the two collaborators the arms do not exercise: a TERMINAL listing
  # never reaches either, and the arms that do reach them are about clocks, not jobs.
  printf '%s\n' 'fetch_run_jobs() { cat "$FC_JOBS_JSON" 2>/dev/null || :; }'
  printf '%s\n' 'first_checks_digest() { printf "%s\n" "${FC_DIGEST:-1	0	fp	1 job(s)}"; }'
  printf '%s\n' "$KNOB"
  printf '%s\n\n' "$PROBE"
  printf '%s\n' "$WAIT"
  printf '%s\n' "$BLOCK"
} > "$LIB"

# ── the fake gh ──────────────────────────────────────────────────────────────
# It models the two calls this wait makes, and NOTHING is inferred: the arms are
# distinguished by FIXTURE, and every invocation is logged so an arm can assert
# which calls it did and did not make (arm (a) must not pay the probe).
GHF="$TMP/gh"
cat > "$GHF" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FC_GH_LOG"
case "$1" in
  run)
    wf=""; prev=""
    for x in "$@"; do [ "$prev" = "--workflow" ] && wf="$x"; prev="$x"; done
    if [ "${FC_RUNLIST_FAIL:-0}" = "1" ]; then echo "gh: could not read runs" >&2; exit 1; fi
    if [ -n "$wf" ]; then
      # Real gh exits 0 with no rows when the file matches no workflow in the repo
      # (measured: that is the state premise-labs#572 sat in — never-started, rc 0).
      [ "$wf" = "$FC_HAVE_WF" ] && [ -s "$FC_RUNS" ] && { cat "$FC_RUNS"; }
      exit 0
    fi
    [ -s "$FC_RUNS" ] && cat "$FC_RUNS"
    exit 0 ;;
  api)
    case "$*" in
      *"/check-runs"*)
        if [ "${FC_CHECKS_FAIL:-0}" = "1" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
        printf '{"total_count":%s,"check_runs":[]}\n' "${FC_CHECKS_TOTAL:-0}"
        exit 0 ;;
      *) printf '{}\n'; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$GHF"

SCEN="$TMP/scen"; mkdir -p "$SCEN"
# MUTATION SEAM (#2862): the knob is what turns the fix off, so a mutation run can
# restore the pre-fix behaviour WITHOUT editing the source under test.
#   ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX=0  → the hardcoded lane is back, and arm
#   (b) below must go RED. That is the "restore the hardcoded name → red" proof.
REDERIVE_MAX_OVERRIDE="${ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX:-}"

# drive_wait <label> — run the REAL wait once against the fixture in $SCEN.
# Prints nothing; sets W_RC / W_STATE / W_OUTCOME / W_REDERIVED / W_ELAPSED / W_ERR.
drive_wait() {
  local t0=$SECONDS
  : > "$SCEN/gh.log"
  W_ERR="$(
    FC_GH_LOG="$SCEN/gh.log" FC_RUNS="$SCEN/runs" FC_HAVE_WF="${FC_HAVE_WF:-}" \
    FC_CHECKS_TOTAL="${FC_CHECKS_TOTAL:-0}" \
    FC_CHECKS_FAIL="${FC_CHECKS_FAIL:-}" FC_RUNLIST_FAIL="${FC_RUNLIST_FAIL:-}" \
    TMP="$SCEN" GH="$GHF" HEAD="deadbeef" REPO="o/r" LIB="$LIB" \
    WORKFLOW="${W_WORKFLOW-python-ci.yml}" ANY_WORKFLOW="${W_ANY:-0}" \
    FIRST_CHECKS_WAIT="${W_WAIT:-2}" FIRST_CHECKS_STALL="${W_STALL:-8760}" \
    FIRST_CHECKS_CEILING="${W_CEIL:-18064}" FIRST_CHECKS_POLL=1 \
    ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX="${REDERIVE_MAX_OVERRIDE:-${W_REDERIVE_MAX:-1}}" \
    bash -c 'source "$LIB"; wait_for_first_checks "$1"; rc=$?;
             printf "RC=%s\n" "$rc" >&2
             printf "STATE=%s\n" "$FIRST_CHECKS_STATE" >&2
             printf "OUTCOME=%s\n" "$FIRST_CHECKS_OUTCOME" >&2
             printf "REDERIVED=%s\n" "$FIRST_CHECKS_REDERIVED" >&2
             # The refusal body lives in block_on_first_checks; a failed wait is
             # only half the evidence, so the arm asserts on what an operator reads.
             if [ "$rc" -ne 0 ]; then block_on_first_checks "$1" >&2; fi' _ "deadbeef" 2>&1 >/dev/null
  )"
  W_RC="$(sed -n 's/^RC=//p' <<<"$W_ERR")"
  W_STATE="$(sed -n 's/^STATE=//p' <<<"$W_ERR")"
  W_OUTCOME="$(sed -n 's/^OUTCOME=//p' <<<"$W_ERR")"
  W_REDERIVED="$(sed -n 's/^REDERIVED=//p' <<<"$W_ERR")"
  W_ELAPSED=$((SECONDS - t0))
}

# ── (a) a repo whose CI IS python-ci.yml ────────────────────────────────────
echo "(a) the configured lane EXISTS — clears, and pays NO extra REST read"
printf 'completed|success|7001|2026-10-26T01:00:00Z\n' > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=python-ci.yml FC_CHECKS_TOTAL=12 drive_wait
ck "(a) the wait CLEARS (rc 0) on the configured lane" "$([ "$W_RC" = 0 ] && echo 0 || echo 1)"
ck "(a) NO re-derivation happened" "$([ -z "$W_REDERIVED" ] && echo 0 || echo 1)"
ck "(a) the check-runs probe was NEVER CALLED (the pre-existing path is untouched, no new REST cost)" \
   "$(grep -q 'check-runs' "$SCEN/gh.log" && echo 1 || echo 0)"
ck "(a) the run list still carried --workflow (the filter is kept when it works)" \
   "$(grep -q -- '--workflow python-ci.yml' "$SCEN/gh.log" && echo 0 || echo 1)"

# ── (b) a differently-named CI — THE DEFECT arm ─────────────────────────────
echo "(b) the configured lane selects NOTHING but the head carries checks — the #2862 defect"
printf 'completed|success|8001|2026-10-26T02:00:00Z\n' > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_TOTAL=12 drive_wait
ck "(b) the wait CLEARS (rc 0) instead of burning the window (was: never-started → 3900s waste)" \
   "$([ "$W_RC" = 0 ] && echo 0 || echo 1)"
ck "(b) it recorded WHICH lane was dropped" \
   "$([ "$W_REDERIVED" = python-ci.yml ] && echo 0 || echo 1)"
ck "(b) the refusal did NOT say 'no run has appeared'" \
   "$(grep -q 'no run has appeared' <<<"$W_ERR" && echo 1 || echo 0)"
ck "(b) the drop is ANNOUNCED, naming the repo-agnostic reason" \
   "$(grep -q 'DROPPING the lane filter' <<<"$W_ERR" && echo 0 || echo 1)"
NTH2="$(sed -n '2p' "$SCEN/gh.log")"
ck "(b) the SECOND run list dropped --workflow (the re-read is genuinely unfiltered): [$NTH2]" \
   "$(grep -q -- '--workflow' <<<"$NTH2" && echo 1 || echo 0)"
ck "(b) the probe read the head's check-runs exactly ONCE (bounded by the COUNT knob, not a retry loop)" \
   "$([ "$(grep -c 'check-runs' "$SCEN/gh.log")" -eq 1 ] && echo 0 || echo 1)"

# ── (b2) EQUALITY with the operator's own escape (--any-workflow) ───────────
echo "(b2) the dropped-filter path reaches the SAME verdict as --any-workflow (the proven-safe escape)"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_TOTAL=12 drive_wait
DROP_RC="$W_RC"; DROP_STATE="$W_STATE"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_TOTAL=12 W_ANY=1 drive_wait
ck "(b2) rc identical to --any-workflow (drop=$DROP_RC any=$W_RC)" \
   "$([ "$DROP_RC" = "$W_RC" ] && echo 0 || echo 1)"
ck "(b2) state identical to --any-workflow (drop='$DROP_STATE' any='$W_STATE')" \
   "$([ "$DROP_STATE" = "$W_STATE" ] && echo 0 || echo 1)"
ck "(b2) --any-workflow paid NO probe either (so the drop costs exactly what the escape cost)" \
   "$(grep -q 'check-runs' "$SCEN/gh.log" && echo 1 || echo 0)"

# ── (c) a required context that never reports ───────────────────────────────
echo "(c) a required context that never reports — the wait must TERMINATE, sounding like a wait not a misconfiguration"
printf 'completed|success|9001|2026-10-26T03:00:00Z\n' > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_TOTAL=3 drive_wait
ck "(c) the wait TERMINATES (rc 0, terminal surface) in bounded time (${W_ELAPSED}s)" \
   "$([ "$W_RC" = 0 ] && [ "$W_ELAPSED" -le 8 ] && echo 0 || echo 1)"
ck "(c) it does NOT claim the lane never started — the absent NAME is the classifier's refusal" \
   "$([ -z "$W_STATE" ] && echo 0 || echo 1)"
# The classifier's refusal for an absent required context is pinned by its own suite.
ck "(c) the missing-required-context refusal is pinned elsewhere (nochk-resolve PENDING arm)" \
   "$(grep -q 'PENDING:python-ci-gate' "$ROOT/scripts/orchestrator-harness/nochk-resolve.test.sh" && echo 0 || echo 1)"

# ── (d) an EMPTY check-run set — fail CLOSED, and BOUNDED ───────────────────
echo "(d) NO run and NO check-run at the head — the empty list was TRUE, so it fails closed INSIDE the window"
: > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF="" FC_CHECKS_TOTAL=0 W_WAIT=2 drive_wait
ck "(d) the wait FAILS CLOSED (rc 1 after ${W_ELAPSED}s of a 2s window — it cannot hang)" \
   "$([ "$W_RC" = 1 ] && [ "$W_ELAPSED" -ge 2 ] && [ "$W_ELAPSED" -le 8 ] && echo 0 || echo 1)"
ck "(d) the verdict is never-started" "$([ "$W_STATE" = never-started ] && echo 0 || echo 1)"
ck "(d) the refusal says the head carries NO check-run at all (it does not blame the lane's trigger)" \
   "$(grep -q 'the head carries no check-run' <<<"$W_ERR" && echo 0 || echo 1)"
ck "(d) it still NAMES the window bound it respected" \
   "$(grep -q 'window 2s' <<<"$W_ERR" && echo 0 || echo 1)"
ck "(d) the refusal is the never-started arm, not a stall or a timeout" \
   "$(grep -q 'BLOCK — the FIRST-CHECKS wait expired' <<<"$W_ERR" && echo 0 || echo 1)"

# ── (e) FAIL-CLOSED sibling: an UNREADABLE probe drops NOTHING ──────────────
echo "(e) the check-runs probe is UNREADABLE — an unread instrument is not a misconfiguration"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_FAIL=1 W_WAIT=2 drive_wait
ck "(e) NOTHING was dropped (rc ${W_RC}, rederived='${W_REDERIVED}')" \
   "$([ "$W_RC" = 1 ] && [ -z "$W_REDERIVED" ] && echo 0 || echo 1)"
ck "(e) the probe was ATTEMPTED EXACTLY ONCE across the whole window — a failed probe cannot retry per poll" \
   "$([ "$(grep -c 'check-runs' "$SCEN/gh.log")" -eq 1 ] && echo 0 || echo 1)"
ck "(e) the log says the two states stayed INDISTINGUISHABLE and names the operator's escape (--any-workflow)" \
   "$(grep -q 'could not be READ' <<<"$W_ERR" && grep -q -- '--any-workflow' <<<"$W_ERR" && echo 0 || echo 1)"
# Same shape for a run-list READ failure: the unreadable arm must not become a drop.
echo "(e2) the run list itself is unreadable — also drops nothing"
printf 'completed|success|9001|2026-10-26T03:00:00Z\n' > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_RUNLIST_FAIL=1 FC_CHECKS_TOTAL=12 W_WAIT=2 drive_wait
ck "(e2) an unreadable LISTING drops nothing (state='$W_STATE', rederived='$W_REDERIVED')" \
   "$([ -z "$W_REDERIVED" ] && [ "$W_STATE" = unreadable ] && echo 0 || echo 1)"
ck "(e2) the probe was never consulted at all (rc!=0 is not 'nothing exists here')" \
   "$(grep -q 'check-runs' "$SCEN/gh.log" && echo 1 || echo 0)"

# ── (f) a RED run still reaches the gate as RED (terminal ≠ green) ──────────
echo "(f) a RED run on the head — the wait reports TERMINALITY, never greenness"
printf 'completed|failure|9101|2026-10-26T04:00:00Z\n' > "$SCEN/runs"
W_WORKFLOW=python-ci.yml FC_HAVE_WF=ci.yml FC_CHECKS_TOTAL=12 drive_wait
ck "(f) the wait CLEARS on a red run (rc 0) — its contract is 'there is something to compare', and the red reaches §4.5 unchanged" \
   "$([ "$W_RC" = 0 ] && echo 0 || echo 1)"
ck "(f) the wait never emits a green verdict of its own (no 'green'/'GREEN' in its output)" \
   "$(grep -qi 'green' <<<"$W_ERR" && echo 1 || echo 0)"
ck "(f) STRUCTURAL: the wait never assigns ANY_WORKFLOW, so the failure-set lane that decides red is NOT widened" \
   "$(grep -q 'ANY_WORKFLOW=' <<<"$WAIT" && echo 1 || echo 0)"
ck "(f) STRUCTURAL: §4.5's gate is still a head probe across EVERY workflow" \
   "$(grep -q 'check_surface_probe "\$head" "the PR.s evaluated tree' "$SRC" && echo 0 || echo 1)"
ck "(f) STRUCTURAL: this patch added/modified no probe line" \
   "$(cd "$ROOT" && git diff -U0 -- scripts/admin-merge.sh 2>/dev/null \
        | grep -E '^[+-][^+-]' | grep -vE '^[+-][[:space:]]*#' \
        | grep -qE 'MAIN_HEALTH_|check_surface_probe\(|TREE_' && echo 1 || echo 0)"

echo
printf 'first-checks lane re-derive: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
