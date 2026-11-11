#!/usr/bin/env bash
# issue-2465-inert-wait.test.sh — #2465: an INERT FIRST-CHECKS wait must not cost the
# whole window. Two independent mechanisms made `scripts/admin-merge.sh` poll for a run
# that could never appear:
#
#   A. §0b classified a STRUCTURALLY inapplicable lane (its `on:` block declares no
#      `pull_request` / `pull_request_target`) but then gated the fallback on a boolean
#      run probe that folded TWO different answers together: `has a run` and `the gh
#      read FAILED`. So one failed `gh run list` — the actual cause of the measured
#      3900 s burn — was indistinguishable from "a run exists, wait for it", and the
#      lane filter stayed in place for the whole window.
#      ⛔ THE FIX IS NOT "SKIP THE PROBE" (that was a first cut, and it silently
#      reversed the RECORDED #1614 dead-end gate: a `on: push` lane is STRUCTURAL and
#      it DOES run on the PR head's own commit). The probe is THREE-valued and its
#      answer decides — `has-run` keeps the filter and the lane's name (#1614),
#      `none` widens, and `unreadable` widens ONLY for the structural class, which is
#      the one class where no run can still appear while the wait runs. This file
#      pins all three, including the #1614 arm the reversal broke.
#   B. `atomic-land.sh --no-wait` skipped only its OWN `[2/4] verify` and handed the head
#      to a land step that waited the rail's full FIRST-CHECKS window — so a caller that
#      explicitly declined to wait still waited 65 minutes, once per round.
#
# Section A drives §0b extracted from the REAL source; section B drives `do_land`
# extracted from the REAL `atomic-land.sh`. Both are awk extractions over the shipped
# files (never copies — a copy would drift), each asserted non-empty and asserted to
# contain the fix, so a refactor that moves the seam fails loudly instead of testing
# nothing. TWO mutation arms: (f) re-introduces the #1614 reversal in a mutant and
# shows the dead-end-gate arm goes RED there, and (h) re-spells the classifier's
# reason prefix and shows arm (a) — the only arm the classification can change — goes
# RED there. (h) exists because a copy of that CLASSIFIER used to be emitted inside
# the extracted lib's body and silently shadow the extract (review P1).
#
# ✖ The rail's whole behaviour under the knob is pinned by `tests/admin-merge/run.sh`
# (arm (e) there is the integration proof of the #1614 gate, arm (f) the integration
# proof that the CLASSIFICATION reaches the decision — `no-pr-trigger` + a failed
# probe read; arm (g) here is the same decision at unit level, and is what mutation
# (f) discriminates)
# and the wait itself by `tests/first-checks-lane-rederive/run.sh`; this file pins only
# the decisions that were wrong.
#
# Usage: bash tests/issue-2465-inert-wait/run.sh
#        ADMIN_MERGE_SRC=<path> / ATOMIC_LAND_SRC=<path> to point at a MUTANT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="${ADMIN_MERGE_SRC:-$ROOT/scripts/admin-merge.sh}"
ALAND="${ATOMIC_LAND_SRC:-$ROOT/scripts/atomic-land.sh}"
[ -f "$SRC" ] || { echo "❌ no rail at $SRC" >&2; exit 1; }
[ -f "$ALAND" ] || { echo "❌ no atomic-land at $ALAND" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lane-applic.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
ck()  { local d="$1" rc="$2"; if [ "$rc" -eq 0 ]; then ok "$d"; else bad "$d"; fi; }

# ── extract §0b from the REAL source, between its own two section markers ────
extract_block() { # $1 = source path
  awk '
    /^  # ── 0b\. IS THE WATCHED LANE APPLICABLE/ { inb = 1; next }
    inb && /^  # ── 1\. the PR/ { exit }
    inb { print }
  ' "$1"
}
extract_helper() { # $1 = source path  $2 = helper name
  awk -v head="$2() {" 'index($0,head)==1{o=1} o{print} o&&/^}$/{exit}' "$1"
}

build_lib() { # $1 = source path, $2 = output file
  local src="$1" out="$2" block helper
  block="$(extract_block "$src")"
  helper="$(extract_helper "$src" lane_no_pr_trigger)"
  {
    printf '%s\n' 'say_err() { printf "%s\n" "$*" >&2; }'
    printf '%s\n' 'info()   { printf "%s\n" "$*" >&2; }'
    # The two collaborators §0b consults. Each appends to $AP_LOG so an arm can assert
    # WHICH of them decided. The probe is THREE-valued (has-run | none | unreadable):
    # the whole point of this fix is that `unreadable` is NOT `has-run`.
    printf '%s\n' 'lane_applicable() { AP_LOG+="lane_applicable "; LANE_APPLICABILITY="$AP_VERDICT"; LANE_APPLICABILITY_REASON="$AP_REASON"; }'
    printf '%s\n' 'lane_head_run_state() { AP_LOG+="probe "; LANE_HEAD_RUN_STATE="${AP_PROBE_STATE:-has-run}"; }'
    printf '%s\n' ''
    printf '%s\n' 'run_s0b() {'
    printf '%s\n' '  local ANY_WORKFLOW="$1" WORKFLOW="$2" head="deadbeef" WF_PR_CHANGED_PATHS="scripts/admin-merge.sh" wf_args=() lane="python-ci.yml"'
    printf '%s\n' '  AP_LOG=""'
    # ⛔ NO INLINE COPY OF `lane_no_pr_trigger` HERE (review P1). One used to be
    # emitted inside this function body, and a definition in the body wins at CALL
    # time — so it REPLACED the extracted helper below and the real bytes never ran.
    # Every arm was then invariant to the classifier: re-spelling the reason prefix
    # that `scripts/ci-workflow-pr-evaluable.sh` emits (`lane-applicable:
    # no-pr-trigger`) re-opened #2465's 3900 s burn with this whole suite green. The
    # helper appended AFTER `run_s0b`'s closing brace is the one that must run — the
    # guard below asserts it is the only definition in the lib, and arm (h) is the
    # mutation that proves arm (a) discriminates on it.
    printf '%s\n' "$block"
    printf '%s\n' '  printf "ANY_WORKFLOW=%s\n" "$ANY_WORKFLOW" >&2'
    printf '%s\n' '  printf "WF_ARGS=%s\n" "${wf_args[*]:-}" >&2'
    printf '%s\n' '  printf "LANE=%s\n" "$lane" >&2'
    printf '%s\n' '  printf "APLOG=%s\n" "$AP_LOG" >&2'
    printf '%s\n' '}'
    printf '%s\n' "$helper"
    # The lib is RUN (`bash < lib`), not SOURCED from a `bash -c` payload: a
    # `source "$1"` token makes the suite's own body unreadable to
    # main-worktree-guard (#1484), which then refuses to run the suite at all. The
    # trailing call is what a `source` used to be paired with in the caller.
    printf '%s\n' 'run_s0b 0 python-ci.yml'
  } > "$out"
  [ -n "$block" ] && [ -n "$helper" ]
}

LIB="$TMP/lib.sh"
ck "extracted the §0b block and lane_no_pr_trigger from $(basename "$SRC")" "$(build_lib "$SRC" "$LIB" && echo 0 || echo 1)"
ck "the extracted block CONTAINS the structural branch (not testing an empty seam)" \
   "$(grep -q 'lane_no_pr_trigger "\$LANE_APPLICABILITY_REASON"' "$LIB" && echo 0 || echo 1)"
ck "the extracted block CONSULTS the three-valued run probe (the #1614 gate is in the seam)" \
   "$(grep -q 'lane_head_run_state "\$head"' "$LIB" && echo 0 || echo 1)"
# ⛔ THE ONE THAT SHADOWED IT (review P1). `lane_no_pr_trigger` must be defined
# EXACTLY ONCE in the lib, and that definition must be the EXTRACT — a copy inside
# `run_s0b` re-defines it at call time and the shipped classifier never executes, so
# no arm could go red when it stopped classifying. Counted, not eyeballed.
ck "the lib defines lane_no_pr_trigger EXACTLY ONCE — the extract, with no shadowing copy (review P1)" \
   "$([ "$(grep -c 'lane_no_pr_trigger() {' "$LIB")" -eq 1 ] && echo 0 || echo 1)"

# drive <verdict> <reason> <probe_state> → sets R_ANY / R_WFARGS / R_LANE / R_LOG / R_ERR
# ⛔ `bash < "$LIB"`, NEVER `bash -c 'source "$1"'`: the suite must stay RUNNABLE
# (main-worktree-guard #1484 refuses any body containing an unresolvable script
# token, and the suite is exactly such a body — this is pre-existing friction the
# reviewer recorded, not the PR's change, but a suite nobody can run pins nothing).
drive() {
  R_ERR="$(AP_VERDICT="$1" AP_REASON="$2" AP_PROBE_STATE="$3" bash < "$LIB" 2>&1 >/dev/null)"
  R_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$R_ERR")"
  R_WFARGS="$(sed -n 's/^WF_ARGS=//p' <<<"$R_ERR")"
  R_LANE="$(sed -n 's/^LANE=//p' <<<"$R_ERR")"
  R_LOG="$(sed -n 's/^APLOG=//p' <<<"$R_ERR")"
}

# ── (a) STRUCTURAL class + an UNREADABLE probe — #2465's MEASURED case ──────
echo "(a) STRUCTURAL (no PR trigger) + the run probe READ FAILED — #2465's actual 3900s burn"
drive inapplicable 'lane-applicable: no-pr-trigger — the workflow'"'"'s on: block declares no pull_request / pull_request_target, so no run of it can attach to a PR head (declared triggers: workflow_call)' unreadable
ck "(a) the fallback FIRED: ANY_WORKFLOW=1 (was 0 under the boolean probe → the wait then polled a lane that cannot run, 3900s/round)" \
   "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(a) the lane filter is dropped in the SAME path --any-workflow uses (wf_args='$R_WFARGS', lane='$R_LANE')" \
   "$([ "$R_WFARGS" = "--any-workflow" ] && [ "$R_LANE" = "any workflow" ] && echo 0 || echo 1)"
ck "(a) the probe WAS consulted and its answer is the UNREADABLE one ('$R_LOG')" \
   "$(grep -q 'probe' <<<"$R_LOG" && echo 0 || echo 1)"
ck "(a) it names the STRUCTURAL dead-end class (so this is not confused with 'not run yet')" \
   "$(grep -q 'dead-end class: STRUCTURAL' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a) it says the read FAILED (not that a run was measured absent)" \
   "$(grep -q 'read FAILED' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a) ⛔ it does NOT claim the lane has no run for the head — the probe never answered that (review P2)" \
   "$(grep -q 'lane has NO run for head' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(a) it still prints the loud LANE INAPPLICABLE heading and the §4.5 reassurance" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && grep -q '§4.5' <<<"$R_ERR" && echo 0 || echo 1)"

# ── (b) STRUCTURAL class + probe that MEASURED "no run" ────────────────────
echo "(b) STRUCTURAL (no PR trigger) + the run probe MEASURED no run — dead end on the measurement"
drive inapplicable 'lane-applicable: no-pr-trigger — the workflow declares no pull_request (declared triggers: workflow_call)' none
ck "(b) the fallback fires (ANY_WORKFLOW=1)" "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(b) and the probe WAS consulted — one decision, one probe" \
   "$(grep -q 'probe' <<<"$R_LOG" && echo 0 || echo 1)"
ck "(b) it reports the measurement it actually took ('MEASURED: an empty listing, not a read failure')" \
   "$(grep -q 'MEASURED: an empty listing, not a read failure' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(b) and it does NOT claim a failed read" \
   "$(grep -q 'read FAILED' <<<"$R_ERR" && echo 1 || echo 0)"

# ── (c) paths-excluded: the probe STILL decides ────────────────────────────
echo "(c) paths-excluded (a REAL PR trigger that matched nothing) — the probe must still decide"
drive inapplicable 'lane-applicable: paths-excluded — the declared PR trigger'"'"'s path filter matches none of this PR'"'"'s changed files' has-run
ck "(c) probe says 'has a run' → NO fallback (ANY_WORKFLOW=0): a lane that DID run is not a dead end" \
   "$([ "$R_ANY" = 0 ] && echo 0 || echo 1)"
ck "(c) and the probe WAS consulted ($R_LOG)" "$(grep -q 'probe' <<<"$R_LOG" && echo 0 || echo 1)"
ck "(c) neither dead-end class text is printed (nothing was widened, so nothing to explain)" \
   "$(grep -Eq 'dead-end class: (STRUCTURAL|NOT-RUN)' <<<"$R_ERR" && echo 1 || echo 0)"
drive inapplicable 'lane-applicable: paths-excluded — no declared PR trigger can fire for this changed set' none
ck "(c2) probe says 'no run' → fallback fires (ANY_WORKFLOW=1), the #1614 dead-end repair intact" \
   "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(c2) it names the NOT-RUN class" "$(grep -q 'dead-end class: NOT-RUN' <<<"$R_ERR" && echo 0 || echo 1)"
drive inapplicable 'lane-applicable: paths-excluded — no declared PR trigger can fire for this changed set' unreadable
ck "(c3) probe says 'UNREADABLE' on a NON-structural class → NO fallback: a run can still appear, so an unread answer is not an exemption (#1614 fail-closed)" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"

# ── (g) STRUCTURAL + the lane HAS a run for the head → NO widening (#1614) ──
# This is the RECORDED #1614 dead-end gate. A first cut of #2465 skipped the probe
# for the structural class and broke it as a side effect; `tests/admin-merge/run.sh`
# arm (e) is the integration proof, this is the same decision at unit level and the
# arm the mutation below discriminates.
# ⚠️ SCOPE OF THIS ARM: the probe is STUBBED here (`lane_head_run_state` is replaced),
# so this pins §0b's POLICY on the answer, never the probe's own scoping/plumbing —
# a mutant that declared LANE_HEAD_RUN_STATE `local` inside the probe leaves (g) green.
# That regression is caught by rail arm (e), which runs the real helper.
echo "(g) STRUCTURAL (no PR trigger) + the lane HAS a run for the head — the #1614 dead-end gate"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push)' has-run
ck "(g) NO gratuitous widening (ANY_WORKFLOW=0, wf_args='$R_WFARGS') — 'otherwise every trigger-split repo silently becomes --any-workflow'" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(g) the certificate keeps naming the requested lane (lane='$R_LANE')" \
   "$([ "$R_LANE" = "python-ci.yml" ] && echo 0 || echo 1)"
ck "(g) no 'LANE INAPPLICABLE' line (that string means the lane was DROPPED)" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(g) but the decision is SAID OUT LOUD, not silent (#2465's confusion was silence)" \
   "$(grep -q 'LANE KEPT' <<<"$R_ERR" && echo 0 || echo 1)"

# ── (d) unknown: fail closed, but NOT silently ──────────────────────────────
echo "(d) UNMEASURED applicability — fail closed, and say so at the point the decision is made"
drive unknown 'lane-applicable: undecidable — the workflow'"'"'s PR triggers could not be fully attributed' 0
ck "(d) NOTHING was dropped (ANY_WORKFLOW=0, wf_args='$R_WFARGS')" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(d) the probe was never consulted (an unread exemption is not an exemption)" \
   "$(grep -q 'probe' <<<"$R_LOG" && echo 1 || echo 0)"
ck "(d) the rail PRINTS the unmeasured reason (was silent → the 65-minute burn was unreadable)" \
   "$(grep -q 'LANE APPLICABILITY UNMEASURED' <<<"$R_ERR" && grep -q 'could not be fully attributed' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(d) and it names the operator's escape (--any-workflow) in that same line" \
   "$(grep -q -- '--any-workflow' <<<"$R_ERR" && echo 0 || echo 1)"

# ── (e) applicable: untouched ──────────────────────────────────────────────
echo "(e) APPLICABLE lane — nothing changes, nothing is dropped, no new output"
drive applicable 'lane-applicable: yes' 0
ck "(e) ANY_WORKFLOW stays 0 and wf_args stays empty" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(e) no LANE INAPPLICABLE / UNMEASURED noise" \
   "$(grep -Eq 'LANE INAPPLICABLE|APPLICABILITY UNMEASURED' <<<"$R_ERR" && echo 1 || echo 0)"

# ── (f) MUTATION PROOF — drop the #1614 gate, arm (g) must go RED ─────────
# The mutation is the REVERSAL the review found: `has-run` widens for the structural
# class (the reviewed head skipped the probe entirely, which is the same behaviour for
# the structural class). If arm (g) cannot tell this source from that one, arm (g) is
# not pinning the recorded decision.
echo "(f) MUTATION: the #1614 gate removed from a mutant copy → arm (g) is RED there"
MUT="$TMP/mutant.sh"
awk '
  /^          has-run\) lane_dead_end=0 ;;$/ {
    print "          has-run) lane_dead_end=1 ;;"; n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$MUT"
ck "(f) the mutation applied EXACTLY once to the 'has-run' decision (a silent no-op mutation would prove nothing)" "$?"
ck "(f) the mutant parses (bash -n)" "$(bash -n "$MUT" 2>/dev/null && echo 0 || echo 1)"
MUTLIB="$TMP/mutant-lib.sh"
build_lib "$MUT" "$MUTLIB"
ck "(f) the mutant still builds a lib with the decision in it (not testing an empty seam)" \
   "$(grep -q 'lane_dead_end' "$MUTLIB" && echo 0 || echo 1)"
MUT_ERR="$(AP_VERDICT="inapplicable" AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request' AP_PROBE_STATE=has-run \
  bash < "$MUTLIB" 2>&1 >/dev/null)"
MUT_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$MUT_ERR")"
ck "(f) against the mutant, arm (g)'s assertion is RED (ANY_WORKFLOW='$MUT_ANY' — a lane that DID run for the head is widened away)" \
   "$([ "$MUT_ANY" = 1 ] && echo 0 || echo 1)"

# ── (h) MUTATION PROOF — re-spell the classifier, arm (a) must go RED ──────
# (review P1) The arms above are all INVARIANT to `lane_no_pr_trigger` except (a):
# (b) and (c2) widen on a probe answer of `none`, (g) keeps on `has-run`, and (c)/(c3)
# are `paths-excluded`. The only state where the CLASSIFICATION itself decides is
# `structural + unreadable` (`admin-merge.sh:9913`), so with the shadow removed arm
# (a) is the attributable row — and this mutation is its falsifier. The edit is the
# realistic one: the reason string is produced in ANOTHER file
# (`scripts/ci-workflow-pr-evaluable.sh` emits `lane-applicable: no-pr-trigger`), and
# classifier and producer are coupled only by that string prefix, so a re-spelling on
# either side silently de-classifies the lane. If arm (a) cannot tell this mutant from
# the shipped source, the arm is decorative and the 3900 s burn is reachable again.
echo "(h) MUTATION: the classifier's reason prefix re-spelled → arm (a) is RED there (review P1)"
CLMUT="$TMP/classifier-mutant.sh"
awk '
  /^    .lane-applicable: no-pr-trigger.\*\) return 0 ;;$/ {
    print "    " sprintf("%c",39) "lane-applicable: structural" sprintf("%c",39) "*) return 0 ;;"
    n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$CLMUT"
ck "(h) the classifier mutation applied EXACTLY once to the reason match (a silent no-op mutation would prove nothing)" "$?"
ck "(h) the mutant parses (bash -n)" "$(bash -n "$CLMUT" 2>/dev/null && echo 0 || echo 1)"
CLMUTLIB="$TMP/classifier-mutant-lib.sh"
build_lib "$CLMUT" "$CLMUTLIB"
ck "(h) the mutant still builds a lib with the classifier in it (not testing an empty seam)" \
   "$(grep -q 'lane-applicable: structural' "$CLMUTLIB" && echo 0 || echo 1)"
# Arm (a)'s own fixture, driven against the mutant: the same structural + UNREADABLE
# case that must widen. The classifier no longer matches, so `lane_structural` stays 0,
# the `*` arm resolves to no dead end, and the filter is kept — #2465's burn.
CM_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: workflow_call)' \
  AP_PROBE_STATE=unreadable bash < "$CLMUTLIB" 2>&1 >/dev/null)"
CM_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$CM_ERR")"
ck "(h) against the mutant, arm (a)'s 'the fallback FIRED' assertion is RED (ANY_WORKFLOW='$CM_ANY' — the 3900 s poll is back)" \
   "$([ "$CM_ANY" = 0 ] && echo 0 || echo 1)"

echo
echo "── B. atomic-land --no-wait must REACH the step that waits ────────────────"
DLIB="$TMP/land-lib.sh"
DO_LAND="$(awk '/^do_land\(\) \{/{o=1} o{print} o&&/^}$/{exit}' "$ALAND")"
ck "extracted do_land from $(basename "$ALAND") (non-empty)" \
   "$([ "$(printf '%s\n' "$DO_LAND" | grep -c .)" -ge 12 ] && echo 0 || echo 1)"
ck "the extracted do_land CARRIES --no-wait to the land step (the fix is in the text)" \
   "$(grep -q 'ADMIN_MERGE_FIRST_CHECKS_WAIT=0' <<<"$DO_LAND" && echo 0 || echo 1)"
{
  printf '%s\n' 'log_line() { printf "LANDLOG %s\n" "$*" >&2; }'
  printf '%s\n' 'do_queue_land() { return 0; }'
  printf '%s\n' 'repo_args=(--repo o/r)'
  printf '%s\n' 'MERGE_FLAGS=()'
  printf '%s\n' 'PR=2513'
  printf '%s\n' "$DO_LAND"
  # RUN the lib's driver step (see `drive`: `bash < lib`, never a `source "$1"`).
  printf '%s\n' 'do_land'
} > "$DLIB"

# The fake land step ANNOUNCES what it was handed — the assertion is on the child's
# environment, because "the variable is set in this shell" is not the claim: the claim is
# that it REACHES the rail.
FAKE_LAND="$TMP/fake-admin-merge"
cat > "$FAKE_LAND" <<'LANDEOF'
#!/usr/bin/env bash
# STDERR on purpose: the driver captures the child's stderr only (stdout is the rail's
# own report and is discarded), so a fake that printed to stdout would assert NOTHING —
# which is exactly how arm B first came out green-with-empty-values.
printf 'LAND_SAW_WAIT=[%s]\n' "${ADMIN_MERGE_FIRST_CHECKS_WAIT-<unset>}" >&2
printf 'LAND_ARGV=%s\n' "$*" >&2
exit 0
LANDEOF
chmod +x "$FAKE_LAND"

# $1 = NO_WAIT, $2 = pre-existing ADMIN_MERGE_FIRST_CHECKS_WAIT (EMPTY = genuinely UNSET —
# an empty-but-exported value would be a different state, and `[ -z ]` cannot tell them apart),
# $3 = DRY_RUN, $4 = QUEUE_MODE.
land_err() {
  local pre=()
  [ -n "${2:-}" ] && pre=("ADMIN_MERGE_FIRST_CHECKS_WAIT=$2")
  NO_WAIT="$1" DRY_RUN="${3:-0}" QUEUE_MODE="${4:-0}" ADMIN_MERGE="$FAKE_LAND" \
    env -u ADMIN_MERGE_FIRST_CHECKS_WAIT ${pre[@]+"${pre[@]}"} \
    bash < "$DLIB" 2>&1 >/dev/null
}
saw() { sed -n 's/^LAND_SAW_WAIT=\[//p' <<<"$1" | sed 's/\]$//'; }

echo "(B1) --no-wait — the rail is handed the 0 seam (one observation, then refuse by name)"
E="$(land_err 1 '')"
ck "(B1) the land step SEES ADMIN_MERGE_FIRST_CHECKS_WAIT=0 (saw '$(saw "$E")')" \
   "$([ "$(saw "$E")" = 0 ] && echo 0 || echo 1)"
ck "(B1) atomic-land SAYS it carried the flag (no silent 3900s wait: the operator can read why)" \
   "$(grep -q 'carried to the rail' <<<"$E" && echo 0 || echo 1)"
ck "(B1) the PR and --repo still reach the rail (the argv is not disturbed)" \
   "$(grep -q 'LAND_ARGV=2513 --repo o/r' <<<"$E" && echo 0 || echo 1)"

echo "(B2) WITHOUT --no-wait — nothing is overridden (the default path is untouched)"
E="$(land_err 0 '')"
ck "(B2) the land step sees the variable UNSET (saw '$(saw "$E")') — no behaviour change" \
   "$([ "$(saw "$E")" = '<unset>' ] && echo 0 || echo 1)"
ck "(B2) and nothing is logged about carrying it" \
   "$(grep -q 'carried to the rail' <<<"$E" && echo 1 || echo 0)"

echo "(B3) an EXPLICIT ADMIN_MERGE_FIRST_CHECKS_WAIT wins over the pass-through flag"
E="$(land_err 1 600)"
ck "(B3) the operator's knob is NOT overridden (saw '$(saw "$E")')" \
   "$([ "$(saw "$E")" = 600 ] && echo 0 || echo 1)"

echo "(B4) --dry-run --no-wait still carries it (a dry run must predict what a real one does)"
E="$(land_err 1 '' 1 0)"
ck "(B4) the land step sees 0 AND the --dry-run flag" \
   "$([ "$(saw "$E")" = 0 ] && grep -q -- '--dry-run' <<<"$E" && echo 0 || echo 1)"

echo "(B5) --queue mode delegates (this unit does not hand-roll the queue's wait)"
E="$(land_err 1 '' 0 1)"
ck "(B5) queue mode called the queue step, not the land step (no LAND_SAW_WAIT at all)" \
   "$(grep -q 'LAND_SAW_WAIT' <<<"$E" && echo 1 || echo 0)"

echo
printf 'issue #2465 inert wait: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
