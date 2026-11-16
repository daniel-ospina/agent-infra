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
#      `none` widens, and `unreadable` widens ONLY where the lane's own run can never
#      attach to the head: `STRUCTURAL` and EVERY declared `on:` member is a KNOWN-INERT
#      trigger (`lane_own_run_can_attach` — an ALLOW-LIST of inertness, since round 8: any
#      member not proven inert keeps the filter and fails closed). This file pins all three,
#      including the #1614 arm the reversal broke.
#      ⛔ AND NOT "unreadable widens for the whole STRUCTURAL class" — that was the merged
#      first landing (`e4716a058`) and it failed open on one transient read (review P1).
#   B. `atomic-land.sh --no-wait` skipped only its OWN `[2/4] verify` and handed the head
#      to a land step that waited the rail's full FIRST-CHECKS window — so a caller that
#      explicitly declined to wait still waited 65 minutes, once per round.
#
# Section A drives §0b extracted from the REAL source; section B drives `do_land`
# extracted from the REAL `atomic-land.sh`. Both are awk extractions over the shipped
# files (never copies — a copy would drift), each asserted non-empty and asserted to
# contain the fix, so a refactor that moves the seam fails loudly instead of testing
# nothing. TEN mutation arms: (f) re-introduces the #1614 reversal in a mutant and
# shows the dead-end-gate arm goes RED there, and (h) re-spells the classifier's
# reason prefix and shows arm (a) — the only arm the classification can change — goes
# RED there. (h) exists because a copy of that CLASSIFIER used to be emitted inside
# the extracted lib's body and silently shadow the extract (review P1). Four are the
# helper mutants, all expressed in the ALLOW-LIST's terms (round 8 — the deny-list they
# used to re-spell no longer exists): (a5) puts 'push' wrongly ON the inert set, (a6)
# flips the absent-clause default, (a7) treats an UNCLASSIFIED member as inert — the
# round-8 defect itself, which widens the `pull_request_review_comment` lane of (a15) —
# and (a11) puts 'pull_request_review' wrongly ON the inert set. (a9) reduces the §0b
# gate to the class LABEL — the one-condition policy the docstring used to record — and
# is what makes the docstring/predicate pin (a0) provably load-bearing. (a13) moves the
# fail-closed default back under "Widen" in the record, and (a14) restores the "no
# member is classifiable" wording — both round-7 P2/P3 defects that shipped green
# because the wording arms could not see a NEW wording. (a18) puts the DENY-list predicate
# back into the DESIGN RECORD's own step-1 bullet, which is what makes the plan-doc pin
# (a17) — load-bearing: (a0) pins only the DOCSTRING, so the plan doc stayed GREEN while it drifted
# to the superseded predicate (round 9, P2). Each is counted, so a silent no-op proves
# nothing.
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
extract_docstring() { # $1 = source path  $2 = function name — the `#` block ABOVE it
  awk -v fn="$2() {" '
    $0 == fn { print block; exit }
    /^#/ { block = block $0 "\n"; next }
    { block = "" }
  ' "$1"
}

# bullet_with <docstring> <regex> — print the ONE bullet of a `#   * …` list whose text
# matches <regex>, or exit 3 when no bullet does. Bounds are computed from the bullet
# STARTS, so the returned text is exactly one bullet — which is what lets an arm assert
# WHICH bullet a claim sits in (round 7, P2: the record put the fail-closed default
# under "Widen", the fail-OPEN direction, and no arm read the placement).
# ⛔ THE BOUND IS THE BULLET'S OWN END, NOT THE NEXT BULLET **OR EOF** (round 8, P3).
# `end = NR` for the LAST bullet meant its extracted text ran through the docstring's
# closing prose, so "the KEPT bullet carries the default" was satisfied by a sentence that
# had been moved OUT of the bullet and into the paragraph below it. A bullet continuation
# line is `#     ` (bullet marker plus wrap indent); the docstring's post-bullet prose
# starts at `#` or `# ⛔`, so the first line that is not a continuation ends the bullet.
bullet_with() {
  printf '%s\n' "$1" | awk -v pat="$2" '
    { line[NR] = $0 }
    /^#   \* / { nb++; start[nb] = NR }
    { if (nb && !hit && $0 ~ pat) hit = nb }
    END {
      if (!hit) exit 3
      end = (hit + 1 <= nb) ? start[hit + 1] - 1 : NR
      if (hit + 1 > nb) {
        for (i = start[hit] + 1; i <= NR; i++) {
          if (line[i] !~ /^#     /) { end = i - 1; break }
        }
      }
      for (i = start[hit]; i <= end; i++) print line[i]
    }
  '
}

build_lib() { # $1 = source path, $2 = output file
  local src="$1" out="$2" block helper helper2
  block="$(extract_block "$src")"
  helper="$(extract_helper "$src" lane_no_pr_trigger)"
  # (#2465 review P1) the SECOND classifier: can this lane's OWN name ever appear on a
  # run for a PR head? §0b consults it on an `unreadable` probe, so the seam is
  # incomplete without it — an extraction that dropped it would leave arm (a2) testing
  # a command-not-found, which reads as "kept" for the wrong reason.
  helper2="$(extract_helper "$src" lane_own_run_can_attach)"
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
    printf '%s\n' "$helper2"
    # The lib is RUN (`bash < lib`), not SOURCED from a `bash -c` payload: a
    # `source "$1"` token makes the suite's own body unreadable to
    # main-worktree-guard (#1484), which then refuses to run the suite at all. The
    # trailing call is what a `source` used to be paired with in the caller.
    printf '%s\n' 'run_s0b 0 python-ci.yml'
  } > "$out"
  [ -n "$block" ] && [ -n "$helper" ] && [ -n "$helper2" ]
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

# ── (a0) THE RECORD AND THE PREDICATE MUST AGREE (round 5, P2) ──────────────
# `lane_no_pr_trigger`'s docstring stated the REJECTED one-condition policy — the whole
# STRUCTURAL class widens on `unreadable`, with the class-wide "this PR cannot start a
# run" rationale — while the shipped gate is `lane_structural && !
# lane_own_run_can_attach`. The CODE was right; the RECORD was not, in the direction
# that fails open: a next lane restoring "the record" re-opens #2465's fail-open with
# every behavioural arm still green, because no arm reads the prose. So the prose is
# pinned here, to the predicate, and mutation (a9) is what proves the pin bites.
echo "(a0) the docstring states the SHIPPED two-condition predicate, not the rejected class-wide one"
DOC="$(extract_docstring "$SRC" lane_no_pr_trigger)"
ck "(a0) extracted a non-empty docstring for lane_no_pr_trigger (not pinning an empty seam)" \
   "$([ -n "$DOC" ] && echo 0 || echo 1)"
ck "(a0) the gate in the extracted §0b is the TWO-condition predicate (lane_structural && ! lane_own_run_can_attach)" \
   "$(grep -qF 'lane_structural" -eq 1 ] && ! lane_own_run_can_attach' "$LIB" && echo 0 || echo 1)"
ck "(a0) ⛔ the docstring does NOT state the REJECTED class-wide widen (review P2)" \
   "$(grep -q 'the STRUCTURAL class widens on it' <<<"$DOC" && echo 1 || echo 0)"
ck "(a0) ⛔ …nor the class-wide claim a push-triggered member falsifies ('no run can be STARTED by this PR')" \
   "$(grep -q 'can be STARTED by this PR' <<<"$DOC" && echo 1 || echo 0)"
ck "(a0) …and it NAMES the second condition, so the record cannot describe a one-condition policy again" \
   "$(grep -q 'lane_own_run_can_attach' <<<"$DOC" && echo 0 || echo 1)"
# ⛔ WHICH BULLET, NOT ONLY WHICH WORDS (round 7, P2). The rewritten record placed the
# fail-closed DEFAULT (an absent / unclassifiable trigger list) under the bullet that
# concludes "Widen" — while the helper returns "CAN attach" (0) for both shapes, so §0b
# KEEPS the filter. That is the fail-OPEN direction of the drift this docstring exists to
# prevent, and (a0)'s blacklist could not see it: it looked for the OLD rejected phrases,
# not for a NEW wrong placement. So the placement is pinned: the default is named in the
# KEPT bullet and NOT in the WIDEN one, and mutation (a13) is the falsifier.
WIDEN_BULLET="$(bullet_with "$DOC" 'Widen[.]')"
KEPT_BULLET="$(bullet_with "$DOC" 'Otherwise the filter is KEPT')"
ck "(a0) extracted the WIDEN bullet of the record (not pinning an empty seam)" \
   "$([ -n "$WIDEN_BULLET" ] && echo 0 || echo 1)"
ck "(a0) extracted the KEPT bullet of the record (not pinning an empty seam)" \
   "$([ -n "$KEPT_BULLET" ] && echo 0 || echo 1)"
ck "(a0) ⛔ the WIDEN bullet does NOT carry the fail-closed default ('absent or unclassifiable') — that default KEEPS the filter (round 7 P2)" \
   "$(grep -qi 'absent or unclassifiable' <<<"$WIDEN_BULLET" && echo 1 || echo 0)"
ck "(a0) the KEPT bullet DOES carry it, so a next lane reads the default on the arm it lands on" \
   "$(grep -qi 'absent or unclassifiable' <<<"$KEPT_BULLET" && echo 0 || echo 1)"
ck "(a0) …and the KEPT bullet says the default is the FAIL-CLOSED one" \
   "$(grep -qi 'fail-closed DEFAULT' <<<"$KEPT_BULLET" && echo 0 || echo 1)"
# ⛔ THE EXTRACTION ITSELF (round 8, P3). `bullet_with` used to set `end = NR` for the LAST
# bullet, so the KEPT bullet's text ran through the docstring's closing prose — and a claim
# moved OUT of the bullet into that prose still satisfied "the KEPT bullet carries it".
# The docstring's post-bullet prose begins `# ⛔ NOT a class-wide widen.`, so its absence
# from the extracted KEPT bullet is the proof that the bound is the bullet, not EOF.
ck "(a0) ⛔ the KEPT bullet's text STOPS at the bullet — it does not swallow the post-bullet prose (round 8 P3)" \
   "$(grep -q 'NOT a class-wide widen' <<<"$KEPT_BULLET" && echo 1 || echo 0)"

# ── (a9) MUTATION PROOF — reducing the gate to the class LABEL turns (a0)/(a2) RED ──
# The mutation is exactly the rejected policy in code: `lane_structural` alone widens.
# It must be visible to (a0) (whose predicate pin reads those very bytes) AND to (a2)
# (whose push lane then widens on one failed read — the fail-open review P1 rejected).
echo "(a9) MUTATION: the §0b gate reduced to the class LABEL → (a0)'s predicate pin and (a2) go RED"
PMUT="$TMP/predicate-mutant.sh"
awk '
  index($0, "if [ \"$lane_structural\" -eq 1 ] && ! lane_own_run_can_attach") > 0 {
    print "            if [ \"$lane_structural\" -eq 1 ]; then"; n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$PMUT"
ck "(a9) the mutation applied EXACTLY once to the widening gate (a silent no-op mutation would prove nothing)" "$?"
ck "(a9) the mutant parses (bash -n)" "$(bash -n "$PMUT" 2>/dev/null && echo 0 || echo 1)"
PMUTLIB="$TMP/predicate-mutant-lib.sh"
ck "(a9) the mutant still builds a lib carrying the gate (not testing an empty seam)" \
   "$(build_lib "$PMUT" "$PMUTLIB" && grep -q 'lane_structural' "$PMUTLIB" && echo 0 || echo 1)"
ck "(a9) against the mutant, (a0)'s predicate pin is RED — the gate no longer consults lane_own_run_can_attach" \
   "$(grep -qF 'lane_structural" -eq 1 ] && ! lane_own_run_can_attach' "$PMUTLIB" && echo 1 || echo 0)"
PM_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push)' \
  AP_PROBE_STATE=unreadable bash < "$PMUTLIB" 2>&1 >/dev/null)"
PM_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$PM_ERR")"
ck "(a9) …and (a2)'s push case WIDENS there (ANY_WORKFLOW='$PM_ANY' — the fail-open the old docstring described)" \
   "$([ "$PM_ANY" = 1 ] && echo 0 || echo 1)"

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
# ⛔ AND IT QUOTES THE MEASUREMENT IT TOOK (round 8, P2). The widen set is now "every declared
# member proven INERT", so the message must name the inert member it READ. The fixed
# three-name sentence it used to print ("declares no 'push', no 'workflow_dispatch' and no
# 'pull_request_review'") is a deny-list the code no longer holds — and it is exactly the
# wording that made a `pull_request_review_comment` lane look inert at round 7.
ck "(a) it quotes the MEASURED inert member it read ('workflow_call'), not a deny-list of names" \
   "$(grep -q "every trigger it declares ('workflow_call') is one that cannot put a run of it on a PR head" <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a) ⛔ the old deny-list sentence is GONE — a lane the code never classified as attachable is not called inert by name" \
   "$(grep -q "declares no 'push', no 'workflow_dispatch'" <<<"$R_ERR" && echo 1 || echo 0)"

# ── (a2)–(a4) THE FAIL-CLOSED DIRECTION (review P1) ────────────────────────
# `unreadable` is NOT an exemption for a STRUCTURAL lane whose OWN name can still
# appear on a run for this head. `on: push` is a member of this class and a push whose
# tip is $head (or a rerun of a CANCELLED run) attaches a run OF THAT WORKFLOW to THIS
# head while the wait runs — so the filtered wait is still a SIGNAL and the pre-#2465
# fail-closed behaviour must be preserved. `origin/main` failed closed for EVERY class;
# widening this subset is a merge-surface loosening nobody asked for (`--any-workflow`
# is the operator's escape, not a failed read).
echo "(a2) STRUCTURAL + 'push' + UNREADABLE probe — must KEEP the filter (fail closed)"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push)' unreadable
ck "(a2) NO widening on a failed read (ANY_WORKFLOW='$R_ANY', wf_args='$R_WFARGS') — a push-triggered lane CAN clear the filtered wait" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(a2) the certificate still names the requested lane (lane='$R_LANE')" \
   "$([ "$R_LANE" = "python-ci.yml" ] && echo 0 || echo 1)"
ck "(a2) it says LANE KEPT and names the FAILED read, so the operator is not left guessing" \
   "$(grep -q 'LANE KEPT' <<<"$R_ERR" && grep -q 'read FAILED' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a2) it does NOT print 'LANE INAPPLICABLE' (that string means the lane was DROPPED)" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(a2) ⛔ it does NOT claim the lane HAS a run — the probe never answered that" \
   "$(grep -q 'the lane HAS a run' <<<"$R_ERR" && echo 1 || echo 0)"
# ⛔ THE CLASS CLAUSE (round 2, P2). This message is shared by BOTH classes, so a
# STRUCTURAL lane told "it declares a PR trigger this changed set does not match" is
# contradicted by the reason the block just consumed — and that sentence is exactly the
# "cannot run" vs "did not run" confusion #2465 exists to remove. Pinned, because
# nothing else in the suite looked at the clause.
ck "(a2) the class clause names the STRUCTURAL fact AND the MEASURED trigger list ('push'), not the NOT-RUN wording" \
   "$(grep -q "declares no pull_request / pull_request_target, so no such PR event can START it" <<<"$R_ERR" && grep -q "declares 'push'" <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a2) ⛔ it does NOT say 'declares a PR trigger this changed set does not match' — that would contradict the reason it just read" \
   "$(grep -q 'declares a PR trigger this changed set does not match' <<<"$R_ERR" && echo 1 || echo 0)"

echo "(a3) STRUCTURAL + 'workflow_dispatch' + UNREADABLE probe — must KEEP the filter"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: workflow_dispatch)' unreadable
ck "(a3) NO widening: 'gh workflow run --ref <branch>' attaches a run of THIS workflow to THIS head" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
# ⛔ THE MECHANISM MUST MATCH THE TRIGGER THE CLAUSE NAMES (round 3, P2). The clause quotes
# the trigger the helper FOUND; a fixed parenthetical then offers "a push whose tip is $head"
# as the way in, which a `workflow_dispatch`-only lane's `on:` block cannot do. A mechanism
# the lane's own trigger cannot provide is a claim the code did not take.
KEPT_A3="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a3) the class clause names the MEASURED trigger it found ('workflow_dispatch')" \
   "$(grep -q "declares 'workflow_dispatch'" <<<"$KEPT_A3" && echo 0 || echo 1)"
ck "(a3) ⛔ it does NOT offer a PUSH as the mechanism — a workflow_dispatch-only lane has none" \
   "$(grep -q 'a push whose tip is' <<<"$KEPT_A3" && echo 1 || echo 0)"
ck "(a3) instead it names the mechanism that CAN start this lane ('gh workflow run --ref')" \
   "$(grep -q 'gh workflow run --ref' <<<"$KEPT_A3" && echo 0 || echo 1)"

# ── (a3b) A MULTI-TRIGGER LIST names ONLY the members that can attach (round 3, P1) ──
# The helper accumulates `found` from a comma list, so the message quotes a JOINED value.
# Nothing pinned its CONTENT for a list with more than one member: a mutant that appends
# `workflow_call` to the answer survived the whole suite, and naming `workflow_call` as
# attachable is exactly the #1413/#2465 confusion this design removes (a `workflow_call` run
# attaches under the CALLER's name, so this lane's own name never appears on the head). It
# also makes the multi-trigger line in the PR's own evidence a claim no arm produced.
echo "(a3b) STRUCTURAL + 'workflow_call, workflow_dispatch' + UNREADABLE — names ONLY the attachable member"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: workflow_call, workflow_dispatch)' unreadable
ck "(a3b) NO widening: the list holds an attachable member, so the filtered wait is still a SIGNAL" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
KEPT_A3B="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a3b) it names the attachable member it found ('workflow_dispatch')" \
   "$(grep -q "declares 'workflow_dispatch'" <<<"$KEPT_A3B" && echo 0 || echo 1)"
ck "(a3b) ⛔ it does NOT name 'workflow_call' — it cannot attach this lane's name to the head (#1413)" \
   "$(grep -q 'workflow_call' <<<"$KEPT_A3B" && echo 1 || echo 0)"

# ── (a3c) THE JOINED VALUE: two attachable members (round 4, P2) ────────────
# (a3b) exercises the accumulator but only ever produces a SINGLE-member answer, so the
# join (`found="${found:+$found }workflow_dispatch"`) and the case arm that must serve BOTH
# names were driven by no arm at all. And the push mechanism is only as permissive as THAT
# trigger's own `branches`/`paths` filter — `on: push: branches: [main]` cannot attach a run
# to a PR head (see .github/workflows/enforce-skills.yml) — which the reason clause does not
# carry, so the message must qualify it instead of asserting it flatly.
echo "(a3c) STRUCTURAL + 'push, workflow_dispatch' + UNREADABLE — both mechanisms named, the push one FILTER-QUALIFIED"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push, workflow_dispatch)' unreadable
ck "(a3c) NO widening: both members are attachable" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
KEPT_A3C="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a3c) the clause names BOTH members it found, joined ('push workflow_dispatch')" \
   "$(grep -q "declares 'push workflow_dispatch'" <<<"$KEPT_A3C" && echo 0 || echo 1)"
ck "(a3c) it names BOTH mechanisms, so neither trigger is left unexplained" \
   "$(grep -q 'a push whose tip is' <<<"$KEPT_A3C" && grep -q 'gh workflow run --ref' <<<"$KEPT_A3C" && echo 0 || echo 1)"
ck "(a3c) ⛔ the push mechanism is qualified by ITS OWN branches/paths filter — a main-only push cannot attach a PR head" \
   "$(grep -q "subject to that trigger's own 'branches'/'paths' filters" <<<"$KEPT_A3C" && echo 0 || echo 1)"

echo "(a4) STRUCTURAL + NO parseable trigger clause + UNREADABLE — the CONSERVATIVE default"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request' unreadable
ck "(a4) an unknown trigger shape KEEPS the filter (fail closed) — a producer-side change must not re-open the fail-open" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
# ⛔ AND IT MUST NOT BE DESCRIBED AS A MEASUREMENT (round 2, P2). On this path the helper
# could not READ the trigger list, so "it declares 'push'" would be a declaration the code
# never read — the exact class the file's own "nothing may claim a measurement the code did
# not take" rule forbids. The message must say the list was unread instead.
ck "(a4) the message says the trigger list could not be READ — it does not claim a declared trigger" \
   "$(grep -q 'could not be READ from the applicability reason' <<<"$R_ERR" && echo 0 || echo 1)"
# ⛔ THE OTHER GROUND (round 5, P3). An ABSENT clause was never read; the shape gate in
# arm (a8) read one and could not classify it. Reporting both as "could not be READ"
# under-claims in the safe direction, but this file's rule is claim ACCURACY — and if
# both arms print the same words, no assertion can tell which ground fired.
ck "(a4) ⛔ it does NOT claim the list was READ (this ground is the ABSENT clause — a8 owns the read-but-unclassifiable one)" \
   "$(grep -q 'WAS READ from the applicability reason' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(a4) ⛔ it does NOT print \"it declares '\" (a declared trigger it never read)" \
   "$(grep -q "it declares '" <<<"$R_ERR" && echo 1 || echo 0)"
# ⛔ AND THE TAIL MAY NOT RE-ASSERT WHAT THE CLAUSE JUST CALLED UNREAD (round 3, P2).
# "This class CAN still start a run while the wait runs" is the very capability this arm
# has just said it could not establish — and the sentence repeated the "not an exemption"
# rationale twice. Only the CONSEQUENCE may be stated here.
KEPT_A4="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a4) ⛔ the tail does NOT assert 'This class CAN still start a run' — the clause just called that unread" \
   "$(grep -q 'This class CAN still start a run' <<<"$KEPT_A4" && echo 1 || echo 0)"
ck "(a4) …but it still states the consequence, so the operator knows the wait applies and §1b refuses" \
   "$(grep -q 'The bounded wait applies, and §1b refuses if no run appears' <<<"$KEPT_A4" && echo 0 || echo 1)"

# ── (a5)/(a6) MUTATION PROOFS — (a2)/(a4) must discriminate on the helper ───
# Both mutations hit ONLY lane_own_run_can_attach, counted so a silent no-op proves
# nothing. (a5) makes the "can attach" answer unreachable for push; (a6) flips the
# absent-clause default to the LOOSENING one. Each must turn exactly its own arm RED.
echo "(a5) MUTATION: 'push' counted as INERT → arm (a2) is RED there"
# ⛔ THE MUTATION MOVED WITH THE POLARITY (round 8, P2). The allow-list is what decides, so
# the falsifier is a member wrongly ON it: put `push` in the inert set and a `push`-only lane
# widens on one failed read — the loosening review P1 rejected. (The old mutation re-spelled
# the deny-list's `case` arm, which no longer exists.)
HMUT="$TMP/helper-mutant-push.sh"
# The replacement line is passed in with -v so this suite never has to escape `$` inside an
# awk program (the same trick the collector uses below).
REPL='      workflow_call|schedule|push) inert="${inert:+$inert }$member" ;;'
awk -v repl="$REPL" '
  /^lane_own_run_can_attach\(\) \{/ { inh = 1 }
  inh && /^      workflow_call\|schedule\) inert=/ { print repl; n++; next }
  { print }
  inh && /^}$/ { inh = 0 }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$HMUT"
ck "(a5) the mutation applied EXACTLY once to the push branch" "$?"
ck "(a5) the mutant parses (bash -n)" "$(bash -n "$HMUT" 2>/dev/null && echo 0 || echo 1)"
HMUTLIB="$TMP/helper-mutant-push-lib.sh"
ck "(a5) the mutant still builds a lib carrying the helper (not testing an empty seam)" \
   "$(build_lib "$HMUT" "$HMUTLIB" && grep -q 'lane_own_run_can_attach' "$HMUTLIB" && echo 0 || echo 1)"
HM_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push)' \
  AP_PROBE_STATE=unreadable bash < "$HMUTLIB" 2>&1 >/dev/null)"
HM_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$HM_ERR")"
ck "(a5) against the mutant (a2)'s assertion is RED (ANY_WORKFLOW='$HM_ANY' — the failed read widened the merge surface again)" \
   "$([ "$HM_ANY" = 1 ] && echo 0 || echo 1)"

echo "(a6) MUTATION: the absent-clause default flipped to 'inert' → arm (a4) is RED there"
HMUT2="$TMP/helper-mutant-default.sh"
awk '
  /^lane_own_run_can_attach\(\) \{/ { inh = 1 }
  inh && /^    \*\) return 0 ;;$/ { print "    *) return 1 ;;"; n++; next }
  { print }
  inh && /^}$/ { inh = 0 }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$HMUT2"
ck "(a6) the mutation applied EXACTLY once to the absent-clause default" "$?"
HMUT2LIB="$TMP/helper-mutant-default-lib.sh"
ck "(a6) the mutant still builds a lib carrying the helper" \
   "$(build_lib "$HMUT2" "$HMUT2LIB" && grep -q 'lane_own_run_can_attach' "$HMUT2LIB" && echo 0 || echo 1)"
HM2_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request' \
  AP_PROBE_STATE=unreadable bash < "$HMUT2LIB" 2>&1 >/dev/null)"
HM2_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$HM2_ERR")"
ck "(a6) against the mutant (a4)'s assertion is RED (ANY_WORKFLOW='$HM2_ANY' — an unparseable trigger list widened)" \
   "$([ "$HM2_ANY" = 1 ] && echo 0 || echo 1)"

echo "(a7) MUTATION: an UNCLASSIFIED member treated as INERT → arm (a15) is RED there"
# ⛔ THIS IS THE ROUND-8 DEFECT ITSELF, in mutant form (review P2). The shipped helper keeps
# the filter for any member it cannot prove inert; the mutant does the opposite — the `*)`
# arm of the member loop stops forbidding the widen — so a lane whose only trigger is
# `pull_request_review_comment` WIDENS on one failed read. That is the loosening the review
# measured to be live (`replicate/cog` run 42472266861 has `head_sha` = PR #3216's head), and
# the reason the attachable set became an allow-list: a deny-list cannot be made complete.
HMUT3="$TMP/helper-mutant-unknown-inert.sh"
REPL3='        : # mutant: an unclassified member does NOT forbid the widen'
awk -v repl="$REPL3" '
  /^lane_own_run_can_attach\(\) \{/ { inh = 1 }
  inh && /^      \*\)$/ { print; print repl; skip = 1; n++; next }
  skip && /^        ;;$/ { skip = 0; print; next }
  skip { next }
  { print }
  inh && /^}$/ { inh = 0 }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$HMUT3"
ck "(a7) the mutation applied EXACTLY once to the member loop's unclassified arm" "$?"
ck "(a7) the mutant parses (bash -n)" "$(bash -n "$HMUT3" 2>/dev/null && echo 0 || echo 1)"
HMUT3LIB="$TMP/helper-mutant-unknown-inert-lib.sh"
ck "(a7) the mutant still builds a lib carrying the helper" \
   "$(build_lib "$HMUT3" "$HMUT3LIB" && grep -q 'lane_own_run_can_attach' "$HMUT3LIB" && echo 0 || echo 1)"
HM3_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: pull_request_review_comment)' \
  AP_PROBE_STATE=unreadable bash < "$HMUT3LIB" 2>&1 >/dev/null)"
HM3_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$HM3_ERR")"
ck "(a7) against the mutant (a15)'s assertion is RED (ANY_WORKFLOW='$HM3_ANY' — a review-comment-triggered lane widened on one failed read)" \
   "$([ "$HM3_ANY" = 1 ] && echo 0 || echo 1)"

# ── (a8) a PRESENT but UNCLASSIFIABLE clause must fail CLOSED ──
# The prose in `lane_own_run_can_attach` (and row D of the plan) said an unparseable
# clause answers "can attach"; the parser read every PRESENT clause as `measured` and
# widened on shapes it never parsed. Widening is the LOOSENING direction, so the shape
# gate is what makes the recorded guarantee true — pinned here on the two shapes a
# producer-side change would actually produce.
echo "(a8) STRUCTURAL + a PRESENT but UNPARSEABLE clause + UNREADABLE — must KEEP the filter"
for bad_clause in \
  'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push workflow_dispatch)' \
  'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push-to-fork)'
do
  drive inapplicable "$bad_clause" unreadable
  ck "(a8) NO widening on an unclassifiable list [${bad_clause##*(declared triggers: }]" \
     "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
  # ⛔ "READ BUT UNCLASSIFIABLE", NOT "UNREAD" (round 5, P3). The clause WAS read here —
  # the shape gate refused to name a member — so "could not be READ" was the wrong claim,
  # even though it under-claimed in the safe direction.
  # ⛔ "NOT ENTIRELY CLASSIFIABLE", NOT "no member is classifiable" (round 10, P3). The
  # shape gate is all-or-nothing, so both shapes below ARE `unclassifiable` — but
  # `push workflow_dispatch` and `push-to-fork` each carry a member this code classifies
  # perfectly, so "no member is classifiable" is false about a member that exists. The
  # label names the wording the message actually prints (a12)/(a14) pin the same rule.
  ck "(a8) …and the message says the list WAS READ but is not ENTIRELY classifiable" \
     "$(grep -q 'WAS READ from the applicability reason' <<<"$R_ERR" && echo 0 || echo 1)"
  ck "(a8) ⛔ …and it does NOT claim the list could not be READ (the code read it) (round 5 P3)" \
     "$(grep -q 'could not be READ from the applicability reason' <<<"$R_ERR" && echo 1 || echo 0)"
done
ck "(a8) CONTROL: a WELL-FORMED inert list ('workflow_call') still WIDENS — the shape gate tightens the unreadable shape only, not the #2465 narrowing" \
   "$(drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: workflow_call)' unreadable >/dev/null 2>&1; [ "$R_ANY" = 1 ] && echo 0 || echo 1)"

# ── (a10) A `pull_request_review`-ONLY LANE IS STRUCTURAL **AND** ATTACHABLE ──
# (round 7, P2) `PR_TRIGGERS` is `{pull_request, pull_request_target}`
# (scripts/ci-workflow-pr-evaluable.sh:106), so a `pull_request_review`-only lane is
# STRUCTURAL — while a SUBMITTED REVIEW runs that workflow ON THE PR HEAD, so
# `gh run list --commit $head --workflow $lane` CAN return it and the filtered wait is NOT
# inert. Leaving it out of the helper's closed set therefore WIDENED a lane whose own run
# attaches: the exact loosening review P1 rejected for `push`, and the diff's own message
# comment states the fact that falsifies it. Mutation (a11) is the falsifier.
echo "(a10) STRUCTURAL + 'pull_request_review' + UNREADABLE — its own run DOES attach, so KEEP"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: pull_request_review)' unreadable
ck "(a10) NO widening (ANY_WORKFLOW='$R_ANY') — a submitted review attaches a run of this lane to this head" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
KEPT_A10="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a10) it names the MEASURED member it found ('pull_request_review')" \
   "$(grep -q "declares 'pull_request_review'" <<<"$KEPT_A10" && echo 0 || echo 1)"
ck "(a10) it names the mechanism a review provides (a submitted review), not a push the lane cannot do" \
   "$(grep -q 'a submitted review of this PR' <<<"$KEPT_A10" && grep -q 'a push whose tip is' <<<"$KEPT_A10" && echo 1 || { grep -q 'a submitted review of this PR' <<<"$KEPT_A10" && echo 0 || echo 1; })"

echo "(a11) MUTATION: 'pull_request_review' counted as INERT → arm (a10) is RED there"
HMUT4="$TMP/helper-mutant-review-inert.sh"
REPL4='      workflow_call|schedule|pull_request_review) inert="${inert:+$inert }$member" ;;'
awk -v repl="$REPL4" '
  /^lane_own_run_can_attach\(\) \{/ { inh = 1 }
  inh && /^      workflow_call\|schedule\) inert=/ { print repl; n++; next }
  { print }
  inh && /^}$/ { inh = 0 }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$HMUT4"
ck "(a11) the mutation applied EXACTLY once to the inert set" "$?"
ck "(a11) the mutant parses (bash -n)" "$(bash -n "$HMUT4" 2>/dev/null && echo 0 || echo 1)"
HMUT4LIB="$TMP/helper-mutant-review-inert-lib.sh"
ck "(a11) the mutant still builds a lib carrying the helper" \
   "$(build_lib "$HMUT4" "$HMUT4LIB" && grep -q 'lane_own_run_can_attach' "$HMUT4LIB" && echo 0 || echo 1)"
HM4_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: pull_request_review)' \
  AP_PROBE_STATE=unreadable bash < "$HMUT4LIB" 2>&1 >/dev/null)"
HM4_ANY="$(sed -n 's/^ANY_WORKFLOW=//p' <<<"$HM4_ERR")"
ck "(a11) against the mutant (a10)'s assertion is RED (ANY_WORKFLOW='$HM4_ANY' — a review-triggered lane widened on one failed read)" \
   "$([ "$HM4_ANY" = 1 ] && echo 0 || echo 1)"

# ── (a15) A TRIGGER THIS CODE HAS NEVER HEARD OF IS NOT THEREBY INERT (round 8, P2) ──
# The helper's attachable set used to be a DENY-list, so any trigger it had not enumerated
# answered "cannot attach" — which WIDENS. `pull_request_review_comment` is the measured case:
# `PR_TRIGGERS` is `{pull_request, pull_request_target}`
# (scripts/ci-workflow-pr-evaluable.sh:106), so a review-comment-only lane is STRUCTURAL,
# while the run's `head_sha` IS the PR head (`replicate/cog` run 42472266861 has
# `head_sha 01fd5b9cfb` = PR #3216's head), so `gh run list --commit $head --workflow $lane`
# CAN return it and the filtered wait is NOT inert. Under the allow-list it is kept WITHOUT
# being enumerated — and that is the point: the next event GitHub ships needs no new arm.
# Mutation (a7) is the falsifier: it treats an unclassified member as inert and widens THIS lane.
echo "(a15) STRUCTURAL + 'pull_request_review_comment' (never enumerated) + UNREADABLE — KEEP"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: pull_request_review_comment)' unreadable
ck "(a15) NO widening (ANY_WORKFLOW='$R_ANY', wf_args='$R_WFARGS') — its run's head_sha IS the PR head" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(a15) the certificate still names the requested lane (lane='$R_LANE')" \
   "$([ "$R_LANE" = "python-ci.yml" ] && echo 0 || echo 1)"
KEPT_A15="$(grep 'LANE KEPT' <<<"$R_ERR")"
ck "(a15) it names the member it could not prove inert ('pull_request_review_comment')" \
   "$(grep -q "declares 'pull_request_review_comment'" <<<"$KEPT_A15" && echo 0 || echo 1)"
ck "(a15) it says the code cannot prove that member INERT, and that every member must be proven" \
   "$(grep -q 'cannot prove INERT' <<<"$KEPT_A15" && grep -q 'EVERY declared member to be proven inert' <<<"$KEPT_A15" && echo 0 || echo 1)"
# ⛔ AND IT MUST NOT CLASSIFY WHAT IT DID NOT CLASSIFY (round 8, P2). Offering the known
# mechanisms for a value this code has never seen asserts how the run attaches — the
# claim-without-a-measurement this block forbids. The tail states the consequence only.
ck "(a15) ⛔ it names NO mechanism for the unclassified member (no assumed push / dispatch / review)" \
   "$(if grep -q 'a push whose tip is' <<<"$KEPT_A15" || grep -q 'gh workflow run --ref' <<<"$KEPT_A15" || grep -q 'a submitted review of this PR' <<<"$KEPT_A15"; then echo 1; else echo 0; fi)"
ck "(a15) ⛔ …and it does not claim the member CAN attach either ('has not measured that')" \
   "$(grep -q 'has not measured that' <<<"$KEPT_A15" && echo 0 || echo 1)"
ck "(a15) ⛔ it does NOT print 'LANE INAPPLICABLE' (the lane was KEPT, not dropped)" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && echo 1 || echo 0)"

# ── (a16) AN EMPTY CLAUSE IS ITS OWN GROUND, NOT "NO MEMBER IS CLASSIFIABLE" (round 8, P3) ──
# `(declared triggers: )` is REACHABLE: `on: []` / `on: {}` reach the producer's inline path
# as an empty set (`scripts/ci-workflow-pr-evaluable.sh:161-190`) and it emits the clause with
# no member. The shape gate's `''` arm used to report `unclassifiable`, whose message says "at
# least one member is not a plain lowercase 'on:' key" — false about a list with zero members.
# Behaviour (keep) is unchanged and correct; the GROUND is what the message must name.
echo "(a16) STRUCTURAL + an EMPTY clause '(declared triggers: )' + UNREADABLE — kept, own ground"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: )' unreadable
ck "(a16) the filter is KEPT on an empty declaration (ANY_WORKFLOW='$R_ANY') — an empty set proves no member inert" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(a16) it says the list WAS READ and declares NO trigger at all" \
   "$(grep -q 'WAS READ from the applicability reason' <<<"$R_ERR" && grep -q 'declares NO trigger at all' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a16) ⛔ it does NOT claim 'at least one member is not a plain lowercase' — there is no member" \
   "$(grep -q 'at least one member is not a plain lowercase' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(a16) ⛔ …and it does NOT call the list unread ('could not be READ') — the code read it" \
   "$(grep -q 'could not be READ from the applicability reason' <<<"$R_ERR" && echo 1 || echo 0)"

# ── (a17) THE DESIGN RECORD STATES THE SHIPPED PREDICATE, NOT THE DENY-LIST (round 9, P2) ──
# The plan doc's Implementation-steps bullet is the prose a NEXT LANE IMPLEMENTS FROM, and it
# survived round 8 stating the superseded predicate: `unreadable` widens when the lane is
# "STRUCTURAL and its `on:` declares neither `push` nor `workflow_dispatch`" — a DENY-list, under
# which a `pull_request_review_comment`-only lane widens on one failed read (the R16 fail-open
# restored by the record). It also collapsed every non-measured shape into `unread`, which the
# code splits into three grounds (`unread` / `unclassifiable` / `empty`). No arm read the plan doc,
# so the suite stayed green while it drifted — (a0) pins the DOCSTRING only. This arm reads that
# bullet the way (a0) reads the docstring, and mutant (a18) restores the deny-list sentence to
# prove the pin is load-bearing rather than decorative.
PLAN_DOC="${PLAN_DOC_SRC:-$ROOT/docs/plans/2026-11-10-issue-2465-inert-first-checks-wait.md}"
extract_plan_bullet() { # $1 = plan doc — the `unreadable` sub-bullet of step 1
  awk '
    /^[[:space:]]*- `unreadable` → widen only where/ { inb = 1 }
    inb && /^[[:space:]]*⛔/ { exit }
    inb { print }
  ' "$1"
}
echo "(a17) the plan doc's step-1 unreadable-bullet states the SHIPPED allow-list, not the deny-list"
ck "(a17) the design record is present at $PLAN_DOC" \
   "$([ -f "$PLAN_DOC" ] && echo 0 || echo 1)"
PLAN_BULLET="$(extract_plan_bullet "$PLAN_DOC")"
ck "(a17) extracted step 1's unreadable-bullet (not pinning an empty seam)" \
   "$([ -n "$PLAN_BULLET" ] && echo 0 || echo 1)"
ck "(a17) ⛔ it does NOT state the DENY-list predicate ('declares neither …') — a review-comment lane widens under it (round 9 P2)" \
   "$(grep -q 'declares neither' <<<"$PLAN_BULLET" && echo 1 || echo 0)"
ck "(a17) it states the ALLOW-LIST polarity: EVERY declared member proven INERT" \
   "$(grep -q 'EVERY declared' <<<"$PLAN_BULLET" && grep -q 'ALLOW-LIST' <<<"$PLAN_BULLET" && echo 0 || echo 1)"
ck "(a17) it names BOTH known-inert members the helper's set carries ('workflow_call', 'schedule')" \
   "$(grep -q 'workflow_call' <<<"$PLAN_BULLET" && grep -q 'schedule' <<<"$PLAN_BULLET" && echo 0 || echo 1)"
ck "(a17) ⛔ it does NOT collapse a clause that WAS read into 'unread' (the round-5 enum)" \
   "$(grep -q 'UNCLASSIFIABLE shape is' <<<"$PLAN_BULLET" && echo 1 || echo 0)"
ck "(a17) it names the THREE non-measured grounds the code distinguishes (unread / unclassifiable / empty)" \
   "$(grep -qF '`unread` (no clause at all)' <<<"$PLAN_BULLET" && grep -qF '`unclassifiable`' <<<"$PLAN_BULLET" && grep -qF '`empty`' <<<"$PLAN_BULLET" && echo 0 || echo 1)"

# ── (a18) MUTATION — the deny-list sentence restored in the plan doc turns (a17) RED ──
# The round-9 defect verbatim. A prose pin that no mutation can falsify proves nothing (the
# round-8 lesson), so the pre-round-8 sentence is re-inserted into a COPY of the design record
# and the same assertion that guards it must go RED there.
echo "(a18) MUTATION: the deny-list predicate put back in the plan doc → the (a17) pin is RED there"
PLANMUT="$TMP/plan-deny-list-mutant.md"
awk '
  /^[[:space:]]*- `unreadable` → widen only where/ {
    print
    print "     `STRUCTURAL` **and** its `on:` declares neither `push` nor `workflow_dispatch`."
    n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$PLAN_DOC" > "$PLANMUT"
ck "(a18) the mutation applied EXACTLY once to step 1's unreadable-bullet (a silent no-op mutation would prove nothing)" "$?"
PLANMUT_BULLET="$(extract_plan_bullet "$PLANMUT")"
ck "(a18) the mutant bullet is still extractable (not testing an empty seam)" \
   "$([ -n "$PLANMUT_BULLET" ] && echo 0 || echo 1)"
ck "(a18) against the mutant, (a17)'s deny-list row is RED — the shipped record would fail this pin" \
   "$(grep -q 'declares neither' <<<"$PLANMUT_BULLET" && echo 0 || echo 1)"
ck "(a18) …and the mutant still satisfies the allow-list rows, so the pin fails on the DENY-LIST alone, not on an unrelated regression" \
   "$(grep -q 'EVERY declared' <<<"$PLANMUT_BULLET" && grep -q 'ALLOW-LIST' <<<"$PLANMUT_BULLET" && echo 0 || echo 1)"

# ── (a12) A MIXED LIST: "NO MEMBER IS CLASSIFIABLE" IS FALSE ABOUT THE MEMBER THAT IS ──
# (round 7, P3) The shape gate is ALL-OR-NOTHING, so `push, push-to-fork` fails the whole
# list — and `push` IS a plain lowercase `on:` key this code classifies perfectly. The
# message called that list one where "no member of it is a plain lowercase 'on:' key",
# which is a claim accuracy violation by this block's own rule (under-claiming is still a
# mis-claim). "not ENTIRELY classifiable / at least one member" is the honest form.
# Mutation (a14) restores the false wording.
echo "(a12) STRUCTURAL + a MIXED list ('push, push-to-fork') + UNREADABLE — not entirely classifiable"
drive inapplicable 'lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push, push-to-fork)' unreadable
ck "(a12) the all-or-nothing shape gate still KEEPS the filter (ANY_WORKFLOW='$R_ANY')" \
   "$([ "$R_ANY" = 0 ] && [ -z "$R_WFARGS" ] && echo 0 || echo 1)"
ck "(a12) it says the list is not ENTIRELY classifiable" \
   "$(grep -q 'not ENTIRELY classifiable' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(a12) ⛔ it does NOT claim NO member is classifiable — 'push' IS (round 7 P3)" \
   "$(grep -q 'no member of it is a plain lowercase' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(a12) …and it still says the list WAS READ, not that it was unreadable" \
   "$(grep -q 'WAS READ from the applicability reason' <<<"$R_ERR" && echo 0 || echo 1)"

echo "(a14) MUTATION: the 'no member is classifiable' wording restored → arm (a12) is RED there"
WMUT="$TMP/mixed-wording-mutant.sh"
awk '
  /lane_list_ground="WAS READ from the applicability reason, but it is not ENTIRELY classifiable/ {
    print "                lane_list_ground=\"WAS READ from the applicability reason, but no member of it is a plain lowercase " sprintf("%c",39) "on:" sprintf("%c",39) " key this code can classify\""
    n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$WMUT"
ck "(a14) the mutation applied EXACTLY once to the unclassifiable message" "$?"
ck "(a14) the mutant parses (bash -n)" "$(bash -n "$WMUT" 2>/dev/null && echo 0 || echo 1)"
WMUTLIB="$TMP/mixed-wording-mutant-lib.sh"
ck "(a14) the mutant still builds a lib carrying §0b" \
   "$(build_lib "$WMUT" "$WMUTLIB" && grep -q 'lane_own_run_can_attach' "$WMUTLIB" && echo 0 || echo 1)"
WM_ERR="$(AP_VERDICT=inapplicable \
  AP_REASON='lane-applicable: no-pr-trigger — declares no pull_request (declared triggers: push, push-to-fork)' \
  AP_PROBE_STATE=unreadable bash < "$WMUTLIB" 2>&1 >/dev/null)"
ck "(a14) against the mutant (a12)'s assertion is RED (the false 'no member' wording is printed again)" \
   "$(grep -q 'no member of it is a plain lowercase' <<<"$WM_ERR" && echo 0 || echo 1)"

# ── (a13) MUTATION — the fail-closed default restored UNDER "Widen" turns (a0) RED ──
# This is the round-7 defect verbatim: the rewritten record put the absent/unclassifiable
# default — which the helper answers "can attach" (keep) for — in the bullet concluding
# "Widen". (a0)'s phrase blacklist could not see it, because the words were new; the
# placement pin above is what does, and this mutant is its falsifier.
echo "(a13) MUTATION: the fail-closed default put back under 'Widen' → the (a0) placement pin is RED there"
DMUT="$TMP/docstring-mutant.sh"
awk '
  /^#   \* BOTH hold — STRUCTURAL, and EVERY declared .on:. member is a KNOWN-INERT/ {
    print
    print "#     (an absent or unclassifiable trigger list included: the fail-closed default)."
    n++; next
  }
  { print }
  END { exit (n == 1 ? 0 : 1) }
' "$SRC" > "$DMUT"
ck "(a13) the mutation applied EXACTLY once to the WIDEN bullet" "$?"
ck "(a13) the mutant parses (bash -n)" "$(bash -n "$DMUT" 2>/dev/null && echo 0 || echo 1)"
DMUTDOC="$(extract_docstring "$DMUT" lane_no_pr_trigger)"
ck "(a13) the mutant's docstring is still extractable (not testing an empty seam)" \
   "$([ -n "$DMUTDOC" ] && echo 0 || echo 1)"
ck "(a13) against the mutant, (a0)'s 'WIDEN bullet does NOT carry the fail-closed default' row is RED" \
   "$(DMW="$(bullet_with "$DMUTDOC" 'Widen[.]')"; grep -qi 'absent or unclassifiable' <<<"$DMW" && echo 0 || echo 1)"


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
# ⛔ THIS IS THE LAST SILENT PATH (review P2): fail-closed is correct, but a QUIET
# fail-closed is exactly the 65-minute burn #2465 was filed about — the operator sees a
# wait that blames CI and never names the classification. The decision must stay the
# same; only the message is required.
ck "(c3) …and it is NOT SILENT: the kept lane and the failed read are named (#2465)" \
   "$(grep -q 'LANE KEPT' <<<"$R_ERR" && grep -q 'read FAILED' <<<"$R_ERR" && echo 0 || echo 1)"
ck "(c3) …and it does NOT claim the lane was dropped ('LANE INAPPLICABLE' means the filter was DROPPED)" \
   "$(grep -q 'LANE INAPPLICABLE' <<<"$R_ERR" && echo 1 || echo 0)"
ck "(c3) …and it still reports the fail-closed reason, so a reader can act (§1b / --any-workflow)" \
   "$(grep -q 'fail closed' <<<"$R_ERR" && grep -q -- '--any-workflow' <<<"$R_ERR" && echo 0 || echo 1)"
# ⛔ THE OTHER SIDE OF THE SAME CLAUSE (round 2, P2): the genuine NOT-RUN class must KEEP
# its own wording — making the clause conditional is only correct if it still discriminates.
ck "(c3) the class clause says the NOT-RUN fact for a paths-excluded lane (the conditional did not flatten both classes)" \
   "$(grep -q 'declares a PR trigger this changed set does not match' <<<"$R_ERR" && echo 0 || echo 1)"

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
printf 'LAND_SAW_ONESHOT=[%s]\n' "${ADMIN_MERGE_FIRST_CHECKS_ONESHOT-<unset>}" >&2
printf 'LAND_SAW_STALL=[%s]\n' "${ADMIN_MERGE_FIRST_CHECKS_STALL-<unset>}" >&2
printf 'LAND_SAW_CEILING=[%s]\n' "${ADMIN_MERGE_FIRST_CHECKS_CEILING-<unset>}" >&2
printf 'LAND_ARGV=%s\n' "$*" >&2
exit 0
LANDEOF
chmod +x "$FAKE_LAND"

# $1 = NO_WAIT, $2 = pre-existing ADMIN_MERGE_FIRST_CHECKS_WAIT (EMPTY = genuinely UNSET —
# an empty-but-exported value would be a different state, and `[ -z ]` cannot tell them apart),
# $3 = DRY_RUN, $4 = QUEUE_MODE, $5/$6 = pre-existing ADMIN_MERGE_FIRST_CHECKS_STALL/_CEILING.
# ⛔ ALL FOUR knobs are wiped with `env -u` first: a stray value INHERITED from this suite's
# own environment would otherwise decide an arm, which is how a test passes on one box and
# fails on another.
land_err() {
  local pre=() wipe=(-u ADMIN_MERGE_FIRST_CHECKS_WAIT -u ADMIN_MERGE_FIRST_CHECKS_ONESHOT -u ADMIN_MERGE_FIRST_CHECKS_STALL -u ADMIN_MERGE_FIRST_CHECKS_CEILING)
  [ -n "${2:-}" ] && pre=("ADMIN_MERGE_FIRST_CHECKS_WAIT=$2")
  [ -n "${5:-}" ] && pre+=("ADMIN_MERGE_FIRST_CHECKS_STALL=$5")
  [ -n "${6:-}" ] && pre+=("ADMIN_MERGE_FIRST_CHECKS_CEILING=$6")
  NO_WAIT="$1" DRY_RUN="${3:-0}" QUEUE_MODE="${4:-0}" ADMIN_MERGE="$FAKE_LAND" \
    env "${wipe[@]}" ${pre[@]+"${pre[@]}"} \
    bash < "$DLIB" 2>&1 >/dev/null
}
saw() { sed -n 's/^LAND_SAW_WAIT=\[//p' <<<"$1" | sed 's/\]$//'; }
sawk() { sed -n "s/^LAND_SAW_${2}=\[//p" <<<"$1" | sed 's/\]$//'; }

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

# ── (B6) the rail's 0 seam is CONDITIONAL: an inherited STALL/CEILING re-enables it ──
# `admin-merge.sh` only takes the "one observation" path when the legacy window is 0 AND
# neither progress bound is set. So carrying `ADMIN_MERGE_FIRST_CHECKS_WAIT=0` alone is NOT
# enough: with `ADMIN_MERGE_FIRST_CHECKS_STALL=600` inherited, `wait_enabled` stays 1 and the
# caller who declined to wait waits until the STALL bound instead — #2465's own defect, one
# layer down. The rail's dedicated `ADMIN_MERGE_FIRST_CHECKS_ONESHOT` seam is what carries the
# intent, because CLEARING the bounds is the wrong remedy: `ADMIN_MERGE_FIRST_CHECKS_CEILING`
# is a term of the derived whole-attempt bound, so emptying it RAISES `RAIL_DEADLINE`
# (CEILING 600 -> 18064 is 3990s -> 21454s) and a legal `ADMIN_MERGE_LOCK_TTL` then refuses
# with exit 2. This arm is RED against the version that carried only the window AND against
# the version that cleared the bounds.
echo "(B6) --no-wait carries the ONE-SHOT seam and leaves an INHERITED STALL/CEILING untouched (review P2)"
E="$(land_err 1 '' 0 0 600 1200)"
ck "(B6) the 0 seam is still carried (saw '$(saw "$E")')" \
   "$([ "$(saw "$E")" = 0 ] && echo 0 || echo 1)"
ck "(B6) the rail is handed the dedicated ONESHOT seam (saw '$(sawk "$E" ONESHOT)')" \
   "$([ "$(sawk "$E" ONESHOT)" = 1 ] && echo 0 || echo 1)"
ck "(B6) ⛔ the inherited STALL is PRESERVED, not cleared (saw '$(sawk "$E" STALL)')" \
   "$([ "$(sawk "$E" STALL)" = 600 ] && echo 0 || echo 1)"
ck "(B6) ⛔ the inherited CEILING is PRESERVED — clearing it moves the derived whole-attempt bound and can exit 2 (saw '$(sawk "$E" CEILING)')" \
   "$([ "$(sawk "$E" CEILING)" = 1200 ] && echo 0 || echo 1)"
ck "(B6) the carry is SAID OUT LOUD, and names the deadline hazard as the reason not to clear" \
   "$(grep -q 'ADMIN_MERGE_FIRST_CHECKS_ONESHOT=1' <<<"$E" && grep -q 'whole-attempt deadline' <<<"$E" && echo 0 || echo 1)"
ck "(B6) the ONESHOT seam is carried on the DEFAULT path too, not only when a bound is inherited" \
   "$([ "$(sawk "$(land_err 1 '')" ONESHOT)" = 1 ] && echo 0 || echo 1)"
ck "(B6) and nothing is carried without --no-wait (no ONESHOT on the B2 path)" \
   "$([ "$(sawk "$(land_err 0 '')" ONESHOT)" = '<unset>' ] && echo 0 || echo 1)"

# ── (B7) an explicit WAIT=0 is the SAME instruction as --no-wait, not an override ──
# The carry used to be gated on WAIT being UNSET, so `ADMIN_MERGE_FIRST_CHECKS_WAIT=0`
# in the environment made `--no-wait` a SILENT no-op: no ONESHOT, no log line — and with
# an inherited STALL/CEILING the rail kept a LIVE bounded wait (8760s / 18064s) for a
# caller who had declined to wait TWICE. B3 (an explicit 600) still wins; 0 is the same
# intent expressed a second way, so the carry must proceed.
echo "(B7) --no-wait with an explicit WAIT=0 still carries the ONESHOT seam (not a silent no-op)"
E="$(land_err 1 0 0 0 600 1200)"
ck "(B7) the 0 window is preserved (saw '$(saw "$E")')" \
   "$([ "$(saw "$E")" = 0 ] && echo 0 || echo 1)"
ck "(B7) the ONESHOT seam IS carried — WAIT=0 does not suppress the flag's carry (saw '$(sawk "$E" ONESHOT)')" \
   "$([ "$(sawk "$E" ONESHOT)" = 1 ] && echo 0 || echo 1)"
ck "(B7) the inherited bounds stay untouched (STALL='$(sawk "$E" STALL)', CEILING='$(sawk "$E" CEILING)')" \
   "$([ "$(sawk "$E" STALL)" = 600 ] && [ "$(sawk "$E" CEILING)" = 1200 ] && echo 0 || echo 1)"
ck "(B7) and the carry is still SAID OUT LOUD (an ignored flag must never be silent)" \
   "$(grep -q 'ADMIN_MERGE_FIRST_CHECKS_ONESHOT=1' <<<"$E" && echo 0 || echo 1)"
ck "(B7) but an explicit NON-ZERO window still wins, carrying nothing (B3 unchanged)" \
   "$([ "$(sawk "$(land_err 1 600)" ONESHOT)" = '<unset>' ] && echo 0 || echo 1)"

# ── (C) the `*)` REFUSAL MUST NOT ASSERT A MEASUREMENT IT DID NOT TAKE ──────
# Review rounds 4 AND 5 (P2, same class, twice). The `*)` arm splits two states that must
# not share a verdict: "the surface was READ and was still pending" (`still-running`) vs
# "the progress signal was not available" (`unobservable`). It used to split on
# `FIRST_CHECKS_MISSING`, which advances by `dt` in WHOLE seconds — so on a poll whose work
# fits inside one second it is 0 while the state is `unobservable`, and the refusal
# reported an unread Jobs API as "NOTHING was unreadable". Reachable on exactly the
# `--no-wait` path this PR ships, because the one-shot path returns `$FIRST_CHECKS_STATE`
# after ONE observation. Round 5 then found the STATE is not the CAUSE either:
# `unobservable` has TWO producers — a FAILED Jobs read AND the >FIRST_CHECKS_JOBS_MAX cap,
# where the read is deliberately NOT ATTEMPTED and the surface was perfectly readable —
# plus a recovery case (`unobservable` → `still-running`) that keeps its accumulated
# `missing`, so "NOTHING was unreadable" was false about the WHOLE wait.
# The arm drives the SHIPPED `block_on_first_checks` (extracted, never copied) with an
# explicit (state, reason, clock) triple, so it is deterministic: no $SECONDS, no polling,
# no fake gh. Those are INPUTS here, which is the whole point — the defect was the code
# reading one of them as a measurement of another.
BOFC_LIB="$TMP/bofc.sh"
build_bofc() { # $1 = source path, $2 = output file
  local src="$1" out="$2" fn
  fn="$(extract_helper "$src" block_on_first_checks)"
  {
    printf '%s\n' 'say_err() { printf "%s\n" "$*" >&2; }'
    printf '%s\n' "$fn"
    printf '%s\n' 'block_on_first_checks deadbeef'
  } > "$out"
  [ -n "$fn" ]
}
ck "extracted block_on_first_checks from $(basename "$SRC") — the star arm is EXECUTED, not assumed" \
   "$(build_bofc "$SRC" "$BOFC_LIB" && echo 0 || echo 1)"
# bofc <state> <signal-reason> <missing> <missing_streak> <outcome> [<missing_unreadable> <streak_unreadable>] → refusal text
# BOFC_ONESHOT=<empty> drives the same refusal for a caller that did NOT decline to wait
# (the knob is documented as "non-empty ⇒ on", so an EMPTY value is the only way to be
# off — `=0` is truthy, which is the header's stated contract).
# ⛔ THE UNREADABLE-ATTRIBUTABLE COUNTERS ARE INPUTS TOO (review round 6, P2). The refusal
# quotes `FIRST_CHECKS_MISSING_UNREADABLE`/`_STREAK_UNREADABLE`, not the totals, because a
# wait that spent polls over the >JOBS_MAX cap has a `missing` larger than the time the
# Jobs API actually failed to answer for. When the ground IS `unreadable` the two coincide
# (a wait whose only cause was a failed read — the common case), so they DEFAULT to the
# totals; a MIXED wait passes them explicitly and that is the arm below that pins the fix.
bofc() {
  local mu su
  mu="${6:-}"; su="${7:-}"
  if [ -z "$mu" ]; then
    if [ "$2" = "unreadable" ]; then mu="$3"; su="$4"; else mu=0; su=0; fi
  fi
  [ -n "$su" ] || su=0
  FIRST_CHECKS_OUTCOME="$5" FIRST_CHECKS_STATE="$1" FIRST_CHECKS_SIGNAL_REASON="$2" \
  FIRST_CHECKS_MISSING="$3" FIRST_CHECKS_MISSING_STREAK="$4" \
  FIRST_CHECKS_MISSING_UNREADABLE="$mu" FIRST_CHECKS_STREAK_UNREADABLE="$su" \
  FIRST_CHECKS_WAIT=0 FIRST_CHECKS_WAITED=0 FIRST_CHECKS_JOBS_MAX=8 \
  FIRST_CHECKS_CEILING_BOUND=18064 FIRST_CHECKS_STALL_BOUND=8760 \
  FIRST_CHECKS_OBSERVED='run 123: 28 job(s): 2 completed, 26 not' \
  ADMIN_MERGE_FIRST_CHECKS_ONESHOT="${BOFC_ONESHOT-1}" \
    bash < "$BOFC_LIB" 2>&1 >/dev/null
}

echo "(C) the ONE-SHOT refusal claims only the measurement it took"
C_UNREAD="$(bofc unobservable unreadable 0 0 unobservable)"
ck "(C) an UNREADABLE Jobs read with a 0s clock does NOT claim 'NOTHING was unreadable' (round 4 P2)" \
   "$(grep -q 'NOTHING was unreadable' <<<"$C_UNREAD" && echo 1 || echo 0)"
ck "(C) …and it NAMES the failed read instead (the state is the measurement, not the clock)" \
   "$(grep -q 'the Jobs read FAILED' <<<"$C_UNREAD" && echo 0 || echo 1)"
ck "(C) …and it quotes NO duration for a read no time was measured against" \
   "$(grep -q 'did not answer for [0-9]*s in total' <<<"$C_UNREAD" && echo 1 || echo 0)"
C_CAP="$(bofc unobservable cap 0 0 unobservable)"
ck "(C) the >8-pending CAP does NOT claim the Jobs read failed — the surface was READABLE and the read was withheld (round 5 P2)" \
   "$(grep -q 'the Jobs read FAILED' <<<"$C_CAP" && echo 1 || echo 0)"
ck "(C) …and it names the CAP as the ground, so the refusal says what actually happened" \
   "$(grep -q 'MORE THAN 8 run' <<<"$C_CAP" && grep -q 'deliberately NOT read' <<<"$C_CAP" && echo 0 || echo 1)"
ck "(C) …and it quotes NO duration, because none was measured against a read never attempted" \
   "$(grep -q 'did not answer for' <<<"$C_CAP" && echo 1 || echo 0)"
# ⛔ A WIDTH CAP MUST NOT CLAIM THE ENDPOINT WAS HEALTHY (review round 8, P2). The cap is a
# COUNT condition, so on that poll the Jobs endpoint was never asked; "the surface was
# READABLE" was a measurement the code did not take — false in exactly the outage case that
# matters (9 pending runs during a 403 storm reproduced it).
ck "(C) a WIDTH CAP does NOT claim the Jobs surface was READABLE (it never asked) (round 8 P2)" \
   "$(grep -q 'surface was READABLE' <<<"$C_CAP" && echo 1 || echo 0)"
ck "(C) …instead it names itself as a WIDTH cap, not an unreadability finding" \
   "$(grep -q 'not an unreadability finding' <<<"$C_CAP" && echo 0 || echo 1)"
C_READ="$(bofc still-running '' 0 0 still-running)"
ck "(C) CONTROL: a READABLE still-pending surface still says 'NOTHING was unreadable' (the honest branch is still reachable)" \
   "$(grep -q 'NOTHING was unreadable' <<<"$C_READ" && echo 0 || echo 1)"
ck "(C) CONTROL: …and does NOT claim the Jobs read failed" \
   "$(grep -q 'the Jobs read FAILED' <<<"$C_READ" && echo 1 || echo 0)"
# ⛔ NO "RECOVERED SURFACE" ROWS — THERE IS NO RECOVERED SURFACE (review round 9, P2).
# Round 5 added a `MISSING_UNREADABLE > 0` branch here on the premise "a wait that
# recovered from an `unobservable` poll keeps its accumulated `missing`". The premise is
# right in general and the branch was still DEAD CODE: `OUTCOME=still-running` comes only
# from the ONE-SHOT return (`admin-merge.sh:5782`), which returns after the first
# verdict-reaching poll, and a multi-poll wait that was ever `unobservable` expires as
# `stalled`/`ceiling` — each with its OWN case arm. So this arm is reached only when the
# last poll read the surface fine, with no earlier poll able to have advanced the counter.
# The branch is deleted (a dead branch that reads like coverage is worth less than no
# branch), and the two rows that injected the impossible `MU>0` tuple are deleted with it:
# they could only fail on an edit to dead text, which is not coverage. What pins the real
# CAP-vs-unreadable-vs-never-started distinction is the PRODUCER:
# `tests/first-checks-lane-rederive` arm (g) and its mutation.
## ⛔ NO SEPARATE "CAP-ONLY RECOVERED" ROW (review round 8, P2). `missing` is ONE scalar with
# no cause attached, so an injected tuple cannot distinguish "the only `missing` was CAP polls"
# from "never-started seconds" — the row would be decorative, not a guard. The distinction is
# carried by `FIRST_CHECKS_MISSING_UNREADABLE`, and `C_RECOVER_FRESH` above already pins the
# MU=0 case (the only thing an injection can actually express). The CAP-vs-never-started
# distinction is pinned where it is real: in the PRODUCER, by
# tests/first-checks-lane-rederive's arm (g) and its mutation.
C_SLOW="$(bofc unobservable unreadable 3 1 unobservable)"
ck "(C) CONTROL: a MEASURED 3s of unreadable reads is still quoted as a duration" \
   "$(grep -q 'answer for 3s in total, 1s consecutively' <<<"$C_SLOW" && echo 0 || echo 1)"
# ⛔ THE MIXED WAIT (review round 6, P2). `missing` sums the `unobservable` time from BOTH
# of that state's producers — a FAILED read and the >JOBS_MAX cap, where the read is
# deliberately NOT ATTEMPTED. Quoting `missing` charged the cap's seconds to a read failure
# that never happened. Here 5s of `missing` contains only 3s of genuinely unreadable time:
# the refusal must quote 3s, and must NOT claim 5s.
C_MIX="$(bofc unobservable unreadable 5 2 unobservable 3 1)"
ck "(C) a MIXED wait (cap polls + failed-read polls) quotes ONLY the unreadable-attributable seconds (round 6 P2)" \
   "$(grep -q 'answer for 3s in total, 1s consecutively' <<<"$C_MIX" && ! grep -q 'answer for 5s' <<<"$C_MIX" && echo 0 || echo 1)"
# ⛔ THE OTHER ORDERING (review round 7, P2). A cap poll is the LAST observation, not the
# only one — a mixed wait that ENDED on a cap poll used to take the cap branch and deny the
# seconds it had really spent blind, so which ground the operator learned about still
# depended on which poll landed last.
C_MIXCAP="$(bofc unobservable cap 5 2 unobservable 3 1)"
ck "(C) a MIXED wait that ENDS on a cap poll still states the seconds it spent blind (round 7 P2)" \
   "$(grep -qE 'Separately, 3s of this wait DID go by with the Jobs read' <<<"$C_MIXCAP" && echo 0 || echo 1)"
ck "(C) …and still names the CAP as the ground of the refusal (both grounds, not one)" \
   "$(grep -q 'MORE THAN 8 run' <<<"$C_MIXCAP" && echo 0 || echo 1)"
# ⛔ AND IT MUST NOT QUOTE A STREAK HERE (review round 8, P2). Reaching this branch means the
# LAST poll was a cap, and a cap poll ZEROES the unreadable streak — so the figure is
# structurally 0 and would print beside a non-zero total, which reads as self-refutation.
# The injected `3 1` below is deliberately an UNREACHABLE streak; the arm must ignore it.
ck "(C) …but does NOT quote the consecutive figure, which is structurally 0 in this arm (round 8 P2)" \
   "$(grep -qi 'consecutiv' <<<"$C_MIXCAP" && echo 1 || echo 0)"
# ⛔ THE CONTROL: a PURE cap wait (nothing ever blind) must not acquire the unreadable
# sentence — the fix must not make every cap refusal talk about a read failure.
ck "(C) CONTROL: a PURE cap wait does NOT claim any seconds were spent blind (round 7 P2)" \
   "$(grep -q 'DID go by with the Jobs read' <<<"$C_CAP" && echo 1 || echo 0)"
# ⛔ AND THE CATCH-ALL MUST NOT INVENT A GROUND (review round 6, P2). With a reason that
# is neither `cap` nor `unreadable`, the old text asserted "the Jobs read FAILED" — a
# measurement the code did not take, the exact class this block exists to stop.
C_UNK="$(bofc unobservable '' 2 1 unobservable)"
ck "(C) an UNRECOGNISED ground claims NEITHER a failed read nor a duration (round 6 P2)" \
   "$(grep -q 'the Jobs read FAILED' <<<"$C_UNK" && echo 1 || { grep -q 'did not answer for' <<<"$C_UNK" && echo 1 || echo 0; })"
ck "(C) …and it SAYS the ground was not one this wait measured, instead of guessing" \
   "$(grep -q 'GROUND was' <<<"$C_UNK" && echo 0 || echo 1)"
# ⛔ THE `why only ONE observation` BLOCK IS A NEW GUARD, SO IT GETS A ROW (review
# round 5, note). It explains a ONE-OBSERVATION refusal to the operator — the sentence
# that must never appear for a caller who did not decline to wait.
C_WHY="$(bofc still-running '' 0 0 still-running)"
ck "(C) a ONE-SHOT refusal SAYS WHY it took one observation (the operator must not have to guess)" \
   "$(grep -q 'why only ONE observation' <<<"$C_WHY" && grep -q 'ADMIN_MERGE_FIRST_CHECKS_ONESHOT is set' <<<"$C_WHY" && echo 0 || echo 1)"
BOFC_ONESHOT= C_NOFLAG="$(bofc still-running '' 0 0 still-running)"
ck "(C) …and a caller who did NOT decline to wait gets no such explanation — it points at the window/knob instead" \
   "$(grep -q 'why only ONE observation' <<<"$C_NOFLAG" && echo 1 || { grep -q 're-run the rail once those checks complete' <<<"$C_NOFLAG" && echo 0 || echo 1; })"


echo
printf 'issue #2465 inert wait: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
