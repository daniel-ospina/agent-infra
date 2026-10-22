#!/usr/bin/env bash
# lander.test.sh — the contract for `lander.sh` (the versioned drain loop). HERMETIC: stub gh only,
# no network, no real repo, no tmux.
#
# ── WHAT IT MUST PROVE (the six arms the component exists for) ─────────────────────────────────
#   PENDING      a MERGEABLE + all-green-SO-FAR PR whose CI is still running is NOT merged and is NOT
#                reported as failed/skipped. This is the measured case (127 runs queued against 5 in
#                progress, 2026-10-22) and the one this file must not be able to pass vacuously.
#   GREEN        a MERGEABLE + all-green PR IS merged, head-pinned, and the merge sha is reported.
#   FAILED       a PR with one failing check is skipped and the failing check is NAMED.
#   DRAFT        a draft is skipped at any state.
#   BLOCKED      a BLOCKED PR with green checks is reported with its blocker and NOT merged.
#   QUEUE LINE   the CI queue-depth line is printed once per run, INCLUDING a run that merged nothing.
#
# Plus three arms that are cheap and catch the traps this component was built around:
#   rc           real `gh pr checks` exits 1 on a failing PR; that rc must NOT be read as "unreadable"
#                (which would report a red PR as merely waiting, forever);
#   unknown      a check conclusion the file has not been taught is a FAILURE, never a pass;
#   board        an unreadable PR board exits 2 and merges NOTHING (an unreadable board must never
#                read as "no open PRs").
#
# ── NON-VACUITY (run it: `bash lander.test.sh --nonvacuity`) ───────────────────────────────────
# The mutant DELETES the pending arm of the classifier, so pending checks fall into the failure
# bucket. The suite must then FAIL, and the assertion that must break is the PENDING one (asserted by
# name, so a mutant that merely crashes somewhere else cannot be counted as proof).
#
# ── WHY THE STUB LIVES AT $O/gh-rest/gh ────────────────────────────────────────────────────────
# `lander.sh` prepends /opt/homebrew/bin and then re-asserts the seeded gh shims first (#1988), so a
# stub anywhere else on PATH would LOSE to the box's real gh and this suite would hit the network.
# Installing the stub at `$O/gh-rest/gh` is therefore both hermetic AND a live test of that
# re-assert: remove it and the suite runs a real gh (with a deliberately invalid token, so it fails
# fast rather than merging anything).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANDER="${LANDER_BIN:-$HERE/lander.sh}"
[ -f "$LANDER" ] || { echo "lander.test.sh: no lander at $LANDER" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %2d — %s\n' "$PASS" "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL      — %s\n' "$1"; }
ck()  { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# ── fixture: a stub gh driven by files ────────────────────────────────────────────────────────
# Every read the lander performs is answered from $FX; every invocation is appended to $STUB_CALLS
# so an arm can assert what was (and was not) CALLED, not merely what was printed.
new_case() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/lander-test.XXXXXX")"
  O="$T/o"; FX="$T/fx"; STUB_CALLS="$T/calls"
  mkdir -p "$O/state" "$O/gh-rest" "$FX" "$O/logs"
  : >"$STUB_CALLS"
  # ⛔ EXPORTED, or the stub cannot see them: it is a separate process, and an unexported
  # STUB_CALLS made `>>"$STUB_CALLS"` an AMBIGUOUS REDIRECT — the stub exited before answering a
  # single read, the lander saw an empty board, and every arm "passed" for the wrong reason.
  export FX STUB_CALLS
  printf '3\n9\n' >"$FX/queue"          # queued, then in_progress
  printf '0\n'     >"$FX/rules"         # no merge queue by default (a projected COUNT, like --jq)
  # Branch protection: the REAL repo-authority.sh module is sourced by the lander, so this fixture is
  # what decides gate vs rail vs unknown. The gate name is IN the set => authority=gate => squash.
  printf 'ai-review-gate\npipeline-compliance\n' >"$FX/protection"
  cat >"$O/gh-rest/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS:-/dev/null}"
sub="$1 ${2:-}"
num="${3:-}"
case "$sub" in
  "pr list")  cat "$FX/list.json" 2>/dev/null || printf '[]\n' ;;
  "pr view")  cat "$FX/view-$num.json" 2>/dev/null || { echo "no view fixture for $num" >&2; exit 1; } ;;
  "pr checks")
    cat "$FX/checks-$num.json" 2>/dev/null || printf '[]\n'
    # Real gh's documented exit codes: 1 = a check failed, 8 = pending. The lander must judge the
    # PAYLOAD, never this — that is the `rc` arm below.
    exit "$(cat "$FX/checks_rc-$num" 2>/dev/null || echo 0)" ;;
  "pr merge")
    printf '%s\n' "$*" >>"$STUB_CALLS.merge"
    printf '✓ Merged #%s (abc1234) (squashed)\n' "$num" ;;
  api*)
    path="${2:-}"
    pn="$(printf '%s' "$path" | sed -n 's#.*/pulls/\([0-9][0-9]*\).*#\1#p')"
    case "$path" in
      *"actions/runs?status=queued"*)      sed -n 1p "$FX/queue" ;;
      *"actions/runs?status=in_progress"*) sed -n 2p "$FX/queue" ;;
      *"rules/branches/main"*)             cat "$FX/rules" 2>/dev/null || printf '0\n' ;;
      *"protection/required_status_checks"*)
        if [ -e "$FX/protection_fail" ]; then printf 'gh: Branch not protected / HTTP 403\n' >&2; exit 1; fi
        cat "$FX/protection" 2>/dev/null ;;
      *"/pulls/"*)                         cat "$FX/merge_sha-$pn" 2>/dev/null || printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' ;;
      *)                                   printf '0\n' ;;
    esac ;;
  *) printf 'stub gh: unhandled: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$O/gh-rest/gh"
  : >"$STUB_CALLS.merge"
}

# seed <n> <mergeable> <mstate> <draft> <head> — one PR in the candidate list
seed() {
  local n="$1" m="$2" s="$3" d="$4" h="$5"
  python3 - "$FX/list.json" "$n" "$d" "$h" <<'PY'
import json, sys
p, n, d, h = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "true", sys.argv[4]
try:
    rows = json.load(open(p))
except Exception:
    rows = []
rows.append({"number": n, "isDraft": d, "headRefOid": h})
json.dump(rows, open(p, "w"))
PY
  printf '{"mergeable":"%s","mergeStateStatus":"%s","isDraft":%s,"headRefOid":"%s"}\n' "$m" "$s" "$d" "$h" >"$FX/view-$n.json"
}
# checks <n> name:state ... — the check surface for PR n
checks() {
  local n="$1"; shift
  local out="[" sep="" kv nme st
  for kv in "$@"; do
    nme="${kv%%:*}"; st="${kv##*:}"
    out="$out$sep{\"name\":\"$nme\",\"state\":\"$st\"}"; sep=","
  done
  printf '%s]\n' "$out" >"$FX/checks-$n.json"
}
merged_nums() { cat "$STUB_CALLS.merge" 2>/dev/null | awk 'NF{print $3}' | tr '\n' ' '; }

run_lander() { # -> $OUT, $RC
  OUT="$(O="$O" GH_TOKEN=stub-invalid-token bash "$LANDER" --repo stub/repo --max 50 2>&1)"; RC=$?
}

say_case() { printf '\n── %s\n' "$1"; }

# ══ CASE 1 — GREEN: the one thing that MUST land ═════════════════════════════════════════════
say_case "case 1: MERGEABLE + CLEAN + all green → merged, head-pinned, sha reported"
new_case
seed 101 MERGEABLE CLEAN false aaaa111122223333444455556666777788889999
checks 101 build:success test:success lint:neutral docs:skipped
run_lander
ck "GREEN: the lander exits 0 ($OUT)" "$RC"
has "$(merged_nums)" "101" && ok "GREEN: the all-green PR was merged (merge calls: $(merged_nums))" \
                           || bad "GREEN: the all-green PR was NOT merged (merge calls: '$(merged_nums)')"
grep -q 'pr merge 101 --repo stub/repo --squash --match-head-commit aaaa111122223333444455556666777788889999' "$STUB_CALLS" \
  && ok "GREEN: the merge is head-pinned (--match-head-commit <classified head>)" \
  || bad "GREEN: the merge was not head-pinned — got: $(grep 'pr merge' "$STUB_CALLS" | tr '\n' ' ')"
has "$OUT" "MERGED sha=deadbeef" && ok "GREEN: the merge sha is reported" || bad "GREEN: no merge sha in the report ($OUT)"
case "$OUT" in *--admin*|*PIPELINE_COMPLIANCE_SKIP*) bad "GREEN: an admin/bypass flag appeared" ;; *) ok "GREEN: no --admin and no PIPELINE_COMPLIANCE_SKIP anywhere" ;; esac

# ══ CASE 2 — PENDING: the measured case. MUST NOT merge, MUST NOT be called a failure ═════════
say_case "case 2: MERGEABLE + CLEAN + CI still running → NOT merged, reported waiting-on-CI"
new_case
seed 102 MERGEABLE CLEAN false bbbb111122223333444455556666777788889999
checks 102 build:success test:success docs:in_progress lint:queued
printf '1\n' >"$FX/checks_rc-102"        # real gh exits 1 here; the lander must ignore that rc
run_lander
ck "PENDING: the lander exits 0 — waiting is not an error ($OUT)" "$RC"
[ -z "$(merged_nums)" ] && ok "PENDING: a PR merely waiting on CI was NOT merged" \
                        || bad "PENDING: a PR merely waiting on CI WAS merged (merge calls: '$(merged_nums)')"
has "$OUT" "#102 waiting-on-CI" && ok "PENDING: reported as waiting-on-CI, the distinct third state" \
                                || bad "PENDING: not reported as waiting-on-CI ($OUT)"
if printf '%s\n' "$OUT" | grep -qE '^\[lander\] #102 .*(skipped|FAIL)'; then
  bad "PENDING: a pending PR was reported as skipped/failed — the conflation this file exists to prevent ($(printf '%s\n' "$OUT" | grep '#102'))"
else ok "PENDING: not reported as skipped, and not reported as failed"; fi
has "$OUT" "summary: merged=0 enqueued=0 would_merge=0 waiting=1 skipped=0 errors=0" \
  && ok "PENDING: the summary counts it as waiting=1, skipped=0 (rc=1 from gh pr checks was NOT read as unreadable)" \
  || bad "PENDING: the summary miscounts a pending PR ($(printf '%s' "$OUT" | grep summary))"

# ══ CASE 3 — FAILED: skipped, and the failing check is NAMED ═════════════════════════════════
say_case "case 3: MERGEABLE + CLEAN + one failing check → skipped, failure named, never merged"
new_case
seed 103 MERGEABLE CLEAN false cccc111122223333444455556666777788889999
checks 103 python-ci-gate:failure test:success
printf '1\n' >"$FX/checks_rc-103"
run_lander
[ -z "$(merged_nums)" ] && ok "FAILED: a PR with a failing check was NOT merged" \
                        || bad "FAILED: a PR with a failing check WAS merged"
has "$OUT" "#103 skipped: 1 FAILED check(s): python-ci-gate (failure)" \
  && ok "FAILED: the failing check is named in the report" \
  || bad "FAILED: the failing check was not named ($OUT)"
if printf '%s\n' "$OUT" | grep -qE '^\[lander\] #103 .*waiting'; then
  bad "FAILED: a red PR was reported as waiting (the inverse conflation): $(printf '%s\n' "$OUT" | grep '#103')"
else ok "FAILED: not reported as waiting"; fi

# ══ CASE 4 — DRAFT ══════════════════════════════════════════════════════════════════════════
say_case "case 4: a draft is skipped even when it is MERGEABLE, CLEAN and green"
new_case
seed 104 MERGEABLE CLEAN true dddd111122223333444455556666777788889999
checks 104 build:success
run_lander
[ -z "$(merged_nums)" ] && ok "DRAFT: a draft was NOT merged" || bad "DRAFT: a draft WAS merged"
has "$OUT" "#104 skipped: draft" && ok "DRAFT: skipped with the draft reason" || bad "DRAFT: no draft reason ($OUT)"
# ── the queue-depth line must be here even though this run merged NOTHING (the spec's arm) ─────
has "$OUT" "CI queue depth: 3 queued, 9 in progress (12 workflow runs)" \
  && ok "QUEUE LINE: the CI queue depth is printed on a run that merged nothing" \
  || bad "QUEUE LINE: no queue-depth line on a no-merge run ($OUT)"
n="$(printf '%s\n' "$OUT" | grep -c 'CI queue depth')"
[ "$n" = "1" ] && ok "QUEUE LINE: exactly once per run" || bad "QUEUE LINE: printed $n times, expected exactly 1"

# ══ CASE 5 — BLOCKED with green checks: reported with its blocker ════════════════════════════
say_case "case 5: MERGEABLE + BLOCKED + all green → reported with the blocker, NOT merged"
new_case
seed 105 MERGEABLE BLOCKED false eeee111122223333444455556666777788889999
checks 105 build:success test:success
run_lander
[ -z "$(merged_nums)" ] && ok "BLOCKED: a blocked PR was NOT merged" || bad "BLOCKED: a blocked PR WAS merged"
has "$OUT" "#105 skipped: mergeStateStatus=BLOCKED" && ok "BLOCKED: the blocker is reported" \
  || bad "BLOCKED: no blocker in the report ($OUT)"
has "$OUT" "protection rule or a required review" && ok "BLOCKED: the blocker is named as protection/review, not as CI" \
  || bad "BLOCKED: the blocker was not named ($OUT)"
if printf '%s\n' "$OUT" | grep -qE '^\[lander\] #105 .*waiting'; then
  bad "BLOCKED: a blocked PR was misreported as waiting on CI"
else ok "BLOCKED: not misreported as a CI wait"; fi

# ══ CASE 6 — merge queue present → enqueue with --auto, and say so ═══════════════════════════
say_case "case 6: a repo with a merge queue hands the ready PR to the queue (--auto), no direct squash"
new_case
printf '1\n' >"$FX/rules"          # one merge_queue rule
seed 106 MERGEABLE CLEAN false ffff111122223333444455556666777788889999
checks 106 build:success
run_lander
has "$OUT" "merge queue: PRESENT" && ok "QUEUE: queue presence detected from REST branch rules" || bad "QUEUE: queue not detected ($OUT)"
grep -q 'pr merge 106 --repo stub/repo --squash --auto' "$STUB_CALLS" \
  && ok "QUEUE: enqueued with --auto" || bad "QUEUE: not enqueued ($(grep 'pr merge' "$STUB_CALLS" | tr '\n' ' '))"
has "$OUT" "#106 ENQUEUED" && ok "QUEUE: reported as enqueued (not merged — the queue lands it)" || bad "QUEUE: not reported as enqueued ($OUT)"

# ══ CASE 7 — an unrecognised check state is a FAILURE (allow-list polarity) ══════════════════
say_case "case 7: an unrecognised / null check conclusion is a failure, never a pass"
new_case
seed 107 MERGEABLE CLEAN false 1111111122222333334444455555666667777788888
checks 107 build:success weird:action_required
run_lander
[ -z "$(merged_nums)" ] && ok "UNKNOWN-STATE: not merged" || bad "UNKNOWN-STATE: merged on an unrecognised check state"
has "$OUT" "weird (action_required)" && ok "UNKNOWN-STATE: the offending check is named with its state" \
                                      || bad "UNKNOWN-STATE: state not named ($OUT)"

# ══ CASE 7b — a CANCELLED check is NON-RED but not green: skipped, named, never merged ═══════
# Measured live (2026-10-21): real PRs carry `workflow-drift (cancelled)` beside 20+ green checks.
# The fleet's polarity calls cancelled/stale NON-RED — so reporting "FAILED" would invent a red tree
# and summon a fixer for nothing — while merging on it would land work whose verification never
# finished. Both wrong answers are asserted against here.
say_case "case 7b: a cancelled (non-red, not green) check is skipped and named, not called failed and not merged"
new_case
seed 108 MERGEABLE CLEAN false 2222222233333444445555566666777778888899999
checks 108 build:success workflow-drift:cancelled test:success
run_lander
[ -z "$(merged_nums)" ] && ok "CANCELLED: not merged (verification never completed)" \
                        || bad "CANCELLED: merged a PR with an incomplete check"
has "$OUT" "workflow-drift (cancelled) did not complete" \
  && ok "CANCELLED: reported as a non-red incomplete check, with the check named" \
  || bad "CANCELLED: not reported as an incomplete check ($OUT)"
if printf '%s\n' "$OUT" | grep -qE '^\[lander\] #108 .*FAILED check'; then
  bad "CANCELLED: a non-red cancelled check was reported as a FAILED check (invents a red tree)"
else ok "CANCELLED: not reported as a failed check"; fi

# ══ CASE 9 — RAIL authority: a ready PR on a rail repo is NOT merged by this verb ═══════════
# The #1764 bypass: on a repo whose authority is its own rail, `gh pr merge` lands the PR on the
# required checks alone, with no head-bound review evidence. A lander that ignored the contract would
# be a bypass with a friendly log line.
say_case "case 9: a READY PR on a RAIL-authority repo is skipped, naming merge-one.sh as the owner"
new_case
printf 'pipeline-compliance\ndocs\n' >"$FX/protection"     # the gate is NOT required => rail
seed 109 MERGEABLE CLEAN false 3333333344444555556666677777888889999900000
checks 109 build:success test:success
run_lander
[ -z "$(merged_nums)" ] && ok "RAIL: a ready PR was NOT squash-merged on a rail repo" \
                        || bad "RAIL: bypassed the repo's rail (merge calls: '$(merged_nums)')"
has "$OUT" "merge authority: rail" && ok "RAIL: the authority is resolved from branch protection (the real module)" \
                                   || bad "RAIL: authority not resolved ($OUT)"
has "$OUT" "#109 skipped: READY, but this repo's merge authority is its own RAIL" \
  && ok "RAIL: skipped with the rail reason, not as a CI wait or a defect" \
  || bad "RAIL: no rail reason on the PR ($OUT)"

# ══ CASE 10 — an UNREADABLE merge contract merges nothing and exits 3 ═════════════════════════
say_case "case 10: unreadable branch protection => nothing merges, and the run exits 3 (not a quiet success)"
new_case
: >"$FX/protection_fail"
seed 110 MERGEABLE CLEAN false 4444444455555666667777788888999900000111111
checks 110 build:success
run_lander
[ "$RC" = "3" ] && ok "CONTRACT: an unreadable contract exits 3" || bad "CONTRACT: exited $RC, expected 3"
[ -z "$(merged_nums)" ] && ok "CONTRACT: nothing merged on an unreadable contract" \
                        || bad "CONTRACT: merged without a readable merge contract"
has "$OUT" "merge authority: UNKNOWN" && ok "CONTRACT: the refusal is named" || bad "CONTRACT: not named ($OUT)"
case "$OUT" in
  *"REQ_SOURCE=fallback"*) ok "CONTRACT: it names WHY (unreadable protection + no override), not just the verdict" ;;
  *) bad "CONTRACT: the reason is missing ($OUT)" ;;
esac

# ══ CASE 8 — an unreadable board merges NOTHING and exits 2 ══════════════════════════════════
say_case "case 8: an unreadable PR board exits 2 and merges nothing (never reads as 'no open PRs')"
new_case
printf 'not json at all\n' >"$FX/list.json"
run_lander
[ "$RC" = "2" ] && ok "BOARD: an unreadable board exits 2" || bad "BOARD: an unreadable board exited $RC, expected 2"
[ -z "$(merged_nums)" ] && ok "BOARD: nothing merged on an unreadable board" || bad "BOARD: merged something without a readable board"
has "$OUT" "FATAL: the open-PR board could not be read" && ok "BOARD: the failure is named" || bad "BOARD: the failure is not named ($OUT)"

# ══ summary ═════════════════════════════════════════════════════════════════════════════════
printf '\n%s of %s assertions passed, %s failed\n' "$PASS" "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

# ══ NON-VACUITY ═════════════════════════════════════════════════════════════════════════════
# Mutant: delete the pending arm of the classifier, so pending checks fall into the failure bucket
# (i.e. the PENDING/FAILED distinction removed). The suite MUST fail, and the assertion that breaks
# must be the PENDING one by name.
if [ "${1:-}" = "--nonvacuity" ]; then
  printf '\n── non-vacuity: removing the PENDING/FAILED distinction\n'
  MT="$(mktemp -d "${TMPDIR:-/tmp}/lander-mutant.XXXXXX")"
  # The classifier's pending arm is the PYTHON line below (the payload is judged by one python
  # reader). Deleting it drops every pending state into the trailing `else` — i.e. the failure
  # bucket, which is exactly "the PENDING/FAILED distinction removed".
  sed '/elif st in pending: p += 1/d' "$LANDER" >"$MT/mutant.sh"
  if cmp -s "$LANDER" "$MT/mutant.sh"; then
    printf 'FAIL      — non-vacuity: the mutation changed NOTHING (the delete-pending-arm recipe no longer matches lander.sh), so the recipe is a no-op gate\n'
    exit 1
  fi
  printf 'ok        — non-vacuity: the mutant actually differs from lander.sh\n'
  MOUT="$(LANDER_BIN="$MT/mutant.sh" bash "$0" 2>&1)"; MRC=$?
  if [ "$MRC" -ne 0 ]; then printf 'ok        — non-vacuity: the mutated lander makes the suite FAIL (rc=%s)\n' "$MRC"
  else printf 'FAIL      — non-vacuity: the suite PASSED against the mutated lander — the PENDING arm is vacuous\n'; exit 1; fi
  if printf '%s\n' "$MOUT" | grep -q 'FAIL .*PENDING'; then
    printf 'ok        — non-vacuity: the PENDING arm is the one that breaks (not an unrelated crash)\n'
  else
    printf 'FAIL      — non-vacuity: the mutant failed, but NOT on the PENDING arm — the arm may be passing for the wrong reason\n'
    printf '%s\n' "$MOUT" | grep 'FAIL' | sed 's/^/    /'
    exit 1
  fi
  printf '\nnon-vacuity: PASS\n'
  exit 0
fi
