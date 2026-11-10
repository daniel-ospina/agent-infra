#!/usr/bin/env bash
# issue-2465-inert-wait.test.sh — #2465: an INERT FIRST-CHECKS wait must not cost the
# whole window. Two independent mechanisms made `scripts/admin-merge.sh` poll for a run
# that could never appear:
#
#   A. §0b classified a STRUCTURALLY inapplicable lane (its `on:` block declares no
#      `pull_request` / `pull_request_target`) but then gated the fallback on the
#      `lane_has_no_head_run` run probe — a second, single-shot gh read whose failure (or
#      empty answer at t=0) silently left the lane filter in place.
#   B. `atomic-land.sh --no-wait` skipped only its OWN `[2/4] verify` and handed the head
#      to a land step that waited the rail's full FIRST-CHECKS window — so a caller that
#      explicitly declined to wait still waited 65 minutes, once per round.
#
# Section A drives §0b extracted from the REAL source; section B drives `do_land`
# extracted from the REAL `atomic-land.sh`. Both are awk extractions over the shipped
# files (never copies — a copy would drift), each asserted non-empty and asserted to
# contain the fix, so a refactor that moves the seam fails loudly instead of testing
# nothing. A mutation arm rebuilds §0b from a PRE-FIX mutant and shows arm A goes red.
#
# ✖ The rail's whole behaviour under the knob is pinned by `tests/admin-merge/run.sh`
# and the wait itself by `tests/first-checks-lane-rederive/run.sh`; this file pins only
# the two decisions that were wrong.
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
    # WHICH of them decided — the whole point of the fix is that one of them is skipped.
    printf '%s\n' 'lane_applicable() { AP_LOG+="lane_applicable "; LANE_APPLICABILITY="$AP_VERDICT"; LANE_APPLICABILITY_REASON="$AP_REASON"; }'
    printf '%s\n' 'lane_has_no_head_run() { AP_LOG+="probe "; return "${AP_PROBE_RC:-1}"; }'
    printf '%s\n' ''
    printf '%s\n' 'run_s0b() {'
    printf '%s\n' '  local ANY_WORKFLOW="$1" WORKFLOW="$2" head="deadbeef" WF_PR_CHANGED_PATHS="scripts/admin-merge.sh" wf_args=() lane="python-ci.yml"'
    printf '%s\n' '  AP_LOG=""'
    printf '%s\n' '  lane_no_pr_trigger() {'
    printf '%s\n' '    case "${1:-}" in'
    printf '%s\n' "      'lane-applicable: no-pr-trigger'*) return 0 ;;"
    printf '%s\n' '    esac'
    printf '%s\n' '    return 1'
    printf '%s\n' '  }'
    printf '%s\n' "$block"
    printf '%s\n' '  printf "ANY_WORKFLOW=%s\n" "$ANY_WORKFLOW" >&2'
    printf '%s\n' '  printf "WF_ARGS=%s\n" "${wf_args[*]:-}" >&2'
    printf '%s\n' '  printf "LANE=%s\n" "$lane" >&2'
    printf '%s\n' '  printf "APLOG=%s\n" "$AP_LOG" >&2'
    printf '%s\n' '}'
    printf '%s\n' "$helper"
  } > "$out"
  [ -n "$block" ] && [ -n "$helper" ]
}

LIB="$TMP/lib.sh"
ck "extracted the §0b block and lane_no_pr_trigger from $(basename "$SRC")" "$(build_lib "$SRC" "$LIB" && echo 0 || echo 1)"
ck "the extracted block CONTAINS the structural branch (not testing an empty seam)" \
   "$(grep -q 'lane_no_pr_trigger "\$LANE_APPLICABILITY_REASON"' "$LIB" && echo 0 || echo 1)"

# drive <verdict> <reason> <probe_rc> → sets R_ANY / R_WFARGS / R_LANE / R_LOG / R_ERR
drive() {
  R_ERR="$(AP_VERDICT="$1" AP_REASON="$2" AP_PROBE_RC="$3" bash -c '
    source "$1"
    run_s0b 0 python-ci.yml
  ' _ "$LIB" 2>&1 >/dev/null)"
  R_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$R_ERR")"
  R_WFARGS="$(sed -n 's/^WF_ARGS=//p' <<<"$R_ERR")"
  R_LANE="$(sed -n 's/^LANE=//p' <<<"$R_ERR")"
  R_LOG="$(sed -n 's/^APLOG=//p' <<<"$R_ERR")"
}

# ── (a) STRUCTURAL class + a probe that says "has a run" ────────────────────
echo "(a) STRUCTURAL (no PR trigger) + the run probe says 'has a run' — the #2465 defect arm"
drive inapplicable 'lane-applicable: no-pr-trigger — the workflow'"'"'s on: block declares no pull_request / pull_request_target, so no run of it can attach to a PR head (declared triggers: workflow_call)' 1
ck "(a) the fallback FIRED: ANY_WORKFLOW=1 (was 0 → the wait then polled a lane that cannot run, 3900s/round)" \
   "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(a) the lane filter is dropped in the SAME path --any-workflow uses (wf_args='$R_WFARGS', lane='$R_LANE')" \
   "$([ "$R_WFARGS" = "--any-workflow" ] && [ "$R_LANE" = "any workflow" ] && echo 0 || echo 1)"
ck "(a) the run probe was NEVER CONSULTED (its answer cannot change a structural verdict); calls='$R_LOG'" \
   "$(grep -q 'probe' <<<"$R_LOG" && echo 1 || echo 0)"
ck "(a) it names the STRUCTURAL dead-end class (so this is not confused with 'not run yet')" \
   "$(grep -q 'dead-end class: STRUCTURAL' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a) it still prints the loud LANE INAPPLICABLE heading and the §4.5 reassurance" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && grep -q '§4.5' <<<"$R_ERR" && echo 0 || echo 1)"

# ── (b) STRUCTURAL class + probe that says "no run" ─────────────────────────
echo "(b) STRUCTURAL (no PR trigger) + the run probe says 'no run' — pre-existing behaviour preserved"
drive inapplicable 'lane-applicable: no-pr-trigger — the workflow declares no pull_request (declared triggers: workflow_call)' 0
ck "(b) the fallback fires (ANY_WORKFLOW=1)" "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(b) and the probe was skipped here too — one decision, one path" \
   "$(grep -q 'probe' <<<"$R_LOG" && echo 1 || echo 0)"

# ── (c) paths-excluded: the probe STILL decides ─────────────────────────────
echo "(c) paths-excluded (a REAL PR trigger that matched nothing) — the probe must still decide"
drive inapplicable 'lane-applicable: paths-excluded — the declared PR trigger'"'"'s path filter matches none of this PR'"'"'s changed files' 1
ck "(c) probe says 'has a run' → NO fallback (ANY_WORKFLOW=0): a lane that DID run is not a dead end" \
   "$([ "$R_ANY" = 0 ] && echo 0 || echo 1)"
ck "(c) and the probe WAS consulted ($R_LOG)" "$(grep -q 'probe' <<<"$R_LOG" && echo 0 || echo 1)"
ck "(c) the NOT-RUN class text is the one printed, never STRUCTURAL" \
   "$(grep -q 'dead-end class: STRUCTURAL' <<<"$R_ERR" && echo 1 || echo 0)"
drive inapplicable 'lane-applicable: paths-excluded — no declared PR trigger can fire for this changed set' 0
ck "(c2) probe says 'no run' → fallback fires (ANY_WORKFLOW=1), the #1614 dead-end repair intact" \
   "$([ "$R_ANY" = 1 ] && echo 0 || echo 1)"
ck "(c2) it names the NOT-RUN class" "$(grep -q 'dead-end class: NOT-RUN' <<<"$R_ERR" && echo 0 || echo 1)"

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

# ── (f) MUTATION PROOF — remove the structural branch, arm (a) must go RED ──
echo "(f) MUTATION: the structural branch removed from a mutant copy → arm (a) is RED there"
MUT="$TMP/mutant.sh"
# The mutation is the PRE-FIX source: §0b gated the whole fallback on the run probe.
awk '
  /^        local lane_dead_end=0$/ { skip = 1; next }
  skip && /^        if \[ "\$lane_dead_end" -eq 1 \]; then$/ {
    print "        if lane_has_no_head_run \"$head\"; then"; skip = 0; next
  }
  skip && /^        elif lane_has_no_head_run "\$head"; then$/ { next }
  skip && /^        fi$/ { next }
  skip { next }
  { print }
' "$SRC" > "$MUT"
ck "(f) the mutant parses (bash -n)" "$(bash -n "$MUT" 2>/dev/null && echo 0 || echo 1)"
MUTLIB="$TMP/mutant-lib.sh"
build_lib "$MUT" "$MUTLIB"
ck "(f) the mutant's DECISION no longer consults the structural class (no lane_dead_end gate left)" \
   "$(grep -q 'lane_dead_end' "$MUTLIB" && echo 1 || echo 0)"
MUT_ERR="$(AP_VERDICT="inapplicable" AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request' AP_PROBE_RC=1 \
  bash -c 'source "$1"; run_s0b 0 python-ci.yml' _ "$MUTLIB" 2>&1 >/dev/null)"
MUT_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$MUT_ERR")"
ck "(f) against the mutant, arm (a)'s assertion is RED (ANY_WORKFLOW='$MUT_ANY' — the pre-fix 3900s behaviour)" \
   "$([ "$MUT_ANY" = 0 ] && echo 0 || echo 1)"

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
    bash -c 'source "$1"; do_land' _ "$DLIB" 2>&1 >/dev/null
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
